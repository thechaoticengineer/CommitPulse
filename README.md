# CommitPulse

A native Quickshell/QML Omarchy widget for your GitHub contribution activity.

See [PRODUCT.md](PRODUCT.md) for the accepted requirements and delivery order.

## Status

Increments 1, 2, and 3 are implemented. The repository contains a
schema-version 1 Omarchy bar-widget
manifest, a deterministic fictional model, and a themed Quickshell widget with
an anchored detail popup. Its long-lived widget owns one shared asynchronous
data controller and injects it into the popup; neither surface starts a second
helper.

The compiled Go helper under `cmd/commitpulse-data` implements aggregation,
authenticated GitHub GraphQL fetching through `gh`, secure XDG caching, stale
fallback, structured errors, retry suppression, and deterministic contract
validation. It emits exactly Today, Week, Month, and Year in that order. A
failed fetch either preserves the last successful totals as `stale` or emits
`unavailable` without totals; failures never masquerade as four zeroes.

The controller discovers the repository build at `bin/commitpulse-data`
relative to the QML plugin, then launches it directly through Quickshell's
asynchronous `Process` API without a shell or `PATH` fallback. An explicit
`COMMITPULSE_TEST_HELPER` override exists only for isolated integration tests.
This repository-relative production location is provisional until increment 4
defines and validates the installed layout. The controller performs strict
schema-v1 validation, retains the last complete four-period snapshot through
unavailable or invalid results, refreshes every 15 minutes after its startup
refresh, and provides one guarded manual refresh method. Startup, timer, and
manual requests are coalesced so only one helper process can run, and manual
refresh also honors a validated `retryAt`. The compact bar
shows the live Today count when one is available and uses explicit loading or
unavailable text otherwise. The popup shows all four live totals, a
human-readable last-updated indication, and distinct loading, refreshing,
stale, authentication, rate-limit, offline, general-error, and unavailable
presentations. Its Refresh action is disabled while a request is active or a
validated `retryAt` deadline is in the future.

The last-updated text reports the timestamp of the most recent successful fresh
or stale snapshot. The profile action validates and opens only the fixed
`https://github.com/` target through Qt's native URL launcher. GitHub therefore resolves the action
for the browser's authenticated account without CommitPulse querying, logging,
or persisting account identity. The schema-v1 privacy boundary intentionally
contains no login or profile URL, so this increment cannot construct a direct
account-specific URL. Installer/uninstaller work, final installed-helper
discovery, and changes to the live Omarchy setup remain increment 4 work.
Nothing in the current validation flow
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
fixture-mode JSON against the schema-v1 contract, Node unit/integration tests,
QML formatting/parsing, and two isolated QML smoke workflows. The headless
controller smoke stages the compiled Go helper beside the QML plugin, then uses
an explicit executable test override to drive fictional fresh, stale,
unavailable/authentication, and malformed-output attempts. It exercises startup
and manual paths, retained non-zero totals, non-zero exits, and a maximum of one
active process. The visual smoke stages the same complete tree and checks the
actual bar and popup presentations against those scenarios when Quickshell and
an active Wayland socket are available; otherwise it reports an honest runtime
skip after static checks. Both QML smokes use private temporary `HOME` and XDG
trees, remove captured output, and never examine the real plugin directory.
Validation also rejects tracked credentials, cache/runtime artifacts, binaries,
and logs, checks fixture scripts with `bash -n`, and runs `git diff --check`.

`npm run build:helper` writes the helper binary to ignored
`bin/commitpulse-data`, matching the controller's repository/runtime discovery
path. `npm run smoke:controller` runs the headless asynchronous scenario check,
`npm run smoke` runs the fixture-backed isolated visual check,
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

- Increment 4 will add an idempotent installer/uninstaller, establish the final
  installed helper location, enable the plugin without replacing unrelated
  configuration, and validate it in the user's live Omarchy shell.

## Related project

[ReviewBox](https://github.com/thechaoticengineer/ReviewBox) is a planned daily
commit review inbox across your GitHub repositories.

## License

[MIT](LICENSE) © 2026 thechaoticengineer.
