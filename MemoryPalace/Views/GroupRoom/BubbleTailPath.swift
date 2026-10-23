import SwiftUI

/// UIKit 气泡用的泡形（群聊 cell 的 CAShapeLayer / 长按预览 visiblePath）。
/// 直接取 `BubbleTailShape.path(in:)` 的几何转 CGPath，不另抄一份——那套尾巴系数是粟粟亲手调的，
/// 两份拷贝迟早漂；主体同样是系统连续曲率圆角（SwiftUI `.continuous`，r 接近高度一半时也不跳形）。
/// 尾巴点按 `r * tailScale` 算，主体圆角仍是 r（群聊 0.8）。
enum BubbleTailPath {
    static func cgPath(in rect: CGRect, isUser: Bool, radius: CGFloat, hasTail: Bool, tailScale: CGFloat = 1) -> CGPath {
        BubbleTailShape(isUser: isUser, radius: radius, hasTail: hasTail, tailScale: tailScale)
            .path(in: rect)
            .cgPath
    }
}
