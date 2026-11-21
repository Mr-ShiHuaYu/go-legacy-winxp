@echo off
setlocal EnableExtensions

:: ============================================================
:: build-xp.bat -- build a Windows XP (windows/386) Go toolchain
:: from this tree and assemble a self-contained "copy2xp" folder
:: that can be copied to an XP machine and used there directly.
::
:: Double-clicking works: the defaults build a 386 host toolchain
:: and write copy2xp\ next to this script.
::
:: Why GOHOSTARCH=386: bin\go.exe must itself be a 386 binary so
:: that it matches pkg\tool\windows_386. Otherwise go looks for
:: pkg\tool\windows_<hostarch> and fails with "no such tool".
:: The bootstrap Go may be 32- or 64-bit; it only has to be at
:: least Go 1.24.6 (make.bat's requirement).
::
:: Usage:
::   build-xp.bat            build + assemble
::   build-xp.bat assemble   assemble from existing output only
::
:: Optional environment:
::   GOROOT_BOOTSTRAP=<dir>  bootstrap Go tree (default: first go on PATH)
::   GO386=softfloat         XP CPUs without SSE2
::   CGO_ENABLED=1 CC=<gcc>  cgo build (needs an i686 gcc that runs on XP)
::   NOPAUSE=1               do not wait for a key at the end
:: ============================================================

set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"
set "DIST=%ROOT%\copy2xp"

if not exist "%ROOT%\src\make.bat" (
    echo [ERROR] src\make.bat not found. Run this script from the go-legacy-winxp root.
    goto :fail
)

if /i "%~1"=="assemble" goto :assemble

echo.
echo [1/3] Building the windows/386 toolchain ^(host and target arch are both 386^) ...
echo       This takes roughly 5-15 minutes.
echo.

:: A previous copy2xp must not exist while building: cmd/internal/moddeps
:: walks the whole GOROOT and trips over the duplicated package tree.
if exist "%DIST%" rmdir /s /q "%DIST%"
if exist "%DIST%" (
    echo [ERROR] Could not remove "%DIST%". Close anything using it and retry.
    goto :fail
)

set "GOOS=windows"
set "GOARCH=386"
set "GOHOSTARCH=386"
set "GOTOOLCHAIN=local"
if not defined CGO_ENABLED set "CGO_ENABLED=0"

pushd "%ROOT%\src"
call make.bat
set "MAKEERR=%ERRORLEVEL%"
popd
if not "%MAKEERR%"=="0" (
    echo.
    echo [ERROR] make.bat failed with code %MAKEERR%.
    echo         If bootstrap selection failed, set GOROOT_BOOTSTRAP to a Go tree 1.24.6 or newer.
    goto :fail
)

:: Verify that the result is a 386 *host* toolchain, not merely a 386 target.
set "GOROOT=%ROOT%"
set "GOOS="
set "GOARCH="
set "GOHOSTARCH="
"%ROOT%\bin\go.exe" version > "%TEMP%\goxp_version.txt" 2>&1
if errorlevel 1 (
    echo [ERROR] The freshly built bin\go.exe does not run:
    type "%TEMP%\goxp_version.txt"
    goto :fail
)
findstr /C:"windows/386" "%TEMP%\goxp_version.txt" >nul
if errorlevel 1 (
    echo [ERROR] bin\go.exe is not a windows/386 binary:
    type "%TEMP%\goxp_version.txt"
    echo         GOHOSTARCH=386 did not reach src\make.bat.
    goto :fail
)
echo [OK] 386 host toolchain built:
type "%TEMP%\goxp_version.txt"

:assemble
echo.
echo [2/3] Assembling copy2xp ...
if not exist "%ROOT%\bin\go.exe" (
    echo [ERROR] bin\go.exe not found. Run build-xp.bat without arguments first.
    goto :fail
)
if not exist "%ROOT%\pkg\tool\windows_386\compile.exe" (
    echo [ERROR] pkg\tool\windows_386 is missing.
    echo         The last build produced host tools for another architecture.
    echo         Re-run build-xp.bat without arguments.
    goto :fail
)

if exist "%DIST%" rmdir /s /q "%DIST%"
if exist "%DIST%" (
    echo [ERROR] Could not remove "%DIST%". Close anything using it and retry.
    goto :fail
)
mkdir "%DIST%" || goto :fail

:: Only the top-level go.exe/gofmt.exe belong in bin\. A stale bin\windows_386
:: left over from an old cross build must not be shipped.
mkdir "%DIST%\bin" || goto :fail
copy /Y "%ROOT%\bin\go.exe" "%DIST%\bin\" >nul || goto :fail
copy /Y "%ROOT%\bin\gofmt.exe" "%DIST%\bin\" >nul || goto :fail

xcopy /E /I /Y /Q "%ROOT%\pkg\tool\windows_386" "%DIST%\pkg\tool\windows_386" >nul || goto :fail
if exist "%ROOT%\pkg\include" xcopy /E /I /Y /Q "%ROOT%\pkg\include" "%DIST%\pkg\include" >nul
if exist "%ROOT%\lib" xcopy /E /I /Y /Q "%ROOT%\lib" "%DIST%\lib" >nul
robocopy "%ROOT%\src" "%DIST%\src" /E /NFL /NDL /NJH /NJS /NP /XD testdata .git .workbuddy >nul
if errorlevel 8 goto :fail
if exist "%ROOT%\VERSION" copy /Y "%ROOT%\VERSION" "%DIST%\" >nul
if exist "%ROOT%\go.env" copy /Y "%ROOT%\go.env" "%DIST%\" >nul

:: --- setgo.bat: run this on the XP machine to set GOROOT/PATH ---
:: %%~dp0 stays literal here and expands on the XP machine.
> "%DIST%\setgo.bat" echo @echo off
>> "%DIST%\setgo.bat" echo set "GOROOT=%%~dp0"
>> "%DIST%\setgo.bat" echo set "PATH=%%~dp0bin;%%PATH%%"
>> "%DIST%\setgo.bat" echo echo GOROOT=%%GOROOT%%
>> "%DIST%\setgo.bat" echo echo PATH updated, go is ready.

:: --- README ---
> "%DIST%\README.txt" echo Windows XP Go toolchain (windows/386)
>> "%DIST%\README.txt" echo Built by build-xp.bat from go-legacy-winxp.
>> "%DIST%\README.txt" echo.
>> "%DIST%\README.txt" echo Usage on the XP machine:
>> "%DIST%\README.txt" echo   1. Copy this whole folder anywhere, for example C:\go
>> "%DIST%\README.txt" echo   2. Open cmd and run:   C:\go\setgo.bat
>> "%DIST%\README.txt" echo   3. go version   should print: go1.27.4 windows/386
>> "%DIST%\README.txt" echo.
>> "%DIST%\README.txt" echo Notes:
>> "%DIST%\README.txt" echo   - bin\go.exe is a 32-bit host toolchain and matches
>> "%DIST%\README.txt" echo     pkg\tool\windows_386. Do not mix it with an amd64 bin.
>> "%DIST%\README.txt" echo   - Self-hosted: no other Go installation is needed on XP.
>> "%DIST%\README.txt" echo   - Linked programs get PE OS/subsystem version 5.1 (Windows XP).
>> "%DIST%\README.txt" echo   - Vista+ exports resolved at run time are shimmed,
>> "%DIST%\README.txt" echo     for example GetTickCount64 and ucrtbase.dll.
>> "%DIST%\README.txt" echo     Set GODEBUG=xpapi=1 to log unresolved exports.
>> "%DIST%\README.txt" echo   - Built with CGO_ENABLED=0 by default. For cgo set
>> "%DIST%\README.txt" echo     CGO_ENABLED=1 and CC to an i686 gcc that runs on XP.
>> "%DIST%\README.txt" echo   - If the CPU lacks SSE2, rebuild with GO386=softfloat.

echo [OK] copy2xp assembled.

echo.
echo [3/3] Verifying copy2xp ...
set "GOROOT=%DIST%"
set "GOOS="
set "GOARCH="
"%DIST%\bin\go.exe" env GOTOOLDIR > "%TEMP%\goxp_tooldir.txt" 2>&1
if errorlevel 1 (
    echo [ERROR] copy2xp\bin\go.exe does not run:
    type "%TEMP%\goxp_tooldir.txt"
    goto :fail
)
set /p "TOOLDIR=" < "%TEMP%\goxp_tooldir.txt"
if not exist "%TOOLDIR%\compile.exe" (
    echo [ERROR] copy2xp is inconsistent: GOTOOLDIR="%TOOLDIR%" has no compile.exe.
    echo         bin\go.exe and pkg\tool must agree on the host architecture.
    goto :fail
)
echo [OK] copy2xp is self-consistent: %TOOLDIR%

echo.
echo Checking PE headers (expect OS 5.1 and Subsystem 5.1) ...
set "PY="
where python >nul 2>nul
if not errorlevel 1 set "PY=python"
if not defined PY (
    where python3 >nul 2>nul
    if not errorlevel 1 set "PY=python3"
)
if not defined PY (
    echo [WARN] python not found - PE header check skipped.
    goto :done
)
call :write_pecheck
"%PY%" "%TEMP%\goxp_pecheck.py" "%DIST%\bin\go.exe" "%DIST%\bin\gofmt.exe" "%DIST%\pkg\tool\windows_386\compile.exe" "%DIST%\pkg\tool\windows_386\link.exe"
if errorlevel 1 (
    echo [ERROR] PE header check failed - binaries may not run on Windows XP.
    goto :fail
)
echo [OK] PE 5.1 headers verified.

:done
echo.
echo ============================================================
echo  copy2xp is ready: %DIST%
echo  Copy the WHOLE folder to the XP machine (for example C:\go),
echo  run setgo.bat there, then use go as usual.
echo ============================================================
if "%NOPAUSE%"=="" pause
exit /b 0

:fail
echo.
if "%NOPAUSE%"=="" pause
exit /b 1

:write_pecheck
> "%TEMP%\goxp_pecheck.py" echo import sys
>> "%TEMP%\goxp_pecheck.py" echo ok=True
>> "%TEMP%\goxp_pecheck.py" echo for path in sys.argv[1:]:
>> "%TEMP%\goxp_pecheck.py" echo     d=open(path,'rb').read(4096)
>> "%TEMP%\goxp_pecheck.py" echo     pe=int.from_bytes(d[0x3c:0x40],'little')
>> "%TEMP%\goxp_pecheck.py" echo     if d[pe:pe+4]!=b'PE'+bytes([0,0]):
>> "%TEMP%\goxp_pecheck.py" echo         print('FAIL: not a PE file: '+path)
>> "%TEMP%\goxp_pecheck.py" echo         ok=False
>> "%TEMP%\goxp_pecheck.py" echo         continue
>> "%TEMP%\goxp_pecheck.py" echo     o=pe+24
>> "%TEMP%\goxp_pecheck.py" echo     osv=int.from_bytes(d[o+40:o+42],'little')
>> "%TEMP%\goxp_pecheck.py" echo     osmin=int.from_bytes(d[o+42:o+44],'little')
>> "%TEMP%\goxp_pecheck.py" echo     sub=int.from_bytes(d[o+48:o+50],'little')
>> "%TEMP%\goxp_pecheck.py" echo     submin=int.from_bytes(d[o+50:o+52],'little')
>> "%TEMP%\goxp_pecheck.py" echo     print(path+': OS='+str(osv)+'.'+str(osmin)+' Subsystem='+str(sub)+'.'+str(submin))
>> "%TEMP%\goxp_pecheck.py" echo     if (osv,osmin,sub,submin)!=(5,1,5,1):
>> "%TEMP%\goxp_pecheck.py" echo         print('FAIL: expected PE 5.1 target for Windows XP')
>> "%TEMP%\goxp_pecheck.py" echo         ok=False
>> "%TEMP%\goxp_pecheck.py" echo if ok:
>> "%TEMP%\goxp_pecheck.py" echo     print('PE 5.1 check passed')
>> "%TEMP%\goxp_pecheck.py" echo sys.exit(0 if ok else 1)
goto :eof
