#!/bin/bash
# AI-Native SDLC — publish.sh is the only road to the public repository, and it
# must refuse before anything leaves the machine: no usable token list, a
# private token anywhere in the export (contents, names, symlink targets), a
# binary file, a private path surviving the exclusion, or a sweep that could
# not run. A dry run proves the export shape; a real run against a local bare
# repository proves the commit that lands.
#
# Every refusal is proved by mutation: the same fixture passes clean and fails
# once the thing is planted, so a green run cannot come from scanning nothing.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

# Selectors inherited from a calling git (a hook, a worktree) must not leak
# into the fixtures below.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-publish-test.XXXXXX")
tmpdir=$(cd "$tmpdir" && pwd -P)
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# publish.sh keeps a dry run's export in TMPDIR on purpose (the owner opens it
# before a real publish). This file runs dozens of dry runs, so they go under
# the test's own directory: the suite leaves nothing behind in the machine's
# temp folder, and the end of this file proves it.
system_tmp=${TMPDIR:-/tmp}
export TMPDIR="$tmpdir/exports"
mkdir -p "$TMPDIR"
touch "$tmpdir/started"

real_grep=$(command -v grep)

gcommit() {
  local d="$1"
  shift
  git -C "$d" -c user.name=t -c user.email=sdlc-test@example.invalid \
      -c commit.gpgsign=false commit -q "$@"
}

# mkfx <dir> — a fixture repository on main: framework files, a symlink, a
# force-tracked ignored file, and every kind of private working note.
mkfx() {
  local d="$1"
  git init -q -b main "$d"
  mkdir -p "$d/docs" "$d/core" "$d/specs/feat" "$d/specs/_shipped/old/deep" \
           "$d/specs/workspace-interoperability" "$d/specs/portability-step5" \
           "$d/specs/portability-step6" "$d/adapters/codex/docs" \
           "$d/specs/_shipped/2026-09-03-generic-core"
  printf 'framework file\n' > "$d/core/policy.md"
  printf 'private workspace log\n' > "$d/docs/log.md"
  printf 'requirements\n' > "$d/specs/feat/requirements.md"
  printf 'kept: not a ledger\n' > "$d/specs/feat/handoff-notes.md"
  printf 'ledger\n' > "$d/specs/feat/handoff.md"
  printf 'ledger\n' > "$d/specs/handoff.md"
  printf 'ledger\n' > "$d/specs/_shipped/old/deep/handoff.md"
  printf 'private\n' > "$d/specs/workspace-interoperability/notes.md"
  printf 'private\n' > "$d/specs/portability-step5/notes.md"
  printf 'private\n' > "$d/specs/portability-step6/notes.md"
  printf 'names earlier products\n' > "$d/specs/_shipped/2026-09-03-generic-core/requirements.md"
  printf 'session log\n' > "$d/adapters/codex/docs/verification.md"
  printf 'design\n' > "$d/adapters/codex/docs/design.md"
  printf '*.log\n' > "$d/.gitignore"
  printf 'tracked although ignored\n' > "$d/keep.log"
  ln -s core/policy.md "$d/link.md"
  cp "$repo/publish.sh" "$d/publish.sh"
  git -C "$d" add -A
  git -C "$d" add -f keep.log
  gcommit "$d" -m clean
}

fx="$tmpdir/fixture"
mkfx "$fx"

tokens="$tmpdir/tokens"
printf '# fixture list\nsecretproject\n\n' > "$tokens"

# run_pub <out> [env assignments...] -- <publish args...>
run_pub() {
  local out="$1"
  shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  capture "$out" env SDLC_SCRUB_TOKENS_FILE="$tokens" ${envs[@]+"${envs[@]}"} "$fx/publish.sh" "$@"
}

export_of() {
  sed -n 's/^publish: dry run — export left at \(.*\), nothing pushed$/\1/p' "$1"
}

# ---------------------------------------------------------------------------
req "REQ-PUB-001"   # no usable token list: refuse, publish nothing

capture "$tmpdir/notokens.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/missing" "$fx/publish.sh" --dry-run main
assert_rc nonzero "$tmpdir/notokens.out"
assert_grep 'refusing to publish unswept' "$tmpdir/notokens.out"

: > "$tmpdir/empty"
capture "$tmpdir/emptytokens.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/empty" "$fx/publish.sh" --dry-run main
assert_rc nonzero "$tmpdir/emptytokens.out"
assert_grep 'refusing to publish unswept' "$tmpdir/emptytokens.out"

# Comments, blank lines and whitespace-only lines (CRLF included) are not tokens.
printf '# only a comment\r\n   \r\n\t\n' > "$tmpdir/hollow"
capture "$tmpdir/hollow.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/hollow" "$fx/publish.sh" --dry-run main
assert_rc nonzero "$tmpdir/hollow.out"
assert_grep 'refusing to publish unswept' "$tmpdir/hollow.out"

# A token shorter than three characters would match everything: a mistake.
printf 'secretproject\nab\n' > "$tmpdir/short"
capture "$tmpdir/short.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/short" "$fx/publish.sh" --dry-run main
assert_rc nonzero "$tmpdir/short.out"
assert_grep 'shorter than 3' "$tmpdir/short.out"

# Every run names the list it used and how many tokens it holds.
printf '# c\n  secretproject  \r\nanother-token\r\n' > "$tmpdir/crlf"
capture "$tmpdir/count.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/crlf" "$fx/publish.sh" --dry-run main
assert_rc 0 "$tmpdir/count.out"
assert_fgrep "token list $tmpdir/crlf: 2 tokens" "$tmpdir/count.out"

# ---------------------------------------------------------------------------
req "REQ-PUB-002"   # clean export: private notes gone, framework files present

run_pub "$tmpdir/clean.out" -- --dry-run main
assert_rc 0 "$tmpdir/clean.out"
assert_grep 'is clean' "$tmpdir/clean.out"
assert_grep 'dry run' "$tmpdir/clean.out"
export_dir=$(export_of "$tmpdir/clean.out")
printf '%s\n' "$export_dir" > "$tmpdir/export_dir"
assert_grep '/export$' "$tmpdir/export_dir"
for kept in core/policy.md specs/feat/requirements.md specs/feat/handoff-notes.md \
            adapters/codex/docs/design.md keep.log .gitignore link.md; do
  if [ -e "$export_dir/$kept" ] || [ -L "$export_dir/$kept" ]; then
    _test_pass "kept in export: $kept"
  else
    _test_fail "missing from export: $kept"
  fi
done
for gone in docs specs/feat/handoff.md specs/handoff.md specs/_shipped/old/deep/handoff.md \
            specs/workspace-interoperability specs/portability-step5 specs/portability-step6 \
            specs/_shipped/2026-09-03-generic-core adapters/codex/docs/verification.md; do
  if [ -e "$export_dir/$gone" ] || [ -L "$export_dir/$gone" ]; then
    _test_fail "private path survived the export: $gone"
  else
    _test_pass "excluded from export: $gone"
  fi
done

# Mutation: with the exclusion switched off, the independent survivor check
# must refuse and name what survived — docs/ and every handoff.md.
run_pub "$tmpdir/survive.out" SDLC_PUBLISH_TEST_KEEP_PRIVATE=1 -- --dry-run main
assert_rc nonzero "$tmpdir/survive.out"
assert_grep 'private path survived' "$tmpdir/survive.out"
assert_grep 'survived.*: docs$' "$tmpdir/survive.out"
assert_grep 'survived.*: specs/feat/handoff\.md$' "$tmpdir/survive.out"
assert_grep 'survived.*: specs/_shipped/old/deep/handoff\.md$' "$tmpdir/survive.out"
assert_grep 'survived.*: adapters/codex/docs/verification\.md$' "$tmpdir/survive.out"
assert_grep 'survived.*: specs/_shipped/2026-09-03-generic-core$' "$tmpdir/survive.out"
assert_no_grep 'dry run' "$tmpdir/survive.out"

# ---------------------------------------------------------------------------
req "REQ-PUB-003"   # mutation: plant a token, the same run must refuse

git -C "$fx" checkout -q -b leak main
printf 'mentions SecretProject once\n' >> "$fx/core/policy.md"
gcommit "$fx" -am leak
run_pub "$tmpdir/leak.out" -- --dry-run leak
assert_rc nonzero "$tmpdir/leak.out"
assert_grep 'private tokens found' "$tmpdir/leak.out"
assert_grep 'core/policy.md' "$tmpdir/leak.out"
assert_no_grep 'dry run' "$tmpdir/leak.out"

# A CRLF list with padded tokens still catches the token (the list is cleaned,
# not taken literally).
capture "$tmpdir/leak-crlf.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/crlf" "$fx/publish.sh" --dry-run leak
assert_rc nonzero "$tmpdir/leak-crlf.out"
assert_grep 'private tokens found' "$tmpdir/leak-crlf.out"

# A UTF-8 byte-order mark on the first line is not part of the first token: a
# list saved by an editor that writes one must still catch that token.
printf '\xEF\xBB\xBFsecretproject\nanother-token\n' > "$tmpdir/bom"
capture "$tmpdir/leak-bom.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/bom" "$fx/publish.sh" --dry-run leak
assert_rc nonzero "$tmpdir/leak-bom.out"
assert_grep 'private tokens found' "$tmpdir/leak-bom.out"
assert_grep 'core/policy.md' "$tmpdir/leak-bom.out"

# An inline comment would make the whole line the token, which then matches
# nothing: a malformed list is refused, never swept with a dead token.
printf 'secretproject  # the old name\n' > "$tmpdir/inline"
capture "$tmpdir/inline.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/inline" "$fx/publish.sh" --dry-run main
assert_rc nonzero "$tmpdir/inline.out"
assert_grep 'inline comment' "$tmpdir/inline.out"
assert_no_grep 'dry run' "$tmpdir/inline.out"
printf 'secretproject\t# tabbed\n' > "$tmpdir/inline-tab"
capture "$tmpdir/inline-tab.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/inline-tab" "$fx/publish.sh" --dry-run main
assert_rc nonzero "$tmpdir/inline-tab.out"
assert_grep 'inline comment' "$tmpdir/inline-tab.out"

# A token full of regex metacharacters is a literal string, not a bad regex
# that makes the sweep exit 2 and read as clean.
printf 'secretproject\nfoo(\n' > "$tmpdir/meta"
capture "$tmpdir/meta-clean.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/meta" "$fx/publish.sh" --dry-run main
assert_rc 0 "$tmpdir/meta-clean.out"
git -C "$fx" checkout -q -b meta main
printf 'calls foo( here\n' >> "$fx/core/policy.md"
gcommit "$fx" -am meta
capture "$tmpdir/meta-leak.out" env SDLC_SCRUB_TOKENS_FILE="$tmpdir/meta" "$fx/publish.sh" --dry-run meta
assert_rc nonzero "$tmpdir/meta-leak.out"
assert_grep 'private tokens found' "$tmpdir/meta-leak.out"

# A sweep that cannot run is a refusal, never a pass: a grep that exits 2 on
# every recursive sweep.
mkdir -p "$tmpdir/shim"
cat > "$tmpdir/shim/grep" <<SHIM
#!/bin/sh
for a in "\$@"; do [ "\$a" = "-r" ] && exit 2; done
exec $real_grep "\$@"
SHIM
chmod +x "$tmpdir/shim/grep"
run_pub "$tmpdir/broken-grep.out" PATH="$tmpdir/shim:$PATH" -- --dry-run main
assert_rc nonzero "$tmpdir/broken-grep.out"
assert_grep 'sweep could not run' "$tmpdir/broken-grep.out"
assert_no_grep 'is clean' "$tmpdir/broken-grep.out"

# A home-directory path is refused even without a token for it, on macOS and
# Linux. The prefixes are assembled at run time: this test file is itself
# published, and a literal home-directory prefix in it would trip the sweep.
home_mac='/Us'; home_mac="${home_mac}ers"
home_linux='/ho'; home_linux="${home_linux}me"
for prefix in "$home_mac" "$home_linux"; do
  git -C "$fx" checkout -q -B paths main
  printf 'see %s/someone/ws/thing\n' "$prefix" > "$fx/core/policy.md"
  gcommit "$fx" -am paths
  run_pub "$tmpdir/paths.out" -- --dry-run paths
  assert_rc nonzero "$tmpdir/paths.out"
  assert_grep 'home-directory paths found' "$tmpdir/paths.out"
done

# A binary file (a NUL byte) is a finding: the text sweep cannot read it.
git -C "$fx" checkout -q -b binary main
printf 'abc\000def secretproject\n' > "$fx/core/blob.bin"
git -C "$fx" add core/blob.bin
gcommit "$fx" -m binary
run_pub "$tmpdir/binary.out" -- --dry-run binary
assert_rc nonzero "$tmpdir/binary.out"
assert_grep 'binary file.*core/blob.bin' "$tmpdir/binary.out"

# File and directory NAMES are swept, not only contents.
git -C "$fx" checkout -q -b names main
printf 'clean\n' > "$fx/core/secretproject-notes.md"
git -C "$fx" add core/secretproject-notes.md
gcommit "$fx" -m names
run_pub "$tmpdir/names.out" -- --dry-run names
assert_rc nonzero "$tmpdir/names.out"
assert_grep 'private tokens found in names' "$tmpdir/names.out"
assert_grep 'core/secretproject-notes.md' "$tmpdir/names.out"

git -C "$fx" checkout -q -b dirnames main
mkdir -p "$fx/SecretProject"
printf 'clean\n' > "$fx/SecretProject/readme.md"
git -C "$fx" add SecretProject
gcommit "$fx" -m dirnames
run_pub "$tmpdir/dirnames.out" -- --dry-run dirnames
assert_rc nonzero "$tmpdir/dirnames.out"
assert_grep 'private tokens found in names' "$tmpdir/dirnames.out"

# Symlinks: the target string is swept, and a target outside the export is
# refused (relative escape and absolute alike).
git -C "$fx" checkout -q -b linktoken main
ln -s secretproject.md "$fx/core/dangling"
git -C "$fx" add core/dangling
gcommit "$fx" -m linktoken
run_pub "$tmpdir/linktoken.out" -- --dry-run linktoken
assert_rc nonzero "$tmpdir/linktoken.out"
assert_grep 'private tokens found in a symlink target' "$tmpdir/linktoken.out"
assert_grep 'core/dangling -> secretproject\.md' "$tmpdir/linktoken.out"

git -C "$fx" checkout -q -b linkout main
ln -s ../../outside "$fx/core/escape"
git -C "$fx" add core/escape
gcommit "$fx" -m linkout
run_pub "$tmpdir/linkout.out" -- --dry-run linkout
assert_rc nonzero "$tmpdir/linkout.out"
assert_grep 'outside the export.*core/escape' "$tmpdir/linkout.out"

git -C "$fx" checkout -q -b linkabs main
ln -s /etc/hosts "$fx/core/abs"
git -C "$fx" add core/abs
gcommit "$fx" -m linkabs
run_pub "$tmpdir/linkabs.out" -- --dry-run linkabs
assert_rc nonzero "$tmpdir/linkabs.out"
assert_grep 'outside the export.*core/abs' "$tmpdir/linkabs.out"
git -C "$fx" checkout -q main

# ---------------------------------------------------------------------------
req "REQ-PUB-004"   # arguments: every one parsed, nothing guessed

run_pub "$tmpdir/badref.out" -- --dry-run no-such-ref
assert_rc nonzero "$tmpdir/badref.out"
assert_grep 'unknown ref' "$tmpdir/badref.out"

run_pub "$tmpdir/badflag.out" -- --dry-rn main
assert_rc nonzero "$tmpdir/badflag.out"
assert_grep 'usage' "$tmpdir/badflag.out"

run_pub "$tmpdir/tworefs.out" -- --dry-run main leak
assert_rc nonzero "$tmpdir/tworefs.out"
assert_grep 'usage' "$tmpdir/tworefs.out"

run_pub "$tmpdir/guardmix.out" -- --install-guard --dry-run
assert_rc nonzero "$tmpdir/guardmix.out"
assert_grep 'usage' "$tmpdir/guardmix.out"

# --dry-run after the ref is still a dry run: nothing reaches the public side.
git init -q --bare -b main "$tmpdir/public.git"
run_pub "$tmpdir/lateflag.out" SDLC_PUBLIC_REPO="file://$tmpdir/public.git" -- main --dry-run
assert_rc 0 "$tmpdir/lateflag.out"
assert_grep 'dry run' "$tmpdir/lateflag.out"
if git --git-dir="$tmpdir/public.git" rev-parse -q --verify refs/heads/main >/dev/null; then
  _test_fail "main --dry-run pushed to the public repository"
else
  _test_pass "main --dry-run pushed nothing"
fi

# ---------------------------------------------------------------------------
req "REQ-PUB-005"   # the pre-push guard: one normaliser, every spelling

git -C "$fx" remote add origin "https://github.com/wlottermonster/ainative_sdlc.git"
capture "$tmpdir/guard.out" "$fx/publish.sh" --install-guard
assert_rc 0 "$tmpdir/guard.out"
assert_grep 'pre-push guard installed' "$tmpdir/guard.out"
assert_grep 'self-test passed' "$tmpdir/guard.out"
guard="$fx/.git/hooks/pre-push"
assert_file "$guard"
[ -x "$guard" ] || _test_fail "guard is not executable"
assert_fgrep '# sdlc-public-guard' "$guard"

public_slug="wlottermonster/ai_native_sdlc"
while IFS= read -r url; do
  [ -n "$url" ] || continue
  rc=0
  "$guard" origin "$url" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then _test_pass "guard blocks $url"; else _test_fail "guard ALLOWED public $url"; fi
  key=$("$fx/publish.sh" --normalise-url "$url")
  if [ "$key" = "$public_slug" ]; then _test_pass "normalises: $url"; else _test_fail "normalised $url to [$key]"; fi
done <<'URLS'
https://github.com/wlottermonster/ai_native_sdlc.git
https://github.com/wlottermonster/ai_native_sdlc
HTTPS://GitHub.com/WLotterMonster/AI_Native_SDLC.GIT
git@github.com:wlottermonster/ai_native_sdlc.git
ssh://git@github.com:22/wlottermonster/ai_native_sdlc.git
ssh://git@ssh.github.com:443/wlottermonster/ai_native_sdlc.git
git@github-alias:wlottermonster/ai_native_sdlc.git
https://github.com//wlottermonster/ai_native_sdlc
https://user:tok3n@github.com/wlottermonster/ai_native_sdlc.git/
git://github.com/wlottermonster/ai_native_sdlc.git
git+ssh://git@github.com/wlottermonster/ai_native_sdlc.git
/srv/mirror/wlottermonster/ai_native_sdlc.git
/srv/mirror/wlottermonster/ai_native_sdlc
file:///srv/mirror/wlottermonster/ai_native_sdlc.git
https://github.com/wlottermonster/./ai_native_sdlc
https://github.com/wlottermonster/ai_native_sdlc.git/.
https://github.com/./wlottermonster/./ai_native_sdlc/.
  https://github.com/wlottermonster/ai_native_sdlc.git
URLS

while IFS= read -r url; do
  [ -n "$url" ] || continue
  rc=0
  "$guard" origin "$url" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then _test_pass "guard allows $url"; else _test_fail "guard BLOCKED $url"; fi
  key=$("$fx/publish.sh" --normalise-url "$url")
  if [ "$key" != "$public_slug" ]; then _test_pass "not public: $url -> $key"; else _test_fail "$url normalised to the public slug"; fi
done <<'URLS'
https://github.com/wlottermonster/ainative_sdlc.git
git@github.com:wlottermonster/ainative_sdlc.git
ssh://git@github.com:22/wlottermonster/ainative_sdlc.git
HTTPS://GITHUB.COM/WLOTTERMONSTER/AINATIVE_SDLC
https://github.com/wlottermonster/ai_native_sdlc_old.git
/srv/mirror/wlottermonster/ainative_sdlc.git
URLS

# The private repository normalises to its own slug in every spelling.
for url in https://github.com/wlottermonster/ainative_sdlc.git \
           git@github-alias:WLotterMonster/ainative_sdlc.git/ \
           ssh://git@ssh.github.com:443/wlottermonster/ainative_sdlc; do
  key=$("$fx/publish.sh" --normalise-url "$url")
  if [ "$key" = "wlottermonster/ainative_sdlc" ]; then _test_pass "private: $url"; else _test_fail "private $url -> [$key]"; fi
done

# A guard that cannot read a URL cannot verify, so it refuses.
capture "$tmpdir/guard-empty.out" "$guard" origin ""
assert_rc nonzero "$tmpdir/guard-empty.out"

# Installing twice is a refresh, not an error.
capture "$tmpdir/guard2.out" "$fx/publish.sh" --install-guard
assert_rc 0 "$tmpdir/guard2.out"

# Mutation: an old guard that passes the self-test but is not this guard, made
# read-only so it cannot be rewritten in place. The install must replace it or
# fail; it may never report "installed" over the old content.
cp "$guard" "$tmpdir/guard.good"
cat > "$guard" <<'OLD'
#!/bin/sh
# stale guard from an earlier install
case "${2:-}" in *ai_native_sdlc*) exit 1 ;; esac
exit 0
OLD
chmod 555 "$guard"
capture "$tmpdir/guard-stale.out" "$fx/publish.sh" --install-guard
if [ "$(tr -d '[:space:]' < "$tmpdir/guard-stale.out.rc")" = "0" ]; then
  assert_fgrep '# sdlc-public-guard' "$guard"
  assert_no_grep 'stale guard' "$guard"
else
  _test_pass "install over a read-only stale guard failed loudly"
  assert_no_grep 'pre-push guard installed' "$tmpdir/guard-stale.out"
fi
chmod 755 "$guard"
cp "$tmpdir/guard.good" "$guard"

# An override is written into the hook quoted, never executed.
capture "$tmpdir/guard-inject.out" env SDLC_PUBLIC_REPO="https://x.invalid/a'\$(touch $tmpdir/pwned)'/b" "$fx/publish.sh" --install-guard
"$guard" origin "https://example.invalid/some/repo" >/dev/null 2>&1 || true
if [ -e "$tmpdir/pwned" ]; then _test_fail "override was executed by the hook"; else _test_pass "override stays data"; fi
# ...and the canonical public repository stays blocked under an override.
capture "$tmpdir/guard-override-public.out" "$guard" origin "https://github.com/wlottermonster/ai_native_sdlc.git"
assert_rc nonzero "$tmpdir/guard-override-public.out"

# Mutation for the self-test: with origin set to the public repository the
# freshly written hook refuses origin, and the install must say so and fail.
git -C "$fx" remote set-url origin "git@github.com:wlottermonster/ai_native_sdlc.git"
capture "$tmpdir/guard-selftest.out" "$fx/publish.sh" --install-guard
assert_rc nonzero "$tmpdir/guard-selftest.out"
assert_grep 'self-test' "$tmpdir/guard-selftest.out"
git -C "$fx" remote remove origin
"$fx/publish.sh" --install-guard >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
req "REQ-PUB-006"   # inherited git selectors cannot redirect the export

git init -q -b main "$tmpdir/decoy"
printf 'decoy\n' > "$tmpdir/decoy/decoy.md"
git -C "$tmpdir/decoy" add -A
gcommit "$tmpdir/decoy" -m decoy
run_pub "$tmpdir/selector.out" GIT_DIR="$tmpdir/decoy/.git" GIT_WORK_TREE="$tmpdir/decoy" -- --dry-run main
assert_rc 0 "$tmpdir/selector.out"
sel_export=$(export_of "$tmpdir/selector.out")
assert_file "$sel_export/core/policy.md"
if [ -e "$sel_export/decoy.md" ]; then _test_fail "GIT_DIR redirected the export"; else _test_pass "GIT_DIR ignored"; fi

# ---------------------------------------------------------------------------
req "REQ-PUB-009"   # an override is announced; public == origin is refused

assert_grep 'SDLC_PUBLIC_REPO override in use' "$tmpdir/lateflag.out"
assert_no_grep 'override in use' "$tmpdir/clean.out"
git -C "$fx" remote add origin "$tmpdir/public.git"
run_pub "$tmpdir/same.out" SDLC_PUBLIC_REPO="file://$tmpdir/public.git" -- --dry-run main
assert_rc nonzero "$tmpdir/same.out"
assert_grep 'is origin' "$tmpdir/same.out"
git -C "$fx" remote remove origin

# ---------------------------------------------------------------------------
req "REQ-PUB-010"   # a dry run keeps its export; a refusal removes it

if [ -d "$export_dir" ]; then _test_pass "dry-run export kept"; else _test_fail "dry-run export missing: $export_dir"; fi
removed=$(sed -n 's/^publish: removed the export at \(.*\)$/\1/p' "$tmpdir/leak.out")
printf '%s\n' "$removed" > "$tmpdir/removed"
assert_grep 'sdlc-publish' "$tmpdir/removed"
if [ -n "$removed" ] && [ ! -e "$removed" ]; then _test_pass "refused export removed"; else _test_fail "refused export left at [$removed]"; fi

# ---------------------------------------------------------------------------
req "REQ-PUB-011"   # a clone failure says why

run_pub "$tmpdir/noclone.out" SDLC_PUBLIC_REPO="$tmpdir/no-such-public.git" -- main
assert_rc nonzero "$tmpdir/noclone.out"
assert_grep 'cannot clone .*no-such-public.git.*: .+' "$tmpdir/noclone.out"

# ---------------------------------------------------------------------------
req "REQ-PUB-007"   # real run: orphan main on an empty remote, tree == export
req "REQ-PUB-008"   # commit identity is the public one, whatever the env says

pub="$tmpdir/public.git"
pubrun() {
  run_pub "$1" SDLC_PUBLIC_REPO="file://$pub" \
    GIT_AUTHOR_NAME="Personal Name" GIT_AUTHOR_EMAIL="personal@example.invalid" \
    GIT_COMMITTER_NAME="Personal Name" GIT_COMMITTER_EMAIL="personal@example.invalid" \
    EMAIL="personal@example.invalid" -- main
}
pubrun "$tmpdir/real1.out"
assert_rc 0 "$tmpdir/real1.out"
assert_grep '^publish: pushed ' "$tmpdir/real1.out"
git --git-dir="$pub" rev-list --count main > "$tmpdir/count1" 2>&1
assert_grep '^1$' "$tmpdir/count1"
git --git-dir="$pub" log -1 --format='%an <%ae>|%cn <%ce>' main > "$tmpdir/ident"
assert_grep '^wlottermonster <150488328\+wlottermonster@users\.noreply\.github\.com>\|wlottermonster <150488328\+wlottermonster@users\.noreply\.github\.com>$' "$tmpdir/ident"
assert_no_grep 'personal|Personal' "$tmpdir/ident"
git --git-dir="$pub" log -1 --format='%s' main > "$tmpdir/subject"
fx_short=$(git -C "$fx" rev-parse --short main)
assert_grep "^Publish ainative_sdlc@$fx_short\$" "$tmpdir/subject"
# The message names the private commit by its short SHA only: the full SHA
# of a private commit is not something the public history needs to carry.
git --git-dir="$pub" log -1 --format='%B' main > "$tmpdir/body"
fx_full=$(git -C "$fx" rev-parse main)
assert_no_grep "$fx_full" "$tmpdir/body"
assert_fgrep "at $fx_short:" "$tmpdir/body"

tab=$(printf '\t')
git --git-dir="$pub" ls-tree -r main > "$tmpdir/pub-tree"
git -C "$fx" ls-tree -r main \
  | grep -v -E "${tab}(docs/|specs/(.*/)?handoff\.md$|specs/workspace-interoperability/|specs/portability-step[56]/|specs/_shipped/2026-09-03-generic-core/|adapters/codex/docs/verification\.md$)" \
  > "$tmpdir/want-tree"
if cmp -s "$tmpdir/pub-tree" "$tmpdir/want-tree"; then
  _test_pass "public tree equals the export (modes, blobs, symlink, force-tracked file)"
else
  _test_fail "public tree differs from the export"
  diff "$tmpdir/want-tree" "$tmpdir/pub-tree" >&2 || true
fi

# Second run: nothing changed, nothing pushed.
pubrun "$tmpdir/real2.out"
assert_rc 0 "$tmpdir/real2.out"
assert_grep 'already matches' "$tmpdir/real2.out"
git --git-dir="$pub" rev-list --count main > "$tmpdir/count2"
assert_grep '^1$' "$tmpdir/count2"

# A change lands as a second commit on top of the first: history, no force.
first=$(git --git-dir="$pub" rev-parse main)
printf 'more\n' >> "$fx/core/policy.md"
gcommit "$fx" -am more
pubrun "$tmpdir/real3.out"
assert_rc 0 "$tmpdir/real3.out"
git --git-dir="$pub" rev-list --count main > "$tmpdir/count3"
assert_grep '^2$' "$tmpdir/count3"
git --git-dir="$pub" rev-parse main^ > "$tmpdir/parent"
assert_grep "^$first\$" "$tmpdir/parent"

# A remote with branches but no main: refuse, never guess a base.
git init -q --bare -b develop "$tmpdir/nomain.git"
git -C "$tmpdir/decoy" push -q "$tmpdir/nomain.git" main:develop
run_pub "$tmpdir/nomain.out" SDLC_PUBLIC_REPO="file://$tmpdir/nomain.git" -- main
assert_rc nonzero "$tmpdir/nomain.out"
assert_grep 'no main branch' "$tmpdir/nomain.out"
git --git-dir="$tmpdir/nomain.git" for-each-ref --format='%(refname)' > "$tmpdir/nomain-refs"
assert_no_grep 'refs/heads/main' "$tmpdir/nomain-refs"

# ---------------------------------------------------------------------------
req "REQ-GCORE-001"   # tests/test_scrub.sh: a token sweep that cannot run fails

cat > "$tmpdir/shim/grep" <<SHIM
#!/bin/sh
for a in "\$@"; do [ "\$a" = "-H" ] && exit 2; done
exec $real_grep "\$@"
SHIM
chmod +x "$tmpdir/shim/grep"
capture "$tmpdir/scrub-broken.out" env PATH="$tmpdir/shim:$PATH" bash "$repo/tests/test_scrub.sh"
assert_rc nonzero "$tmpdir/scrub-broken.out"
assert_grep 'sweep could not run' "$tmpdir/scrub-broken.out"

# ---------------------------------------------------------------------------
req "REQ-PUB-010"   # the exports the dry runs above kept all sit under $tmpdir

# Housekeeping, proved rather than assumed: the dry runs above did leave
# exports (so the redirect at the top took effect), and every one of them sits
# under $tmpdir, which the trap removes. The machine's temp folder gained no
# sdlc-publish.* directory since this file started.
find "$tmpdir/exports" -maxdepth 1 -name 'sdlc-publish.*' | wc -l | tr -d ' ' > "$tmpdir/exports-kept"
assert_no_grep '^0$' "$tmpdir/exports-kept"
find "$system_tmp" -maxdepth 1 -name 'sdlc-publish.*' -newer "$tmpdir/started" | wc -l | tr -d ' ' > "$tmpdir/exports-strayed"
assert_grep '^0$' "$tmpdir/exports-strayed"

finish
