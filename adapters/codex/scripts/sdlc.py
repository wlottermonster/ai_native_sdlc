#!/usr/bin/env python3.12
"""Durable task loops and bounded verification. No model calls or credentials."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from protected_paths import guard as protected_path_guard


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.write-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def state_path(repo, run):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,63}', run):
        raise ValueError('Run name must be lowercase letters, digits and hyphens')
    root = Path(repo).resolve()
    path = root / '.sdlc-openai' / 'runs' / (run + '.json')
    for parent in (root / '.sdlc-openai', path.parent, path):
        if parent.is_symlink():
            raise ValueError('State paths must not be symlinks')
    return path


@contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = path.with_suffix('.lock')
    if lock.is_symlink():
        raise ValueError('Lock path must not be a symlink')
    with lock.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def read_state(repo, run):
    return json.loads(state_path(repo, run).read_text())


def begin(repo, run, objective, budget=12):
    if not objective.strip() or not 1 <= budget <= 1000:
        raise ValueError('An objective and attempt budget 1..1000 are required')
    path = state_path(repo, run)
    with locked(path):
        if path.exists():
            raise ValueError('Run already exists; inspect its status or use a new name')
        state = dict(objective=objective, status='active', attempts=0, budget=budget,
                     repeated_failures=0, failure='', next_step='Read project instructions and relevant source',
                     stop_reason=None, evidence=None, created_at=time.time(), history=[])
        atomic_json(path, state)
    return state


def fingerprint(repo):
    """Hash Git-tracked and untracked nonignored content, excluding runtime state."""
    repo = Path(repo)
    result = subprocess.run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=repo, capture_output=True)
    if result.returncode:
        paths = sorted(p.relative_to(repo).as_posix() for p in repo.rglob('*') if p.is_file() and '.sdlc-openai' not in p.parts)
    else:
        paths = sorted(set(os.fsdecode(p) for p in result.stdout.split(b'\0') if p))
    digest = hashlib.sha256()
    for name in paths:
        if name.startswith('.sdlc-openai/'):
            continue
        path = repo / name
        digest.update(os.fsencode(name) + b'\0')
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(str(path.stat().st_mode).encode())
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
        else:
            digest.update(b'<missing>')
    return digest.hexdigest()


def record(repo, run, outcome, failure='', next_step=''):
    path = state_path(repo, run)
    with locked(path):
        state = read_state(repo, run)
        if state['status'] != 'active':
            raise ValueError('Run is terminal; inspect the stop reason before starting a new run')
        if outcome not in ('progress', 'failure', 'complete', 'blocked'):
            raise ValueError('Unknown outcome')
        if outcome == 'complete':
            evidence = state.get('evidence')
            if not evidence or evidence['exit_code'] != 0 or evidence['fingerprint'] != fingerprint(repo):
                raise ValueError('Completion needs a passing check against the current files')
            state['status'] = 'complete'
        else:
            if not next_step.strip():
                raise ValueError('Record a concrete next step')
            if outcome in ('failure', 'blocked') and not failure.strip():
                raise ValueError('Record the failure or blocking reason')
            state['attempts'] += 1
            state['repeated_failures'] = (state['repeated_failures'] + 1 if state['failure'] == failure else 1) if outcome == 'failure' else 0
            state['failure'] = failure
            if outcome in ('failure', 'blocked'):
                state['evidence'] = None
            if outcome == 'blocked':
                state.update(status='blocked', stop_reason=failure)
            elif state['repeated_failures'] >= 3:
                state.update(status='blocked', stop_reason='repeated_failure_limit')
            elif state['attempts'] >= state['budget']:
                state.update(status='blocked', stop_reason='attempt_budget')
        state['next_step'] = next_step
        state['history'].append(dict(at=time.time(), outcome=outcome, failure=failure, next_step=next_step))
        atomic_json(path, state)
    return state


def run_command(repo, command, timeout, output):
    if not command or timeout <= 0:
        raise ValueError('A command and positive timeout are required')
    start = time.monotonic()
    timed_out = False
    with output.open('wb') as log:
        try:
            process = subprocess.Popen(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as exc:
            log.write(str(exc).encode())
            return dict(exit_code=127, timed_out=False, duration_seconds=time.monotonic() - start)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            code = 124
    return dict(exit_code=code, timed_out=timed_out, duration_seconds=round(time.monotonic() - start, 3))


def check(repo, run, command, timeout=300):
    path = state_path(repo, run)
    with locked(path):
        state = read_state(repo, run)
        if state['status'] != 'active':
            raise ValueError('Cannot check a terminal run')
        before = fingerprint(repo)
        log = path.with_suffix('.log')
        if log.is_symlink():
            raise ValueError('Log must not be a symlink')
        result = run_command(repo, command, timeout, log)
        after = fingerprint(repo)
        result.update(command=command, at=time.time(), fingerprint=before, log=str(log), files_changed_during_check=before != after)
        if before != after and result['exit_code'] == 0:
            result['exit_code'] = 125
        state['evidence'] = result
        atomic_json(path, state)
    return result


def in_scope(cwd, workspace):
    return Path(cwd).resolve().is_relative_to(Path(workspace).resolve())


def shell_tokens(command):
    """Lex the gate's small shell subset without executing or expanding anything.

    Keep literal words distinct from operators, and inspect executable $(...) /
    backticks separately. This is deliberately not a shell interpreter: aliases,
    functions, arbitrary programs and advanced shell grammar remain out of scope.
    """
    index = 0
    substitutions = []
    malformed = False
    dynamic = False

    def scan(stop=None):
        nonlocal index, malformed, dynamic
        tokens, word = [], []
        quote = None
        started = False
        plain = True
        groups = 0
        heredocs = []
        delimiter_operator = None

        def flush(kind='word'):
            nonlocal started, plain, delimiter_operator
            if started:
                value = ''.join(word)
                tokens.append((kind, value))
                if delimiter_operator is not None:
                    heredocs.append((value, not plain, delimiter_operator == '<<-'))
                    delimiter_operator = None
                word.clear()
                started = False
                plain = True

        def consume_heredocs():
            nonlocal index, malformed, dynamic
            for delimiter, quoted, strip_tabs in heredocs:
                end = index
                while end < len(command):
                    newline = command.find('\n', end)
                    newline = len(command) if newline < 0 else newline
                    line = command[end:newline]
                    if (line.lstrip('\t') if strip_tabs else line) == delimiter:
                        break
                    end = min(newline + 1, len(command))
                else:
                    malformed = True
                    newline = len(command)
                if not quoted:
                    # Heredoc quotes are ordinary data. Only backslash escapes
                    # and executable substitutions affect recognition here.
                    while index < end:
                        if command[index] == '\\' and index + 1 < end and command[index + 1] in '\\$`\n':
                            index += 2
                        elif command.startswith('$(', index) or command[index] == '`':
                            closing = ')' if command[index] == '$' else '`'
                            index += 2 if closing == ')' else 1
                            substitutions.append(scan(closing))
                            dynamic = True
                        else:
                            index += 1
                index = min(newline + 1, len(command))
            heredocs.clear()

        while index < len(command):
            char = command[index]
            if quote is None and char == stop and groups == 0:
                flush()
                index += 1
                return tokens
            if quote == "'":
                if char == "'":
                    quote = None
                else:
                    word.append(char)
                index += 1
                continue
            if char == '\\':
                index += 1
                if index == len(command):
                    malformed = True
                    break
                escaped = command[index]
                if quote == '"' and escaped not in '$`"\\\n':
                    word.append('\\')
                if escaped != '\n':
                    plain = False
                    word.append(escaped)
                    started = True
                index += 1
                continue
            if char == '"' or (char == "'" and quote is None):
                plain = False
                quote = None if quote == char else char
                started = True
                index += 1
                continue
            if command.startswith('$(', index) or char == '`':
                closing = ')' if char == '$' else '`'
                index += 2 if char == '$' else 1
                substitutions.append(scan(closing))
                word.append('<substitution>')
                started = dynamic = True
                continue
            if char == '$' or (quote is None and char in '~*?['):
                dynamic = True
            if quote is None:
                if char == '#' and not started:
                    while index < len(command) and command[index] != '\n':
                        index += 1
                    continue
                if char.isspace() and char != '\n':
                    flush()
                    index += 1
                    continue
                if char in ';\n|&<>()':
                    io_number = char in '<>' and plain and ''.join(word).isdigit()
                    flush('io_number' if io_number else 'word')
                    operator = next((op for op in ('&>>', '&>', '<<<', '<<-', '<<', '>>', '>&', '<&', '<>', '>|')
                                     if command.startswith(op, index)), char)
                    tokens.append(('operator', operator))
                    if operator in ('<<', '<<-'):
                        delimiter_operator = operator
                    if char == '(':
                        groups += 1
                    elif char == ')' and groups:
                        groups -= 1
                    index += len(operator)
                    if char == '\n':
                        consume_heredocs()
                    continue
            word.append(char)
            started = True
            index += 1
        flush()
        malformed = malformed or quote is not None or stop is not None
        return tokens

    tokens = scan()
    return tokens, substitutions, malformed, dynamic


def command_has_commit(words):
    """Recognize Git command heads and a bounded set of common wrappers."""
    words = list(words)
    while words:
        if re.match(r'^[A-Za-z_][A-Za-z_0-9]*=', words[0]):
            words.pop(0)
            continue
        executable = Path(words[0]).name
        if executable in ('env', 'command'):
            words.pop(0)
            while words and words[0].startswith('-'):
                option = words.pop(0)
                if executable == 'command' and any(c in option[1:] for c in 'vV'):
                    return False  # command -v/-V looks up names; it does not execute.
                if option in ('-u', '--unset', '-C', '--chdir') and words:
                    words.pop(0)
                if option == '--':
                    break
            continue
        if executable in ('sh', 'bash', 'zsh', 'dash', 'ksh'):
            for index, option in enumerate(words[1:], 1):
                if not option.startswith('-'):
                    break
                if 'c' in option[1:] and not option.startswith('--'):
                    return index + 1 < len(words) and recognized_commit(words[index + 1])[0]
            return False
        if executable != 'git':
            return False
        index = 1
        while index < len(words):
            option = words[index]
            if option == '--':
                index += 1
                break
            if not option.startswith('-'):
                break
            index += 2 if option in ('-C', '-c', '--git-dir', '--work-tree',
                                     '--namespace', '--config-env', '--super-prefix') else 1
        return index < len(words) and words[index] == 'commit'
    return False


def recognized_commit(command):
    """Return (recognized, literal standalone words or None).

    Only the caller's git [-C directory]* commit form may run the check. Other
    recognized execution contexts are denied, never interpreted or executed.
    """
    tokens, substitutions, malformed, dynamic = shell_tokens(command)

    def contains_commit(stream):
        words = []
        redirect = False
        for kind, value in stream + [('operator', ';')]:
            if kind == 'io_number':
                continue
            if kind == 'operator':
                if value in ('<', '>', '<<', '<<-', '<<<', '>>', '>&', '<&', '<>', '>|', '&>', '&>>'):
                    redirect = True
                else:
                    if command_has_commit(words):
                        return True
                    words = []
                    redirect = False
            elif redirect:
                redirect = False
            else:
                words.append(value)
        return False

    found = contains_commit(tokens) or any(contains_commit(s) for s in substitutions)
    standalone = not (malformed or dynamic or substitutions) and all(k == 'word' for k, _ in tokens)
    return found, [v for _, v in tokens] if standalone else None


def handoff_yield(repo, session_id):
    """Only explicit session-owned handoffs suppress the continuation reminder."""
    if not session_id:
        return False
    import importlib.util
    helper = Path(__file__).with_name('handoff_store.py')
    if not helper.is_file():
        helper = Path(__file__).resolve().parents[3] / 'core/handoff_store.py'
    if not helper.is_file():
        return False
    try:
        spec = importlib.util.spec_from_file_location('sdlc_handoff_store', helper)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.should_yield('codex', session_id, repo=repo)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, SyntaxError, ImportError, AttributeError):
        return False


def checkout_root(cwd):
    """Resolve the Git top level; a cwd Git cannot place stays the root itself."""
    try:
        result = subprocess.run(['git', '-C', str(cwd), 'rev-parse', '--show-toplevel'],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return Path(cwd)
    top = result.stdout.decode().strip()
    return Path(top) if result.returncode == 0 and top else Path(cwd)


def hook(payload, settings, framework):
    cwd = payload.get('cwd')
    if not cwd:
        return {}
    event = payload.get('hook_event_name')

    def deny(reason):
        return {'hookSpecificOutput': {'hookEventName': event, 'permissionDecision': 'deny', 'permissionDecisionReason': reason}}

    execution_cwd = Path(cwd)
    cwd_in_scope = in_scope(cwd, settings['workspace'])
    tool_input = payload.get('tool_input', {})
    if event == 'PreToolUse' and isinstance(tool_input, dict) and 'workdir' in tool_input:
        try:
            workdir = tool_input['workdir']
            if not isinstance(workdir, str) or not workdir.strip() or '\x00' in workdir:
                raise ValueError('workdir must be a nonempty directory path')
            execution_cwd = (Path(cwd) / workdir).resolve(strict=True)
            if not execution_cwd.is_dir():
                raise ValueError('workdir must name a directory')
        except (OSError, RuntimeError, ValueError) as error:
            return deny(f'Invalid tool workdir: {error}') if cwd_in_scope else {}
    if not cwd_in_scope and not (event == 'PreToolUse' and in_scope(execution_cwd, settings['workspace'])):
        return {}
    if event == 'PreToolUse':
        reason = protected_path_guard(payload, settings['workspace'])
        if reason:
            return {'hookSpecificOutput': {'hookEventName': event, 'permissionDecision': 'deny', 'permissionDecisionReason': reason}}
        if payload.get('tool_name') not in (None, 'Bash', 'exec_command', 'shell_command'):
            return {}
        if not isinstance(tool_input, dict):
            return deny('Invalid shell tool input')
        if 'command' in tool_input and 'cmd' in tool_input and tool_input['command'] != tool_input['cmd']:
            return deny('Conflicting command and cmd fields; provide one unambiguous command.')
        command = tool_input.get('command', tool_input.get('cmd', ''))
        if not isinstance(command, str):
            return deny('Shell command must be a string')
        recognized, tokens = recognized_commit(command)
        if not recognized:
            return {}
        if not tokens or tokens[0] != 'git':
            return deny('Run git commit as a standalone command so the SDLC gate can identify its repository.')
        repo = execution_cwd
        index = 1
        while index < len(tokens) and tokens[index] == '-C':
            if index + 1 >= len(tokens):
                return deny('Missing git -C directory')
            repo = (repo / tokens[index + 1]).resolve()
            index += 2
        if index >= len(tokens) or tokens[index] != 'commit':
            return deny('Unsupported commit wrapper/options; use git [-C path] commit.')
        if not in_scope(repo, settings['workspace']):
            return {}
        if not (repo / 'Makefile').is_file():
            return deny('No Makefile check contract. Add a project-specific make check adapter before committing; a missing check is not a pass.')
        with tempfile.TemporaryDirectory(prefix='sdlc-check-') as temp:
            output = Path(temp) / 'check.log'
            result = run_command(repo, ['make', 'check'], 870, output)
            if result['exit_code']:
                return deny(f'make check failed (exit {result["exit_code"]}). Run it explicitly and inspect the output before retrying.')
        return {}
    if event in ('SessionStart', 'PostCompact'):
        context = f'OpenAI SDLC applies here. Read {framework}/policy.md and {framework}/engines.toml. Use the openai-sdlc skill for software work. Resume from task artifacts and .sdlc-openai/runs, not chat recollection. This framework is independent of Claude. Model roles inherit your actual selected model unless the owner specifies otherwise. Do not claim a model switch from reading a file.'
        if event == 'PostCompact':
            # Codex accepts universal output only here; unlike SessionStart,
            # this event cannot inject additionalContext into the model.
            return {'systemMessage': context}
        return {'hookSpecificOutput': {'hookEventName': event, 'additionalContext': context}}
    if event == 'Stop' and not payload.get('stop_hook_active'):
        root = checkout_root(cwd)
        if handoff_yield(root, payload.get('session_id')):
            return {}
        active = []
        for path in sorted((root / '.sdlc-openai/runs').glob('*.json')):
            state = json.loads(path.read_text())
            if state['status'] == 'active':
                active.append(path.stem)
        if active:
            return {'decision': 'block', 'reason': 'OpenAI SDLC active runs: ' + ', '.join(active) + '. Save progress/next step, or run checks and record completion. If awaiting user input or genuinely blocked, report that accurately. Do not invent completion. This reminder continues only once.'}
    return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    sub = parser.add_subparsers(dest='action', required=True)
    init = sub.add_parser('begin')
    init.add_argument('run')
    init.add_argument('objective')
    init.add_argument('--budget', type=int, default=12)
    status = sub.add_parser('status')
    status.add_argument('run')
    rec = sub.add_parser('record')
    rec.add_argument('run')
    rec.add_argument('outcome', choices=['progress', 'failure', 'complete', 'blocked'])
    rec.add_argument('--failure', default='')
    rec.add_argument('--next', default='', dest='next_step')
    verify = sub.add_parser('check')
    verify.add_argument('run')
    verify.add_argument('--timeout', type=float, default=300)
    verify.add_argument('command', nargs=argparse.REMAINDER)
    sub.add_parser('hook')
    args = parser.parse_args()
    if args.action == 'hook':
        framework = Path(__file__).resolve().parents[1]
        settings = json.loads((framework / 'installation.json').read_text())
        result = hook(json.load(sys.stdin), settings, framework)
    elif args.action == 'begin':
        result = begin(args.repo, args.run, args.objective, args.budget)
    elif args.action == 'status':
        result = read_state(args.repo, args.run)
    elif args.action == 'record':
        result = record(args.repo, args.run, args.outcome, args.failure, args.next_step)
    else:
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        result = check(args.repo, args.run, command, args.timeout)
    print(json.dumps(result, indent=2))
    return result.get('exit_code', 0)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError) as error:
        print(f'OpenAI SDLC: {error}', file=sys.stderr)
        sys.exit(2)
