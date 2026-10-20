#requires -Version 5.1
<#
  start-all.ps1 -- one command to bring the whole voice stack up

  Starts, in order:
    1. Ronova TTS service   (port 8188, resident, self-restarting)
    2. qq-bridge           (port 3100, foreground)

  Then reports the state of everything, including the one thing it CANNOT start:
  the SnowLuma gateway (port 3000), which QQ send/receive depends on.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Backup\Documents\deepseek-harness\default-workspace\start-all.ps1"
    ... -StatusOnly     # just report what is up, start nothing
    ... -StopAll        # stop TTS supervisor, TTS server and bridge

  After a reboot run this once. Keep this window open: closing it stops the bridge
  (the TTS service is supervised separately and keeps running).
#>
param(
  [switch]$StatusOnly,
  [switch]$StopAll,
  [int]$TtsPort = 8188,
  [int]$BridgePort = 3100,
  [int]$GatewayPort = 3000,
  [string]$Workspace = 'D:\Backup\Documents\deepseek-harness\default-workspace'
)

$ErrorActionPreference = 'Continue'
function Log($m, $c = 'Gray') { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor $c }

# ---- ffmpeg / ffprobe：GPT-SoVITS 整合包自带静态版，直接指过去 ----
# 桥接用 FFPROBE_PATH 探测语音时长（不设就会 spawn ffprobe 失败，语音仍能发但没时长校验）；
# 音量处理用 FFMPEG_PATH（config.socialV2.voice.ffmpegPath 也会被读，两处都设最稳）。
$gsvRuntime = 'E:\voice-engines\gpt-sovits\GPT-SoVITS-v2pro-20261006nvidia50x0\runtime'
$ffprobeExe = Join-Path $gsvRuntime 'ffprobe.exe'
$ffmpegExe  = Join-Path $gsvRuntime 'ffmpeg.exe'
if (Test-Path -LiteralPath $ffprobeExe) { $env:FFPROBE_PATH = $ffprobeExe }
if (Test-Path -LiteralPath $ffmpegExe)  { $env:FFMPEG_PATH  = $ffmpegExe }

function Listening([int]$p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }
function ProcOf([int]$p) { (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess }

if ($StopAll) {
  Log "stopping bridge..." 'Yellow'
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'bridge\.js' } |
    ForEach-Object { Log "  kill node PID $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Log "stopping TTS supervisor + server..." 'Yellow'
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'start-tts\.ps1|start-bridge-with-tts\.ps1' } |
    ForEach-Object { Log "  kill powershell PID $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'speak-server\.py' } |
    ForEach-Object { Log "  kill python PID $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Log "done." 'Green'
  return
}

function Show-Status {
  Log "---------- 状态 ----------" 'Cyan'
  foreach ($x in @(
    @{ n = 'TTS 服务      (8188)'; p = $TtsPort;     must = $true },
    @{ n = 'qq-bridge     (3100)'; p = $BridgePort;  must = $true },
    @{ n = 'SnowLuma 网关 (3000)'; p = $GatewayPort; must = $false }
  )) {
    if (Listening $x.p) {
      Log ("  [OK]   {0}  PID {1}" -f $x.n, (ProcOf $x.p)) 'Green'
    } elseif ($x.must) {
      Log ("  [DOWN] {0}  需要启动" -f $x.n) 'Red'
    } else {
      Log ("  [DOWN] {0}  —— 需你自行启动 SnowLuma，否则 QQ 收发不可用" -f $x.n) 'Yellow'
    }
  }
  $v = Join-Path 'D:\Backup\Documents\deepseek-harness\qq-bridge\audio' '*.wav'
  $n = (Get-ChildItem -Path $v -ErrorAction SilentlyContinue | Measure-Object).Count
  Log ("  语音库: {0} 个文件" -f $n)
}

if ($StatusOnly) { Show-Status; return }

if (-not (Listening $TtsPort)) {
  $startTts = Join-Path $Workspace 'start-tts.ps1'
  Log "starting TTS service (model load 10-30s)..."
  Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$startTts`"",'-Port',"$TtsPort") `
    -WindowStyle Minimized
  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline -and -not (Listening $TtsPort)) { Start-Sleep -Seconds 3 }
  if (Listening $TtsPort) { Log "TTS service READY" 'Green' } else { Log "TTS service did not come up (bridge will still start)" 'Yellow' }
} else {
  Log "TTS service already up" 'Green'
}

if (Listening $BridgePort) {
  Log "bridge already up (PID $(ProcOf $BridgePort)) -- not starting a second one" 'Green'
  Show-Status
  return
}

$bridgeJs = 'D:\Backup\Documents\deepseek-harness\qq-bridge\src\bridge.js'
$nodeExe  = 'C:\Users\Administrator\FlyEnv-Data\env\node\node.exe'
if (-not (Test-Path -LiteralPath $nodeExe)) { $nodeExe = (Get-Command node).Source }
Log "starting qq-bridge: $bridgeJs" 'Cyan'
Set-Location 'D:\Backup\Documents\deepseek-harness\qq-bridge'
& $nodeExe $bridgeJs
Log "bridge exited with $LASTEXITCODE" 'Red'
Log "TTS service is still running; stop it with:  ... -StopAll"
