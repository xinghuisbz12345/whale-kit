# NOTICE —— 这个包里有什么、没有什么

## 不含（故意的）

| 内容 | 为什么 |
|---|---|
| **语音库音频**（`qq-bridge\audio\*.wav`） | 体积大、且是生成产物；你自己跑一次就有了 |
| **账号凭据**（B站 cookie、QQ 令牌） | 属于你的私人凭据，绝不打包 |
| **桥接状态**（`state\*.json`、`console-token`） | 含 agent token / 会话映射 |
| **个人记忆**（`memory\index.jsonl`、`memory\group-log\*`） | 含真实群聊与个人信息；只给模板 |
| **模型权重**（CosyVoice / GPT-SoVITS） | 几 GB，且许可见下 |

## 第三方

| 组件 | 许可 | 说明 |
|---|---|---|
| **DeepSeek Harness (DSH)** | 见官方 | 宿主 |
| **qq-bridge / SnowLuma / NapCat** | 见各自仓库 | QQ 接入层 |
| **dsh-bili-whale** | MIT | 只提供接线方式，**不包含其代码** |
| **GPT-SoVITS** | MIT | 引擎；**不随包分发** |
| **CosyVoice** | 见官方 | 说话引擎；不随包分发 |

## 音色与版权（必读）

- 角色音色（游戏/动画角色的声音）**版权属于配音演员与版权方**。
- 用别人的声音做克隆并**公开传播/商用**有法律风险；本工具包只适合**个人自用研究**。
- 社区分享的音色模型常注明「严禁商用」，请遵守。

## 安全边界（设计如此，别改）

- QQ 会话**没有任何本地工具**（不能执行命令/读写文件）——群友再怎么诱导也碰不到你的机器。
- 桥接每个 API 都要 `x-console-token`；发送/改状态还要 `x-agent-token`（按会话隔离）。
- 发图有 SSRF 防护（禁私网/回环/非 443）。
- 评论有硬闸：每日 ≤2 条、同视频 7 天一次、评分 ≥13、必须带 @、争议内容不发。

## 使用后果

用你自己的账号做操作，后果自负。撞到平台风控（验证码/限流/判刷屏）请**立刻停手**。
---

## 你需要自己准备的东西（依赖，**不在本包内**）

| 组件 | 地址 | 我用过的版本 | 说明 |
|---|---|---|---|
| **DeepSeek Harness (DSH)** | 官方安装包 | `0.2.0-rc.2`（File 0.2.0-rc.2 / Product 0.2.0.0） | 宿主，没有它一切不成立 |
| **qq-bridge** ★ | https://github.com/Derpyu520/qq-bridge | **`0.2.0-r3`** | **本包的两个补丁是给它打的**；换版本锚点可能对不上 |
| **SnowLuma**（QQ 网关） | npm `@snowluma/sdk` / `@snowluma/mcp` ^1.14.20 | 1.14.x | 桥接通过它跟 QQ 说话（OneBot v11） |
| **NapCatQQ** | https://github.com/NapNeko/NapCatQQ | `4.18.38`（app_name `NapCat.Onebot`，protocol v11） | 跑在 QQ 进程里，提供 3000/3001 |
| **dsh-bili-whale**（可选） | https://github.com/Alterssss/dsh-bili-whale | `0.2.0` | 养鱼（自己刷 B站）；不装也能用其它功能 |
| **Node.js** | https://nodejs.org | ≥ `22.13.0`（实测 22.21.1） | 桥接与脚本都靠它 |
| **Git** | https://git-scm.com | 26.x | 拉仓库 / 推 GitHub |
| **Python**（可选） | https://python.org | 3.12 | 只有跑 TTS（`speak-server.py`）才需要 |

> ⭐ **qq-bridge 是本包最重要的前置**：本包只提供"给它打的补丁 + 周边脚本"。
> 先把它装通（能收发 QQ 消息），再回来打补丁。

### 装 qq-bridge

```powershell
git clone https://github.com/Derpyu520/qq-bridge.git D:\dsh\qq-bridge
cd D:\dsh\qq-bridge
npm install          # 会跑 postinstall（给 SnowLuma SDK 打补丁）
# 按它自己的 README 配 config.json：consolePort / allow.groups / snowluma.wsUrl 等
npm start
```

**打补丁前先确认它能独立工作**：控制台能打开、`/api/status` 返回 `connected: true`。

> 版本不符时补丁脚本会报「锚点未找到」而退出（不会写坏文件），
> 此时按 `bridge/PATCHES.md` 里的锚点说明手动调整即可。
