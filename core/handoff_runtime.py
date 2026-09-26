"""Native routing and interactive process plans for SDLC handoffs."""
from __future__ import annotations

import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tomllib
import uuid


PHASE_ROLES = {
    "plan": "judge", "design": "judge", "spec": "judge",
    "build": "build", "implement": "build", "debug": "build",
    "review": "verify", "verify": "verify", "test": "verify", "audit": "verify",
    "research": "read", "read": "read", "escalate": "escalate",
}
ROLES = {"judge", "build", "verify", "read", "escalate"}
EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*\Z")


def _clean_choice(value, label, allowed=None):
    if value is None:
        return None
    if not isinstance(value, str) or not value or not IDENTIFIER.fullmatch(value):
        raise ValueError("invalid " + label)
    if allowed is not None and value not in allowed:
        raise ValueError("unknown " + label + ": " + value)
    return value


def _required_choice(value, label, allowed=None):
    value = _clean_choice(value, label, allowed)
    if value is None:
        raise ValueError(label + " is missing")
    return value


def _session_id(value, label):
    if not isinstance(value, str):
        raise ValueError(label + " is missing or invalid")
    try:
        parsed = uuid.UUID(value)
    except ValueError as exc:
        raise ValueError(label + " is missing or invalid") from exc
    if str(parsed) != value.lower():
        raise ValueError(label + " is missing or invalid")
    return str(parsed)


def _codex_map(home):
    path = Path(home) / ".codex" / "sdlc-openai" / "engines.toml"
    try:
        value = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, tomllib.TOMLDecodeError) as exc:
        raise ValueError("Codex role map is missing or invalid: " + str(path)) from exc
    if set(value) - {"roles", "reasoning", "agents"}:
        raise ValueError("Codex role map has an unknown section")
    roles = value.get("roles")
    reasoning = value.get("reasoning", {})
    if not isinstance(roles, dict) or not isinstance(reasoning, dict):
        raise ValueError("Codex role map requires roles and reasoning tables")
    parsed = {}
    for role, model in roles.items():
        _clean_choice(role, "role", ROLES)
        _clean_choice(model, "model")
        effort = reasoning.get(role)
        if model == "inherit":
            if effort is not None:
                _clean_choice(effort, "effort", EFFORTS)
            parsed[role] = (None, None)
        else:
            if effort is None:
                raise ValueError("explicit Codex model requires reasoning effort: " + role)
            parsed[role] = (model, _clean_choice(effort, "effort", EFFORTS))
    for role in reasoning:
        if role not in roles:
            raise ValueError("reasoning refers to unknown role: " + role)
    return parsed


def _claude_map(home):
    path = Path(home) / ".claude" / "sdlc-engines.conf"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValueError("Claude role map is missing or invalid: " + str(path)) from exc
    parsed = {}
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.count("=") != 1:
            raise ValueError(f"invalid Claude role map line {number}")
        role, models = (part.strip() for part in line.split("=", 1))
        _clean_choice(role, "role", ROLES)
        choices = [part.strip() for part in models.split(",")]
        if not choices or any(not part for part in choices):
            raise ValueError(f"invalid Claude role map line {number}")
        for choice in choices:
            _clean_choice(choice, "model")
        if role in parsed:
            raise ValueError("duplicate Claude role: " + role)
        # Handoff deliberately selects only the configured primary. It never
        # executes the legacy fallback chain silently.
        parsed[role] = [None if choices[0] == "inherit" else choices[0], None]

    effort_path = Path(home) / ".claude" / "sdlc-handoff.toml"
    if effort_path.exists():
        try:
            value = tomllib.loads(effort_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, tomllib.TOMLDecodeError) as exc:
            raise ValueError("Claude handoff reasoning map is invalid: " + str(effort_path)) from exc
        if set(value) - {"reasoning"} or not isinstance(value.get("reasoning", {}), dict):
            raise ValueError("Claude handoff map supports only [reasoning]")
        for role, effort in value.get("reasoning", {}).items():
            _clean_choice(role, "role", ROLES)
            if role not in parsed:
                raise ValueError("reasoning refers to unknown role: " + role)
            configured = _clean_choice(effort, "effort", EFFORTS)
            if parsed[role][0] is not None:
                parsed[role][1] = configured
    return {role: tuple(values) for role, values in parsed.items()}


def resolve_assignment(client, phase, home, *, model=None, effort=None, role=None):
    """Resolve only explicit phase/role metadata against the destination map."""
    client = _required_choice(client, "client", {"codex", "claude"})
    phase = _required_choice(phase, "phase", set(PHASE_ROLES))
    selected_role = _clean_choice(role, "role", ROLES) if role else PHASE_ROLES[phase]
    mapping = _codex_map(home) if client == "codex" else _claude_map(home)
    if selected_role not in mapping:
        raise ValueError(f"{client} role map has no {selected_role} assignment")
    default_model, default_effort = mapping[selected_role]
    selected_model = _clean_choice(model, "model") if model is not None else default_model
    selected_effort = _clean_choice(effort, "effort", EFFORTS) if effort is not None else default_effort
    return {"role": selected_role, "model": selected_model, "effort": selected_effort}


def _state_root(manifest):
    start = Path(manifest["artifacts"]["start"])
    return start.parent.parent


def _command_in_repo(repo, argv):
    return "cd " + shlex.quote(repo) + " && " + shlex.join(argv)


def _claude_receiver_session_id(handoff_id):
    try:
        package_id = uuid.UUID(handoff_id)
    except (ValueError, AttributeError) as exc:
        raise ValueError("handoff id is missing or invalid") from exc
    return str(uuid.uuid5(package_id, "claude-receiver"))


def _receiver_prompt(manifest, runtime_path, client, *, receiver_session_id=None,
                     recovery_command=None):
    state_root = _state_root(manifest)
    if client == "codex":
        identity_source = "Use the exact CODEX_THREAD_ID value exposed to this Codex session."
        accept_session = "ACTUAL_SESSION_UUID"
    else:
        if receiver_session_id is None or recovery_command is None:
            raise ValueError("Claude receiver session identity is missing")
        identity_source = "Use the exact session UUID assigned by this launch: " + receiver_session_id
        accept_session = receiver_session_id
    lines = [
        f"Receive interactive handoff {manifest['id']}.",
        f"Repository: {manifest['repo']}",
        f"State directory: {state_root}",
        f"Read the immutable briefing first: {manifest['artifacts']['start']}",
        "Before doing any work, accept this exact handoff using your actual native session UUID:",
        identity_source,
        shlex.join(["python3.12", str(runtime_path), "--repo", manifest["repo"],
                    "--state-dir", str(state_root), "accept", manifest["id"],
                    "--client", client, "--session", accept_session]),
        "Continue interactively with the owner. Record durable progress and use handback when returning ownership.",
    ]
    if client == "claude":
        lines += [
            "Recovery applies only if this launched Claude process exited before acceptance.",
            "Confirm it is no longer live; do not start a duplicate live session.",
            "Resume the same session with: " + recovery_command,
        ]
    return "\n".join(lines)


def _return_prompt(manifest, runtime_path, client, session_id):
    state_root = _state_root(manifest)
    return "\n".join([
        f"Receive returned handoff {manifest['id']}.",
        f"Repository: {manifest['repo']}",
        f"State directory: {state_root}",
        f"Read the return package first: {manifest['artifacts']['return']}",
        f"Read the receiver progress record too: {manifest['artifacts']['progress']}",
        "Before making any further project edits, verify the returned repository state and acknowledge this exact package:",
        shlex.join(["python3.12", str(runtime_path), "--repo", manifest["repo"],
                    "--state-dir", str(state_root), "ack", manifest["id"],
                    "--client", client, "--session", session_id,
                    "--file", "ACKNOWLEDGMENT_FILE"]),
        "After ack reports the handoff closed, run cleanup for this handoff, then continue interactively with the owner.",
    ])


def build_launch(manifest, *, return_trip=False, runtime_path=None):
    """Build a launch description without changing package state."""
    runtime_path = Path(runtime_path or Path(__file__).with_name("handoff.py")).resolve()
    # The store records the canonical repository identity. Preserve it exactly
    # so prompts, cwd and state freshness checks all name the same checkout.
    repo = manifest["repo"]
    if return_trip:
        if manifest.get("state") != "returned":
            raise ValueError("return launch requires a returned handoff")
        source = manifest.get("source")
        if not isinstance(source, dict):
            raise ValueError("source identity is missing")
        client = _required_choice(source.get("client"), "source client", {"codex", "claude"})
        session_id = _session_id(source.get("session_id"), "source session identity")
        prompt = _return_prompt(manifest, runtime_path, client, session_id)
        if client == "codex":
            argv = ["codex", "resume", session_id, "-C", repo, prompt]
        elif client == "claude":
            argv = ["claude", "--resume", session_id, prompt]
        else:
            raise ValueError("unknown source client")
        source_surface = _required_choice(source.get("surface"), "source surface", {"cli", "app"})
        delivery = "host_native_required" if source_surface == "app" else "cli_resume"
    else:
        if manifest.get("state") != "prepared":
            raise ValueError("receiver launch requires a prepared handoff")
        target = manifest.get("target")
        if not isinstance(target, dict):
            raise ValueError("target selection is missing")
        client = _required_choice(target.get("client"), "target client", {"codex", "claude"})
        model = _clean_choice(target.get("model"), "target model")
        effort = _clean_choice(target.get("effort"), "target effort", EFFORTS)
        recovery_argv = None
        recovery_command = None
        receiver_session_id = None
        if client == "claude":
            receiver_session_id = _claude_receiver_session_id(manifest.get("id"))
            recovery_argv = ["claude", "--resume", receiver_session_id]
            recovery_command = _command_in_repo(repo, recovery_argv)
        prompt = _receiver_prompt(
            manifest, runtime_path, client, receiver_session_id=receiver_session_id,
            recovery_command=recovery_command)
        if client == "codex":
            argv = ["codex", "-C", repo]
            if model is not None:
                argv += ["-m", model]
            if effort is not None:
                argv += ["-c", "model_reasoning_effort=" + json.dumps(effort)]
            argv.append(prompt)
        elif client == "claude":
            argv = ["claude", "--session-id", receiver_session_id]
            if model is not None:
                argv += ["--model", model]
            if effort is not None:
                argv += ["--effort", effort]
            argv.append(prompt)
        else:
            raise ValueError("unknown target client")
        delivery = "new_session"
    plan = {
        "id": manifest["id"], "client": client, "argv": argv, "cwd": repo,
        "prompt": prompt, "manual_command": _command_in_repo(repo, argv),
        "delivery": delivery,
    }
    if not return_trip and client == "claude":
        plan["receiver_session_id"] = receiver_session_id
        plan["recovery_argv"] = recovery_argv
        plan["recovery_command"] = recovery_command
    if return_trip and source_surface == "app":
        plan["host_delivery"] = {
            "action": "send_and_navigate", "task_id": session_id, "prompt": prompt,
        }
        plan["fallback"] = "manual_cli_resume"
    return plan


def preflight(client, *, which=shutil.which, run=subprocess.run):
    """Check only executable presence and documented flags; never inspect auth."""
    client = _required_choice(client, "client", {"codex", "claude"})
    binary = which(client)
    if not binary:
        return {"client": client, "supported": False, "reason": client + " executable not found"}
    try:
        run([binary, "--version"], capture_output=True, text=True, timeout=3, check=True)
        help_result = run([binary, "--help"], capture_output=True, text=True, timeout=3, check=True)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"client": client, "supported": False, "reason": "client capability check failed: " + type(exc).__name__}
    help_text = (help_result.stdout or "") + (help_result.stderr or "")
    flags = ("resume", "-C", "-m", "-c") if client == "codex" else (
        "--resume", "--session-id", "--model", "--effort")
    missing = [flag for flag in flags if flag not in help_text]
    if missing:
        return {"client": client, "supported": False, "reason": "client help lacks required launch controls"}
    return {"client": client, "supported": True, "reason": None}


def _base_result(plan, status):
    result = {
        "id": plan["id"], "status": status, "client": plan["client"],
        "argv": plan["argv"], "cwd": plan["cwd"], "prompt": plan["prompt"],
        "manual_command": plan["manual_command"], "delivery": plan["delivery"],
        "observed_model": None, "observed_effort": None, "usage": None,
    }
    for key in ("host_delivery", "fallback", "receiver_session_id",
                "recovery_argv", "recovery_command"):
        if key in plan:
            result[key] = plan[key]
    return result


def launch(plan, mode="print"):
    """Print or start an interactive native client; launching never accepts."""
    if mode == "print":
        return _base_result(plan, "ready")
    if mode not in {"terminal", "exec"}:
        raise ValueError("unknown launch mode")
    capability = preflight(plan["client"])
    if not capability["supported"]:
        result = _base_result(plan, "manual_fallback")
        result["reason"] = capability["reason"]
        return result
    if mode == "exec":
        if not sys.stdin.isatty() or not sys.stdout.isatty():
            raise ValueError("exec launch requires an interactive TTY")
        result = _base_result(plan, "process_exited")
        result["exit_code"] = subprocess.call(plan["argv"], cwd=plan["cwd"])
        return result
    if sys.platform != "darwin" or shutil.which("osascript") is None:
        result = _base_result(plan, "manual_fallback")
        result["reason"] = "separate Terminal launch is unavailable on this host"
        return result
    command = plan["manual_command"]
    script = [
        "osascript", "-e", "on run argv",
        "-e", 'tell application "Terminal" to do script (item 1 of argv)',
        "-e", 'tell application "Terminal" to activate',
        "-e", "end run", command,
    ]
    try:
        completed = subprocess.run(script, capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        result = _base_result(plan, "manual_fallback")
        result["reason"] = "Terminal launch failed: " + type(exc).__name__
        return result
    if completed.returncode != 0:
        result = _base_result(plan, "manual_fallback")
        result["reason"] = "Terminal launch failed"
        return result
    return _base_result(plan, "terminal_started")
