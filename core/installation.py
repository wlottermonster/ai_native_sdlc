"""Versioned installation provenance. Stores hashes, never settings contents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib

# Files the installer merges into rather than owns. Only the installer-owned
# fragment is hashed, so owner and client edits elsewhere in them are not drift.
FRAGMENT_KINDS = ('codex-agents-block', 'codex-config', 'codex-hooks', 'claude-agent', 'claude-settings-hooks')
AGENTS_BLOCK = re.compile(r'<!-- openai-sdlc:begin -->.*?<!-- openai-sdlc:end -->', re.S)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def managed_fragment(kind, data):
    """Return the installer-owned bytes of a mixed-ownership file, canonicalized."""
    if kind == 'codex-agents-block':
        match = AGENTS_BLOCK.search(data.decode('utf-8'))
        return match.group(0).encode('utf-8') if match else b''
    if kind == 'codex-config':
        value = tomllib.loads(data.decode('utf-8')).get('desktop', {})
        value = value.get('external-agent-import-sync-enabled') if isinstance(value, dict) else None
        return json.dumps(value).encode('utf-8')
    if kind == 'codex-hooks':
        document = json.loads(data.decode('utf-8'))
        rows = []
        for event, groups in (document.get('hooks', {}) if isinstance(document, dict) else {}).items():
            for group in groups if isinstance(groups, list) else []:
                for hook in group.get('hooks', []) if isinstance(group, dict) else []:
                    if isinstance(hook, dict) and str(hook.get('statusMessage', '')).startswith('OpenAI SDLC:'):
                        rows.append({'event': event, 'matcher': group.get('matcher'), 'hook': hook})
        return json.dumps(sorted(rows, key=lambda row: json.dumps(row, sort_keys=True)),
                          sort_keys=True).encode('utf-8')
    if kind == 'claude-agent':
        return re.sub(rb'^model:.*$', b'model:', data, flags=re.M)
    if kind == 'claude-settings-hooks':
        document = json.loads(data.decode('utf-8'))
        hooks = document.get('hooks') if isinstance(document, dict) else None
        return json.dumps(hooks if isinstance(hooks, dict) else None, sort_keys=True).encode('utf-8')
    raise ValueError('Unknown managed fragment kind: ' + str(kind))


SKILLS_DIR = 'adapters/claude/skills'
# The adapter names the files its engine lays beside a loaded skill; core only
# applies the list, so the names stay in the adapter.
SKILL_EXCLUSIONS = 'adapters/claude/skill-exclusions.txt'


def skill_exclusions(source):
    """Excluded path-component runs; a skills folder without its list cannot be filtered."""
    path = Path(source) / SKILL_EXCLUSIONS
    if not (Path(source) / SKILLS_DIR).is_dir():
        return ()
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise ValueError('Skill exclusion list is unavailable: ' + str(path)) from error
    return tuple(tuple(line.strip().split('/')) for line in lines
                 if line.strip() and not line.strip().startswith('#'))


def skipped_skill_file(path, root, exclusions):
    """True when a file under the skills root matches an excluded component run."""
    try:
        parts = Path(path).relative_to(root).parts
    except ValueError:
        return False
    return any(parts[i:i + len(run)] == run
               for run in exclusions for i in range(len(parts) - len(run) + 1))


def walk_files(top, root, exclusions):
    """Every file under `top`, never descending into an excluded directory.

    The same verdicts as filtering a full rglob afterwards (symlinked
    directories are listed, not followed), but a tree the engine lays beside a
    loaded mod, such as node_modules, is never enumerated.
    """
    found = []
    for dirpath, dirnames, filenames in os.walk(top):
        here = Path(dirpath)
        dirnames[:] = sorted(d for d in dirnames if not skipped_skill_file(here / d, root, exclusions))
        found.extend(here / f for f in filenames)
    return [p for p in found if p.is_file() and not skipped_skill_file(p, root, exclusions)]


def source_files(source):
    source = Path(source).resolve()
    if not (source / 'core').is_dir() or not (source / 'install.sh').is_file():
        raise ValueError('Framework source is unavailable or incomplete')
    paths = []
    exclusions = skill_exclusions(source)
    for name in ('core', 'adapters'):
        paths.extend(p for p in walk_files(source / name, source / SKILLS_DIR, exclusions)
                     if '__pycache__' not in p.parts and p.suffix != '.pyc')
    paths.extend(source / n for n in ('install.sh', 'Makefile', 'sdlc-policy.md', 'doctor')
                 if (source / n).is_file())
    result = {str(p.relative_to(source)): digest(p.read_bytes()) for p in paths}
    for name in ('agents', 'commands', 'hooks', 'scripts', 'settings', 'templates'):
        p = source / name
        if p.is_symlink():
            result[name] = digest(os.readlink(p).encode())
    return dict(sorted(result.items()))


def source_snapshot(source):
    source = Path(source).resolve()
    files = source_files(source)
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env['GIT_OPTIONAL_LOCKS'] = '0'
    def git(*args):
        p = subprocess.run(['git', '-c', 'core.fsmonitor=false', '-C', str(source), *args], env=env,
                           capture_output=True, timeout=10)
        return p.stdout.decode().strip() if p.returncode == 0 else None
    try:
        revision = git('rev-parse', '--verify', 'HEAD')
        dirty = git('status', '--porcelain', '--untracked-files=normal')
    except (OSError, subprocess.TimeoutExpired):
        revision, dirty = None, None
    return {'path': str(source), 'revision': revision,
            'dirty': None if dirty is None else bool(dirty),
            'fingerprint': digest(json.dumps({'files': files, 'modes': {
                name: (source / name).lstat().st_mode & 0o777 for name in files
            }}, sort_keys=True).encode())}


def build_manifest(source, writes, fragments=None):
    fragments = fragments or {}
    recorded = lambda p: str(Path(p).parent.resolve() / Path(p).name)
    ordered = sorted(writes.items(), key=lambda item: str(item[0]))
    return {'schema_version': 1, 'source': source_snapshot(source),
            'source_files': source_files(source),
            'managed_files': {recorded(p): digest(data) for p, data in ordered if p not in fragments},
            'managed_fragments': {recorded(p): {'kind': fragments[p],
                                                'sha256': digest(managed_fragment(fragments[p], data))}
                                  for p, data in ordered if p in fragments}}


def write_manifest(path, manifest):
    path = Path(path)
    for p in (path, *path.parents):
        if p.is_symlink():
            raise ValueError('Refusing symlinked receipt destination')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.receipt-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(manifest, stream, indent=2)
            stream.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def claude_skill_writes(source, runtime):
    """Preflight native skills without overwriting custom or unowned content."""
    source, runtime = Path(source).resolve(), Path(runtime).absolute()
    manifest = runtime / 'doctor-installation.json'
    old = json.loads(manifest.read_text()).get('managed_files', {}) if manifest.is_file() else {}
    writes = {}
    exclusions = skill_exclusions(source)
    for src in sorted(walk_files(source / SKILLS_DIR, source / SKILLS_DIR, exclusions)):
        dst = runtime / 'skills' / src.relative_to(source / SKILLS_DIR)
        for part in (dst, *dst.parents):
            if part.is_symlink():
                raise ValueError('Refusing symlinked skill destination')
        expected = src.read_bytes()
        if dst.exists() and dst.read_bytes() != expected:
            if old.get(str(dst.parent.resolve() / dst.name)) != digest(dst.read_bytes()):
                raise ValueError('Existing handoff skill is unowned or customized: ' + str(dst))
        writes[dst] = expected
    return writes


def install_claude_skills(source, runtime):
    import shutil
    from datetime import datetime, timezone
    writes = claude_skill_writes(source, runtime)
    backup = Path(runtime) / 'sdlc-skill-backups' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    for dst, data in writes.items():
        if dst.is_file() and dst.read_bytes() == data:
            continue
        if dst.exists():
            saved = backup / dst.relative_to(runtime)
            saved.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copy2(dst, saved)
        dst.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, name = tempfile.mkstemp(dir=dst.parent, prefix='.skill-')
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
            os.replace(name, dst)
        finally:
            if os.path.exists(name):
                os.unlink(name)



def migrate_claude_handoff_hook(runtime):
    """Update only a recognized framework Stop command; retain all other settings."""
    import shutil
    from datetime import datetime, timezone
    runtime = Path(runtime).absolute()
    path = runtime / 'settings.json'
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError('Refusing symlinked settings destination')
    if not path.exists():
        return False
    original = path.read_bytes()
    document = json.loads(original)
    relative = '$HOME/' + runtime.name + '/hooks/req-gate.sh'
    expected = {'"' + relative + '"', relative,
                '"' + str(runtime / 'hooks/req-gate.sh') + '"', str(runtime / 'hooks/req-gate.sh')}
    changed = False
    for group in document.get('hooks', {}).get('Stop', []):
        for hook in group.get('hooks', []):
            if hook.get('type') == 'command' and hook.get('command') in expected:
                hook['command'] += ' --stop'
                changed = True
    if not changed:
        return False
    backup = runtime / 'sdlc-skill-backups' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup.mkdir(parents=True, mode=0o700)
    shutil.copy2(path, backup / 'settings.json')
    fd, name = tempfile.mkstemp(dir=runtime, prefix='.handoff-settings-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write((json.dumps(document, indent=2, ensure_ascii=False) + '\n').encode())
        os.chmod(name, path.stat().st_mode & 0o777)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)
    return True


def claude_manifest(source, runtime):
    """Expected copied bytes; agents have owner-selected model frontmatter."""
    source = Path(source).resolve()
    runtime = Path(runtime).parent.resolve() / Path(runtime).name
    writes = {}
    fragments = {}
    for folder, pattern in [('agents', '*.md'), ('agents', '*.conf'),
                            ('hooks', '*.sh'), ('scripts', '*.sh'), ('commands', '*.md')]:
        for src in (source / folder).glob(pattern):
            expected = src.read_bytes()
            dst = runtime / folder / src.name
            if folder == 'agents' and src.suffix == '.md':
                # apply-engines changes only model lines. Verify the rest before
                # recording its expected owner-configured result.
                actual = dst.read_bytes()
                import re
                strip = lambda data: re.sub(rb'^model:.*$', b'model:', data, flags=re.M)
                if strip(actual) != strip(expected):
                    raise ValueError('Installed agent differs beyond model routing')
                expected = actual
                fragments[dst] = 'claude-agent'
            if not dst.is_file() or dst.read_bytes() != expected:
                raise ValueError('Installed framework asset does not match source')
            writes[dst] = expected
    for dst, expected in claude_skill_writes(source, runtime).items():
        if not dst.is_file() or dst.read_bytes() != expected:
            raise ValueError('Installed handoff skill differs from source')
        writes[dst] = expected
    for src, dst in [('sdlc-policy.md', 'sdlc-policy.md'),
                     ('core/handoff.py', 'scripts/handoff.py'),
                     ('core/handoff_store.py', 'scripts/handoff_store.py'),
                     ('core/handoff_runtime.py', 'scripts/handoff_runtime.py'),
                     ('core/project.py', 'scripts/project.py'),
                     ('core/doctor.py', 'scripts/doctor.py'),
                     ('adapters/codex/scripts/routing.py', 'scripts/routing.py'),
                     ('core/installation.py', 'scripts/installation.py'),
                     ('core/templates/pre-commit', 'templates/pre-commit')]:
        expected = (source / src).read_bytes()
        if (runtime / dst).read_bytes() != expected:
            raise ValueError('Installed framework asset does not match source')
        writes[runtime / dst] = expected
    return build_manifest(source, writes, fragments)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--check-skills', action='store_true')
    parser.add_argument('--install-skills', action='store_true')
    args = parser.parse_args()
    runtime = args.runtime.parent.resolve() / args.runtime.name
    if args.check_skills:
        claude_skill_writes(args.source, runtime)
    elif args.install_skills:
        install_claude_skills(args.source, runtime)
        migrate_claude_handoff_hook(runtime)
    else:
        write_manifest(runtime / 'doctor-installation.json', claude_manifest(args.source, runtime))
