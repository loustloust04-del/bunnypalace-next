# Review：真灵动岛（Live Activity）· la0829 批次复盘

> plan：`docs/plan-真灵动岛.md` v3 · 账本：`docs/prompts/2026-08-29-live-activity/README.md` · 状态：**M4b / M6 在飞，本文随收口补全**（🔧 标记 = 待回填）

## 0. 交付了什么（一句话）

hub 已能对已注册的 Live Activity 发 update（真 APNs 传输链验通：sandbox `400 BadDeviceToken` / production 路 `403 BadEnvironmentKeyInToken`），app 侧 token 注册链 + 五种呈现 + DEBUG 起岛全落地；**真机端到端已验（08-30 15:54）**：app 杀死状态下 hub 经 APNs 改写岛内容（22→77→88 + waiting「等你」），push-to-start 拉岛也真机成立。遗留 T13（远程起岛的 token 接续竞态）。

## 1. 边界情况（没处理 / 处理了但没验）

| # | 情况 | 现状 | 归属 |
|---|---|---|---|
| E1 | 真机 token 链路 | ✅ **已验**（08-30：双 token 注册、update 送达、push-to-start 拉岛） | 完成 |
| E2 | Mac 时钟偏移 ±5min 时岛上计时器显示 | M4b ⑥ 只截图记现象，不修 | 🔧 回填截图结论 |
| E3 | `stale-date` 到期后 `context.isStale` UI 分支 | M1 留了分支，M4b ⑥ 验 | 🔧 |
| E4 | `detail` 含 `/` 或 emoji 时 golden 字节比对 | Swift `JSONEncoder` 默认转义 `/` 为 `\/`，TS 不转；**只影响测试不影响 ActivityKit 解码**。未加 golden | 技术债 T1 |
| E5 | 锁屏熄屏变暗时计时器秒位显示 `1:--` | 系统省电渲染，非 bug | 已知，不修 |
| E6 | 8h 上限滚动换岛 | M4b ④（M5 未合时只 end） | 🔧 |
| E7 | codex session 的 transcript 在 `~/.codex/sessions`，`claudeTranscriptPath` 对它无效 | M3b：`model/ctx` 发 undefined（`--`），看门狗判 unknown 不判超时 | 已处理 |
| E8 | 别的 session 卡 AskUser 时本 session 不能假 waiting | M4a 按 `sessionName` 过滤，反查不到丢弃不猜 | 已处理 |
| E9 | 用户在锁屏划掉岛后回 app 要不要自动重挂 | **产品规则未定**，M4b 不自动重挂 | 🔧 问粟粟 |
| E10 | APNs `priority: 5` 可能合并/延迟/丢弃，「发了 200」≠「用户看见」 | checkpoint 记两个时刻 | checkpoint-真机 |

## 2. 与下一模块交互的风险

- **M5 push-to-start**：远程起的岛靠 M2 的全局 `activityUpdates` 监听拿 update token——这一环在模拟器上验不了，真机 checkpoint 第二段。start 的 `alert` 必需且文案固定不泄密。
- **合 master 后生产 hub 要重启**才认 `register_la_token`；`cc-bridge/.env`（NO_PROXY）会被生产 hub 吃到——loopback 不走代理，有益无害，但要知道。
- **`thinking-hook.py` 改了（M4b ⑤）** → app 下次启动自检重装 hook 到 Application Support；生产 CC session 的 Stop hook 行为随之变（多一个无条件 POST `/la/lifecycle`，失败静默）。
- **macOS app 内嵌的 bridge 二进制**：`apns.ts`/`hub.ts` 改了 → 下次 macOS build 重编 `build/cc-bridge/*`。
- **现有 alert 推送路径的潜伏 bug**（不是本刀引入）：`env` 从没用来选 host，app 三处硬编码 `sandbox`，上架/TestFlight 会全 `BadDeviceToken`（`CCBridgeWebSocketClient.swift:90,97,1070` + `hub.ts:1339` + `apns.ts:15`）。LA 路径从第一天按记录 env 选 host；**alert 路径单独一刀修**。

## 3. 技术债

| # | 债 | 出处 | 建议 |
|---|---|---|---|
| T1 | golden 缺带 `/` + emoji 的用例；Swift 测试应加 `.withoutEscapingSlashes` | M3a ask (3) | M5 或收口时补 |
| T2 | `env` 按 `#if DEBUG` 推断而非读 profile `aps-environment`；**真机验收必须 Debug 配置** | 审查席 S11 | 记 checkpoint 前提；改成运行时读 embedded.mobileprovision 是后话 |
| T3 | `StickerProbeUITests/LiveActivityDebugUITests.swift` 脚手架起岛通道脆（设置页恢复上次页签 → 滚过头找不到） | m1-verify / m1-fix | 加「找不到先滚回顶部」或删脚手架 |
| T4 | 测试模拟器 `9451D1D2` 的 `ccBridgeBaseURLOverride` 指着 7899（故意保留） | M2 | 收口时 `defaults delete` 或留着给下批 |
| T5 | bootstrap 的 `deps/libs`/`include` 从软链改拷贝；两台 sim 分给并行 lane | M2/m1-fix 互撞 | 已改脚本；写进 orchestration quirk register |
| T6 | 「基线 4 红」是 `http_proxy` 吞掉 `hub.test.ts` 集成段；`.env` 兜了 | M2/M3b | 已修；教训：**bun 只认进程启动时的代理配置** |
| T7 | `wss.close()` 无残留 timer 的用例没写（集成 hub 是子进程拿不到 wss） | M3b | `stop()` 单测 + 进程正常退出为替代证据 |
| T8 | `LaPhaseSnapshot` 在 scheduler 与 phase 模块同名共存（后者是超集） | M4a | 收口时合一 |
| T9 | idb 在 sheet 内 `tap` 可用、只有快 `swipe` 穿透（与记忆 `feedback_idb_sheet_touch_passthrough` 相反） | m1-fix | **PLAUSIBLE**，亲验后改记忆 |
| T10 | 隔离 hub 起来时测试 sim 会连进来发 focus/set_cc_config | T4 的后果 | 同 T4 |
| T11 | `UsageSnapshot`（`LiveActivityShared/`）没有 wire-key 单测——macOS 测试 target 看不到该目录 | M6 | 要测得动 project.yml 把它挂进 MemoryPalaceTests，或把纯数据层挪去 `MemoryPalace/Services/` |
| T12 | 锁屏三 accessory 在 iOS 26.4 模拟器上截不到（锁屏编辑器不进 screenshot/录屏，idb 找不到 Done） | M6 | 真机验；写进 quirk register |
| T13 | **远程 start 起的岛 token 接不上**：app `recheck()` 只重报已知 token，不给陌生 activity 挂 `pushTokenUpdates`；对账还可能在 token 注册前判它死 | 真机 checkpoint 实撞 | ✅ 已修（`1b542a0e`）：真根因是对账掐监听的赛跑；`liveActivityIdsToQuery` 宽限一轮。真机复验待粟粟 |

## 4. 派单复盘（playbook / quirk register 修订提案，等粟粟裁）

按证据强度排，每条带账本指针：

1. **「起隔离进程」的条款必须整段引用 harness，不许手写 env**（证据：M3a/M2 任务书从 `hub.test.ts:38` 抄漏 `MP_CC_HUB_TOKEN` + `MP_CC_AGENT_DIR`，后者会在生产 agent 目录上跑第二个付费调度器；worker 已按原命令起了 hub，靠缺 token exit(1) 挡住，**纯运气**。审查席 R3 点名：合同越审越干净，跑起来的那行命令没人读）。→ 已固化 `scripts/la-isolated-hub.sh`；提案：playbook「runway clearing」加一句「进程启动配方 = 脚本文件，任务书只引用」。
2. **同族审查席有效**（证据：kimi 撞墙后 opus5 fresh 审 D6/M2/M3a，4 阻断全中、14 应改全采纳，其中 B2 是真金险情）。→ worker-profiles 补一条 opus5 review 席位校准：跨文档矛盾 + 运行配方两轴强；同族盲点用「刻意找编排者会放松的地方」提示可部分抵消。
3. **lane 在飞期间编排者禁止在同一 worktree 做 git 操作**（证据：03:07 我 commit trace 时 worker 正在同一 index 上，没卷进它的文件是运气）。→ 已在账本立规；提案进 playbook「Multiple lanes sharing one working tree」段。
4. **并行 Xcode lane 的 `deps/` 不能软链回主仓**（证据：M2 与 m1-fix 的 `build-ish.sh` 互相打失效 PCH，M2 误杀 m1-fix 进程；我的 M2 验证 iOS build 也因此红一次）。→ bootstrap 脚本改拷贝；quirk register 加：「MP 仓并行 Xcode lane：deps/libs、deps/include 拷贝，resources 可软链；模拟器按 lane 独占」。
5. **bun 只认进程启动时的代理配置**（证据：M2/M3b——本机 `http_proxy` 让 `hub.test.ts` health check 超时，85 个 test 静默只跑 29 个，报成 4 条 unnamed fail；测试代码里设 NO_PROXY 无效，`cc-bridge/.env` 有效）。→ quirk register；教训：「基线红」也要查成因，别标了「基线」就放过。
6. **codex gpt-5.6-sol xhigh 烧额度极快**（证据：M0 23min + M1 20min = 5h 墙；283K tokens 一个 lane）。→ 额度规则补：codex 单 lane ≤30min 或先 `seat-quota` 看剩余 ≥50% 再派。
7. **opus5 lane 的超时模式集中在「起岛通道」排查**（m1-verify 43min、m1-fix 55min，三处修本身 3 分钟）。→ UI 类 lane 的任务书要把「怎么按到按钮」当跑道项由编排者先探，不让 worker 自己摸。
8. **worker 会自己发现同目录下的 `*.answer-N.md` 并继续**（M0 ASK 没 resume 就自解）。→ ask/answer 用文件通道成立，写进 playbook「Ask/answer」段作为无原生 job state 时的补偿。
9. **模拟器 defaults override 是跨 lane 的隐性共享状态**（M2 写的 `ccBridgeBaseURLOverride=7899` 让 M3b 看到「神秘 client」）。→ 任务书里凡写 defaults 的都要在报告「遗留状态」节列出来。

10. **worker 用 `pgrep -f hub.ts` 误杀生产 hub**（M4b，06:53；launchd 拉起，无数据损失，app WS 断连一次）。→ 任务书凡涉及隔离进程，写死「pid 只从脚本输出拿，禁 pgrep/pkill -f」；`la-isolated-hub.sh` 已在注释里写。这条跟粟粟记忆里的 `feedback_pkill_pattern_kills_user_app` 同根。

token 账单（截至 M6，M4b/M5 🔧 补）：
| lane | 席位 | tokens | 时长 | 产出 |
|---|---|---|---|---|
| m0-foundation | codex | ?（log 2.2MB） | 23min | ✅ |
| m1-visual | codex | 283K | 20min | 撞墙，3 commit 已落 |
| review-kimi-contracts | kimi → opus5 | 0 + 174K | 13min | ✅ 4 阻断 |
| m3a-remote-update | opus5 | 194K | 25min | ✅ |
| m1-verify | opus5 | 189K | 43min | ✅ |
| m2-token-registry | opus5 | 209K | 51min | ✅ |
| m1-fix | opus5 | 223K | 69min | ✅ |
| m3b-scheduler | opus5 | 184K | 16min | ✅ |
| m4a-phase-fsm | opus5 | 191K | 18min | ✅ |
| m6-static-widget | opus5 | 227K | 36min | ✅ |
| m4b-fallbacks | opus5 | 203K | 22min | ✅（③④⑥ 未做）|
| 合计（不含 M0/M4b/M5、编排者自身） | | ≈1.87M | | 零产出仅 kimi（额度墙） |
