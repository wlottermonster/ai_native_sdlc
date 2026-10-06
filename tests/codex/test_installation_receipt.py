"""REQ-DOCTOR-002: provenance and managed hashes without configuration contents."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

class InstallationReceiptTests(unittest.TestCase):
    def module(self):
        spec = importlib.util.spec_from_file_location('installation', ROOT/'core/installation.py')
        self.assertIsNotNone(spec)
        self.assertTrue(Path(spec.origin).exists(), 'shared receipt builder must exist')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_REQ_DOCTOR_002_deterministic_content_and_source_drift(self):
        mod = self.module()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); (root/'core').mkdir(); (root/'core/tool.py').write_text('one')
            (root/'install.sh').write_text('true')
            a=mod.source_snapshot(root); b=mod.source_snapshot(root)
            self.assertEqual(a,b)
            (root/'private-report.md').write_text('unrelated')
            self.assertEqual(a['fingerprint'],mod.source_snapshot(root)['fingerprint'])
            (root/'sdlc-policy.md').write_text('generated policy')
            self.assertNotEqual(a['fingerprint'],mod.source_snapshot(root)['fingerprint'])
            a=mod.source_snapshot(root)
            (root/'core/tool.py').write_text('two')
            self.assertNotEqual(a['fingerprint'],mod.source_snapshot(root)['fingerprint'])

    def test_REQ_DOCTOR_002_manifest_contains_hashes_never_values(self):
        mod=self.module()
        manifest=mod.build_manifest(ROOT,{Path('/tmp/config'):b'SYNTHETIC_PRIVATE_VALUE'})
        self.assertEqual(manifest['schema_version'],1)
        self.assertEqual(len(manifest['managed_files'][str(Path('/tmp').resolve()/'config')]),64)
        self.assertNotIn('SYNTHETIC_PRIVATE_VALUE',str(manifest))
        self.assertIn('core/installation.py',manifest['source_files'])
        self.assertIn('revision',manifest['source'])

    def test_REQ_DOCTOR_002_mixed_ownership_files_are_recorded_as_fragments(self):
        """REQ-DOCTOR-002: host files the installer merges into are hashed by their
        installer-owned fragment, so owner and client edits elsewhere are not drift."""
        mod=self.module()
        agents=b'# mine\n<!-- openai-sdlc:begin -->\nblock\n<!-- openai-sdlc:end -->\n'
        self.assertEqual(mod.managed_fragment('codex-agents-block',agents),
                         mod.managed_fragment('codex-agents-block',b'# other notes\n\n'+agents+b'\nmore\n'))
        self.assertNotEqual(mod.managed_fragment('codex-agents-block',agents),
                            mod.managed_fragment('codex-agents-block',agents.replace(b'block',b'edited')))
        config=b'model = "a"\n[desktop]\nexternal-agent-import-sync-enabled = false\n'
        self.assertEqual(mod.managed_fragment('codex-config',config),
                         mod.managed_fragment('codex-config',b'model = "b"\n[desktop]\nexternal-agent-import-sync-enabled = false\n[extra]\nx = 1\n'))
        self.assertNotEqual(mod.managed_fragment('codex-config',config),
                            mod.managed_fragment('codex-config',config.replace(b'false',b'true')))
        import json
        sdlc={'type':'command','command':'sdlc.py hook','timeout':10,'statusMessage':'OpenAI SDLC: Stop'}
        hooks=json.dumps({'hooks':{'Stop':[{'hooks':[sdlc]}]}}).encode()
        mixed=json.dumps({'hooks':{'Stop':[{'hooks':[{'type':'command','command':'mine'}]},{'hooks':[sdlc]}]}}).encode()
        self.assertEqual(mod.managed_fragment('codex-hooks',hooks),mod.managed_fragment('codex-hooks',mixed))
        self.assertNotEqual(mod.managed_fragment('codex-hooks',hooks),
                            mod.managed_fragment('codex-hooks',hooks.replace(b'"timeout": 10',b'"timeout": 20')))
        agent=b'---\nname: implementer\nmodel: opus\n---\nbody\n'
        self.assertEqual(mod.managed_fragment('claude-agent',agent),
                         mod.managed_fragment('claude-agent',agent.replace(b'opus',b'sonnet')))
        self.assertNotEqual(mod.managed_fragment('claude-agent',agent),
                            mod.managed_fragment('claude-agent',agent.replace(b'body',b'edited')))
        with self.assertRaises(ValueError):mod.managed_fragment('unknown',b'')
        manifest=mod.build_manifest(ROOT,{Path('/tmp/AGENTS.md'):agents,Path('/tmp/doctor.py'):b'x'},
                                    fragments={Path('/tmp/AGENTS.md'):'codex-agents-block'})
        recorded=str(Path('/tmp').resolve()/'AGENTS.md')
        self.assertNotIn(recorded,manifest['managed_files'])
        self.assertEqual(manifest['managed_fragments'][recorded]['kind'],'codex-agents-block')
        self.assertEqual(len(manifest['managed_fragments'][recorded]['sha256']),64)
        self.assertIn(str(Path('/tmp').resolve()/'doctor.py'),manifest['managed_files'])

    def test_REQ_DOCTOR_002_missing_source_is_not_empty_pass(self):
        mod=self.module()
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):mod.source_snapshot(Path(d))

    def test_REQ_DOCTOR_002_both_installers_supply_doctor_and_receipt(self):
        import os,json,subprocess
        for harness in ('codex','claude'):
            with self.subTest(harness=harness), tempfile.TemporaryDirectory() as d:
                home=Path(d); workspace=home/'ws';workspace.mkdir()
                args=['bash',str(ROOT/'install.sh'),'--harness',harness]
                if harness=='codex':args+=['--home',d,'--workspace',str(workspace),'--apply']
                p=subprocess.run(args,env=dict(os.environ,HOME=d,SDLC_SCAN_ROOT=str(workspace)),capture_output=True)
                self.assertEqual(p.returncode,0,p.stderr.decode())
                runtime=home/('.codex/sdlc-openai' if harness=='codex' else '.claude')
                self.assertTrue((runtime/'scripts/doctor.py').is_file())
                receipt=json.loads((runtime/'doctor-installation.json').read_text())
                self.assertIn(str(runtime.resolve()/'scripts/doctor.py'),receipt['managed_files'])
                self.assertEqual(receipt['source']['path'],str(ROOT))
                if harness=='codex':
                    import tomllib
                    agent=tomllib.loads((home/'.codex/agents/implementer.toml').read_text())['developer_instructions']
                    workflow=(runtime/'skills/openai-sdlc/references/workflows.md').read_text()
                    self.assertIn('targeted tests',agent)
                    self.assertIn('coordinating session',workflow)
                    self.assertIn('stable tree',workflow)
                    again=subprocess.run(args,env=dict(os.environ,HOME=d,SDLC_SCAN_ROOT=str(workspace)),capture_output=True,text=True)
                    self.assertEqual(again.returncode,0,again.stderr)
                    self.assertNotIn('WRITE ',again.stdout)
                doctor=importlib.util.module_from_spec(importlib.util.spec_from_file_location('doctor_receipt',ROOT/'core/doctor.py'))
                doctor.__spec__.loader.exec_module(doctor)
                inspect=lambda: doctor.inspect_installation(runtime/'doctor-installation.json')
                self.assertEqual(inspect()['status'],'current',inspect()['issues'])
                if harness=='codex':
                    # Owner and client edits outside the installer-owned fragments are not drift.
                    config=home/'.codex/config.toml'; config.write_text('model = "owner-choice"\n'+config.read_text()+'\n[tui.model_availability_nux]\nsomething = 4\n')
                    agents=home/'.codex/AGENTS.md'; agents.write_text(agents.read_text()+'\n## Owner notes\nKeep these.\n')
                    hooks=home/'.codex/hooks.json'; document=json.loads(hooks.read_text())
                    document['hooks'].setdefault('PreToolUse',[]).insert(0,{'matcher':'Bash','hooks':[{'type':'command','command':'owner-guard'}]})
                    hooks.write_text(json.dumps(document,indent=2))
                    self.assertEqual(inspect()['status'],'current',inspect()['issues'])
                    # Edits inside the installer-owned fragment are drift.
                    agents.write_text(agents.read_text().replace('openai-sdlc:begin -->','openai-sdlc:begin -->\nINJECTED'))
                    self.assertEqual(inspect()['status'],'drifted')
                    self.assertTrue(any('AGENTS.md' in issue for issue in inspect()['issues']))
                else:
                    agent=home/'.claude/agents/implementer.md'
                    text=agent.read_text(); self.assertIn('\nmodel: ',text)
                    build=(runtime/'commands/build.md').read_text()
                    self.assertIn('targeted tests',text)
                    self.assertIn('stable tree',build)
                    self.assertIn('coordinating session',build)
                    agent.write_text(text.replace('\nmodel: ','\nmodel: owner-choice-',1))
                    self.assertEqual(inspect()['status'],'current',inspect()['issues'])
                    agent.write_text(agent.read_text()+'\nowner edit outside routing\n')
                    self.assertEqual(inspect()['status'],'drifted')

    def test_REQ_DOCTOR_002_source_mode_changes_invalidate_evidence(self):
        mod=self.module()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); (root/'core').mkdir(); (root/'install.sh').write_text('true')
            (root/'install.sh').chmod(0o644)
            before=mod.source_snapshot(root)['fingerprint']
            (root/'install.sh').chmod(0o755)
            self.assertNotEqual(before,mod.source_snapshot(root)['fingerprint'])


class SkillWalkTests(unittest.TestCase):
    """REQ-MOD-025: the skills install path prunes excluded trees while it walks."""

    def module(self):
        spec = importlib.util.spec_from_file_location('installation_walk', ROOT/'core/installation.py')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def source(self, root):
        (root/'core').mkdir()
        (root/'core/tool.py').write_text('one')
        (root/'install.sh').write_text('true')
        claude = root/'adapters/claude'
        claude.mkdir(parents=True)
        (claude/'skill-exclusions.txt').write_bytes((ROOT/'adapters/claude/skill-exclusions.txt').read_bytes())
        mod = claude/'skills/sdlc-engine-map'
        (mod/'.claude-plugin').mkdir(parents=True)
        (mod/'hooks').mkdir()
        (mod/'.claude-plugin/plugin.json').write_text('{}')
        (mod/'hooks/register.ts').write_text('export {}')
        # A large tree the engine lays beside a loaded mod: many directories deep.
        for i in range(30):
            deep = mod/'node_modules'/f'pkg{i}'/'lib'/'dist'
            deep.mkdir(parents=True)
            (deep/'index.js').write_text('1')
        (mod/'.claude-plugin/types/claude-code').mkdir(parents=True)
        (mod/'.claude-plugin/types/claude-code/index.d.ts').write_text('export {}')
        return mod

    def test_REQ_MOD_025_excluded_trees_are_pruned_not_walked(self):
        mod = self.module()
        with tempfile.TemporaryDirectory() as d:
            root = Path(d).resolve()
            self.source(root)
            runtime = root/'runtime'
            runtime.mkdir()
            visited = []
            real = os.scandir

            def counting(path='.'):
                visited.append(str(path))
                return real(path)

            with patch.object(os, 'scandir', counting):
                files = mod.source_files(root)
                writes = mod.claude_skill_writes(root, runtime)

            skill = 'adapters/claude/skills/sdlc-engine-map/'
            self.assertIn(skill + '.claude-plugin/plugin.json', files)
            self.assertIn(skill + 'hooks/register.ts', files)
            self.assertFalse([k for k in files if 'node_modules' in k or '/types/' in k])
            self.assertEqual(sorted(str(p.relative_to(runtime)) for p in writes),
                             ['skills/sdlc-engine-map/.claude-plugin/plugin.json',
                              'skills/sdlc-engine-map/hooks/register.ts'])
            self.assertTrue(visited, 'the walk must go through os.scandir for this test to mean anything')
            self.assertEqual([p for p in visited if 'node_modules' in p or '.claude-plugin/types' in p], [])
