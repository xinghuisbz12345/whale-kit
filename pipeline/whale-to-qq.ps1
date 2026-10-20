#requires -Version 5.1
<#
  whale-to-qq.ps1 -- 把「鲸鱼」产生的通知推到 QQ 群（融合层）

  背景：dsh-bili-whale 跑在自己的会话（session `bili-whale`）里，用 CLI 刷 B站、
  写日记、在评论区 @ 你。它自己的推送后端是 `notify`（配置里 type=file），
  只会往一个 jsonl 文件里追加 —— **不会发到 QQ**。

  这个脚本就是那座桥：tail 那个 jsonl，把新条目发到 QQ 群。

  为什么用 Python 取 token：social-v2.json 有 150KB+ 且嵌套很深，
  PowerShell 5.1 的 ConvertFrom-Json 默认深度只有 2，会直接抛 ArgumentException
  （本项目踩过）。用 python 的 json 读一次最稳。

  状态：logs\whale-push-state.json 记已读字节偏移，重跑不会重复推送。
  日志：logs\whale-to-qq.log

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File whale-to-qq.ps1
    ... -DryRun      # 只打印要发的内容，不真发
    ... -ReplayAll   # 忽略偏移，从头推一遍（调试用）
#>
param(
  [string]$NotifyFile = "$env:USERPROFILE\.dsh\whale-notify.jsonl",
  [string]$BridgeDir  = 'D:\Backup\Documents\deepseek-harness\qq-bridge',
  [string]$GroupKey   = 'group:1094929609',
  [string]$Workspace  = 'D:\Backup\Documents\deepseek-harness\default-workspace',
  [switch]$DryRun,
  [switch]$ReplayAll
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $Workspace 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir 'whale-to-qq.log'
$statePath = Join-Path $logDir 'whale-push-state.json'

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $NotifyFile)) { Log "通知文件还不存在，跳过：$NotifyFile"; return }
$size = (Get-Item -LiteralPath $NotifyFile).Length
if ($size -eq 0) { return }

# ---------- 读偏移 ----------
$offset = 0
if (-not $ReplayAll -and (Test-Path -LiteralPath $statePath)) {
  try { $offset = [int64](Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).offset } catch { $offset = 0 }
}
if ($offset -gt $size) { $offset = 0 }   # 文件被轮转/清空过
if ($offset -eq $size) { return }        # 没有新内容

# ---------- 取新行 ----------
$fs = [System.IO.File]::Open($NotifyFile, 'Open', 'Read', 'ReadWrite')
try {
  [void]$fs.Seek($offset, 'Begin')
  $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
  $chunk = $reader.ReadToEnd()
  $newOffset = $fs.Position
} finally { $fs.Dispose() }

$lines = $chunk -split "`r?`n" | Where-Object { $_.Trim() }
if (-not $lines) { return }

# ---------- 取凭据 ----------
$python = 'C:\Users\Administrator\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
if (-not (Test-Path -LiteralPath $python)) { $python = 'python' }
$consoleToken = ''
try { $consoleToken = (Get-Content -LiteralPath (Join-Path $BridgeDir 'state\console-token') -Raw).Trim() } catch { }

$pyCode = @'
import json,sys
p=r"__STATE__"
d=json.load(open(p,encoding="utf-8"))
c=d.get("conversations",{}).get("__KEY__",{})
print(c.get("agentToken") or "")
'@
# ⚠️ here-string 的结束符必须独占一行（不能写成 '@.Replace(...)）——
# PowerShell 5.1 会直接 ParserError: Unexpected token '}'，
# 而 PS7 的 Parser::ParseFile 又不报，所以很容易被骗过去。
$pyCode = $pyCode.Replace('__STATE__', (Join-Path $BridgeDir 'state\social-v2.json')).Replace('__KEY__', $GroupKey)
$tmpPy = Join-Path $env:TEMP 'whale_token.py'
[System.IO.File]::WriteAllText($tmpPy, $pyCode, (New-Object System.Text.UTF8Encoding($false)))
$agentToken = (& $python $tmpPy 2>$null | Select-Object -First 1)
if ($agentToken) { $agentToken = $agentToken.Trim() }
Log ("新通知 " + $lines.Count + " 条；token=" + $(if($agentToken){'ok'}else{'MISSING'}))

# ---------- 逐条发 ----------
$utf8 = New-Object System.Text.UTF8Encoding($false)
$sent = 0
foreach ($line in $lines) {
  $obj = $null
  try { $obj = $line | ConvertFrom-Json } catch { Log ("  跳过坏行: " + $line.Substring(0,[Math]::Min(60,$line.Length))); continue }
  # ⚠️ 不能用 `??`（空合并）：那是 PowerShell 7 才有的语法，5.1 直接 ParserError。
  $title = if ($null -ne $obj.title) { [string]$obj.title } else { '' }
  if ($null -ne $obj.text) { $text = [string]$obj.text }
  elseif ($null -ne $obj.message) { $text = [string]$obj.message }
  elseif ($null -ne $obj.body) { $text = [string]$obj.body }
  else { $text = '' }
  if (-not $text.Trim()) { Log "  跳过空内容"; continue }
  # QQ 里不要标题体的"[通知]"前缀，直接正文更像人说话
  $msg = if ($title -and $title -notmatch '^(通知|小鲸鱼刷到)$') { "$title`n$text" } else { $text }
  if ($msg.Length -gt 600) { $msg = $msg.Substring(0, 600) + '…' }

  if ($DryRun) { Log ("  [dry] " + ($msg -replace "`n", ' / ')); $sent++; continue }
  if (-not $agentToken) { Log "  没有 agent token，跳过发送"; break }

  $body = @{ key = $GroupKey; messages = @($msg); token = $agentToken } | ConvertTo-Json -Compress -Depth 4
  $tmpBody = Join-Path $env:TEMP 'whale_push.json'
  [System.IO.File]::WriteAllText($tmpBody, $body, $utf8)
  $resp = & curl.exe -s --max-time 40 -X POST 'http://127.0.0.1:3100/api/socialV2/send-message' `
    -H "x-console-token: $consoleToken" -H "x-agent-token: $agentToken" `
    -H 'content-type: application/json' --data-binary "@$tmpBody" 2>&1
  if ($resp -match '"ok"\s*:\s*true') {
    $sent++
    Log ("  ✅ 已推送: " + ($msg -replace "`n", ' / ').Substring(0, [Math]::Min(80, $msg.Length)))
  } else {
    Log ("  ✗ 推送失败: " + ($resp -replace "`n", ' ').Substring(0, [Math]::Min(200, $resp.Length)))
  }
  Start-Sleep -Seconds 2
}

# ---------- 保存偏移 ----------
if (-not $DryRun) {
  @{ offset = $newOffset; updatedAt = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}
Log ("本轮完成，推送 $sent 条，偏移 -> $newOffset")
