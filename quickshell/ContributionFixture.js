// Deterministic, fictional contribution data for the first plugin increment.
// Keep this module Qt-free so it can be checked with Node as well as imported
// by the Quickshell UI. fixturePeriods() returns fresh records on each call;
// callers should treat those records as immutable.

var PERIOD_LABELS = ["Today", "Week", "Month", "Year"]
var FIXTURE_TOTALS = [4, 23, 87, 642]

function periodLabels() {
  return PERIOD_LABELS.slice()
}

function fixturePeriods() {
  var periods = []
  for (var i = 0; i < PERIOD_LABELS.length; i++) {
    periods.push({
      label: PERIOD_LABELS[i],
      total: FIXTURE_TOTALS[i]
    })
  }
  return periods
}

// Returns an array of messages so callers can decide how to report invalid
// fixture/model data without coupling the model to a UI or runtime logger.
function validateContributionPeriods(periods) {
  var errors = []

  if (!Array.isArray(periods)) {
    return ["periods must be an array"]
  }

  if (periods.length !== PERIOD_LABELS.length) {
    errors.push("periods must contain exactly four entries")
  }

  var labels = []
  for (var i = 0; i < periods.length; i++) {
    var period = periods[i]
    if (!period || typeof period !== "object") {
      errors.push("period " + i + " must be an object")
      continue
    }

    var label = String(period.label === undefined || period.label === null ? "" : period.label)
    labels.push(label)
    if (PERIOD_LABELS[i] !== label) {
      errors.push("period " + i + " must be labeled " + PERIOD_LABELS[i])
    }
    if (labels.indexOf(label) !== i) {
      errors.push("period labels must be unique")
    }

    var total = period.total
    if (typeof total !== "number" || !isFinite(total) || Math.floor(total) !== total || total < 0) {
      errors.push("period " + label + " total must be a non-negative integer")
    }
  }

  return errors
}

function formatContributionSummary(periods) {
  var values = periods || fixturePeriods()
  var errors = validateContributionPeriods(values)
  if (errors.length > 0) {
    return "Invalid contribution fixture"
  }

  var parts = []
  for (var i = 0; i < values.length; i++) {
    parts.push(values[i].label + ": " + values[i].total + " contributions")
  }
  return parts.join(" · ")
}

if (typeof module !== "undefined") {
  module.exports = {
    periodLabels: periodLabels,
    fixturePeriods: fixturePeriods,
    validateContributionPeriods: validateContributionPeriods,
    formatContributionSummary: formatContributionSummary
  }
}
