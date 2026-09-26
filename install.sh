#!/bin/bash
# AI-Native SDLC — installer. Copies the framework's global pieces into ~/.claude.
# Idempotent: safe to re-run after editing files here (this folder stays the
# source of truth). Initial settings registration stays manual; only the exact
# existing framework requirement Stop command is migrated to --stop (backed up).
# Other ~/.claude/settings.json content stays unchanged — that merge is
# the owner's own step, because a session cannot write to that file;
# scripts/merge-settings.sh prints the merged result for the owner to review.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

harness=claude
if [ "${1:-}" = "--harness" ]; then
  [ "$#" -ge 2 ] || { echo "--harness requires claude or codex" >&2; exit 2; }
  harness="$2"
  shift 2
fi
case "$harness" in
  codex) exec python3.12 "$here/adapters/codex/scripts/install.py" "$@" ;;
  claude) [ "$#" -eq 0 ] || { echo "Unknown Claude install argument: $1" >&2; exit 2; } ;;
  *) echo "Unknown harness: $harness" >&2; exit 2 ;;
esac

python3.12 "$here/core/installation.py" --source "$here" --runtime "$HOME/.claude" --check-skills

mkdir -p "$HOME/.claude/agents" "$HOME/.claude/hooks" "$HOME/.claude/scripts" "$HOME/.claude/commands"

command -v jq >/dev/null 2>&1 \
  || echo "WARNING: jq not found — the Stop-hook loop guard, the npm-check fallback, and the PostCompact hook all need it (brew install jq)."

echo "Installing agents → ~/.claude/agents/"
for f in "$here"/agents/*.md; do
  [ -e "$f" ] || continue
  cp -v "$f" "$HOME/.claude/agents/"
done
# The role manifest ships in agents/ but is not a *.md prompt, so the loop above
# does not carry it. It is installed beside the agents so the installed copy of
# apply-engines.sh is runnable on its own (REQ-ENGINE-030). Guarded like every
# other glob here: this script runs under `set -euo pipefail`.
for f in "$here"/agents/*.conf; do
  [ -e "$f" ] || continue
  cp -v "$f" "$HOME/.claude/agents/"
done

echo "Installing hook scripts → ~/.claude/hooks/"
for f in "$here"/hooks/*.sh; do
  [ -e "$f" ] || continue
  cp -v "$f" "$HOME/.claude/hooks/"
  chmod +x "$HOME/.claude/hooks/$(basename "$f")"
done

echo "Installing scripts → ~/.claude/scripts/"
for f in "$here"/scripts/*.sh; do
  [ -e "$f" ] || continue
  cp -v "$f" "$HOME/.claude/scripts/"
  chmod +x "$HOME/.claude/scripts/$(basename "$f")"
done

# Both harnesses use the same non-destructive project enrollment implementation.
cp "$here/adapters/codex/scripts/routing.py" "$HOME/.claude/scripts/routing.py"
for helper in project doctor installation handoff handoff_store handoff_runtime; do
  cp "$here/core/$helper.py" "$HOME/.claude/scripts/$helper.py"
done
mkdir -p "$HOME/.claude/templates"
cp "$here/core/templates/pre-commit" "$HOME/.claude/templates/pre-commit"

echo "Installing commands → ~/.claude/commands/"
for f in "$here"/commands/*.md; do
  [ -e "$f" ] || continue
  cp -v "$f" "$HOME/.claude/commands/"
done
# Commands this framework has renamed away are reported, never removed: this
# installer deletes nothing under ~/.claude that it did not itself install in
# this run (REQ-GCORE-005), so a file the user may have edited or may still want
# is left for the user to delete (REQ-GCORE-034).
for stale in morning.md overnight.md; do
  stale_path="$HOME/.claude/commands/$stale"
  [ -e "$stale_path" ] || continue
  echo "WARNING: stale command $stale_path from an older version — delete it yourself"
done

echo "Installing policy → ~/.claude/sdlc-policy.md"
cp -v "$here/sdlc-policy.md" "$HOME/.claude/sdlc-policy.md"

# The engine map is the ONE file in ~/.claude this installer will not overwrite.
# Everything else here is framework-owned and copied over on every run; the map
# is the owner's choice of which model runs which role, so a re-install seeds it
# once (REQ-ENGINE-007) and thereafter leaves it byte-for-byte alone, whatever
# the template has grown since (REQ-ENGINE-008). No merge, no diff, no "updated
# your map" — the point of the file is that the owner's edit survives.
engine_map="$HOME/.claude/sdlc-engines.conf"
if [ -e "$engine_map" ]; then
  echo "Engine map: kept your existing engine map at $engine_map (not overwritten)"
else
  if [ -e "$here/templates/sdlc-engines.conf" ]; then
    cp "$here/templates/sdlc-engines.conf" "$engine_map"
    echo "Engine map: created $engine_map from the template — it is yours to edit, and no re-install will overwrite it"
  else
    echo "WARNING: no templates/sdlc-engines.conf in this checkout — no engine map was created." >&2
  fi
fi

# Agents pin `model:` in their own frontmatter, so the map above changes nothing
# until it is applied. Run the checkout's copy (not the one just installed into
# ~/.claude/scripts): this run's checkout is the source of truth, and it is the
# copy whose behaviour was tested. A map the script cannot apply is an install
# failure, not a warning — the alternative is a "Done." over agents still on
# yesterday's models (REQ-ENGINE-015).
echo "Applying the engine map → ~/.claude/agents/"
if ! bash "$here/scripts/apply-engines.sh"; then
  echo "ERROR: scripts/apply-engines.sh failed — $engine_map could not be applied." >&2
  echo "  Fix the map (the lines above name the offending entries) and re-run install.sh." >&2
  echo "  How far it got is in its own output above: a validation failure changes nothing," >&2
  echo "  while a file it could not write leaves the map applied to some agents and not others." >&2
  exit 1
fi

# Shadow scan (REQ-GCORE-008/009/035). A project's .claude/commands/<name>.md
# wins over the global command of the same name, so the installer reports every
# such collision it can see — it never edits or removes a project file. Scan
# root: $SDLC_SCAN_ROOT when it names a directory, else the parent of this
# checkout. `find` runs without -L so symlinked directories are not followed
# (a link to a repo must not double-report it), 2>/dev/null drops unreadable
# subtrees, and the .git / node_modules / .venv trees are pruned because a
# command directory never lives inside them. -maxdepth 4 puts both
# <root>/<repo>/.claude/commands and the grouped <root>/<group>/<repo>/... in
# range (a grouping directory), and anything deeper out of it. The globals just
# installed into $HOME/.claude/commands are skipped: a checkout placed directly
# under $HOME would otherwise report $HOME as a repo shadowing every command.
# The glob below is guarded (`[ -e ] || continue`) because the script runs
# under `set -euo pipefail`.
scan_root="${SDLC_SCAN_ROOT:-}"
[ -d "$scan_root" ] || scan_root="$(dirname "$here")"
global_cmds="$(cd "$HOME/.claude/commands" && pwd -P)"
while IFS= read -r cmd_dir; do
  [ "$(cd "$cmd_dir" 2>/dev/null && pwd -P)" = "$global_cmds" ] && continue
  repo_dir="${cmd_dir%/.claude/commands}"
  for pcmd in "$cmd_dir"/*.md; do
    [ -e "$pcmd" ] || continue
    name="$(basename "$pcmd" .md)"
    [ -e "$here/commands/$name.md" ] || continue
    echo "WARNING: $repo_dir shadows global /$name (project wins)"
  done
done < <(find "$scan_root" -maxdepth 4 \
           \( -name .git -o -name node_modules -o -name .venv \) -prune -o \
           -type d -path '*/.claude/commands' -print 2>/dev/null)

python3.12 "$HOME/.claude/scripts/installation.py" --source "$here" --runtime "$HOME/.claude" --install-skills
python3.12 "$HOME/.claude/scripts/installation.py" --source "$here" --runtime "$HOME/.claude"

cat <<'EOF'

Done. Remaining manual steps — these are yours, not a session's:
  1. Merge every TOP-LEVEL key of settings/hooks-snippet.json into
     ~/.claude/settings.json: run ~/.claude/scripts/merge-settings.sh and
     review its output; your existing entries survive the merge. It prints
     and writes nothing, so save it and move it into place yourself:
       ~/.claude/scripts/merge-settings.sh > ~/.claude/settings.json.new
       mv ~/.claude/settings.json.new ~/.claude/settings.json
     This merge is yours: the session cannot edit ~/.claude/settings.json —
     the auto-mode classifier blocks a session from writing to it, so no
     amount of asking will get it done for you.
     Read the diff for the newly added SessionStart entry: it runs
     ~/.claude/hooks/session-engines.sh at startup, resume and clear, so a
     session opens knowing which model runs which role. It is deliberately
     not run on compaction — the PostCompact entry already covers that.
  2. Open /hooks once in Claude Code (or restart) so the new hooks load.
  3. Add a Makefile with `check`/`test` targets to each repo
     (see templates/) — repos without one are simply not gated yet.
  4. Your engine map is ~/.claude/sdlc-engines.conf — no re-install overwrites
     it. Re-run ~/.claude/scripts/apply-engines.sh whenever you change it:
     that is what applies the edit to the agents' own model frontmatter.
  5. Point the SDLC section of ~/.claude/CLAUDE.md at ~/.claude/sdlc-policy.md
     instead of duplicating the routing table — one source of truth.
EOF
