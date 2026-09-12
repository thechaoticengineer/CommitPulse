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
