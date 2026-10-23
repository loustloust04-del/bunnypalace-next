import CoreGraphics

/// 输入条 UIKit carrier（`PassthroughContainerView`）什么时候放行触摸（astra R6 C1，`docs/prompts/2026-09-25-chat-cards/reports/r6-panel-freeze-astra.md`）：
/// ➕ 面板 / 贴纸网格打开时，输入条只剩透明占位（60 / 320pt），但 carrier 叠在面板上方——
/// 以前把占位高度也当可点区，面板工具条 / 贴纸的点按和横滑全被吃掉。占位时整块放行；真输入条照旧只放行栈上方的空白。
enum InputBarHitRule {
    static func isPlaceholder(searchActive: Bool, stickerPanel: Bool, editingStickers: Bool) -> Bool {
        !searchActive && (stickerPanel || editingStickers)
    }

    /// `recordingHitRect`：录语音锁定态的锁 + 大按钮（输入条栈坐标，原点 = 可见栈顶；plan-voice-note M5c），
    /// 栈上方落在它里面的点不放行——否则锁定后松了手，上面的锁 / 大按钮点下去全漏给聊天列表
    static func passesThrough(pointY: CGFloat, carrierHeight: CGFloat, visibleHeight: CGFloat, isPlaceholder: Bool,
                              pointX: CGFloat = 0, recordingHitRect: CGRect? = nil) -> Bool {
        if isPlaceholder { return true }
        let barTop = carrierHeight - visibleHeight
        if let rect = recordingHitRect, rect.offsetBy(dx: 0, dy: barTop).contains(CGPoint(x: pointX, y: pointY)) {
            return false
        }
        return pointY < barTop - 4
    }
}
