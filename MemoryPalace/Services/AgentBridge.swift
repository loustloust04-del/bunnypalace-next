import Foundation
import SwiftData

/// AUTONOMY Phase 1：app ↔ hub 自主 agent 的文件桥（plan-autonomy-network P1.4/P1.5）。
/// 目录 `~/Library/Application Support/MemoryPalace/agent/`：
/// - `config.json`：app 写 hub 读（总开关/楼层开关默认关 = D6，预算 = D4）
/// - `budget-<日期>.json` + `activity.jsonl`：hub 写 app 读（设置页用量/活动 log）
/// - `outbox/{floorId}/*.json`：hub 写；app drain 成功后**删文件 = 主幂等**，agentOrigin 查重兜底
///   （cc-replay 复读事故的教训平移）
enum AgentBridge {

    static var root: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 配置（与 cc-bridge/agent-runner.ts loadConfig 对齐，hub 端补默认值）

    struct CoRead: Codable, Equatable {
        var daemon: Bool = false
        var cc: Bool = false
        var vocab: Bool = false
    }

    struct HubConfig: Codable {
        var enabled: Bool = false
        var floors: [String: Bool] = [:]
        var dailyBudgetUSD: Double = 0.5
        var pausedUntil: Date? = nil
        // optional：旧 config.json 没有这个键，非 optional 会让整个 decode 失败回默认
        var coRead: CoRead? = nil
    }

    private static var configURL: URL { root.appendingPathComponent("config.json") }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func loadConfig(from url: URL? = nil) -> HubConfig {
        guard let data = try? Data(contentsOf: url ?? configURL),
              let cfg = try? decoder.decode(HubConfig.self, from: data) else { return HubConfig() }
        return cfg
    }

    /// ⚠️ 只覆盖 app 管的键（enabled/floors/dailyBudgetUSD/pausedUntil），**保留** hub 侧字段
    /// （model / apiKeyAccount 等）——整体 encode 会把 HubConfig 不认识的字段抹掉，
    /// 用户一动开关就把 hub 的 provider/model 配置清回默认（Phase 1 验收发现的活雷）。
    /// 读-改-写 保未知键；「哪层楼用哪 provider/model」正式交给 app 管归 Phase 2。
    static func saveConfig(_ cfg: HubConfig, to url: URL? = nil) {
        let target = url ?? configURL
        var dict = ((try? Data(contentsOf: target)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) ?? [:]
        dict["enabled"] = cfg.enabled
        dict["floors"] = cfg.floors
        dict["dailyBudgetUSD"] = cfg.dailyBudgetUSD
        if let coRead = cfg.coRead {
            dict["coRead"] = ["daemon": coRead.daemon, "cc": coRead.cc, "vocab": coRead.vocab]
        }
        if let until = cfg.pausedUntil {
            dict["pausedUntil"] = ISO8601DateFormatter().string(from: until)
        } else {
            dict.removeValue(forKey: "pausedUntil")
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: target, options: .atomic)
        }
    }

    // MARK: - 读书模型（R6：设置-读书第三槽；hub cfg.model 每 tick 读）

    /// 当前 config.json 里的 model 显示信息（macOS 直读；无 = hub 默认）。
    static func currentModelInfo(from url: URL? = nil) -> (id: String, name: String)? {
        guard let data = try? Data(contentsOf: url ?? configURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = dict["model"] as? [String: Any],
              let id = model["id"] as? String else { return nil }
        return (id, model["name"] as? String ?? id)
    }

    /// 写读书模型（读-改-写只覆盖 model/apiKeyAccount，保 app 管的四键与未知键）。
    static func saveModelSelection(model: [String: Any], apiKeyAccount: String, to url: URL? = nil) {
        let target = url ?? configURL
        var dict = ((try? Data(contentsOf: target)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) ?? [:]
        dict["model"] = model
        dict["apiKeyAccount"] = apiKeyAccount
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: target, options: .atomic)
        }
    }

    /// ProviderModel + 所属卡 → hub Model 形状（agent-runner AgentConfig.model）。
    /// cost 置 0：预算按 provider 响应里返回的实际 cost 计（OpenRouter 会返），
    /// 不返的渠道用量记 0——设置页 footer 已说明。
    static func hubModelDict(credential: APICredential, model: ProviderModel) -> [String: Any] {
        [
            "id": model.modelId,
            "name": model.name,
            "api": credential.type == .anthropic ? "anthropic-messages" : "openai-completions",
            "provider": credential.name,
            "baseUrl": credential.baseURL,
            "reasoning": false,
            "input": ["text"],
            "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
            "contextWindow": 128_000,
            "maxTokens": 8_192,
        ]
    }

    // MARK: - 用量 / 活动（hub 产出，设置页只读）

    static func todaySpentUSD() -> Double? {
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let url = root.appendingPathComponent("budget-\(day).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["spentUSD"] as? Double
    }

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let ts: String
        let triggerId: String
        let status: String
        let detail: String
    }

    static func recentActivity(limit: Int = 50) -> [ActivityEntry] {
        let url = root.appendingPathComponent("activity.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(limit).reversed().compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            let detail = (obj["preview"] as? String) ?? (obj["echo"] as? String) ?? (obj["error"] as? String) ?? ""
            return ActivityEntry(
                ts: String((obj["ts"] as? String ?? "").prefix(16)).replacingOccurrences(of: "T", with: " "),
                triggerId: obj["triggerId"] as? String ?? "?",
                status: obj["status"] as? String ?? "?",
                detail: detail
            )
        }
    }
}

// MARK: - Outbox drain

enum AgentOutboxDrainer {

    struct Payload: Decodable {
        let v: Int
        let uuid: String
        let triggerId: String
        let floorId: String
        let createdAt: String
        let userSeed: String
        let assistantText: String
    }

    /// 启动时调用（后续 WS 通知到货再补实时档）。返回落库条数。
    /// 语义（D1/D2 已定）：消息对按普通消息插进楼层最近对话，只带 agentOrigin 字段不做特殊 UI。
    @discardableResult
    static func drain(context: ModelContext) -> Int {
        let outboxRoot = AgentBridge.root.appendingPathComponent("outbox", isDirectory: true)
        let fm = FileManager.default
        guard let floors = try? fm.contentsOfDirectory(at: outboxRoot, includingPropertiesForKeys: nil) else { return 0 }

        var landed = 0
        for floorDir in floors where floorDir.hasDirectoryPath {
            let files = ((try? fm.contentsOfDirectory(at: floorDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }   // ts 前缀 = 时间序

            for file in files {
                guard let data = try? Data(contentsOf: file),
                      let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                    // 坏文件挪 .bad 隔离，不无限重试
                    let bad = outboxRoot.appendingPathComponent(".bad", isDirectory: true)
                    try? fm.createDirectory(at: bad, withIntermediateDirectories: true)
                    try? fm.moveItem(at: file, to: bad.appendingPathComponent(file.lastPathComponent))
                    continue
                }
                if insert(payload, context: context) {
                    landed += 1
                }
                // 落库成功或查重命中都删文件；只有"楼层没有对话可落"留着等下次
                if !needsRetry(payload, context: context) {
                    try? fm.removeItem(at: file)
                }
            }
        }
        if landed > 0 { print("[agent] outbox drained \(landed) 条") }
        return landed
    }

    /// 楼层最近的非回收站对话（v1 落点；哪个对话算"主对话"的精细化归 Phase 2）
    private static func targetConversation(floorId: String, context: ModelContext) -> Conversation? {
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == floorId && $0.isTrashed == false },
            sortBy: [SortDescriptor(\Conversation.updateTime, order: .reverse)]
        )
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    private static func needsRetry(_ payload: Payload, context: ModelContext) -> Bool {
        targetConversation(floorId: payload.floorId, context: context) == nil
    }

    /// 插入消息对。true = 本次真的落库（查重命中/无落点 = false）。
    /// CR-4 起 AgentBookNoteWriter 也调（读后感消息走同一落库口径），internal。
    static func insert(_ payload: Payload, context: ModelContext) -> Bool {
        guard let conversation = targetConversation(floorId: payload.floorId, context: context) else { return false }
        let convId = conversation.id
        let pid = conversation.profileId

        // agentOrigin 查重兜底（optional 字段不进 predicate——老教训；conversationId 缩范围 + 内存 filter）
        let nodeDesc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == pid }
        )
        let existing = (try? context.fetch(nodeDesc)) ?? []
        if existing.contains(where: { $0.agentOrigin == payload.uuid }) { return false }

        let parentId = conversation.currentNodeId
        let userNode = MessageNode(
            id: UUID().uuidString, role: "user", content: payload.userSeed, contentType: "text",
            createTime: Date(), parentId: parentId.isEmpty ? nil : parentId,
            childrenIds: [], conversationId: convId, profileId: pid
        )
        userNode.agentOrigin = payload.uuid
        context.insert(userNode)

        let assistantNode = MessageNode(
            id: UUID().uuidString, role: "assistant", content: payload.assistantText, contentType: "text",
            createTime: Date(), parentId: userNode.id,
            childrenIds: [], conversationId: convId, profileId: pid
        )
        assistantNode.agentOrigin = payload.uuid
        context.insert(assistantNode)
        userNode.childrenIds = [assistantNode.id]

        if !parentId.isEmpty, let parent = existing.first(where: { $0.id == parentId }) {
            if !parent.childrenIds.contains(userNode.id) { parent.childrenIds.append(userNode.id) }
            // 分支选择表（③b）：父有多个孩子时记上新这支，否则重开会回到旧分支
            conversation.recordBranchChoice(parentId: parentId, childId: userNode.id, parentChildCount: parent.childrenIds.count)
        }
        conversation.currentNodeId = assistantNode.id
        conversation.updateTime = Date()
        conversation.unreadCount += 1
        conversation.nodeCount += 2
        try? context.save()
        return true
    }
}
