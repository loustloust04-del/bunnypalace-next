#if os(iOS)
import SwiftUI

/// 右栏工具条的拖拽重排 delegate。原先住在 `ToolBarView.swift` 里，那份工具条 2026-09 已无人使用（死码刀删掉），
/// 这个 delegate 还被 Page2 桌面的 dock 用着（`Page2DesktopView.swift`），单独留一份。
struct ToolReorderDropDelegate: DropDelegate {
    let tool: RightPanelTool
    let onMove: (String, String) -> Void   // (fromId, toId)
    @Binding var draggingToolId: String?

    func performDrop(info: DropInfo) -> Bool {
        guard let fromId = draggingToolId else { return false }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            onMove(fromId, tool.id)
        }
        draggingToolId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let fromId = draggingToolId, fromId != tool.id else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            onMove(fromId, tool.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {}

    func validateDrop(info: DropInfo) -> Bool { true }
}
#endif
