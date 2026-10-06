// The judge check and the status line, driven through the pure status module
// with fakes, then once each through the engine (session.start and turn.start
// raised by the test kit, the test's own hooks answering session.model,
// env.get and fs.read and recording ui.status).
import { test, expect, mock } from 'claude-code/testing'
import type { On } from 'claude-code'
import { matches, statusLine, computeStatus, subagentVariableNotice, variableNotice, type StatusDeps } from './status.ts'
import { createChain, type ChainState } from './chain.ts'
import { createNotices } from './notices.ts'
import { parseMap } from './map.ts'

const HOME = '/fx/t'
const MAP = `${HOME}/.claude/sdlc-engines.conf`
const GOOD_MAP = 'judge = testjudge-9, testjudge-8\nbuild = testbuild-9, testbuild-8\nverify = testverify-9\nread = testread-9, testread-8\nescalate = testescalate-9\n'

function roles(text: string) {
  const v = parseMap(text)
  if (!v.ok) throw new Error('fixture map refused')
  return v.roles
}

function deps(over: Partial<StatusDeps> = {}, files: Record<string, string> = { [MAP]: GOOD_MAP }): StatusDeps {
  return {
    home: HOME,
    model: async () => 'claude-testjudge-9-1',
    read: async (path: string) => {
      const text = files[path]
      if (text === undefined) throw new Error(`ENOENT: ${path}`)
      return text
    },
    chain: createChain(),
    ...over,
  }
}

// --- the three spellings -----------------------------------------------------

test('REQ-MOD-016 an id equal to the entry matches', () => {
  expect(matches('testjudge-9', 'testjudge-9')).toBe(true)
})

test('REQ-MOD-016 an id equal to claude- plus the entry matches', () => {
  expect(matches('claude-testjudge-9', 'testjudge-9')).toBe(true)
})

test('REQ-MOD-016 an id starting with claude- plus the entry plus - matches', () => {
  expect(matches('claude-testjudge-9-1', 'testjudge-9')).toBe(true)
})

test('REQ-MOD-016 an id of a different family does not match', () => {
  expect(matches('claude-testbuild-9-1', 'testjudge-9')).toBe(false)
})

test('REQ-MOD-016 an id that merely starts with the entry without the - does not match', () => {
  expect(matches('claude-testjudge-91', 'testjudge-9')).toBe(false)
  expect(matches('testjudge-9-1', 'testjudge-9')).toBe(false)
})

test('REQ-MOD-016 an entry longer than the id does not match', () => {
  expect(matches('claude-testjudge', 'testjudge-9')).toBe(false)
})

test('REQ-MOD-016 a bracketed suffix on the id is stripped before matching', () => {
  expect(matches('claude-testjudge-9-1[big]', 'testjudge-9')).toBe(true)
  expect(matches('testjudge-9[big]', 'testjudge-9')).toBe(true)
  expect(matches('claude-testbuild-9[big]', 'testjudge-9')).toBe(false)
})

test('REQ-MOD-016 the status line says judge: <entry> on a match', () => {
  const line = statusLine({ map: { ok: true, roles: roles(GOOD_MAP) }, judgeId: 'claude-testjudge-9-1', chain: createChain() })
  expect(line.startsWith('judge: testjudge-9 | ')).toBe(true)
  expect(line).not.toContain('MISMATCH')
})

test('REQ-MOD-016 the status line says JUDGE MISMATCH: <id> is not <entry> otherwise, suffix stripped', () => {
  const line = statusLine({ map: { ok: true, roles: roles(GOOD_MAP) }, judgeId: 'claude-testbuild-9-1[big]', chain: createChain() })
  expect(line.startsWith('JUDGE MISMATCH: claude-testbuild-9-1 is not testjudge-9 | ')).toBe(true)
})

test('REQ-MOD-016 the judge check compares with the first entry only, never a fallback', () => {
  const line = statusLine({ map: { ok: true, roles: roles(GOOD_MAP) }, judgeId: 'claude-testjudge-8-1', chain: createChain() })
  expect(line).toContain('JUDGE MISMATCH: claude-testjudge-8-1 is not testjudge-9')
})

test('REQ-MOD-016 computeStatus reads the model as the engine reports it and the judge from the HOME map', async () => {
  expect(await computeStatus(deps())).toBe('judge: testjudge-9 | judge=testjudge-9 build=testbuild-9 verify=testverify-9 read=testread-9')
  expect(await computeStatus(deps({ model: async () => 'claude-testread-9' }))).toBe(
    'JUDGE MISMATCH: claude-testread-9 is not testjudge-9 | judge=testjudge-9 build=testbuild-9 verify=testverify-9 read=testread-9',
  )
})

test('REQ-MOD-016 a model the engine cannot report is flagged, not taken as a match', async () => {
  const line = await computeStatus(deps({ model: async () => { throw new Error('no model') } }))
  expect(line.startsWith('JUDGE UNKNOWN: ')).toBe(true)
  expect(line).toContain('judge=testjudge-9')
})

test('REQ-MOD-016 a map with no judge line is flagged as a mismatch', async () => {
  const line = await computeStatus(deps({}, { [MAP]: 'build = testbuild-9\n' }))
  expect(line).toBe('JUDGE MISMATCH: claude-testjudge-9-1 is not none | judge=none build=testbuild-9 verify=none read=none')
})

// --- one line, the map, the entries in force ---------------------------------

test('REQ-MOD-017 the roles are printed in the fixed order judge build verify read, escalate left out', () => {
  const reordered = 'escalate = testescalate-9\nread = testread-9\nverify = testverify-9\nbuild = testbuild-9\njudge = testjudge-9\n'
  const line = statusLine({ map: { ok: true, roles: roles(reordered) }, judgeId: 'testjudge-9', chain: createChain() })
  expect(line).toBe('judge: testjudge-9 | judge=testjudge-9 build=testbuild-9 verify=testverify-9 read=testread-9')
  expect(line).not.toContain('escalate')
  expect(line).not.toContain('\n')
})

test('REQ-MOD-017 a role moved to its second entry shows the entry in force', () => {
  const chain: ChainState = createChain()
  chain.markGone('build', 'testbuild-9')
  const line = statusLine({ map: { ok: true, roles: roles(GOOD_MAP) }, judgeId: 'testjudge-9', chain })
  expect(line).toContain('build=testbuild-9 → testbuild-8 ')
})

test('REQ-MOD-017 an exhausted role shows frontmatter in force', () => {
  const chain: ChainState = createChain()
  chain.markGone('verify', 'testverify-9')
  const line = statusLine({ map: { ok: true, roles: roles(GOOD_MAP) }, judgeId: 'testjudge-9', chain })
  expect(line).toContain('verify=testverify-9 → frontmatter ')
})

test('REQ-MOD-017 roles not moved show no arrow', () => {
  const chain: ChainState = createChain()
  chain.markGone('build', 'testbuild-9')
  const line = statusLine({ map: { ok: true, roles: roles(GOOD_MAP) }, judgeId: 'testjudge-9', chain })
  expect(line.split('→').length).toBe(2)
  expect(line.endsWith('read=testread-9')).toBe(true)
  const still = statusLine({ map: { ok: true, roles: roles(GOOD_MAP) }, judgeId: 'testjudge-9', chain: createChain() })
  expect(still).not.toContain('→')
})

test('REQ-MOD-017 the mismatch flag and a moved role are carried on the same one line', () => {
  const chain: ChainState = createChain()
  chain.markGone('read', 'testread-9')
  const line = statusLine({ map: { ok: true, roles: roles(GOOD_MAP) }, judgeId: 'claude-testbuild-9', chain })
  expect(line).toBe('JUDGE MISMATCH: claude-testbuild-9 is not testjudge-9 | judge=testjudge-9 build=testbuild-9 verify=testverify-9 read=testread-9 → testread-8')
})

test('REQ-MOD-017 a role whose dead entry the owner removed from the map shows no arrow', () => {
  const chain: ChainState = createChain()
  chain.markGone('build', 'testbuild-9')
  const edited = GOOD_MAP.replace('build = testbuild-9, testbuild-8', 'build = testbuild-8')
  const line = statusLine({ map: { ok: true, roles: roles(edited) }, judgeId: 'testjudge-9', chain })
  expect(line).toContain('build=testbuild-8 verify')
  expect(line).not.toContain('→')
})

test('REQ-MOD-017 a role missing from the map is shown as none', () => {
  const line = statusLine({ map: { ok: true, roles: roles('judge = testjudge-9\nread = testread-9\n') }, judgeId: 'testjudge-9', chain: createChain() })
  expect(line).toBe('judge: testjudge-9 | judge=testjudge-9 build=none verify=none read=testread-9')
})

test('REQ-MOD-017 a refused map gives the refused-line text', async () => {
  const line = await computeStatus(deps({}, { [MAP]: 'judge = testjudge-9\nbuild = , testbuild-9\n' }))
  expect(line).toBe(`engine map: ${MAP} refused line 2`)
})

test('REQ-MOD-017 a missing map says so', async () => {
  expect(await computeStatus(deps({}, {}))).toBe(`engine map: ${MAP} missing or unreadable`)
  expect(await computeStatus(deps({ home: undefined }))).toBe('engine map: ~/.claude/sdlc-engines.conf missing or unreadable')
})

test('REQ-MOD-017 the map is read fresh at every computation', async () => {
  const files: Record<string, string> = { [MAP]: GOOD_MAP }
  const d = deps({}, files)
  expect(await computeStatus(d)).toContain('build=testbuild-9 ')
  files[MAP] = GOOD_MAP.replace('build = testbuild-9', 'build = testbuild-7')
  expect(await computeStatus(d)).toContain('build=testbuild-7 ')
})

// --- the subagent-model variable ---------------------------------------------

test('REQ-MOD-020 the notice names the variable, says the map still decides and that the variable governs only the dispatches the mod leaves alone', () => {
  const text = subagentVariableNotice('testother-9')
  expect(text).toContain('CLAUDE_CODE_SUBAGENT_MODEL')
  expect(text).toContain('is set')
  expect(text).toContain('map still decides')
  expect(text).toContain('a hook-set model outranks the variable')
  expect(text).toContain('dispatches the mod leaves alone')
})

test('REQ-MOD-020 the variable set gives exactly one notice over two session starts', () => {
  const n = createNotices()
  const first = variableNotice('testother-9', n)
  const second = variableNotice('testother-9', n)
  expect(first).toBe(subagentVariableNotice('testother-9'))
  expect(second).toBeUndefined()
})

test('REQ-MOD-020 the variable unset or empty gives nothing', () => {
  const n = createNotices()
  expect(variableNotice(undefined, n)).toBeUndefined()
  expect(variableNotice('', n)).toBeUndefined()
})

// --- through the engine ------------------------------------------------------

type Seen = { status: (string | undefined)[]; toasts: string[]; logs: string[] }

function engineBeneath(on: On, model: string, files: Record<string, string>): Seen {
  const seen: Seen = { status: [], toasts: [], logs: [] }
  on('session.model', () => ({ value: model }))
  on('fs.read', ($, e) => {
    const text = files[e.path]
    return text === undefined ? { deny: `ENOENT: ${e.path}` } : { value: text }
  })
  on('ui.status', ($, e) => { seen.status.push(e.text); return { value: undefined } })
  on('ui.toast', ($, e) => { seen.toasts.push(e.text); return { value: undefined } })
  on('ui.log', ($, e) => { seen.logs.push(e.text); return { value: undefined } })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  return seen
}

// Each kit test loads a fresh plugin instance over its own session state, so
// no fallback chain carries into these tests from another one.
const KIT_MAP = 'judge = testjudge-9\nbuild = testbuild-9\nverify = testverify-9\nread = testread-9\n'
const KIT_LINE = 'judge=testjudge-9 build=testbuild-9 verify=testverify-9 read=testread-9'

test('REQ-MOD-016 REQ-MOD-020 session.start through the engine sets the status line and says the variable once', async ($, on) => {
  mock.env(on, { HOME, CLAUDE_CODE_SUBAGENT_MODEL: 'testother-9' })
  const seen = engineBeneath(on, 'claude-testjudge-9-1', { [MAP]: KIT_MAP })

  const r1 = await $.session.start({ cwd: '/work/repo', surface: null, isInteractive: false })
  const r2 = await $.session.start({ cwd: '/work/repo', surface: null, isInteractive: false })

  expect(r1.cwd).toBe('/work/repo')
  expect(r2.cwd).toBe('/work/repo')
  expect(seen.status).toEqual([`judge: testjudge-9 | ${KIT_LINE}`, `judge: testjudge-9 | ${KIT_LINE}`])
  expect(seen.toasts.length).toBe(1)
  expect(seen.toasts[0]).toContain('CLAUDE_CODE_SUBAGENT_MODEL')
  expect(seen.logs).toEqual(seen.toasts)
})

test('REQ-MOD-016 REQ-MOD-017 turn.start through the engine flags a mismatch on the status line and says nothing else', async ($, on) => {
  mock.env(on, { HOME })
  const seen = engineBeneath(on, 'claude-testbuild-9-1', { [MAP]: KIT_MAP })

  const r = await $.turn.start({ text: 'hello', turnId: 't1' })

  expect(r.turnId).toBe('t1')
  expect(seen.status).toEqual([`JUDGE MISMATCH: claude-testbuild-9-1 is not testjudge-9 | ${KIT_LINE}`])
  expect(seen.toasts).toEqual([])
})

test('REQ-MOD-020 session.start through the engine with the variable unset says nothing', async ($, on) => {
  mock.env(on, { HOME })
  const seen = engineBeneath(on, 'claude-testjudge-9-1', { [MAP]: KIT_MAP })

  await $.session.start({ cwd: '/work/repo', surface: null, isInteractive: false })

  expect(seen.status.length).toBe(1)
  expect(seen.toasts).toEqual([])
})
