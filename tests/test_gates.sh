#!/bin/bash
# AI-Native SDLC — gate tests for the framework's own Makefile and test runner.
# Covers REQ-GCORE-032 (make check enforces the requirement gate, running the
# repo's own hooks/req-gate.sh) and REQ-GCORE-033 (tests/run.sh fails on an
# empty suite and always reports the count of test files executed), plus the
# commit gate's fail-CLOSED contract (HUNT-CHECKGATE-CD).
#
# Every fixture lives in a mktemp -d directory and is removed on exit; no test
# here reads or writes the real $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-gates.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
# The commit-gate fixtures below deliberately create a directory the test user
# cannot enter, so the modes are put back before the tree is removed.
cleanup() { chmod -R u+rwx "$tmproot" 2>/dev/null || true; rm -rf "$tmproot"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
req "REQ-GCORE-032"
# A real git repo carrying a spec whose requirement has no task: `make check`
# must fail on Gate A, because req-gate.sh runs in enforce mode after the lint
# steps. The fixture is its own git repo with a local identity, so nothing
# depends on the caller's git config or on the real $HOME.
d=$(gate_fixture "$tmproot")
git -C "$d" init -q
git -C "$d" config user.name "SDLC Test"
git -C "$d" config user.email "sdlc-test@example.invalid"
# The fixture's requirement ID is assembled at run time so the literal never
# appears in this file: req-gate's orphan check scans every test file for
# REQ-shaped tokens, and a demo ID spelled out here would be reported as an
# orphan on every /ship digest.
demo_feat=DEMO
demo_id="REQ-${demo_feat}-001"
mkdir -p "$d/specs/demo"
printf '# demo — requirements\n\n%s  WHEN the demo runs, THE SYSTEM SHALL do the demo thing.\n              verify: unit\n' \
  "$demo_id" > "$d/specs/demo/requirements.md"
# The task list leaves a box open, so Gate B (tests) stays out of this: the only
# thing that can fail below is Gate A's missing-task check.
printf '# demo — tasks\n\n- [ ] T1: build the demo thing\n' > "$d/specs/demo/tasks.md"
out="$d/gatea.out"
capture "$out" make -C "$d" check
assert_rc nonzero "$out"
assert_grep 'GATE A' "$out"

# With the requirement referenced by a task, the same tree passes.
printf '# demo — tasks\n\n- [ ] T1: build the demo thing    [%s]\n' \
  "$demo_id" > "$d/specs/demo/tasks.md"
assert_exit 0 make -C "$d" check

# The gate that ran is the fixture's own hooks/req-gate.sh — the repo copy is
# the source of truth, never an installed one: with the task reference removed
# again but the fixture's gate replaced by a no-op, the check goes green.
printf '# demo — tasks\n\n- [ ] T1: build the demo thing\n' > "$d/specs/demo/tasks.md"
printf '#!/bin/bash\nexit 0\n' > "$d/hooks/req-gate.sh"
assert_exit 0 make -C "$d" check

# ---------------------------------------------------------------------------
req "REQ-GCORE-033"
# An empty suite is a failure, not a pass: run.sh exits non-zero and says why.
d=$(mktemp -d "$tmproot/runner.XXXXXX")
cp "$TEST_REPO/tests/lib.sh" "$d/lib.sh"
cp "$TEST_REPO/tests/run.sh" "$d/run.sh"
out="$d/empty.out"
capture "$out" bash "$d/run.sh"
assert_rc nonzero "$out"
assert_grep 'no test files' "$out"
assert_grep '^test files executed: 0$' "$out"

# With one passing test file it succeeds and reports the count it ran.
printf '#!/bin/bash\nexit 0\n' > "$d/test_zz_passes.sh"
out="$d/one.out"
capture "$out" bash "$d/run.sh"
assert_rc 0 "$out"
assert_grep '^test files executed: 1$' "$out"

# ---------------------------------------------------------------------------
req "HUNT-CHECKGATE-CD"
# The commit gate (hooks/check-gate.sh) must never ALLOW a commit whose checks
# it could not run, and must never run those checks in a directory other than
# the one the commit targets.
#
# The mechanism under test is "the gate cannot enter the directory it is meant
# to check". An unenterable directory is only the cheapest way to build that
# state — every assertion below is about the gate's exit code and about which
# repo `make check` actually ran in, never about permission bits.

gate="$TEST_REPO/hooks/check-gate.sh"
gd=$(mktemp -d "$tmproot/commitgate.XXXXXX")
ghome=$(mktemp -d "$tmproot/ghome.XXXXXX")   # a throwaway ~/.claude — nothing real is read
# The requirement gate is installed there, as install.sh leaves it: a missing
# one blocks every commit (REQ-GATE-016), which is not what these cases test.
mkdir -p "$ghome/.claude/hooks"
cp "$TEST_REPO/hooks/req-gate.sh" "$ghome/.claude/hooks/req-gate.sh"
witness="$gd/witness"

# gate_repo <dir> <check-exit> — a throwaway git repo whose `make check`
# appends the repo's own basename to $witness, so a run leaves a trace of WHERE
# it happened, and then exits <check-exit>.
gate_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.name "SDLC Test"
  git -C "$1" config user.email "sdlc-test@example.invalid"
  printf 'check:\n\t@echo %s >> %s; exit %s\n' "$(basename "$1")" "$witness" "$2" > "$1/Makefile"
  echo x > "$1/src.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

# run_gate <outfile> <process-cwd> <payload-json> — drive check-gate.sh exactly
# as the hook runner does: payload on stdin, started from <process-cwd>.
# Output+exit code land in <outfile>/<outfile>.rc for assert_rc/assert_grep.
run_gate() {
  local rc=0
  : > "$witness"
  ( cd "$2" || exit 99
    printf '%s' "$3" | HOME="$ghome" bash "$gate" ) > "$1" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$1.rc"
}

gate_repo "$gd/target" 1    # the repo the commit targets: its checks FAIL
gate_repo "$gd/other"  0    # an unrelated repo: its checks PASS

# Precondition, asserted rather than assumed: a directory can satisfy `[ -d ]`
# and still refuse `cd`. If this ever stopped holding (a run as root, say) the
# negatives below would pass vacuously, so both halves are checked.
sealed="$gd/target"
chmod 000 "$sealed"
assert_exit 0 test -d "$sealed"
# shellcheck disable=SC2016  # $1 must stay literal: it is the inner shell's
# positional, bound to "$sealed" by the argument after the script.
assert_exit nonzero bash -c 'cd "$1"' _ "$sealed"
chmod 755 "$sealed"

# --- the directory named by the payload's .cwd -----------------------------
payload_cwd="{\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$gd/target\"}"
# Control: reachable target, its checks fail → blocked, and the check ran there.
out="$gd/cwd-control.out"
run_gate "$out" "$gd/other" "$payload_cwd"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
# Unreachable target: the gate must block, must name the directory, and must
# NOT have fallen through into the unrelated repo it was standing in.
chmod 000 "$gd/target"
out="$gd/cwd-sealed.out"
run_gate "$out" "$gd/other" "$payload_cwd"
chmod 755 "$gd/target"
assert_rc 2 "$out"
assert_no_grep '.' "$witness"
assert_grep 'BLOCKED' "$out"
assert_fgrep "$gd/target" "$out"

# --- the directory named by the command's leading `cd` ---------------------
payload_cd="{\"tool_input\":{\"command\":\"cd $gd/target && git commit -m x\"},\"cwd\":\"$gd/other\"}"
out="$gd/cd-control.out"
run_gate "$out" "$gd/other" "$payload_cd"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
chmod 000 "$gd/target"
out="$gd/cd-sealed.out"
run_gate "$out" "$gd/other" "$payload_cd"
chmod 755 "$gd/target"
assert_rc 2 "$out"
assert_no_grep '.' "$witness"
assert_grep 'BLOCKED' "$out"
assert_fgrep "$gd/target" "$out"

# --- the directory named by `git -C <repo> commit` -------------------------
payload_gitc="{\"tool_input\":{\"command\":\"git -C $gd/target commit -m x\"},\"cwd\":\"$gd/other\"}"
out="$gd/gitc-control.out"
run_gate "$out" "$gd/other" "$payload_gitc"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
chmod 000 "$gd/target"
out="$gd/gitc-sealed.out"
run_gate "$out" "$gd/other" "$payload_gitc"
chmod 755 "$gd/target"
assert_rc 2 "$out"
assert_no_grep '.' "$witness"
assert_grep 'BLOCKED' "$out"
assert_fgrep "$gd/target" "$out"

# --- the allows the gate makes DELIBERATELY must survive -------------------
# 1. Not a git commit at all. The target's checks would fail if they ran.
out="$gd/allow-notcommit.out"
run_gate "$out" "$gd/other" \
  "{\"tool_input\":{\"command\":\"echo hello\"},\"cwd\":\"$gd/target\"}"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"

# 2. A path that is not a git repository.
mkdir -p "$gd/plain"
out="$gd/allow-norepo.out"
run_gate "$out" "$gd/plain" \
  "{\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$gd/plain\"}"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"

# 3. A docs-only staged set skips the checks (the target's would fail).
mkdir -p "$gd/target/docs"
echo note > "$gd/target/docs/note.md"
git -C "$gd/target" add docs/note.md
out="$gd/allow-docs.out"
run_gate "$out" "$gd/other" "$payload_cwd"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"
git -C "$gd/target" reset -q
rm -rf "$gd/target/docs"

# 4. A repo with no `check` contract at all.
mkdir -p "$gd/nocheck"
git -C "$gd/nocheck" init -q
git -C "$gd/nocheck" config user.name "SDLC Test"
git -C "$gd/nocheck" config user.email "sdlc-test@example.invalid"
echo x > "$gd/nocheck/src.txt"
git -C "$gd/nocheck" add -A
git -C "$gd/nocheck" commit -qm init
out="$gd/allow-nocheck.out"
run_gate "$out" "$gd/other" \
  "{\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$gd/nocheck\"}"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"

finish
