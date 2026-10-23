import SwiftUI
import SwiftData
import SwiftStreamingMarkdown
import os

/// 网页卡宿主能力桥日志：`log show --predicate 'subsystem == "MemoryPalace" AND category == "cardbridge"'`
let cardBridgeLog = Logger(subsystem: "MemoryPalace", category: "cardbridge")

/// 同一时间只有一张网页卡在运行（research-chat-cards §7.4）
/// 卡库 ⑦ 起全应用共用：原生网页卡的 runKey 和 Page2 聊天的 "page2|…" 都写这里，谁点运行谁把旧的挤掉
@Observable @MainActor
final class HTMLCardRunCoordinator {
    static let shared = HTMLCardRunCoordinator()
    var runningKey: String?
}

/// 网页卡（research-chat-cards §7.2）：首屏截图 + 标题；点开完整页；「运行」原地换活网页
/// 卡库 ⑦ 起：首屏截图换成消息内直接静态显示（iframe sandbox=""，不跑脚本），固定 360pt、可展开、内部滚动；
/// 每个宿主最多 2 个可见静态实例，超额保高度占位；「运行」要网页脚本总开关开 + 绑定卡已启用（非卡聊天只看总开关）
struct HTMLCardView: View {
    let content: String
    /// 卡片所在消息；nil（流式尾巴 / 文件库预览）时不开宿主能力桥（§13）
    var nodeId: String? = nil
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(\.modelContext) private var modelContext
    @AppStorage(LocalMode.key) private var localMode = true
    @AppStorage(CardLibraryPreferences.allowWebScriptsKey) private var allowWebScripts = false
    @State private var showPreview = false
    @State private var savedPath: String?
    @State private var runKey = UUID().uuidString
    @State private var visible = false
    @State private var hasSlot = false
    @State private var expanded = false
    @State private var denial: String?
    /// 第二批 B2：卡聊天的网页被挡掉的外部资源（按地址去重）；静态上报脚本的 nonce 存住免得 payload 每次变
    @State private var blocked: [CardBlockedResource] = []
    @State private var showBlocked = false
    @State private var cardNonce = HTMLPreviewCard.makeNonce()
    /// §13：本次运行的桥（点运行时新建，收起时作废）+ 等原生确认的请求和它的回复通道
    @State private var bridge: HTMLCardBridgeSession?
    @State private var confirming: HTMLCardRequest?
    @State private var confirmReply: (([String: Any]) -> Void)?

    private var coordinator: HTMLCardRunCoordinator { .shared }
    private var slots: HTMLCardStaticSlots { .native }
    private var running: Bool { coordinator.runningKey == runKey }
    private var title: String { Self.pageTitle(content) ?? "网页" }
    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var boundCard: CharacterCard? {
        HTMLEmbedPermission.boundCard(profileId: profileManager?.currentProfile.id,
                                      cards: profileManager?.characterCardManager?.cards ?? [])
    }
    private var runDenial: String? {
        HTMLEmbedPermission.runDenial(allowWebScripts: allowWebScripts, boundCard: boundCard)
    }
    /// 卡聊天 → 和 Page2 同一份联网策略；非卡（AI 自己写的网页）nil = 维持现状。
    /// 本地模式开着：已许可的卡也只留内置库（白名单全挡，同 Page2 的 .cardLocal）
    private var cardWeb: HTMLPreviewCard? {
        boundCard.map {
            let allowed = $0.extensionConsent == .allowed
            return HTMLPreviewCard(allowed: allowed && !localMode, nonce: cardNonce, localMode: allowed && localMode)
        }
    }

    static func pageTitle(_ html: String) -> String? {
        guard let range = html.range(of: #"<title[^>]*>[\s\S]*?</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = String(html[range])
            .replacingOccurrences(of: #"^<title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</title>$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            card
            if !blocked.isEmpty { blockedBadge }
        }
        .sheet(isPresented: $showPreview) {
            HTMLArtifactPreviewSheet(content: content, profileId: profileId, scriptsAllowed: runDenial == nil, card: cardWeb)
        }
        .alert("已保存到文件库", isPresented: Binding(get: { savedPath != nil }, set: { if !$0 { savedPath = nil } })) {
            Button("好") { savedPath = nil }
        } message: {
            Text(savedPath ?? "")
        }
        .alert("还不能运行", isPresented: Binding(get: { denial != nil }, set: { if !$0 { denial = nil } })) {
            Button("好") { denial = nil }
        } message: {
            Text(denial ?? "")
        }
        // §13 确认由 app 画：网页里的按钮可以被写成任何样子，只有这里可信。
        // 没点按钮就关掉 = 不要。iOS 的按钮回调要等关闭动画走完才来，「关掉」比它先到：
        // 等 1 秒还没有回调才算拒（模拟器实测：之前只晚一拍，把「加入」判成了拒）
        .alert(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { shown in
            guard !shown, let pending = confirming else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if confirming == pending { resolveConfirm(allowed: false) }
            }
        })) {
            Button("不要", role: .cancel) { resolveConfirm(allowed: false) }
            Button("加入") { resolveConfirm(allowed: true) }
        } message: {
            Text(confirmMessage)
        }
        .onAppear { visible = true; claimSlot() }
        .onDisappear {                                                                      // 离屏收起 + 让出静态名额
            visible = false
            releaseSlot()
            if running { coordinator.runningKey = nil }
        }
        .onChange(of: slots.holders) { _, _ in claimSlot() }                               // 别的卡让出名额 → 补上
        .onChange(of: running) { _, now in                                                  // 交互不占静态名额
            if now { releaseSlot() } else { claimSlot(); closeBridge() }
        }
        .onChange(of: localMode) { _, _ in if running { coordinator.runningKey = nil } }   // 切本地模式收起
        .onChange(of: runDenial) { _, reason in if reason != nil, running { coordinator.runningKey = nil } }   // 关总开关 / 撤卡许可
        .onChange(of: content) { _, _ in blocked = [] }
        .onChange(of: cardWeb) { _, _ in blocked = [] }                                     // 许可变了按新策略重挂，重新计数
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { showPreview = true }
                Spacer(minLength: 4)
                pill(expanded ? "收拢" : "展开", systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    expanded.toggle()
                }
                pill(running ? "收起" : "运行", systemImage: running ? "stop.fill" : "play.fill") {
                    if running {
                        coordinator.runningKey = nil
                    } else if let reason = runDenial {
                        denial = reason
                    } else {
                        // 桥先建好再运行：网页第一次加载就带上令牌，不用为补令牌重载一次
                        bridge = bridgeAvailable ? HTMLCardBridgeSession(token: UUID().uuidString) : nil
                        coordinator.runningKey = runKey
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if running {
                Text(bridgeAvailable ? "卡片能请你加待办、生词（会先问你），也能往输入框放一句话"
                                     : "交互还不完整：变量、生成等酒馆助手功能暂不支持")
                    .font(.system(size: 11))
                    .foregroundStyle(CodeBlockStyle.label)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            MintHairline()
            Group {
                if running {
                    HTMLPreviewWebView(content: content, card: cardWeb, onBlocked: recordBlocked, bridgeToken: bridge?.token,
                                       onCardRequest: bridge == nil ? nil : { body, reply in handleCardRequest(body, reply: reply) })
                } else if hasSlot {
                    HTMLPreviewWebView(content: content, staticMode: true, card: cardWeb, onBlocked: recordBlocked)
                } else {
                    Text("滚到这里显示")
                        .font(.system(size: 12))
                        .foregroundStyle(CodeBlockStyle.label)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: expanded ? 720 : 360)
        }
        .mintCard()
        .contextMenu {
            Button("打开完整页") { showPreview = true }
            Button("保存到文件库") {
                savedPath = saveArtifactToLibrary(content: content, title: Self.pageTitle(content), profileId: profileId)
            }
            Button("复制源码") { PlatformClipboard.copyString(content) }
        }
    }

    private func recordBlocked(_ report: String) {
        guard let item = CardBlockedResource.parse(report), blocked.count < 100,
              !blocked.contains(where: { $0.url == item.url }) else { return }
        blocked.append(item)
    }

    /// 小样 04：卡片外右下角报数，点开列域名 + 类型（未许可的卡也显示）
    private var blockedBadge: some View {
        Button { showBlocked = true } label: {
            Label("挡掉了 \(blocked.count) 个外部资源", systemImage: "shield")
                .font(.system(size: 10))
                .foregroundStyle(CodeBlockStyle.label)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.textPrimary.opacity(0.05)))
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showBlocked) {
            HTMLBlockedResourcesPopover(items: blocked, note: cardWeb.map {
                $0.localMode ? CardBlockedResource.localModeNote : ($0.allowed ? "" : CardBlockedResource.notAllowedNote)
            } ?? CardBlockedResource.notAllowedNote)
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - 宿主能力桥（research-chat-cards §13）

    /// 要知道卡在哪条消息、哪个对话里；文件库 / 流式尾巴里没有就不开
    private var bridgeAvailable: Bool { nodeId != nil && viewModel?.selectedConversation != nil }

    /// 收起 / 离屏：挂着的确认回 closed，桥作废（下次运行换新令牌）
    private func closeBridge() {
        if let step = bridge?.cancelPending(), case .reply(let id, let error) = step, let reply = confirmReply {
            send(reply, id: id, error: error)
        }
        confirming = nil
        confirmReply = nil
        bridge = nil
    }

    private func handleCardRequest(_ body: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let bridge else { cardBridgeLog.info("request with no bridge"); return }
        let step = bridge.receive(body, running: running)
        cardBridgeLog.info("request \(String(describing: body["action"]), privacy: .public) -> \(String(describing: step), privacy: .public)")
        switch step {
        case .reply(let id, let error):
            send(reply, id: id, error: error)
        case .confirm(let request):
            confirming = request
            confirmReply = reply
        case .perform(let request):
            send(reply, id: request.id, error: perform(request.action))
        }
    }

    private func resolveConfirm(allowed: Bool) {
        cardBridgeLog.info("confirm allowed=\(allowed) pending=\(confirming != nil) reply=\(confirmReply != nil)")
        let reply = confirmReply
        confirming = nil
        confirmReply = nil
        guard let step = bridge?.resolve(allowed: allowed), let reply else { return }
        switch step {
        case .reply(let id, let error): send(reply, id: id, error: error)
        case .perform(let request): send(reply, id: request.id, error: perform(request.action))
        case .confirm: break
        }
    }

    /// 真去做；返回 nil = 成功
    private func perform(_ action: HTMLCardAction) -> HTMLCardBridgeError? {
        guard let viewModel, let conversationId = viewModel.selectedConversation?.id else { return .closed }
        switch action {
        case .addTodo(let text, let date):
            TodoManager.shared.add(text, date: date)
            ToastCenter.shared.show("已加待办「\(text)」")
        case .addVocab(let word):
            // 同聊天里划词收生词（ChatMarkdownView.collect）：生词本 + 开着自动复习就进牌堆
            guard let collected = VocabCollector.collectManually(rawText: word, anchor: nil, chatNodeId: nodeId,
                                                                 context: modelContext) else { return .invalid }
            if VocabCollector.autoReviewEnabled {
                VocabCardStore.addIfAbsent(word: collected, source: "chat", dir: VocabCollector.reviewDeckDir)
            }
            ToastCenter.shared.show("已收「\(collected)」")
        case .ask(let text):
            viewModel.insertIntoComposer(text)
        case .report(let text):
            viewModel.cardEventOutbox.add(text, conversationId: conversationId)
        }
        return nil
    }

    private func send(_ reply: ([String: Any]) -> Void, id: String, error: HTMLCardBridgeError?) {
        cardBridgeLog.info("reply \(id, privacy: .public) error=\(error?.rawValue ?? "nil", privacy: .public)")
        var payload: [String: Any] = ["type": "cardReply", "id": id, "ok": error == nil]
        if let error { payload["error"] = error.rawValue }
        reply(payload)
    }

    private var confirmTitle: String {
        switch confirming?.action {
        case .addVocab: return "这张卡想加一个生词"
        default: return "这张卡想加一条待办"
        }
    }

    private var confirmMessage: String {
        switch confirming?.action {
        case .addTodo(let text, let date): return date.map { "\(text)\n（\($0)）" } ?? text
        case .addVocab(let word): return word
        default: return ""
        }
    }

    private func claimSlot() {
        guard visible, !running, !hasSlot else { return }
        hasSlot = slots.acquire(runKey)
    }

    private func releaseSlot() {
        slots.release(runKey)
        hasSlot = false
    }

    private func pill(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(CodeBlockStyle.body.opacity(0.92)))
                .overlay(Capsule().strokeBorder(CodeBlockStyle.stroke, lineWidth: 1))
                .foregroundStyle(CodeBlockStyle.label)
        }
        .buttonStyle(.plain)
    }
}

/// 卡库第二批（小样 ②）：被卡里的网页改过正文的消息，分支行后 11 号浅灰「edited」+ 小笔；点开浮层说明（Page2 同一份文案）
struct CardEditedMark: View {
    let cardName: String?
    let editedAt: Date
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "pencil").font(.system(size: 10, weight: .medium))
                Text(CardEditedText.label).font(.system(size: 11))
            }
            .foregroundColor(Theme.textMuted)
            .padding(.leading, 4).padding(.trailing, 6).padding(.vertical, 1)
            .background(Capsule().fill(Theme.textPrimary.opacity(0.05)))
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("网页改过，点开看说明")
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 3) {
                Text(CardEditedText.title(cardName: cardName, at: editedAt))
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CardEditedText.note).font(.system(size: 11)).foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(width: 260, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// 「挡掉了 N 个外部资源」点开的列表（小样 04）：只列域名 + 类型，不列完整地址
struct HTMLBlockedResourcesPopover: View {
    let items: [CardBlockedResource]
    /// 没许可 / 本地模式时多出的一句；空 = 不显示
    var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("挡掉了 \(items.count) 个外部资源").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(CardBlockedResource.rows(items).enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.host).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.kind.label).font(.system(size: 10)).foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .frame(minHeight: 30)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.textPrimary.opacity(0.08)).frame(height: 0.5) }
                }
            }
            if !note.isEmpty {
                Text(note).font(.system(size: 11)).foregroundColor(Theme.textMuted)
            }
            Text(CardBlockedResource.footnote).font(.system(size: 11)).foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(width: 280, alignment: .leading)
    }
}
