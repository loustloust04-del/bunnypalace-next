#if os(iOS)
import Foundation
import SwiftData
import UIKit

/// 卡库第二批 B3 / B4：Page2 宿主这一侧的酒馆助手 API 执行者。
/// 把 ConversationViewModel 的当前路径整理成楼层（合成根 / 不显示节点不算楼，swipes＝分叉点的孩子），
/// 出快照、执行已过 CardScriptGate 的写（变量 / 正文 / 切 swipe），按路径差分出事件。
/// 只走 VM 现成的方法（switchBranch）和 node / conversation 上的三个新列，不碰主聊天别的代码
@MainActor
final class Page2CardScriptAdapter {
    let viewModel: ConversationViewModel
    var deps: () -> ChatSendDeps = { ChatSendDeps() }
    /// Page2 显示用的名字（有效身份），没楼层时兜底
    var fallbackNames: () -> (char: String, user: String) = { ("助手", "你") }

    /// 事件差分基线（只在有交互实例时维护）
    private var baseline: [CardEventFloorSig]?
    private var wasGenerating = false
    private var avatarCache: (key: String, css: String?)?

    init(viewModel: ConversationViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - 快照 / 头像

    func bridge(for identity: HTMLEmbedIdentity, mode: HTMLEmbedMode) -> HTMLEmbedBridge {
        var b = HTMLEmbedBridge(segmentId: identity.segmentId, snapshot: nil, avatarCSS: avatarCSS())
        if mode == .interactive {
            b.snapshot = snapshot(ownNodeId: identity.nodeId)
            resetBaseline()
        }
        return b
    }

    private func names() -> EffectiveCharacterContext {
        if let profile = deps().profile {
            return EffectiveCharacterContext(profile: viewModel.personaResolution(profile: profile).applied(to: profile))
        }
        let f = fallbackNames()
        return EffectiveCharacterContext(charName: f.char, userName: f.user)
    }

    /// B5：slash 里的 `{{char}}` / `{{user}}`（与快照同一份有效身份）
    func displayNames() -> (char: String, user: String) {
        let ctx = names()
        return (ctx.charName, ctx.userName)
    }

    func snapshot(ownNodeId: String) -> String {
        let path = viewModel.currentPath
        let ctx = names()
        let chat = viewModel.selectedConversation.map {
            CardVariables.effectiveChat(stored: $0.cardVariablesData, conversationMetadata: $0.sourceMetadata)
        } ?? [:]
        return CardScriptSnapshot.build(
            count: path.count, floor: { self.floor(path[$0], ctx: ctx) },
            currentId: path.firstIndex { $0.id == ownNodeId } ?? -1,
            chat: chat, charName: ctx.charName, userName: ctx.userName)
    }

    /// 一楼：显示路径上的节点 + 它分叉点的全部孩子（顺序同 `‹ n / m ›`）
    private func floor(_ node: MessageNode, ctx: EffectiveCharacterContext) -> CardSnapshotFloor {
        let siblings = swipeNodes(of: node)
        let selectedMeta = siblings.compactMap { $0 }.first { CardVariables.isSelectedCandidate($0.sourceMetadata) }?.sourceMetadata
            ?? node.sourceMetadata
        let index = siblings.firstIndex { $0?.id == node.id } ?? 0
        let texts = siblings.map { ctx.expand($0?.content ?? "") }
        let datas = siblings.enumerated().map { i, n -> [String: Any] in
            guard let n else { return [:] }
            return CardVariables.effectiveMessage(stored: n.cardVariablesData, nodeMetadata: n.sourceMetadata,
                                                  selectedMetadata: selectedMeta, fallbackIndex: i)
        }
        let isUser = node.role == "user"
        return CardSnapshotFloor(role: isUser ? "user" : "assistant", name: isUser ? ctx.userName : ctx.charName,
                                 message: ctx.expand(node.content), swipeId: index, swipes: texts, swipesData: datas)
    }

    /// 分叉点孩子 → 各自第一条可显示的节点；没分叉就只有自己
    private func swipeNodes(of node: MessageNode) -> [MessageNode?] {
        guard let info = viewModel.branchInfoMap[node.id], info.branchCount > 1 else { return [node] }
        var out = [MessageNode?](repeating: nil, count: info.branchCount)
        for child in info.branchChildren where out.indices.contains(child.index) { out[child.index] = child.node }
        if out.indices.contains(info.currentIndex) { out[info.currentIndex] = node }
        return out
    }

    private func pathFloors() -> [CardPathFloor] {
        viewModel.currentPath.map { node in
            guard let info = viewModel.branchInfoMap[node.id] else { return CardPathFloor(nodeId: node.id) }
            return CardPathFloor(nodeId: node.id, forkId: info.branchNodeId, swipeCount: info.branchCount, swipeIndex: info.currentIndex)
        }
    }

    /// 头像类名（.user_avatar / .char_avatar）→ 96px JPEG data: URI；子文档 CSP 只放 data: 图
    private func avatarCSS() -> String? {
        let p = deps().profile
        let key = "\(p?.id ?? "")|\(p?.userAvatarData?.count ?? 0)|\(p?.assistantAvatarData?.count ?? 0)"
        if let c = avatarCache, c.key == key { return c.css }
        var rules: [String] = []
        if let u = p?.userAvatarData.flatMap(Self.thumbnailDataURI) { rules.append(".user_avatar,.user-avatar{background-image:url('\(u)')}") }
        if let a = p?.assistantAvatarData.flatMap(Self.thumbnailDataURI) { rules.append(".char_avatar,.char-avatar{background-image:url('\(a)')}") }
        let css = rules.isEmpty ? nil : rules.joined(separator: "\n")
        avatarCache = (key, css)
        return css
    }

    private static func thumbnailDataURI(_ data: Data) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        let side: CGFloat = 96
        let scale = min(1, side / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = small.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    // MARK: - 执行

    /// 已过闸的请求：按调用当下的路径解析楼层，先写正文 / 变量再切 swipe，同一次保存。成功返回要不要重渲染
    func execute(_ request: CardScriptRequest, identity: HTMLEmbedIdentity) -> Result<Bool, CardScriptRejection> {
        guard let conversation = viewModel.selectedConversation, conversation.id == identity.conversationId else {
            return .failure(.identityMismatch)
        }
        let steps: [CardWriteStep]
        switch CardScriptPlanner.plan(request, path: pathFloors(), ownNodeId: identity.nodeId) {
        case .failure(let e): return .failure(e)
        case .success(let s): steps = s
        }
        let byId = Dictionary(viewModel.currentPath.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for step in steps {
            switch step {
            case .editMessage(let nodeId, let text):
                guard let node = byId[nodeId] else { continue }
                if node.content != text {
                    node.content = text
                    node.cardEditedAt = Date()
                }
            case .setMessageVariables(let nodeId, let table):
                byId[nodeId]?.cardVariablesData = table
            case .setChatVariables(let table):
                conversation.cardVariablesData = table
            case .switchSwipe(let forkId, let index):
                viewModel.switchBranch(at: forkId, to: index)     // 唯一 resolver，选择表与 currentNodeId 同一次保存
            }
        }
        try? (deps().modelContext ?? conversation.modelContext)?.save()
        resetBaseline()           // 自己写出来的变化不当事件推回去（同酒馆助手 setChatMessages 不发 MESSAGE_EDITED）
        if case .setChatMessages(_, let refresh) = request { return .success(refresh != "none") }
        return .success(false)
    }

    // MARK: - 事件

    private func sigs() -> [CardEventFloorSig] {
        viewModel.currentPath.map { node in
            CardEventFloorSig(nodeId: node.id, role: node.role, contentHash: node.content.hashValue,
                              forkId: viewModel.branchInfoMap[node.id]?.branchNodeId)
        }
    }

    private func resetBaseline() {
        baseline = sigs()
        wasGenerating = viewModel.isCurrentConvResponding
    }

    /// 观察到 VM 变化时调：有交互实例才差分，没有就丢掉基线
    func tick(hasInteractive: Bool) -> [CardScriptEvent] {
        guard hasInteractive else { baseline = nil; return [] }
        let now = sigs()
        let generating = viewModel.isCurrentConvResponding
        defer { baseline = now; wasGenerating = generating }
        guard let old = baseline else { return [] }
        return CardScriptEvents.diff(old: old, new: now, wasGenerating: wasGenerating, isGenerating: generating)
    }
}
#endif
