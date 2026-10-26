# AI-Native SDLC — the framework's own project rules

This repo is the framework. It gates itself with the same two targets it asks of
every repo it installs into, and the commands it ships get run against it — three
unattended `/hunt` rounds on this repository, which is how the commit gate's
fail-open was found.

decision log: AGENTS.md
tracker:
protected paths: specs/_shipped/**, specs/_hunt/**

<!-- The three lines the global /rca reads.

     `tracker:` is deliberately EMPTY. This repo files nothing automatically:
     findings go to the `## FINDINGS` section of the hunt state file and into the
     verdict, which is the documented behaviour for a repo that declares no
     tracker. That is a choice, not an oversight — an unattended loop opening
     issues against the framework itself is noise nobody reads.

     `specs/_shipped/**` is protected because a shipped spec is the audit trail
     for a decision already made. It is superseded in place with a note, never
     edited to match what the code became. `specs/_hunt/**` is a running
     command's own state; a person repairs it, not a run. -->

## The rules this repo has paid for

- **A gate that cannot verify must never allow.** Exit 0 from a gate is an ALLOW
  and has to be earned. `[ -d dir ]` does not imply `cd dir` will succeed, and
  `[ -f file ]` does not imply the file can be read. Every guard that tests for
  presence and then acts as though the operation must succeed is the same bug;
  four of them shipped here before a live `/hunt` found the first.
- **The absence of a block is not evidence the checks passed.** The commit gate
  is a PreToolUse hook with a timeout, and a hook that times out does not block.
  Anything unattended runs `make check` itself and reads the exit code.
- **`make check` proving a file is valid JSON is not the harness accepting its
  schema.** Two different questions. A `"//"` comment inside a hook entry parses
  fine and may still cause the whole settings file to be rejected.
- **A requirement that overclaims is a test that will one day pass while the
  promise is broken.** Narrow the requirement to what is proven and record the
  rest as known, rather than leaving a sentence the tests do not support.
- **A test that greps for one spelling of a bug tests the spelling.** The next
  fail-open will not be spelled the same way. Prove a guard by mutating what it
  guards and watching the suite go red.
- **Scrub fence, easy to trip:** `commands/*.md`, `README.md`, `install.sh`,
  `scripts/*.sh`, `templates/**`, `settings/*.json` may contain no project name
  and no literal four-digit year. The escape `—` for an em dash contains
  "2014" — write literal em dashes, and never round-trip these files through a
  JSON dumper with `ensure_ascii` left on.
- **`ainative_sdlc.html` is outside that fence: its project cards are the
  owner's control panel.** The repository ships one example card and a checkout
  fills in its own. It still
  may not name a model as the fixed engine of a phase, nor carry a year: both
  are asserted by `tests/test_docs_roles.sh`, and the routing table there is
  written in roles that point at the two engine maps.
- **A prepared handoff is not a transfer.** The source's Stop gates yield only
  once the receiver has accepted; a package nobody accepted keeps them closed
  and never expires into an allow. A TTL was rejected: it would be a timed
  bypass, and ownership must not depend on a clock.
- **A receipt hashes what the installer owns, not the file it merged into.**
  `config.toml`, `hooks.json`, `AGENTS.md` and Claude agent files are shared
  with the owner and the clients themselves; the doctor checks their
  installer-owned fragment, so an owner edit or a client rewrite elsewhere in
  them is not drift.
- **One unreadable checkout may not hide the rest.** A broken `.git` is its own
  blocked row in the doctor's inventory, and one corrupt handoff package is a
  diagnosed row that blocks `prepare` by name until `retire <id>`; neither is
  a checkout-wide outage.
- **A hook that drops Git's selectors must prove the repository is still
  findable.** The pre-commit mirror clears them so fixture repositories cannot
  alter the committing one, then re-exports absolute selectors when the work
  tree no longer leads back; a gate that cannot find its repo must not run
  against nothing.
- **A PreToolUse hook blocks only on exit 2, and a gate decides on the state
  the command will produce, not the state it found.** Exit 1 from a sub-gate
  passed through is an allow; a missing sub-gate is a gate that cannot verify.
  The docs-only shortcut read the index before `git add code.py && git commit`
  had run, so it takes that shortcut only for a command it can prove commits
  the index as it stands — a whitelist, because a list of staging forms to
  refuse is one spelling short of the next bypass.

- **A mod routes and informs; it never gates.** A function hook past its
  budget is treated as absent and the action proceeds, the same fail-open as a
  timed-out shell hook, so the engine-map mod sets models and status lines and
  the commit, Stop and requirement gates stay shell hooks. Every mod hook
  carries a `.catch` that announces and passes the event on; a `.catch` is
  accepted only as an inline literal, so its logic lives in a pure function.
- **A fallback that retries a spawn starts a second subagent.** A spawn resolves
  as soon as the subagent starts and its model failure surfaces at the
  subagent's turn end, so the mod moves LATER dispatches of a role down the
  chain, by entry name kept in session state, and never retries the failing one.
- **A merge does not pass the commit gate.** Landing two green task branches
  produced a red feature branch once (one task's fixture lacked a file the
  other task's installer now requires). Run `make check` on the assembled
  branch after every landing, not only at the end.
- **A repo never carries its own engine map.** The map is machine-level and the
  one binding from role to model; a per-repo copy is the second binding the
  framework exists to prevent. Only the agents directory travels with a repo.
- **An unattended command stops itself.** `/hunt` runs its own rounds and writes
  `STOPPED: <reason>`; a harness scheduler is a convenience, never a dependency,
  because a fixed-interval loop cannot be stopped by the command it restarts.
- **Two enforcement designs, kept distinct.** Claude gates are shell hooks on
  Claude payloads; Codex gates are the independently tested Python guard on
  native payloads. Making either harness-neutral adds risk without capability.
  The Codex guard reads both zone-file styles (`.claude/.night-lock` with
  `.claude/hooks/no_fix_zones.txt`, and `.sdlc/night-lock` with
  `.sdlc/protected-paths.txt`), proven by live `codex exec` denial probes.
- **The stamp is the owner's act; evidence has one writer.** A feature's
  `specs/<feature>/state.json` carries the Gate 1 stamp: never run
  `sdlc-state.sh stamp` without the owner's explicit approval at Gate 1, and
  never edit the file by hand. `specs/<feature>/evidence.json` is written only
  by `sdlc-state.sh evidence` (and `record` for a verdict), never by hand. Three
  guards read them: `gate1-stamp` on a commit to `sdlc/*`, `evidence-merge` on
  a merge into the default branch, `stop-evidence` at Stop. Each warns for 14
  days from its clock in `~/.claude/sdlc-guards/`, then denies;
  `SDLC_GUARD_MODE=warn` keeps it warning. After a compaction the routing
  policy returns through the `SessionStart` entry with matcher `compact`
  (`compact-policy.sh`).
- **Freshness is an evidence tree, approval is a hash of the requirements.**
  `evidence.json` records the git tree with the two state files removed, so
  committing the evidence never stales it, a rebase that changes nothing keeps
  it, and any content change kills it. The Gate 1 stamp hashes
  `requirements.md` alone: design.md gains assumptions during a build and
  tasks.md gains ticks, and neither is what the owner approved.
- **A guard's clock is seeded at install and only an absent directory
  self-seeds (all three clocks at once).** Once the directory exists, a
  missing, edited or future `.since` denies; deleting a clock never restarts
  the grace window. Tests point `SDLC_GUARDS_DIR` at a throwaway directory,
  which exists and is empty, so inside the suite a guard denies unless the
  test seeds a clock or sets `SDLC_GUARD_MODE`.
- **The gate decides on the branch the command lands on, one repository per
  command.** A literal `checkout`/`switch` target is followed; a target it
  cannot read, a `cd` between its git commands, or a rebase/pull with an
  option outside the known list is a refusal under the guard's mode, never a
  guess. Redirections are not words. A warning from a PreToolUse hook is
  `additionalContext` only: a `permissionDecision` would approve the whole
  Bash call, including a stamp chained into it.
- **The Stop gate keeps its own block counter below the client's cap** (6
  under 8) so the UNVERIFIED line is actually seen; one exit trap resets it on
  any exit 0; `stop_hook_active` allows nothing by itself. An unwritable
  counter is treated as the cap reached, loudly.
- **A `tool.check` mod hook that throws without `.catch` is skipped and the
  tool runs (fail-open); with a `.catch` that answers deny, the tool is
  refused (fail-closed). The per-hook budget is 10 s and `$.clock.sleep`
  counts.** Probed on build 2.1.310 (re-probe record in the shipped spec);
  this is the fact phase 3 decides the gating question on.
- **A test that reads a feature's spec by its in-flight path goes red the day
  the spec is archived.** The commit gate runs `make check` alone, so the
  archive commit passed it and `make test` was red on `main` until the next
  review. A test that reads `specs/<feature>/` follows the feature into
  `specs/_shipped/`, and an archive commit runs `make test` before it lands.

## Two repositories: where a push goes

This framework lives in two repositories: a PRIVATE working repository
(`wlottermonster/ainative_sdlc`) with the full history and the private notes, and a
PUBLIC repository (`wlottermonster/ai_native_sdlc`) that receives only clean exports.
Which one `origin` points at decides which of the two paragraphs below applies.

**If you cloned the public repository** (`origin` is `wlottermonster/ai_native_sdlc`
or your fork): ordinary git. Branch, push to your fork, open a pull request.
`publish.sh` and `push.sh` are the maintainer's tools; they refuse to run against a
public origin.

**If this is the maintainer's checkout** (`origin` is the private working
repository): the owner's word "push" means BOTH repositories, in one command:
`./push.sh`. It (1) checks the remote and the pre-push guard, (2) pushes the current
branch to `origin` (the private repo, never force), (3) when the branch is `main`,
runs `./publish.sh --dry-run HEAD`, reads the sweep, then `./publish.sh HEAD`, which
exports the files of that commit, strips the private notes, sweeps every file against
the machine-local token list and refuses on any hit. From any other branch it pushes
privately and says plainly that nothing was published. A refusal from the sweep is a
finding to show the owner, never something to work around by editing the token list.
Never `git remote add` the public URL, never `git push <public-url>`. New private
names go into `~/.config/ainative-sdlc/scrub-tokens`, one per line.

The public repository is an export, not a mirror: `docs/` and the private ledgers are
private, and the working history carries workspace details that must not leave the
machine. So the public side receives the files of one commit at a time, committed on
top of its own history without force, and never the private history itself.

## Contract

`make check` — `bash -n` and `shellcheck -x` over every script, `jq` over the
hooks snippet, the requirement gate, then `adapters/codex/scripts/validate.py`
and the `tests/codex` unittest suite. `make test` — `tests/run.sh`, which runs
every `tests/test_*.sh`, then the `tests/codex` suite again. `TEST_PROFILE = lib`.

Nothing here is deployed. `git push` publishes the framework; it starts nothing.

