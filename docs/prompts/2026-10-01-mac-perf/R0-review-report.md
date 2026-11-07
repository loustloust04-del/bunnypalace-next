# R0 对抗审：mac-perf 研究 + 简报 + 计划初稿（钉 `140a4790`）

> 2026-10-01 · 审稿人：🎩（代 astra）· 只读核查，没有 build、没有启动或采样任何进程、没有读真库内容。
> 核查范围：
> - 26 份 `/Library/Logs/DiagnosticReports/记忆花园_*`：逐份分类了栈。
> - `~/Library/Application Support/MemoryPalace/perf/` 下的 `hangs.log` 和 20 份 `sample-*.txt`：逐份拆了线程。
> - `docs/assets/mac-hang/` 的 09-25 采样。
> - `~/.mp-merge-queue/build-history.tsv`。
> - 代码按 `文件:行号` 逐条对过（工作区 = `140a4790` 的代码，基 master `5cbd4e2c`）。
> - 粟粟 10-01 补充的原话：「我没用是因为根本用不了……比如我 code 想在花园打开，就必死」。这句当作已知症状纳入审查。
>
> 级别：【阻断】= 不改就不该进 R1；【重要】= R1 前要改进 plan / research；【建议】= 顺手改。

---

## A. 「打开 Code 必死」

### 1【阻断】唯一一份「她在前台、Code 开着」的现场采样被误判成「主线程已空闲」，第一批的刀修不到它

**问题**

research §1.3 把 `sample-20260928-100441.txt` 归进「7 份主线程已空闲（采样晚到）」。它其实是她停用 mac 版那一刻的现场：

- **进程**：pid 21417，就是她的日常包 `fowvto…`。
- **hangs.log 时间线**：
  - 10:04:14–10:04:36 连续 8 条前台回执（0.27–0.86s），全部带 `code=1`。
  - 10:04:41 一次 ≥1s 卡顿，触发了这份采样。
  - 10:04:58 记 `busy cpu=104% 11s`。
  - 之后这个进程再没有任何记录。`coding-index.sqlite` 和 `-wal` 的 mtime 也停在 10:04。
- **主线程**：2044/2099 个样本在 `NSRunLoop.flushObservers → NSHostingView.beginTransaction → GraphHost.flushTransactions`，细分如下：
  - `LazySubviewPlacements` ≈191。
  - `ViewDimensions / explicitAlignment / _FlexFrameLayout.sizeThatFits` 布局 ≈223。
  - 出现的 app 帧：`ParagraphView.updateNSView`（ParagraphView.swift:128-134）、`ChatMarkdownView`、`MessageSegmentsView`、`ToolCallCardView.card`（MessageSegmentsView.swift:399），另有 `ScrollGeometry*`。
  - 没有任何 `CardFlowView` / `BubbleView` 帧，所以不是聊天页。Code 详情用的正是这套渲染器（CodingSessionDetailView.swift:485、567）。
- **后台**：`mp.coding-sessions.incremental` 线程 705 个样本里，703 个在 `parseSession`，也就是整份重解析。

**结论**

「打开 Code 必死」的直接证据是 **SwiftUI 在渲染 Code 详情（正在被写的大会话），同时后台整份重解析**，不是主线程 SQL。plan 第一批的 K1（SQL 挪出主线程）、K2（差异写）、S1、P1 都修不到这条。research 把 A3「正看着的会话被写」标成「中 / 推断」，plan 把它塞在第二批的「其余」里。

**建议**

- research §1.3 改表：10:04 那份单列为「Code 详情渲染风暴」。
- plan 第一批新增 **K0（Code 详情增量）**，和 K1 并列排第一，内容见第 2 条。
- Q8 已经有答案，直接把「打开 Code（详情开着一条正在被写的大会话）」定为头号验收场景，见第 9 条的 M9-L1c / M8-live。

### 2【重要】「必死」的机制链 research 没写全：节流失效 → 占空比饱和，外加重开就回到死地

**单靠「整表重查 988MB 一次 1–2.4s」解释不了「必死」**

09-28 03:xx 那批 SQL 卡顿在 hangs.log 里是一条条独立的触发，中间有恢复。代码里能闭合「永远卡着」的链条如下：

- **(a) 详情每 ≤2s 整份重解析，而且不受限流**
  - `flushIncremental` 发现正在看的文件变了，就调 `reloadDetail()`（CodingSessionLibrary.swift:360-363）。
  - `loadDetail` 在后台用 `adapter.parseTranscript(ref)` **整份**解析 transcript（:688-689）。
  - 这条路径不经过 `CodingParseThrottle`；那个限流器只管索引写（:286、323）。
  - 解析完把 `detail` 换成新 box，并且 `detailRevision &+= 1`（:697-698）。
  - `isRefreshingDetail` 在 :665 和 :692 各翻一次，又多两次失效。
- **(b) 主线程每轮都把整个详情重排一遍**
  - `loaded(_:)` 每次 body 都对全部消息做 `filter` 和 `Array(enumerated())`（CodingSessionDetailView.swift:81-92），这是 O(N)。
  - 全部 `CodingMessageRow` 重跑。它们不是 Equatable，还带闭包。
  - `MacCodingTranscriptScroll` 在 revision 变化时执行 `position.scrollTo(edge: .bottom)`（MacCodingTranscriptScroll.swift:93-98），又挂着 `.defaultScrollAnchor(.bottom, for: .sizeChanges)`（:48）。在上万行、行高不一的 LazyVStack 里滚到底，要估算和放置大量行，这正是 10:04 采样里那堆布局帧。
- **(c) 2 秒节流对渲染无效**
  - `lastIncrementalAt` 在 flush **开始**时记录（:354）。
  - SwiftUI 的重排发生在 flush 返回之后的 runloop 观察者阶段，完全不算进节流窗口。
  - 只要 flush 加渲染（或者单独 flush）≥2s，下一次就 `wait = 0`（:346），背靠背接着跑。那条 CC 会话还在写，主线程占空比就接近 100%，体感就是「必死」。
- **(d) 重开也没用**
  - `restoreLeftPanelTab()`（ContentView.swift:1812-1818）：上次停在 Code，启动时就直接 `activate()`。
  - 也就是同步 `reload()` 加 `refresh()` 全根扫描（CodingSessionLibrary.swift:140-144）。
  - 扫描期间每推进 200 条，`applyProgress` 还会在主线程 `reloadProjects()`（:429-436，research 漏了这处）。
  - 再叠上启动首扫（L4）。

**L4 其实有直接证据，research 没用上**

`记忆花园_2026-09-26-104336`（pid 22038，事件从 10:39:47 进程启动那一刻开始）：225 秒写了 2GB，约 9.5MB/s。栈是 `CodingSessionLibrary.refresh(full:) → CodingSessionScanner.run(:108) → write(:264) → writeSession`，即扫描路径，不是监听增量。research 把它混进「19 份增量重写」，L4 仍标「推断」。

**置信**：中。现场证据是 10:04 那一份采样，加上代码链闭合；行为还要在 R1 复现。

**建议**

- research §2.2 / §3 把 A3 和 L4 升为「有现场证据」。
- K0 的最小版：
  - 详情按 seq 只追加新尾巴：行身份稳定、行 Equatable 化、静默刷新时不翻 `isRefreshingDetail`。
  - transcript 只解析追加的字节，等于把 K4 对详情路径提前。
  - 详情刷新间隔 ≥ max(2s, 10×上次解析耗时)。
  - 节流改成从「上一次 flush 加渲染结束」开始计，或者 flush 进行中不再排下一次。
- `restoreLeftPanelTab` 加一个止血开关，交她定，见第 20 条。

### 3【重要】09-25 那次 39.8s hang 没有解释，研究引用的证据是错的

**两处事实错误**

- **不是「同一进程」**
  - research §1.1 写「同一进程 09-25 11:30 的旧采样有 app 帧：Code 列表 reload() 先清空再重填」。
  - `.hang` 是 pid 73806（`gwjmgvaq` 包，Time Since Fork 4493s）。
  - `docs/assets/mac-hang/sample-2026-09-25-1130.txt` 是 pid 36536，晚了 10 小时，是另一个进程。
- **那份 11:30 采样里没有 reload 帧**
  - 主线程 753 个样本里没有任何 `CodingSessionLibrary.reload`。
  - app 帧只有 `CodingMessage` 的拷贝 / 销毁，和 `MacCodingTranscriptScroll.Geometry ==`，指向的是详情转录。
  - 「reload 先清空」是 plan-mac-hang-probe §0 当时的代码推断，不是采样证据。

**research 没用上的真线索**

- `.hang` 的主线程 CPU 时间 1.199s / 采样 1.3s，是纯 CPU 布局循环，不是 IO。进程当时在最前台。
- 同一个 pid 73806 有一份 `记忆花园_2026-09-25-010905` disk writes，栈是监听写库。这说明那个进程当时 Code 监听正在写。
- 栈形状 `LazyStack.place → _ViewList_Group → ForEachList → DynamicViewList.WrappedList ×2 → BaseViewList`，和 Code 侧栏的嵌套 `ForEach + if`（CodingSessionSidebarList.swift:195-206、219-231、248-254）更吻合，和详情的单层 ForEach（CodingSessionDetailView.swift:89）不太像。所以「Code 列表」这个结论**可能**仍然成立。

**建议**

- 证据链重写，置信度降为「中低」。
- plan X1 写的「K1 后复测」不成立：K1 不改列表渲染。把 X1 和 A4（侧栏整表 body，`sessionRow` 是父 body 里的函数）合并成一刀，R1 在 M9-L1b 里用 SwiftUI 模板抓。

---

## B. 归因核查

### 4【重要】「Code SQL 卡 1–2.4s 是因为赶上自家写盘拥堵」，采样不支持；「1–2.4s」也是低估

**同期 IO 不是自家写盘**

3 份正卡在 SQL 里的采样（031500、040802 全程，032821 一半），同一进程里**没有任何编程会话索引的写线程**（找不到 `writeSession`、`pwrite`、`wal_checkpoint`）。同期在跑的是 `SQLQueue for unified.store` 上 `SyncEngine.pump` 的 `countForFetchRequest`，也就是 probe-5a/5b 的全表计数，本身就是大量 pread：

| 采样 | 主线程 pread | SQLQueue 计数样本 | 其中 pread |
|---|---|---|---|
| 031500 | 2099 | 1846（SyncEngine.swift:157） | 1770 |
| 032821 | 1034 | 1040 | 1012 |
| 040802 | 2045 | 只有 471 | — |

040802 那份后台计数不多，主线程照样卡在 pread，说明还有机器层面的 IO 或内存压力。佐证：09-28 09:07–09:44 编译几乎没停过（build-history.tsv），第二段密集卡顿 09:17–09:23 正落在里面。

**时长被低估**

HangProbe 记的 ≥1s 行是「第一次越过 1s 的 tick」时的值（HangProbe.swift:55-60），不是卡了多久。031500 在 1.1s 触发后，3 秒采样全在同一条查询里，那次实际 ≥4.1s。

**影响**

- S1 对主线程卡顿的贡献可能被低估了：它和 Code 的 reader 抢同一块盘、同一份页缓存，不只是「后台、次要」。
- K2 对转菊花的直接作用可能被高估：它主要降写盘量、消掉 disk-writes 报告。
- plan §5 S1 那句「主 context 写入不再等后台读」没有证据，WAL 下读不阻塞写，应删掉。

**建议**

- research §2.2 的「IO 来源」改成「未定：同进程 SyncEngine 全表计数的读 + 机器 IO / 内存压力；卡顿采样里看不到自家写盘」。
- 「单次 1–2.4s」「1–6s 卡顿」改称「≥1s（触发值，是下界）」。
- S1 排在第一批第一个。

### 5【建议】若干事实和口径小错

- **§1.3 表头**：写的是「前台 <1s 卡顿（带上下文的回执行）」，但回执行是任意时长，表里自己就写着 max 4.33s / 25.72s。应改为「前台卡顿（回执行，任意时长）」。
- **09-30 那份迁移采样的来源**：`sample-20260930-100654.txt` 链接了 `libXCTestBundleInject.dylib`，是**单测宿主**，不是 §1.3 / L1 写的「page1 工位包」。这反而让 §4.1「测试宿主原地迁移她的真库」从推断变成有证据，两处要统一。
- **10-01 02:02 那份采样**也是 XCTest 宿主（主线程在 `XCTestCase recordIssue` 做符号化）。测试宿主在往她的 `hangs.log` 里写、还会起 `/usr/bin/sample`。
- **09-26 是全周最重的一天**（208 次 ≥1s 触发、131 次 `start pid`），research 没有任何说明。当天采样已经轮换删掉，应写明「未归因」。
- **行号**：probe-2 实际在 MemoryPalaceApp.swift:667-672，probe-4 在 :780-784（research 写的是 669-673 / 781-785）。

### 6【重要】`tool=terminal` 归因错了组件，漏掉了一个常驻的主线程负载：本机终端

**问题**

- research §3.2 把 HangProbe 里 153/154 条 `tool=terminal` 当成「基数问题」，机制挂到了 `CCTerminalPanelView`。
- 实际上 `terminal` 是本机 SwiftTerm 终端（MemoryPanelView.swift:135）；CC 桥终端的 id 是 `ccTerminal`（:102）。
- SwiftTerm 的 `LocalProcess(delegate:)` 不传队列时默认用 `DispatchQueue.main`（SwiftTerm LocalProcess.swift:112-117）。所以每个本机终端 tab 的 PTY 读取、VT 解析和重绘都在主线程，没选中的 tab 也照样解析（LocalTerminalSession.swift:58、274-277）。
- 她在花园里跑 CC（Code 详情的「回到终端」就是本机终端 tab），CC TUI 的转圈和整屏重绘会直接压在主线程上。

这是她「<1s 前台卡顿」最可能的常驻来源，A 区清单里没有。

**建议**

- 进第一批候选：给 LocalProcess 传后台队列，主线程合帧 feed。
- M9 加一个终端档，见第 9 条。

### 7【重要】漏掉的周期性主线程重活（静态排查，按量级排序）

这几条都会被「右栏把 6 个工具用 opacity 0 全挂着」（TabbedToolPanel.swift:52-61）放大：藏在后台的工具，定时器、`@Query`、通知照跑。全项目只有 AssistantPanel 和 LocalTerminalPanel 读了 `isFrontmostTool`。

| # | 位置 | 机制 | 频率 / 量级 |
|---|---|---|---|
| a | 文件库面板 FileLibraryPanelView.swift:68-70 → :659-665 → FileLibraryStore.list :230-251 | 主线程递归枚举整个文件库，**不跳过 `books`** | 每 5 秒一次。input-jank C1 实测同一函数 546ms/次。我已核对代码 |
| b | 日历面板 CalendarPanelView.swift:34-44、92-94 | `@Query` 拉楼层全部对话，body 里还同步读盘 | 主 context 每 save 一次就失效：CC 流式每帧、输入框每键 |
| c | 书架 BookStore.swift:320-361 | 每 5 秒 N+1 次主 context fetch，可能顺带 save 整个主 context | 一 save 就让所有 `@Query` 失效 |
| d | 推特面板 TwitterPanelView.swift:187-192 | 主 context 全量查询 | 每 20 秒 |
| e | 侧栏 SidebarView.swift:1117 | 收到 `.syncDidImport` 就 `refreshList` | 同步开着时只要导出过东西就触发，约每 5 秒 |
| f | MacScrollbars.swift:218-246 | 每次更新都递归遍历整窗 NSView 树 | ContentView 每次更新都触发（A3 已知每 ≤2s 一次） |
| g | 菜单栏快看 MacMenuBarQuickLook.swift:62-69 → recentlyActive | 主线程 SQL | 菜单开着时每 5 秒 |

b–g 来自子 agent 扫描，我只抽核了 a 和第 6 条，其余按「中」置信度对待。

**建议**

- HangProbe 的上下文现在只记 `tools=6` 和选中的那个。R1-5 要记下**打开的工具 id 列表**，才能知道这些里哪些在她现场。
- research §3.1 补进这些条目。

---

## C. 测量方案

### 8【阻断】bench 隔离的清单有漏项，验证手段（`lsof` 快照）会放过它们

plan §3.2 只收口了 36 处 `applicationSupportDirectory`、`Caches/MemoryPalace` 和 `kb-probe`。下面这些换 bundle id 也挡不住：

- **`~/Documents`**（`documentDirectory` 用了 12 处 / 10 个文件）
  - FileLibraryStore.swift:75 的本地 floors 根：bench 种子的文件库会写进她真的 `~/Documents/<app>/floors`。
  - 还有 FeedbackStore:20、GlobalBackup/StagingPaths:31、VocabCorpusStore:46、BridgeProbe、WebSearchProbe 等。
- **写死的 iCloud 路径**：`~/Library/Mobile Documents/iCloud~com~susu~MemoryPalace/Documents`（FileLibraryStore.swift:45-46、BackupStore.swift:50-51、BookStore），绕开了 bundle id 和 Application Support，直接写到她的 iCloud。
  - `primeICloudContainer` 无条件建这个目录。
  - 时间机器在 scenePhase 变 `.background` 时执行 `snapshotIfNeeded` 和 `pruneOldBackups`（MemoryPalaceApp.swift:1209-1221，BackupStore.swift:595）。走 Q1-b 或 Q2-b（同一偏好域，或带着她的设置）时，bench 会按 manifest **删她的备份**。
- **她的 CC workdir**：CCThinkingHookInstaller（:16-30）在每次启动时（ContentView.swift:480）读她的 `~/Desktop/cc-rp/.claude/settings.json`。按 marker 判重，平时不写；但 hook 缺失时会写入指向 bench 根的路径。
- **她的 CC 账号**：SubscriptionQuotaStore 由 Code 详情的 `.task` 触发（CodingSessionDetailView.swift:392-394），用 `security` 读她的 CC OAuth 凭据，再请求 `api.anthropic.com/api/oauth/usage`（SubscriptionQuotaService.swift:254、430-450）。home 不走注入，**M8 一跑就会发生**。
- **生产 hub**：HubTokenStore 读 `~/Library/LaunchAgents/com.susu.cc-bridge-hub.plist`（HubTokenStore.swift:13），CC 桥客户端会自动去连。plan 只写了「hub / bridge **子进程**」，没写**客户端连接**（违反「严禁对生产 hub 发测试流量」）。
- **家目录 API**：`homeDirectoryForCurrentUser` 15 处 / 11 个文件、`NSHomeDirectory` 6 处、`getpwuid` 1 处（LocalTerminalLaunch.swift:27）。CFFIXED_USER_HOME 就算对 FileManager 生效，也盖不住 `getpwuid`。
- **TCC 授权弹框**：新 bundle id 意味着全新的隐私授权状态。第一次碰 `~/Documents`、`~/Desktop`、本地网络（ProxyDiscovery 的 NetService、hub）、日历 / 提醒、通知，都会弹系统框。无人值守时一弹，测量就卡住；她要是点了「允许」，就等于给 bench 包开了她 Documents / Desktop 的权限。

**验证手段也不够**

- `lsof -p` 是瞬时快照，抓不到「打开-写-关」式的原子写（kb-probe、`writeAtomic`、manifest）。
- 她的 `unified.store` mtime 现在就会被别的工位的测试宿主改（10-01 01:24，`-shm` 02:29）。mtime 判据只在门内才可信。

**建议**

- `AppPaths` 收口范围扩到上面全部。bench 模式下只要有路径解析到 bench 根以外就 **trap**（代码层断言）。
- 实证改成：
  - 测前在敏感根下放一个 marker，测后 `find <根> -newer marker`。要覆盖：Application Support/MemoryPalace、Caches/MemoryPalace、`~/Documents`、`~/Desktop/cc-rp`、`~/Library/Mobile Documents/iCloud~com~susu~MemoryPalace`、`~/.claude`、`~/Library/LaunchAgents`。
  - 网络侧确认没有连 hub 和 `api.anthropic.com`。
- TCC：在她在场时首启一次，所有弹框点「不允许」，或者代码层根本不去碰这些位置。
- plan §3.2 第 3 条的副作用清单补上：时间机器、额度服务、hook 安装器、文件库 iCloud、CC 桥客户端。

### 9【重要】M9 复现不了现场条件，基线可能一上来就是「>1s 0 次」

**现场有、M9 没有的条件**

| 现场 | 证据 | M9 现设计 |
|---|---|---|
| app 不在前台 | 09-28 的 ≥1s 卡顿全部没有回执 | 窗口在前台，不遮挡 |
| 被遮挡 / App Nap | 触发值出现 2.6 / 3.5 / 6.0s，说明探针自己的 100ms 定时器被推迟了 | 无 |
| 机器在编译 | 09:07–09:44 编译不断 | 负载门把编译排除掉 |
| Code 开着，正看着被写的会话 | 10:04 | 只有 jsonl 写入器 |
| 本机终端在跑 CC | 第 6 条 | 无 |

这样测会系统性低估，K1 / K0 的收益也就证明不出来。

**建议**：M9 分档

- **L1a**：Code 关。
- **L1b**：Code 列表开着。
- **L1c**：Code 详情开着那条 100MB 级、正在被写的会话。这就是「打开 Code 必死」的验收，预期基线会超时，超时本身就是读数。
- **L-term**：本机终端 tab 按 CC 节奏吐合成的 TUI 输出。
- **L-io**：runner 自己按固定剂量注入 IO 压力（后台固定速率读写另一个大文件），模拟编译期页缓存被挤掉。
- **后台态**：bench 窗口被遮住、不是 active；外加「激活 → 第一个事件处理完」的延迟，直接量转菊花。

负载门管的是「外部噪声」，压力档是 runner 自己注入的固定剂量，两者不矛盾。另外写清楚 M1–M8 跑的是 L0（写入器关）。

### 10【重要】合成的编程会话索引夹具复现不了她那个 988MB 库的碎片化

- 她的库是两周增量写出来的：sessions 表的约 835 页散落在约 780MB 的 trigram 页之间，`listProjects` 回表时就是随机 pread。
- plan §3.2 的「bulk 种子 + 冻结模板」会让 sessions 页连续，A1 的冷读可能快一个数量级。

**建议**

- 夹具用写入器回放增量写来「老化」。
- 或者经她同意克隆 `coding-index.sqlite`。它是可重建的缓存，但里面有她 CC 的对话正文，要**单独**问，不要和聊天库的 Q2-b 混在一起。
- 模板指纹加上 `page_count`、`freelist_count`，以及 sessions 页的分布（`dbstat`）。

### 11【重要】没有时间预算；拿全机编译锁、无人值守不锁屏都要单独拍板

**粗算时长**

| 项目 | 估算 |
|---|---|
| R1-7 基线：M1–M8 | 8 × 12 进程 × ~40s ≈ 1h |
| R1-7 基线：M9 | 2 档 × 3 窗 × 10min = 1h；按第 9 条加档后翻倍 |
| A/A、Debug 对照 | 另计 |
| 每刀 ABBA | M9 就要 4 × 10min，再加 M 系列 |

这些全落在「她出门 + 编译锁空闲」的窗口里。

**拿锁的代价**：这台机白天几乎一直在编译（09-28 那一小时的 build-history），夜里也有 agent 在跑。Q4-b 每块拿锁 15 分钟，会让 9 个工位排队。

**样本量**：>1s 事件很稀，ABBA 每臂 2 × 10 分钟证明不了「0 次」。

**无人值守的安全取舍**：Q3 要她出门时屏幕不锁 + `caffeinate -d`。这等于把一台登录着全部终端、CC 和凭据的 Mac 无人看管地开着，要她单独拍板。`caffeinate -d` 只挡显示器睡眠，挡不住她自己设的锁屏策略。

**建议**

- plan 写进总时长预算和每晚拿锁的块数上限（Q4 里明确）。
- M9 的判据只用三样：>250ms 次数率（带泊松置信区间）、写盘 MB/h、最长块的分位数。「>1s = 0」只当目标，不当判据。

### 12【重要】HangProbe 和卡顿记录器的口径问题

- **(a) 后台卡顿没有时长**：≥1s 那行是触发值（约 1.0–1.1s）。app 不是 active 时，卡顿结束不写回执（HangProbe.swift:71-77），所以后台卡顿永远没有时长。research 和 plan 都把它当时长在用。
- **(b) 不知道是哪个包**：日志不带 pid 和包身份。测试宿主写同一本日志，还会起 `sample`（证据见第 5 条）。
- **(c) Q5 的前提可能不成立**：Release 加 hardened runtime 没有 `get-task-allow`，`/usr/bin/sample` 采自己大概率直接失败。同理，R1-5 第 ④ 条在 Release+PERF 的 bench 包里也靠不住。
- **(d) 进程内栈采样器容易自锁**：R1-5 第 ① 条要 `thread_suspend` 主线程，主线程被挂起期间不能调用任何 malloc、锁、ObjC 或 Swift runtime，否则会死锁。这是整个 R1 最容易写出事故的部分。

**建议**：R1-5 先做低风险的几项

- 阈值降到 500ms；
- 卡顿结束时不论是否 active 都记时长；
- 每行带 pid 和包身份（DerivedData hash 或 Release）；
- 测试宿主里不启动 HangProbe。

进程内采样器往后放，或者改用成熟实现的思路。

### 13【建议】驱动器绕过了 NSEvent 分发

- T0 取的是驱动器直接调业务函数那一刻，跳过了 NSEvent → hit-test → Button 动作这一段。大 SwiftUI 树在 mac 上的 hit-test 和无障碍（AX）开销测不到。iOS 那轮 R1 的 B4 专门做过真手指对照。
- **建议**：M2 / M8 各用 `window.sendEvent` 合成鼠标事件交叉验证一次。双观察者口径和 observer 顺序的实证项（R1-0）没问题。

---

## D. 计划

### 14【重要】先打地基再下刀，代价是她继续「用不了」；有几刀证据已经够，可以先做

R1 在任何一刀之前要完成：测量台、记录器 6 个子项、种子、脚本、8 条 UI 回归、A/A、基线、Debug 对照。按第 11 条的预算是周级，而她现在就用不了 mac 版。

**证据已经足够、行为面接近零、可以先做的**

- **S1**：删掉每次 pump 的 4 次全表计数。纯诊断，iOS L1 有先例；第 4 条显示它和主线程卡顿同时发生。
- **P1**：Debug 包里的 KBProbe、probe-2 / probe-4。
- **保护她的数据（不是性能刀）**：测试宿主改根 + HangProbe 加测试门。
- **K0 最小版**：详情刷新间隔按解析耗时放大，节流按结束时刻计（第 2 条）。
- **`restoreLeftPanelTab` 止血开关**：需要她拍板。
- **K1 的「Code 没开只记脏、不查」部分**：几乎没有行为面。

**建议**：以上先合，让她的日常包先能开 Code。用补了时长和包身份的 HangProbe（第 12 条）看现场前后对比。测量台并行搭，给 K0 / K1 / K2 的完整版做 ABBA。

### 15【重要】K1 只覆盖了 flushIncremental 一处；「照 search 的做法」照抄会出新问题

**主线程同步 SQL 的全部入口**（CodingSessionLibrary.swift）：

- `activate()`：:140-144
- 扫描期间每 200 条的 `applyProgress → reloadProjects`：:429-436
- 扫描完成后的 `reload()` 和 `reloadDetail()`：:247-253
- `toggleRoot`：:567
- `loadPage / fetchPage`：:603-633
- `openSession / reveal` 最多连翻 20 页：:386-426
- `recentlyActive`：:396-401，菜单栏每 5 秒
- `loadDetail` 里的 `reader.session(key:)`：:675

K1 要么覆盖全部这些点，要么统一换成后台 actor。

**search 那套不能照搬**

- `search()` 每次调用都用 `CodingSessionIndex(url:)` 以**读写**方式新开一条连接：`readOnly` 默认 false，见 CodingSessionIndex.swift:85-125。
- 每开一次，都在 `migrationLock` 下执行 `PRAGMA journal_mode=WAL` 和 `INSERT OR REPLACE INTO schema_meta`（:123-125、169）。这是一次写事务，busy_timeout 5 秒，会和扫描器的 `BEGIN IMMEDIATE` 大事务抢写锁，还会让其他 reader 的页缓存作废。
- 主线程那条 `openReader()`（:638）也是读写打开的。

**建议**：K1 改用 `readOnly: true` 的长连接（代码里已经有：:93、101-118）。另外，research 的 `cache_size` 思路没用：WAL 下别的连接一提交，SQLite 的页缓存整体重置。要么用 mmap，要么不在主线程读。

### 16【建议】K2 的「后台 CPU 降」预期要改

- 09-25 11:30 采样：后台扫描 283 个样本里，187 在 `ClaudeCodeAdapter.parse` 整份解析，96 在 `writeSession`。
- 10:04 那份：后台 703/705 在 `parseSession`。

K2「仍整份解析」只能降写盘，CPU 的大头还在。**建议**：去掉这条预期，或者把 K4（尾部增量解析）提前，至少对详情路径（第 2 条）提前。M9 加 footprint 峰值：每次整份解析 100MB 文件会产生大量临时分配。

### 17【建议】mac UI 回归的补法要算上 TCC 和 AX 的代价

- `MacRegressionUITests` 第一次跑需要她给测试 runner 授权「辅助功能 / 控制这台电脑」。
- UI 测试打开无障碍树后，SwiftUI 的每次更新会多算 AX 节点（iOS R1 的 B4 教训），所以 UI 回归和性能测量不能共用一次运行。
- 8 条用例里 MC1 最关键。建议再补两条：
  - 「上次停在 Code，重启」：启动后 N 秒内主线程没有 >1s 的块。
  - 「Code 详情开着，持续写 3 分钟」：主线程不被饿死。

### 18【建议】Todo 颗粒度不够

缺这些项：AppPaths 的扩展收口和 TCC 预处理（第 8 条）、M9 的压力档（第 9 条）、时间预算（第 11 条）、HangProbe 的时长 / 包身份 / 测试门（第 12 条）、K1 的调用点清单（第 15 条）、K0（第 1、2 条）。第二批的各刀也没有展开成可勾选的子项。

---

## E. 拍板问题 Q1–Q8

### 19【重要】Q8 已经有答案，还有几个该问的没问

**Q8**：粟粟已经回答了「打开 Code 必死」。plan 要据此改，见第 1、2、9 条。

**Q1 的选项说明不全**：推荐 a 是对的，但 a 成立的条件（第 8 条：Documents、iCloud 写死路径、时间机器删备份、CC 账号、生产 hub、TCC）要写进选项说明。b（同 bundle id）会**触发时间机器按 manifest 删她的备份**，这个风险也要写出来。

**Q5 的前提存疑**：见第 12 条 (c)。

**漏问的**

- **(a) 止血先上**：是否允许不等测量台就先合 S1、P1、K0 最小版、测试宿主隔离；`restoreLeftPanelTab` 是否先关掉（第 14 条）。
- **(b) 她的日常环境**：常开的是哪 6 个右栏工具；是否在花园的本机终端里跑 CC。这决定第 6、7 条的优先级。
- **(c) 无人值守**：她出门时 Mac 不锁屏的安全取舍；bench 包首启的 TCC 弹框由她当面点「不允许」。
- **(d) 克隆编程会话索引要单独授权**（里面有 CC 正文），见第 10 条。
- **(e) 测试宿主改根影响面大**：会影响所有工位的 mac 单测，要管家协调；测试宿主里是否停掉 HangProbe。
- **(f) 编译锁上限**：Q4-b 每晚最多拿锁几块、总时长多少。

---

## 总评

1. research 的主体结论，即「后台活抢主线程」和「编程会话索引是写盘大户」，方向是对的；但「打开 Code 必死」唯一的前台现场证据（09-28 10:04）被误判成空闲，那是 Code 详情的渲染风暴叠加节流失效，第一批的 K1 / K2 修不到它。
2. 39.8s hang 和「SQL 卡顿来自自家写盘」这两条的证据链都有事实错误，需要重写并降低置信度。bench 隔离漏了 `~/Documents`、写死的 iCloud 路径（含时间机器删备份）、她的 CC 凭据、生产 hub 和 TCC 弹框，`lsof` 快照验证不出来，这是唯一可能伤到她数据的地方。
3. 建议先合零风险的止血刀（S1、P1、测试宿主隔离、K0 最小版、`restoreLeftPanelTab` 开关），让她先能用；测量台按第 8–12 条补齐隔离、压力档和时间预算后再做 ABBA。
