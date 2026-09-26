#!/bin/bash
# AI-Native SDLC — print ~/.claude/settings.json with the framework's hooks
# snippet merged in. It PRINTS the result and never writes any file: the owner
# reads it and moves it into place, because a session must not edit the
# settings file and this script must not pretend otherwise.
#
# Usage: merge-settings.sh [--snippet PATH] [SETTINGS_JSON]
#   --snippet PATH   the snippet to merge (default: settings/hooks-snippet.json
#                    of this checkout, else of the checkout the install receipt
#                    ~/.claude/doctor-installation.json records)
#   SETTINGS_JSON    the settings to merge into (default ~/.claude/settings.json;
#                    a missing file is treated as {})
#
# Typical use:
#   merge-settings.sh > ~/.claude/settings.json.new   # then READ it
#   mv ~/.claude/settings.json.new ~/.claude/settings.json
#
# Merge rule:
#   - hooks: for every event, the existing entries are kept as they are, and
#     each snippet entry is added with only the hook commands not already
#     registered under that event (compared by the `command` string). An entry
#     with nothing new is skipped, so a second run changes nothing and an
#     owner's own hooks (a delete-confinement guard, say) always survive.
#   - other top-level keys: added when absent; when both sides are objects they
#     are merged key by key with the EXISTING value winning; an existing value
#     is never overwritten.
#   - the snippet's "//" key is its documentation for a reader, not a setting,
#     and is not copied.
# Refuses (exit 1, nothing on stdout) when either input is not valid JSON or
# not a JSON object, or when no snippet can be found.
set -euo pipefail

die() { echo "merge-settings: $*" >&2; exit 1; }

snippet=""
if [ "${1:-}" = "--snippet" ]; then
  [ "$#" -ge 2 ] || die "--snippet needs a path"
  snippet="$2"
  shift 2
fi
[ "$#" -le 1 ] || die "usage: merge-settings.sh [--snippet PATH] [SETTINGS_JSON]"
settings="${1:-$HOME/.claude/settings.json}"

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"

if [ -z "$snippet" ]; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || die "cannot locate this script"
  receipt="$HOME/.claude/doctor-installation.json"
  source_dir=""
  if [ -r "$receipt" ]; then
    source_dir=$(jq -r '.source.path // empty' "$receipt" 2>/dev/null || true)
  fi
  for candidate in "$here/../settings/hooks-snippet.json" \
                   "$HOME/.claude/settings/hooks-snippet.json" \
                   ${source_dir:+"$source_dir/settings/hooks-snippet.json"}; do
    if [ -f "$candidate" ]; then
      snippet="$candidate"
      break
    fi
  done
  [ -n "$snippet" ] || die "no hooks snippet found; pass --snippet PATH (settings/hooks-snippet.json in the framework checkout)"
fi

[ -f "$snippet" ] && [ -r "$snippet" ] || die "cannot read the snippet: $snippet"
jq empty "$snippet" >/dev/null 2>&1 || die "the snippet is not valid JSON: $snippet"
[ "$(jq -r 'type' "$snippet")" = "object" ] || die "the snippet is not a JSON object: $snippet"

if [ -e "$settings" ]; then
  [ -r "$settings" ] || die "cannot read the settings file: $settings"
  jq empty "$settings" >/dev/null 2>&1 || die "the settings file is not valid JSON: $settings"
  current=$(jq -c . "$settings") || die "cannot read the settings file: $settings"
  [ -n "$current" ] || current='{}'
else
  current='{}'
fi
[ "$(printf '%s' "$current" | jq -r 'type')" = "object" ] \
  || die "the settings file is not a JSON object: $settings"
[ "$(printf '%s' "$current" | jq -r '.hooks // {} | type')" = "object" ] \
  || die "\"hooks\" in the settings file is not an object: $settings"

# The merge happens in one jq run into a variable, so a failure prints nothing.
merged=$(printf '%s' "$current" | jq --slurpfile snip "$snippet" '
  def commands: [.[]?.hooks[]?.command];
  $snip[0] as $s
  | . as $cur
  # top-level keys other than hooks and the comment: add when absent, merge
  # objects with the existing side winning, never overwrite.
  | reduce ($s | keys_unsorted[] | select(. != "//" and . != "hooks")) as $k
      ($cur;
       if has($k) | not then .[$k] = $s[$k]
       elif (.[$k] | type) == "object" and ($s[$k] | type) == "object"
         then .[$k] = ($s[$k] * .[$k])
       else . end)
  # hooks: keep every existing entry; add only commands not yet registered.
  | if ($s.hooks | type) == "object" then
      .hooks = (reduce ($s.hooks | keys_unsorted[]) as $ev
        (.hooks // {};
         .[$ev] = (reduce ($s.hooks[$ev][]?) as $entry
           (.[$ev] // [];
            commands as $have
            | ([$entry.hooks[]? | select(.command as $c | $have | index([$c]) | not)]) as $new
            | if ($new | length) == 0 then . else . + [$entry + {hooks: $new}] end))))
    else . end
') || die "the merge failed; nothing was printed"

printf '%s\n' "$merged"
