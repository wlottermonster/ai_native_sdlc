# Step 6 bounded hook reconciliation

Authority: approved portability-plan.md Step 6; owner R4 reviewer substitution.
Step 5 completed at 04831d0. No push-policy harmonization in this task.

Keep Claude check-gate, dod and session-engines in its adapter: their semantics
are Claude-specific. Recoverably retire only the three inactive copies under
~/.codex/hooks after scanning active global/project hook configuration references.
Keep other hooks, owner settings, engine maps and trust untouched.

Codex uses sdlc.py. Replace its arbitrary-text git/commit regex with a bounded
shell-command recognizer. Only standalone git [-C directory]* commit executes
make check. Recognized compound/wrapper commits return structured denial. Quoted
prose, filenames and other Git subcommands must not invoke the gate. Malformed
recognized commits deny cleanly. Recognize common env/command/shell -c wrappers
and executable command substitutions; do not build a full shell interpreter or
claim this convenience gate is a security boundary against arbitrary programs.

Preserve atomic_json and locked byte-for-byte. Replace the Step 5 whole-runtime
hash assertion with meaningful preservation evidence for these functions and the
unchanged durable state/check machinery. The original manifest remains immutable;
update destination disposition only for reviewed Step 6 changes.

Retain 240-second internal check / 270-second host budgets, with their 30-second
margin. Measure representative make check durations and test timeout denial using
a short mocked/injected result. Do not claim unmeasured project coverage.

Preserve actual schemas: Codex SessionStart additionalContext; PostCompact common
systemMessage; Stop top-level decision/reason and one-continuation guard. No change
to Claude schemas in this task. Record actual-host probes separately from unit
schemas; unavailable host events are explicit validation limits.

## Acceptance and tests

- Unrelated: git diff -- pre-commit; git diff -- commit; echo 'git commit';
  quoted punctuation/prose; status/read tools. No make check invoked.
- Standalone commit and repeated -C: resolve cwd, run check once. Missing/failed
  contract and timeout deny; passing permits.
- Recognized commits after semicolon, &&, pipe or newline, env/command/absolute
  Git/shell -c wrappers and unsupported Git options: deny. Substitution is execution,
  not quoted prose. Malformed quoting produces valid structured denial.
- Crash-safety/concurrency functions unchanged; previous state-machine and hook
  output tests retained. Both suite targets pass.
- Real Codex failing/passing commit and unrelated-tool probes in a disposable repo;
  startup/Stop/compaction acceptance where the host permits observation. Retain
  prior real Claude startup evidence and report quota limitation honestly.

## Work ownership and rulings

Fresh implementer owns runtime and Python regression tests. Root owns host checks,
dead-copy retirement, destination manifest refresh, installation, docs and backup.
Fresh reviewer inspects final source and host evidence; implementer cannot certify.
No concurrent source ownership. Existing task branch isolates this from main.

Ruling: retain the two distinct enforcement designs instead of making shell hooks
harness-neutral. Rewriting Claude payload/routing semantics adds risk without a
capability benefit; Codex already has the independently tested Python mechanism.
