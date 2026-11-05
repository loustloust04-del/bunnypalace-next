# Plan: CC 思考链回传 + 保存时长产品化

> 前置：`docs/research-思考链回传.md`（粟粟已看过截图教程并说继续）。
> ⚠️ DON'T IMPLEMENT YET — 等粟粟批注。

## 新增实验结论（research 之后补的）

**摘要语言固定英文**：用纯中文 CLAUDE.md（角色扮演设定）+ 中文提问再测一轮，thinking 摘要依然全英文。教程作者（粟粟朋友）的中文思考链应是旧版 CC（v2.1.69 前 thinking **原文**落盘，原文跟随对话语言）；截图2「磁盘上原文还在」描述的就是旧版行为。我们当前版本只能拿英文摘要。→ **中文化做成 backlog 的翻译增强，第一版英文原样展示**（批注点 ①：接不接受第一版英文）。

## 总设计

```
CC 回复完 ── Stop hook(thinking-hook.py) ── POST 127.0.0.1:7890/thinking ──► hub
hub：从 reply-log 倒查该 chat 最近一条 reply 的 mp_msg_id 作为锚 ──► 广播 {type:"thinking", chat_id, mp_msg_id, content, thinking_id}
     │ 进 thinking replay 缓存（iPhone 断连重连补发）；不推 APNs
app：按 mp_msg_id 找到节点（复用 applyCCEdit 的查找）→ 写 node.ccThinking → 气泡内折叠块「思考过程」
```

已定决策（research 里列过选项，这里定稿，批注可推翻）：
- 存储用**方案 C**：`MessageNode.ccThinking: String?` 新字段。不碰 segments、不污染 content。
- **锚定设计**（比 research 的"挂最新节点"更稳）：thinking 挂到 `mp_msg_id` 指向的具体消息。离线多轮后 replay 也不会错挂；锚不上（该 chat 无 reply 记录）就丢弃。
- 开关注入位置：cc workdir（`~/Desktop/cc-rp`）项目级 `.claude/settings.json`。

---

## M1 cc-bridge：hub 入口 + hook（先做，做完联调再进 M2）

- [x] 1.1 `hub.ts` 加 `POST /thinking`（仅 loopback，同 /health 待遇）
  - body：`{session_id?, chat_id, thinking}`；校验 chat_id/thinking 非空 string，thinking cap 64KB
  - 锚定:从 `recentReplies` 倒找该 chat_id 最近一条的 `mpMsgId`；找不到 → log + 丢弃，返回 `{ok:false,reason:"no_anchor"}`
  - 生成 `thinking_id`（uuid），广播 `{type:"thinking", chat_id, mp_msg_id, content, thinking_id}` 给 mpClients；**不推 APNs**
- [x] 1.2 replay：`recentThinkings[]`（MAX 200）持久到 `secrets/thinking-log.json`；client connect 时在 replies + edits **之后** replay（先有消息节点再挂 thinking）
- [x] 1.3 `cc-bridge/thinking-hook.py`（python3 零依赖）：
  - stdin JSON 取 `transcript_path`
  - 尾部读：文件 >20MB 只读最后 10MB（丢首个半行）
  - 倒序定位最后一条真实用户输入（content 含 `<channel source="memorypalace"`；排除 tool_result / isMeta / isSidechain 行），正则抽 `chat_id`
  - 收集其后全部 assistant thinking block（非空、排除 isSidechain），按序 `\n\n` 拼接
  - 没 channel / 没 thinking → exit 0；POST timeout 3s；**任何异常 swallow + exit 0**（绝不阻塞 CC）
- [x] 1.4 写 `~/Desktop/cc-rp/.claude/settings.json`（read-modify-write 合并，预计文件不存在则新建）：
  ```json
  { "showThinkingSummaries": true,
    "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "python3 /Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/cc-bridge/thinking-hook.py" } ] } ] } }
  ```
  ⚠️ settings 文件属粟粟手动确认项，本 plan 获批 = 确认。
- [x] 1.5 验证 hook 在 hub spawn 的 session 里自动生效（CC 对项目级 hooks 可能有审批门槛，headless 会卡）→ 卡的话 fallback：`hub.ts spawnSession` 的 claude 命令加 `--settings <cc-bridge>/cc-session-settings.json` 注入（hub 拥有 spawn 命令，产品化更可控）
- [x] 1.6 `hub.test.ts` 补测试:POST 校验、锚定成功/失败、广播帧、replay 顺序
- [x] 1.7 联调:`bun test` 全过 → 重启 RP 主 session（tmux kill，hub 自动 --resume 不丢记忆）→ 真实发一条消息，hub log 看到 thinking 广播

## M2 app：接收 + 存储 + 渲染

- [x] 2.1 `MessageNode` 加 `var ccThinking: String?`（SwiftData 轻量迁移；只渲染读，不做谓词查询——optional 谓词坑不踩）
- [x] 2.2 `CCBridgeWebSocketClient` 加 `case "thinking"`：`thinking_id` 去重（仿 reply_id 持久去重，:479-490 模式）→ `onThinking(chatId, mpMsgId, content)` 回调
- [x] 2.3 ContentView:303 一带接线 → `ConversationViewModel.applyCCThinking(chatId:ccMessageId:content:context:)`，查找逻辑照抄 `applyCCEdit`（:206-220：当前会话 nodeMap 优先，否则会话内 fetch + 内存 filter ccMessageId）
- [x] 2.4 渲染（两个路径都接，共用源码注意 #if）：
  - `CardFlowView.swift:2329` 折叠块条件 `thinkingResult?.thinking` → `thinkingResult?.thinking ?? node.ccThinking`
  - `ChatBubbleStyle.swift:246`（iOS 气泡）同样处理
  - 折叠块样式沿用现有 `DisclosureGroup("思考过程")`，不新画 UI
- [x] 2.5 显示开关 `@AppStorage("ccShowThinking")` 默认 true：关=不渲染折叠块（数据照落库，开回来还在）
- [x] 2.6 `xcodegen generate && xcodebuild -scheme MemoryPalace build` + iOS build 通过
- [ ] 2.7 实测：协议层 E2E 已过（真实 CC session → reply+thinking 帧到 client，中文思考）；**气泡 UI 实测待粟粟重启 app**（旧二进制没有 thinking case）

## M3 产品化设置（macOS 设置页）

- [x] 3.1 `CCSettingsView` 加 Section「CC 思考与存档」：
  - 「显示思考过程」Toggle（绑 2.5 的 AppStorage）
  - 「对话保留时长」Picker：30 天 / 1 年 / 10 年 / 一百年（=36500，默认），写 `~/.claude/settings.json` 的 `cleanupPeriodDays`
  - 当前值从文件读出显示；**read-modify-write**，绝不整文件覆盖
- [x] 3.2 iOS 端配置项（实做时调整：「显示思考过程」两端都有——它管本端渲染；保留时长仅 macOS）（CC 只在 Mac 跑；声明整个 #if os(macOS) 包，平台 switch 教训）
- [x] 3.3 hook 安装自检：Mac app 启动时若 CC 桥已配对 → 检查 cc workdir settings 含 showThinkingSummaries + Stop hook、hook 脚本存在，缺则补写（与 1.4 幂等）
- [x] 3.4 build 两端 ✅ + commit push（设置页点击路径随 2.7 一起实测）

## Backlog（本次不做）

- 英文摘要 → 中文翻译（hub 或 app 加一道便宜模型翻译；成本/延迟/翻译质量待议）
- ccThinking 是否喂给 AUDN 记忆提取（当前不喂）
- iOS 端经 hub 远程改 Mac 的 CC 配置

## 边界情况（接受，批注可改）

| 情况 | 行为 |
|---|---|
| 一轮多次 reply | thinking 锚到该 chat 最近一条（=最后一条）reply |
| 一轮没 reply（如 nudge 后不打扰） | 锚不上，丢弃 |
| 该轮模型没思考 | 无帧，气泡无折叠块 |
| CC edit_message | 只改 content，ccThinking 不动 |
| showThinkingSummaries 被官方移除 | thinking 全空 → hook exit 0 → 回到现状，静默降级 |

## 批注点汇总

1. 第一版英文摘要直接展示，接受吗？（翻译进 backlog）行吧。
2. 保留时长 Picker 的档位（30天/1年/10年/一百年）和默认值（一百年）✅
3. M1.7 重启 RP 主 session 的时机——我做联调时直接 kill+resume，还是等你挑时间？✅可以恢复就直接resume。
4. 全程 master 直接做（小步 commit），不开分支——按你的 git 工作流，OK？其实可以大步做。

—— 写代码 CC，2026-06-11
