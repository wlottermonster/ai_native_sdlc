// agent.spawn routing, driven through the pure module with fakes for the
// files, HOME, the session root and the message set. The engine's own `$`
// is adapted to these in register.ts and exercised in register.test.ts.
import { test, expect } from 'claude-code/testing'
import { route, type RouteDeps } from './routing.ts'
import { createNotices, type Notices } from './notices.ts'
import { CASES } from './map.fixtures.ts'

const HOME = '/fx/t'
const ROOT = '/work/repo'
const MAP = `${HOME}/.claude/sdlc-engines.conf`
const USER = `${HOME}/.claude/agents/roles.conf`
const PROJECT = `${ROOT}/.claude/agents/roles.conf`

const GOOD_MAP = 'judge = testjudge-9\nbuild = testbuild-9, testbuild-8\nverify = testverify-9\nread = testread-9, testread-8\n'
const GOOD_USER = 'implementer = build\nresearcher = read\nverifier = verify\n'

function deps(files: Record<string, string>, over: Partial<RouteDeps> = {}): RouteDeps {
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

// A plain subagent as the engine hands it: isTeammate absent, fork false.
function spawn(subagentType: string, extra: Record<string, unknown> = {}) {
  return {
    tool_use_id: 'toolu_1',
    prompt: 'do the task',
    description: 'a task',
    subagentType,
    provider: { plugin: 'engine', tier: 'core' },
    parentModel: 'testjudge-9',
    background: false,
    fork: false,
    ...extra,
  } as { subagentType: string; model?: string; fork?: boolean; isTeammate?: boolean } & Record<string, unknown>
}

// Two dispatches in one process: the notices each one produced.
async function twice(e: ReturnType<typeof spawn>, d: RouteDeps, n: Notices = createNotices()) {
  const a = await route(e, d, n)
  const b = await route(e, d, n)
  return { a, b, said: [a.notice, b.notice].filter(x => x !== undefined) as string[] }
}

// ---- REQ-MOD-007

test('REQ-MOD-007 a bound agent dispatched with no model gets the first entry of its role', async () => {
  const e = spawn('implementer')
  const r = await route(e, deps({ [MAP]: GOOD_MAP, [USER]: GOOD_USER }), createNotices())
  expect(r.input.model).toBe('testbuild-9')
  expect(r.notice).toBe(undefined)
  const { model: _m, ...rest } = r.input
  expect(rest).toEqual(e)
})

test('REQ-MOD-007 the entry comes from the map read at this dispatch', async () => {
  const files = { [MAP]: GOOD_MAP, [USER]: GOOD_USER }
  const n = createNotices()
  expect((await route(spawn('researcher'), deps(files), n)).input.model).toBe('testread-9')
  files[MAP] = GOOD_MAP.replace('read = testread-9, testread-8', 'read = testread-7')
  expect((await route(spawn('researcher'), deps(files), n)).input.model).toBe('testread-7')
})

// ---- REQ-MOD-008

test('REQ-MOD-008 an explicit model that differs is left alone and said once over two dispatches', async () => {
  const e = spawn('implementer', { model: 'testother-9' })
  const { a, b, said } = await twice(e, deps({ [MAP]: GOOD_MAP, [USER]: GOOD_USER }))
  expect(a.input).toEqual(e)
  expect(b.input).toEqual(e)
  expect(said.length).toBe(1)
  expect(said[0]).toContain('implementer')
  expect(said[0]).toContain('build')
  expect(said[0]).toContain('testbuild-9')
  expect(said[0]).toContain('testother-9')
})

test('REQ-MOD-008 an explicit model equal to the entry in force is not a bypass', async () => {
  const e = spawn('implementer', { model: 'testbuild-9' })
  const { a, b, said } = await twice(e, deps({ [MAP]: GOOD_MAP, [USER]: GOOD_USER }))
  expect(a.input).toEqual(e)
  expect(b.input).toEqual(e)
  expect(said).toEqual([])
})

test('REQ-MOD-008 the bypass is said once for each agent', async () => {
  const n = createNotices()
  const d = deps({ [MAP]: GOOD_MAP, [USER]: GOOD_USER })
  const one = await twice(spawn('implementer', { model: 'testother-9' }), d, n)
  const two = await twice(spawn('researcher', { model: 'testother-9' }), d, n)
  expect(one.said.length).toBe(1)
  expect(two.said.length).toBe(1)
  expect(two.said[0]).toContain('researcher')
})

// ---- REQ-MOD-009

const SILENT: [string, ReturnType<typeof spawn>][] = [
  ['a fork', spawn('implementer', { fork: true })],
  ['a teammate', spawn('implementer', { isTeammate: true })],
  ['a plugin agent', spawn('someplugin:implementer')],
  ['an unbound name', spawn('general-purpose')],
]

for (const [what, e] of SILENT) {
  test(`REQ-MOD-009 ${what} passes through unchanged and nothing is said`, async () => {
    const { a, b, said } = await twice(e, deps({ [MAP]: GOOD_MAP, [USER]: GOOD_USER }))
    expect(a.input).toEqual(e)
    expect(b.input).toEqual(e)
    expect(a.input.model).toBe(undefined)
    expect(said).toEqual([])
  })
}

test('REQ-MOD-009 a plugin agent whose bare name a manifest binds is still untouched', async () => {
  const e = spawn('someplugin:implementer')
  const files = { [MAP]: GOOD_MAP, [USER]: GOOD_USER + 'someplugin:implementer = build\n' }
  const { a, said } = await twice(e, deps(files))
  expect(a.input).toEqual(e)
  expect(said).toEqual([])
})

test('REQ-MOD-009 a fork or a teammate with an explicit differing model is not a bypass notice', async () => {
  for (const e of [
    spawn('implementer', { fork: true, model: 'testother-9' }),
    spawn('implementer', { isTeammate: true, model: 'testother-9' }),
  ]) {
    const { a, said } = await twice(e, deps({ [MAP]: GOOD_MAP, [USER]: GOOD_USER }))
    expect(a.input).toEqual(e)
    expect(said).toEqual([])
  }
})

// ---- REQ-MOD-010

async function refusedCase(files: Record<string, string>, over: Partial<RouteDeps> = {}) {
  const n = createNotices()
  const d = deps(files, over)
  const said: string[] = []
  const inputs: unknown[] = []
  const given: unknown[] = []
  for (const name of ['implementer', 'researcher', 'verifier', 'implementer']) {
    const e = spawn(name)
    given.push(e)
    const r = await route(e, d, n)
    inputs.push(r.input)
    if (r.notice !== undefined) said.push(r.notice)
  }
  return { said, inputs, given }
}

test('REQ-MOD-010 a missing map passes every dispatch through and is said once, naming the file', async () => {
  const { said, inputs, given } = await refusedCase({ [USER]: GOOD_USER })
  expect(inputs).toEqual(given)
  expect(said.length).toBe(1)
  expect(said[0]).toContain(MAP)
})

test('REQ-MOD-010 a missing user manifest passes every dispatch through and is said once, naming it', async () => {
  const { said, inputs, given } = await refusedCase({ [MAP]: GOOD_MAP })
  expect(inputs).toEqual(given)
  expect(said.length).toBe(1)
  expect(said[0]).toContain(USER)
})

test('REQ-MOD-010 an unset HOME passes every dispatch through and is said once', async () => {
  const { said, inputs, given } = await refusedCase({ [MAP]: GOOD_MAP, [USER]: GOOD_USER }, { home: undefined })
  expect(inputs).toEqual(given)
  expect(said.length).toBe(1)
  expect(said[0]).toContain('HOME')
})

test('REQ-MOD-010 a refused map routes nothing, not even agents on its valid lines, and names the line', async () => {
  const c = CASES.find(x => x.name === 'whole-file-refused')
  if (c === undefined) throw new Error('fixture case missing: whole-file-refused')
  // The map's build line is valid and implementer is bound to it; line 3 is not.
  const { said, inputs, given } = await refusedCase({ [MAP]: c.map, [USER]: GOOD_USER })
  expect(inputs).toEqual(given)
  for (const i of inputs) expect((i as { model?: string }).model).toBe(undefined)
  expect(said.length).toBe(1)
  expect(said[0]).toContain(MAP)
  expect(said[0]).toContain('line 3')
  expect(said[0]).toContain('empty model name in the list')
})

test('REQ-MOD-010 a refused user manifest routes nothing and names the file and line', async () => {
  const c = CASES.find(x => x.name === 'undefined-role')
  if (c === undefined) throw new Error('fixture case missing: undefined-role')
  // implementer = build on line 1 is valid; line 3 binds a role the map lacks.
  const { said, inputs, given } = await refusedCase({ [MAP]: c.map, [USER]: c.roles })
  expect(inputs).toEqual(given)
  expect(said.length).toBe(1)
  expect(said[0]).toContain(USER)
  expect(said[0]).toContain('line 3')
})

test('REQ-MOD-010 a refused project manifest routes nothing, even agents the user manifest binds', async () => {
  const { said, inputs, given } = await refusedCase({
    [MAP]: GOOD_MAP,
    [USER]: GOOD_USER,
    [PROJECT]: 'verifier = design\n',
  })
  expect(inputs).toEqual(given)
  expect(said.length).toBe(1)
  expect(said[0]).toContain(PROJECT)
  expect(said[0]).toContain('line 1')
})

test('REQ-MOD-010 a project manifest whose existence cannot be checked routes nothing', async () => {
  const { said, inputs, given } = await refusedCase(
    { [MAP]: GOOD_MAP, [USER]: GOOD_USER },
    { exists: async () => { throw new Error('no implementation') } },
  )
  expect(inputs).toEqual(given)
  expect(said.length).toBe(1)
  expect(said[0]).toContain(PROJECT)
})

test('REQ-MOD-010 a refusal is said even for an agent that would be unbound', async () => {
  const n = createNotices()
  const e = spawn('general-purpose')
  const r = await route(e, deps({ [USER]: GOOD_USER }), n)
  expect(r.input).toEqual(e)
  expect(r.notice).toContain(MAP)
})

// ---- REQ-MOD-019

test('REQ-MOD-019 the project manifest binds the agent first and wins over the user manifest', async () => {
  const files = {
    [MAP]: GOOD_MAP,
    [USER]: GOOD_USER,
    [PROJECT]: 'implementer = read\n',
  }
  const r = await route(spawn('implementer'), deps(files), createNotices())
  expect(r.input.model).toBe('testread-9')
})

test('REQ-MOD-019 with no project manifest the user manifest binds', async () => {
  const r = await route(spawn('implementer'), deps({ [MAP]: GOOD_MAP, [USER]: GOOD_USER }), createNotices())
  expect(r.input.model).toBe('testbuild-9')
})

test('REQ-MOD-019 a project manifest that does not bind this agent leaves the user manifest in force', async () => {
  const files = {
    [MAP]: GOOD_MAP,
    [USER]: GOOD_USER,
    [PROJECT]: 'repo-agent = verify\n',
  }
  const d = deps(files)
  expect((await route(spawn('implementer'), d, createNotices())).input.model).toBe('testbuild-9')
  expect((await route(spawn('repo-agent'), d, createNotices())).input.model).toBe('testverify-9')
})

test('REQ-MOD-019 the map is read only from HOME, never from the session root', async () => {
  const files = {
    [MAP]: GOOD_MAP,
    [USER]: GOOD_USER,
    [`${ROOT}/.claude/sdlc-engines.conf`]: 'build = testbuild-1\n',
  }
  const reads: string[] = []
  const d = deps(files)
  const inner = d.read
  d.read = async (p: string) => { reads.push(p); return inner(p) }
  const r = await route(spawn('implementer'), d, createNotices())
  expect(r.input.model).toBe('testbuild-9')
  expect(reads).not.toContain(`${ROOT}/.claude/sdlc-engines.conf`)
})

test('REQ-MOD-019 a session root that cannot be read routes nothing, since the project manifest cannot be consulted', async () => {
  const n = createNotices()
  const d = deps({ [MAP]: GOOD_MAP, [USER]: GOOD_USER }, { root: undefined, rootError: 'no implementation' })
  const e = spawn('implementer')
  const a = await route(e, d, n)
  const b = await route(e, d, n)
  expect(a.input).toEqual(e)
  expect(b.input).toEqual(e)
  expect(a.notice).toContain('.claude/agents/roles.conf')
  expect(a.notice).toContain('no implementation')
  expect(b.notice).toBe(undefined)
})

test('REQ-MOD-019 with no session root the user manifest alone binds', async () => {
  const r = await route(spawn('implementer'), deps({ [MAP]: GOOD_MAP, [USER]: GOOD_USER }, { root: undefined }), createNotices())
  expect(r.input.model).toBe('testbuild-9')
})
