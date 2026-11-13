import MemoryCore
import SwiftData
import XCTest
@testable import 记忆花园

// E2-4 真机 live 冒烟：上个窗口纸条（虚构数据）→ systemPrompt → Haiku 一发。
// TEST_RUNNER_MP_C3_LIVE_* 由 xcodebuild 转成宿主 MP_C3_LIVE_*；真实 key 只在出站时注入。
@MainActor
final class PreviousWindowLiveSmokeTests: XCTestCase {
    private let sourceId = "src-星砚"
    private let sourceTitle = "云桥城的航图"
    private let targetId = "dst-新窗"
    private let question = "上次说航图藏在哪？只回地点，不要别的"
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private var container: ModelContainer!
    private var context: ModelContext!
    private var defaults: UserDefaults?
    private var providers: ProviderManager?
    private var credentialId: String?
    private var profileId = ""
    private var mainIds: [String] = []
    private var branchId = ""
    private var target: Conversation!

    override func setUp() async throws {
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "PreviousWindowLiveSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 90
        profileId = "live-prevwin-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: profileId))
        defaults?.set(true, forKey: "mem_master")
        container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        context = ModelContext(container)
        context.autosaveEnabled = false
        try seed()
    }

    override func tearDown() async throws {
        if let credentialId { providers?.removeCredential(id: credentialId) }
        providers = nil
        credentialId = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
        if !profileId.isEmpty { defaults?.removePersistentDomain(forName: profileId) }
        context = nil
        container = nil
        defaults = nil
        target = nil
    }

    func testFreezeRendersPreviousWindowIntoSystemPrompt() throws {
        let snapshot = try freezeAndValidate()
        XCTAssertEqual(target.previousWindowId, sourceId)
        XCTAssertEqual(snapshot.leafId, mainIds[7])
        XCTAssertEqual(snapshot.messages.map(\.nodeId), Array(mainIds.suffix(6)), "纸条必须是主线最后 N 条")
        XCTAssertTrue(snapshot.messages.contains { $0.text.contains("第七根灯柱") }, "主线事实必须进纸条")
        XCTAssertFalse(snapshot.messages.contains { $0.text.contains("钟楼顶") }, "旁支事实不得进纸条")

        let (systemPrompt, messages) = try systemPrompt(for: snapshot)
        XCTAssertTrue(systemPrompt.contains("[上一个窗口]"), systemPrompt)
        XCTAssertTrue(systemPrompt.contains(sourceTitle), systemPrompt)
        XCTAssertTrue(systemPrompt.contains("第七根灯柱"), systemPrompt)
        XCTAssertFalse(systemPrompt.contains("钟楼顶"), systemPrompt)
        XCTAssertTrue(messages.contains { $0.role == "user" && $0.content == question })
        XCTAssertFalse(messages.contains { $0.content.contains("[上一个窗口]") || $0.content.contains("第七根灯柱") },
                       "纸条只进 system，不变成对话消息")
    }

    /// E2-7b：生产入口（VM 登记 → 等落定 → 回写）与同步 freeze 逐字相等，纸条仍进 system
    func testViewModelFreezeRendersPreviousWindowOffline() async throws {
        let vm = ConversationViewModel()
        vm.freezePreviousWindow(target, context: context)
        XCTAssertTrue(vm.isFreezing(targetId), "VM 登记后处于冻结中")
        await vm.awaitPreviousWindowFreeze(targetId)
        XCTAssertFalse(vm.isFreezing(targetId))
        XCTAssertEqual(target.previousWindowId, sourceId)
        let asyncSnapshot = try XCTUnwrap(target.previousWindowSnapshot)

        let syncTarget = Conversation(id: "dst-同步对照", title: "航图之后", createTime: start.addingTimeInterval(600),
            updateTime: start.addingTimeInterval(600), currentNodeId: "", provider: "api", profileId: profileId)
        syncTarget.memoryEnabled = true
        context.insert(syncTarget)
        try context.save()
        PreviousWindowPicker.freeze(syncTarget, context: context, now: asyncSnapshot.capturedAt)
        XCTAssertEqual(asyncSnapshot, try XCTUnwrap(syncTarget.previousWindowSnapshot),
                       "VM 异步入口与同步 freeze 必须逐字相同")

        let (systemPrompt, _) = try systemPrompt(for: asyncSnapshot)
        XCTAssertTrue(systemPrompt.contains("[上一个窗口]"), systemPrompt)
        XCTAssertTrue(systemPrompt.contains(sourceTitle), systemPrompt)
    }

    func testPreviousWindowNoteReachesHaikuLive() async throws {
        guard let keyValue = getenv("MP_C3_LIVE_API_KEY"), !String(cString: keyValue).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_C3_LIVE_API_KEY，不访问真实端点")
        }
        guard let modelValue = getenv("MP_C3_LIVE_MODEL"), !String(cString: modelValue).isEmpty else {
            throw XCTSkip("必须注入 TEST_RUNNER_MP_C3_LIVE_MODEL，模型不写死")
        }
        let modelId = String(cString: modelValue)
        guard modelId.lowercased().contains("haiku") else {
            throw XCTSkip("上个窗口 live 只跑 Haiku，请注入 TEST_RUNNER_MP_C3_LIVE_MODEL")
        }
        CatalogLiveAuthProtocol.key = String(cString: keyValue)
        try CatalogLiveAuthProtocol.install()
        let (manager, model) = makeProvider(modelId: modelId)

        let snapshot = try freezeAndValidate()
        let (systemPrompt, _) = try systemPrompt(for: snapshot)
        XCTAssertTrue(systemPrompt.contains("第七根灯柱"), systemPrompt)
        let caller = SessionSegmentWriter.modelCaller(model: model, providerManager: manager,
            conversationId: "", profileId: "", kind: .summary, checkWriteBudget: false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                var last = ""
                for attempt in 1...2 {
                    let answer = (try await caller(systemPrompt, self.question) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    last = answer
                    let reached = answer.contains("灯柱") || answer.contains("第七")
                    print("[PREVWIN-LIVE] \(self.name) model=\(model.modelId) attempt=\(attempt) reached=\(reached)")
                    print("[PREVWIN-LIVE-RAW] \(CatalogLiveAuthProtocol.redacted(answer))")
                    if reached { return }
                }
                XCTFail("两次回答都没说出纸条里的地点；原文：\(CatalogLiveAuthProtocol.redacted(last))")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func seed() throws {
        mainIds = (0..<8).map { _ in UUID().uuidString }
        branchId = UUID().uuidString
        let texts = [
            "云桥城的早晨有点凉，我们先去看航图。",
            "好，林栖说航图收在灯塔那边。",
            "灯塔下面有很多灯柱，别记错。",
            "我记着，我们慢慢数。",
            "岚舟说航图藏在第七根灯柱下面。",
            "第七根灯柱，我记下了。",
            "那我们明天再去一趟。",
            "明天云桥城见。",
        ]
        for (index, id) in mainIds.enumerated() {
            let children: [String] = index == 3 ? [mainIds[4], branchId]
                : (index + 1 < mainIds.count ? [mainIds[index + 1]] : [])
            context.insert(MessageNode(id: id, role: index % 2 == 0 ? "user" : "assistant", content: texts[index],
                contentType: "text", createTime: start.addingTimeInterval(Double(index) * 60),
                parentId: index == 0 ? nil : mainIds[index - 1], childrenIds: children,
                conversationId: sourceId, profileId: profileId))
        }
        context.insert(MessageNode(id: branchId, role: "user", content: "我猜航图藏在钟楼顶。", contentType: "text",
            createTime: start.addingTimeInterval(3 * 60 + 30), parentId: mainIds[3], childrenIds: [],
            conversationId: sourceId, profileId: profileId))
        let source = Conversation(id: sourceId, title: sourceTitle, createTime: start,
            updateTime: start.addingTimeInterval(7 * 60), currentNodeId: mainIds[7],
            provider: "api", profileId: profileId)
        source.memoryEnabled = true
        source.lastRealChatAt = start.addingTimeInterval(7 * 60)
        source.branchSelectionData = BranchSelection.encode([mainIds[3]: mainIds[4]])
        context.insert(source)
        target = Conversation(id: targetId, title: "航图之后", createTime: start.addingTimeInterval(600),
            updateTime: start.addingTimeInterval(600), currentNodeId: "", provider: "api", profileId: profileId)
        target.memoryEnabled = true
        context.insert(target)
        try context.save()
    }

    private func freezeAndValidate() throws -> PreviousWindowSnapshot {
        PreviousWindowPicker.freeze(target, context: context)
        let snapshot = try XCTUnwrap(target.previousWindowSnapshot)
        let validated = PreviousWindowPicker.validate(snapshot, profileId: profileId, context: context)
        XCTAssertNil(validated.invalid)
        XCTAssertEqual(validated.messages.count, snapshot.messages.count)
        return validated
    }

    private func systemPrompt(for snapshot: PreviousWindowSnapshot) throws -> (String, [(role: String, content: String)]) {
        let profile = Profile(id: profileId, name: "云桥城", emoji: "", description: "",
                              userName: "岚舟", assistantName: "星砚")
        var inputs = MemoryInjector.RoundInputs(memories: [], selfMemory: nil, archiveBudget: 1_000,
                                                wiki: WikiInjectionSnapshot(pages: []))
        inputs.rootIndex = false
        inputs.previousWindow = snapshot
        let layers = RecallSelection.prepare(profile: profile, conversationId: targetId, turnId: "turn-live-1",
            branchAnchor: mainIds[7], text: question, state: RecallConversationState(), existingDecision: nil,
            inputs: inputs, recentMessages: [], now: start.addingTimeInterval(3600),
            tuning: RecallTuning.defaults).layers
        XCTAssertTrue(layers.stable.contains("[上一个窗口]"), layers.stable)
        let assembled = PromptAssembler.assembleTagged(preset: .balanced, profile: profile, memories: [],
            chatHistory: [("user", question)], recallLayers: layers)
        let legacy = PromptMessage.legacyShape(PromptAssembler.orderedMessages(from: assembled.segments))
        return (try XCTUnwrap(legacy.systemPrompt), legacy.messages)
    }

    private func makeProvider(modelId: String) -> (ProviderManager, ProviderModel) {
        let id = "xctest-prevwin-live-\(UUID().uuidString)"
        credentialId = id
        let baseURL = getenv("MP_C3_LIVE_BASE_URL").map { String(cString: $0) } ?? "https://api.anthropic.com/v1"
        let model = ProviderModel(credentialId: id, modelId: modelId, name: modelId)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        providers = manager
        manager.addCredential(APICredential(id: id, name: "上一个窗口 live", emoji: "", type: .anthropic,
            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"], models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        return (manager, model)
    }
}
