#!/usr/bin/env python3.12
"""Validate shipped Python, TOML, skill metadata and local markdown links."""
import ast
from pathlib import Path
import re
import tomllib

root = Path(__file__).resolve().parents[1]
for path in root.rglob('*.py'):
    ast.parse(path.read_text(), filename=str(path))
for path in root.rglob('*.toml'):
    tomllib.loads(path.read_text())
for path in (root / 'skills').rglob('SKILL.md'):
    text = path.read_text()
    assert re.match(r'---\nname: [a-z0-9-]+\ndescription: .+\n---\n', text), path
for path in root.rglob('*.md'):
    for link in re.findall(r'\]\(([^)]+)\)', path.read_text()):
        if not link.startswith(('http:', 'https:', '#', '/')):
            assert (path.parent / link.split('#')[0]).exists(), (path, link)
print('Python, TOML, skill metadata and local links valid')
