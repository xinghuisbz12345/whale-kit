# 桥接补丁说明（PATCHES.md）

> 两个补丁脚本都是**幂等 + 自动备份 + 可 `-Revert`**。
> 但"能跑"不等于"位置对" —— 下面记录了每个补丁落在哪，以及踩过的锚点坑。

---

## 一、发图补丁 `apply-image-patch.ps1`

### 改了什么

| 目标 | 改动 |
|---|---|
| `src/bridge.js` | ① 新增 `cfg.socialV2.image` 默认配置<br>② 新增 `imageCfg` / `isPrivateIp` / `hostIsPrivate` / `imageUrlAllowed` / `stripImgSuffix` / `resolveCoverUrl` / `parseCvId` / `resolveArticleImages` / `fetchImageBytes` / `sendImageForV2`<br>③ 新增端点 `POST /api/socialV2/send-image`<br>④ 工具开关 `sendImage` + 工具清单 + 控制台 toolFlags |
| `src/mcp-snowluma-safe.js` | 注册 `qq_send_image` 工具 + `TOOL_CONFIG_FLAGS` 映射 |
| `config.json` | `socialV2.tools.sendImage=true`、`socialV2.image={...}` |

### 三种图片来源

| 参数 | 行为 |
|---|---|
| `bvid` | 调 B站 公开 `x/web-interface/view` 取封面（不依赖插件） |
| `article` + `index` | 带登录 cookie 调 `x/article/view`，从正文 HTML 抽图（去 `@90p.webp` 之类的缩略后缀） |
| `url` | 任意公网 https 图片（**SSRF 防护**见下） |

### SSRF 防护（别省）

- 白名单域名（B站 图床）无条件放行
- 其余要求：`https` + 端口 443 + **DNS 解析后所有 IP 都不是私网**
- 拒绝：`10/8`、`172.16-31`、`192.168`、`127`、`169.254`、`100.64/10`（CGNAT）、`224+`、`::1`、`fc00::/7`、`fe80::/10`
- 解析失败 = 不放行
- 上限 5 MB、只收 `image/*`、3 张/分钟

### 🔴 锚点坑（我踩了两次）

1. **配置层级**：`image` 必须是 `cfg.socialV2.image`（`voice` 的**兄弟**）。
   塞进 `voice` 里时 `imageCfg()` 读不到 → 运行时 `null` → 端点直接 403，
   而配置文件看起来"明明写着 enabled:true"。
2. **端点锚点**：插入点必须带 `} catch (error) {` 一起做锚：
   ```
   sendJson({ ok: false, error: 'not found' }, 404);
 } catch (error) {
   ```
   只锚那一行 404 会匹配到**内层块**里同文的兜底 → 端点"插进去了但不可达" → 调用返回 404。

### 验证

```powershell
# 必须带双令牌
curl.exe -s -X POST http://127.0.0.1:3100/api/socialV2/send-image `
  -H "x-console-token: <CT>" -H "x-agent-token: <该会话的AT>" `
  -H "content-type: application/json" `
  -d '{"key":"group:<群号>","bvid":"BV1xx411c7mD"}'
```

期望 `{"ok":true,"url":"...","messageId":...}`。返回 404 = 端点没插到顶层。

---

## 二、语音补丁 `apply-tts-patch.ps1`

### 改了什么

| 目标 | 改动 |
|---|---|
| `src/bridge.js` | ① `voice.tts` 默认配置<br>② `ttsCfg()` / `synthesizeSpeech()`（**必须是 `voiceCfg` 的兄弟函数**）<br>③ 端点 `POST /api/socialV2/speak`<br>④ 工具开关 `speak` |
| `src/mcp-snowluma-safe.js` | `qq_speak` 工具（`engine` / `voice` 可选参数） |
| `config.json` | `socialV2.tools.speak=true`、`socialV2.voice.tts={enabled,url,...}` |

### 多引擎（在 speak-server.py 那侧）

```
POST /tts  { text, lang?, speed?, engine?, voice? }
  engine 缺省 = ronova（说话模型）
  engine="gpt-sovits" + voice="qingque"|"tingyun" → 克隆音色
```

**GPT-SoVITS 惰性启动**：第一次被调用才拉起 `api_v2.py`（省显存），之后复用。

### 🔴 锚点坑

1. **420/405**：`/set_gpt_weights`、`/set_sovits_weights` 是 **GET**，参数名 **`weights_path`**。
   POST → 405；参数写成 `gpt_weights_path` → 400。
2. **`synthesizeSpeech is not defined`**：helpers 锚在 `function voiceCfg() {` 上会落进它**内部**，
   调的时候作用域里没有。必须锚在 `voiceCfg` 的**闭合 `}` 之后**。
3. **`live TTS is off`**：`tts:{enabled:false}` 放在用户 spread **之后**会覆盖用户配置。
   默认值要放在 `tts` 字面量**内部**并用嵌套 spread，用户 spread 放最后。

### 验证

```powershell
curl.exe -s -X POST http://127.0.0.1:8188/tts `
  -H "content-type: application/json" `
  -d '{"text":"测试","engine":"gpt-sovits","voice":"qingque"}'
```

---

## 三、记忆召回（不是补丁脚本，是两段代码）

桥接里要加两处（示例代码见 `INSTALL.md` 第 7 节）：

### 1) 落盘归档

在 reserved2 收到消息、写 `st.recentMessages` 的地方，加一句：

```js
archiveChatMessage(key, msg);   // memory/group-log/<kind>-<id>-<日期>.jsonl
```

`archiveChatMessage` 用 `fs.appendFileSync`，**整段 try/catch**（归档失败不能影响收消息）。

### 2) 唤醒时召回

`buildWakePromptV2` 里：

```js
const memoryText = formatMemoryV2(st);      // 原有：话题/想说没说/群友印象
const recallText = recallMemoryV2(key, st); // 新增：记忆 3 条 + 群聊 2 条
```

`recallMemoryV2` 的实现要点：
- 用最近 3 条**非自己**的消息拼查询词（≤80 字）
- `execFileSync(process.execPath, [mem.mjs, 'search', q, '--n','3','--json'])`
- 群聊那段单独 try，失败静默降级
- 60 秒缓存，避免同一轮重复扫
- **失败绝不抛** —— 不能因为查记忆失败就叫不醒她

### 端点（可选，让她能主动翻）

`POST /api/socialV2/memory-search` `{key, query, n?, scope?: memory|chat|both, days?, first?}`

---

## 四、回滚

```powershell
powershell ... -File .\apply-image-patch.ps1 -Revert
powershell ... -File .\apply-tts-patch.ps1   -Revert
```

`-Revert` 会找最近的 `.img-backup-*` / `.tts-backup-*` 目录还原三个文件。
还原后记得 `node --check`，再重启桥接。
