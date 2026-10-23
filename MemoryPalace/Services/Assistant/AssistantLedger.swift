import Foundation
import Observation

// MARK: - 小芽 v2 · 账本（plan-小芽-v2 §4.4 v1.1，astra B5/C2/D1）
// 每次盖章记一笔回执（完整改前 / 改后 + 落地时才知道的 id），撤销就拿它反着做。
// 跟聊天记录分开存；最近 200 条且总量 ≤ 4 MB，超了从最老的裁——被裁掉的那笔，卡片上显示「超出撤销保留范围」。

struct AssistantLedgerEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var actionId: UUID
    var date = Date()
    var category: String
    var title: String
    var receipt: AssistantChange
    var undone = false
    /// 这笔本身是一次撤销时，指向被撤销的那笔（撤销记录不再提供撤销）
    var undoOf: UUID?
}

@Observable
@MainActor
final class AssistantLedger {
    static let maxEntries = 200
    static let maxBytes = 4 * 1024 * 1024

    private(set) var entries: [AssistantLedgerEntry] = []
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = AssistantLedger.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([AssistantLedgerEntry].self, from: data) {
            entries = decoded
        }
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AssistantChat", isDirectory: true)
            .appendingPathComponent("ledger.json")
    }

    func entry(id: UUID) -> AssistantLedgerEntry? { entries.first { $0.id == id } }
    func entry(forAction actionId: UUID) -> AssistantLedgerEntry? {
        entries.first { $0.actionId == actionId && $0.undoOf == nil }
    }

    /// 写盘失败就抛，调用方据此告诉粟粟「已生效但没记进账本（无法撤销）」——不假装可撤销
    @discardableResult
    func record(actionId: UUID, receipt: AssistantChange) throws -> AssistantLedgerEntry {
        let entry = AssistantLedgerEntry(actionId: actionId, category: receipt.category, title: receipt.title, receipt: receipt)
        var next = entries
        next.append(entry)
        try persist(next)
        return entry
    }

    /// 原条目标 undone + 追加一条撤销记录，一次写盘
    func markUndone(_ id: UUID) throws {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var next = entries
        next[idx].undone = true
        let original = next[idx]
        next.append(AssistantLedgerEntry(actionId: original.actionId, category: original.category,
                                         title: "撤销：" + original.title, receipt: original.receipt, undoOf: original.id))
        try persist(next)
    }

    private func persist(_ candidate: [AssistantLedgerEntry]) throws {
        var trimmed = Array(candidate.suffix(Self.maxEntries))
        var data = try JSONEncoder().encode(trimmed)
        while data.count > Self.maxBytes, trimmed.count > 1 {
            trimmed.removeFirst(max(1, trimmed.count / 10))
            data = try JSONEncoder().encode(trimmed)
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        entries = trimmed
    }
}

// MARK: - 权限包（plan §4.5 v1.1 C6）：设置页 / definitions / execute / 盖章四处都读这一个

enum XiaoyaPack: String, CaseIterable {
    case read, creation, appearance

    var title: String {
        switch self {
        case .read: "查阅"
        case .creation: "创作"
        case .appearance: "外观"
        }
    }

    var detail: String {
        switch self {
        case .read: "查记忆、读预设 / 角色卡 / 世界书，不改任何东西"
        case .creation: "提议新建或修改角色卡、预设插槽和采样参数、世界书条目；每一笔都要你盖章"
        case .appearance: "提议换主屏壁纸、图标样式、明暗、单个图标、她的舞台；卡片上先给你看换完的样子，盖章才换"
        }
    }

    var storageKey: String { "xiaoya.pack.\(rawValue)" }
    var defaultEnabled: Bool { true }

    static let appearanceTools: Set<String> = ["read_appearance", "propose_page2_appearance", "propose_app_icon", "propose_stage_theme"]

    static func of(tool name: String) -> XiaoyaPack? {
        if appearanceTools.contains(name) { return .appearance }
        if name.hasPrefix("propose_") { return .creation }
        if name.hasPrefix("read_") || name.hasPrefix("list_") || name.hasPrefix("query_") { return .read }
        return nil
    }

    static func of(kind: AssistantAction.Kind) -> XiaoyaPack {
        switch kind {
        case .page2Appearance, .appIcon, .stageTheme: .appearance
        default: .creation
        }
    }
}

enum XiaoyaPackPolicy {
    /// 缺键 = 默认值（升级上来从没打开过设置的人也照常能用）
    static func isEnabled(_ pack: XiaoyaPack, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: pack.storageKey) as? Bool ?? pack.defaultEnabled
    }
}
