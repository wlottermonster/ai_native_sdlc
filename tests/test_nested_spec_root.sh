#!/bin/bash
# AI-Native SDLC — the gate1-stamp guard for a repository nested inside an
# umbrella (REQ-TOUCH-015, REQ-TOUCH-016). A family of repositories can keep
# its specs and their Gate 1 stamps in an umbrella repository while the code
# commits land in repositories nested inside it (each its own git repository,
# ignored by the umbrella). A commit on `sdlc/<x>` in a nested repository
# resolves its feature from the nearest enclosing repository that declares
# itself to the framework (a `decision log:` line in its CLAUDE.md or
# AGENTS.md) when no `specs/<feature>/` resolves in the repository itself.
# Nothing else is loosened: no spec anywhere is still a refusal, an unstamped
# or stale umbrella spec is still a refusal, and a repository's own spec, when
# it resolves, is the one that decides.
#
# Every fixture lives under one mktemp -d root, removed on exit; HOME points
# at a throwaway directory, so nothing here reads or writes the real
# $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-nested.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

gate="$TEST_REPO/hooks/check-gate.sh"
DAY=86400

# A throwaway ~/.claude with the installed copies a nested repository falls
# back on: the requirement gate (a docs-only commit ends in it) and the state
# script (the nested repository carries none of its own).
nhome=$(mktemp -d "$tmproot/home.XXXXXX")
mkdir -p "$nhome/.claude/hooks" "$nhome/.claude/scripts"
cp "$TEST_REPO/hooks/req-gate.sh" "$TEST_REPO/hooks/guard-lib.sh" "$nhome/.claude/hooks/"
cp "$TEST_REPO/scripts/sdlc-state.sh" "$nhome/.claude/scripts/sdlc-state.sh"

# The fixture requirement ID is assembled at run time: req-gate's orphan check
# scans every test file for REQ-shaped tokens.
fx_feat=NEST
fx_id="REQ-${fx_feat}-001"

# new_repo <dir> — a git repository with a local identity and a `check`
# target that passes, so only the guard can refuse.
new_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.name "SDLC Test"
  git -C "$1" config user.email "sdlc-test@example.invalid"
  printf 'check:\n\ttrue\n' > "$1/Makefile"
}

# add_spec <repo> <feature> — specs/<feature>/ with one requirement and a task
# citing it.
add_spec() {
  mkdir -p "$1/specs/$2"
  printf '# %s — requirements\n\n%s  WHEN it runs, THE SYSTEM SHALL do the thing.\n              verify: unit\n' \
    "$2" "$fx_id" > "$1/specs/$2/requirements.md"
  printf '# %s — tasks\n\n- [ ] T1: build the thing    [%s]\n' "$2" "$fx_id" > "$1/specs/$2/tasks.md"
}

# state_in <repo> <args> — the state script, run from <repo>'s root.
state_in() {
  local r="$1"
  shift
  ( cd "$r" && bash "$TEST_REPO/scripts/sdlc-state.sh" "$@" ) > /dev/null 2>&1
}

# nested_gate <outfile> <repo> <branch> <mode|-> [<guards-dir>] — point
# <repo>'s HEAD at <branch>, stage one note (a docs-only commit, the shape the
# shortcut allows), run the commit gate as the hook runner does. stdout in
# <outfile>, stderr in <outfile>.err, exit in <outfile>.rc. "-" leaves
# SDLC_GUARD_MODE unset, so the clock in <guards-dir> decides.
nested_gate() {
  local out="$1" repo="$2" branch="$3" mode="$4" gdir="${5:-$SDLC_GUARDS_DIR}" rc=0
  git -C "$repo" symbolic-ref HEAD "refs/heads/$branch"
  echo note > "$repo/notes.md"
  git -C "$repo" add notes.md
  ( cd "$repo" || exit 99
    payload="{\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$repo\"}"
    if [ "$mode" = "-" ]; then
      printf '%s' "$payload" | env -u SDLC_GUARD_MODE HOME="$nhome" SDLC_GUARDS_DIR="$gdir" bash "$gate"
    else
      printf '%s' "$payload" | env HOME="$nhome" SDLC_GUARD_MODE="$mode" SDLC_GUARDS_DIR="$gdir" bash "$gate"
    fi ) > "$out" 2> "$out.err" || rc=$?
  printf '%s\n' "$rc" > "$out.rc"
}

# past_window — a guards directory whose three clocks opened 15 days ago:
# the warn window is over, so a refusal is a deny without any override.
past_window() {
  local d g
  d=$(mktemp -d "$tmproot/guards.XXXXXX")
  for g in gate1-stamp evidence-merge stop-evidence; do
    printf '%s\n' $(( $(date +%s) - 15 * DAY )) > "$d/$g.since"
  done
  printf '%s' "$d"
}

# The umbrella: declares itself, ignores the repository nested in it, and
# carries the stamped spec of feature `fam`.
umb="$tmproot/umbrella"
new_repo "$umb"
printf '# umbrella\n\ndecision log: CLAUDE.md\ntracker:\n' > "$umb/CLAUDE.md"
printf 'nested/\n' > "$umb/.gitignore"
add_spec "$umb" fam
git -C "$umb" add -A
git -C "$umb" commit -qm init
state_in "$umb" init fam
state_in "$umb" stamp fam
cp "$umb/specs/fam/requirements.md" "$tmproot/fam-req.orig"

# The nested repository: its own git repository inside the umbrella, with no
# specs/ of its own.
nest="$umb/nested"
new_repo "$nest"
echo code > "$nest/src.txt"
git -C "$nest" add -A
git -C "$nest" commit -qm init
umb_real=$(git -C "$umb" rev-parse --show-toplevel)

req "REQ-TOUCH-015"
# A task branch of a feature specced and stamped in the umbrella: allowed, and
# the guard says nothing.
out="$tmproot/n-task.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 0 "$out"
assert_no_grep 'gate1-stamp' "$out.err"
assert_no_grep 'gate1-stamp' "$out"
# The feature branch itself, and with the guard's clock past its window (no
# override at all): allowed.
pw=$(past_window)
out="$tmproot/n-feature.out"
nested_gate "$out" "$nest" sdlc/fam - "$pw"
assert_rc 0 "$out"
assert_no_grep 'gate1-stamp' "$out.err"

# A linked worktree of the nested repository placed OUTSIDE the umbrella
# resolves through its main checkout, which the umbrella encloses.
wt="$tmproot/outside/nested-wt"
mkdir -p "$tmproot/outside"
git -C "$nest" worktree add -q -b sdlc/fam-2 "$wt" main 2>/dev/null
out="$tmproot/n-worktree.out"
nested_gate "$out" "$wt" sdlc/fam-2 deny
assert_rc 0 "$out"
assert_no_grep 'gate1-stamp' "$out.err"

# The umbrella's spec unstamped (init only): refused, naming the feature and
# the umbrella the state was read in.
mv "$umb/specs/fam/state.json" "$tmproot/fam-state.stamped"
state_in "$umb" init fam
out="$tmproot/n-unstamped.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 2 "$out"
assert_fgrep "gate1-stamp" "$out.err"
assert_grep 'none' "$out.err"
assert_fgrep "feature 'fam'" "$out.err"
assert_fgrep "$umb_real" "$out.err"
# Absent altogether: refused.
rm -f "$umb/specs/fam/state.json"
out="$tmproot/n-nostate.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 2 "$out"
assert_grep 'none' "$out.err"
mv "$tmproot/fam-state.stamped" "$umb/specs/fam/state.json"
# Stamped, then requirements.md changed: stale, refused.
printf 'one more line\n' >> "$umb/specs/fam/requirements.md"
out="$tmproot/n-stale.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 2 "$out"
assert_grep 'stale' "$out.err"
cp "$tmproot/fam-req.orig" "$umb/specs/fam/requirements.md"
# Restored: allowed again (the refusals above were the stamp, not the fixture).
out="$tmproot/n-restored.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 0 "$out"

# The repository's own spec decides when it resolves: a nested specs/fam/
# without a stamp is refused although the umbrella's is stamped.
add_spec "$nest" fam
out="$tmproot/n-own-first.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 2 "$out"
assert_grep 'none' "$out.err"
rm -rf "$nest/specs"

req "REQ-TOUCH-016"
# No spec in the nested repository nor in the umbrella: refused, naming the
# branch — in deny mode, and with the clock past its window and no override.
out="$tmproot/n-nomatch.out"
nested_gate "$out" "$nest" sdlc/elsewhere-1 deny
assert_rc 2 "$out"
assert_fgrep "sdlc/elsewhere-1" "$out.err"
assert_fgrep "gate1-stamp" "$out.err"
pw=$(past_window)
out="$tmproot/n-nomatch-clock.out"
nested_gate "$out" "$nest" sdlc/elsewhere-1 - "$pw"
assert_rc 2 "$out"
assert_fgrep "sdlc/elsewhere-1" "$out.err"
assert_fgrep "gate1-stamp: deny" "$out.err"
# Inside the window it still warns, as before.
out="$tmproot/n-nomatch-warn.out"
nested_gate "$out" "$nest" sdlc/elsewhere-1 warn
assert_rc 0 "$out"
assert_grep '^WARN \(gate1-stamp' "$out.err"

# An enclosing repository that does not declare itself is not a spec root:
# without the `decision log:` line the umbrella's stamped spec is not read.
mv "$umb/CLAUDE.md" "$tmproot/umb-claude.md"
printf '# umbrella\n\nno declaration here\n' > "$umb/CLAUDE.md"
out="$tmproot/n-undeclared.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 2 "$out"
assert_fgrep "sdlc/fam-1" "$out.err"
# Declared through AGENTS.md instead: read again.
printf '# umbrella\n\ndecision log: AGENTS.md\n' > "$umb/AGENTS.md"
out="$tmproot/n-agents.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 0 "$out"
rm -f "$umb/AGENTS.md"
mv "$tmproot/umb-claude.md" "$umb/CLAUDE.md"

# A repository nested in nothing is unchanged: no spec, refused.
solo="$tmproot/solo"
new_repo "$solo"
echo code > "$solo/src.txt"
git -C "$solo" add -A
git -C "$solo" commit -qm init
out="$tmproot/n-solo.out"
nested_gate "$out" "$solo" sdlc/fam-1 deny
assert_rc 2 "$out"
assert_fgrep "sdlc/fam-1" "$out.err"

# --- an evidence-only specs/<feature>/ in the nested repository (hq#845) -----
# The build records its evidence in the repository the code lands in, so the
# nested repository gains specs/<feature>/evidence.json while the spec and its
# stamp stay in the umbrella.

req "REQ-OC1103-002"
# A nested specs/fam/ that holds only evidence.json is not a local spec: the
# stamp is still read from the umbrella, so the commit passes in deny mode and
# with the clock past its window.
mkdir -p "$nest/specs/fam"
printf '{}\n' > "$nest/specs/fam/evidence.json"
out="$tmproot/n-evonly.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 0 "$out"
assert_no_grep 'gate1-stamp' "$out.err"
pw=$(past_window)
out="$tmproot/n-evonly-clock.out"
nested_gate "$out" "$nest" sdlc/fam - "$pw"
assert_rc 0 "$out"
# ...and the umbrella's stamp still decides: unstamped there, refused here.
mv "$umb/specs/fam/state.json" "$tmproot/fam-state.stamped"
out="$tmproot/n-evonly-unstamped.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 2 "$out"
assert_grep 'none' "$out.err"
assert_fgrep "$umb_real" "$out.err"
mv "$tmproot/fam-state.stamped" "$umb/specs/fam/state.json"
# A nested specs/fam/ with requirements.md is still the local spec.
add_spec "$nest" fam
out="$tmproot/n-evonly-own.out"
nested_gate "$out" "$nest" sdlc/fam-1 deny
assert_rc 2 "$out"
rm -rf "$nest/specs"

# A second nested repository for the evidence runs and merges: a check and a
# test target, the test red while a committed file named `red` exists.
nest2="$umb/nested2"
printf 'nested/\nnested2/\n' > "$umb/.gitignore"
new_repo "$nest2"
printf 'check:\n\ttrue\ntest:\n\ttest ! -f red\n' > "$nest2/Makefile"
echo code > "$nest2/src.txt"
git -C "$nest2" add -A
git -C "$nest2" commit -qm init
hd="hunt-$(date +%Y-%m-%d)"

# ev_in <outfile> <repo> <feature> — sdlc-state.sh evidence, run from <repo>.
ev_in() {
  local out="$1" r="$2" rc=0
  ( cd "$r" && bash "$TEST_REPO/scripts/sdlc-state.sh" evidence "$3" ) > "$out" 2>&1 < /dev/null || rc=$?
  printf '%s\n' "$rc" > "$out.rc"
}

# merge_gate <outfile> <repo> <ref> — the commit gate on `git merge <ref>` in
# deny mode, as the hook runner calls it.
merge_gate() {
  local out="$1" repo="$2" ref="$3" rc=0
  ( cd "$repo" || exit 99
    printf '{"tool_input":{"command":"git merge %s"},"cwd":"%s"}' "$ref" "$repo" \
      | env HOME="$nhome" SDLC_GUARD_MODE=deny bash "$gate" ) > "$out" 2> "$out.err" || rc=$?
  printf '%s\n' "$rc" > "$out.rc"
}

# commit_all <repo> <message>
commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "$2"; }

req "REQ-OC1103-001"
# No requirements.md in the nested repository: coverage is the umbrella's
# spec, labelled by the umbrella's report (its one task is open), and the
# evidence is written here. No state.json is created in the nested
# repository, and the umbrella's is left as it was.
umb_state_sha=$(shasum -a 256 < "$umb/specs/fam/state.json")
git -C "$nest2" checkout -q -b sdlc/fam main
echo feature > "$nest2/feat.txt"
commit_all "$nest2" feat
out="$tmproot/ev-umb.out"
ev_in "$out" "$nest2" fam
assert_rc 0 "$out"
assert_file "$nest2/specs/fam/evidence.json"
# shellcheck disable=SC2016  # $id is a jq variable, not a shell one
assert_exit 0 jq -e --arg id "$fx_id" '.coverage == {($id): "OPEN"}' "$nest2/specs/fam/evidence.json"
assert_exit 0 jq -e '.check.rc == 0 and .test.rc == 0' "$nest2/specs/fam/evidence.json"
assert_exit 1 test -e "$nest2/specs/fam/state.json"
assert_exit 0 test "$(shasum -a 256 < "$umb/specs/fam/state.json")" = "$umb_state_sha"
assert_exit 1 test -e "$umb/specs/fam/evidence.json"
commit_all "$nest2" evidence
# No spec anywhere (a hunt branch): empty coverage, written here.
git -C "$nest2" checkout -q -b "sdlc/$hd" main
echo fix > "$nest2/fix.txt"
commit_all "$nest2" fix
out="$tmproot/ev-none.out"
ev_in "$out" "$nest2" "$hd"
assert_rc 0 "$out"
assert_exit 0 jq -e '.coverage == {}' "$nest2/specs/$hd/evidence.json"
assert_exit 1 test -e "$nest2/specs/$hd/state.json"
commit_all "$nest2" evidence
# The same in a repository nested in nothing.
solo2="$tmproot/solo2"
new_repo "$solo2"
printf 'check:\n\ttrue\ntest:\n\ttrue\n' > "$solo2/Makefile"
commit_all "$solo2" init
out="$tmproot/ev-solo.out"
ev_in "$out" "$solo2" "$hd"
assert_rc 0 "$out"
assert_exit 0 jq -e '.coverage == {}' "$solo2/specs/$hd/evidence.json"

req "REQ-OC1103-003"
# A merge of sdlc/fam on the nested main: the feature resolves through the
# umbrella spec, the evidence is read from the ref here. Green passes.
git -C "$nest2" checkout -q main
out="$tmproot/m-green.out"
merge_gate "$out" "$nest2" sdlc/fam
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"
# Hunt branch, green evidence on the ref and no spec anywhere: passes.
out="$tmproot/m-hunt-green.out"
merge_gate "$out" "$nest2" "sdlc/$hd"
assert_rc 0 "$out"
assert_no_grep 'evidence-merge' "$out.err"
# None: a task branch of the feature that carries no evidence.
git -C "$nest2" branch sdlc/fam-none main
out="$tmproot/m-none.out"
merge_gate "$out" "$nest2" sdlc/fam-none
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
assert_grep 'state: none' "$out.err"
# Stale: the code changed on the branch after the evidence was recorded.
git -C "$nest2" checkout -q sdlc/fam
echo more > "$nest2/feat.txt"
commit_all "$nest2" more
git -C "$nest2" checkout -q "sdlc/$hd"
echo more > "$nest2/fix.txt"
commit_all "$nest2" more
git -C "$nest2" checkout -q main
out="$tmproot/m-stale.out"
merge_gate "$out" "$nest2" sdlc/fam
assert_rc 2 "$out"
assert_grep 'state: stale' "$out.err"
out="$tmproot/m-hunt-stale.out"
merge_gate "$out" "$nest2" "sdlc/$hd"
assert_rc 2 "$out"
assert_grep 'state: stale' "$out.err"
# Red: evidence recorded on a tree whose test fails, then committed.
for b in sdlc/fam "sdlc/$hd"; do
  git -C "$nest2" checkout -q "$b"
  echo red > "$nest2/red"
  commit_all "$nest2" red
  ev_in "$tmproot/ev-red.out" "$nest2" "${b#sdlc/}"
  commit_all "$nest2" "red evidence"
done
git -C "$nest2" checkout -q main
out="$tmproot/m-red.out"
merge_gate "$out" "$nest2" sdlc/fam
assert_rc 2 "$out"
assert_grep 'state: red' "$out.err"
out="$tmproot/m-hunt-red.out"
merge_gate "$out" "$nest2" "sdlc/$hd"
assert_rc 2 "$out"
assert_grep 'state: red' "$out.err"
# A hunt branch with no evidence on the ref resolves to no feature: refused.
git -C "$nest2" branch "sdlc/$hd-b" main
out="$tmproot/m-hunt-none.out"
merge_gate "$out" "$nest2" "sdlc/$hd-b"
assert_rc 2 "$out"
assert_fgrep "evidence-merge" "$out.err"
# Only the spec-less names (hunt-*, rca-*) may resolve from evidence on the
# ref: any other sdlc/<x> with no spec here or in the umbrella is refused even
# with green evidence of its own committed on the ref (no Gate 1 bypass).
git -C "$nest2" checkout -q -b sdlc/nospec main
echo x > "$nest2/x.txt"
commit_all "$nest2" x
ev_in "$tmproot/ev-nospec.out" "$nest2" nospec
commit_all "$nest2" "nospec evidence"
git -C "$nest2" checkout -q main
out="$tmproot/m-nospec.out"
merge_gate "$out" "$nest2" sdlc/nospec
assert_rc 2 "$out"
assert_fgrep "no feature resolves" "$out.err"
# A stray local specs/<x>/ with no requirements.md (left untracked, or an archived leftover) is
# not a spec either: it must not let a spec-less sdlc/<x> past the hunt-*/rca-* restriction.
git -C "$nest2" checkout -q -b sdlc/stray main
echo y > "$nest2/y.txt"
commit_all "$nest2" y
ev_in "$tmproot/ev-stray.out" "$nest2" stray
commit_all "$nest2" "stray evidence"
git -C "$nest2" checkout -q main
mkdir -p "$nest2/specs/stray"
echo "leftover" > "$nest2/specs/stray/notes.md"
out="$tmproot/m-stray.out"
merge_gate "$out" "$nest2" sdlc/stray
assert_rc 2 "$out"
assert_fgrep "no feature resolves" "$out.err"
rm -rf "$nest2/specs/stray"
# The same stray in the UMBRELLA is not a spec either (sibling-path parity with the local lookup):
# an umbrella specs/<x>/ holding no requirements.md must not resolve a nested sdlc/<x>.
mkdir -p "$umb/specs/stray"
echo "leftover" > "$umb/specs/stray/notes.md"
out="$tmproot/m-umb-stray.out"
merge_gate "$out" "$nest2" sdlc/stray
assert_rc 2 "$out"
assert_fgrep "no feature resolves" "$out.err"
rm -rf "$umb/specs/stray"

finish
