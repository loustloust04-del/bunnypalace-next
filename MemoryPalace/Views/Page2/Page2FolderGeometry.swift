#if os(iOS)
import SwiftUI

struct Page2FolderGeometry {
    static let referenceWidth: CGFloat = 335.5
    static func panel(in size: CGSize) -> CGRect {
        let unit = min(1, max(260 / referenceWidth, size.width / 440))
        let width = referenceWidth * unit, height = 379 * unit
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
    static func iconSide(in panel: CGRect) -> CGFloat { 68 * panel.width / referenceWidth }
    static func childFrame(_ index: Int, in panel: CGRect) -> CGRect {
        let unit = panel.width / referenceWidth, side = iconSide(in: panel), inset = 33 * unit
        let pitch = (panel.width - 2 * inset - side) / 2
        return CGRect(x: panel.minX + inset + CGFloat(index % 3) * pitch,
                      y: panel.minY + inset + CGFloat((index % 9) / 3) * 112 * unit, width: side, height: side + 20)
    }
    static func insertionSlot(at point: CGPoint, in panel: CGRect) -> Int {
        let unit = panel.width / referenceWidth, side = iconSide(in: panel), inset = 33 * unit
        let pitch = (panel.width - 2 * inset - side) / 2
        let column = max(0, min(2, Int(((point.x - panel.minX - inset - side / 2) / pitch).rounded())))
        let row = max(0, min(2, Int(((point.y - panel.minY - inset - side / 2) / (112 * unit)).rounded())))
        return row * 3 + column
    }
    static func miniatureFrame(_ index: Int, side: CGFloat) -> CGRect {
        let pitch = side * 16 / 68
        let miniature = side * (40.0 / 3) / 68
        let inset = (side - pitch * 3) / 2 + (pitch - miniature) / 2
        let slot = max(0, index) % 9
        return CGRect(x: inset + CGFloat(slot % 3) * pitch, y: inset + CGFloat(slot / 3) * pitch,
                      width: miniature, height: miniature)
    }
}
#endif
