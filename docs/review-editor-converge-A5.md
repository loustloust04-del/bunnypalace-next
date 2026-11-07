# 编辑器方向 A · 切片 5 复盘

## 1. 边界情况

- inline / table / frontmatter 共用 interaction StateField / StateEffect。pointerdown 捕获旧选区，手势中只映射原装饰；document pointerup / pointercancel 后下一帧统一刷新。多指未全部释放不刷新，window blur 清理状态，destroy 清监听 / rAF。
- compositionstart 后只映射，不把候选区域重建成 widget；compositionend 下一帧统一刷新。源码露出状态保留；undo / redo 只映射 typingRevealField，真正的光标移动后才收回。
- 表格 / 属性卡有 estimatedHeight，按行数、单元格 / 字段长度、可用宽度及实际 CSS 行高保守估算。CM requestMeasure 的 read 阶段读取宽度、字体和 widget 高度；高度按内容 + 宽度 + 字体缓存（最多 128 项），变化后新 key 不复用旧尺寸。
- 缓存只记 DOM rect 高度，与 CM measureVisibleLineHeights 一致，不把属性卡外 margin 再算进块高；避免滚动锚点相差 12px。

## 2. 与下一切片的交互风险

- 手势 / 组字结束与显式替换均仍经过同一 CM 事务链；切片 6 更换正文协议时必须保留 interaction / typing 状态，不重建整个编辑器或清 history。
- block decoration 仍由 StateField 提供，inline 仍为 ViewPlugin；未并用另一套 select.pointer 特判时序。表格 / 属性卡点按语义与现有源码露出设计不变。
- 本片冒烟抓到 CM 禁止在 requestMeasure.write 中同步 dispatch 的错误；布局 effect 改为测量完后的 microtask。切片 3 的光标测量同样修正，保留原 1 秒窗口与最小滚动语义。这是本片唯一跨回切片 3 的修正，非新增交互。

## 3. 技术债务 / 验证限制

- Chromium 真实指针按下表格时，尾正文 top 始终 258.78125，表格高 66；释放下一帧才露源码。属性卡同样在按住期间尾正文 top 固定 264.78125，释放后露源码。
- undo 后链接源码仍完整 `[链](https://example.test/long-target)`，真正移动光标后才收成 `链`。合成 composition 输入期间表格沿用原装饰，结束后候选字仍在正文且源码可见；不称为真实拼音验收。
- 60 行表格可用宽 650→350，高度 1747.5→2937；字号 13→16 后实测高 3486，尺寸 key 更新。最终缓存高与 DOM rect 都为 2937；真实滚轮 500→1000→500，windowY=0；已截图目视。最终缩高 430→250，光标 232–250 可见；console / JS error 均无新增，所有浏览器页已关闭。
- 永久回归在 FileEditorUndoTests 增加撤销保留源码 / 实际移动才收回，以及表格手势中尾正文几何不变 / 释放才露源码。双端构建及定向回归原文见 [计划](plan-editor-converge-A.md)。
- iOS 长按 / 拖拽选区（含系统原生选区柄是否产生网页 pointer 事件）、表格与属性卡边界、横竖屏 / iPad 宽度、真实中文组字及滚动锚点留车头设备验。无新 Swift 文件，无新 bundle 导出，本片不需重打包。
