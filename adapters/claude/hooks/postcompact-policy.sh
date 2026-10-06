#!/bin/bash
# AI-Native SDLC — PostCompact hook: re-inject the ROUTING section of the policy.
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

# Drain stdin first: the harness pipes the hook payload, and a hook that never
# reads it can die on a closed pipe when the payload is large.
cat >/dev/null 2>&1 || true

policy="$HOME/.claude/sdlc-policy.md"
heading='^# AI-Native SDLC.*routing policy'

# emit <text> — wrap text as this event's additionalContext.
emit() {
  printf '%s' "$1" | jq -Rs '{hookSpecificOutput:{hookEventName:"PostCompact",additionalContext:.}}'
}

if ! command -v jq >/dev/null 2>&1; then
  # Hand-built JSON of constant text only, so nothing here needs escaping.
  printf '{"hookSpecificOutput":{"hookEventName":"PostCompact","additionalContext":"AI-Native SDLC: jq is not installed, so the routing policy could not be re-injected after compaction. Read ~/.claude/sdlc-policy.md before routing any work."}}\n'
  exit 0
fi

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
