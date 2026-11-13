import MemoryCore
import SwiftData
import XCTest
@testable import 记忆花园

// E2-7 真机 live：A 线「窗口中间软删」走真实写侧路径（`mainPathNodesStrict` → `SessionCloseout.message`
// → A2 收尾 systemPrompt / userContent）→ Haiku 一发。软删那条与旁支各埋一个独特事实，主线埋另一个。
// TEST_RUNNER_MP_C3_LIVE_* 由 xcodebuild 转成宿主 MP_C3_LIVE_*；真实 key 只在出站时注入。
@MainActor
final class SessionCloseoutLiveSmokeTests: XCTestCase {
    private let convId = "closeout-live-云桥城"
    private let speakers = SessionSegmentWriter.Speakers(userName: "岚舟", assistantName: "星砚")
    private let persona = "这是全虚构的云桥城。你叫星砚，对方叫岚舟；林栖和雾岚是你们的朋友。"
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private var container: ModelContainer!
    private var context: ModelContext!
    private var defaults: UserDefaults?
    private var providers: ProviderManager?
    private var credentialId: String?
    private var profileId = ""

    override func setUp() async throws {
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "SessionCloseoutLiveSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 90
        profileId = "live-closeout-\(UUID().uuidString)"
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
    }

    /// 离线：主线 10 条（第 5 条软删）→ 写侧主路口径 9 条；软删 / 旁支事实不进 A2 收尾输入。
    /// 区分力：`seed` 的 `currentNodeId` 故意是旁支叶子（陈旧指针），`branchSelection` 指主线 ——
    /// `visiblePath` 按选择表走主线出 9 条；旧实现从 currentNodeId 沿 parentId 回走只给旁支那条链 + 祖先（4 条，含「铜铃」）。
    func testCloseoutInputDropsTrashedAndBranchMessages() async throws {
        let input = try await closeoutInput()
        XCTAssertEqual(input.messages.count, 9, "中间软删一条只少这一条，不切断主线")
        XCTAssertTrue(input.user.contains("第七根灯柱"), "主线事实必须进 A2 收尾输入")
        XCTAssertFalse(input.user.contains("青瓷坛"), "软删消息不得进 A2 收尾输入")
        XCTAssertFalse(input.user.contains("铜铃"), "旁支消息不得进 A2 收尾输入")
        XCTAssertFalse(input.system.contains("青瓷坛") || input.system.contains("铜铃"))
    }

    /// 有 key 才跑：真实路径拼出的 A2 收尾输入发 Haiku，合同校验 + 不得混入软删 / 旁支事实。
    func testCloseoutHaikuContractLive() async throws {
        guard let keyValue = getenv("MP_C3_LIVE_API_KEY"), !String(cString: keyValue).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_C3_LIVE_API_KEY，不访问真实端点")
        }
        guard let modelValue = getenv("MP_C3_LIVE_MODEL"), !String(cString: modelValue).isEmpty else {
            throw XCTSkip("必须注入 TEST_RUNNER_MP_C3_LIVE_MODEL，模型不写死")
        }
        let modelId = String(cString: modelValue)
        guard modelId.lowercased().contains("haiku") else {
            throw XCTSkip("收尾 live 只跑 Haiku，请注入 TEST_RUNNER_MP_C3_LIVE_MODEL")
        }
        CatalogLiveAuthProtocol.key = String(cString: keyValue)
        try CatalogLiveAuthProtocol.install()
        let (manager, model) = makeProvider(modelId: modelId)

        let input = try await closeoutInput()
        XCTAssertTrue(input.user.contains("第七根灯柱"), input.user)
        try await run(system: input.system, user: input.user, model: model, manager: manager) { raw in
            var problems = self.a2Problems(raw, closeout: true)
            let leaks = ["青瓷坛", "铜铃"].filter { raw.contains($0) }
            if !leaks.isEmpty { problems.append("混入软删/旁支事实：\(leaks.joined(separator: "、"))") }
            return problems
        }
    }

    // MARK: - 真实写侧路径

    /// 走生产收尾链路：`SessionCloseout.currentPath`（`visiblePath` 主线）→ `writeTail`
    /// （水位线 / 150 条上限 / `MemoryStartDay` / 按日或 60 条切段 / `previous`）→ `SessionSegmentWriter`。
    /// caller 截下真正要发的 system / user 后返回 nil，`writeTail` 立即短路（不落盘、不调模型）。
    /// 空库上这些前置状态都原样透传：没有窗口总结段（水位线 = 0、`previous = nil`）、
    /// `MemoryStartDay` 未设（`current == nil` → `firstAllowedIndex` = 0）、9 条同一天（一段）。
    private func closeoutInput() async throws -> (messages: [SessionSegmentWriter.Message], system: String, user: String) {
        let source = SwiftDataConversationSource(container: container)
        let path = try XCTUnwrap(SessionCloseout.currentPath(convId, profileId: profileId, source: source),
                                 "窗口必须在、且开着记忆")
        var captured: (system: String, user: String)?
        _ = try await SessionCloseout.writeTail(
            context: SessionSummary(conversationId: convId, title: path.title, compressedCount: 0, segments: [],
                                    updatedAt: .distantPast),
            messages: path.messages, notBefore: 0, persona: persona, speakers: speakers,
            profileId: profileId, title: path.title,
            save: { _ in XCTFail("caller 返回 nil 时不应落盘") },
            caller: { system, user in
                captured = (system, user)
                return nil
            })
        let sent = try XCTUnwrap(captured, "writeTail 必须先走到 caller")
        return (path.messages, sent.system, sent.user)
    }

    private func seed() throws {
        // 主线 10 条；第 5 条（下标 4）软删，埋「青瓷坛」；主线第 8 条埋「第七根灯柱」
        let texts = [
            "云桥城的雾还没散，我们先在石桥边等林栖。",
            "好，林栖说今天会带航图过来。",
            "航图收在灯塔那边，我们待会儿一起看。",
            "灯塔下风大，纸灯换成了琉璃灯。",
            "我把青瓷坛先放在灯塔第三层，回头再搬。",
            "嗯，搬的时候叫我，别一个人扛。",
            "岚舟说航图最后确认藏在第七根灯柱下面。",
            "第七根灯柱，我记下了，明天再去一趟。",
            "明天云桥城见，雾岚也会来。",
            "那就明天见。"
        ]
        let mainIds = (0..<texts.count).map { _ in UUID().uuidString }
        let branchId = UUID().uuidString
        for (index, id) in mainIds.enumerated() {
            var children: [String] = []
            if index + 1 < mainIds.count { children.append(mainIds[index + 1]) }
            if index == 2 { children.append(branchId) }
            let node = MessageNode(id: id, role: index.isMultiple(of: 2) ? "user" : "assistant",
                                   content: texts[index], contentType: "text",
                                   createTime: start.addingTimeInterval(Double(index) * 60),
                                   parentId: index == 0 ? nil : mainIds[index - 1], childrenIds: children,
                                   conversationId: convId, profileId: profileId)
            node.isTrashed = index == 4
            context.insert(node)
        }
        context.insert(MessageNode(id: branchId, role: "user", content: "我猜航图藏在铜铃下面的暗格里。",
                                   contentType: "text", createTime: start.addingTimeInterval(2 * 60 + 30),
                                   parentId: mainIds[2], childrenIds: [], conversationId: convId, profileId: profileId))
        let conv = Conversation(id: convId, title: "云桥城的航图", createTime: start,
                                updateTime: start.addingTimeInterval(9 * 60), currentNodeId: branchId,
                                provider: "api", profileId: profileId)
        // 陈旧指针：currentNodeId 指向旁支叶子，选择表仍指主线 —— 区分 `visiblePath`（按选择表走主线）
        // 与朴素 parentId 回走（只给旁支链 + 祖先，会把「铜铃」带进来）
        conv.memoryEnabled = true
        conv.lastRealChatAt = start.addingTimeInterval(9 * 60)
        conv.branchSelectionData = BranchSelection.encode([mainIds[2]: mainIds[3]])
        context.insert(conv)
        try context.save()
    }

    // MARK: - live 重试 / 合同（`a2Problems` = ALineLiveSmokeTests 的 a2Problems + `contractProblems(a3:false)` 合并内联，语义等价）

    private func run(system: String, user: String, model: ProviderModel, manager: ProviderManager,
                     problems: @escaping @MainActor (String) -> [String]) async throws {
        let caller = SessionSegmentWriter.modelCaller(model: model, providerManager: manager,
            conversationId: "", profileId: "", kind: .summary, checkWriteBudget: false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                var input = user
                for attempt in 1...2 {
                    let raw = try await caller(system, input) ?? ""
                    let failures = problems(raw)
                    print("[CLOSEOUT-LIVE] \(self.name) model=\(model.modelId) attempt=\(attempt) problems=\(failures)")
                    print("[CLOSEOUT-LIVE-RAW] \(CatalogLiveAuthProtocol.redacted(raw))")
                    if failures.isEmpty { return }
                    if attempt == 2 {
                        XCTFail("两次输出均未满足格式合同：\(failures.joined(separator: "；"))")
                        return
                    }
                    input = user + "\n\n（上次输出未满足格式合同：\(failures.joined(separator: "；"))。按原要求重新输出完整内容。）"
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func a2Problems(_ raw: String, closeout: Bool) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        var problems: [String] = []
        if !firstLine.hasPrefix("标题：") { problems.append("第一行必须为「标题：」") }
        let title = firstLine.dropFirst(3).trimmingCharacters(in: .whitespaces)
        if title.isEmpty || title.count > 15 { problems.append("标题为空或超长") }
        let marks = SessionSummaryStore.lineLayerMarks(text).map(\.mark)
        for mark in ["【经过】", "【原话】", "【关键词】", "【待续】"] where !marks.contains(mark) {
            problems.append("缺少行首\(mark)")
        }
        let output = SessionSegmentWriter.parse(text)
        if output.keywords.count > 5 { problems.append("关键词超量") }
        if text.contains("用户") { problems.append("出现「用户」") }
        if output.pending.isEmpty || output.pending == "无" { print("[CLOSEOUT-LIVE] \(name) soft: 【待续】不能为无") }
        if !output.pending.contains("图") && !output.pending.contains("云桥城") {
            print("[CLOSEOUT-LIVE] \(name) soft: 【待续】漏了图或云桥城")
        }
        if closeout && (output.story.hasPrefix("这个窗口") || output.title.hasPrefix("这个窗口")) {
            print("[CLOSEOUT-LIVE] \(name) soft: 尾段以「这个窗口」重新介绍窗口")
        }
        return problems
    }

    private func makeProvider(modelId: String) -> (ProviderManager, ProviderModel) {
        let id = "xctest-closeout-live-\(UUID().uuidString)"
        credentialId = id
        let baseURL = getenv("MP_C3_LIVE_BASE_URL").map { String(cString: $0) } ?? "https://api.anthropic.com/v1"
        let model = ProviderModel(credentialId: id, modelId: modelId, name: modelId)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        providers = manager
        manager.addCredential(APICredential(id: id, name: "云桥城收尾 live", emoji: "", type: .anthropic,
            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"], models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        return (manager, model)
    }
}
