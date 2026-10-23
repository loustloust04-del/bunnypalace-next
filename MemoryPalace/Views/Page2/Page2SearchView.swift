#if os(iOS)
import SwiftUI

struct Page2SearchView: View {
    let sourceFrame: CGRect
    let topInset: CGFloat
    let closing: Bool
    var onOpen: (String) -> Void
    var onDismiss: () -> Void
    var onClosed: () -> Void
    @Environment(RightPanelToolManager.self) private var manager: RightPanelToolManager?
    @State private var query = ""
    @State private var appearance = Page2AppearanceStore.shared
    @State private var appeared = false
    @State private var fieldTop: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var dark: Bool { !appearance.displayed.isLightBackdrop }
    private var results: [RightPanelTool] {
        let key = Page2LibraryNameKey(query).latin
        return (manager?.pinnedTools ?? []).filter {
            $0.isEnabled && (manager?.isVisibleInCurrentMode($0) ?? false) &&
                (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || Page2LibraryNameKey($0.name).latin.contains(key))
        }
    }
    private var displayed: [RightPanelTool] { query.isEmpty ? Array(results.prefix(4)) : results }
    private var visible: Bool { appeared && !closing }
    var body: some View {
        GeometryReader { geometry in
            let top = topInset + 12
            let available = max(0, (fieldTop > 0 ? fieldTop : geometry.size.height - 220) - top - 16)
            let rows = max(1, (displayed.count + 3) / 4)
            let contentHeight = displayed.isEmpty ? 100 : CGFloat(rows) * 92 + CGFloat(rows - 1) * 20 + 60
            ZStack(alignment: .top) {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: onDismiss)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(query.isEmpty ? "应用建议" : "最佳结果").font(.system(size: 15, weight: .semibold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 20) {
                            ForEach(displayed) { tool in
                                Page2AppIcon(tool: tool, side: 68, followsIconSize: false) { onOpen(tool.id) }
                            }
                        }
                        .padding(16)
                        .background(.primary.opacity(dark ? 0.13 : 0.06), in: RoundedRectangle(cornerRadius: 38))
                        if displayed.isEmpty { Text("没有找到应用").font(.callout) }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollDismissesKeyboard(.interactively).scrollIndicators(.hidden)
                .frame(height: min(available, contentHeight))
                .padding(.top, top)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : -12)
                .allowsHitTesting(!closing)
                Page2SpotlightField(text: $query, sourceFrame: sourceFrame, closing: closing, dark: dark, contentBottom: top + min(available, contentHeight), onDismiss: onDismiss,
                                    onTopChange: { fieldTop = $0 }, onSubmit: { if let tool = results.first { onOpen(tool.id) } }, onClosed: onClosed)
            }
            .background { Rectangle().fill(.ultraThinMaterial).opacity(visible ? 1 : 0) }
            .animation(reduceMotion ? nil : .easeOut(duration: closing ? 0.28 : 0.32), value: visible)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, dark ? .dark : .light)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("page2.spotlight")
        .onAppear { appeared = true }
        .accessibilityAction(.escape, onDismiss)
    }
}
#endif
