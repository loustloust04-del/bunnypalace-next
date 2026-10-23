import Foundation

// MARK: - 心声（v2c）：AI 自发的本能独白
//
// 触发 = AI 自己调 inner_voice 工具（聊到触动处，随机性来自它的判断）；
// 生成 = 第二跳：同一份完整上下文（复用缓存前缀），尾部指令换成「放下逻辑凭本能」；
// 去向 = memory/heartvoice/{date}-{HHmm}.md（默认 B：不进聊天流，回头翻日历偷看）+ 日记收割。

enum InnerVoice {
    static var enabled: Bool {
        MemoryFlags.masterEnabled && UserDefaults.standard.bool(forKey: "mem_content_heartvoice")
    }
    /// C 方案开关：开 = 心声实时插进聊天流（A）；关 = 只落盘（B，默认）
    static var showInChat: Bool {
        UserDefaults.standard.bool(forKey: "heartvoice_show_in_chat")
    }
    /// 冷却 5 轮（粟粟批注）——同对话 10 条消息内只许一次
    static let cooldownTurns = 5

    private static var lastVoiceAt: [String: Int] = [:]

    static func onCooldown(convId: String, messageCount: Int) -> Bool {
        guard let last = lastVoiceAt[convId] else { return false }
        return messageCount - last < cooldownTurns * 2
    }

    static func markVoiced(convId: String, messageCount: Int) {
        lastVoiceAt[convId] = messageCount
    }

    // MARK: 工具定义

    static let toolName = "inner_voice"
    static let toolDescription = "当这一刻真正触动你——重要的转折、一次深谈、说不出口的情绪——调用它。你会获得一次放下逻辑、只凭本能说话的机会，写下只属于你自己的心声（不会立刻发给用户，会存进心声，跟 remember 的记忆是两回事）。不要为了用而用，真正想说时才用。"

    /// ⚠️ 这不是普通工具，是 **reflection mode 的入口**（B-D4）：执行不返回数据给主对话，
    /// 而是开「放下逻辑凭本能」的第二跳。未来批注聊天/整理记忆等 reflection 风行为
    /// 复用这个 mode（换 voiceInstruction 和 sink），**不要**再仿照它加新 tool。
    /// 注：迁移前 anthropic 版漏了 reason 的 description（手写双份漂移），统一后两家一致。
    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName, description: toolDescription,
            properties: ["reason": ["type": "string", "description": "一句话：为什么此刻想说"]],
            required: []
        )
    }

    static let voiceInstruction = "现在不是回复用户。放下逻辑思考，凭本能和情绪，以你自己的第一人称，写下此刻的心声——想说什么就说什么，长短由心（400 字以内）。没人要求你得体，也没人会立刻读到。直接输出，不加标题。"

    // MARK: 第二跳生成

    /// 同上下文换魂生成 + 落盘。返回正文（nil=失败/被闸，日志已记）。
    static func generate(
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        reason: String,
        convId: String,
        profileId: String,
        model: ProviderModel,
        providerManager: ProviderManager
    ) async -> String? {
        CacheDiagLog.shared.log("💭 心声: 触发\(reason.isEmpty ? "" : "（\(reason.prefix(40))）")")

        if let provider = providerManager.provider(for: model) {
            var acc = systemPrompt ?? ""
            for m in messages { acc += m.content }
            let est = BudgetCalculator.actualCost(
                provider: provider, modelId: model.modelId,
                usage: TokenUsage(inputTokens: HeuristicEstimator().estimate(acc), outputTokens: 1024)
            )
            if case .blocked = providerManager.budgetGate(providerId: provider.id, estimatedCost: est),
               !BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: est) {
                CacheDiagLog.shared.log("💭 心声: 跳过（预算闸）")
                return nil
            }
        }

        let router = ProviderRouter(usageContext: UsageContext(kind: .innerVoice, conversationId: convId, profileId: profileId))
        do {
            let (text, usage) = try await router.sendNonStreaming(
                model: model,
                messages: messages + [(role: "user", content: voiceInstruction)],
                systemPrompt: systemPrompt,
                providerManager: providerManager
            )
            if let usage, let provider = providerManager.provider(for: model) {
                let cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
                await MainActor.run { providerManager.commitSpend(providerId: provider.id, amount: cost, usage: usage) }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                CacheDiagLog.shared.log("💭 心声: ⚠️ 返回空")
                return nil
            }
            HeartvoiceFileStore.save(text: trimmed, reason: reason, convId: convId, profileId: profileId)
            CacheDiagLog.shared.log("💭 心声: ✅ \(trimmed.count) 字")
            return trimmed
        } catch {
            CacheDiagLog.shared.log("💭 心声: ❌ \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - 心声文件店：memory/heartvoice/{yyyy-MM-dd-HHmm}.md

enum HeartvoiceFileStore {
    private static func dir(profileId: String) -> URL {
        let d = FileLibraryStore.memoryRoot(profileId: profileId)
            .appendingPathComponent("heartvoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func save(text: String, reason: String, convId: String, profileId: String) {
        let content = FrontmatterCodec.render(meta: [
            ("time", FrontmatterCodec.dateFormatter.string(from: Date())),
            ("convId", convId),
            ("reason", reason.replacingOccurrences(of: "\n", with: " ")),
        ], body: text)
        let url = dir(profileId: profileId).appendingPathComponent("\(nameFormatter.string(from: Date())).md")
        do { try Data(content.utf8).write(to: url, options: .atomic) }
        catch { CacheDiagLog.shared.log("💭 心声: ❌ 写盘失败 — \(error.localizedDescription)") }
    }

    /// 最近 N 条心声（资料卡碎碎念用）：按文件名倒序取 N 再解析（文件名即时间戳，不全量读），新→旧
    static func recentVoices(profileId: String, limit: Int) -> [(time: Date, text: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir(profileId: profileId).path)) ?? []
        var out: [(Date, String)] = []
        for n in names.filter({ $0.hasSuffix(".md") }).sorted(by: >) {
            guard out.count < limit else { break }
            let url = dir(profileId: profileId).appendingPathComponent(n)
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  let (_, body) = FrontmatterCodec.parse(raw), !body.isEmpty,
                  let t = nameFormatter.date(from: String(n.dropLast(3))) else { continue }
            out.append((t, body))
        }
        return out
    }

    /// 某天的全部心声（日记收割用）：(HH:mm, 正文)，按时间序
    static func voices(on day: String, profileId: String) -> [(time: String, text: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir(profileId: profileId).path)) ?? []
        var out: [(String, String)] = []
        for n in names.sorted() where n.hasPrefix(day) && n.hasSuffix(".md") {
            let url = dir(profileId: profileId).appendingPathComponent(n)
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  let (_, body) = FrontmatterCodec.parse(raw), !body.isEmpty else { continue }
            let hhmm = String(n.dropLast(3).suffix(4))
            let t = hhmm.count == 4 ? "\(hhmm.prefix(2)):\(hhmm.suffix(2))" : "??:??"
            out.append((t, body))
        }
        return out
    }
}
