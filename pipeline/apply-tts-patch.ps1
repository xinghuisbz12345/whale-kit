#requires -Version 5.1
<#
  apply-tts-patch.ps1 -- give qq-bridge the "Ronova voice, live TTS" ability (idempotent)

  Four edits, each guarded by a marker so re-running never duplicates anything:
    1) bridge.js            : add socialV2.voice.tts defaults
    2) bridge.js            : add synthesizeSpeech() helper
    3) bridge.js            : add POST /api/socialV2/speak endpoint
    4) bridge.js + mcp file : register qq_speak tool, tool flag, tool list

  Usage (run OUTSIDE DSH, in a normal PowerShell):
    powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Backup\Documents\deepseek-harness\default-workspace\apply-tts-patch.ps1"
    # undo:
    powershell ... -File "...\apply-tts-patch.ps1" -Revert

  Safety: originals are copied to .tts-backup-<timestamp>\ before any change.

  NOTE: this file must stay UTF-8 **with BOM** if it contains any non-ASCII text,
        because Windows PowerShell 5.1 reads BOM-less files as the ANSI codepage.
        Rewrite-Encoded.ps1 re-adds the BOM; keep the two in sync.
#>
param(
  [string]$BridgeDir = 'D:\Backup\Documents\deepseek-harness\qq-bridge',
  [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $BridgeDir ".tts-backup-$stamp"
$bridgeJs = Join-Path $BridgeDir 'src\bridge.js'
$mcpJs    = Join-Path $BridgeDir 'src\mcp-snowluma-safe.js'

function Log($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Read-Text([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-Text([string]$p, [string]$t) {
  $enc = New-Object System.Text.UTF8Encoding($false)   # no BOM: these are JS sources
  [System.IO.File]::WriteAllText($p, $t, $enc)
}

if (-not (Test-Path -LiteralPath $bridgeJs)) { throw "cannot find $bridgeJs" }
if (-not (Test-Path -LiteralPath $mcpJs))    { throw "cannot find $mcpJs" }

if ($Revert) {
  $dirs = Get-ChildItem -LiteralPath $BridgeDir -Directory -Filter '.tts-backup-*' | Sort-Object Name -Descending
  if (-not $dirs) { throw "no .tts-backup-* directory found" }
  $src = $dirs[0].FullName
  Copy-Item -LiteralPath (Join-Path $src 'bridge.js') -Destination $bridgeJs -Force
  Copy-Item -LiteralPath (Join-Path $src 'mcp-snowluma-safe.js') -Destination $mcpJs -Force
  Log "restored from $src" 'Green'
  return
}

New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -LiteralPath $bridgeJs -Destination (Join-Path $backup 'bridge.js') -Force
Copy-Item -LiteralPath $mcpJs    -Destination (Join-Path $backup 'mcp-snowluma-safe.js') -Force
Log "backup -> $backup" 'DarkGray'

$bridge = Read-Text $bridgeJs
$mcp    = Read-Text $mcpJs
$nl     = if ($bridge.Contains("`r`n")) { "`r`n" } else { "`n" }
Log ("line ending of bridge.js: " + $(if ($nl -eq "`r`n") { 'CRLF' } else { 'LF' })) 'DarkGray'

function Eol([string]$s) { $s.Replace("`r`n", "`n").Replace("`n", $nl) }

function Insert-After([string]$text, [string]$anchor, [string]$block, [string]$label) {
  # CONTRACT: $anchor must NOT end with a newline and $block must start with one.
  # A here-string anchor that keeps its trailing newline silently glues the block's first
  # line onto the anchor's last line (the newline becomes a blank line instead of a break).
  $anchor = $anchor.TrimEnd("`r", "`n")
  $probe = (Eol $block).Trim()
  if ($text.Contains($probe)) { Log "  [skip] $label (already present)" 'DarkGray'; return $text }
  $i = $text.IndexOf($anchor)
  if ($i -lt 0) { throw "anchor not found for: $label" }
  $j = $i + $anchor.Length
  Log "  [ok]   $label" 'Green'
  return $text.Substring(0, $j) + (Eol $block) + $text.Substring($j)
}

function Replace-Once([string]$text, [string]$find, [string]$repl, [string]$label) {
  $r = Eol $repl
  if ($text.Contains($r.Trim())) { Log "  [skip] $label (already present)" 'DarkGray'; return $text }
  $i = $text.IndexOf($find)
  if ($i -lt 0) { throw "replacement target not found: $label" }
  Log "  [ok]   $label" 'Green'
  return $text.Substring(0, $i) + $r + $text.Substring($i + $find.Length)
}

# Regex variant: line-ending agnostic. Use it for files whose EOL differs from the one we
# detected (config.json is LF here while bridge.js is CRLF) or where exact spacing is not
# worth pinning. Requires exactly one match unless -AllowMany.
function Replace-Regex([string]$text, [string]$pattern, [string]$repl, [string]$label, [switch]$AllowMany) {
  $probe = ($repl -replace '\$\d+', '').Trim()
  if ($text.Contains($probe)) { Log "  [skip] $label (already present)" 'DarkGray'; return $text }
  $rx = [regex]::new($pattern)
  if (-not $rx.IsMatch($text)) { throw "regex target not found: $label  (pattern: $pattern)" }
  $n = $rx.Matches($text).Count
  if ($n -gt 1 -and -not $AllowMany) { throw "regex matched $n times (expected 1): $label" }
  Log "  [ok]   $label" 'Green'
  # [regex]::Replace would expand $1 in the replacement, which we want here.
  return $rx.Replace($text, $repl, 1)
}

# ================================================================ bridge.js
Log "== 1/4  bridge.js: socialV2.voice.tts defaults" 'Cyan'
# Two contracts here, both learned by breaking them:
#  (1) the user's `...(cfg.socialV2?.voice ?? {})` spread must come LAST among the scalar
#      defaults, or a default silently overwrites the operator's config.json;
#  (2) tts is an OBJECT, so spreading the whole voice object after a `tts: {...}` literal
#      REPLACES that literal wholesale. The defaults therefore live INSIDE the tts literal
#      and the nested user value spreads after them.
# Getting this wrong is invisible in the file and looks exactly like "config.json says
# enabled:true but the bridge reports enabled:false".
$bridge = Replace-Once $bridge `
  "    ...(cfg.socialV2?.voice ?? {})" `
  @'
    // ---- Ronova live TTS (added by apply-tts-patch.ps1) ----
    // Distinct from "send a file from the voice library": the text is synthesised on the
    // spot into a wav inside the library, then sent through the existing channel. The synth
    // runs as a separate resident process (speak-server.py); if it is down, only qq_speak
    // fails -- text chat keeps working.
    tts: {
      enabled: false,
      url: 'http://127.0.0.1:8188',
      defaultLang: 'zh',
      speed: 1.0,
      seed: 1,
      maxChars: 120,
      timeoutMs: 120000,
      verify: true,
      ...(cfg.socialV2?.voice?.tts ?? {})
    },
    ...(cfg.socialV2?.voice ?? {}),
'@ 'voice.tts defaults'

Log "== 2/4  bridge.js: synthesizeSpeech()" 'Cyan'
$bridge = Insert-After $bridge (Eol @'
      autoReadback: v.autoReadback !== false
    };
  }
'@) @'

  /**
   * Ronova live TTS (added by apply-tts-patch.ps1): synthesise text into a wav that lives
   * inside the voice library. Sending stays in sendVoiceForV2, so allow-lists, budgets and
   * the read-back verification behave exactly like a hand-sent library voice.
   * NOTE: these two must be siblings of voiceCfg, not nested inside it -- anchored on
   * `function voiceCfg() {` they end up in its body and the route then throws
   * "synthesizeSpeech is not defined" at call time (hoisting does not cross a scope).
   */
  function ttsCfg() {
    const v = cfg.socialV2?.voice ?? {};
    return {
      enabled: false,
      url: 'http://127.0.0.1:8188',
      defaultLang: 'zh',
      speed: 1.0,
      seed: 1,
      maxChars: 120,
      timeoutMs: 120000,
      verify: true,
      ...(v.tts ?? {})
    };
  }

  async function synthesizeSpeech(text, { lang = null, speed = null, seed = null } = {}) {
    const t = ttsCfg();
    if (!t.enabled) throw new Error('live TTS is off (socialV2.voice.tts.enabled=false)');
    const body = String(text ?? '').trim();
    if (!body) throw new Error('qq_speak needs text');
    if (body.length > t.maxChars) {
      throw new Error(`text too long for live speech (${body.length} > ${t.maxChars}); split it into short lines`);
    }
    const payload = {
      text: body,
      lang: lang || t.defaultLang,
      speed: speed === null || speed === undefined ? t.speed : Number(speed),
      seed: seed === null || seed === undefined ? t.seed : Number(seed),
      clean: true
    };
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), t.timeoutMs);
    let data;
    try {
      const res = await fetch(`${t.url.replace(/\/+$/, '')}/tts`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
        signal: ac.signal
      });
      data = await res.json().catch(() => null);
      if (!res.ok || !data?.ok) throw new Error(`TTS service error: ${data?.error || res.status}`);
    } catch (err) {
      if (err?.name === 'AbortError') throw new Error(`TTS synthesis timed out (>${t.timeoutMs}ms)`);
      if (err?.cause?.code === 'ECONNREFUSED' || /fetch failed/i.test(String(err?.message))) {
        throw new Error(`cannot reach the TTS service at ${t.url}; start speak-server.py first`);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
    const resolved = resolveVoicePathForV2(data.file);
    return { ...data, resolved };
  }
'@ 'synthesizeSpeech helper'

Log "== 3/4  bridge.js: POST /api/socialV2/speak" 'Cyan'
# ANCHOR CONTRACT (learned the hard way, four times). Placement is the whole problem here:
# a block that parses but sits inside another route's `if` body is UNREACHABLE, and the only
# symptom is a bare 404 on /speak. Anchors that all passed `node --check` yet failed:
#   * after the send-voice `if (...) {`     -> nested inside send-voice
#   * before the send-sticker `if (...) {`  -> nested inside send-sticker
#   * after the send-sticker `if (...) {`   -> still nested inside send-sticker
#   * after collect-sticker's `if (...) {`  -> nested inside collect-sticker
# This anchor is the LAST route in the request handler plus the handler's own 404 fallback,
# so the block provably lands at the top level of the dispatch chain. After every repatch,
# call the route and require something OTHER than 404 -- a syntax check proves nothing here.
$bridgeAnchor3 = @'
            releaseLock();
            process.exit(0);
          }, 500);
          return;
        }
'@
$bridge = Insert-After $bridge (Eol $bridgeAnchor3) @'

        // Ronova live TTS (added by apply-tts-patch.ps1): synthesise, then reuse every
        // gate that send-voice already has (mode, token, allow-list, tool flag, budget).
        if (req.method === 'POST' && url.pathname === '/api/socialV2/speak') {
          const body = await readBody();
          const key = String(body.key ?? '').trim();
          if (!key) { sendJson({ ok: false, error: 'key is required' }, 400); return; }
          const voice = voiceCfg();
          if (!voice.enabled) { sendJson({ ok: false, error: 'voice is disabled' }, 403); return; }
          if (currentMode !== 'reserved2') { sendJson({ ok: false, error: 'this endpoint needs reserved2 mode' }, 403); return; }
          if (!req.headers['x-agent-token']) { sendJson({ ok: false, error: 'reserved2 sends must carry an agent token' }, 403); return; }
          if (!agentTokenOk(key, req.headers['x-agent-token'])) { sendJson({ ok: false, error: 'invalid agent token' }, 403); return; }
          if (!v2SessionAllowed(key)) { sendJson({ ok: false, error: 'target outside the allowed scope' }, 403); return; }
          if (!v2ToolEnabled('speak')) { sendJson({ ok: false, error: 'tool disabled: qq_speak' }, 403); return; }
          const m = /^(group|private):(\d+)$/.exec(key);
          if (!m) { sendJson({ ok: false, error: 'key must be group:<id> or private:<id>' }, 400); return; }
          try {
            const synth = await synthesizeSpeech(body.text ?? body.message, {
              lang: body.lang, speed: body.speed, seed: body.seed
            });
            const t = ttsCfg();
            voiceBudgetCheck(key, voice);
            const sent = await sendVoiceForV2(key, synth.file, {
              label: body.label ?? '',
              verify: body.verify === undefined ? t.verify : !!body.verify,
              readback: false
            });
            sendJson({
              ok: true,
              file: synth.file,
              seconds: synth.seconds,
              cached: synth.cached,
              synthMs: synth.ms,
              cleaned: synth.cleaned,
              messageId: sent?.messageId ?? null,
              verified: sent?.verified ?? null
            });
          } catch (err) {
            // A failed synthesis must not burn budget: voiceBudgetCommit only runs after a
            // successful send, so there is nothing to roll back here.
            sendJson({ ok: false, error: String(err?.message ?? err) },
              /too long|needs text|nothing to read/i.test(String(err?.message)) ? 400 : 502);
          }
          return;
        }
'@ 'speak endpoint'

Log "== 4/4  bridge.js: tool flag table + tool list" 'Cyan'
$bridge = Replace-Once $bridge `
  ("    sendVoice: false," + $nl + "    ...(cfg.socialV2.tools ?? {})") `
  ("    sendVoice: false," + $nl + "    speak: false," + $nl + "    ...(cfg.socialV2.tools ?? {})") `
  "tools defaults += speak"
$bridge = Replace-Once $bridge `
  "            sendVoice: 'qq_send_voice / qq_list_voices'" `
  ("            sendVoice: 'qq_send_voice / qq_list_voices'," + $nl + "            speak: 'qq_speak'") `
  "tool list += speak"
# The console's save-config endpoint only persists flags listed in toolFlags; without this
# the new switch would silently revert to its default on the next console save (bridge.js:4211).
$bridge = Replace-Once $bridge `
  "'collectSticker', 'getSelfImage', 'sendVoice']" `
  "'collectSticker', 'getSelfImage', 'speak', 'sendVoice']" `
  "console toolFlags += speak"

# ================================================================ mcp file
Log "== mcp-snowluma-safe.js: register qq_speak" 'Cyan'
$mcp = Replace-Once $mcp `
  "  qq_list_voices: 'sendVoice'," `
  ("  qq_list_voices: 'sendVoice'," + $nl + "  qq_speak: 'speak',") `
  "TOOL_CONFIG_FLAGS += qq_speak"

# Insert INSIDE the same `if (voice.enabled && tools.sendVoice)` block as qq_list_voices,
# right after that tool's closing `);` -- verified against src/mcp-snowluma-safe.js (line ~1090).
$mcpAnchor = @'
        return { content: [{ type: 'text', text: `获取语音库失败：${error?.message ?? error}` }], isError: true };
      }
    }
  );
'@
$mcpAnchor = Eol $mcpAnchor
if (-not $mcp.Contains($mcpAnchor)) { throw "mcp anchor (qq_list_voices tail) not found; the file changed?" }

$mcp = Insert-After $mcp $mcpAnchor @'

  // ---- qq_speak: Ronova live TTS (added by apply-tts-patch.ps1) ----
  server.tool(
    'qq_speak',
    '\u7528\u82e5\u5a1c\u74e6\u97f3\u8272\u628a\u4e00\u53e5\u8bdd\u5b9e\u65f6\u5408\u6210\u6210\u8bed\u97f3\u5e76\u53d1\u5230\u7fa4\u91cc\uff0f\u79c1\u804a\u3002\u9002\u5408\u77ed\u53e5\u3001\u6253\u62db\u547c\u3001\u8868\u8fbe\u60c5\u7eea\uff1b\u6587\u5b57\u4ecd\u5e94\u7167\u5e38\u5148\u53d1\uff08\u672c\u5de5\u5177\u53ea\u8865\u4e00\u6761\u8bed\u97f3\uff09\u3002\u4e00\u6b21\u6700\u591a\u4e00\u6761\uff0c\u522b\u8fde\u53d1\uff1b\u957f\u6587\u4e0d\u8981\u7528\u8bed\u97f3\u3002\u5408\u6210\u9700\u8981\u51e0\u79d2\uff0c\u8fd4\u56de verified=true \u624d\u4ee3\u8868\u8bed\u97f3\u771f\u7684\u53d1\u51fa\u53bb\u4e86\u3002',
    {
      key: z.string().describe('conversation key, group:<id> or private:<id>'),
      token: z.string().describe('conversation token (see the wake-up prompt)'),
      text: z.string().describe('text to speak (keep it short, under ~40 chars; brackets, Markdown and links are stripped into pauses)'),
      lang: z.enum(['zh', 'en', 'ja']).optional().describe('language, default zh'),
      speed: z.number().optional().describe('speaking rate, keep within 0.85-1.2'),
      label: z.string().optional().describe('note for the session log, e.g. "said goodnight by voice"')
    },
    async ({ key, token, text, lang, speed, label }) => {
      try {
        const data = await agentApi('/api/socialV2/speak', {
          method: 'POST',
          body: JSON.stringify({ key, token, text, lang, speed, label: label || '' }),
          headers: { 'x-agent-token': token },
          timeoutMs: 300000
        });
        return { content: [{ type: 'text', text: serializeModelData(data) }] };
      } catch (error) {
        return { content: [{ type: 'text', text: `qq_speak failed: ${error?.message ?? error}` }], isError: true };
      }
    }
  );
'@ 'qq_speak tool definition'

# ================================================================ config.json
# NOTE: on this machine config.json is LF while bridge.js is CRLF, so the config edits must
# NOT reuse the line ending detected from bridge.js. Match with \s* and write LF back, which
# keeps config.json byte-consistent with its sibling files.
Log "== 5/5  config.json: enable speak + tts" 'Cyan'
$cfgPath = Join-Path $BridgeDir 'config.json'
if (Test-Path -LiteralPath $cfgPath) {
  Copy-Item -LiteralPath $cfgPath -Destination (Join-Path $backup 'config.json') -Force
  $cfgText = Read-Text $cfgPath

  $cfgText = Replace-Regex $cfgText `
    '"sendVoice":\s*true(\s*\})' `
    ('"sendVoice": true,' + "`n" + '      "speak": true$1') `
    'config tools += speak'

  $cfgText = Replace-Regex $cfgText `
    '"autoReadback":\s*true(\s*\})' `
    ('"autoReadback": true,' + "`n" +
     '      "tts": {' + "`n" +
     '        "enabled": true,' + "`n" +
     '        "url": "http://127.0.0.1:8188",' + "`n" +
     '        "defaultLang": "zh",' + "`n" +
     '        "speed": 1.0,' + "`n" +
     '        "seed": 1,' + "`n" +
     '        "maxChars": 120,' + "`n" +
     '        "timeoutMs": 120000,' + "`n" +
     '        "verify": true' + "`n" +
     '      }$1') `
    'config voice.tts added'

  try {
    $null = $cfgText | ConvertFrom-Json
    Log "  [ok]   config.json parses as valid JSON" 'Green'
  } catch {
    Copy-Item -LiteralPath (Join-Path $backup 'config.json') -Destination $cfgPath -Force
    throw "config.json edit produced invalid JSON -- restored from backup. $_"
  }
  Write-Text $cfgPath $cfgText
} else {
  Log "  [skip] no config.json at $cfgPath" 'DarkGray'
}

Write-Text $bridgeJs $bridge
Write-Text $mcpJs $mcp

Log ""
Log "done. backup: $backup" 'Green'
Log "revert:  ... -File `"apply-tts-patch.ps1`" -Revert" 'DarkGray'
Log ""
Log "next:" 'Cyan'
Log "  1) set socialV2.tools.speak = true and socialV2.voice.tts.enabled = true in config.json"
Log "  2) start the TTS service: speak-server.py --audio-dir <qq-bridge>\audio --port 8188"
Log "  3) restart qq-bridge"
