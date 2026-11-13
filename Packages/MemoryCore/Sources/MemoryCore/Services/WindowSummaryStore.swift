import Foundation

/// 窗口总结（plan-memory-v4-1 §三，存储方案 B）：memory/windows/{convId前8}-{标题slug}.md，一个窗口一份，
/// 每次收尾整份重写 = 上下文摘要各段原样抄一份 + 新写的最后那段「还在视野里那截」。文件格式同 `SessionSummaryStore`，
/// 头上多一个 closedThrough。不注入，只给粟粟看、给 recall 按编号翻
public enum WindowSummaryStore {}

public extension WindowSummaryStore {
    static let folder = "windows"

    static func dir(root: URL) -> URL {
        root.appendingPathComponent(folder, isDirectory: true)
    }


    static func load(conversationId: String, memoryRoot: URL) -> SessionSummary? {
        SessionSummaryStore.load(conversationId: conversationId, in: dir(root: memoryRoot))
    }

    static func load(conversationId: String, in root: URL) -> SessionSummary? {
        SessionSummaryStore.load(conversationId: conversationId, in: dir(root: root))
    }

    static func loadStrict(conversationId: String, in root: URL) throws -> SessionSummary? {
        try SessionSummaryStore.loadStrict(conversationId: conversationId, in: dir(root: root))
    }

    static func save(_ s: SessionSummary, in root: URL) throws {
        try SessionSummaryStore.save(s, in: dir(root: root))
    }

    static func all(memoryRoot: URL) -> [SessionSummary] {
        SessionSummaryStore.all(in: dir(root: memoryRoot))
    }
}
