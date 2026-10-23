#if os(iOS)
import SwiftUI

struct Page2GridView<Cell: View>: View {
    let home: Page2HomeStore
    let drag: Page2DragCoordinator
    let resize: Page2ResizeSession
    let board: Page2Board
    let pageID: UUID
    let editing: Bool
    let gridSize: CGSize
    let iconSide: CGFloat
    let showLabels: Bool
    let frame: (Page2Item, Page2Placement) -> CGRect
    let isVisible: (Page2Item) -> Bool
    let title: (Page2Item) -> String
    let cell: (Page2Item, Bool, Bool) -> Cell
    let editLayout: () -> Void
    let editItem: (Page2Item) -> Void
    let resizeItem: (Page2Item, UIGestureRecognizer.State, CGSize) -> Void
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var displayedBoard: Page2Board { drag.preview ?? board }

    var body: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = PerfCount.hit("page2GridBody")
        #endif
        ZStack(alignment: .topLeading) {
            GlassEffectContainer(spacing: 0) { gridContent }
            gridBadges
        }
    }

    private var gridContent: some View {
        ZStack(alignment: .topLeading) {
            ForEach(displayedBoard.placements.filter { $0.pageID == pageID }) { placement in
                if let item = (drag.snapshot ?? resize.preview ?? home.layout).item(placement.id), isVisible(item) || editing {
                    let rect = frame(item, placement)
                    Group {
                        if drag.sourceID == item.id {
                            Color.clear.accessibilityHidden(true)
                        } else if drag.mergeTarget == item.id, let sourceID = drag.sourceID,
                                  let source = home.layout.item(sourceID), source.kind == "app", item.kind == "app" {
                            VStack(spacing: 5) {
                                Page2FolderIcon(pages: [[item]], side: iconSide)
                                if showLabels { Text(item.kind == "folder" ? item.title : "文件夹").font(.system(size: 12)).modifier(Page2DesktopLabel()) }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .accessibilityElement(children: .ignore).accessibilityLabel("松手创建文件夹")
                        } else if drag.mergeTarget == item.id, let sourceID = drag.sourceID,
                                  let source = home.layout.item(sourceID), source.canStack(with: item) {
                            VStack(spacing: 0) {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(.thinMaterial)
                                    .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.65), lineWidth: 1) }
                                    .frame(height: rect.height - (showLabels ? 20 : 0))
                                    .scaleEffect(1.08)
                                if showLabels { Color.clear.frame(height: 20) }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("松手叠放组件")
                            .accessibilityIdentifier("page2.stack-drop-preview")
                        } else { cell(item, isVisible(item), !editing && drag.sourceID == nil) }
                    }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: drag.mergeTarget)
                        .animation(reduceMotion || drag.sourceID == item.id || resize.sourceID == item.id ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: placement)
                        .accessibilityHint(editing ? "编辑中" : "")
                        .accessibilityAction(named: "编辑布局") { editLayout() }
                        .accessibilityAction(named: "移动或更改尺寸") { editItem(item) }
                }
            }
            if home.layout.items.isEmpty && !editing {
                ContentUnavailableView("自己的主屏", systemImage: "square.grid.3x3", description: Text("长按空白处，添加应用和小组件。"))
                    .frame(width: gridSize.width, height: gridSize.height)
            }
        }
    }

    private var gridBadges: some View {
        ZStack(alignment: .topLeading) {
            ForEach(displayedBoard.placements.filter { $0.pageID == pageID && $0.id != drag.sourceID }) { placement in
                if let item = (drag.snapshot ?? resize.preview ?? home.layout).item(placement.id), isVisible(item),
                   drag.mergeTarget != item.id || drag.sourceID.flatMap({ home.layout.item($0) })?.canStack(with: item) != true {
                    let rect = frame(item, placement)
                    Color.clear.frame(width: rect.width, height: rect.height).allowsHitTesting(false)
                        .overlay(alignment: .topLeading) {
                            Page2RemoveBadge(label: "从主屏移除\(title(item))", editing: editing) { home.remove(item.id) }
                                .offset(x: Page2RemoveBadge.originOffset, y: Page2RemoveBadge.originOffset)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if editing && drag.sourceID == nil && ["widget", "stack"].contains(item.kind),
                               resize.sourceID == nil || resize.sourceID == item.id {
                                Page2ResizeHandle(identifier: "page2.resize.\(item.widgetKind ?? item.id.uuidString)", title: title(item)) { state, delta in
                                    resizeItem(item, state, delta)
                                }
                                .frame(width: 44, height: 44)
                                .offset(x: 13, y: 13 - (showLabels ? 20 : 0))
                            }
                        }
                        .modifier(Page2EditingMotion(enabled: editing && resize.sourceID != item.id,
                                                     seed: item.kind == "app" ? (tools?.tool(byId: item.toolID ?? "")?.order ?? 0) : Int(item.id.uuid.0),
                                                     amplitude: item.span == .icon ? 1.659 : 0.3,
                                                     pivotHeight: item.span == .icon ? iconSide : rect.height - (showLabels ? 20 : 0)))
                        .position(x: rect.midX, y: rect.midY)
                        .animation(reduceMotion || resize.sourceID == item.id ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: placement)
                }
            }
        }
    }

}
#endif
