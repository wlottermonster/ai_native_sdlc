"""Manual framework doctor acceptance tests use disposable projects and fake homes."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module():
    spec = importlib.util.spec_from_file_location('framework_doctor', ROOT / 'core/doctor.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class DoctorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.workspace = self.root / 'ws'
        self.workspace.mkdir()
        self.state = self.root / 'state'

    def repo(self, name='project', recipe='@true'):
        repo = self.workspace / name
        repo.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        (repo / 'Makefile').write_text(f'check:\n\t{recipe}\ntest:\n\t@true\n')
        (repo / 'AGENTS.md').write_text('Project rules\n')
        (repo / 'CLAUDE.md').write_text('@AGENTS.md\n')
        hook = repo / '.git/hooks/pre-commit'
        hook.write_bytes((ROOT / 'core/templates/pre-commit').read_bytes())
        hook.chmod(0o755)
        return repo

    def fingerprints(self):
        return {'source': 'a' * 64, 'project': 'b' * 64, 'clients': 'c' * 64}

    def test_read_only_default_REQ_DOCTOR_001(self):
        """REQ-DOCTOR-001: inspection never executes checks or creates receipt state."""
        doctor = module()
        repo = self.repo(recipe='@touch forbidden')
        with patch.object(doctor, 'client_inventory', return_value={}), patch.object(
                doctor, 'run_checks', side_effect=AssertionError('verification is opt-in')):
            report = doctor.doctor(self.home, self.workspace, state_dir=self.state)
        self.assertFalse(self.state.exists())
        self.assertFalse((repo / 'forbidden').exists())
        self.assertEqual(report['projects'][0]['verification']['status'], 'unverified')
        self.assertEqual(report['live_compatibility']['status'], 'unverified')

    def test_REQ_ROUTE_003_drifted_routing_cannot_report_healthy(self):
        """REQ-ROUTE-003: drifted routing makes the doctor unhealthy and never claims live selection."""
        doctor = module()
        with patch.object(doctor, 'inspect_installation', return_value={'status': 'current', 'issues': []}), patch.object(
                doctor, 'client_inventory', return_value={x: {'status': 'available'} for x in ['codex', 'claude']}), patch.object(
                doctor, 'dependency_inventory', return_value={}), patch.object(
                doctor, 'inspect_routing', return_value={'status': 'drifted', 'issues': ['Wrong model'], 'live_selection': 'unverified'}):
            report = doctor.doctor(self.home)
        self.assertEqual(report['status'], 'unhealthy')
        self.assertEqual(report['routing']['status'], 'drifted')
        self.assertEqual(report['routing']['live_selection'], 'unverified')

    def test_no_selection_does_not_scan_REQ_DOCTOR_001(self):
        """REQ-DOCTOR-001: default doctor inspects global setup without workspace traversal."""
        doctor = module()
        with patch.object(doctor, 'discover', side_effect=AssertionError('no implicit scan')), patch.object(
                doctor, 'client_inventory', return_value={}):
            report = doctor.doctor(self.home, None, state_dir=self.state)
        self.assertEqual(report['projects'], [])

    def test_project_verification_independent_of_clients_REQ_DOCTOR_004(self):
        """REQ-DOCTOR-004: unavailable harnesses do not prevent explicit project checks."""
        doctor = module()
        repo = self.repo()
        with patch.object(doctor, 'client_inventory', return_value={
                'codex': {'status': 'blocked'}, 'claude': {'status': 'blocked'}}):
            report = doctor.doctor(self.home, self.workspace, project_path=repo, verify=True,
                                   timeout=3, state_dir=self.state)
        self.assertEqual(report['projects'][0]['verification']['status'], 'passed')
        self.assertEqual(report['status'], 'unhealthy')
        self.assertEqual(report['live_compatibility']['status'], 'unverified')

    def test_nested_discovery_and_missing_contract_REQ_DOCTOR_003(self):
        """REQ-DOCTOR-003: nested roots are inspected, dependencies/symlinks pruned."""
        doctor = module()
        umbrella = self.repo('umbrella')
        child = self.repo('umbrella/child')
        excluded = self.repo('umbrella/node_modules/vendor')
        (self.workspace / 'alias').symlink_to(child, target_is_directory=True)
        (child / 'Makefile').unlink()
        roots = doctor.discover(self.workspace)
        self.assertEqual(set(roots), {umbrella, child})
        self.assertNotIn(excluded, roots)
        report = doctor.doctor(self.home, self.workspace, project_path=child, state_dir=self.state)
        self.assertFalse(report['projects'][0]['setup']['setup_ready'])
        self.assertFalse((child / 'Makefile').exists())

    def test_broken_git_candidate_is_one_blocked_row_REQ_DOCTOR_003(self):
        """REQ-DOCTOR-003: one unreadable repository cannot hide every other project."""
        doctor = module()
        good = self.repo('good')
        bad = self.workspace / 'bad'
        (bad / '.git').mkdir(parents=True)
        self.assertEqual(set(doctor.discover(self.workspace)), {good, bad})
        with patch.object(doctor, 'client_inventory', return_value={}):
            report = doctor.doctor(self.home, self.workspace, state_dir=self.state)
        rows = {row['project']: row for row in report['projects']}
        self.assertEqual(set(rows), {str(good), str(bad)})
        self.assertTrue(rows[str(good)]['setup']['setup_ready'])
        self.assertFalse(rows[str(bad)]['setup']['setup_ready'])
        self.assertEqual(rows[str(bad)]['verification']['status'], 'blocked')
        self.assertNotIn('Workspace inventory unavailable', report['issues'])

    def test_client_fingerprint_ignores_client_and_owner_config_rewrites_REQ_DOCTOR_005(self):
        """REQ-DOCTOR-005: a client rewriting its own config, or an owner edit outside the
        installer-owned fragments, is not a client change; a new binary or hook entry is."""
        doctor = module()
        fake_bin = self.root / 'bin'; fake_bin.mkdir()
        for name in ('codex', 'claude'):
            exe = fake_bin / name
            exe.write_text('#!/bin/sh\necho ' + name + ' 1.2.3\n'); exe.chmod(0o755)
        codex = self.home / '.codex'; codex.mkdir()
        sdlc = {'type': 'command', 'command': 'sdlc.py hook', 'timeout': 10, 'statusMessage': 'OpenAI SDLC: Stop'}
        (codex / 'config.toml').write_text('model = "a"\n[desktop]\nexternal-agent-import-sync-enabled = false\n')
        (codex / 'hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [sdlc]}]}}))
        (codex / 'AGENTS.md').write_text('# mine\n<!-- openai-sdlc:begin -->\nblock\n<!-- openai-sdlc:end -->\n')
        claude = self.home / '.claude'; claude.mkdir()
        (claude / 'settings.json').write_text(json.dumps({'model': 'x', 'hooks': {'Stop': [{'hooks': [
            {'type': 'command', 'command': '"$HOME/.claude/hooks/dod.sh"'}]}]}}))
        (claude / 'CLAUDE.md').write_text('owner notes\n')
        with patch.dict(os.environ, {'PATH': str(fake_bin) + os.pathsep + os.environ['PATH']}):
            before = doctor.client_inventory(self.home)
            self.assertEqual({row['status'] for row in before.values()}, {'available'})
            # The client rewrote its own config and the owner picked a model: not a change.
            (codex / 'config.toml').write_text('model = "b"\n[desktop]\nexternal-agent-import-sync-enabled = false\n[tui.model_availability_nux]\nsome-model = 4\n')
            (codex / 'AGENTS.md').write_text((codex / 'AGENTS.md').read_text() + '\n## Owner notes\n')
            (claude / 'settings.json').write_text(json.dumps({'model': 'y', 'hooks': {'Stop': [{'hooks': [
                {'type': 'command', 'command': '"$HOME/.claude/hooks/dod.sh"'}]}]}}))
            (claude / 'CLAUDE.md').write_text('owner notes, edited\n')
            same = doctor.client_inventory(self.home)
            self.assertEqual(same, before)
            # An installer-owned hook entry change is a change, for either client.
            (codex / 'hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [dict(sdlc, timeout=20)]}]}}))
            self.assertNotEqual(doctor.client_inventory(self.home)['codex'], before['codex'])
            (claude / 'settings.json').write_text(json.dumps({'model': 'y', 'hooks': {'Stop': []}}))
            self.assertNotEqual(doctor.client_inventory(self.home)['claude'], before['claude'])
            # A different binary is a change.
            (fake_bin / 'codex').write_text('#!/bin/sh\necho codex 1.2.4\n')
            self.assertNotEqual(doctor.client_inventory(self.home)['codex'], before['codex'])

    def test_registered_hidden_worktrees_REQ_DOCTOR_003(self):
        """REQ-DOCTOR-003: registered workspace worktrees are included and deduplicated."""
        doctor = module()
        repo = self.repo()
        subprocess.run(['git', '-C', str(repo), 'add', 'Makefile', 'AGENTS.md', 'CLAUDE.md'], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c',
                        'user.email=fixture@example.invalid', '-c', 'core.hooksPath=/dev/null',
                        'commit', '-qm', 'fixture'], check=True)
        hidden = self.workspace / '.worktrees/aux'
        subprocess.run(['git', '-C', str(repo), 'worktree', 'add', '-q', '-b', 'aux', str(hidden)], check=True)
        outside = self.root / 'outside'
        subprocess.run(['git', '-C', str(repo), 'worktree', 'add', '-q', '-b', 'outside', str(outside)], check=True)
        self.assertEqual(set(doctor.discover(self.workspace)), {repo, hidden})

    def test_deep_git_fingerprint_REQ_DOCTOR_005(self):
        """REQ-DOCTOR-005: tracked, untracked, modes and symlinks invalidate receipts."""
        doctor = module()
        repo = self.repo()
        (repo / '.gitignore').write_text('ignored-secret\n')
        source = repo / 'deep/source'
        source.parent.mkdir()
        source.write_text('first')
        initial = doctor.project_fingerprint(repo)
        (repo / 'ignored-secret').write_text('not for doctor output')
        self.assertEqual(initial, doctor.project_fingerprint(repo))
        source.write_text('second')
        changed = doctor.project_fingerprint(repo)
        self.assertNotEqual(initial, changed)
        source.chmod(0o755)
        executable = doctor.project_fingerprint(repo)
        self.assertNotEqual(changed, executable)
        (repo / 'link').symlink_to('deep/source')
        self.assertNotEqual(executable, doctor.project_fingerprint(repo))

    def test_failure_receipt_stays_failed_REQ_DOCTOR_005(self):
        """REQ-DOCTOR-005: matching failures stay failures; source/client drift is stale."""
        doctor = module()
        repo = self.repo(recipe='@exit 3')
        fingerprints = self.fingerprints()
        result = doctor.verify_project(repo, self.state, fingerprints, timeout=3)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(doctor.read_receipt(repo, self.state, fingerprints)['status'], 'failed')
        for field in fingerprints:
            altered = {**fingerprints, field: 'd' * 64}
            self.assertEqual(doctor.read_receipt(repo, self.state, altered)['status'], 'unverified')

    def test_invalid_receipt_REQ_DOCTOR_005(self):
        """REQ-DOCTOR-005: corrupt or fabricated empty successful receipts never pass."""
        doctor = module()
        repo = self.repo()
        receipt = doctor.receipt_path(repo, self.state)
        receipt.parent.mkdir(parents=True)
        for contents in ('{broken', '{}', json.dumps({'schema_version': 1, 'status': 'passed',
                                                      'checks': [], 'fingerprints': self.fingerprints()})):
            receipt.write_text(contents)
            self.assertEqual(doctor.read_receipt(repo, self.state, self.fingerprints())['status'], 'blocked')

    def test_timeout_and_no_output_persistence_REQ_DOCTOR_004(self):
        """REQ-DOCTOR-004: command timeout kills children; raw diagnostics never enter state."""
        doctor = module()
        repo = self.repo(recipe="@echo FAKE_SECRET_DIAGNOSTIC; (sleep 1; touch late-child) & wait")
        start = time.monotonic()
        result = doctor.verify_project(repo, self.state, self.fingerprints(), timeout=.15)
        self.assertEqual(result['status'], 'failed')
        self.assertLess(time.monotonic() - start, 1)
        self.assertTrue(result['checks'][0]['timed_out'])
        time.sleep(1.1)
        self.assertFalse((repo / 'late-child').exists())
        for file in self.state.rglob('*'):
            if file.is_file():
                self.assertNotIn('FAKE_SECRET_DIAGNOSTIC', file.read_text())

    def test_mutating_checks_and_interruption_REQ_DOCTOR_004(self):
        """REQ-DOCTOR-004: changed inputs or interruption cannot preserve passing evidence."""
        doctor = module()
        repo = self.repo()
        fingerprints = self.fingerprints()
        result = doctor.verify_project(repo, self.state, fingerprints, timeout=3,
                                       current_fingerprints=lambda: fingerprints)
        self.assertEqual(result['status'], 'passed')
        with patch.object(doctor, 'run_checks', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                doctor.verify_project(repo, self.state, fingerprints, timeout=3)
        self.assertEqual(doctor.read_receipt(repo, self.state, fingerprints)['status'], 'blocked')
        result = doctor.verify_project(repo, self.state, fingerprints, timeout=3,
                                       current_fingerprints=lambda: {**fingerprints, 'project': 'f' * 64})
        self.assertEqual(result['status'], 'unverified')
        self.assertNotEqual(doctor.read_receipt(repo, self.state, fingerprints)['status'], 'passed')

    def test_manifest_validation_and_drift_REQ_DOCTOR_005(self):
        """REQ-DOCTOR-005: malformed manifests and changed managed/source files block parity."""
        doctor = module()
        runtime = self.home / '.codex/sdlc-openai'
        (runtime / 'scripts').mkdir(parents=True)
        managed = {}
        for name in ('doctor.py', 'installation.py', 'project.py'):
            path = runtime / 'scripts' / name
            path.write_text('# managed fixture\n')
            managed[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
        source = self.root / 'source'
        (source / 'core').mkdir(parents=True)
        (source / 'core/doctor.py').write_text('# source fixture\n')
        snapshot = {'path': str(source), 'revision': 'fixture', 'dirty': False, 'fingerprint': 'a' * 64}
        data = {'schema_version': 1, 'source': snapshot, 'managed_files': managed,
                'source_files': {'core/doctor.py': hashlib.sha256((source / 'core/doctor.py').read_bytes()).hexdigest()}}
        manifest = runtime / 'doctor-installation.json'
        for malformed in ({}, {**data, 'managed_files': {}}, {**data, 'schema_version': 99}):
            manifest.write_text(json.dumps(malformed))
            self.assertEqual(doctor.inspect_installation(manifest)['status'], 'blocked')
        manifest.write_text(json.dumps(data))
        with patch.object(doctor, 'source_snapshot', return_value=snapshot):
            self.assertEqual(doctor.inspect_installation(manifest)['status'], 'current')
            (runtime / 'scripts/doctor.py').write_text('# changed\n')
            self.assertEqual(doctor.inspect_installation(manifest)['status'], 'drifted')

    def test_managed_file_changes_invalidate_receipts_REQ_DOCTOR_005(self):
        """REQ-DOCTOR-005: installed byte changes stale evidence, even drifted-to-drifted."""
        doctor = module()
        repo = self.repo()
        source = self.root / 'source'
        (source / 'core').mkdir(parents=True)
        (source / 'core/doctor.py').write_text('# source')
        snapshot = {'path': str(source), 'revision': None, 'dirty': None, 'fingerprint': 'a' * 64}
        for runtime in (self.home / '.codex/sdlc-openai', self.home / '.claude'):
            (runtime / 'scripts').mkdir(parents=True)
            managed = {}
            for name in ('doctor.py', 'project.py', 'installation.py'):
                path = runtime / 'scripts' / name
                path.write_text('# original')
                managed[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
            data = {'schema_version': 1, 'source': snapshot, 'managed_files': managed,
                    'source_files': {'core/doctor.py': hashlib.sha256((source / 'core/doctor.py').read_bytes()).hexdigest()}}
            (runtime / 'doctor-installation.json').write_text(json.dumps(data))
        installed = self.home / '.codex/sdlc-openai/scripts/doctor.py'
        clients = {name: {'status': 'available', 'fingerprint': 'c' * 64, 'version': '1.2.3'}
                   for name in ('codex', 'claude')}
        with patch.object(doctor, 'source_snapshot', return_value=snapshot), patch.object(
                doctor, 'client_inventory', return_value=clients):
            first = doctor.doctor(self.home, self.workspace, repo, True, 3, self.state)
            self.assertEqual(first['installations']['codex']['status'], 'current')
            self.assertEqual(first['projects'][0]['verification']['status'], 'passed')
            installed.write_text('# changed once')
            stale = doctor.doctor(self.home, self.workspace, repo, state_dir=self.state)
            self.assertEqual(stale['projects'][0]['verification']['status'], 'unverified')
            again = doctor.doctor(self.home, self.workspace, repo, True, 3, self.state)
            self.assertEqual(again['projects'][0]['verification']['status'], 'passed')
            installed.write_text('# changed twice')
            stale = doctor.doctor(self.home, self.workspace, repo, state_dir=self.state)
            self.assertEqual(stale['projects'][0]['verification']['status'], 'unverified')

    def test_missing_dependency_requires_attention_REQ_DOCTOR_006(self):
        """REQ-DOCTOR-006: a missing local gate dependency makes quick inspection unhealthy."""
        doctor = module()
        with patch.object(doctor.shutil, 'which', side_effect=lambda name: None if name == 'shellcheck' else '/fake/' + name):
            dependencies = doctor.dependency_inventory()
        self.assertEqual(dependencies['shellcheck']['status'], 'missing')
        with patch.object(doctor, 'dependency_inventory', return_value=dependencies), patch.object(
                doctor, 'inspect_installation', return_value={'status': 'current'}), patch.object(
                doctor, 'client_inventory', return_value={name: {'status': 'available'} for name in ('codex', 'claude')}):
            self.assertEqual(doctor.doctor(self.home)['status'], 'unhealthy')

    def test_unavailable_client_and_cli_status_REQ_DOCTOR_006(self):
        """REQ-DOCTOR-006: missing clients block readiness, JSON and exit status agree."""
        doctor = module()
        with patch.object(doctor.shutil, 'which', return_value=None):
            clients = doctor.client_inventory(self.home)
        self.assertEqual(clients['codex']['status'], 'blocked')
        self.assertEqual(clients['claude']['status'], 'blocked')
        with patch.object(doctor, 'doctor', return_value={'status': 'unhealthy'}), patch('builtins.print') as output:
            self.assertEqual(doctor.main(['--home', str(self.home), '--workspace', str(self.workspace), '--json']), 1)
            self.assertEqual(json.loads(output.call_args.args[0])['status'], 'unhealthy')


    def test_git_environment_does_not_redirect_checks_REQ_DOCTOR_004(self):
        doctor = module()
        repo = self.repo(recipe="@python3.12 envcheck.py")
        (repo/'envcheck.py').write_text("import os; assert not any(k.startswith('GIT_') for k in os.environ); assert os.environ['DOCTOR_SENTINEL']=='keep'")
        with patch.dict(os.environ, {'GIT_DIR':'wrong', 'GIT_INDEX_FILE':'wrong', 'GIT_WORK_TREE':'wrong', 'GIT_COMMON_DIR':'wrong', 'DOCTOR_SENTINEL':'keep'}):
            checks=doctor.run_checks(repo,3)
        self.assertEqual([x['exit_code'] for x in checks],[0,0])

    def test_nonexecutable_installed_hook_is_drift_REQ_DOCTOR_002(self):
        doctor=module()
        from installation import build_manifest
        runtime=self.home/'.claude'
        writes={}
        for name in ('scripts/doctor.py','scripts/installation.py','scripts/project.py','hooks/check-gate.sh'):
            p=runtime/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('true')
            p.chmod(0o755);writes[p]=p.read_bytes()
        manifest=runtime/'doctor-installation.json'
        manifest.write_text(json.dumps(build_manifest(ROOT,writes)))
        self.assertEqual(doctor.inspect_installation(manifest)['status'],'current')
        (runtime/'hooks/check-gate.sh').chmod(0o644)
        self.assertEqual(doctor.inspect_installation(manifest)['status'],'drifted')

    # The install receipt hashes copied files, never whether the hooks are switched
    # on. These tests prove the doctor reads ~/.claude/settings.json itself.
    def merged_settings(self):
        """What the owner's own merge step produces from the shipped snippet."""
        out = subprocess.run(['bash', str(ROOT / 'scripts/merge-settings.sh'), '--snippet',
                              str(ROOT / 'settings/hooks-snippet.json'), str(self.root / 'absent.json')],
                             check=True, stdout=subprocess.PIPE, env=dict(os.environ, HOME=str(self.home)))
        return json.loads(out.stdout)

    def write_settings(self, document):
        (self.home / '.claude').mkdir(exist_ok=True)
        (self.home / '.claude/settings.json').write_text(json.dumps(document))

    def run_doctor(self, doctor, *args, **kwargs):
        """Everything except hook registration reads healthy, so only that can decide."""
        patches = (patch.object(doctor, 'inspect_installation', return_value={'status': 'current', 'issues': []}),
                   patch.object(doctor, 'client_inventory', return_value={x: {'status': 'available'} for x in ('codex', 'claude')}),
                   patch.object(doctor, 'dependency_inventory', return_value={}),
                   patch.object(doctor, 'inspect_routing', return_value={'status': 'current', 'issues': [], 'live_selection': 'unverified'}))
        for item in patches:
            item.start()
        try:
            return doctor.doctor(self.home, *args, **kwargs)
        finally:
            for item in patches:
                item.stop()

    def test_merged_hooks_are_registered_REQ_DOCTOR_006(self):
        """REQ-DOCTOR-006: a runtime whose settings.json carries every snippet hook reads registered."""
        doctor = module()
        self.write_settings(self.merged_settings())
        report = self.run_doctor(doctor)
        claude = report['installations']['claude']
        self.assertEqual(claude['hooks']['status'], 'registered')
        self.assertEqual(claude['status'], 'current')
        self.assertEqual(report['status'], 'healthy')

    def test_unregistered_hook_is_unhealthy_and_named_REQ_DOCTOR_006(self):
        """REQ-DOCTOR-006: removing one snippet hook from settings.json makes the doctor
        unhealthy and names the event and command that is not switched on."""
        doctor = module()
        settings = self.merged_settings()
        gate = '"$HOME/.claude/hooks/check-gate.sh"'
        settings['hooks']['PreToolUse'] = [
            dict(group, hooks=[h for h in group['hooks'] if h.get('command') != gate])
            for group in settings['hooks']['PreToolUse']]
        # An owner's own hook under the same event does not stand in for the gate.
        settings['hooks']['PreToolUse'].append({'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'owner.sh'}]})
        self.write_settings(settings)
        report = self.run_doctor(doctor)
        claude = report['installations']['claude']
        self.assertEqual(report['status'], 'unhealthy')
        self.assertEqual(claude['hooks']['status'], 'not-registered')
        self.assertNotEqual(claude['status'], 'current')
        self.assertIn('Hooks not registered: PreToolUse: ' + gate, claude['issues'])
        self.assertEqual(claude['hooks']['missing'], [{'event': 'PreToolUse', 'command': gate}])
        # The same command under a different event is not registration for this one.
        settings['hooks']['Stop'][0]['hooks'].append({'type': 'command', 'command': gate})
        self.write_settings(settings)
        self.assertEqual(self.run_doctor(doctor)['installations']['claude']['hooks']['status'], 'not-registered')

    def test_absent_or_unparsable_settings_is_never_healthy_REQ_DOCTOR_006(self):
        """REQ-DOCTOR-006: a settings.json the doctor cannot read is reported, never assumed."""
        doctor = module()
        missing = self.run_doctor(doctor)
        self.assertEqual(missing['installations']['claude']['hooks']['status'], 'settings-missing')
        self.assertEqual(missing['status'], 'unhealthy')
        (self.home / '.claude').mkdir()
        (self.home / '.claude/settings.json').write_text('{"hooks": {')
        broken = self.run_doctor(doctor)
        self.assertEqual(broken['installations']['claude']['hooks']['status'], 'settings-invalid')
        self.assertEqual(broken['status'], 'unhealthy')
        self.write_settings(['not', 'an', 'object'])
        self.assertEqual(self.run_doctor(doctor)['installations']['claude']['hooks']['status'], 'settings-invalid')

    # REQ-MOD-026: the engine-map mod ships as a folder under adapters/claude/skills,
    # so the receipt's existing managed-file check is what must name its files.
    # The fixture supplies its own plugin-shaped folder; the real one is not assumed.
    def install_mod_fixture(self):
        """A source checkout carrying the mod folder, installed into the fake home the way
        install.sh does it: --install-skills, then the receipt from claude_manifest."""
        from installation import claude_manifest, install_claude_skills, write_manifest
        source = self.root / 'source'
        mod = source / 'adapters/claude/skills/sdlc-engine-map'
        files = {'.claude-plugin/plugin.json': '{"name": "sdlc-engine-map"}\n',
                 'hooks/hooks.json': '{"hooks": {}}\n',
                 'hooks/register.ts': 'export default function register() {}\n'}
        for name, text in files.items():
            (mod / name).parent.mkdir(parents=True, exist_ok=True)
            (mod / name).write_text(text)
        (source / 'install.sh').write_text('#!/bin/sh\n')
        (source / 'settings').mkdir()
        (source / 'settings/hooks-snippet.json').write_bytes((ROOT / 'settings/hooks-snippet.json').read_bytes())
        # The skills install path refuses without its exclusion list (REQ-MOD-025).
        (source / 'adapters/claude/skill-exclusions.txt').write_bytes(
            (ROOT / 'adapters/claude/skill-exclusions.txt').read_bytes())
        runtime = self.home / '.claude'
        copies = [('sdlc-policy.md', 'sdlc-policy.md'), ('core/handoff.py', 'scripts/handoff.py'),
                  ('core/handoff_store.py', 'scripts/handoff_store.py'),
                  ('core/handoff_runtime.py', 'scripts/handoff_runtime.py'),
                  ('core/project.py', 'scripts/project.py'), ('core/doctor.py', 'scripts/doctor.py'),
                  ('adapters/codex/scripts/routing.py', 'scripts/routing.py'),
                  ('core/installation.py', 'scripts/installation.py'),
                  ('core/templates/pre-commit', 'templates/pre-commit')]
        for src, dst in copies:
            for path in (source / src, runtime / dst):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('# fixture ' + src + '\n')
        install_claude_skills(source, runtime)
        write_manifest(runtime / 'doctor-installation.json', claude_manifest(source, runtime))
        self.write_settings(self.merged_settings())
        return runtime / 'skills/sdlc-engine-map/hooks/register.ts'

    def claude_row(self, doctor):
        """Only the installation inspection is real; clients, tools and routing read healthy."""
        with patch.object(doctor, 'client_inventory', return_value={x: {'status': 'available'} for x in ('codex', 'claude')}), \
                patch.object(doctor, 'dependency_inventory', return_value={}), \
                patch.object(doctor, 'inspect_routing', return_value={'status': 'current', 'issues': [], 'live_selection': 'unverified'}):
            return doctor.doctor(self.home)['installations']['claude']

    def test_intact_mod_reads_current_REQ_MOD_026(self):
        """REQ-MOD-026: the mod's files are in the receipt, and intact they raise no issue."""
        doctor = module()
        register = self.install_mod_fixture()
        receipt = json.loads((self.home / '.claude/doctor-installation.json').read_text())
        self.assertIn(str(register), receipt['managed_files'])
        row = self.claude_row(doctor)
        self.assertEqual(row['status'], 'current', row['issues'])
        self.assertNotIn('skills/sdlc-engine-map', ' '.join(row['issues']))

    def test_missing_or_changed_mod_file_is_named_REQ_MOD_026(self):
        """REQ-MOD-026: deleting or editing an installed mod file makes the claude row not
        current, and its issue names the path under skills/sdlc-engine-map."""
        doctor = module()
        register = self.install_mod_fixture()
        original = register.read_bytes()
        for label, damage in (('missing', register.unlink),
                              ('changed', lambda: register.write_text('// edited by hand\n'))):
            with self.subTest(damage=label):
                damage()
                row = self.claude_row(doctor)
                self.assertNotEqual(row['status'], 'current')
                named = [i for i in row['issues'] if 'skills/sdlc-engine-map' in i]
                self.assertEqual(named, ['Managed file missing or changed: ' + str(register)])
                register.write_bytes(original)
        self.assertEqual(self.claude_row(doctor)['status'], 'current')

    def test_empty_workspace_is_nothing_inspected_REQ_DOCTOR_003(self):
        """REQ-DOCTOR-003: a workspace holding no repository inspected nothing; all([]) is not a pass."""
        doctor = module()
        self.write_settings(self.merged_settings())
        report = self.run_doctor(doctor, self.workspace, state_dir=self.state)
        self.assertEqual(report['projects'], [])
        self.assertEqual(report['status'], 'unhealthy')
        self.assertTrue(any(issue.startswith('Nothing inspected') for issue in report['issues']))

if __name__ == '__main__':
    unittest.main()
