# Design

Shared Python standard-library CLI at core/doctor.py, installed under each
adapter's scripts directory with project.py and installation.py. Source wrapper
./doctor invokes it. No network update lookup or automatic repairs. Two concepts
remain separate: source/install parity and behavior/harness verification.

installation.py builds a schema_version 1 manifest. Keys: source (path, revision,
dirty, fingerprint), managed_files (absolute filename -> SHA256), source_files
(relative filename -> SHA256). Write doctor-installation.json in each runtime
root after successful installation; source doctor can inspect both roots via
--home. Doctor source fingerprint uses installation.source_snapshot(source).
Installation manifest hashes omit itself. Source snapshot includes core and both
adapters (excluding caches) plus install.sh, Makefile, doctor, generated sdlc-policy.md and alias link text; no private reports.

Project discovery prunes dependencies, hidden state and external symlinks;
nested normal repositories are discovered. Worktree inventory may be obtained
through Git metadata without mutating it. Real project contracts are inspected
using project.inspect(apply=False). Runtime version commands have short timeouts.

--verify explicitly executes make check and make test with process-group timeout,
no raw output persistence. Receipts live in an explicit central state directory;
inspection only reads it. Project fingerprint hashes Git tracked and untracked
nonignored files, modes, symlink text and HEAD; ignored source is outside evidence.
A changed fingerprint requires verification. Live harness trust cannot be inferred
from files: show unverified until a genuine live probe receipt exists.

Owner-specific profile/packager remains a separate release phase; this tool must
not grant generic push permission or change existing routing/trust.

Review refinements: compare fingerprints before/after checks and never cache a
mutating pass. Persist attempt-start before executing, then finish atomically.
Require supported nonempty manifests and expected installed bytes.
