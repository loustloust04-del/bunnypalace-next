import Foundation
import CoreGraphics

struct Page2FolderEntry {
    let origin: CGPoint
    private(set) var entered = false

    mutating func contains(_ point: CGPoint, panel: CGRect) -> Bool {
        if panel.contains(point) { entered = true; return true }
        if entered { return panel.insetBy(dx: -14, dy: -14).contains(point) }
        let originArea = CGRect(x: origin.x - 24, y: origin.y - 24, width: 48, height: 48)
        return panel.union(originArea).contains(point)
    }
}
