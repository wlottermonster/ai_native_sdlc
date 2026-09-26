#!/usr/bin/env python3.12
"""Regenerate the legacy complete Claude policy from its two authored sources."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
policy = (root / 'core/policy.md').read_text() + '\n' + (root / 'adapters/claude/policy.md').read_text()
(root / 'sdlc-policy.md').write_text(policy)
