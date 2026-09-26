#!/bin/bash
# AI-Native SDLC — push.sh is the maintainer's single "push": the private push
# to origin, then (from main only) the public export through publish.sh. It
# refuses outside the maintainer's checkout, on a public remote, a detached
# HEAD or uncommitted changes; and a public refusal after a private push is
# reported as exactly that, with a non-zero exit.
#
# Every remote here is a local bare repository: origin's path ends in the
# private repository's owner/name, the public one is reached through
# SDLC_PUBLIC_REPO. Nothing leaves the machine.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-push-test.XXXXXX")
tmpdir=$(cd "$tmpdir" && pwd -P)
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

gcommit() {
  local d="$1"
  shift
  git -C "$d" -c user.name=t -c user.email=sdlc-test@example.invalid \
      -c commit.gpgsign=false commit -q "$@"
}

private_remote="$tmpdir/remotes/wlottermonster/ainative_sdlc.git"
public_remote="$tmpdir/pub/wlottermonster/ai_native_sdlc.git"
mkdir -p "$(dirname "$private_remote")" "$(dirname "$public_remote")"
git init -q --bare -b main "$private_remote"
git init -q --bare -b main "$public_remote"

tokens="$tmpdir/tokens"
printf '# fixture list\nsecretproject\n' > "$tokens"

fx="$tmpdir/fixture"
git init -q -b main "$fx"
mkdir -p "$fx/core" "$fx/docs" "$fx/specs/feat"
printf 'framework file\n' > "$fx/core/policy.md"
printf 'private workspace log\n' > "$fx/docs/log.md"
printf 'ledger\n' > "$fx/specs/feat/handoff.md"
printf 'requirements\n' > "$fx/specs/feat/requirements.md"
cp "$repo/publish.sh" "$repo/push.sh" "$fx/"
git -C "$fx" add -A
gcommit "$fx" -m clean
git -C "$fx" remote add origin "file://$private_remote"

push() {
  local out="$1"
  shift
  capture "$out" env SDLC_SCRUB_TOKENS_FILE="$tokens" SDLC_PUBLIC_REPO="file://$public_remote" \
    "$fx/push.sh" "$@"
}

has_ref() { git --git-dir="$1" rev-parse -q --verify "$2" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
req "REQ-PUSH-001"   # only the maintainer's checkout, never a public remote

git -C "$fx" remote set-url origin "file://$public_remote"
push "$tmpdir/public-origin.out"
assert_rc nonzero "$tmpdir/public-origin.out"
assert_grep "push.sh is the maintainer's tool: fork, branch and open a pull request instead" "$tmpdir/public-origin.out"

git -C "$fx" remote set-url origin "https://github.com/someone/fork.git"
push "$tmpdir/fork-origin.out"
assert_rc nonzero "$tmpdir/fork-origin.out"
assert_grep "maintainer's tool" "$tmpdir/fork-origin.out"
git -C "$fx" remote set-url origin "file://$private_remote"

# Any remote that normalises to the public repository is refused by name, in
# any spelling, and is never removed.
git -C "$fx" remote add mirror "ssh://git@ssh.github.com:443/WLotterMonster/AI_Native_SDLC"
push "$tmpdir/mirror.out"
assert_rc nonzero "$tmpdir/mirror.out"
assert_grep "remote 'mirror'.*PUBLIC" "$tmpdir/mirror.out"
git -C "$fx" remote > "$tmpdir/remote-names"
assert_grep '^mirror$' "$tmpdir/remote-names"
git -C "$fx" remote remove mirror
if has_ref "$private_remote" refs/heads/main; then _test_fail "a refused push.sh pushed"; else _test_pass "refusals pushed nothing"; fi

# ---------------------------------------------------------------------------
req "REQ-PUSH-002"   # detached HEAD and uncommitted changes are refused

git -C "$fx" checkout -q --detach
push "$tmpdir/detached.out"
assert_rc nonzero "$tmpdir/detached.out"
assert_grep 'detached HEAD' "$tmpdir/detached.out"
git -C "$fx" checkout -q main

printf 'edit\n' >> "$fx/core/policy.md"
push "$tmpdir/dirty.out"
assert_rc nonzero "$tmpdir/dirty.out"
assert_grep 'commit first' "$tmpdir/dirty.out"
git -C "$fx" checkout -q -- core/policy.md

push "$tmpdir/badflag.out" --force
assert_rc nonzero "$tmpdir/badflag.out"
assert_grep 'usage' "$tmpdir/badflag.out"

# An untracked file is not an uncommitted change to a tracked file.
printf 'scratch\n' > "$fx/untracked.txt"

# ---------------------------------------------------------------------------
req "REQ-PUSH-003"   # a non-main branch: private push only, said in capitals

git -C "$fx" checkout -q -b feature
printf 'feature work\n' >> "$fx/core/policy.md"
gcommit "$fx" -am feature
push "$tmpdir/feature.out"
assert_rc 0 "$tmpdir/feature.out"
assert_grep '^pushed feature \([0-9a-f]+\) to origin \(private\)$' "$tmpdir/feature.out"
assert_fgrep 'NOT PUBLISHED: public export only happens from main (current branch: feature)' "$tmpdir/feature.out"
if has_ref "$private_remote" refs/heads/feature; then _test_pass "feature reached origin"; else _test_fail "feature not on origin"; fi
if has_ref "$public_remote" refs/heads/main; then _test_fail "a feature branch was published"; else _test_pass "nothing published from feature"; fi
# The guard was installed on the way.
assert_fgrep '# sdlc-public-guard' "$fx/.git/hooks/pre-push"
git -C "$fx" checkout -q main

# A pre-push hook without the marker is not the guard: it is replaced.
printf '#!/bin/sh\nexit 0\n' > "$fx/.git/hooks/pre-push"

# ---------------------------------------------------------------------------
req "REQ-PUSH-004"   # --no-publish on main: private push, publishing skipped

push "$tmpdir/nopub.out" --no-publish
assert_rc 0 "$tmpdir/nopub.out"
assert_grep '^pushed main ' "$tmpdir/nopub.out"
assert_grep 'NOT PUBLISHED: --no-publish' "$tmpdir/nopub.out"
if has_ref "$public_remote" refs/heads/main; then _test_fail "--no-publish published"; else _test_pass "--no-publish published nothing"; fi
assert_fgrep '# sdlc-public-guard' "$fx/.git/hooks/pre-push"

# ---------------------------------------------------------------------------
req "REQ-GATE-018"   # a stale guard that still carries the marker is refreshed

# The marker line is present, so a check for the marker alone would keep this
# file — a guard that allows everything. push.sh must rewrite it every time.
printf '#!/bin/sh\n# sdlc-public-guard — stale copy\n# stale-guard-sentinel\nexit 0\n' > "$fx/.git/hooks/pre-push"
push "$tmpdir/stale.out" --no-publish
assert_rc 0 "$tmpdir/stale.out"
assert_no_grep 'stale-guard-sentinel' "$fx/.git/hooks/pre-push"
assert_fgrep '# sdlc-public-guard' "$fx/.git/hooks/pre-push"
assert_grep '^public_key=' "$fx/.git/hooks/pre-push"
assert_fgrep 'self-test passed' "$tmpdir/stale.out"

# ---------------------------------------------------------------------------
req "REQ-PUSH-005"   # main: private push, then the public export lands

printf 'second\n' >> "$fx/core/policy.md"
gcommit "$fx" -am second
short=$(git -C "$fx" rev-parse --short HEAD)
push "$tmpdir/main.out"
assert_rc 0 "$tmpdir/main.out"
assert_grep "^pushed main \\($short\\) to origin \\(private\\)\$" "$tmpdir/main.out"
assert_fgrep "published $short to file://$public_remote" "$tmpdir/main.out"
assert_fgrep 'private: pushed; public: published' "$tmpdir/main.out"
git --git-dir="$private_remote" rev-parse main > "$tmpdir/origin-main"
assert_grep "^$(git -C "$fx" rev-parse HEAD)\$" "$tmpdir/origin-main"
tab=$(printf '\t')
git --git-dir="$public_remote" ls-tree -r main > "$tmpdir/pub-tree"
git -C "$fx" ls-tree -r main \
  | grep -v -E "${tab}(docs/|specs/(.*/)?handoff\.md$)" > "$tmpdir/want-tree"
if cmp -s "$tmpdir/pub-tree" "$tmpdir/want-tree"; then
  _test_pass "public tree equals the export"
else
  _test_fail "public tree differs from the export"
  diff "$tmpdir/want-tree" "$tmpdir/pub-tree" >&2 || true
fi
# The dry run's export is not left behind in TMPDIR.
assert_no_grep 'export left at' "$tmpdir/main.out"

# ---------------------------------------------------------------------------
req "REQ-PUSH-006"   # a planted token: private pushed, public refused, non-zero

pub_before=$(git --git-dir="$public_remote" rev-parse main)
printf 'mentions SecretProject once\n' >> "$fx/core/policy.md"
gcommit "$fx" -am leak
push "$tmpdir/leak.out"
assert_rc nonzero "$tmpdir/leak.out"
assert_grep '^pushed main ' "$tmpdir/leak.out"
assert_grep 'private: pushed; public: REFUSED — .*private tokens found' "$tmpdir/leak.out"
git --git-dir="$private_remote" rev-parse main > "$tmpdir/origin-leak"
assert_grep "^$(git -C "$fx" rev-parse HEAD)\$" "$tmpdir/origin-leak"
git --git-dir="$public_remote" rev-parse main > "$tmpdir/pub-after"
assert_grep "^$pub_before\$" "$tmpdir/pub-after"

finish
