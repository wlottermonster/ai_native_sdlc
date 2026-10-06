// The message set, as a pure module: what is said once, what the set keeps in
// session state, and what it reads back from there.
import { test, expect } from 'claude-code/testing'
import { createNotices } from './notices.ts'

test('REQ-MOD-018 a message is shown the first time and not again', () => {
  const n = createNotices()
  expect(n.once('a', 'engine map: one')).toBe(true)
  expect(n.once('a', 'engine map: one')).toBe(false)
})

test('REQ-MOD-018 an identical message under a different key is not shown again', () => {
  const n = createNotices()
  expect(n.once('a', 'engine map: same words')).toBe(true)
  expect(n.once('b', 'engine map: same words')).toBe(false)
})

test('REQ-MOD-018 a different message is shown', () => {
  const n = createNotices()
  expect(n.once('a', 'engine map: one')).toBe(true)
  expect(n.once('b', 'engine map: two')).toBe(true)
})

test('REQ-MOD-018 a message the session state already holds is not shown again', () => {
  const first = createNotices(new Set<string>())
  expect(first.once('a', 'engine map: one')).toBe(true)
  const stored = first.fresh()
  // A hot reload: module memory is gone, the session state is not.
  const after = createNotices(new Set<string>(), stored)
  expect(after.once('a', 'engine map: one')).toBe(false)
  expect(after.once('c', 'engine map: one')).toBe(false)
  expect(after.once('b', 'engine map: two')).toBe(true)
})

test('REQ-MOD-018 fresh lists only what was newly said, for the session state write', () => {
  const n = createNotices(new Set<string>(), [])
  expect(n.fresh()).toEqual([])
  n.once('a', 'engine map: one')
  n.once('a', 'engine map: one')
  expect(n.fresh().length).toBe(2)
  expect(n.fresh().some(s => s.includes('engine map: one'))).toBe(true)
})

test('REQ-MOD-018 the process memory is shared, so a set whose state read failed still holds what this process said', () => {
  const memory = new Set<string>()
  expect(createNotices(memory, []).once('a', 'engine map: one')).toBe(true)
  // The fallback when $.state fails: the same memory with nothing stored.
  expect(createNotices(memory).once('a', 'engine map: one')).toBe(false)
})
