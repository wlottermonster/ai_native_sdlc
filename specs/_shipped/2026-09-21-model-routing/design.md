# Approved design and implementation plan

Use the existing Codex engines.toml as central source, adding reasoning and agent
role tables. Render native TOML definitions using the existing global agent
instructions where present and portable templates for fresh installations.
Add a routing helper shared with doctor; both installed doctors can inspect
Codex routing, without importing any Claude routing into Codex execution.
Preserve old owner maps during normal install; explicitly migrate this owner's
inherit-only map to the approved defaults with a backup. Do not change parent
session selection or imply that a map changes an already-running session.

Tasks: helper and red/green unit tests; installer and native templates with
integration tests; doctor drift checks; workflow/docs; full gates; live probe;
global install and encrypted backup. Existing doctor and loop edits are preserved.

Model catalog and access are host-dependent. Validate syntax locally and prove
selection from actual dispatch evidence where exposed. Never invent a static
list of all supported models or treat agent self-report as authoritative proof.
