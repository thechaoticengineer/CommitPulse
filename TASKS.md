# CommitPulse — contribution statistics panel

Status: **task 0 — repair panel opening — was manually accepted by the user and
closed at their request**. Redesign tasks 1–5 remain deferred and are not authorized
to run. The user is working on ReviewBox separately; do not interfere with it.

## Direction

The visual reference is the Omarchy Codex usage panel provided by the user: a dark
background, monospace typography, a clear header, separated sections, aligned
numbers, and horizontal bars. Adapt this presentation to GitHub contributions.
Keep **Quickshell/QML + Go**, and use only Codex for every Forge role.

Proposed layout: CommitPulse header → Today / Week / Month / Year summary → activity
for the last 7 days → monthly activity for the current year → a discreet update
time and actions. The bar counter remains the entry point to the full panel;
the tooltip provides only a brief hint.

## 0. Repair opening of the existing panel

The user confirmed that the installed panel works and requested publication and
closure. Automated review remained blocked: the compositor regression test was
unreliable, and the final attempt was interrupted by a Codex service outage.
User acceptance does not mean these checks passed. See the
[repair report](docs/panel-opening-repair.md) for evidence and remaining limitations.

The original report was that clicking the counter opened no panel, with only the
tooltip visible. This was independent of the requested redesign. The cause was
loss of the watched plugin directory during updates and a poisoned component URL
in the long-running shell process. The fix preserves the directory inode,
switches the manifest last, and uses new component URLs.

- [x] Reproduce clicking the actual installed widget in Omarchy. Compare installed
  files with the repository before changing code.
- [x] Trace click handling in BarWidget.qml, togglePanel(), panelLoader, Panel.qml
  initialization, visibility control, and anchoring. Check the panel/IPC contract
  in the installed Omarchy version.
- [x] Inspect Quickshell/QML errors at click time: loading failures, missing
  properties/imports, invisible windows, or incorrect placement. Read bounded
  log excerpts and establish the cause from evidence.
- [x] Fix the confirmed cause and add a targeted regression test. A Go helper test,
  valid manifest, or visible tooltip alone does not verify panel opening.
- [x] Verify actual opening, closing, and reopening from the bar, including without
  GitHub data. Record the cause and repair evidence.

**Acceptance:** clicking the widget displays the panel in Omarchy; closing and
reopening work. The user authorized the fix and necessary update of the installed
CommitPulse plugin. Do not restart Forge, reset Omarchy configuration, or start
the redesign as part of this task.

## 1. Panel layout and styling with demo data

Dependency: task 0 — panel opening must work first.

- [ ] Inspect the existing Codex usage panel implementation in installed Omarchy
  as the reference for spacing, width, typography, and separators.
- [ ] Build the complete QML panel with a header, four counters, chart sections,
  and footer. Use the Omarchy theme instead of a hard-coded palette.
- [ ] Match the reference width (approximately 360–400 logical pixels), constrained
  by the available screen, with scrolling when height is limited.
- [ ] Use fictional data only in demo mode. Prepare a preview/screenshot for visual
  assessment without changing the installed widget.

**Acceptance:** the preview resembles the reference statistics panel; values,
labels, and sections are readable, including on a smaller screen. Never present
demo data as real activity.

## 2. Daily and monthly series in the Go helper

Dependency: the layout from task 1 defines the required data ranges.

- [ ] Extend calendar calculations with the last 7 days, including today, and the
  current year's months through the current month.
- [ ] Reuse the fetched GitHub calendar; include the preceding year when the
  seven-day range crosses January 1. Avoid separate requests per section.
- [ ] Define the date, value, and completeness contract. Missing data is not zero;
  the current day and month are periods still in progress.
- [ ] Plan a compatible helper → QML and cache contract change. The current
  ContributionState.js rejects additional fields and versions other than
  schemaVersion=1; adding fields only in Go would break the existing widget.
  Support the previous version or provide a controlled transition that retains
  the last successful totals.
- [ ] Check year/month boundaries, leap years, zero-activity days, missing data,
  sample ordering, and consistency between monthly aggregates and the year total.

**Acceptance:** the helper provides deterministic series alongside the four
existing totals, preserving compatibility with the working interface.

## 3. Charts using real data

Dependencies: tasks 1 and 2.

- [ ] Connect the panel to the existing shared DataController. Opening the panel
  must not create a second helper or an additional refresh cycle.
- [ ] Show the last 7 days as rows containing a day/date, horizontal bar, and count.
  Highlight today similarly to the reference's “Today” row.
- [ ] Show the current year's months in a matching section and indicate that the
  current month is still in progress. Do not display future months as zeroes.
- [ ] Scale bars relative to the largest value within their section. Keep exact
  counts, handle all-zero data, and explain the scale. Do not invent quotas,
  completion percentages, or activity targets.
- [ ] Preserve automatic refresh every 15 minutes, manual refresh, and overlapping
  request prevention. Keep private data out of public fixtures and logs.

**Acceptance:** the four totals and both charts represent the same real data
snapshot. Demo mode still works without GitHub or storing user data.

## 4. Panel interaction and error states

Dependency: task 3.

- [ ] Check opening by clicking the counter, closing with Escape/outside click,
  bar anchoring, and preventing off-screen placement.
- [ ] Preserve keyboard access to actions, visible focus, and content scrolling.
- [ ] Unify loading, refreshing, stale, offline, authentication, and rate-limit
  states. Retain the last successful totals and series; show a short status and
  data timestamp.
- [ ] For older caches without series, show available counters and an explicit
  unavailable chart state. Do not replace errors with demo bars or zeroes.
- [ ] Check large numbers, all-zero data, longer labels, and display scaling.

**Acceptance:** the basic workflow works with mouse and keyboard, the panel stays
readable during errors, and refresh respects retryAt and concurrent-request limits.

## 5. Verification and update preparation

Dependencies: tasks 1–4.

- [ ] Run required Go, contract, QML, and controller checks, including new series,
  older cache compatibility, and error states.
- [ ] Check the complete panel with fictional data at normal and constrained
  sizes; prepare a final demo screenshot for comparison with the reference.
- [ ] Check installation, upgrade, and removal in an isolated configuration,
  retaining existing safeguards and backups.
- [ ] Update README with appearance, date ranges, bar scaling, incomplete current
  periods, refreshing, and the command to update an installed version.
- [ ] Prepare the result for review and later installation. Install into live
  Omarchy and publish only according to the user's instructions when work resumes;
  do not start these tasks now.

**Acceptance:** a verified update package and preview are ready for review, and
the documentation describes the implemented panel accurately.

## Later handoff to Forge

After the user's authorization, add the remaining tasks 1–5 in order. Task 0 is
closed and must not be requeued. Before starting after any restart, check project
state and Codex settings for every role; Forge process settings may need to be
reapplied. This list does not authorize restoring the disabled watcher or
automatic recovery jobs.
