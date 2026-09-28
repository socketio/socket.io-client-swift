import test from "node:test"
import assert from "node:assert/strict"
import { observePolling } from "./polling-proof-observer.mjs"

// Deliberately delay rejection after abort. The observer must await cleanup,
// not merely stop waiting for a request that is still using the connection.
function waitForAbort(signal, cleanedUp) {
  return new Promise((_, reject) => {
    const abort = () => setTimeout(() => { cleanedUp(); reject(signal.reason) }, 10)
    if (signal.aborted) abort()
    else signal.addEventListener("abort", abort, { once: true })
  })
}

test("a timed-out GET is aborted and settled without starting another GET", async () => {
  let active = 0
  let calls = 0
  const result = await observePolling(signal => {
    calls += 1
    active += 1
    return waitForAbort(signal, () => { active -= 1 })
  }, () => false, 20)
  assert.equal(result.timedOut, true)
  assert.equal(calls, 1)
  assert.equal(active, 0)
  assert.deepEqual(result.frames, [])
})

test("the deadline also aborts an unfinished response body", async () => {
  let bodyPending = true
  let calls = 0
  const result = await observePolling(async signal => {
    calls += 1
    return { status: 200, text: () => waitForAbort(signal, () => { bodyPending = false }) }
  }, () => false, 20)
  assert.equal(result.timedOut, true)
  assert.equal(calls, 1)
  assert.equal(bodyPending, false)
})

test("completed polls are sequential and both acknowledgement frames are retained", async () => {
  let active = 0
  let calls = 0
  const result = await observePolling(async () => {
    assert.equal(active, 0)
    active += 1
    const frame = `43${calls++}`
    return { status: 200, text: async () => { active -= 1; return frame } }
  }, frames => frames.includes("430") && frames.includes("431"))
  assert.equal(result.timedOut, false)
  assert.equal(calls, 2)
  assert.equal(active, 0)
  assert.deepEqual(result.frames, ["430", "431"])
})

test("a closed server session records its status and ends the observation", async () => {
  let calls = 0
  let consumed = false
  const result = await observePolling(async () => {
    calls += 1
    return { status: 400, text: async () => { consumed = true; return "closed" } }
  }, () => false)
  assert.equal(calls, 1)
  assert.equal(consumed, true)
  assert.equal(result.terminalStatus, 400)
  assert.equal(result.timedOut, false)
})

test("unexpected network errors fail the proof rather than passing as absent acks", async () => {
  const failure = new Error("network failed")
  await assert.rejects(observePolling(async () => { throw failure }, () => false), error => error === failure)
})

test("invalid deadlines are rejected before polling", async () => {
  for (const timeout of [0, -1, Infinity, NaN]) {
    await assert.rejects(observePolling(() => { assert.fail("must not poll") }, () => false, timeout), RangeError)
  }
})
