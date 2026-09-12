package contributions

import (
	"bytes"
	"testing"
)

func TestFictionalFixtureEnvelopeIsDeterministic(t *testing.T) {
	t.Parallel()

	envelope, err := FictionalFixtureEnvelope()
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := WriteEnvelope(&output, envelope); err != nil {
		t.Fatal(err)
	}
	const want = "{\"schemaVersion\":1,\"state\":\"fresh\",\"effectiveTimezone\":\"UTC\",\"periods\":[{\"name\":\"today\",\"total\":7},{\"name\":\"week\",\"total\":17},{\"name\":\"month\",\"total\":40},{\"name\":\"year\",\"total\":40}],\"attemptedAt\":\"2096-01-14T12:00:00Z\",\"lastUpdated\":\"2096-01-14T12:00:00Z\",\"visibility\":{\"privateContributions\":\"unknown\"}}\n"
	if output.String() != want {
		t.Fatal("fictional fixture output changed")
	}
}
