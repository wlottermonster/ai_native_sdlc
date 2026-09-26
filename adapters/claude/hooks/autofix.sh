#!/bin/bash
# AI-Native SDLC — mechanical auto-fix (PostToolUse on Edit|Write, async).
# Problems a tool can fix are fixed silently, spending zero model tokens.
# Always exits 0 — this hook never blocks anything.
set -u
f=$(jq -r '.tool_response.filePath // .tool_input.file_path // empty' 2>/dev/null)
[ -n "$f" ] && [ -f "$f" ] || exit 0

case "$f" in
  *.py)
    repo=$(cd "$(dirname "$f")" && git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$repo" ] && [ -x "$repo/.venv/bin/ruff" ]; then
      "$repo/.venv/bin/ruff" check --fix -q "$f" 2>/dev/null
      "$repo/.venv/bin/ruff" format -q "$f" 2>/dev/null
    elif command -v ruff >/dev/null 2>&1; then
      ruff check --fix -q "$f" 2>/dev/null
      ruff format -q "$f" 2>/dev/null
    fi
    ;;
  *.js|*.jsx|*.ts|*.tsx|*.css|*.json)
    command -v npx >/dev/null 2>&1 \
      && npx --no-install prettier --write "$f" > /dev/null 2>&1
    ;;
esac
exit 0
