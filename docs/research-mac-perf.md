# research · mac-perf：mac 版「点了就转菊花」「打开 Code 必死」的现场证据与静态排查

> 2026-10-01 · 🎩（R0 执行者）· 工位 `zone/mac`（基 master `5cbd4e2c`）· 任务书 [R0](prompts/2026-10-01-mac-perf/R0-research.md)
> 产出：本文（发现 + 证据 + 置信度）→ [perf-mac/BRIEF.md](../perf-mac/BRIEF.md) → [plan-mac-perf.md](plan-mac-perf.md)
> **v2（R0b）**：按对抗审 [报告](prompts/2026-10-01-mac-perf/R0-review-report.md) + 车头 [裁决](prompts/2026-10-01-mac-perf/R0-rulings.md) 修订。审稿人的事实更正我都回原始证据（采样文件、`.hang` / `.diag` 头、代码行）核过一遍，核对结果和分歧见 §6。
>
> **取证边界**：已有的系统诊断报告（`/Library/Logs/DiagnosticReports/记忆花园_*`，26 份）、HangProbe 早先落盘的 `hangs.log` + 20 份 `sample-*.txt`（app 自己在 09-27 ~ 10-01 抓的，时间见文中）、`docs/assets/mac-hang/` 里 09-25 的旧采样、代码阅读、文件元数据（大小 / mtime）。粟粟 10-01：本轮**不做任何真实测量**——没有对任何进程 sample / spindump / xctrace，没有 build、没有启动 app。
> **流程偏差（如实记）**：R0 的 A 区子 agent 以只读 immutable 方式打开过 `~/Library/Caches/MemoryPalace/coding-index.sqlite`，数了表行数 / 页数，并对 `listProjects` 计了时（冷 87–110ms / 热 7ms）。这超出了「只看元数据」的红线和「不做真实测量」的补充指令。下文只引用其中的**聚合规模**（行数、页数，不含正文），计时不作基线，引用处标 ⚠。
>
> 置信度：**高** = 有符号化栈或代码逐行对上；**中** = 栈形状 / 时间线吻合但缺直接符号，或机制清楚但量级是推算；**低** = 只有代码推断。

## 0. 一页结论

1. **她停用 mac 版是因为「根本用不了」，问题没修好。** 粟粟 10-01：「我没用是因为根本用不了……code 想在花园打开，就必死」。她日常包最后一次长时间运行停在 09-28 10:04（编程会话索引 mtime、HangProbe 最后一条、最后一份现场采样都在这一分钟），这些代码路径在 master 上 09-27 中午之后没动过。（高）
2. **「打开 Code 必死」的直接现场 = Code 详情渲染风暴 + 后台整份重解析**（09-28 10:04 采样，§1.3）：主线程 2044/2099 个样本在 SwiftUI 事务刷新里给 Code 详情的 Markdown 段落 / 工具卡片做布局，同时后台 703/705 在整份重解析正被写的那条 CC 会话。代码链闭合了「为什么不是卡一下而是一直卡」：详情整份重解析不受限流 → 主线程每轮 O(N) 重排 + 滚到底 → 2 秒节流从 flush 开始计、不含渲染，于是背靠背 → 重开 app 又被 `restoreLeftPanelTab` 直接带回 Code（§2.2）。（中：现场一份 + 代码链闭合，R1 要复现）
3. **Code 列表主线程整表 SQL 是第二个来源**：只要 app 开着（与 Code 面板开没开无关），CC 会话文件一被写，最多每 2 秒在主线程对 988MB 的索引跑 5+ 条查询，冷读 `pread`；她 09-28 的 3 份采样主线程全程卡在这里，单次 ≥1s（触发值，是下界；031500 那次连续 ≥4s）。同期的 IO 来源**未定**：卡顿采样里看不到自家写盘，同进程同期在跑的是同步引擎的全表计数，另有机器层面编译 IO（§2.3）。（机制高，IO 来源未定）
4. **每小时 ~2GB 写盘 = 编程会话索引整会话删了重插**：22 份 disk writes 里 18 份是监听增量 `writeSession`、1 份是启动那一刻的全量扫描写（09-26 10:39 进程一起来 225 秒写了 2GB）、3 份是 09-27 一次性的搜索索引重建。（栈：高；量级换算：中）
5. **常驻后台 / 隐藏工具的主线程与 IO 负担**：同步引擎每 5 秒对 1.31GB 主库做 4 次全表计数（诊断探针，Release 也跑）；Debug 包侧栏每次 body 同步写 `~/Documents/kb-probe.log`；**本机 SwiftTerm 终端的 PTY 读取 + VT 解析 + 重绘默认全在主线程**（她在花园里跑 CC 时 TUI 整屏刷新直接压主线程，待 R1 证实量级）；右栏 6 个工具 opacity 0 常驻，藏着的文件库面板每 5 秒在主线程递归枚举整个文件库。（高 / 高 / 中 / 中）
6. **测量地基缺且有数据风险**：mac 没有测量台、没有 UI 自动化；单测宿主读写打开她的真库、会在主线程原地迁移 schema（09-30 那份采样**就是单测宿主**，现场证据）；bench 包换 bundle id 也挡不住的写入点很多（`~/Documents`、写死的 iCloud 路径——含时间机器按 manifest 删备份、她的 CC workdir hook、CC 凭据与额度请求、生产 hub 客户端、TCC 弹框，§4）。（高）

## 1. 现场证据

### 1.1 26 份系统报告总览

全是 Debug 包（1.1.0），09-24 ~ 09-28。DerivedData 区分来源：`fowvtox…` = 主工作区（/Applications 软链目标，**她的日常包**）、`gwjmgvaq…` = 09-24/25 mac-mint-appearance 工位包（当时她在用）、`dagxgtak…` = page2-twitter 工位包。

| 类型 | 份数 | 栈归因 | 置信 |
|---|---|---|---|
| disk writes（2GB/≈1h 或 8.6GB/数小时） | 22 | **18 份监听增量写**（`CodingSessionLibrary.startWatcherIfNeeded` → `CodingSessionScanner.scanFiles(:148)` → `write(:264)` → `CodingSessionIndex.writeSession(:180)`）：12 份系统已符号化 + 2 份用同进程 HangProbe 采样配上符号 + 4 份未符号化但 9 层栈形状、`sqlite3_exec → wal_checkpoint` 尾巴相同；**1 份启动扫描写**（`09-26-104336`，pid 22038，报告窗口从 10:39:47 进程启动那一刻开始，225 秒 2GB ≈ 9.5MB/s，栈 `CodingSessionLibrary.refresh(full:)(:241)` → `CodingSessionScanner.run(:108)` → `write(:264)` → `writeSession`）；**3 份搜索索引回填**（09-27 02:41 / 02:53 / 06:13） | 高 / 高 / 高（形状判的 4 份为中） |
| cpu_resource（90s CPU / 92–141s） | 3 | 09-25 11:28 = `LazySubviewPlacements` 布局循环（gwjmgvaq 包）；09-27 06:12 = 搜索索引回填；09-27 23:44 = page2-twitter 工位包的 `LazySubviewPlacements / updatePrefetchPhases`（2 分钟 footprint +426MB） | 中 / 高 / 中 |
| hang | 1 | 09-25 01:39，39.77s，pid 73806（gwjmgvaq 包，Time Since Fork 4493s，进程在最前台）。系统只在最后 1.3s 采了 13 个样，主线程 CPU 1.199s / 1.3s——**纯 CPU 布局循环，不是 IO**：`NSRunLoop.flushObservers → NSHostingView.beginTransaction → GraphHost.flushTransactions → LazySubviewPlacements → LazyStack.place → _ViewList_Group → ForEachList → DynamicViewList.WrappedList ×2 → BaseViewList`，一帧 app 代码都没有。见下 | **中低** |

**39.8s hang 的证据链（v2 重写）**：v1 写「同一进程 09-25 11:30 的旧采样有 Code 列表 `reload()` 帧」——**两处都错**：`docs/assets/mac-hang/sample-2026-09-25-1130.txt` 是 pid 36536（09-25 02:36 启动），不是 hang 的 pid 73806；那份采样里 `CodingSessionLibrary.reload` 帧数为 0（11:35 那份同样为 0），「reload 先清空」是 [plan-mac-hang-probe](plan-mac-hang-probe.md) §0 当时的代码推断，不是采样证据。能用的线索只有：① 同一 pid 73806 有一份 `09-25-010905` disk writes，栈是监听写库 → 那时 Code 监听正在写；② 栈形状（嵌套 `ForEach` + 两层 `DynamicViewList`）更像 Code 侧栏的嵌套 `ForEach + if`（`CodingSessionSidebarList.swift:195-206、219-231、248-254`），不太像详情的单层 `ForEach`（`CodingSessionDetailView.swift:89`）。所以「是 Code 侧栏的放置风暴」**可能**成立，置信度中低，R1 用 SwiftUI 模板抓。

### 1.2 符号化方法（UUID 对不上时怎么配）

- Debug 包的 dylib 每次编译 UUID 都变（`B56F9096…` / `120F9A79…` / `44CA1748…` …），DerivedData 早被覆盖（/Applications 现在指向的 dylib 是 `6071FD6A…`，09-28 03:05 编）。**没有**按偏移去套当前 dylib。
- 改用**同一进程的 HangProbe 采样**：`/usr/bin/sample` 的栈是活进程现场符号化的、带绝对地址；同一 pid 的系统报告与采样绝对地址一一对应（例：pid 21417 的 `0x10f503390` 两边是同一个 thunk）。据此配上了 09-28 06:36（pid 21417）的 9 层 app 帧和 09-27 18:35（pid 13870）的部分帧。脚本 R1 收进 `scripts/perf/`（plan §3.5）。
- 系统当时已符号化的报告，行号与现在 master 对得上（Library `:292/:324`、Scanner `:148/:264`、Index `:180/:1042/:1015`；09-24 早几份差 3–30 行，是之后小改动的位移）。

### 1.3 HangProbe 现场日志与采样（`~/Library/Application Support/MemoryPalace/perf/`）

**先说口径**（v2 补，`HangProbe.swift`）：
- 日志行**不带 pid、不带包身份**；单测宿主（= app 本体）也起 HangProbe、写同一本日志、还会起 `/usr/bin/sample`（`start pid=` 245 次里大部分是宿主和工位包）。按天统计只能当量级看。
- 「≥1s」那行（`hang 1.0s → sample-…` / `(cooldown, no sample)`）记的是**第一次越过 1s 的 tick 那一刻的值**（`:52-55`），**不是卡了多久**——是下界。
- 卡顿结束时的回执行（`hang 0.47s cpu=… code=… tool=…`）**只在 app active 时写**（`:71-77`），所以后台卡顿永远没有时长，回执行本身可以是任意时长。
- 触发值出现 2.6 / 3.5 / 6.0s 这种远大于 1s 的，说明探针自己的 100ms 定时器被推迟了（App Nap / 遮挡），这类行在后台态下真假难分。

| 日期 | 前台卡顿（回执行，任意时长） | ≥1s 触发行（下界） | `start pid` | 备注 |
|---|---|---|---|---|
| 09-26 | 13（p50 0.50s，max 4.33s） | 208 | 131 | **全周最重的一天，未归因**：当天的采样已轮换删除，131 次启动里多少是宿主分不清 |
| 09-27 | 130（p50 0.36s，max 25.72s） | 121 | | 10:29 的 25.7s / 10:45 的 11.2s 都在某进程启动后 30 秒内、CPU 87–90%（启动期重活，采样已删） |
| 09-28 | 8（p50 0.76s，全是 10:04 那一段） | 82 | | 02:55–04:19、09:06–09:23 两段密集触发 + 10:04 一段前台，全是 pid 21417 = 她的日常包 |

**她 09-28 那个进程（pid 21417，01:56 启动）的 14 份采样，按主线程归类（v2 重分）**：

| 主线程在干什么 | 份数 | 代表 |
|---|---|---|
| **Code 详情渲染风暴**：`NSRunLoop.flushObservers → NSHostingView.beginTransaction → GraphHost.flushTransactions` 占 2044/2099；细分有 `LazySubviewPlacements`、`ViewDimensions / explicitAlignment / _FlexFrameLayout.sizeThatFits` 布局；app 帧只有渲染器（`ParagraphView.updateNSView` `ParagraphView.swift:132-134`、`ChatMarkdownView`、`MessageSegmentsView`、`ToolCallCardView`、`RenderableDocument ==`），**没有 `CardFlowView` / `BubbleView`**——不是聊天页；同一时刻后台 `mp.coding-sessions.incremental` 705 个样本里 703 在 `ClaudeCodeAdapter.parseSession → parse`（整份重解析） | 1（`sample-20260928-100441.txt`） | hangs.log 时间线：10:04:14–10:04:36 连续 8 条前台回执（0.27–0.86s，全带 `code=1`）→ 10:04:41 ≥1s 触发这份采样 → 10:04:58 `busy cpu=104% 11s` → 之后这个进程再无记录，coding-index 和 `-wal` mtime 也停在 10:04。**这就是她「打开 Code 必死」、然后停用的那一刻** |
| Code 列表主线程 SQL：`applyIncremental → flushIncremental(:358) → reload(:443) → reloadProjects(:467) → CodingSessionIndex.listProjects(:415) → Statement.step(:986) → pread`（另有 `childCounts(:552)`） | 6（031500 / 040802 主线程全程、032821 约一半，030557 / 041909 / 090608 6–31%） | `sample-20260928-031500.txt`：2353 个样本全在这条查询里，2099 在 `pread`；触发值 1.1s + 3 秒采样全程未出来 → 那次连续 ≥4s |
| Warroom 面板：`WarroomPanelView.groupCard(:228) / taskRow(:239-242)`，`WarroomTask.__derived_struct_equals` 字符串 NFC 比较 + `Theme.textMuted → ThemeManager.selectedTheme` | 1（033328；另 09-27 23:17 pid 13870 一份同样） | AG 更新 1555/2344 |
| 主线程空闲（采样晚到） | 6 | HangProbe 卡 1s 才起 `sample`、`sample` 再采 3 秒，短于 ~1.5s 的卡顿抓不到 |

> v1 把 100441 误归进「空闲」——是我的聚合脚本只按「≥5% 的 app 帧」挑，而那份采样主线程的 app 帧都很碎（渲染器帧各十几个样本），系统帧（SwiftUI 事务）才是大头。审稿人指出后回原文件核：`flushObservers` 那一行 2044 个样本，属实。

同批采样的后台：`SQLQueue for unified.store` 在 `SyncEngine.pump(:157/:158)` 的 `count(for:)` 上——031500 占 1846 + 223、032821 约 1040；040802 只有 471。

**其他采样（v2 更正来源）**：
- `sample-20260930-100654.txt`：v1 写成「page1 工位包」——**错**，它加载了 `libXCTestBundleInject.dylib`，是**单测宿主**（宿主用的是 page1 工位编出来的包）。主线程 1068/1271 在 `MemoryPalaceApp.init(:661) → ProfileManager.makeUnifiedContainer(:229) → migrateStoreWithContext → _NSSQLiteStoreMigrator performMigration → WAL checkpoint`——**单测宿主在主线程原地迁移她的真库（1.31GB）**，这让 §4.1 从推断变成现场证据。（高）
- `sample-20261001-020209.txt` 同样是单测宿主（主线程在 `XCTestCase recordIssue` 做符号化，84 处 XCTest 帧），无参考价值，但再次证明宿主在往她的 `hangs.log` 写、在起 `sample`。

### 1.4 「09-28 之后没有新报告」：她用不了所以停用，不是修好了

| 证据 | 内容 |
|---|---|
| 她本人 | 10-01：「我没用是因为根本用不了……code 想在花园打开，就必死」 |
| 现场 | §1.3 10:04 那份采样 + hangs.log 时间线，之后进程再无记录 |
| 编程会话索引 | `~/Library/Caches/MemoryPalace/coding-index.sqlite`（988MB）和 `-wal`（6.3MB）mtime 都是 **09-28 10:04**；只有 app 的常驻监听会写它（单测宿主跳过首扫，`CodingSessionLibrary.swift:154`） |
| 她的包 | `/Applications/记忆花园.app` → 主工作区 Debug 产物，09-28 03:05 编，dylib `6071FD6A…`，**没出现在任何报告里** |
| 系统报告 | disk writes 按进程累计触发，09-28 03:05 那版只要开着有 CC 在写，一小时就会再来一份——没有 |
| 代码 | `git log --since 09-27T12:00` 对 `Services/CodingSessions`、`SyncEngine/SyncStore`、`Services/Search`、`HangProbe`、`Views/Warroom`、`Views/CodingSessions`：无相关改动 |

**一旦重新日常使用，以上全部会原样回来。**（高）

## 2. 根因展开

### 2.1 编程会话索引：常驻监听 + 整会话重写（写盘主因）

- **监听常驻，和面板无关**：`ContentView.swift:2056` 的 `.task` → `CodingSessionLibrary.scheduleStartupScan`（:150-154，6 秒后）→ `refresh()` 起 FSEvents 监听（:235）；`deactivate()`（:146）不停监听。（高）
- **节奏**：`CodingSessionWatcher.swift:21-22` 0.8s 合批、同文件 3s 内不重复送；`CodingParseThrottle` 同文件两次**索引**解析间隔 `max(3s, 10×上次耗时)`（只管索引写，不管详情，见 §2.2）。（高）
- **整份解析 + 整会话重写**：`CodingSessionScanner.scanFiles`（:126）对增量 ref 不比 mtime/size，`write`（:256-264）整份解析；`CodingSessionIndex.writeSession`（:178-209）在一个事务里 `deleteMessages`（:266-280：逐行读回旧正文给 FTS 写 `'delete'`、删光该会话 messages），再把**全部** units 重插 messages + `messages_fts`（fts5 trigram，:165-167）。（高）
- **PRAGMA** 只有 `journal_mode=WAL` + `synchronous=NORMAL`（:123-124），无 `wal_autocheckpoint` / `journal_size_limit` / FTS automerge → WAL 一遍 + checkpoint 一遍。（高）
- **规模**：库 988MB，`-wal` 6.3MB（WAL 不截断 ≈ 最大单事务）；⚠ sessions 7687 行 / 94 个项目（一个项目 5583 条）、messages 14.1 万行（正文 66MB）、trigram 索引约 780MB（正文 ~12 倍）。她的 `~/.claude/projects` 3.4GB，10-01 时最近 1 小时 28 个 jsonl 在写、10 个 >5MB、最大单文件 130MB。
- **量级换算**（推断）：一次重写 ≈ 正文 × 12 × 2（删 + 插）+ messages，再 ×2（WAL + checkpoint）。实测 WAL 上限 ~6MB/事务时，600KB/s ≈ 每 20 秒一次重写，她同时开几个 CC 会话，**每小时 2GB 解释得了**。（中）
- **启动扫描（L4，v2 升为有证据）**：`09-26-104336` 显示进程一起来就是 `refresh(full:)` 全量扫描写，225 秒 2GB——关着期间变过的会话全部整份重写。（高）
- **CPU 大头在解析不在写**：09-25 11:30 采样后台 283 样本里 187 在 `ClaudeCodeAdapter.parse`、96 在 `writeSession`；10:04 那份 703/705 在 `parseSession`。所以「只改写法」降写盘，不降 CPU。（高）

### 2.2 「打开 Code 必死」的机制链（v2 新增）

| 环 | 机制 | 证据 |
|---|---|---|
| (a) 详情每 ≤2s 整份重解析，**不受限流** | `flushIncremental` 发现正在看的文件变了就 `reloadDetail()`（`CodingSessionLibrary.swift:360-363`）；`loadDetail` 在后台 `adapter.parseTranscript(ref)` **整份**解析（:688-689）；不经过 `CodingParseThrottle`（那个只管索引写，:286、323）；解析完 `detail = .loaded(新 box)` + `detailRevision &+= 1`（:697-698）；`isRefreshingDetail` 在 :665 / :692 各翻一次，又两次失效 | 代码；10:04 后台 703/705 在 parse |
| (b) 主线程每轮整个详情重排 + 滚到底 | `loaded(_:)` 每次 body 对全部消息 `filter` + `Array(enumerated())`（`CodingSessionDetailView.swift:81-92`，O(N)）；`CodingMessageRow` 非 Equatable、带闭包，全部重跑；`MacCodingTranscriptScroll` 在 revision 变时 `position.scrollTo(edge: .bottom)`（:93-98）+ `.defaultScrollAnchor(.bottom, for: .sizeChanges)`（:48）——上万行、行高不一的 LazyVStack 滚到底要估算 / 放置大量行 | 代码；10:04 主线程那堆 `explicitAlignment` / `sizeThatFits` / `LazySubviewPlacements` |
| (c) 2 秒节流对渲染无效 | `lastIncrementalAt` 在 flush **开始**时记（:354）；SwiftUI 重排发生在 flush 返回后的 runloop 观察者阶段，不算进窗口；flush + 渲染 ≥2s 时下一次 `wait = 0`（:346）背靠背接着跑——那条 CC 还在写，主线程占空比接近 100% | 代码；10:04 前 22 秒连续 8 条回执 |
| (d) 重开也没用 | `restoreLeftPanelTab()`（`ContentView.swift:1812-1818`）：上次停在 Code 就启动即 `activate()`（`CodingSessionLibrary.swift:140-144`：同步 `reload()` + `refresh()` 全根扫描）；扫描期间每推进 200 条 `applyProgress` 还在主线程 `reloadProjects()`（:429-436）；叠上启动扫描（§2.1 L4） | 代码；`09-26-104336` |

还有一处放大：`ContentView` 自己读 `detail`（`ContentView.swift:1085-1089` 的悬浮条标题，以及 :1225-1233、1274、2020），所以每次详情刷新整个 ContentView 跟着重算，波及 `MacScrollbars` 整窗 NSView 递归（§3.1 A13）。

置信：中（现场一份 + 代码链闭合；行为要在 R1 的 M9-L1c 复现）。

### 2.3 Code 列表主线程 SQL

- `flushIncremental`（:352-364）→ `reload()`（:442-453）→ `reloadProjects()`（:463-479）：`listProjects` / `sessionCount` / `countSessions` / `presentAgents` / `childCounts` + 每个展开根 `listChildren` + 每个已加载项目流 `fetchPage`，全走 `openReader()`（:635-643）那条**主线程读写连接**，同步执行。Code 面板没开（`isActive == false`）也照跑。（高）
- **主线程同步 SQL 的全部入口**（v2 补全，K1 要全覆盖）：`activate()` :140-144；扫描期间 `applyProgress → reloadProjects` :429-436；扫描完成 `reload()` + `reloadDetail()` :247-253；`toggleRoot` :567；`loadPage / fetchPage` :603-633；`openSession / reveal` 最多连翻 20 页 :386-426；`recentlyActive`（菜单栏快看每 5 秒）:396-401；`loadDetail` 里的 `reader.session(key:)` :675。（高）
- **为什么冷**：WAL 下写连接每次提交都让 reader 的页缓存整体作废——**调大 `cache_size` 没用**（v1 的思路删掉）；`listProjects` rootsOnly 是 `SCAN s USING INDEX idx_sessions_project` + 每行 2 个关联子查询（Index :512 / :517）+ 临时 B 树排序，按索引顺序回表 = 在 988MB 文件里随机 `pread`（她的库是两周增量写出来的，sessions 的 ~835 页散在 ~780MB trigram 页之间）。（机制高）
- **同期 IO 来源：未定**（v2 改）。v1 写「赶上自家写盘拥堵」——**采样不支持**：3 份卡在 SQL 的采样（031500、040802 全程、032821 一半）里 `writeSession` / `pwrite` / `wal_checkpoint` 帧数都是 0。同期在跑的是 `SQLQueue for unified.store` 上同步引擎的全表计数（031500 1846 样本、032821 ~1040，本身就是大量 `pread`）；040802 后台计数只有 471，主线程照样卡在 `pread`，说明还有机器层面的 IO / 内存压力（审稿人引 `build-history.tsv`：09-28 09:07–09:44 编译几乎没停，第二段卡顿 09:17–09:23 正落在里面；我没再去核这份流水账）。所以：S1（删全表计数）对主线程卡顿的贡献可能比 v1 估的大，K2（差异写）主要是消写盘报告、对转菊花的直接作用可能被 v1 高估。（中）
- **`search()` 的做法不能照抄**：它每次 `CodingSessionIndex(url:)` 默认**读写**打开（`CodingSessionIndex.swift:86`，`readOnly` 默认 false），每开一次在 `migrationLock` 下跑 `PRAGMA journal_mode=WAL` + `migrate()`（:122-125），会和扫描器的大事务抢写锁；主线程 `openReader()` 也是读写打开。代码里已有 `readOnly: true` 路径（:85-118，AI 工具用）。K1 应改后台只读长连接。（高）

### 2.4 同步引擎：每 5 秒数 4 遍全库

- iCloud Drive 文件同步，按楼层开，她开了 ghost-lily。`SyncEngine.swift:39` 主线程 5 秒 Timer + 目录 kqueue 触发 `pump`；mac 基本不进 `.background`，开着就一直泵；每次 scenePhase `.active` 还 stop + start 立刻泵一次（`MemoryPalaceApp.swift:1196-1198`）。（高）
- `pump` 在后台 context 上 4 次无谓词全表 `fetchCount`（`[probe-5a]` :156-158、`[probe-5b]` :166-168），**没有 DEBUG 门**。（高）
- `importAll` / `exportChanged` 末尾无条件整份重写状态文件（`SyncStore.swift:655-656`、:324，~2KB，次要）；`exportChanged` 每次 fetch 整个楼层的 Conversation。（高）
- v1 写的「S1 后主 context 写入不再等后台读」**删掉**：WAL 下读不阻塞写，没有证据。

### 2.5 搜索索引回填（一次性，已过去）

`SearchIndexer.backfillStep`（:151/:160）→ `SearchIndexStore.apply`（:147-149），只在 `backfill_done != "1"` 时跑（`SearchIndexer.swift:86-90`）。`search-index.sqlite`（751MB）mtime 09-27 06:18，与那 3 份 disk writes + 1 份 cpu_resource 吻合 = 一次重建。每次启动 `quick_check` 读一遍 751MB（后台只读）。（高）

### 2.6 探针自身的开销

| 探针 | 什么包里开 | 开销 | 置信 |
|---|---|---|---|
| HangProbe | mac **全配置含 Release**（`MemoryPalaceApp.swift:620-628` 只有 `os(macOS)` 门），**无测试门** | 100ms 心跳；卡 ≥1s 起 `/usr/bin/sample`。Release 带 hardened runtime 且无 `get-task-allow`，`sample` 采自己**大概率直接失败**（未实证） | 高 / 中 |
| KBProbe | DEBUG（她日常包是 Debug） | `SidebarView.swift:757-767` 每次侧栏 body 同步 `print` + 写 `~/Documents/kb-probe.log`（10-01 已 16MB，mtime 跟着单测宿主在变） | 高 |
| probe-2 / probe-4 | DEBUG | 启动主线程 4 次全表计数（`MemoryPalaceApp.swift:670-671`、`:782-783`） | 高 |
| `[probe-5a/5b]` | **全配置** | §2.4 | 高 |
| BreadcrumbLog | 全配置 | 每次 add 80 条编码写 UserDefaults（已合并、后台写） | 中 |
| MetricsRecorder | DEBUG + PERF | mac 上 `Metrics` 目录不存在 = 从没收到过 payload | 中 |

## 3. 静态排查：mac 主线程上「点了会转菊花」的候选

> `文件:行号` 均在 mac worktree 核过（v2 新增条目注明谁核的）。量级标「证据」= 有现场栈 / 元数据；「推断」= 代码估算。

### 3.1 A 区：Code / Warroom / 侧栏 / 右栏 / 终端 / 窗口 / 偏好

| # | 候选 | 证据 | 触发 | 主线程上 | 量级 | 置信 |
|---|---|---|---|---|---|---|
| A3 | **Code 详情被写 → 整份重解析 + 整个详情重排 + 滚到底 + ContentView 重算**（§2.2） | §2.2 表 | Code 里开着一条正在被写的 CC 会话 | 见 §2.2 | **证据**：10:04 采样 2044/2099 | **中（v2 由「中 / 推断」升为有现场证据）** |
| A1 | 增量刷新整套同步 SQL | §2.3 | CC jsonl 被写 → ≤2s 一次（Code 关着也跑） | 5+ 条查询，主线程读写连接 | **证据**：3 份采样主线程全程 / 过半，单次 ≥1s（下界），一次 ≥4s | 高 |
| A2 | 她主动点的同步 SQL | `CodingSessionLibrary.swift:140-144`（activate）、:252、:386-426、:539-548、:567、:711-725 | 点 Code tab / 筛选 / 收藏 / 置顶 / 改名 / 展开根 / ⌘K 揭示 | 同步 `reload()` 或分页 | 同 A1（推断） | 高 |
| L4 | 启动扫描整份重写 + 扫描中每 200 条主线程 `reloadProjects` + `restoreLeftPanelTab` 直接 `activate` | `CodingSessionLibrary.swift:150-154、429-436`；`ContentView.swift:1812-1818`；`09-26-104336` | 启动（尤其上次停在 Code） | 后台写 + 主线程 SQL | **证据**：启动后 225 秒写 2GB | **中高（v2 升）** |
| A13 | 本机 SwiftTerm 终端 PTY / VT 解析 / 重绘在主线程（v2 新增，审稿人提出，我核过） | `MemoryPanelView.swift:135`（`terminal` = 本机终端，CC 桥终端是 `ccTerminal` :102）；SwiftTerm `LocalProcess.swift:112-117`（不传队列默认 `DispatchQueue.main`）；`LocalTerminalSession.swift:58、274-277`（`dataReceived` 在主线程，没选中的 tab 也照样解析） | 她在花园本机终端里跑 CC（Code 详情「回到终端」就是开它），TUI 转圈 + 整屏重绘 | 每个 tab 的读、解析、重绘 | 待 R1 证实量级；hangs.log 153/154 条回执带 `tool=terminal`（她的常态，基数大，不能单凭它归因） | 中 |
| A14 | 隐藏工具的周期性活（右栏 6 个工具 opacity 0 全挂着，`TabbedToolPanel.swift:52-61`；只有 AssistantPanel / LocalTerminalPanel 读 `isFrontmostTool`）（v2 新增） | a. 文件库面板 `FileLibraryPanelView.swift:68-70` 每 5 秒 → `checkForExternalChanges`（:659-665）→ `FileLibraryStore.list`（:230-251）**主线程递归枚举整个文件库，不跳过 `books`**（同一函数 input-jank C1 实测 546ms/次）——**我核过代码** | 每 5 秒 | 递归枚举 + resourceValues | 推断：她文件库体量相关，参照 546ms | a：中高 |
| A14b–g | 同上，子 agent 扫描、审稿人与我都没逐条核 | b. 日历面板 `CalendarPanelView.swift:34-44、92-94` `@Query` 拉楼层全部对话 + body 同步读盘（主 context 每 save 失效）；c. 书架 `BookStore.swift:320-361` 每 5 秒 N+1 次主 context fetch（可能顺带 save）；d. 推特面板 `TwitterPanelView.swift:187-192` 每 20 秒全量查询；e. 侧栏 `SidebarView.swift:1117` 收到 `.syncDidImport` 就 `refreshList`（同步开着约每 5 秒）；f. `MacScrollbars.swift:218-246` 每次更新递归遍历整窗 NSView 树（ContentView 每 ≤2s 更新一次时）；g. 菜单栏快看 `MacMenuBarQuickLook.swift:62-69 → recentlyActive` 主线程 SQL（菜单开着每 5 秒） | 各异 | — | 推断 | **中，待核** |
| A4 | Code 侧栏整表重算（与 X1 放置风暴合并成一刀） | `CodingSessionSidebarList.swift:195-206、257-262` | `select` 或 A1 改了列表 | `sessionRow` 是父 body 里的函数，任一属性变整列表 body 重跑 | 94 项目 + 每展开项目 ≤500 行（推断）；39.8s hang 形状吻合（§1.1，中低） | 中 |
| A5 | Warroom 面板 | `WarroomPanelView.swift:88-99、113-136、142-163`；`CCBridgeWebSocketClient.swift:859-866`；`ThemeManager.swift:95-105、339-351`；`Theme.swift:25-27` | 每 30s + hub 每推一次；在后台 tab 也跑 | 非 lazy 整体重排、分组 O(R×T)、`WarroomTask` 逐字段比较（长字符串 NFC）、每次 `Theme.x` 现算整套 token、看板 JSON 主线程解码两次、`lastRefresh` 每次新值 | **证据**：2 份采样 | 中 |
| A11 | 全局 `Theme.x` 每次访问现算整套 token | `Theme.swift:25-27` → `ThemeManager.swift:104` → :339-351（线性查主题表 + 整个 TokenSet 复制 + `UserDefaults.standard.bool` + 按壁纸再变换）；5159 处 `Theme.` 引用，**iOS / mac 共享** | 任何读主题色的 body | — | 采样里 Warroom 一份 139/2344 在这条链上 | 中 |
| A12 | 切回 app 那一刻顺带起后台重活 | `MemoryPalaceApp.swift:1196-1198`：每次 `.active` → `SyncEngine.start`（立刻泵 = 4 次全表计数）+ `SearchIndexer.requestReconcile`（每楼层 `fetchCount`） | 从终端切回来点第一下 | 后台，但和她点的那一下抢库 / IO | 推断 | 中低 |
| A6 | 右栏隐藏工具常驻（A14 的结构原因） | `TabbedToolPanel.swift:52-61`；`IPadPanelOverlay.swift:567-570` | — | 藏着的照样订阅、照样重算 | — | 中 |
| A7 | 停靠 / 浮窗切换整树重建 | `ContentView.swift:1823-1829`；`MacWorkspaceDock.swift:118` | 点切换钮 | 两棵树整体重建 | 推断 | 中低 |
| A8 | 侧栏 body 写探针日志 | `SidebarView.swift:757-767` | 每次侧栏 body（DEBUG） | `print` + 同步写文件 | 每次十几到几十 µs × body 次数 | 低 |
| A9 | 窗口配置每次更新重做 | `MemoryPalaceApp.swift:2087-2105` | 根视图每次更新 | 重设窗口属性 + 重新测量 | 推断 | 低 |
| A10 | 偏好写 | `IPadPanelLayout.swift:389-412`；`BreadcrumbLog.swift:40-52` | 收放面板、拖动 | 已合并每轮 runloop 一次；plist 287KB / 156 key，未复发 09-18 事故 | 低 | 高 |

### 3.2 B 区：聊天主路径

**现场证据很少**：除了 09-24 那份 CC thinking 采样（主线程 664/1546 在 `CCBridgeWebSocketClient.handleIncoming → applyCCThinking → SwiftData.fetch`，当时缺索引），B 区没有直接的现场卡顿栈。下表多为代码推断，R1 基线定序。

| # | 候选 | 证据 | 触发 | 主线程上 | 量级 | 置信 | 平台 |
|---|---|---|---|---|---|---|---|
| B1 | CC 流式帧在**非当前对话**里逐帧主 context 物化整条对话 | `CCBridgeWebSocketClient.swift:955-982` → `ConversationViewModel.swift:569-576、590-599` | CC 在别的对话里吐 thinking / edit，~150ms 一帧 | 按 conversationId 全物化、内存找 ccMessageId、`save()` | 09-24 证据（补索引前）；补索引后每帧仍物化 N 个节点，N=1–3k 推断每帧 30–150ms | 高 | 共享，mac 最重 |
| B2 | CC 流式改**当前对话**正文：每帧 `save()` + 同步整条重 parse + 冲掉 200 条 LRU | `ConversationViewModel.swift:553-565`；`CardFlowView.swift:3137-3147`；`MarkdownRenderCache.swift:73-79` | 当前对话 CC 流式 | 每帧 ≤3000 字同步 parse，结果冲掉 LRU，流完回翻全不中 | 推断 | 高（路径确定） | 共享 |
| B3 | 打开对话：`applyTreeData` 主线程整条对话全量再 fetch + `isLoading` 拆列表 | `ConversationViewModel.swift:941-957`；`CardFlowView.swift:626-636`；搜索 / 推送跳转 `:692-697` | 打开对话、⌘K / 推送点进 | 物化 N 个节点 + 可见行同步 parse + 新建 NSTextView | 推断 N=200 ~10–20ms、N=2000 >100ms + 重建 50–200ms | 中高 | 共享，iOS 冲刺也没修 |
| B4 | 带图 / 文件气泡每次 body 同步读盘 + 全尺寸解码 | `CardFlowView.swift:2995、3419`；`ChatBubbleStyle.swift:338`；`FileLibraryStore.swift:107-111、183-184、395-399` | 滚动、新消息 | segments 解码、附件读盘、`NSImage(data:)` 全尺寸 | 推断 10–100ms/张/次；文件库开 iCloud 时根在 `~/Library/Mobile Documents`，被「优化存储」清掉的文件主线程同步下载可到秒级 | 中 | 共享 |
| B5 | CardFlowView 任一次 body → 所有已显示行重跑 | `CardFlowView.swift:415-475`；`MemoryPalaceApp.swift:44-47`；`ChatMarkdownView.swift:108-178` | 新消息、CC 到达、高亮 | 每行解正则、建渲染配置、哈希正文 | 推断每行 0.3–1ms × 20–40 行 | 中 | 共享 |
| B6 | @AppStorage 扇出 | 每 BubbleView ~18 + ChatMarkdownView 5；`CCBridgeWebSocketClient.swift:315、320` 每条 reply / thinking 把去重表写进 UserDefaults | UserDefaults 任一写 | KVO 扇出 | 推断 | 中低 | 共享 |
| B7 | mac 输入框每键主 context `save()` | `MacChatComposerHost.swift:84-90、118-134` | 打字 | — | 推断每键 1–5ms | 中低 | mac |
| B8 | 正文宽度一变，所有已显示段落 TextKit 2 重排 | `Packages/SwiftStreamingMarkdown/.../ParagraphView.swift:137-166` | 拖窗口、开合面板 | 尺寸缓存全失效 | 推断 | 中低 | mac |
| B9 | 切楼层整树重建 | `MemoryPalaceApp.swift:1138、1363` | 切楼层 | 视图树全重建 + 侧栏 fetchCount | 推断 | 低中 | 共享 |
| B10 | 「数据与备份」页主线程同步读 iCloud manifest | `DataSettingsTab.swift:565` → `BackupStore.swift:43-66、699-705` | 打开该页 | dataless 时同步下载 | 推断 | 低中 | mac |
| B11 | ⌘K 点开结果 = B3 | `MacGlobalSearchPanel.swift:848-861` | 点开搜索结果 | 同 B3 | 中 | 中 | mac |

**iOS 冲刺的修复 mac 吃到了哪些**：O4（`ContentCleaner` 无平台门）✅、C2（`ContentView.swift:1751` 两端共用）✅、B1 面包屑后台写（`BreadcrumbLog.swift:44-55`）✅；O6 只对 iOS，但 mac 有等价 `MacMarkdownFontResolver`（`MarkdownConfig.swift:167`）；C1 / C3 / S1 / R6 / C5′ 是 UIKit 翻页结构，不适用。**两端都没修**：B3、A11。

### 3.3 C 区：启动

| # | 候选 | 证据 | 主线程上 | 量级 | 置信 |
|---|---|---|---|---|---|
| L1 | 换 schema 的包首启在主线程原地迁移她的真库 | `MemoryPalaceApp.swift:229`；`sample-20260930-100654.txt`（**单测宿主**） | Core Data 轻量迁移 + WAL checkpoint | **证据**：~1.07s；她日常同版本重启不发生，单测 / 工位包换着跑就会 | 高 |
| L2 | 迁移后自建索引要重建 | `MemoryPalaceApp.swift:209-212`（`MacStoreQueryIndexes.repair`，主线程读写打开） | `CREATE INDEX` × 3 | 09-24 副本 ~6s（推断：只在迁移重建表后） | 中 |
| L3 | 启动诊断计数 | `MemoryPalaceApp.swift:670-671、782-783`（DEBUG） | 4 次全表 count | 推断 | 高 |
| L4 | 见 §3.1 L4 | — | — | — | 中高 |
| L5 | SwiftData 持久化历史只增不减 | 代码里无 `deleteHistory` | 库体积持续涨（09-19 657MB → 10-01 1.31GB） | 元数据 + 推断 | 中 |

## 4. 测量相关的约束与风险

1. **单测宿主动她的真库（现场证据）**：TEST_HOST 是 app 本体，`makeUnifiedContainer` 无测试门——读写打开 `unified.store`、修索引、换 schema 时**主线程原地迁移**（§1.3 09-30 采样）；HangProbe（写她的 `hangs.log`、起 `sample`）、probe-2/4、各 fixup、BreadcrumbLog、KBProbe 照跑；她真实的 `sync-state/` 里有测试写的 `xctest-sync.*.json`（`SyncStoreTests.swift:34` 注释自己承认 `localStateDir` 不随 `overrideRoot` 隔离）。有门的只有 SearchIndexer、CalendarActivityIndex（`MemoryPalaceApp.swift:818`）、编程会话首扫（`CodingSessionLibrary.swift:154`）、`restoreLeftPanelTab`、SyncEngine（`NSClassFromString("XCTestCase")`）、MetricsRecorder。（高）
2. **bench 包换 bundle id 也挡不住的写入点**（v2 扩，审稿人列；Documents / iCloud / 时间机器 / 家目录 API 计数 / hub plist 我核过，CC hook 与额度请求按审稿人原文）：
   - `~/Documents`：`documentDirectory` 12 处 / 10 个文件（我核过计数）——`FileLibraryStore.swift:75` 的本地 floors 根（bench 种子的文件库会写进她真的 `~/Documents/<app>/floors`）、FeedbackStore、GlobalBackup/StagingPaths、VocabCorpusStore、BridgeProbe、WebSearchProbe、kb-probe。
   - **写死的 iCloud 路径** `~/Library/Mobile Documents/iCloud~com~susu~MemoryPalace/Documents`（`FileLibraryStore.swift:45-46`、`BackupStore.swift:41-51`、`BookStore.swift:296`、`SyncStore.swift:343`），绕开 bundle id 和 Application Support，`iCloudDocumentsRoot()` 无条件建目录；**时间机器**在 scenePhase `.background` 时 `snapshotIfNeeded` + `pruneOldBackups`（`MemoryPalaceApp.swift:1207-1222`）——bench 若带着她的设置（同偏好域，或克隆了她的数据）就会**按 manifest 删她的备份**。
   - 她的 CC workdir：`CCThinkingHookInstaller` 每次启动（`ContentView.swift:478-481`）读 `~/Desktop/cc-rp/.claude/settings.json`，hook 缺失时会写入指向 bench 根的路径。
   - 她的 CC 账号：`SubscriptionQuotaStore` 由 Code 详情 `.task` 触发（`CodingSessionDetailView.swift:390-394`），用 `security` 读她的 CC OAuth 凭据、请求 `api.anthropic.com/api/oauth/usage`——home 不走注入，**M8 一跑就会发生**。
   - 生产 hub：`HubTokenStore` 读 `~/Library/LaunchAgents/com.susu.cc-bridge-hub.plist`，CC 桥**客户端**会自动去连（违反「严禁对生产 hub 发测试流量」）。
   - 家目录 API：`homeDirectoryForCurrentUser` 15 处、`NSHomeDirectory()` 6 处、`getpwuid` 1 处（计数我核过）（`LocalTerminalLaunch.swift:27`）——`CFFIXED_USER_HOME` 就算对 FileManager 生效也盖不住 `getpwuid`。
   - **TCC**：新 bundle id = 全新隐私授权状态；第一次碰 `~/Documents`、`~/Desktop`、本地网络（ProxyDiscovery、hub）、日历 / 提醒、通知都会弹系统框——无人值守时一弹测量就卡死；她若点「允许」就等于给 bench 开了她 Documents / Desktop 的权限。
   - 钥匙串：她的 key 是她的包建的，换 id 的包去读会弹授权框。
   - **验证手段**：`lsof -p` 是瞬时快照，抓不到「打开-写-关」的原子写；她的 `unified.store` mtime 现在就会被别的工位的单测宿主改，mtime 判据只在门内可信。→ plan §3.2 改为代码层越界 trap + marker + `find -newer` + 网络侧核对。
3. **合成夹具复现不了她那个 988MB 编程会话索引的碎片化**：她的库两周增量写出来，sessions 页散落在 trigram 页之间；bulk 种子 + 冻结模板会让 sessions 页连续，冷读可能快一个数量级。→ 夹具用写入器回放增量「老化」；克隆她的 coding-index 要**单独**授权（里面有 CC 正文）。
4. **她日用 Debug 包**（`-Onone`）：现场最大的几类（SQLite `pread`、SwiftUI 布局）是系统库，与 Debug 关系不大；app 自己的 Swift（派生 Equatable、集合处理、`parse`）在 `-Onone` 下慢数倍。
5. **mac 没有 UI 自动化**；UI 测试打开无障碍树会让 SwiftUI 多算 AX 节点（iOS R1 B4 教训），**UI 回归和性能测量不能共用一次运行**；首跑要她给测试 runner 授权辅助功能。
6. **符号**：Debug dylib 214MB，UUID 每编一次变、旧的被覆盖。
7. **机器噪声**：10-01 03:18 的 `uptime` 1 分钟负载 182（10 核）；同时有多个 xcodebuild / swift-frontend、iOS 模拟器常驻、多个 CC 会话 + hub + Docker。没有负载门的数字不可比；白天几乎一直在编译，测量窗口会很稀。

## 5. 未查证 / 需要 R1 实测的点

1. M9-L1c（Code 详情开着一条 100MB 级、正在被写的会话）能否稳定复现 10:04 的渲染风暴；flush + 渲染的实际占空比。
2. 一次 `flushIncremental` 主线程几条 SQL、各多少毫秒；后台只读长连接 / mmap 各省多少。
3. 卡 SQL 时的 IO 来源：同步引擎计数 vs 机器 IO（L-io 档）。
4. `writeSession` 单次写入字节数与频率；活跃会话平均正文量。
5. 本机终端（A13）在 CC 刷屏时的主线程占比；隐藏工具（A14）里她现场实际开着哪几个。
6. 39.8s hang / 两次 `LazySubviewPlacements` cpu_resource 到底是哪个列表（SwiftUI 模板）。
7. 09-26（全周最重）和 09-27 10:29 / 10:45 两次启动期长卡是什么（采样已删）。
8. HangProbe ≥1s 触发里 App Nap 假阳性的比例；Release 下 `sample` 采自己是否必败。
9. `CFFIXED_USER_HOME` 对 `FileManager.urls(for:)` 是否生效（只决定改道代码量，不决定隔离是否充分——`getpwuid` 等仍要收口）。
10. 双观察者在 mac 上的 observer 顺序。

## 6. v2 核对记录：审稿人的事实更正，我回原始证据核的结果

| 审稿条目 | 我核的 | 结论 |
|---|---|---|
| 1：10:04 采样不是空闲 | `sample-20260928-100441.txt` 主线程 `flushObservers` 2044/2099；`CardFlowView` / `BubbleView` 0 处；渲染器帧 `ParagraphView.updateNSView`（:132、:134）等；后台 incremental 线程 703/705 在 `ClaudeCodeAdapter.parseSession`（Scanner :260 → Adapter :38 → :120） | **属实**，v1 误判 |
| 3：39.8s hang 与 11:30 采样不同进程、11:30 无 reload 帧 | `.hang` PID 73806 / Fork 4493s；11:30 采样 `Process: 记忆花园 [36536]`、Launch 02:36:49；`CodingSessionLibrary.reload` 在 11:30、11:35 两份里都 0 处；`09-25-010905` disk writes 同 PID 73806 | **属实**，v1 错 |
| 4：卡 SQL 的采样里没有自家写盘 | 031500 / 032821 / 040802 三份 `writeSession` / `pwrite` / `wal_checkpoint` 计数全 0；SQLQueue 线程 031500 2225、032821 1195、040802 471 | **属实**；`build-history.tsv` 那条佐证我**没核**，照审稿人原话标注 |
| 4：时长是触发值 | `HangProbe.swift:52-55` 首次越过 1s 即记、即采样 | **属实** |
| 5：09-30 / 10-01 采样是单测宿主 | 09-30 采样加载 `libXCTestBundleInject.dylib`；10-01 采样 84 处 XCTest | **属实** |
| 5：09-26 未归因 | `start pid` 当天 131 次 | 属实 |
| 5：probe-2 / probe-4 行号 | 计数调用实际在 `:670-671` / `:782-783`；审稿人写 :667-672 / :780-784（含注释），我 v1 写 :669-673 / :781-785（含 `#if`）。**两边都只是范围取法不同**，v2 统一引计数调用那两行 | 小分歧，不影响结论 |
| 2：L4 有直接证据 | `09-26-104336` PID 22038、Date/Time 10:39:47 与 hangs.log `start pid=22038` 同秒、Duration 225s、栈 `refresh(full:) → run(:108)` | **属实**，v1 把它混进增量写 |
| 6：`tool=terminal` 是本机终端 | `MemoryPanelView.swift:102`（`ccTerminal`）/ :135（`terminal`）；SwiftTerm `LocalProcess.swift:112-117` 默认 main | **属实**，v1 挂错了组件 |
| 7a：文件库面板每 5 秒主线程枚举 | `FileLibraryPanelView.swift:68`（`Timer.publish(every: 5, on: .main)`）→ :659-665 → `FileLibraryStore.list` 无 `skippingTopLevelDirs` | **属实** |
| 8：Documents / iCloud / 时间机器 / home API / hub | `documentDirectory` 12 处 / 10 文件；`FileLibraryStore.swift:45-46`；`MemoryPalaceApp.swift:1207-1222`；`homeDirectoryForCurrentUser` 15、`NSHomeDirectory()` 6、`getpwuid` `LocalTerminalLaunch.swift:27`；`HubTokenStore.swift:13` 读 LaunchAgents plist | **属实**（CC hook、额度请求两项按审稿人原文，未逐条核） |
| 15：`search()` 读写开连接、`readOnly` 路径已有 | `CodingSessionIndex.swift:86` 默认 false、:85-118 | **属实** |
| 4：「031500 那次实际 ≥4.1s」 | 触发值 1.1s + 3 秒采样主线程全程在查询里 | 方向属实；严格说是「主线程连续 ≥~4s 没回到 runloop」，可能是几条查询首尾相接而不是一条，v2 写「连续 ≥4s」 |

## §7 10-16 重核（sol）

### 7.1 基点、范围与阻塞

> §7.1–§7.4 保留 S0 静态提交时点的判断；16:55 后获准的现场补证、当前刀序以 §7.5–§7.7 为准。H1 / S1 / P1 已陆续提交，不把下表的旧状态当作未实现。

- **S0 状态：BLOCKED（现场日志缺口）；静态重核完成，不改产品代码。** 最初核到的 HEAD 为 `67fc88434acdb005de2c021a04537444b51368d6`，不是任务书的 `922b9734c`，也不是 NOW 的 `f7ee00081`；已提示校准，未改 NOW。执行中已重读车头通知的 v2 任务书（`c91baca81`）：mac 编译有明确豁免、验证后可自行提交接续，但未解除硬规矩 2 的数据禁读。
- 本节行号来自 **mac 工位当前文件**。CodeGraph 返回了主仓并提示跨 worktree，本轮未用它的源码定位作证。状态「仍在」只证明代码机制仍在，**不是当前耗时实测**；「部分修」明确保留剩余路径；旧章节仍是 10-01 历史口径，不代表本期现场。
- 未启动、退出、采样或操作她的 app；未 build/test，未碰生产 hub、真库、聊天、Documents 内容或 Backups。S0 没有可声称的测试 `passed`。
- `Utils/HangProbe.swift:13-17` 的日志根为 `~/Library/Application Support/MemoryPalace/perf/`，正处硬规矩 2「不读写其下任何东西」的禁区；**该目录未列举、日志未读**。S0a 要求读日志与此冲突，不能擅自当作例外。需车头提供脱敏副本，或粟粟明确授权仅 `perf/` 日志只读；其余数据根继续禁读。
- 仅读了两个明确布局键：`defaults read com.susu.MemoryPalace ipad.panel.layout.v2`、`defaults read com.susu.MemoryPalace mac.workspace.preferences.v1`。命令返回的是自带省略号的 NSData 摘要（1242 / 1311 bytes），不能恢复工具列表；未 dump 整域、未改偏好。即使能取出当前工具，也不能证明 CC 实际跑在哪个终端。**N3 仍未答，不作止血前置。**
- 系统证据摘要（不入 git，1 个文件）：`~/MemoryPalace-docs-media/perf-mac/sol/S0-system-report-inventory.md`。未复制原报告、原日志或截图进仓库。

### 7.2 本期现场表：没有可归因的 spin，不能编造频次

2026-10-16 16:02–16:05 -0700 核查了用户 / 系统 DiagnosticReports 及各自 Retired（两个 Retired 均为空），递归匹配花园文件名、检查 `.diag` 进程头与 `.ips` 进程字段，并补查通用报告的花园 Powerstats 段。**现存目录不保证保留了 10-01 后全部历史**；「未找到」不等于「没发生 / 不再卡 / 未使用」。下表的 0 是找到的目标报告数，不是卡顿次数。

| 类别 | 次数 | 最长时长（下界 / 真值） | 代表报告文件名 | 主线程自有帧 文件:行号 |
|---|---|---|---|---|
| 花园专属 `.spin` | 0 份可见 | 无观测，不能填 0s | 无 | 无可归因栈 |
| 花园专属 `.hang` | 0 份可见 | 无观测 | 无 | 无可归因栈 |
| 花园专属 `.cpu_resource` / `.cpu_resource.diag` | 0 份可见 | 无观测 | 无 | 无可归因栈 |
| 花园专属 `.diskwrites` / 写盘 `.diag` | 0 份可见 | 无观测 | 无 | 无可归因栈 |
| 花园 `.ips` | 0 份目标进程报告 | 无观测 | 现存两个 ips 为 JetsamEvent / sanity_check_for_c.exe，均非目标进程 | 无 |
| 通用 daily IO 中的花园段（补查，不算 hang） | **2 份**，分别 6 / 8 段、187 / 211 个写盘 samples | **不可判卡顿时长**；86400s / 82842s 是全机统计窗真值，不是 app hang，也不是其下界 | `disk writes_2026-10-14-211845_mimiair.diag`；`disk writes_2026-10-15-201842_mimiair.diag` | 无 main 标记；`imageIndex + offset` 未符号化，不能套当前源码 |
| WindowServer CPU 报告中的花园附属段（不算花园 CPU 违规） | 1 段、11 samples | **不可判卡顿时长**；140.536s 是采样覆盖窗真值 | `WindowServer_2026-10-15-181706_mimiair.cpu_resource.diag` | `start → ??? → UUID FC2D3FCD…`，无 main 标记 / 自有符号 |
| HangProbe | **未获准读取，次数未知** | 未知；当前实现的触发行仍只是下界 | 未枚举 | 未读取，不能归因 |

通用报告逐份拆分记录：

- 10-14 daily IO：花园段起始行 **14863 / 23468 / 34862 / 34930 / 38969 / 41987**，samples 为 136 / 40 / 4 / 4 / 2 / 1。UUID 表索引 183 / 468 / 289 / 4 / 28 / 51；有路径的镜像来自多个 DerivedData 工位，不能认作一个日常进程。
- 10-15 daily IO：花园段起始行 **23712 / 27819 / 32782 / 33647 / 36007 / 38683 / 44353 / 47539**，samples 为 106 / 48 / 19 / 17 / 11 / 7 / 2 / 1。UUID 表索引 180 / 471 / 72 / 697 / 653 / 624 / 105 / 294。同样没有线程身份，不能把采样数当事件数。
- WindowServer：花园段 **1788-1799**，栈 **1802 起**；主二进制 UUID `1BE80A79-8D1A-3B83-BFD8-01149837DB8A`。这是其他进程报告的附属段，不是本 app 的 spin。
- `coresymbolicationd_2026-10-16-115130_mimiair.diag:15,65-119` 和 `mds_stores_2026-10-14-224700_mimiair.diag:1586,1625-1626` 仅含 behalf-of 花园的符号化来源，不含花园主线程，不能补进卡顿分类。

**结论边界**：本期无法按「顶层自有帧 → 次数 → 最长时长」排病因。不能把 §1.3 的 09-28 SQL 6 份、详情 1 份、Warroom 1 份混成本期数据；不能凭通用写盘报告恢复 K2 的现场定罪。当前无证据确认 10-01 没列的新性能病。

### 7.3 当前代码候选表

表内路径除 `Packages/…`、`project.yml`、`docs/…` 外均相对 `MemoryPalace/`；同一文件的后续 `:行号` 沿用上一文件名。刀名是对应计划项，不是新增范围。

| 候选 / 刀 | 当前状态 | 当前文件:行号与核到的变化 | 处置 |
|---|---|---|---|
| A1 | 仍在 | `Services/CodingSessions/CodingSessionLibrary.swift:13-14,352-363,442-479`：MainActor 的 flush 无 inactive 门，重跑项目 / 计数 / children / 已加载分页 SQL | K1-dirty 止血；K1 完整版后移 |
| A2 | 仍在 | `CodingSessionLibrary.swift:140-143,387-426,539-548,561-569,711-725`：activate、揭示 / 翻页、筛选、收藏 / 置顶 / 改名仍同步查询 | K1 覆盖所有入口 |
| A3 / K0 | **部分修** | `Views/CodingSessions/MacCodingTranscriptScroll.swift:48,93-97` 已按 `policy.shouldFollow` 决定滚底；但 `CodingSessionLibrary.swift:659-698` 仍整份 parse、成功必换 detail / 加 revision；`Views/CodingSessions/CodingSessionDetailView.swift:82,89-96,488-495` 仍 filter + enumerated 重建、行非 Equatable；`Views/ContentView.swift:1215-1225` 仍读 shared detail | 保留已有滚动意图；K0-min 先止血，K0 增量完整版待 R1 |
| A4 / X1 | 仍在（**风暴归因仍待 trace**） | `Views/CodingSessions/CodingSessionSidebarList.swift:193-209,217-228,257-263`：父 body 函数行、嵌套 ForEach/if 未变 | 结构候选仍在不等于已确认 39.8s hang 的归属；R1 后定刀 |
| A5 / W1 | **部分修** | `Services/CCBridgeWebSocketClient.swift:138,2191-2225,2244-2247,2303-2310` JSON 文本已在 parseQueue 解一次；主线程 snapshot / 面板仍各 `WarroomTask.from` 一次。`Views/Warroom/WarroomPanelView.swift:9-67,112-169,239-277,346-347,392-396` 仍全字段 Hashable、非 lazy、重复分组、lastRefresh 依赖、30s Timer | W1 不能再写「主线程 JSON 文本解两次」；剩余物化 / 比较 / 失效待测 |
| A6 | 仍在 | `Views/iPad/TabbedToolPanel.swift:51-63`、`Views/iPad/IPadPanelOverlay.swift:563-573`：opacity 隐藏仍挂树；frontmost 消费仅 Assistant / LocalTerminal，后者只管 first responder | 不能靠 onDisappear 停隐藏工具；按工具逐刀，不拆终端存活状态 |
| A7 | 仍在 | `Views/ContentView.swift:2023-2030,2109-2111,2151-2153`、`Views/iPad/MacWorkspaceDock.swift:117-119`：mode 仍替换 docked / floating 两棵树 | R1 后再定结构刀 |
| A8 | 仍在 | `Views/SidebarView.swift:922-935`、`Utils/KBProbe.swift:10-34`：DEBUG body 同步 print + KBProbe 锁内写盘 | 并入 P1，仅处理剩余探针 |
| A9 | 仍在 | `MemoryPalaceApp.swift:1353,2328-2345`：WindowConfigurator update 无同值门、仍重设属性并 measure；autosave prune 已有一次性门 | 不再把 prune 当每次更新成本；窗口配置候选后移 |
| A10 | 原缓解保持，**不再下刀** | `Views/iPad/IPadPanelLayout.swift:395-413` 合并一次 runloop 存档；`Services/BreadcrumbLog.swift:41-56` 后台串行编码 / 写偏好（不是两者都合并） | 现状保持，不声称完全没有偏好成本 |
| A11 / T1（主题刀） | 仍在 | `Utils/Theme.swift:25-38`、`Utils/ThemeManager.swift:95-104,135-136,339-350,380-386`：每次读仍算完整 tokens、查表 / 变换 / 读透明开关；themeChangeID 非缓存 | 共享主题刀待 R1；本轮禁碰 iOS 构建 |
| A12 | 仍在 | `MemoryPalaceApp.swift:1427-1434`、`Services/SyncEngine.swift:24-45,140-169`、`Services/Search/SearchIndexer.swift:278-328`：active 仍重启 pump / reconcile，逐层 count / 查询 | S1 只删其中诊断计数，不代表 A12 全修 |
| A13 | **主线程 delegate/feed 仍在，旧说法需修正** | `Packages/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:112-120,140-165,276-283`：PTY read 已在 readQueue，但 delegate 默认 main；`Packages/SwiftTerm/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift:86,183-184` 未传队列；`Services/LocalTerminal/LocalTerminalSession.swift:274-276` 仍 feed | 不是「PTY read 本身全在主线程」；N3 + L-term 测出量级后再动解析 / feed |
| A14a | **部分修** | `Views/FileLibraryPanelView.swift:27-37,103-104,139-145,1350-1364`、`Services/FileLibraryStore.swift:247-273,442-444`：枚举已 detached；mac active 恒真、opacity 隐藏仍每5秒跑，freshList 未跳过 books | 后移：只剩 frontmost 门 / 补刷、跳过 books；不重复做后台枚举 |
| A14b | 仍在，现已逐条核 | `Views/CalendarPanelView.swift:30,34-42,92-93,487-493,563-564,592-594,652-655`：全楼层 @Query、selectedDiary / 年视图同步读盘、monthCycleMarks 同步 fetch | 日期 / 索引化与缓存待 R1，不能直接归因为本期卡顿 |
| A14c | **部分修** | `Views/Reading/BookshelfView.swift:130-135`、`Services/BookStore.swift:277-361`：5秒 Timer 未加 frontmost；盘 / JSON 已后台化、同值不赋 / 无变更不 save；主线程逐书 fetch + 全量清孤儿仍在 | 后移：frontmost / 合并刷新 / N+1；不重复改已后台的盘读 |
| A14d | 仍在，修正旧描述 | `Views/Twitter/TwitterPanelView.swift:187-192,533-537`、`Services/Twitter/TwitterNotifications.swift:24-76,93-96`：20秒主 context 查询他人推 / likes / follows / targets，200仅裁输出不限制输入 | 不是一条「全量推文查询」；输入边界与隐藏停待测 |
| A14e | 仍在，修正频率 | `Views/SidebarView.swift:1286-1287,3855-3868,3901-4008`、`Services/SyncEngine.swift:39-45,170-180`：syncDidImport 仍直接 refreshList / count / fetch；仅 hadWork 才通知，且导出也算 | 不能再称「无条件每5秒刷新侧栏」；相关变更 / 合并刷新后移 |
| A14f | 仍在 | `Views/iPad/MacScrollbars.swift:217-246`：update / layout 合并到下一 main runloop 后仍递归整窗、只跳 WKWebView，无轮询 Timer | 同值 / 窄触发待 R1；合并不等于省掉遍历 |
| A14g | 仍在 | `Views/iPad/MacMenuBarQuickLook.swift:62-68`、`CodingSessionLibrary.swift:13-14,396-400`：菜单 task 存活时5秒同步 recentlyActive SQL | 归 K1 完整版，关闭菜单 task 取消已有 |
| B1 / C1 | 仍在 | `Services/CCBridgeWebSocketClient.swift:2414-2427`、`ViewModels/ConversationViewModel.swift:581-608,615-632`：非当前对话每帧主 context 全量 fetch、内存找 ccMessageId、save | C1 待 R1-L2，未新增到止血 |
| B2 / C1 | 仍在 | `ConversationViewModel.swift:583-596,2089-2092`、`Views/CardFlowView.swift:543-547`、`Utils/MarkdownRenderCache.swift:223-226,286-300`：自有 turn 已有 transient，但 CC edit streaming 未接，仍逐帧 save / 非 transient parse 缓存 | 不把自有 API 流式优化当 CC 路径已修 |
| B3 / O1 | 仍在 | `ConversationViewModel.swift:802-803,1019-1035`、`Views/CardFlowView.swift:791-804`：loading 清路径 / 拆列表，主 context 全会话 refetch | O1 待 R1 |
| B4 / O2 | 仍在 | `Views/CardFlowView.swift:4212,3706-3709`、`Views/ChatBubbleStyle.swift:353-359`、`Models/MessageSegment.swift:241-248`、`Services/AttachmentStore.swift:174-177`、`Services/FileLibraryStore.swift:658-663`：body hydration 同步盘读，mac NSImage(data:) 全尺寸解码 | O2 待 R1，不读真实附件取证 |
| B5 / O3 | 仍在 | `Views/CardFlowView.swift:591-596,873-890,3752-3775`、`Utils/ChatPerfSwitch.swift:7`、`Views/ChatMarkdownView.swift:177-198,227-234`：行非 Equatable；A3快照 / segments实验默认关，关闭时仍逐行解 regex | 实验默认关不算已覆盖；O3 待测 |
| B6 | 仍在（部分写已后台） | `Views/CardFlowView.swift:3780-3814`、`Views/ChatMarkdownView.swift:63-64,95-96`、`Services/CCBridgeWebSocketClient.swift:921-927,1980-1984,2392-2439,2440`：去重写挪到 handlersQueue，但 reply / final thinking / 主线程游标仍写 UserDefaults | 后移；不能把挪线程等同消除偏好扇出 |
| B7 / I1 | 仍在 | `Views/Chat/MacChatComposerHost.swift:95-100,127-143`：逐键 draftText + save；退出 / 失活 flush 未代替逐键保存 | I1 待测，保住草稿契约 |
| B8 | 仍在 | `Packages/SwiftStreamingMarkdown/Sources/MarkdownText/UI/ParagraphView.swift:145-176`：按宽度 key 缓存，新宽度逐段 sizeThatFits | 窗口 / 面板基线后定 |
| B9 | 仍在 | `MemoryPalaceApp.swift:274-285,1365-1366`：切 profile 仍靠 .id 重建 ContentView | 后移；不可删掉 stale-ref 防御 |
| B10 | 仍在 | `Views/DataSettingsTab.swift:357-359,578`、`Services/BackupStore.swift:652-653,701-705`：主线程同步读 manifest | 后移，不读取她的备份 |
| B11 / O1 | 仍在 | `Views/iPad/MacGlobalSearchPanel.swift:848-866`、`ConversationViewModel.swift:721-735`：搜索导航仍先整会话 fetch，再走 B3 | O1 包含搜索落点，不能只修侧栏 |
| L1 | 仍在 | `MemoryPalaceApp.swift:241-262,842,892-899`：同步容器创建 / schema及legacy迁移；测试隔离不消除启动同步机制 | 后移 |
| L2 | 仍在 | `MemoryPalaceApp.swift:241-245`、`Services/MacStoreQueryIndexes.swift:27-30,73-80`：读写 repair，只补缺失但缺失时同步 CREATE INDEX | 与 L1 后移 |
| L3 | **已修，不重复做** | `MemoryPalaceApp.swift:840-844,991-1035` 已无 probe-2/4；`:1070,1261` 剩的是功能计数 | P1 删除启动四次诊断计数子项销号 |
| L4 | 仍在 | `Views/ContentView.swift:2013-2017,2257`、`CodingSessionLibrary.swift:152-165,232-254,429-435`：6秒后扫描，进度200条 / 完成时主线程 SQL，恢复 Code 仍 activate | R-tab 止血；完整扫描成本归 K1/K2/K4 |
| L5 | 清理机制仍未见；**当前体积未知** | `MemoryPalaceApp.swift:254-262` 无历史清理；当前 app 无 deleteHistory / deletePersistentHistory / purgePersistentHistory 调用 | 不沿用旧1.31GB为当前体积；清理策略不纳入止血 |
| K0-min | **四点均未落地** | `CodingSessionLibrary.swift:655-698` 无详情下限、`:342-354` 在 flush 开头计时、`:662-668,692` 静默仍翻 refreshing、`:694-698` 同值仍换 detail / revision。索引 throttle 在 `:283-302,323-324`，不覆盖详情 | 保留四点原刀；尊重已有 policy.shouldFollow |
| K1 / K1-dirty | 均未落地 | `CodingSessionLibrary.swift:635-643` 主线程缓存 reader 默认读写；`Services/CodingSessions/CodingSessionIndex.swift:86,93-94,120-125` 默认 READWRITE/CREATE + migration；flush 无 inactive 门。`:369-377` 的 search 虽 detached 仍每次读写打开 | dirty 先止血；不能照抄 search 当只读长连接 |
| K2 | 未落地 | `Services/CodingSessions/CodingSessionScanner.swift:126-154,256-264` watcher 无 mtime/size guard，整 parse；`CodingSessionIndex.swift:178-209,266-278` 全删重插 messages/FTS，`:123-124` 仅 WAL/NORMAL | 差异写 / PRAGMA 留 R1 后；本期不能宣称已确认写盘违规 |
| K3 | 未落地 | `CodingSessionLibrary.swift:146-149,279-330` 关闭不停 watcher，scanner 全量正文 / FTS；`CodingSessionScanner.swift:83-93` quickMeta 预写后仍整写 | 新鲜度取舍仍后移，N1不等于批准K3 |
| K4 | 未落地 | `CodingSessionScanner.swift:260`、`Services/CodingSessions/CodingSessionAdapter.swift:17-18`、`Services/CodingSessions/Adapters/ClaudeCodeAdapter.swift:37-43,96-120`、`Services/CodingSessions/CodingParse.swift:11-18`：整文件 parse，无 offset / 续读契约 | 索引尾解析后移；详情路径归 K0 完整版 |
| S1 | 仍在 | `Services/SyncEngine.swift:39-45,154-169` 5秒 pump 四次无谓词全表计数，无 DEBUG 门；`Services/SyncStore.swift:217-234,324,655-657` 状态仍无条件 atomic write | 保留止血；正文JSON同值跳过不代表状态同值不写 |
| P1 | **部分已修** | L3 四次启动 count 已删；`Utils/KBProbe.swift:10-34` 仍 DEBUG enabled=true、同步锁内写；调用含 `Views/SidebarView.swift:930-935`、`Services/BookStore.swift:359-364` | 只做 KBProbe 默认关 / 后台写及相关同步 print 门，不重加旧计数作回退 |
| R-tab | 未落地 | `Views/ContentView.swift:2013-2017,2040`、`Services/MacWorkspacePreferences.swift:34-35,51-54`：Code启用时仍恢复持久Code并activate；没有独立启动恢复开关 | N2已批，`mp.stanch.R-tab=YES` 默认不自动回Code，NO恢复原行为 |
| H1 | 未落地（含测试门） | `Utils/HangProbe.swift:39-49,52-78,103-118,128-145`：只 start 行带pid，无包身份；ack仅active写时长；sample仍1s / 300s cooldown；无测试门。`MemoryPalaceApp.swift:800-804` 无条件启动 | 第一刀；每行身份 / 后台时长 / 上下文 / 500ms及测试门；真时长只能称心跳往返，不能当系统hang精确时长 |
| T5-b / T5-min | **临时持久根已覆盖；不起探针未覆盖** | `project.yml:534-545`、生成scheme `MemoryPalaceTests.xcscheme:70-80` 有 CFFIXED_USER_HOME + MP_TEST_HOST；`MemoryPalaceApp.swift:708-722` 在App.main前装隔离；`Utils/TestHostIsolation.swift:66-99,110-137,154-175,180-224,251-288` 核路径 / 换suite / 临时钥匙串 / 副作用闸，失败exit78。H1仍无测试门 | **不再做第二套临时store**；仅把测试不起HangProbe并入H1。隔离当前仅静态确认，本轮未跑宿主；旧验收见 `docs/review-test-host-isolation.md:7-18,26-30`，不能冒充本轮实测 |

**K1 八类入口未漏项**：activate `CodingSessionLibrary.swift:140-143`；扫描进度 `:241-243,429-435`；扫描完成 `:247-253`；toggleRoot `:561-569`；loadPage/fetchPage `:603-633`；openSession/reveal `:387-390,403-426,579-582`；recentlyActive `:396-400`；loadDetail取meta `:659-675`。均仍在 MainActor 使用同一默认读写 reader；后台 transcript parse 不代表 meta SQL 已后台化。

其他诊断 / 隔离候选：HangProbe样本阈值、Release self-sample权限（T6）仍未实证，后者留R1；MetricsRecorder 没有本期 payload 证据，不能沿用旧「目录为空」当当前事实；测试宿主完整家目录隔离已有 #035，但这不等于 bench 包的 T1-a 隔离已实现，更不能拿其旧验收替代新包的 marker / 网络实证。

### 7.4 原暂定刀单（S0 静态时点；已由 §7.7 替代）

**本期归因频次未知，最终重排 BLOCKED。** 解除日志只读冲突后，先按每份样本的 pid / 包身份和主线程自有帧补表，再定序；不把「没新专属报告」当修复收益。当前仅能依据旧现场与仍在的机制维护最小止血队列：

1. **H1 必须第一刀**：时长 / 每行身份 / 工具上下文 / 测试门；T5已有根隔离，只补不起探针，不新建第二套根。
2. **S1 → P1剩余项 → K0-min → K1-dirty → R-tab**：暂保留 §4 原序（N1=a、N2=a、T5=b 已批），不是依据本期频次排名。L3已修，从P1删除；K0必须保住现有底部跟随策略；R-tab开关语义按「止血默认开」统一。
3. **后移**：K0增量 / K1全入口 / K2写盘 / X1+A4 / W1 / T1 / C1 / O1–O3 / I1 / 其他 B、L；A13、A14剩余项待 N3 与 R1。A14a后台枚举、A14c后台盘读和dirty-only save、W1文本解码、A10原缓解不重复实现。
4. **新病**：没有本期可归因证据，不新加产品刀。新发现的是**旧计划过时的边界**：T5根隔离已做但HangProbe仍起、文件库枚举已后台化、Warroom JSON解析已移出主线程；这些是重核更正，不是本期新性能归因。

**解阻推荐**：车头提供 `hangs*.log` 与 `sample-*.txt` 的脱敏副本到 `~/MemoryPalace-docs-media/perf-mac/sol/`（遵守每切片≤5文件、单个≤1MB，必要时只保留栈和元数据）；或粟粟明确给原 `perf/` 子目录只读例外。**车头16:18补充裁决**：S0静态部分先提交；S0a待授权，不阻塞H1及后续暂定止血刀。授权下来后补S0a并重排，不提前读取原日志或启动她的app。

### 7.5 S0a 获准现场补证（10-16 17:09，产品基点 `f6420e9a8`）

- 粟粟已批 `~/Library/Application Support/MemoryPalace/perf/` **只读**例外；逐份读取了目录中 20 份采样的主线程树、镜像身份和元数据，并筛取 `hangs.log` 的 start / hang / busy 元数据。未改删原件，未读取其余数据根、文件库实际内容或操作她的 app。
- **20 份中 14 份有 XCTest 注入 / tests bundle，只有 6 份未见测试注入**；全部来自 DerivedData Debug，不是一个统一包的生产基线。`Main Thread / DispatchQueue_<multiple>` 也必须算主线程：最终是 **19 份有主线程树、1 份空图**；首轮仅匹配队列名曾漏识别，已按原件校正，不能把漏识别写成空闲。
- 本期日志（10-01 至 10-16）有 **236 条 start、1101 条 hang 触发下界、13 条 active 应答、195 条 CPU busy**；均为记录数，不是独立卡顿次数或前台小时率。203 个不同采样文件引用只保留了 20 份，**缺失 183 份，不能恢复全部历史归因**；旧日志又没有逐行 pid / UUID，不能从最近一条 start 硬接其他进程的应答。
- 最长未留样触发行是 **23.0s 下界**（10-03 17:57:05）；最长 active 应答是 **15.15s 心跳往返观测**（10-03 10:31:10），仍含后台队列等因素，**不是已定位系统 hang 真值**，两者都无法归给下表某个产品帧。`busy ... 11s` 是 CPU 检测窗口，不是主线程 hang 时长；采样数不换算秒。
- 补查两级 DiagnosticReports / Retired，只新增本轮 H1 单测产生的 `记忆花园-2026-10-16-163716.ips`（终端速率初始化下溢，已修并回归）；明确排除日常频次。仍无可归因日常使用的专属 `.spin` / `.hang` 等报告。§7.2 通用 Powerstats 不补造主线程归因。

**取证摘录均不入 git**：`~/MemoryPalace-docs-media/perf-mac/sol/S0a-hang-log-metadata.txt`（3911 bytes）、`S0a-samples-early.md`（15106 bytes）、`S0a-samples-late.md`（13233 bytes）。后两份各有 10 行逐份表及解释，含主线程边界、dominant 分支、PID、Launch、DerivedData、代码镜像 UUID、测试注入证据和原报告行号；没有只读聚合 top-of-stack 代替逐栈。原 S0 摘要仍保留，共 4 个取证文件，均 <1MB。

### 7.6 本期主线程归因表

**次数 = 保留采样中出现该工作链的报告份数，非互斥、不可相加，也不是用户点击次数。** 下界来自同份报告的触发行，不是该帧的独占耗时；“空闲 + 工作”不能整体归成空闲，更不能反证粟粟没有转菊花。路径仍按 §7.3 的相对约定；旧报告源行与当前源码分别列出，不拿当前二进制硬套旧包地址。

| 类别 | 次数 | 最长时长（下界 / 真值） | 代表报告文件名 | 主线程自有帧 文件:行号 |
|---|---:|---|---|---|
| **非测试：启动同步读楼层 manifest（新病 L-manifest）** | **2 / 6** | 触发 **≥1.0s**；未取得完整恢复时长 | `sample-20261012-111358.txt`、`sample-20261016-153807.txt` | 报告 `FileLibraryStore.writeManifest:972 / :673` → `Data(contentsOf:)` → `read/open`；当前 `Services/FileLibraryStore.swift:978`，启动调用 `MemoryPalaceApp.swift:871`。两份分别有 2602/2603、2566/2568 样本在该读取链，**不是秒数** |
| **非测试：Code 增量刷新主线程 SQL** | **2 / 6** | 触发最高 **≥1.4s**；未取得 SQL 独占/完整 hang 时长 | `sample-20261012-112449.txt`、`sample-20261012-114847.txt` | `CodingSessionLibrary.flushIncremental → reloadProjects`；报告/当前 `Services/CodingSessions/CodingSessionLibrary.swift:358,467`、`CodingSessionIndex.swift:986` → SQLite `pread`。204、396 样本的增量工作分支确实存在，虽其余样本多为 runloop 等待 |
| 非测试：同步后侧栏重新查询 | 2 / 6（与下一行等重叠） | 同份触发 **≥1.0s**；不证明侧栏阻塞整段 | `sample-20261012-114246.txt`、`sample-20261012-114847.txt` | `SyncEngine.pump → SidebarView.refreshList/fetchPage`；报告 `SidebarView.swift:3852,3997`，当前 `Views/SidebarView.swift:3858,4006` 及后续 fetch；主线程独立 async 根分别 9、4 样本，不能混作后台 |
| 非测试：SwiftUI layout / GraphHost 更新 | 2 / 6（与 SQL / 同步重叠） | 同份触发 **≥1.0s**；无当前风暴时长证据 | `sample-20261012-114246.txt`、`sample-20261012-114847.txt` | 系统 `NSHostingView.layout / GraphHost` 为主，未定位可独占归因的产品 body；分别有 100/134 与 36/129 样本的 layout/observer 工作。**不能据此指认 CodingSidebar 或 K0 整页重排** |
| 非测试：桥接网络路径更新（旧包） | 1 / 6（与 UI / 同步重叠） | 同份触发 **≥1.0s**；没有独占耗时 | `sample-20261012-114246.txt` | 报告 `CCBridgeWebSocketClient.handlePathUpdate:629`（19 样本）；当前 `Services/CCBridgeWebSocketClient.swift:72,430-445,897,905` 已默认走后台 transportQueue，**不重复实现这条后台化** |
| 非测试：CPU busy 触发，主线程几乎全为事件等待 | 1 / 6 | CPU 窗口 **11s，不是 hang**；主线程真时长未知 | `sample-20261012-111917.txt` | 2381/2384 在完整 `CFRunLoopServiceMachPort → mach_msg` 等待链；没有可归因的自有主线程热帧，不能把进程 CPU=85% 强归主线程 |
| XCTest 注入 / tests bundle（含 1 份空图） | **14 / 20** | hang 触发最高 **≥1.1s**；不计日常性能频次 | `sample-20261009-205232.txt`、`sample-20261010-024502.txt`；空图为 `sample-20261009-203045.txt` | 测试自身、SwiftUI/CA、CFPrefs、WebKit 等不同工作链，见外部逐份表。代表报告内有 `MusicCardPlayer.swift:262`、`WebViewHost.swift:15`、`MermaidRenderer.swift:200,225,294`；**测试等待外壳内的实际工作不误判 idle，也不外推给她日常包** |

### 7.7 剩余刀单：按可用现场证据重排，不返工已上的刀

1. **H1 `0a82a40e7` / S1 `d54ec8632` / P1 `f6420e9a8` 已完成，冻结不返工**。新日志来自旧包，不是这三刀前后对比，不能声明性能收益。
2. **下一刀 K1-dirty → R-tab → K0-min**：两份非测试报告直接命中 `flushIncremental → reloadProjects`，先去掉隐藏 Code 的无用 SQL；N2 已批，再避免启动自动激活 Code。K0-min 仍按 N1 承诺做完四项，但本期保留栈没有抓到整份详情解析 / Code 行布局风暴，故移到这两刀之后，不能用旧 09-28 频次冒充当前排序。
3. **新病 L-manifest 列为 R1 后首批实证优先项**，优先于没有本期自有栈证据的 A13 / 其他 A14 候选；不是“文件库枚举已后台，所以文件库都修了”。当前启动仍同步 `prepareProfiles`（包含目录改名、迁移和 manifest 比较读取）；不能只删比较或把整段随手 dispatch 后台，令楼层路径读写与迁移竞争。它不属于已经批准的几个最小止血行为，需先建立启动准备的就绪/串行契约再下刀，**止血批交付时明确保留这项坏消息**。
4. 同步→侧栏与 layout 各在两份非测试报告出现，但工作分支小、没有完整阻塞时长；A14e / B侧栏、X1 等保留 R1 测量顺位，不以“看到调用”断言整段 hang 都是它。桥接 path update 当前已默认后台化，不重复改；测试样本的 CFPrefs/环境修复等只记在测试宿主材料。
5. N3 仅得到有限新信息：10-12 的 3 条、10-16 的 4 条 active 应答都为 `tool=terminal tools=1`，Code 有开有关；没有终端 pane/session 身份，仍不能证明 CC 在哪个终端，更不能据此重做终端架构。其余 B/L、K1 全入口、K0 增量、K2、主题、工具隐藏等保持 R1 后按量级下刀。

**10-16 17:50 实施接续（止血MILESTONE）**：按上述现场顺序完成K1-dirty `442492eec`、R-tab `b4d5dbd37`及本次K0-min，原H1/S1/P1不返工；六刀定向/回退自测已齐，见plan §4及逐刀实验/复盘。后续产品编辑会移动源码行号，本节取证表的“当前”列仍以§7.5所注明的`f6420e9a8`基点为准，不重新套旧包地址。这里只证明代码行为，未测她日常包的卡顿率；L-manifest新病仍未修，GUI/Release/ABBA留R1。现停交车头合并，不继续改分支。

**10-16 18:16 S7审查接续**：车头收astra五项，已将详情冷却与含详情增量释放补到异步结果落地后的idle，真实快照闸/迟到A与ABA/解析错误保旧回归齐，整类16测通过；详见[复盘](review-mac-perf-s7.md)和plan §9。修前布局后0.00405s即再解析，修后2.44220s≥要求2.23744s；这是受控时序行为，不是生产收益。原S6“连续”用例仅同一actor轮次突发，S7已分散到冷却和取快照之后。取证表基点/现场频次边界不变，manifest新病仍未修，R1未启动；本切片提交后MILESTONE停合。


### 7.8 S39 · 原历史日期的日志回读，不伪造已轮换栈

新增离线日报首次回读当前仍在的09-28日志，只看时间、身份、上下文及栈元数据；旧行没有逐行包身份，保持unknown，不从最近start推给pid21417。

| 日志口径 | 10-01旧稿§1.3 | S39当前原件回读 |
|---|---:|---:|
| 心跳应答记录 | 8 | 8 |
| 中位数（旧稿未注明算法；新脚本取两中项均值） | 0.76s | 0.595s |
| 心跳最大观测 | 文中范围上限0.86s | 0.86s |
| hang触发下界记录 | 82 | 82 |

中位数未复现，不强行改脚本凑旧值；当时读到的记录或旧算法是否不同未确定，不能据此声明旧现场变快。原14份09-28采样已不在获批perf目录及外部perf归档，旧1/6/1/6栈分类只能保留为历史引述，不能标成新脚本复验通过。新工具仅用仍在的manifest和混合WebKit/测试宿主样本验证互斥计数；报告源行号属于报告包，不自动套当前工位。
