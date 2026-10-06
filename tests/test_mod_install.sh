#!/bin/bash
# AI-Native SDLC — the engine-map mod's install half. Covers REQ-MOD-001 (the
# mod folder is installed through the existing skills path and settings.json is
# byte-identical across the install) and REQ-MOD-025 (the skills path skips the
# files the engine lays beside a loaded mod, and git ignores them).
#
# The mod folder is built inside a FIXTURE copy of the repo, so this suite does
# not depend on the real mod's contents. Every run installs into a throwaway
# HOME under mktemp -d, removed on exit: nothing here touches the real
# $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-mod-install.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

scanroot=$(mktemp -d "$tmproot/scan.XXXXXX")

plugin_files=".claude-plugin/plugin.json hooks/hooks.json hooks/register.ts hooks/register.test.ts"
skipped_files=".DS_Store .claude-plugin/types/claude-code/index.d.ts tsconfig.json node_modules/x/index.js"

d=$(install_fixture "$tmproot")
mod="$d/adapters/claude/skills/sdlc-engine-map"
mkdir -p "$mod/.claude-plugin/types/claude-code" "$mod/hooks" "$mod/node_modules/x"
printf '{"name": "sdlc-engine-map"}\n' > "$mod/.claude-plugin/plugin.json"
printf '{"hooks": {}}\n' > "$mod/hooks/hooks.json"
printf 'export default {};\n' > "$mod/hooks/register.ts"
printf 'test("x", () => {});\n' > "$mod/hooks/register.test.ts"
printf 'finder\n' > "$mod/.DS_Store"
printf 'export {};\n' > "$mod/.claude-plugin/types/claude-code/index.d.ts"
printf '{}\n' > "$mod/tsconfig.json"
printf 'module.exports = 1;\n' > "$mod/node_modules/x/index.js"

h=$(fresh_home "$tmproot")
mkdir -p "$h/.claude"
printf '{\n  "theme": "light",\n  "custom": {"keep": [1, 2, 3]}\n}\n' > "$h/.claude/settings.json"
cp "$h/.claude/settings.json" "$tmproot/settings.before"

out="$tmproot/install.out"
run_install "$d" "$h" "$scanroot" "$out"
installed="$h/.claude/skills/sdlc-engine-map"
receipt="$h/.claude/doctor-installation.json"
jq -r '.managed_files | keys[]' "$receipt" > "$tmproot/managed.txt" 2>/dev/null || : > "$tmproot/managed.txt"
jq -r '.source_files | keys[]' "$receipt" > "$tmproot/sources.txt" 2>/dev/null || : > "$tmproot/sources.txt"

# ---------------------------------------------------------------------------
req "REQ-MOD-001"
assert_rc 0 "$out"
for f in $plugin_files; do
  if cmp -s "$mod/$f" "$installed/$f"; then
    _test_pass "REQ-MOD-001 installed byte-identical: $f"
  else
    _test_fail "REQ-MOD-001 not installed byte-identical: $f"
  fi
  assert_fgrep "/.claude/skills/sdlc-engine-map/$f" "$tmproot/managed.txt"
done
if cmp -s "$tmproot/settings.before" "$h/.claude/settings.json"; then
  _test_pass "REQ-MOD-001 settings.json byte-identical across install"
else
  _test_fail "REQ-MOD-001 settings.json changed by install"
fi

# A second install over the owned, unchanged mod succeeds, and a customized
# installed file is refused by the existing ownership check, not overwritten.
out2="$tmproot/install2.out"
run_install "$d" "$h" "$scanroot" "$out2"
assert_rc 0 "$out2"
printf 'owner edit\n' > "$installed/hooks/register.ts"
out3="$tmproot/install3.out"
run_install "$d" "$h" "$scanroot" "$out3"
assert_rc nonzero "$out3"
assert_grep '^owner edit$' "$installed/hooks/register.ts"

# ---------------------------------------------------------------------------
req "REQ-MOD-025"
for f in $skipped_files; do
  if [ -e "$installed/$f" ]; then
    _test_fail "REQ-MOD-025 skipped file was installed: $f"
  else
    _test_pass "REQ-MOD-025 not installed: $f"
  fi
  assert_no_grep "sdlc-engine-map/$f\$" "$tmproot/managed.txt"
  assert_no_grep "sdlc-engine-map/$f\$" "$tmproot/sources.txt"
done
for sub in .claude-plugin/types node_modules; do
  if [ -e "$installed/$sub" ]; then
    _test_fail "REQ-MOD-025 skipped directory was created: $sub"
  else
    _test_pass "REQ-MOD-025 directory not created: $sub"
  fi
done

# The names live in the adapter's exclusion list. A source without that list
# cannot filter its skills, so the install refuses rather than copying litter.
d_nolist=$(install_fixture "$tmproot")
cp -R "$mod" "$d_nolist/adapters/claude/skills/"
rm -f "$d_nolist/adapters/claude/skill-exclusions.txt"
h_nolist=$(fresh_home "$tmproot")
out4="$tmproot/install-nolist.out"
run_install "$d_nolist" "$h_nolist" "$scanroot" "$out4"
assert_rc nonzero "$out4"
if [ -e "$h_nolist/.claude/skills/sdlc-engine-map/tsconfig.json" ]; then
  _test_fail "REQ-MOD-025 install without the exclusion list copied litter"
else
  _test_pass "REQ-MOD-025 install without the exclusion list copied no litter"
fi

# The same names are ignored by git in the mod folder of the real checkout,
# and the plugin files themselves are not.
for f in $skipped_files; do
  assert_exit 0 git -C "$TEST_REPO" check-ignore -q --no-index \
    "adapters/claude/skills/sdlc-engine-map/$f"
done
for f in $plugin_files; do
  assert_exit 1 git -C "$TEST_REPO" check-ignore -q --no-index \
    "adapters/claude/skills/sdlc-engine-map/$f"
done

# ---------------------------------------------------------------------------
# The INSTALLED copy of scripts/mod-check.sh (~/.claude/scripts/) finds the
# installed mod (~/.claude/skills/), and with no mod in either layout it fails
# loudly. The real mod is installed here, from an untouched fixture.
req "REQ-MOD-002"
d_real=$(install_fixture "$tmproot")
h_real=$(fresh_home "$tmproot")
out5="$tmproot/install-real.out"
run_install "$d_real" "$h_real" "$scanroot" "$out5"
assert_rc 0 "$out5"
installed_check="$h_real/.claude/scripts/mod-check.sh"
assert_file "$installed_check"
if command -v claude >/dev/null 2>&1; then
  out6="$tmproot/installed-validate.out"
  capture "$out6" bash "$installed_check" validate
  assert_rc 0 "$out6"
  assert_fgrep 'Validation passed' "$out6"
  assert_fgrep "${h_real##*/}/.claude/skills/sdlc-engine-map/.claude-plugin/plugin.json" "$out6"
elif [ "${SDLC_SKIP_CLAUDE_MOD:-}" = "1" ]; then
  printf '     mod checks NOT run: claude is not on PATH (SDLC_SKIP_CLAUDE_MOD=1: the installed validate is skipped)\n'
else
  _test_fail "mod checks NOT run: claude is not on PATH (set SDLC_SKIP_CLAUDE_MOD=1 to skip explicitly)"
fi

mkdir -p "$tmproot/nomod/scripts"
cp "$installed_check" "$tmproot/nomod/scripts/mod-check.sh"
out7="$tmproot/nomod-validate.out"
capture "$out7" env SDLC_SKIP_CLAUDE_MOD=1 bash "$tmproot/nomod/scripts/mod-check.sh" validate
assert_rc nonzero "$out7"
assert_fgrep 'mod-check: no mod at' "$out7"

finish
