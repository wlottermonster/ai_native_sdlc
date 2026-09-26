"""Conservative PreToolUse night-lock guard (REQ-DUAL-003).

Hooks are an accidental-edit guard, not a sandbox. Arbitrary shell code cannot
be statically proved safe: under a relevant lock only a small read-only command
set is accepted. Use native apply_patch for permitted writes. Git read commands
assume trusted repository config (as do installed hooks themselves). Discovery
walks ancestors and immediate nested repository roots, never the whole workspace.
"""
import fnmatch
import os
from pathlib import Path
import re
import shlex


class GuardError(ValueError):
    pass


def _path(value, base):
    if not isinstance(value, str) or not value.strip() or '\x00' in value:
        raise GuardError('invalid path')
    return base / value


def _ancestors(path, workspace):
    return [p for p in [path, *path.parents] if p == workspace or workspace in p.parents]


def _repository(path):
    return any(os.path.lexists(path / name) for name in ('.git', '.claude', '.sdlc'))


def _roots(paths, workspace):
    roots = set()
    for path in paths:
        for parent in _ancestors(path, workspace):
            if parent != workspace and _repository(parent):
                roots.add(parent)
    # Umbrellas declare immediate nested repositories; don't traverse data trees.
    for root in list(roots):
        for child in root.iterdir():
            if not child.name.startswith('.') and child.is_dir() and _repository(child):
                roots.add(child)
    return roots


def _present(path):
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False


def _zones(root):
    result = []
    pairs = [('.claude/.night-lock', '.claude/hooks/no_fix_zones.txt'),
             ('.sdlc/night-lock', '.sdlc/protected-paths.txt')]
    for lock, manifest in pairs:
        if not _present(root / lock):
            continue
        lines = (root / manifest).read_text().splitlines()
        patterns = []
        for line in lines:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            pattern = line.removeprefix('!').removeprefix('./').rstrip('/')
            if not pattern or pattern.startswith('/') or '..' in Path(pattern).parts:
                raise GuardError('invalid protected-path manifest')
            patterns.append(('!' if line.startswith('!') else '') + pattern)
        if not any(not p.startswith('!') for p in patterns):
            raise GuardError('empty protected-path manifest')
        result.append(patterns)
    return result


def _patch_paths(command):
    if not isinstance(command, str):
        raise GuardError('native patch command is missing')
    lines = command.splitlines()
    if len(lines) < 3 or lines[0] != '*** Begin Patch' or lines[-1] != '*** End Patch':
        raise GuardError('malformed native patch')
    paths = []
    mode = None
    moved = False
    for line in lines[1:-1]:
        match = re.fullmatch(r'\*\*\* (Add|Update|Delete) File: (.+)', line)
        if match:
            mode = match[1]
            paths.append(match[2])
            moved = False
        elif line.startswith('*** Move to: ') and mode == 'Update' and not moved:
            paths.append(line[len('*** Move to: '):])
            moved = True
        elif mode == 'Add' and line.startswith('+'):
            continue
        elif mode == 'Update' and (line.startswith((' ', '+', '-', '@@')) or line == '*** End of File'):
            continue
        else:
            raise GuardError('malformed native patch body')
    if not paths or any(not p.strip() for p in paths):
        raise GuardError('native patch has no valid targets')
    return paths


def _read_only(command):
    if not isinstance(command, str) or re.search(r'[\n\r;&|<>`$(){}\\]', command):
        return False
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    if not words:
        return False
    binary, args = words[0], words[1:]
    # No path-qualified binaries, wrappers, substitutions or arbitrary programs.
    if binary == 'pwd':
        return all(arg in ('-L', '-P') for arg in args)
    if binary == 'ls':
        return all(not a.startswith('-') or re.fullmatch(r'-[laAdFhRrtuS1]+', a) for a in args)
    if binary == 'cat':
        return all(not a.startswith('-') or a in ('-n', '-b', '-s', '-v', '-e', '-t', '--') for a in args)
    if binary == 'rg' and '--no-config' in args:
        return all(not a.startswith('-') or a in ('--no-config', '--files', '--hidden', '-n', '-l', '-i', '-S', '-F', '-e', '-g', '--glob', '--') for a in args)
    if binary == 'git' and args:
        if args[0] == 'status':
            return all(a in ('--short', '-s', '--porcelain', '--branch', '-b', '--untracked-files=no') for a in args[1:])
        if args[0] == 'diff' and '--no-ext-diff' in args and '--no-textconv' in args:
            return all(not a.startswith('-') or a in ('--no-ext-diff', '--no-textconv', '--stat', '--name-only', '--cached', '--staged', '--') for a in args[1:])
    return False


def _matches(path, patterns):
    def match(pattern):
        pieces = [path, *[str(p) for p in Path(path).parents if str(p) != '.']]
        if '/' not in pattern:
            pieces.extend(Path(path).parts)
        return any(fnmatch.fnmatchcase(piece.casefold(), pattern.casefold()) for piece in pieces)
    return any(match(p) for p in patterns if not p.startswith('!')) and not any(
        match(p[1:]) for p in patterns if p.startswith('!'))


def guard(payload, workspace):
    """Return a denial reason, or None. Never execute commands from the payload."""
    try:
        workspace = Path(workspace).resolve()
        if not isinstance(payload, dict):
            raise GuardError('invalid tool payload')
        cwd = _path(payload.get('cwd'), workspace).resolve()
        tool_input = payload.get('tool_input')
        invalid_input = not isinstance(tool_input, dict)
        if invalid_input:
            tool_input = {}
        base = _path(tool_input.get('workdir', str(cwd)), cwd).resolve()
        tool = payload.get('tool_name')
        command = tool_input.get('command', tool_input.get('cmd'))
        paths = []
        patch_error = None
        if tool == 'apply_patch':
            try:
                paths = [_path(p, base) for p in _patch_paths(command)]
            except GuardError as error:
                patch_error = error
        candidates = [cwd, base, *paths]
        if tool in ('Bash', 'exec_command', 'shell_command') and isinstance(command, str):
            try:
                lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
                lexer.whitespace_split = True
                tokens = list(lexer)
                candidates.extend(_path(token, base) for token in tokens if '/' in token)
            except ValueError:
                pass  # A relevant lock will deny malformed shell syntax below.
        candidates += [p.resolve() for p in candidates]
        roots = _roots(candidates, workspace)
        locks = {root: zones for root in roots if (zones := _zones(root))}
        if not locks:
            return None
        if invalid_input:
            raise GuardError('invalid tool input while a night lock is active')
        if patch_error:
            raise patch_error
        if tool in ('Bash', 'exec_command', 'shell_command'):
            if _read_only(command):
                return None
            raise GuardError('shell command cannot be proved read-only while a night lock is active; use native apply_patch for allowed edits')
        if tool != 'apply_patch':
            raise GuardError('unknown tool while a night lock is active')
        for path in paths:
            for target in (path, path.resolve()):
                if not any(target == root or root in target.parents for root in roots):
                    raise GuardError('patch target escapes discovered project roots')
                for root, manifests in locks.items():
                    for ancestor in _ancestors(root, workspace):
                        if ancestor == workspace:
                            continue
                        if target == ancestor or ancestor in target.parents:
                            relative = target.relative_to(ancestor)
                            if relative.parts and relative.parts[0].casefold() in ('.claude', '.codex', '.sdlc'):
                                raise GuardError('night-lock configuration is protected')
                    if target == root or root in target.parents:
                        relative = target.relative_to(root).as_posix()
                        if any(_matches(relative, patterns) for patterns in manifests):
                            raise GuardError('patch target matches night-lock protected paths')
        return None
    except (OSError, RuntimeError, ValueError, TypeError) as error:
        return f'Protected-path guard denied: {error}'
