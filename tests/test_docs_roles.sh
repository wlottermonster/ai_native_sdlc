#!/bin/bash
# AI-Native SDLC — the two reader-facing documents (README.md, ainative_sdlc.html) must
# describe the crew by ROLE, never by model. The binding from role to model
# lives in one file the owner owns; the docs name that file rather than baking a
# model name into prose that goes stale the day the owner edits the map.
#
# Covers REQ-ENGINE-024 (README's "Project layer" documents the engine map),
# REQ-ENGINE-025 (ainative_sdlc.html's crew section presents the four roles and names
# the map) and REQ-ENGINE-037 (neither file presents a specific model as the
# fixed engine for a phase, an agent or a tier).
#
# This file is under tests/, which the scrub fence excludes — it has to spell
# the model names out in order to search for them.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

readme="$repo/README.md"
manual="$repo/ainative_sdlc.html"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-docs-roles.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# md_section <heading> <outfile> — the body under a `## <heading>` line in
# README.md, up to the next `## ` heading (same convention as
# tests/test_readme.sh). An absent heading yields an empty body, which the
# non-empty assertion below then catches.
md_section() {
  awk -v want="## $1" '
    $0 == want { inside = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' "$readme" > "$2"
  wc -l < "$2" | tr -d '[:space:]' > "$2.count"
}

# html_section <h2-heading> <outfile> — the markup from an `<h2>` line in
# ainative_sdlc.html up to and including the `</section>` that closes it.
html_section() {
  awk -v want="$1" '
    index($0, "<h2>" want) { inside = 1 }
    inside { print }
    inside && /<\/section>/ { exit }
  ' "$manual" > "$2"
  wc -l < "$2" | tr -d '[:space:]' > "$2.count"
}

md_section "Project layer" "$tmpdir/project-layer.txt"
md_section "Layout" "$tmpdir/layout.txt"
html_section "The crew" "$tmpdir/crew.txt"

pl="$tmpdir/project-layer.txt"
crew="$tmpdir/crew.txt"

# ---------------------------------------------------------------------------
# REQ-ENGINE-024 — README's "Project layer" section documents the engine map:
# its path, its line format, that the installer creates it once and never
# overwrites it, and the re-run step after an edit.
req "REQ-ENGINE-024"

assert_file "$readme"
assert_grep '^## Project layer$' "$readme"
# A body must exist; an empty section cannot pass by listing nothing.
assert_grep '^[1-9][0-9]*$' "$tmpdir/project-layer.txt.count"

# The path of the map, exactly as the owner types it.
# shellcheck disable=SC2088  # a literal search string, not a path to expand
assert_fgrep '~/.claude/sdlc-engines.conf' "$pl"

# The line format, with role and model as placeholders (never a real model).
assert_fgrep '<role> = <model>' "$pl"

# The four roles the map binds, plus the deliberate escalation lever. The
# backticks are Markdown code spans in README.md, not command substitution.
# shellcheck disable=SC2016
assert_grep '`judge`' "$pl"
# shellcheck disable=SC2016
assert_grep '`build`' "$pl"
# shellcheck disable=SC2016
assert_grep '`verify`' "$pl"
# shellcheck disable=SC2016
assert_grep '`read`' "$pl"
# shellcheck disable=SC2016
assert_grep '`escalate`' "$pl"

# Created once by the installer, and never overwritten, so the owner's choice
# survives every re-install.
assert_fgrep 'never overwrites' "$pl"
assert_grep 'install\.sh' "$pl"

# ...and the step that makes an edit take effect.
assert_fgrep 'scripts/apply-engines.sh' "$pl"

# ---------------------------------------------------------------------------
# REQ-ENGINE-025 — ainative_sdlc.html's crew section presents the four roles rather than
# fixed model names, and names the engine map as what binds a role to a model.
req "REQ-ENGINE-025"

assert_file "$manual"
assert_grep '<h2>The crew</h2>' "$manual"
assert_grep '^[1-9][0-9]*$' "$tmpdir/crew.txt.count"

assert_fgrep 'JUDGE' "$crew"
assert_fgrep 'BUILD' "$crew"
assert_fgrep 'VERIFY' "$crew"
assert_fgrep 'READ' "$crew"

# The map is named inside the crew section as the binding from role to model.
assert_fgrep 'sdlc-engines.conf' "$crew"

# Positive control: the crew section is still a table of workers, not gutted.
assert_grep '<td>' "$crew"
assert_fgrep 'HOOKS' "$crew"

# ---------------------------------------------------------------------------
# REQ-ENGINE-037 — neither file presents a specific model as the fixed engine
# for a phase, an agent or a tier.
#
# Implemented as an absence assertion over the model names as whole words,
# case-insensitively. The pattern spells each case variant out rather than using
# `grep -i`, because lib.sh's assert_no_grep runs a plain `grep -qE`; the
# `(^|[^A-Za-z])` / `([^A-Za-z]|$)` guards are a portable word boundary, so
# "corpus" and "opuses" are not matches.
#
# ALLOWLIST: none. Both documents describe the crew, the file map and the phase
# narration entirely in roles, and every reference to the engine map uses the
# `<role> = <model>` placeholder form rather than a real model name — so there
# is no legitimate occurrence left to exclude, and the pattern is unanchored.
# Should a future edit want a worked example of the map's contents, the example
# lines must be anchored out of this pattern here and the reason recorded above.
req "REQ-ENGINE-037"

MODELS='(^|[^A-Za-z])([Ff][Aa][Bb][Ll][Ee]|[Oo][Pp][Uu][Ss]|[Hh][Aa][Ii][Kk][Uu]|[Ss][Oo][Nn][Nn][Ee][Tt])([^A-Za-z]|$)'

for f in "$readme" "$manual"; do
  if grep -nE -- "$MODELS" "$f" >/dev/null 2>&1; then
    printf 'REQ-ENGINE-037: model names used as fixed engines in %s:\n' "$f" >&2
    grep -nE -- "$MODELS" "$f" >&2
  fi
  assert_no_grep "$MODELS" "$f"
done

# Positive control: the absence above must not be reached by deleting the crew.
# Both files still describe the same work — in roles.
assert_grep 'implementer\.md +build' "$tmpdir/layout.txt"
assert_grep 'researcher\.md +read' "$tmpdir/layout.txt"
assert_fgrep '>JUDGE<' "$manual"
assert_fgrep '>READ<' "$manual"
assert_fgrep 'sdlc-engines.conf' "$readme"
assert_fgrep 'sdlc-engines.conf' "$manual"

# The scrub fence applies to both files as well: no literal four-digit year, no
# project or owner names introduced by this change.
assert_no_grep '20[0-9][0-9]' "$readme"
assert_no_grep '20[0-9][0-9]' "$manual"


# ---------------------------------------------------------------------------
# Training-page readability (no REQ-ID: a caller-scoped rewrite of the manual
# for a public, non-technical audience). The page must open by saying what the
# framework is, speak plainly, carry no maintainer-internal lines, and keep
# its two languages in step.
req "training-page (no REQ-ID)"

# A "What is this?" band before section 01, with SDLC spelled out once.
assert_fgrep 'data-i18n="intro.title">What is this?' "$manual"
assert_order "$manual" 'data-i18n="intro\.title"' '<section id="path">'
assert_fgrep 'Software Development Life Cycle' "$manual"
assert_fgrep 'Claude Code or Codex' "$manual"

# Plain-language rewrites: the jargon is gone, the plain words are present.
assert_no_grep 'Hooks depend on client trust' "$manual"
assert_no_grep 'cannot verify must refuse' "$manual"
assert_no_grep 'requested default, not proof' "$manual"
assert_no_grep 'future dispatches' "$manual"
assert_no_grep 'Fresh bounded checks' "$manual"
assert_no_grep 'saved receipts' "$manual"
assert_no_grep 'runs tests you already have' "$manual"
assert_fgrep 'The automatic checks only run once you have approved them in the AI tool and set up the project.' "$manual"
assert_fgrep 'If a check cannot run, it says no instead of quietly saying yes.' "$manual"
assert_fgrep 'a fresh time-limited run of the checks' "$manual"
assert_fgrep 'the saved results of earlier runs' "$manual"
assert_fgrep 'is the fast lane: syntax and lint;' "$manual"

# Maintainer-internal and owner-specific lines are gone.
assert_no_grep 'published by push' "$manual"
assert_no_grep 'for this checkout' "$manual"
assert_no_grep '(^|[^A-Za-z])[Dd]oors?([^A-Za-z]|$)' "$manual"
assert_no_grep '此工作副本' "$manual"
assert_fgrep 'Installing this framework starts no service.' "$manual"

# Trainers are told how to add their own project cards.
assert_fgrep 'Trainers: open this file in a text editor, find the PROJECTS list and copy the example block to add your own projects.' "$manual"

# The closing band links the README walk-through and glossary.
assert_fgrep '/ai_native_sdlc#your-first-hour-a-training-walk-through' "$manual"
assert_fgrep '/ai_native_sdlc#words-used-here' "$manual"

# A glossary of exactly eight terms, in both languages.
grep -o 'data-i18n="glossary\.list">.*</dl>' "$manual" > "$tmpdir/gloss-en.txt"
# The backticks delimit the JS template literal, not command substitution.
# shellcheck disable=SC2016
grep -o '"glossary\.list":`.*`' "$manual" > "$tmpdir/gloss-zh.txt"
for f in gloss-en gloss-zh; do
  grep -o '<dt>' "$tmpdir/$f.txt" | wc -l | tr -d '[:space:]' > "$tmpdir/$f.count"
  printf '\n' >> "$tmpdir/$f.count"
  assert_grep '^8$' "$tmpdir/$f.count"
done
for term in 'Gate' 'Hook' 'Spec' 'REQ-ID' 'Worktree' 'RCA' 'The roles' 'Engine map'; do
  assert_fgrep "<dt>$term</dt>" "$tmpdir/gloss-en.txt"
done

# The two languages stay in step: every data-i18n key has a ZH entry, and no
# ZH entry is an orphan that no element uses (an orphan is text nobody sees
# until it is wrong).
grep -o 'data-i18n="[^"]*"' "$manual" | sed 's/^data-i18n="//; s/"$//' | sort -u > "$tmpdir/keys-html.txt"
awk '/^const ZH = \{/ || /^Object\.assign\(ZH,/ { inside = 1 } inside { print } inside && /^\}\)?;/ { inside = 0 }' "$manual" \
  | grep -oE '(^|[,{]) *"[a-z][A-Za-z0-9.]*" *:' \
  | sed -E 's/^[,{]? *"//; s/" *:$//' | sort -u > "$tmpdir/keys-zh.txt"
assert_grep '^path\.note$' "$tmpdir/keys-zh.txt"
comm -3 "$tmpdir/keys-html.txt" "$tmpdir/keys-zh.txt" > "$tmpdir/keys-diff.txt"
if [ -s "$tmpdir/keys-diff.txt" ]; then
  printf 'i18n keys out of step (col 1: HTML only, col 2: ZH only):\n' >&2
  cat "$tmpdir/keys-diff.txt" >&2
fi
wc -l < "$tmpdir/keys-diff.txt" | tr -d '[:space:]' > "$tmpdir/keys-diff.count"
printf '\n' >> "$tmpdir/keys-diff.count"
assert_grep '^0$' "$tmpdir/keys-diff.count"
# The ZH command note carries the one-line hunt / test-audit / rca contrast.
grep -o '"cmd\.note":"[^"]*"' "$manual" > "$tmpdir/zh-cmd-note.txt"
assert_fgrep 'test-audit' "$tmpdir/zh-cmd-note.txt"
assert_fgrep 'rca' "$tmpdir/zh-cmd-note.txt"

finish
