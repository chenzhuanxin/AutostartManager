#Requires -Version 5.1
<#
    AutostartManager / Report Builder
    ---------------------------------
    读取 autostart.json，生成自包含的 autostart-report.html（单文件、离线可用）。

    用法：
      powershell -ExecutionPolicy Bypass -File Build-Report.ps1
      powershell -ExecutionPolicy Bypass -File Build-Report.ps1 -InputPath x.json -OutputPath y.html
#>

[CmdletBinding()]
param(
    [string]$InputPath,
    [string]$OutputPath,
    [string]$ApplyScriptName = 'Apply-Autostart.ps1'
)

$ErrorActionPreference = 'Stop'

# ---------- 路径无关性：脚本可放在任意目录（含中文/空格）----------
$PSScriptRoot_ = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PSScriptRoot_)) { $PSScriptRoot_ = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($InputPath))  { $InputPath  = Join-Path $PSScriptRoot_ 'autostart.json' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $PSScriptRoot_ 'autostart-report.html' }

if (-not (Test-Path -LiteralPath $InputPath)) {
    Write-Host "找不到扫描结果 $InputPath，请先运行 Collect-Autostart.ps1" -ForegroundColor Red
    exit 1
}

$json = [System.IO.File]::ReadAllText($InputPath, [System.Text.Encoding]::UTF8)
$data = $json | ConvertFrom-Json

function Esc([string]$s) {
    if ($null -eq $s) { return '' }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

# 生成表格行
$rows = New-Object System.Text.StringBuilder
$idx = 0
foreach ($e in $data.entries) {
    $idx++
    $risk = [string]$e.risk
    $enabled = $true
    if ($e.enabled -ne $true) { $enabled = $false }

    # 可操作性：critical 永远不可选；其余可选
    $selectable = ($risk -ne 'critical')
    $defaultOn  = ($risk -eq 'close')          # 仅"建议关闭"的默认勾选

    $badges = New-Object System.Text.StringBuilder
    if ($risk -eq 'critical') { [void]$badges.Append('<span class="tag tag-crit">不可关闭</span>') }
    elseif ($risk -eq 'keep') { [void]$badges.Append('<span class="tag tag-keep">建议保留</span>') }
    elseif ($risk -eq 'close') { [void]$badges.Append('<span class="tag tag-close">建议关闭</span>') }
    else { [void]$badges.Append('<span class="tag tag-review">待确认</span>') }

    if (-not $enabled) { [void]$badges.Append('<span class="tag tag-off">已禁用</span>') }
    if ($e.exists -eq $false) { [void]$badges.Append('<span class="tag tag-missing">文件缺失</span>') }
    if ($e.needsAdmin) { [void]$badges.Append('<span class="tag tag-admin">需管理员</span>') }

    $signTxt = '未知'
    if ($e.signStatus -eq 'Valid') { $signTxt = '已签名 · ' + (Esc $e.signer) }
    elseif ($e.signStatus -eq 'NotSigned') { $signTxt = '未签名' }
    elseif ($e.signStatus -eq 'Missing') { $signTxt = '文件不存在' }
    else { $signTxt = Esc ([string]$e.signStatus) }

    $friendly = [string]$e.friendlyName
    $title = Esc ([string]$e.name)
    if ($friendly) { $title = Esc $friendly + '<span class="raw">' + (Esc ([string]$e.name)) + '</span>' }

    $unknownAttr = ''
    if ($e.type -in @('scheduledtask', 'service')) { $unknownAttr = ' data-expertonly="1"' }

    [void]$rows.AppendLine(@"
<tr class="row r-$risk" data-risk="$risk" data-enabled="$($enabled.ToString().ToLower())" data-id="$(Esc $e.id)" data-type="$(Esc $e.type)" data-selectable="$($selectable.ToString().ToLower())" data-scope="$(Esc $e.scope)"$unknownAttr>
  <td class="c-check"><input type="checkbox" class="pick" $(if (-not $selectable) { 'disabled' }) $(if ($defaultOn) { 'checked' })></td>
  <td class="c-idx">$idx</td>
  <td class="c-name">
    <div class="nm">$title</div>
    <div class="sub">$(Esc $e.kind) · $(Esc $e.scope)</div>
  </td>
  <td class="c-risk">$($badges.ToString())</td>
  <td class="c-why">
    <div class="why">$(Esc $e.riskReason)</div>
    <div class="adv">$(Esc $e.advice)</div>
  </td>
  <td class="c-src">
    <div class="mono path" title="$(Esc $e.filePath)">$(Esc $e.filePath)</div>
    <div class="sub">$signTxt</div>
  </td>
  <td class="c-act">
    <button class="mini" data-act="detail">详情</button>
  </td>
</tr>
<tr class="detail" data-for="$(Esc $e.id)" hidden>
  <td colspan="7">
    <div class="dgrid">
      <div><b>来源</b><span>$(Esc $e.sourceLabel)</span></div>
      <div><b>位置</b><span class="mono">$(Esc $e.key)</span></div>
      <div><b>条目名</b><span class="mono">$(Esc $e.valueName)</span></div>
      <div><b>作用域</b><span>$(Esc $e.scope)</span></div>
      <div><b>发布者</b><span>$(Esc $e.company)</span></div>
      <div><b>文件说明</b><span>$(Esc $e.description)</span></div>
      <div class="wide"><b>完整命令行</b><span class="mono">$(Esc $e.command)</span></div>
      <div class="wide"><b>处置建议</b><span>$(Esc $e.advice)</span></div>
      <div class="wide"><b>判定依据</b><span>$(Esc $e.riskReason)</span></div>
    </div>
  </td>
</tr>
"@)
}

$stats = $data.stats
$generated = Esc $data.generatedAt
$computer  = Esc $data.computer
$userName  = Esc $data.user
$osCaption = Esc $data.osCaption
$psVersion = Esc $data.psVersion
$isAdmin   = $data.isAdmin
$adminText = if ($isAdmin) { '已提权（管理员）' } else { '普通权限（修改系统项时会自动请求提权）' }

$applyJs = $ApplyScriptName
$disclaimer = '关闭操作全程可逆：每一项都记录在 backup\ 下的撤销脚本里，双击即可恢复。'

$html = @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>开机自启动管理面板 · $computer</title>
<style>
  :root{
    --bg:#f5f7fa; --panel:#ffffff; --line:#e3e8ef; --line2:#eef2f7;
    --tx:#1f2937; --tx2:#5b6472; --tx3:#8a94a3;
    --crit:#c0392b; --crit-bg:#fdecea;
    --keep:#1d6fd6; --keep-bg:#e8f1fd;
    --close:#c8791a; --close-bg:#fdf3e3;
    --review:#6b7280; --review-bg:#f1f3f6;
    --ok:#1f9d55; --ok-bg:#e8f7ee;
    --shadow:0 1px 2px rgba(16,24,40,.06),0 8px 24px rgba(16,24,40,.06);
    --radius:10px;
  }
  *{box-sizing:border-box}
  body{
    margin:0; background:var(--bg); color:var(--tx);
    font-family:"Microsoft YaHei UI","Microsoft YaHei",-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
    font-size:14px; line-height:1.55;
  }
  .mono{font-family:"Cascadia Mono",Consolas,"SF Mono",Menlo,monospace;font-size:12px}
  header{background:var(--panel);border-bottom:1px solid var(--line);padding:20px 28px 0}
  .htop{display:flex;flex-wrap:wrap;align-items:flex-start;gap:16px;justify-content:space-between}
  h1{font-size:19px;margin:0 0 4px;font-weight:600}
  .meta{color:var(--tx3);font-size:12.5px}
  .meta b{color:var(--tx2);font-weight:600}
  .cards{display:flex;gap:10px;flex-wrap:wrap;margin:16px 0 0}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);padding:10px 16px;min-width:104px}
  .card .n{font-size:21px;font-weight:700;line-height:1.2}
  .card .l{font-size:12px;color:var(--tx3)}
  .card.c-crit .n{color:var(--crit)} .card.c-keep .n{color:var(--keep)}
  .card.c-close .n{color:var(--close)} .card.c-rev .n{color:var(--review)}
  nav{display:flex;gap:6px;margin:18px 0 -1px;flex-wrap:wrap}
  nav button{
    border:1px solid var(--line);background:var(--panel);border-bottom-color:transparent;
    padding:8px 14px;border-radius:8px 8px 0 0;cursor:pointer;color:var(--tx2);font-size:13px;font-family:inherit
  }
  nav button.on{color:var(--tx);font-weight:600;border-color:var(--line);box-shadow:0 -2px 0 var(--keep) inset}
  main{padding:0 28px 90px}
  .toolbar{
    display:flex;gap:10px;align-items:center;flex-wrap:wrap;
    background:var(--panel);border:1px solid var(--line);border-top:none;border-radius:0 0 var(--radius) var(--radius);
    padding:12px 16px;margin-bottom:14px
  }
  .toolbar input[type=search]{
    flex:1;min-width:180px;padding:8px 12px;border:1px solid var(--line);border-radius:8px;
    font-family:inherit;font-size:13px;color:var(--tx);background:#fbfcfe
  }
  .btn{
    border:1px solid var(--line);background:var(--panel);padding:8px 14px;border-radius:8px;
    cursor:pointer;font-size:13px;font-family:inherit;color:var(--tx)
  }
  .btn:hover{border-color:#c9d3e0}
  .btn.primary{background:var(--keep);border-color:var(--keep);color:#fff;font-weight:600}
  .btn.primary:hover{background:#1860bd}
  .btn.ghost{background:transparent}
  .btn:disabled{opacity:.45;cursor:not-allowed}
  .chk{display:inline-flex;align-items:center;gap:6px;color:var(--tx2);font-size:13px;cursor:pointer;user-select:none}
  table{width:100%;border-collapse:separate;border-spacing:0;background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);overflow:hidden}
  thead th{
    text-align:left;font-size:12px;font-weight:600;color:var(--tx2);background:#fafbfd;
    padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap
  }
  tbody td{padding:11px 12px;border-bottom:1px solid var(--line2);vertical-align:top}
  tbody tr.row:hover{background:#fafcff}
  td.c-check{width:36px;text-align:center}
  td.c-idx{width:38px;color:var(--tx3);font-size:12px}
  td.c-risk{width:150px}
  td.c-why{width:30%}
  td.c-src{width:24%}
  td.c-act{width:64px}
  .nm{font-weight:600}
  .nm .raw{display:block;font-weight:400;color:var(--tx3);font-size:11.5px;font-family:"Cascadia Mono",Consolas,monospace}
  .sub{color:var(--tx3);font-size:11.5px;margin-top:2px}
  .why{color:var(--tx2);font-size:12.5px}
  .adv{color:var(--tx3);font-size:12px;margin-top:3px}
  .path{color:var(--tx2);word-break:break-all;display:block;max-height:32px;overflow:hidden}
  .tag{display:inline-block;font-size:11.5px;padding:2px 7px;border-radius:5px;margin:0 4px 4px 0;white-space:nowrap;border:1px solid transparent}
  .tag-crit{background:var(--crit-bg);color:var(--crit);border-color:#f6cfc9;font-weight:600}
  .tag-keep{background:var(--keep-bg);color:var(--keep);border-color:#cfe2fa}
  .tag-close{background:var(--close-bg);color:var(--close);border-color:#f4dfbb}
  .tag-review{background:var(--review-bg);color:var(--review);border-color:#e0e4ea}
  .tag-off{background:#f3f4f6;color:#6b7280;border-color:#e5e7eb}
  .tag-missing{background:#fff4e5;color:#b45309;border-color:#fcd9a4}
  .tag-admin{background:#f4f0fd;color:#6d4bc4;border-color:#ded1f7}
  tr.row.r-critical{background:#fffbfa}
  tr.detail td{background:#fbfcfe;padding:0}
  .dgrid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px 18px;padding:14px 18px}
  .dgrid > div{display:flex;flex-direction:column;gap:2px}
  .dgrid > div.wide{grid-column:1/-1}
  .dgrid b{font-size:11.5px;color:var(--tx3);font-weight:600}
  .dgrid span{font-size:12.5px;color:var(--tx2);word-break:break-all}
  .mini{border:1px solid var(--line);background:#fff;border-radius:6px;padding:4px 9px;font-size:12px;cursor:pointer;font-family:inherit;color:var(--tx2)}
  .mini:hover{border-color:#c9d3e0;color:var(--tx)}
  .empty{padding:36px;text-align:center;color:var(--tx3);background:var(--panel);border:1px solid var(--line);border-radius:var(--radius)}
  .notice{background:#fffdf5;border:1px solid #f2e2b8;border-radius:var(--radius);padding:12px 16px;margin:0 0 14px;color:#7a5c14;font-size:12.5px}
  .notice b{color:#5f4708}
  footer{
    position:fixed;left:0;right:0;bottom:0;background:var(--panel);border-top:1px solid var(--line);
    padding:11px 28px;display:flex;gap:14px;align-items:center;flex-wrap:wrap;box-shadow:0 -4px 16px rgba(16,24,40,.05)
  }
  footer .sum{color:var(--tx2);font-size:13px}
  footer .sum b{color:var(--tx)}
  footer .spacer{flex:1}
  dialog{border:none;border-radius:12px;padding:0;max-width:720px;width:92%;box-shadow:var(--shadow)}
  dialog::backdrop{background:rgba(15,23,42,.42)}
  .dlg-h{padding:16px 20px;border-bottom:1px solid var(--line);font-weight:600}
  .dlg-b{padding:16px 20px;max-height:56vh;overflow:auto}
  .dlg-f{padding:14px 20px;border-top:1px solid var(--line);display:flex;gap:10px;justify-content:flex-end;background:#fafbfd}
  .dlg-b ol{margin:8px 0 0;padding-left:22px}
  .dlg-b li{margin-bottom:6px}
  .cmd{
    background:#0f172a;color:#e2e8f0;border-radius:8px;padding:11px 14px;font-size:12px;
    font-family:"Cascadia Mono",Consolas,monospace;word-break:break-all;margin:8px 0 4px;position:relative
  }
  .cmd .cp{position:absolute;right:8px;top:8px;background:#1e293b;border:none;color:#94a3b8;border-radius:5px;padding:3px 8px;font-size:11px;cursor:pointer}
  .warnline{color:var(--crit);font-weight:600;margin-top:10px;font-size:12.5px}
  .toast{
    position:fixed;left:50%;transform:translateX(-50%);bottom:78px;background:#111827;color:#fff;
    padding:10px 18px;border-radius:8px;font-size:13px;opacity:0;pointer-events:none;transition:opacity .25s;z-index:99
  }
  .toast.on{opacity:1}
  @media (max-width:1000px){
    td.c-why,td.c-src{width:auto}
    .dgrid{grid-template-columns:1fr}
    main,header,footer{padding-left:16px;padding-right:16px}
  }
  @media print{ footer{position:static} .c-check,.c-act,.toolbar{display:none} }
</style>
</head>
<body>
<header>
  <div class="htop">
    <div>
      <h1>开机自启动管理面板</h1>
      <div class="meta">
        计算机 <b>$computer</b> · 用户 <b>$userName</b> · $osCaption<br>
        扫描时间 <b>$generated</b> · PowerShell <b>$psVersion</b> · 当前权限 <b>$adminText</b>
      </div>
    </div>
    <div class="cards">
      <div class="card"><div class="n">$($stats.total)</div><div class="l">自启动项总数</div></div>
      <div class="card c-crit"><div class="n">$($stats.critical)</div><div class="l">不可关闭</div></div>
      <div class="card c-keep"><div class="n">$($stats.keep)</div><div class="l">建议保留</div></div>
      <div class="card c-close"><div class="n">$($stats.close)</div><div class="l">建议关闭</div></div>
      <div class="card c-rev"><div class="n">$($stats.review)</div><div class="l">待确认</div></div>
    </div>
  </div>
  <nav id="nav">
    <button class="on" data-filter="all">全部</button>
    <button data-filter="close">建议关闭 ($($stats.close))</button>
    <button data-filter="keep">建议保留 ($($stats.keep))</button>
    <button data-filter="review">待确认 ($($stats.review))</button>
    <button data-filter="critical">不可关闭 ($($stats.critical))</button>
    <button data-filter="off">已被禁用</button>
  </nav>
</header>

<main>
  <div class="toolbar">
    <input type="search" id="q" placeholder="搜索名称、发布者、路径关键字…">
    <label class="chk"><input type="checkbox" id="onlyEnabled" checked> 只显示当前启用的</label>
    <button class="btn ghost" id="selRec">一键选中全部「建议关闭」</button>
    <button class="btn ghost" id="selNone">清空选择</button>
    <button class="btn ghost" id="expand">展开/收起全部详情</button>
  </div>

  <div class="notice">
    <b>安全设计：</b>本面板只负责"选择"，不会在浏览器里直接改系统。
    「不可关闭」项已被锁定，无法勾选。$disclaimer
    计划任务与服务默认不参与批量操作，需要点开某一行单独处理。
  </div>

  <table id="tbl">
    <thead>
      <tr>
        <th class="c-check"></th>
        <th class="c-idx">#</th>
        <th>名称</th>
        <th class="c-risk">风险等级</th>
        <th class="c-why">判定理由与建议</th>
        <th class="c-src">程序位置 / 签名</th>
        <th class="c-act">操作</th>
      </tr>
    </thead>
    <tbody>
$($rows.ToString())
    </tbody>
  </table>
  <div class="empty" id="empty" hidden>没有符合条件的结果</div>
</main>

<footer>
  <span class="sum" id="sum">已选 <b>0</b> 项</span>
  <button class="btn ghost" id="clearAll">取消选择</button>
  <span class="spacer"></span>
  <button class="btn" id="genCmd">生成关闭脚本</button>
  <button class="btn primary" id="applyNow">立即关闭选中项</button>
</footer>

<dialog id="dlg">
  <div class="dlg-h" id="dlgTitle">应用更改</div>
  <div class="dlg-b" id="dlgBody"></div>
  <div class="dlg-f">
    <button class="btn" id="dlgCancel">取消</button>
    <button class="btn primary" id="dlgOk">确认</button>
  </div>
</dialog>

<div class="toast" id="toast"></div>

<script>
(function(){
  "use strict";
  var ENTRIES = __ENTRIES__;
  var APPLY_SCRIPT = __APPLYSCRIPT__;
  var MODE = __MODE__;   // 'auto' | 'manual'
  var IS_ADMIN = __ISADMIN__;

  var tbl = document.getElementById('tbl');
  var tbody = tbl.querySelector('tbody');
  var allRows = Array.prototype.slice.call(tbody.querySelectorAll('tr.row'));
  var curFilter = 'all';
  var q = document.getElementById('q');
  var onlyEnabled = document.getElementById('onlyEnabled');
  var emptyEl = document.getElementById('empty');
  var sumEl = document.getElementById('sum');
  var sel = new Set();

  function fmtSize(kb){ if(!kb) return ''; return kb >= 1024 ? (kb/1024).toFixed(1)+' MB' : kb+' KB'; }

  function toast(msg){
    var t = document.getElementById('toast');
    t.textContent = msg; t.classList.add('on');
    clearTimeout(t._h); t._h = setTimeout(function(){ t.classList.remove('on'); }, 2400);
  }

  function applyFilter(){
    var kw = (q.value || '').trim().toLowerCase();
    var show = 0;
    allRows.forEach(function(r){
      var risk = r.getAttribute('data-risk');
      var en = r.getAttribute('data-enabled') === 'true';
      var okF = true;
      if (curFilter === 'off') { okF = !en; }
      else if (curFilter !== 'all') { okF = (risk === curFilter); }
      var okE = onlyEnabled.checked ? en : true;
      var okQ = true;
      if (kw) {
        var e = ENTRIES[r.getAttribute('data-id')];
        var blob = (r.textContent + ' ' + (e ? (e.filePath + ' ' + e.company + ' ' + e.valueName + ' ' + e.command + ' ' + e.signer) : '')).toLowerCase();
        okQ = blob.indexOf(kw) !== -1;
      }
      var vis = okF && okE && okQ;
      r.hidden = !vis;
      var d = tbody.querySelector('tr.detail[data-for="' + r.getAttribute('data-id') + '"]');
      if (d) { if (!vis) d.hidden = true; }
      if (vis) show++;
    });
    emptyEl.hidden = show !== 0;
  }

  // ---- 选择 ----
  function syncSel(){
    sel.clear();
    allRows.forEach(function(r){
      var cb = r.querySelector('input.pick');
      if (cb && cb.checked && !cb.disabled) sel.add(r.getAttribute('data-id'));
    });
    var byRisk = {close:0, keep:0, review:0};
    sel.forEach(function(id){
      var e = ENTRIES[id];
      if (e && byRisk[e.risk] !== undefined) byRisk[e.risk]++;
    });
    sumEl.innerHTML = '已选 <b>' + sel.size + '</b> 项' +
      (sel.size ? '（建议关闭 ' + byRisk.close + ' · 建议保留 ' + byRisk.keep + ' · 待确认 ' + byRisk.review + '）' : '');
    document.getElementById('applyNow').disabled = sel.size === 0;
    document.getElementById('genCmd').disabled = sel.size === 0;
  }

  tbody.addEventListener('change', function(ev){
    if (ev.target.classList.contains('pick')) syncSel();
  });

  // ---- 详情展开 ----
  tbody.addEventListener('click', function(ev){
    var btn = ev.target.closest('button.mini');
    if (!btn) return;
    var row = btn.closest('tr.row');
    var id = row.getAttribute('data-id');
    var d = tbody.querySelector('tr.detail[data-for="' + id + '"]');
    if (d) { d.hidden = !d.hidden; btn.textContent = d.hidden ? '详情' : '收起'; }
  });

  // ---- 导航 ----
  document.getElementById('nav').addEventListener('click', function(ev){
    var b = ev.target.closest('button');
    if (!b) return;
    Array.prototype.forEach.call(this.querySelectorAll('button'), function(x){ x.classList.remove('on'); });
    b.classList.add('on');
    curFilter = b.getAttribute('data-filter');
    applyFilter();
  });
  q.addEventListener('input', applyFilter);
  onlyEnabled.addEventListener('change', applyFilter);

  document.getElementById('selRec').addEventListener('click', function(){
    var n = 0;
    allRows.forEach(function(r){
      if (r.hidden) return;
      if (r.getAttribute('data-risk') !== 'close') return;
      var cb = r.querySelector('input.pick');
      if (cb && !cb.disabled) { cb.checked = true; n++; }
    });
    syncSel();
    toast('已选中 ' + n + ' 项「建议关闭」');
  });
  document.getElementById('selNone').addEventListener('click', function(){
    allRows.forEach(function(r){ var cb = r.querySelector('input.pick'); if (cb) cb.checked = false; });
    syncSel();
  });
  document.getElementById('clearAll').addEventListener('click', function(){
    allRows.forEach(function(r){ var cb = r.querySelector('input.pick'); if (cb) cb.checked = false; });
    syncSel();
  });
  document.getElementById('expand').addEventListener('click', function(){
    var anyHidden = Array.prototype.some.call(tbody.querySelectorAll('tr.detail'), function(d){ return d.hidden; });
    tbody.querySelectorAll('tr.detail').forEach(function(d){ d.hidden = !anyHidden; });
    tbody.querySelectorAll('button.mini').forEach(function(b){ b.textContent = anyHidden ? '收起' : '详情'; });
    applyFilter();
  });

  // ---- 对话框 ----
  var dlg = document.getElementById('dlg');
  var dlgTitle = document.getElementById('dlgTitle');
  var dlgBody = document.getElementById('dlgBody');
  var dlgOk = document.getElementById('dlgOk');
  var pending = null;

  function closeDlg(){ if (dlg.open) dlg.close(); pending = null; }
  document.getElementById('dlgCancel').addEventListener('click', closeDlg);
  dlg.addEventListener('cancel', function(e){ e.preventDefault(); closeDlg(); });

  function buildCmd(ids){
    var lines = [];
    lines.push('powershell -ExecutionPolicy Bypass -File ".\\' + APPLY_SCRIPT + '" -Action Disable -Ids ' + ids.join(','));
    return lines.join('\n');
  }

  function renderList(ids){
    var html = '<div style="margin-bottom:10px;color:#5b6472">将对以下 <b>' + ids.length + '</b> 项执行关闭操作：</div><ol>';
    ids.forEach(function(id){
      var e = ENTRIES[id]; if (!e) return;
      var nm = e.friendlyName || e.name;
      html += '<li><b>' + escapeHtml(nm) + '</b> <span style="color:#8a94a3;font-size:12px">（' + escapeHtml(e.kind) + ' · ' + escapeHtml(e.sourceLabel) + '）</span></li>';
    });
    html += '</ol>';
    return html;
  }

  function escapeHtml(s){
    return String(s == null ? '' : s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }

  function doApply(ids){
    if (MODE === 'manual') {
      var cmd = buildCmd(ids);
      dlgTitle.textContent = '生成关闭脚本';
      dlgBody.innerHTML = renderList(ids) +
        '<div style="margin-top:12px">复制下面这行命令，在本面板所在文件夹打开 PowerShell 后粘贴执行：</div>' +
        '<div class="cmd" id="cmdB">' + escapeHtml(cmd) + '<button class="cp" id="cpBtn">复制</button></div>' +
        '<div style="color:#5b6472;font-size:12.5px;margin-top:8px">执行前会自动创建备份，并生成同目录下的撤销脚本。</div>';
      document.getElementById('dlgOk').textContent = '复制并关闭';
      pending = { kind: 'copy', text: cmd };
    } else {
      dlgTitle.textContent = '确认关闭自启动';
      dlgBody.innerHTML = renderList(ids) +
        '<div class="warnline">已勾选项将立即停止随开机启动。系统会先备份，随时可以还原。</div>';
      document.getElementById('dlgOk').textContent = '确认关闭';
      pending = { kind: 'apply', ids: ids };
    }
    dlg.showModal();
  }

  dlgOk.addEventListener('click', function(){
    if (!pending) { closeDlg(); return; }
    if (pending.kind === 'copy') {
      copyText(pending.text).then(function(){ toast('已复制，去 PowerShell 里执行吧'); closeDlg(); },
                                  function(){ toast('复制失败，请手动选中复制'); });
      return;
    }
    // 交给本地协议处理器
    var payload = encodeURIComponent(JSON.stringify({ action: 'disable', ids: pending.ids, script: APPLY_SCRIPT }));
    closeDlg();
    try { window.location.href = 'autostart://apply?data=' + payload; }
    catch (err) { toast('无法唤起本地处理程序'); }
  });

  function copyText(text){
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function(resolve, reject){
      try {
        var ta = document.createElement('textarea');
        ta.value = text; ta.style.position = 'fixed'; ta.style.left = '-9999px';
        document.body.appendChild(ta); ta.select();
        document.execCommand('copy'); document.body.removeChild(ta);
        resolve();
      } catch (e) { reject(e); }
    });
  }

  document.getElementById('genCmd').addEventListener('click', function(){
    var ids = Array.from(sel);
    if (!ids.length) { toast('还没有选择任何项'); return; }
    var cmd = buildCmd(ids);
    dlgTitle.textContent = '生成关闭脚本';
    dlgBody.innerHTML = renderList(ids) +
      '<div style="margin-top:12px">把下面这行命令复制到 PowerShell 执行（建议在本面板所在文件夹打开 PowerShell）：</div>' +
      '<div class="cmd">' + escapeHtml(cmd) + '<button class="cp" id="cpBtn2">复制</button></div>' +
      '<div style="color:#5b6472;font-size:12.5px;margin-top:8px">执行前会自动备份，并生成 backup\\restore-last.bat 撤销脚本。</div>';
    document.getElementById('dlgCancel').textContent = '关闭';
    document.getElementById('dlgOk').style.display = 'none';
    dlg.showModal();
    document.getElementById('cpBtn2').addEventListener('click', function(){
      copyText(cmd).then(function(){ toast('已复制'); }, function(){ toast('复制失败'); });
    });
  });

  document.getElementById('applyNow').addEventListener('click', function(){
    var ids = Array.from(sel);
    if (!ids.length) { toast('还没有选择任何项'); return; }
    document.getElementById('dlgCancel').textContent = '取消';
    document.getElementById('dlgOk').style.display = '';
    doApply(ids);
  });

  // ---- 初始化 ----
  allRows.forEach(function(r){
    var id = r.getAttribute('data-id');
    var e = ENTRIES[id];
    if (e && fmtSize(e.sizeKB)) { /* 尺寸信息在详情里已展示 */ }
  });
  syncSel();
  applyFilter();
})();
</script>
</body>
</html>
"@

# 注入数据与运行模式
$entriesObj = @{}
foreach ($e in $data.entries) { $entriesObj[$e.id] = $e }
$entriesJson = ($entriesObj | ConvertTo-Json -Depth 6 -Compress)

# 运行模式：面板默认走"复制命令"通道（浏览器无法直接改系统，属刻意设计）
$mode = 'manual'
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot_ $ApplyScriptName)) { $mode = 'manual' }

$html = $html.Replace('__ENTRIES__', $entriesJson)
$html = $html.Replace('__APPLYSCRIPT__', "'" + $ApplyScriptName + "'")
$html = $html.Replace('__MODE__', "'" + $mode + "'")
$html = $html.Replace('__ISADMIN__', $(if ($isAdmin) { 'true' } else { 'false' }))

try {
    [System.IO.File]::WriteAllText($OutputPath, $html, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Write-Host "写入 HTML 失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "面板已生成：$OutputPath" -ForegroundColor Green
Write-Host "共 $($data.entries.Count) 条记录。" -ForegroundColor Green
