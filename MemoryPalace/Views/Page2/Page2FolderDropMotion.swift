#if os(iOS)
import SwiftUI
import UIKit

struct Page2FolderDropMotion {
    static let duration: TimeInterval = 0.576667
    static let first = CGPoint(x: 0.465, y: 0)
    static let second = CGPoint(x: 0.255, y: 1)
    static var animation: Animation { .timingCurve(first.x, first.y, second.x, second.y, duration: duration) }
}

#endif
