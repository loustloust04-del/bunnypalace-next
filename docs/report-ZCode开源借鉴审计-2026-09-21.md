# ZCode 开源借鉴审计 · 2026-09-21

结论：值得借鉴的是“滚动权状态机、稳定测高缓存、平台能力驱动的设置入口、输入探针口径”，不是把记忆宫殿改成 Electron。当前 Mac hover 与草稿隔离已有对应实现，宜保留；ZCode 的滚动条并不符合粟粟要求的 4pt、滚动时显示、工具栏不偏心，不能照搬。

## 对象与证据边界

- 对象为 [官方 zai-org/ZCode](https://github.com/zai-org/ZCode)，不是 Zed，也不是同名 zcodeapp.com 原生开发产品。官方仓库自述为 Z.ai coding agent harness。
- 固定审计提交：`872ad960de7ec172591f7e1952f7849229f94521`。只读副本：`/tmp/zcode-audit-20260921`。下文外链均固定该提交。
- 这是源码借鉴审计，不是全库安全审计。未运行安装脚本、未构建 ZCode、未运行其测试或实机 UI，不能据此声称帧率、延迟、IME 正确性或整库安全。
- 记忆宫殿对照快照：`.worktrees/mac-mint-appearance`，现场 HEAD `5ed0e72efdb21ec4e55c3a2b3cf97e3153930568`。本报告的外部源码审计为只读；同轮合并与 Dock 修复独立记录。
- 使用 audit-verify-explain-grade-5 技能；结论区分源码确认、移植建议和待实测项。

## 1. 优先借鉴：滚动权由用户意图决定

**问题**：流式内容增长、测高、侧栏宽度变化都会触发滚动事件。如果仅凭“距底部多少”反复决定是否自动贴底，用户上滚阅读会被拉回。

**已确认机制**：`resolveFollowingAfterScroll` 只允许 user 来源更新 following，programmatic/layout 保持原意图；动态测高只补偿视口上方的行，跟随中、恢复中和宽度变化时不补偿。贴底前还会对账尚未派发 scroll 的 wheel 意图。[timelineScrollAnchor.ts:48–89、133–172](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/v4/timelineScrollAnchor.ts#L48-L172)

**建议**：记忆宫殿若继续出现流式跳动，将滚动来源、用户阅读意图、测高补偿拆成可测试的纯 Swift 决策层，AppKit/SwiftUI 只提供真实几何与事件；不要直接移植 DOM 的 wheel 正负号、48px 阈值或浏览器时序。

**验收**：流式输出中上滚立即停止跟随；折叠工具结果、拖侧栏宽度和恢复会话位置不夺取滚动权；主动回底恢复跟随。需要真机证据，纯函数测试只证明决策表。

## 2. 有条件借鉴：稳定 ID、有限测高缓存、完整列表虚拟化

**已确认机制**：会话 timeline 用稳定 render-unit key 索引，缓存实测高度；动态 ResizeObserver 测高回写缓存。缓存最多 4000 条，写入刷新淘汰顺序；切会话清空。顶层任务列表也虚拟化，初始化偏移取现有 scrollTop，而不是硬设 0。[ConversationTimeline.tsx:695–741](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/v4/ConversationTimeline.tsx#L695-L741)、[timelineRowHeightCache.ts:13–58](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/v4/timelineRowHeightCache.ts#L13-L58)、[会话切换清理:1435–1447](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/v4/ConversationTimeline.tsx#L1435-L1447)、[顶层虚拟列表:100–143](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/workspace-grouped-tasks/virtualized-top-level-list.tsx#L100-L143)。

**建议**：先用探针证明主线程耗时来自行创建或测高，再决定是否下沉 NSTableView/NSCollectionView。移植缓存设计时，键除消息 ID 还要区分宽度、字体、内容版本/失效时机，避免沿用旧高度。虚拟化与数据查询是不同层；不能靠截断查询换取流畅、牺牲搜索完整性。

**不能推出**：源码使用虚拟化不等于 ZCode 比当前原生列表快；尚无同数据量、同设备比较。

## 3. 借鉴输入边界，避免照搬 Web IME 补丁

**已确认机制**：快捷键入口过滤 isComposing、Process、Dead、229 和 repeat；通用 helper 还可接收本地 compositionActive。主 Lexical Enter 入口直接放行 isComposing。[bindings.ts:28–51](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/shortcuts/bindings.ts#L28-L51)、[imeComposition.ts:1–7](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/lib/imeComposition.ts#L1-L7)、[LexicalChatInput.tsx:536–550](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/LexicalChatInput.tsx#L536-L550)。

**重要限制**：不同入口并未都统一调用那个 helper，不能声称整个项目 IME 全面无误。Lexical 中另维护 composition ref 并延后清零，主要服务输入耗时分类，不应误读为全部提交路径的门禁。[LexicalChatInput.tsx:815–845](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/LexicalChatInput.tsx#L815-L845)

**记忆宫殿已有**：`MemoryPalace/Views/CardFlowView.swift:2015–2024` 在 ⌘Return 发送前检查 NSTextView.hasMarkedText；`Views/Chat/MacChatComposerHost.swift:15–48、83–88` 独立草稿身份，隔离会话切换且保留即时保存。应保持这些原生契约。可借鉴“每个快捷键先确认编辑器组合态”的统一约束，不把 keyCode 229 或 queueMicrotask 搬到 AppKit。

**验收**：拼音/日文候选确认 Enter 不发送；组合中 ⌘Return 不吞字；切会话不串草稿；长文本、粘贴、撤销重做、六行上限分别实测。

## 4. 优先借鉴：性能探针按阶段和输入类型分桶

**已确认机制**：Lexical update listener 测量 Markdown 序列化与 onChange 同步段；程序化改写与 IME 合成被排除，只上报 >500 且 ≤5000ms 的耗时。[LexicalChatInput.tsx:852–877](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/LexicalChatInput.tsx#L852-L877)、[uiPerfArmsTelemetry.ts:350–399](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/lib/uiPerfArmsTelemetry.ts#L350-L399)

**建议**：采用本地 signpost/探针分别量输入事件→文本更新、持久化、布局、呈现；常规键入、IME、粘贴分桶，记录分布。不能用上述 500ms 阈值认定 100ms 的 hover 无卡顿；不能排除 IME 后宣称中文输入流畅。此处不建议引入它的远端埋点服务。

**局限**：源码计时只覆盖同步处理，不是键盘到屏幕像素的端到端延迟；也仍进行两次全文序列化，不能作为“每次输入只处理增量”的范例。

## 5. 优先借鉴：设置分区注册与平台能力统一过滤

**已确认机制**：分区定义集中声明 id/icon/title/group；createSettingsPageConfig 按桌面能力和功能开关过滤，派生非空分组。目标设置不可见时回退到有效分区；已打开设置再次收到入口请求会消费跳转并更新子导航版本。[settingsPageConfig.ts:34–57、167–200](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/settings/settingsPageConfig.ts#L34-L200)、[SettingsPage.tsx:742–765](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/SettingsPage.tsx#L742-L765)、[不可见分区回退:1336–1343](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/SettingsPage.tsx#L1336-L1343)

**记忆宫殿已有**：`Services/MacWorkspacePreferences.swift:13–37、62–78` 已将 Dock 顺序、Code 入口和临时设置请求分开；`Views/Settings/SettingsSearch.swift:254、278–280` 已有 Mac 工作区搜索入口。不要重做已完成部分。

**建议**：以后新增 Mac 专属工具时，让设置侧栏、搜索词、可见条件、管理入口引用同一个描述对象；测试“入口能找到、隐藏后有有效退路、重复打开能跳转”。ZCode 的分区注册并不等于自动生成了所有搜索叶子，不能据此承诺一次注册覆盖所有设置需求。

## 6. 不直接借鉴的部分

| 部分 | 源码确认 | 对记忆宫殿的判断 |
| --- | --- | --- |
| 窗口实现 | Electron BrowserWindow，mac hidden titlebar/vibrancy，preload 隔离；默认保留后台节流。[desktopWindowChrome.ts:136–144、571–590](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/desktop/src/main/desktopWindowChrome.ts#L571-L590) | 借鉴窗口职责与后台活动边界，不引入 Electron。它不能回答 SwiftUI 何处必须下沉 AppKit。 |
| 滚动条 | CSS 全局 14px 宽/高、透明轨道、3px 透明边框；可见填充名义上 14−2×3=8px。[styles.css:752–795](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/styles.css#L752-L795) | 不是当前要求的 4pt overlay，不保证滚动时才显示，也不保证不占布局宽度。本轮继续使用AppKit 滚动容器的 overlay 模式及自绘滑块，并实测中心线。 |
| hover action | 行本地 hover/focus state，动作条件挂载，含触摸兜底。[task-row.tsx:343–369](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/ui/src/workspace-grouped-tasks/task-row.tsx#L343-L369) | 当前 `MacConversationRow.swift:28–54` 已固定54pt操作位、opacity显隐和本地无动画hover；不要反向改成动态挂载。可补键盘可达性的针对性验证。 |
| 设置写队列 | 超时只在提交前，进入提交阶段后等待收口，避免旧写晚到覆盖新值。[settingsWriteQueue.ts:15–48](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/packages/services/src/setting/settingsWriteQueue.ts#L15-L48) | 将来异步/远程设置可借鉴顺序与过期写防护，当前同步 UserDefaults Dock 没必要为此增加队列。 |

## 许可证与复用范围

根目录为 [Apache-2.0 LICENSE](https://github.com/zai-org/ZCode/blob/872ad960de7ec172591f7e1952f7849229f94521/LICENSE#L67-L129)。复用/改写受其覆盖的源码并分发时，应随附许可、保留适用声明、标明修改，并处理源分发中适用的 NOTICE 归属；专利授权有其条件，商标不因此获授权。仓库还包含独立依赖和子目录许可，不能把根许可视作所有素材/依赖都可任意复制。本报告没有移植代码，也没有完成全依赖许可清单。优先吸收状态机和边界设计，若以后移植具体实现，再按具体文件和依赖核对声明。

## 推荐顺序与完成标准

1. **本轮结束**：合并既有改动，Dock 使用自绘悬浮滑块且不占横向空间；滚动前、中、后截图验证同一中心线。此项无需采用 ZCode 代码。
2. **有复现再做**：补本地输入/滚动分阶段探针；真实样本定位到测高或行构建后，再选缓存或 AppKit 列表，不默认全面重构。
3. **下一次设置扩展时**：统一能力描述与设置注册，保留 Mac/iPad 独立偏好。
4. **若确认滚动权冲突**：抽纯 Swift 状态机，覆盖用户上滚、流式增长、宽度变化、prepend、切会话恢复，并补真实 UI 交互验证。

已核实源码与固定提交；未开展 ZCode 运行性能对比、完整安全审计、完整许可证依赖审计，也未证明记忆宫殿存在上述每一种缺陷。报告中的后续方案是针对可复现问题的借鉴方向，不是额外施工授权。
