const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const test = require("node:test")

const repositoryRoot = path.resolve(__dirname, "..")
const read = file => fs.readFileSync(path.join(repositoryRoot, file), "utf8")

test("demo root instantiates the fixture-backed widget and opens its popup", () => {
  const demo = read("demo/shell.qml")

  assert.match(demo, /^ShellRoot\s*\{/m)
  assert.match(demo, /CommitPulse\.BarWidget\s*\{/)
  assert.match(demo, /bar:\s*demoBar/)
  assert.match(demo, /widget\.open\(\)/)
  assert.match(demo, /COMMITPULSE_SMOKE_READY: BarWidget and fixture popup loaded/)
  assert.match(demo, /Qt\.quit\(\)/)
})

test("smoke workflow isolates XDG state and has a documented static fallback", () => {
  const smoke = read("scripts/qml-smoke.sh")

  for (const required of [
    "npm test",
    "mktemp -d",
    "HOME=$smoke_root/home",
    "XDG_CONFIG_HOME=$smoke_root/config",
    "XDG_CACHE_HOME=$smoke_root/cache",
    "XDG_STATE_HOME=$smoke_root/state",
    "/usr/share/omarchy/shell/Commons",
    "/usr/share/omarchy/shell/Ui",
    "WAYLAND_DISPLAY",
    "runtime skipped",
    "timeout --foreground --kill-after=2s 15s",
    "COMMITPULSE_SMOKE_READY",
  ]) {
    assert.equal(smoke.includes(required), true, `missing smoke workflow contract: ${required}`)
  }

  assert.doesNotMatch(smoke, /\.config\/omarchy\/shell\.json/)
  assert.doesNotMatch(smoke, /plugins\/dev\.commitpulse/)
})

test("read-only reviews have a tracked, state-free agent mount point", () => {
  const ignore = read(".gitignore")

  assert.equal(fs.existsSync(path.join(repositoryRoot, ".agents", ".gitkeep")), true)
  assert.match(ignore, /\.agents\/\*/)
  assert.match(ignore, /!\.agents\/\.gitkeep/)
})
