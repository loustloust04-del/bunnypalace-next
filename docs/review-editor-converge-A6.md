# 编辑器方向 A · 切片 6 复盘

## 1. 边界情况

- 实时正文归 JS。`configure` 不带 content / revision；全文独立 `replaceDocument(content, nativeRevision)`，coordinator 按原生操作标识去重后才序列化。初始化只发送一次，不拿最新 Binding 字符串猜来源。
- 每个原生操作内 JS revision 递增；原生操作序与 JS 输入版本互不比较。JS 拒绝重复 / 更旧的原生操作，合法新操作取消旧防抖并优先落地；Swift 拒绝替换前迟到的 contentChanged / requestSave，以及操作内乱序或同版本不同正文的快照。
- 重载 / 恢复 / 换回是显式原生写入，即使正文等于最近镜像也推进操作标识，避免未上报输入使该操作被跳过。源码输入只改 sourceDraft；退出源码有净修改才提交一次，无净变化不制造操作。
- 实时保存 / 切模式 / 关闭 / 复制 / 打开查找和版本历史 / 双链自动保存先等 token 对应的 flushed 快照，再按请求顺序读取；等待期间显式原生替换优先，迟到 flush 不把旧正文写回。源码保存读原生草稿。查找高亮 / 替换读 JS 当前文档，Swift 状态计数读最多 180ms 防抖的确认镜像，打开查找先 flush。
- 待上报窗口首个编辑只传 documentChanged 元数据启用保存；后续仍按 180ms 上报全文。这不是增量文本协议，不宣称完全不传全文。

## 2. 与下一切片的交互风险

- 仍是 minimalChange + addToHistory(false)。本片没有把重载 / 恢复 / 换回变成可撤销动作，也没有把源码提交加入 CM 历史，更没有给源码 TextEditor 与 CM 共用一本逐键撤销账。
- 切片 7 的 isolateHistory / 源码切回合成一步交互必须等粟粟拍板。U2 / U3 的历史映射问题不以本片协议修复冒充解决。
- 位置存储格式、FileVersionStore 格式、落盘 / 冲突检测未改；原有源码 / 实时视口不对齐 #7 也不宣称在本片解决。

## 3. 技术债务 / 验证限制

- FileEditorUndoTests 改成新契约的真实 WKWebView 回归：配置变化保留正文 / 选区 / undo / redo，新原生写入覆盖未上报输入，两次迟到快照和旧保存不能覆盖新正文，180,000 字符大文档配置变化后末尾完整保存。删除旧 setContent 回声契约测试和 recorder，不保留兼容入口。
- FileEditorTextModeTests 真实切 NSSegmentedControl：180ms 内输入后切源码拿到末尾，两次源码输入不改隐藏 CM，切回 nativeRevision 仅推进一次，随后立即保存精确包含新末尾。
- 临时 IPC 观测（已删除）：180,002 字符文档完成输入 / 查找 / 行号重算和保存后，原生→JS 仅两条 configure，均无正文；JSON.stringify(...).length 为 179 / 180（UTF-16 长度，日志字段叫 bytes，但不作为字节数使用）。原文见计划。
- 切片 5 的真实手势浏览器证明保留。macOS 回归中，窗口 orderFront 仍不足以保证 WK 的 rAF 在全套执行时前进；永久状态转换回归仅在 pointerup 的有界范围控制下一帧时钟，立即恢复原调度器，仍检查真实 CM / DOM 的尾正文几何和释放后源码。未把生产 rAF 改成 timer，未缩窄断言。
- Chromium 实际键入 + flush、未回报输入后的显式替换 / 去重 / 保存、CDP composition 确认后立即保存、inactive flush 均通过。主题 / 查找配置前后正文不变。共享浏览器截图通道在 IME 会话后超时，另起独立 Chrome 打开实际页面完成截图目视，console 无错误；所有页面已关闭，不把截图超时当产品修复证据。
- 双端构建 / 最终回归原文见 [计划](plan-editor-converge-A.md)。不操作设备；iOS 真实输入法候选确认、键盘 / 原生选区与即时保存、恢复 / 换回 / 重载并发输入仍交车头验。没有新 Swift 文件、未改 bundle、未新增存储格式或重试。
