#!/usr/bin/env python3.12
"""Refresh a staging copy of the Codex settings and framework source for backup.

The staging directory defaults to ~/.local/state/ainative-sdlc/backup-staging and
can be moved with SDLC_BACKUP_STAGING_DIR. When SDLC_BACKUP_SCRIPT names an
executable, it runs after staging so an existing (for example encrypted) backup
routine can pick the stage up; without it, the stage is refreshed and its path
printed. No settings content is ever printed.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile


DEFAULT_STAGING = '.local/state/ainative-sdlc/backup-staging'


def stage(home, parent=None):
    home = Path(home)
    parent = Path(parent) if parent else home / DEFAULT_STAGING
    staging = parent / 'openai-sdlc'
    for path in (parent, staging):
        if path.is_symlink():
            raise ValueError(f'Refusing symlinked backup staging path: {path}')
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    codex = home / '.codex'
    metadata = json.loads((codex / 'sdlc-openai/installation.json').read_text())
    source_root = Path(metadata['source'])
    if not (source_root / 'install.sh').is_file():
        raise ValueError('Installed source metadata does not identify the framework checkout')
    # Build the whole replacement before moving the previous stage. A failed
    # copy leaves the previous complete stage in place. Never print file data.
    pending = Path(tempfile.mkdtemp(prefix='.openai-sdlc-pending-', dir=parent))
    previous = None
    try:
        for name in ('AGENTS.md', 'config.toml', 'hooks.json'):
            shutil.copy2(codex / name, pending / name)
            (pending / name).chmod(0o600)
        for name, source in (
            ('runtime', codex / 'sdlc-openai'),
            ('skill', codex / 'skills/openai-sdlc'),
            ('source', source_root),
        ):
            shutil.copytree(source, pending / name, ignore=shutil.ignore_patterns(
                '.git', '__pycache__', '.sdlc-openai', '.DS_Store', '*.pyc'))
        # The pre-migration OpenAI source archive is the rollback record for the
        # folder being retired. Keep that one artifact even though ordinary local
        # run state remains excluded from backup staging.
        archive = source_root / '.sdlc-openai/step5-original-openai.tar.gz'
        if archive.is_file():
            destination = pending / 'source/.sdlc-openai/step5-original-openai.tar.gz'
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(archive, destination)
        if staging.exists():
            previous = Path(tempfile.mkdtemp(prefix='.openai-sdlc-previous-', dir=parent))
            previous.rmdir()
            staging.rename(previous)
        try:
            pending.rename(staging)
        except BaseException:
            if previous is not None:
                previous.rename(staging)
            raise
    except BaseException:
        if pending.exists():
            shutil.rmtree(pending)
        raise
    # Retain the previous complete staging snapshot for inspection/recovery.
    return staging


def main():
    os.umask(0o077)
    home = Path.home()
    parent = os.environ.get('SDLC_BACKUP_STAGING_DIR') or None
    staging = stage(home, parent)
    print(f'Refreshed Codex settings and framework backup staging at {staging}', flush=True)
    script = os.environ.get('SDLC_BACKUP_SCRIPT')
    if not script:
        print('SDLC_BACKUP_SCRIPT is not set; staged only, nothing backed up.', flush=True)
        return 0
    return subprocess.run([script]).returncode


if __name__ == '__main__':
    raise SystemExit(main())
