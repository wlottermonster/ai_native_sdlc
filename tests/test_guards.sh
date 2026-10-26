#!/bin/bash
# AI-Native SDLC — tests for hooks/guard-lib.sh, the warn-then-deny clock
# every guard shares: self-seeding only when the guards directory is absent,
# the 14-day warn window, the SDLC_GUARD_MODE override, deny on an
# unwritable directory, and deny on a missing, non-numeric or future clock.
#
# Every case points SDLC_GUARDS_DIR at a fresh path under mktemp -d, removed
# on exit; nothing here reads or writes the real $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

LIB="$TEST_REPO/hooks/guard-lib.sh"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-guards.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
# The REQ-TOUCH-013 fixtures make directories read-only, so the modes are put
# back before the tree is removed.
cleanup() { chmod -R u+rwx "$tmproot" 2>/dev/null || true; rm -rf "$tmproot"; }
trap cleanup EXIT

# Never let git discovery climb out of the temp root (guard_log asks git).
export GIT_CEILING_DIRECTORIES="$tmproot"

DAY=86400
TEXT_1="REFUSED: the demo guard would block this commit."
TEXT_2="Run the demo fix, then retry."
TEXT="$TEXT_1
$TEXT_2"

# newdir — a fresh, not-yet-existing guards directory path (unique per call,
# even from a command substitution, which a counter would not be).
newdir() {
  local d
  d=$(mktemp -d "$tmproot/guards.XXXXXX") && rmdir "$d" && printf '%s' "$d"
}

# refuse <lib> <guards-dir> <mode|-> <outfile> — source <lib> in a child
# shell and call guard_refuse once; output in <outfile>, exit in <outfile>.rc.
# "-" leaves SDLC_GUARD_MODE unset.
refuse() {
  local lib="$1" dir="$2" mode="$3" out="$4"
  # shellcheck disable=SC2016  # expanded by the child shell, not here
  local code='. "$1" || exit 99; guard_refuse demo "$2"'
  if [ "$mode" = "-" ]; then
    capture "$out" env -u SDLC_GUARD_MODE SDLC_GUARDS_DIR="$dir" \
      bash -c "$code" _ "$lib" "$TEXT"
  else
    capture "$out" env SDLC_GUARD_MODE="$mode" SDLC_GUARDS_DIR="$dir" \
      bash -c "$code" _ "$lib" "$TEXT"
  fi
}

# seeded <since> — a guards directory whose demo clock reads <since>.
seeded() {
  local d
  d=$(mktemp -d "$tmproot/guards.XXXXXX")
  printf '%s\n' "$1" > "$d/demo.since"
  printf '%s' "$d"
}

utc_date() { date -u -r "$1" +%F 2>/dev/null || date -u -d "@$1" +%F; }

# first_line_into <file> <out> — the first line of <file>, for anchored asserts.
first_line_into() { head -n 1 "$1" > "$2"; }

lines_of() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

now=$(date +%s)

req "REQ-TOUCH-010"
d=$(newdir)
refuse "$LIB" "$d" - "$tmproot/o010"
assert_rc 0 "$tmproot/o010"
assert_file "$d/demo.since"
first_line_into "$tmproot/o010" "$tmproot/o010.first"
assert_grep '^WARN' "$tmproot/o010.first"
seeded_at=$(tr -d '[:space:]' < "$d/demo.since" 2>/dev/null)
case "$seeded_at" in
  ''|*[!0-9]*) seeded_at=0 ;;
esac
drift=$(( $(date +%s) - seeded_at ))
if [ "$drift" -ge 0 ] && [ "$drift" -le 5 ]; then
  _test_pass "seeded clock is the current epoch ($seeded_at)"
else
  _test_fail "seeded clock $seeded_at is not within 5 s of now"
fi
# The first guard to fire seeds EVERY guard's clock, not only its own: with
# the directory absent, one gate1-stamp refusal leaves all three .since files,
# so the next guard to fire (stop-evidence) warns instead of finding the
# directory present and its clock missing (a REQ-TOUCH-046 deny).
# refuse_as <guard> <guards-dir> <outfile> — guard_refuse <guard>, mode unset.
refuse_as() {
  # shellcheck disable=SC2016  # expanded by the child shell, not here
  capture "$3" env -u SDLC_GUARD_MODE SDLC_GUARDS_DIR="$2" \
    bash -c '. "$1" || exit 99; guard_refuse "$2" "$3"' _ "$LIB" "$1" "$TEXT"
}
d=$(newdir)
refuse_as gate1-stamp "$d" "$tmproot/o010all"
assert_rc 0 "$tmproot/o010all"
for g in gate1-stamp evidence-merge stop-evidence; do
  assert_file "$d/$g.since"
  assert_grep '^[0-9]+$' "$d/$g.since"
done
refuse_as stop-evidence "$d" "$tmproot/o010second"
assert_rc 0 "$tmproot/o010second"
first_line_into "$tmproot/o010second" "$tmproot/o010second.first"
assert_grep '^WARN \(stop-evidence' "$tmproot/o010second.first"
# Seeding all fills only what is missing: an existing clock is not reset.
d=$(newdir)
mkdir -p "$d"
printf '%s\n' $((now - DAY)) > "$d/evidence-merge.since"
# shellcheck disable=SC2016  # expanded by the child shell, not here
capture "$tmproot/o010keep" env SDLC_GUARDS_DIR="$d" \
  bash -c '. "$1" || exit 99; guards_seed_all' _ "$LIB"
assert_rc 0 "$tmproot/o010keep"
assert_grep "^$((now - DAY))\$" "$d/evidence-merge.since"
assert_file "$d/gate1-stamp.since"
assert_file "$d/stop-evidence.since"

req "REQ-TOUCH-011"
since=$((now - DAY))
d=$(seeded "$since")
deny_on=$(utc_date $((since + 14 * DAY)))
refuse "$LIB" "$d" - "$tmproot/o011"
assert_rc 0 "$tmproot/o011"
first_line_into "$tmproot/o011" "$tmproot/o011.first"
assert_grep '^WARN' "$tmproot/o011.first"
assert_fgrep "$deny_on" "$tmproot/o011.first"
assert_fgrep "$TEXT_1" "$tmproot/o011"
assert_fgrep "$TEXT_2" "$tmproot/o011"
printf '%s\n' "$(lines_of "$d/demo.log")" > "$tmproot/o011.n1"
assert_grep '^1$' "$tmproot/o011.n1"
assert_fgrep "$TEXT_1" "$d/demo.log"
# time, repository, branch, reason: four tab-separated fields.
assert_grep '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^	]*	[^	]+	[^	]+	.+' "$d/demo.log"
refuse "$LIB" "$d" - "$tmproot/o011b"
assert_rc 0 "$tmproot/o011b"
printf '%s\n' "$(lines_of "$d/demo.log")" > "$tmproot/o011.n2"
assert_grep '^2$' "$tmproot/o011.n2"

req "REQ-TOUCH-012"
d=$(seeded $((now - 15 * DAY)))
refuse "$LIB" "$d" - "$tmproot/o012"
assert_rc 2 "$tmproot/o012"
assert_fgrep "$TEXT_1" "$tmproot/o012"
assert_fgrep "$TEXT_2" "$tmproot/o012"
assert_no_grep 'WARN' "$tmproot/o012"
d=$(seeded "$now")
refuse "$LIB" "$d" deny "$tmproot/o012b"
assert_rc 2 "$tmproot/o012b"
assert_fgrep "$TEXT_1" "$tmproot/o012b"
assert_no_grep 'WARN' "$tmproot/o012b"
# An unrecognised mode value is ignored: the fresh clock still warns.
d=$(seeded "$now")
refuse "$LIB" "$d" maybe "$tmproot/o012c"
assert_rc 0 "$tmproot/o012c"

req "REQ-TOUCH-045"
d=$(seeded $((now - 100 * DAY)))
refuse "$LIB" "$d" warn "$tmproot/o045"
assert_rc 0 "$tmproot/o045"
first_line_into "$tmproot/o045" "$tmproot/o045.first"
assert_grep '^WARN' "$tmproot/o045.first"
assert_fgrep "$TEXT_1" "$tmproot/o045"

req "REQ-TOUCH-013"
d=$(seeded "$now")
chmod 555 "$d"
refuse "$LIB" "$d" - "$tmproot/o013"
assert_rc 2 "$tmproot/o013"
assert_fgrep "$d" "$tmproot/o013"
assert_fgrep "$TEXT_1" "$tmproot/o013"
chmod 755 "$d"
parent="$tmproot/locked"
mkdir -p "$parent"
chmod 555 "$parent"
refuse "$LIB" "$parent/guards" - "$tmproot/o013b"
assert_rc 2 "$tmproot/o013b"
assert_fgrep "$parent/guards" "$tmproot/o013b"
chmod 755 "$parent"

req "REQ-TOUCH-046"
d=$(newdir)
mkdir -p "$d"
refuse "$LIB" "$d" - "$tmproot/o046a"
assert_rc 2 "$tmproot/o046a"
assert_fgrep "$d/demo.since" "$tmproot/o046a"
d=$(seeded abc)
refuse "$LIB" "$d" - "$tmproot/o046b"
assert_rc 2 "$tmproot/o046b"
assert_fgrep "$d/demo.since" "$tmproot/o046b"
d=$(seeded $((now + 1000)))
refuse "$LIB" "$d" - "$tmproot/o046c"
assert_rc 2 "$tmproot/o046c"
assert_fgrep "$d/demo.since" "$tmproot/o046c"
# A deleted clock cannot restart the window: warn, delete, then deny.
d=$(seeded $((now - DAY)))
refuse "$LIB" "$d" - "$tmproot/o046d"
assert_rc 0 "$tmproot/o046d"
rm -f "$d/demo.since"
refuse "$LIB" "$d" - "$tmproot/o046e"
assert_rc 2 "$tmproot/o046e"
assert_fgrep "$d/demo.since" "$tmproot/o046e"

req "REQ-TOUCH-012"
# Spelling: the window is written as the product, never the four-digit run
# the year scrub would match.
assert_grep 'SDLC_GUARD_WINDOW=\$\(\(14 \* 86400\)\)' "$LIB"
assert_no_grep '1209600' "$LIB"

# MUTATION: widen the warn window to 100 days in a copy of the library. The
# 15-day clock that denies above must now warn, proving the REQ-TOUCH-012
# case observes the window and not merely the presence of a string.
mut="$tmproot/mutant"
mkdir -p "$mut"
# shellcheck disable=SC2016  # the arithmetic is literal library text
sed 's/\$((14 \* 86400))/$((100 * 86400))/' "$LIB" > "$mut/guard-lib.sh"
if [ ! -s "$LIB" ] || [ ! -s "$mut/guard-lib.sh" ] || cmp -s "$LIB" "$mut/guard-lib.sh"; then
  _test_fail "mutation changed nothing: no library, or the window spelling was not found"
else
  _test_pass "mutation applied: window widened to 100 days"
fi
d=$(seeded $((now - 15 * DAY)))
refuse "$mut/guard-lib.sh" "$d" - "$tmproot/omut"
assert_rc 0 "$tmproot/omut"

# --- evidence trees (REQ-TOUCH-044) -----------------------------------------
# etree <repo> <feature> <ref|WORKTREE> <outfile> — run evidence_tree from
# <repo> in a child shell; output in <outfile>, exit in <outfile>.rc.
etree() {
  # shellcheck disable=SC2016  # expanded by the child shell, not here
  capture "$4" bash -c 'cd "$1" || exit 98; . "$2" || exit 99; evidence_tree "$3" "$4"' \
    _ "$1" "$LIB" "$2" "$3"
}

# same_tree <a> <b> <what> / other_tree <a> <b> <what> — compare two captured
# evidence trees; an empty capture is never a match either way.
same_tree() {
  if [ -s "$1" ] && cmp -s "$1" "$2"; then _test_pass "$3"; else _test_fail "$3"; fi
}
other_tree() {
  if [ -s "$1" ] && [ -s "$2" ] && ! cmp -s "$1" "$2"; then _test_pass "$3"; else _test_fail "$3"; fi
}

req "REQ-TOUCH-044"
er="$tmproot/etree-repo"
mkdir -p "$er/specs/f"
git -C "$er" init -q
git -C "$er" config user.name "SDLC Test"
git -C "$er" config user.email "sdlc-test@example.invalid"
echo 'print(1)' > "$er/code.py"
echo '# f' > "$er/specs/f/requirements.md"
git -C "$er" add -A
git -C "$er" commit -qm init
etree "$er" f HEAD "$tmproot/e1"
etree "$er" f WORKTREE "$tmproot/e2"
assert_rc 0 "$tmproot/e1"
assert_rc 0 "$tmproot/e2"
assert_grep '^[0-9a-f]{40}$' "$tmproot/e1"
same_tree "$tmproot/e1" "$tmproot/e2" "clean tree: HEAD and WORKTREE evidence trees are equal"
# The two evidence files themselves never move the evidence tree.
echo '{"head":"x"}' > "$er/specs/f/state.json"
echo '{"ok":true}' > "$er/specs/f/evidence.json"
etree "$er" f WORKTREE "$tmproot/e3"
same_tree "$tmproot/e1" "$tmproot/e3" "state.json and evidence.json in the work tree leave the evidence tree unchanged"
# A content change does.
echo 'print(2)' > "$er/code.py"
etree "$er" f WORKTREE "$tmproot/e4"
assert_rc 0 "$tmproot/e4"
other_tree "$tmproot/e1" "$tmproot/e4" "a code change moves the work-tree evidence tree"
# An untracked, non-ignored file counts too.
echo 'print(1)' > "$er/code.py"
echo 'new' > "$er/new.py"
etree "$er" f WORKTREE "$tmproot/e4b"
other_tree "$tmproot/e1" "$tmproot/e4b" "an untracked file moves the work-tree evidence tree"
rm -f "$er/new.py"
# Committing the two files: HEAD's evidence tree is still the first value.
git -C "$er" add specs/f/state.json specs/f/evidence.json
git -C "$er" commit -qm evidence
etree "$er" f HEAD "$tmproot/e5"
same_tree "$tmproot/e1" "$tmproot/e5" "committing state.json and evidence.json leaves HEAD's evidence tree unchanged"
# From a subdirectory the work tree is still read from the top.
etree "$er/specs" f WORKTREE "$tmproot/e5b"
same_tree "$tmproot/e1" "$tmproot/e5b" "WORKTREE from a subdirectory reads the whole repository"
# A ref that does not resolve: nothing printed, non-zero.
etree "$er" f no-such-ref "$tmproot/e6"
assert_rc nonzero "$tmproot/e6"
if [ -f "$tmproot/e6" ] && [ ! -s "$tmproot/e6" ]; then
  _test_pass "a bogus ref prints nothing"
else
  _test_fail "a bogus ref printed something (or did not run)"
fi
# The repository's own index is never touched.
git -C "$er" status --porcelain > "$tmproot/e7"
if [ -f "$tmproot/e7" ] && [ ! -s "$tmproot/e7" ]; then
  _test_pass "the repository's own index and tree are untouched"
else
  _test_fail "evidence_tree left the repository dirty"
fi
# A tracked file that matches .gitignore (force-added) is part of HEAD's tree,
# so the work tree's evidence tree must keep it: otherwise the two never match
# and every evidence comparison in such a repository reads stale forever.
gr="$tmproot/etree-ignored"
mkdir -p "$gr/specs/f"
git -C "$gr" init -q
git -C "$gr" config user.name "SDLC Test"
git -C "$gr" config user.email "sdlc-test@example.invalid"
printf '*.lock\n' > "$gr/.gitignore"
echo 'pinned' > "$gr/a.lock"
echo 'print(1)' > "$gr/code.py"
echo '# f' > "$gr/specs/f/requirements.md"
git -C "$gr" add -A
git -C "$gr" add -f a.lock
git -C "$gr" commit -qm init
etree "$gr" f HEAD "$tmproot/g1"
etree "$gr" f WORKTREE "$tmproot/g2"
assert_rc 0 "$tmproot/g2"
same_tree "$tmproot/g1" "$tmproot/g2" "a force-added ignored file: clean tree, HEAD and WORKTREE evidence trees are equal"
# Changing the tracked ignored file moves the work-tree evidence tree.
echo 'repinned' > "$gr/a.lock"
etree "$gr" f WORKTREE "$tmproot/g3"
other_tree "$tmproot/g1" "$tmproot/g3" "a change to a tracked ignored file moves the work-tree evidence tree"
git -C "$gr" checkout -q -- a.lock
# Deleting a tracked file moves it.
rm -f "$gr/code.py"
etree "$gr" f WORKTREE "$tmproot/g4"
other_tree "$tmproot/g1" "$tmproot/g4" "a deleted tracked file moves the work-tree evidence tree"
git -C "$gr" checkout -q -- code.py
# An untracked, non-ignored file moves it.
echo 'new' > "$gr/new.py"
etree "$gr" f WORKTREE "$tmproot/g5"
other_tree "$tmproot/g1" "$tmproot/g5" "an untracked non-ignored file moves the work-tree evidence tree"
rm -f "$gr/new.py"
# An untracked ignored file does not.
echo 'scratch' > "$gr/b.lock"
etree "$gr" f WORKTREE "$tmproot/g6"
same_tree "$tmproot/g1" "$tmproot/g6" "an untracked ignored file leaves the work-tree evidence tree unchanged"
rm -f "$gr/b.lock"
# A repository with no commit yet: the work tree still has an evidence tree.
nr="$tmproot/etree-unborn"
mkdir -p "$nr"
git -C "$nr" init -q
echo 'x' > "$nr/x.py"
etree "$nr" f WORKTREE "$tmproot/g7"
assert_rc 0 "$tmproot/g7"
assert_grep '^[0-9a-f]{40}$' "$tmproot/g7"

# --- the PreToolUse warn document (REQ-TOUCH-014) ---------------------------
req "REQ-TOUCH-014"
warned="WARN (demo: denial begins soon)
$TEXT_1"
# shellcheck disable=SC2016  # expanded by the child shell, not here
capture "$tmproot/c1" bash -c '. "$1" || exit 99; GUARD_WARNED="$2"; guard_context_json "$3"' \
  _ "$LIB" "$warned" "req-gate: coverage report line"
assert_rc 0 "$tmproot/c1"
if jq -e . "$tmproot/c1" > /dev/null 2>&1; then
  _test_pass "output parses as JSON"
else
  _test_fail "output does not parse as JSON"
fi
jq -s 'length' "$tmproot/c1" > "$tmproot/c1.n" 2>/dev/null
assert_grep '^1$' "$tmproot/c1.n"
jq -r '.hookSpecificOutput.hookEventName' "$tmproot/c1" > "$tmproot/c1.ev" 2>/dev/null
assert_grep '^PreToolUse$' "$tmproot/c1.ev"
jq -r '.hookSpecificOutput.additionalContext' "$tmproot/c1" > "$tmproot/c1.ctx" 2>/dev/null
assert_fgrep "WARN (demo" "$tmproot/c1.ctx"
assert_fgrep "$TEXT_1" "$tmproot/c1.ctx"
assert_fgrep "req-gate: coverage report line" "$tmproot/c1.ctx"
assert_order "$tmproot/c1.ctx" '^WARN' 'req-gate: coverage'
jq -r 'paths | map(tostring) | join(".")' "$tmproot/c1" > "$tmproot/c1.paths" 2>/dev/null
assert_grep 'hookSpecificOutput\.additionalContext' "$tmproot/c1.paths"
assert_no_grep 'permissionDecision' "$tmproot/c1.paths"
assert_no_grep 'permissionDecision' "$tmproot/c1"
# Only the requirement gate's text: still one document.
# shellcheck disable=SC2016  # expanded by the child shell, not here
capture "$tmproot/c2" env -u GUARD_WARNED bash -c '. "$1" || exit 99; guard_context_json "$2"' \
  _ "$LIB" "only req text"
assert_rc 0 "$tmproot/c2"
jq -r '.hookSpecificOutput.additionalContext' "$tmproot/c2" > "$tmproot/c2.ctx" 2>/dev/null
assert_grep '^only req text$' "$tmproot/c2.ctx"
# Nothing to say: no output, exit 1.
# shellcheck disable=SC2016  # expanded by the child shell, not here
capture "$tmproot/c3" env -u GUARD_WARNED bash -c '. "$1" || exit 99; guard_context_json ""' _ "$LIB"
assert_rc 1 "$tmproot/c3"
if [ -f "$tmproot/c3" ] && [ ! -s "$tmproot/c3" ]; then
  _test_pass "nothing to say prints nothing"
else
  _test_fail "nothing to say printed something"
fi

finish
