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

# ---------------------------------------------------------------------------
# The gate1-stamp guard (REQ-TOUCH-014, 015, 016). One fixture repo carries
# the gating surface; its Makefile check is replaced by `true` so nothing here
# waits on the real suite. Every case is a docs-only commit (only a .md
# staged), so the shortcut is exactly what the guard has to sit in front of.
# The branch is set with `git symbolic-ref`, which needs no commit and leaves
# the index alone. Every run sets SDLC_GUARD_MODE explicitly: the suite's
# guards directory exists with no clock, which on its own would deny.
sd=$(gate_fixture "$tmproot")
git -C "$sd" init -q
git -C "$sd" config user.name "SDLC Test"
git -C "$sd" config user.email "sdlc-test@example.invalid"
printf 'check:\n\ttrue\n' > "$sd/Makefile"
shome=$(mktemp -d "$tmproot/shome.XXXXXX")   # empty: no installed copies to fall back on
demo_extra_id="REQ-${demo_feat}-002"
mkdir -p "$sd/specs/demo" "$sd/specs/demo-extra" "$sd/specs/_shipped"
printf '# demo — requirements\n\n%s  WHEN the demo runs, THE SYSTEM SHALL do the demo thing.\n              verify: unit\n' \
  "$demo_id" > "$sd/specs/demo/requirements.md"
printf '# demo — tasks\n\n- [ ] T1: build the demo thing    [%s]\n' "$demo_id" > "$sd/specs/demo/tasks.md"
printf '# demo-extra — requirements\n\n%s  WHEN the extra runs, THE SYSTEM SHALL do the extra thing.\n              verify: unit\n' \
  "$demo_extra_id" > "$sd/specs/demo-extra/requirements.md"
printf '# demo-extra — tasks\n\n- [ ] T1: build the extra thing    [%s]\n' "$demo_extra_id" > "$sd/specs/demo-extra/tasks.md"
cp "$sd/specs/demo/requirements.md" "$tmproot/demo-req.orig"
echo note > "$sd/notes.md"
git -C "$sd" add notes.md
stamp_payload="{\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$sd\"}"

# on_branch <branch> — point the fixture's HEAD at <branch>.
on_branch() { git -C "$sd" symbolic-ref HEAD "refs/heads/$1"; }

# stamp_gate <outfile> <mode> [<gate-script>] — run the commit gate on the
# fixture: stdout in <outfile>, stderr in <outfile>.err, exit in <outfile>.rc.
stamp_gate() {
  local rc=0 g="${3:-$sd/hooks/check-gate.sh}"
  ( cd "$sd" || exit 99
    printf '%s' "$stamp_payload" \
      | HOME="$shome" SDLC_GUARD_MODE="$2" bash "$g" ) > "$1" 2> "$1.err" || rc=$?
  printf '%s\n' "$rc" > "$1.rc"
}

# state_sh <args> — the fixture's own state script, run from its root.
state_sh() { ( cd "$sd" && bash "$sd/scripts/sdlc-state.sh" "$@" ) > /dev/null 2>&1; }

req "REQ-TOUCH-015"
on_branch sdlc/demo
# No state.json at all: refused, and the refusal names the guard and the fix.
# This commit is docs-only, the shape the shortcut allows, so the refusal is
# also the ordering proof: the guard runs before the shortcut.
out="$tmproot/s-nostate.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
assert_fgrep "gate1-stamp" "$out.err"
assert_fgrep "sdlc-state.sh stamp demo" "$out.err"
assert_grep 'none' "$out.err"
# init only: a state file without an approval is still `none`.
state_sh init demo
out="$tmproot/s-init.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
assert_grep 'none' "$out.err"
# stamped: allowed.
state_sh stamp demo
out="$tmproot/s-stamped.out"
stamp_gate "$out" deny
assert_rc 0 "$out"
# requirements.md changed after the stamp: stale.
printf 'one more line\n' >> "$sd/specs/demo/requirements.md"
out="$tmproot/s-stale.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
assert_grep 'stale' "$out.err"
cp "$tmproot/demo-req.orig" "$sd/specs/demo/requirements.md"
# state.json edited by hand: invalid (digest mismatch).
cp "$sd/specs/demo/state.json" "$tmproot/demo-state.orig"
perl -0pi -e 's/"approved_at": "[^"]*"/"approved_at": "1999-01-01T00:00:00Z"/' "$sd/specs/demo/state.json"
if cmp -s "$sd/specs/demo/state.json" "$tmproot/demo-state.orig"; then
  _test_fail "the hand edit of state.json changed nothing"
fi
out="$tmproot/s-invalid.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
assert_grep 'invalid' "$out.err"
cp "$tmproot/demo-state.orig" "$sd/specs/demo/state.json"
# A task branch resolves to its feature.
on_branch sdlc/demo-T3
out="$tmproot/s-task.out"
stamp_gate "$out" deny
assert_rc 0 "$out"
# The longest name wins: with only `demo` stamped, sdlc/demo-extra-T1 belongs
# to demo-extra and is refused; stamping demo-extra lets it through.
on_branch sdlc/demo-extra-T1
state_sh init demo-extra
out="$tmproot/s-longest.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
assert_fgrep "sdlc-state.sh stamp demo-extra" "$out.err"
state_sh stamp demo-extra
out="$tmproot/s-longest2.out"
stamp_gate "$out" deny
assert_rc 0 "$out"
# A prefix counts only when followed by `-`: sdlc/demox is not demo's.
on_branch sdlc/demox
out="$tmproot/s-demox.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
assert_fgrep "sdlc/demox" "$out.err"
# `_`-prefixed directories never resolve: sdlc/_shipped has no feature.
on_branch sdlc/_shipped
out="$tmproot/s-underscore.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
assert_fgrep "sdlc/_shipped" "$out.err"
# A guard that cannot find the state script cannot verify: refused.
on_branch sdlc/demo
mv "$sd/scripts/sdlc-state.sh" "$tmproot/sdlc-state.sh.away"
out="$tmproot/s-noscript.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
# The root as git reports it (on macOS /var resolves to /private/var).
assert_fgrep "$(git -C "$sd" rev-parse --show-toplevel)/scripts/sdlc-state.sh" "$out.err"
assert_fgrep "$shome/.claude/scripts/sdlc-state.sh" "$out.err"
mv "$tmproot/sdlc-state.sh.away" "$sd/scripts/sdlc-state.sh"

req "REQ-TOUCH-016"
# Not under sdlc/, or a hunt/rca branch: the guard is not evaluated. demo's
# stamp is made stale here on purpose, so an evaluated guard would refuse.
printf 'one more line\n' >> "$sd/specs/demo/requirements.md"
for b in main sdlc/hunt-20x sdlc/rca-x; do
  on_branch "$b"
  out="$tmproot/s-exempt-${b//\//_}.out"
  stamp_gate "$out" deny
  assert_rc 0 "$out"
  assert_no_grep 'gate1-stamp' "$out"
  assert_no_grep 'gate1-stamp' "$out.err"
done
cp "$tmproot/demo-req.orig" "$sd/specs/demo/requirements.md"
# Any other sdlc/<x> that resolves to nothing: refused under the mode, naming
# the branch.
on_branch sdlc/nothing-matches
out="$tmproot/s-nomatch.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
assert_fgrep "sdlc/nothing-matches" "$out.err"
assert_fgrep "gate1-stamp" "$out.err"
out="$tmproot/s-nomatch-warn.out"
stamp_gate "$out" warn
assert_rc 0 "$out"
assert_fgrep "sdlc/nothing-matches" "$out.err"
assert_grep '^WARN \(gate1-stamp' "$out.err"

req "REQ-TOUCH-014"
# End to end through the hook, warn mode: one JSON document on stdout whose
# only content is additionalContext — never a permissionDecision.
rm -f "$sd/specs/demo/state.json"
on_branch sdlc/demo
glog="$SDLC_GUARDS_DIR/gate1-stamp.log"
before=0
[ -f "$glog" ] && before=$(wc -l < "$glog")
out="$tmproot/s-warn.out"
stamp_gate "$out" warn
assert_rc 0 "$out"
if jq -e . "$out" > /dev/null 2>&1; then
  _test_pass "stdout parses as JSON"
else
  _test_fail "stdout does not parse as JSON"
fi
jq -s 'length' "$out" > "$out.n" 2>/dev/null
assert_grep '^1$' "$out.n"
jq -r '.hookSpecificOutput.hookEventName' "$out" > "$out.ev" 2>/dev/null
assert_grep '^PreToolUse$' "$out.ev"
jq -r '.hookSpecificOutput.additionalContext' "$out" > "$out.ctx" 2>/dev/null
head -n 1 "$out.ctx" > "$out.ctx1"
assert_grep '^WARN \(gate1-stamp' "$out.ctx1"
assert_fgrep "sdlc-state.sh stamp demo" "$out.ctx"
jq '[paths | map(tostring) | join(".")] | map(select(test("permissionDecision"))) | length' \
  "$out" > "$out.pd" 2>/dev/null
assert_grep '^0$' "$out.pd"
after=0
[ -f "$glog" ] && after=$(wc -l < "$glog")
if [ "$after" -eq $((before + 1)) ]; then
  _test_pass "gate1-stamp.log gained one line"
else
  _test_fail "gate1-stamp.log went from $before to $after lines, expected one more"
fi

req "REQ-TOUCH-015"
# MUTATION (guard moved below the docs-only shortcut): a copy of the gate with
# the guard's call moved to just before the final run_req_gate must let the
# same unstamped docs-only commit through. If the copy did not change, or
# still refuses, the ordering assertion above proves nothing.
mutant="$sd/hooks/check-gate-mutant.sh"
perl -0pe 's/^stamp_guard\n//m && s/^run_req_gate\n\z/stamp_guard\nrun_req_gate\n/m' \
  "$sd/hooks/check-gate.sh" > "$mutant"
if cmp -s "$mutant" "$sd/hooks/check-gate.sh"; then
  _test_fail "mutation: moving the guard below the shortcut changed nothing"
else
  _test_pass "mutation: the guard's call was moved"
fi
out="$tmproot/s-mutant.out"
stamp_gate "$out" deny "$mutant"
assert_rc 0 "$out"
out="$tmproot/s-unmutated.out"
stamp_gate "$out" deny
assert_rc 2 "$out"
rm -f "$mutant"

# ---------------------------------------------------------------------------
# The evidence-merge guard and the landing-branch follower (REQ-TOUCH-017,
# 018, 048, 049). One fixture repo: `check:` and `test:` are both `true`
# (the test target exits $MTEST_RC, so a red evidence run needs no Makefile
# edit), `main` is the default branch, feature `demo` is stamped on main, and
# `sdlc/demo` carries a committed, current, green evidence.json produced by
# the fixture's own sdlc-state.sh. `sdlc/demo-T1` is a task branch of demo,
# `sdlc/other` a feature with no evidence, `sdlc/zzz` a branch with no spec.
# Every run sets SDLC_GUARD_MODE explicitly and the fixture's HEAD is `main`
# unless the command itself changes it.
md=$(mktemp -d "$tmproot/merge.XXXXXX")
mhome=$(mktemp -d "$tmproot/mhome.XXXXXX")   # empty: no installed copies
mkdir -p "$md/hooks" "$md/scripts" "$md/specs/demo" "$md/specs/other"
cp "$TEST_REPO"/hooks/*.sh "$md/hooks/"
cp "$TEST_REPO/scripts/sdlc-state.sh" "$md/scripts/sdlc-state.sh"
# shellcheck disable=SC2016  # $$ is make's escape: the recipe reads MTEST_RC
printf 'check:\n\ttrue\ntest:\n\t@exit $${MTEST_RC:-0}\n' > "$md/Makefile"
other_id="REQ-${demo_feat}-003"
printf '# demo — requirements\n\n%s  WHEN the demo runs, THE SYSTEM SHALL do the demo thing.\n              verify: unit\n' \
  "$demo_id" > "$md/specs/demo/requirements.md"
printf '# demo — tasks\n\n- [ ] T1: build the demo thing    [%s]\n' "$demo_id" > "$md/specs/demo/tasks.md"
printf '# other — requirements\n\n%s  WHEN the other runs, THE SYSTEM SHALL do the other thing.\n              verify: unit\n' \
  "$other_id" > "$md/specs/other/requirements.md"
printf '# other — tasks\n\n- [ ] T1: build the other thing    [%s]\n' "$other_id" > "$md/specs/other/tasks.md"
echo readme > "$md/README.md"
git -C "$md" init -q
git -C "$md" symbolic-ref HEAD refs/heads/main
git -C "$md" config user.name "SDLC Test"
git -C "$md" config user.email "sdlc-test@example.invalid"
git -C "$md" add -A
git -C "$md" commit -qm init

# mstate <args> — the fixture's own state script, run from its root.
mstate() { ( cd "$md" && bash "$md/scripts/sdlc-state.sh" "$@" ) > /dev/null 2>&1; }
mstate init demo
mstate stamp demo
git -C "$md" add -A
git -C "$md" commit -qm "stamp demo"
git -C "$md" branch sdlc/other
git -C "$md" branch sdlc/zzz
git -C "$md" checkout -q -b sdlc/demo
mstate evidence demo
git -C "$md" add -A
git -C "$md" commit -qm "evidence demo"
git -C "$md" branch sdlc/demo-T1
git -C "$md" checkout -q main
green=$(git -C "$md" rev-parse sdlc/demo)
# Precondition, asserted: the fixture's evidence really is green on the ref.
# shellcheck disable=SC2016  # $1 is the inner shell's positional
capture "$tmproot/m-pre.out" bash -c 'cd "$1" && bash scripts/sdlc-state.sh evidence-state demo sdlc/demo' _ "$md"
assert_rc 0 "$tmproot/m-pre.out"
assert_grep '^green$' "$tmproot/m-pre.out"

# mgate <outfile> <mode> <command> [<gate-script>] — run the commit gate on the
# fixture with <command>: stdout in <outfile>, stderr in <outfile>.err, exit
# in <outfile>.rc.
mgate() {
  local rc=0 g="${4:-$md/hooks/check-gate.sh}" payload
  payload=$(jq -cn --arg c "$3" --arg d "$md" '{tool_input: {command: $c}, cwd: $d}')
  ( cd "$md" || exit 99
    printf '%s' "$payload" \
      | HOME="$mhome" SDLC_GUARD_MODE="$2" bash "$g" ) > "$1" 2> "$1.err" || rc=$?
  printf '%s\n' "$rc" > "$1.rc"
}
# on_demo <step...> — make one commit on sdlc/demo, then return to main.
on_demo() {
  git -C "$md" checkout -q sdlc/demo
  ( cd "$md" && "$@" ) > /dev/null 2>&1
  git -C "$md" add -A
  git -C "$md" commit -qm "demo step"
  git -C "$md" checkout -q main
}
reset_demo() { git -C "$md" branch -f sdlc/demo "$green"; }

req "REQ-TOUCH-017"
# Green and current: allowed, and the guard says nothing.
out="$tmproot/m-green.out"
mgate "$out" deny "git merge sdlc/demo"
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out"
assert_no_grep 'evidence-merge' "$out.err"
# none: the evidence removed by a commit on the branch.
on_demo git rm -q specs/demo/evidence.json
out="$tmproot/m-none.out"
mgate "$out" deny "git merge sdlc/demo"
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
assert_fgrep "sdlc-state.sh evidence demo" "$out.err"
assert_grep 'none' "$out.err"
reset_demo
# stale: a code commit on the branch after the evidence.
on_demo sh -c 'echo code > code.txt'
out="$tmproot/m-stale.out"
mgate "$out" deny "git merge sdlc/demo"
assert_rc 2 "$out"
assert_grep 'stale' "$out.err"
assert_fgrep "sdlc-state.sh evidence demo" "$out.err"
# Every spelling the design names, against the stale ref: all refused.
git -C "$md" branch -f sdlc/demo-T1 sdlc/demo
git -C "$md" update-ref refs/remotes/origin/sdlc/demo sdlc/demo
n=0
for c in "git merge --no-ff sdlc/demo -m x" "git merge sdlc/demo-T1" \
         "git pull origin sdlc/demo" "git rebase sdlc/demo" "git reset --hard sdlc/demo" \
         "git merge origin/sdlc/demo" "git merge refs/heads/sdlc/demo" \
         'git merge "sdlc/demo"' "git -C $md merge sdlc/demo" \
         "cd $md && git merge sdlc/demo"; do
  n=$((n + 1))
  out="$tmproot/m-spell-$n.out"
  mgate "$out" deny "$c"
  assert_rc 2 "$out"
  assert_fgrep "evidence-merge" "$out.err"
done
reset_demo
git -C "$md" branch -f sdlc/demo-T1 sdlc/demo
git -C "$md" update-ref -d refs/remotes/origin/sdlc/demo
# The task branch resolves to demo: green there is allowed.
out="$tmproot/m-task-green.out"
mgate "$out" deny "git merge sdlc/demo-T1"
assert_rc 0 "$out"
# Octopus: demo is green, other has no evidence — the merge is refused, naming other.
out="$tmproot/m-octopus.out"
mgate "$out" deny "git merge sdlc/demo sdlc/other"
assert_rc 2 "$out"
assert_fgrep "sdlc/other" "$out.err"
assert_fgrep "sdlc-state.sh evidence other" "$out.err"
# red: the evidence re-run with a failing test target, committed.
on_demo env MTEST_RC=1 bash scripts/sdlc-state.sh evidence demo
out="$tmproot/m-red.out"
mgate "$out" deny "git merge sdlc/demo"
assert_rc 2 "$out"
assert_grep 'red' "$out.err"
reset_demo
# invalid: evidence.json edited by hand and committed.
on_demo perl -0pi -e 's/"at": "[^"]*"/"at": "1999-01-01T00:00:00Z"/' specs/demo/evidence.json
if [ "$(git -C "$md" rev-parse sdlc/demo)" = "$green" ]; then
  _test_fail "the hand edit of evidence.json committed nothing"
fi
out="$tmproot/m-invalid.out"
mgate "$out" deny "git merge sdlc/demo"
assert_rc 2 "$out"
assert_grep 'invalid' "$out.err"
reset_demo
# Warn mode: allowed, one JSON document carrying the WARN, no permission
# decision, and the guard's log gained a line.
on_demo git rm -q specs/demo/evidence.json
mlog="$SDLC_GUARDS_DIR/evidence-merge.log"
before=0
[ -f "$mlog" ] && before=$(wc -l < "$mlog")
out="$tmproot/m-warn.out"
mgate "$out" warn "git merge sdlc/demo"
assert_rc 0 "$out"
jq -s 'length' "$out" > "$out.n" 2>/dev/null
assert_grep '^1$' "$out.n"
jq -r '.hookSpecificOutput.additionalContext' "$out" > "$out.ctx" 2>/dev/null
assert_grep '^WARN \(evidence-merge' "$out.ctx"
jq '[paths | map(tostring) | join(".")] | map(select(test("permissionDecision"))) | length' \
  "$out" > "$out.pd" 2>/dev/null
assert_grep '^0$' "$out.pd"
after=0
[ -f "$mlog" ] && after=$(wc -l < "$mlog")
if [ "$after" -eq $((before + 1)) ]; then
  _test_pass "evidence-merge.log gained one line"
else
  _test_fail "evidence-merge.log went from $before to $after lines, expected one more"
fi
# demo stays without evidence (none) for the cases below.

req "REQ-TOUCH-018"
# A ref that does not exist (and no such feature): refused, naming the ref.
out="$tmproot/m-nope.out"
mgate "$out" deny "git merge sdlc/nope"
assert_rc 2 "$out"
assert_fgrep "sdlc/nope" "$out.err"
assert_fgrep "evidence-merge" "$out.err"
# A ref that exists but resolves to no feature: refused, naming the ref.
out="$tmproot/m-zzz.out"
mgate "$out" deny "git merge sdlc/zzz"
assert_rc 2 "$out"
assert_fgrep "sdlc/zzz" "$out.err"
# A state script that cannot be found: refused, naming where it looked.
reset_demo
mv "$md/scripts/sdlc-state.sh" "$tmproot/m-state.away"
out="$tmproot/m-noscript.out"
mgate "$out" deny "git merge sdlc/demo"
assert_rc 2 "$out"
assert_fgrep "$(git -C "$md" rev-parse --show-toplevel)/scripts/sdlc-state.sh" "$out.err"
assert_fgrep "$mhome/.claude/scripts/sdlc-state.sh" "$out.err"
mv "$tmproot/m-state.away" "$md/scripts/sdlc-state.sh"
on_demo git rm -q specs/demo/evidence.json

req "REQ-TOUCH-048"
# The landing branch, not the starting one. HEAD is moved to sdlc/demo first,
# so a guard reading the current branch would not evaluate.
git -C "$md" checkout -q sdlc/demo
out="$tmproot/l-checkout-main.out"
mgate "$out" deny "git checkout main && git merge sdlc/demo"
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
out="$tmproot/l-switch-main.out"
mgate "$out" deny "git switch -q main; git merge sdlc/demo"
assert_rc 2 "$out"
# Landing on a feature branch is not the default branch: not guarded.
git -C "$md" checkout -q main
out="$tmproot/l-onfeature.out"
mgate "$out" deny "git checkout sdlc/demo && git merge sdlc/demo-T1"
assert_rc 0 "$out"
assert_no_grep '.' "$out"
assert_no_grep 'evidence-merge' "$out.err"
# A commit after `switch -c sdlc/demo-T9` lands there: the stamp guard runs
# on it — stamped, the commit path continues; unstamped, refused.
out="$tmproot/l-switchc.out"
mgate "$out" deny "git switch -c sdlc/demo-T9 && git commit -m x"
assert_rc 0 "$out"
mv "$md/specs/demo/state.json" "$tmproot/m-statejson.away"
out="$tmproot/l-switchc-unstamped.out"
mgate "$out" deny "git switch -c sdlc/demo-T9 && git commit -m x"
assert_rc 2 "$out"
assert_fgrep "gate1-stamp" "$out.err"
assert_fgrep "sdlc/demo-T9" "$out.err"
mv "$tmproot/m-statejson.away" "$md/specs/demo/state.json"
out="$tmproot/l-checkoutb.out"
mgate "$out" deny "git checkout -b sdlc/newthing && git commit -m x"
assert_rc 2 "$out"
assert_fgrep "sdlc/newthing" "$out.err"
# Quoted and flagged targets are followed too.
out="$tmproot/l-quoted.out"
mgate "$out" deny "git checkout -q -b 'sdlc/newthing' && git commit -m x"
assert_rc 2 "$out"
assert_fgrep "sdlc/newthing" "$out.err"
# From an unresolvable sdlc/ branch, a checkout of main lands the commit on
# main: no stamp guard.
git -C "$md" symbolic-ref HEAD refs/heads/sdlc/nothing-here
out="$tmproot/l-tomain.out"
mgate "$out" deny "git checkout main && git commit -m x"
assert_rc 0 "$out"
assert_no_grep 'gate1-stamp' "$out.err"
# `--` is a path checkout, not a branch change: the current branch is used,
# so the same commit is refused on sdlc/nothing-here.
out="$tmproot/l-pathco.out"
mgate "$out" deny "git checkout -- README.md && git commit -m x"
assert_rc 2 "$out"
assert_fgrep "sdlc/nothing-here" "$out.err"
git -C "$md" symbolic-ref HEAD refs/heads/main
# Targets the parser cannot read: refused in deny mode, warned in warn mode.
n=0
# shellcheck disable=SC2016  # the variable must reach the gate unexpanded
for c in 'git checkout $BR && git merge sdlc/demo' 'git checkout - && git merge sdlc/demo' \
         'git checkout @{-1} && git merge sdlc/demo' 'git checkout 0123abc && git merge sdlc/demo' \
         'git switch --detach main && git merge sdlc/demo' 'git checkout --bogus x && git merge sdlc/demo'; do
  n=$((n + 1))
  out="$tmproot/l-bad-$n.out"
  mgate "$out" deny "$c"
  assert_rc 2 "$out"
  assert_fgrep "evidence-merge" "$out.err"
  out="$tmproot/l-badwarn-$n.out"
  mgate "$out" warn "$c"
  assert_rc 0 "$out"
  assert_grep '^WARN \(evidence-merge' "$out.err"
done
out="$tmproot/l-bad-commit.out"
# shellcheck disable=SC2016  # literal: the gate must see it unexpanded
unread='$BR'
mgate "$out" deny "git checkout $unread && git commit -m x"
assert_rc 2 "$out"
assert_fgrep "gate1-stamp" "$out.err"
assert_fgrep "$unread" "$out.err"
# Default-branch resolution through origin/HEAD: with it pointing at trunk,
# trunk is guarded and main is not.
git -C "$md" branch trunk main
git clone -q --bare "$md" "$tmproot/m-bare.git"
git -C "$md" remote add origin "$tmproot/m-bare.git"
git -C "$md" fetch -q origin
git -C "$md" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
out="$tmproot/l-trunk.out"
mgate "$out" deny "git checkout trunk && git merge sdlc/demo"
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
out="$tmproot/l-main-not-default.out"
mgate "$out" deny "git checkout main && git merge sdlc/demo"
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"
git -C "$md" symbolic-ref -d refs/remotes/origin/HEAD

req "REQ-TOUCH-049"
# Nothing commit-shaped, merge-family naming sdlc/, or a branch change before
# one of those: untouched, no output at all — while demo has no evidence, so
# an evaluated guard would speak.
n=0
for c in "git log" "git merge --abort" "git merge feature-x" "git status" \
         "git rebase -i main" "git checkout \$BR" "git merge-base main sdlc/demo" \
         "$(printf 'cat > notes.txt <<EOF\ngit merge sdlc/demo\nEOF')"; do
  n=$((n + 1))
  out="$tmproot/u-$n.out"
  mgate "$out" deny "$c"
  assert_rc 0 "$out"
  assert_no_grep '.' "$out"
  assert_no_grep '.' "$out.err"
done

req "REQ-TOUCH-017"
# MUTATION (merge-family shape never matches): a copy of the gate whose
# merge-family words are replaced must let the evidence-less merge through.
# If the copy did not change, or still refuses, the refusals above prove
# nothing about the shape.
mut="$tmproot/mutant-merge"
mkdir -p "$mut"
cp "$md/hooks/guard-lib.sh" "$mut/guard-lib.sh"
sed 's/merge|pull|rebase|reset/nomatchxx/g' "$md/hooks/check-gate.sh" > "$mut/check-gate.sh"
if cmp -s "$mut/check-gate.sh" "$md/hooks/check-gate.sh"; then
  _test_fail "mutation: removing the merge-family shape changed nothing"
else
  _test_pass "mutation: the merge-family shape was removed"
fi
out="$tmproot/m-mutant.out"
mgate "$out" deny "git merge sdlc/demo" "$mut/check-gate.sh"
assert_rc 0 "$out"
out="$tmproot/m-unmutated.out"
mgate "$out" deny "git merge sdlc/demo"
assert_rc 2 "$out"

# --- fix batch A: fail-opens in the command parser --------------------------
# Each case below is one where the gate decided on the current branch, or saw
# no ref, where it should have followed the branch the command lands on or the
# ref it merges. Fixture state from here: sdlc/demo is STALE (a code commit
# after its evidence), `stale` is that commit, `green` the green one.
reset_demo
on_demo sh -c 'echo fixa > fixa.txt'
stale=$(git -C "$md" rev-parse sdlc/demo)
if [ "$stale" = "$green" ]; then
  _test_fail "the stale step on sdlc/demo committed nothing"
fi

req "REQ-TOUCH-048"
# Finding 1 (redirections counted as positional words): `git checkout main
# >/dev/null 2>&1` read as a path checkout of two positionals, the landing
# branch stayed the current one and the evidence guard never ran.
git -C "$md" symbolic-ref HEAD refs/heads/sdlc/demo-T1
n=0
for c in 'git checkout main >/dev/null 2>&1 && git merge sdlc/demo' \
         'git checkout main 2>/dev/null; git merge sdlc/demo' \
         'git checkout main > /dev/null && git merge sdlc/demo' \
         'git checkout main &>/dev/null && git merge sdlc/demo' \
         'git checkout main >|/dev/null && git merge sdlc/demo >/dev/null'; do
  n=$((n + 1))
  out="$tmproot/fa-redir-$n.out"
  mgate "$out" deny "$c"
  assert_rc 2 "$out"
  assert_fgrep "evidence-merge" "$out.err"
done
# A redirected checkout of main from an unresolvable sdlc/ branch lands the
# commit on main: no stamp guard.
git -C "$md" symbolic-ref HEAD refs/heads/sdlc/nothing-here
out="$tmproot/fa-redir-commit.out"
mgate "$out" deny 'git checkout main 2>/dev/null && git commit -m x'
assert_rc 0 "$out"
assert_no_grep 'gate1-stamp' "$out.err"
# MUTATION (finding 1): a copy of the gate with the redirection strip removed
# must let the redirect spelling through; the test fails if the sed changed
# nothing.
git -C "$md" symbolic-ref HEAD refs/heads/sdlc/demo-T1
mut1="$tmproot/mutant-redir"
mkdir -p "$mut1"
cp "$md/hooks/guard-lib.sh" "$mut1/guard-lib.sh"
sed '/# redirection: dropped with its target/d' "$md/hooks/check-gate.sh" > "$mut1/check-gate.sh"
if cmp -s "$mut1/check-gate.sh" "$md/hooks/check-gate.sh"; then
  _test_fail "mutation: removing the redirection strip changed nothing"
else
  _test_pass "mutation: the redirection strip was removed"
fi
out="$tmproot/fa-redir-mutant.out"
mgate "$out" deny 'git checkout main >/dev/null 2>&1 && git merge sdlc/demo' "$mut1/check-gate.sh"
assert_rc 0 "$out"
out="$tmproot/fa-redir-unmutated.out"
mgate "$out" deny 'git checkout main >/dev/null 2>&1 && git merge sdlc/demo'
assert_rc 2 "$out"

# Finding 2 (`git checkout <branch> --` with nothing after `--` read as a path
# checkout): git switches branch there.
git -C "$md" symbolic-ref HEAD refs/heads/main
out="$tmproot/fa-dd-commit.out"
mgate "$out" deny 'git checkout sdlc/zzz -- && git commit -m x'
assert_rc 2 "$out"
assert_fgrep "gate1-stamp" "$out.err"
assert_fgrep "sdlc/zzz" "$out.err"
# A pathspec after `--` is still a path checkout: the commit stays on main.
out="$tmproot/fa-dd-path.out"
mgate "$out" deny 'git checkout sdlc/zzz -- README.md && git commit -m x'
assert_rc 0 "$out"
assert_no_grep 'gate1-stamp' "$out.err"
git -C "$md" symbolic-ref HEAD refs/heads/sdlc/demo
out="$tmproot/fa-dd-merge.out"
mgate "$out" deny 'git checkout main -- && git merge sdlc/demo'
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"

# Finding 3 (two-word global options before the subcommand were not matched).
git -C "$md" symbolic-ref HEAD refs/heads/main
n=0
for c in 'git --git-dir .git merge sdlc/demo' 'git --namespace x merge sdlc/demo' \
         'git --git-dir ".git" --work-tree . merge sdlc/demo'; do
  n=$((n + 1))
  out="$tmproot/fa-gopt-$n.out"
  mgate "$out" deny "$c"
  assert_rc 2 "$out"
  assert_fgrep "evidence-merge" "$out.err"
done
git -C "$md" symbolic-ref HEAD refs/heads/sdlc/demo
out="$tmproot/fa-gopt-checkout.out"
mgate "$out" deny 'git --work-tree . checkout main && git merge sdlc/demo'
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"

# Finding 4 (`-t`/`--track` lands on the target with its remote stripped, but
# was read as a plain checkout of a branch that does not exist).
git -C "$md" symbolic-ref HEAD refs/heads/main
n=0
for c in 'git checkout -t origin/sdlc/nospec && git commit -m x' \
         'git switch -t origin/sdlc/nospec && git commit -m x' \
         'git checkout --track origin/sdlc/nospec && git commit -m x' \
         'git switch --track=direct refs/remotes/origin/sdlc/nospec && git commit -m x'; do
  n=$((n + 1))
  out="$tmproot/fa-track-$n.out"
  mgate "$out" deny "$c"
  assert_rc 2 "$out"
  assert_fgrep "gate1-stamp" "$out.err"
  assert_fgrep "sdlc/nospec" "$out.err"
done
# A --track target without a remote prefix names no branch: unreadable.
out="$tmproot/fa-track-bad.out"
mgate "$out" deny 'git checkout --track nobranch && git commit -m x'
assert_rc 2 "$out"
assert_fgrep "gate1-stamp" "$out.err"
assert_fgrep "nobranch" "$out.err"
# Tracking a stamped feature: the commit path continues.
out="$tmproot/fa-track-demo.out"
mgate "$out" deny 'git checkout -t origin/sdlc/demo && git commit -m x'
assert_rc 0 "$out"
assert_no_grep 'gate1-stamp' "$out.err"

# Finding 5a (only the first commit was anchored): a second commit after a
# checkout lands elsewhere and is stamp-checked too.
out="$tmproot/fa-twocommits.out"
mgate "$out" deny 'git commit -m a && git checkout sdlc/zzz && git commit -m b'
assert_rc 2 "$out"
assert_fgrep "gate1-stamp" "$out.err"
assert_fgrep "sdlc/zzz" "$out.err"

req "REQ-TOUCH-017"
# Finding 6 (`git rebase <upstream> <branch>` checks out <branch> first): on a
# task branch, rebasing main onto the stale feature lands on main.
git -C "$md" branch -f sdlc/demo-T3 main
git -C "$md" symbolic-ref HEAD refs/heads/sdlc/demo-T3
out="$tmproot/fa-rebase2.out"
mgate "$out" deny 'git rebase sdlc/demo main'
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
# shellcheck disable=SC2016  # the variable must reach the gate unexpanded
mgate "$tmproot/fa-rebase-bad.out" deny 'git rebase sdlc/demo $BR'
assert_rc 2 "$tmproot/fa-rebase-bad.out"
assert_fgrep "evidence-merge" "$tmproot/fa-rebase-bad.out.err"
# Rebasing the feature onto main lands on the feature: not guarded.
out="$tmproot/fa-rebase-feature.out"
mgate "$out" deny 'git rebase main sdlc/demo'
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"
git -C "$md" symbolic-ref HEAD refs/heads/main

# From here sdlc/demo is green again.
reset_demo

req "REQ-TOUCH-018"
# Finding 7 (`git pull <remote> sdlc/x` read the LOCAL branch): the guard reads
# the remote-tracking branch the pull merges.
git -C "$md" update-ref refs/remotes/origin/sdlc/demo "$stale"
out="$tmproot/fa-pull-stale.out"
mgate "$out" deny 'git pull origin sdlc/demo'
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
assert_fgrep "origin/sdlc/demo" "$out.err"
assert_grep 'stale' "$out.err"
git -C "$md" update-ref refs/remotes/origin/sdlc/demo "$green"
out="$tmproot/fa-pull-green.out"
mgate "$out" deny 'git pull --no-rebase origin sdlc/demo'
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"
git -C "$md" update-ref -d refs/remotes/origin/sdlc/demo
out="$tmproot/fa-pull-none.out"
mgate "$out" deny 'git pull origin sdlc/demo'
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
assert_fgrep "origin/sdlc/demo" "$out.err"

req "REQ-TOUCH-017"
# Finding 8 (option values scanned as refs): the -m message is not a ref, so a
# green merge with a message naming sdlc/ is allowed and the guard is silent.
out="$tmproot/fa-msg.out"
mgate "$out" deny 'git merge --no-ff -m "sdlc/foo landed" sdlc/demo'
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"
assert_no_grep 'evidence-merge' "$out"
# A rebase's --onto value is still a ref it brings in: not skipped.
out="$tmproot/fa-onto.out"
mgate "$out" deny 'git rebase --onto sdlc/nope main main'
assert_rc 2 "$out"
assert_fgrep "sdlc/nope" "$out.err"

req "REQ-TOUCH-048"
# Finding 5b (several git commands in different directories were evaluated in
# one repository): a second repository whose sdlc/demo is stale, merged after
# a green merge in the fixture, is refused for changing directory.
od="$tmproot/other-repo"
git clone -q "$md" "$od"
git -C "$od" config user.name "SDLC Test"
git -C "$od" config user.email "sdlc-test@example.invalid"
git -C "$od" checkout -q -b sdlc/demo origin/sdlc/demo
echo other > "$od/other.txt"
git -C "$od" add -A
git -C "$od" commit -qm "stale in the other repo"
git -C "$od" checkout -q main
out="$tmproot/fa-twodirs.out"
mgate "$out" deny "cd $md && git merge sdlc/demo; cd $od && git merge sdlc/demo"
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
assert_fgrep "changes directory" "$out.err"
out="$tmproot/fa-twodirs-C.out"
mgate "$out" deny "git -C $md merge sdlc/demo; git -C $od merge sdlc/demo"
assert_rc 2 "$out"
assert_fgrep "changes directory" "$out.err"
out="$tmproot/fa-twodirs-commit.out"
mgate "$out" deny "cd $md && git commit -m a; cd $od && git commit -m b"
assert_rc 2 "$out"
assert_fgrep "gate1-stamp" "$out.err"
assert_fgrep "changes directory" "$out.err"
# One directory for the whole command stays as it was.
out="$tmproot/fa-onedir.out"
mgate "$out" deny "cd $md && git merge sdlc/demo"
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"

# --- fix batch D: option words the parser does not know ---------------------
# An option the parser does not know may take a separate value and shift the
# positionals, so the parse of a rebase's landing branch, or of a pull's
# remote, cannot be trusted. Fixture state: sdlc/demo STALE again.
git -C "$md" branch -f sdlc/demo "$stale"

req "REQ-TOUCH-017"
req "REQ-TOUCH-048"
# Finding D1: `git rebase --unknown-opt x sdlc/demo main` saw three
# positionals, skipped the <branch> override and decided on the task branch.
git -C "$md" symbolic-ref HEAD refs/heads/sdlc/demo-T3
n=0
for c in 'git rebase --unknown-opt x sdlc/demo main' \
         'git rebase --unknown-opt=y sdlc/demo refs/heads/main' \
         'git rebase --unknown-opt sdlc/demo main'; do
  n=$((n + 1))
  out="$tmproot/fd-rebase-unk-$n.out"
  mgate "$out" deny "$c"
  assert_rc 2 "$out"
  assert_fgrep "evidence-merge" "$out.err"
  assert_fgrep "--unknown-opt" "$out.err"
done
# A known option without a value keeps the two-positional parse: guarded.
out="$tmproot/fd-rebase-i.out"
mgate "$out" deny 'git rebase -i sdlc/demo main'
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
# Known options with a separate value are skipped with it: still guarded.
out="$tmproot/fd-rebase-x.out"
mgate "$out" deny 'git rebase -X ours --autostash sdlc/demo main'
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
# The unchanged cases stay as they were.
out="$tmproot/fd-rebase-plain.out"
mgate "$out" deny 'git rebase sdlc/demo main'
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
out="$tmproot/fd-rebase-feature.out"
mgate "$out" deny 'git rebase main sdlc/demo'
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"
# An unknown option on a rebase that names no default branch, from a task
# branch, lands nowhere near it: not this guard's business.
out="$tmproot/fd-rebase-unk-task.out"
mgate "$out" deny 'git rebase --unknown-opt x sdlc/demo sdlc/demo-T3'
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"
# From the default branch itself an unknown option is refused whatever the
# positionals name.
git -C "$md" symbolic-ref HEAD refs/heads/main
out="$tmproot/fd-rebase-unk-main.out"
mgate "$out" deny 'git rebase --unknown-opt x main sdlc/demo'
assert_rc 2 "$out"
assert_fgrep "--unknown-opt" "$out.err"
git -C "$md" symbolic-ref HEAD refs/heads/sdlc/demo-T3
# MUTATION (finding D1): a copy of the gate without the "any positional names
# the default branch" clause lets the unknown-option rebase through; the test
# fails if the sed changed nothing.
mutd="$tmproot/mutant-rebase-pos"
mkdir -p "$mutd"
cp "$md/hooks/guard-lib.sh" "$mutd/guard-lib.sh"
sed '/# any positional names the default branch/d' "$md/hooks/check-gate.sh" > "$mutd/check-gate.sh"
if cmp -s "$mutd/check-gate.sh" "$md/hooks/check-gate.sh"; then
  _test_fail "mutation: removing the any-positional clause changed nothing"
else
  _test_pass "mutation: the any-positional clause was removed"
fi
out="$tmproot/fd-rebase-mutant.out"
mgate "$out" deny 'git rebase --unknown-opt x sdlc/demo main' "$mutd/check-gate.sh"
assert_rc 0 "$out"
out="$tmproot/fd-rebase-unmutated.out"
mgate "$out" deny 'git rebase --unknown-opt x sdlc/demo main'
assert_rc 2 "$out"
git -C "$md" symbolic-ref HEAD refs/heads/main

req "REQ-TOUCH-017"
# Finding D2: `git pull <remote> <ref>` took the first positional as the
# remote; an unknown option's value could stand there. Refused by name,
# whatever the words after it are.
reset_demo
git -C "$md" update-ref refs/remotes/origin/sdlc/demo "$green"
out="$tmproot/fd-pull-unk.out"
mgate "$out" deny 'git pull --unknown-opt x origin sdlc/demo'
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
assert_fgrep "--unknown-opt" "$out.err"
out="$tmproot/fd-pull-unk2.out"
mgate "$out" deny 'git pull --unknown-opt origin origin sdlc/demo'
assert_rc 2 "$out"
assert_fgrep "--unknown-opt" "$out.err"
out="$tmproot/fd-pull-unk-warn.out"
mgate "$out" warn 'git pull --unknown-opt x origin sdlc/demo'
assert_rc 0 "$out"
assert_grep 'WARN \(evidence-merge' "$out"
assert_fgrep "--unknown-opt" "$out"
# Known options, with and without a value, keep the green pull allowed.
out="$tmproot/fd-pull-known.out"
mgate "$out" deny 'git pull --no-rebase --ff-only -X ours --depth 3 origin sdlc/demo'
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"
git -C "$md" update-ref -d refs/remotes/origin/sdlc/demo

finish
