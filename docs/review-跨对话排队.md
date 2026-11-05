# Review: CC 收口即发（跨对话排队修复）

> 实现于 worktree `cc-decouple`，commit `13656278`（M1-M4）+ `8d8729b4`（M5 退役）。
> 双端 build 绿 + 397/397 单测绿。plan：docs/plan-跨对话排队.md。

## 1. 边界情况

- **等待泡跨重启不恢复**：ccWaitingSince 纯内存。发出后杀 app 重开 → 没有等待泡，但回复照常经 hub replay 落地。可接受（v1 拍板）。
- **10min 兜底与迟到回复**：等待泡 10 分钟静默消失后回复才到 → 照常落地（proactive 路径不依赖等待态），只是"没有点在跳"的时段用户可能以为没在等。无错误提示是有意的（老 grace 的报错在 hub replay 兜底下常是假阳性）。
- **同一 CC 对话连发**：不再排队，每条各自建 user 节点直发；hub 端 pendingSends/paste 检测排队注入。回复按到达时的 currentNodeId 链 parent —— 连发 3 条后第一条的回复会链在第 3 条 user 下（线性对话序，和聊天软件一致），**树上不再严格 user/assistant 交替**。CC 路径只发最后一条原文，组装不受影响；但若未来有按"严格交替"假设遍历树的代码，这里是雷区。
- **user+user 连排**：同上，CC 对话树里合法。`drainPending` 的"restoreToDraft 防错发"逻辑不受影响（CC 消息根本不进队列）。
- **thinking 早到（回复没落地就来 thinking）**：`applyCCThinking` 精确锚 miss 时兜底挂"该会话最新 assistant 节点"= 上一轮的回复 → 挂错。旧占位方案同样有此兜底路径，但占位节点在场时兜底恰好挂对。实测中 thinking 晚到几秒（Stop hook 时序），风险低；若真出现，症状是思考链挂错楼，修法是 pending-thinking 缓冲（记账，不预修）。
- **CC 对话的 stop 按钮**：turn 即发即收，输入条不再出现暂停键（CC 本来也停不掉 tmux 里的 CC）。行为变化：以前发出后 10 分钟内显示"生成中"，现在发完立即可继续打字。
- **误路由防御**：任何残留路径把 ccBridge 塞进流式管线 → CCBridgeProvider stub 立即 onError（不再注册 handler 干等 10 分钟）。

## 2. 与相邻模块交互的风险

- **选段引用（master 未合 WIP，replyQuote）**：那边在 `sendMessage` user 节点创建段加了 `userNode.replyQuote = quotingPreview`（约 :1961），在我 CC 分支**之前**的共用段 → 合并后 CC 对话自动继承选段引用落库，无冲突预期；但 git 合并时 ConversationViewModel/CardFlowView 两文件有相邻 hunk，**合并后必须 xcodegen + 双端 build + 重跑全测**（merge 教训 feedback_merge_requires_xcodegen）。
- **hub 侧零改动**：send 帧字段一致（message_id 从占位节点 id 换成 user 节点 id——hub 只透传；CC 回带的 mp_msg_id 是 mcp-server 生成的，与此无关）。
- **replay 三层查重零改动**：insertProactive 的 dedup 在等待泡清理**之前**执行，replay 旧消息不会误清等待泡。
- **推送/NSE**：proactive 落地路径原有 PushIdentityWriter.touch 不变，CC 回复现在全走这条 → 推送索引覆盖反而更全。
- **AUTONOMY（master 当前 WIP）**：触发器骨架走 hub→proactive，同一落地路径，无交集改动。

## 3. 技术债务

- `ProviderRouter.streamingContent/isStreaming/error` 仍聚合 ccBridgeProvider（stub 的态永远 false/nil，无害但是死聚合），全并行（方案 A）时一并清。
- `PendingSend` 队列仍是全局单流设计（API 对话跨对话仍排队）——方案 A 挂 backlog，看 C 落地后剩余痛感。
- 等待泡在文章模式下也用气泡样式（v1 从简，粟粟看了不顺眼再分模式）。
- 等待泡不带头像/昵称行（对齐成本 vs 收益，v1 从简）。
- worktree build 需要 `build/cc-bridge/` 四个二进制（从主工作区拷的，未进 git——本来就 gitignore）。

## 4. 验收清单（装机后粟粟/CC 实测）

1. CC 对话发消息 → 输入条立即恢复可打字，底部出现**弹跳三点**等待泡
2. CC 思考期间切到**另一个对话**（API 或 CC）发消息 → 立即发出，不排队 ← **本案主诉**
3. 反向：API 对话在流式中，切到 CC 对话发消息 → 立即发出
4. CC 回复到达 → 等待泡消失，回复正常落地（选中/非选中对话都试，非选中要有未读数）
5. 回复节点 parent == 刚才的 user 节点（长按看分支/树没乱）
6. 同一 CC 对话连发 3 条 → hub 排队注入，回复依次落地不重不丢
7. CC 消息「重新生成」→ 回复落成原 user 节点下新分支，可切换
8. 思考链回传仍挂对节点（R6c 收词跳转仍通）
9. 杀 app 重开收 replay → 不复读（三层查重回归冒烟）
10. API 对话流式尾部的三点也在弹跳（M1 顺带生效）
