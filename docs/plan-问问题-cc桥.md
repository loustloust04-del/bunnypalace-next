# Plan：问问题打通 CC 桥

> Research: [research-问问题-cc桥.md](research-问问题-cc桥.md)（已确认）
> 粟粟拍板：五个决策点全按推荐——①Q/A 气泡由 resolved 帧统一落 ②app X=整卡 Esc（declined）
> ③pending 独立 map 不进 replay buffer + 连接时校验重发 ④无新开关，hook 装 cc-rp（已同意）
> ⑤键序生成纯函数 + 每步快照校验。**已 go，本文件是执行追踪器。**

## 帧协议

```
hub → app:
  ask_user_question { chat_id, tool_use_id, questions:[{question, header?, options:[{label, description?}], multiSelect}] }
  ask_user_resolved { chat_id, tool_use_id, answers?: {题面: 答案串}, declined?: true }
  ask_user_stale    { tool_use_id }        // 答案到时 pending 已清/TUI 已死
app → hub:
  ask_user_answer   { tool_use_id, skip?: true, answers?: [ {indices:[Int]} | {text:String} ] }  // 按题序
```

- app 答案带**结构**（选项下标 or 自由文本），hub 才能翻译成键序；多选=indices 多个
- skip=true → hub 发 Esc（整卡 declined；已答部分作废——TUI 语义所限，与 API 路径的"已答保留"有差异，接受）
- Q/A 气泡只在 resolved 帧落（app 答完先收卡，亚秒后 resolved 到再落泡；tmux 侧抢答同路）；declined 也落跳过泡（与 API 路径一致）；按 tool_use_id 查重

## 模块

### M1 `cc-bridge/askuser-hook.py`（新，模板抄 thinking-hook.py）
- PreToolUse/PostToolUse 同脚本按 hook_event_name 分流；chat_id 用 CHANNEL_RE 从 transcript 提取
- POST /agent/ask-user：pre={event, session_id, tool_use_id, chat_id, questions}；post={event, session_id, tool_use_id, chat_id, answers?}
- 前置探针：**Esc 时 PostToolUse 是否 fire + tool_response 形状**（决定 declined 信号来源；不 fire 则 hub 靠"该 session 下一条 reply 到达"清 pending 兜底）
- 铁律沿用：任何异常 swallow、永远 exit 0、日志 /tmp/cc-askuser-hook.log

### M2 `cc-bridge/hub.ts` + bun 测试
- pendingAskUser map（key=tool_use_id，值含 chat_id/sessionName/questions/ts）+ 落盘 secrets/askuser-pending.json
- session_id → tmux sessionName 反查（sessionMap 遍历 claudeSessionId）
- POST /agent/ask-user（loopback）：pre→记账+广播 ask_user_question；post→清账+广播 ask_user_resolved
- WS 收 ask_user_answer：pending 在？→ 快照校验（"Esc to cancel" 页脚 + 任一题面前缀在 pane）→ 键序驱动；否则回 ask_user_stale
- `buildAskUserKeySequence(questions, answers)` 纯函数：单选=数字；多选=逐数字 toggle+Tab；自由文本=数字(选项数+1)+文本+Enter；尾部按快照条件补 Submit（Review 页可见→"1"）；skip=Esc
- 驱动走 per-session 串行链 + 步间 sleep + capture 校验（paste-mode 模式）；校验失败不盲发键
- pending 清理钩子：post 事件 / session kill/respawn / 该 session reply 到达（declined 兜底）/ mp 连接时重发前校验
- bun 测试：端点 pre/post、键序生成（单选/多选/混合/自由文本/skip）、stale、持久化

### M3 app 侧
- AskUserQuestionSheet 改 driver 化：产出结构化答案 `[AskAnswer?]`（.options([Int]) / .text(String)），onFinish/onSkip 闭包——API 路径映射回字符串（行为不变），CC 路径发帧
- CCBridgeWebSocketClient：解析三种帧（thinking 帧处理先例同路）
- VM：`pendingCCQuestion`（轻量：chat_id/tool_use_id/questions）；sheet binding 双源；resolved 帧 → 找 conversation 落 Q/A 真实 user 节点（复用二刀落泡逻辑，tool_use_id 查重）+ 收卡；stale → 收卡不落泡
- app 测试：答案映射纯函数 + 帧解析

### M4 部署
- cc-rp/.claude/settings.json +PreToolUse/PostToolUse hooks（粟粟已点头）
- hub launchd kickstart；mp-cc kill-session 轮替（**只 kill-session 禁 kill-server**）让 hooks 生效
- app 双端 build + 装 Air

### M5 E2E（真实 hub + 隔离资源）
- 临时模拟器（defaults 种子，**保留** CC 桥连接）+ 新建 mp-cc-97 会话（不接历史）+ 一次性对话
- 「调用 AskUserQuestion 问我…」→ 卡弹模拟器 → 答题 → tmux 键序落 → CC 接话 → resolved 落 Q/A 泡
- X 跳过路径 → tmux Esc → declined 泡
- tmux 侧抢答路径 → app 收卡 + 落泡
- 测完 kill mp-cc-97 + 删模拟器 + 清 hub 残留 pending

## Todo Checklist

- [x] M1a Esc/PostToolUse 探针 ✅ Esc 不触发 PostToolUse → declined 由 hub 主动收账（app_skip / reply 兜底）
- [x] M1b askuser-hook.py + 手动单测 ✅（pre 带题面/post 带答案/无 channel 静默跳过）
- [x] M2a hub 类型+pendingAskUser+落盘 ✅
- [x] M2b /agent/ask-user 端点 ✅
- [x] M2c 键序生成纯函数 + 测试 ✅
- [x] M2d WS ask_user_answer + 快照校验 + 驱动 + stale ✅（E2E 修 Review 页无页脚的判定序）
- [x] M2e pending 清理钩子 + resolved 帧补发 ✅（E2E 撞出补发缺口，已修）
- [x] M2f bun 测试全绿 ✅（askuser 20 测；全套 217 pass/4 fail=存量基线）
- [x] M3a Sheet driver 化 ✅（573 app 测仍绿，API 路径行为不变）
- [x] M3b WS 帧解析 + pendingCCQuestion + resolved 落泡/stale ✅
- [x] M3c 双端 build 绿 + app 测试绿 ✅
- [x] M4 hooks 部署（cc-rp settings + installer 扩展）+ hub kickstart + mp-cc/30/6 轮替 + 装 Air ✅（Air 锁屏待强启）
- [x] M5 E2E 三路径 ✅（答题键序全落+resolved 泡 / 下拉跳过→Esc→declined 泡 / tmux 抢答→app 收卡落泡；hub log+截图双证）
- [x] M6 review 复盘 + NOW.md + commit push ✅

—— 全部完成（2026-08-04），复盘见 [review-问问题-cc桥.md](review-问问题-cc桥.md)
