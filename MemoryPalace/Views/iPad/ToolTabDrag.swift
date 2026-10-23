import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
import os
enum ShellProbe {
    static let log = Logger(subsystem: "com.susu.MemoryPalace", category: "probe")
    static func p(_ s: String) { log.info("\(s, privacy: .public)") }
    /// `.info` 不落盘（`log show` 事后查不到）；要事后取证的用这个（`.notice` 持久化）
    static func keep(_ s: String) { log.notice("\(s, privacy: .public)") }
}
#endif

extension UTType {
    /// mac / iOS 两个 target 的 Info.plist 都声明了（project.yml 的 info.properties），没声明会被 SwiftUI 拖放桥丢掉（09-08 实测：源起、五种落点零 validate）。
    static let toolTab = UTType(exportedAs: "com.susu.MemoryPalace.tool-tab", conformingTo: .data)
}

/// PS 式 tab 拖放的载荷（A2a）。悬停只画预览，**松手才写状态**；被拖的是谁记在 `IPadPanelLayout.draggingTab`，
/// mac 拖源由 `MacShellDragSource` 提供结束回调；iPad 保留原 provider。
enum ToolTabDrag {
    static func provider(_ toolId: String) -> NSItemProvider {
        let p = NSItemProvider()
        p.registerDataRepresentation(for: .toolTab, visibility: .all) { done in
            done(Data(toolId.utf8), nil)
            return nil
        }
        return p
    }
}

/// tab 半槽 → 插入槽位（纯函数，可测）：落在第 i 个 tab 的左半 = 插到它前面（槽 i），右半 = 槽 i+1。
/// 拖的是它自己时两个槽都是原位，`IPadPanelLayout.moveTab` 归零成不动
enum TabInsertion {
    static func slot(tabIndex: Int, x: CGFloat, width: CGFloat) -> Int {
        x < width / 2 ? tabIndex : tabIndex + 1
    }
}

/// 一个 tab 身上的落点：悬停按 x 报槽位（`dropUpdated` 每帧给 location；`dropDestination` 只在落下给，所以用 delegate）
struct TabSlotDrop: DropDelegate {
    let tabIndex: Int
    let width: CGFloat
    let onSlot: (Int?) -> Void
    let draggingTab: () -> String?
    let perform: (Int) -> Bool

    private func slot(_ info: DropInfo) -> Int { TabInsertion.slot(tabIndex: tabIndex, x: info.location.x, width: width) }

    func validateDrop(info: DropInfo) -> Bool {
        #if os(macOS)
        let valid = draggingTab() != nil && info.hasItemsConforming(to: [.toolTab])
        #else
        let valid = info.hasItemsConforming(to: [.toolTab])
        #endif
        #if DEBUG
        let conforming = info.itemProviders(for: [.toolTab]).flatMap(\.registeredTypeIdentifiers)
        ShellProbe.p("[PROBE tab.target] slot[\(tabIndex)] validate=\(valid) conforming=\(conforming)")
        #endif
        return valid
    }

    func dropEntered(info: DropInfo) { onSlot(slot(info)) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        onSlot(slot(info))
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { onSlot(nil) }
    func performDrop(info: DropInfo) -> Bool {
        #if DEBUG
        ShellProbe.p("[PROBE tab.commit] slot=\(slot(info)) draggingTab=\(draggingTab() ?? "nil")")
        #endif
        onSlot(nil)
        return perform(slot(info))
    }
}

/// 整块落点（组正文 / 工作区空处 / 浮窗标题栏）：进出报高亮，落下给本地坐标
struct ToolTabDropZone: DropDelegate {
    let name: String
    var hovering: ((Bool) -> Void)? = nil
    /// 悬停时的本地坐标（分区预览用；`dropEntered` / `dropUpdated` 都报，松手时 perform 自己按那一刻的坐标重分）
    var located: ((CGPoint) -> Void)? = nil
    let draggingTab: () -> String?
    let perform: (CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        #if os(macOS)
        let valid = draggingTab() != nil && info.hasItemsConforming(to: [.toolTab])
        #else
        let valid = info.hasItemsConforming(to: [.toolTab])
        #endif
        #if DEBUG
        let conforming = info.itemProviders(for: [.toolTab]).flatMap(\.registeredTypeIdentifiers)
        ShellProbe.p("[PROBE tab.target] \(name) validate=\(valid) conforming=\(conforming)")
        #endif
        return valid
    }

    func dropEntered(info: DropInfo) { hovering?(true); located?(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        located?(info.location)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { hovering?(false) }
    func performDrop(info: DropInfo) -> Bool {
        #if DEBUG
        ShellProbe.p("[PROBE tab.commit] \(name) point=\(info.location) draggingTab=\(draggingTab() ?? "nil")")
        #endif
        hovering?(false)
        return perform(info.location)
    }
}
