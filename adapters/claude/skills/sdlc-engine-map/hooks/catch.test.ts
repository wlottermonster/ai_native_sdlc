// The `.catch` on every registration, run by the engine itself through the test
// kit. The test's own hooks sit beneath the plugin and stand for the engine.
//
// Before `next`, the mod's own hooks no longer have a failure the engine can
// provoke: a session state that refuses to open falls back to process memory
// and routing goes on (proven below for all four hooks), the reads they make
// are caught, and the ui calls are fire-and-forget. So the before-next branch
// of the mod's own `.catch` literals is proven with fakes in safety.test.ts,
// and here the engine's side of it (a hook that throws before `next` gets its
// `.catch` with `called` false) runs the mod's announceFailure in a `.catch`
// on a hook of the test's own. A failure after `next` is provoked by the hook
// beneath throwing, so the mod's own `await next(...)` rejects. The mod's
// hooks await nothing but `$` calls and `next`, which the budget does not
// count, so they cannot be made to overrun from the clock; the overrun case
// runs the same announceFailure in a `.catch` on a hook of the test's that
// waits on the mocked clock past its budget (ten seconds of real time on this
// build).
import { test, expect, mock } from 'claude-code/testing'
import type { On } from 'claude-code'
import { announceFailure, failureNotice } from './safety.ts'
import { createNotices } from './notices.ts'
import { subagentVariableNotice } from './status.ts'

const HOME = '/fx/t'
const FILES: Record<string, string> = {
  [`${HOME}/.claude/sdlc-engines.conf`]: 'build = testbuild-9\nread = testread-9\n',
  [`${HOME}/.claude/agents/roles.conf`]: 'implementer = build\n',
}

type Seen = { toasts: string[]; logs: string[]; status: (string | undefined)[]; reads: string[] }

function uiBeneath(on: On): Seen {
  const seen: Seen = { toasts: [], logs: [], status: [], reads: [] }
  on('ui.toast', ($, e) => { seen.toasts.push(e.text); return { value: undefined } })
  on('ui.log', ($, e) => { seen.logs.push(e.text); return { value: undefined } })
  on('ui.status', ($, e) => { seen.status.push(e.text); return { value: undefined } })
  on('fs.read', ($, e) => {
    seen.reads.push(e.path)
    const text = FILES[e.path]
    return text === undefined ? { deny: `ENOENT: ${e.path}` } : { value: text }
  })
  on('fs.exists', ($, e) => ({ value: FILES[e.path] !== undefined }))
  on('session.root', () => ({ value: '/work/repo' }))
  on('session.model', () => ({ value: 'claude-testjudge-9-1' }))
  return seen
}

function refuseState(on: On): void {
  on('state.get', () => ({ deny: 'session state refused for the test' }))
}

const failures = (seen: Seen) => seen.toasts.filter(t => t.includes('hook failed'))

const stateNotices = (seen: Seen) => seen.toasts.filter(t => t.includes('session state unavailable'))

test('REQ-MOD-018 agent.spawn with a session state that refuses to open still routes, says so once and fails nothing', async ($, on) => {
  mock.env(on, { HOME })
  refuseState(on)
  const seen = uiBeneath(on)
  const spawned: { subagentType: string; model?: string }[] = []
  on('agent.spawn', ($, e) => {
    spawned.push({ subagentType: e.subagentType, model: e.model })
    return { model: e.model ?? 'frontmatter', agentId: `agent-${spawned.length}` }
  })

  await $.agent.spawn({ prompt: 'do the task', subagentType: 'implementer' })
  await $.agent.spawn({ prompt: 'do it again', subagentType: 'implementer' })

  expect(spawned).toEqual([
    { subagentType: 'implementer', model: 'testbuild-9' },
    { subagentType: 'implementer', model: 'testbuild-9' },
  ])
  expect(failures(seen)).toEqual([])
  expect(stateNotices(seen).length).toBe(1)
  expect(seen.logs).toEqual(seen.toasts)
})

test('REQ-MOD-004 agent.spawn throwing after next: what settled beneath stands and nothing beneath runs again', async ($, on) => {
  mock.env(on, { HOME })
  const seen = uiBeneath(on)
  let ran = 0
  on('agent.spawn', () => {
    ran++
    throw new Error('the spawn failed beneath')
  })

  let outcome: string
  try {
    await $.agent.spawn({ prompt: 'do the task', subagentType: 'implementer' })
    outcome = 'resolved'
  } catch (err) {
    outcome = `rejected: ${err instanceof Error ? err.message : String(err)}`
  }

  expect(ran).toBe(1)
  expect(outcome).toContain('rejected')
  const said = failures(seen)
  expect(said.length).toBe(1)
  expect(said[0]).toContain('agent.spawn')
  expect(said[0]).toContain('(throw')
  expect(said[0]).toContain('settled')
  expect(seen.logs).toEqual(seen.toasts)
})

test('REQ-MOD-018 session.start with a session state that refuses to open still sets the status line and fails nothing', async ($, on) => {
  mock.env(on, { HOME })
  refuseState(on)
  const seen = uiBeneath(on)
  const reached: string[] = []
  on('session.start', ($, e) => { reached.push(e.cwd); return { cwd: e.cwd } })

  const r = await $.session.start({ cwd: '/work/repo', surface: null, isInteractive: false })

  expect(r.cwd).toBe('/work/repo')
  expect(reached).toEqual(['/work/repo'])
  expect(failures(seen)).toEqual([])
  expect(stateNotices(seen).length).toBe(1)
  expect(seen.status.length).toBe(1)
})

test('REQ-MOD-018 turn.start with a session state that refuses to open still sets the status line and says so once over two turns', async ($, on) => {
  mock.env(on, { HOME })
  refuseState(on)
  const seen = uiBeneath(on)
  const reached: string[] = []
  on('turn.start', ($, e) => { reached.push(e.turnId); return { turnId: e.turnId } })

  await $.turn.start({ text: 'hello', turnId: 't1' })
  await $.turn.start({ text: 'again', turnId: 't2' })

  expect(reached).toEqual(['t1', 't2'])
  expect(failures(seen)).toEqual([])
  expect(stateNotices(seen).length).toBe(1)
  expect(seen.status.length).toBe(2)
})

test('REQ-MOD-018 turn.complete with a session state that refuses to open ends the turn as given and fails nothing', async ($, on) => {
  mock.env(on, { HOME })
  refuseState(on)
  const seen = uiBeneath(on)
  const reached: string[] = []
  on('turn.complete', ($, e) => { reached.push(e.reason); return { text: e.answer } })

  const r = await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't', reason: 'error', agentId: 'agent-x' } as never)

  expect(r.text).toBe('done')
  expect(reached).toEqual(['error'])
  expect(failures(seen)).toEqual([])
  expect(stateNotices(seen).length).toBe(1)
})

// The engine's side of the before-next branch: a hook that throws before it
// calls `next` gets its `.catch` with kind `throw` and `called` false, and the
// mod's announceFailure says it once over two failures. (A test's own hooks
// may not call `$` nouns its module does not call, so the handler records
// through plain closures.)
test('REQ-MOD-004 REQ-MOD-018 a hook throwing before next is caught with called false, the event proceeds, and the same failure is announced once', async ($, on) => {
  mock.env(on, { HOME })
  uiBeneath(on)
  const memory = new Set<string>()
  const shown: string[] = []
  const kinds: { kind: string; called: boolean }[] = []
  on('turn.start', () => {
    throw new Error('fault before next')
  }).catch(async ($, e, next) => {
    kinds.push({ kind: next.error.kind, called: next.called })
    await announceFailure({
      toast: text => { shown.push(text) },
      log: () => {},
      open: async () => ({ notices: createNotices(memory), save: async () => {} }),
      memory,
    }, 'turn.start', next.error, next.called)
    return { turnId: e.turnId }
  })

  const a = await $.turn.start({ text: 'hello', turnId: 't1' })
  const b = await $.turn.start({ text: 'again', turnId: 't2' })

  expect(a.turnId).toBe('t1')
  expect(b.turnId).toBe('t2')
  expect(kinds).toEqual([{ kind: 'throw', called: false }, { kind: 'throw', called: false }])
  expect(shown.length).toBe(1)
  expect(shown[0]).toContain('turn.start')
  expect(shown[0]).toContain('(throw')
  expect(shown[0]).toContain('fault before next')
  expect(shown[0]).toContain('un-routed')
})

// A test's own hooks may not call `$` nouns its module does not call (a host
// rule), so this hook waits on the mocked clock's own `sleep` and the handler
// records through plain closures; announceFailure is the mod's own.
test('REQ-MOD-004 a hook overrunning its budget on the mocked clock is caught as a timeout and announced', { timeoutMs: 30_000 }, async ($, on) => {
  const clock = mock.clock(on)
  mock.env(on, { HOME })
  uiBeneath(on)
  const memory = new Set<string>()
  const shown: string[] = []
  const logged: string[] = []
  const kinds: { kind: string; called: boolean }[] = []
  on('agent.spawn', async () => {
    await clock.sleep(60_000)
    return { model: 'late', agentId: 'never' }
  }).catch(async ($, e, next) => {
    kinds.push({ kind: next.error.kind, called: next.called })
    await announceFailure({
      toast: text => { shown.push(text) },
      log: text => { logged.push(text) },
      open: async () => ({ notices: createNotices(memory), save: async () => {} }),
      memory,
    }, 'agent.spawn', next.error, next.called)
    return { model: 'caught', agentId: 'agent-caught' }
  })

  const pending = $.agent.spawn({ prompt: 'wait', subagentType: 'general-purpose' })
  await clock.settle()
  const got = await pending

  expect(kinds).toEqual([{ kind: 'timeout', called: false }])
  const expected = failureNotice('agent.spawn', { kind: 'timeout' }, false)
  expect(shown).toEqual([expected])
  expect(logged).toEqual([expected])
  expect(got.agentId).toBe('agent-caught')
})

// --- the message set in the session state, through the engine ------------------

function stateBeneath(on: On, stored: string[] | undefined) {
  const writes: unknown[] = []
  let value = stored
  let version = stored === undefined ? 0 : 1
  // Only the message set is held; the chain key reads as never written.
  on('state.get', ($, e) => ({ value: (e.key !== 'said' ? { version: 0 } : value === undefined ? { version } : { value, version }) as never }))
  on('state.set', ($, e) => {
    if (e.key !== 'said') return { value: { isSet: true, version: 1 } as never }
    writes.push(e.value)
    value = e.value as string[]
    version += 1
    return { value: { isSet: true, version } as never }
  })
  return writes
}

test('REQ-MOD-018 a new message is shown as toast and transcript line, never on the status line, and written to the session state', async ($, on) => {
  mock.env(on, { HOME, CLAUDE_CODE_SUBAGENT_MODEL: 'testother-9' })
  const writes = stateBeneath(on, undefined)
  const seen = uiBeneath(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/work/repo', surface: null, isInteractive: false })

  const notice = subagentVariableNotice('testother-9')
  expect(seen.toasts).toEqual([notice])
  expect(seen.logs).toEqual([notice])
  expect(seen.status.length).toBe(1)
  expect(seen.status[0]).not.toBe(notice)
  expect(writes.length).toBe(1)
  expect(writes[0]).toContain(`text:${notice}`)
})

test('REQ-MOD-018 a message the session state already holds is not shown again, as after a hot reload', async ($, on) => {
  mock.env(on, { HOME, CLAUDE_CODE_SUBAGENT_MODEL: 'testother-9' })
  const writes = stateBeneath(on, [`text:${subagentVariableNotice('testother-9')}`])
  const seen = uiBeneath(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/work/repo', surface: null, isInteractive: false })

  expect(seen.toasts).toEqual([])
  expect(seen.logs).toEqual([])
  expect(writes).toEqual([])
})
