// The fallback chain: which entries of each role's list were classified
// unavailable in this process, and what a routed subagent's failed turn does
// to them.
//
// A spawn resolves before its model is first called, so a model that does not
// exist fails later, at the subagent's own turn.complete, with a bare `error`
// reason and no error kind. The failed dispatch is never retried (a second
// spawn could start a duplicate subagent); instead the entry it ran on is
// classified with one bounded one-token completion, and only an answer that
// the model is unavailable marks that entry, by name. The entry in force for a
// role is the first entry of the map's CURRENT list that is not marked, so an
// edit to the map applies at once and a promoted entry is never skipped; past
// the last one the role sets no model and the frontmatter decides.
//
// Pure: register.ts hands in the classifier, the message set and the chain,
// which it opens from the engine's session state at each hook (so the marks
// survive a hot reload) over the process memory below (so they survive a
// session state that cannot be read).
import type { Notices } from './notices.ts'

// The prefix of every notice the routing and the chain say.
export const PREFIX = 'engine map'

// A notice and the key it is said once under.
export type Notice = { key: string; text: string }

// The entries classified unavailable, by role. `markGone` answers true only
// when the entry was not marked before.
export type ChainState = {
  gone(role: string): ReadonlySet<string>
  markGone(role: string, entry: string): boolean
}

export type GoneByRole = Readonly<Record<string, readonly string[]>>

// A chain opened on the session state: `fresh()` is what this view marked, for
// register.ts to write back.
export type SessionChain = ChainState & { fresh(): Record<string, string[]> }

export function createChain(memory: Map<string, Set<string>> = new Map(), stored: GoneByRole = {}): SessionChain {
  const added = new Map<string, string[]>()
  const storedList = (role: string): readonly string[] => {
    const list = Object.prototype.hasOwnProperty.call(stored, role) ? stored[role] : undefined
    return Array.isArray(list) ? list.filter((s): s is string => typeof s === 'string') : []
  }
  const gone = (role: string): ReadonlySet<string> => new Set<string>([...storedList(role), ...(memory.get(role) ?? [])])
  return {
    gone,
    markGone(role, entry) {
      if (gone(role).has(entry)) return false
      let held = memory.get(role)
      if (held === undefined) {
        held = new Set<string>()
        memory.set(role, held)
      }
      held.add(entry)
      added.set(role, [...(added.get(role) ?? []), entry])
      return true
    },
    fresh() {
      return Object.fromEntries([...added].map(([role, list]) => [role, [...list]]))
    },
  }
}

// The first entry of the list not classified unavailable; undefined when every
// entry is (the role is exhausted).
export function inForce(list: readonly string[], gone: ReadonlySet<string>): string | undefined {
  return list.find(entry => !gone.has(entry))
}

// What the mod set on one dispatch: the role, the entry, and the role's list as
// the map gave it at that dispatch (for the notice naming the next entry).
export type Dispatched = { role: string; entry: string; chain: readonly string[] }

// The subagents the mod routed, by agentId, until their first turn ends. Held
// in process memory and capped, so an unattended session cannot grow it
// without bound: past the cap the oldest is forgotten (a failure of its turn is
// then not classified).
export type Pending = {
  remember(agentId: string, d: Dispatched): void
  take(agentId: string): Dispatched | undefined
}

export const PENDING_CAP = 64

export function createPending(cap: number = PENDING_CAP): Pending {
  const by = new Map<string, Dispatched>()
  return {
    remember(agentId, d) {
      by.delete(agentId)
      by.set(agentId, d)
      while (by.size > cap) {
        const oldest = by.keys().next()
        if (oldest.done === true) break
        by.delete(oldest.value)
      }
    },
    take(agentId) {
      const d = by.get(agentId)
      by.delete(agentId)
      return d
    },
  }
}

// Process memory: the marks (beneath the session state's), the routed agents,
// and the classification calls in flight by role and entry.
export const processGone = new Map<string, Set<string>>()
export const processPending: Pending = createPending()
export const processInflight = new Map<string, Promise<boolean>>()

// The one classification call: one token on the entry, cut after a few seconds.
export function classificationRequest(model: string): { model: string; prompt: string; maxTokens: number; timeoutMs: number } {
  return { model, prompt: '.', maxTokens: 1, timeoutMs: 5000 }
}

// Unavailable: an API error with status 404, or an error kind naming the model.
// Anything else (a rate limit, overload, server error, an answer, an empty
// reply, a timeout) is not evidence the model is gone.
export function isUnavailable(r: unknown): boolean {
  if (typeof r !== 'object' || r === null) return false
  const o = r as { isAnswered?: unknown; reason?: unknown; status?: unknown; error?: unknown }
  if (o.isAnswered !== false || o.reason !== 'api-error') return false
  return o.status === 404 || (typeof o.error === 'string' && o.error.includes('model_not_found'))
}

export function exhausted(role: string, tried: number): Notice {
  return {
    key: `exhausted\n${role}`,
    text: `${PREFIX}: role ${role}: all ${tried} entries unavailable this process, frontmatter decides`,
  }
}

// Said once per role and entry moved past.
function fellBack(role: string, entry: string, next: string): Notice {
  return {
    key: `fallback\n${role}\n${entry}`,
    text: `${PREFIX}: role ${role}: ${entry} unavailable, later dispatches use ${next}`,
  }
}

export type TurnLike = { agentId?: string; reason: string }

export type TurnDeps = {
  pending: Pending
  chain: ChainState
  notices: Notices
  classify: (model: string) => Promise<unknown>
  // The classification calls in flight, by role and entry: every failure of
  // one entry while its call is open waits on that call instead of making one.
  inflight: Map<string, Promise<boolean>>
}

// One classification of one entry, shared while it is in flight. A call that
// rejects (a model the engine refuses to send to) counts as not unavailable.
function classifyOnce(d: TurnDeps, role: string, entry: string): Promise<boolean> {
  const key = `${role}\n${entry}`
  const open = d.inflight.get(key)
  if (open !== undefined) return open
  const call = (async () => {
    try {
      return isUnavailable(await d.classify(entry))
    } catch {
      return false
    }
  })()
  d.inflight.set(key, call)
  void call.then(() => {
    if (d.inflight.get(key) === call) d.inflight.delete(key)
  })
  return call
}

// A turn has ended. Only an error turn of a subagent the mod routed, whose entry
// is not already marked, is classified; the agent is forgotten either way. An
// unavailable answer marks that entry alone, so a late answer can never move a
// role backwards or past an entry it did not classify.
export async function onTurnComplete(e: TurnLike, d: TurnDeps): Promise<{ notice?: string }> {
  if (typeof e.agentId !== 'string') return {}
  const was = d.pending.take(e.agentId)
  if (was === undefined || e.reason !== 'error') return {}
  if (d.chain.gone(was.role).has(was.entry)) return {}

  if (!(await classifyOnce(d, was.role, was.entry))) return {}
  d.chain.markGone(was.role, was.entry)

  const next = inForce(was.chain, d.chain.gone(was.role))
  const said = next === undefined ? exhausted(was.role, was.chain.length) : fellBack(was.role, was.entry, next)
  return d.notices.once(said.key, said.text) ? { notice: said.text } : {}
}
