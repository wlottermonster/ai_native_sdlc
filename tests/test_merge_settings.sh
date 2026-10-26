#!/bin/bash
# AI-Native SDLC — scripts/merge-settings.sh prints ~/.claude/settings.json with
# the hooks snippet merged in, and never writes the file itself. The owner reads
# the output and moves it into place; a session cannot, and this script must
# not pretend to.
#
# What is proven here, each by running the script against throwaway files:
#   - an entry the owner already has (a custom safety hook) survives the merge;
#   - every snippet entry is added exactly once, and a second run over the
#     merged output changes nothing (idempotent);
#   - existing top-level values are never overwritten by the snippet's;
#   - invalid JSON in either input is refused with exit 1 and no output;
#   - a missing settings file is treated as an empty object;
#   - the settings file is byte-for-byte unchanged afterwards.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

merge="$repo/scripts/merge-settings.sh"
snippet="$repo/settings/hooks-snippet.json"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-merge.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# cmds <json-file> <jq-path> <outfile> — every hook command under one event.
cmds() {
  jq -r "[$2[]?.hooks[]?.command] | .[]" "$1" > "$3" 2>/dev/null || : > "$3"
}

# An owner's settings: a preference, a worktree key with its own value, and a
# PreToolUse safety hook the framework knows nothing about.
settings="$tmpdir/settings.json"
cat > "$settings" <<'JSON'
{
  "theme": "light",
  "worktree": { "baseRef": "fresh" },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "$HOME/.claude/hooks/confine.sh", "timeout": 5 } ]
      }
    ]
  }
}
JSON
cp "$settings" "$tmpdir/settings.before"

# ---------------------------------------------------------------------------
req "merge-settings: the script exists and is executable"
assert_file "$merge"
if [ -x "$merge" ]; then _test_pass "executable: $merge"; else _test_fail "not executable: $merge"; fi

# ---------------------------------------------------------------------------
req "merge-settings: existing entries survive, snippet entries are added"
out="$tmpdir/merged.json"
capture "$out" bash "$merge" --snippet "$snippet" "$settings"
assert_rc 0 "$out"
assert_exit 0 jq -e . "$out"

# The owner's own hook is still there, beside the commit gate.
cmds "$out" .hooks.PreToolUse "$tmpdir/pre.txt"
assert_fgrep 'confine.sh' "$tmpdir/pre.txt"
assert_fgrep 'check-gate.sh' "$tmpdir/pre.txt"
# Every event the snippet registers is present.
jq -r '.hooks | keys[]' "$out" > "$tmpdir/events.txt" 2>/dev/null
for ev in SessionStart PreToolUse PostToolUse Stop; do
  assert_grep "^$ev\$" "$tmpdir/events.txt"
done
# Existing top-level values win; missing ones are added.
jq -r '.theme' "$out" > "$tmpdir/theme.txt" 2>/dev/null
assert_grep '^light$' "$tmpdir/theme.txt"
jq -r '.worktree.baseRef' "$out" > "$tmpdir/baseref.txt" 2>/dev/null
assert_grep '^fresh$' "$tmpdir/baseref.txt"
jq -r '.worktree.symlinkDirectories | length' "$out" > "$tmpdir/symlinks.txt" 2>/dev/null
assert_grep '^[1-9][0-9]*$' "$tmpdir/symlinks.txt"
# The snippet's comment key is documentation for the reader, not a setting.
jq -r 'has("//")' "$out" > "$tmpdir/comment.txt" 2>/dev/null
assert_grep '^false$' "$tmpdir/comment.txt"

# ---------------------------------------------------------------------------
req "merge-settings: nothing is written"
if cmp -s "$tmpdir/settings.before" "$settings"; then
  _test_pass "settings file byte-unchanged"
else
  _test_fail "settings file was modified"
fi

# ---------------------------------------------------------------------------
req "merge-settings: idempotent, each command once, a second run changes nothing"
jq -r '[.hooks[][].hooks[].command] | group_by(.) | map(length) | max' "$out" \
  > "$tmpdir/maxdup.txt" 2>/dev/null
assert_grep '^1$' "$tmpdir/maxdup.txt"
cp "$out" "$tmpdir/merged-once.json"
out2="$tmpdir/merged2.json"
capture "$out2" bash "$merge" --snippet "$snippet" "$tmpdir/merged-once.json"
assert_rc 0 "$out2"
if [ -s "$out2" ] && [ "$(jq -S . "$out" 2>/dev/null)" = "$(jq -S . "$out2" 2>/dev/null)" ]; then
  _test_pass "second run is identical"
else
  _test_fail "second run changed the merge"
fi

# A partly-merged Stop entry (dod.sh present, req-gate missing) gains only the
# missing command, never a second dod.sh.
cat > "$tmpdir/partial.json" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\"$HOME/.claude/hooks/dod.sh\"", "timeout": 600 } ] } ] } }
JSON
out3="$tmpdir/merged3.json"
capture "$out3" bash "$merge" --snippet "$snippet" "$tmpdir/partial.json"
assert_rc 0 "$out3"
cmds "$out3" .hooks.Stop "$tmpdir/stop.txt"
count_into "$tmpdir/stop.txt" 'dod\.sh' "$tmpdir/dodcount.txt"
assert_grep '^1$' "$tmpdir/dodcount.txt"
assert_grep 'req-gate\.sh' "$tmpdir/stop.txt"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-033"
# Two SessionStart entries with different matchers both survive the merge: an
# owner who already has the engine-map entry gains the compact entry beside it,
# each with its own matcher, and nothing is duplicated on a second run.
cat > "$tmpdir/ss-only.json" <<'JSON'
{ "hooks": { "SessionStart": [ { "matcher": "startup|resume|clear", "hooks": [ { "type": "command", "command": "\"$HOME/.claude/hooks/session-engines.sh\"", "timeout": 10 } ] } ] } }
JSON
out7="$tmpdir/merged7.json"
capture "$out7" bash "$merge" --snippet "$snippet" "$tmpdir/ss-only.json"
assert_rc 0 "$out7"
jq -r '.hooks.SessionStart[] | "\(.matcher // "")\t\([.hooks[].command] | join(" "))"' "$out7" \
  > "$tmpdir/ss-entries.txt" 2>/dev/null
count_into "$tmpdir/ss-entries.txt" '.' "$tmpdir/ss-count.txt"
assert_grep '^2$' "$tmpdir/ss-count.txt"
assert_grep '^startup[|]resume[|]clear	.*session-engines\.sh' "$tmpdir/ss-entries.txt"
assert_grep '^compact	.*compact-policy\.sh' "$tmpdir/ss-entries.txt"
cmds "$out7" .hooks.SessionStart "$tmpdir/ss7.txt"
count_into "$tmpdir/ss7.txt" 'session-engines\.sh' "$tmpdir/se-count.txt"
assert_grep '^1$' "$tmpdir/se-count.txt"
# An owner who already registered the compact entry does not get a second one.
out8="$tmpdir/merged8.json"
capture "$out8" bash "$merge" --snippet "$snippet" "$out7"
assert_rc 0 "$out8"
cmds "$out8" .hooks.SessionStart "$tmpdir/ss8.txt"
count_into "$tmpdir/ss8.txt" 'compact-policy\.sh' "$tmpdir/cp-count.txt"
assert_grep '^1$' "$tmpdir/cp-count.txt"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-041"
# The snippet carries ask rules for the Gate 1 stamp: the stamp command, and
# Edit/Write on a feature's state.json. Only that the rules are carried is
# claimed here; that the client raises a prompt is not something a test sees.
capture "$tmpdir/snip-valid.out" jq -e . "$snippet"
assert_rc 0 "$tmpdir/snip-valid.out"
jq -r '.permissions.ask[]?' "$snippet" > "$tmpdir/snip-ask.txt" 2>/dev/null
assert_fgrep 'Bash(*sdlc-state.sh stamp *)' "$tmpdir/snip-ask.txt"
# The rule must discriminate, not just be spelled right: the stamp verb with
# an argument prompts; stamp-state (the first thing an unattended /build runs
# for every feature) and status must not, or an overnight build stalls at a
# prompt. Each Bash(...) ask rule's glob is matched against the commands the
# way the client applies a trailing-wildcard rule.
stamp_cmd="bash ~/.claude/scripts/sdlc-state.sh stamp demo-feature"
free_cmds=("bash ~/.claude/scripts/sdlc-state.sh stamp-state demo-feature"
           "bash ~/.claude/scripts/sdlc-state.sh status demo-feature")
stamp_hits=0
free_hits=""
while IFS= read -r rule; do
  case "$rule" in Bash\(*\)) ;; *) continue ;; esac
  glob=${rule#Bash(}
  glob=${glob%)}
  # shellcheck disable=SC2053 # the right-hand side is a glob on purpose
  if [[ $stamp_cmd == $glob ]]; then stamp_hits=$((stamp_hits + 1)); fi
  for c in "${free_cmds[@]}"; do
    # shellcheck disable=SC2053
    if [[ $c == $glob ]]; then free_hits="$free_hits [$rule ~ $c]"; fi
  done
done < "$tmpdir/snip-ask.txt"
if [ "$stamp_hits" -ge 1 ]; then
  _test_pass "an ask rule matches: $stamp_cmd"
else
  _test_fail "no ask rule matches: $stamp_cmd"
fi
if [ -z "$free_hits" ]; then
  _test_pass "no ask rule matches stamp-state or status"
else
  _test_fail "ask rule matches a prompt-free command:$free_hits"
fi
assert_grep '^Edit\(.*specs/[*]/state\.json\)$' "$tmpdir/snip-ask.txt"
assert_grep '^Write\(.*specs/[*]/state\.json\)$' "$tmpdir/snip-ask.txt"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-042"
# (a) Settings that already have ask/allow lists and other permissions keys:
# the ask list becomes the union, allow and defaultMode are untouched.
cat > "$tmpdir/perm.json" <<'JSON'
{ "permissions": { "ask": ["Bash(git push*)"], "allow": ["Read"], "defaultMode": "acceptEdits", "additionalDirectories": ["../shared"] } }
JSON
perm_out="$tmpdir/perm-merged.json"
capture "$perm_out" bash "$merge" --snippet "$snippet" "$tmpdir/perm.json"
assert_rc 0 "$perm_out"
jq -r '.permissions.ask[]' "$perm_out" > "$tmpdir/perm-ask.txt" 2>/dev/null
assert_fgrep 'Bash(git push*)' "$tmpdir/perm-ask.txt"
while IFS= read -r rule; do
  assert_fgrep "$rule" "$tmpdir/perm-ask.txt"
done < "$tmpdir/snip-ask.txt"
# Existing strings first, then the snippet's, each once.
head -n 1 "$tmpdir/perm-ask.txt" > "$tmpdir/perm-first.txt"
assert_fgrep 'Bash(git push*)' "$tmpdir/perm-first.txt"
count_into "$tmpdir/perm-ask.txt" '.' "$tmpdir/perm-askcount.txt"
assert_grep "^$(( $(wc -l < "$tmpdir/snip-ask.txt") + 1 ))\$" "$tmpdir/perm-askcount.txt"
jq -c '.permissions.allow' "$perm_out" > "$tmpdir/perm-allow.txt" 2>/dev/null
assert_grep '^\["Read"\]$' "$tmpdir/perm-allow.txt"
jq -r '.permissions.defaultMode, (.permissions.additionalDirectories | join(","))' "$perm_out" \
  > "$tmpdir/perm-other.txt" 2>/dev/null
assert_grep '^acceptEdits$' "$tmpdir/perm-other.txt"
assert_grep '^\.\./shared$' "$tmpdir/perm-other.txt"

# (b) Settings with no permissions at all: the snippet's list appears.
printf '{ "theme": "dark" }\n' > "$tmpdir/noperm.json"
noperm_out="$tmpdir/noperm-merged.json"
capture "$noperm_out" bash "$merge" --snippet "$snippet" "$tmpdir/noperm.json"
assert_rc 0 "$noperm_out"
jq -r '.permissions.ask[]' "$noperm_out" > "$tmpdir/noperm-ask.txt" 2>/dev/null
if cmp -s "$tmpdir/snip-ask.txt" "$tmpdir/noperm-ask.txt"; then
  _test_pass "no permissions: the snippet's ask list is added as it is"
else
  _test_fail "no permissions: the merged ask list differs from the snippet's"
fi

# (c) Settings already holding one of the snippet's rules: it is kept once.
held=$(head -n 1 "$tmpdir/snip-ask.txt")
jq -n --arg r "$held" '{permissions: {ask: [$r, "Bash(git push*)"]}}' > "$tmpdir/held.json"
held_out="$tmpdir/held-merged.json"
capture "$held_out" bash "$merge" --snippet "$snippet" "$tmpdir/held.json"
assert_rc 0 "$held_out"
jq --arg r "$held" '[.permissions.ask[] | select(. == $r)] | length' "$held_out" \
  > "$tmpdir/held-count.txt" 2>/dev/null
assert_grep '^1$' "$tmpdir/held-count.txt"
jq -r '.permissions.ask[]' "$held_out" > "$tmpdir/held-ask.txt" 2>/dev/null
assert_fgrep 'Bash(git push*)' "$tmpdir/held-ask.txt"

# (d) Merging the merged output again changes nothing.
perm_out2="$tmpdir/perm-merged2.json"
capture "$perm_out2" bash "$merge" --snippet "$snippet" "$perm_out"
assert_rc 0 "$perm_out2"
if [ -s "$perm_out2" ] && [ "$(jq -S . "$perm_out" 2>/dev/null)" = "$(jq -S . "$perm_out2" 2>/dev/null)" ]; then
  _test_pass "permissions: a second merge is identical"
else
  _test_fail "permissions: a second merge changed the output"
fi

# Mutation: "take the snippet's list" — the union expression in a copy of the
# script is replaced by the snippet's list alone. Case (a) must then lose the
# owner's Bash(git push*), proving the assertions above observe the union and
# not merely that an ask key exists.
# shellcheck disable=SC2016  # a jq expression, not shell: no expansion wanted
union='reduce $s.permissions[$pk][] as $r (.[$pk] // []; if index([$r]) then . else . + [$r] end)'
mutant="$tmpdir/merge-mutant.sh"
orig_src=$(cat "$merge")
# shellcheck disable=SC2016  # the jq expression the mutant takes instead
taken='$s.permissions[$pk]'
mut_src=${orig_src/"$union"/"$taken"}
printf '%s\n' "$mut_src" > "$mutant"
if [ "$mut_src" != "$orig_src" ]; then
  _test_pass "mutation applied: the union expression was found and replaced"
else
  _test_fail "mutation not applied: the union expression is not in merge-settings.sh"
fi
mut_out="$tmpdir/perm-mutant.json"
capture "$mut_out" bash "$mutant" --snippet "$snippet" "$tmpdir/perm.json"
assert_rc 0 "$mut_out"
jq -r '.permissions.ask[]' "$mut_out" > "$tmpdir/mut-ask.txt" 2>/dev/null
assert_no_grep 'git push' "$tmpdir/mut-ask.txt"

# ---------------------------------------------------------------------------
req "merge-settings: a missing settings file is an empty object"
out4="$tmpdir/merged4.json"
capture "$out4" bash "$merge" --snippet "$snippet" "$tmpdir/does-not-exist.json"
assert_rc 0 "$out4"
cmds "$out4" .hooks.PreToolUse "$tmpdir/pre4.txt"
assert_fgrep 'check-gate.sh' "$tmpdir/pre4.txt"
assert_no_grep 'confine' "$tmpdir/pre4.txt"
if [ -e "$tmpdir/does-not-exist.json" ]; then
  _test_fail "a missing settings file was created"
else
  _test_pass "missing settings file still absent"
fi

# ---------------------------------------------------------------------------
req "merge-settings: invalid JSON is refused"
printf '{ "hooks": ' > "$tmpdir/broken.json"
cp "$tmpdir/broken.json" "$tmpdir/broken.before"
bad="$tmpdir/bad-settings.out"
capture "$bad" bash "$merge" --snippet "$snippet" "$tmpdir/broken.json"
assert_rc 1 "$bad"
assert_grep 'not valid JSON' "$bad"
assert_no_grep 'check-gate' "$bad"
if cmp -s "$tmpdir/broken.before" "$tmpdir/broken.json"; then
  _test_pass "broken settings left untouched"
else
  _test_fail "broken settings were modified"
fi
bad2="$tmpdir/bad-snippet.out"
capture "$bad2" bash "$merge" --snippet "$tmpdir/broken.json" "$settings"
assert_rc 1 "$bad2"
assert_grep 'not valid JSON' "$bad2"
bad3="$tmpdir/missing-snippet.out"
capture "$bad3" bash "$merge" --snippet "$tmpdir/no-such-snippet.json" "$settings"
assert_rc 1 "$bad3"

# ---------------------------------------------------------------------------
req "merge-settings: with no --snippet, the checkout's own snippet is used"
out5="$tmpdir/merged5.json"
capture "$out5" bash "$merge" "$settings"
assert_rc 0 "$out5"
cmds "$out5" .hooks.PreToolUse "$tmpdir/pre5.txt"
assert_fgrep 'check-gate.sh' "$tmpdir/pre5.txt"

# The installed copy (a plain file under ~/.claude/scripts, no checkout beside
# it) finds the snippet through the source path the install receipt records.
fh="$tmpdir/home"
mkdir -p "$fh/.claude/scripts"
cp "$merge" "$fh/.claude/scripts/merge-settings.sh" 2>/dev/null
jq -n --arg p "$repo" '{source: {path: $p}}' > "$fh/.claude/doctor-installation.json"
out6="$tmpdir/merged6.json"
capture "$out6" env HOME="$fh" bash "$fh/.claude/scripts/merge-settings.sh" "$settings"
assert_rc 0 "$out6"
cmds "$out6" .hooks.PreToolUse "$tmpdir/pre6.txt"
assert_fgrep 'check-gate.sh' "$tmpdir/pre6.txt"

finish
