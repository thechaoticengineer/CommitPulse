# CommitPulse data-helper contract (schema version 1)

`cmd/commitpulse-data` is the repository-owned Go command that will supply
contribution data to the QML layer. It now fetches the authenticated viewer's
calendar through the installed GitHub CLI, validates and aggregates the
response, and writes the stable JSON contract below. Cache storage, refresh
scheduling, and QML live-data wiring are later stages.

The helper invokes exactly one read-only `gh api graphql` request when the first
attempt succeeds. It relies on `gh`'s existing authentication, never accepts or
retrieves a token itself, and never prints the viewer login or raw API output.
The query uses typed `DateTime!` `from`/`to` variables and requests only the
viewer login/profile URL (as required response fields), contribution day
date/count values, restricted-contribution visibility metadata, and GraphQL
rate-limit remaining/reset metadata. See the official [`gh api`
manual](https://cli.github.com/manual/gh_api).

The command accepts `-timezone IANA`; an empty value uses the host-local Go
location. The `effectiveTimezone` field reports the selected IANA location, or
`Local` when Go only has the host-local zone rather than a portable IANA name.

## JSON envelope

The helper writes one UTF-8 JSON object followed by a newline. Struct field and
period order are stable. All timestamps use RFC 3339 / RFC 3339 Nano encoding.
Absent optional values are omitted, not written as `null` or misleading zeroes.

```json
{
  "schemaVersion": 1,
  "state": "fresh",
  "effectiveTimezone": "Europe/Warsaw",
  "periods": [
    {"name": "today", "total": 3},
    {"name": "week", "total": 11},
    {"name": "month", "total": 29},
    {"name": "year", "total": 147}
  ],
  "attemptedAt": "2096-02-29T12:00:00Z",
  "lastUpdated": "2096-02-29T12:00:01Z",
  "visibility": {"privateContributions": "unknown"}
}
```

The example values and future dates are fictional documentation data, not a
GitHub response. The schema fields are:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Currently integer `1`; incompatible changes require a new version. |
| `state` | `fresh`, `stale`, or `unavailable`. |
| `effectiveTimezone` | The selected IANA timezone, or host-local `Local`. |
| `periods` | Present only for `fresh` and `stale`; exactly Today, Week, Month, Year in that order, with non-negative integer totals. |
| `attemptedAt` | Time of the most recent fetch attempt; omitted if no attempt happened. |
| `lastUpdated` | Time of the last successful fetch; required for `fresh` and `stale`, absent for `unavailable`. |
| `retryAt` | Optional earliest safe retry time for a rate-limited request. |
| `visibility` | `included` when GitHub reports restricted contributions in the selected range; otherwise `unknown`, because zero cannot distinguish no private activity, disabled private-count sharing, or missing optional scope. |
| `error` | Required for `stale`/`unavailable`, absent for `fresh`; contains a stable `kind` and sanitized fixed `message`. |

An `unavailable` result deliberately has no `periods` or `lastUpdated`. A
failure therefore cannot be mistaken for four genuine zero-contribution totals.
`stale` will carry the complete last successful set of periods together with an
error; it can never carry only a subset.

## Calendar semantics

GitHub documents `ContributionCalendarDay.date` as the day represented by a
calendar square and `contributionCount` as its contribution count. CommitPulse
treats those returned `YYYY-MM-DD` labels as authoritative contribution days;
it does not parse them as UTC timestamps and shift them into another date.
GitHub's `ContributionsCollection` is a collection of contributions, including
issues, commits, and pull requests, so these totals must not be labelled as
commits. [GitHub's GraphQL schema reference](https://docs.github.com/en/graphql/reference/users)
documents both facts and notes that private/internal contributions require the
optional `read:user` scope and remain subject to GitHub visibility settings.
Without that optional scope, private/internal contributions are not included;
even with it, GitHub only includes private counts when the authenticated user
has enabled private-contribution visibility.

For a selected timezone, the helper constructs all boundaries at local
midnight:

- Today is the local date containing the supplied clock instant.
- Week starts on Monday and includes Today. An early-January week can therefore
  start in December of the prior calendar year.
- Month starts on day 1, and Year starts on January 1.
- The later GraphQL range starts at the earliest of Week, Month, and Year. Its
  end is the final nanosecond of the selected local Today, so it is inclusive
  and stays correct when a local day is 23 or 25 hours because of DST.

GitHub defines `from` as inclusive (at that instant or later) and `to` as
inclusive (before and up to that instant). CommitPulse keeps the explicit range
strictly shorter than one calendar year while permitting all 366 labels in a
leap year. A week crossing New Year can begin in the preceding year without
making the request overlong.

Every date label from query start through Today must occur exactly once. Missing,
duplicate, malformed, negative-count, or out-of-range records yield the
machine-readable `malformed_data` error from the pure aggregator instead of
fabricated totals. The command maps malformed API calendar data to
`malformed_response`. This includes February 29 only in leap years.

## Fetch bounds and errors

Each `gh` process has a 15-second deadline, stdout is capped at 512 KiB, stderr
at 32 KiB, and overflow terminates the process. An invocation makes at most
three attempts with 250 ms then 500 ms delays. Only timeouts, recognized network
failures, and HTTP 500/502/503/504 service failures retry. Authentication,
missing CLI, rate-limit, GraphQL, malformed-response, and internal failures do
not retry.

Primary or secondary rate limits return `rate_limit` with a future `retryAt`
derived from valid GraphQL reset/retry metadata, or a conservative one-minute
fallback. The wait is capped at one hour and is represented in JSON rather than
slept or retried in-process. This follows [GitHub's GraphQL rate-limit
guidance](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api).

Stable fetch error kinds are `missing_gh`, `authentication`, `offline`,
`timeout`, `rate_limit`, `api`, `malformed_response`, and `internal`. Every
message is fixed project-owned text. Raw stdout/stderr, GraphQL messages,
command environments, viewer identity, and contribution values are never used
in logs or error text. A top-level GraphQL error fails the entire fetch even if
partial `data` is present. Without a stage-3 cache, any failure emits
`unavailable` with no periods; stale fallback is not implemented yet.

## Deterministic inputs

`internal/contributions/testdata/fictional-calendar-2096.json` is explicitly
fictional, uses no usernames or credentials, and is only a deterministic unit
test input. It contains no fetched account data or real-account timestamps.
