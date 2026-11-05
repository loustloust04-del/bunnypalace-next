# H-A 报告 —— 洞 6（同步/备份还原跨楼层偷数据）+ 洞 7（跨楼层通知点了没反应）

> 分支 `worktree-agent-a138954ed40783572`，从 master `d7a9d163` 出发。
> 契约：`docs/minis对比/plan-补洞.md` §二「洞 6」「洞 7」 + `docs/minis对比/trace/H-A-cross-profile.md`。

## 状态：DONE

- 洞 6 三条路径：两条修（红→绿），第三条核实为**非漏洞**、补回归锚（见「与契约的偏离」1）
- 洞 7 resolve 三 case + 两个 terminal 分支：红→绿
- 全套 `Executed 839 tests, with 2 failures` —— 那 2 条是 `RunCommandToolTests` 的墙钟 flake，
  与本 lane 无关，取证见下
- `** BUILD SUCCEEDED **`

## 改了什么（文件:行号 + 一句话）

### 洞 6

| 文件:行号 | 改动 |
|---|---|
| `MemoryPalace/Services/BackupStore.swift:40-41` | 加 `static var overrideRoot: URL?`（测试注入，跟 `SyncStore.overrideRoot` 同款）。没有它测试会往粟粟真实 iCloud 备份目录写 |
| `MemoryPalace/Services/BackupStore.swift:47-50` | `backupRoot()` 优先返回 `overrideRoot` |
| `MemoryPalace/Services/BackupStore.swift:330-353` | `restore()` 里算 `restoredProfileIds`，每份 doc 还原前过 `crossProfileBlocked`，命中则 `conversationsSkippedCrossProfile += 1` + BreadcrumbLog，**整份跳过**（不做部分 insert、不改 id） |
| `MemoryPalace/Services/BackupStore.swift:419-462` | 新增 `crossProfileBlocked(doc:targetProfileId:allowedProfileIds:context:)`：先用 `ImportSupport` 那对批量冲突查询问「撞没撞别的楼层」，撞了再看占用方在不在本次还原范围内 |
| `MemoryPalace/Services/SyncStore.swift:333` | `ImportResult` 加 `conversationsSkippedCrossProfile` |
| `MemoryPalace/Services/SyncStore.swift:484-505` | 新增 `crossProfileConflicted(document:profileId:context:)`；查询抛错时返回 `true`（宁可不导入也不冒险 upsert 偷行） |
| `MemoryPalace/Services/SyncStore.swift:533-544` | `importAll` 每份文档 insert 前过守卫，命中整份跳过 + 把该文件的 mtime 从 importState 摘掉（冲突解掉后还能进来） |
| `MemoryPalace/Models/BackupManifest.swift:72-73` | `RestoreResult` 加 `conversationsSkippedCrossProfile` |
| `MemoryPalace/Views/RestoreSheet.swift:346-349` | 还原结果文案追加跳过数（复用 `crossProfileConflictSuffix`，跟两个 importer 同款措辞） |
| `MemoryPalace/Views/DataSettingsTab.swift:189, 241` | 同步日志两处（接入 / 立即同步）追加跳过数 |

### 洞 7

| 文件:行号 | 改动 |
|---|---|
| `MemoryPalace/Services/PushTargetResolver.swift`（新文件，46 行） | `PushTargetResolution` 六 case + `PushTargetResolver.resolve(chatId:currentProfileId:knownProfileIds:in:)`。纯函数：不碰 UI、不读写 UserDefaults、不切楼层。**平台中立**（不在 `#if os(iOS)` 里），所以 macOS 单测能直接跑；将来 AppRoute 直接复用 |
| `MemoryPalace/Views/ContentView.swift:707-767` | `consumePendingPushTarget` 重写成「解析 → 按结果动作」，六个分支各自决定消不消费 pending key |

**⧫ 只修 bug，没做 AppRoute。**

## 复现 → 修 → 验证

### RED（修前，`-only-testing` 三个 suite）

```
Test Suite 'BackupStoreTests' failed at 2026-09-02 08:39:42.902.
	 Executed 5 tests, with 14 failures (0 unexpected) in 1.045 (1.048) seconds
Test Suite 'PushTargetResolverTests' failed at 2026-09-02 08:39:42.948.
	 Executed 5 tests, with 2 failures (0 unexpected) in 0.044 (0.046) seconds
Test Suite 'SyncStoreTests' failed at 2026-09-02 08:39:43.273.
	 Executed 10 tests, with 12 failures (0 unexpected) in 0.320 (0.325) seconds
Test Suite 'Selected tests' failed at 2026-09-02 08:39:43.274.
	 Executed 20 tests, with 28 failures (0 unexpected) in 1.409 (1.422) seconds
```

**偷数据是真的，不是推理。** 关键红行（profileId 被整行改写 + 标题 + 节点全被抢）：

```
BackupStoreTests.swift:160: ... XCTAssertEqual failed: ("0") is not equal to ("1") - 跨楼层冲突必须报数
BackupStoreTests.swift:165: ... ("Optional("xctest-backup-B")") is not equal to ("Optional("xctest-backup-A")") - 对话必须仍属楼层 A（没被偷到 B）
BackupStoreTests.swift:166: ... ("Optional("备份里的标题")") is not equal to ("Optional("A 楼层原标题")") - 属性未被备份改写
BackupStoreTests.swift:167: ... XCTAssertTrue failed - 节点也没被偷
SyncStoreTests.swift:321: ... ("Optional("xctest-sync-xp-B")") is not equal to ("Optional("xctest-sync-xp-A")") - 对话仍属楼层 A
SyncStoreTests.swift:322: ... ("Optional("B 楼层云端标题")") is not equal to ("Optional("A 楼层原标题")") - 属性未被云端改写
PushTargetResolverTests.swift:61: ... ("conversationMissing") is not equal to ("switchProfile(profileId: "xctest-push-A", conversationId: "conv-cross")") - 推送 id 属于别的楼层时必须要求切楼层，不能当作对话不存在
```

红的测试逐条：

| 洞 | 测试 | 修前 |
|---|---|---|
| 6-1 | `BackupStoreTests.testRestoreSingleConversationSkipsCrossProfileConflict` | 红（X 被偷到 B） |
| 6-1 | `BackupStoreTests.testRestoreProfileScopeSkipsCrossProfileConflict` | 红 |
| 6-1 | `BackupStoreTests.testRestoreEverythingStillSkipsProfileOutsideBackup` | 红 |
| 6-1 | `BackupStoreTests.testRestoreEverythingKeepsOverwriteSemantics` | **绿**（⧫ 既有语义锚，修前修后都必须绿） |
| 6-1 | `BackupStoreTests.testRestoreWithoutConflictStillRestores` | **绿**（回归锚） |
| 6-2 | `SyncStoreTests.testImportSkipsConversationOwnedByAnotherProfile` | 红 |
| 6-2 | `SyncStoreTests.testImportSkipsWhenNodeIdOwnedByAnotherProfile` | 红 |
| 6-2 | `SyncStoreTests.testImportSameProfileStillWorksWithGuard` | **绿**（回归锚） |
| 6-3 | `SyncStoreTests.testTombstoneDoesNotDeleteSameIdInAnotherProfile` | **绿** —— 见「与契约的偏离」 |
| 7 | `PushTargetResolverTests.testResolveCrossProfileAsksForSwitch` | 红 |
| 7 | `PushTargetResolverTests.testResolveDeletedProfileIsTerminal` | 红 |
| 7 | 其余三 case（同楼层 / 不存在 / 空对话） | 绿 |

洞 7 的红是这么造出来的：先把 `PushTargetResolver.resolve` 写成 **ContentView 修前逻辑的复现桩**（当前楼层 scoped fetch，查不到返回 `.conversationMissing`），跑一次拿到红，再换成全库解析。ContentView 那层是 SwiftUI，不单测（契约也不要求）；模拟器实证归 H-Q。

### GREEN（修后，全套 `xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS'`）

三个 suite 全绿，逐条原始输出：

```
Test Suite 'BackupStoreTests' started at 2026-09-02 08:47:42.980.
Test Case '-[MemoryPalaceTests.BackupStoreTests testRestoreEverythingKeepsOverwriteSemantics]' passed (0.074 seconds).
Test Case '-[MemoryPalaceTests.BackupStoreTests testRestoreEverythingStillSkipsProfileOutsideBackup]' passed (0.044 seconds).
Test Case '-[MemoryPalaceTests.BackupStoreTests testRestoreProfileScopeSkipsCrossProfileConflict]' passed (0.044 seconds).
Test Case '-[MemoryPalaceTests.BackupStoreTests testRestoreSingleConversationSkipsCrossProfileConflict]' passed (0.044 seconds).
Test Case '-[MemoryPalaceTests.BackupStoreTests testRestoreWithoutConflictStillRestores]' passed (0.042 seconds).
Test Suite 'BackupStoreTests' passed at 2026-09-02 08:47:43.231.
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.248 (0.251) seconds

Test Suite 'PushTargetResolverTests' started at 2026-09-02 08:47:57.631.
Test Case '-[MemoryPalaceTests.PushTargetResolverTests testResolveCrossProfileAsksForSwitch]' passed (0.009 seconds).
Test Case '-[MemoryPalaceTests.PushTargetResolverTests testResolveDeletedProfileIsTerminal]' passed (0.008 seconds).
Test Case '-[MemoryPalaceTests.PushTargetResolverTests testResolveEmptyConversationIsTerminal]' passed (0.008 seconds).
Test Case '-[MemoryPalaceTests.PushTargetResolverTests testResolveMissingConversation]' passed (0.007 seconds).
Test Case '-[MemoryPalaceTests.PushTargetResolverTests testResolveSameProfileNavigates]' passed (0.007 seconds).
Test Suite 'PushTargetResolverTests' passed at 2026-09-02 08:47:57.673.
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.039 (0.041) seconds

Test Suite 'SyncStoreTests' started at 2026-09-02 08:51:15.158.
Test Case '-[MemoryPalaceTests.SyncStoreTests testTombstoneDoesNotDeleteSameIdInAnotherProfile]' passed (0.019 seconds).
Test Suite 'SyncStoreTests' passed at 2026-09-02 08:51:15.450.
	 Executed 10 tests, with 0 failures (0 unexpected) in 0.288 (0.292) seconds
```

## 全套测试 + build 结果

```
Test Suite 'MemoryPalaceTests.xctest' failed at 2026-09-02 08:51:18.212.
	 Executed 839 tests, with 2 failures (0 unexpected) in 215.161 (215.988) seconds
Test Suite 'All tests' failed at 2026-09-02 08:51:18.218.
	 Executed 839 tests, with 2 failures (0 unexpected) in 215.161 (215.995) seconds
```

**那 2 个 failure 不是我的，是并行构建把机器压出来的墙钟 flake。** 两条都在
`RunCommandToolTests`，两条都是纯 wall-clock deadline 断言：

```
RunCommandToolTests.swift:42: error: ... testTimeoutKillsWholeTree : XCTAssertLessThan failed: ("16.79561698436737") is not less than ("4.0") - 超时后应 ~1.5s 内返回
RunCommandToolTests.swift:93: error: ... testUnboundedOutputStaysBounded : XCTAssertLessThan failed: ("17.040969967842102") is not less than ("6.0")
```

判定依据（不是猜）：
- 断言内容是「`timeout_seconds: 1` 的子进程要在 4s 内返回」和「`timeout_seconds: 2` 要在 6s 内返回」，
  实测 16.8s / 17.0s——**超了一个数量级**，这是调度饥饿不是逻辑错。
- 我这条 lane 一行都没碰 `RunCommandTool` / 子进程 / 超时路径（改动清单见上）。
- 跑的当口 H-B lane 的 `xcodebuild` 也在机器上（我自己的 build 日志里就有
  `[xcodebuild-lock] 排队 …cwd=…/h-b-tool-loop`），两个 Xcode 构建 + 一个测试宿主抢核。
- 隔离重跑结果见下。

**隔离重跑**（`-only-testing:MemoryPalaceTests/RunCommandToolTests`，H-B 的 build 仍在机器上）：

```
	 Executed 23 tests, with 2 failures (0 unexpected) in 155.214 (155.227) seconds
RunCommandToolTests.swift:42: error: ... testTimeoutKillsWholeTree : XCTAssertLessThan failed: ("15.633655071258545") is not less than ("4.0")
```

同样两条、同样 ~15s。**决定性证据在同一份日志里**：

```
Test Case '-[MemoryPalaceTests.RunCommandToolTests testEcho]' passed (14.658 seconds).
Test Case '-[MemoryPalaceTests.RunCommandToolTests testDefaultCwdIsLibraryRootAndContainment]' passed (14.702 seconds).
Test Case '-[MemoryPalaceTests.RunCommandToolTests testMacBackendResolvesCwdToLibraryRoot]' passed (15.503 seconds).
```

`testEcho` 就是跑一句 `echo`、没有任何超时逻辑，也要 14.7s——**这台机器当前对
「起一个子进程」有 ~15s 的延迟地板**，全 suite 一视同仁。那两条断言的预算是 4s / 6s，
撞地板必挂。我的改动不可能让 `echo` 变慢。

`git diff --stat master...HEAD` 佐证改动面（11 个文件，全部与 run_command / 子进程无关）：
`BackupManifest.swift` / `BackupStore.swift` / `PushTargetResolver.swift` / `SyncStore.swift` /
`ContentView.swift` / `DataSettingsTab.swift` / `RestoreSheet.swift` + 三个测试文件 + 本报告。
`RunCommandToolTests.swift` 和 `MacShellBackend.swift` 最后一次改动是 `c836ffaf` / `558932fb`
（沙箱 lane，不是我）。

**给 H-Q 的交接**：机器空下来后单独重跑 `RunCommandToolTests` 复核这 2 条。
我判定它们与洞 6 / 洞 7 无关，**但没有在空载机器上跑绿过**——列进「未验证」。

### build

```
** BUILD SUCCEEDED **
```
（`xcodebuild -scheme MemoryPalace -destination 'platform=macOS' build`，BUILD_EXIT=0）

## 与契约的偏离

1. **`SyncStore.swift:448`（`processTombstones` 的 scoped fetch）不是漏洞，没改。**
   契约说「三处要修」。逐行核过：那处是
   `guard let conv = try? context.fetch(convDesc)?.first else { continue }` ——
   **查不到就 continue，没有任何 insert**，所以撞不上 unique upsert，偷不了数据。
   而且它「查不到就不动」恰恰是**正确**的：楼层 B 的墓碑本来就不该删楼层 A 里同 id 的对话
   （「永久删赢」只在自己楼层内成立）。按 escape hatch「以代码为准」处理：
   **不改代码，补一条回归测试** `testTombstoneDoesNotDeleteSameIdInAnotherProfile` 把这个行为钉死
   （修前修后都绿）。所以真正改的是两处，第三处只加锚。

2. **冲突查询用 `findCrossProfileConversationConflicts` / `findCrossProfileNodeConflicts`，不是 `crossProfileConflictedConversationIds`。**
   契约说照四处 importer 的调法。但那个包装函数的入参是 `[ImportedConversationPayload]`，
   而 BackupStore / SyncStore 手上是 `SyncStore.ConversationDocument`——为了调它得先造一层
   payload，纯浪费。直接用它内部那两个同文件的 building block（`ImportSupport.swift:37 / :59`），
   语义完全一致。**`ImportSupport.swift` 一行没动。**

3. **整库还原的放行条件比契约字面更严一点点。**
   契约：「全库还原如果现有语义允许覆盖 profile 归属，保持不变」。实现成一条统一规则：
   **占用方楼层在本次还原范围内 → 放行（既有语义），不在范围内 → 跳过。**
   - `.conversation` / `.profile` scope：范围只有一个楼层，等价于「任何跨楼层冲突都跳过」= 契约要求。
   - `.everything`：备份里有的楼层之间照旧互相覆盖归属（`testRestoreEverythingKeepsOverwriteSemantics` 锚住），
     但**备份之后新建的楼层**（不在 day-manifest 里）不会被偷（`testRestoreEverythingStillSkipsProfileOutsideBackup`）。
   多出来的只是最后这条保护；契约冻结的既有语义一字未动。

4. **碰了两个 lane 清单外的 View 文件**：`RestoreSheet.swift`、`DataSettingsTab.swift`，各一行文案追加。
   契约明写「跳过数要回到 UI（还原结果 sheet / 同步日志）」，这两处就是那两个 UI。
   不是 H-B 的地盘（H-B 是 `ChatService` / `ConversationViewModel` 工具循环段），无冲突风险。
   `Models/BackupManifest.swift` 同理——`RestoreResult` 的定义在那儿，加计数字段绕不开。

## 顺手发现

（契约范围外，**没修**）

1. **`BackupStore.restore` 的 `deleteOrphanConversations` 在 `.everything` 下有顺序耦合。**
   `for (pid, refs) in targetByPid` 是 Dictionary 迭代，顺序不确定。当同一个 conv id 同时是
   「楼层 A 的孤儿」和「楼层 B 的还原目标」时，两种顺序殊途同归（实测两次都落在 B），
   但这是巧合不是设计——`deleteOrphanConversations` 和 `restoreConversation` 之间没有显式的
   先删后插约定。`BackupStore.swift:331`。建议将来把 orphan 删除整体前置成一趟。

2. **`SyncStore.importAll` 的 `importState` 账本对「跳过」是粘的。**
   我给跨楼层跳过打了补丁（摘掉 mtime 让它下轮重评），但**别的 `continue` 分支没有**：
   `SyncStore.swift:518-520` 解码失败 / schemaVersion 超标 / `document.profileId != profileId`
   三种情况都是 `continue`，而 mtime 已经在 `:494-501` 的 filter 里记进账本了。
   一份暂时坏掉的文档修好前若 mtime 没变，就永远进不来。不在本 lane 范围。

3. **`RestoreResult.profilesRestored` 把跳过的楼层也算进去了。**
   `BackupStore.swift:355` 无条件 `+= 1`，哪怕该楼层每一条都被跳过。文案会显示
   「楼层: 1 · 对话: 0」。不影响数据正确性，只是数字不好看。

## 建议上游

无。没碰到别的 lane 的地盘。

## 未验证（诚实清单）

1. **洞 7 没有模拟器实证。** 契约把 `xcrun simctl push` 实证划给 H-Q，我按硬约束不跑 iOS、不装机、不开模拟器。
   所以以下三件事**只有代码级论证，没有跑过**：
   - 切楼层后新 subtree 的 `onAppear`（`ContentView.swift:454` 那个 0.6s 延迟消费）真的会再触发一次。
     论证：`MemoryPalaceApp` 的 `.id(currentProfile.id)` 使 `switchTo` 后整棵 ContentView 重建，
     重建必走 `onAppear`。**没实测。**
   - `transientNotice` toast 在推送刚打开 app 的时刻确实可见（viewModel 是新建的那份）。
   - 不会切楼层死循环。论证：`switchTo` 同步写 `currentProfile`，新 subtree 解析必落 `.navigate`；
     楼层不存在时走 `.profileMissing` terminal 消费掉 key。**没实测。**
2. **`.unavailable` 分支没被测试覆盖**——造一个「fetch 抛错」的 SwiftData context 成本过高。
   它只是把 `try?` 换成 `do/catch` 后多出来的保守分支，走不到不会有害。
3. **`crossProfileBlocked` 的 500 一批分片**在真实大对话（上万节点）上没跑过性能。
   逻辑照抄 `ImportSupport` 的既有分片常量，且只在**已经确认有冲突**时才进第二趟查询——
   无冲突的常规路径只多一对 indexed id 查询。
4. **`RunCommandToolTests` 那 2 条没在空载机器上跑绿过。** 我的判定（环境 flake）有三条证据支撑
   （同 suite 的 `testEcho` 也 14.7s / 断言是纯墙钟预算 / 改动面零交集），但**没有实际跑绿**。
   归 H-Q 复核。
5. **iOS build 没跑**（硬约束）。`PushTargetResolver.swift` 平台中立、`ContentView` 改动在
   `#if os(iOS)` 块内且只用了已有符号（`BreadcrumbLog` / `TransientNotice` / `ProfileManager.switchTo`），
   但 iOS 编译面归 H-Q。
