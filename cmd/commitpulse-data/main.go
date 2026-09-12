// commitpulse-data is the repository-owned contribution-data helper.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/thechaoticengineer/commitpulse/internal/contributions"
)

func main() {
	var timezone string
	var version bool
	var fixture bool
	var maxAttempts int
	flag.StringVar(&timezone, "timezone", "", "IANA timezone (defaults to the host local timezone)")
	flag.BoolVar(&version, "version", false, "print the helper contract version")
	flag.BoolVar(&fixture, "fixture", false, "emit deterministic fictional validation data")
	flag.IntVar(&maxAttempts, "max-attempts", 3, "maximum GraphQL request attempts (1-3)")
	flag.Parse()

	if flag.NArg() != 0 || maxAttempts < 1 || maxAttempts > 3 ||
		(fixture && (timezone != "" || version || maxAttempts != 3)) ||
		(version && (timezone != "" || maxAttempts != 3)) {
		fmt.Fprintln(os.Stderr, "usage: commitpulse-data [-timezone IANA] [-max-attempts 1-3] | -fixture | -version")
		os.Exit(2)
	}
	if version {
		fmt.Printf("commitpulse-data schema %d\n", contributions.SchemaVersion)
		return
	}
	if fixture {
		envelope, err := contributions.FictionalFixtureEnvelope()
		if err != nil || contributions.WriteEnvelope(os.Stdout, envelope) != nil {
			fmt.Fprintln(os.Stderr, "failed to write fictional fixture output")
			os.Exit(1)
		}
		return
	}

	client, err := contributions.NewGitHubClient(nil, nil, nil, contributions.FetchOptions{MaxAttempts: maxAttempts})
	if err != nil {
		fmt.Fprintln(os.Stderr, "failed to initialize contribution fetch")
		os.Exit(1)
	}
	service, err := contributions.NewCachedService(client, contributions.CacheOptions{})
	if err != nil {
		fmt.Fprintln(os.Stderr, "failed to initialize contribution cache")
		os.Exit(1)
	}
	envelope, err := service.Run(context.Background(), timezone)
	if err != nil {
		fmt.Fprintln(os.Stderr, "the requested timezone is not a valid IANA location")
		os.Exit(2)
	}
	if err := contributions.WriteEnvelope(os.Stdout, envelope); err != nil {
		fmt.Fprintln(os.Stderr, "failed to write helper output")
		os.Exit(1)
	}
	if envelope.Error != nil {
		os.Exit(1)
	}
}
