#Requires -Version 5.1
<#
    恢复上次关闭的自启动项
    ----------------------
    等价于双击 backup\restore-last.bat，但本脚本放在项目根目录，
    适用于想从 PowerShell 直接执行的场景。

    用法（在项目所在目录打开 PowerShell）：
      powershell -ExecutionPolicy Bypass -File .\Restore-Last.ps1

    路径无关性：使用 $PSScriptRoot 定位同级脚本，整个文件夹可放任意位置。
#>

$ErrorActionPreference = 'Continue'

# $PSScriptRoot 在本脚本被 -File 调用时指向脚本所在目录；
# 若为空（极少数被 pipeline 执行的场景），回退到当前工作目录。
$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }

$apply = Join-Path $root 'Apply-Autostart.ps1'
if (-not (Test-Path -LiteralPath $apply)) {
    Write-Host ''
    Write-Host "  [错误] 找不到 Apply-Autostart.ps1" -ForegroundColor Red
    Write-Host "  预期位置：$apply" -ForegroundColor Red
    Write-Host '  请确认本脚本与 Apply-Autostart.ps1 在同一个文件夹内。' -ForegroundColor Red
    Write-Host ''
    Read-Host '按回车退出'
    exit 1
}

Write-Host ''
Write-Host '  正在恢复上次关闭的自启动项 ...' -ForegroundColor Cyan
Write-Host ''
& $apply -Action Restore
Write-Host ''
Read-Host '按回车退出'
