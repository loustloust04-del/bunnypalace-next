# 编辑器方向 A · 切片 1 复盘

本片只修「新 revision + 旧正文」回声。失败基线：[模拟器复现](repro-editor-undo-flicker.html)；实施、验证原文和交接：[计划](plan-editor-converge-A.md)。

## 1. 边界情况

- `FileEditorSheet` 的正文 / revision 是同一个 `@State` 值快照，`contentChanged` 一次替换；正文回到原样也接收新 revision。主题、历史按钮等 SwiftUI 重算只能读到同一份快照，不再跨父子状态拼字段。
- 源码编辑、重新载入、恢复版本和「换回」经原有正文入口做快照替换，正文实际变化才推进 revision。版本格式、存储、保存和外部替换不入 CM 历史的现有语义未改。
- JS 的防抖与 flush 共用上报入口，先记录该 revision 的已上报正文再发消息。同 revision、不同正文在改 content / CM / textarea 前丢弃；较小 revision 继续拒绝。未上报过的初始 revision 不误拦首次载入，较高原生 revision 被接受并同步到 JS 时钟。
- `requestSave` 带当前正文和 revision，Swift 用同一快照接收；不必等 180ms 才保存，未新增保存队列或重试。
- Chromium 实际输入后的错误回声没有改变正文、选区或 undo / redo 深度；撤销后的回声没有清 redo。首次载入不可撤空、全选删除、较高原生版本、无净变化上报、未防抖保存均已定向冒烟。没有把这些结果当成 iOS 组字或系统撤回验收。

## 2. 与下一切片的交互风险

- 仍使用单个 revision 时钟和常规全文回声。本片没有解决原生替换与尚未上报的网页输入同时发生时的优先级；后续「文本单向 + 原生版本确认」须设计独立原生操作标识，不能在本片之上再猜正文来源。
- 外部写入仍是 `minimalChange + addToHistory(false)`；跨模式历史断层、系统 undoManager、装饰跳动和键盘滚动策略都未改。先由车头复测旧回声，再决定剩余方向 A 是否需要实施。
- 系统撤回手势仍推荐第二档、等待粟粟拍板；本片既未关摇一摇，也未覆写 WKContentView。
- DEBUG 探针沿用切片 0，默认关闭。设备复测需开启 `MP_EDITOR_PROBE=1` 并新建编辑器，比较 inputType、CM 历史和四种滚动 / 视口数据；不靠最终截图推断无闪帧。

## 3. 技术债务 / 验证限制

- 永久回归写在现有 `FileEditorUndoTests`，运行真实 SwiftUI sheet、WKWebView、网页 JS 和 CodeMirror，检查原生回推快照成对、同 revision 错正文、撤销 / 重做及同正文新 revision；不使用源码字符串断言或模拟历史栈。
- 本片未新增 Swift 文件，JS 是 HTML 直接加载的源码；不需要 xcodegen 或 CM bundle 重打包。没有临时测试脚本或私人测试内容入库。
- macOS / iOS 26.4.1 指定 build-for-testing 均 `** TEST BUILD SUCCEEDED **`；`FileEditorUndoTests` / `FileEditorTextModeTests` 共 6 项、0 failures，含两个新增 WKWebView 回归。编译 / 单测原文见计划。iOS 安装与设备交互全留给车头；报告 #1–#5、#8、10a–10g、首次打开不可撤空及原生正文入口都需设备复测。
- 浏览器 Control+Z 工具调用中断已报告；实际冒烟改走编辑器既有命令通道，不宣称浏览器快捷键通过。浏览器页面均已关闭。
