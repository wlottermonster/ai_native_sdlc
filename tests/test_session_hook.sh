#!/bin/bash
# AI-Native SDLC — tests for hooks/session-engines.sh, the SessionStart engine
# announcement. Covers REQ-ENGINE-016 (JSON on stdout whose
# hookSpecificOutput.hookEventName is SessionStart and whose additionalContext
# carries the active engine map), REQ-ENGINE-017 (no map → still valid JSON
# saying the map is absent and the built-in defaults apply, exit 0),
# REQ-ENGINE-018 and REQ-ENGINE-019 (the emitted instructions: one opening line
# naming the model the session runs as and the roles it covers, and the
# judge-mismatch disclosure in that same line — asserted on the emitted
# additionalContext, on the no-jq path too, and against T6's no-quote /
# no-backslash / no-control-character constraint) and
# REQ-ENGINE-034 (stdin drained first, so neither a JSON payload nor a closed
# stdin nor a large piped payload can hang or kill the hook; and with jq off
# PATH a hand-built valid JSON object is emitted, exiting 0 either way).
#
# Every run points HOME at a throwaway mktemp -d removed by the EXIT trap: no
# assertion here reads or writes the real $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

hook="$TEST_REPO/hooks/session-engines.sh"
# The real jq, resolved once and called by absolute path, so the no-jq case can
# still be validated after PATH has been emptied of it.
jqbin=$(command -v jq || true)

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-session-hook.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

# home_with_map <parent> — a throwaway HOME holding an engine map with a
# distinctive line, so "the active map" can be told apart from any default.
home_with_map() {
  local h
  h=$(mktemp -d "$1/home.XXXXXX")
  mkdir -p "$h/.claude"
  {
    printf '# a comment line that a parser skips\n'
    printf '\n'
    printf 'judge = testjudge-9, sonnet\n'
    printf 'build = testbuild-9, sonnet\n'
    printf 'verify = testverify-9, sonnet\n'
    printf 'read = testread-9, sonnet\n'
    printf 'escalate = testescalate-9, opus\n'
  } > "$h/.claude/sdlc-engines.conf"
  printf '%s' "$h"
}

# run_hook <outfile> <home> <stdin-spec> [path]
#   stdin-spec: closed | file:<path> | pipe:<path>
# stdout lands in <outfile> (kept clean of stderr, so it can be parsed), stderr
# in <outfile>.err and the exit code in <outfile>.rc.
run_hook() {
  local out=$1 home=$2 spec=$3 path=${4:-$PATH} rc=0
  case $spec in
    closed)
      env HOME="$home" PATH="$path" bash "$hook" > "$out" 2> "$out.err" < /dev/null || rc=$?
      ;;
    file:*)
      env HOME="$home" PATH="$path" bash "$hook" > "$out" 2> "$out.err" < "${spec#file:}" || rc=$?
      ;;
    pipe:*)
      # a real pipe writer, so an undrained stdin would show up as a hang or a
      # SIGPIPE-killed hook rather than as a quiet pass
      cat -- "${spec#pipe:}" \
        | env HOME="$home" PATH="$path" bash "$hook" > "$out" 2> "$out.err" || rc=$?
      ;;
  esac
  printf '%s\n' "$rc" > "$out.rc"
}

# extract <outfile> — split the emitted JSON into <outfile>.event and
# <outfile>.ctx so they can be asserted on with the usual helpers. Invalid JSON
# leaves both empty, which fails the assertions that follow.
extract() {
  "$jqbin" -r '.hookSpecificOutput.hookEventName // empty' "$1" > "$1.event" 2>/dev/null || true
  "$jqbin" -r '.hookSpecificOutput.additionalContext // empty' "$1" > "$1.ctx" 2>/dev/null || true
}

if [ -z "$jqbin" ]; then
  printf 'tests/test_session_hook.sh needs jq to validate the hook output\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
req "REQ-ENGINE-016"
# With a map installed, stdout parses as JSON, names the SessionStart event and
# carries the ACTIVE map's lines.
h=$(home_with_map "$tmproot")
out="$tmproot/withmap.out"
run_hook "$out" "$h" closed
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"
extract "$out"
assert_grep '^SessionStart$' "$out.event"
assert_fgrep 'build = testbuild-9, sonnet' "$out.ctx"
assert_fgrep 'judge = testjudge-9, sonnet' "$out.ctx"
assert_fgrep 'read = testread-9, sonnet' "$out.ctx"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-017"
# With no map at all the hook still emits valid JSON, says the map is absent,
# says the built-in defaults apply, and exits 0.
h=$(mktemp -d "$tmproot/nomap.XXXXXX")
out="$tmproot/nomap.out"
run_hook "$out" "$h" closed
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"
extract "$out"
assert_grep '^SessionStart$' "$out.event"
assert_grep 'no engine map' "$out.ctx"
assert_grep 'default' "$out.ctx"

# A $HOME/.claude that exists but holds no map is the same case, not a crash.
h2=$(mktemp -d "$tmproot/nomap2.XXXXXX")
mkdir -p "$h2/.claude"
out="$tmproot/nomap2.out"
run_hook "$out" "$h2" closed
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"

# An unreadable map must not block a session either: still exit 0, still JSON.
h3=$(home_with_map "$tmproot")
chmod 000 "$h3/.claude/sdlc-engines.conf"
out="$tmproot/unreadable.out"
run_hook "$out" "$h3" closed
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"
chmod 644 "$h3/.claude/sdlc-engines.conf"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-034"
# jq off PATH: the hook hand-builds the object rather than emitting a partial
# one. Absence is simulated with a PATH holding only bash, so the test does not
# depend on where a platform installs jq. The output is then validated with the
# REAL jq, by absolute path.
stub=$(mktemp -d "$tmproot/stub.XXXXXX")
ln -s "$(command -v bash)" "$stub/bash"
h=$(home_with_map "$tmproot")
out="$tmproot/nojq.out"
run_hook "$out" "$h" closed "$stub"
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"
extract "$out"
assert_grep '^SessionStart$' "$out.event"
assert_fgrep 'build = testbuild-9, sonnet' "$out.ctx"

# jq off PATH AND no map: still one valid JSON object, still exit 0.
h=$(mktemp -d "$tmproot/nojqnomap.XXXXXX")
out="$tmproot/nojqnomap.out"
run_hook "$out" "$h" closed "$stub"
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"
extract "$out"
assert_grep '^SessionStart$' "$out.event"

# A map line carrying characters that would need JSON escaping must not be able
# to produce broken JSON on the hand-built path.
h=$(home_with_map "$tmproot")
printf 'note = a "quoted" \\ backslash model\n' >> "$h/.claude/sdlc-engines.conf"
out="$tmproot/nojqquote.out"
run_hook "$out" "$h" closed "$stub"
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"

# A map saved with CRLF line endings still reaches the session on the no-jq
# path. CR is a control character, so a line that keeps it is dropped by the
# hand-built emitter: without the CR strip in payload() every map line would
# vanish here and the session would be told nothing about the active map, with
# no error anywhere to say so.
h=$(mktemp -d "$tmproot/crlf.XXXXXX")
mkdir -p "$h/.claude"
printf 'judge = crlfjudge-9, sonnet\r\nbuild = crlfbuild-9, sonnet\r\n' \
  > "$h/.claude/sdlc-engines.conf"
out="$tmproot/nojqcrlf.out"
run_hook "$out" "$h" closed "$stub"
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"
extract "$out"
assert_fgrep 'judge = crlfjudge-9, sonnet' "$out.ctx"
assert_fgrep 'build = crlfbuild-9, sonnet' "$out.ctx"
# ...and no stray CR was carried into the emitted context.
assert_no_grep $'\r' "$out.ctx"

# stdin is drained first: JSON on stdin, a closed stdin and a large piped
# payload all exit 0 (never 141/SIGPIPE, never a hang).
h=$(home_with_map "$tmproot")
payload="$tmproot/payload.json"
printf '{"session_id":"abc123","source":"startup","cwd":"/tmp"}\n' > "$payload"
out="$tmproot/stdin-json.out"
run_hook "$out" "$h" "file:$payload"
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"

out="$tmproot/stdin-closed.out"
run_hook "$out" "$h" closed
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"

big="$tmproot/big.json"
: > "$big"
i=0
while [ "$i" -lt 4000 ]; do
  printf '{"session_id":"abc123","transcript":"padding padding padding padding"}\n' >> "$big"
  i=$((i + 1))
done
out="$tmproot/stdin-pipe.out"
run_hook "$out" "$h" "pipe:$big"
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"

# ---------------------------------------------------------------------------
# instr_block <ctxfile> <outfile> — the instruction block alone: the marker line
# and every non-blank line after it. The constraint assertions below are about
# T7's instruction TEXT, so they must not be diluted by the map lines above it
# (nor by the trailing blank line jq's raw output carries).
instr_block() {
  awk '/^Engine-role announcement/ { f = 1 } f && NF' "$1" > "$2"
}

req "REQ-ENGINE-018"
# The hook is RUN and its emitted additionalContext read: the instructions there
# tell the session to open its first reply with ONE line naming the model it is
# running as and the roles that model covers.
h=$(home_with_map "$tmproot")
out="$tmproot/instr.out"
run_hook "$out" "$h" closed
assert_rc 0 "$out"
assert_exit 0 "$jqbin" -e . "$out"
extract "$out"
assert_fgrep 'State in ONE line, at the very start of your first reply' "$out.ctx"
assert_fgrep 'the model you are running as and the roles that model covers' "$out.ctx"

# The block really was located, so the "no match" assertions that follow are
# read against text rather than against an empty file.
instr_block "$out.ctx" "$out.instr"
assert_fgrep 'State in ONE line, at the very start of your first reply' "$out.instr"
# T6's hard constraint, asserted mechanically: the hand-built (no-jq) path drops
# any line holding a double quote, a backslash or a control character, so the
# instruction text must hold none of the three or it vanishes silently.
assert_no_grep '"' "$out.instr"
# a bracketed backslash: the one spelling every grep flavour here reads as
# "a literal backslash" (a bare '\\' is a shellcheck SC1003 trap)
assert_no_grep '[\\]' "$out.instr"
assert_no_grep '[[:cntrl:]]' "$out.instr"

# ...and the proof it survives where that matters: the same hook with jq stubbed
# off PATH ($stub, built above) still emits the instructions.
out2="$tmproot/instr-nojq.out"
run_hook "$out2" "$h" closed "$stub"
assert_rc 0 "$out2"
assert_exit 0 "$jqbin" -e . "$out2"
extract "$out2"
assert_fgrep 'State in ONE line, at the very start of your first reply' "$out2.ctx"
assert_fgrep 'the model you are running as and the roles that model covers' "$out2.ctx"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-019"
# The same emitted context instructs the judge-mismatch disclosure: a session not
# running the first model listed for judge says so in that same one line rather
# than routing as though it were.
assert_fgrep 'is not the FIRST model listed for judge' "$out.ctx"
assert_fgrep 'instead of routing as though it were' "$out.ctx"
assert_fgrep 'is not the FIRST model listed for judge' "$out2.ctx"
assert_fgrep 'instead of routing as though it were' "$out2.ctx"

# Every instruction line survives the no-jq path, not only the greppable ones:
# the block emitted without jq is identical, line for line, to jq's.
instr_block "$out2.ctx" "$out2.instr"
assert_exit 0 diff -u "$out.instr" "$out2.instr"

finish
