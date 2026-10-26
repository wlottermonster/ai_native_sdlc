#!/bin/bash
# AI-Native SDLC — Gate B per requirement (specs/three-touch-points-phase-1).
#
#   REQ-TOUCH-025  an ID cited by at least one checkbox line of tasks.md, every
#                  one of them [x], needs a tagged test even while other tasks
#                  are open, claimed or parked. A checkbox line includes its
#                  indented continuation lines.
#   REQ-TOUCH-026  an ID cited by no checkbox line is labelled UNTASKED, and
#                  Gate B applies to it only when tasks.md has no [ ], [~] or
#                  [!] box at all.
#   REQ-TOUCH-027  an ID cited by a [!] line is labelled PARKED and never blocks.
#
# Each case builds a throwaway git repository holding a copy of this checkout's
# hooks/req-gate.sh, runs it in enforce mode (exit code) and with --report
# (labels). The demo REQ-IDs are assembled at run time so no literal foreign ID
# sits in this file (the gate's orphan check scans test files). Every fixture
# lives under a mktemp -d directory removed on exit.
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

tmproot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-perreq.XXXXXX")
tmproot=$(cd "$tmproot" && pwd)
# shellcheck disable=SC2329  # invoked indirectly by the trap below
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

demo_feat=PERREQ
ida="REQ-${demo_feat}-001"
idb="REQ-${demo_feat}-002"
idc="REQ-${demo_feat}-003"
idd="REQ-${demo_feat}-004"
ide="REQ-${demo_feat}-005"
idorphan="REQ-${demo_feat}-099"

# mkfix <tasks.md body> — a fresh repository with the gate, a requirements.md
# defining A, B, C and a deferred D, and the given tasks.md. Echoes its path.
mkfix() {
  local d
  d=$(mktemp -d "$tmproot/fix.XXXXXX")
  mkdir -p "$d/hooks" "$d/specs/demo" "$d/tests"
  cp "$TEST_REPO/hooks/req-gate.sh" "$d/hooks/req-gate.sh"
  git -C "$d" init -q
  git -C "$d" config user.name "SDLC Test"
  git -C "$d" config user.email "sdlc-test@example.invalid"
  {
    printf '# demo — requirements\n\n'
    printf '%s  WHEN a, THE SYSTEM SHALL a.\n      verify: unit\n\n' "$ida"
    printf '%s  WHEN b, THE SYSTEM SHALL b.\n      verify: unit\n\n' "$idb"
    printf '%s  WHEN c, THE SYSTEM SHALL c.\n      verify: unit\n\n' "$idc"
    printf '%s  WHEN d, THE SYSTEM SHALL d.\n      verify: deferred\n' "$idd"
  } > "$d/specs/demo/requirements.md"
  printf '%s' "$1" > "$d/specs/demo/tasks.md"
  printf '%s' "$d"
}

# tag <fixture> <id> — add a test file that cites <id>.
tag() { printf '#!/bin/bash\n# covers %s\n' "$2" > "$1/tests/test_$2.sh"; }

# gate <fixture> [args] — run the fixture's own gate from inside the fixture.
# shellcheck disable=SC2329  # invoked through capture
gate() { local d="$1"; shift; (cd "$d" && bash hooks/req-gate.sh "$@"); }

# ---------------------------------------------------------------------------
req "REQ-TOUCH-025"
# A is cited only by a [x] line while T2 is still open: A is claimed on its
# own, so a missing tagged test blocks even though the file as a whole does
# not claim completion.
tasks025=$(printf '# demo — tasks\n\n- [x] T1: build a    [%s]\n- [ ] T2: build b and c    [%s, %s]\n' \
  "$ida" "$idb" "$idc")
d=$(mkfix "$tasks025")
out="$d/enforce.out"
capture "$out" gate "$d"
assert_rc 2 "$out"
assert_fgrep "GATE B: demo claims $ida complete but it has no tagged test" "$out"
assert_no_grep "$idb" "$out"
# With a test citing A the same tree passes, and the report says OK for A and
# OPEN for the IDs whose task is still open.
tag "$d" "$ida"
out="$d/enforce2.out"
capture "$out" gate "$d"
assert_rc 0 "$out"
out="$d/report.out"
capture "$out" gate "$d" --report
assert_rc 0 "$out"
assert_fgrep "demo $ida OK" "$out"
assert_fgrep "demo $idb OPEN" "$out"
assert_fgrep "demo $idc OPEN" "$out"

# Every citing line must be [x]: A on one [x] and one [ ] line is still open.
d=$(mkfix "$(printf '# demo — tasks\n\n- [x] T1: a part one    [%s]\n- [~] T2: a part two    [%s]\n- [ ] T3: b c    [%s, %s]\n' \
  "$ida" "$ida" "$idb" "$idc")")
out="$d/mixed.out"
capture "$out" gate "$d"
assert_rc 0 "$out"
out="$d/mixed-report.out"
capture "$out" gate "$d" --report
assert_fgrep "demo $ida OPEN" "$out"

# A checkbox line includes its indented continuation lines: A appears only on
# the continuation line under the [x] box, and is claimed by it.
d=$(mkfix "$(printf '# demo — tasks\n\n- [x] T1: build a\n      covers [%s]\n- [ ] T2: build b and c    [%s, %s]\n' \
  "$ida" "$idb" "$idc")")
out="$d/cont.out"
capture "$out" gate "$d"
assert_rc 2 "$out"
assert_fgrep "GATE B: demo claims $ida complete but it has no tagged test" "$out"

# Mutation: replace the per-requirement classification with the old file-level
# rule (every ID treated as cited by no checkbox line, so Gate B waits for the
# whole file to close). The first 025 case must then wrongly pass — proof that
# the assertions above follow the behaviour, not a spelling.
d=$(mkfix "$tasks025")
cp "$d/hooks/req-gate.sh" "$d/orig.sh"
sed -E 's/^([[:space:]]*)cls=[$][(].*$/\1cls=UNTASKED/' "$d/orig.sh" > "$d/hooks/req-gate.sh"
if cmp -s "$d/orig.sh" "$d/hooks/req-gate.sh"; then
  _test_fail "mutation did not apply: no 'cls=' assignment in hooks/req-gate.sh"
else
  _test_pass "mutation applied: per-requirement classification replaced by the file-level rule"
fi
out="$d/mutant.out"
capture "$out" gate "$d"
assert_rc 0 "$out"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-026"
# B is cited in tasks.md in prose only (an unindented line after a checkbox
# line is not its continuation). With a box still open, B is UNTASKED and does
# not block although no test cites it.
tasks026_open=$(printf '# demo — tasks\n\n- [x] T1: build a c    [%s, %s]\nNote: %s is covered by the T1 work.\n- [ ] T2: polish\n' \
  "$ida" "$idc" "$idb")
d=$(mkfix "$tasks026_open")
tag "$d" "$ida"; tag "$d" "$idc"
out="$d/open.out"
capture "$out" gate "$d"
assert_rc 0 "$out"
out="$d/open-report.out"
capture "$out" gate "$d" --report
assert_fgrep "demo $idb UNTASKED" "$out"
assert_no_grep "demo $idb OK" "$out"
# With every box [x], the old file-level rule claims B: no test blocks...
d=$(mkfix "$(printf '# demo — tasks\n\n- [x] T1: build a c    [%s, %s]\nNote: %s is covered by the T1 work.\n- [x] T2: polish\n' \
  "$ida" "$idc" "$idb")")
tag "$d" "$ida"; tag "$d" "$idc"
out="$d/closed.out"
capture "$out" gate "$d"
assert_rc 2 "$out"
assert_fgrep "GATE B" "$out"
assert_fgrep "$idb" "$out"
assert_no_grep "GATE B.*$ida" "$out"
# ...and a tagged test makes it OK.
tag "$d" "$idb"
out="$d/closed2.out"
capture "$out" gate "$d"
assert_rc 0 "$out"
out="$d/closed-report.out"
capture "$out" gate "$d" --report
assert_fgrep "demo $idb OK" "$out"
# Parked boxes keep the file open too: [!] alone is enough to leave B untasked.
d=$(mkfix "$(printf '# demo — tasks\n\n- [x] T1: build a c    [%s, %s]\nNote: %s.\n- [!] T2: parked polish\n' \
  "$ida" "$idc" "$idb")")
tag "$d" "$ida"; tag "$d" "$idc"
out="$d/parkedfile.out"
capture "$out" gate "$d"
assert_rc 0 "$out"

# ---------------------------------------------------------------------------
req "REQ-TOUCH-027"
# C cited only by a [!] line: PARKED, and never blocking, with no test.
d=$(mkfix "$(printf '# demo — tasks\n\n- [x] T1: build a b    [%s, %s]\n- [!] T2: build c    [%s]\n' \
  "$ida" "$idb" "$idc")")
tag "$d" "$ida"; tag "$d" "$idb"
out="$d/parked.out"
capture "$out" gate "$d"
assert_rc 0 "$out"
out="$d/parked-report.out"
capture "$out" gate "$d" --report
assert_fgrep "demo $idc PARKED" "$out"
# C cited by a [!] line AND a [x] line: still PARKED, still not blocking.
d=$(mkfix "$(printf '# demo — tasks\n\n- [x] T1: build a b c    [%s, %s, %s]\n- [!] T2: finish c    [%s]\n' \
  "$ida" "$idb" "$idc" "$idc")")
tag "$d" "$ida"; tag "$d" "$idb"
out="$d/parked2.out"
capture "$out" gate "$d"
assert_rc 0 "$out"
out="$d/parked2-report.out"
capture "$out" gate "$d" --report
assert_fgrep "demo $idc PARKED" "$out"
assert_no_grep "demo $idc OK" "$out"

# ---------------------------------------------------------------------------
# The behaviours the gate already had still hold in the same fixture shape:
# DEFERRED in the report, Gate A on a missing task, ORPHAN for a test ID no
# spec defines.
req "REQ-TOUCH-025"
d=$(mkfix "$tasks025")
tag "$d" "$ida"
tag "$d" "$idorphan"
out="$d/legacy-report.out"
capture "$out" gate "$d" --report
assert_rc 0 "$out"
assert_fgrep "demo $idd DEFERRED" "$out"
assert_fgrep "ORPHAN $idorphan" "$out"
printf '%s  WHEN e, THE SYSTEM SHALL e.\n      verify: unit\n' "$ide" >> "$d/specs/demo/requirements.md"
out="$d/gatea.out"
capture "$out" gate "$d"
assert_rc 2 "$out"
assert_fgrep "GATE A: $ide" "$out"

finish
