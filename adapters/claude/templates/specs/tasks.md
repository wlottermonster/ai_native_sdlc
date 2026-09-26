# Tasks — <feature name>

<!-- Rules:
     - Every task lists the REQ-IDs it implements (Gate A checks that every
       non-deferred ID in requirements.md appears in this file).
     - Checkbox states are the ONLY execution state (no separate reports):
       [ ] open   [~] claimed/in progress   [x] done   [!] parked
       A parked task carries an indented "> parked: <reason> (branch: ...)" line.
     - When ALL boxes are [x], the feature claims completion and Gate B
       enforces: every ID must have a passing tagged test.
     - Each implementer run gets ONE task (its 1-5 REQ-IDs), re-read fresh. -->

- [ ] T1: Reset-request endpoint + tokened email link            [REQ-PWRESET-001]
- [ ] T2: Single-use token enforcement                           [REQ-PWRESET-002]
- [ ] T3: Reset form flow, confirmation, session invalidation    [REQ-PWRESET-003]
