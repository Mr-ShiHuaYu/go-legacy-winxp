@echo off
setlocal EnableExtensions

:: ============================================================
:: build-xp.bat -- build the windows/386 (Windows XP) toolchain
:: from this go-backports tree and assemble a self-contained
:: "copy2xp" folder that can be copied to an XP machine as-is.
::
:: This script ONLY builds the XP (windows/386) target.
:: It never builds or restores any host (amd64) toolchain.
::
:: Usage:
::   build-xp.bat            full 386 build + assemble copy2xp
::   build-xp.bat assemble   skip the build, only (re)build the
::                           copy2xp folder from existing output
::
:: Note: the 386 build REPLACES bin\go.exe and pkg\tool\ with 386
:: versions (go1.20 installs cross targets straight into bin\).
:: To get the amd64 toolchain back, rebuild without GOARCH later.
::
:: Optional (set these in the environment before running):
::   GO386=softfloat    for XP CPUs without SSE2 (slower but safer)
::   CGO_ENABLED=1      build with cgo (needs an i686 mingw gcc)
::   CC=<path to gcc>   C compiler used by cgo
::
:: NOTE: the copy2xp folder is wiped and regenerated on every run.
:: ============================================================

set "ROOT=%~dp0"
cd /d "%ROOT%"

if not exist "%ROOT%src\make.bat" (
    echo [ERROR] src\make.bat not found. Run this script from the go-backports root.
    goto :fail
)

if /i "%~1"=="assemble" goto :assemble

echo.
echo [1/2] Building windows/386 toolchain with all.bat (build + full tests) ...
echo       (this takes roughly 30-60 minutes)
echo.

:: Remove the previous copy2xp folder BEFORE building/testing:
:: cmd/internal/moddeps walks the whole GOROOT and would trip over the
:: duplicated package tree inside copy2xp ("ambiguous import" failures).
:: It is regenerated fresh in the assemble phase below.
set "DIST=%ROOT%copy2xp"
if exist "%DIST%" rmdir /s /q "%DIST%"
if exist "%DIST%" (
    echo [ERROR] Could not remove the old copy2xp folder. Close any program using it and retry.
    goto :fail
)

pushd "%ROOT%src"
set "GOOS=windows"
set "GOARCH=386"
if not defined CGO_ENABLED set "CGO_ENABLED=0"
call make.bat
set "MAKEERR=%ERRORLEVEL%"
popd
if not "%MAKEERR%"=="0" (
    echo.
    echo [ERROR] all.bat failed with code %MAKEERR%.
    goto :fail
)
if not exist "%ROOT%bin\go.exe" (
    echo.
    echo [ERROR] bin\go.exe not found after build.
    goto :fail
)
echo.
echo [OK] windows/386 toolchain built.

:assemble
echo.
echo [2/2] Assembling copy2xp folder ...
set "DIST=%ROOT%copy2xp"
if exist "%DIST%" rmdir /s /q "%DIST%"
if exist "%DIST%" (
    echo [ERROR] Could not remove the old copy2xp folder. Close any program using it and retry.
    goto :fail
)
mkdir "%DIST%" || goto :fail

xcopy /E /I /Y /Q "%ROOT%bin" "%DIST%\bin" >nul || goto :fail
xcopy /E /I /Y /Q "%ROOT%pkg\tool\windows_386" "%DIST%\pkg\tool\windows_386" >nul || goto :fail
xcopy /E /I /Y /Q "%ROOT%pkg\include" "%DIST%\pkg\include" >nul || goto :fail
xcopy /E /I /Y /Q "%ROOT%lib" "%DIST%\lib" >nul || goto :fail
robocopy "%ROOT%src" "%DIST%\src" /E /NFL /NDL /NJH /NJS /NP /XD testdata .git .workbuddy >nul
if errorlevel 8 goto :fail
if exist "%ROOT%VERSION" copy /Y "%ROOT%VERSION" "%DIST%\" >nul
if exist "%ROOT%go.env" copy /Y "%ROOT%go.env" "%DIST%\" >nul

:: --- setgo.bat: run this on the XP machine to set GOROOT/PATH ---
> "%DIST%\setgo.bat" echo @echo off
>> "%DIST%\setgo.bat" echo set "GOROOT=%~dp0"
>> "%DIST%\setgo.bat" echo set "PATH=%%~dp0bin;%%PATH%%"
>> "%DIST%\setgo.bat" echo echo GOROOT=%%GOROOT%%
>> "%DIST%\setgo.bat" echo echo PATH updated, go is ready.

:: --- README ---
> "%DIST%\README.txt" echo Windows XP Go toolchain (windows/386)
>> "%DIST%\README.txt" echo Built by build-xp.bat from go-backports (release-branch.go1.20-nt51).
>> "%DIST%\README.txt" echo.
>> "%DIST%\README.txt" echo Usage on the XP machine:
>> "%DIST%\README.txt" echo   1. Copy this whole folder anywhere, e.g. C:\go
>> "%DIST%\README.txt" echo   2. Open cmd and run:   C:\go\setgo.bat
>> "%DIST%\README.txt" echo      (sets GOROOT and adds bin to PATH for that window)
>> "%DIST%\README.txt" echo   3. go version   should print go1.20 windows/386
>> "%DIST%\README.txt" echo.
>> "%DIST%\README.txt" echo Notes:
>> "%DIST%\README.txt" echo   - Self-hosted: no other Go installation is needed on XP.
>> "%DIST%\README.txt" echo   - Built with CGO_ENABLED=0. For cgo, set CGO_ENABLED=1 and
>> "%DIST%\README.txt" echo     CC to an i686-w64-mingw32 gcc that runs on XP.
>> "%DIST%\README.txt" echo   - If the CPU lacks SSE2, rebuild the toolchain with
>> "%DIST%\README.txt" echo     GO386=softfloat (see build-xp.bat).

echo [OK] copy2xp assembled.

echo.
echo Checking PE headers (expect OS 5.1 = Windows XP) ...
set "PY="
where python >nul 2>nul && set "PY=python"
if not defined PY where python3 >nul 2>nul && set "PY=python3"
if not defined PY (
    echo [WARN] python not found - skipped PE header check.
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
echo  Copy the WHOLE folder to the XP machine (e.g. as C:\go),
echo  then run setgo.bat inside it before using go.
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
