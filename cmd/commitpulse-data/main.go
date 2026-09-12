// commitpulse-data is the repository-owned contribution-data helper.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/thechaoticengineer/commitpulse/internal/contributions"
)

func main() {
	var timezone string
	var version bool
	flag.StringVar(&timezone, "timezone", "", "IANA timezone (defaults to the host local timezone)")
	flag.BoolVar(&version, "version", false, "print the helper contract version")
	flag.Parse()

	if version {
		fmt.Printf("commitpulse-data schema %d\n", contributions.SchemaVersion)
		return
	}
	if flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: commitpulse-data [-timezone IANA] [-version]")
		os.Exit(2)
	}

	now := time.Now()
	bounds, err := contributions.BoundsFor(now, timezone)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	client, err := contributions.NewGitHubClient(nil, nil, nil, contributions.FetchOptions{})
	if err != nil {
		fmt.Fprintln(os.Stderr, "failed to initialize contribution fetch")
		os.Exit(1)
	}
	attemptedAt := now.UTC()
	fetched, fetchErr := client.Fetch(context.Background(), bounds)
	var envelope contributions.Envelope
	if fetchErr != nil {
		envelope, err = contributions.UnavailableEnvelope(
			bounds.EffectiveTimezone,
			&attemptedAt,
			fetchErr.RetryAt,
			fetchErr.Kind,
			fetchErr.Message,
		)
	} else {
		aggregation, aggregateErr := contributions.Aggregate(now, timezone, fetched.Days)
		if aggregateErr != nil {
			envelope, err = contributions.UnavailableEnvelope(
				bounds.EffectiveTimezone,
				&attemptedAt,
				nil,
				contributions.ErrorKindMalformedResponse,
				"GitHub returned an invalid response.",
			)
		} else {
			updatedAt := time.Now().UTC()
			envelope, err = contributions.FreshEnvelopeWithVisibility(aggregation, attemptedAt, updatedAt, fetched.Visibility)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "failed to create helper output")
		os.Exit(1)
	}
	if err := contributions.WriteEnvelope(os.Stdout, envelope); err != nil {
		fmt.Fprintln(os.Stderr, "failed to write helper output")
		os.Exit(1)
	}
	if fetchErr != nil || envelope.State == contributions.StateUnavailable {
		os.Exit(1)
	}
}
