package contributions

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type cacheTestFetcher struct {
	mu      sync.Mutex
	calls   int
	fetchFn func(CalendarBounds) (FetchResult, *FetchError)
}

func (fetcher *cacheTestFetcher) Fetch(_ context.Context, bounds CalendarBounds) (FetchResult, *FetchError) {
	fetcher.mu.Lock()
	defer fetcher.mu.Unlock()
	fetcher.calls++
	return fetcher.fetchFn(bounds)
}

func (fetcher *cacheTestFetcher) callCount() int {
	fetcher.mu.Lock()
	defer fetcher.mu.Unlock()
	return fetcher.calls
}

type mutableClock struct {
	mu  sync.Mutex
	now time.Time
}

func (clock *mutableClock) Now() time.Time {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	return clock.now
}

func (clock *mutableClock) set(value time.Time) {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	clock.now = value
}

func TestResolveCacheRootFollowsXDGAndFallback(t *testing.T) {
	t.Run("XDG", func(t *testing.T) {
		base := t.TempDir()
		t.Setenv("XDG_CACHE_HOME", base)
		root, err := ResolveCacheRoot()
		if err != nil {
			t.Fatal(err)
		}
		if want := filepath.Join(base, "commitpulse"); root != want {
			t.Fatalf("root = %q, want %q", root, want)
		}
	})
	t.Run("fallback", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("XDG_CACHE_HOME", "")
		t.Setenv("HOME", home)
		root, err := ResolveCacheRoot()
		if err != nil {
			t.Fatal(err)
		}
		if want := filepath.Join(home, ".cache", "commitpulse"); root != want {
			t.Fatalf("root = %q, want %q", root, want)
		}
	})
	t.Run("relative XDG rejected", func(t *testing.T) {
		t.Setenv("XDG_CACHE_HOME", "unexpected-relative-cache")
		if _, err := ResolveCacheRoot(); err == nil || strings.Contains(err.Error(), "unexpected") {
			t.Fatalf("unsafe or leaking error = %v", err)
		}
	})
}

func TestCachedServiceMissAndFreshPrivateWrite(t *testing.T) {
	root := filepath.Join(t.TempDir(), "nested", "commitpulse")
	clock := &mutableClock{now: time.Date(2096, 2, 29, 12, 0, 0, 0, time.UTC)}
	fetcher := successfulCacheFetcher(7)
	service := mustCacheService(t, fetcher, root, clock, nil)

	if cached, err := service.loadCache("UTC"); err == nil || cached != nil {
		t.Fatalf("cache miss = %#v, %v", cached, err)
	}
	envelope, err := service.Run(context.Background(), "UTC")
	if err != nil {
		t.Fatal(err)
	}
	if envelope.State != StateFresh || envelope.Error != nil || envelope.Periods == nil {
		t.Fatalf("fresh envelope = %#v", envelope)
	}
	if fetcher.callCount() != 1 {
		t.Fatalf("fetch calls = %d, want 1", fetcher.callCount())
	}

	assertMode(t, root, 0o700)
	assertMode(t, filepath.Join(root, cacheFileName), 0o600)
	assertMode(t, filepath.Join(root, lockFileName), 0o600)
	cached, err := service.loadCache("UTC")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(cached.Periods, *envelope.Periods) || !cached.LastUpdated.Equal(*envelope.LastUpdated) {
		t.Fatalf("persisted success differs from output: %#v / %#v", cached, envelope)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".commitpulse-") {
			t.Fatalf("temporary cache file was not cleaned up: %s", entry.Name())
		}
	}
}

func TestCachedServiceStaleFallbackPreservesSuccessForEveryFetchError(t *testing.T) {
	kinds := []ErrorKind{
		ErrorKindAuthentication,
		ErrorKindOffline,
		ErrorKindRateLimit,
		ErrorKindTimeout,
		ErrorKindAPI,
	}
	for _, kind := range kinds {
		t.Run(string(kind), func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "commitpulse")
			initial := time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)
			clock := &mutableClock{now: initial}
			seedFetcher := successfulCacheFetcher(3)
			seed := mustCacheService(t, seedFetcher, root, clock, nil)
			fresh, err := seed.Run(context.Background(), "UTC")
			if err != nil {
				t.Fatal(err)
			}

			attempted := initial.Add(5 * time.Minute)
			clock.set(attempted)
			var retryAt *time.Time
			if kind == ErrorKindRateLimit {
				value := attempted.Add(10 * time.Minute)
				retryAt = &value
			}
			failure := fetchFailure(kind, retryAt)
			failing := &cacheTestFetcher{fetchFn: func(CalendarBounds) (FetchResult, *FetchError) {
				return FetchResult{}, failure
			}}
			service := mustCacheService(t, failing, root, clock, nil)
			stale, err := service.Run(context.Background(), "UTC")
			if err != nil {
				t.Fatal(err)
			}
			if stale.State != StateStale || stale.Error == nil || stale.Error.Kind != kind {
				t.Fatalf("stale envelope = %#v", stale)
			}
			if !reflect.DeepEqual(stale.Periods, fresh.Periods) || !stale.LastUpdated.Equal(*fresh.LastUpdated) {
				t.Fatalf("stale output changed cached totals or timestamp: %#v / %#v", stale, fresh)
			}
			if stale.Visibility != fresh.Visibility || !stale.AttemptedAt.Equal(attempted) {
				t.Fatalf("stale metadata = %#v, fresh = %#v", stale, fresh)
			}
		})
	}
}

func TestCachedServiceUnavailableWithoutValidCache(t *testing.T) {
	clock := &mutableClock{now: time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)}
	fetcher := &cacheTestFetcher{fetchFn: func(CalendarBounds) (FetchResult, *FetchError) {
		return FetchResult{}, fetchFailure(ErrorKindOffline, nil)
	}}
	service := mustCacheService(t, fetcher, filepath.Join(t.TempDir(), "commitpulse"), clock, nil)
	envelope, err := service.Run(context.Background(), "UTC")
	if err != nil {
		t.Fatal(err)
	}
	if envelope.State != StateUnavailable || envelope.Periods != nil || envelope.LastUpdated != nil || envelope.Error == nil {
		t.Fatalf("unavailable envelope fabricated cache data: %#v", envelope)
	}
}

func TestInvalidCacheStatesAreIgnoredDeterministically(t *testing.T) {
	valid := `{"version":1,"effectiveTimezone":"UTC","periods":[{"name":"today","total":1},{"name":"week","total":2},{"name":"month","total":3},{"name":"year","total":4}],"lastUpdated":"2096-01-14T12:00:00Z","visibility":{"privateContributions":"unknown"}}
`
	tests := []struct {
		name  string
		setup func(*testing.T, string)
	}{
		{"malformed", func(t *testing.T, path string) { writePrivate(t, path, "{") }},
		{"oversized", func(t *testing.T, path string) { writePrivate(t, path, strings.Repeat("x", maxCacheBytes+1)) }},
		{"wrong version", func(t *testing.T, path string) {
			writePrivate(t, path, strings.Replace(valid, `"version":1`, `"version":2`, 1))
		}},
		{"unknown field", func(t *testing.T, path string) {
			writePrivate(t, path, strings.Replace(valid, `"version":1`, `"version":1,"extra":true`, 1))
		}},
		{"public permissions", func(t *testing.T, path string) { writePrivate(t, path, valid); mustChmod(t, path, 0o644) }},
		{"non regular", func(t *testing.T, path string) {
			if err := os.Mkdir(path, 0o700); err != nil {
				t.Fatal(err)
			}
		}},
		{"interrupted temp only", func(t *testing.T, path string) {
			writePrivate(t, filepath.Join(filepath.Dir(path), ".commitpulse-abandoned.tmp"), valid)
		}},
		{"symlink", func(t *testing.T, path string) {
			victim := filepath.Join(filepath.Dir(path), "victim")
			writePrivate(t, victim, valid)
			if err := os.Symlink(victim, path); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "commitpulse")
			if err := os.Mkdir(root, 0o700); err != nil {
				t.Fatal(err)
			}
			test.setup(t, filepath.Join(root, cacheFileName))
			clock := &mutableClock{now: time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)}
			fetcher := &cacheTestFetcher{fetchFn: func(CalendarBounds) (FetchResult, *FetchError) {
				return FetchResult{}, fetchFailure(ErrorKindAuthentication, nil)
			}}
			service := mustCacheService(t, fetcher, root, clock, nil)
			envelope, err := service.Run(context.Background(), "UTC")
			if err != nil {
				t.Fatal(err)
			}
			if envelope.State != StateUnavailable || envelope.Periods != nil {
				t.Fatalf("invalid cache was emitted: %#v", envelope)
			}
		})
	}
}

func TestSuccessfulFetchAtomicallyReplacesCacheAndPreservesOldDataOnRenameFailure(t *testing.T) {
	root := filepath.Join(t.TempDir(), "commitpulse")
	clock := &mutableClock{now: time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)}
	first := mustCacheService(t, successfulCacheFetcher(2), root, clock, nil)
	oldEnvelope, err := first.Run(context.Background(), "UTC")
	if err != nil {
		t.Fatal(err)
	}

	clock.set(clock.Now().Add(time.Minute))
	second := mustCacheService(t, successfulCacheFetcher(9), root, clock, nil)
	newEnvelope, err := second.Run(context.Background(), "UTC")
	if err != nil || newEnvelope.Error != nil {
		t.Fatalf("replacement failed: %#v, %v", newEnvelope, err)
	}
	if reflect.DeepEqual(newEnvelope.Periods, oldEnvelope.Periods) {
		t.Fatal("successful replacement retained old totals")
	}

	oldBytes, err := os.ReadFile(filepath.Join(root, cacheFileName))
	if err != nil {
		t.Fatal(err)
	}
	clock.set(clock.Now().Add(time.Minute))
	faults := &renameFailFileSystem{}
	failed := mustCacheService(t, successfulCacheFetcher(13), root, clock, faults)
	current, err := failed.Run(context.Background(), "UTC")
	if err != nil {
		t.Fatal(err)
	}
	if current.State != StateFresh || current.Error == nil || current.Error.Kind != ErrorKindInternal {
		t.Fatalf("cache failure did not retain fresh totals with error: %#v", current)
	}
	afterBytes, err := os.ReadFile(filepath.Join(root, cacheFileName))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(afterBytes, oldBytes) {
		t.Fatal("failed atomic replacement changed the last successful cache")
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".commitpulse-") {
			t.Fatalf("failed replacement left temporary file %q", entry.Name())
		}
	}
}

func TestCacheSymlinkTargetsAndRootAreRejectedWithoutFollowing(t *testing.T) {
	t.Run("success target", func(t *testing.T) {
		root := filepath.Join(t.TempDir(), "commitpulse")
		if err := os.Mkdir(root, 0o700); err != nil {
			t.Fatal(err)
		}
		victim := filepath.Join(t.TempDir(), "victim")
		writePrivate(t, victim, "unchanged")
		if err := os.Symlink(victim, filepath.Join(root, cacheFileName)); err != nil {
			t.Fatal(err)
		}
		clock := &mutableClock{now: time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)}
		service := mustCacheService(t, successfulCacheFetcher(4), root, clock, nil)
		envelope, err := service.Run(context.Background(), "UTC")
		if err != nil || envelope.State != StateFresh || envelope.Error == nil {
			t.Fatalf("symlink write result = %#v, %v", envelope, err)
		}
		contents, err := os.ReadFile(victim)
		if err != nil || string(contents) != "unchanged" {
			t.Fatalf("symlink victim changed: %q, %v", contents, err)
		}
	})

	t.Run("root", func(t *testing.T) {
		base := t.TempDir()
		actual := filepath.Join(base, "actual")
		if err := os.Mkdir(actual, 0o700); err != nil {
			t.Fatal(err)
		}
		root := filepath.Join(base, "commitpulse")
		if err := os.Symlink(actual, root); err != nil {
			t.Fatal(err)
		}
		clock := &mutableClock{now: time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)}
		fetcher := successfulCacheFetcher(4)
		service := mustCacheService(t, fetcher, root, clock, nil)
		envelope, err := service.Run(context.Background(), "UTC")
		if err != nil || envelope.State != StateUnavailable || fetcher.callCount() != 0 {
			t.Fatalf("symlink root result = %#v, calls=%d, err=%v", envelope, fetcher.callCount(), err)
		}
	})
}

func TestPersistedRetrySuppressesPrematureFetchWithAndWithoutCache(t *testing.T) {
	for _, seedCache := range []bool{false, true} {
		name := "miss"
		if seedCache {
			name = "hit"
		}
		t.Run(name, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "commitpulse")
			now := time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)
			clock := &mutableClock{now: now}
			if seedCache {
				if _, err := mustCacheService(t, successfulCacheFetcher(1), root, clock, nil).Run(context.Background(), "UTC"); err != nil {
					t.Fatal(err)
				}
			}
			retryAt := now.Add(20 * time.Minute)
			rateFetcher := &cacheTestFetcher{fetchFn: func(CalendarBounds) (FetchResult, *FetchError) {
				return FetchResult{}, fetchFailure(ErrorKindRateLimit, &retryAt)
			}}
			first := mustCacheService(t, rateFetcher, root, clock, nil)
			if _, err := first.Run(context.Background(), "UTC"); err != nil {
				t.Fatal(err)
			}

			suppressedFetcher := successfulCacheFetcher(8)
			second := mustCacheService(t, suppressedFetcher, root, clock, nil)
			suppressed, err := second.Run(context.Background(), "UTC")
			if err != nil {
				t.Fatal(err)
			}
			if suppressedFetcher.callCount() != 0 || suppressed.Error == nil || suppressed.Error.Kind != ErrorKindRateLimit {
				t.Fatalf("retry was not suppressed: calls=%d output=%#v", suppressedFetcher.callCount(), suppressed)
			}
			wantState := StateUnavailable
			if seedCache {
				wantState = StateStale
			}
			if suppressed.State != wantState || suppressed.RetryAt == nil || !suppressed.RetryAt.Equal(retryAt) {
				t.Fatalf("suppressed output = %#v, want %s", suppressed, wantState)
			}

			clock.set(retryAt.Add(time.Second))
			resumed, err := second.Run(context.Background(), "UTC")
			if err != nil || resumed.State != StateFresh || suppressedFetcher.callCount() != 1 {
				t.Fatalf("fetch did not resume after retry window: calls=%d output=%#v err=%v", suppressedFetcher.callCount(), resumed, err)
			}
		})
	}
}

func TestMalformedRetryStateDoesNotSuppressFetch(t *testing.T) {
	root := filepath.Join(t.TempDir(), "commitpulse")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	writePrivate(t, filepath.Join(root, retryFileName), `{"version":2,"attemptedAt":"2096-01-14T12:00:00Z","retryAt":"2196-01-14T12:00:00Z","error":{"kind":"rate_limit","message":"GitHub request rate limit reached."}}`)
	clock := &mutableClock{now: time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)}
	fetcher := successfulCacheFetcher(4)
	envelope, err := mustCacheService(t, fetcher, root, clock, nil).Run(context.Background(), "UTC")
	if err != nil || envelope.State != StateFresh || fetcher.callCount() != 1 {
		t.Fatalf("malformed retry state suppressed fetch: calls=%d output=%#v err=%v", fetcher.callCount(), envelope, err)
	}
}

func TestRateLimitRetryWindowIsBoundedBeforePersistence(t *testing.T) {
	root := filepath.Join(t.TempDir(), "commitpulse")
	now := time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)
	clock := &mutableClock{now: now}
	unbounded := now.Add(24 * time.Hour)
	fetcher := &cacheTestFetcher{fetchFn: func(CalendarBounds) (FetchResult, *FetchError) {
		return FetchResult{}, fetchFailure(ErrorKindRateLimit, &unbounded)
	}}
	service := mustCacheService(t, fetcher, root, clock, nil)
	envelope, err := service.Run(context.Background(), "UTC")
	if err != nil {
		t.Fatal(err)
	}
	want := now.Add(hardMaxRateWait)
	if envelope.RetryAt == nil || !envelope.RetryAt.Equal(want) {
		t.Fatalf("retryAt = %v, want bounded %v", envelope.RetryAt, want)
	}
	retry, err := service.loadRetry(now)
	if err != nil || !retry.RetryAt.Equal(want) {
		t.Fatalf("persisted retry = %#v, %v", retry, err)
	}
}

func TestCacheLockWaitIsBounded(t *testing.T) {
	root := filepath.Join(t.TempDir(), "commitpulse")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	locker := platformCacheLocker{}
	path := filepath.Join(root, lockFileName)
	first, err := locker.acquire(context.Background(), osCacheFileSystem{}, path, time.Second, time.Millisecond, &recordingSleeper{})
	if err != nil {
		t.Fatal(err)
	}
	defer first.close()

	sleeper := &recordingSleeper{}
	if second, err := locker.acquire(context.Background(), osCacheFileSystem{}, path, 10*time.Millisecond, 3*time.Millisecond, sleeper); err == nil {
		_ = second.close()
		t.Fatal("second lock unexpectedly acquired")
	}
	var waited time.Duration
	for _, delay := range sleeper.delays {
		waited += delay
	}
	if waited != 10*time.Millisecond {
		t.Fatalf("lock waited %s, want exact 10ms bound", waited)
	}
}

func TestConcurrentProcessesShareSingleWriterRetryState(t *testing.T) {
	if os.Getenv("COMMITPULSE_CACHE_WORKER") == "1" {
		return
	}
	root := filepath.Join(t.TempDir(), "commitpulse")
	calls := filepath.Join(t.TempDir(), "calls")
	commands := make([]*exec.Cmd, 2)
	outputs := make([]bytes.Buffer, 2)
	for index := range commands {
		command := exec.Command(os.Args[0], "-test.run=^TestCacheSubprocessWorker$")
		command.Env = append(os.Environ(),
			"COMMITPULSE_CACHE_WORKER=1",
			"COMMITPULSE_CACHE_ROOT="+root,
			"COMMITPULSE_CACHE_CALLS="+calls,
		)
		command.Stdout = &outputs[index]
		command.Stderr = &outputs[index]
		commands[index] = command
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
	}
	for index, command := range commands {
		if err := command.Wait(); err != nil {
			t.Fatalf("cache worker failed: %v (%s)", err, outputs[index].Bytes())
		}
	}
	contents, err := os.ReadFile(calls)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(string(contents), "fetch\n"); got != 1 {
		t.Fatalf("concurrent processes made %d fetches, want 1", got)
	}
}

func TestCacheSubprocessWorker(t *testing.T) {
	if os.Getenv("COMMITPULSE_CACHE_WORKER") != "1" {
		t.Skip("subprocess helper")
	}
	now := time.Date(2096, 1, 14, 12, 0, 0, 0, time.UTC)
	retryAt := now.Add(30 * time.Minute)
	fetcher := &cacheTestFetcher{fetchFn: func(CalendarBounds) (FetchResult, *FetchError) {
		file, err := os.OpenFile(os.Getenv("COMMITPULSE_CACHE_CALLS"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := file.WriteString("fetch\n"); err != nil {
			t.Fatal(err)
		}
		if err := file.Close(); err != nil {
			t.Fatal(err)
		}
		time.Sleep(100 * time.Millisecond)
		return FetchResult{}, fetchFailure(ErrorKindRateLimit, &retryAt)
	}}
	clock := &mutableClock{now: now}
	service := mustCacheService(t, fetcher, os.Getenv("COMMITPULSE_CACHE_ROOT"), clock, nil)
	if _, err := service.Run(context.Background(), "UTC"); err != nil {
		t.Fatal(err)
	}
}

type renameFailFileSystem struct{ osCacheFileSystem }

func (*renameFailFileSystem) Rename(string, string) error {
	return errors.New("injected rename failure")
}

func successfulCacheFetcher(total int64) *cacheTestFetcher {
	return &cacheTestFetcher{fetchFn: func(bounds CalendarBounds) (FetchResult, *FetchError) {
		return FetchResult{
			Days:       completeDays(bounds, func(int) int64 { return total }),
			Visibility: Visibility{PrivateContributions: VisibilityIncluded},
		}, nil
	}}
}

func mustCacheService(t *testing.T, fetcher ContributionFetcher, root string, clock Clock, fs CacheFileSystem) *CachedService {
	t.Helper()
	service, err := NewCachedService(fetcher, CacheOptions{
		Root:        root,
		Clock:       clock,
		FileSystem:  fs,
		LockTimeout: time.Second,
		LockPoll:    5 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	return service
}

func writePrivate(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}

func mustChmod(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("mode for fixed cache artifact = %o, want %o", got, want)
	}
}
