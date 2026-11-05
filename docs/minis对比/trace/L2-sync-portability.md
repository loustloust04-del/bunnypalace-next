# L2 —— 同步与数据可移植性

先读 `COMMON.md`（同目录）。本文件只写这条 lane 独有的东西。

## 这条轴问什么

**用户的数据怎么在设备之间活下来，以及怎么不丢。**

OM 有一套明显是重写过的同步系统（目录直接叫 `Sync/V2`，17 个文件），并且同时支持 iCloud 共享区和局域网传输，还有墓碑、迁移引擎、脏数据扫描、上传策略。
MP 在同步和数据完整性上**流过血**（见下），而且 MP 的数据模型比 OM 复杂（对话树、分支、楼层多租户）。这条轴是「别人已经踩完的坑」的富矿。

## OM 侧读什么（`src/ios/Agent/Sync/`）

- `V2/` 全套 17 文件，重点：
  - `PortableRecord.swift` + `Syncable.swift` + `SyncableTypeRegistry.swift` + `SyncedTypes.swift` —— **可移植记录抽象**。这是核心：他们怎么把领域模型和同步表示解耦？注册表模式解决了什么？
  - `SyncCore.swift` + `SyncCoreHydrators.swift` + `ChatStoreSyncHydrators.swift` —— hydrator 模式（记录→对象的复水）。
  - `SyncTransport.swift` + `ICloudSharedZoneTransport.swift` + `LANTransport.swift` —— **传输抽象 + 两种实现**。为什么要 LAN 传输？它解决 iCloud 的什么问题？
  - `TombstoneManager.swift` —— 删除的表示。**这条对 MP 极重要**，见下面的事故。
  - `MigrationEngine.swift` + `SyncV2Bootstrap.swift` —— 从 V1 迁移，以及冷启动装配。
  - `UploadPolicy.swift` + `SyncDirtyScanner.swift` + `SessionFileChangeTracker.swift` —— 什么时候传、传什么。
  - `ForceSyncHelper.swift` —— 手动兜底（用户按钮？）
- `CloudSyncEngine.swift`（V2 外面那个）—— 判断它是旧引擎还是协调层。
- 顺带看 `Agent/Session/SessionLockStore.swift` —— 多设备同时编辑一个会话怎么办。

## MP 侧对照坐标

- MP 用 **SwiftData**，数据库在 `~/Library/Application Support/MemoryPalace/{profileId}.store`，**楼层系统 = 统一 ModelContainer + profileId predicate 做多租户**。
- 备份：`Services/BackupStore.swift`（743 行，MODULE_INDEX 标了 🔴 god class + 🟡 疑似遗弃）、`Models/BackupManifest.swift`。
- iCloud 同步现状：自己 grep 确认 MP 到底有没有跨设备同步、走的什么（CloudKit? 文件同步?）。
- 导入链：MP 能导入 ChatGPT 导出。这是 OM 没有的数据入口。

## 车头给的额外情报（血泪，你查不到）

这些是 MP 的真实事故，**请带着它们去看 OM 是怎么规避的**——这是本 lane 最高价值的部分：

1. **`isDeleted` 是 NSManagedObject 保留名**。MP 的 @Model 上曾定义业务字段 `isDeleted`，set + save 会被框架**逆转**。S4 同步坏了一整天才挖出根因。
   → 去看 OM 的 `TombstoneManager` 用什么表示删除、字段叫什么。这是「删除语义」的直接对照。
2. **SwiftData unique 冲突是静默 upsert，不是报错**。insert 同 id 会改写全部属性**包括 profileId**。在 MP 的单库多租户下，这等于一条偷数据通道——查重必须全库查，不能带 profileId 缩范围。
   → 去看 OM 的记录合并/冲突解决怎么做的，有没有等价陷阱，他们的 id 空间怎么分。
3. **SwiftData 双 context 写后必须显式 save**，autosave 有延迟；主 ctx 改完不 save，后台 ctx fetch 读到旧值。用同 context 写的测试会 PASS，是假阳性。
4. **`#Predicate { $0.optionalField == value }` 在 optional 字段上静默匹配不到**。
5. **MacAir 和 iPhone Air 登的不是同一个 iCloud 账号**，MP 的 iCloud 同步在粟粟的设备间是**物理隔离**的。
   → 这条直接关系到 `LANTransport` 的价值判断：OM 为什么做 LAN 传输？对 MP 是不是比 iCloud 更实用？MP 已经有 cc-bridge 的 LAN WebSocket 基础设施（app ↔ 本机 hub），能不能复用？**这可能是本 lane 最有价值的一条，请重点展开。**

## 特别要回答的

1. `PortableRecord` 那套抽象，对 MP 的**对话树 + 分支**这种复杂结构还成立吗？（MP 的消息是树，有分支冒泡和 effectiveChildrenMap；OM 的会话是不是线性的？先查证再判断）
2. MP 现在的备份（`BackupStore`）和 OM 的同步是两种东西——**MP 该补的是同步，还是把备份做扎实？** 给你的判断和理由。
3. 墓碑 / 冲突解决 / 迁移引擎，哪些是 MP 现在就该有的，哪些是「等真有多设备用户了再说」？
4. OM 的 `SessionLockStore`（会话锁）对 MP 的场景（同一楼层可能被 Mac 和 iPhone 同时开）有没有用？
