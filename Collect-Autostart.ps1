#Requires -Version 5.1
<#
    AutostartManager / Collector
    ----------------------------
    只读采集本机全部自启动项，输出 autostart.json 供 Report 生成 HTML 面板。

    设计约束（重要）：
      * 本脚本严格只读，不修改注册表、不删除文件、不改计划任务状态。
      * 所有采集动作包在 try/catch 内，单项失败不影响整体。
      * 关闭/恢复分区的注册表权限探测同样是只读的，用于在面板上提前告知用户
        "这一项关闭时会不会需要管理员权限"，避免用户点了没反应。

    用法：
      powershell -ExecutionPolicy Bypass -File Collect-Autostart.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ---------- 路径无关性 ----------
# 脚本可放在任意目录（含中文/空格），$PSScriptRoot 始终指向脚本自身所在目录。
$__root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($__root)) { $__root = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $__root 'autostart.json' }

# 输出目录若不存在则创建（支持 -OutputPath 指向任意位置）
$__outDir = Split-Path -Parent $OutputPath
if ($__outDir -and -not (Test-Path -LiteralPath $__outDir)) {
    New-Item -ItemType Directory -Path $__outDir -Force -ErrorAction SilentlyContinue | Out-Null
}

# 关闭/恢复脚本要调用的启动类型常量（提前写入 JSON，保证两侧一致）
$ServiceStartMap = @{ 'Auto' = 2; 'Manual' = 3; 'Disabled' = 4 }

#region ---------- 基础工具 ----------

$script:Notes = New-Object System.Collections.ArrayList

function Add-Note([string]$msg) {
    [void]$script:Notes.Add($msg)
}

function Get-PropValue {
    param($InputObject, [string]$Name)
    try {
        if ($null -eq $InputObject) { return $null }
        $p = $InputObject.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $null
    } catch { return $null }
}

<#
    路径/命令行解析
    从注册表值或任务 Action 中抽出真正的可执行文件与参数，
    用于判断文件是否存在、是否签名、是否为系统路径。
#>
$script:EnvCache = @{}
function Expand-EnvString([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    try {
        return [Environment]::ExpandEnvironmentVariables($s)
    } catch { return $s }
}

function Resolve-CommandPath([string]$raw) {
    <#  返回 @{ Path = '解析出的 exe 绝对路径'; Args = '参数部分'; Raw = 原始串 }  #>
    $res = @{ Path = ''; Args = ''; Raw = $raw }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $res }
    $s = Expand-EnvString $raw
    $s = $s.Trim()

    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -gt 1) {
            $res.Path = $s.Substring(1, $end - 1)
            $res.Args = $s.Substring($end + 1).Trim()
            return $res
        }
    }

    # 无引号：首个 .exe 结尾的 token 视为可执行文件
    $m = [regex]::Match($s, '^(.*?\.(?:exe|com|bat|cmd|vbs|ps1|lnk|dll))(\s|$)', 'IgnoreCase')
    if ($m.Success) {
        $res.Path = $m.Groups[1].Value.Trim()
        $res.Args = $s.Substring($m.Length).Trim()
    } else {
        $res.Path = $s
    }
    return $res
}

function Test-SystemPath([string]$path) {
    <# 是否位于受保护的系统级目录（C:\Windows 或 Program Files） #>
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    foreach ($c in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if ($path.StartsWith($c.TrimEnd('\') + '\', 'OrdinalIgnoreCase')) { return $true }
    }
    return $false
}

function Test-WindowsDir([string]$path) {
    <# 是否位于 C:\Windows 下（真正的系统目录，区别于 Program Files） #>
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    foreach ($c in @($env:SystemRoot, (Join-Path $env:SystemRoot 'System32'), (Join-Path $env:SystemRoot 'SysWOW64'))) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        if ($path.StartsWith($c.TrimEnd('\') + '\', 'OrdinalIgnoreCase')) { return $true }
    }
    return $false
}

function Get-SignatureInfo([string]$path) {
    <#  只读签名校验。返回 @{ Status='Valid'|'NotSigned'|'Unknown'|'Missing'; Signer='...' }  #>
    $out = @{ Status = 'Unknown'; Signer = '' }
    if ([string]::IsNullOrWhiteSpace($path)) { return $out }
    try {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $out.Status = 'Missing'
            return $out
        }
        $sig = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        switch ($sig.Status.ToString()) {
            'Valid' { $out.Status = 'Valid' }
            'NotSigned' { $out.Status = 'NotSigned' }
            default { $out.Status = $sig.Status.ToString() }
        }
        if ($sig.SignerCertificate) {
            # 从证书 Subject 里抽 CN，更易读
            $subj = $sig.SignerCertificate.Subject
            $m = [regex]::Match($subj, 'CN=([^,]+)')
            if ($m.Success) { $out.Signer = $m.Groups[1].Value.Trim().Trim('"') } else { $out.Signer = $subj }
        }
    } catch {
        $out.Status = 'Unknown'
    }
    return $out
}

function Get-FileMeta([string]$path) {
    $meta = @{ Exists = $false; Company = ''; Description = ''; Version = ''; SizeKB = 0 }
    if ([string]::IsNullOrWhiteSpace($path)) { return $meta }
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $meta.Exists = $true
            $fi = Get-Item -LiteralPath $path -ErrorAction Stop
            $meta.SizeKB = [math]::Round($fi.Length / 1KB, 0)
            $vi = $fi.VersionInfo
            if ($vi) {
                $meta.Company = [string]$vi.CompanyName
                $meta.Description = [string]$vi.FileDescription
                $meta.Version = [string]$vi.FileVersion
            }
        }
    } catch { }
    return $meta
}

function Get-ShortHash([string]$text) {
    try {
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12).ToLower()
    } catch {
        return ([Math]::Abs($text.GetHashCode())).ToString('x8')
    }
}

#endregion

#region ---------- 分类规则库 ----------

<#
    分类原则：宁可"建议保留"，也不要让用户关掉一个关了会出问题的东西。
    判级顺序：系统关键项 → 安全软件/驱动/输入法 → 明确可关的更新器 → 常规应用 → 未知。
#>

# 不可关闭：关掉会影响系统启动、登录、桌面、网络、硬件识别
# 注意：这里只放"精确条目名"。关键字匹配另见 $CriticalTokenRegex（按词匹配，避免误伤）。
$CriticalExact = @(
    'SecurityHealth', 'WindowsDefender', 'SecurityHealthSystray', 'WindowsSecurity',
    'OneDriveSetup', 'RTHDVCPL', 'RtHDVCpl', 'NvBackend', 'NVDisplay.ContainerLocalSystem',
    'igfxTray', 'HotKeysCmds', 'Persistence', 'CtxfiRes', 'CtxAudioService',
    'WinLogon', 'ctfmon', 'AudioService', 'RealtekAudio', 'SynTPEnh', 'SynTPHelper',
    'DellTouch', 'LPTouchService', 'SynTP', 'CplButtons', 'Apoint', 'ApMsgFwd',
    'WindowsDefenderSystray', 'MSConfig', 'rdpclip', 'explorer'
)

<#
    关键项词汇表：按"单词边界"匹配，而不是子串匹配。
    用子串匹配会让 RTHDVCPL→DVC、dt_app→app、AweSun→awesun、CCBCertificate→CBC
    这类完全无关的条目被误判成系统关键项，必须避免。
#>
$CriticalTokenRegex = '(?i)(?<![a-z0-9])(SecurityHealth|Windows\s*Defender|WinDefend|Realtek|NVIDIA|NvContainer|NvTelemetry|Synaptics|Elan\s*Touchpad|Intel\s*Graphics|IntelGraphics|igfxtray|VMware\s*Tools|vmtoolsd|VBoxTray|VirtualBox)(?![a-z0-9])'

# 开机自启的 Windows/微软系统项：一律不可关闭
$WindowsRunPatterns = @(
    '^MicrosoftEdgeAutoLaunch', '^Microsoft\s*OneDrive', '^OneDriveSetup', '^OneDrive',
    '^SecurityHealth', '^WindowsDefender', '^WindowsSecurity'
)

# 被 Windows 注册为"卸载/维护"入口的自启动项（Uninstall 条目等），也归入不可关闭
$MaintenancePatterns = @('^Uninstall\s', '^Uninstall_')

# 建议保留：解释器/终端/IM/安全软件/输入法/云盘 —— 关了会明显影响日常使用
$SuggestKeepExact = @(
    'WorkBuddy.WorkBuddy', 'WXWork', 'WeChat', 'Wechat', 'QQ', 'TIM', 'DingTalk', 'Feishu',
    'Lark', 'weixin', 'WeChatAppEx', 'BaiduPinyin', 'SogouPinyin', 'QQPinyin', 'baidupinyin',
    'Everything', 'FlowLauncher', 'PowerToys', 'powertoys', 'AutoHotkey', 'AutoHotkeyU64',
    'Microsoft.PowerShell', 'WindowsTerminal', 'Clash', 'Clash for Windows', 'v2rayN',
    'Xray', 'SangforService', 'Huawei', 'iFlyIME', 'Wox', 'Listary',
    # 远程控制 / 定时提醒 / AI 助手 / 网银安全组件：都是"关了立刻影响使用"的类型
    'AweSun', 'SunloginClient', 'Sunlogin', 'ToDesk', 'AnyDesk', 'TeamViewer', 'RustDesk',
    'MCClock', '梦畅闹钟', 'doubao', 'Doubao', 'com.qwen.work.cn', 'QwenWorkCN',
    'CCBCertificate', 'USBKeyTools.exe', 'InterPass3000_CCB', 'D4Svr_CCB.exe',
    'wdcertm_ccb', 'EsCcbUsbKeyTools', 'dt_app'
)

$SuggestKeepPatterns = @(
    'WorkBuddy', 'WXWork', 'WeChat', 'DingTalk', 'Feishu', 'Lark', 'Telegram', 'Discord',
    'BaiduPinyin', 'Sogou.*Pinyin', 'Pinyin', 'Everything', 'PowerToys', 'Listary',
    'Clash', 'v2ray', 'Shadowsocks', 'Wireguard', 'OpenVPN', 'Tailscale', 'ZeroTier',
    '安全', '杀毒', 'SecurityCenter', 'Antivirus', 'Kaspersky', 'Norton', 'McAfee', 'TrendMicro',
    '360Tray', '360Safe', 'QQPCTray', 'Huorong', '火绒', 'Bitdefender', 'Avast', '\bAVG\b',
    'ESET', '驱动', 'Synergy', 'Sangfor', '深信服', 'AnyDesk', 'TeamViewer',
    'ToDesk', 'SunloginClient', 'RustDesk', '向日葵', '输入法', '闹钟', '远程',
    # 网银 U 盾 / 证书中间件：关了网银 U 盾会认不到，属于"影响正常使用"
    'CCBComponents', 'USBKey', '证书', '网银', 'WatchData', 'Tendyron', 'FTSAFE', 'HDZB',
    # AI 助手 / 云盘 / 输入类：高频但非系统关键
    'Doubao', '豆包', 'Qwen', '通义', 'TencentDocs', 'BaiduNetdisk',
    # 开发环境/数据库：关掉会直接影响本机服务与调试
    'phpStudy', 'phpstudy', 'mysqld', 'mysql', 'BtSoft', 'site_total', 'nginx', 'apache',
    'redis', 'mongod', 'postgres', 'docker', 'wamp', 'xampp', '宝塔'
)

<#
    微软后台维护类任务：任务名/说明里出现这些词，一律判为"建议保留"。
    它们本来就被系统设计成空闲时运行，关掉的收益极小，却容易留下隐患。
#>
$MsBackgroundPatterns = @(
    'Update', 'Updater', 'Census', 'Ctf', 'Monitor', 'Smart', 'Retry', 'Space',
    'Sound', 'SQM', 'Telemetry', 'Feedback', 'Maps', 'Location', 'Speech', 'Cloud',
    'Cortana', 'Defrag', 'DiskFootprint', 'Registry', 'Compatibility', 'Uninstall',
    'Backup', 'Restore', 'Sync', 'Store', 'Push', 'Install', 'Windows', 'Microsoft',
    'WinSAT', 'Perf', 'Power', 'Battery', 'Family', 'Device', 'Account', 'License',
    'Activation', 'Diagnostic', 'Troubleshoot', 'Repair', 'Maintenance', 'Optimize',
    'Cleanup', 'Cache', 'Index', 'Search', 'Time', 'Zone', 'Font', 'D3D', 'DirectX',
    'Graphics', 'AppID', 'Shell', 'Explorer', 'Error', 'Reporting', 'Watson'
)

# 建议关闭：更新器、预加载器、剪贴板助手、纯营销/推广组件
$SuggestClosePatterns = @(
    'updater', 'Updater', 'UpdateTask', 'update_check', 'AutoUpdate', 'Squirrel',
    'GoogleUpdate', 'QuarkUpdater', 'AdobeGCInvoker', 'CreativeCloud',
    'pre-startup', 'PreStartup', 'prestartup', 'qb-pre-startup', 'AutoLaunch',
    'seclipboard', 'SogouExplorer', 'sesvc',
    '360huabao', 'QQBrowser', 'BaiduBrowser', 'baidubrowser',
    'booster', 'Speedup', 'GameCenter', '游戏中心',
    'TencentDocs', 'TencentMeetingHelper', 'PCManager',
    'BaiduNetdisk', 'baidunetdisk', '小米云', 'MiCloudService',
    'WPSUpdate', 'wpsupdate', 'Adobe', 'iTunes', 'Bonjour',
    'HPUsageTracking', 'hppusg', 'SnapDrop'
)

# 用途中文说明映射（关键字 → 说明）。按顺序匹配，第一条命中即返回，
# 所以强特征（品牌名、组件目录）必须排在弱特征（通用词）前面。
$FriendlyNameMap = @(
    # 网银 U 盾 / 证书中间件：目录特征最明确，优先判定
    @{ k = 'CCBComponents|CCBCertificate|USBKeyTools|InterPass3000|D4Svr_CCB|wdcertm_ccb|EsCcbUsbKeyTools|WatchData|Tendyron|FTSAFE|HDZB|DMWZ'
       n = '建设银行网银安全组件（U 盾 / 证书驱动）' }
    @{ k = 'SecurityHealth|WindowsDefender'; n = 'Windows 安全中心（杀毒防护状态托盘）' }
    @{ k = 'AweSun|Oray';                   n = '向日葵远程控制（可手机远程连本机）' }
    @{ k = 'RemoteCloudPC|远程云电脑';      n = '远程云电脑客户端' }
    @{ k = 'MCClock|梦畅闹钟';              n = '梦畅闹钟定时提醒' }
    @{ k = 'BaiduPinyin|baidupinyin';       n = '百度输入法' }
    @{ k = 'WXWork';                        n = '企业微信' }
    @{ k = 'WeChat|weixin';                 n = '微信' }
    @{ k = 'WorkBuddy';                     n = 'WorkBuddy 桌面端' }
    @{ k = 'com\.qwen\.work|QwenWorkCN';    n = '通义千问办公助手' }
    @{ k = '^doubao$|Doubao';               n = '豆包 AI 助手' }
    @{ k = 'SogouExplorer|seclipboard|sesvc'; n = '搜狗浏览器组件 / 剪贴板助手' }
    @{ k = 'QuarkUpdater|Quark';            n = '夸克浏览器更新服务' }
    @{ k = 'MicrosoftEdgeAutoLaunch';       n = 'Microsoft Edge 自启动预加载' }
    @{ k = 'HPUsageTracking|Hewlett|hppusg|HP UT'; n = '惠普打印 / 耗材使用统计组件' }
    @{ k = 'dt_app|PrintService';           n = '打印服务启动器' }
    # 只在"确实是 OneDrive"时贴这个名：必须同时出现 OneDrive 且不含 Uninstall
    @{ k = '^(?!.*Uninstall).*OneDrive';    n = '微软 OneDrive 同步盘' }
    @{ k = '^phpStudy';                     n = 'phpStudy 集成环境（Web 服务器）' }
    @{ k = '^mysql$|mysqld';                n = 'MySQL 数据库服务' }
    @{ k = 'site_total|BtSoft';             n = '宝塔 / 站点管理服务' }
    @{ k = '^MTXXService$';                 n = '美图秀秀后台服务' }
)

function Get-FriendlyName([string]$name, [string]$cmd) {
    $blob = "$name $cmd"
    foreach ($m in $FriendlyNameMap) {
        if ($blob -match $m.k) { return $m.n }
    }
    return ''
}

function Get-RiskLevel {
    <#  返回 @{ level='critical|keep|close|review'; reason='...'; advice='...' }  #>
    param(
        [string]$Name,
        [string]$Command,
        [string]$Source,     # Run | Run32 | RunOnce | StartupFolder | ScheduledTask | Service
        [bool]$IsMicrosoft,
        [bool]$PathIsSystem,
        [string]$Signer,
        [string]$Author = '',
        [string]$FilePath = ''   # 已解析出的可执行文件绝对路径，用于精确判定目录
    )

    $blob = "$Name $Command"
    $probePath = if ($FilePath) { $FilePath } else { $Command }

    # ---------- 步骤 1：明确不可关闭 ----------
    foreach ($c in $CriticalExact) {
        if ($Name -eq $c) {
            return @{ level = 'critical'; reason = '系统关键自启动项'; advice = '关闭后可能导致硬件、输入、安全防护或系统组件工作异常，请保持启用' }
        }
    }
    if ($blob -match $CriticalTokenRegex) {
        $hit = $Matches[0]
        return @{ level = 'critical'; reason = "系统/硬件厂商关键组件（$hit）"; advice = '属于系统或硬件驱动组件，关闭可能影响显示、声音、触控或防护，请保持启用' }
    }
    foreach ($p in $MaintenancePatterns) {
        if ($Name -match $p) {
            return @{ level = 'critical'; reason = '系统注册的卸载/维护入口'; advice = 'Windows 用于软件维护的注册项，删除或禁用可能导致软件无法正常卸载/更新，不建议关闭' }
        }
    }
    foreach ($p in $WindowsRunPatterns) {
        if ($Name -match $p) {
            return @{ level = 'critical'; reason = 'Windows / 微软官方自启动项'; advice = '系统自带组件，关闭可能影响浏览器、同步或安全状态显示，不建议关闭' }
        }
    }

    $isMsTask = ($Source -eq 'ScheduledTask' -and ($Author -match 'Microsoft' -or $IsMicrosoft))
    $isMsOwned = $IsMicrosoft -or $isMsTask

    # 微软/系统目录的项：计划任务与系统服务属于后台维护，注册表项属于系统组件
    if ($isMsOwned) {
        if ($Source -eq 'ScheduledTask') {
            foreach ($p in $MsBackgroundPatterns) {
                if ($blob -match $p) {
                    return @{ level = 'keep'; reason = 'Windows 自带的后台维护任务'; advice = '系统用于更新、诊断与维护，关闭收益极小且可能留下隐患，建议保留' }
                }
            }
            return @{ level = 'keep'; reason = '微软组件计划任务'; advice = '建议保留' }
        }
        if ($Source -eq 'Service') {
            return @{ level = 'keep'; reason = 'Windows 系统服务'; advice = '系统服务，建议保留' }
        }
        if ($PathIsSystem) {
            return @{ level = 'critical'; reason = '微软官方自启动项（位于系统目录）'; advice = 'Windows 组件，关闭可能影响系统功能，不建议关闭' }
        }
        # 微软签名的三方场景（如 Edge 自启）：不是系统关键，但属于高频浏览器，保留
        return @{ level = 'keep'; reason = '微软官方组件'; advice = '属于常用微软组件，关闭会让浏览器/同步功能需要手动启动，建议保留' }
    }

    # 在系统目录但非微软签名、且没有强保留特征 → 通常仍是安全/输入/驱动类，一律保留
    if ($PathIsSystem -and $Source -in @('Run', 'Run32', 'RunOnce', 'RunOnce32', 'StartupFolder')) {
        if (Test-WindowsDir $probePath) {
            return @{ level = 'keep'; reason = '位于 C:\Windows 系统目录'; advice = '系统组件，关闭风险大于收益，建议保留' }
        }
        return @{ level = 'keep'; reason = '安装在系统级目录（Program Files）'; advice = '系统级安装的应用组件，关闭风险大于收益，建议保留' }
    }

    # ---------- 步骤 2：建议保留 ----------
    foreach ($c in $SuggestKeepExact) {
        if ($Name -eq $c) {
            return @{ level = 'keep'; reason = '日常高频使用的软件或安全组件'; advice = '关闭后需要每次手动打开，建议保留' }
        }
    }
    foreach ($p in $SuggestKeepPatterns) {
        if ($blob -match $p) {
            return @{ level = 'keep'; reason = "属于高频工具 / 开发环境 / 安全类：$p"; advice = '关闭会影响开发服务或日常使用便利性，建议保留' }
        }
    }

    # ---------- 步骤 3：建议关闭（需同时命中"可关特征"且不是高频软件） ----------
    $closeHit = $null
    foreach ($p in $SuggestClosePatterns) {
        if ($blob -match $p) { $closeHit = $p; break }
    }
    if ($closeHit) {
        $why = '属于组件预加载 / 推广助手，后台常驻但收益很低'
        if ($blob -match 'updater|Updater|UpdateTask|AutoUpdate|update_check') {
            $why = '属于自动更新器，后台常驻占用资源；需要更新时手动打开软件即可'
        }
        elseif ($blob -match 'clipboard|Clipboard|剪贴板') {
            $why = '属于剪贴板助手类组件，非必需常驻'
        }
        elseif ($blob -match 'pre-startup|PreStartup|AutoLaunch|预启动') {
            $why = '属于"预启动加速"组件，实际会拖慢开机速度，收益很低'
        }
        elseif ($blob -match 'sesvc|360se|QQBrowser.*Service|BrowserService') {
            $why = '属于浏览器后台常驻服务，不打开浏览器时纯属占用资源'
        }
        if ($Source -eq 'Service') { $why += '（服务形式，关闭不会卸载软件）' }
        return @{ level = 'close'; reason = $why; advice = '可以安全关闭；关闭后软件功能不受影响，只是不再开机自动运行' }
    }

    # ---------- 步骤 4：待确认 ----------
    if ($blob -match '\\Temp\\|/Temp/|\\Users\\Public|AppData\\Local\\Temp') {
        return @{ level = 'review'; reason = '位于临时目录或用户可写目录'; advice = '可疑路径，建议先确认来源；可优先关闭并观察是否影响使用' }
    }
    $reason = '用途不明确'
    if ($Signer -and $Signer -notmatch 'Unknown') { $reason = "发行方：$Signer，用途不明确" }
    return @{ level = 'review'; reason = $reason; advice = '不确定时建议先保留；点开"详情"查看程序路径与发布者后再决定' }
}

#endregion

#region ---------- 权限探测（只读） ----------

<#
    测试当前账户对某个注册表键是否有"设置值"权限。
    只打开带 SetValue 请求的 RegistryKey，不写入任何数据。
#>
function Test-RegWriteAccess {
    param([string]$SubKey)

    $result = @{ hasKey = $false; canWrite = $false; needsAdmin = $false }
    $hiveMap = @{ 'HKLM' = [Microsoft.Win32.RegistryHive]::LocalMachine; 'HKCU' = [Microsoft.Win32.RegistryHive]::CurrentUser }

    try {
        $parts = $SubKey.Split('\', 2)
        $hiveName = $parts[0]
        $sub = $parts[1]
        if (-not $hiveMap.ContainsKey($hiveName)) { return $result }

        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveMap[$hiveName], [Microsoft.Win32.RegistryView]::Default)
        $k = $base.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::SetValue)
        if ($k) { $k.Close() } else { return $result }

        $result.hasKey = $true
        $result.canWrite = $true
    } catch [System.UnauthorizedAccessException] {
        $result.hasKey = $true
        $result.canWrite = $false
        $result.needsAdmin = $true
    } catch {
        # 键不存在或其它异常
    }
    return $result
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

#endregion

#region ---------- 采集：注册表 Run 键 ----------

$RunKeyDefs = @(
    @{ Key = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';        Source = 'Run';        Scope = '当前用户' }
    @{ Key = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';    Source = 'RunOnce';    Scope = '当前用户' }
    @{ Key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';        Source = 'Run';        Scope = '所有用户' }
    @{ Key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';    Source = 'RunOnce';    Scope = '所有用户' }
    @{ Key = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';     Source = 'Run32';  Scope = '所有用户(32位)' }
    @{ Key = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Source = 'RunOnce32'; Scope = '所有用户(32位)' }
)

# 取注册表根键。注意：[Microsoft.Win32.Registry]::HKCU 在 PowerShell 5.1 下为 $null，
# 必须用 OpenBaseKey 拿到句柄，否则调用 OpenSubKey 会抛"不能对 Null 值表达式调用方法"。
function Get-RegRoot([string]$HiveName) {
    $hive = if ($HiveName -eq 'HKLM') {
        [Microsoft.Win32.RegistryHive]::LocalMachine
    } else {
        [Microsoft.Win32.RegistryHive]::CurrentUser
    }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
}

# 用户在"任务管理器→启动"里做的启用/禁用，记录在 StartupApproved 下
# 二进制首字节：02/06 = 已启用，03 = 已禁用
function Get-ApprovedState([string]$Scope, [string]$Category, [string]$Name) {
    try {
        $hive = if ($Scope -eq '当前用户') { 'HKCU' } else { 'HKLM' }
        $sub = "SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Category"
        $base = Get-RegRoot $hive
        $k = $base.OpenSubKey($sub)
        if (-not $k) { return $null }
        $v = $k.GetValue($Name)
        $k.Close()
        $base.Close()
        if ($null -eq $v) { return $null }
        if ($v -is [byte[]] -and $v.Length -gt 0) {
            if ($v[0] -eq 3) { return 'disabled' }
            return 'enabled'
        }
        return $null
    } catch { return $null }
}

function Add-RunEntries {
    foreach ($def in $RunKeyDefs) {
        $hiveName = $def.Key.Split('\', 2)[0]
        $sub = $def.Key.Split('\', 2)[1]
        try {
            $base = Get-RegRoot $hiveName
            $k = $base.OpenSubKey($sub)
            if (-not $k) { $base.Close(); continue }

            $access = Test-RegWriteAccess -SubKey $def.Key

            foreach ($valueName in $k.GetValueNames()) {
                if ([string]::IsNullOrWhiteSpace($valueName)) { continue }
                $raw = [string]$k.GetValue($valueName)
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }

                $parsed = Resolve-CommandPath $raw
                $sig = Get-SignatureInfo $parsed.Path
                $meta = Get-FileMeta $parsed.Path
                $isMs = $false
                if ($sig.Signer -match 'Microsoft') { $isMs = $true }
                if ($sig.Signer -match 'Microsoft Corporation') { $isMs = $true }
                $pathSys = Test-SystemPath $parsed.Path

                $risk = Get-RiskLevel -Name $valueName -Command $raw -Source $def.Source `
                                      -IsMicrosoft $isMs -PathIsSystem $pathSys -Signer $sig.Signer -FilePath $parsed.Path

                $approved = Get-ApprovedState -Scope $def.Scope -Category 'Run' -Name $valueName
                $enabled = $true
                if ($approved -eq 'disabled') { $enabled = $false }

                $entry = [ordered]@{
                    id           = 'rk_' + (Get-ShortHash "$($def.Key)|$valueName")
                    type         = 'registry'
                    kind         = '注册表启动项'
                    source       = $def.Source
                    sourceLabel  = switch ($def.Source) {
                        'Run'         { '注册表 Run' }
                        'RunOnce'     { '注册表 RunOnce' }
                        'Run32'       { '注册表 Run(32位)' }
                        'RunOnce32'   { '注册表 RunOnce(32位)' }
                        default       { '注册表' }
                    }
                    key          = $def.Key
                    valueName    = $valueName
                    name         = $valueName
                    friendlyName = (Get-FriendlyName $valueName $raw)
                    command      = $raw
                    filePath     = $parsed.Path
                    args         = $parsed.Args
                    scope        = $def.Scope
                    enabled      = $enabled
                    approvedState = $approved
                    exists       = $meta.Exists
                    signer       = $sig.Signer
                    signStatus   = $sig.Status
                    company      = $meta.Company
                    description  = $meta.Description
                    version      = $meta.Version
                    sizeKB       = $meta.SizeKB
                    isSystemPath = $pathSys
                    needsAdmin   = [bool]$access.needsAdmin
                    risk         = $risk.level
                    riskReason   = $risk.reason
                    advice       = $risk.advice
                }
                $script:Entries.Add([pscustomobject]$entry)
            }
            $k.Close()
            $base.Close()
        } catch {
            Add-Note "读取注册表启动项失败：$($def.Key) —— $($_.Exception.Message)"
        }
    }
}

#endregion

#region ---------- 采集：启动文件夹 ----------

function Add-StartupFolderEntries {
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup');                              Scope = '当前用户'; Category = 'StartupFolder' }
        @{ Path = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'); Scope = '所有用户'; Category = 'StartupFolder' }
    )
    foreach ($f in $folders) {
        try {
            if (-not (Test-Path -LiteralPath $f.Path)) { continue }
            $access = Test-RegWriteAccess -SubKey ("HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder")
            if ($f.Scope -eq '所有用户') {
                $access = Test-RegWriteAccess -SubKey ("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder")
            }

            foreach ($file in (Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue)) {
                if ($file.Name -eq 'desktop.ini') { continue }

                $target = $file.FullName
                $args = ''
                if ($file.Extension -ieq '.lnk') {
                    try {
                        $sh = New-Object -ComObject WScript.Shell
                        $lnk = $sh.CreateShortcut($file.FullName)
                        if ($lnk.TargetPath) { $target = $lnk.TargetPath }
                        $args = [string]$lnk.Arguments
                        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)
                    } catch { }
                }

                $sig = Get-SignatureInfo $target
                $meta = Get-FileMeta $target
                $isMs = ($sig.Signer -match 'Microsoft')
                $pathSys = Test-SystemPath $target
                $risk = Get-RiskLevel -Name $file.BaseName -Command $target -Source 'StartupFolder' `
                                      -IsMicrosoft $isMs -PathIsSystem $pathSys -Signer $sig.Signer -FilePath $target
                $approved = Get-ApprovedState -Scope $f.Scope -Category 'StartupFolder' -Name $file.Name
                $enabled = ($approved -ne 'disabled')

                $entry = [ordered]@{
                    id           = 'sf_' + (Get-ShortHash $file.FullName)
                    type         = 'startupfolder'
                    kind         = '启动文件夹'
                    source       = 'StartupFolder'
                    sourceLabel  = '启动文件夹'
                    key          = $f.Path
                    valueName    = $file.Name
                    name         = $file.BaseName
                    friendlyName = (Get-FriendlyName $file.BaseName $target)
                    command      = if ($args) { "`"$target`" $args" } else { "`"$target`"" }
                    filePath     = $target
                    args         = $args
                    scope        = $f.Scope
                    enabled      = $enabled
                    approvedState = $approved
                    exists       = $meta.Exists
                    signer       = $sig.Signer
                    signStatus   = $sig.Status
                    company      = $meta.Company
                    description  = $meta.Description
                    version      = $meta.Version
                    sizeKB       = $meta.SizeKB
                    isSystemPath = $pathSys
                    needsAdmin   = [bool]$access.needsAdmin
                    risk         = $risk.level
                    riskReason   = $risk.reason
                    advice       = $risk.advice
                }
                $script:Entries.Add([pscustomobject]$entry)
            }
        } catch {
            Add-Note "读取启动文件夹失败：$($f.Path) —— $($_.Exception.Message)"
        }
    }
}

#endregion

#region ---------- 采集：计划任务 / 服务 ----------

<#  与开机体验相关、值得展示的任务路径 + 关键字（其余任务量大且多为系统维护，不展示）  #>
$RelevantTaskPaths = @('\Microsoft\Windows\Application Experience', '\Microsoft\Windows\AppID',
    '\Microsoft\Windows\Autochk', '\Microsoft\Windows\CloudExperienceHost',
    '\Microsoft\Windows\Customer Experience Improvement Program', '\Microsoft\Windows\DiskFootprint',
    '\Microsoft\Windows\Explorer', '\Microsoft\Windows\Feedback', '\Microsoft\Windows\Location',
    '\Microsoft\Windows\Maps', '\Microsoft\Windows\Media Center', '\Microsoft\Windows\PI',
    '\Microsoft\Windows\PushToInstall', '\Microsoft\Windows\Shell',
    '\Microsoft\Windows\Speech', '\Microsoft\Windows\Windows Error Reporting',
    '\Microsoft\Windows\WindowsBackup', '\Microsoft\Windows\WindowsUpdate',
    '\Microsoft\Windows\Workplace Join', '\Microsoft\Windows\WwanSvc')

$RelevantTaskNamePatterns = @(
    'Update', 'Updater', 'UpdateTask', 'GoogleUpdate', 'Adobe', 'OneDrive', 'Edge',
    'Install', 'Adobe Acrobat', 'iTunes', 'Bonjour', 'WPS', 'Kingsoft',
    'MicrosoftEdge', 'Office', 'Creative Cloud', 'Dropbox', 'AdobeGC'
)

function Add-ScheduledTaskEntries {
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' }
    } catch {
        Add-Note "读取计划任务失败（可能权限不足）：$($_.Exception.Message)"
        return
    }

    $isAdmin = Test-IsAdmin

    foreach ($t in $tasks) {
        try {
            $authorRaw = [string]$t.Author
            $triggers = @($t.Triggers)
            $isBoot = $false
            foreach ($tr in $triggers) {
                $cname = $tr.CimClass.CimClassName
                if ($cname -eq 'MSFT_TaskLogonTrigger' -or $cname -eq 'MSFT_TaskBootTrigger') {
                    # LogonTrigger 带延迟或 S4U 的通常是计划/延迟任务，仍算登录触发
                    $isBoot = $true
                }
            }
            if (-not $isBoot) { continue }

            $path = [string]$t.TaskPath
            $inRelevantPath = $false
            foreach ($rp in $RelevantTaskPaths) {
                if ($path -like "$rp*") { $inRelevantPath = $true; break }
            }
            $nameMatch = $false
            foreach ($np in $RelevantTaskNamePatterns) {
                if ($t.TaskName -match $np) { $nameMatch = $true; break }
            }

            $action = @($t.Actions)[0]
            $exec = ''; $argStr = ''
            if ($action) {
                $exec = [string](Get-PropValue $action 'Execute')
                $argStr = [string](Get-PropValue $action 'Arguments')
            }
            # 没有可执行文件的纯 COM 处理器任务（MsCtfMonitor 等）无法评估，直接跳过
            if ([string]::IsNullOrWhiteSpace($exec)) { continue }

            # 归属判断优先看可执行文件的签名，而不是任务作者 —— 任务作者常常为空
            $parsed0 = Resolve-CommandPath $exec
            $sig0 = Get-SignatureInfo $parsed0.Path
            $exeIsMs = ($sig0.Signer -match 'Microsoft')
            $authorIsMs = ($authorRaw -match 'Microsoft') -or $path -like '\Microsoft\*'
            $ownedByMs = $exeIsMs -or ($authorIsMs -and [string]::IsNullOrWhiteSpace($sig0.Signer))

            # 只保留：① 非微软的第三方登录任务；② 微软路径下但属于"更新器"类、可安全关闭的任务
            $keepRow = $false
            if (-not $ownedByMs) { $keepRow = $true }
            elseif ($inRelevantPath -and $nameMatch -and -not $exeIsMs) { $keepRow = $true }
            if (-not $keepRow) { continue }

            $parsed = $parsed0
            $exePath = $parsed.Path
            if (-not $exePath -and $exec) { $exePath = $exec }
            $sig = $sig0
            $meta = Get-FileMeta $exePath
            $pathSys = Test-SystemPath $exePath
            $isMs = $exeIsMs

            $author = $authorRaw
            # 任务作者为空时，任务本身可能在 \Microsoft\ 路径下 —— 用路径兜底判断归属
            $authorIsMs = ($author -match 'Microsoft') -or ($path -like '\Microsoft\*')
            $risk = Get-RiskLevel -Name $t.TaskName -Command ("$exec $argStr") -Source 'ScheduledTask' `
                                  -IsMicrosoft $isMs -PathIsSystem $pathSys -Signer $sig.Signer -Author $author -FilePath $exePath

            $entry = [ordered]@{
                id           = 'tk_' + (Get-ShortHash ($t.TaskPath + $t.TaskName))
                type         = 'scheduledtask'
                kind         = '计划任务'
                source       = 'ScheduledTask'
                sourceLabel  = '计划任务(登录触发)'
                key          = $t.TaskPath
                valueName    = $t.TaskName
                name         = [string]$t.TaskName
                friendlyName = (Get-FriendlyName $t.TaskName "$exec $argStr")
                command      = (("$exec $argStr").Trim())
                filePath     = $exePath
                args         = $argStr
                scope        = if ($pathSys) { '系统' } else { '第三方' }
                author       = $author
                enabled      = $true
                approvedState = 'enabled'
                exists       = $meta.Exists
                signer       = $sig.Signer
                signStatus   = $sig.Status
                company      = $meta.Company
                description  = $meta.Description
                version      = $meta.Version
                sizeKB       = $meta.SizeKB
                isSystemPath = $pathSys
                needsAdmin   = (-not $isAdmin)
                risk         = $risk.level
                riskReason   = $risk.reason
                advice       = $risk.advice
            }
            $script:Entries.Add([pscustomobject]$entry)
        } catch {
            # 单个任务解析失败直接跳过
        }
    }
}

function Add-ServiceEntries {
    try {
        $svcs = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
                Where-Object { $_.StartMode -eq 'Auto' }
    } catch {
        Add-Note "读取服务失败：$($_.Exception.Message)"
        return
    }

    $isAdmin = Test-IsAdmin
    # 白名单：这些自动服务与"开机就有网/有声音/能登录"直接相关，绝不动
    $criticalSvcPatterns = @(
        'RpcSs', 'DcomLaunch', 'PlugPlay', 'Power', 'ProfSvc', 'Themes', 'AudioSrv', 'AudioEndpoint',
        'Dhcp', 'Dnscache', 'NlaSvc', 'netprofm', 'Winmgmt', 'EventLog', 'Schedule', 'gpsvc',
        'BrokerInfrastructure', 'SystemEventsBroker', 'CryptSvc', 'LanmanWorkstation', 'lmhosts',
        'Wcmsvc', 'WlanSvc', 'BFE', 'MpsSvc', 'WinDefend', 'SecurityHealthService', 'wscsvc',
        'LSM', 'SamSs', 'Spooler', 'UmRdpService', 'TermService', 'UserManager', 'StateRepository',
        'TextInputManagementService', 'CoreMessagingRegistrar', 'FontCache', 'nsi', 'NcbService',
        'ShellHWDetection', 'SysMain', 'TimeBrokerSvc', 'TrkWks', 'WpnService', 'WSearch',
        'DiagTrack', 'WerSvc', 'wuauserv', 'BITS', 'DoSvc', 'Cryptographic', 'DeviceInstall'
    )

    foreach ($s in $svcs) {
        try {
            $n = [string]$s.Name
            $skip = $false
            foreach ($cp in $criticalSvcPatterns) { if ($n -eq $cp) { $skip = $true; break } }
            if ($skip) { continue }

            # 只展示非微软/第三方自动服务，避免面板被系统服务淹没
            $pathName = [string]$s.PathName
            $parsed = Resolve-CommandPath $pathName
            $exePath = $parsed.Path
            $pathSys = Test-SystemPath $exePath
            $sig = Get-SignatureInfo $exePath
            $isMs = ($sig.Signer -match 'Microsoft')
            if ($isMs -or $pathSys) { continue }

            $meta = Get-FileMeta $exePath
            # 服务默认更保守：只有明确匹配更新器/推广类才建议关闭，其余一律建议保留
            $risk = Get-RiskLevel -Name $n -Command $pathName -Source 'Service' `
                                  -IsMicrosoft $isMs -PathIsSystem $pathSys -Signer $sig.Signer -FilePath $exePath
            if ($risk.level -in @('review', 'critical')) {
                $risk = @{ level = 'keep'; reason = '第三方自动服务'; advice = '服务改为手动可能导致依赖它的功能异常，建议保留' }
            }

            $startMap = @{ 'Auto' = 2; 'Manual' = 3; 'Disabled' = 4 }
            $entry = [ordered]@{
                id           = 'sv_' + (Get-ShortHash $n)
                type         = 'service'
                kind         = '自动服务'
                source       = 'Service'
                sourceLabel  = 'Windows 服务(自动)'
                key          = 'services'
                valueName    = $n
                name         = $n
                friendlyName = (Get-FriendlyName $n $pathName)
                command      = $pathName
                filePath     = $exePath
                args         = $parsed.Args
                scope        = '系统'
                displayName  = [string]$s.DisplayName
                description  = if ($meta.Description) { $meta.Description } else { [string]$s.Description }
                enabled      = $true
                approvedState = 'enabled'
                exists       = $meta.Exists
                signer       = $sig.Signer
                signStatus   = $sig.Status
                company      = $meta.Company
                version      = $meta.Version
                sizeKB       = $meta.SizeKB
                isSystemPath = $pathSys
                needsAdmin   = $true          # 改服务启动类型必须管理员
                risk         = $risk.level
                riskReason   = $risk.reason
                advice       = $risk.advice
            }
            $script:Entries.Add([pscustomobject]$entry)
        } catch { }
    }
}

#endregion

#region ---------- 主流程 ----------

$script:Entries = New-Object System.Collections.ArrayList

Write-Host '[1/5] 采集注册表启动项 ...' -ForegroundColor Cyan
Add-RunEntries

Write-Host '[2/5] 采集启动文件夹 ...' -ForegroundColor Cyan
Add-StartupFolderEntries

Write-Host '[3/5] 采集计划任务 ...' -ForegroundColor Cyan
Add-ScheduledTaskEntries

Write-Host '[4/5] 采集自动服务 ...' -ForegroundColor Cyan
Add-ServiceEntries

Write-Host '[5/5] 汇总输出 ...' -ForegroundColor Cyan

# 去重：同一文件路径 + 同一名称只保留一条（跨来源重复很常见）
$seen = @{}
$deduped = New-Object System.Collections.ArrayList
foreach ($e in ($script:Entries | Sort-Object @{e='risk';Descending=$false}, name)) {
    $k = "$($e.valueName)|$($e.filePath)"
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = $true
    [void]$deduped.Add($e)
}

$stats = [ordered]@{
    total    = $deduped.Count
    critical = @($deduped | Where-Object { $_.risk -eq 'critical' }).Count
    keep     = @($deduped | Where-Object { $_.risk -eq 'keep' }).Count
    close    = @($deduped | Where-Object { $_.risk -eq 'close' }).Count
    review   = @($deduped | Where-Object { $_.risk -eq 'review' }).Count
    enabled  = @($deduped | Where-Object { $_.enabled }).Count
}

$payload = [ordered]@{
    schemaVersion = 1
    generatedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    computer      = $env:COMPUTERNAME
    user          = $env:USERNAME
    osCaption     = (Get-CimInstance Win32_OperatingSystem).Caption
    osVersion     = (Get-CimInstance Win32_OperatingSystem).Version
    psVersion     = $PSVersionTable.PSVersion.ToString()
    isAdmin       = (Test-IsAdmin)
    needsElevation = (-not (Test-IsAdmin))
    serviceStartMap = $ServiceStartMap
    stats         = $stats
    notes         = @($script:Notes)
    entries       = @($deduped)
}

try {
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    [System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Host "写入 JSON 失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ("采集完成：共 {0} 项（不可关闭 {1} / 建议保留 {2} / 建议关闭 {3} / 待确认 {4}）" -f `
    $stats.total, $stats.critical, $stats.keep, $stats.close, $stats.review) -ForegroundColor Green
Write-Host ("输出文件：{0}" -f $OutputPath) -ForegroundColor Green
Write-Host ''
Write-Host '下一步：运行 build-report.ps1 生成 HTML 面板。' -ForegroundColor Yellow

#endregion
