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

    /// 落库：只加；一字不差的不加。出处 = 第几条消息（发生日按 05:00 日界）。返回新加了几条。
    /// 字段（importance 等）全部赋好后只存一次（10-16 astra #5：先存正文再补字段，中间被杀会留下认不出是 C2 的半成品）；
    /// 存不成就把这次插进去的撤掉再抛，免得没存的留在 context 里、下次重来被当成「一字不差」跳过
    @discardableResult
    static func write(_ fragments: [Fragment], messages: [Message], profileId: String, conversationId: String?,
                      extractedBy: String, store: MemoryStore, context: ModelContext) throws -> Int {
        guard !fragments.isEmpty else { return 0 }
        var contents = Set(store.listAll(profileId: profileId, context: context).map(\.content))
        var inserted: [Memory] = []
        for f in fragments {
            guard !contents.contains(f.content), messages.indices.contains(f.msg - 1) else { continue }
            let source = messages[f.msg - 1]
            let m = store.insertUnsaved(content: f.content, category: f.category, keywords: f.tags, profileId: profileId,
                                        isUserExplicit: false, extractedBy: extractedBy, sourceConversationId: conversationId,
                                        sourceQuote: nil, sourceNodeId: source.id, context: context)
            m.occurredDay = MemoryDay.key(source.date ?? Date())
            m.importance = f.importance
            m.emotion = f.emotion
            m.resolved = f.resolved
            m.validUntil = f.validUntil?.value.flatMap { validUntilDate($0) }
            m.subject = f.subject
            m.speaker = f.speaker
            contents.insert(f.content)
            inserted.append(m)
        }
        guard !inserted.isEmpty else { return 0 }
        do {
            try context.save()
        } catch {
            for m in inserted { context.delete(m) }
            throw error
        }
        return inserted.count
    }

    /// 日志那条：「记下 4 条 · 拒收 1 张（格式不对）」
    static func note(added: Int, rejected: Int, fallback: String?) -> String {
        var s = "记下 \(added) 条"
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
        /// 两次都不是合格 JSON，整包拒收（记了失败）：这一截不再重试
        case rejected
        /// 记了失败但没写成（请求出错 / 超时 / 落库失败）：这一截留着下次再来（10-16 astra #2）
        case failed

        /// 水位能不能提交（API / CC 同一规矩）：只有写成（含合法空包）或整包拒收；网络 / 存储失败一律放回
        var settled: Bool {
            switch self {
            case .done, .rejected: return true
            case .skipped, .failed: return false
            }
        }
    }

    /// 跑一包：调模型（前后复查开关，astra #1）→ 落库 → 记健康状态和日志
    static func process(_ messages: [Message], names: MemoryExtractor.Names, caller: @escaping SessionSegmentWriter.Caller,
                        local: Bool, profileId: String, modelName: String, fallbackNote: String?,
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
            guard let batch = try await run(messages, names: names, local: local, onFirstRejection: { count, reason in
                firstRejected = count
                firstRejectionNote = "首轮拒收 \(count) 张：\(reason)"
            }, caller: gated) else {
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
                return .rejected
            }
            let added = try await write(batch.fragments)
            let finalNote = note(added: added, rejected: batch.rejected, fallback: fallbackNote)
            MemoryHealthStore.recordOK(.extract, profileId: profileId, modelName: modelName,
                                       note: firstRejectionNote.map { "\($0) · \(finalNote)" } ?? finalNote, rejected: batch.rejected)
            return .done(added: added)
        } catch {
            guard recordFailure(error, profileId: profileId, modelName: modelName, note: firstRejectionNote) else {
                recordSkipped(error.localizedDescription)
                return .skipped
            }
            return error is MemoryWriterError ? .rejected : .failed
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
/// 水位成功处理后才提交（astra #3）：`due` 只认领，跑完 `finish`——写成 / 合法空包 / 整包拒收才提交，别的放回（10-16 astra #2）。
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

    /// 认领到的一截：range = 路径里的下标；token = 这次认领的身份
    struct Claim: Equatable {
        let range: Range<Int>
        let token: UUID
    }

    private struct Mark {
        let id: String
        let date: Date?
    }

    private let defaults: UserDefaults
    private var watermark: [String: (mark: Mark, touched: Date)]
    private var inFlight: [String: (mark: Mark, at: Date, token: UUID)] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [String: (mark: Mark, touched: Date)] = [:]
        for (cid, raw) in defaults.dictionary(forKey: Self.marksKey) ?? [:] {
            guard let d = raw as? [String: Any], let id = d["id"] as? String, let u = d["u"] as? Double else { continue }
            loaded[cid] = (Mark(id: id, date: (d["d"] as? Double).map(Date.init(timeIntervalSince1970:))), Date(timeIntervalSince1970: u))
        }
        watermark = loaded
    }

    /// 满 N 条新消息 → 认领水位之后的前 N 条；不够 / 第一次见 / 这个窗口正在跑 / 旧快照 → nil。dates 和 pathIds 一一对应。
    /// threshold 不给 = 读设置 `mem_c2_every`
    func due(conversationId: String, pathIds: [String], dates: [Date?], threshold: Int? = nil, now: Date = Date()) -> Claim? {
        guard let last = pathIds.last else { return nil }
        let n = threshold ?? Self.every(defaults)
        if let f = inFlight[conversationId], now.timeIntervalSince(f.at) < Self.claimTimeout { return nil }
        guard let mark = watermark[conversationId]?.mark else {
            setMark(Mark(id: last, date: dates.last ?? nil), for: conversationId, now: now)
            return nil
        }
        let range: Range<Int>
        if let i = pathIds.lastIndex(of: mark.id) {
            guard pathIds.count - (i + 1) >= n else { return nil }
            range = (i + 1)..<(i + 1 + n)
        } else {
            // 找不到水位：比水位还旧的快照（晚到）→ 不动；不然是切过分支 → 只看最后 N 条，水位挪到新分支最后一条（原语义不变）
            if let md = mark.date, let ld = dates.last ?? nil, ld <= md { return nil }
            guard pathIds.count >= n else { return nil }
            range = (pathIds.count - n)..<pathIds.count
        }
        let end = range.upperBound - 1
        let token = UUID()
        inFlight[conversationId] = (Mark(id: pathIds[end], date: dates.indices.contains(end) ? dates[end] : nil), now, token)
        return Claim(range: range, token: token)
    }

    private func setMark(_ mark: Mark, for conversationId: String, now: Date) {
        watermark[conversationId] = (mark, now)
        if watermark.count > Self.maxMarks {
            let drop = watermark.sorted { $0.value.touched < $1.value.touched }.prefix(watermark.count - Self.maxMarks)
            for (cid, _) in drop { watermark[cid] = nil }
        }
        var out: [String: [String: Any]] = [:]
        for (cid, v) in watermark {
            var d: [String: Any] = ["id": v.mark.id, "u": v.touched.timeIntervalSince1970]
            if let date = v.mark.date { d["d"] = date.timeIntervalSince1970 }
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
        setMark(f.mark, for: conversationId, now: now)
    }

    /// 这一截没处理成：水位不动，下次再认领。token 对不上不动（清不掉别人的认领）
    func release(conversationId: String, token: UUID) {
        guard inFlight[conversationId]?.token == token else { return }
        inFlight[conversationId] = nil
    }

    /// 跑完一包按结果收尾（API / CC 同一规矩）：`outcome.settled` 才提交，别的放回
    func finish(conversationId: String, claim: Claim, outcome: FragmentPool.Outcome, now: Date = Date()) {
        if outcome.settled {
            commit(conversationId: conversationId, token: claim.token, now: now)
        } else {
            release(conversationId: conversationId, token: claim.token)
        }
    }
}
