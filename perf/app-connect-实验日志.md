# app 冷启动秒连实验日志

> 口径见 [plan-app-instant-connect](../docs/plan-app-instant-connect.md)、[research](../docs/research-app-instant-connect.md)、[playbook-perf](../docs/playbook-perf.md) §3。一刀一条：假设 → 改动 → 计数 / 分段 → 现场账本前后分位数 → 留/退。

## 尺子 r1（harnessRevision `connectV2-r1`）——已被 r2 取代，下文保留作历史

**目的**：只加测量、连接控制流未改（r1 原写「零行为改动」，sol R1-11 收窄），给 connect_report 补 research「建议加的探针」一节指出的口径缺口：`openAt` 晚于真正 didOpen、`mainDelayMs` 只记最大值且混了输掉的候选、`launchMs` 只到连接意图不到首个请求、时长用墙钟、没有包身份、启动前段不分段、连接窗口里主线程到底忙不忙不知道。旧字段一个不动（语义不变），hub 账本两套口径并存。

### 新字段（wire 照旧帧的 snake_case；hub 账本里是 camelCase）

所有 `*_ms` 都是**单调时钟**（`clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`，即 mach_continuous_time，含睡眠），起点 = **连接入口**（app 开这一段 `ConnectEpisode` 的那一刻，冷启动即 `connect()` → `beginEpisode`）。`*_at` 是手机墙钟 epoch ms，只做跨端对齐（hub 卡顿对账）。

| 字段 | 含义 | 有没有 |
|---|---|---|
| `rev` | `connectV2-r1`；有它 hub 才认下面这些 | 每次 |
| `build` | `debug` / `release` / `perf`（编译开关，PERF_BENCH 优先） | 每次 |
| `first_req_ms` / `first_request_at` | 入口 → 这一段第一个 `resume`（多候选是第一个 /health 探测，单候选是 WS） | 发出过请求 |
| `ws_resume_ms` | 入口 → 最后一次 WS `resume`（就是连上的那个） | 发起过 WS |
| `ws_open_ms` / `ws_open_at` | 入口 → `didOpenWithProtocol` 回调（URLSession 委托队列线程） | 连上 |
| `ui_ms` / `ui_connected_at` | 入口 → didOpen 排到主线程那个 block 的首行 | 连上 |
| `done_ms` | 入口 → 报告组好（= 旧 `open_at` 那一刻，含 block 里前面的接线和日志） | 每次 |
| `candidates[]` | 每个探测候选 `{h, req_ms?, cb_ms?, queue_ms, handle_ms, won, late?}`，见下 | 多候选 |
| `busy_ms` / `busy_n50` / `busy_max_ms` / `busy_capped?` | 入口 → ui 时刻窗口内主线程 runloop 忙段总和 / >50ms 块数 / 最大块；窗口超 60s 停记标 capped | 连上 |
| `segs` | 冷启动分段：各点距 `AppEntry.main` 首行的 ms（单调），名字见下表 | 只 launch |
| `pre_main_ms` | 进程起点 `p_starttime` → `AppEntry.main` 首行，**墙钟**（唯一一段墙钟时长） | launch 且非预热且 sysctl 成功 |
| `launch_fail` | sysctl 读 `p_starttime` 失败。旧口径 t0 照旧退到连接入口（不改语义），这里显式标出：`total_ms` / `launch_ms` 偏低，不能当冷启动全程 | 只在失败时 |

候选字段：`req_ms` = `URLSessionTaskMetrics.taskInterval`（请求生命周期，委托队列上收，报告时才填，没收到就缺）；`cb_ms` = 主线程 `resume` → 完成回调（单调，含 URLSession 委托队列调度）；`queue_ms` = 完成回调 → 主线程 block 开始；`handle_ms` = 主线程 block 首行 → 结束（赢家含 `openSocket()`：建 session + WS resume）；`late` = 已有赢家后才到（多半是被撤的 cancelled）。只记 host 和数字，不记 token / URL query。

冷启动分段点（`LaunchMarks`，不可观察的全局表，`OSAllocatedUnfairLock` 保护，只追加，同名取第一次，上限 64 条）：

| 点 | 落点 | 段（上一点 → 这一点） |
|---|---|---|
| `entry` | `MemoryPalaceApp.swift:674` `AppEntry.main` 首行（锚点，同时记墙钟） | `pre_main_ms`：进程起点 → 入口 |
| `props` | `MemoryPalaceApp.swift:690` App 第一个存储属性初始化 | 入口 → 属性初始化（含测试宿主检查、BFU 闸、SwiftUI App.main 到建 App 实例） |
| `propProviders` | `MemoryPalaceApp.swift:719` providerManager 属性之后 | 主题 + Provider（含开屏位图预加载派发、LaunchTrace 锚） |
| `propCards` | `MemoryPalaceApp.swift:726` cardManager 属性之后 | 卡库（属性那一次） |
| `initBegin` | `MemoryPalaceApp.swift:749` `init()` 首行 | 其余属性（工具 / 世界书 / 导航 / MCP） |
| `container` | `MemoryPalaceApp.swift:806` `makeUnifiedContainer()` 之后 | init → 建库完（含字体、pending import、archive 清理、建库） |
| `profiles` | `MemoryPalaceApp.swift:818` `loadProfilesChecked()` 之后 | 楼层（含酒馆导入恢复检查） |
| `cards` | `MemoryPalaceApp.swift:873` 第二次 `CharacterCardManager()` + 示例卡之后 | 卡库（init 那一次，含文件库预备、旧迁移检查、ProfileManager） |
| `initEnd` | `MemoryPalaceApp.swift:1004` `init()` 末行 | init 其余（预设、各 fixup、outbox、seed、索引调度、breadcrumb、模型目录） |
| `splashRelease` | `LaunchSplash.swift:106` 内容门 `isOpen = true` 那个主线程 block 里 | init 完 → 开屏内容门（iOS；mac 没有） |
| `contentAppear` | `ContentView.swift:426` `.onAppear` 首行 | 内容门 → 首屏 onAppear |
| `connect` | `CCBridgeWebSocketClient.swift:418` 冷启动那段 `beginEpisode` | onAppear → 开始连 |

### 落点（连接侧）

- `MemoryPalace/Services/ConnectRuler.swift`（新）：`ConnectClock`、`LaunchMarks`、`ProbeRoundTimings`、`ConnectCandidateRecord`、`BusyAccumulator` / `ConnectBusyWindow`、`ConnectRulerEpisode.fields`（报告组装，纯函数）。
- `CCBridgeWebSocketClient.swift:396` `ConnectEpisode.ruler`：建一段 = 记连接入口单调时刻 + 挂连接窗口忙段观察者。
- `:416` sysctl 读失败（非预热）标 `launchFail`；`:418` 冷启动打 `connect` 点。
- `:448` / `:456` `finishEpisode` 合入新字段（`merge` 不覆盖旧键）；launch 才带 `segs` / `pre_main_ms`。
- `:1287–1288` 每轮探测一个 `ProbeRoundTimings`，挂进 `CCBridgeProbeDelegate(onMetrics:)`（`CCRelayPin.swift:68–76`，新增 `didFinishCollecting`，回调在 URLSession 自己的委托队列上）。
- `:1317` 完成回调线程记 `callbackNs`；`:1320` 主线程 block 首行记 `enterNs`；`:1323–1326` `defer` 在 block 结束时记候选（含输掉的、late 的；代次不对的直接丢，不记）。
- `:1348–1351` 原 `.resume()` 链拆成 `let dataTask = …`，`resume` 前记时刻 + 首个请求。
- `:1410` `openSocket` 里 WS `resume` 前记。
- `:2023` didOpen 回调线程记 `wsOpenAt`；`:2025` 排到主线程的 block **首行**（`guard let self` 之前）记 `uiConnectedAt`；`:2030` 过了 `task ===` 守卫才落进这一段，同时摘忙段观察者。

**连接控制流未改的论证**（r1 原题「零行为论证」；埋点自身有锁 / 委托回调成本，量级未测，见 r2）：每处只读单调时钟 / `Date()` 和追加数组，不改调用顺序、不换线程、不读 Observable / 模型、不写盘、不新增 BridgeProbe / PROBE 调用。`.resume()` 拆链只是把同一条语句拆成两行，中间插的是记时刻。`CCBridgeProbeDelegate` 新增的 `didFinishCollecting` 不影响 URLSession 行为（metrics 本来就收，只是多一个回调）。忙段观察者只在连接窗口里挂（beginEpisode → ui 时刻，最多 60s），每次 runloop 唤醒 / 睡前各跑一个闭包（读一次时钟 + 加法）。

**不复用 PerfHarness.MainBlockMonitor 的原因**：它只编进 `(DEBUG || PERF_BENCH) && os(iOS)`，装上不摘，单槽 `splitSink` 还被 AirPerfProbe 占着；日常包要的是「只在这个窗口开、开完摘」。口径照抄它的 split 那套（`order = Int.min` 开段 / `Int.max` 收段 / `commonModes`），忙段含布局 + CA 提交。

### hub

- `cc-bridge/connect-ledger.ts`：`parseConnectReport` 认 `rev` 之后的字段（没 `rev` = 旧 app，一个新字段都不出，旧字段解析不变）；候选只留 host + 数字。`hub.ts` 原样 `...report` 进账本，不用改。
- `classifyConnect`：有 `rev` 时用 `rulerReasons` 代替旧的「app 主线程忙 max」「点开后才开始连」两条，拆成：`启动慢：<段> Nms`（每段 ≥300ms）、`开始连→发出首个请求`、`真网络：探测请求 / WS 握手`、`排主线程：探测结果等 / 连上后等`、`主线程处理探测结果`、`连接窗口主线程忙 N（>50ms 块 n 个，最长 m）`、`进程起点读不到`。hub 卡顿对账窗口有墙钟时缩到 `first_request_at → ws_open_at`（之前 hub 还没收到东西，卡顿跟这次连接无关）。
- `cc-bridge/scripts/connect-ledger.ts`：加「尺子拆分」段，按 `trigger · platform@from · build · rev` 分组，每个指标 n / p50 / p75 / p90（冷启动去掉预热）。
- 测试：`connect-ledger.test.ts` 新 8 条（解析、旧 app 兼容、分段差 / 缺点跨段、理由拆分、真网络、hub 卡顿窗口、分位数、临时目录造账本跑统计脚本）。

### 样例（造的，一次冷启动、LAN 赢、Tailscale 被撤）

```json
{
  "type": "connect_report", "trigger": "launch",
  "t0": 1791700000000, "open_at": 1791700003010, "total_ms": 3010, "bg_ms": 0, "wait_ms": 0,
  "main_delay_ms": 640, "launch_ms": 2100, "host": "192.168.31.20", "path": "satisfied|en0",
  "attempts": [{ "h": "192.168.31.20", "r": "ok", "ms": 700 }],
  "rev": "connectV2-r1", "build": "debug",
  "first_req_ms": 12, "ws_resume_ms": 705, "ws_open_ms": 760, "ui_ms": 1200, "done_ms": 1210,
  "first_request_at": 1791700002112, "ws_open_at": 1791700002860, "ui_connected_at": 1791700003300,
  "candidates": [
    { "h": "192.168.31.20", "req_ms": 38, "cb_ms": 41, "queue_ms": 640, "handle_ms": 12, "won": true },
    { "h": "100.110.76.9", "cb_ms": 60, "queue_ms": 650, "handle_ms": 0, "won": false, "late": true }
  ],
  "busy_ms": 980, "busy_n50": 4, "busy_max_ms": 520,
  "segs": { "entry": 0, "props": 40, "propProviders": 150, "propCards": 220, "initBegin": 260, "container": 900,
            "profiles": 960, "cards": 1000, "initEnd": 1300, "splashRelease": 1500, "contentAppear": 1950, "connect": 1980 },
  "pre_main_ms": 120
}
```

hub 对它贴的理由：`启动慢：init→建库完 640ms；启动慢：init 其余 300ms；启动慢：内容门→首屏 onAppear 450ms；排主线程：探测结果等 640ms；排主线程：连上后等 440ms；连接窗口主线程忙 980ms（>50ms 块 4 个，最长 520ms）`。

### 口径说明：哪些是证据、哪些有偏差

- **证据级**：`segs` 各点间差、`*_ms`（单调、同进程同时钟）；`queue_ms` / `ui_ms − ws_open_ms`（回调线程 → 主线程排队，直接测）；`busy_*`（双观察者，含布局 + CA 提交）。
- **`pre_main_ms` 是墙钟**：`p_starttime` 只有墙钟（timeval），入口那一刻也只能用 `Date()` 对齐，NTP 调表会带进误差（毫秒级，极少）。且 `p_starttime` 是进程创建，不是手指点图标——系统起进程之前的等待不在里面。预热进程不给（点开时刻未知）。可能的 r2：`proc_pid_rusage` 的 `ri_proc_start_abstime` 是单调的，iOS 头文件是否可用未查。
- **`cb_ms` ≠ 纯网络**：含 URLSession 委托队列调度；纯请求看 `req_ms`（URLSessionTaskMetrics）。`req_ms` 在委托队列上异步到，赢家在主线程 block 里马上 `invalidateAndCancel` 探测 session，极端情况下 metrics 没送到就缺（缺 ≠ 0）。
- **`ws_open_ms − ws_resume_ms` ≠ 纯握手**：含 TCP / TLS / HTTP Upgrade + 委托回调调度。WS task 的 metrics 要 task 结束才给，拿不到。
- **`handle_ms`（赢家）含开 WS**：建 URLSession + `webSocketTask` + `resume` + 看门狗，这是主线程上真花的钱，不是排队。
- **`busy_ms` 与 `queue_ms` 重叠**：排队就是因为主线程在忙，两者是同一段时间的两个视角，不能相加；hub 理由是标签不是分解。
- **忙段 ≠ 掉帧**：runloop 忙段是 app 主线程墙钟，不含 render server / GPU，也不是 CPU 时间（主线程等锁 / 等 I/O 也算忙）。
- **窗口起点在忙段中间**：beginEpisode 本身在主线程某个 block 里，开窗那一刻算作段起点（同 MainBlockMonitor.install 的做法），窗口前的半段不算。窗口终点是 ui 时刻，此刻正处在 didOpen 那个 block 里，进行中的段算到 ui 时刻为止。
- **mono 字段起点是连接入口，不是旧 `t0`**：冷启动旧 t0 = 进程起点；回前台旧 t0 = 即将进前台；mono 都从 beginEpisode 那一刻算。后台时间不扣（旧 `bg_ms` 照旧给）。
- **`segs` 只覆盖第一次**：同名取第一次（mac 多窗口、onAppear 重入不会覆盖）。mac 和测试宿主没有开屏点，分段跨过缺的点，统计里段名写成 `上一点→这一点`。
- **观察者效应**：时间戳表加锁追加 ~十几次 / 启动；忙段闭包每 runloop 两次时钟读。量级未测，不能称可忽略（r2 加了 MP_CONNECT_RULER=0 留给 A/A）。`ConnectBusyWindow` 的观察者和 MainBlockMonitor / AirPerfProbe 的同 order 观察者之间执行顺序不确定，互不影响计数。
- **有账的仍只是「连上了并报上来」的启动**：永远连不上、报告前被杀的不在账上（research 探针 6，本轮没补）。

### 测试

- Swift：`MemoryPalaceTests/ConnectRulerTests.swift`（时间戳表、忙段累加、窗口幂等、候选 JSON 只有 host + 数字、metrics 回填、报告组装、缺字段不出），mac 定向跑。
- hub：`bun test` 全量 + `bunx tsc --noEmit`。
- 结果（10-11）：mac 定向 `ConnectRulerTests` 8/0、`CCBridgeHealthURLTests` 9/0、`CCRelayPairingTests` 13/0，`** TEST SUCCEEDED **`。`bun test connect-ledger.test.ts` 17/0；全量 915 pass / 6 fail——5 条 warroom-scan-worker K2 是机器负载 200+ 时的 5–6s 超时，单独重跑全过；1 条 agora-store round_robin 是已知 flaky（单独连跑 3 次 1 次过），都与本改动无关。`tsc --noEmit` 206（与改前相同）。

### 未查证 / 待上线后看

- **iOS 没本地编**（工位不本地编译），iOS 专属的 `LaunchSplash.swift` 那一点只过了读码；mac 测试目标编过。
- 没在设备 / 模拟器上跑过：样例 JSON 是造的，`req_ms` 在真机上是否总能收到、`busy_*` 量级、`segs` 各点先后（尤其 `splashRelease` 与 `contentAppear`、mac 上 `connect` 可能早于 `contentAppear`——内嵌 hub 那条路 `CCHubProcess` 先连）都待现场看。
- 上线后（她正常用 1–2 天）看：`bun scripts/connect-ledger.ts --hours 48` 的「尺子拆分」段——
  1. 冷启动：`启动 *` 各段 p50/p75 谁最大（建库？开屏门？首屏 onAppear？），`pre_main_ms` 有多少；
  2. `探测 回调→主线程` 与 `WS didOpen→主线程` 的 p75（A1 transport executor 能省的上限）；
  3. `探测 请求（metrics）`、`WS resume→didOpen`（真网络底，A8 快车道的上限）；
  4. `窗口主线程忙` 与 `>50ms 块数`（A3–A7 的空间）；
  5. `build` 分组：模拟器是不是 debug 包（A3 是否有意义）；
  6. `launch_fail` 出现频率。
- 尺子本身待 sol 审一轮（「口径有没有自欺」），plan §5 尺子项不勾。

## 尺子 r2 · sol R1 裁决（harnessRevision `connectV2-r2`，统计口径 `ledgerStats-r2`）

> sol 审 r1 结论：局部排队能看，但判断不了 A1 / A2 各能省多少；缺终点、样本身份、早连资格点、尝试代次。车头裁定 11 条全收（6 由 P1 降 P2），在 backend-4 返工。r1 字段名里被改掉的（`done_ms` / `req_ms`）只存在于未合并的 r1，账本里没有 r1 数据，hub 只认 r2 名字。

### 裁决表

| # | sol 意见（严重度） | 裁决 | 落实 | 提交 |
|---|---|---|---|---|
| 1 | 新版「全程」提前结束：`ui_ms` 只是主线程进入，`done_ms` 不是报告组好；样例 `open_at < ui_connected_at`（P1） | 收 | 加 `client_info_ms` = client_info 交给当前 task（`send` 同步调完 `task.send`）那一刻，作计划终点；`ui_ms` 改称「主线程进入」；`done_ms` 改名 `finish_ms` =「finishEpisode 开始组报告」（= 旧 `open_at` 同一刻）；样例墙钟改成自洽并加测试断言 | `9d0e5c3e0` |
| 2 | 分组缺包 / 变体 / 稳定设备身份，`from` 是网络地址（P1） | 收 | `bin` = 本模块镜像 LC_UUID（`#dsohandle`，Debug 即 `.debug.dylib`；只读内存 Mach-O 头）；`sw` = A 刀开关表（现在 `{}`）；`dev` = app 自生成随机 UUID 存 UserDefaults（不读硬件 / 广告标识）；`run` = 每进程 UUID；hub 统计按 `trigger · 平台 · dev × bin × sw · rev` 分组，不再用 `from` | `e66d56104` `68c9a23ec` |
| 3 | 缺 A2 安全起跑线（P1） | 收 | `bootstrapEligible` 点：init 里 pending import 处理完（BFU 闸在 AppEntry.main 已过）；`recovery` 数组：`pending.succeeded / versionMismatch / failed.<step>`、`stRecover`、`profilesUntrusted`、`unifiedMigration`。handlers 就绪 / 早到帧留给 A2 | `6132da579` |
| 4 | WS 时间戳没绑 episode，旧 task 能污染新报告（P1） | 收 | WS resume 登记进程内尝试序号 + `probeGeneration`；didOpen 过了生产 `===` 守卫后再核三条（task 是最后那次尝试的、尝试属于这一段、代次没变），对不上只计 `ws_invalid`、不写时间戳；连接逻辑没动 | `9d0e5c3e0` |
| 5 | 样本选择偏差、启动来源、计数、旧汇总没去预热（P1） | 部分收 | `launch_src`（prewarm / push / icon / voip / unknown）；进程内计数 `counts{started, ok, replaced, report_failed}` 每份报告带（`report_failed` 下一份才看得到）；被杀样本不持久化，统计标题写「仅成功上报样本」；脚本顶部旧汇总剔除预热 | `e66d56104` `68c9a23ec` |
| 6 | 前 50 条截断可能丢赢家；「最后一个 won」未必是最终 WS（P1→P2） | 收 | 候选 id =「代次.序号」，带 `round` / `at_ms`；赢家 id 在开 WS 前记下，那次 resume 取走写 `ws_via`（代次对不上 = `direct`）；hub 按 `ws_via` 找赢家；候选只留最近 32 条，计 `cand_dropped` | `951e44ae2` `68c9a23ec` |
| 7 | 「真网络」标签过强；hub 卡顿是相关不是因果（P2） | 收 | `req_ms` → `task_ms`，理由叫「URLSession 任务生命周期」（taskInterval = task 创建 → 完成）；「WS resume→delegate 回调」照实命名；尺子行的 hub 卡顿写「与连接窗口重叠（相关，非因果）」 | `951e44ae2` `68c9a23ec` |
| 8 | 60s 不是实际封顶，capped 样本混进统计（P2） | 收 | 开段 / 收段 / 汇总都裁到 deadline，过了就 capped 并冻结摘观察者；新增 `busy_window_ms` = 实际覆盖窗口；统计里 capped 样本不进忙段分位数、单列计数，理由写「超时截断（只记前 N ms）」 | `951e44ae2` `68c9a23ec` |
| 9 | connect 分段重复计探针成本；禁用开屏时首开没打点；逆序（P2） | 收 | `segs.connect` 直接用冷启动那段的 `entryNs`（不另打点；`entryNs` 同时是忙段窗口起点）；`LaunchSplash.preload` 同步开门那条路也打 `splashRelease`（同名取第一次）；hub 按固定顺序出现负段 = 「启动分段逆序（不可分解）」，不进分段分位数 | `6132da579` `68c9a23ec` |
| 10 | 分位数约定未注明，小样本被极值决定（P2） | 收 | nearest-rank（第 ⌈p·n⌉ 个），注释写定义；n<5 的指标直接列原始值；统计口径升 `ledgerStats-r2`，打在标题上 | `68c9a23ec` |
| 11 | 「零时序影响」论证不足（P2，风险未实测） | 收 | 文档改为「连接控制流未改」；`MP_CONNECT_RULER=0`（进程启动读一次）关掉所有新埋点：不读时钟、不加锁、不挂观察者、`episode.ruler = nil`、报告不带新字段；探测 task 映射在 resume 前登记，时刻紧贴 `resume()` 前取，簿记挪到 resume 之后（WS 同理） | `f490db3ab` |

### r2 字段（相对 r1 的增改；`*_ms` 单调、从连接入口算；`*_at` 墙钟只做对齐）

| 字段 | 含义 |
|---|---|
| `run` / `dev` / `bin` / `sw` / `ep` | 进程 runId / 匿名设备 id / 镜像 LC_UUID / A 刀开关表 / 进程内第几段 |
| `counts` | `{started, ok, replaced, report_failed}`，进程内截至这份报告 |
| `ws_attempt` / `ws_gen` / `ws_via` | 最终 WS 的尝试序号 / 代次 / 由哪个探测候选发起（`direct` = 单候选直连） |
| `ui_ms` | 主线程进入（didOpen 排到主线程的 block 首行）——不是终点 |
| `client_info_ms` | **终点**：client_info 交给当前 task |
| `finish_ms` | finishEpisode 开始组报告（替 r1 `done_ms`） |
| `ws_invalid` | didOpen 归属对不上的次数（对不上的不记） |
| `candidates[].{id, round, at_ms, task_ms}` | 候选 id / 代次 / resume 距入口 / URLSession 任务生命周期（替 `req_ms`） |
| `cand_dropped` | 候选超 32 条丢掉的数量 |
| `busy_window_ms` | 忙段实际覆盖窗口（截断时 = 60000） |
| `launch_src` / `recovery` | 启动来源 / 恢复分支（只冷启动） |
| `segs.bootstrapEligible` | A2 起跑线；`segs.connect` 改为直接用 entryNs |

### r2 落点（新增 / 改动，文件:行号）

- `MemoryPalace/Services/ConnectRuler.swift`：`ConnectRuler.enabled / stamp / runId / switches / binaryUUID / imageUUID / deviceId / launchSource`、`ConnectRunCounters`、`LaunchMarks.note / bootstrapEligible / offsets(connectNs:)`、候选 id、`BusyAccumulator` deadline、`ConnectRulerEpisode.noteOpen / noteClientInfo / fields(finishNs:deviceId:launch:)`。
- `CCBridgeWebSocketClient.swift`：`:396` ruler 可空（关尺子为 nil）；`:403` `rulerProbeWinner`；`:426` replaced 计数；`:441–442` `finish_ms` 时刻 + ok 计数；`:455` 合字段；`:459` 报告发送失败计数；`:463–473` 冷启动 LaunchInfo；`:476–489` WS 尝试登记 / didOpen 归属；`:1313–1314` timings 可空；`:1343 / :1346` 回调 / 主线程进入时刻；`:1350` 候选（带代次）；`:1360` 记赢家 id；`:1375–1378` 映射先登记 → 时刻 → resume → 补记；`:1437–1439` WS 同理；`:2051 / :2053` wsOpen / 主线程进入；`:2058` 归属核对；`:2082` client_info 终点。
- `MemoryPalaceApp.swift:794` bootstrapEligible + pending 分支；`:810` stRecover；`:824` profilesUntrusted；`:857` unifiedMigration（各一行）。
- `LaunchSplash.swift:84` 禁用开屏同步开门那条路打 splashRelease。
- `PushNotifications.swift:13` 启动来源；`NativeVoiceCall.swift:271 / :276` VoIP 推送到达。
- hub：`cc-bridge/connect-ledger.ts`（parse / `finalCandidate` / `launchSegments` 返回 ordered / `rulerReasons` / `rulerGroupKey` / `runTotals` / `rulerMetrics` 单列 / `quantile` nearest-rank / `describeDist` / `STATS_REV`）；`cc-bridge/scripts/connect-ledger.ts`（标题、顶部汇总去预热、按组输出计数 / 来源 / 单列 / 分布）。

### r2 样例（造的；墙钟自洽：t0 1000 + launch 2100 = 入口 3100）

```json
{
  "type": "connect_report", "trigger": "launch", "t0": 1000, "open_at": 4308, "total_ms": 3308, "launch_ms": 2100,
  "main_delay_ms": 640, "host": "192.168.31.20", "path": "satisfied|en0", "attempts": [{ "h": "192.168.31.20", "r": "ok", "ms": 700 }],
  "rev": "connectV2-r2", "build": "debug", "run": "6F1C…", "dev": "A93E…", "bin": "3B7D…", "sw": {}, "ep": 1,
  "counts": { "started": 1, "ok": 1, "replaced": 0, "report_failed": 0 },
  "first_req_ms": 12, "ws_attempt": 1, "ws_gen": 4, "ws_via": "4.0", "ws_resume_ms": 705, "ws_open_ms": 760,
  "ui_ms": 1200, "client_info_ms": 1205, "finish_ms": 1208,
  "first_request_at": 3112, "ws_open_at": 3860, "ui_connected_at": 4300,
  "candidates": [
    { "id": "4.0", "round": 4, "h": "192.168.31.20", "at_ms": 12, "task_ms": 38, "cb_ms": 41, "queue_ms": 640, "handle_ms": 12, "won": true },
    { "id": "4.1", "round": 4, "h": "100.110.76.9", "at_ms": 12, "cb_ms": 60, "queue_ms": 650, "handle_ms": 0, "won": false, "late": true }
  ],
  "busy_ms": 980, "busy_n50": 4, "busy_max_ms": 520, "busy_window_ms": 1200,
  "segs": { "entry": 0, "props": 40, "propProviders": 150, "propCards": 220, "initBegin": 260, "bootstrapEligible": 300, "container": 900,
            "profiles": 960, "cards": 1000, "initEnd": 1300, "splashRelease": 1500, "contentAppear": 1950, "connect": 1980 },
  "pre_main_ms": 120, "launch_src": "icon", "recovery": []
}
```

### r2 仍有的口径边界

- **终点是「交给 task」不是「hub 收到」**：`client_info_ms` 之后 URLSession 还要排发送；hub 端收到时刻要跨端对时，未做。
- `bin` 只证明是哪个镜像；同一镜像里的运行时开关靠 `sw` 登记，A 刀上线时每刀必须在 `ConnectRuler.switches()` 加一行，否则分组还会混。
- `dev` 卸载重装会换；首次生成时写一次 UserDefaults（主线程，cfprefsd 异步落盘）。
- `launch_src`：`icon` 也包含 URL / 快捷方式 / 小组件拉起；mac 没有 didFinishLaunching 这条记录，全是 `unknown`；VoIP 拉起只有在推送早于报告到达时才认得出来。
- `counts` 只覆盖活到下一份报告的进程；被杀的进程整进程不在账上（标题已写明）。
- `task_ms` 仍是墙钟区间（`DateInterval`），且含 task 创建后未 resume 的那点时间；`WS resume→delegate 回调` 含系统调度。要纯网络分解得再取 transaction metrics（没做）。
- 埋点成本（时钟读、unfair lock、委托回调）量级未测；`MP_CONNECT_RULER=0` 已就位，A/A 校准没跑。
- 忙段截断后观察者的物理摘除要等主线程下一次跑到观察者回调；之前的忙已按 deadline 裁掉，不影响数。

### 测试（r2）

- mac 定向（MemoryPalaceTests，-only-testing，-skipPackageUpdates）：`Test Suite 'ConnectRulerTests' passed`（Executed 17 tests, with 0 failures）、`Test Suite 'CCBridgeHealthURLTests' passed`（9/0）、`Test Suite 'CCRelayPairingTests' passed`（13/0），`** TEST SUCCEEDED **`；改到的文件无新 warning。第一轮 8 条失败全是测试写法：临时 `NSObject()` 释放后地址被复用（`ObjectIdentifier` 相等）、墙钟样例 100.63 浮点截断——改测试后过，产品代码没动。
- hub：`bun test connect-ledger` 21 pass / 0 fail；`bunx tsc --noEmit` 206（与改前相同）。全量 920 pass / 5 fail，都与本改动无关：stream-runner 2 条（spawn 计时，机器负载 160+）单独重跑 7/0 全过；hub.test L4 terminal_attach / terminal_paste 2 条与 stream-runner 一起重跑过；agora-store round_robin 是已知 flaky。

### 未查证（r2）

- iOS 没本地编（工位规矩），`PushNotifications.swift` / `NativeVoiceCall.swift` / `LaunchSplash.swift` 这几处 iOS 专属点只读过码；mac 测试目标编过。
- 没上设备 / 模拟器；样例是造的。`bin` 在 iOS Debug 包里取到的是不是 `.debug.dylib`（预期是）、`launch_src` 在真机上的分布、`ws_invalid` 实际出现频率，都待现场。

## A1 · transport executor（开关 `MP_APP_CONNECT_A1`，默认 1；`sw.A1` 分组）

> 10-11 · 🎩 backend-4 · 粟粟已 go（plan §3 A1）。提交 `d67f78dd3`（实现）、`a2edd32b0`（测试）。

### 假设

基线（[基线](app-connect-基线.md)）：开始连之后主线程一整块 0.5–1.2s 不放手，探测回调排 537–881ms 才进主线程；网络（探测 + WS 握手）只 50–130ms。探测选赢家 → 开 WS → didOpen → client_info 这条路只要不经过主线程，「开始连 → client_info」就该落到网络耗时附近（几十到一两百 ms），iPhone 全程 p50 从 ~1.0–1.6s 降到 ~0.4–0.6s。那一整块主线程工作本身不变（它挡的是首次点击 / 打字，不是连接）。

### 改动

`CCBridgeWebSocketClient` 加 transport 上下文：A1=1 是私有串行队列 `cc.bridge.transport`（`.userInitiated`），**同时是探测 session 和 WS session 的 delegateQueue**（`OperationQueue.underlyingQueue`，并发 1）——探测完成回调、didOpen、收帧、send 完成、认证挑战都直接落在它上面，不再先落 Foundation 自建队列再 `main.async`。A1=0 时 transport 就是主线程，delegateQueue 回到 nil，回调照旧 `main.async`、定时器照旧挂主 RunLoop——**恢复主线程调用链的主要行为**（didOpen 仍是原主线程 block、client_info 之后再报 focus / 推送 token / CC 设置）。不是逐行一致：R1 的正确性修复（task 身份绑定、用户消息回执、帧带来源连接、reply/edit 有序通道、计数加锁，见下「sol R1 裁决」）两条路共用。

状态所有权表（行号是 `d67f78dd3` 的 `MemoryPalace/Services/CCBridgeWebSocketClient.swift`）：

| 状态 | 原来 | A1=1 现在 | 跨线程读 |
|---|---|---|---|
| `task` / `url` / `urls` | 主线程读写（`send`、handlersQueue 补订阅其实也在别的线程读，原本就是裸读） | transport 写；`OSAllocatedUnfairLock` 包着（`:81`），任何线程读 | `send`、handlersQueue、主线程 `isConnecting` / `currentHost` / `candidateHosts` |
| `session` / `probeSession` / `probeGeneration` | 主线程 | transport | — |
| 探测 `settled` / `failures` / `failReasons`（`startTask` 局部捕获） | 主线程（「都在 main queue 串行访问」） | transport（完成回调本来就落在 transport 上，内联） | — |
| `episode`（含 bgSince / waitMs / attempts / mainDelayMs / ruler） | 主线程 | transport；前后台通知在主线程取时刻后排进 transport 改 | — |
| `rulerWSAttemptSeq` / `rulerLastWS` / `rulerProbeWinner` / `launchEpisodeStarted` | 主线程 | transport | — |
| `reconnectDelay` / `reconnectTimer` | 主线程 + `Timer.scheduledTimer` | transport + `DispatchSourceTimer`（`makeTimer` `:532`） | — |
| `connectWatchdog` / `pingTimer` | 主线程 + Timer 挂 `.common` | transport + `DispatchSourceTimer` | — |
| `manualClose` / `wasBackgrounded` / `probeConnectedAt` / `lastPathSignature` | 主线程 | transport | — |
| 新 `socketOpen`（`:107`）——**R1 #3 已删**，改 `openedTask` + `isOpenNow` | （原来用 `isConnected` 做连接决策） | transport；与 `isConnected` 同时机翻，看门狗 / connect 去重 / reconnectNow 只看它 | — |
| 新 `openedTask` / `preOpenFrames`（`:109`） | — | transport（帧门，见下） | — |
| `replyCursor` | 主线程读写 | 主线程推进、transport 开 WS 时读；锁（`:370`） | 是 |
| `isForeground` | 主线程 | 主线程写、transport 读（退避节奏、didOpen 报 terminal_active）；锁（`:715`） | 是 |
| `isConnected` / `lastError` / `hubInfoIsCurrent` / `hubSupportsTerminalPaste` / `lastOpenAt` / `lastSentFocus` / `pushToken` | 主线程 | **仍只在主线程写**：transport 经 `toMain` 投快照 | — |
| 连接窗口忙段观察者 | 主线程，挂在 `episode.ruler` 里 | 主线程 `mainBusyWindows[episodeId]`（`:471`），transport 建段时投主线程挂、主线程进入时收 | — |
| `seenReplyIds` / `seenThinkingIds` / 各 handlers 表 | handlersQueue | 不变 | — |

入口：`connect()` / `disconnect()` 同步排进 transport（`transportSync` `:494`）——`connect` 的去重判断 + 换目标 + `failHubRequests` + 起探测一次做完再返回，调用方紧跟着登记的 hub 请求仍排在作废之后（跟原来一样）；`disconnect` 返回时 task 已摘，主线程上还没轮到的旧快照按 task 对不上作废。`reconnectNow` / 回前台 / 进后台 / `NWPathMonitor` / 退避与看门狗定时器异步排进 transport；`reconnectNow` 在 transport 上再核一次 `!socketOpen`（主线程看到没连上 → 排到 transport 之间可能刚连上）。transport 上的代码从不 `main.sync`，主线程 sync 进来不会死锁。

didOpen（`handleOpenOnTransport` `:2366`）：在 transport 上核 `task ===`、记尺子 wsOpen、清看门狗、`socketOpen = true`、起 ping、补订阅终端（handlersQueue）、`terminal_active`、**`client_info`**、记 client_info 终点、摘下这一段账本（旧字段 + 探针行，= 原 finishEpisode 那一刻），然后把「已连上」快照 `main.async` 出去。主线程 `applyOpened`（`:2403`）首行记 ui 时刻、收忙段、发 connect_report；task 已换 / 已断就到此为止（账本照发），否则 `isConnected = true` 等 + 推送 token / LA / focus / CC 设置 / 记忆清单 / Mac 绑定——内容和顺序同原 block 里 client_info 之后那段。

**didOpen 快照先于首批业务帧**：原来靠「didOpen 和收帧同在一个委托队列串行回调、各自 `main.async`」隐式保证。现在显式两层：① didOpen 和收帧都在 transport 上串行处理，快照在 didOpen 处理里先 `main.async`，之后才处理的帧投主线程（`main.async` / handlersQueue→main / `Task { @MainActor }`，都进主队列 FIFO）一定排在它后面；② 帧门（`ingest` `:1715`）：某个 task 的 didOpen 还没在 transport 上处理完（`openedTask !== task`）时到的帧压进 `preOpenFrames`，didOpen 处理里快照排进主队列后按到达顺序放出（有放出会记一行探针）。这对 `hello` 尤其要紧：快照会把 `hubInfoIsCurrent` 落 false，`hello` 必须在它之后才能翻回 true。

尺子：`ConnectRuler.switches()` 登记 `{"A1": "0|1"}`；报告新增 `transport`（`main` / `a1`，按实例的实际路径）。`ConnectRulerEpisode.noteOpen` 拆成 `noteTransportOpen`（核归属、记 wsOpen）+ `noteUI`（主线程进入 + 忙段），`noteClientInfo` 改认 wsOpen（A1 下 client_info 早于主线程进入）。A1=0 路径调用的仍是合起来的 `noteOpen`，字段值不变。

### A1 下字段怎么读

- `candidates[].queue_ms`：完成回调 → 状态机处理，A1 下 ≈ 0（同一队列内联）；`handle_ms` 含 openSocket（建 session + resume），在 transport 上。
- `ui_ms`：仍是主线程进入（`applyOpened` 首行），A1 下它会**晚于** `client_info_ms`——差值就是主线程那一整块的排队，它不再挡连接。
- `client_info_ms`：终点不变（交给 task），A1 下在 transport 上取。
- `finish_ms` / 旧 `open_at` / `total_ms`：摘账本那一刻，A1 下在 transport 上、client_info 之后，同原「finishEpisode 开始组报告」口径。
- `main_delay_ms`（旧字段）：A1 下是「回调 → transport 处理」的排队（≈0），**不再是主线程排队**；A1=0 / A1=1 不能直接比，按 `sw.A1` 分组看。
- `busy_*`：窗口 = 连接入口 → 主线程进入（同原定义）。A1 下观察者是 transport 建段后投主线程挂的，主线程正忙时会晚挂，但段起点用入口时刻，入口到第一次 beforeWaiting 记成忙；主线程空闲时这段只多算几 ms。

### 风险

- **接线晚于 client_info**：focus / 推送 token / CC 设置 / 记忆清单原来紧跟 client_info 发，现在等主线程空出来（冷启动最多 0.5–1.2s）。这段时间 hub 当她没在看任何会话，新回复可能多推一条通知；CC 设置未重发前 hub 用旧配置。没改顺序，只是拉开了间隔。
- **大帧在 transport 上解析**：收帧的 JSON / base64 解析原来在 Foundation 委托队列，现在在 transport（研报帧实测 4.8MB），解析期间探测 / 重连会排在它后面；`connect` / `disconnect` 的 `transportSync` 也可能被它挡几十 ms。
- **快照作废的边角**：transport 已判打开、主线程还没应用时 task 被换（换网重竞速）——原来这时 `isConnected` 会先被置 true，现在快照按 task 对不上直接作废，界面保持「没连上」直到新 task 打开。`socketOpen` 照原 `isConnected` 语义不因换 task 清零（原有怪癖：新 task 握手期间看门狗不触发），未改。
- `terminal_active` 在 transport 上读前后台锁：进后台通知与 didOpen 同时发生时，有微秒级窗口发出旧值（随后主线程的那帧会纠正）。
- `probeReplyCount`（探针计数）原来主线程清零 / handlersQueue 自增就有竞态，现在变成 transport 清零，未修。
- Debug 包里 transport 专属状态在别处被写 → 计数 + 探针 `transport ownership break at …`（不崩）；现场 bridge-probe.log 出现这行就是漏网之处。

### 测试（mac 定向，`MemoryPalaceTests`，`-skipPackageUpdates`）

- 新 `MemoryPalaceTests/CCBridgeTransportA1Tests.swift` 7 条（task 从不 resume、connect 在测试宿主被挡在发请求前，不碰网络）：早到帧（直接 main.async 的 edit、走 handlersQueue 的 reply）到主线程时 `isConnected` 已是 true 且按到达顺序；旧 task 的 didOpen / 帧作废、不压不放；快照排队时 `disconnect` 作废它；断线 → 「断了」快照 → 退避定时器在 transport 上到点起探测；8 个后台线程乱序打入口 + 主线程 reconnectNow，`transportOwnershipBreaks == 0`；A1 报告 `transport=a1`、`ws_open ≤ client_info ≤ ui`；A1=0 回退：didOpen 从后台线程来照旧排主线程、早到帧不压（`early:false`，原行为）、`transport=main`。
- `ConnectRulerTests` 新 1 条（A1 拆分：client_info 早于 ui 照认、noteUI 只认一次、没核过打开的 ui 不认）、`sw` 断言改为 `switches()`。
- 结果（10-11 20:45）：`Test Suite 'CCBridgeTransportA1Tests' passed`（7/0）、`'ConnectRulerTests' passed`（18/0）、`'CCBridgeReplyDedupOrderTests' passed`（3/0）、`'CCBridgeHealthURLTests' passed`（9/0）、`'CCBridgeTerminalInputChunkTests' passed`（4/0）、`'CCRelayPairingTests' passed`（13/0）、`'TestHostIsolationTests' passed`（11/0），共 65/0，`** TEST SUCCEEDED **`；改到的三个文件 0 warning。A1 测试类 `-test-iterations 5` 连跑 35/0（7 条 × 5 遍，查并发 flaky）。

### 未查证 / 待现场验证

- **iOS 没本地编**（工位规矩）：`handleAppBackground` / `handleAppForeground`（`#if canImport(UIKit)`）、didOpen 里 `#if os(iOS)` 的 client_info / LA 只读过码；mac 测试目标编过。
- 没上设备 / 模拟器；没连过真 hub，所以「委托队列 = transport 时探测完成回调 / receive 回调确实落在 transport 上」只在代码层面成立（`onTransport` 不在就排队，落错也只是多一跳）。
- 合并后粟粟正常用 → `bun scripts/connect-ledger.ts --hours 24` 看 `sw{A1=1}` 组：`开始连 → client_info`（`client_info_ms`）p50 / p75 对比基线 648–1230ms，预期落到 ~60–150ms；`探测 回调→主线程` 应 ≈0；`ui_ms − client_info_ms` 就是主线程那块的排队（不再挡连接）；全程 p75 看 iPhone 能否 ≤1s。模拟器装上带尺子的包后同样看。
- 回退：设 `MP_APP_CONNECT_A1=0`（scheme 环境变量 / launchctl）即恢复主线程调用链的主要行为（不是逐行一致，见上「改动」），账本 `sw.A1=0`。

### sol R1 裁决（10-14 · 🎩 backend-4 返工）

> sol 审第一版（`d67f78dd3` / `a2edd32b0` / `65a350096`）出 12 条，车头裁定全收（6、8、9、12 是旧问题，这次一起修）。核心原则：**用户消息永远不能静默丢；旧 task / 旧 generation 的任何东西（帧、ACK、connect_report、终端分片）不许借新连接发出去、不许在新连接上下文里应用。** 每条（或紧密相关的几条）一个提交，都配回归测试；测试统一用发送替身（`setTransmitHookForTesting`，记下每帧实际发在哪个 task 上、completion 由测试定）+ 队列屏障（`holdTransportForTesting` / `holdParseForTesting`）把交错造出来，能两条路都跑的 A1=1 / A1=0 都跑。

| # | sol 意见（严重度） | 裁决 | 落实 | 提交 |
|---|---|---|---|---|
| 1 | `reconnectNow()` 改异步后，紧接着的用户消息会丢（P1） | 收（两头都做） | `reconnectNow` 改回 `transportSync`：返回时单候选的 task 已建好、多候选的探测已起。`sendUserMessage`：有 task 当场交；没 task 排进 transport——探测正在跑（`probeSession != nil`）就进 `pendingUserFrames`，赢家 `openSocket` 建好 task 立刻按先后发在它上面；没有任何尝试 / 本轮探测全败（`probeRoundFailed`）/ 手动断开 → 气泡当场「没连上电脑，这条没发出去，请重新发一遍」（failed、不可点重发：hub 没记录，`retry` 帧会被它拒）。交给 task 后 send 报错：那个 task 从没打开过 = 肯定没到；打开过（didOpen 处理过 / 回过 101）= 「连接断了，不确定电脑收到没有，看一眼再决定要不要重新发」。测试：`testReconnectNowIsSyncAndFollowingMessageGetsReceipt`、`testMessageDuringProbeWaitsForWinnerTask`、`testPendingMessagesFailWhenAttemptEnds`、`testSendErrorReceiptDependsOnWhetherTaskOpened` | `d2a50440f` |
| 2 | `handleDisconnect` 摘掉了中途换上的新 task（P1） | 收 | `handleDisconnect(error:from:)` 带上造成断线的 task，在真正清理的块里核 `task === failed`；已在 transport 上（A1 的收帧失败 / didClose / 看门狗）就地处理，不再异步排一跳。同一次断连两个回调照旧只处理一次。握手没成 / 掉线的账本分类也按这个 task 判。测试：`testDisconnectOfOldTaskKeepsSwappedInTaskA1`（屏障下「A 收帧失败」「换上 B」先后排进 transport）、`testDisconnectOfOldTaskKeepsSwappedInTaskMainPath`、`testDuplicateDisconnectCallbacksHandledOnce` | `a8ea21431` `5435dfd8a` |
| 3 | `socketOpen` 要绑到具体 task（P1） | 收 | 删 `socketOpen`，改 `openedTask`（A1=0 主线程 block 里也记）+ `isOpenNow`（`openedTask === task`）。看门狗判「这个 task 自己开没开」；`reconnectNow` 只在当前 task 真打开时 no-op（主线程 `isConnected` 预判拿掉——换 task 期间它还停在上一条的 true）。测试：`testWatchdogFiresForNewHandshakeAfterSwap`、`testWatchdogSparesOpenedTask`、`testManualReconnectNotBlockedBySwappedTask`、`testManualReconnectNoopWhenCurrentTaskOpen` | `a8ea21431` |
| 4 | 终端输入多个分片会跨连接发出去（P1） | 收 | `sendTerminalInput` 开头定下 task，所有片 `send(on:)` 发在它上面；中途失效只报 completion 错误，不自动重发。`sendAttachOnQueue` 记下的 task 就是实际发出的那个；补订阅指定刚打开的 task，它已不是当前 task 就不发（新 task 的 didOpen 自己补）。测试：`testTerminalInputChunksStayOnOneTaskAcrossSwap`、`testTerminalInputFailureReportsWithoutResend`、`testAttachRecordsTheTaskItWasSentOn` | `3ffa8d6ea` |
| 5 | 快照作废了，已放出去的业务帧和 ACK 没跟着作废（P2） | 收 | `handleIncoming(_:source:)`：每帧带着来源 task 走到主线程应用那一步。连接现状类——hello、hub_config、send_status_snapshot、session_model / session_phase、terminal_state、terminal_init（含粘贴能力）/ terminal_chunk——应用前核 `isLive(source)`，失效就丢。持久的 reply / thinking / edit 照旧靠 cursor、重放、落库去重。ACK / 命令结果（agent_book_note_ack、trading_report_ack 含冷启动缓冲回放、pocket_result、twitter_result）只发回来源连接，来源失效就发不出去、hub 在新连接补投。测试：`testStaleConnectionStateFramesAreDropped`、`testLiveConnectionStateFramesApply`、`testAckGoesBackOnSourceConnection` | `fd91ba5b8` `f22c66a4f`（测试编译修） |
| 6 | reply→edit 落地顺序可能颠倒（P2，旧问题） | 收 | edit、流式 thinking 改走 reply / 非流式 thinking 同一条 `handlersQueue → main` 通道，落地顺序 = 到达顺序。测试：`testEditLandsAfterTheReplyItEdits` | `a219031d7` |
| 7 | `terminal_active` 发送顺序（P2） | 收 | 前后台状态只在 transport 上写（`noteBackground` / `noteForeground`，UIKit 通知调），`focus(null)` / `terminal_active` 在同一个 transport block 里发，跟 didOpen 读状态报 active 串行。测试：`testTerminalActiveFollowsForegroundOrder`（屏障下两种先后）、`testBackgroundForegroundActiveFrames` | `c872ea37e` |
| 8 | focus 发晚了，会多推通知（P2，旧问题） | 收 | 上报的会话存进锁保护的快照 `reportedFocusBox`，发送挪到 transport；A1 的 didOpen 在 `client_info` 之前拿最新一份发出去，`applyOpened` 不再补发。之后焦点变了照常更新。A1=0 维持原顺序。测试：`testFocusSentBeforeClientInfo` | `c872ea37e` |
| 9 | 大帧解析没时间上界，拖住 transport（P2，旧问题） | 收 | A1 收帧过帧门后交给串行 `cc.bridge.parse`（保到达顺序），结果带来源 task，解析完回 transport 记账；积压超 32MB 先不 receive（背压），追上来接着收（只对暂停时那个 task 恢复）。`preOpenFrames` 上限 256 条 / 80MB（> 单帧上限 64MB）：超了 = 掐掉这次连接走正常断线重连，丢的帧靠 hub 重放（reply / thinking 带 since= 补，去重兜重复）补回。测试：`testParseQueueKeepsOrderAndDoesNotHoldTransport`、`testPreOpenOverflowDropsConnection`、`testParseBacklogPausesReceiving` | `b0aa7876d` |
| 10 | 失效连接的 connect_report 借新连接发出去（P2） | 收 | 报告发在 `snapshot.task` 上；A1 快照轮到主线程时那次连接已失效 → 只记本地诊断（BridgeProbe 一行 + `report_failed` 计数，下一份报告带上来），不发。A1=0 显式绑 didOpen 的 task。`client_info` 也显式绑 didOpen 的 task。测试：`testStaleConnectReportIsNotSentOnNewConnection`、`testConnectReportSentOnOpenedTask` | `fd91ba5b8` |
| 11 | 测试补强：可控 task + 发送替身 + 队列屏障，固定 1/2/3/4/5/6/7/8/10 的交错；断言实际连接、事件顺序、cursor、ACK、消息结果；早到帧测试改有序比较并加 hello / 送达快照 / reply→edit（P2） | 收 | 新测试类 `CCBridgeTransportA1R1Tests`（见上各行）；替身记每帧的 task 和原文，completion 异步回（同真 URLSession）；交错用 transport / 解析队列屏障或 A1=0 的「委托队列线程 + 主线程排队」造。原 `testEarlyFramesReachMainAfterConnectedSnapshot` 从集合比较改有序比较；新 `testEarlyFramesOrderedWithHelloSnapshotAndEdit`（早到的 hello、送达快照、reply、它的 edit 放出后严格有序，reply 落地时已连上 / hello 已应用 / 快照已对账；reply 带 ts 推进 cursor） | 各提交 + `a219031d7` `5435dfd8a` |
| 12 | `probeReplyCount` 数据竞争（P3，旧问题） | 收 | 改锁保护，自增在锁里 `+= 1`。测试：`testProbeReplyCountIsConsistentAcrossQueues` | `f22c66a4f` |
| — | A1=0 回退的说法（「完整回到 / 逐行一致」不准） | 收（只改文档） | 改为「恢复主线程调用链的主要行为」：transport = 主线程、didOpen 仍是原主线程 block、client_info 之后再报 focus；R1 的正确性修复两条路共用 | 本提交 |

落点（`385dc3ec3` 的 `MemoryPalace/Services/CCBridgeWebSocketClient.swift`）：`isOpenNow` `:110`、`FrameLimits` `:125`、`dropStaleConnectReport` `:659`、`probeReplyCountBox` `:744`、`reportedFocusBox` `:756`、`noteBackground` / `noteForeground` `:782` / `:811`、`reconnectNow` `:841`、`sendAck` / `isLive` / `transmit` `:1072` / `:1078` / `:1086`、`sendUserMessage` → `routeUserFrame` / `transmitUserFrame` / `flushPendingUserFrames` / `failPendingUserFrames` `:1135`–`:1192`、`sendAttachOnQueue` `:1308`、`sendTerminalInput` `:1384`、`probeRoundFailed` `:1748`、`startConnectWatchdog` `:1823`、`ingest` / `enqueueParse` `:1954` / `:1982`、`handleIncoming(_:source:)` `:2007`、`handleDisconnect(error:from:)` `:2550`、`handleOpenOnTransport` `:2678`、`applyOpened` `:2720`。

### R1 后的状态所有权（相对上表的增改）

| 状态 | R1 后 | 跨线程读 |
|---|---|---|
| `openedTask`（替代 `socketOpen`）/ `lastOpenedTask` | transport；A1=0 主线程 block 里也记 | — |
| `pendingUserFrames` | transport（探测期间的用户消息） | — |
| `preOpenBytes` / `parseBacklogBytes` / `receivePausedTask` / `frameLimits` | transport | — |
| 帧解析 | A1：串行 `cc.bridge.parse`；A1=0：委托队列（原样） | 结果带来源 task |
| `reportedFocusBox` | 主线程写、transport 读：锁 | 是 |
| `lastSentFocus` | transport（A1=0 即主线程） | — |
| `isForeground` | **只在 transport 上写**（原主线程写），锁留给读 | 是 |
| `probeReplyCountBox` | 锁：handlersQueue 自增、transport 清零 / 读 | 是 |

### R1 风险 / 边界

- 第一版风险里「focus 等主线程」「大帧在 transport 上解析」「socketOpen 换 task 不清」「terminal_active 微秒窗口」「probeReplyCount 竞态」已由 #8 / #9 / #3 / #7 / #12 修掉。推送 token / CC 设置 / 记忆清单仍跟着「已连上」快照等主线程（没改，sol 没提）。
- 「没发出去」回执是本地判断：task 没打开过就报错 = 一定没到 hub；打开过的报错说「不确定」。hub 之后若推 send_status 照样覆盖。回执不可点重发（hub 没记录会拒 retry），要她重新发一遍——重新发是新 message_id。
- 换 task 期间（换网重竞速、旧 task 还在）主线程 `isConnected` 仍停在上一条的 true（原有行为，未改）；用户消息这时交给旧 task，旧 task 死了报错 → 回执。
- 现状类帧失效即丢的清单是按「新连接上 hub 会重推」挑的；`transport_policies`、`error`、各请求回帧不在清单里（前者是 hub 全局配置、后者按 request_id 认领且换连接时已 `failHubRequests`）。
- 帧门超限断线：理论上一帧 >80MB 才会单帧触发，单帧上限是 64MB，不会自激；条数 256 是防异常 hub 狂发。
- `pocket_cmd` 开着时由 `PocketExecutor` 自己回 `pocket_result`（不在连接文件里），仍走当前连接——禁区外，未改。

### 测试（R1，mac 定向，`MemoryPalaceTests`，`-skipPackageUpdates`）

- 新 `MemoryPalaceTests/CCBridgeTransportA1R1Tests.swift` 28 条（能两条路跑的都 A1=1 / A1=0 各跑一遍）；原 `CCBridgeTransportA1Tests` 7 条（早到帧那条改有序比较、A1=0 回退那条排空 handlersQueue）。
- 结果（10-14 22:43，HEAD `385dc3ec3` 代码 + 本文档提交）：`Test Suite 'CCBridgeTransportA1R1Tests' passed`（28/0）、`'CCBridgeTransportA1Tests' passed`（7/0）、`'ConnectRulerTests' passed`（18/0）、`'CCBridgeReplyDedupOrderTests' passed`（3/0）、`'CCBridgeHealthURLTests' passed`（9/0）、`'CCBridgeTerminalInputChunkTests' passed`（4/0）、`'CCRelayPairingTests' passed`（13/0）、`'CCSendStatusTests' passed`（30/0）、`'TestHostIsolationTests' passed`（11/0）、`'TwitterCCBridgeTests' passed`（3/0），共 126/0，`** TEST SUCCEEDED **`；改到的三个 Swift 文件 0 warning。
- 查 flaky：两个 A1 测试类 `-test-iterations 5` 连跑 175/0（R1 140 + 原 35），`** TEST EXECUTE SUCCEEDED **`。

### 未查证（R1）

- iOS 没本地编：`handleAppBackground` / `handleAppForeground` 改成调 `noteBackground` / `noteForeground`（这两个本身 mac 编过、测过）；`#if os(iOS)` 的 client_info / LA 只读过码。
- 没上设备 / 模拟器，没连真 hub：「发在没打开的 task 上的帧在握手完成后发出」沿用原单候选路径的行为（原来就这样发），R1 没有在真 WS 上复核；`target.response` 回 101 的判定只在代码层面。
- 回执文案没给粟粟看过（设置 / 气泡文案归她定）。

### sol R2 裁决（10-15 · 🎩 backend-4 二轮返工）

> sol 审 R1（`65a350096..19e955048`）：上一轮 1–12 里 2/3/4/6/7/8/10/12 已修，1、5 部分修（残留单列 R1-1 / R1-5），9 限解析阶段，11 测试不够；新增 N1–N5。车头裁定全收。原则不变：用户消息永远不静默丢；旧连接的任何东西不许在新连接上下文里生效。本轮只改工作区（车头验收后按文件提交）。

| # | sol 意见（严重度） | 裁决 | 落实 | 测试 |
|---|---|---|---|---|
| N1 | pending 用户消息没有目标 / 鉴权代次，`connect` 直接换目标（`CCHubProcess.followPortWithMainConnection` 不先 disconnect）后被发往新 hub（P1） | 收 | `pendingUserFrames` 每条带排进来时的 `targetEpoch`；`connect` 走重启分支时候选 URL 集合（含 token= / bundle=）变了 = 换目标或换口令 → `targetEpoch += 1` + 排着的一律「没发出去」回执，不迁移。同一组候选（顺序不同也算）重连、换网 / 前后台 / 退避重探不动代次，排着的照旧等赢家。`flushPendingUserFrames` 只发同代次的，别的回执失败（兜底） | `testPendingMessageFailsOnRetarget`、`testPendingMessageFailsOnTokenChange`、对照 `testPendingMessageSurvivesSameTargetReprobe`（两条路） |
| N2 | 解析队列让旧连接的 `terminal_error` 晚于新连接补订阅落地，凭「当前 task + 最新 attach 记录」放行后在新连接上 spawn；`spawn_cc_ok/err`、`list_sessions_result`、窗口回帧同类（P1） | 收 | `terminal_error` 的来源一直带到 `respawnOrReportOnQueue(session:source:)` / `deliverTerminalError(…source:)`：来源必须还是当前连接、且回音对应的 attach 就交给了它；spawn 只发在来源 task 上（`spawnSession(_:on:)`），spawn 回来时来源还得是当前连接才 reattach（也只发在它上面）/ 报错。无 request_id 的回帧改按来源认领：spawn / list / 窗口的回调连同请求发在哪条连接一起记（`BoundHandler`），回帧来自 S——发在 S 上的请求：S 还是当前连接用这份结果，已失效按「连接断了，没等到电脑回话」失败（不把旧连接的成功交给调用方，免得它在新连接上接着干）；发在别的已失效连接上的请求顺手按失败收掉（再也等不到回帧，别让 continuation 挂死）；发在当前连接上的接着等自己的。`window_ended` 来源失效直接丢（换连接时 `failWindowEnds` 已收、5 秒超时兜底）。发送失败的本地结算照旧全部回 | `testStaleTerminalErrorDoesNotSpawnOnNewConnectionA1`（解析队列屏障固定 sol 的交错）、`testStaleTerminalErrorIgnoredBothPaths`、对照 `testLiveTerminalErrorSpawnsOnItsOwnConnection`、`testStaleSpawnReplyFailsInsteadOfApplying`、`testListResultClaimedBySourceConnection`、`testStaleWindowOpenedNotApplied` |
| N3 | 迟到的本地 send 错误覆盖 hub 终态 / 污染同 id 的新一次发送（P2） | 收 | `CCSendTracker` 加发送尝试身份：`didSend` 返回 `Attempt(messageId, serial)`，同 id 再发换新号。回执只走明确入口——`didHandOff`（交给哪条连接）/ `didFailLocally`（本地写入失败、没交出去）/ `linkLost`（连接没了）/ `didHubAnswer`（ack / 带 message_id 的 error）——不再直接 `store.set`。本地结果只结算当前这次，且这次已收到 hub 回话（ack / `send_status`，含快照）就不再覆盖 | `testLateLocalFailureDoesNotOverrideHubDelivered`、`testLateLocalFailureKeepsHubRetryable`、`testLateFailureOfPreviousAttemptIgnored`（替身扣住 completion 手动放，两条路） |
| N4 | 新消息走主线程「已有 task 就直发」，抢在还没 flush 的 pending 前面（P2） | 收 | 去掉快速路径：`sendUserMessage` 一律 `onTransport { routeUserFrame }`；`routeUserFrame` 有 task 时先 flush 排着的再发这条。A1=0 transport 就是主线程，仍是当场内联。不加自动重发 | `testNewMessageCannotOvertakePendingOnes`（`adoptTaskForTesting(flushPending: false)` 造「task 已可见、flush 没轮到」，两条路） |
| N5 | 测试不能证明声称的交错 / 恢复（P2） | 收 | reply→edit 改为卡住 handlersQueue 再喂帧（卡着时谁都不许落地，放开后有序）；背压用可控 receive（`setReceiveHookForTesting`）证明恢复后下一帧真被接收、任何时候只挂一个 receive——删掉恢复时的 `receiveLoop()` 这条必失败；attach 用 `setAttachRecordedHookForTesting` 在「记下 task」与「真正发送」之间换 task；发送替身支持扣住 completion 手动放（N3）。每条 P1 都有在 bug 存在时失败的回归测试 | R1 测试类里 `testEditLandsAfterTheReplyItEdits`、`testParseBacklogPausesReceiving`、`testAttachRecordsTheTaskItWasSentOn` 改写；新测试类 `CCBridgeTransportA1R2Tests` |
| R1-1 残留 | WS 写成功、hub 没接收时消息仍可静默丢；`ack` 被忽略（P1） | 收 | hub 处理 `send` 后回 `{type:"ack", message_id}`（`cc-bridge/hub.ts:4194`）。WS 写入只算「已交出」（`didHandOff`，不建状态对象 → 气泡外观不变）；来源连接上的 ack（`didHubAnswer(accepted: true, on: source)`）= hub 收下了。没等到 ack 那条连接就断了 / 被换掉（`task` 的 setter 是换 / 摘 task 的唯一入口，被换下的 task 一律走 `userFramesLost`）→ 「连接断了，不确定电脑收到没有…」回执（没打开过的连接 = 「没发出去」），不自动重发。结算排在那条连接已收到、还在解析的帧后面（A1 经 parseQueue 再进主线程；A1=0 解析在委托队列同步做完、投主线程的活已排着），先到的 ack 先认；那条连接上迟到的 ack 照样撤回执。与现有语义的衔接：`didSend` 仍先 `store.remove`（新尝试清旧状态）；`send_status` / 快照列到的以 hub 为准；快照对「本地挂着、快照里没有」的处理不变——「不确定」回执是不可重发的 failed，快照不改它；已 ack 的没有条目，快照也不凭空造。带 message_id 的 `error`（hub 写 tmux 抛错，没 ack）= hub 回过话，不再等 ack，气泡照旧 | `testUnackedMessageGetsUncertainReceiptOnDisconnect`、`testAckedMessageNotMarkedOnDisconnect`、`testAckFromOtherConnectionIgnored`、`testUnackedMessageSettledWhenTaskReplaced`、`testUnopenedTaskReplacedGivesNotSentReceipt`、`testLateAckFromReplacedConnectionClearsReceipt`、`testAckQueuedBeforeDisconnectWinsA1`（解析屏障 + 回执从没闪现过）、`testReconnectSnapshotAfterSettlement` |
| R1-5 残留 | Pocket 开启分支的结果仍借当前连接发（P1） | 收 | `PocketExecutor.execute(_:reply:)`：调用方给结果发送口，所有结果（含 JS / html / 截图的异步回调）只经它发；客户端给的口绑帧的来源连接，来源已换 / 断了只记 BridgeProbe 诊断不发。`PocketExecutor` 不再碰 `CCBridgeWebSocketClient.shared` | `testPocketResultOnlyGoesBackOnSourceConnection`（替身执行器扣住异步结果，两条路） |

落点（工作区，`MemoryPalace/Services/`）：`CCBridgeWebSocketClient.swift`——`task` setter → `userFramesLost` `:91` / `:1291`、`targetEpoch` / pending 代次（`connect` `:954`）、`claimSpawn` / `claim` `:1163` / `:1180`、`sendUserMessage` → `routeUserFrame` → `transmitUserFrame` / `flushPendingUserFrames` `:1228`–`:1260`、`pocket_cmd` `:2160`、`ack` / `error` 分支 `:2347`、`runPocket` `:2630`、`respawnOrReportOnQueue(session:source:)` `:2670`；`CCSendTracking.swift`——`Attempt` / `didHandOff` / `didFailLocally` / `linkLost` / `didHubAnswer` `:221`–`:278`；`PocketExecutor.swift` `execute(_:reply:)` `:43`。

#### R2 后的状态所有权（相对 R1 表的增改）

| 状态 | R2 后 | 跨线程读 |
|---|---|---|
| `pendingUserFrames`（带 `Attempt` + 目标代次）/ `targetEpoch` | transport | — |
| 发送尝试表（`CCSendTracker.open`：排着 / 已交出（绑 task）/ 本地已回执） | 主线程（tracker 原有约定） | — |
| spawn / list / 窗口回调（带请求发出时的 task） | handlersQueue（原样） | 认领时读 `task`（锁） |

#### R2 风险 / 边界

- ack 只带 message_id：同一 id 的两次尝试（重新生成）若都交给同一条连接，第一次的 ack 会被算成第二次的；第二次随后真没进 hub、连接又断了，就会少一张「不确定」回执。hub 的 send 分支是异步处理（`await restarting`），两次 ack 的先后也不保证，app 端区分不了。
- 带 message_id 的 `error` 回帧原来就不上气泡，这轮只是不再等它的 ack（免得断线时误报「不确定」）；要不要给它一张「电脑没收下」回执是产品决定，没做。
- 长连接上一直没等到 ack（hub 卡住不回、但连接活着）不会出回执，直到连接断 / 被换。没加超时（任务书要求不加自动重发，超时文案也没定）。
- spawn / list / 窗口：来源失效的回帧不再交给调用方当成功，改回「连接断了，没等到电脑回话」；hub 那边其实可能已经做了（比如窗口已经开出来），下一轮 `list_windows` 对账会补上。`retrySend` 的重发帧仍从主线程直接交给当前 task（不经 transport 排序、不绑尝试），没动。
- 「换目标」按候选 URL 集合（含 token=、bundle=）判：同一 hub 多给 / 少给一个候选地址也算换目标，排着的消息会回执失败（保守一侧）。

#### 测试（R2，mac 定向，`MemoryPalaceTests`，`-skipPackageUpdates`）

- 新 `MemoryPalaceTests/CCBridgeTransportA1R2Tests.swift` 22 条（能两条路跑的都 A1=1 / A1=0 各一遍）；R1 测试类改写 3 条（N5）。
- 结果（10-15 13:00，HEAD `19e955048` + 工作区，`xcodebuild test`）：`Test Suite 'CCBridgeTransportA1R2Tests' passed`（22/0）、`'CCBridgeTransportA1R1Tests' passed`（28/0）、`'CCBridgeTransportA1Tests' passed`（7/0）、`'ConnectRulerTests' passed`（18/0）、`'CCBridgeReplyDedupOrderTests' passed`（3/0）、`'CCBridgeHealthURLTests' passed`（9/0）、`'CCBridgeTerminalInputChunkTests' passed`（4/0）、`'CCRelayPairingTests' passed`（13/0）、`'CCSendStatusTests' passed`（30/0）、`'TestHostIsolationTests' passed`（11/0）、`'TwitterCCBridgeTests' passed`（3/0），共 148/0，`** TEST SUCCEEDED **`；改到的 Swift 文件（连接客户端、CCSendTracking、PocketExecutor、两个 A1 测试类）0 warning。没有 Pocket 相关的现成测试类。
- 查 flaky：三个 A1 测试类 `-test-iterations 5` 连跑 285/0（R1 140 + R2 110 + 原 35），`** TEST EXECUTE SUCCEEDED **`。
- 变异验证（证明测试在 bug 存在时会失败；跑完已从备份还原，哈希核过）：一次性把 N1（换目标不清 pending）、N4（恢复主线程快速路径）、R1-1（被换下的连接不结算）、N2（respawn 只看当前 task / spawn、list 回帧不看来源）、R1-5（pocket 结果借当前连接）、N5 三处（恢复时不 receive、attach 发送时再读 task、edit 直接 main.async）、N3（本地失败无条件写 store）全改回 bug 形态 → 本轮新增 / 改写的针对性测试 21 条（R2 新增 18 + R1 改写 3）全部失败（同一批里 `testEarlyFramesOrderedWithHelloSnapshotAndEdit` 也因 edit 变异失败）；对照组 `testPendingMessageSurvivesSameTargetReprobe`、`testLiveTerminalErrorSpawnsOnItsOwnConnection`、`testAckedMessageNotMarkedOnDisconnect` 照常通过。顺序类的 `testAckQueuedBeforeDisconnectWinsA1` 单独变异（结算不经 parseQueue、直接排主线程）→ 失败（回执闪现 2 次：先出、再被迟到的 ack 撤掉）。

#### 未查证（R2）

- iOS 没本地编（`PocketExecutor` 的 `#else` 截图分支只读过码）；没上设备 / 模拟器、没连真 hub：hub 回 ack 的时机只按 `cc-bridge/hub.ts:4194` 读码，没在真连接上看过 ack 与断线的先后。
- `PocketExecutor` 没有单测（要建 WKWebView），只验了客户端那一侧的结果发送口。
- 新回执出现的时机（断线时才出「不确定」）没给粟粟看过。

### sol R3 裁决（10-15 · 🎩 backend-4 三轮返工）

> sol 审 R2（`19e955048..8f3c8e0f2`）：N1 / N4 / N5 / R1-5 已修；N2、N3、R1-1 部分修，新出 #1–#6（3 条 P1 + 3 条 P2）。车头裁定全收，只改 app 端、不改 hub / 协议。本轮只改工作区。

| # | sol 意见（严重度） | 裁决 | 落实 | 测试 |
|---|---|---|---|---|
| 1 | Attempt 只约束本地结果，同 id 旧 hub 回话（ack / send_status，同连接或旧连接）仍能注销新尝试的待确认记录（P1） | 收 | `CCSendTracker` 改按「同一连接上的发送先后」配对：每次尝试一条账（`Record`：哪条连接、目标代次、hub 回没回过话、本地给没给过回执），交出的按先后进 `inFlight`。WS 保序 + hub 对每条 send 必回 ack 或 error（重发被拒回 send_status）→ 某连接上某 id 的回话认领这条连接上这个 id 最早交出的那一次；认领到旧尝试只销旧账。`send_status` / 快照带来源连接进 tracker：当前这一次已交出、还没等到直接回话时，状态一律当旧尝试的补账、不动它（例外：当前是重发且排在这条连接最前，被拒时 hub 只回状态，这就是它的回话）；本地给过回执 / 已回过话 / 还没交出去的照常以 hub 为准。收下且没给过回执的尝试账到此为止 | `testOldAckOnSameConnectionDoesNotSettleNewAttempt`、`testOldAckQueuedInParseDoesNotSettleNewAttemptA1`（sol 原交错）、`testOldStatusFromPreviousConnectionDoesNotTouchNewAttempt`、`testSnapshotDoesNotSettleInFlightAttempt`；对照 `testStatusAfterAckApplies` |
| 2 | hub 明确拒收后删掉待确认记录却没有消息级回执（P1） | 收 | 带 message_id、**不带 session_name** 的 `error`（`hub.ts` send 分支 catch）= 对这条 send 的直接回话：按先后认领，认领到当前这一次 → 「电脑没收下这条，请重新发一遍（hub 原因，截 80 字）」，不可重发、不自动重发；之后断线不改成「不确定」。带 session_name 的是核对失败后给旧版 app 的重复通知（`legacyError`，同一结果已由 send_status 送到），不认领 | `testHubRejectionGivesMessageReceipt`、`testOnlyDirectRejectionOfCurrentAttemptSettles`、`testHubRejectedReasonFormatting` |
| 3 | 重发原帧没有目标身份，切换 hub 后会发往另一台（P1） | 收 | 交出时记目标代次（复用 `targetEpoch`，新 task 建立时记 `taskEpoch`）。`connect` 换目标 → `targetChanged`：旧目标上能点重发的条目改成不可重发，「换了电脑，这条请重新发一遍」，原帧放掉；换目标后才落地的旧目标「可重发」状态同样不给资格。同目标重连保留资格。`retrySend` 改为登记新尝试（`beginRetryAttempt`）后走 transport 排序（`routeRetry`）：代次对不上就挡下（原帧不出门）、没连上回「连上后再点」、排着的用户消息先发；completion 只结算这一次重发。顺带：换了目标、旧 task 还没被换下时，用户消息 / 重发不交给旧 task（`taskEpoch != targetEpoch` 视同没有 task） | `testRetryableEntryDisabledOnRetarget`、`testLateRetryableStatusAfterRetargetNotRetryable`；对照 `testRetryKeptAcrossSameTargetReconnect` |
| 4 | BoundHandler 在 handlersQueue 核来源，main 真正交付时可能已换连接（P2） | 收 | 认领后的交付统一走 `deliver(_:_:from:)`：成功结果在调用业务 handler 前再核一次来源连接，失效改回「连接断了，没等到电脑回话」，不静默丢 | `testClaimedSuccessRecheckedBeforeDelivery`（认领后、主线程交付前换 task；list + spawn） |
| 5 | 没有任何回帧时 BoundHandler 永久悬挂 continuation（P2） | 收 | task 的 setter（换 / 摘 task 唯一入口）里 `failRequests(boundTo:)`：在 handlersQueue 上摘走绑定该 task 的 spawn / list / 窗口请求，逐个按失败回。登记也在 handlersQueue 上、登记时核连接还活着：登记排在清理前 → 被清理摘走；排在后 → 当场失败，不挂到死 task 上 | `testBoundRequestsFailWhenConnectionDropsWithoutReply`（spawn / list / list_windows / open / restore 五种） |
| 6 | 本地发送失败不按请求 / 尝试身份结算：spawn 按名字删、list / 窗口 `source:nil` 全量 flush；retry 失败无尝试身份（P2） | 收 | BoundHandler 加请求 id，发送失败只结算这一条（spawn 核 id 才删，list / 窗口按 id 摘）。retry 失败绑这次重发的 Attempt（`retryNotSent(_ attempt:)`），hub 回过话就不覆盖 | `testRequestSendFailureOnlySettlesThatRequest`、`testLateSpawnSendFailureDoesNotTakeNewRequest`、`testLateRetryFailureDoesNotOverrideHubAnswer` |

R2 测试类两条（`testLateLocalFailureDoesNotOverrideHubDelivered`、`testLateLocalFailureKeepsHubRetryable`）改成先 ack 再推状态：R3 起「交出后、ack 之前到的状态」按 #1 算旧尝试的补账，原写法的前提（hub 在收到这条之前就给了它的终态）不再成立。

#### R3 风险 / 边界

- 配对依赖「hub 对每条 send 必回一条 ack / error（重发被拒回 send_status）」。hub 在 ack 之前就推这一次的状态（codex 换思考强度要重启会话那条路，`sendWithEffort` 等重启完才 ack）会被当成旧尝试的补账丢掉；终态 hub 记着，重连快照补回。重发被接受只回 ack（`acceptRetry` 转进行中不广播）；被接受后、注入前失败时 hub 先经 `abortRetry` 推终态再回 error——状态按「重发排在最前、状态就是它的回话」认领这次重发，error 随后落空，无害。
- 同一连接上 hub 写 tmux 失败的 `error` 如果不是对 send 的回话（目前只有 `legacyError` 带 session_name，已排除），会被错配；hub 侧改协议时要同步。
- 长连接活着、hub 一直不回 ack：仍不出回执（没加超时）。
- 本地写入报错、但连接其实还活着时（罕见），那一次留在等回话队列里；同 id 的下一次会先被它的迟到回话（如果有）占位——与 hub 的处理顺序一致，不会错配给更新的一次。
- 换了目标但旧 task 还没换下时，消息不再交给旧 task：探测在跑就排队等新目标的赢家，否则当场「没发出去」。
- 「换目标」仍按候选 URL 集合（含 token= / bundle=）判，偏保守。

#### 测试（R3，mac 定向，`MemoryPalaceTests`，`-skipPackageUpdates`）

- 新 `MemoryPalaceTests/CCBridgeTransportA1R3Tests.swift` 16 条（能两条路跑的都 A1=1 / A1=0 各一遍）；R2 测试类改 2 条（见上）。
- 首轮跑出一个真问题：同一 id 连发两次（重新生成）时，第二次 `didSend` 把第一次还排着、没交出去的账删了，第一次的交出登记落空，它的 ack 被认成第二次的（`testOldAckOnSameConnectionDoesNotSettleNewAttempt` 抓到）。改为上一次的账在交出 / 本地失败之前一直留着；旧的一次本地失败只清账、不出回执。
- 结果（10-15 19:26，HEAD `8f3c8e0f2` + 工作区，`xcodebuild test`）：`Test Suite 'CCBridgeTransportA1R3Tests' passed`（16/0）、`'CCBridgeTransportA1R2Tests' passed`（22/0）、`'CCBridgeTransportA1R1Tests' passed`（28/0）、`'CCBridgeTransportA1Tests' passed`（7/0）、`'ConnectRulerTests' passed`（18/0）、`'CCBridgeReplyDedupOrderTests' passed`（3/0）、`'CCBridgeHealthURLTests' passed`（9/0）、`'CCBridgeTerminalInputChunkTests' passed`（4/0）、`'CCRelayPairingTests' passed`（13/0）、`'CCSendStatusTests' passed`（30/0）、`'TestHostIsolationTests' passed`（11/0）、`'TwitterCCBridgeTests' passed`（3/0），共 164/0，`** TEST SUCCEEDED **`；改到的 Swift 文件 0 warning。
- 查 flaky：四个 A1 测试类 `-test-iterations 5` 连跑 365/0（R1 140 + R2 110 + R3 80 + 原 35），`** TEST EXECUTE SUCCEEDED **`。
- 变异验证（跑完从备份还原，哈希核过）：一次性把 #1（回话按 id 认当前这一次、状态 / 快照不护在途尝试）、#2（拒收不出回执）、#3（换目标不动重发资格、旧目标迟到的可重发状态照给、重发不核代次）、#4（主线程交付不再核来源）、#5（连接失效不摘请求）、#6（发送失败按名字 / 全量结算、重发失败不认尝试）全改回 bug 形态 → R3 针对性测试 13 条全部失败；对照 `testStatusAfterAckApplies`、`testRetryKeptAcrossSameTargetReconnect` 与纯函数 `testHubRejectedReasonFormatting` 照常通过。

#### 未查证（R3）

- iOS 没本地编；没上设备、没连真 hub：ack / error / 重发被拒时的回帧顺序按 `cc-bridge/hub.ts:4155–4201`、`send-verify.ts`、`send-track.ts` 读码。
- 新回执文案（「电脑没收下这条…」「换了电脑，这条请重新发一遍」）没给粟粟看过；气泡组件没改（`visibleReason` 不可重发时直接显示原因，两行截断）。

### sol R4 裁决（10-15 · 🎩 backend-4 四轮返工）

> sol 审 R3（`8f3c8e0f2..5c70d86eb`）：R3 #4–#6 已修，#1 / #3 部分修，新出 2 条 P1 + 2 条 P2，外加「带 session_name 的 error 都是 legacyError」不准（还有 `reportUncertainSend`）。根因：同一 message_id 多次尝试只能靠交出顺序猜归属，而 hub 回话不按交出顺序（codex 重启 await）、abortRetry 一次两帧、快照可早于重发生成。车头裁决：**协议加「尝试编号」**（app 生成、hub 原样带回，纯增字段），本轮允许改 hub。本轮只改工作区。

| # | sol 意见（严重度） | 裁决 | 落实 | 测试 |
|---|---|---|---|---|
| 协议 | 同 id 多次尝试靠 FIFO 猜归属（根因） | 收（改协议） | app：每次发送 / 重发生成 `attempt`（进程内单调号 + 每进程随机前缀，跨进程不撞），写进 send / 重发帧。hub（`send-verify.ts` / `hub.ts`）：`attemptStarted` 记下这一次的 app attempt（跟 hub 自己的 ts 一一对应、随 latest 一起清）；ack、直接 error、被拒重发的 send_status、核对的 uncertain / 终态 / 改原因广播（含 abortRetry 的 finish）、快照条目、`reportUncertainSend` 的 error 都原样带回这个终态所属的 attempt。不带 attempt 的旧 app：所有帧跟原来逐字相同（没有 attempt 键）；retry 准入 / 去重 / 重放逻辑不动 | bun：`A1 R4：app 带的 attempt 记在这一次发送上…`、`A1 R4：重新生成后 appAttemptFor 只认最新那次…`、`A1 R4：appAttemptOf…`、`A1 R4：send 帧带 attempt → ack 原样带回…`、`A1 R4：被拒的重发回的 send_status 带重发自己的 attempt`、`A1 R4：直接 error / 结果不明 error 的帧…` |
| 1 | 新尝试本地结算后，旧 delivered 仍能抹掉它的失败回执（P1） | 收 | 回话 / 状态带 attempt → 按编号认领：是当前这一次的才以 hub 为准；不是 = 旧尝试的补账，**永不撤销、覆盖当前这一次的回执、缓存、等回话的账**（含当前已本地结算）。旧 hub（不带 attempt）兜底也堵上：当前这一次本地已给过回执 / 已交出还在等回话 / 还排着没交出去时，归属不明的状态一律不动它 | `testStaleStatusAfterLocalSettlementKeepsReceipt`（带 / 不带 attempt 两种旧状态） |
| 2 | nil epoch 的缓存能获得重发资格并跨 hub 发出（P1） | 收（只改 app） | 原帧**进缓存时**就绑定当时的目标代次（`didSend` 记 tracker 的当前代次）；交出时代次对不上 = 目标未知；**目标未知 = 不可重发**（`retryAllowed`：做了目标隔离之后原帧代次必须等于现在的目标）。旧尝试的状态不能给新缓存赋予重发资格（见 #1 的认领规则）。换目标时旧目标 / 目标未知的可重发条目一律改不可重发（未知的回执「不确定这条原来发给了哪台电脑，请重新发一遍」）。`routeRetry` 对 nil epoch 直接挡下，原帧不出门 | `testOldStatusCannotMakeUnsentAttemptRetryable`（sol 原交错）、`testRetryWithUnknownTargetIsBlocked` |
| 3 | WS 保序 ≠ ACK 按交出顺序返回，FIFO 错配（P2） | 收（改协议） | 新 hub 的 ack / error 带 attempt，按编号精确认领，不看先后；FIFO 只留给不带 attempt 的旧 hub 兜底 | `testOutOfOrderAcksMatchedByAttempt` |
| 4 | 重发的旧快照吃掉直接回话槽；abortRetry 两帧之间开始的新尝试被错配；终态后账没清干净、记录强持有 task（P2） | 收 | 快照不是对哪一次的直接回话，**不消费等回话的账**：带 attempt 的条目只在就是当前这一次时落状态；不带的只对已回过话 / 没有在途尝试的落。abortRetry 的状态和 error 都带重发自己的 attempt，那一次已不是当前就只销它的账。到 hub 终态（送到 / 不可重发失败 / 没收下 / 结果不明）后这条消息所有尝试的 `latest` / `records` / `inFlight` 一并清掉；账有上限（超了先清已了结、气泡上没状态的老账）；记录对连接只存弱引用，不长期持有 task | `testOldSnapshotDuringRetryDoesNotSettleRetry`、`testAbortRetryErrorDoesNotHitNextRetry`、`testTerminalAnswerCleansBookkeeping` |
| 4 节 | 带 session_name 的 error 不都是 legacyError，还有 `reportUncertainSend`（无 send_status 跟进） | 收 | hub 给 `reportUncertainSend` 的帧加 `uncertain: true` 和这一次的 attempt；app：带 session_name + uncertain + attempt 且是当前这一次 → 「连接断了，不确定电脑收到没有…」回执；legacyError（带 session_name、没有 uncertain）继续不认领 | `testUncertainSendErrorGivesReceipt` |
| R3 #5 测试缺口 | 「清理先、登记后」排序没固定；回调次数没核 | 收 | DEBUG 缝 `setRequestCapturedHookForTesting`（listSessions 记下目标之后、排登记之前）固定「清理先跑、登记后到」；每个回调计数 | `testRegistrationAfterCleanupFailsExactlyOnce`、`testBoundRequestsFailExactlyOnceOnDrop` |
| 兼容 | 旧 hub 不带 attempt | — | 回话不带 attempt：直接回话按这条连接上的交出先后认领（R3 规则），状态 / 快照按上面的兜底规则；结果不明的 error 不带 attempt 不认领 | `testOldHubWithoutAttemptStillWorks` |

R2 测试类 `testReconnectSnapshotAfterSettlement` 的「hub 列了就以 hub 为准」改成带 k8 自己的 attempt（不带的旧 hub 状态归属不明、不撤本地回执，见 #1）；R3 测试类 `testLateRetryFailureDoesNotOverrideHubAnswer` 开头补 `connect`（原帧要绑上目标代次才能重发）。

**上线：合并后要重启一次 hub 才生效**（hub 进程不热更）。没重启前 / 旧 hub：app 照常发 `attempt`（旧 hub 不认、忽略这个字段），回话不带 attempt → 走兼容兜底：直接回话按交出先后（sol R4 #3 的逆序 ACK 错配仍可能）、归属不明的状态不撤当前回执（宁可多留一张「不确定」也不漏报）、结果不明的 error 不出回执。（R5 起旧 hub 兜底改了：无歧义时 hub 的真结果照常覆盖本地回执，见下「R5 上线说明」）

#### R4 风险 / 边界

- 旧 hub 兜底路径的已知缺口：逆序 ACK 错配（#3）、abortRetry 两帧之间的新尝试（#4B）只有新 hub 才彻底解决。
- 兜底路径对「本地已给过回执」的当前尝试，归属不明的状态一律不落：如果那是 hub 对这一次的真结果（旧 hub 不带编号，分不出来），气泡会停在本地回执上（「不确定」/「没发出去」），不会被 hub 的「确认中 / 送到」覆盖。新 hub 带编号，不受影响。
- 原帧绑定的是 tracker 记下的「当前目标代次」（主线程视角）；换目标的瞬间发出的消息若绑在旧代次、实际交给了新目标，交出时代次对不上 → 目标未知 → 不可重发（保守一侧）。
- hub 侧没有 TypeScript 类型检查（`cc-bridge` 没装 tsc，bun 只转译）；改动靠 bun 测试覆盖。

#### 测试（R4）

- app：新 `MemoryPalaceTests/CCBridgeTransportA1R4Tests.swift` 11 条（两条路各一遍）；R2 / R3 测试类各改 1 条（见上）。首轮有一条在 A1=0 下失败，是测试 helper 的问题：上一条连接留下的 `isConnected == true` 让 `openTask` 在新 task 的 didOpen 主线程 block 跑完之前就返回了；helper 改为排空 transport 再让主线程跑一下。
- app 结果（10-15 20:42，HEAD `5c70d86eb` + 工作区，`xcodebuild test`）：`Test Suite 'CCBridgeTransportA1R4Tests' passed`（11/0）、`'CCBridgeTransportA1R3Tests' passed`（16/0）、`'CCBridgeTransportA1R2Tests' passed`（22/0）、`'CCBridgeTransportA1R1Tests' passed`（28/0）、`'CCBridgeTransportA1Tests' passed`（7/0）、`'ConnectRulerTests'`（18/0）、`'CCBridgeReplyDedupOrderTests'`（3/0）、`'CCBridgeHealthURLTests'`（9/0）、`'CCBridgeTerminalInputChunkTests'`（4/0）、`'CCRelayPairingTests'`（13/0）、`'CCSendStatusTests'`（30/0）、`'TestHostIsolationTests'`（11/0）、`'TwitterCCBridgeTests'`（3/0）全部 passed，共 175/0，`** TEST SUCCEEDED **`；改到的 Swift 文件 0 warning。前一次同样的跑法里测试宿主在 `TestHostIsolationTests.testNotificationAdapterIsGated` 意外退出一次（没有崩溃报告，跟 A1 无关）；单独 `-test-iterations 5` 跑这个类 55/0，重跑全套干净通过。
- 查 flaky：五个 A1 测试类 `-test-iterations 5` 连跑 420/0（R1 140 + R2 110 + R3 80 + R4 55 + 原 35），`** TEST EXECUTE SUCCEEDED **`。
- hub（`bun test`，只起临时端口 17890–18889 + `MP_CC_TMUX_DRY_RUN`，没碰 7890）：`send-verify.test.ts` + `send-track.test.ts` 32 pass / 0 fail；`hub.test.ts` 全文件 167 pass / 0 fail（含新加 3 条：ack 带回 attempt / 被拒重发的状态带 attempt / 直接 error 与结果不明 error 的帧）。
- 变异验证（都已从备份还原、哈希核过）：app 端把 #1（不核编号、兜底路径本地已结算照样落）、#2（目标未知也能重发、routeRetry 放过 nil epoch）、#3（回话不看编号只按先后）、#4（快照当直接回话、终态不清账）、结果不明 error 不认领、R3 #5 登记不核连接存活 一次全改回 → R4 针对性测试 9 条全部失败，对照 `testOldHubWithoutAttemptStillWorks`、`testBoundRequestsFailExactlyOnceOnDrop` 照常通过。hub 端把 attempt 不记 / 不带回、结果不明帧去掉 `uncertain` → R4 hub 测试 6 条里 5 条失败（剩下的是纯解析函数 `appAttemptOf`）。

#### 未查证（R4）

- 没连真 hub、没重启生产 hub；hub 侧只跑了临时端口（`hub.test.ts` 随机 17890–18889 + `MP_CC_TMUX_DRY_RUN`）和内存替身。`reportUncertainSend` 在默认 runner 下是否还能触发（sol 也没证实）仍未验证。
- iOS 没本地编；没上设备。新回执文案「不确定这条原来发给了哪台电脑，请重新发一遍」没给粟粟看过。

### sol / astra R5 裁决（10-15 · 🎩 backend-4 五轮返工）

> sol、astra 审 R4（`5c70d86eb..4f0a35699`）：R4 原交错都堵上了，但 #1 / #4 的「按编号认领」把「本地没有这一次的记录」当成了旧结果（重启 / 裁账后真失败被吞），旧 hub 兜底「本地已结算后一律不认」让真送到改不掉回执，hub 内部仍拿毫秒 ts 当发送身份并按 latest 反查编号。两份结论一致，车头裁定全收。本轮只改工作区（车头验收后按文件提交）。

| # | 意见（严重度） | 裁决 | 落实 | 测试 |
|---|---|---|---|---|
| P1-a（sol#1 / astra#3） | 带号结果在本地没有这一次的记录时一律丢：app 重启后的快照 / 实时失败、400 条裁账后迟到的终态都吞成「没回执」（P1，R4 回退） | 收 | `CCSendTracker` 把「每个 message_id 当前那一次的身份」（`idents`：wire + 本进程可能到过 hub 的次数；清理阈值 4000 条，不是硬上限——只清没有重型账也没气泡状态的最老条目，在途未回话的豁免；R6 起只记本机创建 / 跟随的身份）和可裁剪的重型账（`records`）分开：带号状态 / 快照条目 / 没收下与结果不明的 error——编号 ≠ 当前身份 = 已知被本地更新的一次取代，不落；= 当前身份（重型账在不在都算）或本地根本没有这条（重启 / 别的设备发的）= 以 hub 为准落状态，原帧不在就不可重发（气泡写 hub 原因 +「原消息没留住，请重新发一遍」，不再误报「不确定发给了哪台电脑」）。裁重型账、终态清账都不动轻量身份 | app：`testNumberedResultsWithoutLocalHistoryAreRestored`（重启后快照 / 实时 / 结果不明 error 三种，两条路）、`testTerminalAfterRecordTrimmingStillClaimed`（420 条裁账后实时与快照终态都认；对照：被取代的旧编号照旧不落） |
| P1-b（sol#2 / astra#2） | R1 在跑、R2 被「已有操作进行中」拒，hub 回话只带 R2 编号，之后 R1 的 delivered 被当旧结果丢，重连快照再把「确认中」改成失败（P1，回退） | 收 | hub：`acceptRetry(…, appAttempt)` 因 active 拒绝时回帧加 `active_attempt`（正在跑的那次的 app attempt；只给带 attempt 的请求、且 active 那次有编号时加，旧 app 的帧逐字不变）。app：`CCSendStatus.activeAttempt`；当前这次收到带 `active_attempt` 的状态 → 被拒的这次账清掉、跟踪目标切回 active 那次（`follow`：轻量身份改成它、它的重型账还在就重新当当前），它之后的 ack / delivered / failed 正常认领。不加自动重发 | bun：`A1 R5 P1-b：重发因「上一次还在跑」被拒——回帧带正在跑的那次的 active_attempt…`（book）、`A1 R5 P1-b：…回帧带被拒请求自己的 attempt 和正在跑的那次的 active_attempt；不带 attempt 的旧 app 请求回帧不变`（经 `admitAppSend` 真实出口，比完整对象）；app：`testActiveRejectionFollowsActiveAttempt`（sol 原交错：R1 本地写入报错 → R2 → 拒 → R1 delivered → 空快照，气泡始终不误标，两条路） |
| P1-c（sol#3 / astra#4） | 旧 hub（不带 attempt）兜底「本地已结算后一律不认」：ACK 因断线丢了的已送达消息永远停在「不确定 / 没送达」（P1，回退） | 收 | 只在「确有多次尝试歧义」时保守：本地已给过回执的当前这次，若它可能到过 hub（交出过、本地没判定一定没到）且这个进程里这条消息只有它一次可能到过（`soleReached`）→ 无编号的状态 / 快照条目以 hub 为准（真 delivered 撤回执，核对中改回「确认中」），否则照旧不动。还在等直接回话的在途尝试、还没交出去的照 R4 规则 | app：`testOldHubRealResultClearsLocalReceiptWhenUnambiguous`（无歧义的 c1：快照「核对中」+ 实时 delivered 撤回执；对照 c2 交出过两次：保守不撤，两条路） |
| P1-d（sol#4 / astra#1） | hub 内部发送身份用毫秒 ts、核对 / 报错时按 latest 反查 app attempt：同毫秒双发时旧操作带上新编号，失败账落到已送达的新那次（P1） | 收 | hub 新 `SendCtx { key, appAttempt }`：`admitAppSend` 收帧时定下（key = 进程内递增的 `send-N`，不是 ts），随发送一路带：`sendWithEffort` → `ensureSessionAndSend(Async)` → `pendingSends`（队列项改 `{ tag, sc }`，三处 flush 都带上）→ `TmuxRunner.send(text, session, sc)` → `realTmuxRunner` → `SendTracker.send(raw, session, sc)` → `book.begin(…, sc.key, sc.appAttempt)`；`requeue` 带回同一个 sc；`reportUncertainSend(…, sc)` 用这一次自己的编号。`SendStatusBook` 删掉 `latestApp` / `appAttemptFor`，`attemptStarted` 只记身份。被接受的重发只由它自己那次发送接手（`live.attempt === sc.key`），同 id 更早排着的别的发送不许顶替。ts 只留在 channel 标签里当时间 | bun：`A1 R5 P1-d：同一毫秒的两次发送（标签逐字相同）——hub 给各自不重复的身份…`（`admitAppSend` + 固定 `toISOString`，两条标签逐字相同、身份不同，旧那次核对不广播、新那次带自己的编号）、`A1 R5 P1-d：同一毫秒（标签里 ts 一样、整段文字一样）的两次发送…`（SendTracker）、`A1 R5 P1-d：同一个 message_id 两次发送的身份是各自的序号…`（book）、`A1 R5 P1-d：app 消息的发送上下文一路带到会话链…`、`A1 R5：重发途中会话没了 → 交回原有路径时把这一次的发送上下文一起带回去…` |
| P2（#5） | `acceptRetry` 不存编号，附件 / 组帧在 `attemptStarted` 前抛错时 abortRetry 的终态和历史没有 attempt；原测试先手调 attemptStarted 绕过了这个窗口 | 收 | `acceptRetry` 准入成功即把这次重发的 appAttempt 写进 op；`SendTracker.abortRetry(op, reason)` 改为结束准入时拿到的那个 op（不再按 message_id 重查 active）；WS send 分支拆成 `admitAppSend`（准入 / 定身份 / 落盘 / 组帧 / 登记，失败经 `failAppSend` 回话）+ 原有发送尾段，行为与原来一致 | bun：`A1 R5 P2：被接受的重发在组帧时抛错（真实预处理出口，没手调 attemptStarted）…`（`content: null` 让 `buildChannelTag` 真抛，核终态帧 / 直接 error / 快照都带 `app.r1`）、`A1 R5 P2：重发准入成功就把这次重发的 attempt 写进 op…`（book）；原 `审查 R1-8` 用例改传 op |
| P2（#6） | `lastLostLink` 是弱引用，旧连接 task 释放后整段旧账清理跳过，inFlight / records 可无限累积 | 收 | 连接改用 tracker 自己发的连接编号（`LinkSlot { weak object, id }`，记录只存 `linkId`，不持有 task）；断线清理按「上一条没了的连接的编号」清，不要求它还能解包；死槽在发新编号时顺手清 | app：`testLostLinkCleanupAfterTaskReleased`（A 的对象在 autoreleasepool 里真正释放、`weak` 核过为 nil，B 断线时 A 留下的等回话账清掉、回执照留） |
| P3（#7） | `uncertain: true` 无条件加，旧 app 请求收到的帧比原来多一个键 | 收 | `uncertainSendFrame` 只在带 attempt 时加 `uncertain`；旧帧键序 / 内容与 R4 之前逐字相同 | bun：`A1 R4：直接 error / 结果不明 error 的帧…` 补完整对象 `toEqual` + 序列化字节比较 |
| 附（astra §4） | 没有连接级协议模式锁定：同一连接上编号认领和 FIFO / 宽松兜底混用 | 收 | 某连接回过带编号的话（ack / error / 状态 / 快照条目）即记为新 hub 连接（`numberedLinks`）：这条连接上不带编号的直接回话不按先后猜；不带编号的状态 / 快照条目对本地有历史的消息不落；回话带编号的记录（`answeredByNumber`）不被无编号状态覆盖 | app：`testNumberedConnectionIgnoresUnnumberedStatus`（两条路） |
| 附（双方） | 随机前缀只取 UUID 前 8 位（32 位） | 收 | `wirePrefix = UUID().uuidString`（完整 36 位；`<uuid>.<序号>` ≤ hub 接受的 64 字符） | 现有 attempt 用例照过 |

#### R5 上线说明

- **合并后要重启一次 hub 才生效**（hub 进程不热更；`active_attempt`、不重复发送身份、重发准入带编号、结果不明帧分类都在 hub 侧）。app 端无数据迁移。
- 没重启前 / 旧 hub：app 照常发 `attempt`（旧 hub 忽略）。回话不带编号 → 兼容兜底：直接回话按这条连接上的交出先后认领（逆序 ACK 仍可能错配，只有新 hub 根治）；本地已给过回执的当前这次——这个进程里只有它一次可能到过 hub 时，hub 的真结果照常覆盖回执（送到能撤掉「不确定」），交出过多次时保守不动；结果不明的 error 不出回执；`active_attempt` 没有 → 重发被「上一次在跑」拒时，前一次的终态仍认不回来（同 R4）。
- R4 hub（带编号、无 `active_attempt`）：除 P1-b 外 R5 app 行为同新 hub。
- 新 hub + 旧 app：所有给旧 app 的帧（ack、直接 error、结果不明 error、被拒重发的状态、核对状态、快照）与 R4 之前逐字相同（不带 attempt 的请求不出现 `attempt` / `uncertain` / `active_attempt` 键）。

#### R5 风险 / 边界

- 轻量身份的 4000 是清理阈值、不是硬上限（R6 更正）：超过后只清最老的、没有重型账也没有气泡状态的，在途未回话的身份豁免，持续交出却一直不回话时会超过（不做硬预算的理由见 R6 裁决 #2）。被清掉的消息若之后又来一条它的旧编号结果，会按「本地没有历史」落状态（需要同一进程里先发过 4000 多条别的消息，且旧结果迟到）。
- 「本地没有历史」的结果照落：别的设备发的消息的状态现在也会在这台设备上显示（R4 之前不带编号时本来就这样）；hub 的 send_status 本来就广播给所有 app。
- 旧 hub 无歧义判定只看本进程：app 重启后同 id 重新生成（新那次是本进程唯一一次），旧进程那次在旧 hub 上的状态（不带编号）会被当成新那次的结果；需要旧 hub + 重启 + 重新生成 + 新那次断线叠在一起。
- `follow` 只在当前这次收到带 `active_attempt` 的状态时切换；active 那次是旧 app 发起（没有编号）时 hub 不带这个字段，行为同 R4。
- 连接级模式锁定以「回过带编号的话」为准：一条新 hub 连接在第一帧带号回话到达前，仍按旧 hub 兜底处理（此时本地这条连接上还没有被编号回答过的记录可被覆盖）。
- hub 侧仍没有 TypeScript 类型检查（`cc-bridge` 没装 tsc，bun 只转译），改动靠 bun 测试覆盖。

#### 测试（R5）

- app：新 `MemoryPalaceTests/CCBridgeTransportA1R5Tests.swift` 6 条（客户端 4 条两条路各一遍 + tracker 级 2 条）；前几轮测试类未改。
- app 结果（10-15 21:59，HEAD `4f0a35699` + 工作区，`xcodebuild test`）：`Test Suite 'CCBridgeTransportA1R5Tests' passed`（6/0）、`'CCBridgeTransportA1R4Tests' passed`（11/0）、`'CCBridgeTransportA1R3Tests' passed`（16/0）、`'CCBridgeTransportA1R2Tests' passed`（22/0）、`'CCBridgeTransportA1R1Tests' passed`（28/0）、`'CCBridgeTransportA1Tests' passed`（7/0）、`'ConnectRulerTests'`（18/0）、`'CCBridgeReplyDedupOrderTests'`（3/0）、`'CCBridgeHealthURLTests'`（9/0）、`'CCBridgeTerminalInputChunkTests'`（4/0）、`'CCRelayPairingTests'`（13/0）、`'CCSendStatusTests'`（30/0）、`'TestHostIsolationTests'`（11/0）、`'TwitterCCBridgeTests'`（3/0）全部 passed，共 181/0，`** TEST SUCCEEDED **`；改到的 Swift 文件（`CCSendTracking.swift`、新测试类）0 warning。首次 test-without-building 跑法里测试宿主在 `TestHostIsolationTests.testNotificationAdapterIsGated` 意外退出一次（无崩溃报告，同 R4 记过的那次，跟 A1 无关），其余全过；终验这遍干净。
- 查 flaky：六个 A1 测试类 `-test-iterations 5` 连跑 450/0（R1 140 + R2 110 + R3 80 + R4 55 + R5 30 + 原 35），`** TEST EXECUTE SUCCEEDED **`。
- hub（`bun test`，临时端口 17890–18889 + `MP_CC_TMUX_DRY_RUN` + test-preload 临时 secrets，没碰 7890）：`send-verify.test.ts` + `send-track.test.ts` 36 pass / 0 fail；`hub.test.ts` 171 pass / 0 fail（+4：同毫秒双发身份、重发预处理抛错、active 拒绝回帧、上下文进会话链；P3 用例补完整对象）；`hub-send.test.ts` + `hub-model.test.ts` + `agora-cc-executor.test.ts`（用到 runner / 发送链的）54 pass / 0 fail。
- 变异验证（跑完都从备份还原、`shasum` 核过一致）：app 端把 P1-a（没有当前那次的重型账就当旧结果）、P1-b（不跟 `active_attempt`）、P1-c（本地已结算一律不认）、P2 #6（清旧账要求上一条连接的弱引用还能解包）、附（拿掉连接级模式锁定）一次改回 → R5 针对性测试 6 条全部失败，对照 R3 / R4 / `CCSendStatusTests` 照常通过（说明前几轮测试覆盖不到这几处）。hub 端把身份退回毫秒 ts、核对身份从标签 ts 推、重发 op 不核身份 / requeue 不带上下文、准入不写 appAttempt、拒绝不带 `active_attempt`、结果不明帧无条件加 `uncertain` 一次改回 → R5 hub 用例 7 条 + P3 用例（`A1 R4：直接 error / 结果不明 error 的帧…`）共 8 条失败；不受这些变异影响的 book 级身份用例与「上下文进会话链」用例照常通过。

#### 未查证（R5）

- 没连真 hub、没重启生产 hub；hub 侧只跑临时端口（`hub.test.ts` 随机 17890–18889 + `MP_CC_TMUX_DRY_RUN`）、进程内 `admitAppSend`（只到组帧登记、不注入不碰 LA，secrets 由 test-preload 指到临时目录）、`hub-send.test.ts` 的独立 `-L` tmux socket 和内存替身。`pendingSends` 三处 flush 带上下文只读码 + 编过，没跑真 spawn 流程。`reportUncertainSend` 在默认 runner 下能否触发仍未证实。
- iOS 没本地编；没上设备。新回执文案（「…。原消息没留住，请重新发一遍」用于重启后恢复的失败）没给粟粟看过。

### sol / astra R6 裁决（10-15 · 🎩 backend-4 六轮返工）

> sol、astra 审 R5（`4794a4de4`）：R5 各条原交错都修了，hub 侧没有新问题；两份一致指出 1 条本分支回退 P1（R5 把从 hub 恢复 / 观察到的外部 attempt 也记成「当前身份」，同一条消息之后别的设备的真实结果被当旧结果拒收）、1 条文档 P2（`idents` 的 4000 是清理阈值不是上限），外加测试缺口和四条既有问题（记账）。车头裁定全收。本轮只改 app 账本 + 测试 + 文档，不碰 `cc-bridge/` 和 `CCBridgeWebSocketClient.swift`；只改工作区。

| # | 意见（严重度） | 裁决 | 落实 | 测试 |
|---|---|---|---|---|
| 1（sol#1 / astra#1） | 恢复来的外部 attempt 被钉成当前身份：设备 A 冷启动从快照恢复 X 的失败后，设备 B 重发 Y 送到，A 因 Y ≠ X 拒收，已送达消息在 A 上一直显示失败；反过来 X 送到后 Y 失败，A 也建不出回执（P1，R5 回退） | 收 | `idents` 只记本机创建（`didSend` / `beginRetryAttempt`）或明确跟随（重发被拒后 `follow` active_attempt）的尝试——只有它们能证明「本地有更新的一次」。仅从 hub 观察 / 恢复的编号（无历史的带号状态、快照条目、没收下 / 结果不明的 error）照落状态，但不再写进 `idents`，同一条消息之后的带号结果照常推进（delivered 撤回执、failed / uncertain 建回执）。不按 UUID 排序。连带：`settleHubFailure` 去掉只用于记身份的 `wire` 参数 | app：`testObservedAttemptsKeepAdvancing`（(a) 恢复 X failed → 外部 Y delivered → 回执消失；(b) X delivered → 外部 Y failed → 建回执；(c) 对照：本机重新生成后旧 X 的失败不覆盖，两条路） |
| 2（sol#2 / astra#2） | `idents` 的「上限 4000」说法不准：清理只动没有重型账、没有气泡状态的，在途未回话的豁免，持续交出不回话会超过（P2） | 收（只改说法，不加准入限流） | 代码注释和本日志 R5 两处改成「清理阈值 4000，不是硬上限，在途未回话的身份豁免」。不做硬预算的理由：硬上限只有两种做法——给发送加准入限流（拒发也得出消息级回执，改变发消息体验），或淘汰还在用的身份（重新放进静默漏报 / 旧结果覆盖），都比多占内存糟；每条身份约百余字节，4000 条在途未回话不是现实负载。R6 起观察到的编号不再进 `idents`，表只随本机发送增长 | — |
| 测试缺口 | `numberedLinks` 没被独立证明（原测试同一条消息的 `answeredByNumber` 也能挡）；新连接首个带号帧之前的兜底窗口没有测试 | 收 | 补两条测试（行为不改） | app：`testNumberedLinkLockProvenByOtherMessage`（另一条消息 bx 的带号 ack 证明连接是新 hub；b1 没被编号回答过、本地已给回执、按兜底本来会落，无号 delivered 不落）、`testFallbackBeforeFirstNumberedFrame`（现状固定：首个带号帧前 w1 的无号 delivered 走兜底撤回执；之后连接锁定，w2 的不落；两条路） |
| 既有 3–6 | 见下「遗留（既有，记账）」 | 记账，不改 | — | — |

#### 遗留（既有，记账）

master 上同样存在、本分支没有恶化，本轮不改，等单独裁定 / 派单：

- boot 队列 flush 注入确定失败只记日志、没有消息级回执：三处 flush 先摘队列再 `tmux.send(...).catch(console.warn)`（`cc-bridge/hub.ts:1330`、`:1380`、`:1736`）；普通发送的非「结果不明」注入错误直接抛出、不进状态账（`cc-bridge/send-track.ts:126–130`）；ACK 在异步注入前就回了（`cc-bridge/hub.ts:4244`）。
- retry 看门狗超时后排队项照样注入、迟到的成功不纠正：看门狗只把 op 结束成 failed、不取消排队项（`cc-bridge/send-track.ts:91–96`）；排队项执行时找不到 retry op，按普通发送结束（`:112`），普通成功不广播 delivered（`:133–135`）。
- 「确定没执行」后自动补注入一次（`cc-bridge/send-track.ts:190–197`）：待粟粟裁定是否算违反「不自动重发」。
- stream 会话不走 SendTracker：分发器只把文本交给 `streamRunner.send(t, s)`、不带发送上下文（`cc-bridge/hub.ts:1011`）；stdin 写入异常只记日志、`send` 照样 resolve（`cc-bridge/stream-runner.ts:105`、`:127–130`）。

#### R6 风险 / 边界

- 没有本机证据的消息，后到的带号结果一律以 hub 为准（同 master 的宽松接收）：两台以上设备对同一条消息先后发起多次尝试、hub 广播又跨连接乱序到达时，可能持续误显示较早那次的结果：后续明确的实时状态可以纠正，但重连快照不含 delivered（`cc-bridge/send-verify.ts:350–359`），快照缺失分支（`CCSendTracking.swift` `didReceiveSnapshot` 里「本地还挂着、快照里却没有」那段，`:724` 起）只会把它改成「电脑那边没有这条的记录」，不保证纠正。没有 hub 可排序的版本号就不能比先后，按裁决不靠 UUID 猜。
- 本机发过的消息仍按本机身份挡旧结果；R5 的其余边界（旧 hub 歧义只看本进程、首个带号帧前的兜底窗口）不变，后者已用测试固定。
- sol R7 收口：可合，无本分支回退 P1（审查原文 scratchpad `a1-r7-sol.txt`）。

#### 测试（R6）

- app：新 `MemoryPalaceTests/CCBridgeTransportA1R6Tests.swift` 3 条（都两条路各一遍）；前几轮测试类未改。
- app 结果（10-15 22:19，HEAD `4794a4de4` + 工作区，`xcodebuild test`）：`Test Suite 'CCBridgeTransportA1R6Tests' passed`（3/0）、`'CCBridgeTransportA1R5Tests' passed`（6/0）、`'CCBridgeTransportA1R4Tests' passed`（11/0）、`'CCBridgeTransportA1R3Tests' passed`（16/0）、`'CCBridgeTransportA1R2Tests' passed`（22/0）、`'CCBridgeTransportA1R1Tests' passed`（28/0）、`'CCBridgeTransportA1Tests' passed`（7/0）、`'ConnectRulerTests'`（18/0）、`'CCBridgeReplyDedupOrderTests'`（3/0）、`'CCBridgeHealthURLTests'`（9/0）、`'CCBridgeTerminalInputChunkTests'`（4/0）、`'CCRelayPairingTests'`（13/0）、`'CCSendStatusTests'`（30/0）、`'TestHostIsolationTests'`（11/0）、`'TwitterCCBridgeTests'`（3/0）全部 passed，共 184/0，`** TEST SUCCEEDED **`；改到的 Swift 文件（`CCSendTracking.swift`、新测试类）0 warning。
- 查 flaky：七个 A1 测试类 `-test-iterations 5` 连跑 465/0（R1 140 + R2 110 + R3 80 + R4 55 + R5 30 + R6 15 + 原 35），`** TEST EXECUTE SUCCEEDED **`。
- hub：本轮没改 `cc-bridge/`，没重跑 bun。
- 变异验证（跑完从备份还原、`shasum` 核过一致）：把「观察到的编号也记成当前身份」（R5 形态，实时状态 + 快照两处）和连接级带号锁定（实时 + 快照两处）一次改回 → R6 三条全部失败；R4 / R5 照常通过（说明 R5 的模式锁定测试确实被 `answeredByNumber` 兜住、证明不了 `numberedLinks`，R6 补的这条才是独立证明）。

#### 未查证（R6）

- 同 R5：没连真 hub、没上设备、iOS 没本地编。跨设备场景只在单客户端里喂帧模拟（另一设备的 attempt 用随机 UUID 前缀），没有两台设备实测。
