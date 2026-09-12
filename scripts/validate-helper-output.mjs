#!/usr/bin/env node

import fs from "node:fs"

const [mode, inputPath] = process.argv.slice(2)
const topLevelFields = new Set([
  "schemaVersion",
  "state",
  "effectiveTimezone",
  "periods",
  "attemptedAt",
  "lastUpdated",
  "retryAt",
  "visibility",
  "error",
])
const errorKinds = new Set([
  "missing_gh",
  "authentication",
  "offline",
  "timeout",
  "rate_limit",
  "api",
  "malformed_response",
  "malformed_data",
  "invalid_timezone",
  "internal",
  "not_implemented",
])
const environmentalKinds = new Set([
  "missing_gh",
  "authentication",
  "offline",
  "timeout",
  "rate_limit",
  "api",
])
const periodNames = ["today", "week", "month", "year"]
const timestampPattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/

function fail() {
  throw new Error("helper output does not satisfy the schema-v1 contract")
}

function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function exactFields(value, allowed, required) {
  if (!object(value)) fail()
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail()
  }
  for (const key of required) {
    if (!Object.hasOwn(value, key)) fail()
  }
}

function timestamp(value) {
  if (typeof value !== "string" || !timestampPattern.test(value) || Number.isNaN(Date.parse(value))) fail()
}

function validatePeriods(periods) {
  if (!Array.isArray(periods) || periods.length !== periodNames.length) fail()
  periods.forEach((period, index) => {
    exactFields(period, new Set(["name", "total"]), ["name", "total"])
    if (period.name !== periodNames[index] || !Number.isSafeInteger(period.total) || period.total < 0) fail()
  })
}

function validateEnvelope(envelope) {
  exactFields(envelope, topLevelFields, ["schemaVersion", "state", "effectiveTimezone", "visibility"])
  if (envelope.schemaVersion !== 1) fail()
  if (!["fresh", "stale", "unavailable"].includes(envelope.state)) fail()
  if (typeof envelope.effectiveTimezone !== "string" || envelope.effectiveTimezone.length < 1) fail()

  exactFields(envelope.visibility, new Set(["privateContributions"]), ["privateContributions"])
  if (!["unknown", "included"].includes(envelope.visibility.privateContributions)) fail()

  for (const field of ["attemptedAt", "lastUpdated", "retryAt"]) {
    if (Object.hasOwn(envelope, field)) timestamp(envelope[field])
  }
  if (Object.hasOwn(envelope, "error")) {
    exactFields(envelope.error, new Set(["kind", "message"]), ["kind", "message"])
    if (!errorKinds.has(envelope.error.kind) || typeof envelope.error.message !== "string" || envelope.error.message.length < 1) fail()
  }

  if (envelope.state === "fresh") {
    if (!Object.hasOwn(envelope, "attemptedAt") || !Object.hasOwn(envelope, "lastUpdated")) fail()
    validatePeriods(envelope.periods)
    if (Object.hasOwn(envelope, "error") && envelope.error.kind !== "internal") fail()
  } else if (envelope.state === "stale") {
    if (!Object.hasOwn(envelope, "attemptedAt") || !Object.hasOwn(envelope, "lastUpdated") || !Object.hasOwn(envelope, "error")) fail()
    validatePeriods(envelope.periods)
  } else {
    if (Object.hasOwn(envelope, "periods") || Object.hasOwn(envelope, "lastUpdated") || !Object.hasOwn(envelope, "error")) fail()
  }
}

function validateFixture(envelope) {
  const expected = {
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
  if (JSON.stringify(envelope) !== JSON.stringify(expected)) fail()
}

if (!["--fixture", "--live"].includes(mode) || !inputPath || process.argv.length !== 4) {
  process.stderr.write("usage: validate-helper-output.mjs (--fixture|--live) FILE\n")
  process.exit(2)
}

try {
  const info = fs.lstatSync(inputPath)
  if (!info.isFile() || info.size < 2 || info.size > 1024 * 1024) fail()
  const envelope = JSON.parse(fs.readFileSync(inputPath, "utf8"))
  validateEnvelope(envelope)

  if (mode === "--fixture") {
    validateFixture(envelope)
    process.exit(0)
  }
  if (envelope.state === "fresh" && !Object.hasOwn(envelope, "error")) process.exit(0)
  if (envelope.state === "unavailable" && environmentalKinds.has(envelope.error.kind)) process.exit(10)
  process.exit(1)
} catch {
  process.stderr.write("helper output does not satisfy the schema-v1 contract\n")
  process.exit(1)
}
