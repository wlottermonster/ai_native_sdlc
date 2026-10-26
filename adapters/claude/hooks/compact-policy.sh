#!/bin/bash
# AI-Native SDLC — SessionStart hook (matcher `compact`): re-inject the ROUTING
# section of the policy after the client compacts a session.
#
# SessionStart with source `compact` is the event the client documents as
# adding its output to the context after a compaction; PostCompact has no
# output channel. The settings entry's matcher is `compact`, so the script
# normally sees only that source; on any other source (or none, or a payload
# it cannot read) it prints nothing, so it never injects the policy at a
# startup, resume or clear it was not registered for.
#
# After compaction the session keeps a summary, and the one thing it must not
# lose is how work is routed. The policy file has a harness-neutral first half
# (lifecycle, evidence, enforcement limits) and a routing half under the
# heading "# AI-Native SDLC — routing policy". Only the routing half comes
# back: the first half is read on demand and would cost three times the
# tokens on every compaction for rules the session already follows.
#
# Falls back to the WHOLE file when the heading cannot be found, so a renamed
# heading degrades to the previous behaviour instead of injecting nothing. A
# missing policy file is said out loud in the injected context, never skipped
# silently: an empty injection looks exactly like a working one. This hook
# injects context and gates nothing, so every exit here is 0 on purpose.
set -u

# Read the whole payload first: the harness pipes it, a hook that never reads
# it can die on a closed pipe when it is large, and the source is in it. A
# closed stdin is tested for first: with descriptor 0 closed, the pipe of the
# command substitution can take descriptor 0 and cat would read its own output
# for ever. The probe duplicates 0 onto 3, because bash treats `<&0` as a
# no-op that succeeds even when 0 is closed.
payload=""
if { : 3<&0; } 2>/dev/null; then
  payload=$(cat 2>/dev/null) || payload=""
fi

policy="$HOME/.claude/sdlc-policy.md"
heading='^# AI-Native SDLC.*routing policy'

# emit <text> — wrap text as this event's additionalContext.
emit() {
  printf '%s' "$1" | jq -Rs '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
}

if ! command -v jq >/dev/null 2>&1; then
  # Without jq the source is matched as text: the one field this needs.
  source_re='"source"[[:space:]]*:[[:space:]]*"compact"'
  [[ $payload =~ $source_re ]] || exit 0
  # Hand-built JSON of constant text only, so nothing here needs escaping.
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"AI-Native SDLC: jq is not installed, so the routing policy could not be re-injected after compaction. Read ~/.claude/sdlc-policy.md before routing any work."}}\n'
  exit 0
fi

src=$(printf '%s' "$payload" \
  | jq -r 'if type == "object" then (.source // "" | tostring) else "" end' 2>/dev/null) || src=""
[ "$src" = compact ] || exit 0

if [ ! -r "$policy" ]; then
  emit "AI-Native SDLC: the policy file $policy is missing or unreadable, so nothing was re-injected after compaction. Reinstall the framework (install.sh) before routing any work."
  exit 0
fi

section=$(sed -n "/$heading/,\$p" "$policy")
if [ -z "$section" ]; then
  section=$(cat "$policy")
fi
emit "$section"
exit 0
