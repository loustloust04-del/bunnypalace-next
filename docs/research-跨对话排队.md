# Research: 跨对话发送排队（A 在跑，B 也被锁）

> 2026-07-11。粟粟报告：CC 正在思考没回复时，切到**另一个对话**发消息也被排队。
> "之前修过一遍" = commit `0980edc1`（06-17），**只修了 UI，没修排队本体**——commit message 原文：
> "B 这时点发送实际仍会进队列等 A 跑完——这里只修 UI 状态对齐，不动串行实发逻辑。"

## 一、机制链条（为什么会排队）

app 是**全局串行单流**设计，整个 app 同时只允许一个 assistant turn：

1. **全局闸门** — `ConversationViewModel.assistantTurnInFlight` 是全局单值 Bool（`ConversationViewModel.swift:1389`）。
2. **任何发送先过闸** — `sendMessage` 开头：`if assistantTurnInFlight { queuePendingSend(...) }`（`:1906`）。**不看是不是同一个对话**——A 在跑，B 发消息一样进队列。
3. **队列出口在 turn 结束** — `finishAssistantTurn()` → `drainPending()`（`:1457-1497`）。而且 drain 有个规则：pending 消息只在**你还停留在那个对话**时才补发；切走了就写回该对话的草稿框（`restoreToDraft`，`:1474-1482`）。
   - 所以症状有两种：留在 B 等 → A 跑完后 B 的消息才发出去；中途切走 → 消息"消失"回草稿。

## 二、为什么 CC 对话最痛

- API 对话一轮几秒~几十秒，串行的痛感低。
- CC 对话一轮 = `CCBridgeProvider.sendStreaming` 注册 reply handler 后 **turn 挂起直到 CC 回复，grace 超时 10 分钟**（`ChatService.swift:1260-1330`，`replyGracePeriod = 600`）。CC 思考/干活 5 分钟，全 app 所有对话的发送就锁 5 分钟。
- 讽刺点：两个 CC 对话绑的是**不同 tmux session**，hub 端本来完全可以并行——串行纯粹是 app 客户端自己锁的。

## 三、全局串行当初是防什么的

`e0e1b551`（连发泄漏进同一次工具执行）引入 turn 生命周期 + pending 队列，防的是：

1. **user+user 连排** — turn 中途插消息会在树上排出连续两个 user 节点，下一轮组装 history 坏掉。→ 这是**同一对话内**的约束，跨对话不适用。
2. **共享可变状态互踩** — 真正让跨对话也串行的原因：
   - `currentPath` / `nodeMap` / `streamingText` / `activeAssistantNodeId` / `activeConversationId` / `recallCallsThisTurn` 全是单值，只为"当前选中对话"服务（`:19`, `:1409-1415`）；
   - provider 实例也是单流：`CCBridgeProvider.replyTimer` 单值——两个 CC turn 并发，第二次 send 会 `replyTimer?.invalidate()` 掉第一个的 grace timer（`ChatService.swift:1309`）；`isStreaming`/`streamingContent` 同理。其它 provider 实例同构。

## 四、修法选项

### 方案 C：CC 对话"发完即收口"（推荐，先做）

CC 本质是异步信使，不是流式 API——发出去就算完，回复什么时候来什么时候落地。

- **改动**：ccBridge 路径的 sendMessage 建完 user node、WS 发出后**立即 finishAssistantTurn**（或压根不设 in-flight）；不再注册阻塞式 reply handler、不建 assistant 占位节点。
- **回复承接已经存在**：`CCBridgeWebSocketClient` 收到 reply 时若无 handler，自动走 `onProactiveMessage` → `insertProactiveAssistantMessage`（`CCBridgeWebSocketClient.swift:569-573`）。这条路已处理：ccMessageId 三层查重、非选中对话落库+未读数、选中对话即时上树+滚动（`ConversationViewModel.swift:178-268`）。
- **效果**：CC 思考不再占全局 turn → 其它对话（API 或 CC）随发随走；同一 CC 对话内连发也不排队（hub/tmux 自己有注入队列，跟 CC 终端行为一致）。
- **user+user 连排不适用于 CC**：CC 路径短路 PromptAssembler 只发最后一条（`:2017` 注释），树上连续 user 无害。
- **要处理的尾巴**：
  1. "等待中"UI——现状靠占位节点+streaming 指示。改后需要轻量的 per-conversation `waitingForCC` 状态（只管 UI，不 block 发送）；或者干脆不显示（像 iMessage 发出即完）。**需要粟粟拍 UX**。
  2. thinking 锚定/CC edit 按 `mp_msg_id` 找节点——proactive 路径 insertProactive 自己存 ccMessageId（`CCBridgeWebSocketClient.swift:46` 注释确认 proactive 不依赖 handler 注册表），思考链锚到回复节点本身，理论不受影响，plan 阶段要实测验证。
  3. 10 分钟超时的"CC 没回"错误提示消失了——没 handler 就没有超时概念。可接受（hub replay 已兜底）或做个软提醒。
- **影响面**：ConversationViewModel 的 ccBridge send 分支 + CCBridgeProvider（可能整个 sendStreaming 阻塞路径退役）。API 对话的串行行为完全不动。

### 方案 A：全并行 per-conversation turn（大手术，后续可选）

- turn 状态全部 per-conversation 化（dict conversationId → TurnState），流式回写不再依赖 currentPath/nodeMap（按 node id 直写，选中时才更新 UI 树），provider 实例改 per-request 状态。
- 解决所有对话类型的并行（包括两个 API 对话同时跑）。
- 工作量大、踩流式管线核心路径，风险高。CC 痛点被 C 解决后，剩余痛感（API 对话间串行，秒级）可能不值这刀。

### 方案 B：只把闸门改成 per-conversation，但仍复用单流管线 —— 不可行

闸门放开但 currentPath/streamingText/provider 实例还是单值，两个流并发必互踩（正是第三节第 2 条）。放开闸门的前提就是方案 A 的状态隔离，没有更便宜的中间态。

## 五、建议

先做 **方案 C**（CC 收口即发）：改动集中、复用现成 proactive 落地路径、直接消掉报告的痛点。方案 A 挂 backlog，等 C 落地后看还痛不痛。

---

⚠️ 等粟粟确认理解无误 / 拍板方向，再进 plan。
