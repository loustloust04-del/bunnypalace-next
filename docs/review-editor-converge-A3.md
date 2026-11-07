# 编辑器方向 A · 切片 3 复盘

## 1. 边界情况

- 仅 markdown-editor 使用专用 WKWebView：禁外层滚动 / bounce、`.never`，layout 后把原生 inset / offset 归零；不替换 scroll delegate，不改变手册 / HTML 预览默认配置。SwiftUI 负责 frame，CM 负责正文内滚。
- iOS 的 window / visualViewport resize、scroll 先复位 window，再下一帧复核；不加 fixed / translateY，不假定 innerHeight 恒定。
- 删除 `keepCaretVisibleOnShrink`、`lastEditorHeight` 及其生产 ResizeObserver。CM geometryChanged 仅在点按后 1 秒内检查光标是否被挡，测量周期读几何后最小滚动；窗口外不追光标。DEBUG ResizeObserver 探针仍保留。
- 浮条不加固定占位；删除独立 0.18 秒动画，在 willShow / willHide 的同次通知中按通知时长更新。标准曲线 0–3 对应 SwiftUI 曲线；系统私有曲线 7 退为 easeInOut，不声称逐帧匹配系统弹簧。

## 2. 与下一切片的交互风险

- `PagingViewController.keyboardFrameWillChange` 只写自身 hostingControllers 的 additionalSafeAreaInsets，sheet 是单独呈现的 hosting 层；未把聊天页的 inset 补偿移植到编辑器。该判断来自代码范围，实际视图树与键盘几何仍交车头采样。
- 不移除 WebKit 私有键盘通知，也不做全局 swizzle；`.never` 不等于禁止 focus reveal。原生 layout 归零与 JS 复位是否覆盖所有 iOS 26 时序，需要设备探针确认。
- Enter / 跨行删除入口暂未改，后续切片 4 接管 beforeinput。装饰和块高度变化由切片 5 处理，不能把本片桌面 resize 冒烟当作它们的验收。

## 3. 技术债务 / 验证限制

- Chromium 真实 HTML / JS / bundle：390×700 缩为 390×430 后光标 top / bottom 407 / 425，scroller 0–430，windowY=0；截图目视通过，无 JS error。点按超过 1 秒后手动滚到 700，再改 700×550，scrollTop 保持 700，innerHeight / visualViewport.height 均 550。
- 原生编译和相关回归原文统一记入 [计划](plan-editor-converge-A.md)。不操作设备；屏底 / 屏中、深滚、键盘弹收与中途打断、横竖屏、窄屏浮条 / iPad 宽屏的几何与偏移验收交车头。
- 无新增 Swift 文件，无 bundle 改动，无永久接线或源码字符串测试，无私人样本入库。
