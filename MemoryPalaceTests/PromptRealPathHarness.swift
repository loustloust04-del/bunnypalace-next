import XCTest
import SwiftData
@testable import 记忆花园

/// 实发 / 检查器同路径测试的共用夹具（plan-inspector-real-path §5）。
/// 内存库 + 指向 127.0.0.1:9 的卡（流式立刻失败、不发真请求）；会碰的真 UserDefaults 键全部存原值、tearDown 还原。
struct PromptScenario {
    var name: String
    var profileId = "xctest-prompt-golden-profile"
    var providerType: ProviderType = .openaiCompatible
    var memoryEnabled = true
    var cacheFriendly = false
    var anthropicBlacklisted = false
    var streamingMode: StreamingMode = .stream
    var healthWeightAskOnceAllowed = false
    var cardToolsSupported: Bool? = nil
    var voiceHint = true
    /// v4-1：楼层里放一份时间轴 + 一份上下文摘要（金样夹具）；主线程读盘预算那套量的是没有记忆文件的路径，关掉
    var memoryFixtures = true
}

@MainActor
final class PromptRealPathHarness {
    let context: ModelContext
    let viewModel: ConversationViewModel
    let providerManager: ProviderManager
    let model: ProviderModel
    let profile: Profile
    let preset: Preset
    private(set) var a2: MessageNode!
    private var credentialIds: [String] = []
    private var savedDefaults: [String: Any] = [:]
    private var absentDefaults: Set<String> = []
    private var budgetSnapshot: (enabled: Bool, isSet: Bool, budget: Double, spent: Double)?
    /// resetSpent 会把「已用从何时算起」挪到现在（账本校准按它算）；tearDown 放回原值
    private var savedSpentResetAt: Any?
    private var savedVoiceEnabled: (() -> Bool)?
    private var savedVoiceService: ((String) -> VoiceService?)?
    private var savedVoiceKey: ((String) -> String?)?
    private static let voiceServiceId = "xctest-voice-svc"
    private static let baseURL = "http://127.0.0.1:9"
    private static let spentResetAtKey = "globalSpentResetAt"
    /// 记忆夹具写下的文件 / 目录，tearDown 删
    private var fixtureFiles: [URL] = []

    private init(context: ModelContext, viewModel: ConversationViewModel, providerManager: ProviderManager,
                 model: ProviderModel, profile: Profile, preset: Preset) {
        self.context = context
        self.viewModel = viewModel
        self.providerManager = providerManager
        self.model = model
        self.profile = profile
        self.preset = preset
    }

    static func make(_ s: PromptScenario) async throws -> PromptRealPathHarness {
        // 文件清单缓存是进程级的：每个场景从干净的清单开始（前一个场景的附件已被删掉）
        FileLibraryStore.ListCache.forget(profileId: s.profileId)
        // #089〔状态〕第一行是「现在」：钉住时刻和时区（金样里有时区名，不随录制机器变）
        savedTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
        MemoryClock.fixedForTests = fixedNow
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let credentialId = "xctest-prompt-golden-\(UUID().uuidString)"
        let modelId = s.providerType == .anthropic ? "claude-sonnet-4-5" : "gpt-4o"
        let model = ProviderModel(credentialId: credentialId, modelId: modelId, name: "Prompt Golden")
        let providerManager = ProviderManager()
        var profile = Profile(id: s.profileId, name: "Test", emoji: "🧪", description: "",
                              userName: "User", assistantName: "Assistant")
        if s.voiceHint {
            profile.voiceServiceId = voiceServiceId
            profile.voiceId = "xctest-voice"
        }
        var preset = Preset.balanced
        preset.sampling.cacheFriendly = s.cacheFriendly
        if s.healthWeightAskOnceAllowed {
            preset.prompts.insert(PromptSlot(id: "xctest-health", name: "健康", role: "system", content: "健康：{{health}}",
                                             isSystemPrompt: false, injectionOrder: 5), at: 1)
        }
        let h = PromptRealPathHarness(context: context, viewModel: ConversationViewModel(), providerManager: providerManager,
                                      model: model, profile: profile, preset: preset)
        h.fixEnvironment(s)
        providerManager.addCredential(APICredential(id: credentialId, name: "Prompt Golden", emoji: "🧪",
                                                    type: s.providerType, baseURL: baseURL, models: [model],
                                                    toolsSupported: s.cardToolsSupported))
        providerManager.setApiKey("test-key", for: credentialId)
        h.credentialIds.append(credentialId)
        try await h.buildConversation(s)
        if s.memoryFixtures { try h.seedMemoryFixtures() }
        return h
    }

    /// 再加一张卡（P1 的 CC 卡），tearDown 一并删
    func addCard(type: ProviderType, modelId: String) -> ProviderModel {
        let id = "xctest-prompt-golden-\(UUID().uuidString)"
        let m = ProviderModel(credentialId: id, modelId: modelId, name: "Prompt Golden Extra")
        providerManager.addCredential(APICredential(id: id, name: "Prompt Golden Extra", emoji: "🧫",
                                                    type: type, baseURL: Self.baseURL, models: [m]))
        credentialIds.append(id)
        return m
    }

    /// 测试里临时改一个真 UserDefaults 键（tearDown 还原）
    func overrideDefault(_ key: String, _ value: Any?) {
        setDefault(key, value)
    }

    private func setDefault(_ key: String, _ value: Any?) {
        let d = UserDefaults.standard
        if savedDefaults[key] == nil, !absentDefaults.contains(key) {
            if let old = d.object(forKey: key) { savedDefaults[key] = old } else { absentDefaults.insert(key) }
        }
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
    }

    private func fixEnvironment(_ s: PromptScenario) {
        let store = GlobalBudgetStore.shared
        budgetSnapshot = (store.enabled, store.isBudgetSet, store.budgetUSD, store.spentUSD)
        savedSpentResetAt = UserDefaults.standard.object(forKey: Self.spentResetAtKey)
        store.setEnabled(true)
        store.setBudgetUSD(100)
        store.resetSpent()

        let bypass: Set<PermissionDomain> = [.toolsMaster, .fileLibrary, .images, .memory]
        for domain in PermissionDomain.allCases {
            let level: PermissionLevel = bypass.contains(domain) ? .bypass : .notAllowed
            setDefault(domain.storageKey, level.rawValue)
        }
        if s.healthWeightAskOnceAllowed {
            setDefault(PermissionDomain.healthWeight.storageKey, PermissionLevel.askOnce.rawValue)
        }
        setDefault("mem_master", true)
        setDefault("mem_content_summary", true)
        setDefault("mem_inject_keyword", false)
        setDefault("mem_inject_vector", false)
        setDefault("mem_inject_full", true)
        setDefault("mem_inject_graph", false)
        setDefault("mem_inject_catalog", false)
        setDefault("mem_inject_budget", nil)
        setDefault("maxImagesToModel", nil)
        setDefault("imageTranscriptionEnabled", nil)
        setDefault("fileLibraryInjectionTemplate", nil)
        setDefault(StreamingPreference.key, s.streamingMode.rawValue)
        setDefault(CardLibraryPreferences.worldBookTokenBudgetKey, nil)
        setDefault(CardLibraryPreferences.worldBookMaxEntriesKey, nil)
        setDefault("anthropicCacheHostBlacklist", s.anthropicBlacklisted ? [Self.baseURL] : nil)

        savedVoiceEnabled = VoiceMessageWriter.proactiveEnabledProvider
        savedVoiceService = VoiceMessageWriter.serviceProvider
        savedVoiceKey = VoiceMessageWriter.serviceKeyProvider
        VoiceMessageWriter.proactiveEnabledProvider = { s.voiceHint }
        // 楼层挂一个 ElevenLabs 服务（认标签 → 标签版文案）
        VoiceMessageWriter.serviceProvider = { id in
            id == Self.voiceServiceId ? VoiceService(id: id, name: "xctest", kind: .elevenLabs) : nil
        }
        VoiceMessageWriter.serviceKeyProvider = { _ in s.voiceHint ? "xctest-voice-key" : nil }
    }

    /// 历史 u1(带图)/a1/u2/a2 + 记忆 + 三本世界书 + 全局条目 + 文件夹说明 + 写作风格（+ 场景开关）
    private func buildConversation(_ s: PromptScenario) async throws {
        let vm = viewModel
        vm.startDraftConversation(profileId: profile.id)
        let conv = try XCTUnwrap(vm.selectedConversation)
        conv.memoryEnabled = s.memoryEnabled
        conv.selectedModelId = model.id
        conv.currentStyleId = WritingStyle.allBuiltin[0].id
        if s.healthWeightAskOnceAllowed {
            var grants = PermissionGrants(raw: nil)
            grants.record(.healthWeight, allow: true)
            conv.permGrantsRaw = grants.raw
            context.insert(WeightEntry(profileId: profile.id, date: Date(), weightKg: 52.0))
        }

        let tag = ConversationTag(name: "测试夹", profileId: profile.id)
        tag.instructions = "文件夹说明：回答尽量简短。"
        context.insert(tag)
        conv.folderId = tag.id

        func constant(_ text: String, order: Int) -> WorldBookEntry {
            var e = WorldBookEntry()
            e.isConstant = true
            e.content = text
            e.insertionOrder = order
            return e
        }
        let floorBook = WorldBook(name: "楼层书", profileId: profile.id, entries: [constant("楼层世界书：常驻条目。", order: 10)])
        let ownBook = WorldBook(name: "本对话书", profileId: profile.id, entries: [constant("本对话专属世界书条目。", order: 20)])
        ownBook.scopeConversationId = conv.id
        let otherBook = WorldBook(name: "别的对话书", profileId: profile.id, entries: [constant("别的对话专属条目（不该出现）。", order: 30)])
        otherBook.scopeConversationId = "xctest-other-conversation"
        [floorBook, ownBook, otherBook].forEach { context.insert($0) }
        vm.globalWorldBookEntries = [constant("全局世界书条目。", order: 40)]

        let m1 = Memory(content: "用户喜欢暖奶白配色", category: "preference", profileId: profile.id)
        m1.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let m2 = Memory(content: "用户养了一只叫团子的猫", category: "fact", profileId: profile.id)
        m2.createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        context.insert(m1)
        context.insert(m2)

        let img = try PendingChatAttachment.image(name: "a.jpg", typeDescription: "图片", mimeType: "image/jpeg",
                                                  data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]))
        XCTAssertTrue(vm.sendMessage("第一条", model: model, profile: profile, preset: preset,
                                     providerManager: providerManager, context: context, attachments: [img]))
        await waitForTurn()
        try XCTUnwrap(vm.currentPath.last { $0.role == "assistant" }).content = "回复一"
        XCTAssertTrue(vm.sendMessage("第二条", model: model, profile: profile, preset: preset,
                                     providerManager: providerManager, context: context))
        await waitForTurn()
        let a2 = try XCTUnwrap(vm.currentPath.last { $0.role == "assistant" })
        a2.content = "回复二"
        self.a2 = a2
        try context.save()
    }

    func waitForTurn(timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.assistantTurnInFlight, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 用「重新生成 a2」驱动实发，抓 provider 建好的 body
    func regenerateCapturingBody() async throws -> [String: Any] {
        var captured: [String: Any]?
        RequestBodyTap.handler = { captured = $0 }
        defer { RequestBodyTap.handler = nil }
        viewModel.regenerate(assistantNodeId: a2.id, model: model, profile: profile, preset: preset,
                             providerManager: providerManager, context: context)
        let deadline = Date().addingTimeInterval(5)
        while captured == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await waitForTurn()
        return try XCTUnwrap(captured, "实发没有建 body")
    }

    func tearDown() async {
        await waitForTurn()
        RequestBodyTap.handler = nil
        if let convId = viewModel.selectedConversation?.id {
            AttachmentStore.deleteConversationAttachments(conversationId: convId, profileId: profile.id)
        }
        credentialIds.forEach { providerManager.removeCredential(id: $0) }
        MemoryInjectionMeter.clear(profileId: profile.id)
        fixtureFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        MemoryClock.fixedForTests = nil
        if let tz = Self.savedTimeZone { NSTimeZone.default = tz }
        let d = UserDefaults.standard
        for (k, v) in savedDefaults { d.set(v, forKey: k) }
        for k in absentDefaults { d.removeObject(forKey: k) }
        if let v = savedVoiceEnabled { VoiceMessageWriter.proactiveEnabledProvider = v }
        if let v = savedVoiceService { VoiceMessageWriter.serviceProvider = v }
        if let v = savedVoiceKey { VoiceMessageWriter.serviceKeyProvider = v }
        if let b = budgetSnapshot {
            let store = GlobalBudgetStore.shared
            store.setEnabled(b.enabled)
            if b.isSet { store.setBudgetUSD(b.budget) } else { store.clearBudget() }
            store.resetSpent()
            store.commitSpend(b.spent)
            if let v = savedSpentResetAt { d.set(v, forKey: Self.spentResetAtKey) } else { d.removeObject(forKey: Self.spentResetAtKey) }
        }
    }

    // MARK: - 记忆夹具（v4-1 金样：时间轴 + 上下文摘要；覆盖别的窗口的条目、当前窗口还在窗口里的条目、一段收尾段）

    /// 金样钉住的「现在」：2026-10-11 12:00（本地），时间轴挑最近几条按它算（MemoryClock，只在测试进程里认）
    nonisolated(unsafe) static var savedTimeZone: TimeZone?

    static var fixedNow: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!
    }
    static let otherWindowId = "xctest-other-window-0001"
    static let goneNodeId = "xctest-node-out-of-window"

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// 时间轴 2026-10.md 四条：别的窗口两条（只有新的那条带待续）、本窗口一条原文已在窗口外（注）、本窗口一条 last 还在窗口里（不注）；
    /// 上下文摘要三段：一段压缩段（注）、一段老收尾段（不注）、一段最后一条还在窗口里（不注）
    func seedMemoryFixtures() throws {
        guard let conv = viewModel.selectedConversation else { return }
        let u2 = try XCTUnwrap(viewModel.currentPath.last { $0.role == "user" })
        MemoryClock.fixedForTests = Self.fixedNow
        let root = FileLibraryStore.memoryRoot(profileId: profile.id)
        let tl = TimelineStore.dir(root: root)
        func v2(_ day: String, _ conv: String, _ title: String, _ start: Date, _ end: Date, _ topics: [String], _ pending: String,
                _ last: String) -> TimelineEntry {
            TimelineEntry(start: start, end: end, conversationId: conv, title: title,
                          text: topics.map { "- \($0)" }.joined(separator: "\n"), pending: pending, day: day, lastNodeId: last)
        }
        try TimelineStore.write([
            v2("2026-10-08", Self.otherWindowId, "别的窗口", at(8, 20), at(8, 21), ["聊了团子的体检"], "旧待续：问体检结果", "other-1"),
            v2("2026-10-09", conv.id, "本窗口", at(9, 14), at(9, 15), ["本窗口早先聊的（原文已不在窗口里）"], "本窗口待续：周三复诊", Self.goneNodeId),
            v2("2026-10-10", Self.otherWindowId, "别的窗口", at(10, 9), at(10, 10), ["给团子买了猫粮", "停在挑罐头"], "周末问团子吃不吃", "other-2"),
            v2("2026-10-11", conv.id, "本窗口", at(11, 9), at(11, 10), ["本窗口刚聊的（原文还在窗口里，不该注入）"], "不该出现的待续", u2.id),
        ], month: "2026-10", in: tl)
        func seg(_ kind: SessionSegment.Kind, _ title: String, _ start: Date, _ last: String) -> SessionSegment {
            SessionSegment(kind: kind, title: title, start: start, end: start.addingTimeInterval(1800), from: 0, to: 2,
                           lastNodeId: last, story: "\(title)的经过", quotes: "User：「\(title)的原话」", pending: "")
        }
        try SessionSummaryStore.save(SessionSummary(conversationId: conv.id, title: "本窗口", compressedCount: 0, segments: [
            seg(.rolling, "挤出视野的一段", at(9, 14), Self.goneNodeId),
            seg(.closeout, "老收尾段（不该注入）", at(10, 20), "xctest-closeout-last"),
            seg(.rolling, "和窗口原文重叠的一段（不该注入）", at(11, 9), u2.id),
        ], updatedAt: at(11, 10)), profileId: profile.id)
        fixtureFiles = [tl.appendingPathComponent("2026-10.md"), SessionSummaryStore.dir(root: root)]
    }

    /// 排序键序列化；对话 id 前缀（文件库 hint 里附件目录名带它，每次运行随机）换成定值
    func canonical(_ body: [String: Any], droppingTools: Bool = false) throws -> String {
        var b = body
        if droppingTools { b.removeValue(forKey: "tools") }
        let data = try JSONSerialization.data(withJSONObject: b, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let text = String(decoding: data, as: UTF8.self)
        guard let convId = viewModel.selectedConversation?.id else { return text }
        return text.replacingOccurrences(of: String(convId.prefix(8)), with: "CONVID00")
    }
}
