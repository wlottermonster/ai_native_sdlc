// One `next` per dispatch and never a `deny`, as a property over every
// scenario REQ-MOD-021 names: first the pure route() with fakes (including
// dependencies that throw or answer nonsense), then the registered agent.spawn
// hook run by the engine through the test kit, its bottom hook counting calls.
import { test, expect, mock } from 'claude-code/testing'
import type { On } from 'claude-code'
import { route, type RouteDeps } from './routing.ts'
import { createNotices, type Notices } from './notices.ts'
import { createChain, type ChainState } from './chain.ts'

const HOME = '/fx/t'
const ROOT = '/work/repo'
const MAP = `${HOME}/.claude/sdlc-engines.conf`
const USER = `${HOME}/.claude/agents/roles.conf`

const GOOD_MAP = 'judge = testjudge-9\nbuild = testbuild-9, testbuild-8\nverify = testverify-9\nread = testread-9\n'
const BAD_MAP = 'judge = testjudge-9\nbuild = , testbuild-9\n'
const GOOD_USER = 'implementer = build\nresearcher = read\n'

type Files = Record<string, string>
const VALID: Files = { [MAP]: GOOD_MAP, [USER]: GOOD_USER }
const REFUSED: Files = { [MAP]: BAD_MAP, [USER]: GOOD_USER }

function fakeDeps(files: Files, over: Partial<RouteDeps> = {}): RouteDeps {
  return {
    home: HOME,
    root: ROOT,
    read: async (path: string) => {
      const text = files[path]
      if (text === undefined) throw new Error(`ENOENT: ${path}`)
      return text
    },
    exists: async (path: string) => files[path] !== undefined,
    ...over,
  }
}

type Spawn = { subagentType: string; model?: string; fork?: boolean; isTeammate?: boolean } & Record<string, unknown>
function spawn(subagentType: string, extra: Record<string, unknown> = {}): Spawn {
  return { subagentType, prompt: 'do the task', fork: false, ...extra }
}

const EVENTS: [string, Spawn][] = [
  ['a bound agent', spawn('implementer')],
  ['an explicit model', spawn('implementer', { model: 'testother-9' })],
  ['an explicit equal model', spawn('implementer', { model: 'testbuild-9' })],
  ['a fork', spawn('implementer', { fork: true })],
  ['a teammate', spawn('implementer', { isTeammate: true })],
  ['a plugin agent', spawn('someplugin:implementer')],
  ['an unbound name', spawn('general-purpose')],
]

const throwing = () => { throw new Error('boom') }

const DEPS: [string, () => { d: RouteDeps; n?: Notices; c?: ChainState }][] = [
  ['a valid map', () => ({ d: fakeDeps(VALID) })],
  ['a refused map', () => ({ d: fakeDeps(REFUSED) })],
  ['missing files', () => ({ d: fakeDeps({}) })],
  ['an unset HOME', () => ({ d: fakeDeps(VALID, { home: undefined }) })],
  ['a session root that failed', () => ({ d: fakeDeps(VALID, { root: undefined, rootError: 'boom' }) })],
  ['a read that throws', () => ({ d: fakeDeps(VALID, { read: async () => throwing() }) })],
  ['a read that throws synchronously', () => ({ d: fakeDeps(VALID, { read: throwing as never }) })],
  ['an exists that throws', () => ({ d: fakeDeps(VALID, { exists: async () => throwing() }) })],
  ['an exists that throws synchronously', () => ({ d: fakeDeps(VALID, { exists: throwing as never }) })],
  ['a read that answers no text', () => ({ d: fakeDeps(VALID, { read: async () => undefined as never }) })],
  ['a message set that throws', () => ({ d: fakeDeps(REFUSED), n: { once: throwing } })],
  ['a chain state that throws', () => ({ d: fakeDeps(VALID), c: { gone: throwing, markGone: throwing } })],
]

// ---- REQ-MOD-021, the pure module

for (const [what, make] of DEPS) {
  test(`REQ-MOD-021 route() never throws and never denies, with ${what}, for every kind of dispatch`, async () => {
    for (const [kind, e] of EVENTS) {
      const { d, n, c } = make()
      let r: unknown
      let threw: unknown
      try {
        r = await route(e, d, n ?? createNotices(), c ?? createChain())
      } catch (err) {
        threw = err
      }
      expect([kind, threw]).toEqual([kind, undefined])
      const out = r as { input: Spawn; deny?: unknown }
      expect([kind, 'deny' in out]).toEqual([kind, false])
      expect([kind, 'deny' in out.input]).toEqual([kind, false])
      expect(out.input.subagentType).toBe(e.subagentType)
      if (e.model !== undefined) expect(out.input.model).toBe(e.model)
    }
  })
}

test('REQ-MOD-021 a dependency that throws inside routing passes the dispatch through as given and says so once', async () => {
  const n = createNotices()
  const d = fakeDeps(VALID, { read: async () => undefined as never })
  const a = await route(spawn('implementer'), d, n, createChain())
  const b = await route(spawn('implementer'), d, n, createChain())
  expect(a.input).toEqual(spawn('implementer'))
  expect(b.input).toEqual(spawn('implementer'))
  expect(a.dispatched).toBe(undefined)
  expect(a.notice !== undefined && a.notice.includes('engine map')).toBe(true)
  expect(b.notice).toBe(undefined)
})

// ---- REQ-MOD-021, the registered hook through the engine

type Kit = { spawned: number; results: unknown[] }

function bottom(on: On): Kit {
  const kit: Kit = { spawned: 0, results: [] }
  on('agent.spawn', ($, e) => {
    kit.spawned++
    return { model: e.model ?? 'frontmatter', agentId: `agent-${kit.spawned}` }
  })
  on('ui.toast', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  return kit
}

function answerFiles(on: On, files: Files, throwIn?: 'fs.exists' | 'session.root') {
  on('fs.read', ($, e) => {
    const text = files[e.path]
    return text === undefined ? { deny: `ENOENT: ${e.path}` } : { value: text }
  })
  if (throwIn === 'fs.exists') on('fs.exists', () => throwing())
  else on('fs.exists', ($, e) => ({ value: files[e.path] !== undefined }))
  if (throwIn === 'session.root') on('session.root', () => throwing())
  else on('session.root', () => ({ value: ROOT }))
}

const KIT: [string, (on: On) => void][] = [
  ['a valid map', on => answerFiles(on, VALID)],
  ['a refused map', on => answerFiles(on, REFUSED)],
  ['missing files', on => answerFiles(on, {})],
  ['no file system at all', () => {}],
  ['a read that throws', on => {
    on('fs.read', () => throwing())
    on('fs.exists', () => ({ value: false }))
    on('session.root', () => ({ value: ROOT }))
  }],
  ['an exists that throws', on => answerFiles(on, VALID, 'fs.exists')],
  ['a session root that throws', on => answerFiles(on, VALID, 'session.root')],
]

for (const [what, setup] of KIT) {
  test(`REQ-MOD-021 the agent.spawn hook calls next exactly once and never denies, with ${what}`, async ($, on) => {
    mock.env(on, { HOME })
    setup(on)
    const kit = bottom(on)
    let n = 0
    for (const [kind, e] of EVENTS) {
      n++
      const got = await $.agent.spawn(e as never)
      expect([kind, kit.spawned]).toEqual([kind, n])
      expect([kind, 'deny' in (got as object)]).toEqual([kind, false])
      expect([kind, typeof (got as { agentId?: unknown }).agentId]).toEqual([kind, 'string'])
    }
  })
}
