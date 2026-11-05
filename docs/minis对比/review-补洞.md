# Review：补洞批次 H（2026-09-02）

> plan：`plan-补洞.md` · 三席报告：`reports/H-A-report.md` / `H-B-report.md` / `H-Q-report.md` · 台账：`trace/LEDGER.md`
> 五洞修三（3/6/7）、标注一（5）、搁置一（2）。master `b93d0684`，macOS 851 测 + iOS build 绿。**未装实机。**

## 一、边界情况（没处理的）

- **洞 7 `.navigate` 分支的可恢复失败无反馈无重试触发器**（H-Q P3）：resolve 说在当前楼层但 scoped fetch 瞬时取不到 → 保留 key 静默 return，只有下次 `onAppear` 才再试。理论上罕见（resolve 刚确认过），但真撞上用户看不到任何东西。
- **toast 可见性未验**（模拟器通知权限弹窗盖屏，点击通道不通）；`PushNotifications.swift:47-53` 读 `userInfo` 那 5 行胶水未跑（H-Q 用等价注入绕过）。
- **洞 3 收尾指令靠追加到最后一条 tool_result 尾部**：若最后一轮所有工具都没 result（理论上不会，预检/权限拒绝也回灌 isError），指令丢失，收尾退化为无 tools 普通请求。干净做法要动 payload 组装链。
- **`.unavailable` 分支无测试覆盖**（造 fetch 抛错的 SwiftData context 成本过高）。
- **`crossProfileBlocked` 的 500 分片在万级节点上没跑过性能**——只在已确认冲突时进第二趟查询。

## 二、与下一模块交互的风险

- **气泡脚注 vs 预算表公开打架**（H-B 顺手 4）：预算现在记全部 9 次请求，`recordUsage` 仍只记最后一次 → 8 轮 turn 脚注 $0.048、预算表 $0.229。**修完之后用户最可能来问的就是这个。** 改它要先定「一条消息 = 一次请求还是一个 turn」。
- **默认 $10 闸会在第 3-4 轮拦人**——不是回归，是第一次看见真账（≈(轮数+1)/2 倍）。粟粟大概率要调默认额度。
- **`BudgetCalculator.actualCost` 不算 cache token**（H-B 顺手 5）：工具循环正是 cache 命中率最高的场景，修完预算会系统性高估。与「宁可多扣」方向一致但值得单独立项。
- **洞 2 搁置 × 记忆方案**：摘要跨分支污染没修，粟粟本周主攻记忆方案；两者碰同一段 prompt 组装。记忆方案定型时把洞 2 一起看。
- **ChatGPT OAuth 双发根治**（H-B 顺手 1）：router 门闩是隔着地盘的补丁，根治在 `ChatGPTOAuthProvider` 让 `response.completed` 与 `[DONE]` 互斥。

## 三、技术债

| | 债 | 来源 | 严重度 |
|---|---|---|---|
| **P1** | `FileLibraryStore.uniqueSlug` while 循环每轮重算 `findExistingFloorDirectory`（全目录扫描）→ 随楼层数 O(N²) | H-Q | ✅ 09-09 修：占用名单读一次 + 本楼层目录查一次，循环里不再扫 manifest（`FileLibraryStore.uniqueSlug`）；两条计时测试 16s→2s |
| **P2** | 测试往真实 `~/Documents/记忆宫殿/floors/` 泄漏（`shortId` 截 profileId 成 `testrunc` + 无 tearDown），现有 477 个垃圾目录待粟粟拍删；上架 app defaults 的 slugMap 撑到 57KB | H-Q | ✅ 09-09：粟粟拍删，617 个 `楼层-testrunc*` + 8 个 `楼层-xctest*` 已清（635→10 真楼层）；`RunCommandToolTests` 随机段前置 + tearDown，跑完 floors 不涨。slugMap 残留未复核 |
| | `.everything` 还原下 orphan 删除与 restore 靠 Dictionary 迭代顺序碰巧对 | H-A 顺手 1 | 🟡 |
| | `importAll` 的 importState 对解码失败/schema 超标/profileId 不匹配三种 `continue` 粘死 mtime | H-A 顺手 2 | 🟡 |
| | `profilesRestored` 把全跳过的楼层也计数 | H-A 顺手 3 | ⚪ 文案 |
| | `pendingEstimatedCost` 单实例字段，并发放开会串 | H-B 顺手 2 | 🟡 现状串行安全 |
| | `GlobalBudgetStore` 单例测试靠快照隔离，`-parallel-testing-enabled` 会打架 | H-B 顺手 3 | ⚪ |
| | 4 个 worktree 待删（分支已合） | 车头 | ⚪ |
