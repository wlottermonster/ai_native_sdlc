#!/bin/bash
# AI-Native SDLC — the engine-map mod in the policy and the documents, and the
# installed binding it sits beside. Covers REQ-MOD-022 (install.sh,
# apply-engines.sh and session-engines.sh keep working with the mod installed),
# REQ-MOD-023 (the Claude policy says when a map change applies, with and
# without the mod, and names the mod as routing, not enforcement), REQ-MOD-024
# (no model named in the mod folder, its tests or the documents this feature
# touches) and REQ-MOD-027 (ARCHITECTURE, the README file map and the manual's
# crew section in both languages describe the mod).
#
# Every install runs into a throwaway HOME under mktemp -d, removed on exit.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-mod-docs.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

policy_src="$repo/adapters/claude/policy.md"
policy="$repo/sdlc-policy.md"
arch="$repo/ARCHITECTURE.md"
readme="$repo/README.md"
manual="$repo/ainative_sdlc.html"
mod="$repo/adapters/claude/skills/sdlc-engine-map"

# ---------------------------------------------------------------------------
# REQ-MOD-023 — the policy, authored and rendered, says when a map change
# applies with and without the mod, and that the mod routes, never enforces.
req "REQ-MOD-023"

# The rendered copy is the one sessions read and PostCompact re-injects: the
# sentences must sit after the routing heading the hook cuts at.
for f in "$policy_src" "$policy"; do
  assert_fgrep 'with the mod loaded, a change to the map applies at the next dispatch' "$f"
  assert_fgrep 'apply-engines.sh` must be re-run' "$f"
  assert_fgrep 'routing, not enforcement' "$f"
  # shellcheck disable=SC2088  # a literal path in the policy, not a path to expand
  assert_fgrep '~/.claude/skills/sdlc-engine-map/' "$f"
  assert_order "$f" '^### Reading the engine map$' 'routing, not enforcement' '^\| Phase \| Who \| Role \|$'
done
assert_order "$policy" '^# AI-Native SDLC — routing policy' 'with the mod loaded, a change to the map applies at the next dispatch'

# The next-dispatch promise is qualified wherever it is made: it holds for a
# role-bound subagent dispatched without a model of its own. Read with the
# line breaks folded, since the Markdown wraps the sentence.
qualifier='applies at the next dispatch for a role-bound subagent dispatched without a model of its own'
flat() { tr '\n' ' ' < "$1" | tr -s ' ' > "$2"; }
for f in "$policy_src" "$policy"; do
  flat "$f" "$tmproot/flat.txt"
  assert_fgrep "$qualifier" "$tmproot/flat.txt"
done

# ---------------------------------------------------------------------------
# REQ-MOD-027 — ARCHITECTURE, the README file map and the manual.
req "REQ-MOD-027"

for f in "$arch" "$readme"; do
  flat "$f" "$tmproot/flat.txt"
  assert_fgrep "$qualifier" "$tmproot/flat.txt"
done

# ARCHITECTURE: a routing section of its own, after the enforcement table and
# before section 4, and the mod is not a row of that table.
assert_grep '^### Routing, not enforcement: the engine-map mod$' "$arch"
# The backticks are Markdown code spans, not command substitution.
# shellcheck disable=SC2016
assert_order "$arch" '^## 3\. Enforcement: the hooks$' '^\| `postcompact-policy\.sh` \|' \
  '^### Routing, not enforcement: the engine-map mod$' '^## 4\. '
assert_no_grep '^\| `?sdlc-engine-map' "$arch"
awk '/^### Routing, not enforcement: the engine-map mod$/ { inside = 1; next }
     /^##/ { inside = 0 } inside { print }' "$arch" > "$tmproot/arch-mod.txt"
assert_fgrep 'adapters/claude/skills/sdlc-engine-map/' "$tmproot/arch-mod.txt"
assert_fgrep 'agent.spawn' "$tmproot/arch-mod.txt"
assert_fgrep 'never blocks' "$tmproot/arch-mod.txt"
assert_fgrep 'cannot rescue the dispatch that fails' "$tmproot/arch-mod.txt"
assert_fgrep 'installed but not loaded' "$tmproot/arch-mod.txt"
assert_fgrep 'scripts/mod-check.sh' "$tmproot/arch-mod.txt"
assert_fgrep 'tests/test_mod.sh' "$tmproot/arch-mod.txt"
flat "$tmproot/arch-mod.txt" "$tmproot/arch-mod.flat"
assert_fgrep 'a failure after the hook has already passed the event on leaves the settled result standing' "$tmproot/arch-mod.flat"

# README: the file map lists the mod under the Claude adapter, and the
# apply-engines step stays where it was, in the file map and in "Project layer".
awk '$0 == "## Layout" { inside = 1; next } /^## / { inside = 0 } inside { print }' \
  "$readme" > "$tmproot/layout.txt"
awk '$0 == "## Project layer" { inside = 1; next } /^## / { inside = 0 } inside { print }' \
  "$readme" > "$tmproot/project-layer.txt"
assert_grep '^      skills/sdlc-engine-map/ +the engine-map mod' "$tmproot/layout.txt"
assert_order "$tmproot/layout.txt" '^    adapters/claude/ ' '^      skills/sdlc-engine-map/ ' '^    adapters/codex/ '
assert_grep '^      mod-check\.sh ' "$tmproot/layout.txt"
assert_grep '^      apply-engines\.sh +rewrites each installed agent' "$tmproot/layout.txt"
# shellcheck disable=SC2016  # Markdown code spans, not command substitution
assert_fgrep 'After editing the map, re-run `~/.claude/scripts/apply-engines.sh`' "$tmproot/project-layer.txt"
assert_fgrep 'with the engine-map mod loaded, a map change applies at the next dispatch' "$readme"

# The manual: the crew section in English, and its i18n string in Chinese.
awk 'index($0, "<h2>The crew") { inside = 1 } inside { print }
     inside && /<\/section>/ { exit }' "$manual" > "$tmproot/crew.txt"
assert_fgrep 'With the engine-map mod loaded, a change to the Claude role map applies to the next task handed out' "$tmproot/crew.txt"
assert_fgrep 'to a role-bound agent that names no model of its own' "$tmproot/crew.txt"
grep -o '"crew\.maps":"[^"]*"' "$manual" > "$tmproot/zh-crew-maps.txt"
assert_fgrep '套用到下一個分派的工作' "$tmproot/zh-crew-maps.txt"
assert_fgrep '限於綁定角色、且未自行指定模型的代理' "$tmproot/zh-crew-maps.txt"
assert_fgrep '重新執行套用步驟' "$tmproot/zh-crew-maps.txt"

# ---------------------------------------------------------------------------
# REQ-MOD-024 — the model-name pattern of tests/test_docs_roles.sh, read from
# that file so the two can never drift, finds nothing in the mod folder, its
# tests, or the documents this feature touches.
req "REQ-MOD-024"

MODELS=$(sed -n "s/^MODELS='\(.*\)'\$/\1/p" "$here/test_docs_roles.sh")
printf '%s\n' "$MODELS" > "$tmproot/pattern.txt"
# Guard: an empty pattern would match everything; a missing one nothing.
assert_grep '^\(\^\|\[\^A-Za-z\]\)\(' "$tmproot/pattern.txt"
# Positive control: the pattern still catches a model name. The name is put
# together at run time so this file does not trip its own check.
printf 'routes to %s here\n' "$(printf 'O%s' PUS)" > "$tmproot/control.txt"
assert_grep "$MODELS" "$tmproot/control.txt"

find "$mod" -type f > "$tmproot/mod-files.txt"
# The mod folder is not empty: its manifest and hooks module are there.
assert_file "$mod/.claude-plugin/plugin.json"
assert_file "$mod/hooks/register.ts"
assert_file "$mod/hooks/register.test.ts"
while IFS= read -r f; do
  assert_no_grep "$MODELS" "$f"
done < "$tmproot/mod-files.txt"
for f in "$policy_src" "$policy" "$arch" "$readme" "$manual" \
         "$repo/scripts/mod-check.sh" "$here/test_mod.sh" "$here/test_mod_install.sh" \
         "$here/test_mod_docs.sh" "$here/engine_map_cases.sh"; do
  if grep -nE -- "$MODELS" "$f" >/dev/null 2>&1; then
    printf 'REQ-MOD-024: model names in %s:\n' "$f" >&2
    grep -nE -- "$MODELS" "$f" >&2
  fi
  assert_no_grep "$MODELS" "$f"
done
for f in "$here"/fixtures/engine-map/*; do
  [ -f "$f" ] && assert_no_grep "$MODELS" "$f"
done

# ---------------------------------------------------------------------------
# REQ-MOD-022 — with the mod installed, install.sh still installs the
# SessionStart hook and runs the apply step, the agents' frontmatter follows
# the map, and a re-run of the installed apply-engines.sh after an edit to the
# map still moves it.
req "REQ-MOD-022"

scanroot=$(mktemp -d "$tmproot/scan.XXXXXX")
d=$(install_fixture "$tmproot")
h=$(fresh_home "$tmproot")
mkdir -p "$h/.claude"
cat > "$h/.claude/sdlc-engines.conf" <<'MAP'
# a test map: fixture names only
judge = fixture-judge
build = fixture-build, fixture-build-fallback
verify = fixture-verify
read = fixture-read
MAP
out="$tmproot/install.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc 0 "$out"
assert_grep 'Applying the engine map' "$out"

# The mod is installed: this is the case the requirement is about.
assert_file "$h/.claude/skills/sdlc-engine-map/.claude-plugin/plugin.json"
assert_file "$h/.claude/skills/sdlc-engine-map/hooks/register.ts"

# The installed scripts are the shipped ones, byte for byte.
for pair in "hooks/session-engines.sh:hooks/session-engines.sh" \
            "scripts/apply-engines.sh:scripts/apply-engines.sh"; do
  src="$repo/${pair%%:*}"
  dst="$h/.claude/${pair#*:}"
  if cmp -s "$src" "$dst"; then
    _test_pass "REQ-MOD-022 installed byte-identical: ${pair#*:}"
  else
    _test_fail "REQ-MOD-022 not installed byte-identical: ${pair#*:}"
  fi
done

# The frontmatter is the binding: each agent's model line follows the map.
assert_grep '^model: fixture-build$' "$h/.claude/agents/implementer.md"
assert_grep '^model: fixture-verify$' "$h/.claude/agents/verifier.md"
assert_grep '^model: fixture-verify$' "$h/.claude/agents/spec-reviewer.md"
assert_grep '^model: fixture-read$' "$h/.claude/agents/researcher.md"

# The SessionStart statement still names the map it runs under.
capture "$tmproot/session.out" env HOME="$h" bash "$h/.claude/hooks/session-engines.sh" < /dev/null
assert_rc 0 "$tmproot/session.out"
assert_fgrep 'SessionStart' "$tmproot/session.out"
assert_fgrep 'build = fixture-build, fixture-build-fallback' "$tmproot/session.out"

# Without the mod, an edit to the map applies after a re-run of the installed
# apply step; that step still works.
sed 's/^build = .*/build = fixture-build-edited/' "$h/.claude/sdlc-engines.conf" > "$tmproot/map.new"
cp "$tmproot/map.new" "$h/.claude/sdlc-engines.conf"
capture "$tmproot/reapply.out" env HOME="$h" bash "$h/.claude/scripts/apply-engines.sh"
assert_rc 0 "$tmproot/reapply.out"
assert_grep '^model: fixture-build-edited$' "$h/.claude/agents/implementer.md"
assert_grep '^model: fixture-verify$' "$h/.claude/agents/verifier.md"

finish
