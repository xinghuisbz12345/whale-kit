#requires -Version 5.1
<#
  start-bridge-with-tts.ps1 -- one entry point that runs the TTS service AND the qq-bridge

  Use this instead of `npm start` when you want voice replies to work: it brings up the
  Ronova TTS service first, waits until it is actually ready (model loaded, ~10-30 s), and
  only then starts the bridge. The bridge's own MCP clients are started by DSH, so this
  script is the only launcher the bridge needs.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Backup\Documents\deepseek-harness\default-workspace\start-bridge-with-tts.ps1"
    ... -SkipTtsWait    # start the bridge immediately (first qq_speak may fail while loading)
    ... -NoTts          # plain bridge, exactly like `npm start`
    ... -TtsPort 8188

  Behaviour:
    * TTS runs in the background under its own supervisor window (start-tts.ps1).
    * This window then runs `node src/bridge.js` in the foreground, so you keep bridge logs
      and Ctrl+C stops the bridge (the TTS service keeps running; stop it with -StopTts).
    * A missing/failed TTS service never blocks text chat: the bridge starts anyway.
#>
param(
  [string]$BridgeDir = 'D:\Backup\Documents\deepseek-harness\qq-bridge',
  [string]$Workspace = 'D:\Backup\Documents\deepseek-harness\default-workspace',
  [int]$TtsPort = 8188,
  [int]$TtsWaitSec = 90,
  [switch]$NoTts,
  [switch]$SkipTtsWait,
  [switch]$StopTts
)

$ErrorActionPreference = 'Continue'
function Log([string]$m, $c = 'Gray') { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor $c }

$startTts = Join-Path $Workspace 'start-tts.ps1'
$bridgeJs = Join-Path $BridgeDir 'src\bridge.js'

$nodeExe = 'C:\Users\Administrator\FlyEnv-Data\env\node\node.exe'
if (-not (Test-Path -LiteralPath $nodeExe)) {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { $nodeExe = $cmd.Source } else { Log "ERROR: node not found" 'Red'; exit 2 }
}

function Get-TtsSupervisor {
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*start-tts.ps1*" }
}

if ($StopTts) {
  $sup = Get-TtsSupervisor
  if (-not $sup) { Log "no TTS supervisor process found" 'Yellow' }
  foreach ($p in $sup) { Log "stopping TTS supervisor PID $($p.ProcessId)"; Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*speak-server.py*' } |
    ForEach-Object { Log "stopping python PID $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  exit 0
}

function Test-TtsHealth {
  try { $r = Invoke-RestMethod -Uri "http://127.0.0.1:$TtsPort/health" -TimeoutSec 4; return [bool]$r.ok } catch { return $false }
}

if (-not $NoTts) {
  if (Test-TtsHealth) {
    Log "TTS service already up on port $TtsPort" 'Green'
  } else {
    Log "starting TTS supervisor in a separate window..."
    Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$startTts`"",'-Port',"$TtsPort") `
      -WindowStyle Minimized
  }

  if (-not $SkipTtsWait) {
    $deadline = (Get-Date).AddSeconds($TtsWaitSec)
    Log "waiting for the TTS model to load (up to ${TtsWaitSec}s)..."
    $ready = $false
    while ((Get-Date) -lt $deadline) {
      if (Test-TtsHealth) { $ready = $true; break }
      Start-Sleep -Seconds 3
    }
    if ($ready) { Log "TTS service is READY" 'Green' }
    else { Log "TTS service did not become ready in ${TtsWaitSec}s -- starting the bridge anyway (text chat works, qq_speak will fail until it is up)" 'Yellow' }
  }
}

Log "starting qq-bridge: $nodeExe $bridgeJs" 'Cyan'
Set-Location $BridgeDir
& $nodeExe $bridgeJs
$code = $LASTEXITCODE
Log "bridge exited with $code" $(if ($code -eq 0) { 'Gray' } else { 'Red' })
Log "TTS service (if started) is still running; stop it with:  ... -StopTts"
exit $code
