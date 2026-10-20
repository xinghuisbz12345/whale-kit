#!/usr/bin/env node
// backfill-chat.mjs —— 把桥接状态里还留着的群消息回填到 group-log 归档
//
// 为什么要回填：桥接内存只留最近 80 条，新归档只能从"从现在起"开始记。
// 状态文件里现存的那 80+ 条是最后的活口 —— 先落盘，之后靠桥接实时 append。
//
// 去重：按 (seq|time|text) 三件套判重，重复跑不会写两遍。
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const OUT = path.join(HERE, 'memory', 'group-log')
const STATE = 'D:\\Backup\\Documents\\deepseek-harness\\qq-bridge\\state\\social-v2.json'
fs.mkdirSync(OUT, { recursive: true })

const state = JSON.parse(fs.readFileSync(STATE, 'utf8'))
const convs = state.conversations || {}

const pad = (n) => String(n).padStart(2, '0')
const dayOf = (ms) => { const d = new Date(ms); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` }

// 已有条目（用于去重）
const seen = new Set()
for (const f of fs.readdirSync(OUT)) {
  if (!f.endsWith('.jsonl')) continue
  for (const line of fs.readFileSync(path.join(OUT, f), 'utf8').split(/\r?\n/)) {
    const s = line.trim(); if (!s) continue
    try { const o = JSON.parse(s); seen.add(`${o.seq}|${o.t}|${(o.text || '').slice(0, 40)}`) } catch {}
  }
}

let added = 0
const perFile = new Map()
for (const [key, conv] of Object.entries(convs)) {
  const m = /^(group|private):(\d+)$/.exec(key)
  if (!m) continue
  for (const msg of conv.recentMessages || []) {
    if (!msg || msg.isSelf) continue
    const t = Number(msg.time) || 0
    if (!t) continue
    const text = String(msg.plain || msg.text || '').replace(/\s+/g, ' ').slice(0, 300)
    if (!text) continue
    const at = new Date(t).toISOString()
    const k = `${msg.seq}|${at}|${text.slice(0, 40)}`
    if (seen.has(k)) continue
    seen.add(k)
    const file = path.join(OUT, `${m[1]}-${m[2]}-${dayOf(t)}.jsonl`)
    const line = JSON.stringify({ t: at, seq: msg.seq, sender: msg.sender || '', userId: msg.userId || '', isOwner: !!msg.isOwner, isSelf: false, text, backfilled: true }) + '\n'
    perFile.set(file, (perFile.get(file) || '') + line)
    added++
  }
}
for (const [file, content] of perFile) fs.appendFileSync(file, content, 'utf8')
console.log(JSON.stringify({ ok: true, added, files: perFile.size, dir: OUT }, null, 2))
