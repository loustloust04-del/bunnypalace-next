import SwiftUI

/// UIKit 气泡用的泡形（群聊 cell 的 CAShapeLayer / 长按预览 visiblePath）。
/// 直接取 `BubbleTailShape.path(in:)`，与一对一共用实测尾巴，避免两份曲线漂移。
/// 主体仍为系统连续曲率圆角；群聊只把尾巴缩至0.8，圆角与正文布局不变。
enum BubbleTailPath {
    static func cgPath(in rect: CGRect, isUser: Bool, radius: CGFloat, hasTail: Bool, tailScale: CGFloat = 1) -> CGPath {
        BubbleTailShape(isUser: isUser, radius: radius, hasTail: hasTail, tailScale: tailScale)
            .path(in: rect)
            .cgPath
    }
}
