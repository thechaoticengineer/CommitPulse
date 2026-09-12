# CommitPulse

A small Omarchy widget for your GitHub contribution activity.

## Status

Project initialized. This repository currently contains the project brief and
license; the widget is not implemented yet. Desktop integration and the
technology stack will be chosen during the next development step.

## Goal

See your GitHub contribution counts at a glance while working in Omarchy.

## Planned first version

- Show contributions for today, the current week, month, and year.
- Keep the widget compact and readable on the desktop.
- Refresh automatically and display when the data was last updated.
- Handle an unavailable connection without showing a misleading zero count.
- Open your GitHub profile from the widget.

## Decisions for implementation

- Choose the desktop placement and integration supported by the target Omarchy setup.
- Define the metric precisely: GitHub contributions or commits only.
- Define timezone behavior and the start of the week.
- Choose authentication, refresh frequency, and local caching.
- Define how private contribution counts should be represented.

## Related project

[ReviewBox](https://github.com/thechaoticengineer/ReviewBox) is a planned daily
commit review inbox across your GitHub repositories.

## License

[MIT](LICENSE) © 2026 thechaoticengineer.
