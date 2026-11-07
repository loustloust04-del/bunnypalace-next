# 编辑器方向 A · 切片 7 复盘

## 1. 边界情况

- 10-16 粟粟：好（照推荐）。每份文档沿用新建 sheet / WKWebView / CM 的生命周期；首次原生载入不入栈，不能撤成空文件。没有增加同文档清栈策略。
- 同文档重新载入 / 恢复 / 换回 / 源码提交统一走 `replaceEditorDocument`：`minimalChange` 保留公共前后缀，`isolateHistory("full")` 隔离前后历史，各自可整步撤回 / 重做。后续普通输入不会并入该步；有变化的新写入按 CM 规则截断旧 redo 分支。
- 同正文显式写入仍推进 nativeRevision 并取消替换前的防抖，但不发无变化 transaction，不制造历史步、不丢 redo。输入尚未上报时的替换以 JS 当前正文为撤回基线，不以 Swift 旧镜像代替。
- 源码输入仍只改 sourceDraft，源码模式本地撤 / 重做归原生 TextEditor UndoManager；退出有净修改才向隐藏 CM 提交一次。源码临时编辑后撤回到基线，不制造 CM 步骤、不截断原 CM redo。
- 保留版本存储格式、`recordVersion`、保存 / 冲突基线 / 恢复标记 / 换回提示的全部落盘行为；CM 撤销不回滚已写入磁盘的文件或版本记录。

## 2. 与后续工作的交互风险

- 这里的统一账本仅指实时模式的所有编辑入口。没有原生与 CM 跨模式逐键共享撤销，也没有 UndoManager 代理；浮条 / 格式条 / 硬件快捷键仍走原来的模式分派。
- 初始化边界依赖每份文档独立的编辑器生命周期，不能把另一份文档复用成现有实例的同文档 `replaceDocument`。现有打开另一份文档的生命周期回归覆盖该边界。
- 恢复后「换回」仍是显式正文写入，和撤回恢复不是同一动作；二者各自进历史，不更改版本历史来源和保存时机。
- 源码 / 实时视口不对齐 #7 不在本片修复范围；历史正确不代表 iOS 原生选区、输入法与键盘几何已验收。

## 3. 技术债务 / 验证限制

- 删除同文档显式写入一律 `addToHistory(false)` 的规则，只保留首次载入的排除；删除「恢复不进撤销历史」矛盾注释。源码期间逐键映射旧 CM 的路径在切片 6 已移除，本片不重新引入。
- bundle 只新增实际使用的 `isolateHistory` 导出；不额外引入 history / Compartment / 清栈 API。重建脚本同时校验该导出，bundle / VERSIONS 同片提交。
- 新增 / 更新真实 WKWebView 回归：未回报输入→多次替换（含空正文）→后续输入的完整撤 / 重做；同正文不丢 redo、新替换截断旧 redo；另一份文档无历史继承；真实 NSSegmentedControl / TextEditor 覆盖打字→格式→源码多次编辑→切回逐基线撤 / 重做及即时保存，源码编辑后本地撤到原文不制造 CM 步骤。原跨行删除回归改为用首次载入布置文档，不把其准备数据伪装成同文档外部操作。
- 修改前 Chromium 真实页面证明：输入后恢复正文，撤回不能回到恢复前正文。修改后实际键入、格式命令、显式源码提交、前后输入隔离、多次外部替换、空正文、无变化保留 redo、重载页面换文档边界均通过；截图目视，console / JS error 为空，页面已关闭。浏览器的源码提交只验证 JS 协议，原生 TextEditor 交互由 WK 单测覆盖。
- 双端构建与回归原文记录在[计划](plan-editor-converge-A.md)的切片 7 验证记录；iOS 实际软硬键盘、浮条、候选确认、恢复 / 换回 / 重载时的原生时序仍交车头验。不安装、不 boot / shutdown / erase 模拟器、不碰真机、不 device-lease、不 push / merge-queue submit。
- macOS 新用例首轮失败时，直接调用 UndoManager 后 NSTextView 正文已撤回，但没有触发 SwiftUI Binding 的正文回报。夹具在该调用后用 AppKit `didChangeText()` 完成文本变更通知，再切模式验证 CM redo；不直接写 Binding、不修改预期、不替换 CM 历史。其他 hosting / responder 路径和直接 State Binding 的诊断改动均已撤掉；生产原生撤销桥未改。该夹具不验证真实 macOS 快捷键的通知链，也不代替 iOS 原生撤销验收；API 文档：[didChangeText](https://developer.apple.com/documentation/appkit/nstextview/didchangetext())。
