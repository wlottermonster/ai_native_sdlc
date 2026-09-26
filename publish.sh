#!/bin/bash
# AI-Native SDLC — publish a clean export of one ref to the PUBLIC repository.
#
# Two repositories, two jobs. `origin` is the private working repository: full
# history, docs/, every ordinary `git push`. The public repository never
# becomes a remote of this checkout and never receives history: it gets the
# FILES of one commit, exported with `git archive`, minus the private working
# notes, committed on top of the public repository's own linear `main` and
# pushed without force.
#
# The export is refused, before anything leaves this machine, when
#   - the machine-local scrub token list is missing, empty, holds an inline
#     comment (`token  # note`), or holds a token shorter than 3 characters
#     (an unswept export is not a publish);
#   - any sweep could not run (a sweep that errors is not a clean sweep);
#   - any exported file is binary (the text sweep cannot read it);
#   - any file content, file or directory name, or symlink target matches a
#     token or a home-directory path, or a symlink points outside the export;
#   - a private path survived the exclusion.
#
#   ./publish.sh [--dry-run] [ref]  export <ref> (default main); with --dry-run,
#                                   build and sweep it, print its path, push nothing
#   ./publish.sh --install-guard    install a pre-push hook in THIS checkout that
#                                   refuses any push whose remote URL is the public
#                                   repository, then self-test it (idempotent)
#   ./publish.sh --normalise-url U  print the owner/name key the guard compares
#
# SDLC_PUBLIC_REPO overrides the public repository URL; SDLC_SCRUB_TOKENS_FILE
# the token list (default ~/.config/ainative-sdlc/scrub-tokens);
# SDLC_PUBLIC_NAME and SDLC_PUBLIC_EMAIL the identity on the public commit.
set -euo pipefail

# Inherited selectors (from a hook, a worktree, a caller's environment) would
# redirect every `git -C` below to some other repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

here=$(cd "$(dirname "$0")" && pwd)

PUBLIC_SLUG="wlottermonster/ai_native_sdlc"
DEFAULT_PUBLIC_REPO="https://github.com/wlottermonster/ai_native_sdlc.git"
public_repo="${SDLC_PUBLIC_REPO:-$DEFAULT_PUBLIC_REPO}"

# Private working notes: kept in the private repository, never exported.
# Each entry is a git pathspec under `:(glob,exclude)` magic, so `**/` matches
# any depth (including none) and `*` never crosses a `/`. tests/test_publish.sh
# plants every one of these in a fixture and proves it is absent from the export.
PRIVATE_PATHS=(
  "docs"                                  # workspace logs and project names
  "specs/**/handoff.md"                   # session handoff ledgers, any depth
  "specs/workspace-interoperability"      # one-machine migration notes
  "specs/portability-step5"
  "specs/portability-step6"
  "adapters/codex/docs/verification.md"   # one-machine session log
  "specs/_shipped/2026-09-03-generic-core" # names the owner's earlier products; the private repository keeps the audit trail
)

# The one URL normaliser. It is written verbatim into the pre-push hook (a
# POSIX sh script) and evaluated here, and push.sh reaches it through
# --normalise-url, so all three compare keys made by the same text.
# Lowercase and trim surrounding whitespace; drop the scheme and authority
# (user[:token]@host[:port]) or the scp-style `user@host:`; collapse `//` and
# `/./` and a trailing `/.`; drop a trailing `/` and `.git`; keep
# the last two path components (owner/name), whatever the host or alias.
# shellcheck disable=SC2016  # literal shell text: expanded where it is run
NORMALISER='sdlc_url_key() {
  _k=$(printf "%s" "$1" | tr "[:upper:]" "[:lower:]" | sed -E "s/^[[:space:]]+//; s/[[:space:]]+\$//")
  case "$_k" in
    [a-z]*://*) _k=$(printf "%s" "$_k" | sed -E "s#^[a-z][a-z0-9+.-]*://[^/]*##") ;;
    *) _k=$(printf "%s" "$_k" | sed -E "s#^[^/]*:##") ;;
  esac
  printf "%s" "$_k" | sed -E "s#/+#/#g; s#/(\\./)+#/#g; s#(/\\.)+\$##; s#/\$##; s#\\.git\$##; s#/\$##; s#^.*/([^/]+/[^/]+)\$#\\1#"
}'
eval "$NORMALISER"

fail() { printf 'publish: %s\n' "$*" >&2; exit 1; }

usage() {
  printf 'usage: publish.sh [--dry-run] [ref] | --install-guard | --normalise-url <url>\n' >&2
  [ -n "${1:-}" ] && printf 'publish: %s\n' "$1" >&2
  exit 2
}

# shell-quote for a POSIX sh script: wrap in single quotes, escape embedded ones.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# --- arguments: every one parsed, none guessed -----------------------------
dry_run=0 install_guard=0 ref=""
if [ "${1:-}" = "--normalise-url" ]; then
  [ "$#" -eq 2 ] || usage "--normalise-url takes exactly one URL"
  sdlc_url_key "$2"
  printf '\n'
  exit 0
fi
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --install-guard) install_guard=1 ;;
    -h|--help) usage ;;
    -*) usage "unknown option: $arg" ;;
    *) [ -z "$ref" ] || usage "more than one ref: $ref $arg"; ref="$arg" ;;
  esac
done
if [ "$install_guard" -eq 1 ] && { [ "$dry_run" -eq 1 ] || [ -n "$ref" ]; }; then
  usage "--install-guard takes no other arguments"
fi
ref="${ref:-main}"

public_key=$(sdlc_url_key "$public_repo")
[ -n "$public_key" ] || fail "cannot normalise the public repository URL: $public_repo"
[ -z "${SDLC_PUBLIC_REPO:-}" ] || printf 'publish: SDLC_PUBLIC_REPO override in use: %s\n' "$public_repo"
origin_url=$(git -C "$here" remote get-url origin 2>/dev/null || true)

# --- --install-guard --------------------------------------------------------
# The public repository must never be a push target of this checkout, whatever
# the remote is called. The hook is a plain git pre-push hook, so it also holds
# for pushes a client issues on the owner's behalf.
if [ "$install_guard" -eq 1 ]; then
  hooks_dir=$(git -C "$here" rev-parse --git-path hooks) || fail "not a git checkout: $here"
  case "$hooks_dir" in /*) ;; *) hooks_dir="$here/$hooks_dir" ;; esac
  mkdir -p "$hooks_dir"
  guard="$hooks_dir/pre-push"
  # Written beside the guard, then moved over it: a guard that cannot be
  # rewritten in place (read-only, an old install) is replaced, never kept and
  # self-tested as if it were the new one.
  new_guard=$(mktemp "$hooks_dir/.pre-push.XXXXXX") || fail "cannot create a temporary guard in $hooks_dir"
  {
    printf '#!/bin/sh\n'
    printf '# sdlc-public-guard — installed by publish.sh --install-guard (AI-Native SDLC).\n'
    printf '# Refuses any push whose remote URL is the public repository: it receives\n'
    printf '# clean exports from publish.sh only, never history from this checkout.\n'
    printf '# Re-run --install-guard to refresh; delete this file to remove the guard.\n'
    printf 'public_slug=%s\n' "$(sq "$PUBLIC_SLUG")"
    printf 'public_key=%s\n' "$(sq "$public_key")"
    printf '%s\n' "$NORMALISER"
    cat <<'HOOK'
url="${2:-}"
key=$(sdlc_url_key "$url")
if [ -z "$key" ]; then
  printf 'pre-push: cannot read the remote URL [%s] — refusing (a guard that cannot verify never allows).\n' "$url" >&2
  exit 1
fi
if [ "$key" = "$public_slug" ] || [ "$key" = "$public_key" ]; then
  printf 'pre-push: %s is the PUBLIC repository.\n' "$url" >&2
  printf 'pre-push: never push here — run ./publish.sh, which exports and sweeps first.\n' >&2
  exit 1
fi
exit 0
HOOK
  } > "$new_guard" || { rm -f "$new_guard"; fail "cannot write the guard to $new_guard"; }
  chmod 755 "$new_guard" || { rm -f "$new_guard"; fail "cannot make $new_guard executable"; }
  mv -f "$new_guard" "$guard" || { rm -f "$new_guard"; fail "cannot install the guard at $guard"; }
  grep -q '^# sdlc-public-guard' "$guard" \
    || fail "guard at $guard is not the one just written — refusing to report it installed"
  # Self-test the hook just written: the public URL must be refused, the
  # private one allowed. A guard that has not been seen to refuse is not one.
  if "$guard" origin "$public_repo" >/dev/null 2>&1; then
    fail "guard self-test FAILED: $guard allowed the public repository $public_repo"
  fi
  if [ "$public_repo" != "$DEFAULT_PUBLIC_REPO" ] && "$guard" origin "$DEFAULT_PUBLIC_REPO" >/dev/null 2>&1; then
    fail "guard self-test FAILED: $guard allowed the public repository $DEFAULT_PUBLIC_REPO"
  fi
  allow_url="${origin_url:-https://github.com/wlottermonster/ainative_sdlc.git}"
  if ! "$guard" origin "$allow_url" >/dev/null 2>&1; then
    fail "guard self-test FAILED: $guard refused origin $allow_url — is origin the public repository?"
  fi
  printf 'publish: pre-push guard installed at %s (refuses %s); self-test passed\n' "$guard" "$public_key"
  exit 0
fi

# --- preconditions ----------------------------------------------------------
if [ -n "$origin_url" ] && [ "$(sdlc_url_key "$origin_url")" = "$public_key" ]; then
  fail "the public repository $public_repo is origin ($origin_url) — refusing: origin must be the private repository"
fi

tokens_file="${SDLC_SCRUB_TOKENS_FILE:-$HOME/.config/ainative-sdlc/scrub-tokens}"
[ -f "$tokens_file" ] && [ -r "$tokens_file" ] \
  || fail "no readable scrub token list at $tokens_file — refusing to publish unswept"

sha=$(git -C "$here" rev-parse --verify --quiet "$ref^{commit}") || fail "unknown ref: $ref"
short=$(git -C "$here" rev-parse --short "$sha")

work=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-publish.XXXXXX")
keep_work=0
# shellcheck disable=SC2329  # invoked by the trap
# A real run removes its work tree whatever happens; so does a refusal, and
# it says where the export was. Only a dry run that succeeds keeps its
# export, for reading.
cleanup() {
  local rc=$?
  [ "$keep_work" -eq 1 ] && return 0
  rm -rf "$work"
  [ "$rc" -eq 0 ] || printf 'publish: removed the export at %s\n' "$work" >&2
  return 0
}
trap cleanup EXIT

# --- the token list, cleaned -----------------------------------------------
# CR stripped, whitespace trimmed, comments and blank lines dropped. Tokens are
# FIXED strings (grep -F): a metacharacter is a literal, never a bad regex.
# A UTF-8 byte-order mark on the first line is stripped, not kept as part of
# the first token (which would then match nothing).
clean_tokens="$work/tokens"
bom=$(printf '\357\273\277')
tr -d '\r' < "$tokens_file" \
  | LC_ALL=C sed -e "1s/^$bom//" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | awk 'length($0) > 0 && substr($0, 1, 1) != "#"' > "$clean_tokens" \
  || fail "cannot read the token list $tokens_file"
# `token  # note` would make the whole line the token: refuse, never sweep
# with a token that silently matches nothing.
inline_line=$(awk '/[[:space:]]#/ { print NR; exit }' "$clean_tokens")
[ -z "$inline_line" ] \
  || fail "token #$inline_line in $tokens_file carries an inline comment — put comments on their own line; fix the list"
token_count=$(wc -l < "$clean_tokens" | tr -d '[:space:]')
printf 'publish: token list %s: %s tokens\n' "$tokens_file" "$token_count"
[ "$token_count" -gt 0 ] || fail "token list $tokens_file is empty — refusing to publish unswept"
short_line=$(awk 'length($0) < 3 { print NR; exit }' "$clean_tokens")
[ -z "$short_line" ] \
  || fail "token #$short_line in $tokens_file is shorter than 3 characters — it would match everything; fix the list"

# --- export -----------------------------------------------------------------
pathspecs=()
if [ -z "${SDLC_PUBLISH_TEST_KEEP_PRIVATE:-}" ]; then
  for p in "${PRIVATE_PATHS[@]}"; do pathspecs+=(":(glob,exclude)$p"); done
else
  # Test hook: skip the exclusion so the survivor check below is seen to
  # refuse. It can only make a publish fail, never let one through.
  printf 'publish: SDLC_PUBLISH_TEST_KEEP_PRIVATE set — exclusion skipped, expect a refusal\n' >&2
fi
export_dir="$work/export"
mkdir "$export_dir"
git -C "$here" archive --format=tar "$sha" -- . ${pathspecs[@]+"${pathspecs[@]}"} > "$work/export.tar" \
  || fail "git archive of $short failed"
tar -x -C "$export_dir" -f "$work/export.tar" || fail "cannot unpack the export of $short"
rm -f "$work/export.tar"

# Every exported path (files and symlinks), relative, sorted: the list the
# public clone must end up tracking exactly.
(cd "$export_dir" && find . \( -type f -o -type l \) -print | sed 's#^\./##' | LC_ALL=C sort) \
  > "$work/paths" || fail "cannot list the export"
(cd "$export_dir" && find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort) \
  > "$work/names" || fail "cannot list the export"

# --- survivor check, independent of the pathspec ----------------------------
: > "$work/survivors"
for p in "${PRIVATE_PATHS[@]}"; do
  case "$p" in
    *'**/'*)
      base="${p%%/\*\**}" name="${p##*/}"
      if [ -d "$export_dir/$base" ]; then
        (cd "$export_dir" && find "$base" -name "$name" -print) >> "$work/survivors" \
          || fail "survivor check could not run for $p"
      fi ;;
    *)
      if [ -e "$export_dir/$p" ] || [ -L "$export_dir/$p" ]; then
        printf '%s\n' "$p" >> "$work/survivors"
      fi ;;
  esac
done
if [ -s "$work/survivors" ]; then
  while IFS= read -r s; do printf 'publish: private path survived: %s\n' "$s" >&2; done < "$work/survivors"
  exit 1
fi

# --- binary files are a finding ---------------------------------------------
while IFS= read -r p; do
  [ -L "$export_dir/$p" ] && continue
  rc=0
  # Both sides only read the file: strip NULs from one copy, compare.
  # shellcheck disable=SC2094
  LC_ALL=C tr -d '\000' < "$export_dir/$p" | cmp -s - "$export_dir/$p" || rc=$?
  case "$rc" in
    0) ;;
    1) printf 'publish: binary file in the export (a NUL byte): %s\n' "$p" >> "$work/binaries" ;;
    *) fail "binary check could not run on $p — refusing" ;;
  esac
done < "$work/paths"
if [ -s "$work/binaries" ]; then
  cat "$work/binaries" >&2
  fail "binary files cannot be swept — nothing is published until they are removed or excluded"
fi

# --- sweeps: exit 0 = hits (refuse), 1 = clean, anything else = could not run
# sweep <label> <grep args...>
sweep() {
  local label="$1" rc=0
  shift
  grep "$@" > "$work/hits" 2> "$work/sweep.err" || rc=$?
  case "$rc" in
    0) printf 'publish: %s in the export of %s:\n' "$label" "$short" >&2
       cat "$work/hits" >&2
       exit 1 ;;
    1) ;;
    *) fail "sweep could not run ($label, grep exit $rc): $(tail -n 1 "$work/sweep.err")" ;;
  esac
}
home_re='/(Users|home)/[A-Za-z]'
sweep "private tokens found" -r -n -i -F -f "$clean_tokens" -- "$export_dir"
sweep "home-directory paths found" -r -n -E -- "$home_re" "$export_dir"
sweep "private tokens found in names" -n -i -F -f "$clean_tokens" -- "$work/names"
sweep "home-directory paths found in names" -n -E -- "$home_re" "$work/names"

# --- symlinks: target swept, and it must stay inside the export ------------
: > "$work/link-targets"
while IFS= read -r p; do
  [ -L "$export_dir/$p" ] || continue
  target=$(readlink "$export_dir/$p") || fail "cannot read symlink $p"
  printf '%s -> %s\n' "$p" "$target" >> "$work/link-targets"
  case "$target" in
    /*) fail "symlink points outside the export (absolute target): $p -> $target" ;;
  esac
  # Resolve lexically against the link's directory; a `..` that climbs above
  # the export root escapes it.
  dir=$(dirname "$p")
  [ "$dir" = "." ] && dir=""
  resolved="$dir"
  IFS=/ read -r -a parts <<< "$target"
  for part in "${parts[@]}"; do
    case "$part" in
      ""|.) ;;
      ..) [ -n "$resolved" ] || fail "symlink points outside the export: $p -> $target"
          case "$resolved" in */*) resolved="${resolved%/*}" ;; *) resolved="" ;; esac ;;
      *) resolved="${resolved:+$resolved/}$part" ;;
    esac
  done
done < "$work/paths"
sweep "private tokens found in a symlink target" -n -i -F -f "$clean_tokens" -- "$work/link-targets"
sweep "home-directory paths found in a symlink target" -n -E -- "$home_re" "$work/link-targets"

count=$(wc -l < "$work/paths" | tr -d '[:space:]')
printf 'publish: export of %s (%s) is clean — %s files, no private paths, no private tokens\n' "$ref" "$short" "$count"

if [ "$dry_run" -eq 1 ]; then
  keep_work=1
  printf 'publish: dry run — export left at %s, nothing pushed\n' "$export_dir"
  exit 0
fi

# --- the public side --------------------------------------------------------
pub="$work/public"
git clone --quiet --no-checkout "$public_repo" "$pub" 2> "$work/clone.err" \
  || fail "cannot clone $public_repo: $(tail -n 1 "$work/clone.err")"
git -C "$pub" for-each-ref --format='%(refname)' refs/remotes/origin/ > "$work/remote-refs" \
  || fail "cannot list the branches of $public_repo"
awk '$0 != "refs/remotes/origin/HEAD"' "$work/remote-refs" > "$work/remote-branches"
if git -C "$pub" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
  git -C "$pub" update-ref refs/heads/main refs/remotes/origin/main
  git -C "$pub" symbolic-ref HEAD refs/heads/main
elif [ -s "$work/remote-branches" ]; then
  fail "the public repository has branches but no main branch — refusing to guess a base: $(tr '\n' ' ' < "$work/remote-branches")"
else
  # Empty remote: the first commit is an orphan main.
  git -C "$pub" symbolic-ref HEAD refs/heads/main
fi
git -C "$pub" read-tree --empty
tar -c -C "$export_dir" . | tar -x -C "$pub"
# -f: the public repository's ignore rules must not drop a tracked file.
git -C "$pub" add -A -f
git -C "$pub" -c core.quotepath=off ls-files | LC_ALL=C sort > "$work/public-paths"
cmp -s "$work/paths" "$work/public-paths" \
  || fail "the public clone does not track exactly the exported files — refusing: $(diff "$work/paths" "$work/public-paths" | head -n 5 | tr '\n' ' ')"

if git -C "$pub" rev-parse -q --verify HEAD >/dev/null && git -C "$pub" diff --cached --quiet; then
  printf 'publish: public repository already matches %s — nothing to push\n' "$short"
  exit 0
fi

# The public commit carries the public identity, never a personal one: every
# identity variable is set explicitly, so global config, EMAIL or an inherited
# GIT_AUTHOR_* cannot leak through.
GIT_AUTHOR_NAME="${SDLC_PUBLIC_NAME:-wlottermonster}"
GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
GIT_AUTHOR_EMAIL="${SDLC_PUBLIC_EMAIL:-150488328+wlottermonster@users.noreply.github.com}"
GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_AUTHOR_NAME GIT_COMMITTER_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL
git -C "$pub" -c commit.gpgsign=false commit --quiet -m "Publish ainative_sdlc@$short

Clean export of the private working repository at $short: files only, no history, private working notes excluded, swept for private tokens."
git -C "$pub" push --quiet origin main:refs/heads/main 2> "$work/push.err" \
  || fail "push to $public_repo failed: $(tail -n 1 "$work/push.err")"
printf 'publish: pushed %s to %s\n' "$short" "$public_repo"
