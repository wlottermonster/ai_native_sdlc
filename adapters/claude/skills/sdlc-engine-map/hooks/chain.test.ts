// The fallback chain, driven through the pure modules with fakes: route()
// choosing the entry in force, and onTurnComplete() classifying a routed
// subagent's failed turn with one bounded completion. The engine's `$` is
// adapted to these in register.ts and exercised in register.test.ts.
import { test, expect } from 'claude-code/testing'
import { route, type RouteDeps } from './routing.ts'
import { createNotices, type Notices } from './notices.ts'
import {
  createChain,
  createPending,
  classificationRequest,
  isUnavailable,
  onTurnComplete,
  PENDING_CAP,
  type ChainState,
  type Pending,
} from './chain.ts'

const HOME = '/fx/t'
const ROOT = '/work/repo'
const MAP = `${HOME}/.claude/sdlc-engines.conf`
const USER = `${HOME}/.claude/agents/roles.conf`

const GOOD_MAP = 'judge = testjudge-9\nbuild = testbuild-9, testbuild-8\nverify = testverify-9\nread = testread-9, testread-8, testread-7\n'
const GOOD_USER = 'implementer = build\nresearcher = read\nverifier = verify\n'

function deps(files: Record<string, string> = { [MAP]: GOOD_MAP, [USER]: GOOD_USER }): RouteDeps {
  // Read at every call, so a test that edits `files` edits the map on disk.
  return {
    home: HOME,
    root: ROOT,
    read: async (path: string) => {
      const text = files[path]
      if (text === undefined) throw new Error(`ENOENT: ${path}`)
      return text
    },
    exists: async (path: string) => files[path] !== undefined,
  }
}

function spawn(subagentType: string, extra: Record<string, unknown> = {}) {
  return { subagentType, prompt: 'do the task', fork: false, ...extra } as {
    subagentType: string
    model?: string
    fork?: boolean
    isTeammate?: boolean
  } & Record<string, unknown>
}

const USAGE = { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 }
const NOT_FOUND = { isAnswered: false, reason: 'api-error', status: 404, error: 'model_not_found', usage: USAGE }
const KIND_ONLY = { isAnswered: false, reason: 'api-error', status: null, error: 'model_not_found', usage: USAGE }
const RATE_LIMIT = { isAnswered: false, reason: 'api-error', status: 429, error: 'rate_limit', usage: USAGE }
const OVERLOADED = { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: USAGE }
const SERVER = { isAnswered: false, reason: 'api-error', status: 500, error: 'server_error', usage: USAGE }
const ANSWERED = { isAnswered: true, text: '.', usage: USAGE }
const ABORTED = { isAnswered: false, reason: 'aborted', usage: USAGE }
const EMPTY = { isAnswered: false, reason: 'empty-reply', usage: USAGE }

// One process: the chain state, the routed agents and the message set, plus a
// classifier fake that counts its calls and answers what the test says. `files`
// is the disk: a test may edit the map between dispatches.
function world(answer: unknown | ((model: string) => unknown) = NOT_FOUND, chain: ChainState = createChain()) {
  const files: Record<string, string> = { [MAP]: GOOD_MAP, [USER]: GOOD_USER }
  const pending: Pending = createPending()
  const notices: Notices = createNotices()
  const inflight = new Map<string, Promise<boolean>>()
  const classified: string[] = []
  const said: string[] = []
  let ids = 0
  const classify = async (model: string) => {
    classified.push(model)
    const a = typeof answer === 'function' ? (answer as (m: string) => unknown)(model) : answer
    if (a instanceof Error) throw a
    return a
  }
  // A dispatch as register.ts makes it: route, then remember the agent the
  // spawn resolved to when the mod set its model.
  async function dispatch(name: string, extra: Record<string, unknown> = {}) {
    const r = await route(spawn(name, extra), deps(files), notices, chain)
    if (r.notice !== undefined) said.push(r.notice)
    const agentId = `agent-${++ids}`
    if (r.dispatched !== undefined) pending.remember(agentId, r.dispatched)
    return { model: r.input.model, agentId }
  }
  async function complete(agentId: string | undefined, reason = 'error') {
    const out = await onTurnComplete({ agentId, reason }, { pending, chain, notices, classify, inflight })
    if (out.notice !== undefined) said.push(out.notice)
    return out
  }
  const gone = (role: string) => [...chain.gone(role)]
  return { chain, files, pending, notices, classified, said, gone, dispatch, complete }
}

// ---- REQ-MOD-011

test('REQ-MOD-011 the classification call is one token on the entry, bounded by a timeout of a few seconds', () => {
  const req = classificationRequest('testbuild-9')
  expect(req.model).toBe('testbuild-9')
  expect(req.maxTokens).toBe(1)
  expect(typeof req.timeoutMs).toBe('number')
  expect((req.timeoutMs as number) > 0 && (req.timeoutMs as number) <= 10000).toBe(true)
  expect(req.prompt.length > 0).toBe(true)
})

test('REQ-MOD-011 unavailable means a 404 or an error kind naming the model, nothing else', () => {
  expect(isUnavailable(NOT_FOUND)).toBe(true)
  expect(isUnavailable(KIND_ONLY)).toBe(true)
  expect(isUnavailable({ ...RATE_LIMIT, status: 404 })).toBe(true)
  for (const r of [RATE_LIMIT, OVERLOADED, SERVER, ANSWERED, ABORTED, EMPTY, undefined, null, 'model_not_found']) {
    expect(isUnavailable(r)).toBe(false)
  }
})

test('REQ-MOD-011 a 404 on a routed agent moves later dispatches of that role to the next entry, said once for the entry moved', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('implementer')
  const b = await w.dispatch('implementer')
  expect(a.model).toBe('testbuild-9')
  expect(b.model).toBe('testbuild-9')

  await w.complete(a.agentId)
  await w.complete(b.agentId)

  expect(w.classified).toEqual(['testbuild-9'])
  expect(w.gone('build')).toEqual(['testbuild-9'])
  expect((await w.dispatch('implementer')).model).toBe('testbuild-8')
  expect((await w.dispatch('implementer')).model).toBe('testbuild-8')
  expect(w.said.length).toBe(1)
  expect(w.said[0]).toContain('role build')
  expect(w.said[0]).toContain('testbuild-9 unavailable')
  expect(w.said[0]).toContain('testbuild-8')
})

test('REQ-MOD-011 an error kind naming the model with no status also moves the chain', async () => {
  const w = world(KIND_ONLY)
  const a = await w.dispatch('researcher')
  await w.complete(a.agentId)
  expect((await w.dispatch('researcher')).model).toBe('testread-8')
})

test('REQ-MOD-011 the chain moves only the failed role', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('implementer')
  await w.complete(a.agentId)
  expect((await w.dispatch('researcher')).model).toBe('testread-9')
  expect((await w.dispatch('implementer')).model).toBe('testbuild-8')
})

for (const [what, answer] of [
  ['a rate limit', RATE_LIMIT],
  ['overloaded', OVERLOADED],
  ['a server error', SERVER],
  ['an answer', ANSWERED],
  ['an aborted call', ABORTED],
  ['an empty reply', EMPTY],
  ['a rejected call', new Error('blocked model')],
] as [string, unknown][]) {
  test(`REQ-MOD-011 a classification that says ${what} leaves the chain where it is and says nothing`, async () => {
    const w = world(answer)
    const a = await w.dispatch('implementer')
    await w.complete(a.agentId)
    expect(w.classified).toEqual(['testbuild-9'])
    expect(w.gone('build')).toEqual([])
    expect((await w.dispatch('implementer')).model).toBe('testbuild-9')
    expect(w.said).toEqual([])
  })
}

test('REQ-MOD-011 an error turn the mod did not route makes no classification call', async () => {
  const w = world(NOT_FOUND)
  await w.dispatch('general-purpose')
  await w.dispatch('implementer', { model: 'testother-9' })
  await w.dispatch('implementer', { fork: true })
  await w.complete('agent-1')
  await w.complete('agent-2')
  await w.complete('agent-3')
  await w.complete('agent-never-seen')
  await w.complete(undefined)
  expect(w.classified).toEqual([])
  expect(w.gone('build')).toEqual([])
})

test('REQ-MOD-011 a turn that did not end in error makes no classification call', async () => {
  const w = world(NOT_FOUND)
  for (const reason of ['answer', 'aborted', 'refusal']) {
    const a = await w.dispatch('implementer')
    await w.complete(a.agentId, reason)
  }
  expect(w.classified).toEqual([])
  expect(w.gone('build')).toEqual([])
})

test('REQ-MOD-011 an error for an entry no longer in force does not move the chain again', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('researcher')
  const b = await w.dispatch('researcher')
  await w.complete(a.agentId)
  expect(w.gone('read')).toEqual(['testread-9'])
  await w.complete(b.agentId)
  expect(w.gone('read')).toEqual(['testread-9'])
  expect(w.classified).toEqual(['testread-9'])
  expect((await w.dispatch('researcher')).model).toBe('testread-8')
})

test('REQ-MOD-011 two failures of one entry in parallel make one classification call and move the chain once', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('researcher')
  const b = await w.dispatch('researcher')
  await Promise.all([w.complete(a.agentId), w.complete(b.agentId)])
  expect(w.classified).toEqual(['testread-9'])
  expect(w.gone('read')).toEqual(['testread-9'])
  expect(w.said.length).toBe(1)
})

test('REQ-MOD-011 a classification held open is shared by every failure of that entry until it settles', async () => {
  let release: (v: unknown) => void = () => {}
  const held = new Promise(resolve => { release = resolve })
  const w = world(() => held)
  const a = await w.dispatch('researcher')
  const b = await w.dispatch('researcher')
  const c = await w.dispatch('researcher')
  const all = Promise.all([w.complete(a.agentId), w.complete(b.agentId), w.complete(c.agentId)])
  release(NOT_FOUND)
  await all
  expect(w.classified).toEqual(['testread-9'])
  expect(w.said.length).toBe(1)
  expect((await w.dispatch('researcher')).model).toBe('testread-8')
})

test('REQ-MOD-011 an agent is classified at most once, a second error turn for it is ignored', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('researcher')
  await w.complete(a.agentId)
  const c = await w.dispatch('researcher')
  expect(c.model).toBe('testread-8')
  await w.complete(a.agentId)
  expect(w.classified).toEqual(['testread-9'])
  expect(w.gone('read')).toEqual(['testread-9'])
})

test('REQ-MOD-011 a second error turn for one agent makes no second classification call', async () => {
  const w = world(RATE_LIMIT)
  const a = await w.dispatch('researcher')
  await w.complete(a.agentId)
  await w.complete(a.agentId)
  expect(w.classified).toEqual(['testread-9'])
  expect(w.gone('read')).toEqual([])
})

test('REQ-MOD-011 a classification that comes back after the chain moved on marks only its own entry', async () => {
  // b's entry (testread-8) is classified after a's (testread-9) settled; then a
  // late failure of an agent still on testread-9 adds nothing and says nothing.
  const w = world(NOT_FOUND)
  const a1 = await w.dispatch('researcher')
  const a2 = await w.dispatch('researcher')
  await w.complete(a1.agentId)
  const b = await w.dispatch('researcher')
  await w.complete(b.agentId)
  expect(w.gone('read')).toEqual(['testread-9', 'testread-8'])
  await w.complete(a2.agentId)
  expect(w.classified).toEqual(['testread-9', 'testread-8'])
  expect(w.said.length).toBe(2)
  expect((await w.dispatch('researcher')).model).toBe('testread-7')
})

test('REQ-MOD-011 the chain is walked in order, one entry per unavailable answer', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('researcher')
  await w.complete(a.agentId)
  const b = await w.dispatch('researcher')
  expect(b.model).toBe('testread-8')
  await w.complete(b.agentId)
  expect((await w.dispatch('researcher')).model).toBe('testread-7')
  expect(w.classified).toEqual(['testread-9', 'testread-8'])
  expect(w.said.length).toBe(2)
  expect(w.said[0]).toContain('testread-9 unavailable')
  expect(w.said[1]).toContain('testread-8 unavailable')
})

test('REQ-MOD-011 a map edit after a fallback routes to the first entry of the edited list not classified unavailable', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('researcher')
  await w.complete(a.agentId)
  // The owner promotes testread-7 ahead of the dead entry.
  w.files[MAP] = GOOD_MAP.replace('read = testread-9, testread-8, testread-7', 'read = testread-7, testread-9, testread-8')
  expect((await w.dispatch('researcher')).model).toBe('testread-7')
  // And moves the dead entry first again: it is still skipped.
  w.files[MAP] = GOOD_MAP.replace('read = testread-9, testread-8, testread-7', 'read = testread-9, testread-6')
  expect((await w.dispatch('researcher')).model).toBe('testread-6')
})

test('REQ-MOD-011 a map edit that shortens a moved role leaves its remaining entry in force, not exhausted', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('implementer')
  await w.complete(a.agentId)
  w.files[MAP] = GOOD_MAP.replace('build = testbuild-9, testbuild-8', 'build = testbuild-6')
  expect((await w.dispatch('implementer')).model).toBe('testbuild-6')
  expect(w.said.filter(s => s.includes('all ')).length).toBe(0)
})

test('REQ-MOD-011 the entries classified unavailable are read back from the session state, so a reload keeps the role on its next entry', async () => {
  // A fresh process memory (module memory reset by a hot reload) over the
  // stored entries the session state kept.
  const reloaded = createChain(new Map(), { read: ['testread-9'] })
  const w = world(NOT_FOUND, reloaded)
  expect((await w.dispatch('researcher')).model).toBe('testread-8')
  expect(w.said).toEqual([])
})

test('REQ-MOD-011 a chain records what it marked, by role and entry, for the session state', () => {
  const memory = new Map<string, Set<string>>()
  const c = createChain(memory, { read: ['testread-9'] })
  expect(c.markGone('read', 'testread-9')).toBe(false)
  expect(c.markGone('build', 'testbuild-9')).toBe(true)
  expect(c.markGone('build', 'testbuild-9')).toBe(false)
  expect(c.fresh()).toEqual({ build: ['testbuild-9'] })
  // Process memory carries the mark to a chain opened later on the same memory.
  expect([...createChain(memory).gone('build')]).toEqual(['testbuild-9'])
})

test('REQ-MOD-011 the routed agents waiting for their first turn are capped, the oldest forgotten first', () => {
  const p = createPending()
  for (let i = 0; i <= PENDING_CAP; i++) p.remember(`agent-${i}`, { role: 'read', entry: 'testread-9', chain: ['testread-9'] })
  expect(p.take('agent-0')).toBe(undefined)
  expect(p.take('agent-1')?.entry).toBe('testread-9')
  expect(p.take(`agent-${PENDING_CAP}`)?.entry).toBe('testread-9')
  expect(PENDING_CAP > 0 && PENDING_CAP <= 256).toBe(true)
})

// ---- REQ-MOD-013

test('REQ-MOD-013 when every entry is unavailable later dispatches set no model and the role and count are said once', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('implementer')
  await w.complete(a.agentId)
  const b = await w.dispatch('implementer')
  expect(b.model).toBe('testbuild-8')
  await w.complete(b.agentId)

  const c = await w.dispatch('implementer')
  const d = await w.dispatch('implementer')
  expect(c.model).toBe(undefined)
  expect(d.model).toBe(undefined)
  expect(w.gone('build')).toEqual(['testbuild-9', 'testbuild-8'])
  const exhausted = w.said.filter(s => s.includes('all 2 entries'))
  expect(exhausted.length).toBe(1)
  expect(exhausted[0]).toContain('role build')
  expect(exhausted[0]).toContain('frontmatter decides')
})

test('REQ-MOD-013 a single-entry chain classified unavailable is exhausted at once and said with its count', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('verifier')
  await w.complete(a.agentId)
  expect((await w.dispatch('verifier')).model).toBe(undefined)
  expect(w.said.length).toBe(1)
  expect(w.said[0]).toContain('role verify')
  expect(w.said[0]).toContain('all 1 entries')
})

test('REQ-MOD-013 an exhausted role leaves an explicit model as given and other roles routed', async () => {
  const w = world(NOT_FOUND)
  const a = await w.dispatch('verifier')
  await w.complete(a.agentId)
  const r = await route(spawn('verifier', { model: 'testother-9' }), deps(), w.notices, w.chain)
  expect(r.input.model).toBe('testother-9')
  expect(r.dispatched).toBe(undefined)
  expect((await w.dispatch('implementer')).model).toBe('testbuild-9')
})
