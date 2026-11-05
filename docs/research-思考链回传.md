# Research: CC 思考链回传 + 对话保存一百年

> 输入：`/Users/susu/Desktop/cc-rp/思考链回传-交接给写代码CC.md`（RP CC 的交接文档）
> 状态：research 完成，等粟粟确认后进 plan。**本文所有关键结论都做过实测或源码核实，引用附行号。**

## TL;DR

1. **方案成立**。RP CC 担心的「thinking 落盘全空」已查明根因并实测打通：CC v2.1.69 起对交互式 session 静默打码 thinking（服务端配合 `REDACT_THINKING_BETA_HEADER`），undocumented 开关 `showThinkingSummaries: true` 能恢复落盘。我已实测：开了之后 transcript 里 thinking 有内容 ✅。
2. **但拿到的是英文摘要，不是思考原文**。原文在当前版本任何渠道都拿不到（细节见下）。这是粟粟需要先知道的最大限制。
3. 通道答案：**Stop hook → HTTP POST 到 hub（7890 已是 HTTP server）→ hub 广播新帧给 Mac/iPhone**。不用 inbox/outbox 文件——文件在 Mac 上，iPhone 收不到；走 hub 广播两端都到，且能复用 replay 补发机制。
4. App 侧 UI 大头已存在：CardFlowView 已有「思考过程」折叠块，MessageSegment 已有 `.thinking` case。改动量主要在接线，不在画 UI。
5. `cleanupPeriodDays: 36500` 已生效（粟粟的 `~/.claude/settings.json` 第一行，实查确认）。产品化＝app 设置页暴露 + 写文件。

---

## 一、thinking 落盘真相（决策点 1，已破案）

### 现状证据

- 扫了本机 `~/.claude/projects/` 全部 transcript：2026-05/06 共 **5607 个 thinking block，全部为空**，只剩 `signature`。不是 cc-rp 进程特例，是全局现象。
- block 结构：`{"type":"thinking","thinking":"","signature":"CAIS…"}`。

### 根因（源码 + 社区双重核实）

本机 CC 源码 checkout（`/Users/susu/Desktop/claude-code-new/src/utils/betas.ts:268-276`）：

```ts
// Skip the API-side Haiku thinking summarizer — the summary is only used
// for ctrl+o display... The API returns redacted_thinking blocks instead...
// Users can opt back in via settings.json showThinkingSummaries.
if (includeFirstPartyOnlyBetas && modelSupportsISP(model) &&
    !getIsNonInteractiveSession() &&
    getInitialSettings().showThinkingSummaries !== true) {
  betaHeaders.push(REDACT_THINKING_BETA_HEADER)
}
```

- 交互式 session 默认带打码 header → API 只回 signature，**客户端根本没收到 thinking 文本**，所以磁盘上是空的。教程那句「磁盘上原文还在」对 v2.1.69 之前成立，现在不成立——RP CC 的怀疑正确。
- `showThinkingSummaries: true` → 不发打码 header → API 返回 **Haiku 摘要器生成的 thinking 摘要** → 落盘。
- 社区佐证：v2.1.69（2026-03-05）起静默打码，无 changelog；GitHub issue #32997 已被官方 closed as not planned。`--output-format stream-json` 的 thinking 也从 v2.1.8 起没了（issue #20127）。
- 实测补充：**print 模式（`claude -p`）也是空的**，和源码注释「SDK/print-mode keep summaries」不符——服务端也参与打码，或 checkout 略旧。反正交互式+开关这条路实测是通的，print 模式不在我们链路上。

### 决定性实验（2026-06-11 实测）

```
tmux 跑 claude --settings '{"showThinkingSummaries": true}'（交互式，/private/tmp 测试目录）
→ 发一条中文问题 → transcript JSONL 里 thinking block len=340，内容为英文摘要 ✅
（实验现场已清理：kill session + rm 测试目录，没碰生产 mp-cc）
```

### 三个必须让粟粟知道的限制

1. **是英文摘要不是原文**：API 侧 Haiku 摘要器产出，中文对话也给英文摘要（实测如此）。原文（raw CoT）当前版本无论怎么配都拿不到。要中文可以后续在链路里加一道翻译，但那是增强，第一版先原样展示。
2. **不是每轮都有**：简单轮次模型可能不思考，没 thinking 就没得显示。
3. **settings 是启动时读的**（源码 settings.ts:812 一带，session 级缓存）：现有 RP 进程不会热生效，要重启 CC 进程。好消息是 hub 有 `--resume` 机制（hub.ts:148-186）——kill tmux session 后下一条消息自动 resume 同一 claude session id，记忆不丢。

### 开关放哪

`getInitialSettings()` 合并 userSettings → projectSettings → localSettings（settings.ts:797-816）。所以**放 cc workdir（`~/Desktop/cc-rp`）的项目级 `.claude/settings.json`** 即可，只影响 MP 拉起的 RP session，不影响粟粟的写码 session（写码 session 的 thinking 继续打码，transcript 更小）。也符合产品化方向：app 管理的是自己 workdir 的配置，不碰用户全局配置。

---

## 二、hook → 记忆宫殿通道（决策点 2，答案：HTTP POST 进 hub）

### 现有链路（已深读 hub.ts 全文 1113 行 + mcp-server.ts 159 行）

```
CC（tmux）── MCP reply 工具 ──► mcp-server.ts ── WS /mcp ──► hub(7890)
                                                              │ 广播 {type:"reply",...} 给所有 /cc 客户端（Mac app + iPhone app）
                                                              │ 持久 replay log（secrets/reply-log.json，500 条，重连补发）
                                                              │ 没人聚焦该 chat → APNs 推送
```

- hub 本身已是 HTTP server：`GET /health` `GET /pair`（仅 loopback，hub.ts:543-560），非 GET 现在回 426。
- **(b) inbox/outbox 文件方案否决**：文件在 Mac 上，iPhone 端 app 只通过 WS 连 hub，收不到文件；且要 app 轮询，背离现有事件驱动架构。

### 建议设计

```
Stop hook（CC 子进程）─ POST http://127.0.0.1:7890/thinking ─► hub
  body: { session_id, chat_id, thinking }                       │ 广播 {type:"thinking", chat_id, content, thinking_id}
                                                                │ 进 replay 缓存（iPhone 后台断连，重连必须能补）
                                                                │ 不推送（thinking 是配菜，不值得叫人）
```

- `POST /thinking` 仅 loopback（hook 和 hub 同机，跟 /health /pair 同等待遇），不暴露 LAN。
- **chat_id 怎么来**：两个选项——
  - **倾向：hook 自己从 transcript 抽**。user message 里有 `<channel source="memorypalace" chat_id="…">`（hub.ts:45 buildChannelTag），倒着找最近一条即可。不依赖 hub 内存状态，hub 重启也不影响。
  - 备选：hook 只发 session_id，hub 查 `secrets/session-map.json`（claudeSessionId→chatId，hub.ts:124-143）。缺点：主 session 若是手动开的可能没绑定、chatId 是 spawn 时绑的可能过时。
- **hook 取哪些 thinking**：最后一条真实用户输入（含 channel tag 的，**不是 tool_result**）之后的全部 thinking block，按序拼接（interleaved thinking 一轮可能多块）。
- **时序**：reply 工具在轮中调用，Stop hook 在轮末 fire → thinking 帧晚于 reply 帧几秒到达，app 把它挂到该 chat **最新的小克消息节点**上。一轮没 reply（如 nudge 后选择不打扰）→ thinking 无处挂，丢弃（可接受，批注可议）。
- hook 必须快进快出 + 永不报错阻塞 CC（exit 0 兜底），transcript 大文件倒读优化进 plan。

### App 侧接线（已读 CCBridgeWebSocketClient.swift / CardFlowView.swift / MessageSegment.swift）

- WS client `handleIncoming` 加 `case "thinking"`（CCBridgeWebSocketClient.swift:462 的 switch），带 thinking_id 去重（仿 reply_id，:479-490）。
- ContentView.swift:303 一带仿 `onProactiveMessage` 加回调，ConversationViewModel 找该 chat 最新 assistant 节点写入。
- **存储方案三选一（plan 阶段定，先列出）**：
  - **A. 复用 segmentsData**：`[.thinking(text:signature:), .text(content)]`。最正统，但 CC 消息会从纯 content 渲染路径切到 segments 路径（CardFlowView:2317），正则脚本/A4 编辑（applyCCEdit 只改 content）都要跟着改，影响面大。
  - **B. content 前缀 `[thinking]…[/thinking]`**：CardFlowView:2243 已有 `ContentCleaner.extractThinking` + :2329 的 `DisclosureGroup("思考过程")` 折叠渲染，**零新 UI 代码**。缺点：污染 content——AUDN 记忆提取、搜索、token 预算都会吃到 thinking 文本；CC edit_message 会把前缀覆盖掉。
  - **C. MessageNode 加 optional 字段 `ccThinking: String?`**：SwiftData 加 optional 属性是轻量迁移；渲染处把 :2329 的条件改成 `thinkingResult?.thinking ?? node.ccThinking`，一行级别。不污染 content、不动现有路径。**我倾向 C**。
- iPhone/Mac 是各自独立 SwiftData store，靠 hub replay 各自落库——所以 thinking 必须进 replay 缓存，否则后台端永久缺失。

---

## 三、保存时长产品化（决策点 3，逻辑简单）

- 现状：粟粟的 `~/.claude/settings.json` 已是 `"cleanupPeriodDays": 36500`（实查第一行）。
- 产品化：CCSettingsView 加一项「对话保留时长」（如 30 天 / 1 年 / 10 年 / 一百年，默认一百年），写用户的 `~/.claude/settings.json`。
- **必须 read-modify-write**：读现有 JSON → 只改这一个 key → 写回，绝不能整文件覆盖（里面有 env、hooks 等粟粟的配置）。文件不存在则创建 `{"cleanupPeriodDays": N}`。
- 同页顺带加「思考链显示」开关（控制 app 收到 thinking 帧是否落库/显示；hook 安装与否也可挂这个开关）。

## 四、产品化打包（hook 安装）

app 首次配对/初始化 CC 时自动写 cc workdir：
1. `<workdir>/.claude/settings.json`：`showThinkingSummaries: true` + `hooks.Stop` 配置（同样 read-modify-write 合并）。
2. hook 脚本本体落到 `cc-bridge/` 目录（如 `thinking-hook.py`，python3 系统自带，零依赖）。
3. 提示「需要重启 CC 会话生效」或自动 kill tmux session（hub 自动 --resume，记忆不丢）——倾向后者，批注可议。

## 五、风险与边界

| 风险 | 说明 / 对策 |
|---|---|
| undocumented 开关随时可能被官方移除 | 链路设计成「没 thinking 就静默没有」，开关失效只是回到现状，不炸 |
| thinking 是英文 | 第一版原样展示，翻译留作后续增强 |
| Stop hook 每轮都 fire（包括无 reply 轮、写码型长轮） | hook 内部判断：没新 thinking / 没 channel 来源就直接 exit 0 |
| transcript 可能几十 MB（长寿 RP session） | hook 从文件尾部倒读，不全量 load |
| hub 重启丢 thinking 帧 | 进 replay log（与 reply-log 同机制）即可覆盖 |
| 写 settings.json 是敏感操作 | 全部 read-modify-write + 只动自己的 key；属于功能本身，在 plan 里逐文件列清楚给粟粟批 |

## 六、建议的 plan 切分（确认 research 后我再写 plan-思考链回传.md）

1. **M1 hub + hook**（cc-bridge）：POST /thinking、广播帧、replay 缓存、thinking-hook 脚本、cc-rp 项目级 settings、hub.test.ts 补测试
2. **M2 app 接收 + UI**：WS client 新帧、节点存储（A/B/C 定稿）、折叠渲染复用、两端 build 验证
3. **M3 产品化设置**：保留时长设置项、思考链开关、hook 自动安装、重启引导

—— 写代码 CC，2026-06-11
