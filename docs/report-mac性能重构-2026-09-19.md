# mac 性能根因与重构结果

工作区：`.worktrees/mac-mint-appearance`；基线：`1d001174`。按粟粟要求实测定位，现已收尾，不再扩大重构范围。

**剩余项：现有旧库索引没有自动回补，正式旧库仍为全表扫描。新库模型索引与测试已补齐；旧库迁移未做。副本基准不代表真实旧库已提速。**

> 09-24 后续：旧库索引已通过 mac 启动前回补，正式库执行计划已验证。详见 [后续记录](report-mac-cc刷新滚动-2026-09-24.md)。以下保留 09-19 当时的结论。

## 找到的根因

### 1. 窗口焦点更新风暴

上一轮在 ContentView 每次 body 中创建携带闭包的 MacWorkspaceActions，再作为 focusedSceneValue 上送 App。身份持续变化，牵动窗口焦点、偏好与整棵视图图谱。

35 秒 Time Profiler 基线：主线程 CPU 采样 **22,101ms**，**37 次 ≥250ms hang**，最长 **1,259.6ms**。hang 样本中，`AppWindowsController.updateAppFocus` 含 **3,315ms**、`updateWindowFocus` 含 **3,287ms**（包含耗时，不可相加）。

仅稳定命令对象的对照版本：35 秒主线程采样 **479ms**、**0 次 hang**，AX 窗口读取也恢复。两轮人工操作量未严格对齐，不能将比值当作“输入快了 46 倍”。

最终实现是窗口拥有一个稳定的 `@Observable` 命令/呈现状态对象，菜单调用对象，不再每次捕获整张 ContentView 的临时闭包。

### 2. mac 数据库缺失复合索引

真实库 **657,862,656 字节 / 251,731 条 MessageNode**。消息表与对话表原来只有 id 唯一索引；`profileId + conversationId` 查询计划为 `SCAN ZMESSAGENODE`。

原因可追到 `f1a3466c`：当年为兼容 macOS 14，把 #Index 包在 os(iOS) 中。项目现在最低 macOS 15，这个旧限制仍留着。

先通过 SQLite backup API 留下一致性快照，再在独立副本上做同结果查询对照：

| 查询 | 未加索引 | 加复合索引 |
|---|---:|---:|
| 返回节点数 | 206 | 206 |
| 首轮 | 5,502ms | 3.60ms |
| 后续四轮 | 421 / 496 / 573 / 446ms | 2.05 / 2.50 / 2.17 / 3.22ms |
| 执行计划 | SCAN | SEARCH USING INDEX |

副本 `quick_check = ok`。通过 SwiftData 模型声明在 mac 新库启用 Conversation 和 MessageNode 的既有索引，新建磁盘库 EXPLAIN 检查通过。最终应用启动后，再用 lsof 确认其实际打开的正是原 unified.store，并两次只读核对：原库仍只有 id 唯一索引、查询计划仍为 SCAN。说明仅增加模型 #Index 声明不足以回补这份旧库。

按粟粟“差不多就收手”的要求，**旧库迁移留作后续项**，没有继续引入迁移框架或直接用 SQL 改正式库表，也没有限制历史条数。

快照：`build/performance-mac/unified-before-index.sqlite`（0600，只是 SQLite 一致性快照，不替代完整资料库导出）。基准：`build/performance-mac/index-benchmark.json`。

### 3. 输入与字体资源的生命周期不对

- mac 草稿原由 CardFlowView 持有，打字会触发消息页状态更新，加载分支还会移除输入框。现在 MacChatComposerHost 与消息区并列，MacComposerDraft 独占草稿归属；切换会话才更换编辑器身份，拒绝旧编辑器晚到的回调。逐键保存、退出/失活保存契约保留。
- 基线 `MarkdownRenderConfig.findVariant` 占 hang 样本 **1,400ms**。字体变体解析现由 MacMarkdownFontResolver 按字体名、字号、weight 有界复用；注册/导入/删除字体时失效，颜色和批注不被缓存冻结。
- 100 次同配置解析基准：未缓存约 **16–33ms**，缓存命中约 **0.05–0.085ms**。这是字体路径数据，不是整个应用加速倍数。
- 整块绿色选框来自列表容器默认焦点效果；关闭该效果，保留键盘焦点和行选中提示。

## 实际交互与验证边界

- 结构重构版 55 秒操作：连续 ASCII 输入、多行中英文文本设置、侧栏滚动、全局搜索和打开结果。主线程采样 2,296ms，5 次 hang，最长 571.8ms；测试文本已清空，未发送消息。
- 结构重构版 45 秒长对话：加载同一历史会话、向历史滚动三屏，内容与滚动位置均变化。主线程采样 2,666ms，3 次 hang，最长 597.1ms。
- 剩余热点指向 applyTreeData 的数据库读取。曾试验 propertiesToFetch 元数据预取，但采样 **439→444ms**，没有改善，**已撤回**；进一步查询执行计划才确认缺索引。
- 中文输入法候选组字尚未实测，不能用文本设置/粘贴成功替代。未声称所有首次操作均低于 250ms。
- 当前证据不要求整窗重写成 AppKit；已有 AppKit 文本底座沿用，重构集中在状态、资源与数据库索引边界。

## 构建与回归

- mac 构建、启动与最终 **43 项回归通过**；覆盖草稿归属、临时/删除态、楼层隔离、过期编辑回调、200 节点完整历史、字体缓存/失效与原有面板/搜索/发送契约。
- iOS 编译通过。最终索引声明改动的 iOS 生效代码与基线一致。
- 新增空白磁盘库 EXPLAIN QUERY PLAN 检查已通过，验证 mac 新库确实建立并使用复合索引；正式旧库回补尚未生效。最终结果：`build/mac-performance-index-tests.xcresult`、`/tmp/mac-mint-index-tests.log`。

原始 trace 留在本机 `/tmp/mac-mint-before.trace`、`/tmp/mac-mint-focus-after.trace`、`/tmp/mac-mint-final.trace`、`/tmp/mac-mint-long-scroll.trace`；可读摘要在 `build/performance-mac/`。未操作 Typora。

最终旧库只读检查：`build/performance-mac/live-index-verification.json`。本轮没有继续进行数据库迁移；最终构建已启动，工作区变更将原子提交，未合并主线。
