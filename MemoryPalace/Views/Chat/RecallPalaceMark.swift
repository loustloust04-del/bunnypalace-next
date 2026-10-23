import SwiftUI

/// 小样中的宫殿门廊：外拱、内门和门槛，24×24 自绘路径。
struct RecallPalaceMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 5, y: 20.5))
        path.addLine(to: CGPoint(x: 5, y: 11))
        path.addCurve(to: CGPoint(x: 19, y: 11), control1: CGPoint(x: 5, y: 1.67), control2: CGPoint(x: 19, y: 1.67))
        path.addLine(to: CGPoint(x: 19, y: 20.5))
        path.move(to: CGPoint(x: 9.5, y: 20.5))
        path.addLine(to: CGPoint(x: 9.5, y: 15))
        path.addCurve(to: CGPoint(x: 14.5, y: 15), control1: CGPoint(x: 9.5, y: 11.67), control2: CGPoint(x: 14.5, y: 11.67))
        path.addLine(to: CGPoint(x: 14.5, y: 20.5))
        path.move(to: CGPoint(x: 3, y: 20.5))
        path.addLine(to: CGPoint(x: 21, y: 20.5))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
