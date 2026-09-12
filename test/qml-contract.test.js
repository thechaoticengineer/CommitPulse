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
  assert.match(readQml("BarWidget.qml"), /moduleName:\s*"dev\.commitpulse"/)
  assert.match(readQml("BarWidget.qml"), /import\s+"ContributionFixture\.js"\s+as\s+Fixture/)
})

test("one asynchronous controller is owned by the widget and injected into the popup", () => {
  const widget = readQml("BarWidget.qml")
  const panel = readQml("Panel.qml")
  const controller = readQml("DataController.qml")

  assert.equal((widget.match(/DataController\s*\{/g) || []).length, 1)
  assert.match(widget, /target\.dataController = dataController/)
  assert.match(panel, /property var dataController:\s*null/)
  assert.equal((panel.match(/DataController\s*\{/g) || []).length, 0)

  assert.equal((controller.match(/Process\s*\{/g) || []).length, 1)
  assert.match(controller, /readonly property int defaultRefreshInterval:\s*900000/)
  assert.match(controller, /interval:\s*root\.refreshInterval/)
  assert.match(controller, /Component\.onCompleted:\s*startupTimer\.start\(\)/)
  assert.equal((controller.match(/onTriggered:\s*root\.refresh\(\)/g) || []).length, 2)
  assert.match(controller, /var arguments = \[root\.helperExecutable\]/)
  assert.doesNotMatch(controller, /\[\s*["'](?:ba)?sh["']/)

  const guard = controller.indexOf("if (root.running || !ContributionState.retryAllowed")
  const launch = controller.indexOf("helperProcess.running = true")
  assert.notEqual(guard, -1)
  assert.notEqual(launch, -1)
  assert.ok(guard < launch)
})

test("bar widget preserves the installed nested popout lifecycle", () => {
  const widget = readQml("BarWidget.qml")

  for (const member of ["opened", "open", "close", "toggle", "togglePanel", "closeForPopoutSwitch", "injectPanel"]) {
    assert.match(widget, new RegExp(`(?:property|function)\\s+(?:\\w+\\s+)?${member}\\b`))
  }
  assert.match(widget, /popoutSwitchClosing/)
  assert.match(widget, /anchorItem"\s+in\s+target\)\s+target\.anchorItem = button/)
  assert.match(widget, /onPressed:\s*function\s*\(mouseButton\)\s*\{\s*if \(mouseButton === Qt\.LeftButton\)\s+root\.togglePanel\(\)/)
  assert.match(widget, /source:\s*Qt\.resolvedUrl\("Panel\.qml"\)/)
  assert.match(widget, /active:\s*true/)
})

test("detail popup uses the Panel and KeyboardPanel contract for four fixture totals", () => {
  const panel = readQml("Panel.qml")

  assert.match(panel, /^Panel\s*\{/m)
  assert.match(panel, /KeyboardPanel\s*\{/)
  assert.match(panel, /anchorItem:\s*root\.anchorItem/)
  assert.match(panel, /owner:\s*root\.barIdentity/)
  assert.match(panel, /bar:\s*root\.bar/)
  assert.match(panel, /onCloseRequested:\s*root\.close\(\)/)
  assert.match(panel, /model:\s*root\.periods/)
  assert.match(panel, /text:\s*periodRow\.modelData\.label/)
  assert.match(panel, /text:\s*periodRow\.modelData\.total \+ " contributions"/)
  assert.doesNotMatch(panel, /#[0-9a-fA-F]{3,8}\b/)
})
