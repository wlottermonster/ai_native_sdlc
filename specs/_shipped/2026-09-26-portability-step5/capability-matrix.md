# Capability preservation matrix (before migration)

Baseline: docs/portability-step3-inventory.md and original source manifest in
../../docs/portability-step5/source-manifest.json. No runtime capability retired.

| Capability | Decision | Destination / proof |
|---|---|---|
| Claude feature command | keep verbatim | adapters/claude/commands/feature.md; established routing tests; baseline byte comparison |
| Claude spec command | keep | adapters/claude/commands/spec.md; test_routing.sh |
| Claude build command | keep | adapters/claude/commands/build.md; test_hunt.sh build boundary assertions |
| Claude ship command | keep verbatim | adapters/claude/commands/ship.md; test_scrub.sh and baseline byte comparison |
| Claude hunt command | keep | adapters/claude/commands/hunt.md; test_hunt.sh; not falsely exported as a Codex command |
| Claude RCA command | keep | adapters/claude/commands/rca.md; test_rca.sh |
| Claude test-audit command | keep | adapters/claude/commands/test-audit.md; test_audit_cmd.sh and test_auditor.sh; Codex retains its original generic audit workflow |
| Claude seven agents, roles/frontmatter | keep | adapters/claude/agents; test_engines.sh, test_apply_engines.sh |
| Claude shell hooks and wiring | keep | adapters/claude/hooks, settings; test_gate_hardening.sh, test_session_hook.sh; semantics Step 6 |
| Claude install/shadow reporting | keep | root dispatcher, adapter assets; test_install.sh, test_shadow.sh |
| Claude engine-map owner choices | keep | seed-only engine map; test_install.sh |
| Requirement/trace gates, audit/hunt/RCA | keep | adapter scripts/commands; existing shell suites |
| Codex atomic_json | keep verbatim | adapters/codex/scripts/sdlc.py; original source hash/AST comparison in portability suite |
| Codex locked | keep verbatim | same; original source hash/AST comparison, no new guarantee claimed |
| state_path/read_state/begin | keep | test_path_traversal_and_duplicate_runs_rejected, test_repeated_failures_stop_and_survive_reload |
| record attempt budget/repeated failure | keep | test_budget_and_completion_requires_passing_evidence, test_repeated_failures_stop_and_survive_reload |
| run_command/check bounded execution | keep | test_failed_and_timed_out_checks_cannot_complete |
| fingerprint/stale completion | keep | test_completion_rejects_stale_evidence, test_failure_invalidates_preceding_pass |
| in_scope resolved workspace boundaries | keep | test_scope_and_hook_output |
| PreToolUse check enforcement | keep | test_commit_gate_rejects_failed_and_missing_checks; Step 6 reconciles recognition/timeout |
| SessionStart injection | keep | test_scope_and_hook_output |
| PostCompact schema | keep | test_post_compact_uses_only_codex_common_output_fields |
| Stop bounded continuation/schema | keep | test_stop_active_run_requests_one_continuation_then_yields |
| Codex CLI begin/status/record/check/hook | keep | installed CLI smoke and original runtime tests |
| Codex installer safety and idempotence | keep | all seven original InstallTests |
| Discoverable and packaged Codex skill | keep | test_codex_install_and_reinstall_preserve_state |
| Codex workflow references | keep | core workflow; adapter skill packaging; validator |
| Project templates | keep | core neutral templates and adapter compatibility assets |
| Codex backup staging | replace source discovery and repeat-refresh mechanism | test_backup_source_uses_installation_metadata_and_refreshes; complete-stage rename retains prior snapshots |
| installation.json old source pointer | replace | canonical repo source; test_codex_install_and_reinstall_preserve_state |
| Existing run state | keep untouched | test_codex_install_and_reinstall_preserve_state |
| Rollback manifest/backups | keep | test_codex_rollback_restores_previous_files; Claude snapshot restore: test_claude_snapshot_rollback |
| Old standalone folder | retire last | root integration after review, live install validation and rollback |
| Python caches / Finder metadata | retire | excluded from migrated assets |

## Clause-by-clause policy reconciliation

| Original clause group | Decision / authority |
|---|---|
| Claude lifecycle/phase-role table | keep in adapter; neutral lifecycle in core |
| Claude bulk delegation thresholds | keep as adapter guidance subject to host permission and scoped ownership |
| Claude fallback chain/owner override/escalate | keep adapter-only; actual host model limits always apply |
| Claude plan and ship gates | keep original adapter wording; global policy harmonization deferred by owner |
| Claude owner-testing batches/cosmetic vs behavior/refresh | keep in core |
| Claude decision protocol/options/one question/assumptions | keep in core; host tools chosen by adapter |
| Codex workspace scope and instruction precedence | keep core; workspace metadata + in_scope mechanism retained |
| Codex proportionate process and approved plans | keep core |
| Codex context artifacts/untrusted input/no secrets/handoff | keep core |
| Codex bounded loops/three failures/attempt budget/timeouts | keep core and runtime |
| Codex no model launching/token-dollar enforcement claims | keep core |
| Codex roles/inherit/independent review/separate worktrees | keep core; routing implementation stays adapter |
| Codex connected tools/progressive skills/no invented access | keep core; product-specific tool references stay adapter |
| Codex evidence/TDD/current files/changed-source second run | keep core |
| Codex hook convenience vs CI and explicit checks | keep core; no security-boundary claim |
| Codex release authorization/no force-push/deploy reporting | keep authorization in Codex adapter; shared release checks in core; no new Claude authorization policy |
| Codex backup/import isolation/trust review | keep adapter installer and docs |
