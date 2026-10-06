// The registered agent.spawn hook, run by the engine itself through the test
// kit. The test's own hooks sit beneath the plugin and stand for the engine:
// the bottom agent.spawn records what reached it, ui.toast and ui.log record
// what the mod said.
import { test, expect, mock } from 'claude-code/testing'
import type { On } from 'claude-code'

const HOME = '/fx/t'

type Seen = { spawned: { subagentType: string; model?: string }[]; toasts: string[]; logs: string[] }

function engineBeneath(on: On): Seen {
  const seen: Seen = { spawned: [], toasts: [], logs: [] }
  on('agent.spawn', ($, e) => {
    seen.spawned.push({ subagentType: e.subagentType, model: e.model })
    return { model: e.model ?? 'frontmatter', agentId: `agent-${seen.spawned.length}` }
  })
  on('ui.toast', ($, e) => { seen.toasts.push(e.text); return { value: undefined } })
  on('ui.log', ($, e) => { seen.logs.push(e.text); return { value: undefined } })
  return seen
}

test('REQ-MOD-010 with no file system beneath it the hook passes every dispatch through and says so once', async ($, on) => {
  mock.env(on, { HOME })
  const seen = engineBeneath(on)

  await $.agent.spawn({ prompt: 'do the task', subagentType: 'implementer' })
  await $.agent.spawn({ prompt: 'do it again', subagentType: 'implementer' })

  expect(seen.spawned).toEqual([
    { subagentType: 'implementer', model: undefined },
    { subagentType: 'implementer', model: undefined },
  ])
  expect(seen.toasts.length).toBe(1)
  expect(seen.toasts[0]).toContain('routing is off')
  expect(seen.toasts[0]).toContain('roles.conf')
  expect(seen.toasts[0]).toContain('no implementation')
  expect(seen.logs).toEqual(seen.toasts)
})

test('REQ-MOD-007 with files answered beneath it the hook sets the role\'s first entry', async ($, on) => {
  mock.env(on, { HOME })
  const files: Record<string, string> = {
    [`${HOME}/.claude/sdlc-engines.conf`]: 'build = testbuild-9, testbuild-8\nread = testread-9\n',
    [`${HOME}/.claude/agents/roles.conf`]: 'implementer = build\nresearcher = read\n',
  }
  on('fs.read', ($, e) => {
    const text = files[e.path]
    return text === undefined ? { deny: `ENOENT: ${e.path}` } : { value: text }
  })
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }))
  on('session.root', () => ({ value: '/work/repo' }))
  const seen = engineBeneath(on)

  const got = await $.agent.spawn({ prompt: 'do the task', subagentType: 'implementer' })
  await $.agent.spawn({ prompt: 'look it up', subagentType: 'general-purpose' })

  expect(seen.spawned).toEqual([
    { subagentType: 'implementer', model: 'testbuild-9' },
    { subagentType: 'general-purpose', model: undefined },
  ])
  expect(got.model).toBe('testbuild-9')
  expect(seen.toasts).toEqual([])
})

// The kit loads a fresh plugin instance and session state per test, so the
// chain this test moves does not reach the other kit tests.
test('REQ-MOD-011 REQ-MOD-013 an error turn for a routed agent is classified once through the engine and moves later dispatches', async ($, on) => {
  mock.env(on, { HOME })
  const files: Record<string, string> = {
    [`${HOME}/.claude/sdlc-engines.conf`]: 'build = testbuild-9\nverify = testverify-9, testverify-8\n',
    [`${HOME}/.claude/agents/roles.conf`]: 'verifier = verify\n',
  }
  on('fs.read', ($, e) => {
    const text = files[e.path]
    return text === undefined ? { deny: `ENOENT: ${e.path}` } : { value: text }
  })
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }))
  on('session.root', () => ({ value: '/work/repo' }))
  const asked: { model: string; maxTokens?: number; timeoutMs?: number }[] = []
  on('model.complete', ($, e) => {
    asked.push({ model: e.model, maxTokens: e.maxTokens, timeoutMs: e.timeoutMs })
    const usage = { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 }
    return { value: { isAnswered: false, reason: 'api-error', status: 404, error: 'model_not_found', usage } as never }
  })
  const ended: string[] = []
  on('turn.complete', ($, e) => { ended.push(e.reason); return { text: e.answer } })
  const seen = engineBeneath(on)
  const turn = (agentId: string | undefined) =>
    $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't', reason: 'error', ...(agentId === undefined ? {} : { agentId }) } as never)

  const first = await $.agent.spawn({ prompt: 'check it', subagentType: 'verifier' })
  expect(first.model).toBe('testverify-9')
  await turn(undefined)
  expect(asked).toEqual([])
  const done = await turn(first.agentId)
  expect(done.text).toBe('')
  expect(asked.length).toBe(1)
  expect(asked[0].model).toBe('testverify-9')
  expect(asked[0].maxTokens).toBe(1)
  expect(seen.spawned.length).toBe(1)

  const second = await $.agent.spawn({ prompt: 'check it again', subagentType: 'verifier' })
  expect(second.model).toBe('testverify-8')
  await turn(second.agentId)
  const third = await $.agent.spawn({ prompt: 'check it once more', subagentType: 'verifier' })
  expect(third.model).toBe('frontmatter')
  expect(seen.spawned.map(s => s.model)).toEqual(['testverify-9', 'testverify-8', undefined])
  expect(ended).toEqual(['error', 'error', 'error'])
  expect(seen.toasts.length).toBe(2)
  expect(seen.toasts[0]).toContain('role verify')
  expect(seen.toasts[1]).toContain('all 2 entries')
  expect(seen.logs).toEqual(seen.toasts)
})

// The session state beneath, one value per key, recording every write.
function stateBeneath(on: On, stored: Record<string, unknown> = {}) {
  const values: Record<string, unknown> = { ...stored }
  const versions: Record<string, number> = {}
  const writes: { key: string; value: unknown }[] = []
  on('state.get', ($, e) => ({ value: { value: values[e.key], version: versions[e.key] ?? 0 } as never }))
  on('state.set', ($, e) => {
    writes.push({ key: e.key, value: e.value })
    values[e.key] = e.value
    versions[e.key] = (versions[e.key] ?? 0) + 1
    return { value: { isSet: true, version: versions[e.key] } as never }
  })
  return { values, writes }
}

function verifyFiles(on: On): void {
  const files: Record<string, string> = {
    [`${HOME}/.claude/sdlc-engines.conf`]: 'build = testbuild-9\nverify = testverify-9, testverify-8\n',
    [`${HOME}/.claude/agents/roles.conf`]: 'verifier = verify\nimplementer = build\n',
  }
  on('fs.read', ($, e) => {
    const text = files[e.path]
    return text === undefined ? { deny: `ENOENT: ${e.path}` } : { value: text }
  })
  on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }))
  on('session.root', () => ({ value: '/work/repo' }))
}

test('REQ-MOD-011 an entry classified unavailable is written to the session state by name', async ($, on) => {
  mock.env(on, { HOME })
  verifyFiles(on)
  const state = stateBeneath(on)
  on('model.complete', () => {
    const usage = { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 }
    return { value: { isAnswered: false, reason: 'api-error', status: 404, error: 'model_not_found', usage } as never }
  })
  on('turn.complete', ($, e) => ({ text: e.answer }))
  engineBeneath(on)

  const first = await $.agent.spawn({ prompt: 'check it', subagentType: 'verifier' })
  await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't', reason: 'error', agentId: first.agentId } as never)

  expect(state.values.gone).toEqual({ verify: ['testverify-9'] })
})

test('REQ-MOD-011 REQ-MOD-018 after a hot reload the role stays on its next entry and nothing is said again', async ($, on) => {
  mock.env(on, { HOME })
  verifyFiles(on)
  // What the session state held when the module was loaded afresh.
  stateBeneath(on, {
    gone: { verify: ['testverify-9'] },
    said: ['key:fallback\nverify\ntestverify-9', 'text:engine map: role verify: testverify-9 unavailable, later dispatches use testverify-8'],
  })
  const seen = engineBeneath(on)

  const got = await $.agent.spawn({ prompt: 'check it', subagentType: 'verifier' })

  expect(got.model).toBe('testverify-8')
  expect(seen.toasts).toEqual([])
})

test('REQ-MOD-011 REQ-MOD-018 a session state that refuses to open leaves routing on and says so once', async ($, on) => {
  mock.env(on, { HOME })
  verifyFiles(on)
  on('state.get', () => ({ deny: 'session state refused for the test' }))
  const seen = engineBeneath(on)

  const a = await $.agent.spawn({ prompt: 'check it', subagentType: 'verifier' })
  const b = await $.agent.spawn({ prompt: 'build it', subagentType: 'implementer' })

  expect(a.model).toBe('testverify-9')
  expect(b.model).toBe('testbuild-9')
  expect(seen.toasts.length).toBe(1)
  expect(seen.toasts[0]).toContain('session state')
  expect(seen.toasts[0]).toContain('session state refused for the test')
  expect(seen.toasts[0]).not.toContain('hook failed')
  expect(seen.logs).toEqual(seen.toasts)
})
