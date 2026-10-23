import Foundation
import Observation
import SwiftUI

/// 聊天划线一条：锚 = nodeId + 原文精确 quote（消息编辑后失锚不显示，数据不删）。
/// 09-26 和读书划线同步（plan-chat-marks-sync）：每道划线独立（同一段可以叠）、色值 + 样式、
/// 批注是时间线——根 = 划线本身（content 是第一条批注），回复 replyTo = 根 id。
struct ChatHighlight: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var profileId: String
    var nodeId: String
    var quote: String
    /// 老三色名（mint / rose / amber）。新数据仍按最接近的写上，装回旧版本也读得出来
    var colorId: String
    var createdAt: Date
    /// 老版本的单条批注；读进来时搬进 content
    var note: String? = nil
    var color: String? = nil {
        didSet { if let color { colorId = Self.nearestLegacyId(color) } }
    }
    var style: String? = nil
    var replyTo: String? = nil
    var content: String = ""
    var role: String = "user"
    /// 收藏标签（10-02 收藏标签组，方案 A：tag 就是文字）。入口第二期再做，这次只留数据位；旧文件读进来 = nil
    var tags: [String]? = nil
}

extension ChatHighlight {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        profileId = try c.decode(String.self, forKey: .profileId)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        quote = try c.decode(String.self, forKey: .quote)
        colorId = try c.decodeIfPresent(String.self, forKey: .colorId) ?? "mint"
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        style = try c.decodeIfPresent(String.self, forKey: .style)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
    }

    static func legacyHex(_ colorId: String) -> String {
        switch colorId {
        case "rose": return "#C98A8A"
        case "amber": return "#E89B47"
        default: return "#8EBD9F"
        }
    }

    /// 色值 → 最接近的老三色名（只为旧版本兼容）
    static func nearestLegacyId(_ hex: String) -> String {
        guard let v = HighlightPalette.hexValue(hex) else { return "mint" }
        func dist(_ w: UInt) -> Int {
            let d = [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF].enumerated().map { i, x in
                Int(x) - Int((w >> (16 - 8 * UInt(i))) & 0xFF)
            }
            return d.map { $0 * $0 }.reduce(0, +)
        }
        return [("mint", UInt(0x8EBD9F)), ("rose", 0xC98A8A), ("amber", 0xE89B47)].min { dist($0.1) < dist($1.1) }!.0
    }

    var strokeColorHex: String { color ?? Self.legacyHex(colorId) }
    var strokeStyle: HighlightStyle { style.flatMap(HighlightStyle.init(rawValue:)) ?? .fill }

    /// 列表展示用色点
    var dotColor: Color { HighlightPalette.color(strokeColorHex) }
}

extension ChatHighlight: ThreadMark {
    /// 聊天这边没有独立的 kind：写了内容 / 是回复 = note，否则 highlight
    var kind: String {
        get { replyTo != nil || !content.isEmpty ? "note" : "highlight" }
        set {}
    }

    var quoteText: String { quote }
    var chatMessageId: String? { nil }

    func samePlace(as other: ChatHighlight) -> Bool {
        profileId == other.profileId && nodeId == other.nodeId && quote == other.quote
    }

    func reply(content: String, at: Date) -> ChatHighlight {
        ChatHighlight(profileId: profileId, nodeId: nodeId, quote: quote, colorId: colorId,
                      createdAt: at, replyTo: id, content: content)
    }
}

/// 聊天划线存储：chat-highlights.json 原子写（schema 冻结 → 文件层，VocabCardStore 同款）。
/// @Observable 单例——views 在 body 里读 highlights，划/删即时重渲。dir 可注入（测试 tmp）。
@Observable
@MainActor
final class ChatHighlightStore {
    static let shared = ChatHighlightStore()

    private(set) var highlights: [ChatHighlight] = []
    let dir: URL

    /// 文件在、却整份读不懂：这一次运行里不再往里写（免得用空数据盖掉它），原样另存一份等恢复
    private(set) var writesBlocked = false

    init(dir: URL = ChatHighlightStore.defaultDir) {
        self.dir = dir
        let url = dir.appendingPathComponent("chat-highlights.json")
        let data = try? Data(contentsOf: url)
        let loaded = Self.load(dir: dir)
        let isEmptyArray = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Any])?.isEmpty == true
        if loaded.isEmpty, let data, !data.isEmpty, !isEmptyArray {
            let stamp = Int(Date().timeIntervalSince1970)
            try? data.write(to: dir.appendingPathComponent("chat-highlights.unreadable-\(stamp).json"))
            writesBlocked = true
        }
        // 老数据迁移：单条批注搬进 content（时间线第一条）；缺 id 的在解码时补了，这里落盘让 id 固定下来
        let rawItems = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        var migrated = rawItems.contains { $0["id"] == nil }
        highlights = loaded.map { h in
            var h = h
            if let n = h.note {
                if h.content.isEmpty { h.content = n.trimmingCharacters(in: .whitespacesAndNewlines) }
                h.note = nil
                migrated = true
            }
            return h
        }
        if migrated { persist() }
    }

    nonisolated static var defaultDir: URL {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("MemoryPalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 缺文件 / 坏 JSON → []（划线是增强功能，存储坏了不炸 app）。
    nonisolated static func load(dir: URL) -> [ChatHighlight] {
        let url = dir.appendingPathComponent("chat-highlights.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let items = try? decoder.decode([ChatHighlight].self, from: data) else { return [] }
        return items
    }

    private func persist() {
        guard !writesBlocked else { return }
        let url = dir.appendingPathComponent("chat-highlights.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(highlights) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 这个锚上的划线和时间线条目。合成锚（`ticker:` / `vocab:` / `topic:`…）各楼层同名，要按楼层分开；
    /// profileId 为空（少数没有楼层的调用点）不筛
    func highlights(nodeId: String, profileId: String) -> [ChatHighlight] {
        highlights.filter { $0.nodeId == nodeId && (profileId.isEmpty || $0.profileId == profileId) }
    }

    /// 这条消息上的划线笔画（根，不含时间线回复），按划的先后
    func strokes(nodeId: String, profileId: String) -> [ChatHighlight] {
        highlights(nodeId: nodeId, profileId: profileId).filter { $0.replyTo == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 划一道新的（同一段可以叠）
    @discardableResult
    func add(nodeId: String, profileId: String, quote: String, color: String, style: HighlightStyle,
             now: Date = Date()) -> ChatHighlight? {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let h = ChatHighlight(profileId: profileId, nodeId: nodeId, quote: trimmed,
                              colorId: ChatHighlight.nearestLegacyId(color), createdAt: now,
                              color: color, style: style.rawValue)
        highlights.append(h)
        persist()
        return h
    }

    /// 跑一段 NoteThreads 改动（再写一条 / 改 / 删 / 删这道 / 删这处）后落盘
    func mutate(_ change: (inout [ChatHighlight]) -> Void) {
        change(&highlights)
        persist()
    }
}
