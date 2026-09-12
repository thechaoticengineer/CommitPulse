// Package contributions defines the stable data contract and pure calendar
// aggregation used by the CommitPulse data helper.
package contributions

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"time"
)

const dateLayout = "2006-01-02"

// PeriodName identifies one of the four display periods. Their order is part
// of the JSON contract.
type PeriodName string

const (
	PeriodToday PeriodName = "today"
	PeriodWeek  PeriodName = "week"
	PeriodMonth PeriodName = "month"
	PeriodYear  PeriodName = "year"
)

// CalendarDay is the minimal, date-only part of GitHub's
// ContributionCalendarDay needed for aggregation. Date must be YYYY-MM-DD and
// ContributionCount must be a non-negative integer.
type CalendarDay struct {
	Date              string `json:"date"`
	ContributionCount int64  `json:"contributionCount"`
}

// DecodeCalendarDays accepts the minimal JSON array used by deterministic
// fixtures and later by the fetch adapter. It deliberately returns a sanitized
// structured error for a non-integer or otherwise malformed count.
func DecodeCalendarDays(input []byte) ([]CalendarDay, error) {
	decoder := json.NewDecoder(bytes.NewReader(input))
	var days []CalendarDay
	if err := decoder.Decode(&days); err != nil {
		return nil, malformed("calendar day input is invalid")
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return nil, malformed("calendar day input is invalid")
	}
	return days, nil
}

// Period is a single aggregate total. A successful envelope always contains
// precisely the four periods in the declared PeriodName order.
type Period struct {
	Name  PeriodName `json:"name"`
	Total int64      `json:"total"`
}

// CalendarBounds describes the selected local calendar range and the
// inclusive DateTime values later supplied to GitHub's contributions query.
// The Date fields are only used as GitHub's authoritative date labels; they
// are not converted through UTC.
type CalendarBounds struct {
	EffectiveTimezone string
	Today             time.Time
	WeekStart         time.Time
	MonthStart        time.Time
	YearStart         time.Time
	QueryStart        time.Time
	QueryEnd          time.Time
}

// Aggregation contains validated period totals and the bounds used to derive
// them. It has no I/O and is safe to use in deterministic tests.
type Aggregation struct {
	Bounds  CalendarBounds
	Periods []Period
}

// ValidationError is safe to place in the JSON contract: its fields never
// include input values, account data, or raw API responses.
type ValidationError struct {
	Kind    ErrorKind
	Message string
}

func (e *ValidationError) Error() string {
	return string(e.Kind) + ": " + e.Message
}

// ResolveLocation chooses an explicitly requested IANA timezone. An empty
// name uses Go's host-local location and reports its effective name (usually
// "Local" when the host zone has no portable IANA identifier available).
func ResolveLocation(name string) (*time.Location, string, error) {
	if name == "" {
		return time.Local, time.Local.String(), nil
	}

	location, err := time.LoadLocation(name)
	if err != nil {
		return nil, "", &ValidationError{
			Kind:    ErrorKindInvalidTimezone,
			Message: "the requested timezone is not a valid IANA location",
		}
	}
	return location, location.String(), nil
}

// BoundsFor returns local-midnight boundaries for now. QueryEnd is the final
// nanosecond of today in the selected zone, making the later GraphQL interval
// explicitly inclusive even across daylight-saving changes.
func BoundsFor(now time.Time, timezone string) (CalendarBounds, error) {
	location, effectiveTimezone, err := ResolveLocation(timezone)
	if err != nil {
		return CalendarBounds{}, err
	}

	localNow := now.In(location)
	today := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), 0, 0, 0, 0, location)
	weekdayOffset := (int(today.Weekday()) + 6) % 7 // Monday is zero.
	weekStart := today.AddDate(0, 0, -weekdayOffset)
	monthStart := time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, location)
	yearStart := time.Date(today.Year(), time.January, 1, 0, 0, 0, 0, location)
	queryStart := earliest(weekStart, monthStart, yearStart)
	queryEnd := today.AddDate(0, 0, 1).Add(-time.Nanosecond)

	return CalendarBounds{
		EffectiveTimezone: effectiveTimezone,
		Today:             today,
		WeekStart:         weekStart,
		MonthStart:        monthStart,
		YearStart:         yearStart,
		QueryStart:        queryStart,
		QueryEnd:          queryEnd,
	}, nil
}

// Aggregate validates a complete GitHub contribution-calendar range and sums
// it into Today, Monday-based Week, calendar Month, and calendar Year. GitHub
// Date labels are compared as local calendar dates, never interpreted as UTC
// instants. Missing, duplicate, malformed, negative, or out-of-range records
// return a structured error instead of creating misleading zero totals.
func Aggregate(now time.Time, timezone string, days []CalendarDay) (Aggregation, error) {
	bounds, err := BoundsFor(now, timezone)
	if err != nil {
		return Aggregation{}, err
	}

	counts := make(map[string]int64, len(days))
	for _, day := range days {
		parsed, err := parseDateLabel(day.Date, bounds.Today.Location())
		if err != nil {
			return Aggregation{}, malformed("a calendar day has an invalid date label")
		}
		if parsed.Before(bounds.QueryStart) || parsed.After(bounds.Today) {
			return Aggregation{}, malformed("a calendar day is outside the required date range")
		}
		if day.ContributionCount < 0 {
			return Aggregation{}, malformed("a calendar day has an invalid contribution count")
		}
		if _, duplicate := counts[day.Date]; duplicate {
			return Aggregation{}, malformed("the calendar has duplicate date labels")
		}
		counts[day.Date] = day.ContributionCount
	}

	var today, week, month, year int64
	for date := bounds.QueryStart; !date.After(bounds.Today); date = date.AddDate(0, 0, 1) {
		label := date.Format(dateLayout)
		count, found := counts[label]
		if !found {
			return Aggregation{}, malformed("the calendar does not cover the required date range")
		}

		if !date.Before(bounds.YearStart) {
			if count > math.MaxInt64-year {
				return Aggregation{}, malformed("the calendar contribution total is too large")
			}
			year += count
		}
		if !date.Before(bounds.MonthStart) {
			if count > math.MaxInt64-month {
				return Aggregation{}, malformed("the calendar contribution total is too large")
			}
			month += count
		}
		if !date.Before(bounds.WeekStart) {
			if count > math.MaxInt64-week {
				return Aggregation{}, malformed("the calendar contribution total is too large")
			}
			week += count
		}
		if date.Equal(bounds.Today) {
			today = count
		}
	}

	return Aggregation{
		Bounds: bounds,
		Periods: []Period{
			{Name: PeriodToday, Total: today},
			{Name: PeriodWeek, Total: week},
			{Name: PeriodMonth, Total: month},
			{Name: PeriodYear, Total: year},
		},
	}, nil
}

func parseDateLabel(label string, location *time.Location) (time.Time, error) {
	if len(label) != len(dateLayout) {
		return time.Time{}, errors.New("wrong date-label length")
	}
	parsed, err := time.ParseInLocation(dateLayout, label, location)
	if err != nil || parsed.Format(dateLayout) != label {
		return time.Time{}, fmt.Errorf("invalid date label: %w", err)
	}
	return parsed, nil
}

func malformed(message string) *ValidationError {
	return &ValidationError{Kind: ErrorKindMalformedData, Message: message}
}

func earliest(values ...time.Time) time.Time {
	earliest := values[0]
	for _, value := range values[1:] {
		if value.Before(earliest) {
			earliest = value
		}
	}
	return earliest
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("unexpected trailing JSON value")
	}
	return err
}
