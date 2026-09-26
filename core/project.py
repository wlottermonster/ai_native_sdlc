#!/usr/bin/env python3.12
"""Inspect or safely enroll a project in the shared two-harness check contract.

This validates setup, not application correctness. Run real checks separately.
Existing project instructions and custom hooks are never overwritten.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def git(repo, *args, optional=False):
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    result = subprocess.run(['git', '-C', str(repo), *args], env=env,
                            capture_output=True, text=True, timeout=10)
    if optional and result.returncode == 1:
        return ""
    if result.returncode:
        raise ValueError('Git could not resolve project metadata: ' + ' '.join(args))
    return result.stdout.strip()


def no_symlinks(path):
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError('Refusing symlinked enrollment destination: ' + str(part))


def inspect(repo, apply=False):
    repo = Path(repo).resolve()
    top = Path(git(repo, 'rev-parse', '--show-toplevel')).resolve()
    if top != repo:
        raise ValueError('Use the project root: ' + str(top))
    template = Path(__file__).resolve().parent / 'templates/pre-commit'
    if not template.exists():  # installed scripts/ lives next to templates/
        template = Path(__file__).resolve().parent.parent / 'templates/pre-commit'
    expected = template.read_bytes()
    issues = []
    if git(repo, 'config', '--get', 'core.hooksPath', optional=True):
        issues.append('Configured core.hooksPath preserved; integrate the check hook manually')
    make = repo / 'Makefile'
    no_symlinks(make)
    if not make.is_file():
        issues.append('Missing Makefile: add real check and test recipes before enrollment')
    else:
        text = make.read_text()
        for name in ('check', 'test'):
            if not re.search(r'^' + name + r'\s*:(?!=)', text, re.M):
                issues.append('Makefile must explicitly declare ' + name + ' target')
    writes = {}
    for name in ('AGENTS.md', 'CLAUDE.md'):
        path = repo / name
        no_symlinks(path)
        if path.exists() and (not path.is_file() or not path.read_text().strip()):
            issues.append(name + ' is not a readable nonempty instruction file')
    for name in ('AGENTS.override.md', 'CLAUDE.local.md'):
        if (repo / name).exists():
            issues.append(name + ' requires manual review before automatic enrollment')
    if not (repo / 'AGENTS.md').exists():
        reference = ('Read CLAUDE.md for existing project/domain constraints; its Claude-specific\n'
                     'routing applies only to Claude.\n') if (repo / 'CLAUDE.md').exists() else (
                     'Read README.md and relevant source before changes; record verified project\n'
                     'architecture, protected paths and deployment behavior as they are discovered.\n')
        writes[repo / 'AGENTS.md'] = ('# Project instructions\n\n' + reference +
            '\nEach harness uses its own installed global policy and model routing.\n'
            'Run make check and make test before completion; setup inspection is not a test pass.\n'
            'Concurrent sessions require separate branches, worktrees, ports and test data.\n'
            'Preserve unfinished work. Never include credentials in logs or handoffs.\n').encode()
    if not (repo / 'CLAUDE.md').exists():
        writes[repo / 'CLAUDE.md'] = b'@AGENTS.md\n'
    hook = Path(git(repo, 'rev-parse', '--git-path', 'hooks/pre-commit'))
    if not hook.is_absolute():
        hook = repo / hook
    no_symlinks(hook)
    # Only the exact shipped previous mirror is owned by this updater.
    legacy_hashes = {'598bb8c3f14b5dcc9b457d9a14322add6cf5675635b66d5309e6f60abb2d7456', 'be10471d63cf8e42e541e48f7a8c140d019d0f2a637d8adb7b74c861e718ee77', 'ba91761e7aba48ec2f8b49b0d57ee192dcc274357d30d3ea51f136a4ceabdd64', '83361d4ca31db3cecb95adb91d8563abeed7a478c3f4a891ab25e036f4ea63ed'}
    if hook.exists() and hook.read_bytes() != expected and hashlib.sha256(hook.read_bytes()).hexdigest() not in legacy_hashes:
        issues.append('Custom pre-commit hook preserved; integrate make check explicitly: ' + str(hook))
    elif not hook.exists() or hook.read_bytes() != expected or not os.access(hook, os.X_OK):
        writes[hook] = expected
    if apply and not issues:
        for path, data in writes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        if hook in writes:
            hook.chmod(0o755)
    pending = [str(p.relative_to(repo)) if p.is_relative_to(repo) else str(p) for p in writes]
    return {'repo': str(repo), 'setup_ready': not issues and (apply or not writes),
            'issues': issues, 'applied' if apply and not issues else 'pending': pending,
            'checks_executed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        result = inspect(args.repo, args.apply)
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({'setup_ready': False, 'issues': [str(exc)], 'checks_executed': False}))
        sys.exit(1)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result['setup_ready'] else 1)
