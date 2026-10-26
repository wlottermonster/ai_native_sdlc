#!/bin/bash
# AI-Native SDLC — the one owner of a feature's machine state.
#
#   sdlc-state.sh init <feature>         write specs/<feature>/state.json
#   sdlc-state.sh stamp <feature>        record the Gate 1 approval
#   sdlc-state.sh stamp-state <feature>  print none | invalid <path> | stale | ok <approved_at>
#   sdlc-state.sh evidence <feature>     run check then test, write
#                                        specs/<feature>/evidence.json; on a
#                                        green run set `passes` in state.json
#   sdlc-state.sh record <feature> <verifier|ui-tester> <PASS|FAIL|COULD-NOT-TEST> "<note>"
#                                        store a verdict against current evidence
#   sdlc-state.sh evidence-state <feature> [<ref>|WORKTREE]
#                                        print none | invalid <path> | stale |
#                                        red | green; exit 0 only for green
#   sdlc-state.sh status                 one line per feature under specs/
#
# state.json and evidence.json carry a `digest`: the sha256 of the document
# with the digest removed and keys sorted (jq -cS). A reader that finds the
# digest wrong treats the file as invalid and never as a stamp or as evidence.
# Every write goes to a temp file in the target's own directory and is renamed
# over the target, so a failure leaves the target exactly as it was.
# Freshness is judged by evidence tree (hooks/guard-lib.sh evidence_tree): the
# tree with the feature's two JSON files removed, so committing them never
# makes evidence stale. `passes` is written by `evidence` alone, and only after
# a green run; `stamp` and `record` never touch it.
set -u

usage() {
  cat >&2 <<'EOF'
usage: sdlc-state.sh init <feature>
       sdlc-state.sh stamp <feature>
       sdlc-state.sh stamp-state <feature>
       sdlc-state.sh evidence <feature>
       sdlc-state.sh record <feature> <verifier|ui-tester> <PASS|FAIL|COULD-NOT-TEST> "<note>"
       sdlc-state.sh evidence-state <feature> [<ref>|WORKTREE]
       sdlc-state.sh status
EOF
  exit 2
}

die() { printf 'sdlc-state: %s\n' "$*" >&2; exit 1; }

REQ_ID_RE='REQ-[A-Z0-9-]+-[0-9]{3}'

# --- helpers (reused by the subcommands later tasks add) --------------------

require_tools() {
  local t
  for t in jq shasum git; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"
  done
}

# repo_root — the repository root; refuses outside a git repository.
repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not a git repository: $PWD"
  if [ -z "$root" ] || ! cd "$root" 2>/dev/null; then
    die "cannot enter the repository root: ${root:-$PWD}"
  fi
  ROOT="$root"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sha256_file() { shasum -a 256 < "$1" | cut -d' ' -f1; }

state_path() { printf '%s/specs/%s/state.json' "$ROOT" "$1"; }

req_path() { printf '%s/specs/%s/requirements.md' "$ROOT" "$1"; }

# spec_sha <feature> — sha256 of requirements.md, empty on a read failure.
spec_sha() {
  local r
  r=$(req_path "$1")
  [ -r "$r" ] || return 1
  sha256_file "$r"
}

# feature_dir_check <feature> — requirements.md must be readable.
feature_dir_check() {
  local r
  r=$(req_path "$1")
  [ -f "$r" ] && [ -r "$r" ] || die "cannot read $r"
}

# digest_of <file> — sha256 of the document with the digest removed.
digest_of() {
  local body
  body=$(jq -cS 'del(.digest)' "$1" 2>/dev/null) || return 1
  printf '%s\n' "$body" | shasum -a 256 | cut -d' ' -f1
}

# digest_ok <file> — 0 when the file parses and its digest matches its body.
digest_ok() {
  local want have
  have=$(jq -r '.digest // empty' "$1" 2>/dev/null) || {
    printf 'invalid: %s (not readable JSON)\n' "$1" >&2; return 1; }
  want=$(digest_of "$1") || {
    printf 'invalid: %s (not readable JSON)\n' "$1" >&2; return 1; }
  if [ -z "$have" ] || [ "$have" != "$want" ]; then
    printf 'invalid: %s (digest mismatch)\n' "$1" >&2
    return 1
  fi
}

# write_atomic <target> — read a JSON document on stdin, add its digest,
# write it formatted (jq -S) to a temp file beside the target, rename it over
# the target. On any failure the target is untouched and the script exits
# non-zero naming the path.
write_atomic() {
  local target="$1" dir tmp dg
  dir=$(dirname "$target")
  tmp=$(mktemp "$dir/.state.XXXXXX" 2>/dev/null) || die "cannot write $target (directory not writable)"
  if ! jq -S 'del(.digest)' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; die "cannot write $target (bad document)"
  fi
  dg=$(digest_of "$tmp") || { rm -f "$tmp"; die "cannot write $target (digest)"; }
  if ! jq -S --arg dg "$dg" '.digest = $dg' "$tmp" > "$tmp.d" 2>/dev/null \
     || ! mv "$tmp.d" "$tmp" 2>/dev/null \
     || ! mv "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp" "$tmp.d"; die "cannot write $target"
  fi
}

# req_tiers <requirements.md> — one "ID<TAB>tier" per REQ-ID, in file order,
# unique; the tier is the first `verify:` line after the ID and before the
# next one (the block rule of hooks/req-gate.sh), default "unit".
req_tiers() {
  awk -v re="$REQ_ID_RE" '
    match($0, re) {
      cur = substr($0, RSTART, RLENGTH)
      if (!(cur in seen)) { seen[cur] = 1; order[++n] = cur }
    }
    /verify:/ && cur != "" && !(cur in tier) {
      t = $0; sub(/.*verify:[ \t]*/, "", t); sub(/[^a-z0-9-].*/, "", t)
      if (t != "") tier[cur] = t
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], (order[i] in tier ? tier[order[i]] : "unit") }
  ' "$1"
}

# tiers_json <requirements.md> — {"ID": {"verify": tier, "passes": false}}.
tiers_json() {
  req_tiers "$1" | jq -Rn '
    [inputs | split("\t") | {key: .[0], value: {verify: .[1], passes: false}}]
    | from_entries'
}

# stamp_state <feature> — prints none | invalid <path> | stale | ok <at>.
stamp_state() {
  local f at sha cur
  f=$(state_path "$1")
  if [ ! -e "$f" ]; then echo none; return 1; fi
  if ! digest_ok "$f"; then echo "invalid $f"; return 1; fi
  at=$(jq -r '.gate1.approved_at // empty' "$f")
  sha=$(jq -r '.gate1.spec_sha // empty' "$f")
  if [ -z "$at" ]; then echo none; return 1; fi
  cur=$(spec_sha "$1") || cur=""
  if [ -z "$sha" ] || [ "$cur" != "$sha" ]; then echo stale; return 1; fi
  echo "ok $at"
}

# --- subcommands ------------------------------------------------------------

cmd_init() {
  local feat="$1" f r
  feature_dir_check "$feat"
  f=$(state_path "$feat")
  r=$(req_path "$feat")
  [ -e "$f" ] && die "refusing to overwrite $f (it already exists; use stamp)"
  local reqs
  reqs=$(tiers_json "$r") || die "cannot read $r"
  jq -n --arg feat "$feat" --arg now "$(now_iso)" --argjson reqs "$reqs" '
    {schema: 1, feature: $feat, created_at: $now,
     gate1: {approved_at: null, spec_sha: null},
     requirements: $reqs}' | write_atomic "$f" || exit 1
  printf 'initialised %s\n' "$f"
}

cmd_stamp() {
  local feat="$1" f r sha reqs count
  feature_dir_check "$feat"
  f=$(state_path "$feat")
  r=$(req_path "$feat")
  [ -e "$f" ] || die "no $f (run init first)"
  digest_ok "$f" || die "refusing to stamp: $f is invalid (digest mismatch)"
  sha=$(spec_sha "$feat") || die "cannot read $r"
  reqs=$(tiers_json "$r") || die "cannot read $r"
  count=$(jq -n --argjson old "$(jq '.requirements' "$f")" --argjson new "$reqs" \
    '$old + $new | length')
  # Printed BEFORE the write: these lines are the session's record of what
  # was stamped, and printing first means a write that is refused or fails
  # still leaves that record. A permission prompt shows only the command
  # text, never this output.
  printf 'feature: %s\nrequirements: %s\nspec_sha: %s\n' "$feat" "$count" "$sha"
  jq --arg now "$(now_iso)" --arg sha "$sha" --argjson new "$reqs" '
    .gate1 = {approved_at: $now, spec_sha: $sha}
    | .requirements = ($new + .requirements)' "$f" | write_atomic "$f" || exit 1
  printf 'stamped %s\n' "$f"
}

cmd_stamp_state() { stamp_state "$1"; }

# --- evidence ---------------------------------------------------------------

evidence_path() { printf '%s/specs/%s/evidence.json' "$ROOT" "$1"; }

# scratch — a private temp directory, removed on exit; sets SCRATCH. Called in
# the main shell only (never inside $(...)), so the trap and the path survive.
SCRATCH=""
scratch() {
  [ -n "$SCRATCH" ] && return 0
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-state.XXXXXX") || die "cannot create a temp directory"
  trap 'rm -rf "$SCRATCH"' EXIT
}

# contract_cmd <check|test> — print the command the gates would run for that
# target: a Makefile target, else an npm script, else .venv/bin/pytest.
# Returns 1 when none is found, 2 when a contract file cannot be read.
contract_cmd() {
  local t="$1"
  if [ -f Makefile ] && [ ! -r Makefile ]; then return 2; fi
  if [ -f Makefile ] && grep -qE "^$t:" Makefile; then
    printf 'make %s' "$t"
    return 0
  fi
  if [ -f package.json ] && [ ! -r package.json ]; then return 2; fi
  if [ -f package.json ] && jq -e --arg t "$t" '.scripts[$t]' package.json >/dev/null 2>&1; then
    printf 'npm run --silent %s' "$t"
  elif [ -x .venv/bin/pytest ]; then
    printf '.venv/bin/pytest -x -q'
  else
    return 1
  fi
}

# run_contract <name> <command> — run it from the repo top with its output in
# a temp file; set RUN_RC and RUN_SECONDS; print the last 40 lines when red.
run_contract() {
  local name="$1" cmd="$2" out start argv
  out="$SCRATCH/$name.out"
  read -r -a argv <<< "$cmd"
  printf 'evidence: running %s ...\n' "$cmd"
  start=$(date +%s)
  RUN_RC=0
  "${argv[@]}" > "$out" 2>&1 < /dev/null || RUN_RC=$?
  RUN_SECONDS=$(( $(date +%s) - start ))
  if [ "$RUN_RC" -eq 0 ]; then
    printf 'evidence: %s passed (%ss)\n' "$cmd" "$RUN_SECONDS"
  else
    printf 'evidence: %s FAILED with exit %s (%ss); last 40 lines:\n' "$cmd" "$RUN_RC" "$RUN_SECONDS" >&2
    tail -n 40 "$out" >&2
  fi
}

# coverage_json <feature> — {"ID": label} for every ID in requirements.md, the
# label read from `req-gate.sh --report`. An ID that a GATE A/B line names, or
# that the report does not label, is MISSING.
coverage_json() {
  local feat="$1" report labels
  report=$(bash "$REQ_GATE" --report 2>/dev/null) \
    || printf 'evidence: %s --report failed; unlabelled IDs are recorded MISSING\n' "$REQ_GATE" >&2
  labels=$(printf '%s\n' "$report" | awk -v f="$feat" '
    /^GATE B:/ { if ($3 == f) for (i = 4; i <= NF; i++) if ($i ~ /^REQ-/) bad[$i] = 1; next }
    /^GATE A:/ { if (index($0, "specs/" f "/requirements.md")) bad[$3] = 1; next }
    $1 == f && NF == 3 && $3 ~ /^(OK|OPEN|PARKED|UNTASKED|DEFERRED)$/ { lab[$2] = $3 }
    END { for (k in lab) if (!(k in bad)) printf "%s\t%s\n", k, lab[k] }')
  req_tiers "$(req_path "$feat")" | cut -f1 | jq -Rn --arg labels "$labels" '
    ($labels | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $l
    | [inputs | select(length > 0) | {key: ., value: ($l[.] // "MISSING")}] | from_entries'
}

cmd_evidence() {
  local feat="$1" ef sf ccmd tcmd crc=0 trc=0 tree after head branch cov c_rc c_s t_rc t_s
  feature_dir_check "$feat"
  ef=$(evidence_path "$feat")
  sf=$(state_path "$feat")
  ccmd=$(contract_cmd check) || crc=$?
  tcmd=$(contract_cmd test) || trc=$?
  if [ "$crc" -ne 0 ] || [ "$trc" -ne 0 ]; then
    die "no check and test contract found in $ROOT (Makefile check: and test: targets, npm scripts check and test, or .venv/bin/pytest); nothing written"
  fi
  head=$(git rev-parse -q --verify HEAD) || die "no commit yet in $ROOT; evidence needs a HEAD; nothing written"
  tree=$(evidence_tree "$feat" WORKTREE) \
    || die "cannot compute the evidence tree of $ROOT; nothing written"
  scratch
  run_contract check "$ccmd"; c_rc=$RUN_RC; c_s=$RUN_SECONDS
  run_contract test "$tcmd"; t_rc=$RUN_RC; t_s=$RUN_SECONDS
  after=$(evidence_tree "$feat" WORKTREE) \
    || die "cannot compute the evidence tree of $ROOT after the run; nothing written"
  if [ "$after" != "$tree" ]; then
    printf 'evidence: the runs changed the working tree; the tree that was tested is recorded, so this evidence reads stale until that change is gone\n' >&2
  fi
  branch=$(git symbolic-ref --short -q HEAD) || branch="-"
  [ -n "$branch" ] || branch="-"
  cov=$(coverage_json "$feat") || die "cannot read the coverage of $feat; nothing written"
  # A new run resets both verdict lanes: a verdict belongs to the evidence it
  # was given against.
  jq -n --arg feat "$feat" --arg at "$(now_iso)" --arg branch "$branch" \
    --arg head "$head" --arg tree "$tree" \
    --arg ccmd "$ccmd" --argjson crc "$c_rc" --argjson cs "$c_s" \
    --arg tcmd "$tcmd" --argjson trc "$t_rc" --argjson ts "$t_s" \
    --argjson cov "$cov" '
    {schema: 1, feature: $feat, at: $at, branch: $branch, head: $head,
     evidence_tree: $tree,
     check: {rc: $crc, seconds: $cs, command: $ccmd},
     test: {rc: $trc, seconds: $ts, command: $tcmd},
     coverage: $cov, verifier: null, "ui-tester": null}' | write_atomic "$ef" || exit 1
  printf 'recorded %s\n' "$ef"
  if [ "$c_rc" -ne 0 ] || [ "$t_rc" -ne 0 ]; then
    printf 'evidence: RED — passes in %s left unchanged\n' "$sf" >&2
    exit 1
  fi
  # The only writer of `passes` (REQ-TOUCH-006): true for exactly the IDs
  # req-gate labelled OK in this green run, false for every other.
  if [ ! -e "$sf" ]; then
    printf 'evidence: no %s; passes not recorded (run init and stamp)\n' "$sf" >&2
  elif ! digest_ok "$sf"; then
    printf 'evidence: %s is invalid; passes not recorded, file left as it was\n' "$sf" >&2
  else
    jq --argjson cov "$cov" \
      '.requirements |= with_entries(.value.passes = ($cov[.key] == "OK"))' "$sf" \
      | write_atomic "$sf" || exit 1
    printf 'passes updated in %s\n' "$sf"
  fi
}

# evidence_state <feature> <ref|WORKTREE> — set EV_STATE (none | invalid <path>
# | stale | red | green) and EV_FILE (a readable copy, only when valid). For a
# ref the file is read from the ref and compared with that ref's evidence tree
# (REQ-TOUCH-044). A tree that cannot be computed is stale, never green.
evidence_state() {
  local feat="$1" ref="$2" rel src rec cur
  rel="specs/$feat/evidence.json"
  EV_FILE=""
  if [ "$ref" = WORKTREE ]; then
    src=$(evidence_path "$feat")
    [ -e "$src" ] || { EV_STATE=none; return 0; }
    EV_FILE="$src"
  else
    if [ "${ref#-}" != "$ref" ] || ! git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
      printf 'evidence-state: no such ref: %s\n' "$ref" >&2
      EV_STATE=none; return 0
    fi
    scratch
    EV_FILE=$(mktemp "$SCRATCH/evidence.XXXXXX") || die "cannot create a temp file"
    if ! git show "$ref:$rel" > "$EV_FILE" 2>/dev/null; then
      EV_FILE=""; EV_STATE=none; return 0
    fi
    src="$ref:$rel"
  fi
  if ! digest_ok "$EV_FILE" 2>/dev/null; then
    EV_FILE=""; EV_STATE="invalid $src"; return 0
  fi
  rec=$(jq -r '.evidence_tree // empty' "$EV_FILE")
  if ! cur=$(evidence_tree "$feat" "$ref"); then
    printf 'evidence-state: cannot compute the evidence tree of %s; treated as stale\n' "$ref" >&2
    EV_STATE=stale; return 0
  fi
  if [ -z "$rec" ] || [ "$rec" != "$cur" ]; then EV_STATE=stale; return 0; fi
  if jq -e '.check.rc == 0 and .test.rc == 0' "$EV_FILE" >/dev/null 2>&1; then
    EV_STATE=green
  else
    EV_STATE=red
  fi
}

cmd_evidence_state() {
  evidence_state "$1" "${2:-WORKTREE}"
  printf '%s\n' "$EV_STATE"
  [ "$EV_STATE" = green ]
}

cmd_record() {
  local feat="$1" lane="$2" verdict="$3" note="$4" ef rec cur
  ef=$(evidence_path "$feat")
  [ -e "$ef" ] || die "refusing to record: no $ef (run sdlc-state.sh evidence $feat first)"
  digest_ok "$ef" || die "refusing to record: $ef is invalid (hand-edited, truncated or not JSON)"
  rec=$(jq -r '.evidence_tree // empty' "$ef")
  cur=$(evidence_tree "$feat" WORKTREE) \
    || die "refusing to record: cannot compute the working tree's evidence tree, so $ef cannot be verified"
  # One line on purpose: the suite's mutation deletes it and expects a red.
  [ -n "$rec" ] && [ "$rec" = "$cur" ] || die "refusing to record: $ef is stale (the code changed since the evidence run; run sdlc-state.sh evidence $feat)"
  jq --arg lane "$lane" --arg v "$verdict" --arg note "$note" --arg at "$(now_iso)" \
    '.[$lane] = {verdict: $v, note: $note, at: $at}' "$ef" | write_atomic "$ef" || exit 1
  printf 'recorded %s %s in %s\n' "$lane" "$verdict" "$ef"
}

cmd_status() {
  local dir feat stamp tasks open claimed parked done_ ev ver uit
  for dir in "$ROOT"/specs/*/; do
    [ -d "$dir" ] || continue
    feat=$(basename "$dir")
    case "$feat" in _*) continue ;; esac
    stamp=$(stamp_state "$feat" 2>/dev/null)
    case "$stamp" in
      ok*) stamp=$(printf '%s' "$stamp" | cut -d' ' -f2 | cut -dT -f1) ;;
      invalid*) stamp=invalid ;;
    esac
    tasks="$dir/tasks.md"
    open=0 claimed=0 parked=0 done_=0
    if [ -r "$tasks" ]; then
      open=$(grep -cE '^[[:space:]]*- \[ \]' "$tasks")
      claimed=$(grep -cE '^[[:space:]]*- \[~\]' "$tasks")
      parked=$(grep -cE '^[[:space:]]*- \[!\]' "$tasks")
      done_=$(grep -cE '^[[:space:]]*- \[[xX]\]' "$tasks")
    fi
    # The working tree's evidence; when absent there, the sdlc/<feature> ref's.
    if [ -e "$(evidence_path "$feat")" ]; then
      evidence_state "$feat" WORKTREE 2>/dev/null
    elif git rev-parse -q --verify "sdlc/$feat^{commit}" >/dev/null 2>&1; then
      evidence_state "$feat" "sdlc/$feat" 2>/dev/null
    else
      EV_STATE=none EV_FILE=""
    fi
    ev=${EV_STATE%% *} ver=none uit=none
    if [ -n "$EV_FILE" ]; then
      ver=$(jq -r '.verifier.verdict // "none"' "$EV_FILE" 2>/dev/null) || ver=none
      uit=$(jq -r '.["ui-tester"].verdict // "none"' "$EV_FILE" 2>/dev/null) || uit=none
    fi
    printf '%s stamp=%s tasks=open:%s,claimed:%s,parked:%s,done:%s evidence=%s verifier=%s ui-tester=%s\n' \
      "$feat" "$stamp" "$open" "$claimed" "$parked" "$done_" "$ev" "$ver" "$uit"
  done
}

# --- dispatch ---------------------------------------------------------------

[ $# -ge 1 ] || usage
sub="$1"
shift
case "$sub" in
  init|stamp|stamp-state|evidence) [ $# -eq 1 ] && [ -n "$1" ] || usage ;;
  evidence-state) [ $# -ge 1 ] && [ $# -le 2 ] && [ -n "$1" ] && [ -n "${2-x}" ] || usage ;;
  record)
    [ $# -eq 4 ] && [ -n "$1" ] || usage
    case "$2" in verifier|ui-tester) ;; *) usage ;; esac
    case "$3" in PASS|FAIL|COULD-NOT-TEST) ;; *) usage ;; esac
    ;;
  status) [ $# -eq 0 ] || usage ;;
  *) usage ;;
esac
case "${1:-}" in */*|.|..) usage ;; esac

require_tools

# The guard library (evidence_tree) and the requirement gate sit in hooks/
# beside scripts/: in the checkout and in ~/.claude alike. Resolved before
# repo_root changes directory, so a relative $0 still finds them.
case "$sub" in
  evidence|evidence-state|record|status)
    case "$0" in */*) self_dir="${0%/*}" ;; *) self_dir="." ;; esac
    guard_lib="$self_dir/../hooks/guard-lib.sh"
    # shellcheck source-path=SCRIPTDIR source=../hooks/guard-lib.sh
    . "$guard_lib" || die "cannot source $guard_lib"
    REQ_GATE="$(cd "$self_dir/../hooks" 2>/dev/null && pwd)/req-gate.sh"
    [ -r "$REQ_GATE" ] || die "cannot read the requirement gate ${self_dir}/../hooks/req-gate.sh"
    ;;
esac

repo_root

case "$sub" in
  init) cmd_init "$1" ;;
  stamp) cmd_stamp "$1" ;;
  stamp-state) cmd_stamp_state "$1" ;;
  evidence) cmd_evidence "$1" ;;
  evidence-state) cmd_evidence_state "$1" "${2:-WORKTREE}" ;;
  record) cmd_record "$1" "$2" "$3" "$4" ;;
  status) cmd_status ;;
esac
