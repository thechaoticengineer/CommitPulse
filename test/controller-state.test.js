const assert = require("node:assert/strict")
const test = require("node:test")

const State = require("../quickshell/ContributionState.js")

const periods = totals => ["today", "week", "month", "year"].map((name, index) => ({ name, total: totals[index] }))
const envelope = (state, totals = [3, 12, 38, 211]) => ({
  schemaVersion: 1,
  state,
  effectiveTimezone: "Europe/Warsaw",
  ...(state === "unavailable" ? {} : { periods: periods(totals) }),
  attemptedAt: "2096-02-29T12:00:00Z",
  ...(state === "unavailable" ? {} : { lastUpdated: "2096-02-29T11:59:00Z" }),
  visibility: { privateContributions: "unknown" },
  ...(state === "fresh" ? {} : { error: { kind: "offline", message: "Contribution data is unavailable offline." } }),
})

function apply(previous, value, exitCode = 0) {
  return State.applyOutput(previous, typeof value === "string" ? value : JSON.stringify(value), exitCode, "2096-02-29T12:00:01Z")
}

test("fresh and stale envelopes produce exactly four ordered display periods", () => {
  const fresh = apply(State.initialState(), envelope("fresh"))
  assert.deepEqual(fresh.periods, [
    { name: "today", label: "Today", total: 3 },
    { name: "week", label: "Week", total: 12 },
    { name: "month", label: "Month", total: 38 },
    { name: "year", label: "Year", total: 211 },
  ])
  assert.equal(fresh.state, "fresh")
  assert.equal(fresh.stale, false)

  const stale = apply(fresh, { ...envelope("stale", [4, 14, 40, 220]), retryAt: "2096-02-29T12:10:00Z" })
  assert.deepEqual(stale.periods.map(period => period.total), [4, 14, 40, 220])
  assert.equal(stale.state, "stale")
  assert.equal(stale.stale, true)
  assert.equal(stale.retryAt, "2096-02-29T12:10:00Z")
  assert.equal(stale.errorCategory, "general")
})

test("unavailable and malformed output retain the last complete snapshot", () => {
  const fresh = apply(State.initialState(), envelope("fresh", [8, 18, 48, 318]))
  const unavailable = apply(fresh, envelope("unavailable"), 1)
  assert.deepEqual(unavailable.periods, fresh.periods)
  assert.equal(unavailable.state, "unavailable")
  assert.equal(unavailable.stale, true)

  for (const malformed of [
    "not json",
    JSON.stringify({ ...envelope("fresh"), periods: periods([0, 0, 0]) }),
    JSON.stringify({ ...envelope("fresh"), periods: periods([0, 0, 0, 0]).reverse() }),
    JSON.stringify({ ...envelope("fresh"), periods: periods([0, 0, 0, Number.MAX_SAFE_INTEGER + 1]) }),
  ]) {
    const failed = apply(fresh, malformed, 1)
    assert.deepEqual(failed.periods, fresh.periods)
    assert.equal(failed.state, "error")
    assert.equal(failed.errorKind, "invalid_output")
  }

  const noSnapshot = apply(State.initialState(), envelope("unavailable"), 1)
  assert.deepEqual(noSnapshot.periods, [])
  assert.equal(noSnapshot.periods.some(period => period.total === 0), false)
})

test("a non-zero process exit still accepts a valid envelope", () => {
  const stale = apply(State.initialState(), envelope("stale", [6, 16, 46, 306]), 17)
  assert.equal(stale.state, "stale")
  assert.deepEqual(stale.periods.map(period => period.total), [6, 16, 46, 306])

  const unavailable = apply(stale, {
    ...envelope("unavailable"),
    error: { kind: "authentication", message: "GitHub CLI authentication is required." },
  }, 4)
  assert.equal(unavailable.errorCategory, "authentication")
  assert.equal(unavailable.errorDetail, "GitHub authentication is required.")
  assert.deepEqual(unavailable.periods, stale.periods)
})

test("repeated refresh results only replace totals after complete validation", () => {
  let state = State.initialState()
  state = apply(state, envelope("fresh", [1, 2, 3, 4]))
  state = apply(state, "{", 1)
  assert.deepEqual(state.periods.map(period => period.total), [1, 2, 3, 4])
  state = apply(state, envelope("unavailable"), 1)
  assert.deepEqual(state.periods.map(period => period.total), [1, 2, 3, 4])
  state = apply(state, envelope("fresh", [5, 6, 7, 8]))
  assert.deepEqual(state.periods.map(period => period.total), [5, 6, 7, 8])
})

test("schema validation rejects invalid metadata and excessive output", () => {
  const valid = envelope("fresh")
  assert.equal(State.validateEnvelope(valid), true)
  assert.equal(State.validateEnvelope({ ...valid, schemaVersion: 2 }), false)
  assert.equal(State.validateEnvelope({ ...valid, state: "loading" }), false)
  assert.equal(State.validateEnvelope({ ...valid, effectiveTimezone: "" }), false)
  assert.equal(State.validateEnvelope({ ...valid, attemptedAt: "yesterday" }), false)
  assert.equal(State.validateEnvelope({ ...valid, attemptedAt: "2096-02-30T12:00:00Z" }), false)
  assert.equal(State.validateEnvelope({ ...valid, visibility: {} }), false)
  assert.equal(State.validateEnvelope({ ...valid, login: "must-not-be-accepted" }), false)

  const oversized = apply(apply(State.initialState(), valid), "x".repeat(State.maxOutputBytes + 1))
  assert.equal(oversized.errorKind, "output_too_large")
  assert.deepEqual(oversized.periods.map(period => period.total), [3, 12, 38, 211])
})

test("retry metadata blocks only future retry times", () => {
  const now = Date.parse("2096-02-29T12:00:00Z")
  assert.equal(State.retryAllowed("", now), true)
  assert.equal(State.retryAllowed("2096-02-29T11:59:59Z", now), true)
  assert.equal(State.retryAllowed("2096-02-29T12:00:01Z", now), false)
})
