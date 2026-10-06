// The hooks module of the engine-map mod. It routes; it never gates.
//
// agent.spawn: the engine's `$` is adapted to the pure routing module
// (routing.ts), which decides; this file only reads HOME and the session root,
// hands over the file reads, shows a notice the first time, and calls `next`
// exactly once with the input routing returned, remembering the agent it
// started when the mod set its model.
//
// turn.complete: a routed subagent's turn that ended in error is handed to
// chain.ts, which classifies its entry with one bounded completion and may mark
// that entry unavailable for later dispatches of the role. The turn's own
// result is passed on untouched and the failed dispatch is never retried.
//
// session.start and turn.start (every turn.start is the main loop's): the main
// loop's model as the engine reports it is checked against the judge line and
// the one-line status is set from the map read now and the chain in force
// (status.ts). session.start also says once that CLAUDE_CODE_SUBAGENT_MODEL is
// set, when it is. Both pass their event on unchanged.
//
// Session state: each hook opens two keys of the engine's session state
// (types/index.d.ts) before anything else, the message set (`said`) and the
// entries classified unavailable by role (`gone`), so both survive a hot
// reload, and writes back what it added before it calls `next`. A session
// state that cannot be opened or written does not stop routing: both are
// then kept in this process's memory only, and that is said once.
//
// Safety (safety.ts): every registration is wrapped, so one the engine refuses
// by throwing is recorded and the rest still register (REQ-MOD-005); the first
// hook that runs says which were refused. Every registration carries the same
// `.catch` handler, which announces the failure and returns `next(e)`
// (REQ-MOD-004).
import type { Register } from 'claude-code'
import { route, type RouteDeps } from './routing.ts'
import { createNotices, processMemory, type Notices, type SessionNotices } from './notices.ts'
import { announceFailure, refusedNotice, type Failure, type OpenNotices } from './safety.ts'
import {
  classificationRequest,
  createChain,
  onTurnComplete,
  processGone,
  processInflight,
  processPending,
  PREFIX,
  type GoneByRole,
  type SessionChain,
} from './chain.ts'
import { computeStatus, variableNotice } from './status.ts'

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

// The session state keys (types/index.d.ts): the message set, and the entries
// classified unavailable by role.
const SAID = { plugin: 'sdlc-engine-map', key: 'said' } as const
const GONE = { plugin: 'sdlc-engine-map', key: 'gone' } as const
type Ref = typeof SAID | typeof GONE

type StateEngine = {
  state: {
    get(ref: Ref): Promise<{ value?: unknown; version: number }>
    set(ref: Ref, value: never, options?: { ifVersion?: number }): Promise<{ isSet: boolean; version: number }>
  }
}

type EnvEngine = { env: { get(name: string): Promise<string | undefined> } }

// What a read answers, or undefined when it rejects.
async function orUndefined<T>(read: () => Promise<T>): Promise<T | undefined> {
  try {
    return await read()
  } catch {
    return undefined
  }
}

// HOME, undefined when it is unset or cannot be read: the missing-map case.
// (The engine wants each variable name spelled as a literal at the call.)
function readHome($: EnvEngine): Promise<string | undefined> {
  return orUndefined(() => $.env.get('HOME'))
}

// The parts of the engine's `$` the status line uses.
type Engine = EnvEngine & {
  session: { model(): Promise<string> }
  fs: { read(path: string): Promise<unknown> }
  ui: { status(text: string | undefined): unknown }
}

function entries(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((s): s is string => typeof s === 'string') : []
}

function goneEntries(value: unknown): Record<string, string[]> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return {}
  const out: Record<string, string[]> = {}
  for (const [role, list] of Object.entries(value as Record<string, unknown>)) out[role] = entries(list)
  return out
}

// Each save writes what this hook added into its key, merged with what is
// there, retried when another hook wrote in between; a write that loses three
// races leaves the additions in process memory only. (The engine wants each
// `$.state` reference spelled as a literal at the call, so the two keys do not
// share one helper.)
async function saveSaid($: StateEngine, fresh: string[]): Promise<void> {
  if (fresh.length === 0) return
  for (let attempt = 0; attempt < 3; attempt++) {
    const read = await $.state.get(SAID)
    const held = entries(read.value)
    const merged = [...held, ...fresh.filter(s => !held.includes(s))]
    const wrote = await $.state.set(SAID, merged as never, { ifVersion: read.version })
    if (wrote.isSet) return
  }
}

async function saveGone($: StateEngine, fresh: GoneByRole): Promise<void> {
  if (Object.keys(fresh).length === 0) return
  for (let attempt = 0; attempt < 3; attempt++) {
    const read = await $.state.get(GONE)
    const held = goneEntries(read.value)
    for (const [role, list] of Object.entries(fresh)) {
      const kept = held[role] ?? []
      held[role] = [...kept, ...list.filter(s => !kept.includes(s))]
    }
    const wrote = await $.state.set(GONE, held as never, { ifVersion: read.version })
    if (wrote.isSet) return
  }
}

// The message set alone, for the `.catch` handler: rejects when the session
// state cannot be read, and announceFailure then falls back to process memory.
async function openSaid($: StateEngine): Promise<OpenNotices> {
  const read = await $.state.get(SAID)
  const notices = createNotices(processMemory, entries(read.value))
  return { notices, save: () => saveSaid($, notices.fresh()) }
}

type Ui = { ui: { toast(text: string): unknown; log(text: string): unknown } }

function show($: Ui, text: string | undefined): void {
  if (text === undefined) return
  $.ui.toast(text)
  $.ui.log(text)
}

function stateUnavailable($: Ui, n: Notices, why: string): void {
  const text = `${PREFIX}: session state unavailable (${why}); routing goes on, and what the mod has said and the entries classified unavailable are kept in this process's memory only`
  if (n.once('state-unavailable', text)) show($, text)
}

type Session = { notices: SessionNotices; chain: SessionChain; save(): Promise<void> }

// Opens the message set and the chain on the session state, over process
// memory. Never throws: a state that cannot be opened or written leaves both on
// process memory, said once.
async function openSession($: StateEngine & Ui): Promise<Session> {
  let said: string[] = []
  let gone: GoneByRole = {}
  let failure: string | undefined
  try {
    said = entries((await $.state.get(SAID)).value)
    gone = goneEntries((await $.state.get(GONE)).value)
  } catch (err) {
    failure = message(err)
    said = []
    gone = {}
  }
  const notices = createNotices(processMemory, said)
  const chain = createChain(processGone, gone)
  if (failure !== undefined) stateUnavailable($, notices, failure)
  const save = async (): Promise<void> => {
    if (failure !== undefined) return
    try {
      await saveSaid($, notices.fresh())
      await saveGone($, chain.fresh())
    } catch (err) {
      stateUnavailable($, notices, message(err))
    }
  }
  return { notices, chain, save }
}

// The events the engine refused at this load, said once at the first hook.
const refused: string[] = []

function sayRefused($: Ui, n: Notices): void {
  const text = refusedNotice(refused)
  if (text !== undefined && n.once('refused', text)) show($, text)
}

// The body of every `.catch` literal: says the failure, never throws.
async function failed($: Ui & StateEngine, event: string, failure: Failure, called: boolean): Promise<void> {
  await announceFailure({
    toast: text => $.ui.toast(text),
    log: text => $.ui.log(text),
    open: () => openSaid($),
    memory: processMemory,
  }, event, failure, called)
}

async function readText($: Engine, path: string): Promise<string> {
  const text = await $.fs.read(path)
  if (typeof text !== 'string') throw new Error('not read as text')
  return text
}

async function showStatus($: Engine, chain: SessionChain): Promise<void> {
  const line = await computeStatus({
    home: await readHome($),
    model: () => $.session.model(),
    read: path => readText($, path),
    chain,
  })
  $.ui.status(line)
}

export const register: Register = on => {
  refused.length = 0
  // One registration: refused by a throw, it is recorded and the rest go on.
  const guard = (event: string, attach: () => void): void => {
    try {
      attach()
    } catch {
      refused.push(event)
    }
  }

  guard('agent.spawn', () => {
    on('agent.spawn', async ($, e, next) => {
      const session = await openSession($)
      sayRefused($, session.notices)
      let root: string | undefined
      let rootError: string | undefined
      try {
        root = await $.session.root()
      } catch (err) {
        rootError = message(err)
      }
      const deps: RouteDeps = {
        home: await readHome($),
        root,
        rootError,
        read: path => readText($, path),
        exists: (path: string) => $.fs.exists(path),
      }
      const routed = await route(e, deps, session.notices, session.chain)
      show($, routed.notice)
      await session.save()
      const r = await next(routed.input)
      if (routed.dispatched !== undefined && 'agentId' in r && typeof r.agentId === 'string') {
        processPending.remember(r.agentId, routed.dispatched)
      }
      return r
    }).catch(async ($, e, next) => {
      await failed($, 'agent.spawn', next.error, next.called)
      return next(e)
    })
  })

  guard('turn.complete', () => {
    on('turn.complete', async ($, e, next) => {
      const session = await openSession($)
      sayRefused($, session.notices)
      const out = await onTurnComplete(e, {
        pending: processPending,
        chain: session.chain,
        notices: session.notices,
        classify: model => $.model.complete(classificationRequest(model)),
        inflight: processInflight,
      })
      show($, out.notice)
      await session.save()
      return next(e)
    }).catch(async ($, e, next) => {
      await failed($, 'turn.complete', next.error, next.called)
      return next(e)
    })
  })

  guard('session.start', () => {
    on('session.start', async ($, e, next) => {
      const session = await openSession($)
      sayRefused($, session.notices)
      const value = await orUndefined(() => $.env.get('CLAUDE_CODE_SUBAGENT_MODEL'))
      show($, variableNotice(value, session.notices))
      await session.save()
      await showStatus($, session.chain)
      return next(e)
    }).catch(async ($, e, next) => {
      await failed($, 'session.start', next.error, next.called)
      return next(e)
    })
  })

  guard('turn.start', () => {
    on('turn.start', async ($, e, next) => {
      const session = await openSession($)
      sayRefused($, session.notices)
      await session.save()
      await showStatus($, session.chain)
      return next(e)
    }).catch(async ($, e, next) => {
      await failed($, 'turn.start', next.error, next.called)
      return next(e)
    })
  })
}
