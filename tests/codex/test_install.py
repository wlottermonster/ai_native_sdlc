import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import contextlib
import io
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2] / 'adapters/codex'
OPT_IN = 'SDLC_MIGRATE_LEGACY_SECTIONS'


def legacy_file(mod, *tail):
    """A pre-release AGENTS.md: the recognised legacy headings, neutral bodies."""
    return ''.join([
        '# Owner\n',
        f'{mod.LEGACY_POLICY_HEADING} — legacy model policy\n\n',
        f'{mod.LEGACY_ENTRY_BULLET}: old entry point note.\n',
        '- Vendor A model retired.\n',
        '- Vendor B model local only.\n\n',
        f'{mod.LEGACY_ROUTING_HEADING} — legacy routing\n',
        'Legacy routing body.\n\n',
        *tail,
    ])


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.codex = self.home / '.codex'
        self.codex.mkdir()
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)
        self.claude = self.home / '.claude'
        self.claude.mkdir()
        (self.claude / 'settings.json').write_text('CLAUDE SENTINEL')
        (self.codex / 'AGENTS.md').write_text('# Personal\nKeep my preferences.\n\n### Asking questions\nUse options.\n')
        (self.codex / 'config.toml').write_text('model = "my-model"\n[desktop]\nexternal-agent-import-sync-enabled = true\n[custom]\nvalue = 12\n')
        (self.codex / 'hooks.json').write_text(json.dumps({'hooks': {'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'safety-guard'}, {'type': 'command', 'command': "'/tmp/.codex/hooks/check-gate.sh'"}]}]}}))

    def module(self):
        path = ROOT / 'scripts/install.py'
        self.assertTrue(path.exists(), 'Installer not implemented')
        spec = importlib.util.spec_from_file_location('installer', path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_preserves_claude_preferences_and_other_hooks(self):
        mod = self.module()
        mod.install(self.home, self.home / 'ws', apply=True)
        self.assertEqual((self.claude / 'settings.json').read_text(), 'CLAUDE SENTINEL')
        agents = (self.codex / 'AGENTS.md').read_text()
        self.assertIn('Keep my preferences.', agents)
        self.assertIn('Use options.', agents)
        hooks = (self.codex / 'hooks.json').read_text()
        self.assertIn('safety-guard', hooks)
        self.assertNotIn('check-gate.sh', hooks)
        config = (self.codex / 'config.toml').read_text()
        self.assertIn('model = "my-model"', config)
        self.assertIn('value = 12', config)
        self.assertIn('external-agent-import-sync-enabled = false', config)

    def test_REQ_ROUTE_002_native_agents_preserve_instructions_and_owner_map(self):
        import tomllib
        folder = self.codex / 'agents'
        folder.mkdir()
        original = 'name = "implementer"\ndescription = "Custom"\ndeveloper_instructions = "Keep exactly"\nsandbox_mode = "workspace-write"\n'
        (folder / 'implementer.toml').write_text(original)
        mod = self.module()
        mod.install(self.home, self.home / 'ws', apply=True)
        agent = tomllib.loads((folder / 'implementer.toml').read_text())
        self.assertEqual(agent['developer_instructions'], 'Keep exactly')
        self.assertEqual(agent['sandbox_mode'], 'workspace-write')
        self.assertEqual(agent['model'], 'gpt-5.6-sol')
        self.assertEqual(agent['model_reasoning_effort'], 'high')
        self.assertEqual(mod.install(self.home, self.home / 'ws', apply=True)['changed'], 0)
        mapping = self.codex / 'sdlc-openai/engines.toml'
        mapping.write_text(mapping.read_text().replace('gpt-5.6-sol', 'custom-future-model'))
        mod.install(self.home, self.home / 'ws', apply=True)
        self.assertEqual(tomllib.loads((folder / 'implementer.toml').read_text())['model'], 'custom-future-model')
        self.assertIn('custom-future-model', mapping.read_text())

    def test_REQ_ROUTE_002_owner_named_agent_is_routed(self):
        import tomllib
        mod = self.module()
        mod.install(self.home, self.home / 'ws', apply=True)
        agent = self.codex / 'agents/custom-reviewer.toml'
        agent.write_text('name="custom-reviewer"\ndescription="Owner reviewer"\ndeveloper_instructions="Preserve me"\n')
        mapping = self.codex / 'sdlc-openai/engines.toml'
        mapping.write_text(mapping.read_text() + '\ncustom-reviewer = "verify"\n')
        mod.install(self.home, self.home / 'ws', apply=True)
        parsed = tomllib.loads(agent.read_text())
        self.assertEqual(parsed['model'], 'gpt-5.6-sol')
        self.assertEqual(parsed['developer_instructions'], 'Preserve me')

    def test_dry_run_and_idempotence(self):
        mod = self.module()
        original = (self.codex / 'AGENTS.md').read_bytes()
        mod.install(self.home, self.home / 'ws', apply=False)
        self.assertEqual((self.codex / 'AGENTS.md').read_bytes(), original)
        mod.install(self.home, self.home / 'ws', apply=True)
        first = {p.name: p.read_bytes() for p in self.codex.iterdir() if p.is_file()}
        mod.install(self.home, self.home / 'ws', apply=True)
        self.assertEqual(first, {p.name: p.read_bytes() for p in self.codex.iterdir() if p.is_file()})
        self.assertTrue(list((self.codex / 'sdlc-backups').iterdir()))

    def test_loop_skill_installed_discoverable_and_repeatable(self):
        mod = self.module()
        mod.install(self.home, self.home / 'ws', apply=True)
        source = ROOT / 'skills/loop/SKILL.md'
        installed = self.codex / 'skills/loop/SKILL.md'
        self.assertTrue(installed.is_file(), 'Global loop skill is not installed')
        self.assertEqual(installed.read_bytes(), source.read_bytes())
        self.assertIn(str(installed), (self.codex / 'AGENTS.md').read_text())
        self.assertEqual(mod.install(self.home, self.home / 'ws', apply=True)['changed'], 0)

    def test_existing_unowned_loop_skill_is_not_overwritten(self):
        mod = self.module()
        mod.install(self.home, self.home / 'ws', apply=True)
        skill = self.codex / 'skills/loop/SKILL.md'
        skill.parent.mkdir(parents=True, exist_ok=True)
        skill.write_text('Owner custom loop')
        before = (self.codex / 'AGENTS.md').read_bytes()
        with self.assertRaises(ValueError):
            mod.install(self.home, self.home / 'ws', apply=True)
        self.assertEqual(skill.read_text(), 'Owner custom loop')
        self.assertEqual((self.codex / 'AGENTS.md').read_bytes(), before)

    def test_commit_host_deadline_leaves_cleanup_margin_for_long_checks(self):
        mod = self.module()
        mod.install(self.home, self.home / 'ws', apply=True)
        installed = json.loads((self.codex / 'hooks.json').read_text())
        managed = [hook for group in installed['hooks']['PreToolUse']
                   for hook in group['hooks']
                   if hook.get('statusMessage') == 'OpenAI SDLC: PreToolUse']
        self.assertEqual(len(managed), 1)
        self.assertEqual(managed[0]['timeout'], 900)
        runtime_path = self.codex / 'sdlc-openai/scripts/sdlc.py'
        spec = importlib.util.spec_from_file_location('installed_runtime', runtime_path)
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        from unittest.mock import patch
        repo = self.home / 'ws'
        repo.mkdir(exist_ok=True)
        (repo / 'Makefile').write_text('check:\n\t@true\n')
        with patch.object(runtime, 'run_command', return_value={'exit_code': 124}) as run:
            result = runtime.hook({'cwd': str(repo), 'hook_event_name': 'PreToolUse',
                                   'tool_input': {'command': 'git commit -m test'}},
                                  {'workspace': str(repo)}, runtime_path.parents[1])
        self.assertEqual(result['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertEqual(managed[0]['timeout'] - run.call_args.args[2], 30)

    def test_rejects_symlink_and_invalid_config_before_writing(self):
        mod = self.module()
        (self.codex / 'AGENTS.md').unlink()
        (self.codex / 'AGENTS.md').symlink_to(self.claude / 'settings.json')
        with self.assertRaises(ValueError):
            mod.install(self.home, self.home / 'ws', apply=True)
        self.assertEqual((self.claude / 'settings.json').read_text(), 'CLAUDE SENTINEL')

    def test_keeps_retired_model_preferences(self):
        mod = self.module()
        (self.codex / 'AGENTS.md').write_text(legacy_file(mod, '### Asking questions\nUse options.\n'))
        with patch.dict(os.environ, {OPT_IN: '1'}):
            mod.install(self.home, self.home / 'ws', apply=True)
        result = (self.codex / 'AGENTS.md').read_text()
        self.assertIn('- Vendor A model retired.', result)
        self.assertIn('- Vendor B model local only.', result)
        self.assertIn('Use options.', result)
        self.assertNotIn('old entry point note', result)
        self.assertNotIn('Legacy routing body.', result)

    def test_invalid_config_makes_no_changes(self):
        mod = self.module()
        before = (self.codex / 'AGENTS.md').read_bytes()
        (self.codex / 'config.toml').write_text('[broken')
        with self.assertRaises(ValueError):
            mod.install(self.home, self.home / 'ws', apply=True)
        self.assertEqual((self.codex / 'AGENTS.md').read_bytes(), before)
        self.assertFalse((self.codex / 'sdlc-openai').exists())

    def test_migration_preserves_unknown_sections(self):
        mod = self.module()
        text = legacy_file(mod, '## Unrelated owner preference\nKeep this verbatim.\n')
        with patch.dict(os.environ, {OPT_IN: '1'}):
            result = mod.global_instructions(text, self.codex / 'sdlc-openai', self.home / 'ws')
        self.assertIn('## Unrelated owner preference\nKeep this verbatim.', result)
        self.assertNotIn('Legacy routing body.', result)

    def test_without_opt_in_user_sections_survive(self):
        # Without the opt-in the installer manages only its own START/END
        # block: a user's section that happens to share a legacy heading is
        # theirs, and survives byte for byte.
        mod = self.module()
        own = legacy_file(mod, '## Unrelated owner preference\nKeep this verbatim.\n')
        env = {k: v for k, v in os.environ.items() if k != OPT_IN}
        with patch.dict(os.environ, env, clear=True):
            result = mod.global_instructions(own, self.codex / 'sdlc-openai', self.home / 'ws')
            (self.codex / 'AGENTS.md').write_text(own)
            mod.install(self.home, self.home / 'ws', apply=True)
        self.assertTrue(result.startswith(own.rstrip() + '\n\n' + mod.START))
        installed = (self.codex / 'AGENTS.md').read_text()
        self.assertTrue(installed.startswith(own.rstrip() + '\n\n' + mod.START))
        self.assertIn(f'{mod.LEGACY_ROUTING_HEADING} — legacy routing\nLegacy routing body.', installed)

    def test_commented_toml_headers(self):
        mod = self.module()
        source = '[desktop] # comment\nexternal-agent-import-sync-enabled = true\n[other] # comment\nexternal-agent-import-sync-enabled = true\n'
        import tomllib
        result = tomllib.loads(mod.disable_import(source))
        self.assertFalse(result['desktop']['external-agent-import-sync-enabled'])
        self.assertTrue(result['other']['external-agent-import-sync-enabled'])

    def test_project_onboarding_is_installed_with_its_template(self):
        mod = self.module()
        mod.install(self.home, self.home / 'ws', apply=True)
        target = self.codex / 'sdlc-openai'
        self.assertEqual((target / 'scripts/project.py').read_bytes(), (ROOT.parents[1] / 'core/project.py').read_bytes())
        self.assertEqual((target / 'templates/pre-commit').read_bytes(), (ROOT.parents[1] / 'core/templates/pre-commit').read_bytes())
        self.assertIn('project.py', (target / 'policy.md').read_text())

    def test_native_patch_tools_are_matched_and_guarded(self):
        mod = self.module()
        mod.install(self.home, self.home / 'ws', apply=True)
        hooks = json.loads((self.codex / 'hooks.json').read_text())
        groups = [g for g in hooks['hooks']['PreToolUse']
                  if any(h.get('statusMessage') == 'OpenAI SDLC: PreToolUse' for h in g['hooks'])]
        self.assertIn(groups[0].get('matcher', '*'), ('*', ''))
        import subprocess
        import sys
        repo = self.home / 'ws/project'
        (repo / '.sdlc').mkdir(parents=True)
        (repo / '.sdlc/night-lock').touch()
        (repo / '.sdlc/protected-paths.txt').write_text('secret/\n')
        payload = {'cwd': str(repo), 'hook_event_name': 'PreToolUse', 'tool_name': 'apply_patch',
                   'tool_input': {'command': '*** Begin Patch\n*** Add File: secret/x\n+x\n*** End Patch'}}
        result = subprocess.run([sys.executable, str(self.codex / 'sdlc-openai/scripts/sdlc.py'), 'hook'],
                                input=json.dumps(payload), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'], 'deny')
