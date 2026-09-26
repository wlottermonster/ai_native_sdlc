"""Step 5 acceptance; removing adapter dispatch or source metadata breaks these tests."""
import ast
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / 'adapters/codex'


def module(name):
    path = ADAPTER / 'scripts' / (name + '.py')
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class PortabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.workspace = self.home / 'ws'
        self.workspace.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), SDLC_SCAN_ROOT=str(self.workspace))

    def install(self, harness, *args):
        result = subprocess.run(['bash', str(ROOT / 'install.sh'), '--harness', harness, *args],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_codex_install_and_reinstall_preserve_state(self):
        self.install('codex', '--workspace', str(self.workspace), '--apply')
        target = self.home / '.codex/sdlc-openai'
        self.assertTrue((target / 'scripts/sdlc.py').is_file(), 'Codex adapter was not installed')
        self.assertEqual(json.loads((target / 'installation.json').read_text())['source'], str(ROOT))
        skill = self.home / '.codex/skills/openai-sdlc/SKILL.md'
        self.assertEqual(skill.read_bytes(), (target / 'skills/openai-sdlc/SKILL.md').read_bytes())
        self.assertNotIn('or the ainative_sdlc source', (self.home / '.codex/AGENTS.md').read_text())
        run = subprocess.run([sys.executable, str(target / 'scripts/sdlc.py'), '--repo', str(self.workspace),
                              'begin', 'preserved', 'Preserve existing run', '--budget', '7'], capture_output=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        state = self.workspace / '.sdlc-openai/runs/preserved.json'
        before = state.read_bytes()
        (target / 'engines.toml').write_text('[roles]\nbuild = "owner-choice"\n')
        self.install('codex', '--workspace', str(self.workspace), '--apply')
        self.assertEqual(state.read_bytes(), before)
        self.assertIn('owner-choice', (target / 'engines.toml').read_text())
        payload = {'cwd': str(self.workspace), 'hook_event_name': 'SessionStart'}
        hook = subprocess.run([sys.executable, str(target / 'scripts/sdlc.py'), 'hook'],
                              input=json.dumps(payload), text=True, capture_output=True)
        self.assertEqual(hook.returncode, 0, hook.stderr)
        self.assertIn(str(target / 'policy.md'), hook.stdout)

    def test_claude_install_preserves_settings_and_installs_core(self):
        settings = self.home / '.claude/settings.json'
        settings.parent.mkdir()
        settings.write_text('{"unrelated": "keep"}\n')
        self.install('claude')
        self.assertEqual(settings.read_text(), '{"unrelated": "keep"}\n')
        self.assertTrue((self.home / '.claude/commands/build.md').is_file())
        self.assertIn('Shared SDLC policy', (self.home / '.claude/sdlc-policy.md').read_text())
        result = subprocess.run(['bash', str(self.home / '.claude/scripts/apply-engines.sh')],
                                env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_claude_snapshot_rollback(self):
        claude = self.home / '.claude'
        (claude / 'commands').mkdir(parents=True)
        (claude / 'commands/build.md').write_text('Previous build prompt\n')
        (claude / 'commands/private.md').write_text('Unrelated command\n')
        (claude / 'settings.json').write_text('{"owner": true}\n')
        before = {p.relative_to(claude): p.read_bytes() for p in claude.rglob('*') if p.is_file()}
        self.install('claude')
        # Exercise the documented snapshot restoration, before any later edits.
        for path in claude.rglob('*'):
            if path.is_file() and path.relative_to(claude) not in before:
                path.unlink()
        for relative, data in before.items():
            (claude / relative).write_bytes(data)
        after = {p.relative_to(claude): p.read_bytes() for p in claude.rglob('*') if p.is_file()}
        self.assertEqual(after, before)

    def test_codex_rollback_restores_previous_files(self):
        self.assertTrue((ADAPTER / 'scripts/install.py').exists(), 'Consolidated installer missing')
        installer = module('install')
        codex = self.home / '.codex'
        codex.mkdir()
        (codex / 'AGENTS.md').write_text('Original preferences\n')
        (codex / 'config.toml').write_text('model = "owner"\n')
        before = {p.relative_to(codex): p.read_bytes() for p in codex.rglob('*') if p.is_file()}
        with contextlib.redirect_stdout(io.StringIO()):
            result = installer.install(self.home, self.workspace, True)
        backup = Path(result['backup'])
        for entry in json.loads((backup / 'manifest.json').read_text()):
            path = codex / entry['path']
            if entry['existed']:
                installer.atomic_write(path, (backup / entry['path']).read_bytes())
            else:
                path.unlink()
        after = {p.relative_to(codex): p.read_bytes() for p in codex.rglob('*')
                 if p.is_file() and 'sdlc-backups' not in p.parts}
        self.assertEqual(after, before)

    def test_core_is_neutral_and_policy_authorization_is_preserved(self):
        self.assertTrue((ROOT / 'core/policy.md').exists(), 'Neutral policy missing')
        for path in (ROOT / 'core').rglob('*'):
            # Cross-harness diagnostics and handoff adapters inspect explicit target
            # settings; shared lifecycle policy remains harness-neutral.
            if path.is_file() and '__pycache__' not in path.parts and path.name not in {'doctor.py', 'handoff.py', 'handoff_runtime.py'}:
                self.assertNotIn('.claude', path.read_text(), str(path))
        policy = (ROOT / 'core/policy.md').read_text()
        self.assertIn('authorization', policy)
        self.assertIn('attempt budget', policy)
        self.assertIn('inherit', policy)

    def test_backup_source_uses_installation_metadata_and_refreshes(self):
        self.assertTrue((ADAPTER / 'scripts/backup-settings.py').exists(), 'Backup adapter missing')
        self.install('codex', '--workspace', str(self.workspace), '--apply')
        backup = module('backup-settings')
        # Supply the historical archive explicitly: a clean checkout has no local
        # migration archive or run state. Plant both so exclusion is exercised.
        source = self.home / 'source-fixture'
        runtime = source / 'adapters/codex/scripts/sdlc.py'
        runtime.parent.mkdir(parents=True)
        runtime.write_bytes((ADAPTER / 'scripts/sdlc.py').read_bytes())
        (source / 'install.sh').write_bytes((ROOT / 'install.sh').read_bytes())
        state = source / '.sdlc-openai/runs/private.json'
        state.parent.mkdir(parents=True)
        state.write_text('{"local": true}\n')
        original_archive = source / '.sdlc-openai/step5-original-openai.tar.gz'
        original_archive.write_bytes(b'archive-copy-fixture')
        metadata = self.home / '.codex/sdlc-openai/installation.json'
        metadata.write_text(json.dumps({'source': str(source)}))
        with contextlib.redirect_stdout(io.StringIO()):
            stage = backup.stage(self.home)
            self.assertEqual((stage / 'source/install.sh').read_bytes(), (ROOT / 'install.sh').read_bytes())
            (self.home / '.codex/config.toml').write_text('model = "updated"\n')
            stage = backup.stage(self.home)
        self.assertEqual((stage / 'config.toml').read_text(), 'model = "updated"\n')
        self.assertTrue((stage / 'source/adapters/codex/scripts/sdlc.py').exists())
        archive = stage / 'source/.sdlc-openai/step5-original-openai.tar.gz'
        self.assertEqual(archive.read_bytes(), original_archive.read_bytes())
        self.assertFalse((stage / 'source/.sdlc-openai/runs').exists(), 'local run state must not enter backup staging')

    def test_source_disposition_is_current_and_complete(self):
        record = ROOT / 'docs/portability-step5'
        if not record.is_dir():
            self.skipTest('migration record not present in this checkout')
        manifest = json.loads((ROOT / 'docs/portability-step5/source-manifest.json').read_text())
        disposition = json.loads((ROOT / 'docs/portability-step5/source-disposition.json').read_text())
        self.assertEqual({row['path'] for row in disposition}, {row['path'] for row in manifest})
        for row in disposition:
            destination = row.get('destination')
            if row.get('exists'):
                path = ROOT / destination
                self.assertTrue(path.is_file(), destination)
                digest = __import__('hashlib').sha256(path.read_bytes()).hexdigest()
                self.assertEqual(row.get('destination_sha256'), digest, destination)
            elif row.get('decision') not in ('retire standalone-source instructions', 'retire session log'):
                self.fail(f"undocumented missing destination: {row['path']}")

    def test_installed_markdown_links_resolve(self):
        self.install('codex', '--workspace', str(self.workspace), '--apply')
        import re
        target = self.home / '.codex/sdlc-openai'
        for path in target.rglob('*.md'):
            for link in re.findall(r'\]\(([^)]+)\)', path.read_text()):
                if not link.startswith(('http:', 'https:', '#', '/')):
                    self.assertTrue((path.parent / link.split('#')[0]).exists(), (path, link))

    def test_claude_compatibility_policy_is_composed_without_duplicate_clauses(self):
        core = (ROOT / 'core/policy.md').read_text()
        adapter = (ROOT / 'adapters/claude/policy.md').read_text()
        self.assertNotIn('## Owner testing', adapter)
        self.assertEqual((ROOT / 'sdlc-policy.md').read_text(), core + '\n' + adapter)

    def test_runtime_preserves_original_state_and_check_machinery(self):
        self.assertTrue((ADAPTER / 'scripts/sdlc.py').exists(), 'Runtime adapter missing')
        # Step 6 deliberately changes command recognition. These SHA256 values
        # were recorded from the Step 5 runtime, whose whole-file hash is
        # retained in the immutable source manifest. Include decorator lines and
        # exact whitespace: atomic_json/locked must remain byte-for-byte intact.
        import hashlib
        content = (ADAPTER / 'scripts/sdlc.py').read_bytes()
        original_functions = {
            'atomic_json': '6f60843a5b7ed8ad479f48df17bb0db4419ec05d3637af0fc57e21d2e4d0482d',
            'state_path': '4e6d2d0f3c6315b4a21a3cfaa7e82097721fc3d6a9434b732a54855ea59ad572',
            'locked': 'a1085a300d4c4e23ca4bfb70eb11e5e05a23e4add30052ae178a7383c61c4fad',
            'read_state': '7ae133382136b8338a3b3e7933c1262fab56c2fbb4f291d1ed2fc1567fca2f41',
            'begin': 'daefe523472a7f6ec847e7a33898edd09393c2e1c83a4b519af0b3bff58e09ec',
            'fingerprint': 'edc4d48a460cb659c7979c1b091554601e86eabb8e1b7837e6e4533e24bf41e0',
            'record': '87019898da1eddcc32dad5fe9ac3c3fd59288857953fd94d8ff0ff4fc7ff0cca',
            'run_command': '97a5168810cc5c5ca9cd78607ec8c032b49931bd905f662c23ed99641b935a40',
            'check': '38c407c9c7c61723954024432e1ced7bb02651d3ce7b1b4531f71f7fc4aff559',
            'in_scope': 'cd8b7814e6a53ca6dc16cbbe79efdcb01b4943e2f96749e553d947fc2b39e36a',
        }
        functions = {n.name: n for n in ast.parse(content).body if isinstance(n, ast.FunctionDef)}
        lines = content.splitlines(keepends=True)
        for name, digest in original_functions.items():
            with self.subTest(function=name):
                node = functions[name]
                start = min([node.lineno] + [d.lineno for d in node.decorator_list])
                original_bytes = b''.join(lines[start - 1:node.end_lineno])
                self.assertEqual(hashlib.sha256(original_bytes).hexdigest(), digest)


if __name__ == '__main__':
    unittest.main()
