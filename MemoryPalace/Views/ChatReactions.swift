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

    init(defaults: UserDefaults = .standard, key: String = "chatReactions") {
        self.defaults = defaults
        self.key = key
        byNode = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    func reactions(for nodeId: String) -> [String] { byNode[nodeId] ?? [] }

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
    func toggle(_ emoji: String, on target: ChatReactionTarget, outbox: ChatCardEventOutbox = .shared) {
        let added = toggle(emoji, on: target.nodeId)
        let key = "reaction:\(target.nodeId):\(emoji)"
        let whose = target.isAssistant ? "你那条" : "自己那条"
        if added {
            outbox.add("对\(whose)「\(target.snippet)」回了 \(emoji)", conversationId: target.conversationId, key: key)
        } else if !outbox.remove(key: key, conversationId: target.conversationId) {
            outbox.add("收回了对\(whose)「\(target.snippet)」的 \(emoji)", conversationId: target.conversationId, key: key)
        }
    }
}

/// 回应的是哪条：事件里要说清对话和那条的开头
struct ChatReactionTarget: Equatable {
    let nodeId: String
    let conversationId: String
    let snippet: String
    let isAssistant: Bool

    init(nodeId: String, conversationId: String, snippet: String, isAssistant: Bool) {
        self.nodeId = nodeId
        self.conversationId = conversationId
        self.snippet = snippet
        self.isAssistant = isAssistant
    }

    init(node: MessageNode) {
        self.init(nodeId: node.id, conversationId: node.conversationId,
                  snippet: Self.snippet(from: String(node.content.prefix(200))),   // 每次渲染都建：只看开头，不解 segments
                  isAssistant: node.role == "assistant")
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
    static func symbol(for emoji: String) -> String {
        switch emoji {
        case "👍": return "hand.thumbsup.fill"
        case "❤️": return "heart.fill"
        case "😂": return "face.smiling"
        case "👀": return "eyes"
        case "🎉": return "party.popper.fill"
        case "🔥": return "flame.fill"
        case "😢": return "drop.fill"
        case "🤔": return "questionmark.bubble"
        case "✅": return "checkmark.circle.fill"
        case "🙏": return "hands.sparkles"
        case "💯": return "seal.fill"
        case "❌": return "xmark.circle.fill"
        default: return "face.smiling"
        }
    }

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
        default: return "回应"
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
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(emojis, id: \.self) { emoji in
                Image(systemName: ChatReactionIcon.symbol(for: emoji))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: Self.slot, height: Self.height)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(emoji) }
                    .accessibilityLabel("取消回应 \(ChatReactionIcon.title(for: emoji))")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.horizontal, Self.padding)
        .background(Capsule().fill(Color.white).shadow(color: .black.opacity(0.12), radius: 2.5, y: 1))
        .overlay(alignment: trailsRight ? .trailing : .leading) {
            ZStack {
                dot(size: 5.5, dx: 6, dy: 14)
                dot(size: 3.5, dx: 11, dy: 20)
            }
            .frame(width: Self.height, height: Self.height)
            .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .light)
    }

    private func dot(size: CGFloat, dx: CGFloat, dy: CGFloat) -> some View {
        Circle().fill(Color.white)
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
    private var nodeId: String { target.nodeId }
    private var store: ChatReactionStore { .shared }
    /// 胶囊往上探出的高度（群聊：半高减 2）
    private static let rise: CGFloat = ChatReactionBadge.height / 2 - 2
    private static let overhang: CGFloat = ChatReactionBadge.height / 2

    func body(content: Content) -> some View {
        let emojis = store.reactions(for: nodeId)
        if emojis.isEmpty {
            content
        } else {
            content
                .padding(.top, Self.rise)
                .overlay(alignment: isUser ? .topLeading : .topTrailing) {
                    ChatReactionBadge(emojis: emojis, trailsRight: !isUser) { store.toggle($0, on: target) }
                        .offset(x: isUser ? -Self.overhang : Self.overhang)
                }
                .accessibilityElement(children: .contain)
                .accessibilityValue("回应 \(emojis.map { ChatReactionIcon.title(for: $0) }.joined(separator: " "))")
        }
    }
}
