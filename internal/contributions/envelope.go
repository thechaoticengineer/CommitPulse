package contributions

import (
	"encoding/json"
	"io"
	"time"
)

// SchemaVersion is incremented only for intentional incompatible JSON changes.
const SchemaVersion = 1

// State describes whether Periods are current, cached after an error, or not
// available. Unavailable envelopes must omit Periods.
type State string

const (
	StateFresh       State = "fresh"
	StateStale       State = "stale"
	StateUnavailable State = "unavailable"
)

// ErrorKind is a stable, machine-readable error classification. Error messages
// are fixed, sanitized text and must not contain command output or account data.
type ErrorKind string

const (
	ErrorKindMissingGH         ErrorKind = "missing_gh"
	ErrorKindAuthentication    ErrorKind = "authentication"
	ErrorKindOffline           ErrorKind = "offline"
	ErrorKindTimeout           ErrorKind = "timeout"
	ErrorKindRateLimit         ErrorKind = "rate_limit"
	ErrorKindAPI               ErrorKind = "api"
	ErrorKindMalformedResponse ErrorKind = "malformed_response"
	ErrorKindMalformedData     ErrorKind = "malformed_data"
	ErrorKindInvalidTimezone   ErrorKind = "invalid_timezone"
	ErrorKindInternal          ErrorKind = "internal"
	ErrorKindNotImplemented    ErrorKind = "not_implemented"
)

// Visibility records what the helper knows about private/internal contribution
// visibility. Stage 1 cannot inspect GitHub metadata, so it reports unknown.
type Visibility struct {
	PrivateContributions string `json:"privateContributions"`
}

const (
	VisibilityUnknown  = "unknown"
	VisibilityIncluded = "included"
)

// ContractError is the optional sanitized failure detail in the JSON envelope.
type ContractError struct {
	Kind    ErrorKind `json:"kind"`
	Message string    `json:"message"`
}

// Envelope is the versioned stdout contract consumed by a future QML adapter.
// Struct field order intentionally defines deterministic JSON key order.
type Envelope struct {
	SchemaVersion     int            `json:"schemaVersion"`
	State             State          `json:"state"`
	EffectiveTimezone string         `json:"effectiveTimezone"`
	Periods           *[]Period      `json:"periods,omitempty"`
	AttemptedAt       *time.Time     `json:"attemptedAt,omitempty"`
	LastUpdated       *time.Time     `json:"lastUpdated,omitempty"`
	RetryAt           *time.Time     `json:"retryAt,omitempty"`
	Visibility        Visibility     `json:"visibility"`
	Error             *ContractError `json:"error,omitempty"`
}

// FreshEnvelope wraps a successful aggregation. Both update times are required
// because a fresh response has just completed a successful attempt.
func FreshEnvelope(aggregation Aggregation, attemptedAt, lastUpdated time.Time) (Envelope, error) {
	return FreshEnvelopeWithVisibility(
		aggregation,
		attemptedAt,
		lastUpdated,
		Visibility{PrivateContributions: VisibilityUnknown},
	)
}

// FreshEnvelopeWithVisibility wraps a successful aggregation with the
// visibility metadata returned by GitHub. Account identifiers are deliberately
// not part of the stdout contract.
func FreshEnvelopeWithVisibility(aggregation Aggregation, attemptedAt, lastUpdated time.Time, visibility Visibility) (Envelope, error) {
	periods := append([]Period(nil), aggregation.Periods...)
	envelope := Envelope{
		SchemaVersion:     SchemaVersion,
		State:             StateFresh,
		EffectiveTimezone: aggregation.Bounds.EffectiveTimezone,
		Periods:           &periods,
		AttemptedAt:       timePointer(attemptedAt),
		LastUpdated:       timePointer(lastUpdated),
		Visibility:        visibility,
	}
	return envelope, ValidateEnvelope(envelope)
}

// StaleEnvelope retains a previously validated aggregation after a later
// attempt failed. It cannot be used without all four existing period totals.
func StaleEnvelope(aggregation Aggregation, attemptedAt, lastUpdated time.Time, retryAt *time.Time, kind ErrorKind, message string) (Envelope, error) {
	periods := append([]Period(nil), aggregation.Periods...)
	envelope := Envelope{
		SchemaVersion:     SchemaVersion,
		State:             StateStale,
		EffectiveTimezone: aggregation.Bounds.EffectiveTimezone,
		Periods:           &periods,
		AttemptedAt:       timePointer(attemptedAt),
		LastUpdated:       timePointer(lastUpdated),
		RetryAt:           copyTimePointer(retryAt),
		Visibility:        Visibility{PrivateContributions: VisibilityUnknown},
		Error:             &ContractError{Kind: kind, Message: message},
	}
	return envelope, ValidateEnvelope(envelope)
}

// UnavailableEnvelope creates a failure result with no fabricated totals.
func UnavailableEnvelope(effectiveTimezone string, attemptedAt, retryAt *time.Time, kind ErrorKind, message string) (Envelope, error) {
	envelope := Envelope{
		SchemaVersion:     SchemaVersion,
		State:             StateUnavailable,
		EffectiveTimezone: effectiveTimezone,
		AttemptedAt:       copyTimePointer(attemptedAt),
		RetryAt:           copyTimePointer(retryAt),
		Visibility:        Visibility{PrivateContributions: VisibilityUnknown},
		Error:             &ContractError{Kind: kind, Message: message},
	}
	return envelope, ValidateEnvelope(envelope)
}

// ValidateEnvelope rejects partial period data and inconsistent state before an
// envelope can be written to stdout or persisted by later stages.
func ValidateEnvelope(envelope Envelope) error {
	if envelope.SchemaVersion != SchemaVersion {
		return malformed("the output schema version is unsupported")
	}
	if envelope.EffectiveTimezone == "" {
		return malformed("the output does not identify an effective timezone")
	}
	if envelope.Visibility.PrivateContributions != VisibilityUnknown &&
		envelope.Visibility.PrivateContributions != VisibilityIncluded {
		return malformed("the output does not include visibility metadata")
	}
	if envelope.Error != nil && (envelope.Error.Kind == "" || envelope.Error.Message == "") {
		return malformed("the output error is incomplete")
	}

	switch envelope.State {
	case StateFresh:
		if envelope.AttemptedAt == nil || envelope.LastUpdated == nil || envelope.Error != nil {
			return malformed("a fresh output has invalid update metadata")
		}
		return validatePeriods(envelope.Periods)
	case StateStale:
		if envelope.AttemptedAt == nil || envelope.LastUpdated == nil || envelope.Error == nil {
			return malformed("a stale output has invalid update metadata")
		}
		return validatePeriods(envelope.Periods)
	case StateUnavailable:
		if envelope.Periods != nil || envelope.LastUpdated != nil || envelope.Error == nil {
			return malformed("an unavailable output has invalid metadata")
		}
		return nil
	default:
		return malformed("the output state is invalid")
	}
}

// WriteEnvelope writes one deterministic JSON object followed by a newline.
func WriteEnvelope(writer io.Writer, envelope Envelope) error {
	if err := ValidateEnvelope(envelope); err != nil {
		return err
	}
	encoder := json.NewEncoder(writer)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(envelope)
}

func validatePeriods(periods *[]Period) error {
	if periods == nil || len(*periods) != 4 {
		return malformed("the output does not contain the four required periods")
	}
	expected := []PeriodName{PeriodToday, PeriodWeek, PeriodMonth, PeriodYear}
	for index, period := range *periods {
		if period.Name != expected[index] || period.Total < 0 {
			return malformed("the output periods are invalid")
		}
	}
	return nil
}

func timePointer(value time.Time) *time.Time {
	return &value
}

func copyTimePointer(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}
