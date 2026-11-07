# 编辑器方向 A · 切片 4 复盘

## 1. 边界情况

- 删除旧 `interceptIOSEnter`、capture keydown 注册及所属旧注释。生产仅 iOS 安装一个 CM ViewPlugin；keydown 只 stopPropagation，不 preventDefault；beforeinput 才取消原生换行并执行一次 keymap，不派合成 DOM keydown。
- `insertParagraph` / `insertLineBreak` 同步 DOM anchor / head 后执行 CM keymap；Shift-Enter 保留。Backspace / Delete 只接管空选区行首 / 行尾跨行删除，不接管行内、选择删除或词删除，不拦 ctrl / alt / meta keydown。
- 只处理 contentDOM、可编辑、非只读、非组字输入；keyCode 229 不接管。500ms 未收到 beforeinput 执行一次，之后 1 秒内匹配的迟到 beforeinput 吞掉；新 keydown 可以开启下一次操作。plugin 销毁清 timer / listener。
- bundle 按既有脚本重建；新增 EditorSelection / runScopeHandlers / deleteCharBackward / deleteCharForward 和 StateEffect 导出，StateEffect 用于真实 WKWebView 回归安装同一输入扩展，后续装饰刷新也复用。

## 2. 与下一切片的交互风险

- DOM 选区先于 CM 状态时以 DOM 为准；多选区或 DOM 不在编辑区时沿用 CM 选区。不改变普通输入 / 组字的 DOMObserver 路径。
- keymap 仍复用现有列表续行、空列表退出、缩进与删除命令；未动 CM history 配置和外部替换不入历史的既有规则。切片 5 负责手势期间装饰保留，不能靠本片事件取消证明块级装饰稳定。

## 3. 技术债务 / 验证限制

- Chromium 实际页面安装生产输入扩展：编号续行为 `1. 项\n2. `，空列表退出为空，Backspace / Delete 合并为 `甲乙`，Shift-Enter 为 `甲\n乙`；各一次 revision 变化，keydown 不取消默认、beforeinput 取消默认。
- 原生 DOM caret 在 CM 未同步时换行为 `原\n文`；普通行内删除、组字 Enter 未被接管。缺失 beforeinput 的 Enter fallback 后，迟到事件净修改 0；真实键入 abc + Enter 最终为 `等待\nabc\n`。截图目视通过、无 JS error，页面已关闭。
- 永久回归放现有 FileEditorUndoTests：检查真实 WKWebView / CM 的 DOM caret、精确一次修改及可撤销恢复，跨行删除 fallback 与迟到事件不重复消费。双端构建 / 回归原文见 [计划](plan-editor-converge-A.md)。
- 不操作设备。屏底连续 Enter、WebKit 是否居中、硬件键盘、粘贴后首键、拼音候选确认及 iOS beforeinput 时序交车头；Chromium 不替代设备验收。无临时脚本或私人样本入库。
