const assert = require("node:assert/strict")
const { spawn, spawnSync } = require("node:child_process")
const { once } = require("node:events")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const test = require("node:test")

const repositoryRoot = path.resolve(__dirname, "..")
const read = file => fs.readFileSync(path.join(repositoryRoot, file), "utf8")

test("demo root instantiates the widget and opens its popup", () => {
  const demo = read("demo/shell.qml")

  assert.match(demo, /^ShellRoot\s*\{/m)
  assert.match(demo, /CommitPulse\.Widget\s*\{/)
  assert.match(demo, /bar:\s*demoBar/)
  assert.match(demo, /widget\.open\(\)/)
  assert.match(demo, /COMMITPULSE_SMOKE_READY: fresh stale auth malformed manual maximum active 1/)
  assert.match(demo, /panel\.statusTitle !== "Stale · Authentication required"/)
  assert.match(demo, /panel\.statusTitle !== "Loading contributions…"/)
  assert.match(demo, /panel\.statusTitle !== "Refreshing contributions…"/)
  assert.match(demo, /COMMITPULSE_SMOKE_STARTUP_LOADING: observed/)
  assert.match(demo, /panel\.refreshContributions\(\)/)
  assert.match(demo, /panel\.dataController\.maximumActiveProcesses !== 1/)
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
    "XDG_RUNTIME_DIR=$runtime_dir",
    "/usr/share/omarchy/shell/Commons",
    "/usr/share/omarchy/shell/Ui",
    "WAYLAND_DISPLAY",
    "runtime skipped",
    "timeout --foreground --kill-after=2s 15s",
    "COMMITPULSE_SCENARIO_STATE=$scenario_state",
    "COMMITPULSE_SCENARIO_GATE=$startup_gate",
    "COMMITPULSE_SMOKE_STARTUP_LOADING: observed",
    "staged_plugin",
    "runtime_bin/commitpulse-data",
    "COMMITPULSE_SMOKE_READY: fresh stale auth malformed manual maximum active 1",
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
    "bash -n test/scenario-helper.sh",
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
    "XDG_RUNTIME_DIR=$smoke_root/runtime",
    "COMMITPULSE_TEST_HELPER=$smoke_root/scenario-helper",
    "COMMITPULSE_SCENARIO_STATE=$scenario_state",
    "WAYLAND_DISPLAY",
    "active Wayland socket",
    "staged_plugin",
    "stage_root/bin/commitpulse-data",
    "fresh stale auth malformed manual startup maximum active 1",
  ]) {
    assert.equal(smoke.includes(required), true, `missing controller-smoke safeguard: ${required}`)
  }
  assert.equal(packageFile.scripts["smoke:controller"], "./scripts/controller-smoke.sh")
  assert.doesNotMatch(smoke, /QT_QPA_PLATFORM=offscreen/)
  assert.doesNotMatch(smoke, /\.config\/omarchy\/shell\.json/)
  assert.doesNotMatch(smoke, /plugins\/dev\.commitpulse/)
})

test("controller smoke honestly skips without a display backend", () => {
  const result = spawnSync("bash", [path.join(repositoryRoot, "scripts/controller-smoke.sh")], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: { ...process.env, DISPLAY: "", WAYLAND_DISPLAY: "", XDG_RUNTIME_DIR: "" },
    timeout: 5000,
  })

  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /CommitPulse controller smoke: SKIP; (?:quickshell is unavailable|an active Wayland socket .* is required)\./)
})

test("scenario helper contains only fictional bounded integration states", () => {
  const driver = read("test/scenario-helper.sh")

  for (const state of ['"state":"fresh"', '"state":"stale"', '"state":"unavailable"', '"kind":"authentication"', "fictional malformed output"]) {
    assert.equal(driver.includes(state), true, `missing scenario-helper state: ${state}`)
  }
  for (const guard of ["COMMITPULSE_SCENARIO_STATE", "COMMITPULSE_SCENARIO_GATE", "flock", "maximum-active", "invocation-count"]) {
    assert.equal(driver.includes(guard), true, `missing scenario-helper guard: ${guard}`)
  }
  assert.doesNotMatch(driver, /\bgh\b|api\.github|login|profileUrl|\.config\/omarchy/)
})

test("scenario helper gates the first result until startup loading is observed", async t => {
  const scenarioRoot = fs.mkdtempSync(path.join(os.tmpdir(), "commitpulse-gate-test."))
  const gate = path.join(scenarioRoot, "startup-observed")

  const child = spawn(path.join(repositoryRoot, "test/scenario-helper.sh"), [], {
    env: {
      ...process.env,
      COMMITPULSE_SCENARIO_STATE: scenarioRoot,
      COMMITPULSE_SCENARIO_GATE: gate,
      COMMITPULSE_SCENARIO_DELAY: "0",
    },
    stdio: ["ignore", "pipe", "pipe"],
  })
  t.after(() => {
    if (child.exitCode === null)
      child.kill("SIGTERM")
    fs.rmSync(scenarioRoot, { recursive: true, force: true })
  })
  let stdout = ""
  let stderr = ""
  child.stdout.setEncoding("utf8")
  child.stderr.setEncoding("utf8")
  child.stdout.on("data", chunk => { stdout += chunk })
  child.stderr.on("data", chunk => { stderr += chunk })

  await new Promise(resolve => setTimeout(resolve, 100))
  assert.equal(child.exitCode, null, "helper exited before the observation gate opened")
  assert.equal(stdout, "", "helper emitted a result before the observation gate opened")

  fs.writeFileSync(gate, "")
  const [exitCode] = await once(child, "exit")
  assert.equal(exitCode, 0, stderr)
  assert.match(stdout, /"state":"fresh"/)
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
