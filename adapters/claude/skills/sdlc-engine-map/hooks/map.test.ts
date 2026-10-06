// The engine-map parser against the shared fixture set, and the reader's
// promise to hold no copy between calls.
//
// The plugin test kit gives a hook's file system no implementation, so the
// fixture set arrives through map.fixtures.ts, the mirror that
// tests/test_apply_engines.sh holds byte-equal to tests/fixtures/engine-map/.
import { test, expect } from 'claude-code/testing'
import { parseMap, parseManifest, firstEntry, loadBinding } from './map.ts'
import { CASES, REQUIRED } from './map.fixtures.ts'

// The verdict in the `.expected` file's own shape: `accept` and the sorted
// agent-to-first-entry table, or one `refuse <file> <line>` per fault in the
// order apply-engines.sh reports them (the map's, then the manifest's).
function verdictOf(mapText: string, rolesText: string): string {
  const map = parseMap(mapText)
  const manifest = parseManifest(rolesText, map.roles)
  const faults = [
    ...map.errors.map(f => `refuse map ${f.line}\n`),
    ...manifest.errors.map(f => `refuse roles ${f.line}\n`),
  ]
  if (faults.length > 0) return faults.join('')
  const agents = [...manifest.agents.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
  return 'accept\n' + agents.map(a => `${a}\t${firstEntry(a, manifest, map)}\n`).join('')
}

function caseNamed(name: string) {
  const c = CASES.find(x => x.name === name)
  if (c === undefined) throw new Error(`fixture case missing: ${name}`)
  return c
}

// The required names are the list tests/engine_map_cases.sh holds, carried
// into the generated mirror, so this file keeps no second copy of them.
test('REQ-MOD-015 the fixture set is present and holds every grammar case', async () => {
  const names = CASES.map(c => c.name)
  expect(REQUIRED.length > 0).toBe(true)
  for (const n of REQUIRED) expect(names).toContain(n)
  expect(CASES.length).toBe(REQUIRED.length)
})

test('REQ-MOD-015 every fixture case reaches the verdict apply-engines.sh reached', async () => {
  for (const c of CASES) {
    expect(`${c.name}: ${verdictOf(c.map, c.roles)}`).toBe(`${c.name}: ${c.expected}`)
  }
})

test('REQ-MOD-015 comments, blank lines and whitespace around = and after commas', async () => {
  const map = parseMap(caseNamed('whitespace').map)
  expect(map.ok).toBe(true)
  expect(map.roles.get('verify')).toEqual(['testverify-9', 'testverify-8'])
  expect(map.roles.get('read')).toEqual(['testread-9', 'testread-8'])
})

test('REQ-MOD-015 a trailing carriage return is stripped', async () => {
  const map = parseMap(caseNamed('crlf').map)
  expect(map.ok).toBe(true)
  expect(map.roles.get('read')).toEqual(['testread-9'])
  expect(map.roles.get('build')).toEqual(['testbuild-9', 'testbuild-8'])
})

test('REQ-MOD-015 duplicate map key: first wins', async () => {
  const c = caseNamed('dup-map-first-wins')
  const map = parseMap(c.map)
  const manifest = parseManifest(c.roles, map.roles)
  expect(firstEntry('implementer', manifest, map)).toBe('testbuild-9')
})

test('REQ-MOD-015 duplicate manifest key: last wins', async () => {
  const c = caseNamed('dup-manifest-last-wins')
  const map = parseMap(c.map)
  const manifest = parseManifest(c.roles, map.roles)
  expect(manifest.agents.get('implementer')).toBe('build')
  expect(firstEntry('implementer', manifest, map)).toBe('testbuild-9')
})

test('REQ-MOD-015 an empty list element is refused with its line', async () => {
  const map = parseMap(caseNamed('empty-element-map').map)
  expect(map.ok).toBe(false)
  if (!map.ok) expect(map.line).toBe(2)
  const trailing = parseMap(caseNamed('empty-element-trailing').map)
  expect(trailing.ok).toBe(false)
  if (!trailing.ok) expect(trailing.line).toBe(2)
})

test('REQ-MOD-015 a manifest role the map does not define is refused', async () => {
  const c = caseNamed('undefined-role')
  const manifest = parseManifest(c.roles, parseMap(c.map).roles)
  expect(manifest.ok).toBe(false)
  if (!manifest.ok) expect(manifest.line).toBe(3)
})

test('REQ-MOD-015 a manifest role containing a comma is refused', async () => {
  const c = caseNamed('comma-role')
  const manifest = parseManifest(c.roles, parseMap(c.map).roles)
  expect(manifest.ok).toBe(false)
  if (!manifest.ok) expect(manifest.line).toBe(1)
})

test('REQ-MOD-015 one bad line refuses the whole file', async () => {
  const map = parseMap(caseNamed('whole-file-refused').map)
  expect(map.ok).toBe(false)
  if (!map.ok) expect(map.line).toBe(3)
  expect(firstEntry('implementer', parseManifest('implementer = build\n', map.roles), map)).toBe(undefined)
})

// A counting stand-in for the engine's `$`: only `fs.read`, answering from a
// table the test edits between calls.
function countingFs(files: Record<string, string>) {
  const reads: string[] = []
  const fake = {
    fs: {
      read: async (path: string) => {
        reads.push(path)
        const text = files[path]
        if (text === undefined) throw new Error(`ENOENT: ${path}`)
        return text
      },
    },
  }
  return { fake, reads }
}

const PATHS = { map: '/fx/t/.claude/sdlc-engines.conf', manifests: ['/fx/t/.claude/agents/roles.conf'] }

test('REQ-MOD-014 every load reads the map and the manifests from disk again', async () => {
  const files: Record<string, string> = {
    [PATHS.map]: 'build = testbuild-9\nread = testread-9\n',
    [PATHS.manifests[0]]: 'implementer = build\n',
  }
  const { fake, reads } = countingFs(files)

  const first = await loadBinding(fake, PATHS)
  expect(reads).toEqual([PATHS.map, PATHS.manifests[0]])
  expect(first.ok).toBe(true)
  if (first.ok) expect(firstEntry('implementer', first.manifests[0], first.map)).toBe('testbuild-9')

  files[PATHS.map] = 'build = testbuild-7\nread = testread-9\n'
  const second = await loadBinding(fake, PATHS)
  expect(reads).toEqual([PATHS.map, PATHS.manifests[0], PATHS.map, PATHS.manifests[0]])
  expect(second.ok).toBe(true)
  if (second.ok) expect(firstEntry('implementer', second.manifests[0], second.map)).toBe('testbuild-7')
})

test('REQ-MOD-014 a map that turns bad between loads is refused at the next load', async () => {
  const files: Record<string, string> = {
    [PATHS.map]: 'build = testbuild-9\n',
    [PATHS.manifests[0]]: 'implementer = build\n',
  }
  const { fake } = countingFs(files)
  expect((await loadBinding(fake, PATHS)).ok).toBe(true)
  files[PATHS.map] = 'build = testbuild-9,\n'
  const later = await loadBinding(fake, PATHS)
  expect(later.ok).toBe(false)
  if (!later.ok) {
    expect(later.file).toBe(PATHS.map)
    expect(later.line).toBe(1)
  }
})

test('REQ-MOD-014 a file that cannot be read is a refusal naming it, with no line', async () => {
  const { fake } = countingFs({ [PATHS.map]: 'build = testbuild-9\n' })
  const got = await loadBinding(fake, PATHS)
  expect(got.ok).toBe(false)
  if (!got.ok) {
    expect(got.file).toBe(PATHS.manifests[0])
    expect(got.line).toBe(undefined)
  }
})
