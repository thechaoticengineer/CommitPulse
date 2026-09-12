# CommitPulse

A native Quickshell/QML Omarchy widget for your GitHub contribution activity.

See [PRODUCT.md](PRODUCT.md) for the accepted requirements and delivery order.

## Status

Increment 1 is implemented: the repository contains a schemaVersion 1
Omarchy bar-widget manifest, a Qt-free deterministic fixture model, and a
compact themed Quickshell widget with an anchored detail popup under
`quickshell/`. The fictional fixture exposes Today, Week, Month, and Year
contribution totals in that order; the popup shows all four totals and the bar
shows today's concise summary. Fixture values are fictional, deterministic,
and contain no personal contribution data.

Run `npm run smoke` to validate the manifest and fixture model, parse the QML,
and run a bounded repository-local Quickshell demo. It uses a temporary HOME
and XDG config/cache/state/data tree, stages only the repository QML, and links
its imports directly to the installed read-only Omarchy shell APIs. It neither
installs nor enables the plugin, and it never reads or changes your live
`~/.config/omarchy` configuration or plugin directory. On an active Wayland
session, the command confirms that the demo root, `BarWidget.qml`, and its
fixture popup load before Quickshell exits cleanly. A Wayland socket is required
for that runtime portion; without one, the command reports the runtime check as
skipped and completes only its deterministic static checks. Use `npm run demo`
for the same isolated preview without the bounded exit, then close it or press
Ctrl-C when finished.

Increment 2, stages 1–3 are implemented: `cmd/commitpulse-data` and its
standard-library Go module define schema version 1 of the data-helper JSON
contract, fetch the authenticated viewer's contribution calendar through one
minimal read-only `gh api graphql` query, and strictly aggregate GitHub calendar
day labels into Today, Week, Month, and Year totals. The helper uses `gh`'s
existing authentication and never accepts or prints a token. It defaults to the
host-local timezone or accepts an explicit IANA timezone, uses Monday-based
weeks, handles year-crossing weeks, leap days, and DST-aware inclusive query
bounds, and rejects incomplete or malformed responses rather than inventing
zero totals.

The helper serializes invocations with a bounded Linux advisory lock and stores
its last validated success under `$XDG_CACHE_HOME/commitpulse`, falling back to
the standard user-cache directory when `XDG_CACHE_HOME` is unset. Cache files
are bounded, versioned, private, symlink-safe, and atomically replaced. When a
fetch fails, a valid prior success is emitted unchanged as `stale` with the
current sanitized error and its original `lastUpdated`; without one, the helper
emits `unavailable` with no totals. Rate-limit metadata is stored separately and
prevents later helper processes from contacting GitHub before `retryAt`.

Install and authenticate the GitHub CLI, then run `go run
./cmd/commitpulse-data` (optionally with `-timezone Europe/Warsaw`). A failure
produces `stale` totals when a valid cache exists; otherwise it produces a
structured `unavailable` envelope with a stable, sanitized error and no totals.
Requests have strict process deadlines, output caps, and a maximum of three
attempts; only transient network, timeout, and service failures back off.
Rate-limit responses carry a bounded `retryAt` without an immediate retry loop,
and that suppression survives later invocations. Private/internal contribution
inclusion requires the optional `read:user` scope and GitHub's
private-contribution visibility setting; the output reports only whether
restricted contributions were observed, never the login. See [the helper
contract](docs/data-helper-contract.md) and run `go test ./...` for deterministic
tests that do not require a network or real authentication.

Live QML refresh and installation remain planned work. No credentials, fetched
contribution data, cache contents, or other runtime state is included in this
repository.

## Goal

See your GitHub contribution counts at a glance while working in Omarchy.

## Planned later increments

- Connect the QML widget to the helper with asynchronous refresh controls.
- Provide a profile action and idempotent installer and uninstaller.

## Decisions for implementation

- Refine placement within the installed Omarchy Quickshell bar.
- Preserve the agreed GitHub contributions metric and explain its API semantics.
- Align timezone behavior with API dates; weeks start on Monday.
- Choose authentication, refresh frequency, and local caching.
- Define how private contribution counts should be represented.

## Related project

[ReviewBox](https://github.com/thechaoticengineer/ReviewBox) is a planned daily
commit review inbox across your GitHub repositories.

## License

[MIT](LICENSE) © 2026 thechaoticengineer.
