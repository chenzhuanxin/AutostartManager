@echo off
rem ============================================================
rem  恢复上次关闭的自启动项
rem  本文件可放在任意路径（含中文/空格），双击即可运行。
rem  使用 %~dp0 动态定位自身所在目录，无需任何手工改路径。
rem ============================================================
chcp 65001 >nul 2>&1
title 恢复自启动项
setlocal

set "SCRIPT_DIR=%~dp0"
set "APPLY_SCRIPT=%SCRIPT_DIR%Apply-Autostart.ps1"

if not exist "%APPLY_SCRIPT%" (
    echo.
    echo   [错误] 找不到 Apply-Autostart.ps1
    echo   请确认本 .bat 文件与 Apply-Autostart.ps1 在同一个文件夹内。
    echo   当前查找路径：%APPLY_SCRIPT%
    echo.
    pause
    exit /b 1
)

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

echo.
echo   正在恢复上次关闭的自启动项 ...
echo.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%APPLY_SCRIPT%" -Action Restore

echo.
echo   按任意键关闭窗口。
pause >nul
endlocal
