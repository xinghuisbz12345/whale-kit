# 小鲸鱼工具包（whale-kit）

> 把「一个能自己刷 B站、会换音色、记得住事、还会安慰人的 QQ 机器人」跑起来所需的自制部分，
> 打包成可移植的工具包 + 安装教程。
>
> **不含**：语音库音频、账号凭据、个人记忆/群聊归档、任何令牌。
> 你到新机器上自己准备账号和模型即可。

---

## 这个包解决什么问题

DSH（DeepSeek Harness）+ qq-bridge 本身能跑通 QQ 机器人，但要做成"有日子的小鲸鱼"，
还需要很多胶水。这个包就是那些胶水：

| 模块 | 文件 | 干什么 |
|---|---|---|
| **发图** | `pipeline/apply-image-patch.ps1` | 给桥接加 `qq_send_image`：BV 封面 / B站专栏取图 / 任意公网 https（带 SSRF 防护） |
| **三音色 TTS** | `pipeline/speak-server.py` + `apply-tts-patch.ps1` | 多引擎语音合成（说话模型 + 克隆音色），惰性启动，切一次模式即可持续生效 |
| **守护** | `pipeline/watch-bridge.ps1` | 桥接/TTS 挂了自动拉起（按**进程**判定，避免把"模型加载中"误判为挂） |
| **一键启动** | `pipeline/start-all.ps1` | 按正确顺序起 TTS + 桥接，附带状态检查 |
| **重启编排** | `pipeline/restart-dsh-with-voice.ps1` | 脱离进程树重启 DSH，再把语音栈拉起来（自己杀自己时必须用计划任务） |
| **长期记忆** | `pipeline/mem.mjs` | 记忆库（人/决定/坑/承诺）+ 索引 + 关键词检索 + 群聊归档检索 |
| **群归档回填** | `pipeline/backfill-chat.mjs` | 把桥接状态里剩的最近消息抢救成按天 jsonl |
| **人格同步** | `pipeline/sync-persona-to-v2.mjs` | 把规则从 `qq-chat` 同步到实际生效的 `qq-chat-v2`（reserved2 模式用后者） |
| **人格规则** | `persona/qq-chat-rules.snippet.md` | B站/发图/评论/语音/音色模式/记忆/安慰 的完整规则块，粘进 preset 即可 |
| **养鱼流程** | `persona/AGENTS.md` | 鲸鱼会话的作业指导书（选题→看懂→分享→日记→推群→写进度档） |
| **鲸鱼→QQ 桥** | `pipeline/whale-to-qq.ps1` | 把 dsh-bili-whale 的通知文件转成群消息 |
| **并行下载** | `pipeline/Download-Parallel.ps1` | 绕开 hf-mirror 单连接限速（分段 Range + 并发 + 拼接） |
| **记忆模板** | `templates/seed-memory.template.mjs`、`templates/MEMORY.template.md` | 去掉个人信息的初始记忆骨架 |

---

## 快速开始

1. 读 [`INSTALL.md`](INSTALL.md)（详细步骤 + 验证清单 + 12 个已知坑）
2. 参考 [`bridge/PATCHES.md`](bridge/PATCHES.md)（每个补丁改了什么、锚点在哪）
3. 规则块从 [`persona/qq-chat-rules.snippet.md`](persona/qq-chat-rules.snippet.md) 复制

## 前置条件

- Windows 10/11
- **DSH 桌面版**已装好，且 `qq-bridge` 已能正常收发 QQ 消息（这是地基，本包不包含它）
- Node.js 22+（DSH 自带一份也可以）
- Python 3.12（只有跑 TTS 才需要）
- 一个能登录的 QQ 机器人号（NapCat / SnowLuma 网关）

## 许可与边界

- 本包代码：随你使用（MIT 精神）。
- **dsh-bili-whale** 是第三方开源项目（MIT），本包只提供接线方式，不包含其代码。
- **角色音色版权属配音演员**：自己听着玩可以，**不要商用、不要公开传播**。
- 用你自己的账号操作，后果自负。
