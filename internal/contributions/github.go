package contributions

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const graphqlQuery = `query CommitPulseContributions($from: DateTime!, $to: DateTime!) {
  viewer {
    login
    url
    contributionsCollection(from: $from, to: $to) {
      hasAnyRestrictedContributions
      restrictedContributionsCount
      contributionCalendar {
        weeks {
          contributionDays {
            date
            contributionCount
          }
        }
      }
    }
  }
  rateLimit {
    remaining
    resetAt
  }
}`

const (
	defaultAttemptTimeout = 15 * time.Second
	defaultMaxAttempts    = 3
	defaultInitialBackoff = 250 * time.Millisecond
	defaultMaxBackoff     = 2 * time.Second
	defaultStdoutLimit    = 512 * 1024
	defaultStderrLimit    = 32 * 1024
	defaultRateWait       = time.Minute
	defaultMaxRateWait    = time.Hour
	hardMaxAttemptTimeout = 30 * time.Second
	hardMaxBackoff        = 5 * time.Second
	hardMaxStdoutLimit    = 1024 * 1024
	hardMaxStderrLimit    = 64 * 1024
	hardMaxRateWait       = time.Hour
)

var errOutputLimit = errors.New("subprocess output limit exceeded")

// Command describes one bounded subprocess invocation. It contains no
// environment field by design: CommitPulse does not inspect, override, or
// report the ambient authentication environment used by gh.
type Command struct {
	Name           string
	Args           []string
	Stdin          string
	MaxStdoutBytes int
	MaxStderrBytes int
}

// CommandResult contains bounded in-memory process output. Callers must never
// propagate its contents into logs or user-facing errors.
type CommandResult struct {
	Stdout   []byte
	Stderr   []byte
	ExitCode int
	Err      error
}

// Executor permits deterministic tests without invoking gh or the network.
type Executor interface {
	Execute(context.Context, Command) CommandResult
}

// Clock supplies retry metadata without tying tests to wall-clock time.
type Clock interface {
	Now() time.Time
}

// Sleeper implements cancellable retry delays.
type Sleeper interface {
	Sleep(context.Context, time.Duration) error
}

type systemClock struct{}

func (systemClock) Now() time.Time { return time.Now() }

type systemSleeper struct{}

func (systemSleeper) Sleep(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// SystemExecutor runs a command directly, without a shell, and cancels it as
// soon as either output stream crosses its configured bound.
type SystemExecutor struct{}

func (SystemExecutor) Execute(ctx context.Context, command Command) CommandResult {
	processContext, cancel := context.WithCancel(ctx)
	defer cancel()

	name := command.Name
	args := command.Args
	if command.Name == "gh" {
		resolved, err := exec.LookPath(command.Name)
		if err != nil {
			return CommandResult{ExitCode: -1, Err: err}
		}
		// env applies fixed, non-sensitive overlays while inheriting the ambient
		// authentication environment directly in the child. Go never enumerates
		// that environment, and mise-backed gh wrappers remain quiet.
		name = "env"
		args = append([]string{"MISE_QUIET=1", "GH_PROMPT_DISABLED=1", resolved}, command.Args...)
	}
	cmd := exec.CommandContext(processContext, name, args...)
	cmd.Stdin = strings.NewReader(command.Stdin)
	var overflow atomic.Bool
	stdout := newCappedBuffer(command.MaxStdoutBytes, func() {
		overflow.Store(true)
		cancel()
	})
	stderr := newCappedBuffer(command.MaxStderrBytes, func() {
		overflow.Store(true)
		cancel()
	})
	cmd.Stdout = stdout
	cmd.Stderr = stderr

	err := cmd.Run()
	result := CommandResult{Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), ExitCode: 0}
	if overflow.Load() {
		result.ExitCode = -1
		result.Err = errOutputLimit
		return result
	}
	if ctx.Err() != nil {
		result.ExitCode = -1
		result.Err = ctx.Err()
		return result
	}
	if err == nil {
		return result
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		result.ExitCode = exitError.ExitCode()
		return result
	}
	result.ExitCode = -1
	result.Err = err
	return result
}

type cappedBuffer struct {
	mu       sync.Mutex
	buffer   bytes.Buffer
	limit    int
	once     sync.Once
	overflow func()
}

func newCappedBuffer(limit int, overflow func()) *cappedBuffer {
	return &cappedBuffer{limit: limit, overflow: overflow}
}

func (buffer *cappedBuffer) Write(input []byte) (int, error) {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	remaining := buffer.limit - buffer.buffer.Len()
	if remaining >= len(input) {
		return buffer.buffer.Write(input)
	}
	written := 0
	if remaining > 0 {
		written, _ = buffer.buffer.Write(input[:remaining])
	}
	buffer.once.Do(buffer.overflow)
	return written, errOutputLimit
}

func (buffer *cappedBuffer) Bytes() []byte {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return append([]byte(nil), buffer.buffer.Bytes()...)
}

// FetchOptions bounds every external operation. Zero values select safe
// defaults; tests may choose smaller positive values.
type FetchOptions struct {
	AttemptTimeout  time.Duration
	MaxAttempts     int
	InitialBackoff  time.Duration
	MaxBackoff      time.Duration
	MaxStdoutBytes  int
	MaxStderrBytes  int
	DefaultRateWait time.Duration
	MaxRateWait     time.Duration
}

// GitHubClient fetches one authenticated viewer contribution calendar through
// gh. It never accepts a token and never formats upstream output into errors.
type GitHubClient struct {
	executor Executor
	clock    Clock
	sleeper  Sleeper
	options  FetchOptions
}

func NewGitHubClient(executor Executor, clock Clock, sleeper Sleeper, options FetchOptions) (*GitHubClient, error) {
	if executor == nil {
		executor = SystemExecutor{}
	}
	if clock == nil {
		clock = systemClock{}
	}
	if sleeper == nil {
		sleeper = systemSleeper{}
	}
	options = withFetchDefaults(options)
	if options.AttemptTimeout <= 0 || options.MaxAttempts < 1 || options.MaxAttempts > defaultMaxAttempts ||
		options.InitialBackoff <= 0 || options.MaxBackoff < options.InitialBackoff ||
		options.MaxStdoutBytes <= 0 || options.MaxStderrBytes <= 0 ||
		options.DefaultRateWait <= 0 || options.MaxRateWait < options.DefaultRateWait ||
		options.AttemptTimeout > hardMaxAttemptTimeout || options.MaxBackoff > hardMaxBackoff ||
		options.MaxStdoutBytes > hardMaxStdoutLimit || options.MaxStderrBytes > hardMaxStderrLimit ||
		options.MaxRateWait > hardMaxRateWait {
		return nil, errors.New("invalid GitHub client bounds")
	}
	return &GitHubClient{executor: executor, clock: clock, sleeper: sleeper, options: options}, nil
}

func withFetchDefaults(options FetchOptions) FetchOptions {
	if options.AttemptTimeout == 0 {
		options.AttemptTimeout = defaultAttemptTimeout
	}
	if options.MaxAttempts == 0 {
		options.MaxAttempts = defaultMaxAttempts
	}
	if options.InitialBackoff == 0 {
		options.InitialBackoff = defaultInitialBackoff
	}
	if options.MaxBackoff == 0 {
		options.MaxBackoff = defaultMaxBackoff
	}
	if options.MaxStdoutBytes == 0 {
		options.MaxStdoutBytes = defaultStdoutLimit
	}
	if options.MaxStderrBytes == 0 {
		options.MaxStderrBytes = defaultStderrLimit
	}
	if options.DefaultRateWait == 0 {
		options.DefaultRateWait = defaultRateWait
	}
	if options.MaxRateWait == 0 {
		options.MaxRateWait = defaultMaxRateWait
	}
	return options
}

// FetchResult is deliberately not the stdout contract. Viewer identifiers are
// validated because the query is for the authenticated viewer, then discarded
// by the command instead of being printed or persisted.
type FetchResult struct {
	Days       []CalendarDay
	Visibility Visibility
}

// FetchError contains only project-owned constant text and optional bounded
// retry metadata. It never contains gh output, GraphQL messages, or account data.
type FetchError struct {
	Kind      ErrorKind
	Message   string
	RetryAt   *time.Time
	transient bool
}

func (failure *FetchError) Error() string { return string(failure.Kind) + ": " + failure.Message }

func (client *GitHubClient) Fetch(ctx context.Context, bounds CalendarBounds) (FetchResult, *FetchError) {
	if !validQueryBounds(bounds) {
		return FetchResult{}, fetchFailure(ErrorKindInternal, nil)
	}
	command := Command{
		Name: "gh",
		Args: []string{
			"api", "graphql", "--method", "POST",
			"-F", "query=@-",
			"-F", "from=" + bounds.QueryStart.Format(time.RFC3339Nano),
			"-F", "to=" + bounds.QueryEnd.Format(time.RFC3339Nano),
		},
		Stdin:          graphqlQuery,
		MaxStdoutBytes: client.options.MaxStdoutBytes,
		MaxStderrBytes: client.options.MaxStderrBytes,
	}

	var lastFailure *FetchError
	for attempt := 0; attempt < client.options.MaxAttempts; attempt++ {
		if ctx.Err() != nil {
			return FetchResult{}, fetchFailure(ErrorKindTimeout, nil)
		}
		attemptContext, cancel := context.WithTimeout(ctx, client.options.AttemptTimeout)
		result := client.executor.Execute(attemptContext, command)
		deadlineExpired := errors.Is(attemptContext.Err(), context.DeadlineExceeded)
		cancel()

		fetched, failure := client.interpret(result, deadlineExpired)
		if failure == nil {
			return fetched, nil
		}
		lastFailure = failure
		if !failure.transient || attempt+1 == client.options.MaxAttempts {
			return FetchResult{}, failure
		}
		delay := client.retryDelay(attempt)
		if err := client.sleeper.Sleep(ctx, delay); err != nil {
			return FetchResult{}, fetchFailure(ErrorKindTimeout, nil)
		}
	}
	return FetchResult{}, lastFailure
}

func validQueryBounds(bounds CalendarBounds) bool {
	if bounds.QueryStart.IsZero() || bounds.QueryEnd.IsZero() || bounds.QueryEnd.Before(bounds.QueryStart) {
		return false
	}
	// GitHub's default range is at most one calendar year. Keeping the explicit
	// inclusive end before start+1 year also permits a complete leap year.
	return bounds.QueryEnd.Before(bounds.QueryStart.AddDate(1, 0, 0))
}

func (client *GitHubClient) retryDelay(attempt int) time.Duration {
	delay := client.options.InitialBackoff
	for index := 0; index < attempt && delay < client.options.MaxBackoff; index++ {
		if delay > client.options.MaxBackoff/2 {
			return client.options.MaxBackoff
		}
		delay *= 2
	}
	if delay > client.options.MaxBackoff {
		return client.options.MaxBackoff
	}
	return delay
}

type graphQLResponse struct {
	Data   *graphQLData   `json:"data"`
	Errors []graphQLError `json:"errors"`
}

type graphQLData struct {
	Viewer    *graphQLViewer    `json:"viewer"`
	RateLimit *graphQLRateLimit `json:"rateLimit"`
}

type graphQLViewer struct {
	Login                   *string               `json:"login"`
	URL                     *string               `json:"url"`
	ContributionsCollection *graphQLContributions `json:"contributionsCollection"`
}

type graphQLContributions struct {
	HasAnyRestrictedContributions *bool            `json:"hasAnyRestrictedContributions"`
	RestrictedContributionsCount  *int64           `json:"restrictedContributionsCount"`
	ContributionCalendar          *graphQLCalendar `json:"contributionCalendar"`
}

type graphQLCalendar struct {
	Weeks *[]graphQLWeek `json:"weeks"`
}

type graphQLWeek struct {
	ContributionDays *[]CalendarDay `json:"contributionDays"`
}

type graphQLRateLimit struct {
	Remaining *int    `json:"remaining"`
	ResetAt   *string `json:"resetAt"`
}

type graphQLError struct {
	Message    string `json:"message"`
	Type       string `json:"type"`
	Extensions struct {
		Code       string          `json:"code"`
		RetryAfter json.RawMessage `json:"retryAfter"`
	} `json:"extensions"`
}

func (client *GitHubClient) interpret(result CommandResult, deadlineExpired bool) (FetchResult, *FetchError) {
	if deadlineExpired || errors.Is(result.Err, context.DeadlineExceeded) || errors.Is(result.Err, context.Canceled) {
		failure := fetchFailure(ErrorKindTimeout, nil)
		failure.transient = true
		return FetchResult{}, failure
	}
	if errors.Is(result.Err, errOutputLimit) {
		return FetchResult{}, fetchFailure(ErrorKindMalformedResponse, nil)
	}
	if result.Err != nil {
		if errors.Is(result.Err, exec.ErrNotFound) {
			return FetchResult{}, fetchFailure(ErrorKindMissingGH, nil)
		}
		return FetchResult{}, fetchFailure(ErrorKindInternal, nil)
	}

	response, decodeErr := decodeGraphQLResponse(result.Stdout)
	if result.ExitCode != 0 {
		return FetchResult{}, client.classifyProcessFailure(result, response)
	}
	if decodeErr != nil {
		return FetchResult{}, fetchFailure(ErrorKindMalformedResponse, nil)
	}
	if len(response.Errors) != 0 {
		return FetchResult{}, client.classifyGraphQLErrors(response)
	}
	return parseSuccessfulResponse(response)
}

func decodeGraphQLResponse(output []byte) (*graphQLResponse, error) {
	decoder := json.NewDecoder(bytes.NewReader(output))
	var response graphQLResponse
	if err := decoder.Decode(&response); err != nil {
		return nil, err
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return nil, err
	}
	return &response, nil
}

func parseSuccessfulResponse(response *graphQLResponse) (FetchResult, *FetchError) {
	if response == nil || response.Data == nil || response.Data.Viewer == nil || response.Data.RateLimit == nil {
		return FetchResult{}, fetchFailure(ErrorKindMalformedResponse, nil)
	}
	viewer := response.Data.Viewer
	collection := viewer.ContributionsCollection
	if viewer.Login == nil || *viewer.Login == "" || viewer.URL == nil || *viewer.URL == "" || collection == nil ||
		collection.HasAnyRestrictedContributions == nil || collection.RestrictedContributionsCount == nil ||
		collection.ContributionCalendar == nil || collection.ContributionCalendar.Weeks == nil ||
		response.Data.RateLimit.Remaining == nil || response.Data.RateLimit.ResetAt == nil {
		return FetchResult{}, fetchFailure(ErrorKindMalformedResponse, nil)
	}
	if _, err := time.Parse(time.RFC3339Nano, *response.Data.RateLimit.ResetAt); err != nil ||
		*response.Data.RateLimit.Remaining < 0 || *collection.RestrictedContributionsCount < 0 {
		return FetchResult{}, fetchFailure(ErrorKindMalformedResponse, nil)
	}

	days := make([]CalendarDay, 0)
	for _, week := range *collection.ContributionCalendar.Weeks {
		if week.ContributionDays == nil {
			return FetchResult{}, fetchFailure(ErrorKindMalformedResponse, nil)
		}
		days = append(days, (*week.ContributionDays)...)
	}
	visibility := Visibility{PrivateContributions: VisibilityUnknown}
	if *collection.HasAnyRestrictedContributions || *collection.RestrictedContributionsCount > 0 {
		visibility.PrivateContributions = VisibilityIncluded
	}
	return FetchResult{Days: days, Visibility: visibility}, nil
}

func (client *GitHubClient) classifyProcessFailure(result CommandResult, response *graphQLResponse) *FetchError {
	if response != nil && len(response.Errors) != 0 {
		return client.classifyGraphQLErrors(response)
	}
	signal := strings.ToLower(string(result.Stderr))
	switch {
	case containsAny(signal, "rate limit", "secondary rate", "abuse detection", "http 429"):
		return client.rateFailure(response, nil)
	case containsAny(signal, "not logged into any github hosts", "to get started with github cli", "gh auth login", "authentication failed", "requires authentication", "http 401", "insufficient scope", "requires one of the following scopes", "resource not accessible"):
		return fetchFailure(ErrorKindAuthentication, nil)
	case containsAny(signal, "context deadline exceeded", "operation timed out", "request timeout", "i/o timeout", "client.timeout exceeded"):
		failure := fetchFailure(ErrorKindTimeout, nil)
		failure.transient = true
		return failure
	case containsAny(signal, "could not resolve host", "temporary failure in name resolution", "no such host", "network is unreachable", "connection refused", "connection reset", "tls handshake timeout", "dial tcp", "dial udp", "lookup api.github.com", "server misbehaving", "unexpected eof"):
		failure := fetchFailure(ErrorKindOffline, nil)
		failure.transient = true
		return failure
	case containsAny(signal, "http 500", "http 502", "http 503", "http 504"):
		failure := fetchFailure(ErrorKindAPI, nil)
		failure.transient = true
		return failure
	default:
		return fetchFailure(ErrorKindAPI, nil)
	}
}

func (client *GitHubClient) classifyGraphQLErrors(response *graphQLResponse) *FetchError {
	for _, item := range response.Errors {
		signal := strings.ToLower(item.Type + " " + item.Extensions.Code + " " + item.Message)
		if containsAny(signal, "rate_limit", "rate limit", "rate_limited", "secondary rate") {
			return client.rateFailure(response, &item)
		}
	}
	for _, item := range response.Errors {
		signal := strings.ToLower(item.Type + " " + item.Extensions.Code + " " + item.Message)
		if containsAny(signal, "unauthenticated", "forbidden", "insufficient_scope", "insufficient scope", "requires authentication", "resource not accessible") {
			return fetchFailure(ErrorKindAuthentication, nil)
		}
	}
	return fetchFailure(ErrorKindAPI, nil)
}

func (client *GitHubClient) rateFailure(response *graphQLResponse, item *graphQLError) *FetchError {
	now := client.clock.Now()
	retryAt := now.Add(client.options.DefaultRateWait)
	if response != nil && response.Data != nil && response.Data.RateLimit != nil &&
		response.Data.RateLimit.Remaining != nil && *response.Data.RateLimit.Remaining == 0 &&
		response.Data.RateLimit.ResetAt != nil {
		if parsed, err := time.Parse(time.RFC3339Nano, *response.Data.RateLimit.ResetAt); err == nil && parsed.After(now) {
			retryAt = parsed
		}
	}
	if item != nil {
		if delay, ok := parseRetryAfter(item.Extensions.RetryAfter); ok {
			retryAt = now.Add(delay)
		}
	}
	maximum := now.Add(client.options.MaxRateWait)
	if retryAt.After(maximum) {
		retryAt = maximum
	}
	if !retryAt.After(now) {
		retryAt = now.Add(client.options.DefaultRateWait)
	}
	retryAt = retryAt.UTC()
	return fetchFailure(ErrorKindRateLimit, &retryAt)
}

func parseRetryAfter(raw json.RawMessage) (time.Duration, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	var seconds int64
	if err := json.Unmarshal(raw, &seconds); err != nil {
		var text string
		if json.Unmarshal(raw, &text) != nil {
			return 0, false
		}
		parsed, err := strconv.ParseInt(text, 10, 64)
		if err != nil {
			return 0, false
		}
		seconds = parsed
	}
	if seconds <= 0 || seconds > int64(defaultMaxRateWait/time.Second)*24 {
		return 0, false
	}
	return time.Duration(seconds) * time.Second, true
}

func containsAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}

func fetchFailure(kind ErrorKind, retryAt *time.Time) *FetchError {
	messages := map[ErrorKind]string{
		ErrorKindMissingGH:         "GitHub CLI is not installed.",
		ErrorKindAuthentication:    "GitHub authentication or permissions are unavailable.",
		ErrorKindOffline:           "GitHub is temporarily unreachable.",
		ErrorKindTimeout:           "The GitHub request timed out.",
		ErrorKindRateLimit:         "GitHub request rate limit reached.",
		ErrorKindAPI:               "GitHub API request failed.",
		ErrorKindMalformedResponse: "GitHub returned an invalid response.",
		ErrorKindInternal:          "The contribution request could not be completed.",
	}
	message, ok := messages[kind]
	if !ok {
		kind = ErrorKindInternal
		message = messages[kind]
	}
	return &FetchError{Kind: kind, Message: message, RetryAt: copyTimePointer(retryAt)}
}
