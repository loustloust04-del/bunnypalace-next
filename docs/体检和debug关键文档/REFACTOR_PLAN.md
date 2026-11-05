# 重构路线图: 记忆宫殿

生成日期: 2026-06-10
基于审查: `docs/体检/CODE_REVIEW.md`（2026-06-10）
有效 issue 数: 28 + P2 约 60 处（P0: 4，P1: 24，P2: 按组处理不逐条计）

> 验证结论：审查基线（efae35a）至今源码零改动（期间仅 docs 提交），4 P0 + 24 P1 已逐条按行号复验有效，无失效条目。
> 协调约束：`docs/plan-assembly-message-stream.md`（待批注）将改 PromptAssembler / PromptPostProcessor / 各 provider 的 buildRequestBody——本路线图凡触及组装链的条目都已避开或标注，落地前后请对照。

## 全局策略

先用**三个互相独立的小批次把 4 个 P0 和"点了没反应/失败报成功"这类用户直接撞上的问题清零**（B1-B4，全部不动 schema、不做结构重构，每批都能独立 revert）；然后**搭测试基建**（B5）——它是后面所有结构性改动（导入器重构、schema 演进、God Object 拆分）的前置安全网，放在大改之前而不是"以后再说"。中段（B6-B10）按"同文件聚合"原则逐个收拾核心链路的性能与正确性债。**最大的风险集中在两处**：导入器整修（B7，跨 await 的 ModelContext 改 @ModelActor，行为敏感）和 schema 演进基线（B11，SwiftData store 一旦升级旧版打不开）——这两批都强制"改动前手动备份 unified.store"并排在测试就位之后。God Object 拆分（B12）不设截止日，作为滚动习惯执行。

## 依赖关系摘要

```
        ┌── B1 数据止血(P0-1/2/4) ──┐
独立可先 ├── B2 MCP 可靠性(P0-3)     ├──→ M1: P0 清零
        ├── B3 崩溃与死功能快修      │
        └── B4 数据出口错误可见性 ───┘
                    │
              B5 测试基建 ────┬──→ B7 导入与迁移整修（另需 B1 先行：同文件先修对再重构）
                              ├──→ B11 Schema 演进基线（P1-3 → P1-4 / P0-1 根治的硬前置）
                              └──→ B12 架构拆分（滚动）
        B3 ──→ B6 流式渲染与缓存（CardFlowView/MarkdownExporter 同文件，串行避免交叉）
        B6 / B8 共触 CardFlowView 与贴纸文件 → 顺序执行不交叉
```

瓶颈节点：**B5（测试基建）**——它不阻塞 M1，但阻塞所有结构性重构；**P1-3（VersionedSchema 基线）**——任何未来 schema 级变更（含 P0-1 根治、#Index 上 macOS）的硬前置。

高风险节点（🔴）：B7（importer 并发模型重写）、B11（schema 升级不可逆）、P0-1 根治（改主键 = 全库数据迁移，已降级为 B11 内的评估项）。

---

## 路线图

### Batch 1: 数据层止血（P0 三连）✅ 已实施（2026-06-11，commits 873ab9c/1c6eeee/83c1488；复盘 docs/review-p0-fixes.md；build ✅ 手测清单待跑；孤儿数据处置策略待粟粟看 dry-run 输出后定）
- **目标**: 关闭三个数据丢失/不可见入口——跨楼层 upsert、角色卡黑洞、解绑即删书。
- **前置**: 无
- **风险等级**: 🔴（碰导入写路径，但方案刻意选"只加检查、不改写入语义、不动 schema"）
- **包含 issue**:
  - P0-1: 跨楼层 unique upsert 偷对话 — 短期方案（全库查重 + 冲突跳过），不改 schema；根治（复合主键）移到 B11 评估
  - P0-2: 角色卡问候对话 profileId="" — 与 P0-1 同属"导入写入路径"，一起修一起验
  - P0-4: 「解绑」世界书 = 永久删除 — 独立小改，搭车本批一次清完 P0
- **共触文件**: `ConversationImporter.swift`, `ClaudeImporter.swift`, `UnifiedContainerMigration.swift`, `MemoryPalaceApp.swift`, `GeneralSettingsTab.swift`
- **修复思路概要**:
  - P0-1: 两个 importer 在写入前对 incoming 的 Conversation id 和 MessageNode id 做**全库**冲突检查（用 `#Predicate { ids.contains($0.id) }` 分批 IN 查询，不全量 fetch）；命中"同 id 但 profileId ≠ 当前楼层"→ 整条对话跳过并计入"与其他楼层冲突 N 条"提示。迁移路径（UnifiedContainerMigration）插入前做同款检查。merge 模式插入新节点同样过检查。
  - P0-2: `importCardContent` 的 Conversation/MessageNode 构造补传 `profile.id`；App 启动加一次性清理（UserDefaults key 守卫）：fetch `profileId == ""` 的 Conversation/MessageNode，DEBUG 先打印数量与标题再归入"当前楼层"或删除——**清理动作执行前先在控制台输出 dry-run 清单**，由粟粟确认归属策略（归位 or 删除）后再放行。
  - P0-4: `unbindWorldBook` 只改 `profile.linkedWorldBookIDs`，不再 `delete(book)`；真删除入口留在世界书面板且带确认弹窗（参照 ThemeSettingsTab:153-170 的现成模式）。
- **验证清单**:
  - [ ] `xcodegen generate && xcodebuild -scheme MemoryPalace build` 通过
  - [ ] 楼层 A 导入一份 ChatGPT 导出（≥2 个对话）→ 对话全部出现、可打开
  - [ ] 切到楼层 B 导入**同一份**导出 → 出现"N 条与其他楼层冲突，已跳过"类提示；楼层 B 列表不出现这些对话
  - [ ] 切回楼层 A → 原对话仍在、消息完整（这是 P0-1 的核心回归点）
  - [ ] Claude 导出重复同样四步
  - [ ] 新建楼层导入带 first_mes + alternate_greetings 的角色卡 → 开场白对话出现在新楼层对话列表，条数 = 1 + alternate 数
  - [ ] 重启 app → 控制台输出存量 profileId=="" 孤儿统计；处理后再重启 → 清理不再执行（幂等）
  - [ ] 设置→通用 点世界书旁 ✕ → 该书从绑定列表消失；打开世界书面板 → 书还在、entries 完整、可重新绑定
- **rollback**: git revert 够（无 schema 变更）。唯一例外是一次性清理：执行前控制台 dry-run + 建议先 `cp ~/Library/Application\ Support/MemoryPalace/unified.store* /tmp/` 留底，清理出错可整库还原。
- **预估范围**: ~5 文件, ~200-300 行

### Batch 2: MCP 可靠性与凭证安全 ✅ 已实施（P0-3：2026-06-11 commit 60bf8f5；P1-20 余项：2026-06-13 commit a7ec52ac 凭证入 Keychain + SecureField。残余暴露面见 复查-2026-07-08.md：MCPJSONEditorSheet 经 prettyJSON 仍明文展示 secret）
- **目标**: 修复超时机制本身（聊天回合永久挂死的根因），凭证撤出明文 plist。
- **前置**: 无（与 B1 互相独立，可任意先后）
- **风险等级**: 🟡（行为变化：原来"永挂"的场景将开始正常报错；现有 MCP server 配置需无感迁移）
- **包含 issue**:
  - P0-3: MCP 超时挂死 ×2（MCPClient.sendRequest + MCPSSETransport.connect，同款模式同修）
  - P1-20: MCP headers/oauthClientSecret 明文 UserDefaults — 同在 MCP 文件群，一次理解成本
  - 顺带 P2（同文件低成本）: MCPProvider 并发 connect 双 client（加 `.connecting` 挡板）、connect 失败不 close transport、OAuth Secret 输入框换 SecureField
- **共触文件**: `MCPClient.swift`, `MCPSSETransport.swift`, `MCPProvider.swift`, `MCPModels.swift`, `MCPSettingsView.swift`
- **修复思路概要**:
  - P0-3: 超时分支主动 `pending.removeValue(forKey: id)?.resume(throwing: .requestTimeout)` 后再 throw（或改单 Task + `withTaskCancellationHandler` 模式）；SSE 的 endpointContinuation 同款——超时路径 resume-and-clear，并给 resume 加 once 守卫防 double-resume。
  - P1-20: `MCPServerConfig` 的 headers 敏感值与 oauthClientSecret 改存 Keychain（account 形如 `mcp-{serverId}`），Codable 编码时剔除；启动 load 时做一次性迁移（读到明文 → 写 Keychain → 从 UserDefaults 抹除）。
  - 暂不改默认 transport（.sse → .streamableHTTP 的切换牵涉现有 server 配置语义，列入暂缓区单独决策）。
- **验证清单**:
  - [ ] build 通过
  - [ ] 用 `nc -l 8765` 模拟"接受连接但永不回包"的 server，配成 MCP server 后发起带工具的对话 → 在 requestTimeout 时限内收到超时错误、`assistantTurnInFlight` 释放、**同一对话能继续发消息**（不再需要重启）
  - [ ] 正常 MCP server（如本机 streamableHTTP 测试 server）工具调用功能不退化：连接、tools 列表、调用、结果回灌
  - [ ] 添加一个带 `Authorization: Bearer xxx` header 的 server → `defaults read com.susu.MemoryPalace` 输出里 grep 不到该 token；钥匙串访问里能看到对应条目
  - [ ] 已有明文配置的升级路径：旧 plist 数据启动后自动入 Keychain，server 连接行为不变
  - [ ] 断开 server 进程 → 心跳在合理时间内把状态置为断开并触发重连（验证心跳不再挂死）
- **rollback**: git revert 够。Keychain 迁移是增量写（UserDefaults 抹除前先确认 Keychain 写成功），revert 后旧版本仍可读 Keychain 失败→报"未配置"，不丢数据（token 可重填）。
- **预估范围**: ~5 文件, ~200-300 行

### Batch 3: 崩溃与死功能快修 ✅ 已实施（2026-06-13，commits 10eb0e72/2e603999/589b452f/0a7da8e3；复盘 docs/review-R-B3.md；2026-07-08 复查逐条确认全修）
- **目标**: 一批互相独立的小改：消灭已知崩溃源和四个"按钮在、功能无"。
- **前置**: 无
- **风险等级**: 🟢（全部局部小改，每个 issue 一个 commit，独立可 revert）
- **包含 issue**:
  - P1-11: `profileManager!` 强解包 — 改 guard，一行级
  - P1-12: MarkdownExporter root 非确定性 + 递归爆栈 — root 选择改确定性算法（与 ViewModel 同款，抽公共静态函数）；`formatFullTree` 的 walk/depth 改迭代（同文件 longestPath 已有范本）。⚠️ cacheKey 部分**不在本批**（归 B6 统一）
  - P1-15: 四个死功能 — renameSticker 接画布侧现成实现；iOS exportPreset 接 UIActivityViewController（抄 StickerSettingsTab:319-327）；RegexScriptEditor 的 frame 包 `#if os(macOS)`；DataSettingsTab iOS 导出按钮 disabled+"即将支持"
  - P1-8: StickerViewModel 后台改 UI 状态 — importImages/importImageData/updateStyle 标 `@MainActor`，重活（抠图/渲染）下沉局部 Task.detached
  - P1-9: handleStickerDrop 后台 race — loadItem completion 第一行 hop 到 main 再读 viewModel/stickerVM 状态
- **共触文件**: `CardFlowView.swift`（仅 :90-115 与 :599-637 两个小函数）, `MarkdownExporter.swift`, `StickerLibraryView.swift`, `StickerViewModel.swift`, `PersonaSettingsTab.swift`（仅 exportPreset）, `RegexScriptEditor.swift`, `DataSettingsTab.swift`
- **验证清单**:
  - [ ] build 通过（macOS + iOS 两个 scheme 都过——本批一半是 iOS 修复）
  - [ ] macOS：对一条 assistant 消息点「重新生成」「编辑重发」正常工作（强解包改 guard 后行为不变）
  - [ ] 贴纸库右键「重命名」→ 弹输入框 → 改名生效并持久化（重启后仍是新名）
  - [ ] 同一对话导出"全部分支"模式，选一条 500+ 消息的长对话 → 不崩、输出完整；同一对话连续导出 3 次 → 内容逐字节一致（root 确定性）
  - [ ] 批量导入 10 张贴纸 → 进度文案正常刷新、无 runtime "Publishing changes from background threads" 紫色警告
  - [ ] 从贴纸库拖一张贴纸进对话 → 正常落位（race 修复后行为不变）
  - [ ] iOS（如有真机/模拟器顺手）：预设导出弹分享面板；正则编辑器 sheet 不再溢出
- **rollback**: git revert 单个 commit 即可，互不依赖。
- **预估范围**: ~7 文件, ~150-250 行

### Batch 4: 数据出口的错误可见性 ✅ 已实施（2026-06-13，commits f77b0e2d/41e5a1f7/4fe63a09/3f571c42；复盘 docs/review-R-B4.md；2026-07-08 复查逐条确认全修。注意：全项目 try? 总量 404→939 未收敛）
- **目标**: 消灭"失败报成功"——导出/保存/备份这些数据出口，失败必须用户可见。
- **前置**: 无
- **风险等级**: 🟢
- **包含 issue**:
  - P1-19: 四处假成功 + 导出静默失败（ExportOptionsSheet 写盘失败照样 dismiss / iOS 导出黑洞接 ShareSheet 或禁用 / StickerSettingsTab moveItem 失败报成功 / AttachmentPreviewSheet 相册假成功补 completion / SidebarView:731 导出写盘 / 记忆胶囊改为 executeActions 成功后再弹）
  - 顺带 P2（同主题）: DataSettingsTab 批量导出加失败计数；ImportView 入口三连吞错的**提示部分**（弹 alert；importer 内部回滚机制归 B7）
- **共触文件**: `ExportOptionsSheet.swift`, `StickerSettingsTab.swift`, `AttachmentPreviewSheet.swift`, `SidebarView.swift`（:731 一处）, `ConversationViewModel.swift`（记忆胶囊时序）, `DataSettingsTab.swift`, `ImportView.swift`
- **修复思路概要**: 不引入新框架——复用项目现成的两条反馈通道（`transientNotice` 胶囊 / 各页已有的 alert state）。每个出口的 `try?` 改 do-catch，catch 分支给用户可见报错 + 一条 log。相册保存改传 completion selector 或 PHPhotoLibrary.performChanges。
- **验证清单**:
  - [ ] build 通过
  - [ ] 导出对话到一个只读目录（`chmod 555` 的文件夹）→ 出现错误提示而不是静默 dismiss
  - [ ] 正常导出 → 成功路径行为不变，文件落地
  - [ ] 贴纸包导出到已存在同名文件的位置 → 报错或正确覆盖（不再"导出成功！"但文件没动）
  - [ ] 断网/拒绝相册权限后「保存到相册」→ 不再弹「已保存」
  - [ ] 发一条消息触发记忆提取，模拟 executeActions 失败（临时断点/改造测试）→ 不弹「记住 N 条」
- **rollback**: git revert 够。
- **预估范围**: ~7 文件, ~150-250 行

### Batch 5: 测试基建 ✅ 已实施（2026-06-13 开张 commit fa9166f9，持续追加中；现 MemoryPalaceTests 33 个测试文件。B7/B11 的前置已解除）
- **目标**: 建 unit test target + 给纯逻辑层补特征测试，为 B7/B11/B12 提供安全网。
- **前置**: 建议在 B1 后（顺手给"全库查重"写第一批回归测试）
- **风险等级**: 🟢（纯新增，不碰生产代码；唯一改动是 project.yml）
- **包含 issue**: P1-24
- **共触文件**: `project.yml`（新增 MemoryPalaceTests target）+ 新建 `MemoryPalaceTests/` 目录
- **修复思路概要**:
  - project.yml 加 macOS unit-testing bundle target，依赖主 target。
  - 第一批测试对象（纯函数/纯逻辑，无 UI）：树算法（`computeMainPathSet`/buildTree 的等价静态逻辑——确定性 root、分支冒泡）、`MarkdownExporter`（root 确定性 + B3 修复的回归）、`ContentCleaner`（PUA 清洗 + 缓存键行为）、`MacroExpander`、`BudgetCalculator`/`TokenEstimator`、`MemoryService.DecayEngine`（衰减分层）、B1 的导入查重逻辑（需把查重抽成可注入 context 的纯函数）。
  - ⚠️ PromptAssembler 暂不深测——`plan-assembly-message-stream.md` 待批注，落地会改 assemble 行为；先只给 `assembleTagged` 的槽排序写 2-3 个粗粒度特征测试，plan 落地时同步更新。
  - SwiftData 相关测试用内存 container（`isStoredInMemoryOnly: true`）。
- **验证清单**:
  - [ ] `xcodebuild -scheme MemoryPalace build` 不受影响
  - [ ] `xcodebuild test -scheme MemoryPalaceTests`（或合入主 scheme 的 test action）全绿
  - [ ] 故意改坏 MarkdownExporter root 选择 → 测试能红（安全网真的能拦）
- **rollback**: 删 target 即可，零生产影响。
- **预估范围**: project.yml ~30 行 + 新增测试代码量**需要进一步调研**（首批目标 ~15-25 个用例；fixture 设计——尤其树结构样本——是主要工作量）
- **SwiftData 标注**: 内存 container 测试不触发任何 store 迁移，无 schema 影响。

### Batch 6: 流式渲染与缓存正确性
- **目标**: 聊天主路径的 CPU 热点和"复制出旧文本"的缓存正确性 bug 一次收口。
- **前置**: B3（CardFlowView/MarkdownExporter 同文件已各修过一刀，串行避免交叉）
- **风险等级**: 🟡（滚动跟随行为是用户可见变化；缓存键统一涉及 7 个调用点）
- **包含 issue**:
  - P1-16: 流式渲染热点四件（segments 每 render 重复 decode → body 顶部取一次复用；extractThinking 正则 `static let`；流式 scrollTo 加 `isAtBottom` 条件；BubbleView 17 个 @AppStorage 下沉为传入的设置值结构）
  - P1-13: ContentCleaner 缓存键统一（裸 node.id / id_count / nil 三套 → 统一 `id + 内容版本`；NSCache 设 countLimit 治流式 O(n²) 膨胀；MarkdownExporter 的 nil cacheKey 一并改）
  - P1-17: ThemeBackgroundView 壁纸按 url 缓存解码结果（参照 PagingViewController 的 lastImageURL 去重模式）
- **共触文件**: `CardFlowView.swift`, `ChatBubbleStyle.swift`, `ContentCleaner.swift`, `MarkdownExporter.swift`, `PinnedMessageBar.swift`, `ThemeBackgroundView.swift`
- **验证清单**:
  - [ ] build 通过 + B5 的 ContentCleaner/MarkdownExporter 测试全绿
  - [ ] 流式长回复期间向上滚动 → **不再被拽回底部**；停在底部时 → 跟随正常
  - [ ] 流式进行中点「复制文本」→ 得到当前已生成内容；CC `edit_message` 改过的消息复制 → 得到编辑后文本（缓存正确性核心回归）
  - [ ] 一条带工具段的 CC 消息滚动经过 → 渲染正常（segments 单次取用不改显示）
  - [ ] 流式 1 万字长回复 → Xcode memory gauge 无异常爬升（NSCache countLimit 生效）
  - [ ] 拖拽窗口 resize（设了壁纸的主题）→ 不卡顿、CPU 无 IO 尖峰
  - [ ] 气泡外观设置改字号/间距 → 仍即时生效（@AppStorage 下沉后响应链不断）
- **rollback**: git revert 够。建议 P1-16 的四件各自独立 commit，滚动行为如有手感争议可单独退。
- **预估范围**: ~6 文件, ~250-400 行
- **备注**: 改完建议用 swiftui-expert 的 trace 工具录一条流式会话的 Instruments trace 对比前后（有现成技能支持）。

### Batch 7: 导入与迁移整修
- **目标**: 导入器从"碰巧没炸"升级到结构正确：并发模型、内存峰值、中断恢复、双份复制合一。
- **前置**: **B5（测试兜底）+ B1（同文件查重逻辑已稳定）**
- **风险等级**: 🔴（importer 并发模型重写 + 迁移代码改动；行为敏感、数据敏感）
- **包含 issue**:
  - P1-10: importer ModelContext 跨 await → `@ModelActor` 改造（结构重写的主轴）
  - P1-22（importer 部分）: 两 importer ~400 行状态机复制 → 抽共享基座，只留 decode/payload 差异（与 @ModelActor 改造同刀，先抽基座再改并发，分两个 commit）
  - P1-6: 中断恢复——失败分支写 record 计数 + supportsUndo（让部分导入可撤销）；ImportView 入口吞错改可见（B4 已做提示，这里补 security-scope/copy 失败的具体分支）；ImportHistoryView 撤回失败弹错并提示"可重试"（restore 已幂等）
  - P1-2: 迁移两缺口——open 失败不落 doneKey（按 profile 粒度记录已迁完的）；sidecar 改 `-wal/-shm` 命名；rename 前先释放 legacy container
  - P1-5: 内存峰值——迁移读侧设 `fetchBatchSize` 分批；importer 注释改实话（流式 decode 重写量大，列为本批的"调研后决定"项，不强行塞入）
- **共触文件**: `ConversationImporter.swift`, `ClaudeImporter.swift`, `ImportSupport.swift`, `UnifiedContainerMigration.swift`, `ImportView.swift`, `ImportHistoryView.swift`
- **验证清单**:
  - [ ] build 通过 + B5 导入相关测试全绿（基座抽取前后行为等价）
  - [ ] 完整导入一份真实 ChatGPT 导出（大文件）→ 条数/树结构与 B7 之前一致（可对比 nodeCount 总和）
  - [ ] Claude 导出同验
  - [ ] merge 模式重复导入 → added/updated/skipped 计数与改造前一致
  - [ ] 导入中途强杀 app → 重启后 ImportRecord 存在且可撤销（或可重导续传），不留不可操作的孤儿
  - [ ] 撤回一个 merge 导入 → 数据恢复；中途模拟失败 → 弹错且重跑撤回可完成
  - [ ] 迁移路径：构造一个 legacy store 测试副本跑 `needsMigration→runMigration` → 备份文件 `-wal/-shm` 随主库改名；故意放一个打不开的 legacy store → doneKey 不落、下次启动重试
  - [ ] Activity Monitor 观察大文件导入内存峰值较改造前下降（迁移读侧分批生效）
- **rollback**: git revert + 注意 doneKey 语义变更要向后兼容（新代码能识别旧的全局 doneKey）。**动迁移代码前手动 `cp unified.store* ` 留底。**
- **预估范围**: ~6 文件，重构性质 ~500-800 行净变动；流式 decode 部分**需要进一步调研**（ChatGPT 导出 JSON 顶层是数组，逐元素流式解析需要手写 JSONDecoder 之外的方案）
- **SwiftData 标注**: 不改 schema；@ModelActor 改造只动 context 的线程归属，store 格式无影响，lightweight migration 不涉及。

### Batch 8: 贴纸专项
- **目标**: 贴纸域剩余 P1（缓存失效、快捷键吞键）+ 同域 P2 顺手清。
- **前置**: B3（StickerViewModel 已修过 @MainActor，本批继续同文件）
- **风险等级**: 🟡（快捷键行为变化需实测）
- **包含 issue**:
  - P1-14: updateStyle 后缓存不失效 → saveStickerImage 后 evictCache（或 key 掺 mtime）
  - P1-23: 常驻快捷键吞 ⌘C/⌫/[/] → 包 `if stickerVM.isEditingStickers` 条件挂载
  - 顺带 P2: CIContext 三处共享单例（照搬 PagingViewController.sharedCIContext）、便签色映射五处收口到 NoteStyle、拖拽物理双份抽纯函数（torqueFactor 分叉值请粟粟拍板取哪个手感）、PetManager 久别重逢死分支、StickerStyleSheet 预览渲染加 generation token
- **共触文件**: `StickerViewModel.swift`, `StickerFileManager.swift`, `StickerCanvasLayer.swift`, `StickerGestureOverlay.swift`, `StickerView.swift`, `StickerBorderRenderer.swift`, `StickerFilterRenderer.swift`, `SubjectLifter.swift`, `Services/PetManager.swift`
- **验证清单**:
  - [ ] build 通过
  - [ ] 改一张贴纸的描边/滤镜 → 库缩略图和画布上的实例**立即**显示新样式（不再要重启）
  - [ ] 非贴纸编辑态：聊天里选中文本 ⌘C → 复制的是文本；输入框 ⌫ → 删字（不再被贴纸层吞）
  - [ ] 贴纸编辑态：选中贴纸 ⌫ 删除、[/] 调图层 → 功能保持
  - [ ] 批量导入 20 张贴纸 → 总耗时不高于改造前（CIContext 共享应更快）
  - [ ] 宠物 widget：把 `lastSeen` 手动改到 3 天前（改 UserDefaults）→ 出现"久别重逢"文案
- **rollback**: git revert 够；快捷键条件挂载如误伤编辑态，可单独退该 commit。
- **预估范围**: ~9 文件, ~200-300 行

### Batch 9: 侧栏与搜索
- **目标**: 修标签分页坏死、搜索 N+1、跨线程活模型——列表与搜索的功能 + 性能一起收。
- **前置**: 无硬前置（建议 B5 后，可给 fetchPage 抽出的数据源写测试）
- **风险等级**: 🟡（分页逻辑重写，回归面是整个侧栏列表）
- **包含 issue**:
  - P1-1: 标签 tab 分页坏死 → 标签桶按 convIds 收窄 predicate + 真分页（offset 生效）
  - P1-7: SearchService N+1（mainPath 计算用 propertiesToFetch 只拉 id/parentId/childrenIds）+ searchStickers 改返回值类型 struct
  - 顺带 P2: fetchConversationTitleMap 用 propertiesToFetch、FavoriteItem 插入去重、列表过滤加 300ms 防抖、EmptyStateView fetchLimit=1
- **共触文件**: `SidebarView.swift`, `SearchService.swift`, `ContentView.swift`（EmptyStateView 一处）
- **修复思路概要**: 顺手做半步 P1-21——把 fetchPage/normalPredicate/trashPredicate 这组数据源方法抽成独立的 store 类型（不强求完整拆 SidebarView，只下沉数据层，UI 不动），这是审查报告里"互为因果"的那对。
- **验证清单**:
  - [ ] build 通过
  - [ ] 给一个标签挂 120+ 个对话（脚本或手动）→ 标签 tab 滚到底 → 第 101 条之后能加载出来，footer 计数正确
  - [ ] 普通列表/收藏/回收站三个 tab 的滚动加载、计数、排序与改造前一致
  - [ ] 列表搜索框连续打字 → 不卡顿（防抖生效）；结果与逐字符即时过滤一致
  - [ ] 全局搜索一个高频词（命中多对话）→ 结果正确且明显快于改造前；主线/分支过滤标记正确
  - [ ] 搜索贴纸名/标签 → 结果正常显示不崩（值类型返回回归点）
- **rollback**: git revert 够。
- **预估范围**: ~3 文件, ~250-400 行
- **SwiftData 标注**: propertiesToFetch 是查询层特性，无 schema 影响。

### Batch 10: 设置页性能与一致性
- **目标**: macOS 预设编辑卡顿根治 + 设置域 P2 顺手清。
- **前置**: 无（⚠️ 与 PersonaSettingsTab 相关的 assembly plan 若已落地，先 rebase 理解再动）
- **风险等级**: 🟢
- **包含 issue**:
  - P1-18: 预设每键击全量持久化 → macOS 端平移 iOS 现成的 300ms 防抖草稿模式；PresetManager.persist 加 debounce
  - 顺带 P2: APISettingsTab 模型拉取过期响应竞态（落地校验 providerId）、SlotEditPage 按 slot.id 定位、JSON dirty buffer 切预设清空、SettingsView tts/attachment tab 错页、预设导入失败提示、role 徽章去蓝
- **共触文件**: `PersonaSettingsTab.swift`, `APISettingsTab.swift`, `SettingsView.swift`, `MemoryPalaceApp.swift`（PresetManager）
- **验证清单**:
  - [ ] build 通过
  - [ ] macOS 在一个大预设（10+ 插槽、长文本）的 TextEditor 里连续打字 → 无卡顿；切走再切回 → 内容已持久化（防抖不丢字）
  - [ ] 强杀 app（防抖窗口内）→ 重启后最多丢失防抖窗口内的输入（与 iOS 行为一致）
  - [ ] 快速来回切两个 provider 同时触发模型拉取 → 列表始终显示当前 provider 的模型
  - [ ] JSON 模式编辑后不应用、切换预设 → 弹确认或 buffer 重置，不再串台覆盖
  - [ ] macOS 设置点「朗读」「附件」tab → 显示各自内容（或暂时隐藏这两个 tab）
- **rollback**: git revert 够。
- **预估范围**: ~4 文件, ~200-300 行

### Batch 11: Schema 演进基线
- **目标**: 给 20 万节点的库一条版本化迁移路径；评估 P0-1 根治与 #Index 上 macOS。
- **前置**: **B5（测试）+ B7（迁移代码已稳定）**
- **风险等级**: 🔴（schema 批——store 一旦按新版打开，旧版本 app 无法回读）
- **包含 issue**:
  - P1-3: 引入 VersionedSchema——把当前 schema 固化为 SchemaV1 + 空 MigrationPlan，作为一切未来变更的基线
  - P1-4: #Index 对 macOS 15+ 开放（评估 `#if os(iOS) || os(macOS)` + availability 的可行写法；macOS 14 用户继续无索引）
  - P0-1 根治评估: id 改"profileId 复合"——**只做评估和决策文档，不在本批实施**。需要 custom MigrationStage 全量重写主键，收益 = 彻底消除 upsert 类风险；成本 = 20 万行重写 + 所有按 id 查询的语义复查。若 B1 短期方案运行稳定且多楼层导入需求不强，可长期搁置。
- **共触文件**: 全部 12 个 `Models/*.swift`、`MemoryPalaceApp.swift`（fullSchema → versioned）、可能新增 `Models/SchemaVersions.swift`
- **验证清单**:
  - [ ] **改动前手动备份**：`cp ~/Library/Application\ Support/MemoryPalace/unified.store* <备份目录>`
  - [ ] build 通过 + 全部测试绿
  - [ ] 用现有 unified.store 启动 → 数据完整（V1 基线 = 现 schema 快照，应零迁移直开）
  - [ ] 用 B7 验证用的 legacy 测试副本走完整迁移链 → 正常
  - [ ] #Index 部分：在 store **副本**上用 macOS 15 构建启动 → 打开成功（lightweight 建索引）、对话加载/搜索可感提速；用旧构建打开同一副本 → 确认是否仍可读（**这是决定 #Index 怎么发布的关键实测，结果写进决策文档**）
- **rollback**: **git revert 不够**——若 store 已被新 schema 打开过，必须用备份还原。所以本批所有实验先在 store 副本上做，真库升级放最后一步。
- **预估范围**: **需要进一步调研**（V1 基线本身 ~100-150 行；#Index 可用性 gating 写法需查证 SwiftData 是否支持 runtime availability 分支 schema——不支持则只能放弃或上调部署目标，这本身是一个待粟粟拍板的决策）
- **SwiftData 标注**: 本批就是 schema 批。V1 固化预期 lightweight 零迁移；#Index 添加预期 lightweight 兜得住（索引不改行数据）但**必须副本实测**；复合 id 属 heavyweight custom migration，单独立项。

### Batch 12: 架构拆分（滚动，无截止日）
- **目标**: God Object 四件套 + 双平台整页复制的渐进消解。
- **前置**: B5；各文件首刀建议结合该文件的下一个功能需求做
- **风险等级**: 🟡（每刀独立评估）
- **包含 issue**: P1-21（四个 God Object）、P1-22（设置页双平台复制部分）
- **修复思路概要**（按"下次碰这文件时做哪一刀"组织）:
  - `ConversationViewModel` 第一刀：把 regenerate/editAndResend 收敛进 runStreamingTurn 统一收尾（顺手消除"再生成无工具/无记忆提取"的行为分叉——分叉是否有意请粟粟先确认）；第二刀：树引擎（buildTree/rebuildPath/branch*）抽 `ConversationTreeEngine`；第三刀：记忆/预算/摘要的后台 agent 逻辑抽 service
  - `CardFlowView` 每刀：ChatInputBar → ModelPickerPopover → BubbleView 各自成文件（纯移动，零行为变化，每刀一个 commit）
  - `SidebarView`：B9 已下沉数据源，剩 UI 拆分按 tab 切
  - 设置页：抽共享 section 组件（AppearanceSettingsTab 先做样板：一份逻辑 + 平台外壳），验证模式后推广到 Memory/Regex/General
- **验证清单**（每刀通用）: build 通过 + 测试绿 + 该文件相关功能手动过一遍 + diff 审查确认"纯移动刀"零逻辑变化
- **rollback**: 每刀独立 commit，git revert 单刀。
- **预估范围**: 滚动进行，不估总量；单刀控制在一个 session 内

---

## 暂缓处理

| 条目 | 原因 |
|------|------|
| P0-1 根治（复合主键） | B1 短期方案已消除风险；heavyweight migration 成本与收益待 B11 评估后由粟粟决策 |
| MCP 默认 transport 切 .streamableHTTP | 牵涉现有 server 配置语义与兼容性，B2 修好 SSE 挂死后紧迫性下降；接新 server 时再决策 |
| MCPStreamableHTTP 缺 Mcp-Session-Id | 当前所用 server 无状态、实测能通；接有状态 server 前补 |
| RegexScript ReDoS 防护 | 绑"角色卡社区分发"产品里程碑——开放外来卡之前必须做，当前自用风险极低 |
| PromptAssembler.preview 死代码删除 | 等 `plan-assembly-message-stream.md` 落地后一起清，避免两线冲突 |
| 多窗口草稿互踩 | 单窗口使用习惯下不触发；启用多窗功能时再做协调 |
| CC token 进 URL query / ws:// | Tailscale 隧道场景威胁模型可接受，已记录在案 |
| macOS Settings scene 化（480×560 + 18 tab） | 属设计改版而非修复，UI 变动敏感（粟粟规则：小步迭代），单独立项走 research→plan 流程 |
| 部署目标上调 macOS 15 | 影响面是产品决策（用户覆盖），与 P1-4 一起在 B11 给出实测数据后由粟粟拍板 |
| 其余 P2 | 按类型归组、"碰到那个文件时顺手改"：**死代码清理**（B 批次碰到哪个文件清哪个）/ **DateFormatter 静态化**（同上）/ **命名遗留**（softBlue/paleBlue/Theme.F 双名，碰 Theme 时一次清）/ **repeatForever 动画群**（性能不构成痛点前不动）/ **try? 补 log**（新改动一律 do-catch，存量随批次顺手） |

## 里程碑

| 里程碑 | 包含批次 | 标志 |
|--------|----------|------|
| M1: 数据安全清零 | B1-B2 | 所有 P0 关闭；跨楼层重复导入安全、MCP 不再能挂死聊天 |
| M2: 止血与安全网 | B3-B5 | 已知崩溃源清零、"失败报成功"清零、测试 target 跑起来且能拦回归 |
| M3: 核心链路健壮 | B6-B9 | 流式渲染热点收口、导入器结构正确、贴纸/侧栏/搜索的功能性 bug 清零 |
| M4: 演进基线 | B10-B11 | 设置页卡顿根治；VersionedSchema 基线落地、#Index/复合 id 决策有实测数据支撑 |
| M5: 架构滚动 | B12 | 无终点；以"四个 God Object 行数逐季下降"为方向性指标 |

## 长期架构方向

不立宏大目标，立四个"下次碰到就执行"的习惯：

1. **碰 View 文件时**：新逻辑一律不进 View（下沉 service/store/VM），并把该文件的死代码顺手清掉一件——God Object 靠"只出不进"瘦身，不靠专项大重构。
2. **碰双平台页面时**：先抽共享 section 再改需求，每次留下的复制比来时少一份。
3. **新写数据代码的三条铁律**：fetch 必带 profileId、save 不再裸 `try?`（失败至少 log + 用户路径上可见）、跨线程只传值类型不传 PersistentModel。
4. **每修一个正确性 bug，先在 B5 的 target 里写复现测试再修**——把"改 bug 必须引用证据"的既有纪律延伸成"修 bug 必须留测试"。
