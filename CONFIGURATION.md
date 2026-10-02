# 配置与路径说明

本文档说明部署细节、路径处理机制和常见路径问题的排查方法。

---

## 一、核心结论：不需要配置

**本工具没有任何需要手工修改的路径配置。**

下载解压后，把整个 `AutostartManager` 文件夹放到任意位置，双击 `启动面板.bat` 即可。

已验证可用的路径形式：

| 路径类型 | 示例 | 是否可用 |
|:---|:---|:---|
| 简单英文路径 | `C:\AutostartManager\` | ✅ |
| 中文路径 | `D:\我的工具\自启动管理\` | ✅ |
| 含空格路径 | `C:\Program Files\My Tools\` | ✅ |
| 中文 + 空格混合 | `D:\我的 工具\自启动 管理\` | ✅ |
| 深层嵌套 | `D:\a\b\c\d\e\AutostartManager\` | ✅ |
| U 盘 / 移动硬盘 | `E:\AutostartManager\` | ✅ |
| 网络共享盘 | `\\NAS\share\AutostartManager\` | ✅（需有写权限，见第四节） |
| 只读目录 | `C:\Program Files\AutostartManager\` | ⚠️ 可运行，备份自动改存到 `%LOCALAPPDATA%` |

---

## 二、路径是如何被自动定位的

### 2.1 批处理文件（.bat）

`.bat` 通过 `%~dp0` 获取**自身所在目录**（结尾自带反斜杠）：

```bat
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Start-Panel.ps1"
```

`%~dp0` 是 Windows 批处理的内置变量，**不依赖当前工作目录**，因此无论从哪里调用都能正确定位。这就是为什么**必须先 `cd` 到别处再运行也不会有问题**。

同时脚本做了三层加固：

```bat
rem ① 找不到目标脚本时给出明确提示，而不是闪一下就消失
if not exist "%PS_SCRIPT%" (
    echo   [错误] 找不到 Start-Panel.ps1
    echo   当前查找路径：%PS_SCRIPT%
    pause
    exit /b 1
)

rem ② 优先用完整的系统 PowerShell 路径，避免用户 PATH 被改坏
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

rem ③ 路径参数用引号包裹，兼容空格与中文
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
```

另外 `chcp 65001` 把控制台切到 UTF-8 代码页，保证中文提示不乱码。

### 2.2 PowerShell 脚本（.ps1）

所有 `.ps1` 统一用 `$PSScriptRoot` 定位同级文件：

```powershell
$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = (Get-Location).Path      # 极端情况下的兜底
}
$collector = Join-Path $ScriptRoot 'Collect-Autostart.ps1'
```

`$PSScriptRoot` 由 PowerShell 引擎自动填入「**当前脚本文件所在目录**」，与被调用时的当前目录无关。这是 PowerShell 官方推荐的路径无关写法。

> **注意**：`$PSScriptRoot` 仅在脚本**以文件方式执行**时有效（`-File` 参数）。如果用管道或字符串方式执行（如 `Get-Content x.ps1 | Invoke-Expression`），它会为空——这也是每处都写了 `Get-Location` 兜底的原因。

### 2.3 提权时的路径传递

`Start-Panel.ps1` 提权时会重新以管理员身份启动自己。这里有个容易出错的地方：

```powershell
# ❌ 错误写法：PowerShell 会把数组用空格拼接，含空格的路径会断成两个参数
$argList = @('-File', $selfPath)          # C:\My Tools\Start-Panel.ps1
                                          # → -File C:\My Tools\Start-Panel.ps1  ← 断链！

# ✅ 正确写法：把整个 -File 值用引号包成"一个"参数
$argList = @('-File', ('"' + $selfPath + '"'))
```

本项目采用后者，因此**放在含空格的目录下提权也能正常工作**。

---

## 三、输出文件的位置

所有输出都产生在**脚本所在目录**，不会污染系统其他地方：

| 文件 | 生成时机 | 位置 |
|:---|:---|:---|
| `autostart.json` | 每次扫描 | 脚本目录 |
| `autostart-report.html` | 每次扫描 | 脚本目录 |
| `backup\autostart-Disable-<时间戳>.json` | 每次关闭操作 | 脚本目录下的 `backup\` |
| `backup\restore-last.bat` | 每次关闭操作 | 同上（覆盖式更新） |
| `backup\restore-last.ps1` | 每次关闭操作 | 同上 |

这些文件都是**可再生的中间产物**，你可以随时删除 `autostart.json`、`autostart-report.html` 和整个 `backup\` 目录，不影响工具运行。

### 备份目录不可写时的自动回退

如果脚本被放在只读位置（例如 `C:\Program Files\` 下，普通用户无写权限），备份会**自动改存**到：

```
%LOCALAPPDATA%\AutostartManager\backup
```

即 `C:\Users\<你的用户名>\AppData\Local\AutostartManager\backup`。

回退逻辑会**真实写入一个探针文件**来验证目录可写性（因为只读目录 `Test-Path` 也会返回真，仅靠路径存在性判断不可靠）：

```powershell
$probe = Join-Path $Preferred ('.writetest-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
[System.IO.File]::WriteAllText($probe, 'ok')
Remove-Item -LiteralPath $probe -Force
```

回退发生时会打印黄色提示告知新位置。**此时 `恢复上次关闭项.bat` 仍能工作**，因为 `Apply-Autostart.ps1 -Action Restore` 内置了同样的目录解析逻辑。

---

## 四、特殊场景配置

### 4.1 自定义输出路径

所有脚本都支持显式指定路径参数：

```powershell
# 扫描结果输出到 D 盘
.\Collect-Autostart.ps1 -OutputPath 'D:\扫描结果\autostart.json'

# 面板输出到指定位置
.\Build-Report.ps1 -InputPath 'D:\扫描结果\autostart.json' `
                   -OutputPath 'D:\扫描结果\面板.html'
```

目标目录不存在时会**自动创建**（含多级父目录）。

### 4.2 从命令行完整跑一遍

```powershell
# 在项目目录打开 PowerShell
cd D:\我的工具\AutostartManager

powershell -ExecutionPolicy Bypass -File .\Collect-Autostart.ps1
powershell -ExecutionPolicy Bypass -File .\Build-Report.ps1
start .\autostart-report.html
```

或者直接用启动器（含自动提权）：

```powershell
.\Start-Panel.ps1                 # 会自动请求管理员权限
.\Start-Panel.ps1 -NoElevate      # 不提权，跳过计划任务和服务
.\Start-Panel.ps1 -SkipCollect    # 复用已有 autostart.json，只重新生成面板
```

### 4.3 关闭执行策略限制

首次运行时，如果系统执行策略过严可能被拦截。三种解决方式按推荐度排序：

```powershell
# ① 单次绕过（推荐，不改系统设置）
powershell -ExecutionPolicy Bypass -File .\Start-Panel.ps1

# ② 只对当前会话生效
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# ③ 放开当前用户（改动会持久保存）
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

项目里的 `.bat` 启动器**已经内置 `-ExecutionPolicy Bypass`**，所以正常双击使用时不会遇到这个限制。

---

## 五、故障排查

### 双击 .bat 闪一下就消失

**原因**：脚本报错后窗口立即关闭。

**排查**：改用命令行运行，错误信息会保留在窗口里：

```bat
cd /d "D:\你的路径\AutostartManager"
启动面板.bat
```

启动器已内置 `if not "%RC%"=="0" pause`，正常情况下报错会停住。如果仍然闪退，说明是 `.bat` 本身的问题（例如被安全软件拦截），可以手动在 PowerShell 里执行 `.\Start-Panel.ps1` 绕过。

### 提示「找不到 Start-Panel.ps1」

**原因**：`.bat` 文件和 `.ps1` 文件被拆散了。

**解决**：确认它们**在同一层目录**。正确的目录结构：

```
AutostartManager\
├── 启动面板.bat          ← 双击这个
├── Start-Panel.ps1       ← 必须和 .bat 同级
├── Collect-Autostart.ps1
├── Build-Report.ps1
├── Apply-Autostart.ps1
└── ...
```

### PowerShell 报 `Join-Path : 无法将参数绑定到参数"Path"，因为该参数为空字符串`

**原因**：脚本在 `param` 块的默认值里调用了 `Join-Path $PSScriptRoot ...`。

`param` 默认值的求值时机**早于脚本正文**，而在部分调用方式下（`-File`、点源 `.` 调用、被其它脚本加载），此时 `$PSScriptRoot` 仍然是空字符串，于是 `Join-Path` 抛错。

**本版本（v1.0.1 起）已彻底修复**：所有脚本都改为在**正文**中解析脚本目录，并带多级兜底（`$PSScriptRoot` → 当前目录 → `AppDomain.BaseDirectory` → `%TEMP%`）。`-Ids` 参数也做了归一化，逗号分隔的 id 列表在 `-File` 调用下同样能正确切分。

**如果你手上是旧版本**，按下面任一方式修复：

1. 直接重新下载本仓库最新版（推荐）；
2. 或手动把 `Apply-Autostart.ps1` 里这一行

```powershell
    [string]$ScanFile = (Join-Path $PSScriptRoot 'autostart.json'),
```

改成

```powershell
    [string]$ScanFile,
```

并在 `param(...)` 块**之后**补上：

```powershell
$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($ScanFile)) { $ScanFile = Join-Path $ScriptRoot 'autostart.json' }
```

> 这个报错还有一个「同伙」：如果命令是 `-Ids a,b,c` 这种逗号串，`powershell -File` **不会**按逗号切分成数组，旧版会把整串当成一个 id，导致命令**静默什么都不做**。新版已在脚本内按 `,`、`;`、空白重新切分，两种写法都安全。

### PowerShell 报「意外的标记」「缺少右括号」等语法错误

**原因**：**脚本文件丢失了 UTF-8 BOM**。

这是本工具最容易踩的坑。Windows PowerShell 5.1 在没有 BOM 时会按系统本地代码页（简体中文为 GBK/936）解析文件，而本项目脚本含大量中文字符串，会被解成乱码进而引发语法错误。

**触发场景**：你用记事本、VSCode 或其他编辑器改过脚本，另存为「UTF-8」（不带 BOM）。

**内置防护**：`Start-Panel.ps1` 启动时会**自动检测并补回 BOM**，所以只要你通过 `启动面板.bat` 运行，这个问题会被自动修复。

**手工修复**（如果不经启动器直接跑子脚本）：

```powershell
$utf8bom = New-Object System.Text.UTF8Encoding($true)
Get-ChildItem *.ps1 | ForEach-Object {
    $t = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($_.FullName, $t, $utf8bom)
}
```

> **编辑建议**：如果要用编辑器改脚本，VSCode 请选择 `UTF-8 with BOM`；记事本另存时编码选「UTF-8」在较新版本会自动带 BOM。

### 扫描结果缺少计划任务或服务

**原因**：没有以管理员身份运行。

**解决**：用 `启动面板.bat` 启动并同意 UAC；或手动以管理员身份打开 PowerShell 再执行。

### 关闭某项时提示「访问被拒绝」

**原因**：该项位于 `HKLM`（所有用户）或属于系统服务，需要管理员权限。

**解决**：以管理员身份运行。面板里这类项会显示紫色「需管理员」标签。

### 关闭后发现某个软件不正常

**解决**：立即恢复。

```powershell
.\Apply-Autostart.ps1 -Action Restore
```

或双击 `backup\restore-last.bat`。

**只会恢复你本次关闭的项**，不会影响你之前在任务管理器里手工禁用的其他项（恢复逻辑会跳过「原本就是禁用状态」的条目）。

### 想查看所有历史备份

```powershell
.\Apply-Autostart.ps1 -Action ListBackups
```

然后可以恢复到任意一个指定备份：

```powershell
.\Apply-Autostart.ps1 -Action Restore -Backup .\backup\autostart-Disable-20261002-173706.json
```

---

## 六、目录结构参考

```
AutostartManager\
│
├── 启动面板.bat                    ← ⭐ 双击启动
├── 恢复上次关闭项.bat               ← ⭐ 双击恢复
│
├── Start-Panel.ps1                 主流程（提权 + 编排 + 编码自检）
├── Collect-Autostart.ps1           扫描器（只读）
├── Build-Report.ps1                面板生成器
├── Apply-Autostart.ps1             执行器（关闭 / 恢复，含备份）
├── Restore-Last.ps1                恢复的 PowerShell 入口
│
├── autostart.json                  扫描结果（可再生）
├── autostart-report.html           面板（可再生）
│
├── backup\                         备份目录（自动创建）
│   ├── autostart-Disable-<时间戳>.json
│   ├── restore-last.bat            ← 双击即可撤销
│   └── restore-last.ps1
│
├── README.md                       项目说明
├── CONFIGURATION.md                本文档
├── 使用说明.txt                     精简中文说明
└── LICENSE
```

---

## 七、技术约束说明

| 项目 | 说明 |
|:---|:---|
| PowerShell 版本 | 需要 5.1+（Windows 10/11 自带）。脚本**未使用** PowerShell 7 独有语法，兼容性优先 |
| 依赖 | 仅 .NET Framework 内置类型（`Microsoft.Win32.Registry`、`System.Security.Cryptography`）+ `Get-AuthenticodeSignature` 等系统 cmdlet |
| 编码 | 所有 `.ps1` 必须为 **UTF-8 with BOM**；`.bat` 为 **UTF-8 无 BOM**（配合 `chcp 65001`） |
| 权限 | 扫描建议管理员；关闭 `HKLM` 项和计划任务/服务必须管理员 |
| 网络 | 完全离线运行，不发起任何网络请求 |

### 关于 `[Microsoft.Win32.Registry]::HKCU`

一个容易踩的 .NET 兼容性问题：在 PowerShell 5.1 下，静态属性 `[Microsoft.Win32.Registry]::HKCU` 和 `::HKLM` 是 `$null`，直接调用会在运行时报「不能对 Null 值表达式调用方法」。

本项目统一使用 `OpenBaseKey` 正确获取根键句柄：

```powershell
function Get-RegRoot([string]$HiveName) {
    $hive = if ($HiveName -eq 'HKLM') {
        [Microsoft.Win32.RegistryHive]::LocalMachine
    } else {
        [Microsoft.Win32.RegistryHive]::CurrentUser
    }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        $hive, [Microsoft.Win32.RegistryView]::Default)
}
```

如果你要基于本项目二次开发，请沿用这个写法。
