#!/bin/bash
# AI-Native SDLC — behaviour tests for scripts/apply-engines.sh.
#
# This file covers the PARSING AND VALIDATION half of the script:
#   REQ-ENGINE-014  a manifest role the map does not define, a malformed line in
#                   either file, or an empty model name in a list → a message
#                   naming the offending FILE and LINE, a non-zero exit, and not
#                   one byte changed in any agent file.
#   REQ-ENGINE-027  a role the map defines but no agent is bound to (`judge`) is
#                   a no-op, never an error — so the SHIPPED map and the SHIPPED
#                   manifest must validate cleanly together.
#   REQ-ENGINE-042  `escalate` is the same case as `judge`, and equally not an
#                   error.
#   REQ-ENGINE-029  a manifest entry naming an agent that is not installed under
#                   $HOME/.claude/agents/ → a warning naming it, the rest of the
#                   run continues, exit 0.
#
# ...and the REWRITE half:
#   REQ-ENGINE-010  every installed agent's `model:` line becomes the FIRST model
#                   listed for that agent's role.
#   REQ-ENGINE-011  only that line changes: byte-exactness proved by
#                   reconstruction (snapshot → substitute the one line → `cmp`),
#                   never by a diff that is allowed to differ.
#   REQ-ENGINE-038  the frontmatter fence is the boundary: a body line beginning
#                   `model:` survives, a file with no `model:` line and a file
#                   with no fence are byte-unchanged, a file with no trailing
#                   newline neither gains nor loses one, and a CRLF file is left
#                   alone (its `---\r` lines are not a fence this script knows).
#   REQ-ENGINE-033  the write is a temp file in the agent's OWN directory renamed
#                   over the target: no stray temp survives a good run, and a run
#                   that cannot create the temp leaves the original byte-intact.
#
# ...and the REPORT:
#   REQ-ENGINE-013  one line per change naming the agent, the old model and the
#                   new model, plus the count of agents changed — asserted both
#                   as the number of change lines and as the tally's numeral, so
#                   a tally that disagrees with the lines above it fails.
#   REQ-ENGINE-012  a second run against an unchanged map rewrites nothing and
#                   says no agent changed: proved by the wording AND by `cmp` on
#                   every agent file across the second run.
#   REQ-ENGINE-028  an installed agent the manifest does not name is left
#                   byte-unchanged and reported as skipped, in wording that does
#                   not collide with the other skip (a managed agent with no
#                   eligible `model:` line) — both raised in the same run.
#   REQ-ENGINE-030  the manifest at $HOME/.claude/agents/roles.conf is preferred
#                   and the checkout's is the fallback: both paths exercised,
#                   the installed one binding an agent to a DIFFERENT role so
#                   the winner is visible in the model that gets written.
#
# Every run points HOME at a fresh mktemp -d and installs a fixture copy of the
# repo's agents into it: no assertion here reads or writes the real
# $HOME/.claude, and the whole tree is removed by the EXIT trap.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-apply-engines.XXXXXX")
# Normalised through `cd`+`pwd`: a $TMPDIR with a trailing slash makes mktemp
# hand back a path containing "//", which the script's own `cd ... && pwd`
# collapses. The error-message assertions below compare against paths the script
# printed, so both sides have to be spelled the same way.
tmproot=$(cd "$tmproot" && pwd)
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

# --- fixtures ---------------------------------------------------------------

# engine_fixture <parent> — a runnable checkout: the scripts, the agent prompts,
# the role manifest beside them, and the engine-map template. The script under
# test finds its manifest relative to its own location, so it has to be run out
# of a directory shaped like the repo, not out of a bare copy of one file.
engine_fixture() {
  local d f
  d=$(mktemp -d "$1/fixture.XXXXXX")
  mkdir -p "$d/scripts" "$d/agents" "$d/templates"
  cp "$TEST_REPO"/scripts/*.sh "$d/scripts/"
  cp "$TEST_REPO"/agents/*.md "$d/agents/"
  for f in "$TEST_REPO"/agents/*.conf; do
    [ -f "$f" ] && cp "$f" "$d/agents/"
  done
  cp "$TEST_REPO"/templates/*.conf "$d/templates/"
  printf '%s' "$d"
}

# engine_home <parent> <fixture> — a throwaway HOME with the fixture's agents
# installed under .claude/agents and the SHIPPED engine map as the owner's map.
engine_home() {
  local h
  h=$(mktemp -d "$1/home.XXXXXX")
  mkdir -p "$h/.claude/agents"
  cp "$2"/agents/*.md "$h/.claude/agents/"
  cp "$2/templates/sdlc-engines.conf" "$h/.claude/sdlc-engines.conf"
  printf '%s' "$h"
}

# run_apply <fixture> <home> <outfile>
run_apply() {
  capture "$3" env HOME="$2" bash "$1/scripts/apply-engines.sh"
}

# assert_unchanged <snapshot> <file> — byte-for-byte identity, the only honest
# reading of "leaves every agent file unchanged".
assert_unchanged() {
  if [ ! -f "$2" ]; then
    _test_fail "missing: $2"
  elif cmp -s "$1" "$2"; then
    _test_pass "byte-unchanged: $2"
  else
    _test_fail "expected byte-unchanged: $2"
  fi
}

# assert_bytes <expected-file> <actual-file> — <actual> is byte-for-byte the
# content <expected> was built to predict. Used for the reconstruction proof:
# the expected file is rebuilt from a snapshot by substituting exactly one line,
# so `cmp` failing means the script touched something it had no business
# touching.
assert_bytes() {
  if [ ! -f "$2" ]; then
    _test_fail "missing: $2"
  elif cmp -s "$1" "$2"; then
    _test_pass "byte-identical to the reconstruction: $2"
  else
    _test_fail "bytes differ from the reconstruction: $2"
  fi
}

# assert_str <expected> <actual> <what>
assert_str() {
  if [ "$1" = "$2" ]; then
    _test_pass "$3 = \"$1\""
  else
    _test_fail "$3: expected \"$1\", got \"$2\""
  fi
}

# fm_model <file> — the value of the `model:` line inside the leading
# frontmatter fence, read INDEPENDENTLY of the script under test (this is a
# plain reader; the script's own extractor is not reused, or the test would be
# asserting the implementation against itself). Empty when there is no fence or
# no `model:` line inside it.
fm_model() {
  awk '
    NR == 1 { if ($0 != "---") exit; fm = 1; next }
    fm && $0 == "---" { exit }
    fm && /^model:/ { sub(/^model:[ \t]*/, ""); print; exit }
  ' "$1"
}

# assert_model <file> <expected-model>
assert_model() {
  assert_str "$2" "$(fm_model "$1")" "frontmatter model of $(basename "$1")"
}

# assert_no_strays <agents-dir> — the directory holds agent prompts and nothing
# else: no leftover temp file from the rewrite, hidden or otherwise.
assert_no_strays() {
  local strays="$tmproot/strays.$$"
  find "$1" -mindepth 1 ! -name '*.md' > "$strays" 2>/dev/null
  count_into "$strays" '.' "$strays.count"
  assert_grep '^0$' "$strays.count"
}

# probe_map <home> — an engine map whose model names are INVENTED. The shipped
# map already says `opus` for build and `haiku` for read, which is what the
# shipped agents already carry: a run that did nothing at all would pass an
# assertion written against those values. Probe names cannot be arrived at by
# accident, so asserting them is asserting the rewrite.
probe_map() {
  cat > "$1/.claude/sdlc-engines.conf" <<'EOF'
judge = probe-judge-1, probe-judge-2
build = probe-build-1, probe-build-2
verify = probe-verify-1, probe-verify-2
read = probe-read-1, probe-read-2
escalate = probe-escalate-1, probe-escalate-2
EOF
}

# ---------------------------------------------------------------------------
req "REQ-ENGINE-027"
# The shipped map defines `judge`, which the shipped manifest binds to no agent.
# That combination is the default on every clean machine, so it must validate
# and exit 0 — this block fails the moment an unbound role is treated as an
# error.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")

# The premise, asserted rather than assumed: the map really does define `judge`
# and the manifest really does bind no agent to it.
assert_grep '^[[:space:]]*judge[[:space:]]*=' "$h/.claude/sdlc-engines.conf"
assert_no_grep '=[[:space:]]*judge[[:space:]]*$' "$d/agents/roles.conf"

out="$tmproot/shipped.out"
run_apply "$d" "$h" "$out"
assert_rc 0 "$out"
# ...and nothing in the output complains about the unbound role.
assert_no_grep '(ERROR|error|not defined).*judge' "$out"
# Exit 0 was not bought by doing nothing: the bound agents are still reported.
assert_grep 'implementer' "$out"
assert_grep 'researcher' "$out"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-042"
# `escalate` is the same case as `judge`: defined in the shipped map, bound to
# no agent, and not an error. Same clean run as the block above.
assert_grep '^[[:space:]]*escalate[[:space:]]*=' "$h/.claude/sdlc-engines.conf"
assert_no_grep '=[[:space:]]*escalate[[:space:]]*$' "$d/agents/roles.conf"
assert_rc 0 "$out"
assert_no_grep '(ERROR|error|not defined).*escalate' "$out"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-014"
# A manifest naming a role the map does not define: non-zero, a message naming
# the manifest file and the offending line number, and no agent file touched.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
cat > "$d/agents/roles.conf" <<'EOF'
# fixture manifest
implementer = build
researcher = read
verifier = nosuchrole
EOF
snap="$tmproot/implementer.snapshot"
cp "$h/.claude/agents/implementer.md" "$snap"
out="$tmproot/unknown-role.out"
run_apply "$d" "$h" "$out"
assert_rc nonzero "$out"
assert_fgrep "$d/agents/roles.conf:4:" "$out"
assert_grep 'nosuchrole' "$out"
assert_unchanged "$snap" "$h/.claude/agents/implementer.md"

# A malformed line in the MAP — no `=` at all: non-zero, naming the map and the
# line.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
cat > "$h/.claude/sdlc-engines.conf" <<'EOF'
# fixture map
judge = opus, sonnet
build opus
verify = opus
read = haiku
EOF
cp "$h/.claude/agents/implementer.md" "$snap"
out="$tmproot/malformed-map.out"
run_apply "$d" "$h" "$out"
assert_rc nonzero "$out"
assert_fgrep "$h/.claude/sdlc-engines.conf:3:" "$out"
assert_unchanged "$snap" "$h/.claude/agents/implementer.md"

# A malformed line in the MANIFEST — an empty key: non-zero, naming the
# manifest and the line.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
cat > "$d/agents/roles.conf" <<'EOF'
implementer = build
 = verify
EOF
cp "$h/.claude/agents/implementer.md" "$snap"
out="$tmproot/malformed-manifest.out"
run_apply "$d" "$h" "$out"
assert_rc nonzero "$out"
assert_fgrep "$d/agents/roles.conf:2:" "$out"
assert_unchanged "$snap" "$h/.claude/agents/implementer.md"

# An empty model name inside a list: non-zero, naming the map and the line.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
cat > "$h/.claude/sdlc-engines.conf" <<'EOF'
judge = opus, sonnet
build = opus,, sonnet
verify = opus
read = haiku
EOF
cp "$h/.claude/agents/implementer.md" "$snap"
out="$tmproot/empty-model.out"
run_apply "$d" "$h" "$out"
assert_rc nonzero "$out"
assert_fgrep "$h/.claude/sdlc-engines.conf:2:" "$out"
assert_unchanged "$snap" "$h/.claude/agents/implementer.md"

# An empty value — the whole right-hand side missing: same treatment.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
cat > "$h/.claude/sdlc-engines.conf" <<'EOF'
judge = opus
build =
verify = opus
read = haiku
EOF
cp "$h/.claude/agents/implementer.md" "$snap"
out="$tmproot/empty-value.out"
run_apply "$d" "$h" "$out"
assert_rc nonzero "$out"
assert_fgrep "$h/.claude/sdlc-engines.conf:2:" "$out"
assert_unchanged "$snap" "$h/.claude/agents/implementer.md"

# Validation covers the WHOLE of both files before anything happens: a fault on
# the last line of the manifest is caught even though every line before it is
# good and would otherwise have been acted on first.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
cat > "$d/agents/roles.conf" <<'EOF'
implementer = build
researcher = read
verifier = verify
evidence = ghostrole
EOF
cp "$h/.claude/agents/implementer.md" "$snap"
out="$tmproot/late-fault.out"
run_apply "$d" "$h" "$out"
assert_rc nonzero "$out"
assert_fgrep "$d/agents/roles.conf:4:" "$out"
assert_unchanged "$snap" "$h/.claude/agents/implementer.md"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-029"
# A manifest entry naming an agent that is not installed is a warning, not a
# failure: it is named, the rest of the manifest is still processed, exit 0.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
cat > "$d/agents/roles.conf" <<'EOF'
implementer = build
ghost-agent = verify
researcher = read
EOF
out="$tmproot/missing-agent.out"
run_apply "$d" "$h" "$out"
assert_rc 0 "$out"
assert_grep 'WARNING' "$out"
assert_grep 'ghost-agent' "$out"
# "continue with the rest" — the entries after the missing one are still there.
assert_grep 'researcher' "$out"
assert_grep 'implementer' "$out"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-010"
# The SHIPPED manifest, the shipped agents, and a map with the shipped roles but
# invented model names: every installed agent ends up carrying the FIRST model
# of its role. Seven agents, three roles.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")

# The premise, asserted rather than assumed: these are the shipped bindings, and
# the shipped map defines every role they name.
assert_grep '^implementer[[:space:]]*=[[:space:]]*build$' "$d/agents/roles.conf"
assert_grep '^researcher[[:space:]]*=[[:space:]]*read$' "$d/agents/roles.conf"
for a in spec-reviewer verifier evidence ui-tester test-auditor; do
  assert_grep "^${a}[[:space:]]*=[[:space:]]*verify$" "$d/agents/roles.conf"
done
assert_grep '^[[:space:]]*build[[:space:]]*=' "$h/.claude/sdlc-engines.conf"
assert_grep '^[[:space:]]*read[[:space:]]*=' "$h/.claude/sdlc-engines.conf"
assert_grep '^[[:space:]]*verify[[:space:]]*=' "$h/.claude/sdlc-engines.conf"

# ...and that the agents do NOT already carry the probe names, so every
# assertion below is about what this run did.
assert_no_grep '^model: probe-' "$h/.claude/agents/implementer.md"

probe_map "$h"
out="$tmproot/e010.out"
run_apply "$d" "$h" "$out"
assert_rc 0 "$out"

assert_model "$h/.claude/agents/implementer.md" "probe-build-1"
assert_model "$h/.claude/agents/researcher.md" "probe-read-1"
for a in spec-reviewer verifier evidence ui-tester test-auditor; do
  assert_model "$h/.claude/agents/$a.md" "probe-verify-1"
done

# The FIRST model, not some later one in the fallback chain.
assert_no_grep '^model: probe-build-2$' "$h/.claude/agents/implementer.md"
assert_no_grep '^model: probe-read-2$' "$h/.claude/agents/researcher.md"

# The model name is written VERBATIM. The map's own documentation promises
# pass-through, so a name carrying a backslash — which several string tools,
# `awk -v` among them, would quietly read as an escape — must arrive intact.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
cat > "$h/.claude/sdlc-engines.conf" <<'EOF'
judge = probe-judge-1
build = probe\build-1
verify = probe-verify-1
read = probe-read-1
escalate = probe-escalate-1
EOF
out="$tmproot/e010-verbatim.out"
run_apply "$d" "$h" "$out"
assert_rc 0 "$out"
assert_model "$h/.claude/agents/implementer.md" 'probe\build-1'

# ---------------------------------------------------------------------------
req "REQ-ENGINE-011"
# Byte-exactness by RECONSTRUCTION: snapshot the file, run the script, rebuild
# what the file should now contain by replacing exactly one line of the
# snapshot, and `cmp`. A diff that ignores the model line would pass even if the
# script had rewritten the body; this cannot.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
probe_map "$h"

for a in implementer test-auditor researcher; do
  snap="$tmproot/e011.$a.snap"
  cp "$h/.claude/agents/$a.md" "$snap"

  # The line number is found independently of the script under test, and the
  # premises that make the substitution the RIGHT prediction are asserted: line
  # 1 opens the fence, the fence closes later, and the first `model:` line falls
  # between the two.
  head -n 1 "$snap" > "$tmproot/e011.$a.first"
  assert_grep '^---$' "$tmproot/e011.$a.first"
  n=$(grep -n '^model:' "$snap" | head -n 1 | cut -d: -f1)
  c=$(grep -n '^---$' "$snap" | sed -n '2p' | cut -d: -f1)
  if [ -n "$n" ] && [ -n "$c" ] && [ "$n" -gt 1 ] && [ "$n" -lt "$c" ]; then
    _test_pass "model: line $n lies inside the fence (closes at $c): $a.md"
  else
    _test_fail "premise broken: model: line \"$n\", closing fence \"$c\": $a.md"
  fi
  # ...and that the snapshot ends with a newline, so a line-wise rebuild of it
  # is a faithful prediction of the bytes.
  if [ -z "$(tail -c 1 "$snap")" ]; then
    _test_pass "snapshot ends with a newline: $a.md"
  else
    _test_fail "premise broken: snapshot has no trailing newline: $a.md"
  fi
done

# The file's MODE is part of leaving it alone: a rewrite that renames a fresh
# mktemp over the target would otherwise hand every agent mktemp's 0600.
chmod 640 "$h/.claude/agents/implementer.md"

out="$tmproot/e011.out"
run_apply "$d" "$h" "$out"
assert_rc 0 "$out"

# shellcheck disable=SC2012  # a fixed temp path, and `stat`'s format flags
# differ between BSD and GNU — `ls -l`'s mode column is the portable reading
assert_str "-rw-r-----" \
  "$(ls -l "$h/.claude/agents/implementer.md" | awk '{ print substr($1, 1, 10) }')" \
  "mode of implementer.md after the rewrite"

for a in implementer:probe-build-1 test-auditor:probe-verify-1 \
         researcher:probe-read-1; do
  agent=${a%%:*}
  model=${a##*:}
  snap="$tmproot/e011.$agent.snap"
  n=$(grep -n '^model:' "$snap" | head -n 1 | cut -d: -f1)
  awk -v n="$n" -v repl="model: $model" 'NR == n { print repl; next } { print }' \
    "$snap" > "$tmproot/e011.$agent.expected"
  assert_bytes "$tmproot/e011.$agent.expected" "$h/.claude/agents/$agent.md"
done

# ---------------------------------------------------------------------------
req "REQ-ENGINE-038"
# The fence is the boundary. Five hand-built agents, each installed and bound to
# `build` in the manifest, each with its expected bytes written out by hand.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
probe_map "$h"
ag="$h/.claude/agents"
exp="$tmproot/e038"
mkdir -p "$exp"

cat > "$d/agents/roles.conf" <<'EOF'
fx-body = build
fx-bodyonly = build
fx-nomodel = build
fx-nofence = build
fx-nonl = build
fx-crlf = build
fx-ws = build
fx-tight = build
fx-wide = build
fx-tab = build
EOF

# (a) a body line beginning `model:` — the frontmatter one changes, the body one
# does not.
printf '%s\n' '---' 'name: fx-body' 'model: opus' 'tools: Read' '---' \
  'Prose about frontmatter.' 'model: not-this-one' 'Trailing prose.' \
  > "$ag/fx-body.md"
printf '%s\n' '---' 'name: fx-body' 'model: probe-build-1' 'tools: Read' '---' \
  'Prose about frontmatter.' 'model: not-this-one' 'Trailing prose.' \
  > "$exp/fx-body.md"

# (a2) a body line beginning `model:` and NO `model:` line in the frontmatter:
# the file is byte-unchanged. This is the fixture that catches a rewrite which
# looks for the first `model:` line in the FILE rather than in the fence.
printf '%s\n' '---' 'name: fx-bodyonly' 'tools: Read' '---' 'Prose.' \
  'model: still-not-this-one' 'More prose.' > "$ag/fx-bodyonly.md"
cp "$ag/fx-bodyonly.md" "$exp/fx-bodyonly.md"

# (b) no `model:` line anywhere.
printf '%s\n' '---' 'name: fx-nomodel' 'tools: Read' '---' 'Body.' \
  > "$ag/fx-nomodel.md"
cp "$ag/fx-nomodel.md" "$exp/fx-nomodel.md"

# (c) no leading fence at all — line 1 is not `---`, so the `model:` line below
# it is body, not frontmatter.
printf '%s\n' '# fx-nofence' 'model: opus' 'Body.' > "$ag/fx-nofence.md"
cp "$ag/fx-nofence.md" "$exp/fx-nofence.md"

# (d) no trailing newline: the model line changes and no newline is invented.
printf '%s' '---
name: fx-nonl
model: opus
---
Body with no trailing newline.' > "$ag/fx-nonl.md"
printf '%s' '---
name: fx-nonl
model: probe-build-1
---
Body with no trailing newline.' > "$exp/fx-nonl.md"

# (e) CRLF line endings. DECISION: such a file is left completely unchanged —
# `---\r` is not the fence this script recognises, so it has no frontmatter to
# rewrite and the script reports it as skipped rather than half-converting the
# file's line endings.
printf '%s\r\n' '---' 'name: fx-crlf' 'model: opus' '---' 'Body.' \
  > "$ag/fx-crlf.md"
cp "$ag/fx-crlf.md" "$exp/fx-crlf.md"

# (f) trailing whitespace on lines the rewrite must not touch — one inside the
# fence, one in the body, plus a whitespace-only line. awk's default record
# handling makes it tempting to "tidy" each line on the way past; nothing here
# is tidied, so a rewrite that trims is caught rather than passing because no
# fixture happened to have any. (The `model:` line itself is excluded: its whole
# tail after the `model:` prefix is the value being replaced.)
{
  printf -- '---\n'
  printf 'name: fx-ws  \n'
  printf 'model: opus\n'
  printf -- '---\n'
  printf 'Body line with trailing spaces.   \n'
  printf '\t\n'
  printf 'Body line with a trailing tab.\t\n'
} > "$ag/fx-ws.md"
{
  printf -- '---\n'
  printf 'name: fx-ws  \n'
  printf 'model: probe-build-1\n'
  printf -- '---\n'
  printf 'Body line with trailing spaces.   \n'
  printf '\t\n'
  printf 'Body line with a trailing tab.\t\n'
} > "$exp/fx-ws.md"

# (g) the three other spellings of the separator after `model:`. The value is
# replaced; the KEY and the exact spacing the file was written with are carried
# over, so `model:opus` stays tight, `model:   opus` keeps its three spaces and
# a tab stays a tab. Without these a rewrite that emits a canonical
# `model: <value>` is indistinguishable from one that preserves the line.
printf '%s\n' '---' 'name: fx-tight' 'model:opus' '---' 'Body.' \
  > "$ag/fx-tight.md"
printf '%s\n' '---' 'name: fx-tight' 'model:probe-build-1' '---' 'Body.' \
  > "$exp/fx-tight.md"

printf '%s\n' '---' 'name: fx-wide' 'model:   opus' '---' 'Body.' \
  > "$ag/fx-wide.md"
printf '%s\n' '---' 'name: fx-wide' 'model:   probe-build-1' '---' 'Body.' \
  > "$exp/fx-wide.md"

{
  printf -- '---\n'
  printf 'name: fx-tab\n'
  printf 'model:\topus\n'
  printf -- '---\n'
  printf 'Body.\n'
} > "$ag/fx-tab.md"
{
  printf -- '---\n'
  printf 'name: fx-tab\n'
  printf 'model:\tprobe-build-1\n'
  printf -- '---\n'
  printf 'Body.\n'
} > "$exp/fx-tab.md"

out="$tmproot/e038.out"
run_apply "$d" "$h" "$out"
# An agent with nothing to rewrite is not a failure.
assert_rc 0 "$out"

assert_bytes "$exp/fx-body.md" "$ag/fx-body.md"
assert_grep '^model: not-this-one$' "$ag/fx-body.md"
assert_bytes "$exp/fx-bodyonly.md" "$ag/fx-bodyonly.md"
assert_grep '^model: still-not-this-one$' "$ag/fx-bodyonly.md"
assert_bytes "$exp/fx-nomodel.md" "$ag/fx-nomodel.md"
assert_bytes "$exp/fx-nofence.md" "$ag/fx-nofence.md"
assert_bytes "$exp/fx-nonl.md" "$ag/fx-nonl.md"
# ...and the no-newline file still ends without one.
if [ -n "$(tail -c 1 "$ag/fx-nonl.md")" ]; then
  _test_pass "still ends without a trailing newline: fx-nonl.md"
else
  _test_fail "a trailing newline was invented: fx-nonl.md"
fi
assert_bytes "$exp/fx-crlf.md" "$ag/fx-crlf.md"
assert_bytes "$exp/fx-ws.md" "$ag/fx-ws.md"
assert_bytes "$exp/fx-tight.md" "$ag/fx-tight.md"
assert_bytes "$exp/fx-wide.md" "$ag/fx-wide.md"
assert_bytes "$exp/fx-tab.md" "$ag/fx-tab.md"

# The REPORT agrees with the bytes. `assert_bytes` alone cannot tell a file the
# script decided to skip from one it decided to change and then rewrote
# identically — and the two decisions call for opposite fixes — so the fence
# skips are asserted as report lines too, not only as unchanged bytes.
assert_grep '^skipped fx-nofence: no "model:" line inside a leading frontmatter fence' "$out"
assert_grep '^skipped fx-crlf: no "model:" line inside a leading frontmatter fence' "$out"
assert_grep '^skipped fx-nomodel: no "model:" line inside a leading frontmatter fence' "$out"
assert_grep '^skipped fx-bodyonly: no "model:" line inside a leading frontmatter fence' "$out"
assert_no_grep '^changed fx-(nofence|crlf|nomodel|bodyonly)' "$out"
# ...and the fixtures that DO have an eligible line are reported as changed, so
# the four skips above are not the vacuous pass of a run that skipped the lot.
assert_no_grep '^skipped fx-(body|nonl|ws|tight|wide|tab):' "$out"
assert_grep '^changed fx-body: model: opus -> probe-build-1 \(role build\)$' "$out"
assert_grep '^changed fx-tight: model: opus -> probe-build-1 \(role build\)$' "$out"
assert_grep '^changed fx-wide: model: opus -> probe-build-1 \(role build\)$' "$out"
assert_grep '^changed fx-tab: model: opus -> probe-build-1 \(role build\)$' "$out"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-033"
# The write is a temp file in the agent's own directory, renamed over the
# target. Two observable consequences.

# (1) A good run leaves no temp behind — and it really did write, so "no
# strays" is not the vacuous pass of a script that did nothing.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
probe_map "$h"
out="$tmproot/e033.out"
run_apply "$d" "$h" "$out"
assert_rc 0 "$out"
assert_model "$h/.claude/agents/implementer.md" "probe-build-1"
assert_no_strays "$h/.claude/agents"

# (2) A run that cannot create that temp — the agents directory is not writable,
# which is where an interruption before the rename lands — leaves the original
# byte-identical and nothing partial beside it.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
probe_map "$h"
snap="$tmproot/e033.implementer.snap"
cp "$h/.claude/agents/implementer.md" "$snap"
if [ "$(id -u)" -eq 0 ]; then
  _test_fail "running as root: an unwritable directory cannot be simulated"
else
  chmod 500 "$h/.claude/agents"
  out="$tmproot/e033-ro.out"
  run_apply "$d" "$h" "$out"
  chmod 700 "$h/.claude/agents"   # before the assertions, so cleanup can rm it
  assert_rc nonzero "$out"
  assert_fgrep "$h/.claude/agents/implementer.md" "$out"
  assert_unchanged "$snap" "$h/.claude/agents/implementer.md"
  assert_no_strays "$h/.claude/agents"
fi

# (3) A read-only AGENT FILE in a writable directory is still rewritten, and
# keeps its mode. The temp takes the target's mode from `cp -p`, so without an
# explicit widen-then-restore the script's own redirect fails on its own temp
# and the map can never be applied to that agent.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
probe_map "$h"
if [ "$(id -u)" -eq 0 ]; then
  _test_fail "running as root: a read-only file cannot be simulated"
else
  chmod 444 "$h/.claude/agents/implementer.md"
  out="$tmproot/e033-rofile.out"
  run_apply "$d" "$h" "$out"
  assert_rc 0 "$out"
  assert_model "$h/.claude/agents/implementer.md" "probe-build-1"
  assert_no_strays "$h/.claude/agents"
  # ...and the mode survived the rewrite: still not writable by its owner.
  if [ -w "$h/.claude/agents/implementer.md" ]; then
    _test_fail "the rewrite widened the agent file's mode: implementer.md"
  else
    _test_pass "read-only mode preserved across the rewrite: implementer.md"
  fi
  chmod 644 "$h/.claude/agents/implementer.md"
fi

# ---------------------------------------------------------------------------
req "REQ-ENGINE-013"
# One line per CHANGE, naming the agent, the old model and the new model, and
# the COUNT of agents changed. The probe map's model names cannot be arrived at
# by accident, so the old -> new pair asserted below is a real rewrite; and the
# count is asserted twice over — once as the number of `changed` lines, once as
# the numeral in the tally — so a tally that is merely a plausible number
# disagreeing with the lines above it fails.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
probe_map "$h"

# The premise, asserted rather than assumed: the shipped manifest binds exactly
# seven agents, and all seven are installed.
count_into "$d/agents/roles.conf" '^[a-z][a-z-]*[[:space:]]*=' \
  "$tmproot/e013.bound.count"
assert_grep '^7$' "$tmproot/e013.bound.count"
ls "$h/.claude/agents"/*.md > "$tmproot/e013.installed"
count_into "$tmproot/e013.installed" '\.md$' "$tmproot/e013.installed.count"
assert_grep '^7$' "$tmproot/e013.installed.count"

out="$tmproot/e013.out"
run_apply "$d" "$h" "$out"
assert_rc 0 "$out"

# Three roles, three agents, each line naming the agent, the old model and the
# new one.
assert_grep '^changed implementer: model: opus -> probe-build-1 \(role build\)$' "$out"
assert_grep '^changed researcher: model: haiku -> probe-read-1 \(role read\)$' "$out"
assert_grep '^changed verifier: model: opus -> probe-verify-1 \(role verify\)$' "$out"

# One line per change, no more and no less.
count_into "$out" '^changed ' "$tmproot/e013.changed.count"
assert_grep '^7$' "$tmproot/e013.changed.count"

# ...and the count of agents changed, printed.
assert_grep '^apply-engines\.sh: 7 changed, 0 unchanged, 0 skipped\.$' "$out"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-012"
# A SECOND run against the same home, with the map untouched: nothing is
# rewritten and the report says so. Proved two ways — the wording, and the
# bytes of every agent file across the second run. mtime would not do: a
# rewrite that produced identical content would still be a rewrite, and a
# rewrite that produced different content with a preserved mtime would still be
# a change. `cmp` is the honest reading of "rewrote nothing".
snapdir="$tmproot/e012.snap"
mkdir -p "$snapdir"
for f in "$h"/.claude/agents/*.md; do
  cp "$f" "$snapdir/$(basename "$f")"
done

out2="$tmproot/e012.out"
run_apply "$d" "$h" "$out2"
assert_rc 0 "$out2"

# The wording: no change lines at all, a zero count, and the run saying in
# words that no agent changed.
count_into "$out2" '^changed ' "$tmproot/e012.changed.count"
assert_grep '^0$' "$tmproot/e012.changed.count"
assert_fgrep 'no agent changed' "$out2"
assert_grep '^apply-engines\.sh: 0 changed, 7 unchanged, 0 skipped' "$out2"
# Zero changes was not bought by doing nothing at all: the seven agents are
# still each accounted for.
count_into "$out2" '^unchanged ' "$tmproot/e012.unchanged.count"
assert_grep '^7$' "$tmproot/e012.unchanged.count"

# The bytes: every agent file identical across the second run.
for f in "$h"/.claude/agents/*.md; do
  assert_unchanged "$snapdir/$(basename "$f")" "$f"
done
assert_no_strays "$h/.claude/agents"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-028"
# An agent installed under $HOME/.claude/agents/ that the manifest does not
# name is left byte-unchanged and reported as SKIPPED — and that report is
# distinguishable from the other skip, an agent the manifest DOES name whose
# file has no eligible `model:` line. Both are exercised in the same run, so
# the two wordings are compared against each other and not just each read on
# its own.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
probe_map "$h"

# (1) not named in the manifest — the manifest is the SHIPPED one, appended to,
# so the seven shipped agents stay bound and this file is the only stranger.
cat > "$h/.claude/agents/stray-agent.md" <<'EOF'
---
name: stray-agent
model: someone-elses-model
tools: Read
---
An agent this framework did not install and does not manage.
EOF
straysnap="$tmproot/e028.stray.snap"
cp "$h/.claude/agents/stray-agent.md" "$straysnap"

# (2) named in the manifest, but nothing eligible to rewrite.
printf 'fx-nomodel = build\n' >> "$d/agents/roles.conf"
printf '%s\n' '---' 'name: fx-nomodel' 'tools: Read' '---' 'Body.' \
  > "$h/.claude/agents/fx-nomodel.md"
nomodelsnap="$tmproot/e028.nomodel.snap"
cp "$h/.claude/agents/fx-nomodel.md" "$nomodelsnap"

out="$tmproot/e028.out"
run_apply "$d" "$h" "$out"
# An unmanaged agent is not a failure.
assert_rc 0 "$out"

# Byte-unchanged, both of them.
assert_unchanged "$straysnap" "$h/.claude/agents/stray-agent.md"
assert_unchanged "$nomodelsnap" "$h/.claude/agents/fx-nomodel.md"

# Reported as skipped, naming it, and naming the manifest it is absent from.
assert_grep '^skipped stray-agent: not named in ' "$out"
assert_fgrep "$d/agents/roles.conf" "$out"

# The OTHER skip, same run, and its reason is a different sentence: greping for
# either one must not find the other.
assert_grep '^skipped fx-nomodel: no "model:" line inside a leading frontmatter fence' "$out"
grep '^skipped ' "$out" > "$tmproot/e028.skips"
count_into "$tmproot/e028.skips" '^skipped ' "$tmproot/e028.skips.count"
assert_grep '^2$' "$tmproot/e028.skips.count"
count_into "$tmproot/e028.skips" 'not named in' "$tmproot/e028.unmanaged.count"
assert_grep '^1$' "$tmproot/e028.unmanaged.count"
count_into "$tmproot/e028.skips" 'no "model:" line' "$tmproot/e028.nomodel.count"
assert_grep '^1$' "$tmproot/e028.nomodel.count"

# The unmanaged agent is skipped, not counted as an agent that changed.
assert_no_grep '^changed stray-agent' "$out"
assert_grep '^apply-engines\.sh: 7 changed, 0 unchanged, 2 skipped\.$' "$out"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-030"
# The manifest is looked for at $HOME/.claude/agents/roles.conf FIRST, and the
# one beside the running script's checkout is the fallback.

# (1) An installed manifest that DIFFERS from the checkout's — it binds
# implementer to `read` where the checkout binds it to `build`, and names a
# ghost agent the checkout's does not. Three independent tells that the
# installed copy won: the model implementer ends up with, the warning naming
# the ghost, and the path that warning prints.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
probe_map "$h"
assert_grep '^implementer[[:space:]]*=[[:space:]]*build$' "$d/agents/roles.conf"
cat > "$h/.claude/agents/roles.conf" <<'EOF'
implementer = read
ghost-of-the-installed-manifest = build
EOF

out="$tmproot/e030-installed.out"
run_apply "$d" "$h" "$out"
assert_rc 0 "$out"
# The installed manifest's binding is the one that was applied.
assert_model "$h/.claude/agents/implementer.md" "probe-read-1"
assert_grep '^changed implementer: model: opus -> probe-read-1 \(role read\)$' "$out"
# ...and the checkout's binding was NOT.
assert_no_grep 'probe-build-1' "$out"
# The warning names the ghost agent, and names the INSTALLED manifest as the
# file that asked for it.
assert_grep 'ghost-of-the-installed-manifest' "$out"
assert_fgrep "$h/.claude/agents/roles.conf" "$out"
if grep -qF -- "$d/agents/roles.conf" "$out"; then
  _test_fail "the checkout manifest was consulted anyway: $d/agents/roles.conf"
else
  _test_pass "the checkout manifest was not consulted: $d/agents/roles.conf"
fi
# researcher is bound by the checkout's manifest but not the installed one, so
# under the installed manifest it is simply an agent nobody named.
assert_grep '^skipped researcher: not named in ' "$out"

# (2) No installed manifest: the checkout's is used.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
probe_map "$h"
if [ -e "$h/.claude/agents/roles.conf" ]; then
  _test_fail "premise broken: an installed manifest exists at $h/.claude/agents/roles.conf"
else
  _test_pass "no installed manifest: $h/.claude/agents/roles.conf"
fi

out="$tmproot/e030-checkout.out"
run_apply "$d" "$h" "$out"
assert_rc 0 "$out"
# The checkout's binding — implementer = build — is the one that was applied.
assert_model "$h/.claude/agents/implementer.md" "probe-build-1"
assert_grep '^changed implementer: model: opus -> probe-build-1 \(role build\)$' "$out"
assert_model "$h/.claude/agents/researcher.md" "probe-read-1"

finish
