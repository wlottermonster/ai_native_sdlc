"""Plan native agent routing without changing the running session or contacting a host."""
import json
from pathlib import Path
import re
import tomllib

EFFORTS = {'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'}
NAME = re.compile(r'[a-z][a-z0-9_-]*\Z')
MODEL = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:/-]*\Z')


def parse_map(content):
    """Validate intent; model availability is deliberately a separate live question."""
    try:
        value = tomllib.loads(content.decode('utf-8'))
    except (ValueError, UnicodeError) as exc:
        raise ValueError('invalid routing TOML') from exc
    if set(value) - {'roles', 'reasoning', 'agents'}:
        raise ValueError('unknown routing section')
    roles, reasoning, agents = (value.get(k, {}) for k in ('roles', 'reasoning', 'agents'))
    if not isinstance(roles, dict) or not roles or not isinstance(reasoning, dict) or not isinstance(agents, dict) or not agents:
        raise ValueError('routing requires roles, reasoning, and agent mappings')
    for role, model in roles.items():
        if not NAME.fullmatch(role) or not isinstance(model, str) or not MODEL.fullmatch(model):
            raise ValueError('invalid role or model identifier')
        if model == 'owner-only':
            raise ValueError('owner-only is a dispatch policy, not a model identifier')
        if model != 'inherit' and role not in reasoning:
            raise ValueError('explicit model requires reasoning effort')
    for role, effort in reasoning.items():
        if role not in roles or not isinstance(effort, str) or effort not in EFFORTS:
            raise ValueError('invalid reasoning assignment')
    for name, role in agents.items():
        if not NAME.fullmatch(name) or not isinstance(role, str) or role not in roles:
            raise ValueError('invalid agent mapping')
    return {'roles': roles, 'reasoning': reasoning, 'agents': agents}


def parse_agent(content, name):
    try:
        value = tomllib.loads(content.decode('utf-8'))
    except (ValueError, UnicodeError) as exc:
        raise ValueError('invalid native agent TOML: ' + name) from exc
    for key in ('name', 'description', 'developer_instructions'):
        if not isinstance(value.get(key), str) or not value[key].strip():
            raise ValueError('agent requires ' + key + ': ' + name)
    if value['name'] != name:
        raise ValueError('agent name does not match filename: ' + name)
    for key in ('model', 'model_reasoning_effort'):
        if key in value and not isinstance(value[key], str):
            raise ValueError('agent override must be a string: ' + name)
    return value


def _without_overrides(content):
    # Parse complete TOML statements so model-like text inside multiline prompts
    # is never confused with a real top-level assignment. Stop at the first table.
    lines = content.decode('utf-8').splitlines(keepends=True)
    kept, pending = [], ''
    for index, line in enumerate(lines):
        pending += line
        try:
            statement = tomllib.loads(pending)
        except tomllib.TOMLDecodeError:
            continue
        if pending.lstrip().startswith('['):
            kept.append(pending)
            kept.extend(lines[index + 1:])
            pending = ''
            break
        if not set(statement) & {'model', 'model_reasoning_effort'}:
            kept.append(pending)
        pending = ''
    if pending:
        raise ValueError('unsupported native agent statement')
    return ''.join(kept)


def plan_agents(map_bytes, existing_agents, templates):
    """Return agent-name -> TOML bytes; preserve existing native instructions."""
    mapping = parse_map(map_bytes)
    writes = {}
    for name, role in mapping['agents'].items():
        content = existing_agents.get(name, templates.get(name))
        if content is None:
            raise ValueError('missing native agent template: ' + name)
        before = parse_agent(content, name)
        model = mapping['roles'][role]
        prefix = ''
        if model != 'inherit':
            prefix = 'model = ' + json.dumps(model) + '\n'
            prefix += 'model_reasoning_effort = ' + json.dumps(mapping['reasoning'][role]) + '\n'
        rendered = (prefix + _without_overrides(content)).encode('utf-8')
        after = parse_agent(rendered, name)
        unrelated = lambda obj: {k: v for k, v in obj.items() if k not in {'model', 'model_reasoning_effort'}}
        if unrelated(before) != unrelated(after):
            raise ValueError('routing would change unrelated native agent fields: ' + name)
        if model == 'inherit':
            if 'model' in after or 'model_reasoning_effort' in after:
                raise ValueError('cannot remove native overrides safely: ' + name)
        elif after.get('model') != model or after.get('model_reasoning_effort') != mapping['reasoning'][role]:
            raise ValueError('cannot set native overrides safely: ' + name)
        writes[name] = rendered
    return writes


def inspect_routing(home):
    """Inspect configured assignments, never infer runtime selection or support."""
    home = Path(home)
    report = {'status': 'blocked', 'issues': [], 'roles': {}, 'agents': {},
              'live_selection': 'unverified', 'model_availability': 'unverified'}
    try:
        mapping = parse_map((home/'.codex/sdlc-openai/engines.toml').read_bytes())
        report['roles'] = {role: {'model': model, 'reasoning': mapping['reasoning'].get(role) if model != 'inherit' else None}
                           for role, model in mapping['roles'].items()}
        report['agents'] = mapping['agents']
        for name, role in mapping['agents'].items():
            path = home/'.codex/agents'/(name + '.toml')
            try:
                agent = parse_agent(path.read_bytes(), name)
            except (OSError, ValueError):
                report['issues'].append('missing or invalid native agent: ' + name)
                continue
            model = mapping['roles'][role]
            if model == 'inherit':
                matches = 'model' not in agent and 'model_reasoning_effort' not in agent
            else:
                matches = agent.get('model') == model and agent.get('model_reasoning_effort') == mapping['reasoning'][role]
            if not matches:
                report['issues'].append('native routing differs from central map: ' + name)
        report['status'] = 'drifted' if report['issues'] else 'current'
    except (OSError, ValueError):
        report['issues'].append('central routing map is missing or invalid')
    return report
