// The safety layer with fakes: the shared `.catch` handler (safety.ts) and the
// wrapped `register` called directly with a fake `on`, so every registration,
// every `.catch` it carries and every refused name can be looked at.
import { test, expect } from 'claude-code/testing'
import { announceFailure, failureNotice, refusedNotice, type OpenNotices } from './safety.ts'
import { createNotices } from './notices.ts'
import { register } from './register.ts'

type Said = { toasts: string[]; logs: string[]; status: unknown[]; fs: string[] }

// A fake `$` with the nouns the hooks and the handler touch. Every `fs` call is
// recorded, so "no file I/O" can be asserted; `$.state` keeps one value.
function fakeEngine(opts: { stateFails?: boolean } = {}) {
  const said: Said = { toasts: [], logs: [], status: [], fs: [] }
  let value: unknown = undefined
  let version = 0
  const $ = {
    env: { get: async (_: string) => undefined },
    session: { model: async () => 'testjudge-1', root: async () => '/work/repo' },
    fs: {
      read: async (p: string) => { said.fs.push(`read ${p}`); throw new Error('ENOENT') },
      exists: async (p: string) => { said.fs.push(`exists ${p}`); return false },
    },
    ui: {
      toast: (t: string) => { said.toasts.push(t) },
      log: (t: string) => { said.logs.push(t) },
      status: (t: unknown) => { said.status.push(t) },
    },
    state: {
      get: async (_: unknown) => {
        if (opts.stateFails) throw new Error('state refused')
        return value === undefined ? { version } : { value, version }
      },
      set: async (_: unknown, v: unknown, o?: { ifVersion?: number }) => {
        if (opts.stateFails) throw new Error('state refused')
        if (o?.ifVersion !== undefined && o.ifVersion !== version) return { isSet: false, version }
        value = v
        version += 1
        return { isSet: true, version }
      },
    },
    model: { complete: async () => ({ isAnswered: true, text: '.' }) },
  }
  return { $, said, stored: () => value }
}

// A fake `next` as a `.catch` handler receives it.
function caughtNext<E, R>(result: R, error: { kind: 'throw' | 'timeout'; message?: string }, called: boolean) {
  const calls: E[] = []
  const next = Object.assign((e: E) => { calls.push(e); return Promise.resolve(result) }, { error: { ...error, budget: 1000 }, called })
  return { next, calls }
}

test('REQ-MOD-004 the failure notice names the mod, the event, the kind and the message', () => {
  const text = failureNotice('agent.spawn', { kind: 'throw', message: 'boom' }, false)
  expect(text).toContain('engine map mod')
  expect(text).toContain('agent.spawn')
  expect(text).toContain('throw')
  expect(text).toContain('boom')
  expect(text).toContain('un-routed')
})

test('REQ-MOD-004 a timeout with no message still names the kind', () => {
  const text = failureNotice('turn.start', { kind: 'timeout' }, false)
  expect(text).toContain('turn.start')
  expect(text).toContain('timeout')
  expect(text).not.toContain('undefined')
})

test('REQ-MOD-004 a failure after next says the settled result stands', () => {
  const text = failureNotice('agent.spawn', { kind: 'throw', message: 'late' }, true)
  expect(text).toContain('settled')
  expect(text).not.toContain('un-routed')
})

// announceFailure with fakes: what it shows, from where, and that it never throws.
function failureDeps(opts: { open?: () => Promise<OpenNotices>; toast?: (t: string) => void } = {}) {
  const shown = { toasts: [] as string[], logs: [] as string[] }
  const memory = new Set<string>()
  return {
    shown,
    memory,
    deps: {
      toast: opts.toast ?? ((t: string) => { shown.toasts.push(t) }),
      log: (t: string) => { shown.logs.push(t) },
      open: opts.open ?? (async () => ({ notices: createNotices(memory), save: async () => {} })),
      memory,
    },
  }
}

test('REQ-MOD-004 announceFailure shows the notice as a toast and a transcript line', async () => {
  const { deps, shown } = failureDeps()
  await announceFailure(deps, 'agent.spawn', { kind: 'throw', message: 'boom' }, false)
  expect(shown.toasts.length).toBe(1)
  expect(shown.toasts[0]).toBe(failureNotice('agent.spawn', { kind: 'throw', message: 'boom' }, false))
  expect(shown.logs).toEqual(shown.toasts)
})

test('REQ-MOD-004 REQ-MOD-018 an identical failure is announced once, a different one again', async () => {
  const { deps, shown } = failureDeps()
  await announceFailure(deps, 'turn.start', { kind: 'throw', message: 'same' }, false)
  await announceFailure(deps, 'turn.start', { kind: 'throw', message: 'same' }, false)
  await announceFailure(deps, 'turn.start', { kind: 'timeout' }, false)
  expect(shown.toasts.length).toBe(2)
  expect(shown.toasts[1]).toContain('timeout')
})

test('REQ-MOD-004 REQ-MOD-018 when the session state cannot be opened the failure is still announced once from process memory', async () => {
  const { deps, shown } = failureDeps({ open: async () => { throw new Error('state refused') } })
  await announceFailure(deps, 'session.start', { kind: 'throw', message: 'same fault' }, false)
  await announceFailure(deps, 'session.start', { kind: 'throw', message: 'same fault' }, false)
  expect(shown.toasts.length).toBe(1)
  expect(shown.logs.length).toBe(1)
})

test('REQ-MOD-004 REQ-MOD-018 what was announced is written to the session state', async () => {
  let saved = 0
  const memory = new Set<string>()
  const notices = createNotices(memory)
  const { deps } = failureDeps({ open: async () => ({ notices, save: async () => { saved++ } }) })
  await announceFailure(deps, 'turn.complete', { kind: 'throw', message: 'x' }, true)
  expect(saved).toBe(1)
  expect(notices.fresh().length).toBe(2)
})

test('REQ-MOD-004 an announcement that throws does not escape announceFailure', async () => {
  const { deps } = failureDeps({ toast: () => { throw new Error('no toast') } })
  await announceFailure(deps, 'turn.start', { kind: 'timeout' }, false)
  expect(true).toBe(true)
})

test('REQ-MOD-005 the refused notice names the events and says routing falls back to the agents\' frontmatter', () => {
  expect(refusedNotice([])).toBeUndefined()
  const text = refusedNotice(['turn.start', 'turn.complete'])
  expect(text).toContain('turn.start, turn.complete')
  expect(text).toContain('not registered')
  expect(text).toContain("falls back to the agents' frontmatter")
})

// A fake `on`: records each registration and the `.catch` handler it carries;
// throws for the names in `refuse`, as an engine refusing a registration would.
function fakeOn(refuse: string[] = []) {
  const hooks = new Map<string, Function>()
  const catches = new Map<string, Function>()
  const on = (event: string, hook: Function) => {
    if (refuse.includes(event)) throw new Error(`unknown event ${event}`)
    hooks.set(event, hook)
    return { catch: (handler: Function) => { catches.set(event, handler) } }
  }
  return { on, hooks, catches }
}

const EVENTS = ['agent.spawn', 'session.start', 'turn.complete', 'turn.start']

test('REQ-MOD-004 every registration carries a .catch, and each names its own event', async () => {
  const f = fakeOn()
  register(f.on as never)
  expect([...f.hooks.keys()].sort()).toEqual(EVENTS)
  expect([...f.catches.keys()].sort()).toEqual(EVENTS)
  for (const event of EVENTS) {
    const { $, said } = fakeEngine()
    const e = { marker: event }
    const { next, calls } = caughtNext<typeof e, string>('passed', { kind: 'throw', message: `fault in ${event}` }, false)
    expect(await f.catches.get(event)!($, e, next)).toBe('passed')
    expect(calls).toEqual([e])
    expect(said.toasts.length).toBe(1)
    expect(said.toasts[0]).toContain(event)
    expect(said.toasts[0]).toContain(`fault in ${event}`)
    expect(said.fs).toEqual([])
  }
})

test('REQ-MOD-004 a registration\'s .catch, when the hook had called next, returns what next replays and calls nothing else', async () => {
  const f = fakeOn()
  register(f.on as never)
  for (const event of EVENTS) {
    const { $, said } = fakeEngine()
    const { next, calls } = caughtNext<object, { settled: string }>({ settled: event }, { kind: 'throw', message: 'after next' }, true)
    expect(await f.catches.get(event)!($, { marker: event }, next)).toEqual({ settled: event })
    expect(calls.length).toBe(1)
    expect(said.toasts[0]).toContain('settled')
    expect(said.fs).toEqual([])
  }
})

// The mod's hooks await only `$` calls and `next`, which the budget does not
// count, so the engine cannot be made to overrun them from the clock; the
// timeout branch of their own `.catch` is driven here with the kind the engine
// would pass.
test('REQ-MOD-004 every registration\'s .catch announces a timeout and returns next(e)', async () => {
  const f = fakeOn()
  register(f.on as never)
  for (const event of EVENTS) {
    const { $, said } = fakeEngine()
    const e = { marker: event }
    const { next, calls } = caughtNext<typeof e, string>('passed', { kind: 'timeout' }, false)
    expect(await f.catches.get(event)!($, e, next)).toBe('passed')
    expect(calls).toEqual([e])
    expect(said.toasts).toEqual([failureNotice(event, { kind: 'timeout' }, false)])
    expect(said.logs).toEqual(said.toasts)
  }
})

test('REQ-MOD-005 a refused registration is recorded, the rest proceed, and the first hook that runs announces it once', async () => {
  const f = fakeOn(['turn.start'])
  register(f.on as never)
  expect([...f.hooks.keys()].sort()).toEqual(['agent.spawn', 'session.start', 'turn.complete'])
  expect([...f.catches.keys()].sort()).toEqual(['agent.spawn', 'session.start', 'turn.complete'])

  const { $, said } = fakeEngine()
  const passed: unknown[] = []
  const next = async (e: unknown) => { passed.push(e); return e }
  await f.hooks.get('session.start')!($, { source: 'startup' }, next)
  await f.hooks.get('agent.spawn')!($, { prompt: 'p', subagentType: 'general-purpose' }, async () => ({ model: 'm', agentId: 'a1' }))
  await f.hooks.get('turn.complete')!($, { reason: 'end', answer: '' }, next)

  const refused = said.toasts.filter(t => t.includes('turn.start'))
  expect(refused.length).toBe(1)
  expect(refused[0]).toContain("falls back to the agents' frontmatter")
  expect(said.logs.filter(t => t.includes('turn.start')).length).toBe(1)
  expect(passed.length).toBe(2)
})

test('REQ-MOD-018 a hook writes what it said into the session state, and a reopened set reads it back', async () => {
  const f = fakeOn()
  register(f.on as never)
  const { $, said, stored } = fakeEngine()
  $.env.get = async (name: string) => (name === 'CLAUDE_CODE_SUBAGENT_MODEL' ? 'testvar-1' : undefined)
  await f.hooks.get('session.start')!($, { source: 'startup' }, async (e: unknown) => e)
  expect(said.toasts.length).toBe(1)
  expect(said.toasts[0]).toContain('CLAUDE_CODE_SUBAGENT_MODEL')
  const kept = stored()
  expect(Array.isArray(kept)).toBe(true)
  expect((kept as string[]).some(s => s.includes(said.toasts[0]))).toBe(true)
  // The status line carries the standing state, never a notice.
  expect(said.status.some(s => s === said.toasts[0])).toBe(false)
})
