package contributions

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type recordingExecutor struct {
	results   []CommandResult
	commands  []Command
	deadlines []time.Duration
}

func (executor *recordingExecutor) Execute(ctx context.Context, command Command) CommandResult {
	executor.commands = append(executor.commands, cloneCommand(command))
	if deadline, ok := ctx.Deadline(); ok {
		executor.deadlines = append(executor.deadlines, time.Until(deadline))
	} else {
		executor.deadlines = append(executor.deadlines, 0)
	}
	index := len(executor.commands) - 1
	if index >= len(executor.results) {
		return CommandResult{ExitCode: -1, Err: errors.New("unconfigured fake execution")}
	}
	return executor.results[index]
}

type fixedClock struct{ now time.Time }

func (clock fixedClock) Now() time.Time { return clock.now }

type recordingSleeper struct {
	delays []time.Duration
	err    error
}

func (sleeper *recordingSleeper) Sleep(_ context.Context, delay time.Duration) error {
	sleeper.delays = append(sleeper.delays, delay)
	return sleeper.err
}

func TestGitHubClientInvocationAndParsing(t *testing.T) {
	t.Parallel()
	bounds := mustBounds(t)
	executor := &recordingExecutor{results: []CommandResult{{
		Stdout: successGraphQLResponse(t, bounds, true),
	}}}
	sleeper := &recordingSleeper{}
	client := mustClient(t, executor, sleeper, FetchOptions{
		AttemptTimeout: 2 * time.Second,
		MaxAttempts:    1,
		MaxStdoutBytes: 12345,
		MaxStderrBytes: 678,
	})

	result, failure := client.Fetch(context.Background(), bounds)
	if failure != nil {
		t.Fatal(failure)
	}
	if got, want := len(result.Days), expectedDayCount(bounds); got != want {
		t.Fatalf("calendar day count = %d, want %d", got, want)
	}
	if got, want := result.Visibility.PrivateContributions, VisibilityIncluded; got != want {
		t.Fatalf("visibility = %q, want %q", got, want)
	}
	if len(executor.commands) != 1 || len(sleeper.delays) != 0 {
		t.Fatalf("executions = %d, sleeps = %v", len(executor.commands), sleeper.delays)
	}
	command := executor.commands[0]
	if command.Name != "gh" {
		t.Fatalf("command name = %q, want gh", command.Name)
	}
	wantArgs := []string{
		"api", "graphql", "--method", "POST",
		"-F", "query=@-",
		"-F", "from=" + bounds.QueryStart.Format(time.RFC3339Nano),
		"-F", "to=" + bounds.QueryEnd.Format(time.RFC3339Nano),
	}
	if !reflect.DeepEqual(command.Args, wantArgs) {
		t.Fatalf("arguments = %#v, want %#v", command.Args, wantArgs)
	}
	if command.Stdin != graphqlQuery {
		t.Fatal("GraphQL query stdin differs from the minimal query contract")
	}
	for _, required := range []string{
		"$from: DateTime!", "$to: DateTime!", "viewer", "login", "url",
		"contributionsCollection(from: $from, to: $to)",
		"hasAnyRestrictedContributions", "restrictedContributionsCount",
		"contributionDays", "date", "contributionCount", "remaining", "resetAt",
	} {
		if !strings.Contains(command.Stdin, required) {
			t.Fatalf("GraphQL query is missing %q", required)
		}
	}
	for _, forbidden := range []string{"email", "repositories", "totalCommitContributions", "mutation"} {
		if strings.Contains(command.Stdin, forbidden) {
			t.Fatalf("GraphQL query unexpectedly requests %q", forbidden)
		}
	}
	if command.MaxStdoutBytes != 12345 || command.MaxStderrBytes != 678 {
		t.Fatalf("output bounds = %d/%d", command.MaxStdoutBytes, command.MaxStderrBytes)
	}
	if got := executor.deadlines[0]; got < 1500*time.Millisecond || got > 2*time.Second {
		t.Fatalf("attempt deadline remaining = %s, want approximately 2s", got)
	}
}

func TestFetchedCalendarProducesStructuredEnvelope(t *testing.T) {
	t.Parallel()
	bounds := mustBounds(t)
	executor := &recordingExecutor{results: []CommandResult{{Stdout: successGraphQLResponse(t, bounds, false)}}}
	client := mustClient(t, executor, &recordingSleeper{}, FetchOptions{MaxAttempts: 1})
	fetched, failure := client.Fetch(context.Background(), bounds)
	if failure != nil {
		t.Fatal(failure)
	}
	aggregation, err := Aggregate(bounds.Today, "UTC", fetched.Days)
	if err != nil {
		t.Fatal(err)
	}
	stamp := time.Date(2096, 1, 14, 15, 0, 0, 0, time.UTC)
	envelope, err := FreshEnvelopeWithVisibility(aggregation, stamp, stamp, fetched.Visibility)
	if err != nil {
		t.Fatal(err)
	}
	if envelope.State != StateFresh || envelope.Periods == nil || len(*envelope.Periods) != 4 {
		t.Fatalf("invalid fetched envelope: %#v", envelope)
	}
	if envelope.Visibility.PrivateContributions != VisibilityUnknown || envelope.Error != nil {
		t.Fatalf("invalid fetched metadata: %#v", envelope)
	}
}

func TestGitHubClientPassesInclusiveTimezoneBounds(t *testing.T) {
	t.Parallel()
	bounds, err := BoundsFor(time.Date(2024, time.March, 10, 12, 0, 0, 0, time.UTC), "America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	executor := &recordingExecutor{results: []CommandResult{{Stdout: successGraphQLResponse(t, bounds, false)}}}
	client := mustClient(t, executor, &recordingSleeper{}, FetchOptions{MaxAttempts: 1})
	if _, failure := client.Fetch(context.Background(), bounds); failure != nil {
		t.Fatal(failure)
	}
	args := executor.commands[0].Args
	if !containsString(args, "from=2024-01-01T00:00:00-05:00") {
		t.Fatalf("from argument is not the inclusive local start: %#v", args)
	}
	if !containsString(args, "to=2024-03-10T23:59:59.999999999-04:00") {
		t.Fatalf("to argument is not the inclusive local end: %#v", args)
	}
}

func TestVisibilityUsesEitherRestrictedContributionSignal(t *testing.T) {
	t.Parallel()
	for _, metadata := range []struct {
		hasAny bool
		count  int64
	}{{hasAny: true, count: 0}, {hasAny: false, count: 2}} {
		bounds := mustBounds(t)
		executor := &recordingExecutor{results: []CommandResult{{
			Stdout: successGraphQLResponseWithVisibility(t, bounds, metadata.hasAny, metadata.count),
		}}}
		client := mustClient(t, executor, &recordingSleeper{}, FetchOptions{MaxAttempts: 1})
		result, failure := client.Fetch(context.Background(), bounds)
		if failure != nil {
			t.Fatal(failure)
		}
		if result.Visibility.PrivateContributions != VisibilityIncluded {
			t.Fatalf("visibility = %q for metadata %#v", result.Visibility.PrivateContributions, metadata)
		}
	}
}

func TestGitHubClientRetriesOnlyTransientFailures(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		result   CommandResult
		wantKind ErrorKind
	}{
		{
			name:     "offline",
			result:   CommandResult{ExitCode: 1, Stderr: []byte("gh: could not resolve host")},
			wantKind: ErrorKindOffline,
		},
		{
			name:     "timeout",
			result:   CommandResult{ExitCode: -1, Err: context.DeadlineExceeded},
			wantKind: ErrorKindTimeout,
		},
		{
			name:     "service failure",
			result:   CommandResult{ExitCode: 1, Stderr: []byte("gh: service unavailable (HTTP 503)")},
			wantKind: ErrorKindAPI,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			executor := &recordingExecutor{results: []CommandResult{test.result, test.result, test.result}}
			sleeper := &recordingSleeper{}
			client := mustClient(t, executor, sleeper, FetchOptions{
				AttemptTimeout: time.Second,
				MaxAttempts:    3,
				InitialBackoff: 10 * time.Millisecond,
				MaxBackoff:     20 * time.Millisecond,
			})
			_, failure := client.Fetch(context.Background(), mustBounds(t))
			assertFetchKind(t, failure, test.wantKind)
			if got, want := len(executor.commands), 3; got != want {
				t.Fatalf("attempts = %d, want %d", got, want)
			}
			if want := []time.Duration{10 * time.Millisecond, 20 * time.Millisecond}; !reflect.DeepEqual(sleeper.delays, want) {
				t.Fatalf("delays = %v, want %v", sleeper.delays, want)
			}
		})
	}
}

func TestGitHubClientDoesNotRetryPermanentFailures(t *testing.T) {
	t.Parallel()
	now := time.Date(2096, time.January, 14, 15, 0, 0, 0, time.UTC)
	rateResponse := graphQLFailureResponse(t, "RATE_LIMITED", "rate limit exceeded", now.Add(20*time.Minute), 0, nil)
	authResponse := graphQLFailureResponse(t, "FORBIDDEN", "requires one of the following scopes", now.Add(time.Hour), 50, nil)
	apiResponse := graphQLFailureResponse(t, "SOMETHING_ELSE", "upstream detail for fixture-viewer", now.Add(time.Hour), 50, nil)
	tests := []struct {
		name     string
		result   CommandResult
		wantKind ErrorKind
	}{
		{"missing gh", CommandResult{ExitCode: -1, Err: fmt.Errorf("wrapped: %w", exec.ErrNotFound)}, ErrorKindMissingGH},
		{"not authenticated", CommandResult{ExitCode: 1, Stderr: []byte("To get started with GitHub CLI, run gh auth login")}, ErrorKindAuthentication},
		{"insufficient scope", CommandResult{Stdout: authResponse}, ErrorKindAuthentication},
		{"rate limit", CommandResult{Stdout: rateResponse}, ErrorKindRateLimit},
		{"GraphQL API", CommandResult{Stdout: apiResponse}, ErrorKindAPI},
		{"malformed JSON", CommandResult{Stdout: []byte("not-json")}, ErrorKindMalformedResponse},
		{"output overflow", CommandResult{ExitCode: -1, Err: errOutputLimit}, ErrorKindMalformedResponse},
		{"internal executor", CommandResult{ExitCode: -1, Err: errors.New("fake internal detail")}, ErrorKindInternal},
		{"unknown process failure", CommandResult{ExitCode: 2, Stderr: []byte("unrecognized upstream detail")}, ErrorKindAPI},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			executor := &recordingExecutor{results: []CommandResult{test.result}}
			sleeper := &recordingSleeper{}
			client := mustClientWithClock(t, executor, sleeper, fixedClock{now}, FetchOptions{MaxAttempts: 3})
			_, failure := client.Fetch(context.Background(), mustBounds(t))
			assertFetchKind(t, failure, test.wantKind)
			if got := len(executor.commands); got != 1 {
				t.Fatalf("attempts = %d, want 1", got)
			}
			if len(sleeper.delays) != 0 {
				t.Fatalf("unexpected delays: %v", sleeper.delays)
			}
		})
	}
}

func TestGitHubClientRejectsPartialGraphQLData(t *testing.T) {
	t.Parallel()
	now := time.Date(2096, time.January, 14, 15, 0, 0, 0, time.UTC)
	tests := []struct {
		name     string
		response []byte
		wantKind ErrorKind
	}{
		{
			name: "top level error with partial data",
			response: graphQLFailureResponse(t, "INTERNAL", "partial response detail", now.Add(time.Hour), 10, map[string]any{
				"viewer": map[string]any{"login": "fixture-viewer"},
			}),
			wantKind: ErrorKindAPI,
		},
		{
			name:     "missing viewer subtree",
			response: mustJSON(t, map[string]any{"data": map[string]any{"rateLimit": rateLimitObject(now.Add(time.Hour), 10)}}),
			wantKind: ErrorKindMalformedResponse,
		},
		{
			name: "missing calendar days",
			response: mustJSON(t, map[string]any{"data": map[string]any{
				"viewer": map[string]any{
					"login": "fixture-viewer", "url": "https://example.invalid/fixture-viewer",
					"contributionsCollection": map[string]any{
						"hasAnyRestrictedContributions": false,
						"restrictedContributionsCount":  0,
						"contributionCalendar":          map[string]any{"weeks": []any{map[string]any{}}},
					},
				},
				"rateLimit": rateLimitObject(now.Add(time.Hour), 10),
			}}),
			wantKind: ErrorKindMalformedResponse,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			executor := &recordingExecutor{results: []CommandResult{{Stdout: test.response}}}
			client := mustClientWithClock(t, executor, &recordingSleeper{}, fixedClock{now}, FetchOptions{MaxAttempts: 1})
			_, failure := client.Fetch(context.Background(), mustBounds(t))
			assertFetchKind(t, failure, test.wantKind)
		})
	}
}

func TestGitHubClientRateLimitMetadataStopsImmediateRetries(t *testing.T) {
	t.Parallel()
	now := time.Date(2096, time.January, 14, 15, 0, 0, 0, time.UTC)
	tests := []struct {
		name      string
		response  []byte
		wantRetry time.Time
	}{
		{
			name:      "primary reset time",
			response:  graphQLFailureResponse(t, "RATE_LIMITED", "rate limit", now.Add(17*time.Minute), 0, nil),
			wantRetry: now.Add(17 * time.Minute),
		},
		{
			name: "secondary retry after",
			response: graphQLFailureResponse(t, "FORBIDDEN", "secondary rate limit", now.Add(time.Hour), 10, map[string]any{
				"extensionRetryAfter": 75,
			}),
			wantRetry: now.Add(75 * time.Second),
		},
		{
			name:      "missing metadata uses bounded fallback",
			response:  graphQLFailureResponse(t, "FORBIDDEN", "secondary rate limit", time.Time{}, 10, nil),
			wantRetry: now.Add(time.Minute),
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			executor := &recordingExecutor{results: []CommandResult{{Stdout: test.response}}}
			sleeper := &recordingSleeper{}
			client := mustClientWithClock(t, executor, sleeper, fixedClock{now}, FetchOptions{MaxAttempts: 3})
			_, failure := client.Fetch(context.Background(), mustBounds(t))
			assertFetchKind(t, failure, ErrorKindRateLimit)
			if failure.RetryAt == nil || !failure.RetryAt.Equal(test.wantRetry) {
				t.Fatalf("retryAt = %v, want %v", failure.RetryAt, test.wantRetry)
			}
			if len(executor.commands) != 1 || len(sleeper.delays) != 0 {
				t.Fatalf("rate limit retried: attempts=%d sleeps=%v", len(executor.commands), sleeper.delays)
			}
		})
	}
}

func TestGitHubClientErrorsAreSanitized(t *testing.T) {
	t.Parallel()
	const sensitive = "fixture-sensitive-marker"
	executor := &recordingExecutor{results: []CommandResult{{
		ExitCode: 1,
		Stdout:   []byte(`{"viewer":"` + sensitive + `"}`),
		Stderr:   []byte("not logged into any GitHub hosts: " + sensitive),
	}}}
	client := mustClient(t, executor, &recordingSleeper{}, FetchOptions{MaxAttempts: 1})
	_, failure := client.Fetch(context.Background(), mustBounds(t))
	assertFetchKind(t, failure, ErrorKindAuthentication)
	if strings.Contains(failure.Message, sensitive) || strings.Contains(failure.Error(), sensitive) {
		t.Fatal("upstream response data escaped into the sanitized error")
	}
	if failure.Message != "GitHub authentication or permissions are unavailable." {
		t.Fatalf("message = %q", failure.Message)
	}
}

func TestGitHubClientRejectsInvalidOrOverlongBoundsWithoutExecution(t *testing.T) {
	t.Parallel()
	valid := mustBounds(t)
	tests := []CalendarBounds{
		{},
		{QueryStart: valid.QueryEnd, QueryEnd: valid.QueryStart},
		{QueryStart: time.Date(2096, 1, 1, 0, 0, 0, 0, time.UTC), QueryEnd: time.Date(2097, 1, 1, 0, 0, 0, 0, time.UTC)},
	}
	for _, bounds := range tests {
		executor := &recordingExecutor{}
		client := mustClient(t, executor, &recordingSleeper{}, FetchOptions{MaxAttempts: 1})
		_, failure := client.Fetch(context.Background(), bounds)
		assertFetchKind(t, failure, ErrorKindInternal)
		if len(executor.commands) != 0 {
			t.Fatal("invalid bounds started a GitHub request")
		}
	}
}

func TestQueryBoundsPermitACompleteLeapYear(t *testing.T) {
	t.Parallel()
	bounds := CalendarBounds{
		QueryStart: time.Date(2096, 1, 1, 0, 0, 0, 0, time.UTC),
		QueryEnd:   time.Date(2096, 12, 31, 23, 59, 59, 999999999, time.UTC),
	}
	if !validQueryBounds(bounds) {
		t.Fatal("complete leap-year interval was rejected")
	}
}

func TestGitHubClientCancellationDuringBackoffIsBounded(t *testing.T) {
	t.Parallel()
	executor := &recordingExecutor{results: []CommandResult{{ExitCode: 1, Stderr: []byte("network is unreachable")}}}
	sleeper := &recordingSleeper{err: context.Canceled}
	client := mustClient(t, executor, sleeper, FetchOptions{MaxAttempts: 3})
	_, failure := client.Fetch(context.Background(), mustBounds(t))
	assertFetchKind(t, failure, ErrorKindTimeout)
	if len(executor.commands) != 1 || len(sleeper.delays) != 1 {
		t.Fatalf("attempts=%d delays=%v", len(executor.commands), sleeper.delays)
	}
}

func TestSystemExecutorBoundsOutputAndDeadline(t *testing.T) {
	t.Parallel()
	executor := SystemExecutor{}
	overflow := executor.Execute(context.Background(), Command{
		Name: "sh", Args: []string{"-c", "yes x"}, MaxStdoutBytes: 64, MaxStderrBytes: 64,
	})
	if !errors.Is(overflow.Err, errOutputLimit) || len(overflow.Stdout) > 64 {
		t.Fatalf("overflow result: err=%v bytes=%d", overflow.Err, len(overflow.Stdout))
	}

	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	timedOut := executor.Execute(ctx, Command{
		Name: "sh", Args: []string{"-c", "sleep 2"}, MaxStdoutBytes: 64, MaxStderrBytes: 64,
	})
	if !errors.Is(timedOut.Err, context.DeadlineExceeded) {
		t.Fatalf("deadline result = %v", timedOut.Err)
	}
}

func TestSystemExecutorKeepsGitHubWrapperOutputCleanAndNonInteractive(t *testing.T) {
	directory := t.TempDir()
	wrapper := filepath.Join(directory, "gh")
	contents := `#!/bin/sh
if [ "$MISE_QUIET" != "1" ] || [ "$GH_PROMPT_DISABLED" != "1" ]; then
  printf 'wrapper chatter\n'
  exit 2
fi
if [ "$1" != "api" ] || [ "$2" != "graphql" ]; then
  exit 3
fi
printf '{"fixture":"ok"}'
`
	if err := os.WriteFile(wrapper, []byte(contents), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory+":"+os.Getenv("PATH"))
	result := (SystemExecutor{}).Execute(context.Background(), Command{
		Name: "gh", Args: []string{"api", "graphql"}, MaxStdoutBytes: 64, MaxStderrBytes: 64,
	})
	if result.Err != nil || result.ExitCode != 0 {
		t.Fatalf("wrapper execution failed: code=%d err=%v", result.ExitCode, result.Err)
	}
	if got, want := string(result.Stdout), `{"fixture":"ok"}`; got != want {
		t.Fatalf("stdout = %q, want %q", got, want)
	}
}

func TestNewGitHubClientRejectsUnboundedOptions(t *testing.T) {
	t.Parallel()
	for _, options := range []FetchOptions{
		{MaxAttempts: defaultMaxAttempts + 1},
		{AttemptTimeout: -time.Second},
		{AttemptTimeout: hardMaxAttemptTimeout + time.Second},
		{MaxStdoutBytes: -1},
		{MaxStdoutBytes: hardMaxStdoutLimit + 1},
		{MaxStderrBytes: hardMaxStderrLimit + 1},
		{MaxBackoff: hardMaxBackoff + time.Second},
		{DefaultRateWait: time.Hour, MaxRateWait: time.Minute},
		{MaxRateWait: hardMaxRateWait + time.Second},
	} {
		if _, err := NewGitHubClient(&recordingExecutor{}, fixedClock{}, &recordingSleeper{}, options); err == nil {
			t.Fatalf("accepted invalid options: %#v", options)
		}
	}
}

func mustClient(t *testing.T, executor Executor, sleeper Sleeper, options FetchOptions) *GitHubClient {
	t.Helper()
	return mustClientWithClock(t, executor, sleeper, fixedClock{time.Date(2096, 1, 14, 15, 0, 0, 0, time.UTC)}, options)
}

func mustClientWithClock(t *testing.T, executor Executor, sleeper Sleeper, clock Clock, options FetchOptions) *GitHubClient {
	t.Helper()
	client, err := NewGitHubClient(executor, clock, sleeper, options)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func mustBounds(t *testing.T) CalendarBounds {
	t.Helper()
	bounds, err := BoundsFor(time.Date(2096, time.January, 14, 12, 0, 0, 0, time.UTC), "UTC")
	if err != nil {
		t.Fatal(err)
	}
	return bounds
}

func successGraphQLResponse(t *testing.T, bounds CalendarBounds, restricted bool) []byte {
	t.Helper()
	count := int64(0)
	if restricted {
		count = 2
	}
	return successGraphQLResponseWithVisibility(t, bounds, restricted, count)
}

func successGraphQLResponseWithVisibility(t *testing.T, bounds CalendarBounds, restricted bool, count int64) []byte {
	t.Helper()
	days := completeDays(bounds, func(index int) int64 { return int64(index % 5) })
	return mustJSON(t, map[string]any{
		"data": map[string]any{
			"viewer": map[string]any{
				"login": "fixture-viewer",
				"url":   "https://example.invalid/fixture-viewer",
				"contributionsCollection": map[string]any{
					"hasAnyRestrictedContributions": restricted,
					"restrictedContributionsCount":  count,
					"contributionCalendar": map[string]any{
						"weeks": []any{map[string]any{"contributionDays": days, "ignoredFutureField": true}},
					},
				},
			},
			"rateLimit": rateLimitObject(time.Date(2096, 1, 14, 16, 0, 0, 0, time.UTC), 100),
		},
		"ignoredFutureField": true,
	})
}

func graphQLFailureResponse(t *testing.T, errorType, message string, resetAt time.Time, remaining int, extra map[string]any) []byte {
	t.Helper()
	extensions := map[string]any{"code": errorType}
	if extra != nil {
		if retryAfter, ok := extra["extensionRetryAfter"]; ok {
			extensions["retryAfter"] = retryAfter
			delete(extra, "extensionRetryAfter")
		}
	}
	data := map[string]any{"rateLimit": rateLimitObject(resetAt, remaining)}
	for key, value := range extra {
		data[key] = value
	}
	return mustJSON(t, map[string]any{
		"data": data,
		"errors": []any{map[string]any{
			"type": errorType, "message": message, "extensions": extensions,
		}},
	})
}

func rateLimitObject(resetAt time.Time, remaining int) map[string]any {
	reset := "invalid"
	if !resetAt.IsZero() {
		reset = resetAt.Format(time.RFC3339Nano)
	}
	return map[string]any{"remaining": remaining, "resetAt": reset}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func expectedDayCount(bounds CalendarBounds) int {
	count := 0
	for day := bounds.QueryStart; !day.After(bounds.Today); day = day.AddDate(0, 0, 1) {
		count++
	}
	return count
}

func cloneCommand(command Command) Command {
	command.Args = append([]string(nil), command.Args...)
	return command
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func assertFetchKind(t *testing.T, failure *FetchError, want ErrorKind) {
	t.Helper()
	if failure == nil {
		t.Fatalf("expected %s failure, got success", want)
	}
	if failure.Kind != want {
		t.Fatalf("failure kind = %q, want %q", failure.Kind, want)
	}
}
