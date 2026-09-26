#!/bin/bash
# AI-Native SDLC — assertion helpers and fixture builders. Source this from
# tests/test_*.sh:
#
#   # shellcheck source-path=SCRIPTDIR
#   # shellcheck source=lib.sh
#   . "$(dirname "$0")/lib.sh"
#   req "REQ-<FEATURE>-001"
#   assert_grep '^pattern$' path/to/file
#   finish
#
# Every assertion is labelled with the REQ-ID last passed to `req`, so a
# failure names the requirement it belongs to. `finish` exits non-zero if any
# assertion failed.

TEST_FAILURES=0
TEST_ASSERTIONS=0
TEST_CURRENT_REQ=""

# The framework checkout (the directory above tests/): what the fixture
# builders below copy from.
TEST_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# req <REQ-ID> — announce which requirement the following assertions check.
req() {
  TEST_CURRENT_REQ="$1"
  printf '  -- %s\n' "$1"
}

_test_pass() {
  TEST_ASSERTIONS=$((TEST_ASSERTIONS + 1))
  printf '     ok    %s\n' "$1"
}

_test_fail() {
  TEST_ASSERTIONS=$((TEST_ASSERTIONS + 1))
  TEST_FAILURES=$((TEST_FAILURES + 1))
  printf '     FAIL  [%s] %s\n' "${TEST_CURRENT_REQ:-no-req}" "$1" >&2
}

# assert_grep <extended-regex> <file>
assert_grep() {
  if [ -f "$2" ] && grep -qE -- "$1" "$2"; then
    _test_pass "matches /$1/ : $2"
  else
    _test_fail "expected /$1/ in $2"
  fi
}

# assert_no_grep <extended-regex> <file> — a missing file is a failure, not a
# vacuous pass: "no match" must mean the file was read and did not match.
assert_no_grep() {
  if [ ! -f "$2" ]; then
    _test_fail "missing: $2"
  elif grep -qE -- "$1" "$2"; then
    _test_fail "did not expect /$1/ in $2"
  else
    _test_pass "no match /$1/ : $2"
  fi
}

# assert_fgrep <literal-string> <file> — fixed-string match (grep -F), for
# phrases full of regex metacharacters and sentences a requirement pins
# verbatim.
assert_fgrep() {
  if [ -f "$2" ] && grep -qF -- "$1" "$2"; then
    _test_pass "contains literally [$1] : $2"
  else
    _test_fail "expected literally [$1] in $2"
  fi
}

# assert_order <file> <ere> [<ere>...] — every pattern must match, and the
# first line each matches on must be strictly greater than the previous one's.
# A prompt whose sections are all present but shuffled is a different prompt,
# so order is asserted, not just presence.
assert_order() {
  local file="$1"
  shift
  local prev=0 line pat
  for pat in "$@"; do
    line=$(grep -nE -- "$pat" "$file" 2>/dev/null | head -n 1 | cut -d: -f1)
    if [ -z "$line" ]; then
      _test_fail "order: no match for /$pat/ in $file"
      return
    fi
    if [ "$line" -le "$prev" ]; then
      _test_fail "order: /$pat/ at line $line, expected after line $prev in $file"
      return
    fi
    prev="$line"
  done
  _test_pass "ordered: $* : $file"
}

# assert_file <path>
assert_file() {
  if [ -e "$1" ]; then
    _test_pass "exists: $1"
  else
    _test_fail "missing: $1"
  fi
}

# assert_exit <expected-code|nonzero> <cmd> [args...] — run the command (its
# output discarded) and assert on its exit code. When the output is needed as
# well, use `capture` + `assert_rc` so the command runs once, not twice.
assert_exit() {
  local expected="$1"
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  _assert_code "$expected" "$rc" "$*"
}

# capture <outfile> <cmd> [args...] — run the command once with stdout+stderr
# in <outfile> and its exit code in <outfile>.rc, so both can be asserted on.
capture() {
  local out="$1"
  shift
  local rc=0
  "$@" >"$out" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$out.rc"
}

# assert_rc <expected-code|nonzero> <outfile> — assert on the exit code that
# `capture` stored beside <outfile>.
assert_rc() {
  local rc
  if [ ! -f "$2.rc" ]; then
    _test_fail "missing: $2.rc (no capture)"
    return
  fi
  rc=$(tr -d '[:space:]' < "$2.rc")
  _assert_code "$1" "$rc" "$2"
}

_assert_code() {
  local expected="$1" rc="$2" what="$3"
  if [ "$expected" = "nonzero" ]; then
    if [ "$rc" -ne 0 ]; then
      _test_pass "exit $rc (nonzero): $what"
    else
      _test_fail "expected nonzero exit, got 0: $what"
    fi
  elif [ "$rc" = "$expected" ]; then
    _test_pass "exit $rc: $what"
  else
    _test_fail "expected exit $expected, got $rc: $what"
  fi
}

# count_into <file> <extended-regex> <countfile> — write the number of matching
# lines to <countfile> so it can be asserted on with assert_grep.
count_into() {
  local n
  n=$(grep -cE -- "$2" "$1" || true)
  printf '%s\n' "$n" > "$3"
}

# --- fixture builders -------------------------------------------------------
# Each copies part of the framework checkout into a fresh temp dir under
# <parent> and echoes the new path. Callers own <parent> (mktemp -d + trap).

# gate_fixture <parent> — the gating surface: Makefile + the shell scripts +
# the hooks snippet + the test harness (but never the test_*.sh files, which
# would recurse).
gate_fixture() {
  local d
  d=$(mktemp -d "$1/fixture.XXXXXX")
  mkdir -p "$d/hooks" "$d/scripts" "$d/settings" "$d/tests"
  cp "$TEST_REPO/Makefile" "$d/Makefile"
  cp "$TEST_REPO"/hooks/*.sh "$d/hooks/"
  cp "$TEST_REPO"/scripts/*.sh "$d/scripts/"
  cp "$TEST_REPO/install.sh" "$d/install.sh"
  cp "$TEST_REPO/settings/hooks-snippet.json" "$d/settings/hooks-snippet.json"
  cp "$TEST_REPO/tests/lib.sh" "$d/tests/lib.sh"
  cp "$TEST_REPO/tests/run.sh" "$d/tests/run.sh"
  # Preserve the complete Python gate surface in self-gate fixtures.
  cp -RL "$TEST_REPO/adapters" "$TEST_REPO/core" "$d/"
  cp -RL "$TEST_REPO/agents" "$TEST_REPO/commands" "$TEST_REPO/templates" "$d/"
  cp "$TEST_REPO/sdlc-policy.md" "$d/sdlc-policy.md"
  cp "$TEST_REPO/.gitignore" "$d/.gitignore"
  cp -R "$TEST_REPO/tests/codex" "$d/tests/"
  # The migration record is private working-repository history; a published
  # checkout has none, and the Python test that reads it skips itself.
  if [ -f "$TEST_REPO/docs/portability-step5/source-disposition.json" ]; then
    mkdir -p "$d/docs/portability-step5"
    cp "$TEST_REPO/docs/portability-step5/source-manifest.json" \
       "$TEST_REPO/docs/portability-step5/source-disposition.json" "$d/docs/portability-step5/"
  fi
  if [ -f "$TEST_REPO/.sdlc-openai/step5-original-openai.tar.gz" ]; then
    mkdir -p "$d/.sdlc-openai"
    cp "$TEST_REPO/.sdlc-openai/step5-original-openai.tar.gz" "$d/.sdlc-openai/"
  fi
  printf '%s' "$d"
}

# install_fixture <parent> — the installer and everything it installs.
#
# agents/ is copied WHOLE, so any `agents/*.conf` beside the agent prompts
# (the role manifest) comes with it; the explicit copy below is the belt to
# that braces, and is skipped when no .conf exists yet. templates/ is copied
# whole too — the engine map template lives there. Both are guarded rather
# than assumed: install.sh runs under `set -euo pipefail`, so a fixture built
# before those files land must still be a working fixture, not a hard error.
install_fixture() {
  local d f
  d=$(mktemp -d "$1/fixture.XXXXXX")
  cp -RL "$TEST_REPO/agents" "$TEST_REPO/commands" "$TEST_REPO/hooks" \
        "$TEST_REPO/scripts" "$d/"
  for f in "$TEST_REPO"/agents/*.conf; do
    [ -f "$f" ] && cp "$f" "$d/agents/"
  done
  if [ -d "$TEST_REPO/templates" ]; then
    cp -RL "$TEST_REPO/templates" "$d/"
  fi
  cp "$TEST_REPO/install.sh" "$d/install.sh"
  cp "$TEST_REPO/sdlc-policy.md" "$d/sdlc-policy.md"
  cp -R "$TEST_REPO/core" "$d/core"
  cp -RL "$TEST_REPO/adapters" "$d/adapters"
  printf '%s' "$d"
}

# fresh_home <parent> — an empty throwaway $HOME, .claude not yet created.
fresh_home() {
  mktemp -d "$1/home.XXXXXX"
}

# run_install <fixture-dir> <home> <scan-root|-> <outfile> — run the installer
# with HOME pointed at a throwaway dir and SDLC_SCAN_ROOT at <scan-root> ("-"
# leaves it unset so the fallback root is exercised), capturing output in
# <outfile> and the exit code in <outfile>.rc.
run_install() {
  if [ "$3" = "-" ]; then
    capture "$4" env HOME="$2" bash "$1/install.sh"
  else
    capture "$4" env HOME="$2" SDLC_SCAN_ROOT="$3" bash "$1/install.sh"
  fi
}

# finish — print the tally and exit non-zero if anything failed.
finish() {
  if [ "$TEST_FAILURES" -gt 0 ]; then
    printf '     %d of %d assertion(s) FAILED\n' "$TEST_FAILURES" "$TEST_ASSERTIONS" >&2
    exit 1
  fi
  printf '     %d assertion(s) passed\n' "$TEST_ASSERTIONS"
  exit 0
}
