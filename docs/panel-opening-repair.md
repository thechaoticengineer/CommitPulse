# Panel opening repair

## Stage 1 diagnosis (2026-09-12)

Scope was task 0 only. No plugin, shell configuration, packaged Omarchy file,
watcher, timer, Forge process, or ReviewBox state was changed during diagnosis.
`PRODUCT.md` and `TASKS.md` were preserved as found.

### Reproduction and source identity

The running shell discovers `dev.commitpulse` as an enabled `bar-widget`, and
the bar reports a visible 74 by 26 logical-pixel widget on each output. The
repository and installed copies are byte-identical:

| File | SHA-256 |
| --- | --- |
| `manifest.json` | `c28f65684f7cc4ef546ef1b49ecb2edb7ac9cd2c52c1626198b789ac5bd7d9df` |
| `quickshell/BarWidget.qml` | `98e5aae3cc31b81d5414f31b8b4b0afaf574b89f3b102869985124323eff1bfa` |
| `quickshell/Panel.qml` | `e54d9db65852e288420c8ebc3bb83558fee5f49b433f74b14a41e760025c87cd` |
| `quickshell/DataController.qml` | `29dafc303a5292e507ad18c311c0b1eb176b9ac01437a92a8b8ba70df1657e04` |
| `quickshell/ContributionState.js` | `32dd7057ea4d59322d29f049bcc99f7836f6d8f7c52f16f7da12cedb7aed41b2` |
| `quickshell/ContributionFixture.js` | `2dca84db8580eb5affde2df0ac9bd0e56a2f278b7379de937f7473937eaee196` |

The failure was reproduced with the installed widget's own IPC `toggle`
handler, which calls the same `root.togglePanel()` used by its left-button
`WidgetButton.onPressed`. It was independently reproduced through the shell's
bar-widget routing:

```sh
omarchy-shell dev.commitpulse close
omarchy-shell dev.commitpulse toggle
hyprctl layers -j

omarchy-shell shell hide dev.commitpulse
omarchy-shell shell summon dev.commitpulse
hyprctl layers -j
```

Both routes left zero `omarchy-keyboard-panel` layer surfaces. The shell route
returned `ok`, confirming that it found the live bar widget and invoked
`open()`. An immediately action-correlated, privacy-filtered journal window was
empty: there was no new component, import, type, property, binding, anchor, or
surface error because the panel component was not reached.

An explicit open/close/reopen sequence observed `[]`, `[]`, `[]` mapped panel
surfaces for CommitPulse. The equivalent stock-clock sequence observed one
`[0,0,1920,1080]` surface, then `[]`, then the same positive-size surface again.

### Failing lifecycle boundary

The current Quickshell process's journal records the last installed-plugin
reload at 19:35:07, followed at 19:35:08 by three
`quickshell/Panel.qml[-1:-1]: No such file or directory` warnings, one for each
bar instance. The installed directory and `Panel.qml` now exist, and their
ctime is 19:35:07, so this is an installation/reload race rather than source
drift or a permanently absent file.

The upgrade path in `scripts/lifecycle.sh` first moves the live destination to
its backup and then moves the prepared tree into the destination. The shell's
file watcher can reload during that gap. `BarWidget.qml` itself survives long
enough to show the counter, but its eager URL Loader fails while `Panel.qml` is
absent. After the file returns, that Loader retains no `item`. Consequently
`open()`, `close()`, and `togglePanel()` all stop at their
`if (panelLoader.item)` guard. `PanelController.open`, `root.opened`, the
injected bar/anchor/host/controller values, `KeyboardPanel.open`, focus,
backing-surface visibility, geometry, and screen anchoring are never created or
changed. Repeated open/close/reopen requests therefore remain invisible.

This resolves the scoped risks as follows:

- CP0-R1: the `WidgetButton` emits an integer mouse button and
  `Qt.LeftButton` is handled correctly; faithful dispatch of the exact target
  handler reproduces the downstream failure.
- CP0-R2: the live Loader failed at URL resolution while the installed panel
  path was transiently absent. There is no evidence of an import, type, or
  property incompatibility after component creation because creation did not
  occur.
- CP0-R3: controller, anchor, geometry, and focus are not the first failure;
  the backing surface never exists.

### Stock comparison and minimal correction boundary

`omarchy.clock` uses the same bar root → eager Loader → injected panel →
`PanelController` → anchored `KeyboardPanel` contract. Running the equivalent
commands maps an `omarchy-keyboard-panel` surface at `[0,0,1920,1080]`, then
the supported hide action removes it. Its packaged panel path is never made
temporarily absent during a user-plugin upgrade.

The minimal correction should therefore keep the canonical installed plugin
path continuously populated while swapping a validated upgrade into place,
then use the existing rescan. On this system GNU `mv` supports same-filesystem
atomic `--exchange`, and the transfer stage is deliberately created beside the
destination. Stage 2 should cover that exact upgrade race and the real
repository `BarWidget.qml`/`Panel.qml` creation, visible positive-size surface,
close, reopen, and unavailable-data opening lifecycle; source-pattern checks or
a substitute popup are insufficient.

Privacy-filtered runtime evidence is retained under the private directory named
in `/tmp/commitpulse-stage1-latest`; it contains no contribution totals or
screenshots.

### Repository checks

All declared checks were run after this note was added, with complete output
redirected to that private evidence directory:

| Command | Exit | Result |
| --- | ---: | --- |
| `npm run build:helper` | 0 | Go helper built successfully. |
| `npm test` | 0 | 29 tests passed, 0 failed. |
| `npm run validate` | 0 | Go tests and race tests, helper build/validation, controller and QML runtime smokes, shell syntax, lifecycle tests, and `git diff --check` passed. |
| `npm run smoke:live` | 0 | Bounded live helper smoke passed without printing contribution values. |

The lifecycle suite's deliberately injected malformed-input, build, validation,
rescan, and enable failures appear in its log and are expected assertions; the
suite itself and aggregate validation both report `PASS`.

## Stage 2 fix and regression (2026-09-12)

The confirmed failure was corrected at the installer boundary. An upgrade now
uses GNU `mv --exchange --no-target-directory` to atomically swap the validated
transfer tree with the existing plugin directory. The canonical
`~/.config/omarchy/plugins/dev.commitpulse` path therefore always contains a
complete tree while the shell watcher is active. The exchanged old tree is then
moved to the existing timestamped backup path. Upgrade rollback also exchanges
the restored tree into place without temporarily removing the canonical path.
Fresh installs retain their existing atomic rename into an absent destination.

No QML content, data controller, helper, error-state behavior, profile target,
IPC identity, or keyboard behavior changed. No plugin was installed during this
stage.

### Targeted regressions

`scripts/lifecycle-test.sh` now places a selective `mv` observer around an
upgrade and fails if the canonical destination is absent after any filesystem
transition. Against the diagnosed two-rename implementation it exited 1 with
`upgrade made the canonical plugin destination temporarily absent`. With the
atomic exchange it passes while retaining the old complete tree in the expected
collision-safe backup.

`scripts/panel-lifecycle-smoke.sh` starts an isolated Quickshell instance on the
active Wayland compositor. It loads the repository's real `BarWidget.qml` and
eager `Panel.qml` against `/usr/share/omarchy/shell`'s `qs.Commons` and `qs.Ui`
modules. The harness invokes the registered production
`WidgetButton.triggerPress(Qt.LeftButton)` path, not a replacement panel. It
asserts Loader Ready, the real panel identity, non-null controller, a positive
anchor attached to a window, unavailable contribution data, and matching opened
and controller states. Hyprland then confirms exactly one
`omarchy-keyboard-panel` surface owned by that Quickshell process, with positive
dimensions contained by its output. The production `dev.commitpulse close` IPC
must unmap it; the click path must reopen the same real surface; a final close
must unmap it again. Relevant component/import/type/property/binding/path,
anchor, and Wayland errors fail the test.

The final stage-2 checks passed with complete output retained in the private
directory `/tmp/commitpulse-stage2.h5HCcQ`:

| Command | Exit | Result |
| --- | ---: | --- |
| `npm run build:helper` | 0 | Go helper build passed. |
| `npm test` | 0 | Node contract and state tests passed. |
| `npm run smoke:panel` | 0 | Real unavailable-data panel opened at 1920 by 1080, closed, reopened, and closed. |
| `npm run validate` | 0 | Formatting, Go vet/tests/race, helper validation, controller/QML/panel runtime smokes, installer lifecycle, shell syntax, and diff checks passed. |
| `npm run smoke:live` | 0 | Privacy-safe live helper smoke passed. |

## Stage 3 deployment finding (2026-09-12)

The stage-2 directory exchange kept the canonical path populated, but live
deployment proved that it did not preserve the running shell's recursive file
watch. After `./install.sh` returned 0, both `omarchy-shell dev.commitpulse
toggle` and `omarchy-shell shell summon dev.commitpulse '{}'` returned without
mapping a panel. The action-correlated journal again reported the installed
`Panel.qml` as missing even though `stat`, `realpath`, and SHA-256 comparison
proved that the file was present and readable. A later fresh entry-point URL
was rejected as `File name case mismatch`, and touching that installed file
produced no local-plugin watcher event. Supported rescan and disable/enable
cycles did not recover the detached watcher.

The repository correction now preserves the existing plugin directory inode
during upgrades. It copies the complete old tree to the normal timestamped
backup, atomically replaces validated files within the watched directory,
switches `manifest.json` last, and removes obsolete files only after the new
entry point is complete. Rollback uses the same inode-preserving sync. The live
entry points are now `quickshell/Widget.qml` and `quickshell/Popup.qml`, avoiding
the already-poisoned component URLs without changing the bar, popup content,
controller, data behavior, or keyboard contract. The lifecycle regression now
fails if an upgrade changes the destination inode as well as if the path ever
disappears.

Repository runtime evidence passes: `npm test` reports 29/29, `npm run
smoke:panel` opens the real unavailable-data popup on-screen, closes it,
reopens it, and closes it again, and `scripts/lifecycle-test.sh` reports PASS
with watched-directory inode continuity. The corrected tree is installed and
its manifest/QML match the repository; `shell.json` is byte-identical to the
pre-install snapshot with CommitPulse still at `right:1`, unrelated plugin
catalog entries compare equal, and installer-created backups remain present.

Live-session acceptance initially remained pending because the already-running
shell retained the detached watcher and poisoned component cache from the
earlier directory exchanges. All supported hot-reload paths were exhausted, so
the separately authorized one-time `omarchy restart shell` was required.

## Stage 3 installed-session verification (2026-09-12)

The final repository checks ran before live acceptance, with complete output in
the private directory `/tmp/commitpulse-stage3-final.rlIrT6`:

| Command | Exit | Result |
| --- | ---: | --- |
| `npm run build:helper` | 0 | The Go helper built successfully. |
| `npm test` | 0 | 29 tests passed, 0 failed. |
| `npm run validate` | 0 | Go vet/tests/race, helper validation, controller/QML/real-panel smokes, installer lifecycle, shell syntax and diff checks passed. |
| `npm run smoke:live` | 0 | Privacy-safe live helper smoke passed. |

The corrected tree had already been deployed by the repository installer after
the preceding successful checks. Immediately before the authorized recovery,
the installed manifest, QML, license and helper matched the repository,
`omarchy plugin validate` succeeded, the plugin directory inode was `1215500`,
CommitPulse was enabled at `right[1]`, and the nine plugin plus fourteen
`shell.json` installer backups were present. `shell.json` and a normalized
catalog of all unrelated plugins were saved for post-restart comparison.

Exactly one recovery command was run:

```sh
omarchy restart shell
```

It exited 0 and replaced stale shell PID `1393375` with PID `116722`. Once IPC
was ready, the production lifecycle was exercised with:

```sh
omarchy-shell shell summon dev.commitpulse '{}'
hyprctl layers -j | jq '<bounded omarchy-keyboard-panel selection>'
omarchy-shell shell hide dev.commitpulse
omarchy-shell dev.commitpulse toggle
hyprctl layers -j | jq '<bounded omarchy-keyboard-panel selection>'
wtype -k Escape
```

The first summon returned `ok` and Hyprland showed exactly one on-screen
`omarchy-keyboard-panel` surface at 1920 by 1080. The supported hide removed the
surface, the installed CommitPulse IPC toggle reopened exactly one surface, and
Escape removed it again. `shell debugBarGeometry` then reported three visible
monitor-local CommitPulse instances at 74 by 26 in the preserved right section.

For the unavailable-data case, touching the installed `Widget.qml` without
changing its bytes exercised the repaired stable-directory watcher. The fresh
shell logged `Local plugin changed, reloading: dev.commitpulse`; all three real
bar instances unloaded and returned, and an immediate production summon opened
exactly one positive-size surface before the asynchronous live helper completed.
The privacy-safe local crop
`/tmp/commitpulse-stage3-final.rlIrT6/unavailable-panel-evidence-final.png`
(SHA-256 `4db7da7d0df8ef95f488464dd41e4da0c39d84bb71e11225fbcd473df065c43f`)
shows the existing panel at its bar anchor with `Loading contributions…` and
`Waiting for GitHub contribution data.` plus the normal actions; it contains no
contribution totals or other personal data and is not published. The supported
hide removed this surface as well. The live helper subsequently returned the
privacy-safe summary `fresh`, four periods and no error.

Final comparison confirmed the installed tree still matches the repository,
the plugin directory inode is still `1215500`, `shell.json` is byte-identical,
CommitPulse is still at `right[1]`, the unrelated plugin catalog is unchanged,
and all backups remain. The final popup count is zero. The complete Quickshell
log beginning with the restarted process contains no CommitPulse
component/import/type/property/binding/path/anchor or Wayland errors. Its unused
`dev.commitpulse` IPC-handler warnings are the expected extra-monitor duplicates
also emitted by stock bar panels on each load; shell routing and the retained
handler both succeeded in the lifecycle above. Task 0 is complete; no redesign
work was started.
