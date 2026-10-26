#!/bin/bash
# shellcheck shell=bash
# AI-Native SDLC — the warn-then-deny clock every guard shares. SOURCED by the
# hooks (`. "$lib" || exit 2`); it defines functions and defaults only.
#
#   guard_refuse <guard> <text>   the one entry point a hook calls when a guard
#                                 would refuse: returns 2 in deny mode (the
#                                 caller exits 2), 0 in warn mode after
#                                 printing and logging the warning.
#   guard_mode <guard>            prints `warn` or `deny`; on deny, GUARD_REASON
#                                 says why.
#   guard_deny_date <guard>       the UTC date denial begins (since + window).
#   guard_log <guard> <reason>    appends one line to <guard>.log.
#   guards_seed_all [guard...]    creates the directory and seeds every missing
#                                 .since (the three guards, plus any named).
#
# The clock: SDLC_GUARDS_DIR holds <guard>.since (the epoch second the warn
# window opened) and <guard>.log. Clocks are seeded ONLY when the directory is
# absent altogether, and then every guard's at once (guards_seed_all), so the
# second guard to fire finds its clock too; once it exists, a missing, non-numeric or
# future .since is a deny naming the file, so deleting or editing a clock
# cannot restart the window. A directory that cannot be created or written is
# a deny too: a guard that cannot record its clock gets no grace.

SDLC_GUARDS_DIR="${SDLC_GUARDS_DIR:-${HOME:-}/.claude/sdlc-guards}"
# A constant, not read from the environment: the window is not negotiable.
SDLC_GUARD_WINDOW=$((14 * 86400))
GUARD_REASON="${GUARD_REASON:-}"
GUARD_WARNED="${GUARD_WARNED:-}"
GUARD_RESULT=""

# guards_seed_all [guard...] — create SDLC_GUARDS_DIR and write the current
# epoch into every missing <guard>.since: every guard the hooks call
# (gate1-stamp, evidence-merge, stop-evidence) and any named. A clock seeded
# for one and not the others would make the second guard to fire a
# REQ-TOUCH-046 deny on its first evaluation.
# An existing clock is never rewritten. Fails when the directory cannot be
# created or a clock cannot be written. Callers seed only when the directory
# did not exist: once it does, a missing clock is a deny (REQ-TOUCH-046).
guards_seed_all() {
  local dir="$SDLC_GUARDS_DIR" now g
  now=$(date +%s)
  mkdir -p "$dir" 2>/dev/null || return 1
  for g in gate1-stamp evidence-merge stop-evidence "$@"; do
    [ -e "$dir/$g.since" ] && continue
    printf '%s\n' "$now" > "$dir/$g.since" 2>/dev/null || return 1
  done
  return 0
}

# _guard_date <epoch> — the UTC calendar date, on macOS and Linux date(1).
_guard_date() {
  date -u -r "$1" +%F 2>/dev/null || date -u -d "@$1" +%F 2>/dev/null || printf '%s' "epoch $1"
}

# _guard_since <guard> — print the clock if it is a plain non-negative integer
# no later than now; otherwise fail.
_guard_since() {
  local f="$SDLC_GUARDS_DIR/$1.since" v now
  [ -f "$f" ] || return 1
  v=$(tr -d '[:space:]' < "$f" 2>/dev/null) || return 1
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Longer than any epoch second for the foreseeable future, and would
  # overflow shell arithmetic.
  [ "${#v}" -le 15 ] || return 1
  v=$((10#$v))
  now=$(date +%s)
  [ "$v" -le "$now" ] || return 1
  printf '%s' "$v"
}

# _guard_eval <guard> — set GUARD_RESULT (warn|deny) and, for deny,
# GUARD_REASON. Runs in the caller's shell so both globals survive.
_guard_eval() {
  local g="$1" dir="$SDLC_GUARDS_DIR" now since probe
  GUARD_RESULT=""
  GUARD_REASON=""
  case "${SDLC_GUARD_MODE:-}" in
    deny) GUARD_RESULT=deny; GUARD_REASON="SDLC_GUARD_MODE=deny"; return 0 ;;
    warn) GUARD_RESULT=warn; return 0 ;;
  esac
  now=$(date +%s)
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    if guards_seed_all "$g"; then
      GUARD_RESULT=warn
    else
      GUARD_RESULT=deny
      GUARD_REASON="the guards directory $dir cannot be created or seeded, so the clock cannot be recorded"
    fi
    return 0
  fi
  # Writability is proven by writing, not by -w.
  probe=$(mktemp "$dir/.probe.XXXXXX" 2>/dev/null) && rm -f "$probe" 2>/dev/null || probe=""
  if [ -z "$probe" ]; then
    GUARD_RESULT=deny
    GUARD_REASON="the guards directory $dir is not writable, so the clock cannot be recorded"
    return 0
  fi
  if ! since=$(_guard_since "$g"); then
    GUARD_RESULT=deny
    GUARD_REASON="the clock $dir/$g.since is missing, not a number, or in the future; a warn window is not restarted by deleting or editing its clock"
    return 0
  fi
  if [ $((now - since)) -lt "$SDLC_GUARD_WINDOW" ]; then
    GUARD_RESULT=warn
  else
    GUARD_RESULT=deny
    GUARD_REASON="the warn window ended on $(_guard_date $((since + SDLC_GUARD_WINDOW)))"
  fi
}

# guard_mode <guard> — print `warn` or `deny`; on deny GUARD_REASON says why.
guard_mode() {
  _guard_eval "$1"
  printf '%s\n' "$GUARD_RESULT"
}

# guard_deny_date <guard> — the UTC date denial begins. With no readable clock
# (an override, or a clock never seeded) it counts from now.
guard_deny_date() {
  local since
  since=$(_guard_since "$1") || since=$(date +%s)
  _guard_date $((since + SDLC_GUARD_WINDOW))
  printf '\n'
}

# guard_log <guard> <reason> — append "<iso time>\t<repo>\t<branch>\t<reason>"
# to <guard>.log. A failed append is reported on stderr, never fatal.
guard_log() {
  local g="$1" reason="$2" when top branch
  when=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(pwd)
  branch=$(git symbolic-ref --short -q HEAD 2>/dev/null) || branch="-"
  [ -n "$branch" ] || branch="-"
  reason=$(printf '%s' "$reason" | tr '\t\n' '  ')
  if ! printf '%s\t%s\t%s\t%s\n' "$when" "$top" "$branch" "$reason" \
      >> "$SDLC_GUARDS_DIR/$g.log" 2>/dev/null; then
    printf 'guard %s: could not append to %s\n' "$g" "$SDLC_GUARDS_DIR/$g.log" >&2
  fi
  return 0
}

# guard_refuse <guard> <text> — deny: print <text> and why, return 2. Warn:
# print the same <text> under a WARN line naming the date denial begins, log
# it, accumulate it in GUARD_WARNED, return 0.
guard_refuse() {
  local g="$1" text="$2" block
  _guard_eval "$g"
  if [ "$GUARD_RESULT" = warn ]; then
    block="WARN ($g: denial begins $(guard_deny_date "$g"))
$text"
    printf '%s\n' "$block" >&2
    guard_log "$g" "$text"
    GUARD_WARNED="${GUARD_WARNED}${block}
"
    return 0
  fi
  printf '%s\n(%s: deny — %s)\n' "$text" "$g" "${GUARD_REASON:-deny}" >&2
  return 2
}

# guard_context_json <extra-text> — the one document a PreToolUse hook prints
# on an allow that has something to say: GUARD_WARNED, then <extra-text> (the
# requirement gate's report), as hookSpecificOutput.additionalContext. Never a
# permissionDecision: an `allow` there would approve the whole Bash call
# (REQ-TOUCH-014). Returns 1 and prints nothing when there is nothing to say.
guard_context_json() {
  local extra="${1:-}" ctx
  ctx="${GUARD_WARNED}"
  if [ -n "$extra" ]; then
    ctx="${ctx}${extra}"
  fi
  ctx="${ctx%$'\n'}"
  [ -n "$ctx" ] || return 1
  jq -cn --arg ctx "$ctx" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
}

# evidence_tree <feature> <ref|WORKTREE> — print the sha of the tree of <ref>
# (or of the working tree, untracked non-ignored files included) with
# specs/<feature>/state.json and specs/<feature>/evidence.json removed, so
# committing the evidence never makes it stale (REQ-TOUCH-044). Built in a
# temporary index; the repository's own index is never touched. On any failure
# it prints nothing and returns non-zero: the caller reads that as "cannot
# verify", never as "equal".
evidence_tree() {
  local feature="$1" ref="$2" tmp top sha rc=0
  [ -n "$feature" ] && [ -n "$ref" ] || return 1
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-etree.XXXXXX") || return 1
  sha=$(
    export GIT_INDEX_FILE="$tmp/index"
    if [ "$ref" = WORKTREE ]; then
      top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
      cd "$top" || exit 1
      # Seeded from HEAD, so a tracked file that matches .gitignore (added
      # with -f) stays in the tree as it does in the ref's; `add -A` then
      # stages what the work tree changed, removals included, and hashes only
      # those paths. No HEAD yet (an unborn branch): start empty.
      if git rev-parse -q --verify 'HEAD^{tree}' >/dev/null 2>&1; then
        git read-tree 'HEAD^{tree}' >/dev/null 2>&1 || exit 1
      fi
      git add -A -- . >/dev/null 2>&1 || exit 1
    else
      # A ref that reads as an option is never passed to git.
      [ "${ref#-}" = "$ref" ] || exit 1
      git rev-parse -q --verify "$ref^{tree}" >/dev/null 2>&1 || exit 1
      git read-tree "$ref^{tree}" >/dev/null 2>&1 || exit 1
    fi
    git update-index --force-remove -- \
      "specs/$feature/state.json" "specs/$feature/evidence.json" >/dev/null 2>&1 || exit 1
    git write-tree 2>/dev/null
  ) || rc=1
  rm -rf "$tmp"
  case "$sha" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$sha"
}
