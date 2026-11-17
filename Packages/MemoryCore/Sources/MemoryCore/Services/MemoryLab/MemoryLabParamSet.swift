import Foundation

/// 记忆实验台存下来的一组参数（plan-memory-lab-3 §1）。存的是值（记录里那份完整参数），不是对她设置的引用。
/// 「现在的设置」不落盘：固定 id `currentId`，每次现读她的设置。除了编号，字段全是可选的。
public struct MemoryLabParamSet: Codable, Equatable, Sendable, Identifiable {
    /// 「现在的设置」那一组的 id（不落盘，也不能拿来存别的）
    public static let currentId = "current"

    public var schema: Int?
    public var id: String
    public var name: String?
    public var createdAt: Date?
    /// 不带 `differences`：那是跑的那一刻跟设置比的，存下来就过时了，要看差在哪现比
    public var params: MemoryLabRecord.Params?

    public init(id: String, name: String? = nil, createdAt: Date? = nil, params: MemoryLabRecord.Params? = nil) {
        schema = 1
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.params = params
    }
}
