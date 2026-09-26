# AI-Native SDLC (Codex adapter)

A global Codex framework for software projects under your workspace, with a host-specific adapter alongside the
Claude adapter. Includes context engineering, bounded task loops, evidence,
workflow skills and Codex lifecycle hooks. Uses the existing ChatGPT/Codex tools;
no new account, API key, service, runtime model or subscription is required.

## Use

The commit gate recognizes executable Git commands rather than mentions in prose
or filenames. Standalone `git [-C directory]* commit` runs `make check`; recognized
compound and wrapper commits are denied with instructions to use the standalone
form. Quoted messages may contain shell punctuation. Common env/command/shell
wrappers and executable substitutions are recognized; aliases, shell functions,
arbitrary programs and advanced shell grammar are outside this convenience gate.
Always run required checks explicitly and use CI as the integration gate.

The internal check deadline is 870 seconds inside the host's 900 seconds.
Timeout is a denial, not a pass. Claude's shell commit/Stop gates remain in its
own adapter; Codex uses the Python lifecycle hooks and persisted-run reminder.

Open a project in a **new Codex session** and ask normally, for example:

- "Use OpenAI SDLC to plan and build this feature."
- "Resume the login fix from its handoff."
- "Verify this branch and ship it."
- "Audit these tests" or "Investigate this failure."

The `openai-sdlc` skill provides feature, spec, build, verify, audit, debugging,
ship and handoff workflows. Durable records live in `specs/<feature>/` and local
`.sdlc-openai/runs/`. See [policy](policy.md) and [loop commands](skills/openai-sdlc/references/loops.md).
Scope covers nested projects under the configured workspace. Project AGENTS.md
adds local rules. No per-project installation is needed for global guidance.

## Install / update

Requires Python 3.12. From this repository's checkout, review the dry-run then
apply (after the first install, installation.json records that checkout's path):

```sh
bash install.sh --harness codex --workspace /path/to/your/workspace
bash install.sh --harness codex --workspace /path/to/your/workspace --apply
make check
```

The canonical source is the checkout you installed from. Runtime copies live in `~/.codex/sdlc-openai/`; the skill
lives in `~/.codex/skills/openai-sdlc/`. The installer adds a managed global
AGENTS.md block, disables external-agent import sync in Codex, and replaces only
known imported SDLC hooks. In AGENTS.md it manages only its own marked block and
leaves every other section untouched. It preserves unrelated preferences,
plugins, model choice and safety hooks.
Set `SDLC_MIGRATE_LEGACY_SECTIONS=1` if you are upgrading from the pre-release
layout: the installer then also removes that layout's imported model/routing
sections from AGENTS.md, keeping any other preferences they held.
It writes nothing to `~/.claude`, `~/.agents`, other projects or shell startup.
Rerunning updates owned files; it preserves your installed engines.toml.

**Open `/hooks` in Codex CLI and review/trust the new hooks.** Codex skips new
untrusted hooks. Installation does not fabricate trust or disable its review.
Global AGENTS.md and the skill remain useful before hook activation. Restart
Codex after configuration changes. Existing sessions may retain imported context.

## Checks and limits

`make check` is the commit contract. Projects without it need an adapter to their
actual lint/type/test commands; installation does not rewrite every project.
The commit hook checks standalone `git [-C path] commit`; complex wrappers must
be split into separate calls. Other tool paths/aliases can bypass it. CI and
explicit executed evidence remain authoritative. The Stop hook reminds once
about tracked active runs; it is not an infinite continuation loop.

The task helper enforces saved iteration limits and verification timeouts. It
does not autonomously schedule models or provide token/dollar metering. A green
command is only meaningful if it implements the real acceptance contract. Git
ignored files are outside its freshness fingerprint. The parent session retains its selected model. engines.toml supplies model and
reasoning assignments for native global agents rendered by the installer.
Workflow instructions select roles; the map does not change a running session.
ChatGPT artifacts can be handed into this workflow, but cloud chat synchronization
and a custom ChatGPT application are not installed by this setup.

## Rollback

Each changed installation saves previous files and a manifest under
`~/.codex/sdlc-backups/<timestamp>/`. To roll back, inspect that manifest, restore
each previously existing file from its matching relative path, and remove only
new files named in that manifest after checking for later edits. Restart Codex
and review hooks again. Claude never needs restoration because it is not changed.
Run your own settings backup after installation and rollback.

## Sources and design

- [Design](docs/design.md) and [implementation plan](docs/plan.md)
- [OpenAI global/project instructions](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [OpenAI skills](https://learn.chatgpt.com/docs/build-skills)
- [OpenAI hooks and trust](https://learn.chatgpt.com/docs/hooks)

The original `ainative_sdlc` inspired the lifecycle and evidence principles.
Both adapters are maintained together; host mechanisms remain distinct.

## Repeatable project onboarding

For a new checkout, run the installed setup inspector:

```sh
python3.12 ~/.codex/sdlc-openai/scripts/project.py --repo /path/to/project
python3.12 ~/.codex/sdlc-openai/scripts/project.py --repo /path/to/project --apply
```

Apply mode preserves existing instruction files and custom hooks. It creates missing
instruction entry points and installs the standard fail-closed Git mirror only
when explicit `check` and `test` targets already exist. It never invents passing
recipes. A configured shared hooks directory requires manual integration. Setup
readiness is separate from executed tests and live hook activation. Claude ships
the same inspector under its own scripts directory.

## Native protected paths

The global pre-tool hook reads project night locks and zone declarations relative
to the working tree. New projects may use `.sdlc/night-lock` and
`.sdlc/protected-paths.txt` (one relative pattern per line, `!` exceptions). Existing
`.claude/.night-lock` and `.claude/hooks/no_fix_zones.txt` declarations remain
supported as project data. Codex does not load Claude model or agent configuration.

Native patch additions, updates, deletions and move destinations are checked,
including symlink targets and nested project roots. While a relevant lock is on,
ambiguous tools and shell execution are denied; use native patches for permitted
edits. Only simple read commands are allowed, with `rg --no-config` and
`git diff --no-ext-diff --no-textconv`. This is an accidental-edit guard, not an OS
sandbox or proof about arbitrary programs. Restart and review changed hooks in
the client before relying on live enforcement.

## Global role routing

Edit the installed `~/.codex/sdlc-openai/engines.toml`, then rerun this adapter's
installer with `--apply`. Existing maps are preserved on reinstall. `[roles]`
contains model IDs, `[reasoning]` contains explicit effort, and `[agents]` maps
native agent names to roles. `inherit` removes explicit model/effort settings.
The installed native definitions keep existing instructions and unrelated fields.
`doctor` checks map-to-agent consistency; model syntax validation cannot certify
account access or client acceptance. A genuine fresh-client probe is separate.
Models are configured centrally; no project pins are added. Escalation is owner
requested only, and no implicit model fallback is configured.
