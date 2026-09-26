"""Real Git-mirror behavior: removing the contract must never allow a commit."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CommitContractTests(unittest.TestCase):
    def test_hook_clears_repository_selectors_before_checks(self):
        for template in ['core/templates/pre-commit', 'adapters/claude/templates/pre-commit']:
            with self.subTest(template=template), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                subprocess.run(['git', 'init', '-q', str(root)], check=True)
                (root / 'Makefile').write_text('check:\n\t@python3.12 probe.py\n')
                (root / 'probe.py').write_text(
                    "import os, subprocess\n"
                    "assert 'GIT_DIR' not in os.environ\n"
                    "assert 'GIT_INDEX_FILE' not in os.environ\n"
                    "assert os.environ['DOCTOR_SENTINEL'] == 'preserved'\n"
                    "subprocess.run(['git', 'init', '-q', '--bare', 'fixture'], check=True)\n")
                env = dict(os.environ, GIT_DIR=str(root / '.git'),
                           GIT_INDEX_FILE=str(root / '.git/index'), DOCTOR_SENTINEL='preserved')
                result = subprocess.run(['sh', str(ROOT / template)], cwd=root, env=env, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual(subprocess.check_output(['git', '-C', str(root), 'config', 'core.bare'], text=True).strip(), 'false')

    def test_hook_keeps_detached_gitdir_discoverable(self):
        """Dropping Git selectors must not leave make check unable to find the repository."""
        for template in ['core/templates/pre-commit', 'adapters/claude/templates/pre-commit']:
            with self.subTest(template=template), tempfile.TemporaryDirectory() as d:
                root = Path(d).resolve()
                work = root / 'work'; work.mkdir()
                gitdir = root / 'gitdir'
                subprocess.run(['git', '--git-dir', str(gitdir), '--work-tree', str(work), 'init', '-q'], check=True)
                (work / 'Makefile').write_text('check:\n\t@python3.12 probe.py\n')
                (work / 'probe.py').write_text(
                    "import os, subprocess\n"
                    "top = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()\n"
                    "assert os.path.realpath(top) == os.path.realpath(os.getcwd()), top\n")
                env = dict(os.environ, GIT_DIR=str(gitdir), GIT_WORK_TREE=str(work))
                result = subprocess.run(['sh', str(ROOT / template)], cwd=work, env=env, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_missing_or_broken_contract_denies_both_templates(self):
        cases = [(None, False), ('test:\n\t@true\n', False),
                 ('check:\n\t@false\n', False), ('check:\n\t@true\n', True),
                 ('.PHONY: check\ncheck :\n\t@true\n', True)]
        for template in ['templates/pre-commit', 'adapters/claude/templates/pre-commit', 'core/templates/pre-commit']:
            for recipe, allowed in cases:
                with self.subTest(template=template, recipe=recipe), tempfile.TemporaryDirectory() as d:
                    if recipe is not None:
                        (Path(d) / 'Makefile').write_text(recipe)
                    result = subprocess.run(['sh', str(ROOT / template)], cwd=d,
                                            capture_output=True, env={'PATH': os.environ['PATH']})
                    self.assertEqual(result.returncode == 0, allowed, result.stderr.decode())


class OnboardingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'project'
        self.repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        (self.repo / 'Makefile').write_text('.PHONY: check test\ncheck:\n\t@false\ntest:\n\t@false\n')

    def run_tool(self, *args):
        return subprocess.run(['python3.12', str(ROOT / 'core/project.py'), '--repo', str(self.repo), *args],
                              capture_output=True, text=True)

    def test_apply_is_non_destructive_and_idempotent(self):
        (self.repo / 'CLAUDE.md').write_text('Keep domain rules.\n')
        result = self.run_tool('--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.repo / 'CLAUDE.md').read_text(), 'Keep domain rules.\n')
        self.assertIn('CLAUDE.md', (self.repo / 'AGENTS.md').read_text())
        before = (self.repo / 'AGENTS.md').read_bytes()
        self.assertEqual(self.run_tool('--apply').returncode, 0)
        self.assertEqual((self.repo / 'AGENTS.md').read_bytes(), before)
        hook = self.repo / '.git/hooks/pre-commit'
        self.assertTrue(os.access(hook, os.X_OK))
        self.assertNotEqual(subprocess.run([str(hook)], cwd=self.repo, capture_output=True).returncode, 0)

    def test_missing_contract_is_reported_without_inventing_checks(self):
        (self.repo / 'Makefile').unlink()
        self.assertNotEqual(self.run_tool('--apply').returncode, 0)
        self.assertFalse((self.repo / 'Makefile').exists())
        self.assertFalse((self.repo / 'AGENTS.md').exists())

    def test_custom_hook_and_symlink_are_preserved(self):
        hook = self.repo / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\necho custom\n')
        self.assertNotEqual(self.run_tool('--apply').returncode, 0)
        self.assertEqual(hook.read_text(), '#!/bin/sh\necho custom\n')
        hook.unlink()
        outside = Path(self.temp.name) / 'outside'
        outside.write_text('sentinel')
        (self.repo / 'AGENTS.md').symlink_to(outside)
        self.assertNotEqual(self.run_tool('--apply').returncode, 0)
        self.assertEqual(outside.read_text(), 'sentinel')

    def test_inspect_never_mutates(self):
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertFalse((self.repo / 'AGENTS.md').exists())

    def test_shared_hook_directory_is_not_modified(self):
        shared = Path(self.temp.name).resolve() / 'shared-hooks'
        shared.mkdir()
        subprocess.run(['git', '-C', str(self.repo), 'config', 'core.hooksPath', str(shared)], check=True)
        self.assertNotEqual(self.run_tool('--apply').returncode, 0)
        self.assertFalse((shared / 'pre-commit').exists())
