#if os(iOS)
import SwiftUI

struct Page2FolderIcon: View {
    let pages: [[Page2Item]]
    let side: CGFloat
    var page = 0
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(1, max(pages.count, page + 1)), id: \.self) { index in
                ZStack(alignment: .topLeading) {
                    if pages.indices.contains(index) {
                        ForEach(Array(pages[index].prefix(9).enumerated()), id: \.element.id) { slot, child in
                            if let tool = tools?.tool(byId: child.toolID ?? "") {
                                let frame = Page2FolderGeometry.miniatureFrame(slot, side: side)
                                Page2AppIcon(tool: tool, side: frame.width, label: false, followsIconSize: false, interactive: false, usesGlass: false, decorative: true)
                                    .frame(width: frame.width, height: frame.height)
                                    .position(x: frame.midX, y: frame.midY)
                            }
                        }
                    }
                }.frame(width: side, height: side, alignment: .topLeading)
            }
        }
        .offset(x: -CGFloat(page) * side)
        .frame(width: side, height: side, alignment: .leading)
        .clipped()
        .glassEffect(.clear, in: .rect(cornerRadius: side * 0.26))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: page)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
#endif
