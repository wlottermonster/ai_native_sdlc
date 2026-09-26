#!/bin/bash
# AI-Native SDLC — installer tests. Covers REQ-GCORE-005 (install.sh never
# deletes a file under $HOME/.claude it did not install in this run),
# REQ-GCORE-034 (it warns about a stale morning.md/overnight.md and leaves it
# in place) and REQ-GCORE-028 (the new rca / test-audit / test-auditor prompt
# files are carried by the existing install loops).
#
# It also covers the engine map's install half: REQ-ENGINE-007 (a fresh HOME
# gets the map from the template), REQ-ENGINE-008 (an existing map survives
# byte-for-byte), REQ-ENGINE-015 (install.sh runs scripts/apply-engines.sh and
# exits non-zero when it fails) and REQ-ENGINE-030's install half (the role
# manifest is installed beside the agents).
#
# Every run installs into a throwaway HOME from a fixture copy of the repo, both
# under mktemp -d and removed on exit: no test here reads or writes the real
# $HOME/.claude.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-install.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

# SDLC_SCAN_ROOT is pinned to an empty directory so install.sh's shadow scan
# (REQ-GCORE-008/009/035, covered by tests/test_shadow.sh) finds nothing here:
# without it the scan would fall back to the parent of the fixture — this
# suite's own $tmproot — and report every throwaway HOME it has already
# installed into. These tests are about what the installer copies, not what it
# scans.
scanroot=$(mktemp -d "$tmproot/scan.XXXXXX")

# ---------------------------------------------------------------------------
req "REQ-GCORE-005"
# install.sh must not delete anything under $HOME/.claude that it did not
# install in this run — neither an unrelated user command nor the renamed-away
# morning.md it used to `rm -f`.
d=$(install_fixture "$tmproot")
h=$(fresh_home "$tmproot")
mkdir -p "$h/.claude/commands"
printf 'my own command\n' > "$h/.claude/commands/unrelated.md"
printf 'stale morning command\n' > "$h/.claude/commands/morning.md"
printf 'stale overnight command\n' > "$h/.claude/commands/overnight.md"
out="$tmproot/keep.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc 0 "$out"
# Pre-existing files survive the run untouched.
assert_file "$h/.claude/commands/unrelated.md"
assert_file "$h/.claude/commands/morning.md"
assert_file "$h/.claude/commands/overnight.md"
assert_grep '^my own command$' "$h/.claude/commands/unrelated.md"
assert_grep '^stale morning command$' "$h/.claude/commands/morning.md"
assert_grep '^stale overnight command$' "$h/.claude/commands/overnight.md"
# The files install.sh does install are present, so "deletes nothing" was not
# bought by installing nothing.
assert_file "$h/.claude/commands/build.md"
assert_file "$h/.claude/commands/ship.md"
assert_file "$h/.claude/agents/verifier.md"
assert_file "$h/.claude/hooks/req-gate.sh"
assert_file "$h/.claude/scripts/trace-matrix.sh"
assert_file "$h/.claude/sdlc-policy.md"

# ---------------------------------------------------------------------------
req "REQ-GCORE-034"
# The stale files above are reported by name, with the instruction to delete
# them by hand. (Same run as the block above — $out still holds its output.)
assert_grep 'WARNING: stale command' "$out"
assert_grep "WARNING: stale command $h/\.claude/commands/morning\.md from an older version — delete it yourself" "$out"
assert_grep "WARNING: stale command $h/\.claude/commands/overnight\.md from an older version — delete it yourself" "$out"

# Only one of the two present: only that one is named.
h=$(fresh_home "$tmproot")
mkdir -p "$h/.claude/commands"
printf 'stale overnight command\n' > "$h/.claude/commands/overnight.md"
out="$tmproot/one-stale.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc 0 "$out"
assert_grep 'WARNING: stale command .*overnight\.md' "$out"
assert_no_grep 'WARNING: stale command .*morning\.md' "$out"

# A HOME with no stale files produces no such warning at all.
h=$(fresh_home "$tmproot")
out="$tmproot/clean.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc 0 "$out"
assert_no_grep 'WARNING: stale command' "$out"
assert_grep '^Done\.' "$out"

# ---------------------------------------------------------------------------
req "REQ-GCORE-028"
# commands/rca.md, commands/test-audit.md and agents/test-auditor.md are
# carried by the existing install loops. Their real content is written by other
# tasks; what is proved here is the mechanism, so the three files are planted as
# stubs in the fixture copy of the repo — never in the real repo.
d=$(install_fixture "$tmproot")
h=$(fresh_home "$tmproot")
printf -- '--- rca stub ---\n' > "$d/commands/rca.md"
printf -- '--- test-audit stub ---\n' > "$d/commands/test-audit.md"
printf -- '--- test-auditor stub ---\n' > "$d/agents/test-auditor.md"
out="$tmproot/newfiles.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc 0 "$out"
assert_file "$h/.claude/commands/rca.md"
assert_file "$h/.claude/commands/test-audit.md"
assert_file "$h/.claude/agents/test-auditor.md"
assert_grep 'rca stub' "$h/.claude/commands/rca.md"
assert_grep 'test-audit stub' "$h/.claude/commands/test-audit.md"
assert_grep 'test-auditor stub' "$h/.claude/agents/test-auditor.md"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-030"
# The role manifest installs alongside the agent prompts, so the installed copy
# of apply-engines.sh is runnable on its own. `cmp` (not just "a file exists")
# proves it is the manifest this checkout ships.
d=$(install_fixture "$tmproot")
h=$(fresh_home "$tmproot")
out="$tmproot/roles.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc 0 "$out"
assert_file "$h/.claude/agents/roles.conf"
capture "$tmproot/roles-cmp.out" cmp -s "$h/.claude/agents/roles.conf" "$d/agents/roles.conf"
assert_rc 0 "$tmproot/roles-cmp.out"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-007"
# A HOME with no engine map gets one from the template, byte-for-byte, and the
# installer says it created it and that it is the owner's to edit. (Same run as
# the REQ-ENGINE-030 block above — $h and $out still hold it.)
assert_file "$h/.claude/sdlc-engines.conf"
capture "$tmproot/map-fresh-cmp.out" \
  cmp -s "$h/.claude/sdlc-engines.conf" "$d/templates/sdlc-engines.conf"
assert_rc 0 "$tmproot/map-fresh-cmp.out"
assert_grep 'created' "$out"
assert_grep "$h/\.claude/sdlc-engines\.conf" "$out"
assert_grep 'yours to edit' "$out"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-008"
# An engine map already in HOME is left byte-for-byte alone, whatever the
# template says. The planted map is deliberately DIFFERENT from the template —
# different models, and a sentinel comment the template does not contain — so an
# unconditional `cp` would be caught by the cmp below, not hidden by two files
# that happened to match.
h=$(fresh_home "$tmproot")
mkdir -p "$h/.claude"
mine="$h/.claude/sdlc-engines.conf"
cat > "$mine" <<'MAP'
# SENTINEL-MY-OWN-ENGINE-MAP — hand-edited, must survive every re-install
judge = my-judge-model
build = my-build-model
verify = my-verify-model
read = my-read-model
escalate = my-escalate-model
MAP
before="$tmproot/map-before.conf"
cp "$mine" "$before"
out="$tmproot/map-kept.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc 0 "$out"
# Byte-for-byte unchanged...
capture "$tmproot/map-kept-cmp.out" cmp -s "$mine" "$before"
assert_rc 0 "$tmproot/map-kept-cmp.out"
# ...and still not the template, so "unchanged" was not bought by the two files
# being identical in the first place.
capture "$tmproot/map-kept-vs-template.out" \
  cmp -s "$mine" "$d/templates/sdlc-engines.conf"
assert_rc nonzero "$tmproot/map-kept-vs-template.out"
assert_grep '^# SENTINEL-MY-OWN-ENGINE-MAP' "$mine"
assert_grep '^judge = my-judge-model$' "$mine"
assert_no_grep 'created' "$out"
assert_grep 'kept your existing engine map' "$out"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-015"
# Positive control first: the shipped map applies cleanly, install.sh reports
# that it ran the apply step and exits 0.
h=$(fresh_home "$tmproot")
out="$tmproot/apply-ok.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc 0 "$out"
assert_grep 'Applying the engine map' "$out"

# A map install.sh cannot apply — a line with no `=` — makes install.sh fail.
h=$(fresh_home "$tmproot")
mkdir -p "$h/.claude"
cat > "$h/.claude/sdlc-engines.conf" <<'MAP'
# a map with a line that is not <role> = <model>
build opus
verify = opus
read = haiku
MAP
out="$tmproot/apply-broken.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc nonzero "$out"
# The failure is reported as the apply step's, naming the map to fix. (A bare
# /apply-engines\.sh/ would match the `cp -v` line that installs the script, so
# the pattern is pinned to the error line install.sh prints itself.)
assert_grep 'ERROR: scripts/apply-engines\.sh failed' "$out"
assert_grep "$h/\.claude/sdlc-engines\.conf" "$out"
# It failed at the apply step, not before it: the run got far enough to try.
assert_grep 'Applying the engine map' "$out"
# And it stopped there — the closing instructions never printed.
assert_no_grep '^Done\.' "$out"

# ---------------------------------------------------------------------------
# The closing instructions: REQ-ENGINE-021 (the settings merge is the owner's,
# and why, with the SessionStart entry named as newly added) and REQ-ENGINE-026
# (no reference to the deleted sdlc_llm command).
#
# One clean run feeds both blocks. Its closing block is extracted from "Done."
# to the end of the output, so an assertion cannot be satisfied by a `cp -v`
# line or a progress message earlier in the run.
d=$(install_fixture "$tmproot")
h=$(fresh_home "$tmproot")
out="$tmproot/closing.out"
run_install "$d" "$h" "$scanroot" "$out"
assert_rc 0 "$out"
closing="$tmproot/closing-block.txt"
awk '/^Done\./ { inblock = 1 } inblock { print }' "$out" > "$closing"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-021"

# The block exists at all (guards every assertion below against a vacuous pass
# on an empty extraction).
assert_grep '^Done\.' "$closing"

# (a) The merge is named, and handed to the owner...
assert_grep 'settings/hooks-snippet\.json' "$closing"
# shellcheck disable=SC2016  # a literal path in the installer's text, not an expansion
assert_fgrep 'This merge is yours: the session cannot edit ~/.claude/settings.json' "$closing"
# ...with the helper that prints the merge, and no owner-specific entry named.
# shellcheck disable=SC2088  # a literal path in the installer's text
assert_fgrep '~/.claude/scripts/merge-settings.sh' "$closing"
assert_fgrep 'your existing entries survive the merge' "$closing"
assert_no_grep 'KEEP the existing' "$closing"
if [ -x "$h/.claude/scripts/merge-settings.sh" ]; then
  _test_pass "installed and executable: merge-settings.sh"
else
  _test_fail "not installed or not executable: $h/.claude/scripts/merge-settings.sh"
fi

# (b) ...with the SessionStart entry named as the newly added one.
assert_grep 'newly added .*SessionStart' "$closing"
assert_grep 'session-engines\.sh' "$closing"

# (c) The engine map is named, where it lives, and how an edit to it is
#     applied — re-running the applier.
# shellcheck disable=SC2016  # literal paths in the installer's text
assert_fgrep 'Your engine map is ~/.claude/sdlc-engines.conf' "$closing"
assert_grep 'apply-engines\.sh' "$closing"
assert_grep 'applies the edit' "$closing"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-026"

# The deleted command is gone from the closing instructions — and from the
# installer's whole output, so it cannot survive in a warning either.
assert_no_grep 'sdlc_llm' "$closing"
assert_no_grep 'sdlc_llm' "$out"

finish
