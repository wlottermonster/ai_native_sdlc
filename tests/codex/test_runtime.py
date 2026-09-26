import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

ROOT = Path(__file__).resolve().parents[2] / 'adapters/codex'


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)

    def module(self):
        path = ROOT / 'scripts/sdlc.py'
        self.assertTrue(path.exists(), 'Runtime not implemented')
        spec = importlib.util.spec_from_file_location('sdlc', path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_repeated_failures_stop_and_survive_reload(self):
        mod = self.module()
        mod.begin(self.repo, 'test', 'Fix login', 10)
        for _ in range(3):
            state = mod.record(self.repo, 'test', 'failure', 'login assertion', 'inspect fixture')
        self.assertEqual(state['status'], 'blocked')
        self.assertEqual(state['stop_reason'], 'repeated_failure_limit')
        self.assertEqual(mod.read_state(self.repo, 'test')['attempts'], 3)
        with self.assertRaises(ValueError):
            mod.record(self.repo, 'test', 'failure', 'login assertion', 'retry')

    def test_budget_and_completion_requires_passing_evidence(self):
        mod = self.module()
        mod.begin(self.repo, 'budget', 'Bounded task', 2)
        mod.record(self.repo, 'budget', 'failure', 'first', 'try different')
        self.assertEqual(mod.record(self.repo, 'budget', 'failure', 'second', 'inspect')['stop_reason'], 'attempt_budget')
        mod.begin(self.repo, 'done', 'Verify task', 5)
        with self.assertRaises(ValueError):
            mod.record(self.repo, 'done', 'complete', '', '')
        result = mod.check(self.repo, 'done', [sys.executable, '-c', 'print("ok")'], 5)
        self.assertEqual(result['exit_code'], 0)
        self.assertEqual(mod.record(self.repo, 'done', 'complete', '', '')['status'], 'complete')

    def test_failed_and_timed_out_checks_cannot_complete(self):
        mod = self.module()
        mod.begin(self.repo, 'fail', 'Fail', 5)
        self.assertEqual(mod.check(self.repo, 'fail', [sys.executable, '-c', 'raise SystemExit(7)'], 5)['exit_code'], 7)
        with self.assertRaises(ValueError):
            mod.record(self.repo, 'fail', 'complete', '', '')
        evidence = mod.check(self.repo, 'fail', [sys.executable, '-c', 'import time; time.sleep(10)'], .05)
        self.assertEqual(evidence['exit_code'], 124)
        self.assertTrue(evidence['timed_out'])

    def test_path_traversal_and_duplicate_runs_rejected(self):
        mod = self.module()
        with self.assertRaises(ValueError):
            mod.begin(self.repo, '../escape', 'Bad', 5)
        mod.begin(self.repo, 'one', 'Task', 5)
        with self.assertRaises(ValueError):
            mod.begin(self.repo, 'one', 'Overwrite', 5)

    def test_scope_and_hook_output(self):
        mod = self.module()
        ws = self.repo / 'ws'
        ws.mkdir()
        self.assertFalse(mod.in_scope(self.repo / 'ws-other', ws))
        self.assertTrue(mod.in_scope(ws / 'nested' / 'repo', ws))
        settings = {'workspace': str(ws)}
        outside = mod.hook({'cwd': str(self.repo), 'hook_event_name': 'SessionStart'}, settings, ROOT)
        self.assertEqual(outside, {})
        inside = mod.hook({'cwd': str(ws), 'hook_event_name': 'SessionStart'}, settings, ROOT)
        self.assertIn('additionalContext', inside['hookSpecificOutput'])
        self.assertEqual(mod.hook({'cwd': str(ws), 'hook_event_name': 'Stop', 'stop_hook_active': True}, settings, ROOT), {})

    def test_commit_gate_rejects_failed_and_missing_checks(self):
        mod = self.module()
        settings = {'workspace': str(self.repo)}
        payload = {'cwd': str(self.repo), 'hook_event_name': 'PreToolUse', 'tool_input': {'command': 'git commit -m test'}}
        self.assertEqual(mod.hook(payload, settings, ROOT)['hookSpecificOutput']['permissionDecision'], 'deny')
        (self.repo / 'Makefile').write_text('check:\n\t@exit 1\n')
        self.assertEqual(mod.hook(payload, settings, ROOT)['hookSpecificOutput']['permissionDecision'], 'deny')
        (self.repo / 'Makefile').write_text('check:\n\t@true\n')
        self.assertEqual(mod.hook(payload, settings, ROOT), {})

    def test_REQ_DUAL_001_native_cmd_runs_the_commit_gate(self):
        """REQ-DUAL-001: native commit checks use the actual execution directory."""
        mod = self.module()
        payload = {'cwd': str(self.repo), 'hook_event_name': 'PreToolUse',
                   'tool_name': 'exec_command', 'tool_input': {'cmd': 'git commit -m test'}}
        (self.repo / 'Makefile').write_text('check:\n\t@touch checked\n\t@exit 1\n')
        result = mod.hook(payload, {'workspace': str(self.repo)}, ROOT)
        self.assertEqual(result.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
        self.assertTrue((self.repo / 'checked').exists())

    def test_REQ_DUAL_001_workdir_controls_the_checked_repository(self):
        """REQ-DUAL-001: native commit checks use the actual execution directory."""
        mod = self.module()
        target = self.repo / 'target'
        target.mkdir()
        (self.repo / 'Makefile').write_text('check:\n\t@touch wrong-repository\n')
        (target / 'Makefile').write_text('check:\n\t@pwd > checked-cwd\n\t@exit 1\n')
        for workdir in ('target', str(target)):
            for key in ('command', 'cmd'):
                with self.subTest(workdir=workdir, key=key):
                    payload = {'cwd': str(self.repo), 'hook_event_name': 'PreToolUse',
                               'tool_name': 'exec_command',
                               'tool_input': {key: 'git commit -m test', 'workdir': workdir}}
                    result = mod.hook(payload, {'workspace': str(self.repo)}, ROOT)
                    self.assertEqual(result.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
                    self.assertEqual(Path((target / 'checked-cwd').read_text().strip()), target.resolve())
                    self.assertFalse((self.repo / 'wrong-repository').exists())

    def test_REQ_DUAL_001_workdir_inside_workspace_from_outside_cwd_is_gated(self):
        """REQ-DUAL-001: native commit checks use the actual execution directory."""
        mod = self.module()
        target = self.repo / 'ws'
        target.mkdir()
        (target / 'Makefile').write_text('check:\n\t@touch checked\n\t@exit 1\n')
        payload = {'cwd': str(self.repo), 'hook_event_name': 'PreToolUse',
                   'tool_name': 'exec_command',
                   'tool_input': {'cmd': 'git commit -m test', 'workdir': str(target)}}
        result = mod.hook(payload, {'workspace': str(target)}, ROOT)
        self.assertEqual(result.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
        self.assertTrue((target / 'checked').exists())

    def test_REQ_DUAL_001_invalid_workdir_and_ambiguous_command_deny(self):
        """REQ-DUAL-001: native commit checks use the actual execution directory."""
        mod = self.module()
        (self.repo / 'Makefile').write_text('check:\n\t@touch checked\n')
        for workdir in ('missing', 'Makefile', '', None, 42, [], '\0'):
            with self.subTest(workdir=workdir):
                payload = {'cwd': str(self.repo), 'hook_event_name': 'PreToolUse',
                           'tool_name': 'exec_command',
                           'tool_input': {'cmd': 'git commit -m test', 'workdir': workdir}}
                result = mod.hook(payload, {'workspace': str(self.repo)}, ROOT)
                self.assertEqual(result.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
                self.assertFalse((self.repo / 'checked').exists())
        payload = {'cwd': str(self.repo), 'hook_event_name': 'PreToolUse',
                   'tool_name': 'exec_command',
                   'tool_input': {'cmd': 'git commit -m test', 'command': 'git status'}}
        result = mod.hook(payload, {'workspace': str(self.repo)}, ROOT)
        self.assertEqual(result.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')

    def commit_hook(self, mod, command):
        return mod.hook({'cwd': str(self.repo), 'hook_event_name': 'PreToolUse',
                         'tool_input': {'command': command}},
                        {'workspace': str(self.repo)}, ROOT)

    def test_unrelated_commands_and_literal_prose_do_not_run_commit_gate(self):
        mod = self.module()
        # A real check creates a marker, so accidental execution is observable.
        (self.repo / 'Makefile').write_text('check:\n\t@touch checked\n')
        commands = [
            'git diff -- pre-commit', 'git diff -- commit', 'git status',
            "echo 'git commit'", 'echo "git commit; && | $(literal)"',
            "printf '%s' 'git commit; && | $(git commit)'",
            "rg 'git commit' README.md", 'cat git-commit-notes',
            "git diff -- 'git commit; notes'", 'git log --grep=commit',
            "echo 'git commit' && git status", "echo git commit",
            'git -C nested diff -- commit', "echo '$(git commit)'",
            r'echo "\$(git commit)"', '# git commit\ngit status',
            'echo "$(git diff -- commit)"',
            'command -v git commit', 'command -V git commit',
            'env command -v git commit',
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.commit_hook(mod, command), {})
                self.assertFalse((self.repo / 'checked').exists())

    def test_recognized_compound_wrapped_and_substitution_commits_deny(self):
        mod = self.module()
        (self.repo / 'Makefile').write_text('check:\n\t@touch checked\n')
        commands = [
            'true; git commit -m test', 'true && git commit -m test',
            'true | git commit -m test', 'true\ngit commit -m test',
            'git commit -m test && true', 'git commit -m test > out',
            'env git commit -m test', 'env NAME=value git commit -m test',
            'env -u NAME git commit -m test', 'command git commit -m test',
            '/usr/bin/git commit -m test', 'NAME=value git commit -m test',
            "sh -c 'git commit -m test'", "bash -lc 'git commit -m test'",
            "env command /bin/zsh -lc 'git commit -m test'",
            'git -c core.editor=true commit -m test',
            'git --no-pager commit -m test',
            'git --git-dir .git commit -m test',
            'echo $(git commit -m test)', 'echo "$(git commit -m test)"',
            'echo `git commit -m test`', 'echo "`git commit -m test`"',
            'echo "$(echo $(git commit -m test))"',
            "git commit -m \"$(date)\"", '(git commit -m test)',
            'git -C "$REPO" commit -m test',
        ]
        for command in commands:
            with self.subTest(command=command):
                result = self.commit_hook(mod, command)
                self.assertEqual(set(result), {'hookSpecificOutput'})
                output = result['hookSpecificOutput']
                self.assertEqual(set(output), {'hookEventName', 'permissionDecision',
                                              'permissionDecisionReason'})
                self.assertEqual(output['hookEventName'], 'PreToolUse')
                self.assertEqual(output['permissionDecision'], 'deny')
                self.assertFalse((self.repo / 'checked').exists())

    def test_literal_punctuation_in_commit_message_runs_check_once(self):
        mod = self.module()
        (self.repo / 'Makefile').write_text('check:\n\t@echo checked >> checks\n')
        command = "git commit -m 'literal ; && | `git commit` $(git commit) > <'"
        self.assertEqual(self.commit_hook(mod, command), {})
        self.assertEqual((self.repo / 'checks').read_text(), 'checked\n')

    def test_heredoc_data_is_not_an_executed_command(self):
        mod = self.module()
        (self.repo / 'Makefile').write_text('check:\n\t@touch checked\n')
        commands = [
            "cat <<'EOF'\ngit commit -m test\nEOF\n",
            'cat <<"EOF"\n$(git commit -m test)\n`git commit -m test`\nEOF\n',
            "cat <<\\EOF\n$(git commit -m test)\nEOF\n",
            'cat <<EOF\ngit commit -m test\nEOF\n',
            'cat <<EOF\n\\$(git commit -m test)\nEOF\n',
            'cat <<EOF\n$(git diff -- commit)\nEOF\n',
            "cat <<-'EOF'\n\tgit commit -m test\n\tEOF\n",
            "cat <<'FIRST' <<SECOND\ngit commit -m test\nFIRST\ngit commit -m test\nSECOND\n",
            "cat <<'EOF'\ngit commit -m test\nEOF\ngit status",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.commit_hook(mod, command), {})
                self.assertFalse((self.repo / 'checked').exists())

    def test_heredoc_substitutions_and_commands_after_body_are_recognized(self):
        mod = self.module()
        (self.repo / 'Makefile').write_text('check:\n\t@touch checked\n')
        commands = [
            'cat <<EOF\n$(git commit -m test)\nEOF\n',
            'cat <<EOF\n`git commit -m test`\nEOF\n',
            "cat <<EOF\n'$(git commit -m test)'\nEOF\n",
            'cat <<EOF\n$(git \\\ncommit -m test)\nEOF\n',
            'cat <<\\\nEOF\n$(git commit -m test)\nEOF\n',
            "cat <<'FIRST' <<SECOND\n$(git commit -m literal)\nFIRST\n$(git commit -m actual)\nSECOND\n",
            "cat <<'EOF'\ngit commit -m literal\nEOF\ngit commit -m actual",
        ]
        for command in commands:
            with self.subTest(command=command):
                result = self.commit_hook(mod, command)
                self.assertEqual(result.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
                self.assertFalse((self.repo / 'checked').exists())

    def test_fd_redirections_recognize_commits_without_running_checks(self):
        mod = self.module()
        (self.repo / 'Makefile').write_text('check:\n\t@touch checked\n')
        commands = [
            'git 2>/dev/null commit -m test', '2>/dev/null git commit -m test',
            'git 2>>/dev/null commit -m test', '2>>/dev/null git commit -m test',
            'git 2>/dev/null 1>/dev/null commit -m test',
            '2>/dev/null git 1>>/dev/null commit -m test',
            'git 2>&1 commit -m test', '2>&1 git commit -m test',
            'git 0</dev/null commit -m test',
            'git \\\n2>/dev/null commit -m test',
            'git &>/dev/null commit -m test', '&>/dev/null git commit -m test',
            'git &>>/dev/null commit -m test', '&>>/dev/null git commit -m test',
        ]
        for command in commands:
            with self.subTest(command=command):
                result = self.commit_hook(mod, command)
                self.assertEqual(result.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
                self.assertFalse((self.repo / 'checked').exists())

    def test_numeric_arguments_are_not_fd_redirections(self):
        mod = self.module()
        (self.repo / 'Makefile').write_text('check:\n\t@touch checked\n')
        for command in ('git 2 commit', 'git "2">/dev/null commit',
                        "git '2'>>/dev/null commit", 'git 2 >/dev/null commit',
                        '"2">/dev/null git commit', 'git "&>" commit',
                        "git '&>>' commit", "echo 'git &>/dev/null commit'"):
            with self.subTest(command=command):
                self.assertEqual(self.commit_hook(mod, command), {})
                self.assertFalse((self.repo / 'checked').exists())

    def test_repeated_git_C_resolves_repository_and_runs_check_once(self):
        mod = self.module()
        nested = self.repo / 'outer' / 'nested directory'
        nested.mkdir(parents=True)
        (nested / 'Makefile').write_text('check:\n\t@pwd > checked-cwd\n\t@echo checked >> checks\n')
        command = "git -C outer -C 'nested directory' commit -m test"
        self.assertEqual(self.commit_hook(mod, command), {})
        self.assertEqual(Path((nested / 'checked-cwd').read_text().strip()), nested.resolve())
        self.assertEqual((nested / 'checks').read_text(), 'checked\n')
        self.assertFalse((self.repo / 'checks').exists())

    def test_malformed_recognized_commits_return_structured_denial(self):
        mod = self.module()
        for command in ('git commit -m "unterminated', 'git commit -m trailing\\',
                        'echo "$(git commit', "sh -c 'git commit"):
            with self.subTest(command=command):
                result = self.commit_hook(mod, command)
                self.assertEqual(result['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_commit_check_timeout_denies_with_existing_budget(self):
        mod = self.module()
        (self.repo / 'Makefile').write_text('check:\n\t@true\n')
        # Keep long suites bounded without sleeping through the entire budget.
        with patch.object(mod, 'run_command', return_value={
                'exit_code': 124, 'timed_out': True, 'duration_seconds': 870}) as run:
            result = self.commit_hook(mod, 'git commit -m test')
        self.assertEqual(result['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertIn('124', result['hookSpecificOutput']['permissionDecisionReason'])
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[:3], (self.repo, ['make', 'check'], 870))

    def test_post_compact_uses_only_codex_common_output_fields(self):
        # Codex rust-v0.154.0 hooks/src/schema.rs:
        # PostCompactCommandOutputWire has universal fields only.
        mod = self.module()
        result = mod.hook({'cwd': str(self.repo), 'hook_event_name': 'PostCompact'},
                          {'workspace': str(self.repo)}, ROOT)
        self.assertEqual(set(result), {'systemMessage'})
        self.assertIn(str(ROOT / 'policy.md'), result['systemMessage'])

    def test_stop_active_run_requests_one_continuation_then_yields(self):
        # Codex StopCommandOutputWire accepts top-level decision/reason,
        # not hookSpecificOutput. Preserve real continuation semantics.
        mod = self.module()
        mod.begin(self.repo, 'active', 'Unfinished task', 5)
        payload = {'cwd': str(self.repo), 'hook_event_name': 'Stop'}
        settings = {'workspace': str(self.repo)}
        result = mod.hook(payload, settings, ROOT)
        self.assertEqual(set(result), {'decision', 'reason'})
        self.assertEqual(result['decision'], 'block')
        self.assertIn('active', result['reason'])
        self.assertEqual(mod.hook(dict(payload, stop_hook_active=True), settings, ROOT), {})
        mod.record(self.repo, 'active', 'blocked', 'Awaiting user', 'Wait')
        self.assertEqual(mod.hook(payload, settings, ROOT), {})

    def test_completion_rejects_stale_evidence(self):
        mod = self.module()
        mod.begin(self.repo, 'stale', 'Task', 5)
        mod.check(self.repo, 'stale', [sys.executable, '-c', 'pass'], 5)
        (self.repo / 'code.txt').write_text('changed')
        with self.assertRaises(ValueError):
            mod.record(self.repo, 'stale', 'complete', '', '')

    def test_failure_invalidates_preceding_pass(self):
        mod = self.module()
        mod.begin(self.repo, 'failure', 'Task', 5)
        mod.check(self.repo, 'failure', [sys.executable, '-c', 'pass'], 5)
        mod.record(self.repo, 'failure', 'failure', 'requirement unmet', 'Add a meaningful test')
        with self.assertRaises(ValueError):
            mod.record(self.repo, 'failure', 'complete', '', '')
