// Schema-v1 validation and state transitions shared by QML and Node tests.
// This module never logs or returns helper output. Invalid data is reduced to
// fixed local error details so subprocess diagnostics cannot reach the UI.

var PERIOD_NAMES = ["today", "week", "month", "year"]
var PERIOD_LABELS = ["Today", "Week", "Month", "Year"]
var MAX_SAFE_INTEGER = 9007199254740991
var MAX_OUTPUT_BYTES = 1024 * 1024
var TIMESTAMP_PATTERN = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/
var TOP_LEVEL_FIELDS = ["schemaVersion", "state", "effectiveTimezone", "periods", "attemptedAt", "lastUpdated", "retryAt", "visibility", "error"]
var ERROR_KINDS = [
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
  "not_implemented"
]

function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key)
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function hasExactFields(value, allowed, required) {
  if (!isObject(value)) return false
  var keys = Object.keys(value)
  for (var i = 0; i < keys.length; i++) {
    if (allowed.indexOf(keys[i]) === -1) return false
  }
  for (var j = 0; j < required.length; j++) {
    if (!hasOwn(value, required[j])) return false
  }
  return true
}

function isTimestamp(value) {
  if (typeof value !== "string") return false
  var match = TIMESTAMP_PATTERN.exec(value)
  if (!match || isNaN(Date.parse(value))) return false
  var year = Number(match[1])
  var month = Number(match[2])
  var day = Number(match[3])
  var hour = Number(match[4])
  var minute = Number(match[5])
  var second = Number(match[6])
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59) return false
  var leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)
  var monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  return day >= 1 && day <= monthDays[month - 1]
}

function validatePeriods(periods) {
  if (!Array.isArray(periods) || periods.length !== PERIOD_NAMES.length) return false
  for (var i = 0; i < periods.length; i++) {
    var period = periods[i]
    if (!hasExactFields(period, ["name", "total"], ["name", "total"])) return false
    if (period.name !== PERIOD_NAMES[i]) return false
    if (typeof period.total !== "number" || !isFinite(period.total) || Math.floor(period.total) !== period.total || period.total < 0 || period.total > MAX_SAFE_INTEGER) return false
  }
  return true
}

function validateError(error) {
  return hasExactFields(error, ["kind", "message"], ["kind", "message"])
    && ERROR_KINDS.indexOf(error.kind) !== -1
    && typeof error.message === "string"
    && error.message.length > 0
}

function validateEnvelope(envelope) {
  if (!hasExactFields(envelope, TOP_LEVEL_FIELDS, ["schemaVersion", "state", "effectiveTimezone", "visibility"])) return false
  if (envelope.schemaVersion !== 1 || ["fresh", "stale", "unavailable"].indexOf(envelope.state) === -1) return false
  if (typeof envelope.effectiveTimezone !== "string" || envelope.effectiveTimezone.length === 0) return false
  if (!hasExactFields(envelope.visibility, ["privateContributions"], ["privateContributions"])) return false
  if (["unknown", "included"].indexOf(envelope.visibility.privateContributions) === -1) return false

  var timestampFields = ["attemptedAt", "lastUpdated", "retryAt"]
  for (var i = 0; i < timestampFields.length; i++) {
    var field = timestampFields[i]
    if (hasOwn(envelope, field) && !isTimestamp(envelope[field])) return false
  }
  if (hasOwn(envelope, "error") && !validateError(envelope.error)) return false

  if (envelope.state === "fresh") {
    if (!hasOwn(envelope, "attemptedAt") || !hasOwn(envelope, "lastUpdated") || !validatePeriods(envelope.periods)) return false
    return !hasOwn(envelope, "error") || envelope.error.kind === "internal"
  }
  if (envelope.state === "stale") {
    return hasOwn(envelope, "attemptedAt") && hasOwn(envelope, "lastUpdated") && hasOwn(envelope, "error") && validatePeriods(envelope.periods)
  }
  return !hasOwn(envelope, "periods") && !hasOwn(envelope, "lastUpdated") && hasOwn(envelope, "error")
}

function copyPeriods(periods) {
  var result = []
  for (var i = 0; i < periods.length; i++) {
    result.push({
      name: PERIOD_NAMES[i],
      label: PERIOD_LABELS[i],
      total: periods[i].total
    })
  }
  return result
}

function errorCategory(kind) {
  if (kind === "missing_gh" || kind === "authentication") return "authentication"
  if (kind === "rate_limit") return "rate-limit"
  return "general"
}

function errorDetail(kind) {
  var category = errorCategory(kind)
  if (category === "authentication") return "GitHub authentication is required."
  if (category === "rate-limit") return "GitHub's rate limit is temporarily preventing a refresh."
  return "GitHub contributions could not be refreshed."
}

function initialState() {
  return {
    periods: [],
    state: "loading",
    stale: false,
    attemptedAt: "",
    lastUpdated: "",
    retryAt: "",
    effectiveTimezone: "",
    privateContributions: "unknown",
    errorKind: "",
    errorCategory: "",
    errorDetail: ""
  }
}

function copyState(previous) {
  var source = previous || initialState()
  return {
    periods: copyPeriods(source.periods || []),
    state: source.state || "loading",
    stale: source.stale === true,
    attemptedAt: source.attemptedAt || "",
    lastUpdated: source.lastUpdated || "",
    retryAt: source.retryAt || "",
    effectiveTimezone: source.effectiveTimezone || "",
    privateContributions: source.privateContributions || "unknown",
    errorKind: source.errorKind || "",
    errorCategory: source.errorCategory || "",
    errorDetail: source.errorDetail || ""
  }
}

function localFailure(previous, attemptedAt, kind) {
  var next = copyState(previous)
  next.state = "error"
  next.stale = next.periods.length === PERIOD_NAMES.length
  next.attemptedAt = attemptedAt || ""
  next.errorKind = kind
  next.errorCategory = "general"
  next.errorDetail = "GitHub contributions could not be refreshed."
  return next
}

function applyOutput(previous, output, exitCode, attemptedAt) {
  var text = typeof output === "string" ? output : ""
  if (text.length === 0 || text.length > MAX_OUTPUT_BYTES) return localFailure(previous, attemptedAt, text.length > MAX_OUTPUT_BYTES ? "output_too_large" : "invalid_output")

  var envelope
  try {
    envelope = JSON.parse(text)
  } catch (error) {
    return localFailure(previous, attemptedAt, "invalid_output")
  }
  if (!validateEnvelope(envelope)) return localFailure(previous, attemptedAt, "invalid_output")

  var next = copyState(previous)
  next.state = envelope.state
  next.attemptedAt = hasOwn(envelope, "attemptedAt") ? envelope.attemptedAt : (attemptedAt || "")
  next.retryAt = hasOwn(envelope, "retryAt") ? envelope.retryAt : ""
  next.effectiveTimezone = envelope.effectiveTimezone
  next.privateContributions = envelope.visibility.privateContributions

  if (envelope.state === "fresh" || envelope.state === "stale") {
    next.periods = copyPeriods(envelope.periods)
    next.lastUpdated = envelope.lastUpdated
  }
  next.stale = envelope.state === "stale" || (envelope.state === "unavailable" && next.periods.length === PERIOD_NAMES.length)

  if (hasOwn(envelope, "error")) {
    next.errorKind = envelope.error.kind
    next.errorCategory = errorCategory(envelope.error.kind)
    next.errorDetail = errorDetail(envelope.error.kind)
  } else {
    next.errorKind = ""
    next.errorCategory = ""
    next.errorDetail = ""
  }
  return next
}

function retryAllowed(retryAt, nowMilliseconds) {
  if (!retryAt) return true
  var retryMilliseconds = Date.parse(retryAt)
  return isNaN(retryMilliseconds) || retryMilliseconds <= nowMilliseconds
}

if (typeof module !== "undefined") {
  module.exports = {
    maxOutputBytes: MAX_OUTPUT_BYTES,
    validateEnvelope: validateEnvelope,
    initialState: initialState,
    applyOutput: applyOutput,
    retryAllowed: retryAllowed
  }
}
