# Review: 思考链回传 + 保存时长产品化（2026-06-11）

> plan: `docs/plan-思考链回传.md`（M1-M3 全部完成）。commits: e413faf（M1 cc-bridge）、ae38e47（M2+M3 app）。

## 1. 边界情况（没处理 / 接受的）

- **一轮没 reply 的 thinking 丢弃**：nudge 后选择不打扰、纯写码轮，thinking 锚不上直接丢（hub log 有 `no_anchor` 痕迹）。接受——没有消息可挂时强行展示反而怪。
- **thinking 晚到的窗口期**：reply 帧和 thinking 帧之间隔几秒（Stop hook 在轮末才 fire）。窗口内气泡先没有折叠块、随后冒出来。没做占位 loading，接受。
- **64KB 截断**：hook 和 hub 双侧 cap。RP 摘要实测 200-400 字符，离上限很远；超长截断带 `…[截断]` 标记。
- **hook 的「最后一轮」定位依赖 channel tag 正则**：`buildChannelTag` 格式变了 hook 会静默失效（no_channel）。两者同 repo 同 commit，风险低；改 tag 格式时记得带上 hook。
- **粟粟在终端直接打字的轮次**：hook 仍按最后一条 channel 消息算「本轮起点」，会把终端轮的 thinking 也算进去拼接，POST 后锚到旧 reply——可能把无关思考挂到旧消息上。罕见（RP session 基本只走 channel），但存在。
- **thinking 去重表独立于 reply 表**：混用会把 reply 去重条目挤出 600 上限 → 旧 reply 漏过去重重复插入。已分表（300 条 ≥ hub 200），这个坑值得记住。
- **同锚多帧**：同一 mp_msg_id 收到多条 thinking（理论上重 POST），后到覆盖先到（同值幂等跳过）。

## 2. 与下一模块交互的风险

- **`MP_CC_SECRETS_DIR` env 是新契约**：hub 持久文件（session-map/reply-log/thinking-log/push-tokens/bind-config）全走它。今后写 hub 测试**必须**设它指临时目录，否则测试帧污染生产 replay log（mcp-server.test.ts 踩过：回放生产数据挂测 + 反向写入）。
- **thinking 帧 schema**：`{type:"thinking", chat_id, mp_msg_id, content, thinking_id}`，replay 顺序在 replies/edits 之后。iOS/Mac 旧版本 app 收到未知帧类型静默忽略，无兼容问题。
- **`showThinkingSummaries` 是 undocumented 开关**：官方哪天移除 → thinking 恒空 → hook `no_thinking` exit 0 → 整条链静默降级回现状，不炸。但「思考过程没了」的现象要先想到这里（查 `/tmp/cc-thinking-hook.log`）。
- **CCThinkingHookInstaller 假设 workdir = `~/Desktop/cc-rp`**（跟 hub.ts 默认一致，env `MP_CC_WORKDIR` 可覆盖）。将来 workdir 做成 app 配置时两处要一起改。
- **诊断链路**：消息「7 节点排查表」（project_mp_cc_bridge_diagnosis）现在多了第 8 节点——thinking 不显示时查：hook log → hub log（no_anchor/broadcast）→ app 去重表 → 节点 ccThinking → ccShowThinking 开关。

## 实测追修（2026-06-11 晚）

首次真机实测思考链不显示，链路逐节排查：hook ✅ → hub 锚定+广播 2/2 ✅ → **app 静默丢弃**。
根因：粟粟主动发问的回复走 pending 回填路径（ChatService:1205 handler 只收文字），节点从没存过 `mp_msg_id` → thinking 按 ccMessageId 找不到节点。这同时是 A4 的旧缺口（CC 一直没法 edit 回答型消息，只能 edit 主动消息）。
修复：① WS client pending 投递后新回调 `onReplyMessageId` 把 id 盖到该会话最新 assistant 节点（同 main 队列 FIFO 保证节点已回填）；② `applyCCThinking` 加兜底——精确锚 miss 时挂最新 assistant 节点。
教训：**「锚定挂载」设计评审时只看了 proactive 路径的 ccMessageId 来源，没核对 pending 路径**——同一个字段两条写入路径，验收要两条都追。
另：修复前已广播的那一轮 thinking 被旧 app 标了去重，Mac 端追不回（一条，可接受）。

## 追修 2：大 session resume 弹窗卡死 headless（2026-06-11 深夜）

粟粟 Mac 重启（20:17）→ tmux 全灭 → hub 重 spawn `--resume` 大 session（126k）时 CC 弹「Resume from summary (recommended)」交互框：headless 没人按 = 卡死，且 boot 后 flush 的消息会打进弹窗、Enter 误确认**摘要恢复 = 压缩小克记忆**。
查证（claude-code-guide）：无任何官方配置/flag 可跳过（GitHub #46751 是同痛点 feature request）；"Don't ask me again" 行为未定义（#60848）。
修复：hub spawnSession boot 检查时 `capture-pane` 检测弹窗 → `Down+Enter` 选「完整恢复」→ 延长一轮 boot 再 flush。TmuxRunner 加 key/capture。真实复现验证通过（kill mp-cc → spawn → hub log「resume 弹窗 → 已选完整恢复」→ ctx 63% 完整回来）。
遗留：弹窗文案变了检测就失效（字符串匹配 "Resume from summary"）；CC 改版时留意。

## 3. 技术债务

- **测试 hub 共享生产 secrets 的历史问题只修了 env 注入**：三个测试文件各自 mkdtemp，没抽公共 helper（三行重复 < 过早抽象，先放着）。
- **hook 每轮全量解析尾部 10MB**：长寿 session 每轮 ~几十 ms python 开销。可优化成记录上次 offset 增量读，不值得现在做。
- **保留时长设置项只在 macOS**；iOS 远程改（经 hub）在 backlog。
- **翻译增强不需要了**：实测真实 RP 环境思考摘要是中文（语言跟随上下文），backlog 里的翻译项可以划掉。
- **2.7 的 UI 最后一跳未实测**：协议层 E2E 已过（真实 CC session 出帧、内容正确），但「气泡里冒出折叠块」要等粟粟重启 app（旧二进制没有 thinking case）。同时三个 RP session（mp-cc/-6/-7x）还跑着旧 settings，**需要 kill 让 hub resume**（绑定已核实齐全，记忆不丢）——执行时被权限分类器拦了，留给粟粟手动或下次批。
