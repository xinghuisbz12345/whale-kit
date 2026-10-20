#!/usr/bin/env node
// mem.mjs —— 小鲸鱼的记忆库（最小可用版）
//
// 设计要点（为什么不是"一个大文件全量注入"）：
//   上下文窗口是固定预算。库可以几百条，但每次只该注入**命中的 3~5 条**。
//   所以：index.jsonl 当"目录"（几十 KB，不注入），正文按需取。
//
// 存储：memory/index.jsonl，一行一条 JSON：
//   { id, date, type, who, title, text, tags[], conf, src }
//   type: person(人) | fact(事实) | decision(决定) | pitfall(坑) | promise(承诺) | event(事件)
//
// 用法：
//   node mem.mjs add --type person --who 哥哥酱 --title "哥哥酱是谁" --text "..." --tags 人,owner
//   node mem.mjs search "CS2 视频" [--n 3] [--json]
//   node mem.mjs stats
//   node mem.mjs get m-0003
//   node mem.mjs forget m-0003
//   node mem.mjs compact            # 去重（同 text 保留最新）
//   node mem.mjs list [--type person] [--n 20]
//
// 退出码：0 正常；1 参数错误；2 找不到。

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const DIR = path.join(HERE, 'memory')
const INDEX = path.join(DIR, 'index.jsonl')

function ensure() {
  fs.mkdirSync(DIR, { recursive: true })
  if (!fs.existsSync(INDEX)) fs.writeFileSync(INDEX, '', 'utf8')
}

function load() {
  ensure()
  const out = []
  for (const line of fs.readFileSync(INDEX, 'utf8').split(/\r?\n/)) {
    const s = line.trim()
    if (!s) continue
    try { out.push(JSON.parse(s)) } catch { /* 坏行跳过 */ }
  }
  return out
}

function saveAll(items) {
  ensure()
  fs.writeFileSync(INDEX, items.map((o) => JSON.stringify(o)).join('\n') + (items.length ? '\n' : ''), 'utf8')
}

function nextId(items) {
  let max = 0
  for (const it of items) {
    const m = /^m-(\d+)$/.exec(it.id || '')
    if (m) max = Math.max(max, Number(m[1]))
  }
  return 'm-' + String(max + 1).padStart(4, '0')
}

function parseArgs(argv) {
  const argv2 = argv.slice(2)
  const cmd = argv2[0]
  const positional = []
  const flags = {}
  for (let i = 1; i < argv2.length; i++) {
    const a = argv2[i]
    if (a.startsWith('--')) {
      const k = a.slice(2)
      const v = argv2[i + 1] && !argv2[i + 1].startsWith('--') ? argv2[++i] : true
      flags[k] = v
    } else positional.push(a)
  }
  return { cmd, positional, flags }
}

const norm = (s) => String(s || '').toLowerCase()

/** 简单打分：标题命中 > 标签命中 > 正文命中；多词命中加权。 */
function score(item, terms) {
  const title = norm(item.title)
  const tags = (item.tags || []).map(norm).join(' ')
  const text = norm(item.text)
  const who = norm(item.who)
  let s = 0
  for (const t of terms) {
    if (!t) continue
    if (title.includes(t)) s += 6
    if (tags.includes(t)) s += 4
    if (who.includes(t)) s += 3
    if (text.includes(t)) s += 2
  }
  // 类型加权：人和承诺比"事件"更该被想起来
  const bias = { person: 1.4, promise: 1.5, decision: 1.2, pitfall: 1.1, fact: 1.0, event: 0.9 }[item.type] ?? 1
  return s * bias
}

function cmdAdd(flags) {
  const items = load()
  const text = String(flags.text ?? '').trim()
  if (!text) { console.error('缺 --text'); process.exit(1) }
  const item = {
    id: nextId(items),
    date: String(flags.date ?? new Date().toISOString().slice(0, 10)),
    type: String(flags.type ?? 'fact'),
    who: String(flags.who ?? ''),
    title: String(flags.title ?? text.slice(0, 24)),
    text: text.slice(0, 600),
    tags: String(flags.tags ?? '').split(',').map((s) => s.trim()).filter(Boolean),
    conf: flags.conf !== undefined ? Number(flags.conf) : 1,
    src: String(flags.src ?? 'manual')
  }
  items.push(item)
  saveAll(items)
  console.log(JSON.stringify({ ok: true, added: item }))
}

function cmdSearch(positional, flags) {
  const q = positional.join(' ').trim()
  if (!q) { console.error('缺查询词'); process.exit(1) }
  const n = Number(flags.n) || 3
  const terms = norm(q).split(/[\s,，。;；:：/]+/).filter(Boolean)
  const items = load()
  const ranked = items
    .map((it) => ({ it, s: score(it, terms) }))
    .filter((x) => x.s > 0)
    .sort((a, b) => b.s - a.s)
    .slice(0, n)
  if (flags.json) { console.log(JSON.stringify(ranked.map((x) => ({ ...x.it, _score: x.s })), null, 2)); return }
  if (!ranked.length) { console.log('（没有相关记忆）'); return }
  for (const { it, s } of ranked) {
    console.log(`[${it.id}] (${it.type}${it.who ? '/' + it.who : ''}) ${it.title}  · ${it.date} · score=${s.toFixed(1)}`)
    console.log(`    ${it.text}`)
  }
}

function cmdStats() {
  const items = load()
  const byType = {}
  for (const it of items) byType[it.type] = (byType[it.type] || 0) + 1
  console.log(JSON.stringify({ total: items.length, byType, file: INDEX, bytes: fs.statSync(INDEX).size }, null, 2))
}

function cmdGet(positional) {
  const id = positional[0]
  const it = load().find((x) => x.id === id)
  if (!it) { console.error('没有 ' + id); process.exit(2) }
  console.log(JSON.stringify(it, null, 2))
}

function cmdForget(positional) {
  const id = positional[0]
  const items = load()
  const rest = items.filter((x) => x.id !== id)
  if (rest.length === items.length) { console.error('没有 ' + id); process.exit(2) }
  saveAll(rest)
  console.log(JSON.stringify({ ok: true, removed: id }))
}

function cmdCompact() {
  const items = load()
  const seen = new Map()
  for (const it of items) {
    const key = norm(it.text).replace(/\s+/g, '')
    const prev = seen.get(key)
    if (!prev || String(it.date) >= String(prev.date)) seen.set(key, it)
  }
  const out = [...seen.values()]
  saveAll(out)
  console.log(JSON.stringify({ ok: true, before: items.length, after: out.length }))
}

function cmdList(flags) {
  const n = Number(flags.n) || 20
  let items = load()
  if (flags.type) items = items.filter((x) => x.type === flags.type)
  items.slice(-n).forEach((it) => console.log(`[${it.id}] ${it.type} ${it.title} · ${it.date}`))
}

// ---------- 群聊归档检索 ----------
// 桥接把每条收到的消息 append 到 memory/group-log/<kind>-<id>-<day>.jsonl。
// 这条命令让"谁第一个跟我说话""昨天谁提过青雀"这类问题**真的查得到**。
const CHAT_DIR = path.join(DIR, 'group-log')

function loadChat(days, kindFilter) {
  if (!fs.existsSync(CHAT_DIR)) return []
  const cutoff = Date.now() - days * 86400000
  const out = []
  for (const f of fs.readdirSync(CHAT_DIR)) {
    if (!f.endsWith('.jsonl')) continue
    if (kindFilter && !f.startsWith(kindFilter)) continue
    let raw = ''
    try { raw = fs.readFileSync(path.join(CHAT_DIR, f), 'utf8') } catch { continue }
    for (const line of raw.split(/\r?\n/)) {
      const s = line.trim()
      if (!s) continue
      try {
        const o = JSON.parse(s)
        const t = Date.parse(o.t)
        if (!Number.isFinite(t) || t < cutoff) continue
        out.push({ ...o, _t: t })
      } catch { /* 坏行跳过 */ }
    }
  }
  return out
}

function fmtChat(o) {
  const d = new Date(o._t)
  const p = (n) => String(n).padStart(2, '0')
  const ts = `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
  return `[${ts}] ${o.sender}${o.isOwner ? '（管理员）' : ''}: ${o.text}`
}

function cmdChatSearch(positional, flags) {
  const q = positional.join(' ').trim()
  const n = Number(flags.n) || 10
  const days = Number(flags.days) || 30
  const terms = norm(q).split(/[\s,，。;；:：/]+/).filter(Boolean)
  const who = flags.who ? norm(flags.who) : ''
  let rows = loadChat(days, flags.kind)
  if (who) rows = rows.filter((r) => norm(r.sender).includes(who))
  if (terms.length) {
    rows = rows.filter((r) => {
      const t = norm(r.text)
      const s = norm(r.sender)
      return terms.some((x) => t.includes(x) || s.includes(x))
    })
  }
  rows.sort((a, b) => (flags.first ? a._t - b._t : b._t - a._t))
  const out = rows.slice(0, n)
  if (flags.json) { console.log(JSON.stringify(out.map(({ _t, ...r }) => ({ ...r, at: new Date(_t).toISOString() })), null, 2)); return }
  if (!out.length) { console.log(`（近 ${days} 天的群聊归档里没有匹配）`); return }
  for (const o of out) console.log(fmtChat(o))
}

const { cmd, positional, flags } = parseArgs(process.argv)
switch (cmd) {
  case 'add': cmdAdd(flags); break
  case 'search': cmdSearch(positional, flags); break
  case 'stats': cmdStats(); break
  case 'get': cmdGet(positional); break
  case 'forget': cmdForget(positional); break
  case 'compact': cmdCompact(); break
  case 'list': cmdList(flags); break
  case 'chat-search': cmdChatSearch(positional, flags); break
  default:
    console.log('用法: node mem.mjs <add|search|stats|get|forget|compact|list|chat-search> [参数]')
    process.exit(cmd ? 1 : 0)
}
