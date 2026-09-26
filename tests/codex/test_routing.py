"""Native Codex routing retains instructions and validates central intent."""
import importlib.util
from pathlib import Path
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAP = b'''[roles]\nbuild = "gpt-5.6-sol"\nread = "gpt-5.6-terra"\n[reasoning]\nbuild = "high"\nread = "medium"\n[agents]\nimplementer = "build"\nresearcher = "read"\n'''
TEMPLATE = b'''name = "implementer"\ndescription = "Build things"\ndeveloper_instructions = """Keep all instructions.\nmodel = 'inside instructions'\n[not_a_table]\n"""\n[tools]\ncustom = true\n'''

class RoutingTests(unittest.TestCase):
    def module(self):
        spec = importlib.util.spec_from_file_location('routing', ROOT/'adapters/codex/scripts/routing.py')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def templates(self):
        return {'implementer': TEMPLATE, 'researcher': TEMPLATE.replace(b'implementer', b'researcher')}

    def test_REQ_ROUTE_002_preserves_existing_native_instructions_and_settings(self):
        """REQ-ROUTE-002, REQ-ROUTE-005: generated agents keep instructions and unrelated fields; a second plan is idempotent."""
        mod = self.module()
        old = b'model = "old"\nmodel_reasoning_effort = "low"\n' + TEMPLATE
        result = mod.plan_agents(MAP, {'implementer': old}, self.templates())
        value = tomllib.loads(result['implementer'].decode())
        original = tomllib.loads(TEMPLATE.decode())
        self.assertEqual(value['developer_instructions'], original['developer_instructions'])
        self.assertEqual(value['tools'], original['tools'])
        self.assertEqual(value['model'], 'gpt-5.6-sol')
        self.assertEqual(value['model_reasoning_effort'], 'high')
        self.assertEqual(tomllib.loads(result['researcher'].decode())['model'], 'gpt-5.6-terra')
        self.assertEqual(result, mod.plan_agents(MAP, result, self.templates()))

    def test_REQ_ROUTE_002_inline_settings_before_quoted_multiline_override(self):
        """REQ-ROUTE-002, REQ-ROUTE-005: an unrelated inline setting survives an override rewrite."""
        mod = self.module()
        old = b'custom = { enabled = true }\n"model" = """old"""\n' + TEMPLATE
        generated = mod.plan_agents(MAP, {'implementer': old}, self.templates())
        self.assertEqual(tomllib.loads(generated['implementer'].decode())['custom'], {'enabled': True})

    def test_REQ_ROUTE_001_default_assignments(self):
        """REQ-ROUTE-001: the shipped central map binds each role to its model and reasoning pair."""
        mod = self.module()
        mapping = mod.parse_map((ROOT/'adapters/codex/engines.toml').read_bytes())
        self.assertEqual(mapping['roles'], {'judge': 'gpt-6-astra', 'build': 'gpt-5.6-sol', 'verify': 'gpt-5.6-sol', 'read': 'gpt-5.6-terra', 'escalate': 'gpt-6-astra'})
        self.assertEqual(mapping['agents']['implementer'], 'build')
        self.assertEqual(mapping['agents']['escalation'], 'escalate')
        self.assertEqual(mapping['reasoning']['escalate'], 'xhigh')

    def test_REQ_ROUTE_001_inherit_removes_both_overrides(self):
        """REQ-ROUTE-001: inherit leaves the model to the session, removing both overrides."""
        mod = self.module()
        existing = mod.plan_agents(MAP, {}, self.templates())
        inherited = MAP.replace(b'gpt-5.6-sol', b'inherit')
        result = tomllib.loads(mod.plan_agents(inherited, existing, self.templates())['implementer'].decode())
        self.assertNotIn('model', result)
        self.assertNotIn('model_reasoning_effort', result)

    def test_REQ_ROUTE_003_malformed_maps_and_agents_fail_closed(self):
        """REQ-ROUTE-003, REQ-ROUTE-005: malformed maps and agent definitions fail closed."""
        mod = self.module()
        for invalid in [b'bad', MAP.replace(b'implementer =', b'"../escape" ='), MAP.replace(b'"high"', b'"magic"'), MAP.replace(b'"build"', b'"unknown"'), MAP.replace(b'gpt-5.6-sol', b'bad model'), MAP + b'\n[typo]\nx = 1']:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                mod.plan_agents(invalid, {}, self.templates())
        for invalid in [b'name = "implementer"', TEMPLATE.replace(b'implementer', b'other'), TEMPLATE + b'\nnot valid']:
            with self.subTest(agent=invalid), self.assertRaises(ValueError):
                mod.plan_agents(MAP, {'implementer': invalid}, self.templates())

    def test_REQ_ROUTE_003_inspect_reports_drift_and_never_live_selection(self):
        """REQ-ROUTE-003, REQ-ROUTE-005: drift and a broken map are reported; live selection stays unverified."""
        mod = self.module()
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            runtime = home/'.codex/sdlc-openai'
            agents = home/'.codex/agents'
            runtime.mkdir(parents=True); agents.mkdir(parents=True)
            (runtime/'engines.toml').write_bytes(MAP)
            for name, content in mod.plan_agents(MAP, {}, self.templates()).items():
                (agents/(name+'.toml')).write_bytes(content)
            result = mod.inspect_routing(home)
            self.assertEqual(result['status'], 'current')
            self.assertEqual(result['live_selection'], 'unverified')
            (agents/'implementer.toml').write_bytes(TEMPLATE)
            self.assertEqual(mod.inspect_routing(home)['status'], 'drifted')
            (runtime/'engines.toml').write_text('broken')
            self.assertEqual(mod.inspect_routing(home)['status'], 'blocked')

    def test_REQ_ROUTE_004_no_fallback_chain_and_no_implicit_escalation(self):
        """REQ-ROUTE-004: a role binds one model, never a fallback list, and only the
        escalation agent is routed to the escalate role in the shipped map."""
        mod = self.module()
        for chain in (b'"gpt-5.6-sol,gpt-5.6-terra"', b'"gpt-5.6-sol, gpt-5.6-terra"', b'"gpt-5.6-sol|gpt-5.6-terra"'):
            with self.subTest(chain=chain), self.assertRaises(ValueError):
                mod.parse_map(MAP.replace(b'"gpt-5.6-sol"', chain))
        with self.assertRaises(ValueError):
            mod.parse_map(MAP.replace(b'"gpt-5.6-sol"', b'"owner-only"'))
        mapping = mod.parse_map((ROOT/'adapters/codex/engines.toml').read_bytes())
        escalating = sorted(name for name, role in mapping['agents'].items() if role == 'escalate')
        self.assertEqual(escalating, ['escalation'])

if __name__ == '__main__':
    unittest.main()
