#!/bin/bash
# AI-Native SDLC — tests for hooks/postcompact-policy.sh, the PostCompact
# re-injection of the routing policy. Covers REQ-POLICY-001 (only the routing
# section is injected: the heading is the first line and the first half of the
# file is absent), REQ-POLICY-002 (no heading → the whole file, never nothing),
# REQ-POLICY-003 (no policy file → valid JSON that says so, exit 0),
# REQ-POLICY-004 (stdin drained: a large piped payload cannot kill the hook),
# REQ-POLICY-005 (no jq on PATH → still valid JSON naming the gap, exit 0),
# REQ-POLICY-006 (the snippet registers the script and no longer the inline jq
# command) and REQ-POLICY-007 (the shipped policy file carries the heading the
# hook cuts at, and the cut keeps the routing table).
#
# Every run points HOME at a throwaway mktemp -d removed by the EXIT trap: no
# assertion here reads or writes the real $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

hook="$TEST_REPO/hooks/postcompact-policy.sh"
snippet="$TEST_REPO/settings/hooks-snippet.json"
# The real jq, resolved once and called by absolute path, so the no-jq case can
# still be validated after PATH has been emptied of it.
jqbin=$(command -v jq || true)

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-postcompact.XXXXXX")
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

# run_hook <outfile> <home> <stdin: closed|pipe> [PATH]
# stdout lands in <outfile>, stderr in <outfile>.err, the exit code in
# <outfile>.rc, and the parsed event name and context beside them.
run_hook() {
  local out=$1 home=$2 spec=$3 path=${4:-$PATH} rc=0
  case $spec in
    closed) env HOME="$home" PATH="$path" bash "$hook" >"$out" 2>"$out.err" <&- || rc=$? ;;
    pipe)   head -c 2000000 /dev/zero | tr '\0' 'x' \
              | env HOME="$home" PATH="$path" bash "$hook" >"$out" 2>"$out.err" || rc=$? ;;
  esac
  printf '%s\n' "$rc" > "$out.rc"
  "$jqbin" -r '.hookSpecificOutput.hookEventName // empty' "$out" > "$out.event" 2>/dev/null || true
  "$jqbin" -r '.hookSpecificOutput.additionalContext // empty' "$out" > "$out.ctx" 2>/dev/null || true
  head -n 1 "$out.ctx" > "$out.first"
}

req "REQ-POLICY-001"
h=$(home_with_policy "$tmproot" yes)
out="$tmproot/section.out"
run_hook "$out" "$h" closed
assert_rc 0 "$out"
assert_grep '^PostCompact$' "$out.event"
assert_grep '^# AI-Native SDLC.*routing policy' "$out.first"
assert_fgrep "$ROUTE_MARK" "$out.ctx"
assert_no_grep 'Lifecycle and proportionate process' "$out.ctx"
assert_no_grep 'Core prose' "$out.ctx"

req "REQ-POLICY-002"
h=$(home_with_policy "$tmproot" no)
out="$tmproot/fallback.out"
run_hook "$out" "$h" closed
assert_rc 0 "$out"
assert_grep '^PostCompact$' "$out.event"
assert_fgrep 'Core prose' "$out.ctx"
assert_fgrep "$ROUTE_MARK" "$out.ctx"

req "REQ-POLICY-003"
h=$(mktemp -d "$tmproot/home.XXXXXX")
mkdir -p "$h/.claude"
out="$tmproot/missing.out"
run_hook "$out" "$h" closed
assert_rc 0 "$out"
assert_grep '^PostCompact$' "$out.event"
assert_grep 'sdlc-policy.md' "$out.ctx"
assert_grep 'missing' "$out.ctx"

req "REQ-POLICY-004"
h=$(home_with_policy "$tmproot" yes)
out="$tmproot/pipe.out"
run_hook "$out" "$h" pipe
assert_rc 0 "$out"
assert_grep '^PostCompact$' "$out.event"
assert_fgrep "$ROUTE_MARK" "$out.ctx"

req "REQ-POLICY-005"
nojq=$(mktemp -d "$tmproot/bin.XXXXXX")
for tool in bash cat sed env head tr; do
  ln -s "$(command -v "$tool")" "$nojq/$tool"
done
h=$(home_with_policy "$tmproot" yes)
out="$tmproot/nojq.out"
run_hook "$out" "$h" closed "$nojq"
assert_rc 0 "$out"
assert_grep '^PostCompact$' "$out.event"
assert_grep 'jq' "$out.ctx"

req "REQ-POLICY-006"
"$jqbin" -r '.hooks.PostCompact[].hooks[].command' "$snippet" > "$tmproot/snippet.cmd"
assert_grep 'postcompact-policy\.sh' "$tmproot/snippet.cmd"
assert_no_grep 'jq -Rs' "$tmproot/snippet.cmd"

req "REQ-POLICY-007"
assert_grep '^# AI-Native SDLC.*routing policy' "$TEST_REPO/sdlc-policy.md"
h=$(mktemp -d "$tmproot/home.XXXXXX")
mkdir -p "$h/.claude"
cp "$TEST_REPO/sdlc-policy.md" "$h/.claude/sdlc-policy.md"
out="$tmproot/shipped.out"
run_hook "$out" "$h" closed
assert_rc 0 "$out"
assert_grep '^# AI-Native SDLC.*routing policy' "$out.first"
assert_grep '\| Phase \| Who \| Role \|' "$out.ctx"
assert_no_grep 'Lifecycle and proportionate process' "$out.ctx"

finish
