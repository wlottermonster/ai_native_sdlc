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
for ev in SessionStart PreToolUse PostToolUse Stop PostCompact; do
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
