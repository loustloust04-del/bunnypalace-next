import CryptoKit
import MemoryCore
import Foundation
import SwiftData

/// 记忆实验台的执行器（plan-memory-lab §2）：把「一句话 × 一组参数」在这层楼的真记忆上跑成一条记录。
///
/// 口径是「新开一个窗口说第一句」。选什么、拼什么全走真聊天那几个函数（`MemoryInjector.roundInputs` →
/// `RecallSelection.prepare` → `PromptAssembler.assembleTagged` → `MemoryDelivery.build`），参数都是传值。
/// 只读：自己开的 `ModelContext` 不自动保存、从不 save、不改取到的对象；不建对话和消息；不写偏好。
/// 落盘的只有这条记录（`<楼层记忆根>/lab/records/`）；真问模型的花费记在用量账本「试写」名下。
///
///     let lab = MemoryLabRunner(profile: profile, preset: preset, providers: providers, container: container)
///     var params = lab.currentParams()            // 她现在的设置；在页面上拨的只改这个值
///     let record = try await lab.run("…", params: params)
///     let history = await lab.records()
///     try await lab.judge(record.id) { $0.verdict = .up }
@MainActor
struct MemoryLabRunner {
    let profile: Profile
    let preset: Preset
    let providers: ProviderManager
    let container: ModelContainer
    /// 测试换成假的；nil = 真问模型
    var send: MemoryLabModelLoop.Send? = nil

    /// 假的窗口编号：对不上任何真窗口，所以「出处就在眼前不推回」「翻记忆排除当前窗口」都不生效，和新窗口第一句一样
    static let conversationId = "memory-lab"

    // MARK: - 给页面的入口

    /// 这层楼现在的模型（没有窗口：楼层选的 → 全局选的）
    var currentModel: ProviderModel {
        providers.resolveModel(conversationModelId: nil, profileModelId: profile.preferredModel,
                               globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
    }

    /// 她现在的设置（只读）
    func currentParams() -> MemoryLabParams {
        .current(profileId: profile.id, modelId: currentModel.id)
    }

    var store: MemoryLabStore {
        MemoryLabStore(memoryRoot: FileLibraryStore.memoryRoot(profileId: profile.id))
    }

    /// 这层楼说过的每一句，旧的在前
    func records() async -> [MemoryLabRecord] {
        let store = store
        return await Task.detached(priority: .userInitiated) { store.records() }.value
    }

    /// 改拇指 / 批注（原地重写那一条）
    @discardableResult
    func judge(_ id: String, _ change: @escaping @Sendable (inout MemoryLabRecord.Judgment) -> Void) async throws -> MemoryLabRecord {
        let store = store
        return try await Task.detached(priority: .userInitiated) { try store.judge(id: id, change) }.value
    }

    /// 比真聊天少的那几段（只有主对话那个文件拼得出来）
    static func missing(assistant: String) -> [String] {
        ["其他工具的清单和说明（这里\(assistant)手上只有「翻记忆」）", "状态行", "卡片格式说明",
         "文件库和语音条的用法提示", "健康和交易摘要", "文件夹说明"]
    }

    // MARK: - 跑一句

    /// 一组参数存进记录 / 存成一组时的样子（带上模型的名字、跟她现在的设置比差在哪）
    func recorded(_ params: MemoryLabParams) -> MemoryLabRecord.Params {
        let model = providers.model(byId: params.modelId)
        return params.recorded(model: model, provider: model.flatMap { providers.provider(for: $0) }?.name, settings: currentParams())
    }

    /// 说一句。问模型失败、模型不能用时记录照存照回（想起了什么那一半还在），原因在 `happened.error`；
    /// 只有记录写不进盘才抛错。
    /// `sentenceId / sets / paramsId` 只是原样写进记录的三个标记（这句话的键、在哪几份测试集里、算哪一组参数），
    /// 不参与选记忆、拼提示词、问模型。
    ///
    /// 一旦开始就跑完并落盘：调用方的 Task 被取消（离开页面、切楼层、重放点了停）不会传进来。
    /// 里面的 wiki 预热和全文搜词碰到取消会抛错 / 悄悄给空结果，传进来的话这一句选到的记忆会变样、或者存成一条出错记录。
    /// 调用方照样等到这一句的记录回来；要不要接着做别的（重放的下一句）自己看 `Task.isCancelled`。
    func run(_ text: String, params: MemoryLabParams, sentenceId: String? = nil, sets: [String]? = nil,
             paramsId: String? = nil) async throws -> MemoryLabRecord {
        // 另起的 Task 不继承取消
        try await Task {
            try await perform(text, params: params, sentenceId: sentenceId, sets: sets, paramsId: paramsId)
        }.value
    }

    private func perform(_ text: String, params: MemoryLabParams, sentenceId: String?, sets: [String]?,
                         paramsId: String?) async throws -> MemoryLabRecord {
        let pid = profile.id, id = UUID().uuidString, now = MemoryClock.now
        let memoryRoot = FileLibraryStore.memoryRoot(profileId: pid)
        let store = MemoryLabStore(memoryRoot: memoryRoot)
        let tuning = params.tuning.validated
        let participation = params.participation()
        let model = providers.model(byId: params.modelId)
        let credential = model.flatMap { providers.provider(for: $0) }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        // 身份 / 世界书：没有窗口 = 楼层的身份、不挂在别的对话上的书（新开的窗口也是这样）
        let sendContext = SendContextResolver.resolve(profile: profile, conversation: nil, context: context,
                                                      globalEntries: (GlobalWorldBookManager.live?.enabledBooks ?? []).flatMap(\.entries))
        let floor = sendContext.profile
        let names = EffectiveCharacterContext(profile: floor)

        var record = MemoryLabRecord(
            id: id, input: .init(text: text, at: MemoryBench.stamp(now)),
            params: recorded(params),
            happened: .init(missing: Self.missing(assistant: names.charName)), sets: sets ?? [],
            sentenceId: sentenceId, paramsId: paramsId)
        func finish(_ error: String? = nil) async throws -> MemoryLabRecord {
            if let error { record.happened?.error = error }
            let saved = record
            try await Task.detached(priority: .userInitiated) { try store.save(saved) }.value
            return saved
        }

        // 预热（同真聊天发送前那一段）：wiki 快照 → 全文搜词
        var warmed: WikiInjectionCache.WarmedSnapshot?
        do {
            warmed = try await WikiInjectionCache.shared.warm(pid, WikiInjectionCache.source(profileId: pid))
        } catch {
            if participation.archive || participation.pages { return try await finish(error.localizedDescription) }
        }
        if participation.fullText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let snapshot = warmed?.snapshot {
            let excluded = [UserDefaults.standard.string(forKey: "userName") ?? "", UserDefaults.standard.string(forKey: "assistantName") ?? "",
                            profile.userName, profile.assistantName, names.userName, names.charName]
                + (sendContext.persona.displayUserName.map { [$0] } ?? [])
            warmed?.fullText = await RecallFullTextRetriever.fetch(
                profileId: pid, text: text, snapshot: snapshot, excluding: { excluded }, tuning: tuning,
                source: WikiInjectionCache.source(profileId: pid), indexer: .shared)
        }
        // 上一个窗口最后几条：真聊天是开窗那一刻冻结的；这里现看一眼最后聊的那个窗口，不往任何窗口上写
        var previous: PreviousWindowSnapshot?
        if participation.previousWindow,
           let source = PreviousWindowPicker.latest(profileId: pid, excluding: Self.conversationId, context: context) {
            previous = await PreviousWindowPicker.captureInBackground(
                .init(window: SwiftDataConversationSource.window(source), count: tuning.previousWindowMessages),
                container: container, now: now)
        }
        let hidden = EffectiveMemoryParticipation.hiddenSources(profileId: pid, context: context)
        let scripts = RegexPipeline.scripts(profile: floor, preset: preset, cards: RegexPipeline.liveCards?.cards ?? [])
        let journal = CalendarInjection.todayJournalText(profileId: pid, today: now)

        func assemble(_ participation: EffectiveMemoryParticipation) -> Pass {
            let inputs = MemoryInjector.roundInputs(profileId: pid, participation: participation, store: SwiftDataMemoryStore(),
                                                    context: context, warmedWiki: warmed, useCachedWiki: false,
                                                    previousWindow: previous, hiddenSources: hidden)
            let recalled = RecallSelection.prepare(
                profile: floor, conversationId: Self.conversationId, turnId: id, branchAnchor: Self.conversationId,
                text: text, state: RecallConversationState(), existingDecision: nil, inputs: inputs,
                recentMessages: [text], now: now, tuning: tuning, enabled: participation.on)
            let timeline = CalendarInjection.timelineSlot(profileId: pid, currentConversationId: Self.conversationId, now: now,
                                                          participation: participation, hiddenSources: hidden)
            let assembled = PromptAssembler.assembleTagged(
                preset: preset, profile: floor, memories: inputs.memories, chatHistory: [(role: "user", content: text)],
                worldBooks: sendContext.worldBooks, globalEntries: sendContext.globalEntries,
                timelineSummary: timeline.text, volatileNote: journal, regexScripts: scripts,
                selfMemory: (inputs.selfMemory?.text).flatMap { $0.isEmpty ? nil : $0 },
                memoryBudget: inputs.archiveBudget, cardGuide: .none, wiki: inputs.wiki,
                wikiScanMessages: [text], recallLayers: recalled.layers)
            return Pass(inputs: inputs, decision: recalled.decision, layers: recalled.layers, timeline: timeline,
                        segments: assembled.segments)
        }
        let with = assemble(participation)
        // 同一句、同一组参数、记忆整个关掉再拼一次：只为按段比出多了什么，不多问模型
        let without = assemble(params.participation(memory: false))

        let delivery = Self.delivery(with, journal: journal, participation: participation,
                                     cacheFriendly: preset.sampling.cacheFriendly == true, now: now)
        var receipt = RecallTurnReceipt(decision: with.decision)
        receipt.delivery = delivery
        let ordered = PromptAssembler.orderedMessages(from: with.segments)
        let all = SwiftDataMemoryStore().listActive(profileId: pid, context: context)
        let facts = all.filter { $0.isFragment && !$0.isUserExplicit }
        let info = Bundle.main.infoDictionary ?? [:]
        record.environment = .init(
            profileId: pid,
            counts: .init(approvedFacts: facts.filter { $0.reviewedAt != nil }.count, allFacts: facts.count,
                          wikiPages: warmed?.snapshot.pages.count, pinned: all.filter(\.isUserExplicit).count),
            fingerprint: Self.fingerprint(with.inputs), presetName: preset.name, promptHash: Self.promptHash(without.segments),
            appVersion: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String,
            commit: (info["GitCommit"] ?? info["GIT_COMMIT"]) as? String, window: MemoryLabRecord.Environment.firstTurn)
        record.happened?.messages = ordered.map { .init(role: $0.role, content: $0.content, source: $0.source.displayName) }
        record.happened?.prompt = .init(segments: Self.diff(with: with.segments, without: without.segments),
                                        everyRound: with.layers.stable, pushed: with.layers.volatile)
        record.happened?.receipt = receipt

        // 问模型
        let send: MemoryLabModelLoop.Send
        if let injected = self.send {
            send = injected
        } else {
            guard let model, let credential else { return try await finish("找不到这个模型（\(params.modelId)）") }
            // CC 桥那边是一场真的 Claude Code 会话，而且收不到这段提示词：不往里发
            guard credential.type != .ccBridge else {
                return try await finish("「\(credential.name)」走的是 Claude Code，收不到这里拼的提示词，实验台问不了它")
            }
            let definition = RecallTool.definition
            send = MemoryLabModelLoop.routerSend(
                router: ProviderRouter(usageContext: UsageContext(kind: .memoryTrial, profileId: pid)),
                model: model, providers: providers, ordered: ordered, sampling: StreamingPreference.apply(preset.sampling),
                tools: [credential.type == .anthropic ? ToolSchemaRenderer.anthropic(definition) : ToolSchemaRenderer.openAI(definition)])
        }
        let attempt = receipt.beginAttempt(deliveryId: delivery.id)
        receipt.markAttempt(attempt, status: .submitted)
        let source = SwiftDataConversationSource(container: container)
        let environment = RecallTool.l1Environment(container: container)
        let userName = profile.userName.isEmpty ? "用户" : profile.userName
        let assistantName = profile.assistantName.isEmpty ? "AI" : profile.assistantName
        let outcome = await MemoryLabModelLoop.run(
            recallTool: params.recallTool, maximumCalls: tuning.maximumRecallCalls, turnId: id, send: send
        ) { arguments in
            await RecallTool.execute(inputJSON: arguments, profileId: pid, currentConversationId: nil,
                                     userName: userName, assistantName: assistantName, source: source, memoryRoot: memoryRoot,
                                     tuning: tuning, memoryParticipation: participation.participates, environment: environment)
        }
        receipt.reads = outcome.reads
        if outcome.reply != nil {
            // 回执上记「回了」；提议的召回状态不落到任何窗口（applyState: false）
            var unused = RecallConversationState()
            receipt.recordResponse(attemptId: attempt, state: &unused, currentTurnId: id,
                                   currentBranchAnchor: Self.conversationId, applyState: false)
        } else {
            receipt.finishAttempt(id: attempt, status: .failed)
        }
        record.happened?.receipt = receipt
        record.happened?.reply = outcome.reply
        record.happened?.rounds = outcome.rounds
        record.happened?.usage = outcome.usage
        return try await finish(outcome.reply == nil ? (outcome.error ?? "模型没有回话") : nil)
    }

    // MARK: - 拼的零件

    private struct Pass {
        let inputs: MemoryInjector.RoundInputs
        let decision: RecallTurnDecision
        let layers: RecallMemoryLayers
        let timeline: CalendarInjection.TimelineSlot
        let segments: [TaggedSegment]
    }

    /// 「每轮都带了什么」的清单：单位怎么列、怎么在最终那几段里核存活，同真聊天组装处（那段在主对话文件里，不能共用）
    private static func delivery(_ pass: Pass, journal: String?, participation: EffectiveMemoryParticipation,
                                 cacheFriendly: Bool, now: Date) -> RecallDelivery {
        typealias Kind = RecallDeliveryItem.Kind
        var units = pass.layers.units
        for unit in pass.timeline.units {
            units.append(.init(kind: Kind.timeline, ref: unit.key, text: unit.line, tokens: Memory.estimateTokens(unit.line),
                               shown: unit.line.trimmingCharacters(in: .whitespaces), segment: .timeline))
        }
        for pending in pass.timeline.pendingUnits {
            units.append(.init(kind: Kind.pending, ref: "pending:\(pending.conversationId)", text: pending.line,
                               tokens: Memory.estimateTokens(pending.line), shown: pending.line, segment: .timeline))
        }
        if let anniversary = pass.timeline.anniversaryUnit {
            units.append(.init(kind: Kind.anniversary, ref: "anniversary", text: anniversary,
                               tokens: Memory.estimateTokens(anniversary), shown: anniversary, segment: .timeline))
        }
        if let journal {
            units.append(.init(kind: Kind.journal, ref: "journal:\(DailyActivity.dayKey(now, calendar: .current))", text: journal,
                               tokens: Memory.estimateTokens(journal), shown: "今天的日记", segment: .volatileContext))
        }
        // 记忆那一段：缓存友好时每轮都带的 / 推送的各一段；否则同一段里前后两截
        let stable = pass.layers.stable, volatile = pass.layers.volatile
        let memory = pass.segments.filter { $0.source == .memory }.map(\.content)
        func host(_ layer: String) -> String? {
            (cacheFriendly && !layer.isEmpty ? memory.first { $0 == layer } : nil) ?? memory.first
        }
        var located: [RecallDeliveryUnit.Segment: String] = [:]
        located[.memoryStable] = host(stable)
        if let full = host(volatile) {
            located[.memoryVolatile] = !cacheFriendly && !stable.isEmpty && full.hasPrefix(stable)
                ? String(full.dropFirst(stable.count)) : full
        }
        located[.timeline] = pass.segments.first { $0.source == .timeline }?.content
        located[.volatileContext] = pass.segments.filter { $0.source == .volatileContext }.map(\.content).joined(separator: "\n")
        return MemoryDelivery.build(
            units: units, route: "api",
            gate: RecallGateSnapshot(participation, hiddenFragments: pass.inputs.hiddenFragmentCount,
                                     hiddenTimeline: pass.timeline.hiddenCount),
            locate: MemoryDelivery.containmentLocator(located) { $0 })
    }

    /// 带记忆比不带记忆多出来 / 变了的段（按提示词里的顺序）
    static func diff(with: [TaggedSegment], without: [TaggedSegment]) -> [MemoryLabRecord.PromptDiff.Segment] {
        var pool = without
        var changed: [TaggedSegment] = []
        for segment in with {
            if let same = pool.firstIndex(where: { $0.source == segment.source && $0.role == segment.role && $0.content == segment.content }) {
                pool.remove(at: same)
            } else {
                changed.append(segment)
            }
        }
        return changed.map { segment in
            let before = pool.firstIndex { $0.source == segment.source && $0.role == segment.role }.map { pool.remove(at: $0).content }
            return .init(source: segment.source.displayName, role: segment.role, with: segment.content, without: before)
        }
    }

    /// 这一轮能用上的记忆的指纹：条目（编号 + 改动时间）、页（路径 + 版本）、目录、{助手}的记忆、上个窗口
    private static func fingerprint(_ inputs: MemoryInjector.RoundInputs) -> String {
        var lines = inputs.memories.map { "m:\($0.id.uuidString)|\($0.updatedAt.timeIntervalSince1970)" }
        lines += (inputs.wiki?.pages ?? []).map { "p:\($0.path)|\($0.version)" }
        if let index = inputs.wiki?.indexLines, !index.isEmpty { lines.append("i:" + hash(index.joined(separator: "\n"))) }
        if let own = inputs.selfMemory?.text, !own.isEmpty { lines.append("s:" + hash(own)) }
        if let previous = inputs.previousWindow { lines.append("w:\(previous.sourceId)|\(previous.leafId)") }
        return hash(lines.sorted().joined(separator: "\n"))
    }

    /// 人设 / 预设 / 世界书那几段的哈希。取宏没展开的原样（时间之类的宏不会让它每分钟变），不算对话、记忆、时间轴、动态段
    private static func promptHash(_ segments: [TaggedSegment]) -> String {
        hash(segments.filter {
            switch $0.source {
            case .chatHistory, .memory, .timeline, .contextSummary, .volatileContext: return false
            default: return true
            }
        }.map { $0.role + "\u{0}" + $0.template }.joined(separator: "\u{1}"))
    }

    private static func hash(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
