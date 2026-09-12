package contributions

import (
	_ "embed"
	"encoding/json"
	"errors"
	"time"
)

// fictionalCalendarFixture is repository-owned validation data. It is embedded
// so a built helper can prove its stdout contract without GitHub, gh, or cache
// access.
//
//go:embed testdata/fictional-calendar-2096.json
var fictionalCalendarFixture []byte

type fixtureDocument struct {
	Fictional bool          `json:"fictional"`
	Purpose   string        `json:"purpose"`
	Days      []CalendarDay `json:"days"`
}

// FictionalFixtureEnvelope returns the deterministic schema-v1 envelope used
// by repository validation. It performs no subprocess, network, or cache I/O.
func FictionalFixtureEnvelope() (Envelope, error) {
	var fixture fixtureDocument
	if err := json.Unmarshal(fictionalCalendarFixture, &fixture); err != nil {
		return Envelope{}, errors.New("invalid embedded validation fixture")
	}
	if !fixture.Fictional || fixture.Purpose == "" {
		return Envelope{}, errors.New("embedded validation fixture is not marked fictional")
	}

	now := time.Date(2096, time.January, 14, 12, 0, 0, 0, time.UTC)
	aggregation, err := Aggregate(now, "UTC", fixture.Days)
	if err != nil {
		return Envelope{}, errors.New("invalid embedded validation fixture")
	}
	return FreshEnvelope(aggregation, now, now)
}
