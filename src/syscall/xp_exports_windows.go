// Copyright 2026 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package syscall

// Windows XP compatibility shims for exports that programs resolve at run
// time through LoadLibrary/GetProcAddress.
//
// This tree already makes every statically imported Vista+ export optional,
// but code outside the standard library does its own dynamic loading.
// golang.org/x/sys/windows is one example, and packages built on top of it
// (the pure-Go C runtime behind modernc.org/libc and the cgo-free SQLite
// drivers, for instance) call GetProcAddress for whatever the C code uses.
// When such a program asks kernel32.dll for an export that only exists on
// Vista or later, the lookup fails and the program aborts even though nothing
// in the Go code asked for a Vista-only feature.
//
// The table below closes that gap. getprocaddress consults it when the real
// GetProcAddress fails and hands out a reserved "shim address" instead. A
// call to a shim address is intercepted by syscalln and redirected to another
// export of the same system library. On Windows 7 and later the real lookup
// always succeeds, so the shim path is never taken and behaviour is
// unchanged.
//
// The entries were verified on a Windows XP SP3 machine by resolving every
// dynamically loaded export used by modernc.org/libc v1.80.1: 159 exports
// across kernel32, advapi32, ws2_32, user32, netapi32, userenv, msvcrt and
// ucrtbase. Only these are missing on XP:
//
//	kernel32.dll!GetTickCount64	Vista+; GetTickCount is the documented substitute
//	kernel32.dll!OpenProcessToken	libc looks it up in kernel32, it lives in advapi32
//	msvcrt.dll!time64		msvcrt spells it _time64
//	msvcrt.dll!ctime64		msvcrt spells it _ctime64
//	msvcrt.dll!_gmtime32		msvcrt spells it gmtime (32-bit time_t)
//	ucrtbase.dll			the Universal CRT does not exist on XP at all
//
// ucrtbase.dll is reported missing as a whole library, so a failed
// LoadLibraryExW for it gets a fake module handle and the CRT exports it
// provides are redirected to their msvcrt equivalents. The four
// _stat64i32/_wstat64i32/_wfindfirst64i32/_wfindnext64i32 entries have no
// layout-compatible msvcrt replacement and stay unresolved on purpose: making
// up a struct layout would be worse than a clean failure. Set GODEBUG=xpapi=1
// to have every unresolved lookup printed, which is how the table was derived
// and how to audit a new dependency on a real XP machine.

import (
	"strings"
	"sync"
	"sync/atomic"
	"unsafe"
)

// xpAPIDebugName is the GODEBUG setting that reports unresolved exports. It is
// parsed here instead of through internal/godebug because that package panics
// for names that are not registered in internal/godebugs, and this setting is
// specific to this toolchain.
const xpAPIDebugName = "xpapi"

var (
	xpGODEBUGOnce sync.Once
	xpGODEBUGOn   bool
	xpGODEBUGBusy int32
)

// xpAPIDebugOn reports whether GODEBUG=xpapi=1 is set. The busy flag keeps a
// lookup that fails while reading the environment from recursing into itself.
func xpAPIDebugOn() bool {
	if atomic.LoadInt32(&xpGODEBUGBusy) != 0 {
		return false
	}
	atomic.StoreInt32(&xpGODEBUGBusy, 1)
	xpGODEBUGOnce.Do(func() {
		v, _ := Getenv("GODEBUG")
		for _, field := range strings.Split(v, ",") {
			if k, val, ok := strings.Cut(field, "="); ok && k == xpAPIDebugName {
				xpGODEBUGOn = val != "" && val != "0"
			}
		}
	})
	atomic.StoreInt32(&xpGODEBUGBusy, 0)
	return xpGODEBUGOn
}

const (
	// xpShimAddr starts the reserved range of procedure addresses handed out
	// for shimmed exports. It sits at the top of the address space, which no
	// loaded module can occupy, so syscalln recognises a shim with a single
	// subtraction.
	xpShimAddr = ^uintptr(0) - 0x100

	// xpFakeModule is the module handle returned in place of a system DLL
	// that this version of Windows does not have.
	xpFakeModule = ^uintptr(0) - 0x40
)

type xpShimEntry struct {
	dll        string // module the program asks for
	proc       string // export the program asks for
	targetDLL  string // module that provides the replacement
	targetProc string // replacement export
	zeroHigh   bool   // discard the high half of the result (32-bit return value)
}

var xpShimTable = []xpShimEntry{
	// GetTickCount64 returns ULONGLONG; GetTickCount returns DWORD in EAX and
	// leaves the upper half undefined, hence zeroHigh.
	{"kernel32.dll", "GetTickCount64", "kernel32.dll", "GetTickCount", true},

	// libc binds OpenProcessToken to kernel32; the export lives in advapi32.
	{"kernel32.dll", "OpenProcessToken", "advapi32.dll", "OpenProcessToken", false},

	// Names the Universal CRT exports without the msvcrt underscore, or with
	// a decoration msvcrt never had.
	{"msvcrt.dll", "time64", "msvcrt.dll", "_time64", false},
	{"msvcrt.dll", "ctime64", "msvcrt.dll", "_ctime64", false},
	{"msvcrt.dll", "_gmtime32", "msvcrt.dll", "gmtime", false},

	// ucrtbase.dll replacements. The struct-returning ones are only safe
	// where the XP msvcrt struct has the same layout: 32-bit time_t with a
	// 64-bit size (_stat32i64 -> _stati64) or with a 32-bit size
	// (_wstat32 -> _wstat).
	{"ucrtbase.dll", "_stat32i64", "msvcrt.dll", "_stati64", false},
	{"ucrtbase.dll", "_wstat32", "msvcrt.dll", "_wstat", false},
	{"ucrtbase.dll", "_findfirst32", "msvcrt.dll", "_findfirst", false},
	{"ucrtbase.dll", "_findnext32", "msvcrt.dll", "_findnext", false},
	{"ucrtbase.dll", "_wfindfirst32", "msvcrt.dll", "_wfindfirst", false},
	{"ucrtbase.dll", "_wfindnext32", "msvcrt.dll", "_wfindnext", false},
	{"ucrtbase.dll", "_wchmod", "msvcrt.dll", "_wchmod", false},
	{"ucrtbase.dll", "_wmkdir", "msvcrt.dll", "_wmkdir", false},
	{"ucrtbase.dll", "_wfullpath", "msvcrt.dll", "_wfullpath", false},
}

var (
	// xpShimTargets holds the resolved address of each replacement export.
	// It stays 0 until xpResolve runs, and for entries that could not be
	// resolved, in which case calls to that shim fail cleanly.
	xpShimTargets = make([]uintptr, len(xpShimTable))

	xpShimOnce sync.Once

	// xpDLLs caches the module handles used to tell which DLL a
	// GetProcAddress handle refers to.
	xpDLLs = []struct {
		name   string
		handle uintptr
	}{
		{"kernel32.dll", 0},
		{"msvcrt.dll", 0},
		{"advapi32.dll", 0},
	}
)

// xpResolve loads the modules and resolves the replacement exports. It runs on
// the first failed lookup, so programs that only use exports their Windows
// version has never pay for it.
func xpResolve() {
	xpShimOnce.Do(func() {
		for i := range xpDLLs {
			xpDLLs[i].handle = xpLoadLibrary(xpDLLs[i].name)
		}
		for i := range xpShimTable {
			e := &xpShimTable[i]
			target := xpResolveProc(e.targetDLL, e.targetProc)
			atomic.StoreUintptr(&xpShimTargets[i], target)
			if target == 0 {
				xpLog("cannot resolve fallback " + e.targetDLL + "!" + e.targetProc)
			}
		}
	})
}

func xpLoadLibrary(name string) uintptr {
	p, err := UTF16PtrFromString(name)
	if err != nil {
		return 0
	}
	h, _, _ := SyscallN(uintptr(__LoadLibraryExW), uintptr(unsafe.Pointer(p)), 0, 0)
	return h
}

func xpResolveProc(dll, proc string) uintptr {
	var h uintptr
	for i := range xpDLLs {
		if xpDLLs[i].name == dll {
			h = xpDLLs[i].handle
			break
		}
	}
	if h == 0 {
		return 0
	}
	p, err := BytePtrFromString(proc)
	if err != nil {
		return 0
	}
	r, _, _ := SyscallN(uintptr(__GetProcAddress), h, uintptr(unsafe.Pointer(p)))
	return r
}

// xpExportFallback returns the shim address for an export that this version of
// Windows does not provide, or 0 if there is no substitute.
func xpExportFallback(handle uintptr, procname *uint8) uintptr {
	xpResolve()
	dll := xpDLLName(handle)
	if dll == "" {
		return 0
	}
	name := xpCString(procname)
	for i := range xpShimTable {
		e := &xpShimTable[i]
		if e.dll == dll && e.proc == name {
			return xpShimAddr + uintptr(i) + 1
		}
	}
	return 0
}

func xpDLLName(handle uintptr) string {
	if handle == xpFakeModule {
		return "ucrtbase.dll"
	}
	for i := range xpDLLs {
		if handle != 0 && xpDLLs[i].handle == handle {
			return xpDLLs[i].name
		}
	}
	return ""
}

func xpCString(p *uint8) string {
	if p == nil {
		return ""
	}
	var b []byte
	for i := 0; i < 64; i++ {
		c := *(*byte)(unsafe.Add(unsafe.Pointer(p), i))
		if c == 0 {
			break
		}
		b = append(b, c)
	}
	return string(b)
}

// xpLog prints a diagnostic when GODEBUG=xpapi=1 is set.
func xpLog(msg string) {
	if xpAPIDebugOn() {
		println("xpapi: " + msg)
	}
}

// xpLogMiss reports an export that this version of Windows lacks and that the
// shim table does not cover. It only formats the message when the diagnostic
// is enabled, since probing for optional exports can fail routinely.
func xpLogMiss(handle uintptr, procname *uint8) {
	if !xpAPIDebugOn() {
		return
	}
	dll := xpDLLName(handle)
	if dll == "" {
		dll = "unknown module"
	}
	println("xpapi: unresolved export " + dll + "!" + xpCString(procname))
}

// xpShimCall handles a call to a shimmed export and the load of a system DLL
// that this version of Windows does not have. It is called from syscalln on
// the syscall path and must not grow the stack or allocate.
//
//go:nosplit
func xpShimCall(fn, n uintptr, args []uintptr) (r1, r2 uintptr, err Errno, ok bool) {
	if idx := fn - xpShimAddr; idx != 0 && idx <= uintptr(len(xpShimTable)) {
		target := atomic.LoadUintptr(&xpShimTargets[idx-1])
		if target == 0 {
			return 0, 0, ERROR_PROC_NOT_FOUND, true
		}
		r1, r2, err = syscallnRaw(target, n, args...)
		if xpShimTable[idx-1].zeroHigh {
			r2 = 0
		}
		return r1, r2, err, true
	}

	// A failed load of a DLL that does not exist on this Windows version
	// turns into a fake module handle, so that the CRT exports it would have
	// provided can still be resolved by getprocaddress.
	if fn == uintptr(__LoadLibraryExW) {
		r1, r2, err = syscallnRaw(fn, n, args...)
		if r1 == 0 && n >= 1 {
			if h := xpAbsentDLL((*uint16)(unsafe.Pointer(args[0]))); h != 0 {
				return h, 0, 0, true
			}
		}
		return r1, r2, err, true
	}

	return 0, 0, 0, false
}

// xpAbsentDLL returns a fake module handle when the UTF-16 file name is a
// system DLL that does not exist on this Windows version.
//
//go:nosplit
func xpAbsentDLL(p *uint16) uintptr {
	const want = "ucrtbase.dll"
	if p == nil {
		return 0
	}
	var start, i uintptr
	for ; i < 260; i++ {
		c := *(*uint16)(unsafe.Add(unsafe.Pointer(p), i*2))
		if c == 0 {
			break
		}
		if c == '\\' || c == '/' {
			start = i + 1
		}
	}
	if i < start+uintptr(len(want)) {
		return 0
	}
	for j := uintptr(0); j < uintptr(len(want)); j++ {
		c := *(*uint16)(unsafe.Add(unsafe.Pointer(p), (start+j)*2))
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if byte(c) != want[j] {
			return 0
		}
	}
	if *(*uint16)(unsafe.Add(unsafe.Pointer(p), (start+uintptr(len(want)))*2)) != 0 {
		return 0
	}
	return xpFakeModule
}
