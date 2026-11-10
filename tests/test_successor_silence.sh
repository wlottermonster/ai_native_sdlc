#!/bin/bash
# AI-Native SDLC — the four gating and fixing hooks stay silent in a repository
# that has moved to the successor lifecycle.
#
# A repository that COMMITS `.claude/rules/sdlc-v2.md` is fully separate from
# this framework: its gate is CI on the pull request. check-gate.sh, dod.sh,
# req-gate.sh (enforce and --stop) and autofix.sh exit 0 there with no output
# and no side effects. The repository judged is the one each hook already acts
# on: the commit gate follows the command's `cd` / `git -C`, dod.sh and
# req-gate.sh the repository of their working directory, autofix.sh the edited
# file's repository. A nested repository is judged on its own marker, never its
# umbrella's, and the reverse. A marker that is untracked or only staged does
# not count: creating an empty file must not switch a gate off.
#
# The last block mutates the helper in a copy of the hooks (it answers "not a
# successor repository" always) and watches every silenced case fire again.
#
# Every fixture lives under a mktemp -d directory removed on exit, with HOME
# and SDLC_GUARDS_DIR pointed at throwaway directories.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-successor.XXXXXX")
tmproot=$(cd "$tmproot" && pwd)
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT
export GIT_CEILING_DIRECTORIES="$tmproot"

# A home with the requirement gate and its library installed, as install.sh
# leaves them: check-gate.sh calls the installed req-gate.sh in a repository
# that carries no hooks/ of its own.
home=$(fresh_home "$tmproot")
mkdir -p "$home/.claude/hooks"
cp "$repo/hooks/req-gate.sh" "$repo/hooks/guard-lib.sh" "$home/.claude/hooks/"

# The fixture requirement ID is assembled at run time: req-gate's orphan check
# scans this file, and the ID is defined by no spec of this repository.
rid="REQ-DEMO""-001"

# mkrepo <dir> <committed|staged|untracked|none> — a repository whose every
# gate refuses: `make check` fails, a requirement has no task (Gate A), and a
# code file carries an uncommitted change. The marker is committed with the
# rest, staged after the commit, written untracked after it, or absent. The
# repository also holds a fake ruff that records each run in ruff-ran.
mkrepo() {
  local d=$1 how=$2
  mkdir -p "$d/specs/demo" "$d/src/deep" "$d/.venv/bin"
  git -C "$d" init -q
  git -C "$d" config user.name "SDLC Test"
  git -C "$d" config user.email "sdlc-test@example.invalid"
  printf 'check:\n\t@false\n' > "$d/Makefile"
  printf 'print(1)\n' > "$d/src/app.py"
  printf '%s  WHEN anything THE SYSTEM SHALL do it.\n' "$rid" > "$d/specs/demo/requirements.md"
  printf -- '- [ ] T1: something else\n' > "$d/specs/demo/tasks.md"
  printf '.venv/\nruff-ran\n' > "$d/.gitignore"
  if [ "$how" = committed ]; then
    mkdir -p "$d/.claude/rules"
    printf 'steering lines\n' > "$d/.claude/rules/sdlc-v2.md"
  fi
  git -C "$d" add -A
  git -C "$d" commit -qm init
  case "$how" in
    staged|untracked)
      mkdir -p "$d/.claude/rules"
      printf 'steering lines\n' > "$d/.claude/rules/sdlc-v2.md"
      [ "$how" = staged ] && git -C "$d" add .claude/rules/sdlc-v2.md ;;
  esac
  printf 'print(2)\n' > "$d/src/app.py"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ruff-ran"\n' "$d" > "$d/.venv/bin/ruff"
  chmod +x "$d/.venv/bin/ruff"
}

v2="$tmproot/v2";         mkrepo "$v2" committed
v1="$tmproot/v1";         mkrepo "$v1" none
untr="$tmproot/untr";     mkrepo "$untr" untracked
staged="$tmproot/staged"; mkrepo "$staged" staged
# An umbrella that committed the marker, holding a nested repository that has
# none; and an umbrella without one, holding a nested repository that has it.
umb2="$tmproot/umb2";     mkrepo "$umb2" committed
nest1="$umb2/nested";     mkrepo "$nest1" none
umb1="$tmproot/umb1";     mkrepo "$umb1" none
nest2="$umb1/nested";     mkrepo "$nest2" committed

# runh <out> <cwd> <stdin-file> <cmd...> — run a hook from <cwd> with the
# throwaway HOME and a fresh guards directory. Output in <out>, the exit code
# in <out>.rc, and the guards directory's contents after the run in
# <out>.guards (a silenced hook leaves it empty).
runh() {
  local out=$1 cwd=$2 in=$3 g rc=0
  shift 3
  g=$(mktemp -d "$tmproot/guards.XXXXXX")
  ( cd "$cwd" && HOME="$home" SDLC_GUARDS_DIR="$g" "$@" < "$in" ) > "$out" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$out.rc"
  ls -A "$g" > "$out.guards"
}

# silent <out> <what> — exit 0, not a byte of output, nothing written to the
# guards directory.
silent() {
  assert_rc 0 "$1"
  if [ -f "$1" ] && [ ! -s "$1" ]; then _test_pass "no output: $2"
  else _test_fail "expected no output ($2), got: $(head -c 300 "$1" 2>/dev/null)"; fi
  if [ -f "$1.guards" ] && [ ! -s "$1.guards" ]; then _test_pass "no guard state written: $2"
  else _test_fail "guard state written ($2): $(tr '\n' ' ' < "$1.guards" 2>/dev/null)"; fi
}

# fires <out> <what> — the gate blocked (exit 2) and said why.
# shellcheck disable=SC2329  # invoked indirectly, by name, from the cases below
fires() {
  assert_rc 2 "$1"
  if [ -s "$1" ]; then _test_pass "the gate reported: $2"
  else _test_fail "the gate said nothing: $2"; fi
}

n=0
# commit_case <hooks-dir> <session-cwd> <command> <silent|fires> <what>
commit_case() {
  local pl out
  n=$((n + 1))
  pl="$tmproot/cg$n.json"; out="$tmproot/cg$n.out"
  jq -n --arg c "$3" --arg cwd "$2" '{tool_input:{command:$c},cwd:$cwd}' > "$pl"
  runh "$out" "$2" "$pl" bash "$1/check-gate.sh"
  "$4" "$out" "check-gate: $5"
}
# stop_case <hooks-dir> <cwd> <silent|fires> <what> — dod.sh, then req-gate.sh
# in enforce mode, then req-gate.sh --stop, all from <cwd>.
stop_case() {
  local pl="$tmproot/stop.json" out
  printf '{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":false}' > "$pl"
  n=$((n + 1)); out="$tmproot/dod$n.out"
  runh "$out" "$2" "$pl" bash "$1/dod.sh"
  "$3" "$out" "dod: $4"
  n=$((n + 1)); out="$tmproot/rg$n.out"
  runh "$out" "$2" /dev/null bash "$1/req-gate.sh"
  "$3" "$out" "req-gate: $4"
  n=$((n + 1)); out="$tmproot/rgs$n.out"
  runh "$out" "$2" "$pl" bash "$1/req-gate.sh" --stop
  "$3" "$out" "req-gate --stop: $4"
}
# fix_case <hooks-dir> <repo> <ran|quiet> <what> — autofix.sh on an edit of
# <repo>/src/app.py; `ran` means the repository's ruff ran, `quiet` that it
# did not and the hook printed nothing.
fix_case() {
  local pl out
  n=$((n + 1))
  pl="$tmproot/fx$n.json"; out="$tmproot/fx$n.out"
  rm -f "$2/ruff-ran"
  jq -n --arg f "$2/src/app.py" '{tool_input:{file_path:$f},tool_response:{filePath:$f}}' > "$pl"
  runh "$out" "$tmproot" "$pl" bash "$1/autofix.sh"
  assert_rc 0 "$out"
  if [ "$3" = ran ]; then
    if [ -s "$2/ruff-ran" ]; then _test_pass "autofix ran the fixer: $4"
    else _test_fail "autofix did not run the fixer: $4"; fi
  else
    if [ ! -e "$2/ruff-ran" ]; then _test_pass "autofix left the file alone: $4"
    else _test_fail "autofix ran the fixer: $4"; fi
    silent "$out" "autofix: $4"
  fi
}

H="$repo/hooks"

req "successor repo: commit gate (check-gate.sh)"
commit_case "$H" "$v2"          "git commit -m x"                silent "committed marker"
commit_case "$H" "$v2/src/deep" "git commit -m x"                silent "committed marker, session in a subdirectory"
commit_case "$H" "$v1"          "git commit -m x"                fires  "no marker"
commit_case "$H" "$untr"        "git commit -m x"                fires  "untracked marker"
commit_case "$H" "$staged"      "git commit -m x"                fires  "staged, uncommitted marker"
commit_case "$H" "$nest1"       "git commit -m x"                fires  "nested repository without a marker inside a marked umbrella"
commit_case "$H" "$nest2"       "git commit -m x"                silent "nested repository with a marker inside an unmarked umbrella"
commit_case "$H" "$umb1"        "git commit -m x"                fires  "unmarked umbrella holding a marked nested repository"
# The repository the command lands on, not the session's.
commit_case "$H" "$v2"          "cd $v1 && git commit -m x"      fires  "session in a marked repository, cd into an unmarked one"
commit_case "$H" "$v2"          "git -C $v1 commit -m x"         fires  "session in a marked repository, git -C an unmarked one"
commit_case "$H" "$v1"          "cd $v2 && git commit -m x"      silent "session in an unmarked repository, cd into a marked one"
commit_case "$H" "$umb2"        "cd $nest1 && git commit -m x"   fires  "session in a marked umbrella, cd into its unmarked nested repository"
commit_case "$H" "$nest2"       "cd $umb1 && git commit -m x"    fires  "session in a marked nested repository, cd into its unmarked umbrella"

req "successor repo: Stop gates (dod.sh, req-gate.sh, req-gate.sh --stop)"
stop_case "$H" "$v2"          silent "committed marker"
stop_case "$H" "$v2/src/deep" silent "committed marker, from a subdirectory"
stop_case "$H" "$v1"          fires  "no marker"
stop_case "$H" "$untr"        fires  "untracked marker"
stop_case "$H" "$staged"      fires  "staged, uncommitted marker"
stop_case "$H" "$nest1"       fires  "nested repository without a marker inside a marked umbrella"
stop_case "$H" "$nest2"       silent "nested repository with a marker inside an unmarked umbrella"
stop_case "$H" "$umb1"        fires  "unmarked umbrella holding a marked nested repository"

req "successor repo: autofix (autofix.sh)"
fix_case "$H" "$v2"     quiet "committed marker"
fix_case "$H" "$v1"     ran   "no marker"
fix_case "$H" "$untr"   ran   "untracked marker"
fix_case "$H" "$staged" ran   "staged, uncommitted marker"
fix_case "$H" "$nest1"  ran   "nested repository without a marker inside a marked umbrella"
fix_case "$H" "$nest2"  quiet "nested repository with a marker inside an unmarked umbrella"

req "successor repo: mutation — the helper answers no, every silenced case fires"
mut="$tmproot/mut-hooks"
mkdir -p "$mut"
cp "$repo"/hooks/*.sh "$mut/"
if grep -q '^successor_repo()' "$mut/guard-lib.sh"; then
  printf '\nsuccessor_repo() { return 1; }\n' >> "$mut/guard-lib.sh"
  _test_pass "mutation applied: successor_repo always answers no in the hooks copy"
else
  _test_fail "mutation did not apply: no successor_repo() in guard-lib.sh"
fi
commit_case "$mut" "$v2"    "git commit -m x"             fires "mutated: committed marker"
commit_case "$mut" "$v1"    "cd $v2 && git commit -m x"   fires "mutated: cd into a marked repository"
commit_case "$mut" "$nest2" "git commit -m x"             fires "mutated: marked nested repository"
stop_case "$mut" "$v2"    fires "mutated: committed marker"
stop_case "$mut" "$nest2" fires "mutated: marked nested repository"
fix_case "$mut" "$v2"    ran "mutated: committed marker"
fix_case "$mut" "$nest2" ran "mutated: marked nested repository"

finish
