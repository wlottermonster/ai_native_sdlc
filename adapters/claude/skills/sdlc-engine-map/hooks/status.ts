// The judge check and the mod's status line, as pure functions of what the
// engine reports and what the map says. No engine call is made here:
// register.ts hands in the model read, HOME, the file read and the chain state.
//
//   - the main loop's model id, any trailing `[...]` stripped, matches the
//     judge line's first entry when it equals the entry, equals `claude-` plus
//     the entry, or starts with `claude-` plus the entry plus `-`
//   - one line: `judge: <entry>` or `JUDGE MISMATCH: <id> is not <entry>`, then
//     ` | judge=… build=… verify=… read=…` in that fixed order, each the role's
//     first entry, with ` → <entry in force>` (or ` → frontmatter`) after any
//     role whose first entry was classified unavailable in this process; other
//     roles are left out
//   - a missing or refused map gives `engine map: <file> refused line <n>` or
//     `engine map: <file> missing or unreadable`; the dispatch notice already
//     says the rest once
//   - the map is read at every computation, never kept
import { loadBinding } from './map.ts'
import { inForce, type ChainState } from './chain.ts'
import type { Notices } from './notices.ts'

const ROLES = ['judge', 'build', 'verify', 'read'] as const
const NONE = 'none'
const VARIABLE = 'CLAUDE_CODE_SUBAGENT_MODEL'

export function stripSuffix(id: string): string {
  return id.replace(/\[[^\]]*\]$/, '')
}

export function matches(id: string, entry: string): boolean {
  const bare = stripSuffix(id)
  const full = `claude-${entry}`
  return bare === entry || bare === full || bare.startsWith(`${full}-`)
}

export type MapView =
  | { ok: true; roles: ReadonlyMap<string, readonly string[]> }
  | { ok: false; file: string; line?: number }

// judgeId undefined: the engine did not report the main loop's model.
export type StatusInput = { map: MapView; judgeId: string | undefined; chain: ChainState }

function roleText(role: string, list: readonly string[] | undefined, chain: ChainState): string {
  if (list === undefined || list.length === 0) return `${role}=${NONE}`
  const entry = inForce(list, chain.gone(role))
  if (entry === list[0]) return `${role}=${list[0]}`
  return `${role}=${list[0]} → ${entry ?? 'frontmatter'}`
}

export function statusLine(s: StatusInput): string {
  if (!s.map.ok) {
    return s.map.line === undefined
      ? `engine map: ${s.map.file} missing or unreadable`
      : `engine map: ${s.map.file} refused line ${s.map.line}`
  }
  const roles = s.map.roles
  const judge = roles.get('judge')?.[0]
  let flag: string
  if (s.judgeId === undefined) {
    flag = `JUDGE UNKNOWN: the engine did not report the main model, judge is ${judge ?? NONE}`
  } else if (judge !== undefined && matches(s.judgeId, judge)) {
    flag = `judge: ${judge}`
  } else {
    flag = `JUDGE MISMATCH: ${stripSuffix(s.judgeId)} is not ${judge ?? NONE}`
  }
  const map = ROLES.map(r => roleText(r, roles.get(r), s.chain)).join(' ')
  return `${flag} | ${map}`
}

export type StatusDeps = {
  home: string | undefined
  model: () => Promise<string>
  read: (path: string) => Promise<string>
  chain: ChainState
}

export async function computeStatus(d: StatusDeps): Promise<string> {
  let map: MapView
  if (d.home === undefined || d.home === '') {
    map = { ok: false, file: '~/.claude/sdlc-engines.conf' }
  } else {
    const file = `${d.home}/.claude/sdlc-engines.conf`
    let binding
    try {
      binding = await loadBinding({ fs: { read: d.read } }, { map: file, manifests: [] })
    } catch {
      binding = { ok: false as const, file, message: 'cannot read it' }
    }
    map = binding.ok ? { ok: true, roles: binding.map.roles } : { ok: false, file: binding.file, line: binding.line }
  }
  let judgeId: string | undefined
  try {
    const id = await d.model()
    judgeId = typeof id === 'string' && id !== '' ? id : undefined
  } catch {
    judgeId = undefined
  }
  return statusLine({ map, judgeId, chain: d.chain })
}

export function subagentVariableNotice(value: string): string {
  return `engine map: ${VARIABLE} is set (${value}); the map still decides the dispatches the mod routes, because a hook-set model outranks the variable on this build; the variable governs only the dispatches the mod leaves alone`
}

// Said once per process, whatever the value; unset or empty says nothing.
export function variableNotice(value: string | undefined, n: Notices): string | undefined {
  if (value === undefined || value === '') return undefined
  const text = subagentVariableNotice(value)
  return n.once(`variable\n${VARIABLE}`, text) ? text : undefined
}
