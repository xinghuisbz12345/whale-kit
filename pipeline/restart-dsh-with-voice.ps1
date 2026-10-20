#requires -Version 5.1
<#
  restart-dsh-with-voice.ps1 -- 无人值守重启 DSH，并把语音栈按正确顺序拉起来

  为什么需要它：重启 DSH 会杀掉这个宿主进程本身（agent 也在这进程里），
  所以「杀掉 → 等它起来 → 再起 TTS/桥接」这套动作必须由一个**脱离宿主**的进程来做，
  否则做到一半自己也被杀掉了。

  顺序（顺序是硬要求，上次就是桥接比网卡早 19 秒才卡死）：
    1. 停桥接、停 TTS（先断开，避免重启期间乱连接）
    2. 杀 DSH 桌面进程
    3. 等 8 秒 → 重新启动 DSH
    4. 等 NapCat 网关（3000）可答 get_status —— QQ 是独立进程，重启 DSH 不会带走它
    5. 起 TTS，等 /health 就绪（模型加载 30~60 秒）
    6. 起桥接
    7. 校验：桥接日志出现「SnowLuma 已连接」+ 至约定时长仍未连接则再重启一次桥接

  日志：D:\Backup\Documents\deepseek-harness\default-workspace\restart-dsh.log
  用法（通常由外层 detach 启动，不手工跑）：
    powershell -NoProfile -ExecutionPolicy Bypass -File restart-dsh-with-voice.ps1
#>
param(
  [int]$StartDelaySec = 25,
  [int]$DshBootWaitSec = 8,
  [int]$GatewayWaitSec = 120,
  [int]$TtsWaitSec = 180,
  [int]$BridgeWaitSec = 90
)

$ErrorActionPreference = 'Continue'
$WS = 'D:\Backup\Documents\deepseek-harness\default-workspace'
$BRIDGE = 'D:\Backup\Documents\deepseek-harness\qq-bridge'
$LOG = Join-Path $WS 'restart-dsh.log'
$DSH_EXE = 'C:\Users\Administrator\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe'
$NODE = 'C:\Users\Administrator\FlyEnv-Data\env\node\node.exe'
$CT_FILE = Join-Path $BRIDGE 'state\console-token'

function Log([string]$m, $c = 'Gray') {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $line -ForegroundColor $c
  Add-Content -LiteralPath $LOG -Value $line -Encoding UTF8
}

function Listening([int]$p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }

Log "===== 重启流程开始 =====" 'Cyan'

# 先等一会儿再动手：把宿主杀掉会同时杀掉发起它的那一轮对话，
# 留出时间让 agent 的说明文字先发出去。
if ($StartDelaySec -gt 0) {
  Log ("先等 {0} 秒（让界面把说明发完）" -f $StartDelaySec) 'DarkGray'
  Start-Sleep -Seconds $StartDelaySec
}

# ---------- 1) 先停服务 ----------
Log "1) 停桥接 + TTS"
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'bridge\.js' } |
  ForEach-Object { Log ("   停桥接 PID " + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'start-tts\.ps1|start-bridge-with-tts\.ps1|start-all\.ps1' } |
  ForEach-Object { Log ("   停守护 PID " + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'speak-server\.py' } |
  ForEach-Object { Log ("   停 TTS PID " + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

# ---------- 2) 杀 DSH ----------
Log "2) 结束 DSH 桌面进程"
$dsh = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
if ($dsh) {
  Log ("   找到 " + $dsh.Count + " 个进程: " + ($dsh.Id -join ', '))
  Stop-Process -Id $dsh.Id -Force -ErrorAction SilentlyContinue
} else {
  Log "   DSH 未在运行" 'Yellow'
}
Start-Sleep -Seconds $DshBootWaitSec

# ---------- 3) 重启 DSH ----------
Log "3) 启动 DSH：$DSH_EXE"
if (Test-Path -LiteralPath $DSH_EXE) {
  Start-Process -FilePath $DSH_EXE -WindowStyle Normal
  Log "   已发起（GUI 会自己重连；本脚本继续在后台推进）"
} else {
  Log "   !! 找不到 DSH 可执行文件，跳过" 'Red'
}
Start-Sleep -Seconds 12

# ---------- 4) 等 NapCat 网关 ----------
Log "4) 等 NapCat 网关（3000）就绪"
$gw = $false
$deadline = (Get-Date).AddSeconds($GatewayWaitSec)
while ((Get-Date) -lt $deadline) {
  try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/get_status' -TimeoutSec 4
    if ($r.status -eq 'ok' -or $r.retcode -eq 0) { $gw = $true; break }
  } catch { }
  Start-Sleep -Seconds 3
}
if ($gw) { Log "   网关就绪 ✅" 'Green' } else { Log "   网关未就绪（QQ 可能没开/NapCat 没加载）—— 仍会尝试起桥接" 'Yellow' }

# ---------- 5) 起 TTS ----------
Log "5) 启动 TTS 服务"
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $WS 'start-tts.ps1')) -WindowStyle Minimized
$tts = $false
$deadline = (Get-Date).AddSeconds($TtsWaitSec)
while ((Get-Date) -lt $deadline) {
  try { $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8188/health' -TimeoutSec 4; if ($h.ok) { $tts = $true; break } } catch { }
  Start-Sleep -Seconds 4
}
if ($tts) { Log "   TTS 就绪 ✅（24 kHz）" 'Green' } else { Log "   TTS 未就绪（继续，桥接仍可用，只是没有语音）" 'Yellow' }

# ---------- 6) 起桥接 ----------
Log "6) 启动桥接"
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $WS 'start-all.ps1')) -WindowStyle Minimized
$br = $false
$deadline = (Get-Date).AddSeconds($BridgeWaitSec)
while ((Get-Date) -lt $deadline) {
  if (Listening 3100) { $br = $true; break }
  Start-Sleep -Seconds 3
}
if (-not $br) { Log "   桥接未监听 3100" 'Red'; Log "===== 流程结束（失败）=====" 'Red'; return }

# ---------- 7) 校验网关连接 ----------
Log "7) 校验桥接 ↔ 网关链路"
Start-Sleep -Seconds 10
$connected = $false
for ($i = 1; $i -le 10; $i++) {
  try {
    if (Test-Path -LiteralPath $CT_FILE) {
      $ct = (Get-Content -LiteralPath $CT_FILE -Raw).Trim()
      $s = Invoke-RestMethod -Uri 'http://127.0.0.1:3100/api/status' -Headers @{ 'x-console-token' = $ct } -TimeoutSec 8
      if ($s.snowluma.connected -eq $true -and $s.snowluma.accountOnline -eq $true) { $connected = $true; break }
    }
  } catch { }
  Start-Sleep -Seconds 5
}

if (-not $connected) {
  Log "   未连上网关 → 重启一次桥接（上次是启动时序问题，重启即好）" 'Yellow'
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'bridge\.js' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 4
  Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $WS 'start-all.ps1')) -WindowStyle Minimized
  Start-Sleep -Seconds 20
  try {
    $ct = (Get-Content -LiteralPath $CT_FILE -Raw).Trim()
    $s = Invoke-RestMethod -Uri 'http://127.0.0.1:3100/api/status' -Headers @{ 'x-console-token' = $ct } -TimeoutSec 8
    if ($s.snowluma.connected -eq $true) { $connected = $true }
  } catch { }
}

if ($connected) { Log "   网关已连接 ✅" 'Green' } else { Log "   仍未连上（需要人工看一眼）" 'Red' }

# ---------- 汇总 ----------
$status = @()
foreach ($p in @(@{n='NapCat 网关';p=3000},@{n='TTS 服务';p=8188},@{n='qq-bridge';p=3100})) {
  $status += ("{0}={1}" -f $p.n, $(if (Listening $p.p) { 'UP' } else { 'DOWN' }))
}
Log ("状态: " + ($status -join '  ') + "   网关连接=" + $connected) 'Cyan'
Log "===== 重启流程结束 =====" 'Cyan'

# 收尾：删掉自己这条计划任务（它只在本次重启里有用，留着以后会被误触发）
try {
  Unregister-ScheduledTask -TaskName 'DshVoiceRestart' -Confirm:$false -ErrorAction SilentlyContinue
  Log "已清理计划任务 DshVoiceRestart" 'DarkGray'
} catch { }
