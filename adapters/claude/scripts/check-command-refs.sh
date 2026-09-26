#!/bin/bash
# AI-Native SDLC — do the slash commands a repo's instructions name still exist?
#
# A CLAUDE.md that tells a session to run `/foo` is only as good as `/foo`
# existing. Commands get renamed and retired; the prose that names them does
# not notice, and the failure arrives as a session that cannot do what it was
# told. This script asks the filesystem instead of the author (REQ-GATE-007).
#
# Usage: check-command-refs.sh [<repo-dir>]        (default: the current directory)
#
# It scans <repo>/CLAUDE.md and <repo>/.claude/commands/*.md for backticked
# `/name` tokens and resolves each against, in order:
#   - the repo's own .claude/commands/<name>.md and .claude/skills/<name>/
#   - the installed $HOME/.claude/commands/<name>.md and $HOME/.claude/skills/<name>/
#   - the harness's built-in commands (the list below)
#   - <repo>/.claude/known-commands — one name per line — for anything else the
#     repo knows to be real (a plugin's command, say). It is the repo's list,
#     read as data; nothing here invents an exemption.
# Exit 0: every reference resolves. Exit 1: each unresolved one is listed as
# <file>:<line> /<name>. Exit 2: the repo cannot be entered or has no CLAUDE.md.
set -u

repo="${1:-.}"
repo=$(cd "$repo" 2>/dev/null && pwd) \
  || { echo "check-command-refs: cannot enter ${1:-.}" >&2; exit 2; }
[ -f "$repo/CLAUDE.md" ] \
  || { echo "check-command-refs: no CLAUDE.md in $repo — nothing to scan" >&2; exit 2; }

# Built-in slash commands of the harness. A name here is one this script stops
# watching, so the list is kept to what the harness itself provides.
BUILTIN=" add-dir agents artifacts btw bug clear code-review compact config context cost design diff doctor effort exit export fast feedback fewer-permission-prompts help hooks ide init insights install-slack-app keybindings-help login logout loop mcp memory model output-style permissions plugin pr-comments release-notes remember rename resume review rewind run schedule security-review simplify skill-doctor statusline stats status tasks terminal-setup theme ultrareview update-config upgrade usage vim workflows "

# The token shape: a backticked /name with nothing else inside the backticks, so
# a path like `/dev/null` or a glob like `/portal/**` is never mistaken for one.
TOKEN="\`/[a-z][a-z0-9_-]*\`"

resolves() {
  local n="$1"
  [ -f "$repo/.claude/commands/$n.md" ] && return 0
  [ -d "$repo/.claude/skills/$n" ] && return 0
  [ -f "$HOME/.claude/commands/$n.md" ] && return 0
  [ -d "$HOME/.claude/skills/$n" ] && return 0
  case "$BUILTIN" in *" $n "*) return 0 ;; esac
  [ -f "$repo/.claude/known-commands" ] \
    && grep -qx -- "$n" "$repo/.claude/known-commands" && return 0
  return 1
}

files=("$repo/CLAUDE.md")
for f in "$repo"/.claude/commands/*.md; do
  [ -f "$f" ] && files+=("$f")
done

bad=0
total=0
for f in "${files[@]}"; do
  while IFS=: read -r line tok; do
    [ -n "$tok" ] || continue
    n=${tok#\`/}
    n=${n%\`}
    total=$((total + 1))
    if ! resolves "$n"; then
      printf '%s:%s /%s resolves nowhere (no project or installed command, skill, built-in, or known-commands entry)\n' \
        "${f#"$repo"/}" "$line" "$n" >&2
      bad=$((bad + 1))
    fi
  done < <(grep -noE "$TOKEN" "$f" 2>/dev/null || true)
done

if [ "$bad" -ne 0 ]; then
  echo "check-command-refs: $bad of $total reference(s) resolve nowhere in $repo" >&2
  exit 1
fi
echo "command refs OK — $total reference(s) across ${#files[@]} file(s) resolve ($repo)"
exit 0
