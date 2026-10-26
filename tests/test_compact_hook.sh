#!/bin/bash
# AI-Native SDLC — tests for hooks/compact-policy.sh, the re-injection of the
# routing policy after compaction, registered as a SessionStart entry whose
# matcher is `compact` (the event the client documents as adding context after
# a compaction; PostCompact has no output channel).
#
# REQ-TOUCH-033 (the snippet registers the script under SessionStart with a
# matcher covering `compact`, and no PostCompact entry remains), REQ-TOUCH-034
# (on a payload whose source is `compact` the script emits hookEventName
# SessionStart with the routing section as additionalContext, keeping every
# shipped fallback: no heading, no file, no jq, large payload), REQ-TOUCH-035
# (the session-engines entry still excludes `compact`). The live observation on
# a real compaction is deferred to Gate 2: nothing here claims it.
#
# The earlier shipped labels stay on what they still prove: REQ-POLICY-001
# (only the routing section), 002 (no heading → whole file), 003 (no policy
# file → valid JSON saying so), 004 (stdin drained: a large piped payload
# cannot kill the hook), 005 (no jq → valid JSON naming the gap), 006 (the
# snippet names the script, not an inline jq command; the entry is now the
# SessionStart compact one) and 007 (the shipped heading and the cut).
#
# Every run points HOME at a throwaway mktemp -d removed by the EXIT trap: no
# assertion here reads or writes the real $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

hook="$TEST_REPO/hooks/compact-policy.sh"
snippet="$TEST_REPO/settings/hooks-snippet.json"
# The real jq, resolved once and called by absolute path, so the no-jq case can
# still be validated after PATH has been emptied of it.
jqbin=$(command -v jq || true)

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-compact.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

CORE_MARK='## Lifecycle and proportionate process'
ROUTE_HEAD='# AI-Native SDLC — routing policy (re-injected after every compaction)'
ROUTE_MARK='routing sentinel 7731 "quoted" back\slash'

# home_with_policy <parent> <heading: yes|no> — a throwaway HOME holding a
# two-part policy file; with `no` the routing heading is left out.
home_with_policy() {
  local h
  h=$(mktemp -d "$1/home.XXXXXX")
  mkdir -p "$h/.claude"
  {
    printf '# Shared SDLC policy\n\n%s\n\nCore prose that is read on demand.\n\n' "$CORE_MARK"
    if [ "$2" = yes ]; then printf '%s\n\n' "$ROUTE_HEAD"; fi
    printf 'The main session runs the judge role. %s\n' "$ROUTE_MARK"
  } > "$h/.claude/sdlc-policy.md"
  printf '%s' "$h"
}

# payload <file> <source|-> [pad-bytes] — a SessionStart payload; `-` leaves
# the source field out, and pad-bytes lengthens transcript_path so the payload
# is far larger than a pipe buffer.
payload() {
  local f=$1 src=$2 pad=${3:-0} filler=""
  if [ "$pad" -gt 0 ]; then
    filler=$(head -c "$pad" /dev/zero | tr '\0' 'x')
  fi
  if [ "$src" = - ]; then
    printf '{"hook_event_name":"SessionStart","session_id":"s1","transcript_path":"/t/%s"}' "$filler" > "$f"
  else
    printf '{"hook_event_name":"SessionStart","session_id":"s1","transcript_path":"/t/%s","source":"%s"}' "$filler" "$src" > "$f"
  fi
}

# run_hook <outfile> <home> <payload-file|closed> [PATH]
# stdout lands in <outfile>, stderr in <outfile>.err, the exit code in
# <outfile>.rc, and the parsed event name and context beside them. A payload
# file is piped through head, so the hook reads a real pipe, not a file.
run_hook() {
  local out=$1 home=$2 spec=$3 path=${4:-$PATH} rc=0
  case $spec in
    closed) env HOME="$home" PATH="$path" bash "$hook" >"$out" 2>"$out.err" <&- || rc=$? ;;
    *)      head -c 100000000 "$spec" | env HOME="$home" PATH="$path" bash "$hook" >"$out" 2>"$out.err" || rc=$? ;;
  esac
  printf '%s\n' "$rc" > "$out.rc"
  "$jqbin" -r '.hookSpecificOutput.hookEventName // empty' "$out" > "$out.event" 2>/dev/null || true
  "$jqbin" -r '.hookSpecificOutput.additionalContext // empty' "$out" > "$out.ctx" 2>/dev/null || true
  head -n 1 "$out.ctx" > "$out.first"
}

# assert_silent <outfile> <what> — the hook printed nothing at all.
assert_silent() {
  if [ -s "$1" ]; then _test_fail "$2 produced output: $1"
  else _test_pass "$2 produces no output"; fi
}

compact="$tmproot/compact.json"
payload "$compact" compact

req "REQ-POLICY-001"
req "REQ-TOUCH-034"
h=$(home_with_policy "$tmproot" yes)
out="$tmproot/section.out"
run_hook "$out" "$h" "$compact"
assert_rc 0 "$out"
assert_grep '^SessionStart$' "$out.event"
assert_grep '^# AI-Native SDLC.*routing policy' "$out.first"
assert_fgrep "$ROUTE_MARK" "$out.ctx"
assert_no_grep 'Lifecycle and proportionate process' "$out.ctx"
assert_no_grep 'Core prose' "$out.ctx"

req "REQ-POLICY-002"
req "REQ-TOUCH-034"
h=$(home_with_policy "$tmproot" no)
out="$tmproot/fallback.out"
run_hook "$out" "$h" "$compact"
assert_rc 0 "$out"
assert_grep '^SessionStart$' "$out.event"
assert_fgrep 'Core prose' "$out.ctx"
assert_fgrep "$ROUTE_MARK" "$out.ctx"

req "REQ-POLICY-003"
req "REQ-TOUCH-034"
h=$(mktemp -d "$tmproot/home.XXXXXX")
mkdir -p "$h/.claude"
out="$tmproot/missing.out"
run_hook "$out" "$h" "$compact"
assert_rc 0 "$out"
assert_grep '^SessionStart$' "$out.event"
assert_grep 'sdlc-policy.md' "$out.ctx"
assert_grep 'missing' "$out.ctx"

req "REQ-POLICY-004"
req "REQ-TOUCH-034"
# A 2 MB payload on the pipe, with the source at its END: the hook must drain
# all of it, still read the source, and still answer.
large="$tmproot/large.json"
payload "$large" compact 2000000
h=$(home_with_policy "$tmproot" yes)
out="$tmproot/pipe.out"
run_hook "$out" "$h" "$large"
assert_rc 0 "$out"
assert_grep '^SessionStart$' "$out.event"
assert_fgrep "$ROUTE_MARK" "$out.ctx"

req "REQ-POLICY-005"
req "REQ-TOUCH-034"
nojq=$(mktemp -d "$tmproot/bin.XXXXXX")
for tool in bash cat sed env head tr; do
  ln -s "$(command -v "$tool")" "$nojq/$tool"
done
h=$(home_with_policy "$tmproot" yes)
out="$tmproot/nojq.out"
run_hook "$out" "$h" "$compact" "$nojq"
assert_rc 0 "$out"
assert_grep '^SessionStart$' "$out.event"
assert_grep 'jq' "$out.ctx"
# Without jq the source is still read: the large compact payload gets the
# notice, and a startup payload gets nothing.
out="$tmproot/nojq-large.out"
run_hook "$out" "$h" "$large" "$nojq"
assert_rc 0 "$out"
assert_grep '^SessionStart$' "$out.event"
pl="$tmproot/nojq-startup.json"
payload "$pl" startup
out="$tmproot/nojq-startup.out"
run_hook "$out" "$h" "$pl" "$nojq"
assert_rc 0 "$out"
assert_silent "$out" "no jq, source startup,"

req "REQ-TOUCH-034"
# Any other source, or none, gets nothing: the entry's matcher is `compact`, so
# another source means the script runs where it was not registered to, and it
# must not inject the policy there. It still exits 0: it gates nothing.
for src in startup resume clear -; do
  pl="$tmproot/src-$src.json"
  payload "$pl" "$src"
  h=$(home_with_policy "$tmproot" yes)
  out="$tmproot/src-$src.out"
  run_hook "$out" "$h" "$pl"
  assert_rc 0 "$out"
  assert_silent "$out" "source '$src'"
done
# A payload that is not JSON, and closed stdin, carry no source either.
printf 'not json "source":"compact"' > "$tmproot/garbage.json"
h=$(home_with_policy "$tmproot" yes)
out="$tmproot/garbage.out"
run_hook "$out" "$h" "$tmproot/garbage.json"
assert_rc 0 "$out"
assert_silent "$out" "a non-JSON payload"
out="$tmproot/closed.out"
run_hook "$out" "$h" closed
assert_rc 0 "$out"
assert_silent "$out" "closed stdin"

req "REQ-POLICY-006"
req "REQ-TOUCH-033"
# The SessionStart entries whose matcher, tested as the extended regex the
# client applies to the source, covers `compact`: exactly one, and it runs the
# script, not an inline jq command and not the engine map.
"$jqbin" -r '.hooks.SessionStart[]? | .matcher // ""' "$snippet" > "$tmproot/ss-matchers.txt"
: > "$tmproot/compact-cmds.txt"
n=0
while IFS= read -r m; do
  if [ -n "$m" ] && printf 'compact\n' | grep -qE -- "$m"; then
    # shellcheck disable=SC2016  # $m is a jq variable, not a shell expansion
    "$jqbin" -r --arg m "$m" '.hooks.SessionStart[] | select(.matcher == $m) | .hooks[].command' \
      "$snippet" >> "$tmproot/compact-cmds.txt"
    n=$((n + 1))
  fi
done < "$tmproot/ss-matchers.txt"
if [ "$n" -eq 1 ]; then _test_pass "one SessionStart entry covers compact"
else _test_fail "SessionStart entries covering compact: $n (want 1)"; fi
assert_grep 'compact-policy\.sh' "$tmproot/compact-cmds.txt"
# shellcheck disable=SC2016  # a literal command string, not an expansion
assert_fgrep '"$HOME/.claude/hooks/compact-policy.sh"' "$tmproot/compact-cmds.txt"
assert_no_grep 'jq -Rs' "$tmproot/compact-cmds.txt"
assert_no_grep 'session-engines' "$tmproot/compact-cmds.txt"
# ...and nothing is registered under PostCompact any more, nor named so.
"$jqbin" -r '.hooks | keys[]' "$snippet" > "$tmproot/events.txt"
assert_no_grep '^PostCompact$' "$tmproot/events.txt"
assert_no_grep 'PostCompact' "$snippet"
assert_no_grep 'postcompact-policy' "$snippet"
# No comment key inside any hook entry: the note lives at the top level only.
"$jqbin" -r '[.hooks | paths | map(tostring) | join(".")] | .[]' "$snippet" > "$tmproot/hook-paths.txt"
assert_no_grep '//' "$tmproot/hook-paths.txt"

req "REQ-TOUCH-035"
# The session-engines entry keeps its matcher and still excludes compact, so
# the engine map is not re-announced on every compaction.
"$jqbin" -r '.hooks.SessionStart[] | select([.hooks[].command] | join(" ") | test("session-engines")) | .matcher' \
  "$snippet" > "$tmproot/engines-matcher.txt"
assert_grep '^startup[|]resume[|]clear$' "$tmproot/engines-matcher.txt"
em=$(head -n 1 "$tmproot/engines-matcher.txt")
if printf 'compact\n' | grep -qE -- "$em"; then _test_fail "session-engines matcher /$em/ covers compact"
else _test_pass "session-engines matcher /$em/ excludes compact"; fi

req "REQ-POLICY-007"
assert_grep '^# AI-Native SDLC.*routing policy' "$TEST_REPO/sdlc-policy.md"
h=$(mktemp -d "$tmproot/home.XXXXXX")
mkdir -p "$h/.claude"
cp "$TEST_REPO/sdlc-policy.md" "$h/.claude/sdlc-policy.md"
out="$tmproot/shipped.out"
run_hook "$out" "$h" "$compact"
assert_rc 0 "$out"
assert_grep '^# AI-Native SDLC.*routing policy' "$out.first"
assert_grep '\| Phase \| Who \| Role \|' "$out.ctx"
assert_no_grep 'Lifecycle and proportionate process' "$out.ctx"

finish
