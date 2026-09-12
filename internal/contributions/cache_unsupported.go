//go:build !linux

package contributions

import (
	"context"
	"time"
)

const platformNoFollow = 0

type cacheLock interface {
	close() error
}

type cacheLocker interface {
	acquire(context.Context, CacheFileSystem, string, time.Duration, time.Duration, Sleeper) (cacheLock, error)
}

type platformCacheLocker struct{}

func (platformCacheLocker) acquire(context.Context, CacheFileSystem, string, time.Duration, time.Duration, Sleeper) (cacheLock, error) {
	return nil, errUnsafeCache
}
