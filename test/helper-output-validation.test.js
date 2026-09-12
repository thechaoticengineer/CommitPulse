const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")
const test = require("node:test")

const repositoryRoot = path.resolve(__dirname, "..")
const validator = path.join(repositoryRoot, "scripts", "validate-helper-output.mjs")
const fixtureEnvelope = {
  schemaVersion: 1,
  state: "fresh",
  effectiveTimezone: "UTC",
  periods: [
    { name: "today", total: 7 },
    { name: "week", total: 17 },
    { name: "month", total: 40 },
    { name: "year", total: 40 },
  ],
  attemptedAt: "2096-01-14T12:00:00Z",
  lastUpdated: "2096-01-14T12:00:00Z",
  visibility: { privateContributions: "unknown" },
}

function validate(mode, envelope) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "commitpulse-validator-test-"))
  const input = path.join(directory, "output.json")
  try {
    fs.writeFileSync(input, `${JSON.stringify(envelope)}\n`, { mode: 0o600 })
    return spawnSync(process.execPath, [validator, mode, input], { encoding: "utf8" })
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
}

test("fixture validator accepts only the stable fictional envelope", () => {
  assert.equal(validate("--fixture", fixtureEnvelope).status, 0)
  assert.equal(validate("--fixture", { ...fixtureEnvelope, periods: fixtureEnvelope.periods.slice(0, 3) }).status, 1)
})

test("live validator classifies fresh, environmental, and invalid output without values", () => {
  const pass = validate("--live", fixtureEnvelope)
  assert.equal(pass.status, 0)
  assert.equal(pass.stdout, "")
  assert.equal(pass.stderr, "")

  const unavailable = {
    schemaVersion: 1,
    state: "unavailable",
    effectiveTimezone: "UTC",
    attemptedAt: "2096-01-14T12:00:00Z",
    visibility: { privateContributions: "unknown" },
    error: { kind: "authentication", message: "sanitized" },
  }
  const skip = validate("--live", unavailable)
  assert.equal(skip.status, 10)
  assert.equal(skip.stdout, "")
  assert.equal(skip.stderr, "")

  const invalid = validate("--live", { ...fixtureEnvelope, login: "fictional-login" })
  assert.equal(invalid.status, 1)
  assert.equal(invalid.stdout, "")
  assert.equal(invalid.stderr.includes("fictional-login"), false)
})
