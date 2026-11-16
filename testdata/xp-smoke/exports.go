// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"
)

// checkLazyGetTickCount64 resolves kernel32!GetTickCount64 at run time, the
// way golang.org/x/sys/windows and modernc.org/libc do, and calls it twice.
// Windows XP has no such export: the toolchain hands out a shim that wraps
// GetTickCount, so this check only passes there when the shim works.
func checkLazyGetTickCount64() error {
	dll, err := syscall.LoadDLL("kernel32.dll")
	if err != nil {
		return err
	}
	proc, err := dll.FindProc("GetTickCount64")
	if err != nil {
		return err
	}
	lo1, hi1, _ := proc.Call()
	time.Sleep(60 * time.Millisecond)
	lo2, hi2, _ := proc.Call()
	v1 := uint64(lo1) | uint64(hi1)<<32
	v2 := uint64(lo2) | uint64(hi2)<<32
	if hi1 != 0 || hi2 != 0 {
		return fmt.Errorf("high word not zero: %#x %#x", hi1, hi2)
	}
	if v2 <= v1 {
		return fmt.Errorf("did not advance: %d -> %d", v1, v2)
	}
	return nil
}

// checkUCRTExport creates a directory through ucrtbase!_wmkdir. ucrtbase.dll
// does not exist on Windows XP: the toolchain fakes the module handle and
// redirects the export to msvcrt, so this check only passes there when the
// redirect works.
func checkUCRTExport(dir string) error {
	path := filepath.Join(dir, "xp-smoke-ucrt")
	if err := os.RemoveAll(path); err != nil {
		return err
	}
	dll, err := syscall.LoadDLL("ucrtbase.dll")
	if err != nil {
		return err
	}
	proc, err := dll.FindProc("_wmkdir")
	if err != nil {
		return err
	}
	namep, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	if r, _, callErr := proc.Call(uintptr(unsafe.Pointer(namep))); int32(r) != 0 {
		return fmt.Errorf("_wmkdir(%s): %v", path, callErr)
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s is not a directory", path)
	}
	return os.Remove(path)
}
