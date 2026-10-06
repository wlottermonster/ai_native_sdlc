// agent.spawn routing, as a pure function of the event and what the files say.
// No engine call is made here: register.ts hands in the reads, HOME, the
// session root and the message set, so every case is driven by fakes.
//
//   - a fork, a teammate, or a name holding `:` (a plugin's agent) passes
//     through unchanged and nothing is said, before any file is read
//   - the map is `<HOME>/.claude/sdlc-engines.conf`, never anywhere else
//   - `<root>/.claude/agents/roles.conf`, when it exists, is consulted first for
//     the agent's name, then `<HOME>/.claude/agents/roles.conf`
//   - a missing or refused map or manifest (or one whose existence cannot be
//     checked) routes nothing at all, and that is said once
//   - a bound agent with no model gets its role's entry in force: the first
//     entry of the list read now that chain.ts has not marked unavailable; an
//     explicit model equal to it passes as given; one that differs passes as
//     given and the bypass is said once for that agent
//   - a role whose every entry was classified unavailable sets no model (the
//     frontmatter decides), said once for the role with the count tried
//   - an unbound name passes through unchanged and nothing is said
//   - anything that throws while deciding passes the dispatch through as given
//     and is said once: routing never throws, so it never turns into a deny
import { loadBinding } from './map.ts'
import type { Notices } from './notices.ts'
import { createChain, exhausted, inForce, PREFIX, type ChainState, type Dispatched, type Notice } from './chain.ts'

export type RouteDeps = {
  home: string | undefined
  root: string | undefined
  // Set when asking for the session root failed: the project manifest cannot
  // be consulted, so nothing is routed rather than routing past it.
  rootError?: string
  read: (path: string) => Promise<string>
  exists: (path: string) => Promise<boolean>
}

export type SpawnLike = { subagentType: string; model?: string; fork?: boolean; isTeammate?: boolean }

// `dispatched` is set only when the mod set the model: what to remember of
// the spawn, so a failure of its turn can be classified.
export type Routed<E> = { input: E; notice?: string; dispatched?: Dispatched }

function refusal(file: string, message: string, line?: number): Notice {
  const where = line === undefined ? file : `${file} line ${line}`
  const text = `${PREFIX}: routing is off, every dispatch keeps its own model: ${where}: ${message}`
  return { key: `refused\n${text}`, text }
}

function say<E>(input: E, n: Notices, said: Notice): Routed<E> {
  return n.once(said.key, said.text) ? { input, notice: said.text } : { input }
}

export async function route<E extends SpawnLike>(
  e: E,
  d: RouteDeps,
  n: Notices,
  chain: ChainState = createChain(),
): Promise<Routed<E>> {
  try {
    return await decide(e, d, n, chain)
  } catch (err) {
    const text = `${PREFIX}: routing failed for ${String(e.subagentType)}, the dispatch keeps its own model: ${String(err)}`
    try {
      return n.once(`failed\n${text}`, text) ? { input: e, notice: text } : { input: e }
    } catch {
      return { input: e }
    }
  }
}

async function decide<E extends SpawnLike>(e: E, d: RouteDeps, n: Notices, chain: ChainState): Promise<Routed<E>> {
  if (e.fork === true || e.isTeammate === true || e.subagentType.includes(':')) return { input: e }

  if (d.home === undefined || d.home === '') {
    return say(e, n, refusal('~/.claude/sdlc-engines.conf', 'HOME is not set, so the map cannot be found'))
  }
  const mapPath = `${d.home}/.claude/sdlc-engines.conf`
  const userPath = `${d.home}/.claude/agents/roles.conf`

  if (d.rootError !== undefined) {
    return say(e, n, refusal('<session root>/.claude/agents/roles.conf', `cannot find the session root: ${d.rootError}`))
  }

  const manifests: string[] = []
  if (d.root !== undefined && d.root !== '') {
    const projectPath = `${d.root}/.claude/agents/roles.conf`
    if (projectPath !== userPath) {
      let present: boolean
      try {
        present = await d.exists(projectPath)
      } catch (err) {
        return say(e, n, refusal(projectPath, `cannot tell whether it exists: ${String(err)}`))
      }
      if (present) manifests.push(projectPath)
    }
  }
  manifests.push(userPath)

  const binding = await loadBinding({ fs: { read: d.read } }, { map: mapPath, manifests })
  if (!binding.ok) return say(e, n, refusal(binding.file, binding.message, binding.line))

  let role: string | undefined
  for (const m of binding.manifests) {
    role = m.agents.get(e.subagentType)
    if (role !== undefined) break
  }
  if (role === undefined) return { input: e }
  const list = binding.map.roles.get(role)
  if (list === undefined || list.length === 0) return { input: e }
  const entry = inForce(list, chain.gone(role))
  if (entry === undefined) {
    if (e.model !== undefined) return { input: e }
    return say(e, n, exhausted(role, list.length))
  }

  if (e.model === undefined) {
    return { input: { ...e, model: entry }, dispatched: { role, entry, chain: [...list] } }
  }
  if (e.model === entry) return { input: e }
  const agent = e.subagentType
  return say(e, n, {
    key: `bypass\n${agent}`,
    text: `${PREFIX}: bypassed for ${agent}: the call named ${e.model}, the map's entry for role ${role} is ${entry}; the call's model stands`,
  })
}
