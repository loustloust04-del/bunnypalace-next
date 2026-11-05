# LEDGER —— minis 对比批次（MC，2026-08-24）

批次短 id：**MC**（minis-compare）。计划 lane 数：**6 侦察 + 1 交叉核查 = 7**。
车头：master 工作树（`/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace`），session `21f01c6d`。

## Partition declaration（补写，见下方偏离说明）

**本批次占用**：
- 写：`docs/prompts/2026-08-24-minis-compare/**` （唯一写入面）
- 读：MP 全仓只读 + OpenMinis clone 只读（`<本 session scratchpad>/OpenMinis`，commit `09fc199`）
- master HEAD：只为本目录的 trace 做 commit，不碰产品代码

**显式让出**（已确认有并行线在做，本批次不碰）：
- **权限模型轴** → `worktree-permissions` 线，08-23 PERM 批次已收口（`docs/prompts/2026-08-23-perm-research/`），P1 代码已落 `93d6bced`→`bee89e55`。本批次只引用不重做。
- **设备能力集移植轴**（Calendar/Reminders/Clipboard/Maps/Weather/Location/Photos/Vision/Notification 等族）→ 同一条线，08-24 02:33 起 research 中（`.claude/worktrees/permissions/docs/research-设备工具.md` + `docs/prompts/2026-08-24-device-tools/`，DEVT-scout 在跑）。本批次六轴**均不含设备能力族**。
- `.claude/worktrees/**` 下任何 worktree → 不读不写不 touch。

**相邻但不冲突的一处**：MC-L1 会碰「URL scheme / 深链」，方向是「深链作为 app 的对外接口规范」；设备工具线的 `open_url` 是「把深链包成工具给 AI 调」。方向相反，产出互补。

## Lane 表

| lane | 目的 | 席位 | 状态 | 报告 |
|---|---|---|---|---|
| MC-L1 | 系统公民身份 | ~~opus5~~ → codex | ✅ 收割已读 | `reports/L1-report.md` 130 行 |
| MC-L2 | 同步与数据可移植 | ~~opus5~~ → codex | ✅ 收割已读 | `reports/L2-report.md` 147 行 |
| MC-L3 | 消息列表与渲染 | ~~opus5~~ → kimi k3 | ✅ 收割已读（本批次最佳） | `reports/L3-report.md` 235 行 |
| MC-L4 | Provider 接入层与账号登录 | codex gpt-5.6-sol | ✅ 已收割已读 | `reports/L4-report.md` 180 行 |
| MC-L5 | 上下文治理：Compaction/Preflight/LoopDetector/Budget | codex gpt-5.6-sol | ✅ 已收割已读 | `reports/L5-report.md` 153 行 |
| MC-L6 | 会话对象模型：Skill/Soul/Fork/MCP OAuth/workspace | codex gpt-5.6-sol | ✅ 已收割已读 | `reports/L6-report.md` 146 行 |
| MC-V | 交叉核查 | — | **刻意不跑**（理由见下） | — |

### 第一轮席位阵亡（02:55）

L1/L2/L3 原派 opus5（CC 原生 subagent），三条**同时**因账号 session limit 挂掉（reset 3:50am PT）。
死因不是 worker 能力问题，是**席位选择把三条 lane 押在同一个配额池上**——codex 三条同时段全部 exit 0，因为走的是另一个账号。
教训（建议进 playbook）：**并行 lane 的席位分配要按配额池分散，不只按 model family 分散**。error diversity 讲的是失败面不相关，配额池是一个此前没被点名的共享失败面。

重派后阵型：codex ×5（L1/L2/L4/L5/L6）+ kimi ×1（L3）。跨 family 从 3 家降到 2 家，是被迫的降级——L3 特意给了 kimi 保住跨家对照。

### 已收割三份的车头验收（亲读，非摘要）

三份均遵守红线（只写自己的报告）、格式合契约（TL;DR 表 + 行号 + 反向发现 + 不建议学）。
**escape hatch 全部生效**：三席合计推翻车头 8 条前提（见下），这正是 prompt 里要求的行为，不是失败。

车头前提被推翻记录（我的转写债，记账）：
1. 「MP 6 家内置 provider」→ 实际 16 张预设模板（L4）
2. 「APIProvider.swift 1464 行」→ 实际 1507 行（我引了 07-04 的 MODULE_INDEX 快照，没标假设）
3. 「OM 七家 × 各自 OAuth 对称结构」→ 实际 8 type，OpenRouter/xAI/Kimi 复用 OpenAI 实现，目录不等形（L4）
4. 「MP 基本没有 Compaction」→ MP 有累计摘要+自动触发+手动压缩+可见状态（L5）
5. 「GlobalBudgetStore 60 行 60 天没动，基本是死的」→ 是活的，主发送路径在调用（L5，我又一次直接引用 MODULE_INDEX 的 ⚪ 标记当事实）
6. 「OM 的 RequestBudget 是 token/钱/轮数预算」→ 是**图片字节**预算（L5）
7. 「OM workspace ≈ MP 楼层」→ workspace 实为 `<sessionId>/workspace` 会话文件桶，不是人格容器（L6）
8. 「OM 也有 OpenRouter，看他们怎么处理 OR 的特殊性」→ OM 没解决 OR pinning，MP 反而更完备（L4）

**根因**：MODULE_INDEX.md 是 2026-07-04 快照，我把它的数字和 ⚪/🔴 标记当现值直接写进了 prompt。playbook 的「陈旧文档事实降级为假设」是车头的无条件义务，本批次没做到。
**已生效的补偿**：COMMON.md 的 escape hatch 条款让三席都主动falsify了，零条错误前提进入结论。

## 偏离记录（诚实记账）

1. **partition declaration 是事后补的**。派单在先（02:40），发现并行线在后（02:45，靠 `ps` 撞见 DEVT-scout 进程）。playbook 要求「same-project parallelism 必须先声明后开工」，本批次违反了先后顺序。
   实际损害：零——六轴与并行线零重叠（见上），且本批次纯只读。
   但这是真实的流程漏洞：**发车前没有枚举活跃 session**。建议进 playbook 修订提案：派单前的 runway check 应包含「枚举同项目活跃 worker 进程 + 扫 worktree 近期 mtime」。
2. **ledger 没有写进 project card**。卡（`project-cards/bot/memory-palace.md`）此刻正被并行线维护（权限 thread 记录活跃），两个 session 同写同一文件会撞。本 ledger 落在批次目录内，收口时再往卡上加**一行指针**（冲突窗口最小）。


---

## 收口（2026-08-24）

**六轴全部收割，车头逐份亲读**（共约 990 行报告，raw log 约 7.5MB）。产出汇总在 `docs/research-minis-对比.md`，等粟粟 ⧫。

### 车头亲验的八个洞

对照 Minis 顺手体检出的 MP 自身缺陷，**每条都是车头自己读代码复核的，不是 worker 转述**：
fs_write 清空文件 / 摘要跨分支污染 / 工具循环漏账 / 未知 provider type 清空凭据 / MCP OAuth 配置壳 / 同步备份跨楼层偷数据 / 跨楼层通知静默失败 / 流式 O(N²) 重 parse。

### 不跑 MC-V 交叉核查席的决定

原计划第七席吃全部六份报告做交叉核实。**刻意不跑**，理由：(a) 最高价值的 claim 车头已亲验；(b) 六轴正交，无互相依赖的 claim，跨文档矛盾风险面小；(c) research 产出交粟粟批注，她是最终 gate。
按 playbook 的 no-silent-caps 条款，这次覆盖收窄写在这里而不是默默省掉。

### 给 playbook 的修订提案（两条，等操作员裁决）

1. **席位分配要按配额池分散，不只按 model family 分散。**
   本批次 L1/L2/L3 原派 opus5，三条**同时**因账号 session limit 阵亡；同时段 codex 三条全部 exit 0（另一个账号）。
   playbook 现有的 error diversity 讲的是「同族模型失败面高度相关」，但**共享配额池是一个此前没被点名的共享失败面**——它跟模型家族正交，而且失败是同时的、全量的。
   建议：dispatch discipline 增加一条——并行 lane 的席位分配需同时满足「跨 family」和「跨配额池」。

2. **派单前的 runway check 应包含「枚举同项目活跃 worker 进程」。**
   本批次发车后才靠 `ps` 撞见另一条线（`worktree-permissions`）正在做同一对象（Minis）的相邻轴，事后补的 partition declaration。
   playbook 的 multi-orchestrator 章节要求「先声明后开工」，但没规定**怎么发现**别人在跑。
   建议：runway clearing 的清单里加「扫活跃 worker 进程 + 扫 worktree 近期 mtime」。

### 车头自身的过失记账

10 条前提被 worker 用证据推翻，根因两个：把 2026-07-04 的 `MODULE_INDEX.md` 快照当现值写进 prompt；从目录/文件名推断能力存在（`LANTransport.swift` → 「它有 LAN 传输」，实为 `isImplemented = false` 的空壳）。
playbook 的「陈旧文档事实降级为假设」是车头的无条件义务，本批次没做到。零条错误前提进入结论，全靠 COMMON 的 escape hatch 条款兜住——**这不能算车头做对了，只能算防线起了作用**。

### Lane 清理

本批次无 worktree、无分支，六席均为只读进程，全部自然退出。无待回收资源。

---

> **归拢说明（2026-08-24，粟粟要求）**：本批次全部文件已从 `docs/prompts/2026-08-24-minis-compare/` 移到 `docs/minis对比/`（报告在 `reports/`，本文件与派单 prompt 在 `trace/`，汇总在 `对比报告.md`）。上文所有路径均为**派单时状态**，按 trace 冻结原则未回头修改。

---

# 批次 H（补洞，2026-09-02）

粟粟「那几个大漏勺现在补了多少了，是不是还剩一些没补，你去看看并且走流程」→ ⧫「Hc 先不管，别的按你推荐」。
plan：`../plan-补洞.md`。共用条款：`IMPL-COMMON.md`。计划 lane 数：**2 实施 + 1 QA（收口时）**。
seat-quota 09-02 派前：`claude 5h 1% 7d 19% | codex 5h 0% wk 34% | kimi ?`。

## Partition

- 车头：master 工作树，**lane 在飞期间不做任何 git 操作**（08-30 教训）。洞 5 标注已在派单前落 `98660a54`。
- H-A：`BackupStore.swift` / `SyncStore.swift` / `ContentView.swift` + 新 helper + `SyncStoreTests` / 新 `BackupStoreTests`
- H-B：`ChatService.swift` / `ConversationViewModel.swift` 工具循环段 / `BudgetGateTests.swift`
- 两条 lane 零共享文件。`ConversationViewModel.swift` 只有 H-B 碰。

| lane | 洞 | 席位 | worktree | 状态 | 报告 |
|---|---|---|---|---|---|
| H-A | 6 + 7 | opus5（Agent, isolation: worktree） | Agent 自建 | in-flight | worktree 内 `reports/H-A-report.md` |
| H-B | 3 | codex gpt-5.6-sol（detached） | `.claude/worktrees/h-b-tool-loop` | in-flight | worktree 内 `reports/H-B-report.md` |
| H-Q | 全套测试 + 双端 build + 洞 7 模拟器实证 | codex fresh | master（合并后） | 未发车 | — |
| — | 洞 5 标注 | 车头 | master | ✅ `98660a54` | — |
| ~~H-C~~ | ~~2~~ | — | — | ⧫ 搁置 | — |

## H-A 收割（09-02，车头亲读 + diff 抽查）

**DONE**。分支 `worktree-agent-a138954ed40783572`，3 commit（`c04a2210` 复现 → `fee98e79` 修 → `18a7bdb1` 报告），11 文件 +939/-11，35 min，326K tokens。

**验收**：
- 红→绿原始输出齐全；洞 6 红灯抓到的是**真实 upsert**（`profileId` 从 `-A` 被整行改成 `-B`，标题+节点连带被抢），不是推理。
- 全套 839 测 2 fail = `RunCommandToolTests` 墙钟 flake（同 suite `testEcho` 一句 echo 也 14.7s，机器被两个并行构建压出 ~15s 子进程延迟地板）；diff 与 run_command 零交集。**未在空载机器跑绿，归 H-Q 复核。**
- 车头亲读三段核心：`PushTargetResolver.swift` 全文 / `SyncStore` 守卫 diff / `ContentView` 重写 diff——干净。异楼层分支「不消费 key 让新 subtree 再解析」比 plan 写的「等 subtree 就绪再导航」更简单。

**偏离 4 条，全部裁「收」**：
1. `SyncStore:448`（`processTombstones`）**不是洞**——scoped fetch 后是 `continue` 无 insert，且「B 的墓碑不删 A 的同 id」是正确语义。补回归锚不改代码。**车头 plan 写错，记账。**
2. 用 `findCrossProfileConversationConflicts`/`findCrossProfileNodeConflicts` 而非 `crossProfileConflictedConversationIds`（后者要 payload 包装，Service 手上是 `ConversationDocument`）。`ImportSupport.swift` 零改动。
3. `.everything` 还原多一条保护：备份之后新建的楼层不被偷；既有「备份内楼层互相覆盖归属」语义锚死不变。
4. 碰了 `RestoreSheet.swift` / `DataSettingsTab.swift` / `BackupManifest.swift`——契约要求跳过数露到 UI，绕不开，且不是 H-B 地盘。

**顺手发现 3 条（未修，待粟粟拍）**：`.everything` 下 orphan 删除与 restore 的 Dictionary 迭代顺序耦合 / `importAll` 的 importState 对解码失败等 `continue` 分支粘死 mtime / `profilesRestored` 把全跳过的楼层也计数。

**交接 H-Q**：① 空载复核 `RunCommandToolTests` 2 条 ② 洞 7 `simctl push` 三件事（切楼层后 onAppear 再消费 / toast 可见 / 无死循环）③ iOS 编译面。

**环境**：master 在 H-A 出发后前进 3 commit（`92f50700`/`01e68505`/`0f1f258e`，另一 session 修 hub 长消息碎片），与 H-A 零文件重叠。合并等 H-B。

## H-B 席位阵亡 + 接手（09-02 09:19）

**codex 撞账号配额墙**：`You've hit your usage limit … try again at 1:24 PM`，487K tokens，跑了 ~55 min。
死时状态：2 commit 已 push（骨架 + 红灯测试 13 测 8 fail 正确地红着）+ **工作树 273 行未提交实现**（签名改 `(([ToolCallBlock], TokenUsage?) -> Void)?` / `preCheckToolRequestBudget` / `continueToolLoop` 抽出 / 预算不足收尾文案）+ 报告 PARTIAL 已写一条偏离（ChatGPT OAuth 触发点实际在 `ChatGPTOAuthProvider.swift:211-220`，决定在 `ProviderRouter` 适配不越界）。

**处置**：车头代收工作树 commit `813507c9`（message 标 WIP）push 分支 → 派 **opus5 接手**（Agent, isolation worktree, `git checkout worktree-h-b-tool-loop`），任务书要它**先审 WIP 再续**，方向不对允许重做。不等 13:24 墙解——4 小时太长，且 opus5 08-30 校准为等质替补。

**seat-quota 疑点已解**：撞墙后读数 `codex 5h 97%→13:24`——百分比是**已用**，派前 0% 是 13:06 刚重置。所以不是读数错，是 **codex gpt-5.6-sol 一条实施 lane 55 min 吃光一整个 5h 窗**（08-30 quirk 说 23 min ≈ 半窗，这次实测一整窗）。**规则升级：派 codex 做实施 lane，按「一条 lane = 一个 5h 窗」预算；窗内不派第二条；0% 不等于够用。**

| lane | 席位 | 状态 |
|---|---|---|
| H-B | ~~codex~~ → opus5（接手） | in-flight（第二席） |

## 批次 H 收口（09-02）

| lane | 结果 |
|---|---|
| H-A 洞 6+7 | ✅ opus5 35min 326K · 3 commit · merge `6e7e1e2e` |
| H-B 洞 3 | ✅ codex 55min 487K **撞墙**（WIP 七成，测试其实已绿但它没跑到）→ opus5 接手 18min 230K · 7 commit · merge `b93d0684` |
| H-Q QA | ✅ opus5 26min 222K · 851 测 2 红（**不是 flake，真 bug 立案**）· iOS build 0 error · 洞 7 跨楼层实证通过（等价注入，`simctl push` 点击通道不通）|
| 洞 5 | ✅ 车头 `98660a54` |
| 洞 2 | ⧫ 搁置 |

**不装实机** ⧫ 全程遵守。模拟器用 17 Pro Max，已还原关机。

**H-Q 抓到的**：H-A/H-B 两席都把 `RunCommandToolTests` 2 红判成「并行构建压出的墙钟 flake」——错。空载复核**一次比一次慢**（9.7s→12.4s），根因 `FileLibraryStore.uniqueSlug`（`:504-516`）while 循环每轮重算全目录扫描 + `shortId`（`:574-577`）把 profileId 截成 `testrunc` + 无 tearDown ⇒ 粟粟真实 `~/Documents/记忆宫殿/floors/` **495 目录、477 个测试垃圾**，slugMap 57KB。存量 bug，与两 lane 改动零交集，被这批测试轮次养大。**两席判错 + 第三席空载复核抓到 = 独立验证席的价值实证。**

**playbook 修订提案（累计三条）**：
1. codex gpt-5.6-sol 实施 lane 按「一条 = 一个 5h 窗」预算（本批实测 55min 一整窗）。
2. 「两席同判 flake」不等于 flake——收口 QA 的空载复核是硬步骤，且要看**趋势**（单调恶化 = 不是 flake）。
3. 测试卫生：任何往真实用户目录写的测试必须 tearDown；`shortId` 截断 profileId 让测试身份撞车是结构性坑。

**Token 账（车头可见的）**：opus5 三席 778K，codex 487K，合计 ~1.27M。车头自身 ctx 至收口 ~80%。

**Lane 清理**：H-B 的 `.claude/worktrees/h-b-tool-loop` + 三个 Agent 自建 worktree（`agent-a138954ed40783572` / `agent-a0c9dc056b525b73f` / H-Q 无 worktree）——分支均已合 master，predicate `tip is ancestor of master && clean` 成立，**待删**（车头 context 紧，留给下一 session 或粟粟一句话）。
