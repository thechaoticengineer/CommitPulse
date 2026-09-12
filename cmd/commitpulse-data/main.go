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

	client, err := contributions.NewGitHubClient(nil, nil, nil, contributions.FetchOptions{})
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
