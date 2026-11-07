# 编辑器方向 A · 切片 2 复盘

本片按 10-15 粟粟拍板：编辑器关闭系统编辑手势，全 App 关闭摇一摇；浮条 / CM 硬件快捷键保留。实施与验证原文见[计划](plan-editor-converge-A.md)，车头的切片 1 设备复测原样附在[复现报告](repro-editor-undo-flicker.html)末尾。

## 1. 边界情况

- `WebViewHost` 只为 `markdown-editor` 资源启用关闭，其他预览 / 手册 WebView 不调用新辅助方法；macOS 不编译 UIKit 实现。
- `didFinish` 先走现有去 accessory 覆盖，再给 WKWebView / 内层 WKContentView 的 `editingInteractionConfiguration` 返回 `.none`。在当前动态类上叠加，保留 accessory getter；避免加载前抢先换类让原有 `hasPrefix("WKContent")` 查找失效。已为 `.none` 的实例不重复套类。
- 沿用现有 Objective-C runtime 子类模式，无全局 swizzle，无 UndoManager 代理。内容视图查找或动态类创建失败时不改实例；具体 iOS 26 WKContentView 识别和系统手势实效仍须设备验收，编译成功不证明这些运行时路径通过。
- `PushAppDelegate` 启动回调在通知授权 / 测试模式提前返回之前设置 `applicationSupportsShakeToEdit = false`。这是批准的全 App 行为，关闭编辑器后不恢复；其他文本框三指行为不在本片修改范围。
- 没有改 JS、CM 历史、选区菜单、硬件按键处理、源码 TextEditor、存储和版本历史格式。三指手势关闭后，长按选区 / 复制粘贴及键盘附件条是否正常仍待设备确认。

## 2. 与下一切片的交互风险

- 系统手势不再计划映射 CM，不实现之前推荐的 WKContentView.undoManager 代理或 em 回放。后续不要把两条旧路线重新叠回本片。
- 车头已证实切片 1 的 #1–#6、#8 和已测闪烁通过；#7 源码 / 实时视口不对齐仍在。本片不修改滚动、键盘、beforeinput、装饰或跨模式历史。
- 后续方向 A 在计划中重编号为切片 3–7，仍需依据复测剩余现象授权，不自动推进。组字中途保存 / 切源码可能收到标记文本的边界沿用复测报告观察，不在本片悄悄扩修。
- 车头安装本片提交对应 DEBUG 包并开 `MP_EDITOR_PROBE=1`：确认三指左 / 右滑和双击不再触发系统编辑历史 / 工具条，摇一摇不弹撤销；浮条、⌘Z / ⌘⇧Z、选区 / 复制粘贴、关闭重开及切源码正常。其他输入框三指行为应不变，摇一摇全 App 禁用。

## 3. 技术债务 / 验证限制

- macOS 指定 build-for-testing：`** TEST BUILD SUCCEEDED **`。FileEditorUndoTests / FileEditorTextModeTests：两类均 `passed`，共 6 项、0 failures；真实 sheet / WKWebView / CM 回归覆盖旧回声、撤 / 重做、源码编辑与保存，不当作 UIKit 手势验收。
- iOS 首次构建退出 65：合入 master 新增的 LaunchResume.swift 未进入旧生成工程，导致 LastLocationResume / LaunchResumeMarker 找不到。执行 `xcodegen generate` 后，同一指定 iOS 26.4.1 目的地 / 命令出现 `** TEST BUILD SUCCEEDED **`。不修改这些功能源码，不绕编译 shim，无 exit 75。
- 本片未新增 Swift 文件、未改 JS / bundle、无新增永久接线测试或临时测试脚本。复测附录按原始字节验证，完整插到报告末尾闭合标签前。
- 本轮不安装、不启动 / 关闭 / 擦除模拟器、不碰真机；系统手势和摇一摇尚未实测。本片提交后停下，由车头安排设备验收；不 push、不 merge-queue submit。
