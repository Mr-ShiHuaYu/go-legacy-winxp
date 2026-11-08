@echo off
chcp 65001
setlocal enabledelayedexpansion

REM ========== 请修改以下配置 ==========
set VMRUN="C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"
set VMX="G:\资料盘\vmwarre machine\Windows XP Professional\Windows XP Professional.vmx"
set GUEST_USER=Administrator
set GUEST_PASS=""

REM 主机源目录（所有需要复制的文件所在目录）
set SOURCE_DIR=E:\go\resources\go-sciter\xp\gopath\src\go-sciter-xp-test\bin
REM 虚拟机目标目录
set DEST_DIR=C:\bin
REM 虚拟机内日志文件路径
set LOG_GUEST=C:\bin\go-sciter-xp.log
REM 主机保存的日志文件名
set LOG_HOST=go-sciter-xp.log
REM 程序等待秒数
set WAIT_SEC=5

echo ========================================
echo 开始部署 XP 兼容版到 XP 虚拟机
echo ========================================

echo [1/6] 确保虚拟机内目标目录 %DEST_DIR% 存在...
%VMRUN% -T ws -gu %GUEST_USER% -gp %GUEST_PASS% runProgramInGuest %VMX% "C:\Windows\System32\cmd.exe" "/c if not exist ""%DEST_DIR%"" mkdir ""%DEST_DIR%"""
if errorlevel 1 (
    echo [错误] 创建目录失败，请检查 VMware Tools 是否运行
    pause
    exit /b 1
)
echo 目录已就绪.

echo [2/6] 复制文件到虚拟机 %DEST_DIR% ...
set COPY_OK=1
set FOUND_EXE=0
set EXE_NAME=

REM 先复制 bin 目录下所有的 .exe 文件
echo   扫描 %SOURCE_DIR% 中的 .exe 文件...
for %%F in ("%SOURCE_DIR%\*.exe") do (
    set "EXE_FILE=%%~nxF"
    echo   复制 !EXE_FILE! ...
    %VMRUN% -T ws -gu %GUEST_USER% -gp %GUEST_PASS% CopyFileFromHostToGuest %VMX% "%%~fF" "%DEST_DIR%\!EXE_FILE!"
    if errorlevel 1 (
        echo   [错误] 复制 !EXE_FILE! 失败
        set COPY_OK=0
    ) else (
        set FOUND_EXE=1
        REM 优先选择带 -xp 或 _xp 的 XP 兼容版 EXE 作为启动目标
        echo %%~nxF | findstr /i "xp" >nul 2>&1
        if not errorlevel 1 (
            set "EXE_NAME=!EXE_FILE!"
        )
        REM 如果还没选定，就用第一个找到的 exe
        if "!EXE_NAME!"=="" set "EXE_NAME=!EXE_FILE!"
    )
)

REM 再复制 sciter.dll
set "SCITER_DLL=%SOURCE_DIR%\sciter.dll"
if exist "%SCITER_DLL%" (
    echo   复制 sciter.dll ...
    %VMRUN% -T ws -gu %GUEST_USER% -gp %GUEST_PASS% CopyFileFromHostToGuest %VMX% "%SCITER_DLL%" "%DEST_DIR%\sciter.dll"
    if errorlevel 1 (
        echo   [错误] 复制 sciter.dll 失败
        set COPY_OK=0
    )
) else (
    echo   [警告] %SOURCE_DIR%\sciter.dll 不存在，跳过复制
)

if "%FOUND_EXE%"=="0" (
    echo [错误] 未找到任何 .exe 文件，请先构建项目
    pause
    exit /b 1
)

if "%COPY_OK%"=="0" (
    echo [错误] 部分文件复制失败，请检查共享文件夹或文件是否存在
    pause
    exit /b 1
)
echo 文件复制完成，将要启动的程序: %EXE_NAME%

echo [3/6] 删除虚拟机内旧日志文件 ...
%VMRUN% -T ws -gu %GUEST_USER% -gp %GUEST_PASS% runProgramInGuest %VMX% "C:\Windows\System32\cmd.exe" "/c if exist ""%LOG_GUEST%"" del ""%LOG_GUEST%"""

echo [4/6] 启动程序（工作目录=%DEST_DIR%，日志输出到 %LOG_GUEST%）...
%VMRUN% -T ws -gu %GUEST_USER% -gp %GUEST_PASS% runProgramInGuest %VMX% -interactive -activeWindow "C:\Windows\System32\cmd.exe" "/c cd /d "%DEST_DIR%" && "%EXE_NAME%" > "%LOG_GUEST%""

set RUN_EC=%ERRORLEVEL%
if %RUN_EC% neq 0 (
    echo [错误] 程序执行失败，exitcode=%RUN_EC%，正在拉取日志...
    goto :FETCH_LOG
)
echo 程序已启动.

rem echo [5/6] 等待程序运行 %WAIT_SEC% 秒 ...
rem timeout /t %WAIT_SEC% /nobreak

:FETCH_LOG
echo [5/6] 从虚拟机拷贝日志到主机当前目录 ...
%VMRUN% -T ws -gu %GUEST_USER% -gp %GUEST_PASS% copyFileFromGuestToHost %VMX% "%LOG_GUEST%" "%LOG_HOST%"
if errorlevel 1 (
    echo [警告] 拷贝日志失败，可能日志文件尚未生成（程序仍在运行或崩溃太快）
) else (
    echo 日志已保存到 %LOG_HOST%
    echo ---------- 日志内容 ----------
    if exist "%LOG_HOST%" type "%LOG_HOST%"
    echo ------------------------------
)

echo [6/6] 清理虚拟机内的临时日志文件 ...
%VMRUN% -T ws -gu %GUEST_USER% -gp %GUEST_PASS% runProgramInGuest %VMX% "C:\Windows\System32\cmd.exe" "/c if exist ""%LOG_GUEST%"" del ""%LOG_GUEST%"""

echo ========================================
echo 完成！
echo ========================================
pause