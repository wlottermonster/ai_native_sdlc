#!/bin/bash
# AI-Native SDLC — the three gaps found reviewing a live estate, and the fixes
# for them. Every assertion below carries its REQ-ID literally, so requirement
# coverage stays grep-able.
#
#   A. The commit gate fails open on a TIMEOUT, not only on a crash.
#      REQ-GAP-001  README "Known gaps" says the commit gate is a PreToolUse
#                   hook with a timeout and that a hook which times out does NOT
#                   block — so a repo whose `check` overruns commits ungated.
#      REQ-GAP-002  ...and states the rule that follows: absence of a block is
#                   not evidence the checks passed.
#      REQ-GAP-003  settings/hooks-snippet.json names that timeout as a budget,
#                   beside the timeout itself.
#      REQ-GAP-004  all three Makefile templates carry the same budget, and
#                   direct a repo that cannot fit it to split the slow work
#                   into `test`.
#
#   B. Repo-local agents drift off the engine map.
#      REQ-GAP-005  scripts/apply-engines.sh honours an agents directory given
#                   in the environment and rewrites THOSE agents from a
#                   roles.conf found beside them. The no-override path is
#                   pinned here too: it must stay exactly what it was.
#      REQ-GAP-006  that directory with no roles.conf → reported, nothing
#                   changed, no role guessed.
#      REQ-GAP-007  the engine map is still read from its machine-level
#                   location; a map planted beside the agents is ignored.
#      REQ-GAP-008  README "Project layer" names the command that keeps a
#                   repo's own agents in step.
#
#   C. No CI mirror.
#      REQ-GAP-009  templates/ci-check.yml runs `make check` on push and on
#                   pull request.
#      REQ-GAP-010  ...and says in a comment why it runs `check` and not
#                   `test`.
#      REQ-GAP-011  README "Known gaps" points its no-CI entry at that file.
#
# The behaviour half runs the script under a throwaway $HOME and throwaway
# agent directories built by mktemp -d; nothing here reads or writes the real
# ~/.claude, and the whole tree is removed by the EXIT trap.
#
# This file is under tests/, which the scrub fence excludes — it has to spell
# out phrases the shipped surface is asserted to contain.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

readme="$repo/README.md"
snippet="$repo/settings/hooks-snippet.json"
ci="$repo/templates/ci-check.yml"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-gaps.XXXXXX")
# Normalised through `cd`+`pwd`: a $TMPDIR with a trailing slash makes mktemp
# hand back a path containing "//", and the assertions below compare against
# paths the script under test printed after its own `cd ... && pwd`.
tmproot=$(cd "$tmproot" && pwd)
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

# section <heading> <outfile> — the body under a `## <heading>` line, up to the
# next `## ` heading, with its line count recorded beside it. An absent heading
# yields an empty body, which the non-empty assertion then catches.
section() {
  awk -v want="## $1" '
    $0 == want { inside = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' "$readme" > "$2"
  wc -l < "$2" | tr -d '[:space:]' > "$2.count"
}

# assert_unchanged <snapshot> <file> — byte-for-byte identity, the only honest
# reading of "changed nothing".
assert_unchanged() {
  if [ ! -f "$2" ]; then
    _test_fail "missing: $2"
  elif cmp -s "$1" "$2"; then
    _test_pass "byte-unchanged: $2"
  else
    _test_fail "expected byte-unchanged: $2"
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

# fm_model <file> — the `model:` value inside the leading frontmatter fence,
# read INDEPENDENTLY of the script under test (its own extractor is not reused,
# or the test would be asserting the implementation against itself).
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

# ===========================================================================
# A. The gate that fails open
# ===========================================================================

section "Known gaps (accepted, revisit later)" "$tmproot/known-gaps.txt"
gaps="$tmproot/known-gaps.txt"

# ---------------------------------------------------------------------------
req "REQ-GAP-001"
assert_file "$readme"
assert_grep '^## Known gaps \(accepted, revisit later\)$' "$readme"
# The section must have a body; an empty section cannot pass by saying nothing.
assert_grep '^[1-9][0-9]*$' "$gaps.count"

# The mechanism, named: a PreToolUse hook, a timeout, and a timeout that does
# not block.
assert_grep 'PreToolUse' "$gaps"
assert_grep 'timeout' "$gaps"
assert_fgrep 'times out does NOT block' "$gaps"
# ...and the consequence, in the words the requirement fixes: a repo whose
# check exceeds the timeout commits ungated while looking gated.
assert_fgrep 'ungated while looking gated' "$gaps"
# The two halves belong to one entry, in that order.
assert_order "$gaps" \
  'PreToolUse' \
  'times out does NOT block' \
  'ungated while looking gated'

# ---------------------------------------------------------------------------
req "REQ-GAP-002"
# The rule that follows from the mechanism, stated in the same section and
# after it.
assert_fgrep 'the absence of a block is not evidence the checks passed' "$gaps"
assert_fgrep 'inside that budget or knows it is ungated' "$gaps"
assert_order "$gaps" \
  'times out does NOT block' \
  'the absence of a block is not evidence the checks passed' \
  'inside that budget or knows it is ungated'

# ---------------------------------------------------------------------------
req "REQ-GAP-003"
# The hooks snippet still parses (make check runs `jq -e .` over it), and the
# commit-gate hook entry carries a "//" comment beside its timeout.
assert_file "$snippet"
assert_exit 0 jq -e . "$snippet"

jq -r '.hooks.PreToolUse[0].hooks[0].command // ""' "$snippet" \
  > "$tmproot/gate-command.txt"
assert_grep 'check-gate\.sh' "$tmproot/gate-command.txt"

jq -r '.hooks.PreToolUse[0].hooks[0].timeout // ""' "$snippet" \
  > "$tmproot/gate-timeout.txt"
assert_grep '^[1-9][0-9]*$' "$tmproot/gate-timeout.txt"

# The budget lives in the file's TOP-LEVEL comment. It is deliberately NOT a key
# inside the hook entry: Claude Code does not accept comments in a settings file,
# unknown-key tolerance inside a hook object is undocumented, and a schema error
# rejects the WHOLE settings file — every hook, permission and setting with it.
jq -r '.["//"] // ""' "$snippet" > "$tmproot/gate-comment.txt"
assert_fgrep 'TIMEOUT BUDGET' "$tmproot/gate-comment.txt"
assert_fgrep 'make check' "$tmproot/gate-comment.txt"
# ...naming the SAME number the timeout key carries, so the two cannot drift.
gate_timeout=$(tr -d '[:space:]' < "$tmproot/gate-timeout.txt")
assert_fgrep "$gate_timeout" "$tmproot/gate-comment.txt"
# ...what happens when a check does not fit...
assert_fgrep 'does NOT block' "$tmproot/gate-comment.txt"
assert_fgrep 'ungated while looking gated' "$tmproot/gate-comment.txt"
# ...and the rejected fix named as rejected: raise nothing, split instead.
assert_fgrep 'make test' "$tmproot/gate-comment.txt"

req "REQ-GAP-012"
# No hook entry carries a key the hook schema does not define. This is the one
# assertion standing between a hand-merged snippet and a settings file the
# harness may reject outright.
jq -r '[.hooks[][] | .hooks[] | keys[]] | unique | .[]' "$snippet" \
  > "$tmproot/hook-entry-keys.txt"
assert_no_grep '^//$' "$tmproot/hook-entry-keys.txt"
bad=0
while read -r k; do
  case "$k" in
    type|command|timeout|statusMessage|async) : ;;
    *) echo "UNDEFINED KEY IN A HOOK ENTRY: $k" >&2; bad=$((bad + 1)) ;;
  esac
done < "$tmproot/hook-entry-keys.txt"
printf '%s\n' "$bad" > "$tmproot/bad-key-count.txt"
assert_grep '^0$' "$tmproot/bad-key-count.txt"
# And the file tells the reader how to SEE that the entry was accepted.
assert_fgrep '/hooks' "$tmproot/gate-comment.txt"

# ---------------------------------------------------------------------------
req "REQ-GAP-004"
# The same budget, in every Makefile template — this is where someone writing a
# `check` target actually looks.
for tmpl in Makefile.python Makefile.node Makefile.static; do
  f="$repo/templates/$tmpl"
  assert_file "$f"
  assert_fgrep 'TIMEOUT BUDGET' "$f"
  assert_fgrep "${gate_timeout}s" "$f"
  assert_fgrep 'does NOT block' "$f"
  assert_fgrep 'ungated while looking gated' "$f"
  # ...and the direction for a repo that cannot fit it.
  assert_fgrep 'split the slow work into' "$f"
  assert_grep 'split the slow work into .test.' "$f"
  # The budget is stated before the target it constrains.
  assert_order "$f" 'TIMEOUT BUDGET' '^check:'
done

# ===========================================================================
# B. Repo-local agents drift off the engine map
# ===========================================================================

# engine_fixture <parent> — a runnable checkout: the scripts, the agent prompts
# and the role manifest beside them. The script finds its fallback manifest
# relative to its own location, so it has to run out of a repo-shaped tree.
engine_fixture() {
  local d f
  d=$(mktemp -d "$1/fixture.XXXXXX")
  mkdir -p "$d/scripts" "$d/agents"
  cp "$TEST_REPO"/scripts/*.sh "$d/scripts/"
  cp "$TEST_REPO"/agents/*.md "$d/agents/"
  for f in "$TEST_REPO"/agents/*.conf; do
    [ -f "$f" ] && cp "$f" "$d/agents/"
  done
  printf '%s' "$d"
}

# engine_home <parent> <fixture> — a throwaway HOME with the fixture's agents
# and manifest installed under .claude/agents, and an engine map whose model
# names are INVENTED: the shipped map already names what the shipped agents
# already carry, so a run that did nothing at all would pass an assertion
# written against those. A probe name cannot be arrived at by accident.
engine_home() {
  local h f
  h=$(mktemp -d "$1/home.XXXXXX")
  mkdir -p "$h/.claude/agents"
  cp "$2"/agents/*.md "$h/.claude/agents/"
  for f in "$2"/agents/*.conf; do
    [ -f "$f" ] && cp "$f" "$h/.claude/agents/"
  done
  cat > "$h/.claude/sdlc-engines.conf" <<'MAP'
judge = probe-judge-1, probe-judge-2
build = probe-build-1, probe-build-2
verify = probe-verify-1, probe-verify-2
read = probe-read-1, probe-read-2
escalate = probe-escalate-1, probe-escalate-2
MAP
  printf '%s' "$h"
}

# repo_agents <dir> — a repo's own .claude/agents: two agents pinned to a model
# nobody's map names, so any movement is the script's doing.
repo_agents() {
  mkdir -p "$1"
  cat > "$1/repo-worker.md" <<'AGENT'
---
name: repo-worker
description: a repo-local worker
model: stale-engine
---

Body text, which happens to contain a line that begins like frontmatter:
model: never-eligible
AGENT
  cat > "$1/repo-reader.md" <<'AGENT'
---
name: repo-reader
description: a repo-local reader
model: stale-engine
---

Body.
AGENT
}

# ---------------------------------------------------------------------------
req "REQ-GAP-005"
# An agents directory given in the environment: THOSE agents are rewritten,
# from a roles.conf found beside them.
d=$(engine_fixture "$tmproot")
h=$(engine_home "$tmproot" "$d")
local_dir="$tmproot/repo-a/.claude/agents"
repo_agents "$local_dir"
printf 'repo-worker = build\nrepo-reader = read\n' > "$local_dir/roles.conf"

# Snapshot the installed global agents: the override must not reach them.
mkdir -p "$tmproot/global-before"
cp "$h/.claude/agents"/*.md "$tmproot/global-before/"

out="$tmproot/override.out"
capture "$out" env HOME="$h" SDLC_AGENTS_DIR="$local_dir" \
  bash "$d/scripts/apply-engines.sh"
assert_rc 0 "$out"

# The repo's own agents now carry the model the machine-level map gives their
# role...
assert_model "$local_dir/repo-worker.md" "probe-build-1"
assert_model "$local_dir/repo-reader.md" "probe-read-1"
assert_grep '^changed repo-worker: model: stale-engine -> probe-build-1 \(role build\)$' "$out"
assert_grep '^changed repo-reader: model: stale-engine -> probe-read-1 \(role read\)$' "$out"
# ...the manifest that bound them is the one beside them...
assert_fgrep "the role manifest $local_dir/roles.conf" "$out"
# ...only the frontmatter line moved (the body line beginning `model:` is body)...
assert_grep '^model: never-eligible$' "$local_dir/repo-worker.md"
# ...and the global agents were not touched at all.
for f in "$tmproot/global-before"/*.md; do
  assert_unchanged "$f" "$h/.claude/agents/$(basename "$f")"
done
assert_no_grep '^changed implementer' "$out"

# ---------------------------------------------------------------------------
req "REQ-GAP-005"
# REGRESSION PIN — with no override, the script does exactly what it did
# before: the machine-level agents directory, its installed manifest, and no
# reach into any repo. This block fails the moment the override path leaks into
# the default one.
d2=$(engine_fixture "$tmproot")
h2=$(engine_home "$tmproot" "$d2")
untouched="$tmproot/repo-b/.claude/agents"
repo_agents "$untouched"
printf 'repo-worker = build\n' > "$untouched/roles.conf"
mkdir -p "$tmproot/repo-b-before"
cp "$untouched"/*.md "$tmproot/repo-b-before/"

out2="$tmproot/default.out"
capture "$out2" env HOME="$h2" bash "$d2/scripts/apply-engines.sh"
assert_rc 0 "$out2"
assert_fgrep "using the engine map $h2/.claude/sdlc-engines.conf and the role manifest $h2/.claude/agents/roles.conf" "$out2"
assert_model "$h2/.claude/agents/implementer.md" "probe-build-1"
assert_model "$h2/.claude/agents/researcher.md" "probe-read-1"
for f in "$tmproot/repo-b-before"/*.md; do
  assert_unchanged "$f" "$untouched/$(basename "$f")"
done

# An empty value is not an override either: the variable has to name a
# directory to mean anything.
d3=$(engine_fixture "$tmproot")
h3=$(engine_home "$tmproot" "$d3")
out3="$tmproot/empty.out"
capture "$out3" env HOME="$h3" SDLC_AGENTS_DIR= bash "$d3/scripts/apply-engines.sh"
assert_rc 0 "$out3"
assert_fgrep "the role manifest $h3/.claude/agents/roles.conf" "$out3"
assert_model "$h3/.claude/agents/implementer.md" "probe-build-1"

# ---------------------------------------------------------------------------
req "REQ-GAP-006"
# The same override, against a directory with no roles.conf: the run reports
# the missing manifest and changes nothing. No role is guessed from a name, and
# the checkout's own manifest is NOT silently used instead — that fallback
# exists for the installed agents, and borrowing it here would bind a repo's
# agents to roles nobody wrote down for them.
d4=$(engine_fixture "$tmproot")
h4=$(engine_home "$tmproot" "$d4")
bare="$tmproot/repo-c/.claude/agents"
repo_agents "$bare"
mkdir -p "$tmproot/repo-c-before"
cp "$bare"/*.md "$tmproot/repo-c-before/"
mkdir -p "$tmproot/global-c-before"
cp "$h4/.claude/agents"/*.md "$tmproot/global-c-before/"

out4="$tmproot/noconf.out"
capture "$out4" env HOME="$h4" SDLC_AGENTS_DIR="$bare" \
  bash "$d4/scripts/apply-engines.sh"
assert_rc 2 "$out4"
# The report names the file it looked for, beside the agents it was given.
assert_fgrep "$bare/roles.conf: no such file" "$out4"
assert_fgrep 'nothing was changed.' "$out4"
# Nothing was applied, anywhere.
assert_no_grep '^changed ' "$out4"
assert_no_grep 'using the engine map' "$out4"
for f in "$tmproot/repo-c-before"/*.md; do
  assert_unchanged "$f" "$bare/$(basename "$f")"
done
for f in "$tmproot/global-c-before"/*.md; do
  assert_unchanged "$f" "$h4/.claude/agents/$(basename "$f")"
done
# ...and the checkout's manifest was never reached for.
assert_no_grep "the role manifest $d4/agents/roles.conf" "$out4"

# ---------------------------------------------------------------------------
req "REQ-GAP-007"
# The engine map stays machine-level. A map planted beside the repo's agents is
# not a map: the models applied come from $HOME, and the decoy is neither read
# nor named.
d5=$(engine_fixture "$tmproot")
h5=$(engine_home "$tmproot" "$d5")
decoyed="$tmproot/repo-d/.claude/agents"
repo_agents "$decoyed"
printf 'repo-worker = build\nrepo-reader = read\n' > "$decoyed/roles.conf"
cat > "$decoyed/sdlc-engines.conf" <<'DECOY'
build = decoy-build
read = decoy-read
DECOY
cp "$decoyed/sdlc-engines.conf" "$tmproot/decoy-before.conf"

out5="$tmproot/decoy.out"
capture "$out5" env HOME="$h5" SDLC_AGENTS_DIR="$decoyed" \
  bash "$d5/scripts/apply-engines.sh"
assert_rc 0 "$out5"
assert_fgrep "using the engine map $h5/.claude/sdlc-engines.conf" "$out5"
assert_model "$decoyed/repo-worker.md" "probe-build-1"
assert_model "$decoyed/repo-reader.md" "probe-read-1"
assert_no_grep 'decoy' "$out5"
assert_unchanged "$tmproot/decoy-before.conf" "$decoyed/sdlc-engines.conf"

# With no map at the machine-level location the run fails naming THAT path,
# rather than falling back to the one sitting beside the agents.
d6=$(engine_fixture "$tmproot")
h6=$(engine_home "$tmproot" "$d6")
rm -f "$h6/.claude/sdlc-engines.conf"
nomap="$tmproot/repo-e/.claude/agents"
repo_agents "$nomap"
printf 'repo-worker = build\n' > "$nomap/roles.conf"
cat > "$nomap/sdlc-engines.conf" <<'DECOY'
build = decoy-build
DECOY
mkdir -p "$tmproot/repo-e-before"
cp "$nomap"/*.md "$tmproot/repo-e-before/"

out6="$tmproot/nomap.out"
capture "$out6" env HOME="$h6" SDLC_AGENTS_DIR="$nomap" \
  bash "$d6/scripts/apply-engines.sh"
assert_rc 2 "$out6"
assert_fgrep "$h6/.claude/sdlc-engines.conf: no such file" "$out6"
for f in "$tmproot/repo-e-before"/*.md; do
  assert_unchanged "$f" "$nomap/$(basename "$f")"
done

# ---------------------------------------------------------------------------
req "REQ-GAP-008"
# The README's project layer names the command, in place of telling the owner
# to keep the model lines in step by hand.
section "Project layer" "$tmproot/project-layer.txt"
pl="$tmproot/project-layer.txt"
assert_grep '^[1-9][0-9]*$' "$pl.count"
assert_grep '\.claude/agents/' "$pl"
assert_fgrep 'SDLC_AGENTS_DIR' "$pl"
assert_fgrep 'apply-engines.sh' "$pl"
assert_fgrep 'roles.conf' "$pl"
# The superseded sentence is gone: it is no longer the repo's to maintain.
assert_no_grep 'yours to keep in step with the map' "$pl"
# ...and the map is still stated to be the single machine-level binding, so a
# reader cannot come away thinking a repo may carry its own.
assert_grep 'machine-level' "$pl"

# ===========================================================================
# C. No CI mirror
# ===========================================================================

# ---------------------------------------------------------------------------
req "REQ-GAP-009"
assert_file "$ci"
# A workflow that fires on push and on pull request...
assert_grep '^on:' "$ci"
assert_grep '^  push:' "$ci"
assert_grep '^  pull_request:' "$ci"
# ...and runs the repo's own fast gate by the name the framework contracts for.
assert_grep '^ *run: make check$' "$ci"
assert_grep '^jobs:' "$ci"
# The triggers come before the job that answers them.
assert_order "$ci" '^on:' '^  push:' '^  pull_request:' '^jobs:'

# ---------------------------------------------------------------------------
req "REQ-GAP-016"
# Every file shipped in templates/ appears in README's file map. Verification
# caught ci-check.yml missing from it and noted that no test would ever have
# said so — this is that test. It is general on purpose: the next template to be
# added fails here until it is documented, rather than being quietly invisible.
: > "$tmproot/unlisted-templates.txt"
for tf in "$repo"/templates/*; do
  [ -e "$tf" ] || continue
  name=$(basename "$tf")
  [ -d "$tf" ] && name="$name/"
  grep -qF "      $name" "$repo/README.md" \
    || printf '%s\n' "$name" >> "$tmproot/unlisted-templates.txt"
done
printf '%s\n' "$(wc -l < "$tmproot/unlisted-templates.txt" | tr -d ' ')" \
  > "$tmproot/unlisted-count.txt"
assert_grep '^0$' "$tmproot/unlisted-count.txt"

req "REQ-GAP-010"
# The template says why it runs check and not test, and where a credentialed
# suite goes instead.
assert_fgrep 'deliberately' "$ci"
assert_fgrep 'make test' "$ci"
assert_fgrep 'credentials' "$ci"
assert_fgrep 'stays out of CI' "$ci"
assert_fgrep 'by hand before a deploy' "$ci"
# It is a comment, not a step: the reason is stated above the workflow body.
assert_order "$ci" '^# ' 'deliberately' '^jobs:'
# ...and `make test` is explained, never run.
assert_no_grep '^ *run:.*make test' "$ci"

# ---------------------------------------------------------------------------
req "REQ-GAP-011"
# The known-gaps entry for the missing CI mirror points at that template.
assert_grep 'locally only' "$gaps"
assert_fgrep 'templates/ci-check.yml' "$gaps"
assert_grep 'make check' "$gaps"
# One entry: the pointer follows the gap it closes, not some unrelated line.
assert_order "$gaps" 'locally only' 'templates/ci-check\.yml'

req "REQ-GAP-013"
# A gate that cannot reach the repo it is meant to check must BLOCK, not allow.
# Found by a live /hunt run and confirmed by an evidence lane: check-gate.sh
# exited 0 when a cd failed, and in one path ran `make check` in a DIFFERENT
# repository and allowed on that result. Behaviour, not wording: build an
# unenterable directory and observe the exit code.
probe="$tmproot/gate13"
mkdir -p "$probe/other" "$probe/target/locked"
for d in other target; do
  ( cd "$probe/$d" \
      && git init -q . \
      && printf 'check:\n\t@exit %s\n' "$([ "$d" = target ] && echo 1 || echo 0)" > Makefile \
      && printf 'x\n' > f.py \
      && git add -A ) >/dev/null 2>&1
done
chmod 000 "$probe/target/locked"
# The precondition is asserted too, so a machine where `-d` and `cd` agree
# cannot pass this test vacuously.
if [ -d "$probe/target/locked" ] && ! ( cd "$probe/target/locked" ) 2>/dev/null; then
  printf 'precondition holds\n' > "$probe/pre.txt"
else
  printf 'precondition ABSENT\n' > "$probe/pre.txt"
fi
assert_grep '^precondition holds$' "$probe/pre.txt"
payload=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$probe/target/locked")
( cd "$probe/other" && printf '%s' "$payload" | bash "$repo/hooks/check-gate.sh" ) >/dev/null 2>&1
printf '%s\n' "$?" > "$probe/rc.txt"
# 0 here would mean the commit was ALLOWED after checks that never ran for it.
assert_no_grep '^0$' "$probe/rc.txt"
chmod 755 "$probe/target/locked"
req "REQ-GAP-015"
# The sibling gates, tested by BEHAVIOUR rather than by spelling. Verification
# pointed out that greping for one literal spelling of the old fail-open is a
# test of the spelling, not of the rule — a mutant that writes
# `cd "$top" 2>/dev/null || exit 0` or `if ! cd "$top"; then exit 0; fi` passes
# a grep and reintroduces the bug. So: run each gate somewhere it cannot reach
# a repo, and require a non-zero exit whatever the source happens to say.
#
# The codes differ by position, deliberately. dod.sh reads stop_hook_active and
# blocks with 2. req-gate.sh drains stdin, cannot read that guard, and so exits
# 1 — loud and visible, but with no way to loop from a Stop hook on a condition
# the model cannot fix.
sib="$tmproot/siblings"
mkdir -p "$sib/notarepo"
for gate in dod req-gate; do
  ( cd "$sib/notarepo" && bash "$repo/hooks/$gate.sh" </dev/null ) >/dev/null 2>&1   # stdin closed: a Stop hook reads its payload from stdin and would wait forever on an open pipe
  printf '%s\n' "$?" > "$sib/$gate-notrepo.txt"
done
# Outside a repo both correctly ALLOW — `git rev-parse` fails and there is
# nothing to gate. This pins the legitimate allow so the negatives below cannot
# pass by the gate simply refusing everything.
assert_grep '^0$' "$sib/dod-notrepo.txt"
assert_grep '^0$' "$sib/req-gate-notrepo.txt"
# And inside a repo whose specs/ exists but cannot be read, the coverage gate
# must not sail through having read nothing.
mkdir -p "$sib/repo/specs"
( cd "$sib/repo" && git init -q . ) >/dev/null 2>&1
chmod 000 "$sib/repo/specs"
if [ -d "$sib/repo/specs" ] && ! ( cd "$sib/repo/specs" ) 2>/dev/null; then
  ( cd "$sib/repo" && bash "$repo/hooks/req-gate.sh" ) >/dev/null 2>&1
  printf '%s\n' "$?" > "$sib/req-gate-unreadable.txt"
  chmod 755 "$sib/repo/specs"
  assert_no_grep '^0$' "$sib/req-gate-unreadable.txt"
else
  chmod 755 "$sib/repo/specs"
  printf 'precondition ABSENT\n' > "$sib/skip.txt"
  assert_no_grep 'precondition ABSENT' "$sib/skip.txt"
fi

req "REQ-GAP-014"
# Present is not readable. Without this the map parses empty and the run reports
# a cascade of "role is not defined" errors that all name the wrong cause.
rdhome="$tmproot/gap14home"
mkdir -p "$rdhome/.claude/agents"
cp "$repo/templates/sdlc-engines.conf" "$rdhome/.claude/sdlc-engines.conf"
cp "$repo/agents/roles.conf" "$rdhome/.claude/agents/roles.conf"
cp "$repo/agents/researcher.md" "$rdhome/.claude/agents/researcher.md"
chmod 000 "$rdhome/.claude/sdlc-engines.conf"
HOME="$rdhome" bash "$repo/scripts/apply-engines.sh" > "$rdhome/out.txt" 2>&1
printf '%s\n' "$?" > "$rdhome/rc.txt"
chmod 644 "$rdhome/.claude/sdlc-engines.conf"
assert_no_grep '^0$' "$rdhome/rc.txt"
assert_fgrep 'not readable' "$rdhome/out.txt"

finish
