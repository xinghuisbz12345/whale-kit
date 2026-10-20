# 安装教程（Windows）

> 目标：在一台新机器上，把"小鲸鱼"这套能力装起来。
> 全程假设你**已经**有一份能正常收发 QQ 消息的 DSH + qq-bridge。

---

## 0. 先确认地基

```powershell
# 桥接在跑、且连上了 QQ 网关
curl.exe -s http://127.0.0.1:3100/api/status -H "x-console-token: <你的控制台令牌>"
```

要看到 `"connected": true`。没有这一步，后面全都白搭。

**令牌在哪**：`<qq-bridge>\state\console-token`（48 位十六进制）。
控制台地址：`http://127.0.0.1:3100/?token=<令牌>`

> 每个 API 请求都要带 `x-console-token`；
> 触发发送/改状态的还要带 `x-agent-token`（**按会话**不同，见唤醒提示里的【会话令牌】）。

---

## 1. 放文件

建议目录（后面所有脚本的 `-Workspace` / `-BridgeDir` 参数都指这里）：

```
D:\dsh\workspace\          # 脚本放这儿（= 本包的 pipeline/*）
D:\dsh\qq-bridge\          # 你已有的 qq-bridge
D:\dsh\workspace\memory\   # 记忆库（脚本会自动建）
```

如果你放在别处，**逐个改脚本顶部/参数里的绝对路径**（详见每节提示）。

---

## 2. 打桥接补丁

两个补丁都是**幂等 + 自动备份 + 可 `-Revert`**：

```powershell
cd D:\dsh\workspace

# 2.1 发图能力（qq_send_image：BV封面 / 专栏取图 / 公网https）
powershell -NoProfile -ExecutionPolicy Bypass -File .\apply-image-patch.ps1 `
  -BridgeDir "D:\dsh\qq-bridge"

# 2.2 三音色语音（qq_speak 的 engine/voice 参数 + /api/socialV2/speak 透传）
powershell -NoProfile -ExecutionPolicy Bypass -File .\apply-tts-patch.ps1 `
  -BridgeDir "D:\dsh\qq-bridge"
```

打完必须验证语法：

```powershell
node --check "D:\dsh\qq-bridge\src\bridge.js"
node --check "D:\dsh\qq-bridge\src\mcp-snowluma-safe.js"
```

**撤销**：`... -Revert`（会从 `.img-backup-*` / `.tts-backup-*` 还原）

> ⚠️ 补丁改的是 `bridge.js` / `mcp-snowluma-safe.js` / `config.json`。
> 换桥接版本后补丁可能失效——重新跑一次即可（脚本会跳过已存在的段落）。

---

## 3. 语音服务（可选）

`speak-server.py` 支持多引擎：

| 引擎 | 用途 | 依赖 |
|---|---|---|
| `ronova`（默认） | 日常说话 | 你自己的说话模型（如 CosyVoice 系） |
| `gpt-sovits` | 克隆音色（角色声线） | GPT-SoVITS 整合包 + 你自备的权重 |

**没有模型也能跑**：只用 `ronova` 时把 `--no-gsv` 传上，或直接不装 GPT-SoVITS。

```powershell
# 启动（参数按你的实际模型路径改）
python speak-server.py --root "E:\your-cosyvoice" --audio-dir "D:\dsh\qq-bridge\audio" --port 8188
```

接 GPT-SoVITS（可选）：

1. 下 Windows 整合包（NVIDIA 50 系显卡要用带 `nvidia50` 的版本）
2. 解压后把 `GPT-SoVITS-v*-nvidia50x0\runtime` 里的 `ffmpeg.exe` / `ffprobe.exe` 记下来
3. 模型权重放 `GPT_weights_v2\`、`SoVITS_weights_v2\`
4. 参考音频和**它的逐字稿**（`prompt_text` 必须和音频内容一致，否则音质崩）
5. 改 `speak-server.py` 顶部的 `GSV_ROOT` / `GSV_VOICES`

**ffmpeg / ffprobe**（语音时长校验、抽帧看画面都要）：

```powershell
# 在 start-all.ps1 里已经这么做了，改成你自己的路径即可
$env:FFMPEG  = "E:\...\runtime\ffmpeg.exe"
$env:FFPROBE = "E:\...\runtime\ffprobe.exe"
```

---

## 4. 一键启动

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-all.ps1
# 只看状态
powershell ... -File .\start-all.ps1 -StatusOnly
# 全停
powershell ... -File .\start-all.ps1 -StopAll
```

顺序很重要：**网关(3000) → TTS(8188) → 桥接(3100)**。桥接比网关早起会卡在"连接中"。

改路径：脚本顶部 `$Workspace`，以及内部的 `$BridgeDir` / TTS 路径。

---

## 5. 守护（让服务自己活过来）

```powershell
# 注册成计划任务：登录自启 + 单实例
$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\dsh\workspace\watch-bridge.ps1"'
$trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'GsvWatchdog' -Action $act -Trigger $trg -Settings $set -Force
Start-ScheduledTask -TaskName 'GsvWatchdog'
```

**它怎么判"挂了"**（这是踩出来的）：

- ✅ 看**进程**：`python speak-server.py` 还活着 = 正在加载模型 = 不重启
- ✅ `start-all.ps1` 正在跑 = 有人正在启动 = 本轮跳过
- ✅ 两次重启之间至少隔 5 分钟
- ❌ **绝对不要只按端口判**：TTS 加载要 50~60 秒，端口不通但没挂

---

## 6. 人格规则（最容易踩坑的一步）

规则块在 [`persona/qq-chat-rules.snippet.md`](persona/qq-chat-rules.snippet.md)。

**关键：reserved2（二代仿真）模式实际挂载的是 `qq-chat-v2`，不是 `qq-chat`。**

改法（二选一）：

**A. 两边都放（推荐）**

```powershell
# 1) 把 snippet 分别粘进两个源文件的 persona prefix 里
#    <qq-bridge>\dsh\agent-presets\qq-chat\agent.cordis.yml
#    <qq-bridge>\dsh\agent-presets\qq-chat-v2\agent.cordis.yml
# 2) 用脚本把 qq-chat 的规则同步到 v2（幂等）
node sync-persona-to-v2.mjs
# 3) 重新生成 DSH 读的 patch
cd <qq-bridge>
node scripts/build-agent-preset-patches.mjs
```

**B. 只改 v2**（如果你确定只用 reserved2）

验证是否真的生效（**别看日志，看会话文件**）：

```powershell
# 会话文件是多 frame 的 zstd，要逐帧解压
node -e "
const fs=require('fs'),zlib=require('zlib');
const f=process.argv[1],buf=fs.readFileSync(f);
let offs=[];for(let i=0;i+4<=buf.length;i++)if(buf[i]===0x28&&buf[i+1]===0xb5&&buf[i+2]===0x2f&&buf[i+3]===0xfd)offs.push(i);
if(!offs.length)offs=[0];let out='';
for(let k=0;k<offs.length;k++){const s=offs[k],e=k+1<offs.length?offs[k+1]:buf.length;try{out+=zlib.zstdDecompressSync(buf.subarray(s,e)).toString('utf8')}catch{}}
console.log(out.includes('安慰群友')?'OK 人格已生效':'MISSING 还是旧人格');
" "C:\Users\<你>\.dsh\sessions\<会话目录>\session.v4.jsonl.zstd"
```

> 🔴 **铁律**：改完人格 **必须重启 DSH**。
> 只调 `POST /api/socialV2/reset` 重建会话**不够** —— DSH 启动时就把 preset patch 读进内存了，
> 新会话照样拿旧人格（实测过：补丁比 DSH 晚写，会话 dump 里没有新规则）。

---

## 7. 长期记忆（抗遗忘）

```powershell
# 7.1 放进 seed 模板里的初始记忆（把占位符换成你的）
node seed-memory.template.mjs      # 改成 .mjs 后按你的信息改
node mem.mjs stats

# 7.2 检索
node mem.mjs search "关键词" --n 3
node mem.mjs chat-search "关键词" --days 7 --first   # 群聊归档，--first 取最早
```

**接进唤醒**（桥接里加两段，见 `bridge/PATCHES.md` 的「记忆召回」）：

1. 收到消息时 `archiveChatMessage(key,msg)` → 写 `memory/group-log/<kind>-<id>-<日期>.jsonl`
2. 构造唤醒提示时 `recallMemoryV2(key,st)` → 记忆 3 条 + 群聊 2 条

回填历史：

```powershell
node backfill-chat.mjs    # 把桥接状态里剩的消息抢救成按天 jsonl（幂等去重）
```

**为什么只注入 3+2 条**：上下文窗口是固定预算。库可以几百条，但**每次只该放进命中的那几条**。

---

## 8. 养鱼插件（可选，要自己刷 B站 才装）

```powershell
# 8.1 装 dsh-bili-whale（第三方，MIT）
git clone https://github.com/Alterssss/dsh-bili-whale
cd "<你的 DSH profile 目录>"      # 如 C:\Users\<你>\.dsh\profiles\desktop
# 在 package.json 的 dependencies 加 "dsh-bili-whale": "link:D:/path/to/dsh-bili-whale"
# 在 dsh.profile.bundles 里加 "dsh-bili-whale"
node "<DSH 自带>\pnpm\bin\pnpm.mjs" install --no-frozen-lockfile

# 8.2 凭据（F12 → Application → Cookies 里抄，SESSDATA 是 HttpOnly）
#   ~/.bili-ai/credentials.json  =>  {"sessdata":"...","bili_jct":"...","buvid3":"..."}
# 8.3 配置
#   ~/.dsh/bili-whale.config.json（owner.mid/name、preferences、share、notify.type=file）
# 8.4 体检
cd dsh-bili-whale\tools
node bili.mjs deps
```

装完**重启 DSH**（bundle 变更必须重启）。

**推群**：

```powershell
# 注册每 3 分钟跑一次
$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\dsh\workspace\whale-to-qq.ps1"'
$trg = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 3)
Register-ScheduledTask -TaskName 'WhaleToQQ' -Action $act -Trigger $trg -Force
```

---

## 9. 验证清单（照着打勾）

| # | 检查 | 命令/现象 |
|---|---|---|
| 1 | 桥接连上网关 | `/api/status` → `connected: true` |
| 2 | 发图能用 | 聊天里发 `BV号` 给她，她能回一张封面 |
| 3 | 语音能用 | 让她用语音说一句；`/health` 里 `engines` 有两个 |
| 4 | 音色能切 | `qq_voice_mode(mode="qingque")` → 之后语音变角色声 |
| 5 | 记忆能召回 | 日志出现 `[memory] ... 召回 记忆N 条 / 群聊M 条` |
| 6 | 群归档在写 | `memory/group-log/` 里有今天的 jsonl |
| 7 | 人格已生效 | 会话 dump 里搜得到新规则（见第 6 节） |
| 8 | 守护在跑 | `Get-ScheduledTask GsvWatchdog` → Running |
| 9 | 鲸鱼会自己醒 | `~/.dsh/whale-night.json` 里有今晚的计划时间 |

---

## 10. 已知坑（全部踩过，别再踩）

1. **PowerShell 5.1 不认 `??`**（空合并是 PS7 的）→ `ParserError: Unexpected token '}'`。
   here-string 结束符 `'@` 必须独占一行，不能写成 `'@.Replace(...)`。
   而 PS7 的 `Parser::ParseFile` 又不报，别拿它验证 5.1 脚本。
2. **`ConvertFrom-Json` 深度只有 2**：`social-v2.json` 150KB+ 嵌套深会抛异常 → 用 python 读。
3. **MCP 工具 schema 改了要重启 DSH**（加参数、加工具都算）；只改桥接逻辑只需重启桥接。
4. **桥接 API 要双令牌**：`x-console-token` 必带；发送还要 `x-agent-token`，且**按会话**不同
   （往私聊发却用群 token → `403 invalid agent token`）。
5. **`Start-Job` 会随工具调用结束被杀** → 长任务用计划任务（脱离进程树）。
6. **hf-mirror 限单连接**：单流 ~0.4 MB/s，12 并发 ~5 MB/s（用 `Download-Parallel.ps1`）。
   HEAD 会返回多个 `content-length`，取**最大值**才是文件真实大小。
7. **GPT-SoVITS 权重接口**：`GET /set_gpt_weights?weights_path=`（不是 POST，参数名也不是 `gpt_weights_path`）。
8. **`check-comment` 会误报"不存在"**：它只翻热评前 3 页。复核用
   `/x/v2/reply/reply?oid=<aid>&root=<rpid>`，看 `data.root.member.mid` 是不是自己。
9. **新会话第一次唤醒可能丢**：会话刚创建时投递的 prompt 有时不执行 → 重启桥接再唤醒。
10. **`unreadCount=0` 时她不会主动说话**：给她软提示（"如果她还在…"）她只会等。
    要她动，给**明确指令 + 对象 + 方法**（例："现在就去群里安慰 X，1~2 句"）。
11. **`qq_wait_for_messages` 会让她长期"繁忙"**：每次最长 5 分钟，期间所有唤醒排队。
    排查：`bridge.log` 里连续 `会话繁忙，暂存唤醒原因`。
12. **守护和启动脚本会打架**：只按端口判"挂了"会导致重启风暴
    （实测一天 22 次重启、PID 一直变）。必须按**进程**判定 + 冷却。

---

## 11. 回滚

```powershell
powershell ... -File .\apply-image-patch.ps1 -Revert
powershell ... -File .\apply-tts-patch.ps1   -Revert
# 人格：从 agent.cordis.yml.bak-* 还原，再重编 patch + 重启 DSH
```

---

## 附录 A：需要改的绝对路径清单

这些脚本里带着**我这台机器**的路径，换机器必须改。建议先在 PowerShell 里批量替换：

```powershell
# 在 kit 目录下执行；把两个旧前缀换成你的新路径
$old1 = 'D:\Backup\Documents\deepseek-harness\default-workspace'
$old2 = 'D:\Backup\Documents\deepseek-harness\qq-bridge'
$new1 = 'D:\dsh\workspace'
$new2 = 'D:\dsh\qq-bridge'
Get-ChildItem -Recurse -File -Include *.ps1,*.mjs,*.py |
  ForEach-Object {
    $t = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    $t = $t.Replace($old1, $new1).Replace($old2, $new2)
    [IO.File]::WriteAllText($_.FullName, $t, (New-Object Text.UTF8Encoding($true)))
  }
```

| 文件 | 要改什么 |
|---|---|
| `pipeline/start-all.ps1` | `$Workspace`、`$gsvRuntime`（ffmpeg/ffprobe 所在目录）、内部调用的脚本绝对路径 |
| `pipeline/start-tts.ps1` | `$AudioDir`、speak-server.py 路径、python 解释器路径、`COSYVOICE_DIR` |
| `pipeline/start-bridge-with-tts.ps1` | `$BridgeDir`、`$Workspace` |
| `pipeline/watch-bridge.ps1` | `$Workspace`、`console-token` 路径（用于 connected 检查） |
| `pipeline/restart-dsh-with-voice.ps1` | `$WS`、`$BRIDGE`、`$DSH_EXE`（DSH 安装路径） |
| `pipeline/apply-image-patch.ps1` | `-BridgeDir` 默认值 |
| `pipeline/apply-tts-patch.ps1` | `-BridgeDir` 默认值 + 注释里的示例路径 |
| `pipeline/whale-to-qq.ps1` | `-BridgeDir`、`-Workspace`、`$python`（用于读 token 的 Python） |
| `pipeline/backfill-chat.mjs` | `STATE`（social-v2.json 路径） |
| `pipeline/sync-persona-to-v2.mjs` | `BASE`（agent-presets 目录） |
| `pipeline/speak-server.py` | `GSV_ROOT`、`GSV_VOICES`（每个音色的权重/参考音频/台词）、`DEFAULT_ROOT`、`DEFAULT_AUDIO` |
| `pipeline/mem.mjs` | 不需要改（用脚本自身所在目录定位 `memory/`） |

> `speak-server.py` 里 `GSV_VOICES` 的 `prompt` 字段必须是**参考音频里那句话的逐字稿**，
> 对不上音质会明显变差（这是 GPT-SoVITS 的硬要求）。

## 附录 B：最小可用 vs 完整能力

想少踩坑就分阶段上，每阶段都能独立跑：

| 阶段 | 装什么 | 得到什么 |
|---|---|---|
| 1 | 桥接补丁（发图）+ 人格规则 | 她会看 B站、发图、按人格说话 |
| 2 | + 语音补丁 + speak-server（只用说话引擎） | 她会发语音 |
| 3 | + GPT-SoVITS + 音色模式 | 她能换角色声线 |
| 4 | + 记忆库 + 群归档 | 她记得住人、翻得到旧事 |
| 5 | + dsh-bili-whale + whale-to-qq | 她自己按生物钟刷 B站并发群 |
