#!/bin/bash
# AI-Native SDLC — gate hardening (specs/gate-hardening). Every assertion below
# carries its REQ-ID literally, so requirement coverage stays grep-able.
#
#   REQ-GATE-001  a heredoc body is data: a command that only WRITES ABOUT a
#                 commit inside one is not gated.
#   REQ-GATE-002  `git` is matched as a command word, never as a path segment:
#                 `ls .git/hooks/pre-commit` is not gated, while
#                 `/usr/bin/git commit` and a quoted "git commit" still are.
#   REQ-GATE-003  `commit` is a whole word after whitespace: `--no-commit` is
#                 not gated, and `git log | grep commit` is not a commit.
#   REQ-GATE-004  check-gate.sh keeps its own clock — it reads its hook timeout
#                 from the user's settings, stops the checks before it, and
#                 BLOCKS, killing everything the checks started.
#   REQ-GATE-005  dod.sh does the same against its Stop entry's timeout.
#   REQ-GATE-006  the hooks snippet ships no push gate, symlinks venv, and
#                 names the deadline behaviour beside the budget; the Makefile
#                 templates name it too.
#   REQ-GATE-007  scripts/check-command-refs.sh resolves every `/name` a repo's
#                 instruction files cite and fails on one that resolves nowhere.
#   REQ-GATE-008  README's Known-gaps entry says the gate now keeps its own clock.
#   REQ-GATE-009  the policy forbids a bare yes/no question to the owner.
#
# Every fixture lives under a mktemp -d directory removed on exit, with HOME
# pointed at a throwaway directory; nothing here reads or writes the real
# ~/.claude. The two deadline cases sleep for real, so this file takes a little
# over ten seconds — the price of proving a kill rather than reading about one.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-gatehard.XXXXXX")
tmproot=$(cd "$tmproot" && pwd)
# shellcheck disable=SC2329  # invoked indirectly by the trap below
# The REQ-TOUCH-020 unwritable-counter case makes a directory read-only, so
# the modes are put back before the tree is removed.
cleanup() { chmod -R u+rwx "$tmproot" 2>/dev/null || true; rm -rf "$tmproot"; }
trap cleanup EXIT

gate="$repo/hooks/check-gate.sh"
dod="$repo/hooks/dod.sh"
refs="$repo/scripts/check-command-refs.sh"
snippet="$repo/settings/hooks-snippet.json"
readme="$repo/README.md"
policy="$repo/sdlc-policy.md"

ghome=$(mktemp -d "$tmproot/ghome.XXXXXX")   # no settings.json: harness defaults apply
# The requirement gate is installed, as install.sh leaves it: a missing one now
# blocks every commit (REQ-GATE-016), which is not what these cases test.
mkdir -p "$ghome/.claude/hooks"
cp "$repo/hooks/req-gate.sh" "$ghome/.claude/hooks/req-gate.sh"
witness="$tmproot/witness"

# gate_repo <dir> <check-body> — a throwaway git repo whose `make check` runs
# <check-body> (a shell line) after appending the repo's basename to $witness,
# so a run leaves a trace of WHERE it happened.
gate_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.name "SDLC Test"
  git -C "$1" config user.email "sdlc-test@example.invalid"
  printf 'check:\n\t@echo %s >> %s; %s\n' "$(basename "$1")" "$witness" "$2" > "$1/Makefile"
  echo x > "$1/src.py"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

# payload <command> <cwd> — the JSON the hook runner hands the gate.
payload() {
  jq -n --arg c "$1" --arg cwd "$2" '{tool_input:{command:$c},cwd:$cwd}'
}

# run_gate <outfile> <home> <payload-json> — drive check-gate.sh as the hook
# runner does: payload on stdin, HOME as given. Output and exit code land in
# <outfile> and <outfile>.rc.
run_gate() {
  local rc=0
  : > "$witness"
  printf '%s' "$3" | HOME="$2" bash "$gate" > "$1" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$1.rc"
}

# settings_with <home> <event> <script-name> <timeout> — a settings.json in
# <home>/.claude carrying one hook entry, the way install.sh's snippet would.
settings_with() {
  mkdir -p "$1/.claude"
  jq -n --arg ev "$2" --arg cmd "\"\$HOME/.claude/hooks/$3\"" --argjson t "$4" \
    '{hooks: {($ev): [{matcher: "Bash", hooks: [{type: "command", command: $cmd, timeout: $t}]}]}}' \
    > "$1/.claude/settings.json"
}

target="$tmproot/target"
gate_repo "$target" "exit 1"     # its checks FAIL: a gated command is blocked

# ===========================================================================
req "REQ-GATE-001"
# A command whose only mention of a commit sits inside a heredoc body is not a
# commit. The target's checks would fail, so a false positive shows as exit 2.
hd=$(printf 'cat > /dev/null <<'"'"'EOF'"'"'\nthe gate runs on git commit\nEOF\n')
out="$tmproot/heredoc.out"
run_gate "$out" "$ghome" "$(payload "$hd" "$target")"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"
# ...and the same words OUTSIDE a heredoc are still gated.
out="$tmproot/heredoc-control.out"
run_gate "$out" "$ghome" "$(payload 'git commit -m x' "$target")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"

# ===========================================================================
req "REQ-GATE-002"
# A path segment is not the git command.
out="$tmproot/path.out"
run_gate "$out" "$ghome" "$(payload 'ls -la .git/hooks/pre-commit' "$target")"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"
# A full path to the binary IS the git command.
out="$tmproot/binpath.out"
run_gate "$out" "$ghome" "$(payload '/usr/bin/git commit -m x' "$target")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
# A quoted invocation can reach eval; the gate fails closed on it.
out="$tmproot/quoted.out"
run_gate "$out" "$ghome" "$(payload 'eval "git commit -m x"' "$target")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
# A compound command still gates on the commit after the &&.
out="$tmproot/compound.out"
run_gate "$out" "$ghome" "$(payload "cd $target && git add -A && git commit -m x" "$target")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"

# ===========================================================================
req "REQ-GATE-003"
# `--no-commit` is an option, not the commit word.
out="$tmproot/nocommit.out"
run_gate "$out" "$ghome" "$(payload 'git merge --no-commit topic' "$target")"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"
# A pipe separates commands: `grep commit` after `git log |` is not a commit.
out="$tmproot/pipe.out"
run_gate "$out" "$ghome" "$(payload 'git log --oneline | grep commit' "$target")"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"
# A trailing separator after the word still counts.
out="$tmproot/semicolon.out"
run_gate "$out" "$ghome" "$(payload 'git commit -m x; echo done' "$target")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"

# ===========================================================================
req "REQ-GATE-004"
# A repo whose checks take six seconds, gated under a settings.json whose
# commit-gate entry carries a 32s timeout: the budget is 2s, so the gate must
# BLOCK, name both numbers, and kill the checks — the file the checks would
# have written at the end must never appear.
slow="$tmproot/slow"
late="$tmproot/late-write"
gate_repo "$slow" "sleep 6; echo late > $late; exit 0"
shome=$(mktemp -d "$tmproot/shome.XXXXXX")
settings_with "$shome" PreToolUse check-gate.sh 32
out="$tmproot/deadline.out"
run_gate "$out" "$shome" "$(payload 'git commit -m x' "$slow")"
assert_rc 2 "$out"
assert_fgrep 'budget of 2s' "$out"
assert_fgrep 'timeout is 32s' "$out"
assert_fgrep 'does NOT block' "$out"
sleep 6
if [ -e "$late" ]; then
  _test_fail "the checks outlived the gate: $late was written after the block"
else
  _test_pass "the checks were killed with the gate: $late never appeared"
fi
# Control: the same repo under an empty HOME (harness default 600 → budget 570)
# runs its checks to completion and allows.
quick="$tmproot/quick"
gate_repo "$quick" "sleep 1; exit 0"
out="$tmproot/deadline-control.out"
run_gate "$out" "$ghome" "$(payload 'git commit -m x' "$quick")"
assert_rc 0 "$out"
assert_grep '^quick$' "$witness"
# A settings.json with no commit-gate entry also means the default.
nhome=$(mktemp -d "$tmproot/nhome.XXXXXX")
mkdir -p "$nhome/.claude/hooks"
cp "$repo/hooks/req-gate.sh" "$nhome/.claude/hooks/req-gate.sh"
printf '{"hooks":{}}\n' > "$nhome/.claude/settings.json"
out="$tmproot/deadline-noentry.out"
run_gate "$out" "$nhome" "$(payload 'git commit -m x' "$quick")"
assert_rc 0 "$out"

# ===========================================================================
req "REQ-GATE-005"
# dod.sh: a dirty tree whose checks take six seconds, under a Stop entry with
# a 32s timeout, must refuse to let the turn end and name both numbers.
dslow="$tmproot/dslow"
dlate="$tmproot/dod-late-write"
gate_repo "$dslow" "sleep 6; echo late > $dlate; exit 0"
echo changed > "$dslow/src.py"          # dirty, and not docs-only
dhome=$(mktemp -d "$tmproot/dhome.XXXXXX")
settings_with "$dhome" Stop dod.sh 32
out="$tmproot/dod-deadline.out"
rc=0
( cd "$dslow" && printf '{}' | HOME="$dhome" bash "$dod" ) > "$out" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$out.rc"
assert_rc 2 "$out"
assert_fgrep 'CANNOT STOP' "$out"
assert_fgrep 'budget of 2s' "$out"
assert_fgrep 'timeout is 32s' "$out"
sleep 6
if [ -e "$dlate" ]; then
  _test_fail "dod.sh let the checks outlive it: $dlate was written after the block"
else
  _test_pass "dod.sh killed the checks with the gate: $dlate never appeared"
fi
# Control: a dirty tree whose checks pass quickly lets the turn end.
dquick="$tmproot/dquick"
gate_repo "$dquick" "exit 0"
echo changed > "$dquick/src.py"
out="$tmproot/dod-control.out"
rc=0
( cd "$dquick" && printf '{}' | HOME="$ghome" bash "$dod" ) > "$out" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$out.rc"
assert_rc 0 "$out"

# ===========================================================================
req "REQ-GATE-006"
assert_exit 0 jq -e . "$snippet"
# No push gate ships from the framework: push-equals-deploy is a repo fact.
# The snippet does carry permission rules since REQ-TOUCH-041 (the Gate 1
# stamp is the owner's act), so the clause "no permissions key" is read as
# its stated intent: no rule of any list may gate a push.
jq -r '.permissions // {} | to_entries[] | .value | if type == "array" then .[] else empty end' "$snippet" \
  > "$tmproot/perm-rules.txt"
assert_file "$tmproot/perm-rules.txt"
assert_no_grep 'push' "$tmproot/perm-rules.txt"
# venv is symlinked into worktrees alongside .venv and node_modules.
jq -r '.worktree.symlinkDirectories[]' "$snippet" > "$tmproot/symlinks.txt"
assert_grep '^venv$' "$tmproot/symlinks.txt"
assert_grep '^\.venv$' "$tmproot/symlinks.txt"
assert_grep '^node_modules$' "$tmproot/symlinks.txt"
# The comment names the deadline behaviour beside the budget.
jq -r '.["//"]' "$snippet" > "$tmproot/comment.txt"
assert_fgrep 'stops the checks 30 seconds before it' "$tmproot/comment.txt"
assert_fgrep 'BLOCKS the commit' "$tmproot/comment.txt"
# ...and the Stop and commit gates carry the same timeout, so one budget
# governs both.
jq -r '.hooks.PreToolUse[0].hooks[0].timeout' "$snippet" > "$tmproot/t-gate.txt"
jq -r '[.hooks.Stop[0].hooks[] | select(.command | test("dod")) | .timeout][0]' "$snippet" \
  > "$tmproot/t-dod.txt"
assert_exit 0 cmp -s "$tmproot/t-gate.txt" "$tmproot/t-dod.txt"
# The Makefile templates say the gate stops the checks itself.
for tmpl in Makefile.python Makefile.node Makefile.static; do
  assert_fgrep 'stops the checks' "$repo/templates/$tmpl"
done

# ===========================================================================
req "REQ-GATE-007"
# A repo whose CLAUDE.md cites a project command, an installed command, a
# built-in, a skill and a ghost: only the ghost is reported, and its line is
# named.
rrepo="$tmproot/refs-repo"
mkdir -p "$rrepo/.claude/commands" "$rrepo/.claude/skills/omega"
rhome=$(mktemp -d "$tmproot/rhome.XXXXXX")
mkdir -p "$rhome/.claude/commands"
printf 'installed\n' > "$rhome/.claude/commands/build.md"
printf 'project\n' > "$rrepo/.claude/commands/alpha.md"
# shellcheck disable=SC2016  # backticked names are the fixture text
printf '# rules\n\nRun `/alpha` then `/build`.\nOpen `/hooks` once.\nUse `/omega` for the skill.\nNever `/ghost`.\nA path like `/dev/null` is not a command.\n' \
  > "$rrepo/CLAUDE.md"
out="$tmproot/refs-ghost.out"
capture "$out" env HOME="$rhome" bash "$refs" "$rrepo"
assert_rc 1 "$out"
assert_grep '^CLAUDE\.md:6 /ghost resolves nowhere' "$out"
assert_no_grep '/alpha' "$out"
assert_no_grep '/build ' "$out"
assert_no_grep '/hooks' "$out"
assert_no_grep '/omega' "$out"
assert_no_grep '/dev' "$out"
# A command file citing a retired command is caught too.
# shellcheck disable=SC2016  # backticked names are the fixture text
printf 'Then run `/vanished`.\n' > "$rrepo/.claude/commands/alpha.md"
out="$tmproot/refs-cmd.out"
capture "$out" env HOME="$rhome" bash "$refs" "$rrepo"
assert_rc 1 "$out"
assert_grep 'commands/alpha\.md:1 /vanished resolves nowhere' "$out"
# The repo's own known-commands list vouches for a name, as data.
printf 'vanished\nghost\n' > "$rrepo/.claude/known-commands"
out="$tmproot/refs-known.out"
capture "$out" env HOME="$rhome" bash "$refs" "$rrepo"
assert_rc 0 "$out"
assert_grep '^command refs OK' "$out"
# No CLAUDE.md: nothing to scan is reported, never passed.
empty="$tmproot/refs-empty"
mkdir -p "$empty"
out="$tmproot/refs-empty.out"
capture "$out" env HOME="$rhome" bash "$refs" "$empty"
assert_rc 2 "$out"
assert_grep 'no CLAUDE\.md' "$out"

# ===========================================================================
req "REQ-GATE-010"
# `cd ~/repo && git commit` names the repo through the home directory. The gate
# must follow it — under the test HOME — and check THAT repo (its checks fail,
# so the block proves where the check ran), not the session cwd (whose checks
# pass).
tilde="$ghome/tilde-repo"
gate_repo "$tilde" "exit 1"
# shellcheck disable=SC2088,SC2016,SC2018  # unexpanded forms on purpose: the gate expands them
for form in '~/tilde-repo' '$HOME/tilde-repo' '${HOME}/tilde-repo'; do
  out="$tmproot/tilde-$(printf '%s' "$form" | tr -c 'a-z' _).out"
  run_gate "$out" "$ghome" "$(payload "cd $form && git commit -m x" "$quick")"
  assert_rc 2 "$out"
  assert_grep '^tilde-repo$' "$witness"
  assert_no_grep '^quick$' "$witness"
done

# ===========================================================================
req "REQ-GATE-011"
# (a) No jq on PATH: a commit-shaped payload is REFUSED, anything else allowed.
nojq="$tmproot/nojq-bin"
mkdir -p "$nojq"
for b in bash sh git make grep sed awk perl printf cat tr mktemp sleep rm; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$nojq/$b"
done
run_gate_path() {   # <outfile> <PATH> <payload>
  local rc=0
  : > "$witness"
  printf '%s' "$3" | PATH="$2" HOME="$ghome" bash "$gate" > "$1" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$1.rc"
}
out="$tmproot/nojq-commit.out"
run_gate_path "$out" "$nojq" "$(payload 'git commit -m x' "$target")"
assert_rc 2 "$out"
assert_fgrep 'jq is not on PATH' "$out"
assert_no_grep '.' "$witness"
out="$tmproot/nojq-other.out"
run_gate_path "$out" "$nojq" "$(payload 'ls -la' "$target")"
assert_rc 0 "$out"
# (b) a heredoc FED TO A SHELL is code, not data
out="$tmproot/heredoc-shell.out"
run_gate "$out" "$ghome" "$(payload "$(printf 'bash <<\047EOF\047\ngit commit -m x\nEOF\n')" "$target")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
# (c) a quote right after the word
out="$tmproot/bash-c.out"
run_gate "$out" "$ghome" "$(payload 'bash -c "git commit -m x"' "$target")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
# (d) a backslash-newline between the words
out="$tmproot/continuation.out"
run_gate "$out" "$ghome" "$(payload "$(printf 'git \\\\\n  commit -m x')" "$target")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"

# ===========================================================================
req "REQ-GATE-012"
# The LAST cd before the commit is the one that counts, on any line.
out="$tmproot/cd-last.out"
run_gate "$out" "$ghome" "$(payload "cd $quick && cd $target && git commit -m x" "$quick")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
assert_no_grep '^quick$' "$witness"
out="$tmproot/cd-twoline.out"
run_gate "$out" "$ghome" "$(payload "$(printf 'cd %s && make check\ncd %s && git commit -m x' "$quick" "$target")" "$quick")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
assert_no_grep '^quick$' "$witness"
# ...and a cd AFTER the commit says nothing about where it ran.
out="$tmproot/cd-after.out"
run_gate "$out" "$ghome" "$(payload "cd $target && git commit -m x && cd $quick" "$quick")"
assert_rc 2 "$out"
assert_grep '^target$' "$witness"
# bare $HOME expands like ~/
out="$tmproot/cd-home.out"
rc=0
: > "$witness"
# shellcheck disable=SC2016  # the literal $HOME is what the command text carries; the gate expands it
printf '%s' "$(payload 'cd $HOME && git commit -m x' "$quick")" | HOME="$tilde" bash "$gate" > "$out" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$out.rc"
assert_rc 2 "$out"
assert_grep '^tilde-repo$' "$witness"

# ===========================================================================
req "REQ-GATE-013"
# A script under docs/ is code: staging it does not skip the checks.
codedocs="$tmproot/codedocs"
gate_repo "$codedocs" "exit 1"
mkdir -p "$codedocs/docs"
echo x > "$codedocs/docs/generate.py"
git -C "$codedocs" add docs/generate.py
out="$tmproot/docs-code.out"
run_gate "$out" "$ghome" "$(payload 'git commit -m x' "$codedocs")"
assert_rc 2 "$out"
assert_grep '^codedocs$' "$witness"
# ...while prose by extension anywhere still skips them.
git -C "$codedocs" reset -q
mkdir -p "$codedocs/src"
echo note > "$codedocs/src/README.md"
git -C "$codedocs" add src/README.md
out="$tmproot/docs-prose.out"
run_gate "$out" "$ghome" "$(payload 'git commit -m x' "$codedocs")"
assert_rc 0 "$out"
assert_no_grep '.' "$witness"
# An unreadable Makefile refuses, in the gate's own words, at commit AND at Stop.
unread="$tmproot/unread"
gate_repo "$unread" "exit 0"
chmod 000 "$unread/Makefile"
out="$tmproot/unread-commit.out"
run_gate "$out" "$ghome" "$(payload 'git commit -m x' "$unread")"
assert_rc 2 "$out"
assert_fgrep 'read the Makefile' "$out"
echo changed > "$unread/src.py"
out="$tmproot/unread-dod.out"
rc=0
( cd "$unread" && printf '{}' | HOME="$ghome" bash "$dod" ) > "$out" 2>&1 || rc=$?
printf '%s\n' "$rc" > "$out.rc"
chmod 644 "$unread/Makefile"
assert_rc 2 "$out"
assert_fgrep 'Makefile cannot be read' "$out"
# A refusal on budget prints no stray shell error.
assert_no_grep 'No such file' "$tmproot/deadline.out"
assert_no_grep 'No such file' "$tmproot/dod-deadline.out"

# ===========================================================================
req "REQ-GATE-008"
# The Known-gaps entry keeps the mechanism (REQ-GAP-001/002 pin those words)
# and now says the gate keeps its own clock.
assert_fgrep 'keeps its own clock' "$readme"
assert_order "$readme" \
  'times out does NOT block' \
  'keeps its own clock'

# ===========================================================================
req "REQ-GATE-009"
assert_fgrep 'never a bare yes/no' "$policy"
# ...and a pile of pending items is walked one at a time, never handed over as a list;
# a testing session that ends with findings left offers another batch or ship-as-is.
assert_fgrep 'never handed over as a list' "$policy"
assert_fgrep 'ship as is' "$policy"

# ===========================================================================
# The Stop gate's own counter and the stop-evidence guard
# (specs/three-touch-points-phase-1: REQ-TOUCH-019, 020, 021, 022, 050).
# Every case sets SDLC_STOP_BLOCK_CAP and SDLC_GUARD_MODE itself: lib.sh's
# guards directory exists and is empty, so an unset mode would deny.

# run_dod <outfile> <dir> <dod-script> <payload> [VAR=value...] — drive a Stop
# hook as the client does: payload on stdin, cwd <dir>, HOME the gate home.
run_dod() {
  local out="$1" dir="$2" script="$3" pl="$4" rc=0
  shift 4
  ( cd "$dir" && printf '%s' "$pl" | env HOME="$ghome" "$@" bash "$script" ) > "$out" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$out.rc"
}

# set_check <dir> <shell-line> — the fixture's `make check` runs <shell-line>.
set_check() { printf 'check:\n\t@%s\n' "$2" > "$1/Makefile"; }

# stop_count <key> — the Stop gate's block count for <key>; 0 when no file.
stop_count() {
  local f="$SDLC_GUARDS_DIR/stop/$1.count" v
  if [ -f "$f" ]; then
    v=$(tr -d '[:space:]' < "$f")
    printf '%s\n' "${v:-0}"
  else
    printf '0\n'
  fi
}

# check_count <key> <expected> — assert the block count.
check_count() {
  local got
  got=$(stop_count "$1")
  if [ "$got" = "$2" ]; then
    _test_pass "stop count for $1 is $2"
  else
    _test_fail "stop count for $1: expected $2, got $got"
  fi
}

# mutant_dir — a directory holding a copy of dod.sh and its guard library.
mutant_dir() {
  local m
  m=$(mktemp -d "$tmproot/mutant.XXXXXX")
  cp "$repo/hooks/dod.sh" "$repo/hooks/guard-lib.sh" "$m/"
  printf '%s' "$m"
}

# assert_mutated <copy> — the mutation really changed the file; an unchanged
# copy would make the red case below prove nothing.
assert_mutated() {
  if cmp -s "$1" "$dod"; then
    _test_fail "the mutation did not change $1"
  else
    _test_pass "mutation applied: $1"
  fi
}

S6=(SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny)

# ---------------------------------------------------------------------------
req "REQ-TOUCH-019"
# stop_hook_active no longer allows by itself: a dirty red tree on the retry
# is still refused, and the same tree made green is allowed.
r19="$tmproot/r19"
gate_repo "$r19" "exit 1"
echo changed > "$r19/src.py"
out="$tmproot/t019-red.out"
run_dod "$out" "$r19" "$dod" '{"stop_hook_active":true,"session_id":"s19"}' "${S6[@]}"
assert_rc 2 "$out"
assert_fgrep 'CANNOT STOP' "$out"
set_check "$r19" "exit 0"
out="$tmproot/t019-green.out"
run_dod "$out" "$r19" "$dod" '{"stop_hook_active":true,"session_id":"s19"}' "${S6[@]}"
assert_rc 0 "$out"
# Mutation: put the old early allow back; the red retry must now be allowed,
# which is what the case above would miss if the re-check were gone.
set_check "$r19" "exit 1"
m19=$(mutant_dir)
awk '{ print } /^input=\$\(cat\)$/ { print "if command -v jq >/dev/null 2>&1 && echo \"$input\" | jq -e '"'"'.stop_hook_active == true'"'"' > /dev/null 2>&1; then exit 0; fi" }' \
  "$repo/hooks/dod.sh" > "$m19/dod.sh"
assert_mutated "$m19/dod.sh"
out="$tmproot/t019-mutant.out"
run_dod "$out" "$r19" "$m19/dod.sh" '{"stop_hook_active":true,"session_id":"s19m"}' "${S6[@]}"
assert_rc 0 "$out"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-020"
r20="$tmproot/r20"
gate_repo "$r20" "exit 1"
echo changed > "$r20/src.py"
caplog="$SDLC_GUARDS_DIR/stop/cap.log"
for i in 1 2 3; do
  out="$tmproot/t020-block$i.out"
  run_dod "$out" "$r20" "$dod" '{"session_id":"s20"}' SDLC_STOP_BLOCK_CAP=3 SDLC_GUARD_MODE=deny
  assert_rc 2 "$out"
done
check_count s20 3
before=0
[ -f "$caplog" ] && before=$(wc -l < "$caplog" | tr -d ' ')
out="$tmproot/t020-cap.out"
run_dod "$out" "$r20" "$dod" '{"session_id":"s20"}' SDLC_STOP_BLOCK_CAP=3 SDLC_GUARD_MODE=deny
assert_rc 0 "$out"
assert_fgrep 'UNVERIFIED' "$out"
assert_fgrep 'block cap (3)' "$out"
after=0
[ -f "$caplog" ] && after=$(wc -l < "$caplog" | tr -d ' ')
if [ "$after" -eq $((before + 1)) ]; then
  _test_pass "cap.log gained one line"
else
  _test_fail "cap.log: expected $((before + 1)) lines, got $after"
fi
assert_grep 's20$' "$caplog"
check_count s20 0
# Another session key is counted on its own.
out="$tmproot/t020-s20.out"
run_dod "$out" "$r20" "$dod" '{"session_id":"s20"}' SDLC_STOP_BLOCK_CAP=3 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
out="$tmproot/t020-other.out"
run_dod "$out" "$r20" "$dod" '{"session_id":"s20-other"}' SDLC_STOP_BLOCK_CAP=3 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
check_count s20 1
check_count s20-other 1
# No session_id, and one that is not a safe file name, both count as `unknown`.
rm -f "$SDLC_GUARDS_DIR/stop/unknown.count"
out="$tmproot/t020-nokey.out"
run_dod "$out" "$r20" "$dod" '{}' SDLC_STOP_BLOCK_CAP=3 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
check_count unknown 1
out="$tmproot/t020-badkey.out"
run_dod "$out" "$r20" "$dod" '{"session_id":"../escape"}' SDLC_STOP_BLOCK_CAP=3 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
check_count unknown 2
assert_exit 1 test -e "$SDLC_GUARDS_DIR/escape.count"
# A cap that is not a positive integer falls back to 6: six blocks, then allow.
for cap in abc 0; do
  for i in 1 2 3 4 5 6; do
    out="$tmproot/t020-def-$cap-$i.out"
    run_dod "$out" "$r20" "$dod" "{\"session_id\":\"s20def$cap\"}" SDLC_STOP_BLOCK_CAP=$cap SDLC_GUARD_MODE=deny
    assert_rc 2 "$out"
  done
  check_count "s20def$cap" 6
  out="$tmproot/t020-def-$cap-7.out"
  run_dod "$out" "$r20" "$dod" "{\"session_id\":\"s20def$cap\"}" SDLC_STOP_BLOCK_CAP=$cap SDLC_GUARD_MODE=deny
  assert_rc 0 "$out"
  assert_fgrep 'block cap (6)' "$out"
done
# A counter that cannot be written is the cap already reached: otherwise every
# stop counts as 0, the UNVERIFIED allow never fires, and only the client's
# own silent cap ends the loop. Allowed loudly, naming the counter path.
g20u="$tmproot/g20u"
mkdir -p "$g20u/stop"
chmod 555 "$g20u/stop"
out="$tmproot/t020-unwritable.out"
run_dod "$out" "$r20" "$dod" '{"session_id":"s20u"}' SDLC_GUARDS_DIR="$g20u" SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
chmod 755 "$g20u/stop"
assert_rc 0 "$out"
assert_fgrep 'CANNOT STOP' "$out"
assert_fgrep 'UNVERIFIED' "$out"
assert_fgrep "$g20u/stop" "$out"
assert_fgrep 'could not be written' "$out"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-010"
# A machine where install.sh never ran: the guards directory is absent. The
# Stop gate's counter must not create it bare, or the first guard to fire
# would find it present with no clock and deny (REQ-TOUCH-046) instead of
# warning. A Stop that blocks creates the directory AND every guard's clock.
g10="$tmproot/g10-absent"
r10="$tmproot/r10"
gate_repo "$r10" "exit 1"
echo changed > "$r10/src.py"
out="$tmproot/t010-stop.out"
run_dod "$out" "$r10" "$dod" '{"session_id":"s10"}' SDLC_GUARDS_DIR="$g10" SDLC_STOP_BLOCK_CAP=6
assert_rc 2 "$out"
assert_fgrep 'CANNOT STOP' "$out"
for g in gate1-stamp evidence-merge stop-evidence; do
  assert_file "$g10/$g.since"
done
# A later commit-gate guard (gate1-stamp: a commit on sdlc/<x> with no
# specs/<x>/) then warns instead of denying.
c10="$tmproot/c10"
gate_repo "$c10" "exit 0"
git -C "$c10" checkout -q -b sdlc/nospec
echo more > "$c10/src.py"
git -C "$c10" add -A
out="$tmproot/t010-commit.out"
SDLC_GUARDS_DIR="$g10" run_gate "$out" "$ghome" "$(payload 'git commit -m x' "$c10")"
assert_rc 0 "$out"
assert_fgrep 'WARN (gate1-stamp' "$out"
# Control: the same commit in deny mode is refused, so the case above did
# reach the guard.
out="$tmproot/t010-commit-deny.out"
SDLC_GUARDS_DIR="$g10" SDLC_GUARD_MODE=deny run_gate "$out" "$ghome" "$(payload 'git commit -m x' "$c10")"
assert_rc 2 "$out"
assert_fgrep 'gate1-stamp' "$out"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-050"
# Three different allow paths each reset the count: green checks, a docs-only
# tree, a clean tree. One trap, not one reset per path.
r50="$tmproot/r50"
gate_repo "$r50" "exit 1"
# block_twice <expected> — two refused stops for s50; the count is then <expected>.
block_twice() {
  echo changed > "$r50/src.py"
  set_check "$r50" "exit 1"
  run_dod "$tmproot/t050-b1.out" "$r50" "$dod" '{"session_id":"s50"}' "${S6[@]}"
  assert_rc 2 "$tmproot/t050-b1.out"
  run_dod "$tmproot/t050-b2.out" "$r50" "$dod" '{"session_id":"s50"}' "${S6[@]}"
  assert_rc 2 "$tmproot/t050-b2.out"
  check_count s50 "$1"
}
# (a) the checks pass
block_twice 2
set_check "$r50" "exit 0"
out="$tmproot/t050-green.out"
run_dod "$out" "$r50" "$dod" '{"session_id":"s50"}' "${S6[@]}"
assert_rc 0 "$out"
check_count s50 0
# ...and the next red run starts again from one.
set_check "$r50" "exit 1"
out="$tmproot/t050-again.out"
run_dod "$out" "$r50" "$dod" '{"session_id":"s50"}' "${S6[@]}"
assert_rc 2 "$out"
check_count s50 1
# (b) a docs-only dirty tree (on top of the one block just above)
block_twice 3
git -C "$r50" checkout -q -- src.py Makefile
echo note > "$r50/notes.md"
out="$tmproot/t050-docs.out"
run_dod "$out" "$r50" "$dod" '{"session_id":"s50"}' "${S6[@]}"
assert_rc 0 "$out"
check_count s50 0
rm -f "$r50/notes.md"
# (c) a clean tree
block_twice 2
git -C "$r50" checkout -q -- src.py Makefile
out="$tmproot/t050-clean.out"
run_dod "$out" "$r50" "$dod" '{"session_id":"s50"}' "${S6[@]}"
assert_rc 0 "$out"
check_count s50 0

# ---------------------------------------------------------------------------
# A feature-branch fixture for the stop-evidence guard.
demo_feat=STOPDEMO
demo_id="REQ-${demo_feat}-001"
gc() { local dir="$1"; shift; git -C "$dir" -c core.hooksPath=/dev/null "$@"; }
# ev_repo <dir> — a committed repo on sdlc/demo with specs/demo, every task
# box ticked, its own sdlc-state.sh, cheap check and test targets, and no
# evidence.json yet.
ev_repo() {
  local d="$1"
  mkdir -p "$d/specs/demo" "$d/scripts" "$d/hooks" "$d/tests"
  git -C "$d" init -q
  git -C "$d" config user.name "SDLC Test"
  git -C "$d" config user.email "sdlc-test@example.invalid"
  cp "$repo/scripts/sdlc-state.sh" "$d/scripts/"
  cp "$repo/hooks/guard-lib.sh" "$repo/hooks/req-gate.sh" "$d/hooks/"
  printf '# Requirements — demo\n\n%s  WHEN a thing happens THE SYSTEM SHALL do it.\n              verify: unit\n' \
    "$demo_id" > "$d/specs/demo/requirements.md"
  printf '# Tasks — demo\n- [x] T1: one [%s]\n' "$demo_id" > "$d/specs/demo/tasks.md"
  printf '# covers %s\n' "$demo_id" > "$d/tests/test_demo.sh"
  printf 'check:\n\t@sh ./check.sh\n\ntest:\n\t@sh ./test.sh\n' > "$d/Makefile"
  printf 'exit 0\n' > "$d/check.sh"
  printf 'exit 0\n' > "$d/test.sh"
  echo v1 > "$d/src.py"
  gc "$d" add -A
  gc "$d" commit -qm init
  gc "$d" checkout -q -b sdlc/demo
}
commit_all() { gc "$1" add -A && gc "$1" commit -qm "$2"; }

# ---------------------------------------------------------------------------
req "REQ-TOUCH-021"
r21="$tmproot/r21"
ev_repo "$r21"
# A clean tree with no evidence: refused (so the guard sits before the
# clean-tree allow), naming the command that produces evidence.
out="$tmproot/t021-none.out"
run_dod "$out" "$r21" "$dod" '{"session_id":"s21a"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
assert_fgrep 'sdlc-state.sh evidence demo' "$out"
assert_fgrep 'none' "$out"
# Warn mode: allowed, the warning on stderr and a line in the guard's log.
out="$tmproot/t021-warn.out"
run_dod "$out" "$r21" "$dod" '{"session_id":"s21b"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=warn
assert_rc 0 "$out"
assert_fgrep 'WARN (stop-evidence' "$out"
assert_grep 'sdlc/demo' "$SDLC_GUARDS_DIR/stop-evidence.log"
# No state script anywhere: refused, naming both places looked.
r21n="$tmproot/r21n"
ev_repo "$r21n"
git -C "$r21n" rm -q scripts/sdlc-state.sh
gc "$r21n" commit -qm "no state script"
out="$tmproot/t021-noscript.out"
run_dod "$out" "$r21n" "$dod" '{"session_id":"s21n"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
assert_fgrep "$r21n/scripts/sdlc-state.sh" "$out"
assert_fgrep "$ghome/.claude/scripts/sdlc-state.sh" "$out"
# Green, current evidence, committed: allowed.
( cd "$r21" && bash scripts/sdlc-state.sh evidence demo ) > "$tmproot/t021-ev.out" 2>&1
commit_all "$r21" "evidence"
out="$tmproot/t021-green.out"
run_dod "$out" "$r21" "$dod" '{"session_id":"s21c"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 0 "$out"
assert_no_grep 'stop-evidence' "$out"
# A code change committed after it: stale.
echo v2 > "$r21/src.py"
commit_all "$r21" "code change"
out="$tmproot/t021-stale.out"
run_dod "$out" "$r21" "$dod" '{"session_id":"s21d"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
assert_fgrep 'stale' "$out"
assert_fgrep 'sdlc-state.sh evidence demo' "$out"
# Red evidence, committed: refused.
printf 'exit 1\n' > "$r21/test.sh"
( cd "$r21" && bash scripts/sdlc-state.sh evidence demo ) > "$tmproot/t021-evr.out" 2>&1
commit_all "$r21" "red evidence"
out="$tmproot/t021-red.out"
run_dod "$out" "$r21" "$dod" '{"session_id":"s21e"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
assert_fgrep 'red' "$out"
# A hand-edited evidence.json, committed: invalid.
ef="$r21/specs/demo/evidence.json"
jq '.test.rc = 0' "$ef" > "$ef.tmp" && mv "$ef.tmp" "$ef"
commit_all "$r21" "hand edit"
out="$tmproot/t021-invalid.out"
run_dod "$out" "$r21" "$dod" '{"session_id":"s21f"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
assert_fgrep 'invalid' "$out"
# Mutation: move the guard below the clean-tree allow; the clean no-evidence
# tree must now be allowed, which the first case above would then miss.
m21=$(mutant_dir)
awk '/^stop_evidence_guard$/ { next } /^# Docs-only changes/ { print "stop_evidence_guard" } { print }' \
  "$repo/hooks/dod.sh" > "$m21/dod.sh"
assert_mutated "$m21/dod.sh"
r21m="$tmproot/r21m"
ev_repo "$r21m"
out="$tmproot/t021-mutant-control.out"
run_dod "$out" "$r21m" "$dod" '{"session_id":"s21m"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
out="$tmproot/t021-mutant.out"
run_dod "$out" "$r21m" "$m21/dod.sh" '{"session_id":"s21m2"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 0 "$out"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-022"
# An open, claimed or parked box: the guard is not evaluated.
r22="$tmproot/r22"
ev_repo "$r22"
for box in ' ' '~' '!'; do
  printf '# Tasks — demo\n- [x] T1: one [%s]\n- [%s] T2: two\n' "$demo_id" "$box" > "$r22/specs/demo/tasks.md"
  commit_all "$r22" "box $box"
  out="$tmproot/t022-box-$(printf '%s' "$box" | tr ' ~!' 'otp').out"
  run_dod "$out" "$r22" "$dod" '{"session_id":"s22"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
  assert_rc 0 "$out"
  assert_no_grep 'stop-evidence' "$out"
done
# Every box ticked again, but not exactly a feature branch: no guard.
printf '# Tasks — demo\n- [x] T1: one [%s]\n' "$demo_id" > "$r22/specs/demo/tasks.md"
commit_all "$r22" "all ticked"
for br in sdlc/demo-T1 main-line sdlc/dem; do
  gc "$r22" checkout -q -B "$br"
  out="$tmproot/t022-branch-$(printf '%s' "$br" | tr '/' '_').out"
  run_dod "$out" "$r22" "$dod" '{"session_id":"s22"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
  assert_rc 0 "$out"
  assert_no_grep 'stop-evidence' "$out"
done
# A feature with no tasks.md: no guard.
gc "$r22" checkout -q sdlc/demo
git -C "$r22" rm -q specs/demo/tasks.md
gc "$r22" commit -qm "no tasks"
out="$tmproot/t022-notasks.out"
run_dod "$out" "$r22" "$dod" '{"session_id":"s22"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 0 "$out"
assert_no_grep 'stop-evidence' "$out"
# Control: the same fixture with the tasks restored is guarded.
git -C "$r22" checkout -q HEAD~1 -- specs/demo/tasks.md
gc "$r22" commit -qm "tasks back"
out="$tmproot/t022-control.out"
run_dod "$out" "$r22" "$dod" '{"session_id":"s22c"}' SDLC_STOP_BLOCK_CAP=6 SDLC_GUARD_MODE=deny
assert_rc 2 "$out"
assert_fgrep 'stop-evidence' "$out"

finish
