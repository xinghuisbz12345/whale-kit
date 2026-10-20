#requires -Version 5.1
<#
  start-tts.ps1 -- run the Ronova TTS service as a resident, self-healing process

  This is the "resident with the bridge" half: it keeps speak-server.py alive, restarting it
  if it exits, and never returning control until you stop it (Ctrl+C).

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Backup\Documents\deepseek-harness\default-workspace\start-tts.ps1"
    ... -Port 8188 -AudioDir "D:\Backup\Documents\deepseek-harness\qq-bridge\audio"
    ... -Once      # no supervision: run in the foreground, exit when the server stops
    ... -Check     # only probe /health and exit (is it running?)

  Notes:
    * The model load takes 10-30 s and ~3.4 GB of VRAM. The health endpoint only answers
      after the model is ready, so the bridge's first qq_speak may fail if it races startup.
    * Logs go to the console and to logs\tts-<date>.log.
#>
param(
  [int]$Port = 8188,
  [string]$AudioDir = 'D:\Backup\Documents\deepseek-harness\qq-bridge\audio',
  [string]$Root = 'E:\新建文件夹 (2)\ronova-cosyvoice3\ronova-cosyvoice3',
  [string]$ModelDir = 'E:\新建文件夹 (2)\ronova-cosyvoice3\base-model',
  [string]$ServerScript = 'D:\Backup\Documents\deepseek-harness\default-workspace\speak-server.py',
  [int]$RestartDelaySec = 5,
  [switch]$Once,
  [switch]$Check
)

$ErrorActionPreference = 'Continue'
$py = Join-Path $Root '.venv\Scripts\python.exe'
$logDir = Join-Path (Split-Path $ServerScript -Parent) 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("tts-" + (Get-Date -Format 'yyyyMMdd') + ".log")

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Host $line
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Test-Health {
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 4
    return [bool]$r.ok
  } catch { return $false }
}

if ($Check) {
  if (Test-Health) { Log "TTS service is UP on port $Port"; exit 0 }
  Log "TTS service is DOWN on port $Port"; exit 1
}

if (-not (Test-Path -LiteralPath $py)) { Log "ERROR: venv python not found: $py"; exit 2 }
if (-not (Test-Path -LiteralPath $ServerScript)) { Log "ERROR: server script not found: $ServerScript"; exit 2 }
if (-not (Test-Path -LiteralPath $ModelDir)) {
  Log "WARNING: base model dir not found: $ModelDir -- the service will fall back to Hugging Face"
}

if (Test-Health) {
  Log "A TTS service is already answering on port $Port -- nothing to do."
  exit 0
}

# The model dir must be passed explicitly: ronova_tts.py's own default would call
# snapshot_download() against huggingface.co, which is unreachable here.
$serverArgs = @(
  $ServerScript,
  '--root', $Root,
  '--audio-dir', $AudioDir,
  '--port', "$Port",
  '--model', $ModelDir
)

$attempt = 0
while ($true) {
  $attempt++
  Log "starting speak-server.py (attempt $attempt, port $Port)"

  $env:COSYVOICE_DIR = Join-Path $Root 'CosyVoice'
  $env:PYTHONIOENCODING = 'utf-8'
  $env:PYTHONUNBUFFERED = '1'
  # Keep HF local: never let a stray snapshot_download() reach the network.
  $env:HF_HUB_OFFLINE = '1'

  # Tee the child's output to the console and the log file.
  & $py @serverArgs 2>&1 | ForEach-Object {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $_
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
  }
  $code = $LASTEXITCODE

  if ($Once) { Log "server exited with $code (no supervision, -Once given)"; exit $code }
  Log "server exited with $code; restarting in ${RestartDelaySec}s (Ctrl+C to stop)"
  Start-Sleep -Seconds $RestartDelaySec
}
