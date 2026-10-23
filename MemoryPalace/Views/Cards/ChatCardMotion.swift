import SwiftUI

/// 卡片动效（research-chat-cards §10.0）：只用这几条弹簧，最多轻微超调；拖过端点走橡皮筋；减弱动态效果时只淡入淡出
enum ChatCardMotion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let morph = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let draw = Animation.spring(response: 0.9, dampingFraction: 0.9)
    /// 尾随边：比 snappy 慢，领先边先到、尾随边后到 → 移动时自然拉伸
    static let trail = Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let fade = Animation.easeOut(duration: 0.2)

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }

    /// 内容切换：短暂模糊替换；减弱动态效果时只淡入淡出
    static func contentTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace)
    }

    /// 拖过端点：超出部分 × resistance，最多再伸出 maxStretch（不拉出卡片外）
    static func rubberBand(_ x: Double, in range: ClosedRange<Double>, resistance: Double = 0.35, maxStretch: Double = 0.15) -> Double {
        if x > range.upperBound { return range.upperBound + min((x - range.upperBound) * resistance, maxStretch) }
        if x < range.lowerBound { return range.lowerBound - min((range.lowerBound - x) * resistance, maxStretch) }
        return x
    }
}
