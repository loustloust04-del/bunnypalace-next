#if os(iOS)
import SwiftUI

struct Page2SystemMetrics {
    let columns: Int
    let contentWidth: CGFloat
    let small: CGFloat
    let largeHeight: CGFloat

    init(width: CGFloat, height: CGFloat) {
        columns = width > height * 1.3 ? 6 : 4
        let portraitWidth = columns == 4 ? width : min(width, 430)
        if portraitWidth >= 440 { contentWidth = columns == 4 ? 378 : width - 48; small = 530.0 / 3.0; largeHeight = 394 }
        else if portraitWidth >= 428 { contentWidth = columns == 4 ? 364 : width - 48; small = 170; largeHeight = 382 }
        else if portraitWidth >= 414 { contentWidth = columns == 4 ? 360 : width - 48; small = 169; largeHeight = 379 }
        else if portraitWidth >= 390 { contentWidth = columns == 4 ? 338 : width - 48; small = 158; largeHeight = 354 }
        else if portraitWidth >= 375 && height > 500 { contentWidth = columns == 4 ? 329 : width - 40; small = 155; largeHeight = 345 }
        else if portraitWidth >= 375 { contentWidth = columns == 4 ? 321 : width - 40; small = 148; largeHeight = 324 }
        else if portraitWidth >= 360 { contentWidth = 329; small = 155; largeHeight = 345 }
        else { contentWidth = width - 28; small = 141; largeHeight = 311 }
    }

    var dockCornerRadius: CGFloat { 37 }
    var dockVerticalInset: CGFloat { 24.5 }
    var dockBottomExtension: CGFloat { 17 }

    var horizontalGap: CGFloat { columns == 4 ? contentWidth - 2 * small : 22 }
    var columnWidth: CGFloat { (contentWidth - CGFloat(columns - 1) * horizontalGap) / CGFloat(columns) }
    var columnPitch: CGFloat { columnWidth + horizontalGap }
    var rowPitch: CGFloat { (largeHeight - small) / 2 }
    var verticalGap: CGFloat { rowPitch * 2 - small }
    var iconSide: CGFloat { small > 174 ? 68 : (small >= 169 ? 64 : 60) }
    func width(_ span: Page2Span) -> CGFloat { CGFloat(span.columns) * columnPitch - horizontalGap }
    func height(_ span: Page2Span) -> CGFloat { CGFloat(span.rows) * rowPitch - verticalGap }
}
#endif
