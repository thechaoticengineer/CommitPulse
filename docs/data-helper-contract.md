# CommitPulse data-helper contract (schema version 1)

`cmd/commitpulse-data` is the repository-owned Go command that will supply
contribution data to the QML layer. This increment establishes its stable JSON
contract and pure calendar aggregation only. It does not call GitHub, cache
data, schedule refreshes, or connect QML to live output yet.

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
| `retryAt` | Optional earliest safe retry time, to be added with rate-limit/backoff handling. |
| `visibility` | Private contribution visibility knowledge; schema version 1 currently emits `unknown`. |
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

For a selected timezone, the helper constructs all boundaries at local
midnight:

- Today is the local date containing the supplied clock instant.
- Week starts on Monday and includes Today. An early-January week can therefore
  start in December of the prior calendar year.
- Month starts on day 1, and Year starts on January 1.
- The later GraphQL range starts at the earliest of Week, Month, and Year. Its
  end is the final nanosecond of the selected local Today, so it is inclusive
  and stays correct when a local day is 23 or 25 hours because of DST.

Every date label from query start through Today must occur exactly once. Missing,
duplicate, malformed, negative-count, or out-of-range records yield the
machine-readable `malformed_data` error instead of fabricated totals. This
includes February 29 only in leap years.

## Deterministic inputs

`internal/contributions/testdata/fictional-calendar-2096.json` is explicitly
fictional, uses no usernames or credentials, and is only a deterministic unit
test input. It contains no fetched account data or real-account timestamps.
