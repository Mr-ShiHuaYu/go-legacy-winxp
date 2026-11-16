@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================
:: Deploy executables from the host into the Windows XP VM,
:: run a command there, and copy the log back next to this script.
::
:: Double-click: copies copy2xp\bin\*.exe to C:\go in the guest
:: and runs "go version" there, so you can confirm the freshly
:: built 386 toolchain actually runs on Windows XP.
::
:: Usage:
::   <this script> [sourceDir] [guestDir] [runCommand] [logName] [killImage] [waitSec]
::
:: Defaults:
::   sourceDir   %~dp0copy2xp\bin   (top-level *.exe and *.dll are copied)
::   guestDir    C:\go
::   runCommand  go version
::   logName     xp-vm.log          (written to C:\<logName> in the guest)
::   killImage   (empty)            run to completion
::   waitSec     12                 used only when killImage is set
::
:: Examples:
::   <this script>
::       toolchain smoke test: go version from copy2xp
::   <this script> "E:\xp-dll-audit\deploy" C:\xptest "xpprobe.exe" xpprobe.log
::   <this script> "E:\go\code\gf-webman" C:\gfwebman-test "main.exe" main.log main.exe 12
::       start the server, wait 12s, taskkill it, fetch the log
::
:: The one-line cmd arguments are baked into a guest runner .bat,
:: because this VMware Tools version mangles long command lines.
:: For whole directory trees use a VMware shared folder instead;
:: this script is meant for a few files.
:: ============================================================

set "VMRUN=C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"
set "VMX=D:\vmware machine\Windows XP Professional\Windows XP Professional.vmx"
set "GUEST_USER=Administrator"
set "GUEST_PASS=1qaz"

set "SOURCE_DIR=%~1"
if not defined SOURCE_DIR set "SOURCE_DIR=%~dp0copy2xp\bin"
set "DEST_DIR=%~2"
if not defined DEST_DIR set "DEST_DIR=C:\go"
set "RUN_CMD=%~3"
if not defined RUN_CMD set "RUN_CMD=go version"
set "LOG_NAME=%~4"
if not defined LOG_NAME set "LOG_NAME=xp-vm.log"
set "KILL_IMAGE=%~5"
set "WAIT_SEC=%~6"
if not defined WAIT_SEC set "WAIT_SEC=12"

set "LOG_GUEST=C:\%LOG_NAME%"
set "LOG_HOST=%~dp0%LOG_NAME%"
set "KILL_LOG_GUEST=C:\xp-vm-kill.log"
set "KILL_LOG_HOST=%~dp0xp-vm-kill.log"
set "RUNNER=%TEMP%\xp-vm-runner.bat"
set "KILLER=%TEMP%\xp-vm-kill.bat"

echo ========================================
echo  source : %SOURCE_DIR%
echo  guest  : %DEST_DIR%  (log %LOG_GUEST%)
echo  run    : %RUN_CMD%
echo  kill   : %KILL_IMAGE%
echo ========================================

if not exist "%VMRUN%" (
    echo [ERROR] vmrun not found: "%VMRUN%"
    goto :fail
)
if not exist "%VMX%" (
    echo [ERROR] virtual machine not found: "%VMX%"
    goto :fail
)
if not exist "%SOURCE_DIR%" (
    echo [ERROR] source directory not found: "%SOURCE_DIR%"
    echo         Build copy2xp first ^(build-xp.bat^) or pass a sourceDir argument.
    goto :fail
)

echo [1/6] Ensure %DEST_DIR% exists ...
"%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% runProgramInGuest "%VMX%" "C:\WINDOWS\system32\cmd.exe" "/c if not exist %DEST_DIR% mkdir %DEST_DIR%"
if errorlevel 1 (
    echo [ERROR] Cannot create "%DEST_DIR%". Is the VM running and VMware Tools active?
    goto :fail
)

echo [2/6] Copy executables ...
set "FOUND=0"
for %%F in ("%SOURCE_DIR%\*.exe") do (
    if exist "%%~fF" (
        echo   %%~nxF
        "%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% CopyFileFromHostToGuest "%VMX%" "%%~fF" "%DEST_DIR%\%%~nxF"
        if errorlevel 1 (
            echo   [ERROR] copy failed: %%~nxF
            goto :fail
        )
        set "FOUND=1"
    )
)
for %%F in ("%SOURCE_DIR%\*.dll") do (
    if exist "%%~fF" (
        echo   %%~nxF
        "%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% CopyFileFromHostToGuest "%VMX%" "%%~fF" "%DEST_DIR%\%%~nxF"
        if errorlevel 1 (
            echo   [ERROR] copy failed: %%~nxF
            goto :fail
        )
        set "FOUND=1"
    )
)
if "%FOUND%"=="0" (
    echo [ERROR] No .exe or .dll found in "%SOURCE_DIR%"
    goto :fail
)

echo [3/6] Stage the guest scripts ...
> "%RUNNER%" echo @echo off
>> "%RUNNER%" echo cd /d "%DEST_DIR%"
>> "%RUNNER%" echo set "GOROOT=%DEST_DIR%"
if defined KILL_IMAGE (
    rem start /b detaches and lets this script end immediately; the kill is
    rem done by a second script because cmd here does not survive past start.
    >> "%RUNNER%" echo start "" /b %RUN_CMD% ^> "%LOG_GUEST%" 2^>^&1
) else (
    >> "%RUNNER%" echo %RUN_CMD% ^> "%LOG_GUEST%" 2^>^&1
)
"%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% CopyFileFromHostToGuest "%VMX%" "%RUNNER%" "C:\xp-vm-runner.bat"
if errorlevel 1 (
    echo [ERROR] Cannot copy the runner to the guest.
    goto :fail
)
if defined KILL_IMAGE (
    > "%KILLER%" echo @echo off
    >> "%KILLER%" echo ping -n %WAIT_SEC% 127.0.0.1 ^>nul
    rem The program still holds %LOG_GUEST% as its stdout, so the kill log
    rem goes to its own file instead of appending to the program log.
    >> "%KILLER%" echo taskkill /f /im %KILL_IMAGE% ^> "%KILL_LOG_GUEST%" 2^>^&1
    "%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% CopyFileFromHostToGuest "%VMX%" "%KILLER%" "C:\xp-vm-kill.bat"
    if errorlevel 1 (
        echo [ERROR] Cannot copy the killer script to the guest.
        goto :fail
    )
)

echo [4/6] Clear the old guest log ...
"%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% runProgramInGuest "%VMX%" "C:\WINDOWS\system32\cmd.exe" "/c if exist %LOG_GUEST% del %LOG_GUEST%"

echo [5/6] Run ...
"%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% runProgramInGuest "%VMX%" -interactive -activeWindow "C:\WINDOWS\system32\cmd.exe" "/c C:\xp-vm-runner.bat"
if defined KILL_IMAGE (
    echo       letting it run for %WAIT_SEC%s, then taskkill %KILL_IMAGE% ...
    "%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% runProgramInGuest "%VMX%" -interactive -activeWindow "C:\WINDOWS\system32\cmd.exe" "/c C:\xp-vm-kill.bat"
)

echo [6/6] Fetch the log ...
if exist "%LOG_HOST%" del "%LOG_HOST%"
set "FETCHED=0"
for /L %%i in (1,1,5) do (
    if "!FETCHED!"=="0" (
        "%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% copyFileFromGuestToHost "%VMX%" "%LOG_GUEST%" "%LOG_HOST%" >nul 2>&1
        if not errorlevel 1 set "FETCHED=1"
    )
)
if "!FETCHED!"=="0" (
    echo [ERROR] Log not fetched: "%LOG_GUEST%"
    echo         The program may still be running; start it with a killImage argument.
    goto :fail
)
if defined KILL_IMAGE (
    if exist "%KILL_LOG_HOST%" del "%KILL_LOG_HOST%"
    for /L %%i in (1,1,3) do (
        if not exist "%KILL_LOG_HOST%" (
            "%VMRUN%" -T ws -gu %GUEST_USER% -gp %GUEST_PASS% copyFileFromGuestToHost "%VMX%" "%KILL_LOG_GUEST%" "%KILL_LOG_HOST%" >nul 2>&1
        )
    )
)

echo ---------- log ----------
type "%LOG_HOST%"
echo -------------------------
if defined KILL_IMAGE (
    if exist "%KILL_LOG_HOST%" (
        echo ---------- taskkill ----------
        type "%KILL_LOG_HOST%"
        echo -------------------------------
    )
)
echo ========================================
echo  Done. Log saved to %LOG_HOST%
echo ========================================
if "%NOPAUSE%"=="" pause
exit /b 0

:fail
echo.
if "%NOPAUSE%"=="" pause
exit /b 1
