# CommitPulse

A native Quickshell/QML Omarchy widget for your GitHub contribution activity.

See [PRODUCT.md](PRODUCT.md) for the accepted requirements and delivery order.

## Status

Increment 1 is implemented: the repository contains a schemaVersion 1
Omarchy bar-widget manifest, a Qt-free deterministic fixture model, and a
compact themed Quickshell widget with an anchored detail popup under
`quickshell/`. The fictional fixture exposes Today, Week, Month, and Year
contribution totals in that order; the popup shows all four totals and the bar
shows today's concise summary. Run `npm test` to validate the manifest,
fixture model, and QML host-contract coverage.

GitHub access, the compiled Go helper, live refresh and cache behavior, an
isolated runtime smoke command, and installer integration remain planned work.
No personal contribution data, credentials, or runtime state is included in
this repository.

## Goal

See your GitHub contribution counts at a glance while working in Omarchy.

## Planned later increments

- Fetch GitHub contributions through a compiled Go helper using `gh` auth.
- Add asynchronous refresh, stale/offline handling, and XDG cache storage.
- Provide a profile action, isolated runtime smoke workflow, and idempotent
  installer and uninstaller.

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
