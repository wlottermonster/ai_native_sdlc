#!/bin/bash
# AI-Native SDLC — tests for scripts/sdlc-state.sh, the one owner of a
# feature's state.json: `init`, `stamp`, the digest, stale detection, the
# `stamp-state` reader, `status`, and the atomic write.
#
# Every fixture is a throwaway git repository under mktemp -d, removed on
# exit; nothing here reads or writes the real $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

S="$TEST_REPO/scripts/sdlc-state.sh"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-state.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
# The REQ-TOUCH-009 fixture makes a directory read-only, so the modes are put
# back before the tree is removed.
cleanup() { chmod -R u+rwx "$tmproot" 2>/dev/null || true; rm -rf "$tmproot"; }
trap cleanup EXIT

# Never let git discovery climb out of the temp root (the no-repo case).
export GIT_CEILING_DIRECTORIES="$tmproot"

# Demo IDs assembled at run time: req-gate's orphan check scans test files
# for REQ-shaped tokens.
demo_feat=DEMO
id1="REQ-${demo_feat}-001"
id2="REQ-${demo_feat}-002"
id3="REQ-${demo_feat}-003"
id4="REQ-${demo_feat}-004"

# st <dir> <args...> — run the script with <dir> as the working directory.
st() { local dir="$1"; shift; (cd "$dir" && bash "$S" "$@"); }

# digest_of <file> — the digest as the design defines it.
digest_of() { jq -cS 'del(.digest)' "$1" | shasum -a 256 | cut -d' ' -f1; }

# sha_of <file>
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# check <name> <shell-condition...> — a pass/fail on an arbitrary test.
check() {
  local name="$1"; shift
  if "$@"; then _test_pass "$name"; else _test_fail "$name"; fi
}

# new_repo — a git repo with specs/demo/{requirements,tasks}.md.
new_repo() {
  local d
  d=$(mktemp -d "$tmproot/repo.XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.name "SDLC Test"
  git -C "$d" config user.email "sdlc-test@example.invalid"
  mkdir -p "$d/specs/demo" "$d/specs/_shipped/old"
  cat > "$d/specs/demo/requirements.md" <<EOF
# Requirements — demo

$id1  WHEN a thing happens THE SYSTEM SHALL do it.
              verify: unit

$id2  WHEN another thing happens THE SYSTEM SHALL do that.
              verify: integration

$id3  WHEN a third thing happens THE SYSTEM SHALL wait.
EOF
  cat > "$d/specs/demo/tasks.md" <<EOF
# Tasks — demo
- [x] T1: one [$id1]
- [x] T2: two [$id2]
- [~] T3: three [$id3]
- [ ] T4: four
- [!] T5: five
EOF
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
req "REQ-TOUCH-001"
d=$(new_repo)
f="$d/specs/demo/state.json"
capture "$tmproot/init.out" st "$d" init demo
assert_rc 0 "$tmproot/init.out"
assert_file "$f"
check "schema 1, feature demo" test "$(jq -r '"\(.schema) \(.feature)"' "$f" 2>/dev/null)" = "1 demo"
check "every ID listed, in file order" test "$(jq -r '.requirements | keys_unsorted | join(",")' "$f" 2>/dev/null)" = "$id1,$id2,$id3"
check "tiers read from each block (default unit)" test "$(jq -r '[.requirements[] | .verify] | join(",")' "$f" 2>/dev/null)" = "unit,integration,unit"
check "every passes is false" test "$(jq -r '[.requirements[] | .passes] | unique | join(",")' "$f" 2>/dev/null)" = "false"
check "no Gate 1 stamp" test "$(jq -c '.gate1' "$f" 2>/dev/null)" = '{"approved_at":null,"spec_sha":null}'
check "created_at is an ISO time" test -n "$(jq -r '.created_at | select(test("^[0-9-]+T[0-9:]+Z$"))' "$f" 2>/dev/null)"
check "digest matches the body" test "$(jq -r '.digest' "$f" 2>/dev/null)" = "$(digest_of "$f")"
capture "$tmproot/ss0.out" st "$d" stamp-state demo
assert_fgrep "none" "$tmproot/ss0.out"
assert_rc 1 "$tmproot/ss0.out"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-002"
d=$(new_repo)
f="$d/specs/demo/state.json"
st "$d" init demo >/dev/null 2>&1
st "$d" stamp demo >/dev/null 2>&1
# A hand edit: passes flipped, digest not recomputed.
jq --arg id "$id1" '.requirements[$id].passes = true' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
before=$(sha_of "$f")
capture "$tmproot/ss2.out" st "$d" stamp-state demo
assert_grep "^invalid .*specs/demo/state.json" "$tmproot/ss2.out"
assert_fgrep "digest mismatch" "$tmproot/ss2.out"
assert_rc 1 "$tmproot/ss2.out"
capture "$tmproot/stamp2.out" st "$d" stamp demo
assert_rc nonzero "$tmproot/stamp2.out"
assert_fgrep "specs/demo/state.json" "$tmproot/stamp2.out"
check "stamp left the edited file byte-identical" test "$(sha_of "$f")" = "$before"
# A truncated file is invalid too, never a stamp.
head -c 40 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
capture "$tmproot/ss2b.out" st "$d" stamp-state demo
assert_grep "^invalid .*specs/demo/state.json" "$tmproot/ss2b.out"
assert_rc 1 "$tmproot/ss2b.out"
capture "$tmproot/status2.out" st "$d" status
assert_grep "^demo stamp=invalid " "$tmproot/status2.out"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-003"
d=$(new_repo)
f="$d/specs/demo/state.json"
st "$d" init demo >/dev/null 2>&1
# A requirement added after init, and a passes set to true by a proper rewrite
# (digest recomputed), which the stamp must keep.
printf '\n%s  WHEN a fourth thing happens THE SYSTEM SHALL act.\n              verify: deferred\n' "$id4" >> "$d/specs/demo/requirements.md"
jq --arg id "$id2" '.requirements[$id].passes = true' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
jq --arg dg "$(digest_of "$f")" '.digest = $dg' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
spec=$(sha_of "$d/specs/demo/requirements.md")
capture "$tmproot/stamp3.out" st "$d" stamp demo
assert_rc 0 "$tmproot/stamp3.out"
check "approved_at set" test -n "$(jq -r '.gate1.approved_at | select(test("^[0-9-]+T[0-9:]+Z$"))' "$f" 2>/dev/null)"
check "spec_sha is sha256 of requirements.md" test "$(jq -r '.gate1.spec_sha' "$f" 2>/dev/null)" = "$spec"
check "new ID added with passes false and its tier" test "$(jq -c --arg id "$id4" '.requirements[$id]' "$f" 2>/dev/null)" = '{"passes":false,"verify":"deferred"}'
check "existing true passes preserved" test "$(jq -r --arg id "$id2" '.requirements[$id].passes' "$f" 2>/dev/null)" = "true"
check "existing false passes preserved" test "$(jq -r --arg id "$id1" '.requirements[$id].passes' "$f" 2>/dev/null)" = "false"
check "stamp writes no other passes true" test "$(jq '[.requirements[] | select(.passes == true)] | length' "$f" 2>/dev/null)" = "1"
check "digest recomputed" test "$(jq -r '.digest' "$f" 2>/dev/null)" = "$(digest_of "$f")"
capture "$tmproot/ss3.out" st "$d" stamp-state demo
assert_grep "^ok [0-9-]+T[0-9:]+Z$" "$tmproot/ss3.out"
assert_rc 0 "$tmproot/ss3.out"
req "REQ-TOUCH-053"
assert_grep "demo" "$tmproot/stamp3.out"
assert_grep "requirements: 4" "$tmproot/stamp3.out"
assert_fgrep "$spec" "$tmproot/stamp3.out"
# The print comes first: proven below (REQ-TOUCH-009) where the write fails
# and the three lines are still printed.
# And directly: on a successful stamp, stdout alone carries feature, count and
# sha BEFORE the `stamped` line, so a prompt on the command shows them first.
d=$(new_repo)
st "$d" init demo >/dev/null 2>&1
st "$d" stamp demo > "$tmproot/stamp-stdout.out" 2>/dev/null
assert_order "$tmproot/stamp-stdout.out" '^feature: demo$' '^requirements: [0-9]+$' '^spec_sha: [0-9a-f]{64}$' '^stamped .*specs/demo/state\.json$'

# ---------------------------------------------------------------------------
req "REQ-TOUCH-004"
d=$(new_repo)
f="$d/specs/demo/state.json"
st "$d" init demo >/dev/null 2>&1
st "$d" stamp demo >/dev/null 2>&1
cp "$d/specs/demo/requirements.md" "$tmproot/req.orig"
printf '\nA sentence added after the stamp.\n' >> "$d/specs/demo/requirements.md"
capture "$tmproot/ss4.out" st "$d" stamp-state demo
assert_grep "^stale$" "$tmproot/ss4.out"
assert_rc 1 "$tmproot/ss4.out"
capture "$tmproot/status4.out" st "$d" status
assert_grep "^demo stamp=stale tasks=open:1,claimed:1,parked:1,done:2 evidence=none verifier=none ui-tester=none$" "$tmproot/status4.out"
assert_no_grep "^_shipped" "$tmproot/status4.out"
cp "$tmproot/req.orig" "$d/specs/demo/requirements.md"
capture "$tmproot/ss4b.out" st "$d" stamp-state demo
assert_grep "^ok " "$tmproot/ss4b.out"
assert_rc 0 "$tmproot/ss4b.out"
capture "$tmproot/status4b.out" st "$d" status
assert_grep "^demo stamp=[0-9]{4}-[0-9]{2}-[0-9]{2} tasks=" "$tmproot/status4b.out"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-009"
# Not a git repository: refused, naming the directory, nothing written.
n=$(mktemp -d "$tmproot/nogit.XXXXXX")
n=$(cd "$n" && pwd)   # TMPDIR may end in "/"; the script names $PWD
mkdir -p "$n/specs/demo"
cp "$tmproot/req.orig" "$n/specs/demo/requirements.md"
capture "$tmproot/nogit.out" st "$n" init demo
assert_rc nonzero "$tmproot/nogit.out"
assert_fgrep "$n" "$tmproot/nogit.out"
check "nothing written outside a repo" test ! -e "$n/specs/demo/state.json"
# requirements.md missing: refused, naming it.
d=$(new_repo)
rm "$d/specs/demo/requirements.md"
capture "$tmproot/noreq.out" st "$d" init demo
assert_rc nonzero "$tmproot/noreq.out"
assert_fgrep "specs/demo/requirements.md" "$tmproot/noreq.out"
check "nothing written without requirements" test ! -e "$d/specs/demo/state.json"
# Target not writable: refused, naming the path, file byte-identical.
d=$(new_repo)
f="$d/specs/demo/state.json"
st "$d" init demo >/dev/null 2>&1
before=$(sha_of "$f")
chmod 555 "$d/specs/demo"
capture "$tmproot/ro.out" st "$d" stamp demo
chmod 755 "$d/specs/demo"
assert_rc nonzero "$tmproot/ro.out"
assert_fgrep "specs/demo/state.json" "$tmproot/ro.out"
check "read-only target byte-identical" test "$(sha_of "$f")" = "$before"
check "no temp file left behind" test "$(find "$d/specs/demo" -type f | wc -l | tr -d ' ')" = "3"
req "REQ-TOUCH-053"
# The stamp printed what it was about to write before the write failed.
assert_grep "requirements: 3" "$tmproot/ro.out"
assert_fgrep "$(sha_of "$d/specs/demo/requirements.md")" "$tmproot/ro.out"
req "REQ-TOUCH-009"
# init on an existing state.json: refused, file untouched (a stamp survives).
st "$d" stamp demo >/dev/null 2>&1
before=$(sha_of "$f")
capture "$tmproot/reinit.out" st "$d" init demo
assert_rc nonzero "$tmproot/reinit.out"
assert_fgrep "specs/demo/state.json" "$tmproot/reinit.out"
check "re-init left the stamped file byte-identical" test "$(sha_of "$f")" = "$before"
# stamp with no state.json: refused, naming it.
d=$(new_repo)
capture "$tmproot/nostate.out" st "$d" stamp demo
assert_rc nonzero "$tmproot/nostate.out"
assert_fgrep "specs/demo/state.json" "$tmproot/nostate.out"
# Usage errors exit 2.
capture "$tmproot/usage.out" st "$d" frobnicate demo
assert_rc 2 "$tmproot/usage.out"
capture "$tmproot/usage2.out" st "$d" init
assert_rc 2 "$tmproot/usage2.out"

# ===========================================================================
# evidence, record, evidence-state, status (REQ-TOUCH-005 to 008, 043)
# ===========================================================================

# gc <dir> <git args...> — git in a fixture, never running anyone's hooks.
gc() { local dir="$1"; shift; git -C "$dir" -c core.hooksPath=/dev/null "$@"; }

# lib_tree <dir> [<ref>] — the evidence tree as the guard library computes it.
lib_tree() {
  (cd "$1" && . "$TEST_REPO/hooks/guard-lib.sh" && evidence_tree demo "${2:-WORKTREE}")
}

# json_ok <file> — the digest of an evidence/state file matches its body.
# shellcheck disable=SC2329  # invoked indirectly through check
json_ok() { [ "$(jq -r '.digest' "$1" 2>/dev/null)" = "$(digest_of "$1")" ]; }

# differs <a> <b> — the two files are not byte-identical.
# shellcheck disable=SC2329  # invoked indirectly through check
differs() { ! cmp -s "$1" "$2"; }

# set_rc <dir> <check|test> <rc> — make the fixture's contract target exit <rc>.
set_rc() { printf 'echo "%s-RUN-MARKER"\nexit %s\n' "$2" "$3" > "$1/$2.sh"; }

# new_ev_repo — a committed git repo whose Makefile has controllable check and
# test targets, a spec with three IDs ($id1 done and tagged → OK, $id2 open →
# OPEN, $id3 done but untagged → no label), and a stamped state.json.
new_ev_repo() {
  local d
  d=$(mktemp -d "$tmproot/ev.XXXXXX")
  d=$(cd "$d" && pwd -P)
  git -C "$d" init -q
  git -C "$d" config user.name "SDLC Test"
  git -C "$d" config user.email "sdlc-test@example.invalid"
  mkdir -p "$d/specs/demo" "$d/tests"
  cat > "$d/specs/demo/requirements.md" <<EOF
# Requirements — demo

$id1  WHEN a thing happens THE SYSTEM SHALL do it.
              verify: unit

$id2  WHEN another thing happens THE SYSTEM SHALL do that.

$id3  WHEN a third thing happens THE SYSTEM SHALL wait.
EOF
  cat > "$d/specs/demo/tasks.md" <<EOF
# Tasks — demo
- [x] T1: one [$id1]
- [ ] T2: two [$id2]
- [x] T3: three [$id3]
EOF
  printf '# covers %s\n' "$id1" > "$d/tests/test_demo.sh"
  printf 'check:\n\tsh ./check.sh\n\ntest:\n\tsh ./test.sh\n' > "$d/Makefile"
  set_rc "$d" check 0
  set_rc "$d" test 0
  printf 'v1\n' > "$d/src.txt"
  gc "$d" add -A
  gc "$d" commit -qm init
  st "$d" init demo >/dev/null 2>&1
  st "$d" stamp demo >/dev/null 2>&1
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
req "REQ-TOUCH-005"
d=$(new_ev_repo)
e="$d/specs/demo/evidence.json"
capture "$tmproot/ev1.out" st "$d" evidence demo
assert_rc 0 "$tmproot/ev1.out"
assert_file "$e"
check "evidence digest valid" json_ok "$e"
check "schema 1, feature demo" test "$(jq -r '"\(.schema) \(.feature)"' "$e" 2>/dev/null)" = "1 demo"
check "check.rc 0 and test.rc 0" test "$(jq -r '"\(.check.rc) \(.test.rc)"' "$e" 2>/dev/null)" = "0 0"
check "seconds are numbers" test "$(jq -r '[.check.seconds, .test.seconds] | map(type) | join(",")' "$e" 2>/dev/null)" = "number,number"
check "commands recorded" test "$(jq -r '"\(.check.command)|\(.test.command)"' "$e" 2>/dev/null)" = "make check|make test"
check "head is HEAD" test "$(jq -r '.head' "$e" 2>/dev/null)" = "$(git -C "$d" rev-parse HEAD)"
check "branch is the current branch" test "$(jq -r '.branch' "$e" 2>/dev/null)" = "$(git -C "$d" symbolic-ref --short -q HEAD)"
check "at is an ISO time" test -n "$(jq -r '.at | select(test("^[0-9-]+T[0-9:]+Z$"))' "$e" 2>/dev/null)"
t_lib=$(lib_tree "$d")
check "evidence_tree is the library's working-tree evidence tree" test -n "$t_lib" -a "$(jq -r '.evidence_tree' "$e" 2>/dev/null)" = "$t_lib"
check "coverage labels from req-gate --report" test "$(jq -r --arg a "$id1" --arg b "$id2" --arg c "$id3" '"\(.coverage[$a]) \(.coverage[$b]) \(.coverage[$c])"' "$e" 2>/dev/null)" = "OK OPEN MISSING"
check "verdict lanes start null" test "$(jq -c '[.verifier, .["ui-tester"]]' "$e" 2>/dev/null)" = "[null,null]"
# The test target red: non-zero, and the red run is still recorded.
set_rc "$d" test 1
capture "$tmproot/ev1r.out" st "$d" evidence demo
assert_rc nonzero "$tmproot/ev1r.out"
check "red run recorded: check.rc 0, test.rc nonzero" test "$(jq -r '"\(.check.rc) \(.test.rc != 0)"' "$e" 2>/dev/null)" = "0 true"
check "red evidence digest valid" json_ok "$e"
assert_fgrep "test-RUN-MARKER" "$tmproot/ev1r.out"
# The check target red too: recorded, non-zero.
set_rc "$d" check 3
capture "$tmproot/ev1c.out" st "$d" evidence demo
assert_rc nonzero "$tmproot/ev1c.out"
check "red check recorded with a nonzero rc" test "$(jq -r '.check.rc != 0' "$e" 2>/dev/null)" = "true"
# No contract: non-zero naming the directory, the old file byte-identical.
before=$(sha_of "$e")
rm "$d/Makefile"
capture "$tmproot/ev1n.out" st "$d" evidence demo
assert_rc nonzero "$tmproot/ev1n.out"
assert_fgrep "$d" "$tmproot/ev1n.out"
check "no contract: evidence.json byte-identical" test "$(sha_of "$e")" = "$before"
d=$(new_ev_repo)
rm "$d/Makefile"
capture "$tmproot/ev1m.out" st "$d" evidence demo
assert_rc nonzero "$tmproot/ev1m.out"
check "no contract: nothing written" test ! -e "$d/specs/demo/evidence.json"
# A Makefile with check but no test target is no contract either.
printf 'check:\n\tsh ./check.sh\n' > "$d/Makefile"
capture "$tmproot/ev1h.out" st "$d" evidence demo
assert_rc nonzero "$tmproot/ev1h.out"
check "half a contract: nothing written" test ! -e "$d/specs/demo/evidence.json"
# Without requirements.md: refused, nothing written.
d=$(new_ev_repo)
rm "$d/specs/demo/requirements.md"
capture "$tmproot/ev1q.out" st "$d" evidence demo
assert_rc nonzero "$tmproot/ev1q.out"
assert_fgrep "specs/demo/requirements.md" "$tmproot/ev1q.out"
check "no requirements: nothing written" test ! -e "$d/specs/demo/evidence.json"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-006"
d=$(new_ev_repo)
f="$d/specs/demo/state.json"
st "$d" evidence demo >/dev/null 2>&1
check "passes true only for the OK ID" test "$(jq -r --arg a "$id1" --arg b "$id2" --arg c "$id3" '"\(.requirements[$a].passes) \(.requirements[$b].passes) \(.requirements[$c].passes)"' "$f" 2>/dev/null)" = "true false false"
check "state digest valid after evidence" json_ok "$f"
# A red run leaves state.json byte-identical.
before=$(sha_of "$f")
set_rc "$d" test 1
st "$d" evidence demo >/dev/null 2>&1
check "red run: state.json byte-identical" test "$(sha_of "$f")" = "$before"
set_rc "$d" test 0
# stamp does not write passes: the true value survives, only gate1 (and the
# digest) changes.
cp "$f" "$tmproot/state6.before"
st "$d" stamp demo >/dev/null 2>&1
check "stamp keeps passes true" test "$(jq -r --arg a "$id1" '.requirements[$a].passes' "$f" 2>/dev/null)" = "true"
check "stamp changes nothing but gate1" test "$(jq -cS 'del(.gate1, .digest)' "$f")" = "$(jq -cS 'del(.gate1, .digest)' "$tmproot/state6.before")"
# record does not write passes either.
cp "$f" "$tmproot/state6.rec"
st "$d" record demo verifier PASS "fine" >/dev/null 2>&1
check "record leaves state.json byte-identical" cmp -s "$f" "$tmproot/state6.rec"
# A previously true ID that is no longer OK goes back to false.
sed -i.bak "s/- \[x\] T1/- [ ] T1/" "$d/specs/demo/tasks.md" && rm -f "$d/specs/demo/tasks.md.bak"
st "$d" evidence demo >/dev/null 2>&1
check "an ID no longer OK is set false" test "$(jq -r --arg a "$id1" '.requirements[$a].passes' "$f" 2>/dev/null)" = "false"
# No state.json: the evidence run still succeeds, says so, writes evidence.
d=$(new_ev_repo)
rm "$d/specs/demo/state.json"
capture "$tmproot/ev6s.out" st "$d" evidence demo
assert_rc 0 "$tmproot/ev6s.out"
assert_fgrep "state.json" "$tmproot/ev6s.out"
check "no state.json: none created" test ! -e "$d/specs/demo/state.json"
assert_file "$d/specs/demo/evidence.json"
# An invalid state.json is left as it was.
d=$(new_ev_repo)
f="$d/specs/demo/state.json"
jq '.feature = "edited"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
before=$(sha_of "$f")
capture "$tmproot/ev6i.out" st "$d" evidence demo
assert_rc 0 "$tmproot/ev6i.out"
assert_fgrep "specs/demo/state.json" "$tmproot/ev6i.out"
check "invalid state.json byte-identical" test "$(sha_of "$f")" = "$before"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-007"
d=$(new_ev_repo)
e="$d/specs/demo/evidence.json"
st "$d" evidence demo >/dev/null 2>&1
capture "$tmproot/rec7.out" st "$d" record demo verifier PASS "looks right"
assert_rc 0 "$tmproot/rec7.out"
check "verifier lane stored" test "$(jq -r '"\(.verifier.verdict)|\(.verifier.note)"' "$e" 2>/dev/null)" = "PASS|looks right"
check "verifier at is an ISO time" test -n "$(jq -r '.verifier.at | select(test("^[0-9-]+T[0-9:]+Z$"))' "$e" 2>/dev/null)"
check "digest valid after record" json_ok "$e"
check "ui-tester untouched" test "$(jq -c '.["ui-tester"]' "$e" 2>/dev/null)" = "null"
v_before=$(jq -c '.verifier' "$e")
capture "$tmproot/rec7b.out" st "$d" record demo ui-tester FAIL "button missing"
assert_rc 0 "$tmproot/rec7b.out"
check "ui-tester lane stored" test "$(jq -r '"\(.["ui-tester"].verdict)|\(.["ui-tester"].note)"' "$e" 2>/dev/null)" = "FAIL|button missing"
check "verifier lane untouched by the ui-tester record" test "$(jq -c '.verifier' "$e")" = "$v_before"
check "digest valid after second record" json_ok "$e"
capture "$tmproot/rec7c.out" st "$d" record demo verifier COULD-NOT-TEST "no browser"
assert_rc 0 "$tmproot/rec7c.out"
check "COULD-NOT-TEST accepted" test "$(jq -r '.verifier.verdict' "$e")" = "COULD-NOT-TEST"
# Wrong lane or verdict words: usage, nothing written.
before=$(sha_of "$e")
capture "$tmproot/rec7u.out" st "$d" record demo reviewer PASS "x"
assert_rc 2 "$tmproot/rec7u.out"
capture "$tmproot/rec7v.out" st "$d" record demo verifier MAYBE "x"
assert_rc 2 "$tmproot/rec7v.out"
check "bad words: evidence.json byte-identical" test "$(sha_of "$e")" = "$before"
# A new evidence run resets the verdict lanes.
st "$d" evidence demo >/dev/null 2>&1
check "new evidence run resets both lanes" test "$(jq -c '[.verifier, .["ui-tester"]]' "$e" 2>/dev/null)" = "[null,null]"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-043"
d=$(new_ev_repo)
e="$d/specs/demo/evidence.json"
capture "$tmproot/r43a.out" st "$d" record demo verifier PASS "x"
assert_rc nonzero "$tmproot/r43a.out"
assert_fgrep "specs/demo/evidence.json" "$tmproot/r43a.out"
check "no evidence: nothing written" test ! -e "$e"
# A hand edit: refused naming the file, byte-identical.
st "$d" evidence demo >/dev/null 2>&1
jq '.test.rc = 0 | .check.seconds = 1' "$e" > "$e.tmp" && mv "$e.tmp" "$e"
jq '.head = "0000"' "$e" > "$e.tmp" && mv "$e.tmp" "$e"
before=$(sha_of "$e")
capture "$tmproot/r43b.out" st "$d" record demo verifier PASS "x"
assert_rc nonzero "$tmproot/r43b.out"
assert_fgrep "specs/demo/evidence.json" "$tmproot/r43b.out"
check "hand-edited evidence byte-identical" test "$(sha_of "$e")" = "$before"
# A code change after the evidence: stale, refused, byte-identical.
st "$d" evidence demo >/dev/null 2>&1
printf 'v2\n' > "$d/src.txt"
before=$(sha_of "$e")
capture "$tmproot/r43c.out" st "$d" record demo verifier PASS "x"
assert_rc nonzero "$tmproot/r43c.out"
assert_fgrep "stale" "$tmproot/r43c.out"
check "stale evidence byte-identical" test "$(sha_of "$e")" = "$before"
# Committing only the two JSON files keeps the evidence current (044).
printf 'v1\n' > "$d/src.txt"
st "$d" evidence demo >/dev/null 2>&1
gc "$d" add specs/demo/state.json specs/demo/evidence.json
gc "$d" commit -qm evidence
capture "$tmproot/r43d.out" st "$d" record demo verifier PASS "after commit"
assert_rc 0 "$tmproot/r43d.out"
check "record after committing the JSON files" test "$(jq -r '.verifier.note' "$e")" = "after commit"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-008"
d=$(new_ev_repo)
e="$d/specs/demo/evidence.json"
capture "$tmproot/s8n.out" st "$d" status
assert_grep "^demo stamp=[0-9]{4}-[0-9]{2}-[0-9]{2} tasks=open:1,claimed:0,parked:0,done:2 evidence=none verifier=none ui-tester=none$" "$tmproot/s8n.out"
st "$d" evidence demo >/dev/null 2>&1
st "$d" record demo verifier PASS "ok" >/dev/null 2>&1
capture "$tmproot/s8g.out" st "$d" status
assert_grep "^demo stamp=[0-9]{4}-[0-9]{2}-[0-9]{2} tasks=open:1,claimed:0,parked:0,done:2 evidence=green verifier=PASS ui-tester=none$" "$tmproot/s8g.out"
capture "$tmproot/es8g.out" st "$d" evidence-state demo
assert_grep "^green$" "$tmproot/es8g.out"
assert_rc 0 "$tmproot/es8g.out"
printf 'v2\n' > "$d/src.txt"
capture "$tmproot/s8s.out" st "$d" status
assert_grep "^demo .* evidence=stale verifier=PASS ui-tester=none$" "$tmproot/s8s.out"
capture "$tmproot/es8s.out" st "$d" evidence-state demo WORKTREE
assert_grep "^stale$" "$tmproot/es8s.out"
assert_rc nonzero "$tmproot/es8s.out"
printf 'v1\n' > "$d/src.txt"
set_rc "$d" test 1
st "$d" evidence demo >/dev/null 2>&1
capture "$tmproot/s8r.out" st "$d" status
assert_grep "^demo .* evidence=red verifier=none ui-tester=none$" "$tmproot/s8r.out"
capture "$tmproot/es8r.out" st "$d" evidence-state demo
assert_grep "^red$" "$tmproot/es8r.out"
assert_rc nonzero "$tmproot/es8r.out"
jq '.test.rc = 0' "$e" > "$e.tmp" && mv "$e.tmp" "$e"
capture "$tmproot/s8i.out" st "$d" status
assert_grep "^demo .* evidence=invalid verifier=" "$tmproot/s8i.out"
capture "$tmproot/es8i.out" st "$d" evidence-state demo
assert_grep "^invalid .*specs/demo/evidence\.json$" "$tmproot/es8i.out"
assert_rc nonzero "$tmproot/es8i.out"
rm -f "$e"
capture "$tmproot/es8n.out" st "$d" evidence-state demo
assert_grep "^none$" "$tmproot/es8n.out"
assert_rc nonzero "$tmproot/es8n.out"
# Absent from the working tree, present on sdlc/demo: status reads the ref.
d=$(new_ev_repo)
base=$(git -C "$d" symbolic-ref --short HEAD)
gc "$d" checkout -q -b sdlc/demo
st "$d" evidence demo >/dev/null 2>&1
gc "$d" add specs/demo/state.json specs/demo/evidence.json
gc "$d" commit -qm evidence
gc "$d" checkout -q "$base"
check "evidence.json absent from the working tree" test ! -e "$d/specs/demo/evidence.json"
capture "$tmproot/s8ref.out" st "$d" status
assert_grep "^demo .* evidence=green verifier=none ui-tester=none$" "$tmproot/s8ref.out"
capture "$tmproot/es8ref.out" st "$d" evidence-state demo sdlc/demo
assert_grep "^green$" "$tmproot/es8ref.out"
assert_rc 0 "$tmproot/es8ref.out"
capture "$tmproot/es8wt.out" st "$d" evidence-state demo
assert_grep "^none$" "$tmproot/es8wt.out"
assert_rc nonzero "$tmproot/es8wt.out"
# A code change committed on sdlc/demo makes the ref's evidence stale.
gc "$d" checkout -q sdlc/demo
printf 'v3\n' > "$d/src.txt"
gc "$d" commit -qam change
gc "$d" checkout -q "$base"
capture "$tmproot/s8refs.out" st "$d" status
assert_grep "^demo .* evidence=stale verifier=none ui-tester=none$" "$tmproot/s8refs.out"
capture "$tmproot/es8refs.out" st "$d" evidence-state demo sdlc/demo
assert_grep "^stale$" "$tmproot/es8refs.out"
assert_rc nonzero "$tmproot/es8refs.out"
# An unknown ref cannot be verified: never green.
capture "$tmproot/es8bad.out" st "$d" evidence-state demo no/such-ref
assert_rc nonzero "$tmproot/es8bad.out"
assert_no_grep "^green$" "$tmproot/es8bad.out"

# ---------------------------------------------------------------------------
# Mutations (CLAUDE.md: prove a guard by breaking what it guards). A copy of
# the script beside copies of the hooks it sources; each mutant must make the
# case its requirement pins go the other way.
mut=$(mktemp -d "$tmproot/mut.XXXXXX")
mkdir -p "$mut/scripts" "$mut/hooks"
cp "$TEST_REPO/hooks/guard-lib.sh" "$TEST_REPO/hooks/req-gate.sh" "$mut/hooks/"

req "REQ-TOUCH-006"
# Mutant 1: every ID labelled as passing, not only the OK ones.
sed 's/== "OK"/!= "NO-SUCH-LABEL"/' "$S" > "$mut/scripts/sdlc-state.sh"
check "mutant 1 differs from the script" differs "$S" "$mut/scripts/sdlc-state.sh"
d=$(new_ev_repo)
(cd "$d" && bash "$mut/scripts/sdlc-state.sh" evidence demo) >/dev/null 2>&1
check "mutant 1 (passes for every ID) is caught: an OPEN ID would pass" test "$(jq -r --arg b "$id2" '.requirements[$b].passes' "$d/specs/demo/state.json" 2>/dev/null)" = "true"

req "REQ-TOUCH-043"
# Mutant 2: record skips the evidence-tree comparison.
grep -v 'is stale' "$S" > "$mut/scripts/sdlc-state.sh"
check "mutant 2 differs from the script" differs "$S" "$mut/scripts/sdlc-state.sh"
d=$(new_ev_repo)
st "$d" evidence demo >/dev/null 2>&1
printf 'v2\n' > "$d/src.txt"
# shellcheck disable=SC2329  # invoked indirectly through capture
mst() { local dir="$1"; shift; (cd "$dir" && bash "$mut/scripts/sdlc-state.sh" "$@"); }
capture "$tmproot/mut2.out" mst "$d" record demo verifier PASS x
assert_rc 0 "$tmproot/mut2.out"

finish
