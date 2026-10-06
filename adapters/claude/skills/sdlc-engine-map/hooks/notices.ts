// The set of messages the mod has already shown. `once` answers true the first
// time a message is offered and false every time after: a message counts as
// shown when its key OR its exact text was shown before, so an identical
// message is never repeated whatever key it comes under (REQ-MOD-018).
//
// What was shown lives in two places: `memory`, a Set the process keeps (lost
// on a hot reload), and `stored`, the entries the engine's session state held
// when the set was opened (kept across a hot reload). register.ts reads
// `stored` from `$.state` at the start of each hook and writes `fresh()` back;
// when that read fails, the set is opened on memory alone. Callers (routing,
// chain, status) see only the `Notices` interface and stay pure.

export type Notices = { once(key: string, text: string): boolean }

export type SessionNotices = Notices & {
  // The entries this set added, to be written to the session state.
  fresh(): string[]
}

const keyEntry = (key: string) => `key:${key}`
const textEntry = (text: string) => `text:${text}`

export function createNotices(memory: Set<string> = new Set<string>(), stored: readonly string[] = []): SessionNotices {
  const held = new Set<string>(stored)
  const added: string[] = []
  const seen = (entry: string) => memory.has(entry) || held.has(entry)
  return {
    once(key: string, text: string): boolean {
      const k = keyEntry(key)
      const t = textEntry(text)
      if (seen(k) || seen(t)) return false
      for (const entry of [k, t]) {
        memory.add(entry)
        added.push(entry)
      }
      return true
    },
    fresh(): string[] {
      return [...added]
    },
  }
}

// The process memory register.ts opens every set on.
export const processMemory = new Set<string>()
