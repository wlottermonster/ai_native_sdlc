#!/bin/bash
# AI-Native SDLC — commit-gate fail-opens, second round (specs/gate-fail-open-2).
# Every assertion below carries its REQ-ID literally, so requirement coverage
# stays grep-able.
#
#   REQ-GATE-014  the docs-only shortcut is taken only when the command cannot
#                 change what the commit contains: any other git invocation in
#                 the command, a commit pathspec, or a staging option (-a,
#                 --all, -i, --include, -o, --only, -p) runs the full check.
#   REQ-GATE-015  any non-zero exit from the requirement gate BLOCKS the commit
#                 with exit 2, never passing its exit 1 through as an allow.
#   REQ-GATE-016  a requirement gate that cannot be found BLOCKS the commit.
#   REQ-GATE-017  a docs-only commit skips `make check` but still runs the
#                 requirement gate.
#
# Each guard is proven by mutation: a fixture that passes clean, the fault
# planted, the gate observed to block. The fixture's `make check` appends the
# repo's name to a witness file, so whether the checks ran is observed, not
# inferred. HOME points at throwaway directories; nothing real is read.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-failopen.XXXXXX")
tmproot=$(cd "$tmproot" && pwd)
# shellcheck disable=SC2329  # invoked indirectly by the trap below
# Some fixtures make specs/ unreadable on purpose; modes go back before removal.
cleanup() { chmod -R u+rwx "$tmproot" 2>/dev/null || true; rm -rf "$tmproot"; }
trap cleanup EXIT

gate="$repo/hooks/check-gate.sh"
witness="$tmproot/witness"

# rhome: a HOME whose ~/.claude/hooks carries the requirement gate, the way
# install.sh leaves it. bare: a HOME with no ~/.claude at all.
rhome=$(mktemp -d "$tmproot/rhome.XXXXXX")
mkdir -p "$rhome/.claude/hooks"
cp "$repo/hooks/req-gate.sh" "$rhome/.claude/hooks/req-gate.sh"
bare=$(mktemp -d "$tmproot/bare.XXXXXX")

# gate_repo <dir> <check-exit> — a throwaway git repo with a tracked src.py
# whose `make check` records the repo's name in $witness, then exits as told.
gate_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.name "SDLC Test"
  git -C "$1" config user.email "sdlc-test@example.invalid"
  printf 'check:\n\t@echo %s >> %s; exit %s\n' "$(basename "$1")" "$witness" "$2" > "$1/Makefile"
  echo x > "$1/src.py"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

payload() {
  jq -n --arg c "$1" --arg cwd "$2" '{tool_input:{command:$c},cwd:$cwd}'
}

# run_gate <outfile> <home> <payload-json>
run_gate() {
  local rc=0
  : > "$witness"
  printf '%s' "$3" | HOME="$2" bash "$gate" > "$1" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$1.rc"
}

# The fixture requirement ID is assembled at run time: a literal here would be
# reported as an orphan by the requirement gate's drift check.
demo_feat=DEMO
demo_id="REQ-${demo_feat}-001"

# ===========================================================================
req "REQ-GATE-014"
# One repo, checks FAIL, a prose file already staged and a code file edited in
# the work tree. The staged set is docs-only; the commit each command makes is
# not.
docs="$tmproot/docs"
gate_repo "$docs" 1
echo note > "$docs/notes.md"
git -C "$docs" add notes.md
echo changed > "$docs/src.py"
echo new > "$docs/code.py"

# The clean control first: a bare commit of the staged prose skips the checks.
# The command texts are data for the gate, never expanded here.
n=0
# shellcheck disable=SC2016
for shape in \
  'git commit -m x' \
  'git commit -q -s -m "docs: a note"' \
  "cd $docs && git commit -m x" \
  "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\ndocs: a note\n\nwith a body\nEOF\n)"')" \
  "$(printf 'git commit -F - <<'"'"'EOF'"'"'\ndocs: a note\nEOF\n')"
do
  n=$((n + 1))
  out="$tmproot/docs-ok-$n.out"
  run_gate "$out" "$rhome" "$(payload "$shape" "$docs")"
  assert_rc 0 "$out"
  assert_no_grep '.' "$witness"
done

# The mutation: each command below changes what the commit contains, so the
# docs-only answer read from the index would be a lie. Every one must run the
# failing check and block.
n=0
# shellcheck disable=SC2016
for shape in \
  'git add code.py && git commit -m x' \
  'git add -A; git commit -m x' \
  "$(printf 'git add src.py\ngit commit -m x')" \
  'git stage src.py && git commit -m x' \
  'git rm -q src.py && git commit -m x' \
  'git mv src.py lib.py && git commit -m x' \
  'git commit -am x' \
  'git commit -a -m x' \
  'git commit --all -m x' \
  'git commit -m x -a' \
  'git commit src.py -m x' \
  'git commit -m x src.py' \
  'git commit -m x -- src.py' \
  'git commit --include src.py -m x' \
  'git commit -i -m x src.py' \
  'git commit --only -m x src.py' \
  'git commit -o -m x src.py' \
  'git commit -p -m x' \
  'git commit --interactive' \
  'git commit --pathspec-from-file=list -m x' \
  'GIT_INDEX_FILE=/tmp/other-index git commit -m x' \
  'git commit -m "$(git add src.py; echo msg)"' \
  'git commit -m "unterminated' \
  'git commit --no-such-option -m x'
do
  n=$((n + 1))
  out="$tmproot/docs-bad-$n.out"
  run_gate "$out" "$rhome" "$(payload "$shape" "$docs")"
  assert_rc 2 "$out"
  assert_fgrep 'COMMIT BLOCKED' "$out"
  assert_grep '^docs$' "$witness"
done

# ===========================================================================
req "REQ-GATE-015"
# Checks PASS; the requirement gate cannot read specs/ and exits 1. That exit
# means "coverage was not checked" — the commit gate must turn it into a block.
unread="$tmproot/unread"
gate_repo "$unread" 0
mkdir -p "$unread/specs/demo"
printf '# demo\n\n%s  THE SYSTEM SHALL do the demo thing.\n  verify: unit\n' "$demo_id" \
  > "$unread/specs/demo/requirements.md"
printf '# demo\n\n- [ ] T1: the demo thing    [%s]\n' "$demo_id" > "$unread/specs/demo/tasks.md"
echo changed > "$unread/src.py"
git -C "$unread" add -A
# Clean control: readable specs, green checks → allowed after the checks ran.
out="$tmproot/unread-ok.out"
run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$unread")"
assert_rc 0 "$out"
assert_grep '^unread$' "$witness"
# The fault: specs/ unreadable.
chmod 000 "$unread/specs"
out="$tmproot/unread-bad.out"
run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$unread")"
chmod 755 "$unread/specs"
assert_rc 2 "$out"
assert_fgrep 'COMMIT BLOCKED' "$out"
# ...and the requirement gate's own reason reaches the reader.
assert_fgrep 'specs/ exists but is not readable' "$out"

# ===========================================================================
req "REQ-GATE-016"
# Checks PASS, and no requirement gate exists anywhere: not in the repo, not
# under the HOME the gate runs with. Coverage cannot be checked, so the commit
# is refused and the reader is told how to fix it.
nogate="$tmproot/nogate"
gate_repo "$nogate" 0
echo changed > "$nogate/src.py"
git -C "$nogate" add -A
# Clean control: the same repo under a HOME that has the gate installed.
out="$tmproot/nogate-ok.out"
run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$nogate")"
assert_rc 0 "$out"
# The fault: nothing installed.
out="$tmproot/nogate-bad.out"
run_gate "$out" "$bare" "$(payload 'git commit -m x' "$nogate")"
assert_rc 2 "$out"
assert_fgrep 'COMMIT BLOCKED' "$out"
assert_fgrep 'install.sh' "$out"
# The docs-only path looks for the gate too, and refuses the same way.
git -C "$nogate" reset -q
git -C "$nogate" checkout -q -- src.py
echo note > "$nogate/notes.md"
git -C "$nogate" add notes.md
out="$tmproot/nogate-docs.out"
run_gate "$out" "$bare" "$(payload 'git commit -m x' "$nogate")"
assert_rc 2 "$out"
assert_fgrep 'COMMIT BLOCKED' "$out"
assert_fgrep 'install.sh' "$out"

# ===========================================================================
req "REQ-GATE-017"
# A docs-only commit that CLAIMS completion: the requirement is not in the task
# list. `make check` FAILS in this repo, so if make ran the witness shows it.
claim="$tmproot/claim"
gate_repo "$claim" 1
mkdir -p "$claim/specs/demo"
printf '# demo\n\n%s  THE SYSTEM SHALL do the demo thing.\n  verify: unit\n' "$demo_id" \
  > "$claim/specs/demo/requirements.md"
printf '# demo\n\n- [ ] T1: the demo thing    [%s]\n' "$demo_id" > "$claim/specs/demo/tasks.md"
git -C "$claim" add -A
git -C "$claim" commit -qm spec
# Clean control: a prose edit that keeps coverage (Gate A holds; Gate B is out
# of the way because the one box is still open) → allowed, and make never ran.
printf '# demo\n\n- [ ] T1: the demo thing    [%s]\n\nA note.\n' "$demo_id" > "$claim/specs/demo/tasks.md"
git -C "$claim" add specs/demo/tasks.md
out="$tmproot/claim-ok.out"
run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$claim")"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"
# The fault, Gate A: the task list drops the requirement.
printf '# demo\n\n- [ ] T1: the demo thing\n' > "$claim/specs/demo/tasks.md"
git -C "$claim" add specs/demo/tasks.md
out="$tmproot/claim-gatea.out"
run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$claim")"
assert_rc 2 "$out"
assert_fgrep 'COMMIT BLOCKED' "$out"
assert_fgrep 'GATE A' "$out"
assert_no_grep '.' "$witness"
# The fault, Gate B: ticking the last box claims completion with no test.
printf '# demo\n\n- [x] T1: the demo thing    [%s]\n' "$demo_id" > "$claim/specs/demo/tasks.md"
git -C "$claim" add specs/demo/tasks.md
out="$tmproot/claim-gateb.out"
run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$claim")"
assert_rc 2 "$out"
assert_fgrep 'COMMIT BLOCKED' "$out"
assert_fgrep 'GATE B' "$out"
assert_no_grep '.' "$witness"
# The fault, unreadable specs/ on the docs-only path: exit 1 becomes a block.
chmod 000 "$claim/specs"
out="$tmproot/claim-unread.out"
run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$claim")"
chmod 755 "$claim/specs"
assert_rc 2 "$out"
assert_fgrep 'COMMIT BLOCKED' "$out"
assert_no_grep '.' "$witness"

# ===========================================================================
req "REQ-GATE-019"
# Sibling of REQ-GATE-015: the requirement gate itself read an unreadable
# requirements.md, or a feature directory it cannot enter, as "no IDs here" and
# passed. The fixture's coverage FAILS readably (a requirement with no task),
# so a gate that stops reading shows up as a pass.
rgate="$repo/hooks/req-gate.sh"
cov="$tmproot/cov"
gate_repo "$cov" 0
mkdir -p "$cov/specs/demo"
printf '# demo\n\n%s  THE SYSTEM SHALL do the demo thing.\n  verify: unit\n' "$demo_id" \
  > "$cov/specs/demo/requirements.md"
printf '# demo\n\n- [ ] T1: the demo thing\n' > "$cov/specs/demo/tasks.md"
# run_req <outfile> — the requirement gate in enforce mode, inside the fixture.
run_req() {
  local rc=0
  ( cd "$cov" && bash "$rgate" < /dev/null ) > "$1" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$1.rc"
}
# Clean control: readable, and the missing task is found.
out="$tmproot/cov-readable.out"
run_req "$out"
assert_rc 2 "$out"
assert_fgrep 'GATE A' "$out"
# The fault: requirements.md unreadable. Never a pass.
chmod 000 "$cov/specs/demo/requirements.md"
out="$tmproot/cov-unread-req.out"
run_req "$out"
chmod 644 "$cov/specs/demo/requirements.md"
assert_rc 1 "$out"
assert_fgrep 'coverage was not checked' "$out"
assert_fgrep 'specs/demo/requirements.md' "$out"
# The fault: the feature directory cannot be entered.
chmod 000 "$cov/specs/demo"
out="$tmproot/cov-unread-dir.out"
run_req "$out"
chmod 755 "$cov/specs/demo"
assert_rc 1 "$out"
assert_fgrep 'coverage was not checked' "$out"
assert_fgrep 'specs/demo' "$out"
# ...and specs/ readable but not searchable hides every file below it.
chmod 644 "$cov/specs"
out="$tmproot/cov-noexec-specs.out"
run_req "$out"
chmod 755 "$cov/specs"
assert_rc 1 "$out"
# At commit time the same condition is a block.
echo changed > "$cov/src.py"
git -C "$cov" add src.py
chmod 000 "$cov/specs/demo/requirements.md"
out="$tmproot/cov-commit.out"
run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$cov")"
chmod 644 "$cov/specs/demo/requirements.md"
assert_rc 2 "$out"
assert_fgrep 'COMMIT BLOCKED' "$out"

# ===========================================================================
req "REQ-GATE-020"
# Sibling of the unreadable-Makefile refusal: a package.json the gate cannot
# read was taken for "no check contract" and the commit allowed. The fixture
# has no Makefile, and its npm check fails.
npmr="$tmproot/npmr"
mkdir -p "$npmr"
git -C "$npmr" init -q
git -C "$npmr" config user.name "SDLC Test"
git -C "$npmr" config user.email "sdlc-test@example.invalid"
printf '{"name":"npmr","private":true,"scripts":{"check":"echo npmr >> %s; exit 1"}}\n' "$witness" \
  > "$npmr/package.json"
echo x > "$npmr/src.js"
git -C "$npmr" add -A
git -C "$npmr" commit -qm init
echo changed > "$npmr/src.js"
git -C "$npmr" add src.js
if command -v npm >/dev/null 2>&1; then
  # Clean control: readable, the npm check runs and fails → blocked.
  out="$tmproot/npmr-readable.out"
  run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$npmr")"
  assert_rc 2 "$out"
  assert_grep '^npmr$' "$witness"
fi
# The fault: package.json unreadable. The gate cannot tell what the contract
# is, so it refuses in its own words.
chmod 000 "$npmr/package.json"
out="$tmproot/npmr-unread.out"
run_gate "$out" "$rhome" "$(payload 'git commit -m x' "$npmr")"
chmod 644 "$npmr/package.json"
assert_rc 2 "$out"
assert_fgrep 'read package.json' "$out"

finish
