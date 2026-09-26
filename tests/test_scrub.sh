#!/bin/bash
# AI-Native SDLC — the framework's shipped surface must be generic: no project
# or owner specifics, no dated attributions, and the replacement wordings must
# actually be present. Covers REQ-GCORE-001 (the fence over the explicit file
# list), REQ-GCORE-002 (the batch rules survive the scrub), REQ-GCORE-003 and
# REQ-GCORE-004 (the generic push-equals-deploy and decision-log phrasings).
#
# This file is under tests/, which REQ-GCORE-001 excludes from the scrub, and
# specs/ is excluded too. Both are excluded BY CONSTRUCTION: the file
# list below is built explicitly and never by `grep -r`. Dotfiles under
# templates/ (a stray .DS_Store, an editor swap file) are not shipped surface
# and are skipped, and binary files are never counted as offending lines.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

cd "$repo" || exit 1

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-scrub.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# The built-in pattern is only a four-digit year, which catches dated
# attributions ("owner 2026-09-01"). A `%Y` in a shell script is fine — it is
# not four literal digits.
#
# Project, product and owner names are NOT spelled here: this file is
# published with the framework. They come from a machine-local list, one FIXED
# string per line (matched with grep -F, as publish.sh does; CR stripped,
# whitespace trimmed, `#` comments and blank lines ignored), at
# $SDLC_SCRUB_TOKENS_FILE or ~/.config/ainative-sdlc/scrub-tokens. Without
# that file the fence still catches every year.
TOKENS='20[0-9][0-9]'
local_tokens="${SDLC_SCRUB_TOKENS_FILE:-$HOME/.config/ainative-sdlc/scrub-tokens}"
: > "$tmpdir/local-tokens.txt"
if [ -f "$local_tokens" ]; then
  tr -d '\r' < "$local_tokens" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | awk 'length($0) > 0 && substr($0, 1, 1) != "#"' > "$tmpdir/local-tokens.txt" \
    || { printf 'REQ-GCORE-001: cannot read %s\n' "$local_tokens" >&2; exit 1; }
  printf 'REQ-GCORE-001: local token list loaded from %s\n' "$local_tokens"
fi

# ---------------------------------------------------------------------------
# REQ-GCORE-001 — the fence, over an EXPLICIT file list (never `grep -r`).
#
# The list also covers `agents/*.conf` (the role manifest) and
# `settings/*.json` (the hooks snippet) per REQ-ENGINE-031, so a forbidden
# token in either cannot ship unscanned. tests/test_engines.sh asserts that
# widening is still here.
req "REQ-GCORE-001"

FILES=()
for f in sdlc-policy.md README.md install.sh \
         commands/*.md agents/*.md agents/*.conf hooks/*.sh scripts/*.sh \
         settings/*.json; do
  [ -f "$f" ] && FILES+=("$f")
done
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(find -H templates -type f ! -name '.*' | LC_ALL=C sort)

printf '%s\n' ${FILES[@]+"${FILES[@]}"} > "$tmpdir/list.txt"
printf '%s\n' "${#FILES[@]}" > "$tmpdir/count.txt"

printf 'REQ-GCORE-001: scanning %d file(s)\n' "${#FILES[@]}"

# The list must be non-empty — an empty list cannot pass by scanning nothing.
assert_grep '^[1-9][0-9]*$' "$tmpdir/count.txt"

# ...and must actually contain the four anchor files.
assert_grep '^sdlc-policy\.md$' "$tmpdir/list.txt"
# Compatibility directory links must not hide templates from the scrub.
assert_grep '^templates/specs/requirements\.md$' "$tmpdir/list.txt"
assert_grep '^README\.md$' "$tmpdir/list.txt"
assert_grep '^install\.sh$' "$tmpdir/list.txt"

# specs/ and tests/ are excluded by construction: no entry may come from them.
assert_no_grep '^(specs|tests)/' "$tmpdir/list.txt"

# Each sweep's exit code is read, never swallowed: 0 = offending lines, 1 =
# clean, anything else (a bad pattern, an unreadable file) = the sweep did not
# run, which is a failure — never a clean pass.
: > "$tmpdir/offenders.txt"
: > "$tmpdir/sweep-errors.txt"
scrub_sweep() {
  local rc=0
  grep "$@" >> "$tmpdir/offenders.txt" 2>> "$tmpdir/sweep-errors.txt" || rc=$?
  if [ "$rc" -gt 1 ]; then
    printf 'sweep could not run (grep exit %s): %s\n' "$rc" "${*: -1}" >> "$tmpdir/sweep-errors.txt"
  fi
}
for f in ${FILES[@]+"${FILES[@]}"}; do
  scrub_sweep -H -n -i -I -E "$TOKENS" "$f"
  if [ -s "$tmpdir/local-tokens.txt" ]; then
    scrub_sweep -H -n -i -I -F -f "$tmpdir/local-tokens.txt" "$f"
  fi
done
if grep -q 'sweep could not run' "$tmpdir/sweep-errors.txt"; then
  cat "$tmpdir/sweep-errors.txt" >&2
  _test_fail "sweep could not run over the fence"
else
  _test_pass "every sweep ran"
fi

offenders=$(wc -l < "$tmpdir/offenders.txt" | tr -d '[:space:]')
printf '%s\n' "$offenders" > "$tmpdir/offcount.txt"
if [ "$offenders" != "0" ]; then
  printf 'REQ-GCORE-001: offending lines:\n' >&2
  cat "$tmpdir/offenders.txt" >&2
fi
assert_grep '^0$' "$tmpdir/offcount.txt"

# Mutation: the fence must go red when a fenced file carries a year or a token
# from the local list. A scratch copy of the fenced files and this test is
# swept twice — once with a planted year, once with a planted scratch token
# supplied through a temporary SDLC_SCRUB_TOKENS_FILE. The inner runs set
# SDLC_SCRUB_NO_SELFTEST so they do not recurse.
if [ -z "${SDLC_SCRUB_NO_SELFTEST:-}" ]; then
  mut="$tmpdir/mutant"
  mkdir -p "$mut/tests"
  cp "$here/lib.sh" "$here/test_scrub.sh" "$mut/tests/"
  for f in ${FILES[@]+"${FILES[@]}"}; do
    mkdir -p "$mut/$(dirname "$f")"
    cp "$f" "$mut/$f"
  done
  printf 'scratch-token-not-a-name\n' > "$tmpdir/scratch-tokens.txt"

  cp "$mut/README.md" "$tmpdir/readme.orig"
  printf 'Dated note, 20%s.\n' "99" >> "$mut/README.md"
  capture "$tmpdir/mut-year.out" env SDLC_SCRUB_NO_SELFTEST=1 \
    SDLC_SCRUB_TOKENS_FILE="$tmpdir/scratch-tokens.txt" bash "$mut/tests/test_scrub.sh"
  assert_rc nonzero "$tmpdir/mut-year.out"
  assert_grep '^README\.md:[0-9]+:Dated note' "$tmpdir/mut-year.out"

  cp "$tmpdir/readme.orig" "$mut/README.md"
  printf 'mentions Scratch-Token-Not-A-Name once\n' >> "$mut/README.md"
  capture "$tmpdir/mut-token.out" env SDLC_SCRUB_NO_SELFTEST=1 \
    SDLC_SCRUB_TOKENS_FILE="$tmpdir/scratch-tokens.txt" bash "$mut/tests/test_scrub.sh"
  assert_rc nonzero "$tmpdir/mut-token.out"
  assert_grep '^README\.md:[0-9]+:mentions Scratch-Token' "$tmpdir/mut-token.out"

  # ...and the unplanted copy is clean against the same scratch list, so the
  # two refusals above came from the plants and nothing else.
  cp "$tmpdir/readme.orig" "$mut/README.md"
  capture "$tmpdir/mut-clean.out" env SDLC_SCRUB_NO_SELFTEST=1 \
    SDLC_SCRUB_TOKENS_FILE="$tmpdir/scratch-tokens.txt" bash "$mut/tests/test_scrub.sh"
  assert_rc 0 "$tmpdir/mut-clean.out"
fi

# ---------------------------------------------------------------------------
# REQ-GCORE-002 — the scrub must not gut the owner-testing batch rules.
req "REQ-GCORE-002"

policy="$repo/sdlc-policy.md"
assert_file "$policy"

# The heading keeps its name and loses only its dated attribution.
assert_grep '^## Owner testing after a build \(the batch loop\)$' "$policy"

# Findings move by batch, not by drip.
assert_grep 'batch' "$policy"
assert_grep 'drip' "$policy"
# Two lanes.
assert_grep 'Cosmetic' "$policy"
assert_grep 'Behaviour' "$policy"
# One refresh per batch.
assert_grep 'One refresh per batch' "$policy"

# ---------------------------------------------------------------------------
# REQ-GCORE-003 — push = deploy points at the repo's own CLAUDE.md.
req "REQ-GCORE-003"

ship="$repo/commands/ship.md"
assert_file "$ship"

# Both files sit inside the fence above, so the local token list sweeps them
# for any private product or deployment name; the generic wording is asserted
# here.
assert_grep '^sdlc-policy\.md$' "$tmpdir/list.txt"
assert_grep '^commands/ship\.md$' "$tmpdir/list.txt"
assert_grep "the repo's CLAUDE\.md names" "$policy"
assert_grep "the repo's CLAUDE\.md names" "$ship"

# ---------------------------------------------------------------------------
# REQ-GCORE-004 — shipped decisions are distilled into the project's own log.
req "REQ-GCORE-004"

tmpl_design="$repo/templates/specs/design.md"
assert_file "$tmpl_design"

# Both files sit inside the fence, so no private product name can stand in
# for the generic decision-log wording asserted here.
assert_grep '^commands/ship\.md$' "$tmpdir/list.txt"
assert_grep '^templates/specs/design\.md$' "$tmpdir/list.txt"
assert_grep "the project's decision log" "$ship"
assert_grep "the project's decision log" "$tmpl_design"

finish
