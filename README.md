# CommitPulse

A native Quickshell/QML Omarchy widget for your GitHub contribution activity.

See [PRODUCT.md](PRODUCT.md) for the accepted requirements and delivery order.

## Status

Project initialized. This repository currently contains the project brief and
license; the widget is not implemented yet. It will use the installed Omarchy
shell plugin API with a QML bar widget and detail popup.
The data helper will be written in Go and use the existing gh authentication.

## Goal

See your GitHub contribution counts at a glance while working in Omarchy.

## Planned first version

- Show contributions for today, the current week, month, and year.
- Keep the widget compact and readable on the desktop.
- Refresh automatically and display when the data was last updated.
- Handle an unavailable connection without showing a misleading zero count.
- Open your GitHub profile from the widget.

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
