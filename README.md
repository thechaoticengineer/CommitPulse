# CommitPulse

A native Quickshell/QML Omarchy widget for your GitHub contribution activity.

See [PRODUCT.md](PRODUCT.md) for the accepted requirements and delivery order.

## Status

Increments 1 and 2, plus the live-integration controller stage of increment 3,
are implemented. The repository contains a schema-version 1
Omarchy bar-widget manifest, a deterministic fictional model, and a themed
Quickshell widget with an anchored detail popup. The UI still displays only the
fictional fixture pending the next stage, but its long-lived widget now owns one
shared asynchronous data controller and injects it into the popup.

The compiled Go helper under `cmd/commitpulse-data` implements aggregation,
authenticated GitHub GraphQL fetching through `gh`, secure XDG caching, stale
fallback, structured errors, retry suppression, and deterministic contract
validation. It emits exactly Today, Week, Month, and Year in that order. A
failed fetch either preserves the last successful totals as `stale` or emits
`unavailable` without totals; failures never masquerade as four zeroes.

The controller launches that helper directly through Quickshell's asynchronous
`Process` API, performs strict schema-v1 validation, retains the last complete
four-period snapshot through unavailable or invalid results, refreshes every
15 minutes, and provides one guarded manual refresh method. It exposes
freshness, sanitized error categories, timestamps, retry metadata, visibility,
and observable process-state counters for the next UI-wiring stage. The popup's
live state presentation and actions, installer/uninstaller, and changes to the
live Omarchy setup remain later work. Nothing in the current validation flow
installs or enables the plugin, reads live plugin configuration, or edits
`/usr/share/omarchy`.

## Dependencies

- Linux/Omarchy for the helper's bounded advisory cache lock.
- Go 1.27 or newer and Node.js 18 or newer for build and validation.
- GitHub CLI (`gh`) authenticated as the desired viewer for live data. The
  helper delegates authentication to `gh`; it never accepts, obtains, prints,
  or persists a token.
- Qt 6 `qmlformat` and Quickshell for controller/runtime checks. An active
  Wayland socket is optional for the isolated visual smoke portion.

## Build and validation

Run the complete local validation workflow with:

```sh
npm run validate
```

That one command checks `gofmt`, `go vet`, all Go tests, Go race tests on
supported Linux targets, a reproducible temporary helper build, deterministic
fixture-mode JSON against the schema-v1 contract, the existing Node tests, and
two isolated QML smoke workflows. The headless controller smoke always runs the
compiled helper's deterministic `-fixture` path twice and asserts that no more
than one process is active; the visual smoke reports an honest runtime skip when
no Wayland socket is available. Validation also rejects tracked cache/runtime
artifacts and runs `git diff --check`.

`npm run build:helper` writes the reproducible helper binary to ignored
`bin/commitpulse-data`. `npm run smoke:controller` runs the headless asynchronous
controller check, `npm run smoke` runs the fixture-backed isolated visual check,
and `npm run demo` leaves that isolated preview open until closed. None of these
commands installs the plugin or touches live Omarchy configuration.

`npm run smoke:live` is the opt-in, read-only authenticated smoke test. It
preflights `gh`, builds into a temporary directory, uses a disposable
`XDG_CACHE_HOME`, permits exactly one GraphQL attempt, validates only output
schema/state/invariants, and deletes all captured data. Its only visible result
is PASS, SKIP, or FAIL; authentication, rate-limit, API, or network
unavailability is a SKIP. It never prints the viewer login, contribution
values, raw API response, cache contents, or subprocess diagnostics.

## Helper usage and JSON contract

Run `go run ./cmd/commitpulse-data`, optionally with `-timezone
Europe/Warsaw`. `-max-attempts 1` lowers the normal request budget for bounded
callers such as the live smoke; it cannot raise the hard limit of three.
`-fixture` emits a fixed fictional fresh envelope without invoking `gh` or
touching the cache. A normal failed invocation still writes its valid `stale` or
`unavailable` JSON envelope, then exits non-zero.

The versioned stdout object contains `schemaVersion`, `state`,
`effectiveTimezone`, ordered `periods` when data exists, `attemptedAt`,
`lastUpdated`, optional `retryAt`, restricted-contribution `visibility`, and an
optional sanitized `error`. Error kinds cover missing `gh`, authentication,
offline, timeout, rate limit, API/GraphQL failure, malformed response, invalid
timezone, and internal failure. See the complete [data-helper
contract](docs/data-helper-contract.md).

The cache lives at `$XDG_CACHE_HOME/commitpulse`, or the platform user-cache
directory plus `commitpulse` when `XDG_CACHE_HOME` is unset. Its directory is
mode `0700`; the bounded success, retry, and lock files are mode `0600`.
Successful records are atomically replaced and never followed through
symlinks. A two-second bounded lock prevents overlapping authenticated fetches.
Rate-limit retry state is separate from successful totals, so later processes
honor `retryAt` even before the first success.

Each `gh api graphql` process has a 15-second deadline and bounded output. A
normal invocation makes at most three attempts, waiting 250 ms and then 500 ms
only after recognized transient network, timeout, or service failures.
Authentication, malformed responses, GraphQL errors, and rate limits are not
retried within the invocation. Rate limits persist a retry time capped to one
hour, with a one-minute fallback when GitHub supplies no usable reset time.

## Calendar and GitHub API semantics

GitHub's `ContributionCalendarDay.date` values are authoritative date-only
calendar labels. CommitPulse does not convert those labels through UTC.
Today, Month, and Year use the effective host-local timezone or the explicitly
selected IANA timezone. Week starts Monday and may include days from the
preceding year. Leap days and 23/25-hour daylight-saving days are covered by
constructing boundaries at local midnight.

The GraphQL `from` value is the earliest needed local boundary and `to` is the
end of the effective local day. Both are timezone-aware instants. GitHub defines
`from` as inclusive and `to` as inclusive; CommitPulse keeps the interval below
one year while allowing every date label in a leap year.

These are GitHub contributions, not commits alone: the collection includes
issues, commits, and pull requests. Private/internal contributions require the
optional `read:user` scope and remain subject to the authenticated user's
private-contribution visibility setting. The helper exposes only whether
restricted contributions were observed, not the viewer identity.

Official references: [GitHub GraphQL user and contribution
schema](https://docs.github.com/en/graphql/reference/users#object-contributioncalendarday),
[`gh api` GraphQL usage](https://cli.github.com/manual/gh_api), and [GitHub
GraphQL rate-limit guidance](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api).

## Goal

See your GitHub contribution counts at a glance while working in Omarchy.

## Planned later increments

- Bind the widget and popup to the shared controller, including manual refresh
  controls and visible loading, freshness, timestamp, and error states.
- Add the profile action and idempotent installer/uninstaller, then validate the
  installed plugin in the user's live Omarchy shell.

## Related project

[ReviewBox](https://github.com/thechaoticengineer/ReviewBox) is a planned daily
commit review inbox across your GitHub repositories.

## License

[MIT](LICENSE) © 2026 thechaoticengineer.
