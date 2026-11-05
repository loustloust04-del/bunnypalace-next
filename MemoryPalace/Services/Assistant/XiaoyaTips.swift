import Foundation

// MARK: - 小芽 Tip（plan-onboarding-xiaoya-impl §11；小样 design-onboarding-xiaoya-v2.html A）
// Muse 式「Tip N」：小芽在自己的对话里发，一句话 + 一张会动的示意插图。Tip 1 = 一组四张（回桌面 / 去聊天 / 看所有对话 / 楼层是什么），
// v3（§12-B）拆成 Tip 1.1–1.4：收尾只发 1.1，「懂了，下一条」再发下一张，「以后再看」剩下的进灯泡。
// 每日 tip 以后从 Tip 2 起。收到过哪几组、看过哪几张记在 AssistantChat/tips.json（跟 history.json 同目录 → 全局备份自动带上），不进 UserDefaults。

/// 一张 tip 讲的事。插图和文案按它画；回桌面那张按她当时的「切换应用」设置出竖条版 / 弧线版（渲染时读，改了设置旧消息跟着变）
enum XiaoyaTipKind: String, Codable, CaseIterable {
    case toDesk, toChat, toList
    /// 粟粟 10-16：讲楼层的概念（一层一个 Ta；小芽不住在任何一层）
    case floors
}

/// 卡上存的只有编号 + 种类：文案和插图都现拼，旧消息跟着当前设置画
struct XiaoyaTipRef: Codable, Equatable {
    var number: Int
    var kind: XiaoyaTipKind

    init(number: Int, kind: XiaoyaTipKind) {
        self.number = number
        self.kind = kind
    }
}

enum XiaoyaTipCatalog {
    /// Tip 1（一组）：1.1–1.4
    static let firstGroup: [XiaoyaTipKind] = [.toDesk, .toChat, .toList, .floors]

    /// 编号 → 这一组有哪几张（历史列表按它重画）
    static func kinds(for number: Int) -> [XiaoyaTipKind] {
        number == 1 ? firstGroup : []
    }

    static func refs(for number: Int) -> [XiaoyaTipRef] {
        kinds(for: number).map { XiaoyaTipRef(number: number, kind: $0) }
    }

    /// 灯泡列表里这一组的小标题
    static func groupTitle(_ number: Int) -> String {
        number == 1 ? "怎么划" : ""
    }

    /// 同一组的下一张（「懂了，下一条」）；最后一张 nil
    static func next(after ref: XiaoyaTipRef) -> XiaoyaTipRef? {
        let kinds = kinds(for: ref.number)
        guard let i = kinds.firstIndex(of: ref.kind), i + 1 < kinds.count else { return nil }
        return XiaoyaTipRef(number: ref.number, kind: kinds[i + 1])
    }
}

extension XiaoyaTipRef {
    /// 「1.1」：一组多张时带小号，单张就是组号
    var label: String {
        let kinds = XiaoyaTipCatalog.kinds(for: number)
        guard kinds.count > 1, let i = kinds.firstIndex(of: kind) else { return "\(number)" }
        return "\(number).\(i + 1)"
    }
}

/// tips.json：收到过的 tip 组号 + 第一次收到的时间 + 看过的张（「1.1」）。
/// 收到一组 = 这一组每张都进灯泡列表；没看过的张算未看（灯泡红数字）
struct XiaoyaTipLog: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var number: Int
        var receivedAt: Date
    }

    var received: [Entry] = []
    var seen: Set<String> = []

    init(received: [Entry] = [], seen: Set<String> = []) {
        self.received = received
        self.seen = seen
    }

    private enum CodingKeys: String, CodingKey { case received, seen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        received = (try? c.decodeIfPresent([Entry].self, forKey: .received)) ?? []
        if let seen = try? c.decodeIfPresent([String].self, forKey: .seen) {
            self.seen = Set(seen)
        } else {
            // v2 的 tips.json 没有 seen：那时一组四张是一口气全发在对话里的，都算看过
            self.seen = Set(received.flatMap { XiaoyaTipCatalog.refs(for: $0.number).map(\.label) })
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(received, forKey: .received)
        try c.encode(seen.sorted(), forKey: .seen)
    }

    var isEmpty: Bool { received.isEmpty }

    /// 按编号排好（历史列表）
    var sorted: [Entry] { received.sorted { $0.number < $1.number } }

    /// 灯泡列表里的每一张（收到过的组，按编号 + 组内顺序）
    var items: [XiaoyaTipRef] { sorted.flatMap { XiaoyaTipCatalog.refs(for: $0.number) } }

    func isSeen(_ ref: XiaoyaTipRef) -> Bool { seen.contains(ref.label) }

    var unseenCount: Int { items.filter { !isSeen($0) }.count }

    /// 记一组；同一编号只记第一次。返回 true = 新收到的
    mutating func record(_ number: Int, at date: Date = Date()) -> Bool {
        guard !received.contains(where: { $0.number == number }) else { return false }
        received.append(Entry(number: number, receivedAt: date))
        return true
    }

    /// 看过一张（发在对话里 / 在灯泡里点开）。返回 true = 这次才看
    mutating func markSeen(_ ref: XiaoyaTipRef) -> Bool {
        seen.insert(ref.label).inserted
    }
}

struct XiaoyaTipStore: Sendable {
    let fileURL: URL

    /// 跟 history.json 放同一个目录
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("tips.json")
    }

    func load() -> XiaoyaTipLog {
        guard let data = try? Data(contentsOf: fileURL) else { return XiaoyaTipLog() }
        do {
            return try JSONDecoder().decode(XiaoyaTipLog.self, from: data)
        } catch {
            // 同 history.json：解不开挪开留底（备份导出会跳过 corrupt），当没收到过
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json"))
            return XiaoyaTipLog()
        }
    }

    func save(_ log: XiaoyaTipLog) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
