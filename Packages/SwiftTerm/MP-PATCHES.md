# SwiftTerm 入库说明

- 来源：https://github.com/migueldeicaza/SwiftTerm tag `v1.13.0`（commit `8e7a1e154f470e19c709a00a8768df348ba5fc43`），`git archive` 原样取出 `Package.swift`、`LICENSE`、`README.md`、`Sources/`、`Tests/`、`Benchmarks/`（没带示例 app `TerminalApp/`、CI 配置）。
- 为什么入库：#087 中文字距要改宽字符的绘制，CoreText fallback 字号没有外部接口能改（见 `docs/research-terminal-render-fix.md` §1）。
- 改动一律单独 commit、前缀 `SwiftTerm patch`，升级上游时按下面清单逐条重放。

## 补丁清单

0. `Package.swift` 只留 `SwiftTerm` 库和 `SwiftTermTests`，去掉 fuzz / termcast / 基准 target 及其外部依赖（`Sources/SwiftTermFuzz`、`Sources/Termcast`、`Sources/CaptureOutput`、`Benchmarks/` 原样留着但不参与编译）。
1. 两格宽 fallback 字形填满两格（#087 中文字距）：新增 `Sources/SwiftTerm/Apple/WideGlyphFit.swift`；`AppleTerminalView.swift` 字形循环里两格宽段落改走 `wideSegmentLayout` / `drawWideItems`（一格段落照上游 `CTFontDrawGlyphs`），`updateCursorPosition` 让光标压在宽字符上时变两格宽；`CaretView.swift` 两格宽光标里的字走同一套排法。以 fallback 字体里「水」的字宽为准往两格放大（Ghostty ic_width 归一化），封顶 `maxScale` = 1.03（填满两格≈1.24 倍，粟粟 10-14 嫌字大），字身框在两格里居中，上限还有格高、墨迹不出槽；主字体自带的宽字形不放大。一格里的组合字形（CoreText 常把组合符号拆成另一个 run、带竖向偏移）按字符串下标认回基字那一格，整格统一缩放、保留 shaping 的相对位置，限高按整格墨迹（含偏移）算——顺带修了上游把这种组合符号画到下一格的问题（只限两格宽段落；上游的背景色循环仍按字形数算格，带组合符号又带背景色的宽字符背景会偏一格）。字形字宽 / 墨迹按（字体名、字号、字形号）缓存。测试 `Tests/SwiftTermTests/WideGlyphFitTests.swift`。
   - **Metal 渲染路径没走这个补丁**（`Apple/Metal/MetalTerminalRenderer.swift` 的 glyph atlas 与光标）。我们没调用 `setUseMetal`，所以没移植；**启用 Metal 前必须把补丁移植到 atlas 和光标**。
   - **升级上游时不能原样重放**：v1.14.0 起上游自己有了 `glyphSlotFit` / `glyphPositions`（宽字形居中 + 出格缩小，CoreGraphics 与 Metal 共用）。手工移植：把「按『水』归一化放大」接到上游统一的 fitting 入口（让它算出的 scale 允许 > 1、字身框按参照字宽居中、组合字形整格统一），不要在上游那套之外再叠一层缩放；光标改宽上游也已做，保留上游的。
