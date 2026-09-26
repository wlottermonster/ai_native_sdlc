#!/bin/bash
# AI-Native SDLC — self-gating tests for the framework's own Makefile and
# test runner. Covers REQ-GCORE-029, REQ-GCORE-039, REQ-GCORE-040,
# REQ-GCORE-030, REQ-GCORE-031.
#
# Every fixture lives in a mktemp -d directory and is removed on exit; no test
# here reads or writes the real $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-selfgate.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
req "REQ-GCORE-031"
# The Makefile declares the test profile on a line of its own.
assert_file "$TEST_REPO/Makefile"
assert_grep '^TEST_PROFILE[[:space:]]*=[[:space:]]*lib$' "$TEST_REPO/Makefile"

# ---------------------------------------------------------------------------
req "REQ-GCORE-029"
# Control: an unmodified copy passes, so the negatives below mean something.
d=$(gate_fixture "$tmproot")
assert_exit 0 make -C "$d" check
# A script that fails `bash -n` fails the check target. The failure must be
# attributable to bash -n, not to the shellcheck step that follows it: the
# output carries bash's syntax error and no SC code.
printf '#!/bin/bash\nif true; then\n  echo broken\n' > "$d/hooks/zz-broken.sh"
assert_exit nonzero bash -n "$d/hooks/zz-broken.sh"
out="$d/syntax.out"
capture "$out" make -C "$d" check
assert_rc nonzero "$out"
assert_grep 'syntax error' "$out"
assert_no_grep 'SC[0-9]{4}' "$out"
rm -f "$d/hooks/zz-broken.sh"

# ---------------------------------------------------------------------------
req "REQ-GCORE-039"
# A script that parses fine but has a shellcheck finding fails the check target.
# shellcheck disable=SC2016  # $1 must stay literal: the planted script's
# unquoted positional is exactly the finding this test expects shellcheck to
# report.
printf '#!/bin/bash\nif [ $1 = x ]; then\n  echo hi\nfi\n' > "$d/hooks/zz-lint.sh"
# It parses cleanly, so the failure below is the shellcheck step's alone.
assert_exit 0 bash -n "$d/hooks/zz-lint.sh"
out="$d/lint.out"
capture "$out" make -C "$d" check
assert_rc nonzero "$out"
assert_grep 'SC[0-9]{4}' "$out"
rm -f "$d/hooks/zz-lint.sh"

# With shellcheck absent from PATH the target fails and says so. Absence is
# simulated with a PATH holding only what the target needs up to that step
# (make and bash), so the test does not depend on where a platform's package
# manager installs shellcheck.
stub=$(mktemp -d "$tmproot/stub.XXXXXX")
ln -s "$(command -v make)" "$stub/make"
ln -s "$(command -v bash)" "$stub/bash"
out="$d/nosc.out"
capture "$out" env PATH="$stub" make -C "$d" check
assert_rc nonzero "$out"
assert_grep 'shellcheck' "$out"

# ---------------------------------------------------------------------------
req "REQ-GCORE-040"
# An invalid settings/hooks-snippet.json fails the check target.
# The scripts are untouched here, so only the jq step can fail.
cp "$d/settings/hooks-snippet.json" "$d/hooks-snippet.json.orig"
printf 'this is not json\n' > "$d/settings/hooks-snippet.json"
out="$d/json.out"
capture "$out" make -C "$d" check
assert_rc nonzero "$out"
assert_grep 'parse error' "$out"
cp "$d/hooks-snippet.json.orig" "$d/settings/hooks-snippet.json"

# ---------------------------------------------------------------------------
req "REQ-GCORE-030"
# One failing tests/test_*.sh makes the test target fail...
printf '#!/bin/bash\nexit 1\n' > "$d/tests/test_zz_fails.sh"
printf '#!/bin/bash\nexit 0\n' > "$d/tests/test_zz_passes.sh"
assert_exit nonzero make -C "$d" test
# ...and with only passing test files it succeeds.
rm -f "$d/tests/test_zz_fails.sh"
assert_exit 0 make -C "$d" test

finish
