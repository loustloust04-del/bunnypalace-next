import SwiftUI
import Observation

/// page1 消息的表情回应（粟粟 10-01：长按菜单顶上那行换成表情，照群聊抄）。
/// 存本机（UserDefaults：消息 id → 按点的先后排的表情）；点了 / 取消都进待捎带箱，下次发消息带给模型（§13，解 §12.4）。
@MainActor
@Observable
final class ChatReactionStore {
    static let shared = ChatReactionStore()
    /// 表情条：与群聊 GroupMessageActionOverlay.emojis 同一套（那边只在 iOS 编，这里 mac 也要用，抄一份）
    static let emojis = ["👍", "❤️", "😂", "👀", "🎉", "🔥", "😢", "🤔", "✅", "🙏", "💯", "❌"]

    private let defaults: UserDefaults
    private let key: String
    private(set) var byNode: [String: [String]]
    /// AI 贴在她消息上的（10-29：```react 块），和她自己点的分开存（徽标同样白底、点不掉）
    private(set) var aiByNode: [String: [String]]

    init(defaults: UserDefaults = .standard, key: String = "chatReactions") {
        self.defaults = defaults
        self.key = key
        byNode = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        aiByNode = defaults.dictionary(forKey: key + ".ai") as? [String: [String]] ?? [:]
    }

    /// AI 贴的：块级 key 优先，整条消息的 key 挂在第 0 个泡
    func aiReactions(for target: ChatReactionTarget) -> [String] {
        if let list = aiByNode[Self.key(for: target)] { return list }
        if target.blockIndex == 0 || target.blockIndex == nil, let whole = aiByNode[target.nodeId] { return whole }
        return []
    }

    /// AI 贴一个（同一个不重复贴）。返回 true = 新贴上
    @discardableResult
    func addAIReaction(_ emoji: String, on nodeId: String) -> Bool {
        var list = aiByNode[nodeId] ?? []
        guard !list.contains(emoji) else { return false }
        list.append(emoji)
        aiByNode[nodeId] = list
        defaults.set(aiByNode, forKey: key + ".ai")
        return true
    }

    /// 待捎带箱里这条是她「新贴」的表情（撤销已发表情的「收回了」、AI 自己贴的记录都不单独触发回复）
    nonisolated static func isAddEvent(_ event: ChatCardEvent) -> Bool {
        (event.key?.hasPrefix("reaction:") ?? false) && !event.text.hasPrefix("收回了") && event.carried != true
    }

    /// 表情事件和现在实际的表情状态还对得上吗（归还后核对用）：「回了 X」要求 X 还在，「收回了 X」要求 X 不在；别的事件不管
    func stillHolds(_ event: ChatCardEvent) -> Bool {
        guard let key = event.key, key.hasPrefix("reaction:") else { return true }
        let parts = key.dropFirst("reaction:".count).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return true }
        let present = reactions(for: parts[0]).contains(parts[1])
        return event.text.hasPrefix("收回了") ? !present : present
    }

    func reactions(for nodeId: String) -> [String] { byNode[nodeId] ?? [] }

    /// 按目标取回应：块级 key 优先；旧数据（整条消息的 key）只在第 0 个泡向后兼容可读
    func reactions(for target: ChatReactionTarget) -> [String] {
        let key = Self.key(for: target)
        if let list = byNode[key] { return list }
        if target.blockIndex == 0, let old = byNode[target.nodeId] { return old }
        return []
    }

    /// 存储 key：块级为 "nodeId#块序号"，整条消息为 nodeId（旧格式）
    static func key(for target: ChatReactionTarget) -> String {
        if let i = target.blockIndex { return "\(target.nodeId)#\(i)" }
        return target.nodeId
    }

    /// 点一次加上，同一个再点一次取消（同群聊）。返回 true = 这次是加上
    @discardableResult
    func toggle(_ emoji: String, on nodeId: String) -> Bool {
        var list = byNode[nodeId] ?? []
        let added: Bool
        if let i = list.firstIndex(of: emoji) { list.remove(at: i); added = false } else { list.append(emoji); added = true }
        byNode[nodeId] = list.isEmpty ? nil : list
        defaults.set(byNode, forKey: key)
        return added
    }

    /// 界面上点的都走这个：顺带告诉模型。还没发出去就取消 → 箱里那条撤掉；已经带过去了再取消 → 补一条「收回了」
    func toggle(_ emoji: String, on target: ChatReactionTarget, outbox: ChatCardEventOutbox = .shared,
                trigger: ChatReactionTrigger? = .shared) {
        // 10-30：贴了立刻带给 AI（气泡对话；撤掉的 / 文章 / CC 留在箱里随下一条）
        defer { trigger?.schedule(conversationId: target.conversationId) }
        let storeKey = Self.key(for: target)
        let added = toggle(emoji, on: storeKey)
        let key = "reaction:\(storeKey):\(emoji)"
        let whose = target.isAssistant ? "你那条" : "自己那条"
        if added {
            outbox.add("对\(whose)「\(target.snippet)」回了 \(emoji)", conversationId: target.conversationId, key: key)
        } else if !outbox.remove(key: key, conversationId: target.conversationId) {
            outbox.add("收回了对\(whose)「\(target.snippet)」的 \(emoji)", conversationId: target.conversationId, key: key)
        }
    }
}

#if os(macOS)
/// mac 气泡右键菜单的「回应」子菜单（plan-cc-reactions-1105 第 3 步）：同一套 12 个表情，已贴的打勾；
/// 点了走 ChatReactionStore.toggle（和 iOS 浮层同一个入口：进箱、立刻触发 AI / CC）
@MainActor
enum MacReactionMenu {
    struct Item: Equatable {
        let emoji: String
        let selected: Bool
    }

    static func items(target: ChatReactionTarget, store: ChatReactionStore = .shared) -> [Item] {
        let picked = store.reactions(for: target)
        return ChatReactionStore.emojis.map { Item(emoji: $0, selected: picked.contains($0)) }
    }

    static func pick(_ emoji: String, target: ChatReactionTarget, store: ChatReactionStore = .shared,
                     outbox: ChatCardEventOutbox = .shared, trigger: ChatReactionTrigger? = .shared) {
        store.toggle(emoji, on: target, outbox: outbox, trigger: trigger)
    }
}
#endif

/// 回应的是哪条：事件里要说清对话和那条的开头
struct ChatReactionTarget: Equatable {
    let nodeId: String
    let conversationId: String
    let snippet: String
    let isAssistant: Bool
    /// nil = 整条消息（旧数据 / 非文本泡）；有值 = 第几个文本泡（从 0 数）
    let blockIndex: Int?

    init(nodeId: String, conversationId: String, snippet: String, isAssistant: Bool, blockIndex: Int? = nil) {
        self.nodeId = nodeId
        self.conversationId = conversationId
        self.snippet = snippet
        self.isAssistant = isAssistant
        self.blockIndex = blockIndex
    }

    init(node: MessageNode) {
        self.init(nodeId: node.id, conversationId: node.conversationId,
                  snippet: Self.snippet(from: String(node.content.prefix(200))),   // 每次渲染都建：只看开头，不解 segments
                  isAssistant: node.role == "assistant")
    }

    /// 文本泡的回应目标：snippet 取该泡文字
    init(node: MessageNode, blockIndex: Int, blockText: String) {
        self.init(nodeId: node.id, conversationId: node.conversationId,
                  snippet: Self.snippet(from: blockText),
                  isAssistant: node.role == "assistant", blockIndex: blockIndex)
    }

    /// 一行、最多 20 字
    static func snippet(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > 20 ? String(line.prefix(20)) + "…" : line
    }
}

// MARK: - 长按浮层用：回应的是哪条（BubbleView 往下传，菜单 wrapper 读）

private struct ReactionTargetKey: EnvironmentKey {
    static let defaultValue: ChatReactionTarget? = nil
}

extension EnvironmentValues {
    var reactionTarget: ChatReactionTarget? {
        get { self[ReactionTargetKey.self] }
        set { self[ReactionTargetKey.self] = newValue }
    }
}

// MARK: - 气泡角上的回应胶囊（照抄 GroupReactionBadgeView：白胶囊 + 两个往外拖的小圆点）

enum ChatReactionIcon {
    static func title(for emoji: String) -> String {
        switch emoji {
        case "👍": return "赞"
        case "❤️": return "喜欢"
        case "😂": return "好笑"
        case "👀": return "关注"
        case "🎉": return "庆祝"
        case "🔥": return "热烈"
        case "😢": return "难过"
        case "🤔": return "思考"
        case "✅": return "确认"
        case "🙏": return "感谢"
        case "💯": return "满分"
        case "❌": return "否定"
        default: return emoji
        }
    }
}

struct ChatReactionBadge: View {
    static let height: CGFloat = 26
    private static let slot: CGFloat = 20
    private static let padding: CGFloat = 3

    let emojis: [String]
    /// 小圆点往右下拖（模型的泡，角标在右上角）；你的泡往左下
    let trailsRight: Bool
    /// AI 贴的：点不掉（底色和她自己点的一样白，粟粟 10-30）
    var fromAssistant = false
    var showsTrail = true
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(emojis, id: \.self) { emoji in
                Text(emoji)
                    .font(.system(size: 14))
                    .frame(width: Self.slot, height: Self.height)
                    .contentShape(Rectangle())
                    .onTapGesture { if !fromAssistant { onTap(emoji) } }
                    .accessibilityLabel(fromAssistant ? "对方回应 \(ChatReactionIcon.title(for: emoji))"
                                                      : "取消回应 \(ChatReactionIcon.title(for: emoji))")
                    .accessibilityAddTraits(fromAssistant ? [] : .isButton)
            }
        }
        .padding(.horizontal, Self.padding)
        .background(Capsule().fill(.white).shadow(color: .black.opacity(0.12), radius: 2.5, y: 1))
        .overlay(alignment: trailsRight ? .trailing : .leading) {
            ZStack {
                dot(size: 5.5, dx: 6, dy: 14)
                dot(size: 3.5, dx: 11, dy: 20)
            }
            .frame(width: Self.height, height: Self.height)
            .opacity(showsTrail ? 1 : 0)
            .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .light)
    }

    private func dot(size: CGFloat, dx: CGFloat, dy: CGFloat) -> some View {
        Circle().fill(.white)
            .shadow(color: .black.opacity(0.12), radius: 2.5, y: 1)
            .frame(width: size, height: size)
            .offset(x: (trailsRight ? 1 : -1) * dx, y: dy)
    }
}

extension View {
    /// 有回应时在内容的上角挂胶囊（模型的右上、你的左上），往外探出半个胶囊、往上探出一截（同群聊）
    func chatReactionBadge(target: ChatReactionTarget, isUser: Bool) -> some View {
        modifier(ChatReactionBadgeModifier(target: target, isUser: isUser))
    }
}

private struct ChatReactionBadgeModifier: ViewModifier {
    let target: ChatReactionTarget
    let isUser: Bool
    private var store: ChatReactionStore { .shared }
    /// 胶囊往上探出的高度（群聊：半高减 2）
    private static let rise: CGFloat = ChatReactionBadge.height / 2 - 2
    private static let overhang: CGFloat = ChatReactionBadge.height / 2

    func body(content: Content) -> some View {
        let emojis = store.reactions(for: target)
        let fromAI = store.aiReactions(for: target)
        if emojis.isEmpty && fromAI.isEmpty {
            content
        } else {
            content
                .padding(.top, Self.rise)
                .overlay(alignment: isUser ? .topLeading : .topTrailing) {
                    // 两种都有时并排：AI 的胶囊在外侧（带小圆点），她自己的靠里
                    HStack(spacing: 3) {
                        if isUser { aiBadge(fromAI, trail: true) }
                        if !emojis.isEmpty {
                            ChatReactionBadge(emojis: emojis, trailsRight: !isUser, showsTrail: fromAI.isEmpty) {
                                store.toggle($0, on: target)
                            }
                        }
                        if !isUser { aiBadge(fromAI, trail: true) }
                    }
                    .offset(x: isUser ? -Self.overhang : Self.overhang)
                }
                .accessibilityElement(children: .contain)
                .accessibilityValue("回应 \((fromAI + emojis).map { ChatReactionIcon.title(for: $0) }.joined(separator: " "))")
        }
    }

    @ViewBuilder
    private func aiBadge(_ emojis: [String], trail: Bool) -> some View {
        if !emojis.isEmpty {
            ChatReactionBadge(emojis: emojis, trailsRight: !isUser, fromAssistant: true, showsTrail: trail) { _ in }
        }
    }
}
