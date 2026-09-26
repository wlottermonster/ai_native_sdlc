# Durable loops and handoffs

The helper is `~/.codex/sdlc-openai/scripts/sdlc.py`; use python3.12.
Commands run from the project root, or supply `--repo /absolute/path` before
the subcommand. Give each feature a unique short lowercase run name.

```sh
python3.12 ~/.codex/sdlc-openai/scripts/sdlc.py begin login-fix 'Correct login expiry' --budget 12
python3.12 ~/.codex/sdlc-openai/scripts/sdlc.py status login-fix
python3.12 ~/.codex/sdlc-openai/scripts/sdlc.py check login-fix -- make check
python3.12 ~/.codex/sdlc-openai/scripts/sdlc.py record login-fix failure --failure 'expired-session test rejects refresh' --next 'Inspect refresh expiry calculation'
python3.12 ~/.codex/sdlc-openai/scripts/sdlc.py record login-fix progress --next 'Run the behavior suite and inspect the diff'
python3.12 ~/.codex/sdlc-openai/scripts/sdlc.py check login-fix -- sh -c 'make check && make test'
python3.12 ~/.codex/sdlc-openai/scripts/sdlc.py record login-fix complete
```

These are examples, not commands to execute for every task. Use the project's
actual commands. The last evidence must cover the full completion contract; use
one combined command for multiple required checks. The helper records exit code,
duration, command and a log; use non-secret commands because output is persisted.
It hashes current project files, rejecting completion if they changed after the
passing run. The runtime state is excluded from that hash. Git-ignored files are
not fingerprinted; don't use ignored source as the basis of a completion claim.

Record each meaningful iteration after its result. A check alone records evidence,
not an iteration. Three matching consecutive failure signatures or the attempt
budget stop the run. Do not change signatures to evade a stop. Inspect the cause,
save what was learned and tell the user the recovery needed. Use `blocked` with
`--failure` and `--next` for an external blocker. Never restart silently.

Keep `.sdlc-openai/` local (add to the project's Git exclude only when authorized).
For durable team handoffs, also write `specs/<feature>/handoff.md` with objective,
approved scope, branch/worktree, changed paths, test command/result/log location,
open questions, next action, and the run-state path. Store no credentials.
