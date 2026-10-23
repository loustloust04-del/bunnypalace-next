import Foundation

/// 这次调用是干什么的（主模型 / 各路副模型）。新版本加的 kind 旧版本读到按 `.other`。
enum UsageKind: String, Codable, CaseIterable, Sendable {
    case chat, assistant, memory, dream, timeline, summary, image, innerVoice, vocab, vocabArcheology, topic, coach, code, title, thinking, toolSummary, other

    var label: String {
        switch self {
        case .chat: "对话"
        case .assistant: "小芽助手"
        case .memory: "记忆提取"
        case .dream: "做梦画像"
        case .timeline: "日记"
        case .summary: "上下文压缩"
        case .image: "图片转述"
        case .innerVoice: "心声"
        case .vocab: "单词判分"
        case .vocabArcheology: "单词考古"
        case .topic: "话题盒"
        case .coach: "人设教练"
        case .code: "Code"
        case .title: "起标题"
        case .thinking: "思考总结"
        case .toolSummary: "工具总结"
        case .other: "其他"
        }
    }

    /// 主模型（粟粟直接在聊）vs 副模型（后台代劳）
    var isMainModel: Bool { self == .chat || self == .assistant }
}

/// 发请求的一方告诉 router：这次调用算谁的
struct UsageContext: Equatable, Sendable {
    var kind: UsageKind = .other
    var conversationId: String? = nil
    var profileId: String? = nil
    var messageNodeId: String? = nil
}

enum CostSource: String, Codable, Sendable {
    case reported, calculated, partial, estimated
}

/// 账本的一行 = 一次模型调用（research-magpie 2.1，仿 magpie `usage.Record`）。
/// `input` 是归一化后的**总 prompt**（含缓存读写），和消息节点 `usagePromptTokens` 同口径。
struct UsageRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case ok, error }

    var time: Date
    var providerId: String
    var providerName: String
    var providerType: String
    var model: String
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var reasoning: Int
    var durationMs: Int
    var status: Status
    var kind: UsageKind
    var conversationId: String?
    var profileId: String?
    /// 订阅额度通道（ChatGPT 登录 / CC 桥）：不花 API 钱
    var subscription: Bool
    /// Code 侧会话级 token：只有总数、拆不出输入输出 → 不计价，也不算「未计价」
    var tokensOnly: Bool
    var costUSD: Double? = nil
    var costSource: CostSource? = nil
    var priceVersion: String? = nil
    var cacheWrite1h: Int = 0
    var webSearches: Int = 0
    var responseId: String? = nil
    var correction = false
    var budgetChargeUSD: Double? = nil
    var requestId: String? = nil
    var messageNodeId: String? = nil
    var keyIdentity: String? = nil
    var usageState: UsageCompleteness? = nil
    var requestSent: Bool? = nil

    var invocationId: String? {
        (responseId ?? requestId).map { providerId + "\u{0}" + $0 }
    }

    var effectiveCostSource: CostSource { costSource ?? .estimated }

    init(time: Date, providerId: String, providerName: String, providerType: String, model: String,
         input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, durationMs: Int,
         status: Status, kind: UsageKind, conversationId: String?, profileId: String?,
         subscription: Bool, tokensOnly: Bool) {
        self.time = time
        self.providerId = providerId
        self.providerName = providerName
        self.providerType = providerType
        self.model = model
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.durationMs = durationMs
        self.status = status
        self.kind = kind
        self.conversationId = conversationId
        self.profileId = profileId
        self.subscription = subscription
        self.tokensOnly = tokensOnly
    }

    /// router 收尾时用：按卡类型把 usage 归一化（Anthropic input_tokens 不含缓存 → 补成总 prompt；OAI 本来就含）
    init(provider: APICredential, modelId: String, usage: TokenUsage?, started: Date, ended: Date,
         status: Status, context: UsageContext, requestSent: Bool = true) {
        let read = usage?.cacheReadTokens ?? 0
        let write = usage?.cacheWriteTokens ?? 0
        let rawInput = usage?.inputTokens ?? 0
        self.init(
            time: ended, providerId: provider.id, providerName: provider.name, providerType: provider.type.rawValue,
            model: modelId,
            input: provider.type == .anthropic ? rawInput + read + write : rawInput,
            output: usage?.outputTokens ?? 0, cacheRead: read, cacheWrite: write,
            reasoning: usage?.reasoningTokens ?? 0,
            durationMs: max(0, Int((ended.timeIntervalSince(started) * 1000).rounded())),
            status: status, kind: context.kind, conversationId: context.conversationId, profileId: context.profileId,
            subscription: provider.type == .chatgptOAuth || provider.type == .ccBridge, tokensOnly: false
        )
        self.requestSent = requestSent
        usageState = usage == nil || usage?.completeness == .missing ? .missing : (status == .error ? .snapshot : usage?.completeness)
        messageNodeId = context.messageNodeId
        cacheWrite1h = usage?.cacheWrite1hTokens ?? 0
        webSearches = usage?.webSearches ?? 0
        responseId = usage?.responseId
        if !requestSent {
            costUSD = 0
            costSource = .calculated
        } else if subscription {
            costUSD = 0
            costSource = .calculated
        } else if let reported = usage?.reportedCostUSD {
            costUSD = reported
            costSource = .reported
        } else if usage == nil || (input + output == 0 && webSearches == 0 && responseId != nil) {
            costSource = .partial // 缺 usage 的调用只有待补查金额，不能冒充已精算的零元。
        } else if let pricing = PricingCatalog.price(for: modelId) {
            var pricing = pricing
            if provider.type == .anthropic, URL(string: provider.baseURL)?.host == "api.anthropic.com" {
                pricing.webSearchUSDPerCall = pricing.webSearchUSDPerCall ?? 0.01
            }
            let result = pricing.evaluatedCost(promptTokens: input, completionTokens: output,
                                              cacheReadTokens: read, cacheWriteTokens: write,
                                              cacheWrite1hTokens: cacheWrite1h, webSearches: webSearches)
            costUSD = result.usd
            costSource = result.partial || usageState != .complete ? .partial : .calculated
            priceVersion = pricing.priceVersion
        } else {
            costSource = .partial
        }
    }

    /// 标价费用（USD）。nil = 查不到价（「未计价」）或 Code 会话级 token（拆不出输入输出）。
    func cost(price: (String) -> ModelPricing?) -> Double? {
        if let costUSD { return costUSD }
        if tokensOnly { return nil }
        if costSource != nil { return nil } // 新记录缺价保持未计价，不随后来的价格改写。
        if subscription || input + output == 0 { return 0 }
        guard let pricing = price(model) else { return nil }
        return pricing.cost(promptTokens: input, completionTokens: output,
                            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                            cacheWrite1hTokens: cacheWrite1h, webSearches: webSearches)
    }

    func costCorrection(usd: Double) -> UsageRecord {
        var row = self
        row.input = 0; row.output = 0; row.cacheRead = 0; row.cacheWrite = 0
        row.reasoning = 0; row.cacheWrite1h = 0; row.webSearches = 0
        row.costUSD = usd
        row.costSource = .reported
        row.correction = true
        row.status = .ok
        row.durationMs = 0
        row.priceVersion = nil; row.budgetChargeUSD = nil
        row.requestId = nil; row.messageNodeId = nil; row.keyIdentity = nil
        row.usageState = nil; row.requestSent = nil
        return row
    }

    func budgetCost(estimatedCost: Double, price: (String) -> ModelPricing? = { PricingCatalog.price(for: $0) }) -> Double {
        if requestSent == false || subscription || tokensOnly { return 0 }
        if costSource != .partial, let costUSD { return costUSD }
        guard input + output > 0 || webSearches > 0 else { return max(0, estimatedCost) }
        let rate = price(model) ?? PricingCatalog.budgetFallback
        return max(costUSD ?? 0, rate.cost(promptTokens: input, completionTokens: output,
                                          cacheReadTokens: 0, cacheWriteTokens: 0, webSearches: webSearches))
    }

    // 短 key：一年几万行，省点盘
    private enum CodingKeys: String, CodingKey {
        case time = "t", providerId = "provider", providerName = "pname", providerType = "ptype", model
        case input = "in", output = "out", cacheRead = "cr", cacheWrite = "cw", reasoning = "rs"
        case durationMs = "ms", status, kind, conversationId = "conv", profileId = "profile"
        case subscription = "sub", tokensOnly = "tok"
        case costUSD = "cost", costSource = "cs", priceVersion = "pv"
        case cacheWrite1h = "cw1h", webSearches = "ws", responseId = "rid", correction, budgetChargeUSD = "bc", requestId = "req", messageNodeId = "node", keyIdentity = "kh", usageState = "us", requestSent = "sent"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Date.self, forKey: .time)
        providerId = try c.decode(String.self, forKey: .providerId)
        model = try c.decode(String.self, forKey: .model)
        providerName = try c.decodeIfPresent(String.self, forKey: .providerName) ?? providerId
        providerType = try c.decodeIfPresent(String.self, forKey: .providerType) ?? ""
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        reasoning = try c.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .ok
        kind = (try? c.decodeIfPresent(UsageKind.self, forKey: .kind)) ?? .other
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
        subscription = try c.decodeIfPresent(Bool.self, forKey: .subscription) ?? false
        tokensOnly = try c.decodeIfPresent(Bool.self, forKey: .tokensOnly) ?? false
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
        costSource = try c.decodeIfPresent(CostSource.self, forKey: .costSource)
        priceVersion = try c.decodeIfPresent(String.self, forKey: .priceVersion)
        cacheWrite1h = try c.decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0
        webSearches = try c.decodeIfPresent(Int.self, forKey: .webSearches) ?? 0
        responseId = try c.decodeIfPresent(String.self, forKey: .responseId)
        correction = try c.decodeIfPresent(Bool.self, forKey: .correction) ?? false
        if correction, costUSD != nil { costSource = .reported }
        budgetChargeUSD = try c.decodeIfPresent(Double.self, forKey: .budgetChargeUSD)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        messageNodeId = try c.decodeIfPresent(String.self, forKey: .messageNodeId)
        keyIdentity = try c.decodeIfPresent(String.self, forKey: .keyIdentity)
        usageState = try c.decodeIfPresent(UsageCompleteness.self, forKey: .usageState)
        requestSent = try c.decodeIfPresent(Bool.self, forKey: .requestSent)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(providerId, forKey: .providerId)
        try c.encode(providerName, forKey: .providerName)
        try c.encode(providerType, forKey: .providerType)
        try c.encode(model, forKey: .model)
        try c.encode(input, forKey: .input)
        try c.encode(output, forKey: .output)
        if cacheRead != 0 { try c.encode(cacheRead, forKey: .cacheRead) }
        if cacheWrite != 0 { try c.encode(cacheWrite, forKey: .cacheWrite) }
        if reasoning != 0 { try c.encode(reasoning, forKey: .reasoning) }
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(status, forKey: .status)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(conversationId, forKey: .conversationId)
        try c.encodeIfPresent(profileId, forKey: .profileId)
        if subscription { try c.encode(subscription, forKey: .subscription) }
        if tokensOnly { try c.encode(tokensOnly, forKey: .tokensOnly) }
        try c.encodeIfPresent(costUSD, forKey: .costUSD)
        if !correction { try c.encodeIfPresent(costSource, forKey: .costSource) }
        try c.encodeIfPresent(priceVersion, forKey: .priceVersion)
        if cacheWrite1h != 0 { try c.encode(cacheWrite1h, forKey: .cacheWrite1h) }
        if webSearches != 0 { try c.encode(webSearches, forKey: .webSearches) }
        try c.encodeIfPresent(responseId, forKey: .responseId)
        if correction { try c.encode(correction, forKey: .correction) }
        try c.encodeIfPresent(budgetChargeUSD, forKey: .budgetChargeUSD)
        try c.encodeIfPresent(requestId, forKey: .requestId)
        try c.encodeIfPresent(messageNodeId, forKey: .messageNodeId)
        try c.encodeIfPresent(keyIdentity, forKey: .keyIdentity)
        try c.encodeIfPresent(usageState, forKey: .usageState)
        try c.encodeIfPresent(requestSent, forKey: .requestSent)
    }
}

/// 用量账本：Application Support 下的 `usage.jsonl`，一次调用一行，只追加。
/// **记账绝不能弄坏调用**：所有失败静默吞掉（magpie `usage.Append` 同款）。只在本机，不上传。
final class UsageLedger: @unchecked Sendable {
    /// 追加成功后在主线程发（用量页据此刷新）
    static let didAppend = Notification.Name("UsageLedger.didAppend")

    /// 测试宿主里写临时目录，绝不污染粟粟的真账本
    static let shared: UsageLedger = {
        if NSClassFromString("XCTestCase") != nil {
            return UsageLedger(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoryPalaceTests-usage-\(ProcessInfo.processInfo.processIdentifier).jsonl"))
        }
        return UsageLedger(fileURL: URL.applicationSupportDirectory
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("usage.jsonl"))
    }()

    let fileURL: URL
    private let queue = DispatchQueue(label: "memorypalace.usage-ledger", qos: .utility)

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// 异步串行追加；`load` 走同一队列，读之前的追加一定已落盘。
    func append(_ record: UsageRecord) {
        queue.async { [fileURL] in
            guard var line = try? Self.encoder.encode(record) else { return }
            line.append(0x0A)
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: fileURL.path) {
                    guard fm.createFile(atPath: fileURL.path, contents: nil) else { return }
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                return
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didAppend, object: nil) }
        }
    }

    /// 全部（或某时刻之后）的记录，按时间升序；坏行跳过。
    func load(since: Date? = nil) -> [UsageRecord] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let records = Self.decode(lines: data)
            guard let since else { return records }
            return records.filter { $0.time >= since }
        }
    }

    static func decode(lines data: Data) -> [UsageRecord] {
        let records = data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(UsageRecord.self, from: Data(line))
        }
        return latestRecords(records).sorted { $0.time < $1.time }
    }

    /// 按追加顺序取同一 generation 最后一行，先去重再筛时间，保留无 rid 的旧行。
    static func latestRecords(_ records: [UsageRecord]) -> [UsageRecord] {
        var positions: [String: Int] = [:]
        var merged: [UsageRecord] = []
        for row in records {
            guard let id = row.invocationId else { merged.append(row); continue }
            if let index = positions[id] {
                if row.correction {
                    merged[index].costUSD = row.costUSD
                    merged[index].costSource = .reported
                    merged[index].budgetChargeUSD = row.costUSD
                    merged[index].correction = true
                } else if !merged[index].correction { merged[index] = row }
            } else {
                positions[id] = merged.count
                merged.append(row)
            }
        }
        return merged
    }
}
