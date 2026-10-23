import Foundation

// MARK: - 小芽助手 · 聊天记录独立存储
// 要求（粟粟 09-11）：单窗口保持历史；不碰主聊天 SwiftData 库，单独一份 JSON；
// 上下文 30 轮窗口（1 轮 = user+assistant 各一条，wire 只带最近 60 条），本地全量留档。
// v2（plan-小芽-v2 §4.1 A1/C1）：解不开时把原文件改名留底、不覆盖；写盘挪到后台。

struct AssistantChatStore: Sendable {
    let fileURL: URL

    init(fileURL: URL = AssistantChatStore.defaultURL) {
        self.fileURL = fileURL
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AssistantChat", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    func load() -> [AssistantChatMessage] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([AssistantChatMessage].self, from: data)
        } catch {
            // 解不开就挪开留底，别让下一次写盘用空数组盖掉
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return []
        }
    }

    func save(_ messages: [AssistantChatMessage]) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// wire 上下文窗口：最近 30 轮 ≈ 60 条
    static let wireWindowMessages = 60
}
