# AI-Native SDLC

A way of working with an AI that writes software, so that you stay in charge of what
gets built and the AI does the careful, repetitive part. SDLC stands for
**Software Development Life Cycle**: the steps every change goes through, from idea to
plan to code to testing to release.

It works with two AI coding assistants: [Claude Code](https://claude.com/claude-code)
from Anthropic and Codex from OpenAI. Both run in a terminal window, read your project's
files and edit code when you ask them to. On their own they are fast but too eager: they
report success they have not checked. This framework adds checks that run automatically
inside the AI tool, and it stops at two points where a person decides. The checks are
strong guard-rails, not a security boundary: someone determined can switch them off.

**Who it is for:** anyone who wants to get software built with an AI and keep control of
it, whether you write code yourself or not; for example a founder, a product owner, a
team lead, or a developer who wants the AI to do the routine work safely.

**What changes in your day.** Morning: describe the feature, approve a one-page plan. The
AI builds and checks while you do other work. Afternoon: try the result like a customer,
send your notes in one batch, say ship when you are happy.
Most of what is in between runs on its own and is graded on **artifacts**: judged on
proof you can see (test results, exit codes, the exact changes), never on the AI saying done.

`ainative_sdlc.html` is the manual for this workflow, written for both non-technical and
technical readers (English / 繁體中文). Open it in any browser. `ARCHITECTURE.md`
explains each layer and points at the code that implements it, in reading order.

## Why

Coding agents are good at producing plausible work and bad at knowing when it is wrong.
Left alone they report success, skip the slow tests, and commit on a red build. This
framework does not ask them to behave; it makes the harness refuse:

- **A commit is blocked while the repo's checks fail,
  once the hooks are installed and enabled.** A hook runs the project's checks before
  every commit the AI makes and refuses the commit if any check fails.
- **A session cannot end on a red build.** A stop hook runs the same checks.
- **Every requirement needs a task and a test.** Requirement IDs (`REQ-...`) are written
  in the spec, referenced by tasks, and tagged in tests; every requirement must have a
  task, and the gate refuses to call a feature finished while any requirement has no test.
- **A gate that cannot verify must never allow.** A check that times out or cannot find
  its repository refuses the commit instead of silently passing.

Around those checks sit a few typed commands (`/spec`, `/build`, `/ship` and friends)
that walk a change from idea to release; each is explained below. The design rules the framework has
learned the hard way are recorded in `CLAUDE.md`.

## Your first hour (a training walk-through)

Do these in order on your own computer; each step says what you should see. Words in
**bold** are explained under "Words used here" near the end.

1. **Check what you need.** Claude Code installed and signed in (`claude` opens it);
   on a Mac with Homebrew (brew.sh) installed, run `brew install jq shellcheck python@3.12`;
   git configured
   (`git config --global user.name "Your Name"` and `user.email`).
   *You will see:* `claude --version`, `jq --version` and `python3.12 --version` all answer.
2. **Get the framework and let it check itself.**
   `git clone https://github.com/wlottermonster/ai_native_sdlc.git && cd ai_native_sdlc && make check`
   *You will see:* a stream of checks ending in `check: OK`.
3. **Install it.** `bash install.sh --harness claude`
   *You will see:* files copied into `~/.claude/`, then `Done.` and a short list of manual steps.
4. **Switch the hooks on.** `~/.claude/scripts/merge-settings.sh > ~/.claude/settings.json.new`;
   open the new file and check your old settings are still there and it is not empty before
   the move, then `test -s ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json`.
   *You will see:* your existing settings, plus the framework's **hooks** added beside them.
5. **Point Claude at the policy.** Add one line to `~/.claude/CLAUDE.md`:
   `Follow the AI-Native SDLC policy in ~/.claude/sdlc-policy.md.`
   *You will see:* nothing yet; the next session reads it.
6. **Restart Claude Code and type `/hooks`.**
   *You will see:* the commit gate, the stop checks and the session hook in the list.
7. **Run the health check.** From the framework folder: `./doctor`
   *You will see:* `Framework doctor: unhealthy`, a `claude` row saying `installation current`,
   and `codex: installation blocked` and `Codex routing: blocked`; it exits 1. That is
   expected with Claude only: the Codex rows are blocked because Codex is not installed.
8. **Make a practice project.** `cp -R examples/todo-cli ~/todo-practice && cd ~/todo-practice && git init`
   (`git init` prints a hint about the default branch name; it is harmless), then
   `python3.12 ~/.claude/scripts/project.py --repo ~/todo-practice --apply`. Go back to the
   framework folder (`cd ~/ai_native_sdlc`) and run `./doctor --project ~/todo-practice --verify`.
   *You will see:* the project row says `setup ready; checks passed` (the Codex rows stay
   blocked, as in step 7).
9. **Watch a gate refuse.** Open Claude Code in `~/todo-practice`, ask it to "change
   todo.py so that the list command prints nothing", and then to commit.
   *You will see:* `COMMIT BLOCKED` with the failing test named
   (`test_list_command_prints_every_todo`). Ask it to undo the change;
   the next commit goes through. That refusal is the whole point.
10. **Plan a feature (Gate 1).** Type `/spec add a due date to todos`.
    *You will see:* a short decision digest with the requirements, each with a REQ-ID.
    Read it; answer its questions; approve it or ask for changes. Nothing is built before this.
11. **Let it build.** Type `/build`.
    *You will see:* it write tests first, build in a **worktree**, run a **verifier**, and
    report with evidence (test output), not a claim.
12. **Try it yourself.** `python3.12 todo.py add "pay rent" --due friday`, then
    `python3.12 todo.py list` (use whatever form the plan agreed). Write down everything
    that feels wrong, then send it as one batch in a single message.
    *You will see:* one round of fixes for the whole batch, not a drip of small ones.
13. **Ship it (Gate 2).** Type `/ship`.
    *You will see:* a **ship digest** computed from the real diff and tests, and a question
    per branch. Nothing ships until you say yes.
14. **Wrap-up.** Three more commands for later: `/rca <bug>` turns one bug into a fix, a
    test and a rule; `/hunt` looks for bugs on its own and stops itself; `/test-audit`
    judges whether the tests are any good. What is NOT guaranteed: hooks run on your
    machine and anyone can bypass them (`git commit --no-verify`, a disabled hook), so
    copy `templates/ci-check.yml` into `.github/workflows/` so GitHub re-runs the checks on
    every push (**CI** means automatic checks on the server); that is the backstop.

## How it works

1. **`/spec <idea>`** writes `requirements.md` (EARS-style, each requirement with an ID),
   `design.md` and `tasks.md` under `specs/<feature>/`, has them attacked by a reviewer
   agent, and presents a short decision digest. **Gate 1: you approve the plan.**
2. **`/build`** implements the approved tasks test-first in a git worktree, tagging tests
   with their requirement IDs. A verifier agent with no memory of the build checks the
   result against the spec.
3. **`/ship`** computes a digest from ground truth (diff, tests, coverage of requirements)
   and walks the ship decisions one branch at a time. **Gate 2: one explicit yes per
   branch.** Where a repo says push equals deploy, that yes is the deploy.
4. **`/hunt`** runs unattended: sweeps a repo for bugs, reproduces each finding, fixes what
   it can prove, files the rest, and stops itself with a named reason.
5. **`/rca <bug>`** turns one known bug into a fix, a regression test, a rule, and a sweep
   for siblings, so the class is gone rather than the instance.

`/feature <idea>` runs steps 1 to 3 for one ask. `/test-audit` judges the test suite itself.

### Roles, not models

Agents are bound to **roles**, never to models. There are five roles: four working roles,
`judge` (the main session's own reasoning), `build` (the implementer), `verify` (reviewers
and auditors) and `read` (bulk reading), plus the `escalate` lever (pulled by name, never
an automatic route). One machine-level file, the engine map, binds each role to a model
with an ordered fallback chain. Change the map and every agent follows;
no one edits a model name by hand: the map writes each agent's model line. And
with the engine-map mod loaded, a map change applies at the next dispatch for a
role-bound subagent dispatched without a model of its own, with no re-run of the
apply step.

### Two harnesses, one policy

`core/` holds the harness-neutral policy, workflows and templates. `adapters/claude/`
holds the native Claude Code commands, agents, hooks and settings. `adapters/codex/` holds
the Codex skills and a durable Python runtime that gives Codex the same gates. The
root-level `agents/`, `commands/`, `hooks/`, `scripts/`, `settings/` and `templates/` are
compatibility links into the Claude adapter, not copies.

A task can move between the two mid-flight: `/handoff codex` from Claude Code (or
`$handoff claude` from Codex) prepares a compact briefing, the receiver accepts it in its
own session, and `/handback` returns decisions and results to the exact source
conversation. Ownership transfers only on acceptance; a prepared package nobody accepted
keeps the sender's gates closed.

## Install

Requirements: bash, `jq`, `shellcheck`, `python3.12`, git. Claude Code and/or Codex.

```sh
git clone https://github.com/wlottermonster/ai_native_sdlc.git
cd ai_native_sdlc
make check && make test          # the framework gates itself first

bash install.sh --harness claude                                          # into ~/.claude
bash install.sh --harness codex --workspace /path/to/your/workspace          # dry run
bash install.sh --harness codex --workspace /path/to/your/workspace --apply
```

The installer is idempotent and never edits `settings.json`. For Claude Code, register the
hooks (the commit gate, the stop gate, the requirement gates and the session hook) with
the merge helper, which prints the merged settings and writes nothing:

```sh
~/.claude/scripts/merge-settings.sh > ~/.claude/settings.json.new   # then read it
mv ~/.claude/settings.json.new ~/.claude/settings.json
```

Your existing entries survive the merge; each framework hook is added once, so running it
again changes nothing. Then add one line to `~/.claude/CLAUDE.md` pointing at the policy,
for example `Follow the AI-Native SDLC policy in ~/.claude/sdlc-policy.md.`, and restart
the client. For Codex, open `/hooks` in Codex and trust the new hooks; untrusted hooks are
skipped. The engine map `~/.claude/sdlc-engines.conf` is created from
`templates/sdlc-engines.conf` on first install and never overwritten afterwards.

### Enrol a repository

Every repo supplies one contract: a `Makefile` with `check` (fast: syntax, lint, types)
and `test` (everything), plus one `TEST_PROFILE` line. Start from `templates/Makefile.python`,
`Makefile.node` or `Makefile.static`, then let the framework add the entry points:

```sh
python3.12 ~/.claude/scripts/project.py --repo /path/to/repo --apply
./doctor --project /path/to/repo --verify
```

Run one real feature through `/feature` end to end. That is the proof that the gates block
before you rely on them.

### Check the installation

```sh
./doctor                          # installed files, routing, dependencies
./doctor --workspace /path/to/your/workspace   # every enrolled repo's contract and receipts
./doctor --json                   # machine-readable
```

Doctor is read-only. A non-zero exit means something needs attention; the installation,
project and verification rows say what. A passing `make` proves the recipe, not that the
client has loaded or trusted a hook; live hook behaviour is reported separately.

## Layout

    ainative_sdlc.html      the manual (open in any browser). Written for a
                            non-technical reader and organised around day-to-day
                            use, with a clickable per-project section listing the
                            `/` commands each repo adds. It is the ONE page — no
                            per-repo copies. The project cards are an owner's
                            control panel: the repository ships one example card,
                            so the page sits outside the scrub fence that keeps the
                            rest of the framework portable; it still names no model.
    sdlc-policy.md          routing policy: phase → role; re-injected after every compaction
                            (generated from core/policy.md plus the Claude routing;
                            see "Development")
    Makefile                the framework gates itself: make check / make test
                            (TEST_PROFILE = lib — the same contract it asks repos for)
    tests/                  bash test harness; run.sh executes every tests/test_*.sh;
                            tests/codex/ holds the Python runtime tests
    core/                   harness-neutral policy, workflows, templates and the Python
                            doctor / handoff / project runtimes
    adapters/claude/        the Claude Code adapter (the root links below point here)
      skills/sdlc-engine-map/ the engine-map mod: function hooks that read the engine map at
                              each subagent dispatch and show it on the status line;
                              routing, not enforcement, so it never blocks
    adapters/codex/         the Codex adapter: skills, agents, engines and runtime
    agents/                 job descriptions, one per AI worker (each bound to a role, never
                            to a model — `roles.conf` says which role, the engine map says
                            which model fills it)
      implementer.md          build  — builds test-first in a worktree, tags tests with REQ-IDs
      spec-reviewer.md        verify — attacks plan + requirement coverage before code exists
      verifier.md             verify — independent fresh-eyes verification
      evidence.md             verify — debugging evidence, facts only
      researcher.md           read   — bulk reading, returns digests
      ui-tester.md            verify — agentic browser walkthrough of EARS scenarios (informs, never gates)
      test-auditor.md         verify — read-only audit of the test suite itself: the four lanes
      roles.conf              the manifest: every shipped agent → exactly one role
                              (`judge` belongs to the main session, so no agent carries it)
    hooks/                  the enforcement layer (mechanical, not advisory; it runs
                            inside the client; not a security boundary)
      check-gate.sh           blocks `git commit` while checks fail — and enforces its own
                              deadline, so a check that outruns the hook timeout is refused,
                              not silently allowed
      dod.sh                  a session cannot end on a red build (same deadline rule)
      req-gate.sh             Gate A: every REQ has a task; Gate B: at completion, every REQ has a test
      autofix.sh              formatters fix mechanical issues silently
      session-engines.sh      SessionStart: states the engine map the session is actually running under
      postcompact-policy.sh   PostCompact: re-injects the routing section of the policy after compaction
    scripts/
      trace-matrix.sh         generates specs/<feature>/matrix.html (red = uncovered requirement)
      apply-engines.sh        rewrites each installed agent's `model:` line from the engine map
      mod-check.sh            runs `claude plugin validate` / `claude plugin test` on the
                              engine-map mod for make check / make test
      check-command-refs.sh   proves every `/name` a repo's CLAUDE.md and command files cite
                              still exists (project, installed, built-in, or vouched for)
      merge-settings.sh       prints ~/.claude/settings.json with the hooks snippet merged in;
                              existing entries survive, nothing is written
    commands/
      feature.md              /feature — the whole pipeline for one ask
      spec.md                 /spec — spec stage only, decision-first digest for Gate 1
      build.md                /build — execute approved work: a feature, or (no args) the whole
                              queue unattended (worktrees, kill rule, assumptions recorded)
      ship.md                 /ship — Gate 2: computed digest + ship decisions, one yes per branch
      rca.md                  /rca — the bug-to-rule flywheel: reproduce, fix, generalise
      test-audit.md           /test-audit — audits the test suite itself: the four lanes
      hunt.md                 /hunt — the unattended bug hunt: sweeps, proves each finding, fixes
                              what it can and files the rest, then stops itself with a named reason
                              (hunt looks for bugs, test-audit judges the tests, rca kills the class of one known bug)
    settings/
      hooks-snippet.json      hooks + worktree config to MERGE into ~/.claude/settings.json
    templates/
      sdlc-engines.conf       the shipped engine map, copied to ~/.claude/ on first install only
      Makefile.python         per-repo contract (make check / make test + TEST_PROFILE)
      Makefile.node
      Makefile.static         minimal contract for static-site repos
      pre-commit              plain git hook mirror so manual commits hit the same gate
      ci-check.yml            CI mirror: runs the repo's `make check` on push and on PR,
                              so the gates are not local-only. Copy into .github/workflows/
      specs/                  requirements/design/tasks templates (EARS + REQ-IDs + verify tiers)
    doctor                  read-only installation and workspace inventory (see above)
    install.sh              idempotent installer (never edits settings.json)
    push.sh                 the maintainer's one push: always the private push, then, from
                            main only, the public publish
    publish.sh              exports one commit, sweeps it for private names, publishes it
    specs/                  this repository's own specs: in-flight features, and
                            `_shipped/` for the audit trail of decisions already made
    examples/todo-cli/      a tiny practice project for the walk-through above

## Project layer

The framework ships the engines; each repo supplies the contract they run against. This
section is the only place the framework says what a repo may add — everything here is
optional except the two Makefile targets, which the gates call by name.

- **`Makefile` — the `check` and `test` targets.** The contract every gate calls: `check`
  is the fast lane (syntax, lint, types) that blocks a commit while it is red, and `test`
  runs everything the profile declares. Start from `templates/Makefile.python`,
  `Makefile.node` or `Makefile.static`.
- **`TEST_PROFILE`** — one line in that Makefile declaring how deep the repo tests:
  `lib | api | webapp | static`. Agents read it to size their work, and the spec-reviewer
  uses it to flag a requirement whose proof the declared profile cannot deliver.
- **`specs/` layout** — `specs/<feature>/{requirements,design,tasks}.md` for work in
  flight, `specs/_shipped/` for features that have shipped, `specs/_audit/` for
  test-audit reports (`/test-audit` creates `specs/_audit/` the first time it runs).
  The requirement gates scan `specs/*/`; both underscore directories sit outside that
  scan, so an archive or a report never trips a gate.
- **`.claude/commands/`** — project commands, one Markdown prompt file per command,
  named for the slash command it defines. The collision rule is one sentence:
  A project command with the same name as a global command wins.
  `install.sh` warns (one `WARNING` line naming the repo and the command) whenever a
  repo under its scan root — `$SDLC_SCAN_ROOT`, else the parent of the framework
  checkout, up to four directory levels down — shadows a global command name, so a
  shadow is always a deliberate choice.
- **`.claude/agents/`** — project agents: workers that only make sense in this repo.
  Think of each as filling one of the framework's roles, and set its `model:` to what the
  engine map gives that role. Keep them in step the same way the global agents are kept,
  rather than by hand: put a `roles.conf` beside them binding each agent to a role
  (`<agent> = <role>`, the same format as `agents/roles.conf`), then run
  `SDLC_AGENTS_DIR=.claude/agents ~/.claude/scripts/apply-engines.sh` from the repo.
  It rewrites those agents' `model:` lines and no others; without a `roles.conf` beside
  them it reports that and changes nothing, rather than guessing a role. The map itself
  is still read from its machine-level location — a repo never carries its own.
- **The engine map — `~/.claude/sdlc-engines.conf`.** Not a repo file: the one
  machine-level knob, listed here because it is the boundary of the project layer. The
  framework routes by role — `judge` (the main session's own reasoning), `build` (the
  implementer), `verify` (the reviewing and auditing agents), `read` (bulk reading), plus
  `escalate`, a deliberate lever the owner names in the moment and never an automatic
  route. This file is what binds each role to a model, one per line, in the form
  `<role> = <model>[, <model>…]` — the models after the first are an ordered fallback
  chain. Lines whose first non-blank character is `#` are comments; blank lines are
  ignored. `install.sh` creates the file from `templates/sdlc-engines.conf` the first
  time and **never overwrites** it afterwards, so the owner's choice survives every
  re-install. After editing the map, re-run `~/.claude/scripts/apply-engines.sh` (the
  installed copy of `scripts/apply-engines.sh`) to push the change into each installed
  agent's `model:` line. A repo must not pin `model` in its own
  `.claude/settings.json`: the map is the single binding, and a second one would silently
  win.
- **`.claude/hooks/`** — project hooks, layered on the global ones rather than replacing
  them; the usual case is a protected-path guard that refuses edits to a no-fix zone.
- **`.claude/known-commands`** — optional, one name per line: slash commands the repo
  vouches for that `scripts/check-command-refs.sh` cannot see (a plugin's command, a
  route name written like one). Run `~/.claude/scripts/check-command-refs.sh .` from
  the repo — ideally from its `make check` — and every `/name` its CLAUDE.md and command
  files cite must resolve to a project or installed command or skill, a harness built-in,
  or a line in this file. A name in the instructions that resolves nowhere is the
  drift this catches: a rule that tells a session to run something it cannot.
- **`permissions.ask` for push, when push deploys** — a repo where `git push` ships to
  production adds `{"permissions": {"ask": ["Bash(git push*)"]}}` to its own
  `.claude/settings.json`. The framework does not ship that gate globally: whether push
  deploys is a fact about a repo, not about the machine.
- **`CLAUDE.md` add-on sections** — project rules stacked on top of the framework, plus
  the optional one-line declarations `/rca` reads: `decision log:`, `tracker:` and
  `protected paths:`. Declare nothing and the engines degrade gracefully — no tracker
  means the evidence summary is delivered in chat, no protected paths means none exist.
- **A decision log** — an optional directory or file where lasting decisions are
  recorded (`decisions/`, `docs/decisions/`, or whatever the `decision log:` line names).
  `/rca` writes its prose rules there when a repo has one, and into `CLAUDE.md` when not.
- **Reserved Makefile targets** — `sim-up`, `sim-down`, `sim-cast`: reserved, not yet used.
  Leave the names free so a repo does not have to rename its own targets later.

## The two human gates

1. **Plan approval** — nothing is built until the plan is
   approved from the /spec decision digest.
2. **Ship review** — nothing ships without an explicit yes; where push deploys, that yes
   is the deploy.

## Codex specifics

Codex runtime and policy install to `~/.codex/sdlc-openai/`, with the discoverable skill
in `~/.codex/skills/openai-sdlc/`; `installation.json` there records the canonical source.
Codex defaults to a dry run and preserves unrelated settings, owner engine choices and
safety hooks. Its commit hook gives `make check` 870 seconds inside the host's 900-second
deadline; timeout, failure or a missing Makefile denies the commit. Restart the host after
installation so changed hook settings load.

With `claude` on PATH, `make check` runs `claude plugin validate` on the Claude engine-map
mod and `make test` runs its `claude plugin test` suite. A Codex-only checkout without
`claude` fails both targets with one line saying the mod checks did not run; set
`SDLC_SKIP_CLAUDE_MOD=1` to skip them explicitly. The same line is still printed, and
the skip never silences a check that did run.

Installers record source provenance and hashes in `doctor-installation.json`; doctor
compares the installer-owned fragment of shared files (`config.toml`, `hooks.json`,
`AGENTS.md`), so an owner's own edits elsewhere in them are not reported as drift.

Codex changes save a manifest and the previous files under
`~/.codex/sdlc-backups/<timestamp>/`. To roll back, restore each previously existing file
from that backup and remove only the newly created files the manifest names. Before a
Claude update, snapshot `~/.claude` yourself; the installer deletes nothing.

`adapters/codex/scripts/backup-settings.py` stages the Codex settings, runtime, skill and
framework source under `~/.local/state/ainative-sdlc/backup-staging` (or
`$SDLC_BACKUP_STAGING_DIR`) for whatever backup routine you already run; set
`$SDLC_BACKUP_SCRIPT` to have it invoked afterwards.

## Known gaps (accepted, revisit later)

- **Commit-gate time limit.** The gate is a PreToolUse hook with a timeout, and a hook that
  times out does NOT block, so a slow `check` once left commits
  ungated while looking gated; the absence of a block is not evidence the checks passed.
  The gate now keeps its own clock: it stops the checks 30 seconds before its timeout and
  refuses the commit (`dod.sh` does the same at Stop). A repo still keeps `check`
  inside that budget or knows it is ungated by the harness; slow work goes in `test`.
- Gates run locally only (Claude hooks + optional pre-commit). Close it by copying
  `templates/ci-check.yml` into a repo's `.github/workflows/`: it runs that repo's
  `make check` on push and on pull request, so a push that skipped a local gate still
  has something behind it.
- Gate B proves a tagged test EXISTS and the suite is green; whether the test
  meaningfully tests the requirement is a `verify` / `judge` judgment call.
- TDD red-phase edge: ending a main-session turn with an intentionally-failing
  test uncommitted trips dod.sh. Normal flow (subagents go red→green within one
  run) avoids it; if it bites, finish the green step before stopping.
- Requirement gates are repo-global: one feature's coverage gap blocks commits for
  unrelated work in the same repo (the block message names the feature; fix or defer it).
- Docs-only commits (.md/.txt/.rst/.html) skip `make check` but still run the requirement
  gate, and only when the command commits the index as it stands: a `git add`, `-a` or a
  pathspec in the same command runs the full check. A git pre-commit hook that stages
  files during the commit is not visible to the gate. `git merge` commits at /ship are
  gated by the post-merge check the command runs, not by the commit hook.
- autofix.sh (async formatter) can, rarely, race a subsequent Edit ("file modified since
  read"). If that shows up in practice, remove `"async": true` from its hook entry.
- Whether PreToolUse hooks fire inside subagents has changed across client releases. Prove
  it on first install: have an implementer run `git commit` in a repo with a failing check
  and confirm the block.

## Words used here

- **SDLC** — Software Development Life Cycle: the steps a change goes through, from idea to release.
- **Gate** — a point where work stops until something is proven: a passing check, or a person's yes.
- **Hook** — a small script the AI tool runs automatically at a set moment, such as just before a commit.
- **Harness** — the AI tool that runs the model and its hooks: Claude Code or Codex.
- **Commit** — a saved snapshot of changes in git, with a message saying what changed.
- **Branch** — a separate line of work in git, so a change can be built without touching the main line.
- **Push** — sending commits from your computer to the shared copy of the repository (for example on GitHub).
- **Deploy** — putting a change live where users see it; in some repositories a push is a deploy.
- **Spec** — the written plan for a feature: requirements, design and tasks under `specs/<feature>/`.
- **EARS** — a fixed sentence pattern for requirements ("WHEN …, THE SYSTEM SHALL …"), so each one is testable.
- **REQ-ID** — the permanent number of one requirement (`REQ-TODO-001`); tasks and tests quote it.
- **Worktree** — a second working folder of the same repository, so the AI builds without disturbing yours.
- **Adversarial review** — a second agent told to find what is wrong with a plan or a change, not to agree.
- **Verifier** — an agent with no memory of the build that checks the result against the spec.
- **Ship digest** — the short summary `/ship` computes from the real diff and tests before asking you.
- **RCA** — root-cause analysis: finding why a bug happened, so the whole class of bug is fixed.
- **judge** — role: the main session's own reasoning; it plans and decides.
- **build** — role: the implementer that writes tests and code.
- **verify** — role: the reviewers and auditors that check work.
- **read** — role: bulk reading of many files, returned as a short digest.
- **escalate** — the fifth role: a lever you pull by name for a stronger model, never automatic.
- **Engine map** — the one file (`~/.claude/sdlc-engines.conf`) that says which model fills each role.
- **Fallback chain** — the models listed after the first on a map line, tried in order if the first is unavailable.
- **Adapter** — the part of the framework written for one harness (`adapters/claude/`, `adapters/codex/`).
- **Handoff** — passing a task in progress from one harness to the other with a compact briefing.
- **Handback** — returning the results of a handoff to the session that sent it.
- **Doctor** — `./doctor`, a read-only health check of the installation and enrolled repositories.
- **TEST_PROFILE** — one line in a repository's Makefile saying how deep its testing goes (`lib`, `api`, `webapp`, `static`).
- **Idempotent** — safe to run twice: the second run changes nothing.
- **Compaction** — the AI tool shortening a long conversation into a summary to free up memory.
- **Subagent** — a helper AI session the main session starts for one job, which reports back when done.
- **CI** — continuous integration: the same checks run again automatically on a server (such as GitHub) after every push.
- **artifacts** — the proof a step leaves behind that anyone can read: test output, exit codes, the exact changes.

## Development

```sh
make check      # bash -n + shellcheck over every script, jq over the hooks snippet,
                # the requirement gate, Python validation and the Python test suite,
                # and validates the mod
make test       # every tests/test_*.sh plus tests/codex, and the mod's own tests
```

`sdlc-policy.md` is generated: after editing `core/policy.md` or `adapters/claude/policy.md`,
run `python3.12 adapters/claude/render-policy.py`; the gate rejects any drift.

**Scrub fence.** `commands/*.md`, `README.md`, `install.sh`, `scripts/*.sh`,
`templates/**`, `settings/*.json` and the agent files may carry no project or owner name
and no literal four-digit year. `tests/test_scrub.sh` enforces the generic tokens; add your
own project names, one fixed string per line (matched literally, not as a regular
expression), in
`~/.config/ainative-sdlc/scrub-tokens` (or `$SDLC_SCRUB_TOKENS_FILE`) and the fence
checks those too. Write literal em dashes rather than their JSON unicode escape, and never
round-trip fenced files through a JSON dumper with `ensure_ascii` on: the escape contains
four digits.

`specs/_shipped/**` is the audit trail of decisions already made and is superseded in
place with a note, never edited to match what the code became.

## Where this repository comes from

This is a curated export. Development happens in a private working repository whose
history and working notes contain workspace details; `publish.sh` in that checkout
exports one commit at a time, strips the private notes, sweeps every file for private
names and paths, and commits the result here. Issues and pull requests are welcome here;
changes are folded back into the working repository and re-exported. `push.sh` wraps the
private push and the publish, so the maintainer never runs them separately.

`publish.sh` hard-codes the maintainer's public repository and GitHub noreply email as
its defaults. Anyone reusing it sets `SDLC_PUBLIC_REPO`, `SDLC_PUBLIC_EMAIL` and
`SDLC_PUBLIC_NAME` first, so an export can never land in someone else's repository or
under someone else's name.

The same script is the pattern for anyone keeping a private working repository and a
public copy, and it is built so that a mistake is refused rather than published:

- **Files, never history.** The public side receives the tree of one commit via
  `git archive`; the private history is never pushed anywhere public.
- **A private-token sweep that cannot be skipped.** Names to keep out live in a
  machine-local list outside the repository (`~/.config/ainative-sdlc/scrub-tokens`).
  No list, or an empty one, is a refusal, and every exported file is matched against
  the list and against home-directory paths before anything leaves the machine.
- **`--dry-run` first.** It builds and sweeps the export and prints where it is, so the
  result can be read before the real run.
- **`--install-guard`.** Installs a git pre-push hook in the working checkout that
  refuses any push whose remote URL is the public repository, whichever tool issued
  the push. The script's own temporary clone is the only thing that ever pushes there.
- **No force.** Each publish is one commit on the public repository's own linear
  history, so nothing there is ever rewritten.

`tests/test_publish.sh` proves each refusal by planting the fault and watching the
run go red.

## License

MIT. See `LICENSE`.
