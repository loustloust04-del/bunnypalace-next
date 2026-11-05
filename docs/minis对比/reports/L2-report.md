# L2 —— 同步与数据可移植性对比报告

## TL;DR

| 发现 | 差距性质 | 采纳建议 | 代价档位 |
|---|---|---|---|
| 1. OM 的 LAN 传输尚未实现，`SessionLockStore` 也不是编辑锁 | 不适用 | 先修正前提，不把纸面能力当参考实现 | 小时级 |
| 2. `PortableRecord` 的传输中立思路值得学，但 OM 注册表比实际落地更“饱满” | 实现更优 | 按 MP 架构原生做精简版记录契约 + 每类型 merger | 架构级 |
| 3. MP 的对话级 `updateTime` 指纹可漏掉已完成的流式回复 | 实现更优 | 先补完成/失败/取消时钟，再上持久化每记录 dirty outbox | 天级 → 周级 |
| 4. SyncStore 和 BackupStore 的 insert 前查重仍按 `profileId` 缩小，跨楼层 unique-upsert 通道尚在 | 实现更优 | 直接复用 MP 已有的全库冲突预检，整对话原子跳过/改 ID | 天级 |
| 5. MP 的树、分支并集和 ChatGPT 历史入口比 OM 更强；但已有节点的编辑不会合并 | 我们更好 | 保留树语义，只借 OM 的每消息 `updatedAt`/冲突钟 | 周级 |
| 6. 删除语义上 MP 已经比 OM 更完整，且已避开 `isDeleted` 保留名 | 我们更好 | 保留“回收站 + 永久墓碑 + 恢复纪元”，不搬 OM 的纯硬删 | 小时级 |
| 7. OM 有 schema/可选字段的抽象，但 `.null` 与“字段不存在”仍被混在一起 | 不适用 | 只借版本门概念；MP 原生实现显式三态 patch 和版本迁移 | 天级 |
| 8. MP 的 Time Machine 是活路径且有还原前快照，但复用的同步文档不是全字段备份 | 我们更好 | 先做实备份/便携契约，再用同一契约做 LAN 同步 | 周级 |
| 9. 粟粟的两台设备不同 iCloud 账号，真正有价值的是 hub-spooled LAN/Tailscale 传输 | 能力缺失 | 改造搬 CCBridge 的连接/鉴权/重连基座，新建独立 `/sync` 协议与持久化投递簿 | 架构级 |
| 10. 现在不需要分布式会话锁 | 不适用 | 用树分支承接并发 append；必要时只加“本机正在生成时延后复水” | 天级 |

TL;DR 中的每行编号与正文发现编号一一对应；代码断言的文件:行号证据在对应正文内。

## 取证口径与 escape hatch

- `OM/...` 指任务书指定的 OpenMinis clone 根；`MP/...` 指当前 MemoryPalace 仓库根。
- 本次实际枚举到 `OM/src/ios/Agent/Sync/V2/` **16** 个 Swift 文件，不是任务书的 17 个；16 个均逐文件读取。另读了 V2 外的 `CloudSyncEngine.swift`、`SyncDirtyScanner.swift` 和全部 `SessionLockStore.swift`。
- 任务书称 OM “同时支持 iCloud 和 LAN”，但当前代码明确把 LAN 标成 skeleton，并拒绝注册；该前提与现实冲突。
- 这是纯静态阅读；按红线没有 build、没有运行测试、没有 Git 操作。所有运行时结果都仍是未查证。

### 1. OM 的 LAN 与 `SessionLockStore` 都不是任务书所述能力

- **OM 怎么做**：`LANTransport` 文件自述“只有 skeleton”，`isImplemented = false`，所有传输方法均 `preconditionFailure`（`OM/src/ios/Agent/Sync/V2/LANTransport.swift:3-7,27-67`）；`SyncCore.register` 遇到它会直接拒绝（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:182-199`），冷启动也只注册 iCloud（`OM/src/ios/Agent/Sync/V2/SyncV2Bootstrap.swift:171-175`）。`SessionLockStore` 管的是 Face ID/密码保护、解锁时间和空闲重锁，并且故意不进同步/导出链（`OM/src/ios/Agent/Session/SessionLockStore.swift:5-20,64-74,100-114`）。
- **MP 现状**：MP 的 CCBridge 是真实可用的 WebSocket 客户端：候选 URL 可以是 LAN + Tailscale，并会给 URL 加 token（`MP/MemoryPalace/Services/CCBridgeWebSocketClient.swift:270-303`）；它会并发探测候选地址并选可达者（`MP/MemoryPalace/Services/CCBridgeWebSocketClient.swift:624-680`）。但它是 app ↔ hub 的 CC/代理通道，不是数据同步协议。
- **差距性质**：不适用。任务书把两个名字误解成了已落地的传输和并发锁。
- **采纳建议**：不建议从 OM 的这两个文件搬代码。LAN 只能借其“传输能力向量”的思路；真实实现应从 MP 现有 CCBridge 连接基座起步。
- **代价档位**：小时级（修正设计输入）；真正 LAN 同步见发现 9，是架构级。
- **风险与前置**：如果继续把 skeleton 当完成品，会高估 OM，也会低估 MP 已有的网络工程基础。

### 2. 应学 `PortableRecord` 的分层，不应照搬它的注册表表面

- **OM 怎么做**：OM 把逻辑身份固定为 `type + opaque id`，记录内含字段、资产、schema version、最低兼容版本、未知字段和 `updatedAt`（`OM/src/ios/Agent/Sync/V2/PortableRecord.swift:3-23,80-120`）；传输层只消费 `SyncOutboundBatch/SyncInboundBatch`，而 `SyncTransport` 把 send/observe/full fetch/delta fetch/delete 统一在一个边界内（`OM/src/ios/Agent/Sync/V2/PortableRecord.swift:141-163`; `OM/src/ios/Agent/Sync/V2/SyncTransport.swift:48-93`）。域模型本身不直接遵守同步协议，而是先投影成 `Synced*` mirror（`OM/src/ios/Agent/Sync/V2/SyncedTypes.swift:3-10`）。
- **MP 现状**：MP 目前的传输单位是整个 `ConversationDocument`，其中嵌入全部 `NodeDocument`（`MP/MemoryPalace/Services/SyncStore.swift:107-156`）；同一 schema 又被 Time Machine 直接复用（`MP/MemoryPalace/Services/BackupStore.swift:5-14,597-625`）。这让传输、合并和备份完整性绑在一份子集 DTO 上。
- **差距性质**：实现更优。OM 的“域模型 ↔ 便携表示 ↔ 传输”分层比 MP 当前的整文档直连更易演进。但 OM 的 `resolveConflict`/`applyPortableToExisting` 只在注册表内构造（`OM/src/ios/Agent/Sync/V2/SyncableTypeRegistry.swift:147-181`），真实入站路径却直接调各类型 hydrator（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:621-660`; `OM/src/ios/Agent/Sync/V2/SyncCoreHydrators.swift:69-90`），所以它并没有真正把冲突政策集中起来。
- **采纳建议**：改造搬。按 MP 架构原生实现一个小的 `PortableEnvelope`：身份、profileId、type、schemaVersion、operation、updatedAt/version、payload/assets；每个类型只注册 encode/decode/merge/delete。不需要 OM 那套 `Any` 类型擦除和未被入站路径使用的冲突 closure。
- **代价档位**：架构级。
- **风险与前置**：前置是先决定全库唯一 ID 如何包含楼层身份（发现 4），并分开“同步子集”和“灾备全量”两套 schema（发现 8）。

### 3. OM 的每记录 dirty journal 能直接避开 MP 当前的指纹漏更新

- **OM 怎么做**：OM 在 SQLite 内用 `(record_type, record_id)` 做 dirty 表主键，同时记 operation（`OM/src/ios/Agent/Chat/ChatStore.swift:723-731`）。消息写入后立即 `markDirty(Message)`，会话也只标一次，然后同一 SQLite 连接 `COMMIT`（`OM/src/ios/Agent/Chat/ChatStore.swift:2660-2674`）。`SyncCore` 先持久化 dirty，后异步 debounce 发送（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:278-304`），发送时重新从表中取快照（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:355-417`）。这个顺序不依赖另一个 ORM context 何时看到 autosave。
- **MP 现状**：`SyncEngine` 每 5 秒用新的后台 `ModelContext` 扫描导出（`MP/MemoryPalace/Services/SyncEngine.swift:39-45,140-165`），而 `exportChanged` 在读节点之前先用 `conversation.updateTime` 指纹短路（`MP/MemoryPalace/Services/SyncStore.swift:242-257`）。发消息时，MP 在创建空 assistant 占位后就改 `updateTime`（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:2279-2304`）；流式完成时才写入最终 `assistantNode.content` 并 save，但该路径没有再改 `conversation.updateTime`（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:2655-2680`）。**确认的静态可达序列**：5 秒泵先导出空占位并记下该 `updateTime` → 回复完成只改节点内容 → 下次泵在第 251 行直接跳过，最终回复不再出现在同步文档中。
- **差距性质**：实现更优。OM 的变更单位是消息记录；MP 把整棵树的变更检测压在一个对话时钟上。
- **采纳建议**：分两步改造搬。立即修补：最终完成、错误保留 partial、用户取消、已有节点编辑都必须推进同步时钟。结构性修复：在 SwiftData 内建每记录 outbox，业务写入与 dirty 标记同次显式 save，发送成功才按 transport 确认。
- **代价档位**：补时钟是天级；outbox 是周级。
- **风险与前置**：20 万节点不能一次全量标 dirty；要分批建基线。双 context save 事故在本次抽查的两条核心路径中已有明确修复：流式完成显式 save（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:2655-2680`），软删/恢复也专门显式 save（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:1348-1369`）；风险在于这仍是“每个 writer 都必须记得”的纪律，不是架构保证。

### 4. 跨楼层 unique-upsert 在 SyncStore 和 BackupStore 中仍是现役数据通道

- **OM 怎么做**：OM 的线上身份是 `SyncRecordID(type,id)`（`OM/src/ios/Agent/Sync/V2/PortableRecord.swift:3-23`）；本地会话是 SQLite `id TEXT PRIMARY KEY`（`OM/src/ios/Agent/Chat/ChatStore.swift:564-584`）。入站会话先显式 `SELECT ... WHERE id = ?`，有则按时钟 update，无则明确 insert（`OM/src/ios/Agent/Chat/ChatStore.swift:6005-6025,6058-6088,6148-6184`）。OM 没有 MP 的统一库多租户 `profileId`，所以它是通过“不存在这个维度”避开该坑，不是解决了多租户冲突。
- **MP 现状**：`Conversation.id` 和 `MessageNode.id` 都是全库 `@Attribute(.unique)`，`profileId` 只是普通列（`MP/MemoryPalace/Models/Conversation.swift:14-17,104-107`）。MP 其实已有正确的批量全库冲突检查：insert 前查同 ID 是否被其他 profile 占用（`MP/MemoryPalace/Services/ImportSupport.swift:26-76`）。但 `SyncStore.importAll` 仍用 `id + profileId` 查会话，查不到就 insert（`MP/MemoryPalace/Services/SyncStore.swift:511-557`）；节点也只查当前对话 + 当前 profile，查不到就 insert（`MP/MemoryPalace/Services/SyncStore.swift:559-595`）。`BackupStore.restoreConversation` 有同样的 scoped-check-then-insert 形状（`MP/MemoryPalace/Services/BackupStore.swift:419-457,459-513`）。根据任务书给定的 SwiftData 静默 upsert 事故，这是确认的结构性缺口。
- **差距性质**：实现更优。不是 OM 的算法更高级，而是 OM 显式控制主键冲突，不会让 ORM 静默改写所有者字段。
- **采纳建议**：直接搬 MP 自己的正确代码，不需要搬 OM。`SyncStore.importAll` 和 `BackupStore.restore` 在对任何 Conversation/MessageNode insert 前，先用 `crossProfileConflictedConversationIds`。一份对话里任一 ID 冲突就整份跳过，或者先对 conversation/node/parent/children/currentNodeId 做完整确定性改 ID；禁止部分 insert 后才发现冲突。
- **代价档位**：天级。
- **风险与前置**：前置是明确还原语义：“全库还原”可以覆盖 profile 归属，但“单楼层/单对话还原”不应抢走另一楼层的行。长期根治是用带 profile 命名空间的 storage ID，但这涉及全库迁移。

### 5. `PortableRecord` 可以承载 MP 的树，但 OM 自己的会话是线性的

- **OM 怎么做**：OM `RawMessage` 只有 `sessionId`、内容、时间和 `sortOrder`，没有 message parent/children（`OM/src/ios/Agent/Chat/ChatStore.swift:360-378`）；SQLite messages 也是 `session_id + sort_order` 线性序列（`OM/src/ios/Agent/Chat/ChatStore.swift:575-592`）。`SyncedMessage` 同样只声明它是 SessionV2 的直接 child，并用消息 `updatedAt` 做 LWW（`OM/src/ios/Agent/Sync/V2/SyncedTypes.swift:68-105`）。
- **MP 现状**：MP 消息明确有 `parentId` 和 `childrenIds`（`MP/MemoryPalace/Models/Conversation.swift:104-114`），ChatGPT 导入也原样读取 mapping 的 parent/children/current node（`MP/MemoryPalace/Services/ConversationImporter.swift:464-485`）。同步对已有节点会对 `childrenIds` 取并集，所以两端各自长出的分支可共存（`MP/MemoryPalace/Services/SyncStore.swift:567-575`）。但同一段代码随后直接 `continue`，即已有节点的 content、segments、收藏、编辑标志等都不合并。
- **差距性质**：我们更好。MP 的树和导入入口是真实产品能力，OM 的线性 message 设计不能反过来指导 MP 简化掉树。
- **采纳建议**：改造搬。便携记录抽象对树仍然成立：Conversation 是父记录，MessageNode 是每节点记录，payload 带 `parentId`；`childrenIds` 可定义为可并集的派生索引。只借 OM 的每消息 `updatedAt` 作为“同 ID 节点确实被编辑”的冲突钟，不借它的线性 `sortOrder` 作树真相。
- **代价档位**：周级。
- **风险与前置**：要先定义不可变字段（id/profileId/conversationId/parentId/role/createTime）和可变字段（content/segments/标记）。同一 parent 上并发 append 应形成分支，不应被整记录 LWW 吃掉。

### 6. 删除语义上 MP 已经走在 OM 前面

- **OM 怎么做**：OM 早期有 `remote_tombstoned_at` 软墓碑，现在明确废弃且不再读；收到 SessionV2 delete 时直接硬删本地 session 及 children/files（`OM/src/ios/Agent/Sync/V2/TombstoneManager.swift:5-28,34-45`）。出站删除不用域模型 boolean，而是把 dirty row 记为 operation `delete`（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:295-304`）。因此它确实完全避开了 SwiftData/NSManagedObject `isDeleted` 保留名事故，但代价是没有用户可见的跨设备回收站语义。
- **MP 现状**：MP 把老 `isDeleted` 只保留为迁移 zombie，业务字段已改成 `isTrashed/trashedAt`（`MP/MemoryPalace/Models/Conversation.swift:37-47,119-123`）。同步 wire 虽沿用 `isDeleted` 键名保持 JSON 兼容，导出/入库都明确映射到 `isTrashed`（`MP/MemoryPalace/Services/SyncStore.swift:259-287,518-553`）。永久删除另外写 90 天墓碑、删同步文档、对端先扫墓碑再删本地（`MP/MemoryPalace/Services/SyncStore.swift:383-417,420-472`）；全量恢复又有恢复纪元阻断老墓碑反杀（`MP/MemoryPalace/Services/SyncStore.swift:29-40,429-435`）。
- **差距性质**：我们更好。MP 同时表达用户可恢复的软删和不可恢复的永久删，还处理了恢复与老墓碑的先后关系。
- **采纳建议**：不建议搬 OM 的 Session 纯硬删政策。若实现新记录层，可借“删除是 operation，不是持久模型上叫 `isDeleted` 的字段”；但回收站仍保留 MP 的 `isTrashed`。
- **代价档位**：小时级（设计冻结/回归审查）。
- **风险与前置**：墓碑与记录身份必须带 profile 命名空间，否则发现 4 的跨楼层冲突会把“永久删赢”放大成误删。

### 7. 可选字段与 schema 演进只能借 OM 的门，不能搬它的现成路

- **OM 怎么做**：OM 的元数据有 schema version、minimum compatible version 和 known keys（`OM/src/ios/Agent/Sync/V2/PortableRecord.swift:102-120`; `OM/src/ios/Agent/Sync/V2/SyncableTypeRegistry.swift:11-27`）；optional descriptor 把 nil 抽象为 `.null`（`OM/src/ios/Agent/Sync/V2/Syncable.swift:91-109,167-185`）。但 CloudKit 写入时 `.null` 被转成 `record[key] = nil`（`OM/src/ios/Agent/Sync/V2/ICloudSharedZoneTransport.swift:1259-1283`），反向只遍历 `record.allKeys()`（`OM/src/ios/Agent/Sync/V2/ICloudSharedZoneTransport.swift:1306-1335`）；同时 Session merger 却想用“key 是否存在”区分新端显式清空与老端不认识字段（`OM/src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift:173-205`）。**静态推断**：这个显式 nil 在 CloudKit 来回后无法保留“key 曾存在”。更直接的纪律破口是 `folderId` 新增后明写“no version bump”（`OM/src/ios/Agent/Sync/V2/SyncedTypes.swift:26-49`）。
- **MP 现状**：MP 同步 schema 固定为 1，`folderId/isDeleted/deletedAt` 都是 optional（`MP/MemoryPalace/Services/SyncStore.swift:9,109-127`）；入站只做 `document.schemaVersion <= schemaVersion`，没有版本 migrator（`MP/MemoryPalace/Services/SyncStore.swift:504-508`）。本 lane 的关键 SwiftData 查询使用的是非 optional `id/profileId/conversationId`（例如 `MP/MemoryPalace/Services/SyncStore.swift:511-516,559-563`），因此本次没有在同步主路里找到 `#Predicate { optionalField == value }` 的直接复发；这条事故在 OM 也不适用，因为 OM 不使用 SwiftData predicate。
- **差距性质**：不适用。OM 有更好的概念名词，但当前代码没有给出可直搬的 nullable wire 正解。
- **采纳建议**：只借思路。MP 的 patch 字段用显式三态：`absent / set(value) / clear`，编码时不把 clear 和 absent 都变成 JSON key 缺席。当 schema 从 1 升 2 时先做小的纯值 migrator，而不是一开始就搬 OM 的六阶段迁移引擎。
- **代价档位**：天级。
- **风险与前置**：旧文档缺 key 时必须保留本地值，而新文档显式 clear 必须能清掉它。这需要传输协议而不是 Swift `Optional` 单独表达。

### 8. MP 先做实备份契约，但备份不能取代同步

- **OM 怎么做**：在本 lane 指定并实际读取的 OM `Agent/Sync` + `Agent/Session` 范围内，没有版本化用户快照/还原点实现；搜索 `backup|snapshot|restore|rollback` 后，命中的 `MigrationEngine.snapshot()` 只是返回迁移状态（`OM/src/ios/Agent/Sync/V2/MigrationEngine.swift:586-595`），而 `forceFullSync` 是重置 token/cache 后重拉重推，不产生可回滚时间点（`OM/src/ios/Agent/Sync/CloudSyncEngine.swift:701-742`）。这是对指定范围的结论，不声称 OM 全仓库绝对无备份。
- **MP 现状**：`BackupStore` 不是遗弃代码：app 进后台会根据开关调用 snapshot 和 prune（`MP/MemoryPalace/MemoryPalaceApp.swift:849-877`）。它有同日 SHA 去重（`MP/MemoryPalace/Services/BackupStore.swift:153-190`）、还原前快照（`MP/MemoryPalace/Services/BackupStore.swift:240-296`）、强制覆盖还原与显式 save（`MP/MemoryPalace/Services/BackupStore.swift:299-355`）。但它复用的 `NodeDocument` 只到 `imageDescsData`（`MP/MemoryPalace/Services/SyncStore.swift:138-156`），真实 `MessageNode` 还有 style、usage、bookRef、webSources、agentOrigin、recallHits 等字段（`MP/MemoryPalace/Models/Conversation.swift:138-172`）；还原新节点也只写 DTO 里的那些字段（`MP/MemoryPalace/Services/BackupStore.swift:474-513`）。还原循环虽持有带 `sha256` 的 `ConversationRef`，实际加载文档只按 date/profile/id 读取并 decode，没有将 ref.sha256 与文件内容对比（`MP/MemoryPalace/Services/BackupStore.swift:331-338,377-385`）。另一条 `.mpb` 全量备份已有 section checksum 和导入前验证（`MP/MemoryPalace/Services/GlobalBackup/GlobalImporter.swift:99-123`）、两阶段替换与主位验证（`MP/MemoryPalace/Services/GlobalBackup/PendingImportApplier.swift:199-267,310-357`），这些是可复用的 MP 自有资产。
- **差距性质**：我们更好。MP 有 OM 本 lane 未提供的真正回滚点。但“备份成功”尚不等于“所有当前字段可恢复”。
- **采纳建议**：只借 OM 的版本化记录思路，具体先修 MP：Time Machine 不再复用同步子集 DTO；把 `.mpb` 的全字段映射/checksum/staging verify 下沉为共用备份契约；还原前实际校验 manifest 里的每对话 SHA，不只用 SHA 做写入去重。顺序判断：**先保证便携包不漏字段且可还原，再让 LAN 用同一记录契约跑快。**
- **代价档位**：周级。
- **风险与前置**：备份不能取代同步：它解决“某个时点能回去”，不解决两台设备持续合并。而且当前 Time Machine 也在各自 iCloud 容器中，不同 iCloud 账号下不会自动成为另一台设备的备份。

### 9. 对粟粟的真实设备组合，LAN/Tailscale 比继续加码 iCloud 更值得

- **OM 怎么做**：OM 唯一真实传输依赖 CloudKit private database，文件明确限定“same-Apple-ID devices”（`OM/src/ios/Agent/Sync/V2/ICloudSharedZoneTransport.swift:6-16`）。LAN 只是未实现的 Bonjour + WebSocket 设计草图，而且草图自己承认无持久性、无通用 full fetch（`OM/src/ios/Agent/Sync/V2/LANTransport.swift:9-26,30-37`）。
- **MP 现状**：MP 同步根落在 ubiquity container `iCloud.com.susu.MemoryPalace`（`MP/MemoryPalace/Services/FileLibraryStore.swift:27-29,39-64`; `MP/MemoryPalace/Services/SyncStore.swift:48-59`）。结合任务书给定的真实环境——MacAir 与 iPhone Air 不是同一 iCloud 账号——这条路径在两台目标设备之间物理隔离。反而 CCBridge 已有 LAN/Tailscale 候选、token、重连退避和重连后重订阅（`MP/MemoryPalace/Services/CCBridgeWebSocketClient.swift:270-303,1033-1040,1046-1080`）。
- **差距性质**：能力缺失。两边都没有已落地的跨 iCloud 账号数据同步，但 MP 已经有更接近终点的网络基座。
- **采纳建议**：改造搬 CCBridge，不搬 OM skeleton。复用候选地址、token、LAN/Tailscale 选路、心跳、退避和连接状态；在 hub 另建 `/sync` 协议和磁盘 spool，让两台设备不必同时在线。每笔投递带 `(profileId,type,id,version/hash,operation)`，设备按自己的 delivery ledger ack。iCloud 可作可选持久 transport，但不再是唯一路。
- **代价档位**：架构级。
- **风险与前置**：不能复制 OM 的“多 transport 共用一个 dirty 位”。OM 依次 send 给每个 transport（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:469-510`），但任一 transport 返回 success 就删掉全局 dirty（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:541-565`）；当 LAN 真的和 iCloud 同时开启时，第一路成功会使第二路失去重试账本。MP 必须从第一天就做 per-transport ack。

### 10. 同一对话多设备同开不应先用分布式锁解决

- **OM 怎么做**：指定的 `SessionLockStore` 与编辑并发无关（见发现 1）。OM 真正相关的代码在 message merger：如果本机 agent loop 正在该 session 流式生成，就延后入站消息，等下次 CloudKit fetch 再合并（`OM/src/ios/Agent/Chat/ChatStore.swift:6240-6260`）。这是本机活动门，不是跨设备 lease。
- **MP 现状**：MP 对并发 append 已有自然表达：两个新节点可以挂在同一 parent 下，`childrenIds` 入站取并集（`MP/MemoryPalace/Models/Conversation.swift:104-114`; `MP/MemoryPalace/Services/SyncStore.swift:567-575`）。当前缺的是“同 ID 已有节点被修改”的冲突规则，不是一把会话大锁。
- **差距性质**：不适用。
- **采纳建议**：不建议现在实现分布式 SessionLock。保留 offline-first：并发新消息成为分支；对已有节点用 node version/LWW 加可见冲突提示。只在 LAN 入站已经能做到秒级后，借 OM 的本地 `activity gate` 避免正在生成的界面被中途复水。
- **代价档位**：本地 activity gate 天级；分布式锁不做。
- **风险与前置**：分布式锁会带来过期锁、断网无法写、时钟与抢锁冲突，却没解决同一节点的字段合并。先有发现 5 的 node version 才有讨论锁的基础。

## 四个特别问题，直接回答

1. **`PortableRecord` 对 MP 的对话树仍然成立吗？** 成立，但单位必须是 Conversation + 每个 MessageNode，不是 OM 的线性消息复制品。MP 的 `parentId/childrenIds` 在模型中是明确树边（`MP/MemoryPalace/Models/Conversation.swift:104-114`），OM 消息则只有 `sessionId/sortOrder`（`OM/src/ios/Agent/Chat/ChatStore.swift:360-378`）。`parentId` 是树的真相，`childrenIds` 是可并集索引，分支不用 LWW 压平。
2. **MP 该补同步，还是先做实备份？** 先做实共享的数据契约与备份还原，立即修 unique-upsert 与流式指纹两个现役缺口（`MP/MemoryPalace/Services/SyncStore.swift:242-257,511-595`; `MP/MemoryPalace/ViewModels/ConversationViewModel.swift:2279-2304,2655-2680`）；然后用同一契约建 LAN/Tailscale 同步。备份不能替代同步，但在契约仍会漏字段时先加传输只会更快地扩散不完整数据（字段对照见 `MP/MemoryPalace/Services/SyncStore.swift:138-156`; `MP/MemoryPalace/Models/Conversation.swift:138-172`）。
3. **墓碑 / 冲突 / 迁移什么时候做？** 墓碑现在已有（`MP/MemoryPalace/Services/SyncStore.swift:383-472`），保留并补跨楼层身份审计；冲突规则现在就做，因为同步已经存在且 scoped insert 可抢数据（`MP/MemoryPalace/Services/SyncStore.swift:511-595`）；schema v1→v2 的小 migrator 现在做，OM 那种跨 zone、巨量 backlog、可恢复检查点的全迁移引擎（`OM/src/ios/Agent/Sync/V2/MigrationEngine.swift:15-39,526-579`）等真正更换存储/传输后再做。
4. **`SessionLockStore` 对 Mac + iPhone 同开一楼层有用吗？** 没有，它是生物识别隐私锁（`OM/src/ios/Agent/Session/SessionLockStore.swift:5-20,64-74`）。现阶段不加分布式会话锁；用分支处理并发新消息（`MP/MemoryPalace/Services/SyncStore.swift:567-575`），用 node version 处理同节点编辑，用本机 activity gate 保护正在流式生成的 UI（OM 对照：`OM/src/ios/Agent/Chat/ChatStore.swift:6240-6260`）。

## §反向发现

1. **MP 的对话树与分支合并领先 OM。** MP 保存 parent/children/current node（`MP/MemoryPalace/Models/Conversation.swift:104-114`; `MP/MemoryPalace/Services/ConversationImporter.swift:464-485`），同步对 children 取并集（`MP/MemoryPalace/Services/SyncStore.swift:567-575`）；OM 仅有 session + sort order 线性消息（`OM/src/ios/Agent/Chat/ChatStore.swift:360-378,575-592`）。
2. **MP 有 OM 本 lane 没有的外部历史入口。** MP 解码 ChatGPT `conversations.json` 并保留 mapping 树（`MP/MemoryPalace/Services/ConversationImporter.swift:35-59,464-485`）。在 OM `src/` + `docs/specs/` 搜索 `conversations.json|current_node|ChatGPT export/import` 无命中；因此本结论是“在该搜索范围未找到”，不是对仓库外部产品能力的声明。
3. **MP 的删除/恢复状态机更符合用户数据产品。** `isTrashed`、永久墓碑、90 天窗口、还原前纪元已成链（`MP/MemoryPalace/Models/Conversation.swift:37-47`; `MP/MemoryPalace/Services/SyncStore.swift:383-472`）；OM 现政策是远端 delete 直接硬删（`OM/src/ios/Agent/Sync/V2/TombstoneManager.swift:34-45`）。
4. **MP 有真正的灾备与可回滚导入链。** Time Machine 为活路径（`MP/MemoryPalace/MemoryPalaceApp.swift:849-877`），`.mpb` 路径还有 checksum、staging、主位 verify 和反向 rollback 前置（`MP/MemoryPalace/Services/GlobalBackup/GlobalImporter.swift:99-123`; `MP/MemoryPalace/Services/GlobalBackup/PendingImportApplier.swift:199-267,310-367`）。OM 的 sync/migration 是收敛系统，不是时间点备份。

## §不建议学

1. **不学 OM 的 LAN skeleton。** 它不能运行，且设计上无 persistence/full fetch（`OM/src/ios/Agent/Sync/V2/LANTransport.swift:3-7,20-24,35-67`）。MP 真实需求是跨账号、可断续，应让 hub 持久化 spool。
2. **不学 OM 的会话纯硬删。** MP 有用户可恢复的回收站和明确的永久删，不应因为 transport 简单而降级产品语义。
3. **不学 OM 的 V1/V2 长期混合。** `SyncV2Bootstrap` 明确说 V2 关闭时由旧 `CloudSyncEngine` 运行，开启后暂停 V1（`OM/src/ios/Agent/Sync/V2/SyncV2Bootstrap.swift:5-13,115-130`）；V2 hydrator 又回调 V1 的 provider secrets/merge 函数（`OM/src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift:564-590,593-650`）。因此 V2 外的 `CloudSyncEngine.swift` 是**旧引擎 + 被借用的兼容工具集**，不是纯协调层。MP 应用一次性 adapter 迁移，不应双引擎长期双写。
4. **不学 OM “注册表已统一冲突”的假完成感。** `resolveConflict` 和 apply closures 被构造（`OM/src/ios/Agent/Sync/V2/SyncableTypeRegistry.swift:147-194`），但入站仍跳到手写 merger（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:621-660`）。MP 如果建注册表，要让真实入站路径只能通过它，否则少一层抽象更诚实。
5. **不学 OM 多 transport 共用单 dirty 确认位。** 架构声称广播给多 transport（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:17-29,35-40`），但每一路 success 都会清全局 dirty（`OM/src/ios/Agent/Sync/V2/SyncCore.swift:469-475,541-565`）。LAN 尚未实现，这个问题暂时没被真实双传输暴露；MP 不要复制这个潜伏条件。

## 已检查且未发现同类复发

- 同步主路的 SwiftData predicates 都落在非 optional 的 `id/profileId/conversationId`，未发现任务书第 4 条“optional 字段等值静默匹配不到”在 SyncStore/BackupStore 主路直接复发（样例 `MP/MemoryPalace/Services/SyncStore.swift:511-516,559-563`; `MP/MemoryPalace/Services/BackupStore.swift:423-425,461-463`）。
- 软删和恢复两个会被后台 SyncEngine 读取的主 context 写入点已显式 save（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:1348-1369`）；同步入站批次也在 dirty 时显式 save（`MP/MemoryPalace/Services/SyncStore.swift:604-608`）。这不能证明全仓库所有 writer 都安全，只能证明本 lane 抽查的核心删除/入站路径已知道该事故。

## 未查证

- 没有运行两台实机、iCloud daemon、CloudKit Dashboard 或 cc-bridge hub；所有时延、丢包、账号可见性与实际收敛行为未验证。
- 没有 build/测试，也没有把源码注释里的“实测”当成本次重现证据。
- 没有全仓库逐一证明 OM 绝对无备份/导入功能；反向发现中的“未找到”都明确限定了搜索路径与关键词。
- 没有验证 `BackupStore` 对所有当前 model 的实际还原结果；“漏字段”结论来自 model 字段与真实 encode/restore 路径的静态对照。
