"""Unit coverage for the private interactive-handoff state store."""
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid


ROOT = Path(__file__).resolve().parents[2]


def module():
    spec = importlib.util.spec_from_file_location(
        "handoff_store", ROOT / "core/handoff_store.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class HandoffStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        (self.repo / "tracked.txt").write_text("initial\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "tracked.txt"], check=True)
        subprocess.run([
            "git", "-C", str(self.repo), "-c", "user.name=Fixture", "-c",
            "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
            "commit", "-qm", "fixture",
        ], check=True)
        self.state = self.root / "state"
        self.store_module = module()
        self.store = self.store_module.Store(self.repo, state_dir=self.state)
        self.codex_session = str(uuid.uuid4())
        self.claude_session = str(uuid.uuid4())

    def source(self, client="codex"):
        return {
            "client": client,
            "session_id": self.codex_session if client == "codex" else self.claude_session,
            "surface": "cli",
        }

    def target(self, client="claude"):
        return {"client": client, "model": None, "effort": None}

    def prepare(self, source="codex", target="claude", briefing="Exact briefing"):
        return self.store.prepare(
            source=self.source(source), target=self.target(target), phase="build",
            task="Implement the approved task", briefing=briefing)

    def test_REQ_HAND_001_both_direction_lifecycles_record_exact_identity_and_artifacts(self):
        """REQ-HAND-001/003/004: both client directions retain exact transfer identity."""
        for source, target in (("codex", "claude"), ("claude", "codex")):
            with self.subTest(source=source):
                state = self.root / (source + "-state")
                store = self.store_module.Store(self.repo, state_dir=state)
                source_identity = self.source(source)
                receiver_session = self.claude_session if target == "claude" else self.codex_session
                manifest = store.prepare(
                    source=source_identity, target=self.target(target), phase="build",
                    task="Transfer task", briefing="Immutable briefing")
                uuid.UUID(manifest["id"])
                self.assertEqual(manifest["source"], source_identity)
                self.assertEqual(manifest["target"], self.target(target))
                self.assertEqual(manifest["state"], "prepared")
                self.assertEqual(set(manifest["artifacts"]),
                                 {"start", "progress", "return", "closed-summary"})
                self.assertEqual(Path(manifest["artifacts"]["start"]).read_text(),
                                 "Immutable briefing")
                self.assertIsNone(manifest["receiver"])

                manifest = store.accept(
                    manifest["id"], client=target, session_id=receiver_session,
                    observed_model=None, observed_effort=None)
                self.assertEqual(manifest["state"], "active")
                self.assertEqual(manifest["receiver"]["client"], target)
                self.assertEqual(manifest["receiver"]["session_id"], receiver_session)
                self.assertIsNone(manifest["receiver"]["observed_model"])
                store.progress(manifest["id"], client=target, session_id=receiver_session,
                               text="First checkpoint")
                manifest = store.handback(
                    manifest["id"], client=target, session_id=receiver_session,
                    summary="Work and tests")
                self.assertEqual(manifest["state"], "returned")
                self.assertIn("return_snapshot", manifest)
                manifest = store.acknowledge(
                    manifest["id"], client=source,
                    session_id=source_identity["session_id"], summary="Receipt acknowledged")
                self.assertEqual(manifest["state"], "closed")
                self.assertEqual(Path(manifest["artifacts"]["return"]).read_text(), "Work and tests")
                self.assertEqual(Path(manifest["artifacts"]["closed-summary"]).read_text(),
                                 "Receipt acknowledged")

    def test_REQ_HAND_003_stale_snapshot_requires_explicit_accept_reconciliation(self):
        """REQ-HAND-003: acceptance rejects checkout drift unless explicitly reconciled."""
        manifest = self.prepare()
        (self.repo / "tracked.txt").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        with self.assertRaisesRegex(ValueError, "reason"):
            self.store.accept(
                manifest["id"], client="claude", session_id=self.claude_session,
                allow_changed=True)
        manifest = self.store.accept(
            manifest["id"], client="claude", session_id=self.claude_session,
            allow_changed=True, reconcile_reason="Owner reviewed the changed file")
        self.assertTrue(manifest["reconciliation"]["accept_changed"])
        self.assertEqual(manifest["reconciliation"]["accept_reason"],
                         "Owner reviewed the changed file")

    def test_REQ_HAND_003_acceptance_snapshots_after_waiting_for_state_lock(self):
        """REQ-HAND-003: lock contention cannot make acceptance use an old snapshot."""
        manifest = self.prepare()

        @contextmanager
        def delayed_lock():
            (self.repo / "tracked.txt").write_text("changed while waiting\n")
            yield

        with patch.object(self.store, "_lock", delayed_lock):
            with self.assertRaisesRegex(ValueError, "changed"):
                self.store.accept(
                    manifest["id"], client="claude", session_id=self.claude_session)

    def test_REQ_HAND_004_stale_return_requires_explicit_source_reconciliation(self):
        """REQ-HAND-004: source acknowledgement checks the receiver's return snapshot."""
        manifest = self.prepare()
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        manifest = self.store.handback(
            manifest["id"], client="claude", session_id=self.claude_session,
            summary="Returned")
        (self.repo / "after-return.txt").write_text("source-side change\n")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.store.acknowledge(
                manifest["id"], client="codex", session_id=self.codex_session,
                summary="Ack")
        manifest = self.store.acknowledge(
            manifest["id"], client="codex", session_id=self.codex_session,
            summary="Ack after reconciliation", allow_changed=True,
            reconcile_reason="Owner reconciled the source-side change")
        self.assertTrue(manifest["reconciliation"]["acknowledge_changed"])
        self.assertEqual(manifest["reconciliation"]["acknowledge_reason"],
                         "Owner reconciled the source-side change")

    def test_REQ_HAND_005_identity_state_and_duplicate_guards(self):
        """REQ-HAND-005: exact identities and state transitions prevent stale overwrites."""
        manifest = self.prepare()
        with self.assertRaises(ValueError):
            self.store.accept(manifest["id"], client="codex", session_id=self.codex_session)
        active = self.store.accept(
            manifest["id"], client="claude", session_id=self.claude_session)
        with self.assertRaises(ValueError):
            self.store.accept(active["id"], client="claude", session_id=str(uuid.uuid4()))
        with self.assertRaises(ValueError):
            self.store.progress(
                active["id"], client="claude", session_id=str(uuid.uuid4()), text="stale")
        with self.assertRaises(ValueError):
            self.store.acknowledge(
                active["id"], client="codex", session_id=self.codex_session, summary="too soon")
        returned = self.store.handback(
            active["id"], client="claude", session_id=self.claude_session, summary="Original")
        with self.assertRaises(ValueError):
            self.store.handback(
                returned["id"], client="claude", session_id=self.claude_session,
                summary="Overwrite")
        self.assertEqual(Path(returned["artifacts"]["return"]).read_text(), "Original")

    def test_REQ_HAND_005_immutable_briefing_hash_is_enforced(self):
        """REQ-HAND-005: modifying the immutable start payload blocks acceptance."""
        manifest = self.prepare(briefing="Original briefing")
        Path(manifest["artifacts"]["start"]).write_text("Tampered briefing")
        with self.assertRaisesRegex(ValueError, "briefing"):
            self.store.accept(
                manifest["id"], client="claude", session_id=self.claude_session)

    def test_REQ_HAND_005_single_open_handoff_is_process_safe(self):
        """REQ-HAND-005: concurrent preparation yields one open handoff per checkout."""
        store_a = self.store_module.Store(self.repo, state_dir=self.state)
        store_b = self.store_module.Store(self.repo, state_dir=self.state)

        def attempt(store, task):
            try:
                return store.prepare(
                    source=self.source(), target=self.target(), phase="build",
                    task=task, briefing="brief")
            except ValueError as error:
                return error

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(attempt, (store_a, store_b), ("one", "two")))
        self.assertEqual(sum(isinstance(result, dict) for result in results), 1)
        self.assertEqual(sum(isinstance(result, ValueError) for result in results), 1)
        self.assertEqual(len(self.store.status()), 1)

    def test_REQ_HAND_005_lock_contention_is_bounded(self):
        """REQ-HAND-005: a busy interprocess lock fails instead of hanging hooks."""
        operations = []

        def busy(_descriptor, operation):
            if operation == self.store_module.fcntl.LOCK_UN:
                return
            operations.append(operation)
            raise BlockingIOError

        with patch.object(self.store_module.fcntl, "flock", side_effect=busy), patch.object(
                self.store_module, "LOCK_TIMEOUT", 0.01, create=True):
            with self.assertRaisesRegex(ValueError, "busy"):
                with self.store._lock():
                    self.fail("busy lock was acquired")
        self.assertTrue(operations)
        self.assertTrue(all(operation & self.store_module.fcntl.LOCK_NB
                            for operation in operations))

    def test_REQ_HAND_005_progress_save_failure_after_file_write_recovers(self):
        """REQ-HAND-005: a journaled new progress hash recovers after final save failure."""
        manifest = self.prepare()
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        real_save = self.store._save_unlocked

        def fail_final(candidate):
            if "progress_update" in candidate:
                return real_save(candidate)
            raise OSError("injected progress manifest save failure")

        with patch.object(self.store, "_save_unlocked", side_effect=fail_final):
            with self.assertRaisesRegex(OSError, "progress manifest"):
                self.store.progress(
                    manifest["id"], client="claude", session_id=self.claude_session,
                    text="first checkpoint")

        recovered = self.store.status()[0]
        self.assertNotIn("progress_update", recovered)
        self.assertEqual(Path(recovered["artifacts"]["progress"]).read_text(),
                         "first checkpoint")
        self.store.progress(
            manifest["id"], client="claude", session_id=self.claude_session,
            text="; second checkpoint")
        returned = self.store.handback(
            manifest["id"], client="claude", session_id=self.claude_session,
            summary="work complete")
        closed = self.store.acknowledge(
            manifest["id"], client="codex", session_id=self.codex_session,
            summary="received")
        self.assertEqual(returned["state"], "returned")
        self.assertEqual(closed["state"], "closed")

    def test_REQ_HAND_005_progress_failure_before_file_write_rolls_back_journal(self):
        """REQ-HAND-005: old progress remains valid when replacement fails after intent."""
        manifest = self.prepare()
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        progress_path = Path(manifest["artifacts"]["progress"])
        real_replace = self.store_module._atomic_replace

        def fail_progress(path, data):
            if path == progress_path:
                raise OSError("injected progress file failure")
            return real_replace(path, data)

        with patch.object(self.store_module, "_atomic_replace", side_effect=fail_progress):
            with self.assertRaisesRegex(OSError, "progress file"):
                self.store.progress(
                    manifest["id"], client="claude", session_id=self.claude_session,
                    text="not written")

        durable = json.loads(progress_path.parent.joinpath("manifest.json").read_text())
        self.assertIn("progress_update", durable)
        restarted = self.store_module.Store(self.repo, state_dir=self.state)
        recovered = restarted.status()[0]
        self.assertNotIn("progress_update", recovered)
        self.assertEqual(progress_path.read_text(), "")
        cancelled = restarted.cancel(
            manifest["id"], client="codex", session_id=self.codex_session,
            reason="receiver stopped after failed progress", receiver_stopped=True)
        self.assertEqual(cancelled["state"], "cancelled")
        replacement = restarted.prepare(
            source=self.source(), target=self.target(), phase="build",
            task="replacement", briefing="new transfer")
        self.assertEqual(replacement["state"], "prepared")

    def test_REQ_HAND_005_uuid_collision_and_interrupted_artifact_never_overwrite(self):
        """REQ-HAND-005: collisions and interrupted artifacts preserve original content."""
        collision = uuid.uuid4()
        (self.state / str(collision)).mkdir(parents=True)
        with patch.object(self.store_module.uuid, "uuid4", return_value=collision):
            with self.assertRaisesRegex(ValueError, "collision"):
                self.prepare()

        # A prior interrupted handback can leave an immutable payload before its
        # manifest transition. Recovery must preserve it for inspection.
        other = self.root / "interrupted-state"
        store = self.store_module.Store(self.repo, state_dir=other)
        manifest = store.prepare(
            source=self.source(), target=self.target(), phase="build", task="task",
            briefing="brief")
        store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        return_path = Path(manifest["artifacts"]["return"])
        return_path.write_text("recover me")
        with self.assertRaisesRegex(ValueError, "already exists"):
            store.handback(
                manifest["id"], client="claude", session_id=self.claude_session,
                summary="new value")
        self.assertEqual(return_path.read_text(), "recover me")
        self.assertEqual(store.load(manifest["id"])["state"], "active")

    def test_REQ_HAND_005_cancel_is_source_owned_explicit_and_terminal(self):
        """REQ-HAND-005: cancellation requires stopped receiver proof and keeps artifacts."""
        manifest = self.prepare()
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        self.store.progress(
            manifest["id"], client="claude", session_id=self.claude_session,
            text="recoverable progress")
        with self.assertRaises(ValueError):
            self.store.cancel(
                manifest["id"], client="codex", session_id=self.codex_session,
                reason="receiver stopped", receiver_stopped=False)
        with self.assertRaises(ValueError):
            self.store.cancel(
                manifest["id"], client="claude", session_id=self.claude_session,
                reason="not source", receiver_stopped=True)
        cancelled = self.store.cancel(
            manifest["id"], client="codex", session_id=self.codex_session,
            reason="receiver stopped", receiver_stopped=True)
        self.assertEqual(cancelled["state"], "cancelled")
        self.assertEqual(cancelled["cancellation"]["reason"], "receiver stopped")
        self.assertIn("recoverable progress", Path(cancelled["artifacts"]["progress"]).read_text())
        with self.assertRaises(ValueError):
            self.store.progress(
                manifest["id"], client="claude", session_id=self.claude_session,
                text="stale receiver")
        replacement = self.prepare(briefing="new transfer")
        self.assertEqual(replacement["state"], "prepared")

    def test_REQ_HAND_005_snapshot_is_git_visible_deterministic_and_strips_git_environment(self):
        """REQ-HAND-005: snapshot tracks modes/symlinks while excluding ignored state."""
        (self.repo / ".gitignore").write_text("ignored\n")
        (self.repo / "ignored").write_text("secret one")
        (self.repo / "untracked").write_text("visible")
        with patch.dict(os.environ, {"GIT_DIR": "/invalid", "GIT_WORK_TREE": "/invalid"}):
            first = self.store_module.repository_snapshot(self.repo)
        (self.repo / "ignored").write_text("secret two")
        self.assertEqual(first, self.store_module.repository_snapshot(self.repo))
        (self.repo / "untracked").chmod(0o755)
        executable = self.store_module.repository_snapshot(self.repo)
        self.assertNotEqual(first["fingerprint"], executable["fingerprint"])
        (self.repo / "link").symlink_to("tracked.txt")
        linked = self.store_module.repository_snapshot(self.repo)
        self.assertNotEqual(executable["fingerprint"], linked["fingerprint"])
        self.assertEqual(linked["branch"], "main")
        self.assertRegex(linked["head"], r"^[0-9a-f]{40,64}$")

    def test_REQ_HAND_005_private_paths_exact_root_and_symlinks_refused(self):
        """REQ-HAND-005: explicit roots are exact/private and symlink paths are rejected."""
        manifest = self.prepare()
        self.assertEqual(Path(manifest["artifacts"]["start"]).parent.parent, self.state)
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(Path(manifest["artifacts"]["start"]).stat().st_mode), 0o600)
        alias = self.root / "state-alias"
        alias.symlink_to(self.state, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.store_module.Store(self.repo, state_dir=alias)

    def test_REQ_HAND_006_cleanup_only_closed_known_payloads(self):
        """REQ-HAND-006: cleanup deletes only owned payloads from acknowledged handoffs."""
        manifest = self.prepare()
        package = Path(manifest["artifacts"]["start"]).parent
        unrelated = package / "owner-note.txt"
        unrelated.write_text("keep")
        with self.assertRaises(ValueError):
            self.store.cleanup(manifest["id"])
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        self.store.progress(
            manifest["id"], client="claude", session_id=self.claude_session,
            text="checkpoint")
        self.store.handback(
            manifest["id"], client="claude", session_id=self.claude_session,
            summary="return")
        closed = self.store.acknowledge(
            manifest["id"], client="codex", session_id=self.codex_session,
            summary="compact audit")
        cleaned = self.store.cleanup(manifest["id"])
        self.assertEqual(cleaned["state"], "closed")
        self.assertIn("cleaned_at", cleaned)
        for key in ("start", "progress", "return"):
            self.assertFalse(Path(closed["artifacts"][key]).exists())
        self.assertTrue(Path(closed["artifacts"]["closed-summary"]).is_file())
        self.assertTrue(unrelated.is_file())
        self.assertTrue((package / "manifest.json").is_file())

    def test_REQ_HAND_006_cleanup_refuses_payload_symlinks(self):
        """REQ-HAND-006: cleanup cannot follow a substituted payload symlink."""
        manifest = self.prepare()
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        self.store.handback(
            manifest["id"], client="claude", session_id=self.claude_session,
            summary="return")
        manifest = self.store.acknowledge(
            manifest["id"], client="codex", session_id=self.codex_session,
            summary="audit")
        outside = self.root / "outside"
        outside.write_text("safe")
        progress = Path(manifest["artifacts"]["progress"])
        progress.unlink()
        progress.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.store.cleanup(manifest["id"])
        self.assertEqual(outside.read_text(), "safe")

    def test_REQ_HAND_005_cleanup_completion_save_failure_is_retryable(self):
        """REQ-HAND-005/006: persisted cleanup intent recovers after final save failure."""
        manifest = self.prepare()
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        self.store.handback(
            manifest["id"], client="claude", session_id=self.claude_session,
            summary="return")
        manifest = self.store.acknowledge(
            manifest["id"], client="codex", session_id=self.codex_session,
            summary="audit")
        real_save = self.store._save_unlocked

        def fail_completion(candidate):
            if "cleaned_at" in candidate:
                raise OSError("injected completion save failure")
            return real_save(candidate)

        with patch.object(self.store, "_save_unlocked", side_effect=fail_completion):
            with self.assertRaisesRegex(OSError, "injected"):
                self.store.cleanup(manifest["id"])

        recovering = self.store.load(manifest["id"])
        self.assertIn("cleanup_started_at", recovering)
        self.assertNotIn("cleaned_at", recovering)
        self.assertEqual([row["id"] for row in self.store.status()], [manifest["id"]])
        replacement = self.prepare(briefing="new transfer after interrupted cleanup")
        self.assertEqual(replacement["state"], "prepared")
        cleaned = self.store.cleanup(manifest["id"])
        self.assertIn("cleaned_at", cleaned)

    def test_REQ_HAND_005_partial_cleanup_unlink_is_retryable(self):
        """REQ-HAND-005/006: restart resumes a journaled partially deleted payload set."""
        manifest = self.prepare()
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        self.store.handback(
            manifest["id"], client="claude", session_id=self.claude_session,
            summary="return")
        manifest = self.store.acknowledge(
            manifest["id"], client="codex", session_id=self.codex_session,
            summary="audit")
        progress = Path(manifest["artifacts"]["progress"])
        real_unlink = Path.unlink
        injected = False

        def fail_progress(path, *args, **kwargs):
            nonlocal injected
            if path == progress and not injected:
                injected = True
                raise OSError("injected partial unlink failure")
            return real_unlink(path, *args, **kwargs)

        with patch.object(Path, "unlink", fail_progress):
            with self.assertRaisesRegex(OSError, "partial unlink"):
                self.store.cleanup(manifest["id"])

        recovering = self.store.load(manifest["id"])
        self.assertIn("cleanup_started_at", recovering)
        self.assertFalse(Path(manifest["artifacts"]["start"]).exists())
        self.assertTrue(progress.exists())
        cleaned = self.store.cleanup(manifest["id"])
        self.assertIn("cleaned_at", cleaned)

    def test_REQ_HAND_004_ack_and_cleanup_require_intact_return_and_progress(self):
        """REQ-HAND-004/006: hashed receiver evidence must survive ack and cleanup."""
        for corruption in ("missing-return", "changed-progress"):
            with self.subTest(corruption=corruption):
                state = self.root / ("evidence-" + corruption)
                store = self.store_module.Store(self.repo, state_dir=state)
                manifest = store.prepare(
                    source=self.source(), target=self.target(), phase="build", task="task",
                    briefing="brief")
                store.accept(manifest["id"], client="claude", session_id=self.claude_session)
                store.progress(
                    manifest["id"], client="claude", session_id=self.claude_session,
                    text="verified checkpoint")
                manifest = store.handback(
                    manifest["id"], client="claude", session_id=self.claude_session,
                    summary="verified return")
                if corruption == "missing-return":
                    Path(manifest["artifacts"]["return"]).unlink()
                else:
                    Path(manifest["artifacts"]["progress"]).write_text("changed checkpoint")
                with self.assertRaisesRegex(ValueError, "payload"):
                    store.acknowledge(
                        manifest["id"], client="codex", session_id=self.codex_session,
                        summary="must not close")
                self.assertFalse(Path(manifest["artifacts"]["closed-summary"]).exists())

        state = self.root / "cleanup-evidence"
        store = self.store_module.Store(self.repo, state_dir=state)
        manifest = store.prepare(
            source=self.source(), target=self.target(), phase="build", task="task",
            briefing="brief")
        store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        manifest = store.handback(
            manifest["id"], client="claude", session_id=self.claude_session,
            summary="verified return")
        manifest = store.acknowledge(
            manifest["id"], client="codex", session_id=self.codex_session,
            summary="audit")
        Path(manifest["artifacts"]["return"]).write_text("changed after ack")
        with self.assertRaisesRegex(ValueError, "payload"):
            store.cleanup(manifest["id"])
        self.assertTrue(Path(manifest["artifacts"]["start"]).exists())

    def test_REQ_HAND_001_payload_limits_and_input_validation(self):
        """REQ-HAND-001/004/005: API strings are nonempty and byte-bounded."""
        with self.assertRaises(ValueError):
            self.store.prepare(
                source=self.source(), target=self.target(), phase=" ", task="task",
                briefing="brief")
        with self.assertRaises(ValueError):
            self.prepare(briefing="x" * (32 * 1024 + 1))
        manifest = self.prepare(briefing="x")
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        self.store.progress(
            manifest["id"], client="claude", session_id=self.claude_session,
            text="x" * (128 * 1024))
        with self.assertRaises(ValueError):
            self.store.progress(
                manifest["id"], client="claude", session_id=self.claude_session,
                text="y")
        with self.assertRaises(ValueError):
            self.store.handback(
                manifest["id"], client="claude", session_id=self.claude_session,
                summary="x" * (64 * 1024 + 1))
        returned = self.store.handback(
            manifest["id"], client="claude", session_id=self.claude_session,
            summary="return")
        with self.assertRaises(ValueError):
            self.store.acknowledge(
                returned["id"], client="codex", session_id=self.codex_session,
                summary="x" * (16 * 1024 + 1))

    def test_REQ_HAND_003_should_yield_tracks_source_and_receiver_ownership(self):
        """REQ-HAND-003/004: stop-hook yielding follows active ownership and return state."""
        xdg = self.root / "xdg"
        with patch.dict(os.environ, {"XDG_STATE_HOME": str(xdg)}):
            store = self.store_module.Store(self.repo)
            manifest = store.prepare(
                source=self.source(), target=self.target(), phase="build", task="task",
                briefing="brief")
            # Launching or preparing alone is not acceptance: nobody yields yet.
            self.assertFalse(store.should_yield("codex", self.codex_session))
            store.accept(manifest["id"], client="claude", session_id=self.claude_session)
            self.assertTrue(store.should_yield("codex", self.codex_session))
            self.assertFalse(store.should_yield("claude", self.claude_session))
            store.handback(
                manifest["id"], client="claude", session_id=self.claude_session,
                summary="return")
            self.assertTrue(store.should_yield("claude", self.claude_session))
            store.acknowledge(
                manifest["id"], client="codex", session_id=self.codex_session,
                summary="closed")
            self.assertFalse(store.should_yield("codex", self.codex_session))
            self.assertFalse(store.should_yield("claude", self.claude_session))

    def test_REQ_HAND_003_should_yield_supports_exact_read_only_state_root(self):
        """REQ-HAND-003: hook queries can target explicit state without creating it."""
        absent = self.root / "absent"
        self.assertFalse(self.store_module.should_yield(
            "codex", self.codex_session, repo=self.repo, state_dir=absent))
        self.assertFalse(absent.exists())
        manifest = self.prepare()
        self.assertFalse(self.store_module.should_yield(
            "codex", self.codex_session, repo=self.repo, state_dir=self.state))
        self.assertEqual(manifest["state"], "prepared")
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        self.assertTrue(self.store_module.should_yield(
            "codex", self.codex_session, repo=self.repo, state_dir=self.state))

        other_repo = self.root / "other-repo"
        other_repo.mkdir()
        subprocess.run(["git", "init", "-q", str(other_repo)], check=True)
        self.assertFalse(self.store_module.should_yield(
            "codex", self.codex_session, repo=other_repo, state_dir=self.state))

    def test_REQ_HAND_003_should_yield_rejects_malformed_or_tampered_packages(self):
        """REQ-HAND-003/005: read-only yielding trusts only a complete valid package."""
        manifest = self.prepare()
        self.store.accept(manifest["id"], client="claude", session_id=self.claude_session)
        manifest = self.store.load(manifest["id"])
        package = Path(manifest["artifacts"]["start"]).parent
        manifest_path = package / "manifest.json"
        pristine = json.loads(manifest_path.read_text())

        malformed = []
        for missing in ("id", "artifacts", "snapshot"):
            candidate = json.loads(json.dumps(pristine))
            candidate.pop(missing)
            malformed.append(candidate)
        missing_source_identity = json.loads(json.dumps(pristine))
        missing_source_identity["source"].pop("surface")
        malformed.append(missing_source_identity)
        bad_receiver = json.loads(json.dumps(pristine))
        bad_receiver["receiver"] = {}
        malformed.append(bad_receiver)

        for candidate in malformed:
            manifest_path.write_text(json.dumps(candidate))
            self.assertFalse(self.store_module.should_yield(
                "codex", self.codex_session, repo=self.repo, state_dir=self.state))

        manifest_path.write_text(json.dumps(pristine))
        Path(pristine["artifacts"]["start"]).write_text("tampered briefing")
        self.assertFalse(self.store_module.should_yield(
            "codex", self.codex_session, repo=self.repo, state_dir=self.state))

        Path(pristine["artifacts"]["start"]).write_text("Exact briefing")
        wrong_id = str(uuid.uuid4())
        wrong_package = self.state / wrong_id
        shutil.copytree(package, wrong_package)
        package.rename(self.root / "moved-valid-package")
        self.assertFalse(self.store_module.should_yield(
            "codex", self.codex_session, repo=self.repo, state_dir=self.state))

    def test_REQ_HAND_003_should_yield_rejects_symlink_ancestors_without_writes(self):
        """REQ-HAND-003/005: hook reads neither follow symlink ancestors nor create state."""
        alias = self.root / "ancestor-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        through_alias = alias / "state"
        self.prepare()
        self.assertFalse(self.store_module.should_yield(
            "codex", self.codex_session, repo=self.repo, state_dir=through_alias))

    def test_REQ_HAND_005_invalid_package_is_reported_blocks_prepare_and_is_retirable(self):
        """REQ-HAND-005: one corrupt package is diagnosed, never a checkout-wide outage."""
        manifest = self.prepare()
        self.store.cancel(manifest["id"], client="codex", session_id=self.codex_session,
                          reason="Receiver stopped", receiver_stopped=True)
        manifest_path = Path(manifest["artifacts"]["start"]).parent / "manifest.json"
        data = json.loads(manifest_path.read_text())
        data["schema_version"] = 999
        manifest_path.write_text(json.dumps(data))
        rows = self.store.status()
        self.assertEqual([(row["id"], row["state"]) for row in rows], [(manifest["id"], "invalid")])
        self.assertIn("error", rows[0])
        with self.assertRaisesRegex(ValueError, "retire"):
            self.prepare()
        self.store.retire(manifest["id"])
        self.assertFalse((self.state / manifest["id"]).exists())
        self.assertEqual(self.store.status(), [])
        valid = self.prepare()
        with self.assertRaisesRegex(ValueError, "valid"):
            self.store.retire(valid["id"])
        self.assertEqual([row["id"] for row in self.store.status()], [valid["id"]])

    def test_REQ_HAND_005_status_and_load_reject_corrupt_or_traversal_ids(self):
        """REQ-HAND-005: package lookup cannot escape state or accept corrupt manifests."""
        manifest = self.prepare()
        self.assertEqual([row["id"] for row in self.store.status()], [manifest["id"]])
        with self.assertRaises(ValueError):
            self.store.load("../manifest")
        Path(manifest["artifacts"]["start"]).parent.joinpath("manifest.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "manifest"):
            self.store.load(manifest["id"])


if __name__ == "__main__":
    unittest.main()
