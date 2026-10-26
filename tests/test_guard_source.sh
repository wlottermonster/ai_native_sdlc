#!/bin/bash
# AI-Native SDLC — the gates and their guard library.
#
#   REQ-TOUCH-047  check-gate.sh and dod.sh source hooks/guard-lib.sh and exit
#                  2 naming it when it cannot be sourced — proven by deleting
#                  the library from a copy of the hooks and watching both gates
#                  refuse payloads they otherwise allow.
#   REQ-TOUCH-051  tests/lib.sh points SDLC_GUARDS_DIR at a throwaway directory,
#                  so a hook run from the suite never touches $HOME/.claude.
#
# Every fixture lives under a mktemp -d directory removed on exit, with HOME
# pointed at a throwaway directory.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-guardsrc.XXXXXX")
tmproot=$(cd "$tmproot" && pwd)
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT
export GIT_CEILING_DIRECTORIES="$tmproot"

# hooks_copy <name> — a copy of the shipped hooks directory.
hooks_copy() {
  mkdir -p "$tmproot/$1"
  cp "$repo"/hooks/*.sh "$tmproot/$1/"
  printf '%s' "$tmproot/$1"
}

# A home with the requirement gate installed, as install.sh leaves it.
ghome=$(fresh_home "$tmproot")
mkdir -p "$ghome/.claude/hooks"
cp "$repo/hooks/req-gate.sh" "$ghome/.claude/hooks/req-gate.sh"

# A target repo whose checks pass, with one uncommitted code change.
target="$tmproot/target"
mkdir -p "$target"
git -C "$target" init -q
git -C "$target" config user.name "SDLC Test"
git -C "$target" config user.email "sdlc-test@example.invalid"
printf 'check:\n\t@true\n' > "$target/Makefile"
echo 'print(1)' > "$target/src.py"
git -C "$target" add -A
git -C "$target" commit -qm init
echo 'print(2)' > "$target/src.py"

commit_payload=$(jq -n --arg c "git commit -m x" --arg cwd "$target" '{tool_input:{command:$c},cwd:$cwd}')

# run_hook <outfile> <hook> <payload> — stdin payload, cwd the target repo,
# HOME the throwaway home; output and exit code captured.
run_hook() {
  local rc=0
  ( cd "$target" && printf '%s' "$3" | HOME="$ghome" bash "$2" ) > "$1" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$1.rc"
}

good=$(hooks_copy good)
bad=$(hooks_copy bad)
rm -f "$bad/guard-lib.sh"

req "REQ-TOUCH-047"
# Control: with the library present both payloads are allowed.
run_hook "$tmproot/cg-ok" "$good/check-gate.sh" "$commit_payload"
assert_rc 0 "$tmproot/cg-ok"
run_hook "$tmproot/dod-ok" "$good/dod.sh" '{}'
assert_rc 0 "$tmproot/dod-ok"
# Mutation: the library deleted — both gates refuse and name it.
if [ ! -e "$bad/guard-lib.sh" ] && [ -f "$bad/check-gate.sh" ]; then
  _test_pass "mutation applied: guard-lib.sh removed from the hooks copy"
else
  _test_fail "mutation did not apply"
fi
run_hook "$tmproot/cg-bad" "$bad/check-gate.sh" "$commit_payload"
assert_rc 2 "$tmproot/cg-bad"
assert_fgrep "$bad/guard-lib.sh" "$tmproot/cg-bad"
run_hook "$tmproot/dod-bad" "$bad/dod.sh" '{}'
assert_rc 2 "$tmproot/dod-bad"
assert_fgrep "$bad/guard-lib.sh" "$tmproot/dod-bad"
# A library that exists and fails while being sourced is the same refusal.
broken=$(hooks_copy broken)
printf 'return 1\n' > "$broken/guard-lib.sh"
run_hook "$tmproot/cg-broken" "$broken/check-gate.sh" "$commit_payload"
assert_rc 2 "$tmproot/cg-broken"
assert_fgrep "$broken/guard-lib.sh" "$tmproot/cg-broken"
run_hook "$tmproot/dod-broken" "$broken/dod.sh" '{}'
assert_rc 2 "$tmproot/dod-broken"

req "REQ-TOUCH-051"
# shellcheck disable=SC2016  # the literal text of tests/lib.sh
assert_grep '^SDLC_GUARDS_DIR=\$\(mktemp -d ' "$repo/tests/lib.sh"
assert_grep '^export SDLC_GUARDS_DIR' "$repo/tests/lib.sh"
gdir="${SDLC_GUARDS_DIR:-unset}"
tmpbase="${TMPDIR:-/tmp}"
tmpbase="${tmpbase%/}"
case "$gdir" in
  "$tmpbase"/sdlc-guards-test.*|"$tmpbase"//sdlc-guards-test.*)
    if [ -d "$gdir" ]; then
      _test_pass "SDLC_GUARDS_DIR is a throwaway directory: $gdir"
    else
      _test_fail "SDLC_GUARDS_DIR is not a directory: $gdir"
    fi ;;
  *) _test_fail "SDLC_GUARDS_DIR is not a mktemp directory under $tmpbase: $gdir" ;;
esac
# Behaviour: a guard evaluated from the suite with a fresh HOME reads and
# writes the throwaway directory, never $HOME/.claude/sdlc-guards.
gh=$(fresh_home "$tmproot")
# shellcheck disable=SC2016  # expanded by the child shell, not here
capture "$tmproot/g051" env HOME="$gh" bash -c '. "$1" || exit 99; guard_refuse demo "demo refusal"' \
  _ "$repo/hooks/guard-lib.sh"
assert_fgrep "$gdir/demo.since" "$tmproot/g051"
run_hook "$tmproot/cg051" "$good/check-gate.sh" "$commit_payload"
run_hook "$tmproot/dod051" "$good/dod.sh" '{}'
if [ ! -e "$gh/.claude/sdlc-guards" ] && [ ! -e "$ghome/.claude/sdlc-guards" ]; then
  _test_pass "no hook run created \$HOME/.claude/sdlc-guards"
else
  _test_fail "a hook run created \$HOME/.claude/sdlc-guards"
fi

finish
