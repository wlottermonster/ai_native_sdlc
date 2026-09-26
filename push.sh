#!/bin/bash
# AI-Native SDLC — the maintainer's single "push": push the current branch to
# origin (the PRIVATE repository), then, from main only, publish a clean export
# of the same commit to the PUBLIC repository through publish.sh.
#
#   ./push.sh               private push; from main, also the public export
#   ./push.sh --no-publish  private push only, even on main
#
# It refuses, before pushing anything, when origin is not the private
# repository (this is the maintainer's tool, not a contributor's), when any
# remote is the public repository, on a detached HEAD, and with uncommitted
# changes to tracked files. It never forces and never skips hooks; the
# pre-push guard from `publish.sh --install-guard` is reinstalled and
# self-tested before every push. A public refusal after the private push is
# reported as exactly that, with a non-zero exit.
#
# URL comparison goes through `publish.sh --normalise-url`: one normaliser,
# the same text the pre-push guard runs.
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

here=$(cd "$(dirname "$0")" && pwd)
publish="$here/publish.sh"

PRIVATE_SLUG="wlottermonster/ainative_sdlc"
PUBLIC_SLUG="wlottermonster/ai_native_sdlc"
public_repo="${SDLC_PUBLIC_REPO:-https://github.com/wlottermonster/ai_native_sdlc.git}"

fail() { printf 'push: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'usage: push.sh [--no-publish]\n' >&2
  [ -n "${1:-}" ] && printf 'push: %s\n' "$1" >&2
  exit 2
}

no_publish=0
for arg in "$@"; do
  case "$arg" in
    --no-publish) no_publish=1 ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $arg" ;;
  esac
done

[ -x "$publish" ] || fail "publish.sh is missing or not executable at $publish"
key() {
  local k
  k=$("$publish" --normalise-url "$1") || fail "cannot normalise URL: $1"
  [ -n "$k" ] || fail "cannot normalise URL: $1"
  printf '%s' "$k"
}

# --- whose checkout is this --------------------------------------------------
origin_url=$(git -C "$here" remote get-url origin 2>/dev/null) \
  || fail "no origin remote — push.sh is the maintainer's tool: fork, branch and open a pull request instead"
[ "$(key "$origin_url")" = "$PRIVATE_SLUG" ] \
  || fail "origin is $origin_url — push.sh is the maintainer's tool: fork, branch and open a pull request instead"

public_key=$(key "$public_repo")
while IFS= read -r remote; do
  [ -n "$remote" ] || continue
  urls=$( { git -C "$here" remote get-url --all "$remote"; git -C "$here" remote get-url --push --all "$remote"; } ) \
    || fail "cannot read the URLs of remote '$remote'"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    k=$(key "$url")
    if [ "$k" = "$PUBLIC_SLUG" ] || [ "$k" = "$public_key" ]; then
      fail "remote '$remote' ($url) is the PUBLIC repository — it must never be a remote of this checkout. Remove it yourself (git remote remove $remote); push.sh will not."
    fi
  done <<< "$urls"
done < <(git -C "$here" remote)

branch=$(git -C "$here" symbolic-ref -q --short HEAD) \
  || fail "detached HEAD — check out a branch first"
dirty=$(git -C "$here" status --porcelain --untracked-files=no) \
  || fail "cannot read the working tree status"
[ -z "$dirty" ] || fail "uncommitted changes to tracked files — commit first:
$dirty"
short=$(git -C "$here" rev-parse --short HEAD)

# --- the guard, before any push ----------------------------------------------
# Reinstalled on EVERY push (REQ-GATE-018), never only when its marker is
# missing: a stale guard still carries the marker, so a presence check would
# keep an old guard — or any file that merely contains the line — forever.
# --install-guard writes beside the hook, moves it over, and self-tests the
# result, so running it each time is idempotent and proves the guard refuses.
"$publish" --install-guard || fail "could not install the pre-push guard — nothing pushed"

# --- private push ------------------------------------------------------------
git -C "$here" push origin "HEAD:refs/heads/$branch" \
  || fail "private push of $branch failed — nothing published"
printf 'pushed %s (%s) to origin (private)\n' "$branch" "$short"

# --- public export -----------------------------------------------------------
if [ "$branch" != "main" ]; then
  printf 'NOT PUBLISHED: public export only happens from main (current branch: %s)\n' "$branch"
  printf 'private: pushed; public: not published (branch %s)\n' "$branch"
  exit 0
fi
if [ "$no_publish" -eq 1 ]; then
  printf 'NOT PUBLISHED: --no-publish given\n'
  printf 'private: pushed; public: not published (--no-publish)\n'
  exit 0
fi

errf=$(mktemp "${TMPDIR:-/tmp}/sdlc-push.XXXXXX")
# shellcheck disable=SC2329  # invoked by the trap
cleanup() { rm -f "$errf"; }
trap cleanup EXIT

refused() {
  local reason
  reason=$(grep -m 1 '^publish: ' "$errf" | sed 's/^publish: //' || true)
  cat "$errf" >&2
  printf 'private: pushed; public: REFUSED — %s\n' "${reason:-publish.sh failed}" >&2
  exit 1
}

if ! dry=$("$publish" --dry-run HEAD 2> "$errf"); then refused; fi
# The dry run keeps its export for reading; push.sh has read the verdict, so
# it removes the export rather than leave one in TMPDIR per push.
left=$(printf '%s\n' "$dry" | sed -n 's/^publish: dry run — export left at \(.*\)\/export, nothing pushed$/\1/p')
case "$left" in
  */sdlc-publish.*) rm -rf "$left" ;;
esac
printf '%s\n' "$dry" | grep -v '^publish: dry run — export left at ' || true
printf 'publish: dry run passed — publishing\n'

if ! out=$("$publish" HEAD 2> "$errf"); then refused; fi
printf '%s\n' "$out"
cat "$errf" >&2
# The summary names the commit publish.sh says it exported, read from its own
# output, never the HEAD this script saw earlier: HEAD can move in between.
exported=$(printf '%s\n' "$out" | sed -n 's/^publish: pushed \([0-9a-f][0-9a-f]*\) to .*$/\1/p' | tail -n 1)
unchanged=$(printf '%s\n' "$out" | sed -n 's/^publish: public repository already matches \([0-9a-f][0-9a-f]*\) — nothing to push$/\1/p' | tail -n 1)
if [ -n "$exported" ]; then
  printf 'published %s to %s\n' "$exported" "$public_repo"
  printf 'private: pushed; public: published\n'
elif [ -n "$unchanged" ]; then
  printf 'public repository already matches %s — nothing new published\n' "$unchanged"
  printf 'private: pushed; public: already up to date\n'
else
  printf 'push: publish.sh succeeded but did not name the commit it exported\n' >&2
  printf 'private: pushed; public: published (exported commit unknown)\n'
fi
