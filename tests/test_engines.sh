#!/bin/bash
# AI-Native SDLC — content tests for the engine-map feature.
#
# Covers REQ-ENGINE-031 (the scrub fence's explicit file list includes
# `agents/*.conf` and `settings/*.json`, so a forbidden token in the role
# manifest or the hooks snippet cannot ship unscanned).
#
# The fence itself lives in tests/test_scrub.sh. This file asserts on the
# fence's list-building — both on its source (so the widening cannot be
# deleted without a failure here, even before the .conf files exist) and on
# the list it actually produces, tied back to the count the fence prints so
# the replica cannot drift from the real thing.
#
# These are read-only assertions; nothing here writes outside its tmpdir.
#
# File-wide: the search patterns below are markdown and paths quoted verbatim —
# literal backticks around a role name, a literal `~/.claude/...` path — never
# shell expansions, so SC2016 and SC2088 do not apply to this file.
# shellcheck disable=SC2016,SC2088
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"
repo=$TEST_REPO

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-engines.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

cd "$repo" || exit 1

# ---------------------------------------------------------------------------
# REQ-ENGINE-031 — the scrub fence's file list includes agents/*.conf and
# settings/*.json.
req "REQ-ENGINE-031"

scrub="$repo/tests/test_scrub.sh"
assert_file "$scrub"

# (a) The two globs are in the fence's explicit list. Source assertions,
#     because `agents/*.conf` has no file to match until the role manifest
#     lands — remove either glob and this fails.
assert_grep 'agents/\*\.conf' "$scrub"
assert_grep 'settings/\*\.json' "$scrub"

# (b) The list is still built explicitly, one glob at a time, and never by a
#     recursive grep over the checkout.
assert_grep '^FILES=\(\)$' "$scrub"
assert_no_grep '^[^#]*grep +-[a-zA-Z]*r' "$scrub"

# (c) Build the list the same way the fence does, and prove the widening
#     actually reaches the scanner.
FILES=()
for f in sdlc-policy.md README.md install.sh \
         commands/*.md agents/*.md agents/*.conf hooks/*.sh scripts/*.sh \
         settings/*.json; do
  [ -f "$f" ] && FILES+=("$f")
done
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(find -H templates -type f ! -name '.*' | LC_ALL=C sort)

printf '%s\n' ${FILES[@]+"${FILES[@]}"} > "$tmpdir/list.txt"
printf '%s\n' "${#FILES[@]}" > "$tmpdir/count.txt"

# Non-empty, and the anchor files are still there.
assert_grep '^[1-9][0-9]*$' "$tmpdir/count.txt"
assert_grep '^sdlc-policy\.md$' "$tmpdir/list.txt"
# Compatibility directory links must not hide templates from the scrub.
assert_grep '^templates/specs/requirements\.md$' "$tmpdir/list.txt"
assert_grep '^README\.md$' "$tmpdir/list.txt"
assert_grep '^install\.sh$' "$tmpdir/list.txt"

# specs/ and tests/ are excluded by construction.
assert_no_grep '^(specs|tests)/' "$tmpdir/list.txt"

# The settings glob really adds the hooks snippet to what gets scanned.
assert_grep '^settings/hooks-snippet\.json$' "$tmpdir/list.txt"

# Every agents/*.conf present in the checkout is in the list (vacuous only
# until the role manifest lands; a manifest that escapes the fence fails here).
for f in agents/*.conf; do
  [ -f "$f" ] || continue
  assert_grep "^$(printf '%s' "$f" | sed 's/[.[\*^$]/\\&/g')\$" "$tmpdir/list.txt"
done

# (d) Tie the replica above to the real fence: run it and require that it
#     reports scanning exactly this many files, and passes.
capture "$tmpdir/scrub.out" bash "$scrub"
assert_rc 0 "$tmpdir/scrub.out"
assert_grep "^REQ-GCORE-001: scanning ${#FILES[@]} file\(s\)\$" "$tmpdir/scrub.out"

# ---------------------------------------------------------------------------
# Routing by ROLE, not by model name: sdlc-policy.md's routing table, the role
# definitions, the engine-map path and the announcement wording.
#
# Covers REQ-ENGINE-001, REQ-ENGINE-002, REQ-ENGINE-003, REQ-ENGINE-004 and
# REQ-ENGINE-036. All read-only assertions over the shipped policy file.
policy="$repo/sdlc-policy.md"

# assert_line_pair <anchor> <token> <file> — one line of <file> holding the
# fixed string <anchor> must also hold the fixed string <token>. Both matches
# are grep -F, so no character in either argument is special.
assert_line_pair() {
  local anchor="$1" token="$2" file="$3"
  if [ -f "$file" ] &&
     grep -F -- "$anchor" "$file" 2>/dev/null | grep -qF -- "$token"; then
    _test_pass "line with '$anchor' also has '$token' : $file"
  else
    _test_fail "expected one line with '$anchor' and '$token' in $file"
  fi
}

# assert_role_word <row-label> <cell> — the cell must be one of the four roles.
assert_role_word() {
  case "$2" in
    judge|build|verify|read) _test_pass "row [$1]: third cell is '$2'" ;;
    *) _test_fail "row [$1]: third cell is '$2', not judge/build/verify/read" ;;
  esac
}

# ---------------------------------------------------------------------------
# REQ-ENGINE-001 — the routing table's third column is headed `Role` and holds
# one of `judge`, `build`, `verify`, `read` on every phase row, naming no model.
req "REQ-ENGINE-001"

assert_file "$policy"

# (a) The header names Role; the old Model heading is gone from the file.
assert_grep '^\| *Phase *\| *Who *\| *Role *\|$' "$policy"
assert_no_grep '^\| *Phase *\| *Who *\| *Model *\|$' "$policy"
assert_no_grep '\| *Model *\|' "$policy"

# (b) Parse the table with awk: everything from the header down to the first
#     line that is not a table row, minus the `|---|---|---|` separator.
awk '
  /^\| *Phase *\| *Who *\| *Role *\|/ { intable = 1; next }
  intable && $0 !~ /^\|/             { exit }
  intable && $0 ~ /^\|[-: |]*\|$/    { next }
  intable                            { print }
' "$policy" > "$tmpdir/rows.txt"

count_into "$tmpdir/rows.txt" '^\|' "$tmpdir/rowcount.txt"
assert_grep '^10$' "$tmpdir/rowcount.txt"

# (c) Assert EACH parsed row's third cell, one assertion per row.
while IFS= read -r row; do
  [ -n "$row" ] || continue
  rowphase=$(printf '%s\n' "$row" |
    awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
  rowrole=$(printf '%s\n' "$row" |
    awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}')
  assert_role_word "$rowphase" "$rowrole"
done < "$tmpdir/rows.txt"

# (d) No model name survives anywhere in the parsed rows.
assert_no_grep '[Ff]able|[Oo]pus|[Hh]aiku|[Ss]onnet' "$tmpdir/rows.txt"

# (e) The mapping itself, phase by phase. The token carries its pipes, so it
#     matches the role CELL and not the same word inside the phase text
#     ("read" would otherwise match "bulk reading").
assert_line_pair 'Architecture / spec / design' '| judge |' "$policy"
assert_line_pair 'Adversarial spec review' '| verify |' "$policy"
assert_line_pair 'Tests-first + implementation' '| build |' "$policy"
assert_line_pair 'Independent verification' '| verify |' "$policy"
assert_line_pair 'Final review' '| judge |' "$policy"
assert_line_pair 'Research / bulk reading' '| read |' "$policy"
assert_line_pair 'Debugging evidence' '| verify |' "$policy"
assert_line_pair 'RCA root cause' '| judge |' "$policy"
assert_line_pair 'Agentic e2e walkthrough' '| verify |' "$policy"
assert_line_pair 'Test-suite audit' '| verify |' "$policy"

# ---------------------------------------------------------------------------
# REQ-ENGINE-002 — every phase the file names today survives, phase text and
# "Who" column unchanged.
req "REQ-ENGINE-002"

assert_line_pair 'Architecture / spec / design' 'main session' "$policy"
assert_line_pair 'Adversarial spec review' '`spec-reviewer` agent' "$policy"
assert_line_pair 'Tests-first + implementation' '`implementer` agent (worktree)' "$policy"
assert_line_pair 'Independent verification' '`verifier` agent (fresh worktree)' "$policy"
assert_line_pair 'Final review' 'main session (reads the diff itself)' "$policy"
assert_line_pair 'Research / bulk reading' '`researcher` agent' "$policy"
assert_line_pair 'Debugging evidence' '`evidence` agent' "$policy"
assert_line_pair 'RCA root cause (/rca step 2)' 'main session' "$policy"
assert_line_pair 'Agentic e2e walkthrough (webapp, pre-ship)' '`ui-tester` agent' "$policy"
assert_line_pair 'Test-suite audit (four lanes, read-only)' '`test-auditor` agent' "$policy"

# ---------------------------------------------------------------------------
# REQ-ENGINE-003 — the file defines the four roles and the work each covers.
req "REQ-ENGINE-003"

assert_grep '^## The four roles$' "$policy"
assert_grep '^- `judge` ' "$policy"
assert_grep '^- `build` ' "$policy"
assert_grep '^- `verify` ' "$policy"
assert_grep '^- `read` ' "$policy"

assert_fgrep "the main session's own reasoning" "$policy"
assert_line_pair '`build`' 'the implementer' "$policy"
assert_line_pair '`verify`' 'the reviewing and auditing agents' "$policy"
assert_line_pair '`read`' 'bulk reading' "$policy"

# ---------------------------------------------------------------------------
# REQ-ENGINE-004 — the engine map is named as the binding from role to model,
# and no specific model is asserted as the main session's.
req "REQ-ENGINE-004"

assert_fgrep '~/.claude/sdlc-engines.conf' "$policy"
assert_fgrep 'the binding from role to model' "$policy"

# The old opening assertion is gone...
assert_no_grep 'Main session = Fable' "$policy"
assert_no_grep 'Main session = ' "$policy"
# ...and no model name is left anywhere in the file to replace it with.
assert_no_grep '[Ff]able|[Oo]pus|[Hh]aiku|[Ss]onnet' "$policy"

# ---------------------------------------------------------------------------
# REQ-ENGINE-036 — the routing rules announce `<phase> → <role>`.
req "REQ-ENGINE-036"

assert_fgrep '`<phase> → <role>`' "$policy"
assert_no_grep '<phase> → <engine>' "$policy"

# ---------------------------------------------------------------------------
# REQ-ENGINE-022 — the model list for a role is an ORDERED FALLBACK CHAIN: the
# first entry runs, the rest are what to drop to; a substitution is announced
# once per session; and no phase silently runs on an unlisted model.
#
# Each phrase is pinned as a fixed string on ONE line of the policy, so a
# reflow that splits a sentence in half fails here rather than quietly
# weakening the instruction.
req "REQ-ENGINE-022"

assert_file "$policy"

# (a) The chain is ordered, and the first entry is the one that runs.
assert_fgrep 'an ordered fallback chain: the first entry is what runs' "$policy"

# (b) A substitution is announced once, on first use in a session.
assert_fgrep 'announced once, the first time it is used in a session' "$policy"

# (c) Nothing runs off-map in silence.
assert_fgrep 'No phase silently runs on a model the owner did not list.' "$policy"

# (d) The three live together under the roles material, not scattered: extract
#     the subsection (heading to the next `##`/`###`) and assert on it.
awk '
  /^### Reading the engine map$/ { insec = 1; next }
  insec && /^#{2,3} /            { exit }
  insec                          { print }
' "$policy" > "$tmpdir/chain.txt"

count_into "$tmpdir/chain.txt" '.' "$tmpdir/chaincount.txt"
assert_grep '^[1-9][0-9]*$' "$tmpdir/chaincount.txt"

assert_fgrep 'an ordered fallback chain: the first entry is what runs' "$tmpdir/chain.txt"
assert_fgrep 'announced once, the first time it is used in a session' "$tmpdir/chain.txt"
assert_fgrep 'No phase silently runs on a model the owner did not list.' "$tmpdir/chain.txt"

# (e) The mechanism is described without naming a model — the file-wide ban in
#     REQ-ENGINE-004 restated over this section, so a future edit that reaches
#     for an example model name fails against the requirement that owns it.
assert_no_grep '[Ff]able|[Oo]pus|[Hh]aiku|[Ss]onnet' "$tmpdir/chain.txt"

# ---------------------------------------------------------------------------
# REQ-ENGINE-023 — a model the owner names in the moment outranks the map, and
# no project may pin `model` in its own `.claude/settings.json`.
req "REQ-ENGINE-023"

# (a) The owner in the moment beats the map.
assert_fgrep 'A model the owner names in the moment outranks the map' "$policy"

# (b) No project-level pin, and the reason: the map is the single binding, so a
#     pin would fork the routing where nobody sees it.
assert_fgrep 'No project may pin `model` in its own `.claude/settings.json`' "$policy"
assert_fgrep 'a project-level pin would fork the routing' "$policy"

# (c) Both live in the same subsection as the chain rules above.
assert_fgrep 'A model the owner names in the moment outranks the map' "$tmpdir/chain.txt"
assert_fgrep 'No project may pin `model` in its own `.claude/settings.json`' "$tmpdir/chain.txt"

# ---------------------------------------------------------------------------
# REQ-ENGINE-040 — `escalate` is a LEVER, not a routing row: no phase escalates
# on its own, the routing table never sends work to it, the OWNER raises a
# phase to it by naming it in the moment, and any use of it is announced in the
# same one line as the phase.
#
# Each phrase is pinned as a fixed string on ONE line of the policy, so a
# reflow that splits a sentence in half fails here rather than quietly turning
# the lever back into a row.
req "REQ-ENGINE-040"

assert_file "$policy"

# (a) A lever, not a row — nothing promotes work to it on its own.
assert_fgrep 'a lever, not a routing row: no phase escalates on its own' "$policy"

# (b) The routing table never sends work there.
assert_fgrep 'the routing table above never sends work to it.' "$policy"

# (c) The owner is the one who raises a phase to it, in the moment.
assert_fgrep 'The owner raises a phase to it by naming it in the moment' "$policy"

# (d) Never silent: announced in the same one line as the phase.
assert_fgrep 'Any use of it is announced in the same one line as the phase' "$policy"

# (e) All four live in one subsection, not scattered: extract it (heading to the
#     next `##`/`###`) and assert on it.
awk '
  /^### The `escalate` lever$/ { insec = 1; next }
  insec && /^#{2,3} /          { exit }
  insec                        { print }
' "$policy" > "$tmpdir/escalate.txt"

count_into "$tmpdir/escalate.txt" '.' "$tmpdir/escalatecount.txt"
assert_grep '^[1-9][0-9]*$' "$tmpdir/escalatecount.txt"

assert_fgrep 'a lever, not a routing row: no phase escalates on its own' "$tmpdir/escalate.txt"
assert_fgrep 'the routing table above never sends work to it.' "$tmpdir/escalate.txt"
assert_fgrep 'The owner raises a phase to it by naming it in the moment' "$tmpdir/escalate.txt"
assert_fgrep 'Any use of it is announced in the same one line as the phase' "$tmpdir/escalate.txt"

# (f) The lever is described without naming a model — the file-wide ban in
#     REQ-ENGINE-004 restated over this subsection, so an edit that reaches for
#     "escalate to <model>" fails against the requirement that owns the prose.
assert_no_grep '[Ff]able|[Oo]pus|[Hh]aiku|[Ss]onnet' "$tmpdir/escalate.txt"

# ---------------------------------------------------------------------------
# REQ-ENGINE-041 — the lever is what a session OFFERS rather than silently
# takes, when a judgement is close, contested, or costly to get wrong.
req "REQ-ENGINE-041"

# (a) Offered, not taken.
assert_fgrep 'A session OFFERS the lever rather than silently taking it' "$policy"

# (b) The trigger, all three cases on one line.
assert_fgrep 'is close, contested, or costly to get wrong.' "$policy"

# (c) Offering is not taking: say what and why, then wait.
assert_fgrep 'Offering is not taking: the session says what it would escalate' "$policy"

# (d) Same subsection as the lever definition above.
assert_fgrep 'A session OFFERS the lever rather than silently taking it' "$tmpdir/escalate.txt"
assert_fgrep 'is close, contested, or costly to get wrong.' "$tmpdir/escalate.txt"
assert_fgrep 'Offering is not taking: the session says what it would escalate' "$tmpdir/escalate.txt"

# ---------------------------------------------------------------------------
# The SessionStart wiring in settings/hooks-snippet.json: REQ-ENGINE-020 (the
# entry exists, names the hook, and the file stays valid JSON) and
# REQ-ENGINE-035 (it is limited to startup/resume/clear and carries a timeout).
#
# Read-only assertions over the shipped snippet, parsed with jq — the tool
# `make check` validates the file with, so a hand-rolled grep cannot pass here
# on a file jq would reject.
snippet="$repo/settings/hooks-snippet.json"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-020"

assert_file "$snippet"
assert_file "$repo/hooks/session-engines.sh"

# (a) Valid JSON, exactly as `make check` requires.
capture "$tmpdir/snippet-valid.out" jq -e . "$snippet"
assert_rc 0 "$tmpdir/snippet-valid.out"

# (b) SessionStart is present under "hooks" — AND the events already there
#     survive: this file is merged into a settings.json, never a replacement.
jq -r '.hooks | keys_unsorted[]' "$snippet" > "$tmpdir/hook-events.txt"
assert_grep '^SessionStart$' "$tmpdir/hook-events.txt"
assert_grep '^PreToolUse$' "$tmpdir/hook-events.txt"
assert_grep '^PostToolUse$' "$tmpdir/hook-events.txt"
assert_grep '^Stop$' "$tmpdir/hook-events.txt"
assert_grep '^PostCompact$' "$tmpdir/hook-events.txt"

# (c) Its command runs the session-engines hook out of the installed hooks
#     directory, quoted the way every other command in the file is.
jq -r '[.hooks.SessionStart[]?.hooks[]?.command] | .[]' "$snippet" \
  > "$tmpdir/ss-commands.txt"
assert_grep 'session-engines\.sh' "$tmpdir/ss-commands.txt"
assert_fgrep '"$HOME/.claude/hooks/session-engines.sh"' "$tmpdir/ss-commands.txt"

# (d) Every SessionStart hook declared is a `command` hook — the type the
#     harness runs — so the entry cannot pass as a shape nothing executes.
jq -r '[.hooks.SessionStart[]?.hooks[]?.type] | unique | .[]' "$snippet" \
  > "$tmpdir/ss-types.txt"
assert_grep '^command$' "$tmpdir/ss-types.txt"
count_into "$tmpdir/ss-types.txt" '.' "$tmpdir/ss-typecount.txt"
assert_grep '^1$' "$tmpdir/ss-typecount.txt"

# (e) The file's own `//` key enumerates what is being merged, so it names the
#     new entry rather than leaving the owner to spot it in the diff.
jq -r '."//"' "$snippet" > "$tmpdir/snippet-doc.txt"
assert_grep 'SessionStart' "$tmpdir/snippet-doc.txt"

# ---------------------------------------------------------------------------
req "REQ-ENGINE-035"

# assert_matcher_covers / assert_matcher_excludes <matcher> <source> — the
# matcher is the extended regex the harness tests a SessionStart source against,
# so it is exercised as one here rather than string-compared.
assert_matcher_covers() {
  if printf '%s\n' "$2" | grep -qE -- "$1"; then
    _test_pass "matcher /$1/ covers source '$2'"
  else
    _test_fail "matcher /$1/ does not cover source '$2'"
  fi
}
assert_matcher_excludes() {
  if printf '%s\n' "$2" | grep -qE -- "$1"; then
    _test_fail "matcher /$1/ must not cover source '$2'"
  else
    _test_pass "matcher /$1/ excludes source '$2'"
  fi
}

# (a) Exactly one SessionStart entry runs this hook, and it carries a matcher.
jq -r '[.hooks.SessionStart[]?
        | select([.hooks[]?.command // ""] | join(" ") | test("session-engines"))
        | .matcher // empty] | .[]' "$snippet" > "$tmpdir/ss-matcher.txt"
count_into "$tmpdir/ss-matcher.txt" '.' "$tmpdir/ss-matchercount.txt"
assert_grep '^1$' "$tmpdir/ss-matchercount.txt"

ss_matcher=$(head -n 1 "$tmpdir/ss-matcher.txt")
assert_matcher_covers "$ss_matcher" startup
assert_matcher_covers "$ss_matcher" resume
assert_matcher_covers "$ss_matcher" clear

# (b) ...and NOT compaction: the PostCompact entry above already re-injects the
#     policy there, so this hook must not re-fire on every compaction.
assert_matcher_excludes "$ss_matcher" compact

# (c) A timeout is present, so a slow or wedged map read cannot hang a start.
jq -r '[.hooks.SessionStart[]?.hooks[]?
        | select((.command // "") | test("session-engines"))
        | .timeout | numbers] | .[]' "$snippet" > "$tmpdir/ss-timeout.txt"
count_into "$tmpdir/ss-timeout.txt" '.' "$tmpdir/ss-timeoutcount.txt"
assert_grep '^1$' "$tmpdir/ss-timeoutcount.txt"
assert_grep '^[1-9][0-9]*$' "$tmpdir/ss-timeout.txt"

finish
