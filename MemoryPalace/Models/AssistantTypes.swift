import Foundation

// MARK: - 小芽助手 · 类型（plan-小芽助手.md §4；v2：plan-小芽-v2 §4.1）
// 助手面板的消息模型 + 写操作提案。写操作一律走「提案 → 人盖章 → 落地」，
// 模型自身没有任何直达写路径（安全闸门 §5）。

/// 一条待用户确认的写操作提案
struct AssistantAction: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case createCharacter        // 卡库新建角色卡
        case updateCharacterField   // 改角色卡单字段
        case createPreset           // 以现有预设为底新建副本
        case updatePresetSlot       // 改当前楼层预设实例的插槽内容
        case updatePresetSampling   // 改当前楼层预设实例的采样参数
        case addWorldBookEntry      // 世界书加条目
        case updateWorldBookEntry   // 改世界书单条目
        case deleteWorldBookEntry   // 删世界书单条目
        case page2Appearance        // 改 Page2 主屏外观（P3）
        case appIcon                // 改单个 app 图标（P3）
        case stageTheme             // 换小芽的剪纸舞台（P3）
    }

    enum Tier: String, Codable {
        case reversible
        case destructive   // 盖章后还要再确认一次
    }

    enum Status: String, Codable {
        case pending
        case approved
        case discarded
        case undone
        case failed
        /// v1 留下的旧卡：没有改前值，不能盖章，只能让小芽重提
        case legacy
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    /// v1 的无类型载荷；v2 起不用，留着只为能读旧历史
    var payloadJSON: String = "{}"
    /// v2：带类型的改动；盖章后换成回执（补上落地时才知道的 id）
    var change: AssistantChange?
    var status: Status = .pending
    var failure: String?
    var ledgerId: UUID?

    var tier: Tier { change?.tier ?? .reversible }

    init(change: AssistantChange) {
        self.kind = change.kind
        self.title = change.title
        self.detail = change.category
        self.change = change
    }

    init(kind: Kind, title: String, detail: String, payloadJSON: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.payloadJSON = payloadJSON
        self.status = .legacy
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, payloadJSON, change, status, failure, ledgerId
    }

    /// 手写解码（astra A1）：synthesized Codable 对缺键的非 Optional 属性会抛错，旧历史会整份解不开
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        payloadJSON = try c.decodeIfPresent(String.self, forKey: .payloadJSON) ?? "{}"
        change = try? c.decodeIfPresent(AssistantChange.self, forKey: .change)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        ledgerId = try c.decodeIfPresent(UUID.self, forKey: .ledgerId)
        let decodedStatus = try c.decodeIfPresent(Status.self, forKey: .status)
        if change == nil, decodedStatus == nil || decodedStatus == .pending {
            status = .legacy
        } else {
            status = decodedStatus ?? .pending
        }
    }
}

/// 助手面板里的一条消息
struct AssistantChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    var isUser: Bool
    var text: String
    var actions: [AssistantAction] = []   // 仅 assistant 消息：本轮产出的提案（v2 起处理完也留着，显示状态）
    var createdAt = Date()

    init(isUser: Bool, text: String, actions: [AssistantAction] = [], createdAt: Date = Date()) {
        self.isUser = isUser
        self.text = text
        self.actions = actions
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, isUser, text, actions, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isUser = try c.decode(Bool.self, forKey: .isUser)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        actions = try c.decodeIfPresent([AssistantAction].self, forKey: .actions) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

// MARK: - 小芽助手用的显式 init
// CharacterCard 在主声明里有 init(from: TavernCard)，memberwise init 被抑制；助手建卡走这里。
extension CharacterCard {
    init(name: String, description: String, personality: String, scenario: String, firstMes: String) {
        self.name = name
        self.description = description
        self.personality = personality
        self.scenario = scenario
        self.firstMes = firstMes
    }
}
