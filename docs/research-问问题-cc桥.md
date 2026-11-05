# Research：问问题打通 CC 桥

> 目标：mp-cc 会话里 CC 调 AskUserQuestion 时，问题卡弹到 app（复用 [问问题](plan-问问题.md) 的
> AskUserQuestionSheet），答案回灌 tmux TUI，Q/A 落真实 user 气泡——体感与 API 路径一致。
> 结论先行：**不用解析 TUI 文本**。PreToolUse hook 直接给结构化题面，TUI 只在回答时被 send-keys 驱动。
> 以下 CC 侧行为全部为 2026-08-04 隔离 tmux 探针**实测**（scratch 目录 + 独立 session，未碰 mp-cc/hub）。

## 一、CC 侧事实（实测 + 官方文档双确认）

### hook 通道 ✅

- **PreToolUse** matcher `AskUserQuestion` 实测 fire，stdin JSON 含：
  `session_id / transcript_path / tool_use_id / tool_input`，其中 tool_input 结构化全量：
  ```json
  {"questions":[{"question":"你现在想喝咖啡还是茶？","header":"饮品",
    "options":[{"label":"咖啡","description":"来一杯提神的咖啡"},…],"multiSelect":false}]}
  ```
- **PostToolUse** 实测 fire（用户答完/Esc 后），`tool_response`：
  ```json
  {"questions":[…],"answers":{"你现在想喝咖啡还是茶？":"咖啡"},"annotations":{}}
  ```
  多选答案是逗号空格 join 的单字符串（`"Windows, macOS"`）。
- ⚠️ hooks 是**启动快照**——mp-cc 常驻 session 要轮替一次才吃到新 hook（既有教训）。

### TUI 键位（实测，全部 send-keys 可驱动）

| 操作 | 键序 |
|---|---|
| 单选选项 i | 数字 `i`——多题时选中即自动翻下一题；**单题时选中即直接提交** |
| 多选 toggle 选项 i | 数字 `i`（可反复 toggle）；⚠️ **Enter = toggle 当前行，不是提交** |
| 多选/多题提交 | `Tab` 走到 Submit 页（Review your answers）→ 数字 `1`（Submit answers） |
| 自由输入 | 数字选 `Type something.` 行 → 直打文本（`-l`）→ Enter 提交该题 |
| 跳过整卡 | `Esc` → CC 收到 **"User declined to answer questions"** 并优雅继续（= 方案 a 语义天然对齐） |

- 页脚导航提示随形态变化（单题 `↑/↓`，多题 `Tab/Arrow`）；chips 行 `☐ 饮品 ☐ 操作系统 ✔ Submit` 显示答题进度
- 模型收到的回执格式：`· 题面 → 答案`（tmux 里可见 `User answered Claude's questions`）

## 二、hub 侧地形（已读码，全是现成件）

| 需要 | 现成先例 | 位置 |
|---|---|---|
| hook → hub 上报 | thinking-hook.py（Stop hook POST /thinking loopback） | cc-bridge/thinking-hook.py |
| chat_id 提取 | `CHANNEL_RE` 从 transcript 尾部 channel tag 反查 | thinking-hook.py:18 |
| loopback 端点 + 闸 | `POST /agent/book-note`（isLoopback + 配置闸 + 限长） | hub.ts:1504 |
| 帧广播到 app | `thinkingFramePayload` → mpClients broadcast | hub.ts:1072,1494 |
| send-keys 驱动 | `realPasteIO.sendLiteral/sendKey` + per-session 串行链 | hub.ts:381 |
| 快照校验 | `captureSnapshotWithCursor`（paste-mode capture-verify-retry 模式） | hub.ts:966 |
| session↔chat 绑定 | sessionMap（tmux 名 ↔ claudeSessionId + chatId） | hub.ts:517 |

## 三、设计草案（plan 阶段细化）

```
CC 调 AskUserQuestion
 → PreToolUse hook（askuser-hook.py，模板抄 thinking-hook）
   POST /agent/ask-user {event:"pre", session_id, tool_use_id, chat_id, questions}
 → hub：pendingAskUser[tool_use_id] 记账 + 广播帧 ask_user_question{chat_id, tool_use_id, questions}
 → app：CCBridgeWebSocketClient 收帧 → 弹 AskUserQuestionSheet（UI 整体复用，pending 源换 CC 变体）
 → 用户作答 → app 发 ask_user_answer{tool_use_id, answers:[…]} 帧
 → hub：校验 pending 在 + 快照确认 TUI 还挂着 → 按 §一键位表驱动 send-keys（逐步 capture 校验）
 → 用户答完（或 tmux 侧被抢答/Esc）→ PostToolUse hook POST {event:"post", tool_use_id, answers|declined}
 → hub：清 pending + 广播 ask_user_resolved{tool_use_id, answers?}
 → app：落 Q/A 真实 user 气泡（按 tool_use_id 查重）+ 收卡
```

关键决策点（⧫ 待拍）：

1. **Q/A user 气泡谁落**：推荐 resolved 帧统一落（无论 app 答还是 tmux 答，来源单一不重复；app 答题后卡先收、气泡等 resolved 帧到再落，间隔亚秒级）
2. **跳过语义**：app 侧 X/拖拽 → hub 发 `Esc` → CC 收 declined（和官端体感一致）
3. **pending 重投**：问题帧不进 500 条 replay buffer，hub 单独 pendingAskUser map——app 新连接时若 pending 未决且快照确认 TUI 还挂着 → 重发问题帧（迟到也能答）
4. **开关**：不加新设置（问题卡是核心体验；hook 只装 cc-rp，mp-codex 无此工具天然不涉及）——⚠️ 装 hook = 改 `~/Desktop/cc-rp/.claude/settings.json`，需粟粟点头 + mp-cc 轮替生效
5. **多题混合驱动序列**：单选自动翻题、多选须 Tab，混合序列 hub 侧按 questions 结构逐步生成 + 每步 capture 校验（plan 里给全键序生成函数 + 测试）

## 四、边界

- **tmux 侧抢答/Esc**：PostToolUse → resolved 帧 → app 收卡（若 app 已答一半，答案作废，卡收起）
- **双端同弹（Air+Mac app）**：先答者赢；hub 第二份答案发现 pending 已清 → 回 `ask_user_stale`，app 收卡不落泡
- **CC 轮替/杀 session 时问题挂着**：TUI 死了 → hub 在 kill/respawn 钩子清 pending + 广播 resolved(declined)
- **没人答**：TUI 一直挂着（现状本来如此），app 随时上线随时能答——比现状纯盲区已是纯增益
- **send-keys 校验失败**（快照里问题文本不在了）：不盲发键（键会漏进输入框！），回 app stale
- **数字>9 的选项**：AskUserQuestion 选项上限 4，无此问题
- **hub 重启**：pendingAskUser 落盘与否——问题可能还挂在 TUI 上，倾向落盘（secrets/，同 thinking-log 模式），重启后快照校验存活再决定重发/清理

## 五、成本预估

- cc-bridge：askuser-hook.py（新，~100 行）+ hub.ts 端点/帧/键序驱动（~200 行）+ bun 测试
- app：WS 帧解析 + CC 变体 pending + resolved 落泡（~150 行）；Sheet 零改动
- cc-rp settings.json：+2 hook 条目
