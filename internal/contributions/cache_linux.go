//go:build linux

package contributions

import (
	"context"
	"errors"
	"os"
	"syscall"
	"time"
)

const platformNoFollow = syscall.O_NOFOLLOW

type cacheLock interface {
	close() error
}

type cacheLocker interface {
	acquire(context.Context, CacheFileSystem, string, time.Duration, time.Duration, Sleeper) (cacheLock, error)
}

type platformCacheLocker struct{}

type flockLock struct {
	file *os.File
}

func (platformCacheLocker) acquire(ctx context.Context, fs CacheFileSystem, path string, timeout, poll time.Duration, sleeper Sleeper) (cacheLock, error) {
	if info, err := fs.Lstat(path); err == nil {
		if !info.Mode().IsRegular() {
			return nil, errUnsafeCache
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, errUnsafeCache
	}
	file, err := fs.OpenFile(path, os.O_CREATE|os.O_RDWR|platformNoFollow, 0o600)
	if err != nil {
		return nil, errUnsafeCache
	}
	closeFailure := func() (cacheLock, error) {
		_ = file.Close()
		return nil, errUnsafeCache
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return closeFailure()
	}
	if err := file.Chmod(0o600); err != nil {
		return closeFailure()
	}
	waited := time.Duration(0)
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return &flockLock{file: file}, nil
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EAGAIN {
			return closeFailure()
		}
		if waited >= timeout {
			return closeFailure()
		}
		delay := poll
		if remaining := timeout - waited; delay > remaining {
			delay = remaining
		}
		if delay <= 0 || sleeper.Sleep(ctx, delay) != nil {
			return closeFailure()
		}
		waited += delay
	}
}

func (lock *flockLock) close() error {
	err := syscall.Flock(int(lock.file.Fd()), syscall.LOCK_UN)
	closeErr := lock.file.Close()
	if err != nil {
		return err
	}
	return closeErr
}
