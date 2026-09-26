# Requirements — <feature name>

<!-- One requirement per line-block. Rules:
     - ID is permanent: REQ-<FEATURE>-NNN. Never renumber, never reuse.
     - EARS form: WHEN <trigger>, THE SYSTEM SHALL <behavior>. One testable claim per ID.
     - verify: is REQUIRED — one of: unit | integration | e2e | deferred.
       "deferred" shows amber in the matrix and skips Gate B until you change it.
     - Adding a requirement here later is safe: the gates recompute every run,
       so a new ID immediately shows as uncovered until it has a task and a test. -->

REQ-PWRESET-001  WHEN a user requests a password reset, THE SYSTEM SHALL
                 email a reset link valid for 30 minutes.
                 verify: integration

REQ-PWRESET-002  WHEN a reset link is used a second time, THE SYSTEM SHALL
                 reject the attempt with a clear error.
                 verify: integration

REQ-PWRESET-003  WHEN a user completes the reset form successfully, THE SYSTEM
                 SHALL show a confirmation screen and invalidate old sessions.
                 verify: e2e
