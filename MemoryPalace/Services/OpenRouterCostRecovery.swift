import Foundation
import SwiftData

struct OpenRouterCostRecovery: Sendable {
    var fetch: @Sendable (URLRequest) async throws -> Data = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
    var sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }

    func recover(_ original: UsageRecord, apiKey: String, ledger: UsageLedger) async -> UsageRecord? {
        guard let rid = original.responseId, original.costSource != .reported else { return nil }
        // 相对请求收尾的 10s / 30s / 120s；元数据可见延迟与真实 key 权限待实测。
        for delay: UInt64 in [10, 20, 90] {
            do {
                try await sleep(delay * 1_000_000_000)
                var url = URLComponents(string: "https://openrouter.ai/api/v1/generation")!
                url.queryItems = [URLQueryItem(name: "id", value: rid)]
                var request = URLRequest(url: url.url!, timeoutInterval: 10)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let data = try await fetch(request)
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let generation = obj["data"] as? [String: Any],
                      let cost = generation["total_cost"] as? Double, cost.isFinite, cost >= 0 else { continue }
                let row = original.costCorrection(usd: cost)
                ledger.append(row)
                return row
            } catch is CancellationError { return nil }
            catch { continue }
        }
        return nil
    }
}

struct NodeUsageAmounts {
    private var calls: [String: UsageRecord] = [:]
    mutating func add(_ record: UsageRecord) {
        guard let id = record.invocationId else { return }
        if record.correction, var original = calls[id] {
            original.costUSD = record.costUSD
            original.costSource = record.costSource
            original.correction = true
            calls[id] = original
        } else if calls[id]?.correction != true { calls[id] = record }
    }
    var costUSD: Double? {
        guard !calls.isEmpty, !calls.values.contains(where: { $0.costUSD == nil }) else { return nil }
        return calls.values.reduce(0) { $0 + ($1.costUSD ?? 0) }
    }
    var input: Int { calls.values.reduce(0) { $0 + $1.input } }
    var output: Int { calls.values.reduce(0) { $0 + $1.output } }
    var cacheRead: Int { calls.values.reduce(0) { $0 + $1.cacheRead } }
    var cacheWrite: Int { calls.values.reduce(0) { $0 + $1.cacheWrite } }
}

/// 只维护当前进程的 footer 订阅；金额的持久真相仍是 usage.jsonl。
@MainActor
final class UsageCostSettlement {
    static let shared = UsageCostSettlement()
    private var sinks: [String: (UsageRecord) -> Void] = [:]
    private var settled: [String: UsageRecord] = [:]
    private var amounts: [String: NodeUsageAmounts] = [:]
    private let ledger: UsageLedger

    init(ledger: UsageLedger = .shared) { self.ledger = ledger }

    func attach(record: UsageRecord, node: MessageNode) {
        guard let invocation = record.invocationId else { return }
        if let profile = record.profileId, profile != node.profileId { return }
        if let nodeId = record.messageNodeId, nodeId != node.id { return }
        let nodeKey = node.profileId + "\u{0}" + node.id
        if amounts[nodeKey] == nil {
            var saved = NodeUsageAmounts()
            for row in ledger.load() where row.messageNodeId == node.id && row.profileId == node.profileId { saved.add(row) }
            amounts[nodeKey] = saved
        }
        amounts[nodeKey]?.add(record)
        writeAmounts(nodeKey, to: node)
        guard record.costSource != .reported else { return }
        let nodeId = node.id
        let profileId = node.profileId
        let context = node.modelContext
        sinks[invocation] = { [weak self, weak node, weak context] correction in
            self?.amounts[nodeKey]?.add(correction)
            var target = node
            if target == nil, let context {
                // 切支后节点引用可能释放：按 id + profile 精确取回，不扫消息表。
                var descriptor = FetchDescriptor<MessageNode>(predicate: #Predicate {
                    $0.id == nodeId && $0.profileId == profileId
                })
                descriptor.fetchLimit = 1
                target = (try? context.fetch(descriptor))?.first
            }
            guard let target else { return }
            self?.writeAmounts(nodeKey, to: target)
            try? target.modelContext?.save()
        }
        if let correction = settled.removeValue(forKey: invocation) { sinks[invocation]?(correction) }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            self?.sinks.removeValue(forKey: invocation)
            self?.settled.removeValue(forKey: invocation)
        }
    }

    private func writeAmounts(_ key: String, to node: MessageNode) {
        guard let total = amounts[key] else { return }
        node.usagePromptTokens = total.input
        node.usageCompletionTokens = total.output
        node.usageCacheReadTokens = total.cacheRead
        node.usageCacheWriteTokens = total.cacheWrite
        node.usageCostUSD = total.costUSD
    }

    func applyNodeCorrection(_ correction: UsageRecord) {
        guard let id = correction.invocationId, correction.costUSD != nil else { return }
        if let sink = sinks[id] { sink(correction) }
        else { settled[id] = correction }
    }

    func apply(_ correction: UsageRecord, original: UsageRecord) {
        applyNodeCorrection(correction)
        GlobalBudgetStore.shared.applyCostCorrection(original: original, corrected: correction)
    }
}
