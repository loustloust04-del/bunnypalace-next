# plan · mac-perf：记忆花园 macOS「打开 Code 必死 / 点了就转菊花」性能冲刺

# S34 候选已好并开始实测；按最新裁决本窗额度账只记不挡，继续 M2–M9/A/A

> 2026-10-01 · 🎩（R0 执行者）· 工位 `zone/mac` · 基 master `5cbd4e2c`
> 简报 [perf-mac/BRIEF.md](../perf-mac/BRIEF.md) · 调研 [research-mac-perf.md](research-mac-perf.md) · 任务书 [R0](prompts/2026-10-01-mac-perf/R0-research.md)
> **v2（R0b）**：按对抗审 [报告](prompts/2026-10-01-mac-perf/R0-review-report.md) + 车头 [裁决](prompts/2026-10-01-mac-perf/R0-rulings.md) 修订（§9）。
> 方法照 iOS [perf-flash](plan-perf-flash.md)：测量台 → 基线 → 一刀一 commit、每刀挂开关、ABBA 配对 → 棘轮 → 每轮交 astra 对抗审 → UI 回归 → 看得见的变化粟粟拍板。
> 粟粟 10-01：「先不真测，等机器闲下来再真正开始，现在只看和写计划」。本文所有「预计」都是推断；R0 没做任何真实测量。

## 0. 要粟粟拍板的（一张表，两组）

### 0.1 现在就要答

| # | 问题 | 选项 | 推荐 |
|---|---|---|---|
| N1 | **止血先上？** 不等测量台，先合一批「行为面几乎为零、证据已够」的小刀（§4 R0.5）：删同步引擎每 5 秒的 4 次全表计数；Debug 包探针减负；Code 详情刷新限流 + 节流按渲染结束计；Code 面板没开时列表只记脏不查；HangProbe 补卡顿时长 / 包身份 / 测试门（用来看前后对比）。全部可用一条 `defaults write` 关回去 | **a** 先上，你日常包装上后照常用，用 HangProbe 日志看前后；**b** 等测量台和基线，按正式流程 ABBA 后再上 | **a**。你现在完全用不了 mac 版；这几刀不改任何看得见的东西，测量台按周算才搭得起来。正式 ABBA 照做，只是排在止血之后补数 |
| N2 | **启动时自动回到 Code 先关掉？** 现在上次停在 Code，下次一启动就直接进 Code 并全量扫描（research §2.2 (d)），等于一开就回到卡死的地方 | **a** 关：启动一律回聊天，Code 要你点一下才进；**b** 保持 | **a**，作为止血开关，Code 修好后再开回来 |
| N3 | **你的日常环境**：右栏常开的是哪几个工具（日志只记到「6 个、当前是终端」）？Claude Code 是在**花园自己的终端**里跑，还是在外部终端（Terminal / iTerm / tmux）里跑？ | 告诉我工具名，或者你截一张右栏 | 决定第一批要不要加终端刀（A13：花园终端的输出解析全在主线程）和隐藏工具刀（A14：比如文件库面板藏着也每 5 秒扫整个文件库） |

### 0.2 开测前再答（R1 开工前）

| # | 问题 | 选项 | 推荐 |
|---|---|---|---|
| T1 | **测量时她的数据怎么隔离** | **a** bench 包换 bundle id（`com.susu.MemoryPalace.perfbench`）+ 全部存储改道到独立根，可与她的 app 共存。**成立条件**：不只 Application Support——`~/Documents`、写死的 iCloud 路径（含时间机器）、她的 CC workdir hook、CC 凭据与额度请求、生产 hub 客户端、钥匙串、家目录 API（含 `getpwuid`）全部收口或在 bench 模式关掉，越界即 trap（§3.2）；**b** 同 bundle id，测前退出她的 app → 整目录克隆备份 → 测 → 逐字节恢复。**b 的风险**：测量进程直接开她真库、写她偏好；bench 若进 `.background` 会跑时间机器、**按 manifest 删她的备份** | **a** |
| T2 | **克隆她的编程会话索引**（`coding-index.sqlite`，988MB，里面有她 CC 会话的正文）做对照，单独授权 | **a** 不克隆，只用「回放增量写老化」的合成夹具；**b** 合成夹具测不出她现场的碎片化时，经你同意克隆一份进隔离根（只让 bench 打开，不读内容、不出本机） | 先 **a**；数字和你的手感对不上再问 **b** |
| T3 | **无人值守测量**：测量要独占前台，屏幕锁了测不了 | **a** 你出门时不锁屏、runner `caffeinate -d`（等于一台登录着全部终端、CC、凭据的 Mac 无人看管开着）；**b** 只在你在场但不用电脑时测（例如你在看手机，告诉我「现在测」） | 你定（安全取舍）。另：bench 包首启会弹一串系统隐私授权框，**需要你当面全部点「不允许」一次**（或代码层根本不碰那些位置） |
| T4 | **编译锁上限与时长预算**：测量块拿全机编译锁（别的工位排队），基线约 5 小时测量窗口、每刀 ABBA 约 1.5 小时（§3.4） | 每块 ≤15 分钟、块间放锁 ≥15 分钟让队列走、每晚 ≤8 块（拿锁合计 ≤2 小时） | 照这个上限；先跟管家打招呼 |
| T5 | **测试宿主改根**：mac 单测现在读写打开你的真库、会在主线程原地迁移 schema、往你的 `sync-state/` 和 `hangs.log` 写。和 bench 隔离是同一份「存储根改道」代码 | **a** 随 R1-0 一起做（影响所有工位的 mac 单测，要管家协调）；**b** 先只做最小版：单测宿主换临时 store + 不起 HangProbe，可随止血一起上 | **b** 先上（随 N1），**a** 随 R1-0 |
| T6 | HangProbe 在 Release 也开 | Release 带 hardened runtime，`/usr/bin/sample` 采自己大概率直接失败（未实证）；心跳和日志开销很小 | R1-0 先实证一次；失败就在 Release 里去掉自动 `sample`，心跳 + 日志留着 |
| T7 | 你日常用的是 **Debug** 包（`-Onone`） | R1 量一次 Debug 额外代价给你看 | 量完再决定要不要给你一个「自用功能全开 + 优化编译」的包 |
| T8 | 改刷新新鲜度的刀（第三批 K3）：Code 面板没开时正文 / 全文索引延后到打开、⌘K 前或空闲 30s | ⌘K / mp-code 搜到最新几条会晚 ≤30s | 先做不改新鲜度的刀，量完再问 |

（原 Q8「点一个什么就转菊花最常是点哪」已答：**在花园里打开 Code 必死**——M 表第一优先、K0 的验收场景。）

## 1. 范围与原则

- 本冲刺只治 macOS（`os(macOS)` 路径 + 共享源码里 mac 吃到的部分）。共享源码的改动同时 build iOS，并按 iOS perf-flash 棘轮复核不退。
- **不改的东西**见 BRIEF。尤其：Code 阅读滚动意图（09-24：上翻不跳、到底才跟）、CC 桥回执、楼层隔离、草稿归属。
- 现场证据（research §1.3）：她停用那一刻是 **Code 详情渲染风暴 + 后台整份重解析**；此外 Code 列表主线程 SQL、同步引擎全表计数、编程会话索引整会话重写。先止血（§4，待 N1），再测量台，再按归因分批。
- 测量和回归一律跑隔离的 bench 包（T1-a）。隔离没实证前，**不启动任何测量进程**。

## 2. 测量定义（`macV1-r1`）

### 2.1 时钟与主线程忙段

- T0：冷启动用 `sysctl KERN_PROC_PID → p_starttime`；其余操作 T0 = 驱动器调用业务函数那一刻（`CACurrentMediaTime`）。M2 / M8 各用 `window.sendEvent` 合成鼠标事件做一次交叉验证，量出被跳过的 NSEvent → hit-test → 动作这一段。
- **主线程忙段 = 双观察者**：`afterWaiting` 用 order `Int.min` 开段、`beforeWaiting` 用 order `Int.max` 收段，挂 `commonModes`。SwiftUI 的 `NSRunLoop.flushObservers`（10:04 现场那 2044 个样本就在这里）和 CA 提交都算进忙段——iOS order 0 单观察者 busy 偏低 15–55%（[plan-launch-perf 勘误](plan-launch-perf.md)，page1-2 `63da34e6` 已改）。mac 从第一版就用双观察者。R1-0 把 `CFRunLoopGetMain()` 的 observer 列表（含 order）打进 JSON 实证顺序。
- 嵌套 runloop（菜单追踪、live resize、模态 sheet）里内层也会触发 after/before：测量场景不开菜单；live resize 只报帧间隔。
- 帧回调：`NSView.displayLink(target:selector:)`（内屏 60Hz；外接屏另记刷新率），>25ms 记 gap25、>50ms 记 hitch，称「回调间隔」不称「掉帧」。
- `ReadyGate`：业务条件**持续成立** + 500ms 安静窗（窗内无 >50ms 双观察者块），`T_ready = max(条件首次成立, 最后一个块结束)`；10s 超时判失败、照样落盘（M9-L1c 的超时本身就是读数）。
- 计数 `PerfCount`（只自增）：`contentViewBody`、`sidebarBody`、`codingReload`、`codingListSQL`（主线程）、`codingDetailParse`、`codingDetailRevision`、`warroomBody`、`mainFetch`、`prefsWrite`、`terminalFeedBytes` 等。
- 资源：每样本 `proc_pid_rusage(RUSAGE_INFO_V4)` 的 CPU、`ri_logical_writes`、`ri_diskio_bytesread/written`、`phys_footprint` 当前值与**峰值**；`thermalState`；窗口 `occlusionState`、`NSApp.isActive`、屏幕与刷新率。
- 结果 `bench-root/perf/run-<runId>.json`（`harnessRevision: "macV1-r1"`、`sourceSHA`、主二进制 LC_UUID、构建配置、有效开关、库与夹具指纹、负载快照、失败断言），原子写后 `exit(0)`。

### 2.2 操作与终点（M1–M8 一律跑 M9 的 L0 档：写入器关）

| # | 驱动（与 UI 同一函数） | 终点条件 | 分层键 |
|---|---|---|---|
| M1 冷启动 | 进程启动 | 主窗 key + visible、输入框在 window 且可成为第一响应者、当前楼层列表首屏 >0 行、草稿态 | 上次停在聊天 / 上次停在 Code（后者 = 重开即死的回归，N2 关闭前后都量） |
| M2 打开对话 | 侧栏行点击闭包抽成函数 | 目标 id、有序路径逐 id 相等、最新气泡已建、异步排版在途 0、输入框可成为第一响应者 | A（~60 条）/ B（~300 条含 >3000 字长文 + 分支）/ C（~2000 条 CC 长会话）× 冷 / 热 / 同 id 重进 |
| M3 切楼层 | 楼层切换函数 | 新楼层列表首屏、聊天区草稿态 | 小 / 大楼层 |
| M4 侧栏 / 面板 | `IPadPanelLayout` 开收函数 | 动画完成 + 内容 frame 连续 3 次回调不变 | 每种面板 × 开 / 收 |
| M5 设置 | 打开设置窗口、逐 tab | 该页根视图 `onAppear` 标记 + 安静窗 | 逐页 |
| M6 流式 | 本地桩 provider 30 tok/s 吐 3000 字，期间注入按键 / 滚动 | 字已在输入框上屏；滚动阶梯走完 | 吐字中 / 吐字后 |
| M7 窗口 | `toggleFullScreen` / `setFrame` 阶梯 | 进出全屏通知 + 布局安静 | 进 / 出 / 缩放 |
| M8 Code | Code 入口函数 / `CodingSessionLibrary.select` | 列表首屏 >0 行 + 详情 `.loaded` + 安静窗 | 小会话 / 100MB 级大会话（静止，不写） |

每个场景结束跑功能断言，不符记 `assertFailures`，任一非空整包判红。

### 2.3 M9：后台负载下的前台卡顿（mac 独有主指标，分档）

公共设施：bench 模式下 `CodingSessionLibrary` 的 roster 用 `home:` 注入指向 `bench-root/home`；host 端 `scripts/perf/mac-cc-writer.py` 维持 3 个 CC 会话 jsonl（~100MB / ~30MB / ~5MB，合成内容），每 3 秒每个追加 2–20KB。每档测 10 分钟窗。

| 档 | 条件 | 对应现场 | 基线必跑 |
|---|---|---|---|
| L0 | 写入器关，Code 关 | 对照 | ✅ |
| L1a | 写入器开，Code 关（监听照跑） | 「Code 没开也卡」 | ✅ |
| L1b | 写入器开，Code 列表开着 | 09-28 03:xx 那批 SQL 卡顿 | ✅ |
| **L1c** | 写入器开，**Code 详情开着那条 100MB 级、正在被写的会话** | **「打开 Code 必死」验收**（10:04 现场）；预期基线会超时，超时本身就是读数 | ✅ |
| L-term | 本机终端 tab 按 CC 节奏吐合成 TUI 输出（整屏重绘 + 转圈） | A13 | ✅ |
| 后台态 | bench 窗口被遮住、非 active，同 L1b；外加「激活 → 第一个事件处理完」的延迟 | 她在别的 app、切回来点第一下就转菊花 | ✅ |
| L-io | runner 按固定剂量注入 IO 压力（后台固定速率读写另一个大文件） | 编译期页缓存被挤掉 | 可选，不进基线必跑 |
| L2 | 桩按 CC 桥协议注入流式帧（~150ms 一帧，目标是**非当前**的大对话），不连 hub | research B1 | 第二批 C1 用 |

**判据（三样，不用「0 次」作判据）**：① 主线程 >250ms 块的**次数率**（次 / 10min，带泊松 95% CI）；② 写盘 MB/h（`ri_logical_writes`）；③ 最长块的分位数（跨窗 p50 / p95）。「>1s = 0」只作目标。另报 CPU%、footprint 峰值、`codingReload` / `codingDetailParse` 次数。
同时在 bench 里并跑 HangProbe 同口径心跳，给她日常包的现场日志一把可比的尺。

## 3. mac 特有约束与方案

### 3.1 负载门（这台 mac 同时是全机编译服务器）

每个块开始前、每个进程前后查一次，任一不满足就等；进程期间破门的样本判红不进统计（计数写进报告）：

| 门 | 判定 | 数据源 |
|---|---|---|
| 编译 | 无人持锁、排号空、无 `xcodebuild` / `swift-frontend` / `XCTRunner` / `xctest` 进程 | `/tmp/mp-xcodebuild.flock.info`、`scripts/lib/mplock`、`pgrep` |
| 负载 | 1 分钟 loadavg < 3、5 分钟 < 4（10 核；10-01 03:18 实际是 182） | `sysctl vm.loadavg` |
| 内存 | `kern.memorystatus_vm_pressure_level == 1`，swapouts 不增 | `sysctl`、`vm_stat` |
| 温度 | `pmset -g therm` 无限速，app 内 `thermalState == .nominal` | — |
| 她不在用 | 按当窗裁决；S23 每次启动前 HID 空闲 ≥60s，低于即收尾，屏幕未锁且显示器亮 | `ioreg -c IOHIDSystem`、`CGSSessionScreenIsLocked` |
| 前台 | bench 窗口 active + visible（「后台态」档除外，那档反过来断言） | app 内 |

- 门过了以后 runner 用同一把内核 flock（`/tmp/mp-xcodebuild.flock`，经 `mplock`）**拿住整块**（T4 上限），块结束放锁。拿锁前给管家发说明。
- 每个样本带负载快照（loadavg、内存压力、swap、thermal、booted 模拟器数、CPU 前 5 名进程、CC 会话 / hub / Docker 数）。L-io 是 runner 自己注入的固定剂量，和负载门（挡外部噪声）不矛盾。

### 3.2 隔离（T1-a）

**收口范围**（research §4.2的历史入口清单）：下列已迁移路径经`AppPaths`，bench下经check解析到根外即拒；**不声称覆盖所有实际IO或所有根外读取**。S10主防线为host默认`deny file-write*`、仅放行bench规范根与具名系统端点的数据写；具体白名单及跨进程门见§9的13条裁决。
1. Application Support（36 处 `applicationSupportDirectory`）、`Caches/MemoryPalace`（编程会话索引）。
2. `~/Documents`（`documentDirectory` 12 处 / 10 文件：文件库本地 floors 根、Feedback、GlobalBackup staging、Vocab、各 Probe、kb-probe）。
3. 写死的 iCloud 路径 `~/Library/Mobile Documents/iCloud~com~susu~MemoryPalace`（FileLibraryStore / BackupStore / BookStore / SyncStore），`iCloudDocumentsRoot()` 不得在 bench 里建目录。
4. 家目录 API：`homeDirectoryForCurrentUser` 15 处、`NSHomeDirectory()` 6 处、`getpwuid` 1 处。
5. 偏好域：换 bundle id。
**bench 模式（`MP_PERF_RUN` / `MP_PERF_SEED` 任一）关掉的副作用**：时间机器（`snapshotIfNeeded` / `pruneOldBackups`）、SyncEngine、CC 桥**客户端连接**与 hub 子进程（读 LaunchAgents plist 的 `HubTokenStore`）、`CCThinkingHookInstaller`（会写她的 `~/Desktop/cc-rp/.claude/settings.json`）、`SubscriptionQuotaStore`（`security` 读她的 CC 凭据 + 请求 `api.anthropic.com`）、钥匙串读取、局域网代理广播（`_mpclaude._tcp`）、Sparkle、通知、菜单栏常驻、全局快捷键；Code 监听只看 `bench-root/home`。

**R1-0 隔离实证（不过不往下走）**：
1. bench 包命令行构建：`xcodebuild -scheme MemoryPalace -configuration Release -destination 'platform=macOS' 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PERF_BENCH' PRODUCT_BUNDLE_IDENTIFIER=com.susu.MemoryPalace.perfbench`（不改 project.yml；首签可能要 `-allowProvisioningUpdates`，失败就停下问），产物 `cp -R` 存档 `build/mac-perf/<sha>-<variant>.app`，记 UUID。
2. 独立小命令行验 `CFFIXED_USER_HOME` 对 `FileManager.urls(for:)` 是否生效（只影响改道代码量；`getpwuid` 等仍要收口）。
3. TCC：首启在她在场时跑一次，所有隐私弹框点「不允许」（T3）；之后代码层保证不碰那些位置。
4. 新隔离仍按任务书2a只读七根路径/mtime、内存比生产偏好，不披露值。S25批准：缺本PID canary时，不论全机日志行数，严格核App内核EPERM、marker inode/size/mtime不变、七根更新零、偏好same；全过GREEN并注「系统日志未记本次拒写」，缺一仍RED，日志loss/不完整不豁免。可见canary的既有路径不变；S25同包已有四证直接复用，不重复扫描/隔离。
5. 测试宿主改根（T5）：同一份 `AppPaths`，`XCTestConfigurationFilePath` 存在时整体改到临时目录；最小版（临时 store + 不起 HangProbe）可随止血先上。

**数据**（T2）：`MP_PERF_SEED=bulk` 造合成聊天库（~2700 对话 / 25 万节点）；编程夹具用两周量级增量写老化。S23 批准冻结模板留在独立合成目录 `TEMPLATES`，只放合成种子，整条线收尾再删；每进程克隆回同一绝对工作根。指纹仍读真实计数、长文长度、`page_count` / `freelist_count` / `dbstat`，不做文件哈希。

**兜底 T1-b**（只在 a 不成立且她同意时）：`osascript` 正常退出并确认进程没了（>30s 不强杀、不用 `pkill -f`）→ 整目录 `cp -c` 克隆备份（Application Support + Caches + `defaults export`）→ 测（bench 不得进入 `.background`）→ 恢复 + `integrity_check` + `defaults import` → 按原包路径 `open` 回去并告诉她。

### 3.3 设备租约与她的屏幕

- runner 整轮 `device-lease acquire mac --why "mac-perf 测量块"`（后台跑，看到 `LEASED mac` 才动），结束 `release`。
- 只控制自有 bench 进程；收尾退出 bench，前台回退交系统处理，不对她的 app 发 `open`、退出或 AX 操作。屏幕/HID 门按车头当窗裁决；未豁免时破门中止，回退效果仍需实测。

### 3.4 时间预算

| 项目 | 估算 |
|---|---|
| R1-7 基线 M1–M8 | 8 × 12 进程 × ~40s ≈ 1h |
| R1-7 基线 M9 | 6 档必跑 × 3 窗 × 10min = 3h |
| R1-6 A/A + R1-8 Debug 对照 | ~1.5h |
| **基线合计** | **~5.5h 测量窗口**（按 T4 每晚 ≤2h 拿锁，约 3 晚） |
| 每刀 ABBA | 相关 M 操作 4 块 × 6 进程 ≈ 30–60min + 相关 M9 档 4 × 10min = 40min → **~1–1.5h / 刀** |

M9 的 >1s 事件很稀，ABBA 每臂 2 × 10 分钟证明不了「0 次」——所以判据用次数率 + CI（§2.3）。

### 3.5 符号与构建存档

HangProbe 启动时若 `perf/builds/<dylib UUID>.syms.gz` 不存在，后台低优先级 `nm -n` 存一份（每包一次，几 MB，留最近 10 个）；`scripts/perf/mac-symbolize.py` 给 `.diag` / `.hang` / hangs 日志的裸地址配符号（R0 用的「同进程采样配绝对地址」法一并收进）。bench 包存档自带符号。

### 3.6 xctrace（诊断用，不作主测）

`xctrace record --template 'Time Profiler' --attach <bench pid> --time-limit 20s`，后台跑 + 看门狗（macOS 没有 `timeout`）；或 `swiftui-expert` 技能的 `record_trace.py --attach`。模板：Time Profiler（含 Hangs）、SwiftUI（Xcode 26，看 body 风暴的因果，用于 A4 / X1 / A3）、Animation Hitches（R1-0 `xctrace list templates` 核 mac 可用性）。OSSignposter 区间 `coldStart` / `openConv` / `panel` / `code` / `soak` 供 `trace-hot.py` 对齐。

## 4. R0.5 止血（10-16 N1=a / N2=a / T5=b 已批）

> **止血批已合，测量台与钩子静态齐；S21 现成包常规隔离 GREEN**。新静默四证分支已按粟粟裁决接入并自测；本轮实际通道活跃且 canary 可见，不冒称静默四证实测。mac 已释放、自有根已清，继续核对真实夹具/运行器，见 §9。


**为什么先上**：N1已批；S0核到的同步诊断计数/KBProbe已分别由S1/P1处理，剩余Code整份详情刷新与主线程SQL不能凭「没有新专属报告」判好。启动计数已删、T5临时根已有，不重复实现；本期收益尚未实测，新manifest启动读仍未处理。
**怎么验**：止血批不做 ABBA（测量台尚未完成实测），用**补了时长 + 包身份**的 HangProbe（H1，必须第一个上）看她日常包的前后对比：
- 前：本期20份保留采样/日志的包身份与归因见research §7.5–§7.6，14份测试注入不混入日常；09-28旧样本只留历史参照，不充当当前统一基线。
- 后：装止血包后她照常用 ≥1 天，**至少打开一次 Code 并停在一条正在跑的 CC 会话上**（K0 验收），按包身份筛出她的进程。
- 对比量：每小时前台使用里 ≥250ms / ≥1s 心跳延迟记录、最长心跳往返、Code开着时的记录、有无新的disk writes报告、`coding-index` WAL / mtime节奏。H1应答取结束点仍不等于系统hang真值，需保留active与调度/App Nap边界；**她手摸「打开Code不死」是第一验收**。
- 正式 ABBA 在测量台立起来后补（第一批 K0 / K1 完整版与止血版一起量）。

**开关**：每刀一个 `mp.stanch.<刀>` 布尔，mac Debug / Release 默认开；H1/S1首次静态访问读，P1/K0/K1/R-tab实例构造读，出问题 `defaults write com.susu.MemoryPalace mp.stanch.<刀> -bool NO` 后重启回原行为。R-tab 的 YES 表示「止血启用、不自动回 Code」，NO 才恢复原行为。已删除的启动诊断计数不为回退而复活。**S7止血批不支持环境入口；S9接线状态与对照门见下段**，不得以设置了env就宣称两臂不同。

S9已接R1环境入口：`MP_PERF_H1`、`MP_PERF_S1`、`MP_PERF_P1`、`MP_PERF_K1_DIRTY`、`MP_PERF_R_TAB`、`MP_PERF_K0_MIN`只接受0/1，隔离安装时写bench域，缺省全开；代码已过两份mac构建/定向回归。**尚未在真实bench核实际配置JSON，不可用于正式对照**。S7原裁决保留在§9，不把本轮静态接线当作真实A/B实证。

| 刀 | 内容 | 证据（research） | 行为面 | 专项验证 |
|---|---|---|---|---|
| **H1（已完成 `0a82a40e7`）** | HangProbe补时长、每行pid/包身份、工具/Code/详情/终端字节率上下文；测试宿主不起探针、不写note，NO回退也不撤安全门；sample阈值500ms | research §7.3为修改前快照；[H1复盘](review-mac-perf-h1.md)为本刀实现/验证 | 仅本地诊断；不称系统hang精确时长 | `HangProbeTests`4测0失败，真实600ms主线程阻塞smoke记录0.68s；未操作她的app |
| **S1（已完成 `d54ec8632`）** | mac默认停同步pump四次纯诊断count；账本编码同值不atomic替换，NO回旧行为 | [S1复盘](review-mac-perf-s1.md)；不把本期侧栏fetch混作这四次count | 业务同步语义不变，不解决所有查询 | `SyncStoreTests`11测0失败，真实导入/导出/空转/变更写盘及NO独立宿主smoke |
| **P1（已完成 `f6420e9a8`）** | mac DEBUG默认关KBProbe，显式开启后台串行写；Sidebar同步print随探针关闭。启动probe-2/probe-4已删，不复活 | [P1复盘](review-mac-perf-p1.md) | Debug专属诊断 | `KBProbeTests`3测0失败，含真实有序写盘/调用线程求值/NO同步回退 |
| **K1-dirty（已完成 S4）** | 默认隐藏Code增量只记dirty，已排队flush再验active/dirty；激活补列表/详情，隐藏期不积攒全部文件路径；NO恢复旧路径 | 本期两份非测试SQL栈；[K1复盘](review-mac-perf-k1-dirty.md) | 隐藏列表不实时、激活补齐；菜单独立查询照常；active/首扫SQL未后台化 | 最终整类16测通过；真实fixture/SQLite删除、NO键回退、隐藏详情追加后激活烟测通过 |
| **R-tab（已完成 S5）** | `mp.stanch.R-tab`默认YES，启动回聊天、不改手动Code存档；NO恢复旧Code恢复，Code隐藏优先。仅恢复属性改策略，ContentView调用不变 | N2已批；[R-tab复盘](review-mac-perf-r-tab.md) | 上次停Code重启后要主动点一次Code；**不解决manifest启动读取** | 独立suite真实持久化/重建，默认/NO/可见性优先级通过；整类10测0失败，GUI留R1 |
| **K0-min（S6完成，S7审查收口）** | 同选择刷新单飞/合并；该代结果落地后的beforeWaiting/Int.max开始冷却≥max(2s,10×解析耗时)。含详情的增量等待刷新链落地/idle再释放，无详情变化沿列表idle；静默、同值不换detail/revision，NO原路径不变 | [K0复盘](review-mac-perf-k0-min.md) / [S7复盘](review-mac-perf-s7.md)；不冒称生产收益 | 含详情列表/大文件/重试更新可更晚；仍整份解析，不保证GPU呈现或最大延迟 | S7整类16测通过：先idle→解析返回→3s长布局，后续间隔2.4422≥2.2374s；跨冷却/快照后写入与pending收尾、无重叠、迟到A/ABA、解析中静默、真实解析错误保旧均过；S6 NO记录保留，本轮未重跑，GUI留R1 |
| **T5-min（已覆盖，不独立再做）** | #035 TestHostIsolation临时持久根/偏好改道与App.main前校验；H1已补测试不起HangProbe、不写note | `TestHostIsolation.swift:66-99`、`project.yml:534-545`；[H1复盘](review-mac-perf-h1.md) | 不引第二套根；不等于bench全隔离 | 本轮三刀mac单测均见临时home/suite，H1安全门回归通过；bench隔离仍待R1实证 |

**新增 L-manifest（R1后首批实证优先项，不混入本批最小止血）**：两份非测试启动采样都堵在 `FileLibraryStore.writeManifest → Data(contentsOf:)`，当前 `FileLibraryStore.swift:978` 与 `MemoryPalaceApp.swift:871` 仍在。已有后台文件枚举不覆盖它。`prepareProfiles` 还承担楼层改名/迁移，不能删比较或随手dispatch造成目录读写竞争；先明确启动准备的就绪/串行契约，再下刀。同步后侧栏/SwiftUI混合工作保留R1测量；旧包桥接path update当前已默认transport后台化，不重复做。止血MILESTONE必须报告manifest新病仍未处理。

交付按 [10-16 sol任务书](prompts/2026-10-16-mac-perf-sol/brief.md)：每刀一切片、一开关、针对行为的回归、实验日志；验证通过仅 add 本刀文件并自行 commit，连续执行到 BLOCKED / MILESTONE。**只准 macOS**：`MP_ZONE_PAUSE=/nonexistent` 的明确豁免仅用于 mac 工位、`MemoryPalace` / `MemoryPalaceTests`、`-destination 'platform=macOS'`，仍走 shim；不碰iOS、模拟器、真机、mobai，不用derivedDataPath。单测须在输出中找到指定类 `Test Suite '<类名>' passed`，未确认TestHostIsolation生效不跑。止血批结束是 MILESTONE，停下交车头合并，合并期间不提交；R1基线出来再停一次。后文旧的三平台构建 / 设备条款不扩大这次授权。

## 5. R1：测量台 + 卡顿记录器 + 基线（不改任何产品行为）

| 步 | 内容 | 验证 |
|---|---|---|
| R1-0 | 隔离实证（§3.2）+ observer 顺序实证 + xctrace 模板清单 + T6（Release 下 `sample` 能否采自己） | marker + `find -newer` 空、defaults 不变、网络侧干净；observer 列表进 JSON |
| R1-1 | `PerfHarnessMac.swift`（`#if (PERF_BENCH \|\| DEBUG) && os(macOS)`）：`MP_PERF_RUN=1`才启用完整统计/驱动。独立UI的`MP_PERF_UI=1`限隔离seed角色，只记录真实忙段并启用本地流式provider，不启动测量驱动/统计、不影响普通产品或iOS | S39 mac Debug/Release+PERF、普通Release符号剔除及两类19项定向单测已过；真实UI待解锁，iOS由Warden集成验 |
| R1-2 | 钩子（每处 1–3 行）：App.init、侧栏行点击函数化、面板、Code 入口 / select / reload / 详情解析 / revision、楼层、设置 onAppear、Warroom body、UserDefaults 写、终端喂入字节 | 只自增、不读模型 |
| R1-3 | 合成聊天种子 + 编程会话夹具（15 轮增量索引写入，覆盖 14 个合成日）+ 运行器 `_load` 内的 CC 写入/TUI 输出 + 同路径模板冻结/恢复 | 五档有效；S40精确PTY例外、唯一自测及新host真实隔离GREEN，App真实终端持续收字节。两次终端全长窗末尾失焦作废，三个有效窗仍缺，正做只读焦点诊断；不改断言或分母 |
| R1-4 | 测量运行器：负载门、编译锁、mac 租约、克隆、看门狗、manifest/ledger；五分钟静默等解锁亮屏，批次内防睡眠，`--verify-m1-first` 单进程探针通过后才续场景；仍用 `sandbox-exec`，统计支持 `macV1` + M9 泊松 CI | 只烟测新增边界/实际输出，不重跑已过整套自测；只操作自有 PID，探针不进正式分母 |
| R1-5 | H1上补离线归档索引/`mac-symbolize.py`、`mac-hangs-report.py`，按日期/逐行包身份/上下文/主线程自有帧汇总；设置页后台读取有限尾部再分组。**进程内thread_suspend采样器仍不进R1** | S39真实atos/未知镜像、保留样本互斥计数及新日志语义已验；09-28计数可复现、中位数与旧稿不符且14份原栈已轮换，见research §7.8。mac两配置/nm/相关单测已过；真实设置界面尚未跑 |
| R1-6 | A/A：同一 bench 包两组各 12 进程 + M9 两档各 3 窗 | S35 已收齐220/220，204正式/16预热；采集完整、性能RED，噪声带与超时原分母见 [基线](../perf-mac/基线.md) |
| R1-7 | 基线：M1–M8 每组 ≥12 进程；M9 六档各 3 窗；主指标各录一次 Time Profiler，A3 / A4 / X1 录 SwiftUI 模板 | 五档各3完整窗、A/A齐；四项Time Profiler有前台代表性缺口。S48原内核exec后附着、正常停录时目标仍活，SwiftUI仍真实零行，按车头限时记缺口；继续后先L-term三窗，见[基线](../perf-mac/基线.md) |
| R1-8 | Debug 代价对照（T7）：同 SHA Debug 包（同样隔离）跑 M2 / M4 / M9-L1b | S43隔离GREEN；S47实物只有状态栏窗、主线程空闲，无普通主窗或T7有效数。按车头限时记缺口，不再深挖，不改原生十秒 |
| R1-9 | mac UI 回归立起来（§7），**和性能测量分开跑** | S45新包隔离GREEN、UI类定向编译过，真实XCTest卡自动化授权0/10；车头已定系统安全设置+认证，UI挂起等粟粟决定，不改不绕，其他R1继续。UI包不替换测量包/同源Debug |
| R1-A | astra 审本 plan v2；再审测量台 + 基线 | 裁决记 §9 |

## 6. R2 起：按归因下刀

每刀：假设（改什么 / 哪个计数降 / 预计省多少）→ 最小改动 → 挂开关 → 棘轮 + 护栏 → 同包开关 A/B 只作方向筛选 → **两包 ABBA**（A1 B1 B2 A2，每块克隆重置 + 预热 1 次丢弃 + 6 进程；相关 M9 档每块 1 窗）→ 没变好就退 → `perf-mac/实验日志.md` 一条 → 一刀一 commit。止血版已上的刀，完整版 ABBA 的 A 臂用「止血后」的包。

### 6.1 第一批：「打开 Code 必死」+ 后台抢主线程（不改看得见的东西）

| 序 | 刀 | 内容 | 证据 | 预期 | 开关 | 专项回归 |
|---|---|---|---|---|---|---|
| 1 | **S1** | 止血版即完整版（§4）；补 ABBA 数字 | §2.4 | M9-L1a/L1b CPU、读盘降；主线程 SQL 卡顿次数率降（IO 竞争减少，待证） | 无 | 同 §4 |
| 1 | **K0** | Code 详情增量（完整版）：① 详情按 seq **只追加新尾巴**——行身份稳定、`CodingMessageRow` Equatable 化（闭包收进稳定对象）、不再每轮 `filter` + `Array(enumerated())` 全量重建；② transcript **只解析追加的字节**（K4 对详情路径提前：按文件记字节偏移 + 最后一条未完结行；压缩 / 改写 / 截断时退回整份）；③ revision 只在尾部真变时加，滚到底只在「在底部」时做（保持 09-24 意图规则） | §2.2 | **M9-L1c 从超时变成有读数**，>250ms 次数率降一个数量级；M8 大会话 ready 降 | `MP_PERF_CODE_DETAIL_INC` | Code 回归全套（§4 K0-min 那几条）+ 压缩 / 改写 / 文件截断 / 侧链的退回整份；MC1 / MC-live（§7） |
| 1 | **K1** | Code 列表 SQL 出主线程：**覆盖全部主线程同步 SQL 入口**（`activate` :140-144、`applyProgress → reloadProjects` :429-436、扫描完成 `reload` + `reloadDetail` :247-253、`toggleRoot` :567、`loadPage / fetchPage` :603-633、`openSession / reveal` :386-426、`recentlyActive` :396-401、`loadDetail` 的 `reader.session(key:)` :675），统一换后台 actor 上的 **`readOnly: true` 长连接**；主线程只拿结果按「同值不赋」落地；**不照抄 `search()`**（它每次读写打开、跑迁移、抢写锁）；不再调 `cache_size`（WAL 下无效） | §2.3 | M9-L1b 主线程 SQL 块 → ~0；M8 不退 | `MP_PERF_CODE_ASYNC` | 新会话 / 更新时间变了照样刷新；⌘K 命中能展开、翻页、滚到；收藏 / 改名 / 归档 / 展开根；菜单栏快看 |
| 2 | **K2** | 编程会话索引差异写：仍整份解析，按 `(seq, text 哈希)` 和库里比，只删 / 插差异 messages + FTS；seq 错位退回整写；显式 `journal_size_limit`、`wal_autocheckpoint` | §2.1 | **写盘降一个数量级以上（目标 <90MB/h，消 disk writes 报告）**；CPU 不作预期（大头在解析） | `MP_PERF_CODE_DIFFWRITE` | `CodingSessionIndexSchemaTests` / `CodingSessionSearchTests` + 新增：追加 N 条只写 N 行、改写退回整写、FTS 命中与整写一致 |
| 2 | **A13** | 本机终端：给 SwiftTerm `LocalProcess` 传后台队列，主线程按帧合并 feed（**待 N3 + R1 证实量级再定是否进第一批**） | §3.1 A13 | M9-L-term 主线程忙降 | `MP_PERF_TERM_BGQUEUE` | 终端输入回显、复制粘贴、窗口缩放重排、CC TUI 正常、`exit` 收尾 |
| 2 | **P1** | 止血版即完整版 | §2.6 | 只在 R1-8 Debug 对照里看得到 | 无 | 无 |

### 6.2 第二批：前台操作本身（按基线大头定序，第一批结束时重排）

| 刀 | 内容 | 对应操作 | 子项 |
|---|---|---|---|
| **X1+A4** | Code 侧栏：`sessionRow` 从父 body 函数拆成独立 Equatable 子视图、嵌套 `ForEach + if` 扁平化——先用 SwiftUI 模板在 M9-L1b 确认 39.8s / 两次 cpu_resource 的放置风暴是不是它 | M8 / M9-L1b | [ ] trace 定位 [ ] 拆行视图 [ ] ABBA [ ] 侧栏回归 |
| **A14a** | 文件库面板 5 秒轮询：藏着时停、出来时补一次；枚举挪后台 + 跳过 `books` | M9 全档 | [ ] `isFrontmostTool` 门 [ ] 后台枚举 [ ] 外部改动提示回归 |
| **A14b–g** | 隐藏工具其余周期活（日历 `@Query`、书架 5 秒 fetch、推特 20 秒、侧栏 `.syncDidImport`、`MacScrollbars` 整树遍历、菜单栏快看）——**先逐条核**（现在是「中，待核」），按 N3 她现场开着的工具定序 | M9 | [ ] 逐条核 [ ] 按现场排序 [ ] 每条一刀 |
| **W1** | Warroom：`WarroomTask` 稳定 id / 内容哈希代替逐字段比较、看板 JSON 只解码一次、`lastRefresh` 不进 body 依赖 | M4 / M9 | [ ] 改 [ ] ABBA [ ] 面板回归（派单回执、分组、颜色） |
| **T1** | `Theme.x` 结果缓存（主题 / 深浅色 / 纯色背景 / 壁纸透明开关变化时重算一次）；**iOS / mac 共享**，同时跑 iOS 棘轮 | 全局单价 | [ ] 改 [ ] mac ABBA [ ] iOS 棘轮 [ ] 换主题 / 深浅色 / 壁纸回归 |
| **C1** | CC 流式入站：`ccMessageId → 节点` 映射或后台 context 找，不再逐帧物化整条对话；CC 流式中间帧按 transient（不进 LRU、不逐帧 `save()`，最终帧照常落库） | M6、M9-L2 | [ ] 映射 [ ] transient [ ] ABBA [ ] CC 桥回执 / 尾部跟随回归 |
| **O1** | 打开对话：主线程按显示路径 id 取节点，不再整条对话全量 fetch；`isLoading` 不拆列表 | M2、⌘K 点开 | [ ] 改 [ ] ABBA（A/B/C × 冷热）[ ] 草稿→真对话、A→B→A 快点、搜索跳分支回归 |
| **O2** | 附件气泡：读盘挪后台 + 缓存、ImageIO 降采样、iCloud 占位文件不在主线程触发下载 | M2 / M6（带图 fixture） | [ ] 改 [ ] ABBA [ ] 图片 / 文件 / iCloud 占位回归 |
| **O3** | 气泡行 Equatable 化 / 闭包收进稳定对象、`regexScripts` 解码缓存 | M2 / M6 | [ ] 改 [ ] ABBA [ ] 气泡交互回归（菜单、划线、编辑） |
| **I1** | mac 输入框每键 `save()` 合并（保留逐键保存、退出 / 失活保存契约） | M6 每键延迟 | [ ] 改 [ ] 中文输入法组字实测 [ ] 退出 / 切对话不丢字回归 |
| **其余** | A3 收尾后的 ContentView 读 `detail` 拆开、A7 停靠 / 浮窗整树重建、B8 宽度变化全段重排、B9 切楼层整树重建、B10 备份页读 iCloud manifest、A12 切回 app 的后台重活 | M3–M5、M7 | 按基线逐条决定 |

### 6.3 第三批：改新鲜度 / 结构（需粟粟拍板）

| 刀 | 内容 | 代价 |
|---|---|---|
| K3（T8） | 监听分级：面板没开时只更新 sessions 元数据行，正文 / FTS 推迟 | ⌘K / mp-code 晚 ≤30s |
| K4 | 索引路径的尾部增量解析（详情路径已在 K0 提前） | 消息跨行合并 / 标题 / kind 依赖全文，风险中 |
| L1 | 换 schema 首启迁移 / 索引回补挪出主线程 | 主要影响单测与工位包 |

### 6.4 棘轮

只把两次改动都同向的计数进 `perf-mac/bench/ratchet.json`（主线程 `codingListSQL` 次数、`codingDetailParse` / `codingDetailRevision` 每分钟、`warroomBody`、M9 各档 >250ms 次数率上限、写盘 MB/h 上限）；新包任一计数中位数升，或 p75 / 次数率升超噪声带一半即红。

## 7. mac UI 回归：现状与补法

**现状（S45实测及车头裁决）**：独立mac target/host已实际启动自持AUT和XCTest；Cua客户端Home分开、AUT/测试Home仍隔离，错误CLI参数已删。测试器卡系统自动化授权、业务0/10；车头已定这是系统安全设置+认证，UI挂起等粟粟决定，不改权限/TCC、不采用无认证模式。原iOS脚本/target不改，其余R1按Debug→SwiftUI→终端继续。

**补法（R1-9）**：
1. 新 target `MacRegressionUITests`（`bundle.ui-testing`，仅macOS），挂在`MemoryPalaceTests` scheme、无默认AUT。host只启动精确归档的bench PID，测试先核PID/绝对bundle路径/唯一进程再附着；禁止Xcode自动启动产品App。首跑若需runner授权，记「有弹框」、不代点。**UI回归和性能测量分开运行**，UI专用观察快照不入基线。
2. 用例（按场景等就绪、不 sleep，失败分 setup / environment / product / assertion）：
   - MK1 冷启动后点输入框能打字（打一个字再删，不发送）
   - MO1 侧栏点对话 A → 标题对、最新消息可见、输入框可点
   - MP1 左侧栏 / 右栏工具面板 / Dock 开收 → 正文 frame 符合 09-24 规则
   - **MC1** 进 Code → 选会话 → 上翻一屏 → 夹具写入新回复 → 滚动位置不跳；滚到底 → 新回复跟随
   - **MC-restart** 「上次停在 Code，重启」→ 启动后 N 秒内主线程无 >1s 块
   - **MC-live** 「Code 详情开着，写入器持续写 3 分钟」→ 主线程不被饿死（期间点侧栏能响应）
   - MS1 设置逐 tab
   - MF1 进 / 出全屏；MF2 切楼层
   - MT1 流式（桩 provider）中滚动 / 打字，结束后最后一段完整上屏
3. 视觉：`shoot-*.sh` 加 `MP_DEBUG_APP` 指 bench 包；看得见的改动仍交她目视。
4. `scripts/ui/mac-ui-regress.sh`：复用负载门/mac租约/冻结模板恢复/原内核白名单，真实Code写入器与自持重启控制；裁剪冻结xctestrun只留无AUT的mac UI target。结果留自有临时批次，不把xcresult/界面内容写进git；十项缺项/跳过/工具失败均不能全绿。

## 8. 审查节奏（astra）

| 轮 | 审什么 | 交付 |
|---|---|---|
| R0 | 本 plan v1 + research + BRIEF（Opus 代 astra，codex 额度到 10-03） | `docs/prompts/2026-10-01-mac-perf/R0-review-report.md` |
| R0.5 | 止血批 diff + 她日常包前后 HangProbe 对比 | `reports/r05-stanch-review.md` |
| R1 | plan v2；测量台 + A/A + 基线 | `reports/r1-*.md` |
| R2+ | 每批刀 diff + ABBA | `reports/rN-*.md` |

## 9. 裁决记录

- R0 对抗审 19 条逐条裁决见 [R0-rulings.md](prompts/2026-10-01-mac-perf/R0-rulings.md)（全收，#7 降级、#9 精简、#14 转为 N1 拍板）；事实更正的核对结果见 [research §6](research-mac-perf.md)。
- 10-16 S0（sol，最初源码基点 `67fc88434`）：N1=a / N2=a / T5=b 已批；P1 启动计数已修、只留 KBProbe，T5 临时根已有、仅将不起HangProbe并入H1；R-tab 统一为止血开关默认开。A3滚动意图、A14a后台枚举、A14c后台盘读、W1文本解码等已有缓解不得重复实现。本期没有可归因spin，HangProbe又在硬规矩2禁读根，**按本期频次重排仍BLOCKED**，§4暂保留原序。验证 / 提交 / 连续执行以10-16任务书v2及车头补充为准，仅mac豁免、不碰iOS；详见 research §7。
- 10-16 16:18车头追加裁决：提交S0静态部分，现场日志授权单独等；直接做S1=H1，随后按§4暂定序连续执行，不因S0a缺口空等。只读禁区不变；日志获准后再补归因与排序。
- 10-16 H1完成：`mp.stanch.H1`默认开，包身份复用ConnectRuler内存LC_UUID，测试门不随回退解除；真实单次心跳smoke主线程阻塞600ms、记录0.68s，最终`HangProbeTests`4测0失败（16:39:52）。真实smoke曾抓到新终端速率初始化下溢，修正并保留回归；没有性能收益/Release采样结论。[复盘](review-mac-perf-h1.md)。
- 10-16 S1（sol S2）完成：仅mac默认停四次诊断全表count、账本同值不atomic替换；整类11测0失败（16:46:45），独立宿主NO回退smoke通过。业务查询/同步语义未改，无卡顿或ABBA收益声明。[复盘](review-mac-perf-s1.md)。
- 10-16 P1（sol S3）完成：仅mac默认关KBProbe，显式开启走后台串行，表达式仍在调用线程求值；3测含默认关闭/真实写盘/NO同步回退通过（16:55:47）。车头已转达粟粟的perf子目录只读授权：本刀提交后先补S0a逐份主线程归因并重排，H1/S1不返工，其余数据禁读不变。[复盘](review-mac-perf-p1.md)。
- 10-16 17:09 S0a（sol）完成：粟粟perf只读例外下逐份拆20份采样（19主线程树、1空图；14份测试注入），非测试manifest启动读2份、Code增量主线程SQL2份；日志1101条hang下界不是独立次数，203个采样引用仅留20。§4改K1-dirty→R-tab→K0-min，H1/S1/P1不返工；新L-manifest列R1后首批优先，不能以取消manifest比较或制造启动竞态止血。原件不改删、摘录3份均外部且<1MB；无app操作/测试/构建，见research §7.5–§7.7。
- 10-16 S4 K1-dirty完成：默认隐藏增量只记dirty，空changedPaths的删除事件也保留脏；只留当前详情命中路径，激活补齐。修改前9→8复现、最终整类16测0失败（17:24:30），NO实际键与隐藏追加后激活2项smoke通过；原有临时库unlink警告仍在、不隐去。产品21新增/测试23新增，下一刀R-tab。[复盘](review-mac-perf-k1-dirty.md)。
- 10-16 S5 R-tab完成：启动默认chats，保留手动Code存档与标签；NO恢复旧Code恢复、隐藏Code仍优先。独立suite真实持久化/重建smoke及整类10测0失败（17:28:31）；仅功能新增5行、测试新增8行，无GUI/ABBA声明。下一刀K0-min。[复盘](review-mac-perf-r-tab.md)。
- 10-16 S6 K0-min及止血MILESTONE：四项齐，整类18测0失败（17:46:27）、真实偏好键NO两项smoke通过（17:48:53）；受控解析间隔2.3227≥2.3064s、idle后2.0049s，同值revision不动。产品102新增/永久测试114新增；首轮夹具id缺失已修，不改解析器。六刀完工，停交车头合并，R1未启动；新增manifest启动读、active SQL、真实GUI/日常卡顿率仍待后续。[复盘](review-mac-perf-k0-min.md)。

### 10-16 S7 · 止血审查裁决（车头批准后直接实施）

来源：[astra报告](prompts/2026-10-16-mac-perf-sol/R-stanch-astra-report.md)，静态审无阻断；S7只修下表，不启动R1、不扩展iOS。

| # | 裁决 | 本刀实施与验收 |
|---|---|---|
| 1 | 收 | 详情冷却从该代结果落地后的`beforeWaiting / Int.max`起算；增量含详情时等该刷新落地/idle后释放，无详情变化仍走列表idle。覆盖先空闲、后解析完成、再长布局。 |
| 2 | 收 | 专用adapter仍真实解析fixture，用快照闸制造A已开始→选B→A迟到；补A→B→A，核正文、错误、revision不被旧代改写。 |
| 3 | 收 | 写入分布到冷却期及解析取快照后，等pending消费与调度收尾；核最终精确文本、无重叠解析、布局后的完整冷却。 |
| 4 | 收 | 解析进行中检查loaded/指示器；保留非空真实文件引用，以临时fixture权限制造真实解析抛错，核保旧与错误可见。 |
| 5 | 收文档 | §4明确`MP_PERF_<刀>`未接线，R1再接；本批不得用该env做对照。 |

- [x] S7：四类异步回归完成，整类16测0失败，`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 18:13:39.434.`且`** TEST SUCCEEDED **`；修前1测3断言失败已复现。产品+45/-13共58行改动，测试新增110≤2×58=116（测试-88，合并弱时序用例18→16测）；未建框架。实验/复盘/工位状态及本切片单次提交齐，MILESTONE停交车头；[S7复盘](review-mac-perf-s7.md)。

### 10-16 R1开工 · S8授权门

车头已给R1 go，队列`#00488 / zone/mac @ 0438097b`在合；合完通知前只改工作区，不commit/暂存，不把旧§4停点当作禁止R1静态准备。S8独立Foundation CLI八项改道通过、getpwuid仍根外；完整bench隔离未证明，未启动app/测量。§3.2.4生产根marker/元数据遍历/完整偏好逐key比较与任务书禁读写冲突，按硬规矩5 **BLOCKED**，请车头确认最小只读核验授权及T3在场测量窗口；不向生产根写marker、不dump偏好、不绕门。详见[R1-0前置核验](research-mac-perf-r1-0.md)。

- 后续裁决：粟粟批1a与T3=b，按任务书2a/2b，原元数据/偏好核验授权冲突已解；marker仅/tmp，七根只路径/mtime，偏好仅内存比较且不披露值。车头确认#00488合master `8dfdae7b`并同步本工位，恢复切片提交。S9先完成静态准备/mac编译/脚本自测，**bench启动前BLOCKED「等粟粟说现在测」**，不把1a当作已给测量窗口。

### 10-16 S9 · R1-0核心隔离自测BLOCKED

- S8文档已补提交`4e02f009b`；S9只留工作区，不暂存/提交。host脚本12项合成自测GREEN，xcodegen成功，不是整包build或app隔离通过。
- 同一核心自测运行两次均exit 133：先发现Foundation原生临时目录不随TMPDIR改道，工作区增加AppPaths显式临时根并迁移部分入口；再发现根内符号链接指向根外、末端文件不存在时`Configuration.check`错误接受。保留失败断言，硬规矩5不跑第三次、不继续编包。
- 需车头裁决修复/复验；推荐先修缺失末端路径的祖先链接解析，获许可后复验，不靠换测试名重置次数。隔离不过不进入R1-1；即使修复/编译通过，仍须BLOCKED「等粟粟说现在测」，不提前拿T3窗口。
- [S9事实、未完成项与证据](research-mac-perf-r1-0.md#s9--10-16-1909-blocked核心自测两次失败)。未启动app、未执行生产根find/偏好读取，无类passed、bench包/UUID、observer实证或基线。



### 10-16 S9 · 车头解除阻断后的复验裁决

| 项 | 车头裁决 | 本轮边界 |
|---|---|---|
| ① 路径边界 | 取最深已存在祖先的realpath，再拼回缺失段；根外拒绝 | 保留根外祖先软链/末端缺失反例，新增根内软链真实写入；代码改动后新轮允许复验，再失败两次仍停 |
| ② 临时入口 | 收尾所有mac可达入口 | 共享入口经AppPaths；纯iOS/非mac分支原调用不动，非bench返回原生值 |
| ③ 静态验证 | mac Debug、Release+PERF_BENCH两份build及相关mac类定向单测；五项非bench逐字对照 | 仅批准scheme与platform=macOS、shim排队，不启动bench；对照home/appSupport/caches/documents/temporary的absoluteString |
| ④ 新启动门 | 这一大片改道先由车头派astra审 | ①–③完成后提交，**BLOCKED「等车头审查」**；审过才进入「等粟粟说现在测」，不可跳过任何一门 |

根边界核心CLI已观测`MAC_ISOLATION_CORE_SELF_TEST PASS rejected=8 native_temporary_redirected=false`，根内软链经check后真实写入并读回目标字节。构建/类测试的最终结果见本轮sol-log，不把命令已排队当通过。已识别既有StorageMaintenance清理测试会扫用户共享tmp，改为仅测自有目录内的既有临时件清理步骤，不调用全局URLCache/WebKit清理；正常清理入口仍组合原步骤。

### 10-16 S9 · 静态验收与当前停点

- [x] 最深已存在祖先realpath与缺失段处理；根外反例、根内软链真实写入/读回通过
- [x] mac可达临时入口收尾，保留非bench/iOS原生值；五项非benchabsoluteString逐字对照通过
- [x] 最终Debug、Release+PERF_BENCH两个mac build通过；候选独立bundle/UUID及preflight只读核验通过
- [x] 本次相关22类184测全部通过并逐类grep passed；MCP误封已复现/修正，不改原断言，缓存清理测试只处理自有目录
- [x] 研究、实验日志、复盘、roadmap索引及工位状态收口；证据仅外部2份，均<1MB
- [x] S9审查已完成（5阻断）；按车头S10的13条裁决收口，当前停点见下节，不再等全量复审
- [ ] 真实bench隔离、七根/偏好/网络、observer/T6、cua与基线；不能把静态结果勾成R1-0已过

最终命令/包身份/失败轨迹及预算见[研究收口](research-mac-perf-r1-0.md#s9复验收口--10-16-2007--blocked等车头审查) / [复盘](review-mac-perf-r1-0.md)。先前19:09的两次失败停点已由车头解除，保留为历史，不掩盖坏消息。

### 10-16 S10 · 隔离审查13条裁决（车头批准直接落实）

裁决源：[astra审查](prompts/2026-10-16-mac-perf-sol/R-isolation-astra-report.md) / [车头裁决](prompts/2026-10-16-mac-perf-sol/R-isolation-rulings.md)，基点`64f5e017f`。主防线改为内核写白名单；不新增通用沙盒、openat边界或active-bench消费者测试宿主。

| # | 裁决落地 | 验收范围 / 明确限制 |
|---|---|---|
| 1 | `Configuration.canonicalPath`拒绝缺失后缀的`.`/`..`，已存在祖先仍用POSIX realpath | 核心CLI加缺失段+点段+祖先软链组合；保留根内软链真实落盘 |
| 2 | `CodingSessionResume.handoffError`统一拦外部终端、桌面深链、AppleScript交接 | 不靠剥掉环境变量当隔离；正常调用路径不变 |
| 3 | host默认`deny file-write*`，只允许bench根；本机终端/`run_command`仅固定`/usr/bin/printf`合成输出 | 不解析shell文本、不接受自选程序/cwd/env；不是后续L-term负载器 |
| 4 | 不改SwiftTerm，终端只接受控合成程序 | shared tmp的写/unlink由内核挡；不承诺拒绝所有根外读 |
| 5 | 默认系统回收闭包拒绝bench；导出写由内核兜底 | 驱动器只点场景控件，不点导出/删除/在终端继续 |
| 6 | 优先恢复三个探针的`.first?`/guard-first可选降级；只有成功URL才check | iOS有效分支与`4e02f009b`逐字相同；补空查询返回nil |
| 7 | Cursor从已校验bench根内解slug，根外slug不探祖先 | 保留真实枚举和解析；用合成项目/真实夹具回归 |
| 8 | 安装、配置、探针和profile准备只编入`DEBUG || PERF_BENCH` | 正式Release不读bench变量；无GUI CLI用有值的RUN/SEED核验忽略 |
| 9 | 系统通知schedule/cancel走既有`.notifications`门 | 本地计时状态不变；cancel先失效本地代号，后决定是否交系统 |
| 10 | 显式数据库路径写由内核白名单兜底 | 只记边界，不补数据库消费者用例，不声称只读路径均拒绝 |
| 11 | MiniBrowser加载/导航及LinkPreview真正网络发起处bench离线 | WebKit/launchd代理不在host进程树网络审计内；不另造验证框架 |
| 12 | 新永久用例限#1、#6、#7及host内核白名单自测 | 不给未改代码补测试、不建消费者宿主；仍守测试两倍上限 |
| 13 | URL目录枚举原地替换为checked返回的规范URL | TOCTOU不升级为能力边界，由内核写规则兜底并记录局限 |

内核系统写例外逐条列明：**仅`file-write-data`到现存`/dev/null`**，供标准输入/输出丢弃；不允许创建/删除/元数据修改，不放开`/tmp`、原生共享temporaryDirectory或用户cache根。没有真实bench进程证据，不预猜系统临时/缓存豁免；真启动遇缺项就停，不扩大白名单绕过。

- [x] 三个探针iOS有效源码与`4e02f009b`逐字对照；没有编译/运行iOS。
- [x] 核心CLI：10项拒绝及根内软链真实写入/读回通过；host18项合成自测GREEN。
- [x] 无GUI正式Release CLI：RUN/SEED存在仍inactive，五项FileManager路径absoluteString原值相同。
- [x] 最终Debug、Release+PERF_BENCH两份mac build成功；14类230测0失败，全部类passed及TEST SUCCEEDED已grep（20:56:28）；测试宿主home/suite/keychain独立。
- [x] 收口外部证据、复盘/索引/工位状态；仅本切片文件随S10提交，**BLOCKED「等粟粟说现在测」**。产品Swift+250/-41，测试保守增量121≤2×250（整个Python脚本改动也算测试）。
- [ ] 真实bench、七根/偏好/网络/observer/T6、cua和基线仍未执行；本次不是R1 MILESTONE。

### 10-16 S11 · T3已授权，真实R1-0被租约前置闸阻断

车头传达粟粟「现在测」，她在场且不用电脑；本轮于21:32先按§3.3申请`device-lease acquire mac`，实际返回exit 75：「工位暂停模拟器 / 设备装包……mac 不能租 mac」。没有取得租约，按硬规矩5立即停；**没有启动bench/生产app、没有首启弹框，也没有运行生产七根find、偏好读取/比较或网络实证**，不能记DONE或把S10静态结果当本轮通过。

只做阻断记录，不重试、不把`MP_ZONE_PAUSE`编译豁免套给租约、不改暂停文件/生产脚本、不转Warden代做或改跑sim/iOS。需粟粟明确处理本次mac运行租约权限；推荐仅放行本轮T3的mac租约、其他限制不变。许可后再从真实R1-0开始，不过即停；首启弹框才打印「等粟粟点不允许」并等待本人处理，不代点。R1-1静态准备不占这个窗口。

外部证据仅`~/MemoryPalace-docs-media/perf-mac/sol/S11-R1-0-lease-blocked.txt`，不入git；本轮无产品/测试改动，无build/test/passed或R1 MILESTONE。

### 10-16 S12 · 租约专项豁免后的真实R1-0 RED

车头明确mac豁免也含bench/cua及本次租约，T3仍有效。按指定唯一入口`MP_ZONE_PAUSE=/nonexistent device-lease acquire mac --why "sol T3 R1-0 隔离核验（粟粟已说现在测）"`取得`LEASED mac`，S11租约阻断解除；不扩到其他设备。

21:37调用原host的真实`run --seed isolation --window-approved --observe-seconds 30 --timeout 180`，静态包预检通过，候选启动请求PID`63047`，独立根`/private/tmp/mp-macperf-sol/bench-s12-t3-3ea7d34d883a`，写白名单不变。最终host exit70/status RED：`app_exit=78`、`APP_EXIT`和`ATTESTATION`，配置/落点证明缺失，30秒观察实际完成0秒；不能确认App.main/完整GUI首启成功或隔离通过。

偏好内存逐key结果same/变化键0；七根均完成元数据检查（6存在且更新路径0，Caches根原本不存在），不打开内容。5次自有树socket采样没有网络失败分类，但不构成完整观察窗/网络生命周期通过。按PID的cua `list_windows`返回daemon不在/exit1，未取得窗口或截图，无法确认首启弹框及人工拒绝；没有代点。

按「不过即停」没有重跑或扩白名单。host结束自有树清理后立即`device-lease release mac`，原文「已释放 mac」；未推进R1-1，未占窗口做静态准备，无DONE/MILESTONE。临时PID通知入口已删，产品/测试未改。

**BLOCKED，等车头裁决下一切片**：退出78原因未知（原host丢弃stderr），不能猜成某个权限问题。推荐先恢复cua、将bench自身失败原因有界落到bench根，保持写白名单不变；获准且T3有效后重做真实R1-0。证据仅外部`S12-R1-0-report.json`（3304 bytes）与`S12-R1-0-run.txt`（3061 bytes），不入git；详见[研究末节](research-mac-perf-r1-0.md#s12--首轮真实r1-0-red--2026-10-16-2137)。

### 10-16 S13 · 有界输出定因 / bench根内原子替换 / 新证明阻断

车头恢复cua，明确允许host只在bench根记录候选stdout/stderr；定因后只改bench侧并重编Release+PERF_BENCH，再作一次真实复验，不过即停，磁盘敏感、合成根测完清。本轮未改写白名单、生产脚本、正常包或iOS写法。

- 旧包定因：根内日志679 bytes，两个Blob保存权限错误在前，随后`当前楼层不是测试楼层`触发78；`addProfile`持久失败不publish/switch。原写白名单下最小Foundation CLI复现`.atomic`为Cocoa513/EPERM、直接写成功；未证明Foundation内部具体哪项操作被拒，不据此放行系统目录。
- 改动：host候选合并输出有界写`perf/bench-output.log`（256KiB，超限/短写RED，偏好值/辅助stderr仍不落盘）；Configuration同目录暂存+POSIX rename供bench Blob及启动报告使用，保留原子替换，非bench/iOS原写法。核心永久回归仅加2行既有内容替换，无新框架。
- 验证：有界日志真实helper通过合并/溢出；实际写helper在原沙盒下通过替换、rename失败保旧及暂存清理，核心CLI10项拒绝和真实替换通过。唯一mac Release+PERF_BENCH构建`** BUILD SUCCEEDED **`，新UUID`307C0D12-F989-378D-99C3-AA1FFC9EE1B9`；产品Swift新增34，保守测试新增55≤68。
- 定因运行还出现`~/.claude`7条路径mtime更新，保持RED、不打开内容/不归因豁免。修复后唯一复验七根更新路径0、偏好same，但host仍RED/ATTESTATION、完整观察0秒；候选由host清理为-15，不再exit78。实际报告已生成，bench楼层、双UUID、六开关及observer/callback值符合，但home/applicationSupport/documents/temporary用/tmp，root/caches用/private/tmp，触发canonical检查。
- 新坏消息：示例卡图片保存权限错误；cua旧会话结束后新会话能查询自有PID，但窗口空列表，无GUI/隐私拒绝验收。按不过即停未继续修或重跑，不把路径证明报错直接当作已写出根。

两次运行均先LEASED mac、测完立即release；所有自有合成根/临时家/marker/探针源码和二进制已清，`/tmp/mp-macperf-sol`仅余模块编译缓存。外部证据4份、各<1MB，不入git，见[研究](research-mac-perf-r1-0.md#s13--定因修复后仍blocked--2026-10-16-2212) / [复盘](review-mac-perf-s13.md)。

**BLOCKED，等车头下一切片裁决**。推荐实际getter结果先经现有Configuration.check/POSIX realpath后写证明（不硬填预期、不放宽host），另定位示例卡保存；获准且T3有效后再真实R1-0。不是DONE或R1 MILESTONE。

### 10-16 S14 · 路径证明 / 卡原件原子写 / 内核拒写证据（车头批准，T3关闭）

| 裁决 | 本轮落实 | 判据边界 |
|---|---|---|
| ① 两边realpath | 实际getter经Configuration.check/POSIX解析再报告；host实际值、root和HOME/TMP期望均解析后比较 | 不填预期冒充getter；根外/祖先软链逃逸、根内报告软链和HOME/TMP不匹配仍拒绝 |
| ② 噪声归因 | 仅`~/.claude`保留mtime列表但不单独RED；按bench subject PID/存活窗查Sandbox拒写，保存实际启动策略与SHA-256 | 其余六根、消失/扫描错误/超限照旧；缺系统来源/完成标志、显式loss、遮蔽或缺canary均不通过 |
| ③ 示例卡权限 | CardOriginalStore最后落到CardLibraryStorage.writeAtomically；仅active mac bench改用既有同目录暂存/rename | PNG/JSON仍真实保存，普通包/iOS原Foundation写法不变；未取得Foundation内部调用栈 |
| ④ T3关闭 | 只做CLI/脚本自测、mac两份编译和相关类定向；不启动bench、不申请运行租约或用cua | 静态门收齐后BLOCKED「等粟粟说现在测」，新窗口再真实R1-0 |

受控canary复用host自建`/tmp`的根外marker，app仅请求`O_WRONLY|O_NOFOLLOW|O_CLOEXEC`句柄，不创建/截断/写入；意外获准立即关句柄并拒绝出证。新报告必需`kernelWriteProbe`，旧包不能搭新host冒充通过。

核心CLI14项拒绝PASS；host20项合成自测GREEN；真实无GUI CLI同PID两条Sandbox拒写（canary与`/dev/dtracehelper`），完成标志/subject与系统emitter已核，marker inode/size/mtime不变，getter规范化及PNG字节替换/暂存清理通过。额外“只有canary”断言曾失败，接受实际第二条拒绝，不重跑helper、不扩白名单；全部拒绝事件保留，不把被拒绝请求等价成已允许写。

**证据边界**：Sandbox只给violation，不给全量allowed写事件；允许范围依据实际传入内核的精确策略与本PID拒写可见性，不从空日志推导。`lossless_system_delivery_proven=false`明确保留；系统代理/长期行为仍沿用S10局限。两份mac构建及逐类passed以本轮[切片日志](../perf-mac/sol-log.md)为准，不拿CLI或S10旧结果替代。无R1-0通过、基线/MILESTONE或性能收益声明；见[复盘](review-mac-perf-s14.md)。

**S14最终静态门已齐（22:53）**：mac Debug与Release+PERF_BENCH均`** BUILD SUCCEEDED **`；六类47测0失败，全部类passed已grep，最终`Test Suite 'TestHostIsolationTests' passed at 2026-10-16 22:49:42.956.`及`** TEST SUCCEEDED **`。宿主真实位于DerivedData的xctest-home/suite/私有keychain；AppPaths五项非bench原值对照通过。产品新增164（Swift47+host117）、测试新增83（核心17+host66）≤328；未加重复普通路径或未改错误分支测试。Release arm64 UUID=`4F758868-5338-38BC-A949-ACFC0A7B4D5B`、独立BID，preflight READY仅静态。原有Security/DetachedSignatures等诊断保留；自有合成根/家/marker/CLI均清，五份外部小证据不入git。**BLOCKED「等粟粟说现在测」**，不能自己启动bench或借旧T3继续。

### 10-19 S15 · 新T3优先，mac租约身份门阻断

车头先解除“R1-0不过不碰R1-1”的静态限制：只做R1-1/2代码、逐切片提交；本地mac两份构建/上架Release nm/定向测试，iOS Debug留Warden。调查尚未改产品代码时，粟粟“测啊”开启新窗口，最新指令优先，两个只读scout已取消，静态实现/构建全部暂停，未继续占窗口。

唯一实际运行前置命令为`MP_ZONE_PAUSE=/nonexistent device-lease acquire mac --why "sol T3 R1-0 隔离核验（粟粟10-19说测啊）"`，后台实际exit64/0.09秒，原文：`[device-lease] 你的 session 进程 56409 已经不在了（CLAUDE_PID / MP_SESSION_PID 要是常驻进程）`。未取得mac租约；按车头已核的S14现成UUID，不重编、不启动，没执行host run/生产偏好或七根扫描/内核审计、没有bench PID/弹框或观察结果。

**BLOCKED：需要修复当前执行会话的可信常驻PID注入/重新挂接，不是再要一次T3授权。** 推荐修启动器身份，保持lease验证不变；不手动绑定临时bash或他人PID、不代持租约、不改lease/暂停脚本或换设备。修复后且车头确认窗口仍有效，再由本会话以原命令acquire，看到LEASED才真实R1-0。当前无自有租约可释放、无新/tmp运行根/marker可清；只记录文档，不借旧测试结果声称通过。外部单份`S15-R1-0-blocked.txt`<1MB。

### 10-19 S16 · 真实隔离GREEN / 剩余自采与驱动缺口

车头指定`MP_SESSION_PID=90376 MP_SESSION_ID=sol-macperf`用于acquire/release后，后台实际`LEASED mac`；不重编，用S14现成包跑原host `run --seed isolation --window-approved --observe-seconds 30 --timeout 180`。临时Notice只通知自有PID，不改原main/perform_run核验、观察或清理；PID52453，host exit0/GREEN、failures空，30.1109秒观察完成，130次IP socket采样、最多1自有进程，结束-15为host正常清理。

| 验收 | 本轮实际结果 |
|---|---|
| 身份/实际getter | 独立BID、bench楼层、主二进制/代码UUID均核对，路径字段均规范；startup observer注册/回调均Int.min/Int.max |
| 七根/偏好 | 7根扫描完整无错误/消失，六根更新0，`.claude`3条仅记不独立RED；生产偏好same/变化键0，无值输出/落盘 |
| 内核主证据 | 唯一本PID系统Sandbox拒写为受控根外marker，canary可见、query_complete=true，精确策略/哈希已存，未扩白名单 |
| 实际界面/原件 | cua自有窗口14728在当前Space，截图见开屏/输入区；AX预算截断，不冒称完整GUI/TCC。自身输出263字节无旧保存错误；隔离根真实PNG/JSON原件存在，HangProbe仅start |
| 剩余诊断 | `xctrace list templates`成功，Time Profiler/SwiftUI/Animation Hitches可用；未录trace，T6进程内自采未触发 |

**DONE仅指真实隔离实证**；不把拒绝日志当全量allowed-write追踪/系统绝无丢失证明，也不把有限socket采样外推系统代理。未见可确认的隐私弹框、未虚构等待/代点，不声称全局权限已全拒。报告后立即`MP_SESSION_PID=90376 MP_SESSION_ID=sol-macperf device-lease release mac`，实际“已释放 mac”；自有bench根/marker已清，不动模块/他人缓存。

**后续BLOCKED（不是隔离失败）**：本轮HangProbe只产start；已核私有takeSample由自然心跳/CPU门触发，调试页仅日志/Finder入口，没有已验证可用的强制自采驱动。不以外部sample替代App内自采、不把空夹具/缺测量台当性能基线，也不在本窗口重编或恢复静态调查。推荐车头结束本窗口后恢复已授权R1-1/2静态，并裁决仅bench可控自采触发方案，留后续候选/窗口实证。原始证据4份、各<1MB，仅外部S16文件；无新build/test/类passed、无A/A/基线/MILESTONE。

### 10-19 · 恢复静态与新窗口规矩
- 车头解除后续缺口：继续测量台和钩子；强制自采只进 PERF_BENCH，普通产品包没有入口。
- 不启动 bench、不租设备、不念进度；以后实测只写 BLOCKED「等车头开窗」，由车头给租约命令。
- 窗口内遇到隐私框只写「有弹框」，不代点、不喊她；新日志每条最多五行，细节放外部证据。

### 10-20 S17 · 测量台静态收齐
- 核心和 M1–M9 真驱动已接，缺夹具会失败；CPU 已与独立系统接口对齐，不把 CLI 当界面实测。
- mac 两种包、普通 Release 符号核验、七类最终通过；首轮测试漏建目录已修，原始记录留外部 S17 证据。
- 下一片接启动、计数和仅测量包的自采；真窗口、夹具与 host 仍未验，iOS 由 Warden 编。[复盘](review-mac-perf-r1-harness.md)。

### 10-20 S18 · 钩子与可控自采静态收齐
- 启动、业务和偏好计数已接；只数已标记入口，不冒充全局 SQL 或物理写盘。
- 强制自采仅测量包的隔离种子角色可开，host 等实际采完再观察；普通 Debug 和正式 Release 没入口。
- mac 两包、正式包符号、八类 68 测及原组件 CLI/host 自测通过；细节外部 S18 留证，iOS 留 Warden。
- BLOCKED「等车头开窗」：真自采、界面、夹具和基线未验；不念、不租设备。[复盘](review-mac-perf-r1-hooks.md)。

### 10-20 S19 · 真实自采未过，停止实测
- 现成测量包身份核对后仅启动一次；自采子进程正常结束，但原文件超过 host 全文件大小门，内核 canary 日志也不可见。
- 原 host 判 RED，完整观察未开始；偏好相同、七根无更新不能抵消这两个失败。
- 已立即释放 mac 并清自有根；只改六份记录，不重编、不重跑、不改产品或白名单，细节仅外部 S19 证据。
- 等车头裁决：推荐流式核验原采样、仅留有界摘录，并解决 canary 可见性；未验钩子、M1–M9 和 A/A。

### 10-20 S20 · host 流式核验与实时日志裁决落地
- 原样本与摘录分开限额；字节数对照 App 回执，哈希/mtime 按原 host 来源两遍流式复核并明标，不虚构 App 字段。
- 日志流先于 App 开，谓词限 Sandbox/本轮 marker，保留 loss；收尾最多等十秒，缺 canary 仍 RED，不再事后查日志。
- host 最终自测与真实日志流烟测通过；同包样本和完整观察已过，唯一剩余失败是系统 canary 不可见，原始细节在外部 S20 证据。
- 已释放 mac、清自有根；没重编 App，未验钩子、M1–M9 或 A/A，等车头裁决可读取的内核日志来源/权限。

### 10-20 S21 · 粟粟批准系统静默分支
- 同窗全机 Sandbox 零行才记系统静默，严格核 App EPERM、marker 身份/大小/mtime 不变、七根更新零、偏好 same；四项缺一仍 RED，七根不豁免噪声。
- 通道活跃却缺本 PID canary 仍 RED；普通可见 canary 路径保留 S13 噪声规则，其他进程日志只计数、不输出内容。
- 最终自测与同包常规隔离 GREEN；首轮全机流类型不兼容已修，实际通道活跃、canary 有，静默分支仅自测，细节外部 S21 留证。
- 本窗口免 HID、不重编；已释放 mac 并清根，继续核真实夹具入口；A/A 若执行须记粟粟在用电脑、可能有噪声。

### 10-20 S22 · 粟粟要求停止冗余验证
- 停止逐文件/全文件哈希与重复身份核验；包 UUID 只核一次，自采只核大小和 mtime，不再读样本正文。
- 同包隔离 GREEN 后，场景和 A/A 复用结果；只在换包或改 host 时重验隔离一次，不逐轮扫七根/偏好/canary。
- 只验新改行为或改到的类，不重跑已过整套自测；证据只留结论和必要摘录，不为留证多跑命令。
- R1-3/R1-4 代码已补真实种子、同路径模板、mac 负载/运行器/分析；新统计边界、过期门、写入器/TUI、模板烟测过。窗口已到点，不启动新包；种子读回、真实钩子、场景与 A/A 仍待下一窗口。

### 10-20 S22 · 静态收口，等车头开窗
- 新种子/运行器与去冗余改动齐；两份 mac 配置及普通 Release 编译过，测量符号零，新增边界与实际输出烟测过。
- 窗口在编译期间到点，没租 mac、没启动新包；真实种子读回、钩子、M1–M9/A/A 未验。下窗只用已归档的测量候选，不用当前 DerivedData 普通包。
- 跨窗冻模板与清 tmp 的边界需车头定：建议单设合成夹具暂存目录；当前未运行批次、未遗留合成根，不能默认长期留 tmp。

### 10-20 S23 · 本窗隔离 RED，等车头裁决
- 新模板目录/HID 门已接，新位置烟测过；候选沿用归档与既有 UUID，不编译、不重核、不哈希。
- 首条 CLI 根别名拼写被拒，没起 App；纠正后实际只起一次，147 条全机 Sandbox 日志却缺自身 canary，按现行判据 RED。
- 已释放 mac、清自有根/marker；七根更新零、偏好 same 不能覆盖该红灯，钩子/M1–M9/A/A 未跑，首批性能数字未取得。
- 建议车头批准只修 host 的订阅就绪门再试；当前仅固定 drain(0.25)，[INFERENCE] 有启动竞态风险，不是已定因，不放宽判据。

### 10-20 S24 · 握手通过，同因 RED 后停轮
- 按车头裁决只修 host：随机 logger 串必须在流中出现后才起 App，上限 15 秒；只补并跑一个真实握手自测，已过。
- 同包本窗只复验一次，握手确认后仍缺自身 canary，依旧 KERNEL_LOG_VISIBILITY；不放宽判据，不再自行调整或重跑。
- 已释放 mac、清自有根/marker；没有重编、重核 UUID、哈希或旧整套自测，真实钩子/M1–M9/A/A 未跑，仍无性能数字。

### 10-20 S25 · 四证复用通过，测量启动错误后收尾
- 粟粟批准所有缺自身 canary 的情况统一核四证；唯一新增自测通过，S24 既有四证全真，保留原始 RED 并另存获批重判 GREEN，没有重跑隔离。
- 补充裁决免等 HID，最长 90 分钟；A/A 注记粟粟当时在电脑前、可能有噪声，命令已传入，不伪造未执行的 A/A 报告。
- 首轮 host 在 App 启动前报 KeyError:0，九场景完成零；按出错收尾释放 mac、清自有工作/批次根，批准的模板目录保留。
- 登记表查询已改用匹配根记录模式，真实查询烟测通过；没追加 App 实测，种子/钩子/M1–M9/A/A 仍未验，无性能数字。

### 10-20 S26 · 到点收尾，真种子完成、有效场景为零
- host 自修没有中途停；显示门改公开 API、bulk 准备排除自身 CPU 噪声，正式测量门未放宽；根内 Code 创建修复后 mac Release+PERF 构建、新包一次隔离 GREEN。
- 真实种子已存 2700 对话/25万节点，Code 增量提交 45 次；冻结模板和续跑入口保留，清掉模板内诊断文件，不重做种子。
- 首次 M1 未激活前台，10 秒就绪超时，最长忙段 1.58 秒只作失败观测；已接自有 PID 激活和模板复用，激活修复尚未实测。
- 续跑到 20:40 仍未拿到测量锁，旧 host 未留最后阻因，不能归因机器负载；现已保存阻因出口，租约/工作根已回收。有效场景 0、A/A 未跑，噪声注记保留；BLOCKED「等车头开窗」，细节外部 S26。

### 10-20 S27 · 五分钟查明真实锁屏，不放宽门
- 按新窗免 HID 复用 S26 冻结种子与 GREEN，先单跑 M1；没有重编、重做隔离、哈希或身份核验。
- host 现把具体阻因/既有快照写入 runtime；同一非编译门五分钟交回诊断，编译/排队/T4 休息仍等待，诊断状态可续跑且不误报完成；两个新增边界烟测过。
- 实际五分钟门触发：屏幕锁住且睡眠，负载/内存正常；只查本 UID 的 console 元数据，确认当前在台会话真的锁屏，不是聚合误判。
- App 未启动，有效场景 0、A/A 未跑；已自动释放 mac、清本批根，冻结种子保留。BLOCKED「车头先解锁并亮屏后续窗」，不绕认证、不删前台门；细节外部 S27。

### 10-20 S28 · 静默等门实证，M1 未过、截止收尾
- 30 秒静默等本人解锁且亮屏，之前不租 mac；批次内防睡眠、结束回收，重锁先放编译锁。两个新等门边界与私有内核锁回收烟测过，没重跑旧测试/隔离或重查 UUID。
- 实际解锁后自动运行；修了 Cua 已结束会话及抢在窗口创建前激活两处 host 错误，自有窗口前台/焦点已独立验证，探针失败不会续跑后续场景。
- 同包 M1 仍 10 秒就绪超时：默认左栏关闭、空 action 却要求可见聊天行；初始前台快照也未满足严格校验。输入见证仅找 NSTextView，原生类型仍待实证，不能改断言硬过。
- 最后一轮再锁屏并静等至 23:30，App 未启动；mac/临时根已回收、冻结种子保留。有效场景 0、A/A 未跑；建议 S29 修 bench 固定初态/真实输入见证与前台时序，再换包一次隔离，必要摘录外部 S28。

### 10-21 S29 · 静态就绪，新包首次真实隔离 RED
- M1 自开左栏并等真实行/输入/前台，仍以进程起点计绝对 10 秒；通用启动先等真主窗前台，M3/M6/M8 和 M9 Code 档补同类左栏前置，不放宽断言。
- M2/M4/M5/M7 与其余压力档已有前置，不扩修；TextField 原生承载、离屏行等仅记风险，逐项审查见研究，未引入输入适配框架。
- 仅测量器类 9 测通过，一次 mac Release+PERF 构建成功并归档；已按要求短记「包好了，可以跑」，新包只核一次 UUID/符号关联。
- 最新等门不查 HID，真实新包隔离 RED：非噪声生产 agent 根两项 mtime 更新，四证未全过，无法归因；没有继续 M1/整批/A/A。mac/临时根/marker 已回收、冻结种子留；建议车头给该根安静窗口同包重验，不放宽判据、不动生产进程，证据外部 S29。

### 10-21 S30 · 定点隔离过，继续修 M1 原生输入见证
- 车头确认生产触发实际为每五分钟第 13 秒，不是源码旧注释的两分钟；判据不变、生产不动，同包在第 15 秒开始，44.36 秒完成、早于下一触发，GREEN。
- 单 M1 仍卡原十秒前置；真实窗口/AX 已见合成聊天行与未聚焦 TextField，前台/key 成立，旧见证却仅递归 NSTextView，不删条件、不把无回调记零卡顿。
- 只读自有窗口诊断没有修改结果或断言；全局菜单/最近文档元数据不保留，五份以内证据仅外部 S30，自有根和脚手架已清。
- 原整批/A/A 保留；继续 S31 修真实原生输入见证和 M6 字段编辑器路径，再编包、定点隔离后续原流程，不停下索要裁决。

### 10-21 S31 · 原生输入见证（静态通过，新候选就绪）
- 输入见证接受未聚焦但可编辑/启用的真实 TextField/TextView，仍须处于 composer 实际可见范围；M6 只在打字阶段请求原生 first responder/字段编辑器，不靠预点击伪造 M1 就绪。
- 实际边界断言两次失败留证：AppKit 的 visibleRect 可超出控件 bounds，错误把 composer 外控件纳入。修真实 bounds 交集后开新一轮，仅相关三个原生用例通过，未删断言、未改测试名。
- 测试包括真实 SwiftUI 竖向 TextField 变为 first responder；产品新增 36 行、测试新增 67 行，未建 helper 库、未重跑旧整套，测试宿主实证仍是隔离根。
- 新 mac Release+PERF 一次编译通过、候选和符号已归档，只核一次新包身份；不碰 iOS/生产。原十秒/T0/所有场景和四证不变，立即定点隔离后续单 M1/整批/A/A，冻结种子不重建，尚无新有效读数。

### 10-21 S31 · 真实补记，继续 S32
- 定点新包隔离 GREEN、50.82 秒且早于下一生产触发，四证全过；系统日志未记本次拒写，不改 S25 判据、不动生产。
- 单 M1 明确 sidebarVisible=true、composerBounds=missing、inputReady=false，原十秒断言拦截；有效 0/10，不放行后续/正式 A/A，不把静态原生三测称端到端过。
- 继续 S32：见证从 Group 背景移到实际 mac 输入域，未入窗旧见证不覆盖已入窗见证，并修同类可见矩形超出控件 bounds；不改产品 UI、iOS、截止或分母，不补接线测试。
- 自有根/批次、进程/租约已回收，必要摘录外部 S31，批准模板与配额账保留；脚本/bench bug 按既定裁决修好继续。

### 10-21 S32 · 车头裁决：先取实物，撤回先猜后编
- S31 补记中的候选改法尚未实施，暂停全部产品源码修改；先复用现成 S31 包/冻结合成根，内核隔离与定点启动照旧，不重核 UUID/哈希。
- 直接取聊天输入区域真实 NSView 的类名、frame、window、isHidden、acceptsFirstResponder；不把 AX 角色当原生类，不读控件文本，必要原始元数据只放外部 S32。
- 输入域本在且可聚焦则明确是测量器 bug，照实物修；所有断言与原十秒不改，之后只编一次，不用多轮包猜测、不补接线测试。
- 首次专用调试器附加自动续跑、失去十秒现场，未取得层级、已报工具状态不一致；改为原子附加/读取的诊断脚本，旧包不变、调试结果不计性能样本，继续取证。

### 10-21 S32 · 实物与最小修复
- 现成 S31 的完整 NSView 元数据已落外部 S32：聊天输入是可接焦点、未隐藏、同窗的真实控件，输入区的原生 Witness 也在；未读文本、未把 AX 当原生类、未重核旧包。
- 不搬 Group/宿主/输入，不按私有类名或硬编码 frame 特判；仅拒绝无窗口实例写入登记，避免离窗回调覆盖活见证；可见范围夹实际 bounds 并统一坐标。
- 只改三行测量器，测试零新增；不写接线测试、不刷已过类。实物明确后的一次 mac Release+PERF 已编成并归档，新包身份只核一次；原十秒、断言、沙盒、产品/iOS 都不改。
- 登记丢失是否闭环以新包真实 M1 为准；调试暂停/表达式/输出三次故障已留证，调试结果一律不计性能，后续仍按新包隔离、单 M1、整批/A/A，不缩分母。

### 10-21 S32 · 隔离 RED，按规停
- 新候选定点隔离 51.74 秒，完整观察在下一生产触发前结束；App EPERM、marker 不变、七根无变化、偏好 same 已观测，但内核审计抛 EVIDENCE_LIMIT，保持 RED。
- `mac-isolation.py` 在时间窗/subject PID 过滤前限制整个流的 256 条行数；这不能等同本 PID 有 256 条写事件，也不能据四证直接绕过未完成审计。当前未修 host/放宽判据。
- 需车头裁决，推荐全机事件只按窗计数、本 PID 事件单独限额；保留字节上限、丢失/格式/本 PID 超限仍 RED、四证不变，同一候选定点重验，不再编 App。
- 原生实物与三行源码/一次编包已提交，但修后 M1/整批/正式 A/A 均未跑、无基线；已释放 mac、清自有进程/根/marker/脚手架，批准模板和原配额账留，证据外部 S32。

### 10-21 S33 · 车头解除 host 资源上限阻断
- 采纳车头裁决：全机仅计数、不留其他 PID 事件内容；本 PID 写证据单独限额，日志丢失/格式错/本 PID 超限仍 RED，四证和内核隔离不变。同类 host 工程故障今后自行修完继续，不再等裁决；真实隔离风险/认证和原 T4 政策不绕。
- NDJSON 逐行处理，不建全机事件对象列表；完成计数/时间/来源仍严格校验，接收字节上限保留，流关闭清临时原文，仅输出本 PID 写事件。
- 仅新定向自测 GREEN：全机超过旧行数上限仍计数且不泄漏外 PID，本 PID 恰好上限完整保留，超限/丢失/格式错误仍拒；顺带修正该格式分支原有错误构造参数。产品新增 24 行、测试含入口 35 行，无框架、未刷旧套。
- 复用 S32 原候选/符号/冻结种子，不编 App、不重核 UUID/哈希；修后 host 先定点重验，同包 GREEN 后单 M1、整批与正式 A/A，原分母、十秒和 T4 账不改。

### 10-21 S33 · host 实证过，继续原测量
- 唯一新增自测 GREEN，产品新增 24 行、测试含入口 35 行；不重刷旧套、不建框架。原格式错误分支的多余构造参数已修，丢失/格式错/本 PID 写证据超限仍 RED。
- 未编 App/重核 UUID 或哈希；同 S32 候选定点重验 44.39 秒 GREEN、四证全过，系统日志未记本次拒写注记保留。本次全机计数与本 PID 事件内容分离，没变内核/四证。
- 隔离 mac 租约立即释放，已启动单 M1 探针通过才续 M1–M9 的原整批；正式 A/A 原分母不改，当前未宣称场景/基线完成。
- 按车头授权，后续同类 host 工程问题修完继续；原 T4 账本/额度、权限、实际越界写不是工程 bug，不绕。验证命令、判定和候选来源外部 S33。

### 10-21 S33 · 首个 M1 读数与下一刀
- M1 探针和正式进程均 OK；正式进程仅 1 个，就绪 1.821 秒、最长主线程忙 9.42 毫秒、采样峰值约 73.44 MiB，探针排除，不称基线、p95 尾分布或产品改进幅度。
- M2 A/B/C 的冷/热/同 ID 与前置过，sendEvent 全部超时/功能断言失败；整进程不计有效分母，M3–M9/A/A 未开始，失败不删、不放宽。
- 实物显示行 visibleRect 可延伸至整个裁剪区，click 尚直接用它算点击点；S34 只将点击范围夹实际 bounds，修这个测量器错误，不改 UI/焦点/断言/十秒、不编多轮包猜。
- 本日原 T4 已 8/8、剩余 0；代码/编包可准备，但真实续测需车头追加额度或次日窗，账本不改、不换身份绕开。自有进程/租约/根已回收，模板留，完整样本摘要外部 S33。

### 10-21 S34 · 车头追加今晚 T4，点击/调度收齐
- 车头授权至本地 10-21 12:00：今晚只按累计拿锁两小时，不再受八块数限制；保留已用账与单块十五分钟、清理余量。显式到期参数覆盖本窗，未授权默认仍保留原块数政策。
- 编译队列有活票即回收自有 App/负载再放锁，部分运行单独记丢弃、新 ID 从冻结根重跑，不进有效分母；队列空可重拿，编译让锁不强塞休息，普通块间原休息仍留。
- M2 根据原生实物只把点击矩形夹到实际 bounds，不改事件/焦点/断言/十秒；离线真实几何旧点在目标外、新点在内，一次 mac 候选编成/符号归档、新身份只核一次。
- 仅新增调度边界自测 GREEN，使用真实临时 flock、预算边界及丢弃分母；未伪造生产排队。新包定点隔离后直接 M2–M9/正式 A/A，不重复单 M1，不缩分母；总额不足仅留有效部分、不冒充完成。

### 10-21 S34 追加 · 车头最新裁决优先
- 只在碰生产数据、真实越界写、需认证时停；host/测量器工程问题自己修完继续。本窗显式到期授权下额度账仅记不挡、取消机械休息；保留单块十五分钟/编译优先/原账，未授权默认政策不变，新增该边界自测已过。
- 不改 App、不重核身份、不重刷旧自测；真实隔离和原分母场景/A/A连续推进，不因自定的额度账再停。
- 同窗实证：新包隔离 GREEN，M2 全阶段过；M3 原报告完整校验过，旧宿主失败不改写。Cua AX 缺焦点旁证不再替代原生前台断言；负载均值仅记噪声，其它原始快照保留。
- M3 切楼层后再启的测试前置由进程参数显式给定 `lastProfileId`，不动产品/隔离守卫、不访问根外偏好；早退输出在宿主保留。续未过的 M4–M9/A/A，不重复已过项；不是完整基线。

### 10-21 后续测量器修正 · 同包实物先行
- 旧包取到完整原生树及实景：日历取证时无面板见证；设置真实页面可见且已换页，出现事件却挂在身份边界外。诊断暂停过进程，不纳测量；Swift 内部状态未导出，未猜其值。
- 先只规范 M4 出厂停靠前置、把 M5 页身份包住出现事件；不降低可见/动画稳定/新出现断言或十秒。旧包独立 M6–M9 同时收齐，必要修正集中后只编一次新 mac 候选，再实测失败项与原 A/A。
- M6 原包实际交付了全部合成字符，但种子流式会话只有两条，初段不够滚；host 仅在还原后的本次夹具复用现有 A 长历史，不改冻结模板/总量。驱动等真实滚动区、五次取内部位置并按原生 clip 约束落点，最后再滚底；原一像素/十秒/业务断言留，必要失败状态只在操作后记。
- 旧包 M7/M8/完整十分钟 M9 已真实通过；不重跑这些旧包场景，修正集中后新候选正在唯一一次 mac 编译，后验仍待。

### 10-21 S35 host · 修正旧裁决未贯通的误判
- 四证汇总漏认 S13 已批准的 Claude 目录 mtime-only 豁免；仅对确切根且已有豁免标记贯通，根消失/错误、其它根与缺数据仍拒。仅新边界自测过，原路径证据不删。
- S35 同次实证已有 EPERM/marker不变/其余根零更新/偏好相同，按既有裁决重判 GREEN并记录新host身份；不重跑隔离/编包/UUID，接失败项与原 A/A。

### 10-21 S35 host · 恢复 §2.1 的超时读数语义
- 原生日历已显示、动画完/帧稳，但连续长忙使安静窗不足；不是缺见证。§2.1 明定超时是失败读数，旧 host 把其当格式错并中止采集有误。
- host 保留原失败/断言/十秒及全部分母，真实 timeout 单列；有超时就不报成功子集的 ready 分位数/差值，`COMPLETE` 仅代表收集完成，不代表性能通过。动作异常、证据缺失、非超时断言仍拒。
- 仅新统计边界自测通过，原生日历原报告完整校验通过但仍为失败测量，不重播；同批次保留原 ID 从 M5/M6 接着走，再原 A/A，不编 App。

### 10-21 S35 host · warning 不丢测量进程
- 本窗已采九十三个进程后，运行中的 memory warning=2 被 host 中止；按最新裁决只记噪声及 swap 增长，原快照保留，不称低负载基线。默认/过期策略、critical/编译/锁屏控制不动。
- 仅新增该边界自测通过，并用原实际 warning 快照证明不再误拦；已采分母保留，唯一中断样本单列丢弃、同任务新 ID 重跑，原计划分母不缩、不重开 A/A。

### 10-21 S35 host · 写入器必须送出真实文件事件
- A/A 完整样本已到一百零七个；首个 L1b 文件持续增加却无 watcher batch。相同沙盒原生探针证实持有写句柄时事件不送，关闭才到。
- 生产器改每次追加后关闭，剂量/节奏与 App/监听断言不变；仅真正 `_load` 的新烟测，三文件原生事件均到。无事件窗单列无效，原完整样本保留，换新 ID 重试同窗续原 A/A，不编包/重核身份/隔离。

### 10-21 S35 · A/A完整，R1基线继续补档
- 原A/A已收齐220/220，204正式进程、16预热；每臂M1–M8各12、L0/L1b各3个完整600秒窗。仅两次真正无效尝试另存并换ID，正式分母不缩。
- 全量原报告分析无采集错误，但性能RED：日历打开、流式首滚/末泡两臂均十二次超时，Code小会话点击各一次。超时原断言/十秒照留，不给成功子集伪报ready分位数。
- 同包A/A噪声带、原生失败、M9次数率CI/资源已进[基线](../perf-mac/基线.md)；不是R1全项MILESTONE。S36复用A臂补L1c/L1a/L-term/后台态各三窗，不重跑已有分母、隔离或包身份；trace/Debug/UI/记录器剩余项仍缺。

### 10-21 S36 · 五档有效，终端真实内核权限阻断
- 同包复用A臂，L1c/L1a/后台态各三个完整600秒窗已补齐；实际监听/增量/详情revision均按原契约。后台激活首事件3/3十秒未确认，原报告active=true但Code选择计数未进，未确定原因，不据此推断生产切回耗时。
- L-term真实PTY零喂入，完整观察仍属无效负载；相同内核策略的纯host诊断证明openpty及首阶段posix_openpt即EPERM。未写设备数据/元数据、未改内核白名单或断言，需车头审最小设备例外，不能以直喂终端替代真实PTY来缩范围。
- M4/M6自有PID Time Profiler已真实录制/保存/导出；日历全对话Query、段落测量及思考块提取见[基线](../perf-mac/基线.md)，整段采样未按单操作切片，不冒称因果。SwiftUI明确无数据且保存未完成，无可用trace，不计已验。
- 本轮无产品/runner源码修改、不重编/哈希/重核身份/重扫隔离或旧测试；mac释放、自有工作根/脚手架清，模板/原账/有效批次及两份有效trace留。R1全项仍缺，BLOCKED是内核权限，不是自定额度账或日志旁证。

### 10-21 S37 · 车头延窗，PTY不动，其余继续
- 车头确认PTY例外仍等粟粟批准，本轮不改沙盒、不重跑终端档；原五档分析/表已完成，不重复验证。真实授权截止延至当日23:59。
- 屏幕现锁着：先无屏幕准备，静默每五分钟检查，解锁亮屏后自动续自有PID的剩余Profiler/SwiftUI/Debug/UI，不查HID、不念、不等车头。五分钟门仅改原等待间隔，新状态烟测已过：锁屏/黑屏均闭、先放编译锁、不租设备/起App。
- 已冻结Release不重编或核身份；Native源码/Packages/project配置与S35源点逐项一致后，只编同源mac Debug候选。换Debug包才隔离一次，已成功M4/M6 TimeProfiler不重复录，UI诊断不混进性能分母。

### 10-21 S38 · 锁屏先收独立UI静态部分
- 仅mac新增无默认AUT的UI target/host，十项均须真实断言；host沿用原内核白名单、冻结合成根和租约，不能代点授权或操作生产App。
- 独立UI的本地流式和真实忙段快照限bench编译门/seed角色，不启用测量驱动、不混入性能分母；旧Release和同源Debug归档不替换，PTY权限不动。
- mac build-for-testing及唯一新增host边界烟测已过；定向单测/十项UI尚未运行。新产品归档仅核一次身份，解锁后隔离一次再实跑，不以静态编译冒称全绿。

### 10-21 S39 · 锁屏补齐离线记录器，界面未冒称通过
- 显式UUID归档索引离线atos，不哈希/重新核包；主/Debug代码镜像分别登记，未知镜像保持未解析。日报只读显式栈和元数据，编译器桥接帧不当产品函数，混合栈/测试宿主保留。
- 历史日期计数已回读；旧稿中位数未复现、原14栈缺失，不为了过表改数。当前主线程样本权重与身份/时长语义烟测通过，详见research §7.8与外部S39证据。
- 设置页改后台有限尾读、区分前后台/下界/CPU窗；mac两配置及普通Release符号门过，隔离宿主相关两类19测实际passed，未跑旧整套。真实UI仍等解锁，新UI包不替换S35基线或S37同源Debug，PTY权限不动。

### 10-21 S40 · PTY精确例外获批，只验新用例
- 粟粟经车头批准：SYSTEM_WRITE_EXCEPTIONS只新增file-write-data的`(literal "/dev/ptmx")`及`(regex #"^/dev/ttys[0-9]+$")`；没有其他设备写、create/unlink/mode权限，原七根读保护/默认拒写不变。
- 原literal生成器仅补regex输出；旧/dev/null用例保留，新独立真实PTY读写用例也纳入完整自测入口。本轮只跑该PTY用例且GREEN，不重跑旧用例、不启动App/租设备。
- host已变，旧GREEN不能复用；解锁亮屏后对S35冻结包完整隔离一次，过后补L-term三个完整600秒窗，再续原Profiler/SwiftUI/Debug/独立UI。五分钟门继续、不念。

### 10-21 S40 · 新host隔离GREEN，真实PTY已通
- 按新白名单复用冻结包，真实隔离四证全过；一次生产定时写入碰窗的RED保留后按既定空档重验，不改判据/生产进程。mac均已释放，隔离根/marker已清。
- App真实终端持续收到了PTY字节；两次全长观察末尾失焦，均保留原报告但不进正式分母，不能写成终端三窗已齐。
- 先用只读PID旁证定位失焦；缓存型NSWorkspace旁证已标无效、换实时系统查询。不开其他设备，不重编/重核包或再扫隔离；查清后继续原归因/Debug/独立UI。

### 10-21 S41 · 宿主排除零尺寸占位窗
- 现场窗口列表曾先给零尺寸隐藏占位窗，旧host“有窗口就激活”误选；测量/归因/UI统一只选自有普通非零窗，激活传精确窗口。
- 只跑新增选择边界用例GREEN，真实主窗已选对；Cua持续激活仍partial，未称失焦修好、未接纳无效终端窗。App/内核策略未变，不重编/重扫隔离或旧测试。
- 继续独立Profiler可达项，已成功M4/M6不重录；主指标有效栈表、SwiftUI/Debug/UI及终端缺档仍按原计划收齐，不用目录存在冒充成功。

### 10-21 S42 · 八份真实栈，SwiftUI仍零行
- 未重录M4/M6；其余8个上下文真实录制、保存、导出且唯一AppKit主线程有栈，启动器入口单列，缺栈分母不丢。4项原生前台校验失败，不拿诊断代替有效前台或补基线。
- 整段采样含测量器指纹/准备成本，不能把入口、去重符号或指纹占比当产品业务病因。必要汇总见外部同名证据，[复盘](review-mac-perf-r1-profiler.md)。
- SwiftUI原策略launch能保存、但更新/因果真实各0行；包已有调试注入权限。官方资料的正常停录提示将单独验证，不猜旗号、不改内核/launcher或重编包，继续可达Debug/UI。

### 10-21 S44 · 车头追问指纹与两个产品热点
- 直接查冻结S35源码：指纹不直接落入任何ready/busy窗口，整进程16–35%不能据此扣改原基线；不为它改下一候选或重跑旧数。
- 启动主线程索引修复约160–240ms采样CPU、M2 applyTreeData热点已记入基线，CPU权重/墙时与失焦来源分清，见[复盘](review-mac-perf-r1-fingerprint.md)。
- 没有新增App测量、重编或哈希；继续Debug启动和剩余R1，不在本切片顺手改产品热点。

### 10-21 S45 · UI宿主修复，初始化仍缺
- UI新包独立隔离GREEN；客户端误用runner Home导致找不到既有Cua守护进程，已分离仅Cua子程的Home，AUT/测试Home仍隔离。真实客户端修复前exit1后exit0，改到UI类定向编译过。
- 删除不存在的mac并发参数，先报测试器退出再看用例分母；已实际越过这两项，XCTest现卡automation mode初始化超时、业务0/10，不冒充用例失败或通过。
- 车头后续已定系统自动化授权属于安全设置+认证，UI挂起等粟粟决定；不改权限/TCC、不采用无认证模式，其他R1继续，[复盘](review-mac-perf-r1-ui-host.md)。

### 10-21 S47 · Debug首窗未建，限时留缺口
- 首进程即缺普通主窗，M2/M4计划进程未收数，M9未开测；实际只有状态栏窗、SwiftUI委托和普通应用策略，主线程已空闲，不猜长布局卡住。
- Cua无窗激活拒绝，候选已撤回；prepared无计时任务三十秒仍无主窗，不改包、原内核或十秒判据，不把诊断冒充Debug代价。
- 根因未定，按车头限时收口；部分早期临时报告未全保留，零分母/必要摘录不补造，见[复盘](review-mac-perf-r1-debug-window.md)。

### 10-21 S48 · SwiftUI仍空，暂停等继续
- 原内核exec后附着自有PID，二十秒正常停录时Native仍活，真实更新/因果仍空；不因trace保存成功称归因完成，不计十分钟窗。
- 车头限时：Debug/空表各最多再查三十分钟，未解写基线缺口不再深挖；收到继续后优先补终端三个完整窗，再收尾提交。
- 粟粟要用电脑，实测已停、残留为零、mac已放；不启app/录制/租约/自动等门、不念，只做已有文件分析/文档，UI认证另挂起，见[复盘](review-mac-perf-r1-swiftui-pause.md)。

### 10-21 S49 · 终端续跑前置，HID结束本窗
- 新继续指令按终端三窗→Debug最多三十分钟→收尾，截止当晚；键鼠归零即作废当前窗并停，不自动等闲置恢复。
- 首次Cua服务未运行、采样前退出，已只恢复standard监听而未改权限；新起跑门实际读到闲置不足两分钟，Native未启动，终端仍无有效窗，Debug未开始。
- 已停自起Cua服务、放mac、清自有进程/合成根，保留种子/原账；等车头继续，下窗仍先终端，不重验有效基线，见[复盘](review-mac-perf-r1-terminal-resume.md)。

### 10-21 S50 · 仅600秒起跑门，实读未达标
- 21:55新继续指令：先终端三窗、再Debug限时三十分钟，23:30前开始收尾；没有新增两分钟等待。
- 起跑门实读闲置不足一分钟，实际未启动Native；原宿主ioreg后续也未到六百秒，终端仍零有效窗、Debug未开始，不据计数器推断是谁操作。
- 自起标准Cua服务已停、mac为空，不自动重试；建议车头先保持Cua前置就绪，再按同一HID读法达六百秒开窗，判据不变，见[交接](review-mac-perf-r1-terminal-resume.md)。

### 10-21 S51 · 自注入不再冒充真人回来
- 车头实读21:55:37已闲置六百一十秒，之后归零很可能是工具；修为初始六百秒自动起跑、自注入/bench前台活动排除，只有非自注入的窗口外新归零才中断，不等新继续，23:30前收尾不变。
- 新HID七项行为用例通过；实际以六百秒边界通过并启动Native，包/内核白名单/原生前台、十秒与六百秒断言未改，旧UI豁免调用约定不变。
- 两轮被backend-2的test-without-building打断，均未计长窗；这是直通测试与测量冲突，不改生产锁、不杀其他任务、不放宽判据，协调后继续终端，见[复盘](review-mac-perf-r1-terminal-resume.md)。

### 10-21 S52 · 截止收尾，终端仍缺三窗
- 按同一授权自动等初始六百秒，无额外等待；至23:29截止仍未获准入，未启动Native/未拿mac租约，终端无新增有效窗，Debug依序未开始。
- 此轮不是窗口外输入触发，也没有新的并发测试采样失败；初始待机没有逐次读数留存，不能归因是谁或哪个工具更新计数器，不补造结论。
- 23:29截止转文档/提交/自有资源收尾，Cua保留基础前置就绪，不重编/重验包或旧隔离，不把时间上限收口冒充R1完成，见[复盘](review-mac-perf-r1-terminal-resume.md)。



































## 10. 三件事交给人

- **野心**：第一批做完 M9-L1c 仍有 >1s 卡顿就继续追，不停在「后台几刀」。
- **品味**：任何看得见的变化（K0-min 的新回复延迟、R-tab 不再自动回 Code、W1 若改样式、K3 的新鲜度）写明给她。
- **方向**：几百行只换几毫秒的主动提不做。

## 11. Todo

**拍板**
- [x] N1=a 止血先上；N2=a 启动不自动回Code；T5=b最小隔离（10-16任务书已批）
- [ ] N3 常开工具 / CC实际在哪个终端（不阻塞不依赖它的止血刀）
- [ ] T1–T4、T6–T8（开测前；T5宿主根改道已有#035，残余限制见既有review；bench隔离仍须另验）

**R0.5 止血（N1 = a 才做）**
- [x] H1 HangProbe：结束必记心跳往返时长（含后台；主线程应答时取结束点）
- [x] H1 每行 pid + 代码镜像UUID / 构建来源
- [x] H1 测试宿主不起 HangProbe / 不写note（回退开关不取消安全门）
- [x] H1 上下文：打开的工具 id 列表、Code / 详情状态、终端喂入字节率
- [x] H1 `sample` 阈值 1s → 500ms；4项行为回归及真实单次心跳smoke通过，周期sample/Release权限实测仍留T6
- [x] S1 默认跳过probe-5a/5b四次count + 状态同值不写；`SyncStoreTests`11测通过，NO回退临时smoke通过并移除
- [x] P1 剩余 KBProbe mac默认关 / 显式开启后台串行写，侧栏同步print随探针关闭；3测含NO同步回退通过
- [x] P1启动 probe-2 / probe-4 已由其他提交删除（L3），不重复做
- [x] K1-dirty 隐藏增量dirty-only、空路径事件/激活补齐/菜单独立查询；最终16测及NO/详情恢复smoke通过
- [x] R-tab 默认YES不自动回Code、保留存档，NO恢复旧行为；独立suite真实重建及整类10测通过
- [x] K0-min 四项齐：成本限流/idle后起计/静默不翻指示器/同值不替换；18测、NO与真实文件/RunLoop smoke通过
- [x] T5-min 临时store / 家目录由TestHostIsolation覆盖；不起HangProbe / note写入已随H1补齐
- [x] `mp.stanch.*`六刀逐刀接线与NO回退自测，不复活已删诊断；H1测试安全门不随NO解除
- [x] 仅mac专项编译/测试，指定类passed原文与最终成功状态均留证；不跑iOS
- [x] 交付止血代码批MILESTONE，停交车头验收/合并；R1未启动
- [ ] 车头MILESTONE验收/合并；合后粟粟手摸「打开Code不死」（本轮不越过此门）
- [ ] 装后 ≥1 天，`mac-hangs-report` 前后对比（按包身份筛）→ astra R0.5 审

**R1-0 隔离与实证**
- [ ] `AppPaths`：Application Support / Caches / Documents / 写死 iCloud / 家目录 API（含 `getpwuid`）全部收口
- [ ] bench 模式越界 trap
- [ ] bench 模式副作用开关：时间机器、SyncEngine、CC 桥客户端 + hub、ThinkingHook 安装器、额度服务、钥匙串、代理广播、Sparkle、通知、菜单栏、全局快捷键、Code 监听根
- [x] `CFFIXED_USER_HOME` 小命令行实证（S8八项PASS；不包含原生临时目录，S9已发现该入口不随TMPDIR改道）
- [ ] bench 包命令行构建 + 签名 + 存档 + UUID
- [ ] TCC 首启她在场全部「不允许」（S16仅候选截图未见可确认弹框，无代点，不声称全局权限全拒验收）
- [x] marker + 七根路径mtime + 生产偏好内存前后 + 网络侧核对（S16 GREEN：六根0、`.claude`3条仅记，本PID内核canary可见，130次socket采样；有限窗非逐包/系统代理保证）
- [x] startup observer顺序进JSON（S16实际注册/回调Int.min/Int.max；非尚未实现的忙段测量器）
- [x] `xctrace list templates`（S16列出Time Profiler/SwiftUI/Animation Hitches，未录trace）
- [x] T6 Release进程内`sample`实证（S20正常退出、本PID主栈、全文件双次哈希/mtime核验通过；R1-0整体仍因canary不可见RED）
- [ ] 测试宿主完整改根（T5-a，管家协调）

**R1 测量台**
- [x] `PerfHarnessMac.swift`：双观察者、display-link、ReadyGate、PerfCount、rusage（含 footprint 峰值）、JSON（S17代码/静态齐，忙段运行实证待窗口）
- [x] 驱动器 M1–M8 + 功能断言；M2 / M8 `sendEvent` 交叉验证代码（S17静态齐，原生行为待窗口）
- [x] M9 六档（L0 / L1a / L1b / L1c / L-term / 后台态 + 激活延迟）+ 可选 L-io + L2 驱动代码（S17静态齐，夹具/运行待后续）
- [x] 钩子（含详情解析 / revision、终端喂入字节、主线程 SQL / fetch、偏好调用；S18静态/定向回归齐，实际场景计数待窗口）
- [ ] 合成聊天种子、15 轮 Code 老化、CC/TUI 输出、同路径模板和指纹（S22代码/mac编译齐，输出器与模板烟测过；App种子/dbstat真实读回待窗口）
- [ ] `mac-perf-run.sh` / `mac-perf-abba.sh`、负载门、编译锁、租约和账本（S22代码/新行为烟测齐；真实进程及跨窗存放策略待验/裁决）
- [ ] `perf-stats.py` / `abba-analyze.py` 的 `macV1` 与 M9 泊松 CI（S22零/一次事件精确区间烟测过；真实报表对账未验）
- [ ] 三份 build + 上架 Release 无测量符号（S18两份mac包及正式Release无测量/自采符号已验，iOS Debug留Warden）

**R1 记录器 / 基线 / 回归**
- [ ] 符号存档 + `mac-symbolize.py`；`mac-hangs-report.py`；设置页分组
- [ ] A/A
- [ ] 基线 M1–M8 + M9 六档 + Time Profiler / SwiftUI 模板 → `perf-mac/基线.md`
- [ ] Debug 代价对照
- [ ] `MacRegressionUITests` 10 例 + `mac-ui-regress.sh`（与测量分开跑），基线包全绿
- [ ] astra R1 裁决落 §9

**R2 第一批**
- [ ] S1 补 ABBA 数字
- [ ] K0 ① 尾部追加 + 行 Equatable ② 追加字节解析 + 退回整份 ③ revision / 滚到底条件 + Code 全套回归 + MC1 / MC-live + ABBA（M9-L1c、M8）
- [ ] K1 后台只读长连接 actor + 全部 8 个入口迁移 + 回归 + ABBA（M9-L1b、M8）
- [ ] K2 差异写 + PRAGMA + 单测 + ABBA（写盘 MB/h）
- [ ] A13 终端后台队列（N3 + R1 证实后）+ 终端回归 + ABBA（L-term）
- [ ] 第一批汇总 + astra 审

**R2 第二批**（按基线重排；每刀：改 → 开关 → 专项回归 → ABBA → 实验日志 → commit）
- [ ] X1+A4 Code 侧栏（trace 定位 → 拆行视图）
- [ ] A14a 文件库面板轮询
- [ ] A14b–g 逐条核 → 按 N3 现场排序 → 逐刀
- [ ] W1 Warroom
- [ ] T1 Theme 缓存（+ iOS 棘轮）
- [ ] C1 CC 流式入站（M9-L2）
- [ ] O1 打开对话按路径取节点
- [ ] O2 附件气泡异步 + 降采样
- [ ] O3 气泡行 Equatable
- [ ] I1 输入框保存合并（中文输入法实测）
- [ ] 其余条目逐条决定
- [ ] 共享源码的刀同时跑 iOS build + iOS 棘轮

**收尾**
- [ ] 第三批（K3 / K4 / L1）交粟粟拍板
- [ ] 最终两包 ABBA（原版 vs 最终）+ `perf-mac/报告.md` + `docs/review-mac-perf.md` + `docs/now/mac.md`
