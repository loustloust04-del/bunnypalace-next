import Foundation

/// 记忆实验台的一份测试集（plan-memory-lab-2 §1）：她精心挑的一组句子。
/// 除了编号，字段全是可选的：以后加字段，旧集子照样读得出。
public struct MemoryLabSet: Codable, Equatable, Sendable, Identifiable {
    public var schema: Int?
    public var id: String
    public var name: String?
    public var createdAt: Date?
    /// 挑进来的句子，按挑进的先后
    public var items: [Item]?

    public init(id: String, name: String? = nil, createdAt: Date? = nil, items: [Item]? = nil) {
        schema = 1
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.items = items
    }

    public struct Item: Codable, Equatable, Sendable {
        /// 「同一句话」的键（`MemoryLabRecord.sentence`）
        public var sentenceId: String
        /// 那句话存一份在集子里：记录文件坏了 / 没了也知道这句是什么
        public var text: String?
        public var addedAt: Date?

        public init(sentenceId: String, text: String? = nil, addedAt: Date? = nil) {
            self.sentenceId = sentenceId
            self.text = text
            self.addedAt = addedAt
        }
    }
}
