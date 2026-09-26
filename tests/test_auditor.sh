#!/bin/bash
# AI-Native SDLC — content tests for agents/test-auditor.md, the read-only
# auditor of a repo's TEST SUITE. Covers REQ-GCORE-020 (coverage currency:
# name the test that would fail if the change were reverted, else UNCOVERED),
# REQ-GCORE-021 (mutation honesty runs the full suite per mutation, never a
# filtered subset), REQ-GCORE-036 (HOLLOW only after a second confirming run),
# REQ-GCORE-037 (budget: 5 mutations or 10 minutes) and REQ-GCORE-022 (stale
# assertions pinned to a literal caption, colour name or URL string, with a
# fact-level replacement proposed), REQ-GCORE-023 (unclosed findings re-checked
# from previous reports under specs/_audit/), REQ-GCORE-025 (write tools denied;
# mutations applied with Bash to a scratchpad copy only) and REQ-GCORE-038 (a
# clean `git status --porcelain` at the end of every lane, else lane FAIL).
# Also REQ-ENGINE-032 (the frontmatter declares a model without this suite
# pinning which one; the role binding lives in agents/roles.conf).
#
# These are read-only assertions against the shipped prompt file; nothing here
# writes outside the repo.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

auditor="$repo/agents/test-auditor.md"

# ---------------------------------------------------------------------------
req "REQ-GCORE-020"
assert_file "$auditor"
# It is an agent file in the house style: frontmatter naming the agent, a
# one-line description, the model, and the write tools denied.
assert_grep '^name: test-auditor$' "$auditor"
assert_grep '^description: ' "$auditor"
assert_grep '^disallowedTools: Write, Edit, NotebookEdit$' "$auditor"
# (the `model:` line is asserted under REQ-ENGINE-032 below, which replaced the
# REQ-GCORE-026 assertion that used to pin it to `opus` here)
# The four canonical lane names exist as headings (REQ-GCORE-018's strings),
# in lane order, so the later lanes this task pins have somewhere to live.
assert_grep '^## Lane 1 — coverage currency$' "$auditor"
assert_grep '^## Lane 2 — mutation honesty$' "$auditor"
assert_grep '^## Lane 3 — stale assertions$' "$auditor"
assert_grep '^## Lane 4 — unclosed findings$' "$auditor"
assert_order "$auditor" \
  '^## Lane 1 — coverage currency$' \
  '^## Lane 2 — mutation honesty$' \
  '^## Lane 3 — stale assertions$' \
  '^## Lane 4 — unclosed findings$'
# Lane 1: the changed non-test source files come from the base ref...
assert_grep 'git diff --name-only <base>\.\.\.HEAD' "$auditor"
# ...and each one is answered with a test that would fail if the change were
# reverted, or listed as UNCOVERED — the two outcomes, no third.
assert_grep 'name a test that would fail if that change were reverted' "$auditor"
assert_grep 'UNCOVERED' "$auditor"
# How the verdict was reached is stated, not implied.
assert_grep 'read the test' "$auditor"
assert_grep 'revert-and-run' "$auditor"
assert_order "$auditor" \
  '^## Lane 1 — coverage currency$' \
  'name a test that would fail if that change were reverted' \
  'UNCOVERED' \
  '^## Lane 2 — mutation honesty$'

# ---------------------------------------------------------------------------
# REQ-ENGINE-032 — replaces the REQ-GCORE-026 assertion `^model: opus$` that
# used to sit in the frontmatter block above. Two things are true and
# load-bearing now, and neither of them is the word "opus": the file declares
# SOME model (the repo ships a working default, and a missing key would leave
# the installed agent unrouted), and the agent's ROLE binding exists in the
# manifest — `scripts/apply-engines.sh` reads that binding plus the engine map
# to rewrite the `model:` line of the INSTALLED copy under ~/.claude, so a
# missing manifest line, not a particular model name, is what breaks routing.
req "REQ-ENGINE-032"

roles="$repo/agents/roles.conf"

assert_grep '^model: [a-z]' "$auditor"
assert_file "$roles"
assert_grep '^test-auditor[[:space:]]*=[[:space:]]*verify[[:space:]]*$' "$roles"

# ---------------------------------------------------------------------------
req "REQ-GCORE-021"
# Lane 2 runs the whole suite per mutation. A filtered run can only say "these
# tests did not catch it", which is a weaker claim than the one being made.
assert_grep 'full suite' "$auditor"
assert_grep 'never a filtered subset' "$auditor"
assert_grep 'make test' "$auditor"
assert_order "$auditor" \
  '^## Lane 2 — mutation honesty$' \
  'full suite' \
  'never a filtered subset' \
  '^## Lane 3 — stale assertions$'

# ---------------------------------------------------------------------------
req "REQ-GCORE-036"
# A green suite is not enough to call a test HOLLOW: the same mutation is run
# a second time before the finding is filed.
assert_grep 'HOLLOW' "$auditor"
assert_grep 'second run of the same mutation' "$auditor"
assert_order "$auditor" \
  '^## Lane 2 — mutation honesty$' \
  'HOLLOW' \
  'second run of the same mutation' \
  '^## Lane 3 — stale assertions$'

# ---------------------------------------------------------------------------
req "REQ-GCORE-037"
# The lane is bounded, and the command may override the bound.
assert_grep '5 mutations' "$auditor"
assert_grep '10 minutes' "$auditor"
assert_grep 'whichever comes first' "$auditor"
assert_grep 'unless the command passes another budget' "$auditor"
assert_order "$auditor" \
  '^## Lane 2 — mutation honesty$' \
  '5 mutations or 10 minutes' \
  '^## Lane 3 — stale assertions$'
# Mutations are applied to a copy; the working tree is never mutated.
assert_grep 'applied to a copy, never the working tree' "$auditor"

# ---------------------------------------------------------------------------
req "REQ-GCORE-022"
# Lane 3 hunts assertions pinned to a spelling instead of the fact under test.
assert_grep 'literal' "$auditor"
assert_grep 'caption' "$auditor"
assert_grep 'colour' "$auditor"
assert_grep 'URL' "$auditor"
assert_grep 'fact-level' "$auditor"
assert_grep 'rather than the fact under test' "$auditor"
# ...and each one gets a proposed replacement asserted through whatever owns
# the fact, rather than a bare complaint.
assert_grep 'propose the fact-level assertion' "$auditor"
assert_grep 'resolver' "$auditor"
assert_order "$auditor" \
  '^## Lane 3 — stale assertions$' \
  'literal caption, colour name or URL string' \
  'propose the fact-level assertion' \
  '^## Lane 4 — unclosed findings$'

# ---------------------------------------------------------------------------
req "REQ-GCORE-023"
# Lane 4 re-opens the previous audits: every report under specs/_audit/ is read,
# and every finding line that is still open is carried forward.
assert_grep 'specs/_audit/' "$auditor"
# The finding form is exact — an open box and a closed box, both carrying the
# AUD id that lets the next audit match them up.
assert_fgrep '- [ ] AUD-<date>-<n>: <text>' "$auditor"
assert_fgrep '- [x] AUD-<date>-<n>: <text>' "$auditor"
# Open findings are re-checked against current code and tests and re-listed...
assert_grep 'still open' "$auditor"
assert_grep 'carrying their original AUD id' "$auditor"
# ...and with nothing to re-check the lane is SKIPPED with that reason, not PASS.
assert_grep 'no previous audit reports' "$auditor"
assert_grep 'It is never PASS' "$auditor"
assert_order "$auditor" \
  '^## Lane 4 — unclosed findings$' \
  'specs/_audit/' \
  'still open' \
  'no previous audit reports'

# ---------------------------------------------------------------------------
req "REQ-GCORE-025"
# The write tools are denied in frontmatter — this is the guard the mutation
# lane leans on, so it is asserted here too and not only under REQ-GCORE-020.
assert_grep '^disallowedTools: Write, Edit, NotebookEdit$' "$auditor"
# The lane's forward reference from Lane 2 resolves to a real section...
assert_grep '^## The scratchpad copy$' "$auditor"
# ...which names the copy, the scratchpad, and how the copy is made.
assert_grep 'session scratchpad directory' "$auditor"
assert_grep 'cp -R' "$auditor"
assert_grep 'git worktree add --detach' "$auditor"
# Mutations reach the copy through Bash, and only the copy.
assert_grep 'applied with Bash' "$auditor"
assert_grep 'applied to a copy, never the working tree' "$auditor"
assert_grep 'to that copy ONLY' "$auditor"
assert_grep 'run inside the copy' "$auditor"
assert_grep 'Discard the copy' "$auditor"
# Having no write tools is the design, not an obstacle to route around.
assert_grep 'no Write, Edit or NotebookEdit tools by design' "$auditor"
# A copy that cannot run the suite downgrades Lane 2 to SKIPPED, not PASS.
assert_grep 'cannot run the suite' "$auditor"
assert_grep 'Lane 2 is SKIPPED with that reason' "$auditor"
assert_order "$auditor" \
  '^## Lane 4 — unclosed findings$' \
  '^## The scratchpad copy$' \
  'applied with Bash' \
  '^## Output$'

# ---------------------------------------------------------------------------
req "REQ-GCORE-038"
# Every lane ends by proving the real repo was not touched.
assert_grep 'git status --porcelain' "$auditor"
assert_grep '^## After every lane$' "$auditor"
# ...and dirt is a lane FAIL regardless of what the lane otherwise found.
assert_fgrep 'Non-empty output is a lane FAIL with the dirty paths listed' "$auditor"
assert_grep 'whatever else the lane found' "$auditor"
assert_order "$auditor" \
  '^## Lane 4 — unclosed findings$' \
  'git status --porcelain' \
  '^## Output$'

# ---------------------------------------------------------------------------
req "REQ-GCORE-018"
# The output section carries the per-lane verdict vocabulary and the rule that
# the final message is itself the deliverable.
assert_grep 'PASS / FAIL / SKIPPED' "$auditor"
assert_grep 'the final message is the data' "$auditor"
# The prompt stays short enough to be read in full by the model it steers.
lines=""
[ -f "$auditor" ] && lines=$(wc -l <"$auditor" | tr -d ' ')
if [ -n "$lines" ] && [ "$lines" -le 140 ]; then
  _test_pass "at most 140 lines ($lines): $auditor"
else
  _test_fail "expected at most 140 lines, got ${lines:-none}: $auditor"
fi

finish
