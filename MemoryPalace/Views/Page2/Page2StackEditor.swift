#if os(iOS)
import SwiftUI
import UIKit

struct Page2StackEditor: View {
    let containerID: UUID
    let origin: CGRect
    let onClose: () -> Void
    let onExternalDrag: (UIGestureRecognizer.State, Page2Item, CGPoint, CGRect) -> Bool
    @State private var home = Page2HomeStore.shared
    @State private var appearance = Page2AppearanceStore.shared
    @State private var selectedID: UUID?
    @State private var showsGallery = false
    @State private var outside = false
    @State private var appeared = false
    @State private var closing = false
    @State private var generation = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var item: Page2Item? { home.layout.item(containerID) }
    private var items: [Page2Item] { (item?.children ?? []).compactMap(home.layout.item) }

    var body: some View {
        GeometryReader { geometry in
            let metrics = Page2SystemMetrics(width: geometry.size.width, height: geometry.size.height)
            let span = item?.span ?? .small
            let width = metrics.width(span)
            let height = metrics.height(span)
            ZStack {
                Rectangle().fill(.ultraThinMaterial).opacity(outside || !appeared ? 0 : 1).ignoresSafeArea()
                Page2StackEditorCards(items: items, layout: home.layout, cardSize: CGSize(width: width, height: height + 18),
                                     selectedID: selectedID ?? item?.configuration["activeChild"].flatMap(UUID.init(uuidString:)), onSelect: { selectedID = $0 },
                                     onReorder: { baseline, ids in _ = home.commitStackOrder(containerID, children: ids, basedOn: baseline) },
                                     onRemove: { home.remove($0) }, onExternalDrag: { state, child, point, frame in
                    let accepted = onExternalDrag(state, child, point, frame)
                    if state == .began { outside = accepted }
                    if state == .cancelled || state == .failed { outside = false }
                    return accepted
                })
                .frame(width: width, height: height)
                .background { Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 42)).opacity(outside ? 0 : 1) }
                .overlay(alignment: .trailing) {
                    VStack(spacing: 8) {
                        ForEach(items) { child in Circle().fill(.white.opacity(child.id == selectedID ? 0.85 : 0.3)).frame(width: 6, height: 6) }
                    }.offset(x: 12).opacity(outside ? 0 : 1).allowsHitTesting(false)
                }
                .opacity(outside ? 0 : 1)
                .position(x: appeared ? geometry.size.width / 2 : origin.midX, y: appeared ? geometry.size.height / 2 : origin.midY)
                .allowsHitTesting(!closing)
                VStack {
                    HStack {
                        Button { showsGallery = true } label: { Image(systemName: "plus").frame(width: 44, height: 18) }
                            .modifier(Page2EditingButtonStyle()).controlSize(.small)
                            .accessibilityLabel("添加小组件").accessibilityIdentifier("page2.stack-add")
                            .disabled(items.count >= 10)
                        Spacer()
                        Button(action: close) { Text("完成").frame(width: 44, height: 18) }
                            .modifier(Page2EditingButtonStyle()).controlSize(.small).accessibilityIdentifier("page2.stack-done")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, geometry.size.width * 50 / 440)
                    .padding(.top, max(16, PagingViewController.topSafeAreaInset / 2 - 12))
                    Spacer()
                    HStack(spacing: 40) {
                        option("智能轮换", symbol: "arrow.triangle.2.circlepath", key: "smartRotate", identifier: "page2.stack-smart-rotate")
                        option("组件建议", symbol: "sparkles", key: "widgetSuggestions", identifier: "page2.stack-suggestions")
                    }
                    .padding(.bottom, max(60, geometry.size.height * 92 / 956))
                }
                .opacity(outside || !appeared ? 0 : 1).allowsHitTesting(!outside && !closing)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, appearance.displayed.isLightBackdrop ? .light : .dark)
        .accessibilityElement(children: .contain).accessibilityIdentifier("page2.stack-editor")
        .accessibilityValue(items.map { Page2WidgetCatalog.name($0.widgetKind ?? "") }.joined(separator: "、"))
        .sheet(isPresented: $showsGallery) {
            Page2WidgetGallery(requiredSpan: item?.span) { widget in
                if home.addWidget(widget, toStack: containerID) { selectedID = widget.id; showsGallery = false }
            }
        }
        .onAppear {
            selectedID = item?.configuration["activeChild"].flatMap(UUID.init(uuidString:)) ?? items.first?.id
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9)) { appeared = true }
        }
        .onDisappear { generation = UUID() }
        .onChange(of: item?.kind) { _, kind in if kind != "stack" { onClose() } }
        .onChange(of: item?.children) { _, _ in if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id } }
        .accessibilityAction(.escape, close)
    }
    private func option(_ title: String, symbol: String, key: String, identifier: String) -> some View {
        let enabled = item?.configuration[key] != "false"
        let toggle = {
            guard var values = item?.configuration else { return }
            values[key] = values[key] == "false" ? "true" : "false"
            home.configure(containerID, values: values)
        }
        return VStack(spacing: 9) {
            Page2StackOptionButton(title: title, symbol: symbol, enabled: enabled, identifier: identifier, action: toggle)
                .frame(width: 60, height: 60)
            VStack(spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(enabled ? "开启" : "关闭").font(.system(size: 12))
            }.foregroundStyle(.white).contentShape(Rectangle()).onTapGesture(perform: toggle).accessibilityHidden(true)
        }.frame(width: 126)
    }
    private func close() {
        guard !closing else { return }
        closing = true
        if let selectedID, var values = item?.configuration, items.contains(where: { $0.id == selectedID }) {
            values["activeChild"] = selectedID.uuidString
            values["rotationTool"] = UserDefaults.standard.string(forKey: "page2RecentTool_v1") ?? ""
            if values != item?.configuration { home.configure(containerID, values: values) }
        }
        if reduceMotion { onClose(); return }
        let request = UUID(); generation = request
        withAnimation(.easeOut(duration: 0.28), completionCriteria: .logicallyComplete) { appeared = false } completion: {
            if generation == request { onClose() }
        }
    }
}
private struct Page2StackOptionButton: UIViewRepresentable {
    let title: String
    let symbol: String
    let enabled: Bool
    let identifier: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchUpInside)
        configure(button)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) { context.coordinator.action = action; configure(button) }
    private func configure(_ button: UIButton) {
        var configuration = enabled ? UIButton.Configuration.prominentGlass() : .glass()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .medium))
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = enabled ? .systemBlue : .clear
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        button.accessibilityLabel = title
        button.accessibilityValue = enabled ? "开启" : "关闭"
        button.accessibilityIdentifier = identifier
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pressed() { action() }
    }
}
#endif
