# 对抗审：mac 止血批六刀（只读）

工位 `/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/.claude/worktrees/mac`，范围 `git diff 922b9734c..62f30f4bb -- MemoryPalace MemoryPalaceTests`（六刀：H1 HangProbe 口径、S1 同步诊断计数、P1 KBProbe、K1-dirty、R-tab、K0-min）。背景读 `perf-mac/sol-log.md`、`perf-mac/实验日志.md`、`docs/plan-mac-perf.md` §4。

重点审：
1. **正确性 / 兜底**：K0-min（详情刷新合并单飞、冷却、beforeWaiting 释放、同值不换、换选择代号拒旧结果）和 K1-dirty（隐藏只记脏、激活补齐）有没有丢更新、永远不刷新、竞态、死锁、主线程同步等待、旧结果覆盖新选择的路径。在底部时新回复跟随、上翻阅读不跳、失败保留旧内容这几条产品行为是否保住。
2. **开关**：每个 `mp.stanch.*` 设 NO 是否真回到原行为；默认值；读取时机。
3. **iOS 影响**：共享文件（SyncEngine / SyncStore / SidebarView / KBProbe / HangProbe / MemoryPalaceApp）在 iOS 下行为和编译是否不变（只读代码判断，不要编译）。
4. **测试有没有自欺**：断言是否真覆盖改动行为；有没有测试只测 mock。

红线：只读。不改任何文件、不 git 写、不 build / test、不碰设备、不联网、不读 `~/Library/Application Support/MemoryPalace/`。

输出：一张表 `# | 严重度(阻断/应修/建议) | 文件:行号 | 问题 | 失败场景 | 建议`，最多 12 条，按严重度排序；没有阻断就明说。中文。直接作为最终回复输出，不写文件。
