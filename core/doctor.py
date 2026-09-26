#!/usr/bin/env python3.12
"""Inspect framework parity and project readiness; checks run only with --verify.

Local receipts are diagnostic evidence, not signed attestations or a security
boundary. Git-ignored source is outside project fingerprints. Live client trust
and compatibility always require a separate genuine harness probe.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from installation import FRAGMENT_KINDS, managed_fragment, source_snapshot
import project as project_contract
# In source the adapter owns routing; installed doctors receive a sibling copy.
sys.path.append(str(Path(__file__).resolve().parents[1] / "adapters/codex/scripts"))
from routing import inspect_routing

HASH = re.compile(r'^[a-f0-9]{64}$')
PRUNE = {'node_modules', 'venv', '__pycache__', 'vendor', 'dist', 'build', 'target'}
COMMANDS = [['make', 'check'], ['make', 'test']]


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def _git(repo, *args, optional=False):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env['GIT_OPTIONAL_LOCKS'] = '0'
    result = subprocess.run(['git', '-c', 'core.fsmonitor=false', '-C', str(repo), *args],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    if result.returncode and not optional:
        raise ValueError('Git metadata unavailable')
    return result.stdout if result.returncode == 0 else b''


def discover(workspace):
    """Find nested normal repositories without traversing dependencies or symlinks."""
    root = Path(workspace).resolve()
    if not root.is_dir():
        raise ValueError('Workspace is not an accessible directory')
    found = []
    def onerror(error):
        raise ValueError('Workspace discovery encountered an unreadable directory') from error
    for directory, dirs, _ in os.walk(root, followlinks=False, onerror=onerror):
        path = Path(directory)
        if os.path.lexists(path / '.git'):
            found.append(path)
        dirs[:] = sorted(name for name in dirs if not name.startswith('.') and name not in PRUNE
                         and not (path / name).is_symlink())
    registered = set(found)
    for repo in found:
        # A candidate whose metadata Git cannot read stays in the inventory as its
        # own blocked row; it must not hide every other project.
        for field in _git(repo, 'worktree', 'list', '--porcelain', '-z', optional=True).split(b'\0'):
            if field.startswith(b'worktree '):
                candidate = Path(os.fsdecode(field[len(b'worktree '):])).resolve()
                if candidate.is_relative_to(root):
                    registered.add(candidate)
    return sorted(registered)


def project_fingerprint(repo):
    """Hash Git-visible content, modes, symlink text and HEAD; never persist contents."""
    repo = Path(repo).resolve()
    names = set(_git(repo, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').split(b'\0'))
    entries = []
    for raw in sorted(names - {b''}):
        name = os.fsdecode(raw)
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid Git inventory path')
        path = repo / relative
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            entries.append([name, 'missing'])
            continue
        if stat.S_ISLNK(mode):
            content = ['symlink', os.readlink(path)]
        elif stat.S_ISREG(mode):
            content = ['file', file_hash(path)]
        elif stat.S_ISDIR(mode):
            content = ['gitlink', _git(path, 'rev-parse', '--verify', 'HEAD', optional=True).decode().strip()]
        else:
            raise ValueError('Unsupported special file in project inventory')
        entries.append([name, stat.S_IMODE(mode), content])
    head = _git(repo, 'rev-parse', '--verify', 'HEAD', optional=True).decode().strip()
    return digest({'head': head or 'unborn', 'files': entries})


def inspect_installation(manifest_path):
    """Validate a versioned receipt, source parity and every managed file digest."""
    manifest_path = Path(manifest_path)
    result = {'manifest': str(manifest_path), 'status': 'blocked', 'issues': []}
    try:
        manifest = json.loads(manifest_path.read_text())
        if not isinstance(manifest, dict) or manifest.get('schema_version') != 1:
            raise ValueError('Invalid installation manifest schema')
        source = manifest.get('source')
        managed = manifest.get('managed_files')
        source_files = manifest.get('source_files')
        if (not isinstance(source, dict) or not isinstance(source.get('path'), str)
                or not Path(source['path']).is_absolute()
                or not HASH.fullmatch(str(source.get('fingerprint', '')))
                or source.get('dirty') is not None and not isinstance(source.get('dirty'), bool)
                or not isinstance(source.get('revision'), (str, type(None)))
                or not isinstance(managed, dict) or not managed
                or not isinstance(source_files, dict) or not source_files):
            raise ValueError('Invalid or empty installation manifest inventory')
        runtime = manifest_path.parent.resolve()
        allowed = runtime.parent if runtime.name == 'sdlc-openai' else runtime
        required = {str(runtime / 'scripts' / name) for name in ('doctor.py', 'installation.py', 'project.py')}
        if not required.issubset(managed):
            raise ValueError('Installation manifest omits required runtime scripts')
        managed_identity = {}
        for name, expected in managed.items():
            path = Path(name)
            if (not path.is_absolute() or not path.is_relative_to(allowed)
                    or '..' in path.parts or not HASH.fullmatch(str(expected))):
                raise ValueError('Invalid managed file path or digest')
            if path.is_symlink():
                identity = {'link': os.readlink(path)}
            elif path.is_file():
                identity = {'sha256': file_hash(path), 'mode': stat.S_IMODE(path.stat().st_mode)}
            else:
                identity = {'missing': True}
            managed_identity[name] = identity
            if path.suffix == '.sh' and not os.access(path, os.X_OK):
                result['issues'].append('Installed shell asset is not executable: ' + name)
            if identity.get('sha256') != expected:
                result['issues'].append('Managed file missing or changed: ' + name)
        fragments = manifest.get('managed_fragments', {})
        if not isinstance(fragments, dict):
            raise ValueError('Invalid managed fragment inventory')
        for name, row in fragments.items():
            path = Path(name)
            if (not isinstance(row, dict) or row.get('kind') not in FRAGMENT_KINDS
                    or not HASH.fullmatch(str(row.get('sha256'))) or not path.is_absolute()
                    or not path.is_relative_to(allowed) or '..' in path.parts or name in managed):
                raise ValueError('Invalid managed fragment path, kind or digest')
            if path.is_symlink() or not path.is_file():
                identity = {'missing': True}
            else:
                try:
                    identity = {'sha256': digest_bytes(managed_fragment(row['kind'], path.read_bytes()))}
                except (ValueError, UnicodeError):
                    identity = {'invalid': True}
            managed_identity[name] = identity
            if identity.get('sha256') != row['sha256']:
                result['issues'].append('Installer-owned fragment missing or changed: ' + name)
        result['managed_fingerprint'] = digest(managed_identity)
        source_path = Path(source['path'])
        for name, expected in source_files.items():
            relative = Path(name)
            if (relative.is_absolute() or '..' in relative.parts or not name
                    or not HASH.fullmatch(str(expected))):
                raise ValueError('Invalid source file path or digest')
        current = source_snapshot(source_path)
        if current['fingerprint'] != source['fingerprint']:
            result['issues'].append('Framework source changed since installation')
        result.update(status='drifted' if result['issues'] else 'current',
                      source_fingerprint=current['fingerprint'], source_revision=current.get('revision'),
                      installed_fingerprint=source['fingerprint'])
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError):
        result['issues'].append('Installation receipt/source unavailable or invalid; install or inspect its manifest')
    return result


def hook_snippet_path(home):
    """The installed checkout's snippet when its receipt names one, else this checkout's."""
    candidates = []
    try:
        source = json.loads((Path(home) / '.claude/doctor-installation.json').read_text()).get('source', {})
        if isinstance(source, dict) and isinstance(source.get('path'), str):
            candidates.append(Path(source['path']) / 'settings/hooks-snippet.json')
    except (OSError, ValueError, AttributeError):
        pass
    candidates.append(Path(__file__).resolve().parents[1] / 'settings/hooks-snippet.json')
    return next((path for path in candidates if path.is_file()), candidates[-1])


def _hook_commands(document):
    """Yield (event, command) for every command hook, tolerating nothing but lists and dicts."""
    hooks = document.get('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('hooks is not an object')
    for event, groups in hooks.items():
        for group in groups if isinstance(groups, list) else []:
            for hook in group.get('hooks', []) if isinstance(group, dict) else []:
                if isinstance(hook, dict) and hook.get('type') == 'command' and isinstance(hook.get('command'), str):
                    yield event, hook['command']


def inspect_hook_registration(home, snippet=None):
    """Whether every snippet hook is registered in ~/.claude/settings.json.

    Matching follows scripts/merge-settings.sh: same event, same command string
    ($HOME spelled out or expanded, quoting aside). A file that cannot be read
    is its own status and never reads as registered.
    """
    home = Path(home)
    snippet = Path(snippet) if snippet else hook_snippet_path(home)
    settings = home / '.claude/settings.json'
    result = {'status': 'snippet-unavailable', 'settings': str(settings), 'missing': [], 'issues': []}
    try:
        wanted = list(_hook_commands(json.loads(snippet.read_text())))
        if not wanted:
            raise ValueError('snippet registers no hooks')
    except (OSError, ValueError, AttributeError):
        result['issues'].append('Hook registration unverified: framework hooks snippet unreadable: ' + str(snippet))
        return result
    if not settings.exists() and not settings.is_symlink():
        result['status'] = 'settings-missing'
        result['issues'].append('Hooks not registered: ' + str(settings) + ' does not exist')
        return result
    try:
        document = json.loads(settings.read_text())
        if not isinstance(document, dict):
            raise ValueError('settings is not an object')
        present = set(_hook_commands(document))
    except (OSError, ValueError, UnicodeError):
        result['status'] = 'settings-invalid'
        result['issues'].append('Hook registration unverified: ' + str(settings) + ' is unreadable or not a valid settings object')
        return result

    def canonical(command):
        for spelling in ('${HOME}', '$HOME'):
            command = command.replace(spelling, str(home))
        return ' '.join(command.replace('"', '').split())

    have = {(event, canonical(command)) for event, command in present}
    for event, command in wanted:
        if (event, canonical(command)) not in have:
            result['missing'].append({'event': event, 'command': command})
            result['issues'].append('Hooks not registered: ' + event + ': ' + command)
    result['status'] = 'not-registered' if result['missing'] else 'registered'
    return result


def with_hook_registration(row, hooks):
    """A Claude installation whose hooks are not switched on is not current."""
    row = dict(row, hooks=hooks, issues=list(row.get('issues', [])) + hooks['issues'])
    if hooks['status'] != 'registered' and row.get('status') == 'current':
        row['status'] = 'incomplete'
    return row


def dependency_inventory():
    """Locate required local executables without running them."""
    result = {}
    for name in ('python3.12', 'git', 'make', 'sh', 'bash', 'jq', 'shellcheck'):
        executable = shutil.which(name)
        result[name] = {'status': 'available' if executable else 'missing', 'path': executable}
    return result


def client_inventory(home):
    """Probe versions offline, retaining only parsed versions and hashed client/config identity."""
    home = Path(home)
    result = {}
    for name in ('codex', 'claude'):
        executable = shutil.which(name)
        row = {'status': 'blocked', 'version': None, 'fingerprint': None}
        if executable:
            try:
                response = subprocess.run([executable, '--version'], stdout=subprocess.PIPE,
                                          stderr=subprocess.DEVNULL, timeout=5)
                match = re.search(rb'\b\d+\.\d+(?:\.\d+)?(?:[-+][a-zA-Z0-9.]+)?\b', response.stdout)
                if response.returncode or not match:
                    raise ValueError('Client version unavailable')
                # Clients rewrite their own config files and owners edit them; only
                # the installer-owned fragments identify the client, never the whole file.
                config = {}
                fragments = ({'config.toml': 'codex-config', 'hooks.json': 'codex-hooks',
                              'AGENTS.md': 'codex-agents-block'} if name == 'codex'
                             else {'settings.json': 'claude-settings-hooks'})
                for filename, kind in fragments.items():
                    path = home / ('.' + name) / filename
                    if not path.is_file():
                        config[filename] = 'missing'
                        continue
                    try:
                        config[filename] = digest_bytes(managed_fragment(kind, path.read_bytes()))
                    except (ValueError, UnicodeError):
                        config[filename] = 'invalid'
                row.update(status='available', version=match.group().decode('ascii'),
                           fingerprint=digest({'binary': file_hash(Path(executable).resolve()),
                                               'version': match.group().decode('ascii'), 'config': config}))
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
        result[name] = row
    return result


def receipt_path(repo, state_dir):
    return Path(state_dir) / 'verification' / (digest(str(Path(repo).resolve())) + '.json')


def _valid_fingerprints(value):
    return (isinstance(value, dict) and set(value) == {'source', 'project', 'clients'}
            and all(isinstance(v, str) and HASH.fullmatch(v) for v in value.values()))


def read_receipt(repo, state_dir, fingerprints):
    """Do not upgrade stale, corrupt, interrupted, or failed evidence to a pass."""
    path = receipt_path(repo, state_dir)
    if not path.exists() and not path.is_symlink():
        return {'status': 'unverified', 'reason': 'No verification receipt'}
    try:
        if path.is_symlink():
            raise ValueError('Symlinked receipt')
        data = json.loads(path.read_text())
        if (not isinstance(data, dict) or data.get('schema_version') != 1
                or data.get('project') != str(Path(repo).resolve())
                or not _valid_fingerprints(data.get('fingerprints'))
                or data.get('status') not in ('passed', 'failed', 'blocked', 'unverified')
                or not isinstance(data.get('checks'), list)):
            raise ValueError('Invalid receipt schema')
        checks = data['checks']
        if data['status'] in ('passed', 'failed'):
            if not checks or len(checks) > 2:
                raise ValueError('Incomplete receipt')
            for index, item in enumerate(checks):
                if (not isinstance(item, dict) or item.get('command') != COMMANDS[index]
                        or type(item.get('exit_code')) is not int or type(item.get('timed_out')) is not bool
                        or not isinstance(item.get('duration_seconds'), (int, float))
                        or not math.isfinite(item['duration_seconds']) or item['duration_seconds'] < 0):
                    raise ValueError('Invalid command evidence')
            passed = len(checks) == 2 and all(c['exit_code'] == 0 and not c['timed_out'] for c in checks)
            if (data['status'] == 'passed') != passed:
                raise ValueError('Contradictory verification evidence')
        if data['fingerprints'] != fingerprints:
            return {'status': 'unverified', 'reason': 'Source, project or client fingerprint changed'}
        # Only whitelisted fields leave the receipt reader, never arbitrary stored text.
        return {'status': data['status'], 'checks': [
            {key: item[key] for key in ('command', 'exit_code', 'timed_out', 'duration_seconds')}
            for item in checks] if data['status'] in ('passed', 'failed') else [], 'reused': True}
    except (OSError, ValueError, KeyError, TypeError):
        return {'status': 'blocked', 'reason': 'Verification receipt is corrupt or invalid'}


def _save_receipt(path, data):
    path = Path(path)
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ValueError('Refusing symlinked receipt state')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.doctor-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, sort_keys=True)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run_checks(repo, timeout):
    """One total deadline, process-group cleanup and no captured or persisted output."""
    deadline = time.monotonic() + timeout
    checks = []
    for command in COMMANDS:
        start = time.monotonic()
        timed_out = False
        process = None
        try:
            process = subprocess.Popen(command, cwd=repo, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True,
                                       env={k: v for k, v in os.environ.items() if not k.startswith('GIT_')})
            code = process.wait(timeout=max(.001, deadline - start))
        except subprocess.TimeoutExpired:
            timed_out = True
            code = 124
        except OSError:
            code = 127
        finally:
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        checks.append({'command': command, 'exit_code': code, 'timed_out': timed_out,
                       'duration_seconds': round(time.monotonic() - start, 3)})
        if code:
            break
    return checks


def verify_project(repo, state_dir, fingerprints, timeout=870, current_fingerprints=None):
    """Invalidate old success before executing; mutation makes new evidence unusable."""
    if not _valid_fingerprints(fingerprints) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('Valid fingerprints and positive finite timeout are required')
    path = receipt_path(repo, state_dir)
    data = {'schema_version': 1, 'project': str(Path(repo).resolve()),
            'fingerprints': fingerprints, 'status': 'blocked', 'checks': [], 'created_at': time.time()}
    _save_receipt(path, data)
    before = project_fingerprint(repo)
    checks = run_checks(repo, timeout)
    data['checks'] = checks
    data['status'] = 'passed' if len(checks) == 2 and all(c['exit_code'] == 0 for c in checks) else 'failed'
    after = project_fingerprint(repo)
    if before != after or (current_fingerprints and current_fingerprints() != fingerprints):
        data['status'] = 'unverified'
    _save_receipt(path, data)
    return {'status': data['status'], 'checks': checks, 'reused': False}


def doctor(home, workspace=None, project_path=None, verify=False, timeout=870, state_dir=None):
    """Inspect both installations and project evidence without repairs or implicit tests."""
    home = Path(home).resolve()
    workspace = Path(workspace).resolve() if workspace else (Path(project_path).resolve().parent if project_path else None)
    state_dir = Path(state_dir or home / '.local/state/ainative-sdlc')
    manifests = {'codex': home / '.codex/sdlc-openai/doctor-installation.json',
                 'claude': home / '.claude/doctor-installation.json'}

    def inspect_installations():
        rows = {name: inspect_installation(path) for name, path in manifests.items()}
        rows['claude'] = with_hook_registration(rows['claude'], inspect_hook_registration(home))
        return rows

    installations = inspect_installations()
    clients = client_inventory(home)
    dependencies = dependency_inventory()
    routing = inspect_routing(home)
    report = {'status': 'unhealthy', 'workspace': str(workspace) if workspace else None, 'installations': installations,
              'clients': clients, 'dependencies': dependencies, 'routing': routing, 'projects': [], 'issues': [],
              'live_compatibility': {'status': 'unverified',
                                     'reason': 'Project checks do not certify live harness trust or compatibility'}}

    def context_fingerprints(repo, installs, client_rows):
        return {'source': digest({key: {field: row.get(field) for field in ('source_fingerprint', 'installed_fingerprint', 'managed_fingerprint', 'status', 'issues')} for key, row in installs.items()}),
                'clients': digest(client_rows), 'project': project_fingerprint(repo)}

    if verify and not project_path and workspace is None:
        report['issues'].append('Verification requires explicit --project or --workspace selection')
        return report
    try:
        roots = [Path(project_path).resolve()] if project_path else (discover(workspace) if workspace else [])
    except (OSError, ValueError):
        report['issues'].append('Workspace inventory unavailable')
        return report
    for repo in roots:
        row = {'project': str(repo), 'setup': {'setup_ready': False, 'issues': []},
               'verification': {'status': 'blocked', 'reason': 'Project inspection unavailable'}}
        try:
            if not repo.is_relative_to(workspace):
                raise ValueError('Project is outside requested workspace')
            row['setup'] = project_contract.inspect(repo, apply=False)
            fingerprints = context_fingerprints(repo, installations, clients)
            row['verification'] = read_receipt(repo, state_dir, fingerprints)
            if verify:
                if not row['setup']['setup_ready']:
                    row['verification'] = {'status': 'blocked', 'reason': 'Repair project check contract/setup before verification'}
                else:
                    def current():
                        return context_fingerprints(repo, inspect_installations(), client_inventory(home))
                    row['verification'] = verify_project(repo, state_dir, fingerprints, timeout, current)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            row['setup']['issues'].append('Project metadata, contract or fingerprint unavailable')
            row['verification'] = {'status': 'blocked', 'reason': 'Project inspection/verification could not finish'}
        report['projects'].append(row)
    if (project_path or workspace) and not report['projects']:
        # all([]) is True: an empty inventory must not read as every project passing.
        report['issues'].append('Nothing inspected: no repository found in ' + str(workspace))
    if (not report['issues'] and routing['status'] == 'current'
            and all(row['status'] == 'available' for row in dependencies.values())
            and all(row['status'] == 'current' for row in installations.values())
            and set(clients) == {'codex', 'claude'} and all(row['status'] == 'available' for row in clients.values())
            and all(row['setup']['setup_ready'] and row['verification']['status'] == 'passed' for row in report['projects'])):
        report['status'] = 'healthy'
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--workspace', type=Path)
    parser.add_argument('--project', type=Path)
    parser.add_argument('--verify', action='store_true', help='Explicitly run bounded make check then make test')
    parser.add_argument('--timeout', type=float, default=870, help='Total seconds per project, default 870')
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('--timeout must be a positive finite number')
    if args.verify and not args.workspace and not args.project:
        parser.error('--verify requires --project or --workspace')
    report = doctor(args.home, args.workspace, args.project, args.verify, args.timeout, args.state_dir)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print('Framework doctor: ' + report['status'])
        missing = [name for name, row in report['dependencies'].items() if row['status'] != 'available']
        print('  Local dependencies: ' + ('missing ' + ', '.join(missing) if missing else 'available'))
        for name, row in report['installations'].items():
            hooks = '; hooks ' + row['hooks']['status'] if isinstance(row.get('hooks'), dict) else ''
            print(f"  {name}: installation {row['status']}; client {report['clients'].get(name, {}).get('status', 'blocked')}{hooks}")
            for issue in row['issues']:
                print('    ' + issue)
        print('  Codex routing: ' + report['routing']['status'] + '; live selection unverified')
        for issue in report['routing']['issues']:
            print('    ' + issue)
        for row in report['projects']:
            print(f"  {row['project']}: setup {'ready' if row['setup']['setup_ready'] else 'needs attention'}; checks {row['verification']['status']}")
            for issue in row['setup'].get('issues', []):
                print('    ' + issue)
            if row['verification'].get('reason'):
                print('    ' + row['verification']['reason'])
        for issue in report['issues']:
            print('  ' + issue)
        print('  Live harness compatibility: unverified (requires separate real-client probes)')
    return 0 if report['status'] == 'healthy' else 1


if __name__ == '__main__':
    raise SystemExit(main())
