import XCTest
import SwiftData
@testable import 记忆花园

/// AUTONOMY Phase 1 app 侧特征测试：config 默认全关（D6）/ outbox drain 幂等（uuid 查重）/ agentOrigin 落库。
final class AgentBridgeTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let floorId = "xctest-agent-floor"

    @MainActor
    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: Conversation.self, MessageNode.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    func testConfigDefaultsAllOff() {
        let cfg = AgentBridge.HubConfig()
        XCTAssertFalse(cfg.enabled, "总开关必须默认关（D6）")
        XCTAssertTrue(cfg.floors.isEmpty, "楼层开关必须默认全关（D6）")
        XCTAssertEqual(cfg.dailyBudgetUSD, 0.5, accuracy: 0.001)
    }

    /// 活雷防回归：app 保存配置不得抹掉 hub 侧手写的 model/apiKeyAccount
    func testSaveConfigPreservesHubFields() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // hub 手写：含 app 不认识的 model + apiKeyAccount
        let seed: [String: Any] = [
            "enabled": false, "dailyBudgetUSD": 0.5,
            "apiKeyAccount": "openrouter",
            "model": ["id": "google/gemini-3.1-flash-lite", "provider": "openrouter"],
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: tmp)

        // app 只改 enabled → 保存
        var cfg = AgentBridge.loadConfig(from: tmp)
        cfg.enabled = true
        cfg.floors["F1"] = true
        AgentBridge.saveConfig(cfg, to: tmp)

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as! [String: Any]
        XCTAssertEqual(after["enabled"] as? Bool, true, "app 管的键要更新")
        XCTAssertEqual((after["floors"] as? [String: Bool])?["F1"], true)
        XCTAssertEqual(after["apiKeyAccount"] as? String, "openrouter", "hub apiKeyAccount 不得被抹")
        XCTAssertEqual((after["model"] as? [String: Any])?["id"] as? String, "google/gemini-3.1-flash-lite", "hub model 不得被抹")
    }

    @MainActor
    private func makeConversation() -> Conversation {
        let conv = Conversation(id: "conv-1", title: "测试", createTime: Date(timeIntervalSinceNow: -100),
                                updateTime: Date(timeIntervalSinceNow: -50), currentNodeId: "root",
                                provider: "api", profileId: floorId)
        context.insert(conv)
        let root = MessageNode(id: "root", role: "user", content: "hi", contentType: "text",
                               createTime: Date(), parentId: nil, childrenIds: [],
                               conversationId: "conv-1", profileId: floorId)
        context.insert(root)
        try? context.save()
        return conv
    }

    @MainActor
    func testDrainInsertsPairOnceAndDeletesFile() throws {
        let conv = makeConversation()

        // 造 outbox 文件
        let outDir = AgentBridge.root.appendingPathComponent("outbox/\(floorId)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let uuid = UUID().uuidString
        let payload: [String: Any] = [
            "v": 1, "uuid": uuid, "triggerId": "t-test", "floorId": floorId,
            "createdAt": "2026-07-05T00:00:00Z", "userSeed": "（自主任务 · t-test）", "assistantText": "任务结果",
        ]
        let file = outDir.appendingPathComponent("2026-07-05-\(uuid).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        // 首次 drain：落一对消息 + 删文件
        XCTAssertEqual(AgentOutboxDrainer.drain(context: context), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "落库成功应删 outbox 文件")

        let pid = floorId
        let nodes = (try? context.fetch(FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.profileId == pid }
        ))) ?? []
        XCTAssertEqual(nodes.count, 3)   // root + user + assistant
        let agentNodes = nodes.filter { $0.agentOrigin == uuid }
        XCTAssertEqual(agentNodes.count, 2, "消息对都要带 agentOrigin")
        XCTAssertEqual(conv.unreadCount, 1)
        XCTAssertNotEqual(conv.currentNodeId, "root", "currentNodeId 应推进到 assistant")

        // 同 uuid 文件再来一次（模拟 crash 后重放）：查重兜底，不重复落库
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        XCTAssertEqual(AgentOutboxDrainer.drain(context: context), 0, "同 uuid 不得二次落库")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "查重命中也应删文件")
    }

    @MainActor
    func testDrainLeavesFileWhenFloorHasNoConversation() throws {
        let outDir = AgentBridge.root.appendingPathComponent("outbox/floor-없음-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let payload: [String: Any] = [
            "v": 1, "uuid": UUID().uuidString, "triggerId": "t", "floorId": outDir.lastPathComponent,
            "createdAt": "2026-07-05T00:00:00Z", "userSeed": "s", "assistantText": "a",
        ]
        let file = outDir.appendingPathComponent("f.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        XCTAssertEqual(AgentOutboxDrainer.drain(context: context), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "无落点应留文件等下次")
    }
}
