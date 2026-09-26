# Original implementation design

Shared Python standard-library components:
- core/handoff_store.py: private versioned packages, repository snapshot, flock,
  atomic writes, state guards, single active checkout ownership, safe cleanup.
- core/handoff_runtime.py: phase-to-role resolution using explicit target adapter
  maps; native CLI capabilities; safe new/resume argument vectors; interactive
  current-terminal execution and macOS new-Terminal launch, printable fallback.
- core/handoff.py: CLI orchestration and stable JSON results, receiving prompts.
- adapters/codex/skills/handoff and handback plus Claude native skills:
  model writes semantic briefing/return; helpers handle deterministic state.

Store is outside Git at ~/.local/state/ainative-sdlc/handoffs/<repo-path-hash>/.
Per transfer: manifest.json, start.md, progress.md, return.md, closed-summary.md.
Creation is private, immutable start hashed in manifest, no transcript copying.
States: prepared -> active -> returned -> closed. Explicit source reclaim can
mark a nonterminal package cancelled, only with reason and receiver_stopped=true;
it does not kill a process. Cancelled packages remain recoverable and are not
automatically cleaned. New prepare is allowed after closed/cancelled. Each transition is an explicit
acknowledgment; launch attempts are metadata, not completion. Failed launches
remain prepared/returned. 'Closed' includes source acknowledgment; cleanup then
removes only start/progress/return, never manifest or closed-summary. Keep usage
as unknown unless supplied by verified native evidence. Do not aggregate costs.

Store API for CLI integration (keyword arguments):
Store(repo, state_dir=None)
prepare(source, target, phase, task, briefing) -> manifest
load(id) -> manifest
accept(id, client, session_id, observed_model=None, observed_effort=None,
       allow_changed=False, reconcile_reason=None) -> manifest
progress(id, client, session_id, text) -> manifest
handback(id, client, session_id, summary) -> manifest
acknowledge(id, client, session_id, summary, allow_changed=False, reconcile_reason=None) -> manifest
cancel(id, client, session_id, reason, receiver_stopped=False) -> manifest
cleanup(id) -> manifest
status() -> list[manifest]
should_yield(client, session_id) -> bool (read-only, checkout-scoped)
Manifest has id, schema_version, repo, phase, task, source, target, state,
created_at, updated_at, snapshot, receiver and artifact paths. IDs UUIDs.
Source has client (codex|claude), session_id (UUID), surface (cli|app).
Target has client/model/effort (model/effort may be null for inherit).
Receiver identity is checked on progress/return; source identity on acknowledge.
Default state_dir resolves private user state per repo; provided state_dir is an
exact root for tests and explicit portable storage. Refuse symlink ancestors.
Snapshot includes current branch/HEAD and Git-visible content fingerprint. Dirty
work is preserved, not committed/reset. Acceptance detects changes since prepare;
allow_changed is explicit owner reconciliation, never automatic.
Return snapshot captures actual state so source can detect changes before ack.

CLI (global --repo, --state-dir, --home):
prepare --source-client --source-session --source-surface --to --phase --task
        --context-file [--role] [--model] [--effort]
accept ID --client --session [--observed-model] [--observed-effort] [--allow-changed --reconcile-reason TEXT]
progress ID --client --session --file
handback ID --client --session --file
ack ID --client --session --file [--allow-changed --reconcile-reason TEXT]
cancel ID --client --session --reason --receiver-stopped
status [ID]
launch ID [--return] [--mode print|terminal|exec] (print default)
cleanup ID
yield-check --client --session (exit0 true, exit1 false, exit2 invalid)

Launch phase prints safe argv+cwd+manual command and receiver prompt. Runtime
owns constructing a prompt that names the exact packet and accept/ack helper.
Interactive exec must require a TTY; terminal launches separate macOS Terminal
using argument-safe AppleScript, no nested blocking headless session disguised as
interactive. Source remains available; skill ends turn immediately after transfer.
Return to an app task uses exposed host send/open tools when available and source
surface=app; unsupported navigation reports prepared manual CLI resume fallback.
Source cannot be 'resumed' until it acknowledges the return file.

Codex uses global roles/reasoning TOML. Claude uses first model from its global
sdlc-engines.conf; no fallback chain execution. Claude effort omitted unless
explicitly supplied or configured in optional sdlc-handoff.toml [reasoning].
Phase map: plan/design/spec->judge, build/implement/debug->build,
review/verify/test/audit->verify, research/read->read. Escalate requires explicit
phase selection. Keep names generic; no model IDs in project rules.

Ruling from spec review: source acknowledgment checks the return snapshot; explicit
allow-changed requires the owner to reconcile changed repository state. Cancellation
is explicit source-owned recovery after the receiver has stopped, not silent TTL
expiry. No nested handoff in v1. Claude installs native local skills so its
CLAUDE_SESSION_ID substitution supplies exact identity, with no new global hook.

Additional review rulings: Stop hooks only suppress their continuation for the
exact yielded source session, or returned receiver; unrelated sessions retain
normal gates. Missing/malformed handoff state cannot exempt checks. The assigned
phase is the receiving task's phase; explicit --role overrides it. Context limit
32 KiB; cumulative progress 128 KiB; return 64 KiB; closure 16 KiB; reject oversize
before reading input files. Progress appends. CLI reconciliation requires a
reason and preserves the immutable original snapshot as evidence.

Claude receiver identity is assigned through native --session-id, deterministically
bound to the handoff UUID. The accept prompt uses that exact ID. If that native
session was created but exited before acceptance, recover with the printed exact
--resume command after confirming no live duplicate. Codex reads CODEX_THREAD_ID.
Both manual commands and Terminal launch include the repository working directory.
The two Claude Stop entries are handoff-aware; only the exact framework requirement
Stop command is migrated to --stop, with settings backup and other entries retained.
Every yield/ack validates schema and required immutable/payload hashes. Corrupt
handoff helpers or state preserve normal gates rather than supplying an exemption.

Progress replacement journals previous/intended hashes before writing the file;
locked recovery chooses only one of those hashes and clears the intent. Cleanup
journals intent before deletion, permits partial deletion only in a closed record,
and remains retryable. Interrupted immutable handback/ack payloads are preserved;
explicit source cancellation after receiver stop reclaims ownership without
overwriting those artifacts. No raw transcript copying or private database edits.
