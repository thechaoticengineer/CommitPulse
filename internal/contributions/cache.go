package contributions

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"
)

const (
	cacheRecordVersion = 1
	retryRecordVersion = 1
	cacheFileName      = "success-v1.json"
	retryFileName      = "retry-v1.json"
	lockFileName       = "cache.lock"
	maxCacheBytes      = 16 * 1024
	maxRetryBytes      = 4 * 1024
	defaultLockTimeout = 2 * time.Second
	defaultLockPoll    = 25 * time.Millisecond
	hardMaxLockTimeout = 5 * time.Second
)

var errUnsafeCache = errors.New("cache state is unavailable")

// CacheFileSystem makes cache persistence failures deterministic in tests.
// Implementations must preserve the security behavior of the os-backed
// default, including no-follow flags supplied to OpenFile.
type CacheFileSystem interface {
	Lstat(string) (os.FileInfo, error)
	MkdirAll(string, os.FileMode) error
	Chmod(string, os.FileMode) error
	OpenFile(string, int, os.FileMode) (*os.File, error)
	CreateTemp(string, string) (*os.File, error)
	Rename(string, string) error
	Remove(string) error
}

type osCacheFileSystem struct{}

func (osCacheFileSystem) Lstat(name string) (os.FileInfo, error) { return os.Lstat(name) }
func (osCacheFileSystem) MkdirAll(name string, mode os.FileMode) error {
	return os.MkdirAll(name, mode)
}
func (osCacheFileSystem) Chmod(name string, mode os.FileMode) error { return os.Chmod(name, mode) }
func (osCacheFileSystem) OpenFile(name string, flag int, mode os.FileMode) (*os.File, error) {
	return os.OpenFile(name, flag, mode)
}
func (osCacheFileSystem) CreateTemp(dir, pattern string) (*os.File, error) {
	return os.CreateTemp(dir, pattern)
}
func (osCacheFileSystem) Rename(oldName, newName string) error { return os.Rename(oldName, newName) }
func (osCacheFileSystem) Remove(name string) error             { return os.Remove(name) }

// CacheOptions provides bounded, injectable persistence behavior. Root is the
// final CommitPulse cache directory, not its XDG parent.
type CacheOptions struct {
	Root        string
	Clock       Clock
	Sleeper     Sleeper
	FileSystem  CacheFileSystem
	LockTimeout time.Duration
	LockPoll    time.Duration
}

// ContributionFetcher is the narrow authenticated-fetch boundary used by the
// cache orchestration and deterministic tests.
type ContributionFetcher interface {
	Fetch(context.Context, CalendarBounds) (FetchResult, *FetchError)
}

// CachedService serializes helper invocations and provides stale fallback.
type CachedService struct {
	fetcher ContributionFetcher
	root    string
	clock   Clock
	sleeper Sleeper
	fs      CacheFileSystem
	lock    cacheLocker
	options CacheOptions
}

type cacheRecord struct {
	Version           int        `json:"version"`
	EffectiveTimezone string     `json:"effectiveTimezone"`
	Periods           []Period   `json:"periods"`
	LastUpdated       time.Time  `json:"lastUpdated"`
	Visibility        Visibility `json:"visibility"`
}

type retryRecord struct {
	Version     int           `json:"version"`
	AttemptedAt time.Time     `json:"attemptedAt"`
	RetryAt     time.Time     `json:"retryAt"`
	Error       ContractError `json:"error"`
}

// ResolveCacheRoot follows the XDG base-directory rule and appends the fixed
// application directory. Relative XDG paths are invalid and are never exposed
// in returned errors.
func ResolveCacheRoot() (string, error) {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		var err error
		base, err = os.UserCacheDir()
		if err != nil {
			return "", errUnsafeCache
		}
	}
	if !filepath.IsAbs(base) {
		return "", errUnsafeCache
	}
	return filepath.Join(filepath.Clean(base), "commitpulse"), nil
}

// NewCachedService constructs the single-writer cache wrapper.
func NewCachedService(fetcher ContributionFetcher, options CacheOptions) (*CachedService, error) {
	if fetcher == nil {
		return nil, errors.New("a contribution fetcher is required")
	}
	if options.Root == "" {
		root, err := ResolveCacheRoot()
		if err != nil {
			return nil, errUnsafeCache
		}
		options.Root = root
	}
	if !filepath.IsAbs(options.Root) {
		return nil, errUnsafeCache
	}
	if options.Clock == nil {
		options.Clock = systemClock{}
	}
	if options.Sleeper == nil {
		options.Sleeper = systemSleeper{}
	}
	if options.FileSystem == nil {
		options.FileSystem = osCacheFileSystem{}
	}
	if options.LockTimeout == 0 {
		options.LockTimeout = defaultLockTimeout
	}
	if options.LockPoll == 0 {
		options.LockPoll = defaultLockPoll
	}
	if options.LockTimeout <= 0 || options.LockTimeout > hardMaxLockTimeout ||
		options.LockPoll <= 0 || options.LockPoll > options.LockTimeout {
		return nil, errors.New("invalid cache lock bounds")
	}
	return &CachedService{
		fetcher: fetcher,
		root:    filepath.Clean(options.Root),
		clock:   options.Clock,
		sleeper: options.Sleeper,
		fs:      options.FileSystem,
		lock:    platformCacheLocker{},
		options: options,
	}, nil
}

// Run returns one contract envelope. Only invalid timezone/configuration can
// escape as an error; cache and fetch failures are represented in the envelope.
func (service *CachedService) Run(ctx context.Context, timezone string) (Envelope, error) {
	now := service.clock.Now()
	bounds, err := BoundsFor(now, timezone)
	if err != nil {
		return Envelope{}, err
	}
	if err := service.ensureRoot(); err != nil {
		return service.unavailable(bounds.EffectiveTimezone, nil, nil, fetchFailure(ErrorKindInternal, nil))
	}

	lock, err := service.lock.acquire(ctx, service.fs, filepath.Join(service.root, lockFileName), service.options.LockTimeout, service.options.LockPoll, service.sleeper)
	if err != nil {
		if cached, cacheErr := service.loadCache(bounds.EffectiveTimezone); cacheErr == nil && cached != nil {
			return envelopeFromCache(*cached, now.UTC(), nil, fetchFailure(ErrorKindInternal, nil))
		}
		return service.unavailable(bounds.EffectiveTimezone, nil, nil, fetchFailure(ErrorKindInternal, nil))
	}
	defer lock.close()

	cached, _ := service.loadCache(bounds.EffectiveTimezone)
	if retry, retryErr := service.loadRetry(now); retryErr == nil && retry != nil && retry.RetryAt.After(now) {
		failure := &FetchError{Kind: retry.Error.Kind, Message: retry.Error.Message, RetryAt: timePointer(retry.RetryAt)}
		if cached != nil {
			return envelopeFromCache(*cached, retry.AttemptedAt, failure.RetryAt, failure)
		}
		return service.unavailable(bounds.EffectiveTimezone, timePointer(retry.AttemptedAt), failure.RetryAt, failure)
	}

	attemptedAt := service.clock.Now().UTC()
	fetched, failure := service.fetcher.Fetch(ctx, bounds)
	if failure != nil {
		failure.RetryAt = boundedRetryAt(failure, attemptedAt)
		if failure.RetryAt != nil {
			retry := retryRecord{
				Version:     retryRecordVersion,
				AttemptedAt: attemptedAt,
				RetryAt:     failure.RetryAt.UTC(),
				Error:       ContractError{Kind: failure.Kind, Message: failure.Message},
			}
			_ = service.writeJSON(retryFileName, retry, maxRetryBytes)
		} else {
			_ = service.removeRegular(retryFileName)
		}
		if cached != nil {
			return envelopeFromCache(*cached, attemptedAt, failure.RetryAt, failure)
		}
		return service.unavailable(bounds.EffectiveTimezone, &attemptedAt, failure.RetryAt, failure)
	}

	aggregation, aggregateErr := Aggregate(now, timezone, fetched.Days)
	if aggregateErr != nil {
		failure = fetchFailure(ErrorKindMalformedResponse, nil)
		_ = service.removeRegular(retryFileName)
		if cached != nil {
			return envelopeFromCache(*cached, attemptedAt, nil, failure)
		}
		return service.unavailable(bounds.EffectiveTimezone, &attemptedAt, nil, failure)
	}

	lastUpdated := service.clock.Now().UTC()
	record := cacheRecord{
		Version:           cacheRecordVersion,
		EffectiveTimezone: aggregation.Bounds.EffectiveTimezone,
		Periods:           append([]Period(nil), aggregation.Periods...),
		LastUpdated:       lastUpdated,
		Visibility:        fetched.Visibility,
	}
	persistErr := service.writeJSON(cacheFileName, record, maxCacheBytes)
	if persistErr == nil {
		persistErr = service.removeRegular(retryFileName)
	}
	if persistErr != nil {
		return FreshEnvelopeWithCacheError(aggregation, attemptedAt, lastUpdated, fetched.Visibility)
	}
	return FreshEnvelopeWithVisibility(aggregation, attemptedAt, lastUpdated, fetched.Visibility)
}

func (service *CachedService) unavailable(timezone string, attemptedAt, retryAt *time.Time, failure *FetchError) (Envelope, error) {
	return UnavailableEnvelope(timezone, attemptedAt, retryAt, failure.Kind, failure.Message)
}

func envelopeFromCache(cached cacheRecord, attemptedAt time.Time, retryAt *time.Time, failure *FetchError) (Envelope, error) {
	aggregation := Aggregation{
		Bounds:  CalendarBounds{EffectiveTimezone: cached.EffectiveTimezone},
		Periods: append([]Period(nil), cached.Periods...),
	}
	return StaleEnvelopeWithVisibility(aggregation, attemptedAt, cached.LastUpdated, retryAt, cached.Visibility, failure.Kind, failure.Message)
}

func (service *CachedService) ensureRoot() error {
	if err := service.fs.MkdirAll(service.root, 0o700); err != nil {
		return errUnsafeCache
	}
	info, err := service.fs.Lstat(service.root)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errUnsafeCache
	}
	directory, err := service.fs.OpenFile(service.root, os.O_RDONLY|platformNoFollow, 0)
	if err != nil {
		return errUnsafeCache
	}
	defer directory.Close()
	openedInfo, err := directory.Stat()
	if err != nil || !openedInfo.IsDir() || !os.SameFile(info, openedInfo) {
		return errUnsafeCache
	}
	if err := directory.Chmod(0o700); err != nil {
		return errUnsafeCache
	}
	return nil
}

func (service *CachedService) loadCache(timezone string) (*cacheRecord, error) {
	var record cacheRecord
	if err := service.readJSON(cacheFileName, maxCacheBytes, &record); err != nil {
		return nil, err
	}
	if record.Version != cacheRecordVersion || record.EffectiveTimezone != timezone || record.LastUpdated.IsZero() ||
		!validVisibility(record.Visibility) || validatePeriodSlice(record.Periods) != nil {
		return nil, errUnsafeCache
	}
	return &record, nil
}

func (service *CachedService) loadRetry(now time.Time) (*retryRecord, error) {
	var record retryRecord
	if err := service.readJSON(retryFileName, maxRetryBytes, &record); err != nil {
		return nil, err
	}
	if record.Version != retryRecordVersion || record.AttemptedAt.IsZero() || record.RetryAt.IsZero() ||
		record.Error.Kind != ErrorKindRateLimit || record.Error.Message != fetchFailure(ErrorKindRateLimit, nil).Message ||
		!record.RetryAt.After(record.AttemptedAt) || record.RetryAt.Sub(record.AttemptedAt) > hardMaxRateWait ||
		record.RetryAt.Sub(now) > hardMaxRateWait {
		return nil, errUnsafeCache
	}
	return &record, nil
}

func boundedRetryAt(failure *FetchError, attemptedAt time.Time) *time.Time {
	if failure.Kind != ErrorKindRateLimit || failure.RetryAt == nil {
		return nil
	}
	retryAt := failure.RetryAt.UTC()
	maximum := attemptedAt.Add(hardMaxRateWait)
	if retryAt.After(maximum) {
		retryAt = maximum
	}
	if !retryAt.After(attemptedAt) {
		retryAt = attemptedAt.Add(defaultRateWait)
	}
	return &retryAt
}

func validVisibility(visibility Visibility) bool {
	return visibility.PrivateContributions == VisibilityUnknown || visibility.PrivateContributions == VisibilityIncluded
}

func validatePeriodSlice(periods []Period) error {
	copy := append([]Period(nil), periods...)
	return validatePeriods(&copy)
}

func (service *CachedService) readJSON(name string, limit int64, destination any) error {
	path := filepath.Join(service.root, name)
	info, err := service.fs.Lstat(path)
	if err != nil {
		return errUnsafeCache
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 || info.Size() < 1 || info.Size() > limit {
		return errUnsafeCache
	}
	file, err := service.fs.OpenFile(path, os.O_RDONLY|platformNoFollow, 0)
	if err != nil {
		return errUnsafeCache
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil || !openedInfo.Mode().IsRegular() || !os.SameFile(info, openedInfo) {
		return errUnsafeCache
	}
	input, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(input)) > limit {
		return errUnsafeCache
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil || ensureJSONEOF(decoder) != nil {
		return errUnsafeCache
	}
	return nil
}

func (service *CachedService) writeJSON(name string, value any, limit int) error {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil || buffer.Len() > limit {
		return errUnsafeCache
	}
	target := filepath.Join(service.root, name)
	if err := service.validateReplaceTarget(target); err != nil {
		return err
	}
	temporary, err := service.fs.CreateTemp(service.root, ".commitpulse-*.tmp")
	if err != nil {
		return errUnsafeCache
	}
	temporaryName := temporary.Name()
	keep := false
	defer func() {
		_ = temporary.Close()
		if !keep {
			_ = service.fs.Remove(temporaryName)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return errUnsafeCache
	}
	if _, err := temporary.Write(buffer.Bytes()); err != nil {
		return errUnsafeCache
	}
	if err := temporary.Sync(); err != nil {
		return errUnsafeCache
	}
	if err := temporary.Close(); err != nil {
		return errUnsafeCache
	}
	if err := service.validateReplaceTarget(target); err != nil {
		return err
	}
	if err := service.fs.Rename(temporaryName, target); err != nil {
		return errUnsafeCache
	}
	keep = true
	if err := service.syncRoot(); err != nil {
		return errUnsafeCache
	}
	return nil
}

func (service *CachedService) validateReplaceTarget(path string) error {
	info, err := service.fs.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !info.Mode().IsRegular() {
		return errUnsafeCache
	}
	return nil
}

func (service *CachedService) removeRegular(name string) error {
	path := filepath.Join(service.root, name)
	info, err := service.fs.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !info.Mode().IsRegular() {
		return errUnsafeCache
	}
	if err := service.fs.Remove(path); err != nil {
		return errUnsafeCache
	}
	return service.syncRoot()
}

func (service *CachedService) syncRoot() error {
	directory, err := service.fs.OpenFile(service.root, os.O_RDONLY|platformNoFollow, 0)
	if err != nil {
		return errUnsafeCache
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return errUnsafeCache
	}
	return nil
}
