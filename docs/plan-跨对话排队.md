# Plan: CC 对话发完即收口 + 等待点动画（方案 C）

> Research: `docs/research-跨对话排队.md`（粟粟已确认方向 2026-07-12）
> UX 拍板：保留等待指示，三个点由静止改成**挨个小幅度弹跳**（typing indicator）。
> 范围外：API↔API 对话之间仍串行（方案 A 挂 backlog）。

## 一、目标行为

1. CC 对话发送 = 发出即完：建 user 节点 → WS 发给 hub → **立即结束**，不占全局 turn。
2. CC 思考期间：本对话显示弹跳点等待泡；**任何**对话（API/CC）都能正常发送。
3. CC 回复经 proactive 路径落地（已有：查重/未读/上树/滚动），落地时清等待泡。
4. 弹跳点动画同时惠及 API 流式尾泡（同一个 `typingDots` view）。

## 二、改动明细

### M1 — 弹跳点动画（独立小改，先做先验收）

`ChatBubbleStyle.swift:362-370` `typingDots`：
- 加 `@State private var dotPhase = false`，`onAppear { dotPhase = true }`
- 每个点 `.offset(y: dotPhase ? -3 : 1)` + `.animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: dotPhase)`
- 幅度小（~4pt 行程）、错峰 0.15s，符合"小幅度弹跳"
- ⚠️ 按 [[feedback_swiftui_animation_transaction_traps]]：动画绑在点自身的 offset 上、value-based 驱动，不碰容器 transition；真机看一眼没有 additive 叠加飞点

### M2 — CC 发送收口（核心）

**新 helper**（ConversationViewModel 内，`sendCCSlashCommand` 旁边）：
`sendToCCBridge(text:conversation:attachments:replyTo:messageId:context:)`
- payload 组装从 `CCBridgeProvider.sendStreaming` 步骤 7 移植（`ChatService.swift:1340-1376`）：
  chat_id / message_id / content / user / session_name / reply_to / images(≤10MB) / files(≤25MB)
- `wsClient.send` err 只 print 不 fail（原注释：iPhone 抖动时 err 但 hub 已收到，replay 兜底）
- 未连接时触发 `wsClient.connect`（同 sendStreaming 步骤 6）
- 发送后 `ccWaitingChatIds.insert(conversation.id)`（见 M3）

**`sendMessage` 里加 ccBridge 分支**，位置在现有全局 turn guard（`:1906`）**之前**：
```
if provider.type == .ccBridge {
    // 同对话仍串行（防 user 节点插进本对话跑着的 turn 中间）：
    if assistantTurnInFlight && activeConversationId == conversation.id { queuePendingSend(...); return true }
    // 斜杠命令分支保持原逻辑（挪进这个分支内）
    // 正常消息：宏展开 → 建 user 节点 + 链树 + conversation.currentNodeId = userNodeId → save
    //           → sendToCCBridge → scrollToNodeId → return true
    // 不设 assistantTurnInFlight、不建 assistant 占位节点、不走 runStreamingTurn
}
```
- 效果双向：CC 思考不再锁别的对话；API 在跑也不再锁 CC 发送
- `conversation.currentNodeId = userNodeId` 是关键——proactive 回复按 currentNodeId 链 parent（`ConversationViewModel.swift:209`），指到 user 节点回复才接得对
- message_id 用 userNodeId（原来是占位 assistant 节点 id；hub 只透传，CC 回带 mp_msg_id 供 thinking/edit 锚定，锚的是**回复节点**自己的 ccMessageId，proactive 落地时已存，`:216`）

### M3 — 等待状态（per-conversation，不阻塞）

- ViewModel 加 `var ccWaitingChatIds: Set<String> = []`（@Observable 已覆盖）
- **set**：sendToCCBridge 成功排出后
- **clear**：`insertProactiveAssistantMessage` 落地任何 assistant 消息时 `ccWaitingChatIds.remove(chatId)`（不管是不是当前选中对话）；另起 10 分钟兜底 Timer 静默清除（对齐旧 grace 时长，CC 真没回就让点消失，不弹错误）
- **渲染**：CardFlowView 消息列表底部，`selectedConversation.id ∈ ccWaitingChatIds` 时追加一个合成等待泡（assistant 侧样式 + `typingDots`，不是 MessageNode，纯 UI）；跟随滚动锚定沿用现有底部逻辑
- app 重启不恢复等待态（回复靠 hub replay 落地，可接受）

### M4 — regenerate / editAndResend 的 ccBridge 路线改道

两处今天都走阻塞流（`:2950` / `:3048` 有 ccBridge 特判），handler 退役后会变成"占位节点永远不填 + 回复 proactive 落成重复节点"，必须一起改：
- **regenerate（CC 对话）**：不建 sibling 占位；`conversation.currentNodeId` 回拨到锚点 user 节点 → `sendToCCBridge(该 user 文字)` → 回复落地成该 user 节点的新分支（树机制天然支持 sibling 冒泡）
- **editAndResend（CC 对话）**：沿用现有"编辑建分支 user 节点"逻辑到建完节点为止，之后改走 `sendToCCBridge`，不建占位
- 两处同样设 ccWaitingChatIds

### M5 — 退役死代码（本次改动造成的，按规矩清掉）

- `CCBridgeProvider.sendStreaming` 的 handler/timer 阻塞流（整个方法应该没人再调——确认 ProviderRouter 对 ccBridge 的 sendStreaming 分发已无入口后删；provider 类保留做 model 身份）
- `CCBridgeWebSocketClient.registerReplyHandler / unregisterReplyHandler / replyHandlers`（唯一调用方就是上面）+ reply 分发里的 handler 命中分支（`:569-596` 收敛成全走 proactive；`message_id 精确匹配` 丢弃逻辑一并退役）
- `onReplyMessageId` 回调 + `stampCCMessageId`（只服务 handler 回填路径）
- ⚠️ 每删一处先全局 grep 确认无其它引用；拿不准的留下并在 review doc 记一笔

## 三、不动的东西

- API 对话全套串行机制（turn guard / pendingSends / drainPending）原样保留
- proactive 落地路径（查重三层防御）零改动——M3 只在它落地后追加一行 remove
- 斜杠命令 raw 直发逻辑不变（只挪位置进 ccBridge 分支）
- thinking / edit 锚定逻辑（`applyCCThinking` / `applyCCEdit`）零改动

## 四、风险与验证

| 风险 | 验证 |
|---|---|
| 回复链错 parent（currentNodeId 没指对） | 实测：CC 对话发消息 → 回复节点 parentId == userNodeId |
| 同一 CC 对话连发多条 | 实测：连发 3 条 → hub 侧排队注入 → 回复依次落地不重不丢 |
| regenerate 分支树形 | 实测：CC 消息重新生成 → 出现 sibling 分支可切换 |
| thinking 锚定回归 | 实测：CC 回复带思考链 → 思考泡挂在回复节点上（R6c 跳转仍通） |
| replay 复读 | 已有三层查重不动，冒烟：杀 app 重开收 replay 不复读 |
| 弹跳点动画 | 真机看：错峰弹跳、无飞点、流式尾泡同样生效 |

## 五、Checklist（执行追踪器）

- [x] M1 typingDots 弹跳动画（TypingDotsView 文件级 struct，流式尾泡共用）✅ `13656278`
- [ ] M1 验证：真机目视（**待装机后粟粟看**）
- [x] M2 helper（实现为 VM 内 `sendCCFireAndForget` + WSClient `sendUserMessage`——payload 复用
      `assemblePrompt`+`prepareRouterPayload` 原路而不是移植重写，style/附件/引用行为零分叉）✅
- [x] M2 sendMessage ccBridge 分支（guard 改"同对话才排队"；斜杠并入 isCC 判定）✅
- [x] M2 conversation.currentNodeId = userNodeId + save ✅
- [x] M3 ccWaitingSince set/clear（insertProactive 落地清 + 10min stamp 校验兜底）✅
- [x] M3 CardFlowView 合成等待泡（CCWaitingBubbleRow，反转列表物理最前=视觉底）✅
- [x] M4 regenerate CC 路线改道（path 截到 user，回复落成 sibling 分支）✅
- [x] M4 editAndResend CC 路线改道 ✅
- [x] M5 退役 handler 机制（全部四处，grep 零残留）✅ `8d8729b4`
- [x] build macOS + iOS 两端过 ✅
- [x] 单测 397/397 全绿 ✅
- [ ] 第四节验证表逐条实测（**需真机 + 活 hub，装机后走**）
- [x] git commit + push + NOW.md 勾账 ✅

---

（已实现至 `8d8729b4`，实测清单见 review-跨对话排队.md）
