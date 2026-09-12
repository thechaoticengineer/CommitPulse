// commitpulse-data is the repository-owned contribution-data helper.
// Fetching and caching are intentionally added in later delivery stages.
package main

import (
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

	_, effectiveTimezone, err := contributions.ResolveLocation(timezone)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	envelope, err := contributions.UnavailableEnvelope(
		effectiveTimezone,
		nil,
		nil,
		contributions.ErrorKindNotImplemented,
		"GitHub contribution fetching is not available in this build.",
	)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := contributions.WriteEnvelope(os.Stdout, envelope); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
