#!/bin/bash
# AI-Native SDLC — install.sh shadow-scan tests. Covers REQ-GCORE-008 (one
# WARNING line per project command that shadows a global one), REQ-GCORE-009
# (repos that shadow nothing produce no WARNING and the run still reaches its
# "Done." banner with exit 0) and REQ-GCORE-035 (scan root = $SDLC_SCAN_ROOT
# else the parent of the framework checkout; at most 4 directory levels below
# the root; symlinks not followed; unreadable subtrees ignored silently).
#
# Every run installs into a throwaway HOME from a fixture copy of the repo and
# scans a throwaway scan root, both under mktemp -d and removed on exit: no
# test here reads or writes the real $HOME/.claude, and no scan ever touches
# the real workspace.
#
# Depth arithmetic (REQ-GCORE-035). The scan is
# `find "$root" -maxdepth 4 -type d -path '*/.claude/commands'`, so the
# .claude/commands directory itself must sit at most 4 levels below the root.
# Counting every component of the path, .claude and commands included:
#   <root>/repo/.claude/commands            -> depth 3, FOUND
#   <root>/group/repo/.claude/commands      -> depth 4, FOUND (the umbrella
#                                              layout: a repo nested one level
#                                              inside a grouping directory)
#   <root>/g1/g2/repo/.claude/commands      -> depth 5, NOT found (one level
#                                              past the limit — the boundary)
# So a repo may be a direct child of the scan root or sit one grouping level
# below it, and no deeper. The fixtures below cover all three rows.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

# Normalised through `cd`+`pwd`: a $TMPDIR with a trailing slash makes mktemp
# hand back a path containing "//", which install.sh's own `cd ... && pwd`
# collapses. The fallback-root assertions below compare against paths the
# installer printed, so both sides have to be spelled the same way.
tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-shadow.XXXXXX")
tmproot=$(cd "$tmproot" && pwd)
# The unreadable-subtree fixture below leaves a chmod 000 directory behind if
# the run is interrupted, so the trap reopens the tree before removing it.
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { chmod -R u+rwx "$tmproot" 2>/dev/null; rm -rf "$tmproot"; }
trap cleanup EXIT

# plant <dir> <name>... — make <dir>/.claude/commands and put a stub command
# file there for each <name>.
plant() {
  local d="$1"
  shift
  mkdir -p "$d/.claude/commands"
  local n
  for n in "$@"; do
    printf 'project command %s\n' "$n" > "$d/.claude/commands/$n.md"
  done
}

# ---------------------------------------------------------------------------
req "REQ-GCORE-008"
# A scan root holding a repo whose .claude/commands/<name>.md matches one of the
# framework's own commands gets exactly one WARNING line per shadow, naming the
# repo directory and the shadowed global command — and the run still exits 0.
scan=$(mktemp -d "$tmproot/scan.XXXXXX")
plant "$scan/repo-a" spec mine     # /spec shadows, /mine does not
mkdir -p "$scan/repo-b"            # no .claude at all
plant "$scan/outer" ship           # second shadowing repo, direct child
plant "$scan/nested/inner" ship    # depth 4 — grouped repo, at the limit
plant "$scan/g1/g2/repo" build     # depth 5 — one level past the limit
plant "$scan/a/b/c/d" build        # far past the limit
ln -s "$scan/repo-a" "$scan/link-to-a"
d=$(install_fixture "$tmproot")
h=$(fresh_home "$tmproot")
out="$tmproot/shadow.out"
run_install "$d" "$h" "$scan" "$out"
assert_rc 0 "$out"
assert_grep "^WARNING: $scan/repo-a shadows global /spec \(project wins\)$" "$out"
assert_grep "^WARNING: $scan/outer shadows global /ship \(project wins\)$" "$out"
count_into "$out" "^WARNING: $scan/repo-a shadows global /spec \(project wins\)$" "$tmproot/c-spec"
assert_grep '^1$' "$tmproot/c-spec"
count_into "$out" "^WARNING: $scan/outer shadows global /ship \(project wins\)$" "$tmproot/c-ship"
assert_grep '^1$' "$tmproot/c-ship"
# A repo grouped one level below the scan root is reported the same way, and
# the repo directory named is the repo itself, not the grouping directory.
assert_grep "^WARNING: $scan/nested/inner shadows global /ship \(project wins\)$" "$out"
count_into "$out" "^WARNING: $scan/nested/inner shadows global /ship \(project wins\)$" "$tmproot/c-nested"
assert_grep '^1$' "$tmproot/c-nested"
# The non-shadowing command in the very same directory is not reported.
assert_no_grep 'shadows global /mine' "$out"
# The banner is still reached.
assert_grep '^Done\.' "$out"

# ---------------------------------------------------------------------------
req "REQ-GCORE-009"
# A scan root whose repos shadow nothing — one with no .claude directory at all,
# one whose project commands have no global counterpart — produces no WARNING
# line, reaches "Done." and exits 0.
scan=$(mktemp -d "$tmproot/scan.XXXXXX")
mkdir -p "$scan/repo-b"
plant "$scan/repo-nc" mine notes
d=$(install_fixture "$tmproot")
h=$(fresh_home "$tmproot")
out="$tmproot/noshadow.out"
run_install "$d" "$h" "$scan" "$out"
assert_rc 0 "$out"
assert_no_grep '^WARNING:' "$out"
assert_grep '^Done\.' "$out"

# An empty scan root is equally quiet — the no-match path of every glob and
# pipeline must not abort the script under `set -euo pipefail`.
scan=$(mktemp -d "$tmproot/scan.XXXXXX")
d=$(install_fixture "$tmproot")
h=$(fresh_home "$tmproot")
out="$tmproot/emptyscan.out"
run_install "$d" "$h" "$scan" "$out"
assert_rc 0 "$out"
assert_no_grep '^WARNING:' "$out"
assert_grep '^Done\.' "$out"

# ---------------------------------------------------------------------------
req "REQ-GCORE-035"
# Symlinks are not followed: link-to-a -> repo-a in the first scan root above
# must not yield a second warning naming the link.
assert_no_grep 'link-to-a' "$tmproot/shadow.out"
count_into "$tmproot/shadow.out" '^WARNING: .* shadows global ' "$tmproot/c-all"
assert_grep '^3$' "$tmproot/c-all"
# Past the depth limit: the depth-5 grouped repo (one level beyond the limit)
# and the far deeper a/b/c/d are both silent. Both plant a /build shadow that
# would be reported were they in range, so the absence of any /build warning is
# what proves the limit — not merely the absence of those path names.
assert_no_grep 'shadows global /build' "$tmproot/shadow.out"
assert_no_grep 'g1/g2/repo' "$tmproot/shadow.out"
assert_no_grep 'a/b/c/d' "$tmproot/shadow.out"

# An unreadable subtree is skipped silently — no error text, still exit 0.
scan=$(mktemp -d "$tmproot/scan.XXXXXX")
plant "$scan/repo-a" spec
mkdir -p "$scan/locked/sub"
chmod 000 "$scan/locked"
d=$(install_fixture "$tmproot")
h=$(fresh_home "$tmproot")
out="$tmproot/unreadable.out"
run_install "$d" "$h" "$scan" "$out"
chmod 755 "$scan/locked"
assert_rc 0 "$out"
assert_grep "^WARNING: $scan/repo-a shadows global /spec \(project wins\)$" "$out"
assert_no_grep 'Permission denied' "$out"
assert_grep '^Done\.' "$out"

# With SDLC_SCAN_ROOT unset the root falls back to the parent of the framework
# checkout: the fixture is created inside its own isolated parent, and a
# shadowing repo planted beside it must be found.
parent=$(mktemp -d "$tmproot/parent.XXXXXX")
d=$(install_fixture "$parent")
plant "$parent/repo-f" build
h=$(fresh_home "$tmproot")
out="$tmproot/fallback.out"
run_install "$d" "$h" "-" "$out"
assert_rc 0 "$out"
assert_grep "^WARNING: $parent/repo-f shadows global /build \(project wins\)$" "$out"
assert_grep '^Done\.' "$out"

# The global command directory is never reported as a repo: with the throwaway
# HOME placed inside the scan root (a checkout cloned directly under $HOME puts
# $HOME/.claude/commands in range at depth 2), the commands the installer has
# just copied there must not be listed as shadowing themselves.
scan=$(mktemp -d "$tmproot/scan.XXXXXX")
h=$(mktemp -d "$scan/home.XXXXXX")
plant "$scan/repo-a" spec
d=$(install_fixture "$tmproot")
out="$tmproot/homeinroot.out"
run_install "$d" "$h" "$scan" "$out"
assert_rc 0 "$out"
assert_grep "^WARNING: $scan/repo-a shadows global /spec \(project wins\)$" "$out"
assert_no_grep 'shadows global /build' "$out"
assert_no_grep "^WARNING: $h " "$out"
count_into "$out" '^WARNING: .* shadows global ' "$tmproot/c-homeinroot"
assert_grep '^1$' "$tmproot/c-homeinroot"

# An SDLC_SCAN_ROOT that is not a directory falls back the same way.
h=$(fresh_home "$tmproot")
out="$tmproot/badroot.out"
run_install "$d" "$h" "$parent/does-not-exist" "$out"
assert_rc 0 "$out"
assert_grep "^WARNING: $parent/repo-f shadows global /build \(project wins\)$" "$out"
assert_grep '^Done\.' "$out"

finish
