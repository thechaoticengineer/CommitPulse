const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const test = require("node:test")

const repositoryRoot = path.resolve(__dirname, "..")
const readQml = file => fs.readFileSync(path.join(repositoryRoot, "quickshell", file), "utf8")

test("manifest entry point is implemented by the bar widget", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, "manifest.json"), "utf8"))
  const entryPoint = path.join(repositoryRoot, manifest.entryPoints.barWidget)

  assert.equal(fs.existsSync(entryPoint), true)
  assert.match(readQml("Widget.qml"), /moduleName:\s*"dev\.commitpulse"/)
})

test("one asynchronous controller is owned by the widget and injected into the popup", () => {
  const widget = readQml("Widget.qml")
  const panel = readQml("Popup.qml")
  const controller = readQml("DataController.qml")

  assert.equal((widget.match(/DataController\s*\{/g) || []).length, 1)
  assert.match(widget, /target\.dataController = dataController/)
  assert.match(panel, /property var dataController:\s*null/)
  assert.equal((panel.match(/DataController\s*\{/g) || []).length, 0)
  assert.match(widget, /readonly property var periods:\s*dataController\.periods/)
  assert.match(panel, /readonly property var periods:\s*dataController \? dataController\.periods : \[\]/)
  assert.doesNotMatch(widget, /ContributionFixture/)
  assert.doesNotMatch(panel, /ContributionFixture/)

  assert.equal((controller.match(/Process\s*\{/g) || []).length, 1)
  assert.match(controller, /readonly property int defaultRefreshInterval:\s*900000/)
  assert.match(controller, /interval:\s*root\.refreshInterval/)
  assert.match(controller, /Component\.onCompleted:\s*startupTimer\.start\(\)/)
  assert.equal((controller.match(/onTriggered:\s*root\.refresh\(\)/g) || []).length, 2)
  assert.match(controller, /var arguments = \[root\.helperExecutable\]/)
  assert.match(controller, /Quickshell\.env\("COMMITPULSE_TEST_HELPER"\)/)
  assert.match(controller, /Qt\.resolvedUrl\("\.\.\/bin\/commitpulse-data"\)/)
  assert.doesNotMatch(controller, /\[\s*["'](?:ba)?sh["']/)

  const guard = controller.indexOf("if (root.running || !ContributionState.retryAllowed")
  const launch = controller.indexOf("helperProcess.running = true")
  assert.notEqual(guard, -1)
  assert.notEqual(launch, -1)
  assert.ok(guard < launch)
})

test("bar widget preserves the installed nested popout lifecycle", () => {
  const widget = readQml("Widget.qml")

  for (const member of ["opened", "open", "close", "toggle", "togglePanel", "closeForPopoutSwitch", "injectPanel"]) {
    assert.match(widget, new RegExp(`(?:property|function)\\s+(?:\\w+\\s+)?${member}\\b`))
  }
  assert.match(widget, /popoutSwitchClosing/)
  assert.match(widget, /anchorItem"\s+in\s+target\)\s+target\.anchorItem = button/)
  assert.match(widget, /onPressed:\s*function\s*\(mouseButton\)\s*\{\s*if \(mouseButton === Qt\.LeftButton\)\s+root\.togglePanel\(\)/)
  assert.match(widget, /import "\." as CommitPulse/)
  assert.match(widget, /sourceComponent:\s*Component\s*\{\s*CommitPulse\.Popup\s*\{\}/)
  assert.doesNotMatch(widget, /source:\s*Qt\.resolvedUrl\("Popup\.qml"\)/)
  assert.match(widget, /active:\s*true/)
})

test("detail popup preserves the Panel and KeyboardPanel lifecycle and focus contract", () => {
  const panel = readQml("Popup.qml")

  assert.match(panel, /^Panel\s*\{/m)
  assert.match(panel, /KeyboardPanel\s*\{/)
  assert.match(panel, /anchorItem:\s*root\.anchorItem/)
  assert.match(panel, /owner:\s*root\.barIdentity/)
  assert.match(panel, /bar:\s*root\.bar/)
  assert.match(panel, /focusTarget:\s*keyCatcher/)
  assert.match(panel, /onCloseRequested:\s*root\.close\(\)/)
  assert.match(panel, /onMoveRequested:\s*function \(dx, dy\)/)
  assert.match(panel, /onActivateRequested:\s*root\.activateSelectedAction\(\)/)
  assert.match(panel, /onTabRequested:\s*function \(direction\)/)
  assert.match(panel, /root\.switchPanel\(direction\)/)
  assert.match(panel, /model:\s*root\.hasTotals \? root\.periods : \[\]/)
  assert.match(panel, /text:\s*periodRow\.modelData\.label/)
  assert.match(panel, /text:\s*periodRow\.modelData\.total \+ " contributions"/)
})

test("live UI exposes four truthful counters and every required presentation", () => {
  const widget = readQml("Widget.qml")
  const panel = readQml("Popup.qml")
  const state = readQml("ContributionState.js")

  for (const label of ["Today", "Week", "Month", "Year"]) {
    assert.equal(state.includes(`"${label}"`), true, `missing live period label: ${label}`)
  }
  for (const presentation of [
    "Loading contributions…",
    "Refreshing contributions…",
    "Up to date",
    "Stale · ",
    "Authentication required",
    "Rate limited",
    "Offline",
    "Unavailable",
    "Refresh failed",
  ]) {
    assert.equal(panel.includes(presentation), true, `missing UI presentation: ${presentation}`)
  }

  assert.match(widget, /todayPeriod:\s*hasTotals \? periods\[0\] : null/)
  assert.match(widget, /todayValue:\s*todayPeriod && typeof todayPeriod\.total === "number"/)
  assert.match(widget, /horizontalSummary:\s*todayValue !== "" \? todayValue/)
  assert.match(widget, /verticalValue:\s*todayValue !== "" \? todayValue/)
  assert.doesNotMatch(widget, /total:\s*0/)
  assert.doesNotMatch(widget, /\?\s*0\b|:\s*0\b/)
  assert.match(panel, /showingStaleTotals/)
  assert.match(panel, /Showing (?:the last successful|saved) totals/)
  assert.match(panel, /readonly property string lastUpdatedText:/)
  assert.match(panel, /Updated just now/)
  assert.match(panel, /formatTimestamp/)
})

test("popup actions use native controls, guarded refresh, and a fixed safe profile target", () => {
  const panel = readQml("Popup.qml")

  assert.equal((panel.match(/\bButton\s*\{/g) || []).length, 2)
  assert.match(panel, /enabled:\s*dataController \? dataController\.canRefresh : false/)
  assert.match(panel, /if \(!dataController \|\| !dataController\.canRefresh\)/)
  assert.match(panel, /return dataController\.refresh\(\)/)
  assert.match(panel, /readonly property string githubProfileTarget:\s*"https:\/\/github\.com\/"/)
  assert.match(panel, /return String\(target \|\| ""\) === githubProfileTarget/)
  assert.match(panel, /if \(!isTrustedProfileTarget\(candidate\)\)\s*return false/)
  assert.match(panel, /Qt\.openUrlExternally\(candidate\)/)
  assert.match(panel, /hasCursor:\s*root\.selectedAction === 0/)
  assert.match(panel, /onTextKey:\s*function \(text\)/)
  assert.doesNotMatch(panel, /Process\s*\{|Quickshell\.Io|\b(?:exec|spawn|run)\s*\(/)
  assert.doesNotMatch(panel, /https?:\/\/(?!github\.com\/)/)
})

test("live surfaces use native Omarchy styling without a hard-coded palette", () => {
  const widget = readQml("Widget.qml")
  const panel = readQml("Popup.qml")

  for (const qml of [widget, panel]) {
    assert.match(qml, /\bStyle\./)
    assert.match(qml, /\bColor\./)
    assert.doesNotMatch(qml, /#[0-9a-fA-F]{3,8}\b/)
  }
  assert.match(widget, /Style\.bar\.iconSlot/)
  assert.match(widget, /root\.vertical/)
  assert.match(panel, /Style\.space\(/)
  assert.match(panel, /\bButton\s*\{/)
})
