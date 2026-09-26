#!/bin/bash
# AI-Native SDLC — requirement coverage gates.
# Gate A (always, once tasks.md exists): every non-deferred REQ-ID in
#   requirements.md must appear in tasks.md.  Missing → exit 2 (block).
# Gate B (only when a feature CLAIMS completion, i.e. tasks.md has no
#   unchecked boxes): every non-deferred REQ-ID must appear in at least one
#   test file.  Missing → exit 2 (block).
# Mid-flight commits of partial work are never blocked by Gate B.
# Usage: as a hook (reads+drains stdin) or manually: req-gate.sh [--report]
set -u
mode="${1:-enforce}"
# Only the explicit Stop adapter consumes the hook payload. Manual/commit
# requirements enforcement never inherits handoff exemptions.
if [ "$mode" = "--stop" ]; then
  input=$(cat)
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
  if command -v jq >/dev/null 2>&1 && command -v python3.12 >/dev/null 2>&1; then
    handoff_session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
    handoff_helper="$HOME/.claude/scripts/handoff.py"
    if [ -n "$handoff_session" ] && [ -r "$handoff_helper" ] && \
       python3.12 "$handoff_helper" --repo "$top" yield-check --client claude --session "$handoff_session" >/dev/null 2>&1; then
      exit 0
    fi
  fi
  mode=enforce
fi
exec < /dev/null

top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
# Same rule as the other gates: cannot reach the repo is not a reason to allow.
cd "$top" || {
  echo "requirement gate: could not enter the repository root:" >&2
  echo "  $top" >&2
  echo "A directory can exist and still refuse cd. Reporting rather than" >&2
  echo "allowing silently — but NOT exit 2: this script drains stdin, so it" >&2
  echo "cannot read stop_hook_active, and a blocking exit from a Stop hook on" >&2
  echo "a condition the model cannot fix would have no loop break." >&2
  exit 1
}
# Presence is not readability — the same class this run is closing. An
# unreadable specs/ made the glob yield nothing, fail stayed 0, and the
# coverage gate passed silently having read nothing at all.
if [ -d specs ] && [ ! -r specs ]; then
  echo "requirement gate: specs/ exists but is not readable — coverage was" >&2
  echo "  not checked. Reporting rather than passing silently." >&2
  exit 1
fi
[ -d specs ] || exit 0
# The same rule one level down (REQ-GATE-019): a feature directory the glob
# cannot enter, or a requirements.md / tasks.md that cannot be opened, used to
# yield "no IDs here" and the feature was skipped as if it had none. Listing a
# directory needs r, reaching the files in it needs x; both are tested.
unread=""
[ -x specs ] || unread+="  specs/ (cannot be searched)"$'\n'
for d in specs/*/; do
  [ -d "$d" ] || continue
  if [ ! -r "$d" ] || [ ! -x "$d" ]; then
    unread+="  ${d%/} (directory cannot be read)"$'\n'
    continue
  fi
  for f in requirements.md tasks.md; do
    if [ -e "$d$f" ] && [ ! -r "$d$f" ]; then unread+="  $d$f"$'\n'; fi
  done
done
if [ -n "$unread" ]; then
  {
    echo "requirement gate: coverage was not checked — these cannot be read:"
    printf '%s' "$unread"
    echo "  Reporting rather than passing silently."
  } >&2
  exit 1
fi

# real test files only: test dirs or test-shaped basenames — NOT anything whose
# path merely contains "spec"/"test" (a docs/api-spec.md must never satisfy Gate B)
testfiles=$(git ls-files -co --exclude-standard 2>/dev/null \
  | grep -vE '^specs/' \
  | grep -E '(^|/)(tests?|__tests__)/|(^|/)test_[^/]*$|_test\.[^/.]+$|\.(test|spec)\.[^/.]+$' \
  | grep -vE '\.(md|txt|rst|html)$' || true)
fail=0
out=""

for req in specs/*/requirements.md; do
  [ -f "$req" ] || continue
  feat=$(basename "$(dirname "$req")")
  tasks="specs/$feat/tasks.md"
  ids=$(grep -oE 'REQ-[A-Z0-9-]+-[0-9]{3}' "$req" | sort -u)
  [ -n "$ids" ] || continue
  # an ID is deferred if its block carries "verify: deferred" before the next ID.
  # match() extracts the ID wherever it sits on the line (survives **bold**, bullets)
  deferred=$(awk 'match($0, /REQ-[A-Z0-9-]+-[0-9]{3}/){cur=substr($0,RSTART,RLENGTH)} /verify:[ ]*deferred/{if(cur!="") print cur}' "$req" | sort -u)

  for id in $ids; do
    if echo "$deferred" | grep -qx "$id"; then
      [ "$mode" = "--report" ] && out+="$feat $id DEFERRED"$'\n'
      continue
    fi
    # Gate A
    if [ -f "$tasks" ] && ! grep -q "$id" "$tasks"; then
      out+="GATE A: $id is in specs/$feat/requirements.md but has no task in $tasks"$'\n'
      fail=1
      continue
    fi
    # Gate B — only when the feature claims completion: no open [ ], claimed [~],
    # or parked [!] boxes remain (in-progress and parked are NOT complete)
    if [ -f "$tasks" ] && ! grep -qE '^[[:space:]]*- \[[ ~!]\]' "$tasks"; then
      covered=0
      if [ -n "$testfiles" ]; then
        # test output, not xargs exit code (which only reflects the last batch)
        [ -n "$(echo "$testfiles" | tr '\n' '\0' | xargs -0 grep -l -- "$id" 2>/dev/null)" ] && covered=1
      fi
      if [ "$covered" -eq 0 ]; then
        out+="GATE B: $feat claims completion but $id has no tagged test"$'\n'
        fail=1
      fi
    fi
    [ "$mode" = "--report" ] && out+="$feat $id OK"$'\n'
  done
done

if [ "$mode" = "--report" ]; then
  # drift check (report-only): REQ-IDs referenced by tests that no spec —
  # active or shipped — defines. Catches requirements deleted/renamed after
  # the code was written.
  specids=$(cat specs/*/requirements.md specs/_shipped/*/requirements.md 2>/dev/null \
            | grep -oE 'REQ-[A-Z0-9-]+-[0-9]{3}' | sort -u)
  if [ -n "$testfiles" ]; then
    testids=$(echo "$testfiles" | tr '\n' '\0' \
              | xargs -0 grep -ohE 'REQ-[A-Z0-9-]+-[0-9]{3}' 2>/dev/null | sort -u)
    for tid in $testids; do
      echo "$specids" | grep -qx "$tid" || out+="ORPHAN $tid — referenced in tests but defined by no spec (active or shipped)"$'\n'
    done
  fi
  printf '%s' "$out"
  exit 0
fi
if [ "$fail" -ne 0 ]; then
  {
    echo "REQUIREMENT COVERAGE FAILED — requirements exist that the work does not cover:"
    printf '%s' "$out"
    echo "Fix: add the missing task/test, or mark the requirement 'verify: deferred' if the owner agreed to postpone it."
  } >&2
  exit 2
fi
exit 0
