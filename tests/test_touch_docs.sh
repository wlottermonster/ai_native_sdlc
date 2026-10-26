#!/bin/bash
# AI-Native SDLC — content tests for the prose of three-touch-points-phase-1:
# the state commands at the three touch points, and the agent tool line the
# spec review needs.
#   REQ-TOUCH-024  agents/spec-reviewer.md carries Bash in tools:
#   REQ-TOUCH-030  commands/spec.md and commands/feature.md: init, stamp only
#                  after Gate 1, commit first
#   REQ-TOUCH-029  commands/build.md: stamp refusal, evidence LAST, record
#   REQ-TOUCH-028  commands/ship.md: status as ground truth, no stale walk
#   REQ-TOUCH-052  commands/ship.md: webapp ui-tester before the walk
#   REQ-TOUCH-040  ARCHITECTURE.md, AGENTS.md, README.md, install.sh and the
#                  snippet's note: state, evidence, guards, compaction entry,
#                  no PostCompact claim (with a README mutation step)
#
# One `req` block per ID. T13 appends its blocks (ARCHITECTURE.md, AGENTS.md,
# README.md) below the last one here, before `finish`.
#
# Phrases are matched on a flattened copy of each file (newlines folded to
# spaces), so a sentence re-wrapped across lines still matches; orders are
# matched on the file itself, by line.
#
# shellcheck disable=SC2016
# File-wide: every pattern here is literal prose lifted out of a Markdown
# prompt; backticks are code spans in that prose, never command substitution.
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

repo=$TEST_REPO
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/touch-docs.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

# flat <file> <out> — the file with every run of whitespace folded to one space.
flat() {
  tr '\n' ' ' < "$1" | tr -s ' ' > "$2"
}

spec_md="$repo/commands/spec.md"
build_md="$repo/commands/build.md"
ship_md="$repo/commands/ship.md"
feature_md="$repo/commands/feature.md"
for f in "$spec_md" "$build_md" "$ship_md" "$feature_md"; do
  [ -f "$f" ] && flat "$f" "$tmpdir/$(basename "$f" .md).flat"
done
spec_flat="$tmpdir/spec.flat"
build_flat="$tmpdir/build.flat"
ship_flat="$tmpdir/ship.flat"
feature_flat="$tmpdir/feature.flat"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-024"
# The spec-reviewer's prompt asks for `req-gate.sh --report`; without Bash in
# its tools it cannot run it.
assert_grep '^tools:.*Bash' "$repo/agents/spec-reviewer.md"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-030"
# init once the three files exist.
assert_fgrep 'Once the three files are written, run `~/.claude/scripts/sdlc-state.sh init <feature>`' "$spec_flat"
# The stamp only after the owner's explicit approval, never before it.
assert_fgrep "Only after the owner's explicit approval at Gate 1, never before it, run \`~/.claude/scripts/sdlc-state.sh stamp <feature>\`" "$spec_flat"
assert_fgrep "the stamp is the owner's act" "$spec_flat"
# Spec and stamp committed before any /build.
assert_fgrep 'Commit the spec and the stamp' "$spec_flat"
assert_fgrep 'before any `/build`' "$spec_flat"
# init, then Gate 1, then the stamp, then the commit before /build.
assert_order "$spec_md" \
  'sdlc-state\.sh init <feature>' \
  'GATE 1' \
  'sdlc-state\.sh stamp <feature>' \
  'before any `/build`'
# The same rule on the command that chains spec, Gate 1 and build: a feature
# run through /feature must reach its build with an init'd state file and a
# Gate 1 stamp committed, or its first commit on sdlc/<feature> is refused.
assert_fgrep 'run `~/.claude/scripts/sdlc-state.sh init <feature>`' "$feature_flat"
assert_fgrep "Only after the owner's explicit approval at Gate 1, run \`~/.claude/scripts/sdlc-state.sh stamp <feature>\`" "$feature_flat"
assert_fgrep 'the owner answers its permission prompt' "$feature_flat"
assert_fgrep 'commit the spec and the stamp before the build phase' "$feature_flat"
assert_order "$feature_md" \
  'sdlc-state\.sh init <feature>' \
  'GATE 1' \
  'sdlc-state\.sh stamp <feature>' \
  'commit the spec and the stamp' \
  '\*\*Implement\.\*\*'

# ---------------------------------------------------------------------------
req "REQ-TOUCH-029"
# Refusal: no build on a missing or stale stamp.
assert_fgrep 'Build no feature whose stamp is missing or stale' "$build_flat"
assert_fgrep 'sdlc-state.sh stamp-state <feature>' "$build_flat"
# An unstamped in-flight feature: offered once at the prompt, never silently.
assert_fgrep 'An unstamped in-flight feature is offered to the owner at the stamp prompt' "$build_flat"
assert_fgrep 'once, and never stamped silently' "$build_flat"
# The stamp check comes before any task is claimed.
assert_order "$build_md" \
  'sdlc-state\.sh stamp-state <feature>' \
  'Claim before work'
# Evidence LAST, after the code-review fixes and the re-run checks.
assert_fgrep 'LAST, after the code-review fixes and the re-run checks, run `~/.claude/scripts/sdlc-state.sh evidence <feature>`' "$build_flat"
# Then record the verifier's verdict, and the ui-tester's in a webapp repo.
assert_fgrep "record the verifier's verdict with \`sdlc-state.sh record <feature> verifier" "$build_flat"
assert_fgrep 'in a webapp repository, also the ui-tester' "$build_flat"
assert_fgrep 'sdlc-state.sh record <feature> ui-tester' "$build_flat"
assert_order "$build_md" \
  '/code-review with fixes applied' \
  'sdlc-state\.sh evidence <feature>' \
  'sdlc-state\.sh record <feature> verifier' \
  'sdlc-state\.sh record <feature> ui-tester'

# Mutation: the order check above must go red when the evidence line is moved
# above the code-review line in a copy of build.md, and stay green on the file
# itself (so the red is the move, not a pattern that never matches).
# evidence_order_red <file> — exit 0 when the evidence-after-review order fails.
# shellcheck disable=SC2329  # invoked indirectly through assert_exit below
evidence_order_red() {
  (
    TEST_FAILURES=0
    assert_order "$1" \
      '/code-review with fixes applied' \
      'sdlc-state\.sh evidence <feature>' >/dev/null 2>&1
    [ "$TEST_FAILURES" -gt 0 ]
  )
}
mut="$tmpdir/build.mut.md"
ev_line=$(grep -n -F 'sdlc-state.sh evidence <feature>' "$build_md" | head -n 1 | cut -d: -f1)
cr_line=$(grep -n -F '/code-review with fixes applied' "$build_md" | head -n 1 | cut -d: -f1)
if [ -n "$ev_line" ] && [ -n "$cr_line" ] && [ "$ev_line" != "$cr_line" ]; then
  awk -v ev="$ev_line" -v cr="$cr_line" '
    NR == FNR { if (FNR == ev) t = $0; next }
    FNR == ev { next }
    FNR == cr { print t }
    { print }
  ' "$build_md" "$build_md" > "$mut"
  assert_exit nonzero evidence_order_red "$build_md"
  assert_exit 0 evidence_order_red "$mut"
else
  _test_fail "mutation: evidence and /code-review lines not found apart in $build_md"
fi

# ---------------------------------------------------------------------------
req "REQ-TOUCH-028"
assert_fgrep 'Run `~/.claude/scripts/sdlc-state.sh status` as ground truth' "$ship_flat"
assert_fgrep 'Walk no branch whose evidence is not current and green' "$ship_flat"
assert_order "$ship_md" \
  'sdlc-state\.sh status' \
  'Walk no branch whose evidence' \
  'Walk decisions ONE AT A TIME'

# ---------------------------------------------------------------------------
req "REQ-TOUCH-052"
assert_fgrep 'In a repository whose `TEST_PROFILE` is `webapp`' "$ship_flat"
assert_fgrep 'whose evidence carries no ui-tester verdict' "$ship_flat"
assert_fgrep 'dispatch the `ui-tester` agent and record its verdict' "$ship_flat"
assert_fgrep 'sdlc-state.sh record <feature> ui-tester' "$ship_flat"
assert_fgrep 'before the walk' "$ship_flat"
assert_order "$ship_md" \
  'sdlc-state\.sh status' \
  'dispatch the `ui-tester` agent' \
  'Walk decisions ONE AT A TIME'

# ---------------------------------------------------------------------------
req "REQ-TOUCH-040"
# Five surfaces describe the state file, the evidence file, the three guards
# with their warn window and override, and the post-compaction entry, and none
# of them makes a PostCompact claim. Which phrase is asserted where:
#
#   phrase                     ARCH  AGENTS  README  install.sh  note
#   state.json                  x      x       x        x         x
#   evidence.json               x      x       x        x         x
#   gate1-stamp                 x      x       x        x         x
#   evidence-merge              x      x       x        x         x
#   stop-evidence               x      x       x        x         x
#   14 days                     x      x       x        x         x
#   SDLC_GUARD_MODE             x      x       x        x         x
#   compact-policy.sh           x      x       x        x         x
#   SessionStart                x      x       x        x         x
#   sdlc-state.sh               x      x       x        x         x
#   guard-lib.sh                x      -       x        -         -
#   SDLC_STOP_BLOCK_CAP         x      -       -        -         -
#   permissions.ask             -      -       x        -         x
#   no PostCompact (any case)   x      x       x        x         x
#
# AGENTS.md also says the stamp is the owner's act and that evidence is written
# only by `sdlc-state.sh evidence`. The snippet's note is its top-level "//"
# value, read with jq.
arch_md="$repo/ARCHITECTURE.md"
agents_md="$repo/AGENTS.md"
readme_md="$repo/README.md"
install_sh="$repo/install.sh"
note_txt="$tmpdir/snippet-note.txt"
jq -r '.["//"] // ""' "$repo/settings/hooks-snippet.json" > "$note_txt"
for f in "$arch_md" "$agents_md" "$readme_md" "$install_sh"; do
  [ -f "$f" ] && flat "$f" "$tmpdir/$(basename "$f").flat"
done
flat "$note_txt" "$tmpdir/note.flat"
arch_flat="$tmpdir/ARCHITECTURE.md.flat"
agents_flat="$tmpdir/AGENTS.md.flat"
readme_flat="$tmpdir/README.md.flat"
install_flat="$tmpdir/install.sh.flat"
note_flat="$tmpdir/note.flat"

for f in "$arch_flat" "$agents_flat" "$readme_flat" "$install_flat" "$note_flat"; do
  for phrase in 'state.json' 'evidence.json' 'gate1-stamp' 'evidence-merge' \
                'stop-evidence' '14 days' 'SDLC_GUARD_MODE' 'compact-policy.sh' \
                'SessionStart' 'sdlc-state.sh'; do
    assert_fgrep "$phrase" "$f"
  done
done
assert_fgrep 'guard-lib.sh' "$arch_flat"
assert_fgrep 'guard-lib.sh' "$readme_flat"
assert_fgrep 'SDLC_STOP_BLOCK_CAP' "$arch_flat"
assert_fgrep 'permissions.ask' "$readme_flat"
assert_fgrep 'permissions.ask' "$note_flat"
# AGENTS.md in its own terms: the stamp is the owner's, evidence has one writer.
assert_fgrep "never run \`sdlc-state.sh stamp\` without the owner's explicit approval at Gate 1" "$agents_flat"
assert_fgrep 'written only by `sdlc-state.sh evidence`' "$agents_flat"
# The compaction entry is named as what it is: SessionStart with matcher compact.
assert_grep '^      compact-policy\.sh +SessionStart \(matcher compact\): ' "$readme_md"
assert_grep '^\| `compact-policy\.sh` \| SessionStart \(matcher `compact`\) \|' "$arch_md"
# The file map carries the two new scripts in the same column format.
assert_grep '^      guard-lib\.sh +' "$readme_md"
assert_grep '^      sdlc-state\.sh +' "$readme_md"

# No PostCompact claim anywhere on the five surfaces, in any letter case.
no_postcompact='[Pp][Oo][Ss][Tt][Cc][Oo][Mm][Pp][Aa][Cc][Tt]'
for f in "$arch_md" "$agents_md" "$readme_md" "$note_txt"; do
  assert_no_grep "$no_postcompact" "$f"
done
# install.sh is the one surface that must name the old entry: it tells an
# owner upgrading from it to delete the leftover hook and settings entry. So
# there the word may stand only on a line that says to delete or remove it,
# and as the name of the stale script it looks for (postcompact-policy.sh);
# every other line is held to the same no-PostCompact rule.
# removal_only <file> <out> — the file minus its delete/remove lines and
# minus the stale script's file name.
removal_only() {
  grep -viE 'delete|remove' "$1" | sed 's/postcompact-policy\.sh//g' > "$2" || true
}
removal_only "$install_sh" "$tmpdir/install.claims"
assert_no_grep "$no_postcompact" "$tmpdir/install.claims"
assert_grep 'PostCompact entry, delete it after the merge' "$install_sh"
# Mutation (a PostCompact claim put into install.sh): the filtered check must
# go red on a copy carrying one, so the filter is proven not to swallow it.
install_mut="$tmpdir/install.mut.sh"
cp "$install_sh" "$install_mut"
printf '# A PostCompact entry re-injects the routing policy after compaction.\n' >> "$install_mut"
removal_only "$install_mut" "$tmpdir/install.mut.claims"
if grep -qE -- "$no_postcompact" "$tmpdir/install.mut.claims"; then
  _test_pass "a PostCompact claim in install.sh is caught by the filtered check"
else
  _test_fail "the filtered check missed a PostCompact claim in install.sh"
fi

# Mutation (README PostCompact put back): the no-PostCompact check must go red
# on a copy of README.md with a PostCompact sentence restored, and stay green
# on the file itself, so the assertion is proven to read the text.
# postcompact_red <file> — exit 0 when the no-PostCompact assertion fails.
# shellcheck disable=SC2329  # invoked indirectly through assert_exit below
postcompact_red() {
  (
    TEST_FAILURES=0
    assert_no_grep "$no_postcompact" "$1" >/dev/null 2>&1
    [ "$TEST_FAILURES" -gt 0 ]
  )
}
readme_mut="$tmpdir/README.mut.md"
cp "$readme_md" "$readme_mut"
printf '\nA postCompact entry re-injects the routing section after compaction.\n' >> "$readme_mut"
assert_exit nonzero postcompact_red "$readme_md"
assert_exit 0 postcompact_red "$readme_mut"

finish
