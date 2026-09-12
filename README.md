# CommitPulse

A native Quickshell/QML Omarchy widget for your GitHub contribution activity.

See [PRODUCT.md](PRODUCT.md) for the accepted requirements and delivery order.

## Status

All four planned increments are implemented. The repository contains a
schema-version 1 Omarchy bar-widget manifest, a deterministic fictional model,
a themed Quickshell widget with an anchored detail popup, and user-local
installer/uninstaller entry points. Its long-lived widget owns one shared
asynchronous data controller and injects it into the popup; neither surface
starts a second helper.

The compiled Go helper under `cmd/commitpulse-data` implements aggregation,
authenticated GitHub GraphQL fetching through `gh`, secure XDG caching, stale
fallback, structured errors, retry suppression, and deterministic contract
validation. It emits exactly Today, Week, Month, and Year in that order. A
failed fetch either preserves the last successful totals as `stale` or emits
`unavailable` without totals; failures never masquerade as four zeroes.

The controller discovers `../bin/commitpulse-data` relative to its QML file,
which resolves to the compiled helper in both the repository build and the
installed plugin. It launches the helper directly through Quickshell's
asynchronous `Process` API without a shell or `PATH` fallback. An explicit
`COMMITPULSE_TEST_HELPER` override exists only for isolated integration tests.
The controller performs strict schema-v1 validation, retains the last complete
four-period snapshot through unavailable or invalid results, refreshes every 15
minutes after its startup refresh, and provides one guarded manual refresh
method. Startup, timer, and manual requests are coalesced so only one helper
process can run, and manual refresh also honors a validated `retryAt`. The compact bar
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
contains no login or profile URL, so the widget cannot construct a direct
account-specific URL. Repository validation uses only temporary HOME/XDG roots;
live installation happens only when `./install.sh` is invoked. No lifecycle
operation edits `/usr/share/omarchy`.

## Dependencies

- A current Omarchy installation with its Quickshell-based shell and `omarchy`
  CLI. Installation and removal use the running shell's plugin IPC API.
- Go 1.27 or newer to compile the installed data helper. The installer builds
  it locally with `-trimpath`; no generated binary is stored in Git.
- `jq`, plus the standard `realpath`, `find`, and `mktemp` commands used by the
  lifecycle scripts.
- GitHub CLI (`gh`) authenticated as the viewer whose contribution calendar
  should be shown. Run `gh auth login` if needed. The helper delegates
  authentication to `gh`; it never accepts, obtains, prints, or persists a
  token.
- Node.js 18 or newer and Qt 6 `qmlformat` for repository validation. An active
  Wayland/Quickshell session is needed for visual runtime checks; static checks
  still run without one.

## Install, upgrade, and remove

From a checked-out CommitPulse repository, validate first and then install:

```sh
npm run validate
./install.sh
```

The installer builds and validates a complete staged plugin before changing
user state, installs it at `~/.config/omarchy/plugins/dev.commitpulse`, calls
`omarchy shell shell rescanPlugins`, and enables `dev.commitpulse` exactly once
in the right bar section. It preserves the order and values of all unrelated
bar entries, plugin settings, idle settings, and unknown `shell.json` fields.
Running the same command again performs an idempotent reinstall or upgrade:

```sh
./install.sh
```

The installed tree is self-contained:

```text
~/.config/omarchy/plugins/dev.commitpulse/
├── manifest.json
├── LICENSE
├── bin/commitpulse-data
└── quickshell/
    ├── BarWidget.qml
    ├── ContributionFixture.js
    ├── ContributionState.js
    ├── DataController.qml
    └── Panel.qml
```

Before a lifecycle operation changes an existing `shell.json`, it copies the
file to `~/.config/omarchy/shell.json.commitpulse-backup.<UTC timestamp>`.
Replacement and removal move the previous plugin tree to a collision-safe
`~/.config/omarchy/plugins/.dev.commitpulse.backup.<UTC timestamp>` path.
Backups are retained for manual recovery and are never silently pruned. If an
activation or verification step fails, the script restores the pre-operation
plugin and shell configuration and rescans the shell.

The installer performs the required rescan, so no separate reload normally is
needed. To rescan after an unusual shell/session interruption, run:

```sh
omarchy shell shell rescanPlugins
```

If the running shell itself must be restarted, use `omarchy restart shell`,
then rerun `./install.sh` so its post-install checks complete. To inspect the
installed plugin without exposing contribution data, use:

```sh
omarchy plugin validate "$HOME/.config/omarchy/plugins/dev.commitpulse"
omarchy plugin list --json
```

To remove CommitPulse, including its owned bar/plugin references, run:

```sh
./uninstall.sh
```

Removal preserves unrelated configuration and moves the installed plugin to a
backup rather than deleting it. Repeated install and uninstall commands are
safe and non-interactive.

## Refresh and runtime states

CommitPulse fetches once after the widget starts and automatically every 15
minutes. The popup's **Refresh** action requests the same asynchronous helper;
it is disabled while a fetch is active and until any validated GitHub
rate-limit `retryAt` deadline passes, so requests cannot overlap.

A successful response is shown as fresh. If a later authentication, network,
rate-limit, API, or data error occurs, the last complete cached totals remain
visible and are marked stale. If no valid cache exists, the widget shows an
explicit unavailable/error state with no totals; failure is never displayed as
four zeroes. `npm run smoke:live` performs an optional privacy-safe authenticated
check with a disposable cache and reports only PASS, SKIP, or FAIL.

## Build and validation

Run the complete local validation workflow with:

```sh
npm run validate
```

That one command checks `gofmt`, `go vet`, all Go tests, Go race tests on
supported Linux targets, a reproducible temporary helper build, deterministic
fixture-mode JSON against the schema-v1 contract, Node unit/integration tests,
QML formatting/parsing, two isolated QML smoke workflows, and the complete
installer/uninstaller lifecycle in a disposable HOME. The lifecycle suite
covers install, upgrade, repeat install, removal, repeat removal, backups,
rollback, malformed configuration, paths containing spaces, exact preservation
of unrelated shell settings, plugin validation, and executable fixture output.
The controller-only runtime smoke stages the compiled Go helper beside the QML plugin, then uses
an explicit executable test override to drive fictional fresh, stale,
unavailable/authentication, and malformed-output attempts. It exercises startup
and manual paths, retained non-zero totals, non-zero exits, and a maximum of one
active process. The visual smoke stages the same complete tree and checks the
actual bar and popup presentations against those scenarios when Quickshell and
an active Wayland socket are available. Both runtime smokes report an honest
skip when that display backend is unavailable; the visual workflow still runs
its static checks first. Both QML smokes use private temporary `HOME` and XDG
trees, remove captured output, and never examine the real plugin directory.
Validation also rejects tracked credentials, cache/runtime artifacts, binaries,
and logs, checks fixture scripts with `bash -n`, and runs `git diff --check`.

`npm run build:helper` writes the helper binary to ignored
`bin/commitpulse-data`, matching the controller's repository/runtime discovery
path. `npm run smoke:controller` runs the controller-only asynchronous scenario check,
`npm run smoke` runs the fixture-backed isolated visual check,
and `npm run demo` leaves that isolated preview open until closed. None of these
commands installs the plugin or touches live Omarchy configuration; only the
explicit lifecycle scripts do so.

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
directory plus `commitpulse` when `XDG_CACHE_HOME` is unset (normally
`~/.cache/commitpulse` on Omarchy). Its directory is mode `0700`; the bounded
success, retry, and lock files are mode `0600`.
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
optional `read:user` scope (`gh auth refresh -s read:user`) and remain subject
to the authenticated user's private-contribution visibility setting. Without
that scope or visibility setting, those private/internal counts are not
included. The helper exposes only whether restricted contributions were
observed, not the viewer identity.

Credentials, tokens, GitHub API responses, fetched personal counts, caches,
generated binaries, and logs are excluded from the repository. Runtime cache
files stay in the user's XDG cache directory and should not be copied into Git.

Official references: [GitHub GraphQL user and contribution
schema](https://docs.github.com/en/graphql/reference/users#object-contributioncalendarday),
[`gh api` GraphQL usage](https://cli.github.com/manual/gh_api), and [GitHub
GraphQL rate-limit guidance](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api).

## Goal

See your GitHub contribution counts at a glance while working in Omarchy.

## Related project

[ReviewBox](https://github.com/thechaoticengineer/ReviewBox) is a planned daily
commit review inbox across your GitHub repositories.

## License

[MIT](LICENSE) © 2026 thechaoticengineer.
