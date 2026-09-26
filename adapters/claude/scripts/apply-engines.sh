#!/bin/bash
# AI-Native SDLC — make the engine map effective.
#
# Agents pin `model:` in their own frontmatter, so editing the engine map alone
# changes nothing. This script reads the map (role -> ordered model list) and
# the role manifest (agent -> role) and sets each installed agent's model to the
# first model listed for its role.
#
#   map       $HOME/.claude/sdlc-engines.conf   — the owner's, never overwritten
#   manifest  $HOME/.claude/agents/roles.conf   — which role each agent runs
#             else <checkout>/agents/roles.conf   under; installed copy wins
#   agents    $HOME/.claude/agents/<agent>.md   — what gets rewritten
#
# $SDLC_AGENTS_DIR — a repo's OWN agents, kept in step with the same map.
# Set it to an agents directory and that directory is what gets rewritten,
# using the `roles.conf` sitting beside them in it:
#
#   SDLC_AGENTS_DIR=.claude/agents ~/.claude/scripts/apply-engines.sh
#
# The checkout fallback for the manifest does NOT apply to that directory: its
# agents are the repo's, and binding them to roles someone else wrote down
# would be guessing. No `roles.conf` beside them is reported, and nothing is
# changed. THE MAP IS NOT OVERRIDABLE and is always read from $HOME: it is the
# single binding the framework exists to keep, and a repo carrying its own would
# be the second one. Unset or empty, everything below behaves exactly as it did
# before the variable existed.
#
# VALIDATE FIRST, WRITE SECOND. Both files are parsed and checked in full before
# a single agent file is touched, so a malformed map can never leave the agents
# half-rewritten (REQ-ENGINE-014). Two shapes are deliberately NOT errors:
# a role the map defines but no agent is bound to — `judge` and `escalate`, both
# of which the main session and the owner reach for rather than any agent — is a
# no-op (REQ-ENGINE-027, REQ-ENGINE-042); and a manifest entry naming an agent
# that is not installed is a warning that the run continues past
# (REQ-ENGINE-029).
#
# Portability: bash 3.2 (no associative arrays, no mapfile), and no `sed -i`
# (BSD wants an argument, GNU forbids one). Parsing goes through awk into
# tab-separated temp files; rewriting goes through awk into a mktemp file in the
# target's own directory, renamed over it.
#
# Usage: scripts/apply-engines.sh          [SDLC_AGENTS_DIR=<dir>]
# Exit:  0 applied (or nothing to do)   2 the map or the manifest is unusable,
#                                        or an agent file could not be written
set -u

self=$(basename "$0")
script_dir=$(cd "$(dirname "$0")" && pwd)

# The map is the owner's file, in a fixed place. The manifest is looked for
# beside the INSTALLED agents first and in the checkout second (REQ-ENGINE-030):
# install.sh copies `agents/roles.conf` in alongside the agent prompts, so the
# installed tree is runnable on its own — a machine with no checkout, or a
# checkout that has moved on, still applies the map the installed agents were
# installed with. Running the script out of a checkout that HAS no installed
# copy beside it falls back to its own.
#
# $SDLC_AGENTS_DIR redirects the AGENTS (and with them the manifest, which must
# be the one beside them — see the header). It never redirects the map.
map="$HOME/.claude/sdlc-engines.conf"
checkout=$(cd "$script_dir/.." && pwd)   # normalised: the paths this script
                                         # names in an error must be readable
if [ -n "${SDLC_AGENTS_DIR:-}" ]; then
  agents_dir="$SDLC_AGENTS_DIR"
  # Normalised the same way, when it names a directory that exists. When it does
  # not, the value is kept verbatim so the error below quotes back what was set
  # rather than a path the owner never typed.
  normalised=$(cd "$agents_dir" 2>/dev/null && pwd) && agents_dir="$normalised"
  manifest="$agents_dir/roles.conf"
else
  agents_dir="$HOME/.claude/agents"
  manifest="$checkout/agents/roles.conf"
  if [ -f "$agents_dir/roles.conf" ]; then
    manifest="$agents_dir/roles.conf"
  fi
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-apply-engines.XXXXXX") || exit 2
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

errors="$work/errors"
: > "$errors"

# fail <file> <line> <message> <text> — record a validation fault. Nothing is
# printed or acted on yet: every fault in BOTH files is collected first, so one
# run names every problem instead of making the owner fix them one at a time.
fail() {
  printf '%s: %s:%s: %s: %s\n' "$self" "$1" "$2" "$3" "$4" >> "$errors"
}

# parse_conf <file> <outfile> — normalise `key = value[, value...]` lines into
# tab-separated `<line>\t<key>\t<comma-joined values>` records in <outfile>,
# recording a fault for every malformed line. `#` comments, blank lines and
# surrounding whitespace are the shared format of both files; a trailing CR is
# tolerated so a map edited on another platform still parses.
parse_conf() {
  local file="$1" out="$2" parsed="$work/parsed.$$"
  : > "$out"
  if [ ! -f "$file" ]; then
    printf '%s: %s: no such file — cannot read it\n' "$self" "$file" \
      >> "$errors"
    return
  fi
  # Existing is not the same as readable, and this is the sibling of the gate
  # fail-open this run fixed: a guard that tests for presence and then acts as
  # though the read must succeed. Without this, an unreadable map or manifest
  # sends awk to stderr, parse_conf returns quietly, and the run reports
  # "0 changed, 0 unchanged — no agent changed" with exit 0 — a silent no-op
  # wearing the face of a successful apply.
  if [ ! -r "$file" ]; then
    printf '%s: %s: not readable — cannot read it\n' "$self" "$file" \
      >> "$errors"
    return
  fi
  awk '
    {
      t = $0
      sub(/\r$/, "", t)
      gsub(/^[ \t]+/, "", t)
      gsub(/[ \t]+$/, "", t)
      if (t == "") next
      if (substr(t, 1, 1) == "#") next
      eq = index(t, "=")
      if (eq == 0) { emit_err(NR, "malformed line (no \"=\")", t); next }
      k = substr(t, 1, eq - 1)
      v = substr(t, eq + 1)
      gsub(/^[ \t]+/, "", k); gsub(/[ \t]+$/, "", k)
      gsub(/^[ \t]+/, "", v); gsub(/[ \t]+$/, "", v)
      if (k == "") { emit_err(NR, "malformed line (empty key)", t); next }
      if (v == "") { emit_err(NR, "malformed line (empty value)", t); next }
      n = split(v, parts, ",")
      joined = ""
      for (i = 1; i <= n; i++) {
        p = parts[i]
        gsub(/^[ \t]+/, "", p); gsub(/[ \t]+$/, "", p)
        if (p == "") { emit_err(NR, "empty model name in the list", t); next_line = 1; break }
        joined = (joined == "" ? p : joined "," p)
      }
      if (next_line) { next_line = 0; next }
      printf "OK\t%d\t%s\t%s\n", NR, k, joined
    }
    function emit_err(n, msg, txt) { printf "ERR\t%d\t%s\t%s\n", n, msg, txt }
  ' "$file" > "$parsed"

  local kind line key value
  while IFS="$(printf '\t')" read -r kind line key value; do
    case "$kind" in
      OK)  printf '%s\t%s\t%s\n' "$line" "$key" "$value" >> "$out" ;;
      ERR) fail "$file" "$line" "$key" "$value" ;;
    esac
  done < "$parsed"
  rm -f "$parsed"
}

# first_model <role> — the model that runs for <role>: the head of its list.
# Empty output means the map does not define the role at all.
first_model() {
  awk -F'\t' -v role="$1" '$2 == role { split($3, m, ","); print m[1]; exit }' \
    "$work/map"
}

# --- validation -------------------------------------------------------------

parse_conf "$map" "$work/map"
parse_conf "$manifest" "$work/manifest"

# Every manifest entry must name exactly one role, and that role must be defined
# in the map. The reverse is NOT checked: a role with no agent bound to it is a
# no-op (REQ-ENGINE-027 / REQ-ENGINE-042).
while IFS="$(printf '\t')" read -r line agent role; do
  [ -n "${agent:-}" ] || continue
  case "$role" in
    *,*)
      fail "$manifest" "$line" "malformed line (an agent runs under exactly one role)" \
        "$agent = $role"
      continue
      ;;
  esac
  if [ -z "$(first_model "$role")" ]; then
    fail "$manifest" "$line" "role \"$role\" is not defined in $map" "$agent = $role"
  fi
done < "$work/manifest"

if [ -s "$errors" ]; then
  cat "$errors" >&2
  printf '%s: nothing was changed.\n' "$self" >&2
  exit 2
fi

# A key repeated in either file is not a validation error — an owner's map that
# has always had a stray second line must keep installing — but it IS a silent
# ambiguity, and the two files resolve it in opposite directions: `first_model`
# takes the FIRST entry for a role, while the manifest loop below applies every
# line in turn, so the LAST binding of an agent is the one that survives. Both
# are worth saying out loud rather than leaving the owner to infer from a model
# they did not expect.
warn_dupes() {
  local file="$1" parsed="$2" noun="$3" wins="$4"
  awk -F'\t' '
    seen[$2] { printf "%s\t%s\t%s\n", $1, $2, seen[$2]; next }
    { seen[$2] = $1 }
  ' "$parsed" |
  while IFS="$(printf '\t')" read -r line key firstline; do
    printf 'WARNING: %s:%s: %s "%s" is already defined on line %s — the %s wins\n' \
      "$file" "$line" "$noun" "$key" "$firstline" "$wins" >&2
  done
}
warn_dupes "$map" "$work/map" "role" "first"
warn_dupes "$manifest" "$work/manifest" "agent" "last"

# --- action -----------------------------------------------------------------
# Validation is complete and clean: from here on every agent file is fair game.
#
# Every installed agent lands in exactly one of four buckets, one line each, and
# the run ends with the tally (REQ-ENGINE-013):
#
#   changed <agent>: model: <old> -> <new> (role <role>)
#   unchanged <agent>: model: <model> (role <role>)
#   skipped <agent>: no "model:" line inside a leading frontmatter fence (<file>)
#   skipped <agent>: not named in <manifest> — left unchanged (<file>)
#
# The two skips are deliberately different sentences after the same first word.
# Both are "this file was not touched", which is what the owner scanning the
# output cares about, but they call for opposite fixes: the first is an agent
# the framework manages whose prompt has no model line to set, the second is a
# file the framework does not manage at all (REQ-ENGINE-028) — someone else's
# agent, or one whose manifest line was forgotten. `not named in` and
# `no "model:" line` each select exactly one of the two.

# frontmatter_model <file> — the model named on the first `model:` line strictly
# INSIDE the leading frontmatter fence: an opening `---` on line 1, closed by
# the next `---` line (REQ-ENGINE-038). Nothing is printed when the file has no
# such fence or no `model:` line within it — a body line beginning `model:` is
# body, not frontmatter, and is never eligible. The value is printed behind a
# leading `=` so that `model:` with an empty value is still distinguishable from
# "there is no such line" by the caller.
#
# A CRLF file's first line is `---\r`, which is not `---`, so it has no fence
# this script recognises and is left completely alone rather than being half
# converted to LF by the rewrite below.
frontmatter_model() {
  awk '
    NR == 1 { if ($0 != "---") exit; fm = 1; next }
    fm && $0 == "---" { exit }
    fm && /^model:/ {
      v = $0
      sub(/^model:[ \t]*/, "", v)
      sub(/[ \t]+$/, "", v)
      print "=" v
      exit
    }
  ' "$1"
}

# rewrite_model <file> <model> — set that one line to <model> and change nothing
# else (REQ-ENGINE-011). The new content is written to a mktemp file in the
# TARGET'S OWN directory and renamed over it, so the rename is atomic within the
# filesystem and an interrupted run leaves either the old file or the new one,
# never a partial one (REQ-ENGINE-033). Returns non-zero, having written
# nothing, if the temp cannot be created or written.
#
# `sed -i` is deliberately not used anywhere here: BSD requires an argument to
# it and GNU forbids one.
rewrite_model() {
  local file="$1" model="$2" dir tmp final_nl restore_ro
  dir=$(dirname "$file")
  tmp=$(mktemp "$dir/.apply-engines.XXXXXX") || return 1

  # The temp inherits the target's mode from `cp -p` and is then truncated by
  # the redirect below; this avoids `stat`, whose format flags differ between
  # BSD and GNU, and `chmod --reference`, which is GNU-only.
  cp -p "$file" "$tmp" || { rm -f "$tmp"; return 1; }

  # `cp -p` has just handed the temp the TARGET's mode, and that mode may lack
  # owner write — an agent file the owner has made read-only would then fail
  # the redirect below on the script's OWN temp, in a directory it can write
  # perfectly well. The bit is added for the rewrite and taken straight back
  # afterwards, so what lands has exactly the mode the target had.
  restore_ro=0
  if [ ! -w "$tmp" ]; then
    chmod u+w "$tmp" || { rm -f "$tmp"; return 1; }
    restore_ro=1
  fi

  # awk's `print` would append a newline to a file that ended without one, so
  # whether the original had a final newline is measured here and handed in:
  # command substitution strips trailing newlines, so an empty last byte means
  # the file ended with one.
  final_nl=1
  if [ -n "$(tail -c 1 "$file")" ]; then final_nl=0; fi

  # The model name travels in the ENVIRONMENT, not through `awk -v`, which
  # expands escape sequences in the value it is handed: a name containing a
  # backslash would arrive mangled, and the map promises pass-through verbatim.
  APPLY_ENGINES_MODEL="$model" awk -v final_nl="$final_nl" '
    BEGIN { model = ENVIRON["APPLY_ENGINES_MODEL"] }
    NR > 1 { printf "\n" }
    {
      line = $0
      if (NR == 1) {
        if (line == "---") fm = 1
      } else if (fm && line == "---") {
        fm = 0
      } else if (fm && !done && line ~ /^model:/) {
        # Only the value is replaced: the key and the spacing after its colon
        # are carried over from the line as it was written.
        match(line, /^model:[ \t]*/)
        line = substr(line, 1, RLENGTH) model
        done = 1
      }
      printf "%s", line
    }
    END { if (NR > 0 && final_nl) printf "\n" }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

  if [ "$restore_ro" -eq 1 ]; then
    chmod u-w "$tmp" || { rm -f "$tmp"; return 1; }
  fi

  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# The four buckets. Incremented in place by apply_agent below — the loops that
# call it are plain `while`/`for` in this shell, never a pipeline, so no counter
# is lost to a subshell.
changed=0
unchanged=0
skipped=0
failed=0

# apply_agent <agent> <role> <model> — set one installed agent's model line to
# the first model of its role (REQ-ENGINE-010). An agent with no eligible line
# is reported and skipped, not an error: there is nothing to set.
apply_agent() {
  local agent="$1" role="$2" model="$3"
  local file="$agents_dir/$agent.md" raw old
  raw=$(frontmatter_model "$file")
  if [ -z "$raw" ]; then
    printf 'skipped %s: no "model:" line inside a leading frontmatter fence (%s)\n' \
      "$agent" "$file"
    skipped=$((skipped + 1))
    return 0
  fi
  old=${raw#=}
  if [ "$old" = "$model" ]; then
    # Nothing to write: the file already says what the map asks for, so it is
    # not rewritten with identical content either (REQ-ENGINE-012).
    printf 'unchanged %s: model: %s (role %s)\n' "$agent" "$model" "$role"
    unchanged=$((unchanged + 1))
    return 0
  fi
  if ! rewrite_model "$file" "$model"; then
    printf '%s: %s: could not write the update — left unchanged\n' \
      "$self" "$file" >&2
    failed=$((failed + 1))
    return 1
  fi
  printf 'changed %s: model: %s -> %s (role %s)\n' "$agent" "$old" "$model" "$role"
  changed=$((changed + 1))
}

# Which manifest won is reported, not left to be inferred: the INSTALLED copy
# is preferred over the checkout's (REQ-ENGINE-030), so a run started from a
# checkout whose agents/roles.conf was just edited may legitimately be applying
# a different file from the one the owner is looking at.
printf 'using the engine map %s and the role manifest %s\n' "$map" "$manifest"

status=0

# Every agent the manifest names is remembered, whether or not it turned out to
# be installed, so the sweep below can tell an unmanaged file from a managed
# one.
managed="$work/managed"
: > "$managed"

while IFS="$(printf '\t')" read -r line agent role; do
  [ -n "${agent:-}" ] || continue
  printf '%s\n' "$agent" >> "$managed"
  model=$(first_model "$role")
  file="$agents_dir/$agent.md"
  if [ ! -f "$file" ]; then
    printf 'WARNING: %s names "%s", which is not installed at %s — skipping it\n' \
      "$manifest" "$agent" "$file" >&2
    continue
  fi
  apply_agent "$agent" "$role" "$model" || status=2
done < "$work/manifest"

# Anything else in the agents directory belongs to somebody else: it is reported
# and left completely alone, never opened for writing (REQ-ENGINE-028).
for file in "$agents_dir"/*.md; do
  [ -f "$file" ] || continue
  agent=$(basename "$file" .md)
  grep -qxF -- "$agent" "$managed" && continue
  printf 'skipped %s: not named in %s — left unchanged (%s)\n' \
    "$agent" "$manifest" "$file"
  skipped=$((skipped + 1))
done

# The tally, always the same three counters in the same order so it can be read
# at a glance or grepped (REQ-ENGINE-013). Two clauses are appended to it:
# "no agent changed" states in words what `0 changed` says in a numeral, which
# is the second run's whole report (REQ-ENGINE-012); and a run in which some
# agent could not be written says so, because the counters above it are then the
# honest record of a PARTIAL application — what was written stays written, and
# the tally is what tells the owner how far the run got before it stopped.
tally=$(printf '%d changed, %d unchanged, %d skipped' \
  "$changed" "$unchanged" "$skipped")
if [ "$failed" -gt 0 ]; then
  printf '%s: %s, %d FAILED — the map is not fully applied.\n' \
    "$self" "$tally" "$failed"
elif [ "$changed" -eq 0 ]; then
  printf '%s: %s — no agent changed.\n' "$self" "$tally"
else
  printf '%s: %s.\n' "$self" "$tally"
fi

exit "$status"
