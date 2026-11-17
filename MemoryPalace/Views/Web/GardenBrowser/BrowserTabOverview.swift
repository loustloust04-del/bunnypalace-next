#if os(iOS)
import SwiftUI
import UIKit

/// 标签页钮（Safari 同款圆角方框里写数字）：点开总览，长按「新标签页 / 关闭其他 / 关闭所有」（docs/plan-browser-tabs.md §1.2）
struct BrowserTabsButton: View {
    let count: Int
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.primary, lineWidth: 1.7)
                    .frame(width: 21, height: 21)
                Text(count > 99 ? "∞" : "\(count)")
                    .font(.system(size: count > 9 ? 10 : 12, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            let tabs = BrowserTabs.shared
            Button { tabs.open(nil, identity: tabs.active.map(tabs.identity(of:)) ?? .main) } label: {
                Label("新标签页", systemImage: "plus.square.on.square")
            }
            if let active = tabs.active, count > 1 {
                Button { tabs.closeOthers(keeping: active.id) } label: {
                    Label("关闭其他标签页", systemImage: "xmark.square")
                }
            }
            Button(role: .destructive) { tabs.closeAll() } label: {
                Label("关闭所有标签页", systemImage: "xmark")
            }
        }
        .accessibilityLabel("\(count) 个标签页")
    }
}

/// 新标签页：浏览器主页（身份胶囊 / 搜索 / 收藏 / 最近）+ 底下 ✕（或 🏠）和标签页钮
struct BrowserNewTabPage: View {
    let record: BrowserTabRecord
    var embedded = false
    var tabCount = 1
    var onShowTabs: () -> Void
    var onClose: () -> Void

    @State private var tabs = BrowserTabs.shared

    private var identity: Binding<BrowserIdentity> {
        Binding(get: { tabs.identity(of: tabs.list.record(record.id) ?? record) },
                set: { new in
                    BrowserIdentityStore.setCurrent(new.id)
                    tabs.setIdentity(new, for: record.id)
                })
    }

    var body: some View {
        BrowserHome(identity: identity) { url in tabs.load(url, in: record.id) }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { onClose() } label: {
                        Image(systemName: embedded ? "house" : "xmark")
                            .font(.system(size: 19))
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(embedded ? "浏览器主页" : "关闭")
                    Spacer()
                    BrowserTabsButton(count: tabCount, onTap: onShowTabs)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .padding(.horizontal, 34)
                .padding(.bottom, embedded ? 10 : 0)
            }
            .onAppear {
                if embedded { Page2AppBackRegistry.shared.update("browser", canGoBack: true) { onClose() } }
            }
    }
}

/// 标签页总览（Safari 两列卡片）：截图 + 标题 + 身份色点，右上 ✕ / 往左划关；底下 ＋ / 几个标签页 / 完成
struct BrowserTabOverview: View {
    var onDone: () -> Void

    @State private var tabs = BrowserTabs.shared
    @State private var identities: [UUID: BrowserIdentity] = [:]

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(tabs.records) { record in
                            BrowserTabCard(record: record, image: tabs.snapshot(record.id),
                                           identity: identities[record.identityID],
                                           showDot: identities.count > 1,
                                           active: record.id == tabs.active?.id,
                                           onSelect: { tabs.select(record.id); onDone() },
                                           onClose: { withAnimation(.easeOut(duration: 0.2)) { tabs.close(record.id) } })
                                .id(record.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .onAppear { if let id = tabs.active?.id { proxy.scrollTo(id, anchor: .center) } }
            }

            HStack {
                Button {
                    tabs.open(nil, identity: tabs.active.map(tabs.identity(of:)) ?? .main)
                    onDone()
                } label: {
                    Image(systemName: "plus").font(.system(size: 21)).frame(width: 48, height: 48)
                }
                .accessibilityLabel("新标签页")
                Spacer()
                Text("\(tabs.records.count) 个标签页")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("完成") { onDone() }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
            }
            .tint(Theme.textPrimary)
            .padding(.horizontal, 22)
            .padding(.bottom, 4)
        }
        .background(Theme.mainBg.ignoresSafeArea())
        .onAppear {
            identities = Dictionary(BrowserIdentityStore.load().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }
}

private struct BrowserTabCard: View {
    let record: BrowserTabRecord
    let image: UIImage?
    let identity: BrowserIdentity?
    let showDot: Bool
    let active: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var dragX: CGFloat = 0

    private var title: String {
        if !record.title.isEmpty { return record.title }
        if let host = record.url.flatMap(URL.init(string:))?.host() { return host }
        return "新标签页"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(Theme.accent)
                .aspectRatio(0.78, contentMode: .fit)
                .overlay(alignment: .top) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: record.url == nil ? "plus" : "globe")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.textMuted)
                            .frame(maxHeight: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(active ? Theme.branchIndicator : Theme.textPrimary.opacity(0.08), lineWidth: active ? 3 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.ultraThinMaterial))
                            .padding(7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭「\(title)」")
                }
            HStack(spacing: 5) {
                if showDot, let identity {
                    Circle().fill(identity.color).frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .offset(x: dragX)
        .opacity(1 - min(0.6, Double(-dragX) / 300))
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragX = min(0, value.translation.width)
                }
                .onEnded { _ in
                    if dragX < -90 { onClose() } else { withAnimation(.spring(response: 0.3)) { dragX = 0 } }
                }
        )
        .accessibilityAddTraits(.isButton)
    }
}
#endif
