# CommitPulse product brief

## Agreed direction

Build a native Quickshell/QML plugin for the installed Omarchy shell. The widget
shows GitHub contributions for today, the current week, month and year. Quickshell
is required; integrate with the existing Omarchy plugin and theme APIs.

Read the installed shell under /usr/share/omarchy/shell and the user Omarchy skill
to establish the exact current plugin contract. Packaged files are reference-only.
Useful examples include /usr/share/omarchy/shell/plugins/panels/clock and the
Forge plugin in /home/ithilsen/Projects/Forge/manifest.json and quickshell/.

## First usable version

- A plugin manifest, compact bar widget, and a detail popup showing all four
  clearly labeled totals. Follow shell colors, fonts and sizing.
- Fetch the authenticated user's GitHub contribution calendar through the
  installed gh CLI. Use a small Go helper for API calls, calendar aggregation
  and cache serialization, preferably relying on the Go standard library.
  Distribute it as a compiled binary; the UI must remain Quickshell/QML.
- Count GitHub contributions rather than claiming contributions are commits only.
  Document the API's date semantics and private-contribution visibility. Monday
  starts the week; current month/year start on their calendar boundaries. Handle
  the week crossing a year boundary and leap days correctly.
- Use asynchronous fetching, a reasonable default refresh interval (15 minutes),
  manual refresh, last-updated time, and XDG cache storage. Prevent overlapping
  requests and respect rate-limit responses/backoff.
- Keep the last successful values when offline, visibly marked stale. Never
  represent an API/authentication failure as zero contributions.
- Open the GitHub profile from a clear action. No tokens or fetched personal data
  in the repository, logs, fixtures, or distributable assets.
- Include fixture/demo data and deterministic checks for date aggregation and
  errors, plus a QML/plugin smoke check where the runtime supports it.
- Provide an idempotent installer and uninstaller for the user plugin directory
  ~/.config/omarchy/plugins/. Preserve existing shell configuration and unrelated
  plugins; back up any changed user configuration. Never edit /usr/share/omarchy.
- Install and enable the completed plugin in this user's Omarchy setup after
  validation, and verify loading through the actual shell. Keep installation a
  separate explicit command for other users.

## Visual direction for the next iteration

The user clarified the desired appearance after seeing the initial widget:
use the existing Omarchy Codex usage panel as the visual reference. The desired
experience is a substantial dark statistics panel with clear section headings,
separators, aligned values and horizontal activity bars, using the system's
monospace typography and theme. A small text counter/tooltip alone does not meet
this visual expectation.

Show the day/week/month/year contribution summary prominently. A daily activity
breakdown with horizontal bars would adapt the reference's "tokens by day" layout
to GitHub contributions; this is a proposed layout for the next implementation.
Use real daily data for charts, and label any relative scale honestly rather than
inventing quotas or targets. Keep the compact bar entry as the panel launcher.

This is a recorded design clarification, not an implemented redesign. The user
has taken over further work and asked to stop automatic supervision.

The proposed task list is in [TASKS.md](TASKS.md). The user has authorized running
only task 0 (repair panel opening) through Forge, including the necessary local
plugin update and real opening/closing verification. The visual redesign tasks
remain deferred. Do not restart the disabled watcher or touch ReviewBox.

The reported panel-opening defect is repaired and verified in the installed
Omarchy session. The installer now preserves the watched plugin-directory inode,
activates the manifest last and uses fresh component URLs; the existing popup
opens, closes, reopens and opens during unavailable startup data without relevant
QML errors. The visual redesign remains deferred (tasks 1–5 in TASKS.md).

## Original delivery order

1. Quickshell plugin skeleton with a fixture-backed bar widget and detail popup.
2. GitHub contribution fetching, calendar aggregation, cache and error handling.
3. Live asynchronous UI integration, refresh controls and theme polish.
4. Installer/uninstaller, local integration verification and documentation.

Each queue task must leave a usable increment. Forge owns the implementation,
review gates, focused local commits and push after a successful queue task.
