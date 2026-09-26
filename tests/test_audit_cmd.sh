#!/bin/bash
# AI-Native SDLC — content tests for commands/test-audit.md, the /test-audit
# command prompt. Covers REQ-GCORE-018 (the four canonical lane names appear in
# BOTH the command and the agent, and the command reports each lane as PASS,
# FAIL or SKIPPED), REQ-GCORE-019 (a lane that could not run — including when
# the scratchpad copy cannot run the suite — is SKIPPED with its reason, never
# PASS) and REQ-GCORE-024 (the report path, the collision suffix rule, and the
# one-line finding format the next audit parses).
#
# These are read-only assertions against the shipped prompt files; nothing here
# writes outside the repo.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

cmd="$repo/commands/test-audit.md"
auditor="$repo/agents/test-auditor.md"

# ---------------------------------------------------------------------------
req "REQ-GCORE-018"
assert_file "$cmd"
assert_file "$auditor"
# The file is a command prompt: frontmatter with a one-line description.
assert_grep '^description: ' "$cmd"
# The four canonical lane names, spelled exactly, in the command...
assert_fgrep 'coverage currency' "$cmd"
assert_fgrep 'mutation honesty' "$cmd"
assert_fgrep 'stale assertions' "$cmd"
assert_fgrep 'unclosed findings' "$cmd"
# ...and the same four strings in the agent the command dispatches. The two
# files have to agree on the lane names or the command cannot map the agent's
# verdicts onto its own table.
assert_fgrep 'coverage currency' "$auditor"
assert_fgrep 'mutation honesty' "$auditor"
assert_fgrep 'stale assertions' "$auditor"
assert_fgrep 'unclosed findings' "$auditor"
# Every lane gets one of exactly three verdicts.
assert_fgrep 'PASS, FAIL or SKIPPED' "$cmd"
# The command dispatches the agent by name.
assert_fgrep 'test-auditor' "$cmd"

# ---------------------------------------------------------------------------
req "REQ-GCORE-019"
# A lane that could not run is SKIPPED with its reason, never PASS — and the
# scratchpad copy being unable to run the suite is named as one such case.
assert_fgrep 'SKIPPED' "$cmd"
assert_fgrep 'never PASS' "$cmd"
assert_fgrep 'cannot run the suite' "$cmd"

# ---------------------------------------------------------------------------
req "REQ-GCORE-024"
# The report goes to the dated path under specs/_audit/ in the repo under audit.
assert_fgrep 'specs/_audit/<YYYY-MM-DD>.md' "$cmd"
# A name that already exists is never overwritten: the suffix walks up.
# shellcheck disable=SC2016  # the backticks are literal markdown in the prompt
assert_fgrep 'append `-2`, `-3`, … until the name is free' "$cmd"
# Each finding is ONE line, in the exact form the unclosed-findings lane greps
# back out of specs/_audit/ on the next audit.
assert_fgrep '- [ ] AUD-<date>-<n>: <text>' "$cmd"
# The report is the only file this command writes.
assert_fgrep 'never edits source or tests' "$cmd"

finish
