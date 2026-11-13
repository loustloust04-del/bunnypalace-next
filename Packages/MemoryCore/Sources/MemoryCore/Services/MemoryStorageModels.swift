import Foundation
/// 注入 + 历史窗口锚定看到的样子。第三刀起由窗口摘要（memory/sessions/）拼出来：summary = 注入文本，coveredCount = 压缩锚点
public struct ContextSummary: Codable {
    public let summary: String
    public let coveredCount: Int      // 摘要覆盖的旧消息条数
    public let updatedAt: Date

    public init(summary: String, coveredCount: Int, updatedAt: Date) {
        self.summary = summary
        self.coveredCount = coveredCount
        self.updatedAt = updatedAt
    }
}
// MARK: - 停：两步、分组调整、它们的格式重试都看这一个

public final class CatalogCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public var isCancelled: Bool {
        if Task.isCancelled { cancel() }
        return lock.withLock { flag }
    }

    public func cancel() {
        lock.withLock { flag = true }
    }

    public func check() throws {
        if isCancelled { throw CancellationError() }
    }

    /// GCD / detached 不继承父任务取消；整个等待期间桥接到同一个 token。
    public func withTaskCancellation<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await withTaskCancellationHandler(operation: operation, onCancel: { self.cancel() })
    }
}
public struct CatalogRunLink: Codable, Equatable, Sendable {
    public var path: String
    public var anchor: String?

    public init(path: String, anchor: String? = nil) {
        self.path = path
        self.anchor = anchor
    }
}
