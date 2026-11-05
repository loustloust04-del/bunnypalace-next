# Code Review: 记忆宫殿

日期: 2026-06-10
审查范围: 全项目（macOS 主 target 为主；双平台共用源码的 iOS 问题一并报告）
代码规模: 146 files, 51,673 lines
方法: 核心路径逐行人工深读（全部 @Model、App 入口、ChatService、ConversationViewModel、APIProvider、MarkdownExporter 等）+ 6 个并行审查代理覆盖其余集群，所有 P0/关键 P1 均经原文行号二次核实。

## 概要

整体健康度**中等偏上，但有四个必须立即处理的数据安全/可用性问题**。优点很突出：关键决策几乎都有注释记录根因与实测依据（PagingViewController、CCBridgeWebSocketClient 是质量标杆），profileId 楼层隔离纪律在绝大多数 fetch 中执行到位，"预览复用实发链路"等项目教训有清晰的落地痕迹。最大的结构性问题有三类：① **单 container + 全库 unique id 与多楼层导入的根本冲突**（P0-1），这是路线 B 架构唯一一处没想透的地方；② **四个 2400-3000 行的 God Object**（ConversationViewModel / CardFlowView / SidebarView / PersonaSettingsTab）承载全部核心逻辑，已到"改一处读三千行"的程度；③ **`try?` 吞错文化**——全项目 404 处 `try?`（其中 68 处吞掉 `context.save()`），叠加四处"失败也报成功"的 UI，数据写失败时没有任何一层能浮出水面。无单元测试 target，意味着以上所有问题都只能靠人肉回归。

---

## P0 — 必须立即修复

> 定义：会导致崩溃、数据损坏、安全漏洞，或阻塞后续开发的问题。

### [P0-1] 全库 unique id + 仅查本楼层的去重 → 跨楼层导入会静默"偷走"另一楼层的对话
- **位置**: `Models/Conversation.swift:14,82`（`@Attribute(.unique)` 声明）；触发点 `Services/ConversationImporter.swift:49-52,76-87`、`Services/ClaudeImporter.swift:94-97,124-135`、`Services/UnifiedContainerMigration.swift:154-212`
- **维度**: D2 SwiftData
- **现状**: 路线 B 单 ModelContainer 下，Conversation/MessageNode 的 id 是**全库**唯一，但导入去重只 fetch **当前楼层**（`#Predicate { $0.profileId == scopedProfileId }`）。SwiftData 对 unique 冲突的 insert 行为是 upsert——更新现有行的全部属性，**包括 profileId**。
- **风险**: 把同一份 ChatGPT/Claude 导出导入楼层 B 时，若楼层 A 已有同 id 对话，不报错也不重复——而是把楼层 A 那行的 profileId 改写成 B：**楼层 A 的对话连同全部 MessageNode 静默消失**。"同一份导出试导入多个楼层"是完全现实的使用方式；迁移路径（per-profile store 时代同一文件进过两个楼层）同理，后迁的楼层会把先迁的行抢走。merge 导入还可能把别的楼层同 id 节点"抢"过来，导致那边树断裂。
- **建议方向**: 改复合唯一（profileId + id 拼接成存储 id，或去掉 `.unique` 改由导入层保证）；短期至少在导入前做一次**全库** id 冲突检查并阻止/提示。

### [P0-2] 角色卡问候对话写入 profileId=""，任何楼层永远看不到
- **位置**: `MemoryPalaceApp.swift:1200-1223`（`ProfileEditorSheet.importCardContent`）
- **维度**: D2 / D5
- **现状**: 导入角色卡时创建的 first_mes / alternate_greetings 对话和 MessageNode，构造时**没传 profileId**（init 默认 `""`）；同一函数里的 WorldBook 倒是正确传了 `profile.id`。全项目没有任何空 profileId 的回填逻辑（已 grep 验证），所有列表 fetch 都按 profileId 过滤。
- **风险**: 用户导入角色卡后开场白对话**不出现**——功能静默失效；且每次导入都在库里堆一批永远查不到的孤儿行。
- **建议方向**: 两处构造传 `profile.id`；补一个一次性清理，把存量 `profileId == ""` 的 Conversation/MessageNode 归位或删除。

### [P0-3] MCP 请求超时机制自身失效：超时分支挂死，聊天回合卡死到重启
- **位置**: `Services/MCP/MCPClient.swift:99-122`（`sendRequest`）；同款模式 `Services/MCP/MCPSSETransport.swift:81-93`（connect 等 endpoint 事件）
- **维度**: D3 并发安全
- **现状**: 超时用 `withThrowingTaskGroup` 双子任务实现——一个子任务挂在 `withCheckedThrowingContinuation` 等回包，另一个 sleep 后 throw。超时先触发时 group body 以 throw 退出 → 隐式 cancelAll **并等待所有子任务结束**；但 cancel 不会 resume 卡在 continuation 里的子任务（pending 里的 continuation 只有 server 回包 / 连接关闭才 resume）。
- **风险**: server 接受连接但不回包时，`sendRequest` **永不返回**：工具调用回合挂死 → `assistantTurnInFlight` 永远为 true → 该对话再也发不出消息，只能重启 app。心跳（`MCPProvider.heartbeat` 调 `listTools()`）同样挂死 → 断线重连永不触发。超时机制存在的意义恰恰是兜底这种场景，而它本身是坏的；pending continuation 还会泄漏。SSE connect 同款：HTTP 200 但不发 endpoint 事件时 `connect()` 永挂、状态停在 connecting 无报错。
- **建议方向**: 超时分支主动 `pending.removeValue(forKey: id)?.resume(throwing: MCPError.requestTimeout(...))`，或改单 Task + `withTaskCancellationHandler`。两处同修。

### [P0-4] 「解绑」世界书实际是无确认的永久删除
- **位置**: `Views/GeneralSettingsTab.swift:204-211`（macOS），iOS 同构分支 `:345-352`
- **维度**: D5 错误处理
- **现状**: 函数名 `unbindWorldBook`、UI 是世界书行旁的小 ✕，执行的却是 `modelContext.delete(book)`——整本世界书连全部 entries 永久删除，无确认弹窗、无撤销，`try? modelContext.save()` 连失败都看不见。
- **风险**: 用户想"暂时解绑"，结果丢掉一本可能手工维护了很久的世界书。对照同集群 ThemeSettingsTab 删除主题有完整确认 alert（`ThemeSettingsTab.swift:153-170`），这里是裸删。
- **建议方向**: 解绑只改 `profile.linkedWorldBookIDs`，不动 WorldBook 行；真删除走单独入口 + 确认弹窗。

---

## P1 — 近期应处理

> 定义：当前可运行但正在积累技术债，随项目增长会升级为 P0 的问题。

### 数据层

### [P1-1] 标签 tab 分页坏死：忽略 offset 且每次全量 fetch
- **位置**: `Views/SidebarView.swift:1474-1495`（配合 loadMore `:1435-1438`）
- **维度**: D2
- **现状**: 选中标签时 fetch 该 tag 全部 FavoriteItem，再**无 fetchLimit** 拉全部非删除会话内存过滤，最后 `Array(filtered.prefix(pageSize))`——offset 参数被无视。
- **风险**: 标签下超过 100 条会话永远只显示前 100 条；滚到底触发 loadMore 只是白做一次全量 fetch 再重置回前 100 条。功能 bug + 性能债二合一。
- **建议方向**: 标签桶也走 offset 分页；用 convIds 收窄 predicate 而非全量后内存过滤。

### [P1-2] 统一迁移的两个静默缺口：open 失败置 done 永不重试；WAL/SHM sidecar 改名扩展名写错
- **位置**: `Services/UnifiedContainerMigration.swift:62-70,98-99`（open 失败 `continue` 后仍无条件 `set(true, forKey: doneKey)`）；`:110-129`（`url.appendingPathExtension("wal")` 产生 `xx.store.wal`，真实 sidecar 是 `xx.store-wal` 连字符，`fileExists` 永远 false）
- **维度**: D2 / D5
- **现状**: 某楼层 legacy store 打不开时被跳过但迁移标记照常落下；sidecar 从未随主库改名（磁盘实证：`~/Library/Application Support/MemoryPalace/` 下存在孤儿 `275202A6….store-shm/-wal`，对应主库已改名为 `.backup-2026-04-22`）。且 rename 发生在 legacy container 仍打开时。
- **风险**: 打不开的楼层数据"静默不可达且永不重试"（文件还在但 app 里是空楼，无任何提示）；"永久保留的备份"缺 WAL，未 checkpoint 的事务不保证在备份主文件里——目前没丢是运气不是设计。
- **建议方向**: open 失败时不落 doneKey（或按 profile 粒度记录）；sidecar 用 `-wal`/`-shm` 命名；rename 前先销毁 legacy container 让连接关闭。

### [P1-3] 全项目无 VersionedSchema / SchemaMigrationPlan
- **位置**: 全项目 grep `VersionedSchema|SchemaMigrationPlan|MigrationStage` = 0 命中
- **维度**: D2
- **现状**: schema 已演进多次（profileId、segmentsData、ccMessageId、draft 系列），全靠 lightweight migration 加列兜底。
- **风险**: 目前都是"加带默认值字段"所以没炸；一旦需要改名/改类型/拆表，lightweight migration 直接失败，20 万节点的用户库没有版本化迁移路径可走。
- **建议方向**: 在下一次 schema 变更前补 VersionedSchema 基线。

### [P1-4] `#Index` 全部包在 `#if os(iOS)` 里，macOS 主平台 20 万行无索引
- **位置**: `Models/Conversation.swift:6-12,74-80` 等全部 12 个 @Model
- **维度**: D2
- **现状**: `#Index` 需要 macOS 15+，部署目标是 14.0，于是统一 `#if os(iOS)`。
- **风险**: 20 万 MessageNode 所在的本体平台上，所有按 profileId / conversationId 的 fetch 都是全表扫；搜索、导入去重、加载对话的延迟都被放大。
- **建议方向**: 用 `#if os(iOS) || compiler/availability` 方案给 macOS 15+ 也吃上索引，或评估部署目标上调。

### [P1-5] 迁移与导入的内存峰值：全量载入
- **位置**: `Services/UnifiedContainerMigration.swift:182`（`legacyCtx.fetch(FetchDescriptor<MessageNode>())` 一次性全量进内存，违反项目红线的字面违例）；`Services/ConversationImporter.swift:4,33-37` 与 `Services/ClaudeImporter.swift:78-82`（注释自称 "Streams … in batches"，实际 `decoder.decode([RawConversation].self, from: data)` 整文件一次性 decode）
- **维度**: D4
- **风险**: 主力楼层迁移瞬时内存 = 整库文本体积；几百 MB 的 ChatGPT 导出内存峰值数倍于文件大小。macOS 挺得过，iOS 复用此代码会 OOM。batch 只 batch 了 SwiftData 写入侧。
- **建议方向**: 迁移读侧设 `fetchBatchSize`/分页；导入器注释先改实话，长期换流式 JSON 解析。

### [P1-6] 导入/撤回的中断状态不可恢复且全程吞错
- **位置**: `Services/ConversationImporter.swift:106,119-139`（中途失败无 `rollback()`，record 计数与 `supportsUndo` 要循环全部结束才写 → 部分导入既删不掉也撤不了）；`Views/ImportView.swift:662-668`（security scope 失败静默 return、`try? copyItem` 失败后续读不到文件）；`Views/ImportHistoryView.swift:112-128`（撤回中途失败静默中止，留半撤回态无提示）
- **维度**: D5
- **风险**: 导入是该产品的核心入口。失败时已落库批次成为挂在死 record 上的孤儿（好在重导会按 id skip 不重复）；撤回半完成态用户不可见（好在重跑幂等，但用户不知道要重跑）。
- **建议方向**: 失败分支把 record 标成可撤销或回滚当前批；三处吞错补用户可见报错。

### [P1-7] SearchService：N+1 全量节点 fetch + 跨线程返回活模型
- **位置**: `Services/SearchService.swift:168-198`（每个命中对话单独 fetch 全部 MessageNode 算主线，含 content 全拉）；`:402-445`（`searchStickers` 把后台临时 ModelContext fetch 出的 `[StickerAsset]` 经 continuation 返回主线程，context 随闭包销毁）
- **维度**: D2 / D3
- **风险**: 常用词命中几百对话时几百次往返 + 内存峰值；后者是 SwiftData 已知崩溃模式（宿主 context 销毁后访问属性触发 fault），同文件其他搜索都正确转值类型返回，唯独这处漏网。
- **建议方向**: 主线计算用 `propertiesToFetch`（只要 id/parentId/childrenIds）；searchStickers 改返回值类型 struct。

### 并发

### [P1-8] StickerViewModel 在后台执行器上修改驱动 UI 的 @Observable 状态
- **位置**: `ViewModels/StickerViewModel.swift:129-136,197-204`（`importImages`/`importImageData`/`updateStyle` 是非隔离 async，直接写 `isImporting`/`importProgress`，而旁边的 `context.insert` 又刻意包了 `MainActor.run`——唯独漏了这三个字段）
- **维度**: D3
- **风险**: SwiftUI 从后台线程收到 observation 更新属未定义行为（UI 不刷 / 偶发崩溃 / runtime warning）。
- **建议方向**: 函数标 `@MainActor`，重活下沉到局部 `Task.detached`。

### [P1-9] 贴纸拖放回调在后台线程读主线程高频写的共享字典
- **位置**: `Views/CardFlowView.swift:599-637`（`provider.loadItem` completion 非主线程，直接读 `viewModel.selectedConversation`、遍历 `stickerVM.bubblePositions`）；写侧 `:232-238`（每个气泡 `.task(id: midY)` 高频写同一字典）
- **维度**: D3
- **风险**: Dictionary 并发读写可直接崩溃；SwiftData model 跨线程读违反 context 线程约束。
- **建议方向**: completion 第一行 hop 到 main 再做全部读写。

### [P1-10] 导入器 ModelContext 跨 await 悬挂点使用
- **位置**: `Services/ConversationImporter.swift:45,106-117`、`Services/ClaudeImporter.swift:90,154-165`（`try context.save()` → `await updateProgress(...)` hop 主线程 → 回来继续用同一 context）；入口 `Views/ImportView.swift:678,689`（`Task.detached`）
- **维度**: D3
- **风险**: 单 Task 顺序访问无真竞争，但每个 await 后 continuation 可落在协作池不同线程，ModelContext 非 Sendable、按语义是单线程域对象——"碰巧没炸"而非"保证不炸"，Swift 6 strict concurrency 直接编译不过。
- **建议方向**: 导入器改 `@ModelActor`。

### 崩溃 / 正确性

### [P1-11] `profileManager!` 强制解包
- **位置**: `Views/CardFlowView.swift:94,107`（`makeRegenerateAction`/`makeEditAction` 的 guard 只检查 providerManager，闭包内 `self.profileManager!.currentProfile`，而声明是 optional `@Environment`）
- **维度**: D1 / D3
- **风险**: 环境注入不完整时点「重新生成」「编辑重发」直接崩。项目自己的教训（injectPagingEnv 不完整 → iOS Route C child HC 不继承 env）证明 env 为 nil 不是理论场景。
- **建议方向**: 进 guard（同函数 96-98 行已示范 optional + fallback 的正确写法）。

### [P1-12] MarkdownExporter：root 选择非确定性 + 全树导出递归爆栈
- **位置**: `Services/MarkdownExporter.swift:88-89`（`nodeMap.values.first(where: { $0.parentId == nil })`——字典迭代非确定性；这正是 ConversationViewModel 里修过并写了长注释的"抽盲盒"bug，`buildTreeInBackground` 已改 `candidates.map(\.id).min()`，exporter 漏了）；`:210-289`（`formatFullTree` 的 `walk`/`depth(of:)` 递归，对话即线性深链，5000 条消息 = 5000 层递归）；`:322-327`（DateFormatter 每节点新建）
- **维度**: D5 / D4
- **风险**: 批量导出可能随机选错 root 导出空/错内容；长对话全树导出栈溢出崩溃。
- **建议方向**: root 选择与 ViewModel 同款确定性算法（抽公共函数）；walk 改迭代（同文件 `longestPath` 已示范）；formatter 静态化。

### [P1-13] ContentCleaner 缓存键三套策略并存 → 复制/朗读/预览拿到旧文本
- **位置**: 实现 `Utils/ContentCleaner.swift:12-17`（命中即返回，不校验内容）；三套 key：`Views/CardFlowView.swift:2443,2451,2482,2762` 与 `Views/PinnedMessageBar.swift:90` 用裸 `node.id`；`Views/CardFlowView.swift:2226` 与 `Views/ChatBubbleStyle.swift:219` 用 `"\(node.id)_\(node.content.count)"`；`Services/MarkdownExporter.swift:242,301` 传 nil 退化为 `text.hashValue`
- **维度**: D4（数据正确性，用户可感知）
- **现状**: `node.content` 会被原地改写（流式逐 token、CC edit_message、merge 导入），裸 node.id 键命中后返回**旧清洗结果**——「复制文本」复制到剪贴板的可能是编辑前的文本。渲染路径已用 `id_count` 自行规避，说明 stale 踩过但只修了两处。另外流式期间 `id_count` 每 token 生成新 key、value 是整个前缀串，无 countLimit 的 NSCache O(n²) 膨胀（一条万字回复堆数十 MB）。
- **建议方向**: 统一键策略（id + 内容版本），NSCache 设 countLimit；clean 内部可用 content 长度/hash 做一致性兜底。

### [P1-14] 贴纸样式更新后图片缓存永不失效，全链路显示旧图
- **位置**: `ViewModels/StickerViewModel.swift:363-372`（`updateStyle` 同名覆盖写文件，从不调 evictCache——全工程仅 deleteAsset 调过）；`Services/StickerFileManager.swift:28-36`（缓存 key `profileId/path` 不含内容版本）
- **维度**: D4
- **风险**: 改完描边/滤镜后，库缩略图和画布贴纸本次会话内一直显示旧样式，重启才恢复。
- **建议方向**: `saveStickerImage` 后 evict，或 key 掺入 mtime。

### [P1-15] 用户可见的"死功能"集群（点了没反应）
- **位置**: `Views/StickerLibraryView.swift:243-246`（`renameSticker` 函数体为空，右键菜单「重命名」`:93` 已挂——画布侧重命名是完整实现，接上即可）；`Views/PersonaSettingsTab.swift:287-299`（`exportPreset` 函数体整体 `#if os(macOS)`，iOS 按钮 `:1885-1893` 照常调用 = no-op）；`Views/RegexScriptEditor.swift:118`（`frame(width: 460, height: 520)` 无平台守卫，iPhone 上 sheet 内容溢出裁切）；`Views/DataSettingsTab.swift:378-380,449-452`（iOS 批量导出按钮可点、实现是 `return`）
- **维度**: D6 / D7
- **风险**: 四处都是"按钮在、功能无"，用户感知为 bug。
- **建议方向**: 各自补实现或平台上隐藏/disabled + 标注。

### 性能

### [P1-16] 流式渲染热点集群：每 token 重复付费
- **位置**: ① `node.segments` 每次访问都 JSONDecoder 解码 + externalStorage blob 读，单气泡 body 内访问 2-3 次（`Views/CardFlowView.swift:2199,2266,2301`；`Views/ChatBubbleStyle.swift:158,183,209`）；② `extractThinking` 每次调用新建 NSRegularExpression 全文匹配（`Utils/ContentCleaner.swift:106-139`，调用点 CardFlowView:2227 / ChatBubbleStyle:221）；③ 流式 onChange 无条件 `proxy.scrollTo`（`Views/CardFlowView.swift:356-360`，没查现成的 `isAtBottom`——用户流式中向上翻历史会被每个 token 拽回底部，性能 + UX 双重问题）；④ 每气泡 17 个 `@AppStorage` 订阅（`:2067-2083`）
- **维度**: D4
- **风险**: 长回复流式期间 O(消息长 × token 数) 的 JSON/正则/布局开销叠加，是聊天主路径的最大 CPU 热点；③ 还锁死流式中的阅读。
- **建议方向**: body 顶部取一次 segs 复用；正则 `static let`；scrollTo 加 `isAtBottom` 条件；@AppStorage 下沉为传入的设置值类型。

### [P1-17] 壁纸在 body 里每次重算都从磁盘加载解码
- **位置**: `Views/ThemeBackgroundView.swift:136-149`（`NSImage(contentsOf:)` / `UIImage(contentsOfFile:)` 无缓存 API，套在 GeometryReader 下，macOS 主窗口背景就是它）
- **维度**: D4
- **风险**: 拖拽窗口 resize 期间每个尺寸 tick 都磁盘重读 + 全图解码。iOS 聊天主路径已下沉 UIKit 并做了 `lastImageURL` 去重（PagingViewController:342-354），macOS 没有同等处理。
- **建议方向**: 解码结果按 url 缓存。

### [P1-18] 预设编辑每个键击触发全量 JSON 序列化写 UserDefaults
- **位置**: `Views/PersonaSettingsTab.swift:836-849,1163-1166`（TextEditor 直绑 `psm.save(p)`）；落点 `MemoryPalaceApp.swift:343-347`（`persist()` 整库 encode 写 UserDefaults，`presets` 数组整体替换触发全量重渲染）
- **维度**: D4
- **风险**: 预设库一大，macOS 端打字肉眼可见卡顿。iOS 端已有 300ms 防抖草稿（`:2049-2062`），说明作者意识到了，macOS 没平移。
- **建议方向**: macOS 端复用 iOS 的防抖模式。

### 错误处理

### [P1-19] `try?` 系统性吞错 + 四处"失败报成功"
- **位置**: 全项目 404 处 `try?`，其中 68 处吞 `context.save()`（重灾区：ConversationViewModel 全文、StickerViewModel 14 处、SidebarView ~20 处）。最危险的四处"假成功"：`Views/ExportOptionsSheet.swift:148-152`（`try? write` 后无条件 dismiss；iOS 分支写进 tmp 没接 ShareSheet，导出是黑洞）；`Views/StickerSettingsTab.swift:136-142`（`try? moveItem` 失败仍提示「导出成功！」）；`Views/AttachmentPreviewSheet.swift:192-198`（`UIImageWriteToSavedPhotosAlbum` 不传 completion，权限被拒也弹「已保存」）；`ViewModels/ConversationViewModel.swift:2115-2129`（`try? MemoryExtractor.executeActions` 失败后 UI 照样弹「🧠 记住 N 条」）
- **维度**: D5
- **风险**: 导出/备份/保存是数据出口，静默失败 + 谎报成功的组合意味着用户发现丢数据时已无法追溯。
- **建议方向**: 数据出口路径（导出/保存/备份/记忆写入）全部改 do-catch + 用户可见报错；其余 try? 至少在失败分支补 log（项目本有探针文化）。

### 安全

### [P1-20] MCP server 凭证（headers / OAuth Secret）明文存 UserDefaults
- **位置**: `Services/MCP/MCPProvider.swift:301-305`（整个 `[MCPServerConfig]` JSONEncoder 后写 UserDefaults）；`Services/MCP/MCPModels.swift:128-141`（`headers`、`oauthClientSecret` 参与 Codable）；输入侧 `Views/MCPSettingsView.swift:449`（OAuth Secret 用明文 TextField，对照 API key 都用 SecureField）
- **维度**: D8 / 安全
- **风险**: 远程 MCP 常用 `Authorization: Bearer xxx` 放 headers——与 API key 全走 Keychain 的标准不一致，等价凭证落明文 plist、进未加密备份。
- **建议方向**: headers 敏感值与 secret 按 `mcp-{serverId}` account 存 Keychain；输入框换 SecureField。

### 架构 / 卫生

### [P1-21] God Object 四件套
- **位置**: `ViewModels/ConversationViewModel.swift`（2558 行：树构建 + 分支导航 + 搜索 + 导出 + 聊天发送 + 工具循环 + 记忆提取 + 预算 + 草稿 + CC 路由）；`Views/CardFlowView.swift`（2946 行 / 单文件 17 个类型）；`Views/SidebarView.swift`（2676 行：搜索编排 + 分页 fetch + predicate 工厂 + 导出 + 标签 CRUD 全在 View 里）；`Views/PersonaSettingsTab.swift`（2446 行：5 种编辑模式 × 双平台 + 预览引擎，组装预览在 body 内同步 fetch 记忆/世界书/重建 200 条历史）
- **维度**: D1
- **风险**: 核心逻辑无法单测；任何改动都要读 3000 行上下文；regenerate/editAndResend 与 sendMessage 三份重复的流式收尾已经行为分叉（regenerate 不带工具、不提取记忆、不处理 segments——若是有意为之也没有注释说明）。
- **建议方向**: 优先拆 ConversationViewModel（树引擎 / 聊天回合 / 后台 agent 三块）和 CardFlowView（ChatInputBar、ModelPickerPopover、BubbleView 各自成文件）；SidebarView 的列表数据源抽成可测试的 store（可顺手消掉 P1-1）。

### [P1-22] 双平台整页复制 + 双 importer 结构性复制
- **位置**: `Views/AppearanceSettingsTab.swift`（macOS struct :6-332 与 iOS struct :337-614 成段逐字相同，含两份 17 个 @AppStorage 默认值和两份 reset 函数）；`Views/MemorySettingsTab.swift:249-337` vs `:653-741`（memoryRow 逐字相同）；`Views/RegexSettingsTab.swift:149-168` vs `:316-335`（save/delete 两份）；`Services/ConversationImporter.swift:307-453` ≈ `Services/ClaudeImporter.swift:376-561`（进度/完成/失败状态机 ~400 行复制，且已开始分叉：ChatGPT 侧 `ignoredConversations` 是死常量）
- **维度**: D6
- **风险**: 改一个默认值要改 4 处；改进度逻辑必漏一边。这是全项目体量最大的 DRY 债。
- **建议方向**: 设置页抽共享 section 组件；importer 抽共享状态机基座，只留 decode 差异。

### macOS 适配

### [P1-23] 贴纸画布常驻注册 ⌘C/⌘V/⌫/[/] 快捷键，非编辑态也吞键
- **位置**: `Views/StickerCanvasLayer.swift:122-178`（五个隐形 Button 的 keyboardShortcut，只要打开对话就参与窗口 key equivalent 链，未用 `stickerVM.isEditingStickers` 条件挂载；其中 ⌫、[、] 是**无修饰键**）
- **维度**: D7
- **风险**: ⌘C/⌘V 有抢走聊天文本复制/粘贴的风险；无修饰键在"有贴纸选中 + 焦点在输入框"时可能把按键吃成删贴纸/调图层。事件吞噬不依赖动作体的判空兜底。
- **建议方向**: 包 `if stickerVM.isEditingStickers` 条件挂载，并实测 ⌘C。

### 工程

### [P1-24] 没有任何单元测试 target
- **位置**: `project.yml`（仅 StickerProbeUITests 一个 iOS UI 探针 target）
- **维度**: D8
- **现状**: PromptAssembler、树遍历、衰减引擎、BudgetCalculator、MacroExpander、ContentCleaner 全是纯函数/纯逻辑，是教科书级的可测对象，但零测试。
- **风险**: 本报告里所有正确性问题（P0-1 的 upsert、P1-12 的 root 选择、分支冒泡）都只能靠人肉回归发现；重构 God Object（P1-21）没有安全网。
- **建议方向**: 先给纯逻辑层（Assembler/树/预算/清洗）补特征测试，再动重构。

---

## P2 — 有空再改

> 定义：代码风格、命名规范、小幅优化、开发体验改进。按维度分组，格式精简。

### D1 架构
- **CC Bridge 接线写在 View**：`Views/ContentView.swift:287-302` — connect + 回调赋值在 onAppear，读 UserDefaults+Keychain；app 级服务应在 App 层初始化。
- **DI 三风格混用**：`ContentView.swift:21,137,377,473`（`?? ThemeManager.shared` 回退 ×4）、`DashboardView.swift:7`（单例进 @State）— nil 回退会把"忘了注入"掩盖成"列表空了"。
- **View 直改 @Model 与 viewModel 路径并存**：`ContentView.swift:609,678-679` 直写 pin/favorite 字段 vs `BranchMapSheet.swift:114` 走 `viewModel.togglePin`；收藏 toggle 不触发 sidebar 刷新。
- **StickerViewModel 弹 AppKit/UIKit UI**：`ViewModels/StickerViewModel.swift:514-550` — NSSavePanel/UIActivityViewController + 遍历 presentedViewController 找 topVC。
- **WorldBookPanelView 在 View 里做导入解析**：`Views/WorldBookPanelView.swift:897-947`；"最近 lastOpenedAt = 当前对话"的启发式可能绑错。
- **数据修复放在设置 tab 的 onAppear**：`Views/PersonaSettingsTab.swift:249,259-262`（ensureFloorInstance）— 不打开该页就不修复。
- **macOS「朗读」「附件」tab 渲染的是整个 GeneralSettingsTab**：`Views/SettingsView.swift:203-208` — tab 语义失效。

### D2 SwiftData
- **CCSessionPickerSheet 无谓词全量 fetch Conversation（跨楼层）**：`Views/CCSessionPickerSheet.swift:198-199` — 应加 `!isDeleted && ccBridgeSessionName != nil` predicate。
- **加标签可插重复 FavoriteItem**：`Views/SidebarView.swift:411-419` — 无 (conversationId, tagId) 去重，数据持续脏化。
- **fetchConversationTitleMap 全量拉 Conversation 只为取标题**：`Views/SidebarView.swift:1095-1105` — 应 `propertiesToFetch` 或按 conversationId 收窄。
- **EmptyStateView 用 @Query 拉全部会话只判 isEmpty**：`Views/ContentView.swift:1142-1148` — `fetchLimit = 1` 即可。
- **findStickersNearMessage 踩 optional 字段 predicate 陷阱（且是死代码）**：`Services/SearchService.swift:523-534` — 与已知教训同型，建议删除。
- **MemoryStore update/delete 仅按 UUID 不带 profileId**：`Services/MemoryService.swift:48-68,100-110` — 动作来源是 LLM 输出，加 profileId 守卫零成本。
- **侧栏搜索每键击两次同步 SQLite 查询**：`Views/SidebarView.swift:668-671 → 1500,1507` — 无防抖，contains 谓词无索引。

### D3 并发
- **ChatService usage 字段跨线程**：`Services/ChatService.swift:401-407`（session 队列写 `accumulated*/gotUsage`，main 读 `finalUsage`）+ 共享 provider 单实例（`:769-771`，两处同 provider 并发流式会互相 cancel）。
- **CCBridgeProvider.cancel 不注销 reply handler**：`Services/ChatService.swift:1067-1072` — 取消后晚到的 CC 回复仍触发 onComplete 回填 UI；另注释仍写"60s"实为 600s（`:984,999`）。
- **模型拉取过期响应竞态**：`Views/APISettingsTab.swift:1038-1057` — 切 provider 后旧 Task 不取消、落地不校验 providerId。
- **MCPSSETransport 全部可变状态无同步**：`Services/MCP/MCPSSETransport.swift:8-12,97,116-128` — `endpointContinuation` 两线程同过 guard 可 double-resume crash。
- **MCPProvider 并发 connect 双 client**：`Services/MCP/MCPProvider.swift:139-156` — check-then-act 跨 await，前一个 transport 无人 close（连接泄漏，配合 `:157-162` catch 不调 transport.close）。
- **PHImageManager continuation 可挂起/双恢复**：`Views/PhotoStripPanel.swift:180-188` — `.opportunistic` 回调多次触发，degraded-only 时永不 resume。
- **asyncAfter 闭包跨 0.5s 持 @Model**：`Views/StickerGestureOverlay.swift:372-379` — 与自家 Profile Switch Race Defense 相悖。
- **滚动时序用不可取消的 asyncAfter 链**：`Views/CardFlowView.swift:163-171,334,348-353` — 快速切对话时旧 scrollTo 打到新对话；建议 `.task + Task.sleep`。
- **StickerStyleSheet 预览渲染无取消/无序号**：`Views/StickerStyleSheet.swift:209-235` — 慢渲染后到覆盖新选择。
- **WindowFullscreenObserver.updateNSView 同步写 @Binding**：`Views/ContentView.swift:999-1010` — "Modifying state during view update" 触发点（makeNSView 路径已 async，update 路径漏了）。

### D4 内存性能
- **Profile.coverImageData（PNG 原图）随 profiles 数组进 UserDefaults**：`MemoryPalaceApp.swift:29,237-240` — 每次 saveProfiles 全量重编码，UserDefaults 不适合存图。
- **图片 body 内反复全图解码**：`Views/CardFlowView.swift:1241,1257,1997,2005`、`Views/StickerView.swift:159-177`（画布贴纸加载全尺寸原 PNG 显示 120pt）— 应缩略图/降采样 + 缓存。
- **CIContext 每次渲染新建**：`Services/StickerBorderRenderer.swift:59`、`StickerFilterRenderer.swift:54`、`SubjectLifter.swift:69` — PagingViewController 已示范 sharedCIContext。
- **Theme token 每次访问全量重算 + UserDefaults 读**：`Utils/Theme.swift:9-24` + `Utils/ThemeManager.swift:317-330` — 可按 themeChangeID 缓存 resolved set；`ThemeManager.persistDefinitions` 在 slider 拖动期间每 tick 全量编码（`:50-67,348-351`），应 debounce。
- **repeatForever 装饰动画群常驻**：`Views/MemoryPanelView.swift:611-618`（每张卡呼吸）、`Views/GardenSceneView.swift:38-41,139-144`、`Views/GardenWidgetView.swift:206-211`、`Views/DashboardView.swift:62-64` — 有界无泄漏，但叠加是持续底噪。
- **DateFormatter 每 render 新建**：`Views/ImportHistoryView.swift:165-169`、`Views/CalendarPanelView.swift:284-296` — 同文件已有 static formatter 正确示范。
- **ContentView.body 每次重算跑全树 DFS**：`Views/ContentView.swift:760-762`（branchOffMainCount = collectAllBranches().count）— 应缓存到 viewModel。
- **BranchMapSheet 渲染路径重复快照 + 线性扫描**：`Views/BranchMapSheet.swift:24-26,151,265,297-305`。
- **triggerContextSummaryIfNeeded 每轮全量重建历史**：`ViewModels/ConversationViewModel.swift:2144`（`buildAPIMessages(maxMessages: Int.max)` 主线程）；preCheckBudget 同样全 path 拼接大字符串（`:2495-2498`）。
- **FileLibraryPanelView 主线程批量 IO + 5s/4s 轮询**：`Views/FileLibraryPanelView.swift:58-60,568-575,587-599,883-885`。
- **MemoryInjector 关键词匹配重复计算**：`Services/MemoryService.swift:224-237` — haystack 应循环外算一次。
- **MessageSegmentsView 用 indices 当 ForEach identity**：`Views/MessageSegmentsView.swift:113` — 流式中段插 segment 时展开状态错位，违反项目规则。

### D5 错误处理
- **推送跳转静默丢弃且不可重试**：`Views/ContentView.swift:457-464`（先删 pending key 再校验）+ 0.6s 魔数延迟赌时序（`:309`）。
- **container 创建失败 fatalError 死循环**：`MemoryPalaceApp.swift:157` — store 损坏 = 每次启动必崩，无恢复路径（备份/重建 + 提示更妥）；迁移失败仅 print（`:405`）。
- **FileLibraryStore legacy 迁移"全失败"也标记完成**：`Services/FileLibraryStore.swift:353-355`（`!failed || !copiedAny` 布尔条件把全失败放过）。
- **CC 终端链路 send completion 一律 `{ _ in }`**：`Services/CCBridgeWebSocketClient.swift:346-396`；`handleIncoming` 畸形帧静默丢弃无 log（`:457-460`）；spawn/list RPC 无超时，hub 不回包 spinner 永转（`:92-94,290-302`）。
- **预设导入全链路吞错**：`Views/PersonaSettingsTab.swift:301-322`（格式错的酒馆 JSON 点完无任何反馈）；JSON 模式 dirty buffer 切预设可串台覆盖（`:1252-1272`）。
- **导出 Markdown 写盘失败静默**：`Views/SidebarView.swift:731`。

### D6 代码卫生
- **死代码清单**：`Services/ChatService.swift:221-228,581-583`（supportsImageInput 两处零调用）；`Services/PromptAssembler.swift:221-261`（preview/resolveSlotContent——按"预览必须复用真实执行路径"教训应删）；`Views/MessageSegmentsView.swift:91-98,182-201`（ImageStripView 渲染恒 EmptyView）；`Views/PersonaSettingsTab.swift:1516-1530,1933-1948,2336-2382`（三组件零调用）；`Services/DashboardManager.swift:34-41`（WidgetSize.next）；`Services/UnifiedContainerMigration.swift:20`（inProgressKey 只写不读）；`Views/SidebarView.swift:697-705`（#if 双分支逐字相同）、`Views/ContentView.swift:810`（空 onChange）；`Utils/DebugRenderSettings.swift`（注释自承"上架前删除"）。
- **token 估算三套口径**：`Models/Memory.swift:60-70`（CJK×2）vs `Utils/TokenEstimator.swift:11-24`（CJK×1）vs `Services/PromptPostProcessor.swift:29-56`（CJK×1.5）— 记忆预算与保险闸对同一段中文差 50%+；记忆衰减阈值 0.3/0.05 双源（`Services/MemoryService.swift:71,83` vs `:156-161`，同值不同语义）。
- **便签样式→颜色映射五处复制**：StickerView:109-135 / StickerLibraryView:338-353 / StickerKeyboardPanel:313-320 / NoteExportView:22-48 / NoteStickerEditor:28-35 — NoteStyle enum 已存在却只有一处用。
- **NoteStickerEditor 字体选择是死功能**：`Views/NoteStickerEditor.swift:48,86-104,166-173`（selectedFont 被丢弃，显示恒系统字体）。
- **PetManager「久别重逢」分支永不触发**：`Services/PetManager.swift:40-55,92-103`（applyDecay 先重置 lastSeen，hrs 恒 ≈0，6 句文案不可达）。
- **命名撒谎的遗留色别名**：`Utils/Theme.swift:70-77`（paleBlue/softBlue 实为薄荷绿，项目明令不要蓝色）+ `Views/PersonaSettingsTab.swift:1486-1493`（role 徽章直用 .blue，违反配色禁令）；`Theme.F` 与 `Theme.SettingsFont` 双名并用、多处裸字号。
- **拖拽物理双份实现已漂移**：`Views/StickerCanvasLayer.swift:228-261` vs `Views/StickerGestureOverlay.swift:249-293`（torqueFactor 15.0 vs 18.0）。
- **MemoryCardView.blend 名不符实**：`Views/MemoryPanelView.swift:646-650`（声称混色实为阶跃）。
- **贴纸缩略图 tilt 用 hashValue（每次启动随机）**：`Views/StickerLibraryView.swift:260-264` — GardenSceneView:103-104 已正确改 unicodeScalars 并注释，两处不一致。
- **时序赌博类魔数**：`MemoryPalaceApp.swift:696`（0.4s 后切楼层发通知）、`Views/SidebarView.swift:711-732`（0.3s 等 contextMenu 收起再 runModal）、`Views/ContentView.swift:309`（0.6s 推送延迟）— 项目已有同类教训。
- **Preset 酒馆 JSON 往返丢 regex_scripts**：`Models/Preset.swift:203-206`（导入读）vs `:212-261`（导出不写）— 原始模式看到的 JSON 缺数据，粘回即丢。
- **PricingCatalog 前缀/包含匹配遍历字典**：`Models/ModelPricing.swift:27-34` — 多 key 命中时取谁取决于字典迭代序（当前各组同价所以无害，模式脆弱）。
- **ImportView 的 10 个 current* switch 属性家族**：`Views/ImportView.swift:19-107` — 加第三个 provider 要改 10 处。

### D7 macOS 适配
- **设置不是 Settings scene**：`Views/SettingsView.swift:137-257`（sheet + 固定 480×560 + 18 个 tab 横向滚动；无 ⌘, 唤起）— 已到该升级成 NavigationSplitView 设置窗的规模。
- **核心操作无键盘快捷键**：全 app keyboardShortcut 仅 12 处（字号缩放 + 少量面板内）；无 ⌘N 新建对话、⌘F 聚焦搜索（Cmd+F 是 0×0 隐藏按钮 hack，`Views/CardFlowView.swift:427-440`）、⌘O 导入；CommandGroup 无对应菜单项。
- **macOS isAtBottom 用 LazyVStack 哨兵 onAppear**：`Views/CardFlowView.swift:244-247` — 预实例化导致提前误判"到底"，与 iOS 的 onScrollGeometryChange 行为不一致。
- **NSSavePanel.runModal 模态嵌模态**：`Views/ExportOptionsSheet.swift:142-147`、`Views/SidebarView.swift:715-732` — 建议 beginSheetModal / .fileExporter。
- **拖拽 payload 是裸 plain-text UUID**：`Views/StickerLibraryView.swift:301-303` 等 — 拖进任何文本接收方粘出 UUID 串；应自定义 UTType。
- **NSCursor push/pop 不平衡**：`Views/StickerCanvasLayer.swift:544-548,587-591` — hover 态下手柄消失光标滞留。
- **PinnedMessageBar 用 onTapGesture 而非 Button**：`Views/PinnedMessageBar.swift:58-59` — iOS 26 glass workaround 拖累 macOS 键盘/VoiceOver 可达性。
- **多窗口草稿互踩（潜在）**：`Views/CardFlowView.swift:39,478-480` — 双窗开同一对话后 flush 者赢。
- **窗口最小宽度 900 埋在全屏 observer 里**：`Views/ContentView.swift:1030-1031` — 应集中到 WindowConfigurator/App 层。

### D8 依赖与构建
- **硬编码本机绝对路径**：`Views/APISettingsTab.swift:546-549`（指向 `.claude/worktrees/...` 的 README，非本机必失败；有 TODO 标注）。
- **依赖版本用 `from:` 浮动**：`project.yml` — minor 自动升级有惊喜风险；MarkdownUI/ZIPFoundation/SwiftTerm/VariableBlur 四个依赖均有实际使用、无可削减项（正面确认）。
- **MCP 默认 transport 仍是 `.sse`**：`Services/MCP/MCPModels.swift:149` — SSE 实现有 P0-3 同款挂死模式 + 逐字节 for-await 吞吐慢，StreamableHTTP 更可靠；后者缺 `Mcp-Session-Id` 处理（`MCPStreamableHTTPTransport.swift:23-50`），有状态 server 会 400。
- **CC token 进 URL query + 允许 ws:// 明文**：`Services/CCBridgeWebSocketClient.swift:191-202` — 裸 LAN 可嗅探；Tailscale 隧道场景可接受，记录在案。
- **KeychainStore 未设 kSecAttrAccessible / kSecUseDataProtectionKeychain**：`Utils/KeychainStore.swift:22-30` — macOS file-based keychain 对 synchronizable 语义未定义，`sync: true` 可能静默不同步。
- **心跳用全量 tools/list 当 ping**：`Services/MCP/MCPProvider.swift:322-332` — 每 12s 一次，大目录 server 流量偏重且结果丢弃。

---

## 维度覆盖确认

| 维度 | 覆盖 | 发现数 | 最高级别 |
|------|------|--------|----------|
| D1 架构分层 | ✅ | 9 | P1 |
| D2 SwiftData | ✅ | 14 | **P0** |
| D3 并发安全 | ✅ | 14 | **P0** |
| D4 内存性能 | ✅ | 18 | P1 |
| D5 错误处理 | ✅ | 11 | **P0** |
| D6 代码卫生 | ✅ | 16 | P1 |
| D7 macOS 适配 | ✅ | 10 | P1 |
| D8 依赖构建 | ✅ | 8 | P1 |

（跨维度问题计入主维度，集群条目按"处"折算；P0 共 4 条，P1 共 24 条，P2 共 60+ 处。）

## 技术债热力图

**重灾区（高密度）**
| 文件 | 行数 | 主要债 |
|------|------|--------|
| `Views/CardFlowView.swift` | 2946 | God file（17 类型）、强解包、流式渲染热点、缓存键混乱、后台 race |
| `Views/SidebarView.swift` | 2676 | God View、标签分页坏死、每键击双查询、弥漫 try?、多处复制 |
| `ViewModels/ConversationViewModel.swift` | 2558 | God Object、三份流式收尾分叉、try? save 链 |
| `Views/PersonaSettingsTab.swift` | 2446 | God Object、每键击全量持久化、预览重活在 body、3 处死代码 |
| `Services/UnifiedContainerMigration.swift` | 407 | open-fail 置 done、sidecar 改名 bug（磁盘实证）、全量 fetch、死状态键 |
| `Services/MCP/MCPClient.swift` + `MCPSSETransport.swift` | ~400 | 超时挂死 ×2（P0-3）、状态无同步 |
| `Views/StickerLibraryView.swift` | ~400 | rename 空实现、stale cache 链路终端、随机 hashValue |

**中等密度**：ChatService、ContentView、ConversationImporter/ClaudeImporter（复制体）、SearchService、MemoryService、StickerViewModel、ImportView/ImportHistoryView、AppearanceSettingsTab/MemorySettingsTab/RegexSettingsTab/GeneralSettingsTab（双平台复制）、ThemeManager、ThemeBackgroundView、WorldBookPanelView、FileLibraryPanelView、MCPProvider、CCBridgeWebSocketClient、MarkdownExporter、ExportOptionsSheet/AttachmentPreviewSheet、StickerFileManager、PromptPostProcessor。

**低密度（干净）**：Models 层全部（Conversation/Memory/WorldBook 等 12 个 @Model 设计清晰）、Utils 大部分（BudgetCalculator/TokenEstimator/ContentCleaner/KeychainStore/MarkdownTheme）、FlowLayout、IOSPromptTextView、ScrollToBottomButton、ImportSupport（快照机制完整）、FileLibraryStore（路径穿越防护是全仓库最扎实的安全代码）、小组件群（Pet/Todo/Garden/Dashboard）、Web 三件套、CC 面板群、MacroExpander、TavernCardParser。

**质量标杆**（值得在重构时当作范本）：`Views/Paging/PagingViewController.swift`（证据注释 + 去重守卫 + sharedCIContext）、`Views/CCTerminalPanelView.swift`、`Services/CCBridgeWebSocketClient.swift` 的补丁注释文化、`Services/FileLibraryStore.swift` 的防御式路径校验 + DEBUG 自检。

---

## 建议的修复顺序（非要求，按数据安全 → 崩溃 → 体验排）

1. **P0-1 / P0-2**（一次改动顺手修：导入跨楼层查重 + 角色卡 profileId + 存量清理）
2. **P0-3**（MCPClient + MCPSSETransport 两处同款模式同修）
3. **P0-4**（解绑改真解绑）
4. P1-2（迁移 sidecar/doneKey，趁备份还新鲜）、P1-11（一行 guard）、P1-15（四个死功能，改动都极小）
5. P1-16 + P1-13（流式热点与缓存键，一起动 BubbleView 渲染路径）
6. P1-24（给纯逻辑层补测试）→ 之后才动 P1-21/P1-22 的大拆分
