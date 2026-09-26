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
cleanup() { rm -rf "$tmproot"; }
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
jq -r '.permissions // {} | keys[]' "$snippet" > "$tmproot/perm-keys.txt"
assert_no_grep '.' "$tmproot/perm-keys.txt"
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

finish
