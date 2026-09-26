#!/bin/bash
# AI-Native SDLC — README.md is the written contract for the project layer: the
# one place the framework says what a repo may add on top of the global engines.
# Covers REQ-GCORE-006 (the "Project layer" section lists every extension point,
# and "Layout" lists the framework's own files), REQ-GCORE-007 (the exact
# collision sentence) and REQ-GCORE-010 (the reserved simulation targets).
#
# Every assertion below is labelled with its REQ-ID literally, so requirement
# coverage stays grep-able.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

readme="$repo/README.md"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-readme.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# section <heading> <outfile> — extract the body under a `## <heading>` line,
# up to the next `## ` heading, and record its line count beside it. An absent
# heading yields an empty body, which the non-empty assertion then catches.
section() {
  awk -v want="## $1" '
    $0 == want { inside = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' "$readme" > "$2"
  wc -l < "$2" | tr -d '[:space:]' > "$2.count"
}

section "Project layer" "$tmpdir/project-layer.txt"
section "Layout" "$tmpdir/layout.txt"

# ---------------------------------------------------------------------------
# REQ-GCORE-006 — the project layer contract, and the framework's own layout.
req "REQ-GCORE-006"

assert_file "$readme"
assert_grep '^## Project layer$' "$readme"

# The section must have a body; an empty section cannot pass by listing nothing.
assert_grep '^[1-9][0-9]*$' "$tmpdir/project-layer.txt.count"

pl="$tmpdir/project-layer.txt"

# Every extension point a repo may provide, each named inside the section.
assert_grep 'Makefile' "$pl"                 # the gate contract lives in a Makefile
# shellcheck disable=SC2016  # the backticks are Markdown code spans, not command substitution
assert_grep '`check`' "$pl"                  # ...with a check target
# shellcheck disable=SC2016  # ditto
assert_grep '`test`' "$pl"                   # ...and a test target
assert_grep 'TEST_PROFILE' "$pl"             # the declared depth, read by agents
assert_grep 'lib \| api \| webapp \| static' "$pl"
assert_grep 'specs/<feature>/' "$pl"         # the specs layout
assert_grep 'specs/_shipped/' "$pl"
assert_grep 'specs/_audit/' "$pl"
assert_grep '\.claude/commands/' "$pl"       # project commands
assert_grep '\.claude/agents/' "$pl"         # project agents
assert_grep '\.claude/hooks/' "$pl"          # project hooks, layered on the global ones
assert_grep 'CLAUDE\.md' "$pl"               # add-on sections
assert_grep 'decision log' "$pl"             # the optional decision log location
assert_grep 'tracker' "$pl"                  # the one-line declarations /rca reads
assert_grep 'protected paths' "$pl"

# install.sh makes a shadow visible, so shadowing is always deliberate.
assert_grep 'install\.sh' "$pl"
assert_grep '[Ww]arn' "$pl"

# The Layout section names the framework's own gate contract, its harness and
# the two engines lifted out of a project.
assert_grep '^[1-9][0-9]*$' "$tmpdir/layout.txt.count"

lay="$tmpdir/layout.txt"
assert_grep '^ *Makefile ' "$lay"
assert_grep 'TEST_PROFILE' "$lay"
assert_grep '^ *tests/ ' "$lay"
assert_grep 'rca\.md' "$lay"
assert_grep 'test-audit\.md' "$lay"
assert_grep 'test-auditor\.md' "$lay"

# Positive control: the scrub-era wording and the pre-existing entries survive.
assert_grep 'Makefile\.static' "$lay"
assert_grep 'static-site repos' "$lay"
assert_grep 'ainative_sdlc\.html' "$lay"
assert_grep 'sdlc-policy\.md' "$lay"

# ---------------------------------------------------------------------------
# REQ-GCORE-007 — the collision rule, word for word, inside the section.
req "REQ-GCORE-007"

assert_fgrep 'A project command with the same name as a global command wins.' "$pl"

# ---------------------------------------------------------------------------
# REQ-GCORE-010 — the reserved Makefile targets, marked as not yet used.
req "REQ-GCORE-010"

assert_grep 'sim-up' "$pl"
assert_grep 'sim-down' "$pl"
assert_grep 'sim-cast' "$pl"
assert_fgrep 'reserved, not yet used' "$pl"

# The three names and the phrase must share one line, so no target can drift
# away from the marking that says it does nothing yet.
assert_grep 'sim-up.*sim-down.*sim-cast.*reserved, not yet used' "$pl"

# ===========================================================================
# The public, trainable README. These blocks carry no REQ-ID: they pin the
# reviewers' findings for the open-source release, so a later edit that brings
# an overclaim back, or drops a walk-through step, goes red.
# ===========================================================================

section "Why" "$tmpdir/why.txt"
section "Your first hour (a training walk-through)" "$tmpdir/walk.txt"
section "Words used here" "$tmpdir/words.txt"
section "Install" "$tmpdir/install.txt"
section "Known gaps (accepted, revisit later)" "$tmpdir/gaps.txt"
section "Where this repository comes from" "$tmpdir/origin.txt"

# ---------------------------------------------------------------------------
req "readme: the opening speaks to a non-technical reader"
awk '/^## /{exit} {print}' "$readme" > "$tmpdir/opening.txt"
op="$tmpdir/opening.txt"
assert_fgrep 'Software Development Life Cycle' "$op"
assert_grep 'Anthropic' "$op"
assert_grep 'OpenAI' "$op"
assert_grep '[Mm]orning' "$op"
assert_grep '[Aa]fternoon' "$op"
assert_fgrep 'ainative_sdlc.html' "$op"
assert_fgrep 'ARCHITECTURE.md' "$op"
assert_no_grep '[Ii]llustrated' "$readme"

# ---------------------------------------------------------------------------
req "readme: claims match what the hooks can actually promise"
assert_no_grep 'harness-enforced loop' "$readme"
assert_no_grep 'Everything in between runs on its own' "$readme"
assert_fgrep 'not a security boundary' "$op"
assert_fgrep 'once the hooks are installed and enabled' "$tmpdir/why.txt"
assert_fgrep 'refuses to call a feature finished while any requirement has no test' "$tmpdir/why.txt"
assert_fgrep 'Most of what is in between runs on its own' "$readme"
assert_grep 'hooks/ .*enforcement layer' "$lay"
assert_fgrep 'not a security boundary' "$lay"
assert_fgrep 'approved from the /spec decision digest' "$readme"
assert_no_grep 'approved in plan mode' "$readme"
assert_fgrep 'no one edits a model name by hand' "$readme"
assert_no_grep 'no prompt, agent or document carries a model name' "$readme"
assert_fgrep 'five roles' "$readme"

# ---------------------------------------------------------------------------
req "readme: the walk-through comes right after Why and covers every step"
assert_order "$readme" '^## Why$' '^## Your first hour \(a training walk-through\)$' '^## How it works$'
wk="$tmpdir/walk.txt"
assert_grep '^[1-9][0-9]*$' "$wk.count"
walk_lines=$(tr -d '[:space:]' < "$wk.count")
if [ "${walk_lines:-0}" -le 90 ]; then
  _test_pass "walk-through is $walk_lines lines (<= 90)"
else
  _test_fail "walk-through is $walk_lines lines, over the 90-line budget"
fi
assert_fgrep 'brew install jq shellcheck python@3.12' "$wk"
assert_fgrep 'make check' "$wk"
assert_fgrep 'bash install.sh --harness claude' "$wk"
assert_fgrep 'merge-settings.sh' "$wk"
# shellcheck disable=SC2088  # a literal search string, not a path to expand
assert_fgrep '~/.claude/sdlc-policy.md' "$wk"
assert_fgrep '/hooks' "$wk"
assert_fgrep './doctor' "$wk"
assert_fgrep 'examples/todo-cli' "$wk"
assert_fgrep 'git init' "$wk"
assert_fgrep 'project.py' "$wk"
assert_fgrep '--verify' "$wk"
assert_fgrep '/spec add a due date to todos' "$wk"
assert_fgrep '/build' "$wk"
assert_fgrep '/ship' "$wk"
assert_fgrep '/rca' "$wk"
assert_fgrep '/hunt' "$wk"
assert_fgrep '/test-audit' "$wk"
assert_grep 'Gate 1' "$wk"
assert_grep 'Gate 2' "$wk"
assert_grep 'one batch' "$wk"
assert_grep 'CI' "$wk"
assert_grep 'bypass' "$wk"

# ---------------------------------------------------------------------------
req "readme: the glossary defines every term the walk-through leans on"
assert_order "$readme" '^## Words used here$' '^## Development$'
wd="$tmpdir/words.txt"
for term in SDLC Gate Hook Harness Commit Branch Push Deploy Spec EARS REQ-ID \
            Worktree 'Adversarial review' Verifier 'Ship digest' RCA judge build \
            verify read escalate 'Engine map' 'Fallback chain' Adapter Handoff \
            Handback Doctor TEST_PROFILE Idempotent Compaction Subagent; do
  assert_grep "^- \*\*$term" "$wd"
done
assert_no_grep '(^|[^A-Za-z])([Oo]pus|[Ss]onnet|[Hh]aiku|[Ff]able)([^A-Za-z]|$)' "$wd"

# ---------------------------------------------------------------------------
req "readme: install is reproducible on anyone's machine"
ins="$tmpdir/install.txt"
assert_fgrep 'merge-settings.sh' "$ins"
# shellcheck disable=SC2088  # a literal search string, not a path to expand
assert_fgrep '~/.claude/settings.json.new' "$ins"
# shellcheck disable=SC2088  # ditto
assert_fgrep '~/.claude/sdlc-policy.md' "$ins"
assert_grep 'trust' "$ins"
assert_fgrep '/path/to/your/workspace' "$readme"
# The install and doctor examples name a placeholder workspace, never a
# home-relative one that would be some particular machine's layout.
assert_grep 'install\.sh --harness codex --workspace /path/to/your/workspace' "$readme"
assert_grep 'doctor --workspace /path/to/your/workspace' "$readme"
# shellcheck disable=SC2016  # a literal pattern, nothing to expand
assert_no_grep '--workspace (~|\$HOME)' "$readme"
# shellcheck disable=SC2016  # ditto
assert_no_grep '\$HOME/[a-z]{1,4}([/" ]|$)' "$readme"
assert_no_grep 'by hand once' "$ins"
assert_fgrep 'specs/_audit/' "$pl"
assert_grep 'specs/_audit/.*/test-audit|/test-audit.*specs/_audit/' "$readme"

# ---------------------------------------------------------------------------
req "readme: the commit-gate gap is short and current"
assert_grep '^- \*\*Commit-gate time limit\.\*\*' "$tmpdir/gaps.txt"
assert_no_grep 'fails open on a timeout' "$readme"

# ---------------------------------------------------------------------------
req "readme: reusing publish.sh names the three variables to set"
assert_fgrep 'SDLC_PUBLIC_REPO' "$tmpdir/origin.txt"
assert_fgrep 'SDLC_PUBLIC_EMAIL' "$tmpdir/origin.txt"
assert_fgrep 'SDLC_PUBLIC_NAME' "$tmpdir/origin.txt"

# ===========================================================================
# CLAUDE.md and AGENTS.md say the same thing; only the decision-log line
# names its own file.
# ===========================================================================
req "project rules: CLAUDE.md and AGENTS.md do not drift"
sed 's/^decision log: CLAUDE\.md$/decision log: AGENTS.md/' "$repo/CLAUDE.md" > "$tmpdir/claude-as-agents.md"
if cmp -s "$tmpdir/claude-as-agents.md" "$repo/AGENTS.md"; then
  _test_pass "AGENTS.md equals CLAUDE.md apart from the decision-log line"
else
  _test_fail "AGENTS.md has drifted from CLAUDE.md"
fi
assert_grep '^decision log: AGENTS\.md$' "$repo/AGENTS.md"
assert_no_grep 'on the day this file was written' "$repo/CLAUDE.md"
assert_fgrep 'If you cloned the public repository' "$repo/CLAUDE.md"
assert_fgrep 'If this is the maintainer' "$repo/CLAUDE.md"
assert_fgrep './push.sh' "$repo/CLAUDE.md"
assert_fgrep 'adapters/codex/scripts/validate.py' "$repo/CLAUDE.md"
assert_fgrep 'tests/codex' "$repo/CLAUDE.md"

# ===========================================================================
# Workflows never pre-authorise anyone's pushes.
# ===========================================================================
req "workflows: push authority belongs to the owner of each repository"
assert_no_grep 'owner-authorized on' "$repo/core/workflows.md"
assert_fgrep 'Push only under the authorization the owner has already given for that repository' "$repo/core/workflows.md"

# ===========================================================================
# The practice project the walk-through uses is green on its own contract,
# and carries no year.
# ===========================================================================
req "examples: the training project passes make check and make test"
ex="$repo/examples/todo-cli"
assert_file "$ex/Makefile"
assert_file "$ex/specs/todo/requirements.md"
assert_grep '^TEST_PROFILE = ' "$ex/Makefile"
capture "$tmpdir/ex-check.out" make -s -C "$ex" check
assert_rc 0 "$tmpdir/ex-check.out"
capture "$tmpdir/ex-test.out" make -s -C "$ex" test
assert_rc 0 "$tmpdir/ex-test.out"
for id in REQ-TODO-001 REQ-TODO-002 REQ-TODO-003; do
  assert_grep "$id" "$ex/specs/todo/requirements.md"
  assert_grep "$id" "$ex/test_todo.py"
done
grep -rIlE '20[0-9][0-9]' "$ex" > "$tmpdir/ex-years.txt" 2>/dev/null || true
assert_no_grep '.' "$tmpdir/ex-years.txt"
rm -rf "$ex/__pycache__" "$ex/.todo-test"*

finish
