#if os(iOS)
import SwiftUI
import WebKit
import PhotosUI
import SwiftData

/// Page2「聊天（css自定义）」的 WKWebView 宿主。
///
/// 键盘分两层，缺一层就双重避让：
/// - **外层**：`MPChatWebView` 标 `KeyboardSelfManaging` → `PagingViewController`
///   的 `firstResponderSelfManagesKeyboard` 沿祖先链认出它，跳过 `applyKeyboardAvoidance`，
///   不写 `additionalSafeAreaInsets`。不做这步：容器先被压矮一次、web 内再位移一次。
/// - **内层**：web 用 `visualViewport` 定位（chat-runtime.js）。
///
/// P0 实测已验证（`docs/review-page2-chat-p0-keyboard.md`）。
/// P1 = 骨架 + bridge + 假数据；P2 接 `ConversationViewModel`（只读它，不改主聊天任何代码）。
final class MPChatWebView: WKWebView, KeyboardSelfManaging {}

private extension UIView {
    /// 沿 responder 链找能 present 的 VC
    func owningViewController() -> UIViewController? {
        var r: UIResponder? = self
        while let cur = r {
            if let vc = cur as? UIViewController { return vc }
            r = cur.next
        }
        return nil
    }
}

struct Page2ChatWebView: View {
    var viewModel: ConversationViewModel
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.modelContext) private var modelContext
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage("ccShowThinking") private var showThinking = true
    @AppStorage(CardLibraryPreferences.allowWebScriptsKey) private var allowWebScripts = false
    @AppStorage(LocalMode.key) private var localMode = true

    @State private var showPhotoPicker = false
    @State private var showSettings = false

    /// 显式 fetch 而不是 @Query：@Query 随每次 modelContext.save() 重算，
    /// SidebarView 为此专门改过（input-jank C4）。只在打开选择器时查一次。
    private func loadConversations() {
        guard let pid = profileManager?.currentProfile.id else { return }
        var d = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.profileId == pid && !$0.isTrashed },
            sortBy: [SortDescriptor(\.updateTime, order: .reverse)])
        d.fetchLimit = 100
        conversations = (try? modelContext.fetch(d)) ?? []
    }

    /// 照片 → PendingChatAttachment，口径抄 CardFlowView.photoAttachment（那个是 private，只能重写一遍）
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var imported: [PendingChatAttachment] = []
        var failures: [String] = []
        for (offset, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let jpeg = image.jpegData(compressionQuality: 0.82) else {
                    throw ChatAttachmentError.invalidImage("照片 \(offset + 1)")
                }
                imported.append(try PendingChatAttachment.image(
                    name: "照片 \(offset + 1).jpg", typeDescription: "图片",
                    mimeType: "image/jpeg", data: jpeg))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        await MainActor.run {
            viewModel.selectedAttachments.append(contentsOf: imported)
            photoItems = []
            if !failures.isEmpty { attachError = failures.joined(separator: "\n") }
        }
    }

    /// 正则脚本取值链抄 CardFlowView:345（preset 的在前，profile 的在后）
    /// ⑤a 起与原生气泡 / 发送同一解析（RegexPipeline：全局 → 预设实例 → 绑定卡 / 楼层旧规则）
    private var regexScripts: [RegexScript] {
        guard let profile = profileManager?.currentProfile else { return [] }
        return RegexPipeline.scripts(profile: profile, preset: presetManager?.preset(byId: profile.presetId),
                                     cards: profileManager?.characterCardManager?.cards ?? [])
    }

    /// 卡库 ⑦：消息里的网页能不能「运行」（nil = 能；否则是原因）。总开关 + 当前楼层绑定卡的许可
    private var htmlRunDenial: String? {
        let card = HTMLEmbedPermission.boundCard(profileId: profileManager?.currentProfile.id,
                                                 cards: profileManager?.characterCardManager?.cards ?? [])
        return HTMLEmbedPermission.runDenial(allowWebScripts: allowWebScripts, boundCard: card)
    }

    /// 第二批 B2：卡聊天走卡的联网档位（内置库；已许可再放白名单），非卡全断网；本地模式开着白名单全挡
    private var htmlNetwork: HTMLEmbedNetwork {
        HTMLEmbedPermission.network(boundCard: HTMLEmbedPermission.boundCard(profileId: profileManager?.currentProfile.id,
                                                                             cards: profileManager?.characterCardManager?.cards ?? []),
                                    localMode: localMode)
    }

    /// 第二批 B6：卡聊天 + 卡已许可 + 总开关开 → 最新一条自动运行
    private var htmlAutoRun: Bool {
        HTMLEmbedPermission.boundCard(profileId: profileManager?.currentProfile.id,
                                      cards: profileManager?.characterCardManager?.cards ?? []) != nil && htmlRunDenial == nil
    }

    @State private var showConvPicker = false
    @State private var conversations: [Conversation] = []
    @State private var showPickerChoice = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachError: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            webView
            // 常驻逃生口：在 web **外面**，皮肤再怎么写都碰不到它。
            // 皮肤把发送键弄没了、整页画白了，都还能从这儿切回默认。
            Menu {
                Button { loadConversations(); showConvPicker = true } label: {
                    Label("切换对话", systemImage: "bubble.left.and.bubble.right")
                }
                Button { showSettings = true } label: {
                    Label("聊天设置…", systemImage: "slider.horizontal.3")
                }
                Divider()
                // 清皮肤会发 ChatSkinStore.didChange，Coordinator 收到就把 web 里的皮肤卸掉
                Button(role: .destructive) { ChatSkinStore.clearActiveSkin() } label: {
                    Label("恢复默认皮肤", systemImage: "paintbrush")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 30, height: 30)
            }
            // 玻璃走 .buttonStyle(.glass)：glassEffect + .plain 会吞命中（swiftui-ui 规则）
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("更多")
            .padding(.trailing, 14)
            .padding(.top, 4)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ChatSkinSettingsPage()
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showSettings = false } } }
            }
        }
        .sheet(isPresented: $showConvPicker) {
            NavigationStack {
                List(conversations, id: \.id) { c in
                    Button {
                        viewModel.loadConversation(c, context: modelContext)
                        showConvPicker = false
                    } label: {
                        HStack {
                            Text(c.title.isEmpty ? "未命名" : c.title).lineLimit(1)
                            Spacer()
                            if c.id == viewModel.selectedConversation?.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
                .navigationTitle("切换对话")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showConvPicker = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var webView: some View {
        ChatWebViewRepresentable(
            viewModel: viewModel,
            regexScripts: regexScripts,
            userName: viewModel.personaDisplayName(profile: profileManager?.currentProfile) ?? userName,
            assistantName: assistantName,
            showThinking: showThinking,
            htmlRunDenial: htmlRunDenial,
            htmlNetwork: htmlNetwork,
            htmlAutoRun: htmlAutoRun,
            cardManager: profileManager?.characterCardManager,
            deps: ChatSendDeps(profile: profileManager?.currentProfile,
                               preset: presetManager?.preset(byId: profileManager?.currentProfile.presetId ?? ""),
                               providerManager: providerManager,
                               modelContext: modelContext),
            onPickAttachment: { showPickerChoice = true }
        )
        .confirmationDialog("添加附件", isPresented: $showPickerChoice, titleVisibility: .visible) {
            Button("照片") { showPhotoPicker = true }
            Button("文件") { showFileImporter = true }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 6, matching: .images)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            // 口径抄 CardFlowView.handleAttachmentImport
            switch result {
            case .success(let urls):
                var failures: [String] = []
                for url in urls {
                    do { viewModel.selectedAttachments.append(try AttachmentTextExtractor.extract(from: url)) }
                    catch { failures.append(error.localizedDescription) }
                }
                if !failures.isEmpty { attachError = failures.joined(separator: "\n") }
            case .failure(let e):
                attachError = e.localizedDescription
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .alert("附件读取失败", isPresented: Binding(
            get: { attachError != nil }, set: { if !$0 { attachError = nil } }
        )) { Button("好") { attachError = nil } } message: { Text(attachError ?? "") }
            // 子应用是全屏的：web 铺满到灵动岛 / home indicator 底下，顶底留白由 chat-base.css 的
            // env(safe-area-inset-*) 自己让（viewport-fit=cover）；键盘 region 同样交给 web 自己管。
            // ⚠️ 这条挡不住 additionalSafeAreaInsets（手动 inset 不属 keyboard region），
            // 外层豁免靠的是 KeyboardSelfManaging，不是这一行。
            .ignoresSafeArea()
    }
}

private struct ChatWebViewRepresentable: UIViewRepresentable {
    let viewModel: ConversationViewModel
    let regexScripts: [RegexScript]
    let userName: String
    let assistantName: String
    let showThinking: Bool
    let htmlRunDenial: String?
    let htmlNetwork: HTMLEmbedNetwork
    let htmlAutoRun: Bool
    let cardManager: CharacterCardManager?
    let deps: ChatSendDeps
    let onPickAttachment: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, regexScripts: regexScripts,
                    userName: userName, assistantName: assistantName,
                    showThinking: showThinking, deps: deps,
                    onPickAttachment: onPickAttachment)
    }

    func makeUIView(context: Context) -> MPChatWebView {
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "mpChat")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // 聊天是长驻高频页，不让默认持久化 store 堆缓存
        config.websiteDataStore = .nonPersistent()
        // ⚠️ scheme handler 必须在 webView 创建**之前**注册
        let assetHandler = ChatAssetSchemeHandler(viewModel: viewModel) { deps.profile }
        context.coordinator.assetHandler = assetHandler
        config.setURLSchemeHandler(assetHandler, forURLScheme: ChatAssetSchemeHandler.scheme)
        // 卡库 ⑦：消息里 HTML 段的受控子文档（只回登记过的 token，响应带独立 CSP）
        config.setURLSchemeHandler(context.coordinator.embed.scheme, forURLScheme: HTMLEmbedSchemeHandler.scheme)

        let webView = MPChatWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.embed.network = htmlNetwork     // 接 eval 之前设，不往还没加载的页面发 JS
        context.coordinator.embed.autoRunEnabled = htmlAutoRun
        context.coordinator.cardManager = cardManager
        context.coordinator.wireEmbed(runDenial: htmlRunDenial)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // body 定高不滚 → WebKit 没得滚（结构性规避 focus 时的 reveal 自动滚动）。
        // 真正滚的是页面内部的 .mp-messages；webview 自己的 scrollView 关掉兜底。
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // 从 Application Support 加载（不是 bundle）：皮肤自带的 Images/ 要和文档在同一棵
        // 授权树下，web 才读得到——allowingReadAccessTo 只能授权一棵。见 ChatSkinStore 注释。
        // P3 改走 mp-asset:// 后这段简化成 load(URLRequest)。
        ChatSkinStore.syncWebAssets()
        let doc = ChatSkinStore.documentURL
        if FileManager.default.fileExists(atPath: doc.path) {
            webView.loadFileURL(doc, allowingReadAccessTo: ChatSkinStore.root)
        } else {
            KBProbe.log("[CSSCHAT] chat.html 同步失败")
        }
        return webView
    }

    func updateUIView(_ webView: MPChatWebView, context: Context) {
        context.coordinator.regexScripts = regexScripts
        context.coordinator.userName = userName
        context.coordinator.assistantName = assistantName
        context.coordinator.showThinking = showThinking
        context.coordinator.deps = deps
        context.coordinator.onPickAttachment = onPickAttachment
        // 关总开关 / 撤卡许可 → 正在跑的交互实例当场销毁（HTMLEmbedHost.runDenial didSet）
        if context.coordinator.embed.runDenial != htmlRunDenial { context.coordinator.embed.runDenial = htmlRunDenial }
        // 切楼层 / 改卡许可 → 已挂的网页按新 CSP 重挂（HTMLEmbedHost.network didSet）
        if context.coordinator.embed.network != htmlNetwork { context.coordinator.embed.network = htmlNetwork }
        context.coordinator.cardManager = cardManager
        // B6：许可 / 总开关刚打开 → 最新一条接着自动跑
        if context.coordinator.embed.autoRunEnabled != htmlAutoRun {
            context.coordinator.embed.autoRunEnabled = htmlAutoRun
            context.coordinator.autoRun()
        }
    }

    static func dismantleUIView(_ webView: MPChatWebView, coordinator: Coordinator) {
        coordinator.embed.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: MPChatWebView?
        /// 强持有：WKWebViewConfiguration 只弱引用 handler
        var assetHandler: ChatAssetSchemeHandler?
        let viewModel: ConversationViewModel
        var regexScripts: [RegexScript]
        var userName: String
        var assistantName: String
        var showThinking: Bool
        var deps: ChatSendDeps
        var onPickAttachment: () -> Void
        private var skinObserver: NSObjectProtocol?
        /// 卡库 ⑦：HTML 段调度（token / 唯一交互实例 / 释放）
        let embed = HTMLEmbedHost()
        /// 卡库第二批 B3 / B4：交互实例调助手 API 的执行者（快照 / 写 / 事件）
        private lazy var cardScript = Page2CardScriptAdapter(viewModel: viewModel)
        /// 卡库第二批 B5：绑定卡 / sendConsent 读写
        var cardManager: CharacterCardManager?
        /// B5 半屏确认框被划掉时回调（强持有：presentationController 只弱引用 delegate）
        private var sendConfirmWatcher: SheetDismissWatcher?
        private var lifecycleObservers: [NSObjectProtocol] = []
        /// 非 nil = 正在编辑这条，下一次 send 走 editAndResend
        private var editingNodeId: String?

        private var commander: ChatWebCommander { ChatWebCommander(webView: webView) }
        private var lastStructure: Int = 0
        private var lastContent: [String: Int] = [:]
        private var webReady = false

        init(viewModel: ConversationViewModel, regexScripts: [RegexScript],
             userName: String, assistantName: String, showThinking: Bool, deps: ChatSendDeps,
             onPickAttachment: @escaping () -> Void) {
            self.viewModel = viewModel
            self.regexScripts = regexScripts
            self.userName = userName
            self.assistantName = assistantName
            self.showThinking = showThinking
            self.deps = deps
            self.onPickAttachment = onPickAttachment
            super.init()
            // 设置页改 CSS / 导入 / 恢复默认 → 开着的聊天页当场换，不用退出重进
            skinObserver = NotificationCenter.default.addObserver(
                forName: ChatSkinStore.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applySkin() }
            }
        }

        deinit {
            if let skinObserver { NotificationCenter.default.removeObserver(skinObserver) }
            lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        /// 卡库 ⑦：把 HTML 段调度接到这个 webView、全局唯一交互实例和前后台
        func wireEmbed(runDenial: String?) {
            embed.runDenial = runDenial
            embed.reportStore = .shared
            embed.eval = { [weak self] js in
                self?.webView?.evaluateJavaScript(js) { _, err in
                    if let err { KBProbe.log("[HTMLEMBED] JS 出错: \(err.localizedDescription)") }
                }
            }
            embed.log = { KBProbe.log($0) }
            embed.activeKey = { HTMLCardRunCoordinator.shared.runningKey }
            embed.setActiveKey = { HTMLCardRunCoordinator.shared.runningKey = $0 }
            embed.confirmOpenLink = { [weak self] url in self?.confirmOpenLink(url) }
            cardScript.deps = { [weak self] in self?.deps ?? ChatSendDeps() }
            cardScript.fallbackNames = { [weak self] in (self?.assistantName ?? "助手", self?.userName ?? "你") }
            embed.bridge = { [weak self] id, mode in self?.cardScript.bridge(for: id, mode: mode) }
            embed.currentScope = { [weak self] in
                (self?.deps.profile?.id ?? "", self?.viewModel.selectedConversation?.id ?? "")
            }
            embed.execute = { [weak self] request, id in
                self?.cardScript.execute(request, identity: id) ?? .failure(.identityMismatch)
            }
            embed.refreshAfterWrite = { [weak self] in self?.pushUpdate() }
            embed.slash = CardSlashHost(
                card: { [weak self] in self?.slashCard() },
                names: { [weak self] in self?.cardScript.displayNames() ?? ("助手", "你") },
                isGenerating: { [weak self] in self?.viewModel.assistantTurnInFlight ?? false },
                confirm: { [weak self] confirmation, done in
                    guard let self else { done(nil); return }
                    self.presentSendConfirm(confirmation, done: done)
                },
                setConsent: { [weak self] id, consent in self?.setSendConsent(id, consent) },
                perform: { [weak self] step in
                    guard let self else { return .refused("聊天页已经关了") }
                    return self.performSlash(step)      // nil = 成功（别写成 self?.… ?? 兜底：成功的 nil 会被当成失败）
                })
            observeRunKey()
            let nc = NotificationCenter.default
            lifecycleObservers = [
                nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.embed.suspend() }
                },
                nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.embed.resume() }
                },
            ]
        }

        /// 全应用只有一个交互实例：别处（原生网页卡 / 另一段）开了新的，这边的收掉
        private func observeRunKey() {
            withObservationTracking {
                _ = HTMLCardRunCoordinator.shared.runningKey
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.embed.activeKeyChanged(HTMLCardRunCoordinator.shared.runningKey)
                    self.observeRunKey()
                }
            }
        }

        /// 子文档请求的外链：宿主弹原生确认，用户点了才开（只 http(s)，HTMLEmbedBridgeGate 已校验）
        private func confirmOpenLink(_ url: URL) {
            guard let host = webView?.owningViewController() else { return }
            let alert = UIAlertController(title: "打开外部链接？", message: url.absoluteString, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "打开", style: .default) { _ in UIApplication.shared.open(url) })
            host.present(alert, animated: true)
        }

        // MARK: - 卡库第二批 B5：替你发消息

        private func boundCard() -> CharacterCard? {
            HTMLEmbedPermission.boundCard(profileId: deps.profile?.id, cards: cardManager?.cards ?? [])
        }

        private func slashCard() -> CardSlashGate.Card? {
            boundCard().map { CardSlashGate.Card(id: $0.id, name: $0.name, consent: $0.sendConsent, allowed: embed.runDenial == nil) }
        }

        private func setSendConsent(_ cardId: String, _ consent: CardSendConsent) {
            guard let cards = cardManager, var card = cards.cards.first(where: { $0.id == cardId }) else { return }
            card.sendConsent = consent
            do { try cards.update(card) } catch { KBProbe.log("[HTMLEMBED] sendConsent 没存上: \(error.localizedDescription)") }
        }

        /// 小样 ①：底部半屏；选了才回调，划掉 = nil（不发、不记）
        private func presentSendConfirm(_ confirmation: CardSendConfirmation, done: @escaping (CardSendChoice?) -> Void) {
            guard let host = webView?.owningViewController() else { done(nil); return }
            var finished = false
            let finish: (CardSendChoice?) -> Void = { [weak self] choice in
                guard !finished else { return }
                finished = true
                self?.sendConfirmWatcher = nil
                done(choice)
            }
            let avatar = boundCard()?.coverImageData ?? deps.profile?.assistantAvatarData
            let vc = UIHostingController(rootView: AnyView(EmptyView()))
            vc.rootView = AnyView(CardSendConfirmSheet(confirmation: confirmation, avatarData: avatar) { [weak vc] choice in
                vc?.dismiss(animated: true)
                finish(choice)
            })
            vc.view.backgroundColor = Theme.platformMainBackgroundColor
            if let sheet = vc.sheetPresentationController {
                sheet.detents = [.medium()]
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = 34
            }
            let watcher = SheetDismissWatcher { finish(nil) }
            sendConfirmWatcher = watcher
            vc.presentationController?.delegate = watcher
            KBProbe.log("[HTMLEMBED] 替你发消息：弹确认（\(confirmation.cardName)）")
            host.present(vc, animated: true)
        }

        private func sendModel(_ pm: ProviderManager) -> ProviderModel {
            pm.resolveModel(conversationModelId: viewModel.selectedConversation?.selectedModelId,
                            globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        }

        /// 一步落到 VM / web：/send 只追加、/send+/trigger 走和你手动发送同一个入口、/trigger 走同一条生成管线
        private func performSlash(_ step: CardSlashStep) -> CardScriptRejection? {
            switch step {
            case .toast(let text):
                commander.toast(text)
                return nil
            case .fillInput(let text):
                commander.fillInput(text)
                return nil
            case .append(let text):
                guard let prof = deps.profile, let ctx = deps.modelContext else { return .refused("没拿到发送上下文") }
                return viewModel.appendUserMessage(text, profile: prof, preset: deps.preset ?? Preset.balanced, context: ctx)
                    ? nil : .refused("这条没发出去")
            case .sendAndReply(let text):
                guard let prof = deps.profile, let pm = deps.providerManager, let ctx = deps.modelContext else { return .refused("没拿到发送上下文") }
                let model = sendModel(pm)
                viewModel.selectedConversation?.selectedModelId = model.id
                return viewModel.sendMessage(text, model: model, profile: prof, preset: deps.preset ?? Preset.balanced,
                                             providerManager: pm, context: ctx, attachments: []) ? nil : .refused("这条没发出去")
            case .reply:
                guard let prof = deps.profile, let pm = deps.providerManager, let ctx = deps.modelContext else { return .refused("没拿到发送上下文") }
                let model = sendModel(pm)
                viewModel.selectedConversation?.selectedModelId = model.id
                return viewModel.triggerReply(model: model, profile: prof, preset: deps.preset ?? Preset.balanced,
                                              providerManager: pm, context: ctx) ? nil : .refused("没能让 AI 回复")
            }
        }

        // MARK: - 卡库第二批 B6：自动运行最新一条

        /// 渲染 / 内容更新之后：只看窗口里最新一条助手消息（生成中先不动）
        func autoRun() {
            guard webReady else { return }
            let last = windowed().last { $0.role == "assistant" }
            let message = last.map { node -> CardAutoRun.Message in
                let dto = ChatMessageDTO(node: node, ctx: context())
                return CardAutoRun.Message(nodeId: node.id, isAssistant: true,
                                           firstHTMLSegment: dto.segments?.first { $0.kind == "html" }?.id,
                                           streaming: viewModel.isCurrentConvResponding)
            }
            embed.autoRunLatest(message.map { [$0] } ?? [])
        }

        /// 当前渲染窗口里的 HTML 段 → 调度器（内容留在原生，web 只拿段 ID / 指纹）
        private func htmlSources(_ dtos: [ChatMessageDTO]) -> [(HTMLEmbedIdentity, String)] {
            let pid = deps.profile?.id ?? ""
            let cid = viewModel.selectedConversation?.id ?? ""
            return dtos.filter { $0.segments != nil }.flatMap { dto in
                (MessageHTMLSegments.split(dto.text) ?? []).filter { $0.kind == .html }.map {
                    (HTMLEmbedIdentity(profileId: pid, conversationId: cid, nodeId: dto.id, segmentId: $0.id), $0.content)
                }
            }
        }

        func applySkin() {
            guard webReady else { return }
            commander.applyBase(ChatSkinStore.baseCSS())
            let css = ChatSkinStore.activeSkinCSS() ?? ""
            commander.applySkin(css)
            KBProbe.log("[CSSCHAT] 皮肤已应用: \(ChatSkinStore.activeSkinName() ?? "默认") (\(css.count) 字节)")
        }

        /// `‹ ›` 只给方向；切的是这条的分叉点（branchNodeId），不是这条自己
        func switchBranch(nodeId: String, delta: Int) {
            guard let info = viewModel.branchInfoMap[nodeId], info.branchCount > 1 else { return }
            let next = (info.currentIndex + delta + info.branchCount) % info.branchCount   // 两端绕回
            viewModel.switchBranch(at: info.branchNodeId, to: next)
        }

        /// web 点 ⋯ / 菜单里选了某项。全是 VM 现成方法。
        func handleAction(_ name: String, nodeId: String) {
            guard let node = viewModel.currentPath.first(where: { $0.id == nodeId }) else { return }
            switch name {
            case "menu":
                presentMenu(for: node)
            case "copy":
                UIPasteboard.general.string = node.content
            case "favorite":
                viewModel.toggleFavorite(node)
            case "pin":
                viewModel.togglePin(node)
            case "delete":
                viewModel.softDelete(node)
            case "edit":
                editingNodeId = nodeId
                commander.fillInput(node.content)
            case "regenerate":
                regenerate(node)
            default:
                KBProbe.log("[CSSCHAT] 未知 action \(name)")
            }
        }

        /// 原生 action sheet。放 Coordinator 里弹，省掉一条 View↔Coordinator 的回调通道。
        private func presentMenu(for node: MessageNode) {
            guard let host = webView?.owningViewController() else { return }
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            let items: [(String, UIAlertAction.Style, String)] = [
                ("复制", .default, "copy"),
                (node.role == "user" ? "编辑" : "", .default, "edit"),
                ("重新生成", .default, "regenerate"),
                (node.isFavorite ? "取消收藏" : "收藏", .default, "favorite"),
                (node.isPinned ? "取消置顶" : "置顶", .default, "pin"),
                ("删除", .destructive, "delete"),
            ]
            for (title, style, action) in items where !title.isEmpty {
                sheet.addAction(UIAlertAction(title: title, style: style) { [weak self] _ in
                    self?.handleAction(action, nodeId: node.id)
                })
            }
            sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
            // iPad 上 actionSheet 是 popover，没 anchor 会崩
            if let pop = sheet.popoverPresentationController, let wv = webView {
                pop.sourceView = wv
                pop.sourceRect = CGRect(x: wv.bounds.midX, y: wv.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            host.present(sheet, animated: true)
        }

        private func regenerate(_ node: MessageNode) {
            guard let prof = deps.profile, let pm = deps.providerManager, let ctx = deps.modelContext else { return }
            let preset = deps.preset ?? Preset.balanced
            let model = pm.resolveModel(
                conversationModelId: viewModel.selectedConversation?.selectedModelId,
                globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
            if node.role == "assistant" {
                viewModel.regenerate(assistantNodeId: node.id, model: model, profile: prof,
                                     preset: preset, providerManager: pm, context: ctx)
            } else {
                // user 重新生成 = 原文重发建分支（同 CardFlowView 的做法）
                viewModel.editAndResend(node.id, newText: node.content, model: model, profile: prof,
                                        preset: preset, providerManager: pm, context: ctx)
            }
        }

        /// 发送。取值链抄 CardFlowView.makeRegenerateAction（:3355）——
        /// 只调 viewModel 现成的方法，不碰主聊天任何代码。
        func send(_ text: String) {
            guard !text.isEmpty else { return }
            guard let prof = deps.profile, let pm = deps.providerManager, let ctx = deps.modelContext else {
                commander.reportError(code: "no_context", message: "没拿到发送上下文")
                return
            }
            let preset = deps.preset ?? Preset.balanced
            let model = pm.resolveModel(
                conversationModelId: viewModel.selectedConversation?.selectedModelId,
                globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
            viewModel.selectedConversation?.selectedModelId = model.id

            // 编辑态：这一发是改旧消息重发（建分支），不是发新消息
            if let editId = editingNodeId {
                editingNodeId = nil
                viewModel.editAndResend(editId, newText: text, isEdit: true, model: model, profile: prof,
                                        preset: preset, providerManager: pm, context: ctx)
                return
            }
            let atts = viewModel.selectedAttachments
            let ok = viewModel.sendMessage(text, model: model, profile: prof, preset: preset,
                                           providerManager: pm, context: ctx, attachments: atts)
            if ok {
                viewModel.selectedAttachments = []      // 订阅会把空 chips 推回 web
            } else {
                commander.reportError(code: "send_failed", message: "发送失败")
            }
        }

        // MARK: - 数据 → web

        private func context() -> ChatRenderContext {
            let convId = viewModel.selectedConversation?.id ?? ""
            let streamingId = viewModel.currentPath.last {
                $0.role == "assistant" && viewModel.isNodeStreaming(nodeId: $0.id, conversationId: convId)
            }?.id
            return ChatRenderContext(
                regexScripts: regexScripts, userName: userName, assistantName: assistantName,
                showThinking: showThinking, branchInfo: viewModel.branchInfoMap,
                streamingNodeId: streamingId, cardName: boundCard()?.name)
        }

        /// 窗口化：只渲染最近 N 条（花园真有几千条的对话）
        private func windowed() -> [MessageNode] {
            let path = viewModel.currentPath
            return path.count > ChatRenderContext.windowSize
                ? Array(path.suffix(ChatRenderContext.windowSize)) : path
        }

        func renderAll() {
            // 冷启动直接进 Page2 时，主聊天页从没走过加载流程 → currentPath 是空的。
            // 这里补一刀（loadConversation 是 VM 现成的方法，主聊天页自己也是这么加载的）。
            if viewModel.needsInitialLoad,
               let conv = viewModel.selectedConversation,
               let ctx = deps.modelContext {
                KBProbe.log("[CSSCHAT] currentPath 空，补加载对话 \(conv.id)")
                viewModel.loadConversation(conv, context: ctx)
            }
            let nodes = windowed()
            let ctx = context()
            let dtos = nodes.map { ChatMessageDTO(node: $0, ctx: ctx) }
            embed.replaceSources(htmlSources(dtos))
            lastStructure = ChatMessageDTO.structureFingerprint(nodes)
            lastContent = Dictionary(uniqueKeysWithValues: dtos.map { ($0.id, $0.contentFingerprint) })
            commander.render(ChatRenderPayload(
                messages: dtos, theme: "light",
                placeholder: viewModel.selectedConversation == nil ? "先在聊天页选一个对话" : "说点什么…"))
            KBProbe.log("[CSSCHAT] render \(dtos.count) 条")
            autoRun()       // B6：web 那边的段建好之后再挂（同一条 JS 队列，先 render 后 attach）
        }

        /// R5 两级推送：结构变（切分支/删除/新消息）→ 全量；内容变（编辑/收藏/流式）→ patchNode。
        /// 判据用指纹，因为 MessageNode 没有 updatedAt。
        func pushUpdate() {
            guard webReady else { return }
            let nodes = windowed()
            let structure = ChatMessageDTO.structureFingerprint(nodes)
            if structure != lastStructure { renderAll(); return }
            let ctx = context()
            for node in nodes {
                let dto = ChatMessageDTO(node: node, ctx: ctx)
                let fp = dto.contentFingerprint
                if lastContent[dto.id] != fp {
                    lastContent[dto.id] = fp
                    embed.updateSources(nodeId: dto.id, htmlSources([dto]))
                    commander.patchNode(dto)
                }
            }
            autoRun()       // B6：生成结束 / 正文换了
        }

        private var lastChipIds: [String] = []

        /// 待发送附件 → web chips。全量推，不做增量（附件个数很少，可靠优先）
        func pushChips() {
            guard webReady else { return }
            let atts = viewModel.selectedAttachments
            let ids = atts.map(\.id.uuidString)
            guard ids != lastChipIds else { return }
            lastChipIds = ids
            commander.setChips(atts.map {
                ChatAttachmentDTO(id: $0.id.uuidString,
                                  kind: $0.isImage ? "image" : "file",
                                  name: $0.name)
            })
        }

        /// 抄 StreamingMarkdownSource.swift:57-75 —— withObservationTracking 是**单次**触发，
        /// onChange 里必须重新注册，否则只收到第一次变化。
        func observe() {
            withObservationTracking {
                _ = viewModel.currentPath
                _ = viewModel.branchInfoMap
                _ = viewModel.selectedAttachments
                _ = viewModel.assistantTurnInFlight     // B4：生成开始 / 结束事件
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.pushUpdate()
                    self.pushChips()
                    self.embed.emit(self.cardScript.tick(hasInteractive: self.embed.interactive != nil))
                    self.observe()
                }
            }
        }

        /// 卡库 ⑦：主 frame 只许受控 chat.html；子 frame 只许登记过的 mp-card 文档。
        /// 用户在子文档里点的 http(s) 链接不在 frame 里开，交宿主确认
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let isMain = navigationAction.targetFrame?.isMainFrame ?? false
            if HTMLEmbedBridgeGate.allowsNavigation(to: url, isMainFrame: isMain, controlledDocument: ChatSkinStore.documentURL,
                                                    isRegistered: { [embed] in embed.registry.entry($0) != nil }) {
                decisionHandler(.allow)
                return
            }
            KBProbe.log("[HTMLEMBED] 拦截导航 main=\(isMain) \(url?.absoluteString.prefix(120) ?? "nil")")
            if navigationAction.navigationType == .linkActivated, let link = HTMLEmbedBridgeGate.externalLink(url?.absoluteString) {
                confirmOpenLink(link)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // WKContentView 要页面起来才存在，accessory 只能这时候摘
            webView.disableKeyboardInputAccessory()
        }

        /// 内容进程被杀 → 白屏。聊天是长驻页，内存压力下必踩。
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            KBProbe.log("[CSSCHAT] 内容进程被杀，reload")
            embed.suspend(inWeb: false)     // ⑦ 旧页面的 iframe 全没了，token 一并作废
            webView.reload()
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            // 卡库 ⑦ / 审查 #4：handler 对页面里所有 frame 可见，iframe 能直接 postMessage 到这里。
            // 只认主 frame + 受控主文档（chat.html），且必须是本宿主的 webView
            guard message.frameInfo.isMainFrame,
                  message.webView === webView,
                  HTMLEmbedBridgeGate.acceptsHostMessage(isMainFrame: message.frameInfo.isMainFrame,
                                                         frameURL: message.frameInfo.request.url,
                                                         controlledDocument: ChatSkinStore.documentURL) else {
                KBProbe.log("[HTMLEMBED] 拒绝非主文档消息 main=\(message.frameInfo.isMainFrame) url=\(message.frameInfo.request.url?.absoluteString.prefix(80) ?? "nil")")
                return
            }
            guard let msg = ChatWebMessage(body: message.body) else { return }
            switch msg {
            case .ready(let caps):
                KBProbe.log("[CSSCHAT] ready caps=\(caps.joined(separator: ","))")
                embed.suspend(inWeb: false)     // ⑦ 新页面：旧 token 全作废
                webReady = true
                renderAll()
                pushChips()
                observe()
                applySkin()

            case .send(let text, let ids):
                KBProbe.log("[CSSCHAT] send len=\(text.count) atts=\(ids.count)")
                send(text)

            case .action(let name, let nodeId):
                handleAction(name, nodeId: nodeId)

            case .switchBranch(let nodeId, let delta):
                switchBranch(nodeId: nodeId, delta: delta)

            case .pickAttachment:
                onPickAttachment()

            case .removeAttachment(let id):
                viewModel.selectedAttachments.removeAll { $0.id.uuidString == id }

            case .scrolled:
                break   // 高频，不打日志

            case .probe(let vv, let offTop, let win, let atBottom):
                let host = webView.map(Self.hostInsetDescription) ?? "hostVC=?"
                KBProbe.log("[CSSCHAT] vv=\(vv) offTop=\(offTop) win=\(win) bottom=\(atBottom) | \(host)")

            case .errorAck(let code, let m):
                KBProbe.log("[CSSCHAT] errorAck \(code) \(m)")

            case .html(let m):
                embed.handle(m)
            }
        }

        /// 沿 responder 链往上找承载这个 webview 的 VC，报它的 additionalSafeAreaInsets。
        /// > 0 就说明外层还在做 safe-area 避让 = 双重避让。
        private static func hostInsetDescription(of view: UIView) -> String {
            var responder: UIResponder? = view
            while let r = responder {
                if let vc = r as? UIViewController {
                    let add = vc.additionalSafeAreaInsets.bottom
                    return String(format: "addInset=%.1f%@", add, add > 1 ? " ⚠️双重避让" : " ✅单层")
                }
                responder = r.next
            }
            return "hostVC=?"
        }

    }
}
#endif
