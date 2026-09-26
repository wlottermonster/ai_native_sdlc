"""REQ-HAND-002/007/008: native handoff routing and launch behavior."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid


ROOT = Path(__file__).resolve().parents[2]
SESSION_A = "11111111-1111-4111-8111-111111111111"
SESSION_B = "22222222-2222-4222-8222-222222222222"


def load(name):
    path = ROOT / "core" / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.repo = self.base / "repo with spaces"
        (self.home / ".codex" / "sdlc-openai").mkdir(parents=True)
        (self.home / ".claude").mkdir(parents=True)
        self.repo.mkdir()
        (self.home / ".codex" / "sdlc-openai" / "engines.toml").write_text(
            '[roles]\njudge="codex-judge"\nbuild="codex-build"\nverify="inherit"\n'
            'read="codex-read"\nescalate="codex-escalate"\n'
            '[reasoning]\njudge="high"\nbuild="medium"\nread="low"\nescalate="xhigh"\n'
            '[agents]\nimplementer="build"\n'
        )
        (self.home / ".claude" / "sdlc-engines.conf").write_text(
            "judge = claude-judge, fallback\nbuild = claude-build, fallback\n"
            "verify = claude-verify\nread = claude-read\nescalate = claude-escalate\n"
        )
        (self.home / ".claude" / "sdlc-handoff.toml").write_text(
            '[reasoning]\njudge="high"\nbuild="medium"\nverify="low"\nread="minimal"\nescalate="max"\n'
        )

    def manifest(self, target="codex", state="prepared", malicious=False):
        text = "owner context; touch " + str(self.base / "PWNED") if malicious else "owner context"
        packet = self.base / "state" / "packet"
        packet.mkdir(parents=True, exist_ok=True)
        start = packet / "start.md"
        progress = packet / "progress.md"
        returned = packet / "return.md"
        start.write_text(text)
        progress.write_text("checkpoint")
        returned.write_text("done; touch " + str(self.base / "RETURN_PWNED"))
        return {
            "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "repo": str(self.repo),
            "phase": "build",
            "task": "Implement exactly",
            "state": state,
            "source": {"client": "claude", "session_id": SESSION_A, "surface": "cli"},
            "target": {"client": target, "model": "custom/model", "effort": "high"},
            "receiver": None,
            "artifacts": {"start": str(start), "progress": str(progress), "return": str(returned)},
        }

    def test_REQ_HAND_002_routes_destination_role_maps_and_independent_overrides(self):
        """REQ-HAND-002: destination maps and independent overrides determine routing."""
        runtime = load("handoff_runtime")
        self.assertEqual(
            runtime.resolve_assignment("codex", "implement", self.home),
            {"role": "build", "model": "codex-build", "effort": "medium"},
        )
        self.assertEqual(
            runtime.resolve_assignment("codex", "verify", self.home),
            {"role": "verify", "model": None, "effort": None},
        )
        self.assertEqual(
            runtime.resolve_assignment("claude", "design", self.home),
            {"role": "judge", "model": "claude-judge", "effort": "high"},
        )
        self.assertEqual(
            runtime.resolve_assignment("claude", "build", self.home, model="named"),
            {"role": "build", "model": "named", "effort": "medium"},
        )
        self.assertEqual(
            runtime.resolve_assignment("claude", "build", self.home, effort="max"),
            {"role": "build", "model": "claude-build", "effort": "max"},
        )

    def test_REQ_HAND_002_role_override_wins_and_invalid_metadata_fails_closed(self):
        """REQ-HAND-002: explicit roles win while unknown metadata fails closed."""
        runtime = load("handoff_runtime")
        self.assertEqual(runtime.resolve_assignment("codex", "build", self.home, role="read")["model"], "codex-read")
        self.assertEqual(runtime.resolve_assignment("codex", "build", self.home, role="escalate")["model"], "codex-escalate")
        self.assertEqual(runtime.resolve_assignment("codex", "escalate", self.home)["role"], "escalate")
        for args in [
            ("codex", "unknown", {}),
            ("other", "build", {}),
            ("codex", "build", {"role": "unknown"}),
        ]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                runtime.resolve_assignment(args[0], args[1], self.home, **args[2])
        (self.home / ".codex" / "sdlc-openai" / "engines.toml").write_text("broken")
        with self.assertRaises(ValueError):
            runtime.resolve_assignment("codex", "build", self.home)
        (self.home / ".codex" / "sdlc-openai" / "engines.toml").write_text(
            '[roles]\nbuild="explicit"\n[reasoning]\n[agents]\nx="build"\n')
        with self.assertRaises(ValueError):
            runtime.resolve_assignment("codex", "build", self.home)

    def test_REQ_HAND_002_claude_inherit_omits_model_and_effort(self):
        """REQ-HAND-002: inherit is represented by absent model and effort flags."""
        runtime = load("handoff_runtime")
        (self.home / ".claude" / "sdlc-engines.conf").write_text(
            "judge = claude-judge\nbuild = claude-build\nverify = claude-verify\n"
            "read = inherit\nescalate = claude-escalate\n"
        )
        self.assertEqual(runtime.resolve_assignment("claude", "read", self.home),
                         {"role": "read", "model": None, "effort": None})

    def test_REQ_HAND_002_task_freeform_never_changes_routing(self):
        """REQ-HAND-002: freeform task prose is not a routing input."""
        runtime = load("handoff_runtime")
        first = runtime.resolve_assignment("codex", "build", self.home)
        # Task prose is deliberately absent from the routing API.
        self.assertEqual(first["role"], "build")
        self.assertNotIn("task", runtime.resolve_assignment.__code__.co_varnames[:runtime.resolve_assignment.__code__.co_argcount])

    def test_REQ_HAND_007_builds_both_direction_new_and_exact_resume_argv(self):
        """REQ-HAND-007: both clients receive safe new and exact resume argv."""
        runtime = load("handoff_runtime")
        incoming = runtime.build_launch(self.manifest("codex"), runtime_path=ROOT / "core" / "handoff.py")
        self.assertEqual(incoming["argv"][:4], ["codex", "-C", str(self.repo), "-m"])
        self.assertIn("model_reasoning_effort=\"high\"", incoming["argv"])
        self.assertEqual(incoming["cwd"], str(self.repo))
        self.assertIn("accept", incoming["prompt"])
        self.assertIn("ACTUAL_SESSION_UUID", incoming["prompt"])
        self.assertIn("CODEX_THREAD_ID", incoming["prompt"])
        self.assertIn(incoming["prompt"], incoming["argv"])

        outgoing = runtime.build_launch(self.manifest("codex", "returned"), return_trip=True,
                                        runtime_path=ROOT / "core" / "handoff.py")
        self.assertEqual(outgoing["argv"][:3], ["claude", "--resume", SESSION_A])
        self.assertNotIn("--last", outgoing["argv"])
        self.assertIn("ack", outgoing["prompt"])
        self.assertIn("Before making any further project edits", outgoing["prompt"])
        self.assertIn("progress.md", outgoing["prompt"])
        self.assertIn("cleanup", outgoing["prompt"])

        reverse = self.manifest("claude")
        reverse["source"]["client"] = "codex"
        new_claude = runtime.build_launch(reverse, runtime_path=ROOT / "core" / "handoff.py")
        receiver_id = str(uuid.uuid5(uuid.UUID(reverse["id"]), "claude-receiver"))
        self.assertEqual(new_claude["argv"][:7],
                         ["claude", "--session-id", receiver_id,
                          "--model", "custom/model", "--effort", "high"])
        self.assertIn("--session " + receiver_id, new_claude["prompt"])
        self.assertNotIn("CLAUDE_SESSION_ID", new_claude["prompt"])
        self.assertNotIn("ACTUAL_SESSION_UUID", new_claude["prompt"])
        self.assertEqual(new_claude["recovery_argv"], ["claude", "--resume", receiver_id])
        self.assertIn("--resume " + receiver_id, new_claude["recovery_command"])
        self.assertIn("do not start a duplicate", new_claude["prompt"].lower())
        self.assertTrue(new_claude["manual_command"].startswith("cd "))
        self.assertIn(str(self.repo), new_claude["manual_command"])
        returned = runtime.build_launch({**reverse, "state": "returned"}, return_trip=True,
                                        runtime_path=ROOT / "core" / "handoff.py")
        self.assertEqual(returned["argv"][:4], ["codex", "resume", SESSION_A, "-C"])
        self.assertNotIn("--last", returned["argv"])

    def test_REQ_HAND_007_app_return_is_labeled_for_native_send_and_navigation(self):
        """REQ-HAND-007: app returns identify host-native delivery and CLI fallback."""
        runtime = load("handoff_runtime")
        manifest = self.manifest("codex", "returned")
        manifest["source"]["surface"] = "app"
        plan = runtime.build_launch(manifest, return_trip=True, runtime_path=ROOT / "core" / "handoff.py")
        self.assertEqual(plan["delivery"], "host_native_required")
        self.assertEqual(plan["host_delivery"]["task_id"], SESSION_A)
        self.assertEqual(plan["host_delivery"]["action"], "send_and_navigate")
        self.assertIn("return package", plan["host_delivery"]["prompt"])
        self.assertEqual(plan["fallback"], "manual_cli_resume")

    def test_REQ_HAND_007_missing_manifest_client_fails_clearly(self):
        """REQ-HAND-007: incomplete client identity never reaches a native process."""
        runtime = load("handoff_runtime")
        incoming = self.manifest("codex")
        incoming["target"].pop("client")
        with self.assertRaisesRegex(ValueError, "target client"):
            runtime.build_launch(incoming, runtime_path=ROOT / "core" / "handoff.py")
        outgoing = self.manifest("codex", "returned")
        outgoing["source"].pop("client")
        with self.assertRaisesRegex(ValueError, "source client"):
            runtime.build_launch(outgoing, return_trip=True,
                                 runtime_path=ROOT / "core" / "handoff.py")

    def test_REQ_HAND_007_shell_metacharacters_remain_one_argument_and_are_not_executed(self):
        """REQ-HAND-007: native execution preserves hostile text as one argv item."""
        runtime = load("handoff_runtime")
        plan = runtime.build_launch(self.manifest("codex", malicious=True), runtime_path=ROOT / "core" / "handoff.py")
        self.assertFalse((self.base / "PWNED").exists())
        self.assertEqual(plan["argv"][-1], plan["prompt"])
        with patch.object(runtime.subprocess, "call", return_value=0) as called, patch.object(runtime.sys.stdin, "isatty", return_value=True), patch.object(runtime.sys.stdout, "isatty", return_value=True):
            result = runtime.launch(plan, "exec")
        called.assert_called_once_with(plan["argv"], cwd=str(self.repo))
        self.assertEqual(result["status"], "process_exited")
        self.assertFalse((self.base / "PWNED").exists())

    def test_REQ_HAND_007_preflight_and_terminal_have_actionable_print_fallbacks(self):
        """REQ-HAND-007: unsupported launches return a printable manual fallback."""
        runtime = load("handoff_runtime")
        missing = runtime.preflight("codex", which=lambda _: None)
        self.assertFalse(missing["supported"])
        self.assertIn("not found", missing["reason"])
        plan = runtime.build_launch(self.manifest("codex"), runtime_path=ROOT / "core" / "handoff.py")
        with patch.object(runtime, "preflight", return_value=missing):
            result = runtime.launch(plan, "terminal")
        self.assertEqual(result["status"], "manual_fallback")
        self.assertIn("manual_command", result)
        with patch.object(runtime.sys.stdin, "isatty", return_value=False):
            with self.assertRaises(ValueError):
                runtime.launch(plan, "exec")

    def test_REQ_HAND_007_preflight_checks_version_and_all_launch_flags_with_timeouts(self):
        """REQ-HAND-007: bounded preflight checks version and launch controls only."""
        runtime = load("handoff_runtime")
        calls = []

        class Result:
            stdout = "--resume --model --effort"
            stderr = ""

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            return Result()

        result = runtime.preflight("claude", which=lambda _: "/tools/claude", run=run)
        self.assertFalse(result["supported"])
        self.assertIn("launch controls", result["reason"])
        self.assertEqual([row[0] for row in calls],
                         [["/tools/claude", "--version"], ["/tools/claude", "--help"]])
        self.assertTrue(all(row[1]["timeout"] == 3 for row in calls))
        self.assertTrue(all("auth" not in " ".join(row[0]) for row in calls))

    def test_REQ_HAND_007_terminal_passes_shell_command_as_osascript_argv(self):
        """REQ-HAND-007: Terminal receives quoted command data outside AppleScript source."""
        runtime = load("handoff_runtime")
        plan = runtime.build_launch(self.manifest("codex", malicious=True),
                                    runtime_path=ROOT / "core" / "handoff.py")
        completed = type("Completed", (), {"returncode": 0})()
        with patch.object(runtime, "preflight", return_value={"supported": True}), \
                patch.object(runtime.sys, "platform", "darwin"), \
                patch.object(runtime.shutil, "which", return_value="/usr/bin/osascript"), \
                patch.object(runtime.subprocess, "run", return_value=completed) as called:
            result = runtime.launch(plan, "terminal")
        self.assertEqual(result["status"], "terminal_started")
        osascript_argv = called.call_args.args[0]
        self.assertEqual(osascript_argv[0], "osascript")
        self.assertIn("on run argv", osascript_argv)
        self.assertTrue(any("item 1 of argv" in item for item in osascript_argv))
        self.assertTrue(osascript_argv[-1].startswith("cd "))
        self.assertEqual(osascript_argv[-1].count("cd "), 1)
        for script in osascript_argv[1:-1]:
            self.assertNotIn(str(self.base / "PWNED"), script)
        self.assertFalse((self.base / "PWNED").exists())

    def test_REQ_HAND_008_print_launch_reports_unknown_usage_and_never_advances_state(self):
        """REQ-HAND-008: launch reports unknown observations and no state transition."""
        runtime = load("handoff_runtime")
        plan = runtime.build_launch(self.manifest("codex"), runtime_path=ROOT / "core" / "handoff.py")
        result = runtime.launch(plan, "print")
        self.assertEqual(result["status"], "ready")
        self.assertIsNone(result["observed_model"])
        self.assertIsNone(result["observed_effort"])
        self.assertIsNone(result["usage"])
        self.assertNotIn("state", result)


class FakeStore:
    instance = None

    def __init__(self, repo, state_dir=None):
        self.repo = repo
        self.state_dir = state_dir
        self.calls = []
        FakeStore.instance = self

    def accept(self, handoff_id, **kwargs):
        self.calls.append(("accept", handoff_id, kwargs))
        return {"id": handoff_id, "state": "active"}

    def prepare(self, **kwargs):
        self.calls.append(("prepare", None, kwargs))
        return {"id": "packet", "state": "prepared", "target": kwargs["target"]}

    def load(self, handoff_id):
        self.calls.append(("load", handoff_id, {}))
        return {"id": handoff_id, "state": "prepared"}


class FakeStoreModule:
    Store = FakeStore
    value = True
    raise_on_call = False

    @staticmethod
    def should_yield(client, session_id, *, repo, state_dir=None):
        if FakeStoreModule.raise_on_call:
            raise ValueError("bad identity")
        return FakeStoreModule.value


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        (self.repo / "tracked.txt").write_text("initial\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "tracked.txt"], check=True)
        subprocess.run([
            "git", "-C", str(self.repo), "-c", "user.name=Fixture", "-c",
            "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
            "commit", "-qm", "fixture",
        ], check=True)
        self.home = self.base / "home"
        (self.home / ".codex" / "sdlc-openai").mkdir(parents=True)
        (self.home / ".codex" / "sdlc-openai" / "engines.toml").write_text(
            '[roles]\nbuild="builder"\nread="reader"\n[reasoning]\nbuild="high"\nread="low"\n[agents]\nx="build"\n'
        )

    def run_cli(self, args, store_module=FakeStoreModule):
        cli = load("handoff")
        output = io.StringIO()
        error = io.StringIO()
        with patch("sys.stdout", output), patch("sys.stderr", error):
            code = cli.main(["--repo", str(self.repo), "--state-dir", str(self.base / "state"),
                             "--home", str(self.home), *args],
                            store_module=store_module)
        parsed = json.loads(output.getvalue()) if output.getvalue() else None
        return code, parsed, error.getvalue()

    def test_REQ_HAND_005_cli_status_lists_invalid_packages_and_retire_removes_them(self):
        """REQ-HAND-005: the CLI exposes invalid packages and an ID-scoped retire."""
        store_module = load("handoff_store")
        store = store_module.Store(self.repo, state_dir=self.base / "state")
        manifest = store.prepare(
            source={"client": "codex", "session_id": SESSION_A, "surface": "cli"},
            target={"client": "claude", "model": None, "effort": None},
            phase="build", task="task", briefing="brief")
        store.cancel(manifest["id"], client="codex", session_id=SESSION_A,
                     reason="stopped", receiver_stopped=True)
        manifest_path = self.base / "state" / manifest["id"] / "manifest.json"
        manifest_path.write_text("{not json")
        code, rows, _ = self.run_cli(["status"], store_module=store_module)
        self.assertEqual(code, 0)
        self.assertEqual([(row["id"], row["state"]) for row in rows], [(manifest["id"], "invalid")])
        code, result, _ = self.run_cli(["retire", manifest["id"]], store_module=store_module)
        self.assertEqual(code, 0)
        self.assertEqual(result["id"], manifest["id"])
        self.assertFalse((self.base / "state" / manifest["id"]).exists())
        self.assertEqual(self.run_cli(["status"], store_module=store_module)[1], [])

    def test_REQ_HAND_002_cli_preserves_exact_receiver_identity(self):
        """REQ-HAND-002: CLI passes the explicitly supplied receiver identity exactly."""
        code, result, _ = self.run_cli(["accept", "packet", "--client", "codex", "--session", SESSION_B])
        self.assertEqual(code, 0)
        self.assertEqual(result["state"], "active")
        self.assertEqual(FakeStore.instance.calls[-1][2]["client"], "codex")
        self.assertEqual(FakeStore.instance.calls[-1][2]["session_id"], SESSION_B)

    def test_REQ_HAND_002_cli_role_override_routes_destination_and_bounds_context(self):
        """REQ-HAND-002: CLI role override and bounded briefing drive preparation."""
        context = self.base / "brief.md"
        context.write_text("bounded context")
        args = ["prepare", "--source-client", "claude", "--source-session", SESSION_A,
                "--source-surface", "app", "--to", "codex", "--phase", "build",
                "--role", "read", "--task", "review then implement", "--context-file", str(context)]
        code, result, _ = self.run_cli(args)
        self.assertEqual(code, 0)
        self.assertEqual(result["role"], "read")
        self.assertEqual(FakeStore.instance.calls[-1][2]["target"],
                         {"client": "codex", "model": "reader", "effort": "low"})
        context.write_bytes(b"x" * (32 * 1024 + 1))
        code, _, error = self.run_cli(args)
        self.assertEqual(code, 2)
        self.assertIn("exceeds", error)

    def test_REQ_HAND_007_cli_changed_accept_requires_reconciliation_text(self):
        """REQ-HAND-007: changed-state acceptance requires an explicit recorded reason."""
        code, result, error = self.run_cli(["accept", "packet", "--client", "codex", "--session", SESSION_B, "--allow-changed"])
        self.assertEqual(code, 2)
        self.assertIsNone(result)
        self.assertIn("reconcile-reason", error)
        code, _, _ = self.run_cli(["accept", "packet", "--client", "codex", "--session", SESSION_B,
                                   "--allow-changed", "--reconcile-reason", "owner reviewed the diff"])
        self.assertEqual(code, 0)
        self.assertTrue(FakeStore.instance.calls[-1][2]["allow_changed"])
        self.assertEqual(FakeStore.instance.calls[-1][2]["reconcile_reason"],
                         "owner reviewed the diff")

    def test_REQ_HAND_008_yield_check_exit_contract(self):
        """REQ-HAND-008: yield-check distinguishes yield, stop, and errors by status."""
        FakeStoreModule.value = True
        FakeStoreModule.raise_on_call = False
        self.assertEqual(self.run_cli(["yield-check", "--client", "claude", "--session", SESSION_A])[0], 0)
        FakeStoreModule.value = False
        self.assertEqual(self.run_cli(["yield-check", "--client", "claude", "--session", SESSION_A])[0], 1)
        FakeStoreModule.raise_on_call = True
        self.assertEqual(self.run_cli(["yield-check", "--client", "claude", "--session", SESSION_A])[0], 2)
        FakeStoreModule.raise_on_call = False

    def test_REQ_HAND_007_cli_rejects_missing_client_identity(self):
        """REQ-HAND-007: native CLI identity is mandatory rather than discovered."""
        cli = load("handoff")
        with patch("sys.stderr", io.StringIO()):
            with self.assertRaises(SystemExit):
                cli.main(["--repo", str(self.repo), "accept", "packet", "--session", SESSION_B],
                         store_module=FakeStoreModule)

    def test_REQ_HAND_007_REQ_HAND_008_real_store_launch_does_not_accept_and_reason_persists(self):
        """REQ-HAND-007/REQ-HAND-008: real launch stays prepared and reasons persist."""
        store_module = load("handoff_store")
        context = self.base / "brief.md"
        context.write_text("exact briefing")
        prepare = ["prepare", "--source-client", "claude", "--source-session", SESSION_A,
                   "--source-surface", "cli", "--to", "codex", "--phase", "build",
                   "--task", "implement exact task", "--context-file", str(context)]
        code, manifest, _ = self.run_cli(prepare, store_module)
        self.assertEqual(code, 0)
        handoff_id = manifest["id"]
        code, launch, _ = self.run_cli(["launch", handoff_id], store_module)
        self.assertEqual(code, 0)
        self.assertEqual(launch["status"], "ready")
        store = store_module.Store(self.repo, state_dir=self.base / "state")
        self.assertEqual(store.load(handoff_id)["state"], "prepared")
        (self.repo / "tracked.txt").write_text("owner reconciled\n")
        code, accepted, _ = self.run_cli([
            "accept", handoff_id, "--client", "codex", "--session", SESSION_B,
            "--allow-changed", "--reconcile-reason", "owner reviewed exact drift",
        ], store_module)
        self.assertEqual(code, 0)
        self.assertEqual(accepted["state"], "active")
        self.assertEqual(accepted["reconciliation"]["accept_reason"],
                         "owner reviewed exact drift")


if __name__ == "__main__":
    unittest.main()
