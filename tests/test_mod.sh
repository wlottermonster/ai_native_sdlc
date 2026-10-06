#!/bin/bash
# AI-Native SDLC — the engine-map mod as the engine itself reports it, and the
# gate that runs the engine's own checks on it.
#
# Covers:
#   REQ-MOD-029  every test title of the mod matches REQ-MOD-[0-9]{3}: read
#                from the source (and proved red on a copy with one bad
#                title), and from the titles `claude plugin test` ran.
#   REQ-MOD-003  `make check` in a gate fixture whose PATH lacks `claude`:
#                one NOT-run line and a failure, or with SDLC_SKIP_CLAUDE_MOD=1
#                the same line and `check: OK`. This file obeys the same rule:
#                without `claude` it fails, unless the variable is set, and it
#                proves that by running itself again under a PATH without
#                `claude` (the `make test` half). The README's "Codex
#                specifics" section names the variable.
#   REQ-MOD-006  the mod hooks exactly the allow-list scripts/mod-check.sh
#                holds (agent.spawn, session.start, turn.start, turn.complete)
#                and nothing else, read from the hook report
#                of `claude plugin validate --json` and compared as a set (an
#                allow-list: one extra event of any name fails, and so does a
#                missing one); no gating hook without a `.catch`, and at least
#                one gating hook, so the check cannot pass on an empty report.
#   REQ-MOD-028  scripts/mod-check.sh test runs `claude plugin test`.
#   REQ-MOD-030  a copy naming `no.such.event` fails validate, naming it.
#   REQ-MOD-002  `make check` in a fixture validates the mod: a clean mod
#                passes with the validate report in the output, a mod naming
#                an unknown event fails the target, and so do a copy whose
#                agent.spawn registration lost its `.catch` and a copy with an
#                extra `tool.call` registration: the commit lane refuses what
#                the test lane refuses.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

mod="$TEST_REPO/adapters/claude/skills/sdlc-engine-map"
modcheck="$TEST_REPO/scripts/mod-check.sh"
notrun='mod checks NOT run: claude is not on PATH'
# Set when this file runs itself under a PATH without claude (REQ-MOD-003).
nested="${SDLC_TEST_MOD_NESTED:-}"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-mod.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# titles <mod-dir> <outfile> — every test title of every *.test.ts under the
# mod, one per line. A `test(` or `it(` call whose first argument is not a
# string literal is written as `<non-literal>`, so it can never pass.
# (read from a heredoc, not `$(cat <<...)`: bash 3.2 mis-parses the backtick
# in the pattern inside a command substitution.)
title_prog=""
IFS= read -r -d '' title_prog <<'PERL' || true
while (/(?<![\w.\$])(?:test|it)(?:\.\w+)*\(\s*(?:([\x27"`])(.*?)\1)?/sg) {
  print defined $2 ? "$2\n" : "<non-literal>\n";
}
PERL
titles() {
  find "$1" -name '*.test.ts' -not -path '*/node_modules/*' -print0 \
    | xargs -0 perl -0777 -ne "$title_prog" > "$2"
}

# untitled <titles-file> <outfile> — the titles that carry no REQ-MOD-NNN.
untitled() {
  grep -vE 'REQ-MOD-[0-9]{3}' "$1" > "$2" || true
}

# --- REQ-MOD-029, from the source -------------------------------------------
req "REQ-MOD-029"
titles "$mod" "$tmpdir/titles"
n=$(grep -c '' "$tmpdir/titles" || true)
if [ "${n:-0}" -gt 0 ]; then
  _test_pass "$n test titles read from the mod's *.test.ts"
else
  _test_fail "no test titles found under $mod: an empty read is not a pass"
fi
untitled "$tmpdir/titles" "$tmpdir/untitled"
if [ -s "$tmpdir/untitled" ]; then
  _test_fail "titles without REQ-MOD-NNN: $(tr '\n' '|' < "$tmpdir/untitled")"
else
  _test_pass "every one of the $n titles carries REQ-MOD-NNN"
fi
# The check must see a bad title: one title in a copy loses its REQ-ID.
cp -R "$mod" "$tmpdir/badtitle"
f=$(find "$tmpdir/badtitle" -name '*.test.ts' | head -n 1)
perl -pi -e 's/REQ-MOD-[0-9]{3} ?// if !$done && /(?<![\w.])test\(/ && ($done = 1)' "$f"
titles "$tmpdir/badtitle" "$tmpdir/titles.bad"
untitled "$tmpdir/titles.bad" "$tmpdir/untitled.bad"
if [ -s "$tmpdir/untitled.bad" ]; then
  _test_pass "a copy with one title stripped of its REQ-ID is caught"
else
  _test_fail "a title stripped of its REQ-ID went unnoticed"
fi

# --- REQ-MOD-003: make check without claude on PATH -------------------------
# A bin directory holding every command on PATH except `claude`: the first
# directory on PATH wins a name, as it would for the shell. A nested run
# leaves this block to the outer run that started it.
if [ -z "$nested" ]; then
req "REQ-MOD-003"
noclaude="$tmpdir/noclaude-bin"
mkdir -p "$noclaude"
old_ifs=$IFS
IFS=:
for dir in $PATH; do
  [ -d "$dir" ] || continue
  for cmd in "$dir"/*; do
    { [ -x "$cmd" ] && [ ! -d "$cmd" ]; } || continue
    [ -e "$noclaude/${cmd##*/}" ] || ln -s "$cmd" "$noclaude/${cmd##*/}"
  done
done
IFS=$old_ifs
rm -f "$noclaude/claude"
if PATH="$noclaude" command -v claude >/dev/null 2>&1; then
  _test_fail "the no-claude PATH still finds claude"
else
  _test_pass "the no-claude PATH finds no claude"
fi

fx=$(gate_fixture "$tmpdir")
out="$tmpdir/check.noclaude"
capture "$out" env -u SDLC_SKIP_CLAUDE_MOD PATH="$noclaude" make -C "$fx" check
assert_rc nonzero "$out"
assert_fgrep "$notrun" "$out"
count_into "$out" 'mod checks NOT run' "$out.n"
assert_grep '^1$' "$out.n"
assert_no_grep '^check: OK' "$out"

out="$tmpdir/check.skip"
capture "$out" env SDLC_SKIP_CLAUDE_MOD=1 PATH="$noclaude" make -C "$fx" check
assert_rc 0 "$out"
assert_fgrep "$notrun" "$out"
count_into "$out" 'mod checks NOT run' "$out.n"
assert_grep '^1$' "$out.n"
assert_grep '^check: OK' "$out"

# Only the value 1 is the explicit skip.
out="$tmpdir/check.skipyes"
capture "$out" env SDLC_SKIP_CLAUDE_MOD=yes PATH="$noclaude" make -C "$fx" check
assert_rc nonzero "$out"
assert_no_grep '^check: OK' "$out"

# The README's Codex section is where a Codex-only checkout learns the skip.
awk '/^## /{f = ($0 == "## Codex specifics")} f' "$TEST_REPO/README.md" > "$tmpdir/codex.md"
assert_fgrep 'SDLC_SKIP_CLAUDE_MOD=1' "$tmpdir/codex.md"

# The make-test half: this very file, run again under the no-claude PATH,
# fails with the NOT-run line unless the skip is set; with the skip it prints
# the same line and passes.
out="$tmpdir/suite.noclaude"
capture "$out" env -u SDLC_SKIP_CLAUDE_MOD SDLC_TEST_MOD_NESTED=1 PATH="$noclaude" bash "$here/test_mod.sh"
assert_rc nonzero "$out"
assert_fgrep "$notrun" "$out"

out="$tmpdir/suite.skip"
capture "$out" env SDLC_SKIP_CLAUDE_MOD=1 SDLC_TEST_MOD_NESTED=1 PATH="$noclaude" bash "$here/test_mod.sh"
assert_rc 0 "$out"
assert_fgrep "$notrun" "$out"
fi

# This file obeys the rule it tests: without claude, fail unless skipped.
if ! command -v claude >/dev/null 2>&1; then
  if [ "${SDLC_SKIP_CLAUDE_MOD:-}" = "1" ]; then
    printf '     %s (SDLC_SKIP_CLAUDE_MOD=1: the claude-only blocks are skipped)\n' "$notrun"
  else
    _test_fail "$notrun (set SDLC_SKIP_CLAUDE_MOD=1 to skip explicitly)"
  fi
  finish
fi

req "REQ-MOD-006"
report="$tmpdir/validate.json"
capture "$report" claude plugin validate --json "$mod"
assert_rc 0 "$report"

# Every "<module> hooks: a, b, c" note of every hooks file, split, sorted, once
# each. A report jq cannot read yields nothing, which fails the comparison.
events="$tmpdir/events"
jq -r '.contents[] | select(.type == "hooks") | .notes[]
       | capture("^\\S+ hooks: (?<list>.*)$")? | .list | split(", ")[]' \
  "$report" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//' > "$events"
# The allow-list is read from its one home, scripts/mod-check.sh.
sed -nE 's/^allowed_events="(.*)"$/\1/p' "$modcheck" | tr ' ' '\n' | sed '/^$/d' \
  | sort -u | tr '\n' ' ' | sed 's/ $//' > "$tmpdir/expected"
if [ -s "$tmpdir/expected" ]; then
  _test_pass "allow-list read from scripts/mod-check.sh: $(cat "$tmpdir/expected")"
else
  _test_fail "no allowed_events line in scripts/mod-check.sh: an empty allow-list is not a pass"
fi
if [ "$(cat "$events")" = "$(cat "$tmpdir/expected")" ]; then
  _test_pass "hooked events are exactly: $(cat "$events")"
else
  _test_fail "hooked events are [$(cat "$events")], expected exactly [$(cat "$tmpdir/expected")]"
fi

assert_no_grep 'gating hook without \.catch' "$report"
if jq -e '[.contents[].gatingHooks[]?] | length > 0 and all(.hasCatch == true)' "$report" >/dev/null 2>&1; then
  _test_pass "every gating hook in the report carries a .catch"
else
  _test_fail "a gating hook lacks a .catch, or the report lists none"
fi

# --- REQ-MOD-028: the mod's own suite under the engine's test kit -----------
req "REQ-MOD-028"
out="$tmpdir/plugin-test"
capture "$out" "$modcheck" test
assert_rc 0 "$out"
assert_grep '^ *[1-9][0-9]* pass$' "$out"
assert_grep '^ *0 fail$' "$out"

# --- REQ-MOD-029, from the titles the kit ran -------------------------------
req "REQ-MOD-029"
grep -E '^\((pass|fail|skip|todo)\) ' "$out" > "$tmpdir/ran" || true
ran=$(grep -c '' "$tmpdir/ran" || true)
total=$(sed -nE 's/^Ran ([0-9]+) tests? .*/\1/p' "$out" | head -n 1)
if [ "${ran:-0}" -gt 0 ] && [ "$ran" = "${total:-x}" ]; then
  _test_pass "$ran result lines, as many as the kit says it ran"
else
  _test_fail "result lines [${ran:-0}] do not match the kit's count [${total:-none}]"
fi
untitled "$tmpdir/ran" "$tmpdir/ran.untitled"
if [ -s "$tmpdir/ran.untitled" ]; then
  _test_fail "tests run without REQ-MOD-NNN: $(tr '\n' '|' < "$tmpdir/ran.untitled")"
else
  _test_pass "every title the kit ran carries REQ-MOD-NNN"
fi

# --- REQ-MOD-030: an event this build lacks fails validate, by name ---------
# badevent <register.ts> — rename the turn.start registration in a COPY.
badevent() {
  perl -pi -e "s/on\\('turn\\.start'/on('no.such.event'/" "$1"
  assert_fgrep "on('no.such.event'" "$1"
}

req "REQ-MOD-030"
cp -R "$mod" "$tmpdir/badevent"
badevent "$tmpdir/badevent/hooks/register.ts"
out="$tmpdir/validate.badevent"
capture "$out" claude plugin validate "$tmpdir/badevent"
assert_rc nonzero "$out"
assert_fgrep 'no.such.event' "$out"

# --- REQ-MOD-002: make check validates the mod ------------------------------
req "REQ-MOD-002"
out="$tmpdir/check.clean"
capture "$out" make -C "$fx" check
assert_rc 0 "$out"
assert_fgrep 'Validation passed' "$out"
assert_fgrep 'hooks: agent.spawn' "$out"
assert_grep '^check: OK' "$out"

badevent "$fx/adapters/claude/skills/sdlc-engine-map/hooks/register.ts"
out="$tmpdir/check.badevent"
capture "$out" make -C "$fx" check
assert_rc nonzero "$out"
assert_fgrep 'no.such.event' "$out"
assert_no_grep '^check: OK' "$out"

# The skip is for a missing client only: it never silences a check that ran.
out="$tmpdir/check.badevent.skip"
capture "$out" env SDLC_SKIP_CLAUDE_MOD=1 make -C "$fx" check
assert_rc nonzero "$out"
assert_fgrep 'no.such.event' "$out"

# Mutation: the agent.spawn registration loses its `.catch`. validate only
# warns on that; the gate must refuse it.
fx_nocatch=$(gate_fixture "$tmpdir")
reg="$fx_nocatch/adapters/claude/skills/sdlc-engine-map/hooks/register.ts"
perl -0pi -e 's/\}\)\.catch\(async \(\$, e, next\) => \{\n\s*await failed\(\$, \x27agent\.spawn\x27[^\n]*\n\s*return next\(e\)\n\s*\}\)/})/' "$reg"
assert_no_grep "agent.spawn', next.error" "$reg"
out="$tmpdir/check.nocatch"
capture "$out" make -C "$fx_nocatch" check
assert_rc nonzero "$out"
assert_fgrep 'gating hook without .catch' "$out"
assert_no_grep '^check: OK' "$out"

# Mutation: one event more, with a `.catch` of its own so validate passes it.
fx_extra=$(gate_fixture "$tmpdir")
reg="$fx_extra/adapters/claude/skills/sdlc-engine-map/hooks/register.ts"
perl -0pi -e 's/  guard\(\x27turn\.start\x27/  guard(\x27tool.call\x27, () => {\n    on(\x27tool.call\x27, async (\$, e, next) => next(e)).catch(async (\$, e, next) => {\n      return next(e)\n    })\n  })\n\n  guard(\x27turn.start\x27/' "$reg"
assert_fgrep "on('tool.call'" "$reg"
out="$tmpdir/check.extra"
capture "$out" make -C "$fx_extra" check
assert_rc nonzero "$out"
assert_fgrep 'tool.call' "$out"
assert_no_grep '^check: OK' "$out"

finish
