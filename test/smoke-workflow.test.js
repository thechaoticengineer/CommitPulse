const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const test = require("node:test")

const repositoryRoot = path.resolve(__dirname, "..")
const read = file => fs.readFileSync(path.join(repositoryRoot, file), "utf8")

test("demo root instantiates the widget and opens its popup", () => {
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

test("aggregate validation covers the helper and preserves existing QML smoke checks", () => {
  const validation = read("scripts/validate.sh")
  const packageFile = JSON.parse(read("package.json"))

  for (const required of [
    "gofmt -l cmd internal",
    "go vet ./...",
    "go test ./...",
    "go test -race ./...",
    "go build -trimpath",
    "PATH=/nonexistent XDG_CACHE_HOME=\"$validation_root/cache\"",
    "commitpulse-data\" -fixture",
    "validate-helper-output.mjs --fixture",
    "npm run smoke:controller",
    "npm run smoke",
    "git diff --check",
  ]) {
    assert.equal(validation.includes(required), true, `missing aggregate validation step: ${required}`)
  }
  assert.equal(packageFile.scripts.validate, "./scripts/validate.sh")
  assert.match(packageFile.scripts["build:helper"], /bin\/commitpulse-data/)
})

test("controller smoke runs the compiled helper fixture with isolated state", () => {
  const smoke = read("scripts/controller-smoke.sh")
  const packageFile = JSON.parse(read("package.json"))

  for (const required of [
    "mktemp -d",
    "go build -trimpath",
    "HOME=$smoke_root/home",
    "XDG_CONFIG_HOME=$smoke_root/config",
    "XDG_CACHE_HOME=$smoke_root/cache",
    "XDG_STATE_HOME=$smoke_root/state",
    "COMMITPULSE_TEST_HELPER=$smoke_root/commitpulse-data",
    "COMMITPULSE_TEST_FIXTURE=1",
    "maximum active 1",
  ]) {
    assert.equal(smoke.includes(required), true, `missing controller-smoke safeguard: ${required}`)
  }
  assert.equal(packageFile.scripts["smoke:controller"], "./scripts/controller-smoke.sh")
  assert.doesNotMatch(smoke, /\.config\/omarchy\/shell\.json/)
  assert.doesNotMatch(smoke, /plugins\/dev\.commitpulse/)
})

test("live smoke bounds requests and suppresses authenticated output", () => {
  const liveSmoke = read("scripts/live-smoke.sh")
  const packageFile = JSON.parse(read("package.json"))

  for (const required of [
    "gh auth status --active",
    "mktemp -d",
    "XDG_CACHE_HOME=\"$smoke_root/cache\"",
    "-max-attempts 1",
    "> \"$smoke_root/output.json\"",
    "validate-helper-output.mjs\" --live",
    "CommitPulse live smoke: PASS",
    "CommitPulse live smoke: SKIP",
    "CommitPulse live smoke: FAIL",
  ]) {
    assert.equal(liveSmoke.includes(required), true, `missing live-smoke safeguard: ${required}`)
  }
  assert.doesNotMatch(liveSmoke, /cat\s+/)
  assert.doesNotMatch(liveSmoke, /--show-token/)
  assert.equal(packageFile.scripts["smoke:live"], "./scripts/live-smoke.sh")
})
