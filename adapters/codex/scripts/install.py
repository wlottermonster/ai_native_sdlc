#!/usr/bin/env python3.12
"""Install a scoped OpenAI SDLC into Codex, preserving unrelated configuration."""
import argparse
from datetime import datetime, timezone
import difflib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sys
import tempfile
import tomllib

ADAPTER = Path(__file__).resolve().parents[1]
SOURCE = ADAPTER.parents[1]
sys.path.insert(0, str(SOURCE / 'core'))
from installation import build_manifest
sys.path.insert(0, str(ADAPTER / "scripts"))
from routing import plan_agents, parse_map

START = '<!-- openai-sdlc:begin -->'
END = '<!-- openai-sdlc:end -->'


def regular_path(path, root):
    """Reject symlinked installation paths rather than writing through them."""
    current = path
    while current != root.parent:
        if current.is_symlink():
            raise ValueError(f'Refusing symlinked destination: {current}')
        if current == root:
            break
        current = current.parent


# Opt-in only (SDLC_MIGRATE_LEGACY_SECTIONS=1, for upgrades from the pre-release
# layout): without it the installer touches nothing outside its START/END block.
LEGACY_OPT_IN = 'SDLC_MIGRATE_LEGACY_SECTIONS'
LEGACY_POLICY_HEADING = '## Model & engine policy'
LEGACY_ENTRY_BULLET = '- The ONLY entry point'
LEGACY_ROUTING_HEADING = '### SDLC routing'


def migrate_legacy_sections(original):
    """Remove only the obsolete entrypoint bullet and routing section. Other
    preferences (including retired models) and unknown sections survive."""
    def preserve_preferences(match):
        body = re.sub('^' + re.escape(LEGACY_ENTRY_BULLET) + r'.*?(?=^- |\Z)', '', match.group(1), flags=re.M | re.S).strip()
        return ('## Local model and settings preferences\n\n' + body + '\n\n') if body else ''
    original = re.sub('^' + re.escape(LEGACY_POLICY_HEADING) + r'[^\n]*\n(.*?)(?=^#{1,3} |\Z)', preserve_preferences, original, flags=re.M | re.S)
    return re.sub('^' + re.escape(LEGACY_ROUTING_HEADING) + r'[^\n]*\n.*?(?=^#{1,3} |\Z)', '', original, flags=re.M | re.S)


def global_instructions(original, target, workspace):
    if original.count(START) != original.count(END) or original.count(START) > 1:
        raise ValueError('Malformed managed AGENTS block')
    original = re.sub(re.escape(START) + r'.*?' + re.escape(END), '', original, flags=re.S)
    if os.environ.get(LEGACY_OPT_IN) == '1':
        original = migrate_legacy_sections(original)
    block = f'''{START}
## OpenAI SDLC — global framework for {workspace}

For software work whose working directory resolves under `{workspace}` (including
nested projects), read `{target}/policy.md` and `{target}/engines.toml` at task start
and after compaction. Use the `openai-sdlc` skill at
`{target.parent}/skills/openai-sdlc/SKILL.md`. Project AGENTS.md files add local rules.
Outside that workspace, this SDLC does not apply unless explicitly requested.

When the user invokes `/loop <workflow>`, read
`{target.parent}/skills/loop/SKILL.md`. This explicit instruction also works
outside the workspace. Resolve the workflow through the project's AGENTS.md
and skills; do not infer a native slash command or background scheduler.

When the user invokes `/handoff` or `/handback`, use the corresponding skill at
`{target.parent}/skills/handoff/SKILL.md` or
`{target.parent}/skills/handback/SKILL.md`. These are instruction aliases where
native slash registration is unavailable. Explicit handoff authorizes the
specific receiving task and return delivery; use exact session identities.

This OpenAI framework is independent of Claude. Do not load Claude's engine map,
policy, or imported commands as global Codex configuration. This adapter does not
write Claude settings. Both adapters share the canonical source in installation.json.
Use the actual selected session model; never claim a model change from a file.
Preserve the owner's push authorization: no extra per-push approval; force-push
remains forbidden. Respect host permissions and report production deployments.
For concurrent Claude/Codex work, use separate branches/worktrees and test ports.
State and evidence belong in the repository, without credentials or raw secrets.
{END}'''
    return original.rstrip() + '\n\n' + block + '\n'


def disable_import(original):
    tomllib.loads(original)
    lines = original.splitlines(keepends=True)
    section = None
    found = False
    for index, line in enumerate(lines):
        match = re.match(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$', line)
        if match:
            section = match.group(1)
        if section == 'desktop' and re.match(r'^\s*external-agent-import-sync-enabled\s*=', line):
            lines[index] = 'external-agent-import-sync-enabled = false\n'
            found = True
    text = ''.join(lines)
    if not found:
        if re.search(r'^\[desktop\][ \t]*(?:#[^\n]*)?$', text, re.M):
            text = re.sub(r'(^\[desktop\][ \t]*(?:#[^\n]*)?$)', r'\1\nexternal-agent-import-sync-enabled = false', text, count=1, flags=re.M)
        else:
            text = text.rstrip() + '\n\n[desktop]\nexternal-agent-import-sync-enabled = false\n'
    tomllib.loads(text)
    return text


def migrate_hooks(existing, target):
    result = json.loads(json.dumps(existing))
    events = result.setdefault('hooks', {})
    old_names = ('check-gate.sh', 'dod.sh', 'req-gate.sh', 'session-engines.sh')
    for event, groups in events.items():
        kept = []
        for group in groups:
            group['hooks'] = [hook for hook in group.get('hooks', []) if not (
                ('/.codex/hooks/' in hook.get('command', '') and any(name in hook['command'] for name in old_names))
                or ('sdlc-policy.md' in hook.get('command', '') and '/.claude/' in hook['command'])
                or hook.get('statusMessage', '').startswith('OpenAI SDLC:'))]
            if group['hooks']:
                kept.append(group)
        events[event] = kept
    command = shlex.quote(sys.executable) + ' ' + shlex.quote(str(target / 'scripts/sdlc.py')) + ' hook'
    for event in ('SessionStart', 'PostCompact', 'PreToolUse', 'Stop'):
        group = {'hooks': [{'type': 'command', 'command': command, 'timeout': 900 if event == 'PreToolUse' else 10, 'statusMessage': 'OpenAI SDLC: ' + event}]}
        if event == 'SessionStart':
            group['matcher'] = 'startup|resume|clear'
        elif event == 'PreToolUse':
            group['matcher'] = '*'
        events.setdefault(event, []).append(group)
    return result


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.sdlc-install-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def install(home, workspace, apply=False):
    home = Path(home).absolute()
    workspace = Path(workspace).resolve()
    codex = home / '.codex'
    target = codex / 'sdlc-openai'
    if (codex / 'AGENTS.override.md').exists():
        raise ValueError('Global AGENTS.override.md would hide AGENTS.md; review it before installing')
    writes = {}
    for relative in ('AGENTS.md', 'config.toml', 'hooks.json'):
        regular_path(codex / relative, home)
    agents = (codex / 'AGENTS.md').read_text() if (codex / 'AGENTS.md').exists() else ''
    config = (codex / 'config.toml').read_text() if (codex / 'config.toml').exists() else ''
    hooks = json.loads((codex / 'hooks.json').read_text()) if (codex / 'hooks.json').exists() else {}
    writes[codex / 'AGENTS.md'] = global_instructions(agents, target, workspace).encode()
    writes[codex / 'config.toml'] = disable_import(config).encode()
    writes[codex / 'hooks.json'] = (json.dumps(migrate_hooks(hooks, target), indent=2) + '\n').encode()
    for directory in ('scripts', 'skills', 'templates', 'docs'):
        for source in sorted((ADAPTER / directory).rglob('*')):
            if source.is_file() and '__pycache__' not in source.parts and source.name != 'install.py':
                writes[target / source.relative_to(ADAPTER)] = source.read_bytes()
    for name in ('project.py', 'doctor.py', 'installation.py', 'handoff.py', 'handoff_store.py', 'handoff_runtime.py'):
        writes[target / 'scripts' / name] = (SOURCE / 'core' / name).read_bytes()
    writes[target / 'templates/pre-commit'] = (SOURCE / 'core/templates/pre-commit').read_bytes()
    for name in ('policy.md', 'engines.toml', 'README.md'):
        if name == 'engines.toml' and (target / name).exists():
            writes[target / name] = (target / name).read_bytes()
            continue
        writes[target / name] = (ADAPTER / name).read_bytes()
    templates = {p.stem: p.read_bytes() for p in (ADAPTER / 'agents').glob('*.toml')}
    mapping = tomllib.loads(writes[target / 'engines.toml'].decode())
    legacy_routing = 'agents' not in mapping and 'reasoning' not in mapping
    names = [] if legacy_routing else parse_map(writes[target / 'engines.toml'])['agents']
    existing_agents = {}
    for name in names:
        path = codex / 'agents' / (name + '.toml')
        regular_path(path, home)
        if path.exists():
            existing_agents[name] = path.read_bytes()
    if legacy_routing:
        print('Legacy routing map preserved; migrate explicitly to enable native role assignments.')
    else:
        for name, data in plan_agents(writes[target / 'engines.toml'], existing_agents, templates).items():
            writes[codex / 'agents' / (name + '.toml')] = data
    writes[target / 'policy.md'] = (SOURCE / 'core/policy.md').read_bytes() + b'\n' + (ADAPTER / 'policy.md').read_bytes()
    skill_root = codex / 'skills' / 'openai-sdlc'
    if skill_root.exists() and not (target / 'installation.json').exists():
        raise ValueError('An existing openai-sdlc skill is not owned by this installer')
    for source in sorted((ADAPTER / 'skills/openai-sdlc').rglob('*')):
        if source.is_file():
            writes[skill_root / source.relative_to(ADAPTER / 'skills/openai-sdlc')] = source.read_bytes()
    loop_root = codex / 'skills/loop'
    loop_source = ADAPTER / 'skills/loop'
    for source in sorted(loop_source.rglob('*')):
        if source.is_file():
            relative = source.relative_to(loop_source)
            destination = loop_root / relative
            previous = target / 'skills/loop' / relative
            regular_path(destination, home)
            if destination.exists() and (not previous.is_file() or
                    destination.read_bytes() != previous.read_bytes()):
                raise ValueError(f'Existing loop skill is not installer-owned or was customized: {destination}')
            writes[destination] = source.read_bytes()
    for skill_name in ('handoff', 'handback'):
        for source in sorted((ADAPTER / 'skills' / skill_name).rglob('*')):
            if not source.is_file():
                continue
            relative = source.relative_to(ADAPTER / 'skills' / skill_name)
            destination = codex / 'skills' / skill_name / relative
            previous = target / 'skills' / skill_name / relative
            regular_path(destination, home)
            if destination.exists() and (not previous.is_file() or destination.read_bytes() != previous.read_bytes()):
                raise ValueError(f'Existing {skill_name} skill is not installer-owned or was customized: {destination}')
            writes[destination] = source.read_bytes()
    writes[target / 'installation.json'] = (json.dumps({'workspace': str(workspace), 'source': str(SOURCE)}, indent=2) + '\n').encode()
    fragments = {codex / 'AGENTS.md': 'codex-agents-block', codex / 'config.toml': 'codex-config',
                 codex / 'hooks.json': 'codex-hooks'}
    writes[target / 'doctor-installation.json'] = (json.dumps(build_manifest(SOURCE, writes, fragments), indent=2) + '\n').encode()
    for path in writes:
        regular_path(path, home)
    changes = {p: b for p, b in writes.items() if not p.exists() or p.read_bytes() != b}
    for path in changes:
        print(('WRITE ' if apply else 'PLAN  ') + str(path))
    if not apply:
        for path in (codex / 'AGENTS.md', codex / 'config.toml', codex / 'hooks.json'):
            old = path.read_text() if path.exists() else ''
            print(''.join(difflib.unified_diff(old.splitlines(True), writes[path].decode().splitlines(True), fromfile=str(path), tofile=str(path) + ' (planned)')))
        return {'changed': len(changes)}
    if not changes:
        return {'changed': 0}
    backup = codex / 'sdlc-backups' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    regular_path(backup, home)
    backup.mkdir(parents=True, mode=0o700)
    manifest = []
    for path in changes:
        relative = path.relative_to(codex)
        manifest.append({'path': str(relative), 'existed': path.exists()})
        if path.exists():
            dest = backup / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
    (backup / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    completed = []
    try:
        for path, data in changes.items():
            atomic_write(path, data)
            completed.append(path)
    except BaseException:
        for path in reversed(completed):
            previous = backup / path.relative_to(codex)
            if previous.exists():
                atomic_write(path, previous.read_bytes())
            else:
                path.unlink()
        raise
    print('Backup: ' + str(backup))
    print('Restart Codex; review new hooks with /hooks. Trust is not modified by this installer.')
    return {'changed': len(changes), 'backup': str(backup)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--workspace', type=Path, default=Path.home() / 'ws')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        install(args.home, args.workspace, args.apply)
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(f'Installation refused: {exc}', file=sys.stderr)
        sys.exit(1)
