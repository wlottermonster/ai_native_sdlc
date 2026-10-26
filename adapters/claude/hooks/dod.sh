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
# The guards' shared library (REQ-TOUCH-047): a library that cannot be sourced
# is a refusal, never a fall-through to the allows below.
# Parameter expansion, not dirname(1), as in check-gate.sh.
case "$0" in */*) guard_lib="${0%/*}/guard-lib.sh" ;; *) guard_lib="./guard-lib.sh" ;; esac
# shellcheck source-path=SCRIPTDIR source=guard-lib.sh
. "$guard_lib" || {
  echo "CANNOT STOP: cannot source the guard library $guard_lib — refusing rather than allowing. Re-run install.sh." >&2
  exit 2
}
input=$(cat)

GATE_MARGIN=30

# --- the gate's own block counter (REQ-TOUCH-019, 020, 050) ------------------
# The client sets stop_hook_active on the retry after a block. It no longer
# allows anything by itself: the checks run again. What ends a loop is this
# counter, kept per session key with a cap below the client's own, so the
# UNVERIFIED line below is printed by this gate and actually seen.
retrying=0
stop_key=""
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$input" | jq -e '.stop_hook_active == true' > /dev/null 2>&1 && retrying=1
  stop_key=$(printf '%s' "$input" | jq -r '.session_id // empty | strings' 2>/dev/null || true)
fi
case "$stop_key" in
  ''|*[!A-Za-z0-9._-]*) stop_key=unknown ;;
esac
stop_cap="${SDLC_STOP_BLOCK_CAP:-6}"
case "$stop_cap" in
  ''|*[!0-9]*) stop_cap=6 ;;
  *) if [ "${#stop_cap}" -gt 9 ] || [ $((10#$stop_cap)) -lt 1 ]; then stop_cap=6; else stop_cap=$((10#$stop_cap)); fi ;;
esac
stop_dir="$SDLC_GUARDS_DIR/stop"
stop_file="$stop_dir/$stop_key.count"
stop_count=0
stop_unwritable=0
# The counter lives inside the guards directory. Where that directory does not
# exist yet (install.sh never ran), creating it bare here would make the first
# guard to fire find it present with no clock and deny (REQ-TOUCH-046) instead
# of warning (REQ-TOUCH-010): so it is created by seeding every clock first.
if [ ! -e "$SDLC_GUARDS_DIR" ] && [ ! -L "$SDLC_GUARDS_DIR" ]; then
  guards_seed_all || true
fi
# Writable is proven by writing, not by -w (as guard-lib.sh does).
stop_probe=$(mkdir -p "$stop_dir" 2>/dev/null && mktemp "$stop_dir/.probe.XXXXXX" 2>/dev/null) || stop_probe=""
if [ -n "$stop_probe" ] && rm -f "$stop_probe" 2>/dev/null; then
  if [ -f "$stop_file" ]; then
    stop_count=$(tr -d '[:space:]' < "$stop_file" 2>/dev/null || true)
    case "$stop_count" in ''|*[!0-9]*) stop_count=0 ;; esac
    [ "${#stop_count}" -le 9 ] || stop_count=0
    stop_count=$((10#$stop_count))
  fi
else
  # A counter that cannot be written can never reach the cap: every stop
  # would count as 0 and only the client's own silent cap would end the loop.
  # So it is the cap already reached: the first refusal allows, loudly.
  stop_unwritable=1
  stop_count=$stop_cap
fi

# One exit trap for every path (REQ-TOUCH-050): an allow resets the count, a
# block adds one. No allow below carries a reset of its own.
# shellcheck disable=SC2329  # invoked by the EXIT trap
stop_count_on_exit() {
  local rc=$? tmp
  if [ "$rc" -eq 0 ]; then
    rm -f "$stop_file" 2>/dev/null
  elif [ "$rc" -eq 2 ]; then
    if tmp=$(mktemp "$stop_dir/.count.XXXXXX" 2>/dev/null) \
       && printf '%s\n' $((stop_count + 1)) > "$tmp" 2>/dev/null \
       && mv -f "$tmp" "$stop_file" 2>/dev/null; then
      :
    else
      [ -n "${tmp:-}" ] && rm -f "$tmp" 2>/dev/null
      echo "definition-of-done: could not record this block in $stop_file." >&2
    fi
  fi
  return "$rc"
}
trap stop_count_on_exit EXIT

# refuse_stop — every block goes through here. Once this session key has been
# refused stop_cap times in a row, the next stop is allowed instead, loudly:
# the tree is UNVERIFIED, and the cap is logged.
refuse_stop() {
  local when repo branch
  if [ "$stop_count" -ge "$stop_cap" ]; then
    when=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    repo=$(git rev-parse --show-toplevel 2>/dev/null) || repo=$(pwd)
    branch=$(git symbolic-ref --short -q HEAD 2>/dev/null) || branch="-"
    [ -n "$branch" ] || branch="-"
    {
      if [ "$stop_unwritable" -eq 1 ]; then
        echo "UNVERIFIED: the Stop block counter at $stop_file could not be written, so the block"
        echo "cap ($stop_cap) cannot be counted for this session ($stop_key); it is treated as reached."
      fi
      echo "UNVERIFIED: the Stop block cap ($stop_cap) was reached for this session ($stop_key)."
      echo "The session is allowed to end, but the working tree was NOT verified:"
      echo "the refusal above still stands. Fix it before relying on this tree."
    } >&2
    printf '%s\t%s\t%s\t%s\n' "$when" "$repo" "$branch" "$stop_key" >> "$stop_dir/cap.log" 2>/dev/null \
      || echo "definition-of-done: could not append to $stop_dir/cap.log" >&2
    exit 0
  fi
  [ "$retrying" -eq 1 ] && echo "(this is a retry after a refused stop: block $((stop_count + 1)) of $stop_cap before the gate lets the session end UNVERIFIED)" >&2
  exit 2
}

top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0   # not a repo → allow
# A gate that cannot reach the repo must not ALLOW. `git rev-parse` proved this
# is a repo; if the cd still fails, something is wrong with the path, not with
# the session — say so rather than letting the session end unchecked.
cd "$top" || {
  echo "definition-of-done check: could not enter the repository root:" >&2
  echo "  $top" >&2
  echo "A directory can exist and still refuse cd. Not allowing the session to" >&2
  echo "end on an unverified tree — fix the path and try again." >&2
  refuse_stop
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

# --- the stop-evidence guard (REQ-TOUCH-021, 022) ----------------------------
# A session ending on a feature branch whose every task box is ticked is a
# feature claimed done: it needs evidence that is current and green. Evaluated
# BEFORE the clean-tree and docs-only allows, because a fully committed feature
# branch is a clean tree and the guard would otherwise never run. Only exactly
# `sdlc/<feature>` with specs/<feature>/ is a feature branch: `sdlc/<f>-T1` is
# a task branch. Refusals go through guard_refuse: a block in deny mode; in
# warn mode the WARN on stderr and the guard's .log line are the record (a
# Stop hook has no context channel on allow).
stop_evidence_guard() {
  local branch feature tasks sstate ev_out ev_rc=0 retry_note=""
  branch=$(git symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  case "$branch" in
    sdlc/?*) ;;
    *) return 0 ;;
  esac
  feature=${branch#sdlc/}
  case "$feature" in */*|.|..|_*) return 0 ;; esac
  [ -d "specs/$feature" ] || return 0
  tasks="specs/$feature/tasks.md"
  [ -f "$tasks" ] || return 0
  # An open, claimed or parked box: the feature is not claimed done. An
  # unreadable tasks.md is not proof of an open box, so the guard runs.
  grep -qE '^[[:space:]]*- \[[ ~!]\]' "$tasks" 2>/dev/null && return 0
  [ "$retrying" -eq 1 ] && retry_note="
(The stop was already refused once; stopping again does not change the evidence.)"
  sstate="$top/scripts/sdlc-state.sh"
  [ -f "$sstate" ] || sstate="$HOME/.claude/scripts/sdlc-state.sh"
  if [ ! -f "$sstate" ]; then
    guard_refuse stop-evidence "stop-evidence: the session is ending on $branch with every task box ticked, and the evidence for '$feature' cannot be verified — sdlc-state.sh was not found.
Looked in:
  $top/scripts/sdlc-state.sh
  $HOME/.claude/scripts/sdlc-state.sh
Run install.sh from the framework checkout, then: sdlc-state.sh evidence $feature$retry_note" || refuse_stop
    return 0
  fi
  ev_out=$(bash "$sstate" evidence-state "$feature" WORKTREE < /dev/null 2>/dev/null) || ev_rc=$?
  if [ "$ev_rc" -eq 0 ] && [ "$ev_out" = green ]; then
    return 0
  fi
  [ -n "$ev_out" ] || ev_out="no answer (exit $ev_rc)"
  guard_refuse stop-evidence "stop-evidence: the session is ending on $branch with every task box in specs/$feature/tasks.md ticked, and its evidence is not current and green — state: $ev_out.
Produce evidence: sdlc-state.sh evidence $feature, then record the verdicts (sdlc-state.sh record $feature ...) and commit specs/$feature/evidence.json.$retry_note" || refuse_stop
  return 0
}
stop_evidence_guard

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
  refuse_stop
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
  refuse_stop
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
  refuse_stop
fi
case "$rc" in ''|*[!0-9]*)
  {
    echo "CANNOT STOP: the checks ended without an exit code; the tree is unverified."
    [ -n "$out" ] && { echo "--- what the checks printed ---"; echo "$out" | tail -40; }
  } >&2
  refuse_stop ;;
esac
if [ "$rc" -ne 0 ]; then
  {
    echo "CANNOT STOP: the working tree has uncommitted changes and the repo's"
    echo "checks are failing (exit $rc). Fix the failures or revert before ending the turn."
    echo "--- last 40 lines ---"
    echo "$out" | tail -40
  } >&2
  refuse_stop
fi
exit 0
