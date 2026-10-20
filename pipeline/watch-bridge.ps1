#requires -Version 5.1
<#
  watch-bridge.ps1 -- 小鲸鱼守护进程（常驻）

  为什么要它：今天 qq-bridge 自己挂了两次（22:48、23:05），每次都导致"喊她不理"，
  只能人工重启。这个守护每 30 秒体检一次，挂了就自动拉起。

  体检项与处置：
    1. 网关 3000（跑在 QQ 里）
       - 不通 → 只记日志、**不重启桥接**（没有网关，桥接起来也没用），并提醒"QQ 掉了"
    2. TTS 8188
       - 不通 → 调 start-all.ps1（它会先起 TTS 再起桥接）
    3. qq-bridge 3100
       - 不通 → 调 start-all.ps1 重启
    4. 3100 通但 connected=false 连续 3 次（约 90 秒）
       - 判为"WS 卡死"→ 重启桥接（这是已知的启动时序/重连问题，重启即好）

  防雪崩：
    - 30 分钟内最多重启 8 次；超了进冷却 10 分钟，只记日志
    - 单实例：靠计划任务的 MultipleInstances=IgnoreNew 保证

  日志：D:\Backup\Documents\deepseek-harness\default-workspace\logs\watchdog.log
  注册：计划任务 GsvWatchdog（登录时启动 + 立即启动）
#>
param(
  [int]$PollSec = 30,
  [int]$MaxRestartsPer30Min = 8,
  [int]$CooldownMin = 10,
  [string]$Workspace = 'D:\Backup\Documents\deepseek-harness\default-workspace'
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $Workspace 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir 'watchdog.log'
$startAll = Join-Path $Workspace 'start-all.ps1'
$restarts = New-Object System.Collections.ArrayList
$notConnectedCount = 0
$consecutiveFail = 0   # 连续失败计数：单次失败不动手，避免和 restart-dsh 抢着重启
$cooldownUntil = [DateTime]::MinValue
$gatewayWarned = $false

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
  # 日志超过 1MB 就轮转一次，别无限长
  try {
    if ((Get-Item -LiteralPath $log).Length -gt 1MB) {
      Move-Item -LiteralPath $log -Destination ($log + '.1') -Force
    }
  } catch { }
}

function Listening([int]$p) {
  [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
}

function BridgeConnected([string]$ct) {
  try {
    $s = Invoke-RestMethod -Uri 'http://127.0.0.1:3100/api/status' `
      -Headers @{ 'x-console-token' = $ct } -TimeoutSec 6
    return [bool]$s.snowluma.connected
  } catch { return $false }
}

function Restart-Stack([string]$why) {
  if ($script:lastStackRestart -and ((Get-Date) - $script:lastStackRestart).TotalMinutes -lt 5) { Log ("  距上次重启不足 5 分钟，跳过（$why）"); return }
  $script:lastStackRestart = Get-Date
  if ((Get-Date) -lt $cooldownUntil) {
    Log ("  冷却中（到 " + $cooldownUntil.ToString('HH:mm:ss') + "），跳过重启：$why")
    return
  }
  $now = Get-Date
  # 只保留最近 30 分钟的记录
  $recent = @($restarts | Where-Object { ($now - $_).TotalMinutes -lt 30 })
  $restarts.Clear(); foreach ($t in $recent) { [void]$restarts.Add($t) }
  if ($restarts.Count -ge $MaxRestartsPer30Min) {
    $cooldownUntil = $now.AddMinutes($CooldownMin)
    Log ("  ⚠ 30 分钟内重启已达 $($restarts.Count) 次，进入 $CooldownMin 分钟冷却（$why）")
    return
  }
  [void]$restarts.Add($now)
  Log ("  → 重启语音栈：$why")
  try {
    Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $startAll) `
      -WindowStyle Minimized | Out-Null
  } catch { Log ("    启动失败: " + $_.Exception.Message) }
  # 给 start-all 一点时间，别在下一轮立刻又判死
  Start-Sleep -Seconds 40
}

Log "================ 守护启动 ================"
Log ("参数: 轮询 ${PollSec}s, 30分钟最多重启 $MaxRestartsPer30Min 次")

while ($true) {
  try {
    # ⚠️ 如果 start-all.ps1 正在跑（用户手动启动 / 重启脚本 / TTS 还在加载模型），
    # 就**不要**判定"服务挂了"。TTS 加载要 50~60 秒，单看端口会误判成失败，
    # 结果守护把刚起来的栈又重启一遍 —— PID 一直变就是这么来的。
    $booting = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match 'start-all\.ps1' }
    if ($booting) {
      Start-Sleep -Seconds $PollSec
      continue
    }
    $ctFile = 'D:\Backup\Documents\deepseek-harness\qq-bridge\state\console-token'
    $ct = if (Test-Path -LiteralPath $ctFile) { (Get-Content -LiteralPath $ctFile -Raw).Trim() } else { '' }

    # ---- 1) 网关 ----
    $gw = Listening 3000
    if (-not $gw) {
      if (-not $gatewayWarned) {
        Log "⚠ 网关 3000 不通（QQ 掉线/未启动）—— 不重启桥接，等 QQ 恢复后自动接上"
        $gatewayWarned = $true
      }
      Start-Sleep -Seconds $PollSec
      continue
    }
    if ($gatewayWarned) { Log "网关已恢复"; $gatewayWarned = $false }

    # ---- 2) TTS ----
    # ⚠️ 判"挂没挂"要看**进程**，不能只看端口：TTS 加载模型要 50~60 秒，
    # 这期间端口是不通的，但它没挂。之前只看端口 → 守护把"正在加载"当成"挂了"，
    # 于是不停重启，形成重启风暴（今天 22 次就是这么来的）。
    $ttsProc = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match 'speak-server\.py' }
    if (-not (Listening 8188) -and $ttsProc) {
      if ($consecutiveFail -eq 0) { Log "TTS 进程在，但 8188 还没就绪（正在加载模型）—— 不重启，等它" }
      $consecutiveFail = 0
      Start-Sleep -Seconds $PollSec
      continue
    }
    if (-not (Listening 8188)) {
      $consecutiveFail++
      Log ("✗ TTS 8188 不通（连续 $consecutiveFail 次）")
      # ⚠️ 只在连续 2 次（约 60 秒）都失败时才重启：restart-dsh-with-voice.ps1 会
      # 先停服务再起，单次失败很可能是它正在干活，抢着重启会导致桥接被启动两次、
      # prompt 队列卡死（02:14 那次就是这样）。
      if ($consecutiveFail -ge 2) { Restart-Stack "TTS 未监听（连续 60 秒）"; $consecutiveFail = 0 }
      continue
    }
    $consecutiveFail = 0

    # ---- 3) 桥接 ----
    if (-not (Listening 3100)) {
      Log "✗ qq-bridge 3100 不通"
      Restart-Stack "桥接未监听"
      $notConnectedCount = 0
$consecutiveFail = 0   # 连续失败计数：单次失败不动手，避免和 restart-dsh 抢着重启
      continue
    }

    # ---- 4) 桥接在跑但没连上网关 ----
    if ($ct) {
      if (-not (BridgeConnected $ct)) {
        $notConnectedCount++
        Log ("⚠ 桥接在跑但网关未连接（连续 $notConnectedCount 次）")
        if ($notConnectedCount -ge 3) {
          Restart-Stack "WS 卡死（90 秒未连上）"
          $notConnectedCount = 0
$consecutiveFail = 0   # 连续失败计数：单次失败不动手，避免和 restart-dsh 抢着重启
          continue
        }
      } else {
        $notConnectedCount = 0
$consecutiveFail = 0   # 连续失败计数：单次失败不动手，避免和 restart-dsh 抢着重启
      }
    }

    # 一切正常：静默（只在状态切换时说话，避免日志刷屏）
  } catch {
    Log ("守护循环异常: " + $_.Exception.Message)
  }
  Start-Sleep -Seconds $PollSec
}
