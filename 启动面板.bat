@echo off
rem ============================================================
rem  开机自启动管理面板 —— 一键启动
rem  本文件可放在任意路径（含中文/空格），双击即可运行。
rem  使用 %~dp0 动态定位自身所在目录，无需任何手工改路径。
rem ============================================================
chcp 65001 >nul 2>&1
title 开机自启动管理面板
setlocal

rem %~dp0 末尾自带反斜杠，指向 .bat 所在目录
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Start-Panel.ps1"

if not exist "%PS_SCRIPT%" (
    echo.
    echo   [错误] 找不到 Start-Panel.ps1
    echo   请确认本 .bat 文件与 Start-Panel.ps1 在同一个文件夹内。
    echo   当前查找路径：%PS_SCRIPT%
    echo.
    pause
    exit /b 1
)

rem 优先使用完整的系统 PowerShell 路径，避免 PATH 异常
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

rem -File 的参数用引号包裹，兼容含空格/中文的路径
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo   脚本退出码：%RC%
    pause
)
endlocal
