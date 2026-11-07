# 任务书：记忆花园 mac 版性能（转菊花）· sol 长线

> 车头：🎩 Claude（Opus 5.5，记忆花园 session），你是实现方。切片做完自己提交接着干，到里程碑或卡住才停下等车头（见末节）。
> 工位：`/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/.claude/worktrees/mac`（分支 `zone/mac`，已同步 master 到 922b9734c）。只在这里干活。

## 起因

粟粟 10-16：mac 版「现在动不动点什么都经常转菊花」。按我们的性能手册优化；点击等界面操作用 cua；SwiftUI 一直卡就可以下沉 AppKit。

## 开工前必读（按顺序，读完再动手）

1. `docs/playbook-perf.md` —— 打法总纲。**尤其 §0、§5 取证纪律、§6 下刀规则、§11 mac 差异**。
2. `perf-mac/BRIEF.md`、`docs/research-mac-perf.md`、`docs/plan-mac-perf.md`、`docs/prompts/2026-10-01-mac-perf/R0-rulings.md` —— 10-01 写的 mac 冲刺调研和计划。**注意：写于 10-01，之后 master 走了 2500+ 个提交，里面的 文件:行号 和结论可能已经过时，S0 就是重核它。**
3. 已拍板（车头按 plan 推荐答）：**N1 = a 止血先上**；**N2 = a 启动不自动回 Code（开关可关回）**；**T5 = b**（现在仓里已有 `MemoryPalace/Utils/TestHostIsolation.swift`，先核它是否已经覆盖 T5，覆盖了就不再做）。**N3（右栏常开哪些工具、CC 在哪个终端跑）没答**：不要等它，第一批不依赖它的先做。

## 切片（一次只做一个，做完就停）

### S0 重核 + 现场证据（只读 + 写文档，不改代码）
- a. 现场证据：`~/Library/Logs/DiagnosticReports/`（含 `Retired/`）和 `/Library/Logs/DiagnosticReports/` 里进程名 `记忆花园` / `MemoryPalace` 的 `.spin` `.hang` `.cpu_resource` `.diskwrites` `.ips`，10-01 之后的全部；加 HangProbe 日志（路径看 `MemoryPalace/Utils/HangProbe.swift`）。**逐份拆主线程栈**，按顶层自有帧归类，出一张表：`类别 | 次数 | 最长时长(注明是下界还是真值) | 代表报告文件名 | 主线程自有帧 文件:行号`。转菊花（spin）是这次的主诉，优先它。
- b. research / plan 里每个候选（A1…A14、K0、K1、S1、H1、P1、R-tab、T5 等）在**当前代码**上还在不在、文件:行号变到哪、有没有被别的提交改掉。
- c. 产出：`docs/research-mac-perf.md` 末尾追加「§7 10-16 重核（sol）」= 上面两张表 + 按现场证据频次重排后的刀单（哪些进止血批、哪些后移、有没有 10-01 没列的新病）。plan §4 刀单若要改，直接改 plan 并在 §9 记一行。
- 不碰她的数据内容：诊断报告里只看栈和元数据；不打开她的 `.store`、聊天、Documents 文件内容。偏好域只许 `defaults read com.susu.MemoryPalace <具体键>` 读面板 / 工具布局相关键名和值（为了补 N3），不 dump 整个域。

### S1…Sk 止血刀（plan §4，按 S0 排好的顺序，一刀一个切片）
- 每刀：一个开关（`mp.stanch.<刀>`，默认开，`defaults write … -bool NO` 关回原行为）+ 最小改动 + 针对这刀行为的回归测试 + `perf-mac/实验日志.md` 一条（假设 → 改动 → 预计降什么 → 验证结果 → 留/退）。
- H1（HangProbe 补时长 + 包身份）先上，后面的刀靠它看前后。
- 验证只能这样跑（工位编译闸见下）：
  `xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/<类名>`
  然后 **grep 到 `Test Suite '<类名>' passed`** 才算真跑了；`@testable import 记忆花园`（module 名不是 MemoryPalace）。iOS 侧编译不了就别管，共享文件里加 `#if os(macOS)` 守好，交给车头。
- 下沉 AppKit 允许，但按 playbook §6 第 5 条：换父视图 / 换宿主时，把「系统替你做的事」（键盘焦点、first responder、滚动、AX、拖拽、菜单、窗口缩放、深色）列成回归清单写进实验日志。

### R1 测量台 + bench 包 → R2 按归因下刀（粟粟 10-16 已批 mac 编译豁免，见硬规矩 1）
止血批做完后接着做 plan §5 R1（测量台、bench 包隔离、基线），再按 plan §6 R2 一刀一刀下。bench 包必须换 bundle id + 存储根改道（plan §3.2），跑在测试楼层，碰不到她的真库和偏好域；跑前用 marker + `find -newer` 实证隔离，实证不过就停。用 cua 点 bench 包复现「点什么都转菊花」。

## 硬规矩（违反任何一条 = 这个切片作废）

1. **编译：只准 mac，不准碰 iOS**（粟粟 10-16 批的豁免）。工位编译闸 `~/.mp-merge-queue/ZONE-BUILD-PAUSE` 对全机开着，**只有你在 mac 工位编 macOS 时**可以在命令前加 `MP_ZONE_PAUSE=/nonexistent` 放行 build（Debug / Release / Release+PERF_BENCH 都行），scheme 只能是 `MemoryPalace` / `MemoryPalaceTests`，destination 只能是 `platform=macOS`。**禁止**：`MemoryPalaceIOS` / Widget / NSE 等 iOS scheme、任何模拟器或真机、`device-lease`（sim / ipad / air / mask）、mobai。共享源码里改了 iOS 也会编到的代码，用 `#if os(macOS)` 守住，iOS 编译留给 Warden 合并时做。仍然走 xcodebuild shim 排队：不准调 `/usr/bin/xcodebuild` / `xcrun xcodebuild`、不准 `-derivedDataPath`；排队、超载等待、冻结 exit 75 都照规矩等，不绕。
2. **不碰她的 app 和数据**：不启动 / 不退出 / 不 cua 操作她正在用的 `/Applications` 里的记忆花园；不读写 `~/Library/Application Support/MemoryPalace/` 下任何东西——**唯一例外（粟粟 10-16 批）：`~/Library/Application Support/MemoryPalace/perf/` 子目录只读**（`hangs.log`、`sample-*.txt`），只看栈和元数据，不改不删不拷进 git，摘录只放 `~/MemoryPalace-docs-media/perf-mac/sol/`；不对生产 hub 发流量；不动 `~/Backups`。跑 mac 单测前先确认 `TestHostIsolation` 生效（单测宿主不碰真库）——确认不了就停下写 BLOCKED。
2a. **隔离实证授权（粟粟 10-16 选 1a）**：marker 只放 `/tmp`；测后 `find <根> -newer <marker>` 扫 plan §3.2.4 的七个根（花园 Application Support / Caches、`~/Documents`、`~/Desktop/cc-rp`、花园 iCloud 目录、`~/.claude`、`~/Library/LaunchAgents`），**只看路径和 mtime，不打开文件内容**；`com.susu.MemoryPalace` 偏好域测前测后在内存里逐 key 比较，只输出「相同 / 哪些键名变了」，**不打印、不落盘任何值**。除此之外硬规矩 2 不变。
2b. **测量窗口（粟粟选 T3=b）**：只在她人在、不用电脑时测。bench 要真跑（含首启隐私弹框，她当面全点「不允许」）之前写 BLOCKED「等粟粟说现在测」并停下；之前能做的静态准备、编译、脚本自测先做完。
3. **测试别刷量**：新增测试代码行数 ≤ 这一刀产品代码改动行数的 2 倍；只测这刀改的行为；**不写测试框架、不写通用 helper 库、不给没改的代码补测试**。上次有个实现方写了五万行测试一点正事没干，粟粟很生气。
4. **证据别刷量**：取证材料 / 日志 / 截图不进 git（可能带她的私人数据），放 `~/MemoryPalace-docs-media/perf-mac/sol/`，md 里写路径；每切片 ≤ 5 个、单个 ≤ 1MB；中间产物放 `/tmp/mp-macperf-sol/`。
5. **卡住就停，不绕**：同一个编译 / 测试失败两次不跑第三次；需要粟粟拍板、需要豁免、需要权限、需要真机 → 立即停，写 BLOCKED。一个切片超过 90 分钟没完也停下汇报。不准为了绕过闸门去补更多验证。
6. **git**：每个切片验证通过后在 `zone/mac` 自己 commit 一次（只 `git add` 这个切片的文件，消息写「perf(mac): <刀> …」，结尾加一行 `Co-Authored-By: GPT-6.1-Sol (omp)`）；不 push、不 merge、不 rebase、不 reset、不 stash、不切分支、不 `commit -a`。
7. 不改 `NOW.md`、`CLAUDE.md`、`tasks/`、`~/.claude`、`settings*.json`、生产脚本（`scripts/xcodebuild-lock.sh`、`zone`、`merge-queue`、`device-lease`）。
8. 回复和文档用中文。

## cua（R1 才用，S0/止血批用不到）
`cua-driver` 在 PATH，守护进程已开、辅助功能和录屏权限都有。`cua-driver list-tools` / `cua-driver describe <tool>` / `cua-driver call <tool> '<json>'`；按 pid 操作，不抢前台。只准操作你自己启动的 bench 包进程。

## 进度日志与什么时候喊车头

每个切片结束在 `perf-mac/sol-log.md` 末尾追加：

```
## S<n> <DONE|BLOCKED|MILESTONE> <yyyy-mm-dd hh:mm>
- 做了什么（一两行）
- 改动文件（git diff --stat 摘要）+ commit 号
- 验证：跑了什么命令、grep 到的 passed 原文一行
- 证据文件
- 没做到 / 坏消息
- BLOCKED / MILESTONE 时：需要谁做什么决定（给推荐答案）
- 下一切片打算做什么
```

**DONE 的切片写完日志直接接着做下一个，不用等车头。** 只有这三种情况写完日志后停下、结束回复等车头：
- **BLOCKED**：卡住（硬规矩 5）。
- **MILESTONE**：止血批全部做完（车头要拿去合并，合并期间这个分支不能再提交）；R1 基线出来（要给粟粟看）。
- 全部做完。
