"""REQ-DUAL-003: native tool protection under active project night locks."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'adapters/codex/scripts/protected_paths.py'
spec = importlib.util.spec_from_file_location('protected_paths', SOURCE)
guards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guards)


class ProtectedPathsTests(unittest.TestCase):
    """REQ-DUAL-003 uses disposable repositories; never changes real locks."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ws = Path(self.temp.name)
        self.repo = self.ws / 'umbrella'
        self.repo.mkdir()
        (self.repo / '.git').mkdir()

    def lock(self, root=None, generic=False, manifest=True):
        root = root or self.repo
        folder = root / ('.sdlc' if generic else '.claude')
        folder.mkdir(exist_ok=True)
        (folder / ('night-lock' if generic else '.night-lock')).touch()
        if manifest:
            path = folder / ('protected-paths.txt' if generic else 'hooks/no_fix_zones.txt')
            path.parent.mkdir(exist_ok=True)
            path.write_text('# fixture\nsecret/**\n!secret/public.txt\n')

    def payload(self, tool, command, cwd=None, **extra):
        return {'cwd': str(cwd or self.repo), 'tool_name': tool,
                'tool_input': {'command': command, **extra}}

    def patch(self, target, cwd=None):
        return self.payload('apply_patch', f'*** Begin Patch\n*** Add File: {target}\n+hello\n*** End Patch', cwd)

    def denied(self, payload):
        self.assertIsInstance(guards.guard(payload, self.ws), str)

    def allowed(self, payload):
        self.assertIsNone(guards.guard(payload, self.ws))

    def test_REQ_DUAL_003_unlocked(self):
        self.allowed(self.patch('secret/file'))
        self.allowed(self.payload('Bash', 'python -c "anything"'))

    def test_REQ_DUAL_003_other_tools_are_unaffected_without_a_lock(self):
        payload = {'cwd': str(self.repo), 'tool_name': 'functions.exec', 'tool_input': 'text(1)'}
        self.allowed(payload)
        self.lock()
        self.denied(payload)

    def test_REQ_DUAL_003_native_patch_exceptions(self):
        self.lock()
        self.denied(self.patch('secret/file'))
        self.allowed(self.patch('secret/public.txt'))
        self.allowed(self.patch('src/new.py'))

    def test_REQ_DUAL_003_update_delete_move(self):
        self.lock()
        for header in ['*** Delete File: secret/file',
                       '*** Update File: secret/file\n@@\n-old\n+new',
                       '*** Update File: src/file\n*** Move to: secret/file\n@@\n-old\n+new',
                       '*** Update File: secret/file\n*** Move to: src/file\n@@\n-old\n+new']:
            self.denied(self.payload('apply_patch', f'*** Begin Patch\n{header}\n*** End Patch'))

    def test_REQ_DUAL_003_malformed_patch(self):
        self.lock()
        for patch in ['', 'arbitrary', '*** Begin Patch\n*** Add File: src/a\n+hi',
                      '*** Begin Patch\n*** Unknown: secret/a\n*** End Patch',
                      '*** Begin Patch\n*** Add File: \n+x\n*** End Patch']:
            self.denied(self.payload('apply_patch', patch))

    def test_REQ_DUAL_003_shell_allowlist(self):
        self.lock()
        for command in ['pwd', 'ls -la', 'cat README.md', 'rg --no-config --files', 'git status --short',
                        'git diff --no-ext-diff --no-textconv -- src/a']:
            self.allowed(self.payload('Bash', command))
        for command in ['echo x > secret/a', 'python -c "print(1)"', 'rm src/a',
                        'cat README > secret/a', 'ls; touch secret/a', 'cat $(touch secret/a)',
                        'git -c core.pager=evil status', 'sed -i x src/a', 'rg --pre evil x',
                        'git diff --ext-diff', 'git diff --no-ext-diff', 'rg --files', 'cat <(touch secret/a)', 'env ls', 'unknown']:
            self.denied(self.payload('Bash', command))

    def test_REQ_DUAL_003_unknown_or_invalid_payload(self):
        self.lock()
        self.denied(self.payload('unknown_tool', 'read'))
        for payload in [None, {}, {'cwd': str(self.repo)},
                        {'cwd': str(self.repo), 'tool_name': 'apply_patch', 'tool_input': []}]:
            self.denied(payload)

    def test_REQ_DUAL_003_generic_manifest_and_self_protection(self):
        self.lock(generic=True)
        for target in ['secret/a', '.sdlc/night-lock', '.codex/config.toml', '.claude/settings.json']:
            self.denied(self.patch(target))

    def test_REQ_DUAL_003_case_and_basename_patterns(self):
        self.lock()
        manifest = self.repo / '.claude/hooks/no_fix_zones.txt'
        manifest.write_text('secret/**\n.env\n*.key\n')
        for target in ['SECRET/a', 'src/.env', 'src/private.key', '.CLAUDE/settings.json']:
            self.denied(self.patch(target))

    def test_REQ_DUAL_003_missing_manifest(self):
        self.lock(manifest=False)
        self.denied(self.patch('src/a'))
        self.denied(self.payload('Bash', 'ls'))

    def test_REQ_DUAL_003_nested_roots(self):
        nested = self.repo / 'child'
        nested.mkdir()
        (nested / '.git').write_text('gitdir: elsewhere')
        self.lock(nested)
        self.denied(self.patch('child/secret/a'))
        self.denied(self.patch('.claude/settings.json'))
        self.denied(self.payload('Bash', 'python run.py'))
        self.allowed(self.patch('src/a'))
        self.denied(self.patch('secret/a', nested))
        self.allowed(self.patch('src/a', nested))
        self.denied(self.patch('../.codex/config.toml', nested))

    def test_REQ_DUAL_003_unlocked_nested_with_locked_parent(self):
        self.lock()
        nested = self.repo / 'child'
        nested.mkdir()
        (nested / '.git').mkdir()
        self.denied(self.patch('../secret/a', nested))
        self.allowed(self.patch('src/a', nested))

    def test_REQ_DUAL_003_workdir_and_cmd(self):
        self.lock()
        sub = self.repo / 'src'
        sub.mkdir()
        self.denied(self.payload('apply_patch', '*** Begin Patch\n*** Add File: ../secret/a\n+x\n*** End Patch', workdir=str(sub)))
        self.denied({'cwd': str(self.repo), 'tool_name': 'exec_command',
                     'tool_input': {'cmd': 'echo x > secret/a'}})

    def test_REQ_DUAL_003_path_escapes_and_symlinks(self):
        self.lock()
        (self.repo / 'secret').mkdir()
        (self.repo / 'shortcut').symlink_to(self.repo / 'secret', target_is_directory=True)
        self.denied(self.patch('shortcut/a'))
        (self.repo / 'secret/sub').mkdir()
        (self.repo / 'deep-link').symlink_to(self.repo / 'secret/sub', target_is_directory=True)
        self.denied(self.patch('deep-link/../a'))
        self.denied(self.patch('../outside'))
        (self.repo / 'outside-link').symlink_to(self.ws / 'outside', target_is_directory=True)
        self.denied(self.patch('outside-link/a'))

    def test_REQ_DUAL_003_explicit_other_root(self):
        other = self.ws / 'other'
        other.mkdir()
        (other / '.git').mkdir()
        self.lock(other)
        self.denied(self.patch(str(other / 'secret/a')))
        self.denied(self.payload('Bash', f'echo x > {other}/secret/a'))
        self.denied(self.payload('Bash', 'echo x > ../other/secret/a'))


if __name__ == '__main__':
    unittest.main()
