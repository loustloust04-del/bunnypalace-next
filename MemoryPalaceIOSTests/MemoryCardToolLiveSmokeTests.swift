import SwiftData
import XCTest
@testable import 记忆花园

/// 助手动记忆条目 `memory_card` 的真调模型冒烟：只证明这条路存在、跑得通（不看写得好不好）。全虚构的皮影作坊。
/// 走聊天页那条真路：`ConversationViewModel.sendMessage` → 模型自己调 `memory_card` → 工具循环头的「记忆条目」权限闸 →
/// `MemoryCardTool.execute` 落库 → 审计日志。五步：
///   1 自动允许：加一张，不问；
///   2 每次询问 + 拒绝：改不动，卡没变、没记日志；
///   3 每次询问 + 允许这一次：改成了；一笔一问，不往对话授权里记；
///   4 不允许：这一轮不给这个工具，卡没变；
///   5 自动允许：删一张（进 Deleted），再 Undo 那一笔放回来。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里换进请求头；模型默认 Haiku（TEST_RUNNER_MP_STREAM_LIVE_MODEL 可换）。
/// 日志只打布尔 / 计数 / 这几张虚构卡的正文，不打请求体
@MainActor
final class MemoryCardToolLiveSmokeTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialId: String?
    private var permSuite: String?
    private var previousPermDefaults: UserDefaults?
    private var floorToRemove: String?

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "MemoryCardToolLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 900
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = "api.anthropic.com"
        try CatalogLiveAuthProtocol.install()
        // 档位换到一次性 suite，不碰宿主的 perm.*
        let suite = "xctest-memory-card-live-\(UUID().uuidString)"
        permSuite = suite
        previousPermDefaults = PermissionCenter.defaults
        PermissionCenter.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        if let credentialId { manager?.removeCredential(id: credentialId) }
        manager = nil
        credentialId = nil
        CatalogLiveAuthProtocol.onOutgoingBody = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
        if let previousPermDefaults { PermissionCenter.defaults = previousPermDefaults }
        previousPermDefaults = nil
        if let permSuite { UserDefaults(suiteName: permSuite)?.removePersistentDomain(forName: permSuite) }
        permSuite = nil
        if let floorToRemove {
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: floorToRemove).deletingLastPathComponent())
        }
        floorToRemove = nil
    }

    private struct Turn {
        /// 这一轮「记忆条目」问了几次
        var asked = 0
        /// 询问卡上有没有出现「本对话都允许」（一笔一问不该有）
        var grantOffered = false
        /// 这一轮发出去的请求里，有几个带着 memory_card 这个工具
        var requestsWithTool = 0
        var requests = 0
        var finished = false
    }

    func testAssistantAddsEditsDeletesCardsAcrossThreePermissionLevels() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let providers = ProviderManager()
        manager = providers
        let id = "xctest-memory-card-live-\(UUID().uuidString)"
        credentialId = id
        let modelName = getenv("MP_STREAM_LIVE_MODEL").map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "claude-haiku-5-5"
        let model = ProviderModel(credentialId: id, modelId: modelName, name: modelName)
        providers.addCredential(APICredential(id: id, name: "记忆条目 live", emoji: "", type: .anthropic,
                                              baseURL: "https://api.anthropic.com/v1", extraHeaders: ["anthropic-version": "2023-06-01"],
                                              models: [model], toolsSupported: true))
        providers.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

        let profile = Profile(id: "xctest-memory-card-live-\(UUID().uuidString)", name: "记忆条目 live", emoji: "", description: "",
                              userName: "岚舟", assistantName: "星砚")
        floorToRemove = profile.id
        let pid = profile.id
        let memoryRoot = FileLibraryStore.memoryRoot(profileId: pid)

        // 只开工具总开关，别的域都关：这一轮模型手上只有记忆条目（和常开的那几个小工具）
        func setLevel(_ level: PermissionLevel) {
            for d in PermissionDomain.allCases { PermissionCenter.setDefaultLevel(d == .toolsMaster ? .bypass : .notAllowed, for: d) }
            PermissionCenter.setDefaultLevel(level, for: .memoryCards)
        }
        func toolCards() -> [Memory] {
            SwiftDataMemoryStore().listAll(profileId: pid, context: context).filter { $0.extractedBy == MemoryCardTool.toolName }
        }
        func log() -> [MemoryAuditLog.Entry] { MemoryAuditLog.load(memoryRoot: memoryRoot).filter { $0.actor == "星砚" } }

        let vm = ConversationViewModel()
        vm.startDraftConversation(profileId: pid)

        func send(_ text: String, answer: PermissionPromptCenter.Decision) async throws -> Turn {
            var turn = Turn()
            CatalogLiveAuthProtocol.onOutgoingBody = { body in
                turn.requests += 1
                if Self.toolNames(body).contains(MemoryCardTool.toolName) { turn.requestsWithTool += 1 }
            }
            XCTAssertTrue(vm.sendMessage(text, model: model, profile: profile, preset: Preset.balanced, providerManager: providers, context: context))
            let deadline = Date().addingTimeInterval(180)
            while vm.assistantTurnInFlight, Date() < deadline {
                if let request = PermissionPromptCenter.shared.pendingRequest, request.domain == .memoryCards {
                    turn.asked += 1
                    if request.approval?.conversationGrant == true { turn.grantOffered = true }
                    PermissionPromptCenter.shared.respond(to: request.id, decision: answer)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            turn.finished = !vm.assistantTurnInFlight
            CatalogLiveAuthProtocol.onOutgoingBody = nil
            return turn
        }
        func report(_ step: String, _ turn: Turn) {
            print("[CARD-LIVE] \(step) finished=\(turn.finished) asked=\(turn.asked) grantOffered=\(turn.grantOffered) requests=\(turn.requests) withTool=\(turn.requestsWithTool) cards=\(toolCards().map { "\($0.supersededAt == nil ? "live" : "deleted")：\($0.content)" }) log=\(log().map { $0.action.rawValue })")
        }

        // 1 自动允许：加一张
        setLevel(.bypass)
        let added = try await send("请用 memory_card 工具新加一张记忆条目，正文是「岚舟每周三去槐序巷皮影作坊学雕皮影。」，说的是岚舟。只做这一件事，做完告诉我。", answer: .deniedOnce)
        report("1 自动允许·加", added)
        XCTAssertTrue(added.finished, "这一轮要跑完")
        XCTAssertEqual(added.asked, 0, "自动允许不问")
        XCTAssertGreaterThan(added.requestsWithTool, 0, "请求里带着 memory_card")
        let card = try XCTUnwrap(toolCards().first { $0.content.contains("皮影") }, "助手真的加了一张")
        XCTAssertNil(card.supersededAt)
        XCTAssertNotNil(card.reviewedAt, "允许过才落的库，算批过")
        XCTAssertNil(card.userEditedAt, "不算她亲手改的")
        let addEntry = try XCTUnwrap(log().first { $0.action == .add }, "加的那一笔进了日志，操作人是助手")
        XCTAssertEqual(addEntry.via, MemoryAuditLog.viaChat)
        XCTAssertTrue(addEntry.items.contains { $0.card == card.id })
        let short = MemoryCardTool.short(card.id)
        let original = card.content

        // 2 每次询问 + 拒绝：改不动
        setLevel(.askOnce)
        let refused = try await send("用 memory_card 把 id 是 \(short) 的那张卡改一下：把「周三」改成「周五」，别的不动。", answer: .deniedOnce)
        report("2 每次询问·拒绝", refused)
        XCTAssertGreaterThan(refused.asked, 0, "每次询问要出卡")
        XCTAssertFalse(refused.grantOffered, "一笔一问，卡上没有「本对话都允许」")
        XCTAssertEqual(card.content, original, "拒绝了就不动")
        XCTAssertFalse(log().contains { $0.action == .edit }, "没动成的不记")

        // 3 每次询问 + 允许这一次：改成了，但不往对话授权里记
        let allowed = try await send("这次我会点允许。再用 memory_card 改一次 id 是 \(short) 的那张：把「周三」改成「周五」。", answer: .allowedOnce)
        report("3 每次询问·允许", allowed)
        XCTAssertGreaterThan(allowed.asked, 0, "上一轮点过拒绝 / 这一轮点过允许，都不省掉下一次询问")
        XCTAssertTrue(card.content.contains("周五"), "允许了才生效：\(card.content)")
        XCTAssertNil(card.userEditedAt)
        XCTAssertTrue(log().contains { $0.action == .edit && $0.items.contains { $0.card == card.id } })
        XCTAssertFalse((vm.selectedConversation?.permGrantsRaw ?? "").contains(PermissionDomain.memoryCards.rawValue), "不记对话授权")
        let edited = card.content

        // 4 不允许：这一轮不给这个工具
        setLevel(.notAllowed)
        let entriesBefore = log().count
        let blocked = try await send("用 memory_card 把 id 是 \(short) 的那张卡删掉。", answer: .allowedOnce)
        report("4 不允许", blocked)
        XCTAssertEqual(blocked.requestsWithTool, 0, "不允许 = 请求里没有 memory_card")
        XCTAssertEqual(blocked.asked, 0)
        XCTAssertNil(card.supersededAt, "卡没被动")
        XCTAssertEqual(card.content, edited)
        XCTAssertEqual(log().count, entriesBefore)

        // 5 自动允许：删（进 Deleted），再撤回那一笔
        setLevel(.bypass)
        let deleted = try await send("现在可以了。用 memory_card 把 id 是 \(short) 的那张卡删掉。", answer: .deniedOnce)
        report("5 自动允许·删", deleted)
        XCTAssertEqual(deleted.asked, 0)
        XCTAssertNotNil(card.supersededAt, "删 = 进 Deleted，不出库")
        let deleteEntry = try XCTUnwrap(log().first { $0.action == .delete && $0.items.contains { $0.card == card.id } })
        XCTAssertTrue(MemoryAuditLog.canUndo(deleteEntry, in: MemoryAuditLog.load(memoryRoot: memoryRoot)))
        let undone = MemoryAuditLog.undo(deleteEntry, profileId: pid, context: context)
        try context.save()
        XCTAssertEqual(undone.restored, 1, "Undo 能回")
        XCTAssertNil(card.supersededAt)
        XCTAssertEqual(card.content, edited)

        // 文件库 › 记忆 › 记忆条目 里有这张；审计日志那份看得懂的页里有助手的每一笔
        let entry = try XCTUnwrap(MemoryCardFolder.entries(profileId: pid, context: context).first { $0.card == card.id })
        XCTAssertTrue(entry.path.hasPrefix(MemoryCardFolder.root + "/"), entry.path)
        let page = MemoryLogFolder.auditText(MemoryAuditLog.load(memoryRoot: memoryRoot))
        for word in ["星砚 · Add 1 · 聊天", "星砚 · Edit 1 · 聊天", "星砚 · Delete 1 · 聊天"] { XCTAssertTrue(page.contains(word), word) }
        print("[CARD-LIVE] done model=\(modelName) entry=\(entry.path) log=\(log().count)")
    }

    private static func toolNames(_ body: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tools = json["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { $0["name"] as? String }
    }
}
