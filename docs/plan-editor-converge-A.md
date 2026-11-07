# 统一编辑器 iOS：按方向 A 收敛

2026-10-16 · 工位 `misc-2` · 切片 0–6 已合 master；本轮先 merge master 到 `75450655f`，按粟粟确认执行切片 7，双端编译 / 回归后单独提交并停。

## 授权与停止点

- 粟粟已选 A：保留 CodeMirror，不换原生编辑器。
- 切片 0 已提交（`b151322a2`、`05e781bf6`）；默认关闭的 DEBUG 探针保留。本轮不安装、不 boot / shutdown / erase 模拟器、不碰真机。
- 10-16 任务书授权切片 7；粟粟：好（照推荐）。不安装、不操作模拟器或真机，9451 只作编译目标；不 device-lease、不 push / merge-queue submit，单独提交后停。
- 10-15 粟粟拍板：只留浮条撤回按钮，硬件键盘 ⌘Z / ⌘⇧Z 继续走 CM；编辑器 WKWebView 及内容视图的 `editingInteractionConfiguration` 返回 `.none`，`applicationSupportsShakeToEdit = false` 为全 App 开关，已知情。不做 undoManager 代理或 em 回放。
- 外部重载 / 恢复 / 换回可撤、源码切回合成一步已确认；不做跨模式逐键共享撤销，不增加固定浮条占位。
- 不改文件库存储格式 / 位置、FileVersionStore 格式、编辑器外功能（已批准的全 App 摇一摇开关除外）；不动 ContentView.body、NOW.md、CLAUDE.md、tasks/；不 push / merge-queue submit，不操作其他工位。脚本 / 权限 / 钩子拦截即停，不绕过。

## 证据和现状

调研已归档：[research-editor-references.html](research-editor-references.html)。根因编号沿用 U1–U5、F1–F6。

- `MemoryPalace/Views/FileLibraryPanelView.swift`：`FileEditorSheet` 的键盘通知控制 `safeAreaInset` 浮条；实时 WebView 常驻，源码 `TextEditor` 条件创建；`undoEdit` 分别调用 CM / 原生 UndoManager。
- `MemoryPalace/Views/Web/MarkdownWebEditorView.swift`：`editorPayload` 把全文、revision、主题、查找、命令一起发送；接收 contentChanged 后更新 Binding，会再生成全文回声。
- `MemoryPalace/Views/Web/WebViewHost.swift`：通用 WKWebView 宿主，未给编辑器单独限定原生滚动 / inset；切片 0 只在 markdown-editor 资源且显式启用时观测，其他 WebView 不受影响。
- `MemoryPalace/Resources/Web/markdown-editor.js` 是直接由 HTML `<script src>` 加载的源码，不是打包产物。`codemirror.bundle.js` 由 `scripts/codemirror-bundle/entry.js` 和 `build.sh` 生成；切片 7 导出实际使用的 isolateHistory 后重打包。
- 开始调研时 JS 有 `interceptIOSEnter`、`keepCaretVisibleOnShrink`、`typingRevealField`、外部更新 `addToHistory(false)`、revision 旧回声守卫；切片 1–6 的收敛与删除记录见下。
- 本轮已读三份历史教训：iOS 26 不能假设 innerHeight 不变；不能让两个滚动补偿器重复补偿；Binding 的迟到回声可能落后两次提交，不能只和最后一次正文比较。
- 参考源码已对照：SilverBullet `client/codemirror/editing/ios_enter.ts`（beforeinput + 原生选区）、`client/lib/keyboard_viewport.ts`（window 复位、visualViewport 后补一帧）、`client/codemirror/syntax/table.ts`（estimatedHeight + 缓存）；Joplin `packages/editor/CodeMirror/extensions/rendering/utils/makeInlineReplaceExtension.ts`（手势结束后 rAF 更新装饰）。
- 车头补充的模拟器复现已定位主根因：`contentChanged` 先改子视图 revision、后改父 Binding，短暂推送「新 revision + 旧正文」；JS 仅拒绝较小 revision，把同 revision 的旧正文当外部替换，冲掉历史、光标和布局。该报告是切片 1 的失败基线，不重复操作模拟器确认。

## 切片 0：可关闭的观测基线（已完成）

**文件**：本计划、调研报告、`WebViewHost.swift`、`markdown-editor.js`。

1. 首个提交只归档现有调研，不改报告内容。
2. Swift 在 `#if DEBUG` 中读取环境变量 `MP_EDITOR_PROBE=1`，且仅对 `htmlResourceName == "markdown-editor"` 安装探针。document-start / main-frame-only 的 WKUserScript 注入 `window.__mpEditorProbeEnabled = true`。未启用不注入、不注册原生观测；Release 不包含原生探针和开关注入路径。
3. JS 仅在该注入标志严格为 true 时注册事件 / ResizeObserver；默认没有探针消息。记录 beforeinput 捕获时及下一帧、CM 事务、内部滚动 / 缩放、window / visualViewport 事件和焦点 / 指针事件。
4. 每条 JS 样本带事件名、递增序号、毫秒时间、window.scrollY / innerHeight、visualViewport.height / offsetTop、CM scrollDOM.scrollTop / clientHeight、undoDepth / redoDepth、revision / 选区偏移。beforeinput 另带 inputType / isComposing / defaultPrevented；不记录输入字符、正文、文件名或路径。
5. 原生用 KVO 只读观察 WKWebView.scrollView 的 contentOffset / contentInset / adjustedContentInset / bounds，并记录键盘通知。JS 消息到达时同一日志补原生快照：contentOffset / contentInset / adjustedContentInset、WebView frame、scrollView bounds、时间和 WebView 实例标识。**不换 delegate、不改 offset / inset、不派发编辑事务**。
6. 输出用 `os_log` 的 info 级，subsystem `com.susu.MemoryPalace.editor-probe`，category `viewport-history`。仅数值 / 事件元数据公开输出，便于脱离 Xcode 收集。
7. 跑真实编辑器页面的桌面浏览器冒烟，验证开关关闭无探针、开启能看到 beforeinput 和历史深度 / 视口数据；这只能证明 JS 观测链，不证明 iOS 键盘或系统撤回正常。
8. macOS / iOS 两次 build-for-testing 成功后提交，交车头装模拟器实测。切片 0 不执行交互修复。

### 开启 / 关闭与采样交接

- Xcode Run scheme → Arguments → Environment Variables：`MP_EDITOR_PROBE` = `1`；重启 DEBUG App 后**新打开编辑器**。不提交 scheme / settings 改动。移除变量或设为 `0`，重启并重新打开编辑器即关闭。
- 车头用 simctl 启动已安装包时，可用进程环境前缀传入：`SIMCTL_CHILD_MP_EDITOR_PROBE=1 xcrun simctl launch <id> <bundle-id>`；先确保旧进程已由车头结束，避免复用旧进程。bundle id 以相应 target 构建设置为准。
- 采集：`xcrun simctl spawn <id> log stream --level info --style compact --predicate 'subsystem CONTAINS "editor-probe"'`。Xcode 控制台也可按 editor-probe 过滤。不开启则不应出现该 subsystem 的编辑器样本。
- 用脱敏长 Markdown（足够滚两屏，含列表、表格、frontmatter），先打字到可见区底部，依次：回车 → Backspace 合并行 → 普通字 → 点表格 / 属性卡 → 弹收键盘 → 浮条撤销 / 重做 → 三指撤销 / 重做。模拟器无法可靠代表的摇一摇 / 中文连续组字留给车头安排真机。
- 开源码模式编辑再切回、外部重载、恢复版本和「换回」各记录一组；记录每个动作的时间、屏幕录像及前后全文（只用脱敏样本），不要只给最终截图。
- 重点判断：F1 的 window / WK offset 是否移动、frame / visualViewport 是否重复缩放；F2 的 beforeinput 类型与 CM / 原生滚动先后；U1 的系统 historyUndo / historyRedo 是否缺失或提前耗尽、当时 CM undoDepth / redoDepth 是否仍大于 0。
- JS beforeinput 第一条为捕获阶段快照，下一帧才反映 CM 拦截和 DOMObserver 处理后的状态；原生快照是消息抵达时，不是假称与 JS 同步的同一时刻。原生 KVO 日志独立保留，用时间 / 实例 / JS 序号对齐。

## 切片 1：只修「新 revision + 旧正文」回声（已合入）

**证据**：[repro-editor-undo-flicker.html](repro-editor-undo-flicker.html)；来源提交 `8c7a4914c`。不把这片扩成文本单向协议或撤销架构改造。

**文件和步骤**：

1. `MarkdownWebEditorView.swift` 定义正文 / revision 值快照，`FileLibraryPanelView.swift` 用单个 `@State` 持有并绑定到网页编辑器。收到 `contentChanged` 一次替换整个快照，即使正文相同也同步 revision；payload 只从该快照取成对字段。删除子视图单独的 revision 状态及先改 revision 再写父 Binding 的路径，不用交换赋值顺序或异步延迟掩盖中间态。
2. 源码 TextEditor、外部重载、恢复、换回仍走原正文入口，但每次真正的原生正文变化连同 revision 一起推进；无净变化不推进。不改保存、版本落盘和历史分组语义。
3. `markdown-editor.js` 在防抖和 flush 两条上报入口记录最后上报的 revision / 正文。同 revision 回推必须与这份已上报正文一致，否则在修改 content / CM / textarea 之前丢弃；较小 revision 继续丢弃，首次载入不误拒绝。接受较高原生 revision 时同步 JS revision；`requestSave` 同样携带当前 revision，保留 180ms 内立即保存的成对快照。不改 `addToHistory(false)`、minimalChange、键盘和装饰策略。
4. `FileEditorUndoTests.swift` 增加真实 WKWebView 回归：输入上报后原生 payload 必须成对；注入同 revision 旧正文不能删字、移动选区或清历史；撤销后经过回声仍可重做；覆盖首次打开不可撤空及较高原生 revision 替换。测试运行实际页面和 CodeMirror，不断言源码文本。
5. `markdown-editor.js` 是源码，不需要重新打包；不修改 `codemirror.bundle.js`。真实 Chromium 页面另做定向冒烟，验证防抖 / flush、同 revision 旧正文、较小 revision 和合法外部替换的边界。
6. macOS / iOS 26 的指定 build-for-testing、相关单测通过后，提交本片代码 / 回归 / 复现报告 / 计划记录，停下交车头。任何编译闸或脚本 exit 75 立即停止，不换目录或参数绕过。

**设备交接**：车头安装本片 DEBUG iOS 包并开启 `MP_EDITOR_PROBE=1`，复测报告 #1–#5、#8、10a–10g；同时确认 #6 首开不可撤空未回归、源码修改 / 重载 / 恢复 / 换回仍能推入实时模式。设备复测通过前不宣称 iOS 组字、闪烁或系统手势已修复。先独立评估本片是否合入，其余方向 A 等剩余现象再定。

**10-15 regress sim 复测全过（#1–#6、#8、闪烁），#7 源码/实时视口不对齐仍在**。详见报告末尾原样附录；⌘Z / 摇一摇、全选删除、键盘弹收及底部折行仍未测，不把上述结论扩展到这些项目。切片 0、1 已合 master（#00468）。

## 切片 2：关闭系统编辑手势与摇一摇（本轮，粟粟已拍板）

**解决**：U1 的系统历史与 CM 历史不一致入口；不接管 UIKit UndoManager，不改 CM 历史或网页 beforeinput。

**文件和步骤**：

1. `WebViewHost.swift` 仅对 `markdown-editor` 资源启用手势关闭；在 `didFinish`、现有 accessory 覆盖之后应用，覆盖 WKContentView 页面载入后的时机，避免过早换类使 accessory 的原类名匹配失效。其他预览 / 手册 WebView 保持默认。
2. `WKWebViewNoAccessory.swift` 沿用现有动态子类模式，给编辑器 WKWebView 和 WKContentView 的 `editingInteractionConfiguration` getter 返回 `.none`。在当前类上叠加，不替换 accessory 覆盖；重复调用已为 `.none` 的实例不再套子类。不删现有注释、不加全局 swizzle、不改选区 / 复制粘贴菜单或硬件按键。
3. `PushNotifications.swift` 的 iOS 启动代理在任何提前返回之前设置 `application.applicationSupportsShakeToEdit = false`；全 App 生效且关闭编辑器后不恢复，这是已批准行为。本片不新增 Swift 文件；merge master 带入了 `LaunchResume.swift`，需先 `xcodegen generate` 更新本地生成工程。
4. 把 `scratchpad/retest-section.html` 原样插到复现报告末尾 `</main></body></html>` 前；更新本计划、工位状态与复盘索引。
5. 删除旧计划中的三档待选路线（undoManager 代理 / em 回放均未落地，无旧实现可删）；保留浮条 CM undo / redo 和硬件快捷键，不改键盘 / 滚动收敛及其他待授权切片。
6. 双端指定 build-for-testing、macOS 的 `FileEditorUndoTests` / `FileEditorTextModeTests` 回归后提交并停下；不安装或启动模拟器。不能用 macOS 回归证明 UIKit 手势关闭有效。

**交车头验收**：安装本片提交对应 DEBUG iOS 包，开启 `MP_EDITOR_PROBE=1`；软键盘输入后浮条撤 / 重做正常，三指左滑 / 右滑 / 双击不再弹系统编辑条或改正文，摇一摇不再弹撤销框；硬件 ⌘Z / ⌘⇧Z 仍按 CM 历史撤 / 重做。另确认长按选区 / 复制 / 粘贴、去 accessory 条不回归，关闭重开编辑器及切源码正常；其他输入框三指行为保持原样，但摇一摇全 App 禁用。实际手势和 UIKit 私有内容视图兼容性必须设备确认。

## 切片 3：键盘只留一人管理（10-16 已授权）

**解决**：F1 / F5。**文件**：`WebViewHost.swift`（编辑器专用配置）、`FileLibraryPanelView.swift`（FileEditorSheet / bottomBar）、`FileEditorKeyboardBar.swift`（需要同步浮条尺寸时）、`markdown-editor.js` / `.css`。

- 默认推荐 A1-b：保留 CM 内滚和 SwiftUI 缩 frame，WKWebView 外层不再参与滚动；仅编辑器设 isScrollEnabled=false、contentInsetAdjustmentBehavior=.never，必要的原生 offset 归零限定在编辑器宿主内。不能改变共享 WebView 的默认行为。
- 结合探针决定是否需要抑制 WebKit 自己的键盘处理；`.never` 只管 safe-area，不能当作抑制 focus reveal 的保证。先确认 sheet 是否真的经过 PagingViewController 的手动 inset，不能把聊天页结论直接套用。
- JS 采用 SilverBullet 的 viewport 事件 window.scrollTo(0,0) + 下一帧复核；实测读 visualViewport / innerHeight，不假定只有 visualViewport 变化，不用 fixed + translateY。
- 浮条建议跟键盘同帧出现，避免新增固定空白占位；若只能固定占位才能稳定，属于可见变化，先停下让车头请粟粟决定。
- 删除 `keepCaretVisibleOnShrink` 及对应 ResizeObserver / lastEditorHeight；替换成 Joplin 的点按后一秒内 resize 最小露光标，避免每一帧都 dispatch scrollIntoView。
- **验证**：探针比较弹 / 收 / 中途打断键盘，编辑区上下沿和 WK/window 偏移；光标屏底 / 屏中、深滚、横竖屏、窄屏浮条 / iPad 宽屏；不能以桌面 resize 替代 iOS。编译双端并回归 FileEditorPreferencesTests / 位置相关用例；装包实测由车头负责。

## 切片 4：回车 / 退格用 beforeinput 接管

**解决**：F2。**文件**：`markdown-editor.js`；需要公开 runScopeHandlers / EditorSelection / 删除命令时修改 `scripts/codemirror-bundle/entry.js`，运行 `bash scripts/codemirror-bundle/build.sh`，源码 / bundle / VERSIONS 一起提交。

- 照 SilverBullet ios_enter：keydown 只 stopPropagation，不 preventDefault；insertParagraph / insertLineBreak 到 beforeinput 才 cancel，先从 DOM 同步选区，再执行 CM keymap 一次。只在 iOS 且可编辑、非组字时处理。
- 退格先针对跨行 deleteContentBackward / deleteContentForward 做同样接管；不扩大到普通组字删除，不改词删除、修饰键和选择删除语义。beforeinput 缺失 / 迟到的防重逻辑沿用参考的有界状态，不叠第二套合成事件链。
- 删除旧 `interceptIOSEnter` 和 capture keydown 的旧注册及其所属注释，不保留两条 Enter 入口。
- **验证**：屏底逐次 Enter、空列表退出 / 编号续行、Backspace 合并、Delete、Shift-Enter、外接键盘、粘贴后首键、拼音候选确认；恰好一次修改、撤销分组正确、没有 WebKit 居中滚动。保留确定性的消费行为回归；依赖 beforeinput / DOM 选区的部分用真实浏览器及车头 iOS 实测。

## 切片 5：装饰防跳 + 块 widget 估高

**解决**：F3 / F4 / U4。**文件**：`markdown-editor.js`；新增 CM StateEffect 导出时同切片 4 的 bundle 流程。

- Joplin 方案：指针手势期间沿用旧选区生成装饰，手势结束后下一帧统一刷新；覆盖 live preview、table、frontmatter 三处，不只修 inline。SilverBullet 的 select.pointer 保留装饰作为对照，不混用两套不同更新时间。
- 组字中只映射装饰，不把候选区重建成 widget；保留已存在的源码露出设计。undo / redo 不清空 typingRevealField，真正的光标移动后再收回；不删除该交互状态。
- MarkdownTableWidget / FrontmatterWidget 增加 estimatedHeight，未测量按实际行高 / 行数保守估算；按内容 + 可用宽度缓存实测高度，宽度 / 字号改变时失效。用 CM 测量周期读高度，不在写 DOM 阶段同步读写造成布局抖动。
- **删旧绕法**：替换三处 selection 一变立即重建的路径；删除 undo selection 清空露出范围的分支。不删无关现有注释。
- **验证**：点按 / 长按选择 / 拖拽选区在表格及属性卡边界、撤销后保留露出行、长表滚入滚出、旋转宽度变化、中文组字；比较滚动锚点和高度，不仅比较 DOM 节点数。

## 切片 6：文本单向 + 明确 revision

**解决**：U5 / F6。**文件**：`MarkdownWebEditorView.swift`、`WebViewHost.swift`（如需专用命令发送）、`FileLibraryPanelView.swift`（显式替换入口）、`markdown-editor.js`。

- JS 编辑器是实时模式唯一真相源；普通 SwiftUI body 重算只发主题 / 查找 / 命令 / active，不带全文。初始化全文只发一次；contentChanged 单向上报，不再把 Binding 回声反推。
- 显式原生写入（打开、重新载入、恢复、换回、源码提交）有独立递增 nativeRevision / 操作标识，网页按原生操作序去重，不能和 JS 输入 revision 比大小后丢掉合法外部写入。JS 上报携带已应用的原生版本，Swift 拒绝替换前迟到的 contentChanged。
- 源码编辑在退出源码时提交一次，切走实时模式前沿用 flush 保证末尾 180ms 内容不丢。必须先明确切模式 / 保存 / 查找读取的是哪份已确认正文，不用最近一次 Binding 文本比较猜测「外部写」。
- **删除**：editorPayload 的常规 content 回声、JS 以 nativeRevision < revision 判旧回声的路径。保留 minimalChange，用于显式写入。
- **验证**：连续两次迟到回声、180ms 内输入后立刻保存 / 切模式、组字确认、输入未回报时恢复 / 重载、外部替换后旧 contentChanged 迟到、主题 / 查找变化不触发正文替换；大文件输入不再每键全文 JSON 往返。更新受影响的 FileEditorUndoTests / FileEditorTextModeTests；不测试私有源码字符串。

### 切片 6 实施契约（10-16）

- 全文单独走 `replaceDocument(content, nativeRevision)`，宿主 coordinator 按原生操作序去重后才序列化；`configure` 只有主题 / 查找 / active / 命令 / 首次位置，不包含正文。JS 编辑版本在每个原生操作内递增，不与 nativeRevision 比大小。
- 保存、切模式、关闭、复制、打开查找 / 版本历史、双链自动保存，实时模式先请求带 token 的 `flushed` 成对快照再执行；同次等待的读取共用 flush，依请求顺序完成。显式原生替换优先于替换前迟到的快照，等待中的动作读取当前替换正文，不让旧输入覆盖它。
- 实时查找高亮 / 替换读取 JS 当前文档，Swift 计数读取最近确认的镜像（输入上报最多 180ms 防抖）；打开查找先 flush。源码保存 / 查找读取原生 sourceDraft；sourceDraft 与进入源码的基线比较，仅退出源码有净修改时提交一次。切片 6 时提交不入历史；切片 7 改为独立可撤一步。
- 待回报的首个编辑窗口只发小型 documentChanged 元数据以启用保存，不反推正文；contentChanged / requestSave / flushed 均携带 nativeRevision 和 JS revision，Swift 拒绝旧原生操作和操作内乱序快照。

## 切片 7：一本 CM 撤销账 + 外部写入隔离

**解决**：U2 / U3；依赖切片 6 的显式写入契约。**文件**：同切片 6、`FileEditorKeyboardBar.swift`；bundle entry 导出 isolateHistory / history / Compartment 等实际使用的 API 后按脚本重打包。

- 10-16 粟粟：好（照推荐）。初始化 / 换文档新建编辑器，首次载入不入历史，不能撤成空文件；同文档重新载入 / 恢复 / 换回用 minimalChange + isolateHistory("full")，各自一步进入历史，能整步回到之前正文。不同时做清栈和入栈两种策略。
- 源码模式本地编辑仍由原生 TextEditor 的 UndoManager 管；回实时模式时源码净修改只向 CM 提交一步，不把源码每键推给隐藏 CM。这里的「一本账」指实时模式所有编辑入口统一 CM，不声称 UITextView 和 CM 已共享历史。
- 若粟粟要求跨模式逐键共享撤销，属于当前推荐之外的交互 / 架构选择，先停下来拍板；不能拿「切回合成一步」假称逐键统一。
- **删除**：显式外部写入一律 addToHistory(false) 的旧规则、源码期间逐键映射旧 CM 历史；更新与新规则矛盾的注释。保留版本历史存储格式及所有落盘行为。
- **验证**：打字→格式→切源码改→切回→撤 / 重做精确还原每个基线；恢复 / 换回 / 重载后撤销不得出现半截拼接；初次打开不可撤成空；源码无净变化不制造历史步。更新行为用例并让车头 iOS 验证。

## 每片的提交与验证门槛

- 每片独立中文 commit：改动 → 双端 build-for-testing → 相关已有行为单测 / 真实浏览器冒烟 → 更新计划 / 复盘 / 工位状态 → commit；本轮设备实测交车头，不作为本工位提交前置。提交尾带指定 Co-Authored-By。
- 允许编译命令仅为：
  - `xcodebuild build-for-testing -scheme MemoryPalaceTests -destination 'platform=macOS'`
  - `xcodebuild build-for-testing -scheme MemoryPalaceIOS -destination 'platform=iOS Simulator,id=<从 -showdestinations 选 iOS 26>'`
- 编译只认 `** TEST BUILD SUCCEEDED **`；使用全机 shim 排队，不绕过，不设 derivedDataPath。新增 Swift 文件才先跑 xcodegen generate。
- 单测按实际受影响类运行：`xcodebuild test-without-building -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/<类>`；只认 `Test Suite '<类>' passed`。模块名为 `记忆花园`。真实页面冒烟验证当前切片行为；不新增接线 / 源码字符串断言测试。
- 切片 0 结束后追加实际验证与交接记录；设备实测不能做则明确留空，不写「已修复」。

## 切片 0 验证记录

- `node --check MemoryPalace/Resources/Web/markdown-editor.js`：exit 0。
- Chromium 直接打开仓库真实 markdown-editor.html / JS / bundle：不开注入标志，输入 `probe-off` 后探针消息为 0。
- 开启后输入 `sample`：undoDepth / redoDepth 为 1 / 0；真实快捷键撤销得到空串与 0 / 1；重做精确恢复 `sample` 与 1 / 0。
- 合成 `beforeinput historyUndo` 用于验证采样通道：捕获时深度 1 / 0、defaultPrevented=false；下一帧 0 / 1、defaultPrevented=true，正文为空。它不是 iOS 系统手势实测。
- 实际页面高度从 700 改到 460，cm.resize / visualViewport.resize 均记录 460；真实滚轮使 scrollTop 从 638 到 338，cm.scroll 读数一致；页面无 bridge error / 浏览器 JS error，已截图目视并关闭两个页面。
- 长文本 `.type` 自动化曾报 8 秒超时但后台继续输入；未重跑同一长输入，改为观察现有内容并用滚轮完成几何断言，不把这次工具超时计作产品故障或成功证据。
- 原生 os_log / KVO、iOS 键盘 / 三指 / 摇一摇采样尚未实测，按任务书交车头安装验证；不宣布 F1 / F2 / U1 已坐实或已修复。
- macOS：`xcodebuild build-for-testing -scheme MemoryPalaceTests -destination 'platform=macOS'`，日志原文 `** TEST BUILD SUCCEEDED **`（完整构建日志 `artifact://13`）；未运行单元测试。
- iOS：`xcodebuild build-for-testing -scheme MemoryPalaceIOS -destination 'platform=iOS Simulator,id=9451D1D2-7F24-46CB-B7FB-2AA3AD6304A9'`，iPhone 17 Pro / iOS 26.4.1，日志原文 `** TEST BUILD SUCCEEDED **`（完整构建日志 `artifact://5`）。
- 车头安装对应本轮提交的 DEBUG iOS 包（bundle `com.susu.MemoryPalace.ios`）；本次构建产物为 `/Users/susu/Library/Developer/Xcode/DerivedData/MemoryPalace-dfeyfendcildgtfyhfkptruaimsr/Build/Products/Debug-iphonesimulator/记忆花园.app`。共享构建目录可能被后续构建覆盖，按提交内容核对包，不仅按文件名判断版本。

## 切片 1 验证记录

- 失败基线使用车头已取证的模拟器报告；本轮未安装或操作设备。
- `node --check MemoryPalace/Resources/Web/markdown-editor.js`：exit 0；该文件是 HTML 直接加载的源码，无 bundle 重打包。
- Chromium 运行仓库真实 HTML / JS / CodeMirror bundle：实际键入 `abc` 得到 `原文abc`，同 revision 旧正文、较小 revision 旧正文、正确确认回声依次注入后，正文 / head / undoDepth / redoDepth 始终为 `原文abc / 5 / 1 / 0`。
- 通过编辑器真实命令通道撤销，等待 180ms 上报再注入错误和正确回声：`原文 / 2 / 0 / 1`；重做并 flush 后再注入旧正文：`原文abc / 5 / 1 / 0`。已截图目视正文和光标。
- 较高原生 revision 20 替换为 `替换` 后输入 `尾`：上报 revision 21、正文 `替换尾`；独立输入后撤回、flush 的正文不变，revision 23、head 3、redoDepth 1。
- 独立页面首次载入 `打开时的原文` 后执行 undo：返回 false，全文不变，undoDepth / redoDepth 都为 0。全选删除上报后注入旧全文，仍为空串 / head 0 / undoDepth 1；撤销后注入空串旧回声，仍为原文 / redoDepth 1。
- 未等防抖直接调用 requestSave：实际消息包含 `打开时的原文保存前` 和当前 revision 3。两个浏览器页面均无 JS error，已关闭；未留下测试脚本或样本。
- 浏览器工具的 Control+Z 调用中断了执行，页面未收到撤销；已报工具问题，随后改用编辑器既有 undo / redo 命令通道完成上述验证，不把工具中断计作产品失败或快捷键验证通过。
- macOS：`xcodebuild build-for-testing -scheme MemoryPalaceTests -destination 'platform=macOS'`，原文 `** TEST BUILD SUCCEEDED **`（`artifact://15`），全机 shim 正常排队后完成。
- 单测：`xcodebuild test-without-building -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/FileEditorUndoTests -only-testing:MemoryPalaceTests/FileEditorTextModeTests`；原文 `Test Suite 'FileEditorUndoTests' passed`、`Test Suite 'FileEditorTextModeTests' passed`，`Executed 6 tests, with 0 failures (0 unexpected)`（`artifact://17`）。包含两个新增真实 WKWebView 旧回声回归和原有源码撤销 / 保存回归。
- iOS：`xcodebuild build-for-testing -scheme MemoryPalaceIOS -destination 'platform=iOS Simulator,id=9451D1D2-7F24-46CB-B7FB-2AA3AD6304A9'`，iPhone 17 Pro / iOS 26.4.1，原文 `** TEST BUILD SUCCEEDED **`（`artifact://19`）；未装包、未启动或操作模拟器。
- 交车头安装本片提交对应的 DEBUG 包：`/Users/susu/Library/Developer/Xcode/DerivedData/MemoryPalace-dfeyfendcildgtfyhfkptruaimsr/Build/Products/Debug-iphonesimulator/记忆花园.app`。共享产物会被别的构建覆盖，请按提交核包；`MP_EDITOR_PROBE=1` 的开启和 log stream 命令见切片 0。复测完成前，设备验收项保留未勾选。

## 切片 2 验证记录

- 开工 `git merge master` fast-forward 到 `6f9071354`，切片 0、1 已在其中；未 push / 提交合并队列，未操作设备。
- `scratchpad/retest-section.html` 的原始字节完整插在复现报告末尾闭合标签前，程序比对通过。附录是车头的切片 1 设备实测，不是本片系统手势验收。
- macOS：`xcodebuild build-for-testing -scheme MemoryPalaceTests -destination 'platform=macOS'`，原文 `** TEST BUILD SUCCEEDED **`（本轮 `artifact://6`）。
- 单测：`xcodebuild test-without-building -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/FileEditorUndoTests -only-testing:MemoryPalaceTests/FileEditorTextModeTests`；原文 `Test Suite 'FileEditorUndoTests' passed`、`Test Suite 'FileEditorTextModeTests' passed`，`Executed 6 tests, with 0 failures (0 unexpected)`（本轮 `artifact://8`）。运行真实 sheet / WKWebView / CM 的旧回声、撤 / 重做、源码编辑与保存路径；不当作 iOS 手势证据。
- iOS 首次测试构建退出 65：`InputBarStack.swift` 找不到 `LastLocationResume`、`LaunchSplash.swift` 找不到 `LaunchResumeMarker`（本轮 `artifact://10`）。merge master 新带入的 `LaunchResume.swift` 未进入旧生成工程；执行 `xcodegen generate` 成功，不改这几个功能的源码，不换参数绕编译闸。
- 生成工程后，原命令 `xcodebuild build-for-testing -scheme MemoryPalaceIOS -destination 'platform=iOS Simulator,id=9451D1D2-7F24-46CB-B7FB-2AA3AD6304A9'`，iPhone 17 Pro / iOS 26.4.1，原文 `** TEST BUILD SUCCEEDED **`（本轮 `artifact://13`）。全机 shim 正常排队，未遇 exit 75。
- 实施范围无偏离：只落地已拍板的系统手势 / 摇一摇开关；手势覆盖在 `didFinish` 的 accessory 覆盖后叠加，避免原有类名匹配被提前换类破坏。后续切片重编号为 3–7，仍待授权，不自动继续。
- 车头安装本片提交对应的 DEBUG iOS 包（bundle `com.susu.MemoryPalace.ios`）：`/Users/susu/Library/Developer/Xcode/DerivedData/MemoryPalace-dfeyfendcildgtfyhfkptruaimsr/Build/Products/Debug-iphonesimulator/记忆花园.app`。共享产物可能被覆盖，须按提交核包；开启 `MP_EDITOR_PROBE=1` 后按切片 2 交接矩阵验收。未安装、未 boot / shutdown / erase 模拟器、未碰真机；系统手势与摇一摇实效留给车头，不宣称已实测通过。

## 切片 3 验证记录（10-16）

- 仅编辑器采用外层禁滚 / `.never` 及 layout 后 inset / offset 归零；其他共享 WebView 默认行为不变。未移除 WebKit 私有键盘通知；`.never` 不作为 focus reveal 保证。
- `PagingViewController.keyboardFrameWillChange` 的 inset 只写其 hostingControllers，不直接写单独呈现的 sheet；未把聊天页补偿套进编辑器。实际 sheet / UIKit 层级及 focus reveal 时序留设备探针确认。
- 删除旧 `keepCaretVisibleOnShrink`、`lastEditorHeight` 和生产 ResizeObserver；改 CM 测量周期在点按后 1 秒窗口内最小露光标。无固定浮条占位，移除浮条独立 0.18 秒动画，通知同次更新浮条，时长随键盘通知；私有曲线 7 用 easeInOut，不宣称逐帧同曲线。
- Chromium 真实页面：390×700 → 390×430，光标 407–425 在 scroller 0–430 内，windowY=0；超过点按 1 秒后 scrollTop=700，改 700×550 仍为 700，innerHeight / visualViewport.height=550。截图目视，无 JS error，页面已关闭。该结果不代替 iOS 键盘验证。
- macOS 指定 build-for-testing：`** TEST BUILD SUCCEEDED **`（`artifact://7`）。
- 指定 macOS test-without-building：`Test Suite 'FileEditorPreferencesTests' passed`、`Test Suite 'FileEditorPositionStoreTests' passed`、`Test Suite 'FileEditorUndoTests' passed`、`Test Suite 'FileEditorTextModeTests' passed`；`Executed 20 tests, with 0 failures (0 unexpected)`（`artifact://9`）。
- iOS 指定 build-for-testing（9451 仅作编译目标）：`** TEST BUILD SUCCEEDED **`（`artifact://10`）。不操作设备。车头验弹 / 收 / 中途打断、屏底 / 屏中、深滚、横竖屏、窄屏浮条 / iPad 宽屏，比较 WK offset / inset、window 偏移及上下沿。

## 切片 4 验证记录（10-16）

- 参考 SilverBullet `client/codemirror/editing/ios_enter.ts`：替换旧 Enter capture 及合成事件路径；生产仅 iOS 接管 Enter / 行边界空选区删除。keydown 保留默认动作，beforeinput 同步 DOM 选区后执行 CM keymap 一次；500ms fallback / 1s 迟到防重，销毁清理监听和 timer。
- `bash scripts/codemirror-bundle/build.sh` 成功，bundle 1,193,345 bytes；源码、bundle、VERSIONS 同片提交。永久回归在原 FileEditorUndoTests 增加真实 WKWebView 的 DOM caret / 精确一次修改 / 撤销恢复、跨行删除 fallback / 迟到防重。
- Chromium 真实页面：编号续行、空列表退出、Backspace / Delete 合并、Shift-Enter 均恰好一次修改；DOM caret 未同步到 CM 时在正确位置断行；普通行内删除、组字 Enter 不拦。500ms fallback 后迟到 Enter 修改次数 0。真实键入 abc + Enter 得 `等待\nabc\n`，截图目视通过，无 JS error，页面已关闭。
- macOS 指定 build-for-testing：`** TEST BUILD SUCCEEDED **`；定向回归 `Test Suite 'FileEditorUndoTests' passed`、`Test Suite 'FileEditorTextModeTests' passed`，`Executed 8 tests, with 0 failures (0 unexpected)`（同一日志 `artifact://18`）。
- iOS 指定 build-for-testing：`** TEST BUILD SUCCEEDED **`（`artifact://19`）。车头设备验屏底逐次 Enter、列表续行 / 退出、Backspace / Delete、Shift-Enter、硬件键盘、粘贴后首键、拼音候选确认，比较精确一次修改、撤销分组和 WebKit 居中滚动；本工位未操作设备。

## 切片 5 验证记录（10-16）

- inline / table / frontmatter 共用手势与组字冻结：按下记录旧选区，期间只映射，document pointerup / cancel 后下一帧统一刷新；undo / redo 保留 typingRevealField，真正移动光标才收回。
- 两类块 widget 加 estimatedHeight，按内容 / 可用宽度 / 字体缓存 CM 测量周期的真实 DOM rect 高度；宽度或字体变化使用新 key。缓存有界 128 项，不在 DOM 写入阶段同步读布局，不把属性卡外 margin 重复算入块高。
- Chromium 真实 pointer：表格按住时尾正文 top 固定 258.78125 / 表格高 66，属性卡按住时尾正文 top 固定 264.78125，释放下一帧才露源码；撤销后链接源码保留，真正挪光标才收。合成组字期间只映射、结束后候选字仍可见，不代替拼音真机验收。
- 60 行表格宽 650→350，实测高 1747.5→2937，字号 13→16 后高 3486；最终缓存与 DOM rect 均 2937。真实滚轮 500→1000→500，windowY=0。截图目视、最终 console / JS error 无新增，浏览器页均关闭。
- 冒烟发现 CM 禁止在 requestMeasure.write 中同步 dispatch；布局 effect 改到测量后的 microtask，同时修正切片 3 的同类光标测量入口。缩高 430→250 后光标 232–250 可见、无 console 错误；这是本片跨回切片 3 的修正，不改变露光标语义。
- iOS 指定 build-for-testing：`** TEST BUILD SUCCEEDED **`（`artifact://31`）。
- macOS 首轮 build-for-testing 成功，24 项回归中表格手势的两个断言失败（`artifact://34`）：隐藏 WKWebView 的 rAF 不执行。测试改为显示该回归窗口后验证真实帧；未改生产 rAF 为 timer，未缩窄断言。
- 最终 macOS 指定 build-for-testing：`** TEST BUILD SUCCEEDED **`；`Test Suite 'FileEditorPreferencesTests' passed`、`Test Suite 'FileEditorPositionStoreTests' passed`、`Test Suite 'FileEditorUndoTests' passed`、`Test Suite 'FileEditorTextModeTests' passed`，`Executed 24 tests, with 0 failures (0 unexpected)`（`artifact://36`）。
- 车头验长按 / 拖选及原生选区柄事件、表格 / 属性卡边界、中文组字、长表滚入滚出及旋转宽度后的高度 / 锚点。本工位未操作设备。

## 切片 6 验证记录（10-16）

- 全文独立 `replaceDocument` 通道按 nativeRevision 去重后才序列化，普通 `configure` 无 content / revision；contentChanged 单向回报。删除 JS 共享 revision 时钟比较、同 revision 旧回声正文记录及旧 setContent 入口，无兼容别名。
- 重载 / 恢复 / 换回显式推进原生操作序；源码仅 sourceDraft 逐键编辑，退出有净修改时一次提交。保存 / 切模式等依赖实时全文的动作等 token 对应的 flushed；显式原生写入优先，Swift 拒绝替换前迟到的正文 / 保存消息。
- 真实 WKWebView 回归覆盖配置 / 查找后 undo / redo 保持、未回报输入后同正文原生替换仍生效、两次迟到 contentChanged 与旧 requestSave 被拒绝。真实 NSSegmentedControl 切模式覆盖 180ms 内末尾输入、源码逐键不改隐藏 CM、一次提交及立即保存精确全文。
- 180,002 字符真实 WKWebView 临时 IPC 观测原文（`artifact://47`）：`EDITOR_A6_SMOKE {"length":180002,"transmissions":[{"type":"configure","body":false,"bytes":179},{"type":"configure","body":false,"bytes":180}]}`。两条配置均无正文；字段 bytes 实际采样 JSON.stringify(...).length（UTF-16 长度），不冒充字节数。观测 recorder / print 已删除；永久回归只保留大文件末尾与保存的消费行为。
- Chromium 实际键入尾字后 flush：正文 `原文尾`、JS revision 1 / nativeRevision 0；新原生操作 1 在 JS revision 5 时仍替换为 `重载正文`，重复 / 更旧原生操作未覆盖它。CDP composition 确认后立即保存得到 `重载正文中文`；inactive flush 保留 `重载正文中文切换尾`，主题 / 查找配置前后正文一致。共享浏览器截图超时后，独立 Chrome 已对实际页面截图目视，console 无错误，页面全部关闭；CDP 输入不是 iOS 拼音验收。
- iOS 指定 build-for-testing：`** TEST BUILD SUCCEEDED **`（`artifact://44`）。后续只改 macOS 测试，不改生产源码或 iOS 工程。
- 首轮 macOS 构建通过，25 项回归中原切片 5 的手势 rAF 两断言再次因窗口时钟不前进失败（`artifact://43`）。状态转换回归改为在 pointerup 有界范围控制下一帧时钟、立即恢复原调度器；仍断言真实尾正文几何不变和释放后源码，不改生产 rAF、不缩窄断言。真实手势帧的浏览器证据见切片 5。
- 移除临时观测、补同正文显式替换边界后的最终 macOS 指定 build-for-testing：`** TEST BUILD SUCCEEDED **`；`Test Suite 'FileEditorPreferencesTests' passed`、`Test Suite 'FileEditorPositionStoreTests' passed`、`Test Suite 'FileEditorUndoTests' passed`、`Test Suite 'FileEditorTextModeTests' passed`，`Executed 26 tests, with 0 failures (0 unexpected)`（`artifact://55`）。
- 未安装、不操作模拟器 / 真机，不 device-lease、不 push / merge-queue submit。车头设备验真实候选确认、即时保存 / 切模式、输入未回报时恢复 / 重载 / 换回及旧回报迟到；切片 7 未执行，外部写入和源码提交仍不入 CM 历史，不宣称 U2 / U3 或源码 / 实时视口 #7 已修复。

## 切片 7 验证记录（10-16）

- 开工按任务书先 `git merge master`，fast-forward `ea2153152` → `75450655f`；切片 3–6 已在基线中。NOW.md 的旧 HEAD 戳已提示，不修改 Warden 的状态文件。
- 首次载入仍不入栈，换文档沿用新建编辑器；其余同文档原生写入改为 minimalChange + isolateHistory("full")。源码只在退出有净修改时提交一次，本片不引入逐键共享撤销。删除外部写入一律不入栈规则和恢复不进历史的矛盾注释；版本存储格式、保存与所有落盘入口未改。
- `bash scripts/codemirror-bundle/build.sh`：`导出齐全 ✅ (31 个)`，bundle `1193387 bytes`；仅新增实际使用的 isolateHistory 导出，bundle / VERSIONS 同片提交。`node --check MemoryPalace/Resources/Web/markdown-editor.js` exit 0。master 带入新 Swift 文件，先 `xcodegen generate` 成功后编译；本片没有新增 Swift 文件。
- 修改前真实 Chromium：`共同前缀 旧正文 共同后缀尾` → 恢复为 `共同前缀 恢复正文 共同后缀` → undo 后仍为恢复正文，undo / redo 深度均 0，不能整步回到前文。
- 修改后真实页面实际键入尾字：恢复→换回→重载空正文→后输，逐次 undo 得 `空正文` / `共同前缀 旧正文 共同后缀尾` / `共同前缀 恢复正文 共同后缀` / `共同前缀 旧正文 共同后缀尾` / `共同前缀 旧正文 共同后缀`，逐次 redo 精确逆转；首开基线不可继续撤回。
- Chromium 实际键入 / 加粗 / 显式源码提交 / 再键入：四次 undo 精确还原 `原文**末尾**源码一源码二` / `原文**末尾**` / `原文末尾` / `原文`，四次 redo 逆转至 `原文**末尾**源码一源码二后输`。同正文新原生写入保留 redo；页面重载后另一份正文 undo / redo 均 false。截图目视，console / JS error 为空，页面已关闭。浏览器不冒充原生 TextEditor 或 iOS 输入法验收。
- macOS：`xcodebuild build-for-testing -scheme MemoryPalaceTests -destination 'platform=macOS'`，原文 `** TEST BUILD SUCCEEDED **`（本轮 `artifact://9`）。使用全机 shim，没有设置 derivedDataPath。
- 首轮 macOS 回归 30 项：`FileEditorUndoTests` 11 项通过，Preferences / PositionStore 通过；源码无净变化用例有 2 个断言失败（本轮 `artifact://11`）：直接驱动 UndoManager 后 NSTextView 是原文，但未回报 Binding，切回 CM 得 `原文临时`、redo 被截断。该轮串联的 iOS 构建未执行。保留原断言，夹具在程序化 undo 后调用原生 didChangeText 完成文本编辑通知，不直接改 Binding；诊断日志、hosting / responder / State Binding 尝试均已撤掉。诊断中的只读 undoManager 环境注入还曾编译失败，相关代码未保留。
- 最终 macOS 原命令重新 build-for-testing：原文 `** TEST BUILD SUCCEEDED **`；随后原四类定向 test-without-building：`Test Suite 'FileEditorPositionStoreTests' passed`、`Test Suite 'FileEditorPreferencesTests' passed`、`Test Suite 'FileEditorTextModeTests' passed`、`Test Suite 'FileEditorUndoTests' passed`，`Executed 30 tests, with 0 failures (0 unexpected)`（本轮 `artifact://27`，1429 / 1542 / 1559 / 1661 / 2137 / 2140 行）。源码无净变化的原断言已通过；不把程序化 AppKit 编辑通知夹具当 iOS 原生撤销验证。
- iOS：`xcodebuild build-for-testing -scheme MemoryPalaceIOS -destination 'platform=iOS Simulator,id=9451D1D2-7F24-46CB-B7FB-2AA3AD6304A9'`，原文 `** TEST BUILD SUCCEEDED **`（本轮 `artifact://27`，6332 行）。9451 仅作编译目标，无安装、boot / shutdown / erase 或其他设备操作。
- 实施无交互偏离：只导出实际使用的 isolateHistory，不额外引入 history / Compartment 或清栈方案；源码逐键映射路径已在切片 6 删除，本片沿用 sourceDraft / nativeRevision 和现有浮条分派，不改原生撤销桥或任何版本落盘行为。完成本提交后停，不继续其他切片、不提交队列。
- 设备交接：车头按本片提交核包后验打字→格式→源码多次改→切回→浮条 / ⌘Z / ⌘⇧Z 精确整步还原；源码本地撤回到基线后切回不增加 CM 步。恢复 / 换回 / 重新载入在输入尚未回报时各撤 / 重做一步，不出现半截拼接，后续输入独立；首次打开 / 换文档不可撤空。空正文是合法恢复目标，应可一步撤回非空前文；另验真实候选确认、即时保存、关闭重开与版本落盘不回归。
- 未安装、不操作模拟器 / 真机、不 device-lease、不 push / merge-queue submit。源码 / 实时视口 #7 不在本片解决范围。

## Todo checklist

- [x] ✅ 切片 0：首个提交归档调研报告（`b151322a2`）。
- [x] ✅ 切片 0：写方向 A 逐片计划、旧绕法删除清单、验证门槛及待拍板点。
- [x] ✅ 切片 0：默认关闭的 Swift DEBUG / JS 注入探针落地。
- [x] ✅ 切片 0：真实编辑器页面冒烟，验证开 / 关、输入事件与历史深度采样。
- [x] ✅ 切片 0：macOS build-for-testing 出现 TEST BUILD SUCCEEDED。
- [x] ✅ 切片 0：iOS 26 simulator build-for-testing 出现 TEST BUILD SUCCEEDED。
- [x] ✅ 切片 0：提交实现 / 计划 / 工位状态，停下交车头安装采样。
- [x] 车头回传旧回声实测复现报告及只做切片 1 的继续指令；其他 F1 / F2 / U1 探针数据仍待设备补测。
- [x] 切片 1：Swift 正文 / revision 单状态原子更新，原生正文入口同步推进 revision。
- [x] 切片 1：JS 拒绝同 revision 不同已上报正文，保留首次载入 / 较高原生 revision。
- [x] 切片 1：真实 WKWebView 回归及 Chromium 冒烟通过。
- [x] 切片 1：macOS / iOS build-for-testing、相关单测通过。
- [x] 切片 1：提交复现报告、实现、验证及工位状态，停下交车头安装复测。
- [x] 切片 1：车头完成 iOS 旧回声复测，#1–#6、#8、已测闪烁通过，已合 master（#00468）；#7 视口不对齐仍在。
- [x] 粟粟确认系统手势：编辑器 `.none` + 全 App 关摇一摇，保留浮条 / CM 快捷键。
- [x] 切片 2：关闭编辑器 WKWebView / 内容视图系统编辑手势，启动时禁摇一摇，补原样复测附录。
- [x] 切片 2：macOS / iOS build-for-testing、相关回归通过并提交，停下交车头。
- [ ] 切片 2：车头设备验收系统手势关闭、浮条 / 硬件快捷键及选区菜单无回归。
- [x] ✅ 切片 3：键盘 / 滚动收敛为单一管理者，双端编译 / 20 项回归及浏览器冒烟通过，设备验收交车头。
- [x] ✅ 切片 4：Enter / 跨行删除 beforeinput 接管，双端编译 / 8 项回归及浏览器冒烟通过。
- [x] ✅ 切片 5：手势装饰延迟 + widget 估高，双端编译 / 24 项回归及浏览器几何冒烟通过。
- [x] ✅ 切片 6：文本单向 + 原生版本确认，双端编译 / 26 项回归、真实页面与原生 IPC 冒烟通过；按授权在本片后停止。
- [x] 粟粟确认外部写入可撤及源码切回合成一步的交互。10-16 粟粟：好（照推荐）。
- [x] 切片 7：显式写入 isolateHistory + 源码提交边界，双端 `TEST BUILD SUCCEEDED`、30 项回归及真实页面冒烟通过；计划 / 验证 / 复盘 / 工位状态随本片单独提交，提交后停。
