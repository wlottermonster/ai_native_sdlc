---
description: Run the bug-to-rule flywheel on a bug — fix, regression test, a rule, a sibling sweep, so the class is gone
---
Root-cause the bug referenced by $ARGUMENTS: an issue number, a failing test
path, or a one-line description of the symptom. A bug fixed without a rule and
a sweep is a bug half-fixed — the goal is not "the bug is gone", it is "the
CLASS is gone". Work the seven steps in order.

## What the repo declares
Three OPTIONAL one-line entries in the repo's CLAUDE.md steer this command; any
that is missing simply drops out, and nothing here is invented if it is absent:
- `decision log: <path>` — a directory or file where standing rules are kept;
- `tracker: <command prefix>` — the CLI this repo files issues through;
- `protected paths: <globs>` — paths this command may report on but never edit.

`.claude/hooks/no_fix_zones.txt`, if the repo has one, is read as protected
paths too, on top of anything CLAUDE.md declares.

## 1. Reproduce
Reproduce the bug in the CURRENT code before touching anything — a report can
be stale, already fixed, or describe a different mechanism than it names. Run
the failing test, the failing command, or the smallest script that shows the
symptom, and keep its output. If the bug is not reproducible here, the run ends
at this step: report the evidence (what was run, what happened instead) and
fix nothing. Never "fix" a symptom you have not seen.

## 2. Root cause
Find the actual mechanism, not the symptom — think harder here; a shallow root
cause is how a class relands a month later. State the mechanism in one or two
sentences a reviewer could disagree with, then name the CLASS the bug belongs
to (every place this same mechanism could bite, not just this call site). Then
ask WHY it existed: a missing rule, a rule that existed and failed, an untested
seam, prose that drifted from the code? The answer to that question is what
step 4 has to close.

## 3. Fix test-first
TDD, always: the failing regression test comes FIRST and pins the exact
mechanism from step 2, not the surface symptom. Watch it fail for the right
reason, then write the smallest fix that makes it pass.
Tag the failing regression test with the bug reference from $ARGUMENTS — a
marker, the test name, or the docstring — so the bug-to-test link is grep-able
forever by someone who only has the bug reference in hand.

## 4. Rule
Add the smallest guard that makes the class impossible, or at least loudly
visible. Prefer, in this order:
1. **a test that sweeps the whole class** — it re-finds every future instance
   automatically, including the ones nobody thought of;
2. **a code-level seam or predicate** that removes the footgun, so the wrong
   thing can no longer be expressed;
3. **prose** — a written rule where the repo keeps its standing instructions.

Choosing prose REQUIRES saying, in the evidence summary,
why the first two were impossible for this class — prose is memory, a test is
a fence. A prose rule is written into the repo's
declared decision log if one exists, otherwise into the repo's CLAUDE.md — one
place per repo, so the next reader has one place to look.
And if step 2 found a rule that already existed but failed, then
the rule was the bug: tighten that rule and say so, rather than adding a
second rule beside it.

## 5. Sibling sweep
Search the WHOLE repo for siblings of the class — the sweep beats reading, and
it is the step that turns one fix into a class extinction. Use whichever finds
the shape: a structural search (`ast-grep` or the language's own tooling), a
textual `grep` for the pattern, or a probe test that fails on every instance.
Report what was searched and how many siblings were found. Fix them in the same
lane, each with the same regression pinning as step 3 — except that a sibling
found inside a protected path is REPORTED in the evidence summary and
never edited, however small the fix looks. There the report IS the deliverable:
name the file and the mechanism, and leave the change to its owner.

## 6. Gate
`make check` green before the lane merges (fallback: the repo's own lint + test
commands). Run it yourself, never piped through anything that can swallow the
exit code, and never merge a lane whose gate is red or whose fix is unproven.

## 7. Evidence summary
Close with six parts, in plain words:
- **fix:** what changed and where;
- **test:** the regression test and how it is tagged;
- **rule:** what now prevents the class, which of the three forms it took, and
  where it lives (plus the required reason, if it is prose);
- **sweep:** what was searched, how many siblings found and fixed;
- **gates:** what was run and the result;
- **how to verify:** the one thing a human can do to see it for themselves.

If no tracker is declared, that summary is delivered in chat and that is the
whole delivery: no tracker CLI is invoked, and none is guessed at. If a tracker
IS declared, file the same summary through it as well, and give the reference
back in chat.
