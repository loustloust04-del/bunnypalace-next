# 对抗审：mac bench 存储改道（AppPaths / BenchIsolation，只读）

工位 `/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/.claude/worktrees/mac`，范围 `git diff 4e02f009b..HEAD`（S9：约 140 文件，所有存储路径改走 `MemoryPalace/Utils/AppPaths.swift`，bench 模式由 `BenchIsolation.swift` 改道 + 越界即崩）。背景读 `docs/research-mac-perf-r1-0.md`、`docs/review-mac-perf-r1-0.md`、`docs/plan-mac-perf.md` §3.2、`perf-mac/sol-log.md` 最后一条。

这是改了大量共享生产代码的切片，最要紧的是**非 bench 时零行为变化**。重点审：
1. **生产路径等价**：非 bench（BenchIsolation 未 requested / 未 active）时，每个被改的调用点解析出的路径、创建目录、枚举参数（如 `includingPropertiesForKeys`、options）、错误处理是否与改前逐字等价；有没有调用点从「可失败 / 可选」变成会 trap / fatalError；iOS 下 `#if` 分支是否原样。逐文件抽查，抓任何一处不等价。
2. **隔离完备**：bench 模式下仍可能写到她真实位置的漏网路径（`NSHomeDirectory`、`getpwuid`、硬编码 `/Users/`、`~` 展开、`URL(fileURLWithPath:)` 拼 home、UserDefaults suite / App Group、钥匙串、iCloud ubiquity、`Process` 子进程继承 env、SwiftTerm / CC 子进程 cwd、LaunchAgents、Sparkle、hub 网络、时间机器）。grep 全仓，不限 diff。
3. **越界检查正确性**：`BenchIsolation.checked` 的 realpath / 符号链接 / `..` / 大小写 / 末端缺失处理；有没有 TOCTOU 或能被绕过的路径形状。
4. **开关与入口**：bench 模式怎么进入（env？bundle id？），生产包有没有任何方式误进 bench 模式；PERF_BENCH 编译条件是否只在测量包。
5. 测试是否真覆盖上面这些（不是只测 helper）。

红线：只读。不改任何文件、不 git 写、不 build / test、不碰设备、不联网、不读 `~/Library/Application Support/MemoryPalace/` 等她的真实数据目录。

输出：一张表 `# | 严重度(阻断/应修/建议) | 文件:行号 | 问题 | 失败场景 | 建议`，最多 15 条，按严重度排序；没有阻断就明说。中文。直接作为最终回复输出，不写文件。
