> Historical pre-consolidation record, retained for provenance. Current source
> layout and policy are described by the repository README and ARCHITECTURE.md.

# Global OpenAI SDLC Implementation Plan

**Goal:** Install independent global OpenAI SDLC defaults for the workspace root.
**Architecture:** Versioned policy/skill plus Python 3.12 standard-library helpers;
transaction-aware installer with backups and narrow migration of imported config.
**Spec:** docs/design.md

## Constraints

No changes to Claude or shared skills. Preserve unrelated Codex preferences and
guardrails. No credentials or new paid services. Hook trust remains user-controlled.
Existing model selection is inherited. The empty destination is the isolated
workspace; no existing checkout or branch is modified.

## Tasks

- [x] Installer: first test fake-home migration, preservation and idempotence;
  implement scripts/install.py; run `python3.12 -m unittest discover -s tests`.
- [x] Loop and evidence: first test budget/failure limits and check exit codes;
  implement scripts/sdlc.py; rerun targeted tests.
- [x] Context hooks: first test scoped JSON and bounded Stop; implement hooks;
  test failures and out-of-scope directories.
- [x] Author policy and skill references from the approved design; validate
  frontmatter and forward-test realistic handoff/failure/release scenarios.
- [x] Run full checks; dry-run the actual migration; install with filesystem
  approval; inspect installed files, compare Claude hashes, run settings backup.
- [x] Document usage, rollback, and any host hook-review step still required.
