#!/bin/bash
# AI-Native SDLC — content tests for commands/rca.md, the bug-to-rule flywheel
# prompt. Covers REQ-GCORE-011 (the seven step headings, in order),
# REQ-GCORE-012 (a bug that will not reproduce ends the run after step 1),
# REQ-GCORE-013 (the regression test is tagged with the bug reference so the
# link is grep-able), REQ-GCORE-014 (rule preference order, and prose needs
# a stated reason), REQ-GCORE-015 (a prose rule lands in the declared decision
# log, else in CLAUDE.md), REQ-GCORE-016 (no tracker declared: the summary is
# delivered in chat and no tracker CLI is invoked) and REQ-GCORE-017 (a sibling
# inside a protected path is reported, never edited).
#
# These are read-only assertions against the shipped prompt file; nothing here
# writes outside the repo.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

rca="$repo/commands/rca.md"

# ---------------------------------------------------------------------------
req "REQ-GCORE-011"
assert_file "$rca"
# The file is a command prompt: frontmatter with a one-line description.
assert_grep '^description: ' "$rca"
# All seven headings present, with exactly the wording the requirement fixes...
assert_grep '^## 1\. Reproduce$' "$rca"
assert_grep '^## 2\. Root cause$' "$rca"
assert_grep '^## 3\. Fix test-first$' "$rca"
assert_grep '^## 4\. Rule$' "$rca"
assert_grep '^## 5\. Sibling sweep$' "$rca"
assert_grep '^## 6\. Gate$' "$rca"
assert_grep '^## 7\. Evidence summary$' "$rca"
# ...and in this order.
assert_order "$rca" \
  '^## 1\. Reproduce$' \
  '^## 2\. Root cause$' \
  '^## 3\. Fix test-first$' \
  '^## 4\. Rule$' \
  '^## 5\. Sibling sweep$' \
  '^## 6\. Gate$' \
  '^## 7\. Evidence summary$'

# ---------------------------------------------------------------------------
req "REQ-GCORE-012"
# Not reproducible ends the run at step 1: the evidence is reported and
# nothing is fixed. The stop instruction must sit inside step 1, before the
# root-cause heading.
assert_grep 'not reproducible' "$rca"
assert_grep 'fix nothing' "$rca"
assert_order "$rca" \
  '^## 1\. Reproduce$' \
  'not reproducible' \
  'report the evidence' \
  'fix nothing' \
  '^## 2\. Root cause$'

# ---------------------------------------------------------------------------
req "REQ-GCORE-013"
# The regression test carries the bug reference — marker, test name or
# docstring — so the bug-to-test link is grep-able.
assert_grep '[Tt]ag' "$rca"
assert_grep 'grep-able' "$rca"
assert_grep 'bug reference' "$rca"
assert_order "$rca" \
  '^## 3\. Fix test-first$' \
  '[Tt]ag the (failing )?regression test' \
  'grep-able' \
  '^## 4\. Rule$'

# ---------------------------------------------------------------------------
req "REQ-GCORE-014"
# Preference order inside step 4: a class-sweeping test, then a code-level
# seam, then prose — and prose is only allowed with a stated reason why the
# first two were impossible.
assert_grep 'sweeps the whole class' "$rca"
assert_grep 'seam' "$rca"
assert_grep 'prose' "$rca"
assert_order "$rca" \
  '^## 4\. Rule$' \
  'a test that sweeps the whole class' \
  'a code-level seam' \
  '\*\*prose\*\*' \
  '^## 5\. Sibling sweep$'
# Choosing prose requires stating why the first two were impossible.
assert_grep 'why the first two were impossible' "$rca"
assert_order "$rca" \
  '^## 4\. Rule$' \
  'prose REQUIRES' \
  'why the first two were impossible' \
  '^## 5\. Sibling sweep$'
# A rule that already existed and failed was itself the bug — tighten it.
assert_grep 'the rule was the bug' "$rca"

# ---------------------------------------------------------------------------
req "REQ-GCORE-015"
# The three optional repo declarations are explained up front, before step 1.
assert_grep '^## What the repo declares$' "$rca"
assert_grep 'decision log: <path>' "$rca"
assert_order "$rca" \
  '^## What the repo declares$' \
  '^## 1\. Reproduce$'
# A prose rule goes into the declared decision log if there is one, and into
# the repo's own CLAUDE.md if there is not.
assert_grep "declared decision log if one exists, otherwise into the repo's" "$rca"
assert_grep 'CLAUDE\.md' "$rca"
assert_order "$rca" \
  '^## 4\. Rule$' \
  "declared decision log if one exists, otherwise into the repo's" \
  '^## 5\. Sibling sweep$'

# ---------------------------------------------------------------------------
req "REQ-GCORE-016"
# No tracker declared: the summary is delivered in chat, no CLI is invoked.
assert_grep 'tracker: <command prefix>' "$rca"
assert_grep 'no tracker is declared' "$rca"
assert_grep 'delivered in chat' "$rca"
assert_grep 'no tracker CLI is invoked' "$rca"
assert_order "$rca" \
  '^## 7\. Evidence summary$' \
  'no tracker is declared' \
  'no tracker CLI is invoked'

# ---------------------------------------------------------------------------
req "REQ-GCORE-017"
# A sibling inside a protected path is reported, never edited — and the
# no-fix-zones file counts as protected paths too.
assert_grep 'protected paths: <globs>' "$rca"
assert_grep 'no_fix_zones\.txt' "$rca"
assert_grep 'inside a protected path' "$rca"
assert_grep 'never edited' "$rca"
assert_order "$rca" \
  '^## 5\. Sibling sweep$' \
  'inside a protected path' \
  'never edited' \
  '^## 6\. Gate$'

finish
