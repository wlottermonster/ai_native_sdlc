#!/bin/bash
# AI-Native SDLC — the session-start engine announcement (SessionStart hook).
#
# Emits the ACTIVE engine map — $HOME/.claude/sdlc-engines.conf — as
# `additionalContext`, so a session starts knowing which model runs which role
# instead of guessing.
#
# This hook NEVER blocks a session: every path exits 0, including a missing or
# unreadable map and a machine without jq.
#
# Usage: as a hook (drains stdin) or manually: session-engines.sh
set -u

# REQ-ENGINE-034: drain stdin FIRST, before anything else. A SessionStart hook
# is handed a JSON payload this script does not need; leaving it unread risks a
# blocked read or a SIGPIPE. Same idiom as hooks/req-gate.sh.
exec < /dev/null

map="$HOME/.claude/sdlc-engines.conf"

# --- the instruction block -------------------------------------------------
# REQ-ENGINE-018 (one opening line naming the running model and its roles) and
# REQ-ENGINE-019 (that line also discloses a judge mismatch). Both the jq and
# the hand-built path render whatever this prints.
#
# CONSTRAINT, and the reason this text is quote-free and backslash-free: the
# hand-built (no-jq) path drops any line containing a double quote, a backslash
# or a control character, because it does not escape — such a line would vanish
# silently on a machine without jq. tests/test_session_hook.sh asserts this
# mechanically; keep any edit here free of those characters.
#
# This text is injected into EVERY session's context, so it is kept short: six
# lines, no examples, no restatement of the map above it.
instructions() {
  printf '%s\n' \
    'Engine-role announcement (do this first):' \
    'State in ONE line, at the very start of your first reply in this session, the model you are running as and the roles that model covers in the map above.' \
    'Keep it to that one line, before any other output, then get on with the work.' \
    'If the model you are running as is not the FIRST model listed for judge, say so plainly in that same line instead of routing as though it were.' \
    'A session cannot change its own model, so that line is how the owner learns at once when the session is not running the model they chose.' \
    'Roles bind to agents through this map, and a model the owner names in the moment outranks it.'
}

# --- the payload -----------------------------------------------------------
# The plain text that becomes additionalContext. Read with the shell's own
# builtins (no cat/sed/awk), because the hand-built path must work on a PATH
# that holds nothing at all.
payload() {
  local line trimmed
  if [ -r "$map" ]; then
    printf 'Active AI-Native SDLC engine map (%s) — role = model, first listed runs, rest are fallbacks:\n\n' "$map"
    # comment and blank lines are stripped: this is context a session pays for
    while IFS= read -r line || [ -n "$line" ]; do
      # A trailing CR first, so a map saved with CRLF endings reads the same as
      # one saved with LF — scripts/apply-engines.sh tolerates it the same way.
      # It is not cosmetic here: CR is a control character, and the hand-built
      # path below drops every line that carries one, so an unstripped CR would
      # silently empty the map out on a machine without jq.
      trimmed=${line%$'\r'}
      while [ "${trimmed# }" != "$trimmed" ] || [ "${trimmed#$'\t'}" != "$trimmed" ]; do
        trimmed=${trimmed# }
        trimmed=${trimmed#$'\t'}
      done
      case $trimmed in
        ''|'#'*) continue ;;
      esac
      printf '%s\n' "$trimmed"
    done < "$map"
  else
    # REQ-ENGINE-017
    printf 'There is no engine map at %s, so no map is active and the built-in default engines apply.\n' "$map"
    printf 'Install or create one to pin roles to models; until then every role runs on the harness default.\n'
  fi
  printf '\n'
  instructions
}

# --- emission --------------------------------------------------------------
# REQ-ENGINE-034: with jq, the payload is turned into a JSON string by `jq -Rs`
# (the same idiom the PostCompact entry in settings/hooks-snippet.json uses).
# Without jq, the object is hand-built. Hand-building does not escape; it drops
# any line carrying a character that would need escaping (a double quote, a
# backslash, or a control character), so the result is always ONE valid JSON
# object rather than a partial or empty one.
emit_hand_built() {
  local ctx="" line first=1 dropped=0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      *[\"\\]*|*[[:cntrl:]]*) dropped=1; continue ;;
    esac
    if [ "$first" -eq 1 ]; then
      ctx=$line
      first=0
    else
      ctx="$ctx\\n$line"
    fi
  done
  # The apology is only true when something was actually left out, and this
  # path is also reached when jq EXISTS but failed — so it says "could not be
  # used" rather than "is unavailable", and is omitted entirely when every line
  # came through.
  if [ "$dropped" -eq 1 ]; then
    ctx="(jq could not be used, so lines needing JSON escaping were omitted.)\\n$ctx"
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$ctx"
}

if command -v jq >/dev/null 2>&1; then
  payload | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}' \
    || payload | emit_hand_built
else
  payload | emit_hand_built
fi

exit 0
