# Step 5 consolidation design

Approved authority: docs/portability-plan.md Step 5. No new feature scope.

Canonical harness assets live in adapters/claude and adapters/codex. Root legacy
paths remain compatibility links because consumers and the established shell
suite depend on them. The root installer retains the Claude install mechanism
and dispatches Codex explicitly; no-argument installation stays Claude-compatible.
Core policy and workflows are harness-neutral and included in installed policies.
Root sdlc-policy.md is a deterministic compatibility view generated from core
policy plus routing-only Claude policy. Its exact composition is tested; shared
clauses have one authored source, not two.
Existing Claude routing/frontmatter remains adapter-specific; Codex role maps
still inherit the actual selected host model. No cross-harness model claims.

The Codex runtime is ported verbatim, including atomic_json and locked. Installed
paths and project .sdlc-openai/runs remain unchanged. installation.json source
changes to this repository. Hook recognition and payload semantics are Step 6.
The existing 240s gate is retained here; it is not a claim that every project can
finish within it. Explicit runtime checks support --timeout for longer checks;
Measured reference: the integrated sample project check takes about 24 seconds
locally and about 90 seconds in CI; the 240-second limit fits that sample only.
Step 6 must choose the host and per-project gate timeout together from measured
project runs, never merely raise one side of the host/runtime timeout pair.

Installer tests use disposable homes. Claude settings remain a manual merge;
Codex preserves unrelated hooks/config and disabled import-sync, without trust
hash changes. Rollback uses the existing Codex backup manifest and is exercised
by restoring pre-install files and removing only newly installed files. Root
coordinates live validation, backups and folder retirement after Claude review.

## Assumptions and compatibility

Rulesync is not required. No dependency changes. No install writes live settings
from this implementation task. Root compatibility links require fixture builders
to dereference assets, not copy dangling links. This is a packaging adjustment,
not a relaxation of behavioral assertions. Backup staging uses installation.json
source rather than assuming an installed script lives in its source checkout.

Push-gate harmonization is deferred per the owner's split ruling. Claude commands
and its explicit-yes gate retain their baseline wording; Codex's existing machine
authorization stays in the Codex adapter. Shared release checks do not grant new
authorization. Current owner/host instructions still take precedence.
Claude-specific role fallback stays Claude; Codex never imports it.
CLI command prompts remain Claude adapters, with feature,
build, verify/audit, debug/RCA, ship/operate and handoff workflows discoverable
through the Codex skill rather than pretending slash-command parity.
