import MemoryCore
import Foundation
import SwiftData
#if os(iOS)
import UIKit
#endif

/// C2 本机路线被停（进后台 / 内存警告）= 被打断，不算失败、不记健康，下一轮重来。
/// staleClaim = 认领已经超时作废（10-16 astra #3）：这包不落库、不动水位、不记失败
enum FragmentPoolError: LocalizedError, Equatable {
    case interrupted
    case staleClaim
    case local(String)

    var errorDescription: String? {
        switch self {
        case .interrupted: return "被打断了（app 进了后台）"
        case .staleClaim: return "认领超时作废了"
        case .local(let message): return message
        }
    }
}

// MARK: - C2 用哪个模型（默认跟提取模型；选了本机、没装 / 在后台 → 这一轮用提取模型）

enum FragmentModelRoute {
    static let key = "mem_model_c2"
    /// 跟「提取模型」（老值；现在空就是跟提取模型）
    static let extractChoice = "extract"
    static let localPrefix = "local:"

    enum Route: Equatable {
        case local(modelId: String)
        case remote(ProviderModel)
    }

    struct Resolved: Equatable {
        let route: Route
        /// 实际跑的模型名（日志、状态那行）
        let displayName: String
        /// 想用本机却退回提取模型时写清为什么
        let fallbackNote: String?
        /// 选了本机但本机模型没下（一次性提示用）
        let localMissing: Bool

        var isLocal: Bool { if case .local = route { return true } else { return false } }
    }

    static func localName(_ modelId: String) -> String {
        switch modelId {
        case AssistantLocalModel.smart.id: return "本机 4B"
        case AssistantLocalModel.light.id: return "本机 1.7B"
        default: return "本机模型"
        }
    }

    /// 选择器读的时候：老值 "extract" 就是默认项（空）
    static func pickerChoice(_ choice: String) -> String {
        choice == extractChoice ? "" : choice
    }

    /// 选了本机哪一款；空（默认）/ 云上模型 = nil
    static func localModelId(choice: String) -> String? {
        choice.hasPrefix(localPrefix) ? String(choice.dropFirst(localPrefix.count)) : nil
    }

    /// 纯函数：空 = 提取模型；选了本机、装了且在前台 → 本机，否则 → 提取模型并写清；单选了某张卡上的模型 → 它（卡停了退提取模型）
    static func resolve(choice: String, memoryModel: ProviderModel, remoteModels: [ProviderModel],
                        localSupported: Bool, appActive: Bool, localInstalled: (String) -> Bool) -> Resolved {
        if let id = localModelId(choice: choice) {
            if localSupported, localInstalled(id), appActive {
                return Resolved(route: .local(modelId: id), displayName: localName(id), fallbackNote: nil, localMissing: false)
            }
            let why = !localSupported ? "这台设备跑不了本机模型" : (!localInstalled(id) ? "本机模型没下" : "app 在后台")
            return Resolved(route: .remote(memoryModel), displayName: memoryModel.name, fallbackNote: "\(why)，这一轮用 \(memoryModel.name)",
                            localMissing: localSupported && !localInstalled(id))
        }
        if choice != extractChoice, let m = remoteModels.first(where: { $0.id == choice }) {
            return Resolved(route: .remote(m), displayName: m.name, fallbackNote: nil, localMissing: false)
        }
        return Resolved(route: .remote(memoryModel), displayName: memoryModel.name, fallbackNote: nil, localMissing: false)
    }

    /// 后台写手选模型的卡：去掉本机卡（本机走 C2 自己的那一项；ProviderRouter 对本机的拒绝保留）
    static func remoteCredentials(_ enabled: [APICredential]) -> [APICredential] {
        enabled.filter { $0.type != .localMLX && !$0.models.isEmpty }
    }

    /// app 里的真解析（主线程：要看 app 在不在前台）。choiceKey = 读哪一项的单选（C3 同一套，`CatalogModelRoute.key`）
    @MainActor
    static func resolve(providerManager: ProviderManager, chatFallback: ProviderModel, defaults: UserDefaults = .standard,
                        choiceKey: String = key) -> Resolved {
        let memory = ConversationViewModel.memoryModel(providerManager: providerManager, fallback: chatFallback)
        #if os(iOS)
        let active = UIApplication.shared.applicationState != .background
        #else
        let active = true
        #endif
        return resolve(choice: defaults.string(forKey: choiceKey) ?? "", memoryModel: memory,
                       remoteModels: remoteCredentials(providerManager.enabledProviders).flatMap(\.models),
                       localSupported: LocalLLMService.isSupported, appActive: active,
                       localInstalled: { AssistantModelStore.installedDirectory(modelId: $0) != nil })
    }

    /// 按路线拿 caller：本机 → 排 `LocalLLMService` 的队（$0，按 0 花费记账）；云上 → 记忆写手同一个 caller（写入预算 + 全局闸 + 记花费，记在 kind 名下：C2 碎片池 / C3 整理编目）。
    /// 写入预算超了两条路都停（astra #12：超了后台写手停，本机也算后台写手）
    static func caller(for route: Route, providerManager: ProviderManager, conversationId: String, profileId: String, kind: UsageKind = .memory,
                       budgetExceeded: @escaping () -> Bool = { WriteBudgetStore.exceeded() },
                       preflight: ((String) async -> String?)? = nil) -> SessionSegmentWriter.Caller {
        switch route {
        case .local(let id):
            return { system, user in
                if budgetExceeded() {
                    CacheDiagLog.shared.log("🧠 \(kind.label)（本机）: 跳过（写入预算用完）")
                    return nil
                }
                return try await runLocal(modelId: id, system: system, user: user)
            }
        case .remote(let model):
            return SessionSegmentWriter.modelCaller(model: model, providerManager: providerManager,
                                                    conversationId: conversationId, profileId: profileId, kind: kind, preflight: preflight)
        }
    }

    /// 本机路线留给对话那截的字数：按实际 system 字数算（和 `LocalChatProvider.trimmed` 同一口径：system 截 3000 字、总共 6000 字、至少 500），
    /// 再让出重来时补的那句，免得重来那次开头被 trimmed 截掉
    static func localUserBudget(system: String, retryChars: Int = FragmentPool.retryNote.count) -> Int {
        let sys = system.count > LocalChatProvider.systemBudget ? LocalChatProvider.systemBudget + 1 : system.count
        return max(LocalChatProvider.totalBudget - sys, 500) - retryChars
    }

    @MainActor
    private static func runLocal(modelId: String, system: String, user: String) async throws -> String? {
        #if os(iOS)
        guard UIApplication.shared.applicationState != .background else { throw FragmentPoolError.interrupted }
        #endif
        let trimmed = LocalChatProvider.trimmed(system: system, messages: [(role: "user", content: user)], hasImages: false)
        let request = AssistantBackendRequest(system: trimmed.system, history: trimmed.history, tools: [], toolTurns: [], maxTokens: 1024)
        return try await withCheckedThrowingContinuation { continuation in
            LocalLLMService.shared.run(modelId: modelId, request: request) { event in
                switch event {
                case .token:
                    break
                case .finished(let text):
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: t.isEmpty ? nil : t)
                case .toolCalls:
                    continuation.resume(returning: nil)
                case .failed(let message):
                    continuation.resume(throwing: message.contains("被停下") || message.contains("模拟器")
                                        ? FragmentPoolError.interrupted : FragmentPoolError.local(message))
                }
            }
        }
    }
}

// MARK: - C2 碎片池在 app 这一半：落库 / 健康状态 / 本机预算（提示词、解析、跑一包在包里 `FragmentPool+Writer.swift`）

extension FragmentPool {
    /// app 这一半：本机路线按 `LocalChatProvider` 的口径给对话那截留字数，其余同包里的 `run`
    static func run(_ messages: [Message], names: MemoryExtractor.Names, local: Bool,
                    defaults: UserDefaults = .standard, onFirstRejection: ((Int, String) -> Void)? = nil,
                    caller: SessionSegmentWriter.Caller) async throws -> Batch? {
        try await run(messages, names: names,
                      userBudget: local ? { FragmentModelRoute.localUserBudget(system: $0, retryChars: $1) } : nil,
                      defaults: defaults, onFirstRejection: onFirstRejection, caller: caller)
    }

    /// 落库：只加；一字不差的不加。出处 = 第几条消息（发生日按 05:00 日界）；出处原话 = 那条消息的开头一截（`MemoryEntryLine.quote`，
    /// 整段写手给了几个 `msgs` 的取第一个，和跳转锚是同一条）；它给的全部 `msgs` 换成这一批里那几条的 id 存进 `sourceNodeIds`。返回新加了几条。
    /// 字段（importance 等）全部赋好后只存一次（10-16 astra #5：先存正文再补字段，中间被杀会留下认不出是 C2 的半成品）；
    /// 存不成就把这次插进去的撤掉再抛，免得没存的留在 context 里、下次重来被当成「一字不差」跳过
    @discardableResult
    static func write(_ fragments: [Fragment], messages: [Message], profileId: String, conversationId: String?,
                      extractedBy: String, store: MemoryStore, context: ModelContext) throws -> Int {
        try insert(fragments, messages: messages, profileId: profileId, conversationId: conversationId,
                   extractedBy: extractedBy, store: store, context: context).count
    }

    /// 同 `write`，返回新加的那几张卡的 id（按落库的先后）：「C2 整理」要知道这一批是哪几张
    static func insert(_ fragments: [Fragment], messages: [Message], profileId: String, conversationId: String?,
                       extractedBy: String, store: MemoryStore, context: ModelContext) throws -> [UUID] {
        guard !fragments.isEmpty else { return [] }
        var contents = Set(store.listAll(profileId: profileId, context: context).map(\.content))
        var inserted: [Memory] = []
        for f in fragments {
            guard !contents.contains(f.content), messages.indices.contains(f.msg - 1) else { continue }
            let source = messages[f.msg - 1]
            let m = store.insertUnsaved(content: f.content, category: f.category, keywords: f.tags, profileId: profileId,
                                        isUserExplicit: false, extractedBy: extractedBy, sourceConversationId: conversationId,
                                        sourceQuote: MemoryEntryLine.quote(source.content), sourceNodeId: source.id, context: context)
            m.occurredDay = f.occurredDay ?? MemoryDay.key(source.date ?? Date())
            m.importance = f.importance
            m.emotion = f.emotion
            m.resolved = f.resolved
            m.validUntil = f.validUntil?.value.flatMap { validUntilDate($0) }
            m.subject = f.subject
            m.speaker = f.speaker
            m.confidence = f.confidence
            let ids = (f.msgs ?? []).filter { messages.indices.contains($0 - 1) }.map { messages[$0 - 1].id }
            m.sourceNodeIds = ids.isEmpty ? nil : ids
            contents.insert(f.content)
            inserted.append(m)
        }
        guard !inserted.isEmpty else { return [] }
        do {
            try context.save()
        } catch {
            for m in inserted { context.delete(m) }
            throw error
        }
        return inserted.map(\.id)
    }

    /// 给整段写手看的已记的卡：这个窗口出过的、还活着的，新的在前，有上限
    static func knownCards(profileId: String, conversationId: String, store: MemoryStore, context: ModelContext) -> [KnownCard] {
        store.listAll(profileId: profileId, context: context)
            .filter { $0.sourceConversationId == conversationId && $0.supersededAt == nil }
            .prefix(FragmentWatch.wholeKnownCards)
            .map { KnownCard(subject: $0.subject, content: $0.content) }
    }

    /// 日志那条：「记下 4 条 · 写 + 核对（初稿 7 张） · 拒收 1 张（格式不对）」
    static func note(added: Int, rejected: Int, fallback: String?, verified: Batch.Verified? = nil) -> String {
        var s = "记下 \(added) 条"
        switch verified {
        case .adopted(let draft): s += " · 写 + 核对（初稿 \(draft) 张）"
        case .keptDraft: s += " · 写 + 核对（核对那次没成，留初稿）"
        case nil: break
        }
        if rejected > 0 { s += " · 拒收 \(rejected) 张（格式不对）" }
        if let fallback { s += " · \(fallback)" }
        return s
    }

    // MARK: - 跑一包（API / CC 两条路共用）

    /// 一包的结果
    enum Outcome: Equatable {
        /// 预算闸 / 空输出 / 被打断 / 断网 / 开关关了 / 认领作废：不算失败，这一截留着下次再来
        case skipped
        /// 写成了（合法空包也算）
        case done(added: Int)
        /// 老写手两次都不是合格 JSON，整包拒收（记了失败）：这一截不再重试
        case rejected
        /// 整段写手整包拒收（两次都不是合格 JSON / 交回来的一条合格的都没有；记了失败）：这一截留着，
        /// 这个窗口冷却 `SessionCloseout.formatCooldown` 后再试（`FragmentWatch.finish`）
        case held
        /// 记了失败但没写成（请求出错 / 超时 / 落库失败）：这一截留着下次再来（10-16 astra #2）
        case failed

        /// 水位能不能提交（API / CC 同一规矩）：只有写成（含合法空包）或老写手整包拒收；整段写手整包拒收、网络 / 存储失败一律放回
        var settled: Bool {
            switch self {
            case .done, .rejected: return true
            case .skipped, .held, .failed: return false
            }
        }
    }

    /// 跑一包：调模型（前后复查开关，astra #1）→ 落库 → 记健康状态和日志
    /// whole 给了 = 走整段写手（plan-c2-whole-span-writer）：这一截连同前文和已记的卡给模型，写完再核对一次
    /// （两次调用都走同一个 caller：各自查预算、各自记账，日志那条的花费是两次的和）；不给 = 老写手
    /// 整段写手的提示词：她在「提取提示词」页改过就用她那份（`activeWholeTemplate`），没改用默认模板；老写手照旧读它自己的旧 key
    static func process(_ messages: [Message], names: MemoryExtractor.Names, caller: @escaping SessionSegmentWriter.Caller,
                        local: Bool, profileId: String, modelName: String, fallbackNote: String?, whole: WholeContext? = nil,
                        defaults: UserDefaults = .standard,
                        write: ([Fragment]) async throws -> Int) async -> Outcome {
        var firstRejectionNote: String?
        var firstRejected: Int?
        func recordSkipped(_ reason: String) {
            guard let firstRejectionNote else { return }
            MemoryWriteLog.record(.extract, profileId: profileId, ok: false,
                                  note: "\(firstRejectionNote) · 跳过：\(reason)", model: modelName, rejected: firstRejected, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        }
        do {
            let gated = SessionSegmentWriter.gated({ MemoryHealthStore.isOn(.extract) }, caller)
            let onFirstRejection: (Int, String) -> Void = { count, reason in
                firstRejected = count
                firstRejectionNote = "首轮拒收 \(count) 张：\(reason)"
            }
            let written = if let whole {
                try await runWhole(messages, context: whole, names: names, template: activeWholeTemplate(defaults: defaults), verify: true,
                                   onFirstRejection: onFirstRejection, caller: gated)
            } else {
                try await run(messages, names: names, local: local, defaults: defaults, onFirstRejection: onFirstRejection, caller: gated)
            }
            guard let batch = written else {
                recordSkipped("预算闸 / 空输出 / 开关关了")
                return .skipped
            }
            if batch.fragments.isEmpty && batch.rejected > 0 {
                let error = MemoryWriterError.format("重写后拒收 \(batch.rejected) 张：\(batch.rejectionReasons.first ?? "卡片校验失败")")
                guard recordFailure(error, profileId: profileId, modelName: modelName,
                                    note: firstRejectionNote, rejected: batch.rejected) else {
                    recordSkipped(error.localizedDescription)
                    return .skipped
                }
                return whole == nil ? .rejected : .held
            }
            // 核对那次被开关拦下时留的是第一次的：落库前再看一眼开关，关了就不存
            guard MemoryHealthStore.isOn(.extract) else {
                recordSkipped("开关关了")
                return .skipped
            }
            let added = try await write(batch.fragments)
            let finalNote = note(added: added, rejected: batch.rejected, fallback: fallbackNote, verified: batch.verified)
            MemoryHealthStore.recordOK(.extract, profileId: profileId, modelName: modelName,
                                       note: firstRejectionNote.map { "\($0) · \(finalNote)" } ?? finalNote, rejected: batch.rejected)
            return .done(added: added)
        } catch {
            guard recordFailure(error, profileId: profileId, modelName: modelName, note: firstRejectionNote) else {
                recordSkipped(error.localizedDescription)
                return .skipped
            }
            guard error is MemoryWriterError else { return .failed }
            return whole == nil ? .rejected : .held
        }
    }

    /// 一包没成：被打断 / 断网不算；开关关着不计（不红）；整包拒收（两次都不是合格 JSON）照记失败、日志记拒收 1——
    /// 连续 3 包状态卡那行就红（failStreak，astra 车头 #13），成功一包清零。返回 true = 记了失败
    @discardableResult
    static func recordFailure(_ error: Error, profileId: String, modelName: String,
                              note: String? = nil, rejected: Int? = nil) -> Bool {
        if case FragmentPoolError.interrupted = error { return false }
        if case FragmentPoolError.staleClaim = error { return false }
        guard !SessionCloseout.isTransient(error), MemoryHealthStore.isOn(.extract) else { return false }
        let message = note.map { "\($0) · \(error.localizedDescription)" } ?? error.localizedDescription
        MemoryHealthStore.recordError(.extract, profileId: profileId, message: message, modelName: modelName,
                                      rejected: rejected ?? (error is MemoryWriterError ? 1 : nil))
        return true
    }
}

// MARK: - 窗口触发（每满 N 条新消息，API / CC 共用一份水位；plan-memory-audit-desk 第三节）

/// 每个窗口记到哪条了（落盘 `mem_c2_marks`，最多 300 个窗口、超了扔最久没动的；第一次见到一个窗口先记下当前位置，不回头补，免得升级后把老对话重新过一遍）。
/// 她在对话 ⋯ 点「重新记这个窗口」= `rewind` 把这个窗口的水位挪回起点，之后照常一批一批认领（`FragmentRerecord`）。
/// 水位成功处理后才提交（astra #3）：`due` 只认领，跑完 `finish`——写成 / 合法空包 / 老写手整包拒收才提交，别的放回（10-16 astra #2）。
/// 整段写手整包拒收（`.held`）：放回，这个窗口冷却 `SessionCloseout.formatCooldown`（同 A2 格式失败那套：只在内存里），
/// 冷却里自动触发不认领、不调模型；过了再认领同一截。她手动「重新记」不看冷却。
/// 顺序认领（10-16 astra #1）：从水位之后取前 N 条，水位只推进到这一批末尾；积压超过 N 条分批，一次触发认领一批
/// （每轮回复落地都会再触发，积压几轮就追上；不在一次触发里连打几次模型）。
/// 每次认领带一个 token（10-16 astra #3）：提交 / 放回 / 写库前都要对上，超时作废的旧任务落不了库、动不了水位、也清不掉新任务的认领。
/// 同一个窗口同一时刻只认领一截（认领只在内存里）；快照里找不到水位、又比水位还旧 = 晚到的旧快照，不倒退、不重复提取（astra #4）
actor FragmentWatch {
    static let shared = FragmentWatch()
    /// 每满几条写一次（两边加起来），C2 二级页可调
    static let everyKey = "mem_c2_every"
    static let defaultEvery = 20
    static let everyRange = 6...40
    static let marksKey = "mem_c2_marks"
    static let maxMarks = 300
    /// 认领了这么久还没交回（本机模型卡死之类）就当丢了
    static let claimTimeout: TimeInterval = 15 * 60

    static func every(_ defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: everyKey)
        return v == 0 ? defaultEvery : min(max(v, everyRange.lowerBound), everyRange.upperBound)
    }

    // 整段写手（plan-c2-whole-span-writer）：攒得多才写得好（实测每批 80 条 78% 能用，200 条 95%），所以另用一个设置、默认大
    static let wholeEveryKey = "mem_c2_every_whole"
    static let defaultWholeEvery = FragmentPool.wholeDefaultEvery
    static let wholeEveryRange = 40...400
    /// 窗口放下后（静默够了 / 新开了对话）没写过的尾巴满这么多条也写一次——不然聊不到 N 条的窗口和每个窗口的最后一截永远不写（粟粟 11-12 定 10）
    static let wholeTailMinimum = FragmentPool.wholeTailMinimum
    /// 一次最多给模型多少字的新对话（超了剩下的下一轮再认领）
    static let wholeMaxChars = FragmentPool.wholeMaxChars
    /// 前文最多多少字
    static let wholeBeforeChars = FragmentPool.wholeBeforeChars
    /// 带给模型看的已记的卡最多几张（这个窗口出过的，新的在前）
    static let wholeKnownCards = FragmentPool.wholeKnownCards
    /// `classic` = 强制老写手；别的值 / 没设 = 整段写手
    static let writerKey = "mem_c2_writer"

    static func wholeEvery(_ defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: wholeEveryKey)
        return v == 0 ? defaultWholeEvery : min(max(v, wholeEveryRange.lowerBound), wholeEveryRange.upperBound)
    }

    /// 这一轮用不用整段写手：本机模型装不下整截、开关切回老的 → 老写手；别的都是整段写手。
    /// 和她存没存自定义提示词无关（粟粟 11-13「为啥存了会换写法」）：她改的整段提示词存 `FragmentPool.customWholePromptKey`，
    /// 存了照样是整段写手、只换那段话；旧 key（`customPromptKey`）里的老格式模板只在老写手这条路上生效
    static func usesWhole(local: Bool, defaults: UserDefaults = .standard) -> Bool {
        !local && defaults.string(forKey: writerKey) != "classic"
    }

    /// 前文：紧挨这一截之前的原文，从近往远数到字数上限
    static func before<T>(_ path: [T], upTo index: Int, size: (T) -> Int, maxChars: Int = wholeBeforeChars) -> ArraySlice<T> {
        FragmentPool.wholeBefore(path, upTo: index, size: size, maxChars: maxChars)
    }

    /// 认领到的一截：range = 路径里的下标；token = 这次认领的身份
    struct Claim: Equatable {
        let range: Range<Int>
        let token: UUID
    }

    private struct Mark {
        let id: String
        let date: Date?
    }

    /// 水位放在「第一条之前」（重新记、起点就是窗口第一条时）：没有哪条消息的 id 是空的
    static let headMark = ""

    private let defaults: UserDefaults
    private var watermark: [String: (mark: Mark, touched: Date)]
    private var inFlight: [String: (mark: Mark, at: Date, token: UUID)] = [:]
    /// 水位之后攒着还不够一批的：几条、最后一次看到是什么时候（收尾巴用）
    private var pending: [String: (count: Int, seen: Date)] = [:]
    /// 正在「重新记」、还没追上的窗口（落盘：预算用完 / 被掐断后再点是接着跑，不是又从起点来）
    private var redoing: Set<String> = []
    /// 窗口 → 冷却到什么时候（整段写手整包拒收）
    private var cooldown: [String: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [String: (mark: Mark, touched: Date)] = [:]
        for (cid, raw) in defaults.dictionary(forKey: Self.marksKey) ?? [:] {
            guard let d = raw as? [String: Any], let id = d["id"] as? String, let u = d["u"] as? Double else { continue }
            loaded[cid] = (Mark(id: id, date: (d["d"] as? Double).map(Date.init(timeIntervalSince1970:))), Date(timeIntervalSince1970: u))
            if let count = d["p"] as? Int, let seen = d["s"] as? Double { pending[cid] = (count, Date(timeIntervalSince1970: seen)) }
            if d["r"] as? Bool == true { redoing.insert(cid) }
        }
        watermark = loaded
    }

    /// 水位之后第一条的下标；水位不在这条路径上 = nil
    private func afterMark(_ mark: Mark, in pathIds: [String]) -> Int? {
        mark.id == Self.headMark ? 0 : pathIds.lastIndex(of: mark.id).map { $0 + 1 }
    }

    /// 重新记：把这个窗口的水位挪到 start 那条之前（start = 0 就是从头）。这个窗口正有一截在跑 = false，不动
    func rewind(conversationId: String, pathIds: [String], dates: [Date?], start: Int, now: Date = Date()) -> Bool {
        if let f = inFlight[conversationId], now.timeIntervalSince(f.at) < Self.claimTimeout { return false }
        inFlight[conversationId] = nil
        let before = start - 1
        redoing.insert(conversationId)
        setMark(pathIds.indices.contains(before) ? Mark(id: pathIds[before], date: dates.indices.contains(before) ? dates[before] : nil)
                                                 : Mark(id: Self.headMark, date: nil), for: conversationId, now: now)
        return true
    }

    /// 水位之后还有几条没写；没见过这个窗口 / 水位不在这条路径上 = nil
    func backlog(conversationId: String, pathIds: [String]) -> Int? {
        guard let mark = watermark[conversationId]?.mark, let after = afterMark(mark, in: pathIds) else { return nil }
        return pathIds.count - after
    }

    /// 这个窗口正有一截在跑（认领了还没交回、没超时）
    func claimed(conversationId: String, now: Date = Date()) -> Bool {
        inFlight[conversationId].map { now.timeIntervalSince($0.at) < Self.claimTimeout } ?? false
    }

    func isRedoing(conversationId: String) -> Bool { redoing.contains(conversationId) }

    /// 重新记追上了
    func endRedo(conversationId: String) {
        guard redoing.remove(conversationId) != nil else { return }
        save()
    }

    /// 放下了的窗口里尾巴够长的：攒了至少 minimum 条、最后一次看到已经过了 idle（新开对话时 idle 给 0）
    func tails(minimum: Int = FragmentWatch.wholeTailMinimum, idle: TimeInterval, except: Set<String> = [], now: Date = Date()) -> [String] {
        pending.filter { $0.value.count >= minimum && now.timeIntervalSince($0.value.seen) >= idle && !except.contains($0.key) && inFlight[$0.key] == nil
            && !cooling($0.key, now: now) }
            .map(\.key).sorted()
    }

    private func cooling(_ conversationId: String, now: Date) -> Bool {
        (cooldown[conversationId] ?? .distantPast) > now
    }

    /// 满 N 条新消息 → 认领水位之后的前 N 条；不够 / 第一次见 / 这个窗口正在跑 / 旧快照 / 冷却中 → nil。dates 和 pathIds 一一对应。
    /// threshold 不给 = 读设置 `mem_c2_every`
    /// sizes 给了 = 整段写手的认领：满 N 条时认领水位之后**全部**新消息，按 sizes（每条的字数）累计到 maxChars 为止（至少 N 条）
    /// manual = 她手动「重新记」：不看冷却
    func due(conversationId: String, pathIds: [String], dates: [Date?], threshold: Int? = nil,
             sizes: [Int]? = nil, maxChars: Int = FragmentWatch.wholeMaxChars, manual: Bool = false, now: Date = Date()) -> Claim? {
        guard let last = pathIds.last else { return nil }
        let n = threshold ?? Self.every(defaults)
        if let f = inFlight[conversationId], now.timeIntervalSince(f.at) < Self.claimTimeout { return nil }
        guard let mark = watermark[conversationId]?.mark else {
            setMark(Mark(id: last, date: dates.last ?? nil), for: conversationId, now: now)
            return nil
        }
        let range: Range<Int>
        if let after = afterMark(mark, in: pathIds) {
            let i = after - 1
            let fresh = pathIds.count - (i + 1)
            guard fresh >= n else {
                // 条数没变 = 这次不是新消息带来的（收尾巴扑空之类），不刷新「最后看到」
                if pending[conversationId]?.count != fresh {
                    pending[conversationId] = fresh > 0 ? (fresh, now) : nil
                    save()
                }
                return nil
            }
            var end = i + 1 + n
            if let sizes, sizes.count == pathIds.count {
                var used = sizes[(i + 1)..<end].reduce(0, +)
                while end < pathIds.count, used + sizes[end] <= maxChars {
                    used += sizes[end]
                    end += 1
                }
            }
            range = (i + 1)..<end
        } else {
            // 找不到水位：比水位还旧的快照（晚到）→ 不动；不然是切过分支 → 只看最后 N 条，水位挪到新分支最后一条（原语义不变）
            if let md = mark.date, let ld = dates.last ?? nil, ld <= md { return nil }
            guard pathIds.count >= n else { return nil }
            range = (pathIds.count - n)..<pathIds.count
        }
        // 冷却只拦整段写手的自动认领（老写手不带 sizes，照旧）
        guard manual || sizes == nil || !cooling(conversationId, now: now) else { return nil }
        let end = range.upperBound - 1
        let token = UUID()
        inFlight[conversationId] = (Mark(id: pathIds[end], date: dates.indices.contains(end) ? dates[end] : nil), now, token)
        return Claim(range: range, token: token)
    }

    private func setMark(_ mark: Mark, for conversationId: String, now: Date) {
        watermark[conversationId] = (mark, now)
        pending[conversationId] = nil
        if watermark.count > Self.maxMarks {
            let drop = watermark.sorted { $0.value.touched < $1.value.touched }.prefix(watermark.count - Self.maxMarks)
            for (cid, _) in drop { watermark[cid] = nil; pending[cid] = nil; redoing.remove(cid) }
        }
        save()
    }

    private func save() {
        var out: [String: [String: Any]] = [:]
        for (cid, v) in watermark {
            var d: [String: Any] = ["id": v.mark.id, "u": v.touched.timeIntervalSince1970]
            if let date = v.mark.date { d["d"] = date.timeIntervalSince1970 }
            if let p = pending[cid] { d["p"] = p.count; d["s"] = p.seen.timeIntervalSince1970 }
            if redoing.contains(cid) { d["r"] = true }
            out[cid] = d
        }
        defaults.set(out, forKey: Self.marksKey)
    }

    /// 这次认领还作数：token 对得上、没超时（写库前查一次）
    func holds(conversationId: String, token: UUID, now: Date = Date()) -> Bool {
        guard let f = inFlight[conversationId], f.token == token else { return false }
        return now.timeIntervalSince(f.at) < Self.claimTimeout
    }

    /// 这一截处理完了：水位挪到这一批最后一条。token 对不上不动；对得上但已超时 = 作废，只清认领、水位不动
    func commit(conversationId: String, token: UUID, now: Date = Date()) {
        guard let f = inFlight[conversationId], f.token == token else { return }
        inFlight[conversationId] = nil
        guard now.timeIntervalSince(f.at) < Self.claimTimeout else { return }
        cooldown[conversationId] = nil
        setMark(f.mark, for: conversationId, now: now)
    }

    /// 这一截没处理成：水位不动，下次再认领。token 对不上不动（清不掉别人的认领）
    func release(conversationId: String, token: UUID) {
        guard inFlight[conversationId]?.token == token else { return }
        inFlight[conversationId] = nil
    }

    /// 跑完一包按结果收尾（API / CC 同一规矩）：`outcome.settled` 才提交，别的放回；`.held` 放回后这个窗口进冷却
    func finish(conversationId: String, claim: Claim, outcome: FragmentPool.Outcome, now: Date = Date()) {
        if outcome.settled {
            commit(conversationId: conversationId, token: claim.token, now: now)
        } else {
            release(conversationId: conversationId, token: claim.token)
        }
        if outcome == .held { cooldown[conversationId] = now.addingTimeInterval(SessionCloseout.formatCooldown) }
    }
}
