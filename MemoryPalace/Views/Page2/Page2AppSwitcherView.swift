#if os(iOS)
import SwiftUI

/// 模糊桌面上的卡片。卡片只有右上圆形 ×，没有弧线和底栏。
struct Page2AppSwitcherView: View {
    @Binding var selectedToolId: String
    let viewport: CGSize
    @State private var shell = Page2AppShell.shared
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?

    static let cardCornerRadius: CGFloat = 18

    static func cardWidth(count: Int, size: CGSize) -> CGFloat {
        let single = min(360, max(1, min(size.width * 0.68, (size.height - 160) * 3 / 4)))
        return count == 1 ? single : min(230, max(1, min((size.width - 68) / 2, single * 0.68)))
    }
    static func topInset(count: Int, size: CGSize) -> CGFloat {
        count == 1 ? max(80, (size.height - cardWidth(count: count, size: size) * 4 / 3 - 26) / 2) : 96
    }
    static func slot(for id: String, apps: [String], size: CGSize) -> CGRect {
        let count = apps.count
        let columns = count == 1 ? 1 : 2
        let width = cardWidth(count: count, size: size)
        let index = apps.firstIndex(of: id) ?? 0
        let left = (size.width - CGFloat(columns) * width - CGFloat(columns - 1) * 20) / 2
        return CGRect(x: left + CGFloat(index % columns) * (width + 20),
                      y: topInset(count: count, size: size) + CGFloat(index / columns) * (width * 4 / 3 + 52),
                      width: width, height: width * 4 / 3)
    }

    private var width: CGFloat { Self.cardWidth(count: shell.switcherApps.count, size: viewport) }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(width), spacing: 20), count: shell.switcherApps.count == 1 ? 1 : 2)
    }

    var body: some View {
        ZStack {
            Group {
                if let image = shell.desktopSnapshot {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Page2WallpaperView(appearance: Page2AppearanceStore.shared.displayed)
                }
            }
            .frame(width: viewport.width, height: viewport.height).clipped()
            // opaque：默认模糊边缘透明，拉动时透出底下活的桌面、落定后透出底色，四边在落定那帧变一下
            .blur(radius: 24, opaque: true).overlay(.ultraThinMaterial.opacity(0.2))
            .contentShape(Rectangle()).onTapGesture(perform: goHome)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(shell.switcherApps, id: \.self) { id in
                        let tool = tools?.tool(byId: id)
                        // 正在拉的那张：卡身让给活的应用（透明占位），× 和标题跟着进度淡入，落定换截图时不再蹦出来
                        Page2SwitcherCard(id: id, title: tool?.name ?? id, icon: tool?.icon ?? "app",
                                          image: shell.snapshots[id], viewport: viewport, cardSize: CGSize(width: width, height: width * 4 / 3),
                                          motion: shell.motion.flatMap { $0.appID == id ? $0.cardProgress * (1 - $0.homeProgress) : nil },
                                          onOpen: { open(id) }, onClose: { close(id) })
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, Self.topInset(count: shell.switcherApps.count, size: viewport))
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .onTapGesture(perform: goHome)
        }
        .accessibilityIdentifier("page2.switcher")
    }

    private func open(_ id: String) {
        guard shell.motion == nil else { return }
        shell.beginMotion(id, fromSwitcher: true)
        selectedToolId = id
        shell.settle(card: 0) { shell.showsSwitcher = false; shell.open(id) }
    }
    private func close(_ id: String) {
        guard shell.motion == nil else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            shell.close(id)
            if selectedToolId == id { selectedToolId = shell.switcherApps.first ?? "home" }
            if shell.switcherApps.isEmpty { shell.showsSwitcher = false; selectedToolId = "home" }
        }
    }
    private func goHome() {
        guard shell.motion == nil else { return }
        withAnimation(.easeOut(duration: 0.22)) { shell.showsSwitcher = false; selectedToolId = "home" }
    }
}

private struct Page2SwitcherCard: View {
    let id: String
    let title: String
    let icon: String
    let image: UIImage?
    let viewport: CGSize
    let cardSize: CGSize
    /// 这张正被外壳拉着时的进度（卡身隐藏，× / 标题按它淡入）；没在拉为 nil
    let motion: CGFloat?
    let onOpen: () -> Void
    let onClose: () -> Void
    @State private var dragY: CGFloat = 0
    @State private var closing = false
    @State private var dragged = false
    /// × 在拉动时被上层的活应用盖着，落定换截图后再淡入（不跟着 chrome，那样会在换图那帧突然冒出）
    @State private var closeShown = true
    @GestureState private var tracking = false

    var body: some View {
        let chrome = motion.map { min(max(($0 - 0.6) / 0.4, 0), 1) } ?? 1
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button { if !closing && !dragged { onOpen() } } label: {
                    Color.clear.frame(width: cardSize.width, height: cardSize.height)
                        .overlay(alignment: .topLeading) {
                            GeometryReader { geo in
                                if let image {
                                    Image(uiImage: image).resizable()
                                        .frame(width: geo.size.width, height: geo.size.width * image.size.height / max(image.size.width, 1))
                                        .accessibilityHidden(true)
                                } else {
                                    AppIconView(name: icon, size: 34, tint: nil, toolID: id)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.mainBg)
                                }
                            }
                        }
                        .clipped()
                        .contentShape(RoundedRectangle(cornerRadius: Page2AppSwitcherView.cardCornerRadius, style: .continuous))
                        .accessibilityElement(children: .ignore)
                }
                .buttonStyle(.plain).accessibilityLabel("打开\(title)")
                .accessibilityIdentifier("page2.card.\(id)")
                .frame(width: cardSize.width, height: cardSize.height)
                .background(Theme.mainBg)
                .opacity(motion == nil ? 1 : 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary).frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(4)
                .accessibilityLabel("关闭\(title)").accessibilityIdentifier("page2.close.\(id)")
                .opacity(closeShown ? 1 : 0)
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: Page2AppSwitcherView.cardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.14 * chrome), radius: 14, y: 8)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("page2-app-scene")) } action: { frame in
                if Page2AppShell.shared.motion == nil { Page2AppShell.shared.cardFrames[id] = frame }
            }
            HStack(spacing: 6) {
                AppIconView(name: icon, size: 14, tint: nil, toolID: id)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }.foregroundStyle(Theme.textPrimary).opacity(chrome)
        }
        .onChange(of: motion == nil, initial: true) { _, idle in
            if !idle { closeShown = false } else if !closeShown { withAnimation(.easeOut(duration: 0.2)) { closeShown = true } }
        }
        .offset(y: dragY < 0 ? dragY : dragY * 0.25)
        .opacity(closing ? 0 : max(0.3, 1 + Double(dragY) / 400))
        .allowsHitTesting(!closing)
        .highPriorityGesture(DragGesture(minimumDistance: 8)
            .updating($tracking) { _, active, _ in active = true }
            .onChanged { dragged = true; dragY = $0.translation.height }
            .onEnded { value in
                if abs(value.translation.height) > abs(value.translation.width),
                   value.translation.height < -80 || value.predictedEndTranslation.height - value.translation.height < -120 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85), completionCriteria: .removed) { dragY = 0 }
                    completion: { dragged = false }
                }
            })
        .onChange(of: tracking) { _, active in
            if !active && !closing {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85), completionCriteria: .removed) { dragY = 0 }
                completion: { if !closing { dragged = false } }
            }
        }
    }
    private func dismiss() {
        guard !closing else { return }
        withAnimation(.easeIn(duration: 0.24), completionCriteria: .removed) {
            closing = true; dragY = -viewport.height
        } completion: { onClose() }
    }
}
#endif
