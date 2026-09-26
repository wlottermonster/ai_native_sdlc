#!/bin/bash
# AI-Native SDLC — content tests for the shipped engine map and role manifest.
# Covers REQ-ENGINE-005 (templates/sdlc-engines.conf exists, defines all four
# roles each with a primary and at least one fallback, and its comments explain
# the format and how to change it), REQ-ENGINE-006 (the line format, `#`
# comments and ignored blank lines), REQ-ENGINE-009 (agents/roles.conf maps
# every shipped agent to exactly one role and names no agent the repo does not
# ship) and REQ-ENGINE-039 (the shipped defaults: one working model for judge,
# build and verify, a cheaper one for read, plus an `escalate` entry).
#
# Both lists in the REQ-ENGINE-009 block are derived from the filesystem and
# from the manifest itself, never hard-coded, so shipping a new agent without
# a manifest line fails this test.
#
# Read-only assertions against shipped files; nothing here writes outside its
# own temp dir.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

conf="$repo/templates/sdlc-engines.conf"
manifest="$repo/agents/roles.conf"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-engine-map.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# strip <file> — the file with comment lines and blank lines removed, i.e.
# exactly what a parser of this format sees.
strip() {
  grep -vE '^[[:space:]]*(#|$)' "$1"
}

# primary <file> <key> — the first model listed for <key>, or the empty string.
primary() {
  awk -F'[[:space:]]*=[[:space:]]*' -v k="$2" '
    $1 == k { split($2, m, ","); gsub(/[[:space:]]/, "", m[1]); print m[1]; exit }
  ' "$1"
}

# ---------------------------------------------------------------------------
req "REQ-ENGINE-005"
assert_file "$conf"

# All four roles are defined, and each names a primary model plus at least one
# fallback (i.e. at least one comma on the line).
assert_grep '^judge[[:space:]]*=[[:space:]]*[^,]+,.+$' "$conf"
assert_grep '^build[[:space:]]*=[[:space:]]*[^,]+,.+$' "$conf"
assert_grep '^verify[[:space:]]*=[[:space:]]*[^,]+,.+$' "$conf"
assert_grep '^read[[:space:]]*=[[:space:]]*[^,]+,.+$' "$conf"

# The comments explain the format...
assert_grep '^#.*Format' "$conf"
assert_fgrep '<role> = <model>' "$conf"
assert_fgrep 'The FIRST model listed is the one that runs' "$conf"
assert_fgrep 'the rest are the fallback chain' "$conf"
# shellcheck disable=SC2016  # a literal phrase to search for, not a shell expansion
assert_fgrep 'first non-blank character is `#` is a comment' "$conf"
assert_fgrep 'Blank lines are ignored' "$conf"

# ...and how to change it: swapping the whole framework onto another model is
# three lines, and `escalate` is never reached automatically.
assert_fgrep 'To change the model the whole framework runs on' "$conf"
assert_fgrep 'three lines' "$conf"
assert_fgrep 'NEVER automatic' "$conf"
assert_fgrep 'The owner names it in the moment' "$conf"
# judge and escalate bind no agent — stated where the roles are described.
assert_grep '[Bb]inds no agent' "$conf"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-006"
# A representative entry has exactly the documented shape.
assert_grep '^judge = [a-z0-9._-]+, [a-z0-9._-]+$' "$conf"
# At least one comment line, and at least one blank line, so the parse below
# is actually exercised rather than passing over a file with neither.
assert_grep '^[[:space:]]*#' "$conf"
assert_grep '^[[:space:]]*$' "$conf"

# Parsing the file — comments and blank lines dropped — leaves only
# `key = value[, value...]` lines and nothing else.
strip "$conf" > "$tmpdir/parsed.txt"
grep -cvE '^[a-z][a-z0-9-]* = [a-z0-9._-]+(, [a-z0-9._-]+)*$' "$tmpdir/parsed.txt" \
  > "$tmpdir/malformed.txt" || true
assert_grep '^0$' "$tmpdir/malformed.txt"
# ...and that parse is not vacuous: five entries survive it.
grep -c '' "$tmpdir/parsed.txt" > "$tmpdir/entries.txt" || true
assert_grep '^5$' "$tmpdir/entries.txt"

# The same three rules hold for the role manifest.
assert_file "$manifest"
assert_grep '^[[:space:]]*#' "$manifest"
assert_grep '^[[:space:]]*$' "$manifest"
strip "$manifest" > "$tmpdir/parsed-roles.txt"
grep -cvE '^[a-z][a-z0-9-]* = [a-z][a-z0-9-]*$' "$tmpdir/parsed-roles.txt" \
  > "$tmpdir/malformed-roles.txt" || true
assert_grep '^0$' "$tmpdir/malformed-roles.txt"
# ...and that parse is not vacuous either: the manifest has entries.
grep -c '' "$tmpdir/parsed-roles.txt" > "$tmpdir/role-entries.txt" || true
assert_grep '^[1-9][0-9]*$' "$tmpdir/role-entries.txt"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-009"
# Both sides derived, never hard-coded: the agents the repo ships...
for f in "$repo"/agents/*.md; do
  [ -f "$f" ] || continue
  basename "$f" .md
done | LC_ALL=C sort > "$tmpdir/shipped.txt"
# ...and the agents the manifest names.
awk -F'[[:space:]]*=[[:space:]]*' '{ print $1 }' "$tmpdir/parsed-roles.txt" \
  | LC_ALL=C sort > "$tmpdir/named.txt"

# Neither list may be empty — an empty comparison must not read as a pass.
grep -c '' "$tmpdir/shipped.txt" > "$tmpdir/shipped-count.txt" || true
assert_grep '^[1-9][0-9]*$' "$tmpdir/shipped-count.txt"

# The two lists are identical: no shipped agent left out, no agent named that
# the repo does not ship.
diff "$tmpdir/shipped.txt" "$tmpdir/named.txt" > "$tmpdir/diff.txt" 2>&1
grep -c '' "$tmpdir/diff.txt" > "$tmpdir/diff-count.txt" || true
assert_grep '^0$' "$tmpdir/diff-count.txt"

# No agent is named twice.
LC_ALL=C uniq -d "$tmpdir/named.txt" > "$tmpdir/dupes.txt"
grep -c '' "$tmpdir/dupes.txt" > "$tmpdir/dupe-count.txt" || true
assert_grep '^0$' "$tmpdir/dupe-count.txt"

# Every shipped agent appears on exactly one manifest line, and every name in
# the manifest has a matching agents/<name>.md.
while IFS= read -r agent; do
  [ -n "$agent" ] || continue
  count_into "$tmpdir/parsed-roles.txt" "^$agent = " "$tmpdir/n.txt"
  assert_grep '^1$' "$tmpdir/n.txt"
done < "$tmpdir/shipped.txt"

while IFS= read -r agent; do
  [ -n "$agent" ] || continue
  assert_file "$repo/agents/$agent.md"
done < "$tmpdir/named.txt"

# Every role used in the manifest is a role the engine map defines.
awk -F'[[:space:]]*=[[:space:]]*' '{ print $1 }' "$tmpdir/parsed.txt" \
  | LC_ALL=C sort > "$tmpdir/roles.txt"
awk -F'[[:space:]]*=[[:space:]]*' '{ print $2 }' "$tmpdir/parsed-roles.txt" \
  | LC_ALL=C sort -u > "$tmpdir/roles-used.txt"
LC_ALL=C comm -13 "$tmpdir/roles.txt" "$tmpdir/roles-used.txt" > "$tmpdir/unknown.txt"
grep -c '' "$tmpdir/unknown.txt" > "$tmpdir/unknown-count.txt" || true
assert_grep '^0$' "$tmpdir/unknown-count.txt"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-039"
judge_primary=$(primary "$conf" judge)
build_primary=$(primary "$conf" build)
verify_primary=$(primary "$conf" verify)
read_primary=$(primary "$conf" read)

# judge, build and verify all run the SAME general working model.
if [ -n "$judge_primary" ] &&
   [ "$judge_primary" = "$build_primary" ] &&
   [ "$build_primary" = "$verify_primary" ]; then
  printf 'same\n' > "$tmpdir/working.txt"
else
  printf 'judge=%s build=%s verify=%s\n' \
    "$judge_primary" "$build_primary" "$verify_primary" > "$tmpdir/working.txt"
fi
assert_grep '^same$' "$tmpdir/working.txt"

# read runs a different (cheaper) model.
if [ -n "$read_primary" ] && [ "$read_primary" != "$judge_primary" ]; then
  printf 'differs\n' > "$tmpdir/reader.txt"
else
  printf 'read=%s judge=%s\n' "$read_primary" "$judge_primary" > "$tmpdir/reader.txt"
fi
assert_grep '^differs$' "$tmpdir/reader.txt"

# A fifth entry names the model reserved for deliberate escalation.
assert_grep '^escalate[[:space:]]*=[[:space:]]*[^,]+,.+$' "$conf"

finish
