#!/usr/bin/env python3.12
"""Private, atomic state store for interactive client handoffs."""
from contextlib import contextmanager
from datetime import datetime, timezone
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import uuid


SCHEMA_VERSION = 1
CLIENTS = {"codex", "claude"}
SURFACES = {"cli", "app"}
OPEN_STATES = {"prepared", "active", "returned"}
# A package the receiver has not accepted is not a transfer: the source keeps
# every Stop gate until acceptance, so an abandoned launch cannot bypass them.
ACCEPTED_STATES = {"active", "returned"}
TERMINAL_STATES = {"closed", "cancelled"}
ARTIFACT_NAMES = {
    "start": "start.md",
    "progress": "progress.md",
    "return": "return.md",
    "closed-summary": "closed-summary.md",
}
START_LIMIT = 32 * 1024
PROGRESS_LIMIT = 128 * 1024
RETURN_LIMIT = 64 * 1024
SUMMARY_LIMIT = 16 * 1024
SHORT_LIMIT = 4096
TASK_LIMIT = 32 * 1024
LOCK_TIMEOUT = 2.0
MANIFEST_LIMIT = 64 * 1024


def _now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _digest(value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"),
                         ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _file_hash(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def _git(repo, *args, optional=False):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        result = subprocess.run(
            ["git", "-c", "core.fsmonitor=false", "-C", str(repo), *args],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=10, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("Git metadata unavailable") from error
    if result.returncode and not optional:
        raise ValueError("Git metadata unavailable")
    return result.stdout if result.returncode == 0 else b""


def repository_snapshot(repo):
    """Return branch, HEAD and a deterministic hash of Git-visible worktree state."""
    repo = Path(repo).resolve()
    if not repo.is_dir():
        raise ValueError("Repository is not an accessible directory")
    top = _git(repo, "rev-parse", "--show-toplevel").decode("utf-8", "strict").strip()
    if Path(top).resolve() != repo:
        raise ValueError("Repository must be the checkout root")
    raw_names = _git(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    entries = []
    for raw in sorted(set(raw_names.split(b"\0")) - {b""}):
        name = os.fsdecode(raw)
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid Git inventory path")
        path = repo / relative
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            entries.append([name, "missing"])
            continue
        permissions = stat.S_IMODE(mode)
        if stat.S_ISLNK(mode):
            content = ["symlink", os.readlink(path)]
        elif stat.S_ISREG(mode):
            content = ["file", _file_hash(path)]
        elif stat.S_ISDIR(mode):
            content = ["gitlink", _git(
                path, "rev-parse", "--verify", "HEAD", optional=True
            ).decode("ascii", "strict").strip() or None]
        else:
            raise ValueError("Unsupported special file in Git inventory")
        entries.append([name, permissions, content])
    branch = _git(repo, "symbolic-ref", "--quiet", "--short", "HEAD",
                  optional=True).decode("utf-8", "strict").strip() or None
    head = _git(repo, "rev-parse", "--verify", "HEAD",
                optional=True).decode("ascii", "strict").strip() or None
    return {"branch": branch, "head": head,
            "fingerprint": _digest({"branch": branch, "head": head, "files": entries})}


def _validate_text(value, field, limit=SHORT_LIMIT):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a nonempty string")
    if len(value.encode("utf-8")) > limit:
        raise ValueError(f"{field} exceeds {limit} bytes")
    return value


def _validate_optional_text(value, field):
    if value is None:
        return None
    return _validate_text(value, field)


def _validate_uuid(value, field):
    value = _validate_text(value, field, 128)
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ValueError(f"{field} must be a UUID") from error
    if str(parsed) != value.lower():
        raise ValueError(f"{field} must be a canonical UUID")
    return str(parsed)


def _validate_client(value, field="client"):
    if value not in CLIENTS:
        raise ValueError(f"{field} must be codex or claude")
    return value


def _state_base():
    configured = os.environ.get("XDG_STATE_HOME")
    base = Path(configured) if configured else Path.home() / ".local" / "state"
    return base / "ainative-sdlc" / "handoffs"


def _check_no_symlinks(path):
    absolute = Path(os.path.abspath(path))
    for candidate in (absolute, *absolute.parents):
        # /var and /tmp are stable OS compatibility aliases on macOS. State
        # beneath either is still checked component-by-component.
        if str(candidate) in {"/var", "/tmp"}:
            continue
        try:
            if candidate.is_symlink():
                raise ValueError(f"State path has a symlink ancestor: {candidate}")
        except OSError as error:
            raise ValueError("State path is unavailable") from error


def _ensure_private_directory(path):
    _check_no_symlinks(path)
    try:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        if path.is_symlink() or not path.is_dir():
            raise ValueError("State path must be a real directory")
        path.chmod(0o700)
    except OSError as error:
        raise ValueError("Cannot create private state directory") from error


def _fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_temp(parent, data):
    descriptor, name = tempfile.mkstemp(prefix=".handoff-", dir=parent)
    path = Path(name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        path.unlink(missing_ok=True)
        raise
    return path


def _write_immutable(path, text):
    if path.is_symlink():
        raise ValueError(f"Artifact already exists: {path.name}")
    temporary = _write_temp(path.parent, text.encode("utf-8"))
    try:
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError as error:
            raise ValueError(f"Artifact already exists: {path.name}") from error
        _fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def _atomic_replace(path, data):
    if path.is_symlink():
        raise ValueError(f"Refusing symlink state file: {path.name}")
    temporary = _write_temp(path.parent, data)
    try:
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def _atomic_json(path, value):
    data = (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    _atomic_replace(path, data)


def _read_json_file(path):
    _check_no_symlinks(path)
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MANIFEST_LIMIT:
            raise ValueError("Handoff manifest is unavailable or oversized")
        with path.open("r", encoding="utf-8") as stream:
            contents = stream.read(MANIFEST_LIMIT + 1)
        if len(contents.encode("utf-8")) > MANIFEST_LIMIT:
            raise ValueError("Handoff manifest is oversized")
        return json.loads(contents)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("Handoff manifest is invalid") from error


def _valid_hash(value):
    return (isinstance(value, str) and len(value) == 64
            and all(character in "0123456789abcdef" for character in value))


def _expected_artifacts(state_dir, handoff_id):
    package = state_dir / handoff_id
    return {key: str((package / filename).absolute())
            for key, filename in ARTIFACT_NAMES.items()}


def _validate_payload_options(path, expected_hashes, label, *, allow_missing=False):
    if not expected_hashes or any(not _valid_hash(value) for value in expected_hashes):
        raise ValueError(f"Invalid {label} payload hash")
    _check_no_symlinks(path)
    if path.is_symlink() or not path.is_file():
        if allow_missing and not path.exists() and not path.is_symlink():
            return
        raise ValueError(f"{label} payload is unavailable")
    if _file_hash(path) not in expected_hashes:
        raise ValueError(f"{label} payload content changed")


def _validate_payload(path, expected_hash, label, *, allow_missing=False):
    _validate_payload_options(
        path, {expected_hash}, label, allow_missing=allow_missing)


def _validate_snapshot(snapshot):
    if (not isinstance(snapshot, dict)
            or not {"branch", "head", "fingerprint"}.issubset(snapshot)
            or not _valid_hash(snapshot.get("fingerprint"))):
        raise ValueError("Invalid handoff repository snapshot")
    branch = snapshot.get("branch")
    head = snapshot.get("head")
    if branch is not None:
        _validate_text(branch, "snapshot branch")
    if head is not None and (not isinstance(head, str) or len(head) not in (40, 64)
                             or any(character not in "0123456789abcdef" for character in head)):
        raise ValueError("Invalid handoff snapshot HEAD")


def _validate_source(source):
    if not isinstance(source, dict):
        raise ValueError("Invalid handoff source identity")
    _validate_client(source.get("client"), "source client")
    _validate_uuid(source.get("session_id"), "source session_id")
    if source.get("surface") not in SURFACES:
        raise ValueError("Invalid handoff source surface")


def _validate_target(target):
    if not isinstance(target, dict) or "model" not in target or "effort" not in target:
        raise ValueError("Invalid handoff target selection")
    _validate_client(target.get("client"), "target client")
    _validate_optional_text(target.get("model"), "target model")
    _validate_optional_text(target.get("effort"), "target effort")


def _validate_receiver(receiver):
    if not isinstance(receiver, dict):
        raise ValueError("Invalid handoff receiver identity")
    _validate_client(receiver.get("client"), "receiver client")
    _validate_uuid(receiver.get("session_id"), "receiver session_id")
    _validate_optional_text(receiver.get("observed_model"), "observed model")
    _validate_optional_text(receiver.get("observed_effort"), "observed effort")
    if "usage" not in receiver or receiver["usage"] is not None:
        raise ValueError("Invalid handoff receiver usage evidence")
    _validate_text(receiver.get("accepted_at"), "receiver accepted_at")


def _validate_manifest_data(manifest, *, repo, state_dir, expected_id=None):
    """Validate persisted state without Git access or state creation."""
    if not isinstance(manifest, dict) or manifest.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("Invalid handoff manifest")
    handoff_id = _validate_uuid(manifest.get("id"), "manifest id")
    if expected_id is not None and handoff_id != expected_id:
        raise ValueError("Invalid handoff manifest identity")
    state = manifest.get("state")
    if state not in OPEN_STATES | TERMINAL_STATES:
        raise ValueError("Invalid handoff manifest state")
    if manifest.get("repo") != repo:
        raise ValueError("Handoff belongs to a different repository")
    package = state_dir / handoff_id
    _check_no_symlinks(package)
    if package.is_symlink() or not package.is_dir():
        raise ValueError("Handoff package is unavailable")
    expected_artifacts = _expected_artifacts(state_dir, handoff_id)
    if manifest.get("artifacts") != expected_artifacts:
        raise ValueError("Invalid handoff artifact inventory")
    _validate_text(manifest.get("phase"), "manifest phase")
    _validate_text(manifest.get("task"), "manifest task", TASK_LIMIT)
    _validate_text(manifest.get("created_at"), "manifest created_at")
    _validate_text(manifest.get("updated_at"), "manifest updated_at")
    _validate_source(manifest.get("source"))
    _validate_target(manifest.get("target"))
    _validate_snapshot(manifest.get("snapshot"))
    if "receiver" not in manifest:
        raise ValueError("Handoff manifest omits receiver state")
    receiver = manifest.get("receiver")
    if state == "prepared":
        if receiver is not None:
            raise ValueError("Prepared handoff cannot have a receiver")
    elif state in {"active", "returned", "closed"}:
        _validate_receiver(receiver)
    elif receiver is not None:
        _validate_receiver(receiver)
    reconciliation = manifest.get("reconciliation")
    if (not isinstance(reconciliation, dict)
            or not {"accept_changed", "accept_reason", "acknowledge_changed",
                    "acknowledge_reason"}.issubset(reconciliation)
            or not isinstance(reconciliation.get("accept_changed"), bool)
            or not isinstance(reconciliation.get("acknowledge_changed"), bool)
            or reconciliation.get("accept_reason") is not None
            and not isinstance(reconciliation.get("accept_reason"), str)
            or reconciliation.get("acknowledge_reason") is not None
            and not isinstance(reconciliation.get("acknowledge_reason"), str)):
        raise ValueError("Invalid handoff reconciliation record")
    _validate_optional_text(reconciliation.get("accept_reason"), "accept reason")
    _validate_optional_text(reconciliation.get("acknowledge_reason"), "acknowledge reason")

    cleanup_started = state == "closed" and "cleanup_started_at" in manifest
    cleaned = state == "closed" and "cleaned_at" in manifest
    if "cleanup_started_at" in manifest and not cleanup_started:
        raise ValueError("Cleanup intent is valid only for closed handoffs")
    if cleanup_started:
        _validate_text(manifest.get("cleanup_started_at"), "manifest cleanup_started_at")
    if cleaned and not cleanup_started:
        raise ValueError("Completed cleanup is missing its persisted intent")
    if cleaned:
        _validate_text(manifest.get("cleaned_at"), "manifest cleaned_at")
    allow_missing_payloads = cleanup_started or cleaned
    _validate_payload(Path(expected_artifacts["start"]), manifest.get("start_sha256"),
                      "immutable briefing", allow_missing=allow_missing_payloads)
    progress_update = manifest.get("progress_update")
    if progress_update is not None:
        if (state != "active" or not isinstance(progress_update, dict)
                or not {"previous_sha256", "intended_sha256", "started_at"}.issubset(
                    progress_update)
                or progress_update.get("previous_sha256") != manifest.get("progress_sha256")
                or not _valid_hash(progress_update.get("previous_sha256"))
                or not _valid_hash(progress_update.get("intended_sha256"))):
            raise ValueError("Invalid pending progress update")
        _validate_text(progress_update.get("started_at"), "progress update started_at")
        progress_hashes = {
            progress_update["previous_sha256"], progress_update["intended_sha256"]}
    else:
        progress_hashes = {manifest.get("progress_sha256")}
    _validate_payload_options(
        Path(expected_artifacts["progress"]), progress_hashes, "progress",
        allow_missing=allow_missing_payloads)
    if state in {"returned", "closed"} or "return_sha256" in manifest:
        _validate_payload(Path(expected_artifacts["return"]), manifest.get("return_sha256"),
                          "return", allow_missing=allow_missing_payloads)
    if state == "closed":
        _validate_payload(Path(expected_artifacts["closed-summary"]),
                          manifest.get("closed_summary_sha256"), "closed-summary")
    return manifest


class Store:
    """Manage one repository's versioned handoff packages."""

    def __init__(self, repo, state_dir=None):
        self.repo = Path(repo).resolve()
        repository_snapshot(self.repo)
        if state_dir is None:
            repo_key = hashlib.sha256(str(self.repo).encode("utf-8")).hexdigest()
            self.state_dir = _state_base() / repo_key
        else:
            self.state_dir = Path(os.path.abspath(state_dir))
        _ensure_private_directory(self.state_dir)
        self.lock_path = self.state_dir / ".lock"

    @contextmanager
    def _lock(self):
        _check_no_symlinks(self.lock_path)
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(self.lock_path, flags, 0o600)
        except OSError as error:
            raise ValueError("Cannot open handoff state lock") from error
        acquired = False
        try:
            os.fchmod(descriptor, 0o600)
            deadline = time.monotonic() + LOCK_TIMEOUT
            while True:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    acquired = True
                    break
                except OSError as error:
                    if error.errno not in (None, errno.EACCES, errno.EAGAIN):
                        raise ValueError("Cannot acquire handoff state lock") from error
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise ValueError("Handoff state lock is busy") from error
                    time.sleep(min(0.05, remaining))
            yield
        finally:
            if acquired:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def _package(self, handoff_id):
        canonical = _validate_uuid(handoff_id, "handoff id")
        return self.state_dir / canonical

    def _artifacts(self, package):
        return _expected_artifacts(self.state_dir, package.name)

    def _validate_manifest(self, manifest, expected_id=None):
        return _validate_manifest_data(
            manifest, repo=str(self.repo), state_dir=self.state_dir,
            expected_id=expected_id)

    def _load_unlocked(self, handoff_id):
        package = self._package(handoff_id)
        path = package / "manifest.json"
        if package.is_symlink() or path.is_symlink() or not path.is_file():
            raise ValueError("Handoff manifest is unavailable")
        manifest = _read_json_file(path)
        manifest = self._validate_manifest(manifest, expected_id=str(uuid.UUID(handoff_id)))
        return self._recover_progress_unlocked(manifest)

    def _recover_progress_unlocked(self, manifest):
        """Finish or roll back a journaled progress replacement under the store lock."""
        update = manifest.get("progress_update")
        if update is None:
            return manifest
        path = Path(manifest["artifacts"]["progress"])
        actual = _file_hash(path)
        if actual == update["intended_sha256"]:
            manifest["progress_sha256"] = update["intended_sha256"]
        elif actual != update["previous_sha256"]:
            raise ValueError("Pending progress payload is not recoverable")
        del manifest["progress_update"]
        return self._save_unlocked(manifest)

    def _save_unlocked(self, manifest):
        manifest["updated_at"] = _now()
        package = self._package(manifest["id"])
        _atomic_json(package / "manifest.json", manifest)
        return manifest

    def _status_unlocked(self, invalid=None):
        """List valid manifests; an unreadable package is diagnosed, not fatal."""
        manifests = []
        for package in sorted(self.state_dir.iterdir(), key=lambda item: item.name):
            if package.name.startswith(".") or not package.is_dir() or package.is_symlink():
                continue
            try:
                uuid.UUID(package.name)
            except ValueError:
                continue
            manifest_path = package / "manifest.json"
            if not manifest_path.exists():
                continue
            try:
                manifests.append(self._load_unlocked(package.name))
            except (OSError, ValueError) as error:
                if invalid is None:
                    raise
                invalid.append({"id": package.name, "state": "invalid", "error": str(error)})
        return sorted(manifests, key=lambda row: (row["created_at"], row["id"]))

    def _retire_unlocked(self, handoff_id):
        package = self._package(handoff_id)
        _check_no_symlinks(package)
        if package.is_symlink() or not package.is_dir():
            raise ValueError("Handoff package is unavailable")
        try:
            self._load_unlocked(package.name)
        except (OSError, ValueError):
            pass
        else:
            raise ValueError("Only an invalid package can be retired; cancel or clean a valid one")
        retired = self.state_dir / ".retired"
        _ensure_private_directory(retired)
        destination = retired / (package.name + "-" + _now().replace(":", "").replace("+", ""))
        if destination.exists() or destination.is_symlink():
            raise ValueError("Retirement destination already exists")
        os.rename(package, destination)
        _fsync_directory(self.state_dir)
        return {"id": package.name, "state": "retired", "retired_to": str(destination)}

    def prepare(self, *, source, target, phase, task, briefing):
        if not isinstance(source, dict):
            raise ValueError("source must be an identity object")
        normalized_source = {
            "client": _validate_client(source.get("client"), "source client"),
            "session_id": _validate_uuid(source.get("session_id"), "source session_id"),
            "surface": source.get("surface"),
        }
        if normalized_source["surface"] not in SURFACES:
            raise ValueError("source surface must be cli or app")
        if not isinstance(target, dict):
            raise ValueError("target must be a selection object")
        normalized_target = {
            "client": _validate_client(target.get("client"), "target client"),
            "model": _validate_optional_text(target.get("model"), "target model"),
            "effort": _validate_optional_text(target.get("effort"), "target effort"),
        }
        if normalized_target["client"] == normalized_source["client"]:
            raise ValueError("source and target clients must differ")
        phase = _validate_text(phase, "phase")
        task = _validate_text(task, "task", TASK_LIMIT)
        briefing = _validate_text(briefing, "briefing", START_LIMIT)
        with self._lock():
            invalid = []
            rows = self._status_unlocked(invalid)
            if invalid:
                # An unreadable package may be the open handoff; it cannot be
                # ignored, only retired by name after the owner looked at it.
                raise ValueError("Invalid handoff package(s) block preparation; retire each by id: "
                                 + ", ".join(row["id"] for row in invalid))
            if any(row["repo"] == str(self.repo) and row["state"] in OPEN_STATES for row in rows):
                raise ValueError("An open handoff already exists for this checkout")
            snapshot = repository_snapshot(self.repo)
            handoff_id = str(uuid.uuid4())
            package = self.state_dir / handoff_id
            if package.exists() or package.is_symlink():
                raise ValueError("Handoff UUID collision")
            try:
                package.mkdir(mode=0o700)
                package.chmod(0o700)
            except FileExistsError as error:
                raise ValueError("Handoff UUID collision") from error
            artifacts = self._artifacts(package)
            _write_immutable(Path(artifacts["start"]), briefing)
            _write_immutable(Path(artifacts["progress"]), "")
            created = _now()
            manifest = {
                "id": handoff_id,
                "schema_version": SCHEMA_VERSION,
                "repo": str(self.repo),
                "phase": phase,
                "task": task,
                "source": normalized_source,
                "target": normalized_target,
                "state": "prepared",
                "created_at": created,
                "updated_at": created,
                "snapshot": snapshot,
                "receiver": None,
                "artifacts": artifacts,
                "start_sha256": hashlib.sha256(briefing.encode("utf-8")).hexdigest(),
                "progress_sha256": hashlib.sha256(b"").hexdigest(),
                "reconciliation": {
                    "accept_changed": False,
                    "accept_reason": None,
                    "acknowledge_changed": False,
                    "acknowledge_reason": None,
                },
            }
            _atomic_json(package / "manifest.json", manifest)
            return manifest

    def load(self, handoff_id):
        with self._lock():
            return self._load_unlocked(handoff_id)

    def status(self):
        """Valid manifests plus one diagnostic row per invalid package."""
        with self._lock():
            invalid = []
            return self._status_unlocked(invalid) + invalid

    def retire(self, handoff_id):
        """Move one invalid package out of the way; valid packages are refused."""
        with self._lock():
            return self._retire_unlocked(handoff_id)

    def accept(self, handoff_id, *, client, session_id, observed_model=None,
               observed_effort=None, allow_changed=False, reconcile_reason=None):
        client = _validate_client(client)
        session_id = _validate_uuid(session_id, "session_id")
        observed_model = _validate_optional_text(observed_model, "observed_model")
        observed_effort = _validate_optional_text(observed_effort, "observed_effort")
        if not isinstance(allow_changed, bool):
            raise ValueError("allow_changed must be boolean")
        if allow_changed:
            reconcile_reason = _validate_text(
                reconcile_reason, "reconciliation reason", SUMMARY_LIMIT)
        elif reconcile_reason is not None:
            raise ValueError("reconciliation reason requires allow_changed=True")
        with self._lock():
            manifest = self._load_unlocked(handoff_id)
            if manifest["state"] != "prepared":
                raise ValueError("Handoff is not prepared")
            if client != manifest["target"]["client"]:
                raise ValueError("Receiver client does not match target")
            current = repository_snapshot(self.repo)
            changed = current != manifest["snapshot"]
            if changed and not allow_changed:
                raise ValueError("Repository changed since handoff preparation")
            manifest["receiver"] = {
                "client": client,
                "session_id": session_id,
                "observed_model": observed_model,
                "observed_effort": observed_effort,
                "usage": None,
                "accepted_at": _now(),
            }
            manifest["reconciliation"]["accept_changed"] = changed
            manifest["reconciliation"]["accept_reason"] = reconcile_reason
            if changed:
                manifest["accepted_snapshot"] = current
            manifest["state"] = "active"
            return self._save_unlocked(manifest)

    @staticmethod
    def _require_receiver(manifest, client, session_id):
        receiver = manifest.get("receiver")
        if not isinstance(receiver, dict) or (receiver.get("client"), receiver.get("session_id")) != (
                client, session_id):
            raise ValueError("Receiver identity does not match accepted handoff")

    @staticmethod
    def _require_source(manifest, client, session_id):
        source = manifest.get("source")
        if not isinstance(source, dict) or (source.get("client"), source.get("session_id")) != (
                client, session_id):
            raise ValueError("Source identity does not match handoff")

    def progress(self, handoff_id, *, client, session_id, text):
        client = _validate_client(client)
        session_id = _validate_uuid(session_id, "session_id")
        text = _validate_text(text, "progress", PROGRESS_LIMIT)
        with self._lock():
            manifest = self._load_unlocked(handoff_id)
            if manifest["state"] != "active":
                raise ValueError("Handoff is not active")
            self._require_receiver(manifest, client, session_id)
            path = Path(manifest["artifacts"]["progress"])
            if path.is_symlink() or not path.is_file():
                raise ValueError("Progress artifact is unavailable")
            try:
                existing = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as error:
                raise ValueError("Progress artifact is unavailable") from error
            combined = existing + text
            if len(combined.encode("utf-8")) > PROGRESS_LIMIT:
                raise ValueError("progress exceeds cumulative 131072 bytes")
            intended_hash = hashlib.sha256(combined.encode("utf-8")).hexdigest()
            manifest["progress_update"] = {
                "previous_sha256": manifest["progress_sha256"],
                "intended_sha256": intended_hash,
                "started_at": _now(),
            }
            manifest = self._save_unlocked(manifest)
            _atomic_replace(path, combined.encode("utf-8"))
            manifest["progress_sha256"] = intended_hash
            del manifest["progress_update"]
            return self._save_unlocked(manifest)

    def handback(self, handoff_id, *, client, session_id, summary):
        client = _validate_client(client)
        session_id = _validate_uuid(session_id, "session_id")
        summary = _validate_text(summary, "return summary", RETURN_LIMIT)
        with self._lock():
            manifest = self._load_unlocked(handoff_id)
            if manifest["state"] != "active":
                raise ValueError("Handoff is not active")
            self._require_receiver(manifest, client, session_id)
            current = repository_snapshot(self.repo)
            return_path = Path(manifest["artifacts"]["return"])
            # If the following manifest save is interrupted, the immutable
            # return remains recoverable and source cancellation is the
            # explicit way to retire the still-active package.
            _write_immutable(return_path, summary)
            manifest["return_sha256"] = hashlib.sha256(summary.encode("utf-8")).hexdigest()
            manifest["return_snapshot"] = current
            manifest["returned_at"] = _now()
            manifest["state"] = "returned"
            return self._save_unlocked(manifest)

    def acknowledge(self, handoff_id, *, client, session_id, summary, allow_changed=False,
                    reconcile_reason=None):
        client = _validate_client(client)
        session_id = _validate_uuid(session_id, "session_id")
        summary = _validate_text(summary, "closed summary", SUMMARY_LIMIT)
        if not isinstance(allow_changed, bool):
            raise ValueError("allow_changed must be boolean")
        if allow_changed:
            reconcile_reason = _validate_text(
                reconcile_reason, "reconciliation reason", SUMMARY_LIMIT)
        elif reconcile_reason is not None:
            raise ValueError("reconciliation reason requires allow_changed=True")
        with self._lock():
            manifest = self._load_unlocked(handoff_id)
            if manifest["state"] != "returned":
                raise ValueError("Handoff has not been returned")
            self._require_source(manifest, client, session_id)
            current = repository_snapshot(self.repo)
            changed = current != manifest.get("return_snapshot")
            if changed and not allow_changed:
                raise ValueError("Repository changed since receiver handback")
            summary_path = Path(manifest["artifacts"]["closed-summary"])
            # A failed close save likewise preserves this immutable summary;
            # the returned package stays cancellable rather than guessing that
            # source acknowledgement completed.
            _write_immutable(summary_path, summary)
            manifest["closed_summary_sha256"] = hashlib.sha256(
                summary.encode("utf-8")).hexdigest()
            manifest["reconciliation"]["acknowledge_changed"] = changed
            manifest["reconciliation"]["acknowledge_reason"] = reconcile_reason
            if changed:
                manifest["acknowledged_snapshot"] = current
            manifest["acknowledged_at"] = _now()
            manifest["state"] = "closed"
            return self._save_unlocked(manifest)

    def cancel(self, handoff_id, *, client, session_id, reason, receiver_stopped=False):
        client = _validate_client(client)
        session_id = _validate_uuid(session_id, "session_id")
        reason = _validate_text(reason, "cancellation reason", SUMMARY_LIMIT)
        if receiver_stopped is not True:
            raise ValueError("Cancellation requires receiver_stopped=True")
        with self._lock():
            manifest = self._load_unlocked(handoff_id)
            if manifest["state"] not in OPEN_STATES:
                raise ValueError("Only an open handoff can be cancelled")
            self._require_source(manifest, client, session_id)
            manifest["cancellation"] = {
                "reason": reason,
                "receiver_stopped": True,
                "cancelled_at": _now(),
            }
            manifest["state"] = "cancelled"
            return self._save_unlocked(manifest)

    def cleanup(self, handoff_id):
        with self._lock():
            manifest = self._load_unlocked(handoff_id)
            if manifest["state"] != "closed":
                raise ValueError("Only a closed handoff can be cleaned")
            paths = [Path(manifest["artifacts"][key])
                     for key in ("start", "progress", "return")]
            if any(path.is_symlink() for path in paths):
                raise ValueError("Refusing to clean a symlink payload")
            for path in paths:
                if path.exists() and not path.is_file():
                    raise ValueError("Refusing to clean a non-file payload")
            if "cleanup_started_at" not in manifest:
                manifest["cleanup_started_at"] = _now()
                manifest = self._save_unlocked(manifest)
            for path in paths:
                path.unlink(missing_ok=True)
            _fsync_directory(self._package(handoff_id))
            manifest["cleaned_at"] = _now()
            return self._save_unlocked(manifest)

    def should_yield(self, client, session_id):
        """Return Stop-hook ownership for this store's exact checkout."""
        return _should_yield_root(
            self.state_dir, str(self.repo),
            _validate_client(client), _validate_uuid(session_id, "session_id"))


def _should_yield_root(base, repo, client, session_id):
    try:
        _check_no_symlinks(base)
    except ValueError:
        return False
    if base.is_symlink() or not base.is_dir():
        return False
    try:
        packages = base.iterdir()
        for package in packages:
            manifest_path = package / "manifest.json"
            if package.is_symlink() or not package.is_dir() or manifest_path.is_symlink():
                continue
            try:
                manifest = _read_json_file(manifest_path)
            except ValueError:
                continue
            if not isinstance(manifest, dict):
                continue
            state = manifest.get("state")
            source = manifest.get("source")
            receiver = manifest.get("receiver")
            source_match = (isinstance(source, dict)
                            and (source.get("client"), source.get("session_id")) == (
                                client, session_id)
                            and state in ACCEPTED_STATES)
            receiver_match = (state == "returned" and isinstance(receiver, dict)
                              and (receiver.get("client"), receiver.get("session_id")) == (
                                  client, session_id))
            if not source_match and not receiver_match:
                continue
            try:
                _validate_manifest_data(
                    manifest, repo=repo, state_dir=base, expected_id=package.name)
            except (OSError, ValueError, TypeError):
                continue
            if source_match or receiver_match:
                return True
    except OSError:
        return False
    return False


def should_yield(client, session_id, *, repo, state_dir=None):
    """Return Stop-hook ownership for one checkout without creating state."""
    client = _validate_client(client)
    session_id = _validate_uuid(session_id, "session_id")
    repo = Path(repo).resolve()
    if state_dir is None:
        repo_key = hashlib.sha256(str(repo).encode("utf-8")).hexdigest()
        root = _state_base() / repo_key
    else:
        root = Path(os.path.abspath(state_dir))
    return _should_yield_root(root, str(repo), client, session_id)
