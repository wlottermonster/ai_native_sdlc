#!/bin/bash
# AI-Native SDLC — routing tests. Covers REQ-GCORE-027 (the sdlc-policy.md
# routing table carries the test-audit and RCA rows) and REQ-ENGINE-032 (those
# rows bind a ROLE rather than a model, the test-auditor frontmatter declares a
# model without pinning which one, and the two model-naming generic-core
# requirements — REQ-GCORE-026 and the engine half of REQ-GCORE-027 — are
# marked superseded in place in the shipped spec).
#
# Read-only: nothing here writes outside its own mktemp -d scratch dir.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-routing.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

policy="$repo/sdlc-policy.md"
agent="$repo/agents/test-auditor.md"

# assert_line_has <anchor> <token> <file> — a single line of <file> containing
# the fixed string <anchor> must also contain the fixed string <token>. Both
# comparisons are grep -F, so no character in either argument is special.
assert_line_has() {
  local anchor="$1" token="$2" file="$3"
  if [ -f "$file" ] &&
     grep -F -- "$anchor" "$file" 2>/dev/null | grep -qF -- "$token"; then
    _test_pass "line with '$anchor' also has '$token' : $file"
  else
    _test_fail "expected one line with '$anchor' and '$token' in $file"
  fi
}

# assert_superseded <req-id> <superseder-id> <file> — the shipped requirement
# must STILL be present (the audit trail: a superseded claim is annotated in
# place, never deleted) and its own block must carry a note naming what
# supersedes it. The block is the ID's line plus every following line up to,
# but not including, the next line starting a requirement in column 1 — so the
# indented note, which itself names a REQ id, counts as part of the block.
assert_superseded() {
  local id="$1" by="$2" file="$3" block
  if [ ! -f "$file" ]; then
    _test_fail "missing: $file"
    return
  fi
  if ! grep -qF -- "$id" "$file"; then
    _test_fail "expected $id to still be present (superseded, not deleted) in $file"
    return
  fi
  block=$(awk -v id="$id" '
    !seen && index($0, id) { seen = 1; print; next }
    seen && /^REQ-/ { exit }
    seen { print }' "$file")
  if printf '%s\n' "$block" | grep -qF -- "SUPERSEDED by $by"; then
    _test_pass "$id is marked 'SUPERSEDED by $by' in place : $file"
  else
    _test_fail "expected a 'SUPERSEDED by $by' note in the $id block of $file"
  fi
}

# ---------------------------------------------------------------------------
# REQ-GCORE-027 — the routing table carries a "Test-suite audit" row naming the
# `test-auditor` agent and an "RCA root cause" row naming the main session.
# The half of that requirement that named the ENGINE is superseded; the rows
# themselves and who runs them are still its claim, and are asserted here.
req "REQ-GCORE-027"

assert_file "$policy"

# The audit row: one table line names the phase and the agent.
assert_line_has 'Test-suite audit' 'test-auditor' "$policy"

# The RCA row: one table line names the phase and the main session.
assert_line_has 'RCA root cause' 'main session' "$policy"

# Positive control — the pre-existing rows must survive untouched. If these
# fail, the table was rewritten rather than appended to.
assert_line_has 'Tests-first + implementation' 'implementer' "$policy"
assert_line_has 'Independent verification' 'verifier' "$policy"

# ---------------------------------------------------------------------------
# REQ-ENGINE-032 — these four assertions replace the model half of
# REQ-GCORE-027 (which pinned Opus on the audit, build and verify rows and
# Fable on the RCA row). The table no longer names a model anywhere: each row
# ends in the ROLE that runs it, and `~/.claude/sdlc-engines.conf` is the one
# place that role is bound to a model.
req "REQ-ENGINE-032"

assert_line_has 'Test-suite audit' 'verify' "$policy"
assert_line_has 'RCA root cause' 'judge' "$policy"
assert_line_has 'Tests-first + implementation' 'build' "$policy"
assert_line_has 'Independent verification' 'verify' "$policy"

# ---------------------------------------------------------------------------
# REQ-ENGINE-032 — replaces the REQ-GCORE-026 assertions here, which pinned the
# exact line `model: opus`. agents/test-auditor.md still declares A model — the
# repo ships a working default, and apply-engines.sh rewrites the line in the
# INSTALLED copy under ~/.claude — but WHICH model is the engine map's call,
# not this file's, so the value is no longer pinned. Same structure as before:
# the declaration is near the top AND inside the frontmatter fence.
req "REQ-ENGINE-032"

assert_file "$agent"

# Declared as its own line, inside the first 6 lines of the file.
head -6 "$agent" > "$tmpdir/agent-head.txt" 2>/dev/null || : > "$tmpdir/agent-head.txt"
assert_grep '^model: [a-z]' "$tmpdir/agent-head.txt"

# ...and inside the frontmatter fence, not merely somewhere near the top:
# everything strictly between the first and second `---` lines.
awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside' \
  "$agent" > "$tmpdir/agent-frontmatter.txt" 2>/dev/null ||
  : > "$tmpdir/agent-frontmatter.txt"
assert_grep '^model: [a-z]' "$tmpdir/agent-frontmatter.txt"

# ---------------------------------------------------------------------------
# REQ-ENGINE-032 — the two shipped generic-core requirements that pinned a
# model by name are marked superseded IN PLACE. Both must still be readable in
# the shipped spec (deleting a claim destroys the audit trail; the point is
# that the old claim and the reason it no longer holds sit side by side), and
# each must carry a note naming the requirement that superseded it.
req "REQ-ENGINE-032"

shipped="$repo/specs/_shipped/2026-09-03-generic-core/requirements.md"
assert_file "$shipped"

# REQ-GCORE-026 pinned `model: opus` in the agent frontmatter; REQ-GCORE-027
# pinned Opus and Fable on the routing rows.
assert_superseded 'REQ-GCORE-026' 'REQ-ENGINE-032' "$shipped"
assert_superseded 'REQ-GCORE-027' 'REQ-ENGINE-032' "$shipped"

# The original claims survive verbatim beside their notes — a note that
# replaced the text it annotates would defeat the purpose.
# shellcheck disable=SC2016  # the backticks are markdown in the quoted spec line
assert_fgrep 'SHALL declare `model: opus`.' "$shipped"
assert_fgrep 'agent on Opus and a row routing "RCA root cause" to the main' "$shipped"

finish
