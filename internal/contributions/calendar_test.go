package contributions

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAggregateFictionalFixture(t *testing.T) {
	t.Parallel()

	input, err := os.ReadFile(filepath.Join("testdata", "fictional-calendar-2096.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Fictional bool          `json:"fictional"`
		Days      []CalendarDay `json:"days"`
	}
	if err := json.Unmarshal(input, &fixture); err != nil {
		t.Fatal(err)
	}
	if !fixture.Fictional {
		t.Fatal("test fixture must be explicitly fictional")
	}

	aggregation, err := Aggregate(time.Date(2096, time.January, 14, 12, 0, 0, 0, time.UTC), "UTC", fixture.Days)
	if err != nil {
		t.Fatal(err)
	}
	assertPeriods(t, aggregation.Periods, []int64{7, 17, 40, 40})
}

func TestAggregateCalendarBoundaries(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		now      time.Time
		timezone string
		count    func(int) int64
		want     []int64
	}{
		{
			name:     "monday starts a new week",
			now:      time.Date(2024, time.January, 1, 12, 0, 0, 0, time.UTC),
			timezone: "UTC",
			count:    constantOne,
			want:     []int64{1, 1, 1, 1},
		},
		{
			name:     "sunday closes a monday based week",
			now:      time.Date(2024, time.January, 7, 12, 0, 0, 0, time.UTC),
			timezone: "UTC",
			count:    sequentialCounts,
			want:     []int64{7, 28, 28, 28},
		},
		{
			name:     "week crosses december into january",
			now:      time.Date(2023, time.January, 1, 12, 0, 0, 0, time.UTC),
			timezone: "UTC",
			count:    sequentialCounts,
			want:     []int64{7, 28, 7, 7},
		},
		{
			name:     "month and year are calendar boundaries",
			now:      time.Date(2024, time.May, 1, 12, 0, 0, 0, time.UTC),
			timezone: "UTC",
			count:    constantOne,
			want:     []int64{1, 3, 1, 122},
		},
		{
			name:     "leap day remains part of february and year",
			now:      time.Date(2024, time.February, 29, 12, 0, 0, 0, time.UTC),
			timezone: "UTC",
			count:    constantOne,
			want:     []int64{1, 4, 29, 60},
		},
		{
			name:     "non leap february does not invent a day",
			now:      time.Date(2023, time.March, 1, 12, 0, 0, 0, time.UTC),
			timezone: "UTC",
			count:    constantOne,
			want:     []int64{1, 3, 1, 60},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			bounds, err := BoundsFor(test.now, test.timezone)
			if err != nil {
				t.Fatal(err)
			}
			aggregation, err := Aggregate(test.now, test.timezone, completeDays(bounds, test.count))
			if err != nil {
				t.Fatal(err)
			}
			assertPeriods(t, aggregation.Periods, test.want)
		})
	}
}

func TestBoundsTimezoneAndDST(t *testing.T) {
	t.Parallel()

	bounds, err := BoundsFor(time.Date(2024, time.March, 10, 12, 0, 0, 0, time.UTC), "America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := bounds.EffectiveTimezone, "America/New_York"; got != want {
		t.Fatalf("effective timezone = %q, want %q", got, want)
	}
	if got, want := bounds.QueryStart.Format(time.RFC3339Nano), "2024-01-01T00:00:00-05:00"; got != want {
		t.Fatalf("query start = %s, want %s", got, want)
	}
	if got, want := bounds.QueryEnd.Format(time.RFC3339Nano), "2024-03-10T23:59:59.999999999-04:00"; got != want {
		t.Fatalf("query end = %s, want %s", got, want)
	}
	if got, want := bounds.QueryEnd.UTC().Format(time.RFC3339Nano), "2024-03-11T03:59:59.999999999Z"; got != want {
		t.Fatalf("query end in UTC = %s, want %s", got, want)
	}

	if _, _, err := ResolveLocation("Mars/Olympus_Mons"); err == nil {
		t.Fatal("invalid IANA timezone was accepted")
	} else {
		assertValidationKind(t, err, ErrorKindInvalidTimezone)
	}
}

func TestResolveLocationDefaultsToHostLocal(t *testing.T) {
	t.Parallel()

	location, effectiveTimezone, err := ResolveLocation("")
	if err != nil {
		t.Fatal(err)
	}
	if location != time.Local {
		t.Fatalf("default location = %q, want host local %q", location, time.Local)
	}
	if effectiveTimezone != time.Local.String() {
		t.Fatalf("effective timezone = %q, want %q", effectiveTimezone, time.Local.String())
	}
}

func TestAggregateRejectsInvalidOrIncompleteCalendar(t *testing.T) {
	t.Parallel()

	now := time.Date(2024, time.January, 3, 12, 0, 0, 0, time.UTC)
	bounds, err := BoundsFor(now, "UTC")
	if err != nil {
		t.Fatal(err)
	}
	valid := completeDays(bounds, func(int) int64 { return 1 })
	tests := []struct {
		name string
		days []CalendarDay
	}{
		{"missing date", valid[:1]},
		{"duplicate date", append(append([]CalendarDay(nil), valid...), valid[0])},
		{"out of range date", append(append([]CalendarDay(nil), valid...), CalendarDay{Date: "2023-12-31", ContributionCount: 1})},
		{"malformed date", []CalendarDay{{Date: "2024-01-1", ContributionCount: 1}}},
		{"impossible date", []CalendarDay{{Date: "2024-02-30", ContributionCount: 1}}},
		{"negative count", append([]CalendarDay{{Date: "2024-01-01", ContributionCount: -1}}, valid[1:]...)},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := Aggregate(now, "UTC", test.days)
			if err == nil {
				t.Fatal("invalid input was accepted")
			}
			assertValidationKind(t, err, ErrorKindMalformedData)
		})
	}

	if _, err := DecodeCalendarDays([]byte(`[{"date":"2096-01-01","contributionCount":"five"}]`)); err == nil {
		t.Fatal("non-integer JSON count was accepted")
	} else {
		assertValidationKind(t, err, ErrorKindMalformedData)
	}
}

func completeDays(bounds CalendarBounds, count func(index int) int64) []CalendarDay {
	days := make([]CalendarDay, 0)
	for date, index := bounds.QueryStart, 1; !date.After(bounds.Today); date, index = date.AddDate(0, 0, 1), index+1 {
		days = append(days, CalendarDay{Date: date.Format(dateLayout), ContributionCount: count(index)})
	}
	return days
}

func sequentialCounts(index int) int64 {
	return int64(index)
}

func constantOne(int) int64 {
	return 1
}

func assertPeriods(t *testing.T, periods []Period, totals []int64) {
	t.Helper()
	wantNames := []PeriodName{PeriodToday, PeriodWeek, PeriodMonth, PeriodYear}
	if len(periods) != len(wantNames) {
		t.Fatalf("period count = %d, want %d", len(periods), len(wantNames))
	}
	for index, period := range periods {
		if period.Name != wantNames[index] || period.Total != totals[index] {
			t.Fatalf("period %d = %#v, want name %q total %d", index, period, wantNames[index], totals[index])
		}
	}
}

func assertValidationKind(t *testing.T, err error, want ErrorKind) {
	t.Helper()
	var validationError *ValidationError
	if !errors.As(err, &validationError) {
		t.Fatalf("error %T is not a ValidationError: %v", err, err)
	}
	if validationError.Kind != want {
		t.Fatalf("error kind = %q, want %q", validationError.Kind, want)
	}
}
