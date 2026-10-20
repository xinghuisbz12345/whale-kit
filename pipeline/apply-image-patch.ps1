#requires -Version 5.1
<#
  apply-image-patch.ps1 -- 给 qq-bridge 加"发图到 QQ"的能力（幂等，可 -Revert）

  新增：
    1) bridge.js : socialV2.image 默认配置
    2) bridge.js : imageCfg / fetchImageBytes / sendImageForV2（按 bvid 取封面，或直接给 url）
    3) bridge.js : POST /api/socialV2/send-image
    4) bridge.js : 工具开关 sendImage + 工具清单 + 控制台 toolFlags
    5) mcp-snowluma-safe.js : 注册 qq_send_image 工具
    6) config.json : tools.sendImage = true，socialV2.image 默认值

  为什么按 bvid 取封面而不是读插件：插件的 MCP 只暴露了 11 个工具（无 video_info），
  而 B站 的 view 接口是公开的，桥接自己取更省事，也不用改 Python 插件。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File apply-image-patch.ps1
    powershell ... -Revert

  教训沿用（见 ronova-tts-plan.md 第 6 节）：node --check 只能证明语法，
  插错位置会"能跑但不可达"，所以打完必须真的调一次端点、要求非 404。
#>
param(
  [string]$BridgeDir = 'D:\Backup\Documents\deepseek-harness\qq-bridge',
  [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $BridgeDir ".img-backup-$stamp"
$bridgeJs = Join-Path $BridgeDir 'src\bridge.js'
$mcpJs    = Join-Path $BridgeDir 'src\mcp-snowluma-safe.js'
$cfgPath  = Join-Path $BridgeDir 'config.json'

function Log($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Read-Text([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-Text([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false))) }

if (-not (Test-Path -LiteralPath $bridgeJs)) { throw "找不到 $bridgeJs" }

if ($Revert) {
  $dirs = Get-ChildItem -LiteralPath $BridgeDir -Directory -Filter '.img-backup-*' | Sort-Object Name -Descending
  if (-not $dirs) { throw "没有 .img-backup-* 备份" }
  $src = $dirs[0].FullName
  Copy-Item -LiteralPath (Join-Path $src 'bridge.js') -Destination $bridgeJs -Force
  Copy-Item -LiteralPath (Join-Path $src 'mcp-snowluma-safe.js') -Destination $mcpJs -Force
  Copy-Item -LiteralPath (Join-Path $src 'config.json') -Destination $cfgPath -Force
  Log "已还原自 $src" 'Green'
  return
}

New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -LiteralPath $bridgeJs -Destination (Join-Path $backup 'bridge.js') -Force
Copy-Item -LiteralPath $mcpJs    -Destination (Join-Path $backup 'mcp-snowluma-safe.js') -Force
Copy-Item -LiteralPath $cfgPath  -Destination (Join-Path $backup 'config.json') -Force
Log "备份 -> $backup" 'DarkGray'

$bridge = Read-Text $bridgeJs
$mcp    = Read-Text $mcpJs
$nl     = if ($bridge.Contains("`r`n")) { "`r`n" } else { "`n" }
function Eol([string]$s) { $s.Replace("`r`n", "`n").Replace("`n", $nl) }

function Insert-After([string]$text, [string]$anchor, [string]$block, [string]$label) {
  $anchor = $anchor.TrimEnd("`r", "`n")
  if ($text.Contains((Eol $block).Trim())) { Log "  [skip] $label (已存在)" 'DarkGray'; return $text }
  $i = $text.IndexOf($anchor)
  if ($i -lt 0) { throw "锚点未找到: $label" }
  $j = $i + $anchor.Length
  Log "  [ok]   $label" 'Green'
  return $text.Substring(0, $j) + (Eol $block) + $text.Substring($j)
}

function Insert-Before([string]$text, [string]$anchor, [string]$block, [string]$label) {
  if ($text.Contains((Eol $block).Trim())) { Log "  [skip] $label (已存在)" 'DarkGray'; return $text }
  $i = $text.IndexOf($anchor)
  if ($i -lt 0) { throw "锚点未找到: $label" }
  Log "  [ok]   $label" 'Green'
  return $text.Substring(0, $i) + (Eol $block) + $text.Substring($i)
}

function Replace-Once([string]$text, [string]$find, [string]$repl, [string]$label) {
  $r = Eol $repl
  if ($text.Contains($r.Trim())) { Log "  [skip] $label (已存在)" 'DarkGray'; return $text }
  $i = $text.IndexOf($find)
  if ($i -lt 0) { throw "替换目标未找到: $label" }
  Log "  [ok]   $label" 'Green'
  return $text.Substring(0, $i) + $r + $text.Substring($i + $find.Length)
}

# ============================================================ 1) 默认配置
Log "== 1/6  bridge.js: socialV2.image 默认配置" 'Cyan'
# ⚠️ 必须是 cfg.socialV2.image（voice 的**兄弟**），不能塞进 cfg.socialV2.voice 里。
#    塞进 voice 时 imageCfg() 读不到（cfg.socialV2.image === undefined），
#    表现是"配置写着 enabled:true、运行时却是 null"，端点直接 403。
#    所以这里插成一条独立语句，锚在 sticker 默认值那行之前。
$bridge = Insert-Before $bridge "  // socialV2.sticker.collect 也需要深度合并" @'
  // ---- 发图（apply-image-patch.ps1 v2）----
  // 三种来源：
  //   ① bvid     → B站 视频封面
  //   ② article  → B站 专栏正文里的图（cv 号或 read 链接；需要登录 cookie）
  //   ③ url      → 任意公网 https 图片（SSRF 防护：禁私网/回环/非 443 端口）
  // 白名单域名（B站图床）始终允许；其余走 allowPublicHttps。
  cfg.socialV2.image = {
    enabled: true,
    maxBytes: 5 * 1024 * 1024,
    maxPerMinute: 3,
    timeoutMs: 20000,
    allowDomains: ['i0.hdslb.com', 'i1.hdslb.com', 'i2.hdslb.com', 'api.bilibili.com', 'hdslb.com'],
    allowPublicHttps: true,
    credentialPath: 'C:/Users/Administrator/.dsh/bili-duty/bili_credential.json',
    ...(cfg.socialV2?.image ?? {})
  };

'@ 'image 默认配置'

# ============================================================ 2) 辅助函数
Log "== 2/6  bridge.js: 取图 / 发图函数" 'Cyan'
$bridge = Insert-Before $bridge "  function voiceLibrary() {" @'
  /**
   * 发图支持（apply-image-patch.ps1 v2）。三种来源：
   *   ① bvid    → 调 B站 公开 view 接口取封面（插件没暴露 video_info，不依赖它）
   *   ② article → 带登录 cookie 调 x/article/view 取专栏正文里的图（cv 号或 read 链接）
   *   ③ url     → 任意公网 https 图片；白名单域名无条件放行，其余走 SSRF 校验
   * SSRF 校验（关键）：解析主机名到 IP，拒绝私网/回环/链路本地/ULA，
   * 只允许 https + 443 端口。不做这一步就把"发图"变成了内网探测通道。
   */
  function imageCfg() {
    const v = cfg.socialV2?.image ?? {};
    return {
      enabled: false,
      maxBytes: 5 * 1024 * 1024,
      maxPerMinute: 3,
      timeoutMs: 20000,
      allowDomains: ['i0.hdslb.com', 'i1.hdslb.com', 'i2.hdslb.com', 'api.bilibili.com', 'hdslb.com'],
      allowPublicHttps: true,
      credentialPath: 'C:/Users/Administrator/.dsh/bili-duty/bili_credential.json',
      ...v
    };
  }

  function hostInAllowList(host, ic) {
    const h = String(host || '').toLowerCase();
    return (ic.allowDomains || []).some((d) => {
      const dd = String(d).replace(/^\./, '').toLowerCase();
      return h === dd || h.endsWith('.' + dd);
    });
  }

  function isPrivateIp(ip) {
    if (!ip) return true;
    const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip);
    if (v4) {
      const a = Number(v4[1]), b = Number(v4[2]);
      if (a === 0 || a === 10 || a === 127) return true;
      if (a === 169 && b === 254) return true;
      if (a === 172 && b >= 16 && b <= 31) return true;
      if (a === 192 && b === 168) return true;
      if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
      if (a >= 224) return true; // 组播/保留
      return false;
    }
    const l = ip.toLowerCase();
    if (l === '::1' || l === '::' ) return true;
    if (l.startsWith('fc') || l.startsWith('fd')) return true;   // ULA
    if (l.startsWith('fe80')) return true;                        // link-local
    if (l.startsWith('::ffff:')) return isPrivateIp(l.slice(7)); // v4-mapped
    return false;
  }

  async function hostIsPrivate(hostname) {
    if (isPrivateIp(hostname)) return true;
    try {
      const { lookup } = await import('node:dns/promises');
      const addrs = await lookup(hostname, { all: true, verbatim: true });
      if (!addrs.length) return true;
      return addrs.some((a) => isPrivateIp(a.address));
    } catch {
      return true; // 解析失败 = 不放行
    }
  }

  async function imageUrlAllowed(raw, ic) {
    let u;
    try { u = new URL(String(raw)); } catch { return false; }
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return false;
    const host = u.hostname.toLowerCase();
    if (hostInAllowList(host, ic)) return true;              // B站 图床：白名单直接放行
    if (!ic.allowPublicHttps) return false;
    if (u.protocol !== 'https:') return false;               // 公网图只收 https
    if (u.port && u.port !== '443') return false;            // 只允许标准端口
    if (await hostIsPrivate(host)) return false;             // 私网/回环一律拒绝
    return true;
  }

  function stripImgSuffix(url) {
    // B站 的缩略变体后缀：xxx.jpg@90p.webp / @480w_270h.jpg —— 去掉拿原图
    return String(url).split('@')[0];
  }

  async function resolveCoverUrl(bvid) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 15000);
    try {
      const res = await fetch(`https://api.bilibili.com/x/web-interface/view?bvid=${encodeURIComponent(bvid)}`, {
        signal: ctl.signal, headers: { 'user-agent': 'Mozilla/5.0' }
      });
      const j = await res.json().catch(() => null);
      const pic = j?.data?.pic;
      if (!pic) throw new Error(`取不到 ${bvid} 的封面（接口返回异常）`);
      return stripImgSuffix(String(pic));
    } finally { clearTimeout(timer); }
  }

  /** 从 "cv123" / "123" / 专栏链接里取出纯数字 cv id */
  function parseCvId(input) {
    const s = String(input ?? '').trim();
    const m = /(?:cv|read\/)(\d+)/i.exec(s) || /^(\d+)$/.exec(s);
    if (!m) throw new Error('专栏 id 解析失败（给 cv 号或 https://www.bilibili.com/read/cv123）');
    return m[1];
  }

  async function resolveArticleImages(input) {
    const ic = imageCfg();
    const id = parseCvId(input);
    let cookie = '';
    try {
      const fsMod = await import('node:fs');
      const cred = JSON.parse(fsMod.readFileSync(ic.credentialPath, 'utf8'));
      const sess = cred.sessdata || cred.SESSDATA || '';
      const jct = cred.bili_jct || cred.biliJct || '';
      const uid = cred.dedeuserid || cred.DedeUserID || '';
      const buvid = cred.buvid3 || cred.buvid3_ || '';
      cookie = [sess && `SESSDATA=${sess}`, jct && `bili_jct=${jct}`, uid && `DedeUserID=${uid}`, buvid && `buvid3=${buvid}`]
        .filter(Boolean).join('; ');
    } catch (error) {
      throw new Error(`读不到 B站 凭证（${ic.credentialPath}）：${error?.message ?? error}`);
    }
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), ic.timeoutMs);
    try {
      const res = await fetch(`https://api.bilibili.com/x/article/view?id=${encodeURIComponent(id)}`, {
        signal: ctl.signal,
        headers: {
          'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          referer: `https://www.bilibili.com/read/cv${id}`,
          cookie
        }
      });
      const j = await res.json().catch(() => null);
      if (!j || j.code !== 0 || !j.data) throw new Error(`专栏接口返回异常（code=${j?.code ?? '?'}）`);
      const html = String(j.data.content || '');
      const found = [...html.matchAll(/https?:\/\/(?:i\d\.)?hdslb\.com\/[^\s"'\\<>)]+/g)].map((m) => stripImgSuffix(m[0]));
      const uniq = [...new Set(found)].filter((u) => /\/bfs\/(article|album|archive)\//.test(u));
      if (!uniq.length) throw new Error(`专栏 cv${id} 里没找到图片`);
      return { title: String(j.data.title || `cv${id}`), images: uniq, id };
    } finally { clearTimeout(timer); }
  }

  async function fetchImageBytes(rawUrl) {
    const ic = imageCfg();
    if (!(await imageUrlAllowed(rawUrl, ic))) throw new Error(`图片地址不在允许范围内：${rawUrl}`);
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), ic.timeoutMs);
    try {
      const res = await fetch(rawUrl, { signal: ctl.signal, headers: { 'user-agent': 'Mozilla/5.0', referer: 'https://www.bilibili.com/' } });
      if (!res.ok) throw new Error(`下载图片失败：HTTP ${res.status}`);
      const type = String(res.headers.get('content-type') || '');
      if (!type.startsWith('image/')) throw new Error(`不是图片（content-type: ${type || '空'}）`);
      const buf = Buffer.from(await res.arrayBuffer());
      if (buf.length > ic.maxBytes) throw new Error(`图片太大：${(buf.length / 1048576).toFixed(1)} MB > ${(ic.maxBytes / 1048576).toFixed(0)} MB`);
      return { buffer: buf, mime: type.split(';')[0] };
    } finally { clearTimeout(timer); }
  }

  const imageSendTimes = new Map();
  async function sendImageForV2(key, { bvid = null, url = null, article = null, index = 0, label = '' } = {}) {
    const ic = imageCfg();
    if (!ic.enabled) throw new Error('发图未启用（socialV2.image.enabled=false）');
    const now = Date.now();
    const bucket = (imageSendTimes.get(key) ?? []).filter((t) => now - t < 60000);
    if (ic.maxPerMinute > 0 && bucket.length >= ic.maxPerMinute) throw new Error(`发图太频繁（上限 ${ic.maxPerMinute}/分）`);
    let target = null;
    let extra = {};
    if (article) {
      const a = await resolveArticleImages(article);
      const i = Math.max(0, Math.min(Number(index) || 0, a.images.length - 1));
      target = a.images[i];
      extra = { article: a.id, articleTitle: a.title, articleImages: a.images.length, index: i };
    } else if (url) {
      target = stripImgSuffix(String(url));
    } else if (bvid) {
      target = await resolveCoverUrl(String(bvid));
    }
    if (!target) throw new Error('需要 bvid、article 或 url 之一');
    const img = await fetchImageBytes(target);
    const m = /^(group|private):(\d+)$/.exec(String(key));
    if (!m) throw new Error('key 格式错误');
    const seg = [{ type: 'image', data: { file: 'base64://' + img.buffer.toString('base64') } }];
    const sent = m[1] === 'group'
      ? await bot.sendGroupMessage(Number(m[2]), seg)
      : await bot.sendPrivateMessage(Number(m[2]), seg);
    bucket.push(now);
    imageSendTimes.set(key, bucket);
    log(`[image] ${key} 已发送图片 ${target} (${(img.buffer.length / 1024).toFixed(0)} KB)`);
    appendActivity(`${key} [image] 发送图片 ${target}`);
    return { url: target, bytes: img.buffer.length, messageId: sent?.message_id ?? sent?.messageId ?? null, ...extra };
  }

'@ '取图/发图函数'

# ============================================================ 3) 端点
Log "== 3/6  bridge.js: POST /api/socialV2/send-image" 'Cyan'
# ⚠️ 锚点必须带上 "} catch (error) {"，否则会匹配到**内层块**里那条同文的 404
#    （第一次就插进了 tokens 子块，端点于是不可达、调用返回 404）。
#    带上 catch 行能唯一定位到请求处理器**最末尾**的兜底，这里才是顶层。
$endpointAnchor = @'
        sendJson({ ok: false, error: 'not found' }, 404);
      } catch (error) {
'@
$n = ([regex]::Matches($bridge, [regex]::Escape((Eol $endpointAnchor).TrimEnd("`r","`n")))).Count
if ($n -ne 1) { throw "端点锚点应唯一，实际匹配 $n 处" }
$bridge = Insert-Before $bridge (Eol $endpointAnchor) @'
        // 发图（apply-image-patch.ps1）：与 send-voice 同一套闸门，只是发 image segment。
        if (req.method === 'POST' && url.pathname === '/api/socialV2/send-image') {
          const body = await readBody();
          const key = String(body.key ?? '').trim();
          if (!key) { sendJson({ ok: false, error: 'key 不能为空' }, 400); return; }
          const ic = imageCfg();
          if (!ic.enabled) { sendJson({ ok: false, error: '发图已关闭（socialV2.image.enabled=false）' }, 403); return; }
          if (currentMode !== 'reserved2') { sendJson({ ok: false, error: '该接口仅 reserved2 模式可用' }, 403); return; }
          if (!req.headers['x-agent-token']) { sendJson({ ok: false, error: 'reserved2 发送必须携带 agent token' }, 403); return; }
          if (!agentTokenOk(key, req.headers['x-agent-token'])) { sendJson({ ok: false, error: 'agent token 无效' }, 403); return; }
          if (!v2SessionAllowed(key)) { sendJson({ ok: false, error: '目标不在当前模式允许范围内' }, 403); return; }
          if (!v2ToolEnabled('sendImage')) { sendJson({ ok: false, error: '工具未启用：qq_send_image' }, 403); return; }
          try {
            const r = await sendImageForV2(key, {
              bvid: body.bvid ?? null,
              url: body.url ?? null,
              article: body.article ?? null,
              index: body.index ?? 0,
              label: body.label ?? ''
            });
            sendJson({ ok: true, ...r });
          } catch (err) {
            const msg = String(err?.message ?? err);
            sendJson({ ok: false, error: msg }, /白名单|需要 bvid|格式错误|太大|不是图片/.test(msg) ? 400 : 502);
          }
          return;
        }

'@ 'send-image 端点'

# ============================================================ 4) 开关
Log "== 4/6  bridge.js: 工具开关 + 清单" 'Cyan'
$bridge = Replace-Once $bridge `
  ("    sendVoice: false," + $nl + "    speak: false,") `
  ("    sendVoice: false," + $nl + "    speak: false," + $nl + "    sendImage: true,") `
  "tools 默认表加 sendImage"
$bridge = Replace-Once $bridge `
  ("            speak: 'qq_speak'") `
  ("            speak: 'qq_speak'," + $nl + "            sendImage: 'qq_send_image'") `
  "工具清单加 sendImage"
$bridge = Replace-Once $bridge `
  "'speak', 'sendVoice']" `
  "'speak', 'sendImage', 'sendVoice']" `
  "控制台 toolFlags 加 sendImage"

# ============================================================ 5) MCP 工具
Log "== 5/6  mcp-snowluma-safe.js: 注册 qq_send_image" 'Cyan'
$mcp = Replace-Once $mcp "  qq_speak: 'speak'," ("  qq_speak: 'speak'," + $nl + "  qq_send_image: 'sendImage',") "TOOL_CONFIG_FLAGS 加 qq_send_image"
$mcp = Insert-Before $mcp "  // ---- qq_speak: Ronova live TTS" @'
  // ---- qq_send_image: 把一张图发到群/私聊（apply-image-patch.ps1 v2）----
  server.tool(
    'qq_send_image',
    '把一张图片发到群聊／私聊。三种用法（三选一）：① 传 bvid → 取该 B站 视频的封面；② 传 article → 取该 B站 专栏正文里的图（给 cv 号或 read 链接，可配 index 选第几张）；③ 传 url → 任意公网 https 图片直链（内网地址会被拒）。文字仍应单独用 qq_send_message 发。一次只发一张，别刷屏；同一话题最多一张。',
    {
      key: z.string().describe('conversation key, group:<id> or private:<id>'),
      token: z.string().describe('conversation token (see the wake-up prompt)'),
      bvid: z.string().optional().describe('B站 BV号，自动取视频封面，例如 BV1UsNJzvE6E'),
      article: z.string().optional().describe('B站 专栏：cv 号或 read 链接，例如 cv12345'),
      index: z.number().optional().describe('专栏里取第几张图，从 0 开始（默认 0）'),
      url: z.string().optional().describe('任意公网 https 图片直链（B站图床无限定；其他站点须 https、非内网）'),
      label: z.string().optional().describe('note for the session log')
    },
    async ({ key, token, bvid, article, index, url, label }) => {
      try {
        if (!bvid && !article && !url) return { content: [{ type: 'text', text: 'qq_send_image 需要 bvid、article 或 url 之一' }], isError: true };
        const data = await agentApi('/api/socialV2/send-image', {
          method: 'POST',
          body: JSON.stringify({ key, token, bvid, article, index, url, label: label || '' }),
          headers: { 'x-agent-token': token },
          timeoutMs: 120000
        });
        return { content: [{ type: 'text', text: serializeModelData(data) }] };
      } catch (error) {
        return { content: [{ type: 'text', text: `qq_send_image failed: ${error?.message ?? error}` }], isError: true };
      }
    }
  );

'@ 'qq_send_image 工具'

Write-Text $bridgeJs $bridge
Write-Text $mcpJs $mcp

# ============================================================ 6) config.json
Log "== 6/6  config.json: 打开发图" 'Cyan'
$cfgText = Read-Text $cfgPath
if (-not $cfgText.Contains('"sendImage"')) {
  $cfgText = $cfgText.Replace('"sendVoice": true', '"sendVoice": true,' + "`n" + '      "sendImage": true')
  Log "  [ok]   tools.sendImage = true" 'Green'
} else { Log "  [skip] tools.sendImage 已存在" 'DarkGray' }
if (-not $cfgText.Contains('"image": {')) {
  # 插在 socialV2 的 voice **之前**（4 空格缩进 = socialV2 的直属成员）。
  # 之前插在 "tts" 之前是错的：那在 voice 里面，运行时 cfg.socialV2.image 为 null。
  $cfgText = $cfgText.Replace(@'
    "voice": {
'@, @'
    "image": {
        "enabled": true,
        "maxBytes": 5242880,
        "maxPerMinute": 3,
        "timeoutMs": 20000,
        "allowDomains": ["i0.hdslb.com", "i1.hdslb.com", "i2.hdslb.com", "api.bilibili.com", "hdslb.com"],
        "allowPublicHttps": true,
        "credentialPath": "C:/Users/Administrator/.dsh/bili-duty/bili_credential.json"
    },
    "voice": {
'@)
  Log "  [ok]   socialV2.image 已加入（voice 的兄弟）" 'Green'
} else { Log "  [skip] socialV2.image 已存在" 'DarkGray' }
try { $null = $cfgText | ConvertFrom-Json; Log "  [ok]   config.json JSON 合法" 'Green' }
catch { Copy-Item -LiteralPath (Join-Path $backup 'config.json') -Destination $cfgPath -Force; throw "config.json 改坏了，已回滚: $_" }
Write-Text $cfgPath $cfgText

Log ""
Log "完成。备份：$backup" 'Green'
Log "撤销：... -File apply-image-patch.ps1 -Revert" 'DarkGray'
Log ""
Log "下一步：node --check → 重启桥接 → 实测端点（必须非 404）→ 重启 DSH 让 qq_send_image 出现在工具里" 'Cyan'
