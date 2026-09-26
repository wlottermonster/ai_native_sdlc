#!/bin/bash
# AI-Native SDLC — definition-of-done (Stop hook).
# A session may not end while it has left the working tree failing its checks.
# Exit 2 = the turn continues and the model must keep fixing.
#
# RULE — a hook that outlives its timeout does NOT block. This gate keeps its
# own clock (REQ-GATE-005): it reads the timeout its Stop entry carries, stops
# the checks before that deadline, and refuses to let the turn end when they
# did not finish. A loud refusal, never a silent allow.
set -u
input=$(cat)

GATE_MARGIN=30

# Loop guard: if we already blocked once this stop, let it through (Claude Code
# sets stop_hook_active on the retry) — prevents infinite block loops.
if command -v jq >/dev/null 2>&1 \
   && echo "$input" | jq -e '.stop_hook_active == true' > /dev/null 2>&1; then
  exit 0
fi

top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0   # not a repo → allow
# A gate that cannot reach the repo must not ALLOW. `git rev-parse` proved this
# is a repo; if the cd still fails, something is wrong with the path, not with
# the session — say so rather than letting the session end unchecked.
cd "$top" || {
  echo "definition-of-done check: could not enter the repository root:" >&2
  echo "  $top" >&2
  echo "A directory can exist and still refuse cd. Not allowing the session to" >&2
  echo "end on an unverified tree — fix the path and try again." >&2
  exit 2
}
# A prepared handoff explicitly yields this session's work to another client.
# Missing identity/state or a failed helper preserves the normal Stop gate.
if command -v jq >/dev/null 2>&1 && command -v python3.12 >/dev/null 2>&1; then
  handoff_session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
  handoff_helper="$HOME/.claude/scripts/handoff.py"
  if [ -n "$handoff_session" ] && [ -r "$handoff_helper" ] && \
     python3.12 "$handoff_helper" --repo "$top" yield-check --client claude --session "$handoff_session" >/dev/null 2>&1; then
    exit 0
  fi
fi
# clean tree → allow (tracked changes AND untracked new files both count as dirty)
if git diff --quiet HEAD -- 2>/dev/null \
   && [ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
  exit 0
fi
# Docs-only changes don't warrant a test gate (cost-aware: a gate that fires on
# every docs edit is a gate you learn to ignore). Prose by EXTENSION, the same
# rule as check-gate.sh (REQ-GATE-013): a script under docs/ is still code.
changed=$({ git diff --name-only HEAD -- 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u)
if [ -n "$changed" ] && ! echo "$changed" | grep -qvE '\.(md|txt|rst|html?)$'; then
  exit 0
fi
# Present is not readable (REQ-GATE-013): a Makefile the gate cannot open is not
# "no contract" — it is a contract the gate could not verify, so the turn does
# not end.
if [ -f Makefile ] && [ ! -r Makefile ]; then
  {
    echo "CANNOT STOP: the working tree has uncommitted changes and the Makefile cannot be read,"
    echo "so the checks could not be found, let alone run:"
    echo "  $PWD/Makefile"
  } >&2
  exit 2
fi
# same contract fallbacks as check-gate.sh — a Node or bare-pytest repo must be
# gated at Stop exactly as it is at commit
run_check() {
  if [ -f Makefile ] && grep -qE '^check:' Makefile; then
    make check
  elif [ -f package.json ] && command -v jq >/dev/null 2>&1 \
       && jq -e '.scripts.check' package.json > /dev/null 2>&1; then
    npm run --silent check
  elif [ -x .venv/bin/pytest ]; then
    .venv/bin/pytest -x -q
  else
    return 0   # no contract in this repo yet → allow
  fi
}

# --- the gate's own clock (REQ-GATE-005) ------------------------------------
# The same mechanism as check-gate.sh, read from this hook's own Stop entry:
# "<budget> <hook-timeout>", the harness default of 600 when unknown.
gate_clock() {
  local settings="$HOME/.claude/settings.json" t="" b
  if [ -r "$settings" ] && command -v jq >/dev/null 2>&1; then
    t=$(jq -r '[ .hooks.Stop[]? | .hooks[]?
                 | select(((.command // "") | tostring) | test("dod"))
                 | (.timeout // 600) ] | min // empty' "$settings" 2>/dev/null || true)
  fi
  case "$t" in ''|*[!0-9]*) t=600 ;; esac
  b=$((t - GATE_MARGIN))
  [ "$b" -lt 1 ] && b=1
  printf '%s %s\n' "$b" "$t"
}

GATE_EXPIRED=0
run_bounded() {
  local outfile="$1" rcfile="$2" budget="$3" pid waited=0
  set -m
  ( run_check; echo $? > "$rcfile" ) > "$outfile" 2>&1 &
  pid=$!
  set +m
  disown "$pid" 2>/dev/null
  # ends when the exit code is written OR the process is gone — a lingering
  # zombie can never make a finished check look like a hang
  while [ ! -s "$rcfile" ] && kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$budget" ]; then
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null
      GATE_EXPIRED=1
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

clock=$(gate_clock)
budget=${clock%% *}
hook_timeout=${clock##* }
outfile=$(mktemp "${TMPDIR:-/tmp}/sdlc-dod-out.XXXXXX") || {
  echo "CANNOT STOP: the definition-of-done check could not create a scratch file in ${TMPDIR:-/tmp}." >&2
  exit 2
}
rcfile="$outfile.rc"
run_bounded "$outfile" "$rcfile" "$budget"
out=$(cat "$outfile" 2>/dev/null)
rc=""   # stays empty when the kill left no exit-code file — that is by design, not an error
[ -f "$rcfile" ] && rc=$(tr -d '[:space:]' < "$rcfile" 2>/dev/null || true)
rm -f "$outfile" "$rcfile"

if [ "$GATE_EXPIRED" -eq 1 ]; then
  {
    echo "CANNOT STOP: the working tree has uncommitted changes and the checks did not finish"
    echo "inside the gate's budget of ${budget}s. The hook's timeout is ${hook_timeout}s, and a hook that"
    echo "times out does NOT block — so the gate stopped the checks ${GATE_MARGIN}s early and is refusing"
    echo "to end the turn on an unverified tree. Run the checks yourself (make check), then stop."
    echo "--- last 40 lines of output before the stop ---"
    echo "$out" | tail -40
  } >&2
  exit 2
fi
case "$rc" in ''|*[!0-9]*)
  {
    echo "CANNOT STOP: the checks ended without an exit code; the tree is unverified."
    [ -n "$out" ] && { echo "--- what the checks printed ---"; echo "$out" | tail -40; }
  } >&2
  exit 2 ;;
esac
if [ "$rc" -ne 0 ]; then
  {
    echo "CANNOT STOP: the working tree has uncommitted changes and the repo's"
    echo "checks are failing (exit $rc). Fix the failures or revert before ending the turn."
    echo "--- last 40 lines ---"
    echo "$out" | tail -40
  } >&2
  exit 2
fi
exit 0
