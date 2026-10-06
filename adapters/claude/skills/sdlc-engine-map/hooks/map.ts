// The engine map and the role manifests, parsed as scripts/apply-engines.sh
// parses them. That script is the grammar's oracle: tests/fixtures/engine-map/
// holds cases whose verdicts it produced, and this parser is held to the same
// verdicts (REQ-MOD-015). Where the script is lenient or strict, so is this.
//
//   - one `key = value[, value...]` per line; a line is split on newlines, one
//     trailing carriage return stripped, then spaces and tabs trimmed
//   - blank lines and lines whose first non-blank character is `#` are skipped;
//     a `#` later in a line is part of the value
//   - the key is everything before the FIRST `=`, the value everything after
//   - no `=`, an empty key, an empty value, or an empty element in the list is
//     a fault on that line
//   - the map: a repeated role keeps its FIRST definition
//   - a manifest: a repeated agent keeps its LAST binding, and every binding is
//     checked: a role holding a comma, or one the map does not define (among
//     the map's valid lines), is a fault on that line
//   - any fault refuses the whole file: a refused file routes nothing
//
// The parsers do no file I/O. loadBinding reads the files through `$.fs` on
// every call and keeps nothing between calls (REQ-MOD-014).

export type Fault = { line: number; message: string }

type Parsed = { line: number; key: string; values: string[] }

export type MapVerdict =
  | { ok: true; roles: Map<string, string[]>; errors: Fault[] }
  | { ok: false; line: number; message: string; roles: Map<string, string[]>; errors: Fault[] }

export type ManifestVerdict =
  | { ok: true; agents: Map<string, string>; errors: Fault[] }
  | { ok: false; line: number; message: string; agents: Map<string, string>; errors: Fault[] }

const LEAD = /^[ \t]+/
const TRAIL = /[ \t]+$/

function trim(s: string): string {
  return s.replace(LEAD, '').replace(TRAIL, '')
}

// The shared line grammar of both files: the records of the valid lines and a
// fault for every malformed one, each in file order.
function parseLines(text: string): { records: Parsed[]; errors: Fault[] } {
  const lines = text.split('\n')
  // A final newline ends the last line; it does not start an empty one.
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  const records: Parsed[] = []
  const errors: Fault[] = []
  lines.forEach((raw, i) => {
    const line = i + 1
    const t = trim(raw.endsWith('\r') ? raw.slice(0, -1) : raw)
    if (t === '' || t.startsWith('#')) return
    const eq = t.indexOf('=')
    if (eq < 0) {
      errors.push({ line, message: 'malformed line (no "=")' })
      return
    }
    const key = trim(t.slice(0, eq))
    const value = trim(t.slice(eq + 1))
    if (key === '') {
      errors.push({ line, message: 'malformed line (empty key)' })
      return
    }
    if (value === '') {
      errors.push({ line, message: 'malformed line (empty value)' })
      return
    }
    const values = value.split(',').map(trim)
    if (values.some(v => v === '')) {
      errors.push({ line, message: 'empty model name in the list' })
      return
    }
    records.push({ line, key, values })
  })
  return { records, errors }
}

function verdict<T extends object>(body: T, errors: Fault[]) {
  if (errors.length === 0) return { ok: true as const, ...body, errors }
  return { ok: false as const, line: errors[0].line, message: errors[0].message, ...body, errors }
}

// parseMap — role to its ordered list. `roles` holds the valid lines even when
// the file is refused, because a manifest is checked against them (a role
// whose map line is refused is undefined to the manifest, as in the script).
export function parseMap(text: string): MapVerdict {
  const { records, errors } = parseLines(text)
  const roles = new Map<string, string[]>()
  for (const r of records) if (!roles.has(r.key)) roles.set(r.key, r.values)
  return verdict({ roles }, errors)
}

// parseManifest — agent to role. The faults are the line grammar's first, then
// the binding checks, the order in which the script reports them.
export function parseManifest(text: string, mapRoles: ReadonlyMap<string, readonly string[]>): ManifestVerdict {
  const { records, errors } = parseLines(text)
  const agents = new Map<string, string>()
  const bindingErrors: Fault[] = []
  for (const r of records) {
    const role = r.values.join(',')
    if (r.values.length > 1) {
      bindingErrors.push({ line: r.line, message: 'malformed line (an agent runs under exactly one role)' })
      continue
    }
    if (!mapRoles.has(role)) {
      bindingErrors.push({ line: r.line, message: `role "${role}" is not defined in the map` })
    }
    agents.set(r.key, role)
  }
  return verdict({ agents }, [...errors, ...bindingErrors])
}

// firstEntry — the model an agent runs on: the head of its role's list.
// Undefined when either file is refused or the agent is not bound.
export function firstEntry(agent: string, manifest: ManifestVerdict, map: MapVerdict): string | undefined {
  if (!manifest.ok || !map.ok) return undefined
  const role = manifest.agents.get(agent)
  if (role === undefined) return undefined
  return map.roles.get(role)?.[0]
}

// The part of the engine's `$` the reader uses.
export type FsReader = { fs: { read: (path: string) => Promise<string> } }

export type BindingPaths = { map: string; manifests: readonly string[] }

export type Binding =
  | { ok: true; map: MapVerdict; manifests: ManifestVerdict[] }
  | { ok: false; file: string; line?: number; message: string }

// loadBinding — read the map and every manifest named, now. Nothing is cached
// here or anywhere in this module: each call is a fresh read, so an edit to
// the map applies at the next call. The first file that cannot be read, or is
// refused, is the answer, named with its line when it has one.
export async function loadBinding($: FsReader, paths: BindingPaths): Promise<Binding> {
  let mapText: string
  try {
    mapText = await $.fs.read(paths.map)
  } catch (err) {
    return { ok: false, file: paths.map, message: `cannot read it: ${String(err)}` }
  }
  const texts: string[] = []
  for (const path of paths.manifests) {
    try {
      texts.push(await $.fs.read(path))
    } catch (err) {
      return { ok: false, file: path, message: `cannot read it: ${String(err)}` }
    }
  }
  const map = parseMap(mapText)
  if (!map.ok) return { ok: false, file: paths.map, line: map.line, message: map.message }
  const manifests: ManifestVerdict[] = []
  for (let i = 0; i < texts.length; i++) {
    const manifest = parseManifest(texts[i], map.roles)
    if (!manifest.ok) {
      return { ok: false, file: paths.manifests[i], line: manifest.line, message: manifest.message }
    }
    manifests.push(manifest)
  }
  return { ok: true, map, manifests }
}
