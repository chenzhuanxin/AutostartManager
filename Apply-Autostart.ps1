#Requires -Version 5.1
<#
    AutostartManager / Apply (关闭 + 恢复)
    --------------------------------------
    按 id 关闭 / 恢复自启动项。所有操作前先备份，并生成一键撤销脚本。

    用法：
      # 关闭
      powershell -ExecutionPolicy Bypass -File Apply-Autostart.ps1 -Action Disable -Ids rk_a1b2c3d4e5f6

      # 恢复全部（读取最近一次备份）
      powershell -ExecutionPolicy Bypass -File Apply-Autostart.ps1 -Action Restore
      powershell -ExecutionPolicy Bypass -File Apply-Autostart.ps1 -Action Restore -Backup <备份文件>

    安全设计：
      * 白名单硬保护：即使传入 id 也不会去动"不可关闭"级别的项目。
      * 每次操作前自动写备份 JSON + 撤销 .ps1 + 撤销 .bat。
      * 注册表项不改动原键值，改用 StartupApproved 的"禁用"位，
        效果等同任务管理器里点"禁用"，删除注册表值会让用户彻底丢失配置。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Disable', 'Restore', 'Enable', 'List', 'ListBackups')]
    [string]$Action,

    [string[]]$Ids,

    [string]$Backup,
    [string]$ScanFile,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------- 路径无关性：脚本可放在任意目录（含中文/空格）----------
<#
    重要：绝对不要在 param 块的默认值里写 (Join-Path $PSScriptRoot ...)！
    param 默认值的求值时机早于脚本正文，且在部分调用方式下
    （-File、点源、被其它脚本 Import 等）$PSScriptRoot 仍为空字符串，
    于是 Join-Path 会抛出：
        Join-Path : 无法将参数绑定到参数"Path"，因为该参数为空字符串。
    因此所有依赖脚本目录的路径都必须放到正文里解析。
#>
$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = [System.AppDomain]::CurrentDomain.BaseDirectory }
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = $env:TEMP }

if ([string]::IsNullOrWhiteSpace($ScanFile)) { $ScanFile = Join-Path $ScriptRoot 'autostart.json' }

<#
    -Ids 参数归一化（重要）：
    powershell.exe -File 传参时 **不会** 按逗号切分数组，
    面板生成的命令是  -Ids rk_aaa,rk_bbb,rk_ccc  ，
    此时 $Ids 只会得到一个元素 "rk_aaa,rk_bbb,rk_ccc"，
    循环里一个 id 都匹配不上 → 命令静默失败。
    这里统一按 逗号/分号/空白 再切一次，两种传法都能正确工作。
#>
if ($Ids) {
    $__ids = New-Object System.Collections.Generic.List[string]
    foreach ($chunk in $Ids) {
        if ([string]::IsNullOrWhiteSpace($chunk)) { continue }
        foreach ($piece in ($chunk -split '[,\s;]+')) {
            $p = $piece.Trim().Trim('"').Trim("'")
            if (-not [string]::IsNullOrWhiteSpace($p)) { $__ids.Add($p) }
        }
    }
    $Ids = $__ids.ToArray()
}

<#
    备份目录选择策略：
      1) 默认放在脚本同级 backup\ —— 便于整个文件夹拷走时备份一起带走；
      2) 若脚本目录只读（例如放在 Program Files），自动回退到
         %LOCALAPPDATA%\AutostartManager\backup，保证功能不中断。

    注意：回退路径的"基目录"必须逐级兜底。在提权/受限会话里
    $env:LOCALAPPDATA 可能是空字符串，此时 Join-Path 会直接报
    "无法将参数绑定到参数 Path，因为该参数为空字符串"。
#>
function Get-SafeAppDataBase {
    # 注意：候选值里不能直接写 Join-Path，否则基路径为空时会先抛异常。
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($env:LOCALAPPDATA, $env:APPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($c)) { $cands.Add($c) }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $cands.Add((Join-Path $env:USERPROFILE 'AppData\Local'))
        $cands.Add($env:USERPROFILE)
    }
    foreach ($c in @($env:TEMP)) {
        if (-not [string]::IsNullOrWhiteSpace($c)) { $cands.Add($c) }
    }
    foreach ($c in $cands) {
        if (-not [string]::IsNullOrWhiteSpace($c)) { return $c }
    }
    return [System.IO.Path]::GetTempPath()
}

function Test-DirWritable([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        # 实际写一个探针文件，确认真的可写（只读目录 Test-Path 也会通过）
        $probe = Join-Path $Path ('.writetest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.File]::WriteAllText($probe, 'ok')
        return $true
    } catch {
        return $false
    }
}

function Resolve-BackupDir([string]$Preferred) {
    if (Test-DirWritable $Preferred) { return $Preferred }

    $base = Get-SafeAppDataBase
    $fallback = Join-Path $base 'AutostartManager\backup'
    if (Test-DirWritable $fallback) {
        Write-Host "  提示：脚本目录不可写，备份改用 $fallback" -ForegroundColor Yellow
        return $fallback
    }

    # 最后兜底：系统临时目录
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'AutostartManager\backup'
    if (Test-DirWritable $tmp) {
        Write-Host "  提示：脚本目录不可写，备份改用临时目录 $tmp" -ForegroundColor Yellow
        return $tmp
    }

    throw "找不到任何可写的备份目录（已尝试：$Preferred、$fallback、$tmp）"
}

$BackupDir = Resolve-BackupDir (Join-Path $ScriptRoot 'backup')

# StartupApproved 的"禁用/启用"标志位（与 Windows 任务管理器一致）
$FLAG_DISABLED = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
$FLAG_ENABLED  = [byte[]](2,0,0,0,0,0,0,0,0,0,0,0)

$SERVICE_START = @{ Enabled = 2; Disabled = 4 }   # 2=自动, 4=禁用

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Head([string]$t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

function Get-ScanEntries {
    if (-not (Test-Path -LiteralPath $ScanFile)) {
        throw "找不到扫描结果：$ScanFile（请先运行 Collect-Autostart.ps1）"
    }
    $raw = [System.IO.File]::ReadAllText($ScanFile, [System.Text.Encoding]::UTF8)
    $obj = $raw | ConvertFrom-Json
    return $obj.entries
}

#region ---------- 备份 ----------

function New-BackupFile {
    param([string]$Action, $Targets)

    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $BackupDir "autostart-$Action-$stamp.json"

    $rec = [ordered]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        computer  = $env:COMPUTERNAME
        user      = $env:USERNAME
        action    = $Action
        isAdmin   = (Test-IsAdmin)
        items     = @()
    }
    foreach ($t in $Targets) {
        $rec.items += [ordered]@{
            id           = $t.entry.id
            name         = $t.entry.name
            friendlyName = $t.entry.friendlyName
            type         = $t.entry.type
            kind         = $t.entry.kind
            key          = $t.entry.key
            valueName    = $t.entry.valueName
            command      = $t.entry.command
            filePath     = $t.entry.filePath
            scope        = $t.entry.scope
            risk         = $t.entry.risk
            prevEnabled  = [bool]$t.entry.enabled
            appliedVia   = $t.via
        }
    }
    [System.IO.File]::WriteAllText($path, ($rec | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function New-RestoreScripts {
    param([string]$BackupPath)

    $pairs = @(
        @{ file = Join-Path $BackupDir 'restore-last.ps1'; bat = Join-Path $BackupDir 'restore-last.bat' },
        @{ file = Join-Path $BackupDir ("restore-" + [IO.Path]::GetFileNameWithoutExtension($BackupPath) + '.ps1'); bat = $null }
    )

    foreach ($p in $pairs) {
        $content = @"
# 自动生成的撤销脚本 —— 恢复自启动项到关闭前的状态
# 备份文件：$BackupPath
`$ErrorActionPreference = 'Continue'
`$apply = Join-Path (Split-Path -Parent `$PSScriptRoot) 'Apply-Autostart.ps1'
if (-not (Test-Path `$apply)) { `$apply = Join-Path `$PSScriptRoot 'Apply-Autostart.ps1' }

Write-Host '正在恢复自启动项 ...' -ForegroundColor Cyan
& `$apply -Action Restore -Backup '$BackupPath'
Write-Host ''
Write-Host '恢复完成。按回车键关闭。' -ForegroundColor Green
`$null = Read-Host
"@
        [System.IO.File]::WriteAllText($p.file, $content, (New-Object System.Text.UTF8Encoding($true)))
    }

    $bat = Join-Path $BackupDir 'restore-last.bat'
    $batContent = @"
@echo off
chcp 65001 >nul
title 恢复自启动项
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-last.ps1"
"@
    [System.IO.File]::WriteAllText($bat, $batContent, (New-Object System.Text.UTF8Encoding($false)))
}

#endregion

#region ---------- 关闭 / 启用 ----------

function Set-StartupApproved {
    param([string]$Key, [string]$Category, [string]$Name, [string]$Scope, [byte[]]$Flag)

    $hive = if ($Scope -eq '当前用户' -or $Key -like 'HKCU*') { 'HKCU' } else { 'HKLM' }
    if ($Key -like 'HKLM*') { $hive = 'HKLM' }

    $sub = "SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Category"
    $reg = if ($hive -eq 'HKCU') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
    $k = $reg.CreateSubKey($sub)
    if (-not $k) { throw "无法打开注册表键 $hive\$sub" }
    $k.SetValue($Name, $Flag, [Microsoft.Win32.RegistryValueKind]::Binary)
    $k.Close()
}

function Invoke-DisableOne {
    param($entry, [switch]$DryRun)

    $via = ''
    switch ($entry.type) {
        'registry' {
            Set-StartupApproved -Key $entry.key -Category 'Run' -Name $entry.valueName -Scope $entry.scope -Flag $FLAG_DISABLED
            $via = 'StartupApproved\Run'
        }
        'startupfolder' {
            Set-StartupApproved -Key $entry.key -Category 'StartupFolder' -Name $entry.valueName -Scope $entry.scope -Flag $FLAG_DISABLED
            $via = 'StartupApproved\StartupFolder'
        }
        'scheduledtask' {
            Disable-ScheduledTask -TaskPath $entry.key -TaskName $entry.valueName -ErrorAction Stop | Out-Null
            $via = 'ScheduledTask'
        }
        'service' {
            $svc = Get-CimInstance Win32_Service -Filter ("Name='" + ($entry.valueName -replace "'", "''") + "'")
            if (-not $svc) { throw "找不到服务 $($entry.valueName)" }
            Set-Service -Name $entry.valueName -StartupType Disabled -ErrorAction Stop
            $via = 'Service'
        }
        default { throw "未知类型 $($entry.type)" }
    }
    return $via
}

function Invoke-EnableOne {
    param($entry)

    switch ($entry.type) {
        'registry' {
            Set-StartupApproved -Key $entry.key -Category 'Run' -Name $entry.valueName -Scope $entry.scope -Flag $FLAG_ENABLED
        }
        'startupfolder' {
            Set-StartupApproved -Key $entry.key -Category 'StartupFolder' -Name $entry.valueName -Scope $entry.scope -Flag $FLAG_ENABLED
        }
        'scheduledtask' {
            Enable-ScheduledTask -TaskPath $entry.key -TaskName $entry.valueName -ErrorAction Stop | Out-Null
        }
        'service' {
            Set-Service -Name $entry.valueName -StartupType Automatic -ErrorAction Stop
        }
    }
}

#endregion

#region ---------- 主流程 ----------

try {
    if ($Action -eq 'ListBackups') {
        Write-Head '备份列表'
        if (-not (Test-Path $BackupDir)) { Write-Host '（暂无备份）'; exit 0 }
        Get-ChildItem $BackupDir -Filter 'autostart-*.json' | Sort-Object LastWriteTime -Descending | ForEach-Object {
            Write-Host ("  {0}   {1}" -f $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $_.FullName)
        }
        exit 0
    }

    if ($Action -eq 'Restore') {
        Write-Head '恢复自启动项'

        $file = $Backup
        if (-not $file) {
            if (-not (Test-Path $BackupDir)) { throw '找不到 backup 目录，没有可恢复的备份。' }
            $latest = Get-ChildItem $BackupDir -Filter 'autostart-Disable-*.json' |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $latest) { throw '没有找到任何"关闭"操作的备份。' }
            $file = $latest.FullName
        }
        if (-not (Test-Path -LiteralPath $file)) { throw "备份文件不存在：$file" }

        $bk = ([System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
        Write-Host ("备份时间：{0}    条目数：{1}" -f $bk.createdAt, @($bk.items).Count)

        $ok = 0; $skip = 0; $fail = 0
        foreach ($it in $bk.items) {
            try {
                if (-not $it.prevEnabled) { $skip++; continue }   # 原本就是禁用的，不动
                $obj = [pscustomobject]@{
                    id = $it.id; name = $it.name; type = $it.type; kind = $it.kind
                    key = $it.key; valueName = $it.valueName; scope = $it.scope
                    command = $it.command; filePath = $it.filePath
                }
                Invoke-EnableOne -entry $obj
                $ok++
                Write-Host ("  [恢复] {0}" -f ($it.friendlyName, $it.name -ne $null)[0]) -ForegroundColor Green
            } catch {
                $fail++
                Write-Host ("  [失败] {0} —— {1}" -f $it.name, $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        Write-Host ''
        Write-Host ("恢复完成：成功 {0} / 跳过 {1} / 失败 {2}" -f $ok, $skip, $fail) -ForegroundColor Green
        if ($fail -gt 0 -and -not (Test-IsAdmin)) {
            Write-Host '部分失败可能是因为权限不足，请用管理员身份重跑。' -ForegroundColor Yellow
        }
        exit 0
    }

    # ---- Disable / Enable / List ----
    $entries = Get-ScanEntries

    if ($Action -eq 'List') {
        $entries | ForEach-Object {
            "{0,-12} {1,-10} {2,-9} {3}" -f $_.id, $_.risk, $_.kind, $_.name
        }
        exit 0
    }

    if (-not $Ids -or $Ids.Count -eq 0) { throw '需要提供 -Ids 参数。' }

    # 建立索引
    $map = @{}
    foreach ($e in $entries) { $map[$e.id] = $e }

    $targets = New-Object System.Collections.ArrayList
    $unknown = New-Object System.Collections.ArrayList
    $blocked = New-Object System.Collections.ArrayList

    foreach ($id in $Ids) {
        $id = $id.Trim()
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (-not $map.ContainsKey($id)) { [void]$unknown.Add($id); continue }
        $e = $map[$id]

        # 硬保护：不可关闭级别一律拒绝
        if ($e.risk -eq 'critical' -and $Action -eq 'Disable') {
            [void]$blocked.Add($e)
            continue
        }
        # 计划任务 / 服务额外确认（防误操作）
        if ($Action -eq 'Disable' -and ($e.type -eq 'scheduledtask' -or $e.type -eq 'service') -and -not $DryRun) {
            # 由调用方显式传入即可，不改行为，仅记录
        }
        [void]$targets.Add([pscustomobject]@{ entry = $e; via = '' })
    }

    Write-Head "执行 $Action"
    Write-Host ("目标 {0} 项 · 忽略未知 {1} 项 · 拒绝对不可关闭项操作 {2} 项" -f $targets.Count, $unknown.Count, $blocked.Count)

    foreach ($b in $blocked) {
        Write-Host ("  [保护] 已跳过不可关闭项：{0}" -f $b.name) -ForegroundColor Yellow
    }
    foreach ($u in $unknown) {
        Write-Host ("  [忽略] 未知 id：{0}" -f $u) -ForegroundColor DarkGray
    }

    if ($targets.Count -eq 0) { Write-Host '没有可执行的目标。' -ForegroundColor Yellow; exit 0 }

    if ($DryRun) {
        Write-Host ''
        Write-Host '[DryRun] 以下操作不会真正执行：' -ForegroundColor Magenta
        foreach ($t in $targets) {
            Write-Host ("  {0} -> {1} ({2})" -f $t.entry.name, $(if ($Action -eq 'Disable') { '禁用' } else { '启用' }), $t.entry.type)
        }
        exit 0
    }

    $needAdmin = ($targets | Where-Object { $_.entry.needsAdmin -or $_.entry.type -in @('scheduledtask','service') }).Count -gt 0
    if ($needAdmin -and -not (Test-IsAdmin)) {
        Write-Host ''
        Write-Host '提示：本次包含需要管理员权限的项目。请以管理员身份重新运行，否则这些项会失败。' -ForegroundColor Yellow
    }

    # 备份
    $backupPath = New-BackupFile -Action $Action -Targets $targets
    Write-Host "已备份到：$backupPath" -ForegroundColor Green

    # 执行
    $ok = 0; $fail = 0
    foreach ($t in $targets) {
        try {
            if ($Action -eq 'Disable') {
                $t.via = Invoke-DisableOne -entry $t.entry
            } else {
                Invoke-EnableOne -entry $t.entry
                $t.via = 'Enable'
            }
            $ok++
            $label = if ($t.entry.friendlyName) { $t.entry.friendlyName } else { $t.entry.name }
            Write-Host ("  [{0}] {1}" -f $(if ($Action -eq 'Disable') { '已关闭' } else { '已启用' }), $label) -ForegroundColor Green
        } catch {
            $fail++
            Write-Host ("  [失败] {0} —— {1}" -f $t.entry.name, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    # 重新写一次备份（补上实际使用的通道）
    try {
        $rec = ([System.IO.File]::ReadAllText($backupPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
        $i = 0
        foreach ($t in $targets) { $rec.items[$i].appliedVia = $t.via; $i++ }
        [System.IO.File]::WriteAllText($backupPath, ($rec | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }

    if ($Action -eq 'Disable') { New-RestoreScripts -BackupPath $backupPath }

    Write-Host ''
    Write-Host ("完成：成功 {0} / 失败 {1}" -f $ok, $fail) -ForegroundColor Green
    if ($Action -eq 'Disable') {
        Write-Host ''
        Write-Host '如需撤销，双击运行：' -ForegroundColor Yellow
        Write-Host ("  " + (Join-Path $BackupDir 'restore-last.bat')) -ForegroundColor Yellow
        Write-Host '也可以重新打开面板，选择对应项恢复。' -ForegroundColor DarkGray
    }
}
catch {
    Write-Host ''
    Write-Host ("错误：{0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($_.Exception.Message -match '管理员|权限|Access') {
        Write-Host '请以管理员身份重新运行 PowerShell 后重试。' -ForegroundColor Yellow
    }
    exit 1
}

#endregion
