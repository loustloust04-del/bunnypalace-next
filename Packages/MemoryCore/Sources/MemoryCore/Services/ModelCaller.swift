import Foundation

/// 一次写手调用要模型做的：system + user。现有写手只用到这两样——模型、采样参数、预算闸、记账都封在实现里
public struct ModelRequest: Sendable, Equatable {
    public var system: String
    public var user: String

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }
}

/// 回包用量（只收现有写手 / 试写台真读的字段；nil = 回包没报）
public struct ModelUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    /// 这次调用花掉的钱（价目表 / 账本算出来的）
    public var costUSD: Double?

    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int? = nil,
                cacheWriteTokens: Int? = nil, costUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
    }
}

/// 一次调用的结果。text = nil = 没写（预算闸 / 开关关了 / 模型回空），不算失败；usage 照记（花过的钱还在）
public struct ModelReply: Sendable, Equatable {
    public var text: String?
    public var usage: ModelUsage?

    public init(text: String? = nil, usage: ModelUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

/// 写手只认这一个口子调模型。app 适配 = `AppModelCaller`（ProviderRouter + 预算闸 + 记账）；
/// memoryd 适配 = 直连 HTTP（E-5）
public protocol ModelCaller: Sendable {
    func complete(_ request: ModelRequest) async throws -> ModelReply
}

/// 拿闭包当 `ModelCaller`（调用方本来就有模型 / 预算 / 记账，包在闭包里）
public struct ClosureModelCaller: ModelCaller, @unchecked Sendable {
    public typealias Body = (String, String) async throws -> String?

    private let body: Body

    public init(_ body: @escaping Body) {
        self.body = body
    }

    public func complete(_ request: ModelRequest) async throws -> ModelReply {
        ModelReply(text: try await body(request.system, request.user))
    }
}
