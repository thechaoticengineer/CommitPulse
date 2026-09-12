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

GitHub access, the compiled Go helper, live refresh and cache behavior, and
installation remain planned work. No credentials, fetched contribution data, or
runtime state is included in this repository.

## Goal

See your GitHub contribution counts at a glance while working in Omarchy.

## Planned later increments

- Fetch GitHub contributions through a compiled Go helper using `gh` auth.
- Add asynchronous refresh, stale/offline handling, and XDG cache storage.
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
