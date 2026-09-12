const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const test = require("node:test")

const repositoryRoot = path.resolve(__dirname, "..")
const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, "manifest.json"), "utf8"))
const model = require(path.join(repositoryRoot, "quickshell", "ContributionFixture.js"))

const expectedLabels = ["Today", "Week", "Month", "Year"]
const expectedTotals = [4, 23, 87, 642]

test("manifest follows the schemaVersion 1 single bar-widget contract", () => {
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.id, "dev.commitpulse")
  assert.equal(manifest.license, "MIT")
  assert.deepEqual(manifest.kinds, ["bar-widget"])
  assert.equal(manifest.barWidget.allowMultiple, false)
  assert.equal(manifest.barWidget.defaultSection, "right")

  for (const entryPoint of Object.values(manifest.entryPoints)) {
    assert.equal(typeof entryPoint, "string")
    assert.notEqual(entryPoint, "")
    assert.equal(path.posix.isAbsolute(entryPoint), false)
    assert.equal(entryPoint.includes(".."), false)
    const resolved = path.resolve(repositoryRoot, entryPoint)
    const relative = path.relative(repositoryRoot, resolved)
    assert.equal(relative === "" || (relative !== ".." && !relative.startsWith(`..${path.sep}`)), true)
  }
})

test("fixture exposes the four contribution periods in order", () => {
  const periods = model.fixturePeriods()

  assert.deepEqual(model.periodLabels(), expectedLabels)
  assert.deepEqual(periods.map(period => period.label), expectedLabels)
  assert.equal(new Set(periods.map(period => period.label)).size, 4)
  assert.deepEqual(periods.map(period => period.total), expectedTotals)
  assert.deepEqual(model.validateContributionPeriods(periods), [])

  for (const period of periods) {
    assert.equal(Number.isInteger(period.total), true)
    assert.equal(period.total >= 0, true)
  }
})

test("fixture records are fresh and safe to treat as immutable", () => {
  const first = model.fixturePeriods()
  first[0].total = 999
  first.push({ label: "Extra", total: 1 })

  assert.deepEqual(model.fixturePeriods().map(period => period.total), expectedTotals)
})

test("validation rejects wrong length, labels, duplicates, and totals", () => {
  const invalid = [
    { label: "Today", total: 1.5 },
    { label: "Today", total: -1 },
    { label: "Month", total: 2 },
  ]

  const errors = model.validateContributionPeriods(invalid)
  assert.equal(errors.some(error => error.includes("exactly four")), true)
  assert.equal(errors.some(error => error.includes("labeled Week")), true)
  assert.equal(errors.some(error => error.includes("unique")), true)
  assert.equal(errors.some(error => error.includes("non-negative integer")), true)
})

test("summary formatting is stable and names the metric contributions", () => {
  assert.equal(
    model.formatContributionSummary(),
    "Today: 4 contributions · Week: 23 contributions · Month: 87 contributions · Year: 642 contributions"
  )
})
