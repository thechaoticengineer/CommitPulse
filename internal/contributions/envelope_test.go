package contributions

import (
	"bytes"
	"testing"
	"time"
)

func TestFreshEnvelopeSerializationIsStable(t *testing.T) {
	t.Parallel()
	bounds, err := BoundsFor(time.Date(2096, time.January, 2, 10, 0, 0, 0, time.UTC), "Europe/Warsaw")
	if err != nil {
		t.Fatal(err)
	}
	aggregation, err := Aggregate(bounds.Today, "Europe/Warsaw", completeDays(bounds, func(int) int64 { return 2 }))
	if err != nil {
		t.Fatal(err)
	}
	attempted := time.Date(2096, time.January, 2, 9, 5, 0, 0, time.UTC)
	updated := time.Date(2096, time.January, 2, 9, 5, 1, 0, time.UTC)
	envelope, err := FreshEnvelope(aggregation, attempted, updated)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := WriteEnvelope(&output, envelope); err != nil {
		t.Fatal(err)
	}
	const want = "{\"schemaVersion\":1,\"state\":\"fresh\",\"effectiveTimezone\":\"Europe/Warsaw\",\"periods\":[{\"name\":\"today\",\"total\":2},{\"name\":\"week\",\"total\":2},{\"name\":\"month\",\"total\":4},{\"name\":\"year\",\"total\":4}],\"attemptedAt\":\"2096-01-02T09:05:00Z\",\"lastUpdated\":\"2096-01-02T09:05:01Z\",\"visibility\":{\"privateContributions\":\"unknown\"}}\n"
	if got := output.String(); got != want {
		t.Fatalf("serialized envelope = %s, want %s", got, want)
	}
}

func TestUnavailableEnvelopeOmitsPeriodsAndTimesWhenNoAttemptOccurred(t *testing.T) {
	t.Parallel()
	envelope, err := UnavailableEnvelope("UTC", nil, nil, ErrorKindNotImplemented, "GitHub contribution fetching is not available in this build.")
	if err != nil {
		t.Fatal(err)
	}
	if envelope.Periods != nil || envelope.AttemptedAt != nil || envelope.LastUpdated != nil {
		t.Fatalf("unavailable envelope fabricated data: %#v", envelope)
	}
	if err := ValidateEnvelope(envelope); err != nil {
		t.Fatal(err)
	}
}

func TestEnvelopeValidationRejectsPartialAndMisleadingStates(t *testing.T) {
	t.Parallel()
	now := time.Date(2096, time.January, 1, 0, 0, 0, 0, time.UTC)
	partial := []Period{{Name: PeriodToday, Total: 0}}
	invalid := Envelope{
		SchemaVersion:     SchemaVersion,
		State:             StateUnavailable,
		EffectiveTimezone: "UTC",
		Periods:           &partial,
		Visibility:        Visibility{PrivateContributions: visibilityUnknown},
		Error:             &ContractError{Kind: ErrorKindOffline, Message: "The contribution service is unavailable."},
	}
	if err := ValidateEnvelope(invalid); err == nil {
		t.Fatal("unavailable envelope with totals was accepted")
	}

	stale := Envelope{
		SchemaVersion:     SchemaVersion,
		State:             StateStale,
		EffectiveTimezone: "UTC",
		Periods:           &partial,
		AttemptedAt:       &now,
		LastUpdated:       &now,
		Visibility:        Visibility{PrivateContributions: visibilityUnknown},
		Error:             &ContractError{Kind: ErrorKindOffline, Message: "The contribution service is unavailable."},
	}
	if err := ValidateEnvelope(stale); err == nil {
		t.Fatal("stale envelope with partial periods was accepted")
	}
}
