#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// 花园浏览器（docs/plan-inapp-browser-modern.md）：照 iOS 26 Safari，网页铺满、底部玻璃栏。
/// 紧凑 = 左圆钮 / 地址胶囊 / ⋯；两行 = 地址胶囊 + 按钮排；往下滚缩成只写域名的小胶囊。
/// 左圆钮第一页是关闭（embedded 时是回 page2 浏览器主页），进了别的页变后退。
/// embedded = page2 浏览器 app 里内嵌：接 page2 外壳的返回键；网页同样铺满上下（粟粟 11-10「上下有白边」）。
struct GardenBrowserView: View {
    let initialURL: URL
    var embedded = false
    /// 开在哪个身份里（plan-garden-browser-identities §3）；从聊天点链接弹出来的一律主号
    var identity: BrowserIdentity = .main
    /// page2 浏览器里换身份：外面用新身份重开当前网址；nil = 不给换
    var onSwitchIdentity: ((BrowserIdentity, URL) -> Void)? = nil
    var onClose: () -> Void

    @StateObject private var controller = MiniBrowserController()
    @AppStorage(GardenBrowserSettings.layoutKey) private var layout: GardenBrowserToolbarLayout = .compact
    @AppStorage(GardenBrowserSettings.linkOpenModeKey) private var linkOpenMode: GardenLinkOpenMode = .inApp
    @State private var editing = false
    @State private var addressText = ""
    @State private var history: [BrowsingHistoryEntry] = []
    @State private var showHistory = false
    /// 网页自己的输入框 / 页内查找弹了键盘：底栏先藏起来（Safari 同款），不和查找条挤
    @State private var keyboardUp = false
    /// 「让 AI 看这页」放进输入框后的小提示
    @State private var attachedNote: String?
    @State private var op = BrowserOperator.shared
    @FocusState private var addressFocused: Bool

    private var currentURL: URL { controller.url ?? initialURL }

    private var host: String {
        let h = currentURL.host() ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// 底栏在安全区上方盖住的高度（网页最底下的内容要能滚上来）
    private var obscuredHeight: CGFloat {
        if controller.isCollapsed { return 44 }
        return (layout == .compact ? 56 : 104) + (embedded ? 8 : 0)
    }

    /// 紧凑尺寸照 iOS 26 Safari 实测（iPhone 17 Pro / Air 一样）：圆钮 48、胶囊高 48、间距 8、左右各 34、底边贴安全区；
    /// 两行比原来下移 10（粟粟 11-08）
    private var barHorizontalPadding: CGFloat {
        layout == .compact && !controller.isCollapsed ? 34 : 14
    }

    @Environment(\.colorScheme) private var systemColorScheme

    private var barColorScheme: ColorScheme {
        guard let bg = controller.pageBackground else { return systemColorScheme }
        var white: CGFloat = 0
        guard bg.resolvedColor(with: .current).getWhite(&white, alpha: nil) else { return systemColorScheme }
        return white < 0.5 ? .dark : .light
    }

    private var barBottomPadding: CGFloat {
        if controller.isCollapsed { return embedded ? 10 : 6 }
        switch layout {
        case .compact: return embedded ? 10 : 0
        case .twoRow: return embedded ? 0 : -4
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            BrowserWebView(initialURL: initialURL, controller: controller, identity: identity)
                .ignoresSafeArea()

            topChrome

            bottomBar
                .tint(.primary)
                // 大块玻璃（两行版）不会按底下内容自己翻深浅：按网页底色定（Safari 同款，深色网页配深色栏）
                .environment(\.colorScheme, barColorScheme)
                .padding(.horizontal, barHorizontalPadding)
                .padding(.bottom, barBottomPadding)
                // AI 在操作时底栏变淡点不了，免得和它抢（plan-ai-browser-operate §1.2）
                .opacity(editing || keyboardUp ? 0 : (op.isOperating(controller) ? 0.45 : 1))
                .allowsHitTesting(!editing && !keyboardUp && !op.isOperating(controller))
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: controller.isCollapsed)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: layout)
                .ignoresSafeArea(.keyboard)

            AIOperatorOverlay(controller: controller)

            if let attachedNote {
                Text(attachedNote)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, obscuredHeight + 24)
                    .transition(.opacity)
            }

            if editing {
                editOverlay
            }
        }
        .onAppear {
            BrowserOperator.shared.attach(controller, identity: identity)
            DispatchQueue.main.async { controller.setBottomObscuredHeight(obscuredHeight) }
            if embedded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { hideWebViewInputAccessory() }
            }
        }
        .onDisappear { BrowserOperator.shared.detach(controller) }
        .onChange(of: obscuredHeight) { _, h in controller.setBottomObscuredHeight(h) }
        .onChange(of: controller.title) { _, _ in
            if embedded { hideWebViewInputAccessory() }
        }
        .onChange(of: controller.canGoBack, initial: true) { _, canGoBack in
            // page2 外壳的导航钮先退网页（plan-page2-app-shell §2.5）
            if embedded {
                Page2AppBackRegistry.shared.update("browser", canGoBack: canGoBack) { controller.goBack() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .sheet(isPresented: $showHistory) {
            BrowsingHistorySheet(identity: identity.id) { url in controller.load(url) }
        }
    }

    // MARK: - 顶部：状态栏下的柔边 + 进度条

    private var topChrome: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color(uiColor: controller.pageBackground ?? .systemBackground))
                    .frame(height: g.safeAreaInsets.top)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .center, endPoint: .bottom))
                progressBar
                Spacer(minLength: 0)
            }
            .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
    }

    private var progressBar: some View {
        GeometryReader { g in
            Rectangle()
                .fill(Theme.branchIndicator)
                .frame(width: g.size.width * max(0.06, controller.progress))
                .animation(.linear(duration: 0.2), value: controller.progress)
        }
        .frame(height: 2.5)
        .opacity(controller.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: controller.isLoading)
    }

    // MARK: - 底栏

    @ViewBuilder
    private var bottomBar: some View {
        if controller.isCollapsed {
            Text(host.isEmpty ? "网页" : host)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .glassEffect(.regular.interactive(), in: .capsule)
                .contentShape(Capsule())
                .onTapGesture { controller.isCollapsed = false }
                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
        } else if layout == .compact {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { leadingAction() } label: {
                        icon(leadingIcon, size: 21, weight: .regular)
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .accessibilityLabel(controller.canGoBack ? "后退" : (embedded ? "浏览器主页" : "关闭"))
                    addressCapsule(inset: false)
                    moreMenu {
                        icon("ellipsis", size: 21)
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                }
            }
            .transition(.opacity)
        } else {
            VStack(spacing: 2) {
                addressCapsule(inset: true)
                HStack(spacing: 0) {
                    rowButton("chevron.left", label: "后退", disabled: !controller.canGoBack) { controller.goBack() }
                    rowButton("chevron.right", label: "前进", disabled: !controller.canGoForward) { controller.goForward() }
                    ShareLink(item: currentURL) {
                        icon("square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    moreMenu {
                        icon("ellipsis").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    rowButton(embedded ? "house" : "xmark", label: embedded ? "浏览器主页" : "关闭") { onClose() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
            .transition(.opacity)
        }
    }

    private var leadingIcon: String {
        controller.canGoBack ? "chevron.left" : (embedded ? "house" : "xmark")
    }

    private func leadingAction() {
        if controller.canGoBack { controller.goBack() } else { onClose() }
    }

    @ViewBuilder
    private func addressCapsule(inset: Bool) -> some View {
        let content = HStack(spacing: 0) {
            Menu {
                Button {
                    controller.webView?.findInteraction?.presentFindNavigator(showingReplace: false)
                } label: {
                    Label("页内查找", systemImage: "text.magnifyingglass")
                }
                Button { attachPageToChat() } label: {
                    Label("让 AI 看这页", systemImage: "sparkles")
                }
                .disabled(op.attachToChat == nil)
                if let onSwitchIdentity {
                    let identities = BrowserIdentityStore.load()
                    if identities.count > 1 {
                        Section("用别的身份打开") {
                            ForEach(identities.filter { $0.id != identity.id }) { other in
                                Button { onSwitchIdentity(other, currentURL) } label: {
                                    Label(other.name, systemImage: "person.crop.circle")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 0) {
                    icon("doc.text.magnifyingglass", size: 18)
                    if onSwitchIdentity != nil {
                        // 当前身份的色点（只有一个身份时也画：告诉她这是哪份登录态）
                        Circle()
                            .fill(identity.color)
                            .frame(width: 8, height: 8)
                            .offset(x: -3, y: 9)
                            .accessibilityLabel("身份：\(identity.name)")
                    }
                }
                .frame(width: 44, height: 46)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("页面菜单")

            Text(host.isEmpty ? "网页" : host)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                // Safari 的域名离胶囊边 ~45，比两侧按钮的点击区宽 44 还靠外一点
                .padding(.horizontal, -4)

            Button {
                if controller.isLoading { controller.stopLoading() } else { controller.reload() }
            } label: {
                icon(controller.isLoading ? "xmark" : "arrow.clockwise", size: 18)
                    .frame(width: 44, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isLoading ? "停止" : "刷新")
        }
        .frame(height: inset ? 46 : 48)
        .contentShape(Capsule())
        .onTapGesture { beginEditing() }

        if inset {
            content.background(Capsule().fill(Theme.textPrimary.opacity(0.07)))
        } else {
            content.glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    private func moreMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            Button { controller.goForward() } label: { Label("前进", systemImage: "chevron.right") }
                .disabled(!controller.canGoForward)
            ShareLink(item: currentURL) { Label("分享…", systemImage: "square.and.arrow.up") }
            Button { UIPasteboard.general.string = currentURL.absoluteString } label: { Label("复制链接", systemImage: "link") }
            Button { UIApplication.shared.open(currentURL) } label: { Label("在 Safari 打开", systemImage: "safari") }
            Button { showHistory = true } label: { Label("历史", systemImage: "clock") }
            Divider()
            Menu {
                Picker(selection: $layout) {
                    ForEach(GardenBrowserToolbarLayout.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("底栏布局", systemImage: "rectangle.bottomhalf.inset.filled")
                }
                .pickerStyle(.menu)
                Picker(selection: $linkOpenMode) {
                    ForEach(GardenLinkOpenMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("链接打开方式", systemImage: "link.badge.plus")
                }
                .pickerStyle(.menu)
            } label: {
                Label("浏览器设置", systemImage: "gearshape")
            }
        } label: {
            label()
        }
        .accessibilityLabel("更多")
    }

    private func rowButton(_ name: String, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon(name).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(label)
    }

    /// 底栏图标 / 文字用 .primary：玻璃按底下网页深浅自己翻黑白（Safari 同款），固定色会在深色网页上发灰
    private func icon(_ name: String, size: CGFloat = 17, weight: Font.Weight = .medium) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.primary)
    }

    // MARK: - 编辑地址

    private struct Suggestion: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let url: URL
    }

    private var suggestions: [Suggestion] {
        let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [Suggestion] = []
        let unchanged = text == currentURL.absoluteString
        if !unchanged, let kind = AddressInput.kind(of: text), let url = AddressInput.url(for: text) {
            out.append(kind == .url
                       ? Suggestion(id: "go", icon: "globe", title: "打开 \(text)", detail: "网址", url: url)
                       : Suggestion(id: "go", icon: "magnifyingglass", title: "搜索「\(text)」", detail: "Google", url: url))
        }
        let matches = history.filter { entry in
            unchanged || text.isEmpty
                || entry.title.localizedCaseInsensitiveContains(text)
                || entry.url.localizedCaseInsensitiveContains(text)
        }
        for entry in matches.prefix(3) {
            guard let url = URL(string: entry.url), !out.contains(where: { $0.url == url }) else { continue }
            out.append(Suggestion(id: entry.id.uuidString, icon: "clock",
                                  title: entry.title.isEmpty ? entry.url : entry.title, detail: "历史", url: url))
        }
        return out
    }

    private var editOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { endEditing() }

            VStack(spacing: 8) {
                if !suggestions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(suggestions) { s in
                            Button { open(s.url) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: s.icon)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.textMuted)
                                        .frame(width: 18)
                                    Text(s.title)
                                        .font(.system(size: 15))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(s.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textMuted)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 46)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if s.id != suggestions.last?.id { Divider().padding(.leading, 44) }
                        }
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                }

                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textMuted)
                        TextField("搜索或输入网址", text: $addressText)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textPrimary)
                            .focused($addressFocused)
                            .keyboardType(.webSearch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { if let url = AddressInput.url(for: addressText) { open(url) } }
                            // 输入框出现后再聚焦：同一拍设焦点它还不在树上；弹出的控制器里 0.05s 也不够（模拟器实测）
                            .task {
                                try? await Task.sleep(for: .milliseconds(300))
                                addressFocused = true
                            }
                        if !addressText.isEmpty {
                            Button { addressText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清空")
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .glassEffect(.regular, in: .capsule)

                    Button { endEditing() } label: {
                        icon("xmark")
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .accessibilityLabel("取消编辑")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    /// 当前页正文变附件放进当前对话的输入框（plan-ai-browser-operate §1.3）；弹出来的浏览器顺手关掉回聊天
    private func attachPageToChat() {
        Task {
            let ok = await BrowserOperator.shared.attachCurrentPage()
            if ok && !embedded { onClose(); return }
            withAnimation { attachedNote = ok ? "已放进对话的输入框" : "这一页读不出来" }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { attachedNote = nil }
        }
    }

    private func beginEditing() {
        if controller.isCollapsed { controller.isCollapsed = false; return }
        addressText = currentURL.absoluteString
        history = BrowsingHistoryStore.load(identity: identity.id)
        editing = true
    }

    private func endEditing() {
        addressFocused = false
        editing = false
    }

    private func open(_ url: URL) {
        controller.load(url)
        endEditing()
    }

    /// 干掉网页输入框键盘上方的 ⌃⌄✓ 条（page2 内嵌沿用）
    private func hideWebViewInputAccessory() {
        guard let webView = controller.webView else { return }
        webView.disableKeyboardInputAccessory()
        if let contentView = webView.scrollView.subviews.first(where: {
            String(describing: type(of: $0)).contains("WKContent")
        }) {
            contentView.inputAssistantItem.leadingBarButtonGroups = []
            contentView.inputAssistantItem.trailingBarButtonGroups = []
        }
    }
}
#endif
