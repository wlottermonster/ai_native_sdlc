// The mod's failure policy, one place for all four registrations.
//
// Every `on(...)` in register.ts carries a `.catch` literal that awaits
// announceFailure and returns `next(e)` (REQ-MOD-004); the engine accepts only
// a function literal or the name of one there, so the handler cannot be built
// by a factory. The engine runs it afresh when the hook threw or overran its
// budget. announceFailure says the mod, the event, the failure kind and message
// as a toast and a transcript line, once (REQ-MOD-018); with `next.called`
// false the event then goes on un-routed, with it true `next` replays what the
// hook's own call already settled to. No file is read or written: the only
// engine calls are the session state and the ui.
//
// refusedNotice(…) is what the first hook that runs says about registrations
// the engine refused by throwing (REQ-MOD-005).
import { createNotices, type Notices } from './notices.ts'

export type Failure = { kind: string; message?: string }

const PREFIX = 'engine map mod'

export function failureNotice(event: string, failure: Failure, called: boolean): string {
  const why = failure.message === undefined || failure.message === '' ? failure.kind : `${failure.kind}: ${failure.message}`
  const after = called ? 'the result it had already settled stands' : 'the event proceeds un-routed'
  return `${PREFIX}: the ${event} hook failed (${why}); ${after}`
}

export function refusedNotice(events: readonly string[]): string | undefined {
  if (events.length === 0) return undefined
  return `${PREFIX}: ${events.join(', ')} not registered on this build; routing falls back to the agents' frontmatter`
}

export type OpenNotices = { notices: Notices; save(): Promise<void> }

export type FailureDeps = {
  toast(text: string): unknown
  log(text: string): unknown
  // Opens the message set on the session state; may reject.
  open(): Promise<OpenNotices>
  // The process memory a set is opened on when the session state cannot be.
  memory: Set<string>
}

// Says the failure once, as a toast and a transcript line, and records it.
// Never throws: the `.catch` literal that awaits it must still return next(e).
export async function announceFailure(d: FailureDeps, event: string, failure: Failure, called: boolean): Promise<void> {
  try {
    const text = failureNotice(event, failure, called)
    let said: OpenNotices
    try {
      said = await d.open()
    } catch {
      said = { notices: createNotices(d.memory), save: async () => {} }
    }
    if (said.notices.once(text, text)) {
      d.toast(text)
      d.log(text)
    }
    await said.save()
  } catch {
    // Announcing is best effort; the event must still go on.
  }
}
