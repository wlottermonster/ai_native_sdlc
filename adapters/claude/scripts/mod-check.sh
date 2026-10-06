#!/bin/bash
# AI-Native SDLC — run the engine's own checks on the engine-map mod.
#
#   scripts/mod-check.sh validate   `claude plugin validate` on the mod folder
#   scripts/mod-check.sh test       `claude plugin test` on the mod folder
#
# Exit 0 is earned: the client must be on PATH, must exit 0, and must print
# its own success report (a validation that passed; a suite with at least one
# pass and no failure). validate must also list exactly the events of the
# allow-list below as hooked, and no gating hook without a `.catch`: the
# client only warns on those, and a warning is not a pass. A missing mod
# folder is a failure, never a pass.
#
# The mod is found in the checkout layout (adapters/claude/skills/ beside this
# script's `scripts` link, resolved logically) or in the installed layout
# (~/.claude/scripts/ beside ~/.claude/skills/), in that order.
#
# Without `claude` on PATH the checks cannot run: one line says so and the
# script fails, unless SDLC_SKIP_CLAUDE_MOD=1 is set, in which case the same
# line is printed and the script exits 0. The skip is always explicit, never
# inferred from the machine, and it never silences a check that did run.
set -u

# The only events the mod may hook (REQ-MOD-006). tests/test_mod.sh reads this
# line; it is the one place the list lives.
allowed_events="agent.spawn session.start turn.complete turn.start"

usage() {
  printf 'usage: %s validate|test\n' "${0##*/}" >&2
  exit 2
}

[ $# -eq 1 ] || usage
mode="$1"
case "$mode" in
  validate|test) ;;
  *) usage ;;
esac

# The parent of this script's directory, resolved LOGICALLY: in the checkout
# `scripts` is a symlink into adapters/claude, so a physical `..` would land
# there instead.
root=$(cd "$(dirname "$0")" && cd .. && pwd) || {
  printf 'mod-check: cannot resolve the checkout from %s\n' "$0" >&2
  exit 1
}
mod=""
for candidate in "$root/adapters/claude/skills/sdlc-engine-map" "$root/skills/sdlc-engine-map"; do
  if [ -f "$candidate/.claude-plugin/plugin.json" ] && mod=$(cd "$candidate" && pwd); then
    break
  fi
  mod=""
done
if [ -z "$mod" ]; then
  printf 'mod-check: no mod at %s or %s (expected .claude-plugin/plugin.json)\n' \
    "$root/adapters/claude/skills/sdlc-engine-map" "$root/skills/sdlc-engine-map" >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  printf 'mod checks NOT run: claude is not on PATH (only SDLC_SKIP_CLAUDE_MOD=1 lets the gate continue)\n' >&2
  if [ "${SDLC_SKIP_CLAUDE_MOD:-}" = "1" ]; then
    exit 0
  fi
  exit 1
fi

out=$(mktemp "${TMPDIR:-/tmp}/sdlc-mod-check.XXXXXX") || {
  printf 'mod-check: cannot create a temporary file\n' >&2
  exit 1
}
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -f "$out"; }
trap cleanup EXIT

rc=0
claude plugin "$mode" "$mod" >"$out" 2>&1 || rc=$?
cat "$out"

if [ "$rc" -ne 0 ]; then
  printf 'mod-check: claude plugin %s failed (exit %s)\n' "$mode" "$rc" >&2
  exit "$rc"
fi

case "$mode" in
  validate)
    if ! grep -q 'Validation passed' "$out"; then
      printf 'mod-check: claude plugin validate exited 0 without reporting a pass\n' >&2
      exit 1
    fi
    if grep -q 'gating hook without \.catch' "$out"; then
      printf 'mod-check: a gating hook has no .catch (REQ-MOD-004)\n' >&2
      exit 1
    fi
    # Every indented "<marker> <module> hooks: a, b, c" line of the report,
    # split, sorted, once each, against the allow-list as a set: one extra
    # event fails, and so does a missing one.
    hooked=$(sed -nE 's/^[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+ hooks: (.*)$/\1/p' "$out" | tr ',' '\n' | tr -d ' ' \
      | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
    allowed=$(printf '%s\n' "$allowed_events" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [ "$hooked" != "$allowed" ]; then
      printf 'mod-check: hooked events are [%s], allowed exactly [%s] (REQ-MOD-006)\n' "$hooked" "$allowed" >&2
      exit 1
    fi
    ;;
  test)
    if ! grep -qE '^ *[1-9][0-9]* pass$' "$out" || ! grep -qE '^ *0 fail$' "$out"; then
      printf 'mod-check: claude plugin test exited 0 without reporting passes and no failure\n' >&2
      exit 1
    fi
    ;;
esac

exit 0
