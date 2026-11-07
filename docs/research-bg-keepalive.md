# research：iOS 切出去就冷启动 + 回来重播开屏（后台保活）

> 2026-10-15 · 🎩 · infra 工位 · 派单 `~/Desktop/cc-rp/API链路/派单/prompt-后台保活.md`
> 状态：**根因已定（§2.6）**：Air 开着「设置 › 开发者 › Fast App Termination」，系统在任何 app 一挂起时就杀掉它。不是 app 的 bug。

## 1. 现象（粟粟 10-15，iPhone Air）
切到别的 app 复制 URL / key，约 1 分钟内切回来 → 每次都是冷启动、重播约 1 秒开屏、回到首页。

## 2. 证据

### 2.1 开屏重播 = 进程确实换了
`LaunchSplash.install` 有静态门 `installed`，一个进程只装一次（`MemoryPalace/Views/LaunchSplash.swift:109-110`）；
scene 连接观察者首个 scene 后即移除（`:119-125`）。所以「重播开屏」只可能是新进程，不是 scene 断开重连。

### 2.2 系统崩溃 / Jetsam 日志：今天没有任何被杀记录
`devicectl --domain-type systemCrashLogs` 拉 Air 全部 234 份（`~/MemoryPalace-docs-media/docs/evidence/bg-keepalive/air-1015/`）：
- `JetsamEvent-*` 最后一份 **09-26**；
- `记忆花园-*.ips` 最后一份 **10-08**（`.cpu_resource` 最后 10-04、`.diskwrites_resource` 最后 09-18）；
- 10-14 / 10-15 全机没有任何新报告。

### 2.3 MetricKit 退出原因：后台退出全是 `NormalApp`，内存回收 0 次
Air 上的 Debug 包自带 `MetricsRecorder`（`MemoryPalace/Utils/MetricsRecorder.swift`），拉回 `Library/Application Support/MemoryPalace/Metrics`（`…/air-1015-metrics/`，粟粟同意只拷这个目录）：

| 日（本地） | 后台退出 | 前台退出 | 挂起平均内存 | 峰值 |
|---|---|---|---|---|
| 10-04 | NormalApp 2 | — | 147 MB | 442 MB |
| 10-05 | NormalApp 1 | — | 97 MB | 304 MB |
| 10-07 | NormalApp 1 | — | 118 MB | 259 MB |
| 10-08 | NormalApp 3 | Abnormal 1 | 164 MB | 480 MB |
| 10-09 | NormalApp 3 | — | 146 MB | 361 MB |
| 10-10 | NormalApp 5 | — | 182 MB | 454 MB |
| 10-11 | NormalApp 11 | — | 195 MB | 789 MB |
| 10-13 | 0 | — | 240 MB | 589 MB |
| 10-14 | NormalApp 1 | — | 202 MB | 436 MB |

- `memoryPressureExit`（jetsam 回收挂起 app）/ `memoryResourceLimit` / `appWatchdog` / `suspendedWithLockedFile` / `backgroundTaskAssertionTimeout` / `cpuResourceLimit`：**十天全 0**。
- 10-15 当天的数据明天才出（MetricKit 日报延迟一天）。

**读法**：至少 10-04~10-14 期间，系统没有因为内存把我们从后台杀掉。挂起时 100~240MB 在 Air（12GB）上并不大。
「后台常驻内存太大被 jetsam」这个最常见的猜测，被这组数据否掉了（代码排查 agent 的头号嫌疑也是它，判驳回）。
`NormalApp` = 进程自己正常退出（`exit` / `_exit`），装包时 `--terminate-existing` 杀进程可能也计在内（未查证），所以这些数字和装包次数混在一起，不能直接当病例数。

### 2.4 代码里能让进程「正常退出」的路径
| 位置 | 条件 | 和切 app 有没有关 |
|---|---|---|
| `MemoryPalaceApp.swift:676-684` BFU 闸 `exit(0)` | 重启后未解锁、被后台拉起 | 无关 |
| `Utils/PerfHarness.swift:181,1313`、`Views/Spike/UIKitChatSpikeBench.swift:212` | 测量 / spike 角色 env | 无关 |
| **`deps/ish/kernel/exit.c:170-174 → :403-456` `halt_system()` → `_exit(0)`** | 离线沙箱（iSH）guest 的 init（PID 1）退出 | **可疑，未查证** |

iSH 的 init 退出会先给所有 guest 任务发 TERM/KILL，再 `_exit(0)` 把**整个宿主 app 进程**带走，MetricKit 正好记成 `NormalApp`，也不留崩溃日志。
沙箱是懒启动的（`Sandbox/ish/SandboxRuntime.swift:86-122`，第一次 `run_command` 才 boot），她今天有没有用到、init 在后台会不会被弄死，**都未查证**。

### 2.5 其他发现（不是今天的病因，但相关）
- 进后台做的事（`MemoryPalaceApp.swift:1374-1395`）：同步导出 + 时间机器备份在 `DispatchQueue.global` 上跑、没申请后台时间；`BackupStore.snapshotIfNeeded` 每次进后台都对全部对话 fetch + 编码 + sha256 再判断变没变。挂起半路停住不会被杀，但是一次无谓的大内存高峰。
- iSH 的后台 CPU 调速器 `beginBackgroundCPUGovernor`（`Sandbox/ish/ISHKernel.m:2164`，注释说 iOS 26 后台预算 48 CPU-s / 60s，超了就杀）**全仓没有调用方**。只在 app 后台保活（在放音频）且 guest 在跑时有意义；被杀会记成 `cpuResourceLimit`，目前 0 次。
- 冷启动后的页面恢复：只有 page2 打开的应用走 `@SceneStorage`（`ContentView.swift:84-87`）；当前页号写死 1（`ContentView.swift:736`）、当前对话不恢复；API 卡草稿有专用的进后台写 / 冷启动跳回（`APIDraftStore` + `SettingsJump.swift:86-99`）。

### 2.6 系统日志：dasd「BG Kill Demo」——一挂起就杀，哪个 app 都杀（定罪）
她复现后跑 `sudo log collect --last 15m`，存档 `~/MemoryPalace-docs-media/docs/evidence/bg-keepalive/air-repro.logarchive`。14:48 到 15:00 之间，记忆花园先后起了 5 个进程（pid 16711 / 16730 / 16737 / 16743 / 16750）：

```
14:54:29.435 dasd [bgappkilldemo] App <private> suspended
14:54:29.435 dasd [bgappkilldemo] Executing termination request <private>
14:54:29.436 runningboardd Received termination request from [osservice<com.apple.dasd>:92] on app<com.susu.MemoryPalace.ios>:16711
             with context <RBSTerminateContext| explanation:BG Kill Demo reportType:None maxTerminationResistance:Interactive>
14:54:29.454 launchd … [16711] exited with exit reason (namespace: 15 code: 0x0) - OS_REASON_RUNNINGBOARD | … BG Kill Demo …
```

- dasd 的 `bgappkilldemo` 逻辑分两步：app 进前台时先预约一张终止单（日志 `foregrounded, creating a termination request`），app 一挂起就执行（`suspended → Executing termination request`）。
- 同一段日志里被它杀掉的还有 Swiftgram（`app.swiftgram.ios`）、`cn.aelion.aru`、系统贴纸选择器 `StickerPickerService` 和小组件渲染器。不分是谁的 app，一律杀。
- 终止单是 `reportType:None`，所以不出崩溃报告也不出 Jetsam 报告，MetricKit 记成 `NormalApp`。这和 §2.2、§2.3 的现象全部对得上。
- Apple DTS 的 Kevin Elliott 在论坛上解释过（[forums/759754](https://developer.apple.com/forums/thread/759754)）：这是 Xcode 加的开发者选项「设置 › 开发者 › **Fast App Termination**」，说明文字是 *Terminate instead of suspending apps when backgrounded…*。它借用了 Duet 里现成的钩子实现，终止理由就叫「BG Kill Demo」，本意是用来测试状态恢复。

### 2.7 合后实测（T1 / T8，第一轮，Warden 10-15，regress 模拟器 F3BAB89B，master 88b3cc4c）
截图在 `~/MemoryPalace-docs-media/docs/shots/bg-keepalive/`（item1* / item1b* / item2* / item2b*）。判据是 LaunchTrace 有没有 `splashSkipped reason=resume`。
- **T1 session 保留：成立**。`simctl terminate` 杀掉后，`UISceneSession.userInfo` 和 `@SceneStorage` 都能读回来。
- **第 1 条（对话 A 打字 → 杀 → 重开）：PASS（重试那次）**。第一次是回桌面 22 秒后杀的，那时标记还没进存盘的 `userInfo.data`，所以照播了开屏；不过落点在对话 A，字也在，因为字走的是 `Conversation.draftText` 落库。
- **第 2 条（新对话打字）：FAIL**。开屏确实跳过了，可回来字是空的。系统存 scene 恢复数据是 18:12:36，我们 didEnterBackground 写 `resume.newChatText` 是 18:12:47 才落地，**存盘早于写入**。再切一次前后台，值就存上、恢复也正常了。
  - 结论：didEnterBackground 来不及，要在系统存盘之前写，改成在 willResignActive 写（修复见 plan T11）。
- **第 3–9 条：没跑完**。18:20:38 Simulator.app 被退出，两个模拟器都关了；不是测试流程干的，Warden 没再重启。
- **第 9 条**：`--stdout` 抓不到 PerfCount，contentViewBody 那部分记 N/A。

## 3. 结论
- **根因**：Air 上开着开发者选项 Fast App Termination。我们的进程是系统主动终止的（dasd 发起，SIGTERM），不是内存回收、不是崩溃、也不是我们代码自己退出。把这个开关关掉，问题 1 和问题 3 就解决了。
- **iSH 那条嫌疑撤销**：§2.6 证明终止来自 dasd 的 SIGTERM，不是 app 自己退出。不过「沙箱 init 一死，`_exit(0)` 就带走整个 app」这颗雷还在，记成技术债，不在本单修。
- **谁、什么时候打开的，不知道**：这个开关不会自己打开。今天的草稿保活单是在模拟器上用 `simctl terminate` 测的，没有碰 Air 的设置（未查证）。

## 4. 下一步
1. 粟粟在 Air 上关掉「设置 › 开发者 › Fast App Termination」（中文界面叫什么还没核实），再按验收步骤试一次：切出去 1 分钟再回来，应该停在原页、不播开屏。
2. 验收第二条「真被系统回收时，回来不播开屏、直接回到上次的页」还得做。系统的内存回收以后照样会发生，而这个开关正好可以拿来当现成的测试手段。具体写进 `docs/plan-bg-keepalive.md`，等她批。

## 5. 第二条验收要做的
- 开屏：被回收后 N 分钟内冷启动跳过开屏（进后台时记时间戳，冷启动比对）。
- 回到原页：通用 LastLocation（页号 / 对话 id / page2 应用 / 设置子页），复用 SettingsJump 的「进后台写一次、冷启动消费一次、外部入口优先」闸。
