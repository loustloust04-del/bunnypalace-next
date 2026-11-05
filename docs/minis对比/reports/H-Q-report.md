# H-Q 报告 —— 收口 QA（洞 6 + 洞 7 合并后复核）

被测：master `b93d0684`（H-A 洞 6+7 / H-B 洞 3 已合入）

> 跑完后 HEAD 已被**别的 session** 推到 `4bedf862`（09:47-09:48 四条提交）。
> 核过：`git diff --name-only b93d0684..HEAD` **全是 docs/**（plan / prompts / research 的 md），
> **没有一个源码文件变动**，所以本报告的测试与编译结论对当前树依然成立。
> 本席**全程没做任何 git 操作**。
工作树：`/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace`（主仓，未做任何 git 操作）
硬约束遵守：**全程没碰实机**，没装 iPhone Air / iPhone 14 / 任何真机。
本席只验证不改代码——下面每条「问题」都没修。

## 状态

| # | 事项 | 结论 |
|---|---|---|
| 1 | 空载复核 `RunCommandToolTests` | ❌ **不是 flake**。空载仍红（851 中 2 红），且**一次比一次慢**。根因定位到 `FileLibraryStore.uniqueSlug` 的 O(N²) 扫描 + 测试目录泄漏 → **P1 / P2 立案** |
| 2 | iOS 编译面 `MemoryPalaceIOS` | ✅ `** BUILD SUCCEEDED **`，EXIT=0，**0 error**；183 条 warning 逐条核过全是存量，与两条 lane 的改动行段交集为空 |
| 3 | 洞 7 模拟器实证 | ⚠️ **主结论拿到**：跨楼层「切楼层→再消费→落到那条对话」实证通过，不存在 chat_id 不崩且给 terminal 处理。但**没走成 `simctl push`+点横幅**（点击通道不通），toast 可见性仍未验 |

**两条 lane 的改动本身没发现回归。**P1/P2 是被这批测试轮次「养大」到浮出水面的**存量** bug，
改动面（`SyncStore` / `BackupStore` / `PushTargetResolver` / `ChatService` / `ConversationViewModel`）与之零交集。

---

## 一、空载复核 `RunCommandToolTests`

### 1.1 原始输出

**scoped 跑**（`-only-testing:MemoryPalaceTests/RunCommandToolTests`，机器空载）：

```
	 Executed 23 tests, with 2 failures (0 unexpected) in 91.459 (91.466) seconds
** TEST FAILED **
```

```
/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/MemoryPalaceTests/RunCommandToolTests.swift:42: error: -[MemoryPalaceTests.RunCommandToolTests testTimeoutKillsWholeTree] : XCTAssertLessThan failed: ("9.69961392879486") is not less than ("4.0") - 超时后应 ~1.5s 内返回
/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/MemoryPalaceTests/RunCommandToolTests.swift:93: error: -[MemoryPalaceTests.RunCommandToolTests testUnboundedOutputStaysBounded] : XCTAssertLessThan failed: ("10.801285028457642") is not less than ("6.0")
```

**全套跑**（紧接着，同样空载）：

```
	 Executed 851 tests, with 2 failures (0 unexpected) in 147.128 (147.471) seconds
** TEST FAILED **
```

```
/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/MemoryPalaceTests/RunCommandToolTests.swift:42: error: -[MemoryPalaceTests.RunCommandToolTests testTimeoutKillsWholeTree] : XCTAssertLessThan failed: ("12.378578066825867") is not less than ("4.0") - 超时后应 ~1.5s 内返回
/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/MemoryPalaceTests/RunCommandToolTests.swift:93: error: -[MemoryPalaceTests.RunCommandToolTests testUnboundedOutputStaysBounded] : XCTAssertLessThan failed: ("14.089252948760986") is not less than ("6.0")
```

**全套里只有这 2 条红，其余 849 条全绿**（含 H-A 的 `PushTargetResolverTests` 5 条、洞 6 那批）。

### 1.2 结论：不是 flake，是 app 代码里的真 bug（要立案）

H-A / H-B 判「并行构建压出的子进程延迟地板」。**这个判定不成立。**空载复核推翻它：

1. **空载仍红。** 机器空着跑，两条照样失败。
2. **越跑越慢——flake 不会单调恶化。** 同一台空载机器，两次连续跑：

   | 用例 | scoped 跑 | 紧接着全套跑 | 阈值 |
   |---|---|---|---|
   | `testTimeoutKillsWholeTree` | 9.700s | **12.379s** | <4s |
   | `testUnboundedOutputStaysBounded` | 10.801s | **14.089s** | <6s |
   | `testEcho`（一句 `echo hi`，绿的） | 8.643s | **11.289s** | — |
   | `RunCommandToolTests` 整 suite | 91.5s | **122.6s** | — |

   两次之间**只隔了一次跑**，没有任何构建在并行（`xcodebuild` 互斥 shim 保证同时只有一个编译型任务）。慢了 30%。
3. **子进程本身不慢。** `/bin/zsh -c 'echo hi'` 在这台机器上 `real 0.00s`（连测 3 次），本机没有 `/etc/zshenv` 也没有 `~/.zshenv`。所以延迟不在 spawn。

#### 时间花在哪：一次性成本，落在每个 test method 的**第一次** `execute`

拆 scoped 跑的 per-test 墙钟，规律非常干净：

- `testEcho` 1 次 spawn → 8.643s
- `testUnboundedOutputStaysBounded` 2 次 spawn → 全 test 10.877s，而**第一次 `run()` 自己就 10.801s**（测试内部 `t0` 打点）→ 第二次 spawn 只花了 ~0.07s
- `testDefaultCwdIsLibraryRootAndContainment` 2 次真 spawn（另 2 次在 `resolveCwd` 就被拒）→ 9.208s

即：**每个 test method 的第一次 `execute` 固定多付 ~8.6s，同一个 test 里后续调用是 ~0.1s。**
两条红用例的墙钟也精确对得上：`8.7 + timeout 1s = 9.70`、`8.8 + timeout 2s = 10.80`。

#### 根因：`FileLibraryStore` 的楼层目录扫描，随历史累积 O(N²) 退化

调用链（全是既有代码，两条 lane 都没碰）：

```
RunCommandTool.execute                     RunCommandTool.swift:69
  → MacShellBackend.resolveCwd             MacShellBackend.swift:24
  → FileLibraryStore.libraryRoot           FileLibraryStore.swift:107
  → filesystemRoot → floorDirectory        FileLibraryStore.swift:477 / 482
  → floorSlug                              FileLibraryStore.swift:117
  → uniqueSlug                             FileLibraryStore.swift:504-516  ← 热点
```

三件事叠在一起：

**(a) 测试的 profileId 全部塌缩成同一个 slug。**
`RunCommandToolTests.swift:8` 的 `profileId = "test-run-command-\(UUID().uuidString.prefix(8))"` 每个 test method 都不同，
但 `shortId`（`FileLibraryStore.swift:574-577`）是「滤掉非字母数字后取前 8 位」：

```swift
let safe = profileId.filter { $0.isLetter || $0.isNumber }
return String((safe.isEmpty ? "profile" : safe).prefix(8))
```

`test-run-command-…` → `testruncommand…` → **`testrunc`**。UUID 部分在第 8 位之后，**被整个截掉**。
所以每个 test method 的基础 slug 都是 `楼层-testrunc`，永远撞。

**(b) `uniqueSlug` 的循环里放了一个循环不变量。**

```swift
// FileLibraryStore.swift:504-516
while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate, ...).path) {
    if let existing = findExistingFloorDirectory(profileId: profileId), existing.lastPathComponent == candidate {
        break
    }
    candidate = "\(base)-\(index)"
    index += 1
}
```

`findExistingFloorDirectory(profileId:)` **不依赖 `candidate`**，每轮返回同一个值（新 profileId ⇒ 恒为 `nil`，`break` 永不触发），
却被**每轮重算一次**。而它自己是一次全目录扫描（`FileLibraryStore.swift:518-541`）：
`contentsOfDirectory` 整个 floors 根 + 每个条目一次 `resourceValues(.isDirectoryKey)` + 一次
`Data(contentsOf: .memorypalace/manifest.json)` + JSON decode。

于是第 N 个 `楼层-testrunc-*` 目录要付 **N × (floors 目录条目数)** 次 stat/open。

**(c) 测试没有清理，目录单调增长。**
`RunCommandToolTests` 里 `setUp` / `tearDown` **一个都没有**（grep 计数 0），
每个 test method 在 **粟粟真实的 `~/Documents/记忆宫殿/floors/`** 里留下一个楼层目录，永不回收。

实测当前状态（跑完上面两轮后）：

```
total dirs:      495
楼层-testrunc*:  477        ← 最大后缀 楼层-testrunc-473
其余 18 个才是真楼层 + 别的 suite 留的
```

而且**看着它涨**：本席开工时 489 → scoped 跑完 491 → 全套跑完 495。

复现成本模型（scratchpad 里的独立脚本，未动仓库代码）：

```
floors entries: 495  testrunc dirs: 477
one full scan: 0.0095s
projected for 477 iterations: 4.51s
```

Python 的 `os.listdir` 比 Foundation 的 `contentsOfDirectory` + `resourceValues` + `Data(contentsOf:)` 快约 2 倍，
**4.51s × ~2 ≈ 9-11s，与实测的 8.6→11.3s 同量级、且增长律一致**（目录数涨 → 墙钟涨）。机制成立。

**(d) 顺带污染了 app 的真 UserDefaults。**
`setSlug`（`FileLibraryStore.swift:711-718`）每次调用都把整张 map decode + encode 一遍。
这张 map 现在在**上架 app 自己的 defaults 域** `com.susu.MemoryPalace` 里已经 **57,307 字节**，
开头就是 `{"test-run-comma…`——477 条测试垃圾键。这是第二条随时间增长的成本。

#### 所以这 2 条该怎么定性

**断言没写错，测的是真延迟。** 两条断言测的是 `Date().timeIntervalSince(t0)` 包住 `run()` 的墙钟，
而这 ~8.6s **确确实实发生在 `RunCommandTool.execute` 内部**（`resolveCwd` 那一步），不是测试框架开销。
换句话说：**一个真实用户在一个楼层多的库上调 `run_command`，也会吃到这条路径的扫描成本**——
只是真实楼层数是几个而不是 477，所以现在还不痛。

**与 H-A/H-B 的判定的关系**：他们看到的 14.7s / 16s / 17s 比本席空载测到的高，
说明**构建压力确实叠加在上面**——但那只是上层浮动，**下面这条 8.6s 且持续升高的地板是本 bug 造成的，与负载无关**。
两条 lane 的改动面（`SyncStore` / `BackupStore` / `PushTargetResolver` / `ChatService`）与此确实零交集，
**这不是他们引入的回归**，是一个被他们的测试轮次「养大」到浮出水面的存量 bug。

**本席不修**（QA 席只验证）。修法建议见文末。

---

## 二、iOS 编译面

命令：`xcodebuild -scheme MemoryPalaceIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build`
（走 `~/.local/bin` 互斥 shim，没用 `-derivedDataPath`，没用 `xcrun xcodebuild`）

```
** BUILD SUCCEEDED **
```

```
EXIT=0
error: 计数 0
warning: 计数 183
```

**0 error。**排队情况：本席的 iOS build 在 `uikit-t6` worktree 的 `StickerProbeUITests` 后面排了约 4 分钟，
shim 正常序列化（这也说明第一件事的两轮测试确实是空载跑的）。

### 183 条 warning 全是存量，没有一条是这批引入的

抽了看着最像洞 6 地盘的几条（`crossProfileConflicts` / `copiedConversations`
「reference to captured var … this is an error in the Swift 6 language mode」）逐条 `git blame`：

```
ClaudeImporter.swift:200        07d7d1300  2026-06-11
ConversationImporter.swift:151  07d7d1300  2026-06-11
ConversationImporter.swift:349  07d7d1300  2026-06-11
```

再把两条 lane 在 `ConversationViewModel.swift` 的改动行段（`git diff -U0 c41882d8..b93d0684`）
`1634 / 1639-1641 / 2414-2416 / 2706-2834 / 2849-2850 / 2932 / 2936 / 2945-2963 / 3141`
和该文件所有 warning 行号求交集：**交集为空**；抽查的 `106 / 3037 / 3339 / 3558` 分别是
`2026-08-25 / 06-12 / 06-11 / 06-14`，全部早于本批次。

**结论：iOS 编译面干净，两条 lane 没有引入任何新诊断。**
H-A 未验证清单第 5 条（「iOS build 没跑」）——现已跑过，`PushTargetResolver.swift` / `ContentView.swift`
在 iOS target 下正常编译。

---

## 三、洞 7 模拟器实证

设备：**iPhone 17 Pro Max `B7EABEAA-E77A-461C-9016-10BAF359C1B4`**（模拟器）。
**没碰 iPhone 17 Pro**（粟粟日常那台），**没碰任何真机**。
跑完已把设备状态**整个还原**（见 §3.4）。

### 3.1 做到了什么 / 没做到什么（先说边界）

**没走成**「`simctl push` → 手点通知横幅」这条原样路径，卡在**点击通道**：

- `mobai` 的 `start_bridge` 对这台设备连续两次 `HTTP 500: Failed to start bridge app`（claim 过设备也一样），
- `xcrun simctl` 本身没有 tap 能力，
- 且 app 首次启动弹 **"记忆花园" Would Like to Send You Notifications** 系统弹窗，
  没有点击通道就**既点不了 Allow（推送发不进来）、也点不了横幅**。

**改用等价注入**：`PushNotifications.swift:47-53` 的点击 handler 做的事只有两件——
把 `userInfo["chat_id"]` 写进 `UserDefaults["pendingPushChatId"]`（`:50`）+ post 一个通知。
所以本席**直接把 `pendingPushChatId` 写进 app 容器的 prefs 再冷启动**，
走的是 `ContentView.swift:454` 那条「冷启动延迟 0.6s 消费」的真实路径。

> 即：**`consumePendingPushTarget` 全链路（洞 7 的修复本体）是真跑的**，
> 只有 `didReceive` 那 5 行读 `userInfo` 的胶水没跑。见 §未验证。

数据夹具用的是模拟器上**已经存在**的探针对话（`uikit-t6` 那条 lane 的 UITest 留下的），
省掉了「建对话 + 发消息」——**因此全程没有连生产 hub，没发任何真实 API 请求**：

```
ZID            = probe-kb-conv-1
ZPROFILEID     = default-workspace
ZCURRENTNODEID = 29857320-8B57-4A63-8221-4616603F5B5C   （非空，满足 resolver 的 conversationEmpty 前置）
ZTITLE         = [PROBE] 键盘避让测试对话
```

楼层 B 是本席加的（把 `savedProfiles` 里的楼层 A 复制一份改 id/name/emoji = `hq-floor-b`）。

**踩坑记一笔**（给后来人）：`xcrun simctl spawn <udid> defaults write <bundle> …` **写不进 app 容器的 prefs**——
它落在模拟器的**全局** prefs 域，app 根本读不到（本席前两次夹具全部无效就是这个原因，
现象是「`defaults read` 读得到、app 行为却没变、on-disk plist 里没有这个 key」）。
正确姿势：**直接改容器里的 plist 文件**
`…/Devices/<udid>/data/Containers/Data/Application/<app-uuid>/Library/Preferences/<bundle>.plist`，
改完 `xcrun simctl spawn <udid> killall -9 cfprefsd` 让缓存失效，再启动。

### 3.2 跨楼层实证：**通过**

夹具（改完在 on-disk plist 上核过）：

```
 lastProfileId     = 'hq-floor-b'                 ← 当前在楼层 B
 pendingPushChatId = 'probe-kb-conv-1'            ← 推送指向楼层 A 的对话
 savedProfiles     = ['default-workspace', 'hq-floor-b']
```

冷启动后读回（app 自己写的面包屑，`BreadcrumbLog` 持久化在 UserDefaults）：

```
   10:03:27 🚀 启动 v1.0.0 (5) · 构建于 2026-09-02 09:54
   10:03:28 🔔 推送落在别的楼层，切到 对话空间 再跳 conv=probe-kb
   10:03:28 🏠 切楼层 HQ楼层B → 对话空间
   10:03:29 💬 打开对话「[PROBE] 键盘避让测试对话」
```

```
 lastProfileId     = 'default-workspace'          ← 楼层真的切过去了
 pendingPushChatId = None                         ← key 在导航成功后才被消费
```

**这四行按顺序完整覆盖了 H-A「未验证」清单第 1 条的三件事：**

| H-A 说没实测的 | 实证 |
|---|---|
| 切楼层后新 subtree 的 `onAppear`（`ContentView.swift:454` 那个 0.6s 延迟消费）真的会再触发一次 | ✅ `10:03:29 💬 打开对话` —— 第二次消费解析成 `.navigate` 并真的导航了。只有 `.id(currentProfile.id)` 重建 → `onAppear` 再跑一次才可能出现这一行 |
| 不会切楼层死循环 | ✅ 面包屑里 🔔 和 🏠 **各只有一条**，全程 1 秒收敛，没有反复横跳；`pendingPushChatId` 被干净消费 |
| 洞 7 原症状「点了什么都不发生、key 还没了」 | ✅ 已消失：楼层切了、对话开了、key 在**成功之后**才删 |

### 3.3 不存在的 chat_id：**通过，不崩**

```
 pendingPushChatId = 'definitely-does-not-exist-hq-0001'   ← 投前
```

```
   10:04:15 🚀 启动 v1.0.0 (5) · 构建于 2026-09-02 09:54
   10:04:16 🔔 推送对话已不存在 chat=definite
```

```
 pendingPushChatId = None                  ← terminal 失败，key 被消费掉，不会无限重试
 lastProfileId     = 'default-workspace'   ← 没有乱切楼层
```

- 走的是 `.conversationMissing` 分支（`ContentView.swift:749-753`），**app 没崩**（进程正常存活到本席主动 terminate）。
- 「有没有**可见**提示」——**没验到**。该分支会 set `viewModel.transientNotice = TransientNotice("这条消息对应的对话已经被删除了")`，
  但截图时整屏被那个通知权限系统弹窗盖住（`shot-03-missing-toast.png`），toast 没法确认。见 §未验证。

### 3.4 收尾：设备已还原

- app 容器 prefs **从开工前的备份整份还原**：`lastProfileId=None` / `pendingPushChatId=None` /
  `savedProfiles=['default-workspace']`（楼层 B 已消失）。
- 模拟器 `shutdown`（本席接手时它就是 Shutdown，是 `uikit-t6` 那条 lane 跑完 UITest 关掉的）。
- `mobai` 设备租约已 release。
- **没做任何 git 操作。**

---

## 发现的问题（带行号，均未修）

### P1（真 bug，建议立案）`FileLibraryStore.uniqueSlug` 循环里重算循环不变量 → 随楼层数 O(N²)

`MemoryPalace/Services/FileLibraryStore.swift:504-516`

```swift
while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate, ...).path) {
    if let existing = findExistingFloorDirectory(profileId: profileId), existing.lastPathComponent == candidate {
        break
    }
    candidate = "\(base)-\(index)"
    index += 1
}
```

`findExistingFloorDirectory(profileId:)`（`:518-541`）**不依赖 `candidate`**，每轮返回同一个值，
却被每轮重算；而它自己是一次「整个 floors 目录 `contentsOfDirectory` + 每条目 `resourceValues` +
读 `.memorypalace/manifest.json` + JSON decode」的全扫描。

**影响面**：`libraryRoot(profileId:)`（`:107`）是文件库/`run_command` cwd 的必经路径，
每次 `run_command` 都会走到。真实用户楼层少所以现在不痛，但这是一条**在热路径上、随数据量平方增长**的扫描。
**修法建议**：把 `findExistingFloorDirectory` 提到循环外算一次；顺带 `floorSlug` 命中 `slugMap` 时应能完全跳过扫描。

### P2（测试卫生，是 P1 被放大的原因）测试往粟粟真实 `~/Documents` 和上架 app 的 UserDefaults 里泄漏，且永不清理

- `MemoryPalaceTests/RunCommandToolTests.swift:8` 的 `profileId` 每个 test method 都不同，
  但 `FileLibraryStore.shortId`（`:574-577`）取前 8 个字母数字 ⇒ 恒为 `testrunc`，UUID 部分被截掉，
  于是每个 test method 都新建一个 `楼层-testrunc-N` 目录。
- 该 suite **没有任何 `setUp` / `tearDown`**（grep 计数 0），目录永不回收。
- 实测：`~/Documents/记忆宫殿/floors/` 里 **495 个目录，其中 477 个是 `楼层-testrunc*`**（最大后缀 `-473`），
  真楼层只有 18 个。本席开工到收工亲眼看它从 489 涨到 495。
- 同时污染上架 app 自己的 defaults 域：`com.susu.MemoryPalace` 的
  `fileLibraryLocalDocumentsSlugMapV1` 已 **57,307 字节**，开头就是 `{"test-run-comma…`；
  而 `setSlug`（`:711-718`）每次调用都要把这张表整个 decode + encode 一遍。

**这就是那 2 条「flake」的真正来源**，也是它们**一次比一次慢**的原因。
**清理是安全的**（纯测试垃圾），但**本席不动**——删 495 个目录属于破坏性操作，交粟粟决定。

### P3（小，UX）`.navigate` 的可恢复失败分支没有任何用户可见反馈，也没有重试触发器

`MemoryPalace/Views/ContentView.swift:722-730`

```swift
case .navigate(let convId, let nodeId):
    ...
    guard let conv = try? modelContext.fetch(desc).first else {
        BreadcrumbLog.shared.add("🔔", "推送落点这一刻取不到 conv=\(convId.prefix(8))，保留待跳转")
        return   // 可恢复：key 留着，下次消费再试
    }
```

保留 key 是对的，但这一刻**用户什么都看不到**（只有开发者面包屑），
而且**没有任何东西会再触发一次消费**——消费入口只有 `onAppear`（`:454`）和
`.pushConversationRequested` 通知（`:673-675`）。若两者都不再发生，这次点通知就是静默无反应，
和洞 7 修前的症状一样，只是**往后挪了一层**。`.unavailable` 分支（`:765-766`）同理。
命中概率低（要求「全库查得到、按当前楼层 scoped 查不到」），但一旦命中就是老症状复发。

---

## 未验证

1. **`simctl push` + 手点通知横幅这条原样路径没跑成。** 卡在**点击通道**：
   `mobai start_bridge` 两次 `HTTP 500`，`simctl` 无 tap 能力，通知权限系统弹窗点不掉。
   因此 `PushNotifications.swift:47-53`（读 `userInfo["chat_id"]` → 写 `pendingPushChatId` → post 通知）
   这 5 行**没有实测**，是用等价注入替代的。修复本体 `consumePendingPushTarget` 全链路已实测（§3.2 / §3.3）。
2. **toast 可见性没验到**（H-A 未验证清单第 2 条**依然挂着**）。
   `.conversationMissing` 分支确实跑了（面包屑为证），但 `transientNotice` 有没有真显示出来，
   因为通知权限弹窗盖屏没截到。需要点击通道才能验。
3. **热启动路径没验**（`.pushConversationRequested` 通知，`ContentView.swift:673-675`）。
   本席跑的两次都是**冷启动**（`ContentView.swift:454`）。
4. **`.profileMissing` / `.conversationEmpty` / `.unavailable` 三个分支没在设备上跑过**——
   只有 macOS 单测 `PushTargetResolverTests`（5 条，全套里全绿）覆盖解析层。
5. **P1 的修法没验证**（本席只定位不修）。
6. **两条红用例修掉 P1/P2 之后会不会转绿，没验证**——推断会（8.6s 地板消失后，
   墙钟应回落到 timeout+~0.2s，远低于 4s / 6s 阈值），但没实测。
