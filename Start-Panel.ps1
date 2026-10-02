#Requires -Version 5.1
<#
    AutostartManager / 一键入口
    ---------------------------
    1) 需要时自动请求管理员权限（UAC）
    2) 扫描自启动项
    3) 生成 HTML 面板
    4) 用默认浏览器打开面板

    用法：右键"使用 PowerShell 运行"，或双击 启动面板.bat
    可选参数：
      -NoElevate   不请求提权，以当前权限扫描（只读，能扫到绝大部分项）
      -SkipCollect 复用已有 autostart.json，只重新生成面板
#>

[CmdletBinding()]
param(
    [switch]$NoElevate,
    [switch]$SkipCollect
)

$ErrorActionPreference = 'Stop'

# ---------- 路径无关性：脚本可放在任意目录（含中文/空格）----------
<#
    注意：param 块的默认值里绝对不能写 (Join-Path $PSScriptRoot ...)。
    param 默认值在脚本正文之前求值，部分调用方式（-File / 点源）下
    $PSScriptRoot 仍为空字符串，Join-Path 会直接抛
    "无法将参数绑定到参数 Path，因为该参数为空字符串"。
#>
$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = [System.AppDomain]::CurrentDomain.BaseDirectory }
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = $env:TEMP }

# $env:SystemRoot 理论上总有值，但受限会话里可能为空 —— 兜一层避免 Join-Path 报错。
$sysRoot = $env:SystemRoot
if ([string]::IsNullOrWhiteSpace($sysRoot)) { $sysRoot = [System.IO.Path]::GetPathRoot($PSHOME) }
if ([string]::IsNullOrWhiteSpace($sysRoot)) { $sysRoot = 'C:\' }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 1. 提权 ----------
if (-not (Test-IsAdmin) -and -not $NoElevate) {
    Write-Host ''
    Write-Host '  开机自启动管理面板' -ForegroundColor Cyan
    Write-Host '  ----------------------------------------'
    Write-Host '  扫描计划任务与服务需要管理员权限，'
    Write-Host '  现在会弹出 UAC 窗口，请点击"是"。'
    Write-Host ''

    try {
        $psExe = Join-Path $sysRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $psExe)) { $psExe = 'powershell.exe' }

        <#
            用 -ArgumentList 的数组形式时，PowerShell 会用空格拼接参数，
            路径含空格（如 C:\My Tools\...）就会断成两个参数。
            因此这里把 -File 的值整体用双引号包成一个参数传入。
        #>
        $selfPath = Join-Path $ScriptRoot 'Start-Panel.ps1'
        $argList = @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-File', ('"' + $selfPath + '"')
        )
        # 透传已有开关
        if ($NoElevate)   { $argList += '-NoElevate' }
        if ($SkipCollect) { $argList += '-SkipCollect' }

        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs | Out-Null
        exit 0
    } catch {
        Write-Host '  提权被取消，将以当前权限继续（计划任务/服务可能扫描不全）。' -ForegroundColor Yellow
        Write-Host ''
    }
}

Write-Host ''
Write-Host '  ========================================' -ForegroundColor Cyan
Write-Host '   开机自启动管理面板 · 正在准备' -ForegroundColor Cyan
Write-Host '  ========================================' -ForegroundColor Cyan

$collector = Join-Path $ScriptRoot 'Collect-Autostart.ps1'
$builder   = Join-Path $ScriptRoot 'Build-Report.ps1'
$jsonPath  = Join-Path $ScriptRoot 'autostart.json'
$htmlPath  = Join-Path $ScriptRoot 'autostart-report.html'

foreach ($f in @($collector, $builder)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "  缺少必要文件：$f" -ForegroundColor Red
        Write-Host '  请确认脚本目录完整。' -ForegroundColor Red
        Read-Host '按回车退出'
        exit 1
    }
}

<#
    ---------- 编码自检（重要）----------
    Windows PowerShell 5.1 读取 .ps1 时，若文件没有 UTF-8 BOM，会按系统本地代码页
    （简体中文为 GBK/936）解析。本项目的脚本含大量中文字符串，一旦缺 BOM，
    中文会被解成乱码并直接引发语法错误。

    常见触发场景：用户用记事本/VSCode 改过脚本后另存为"UTF-8"（不带 BOM）。
    这里在运行前检测并自动补回 BOM，避免用户面对一堆莫名其妙的报错。
#>
function Repair-ScriptEncodingIfNeeded {
    param([string[]]$Paths)

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $noBom   = New-Object System.Text.UTF8Encoding($false)
    $repaired = @()

    foreach ($p in $Paths) {
        try {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            if ($hasBom) { continue }

            # 按 UTF-8 读入再带 BOM 写回；若不合法则按 GBK 兜底读取
            $text = ''
            try {
                $text = $noBom.GetString($bytes)
            } catch {
                $text = [System.Text.Encoding]::GetEncoding(936).GetString($bytes)
            }
            [System.IO.File]::WriteAllText($p, $text, $utf8Bom)
            $repaired += (Split-Path -Leaf $p)
        } catch {
            # 单个文件修复失败不阻断主流程
        }
    }
    return $repaired
}

$allScripts = @(
    (Join-Path $ScriptRoot 'Collect-Autostart.ps1'),
    (Join-Path $ScriptRoot 'Build-Report.ps1'),
    (Join-Path $ScriptRoot 'Apply-Autostart.ps1'),
    (Join-Path $ScriptRoot 'Start-Panel.ps1'),
    (Join-Path $ScriptRoot 'Restore-Last.ps1')
)
$fixed = Repair-ScriptEncodingIfNeeded -Paths $allScripts
if ($fixed.Count -gt 0) {
    Write-Host ''
    Write-Host ("  已自动修复脚本编码（补回 UTF-8 BOM）：{0}" -f ($fixed -join ', ')) -ForegroundColor Yellow
}

# ---------- 2. 扫描 ----------
if (-not $SkipCollect) {
    & $collector -OutputPath $jsonPath
    if ($LASTEXITCODE -ne 0 -and -not (Test-Path $jsonPath)) {
        Write-Host '  扫描失败。' -ForegroundColor Red
        Read-Host '按回车退出'
        exit 1
    }
} else {
    Write-Host '  已跳过扫描，复用现有 autostart.json' -ForegroundColor Yellow
}

# ---------- 3. 生成面板 ----------
& $builder -InputPath $jsonPath -OutputPath $htmlPath

if (-not (Test-Path -LiteralPath $htmlPath)) {
    Write-Host '  生成面板失败。' -ForegroundColor Red
    Read-Host '按回车退出'
    exit 1
}

# ---------- 4. 打开面板 ----------
Write-Host ''
Write-Host "  面板已生成：$htmlPath" -ForegroundColor Green
Write-Host '  正在用浏览器打开 ...' -ForegroundColor Green

try { Start-Process $htmlPath } catch {
    Write-Host '  自动打开失败，请手动双击该 HTML 文件。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  关闭操作方式：在面板里勾选 → 点"立即关闭选中项" → 复制命令' -ForegroundColor DarkGray
Write-Host '  然后在本文件夹打开 PowerShell 粘贴执行即可' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  撤销方式：双击 backup\restore-last.bat' -ForegroundColor DarkGray
Write-Host ''
