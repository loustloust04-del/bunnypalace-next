# Mac CC 刷新与滚动位置 · 2026-09-24

## 范围

只处理 macOS 的 CC 阅读行为。此前 Dock 与工作区提交 `ee704acf` 已推送到 origin/master。没有移植 ZCode 代码；采用其“数据变化不等于用户导航意图”的设计原则，参考 [固定提交的滚动裁决](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/v4/timelineScrollAnchor.ts#L48-L89)。

## 已确认的两条路径

1. Code 详情：文件监听 → `applyIncremental` → `reloadDetail` → `loadDetail` 曾无条件设 `.loading`。`CodingSessionDetailView` 的 switch 随即移除 loaded 分支中的 ScrollView，解析完成后重新创建；相同 session key 不能抵消分支销毁。
2. 普通对话 CC bridge：`ConversationViewModel.applyCCEdit` 在最终正文更新时无条件写 `scrollToNodeId`，CardFlowView 会把它当作导航命令，而非单纯内容刷新。

## 修改

- 同一会话有已加载内容时，后台重读期间保持 loaded 分支；成功原位替换并递增 revision，失败保留旧内容、显示重试信息。换会话仍走首次加载，旧请求仍受 generation 和 selectedKey 双重守卫。
- mac Code 阅读容器独立维护滚动意图。上翻阅读时刷新不主动跳转；用户到达底部后才跟随新内容。布局与程序化移动不改变意图，交互过程中暂停自动跟随。初次打开仍保留原来的顶部起点。
- 搜索定位主动退出跟随，取消的搜索定位任务不再晚到跳转。
- 普通对话 CC 到达与最终正文更新，在 mac 使用独立尾部跟随信号，反转列表以 `.top` 对齐最新边沿，不再把长回复居中。只有在底部、更新目标为尾消息且没有待处理的显式导航时才跟随；旧回复编辑与流式中间帧不触发导航。

## iOS 边界

`CodingSessionLibrary`、`CodingSessionDetailView`、新增 `MacCodingTranscriptScroll` 全文件受 `#if os(macOS)` 隔离。共享 `ConversationViewModel` 和 `CardFlowView` 的新增逻辑只在 mac 分支内。将新增条件折叠为 iOS 分支后，两个文件均与基线源码逐字节一致；没有修改 iOS 的反转列表、UIKit 补偿、键盘或滚动跟随代码。

## 验证

- 修复前窗口复现：`mac1` 会话向下阅读一页后，重新选择同一会话，详情滚动值从 `0.005918491645261235` 回到 `0`。
- 第一轮 16 项回归通过：同会话加载保持、失败保留、迟到结果隔离、滚动意图，以及既有删除/侧链用例。
- 18 项集成回归通过（`build/mac-cc-refresh-0924-final-tests.xcresult`），含 JSONL 新回复追加、普通 CC bridge 历史阅读保护、旧回复编辑不跳转及显式搜索优先。
- 最终 21 项 CC / Library 回归通过（`build/mac-cc-scroll-final-0924.xcresult`），包含既有 CC 入场逻辑；mac 构建通过。没有重跑 iOS 交互测试，本次以条件编译与共享文件分支等价检查守住其边界。
- 修复后同一 mac1 会话下翻并重读：滚动值 `0.006718470533419506 → 0.006528978733348913`，没有回到 0。比值仍有小幅变化，不据此声称逐像素完全不动。
- 主动滚到底部后重读：`1 → 1`。运行日志分别记录 `retain=true / follow=false` 和 `retain=true / follow=true`；这两次重读之间没有 scroll unmount/mount。
- 页面验收为手动重读真实会话；新回复追加通过临时 JSONL 回归模拟，普通 CC bridge 使用内存数据库验证。未向实际 CC 服务发送测试消息。
- DEBUG 探针：`coding.detail.load` 的 retain 标志；`coding.scroll.mount/unmount` 的视图生命周期；`coding.scroll.refresh` 的跟随决定。它们区分数据刷新与视图重建，不记录消息正文。

## 后续：加载慢与同步阻塞（同日继续）

滚动位置测试不代表同步及时。粟粟继续反馈后，5 秒运行采样 `/tmp/mac-sync-0924-sample.txt` 抓到：主线程 1546 个样本中 664 个处于 `CCBridgeWebSocketClient.handleIncoming → applyCCThinking → SwiftData.fetch → SQLite`。因此至少这批 CC 消息已经收到，主线程在数据库查询上阻塞。不是仅凭源码推断网络断连。

正式 `unified.store` 只读核实：消息表、对话表仍然只有 id 唯一索引，按 conversationId 查询为 `SCAN ZMESSAGENODE`。这正是 09-19 留下的旧库回补项；仅修改模型 #Index 没有修复既有库。

新增 mac 启动前索引回补：仅增建 3 个非唯一查询索引，不修改行、表结构或 Core Data 迁移元数据；核对已知列和现存索引前缀，已有覆盖则跳过；整个 DDL 事务失败回滚，未知结构跳过并记录错误。此方案依赖当前 Core Data SQLite 列名，未来结构变化时会拒绝回补，需要重新审查；不是通用 SwiftData 迁移框架。iOS 不运行此逻辑。

- 先用 SQLite backup API 留下一致性快照 `build/performance-mac/unified-sync-before.sqlite`（0600；数据库备份，不是外部附件完整导出），再在独立副本运行同一 Swift 修复实现。
- 副本一次补建约 6.0 秒，第二次补建 0 个索引。消息数 251731 不变、quick_check=ok；查询返回的 153 个主键逐一相同。
- 同一查询：副本修复前 363.09ms，修复后 2.43ms；正式库启动回补后 0.67ms，执行计划为 `SEARCH ... USING COVERING INDEX mp_node_conversation_v1`。这是查询测量，不能当作端到端同步耗时。
- 回补后的另一次 5 秒采样主线程处于事件等待，没有抓到同类查询阻塞；该窗口没有保证相同 CC 入站负载，不据此报告整体加速倍数。
- Code 库在扫描前启动 FSEvents，避免整个首次扫描期间没有监听；手动刷新索引结束后也重读已选详情。

最终同步回归：`build/mac-sync-verified-0924.xcresult`，31 项全部通过。覆盖索引回补/重复启动/未知结构不写入、真实 FSEvents、文件追加到当前详情、CC 滚动保护。临时 CC 文件追加并关闭写入后，自动更新到当前详情用时 0.846 秒；没有调用手动刷新。最初保持写入句柄未关闭的测试在 6 秒内没有收到更新，当前 FSEvents 链路不保证这种写入模式下逐帧同步；没有修改其 800ms 合批和 3 秒重复解析节流。尚未测量用户实际终端发出回复至 UI 的端到端延迟。

共享文件 `MemoryPalaceApp`、`ConversationViewModel`、`CardFlowView` 删除新增 mac 条件分支后与基线逐字节一致；iOS 活动源码保持不变。

最终构建已重启（PID 50312）。最后一次窗口验收被 macOS 锁屏阻止，未绕过锁屏；先前滚动窗口验收有效，但不把它冒充最终同步版的交互验收。
