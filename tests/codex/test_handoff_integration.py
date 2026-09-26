"""Original native handoff installation and Stop-hook regression tests."""
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
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'core'))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class HandoffIntegrationTests(unittest.TestCase):
    def test_REQ_HAND_007_codex_install_and_preserve_custom_skill(self):
        installer = load('adapters/codex/scripts/install.py', 'handoff_installer')
        with tempfile.TemporaryDirectory() as d, contextlib.redirect_stdout(io.StringIO()):
            home = Path(d)
            installer.install(home, home / 'ws', apply=True)
            skill = home / '.codex/skills/handoff/SKILL.md'
            self.assertTrue(skill.is_file())
            helper = home / '.codex/sdlc-openai/scripts/handoff.py'
            self.assertTrue(helper.is_file())
            self.assertEqual(installer.install(home, home / 'ws', apply=True)['changed'], 0)
            skill.write_text('Owner modified handoff')
            before = (home / '.codex/AGENTS.md').read_bytes()
            with self.assertRaises(ValueError):
                installer.install(home, home / 'ws', apply=True)
            self.assertEqual(skill.read_text(), 'Owner modified handoff')
            self.assertEqual((home / '.codex/AGENTS.md').read_bytes(), before)

    def test_REQ_HAND_007_claude_skill_conflict_preflight(self):
        installation = load('core/installation.py', 'handoff_installation')
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d).resolve() / '.claude'
            skill = runtime / 'skills/handoff/SKILL.md'
            skill.parent.mkdir(parents=True)
            skill.write_text('Private skill')
            with self.assertRaises(ValueError):
                installation.claude_skill_writes(ROOT, runtime)
            self.assertEqual(skill.read_text(), 'Private skill')

    def test_REQ_HAND_003_stop_yields_only_exact_owner(self):
        from handoff_store import Store
        runtime = load('adapters/codex/scripts/sdlc.py', 'handoff_sdlc')
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / 'home'; home.mkdir()
            repo = Path(d) / 'repo'; repo.mkdir()
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            (repo / 'Makefile').write_text('check:\n\t@false\n')
            source_id = '11111111-1111-4111-8111-111111111111'
            other_id = '22222222-2222-4222-8222-222222222222'
            with patch.dict(os.environ, {'HOME': str(home)}):
                runtime.begin(repo, 'pending', 'Pending implementation', 12)
                state = Store(repo).prepare(
                    source={'client': 'codex', 'session_id': source_id, 'surface': 'cli'},
                    target={'client': 'claude', 'model': 'opus', 'effort': None},
                    phase='review', task='Review test', briefing='Review the Makefile')
                payload = {'hook_event_name': 'Stop', 'cwd': str(repo), 'session_id': source_id}
                settings = {'workspace': str(repo)}
                # REQ-HAND-003: a prepared package nobody accepted is not a transfer.
                self.assertEqual(runtime.hook(payload, settings, ROOT / 'adapters/codex')['decision'], 'block')
                Store(repo).accept(state['id'], client='claude', session_id='55555555-5555-4555-8555-555555555555')
                self.assertEqual(runtime.hook(payload, settings, ROOT / 'adapters/codex'), {})
                # The Stop hook resolves the checkout root from a nested cwd, for
                # both the handoff yield and the active-run scan.
                nested = repo / 'packages/api'; nested.mkdir(parents=True)
                nested_payload = dict(payload, cwd=str(nested))
                self.assertEqual(runtime.hook(nested_payload, settings, ROOT / 'adapters/codex'), {})
                nested_payload['session_id'] = other_id
                self.assertEqual(runtime.hook(nested_payload, settings, ROOT / 'adapters/codex')['decision'], 'block')
                payload['session_id'] = other_id
                self.assertEqual(runtime.hook(payload, settings, ROOT / 'adapters/codex')['decision'], 'block')
                Store(repo).cancel(state['id'], client='codex', session_id=source_id, reason='Receiver stopped', receiver_stopped=True)
                payload['session_id'] = source_id
                self.assertEqual(runtime.hook(payload, settings, ROOT / 'adapters/codex')['decision'], 'block')

    def test_REQ_HAND_003_claude_stop_handoff_is_session_scoped(self):
        from handoff_store import Store
        import shutil
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / 'home'; home.mkdir()
            repo = Path(d) / 'repo'; repo.mkdir()
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            (repo / 'Makefile').write_text('check:\n\t@false\n')
            scripts = home / '.claude/scripts'; scripts.mkdir(parents=True)
            for name in ['handoff.py', 'handoff_store.py', 'handoff_runtime.py']:
                shutil.copyfile(ROOT / 'core' / name, scripts / name)
            source_id = '33333333-3333-4333-8333-333333333333'
            env = dict(os.environ, HOME=str(home))
            spec = repo / 'specs/incomplete'; spec.mkdir(parents=True)
            (spec / 'requirements.md').write_text('REQ-DEMO-001 needed [verify: integration]\n')
            (spec / 'tasks.md').write_text('- [ ] No mapping yet\n')
            with patch.dict(os.environ, {'HOME': str(home)}):
                state = Store(repo).prepare(
                    source={'client': 'claude', 'session_id': source_id, 'surface': 'cli'},
                    target={'client': 'codex', 'model': 'some-model', 'effort': 'high'},
                    phase='review', task='Review test', briefing='Review the Makefile')
            hook = ROOT / 'adapters/claude/hooks/dod.sh'
            def stop(session):
                return subprocess.run(['bash', str(hook)], cwd=repo, env=env,
                                      input=json.dumps({'session_id': session}),
                                      text=True, capture_output=True, timeout=12)
            # REQ-HAND-003: prepared but unaccepted keeps the Stop gate closed.
            self.assertEqual(stop(source_id).returncode, 2)
            with patch.dict(os.environ, {'HOME': str(home)}):
                Store(repo).accept(state['id'], client='codex', session_id='66666666-6666-4666-8666-666666666666')
            for session, expected in [(source_id, 0), ('44444444-4444-4444-8444-444444444444', 2)]:
                result = stop(session)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_REQ_HAND_003_requirement_stop_wrapper_and_manual_enforcement(self):
        from handoff_store import Store
        import shutil
        with tempfile.TemporaryDirectory() as d:
            home = Path(d) / 'home'; home.mkdir()
            repo = Path(d) / 'repo'; repo.mkdir()
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            spec = repo / 'specs/incomplete'; spec.mkdir(parents=True)
            (spec / 'requirements.md').write_text('REQ-DEMO-001 needed [verify: integration]\n')
            (spec / 'tasks.md').write_text('- [ ] No mapping yet\n')
            scripts = home / '.claude/scripts'; scripts.mkdir(parents=True)
            for name in ['handoff.py', 'handoff_store.py', 'handoff_runtime.py']:
                shutil.copyfile(ROOT / 'core' / name, scripts / name)
            session = '33333333-3333-4333-8333-333333333333'
            with patch.dict(os.environ, {'HOME': str(home)}):
                state = Store(repo).prepare(source={'client':'claude','session_id':session,'surface':'cli'},
                    target={'client':'codex','model':'example','effort':None},
                    phase='review', task='Review', briefing='Synthetic test')
            hook = ROOT / 'adapters/claude/hooks/req-gate.sh'
            # REQ-HAND-003: prepared but unaccepted keeps the requirement gate closed.
            prepared = subprocess.run(['bash',str(hook),'--stop'], cwd=repo,
                env=dict(os.environ, HOME=str(home)), input=json.dumps({'session_id':session}),
                text=True, capture_output=True, timeout=12)
            self.assertEqual(prepared.returncode, 2, prepared.stderr)
            with patch.dict(os.environ, {'HOME': str(home)}):
                Store(repo).accept(state['id'], client='codex', session_id='77777777-7777-4777-8777-777777777777')
            for args, identity, expected in [(['--stop'], session, 0),
                    (['--stop'], '44444444-4444-4444-8444-444444444444', 2), ([], session, 2)]:
                result = subprocess.run(['bash',str(hook),*args], cwd=repo,
                    env=dict(os.environ, HOME=str(home)), input=json.dumps({'session_id':identity}),
                    text=True, capture_output=True, timeout=12)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_REQ_HAND_007_migrate_only_owned_claude_stop_entry(self):
        installation = load('core/installation.py', 'handoff_migration')
        with tempfile.TemporaryDirectory() as d:
            runtime = Path(d).resolve() / '.claude'; runtime.mkdir()
            settings = runtime / 'settings.json'
            command = '\"$HOME/.claude/hooks/req-gate.sh\"'
            document = {'owner':True, 'hooks': {'Stop': [{'hooks': [
                {'type':'command','command':command,'timeout':60},
                {'type':'command','command':'custom-req-gate.sh','timeout':10}]}],
                'PreToolUse':[{'hooks':[{'type':'command','command':command}]}]}}
            settings.write_text(json.dumps(document))
            installation.migrate_claude_handoff_hook(runtime)
            actual = json.loads(settings.read_text())
            document['hooks']['Stop'][0]['hooks'][0]['command'] += ' --stop'
            self.assertEqual(actual, document)
            before = settings.read_bytes()
            installation.migrate_claude_handoff_hook(runtime)
            self.assertEqual(settings.read_bytes(), before)

    def test_REQ_HAND_003_corrupt_helper_keeps_normal_stop(self):
        runtime = load('adapters/codex/scripts/sdlc.py', 'handoff_corrupt')
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / 'sdlc.py'; fake.touch()
            helper = fake.with_name('handoff_store.py')
            for content in ['invalid python syntax !!!', 'import dependency_that_does_not_exist']:
                helper.write_text(content)
                with patch.object(runtime, '__file__', str(fake)):
                    self.assertFalse(runtime.handoff_yield(Path(d), '33333333-3333-4333-8333-333333333333'))
