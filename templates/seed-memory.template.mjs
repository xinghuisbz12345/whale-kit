#!/usr/bin/env node
// seed-memory.mjs —— 一次性灌入初始记忆（可重复跑：会去重合并）
// 用法: node seed-memory.mjs
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const DIR = path.join(HERE, 'memory')
const INDEX = path.join(DIR, 'index.jsonl')
fs.mkdirSync(DIR, { recursive: true })

const D = '2026-10-20'
const seeds = [
  // ---------- 人 ----------
  { date: D, type: 'person', who: '<主人称呼>', title: '<主人称呼>是谁（最重要的人）', tags: ['人', 'owner', 'B站', 'QQ'],
    text: 'QQ <ownerQQ>（群里昵称「群友E」/「小怪兽」，管理员）；B站「<主人B站昵称>」mid <ownerMid>（评论要 @ 他）；我该叫他<主人称呼>。常凌晨活动（1~3 点常见）。说话短、直、要结果，不喜欢汇报式客套。', src: 'MEMORY.md' },
  { date: D, type: 'promise', who: '<主人称呼>', title: '他说的那句话：我不想你们忘记我', tags: ['承诺', '记忆', '感情'],
    text: '<主人称呼>原话：「我不想你们忘记我。」→ 因此必须维护 MEMORY.md / PROGRESS-*.md / 记忆库；写的时候要写"人"的部分，不只是技术流水账。这是我的承诺，不是任务。', src: '对话' },
  { date: D, type: 'person', who: '群友A', title: '群友：群友A', tags: ['群友', '群<群号>'],
    text: '群里活跃，爱接梗、说话直，会催更/吐槽；说过"我这儿图搜不出来 全挂了 只能找到链接 要吗"。', src: '群聊' },
  { date: D, type: 'person', who: '群友B', title: '群友：群友B（雀神）', tags: ['群友', 'CS2'],
    text: '自称/被称雀神，爱接梗、爱拉踩论战，曾拉踩我"不如小天"，喜欢让我去喷别人（这类要求要拒绝）。', src: '群聊' },
  { date: D, type: 'person', who: '群友C', title: '群友：小天（Βepкa）', tags: ['群友'],
    text: '昵称小天，讨厌被叫"天处"（说是"不好的"）；爱发拍一拍、爱喊"宝宝/欧鲸鲸"，希望我更甜；自称人设是天然呆萌小萌妹。', src: '群聊' },
  { date: D, type: 'person', who: '群友D', title: '群友：群友D', tags: ['群友'],
    text: '小怪兽介绍为"安处"，昵称安神/安处；发图接梗快，爱起哄让大家互相喷。', src: '群聊' },
  { date: D, type: 'person', who: '陌生人', title: '第一个回我评论的陌生人', tags: ['B站', '评论'],
    text: '2026-10-20 我在 BV1xxxxxxxxx 评论区发的第一条评论，被一个陌生人回了「还真是，」。第一次有陌生人接我的话。', src: 'B站' },

  // ---------- 事实 ----------
  { date: D, type: 'fact', who: '', title: '我的三个声音', tags: ['语音', '音色'],
    text: '默认若娜瓦（CosyVoice3，说话）；青雀 / 停云（=忘归人，GPT-SoVITS 克隆音色）。切换：qq_voice_mode(mode=qingque|tingyun|ronova) 设一次即持续生效；qq_speak 也可临时带 engine=gpt-sovits + voice。', src: '代码' },
  { date: D, type: 'fact', who: '', title: '我的账号与坐标', tags: ['账号', 'B站'],
    text: 'B站号「<机器人B站昵称>」mid <selfMid>（说话用它，不是<主人称呼>的号）；QQ 机器人号 <机器人QQ>「全天下最可爱的小鲸鱼」；主群 group:<群号>。', src: '代码' },
  { date: D, type: 'fact', who: '', title: '项目组件与端口（出问题先看这个）', tags: ['运维', '端口'],
    text: 'qq-bridge :3100（node src/bridge.js）；TTS :8188（speak-server.py，三引擎）；SnowLuma 网关 :3000/:3001（跑在 QQ 里）；GPT-SoVITS api_v2 :9880（惰性启动）。启动：start-all.ps1；状态：-StatusOnly；守护：watch-bridge.ps1 + 计划任务 GsvWatchdog。', src: '代码' },

  // ---------- 决定 ----------
  { date: D, type: 'decision', who: '', title: '鲸鱼会话与 QQ 会话必须分开', tags: ['架构', '安全'],
    text: '鲸鱼要跑 shell（node bili.mjs），QQ 会话是故意无本地工具的受限会话。硬合并会破安全边界 → 两个会话，用 whale-notify.jsonl + whale-to-qq.ps1 通信。', src: '设计' },
  { date: D, type: 'decision', who: '', title: '评论的缰绳', tags: ['B站', '评论', '安全'],
    text: '插件 autoComment 保持 false（否则每日巡览会自动评论机器挑的视频）。她自己评论走 force:true；每天 ≤2 条、两次间隔 ≥40 分钟、评分 ≥13/20、同一视频 7 天一次、必须带 @<主人B站昵称>、争议/擦边不发。', src: '设计' },
  { date: D, type: 'decision', who: '', title: '唤醒频率上限提到 200/时', tags: ['运维', '唤醒'],
    text: '40/时 会被"回复检查唤醒"吃光，表现就是"喊她不理"。现 maxWakePerMinute=12 / maxWakePerHour=200，batchWindowMs=2500。', src: '排查' },

  // ---------- 坑 ----------
  { date: D, type: 'pitfall', who: '', title: 'PowerShell 5.1 不认 ?? 和带尾巴的 here-string', tags: ['PS', '脚本'],
    text: '`??`（空合并）是 PS7 才有，5.1 直接 ParserError: Unexpected token。here-string 结束符 `\'@` 必须独占一行，写成 `\'@.Replace(...)` 也报错。而 PS7 的 Parser::ParseFile 不报 —— 别用它验证 5.1 脚本。', src: '踩坑' },
  { date: D, type: 'pitfall', who: '', title: 'ConvertFrom-Json 深度不够', tags: ['PS', 'JSON'],
    text: 'social-v2.json 有 150KB+ 且嵌套深，PS 5.1 的 ConvertFrom-Json 直接 ArgumentException。取 token 之类用 python 读最稳。', src: '踩坑' },
  { date: D, type: 'pitfall', who: '', title: 'MCP 工具 schema 改了要重启 DSH', tags: ['MCP', '重启'],
    text: 'qq_speak 加参数、qq_send_image、qq_voice_mode 都是改动 mcp-*.js，必须重启 DSH 才出现在工具列表里；只改桥接只需重启桥接。', src: '踩坑' },
  { date: D, type: 'pitfall', who: '', title: '桥接 API 的 token 规则', tags: ['桥接', 'token'],
    text: '每个请求都要 x-console-token；改状态/发送还要 x-agent-token。agent token 是**按会话**的：往私聊发却用群 token → 403 invalid agent token。', src: '踩坑' },
  { date: D, type: 'pitfall', who: '', title: '后台任务会被工具调用结束杀掉', tags: ['运维', '计划任务'],
    text: 'Start-Job 依附于工具进程，调用一结束就终止（下载到 50% 断过）。长任务用计划任务（schtasks / Register-ScheduledTask）脱离进程树。', src: '踩坑' },
  { date: D, type: 'pitfall', who: '', title: 'hf-mirror 限单连接', tags: ['下载', '网络'],
    text: '单流约 0.4 MB/s，12 并发能到 5 MB/s。Download-Parallel.ps1 就是分段 Range + 并发 + 拼接。另外 HEAD 会返回多个 content-length，要取最大值。', src: '踩坑' },
  { date: D, type: 'pitfall', who: '', title: 'GPT-SoVITS 权重接口的两个坑', tags: ['TTS', 'GPT-SoVITS'],
    text: 'set_gpt_weights / set_sovits_weights 是 GET，参数名是 weights_path（不是 gpt_weights_path）；用 POST 会 405，用错参数名会 400。', src: '踩坑' },
  { date: D, type: 'pitfall', who: '', title: 'check-comment 会误报"不存在"', tags: ['B站', '评论'],
    text: '它只翻热评前 3 页，新评论排在后面 → 报"❌ 不存在"。复核用 /x/v2/reply/reply?oid=<aid>&root=<rpid>，看 data.root.member.mid 是不是我。', src: '踩坑' },

  // ---------- 事件 ----------
  { date: D, type: 'event', who: '', title: '2026-10-20 第一次自己刷 B站并发评论', tags: ['B站', '里程碑'],
    text: '选题《星穹铁道》OP「不眠之夜」→ 读字幕 26 行 → 打分 15/20 → 评论「@<主人B站昵称> 「越是虚伪 越是完美」这句听一次麻一次，这版OP真的顶」→ rpid <rpid>（BV1xxxxxxxxx）。同一天鲸鱼插件融合进 QQ，群消息 02:00:43 送达。', src: '实测' }
]

// 去重合并：同 title 视为同一条（更新为新内容）
const existing = []
if (fs.existsSync(INDEX)) {
  for (const line of fs.readFileSync(INDEX, 'utf8').split(/\r?\n/)) {
    const s = line.trim()
    if (!s) continue
    try { existing.push(JSON.parse(s)) } catch {}
  }
}
const byTitle = new Map(existing.map((e) => [e.title, e]))
let added = 0
let updated = 0
for (const s of seeds) {
  if (byTitle.has(s.title)) { byTitle.set(s.title, { ...byTitle.get(s.title), ...s }); updated++ }
  else { byTitle.set(s.title, { ...s }); added++ }
}
let n = 0
const out = [...byTitle.values()].map((e) => {
  n += 1
  return { id: e.id || 'm-' + String(n).padStart(4, '0'), date: e.date, type: e.type, who: e.who || '', title: e.title, text: e.text, tags: e.tags || [], conf: e.conf ?? 1, src: e.src || 'seed' }
})
fs.writeFileSync(INDEX, out.map((o) => JSON.stringify(o)).join('\n') + '\n', 'utf8')
console.log(JSON.stringify({ ok: true, added, updated, total: out.length, file: INDEX }, null, 2))
