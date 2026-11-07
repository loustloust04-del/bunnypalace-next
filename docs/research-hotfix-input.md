# 输入栏紧急修复研究（2026-10-17）

## 结论

#00498 的手写 Binding 捕获父 View 的 `@State String`，穿过 `ChatInputBar.equatable()` 后，渲染事务可能一直读旧文本快照；原生 UITextView 和持久化已经有完整两行，UI 却仍认为空输入：多行模式不切、发送箭头仍是语音波形。不是 wiki 预热或 pendingSends 卡住，也没有证据证明 persistText 把换行删掉。

最小修复：iOS 文本镜像改成每个 InputBarStack 持有的稳定 `@Observable` 引用，Binding getter 直接观察同一对象的 text。同步持久化 setter、差分 flush、附件、发送门控、`.equatable()` 和全部外观代码均保留。

## 工位与 T1 核对

- 开工 HEAD `4276ef98f`，共享 `zone/hotfix` 工位干净；任务书的 `9e8f5d550` 之后仅新增任务书。NOW 的 `f7ee00081` 戳过期，不修改 NOW/master。
- `git diff 04feebbe0 HEAD` 的八类输入栏文件：`ChatInputTextView` / `InputFieldContainer` / `ChatInputRepresentable` / `ChatInputBar`（后三者在 CardFlowView）/ `VoiceRecordController` 均无差异。
- 剩余差异：`InputBarStack` 是 #00498 的草稿持久化与手写 Binding；`KeyboardInsetBridge` / `PagingViewController` 只是将同值 74pt compact 高度从 PagingVC 移到 bridge。T1 已把输入栏退回改版前布局。
- 比较基线时仅暂时还原 T1 五个文件到 f74ed9bd0，其余生产代码本就相同；未切分支、未动 master/其他工位，之后全部恢复开工 HEAD。最终生产改动仅 InputBarStack。

## 根因证据

- 修改前：`4276ef98f:MemoryPalace/Views/InputBarStack.swift:24,101–119` 以 `@State String` 存文本、手写 getter 捕获父 View，然后进入 `.equatable()`。
- `MemoryPalace/Views/CardFlowView.swift:2235–2243` 的相等判断只比较管理器引用和 sticker closure 的 nil 状态，不比较文本 Binding。`InputFieldContainer` 的多行判断与发送/波形选择分别位于 `:2780–2799`、`:3139–3151`。
- 真实整页 T1 日志：`commit(empty) 0→3`、`commit(layout) 3→4`、`commit(debounce) 4→7` 后，`InputFieldContainer.body #62…#66` 仍为 `len=0`。PNG `T1-full-bubble-page-multiline.png` 同时显示完整两行与灰色波形。
- 修复在 `MemoryPalace/Views/InputBarStack.swift:5–9,30,107–125`：旧 String 值镜像换为稳定可观察引用；getter 渲染时读实时 text，子树可自行失效，不需要撤掉性能闸。
- 同一生产路径修复后，日志为 `InputFieldContainer.body ... len=7`，两模式都切到原有多行布局，PNG 显示白箭头/实心发送圆；请求和消息节点均保留 `第一行\n第二行`。
- 此次复现的是 UI 多行/发送态与原生文字失步；未观察到 UITextView 实际删除换行。不能把这个结论扩大成已覆盖 Air 的全部输入法状态。

## 正式红绿对照（完整生产路径，包含发送键 PNG 断言）

| 版本 | 文章模式 | 气泡模式 | 结果包 |
| --- | --- | --- | --- |
| f74ed9bd0，无 T1 | 红 | 红 | `/tmp/hotfix-input-f74ed9bd0-glyph.xcresult` |
| 4276ef98f，带 T1，未修 Binding | 红 | 红 | `/tmp/hotfix-input-T1-glyph.xcresult` |
| T1 + 稳定可观察文本引用 | 绿 | 绿 | `/tmp/hotfix-input-fixed.xcresult` |

两次修复前均是 2 tests / 2 failures，仅失败在“打字后必须显示实心发送圆，不能仍是语音波形”。文本、草稿、长高、真实激活后的 HTTP/SSE 与清空断言未失败。外环亮度：基线文章 0.99027 / 气泡 0.98999；T1 两模式 0.99027；修复后两模式均 0.69350，发送箭头白像素均 299。

## 回归测试与实际运行

`MemoryPalaceIOSTests/BubbleInputRegressionTests.swift` 使用真实 XCTest WindowGroup，挂生产 ContentView → PagingVC → InputBarStack → ChatInputBar → ChatInputRepresentable；`--kb-probe-seed` 走生产 loadConversation。不是替身 Composer。

- 三次连续原生 insertText：第一行、独立换行、第二行；每次立即核对文本，落稳后再核对完整文字、真实 frame 长高、草稿。
- 定位生产 Button，检查屏内几何、祖先可见性、中心 hit-test 和 PNG 白箭头/实心圆；通过公开 `accessibilityActivate()` 激活实际 Button，不直接调回调。
- 隔离 SwiftData 全内存库、临时 profile 根、随机端口 HTTP 服务；真实 ProviderRouter/OpenAI 请求发到本机并处理固定 SSE。断言原文、user 节点、assistant 完成、队列为空、输入与草稿清空。
- 测试关闭合成会话的记忆；不把该场景说成已测 wiki 预热超时/失败。
- `xcodegen generate`；修复后 MemoryPalaceIOS、MemoryPalaceIOSTests 与 mac MemoryPalaceTests 均出现 `** TEST BUILD SUCCEEDED **`。编译使用指定目的地与全机锁，无 derivedDataPath；每次编译前 Data 卷 58–70GiB，未低于 15GiB。
- mac 最终：InputBarHitRuleTests 5、VoiceRecordGestureTests 10、InputBarDraftPersistenceTests 6、MacComposerDraftTests 8，合计 29/29；`/tmp/hotfix-input-mac-fixed.xcresult`。
- iOS：新回归 2/2，BubblePageSnapshotTests 1/1，合计 3/3；`/tmp/hotfix-input-fixed.xcresult`。
- 两模式原生字段高度均 40.667 → 57.667pt，发送键均 `(329,468,44,44)`，各 1 次 HTTP 请求、回复 `Input delivered.`。已阅读两张真实窗口 PNG，均显示完整两行与发送箭头。

## 宿主校准与假绿记录

最初公开 AX 遍历为空，是宿主没有启用系统 accessibility automation；采用 [AccessibilitySnapshot/KIF 的初始化做法](https://github.com/cashapp/AccessibilitySnapshot/blob/main/Sources/AccessibilitySnapshot/Parser/ObjC/ASAccessibilityEnabler.m)，测试内加载 libAccessibility、开启 automation，结束恢复原值。按钮定位和激活仍用公开 API，不替换生产按钮。

早期直接挂真实 Stack 和整页的“HTTP 发送成功”检查曾绿，但遗漏了按钮图案：AX 激活在渲染事务外能读到 live binding，即使屏上还显示波形也可能发送。正式回归必须包含 PNG 断言；早期绿色不能充当最终验收。

最终像素检查仅展开按钮裁剪区域，不分配整屏 RGBA 缓冲。全程未装真机、未 push/提交合并队列、未修改 settings/CLAUDE/tasks。

## 媒体

`~/MemoryPalace-docs-media/docs/imessage-ref/ours/hotfix/`

- 修复前：`f74ed9bd0-glyph-*-page-multiline.png`、`T1-glyph-*-page-multiline.png`。
- 修复后：`fixed-*-page-multiline.png`、`fixed-*-page-final.png`、`fixed-*-page-evidence.json`。
- 整页对拍：同目录 `preview-*`、`keyboard-follow-evidence.json`、外观/弹泡截图。

## 收尾

- 最终按钮裁剪采样版本复跑：`/tmp/hotfix-input-fixed-repeat.xcresult`，新回归 2/2，像素与 frame 证据同首轮修复后结果；媒体文件前缀 `fixed-repeat-*`。
- 专用模拟器已用 simslim（CoreSimulator 生命周期封装）关闭，随后 list 观察到 `6CA4B302-A610-4254-8D66-85D5019C0518` 为 `Shutdown`。
- 复盘：[review-hotfix-input.md](review-hotfix-input.md)；工位状态：[now/hotfix.md](now/hotfix.md)。
