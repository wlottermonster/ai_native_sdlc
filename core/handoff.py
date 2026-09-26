#!/usr/bin/env python3.12
"""Stable JSON command line interface for interactive SDLC handoffs."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import stat
import sys
import uuid


CORE = Path(__file__).resolve().parent
if str(CORE) not in sys.path:
    sys.path.insert(0, str(CORE))
import handoff_runtime as runtime  # noqa: E402


CLIENTS = ("codex", "claude")
EFFORTS = tuple(sorted(runtime.EFFORTS))
ROLES = tuple(sorted(runtime.ROLES))


def _session(value):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as exc:
        raise argparse.ArgumentTypeError("session must be a UUID") from exc
    return str(parsed)


def _read_file(filename, limit, label):
    path = Path(filename)
    try:
        info = path.stat()
    except OSError as exc:
        raise ValueError(label + " file cannot be read: " + str(path)) from exc
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(label + " file must be a regular file")
    if info.st_size > limit:
        raise ValueError(f"{label} file exceeds {limit} bytes")
    try:
        data = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ValueError(label + " file must be readable UTF-8") from exc
    if not data.strip():
        raise ValueError(label + " file is empty")
    return data


def _add_identity(parser):
    parser.add_argument("--client", choices=CLIENTS, required=True)
    parser.add_argument("--session", type=_session, required=True)


def _add_reconciliation(parser):
    parser.add_argument("--allow-changed", action="store_true")
    parser.add_argument("--reconcile-reason")


def build_parser():
    parser = argparse.ArgumentParser(prog="handoff")
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--home", type=Path, default=Path.home())
    commands = parser.add_subparsers(dest="command", required=True)

    prepare = commands.add_parser("prepare")
    prepare.add_argument("--source-client", choices=CLIENTS, required=True)
    prepare.add_argument("--source-session", type=_session, required=True)
    prepare.add_argument("--source-surface", choices=("cli", "app"), required=True)
    prepare.add_argument("--to", choices=CLIENTS, required=True)
    prepare.add_argument("--phase", required=True)
    prepare.add_argument("--role", choices=ROLES)
    prepare.add_argument("--task", required=True)
    prepare.add_argument("--context-file", type=Path, required=True)
    prepare.add_argument("--model")
    prepare.add_argument("--effort", choices=EFFORTS)

    accept = commands.add_parser("accept")
    accept.add_argument("id")
    _add_identity(accept)
    accept.add_argument("--observed-model")
    accept.add_argument("--observed-effort")
    _add_reconciliation(accept)

    progress = commands.add_parser("progress")
    progress.add_argument("id")
    _add_identity(progress)
    progress.add_argument("--file", type=Path, required=True)

    handback = commands.add_parser("handback")
    handback.add_argument("id")
    _add_identity(handback)
    handback.add_argument("--file", type=Path, required=True)

    ack = commands.add_parser("ack")
    ack.add_argument("id")
    _add_identity(ack)
    ack.add_argument("--file", type=Path, required=True)
    _add_reconciliation(ack)

    cancel = commands.add_parser("cancel")
    cancel.add_argument("id")
    _add_identity(cancel)
    cancel.add_argument("--reason", required=True)
    cancel.add_argument("--receiver-stopped", action="store_true", required=True)

    status = commands.add_parser("status")
    status.add_argument("id", nargs="?")

    launch = commands.add_parser("launch")
    launch.add_argument("id")
    launch.add_argument("--return", dest="return_trip", action="store_true")
    launch.add_argument("--mode", choices=("print", "terminal", "exec"), default="print")

    cleanup = commands.add_parser("cleanup")
    cleanup.add_argument("id")

    retire = commands.add_parser("retire")
    retire.add_argument("id")

    yield_check = commands.add_parser("yield-check")
    _add_identity(yield_check)
    return parser


def _store_module():
    import handoff_store
    return handoff_store


def _validate_reconciliation(args):
    reason = getattr(args, "reconcile_reason", None)
    if args.allow_changed and (not isinstance(reason, str) or not reason.strip()):
        raise ValueError("--allow-changed requires non-empty --reconcile-reason")
    if reason and not args.allow_changed:
        raise ValueError("--reconcile-reason requires --allow-changed")


def execute(args, store_module):
    if args.command == "yield-check":
        should_yield = store_module.should_yield(
            args.client, args.session, repo=args.repo, state_dir=args.state_dir)
        return {"should_yield": bool(should_yield)}, 0 if should_yield else 1

    store = store_module.Store(args.repo, state_dir=args.state_dir)
    if args.command == "prepare":
        assignment = runtime.resolve_assignment(
            args.to, args.phase, args.home, model=args.model, effort=args.effort, role=args.role)
        source = {"client": args.source_client, "session_id": args.source_session,
                  "surface": args.source_surface}
        target = {"client": args.to, "model": assignment["model"], "effort": assignment["effort"]}
        result = store.prepare(source=source, target=target, phase=args.phase,
                               task=args.task, briefing=_read_file(args.context_file, 32 * 1024, "context"))
        result = dict(result)
        result["role"] = assignment["role"]
        return result, 0
    if args.command == "accept":
        _validate_reconciliation(args)
        return store.accept(
            args.id, client=args.client, session_id=args.session,
            observed_model=args.observed_model, observed_effort=args.observed_effort,
            allow_changed=args.allow_changed,
            reconcile_reason=args.reconcile_reason), 0
    if args.command == "progress":
        return store.progress(args.id, client=args.client, session_id=args.session,
                              text=_read_file(args.file, 128 * 1024, "progress")), 0
    if args.command == "handback":
        return store.handback(args.id, client=args.client, session_id=args.session,
                              summary=_read_file(args.file, 64 * 1024, "return")), 0
    if args.command == "ack":
        _validate_reconciliation(args)
        return store.acknowledge(
            args.id, client=args.client, session_id=args.session,
            summary=_read_file(args.file, 16 * 1024, "acknowledgment"),
            allow_changed=args.allow_changed,
            reconcile_reason=args.reconcile_reason), 0
    if args.command == "cancel":
        if not args.reason.strip():
            raise ValueError("cancellation reason is empty")
        return store.cancel(args.id, client=args.client, session_id=args.session,
                            reason=args.reason, receiver_stopped=args.receiver_stopped), 0
    if args.command == "status":
        return (store.load(args.id) if args.id else store.status()), 0
    if args.command == "launch":
        manifest = store.load(args.id)
        plan = runtime.build_launch(manifest, return_trip=args.return_trip, runtime_path=Path(__file__))
        return runtime.launch(plan, args.mode), 0
    if args.command == "cleanup":
        return store.cleanup(args.id), 0
    if args.command == "retire":
        return store.retire(args.id), 0
    raise ValueError("unknown command")


def main(argv=None, *, store_module=None):
    args = build_parser().parse_args(argv)
    store_module = store_module or _store_module()
    try:
        result, code = execute(args, store_module)
    except (OSError, ValueError) as exc:
        print(json.dumps({"error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
