#!/usr/bin/env node
// sync-persona-to-v2.mjs —— 把「功能规则」从 qq-chat 源同步到 qq-chat-v2 源
//
// 为什么需要它（2026-10-20 踩的坑）：
//   reserved2（二代仿真）模式下桥接实际挂载的是 **qq-chat-v2** preset，
//   而我一直把 B站/发图/评论/语音/音色模式/长期记忆/安慰 这些规则写进 qq-chat。
//   结果：工具层生效，**人格规则一直没生效**（她说不出"我会用青雀音色"这种话，
//   因为 prompt 里根本没这段）。
//   这个脚本把两边的规则对齐，避免以后再各改各的。
//
// 做法：从 qq-chat 源里截取「【B站：可以看」到「【发送与汇报禁令」之间的整段，
//   插到 v2 源的 prefix 折叠块末尾（即 `- id: tool-web` 之前）。
// 幂等：v2 里已经有标记就跳过。
import fs from 'node:fs'
import path from 'node:path'

const BASE = 'D:\\Backup\\Documents\\deepseek-harness\\qq-bridge\\dsh\\agent-presets'
const SRC = path.join(BASE, 'qq-chat', 'agent.cordis.yml')
const DST = path.join(BASE, 'qq-chat-v2', 'agent.cordis.yml')

const START = '【B站：可以看'
const END = '【发送与汇报禁令'

const srcLines = fs.readFileSync(SRC, 'utf8').split(/\r?\n/)
const s = srcLines.findIndex((l) => l.includes(START))
const e = srcLines.findIndex((l) => l.includes(END))
if (s < 0 || e < 0 || e <= s) {
  console.error(`找不到区间：start=${s} end=${e}`)
  process.exit(1)
}
// 截取并去掉尾部空行
const block = srcLines.slice(s, e)
while (block.length && !block[block.length - 1].trim()) block.pop()

let dstText = fs.readFileSync(DST, 'utf8')
const dstLines = dstText.split(/\r?\n/)

if (dstText.includes(START)) {
  console.log(JSON.stringify({ ok: true, skipped: true, reason: 'v2 里已经有这段规则了' }))
  process.exit(0)
}

// 插到「模型侧工具」注释块之前 —— 那才是 persona 折叠块真正的结束位置。
// ⚠️ 不能锚 `- id: tool-web`：它前面有三行注释（`# ── 模型侧工具` 等），
// 那属于 YAML 顶层注释，插到它后面就跑到 prefix 外面去了，YAML 直接报
// "bad indentation of a mapping entry"（踩过一次）。
let at = dstLines.findIndex((l) => /^#\s*─+\s*模型侧工具/.test(l))
if (at < 0) at = dstLines.findIndex((l) => /^\s*-\s*id:\s*tool-web/.test(l))
if (at < 0) {
  console.error('v2 里找不到插入锚点')
  process.exit(1)
}
// 往前回退到最后一个非空行之后
while (at > 0 && !dstLines[at - 1].trim()) at--

const injected = ['', ...block, '']
dstLines.splice(at, 0, ...injected)
dstText = dstLines.join('\n')
fs.writeFileSync(DST, dstText, 'utf8')
console.log(JSON.stringify({ ok: true, injectedLines: block.length, at, dst: DST }, null, 2))
