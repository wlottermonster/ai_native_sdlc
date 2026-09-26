# Step 5 task ledger

1. Read approved plan, both source policies and capability inventory: done.
2. Record layout/preservation decisions and matrix before migration: done.
3. Add failing packaging/install/rollback tests, then migrate adapters/core: done.
4. Run retained shell suite, retained Python suite, portability tests and make check: done;
   make test exit 0, all 18 shell files and 27 Python tests pass.
   The approved plan says 19 shell suites; the baseline actually has 18.
   make check exit 0, final line check: OK.
5. Independent Claude source review: conditional PASS in 18210cd; requested command
   reverts and removal of the wording-only test applied in e230c8f. See response.
6. Live installation and settings backup: applied and verified; rollback exercised
   in disposable homes. Fresh Codex loading passed.
7. Fresh final review and source retirement: done under owner substitution R4.
   Independent Codex review passed; old workspace source moved to retained recovery
   storage. Claude discovery/startup succeeded; generated smoke remains quota-limited.

TDD evidence: initial six packaging tests failed before migration; separate
RED cases covered shipping authorization (later reverted by owner ruling), broken installed README links,
compatibility template scrub traversal and duplicate shared policy clauses.
Final stable logs: /private/tmp/step5-final-test.log and /private/tmp/step5-check.log.
No runtime code changed: the entire sdlc.py hash matches the original manifest.

Review note: core portable templates and the retained Claude template tree have
duplicate files today. This compatibility decision is explicit for independent
review; core policy duplication was removed via deterministic composition.

Root owns the remaining live validation and folder retirement. Exact current
evidence and recovery paths: docs/portability-step5/live-migration-result.md.
No live harness acceptance is inferred from unit test success.
