import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// CC 里的助手经 hub 用花园的记忆：`memory_cmd` 帧 → 那场对话所在的楼层跑聊天里同一个工具、过同一个闸 → `memory_result`。全虚构
@MainActor
final class MemoryCCBridgeTests: XCTestCase {
    // 楼层目录名取 id 的前 8 个字母数字：两层的开头要不一样，也别和别的测试撞
    private let floorA = "ccbmema-xctest"
    private let floorB = "ccbmemb-xctest"
    private var container: ModelContainer!
    private var context: ModelContext!
    private var profiles: [Profile] = []
    private var saved: [String: Any] = [:]
    private var libraryRoot: URL!
    private var previousLibraryRoot: URL?
    private var keys: [String] {
        ["mem_master", "mem_content_timeline", PermissionDomain.memoryCards.storageKey, PermissionDomain.memoryCards.legacy.key, PermissionCenter.floorsKey]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        saved = [:]
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) { saved[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
        UserDefaults.standard.set(true, forKey: "mem_master")
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mem-ccb-\(UUID().uuidString)")
        previousLibraryRoot = FileLibraryStore.testRootOverride
        FileLibraryStore.testRootOverride = libraryRoot
        container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        context = ModelContext(container)
        profiles = [
            Profile(id: floorA, name: "A 楼", emoji: "🌿", description: "", userName: "岚舟", assistantName: "阿栎"),
            Profile(id: floorB, name: "B 楼", emoji: "🌸", description: "", userName: "岚舟", assistantName: "星砚"),
        ]
        context.insert(Conversation(id: "chat-b", title: "B 的 CC 窗口", createTime: .now, updateTime: .now, currentNodeId: "", profileId: floorB))
        context.insert(Conversation(id: "chat-b2", title: "B 的另一个窗口", createTime: .now, updateTime: .now, currentNodeId: "", profileId: floorB))
        try context.save()
    }

    override func tearDownWithError() throws {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) }
        for pid in [floorA, floorB] {
            PendingStore.forget(profileId: pid)
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        }
        FileLibraryStore.testRootOverride = previousLibraryRoot
        if let libraryRoot { try? FileManager.default.removeItem(at: libraryRoot) }
        context = nil; container = nil
        try super.tearDownWithError()
    }

    /// 没人该被问到的地方用它：真问了就是错
    private let neverAsk: PermissionGate.Ask = { _, _, _ in XCTFail("这一档不该出询问卡"); return .deniedOnce }

    private func send(_ tool: String, _ input: [String: Any], chatId: String? = "chat-b", timeoutMs: Int? = nil,
                      ask: PermissionGate.Ask? = nil) async -> [String: Any] {
        var frame: [String: Any] = ["type": "memory_cmd", "id": "req-1", "tool": tool, "input": input]
        if let chatId { frame["chat_id"] = chatId }
        if let timeoutMs { frame["timeout_ms"] = timeoutMs }
        return await MemoryCCBridge.handle(frame, profiles: profiles, context: context, ask: ask ?? neverAsk)
    }

    private func text(_ r: [String: Any]) -> String { r["result"] as? String ?? "" }
    private func cards(_ pid: String) -> [Memory] { SwiftDataMemoryStore().listAll(profileId: pid, context: context) }
    private func log(_ pid: String) -> [MemoryAuditLog.Entry] { MemoryAuditLog.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) }
    private func allow() { PermissionCenter.setFloorLevel(.bypass, for: .memoryCards, profileId: floorB) }

    // MARK: - 记忆条目：楼层、留痕、撤回

    func testCardLandsOnTheChatsFloorAndIsLoggedAsCC() async throws {
        allow()
        let r = await send("memory_card", ["action": "add", "content": "岚舟每周三去槐序巷皮影作坊学雕皮影。", "subject": "岚舟", "reason": "从旧笔记搬过来"])
        XCTAssertEqual(r["type"] as? String, "memory_result")
        XCTAssertEqual(r["id"] as? String, "req-1", "回包带原 id，hub 才能对上等着的请求")
        XCTAssertEqual(r["ok"] as? Bool, true, text(r))
        XCTAssertTrue(text(r).contains("「B 楼」这一层"), text(r))
        XCTAssertTrue(cards(floorA).isEmpty, "没写到别的楼")
        let m = try XCTUnwrap(cards(floorB).first)
        XCTAssertEqual(m.sourceConversationId, "chat-b")

        let entry = try XCTUnwrap(log(floorB).first)
        XCTAssertEqual(entry.actor, "CC 里的星砚")
        XCTAssertEqual(entry.via, MemoryAuditLog.viaCC)
        XCTAssertEqual(entry.action, .add)
        XCTAssertEqual(entry.note, "从旧笔记搬过来")
        XCTAssertTrue(log(floorA).isEmpty)

        XCTAssertTrue(MemoryAuditLog.canUndo(entry, in: log(floorB)))
        XCTAssertEqual(MemoryAuditLog.undo(entry, profileId: floorB, context: context).restored, 1)
        XCTAssertNotNil(m.supersededAt, "她在记忆日志里撤得回 CC 写的这一笔")
    }

    func testEditPinDeleteGoThroughTheSameTool() async throws {
        allow()
        _ = await send("memory_card", ["action": "add", "content": "星砚答应帮岚舟刻一只纸鸢。"])
        let m = try XCTUnwrap(cards(floorB).first)
        let id = MemoryCardTool.short(m.id)
        let pinned = await send("memory_card", ["action": "pin", "id": id])
        XCTAssertEqual(pinned["ok"] as? Bool, true, text(pinned))
        XCTAssertTrue(m.isUserExplicit)
        let edited = await send("memory_card", ["action": "edit", "id": id, "content": "星砚答应帮岚舟刻两只纸鸢。"])
        XCTAssertEqual(edited["ok"] as? Bool, true, text(edited))
        XCTAssertEqual(m.content, "星砚答应帮岚舟刻两只纸鸢。")
        let deleted = await send("memory_card", ["action": "delete", "id": id])
        XCTAssertEqual(deleted["ok"] as? Bool, true, text(deleted))
        XCTAssertNotNil(m.supersededAt)
        XCTAssertEqual(log(floorB).map(\.actor), Array(repeating: "CC 里的星砚", count: 4))
    }

    // MARK: - 三档

    func testNotAllowedIsRefusedWithoutAsking() async {
        PermissionCenter.setFloorLevel(.notAllowed, for: .memoryCards, profileId: floorB)
        let r = await send("memory_card", ["action": "add", "content": "岚舟怕打雷。"])
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertTrue(text(r).hasPrefix("permission_denied：用户未允许「C2 记忆条目」"), text(r))
        XCTAssertTrue(cards(floorB).isEmpty)
        XCTAssertTrue(log(floorB).isEmpty)
    }

    func testAskEveryCallUsesTheChatApprovalAndObeysTheAnswer() async throws {
        XCTAssertEqual(PermissionCenter.level(.memoryCards, profileId: floorB), .askOnce, "默认档")
        var asked: [PermissionPromptCenter.Approval] = []
        let yes: PermissionGate.Ask = { domain, _, approval in
            XCTAssertEqual(domain, .memoryCards)
            asked.append(approval)
            return .allowedOnce
        }
        let ok = await send("memory_card", ["action": "add", "content": "岚舟怕打雷。"], ask: yes)
        XCTAssertEqual(ok["ok"] as? Bool, true, text(ok))
        XCTAssertEqual(cards(floorB).count, 1)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.conversationId, "chat-b", "卡出在那场 CC 对话里")
        XCTAssertEqual(asked.first?.toolName, MemoryCardTool.toolName)
        XCTAssertEqual(asked.first?.conversationGrant, false, "一笔一问，没有「本对话都允许」")

        _ = await send("memory_card", ["action": "add", "content": "岚舟爱喝桂花酿。"], ask: yes)
        XCTAssertEqual(asked.count, 2, "第二笔照样问")

        let no = await send("memory_card", ["action": "add", "content": "岚舟住在云桥城。"], ask: { _, _, _ in .deniedOnce })
        XCTAssertEqual(no["ok"] as? Bool, false)
        XCTAssertTrue(text(no).contains("拒绝"), text(no))
        XCTAssertEqual(cards(floorB).count, 2, "被拒的没写")
        let conv = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == "chat-b" })
        XCTAssertFalse(PermissionGrants(raw: conv.permGrantsRaw).isResolved(.memoryCards), "不往对话授权里记")
    }

    /// 她一直没点：这边先于 hub 的时限收口，卡撤掉、不写，CC 拿到的是「超时未执行」而不是之后又悄悄写进去
    func testAskGivesUpBeforeTheHubDoes() async {
        let center = PermissionPromptCenter(isolatedForTesting: true)
        let budgetMs = Int((MemoryCCBridge.transportMargin + 1) * 1000)
        let r = await send("memory_card", ["action": "add", "content": "岚舟怕打雷。"], timeoutMs: budgetMs,
                           ask: { await center.decide($0, detail: $1, approval: $2) })
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertTrue(text(r).contains("超时"), text(r))
        XCTAssertNil(center.pendingRequest, "挂着的卡收掉了")
        XCTAssertTrue(cards(floorB).isEmpty)
    }

    // MARK: - 楼层要明确、开关照旧

    func testChatIdIsRequiredAndMustExistHere() async {
        allow()
        let none = await send("memory_card", ["action": "add", "content": "岚舟怕打雷。"], chatId: nil)
        XCTAssertEqual(none["ok"] as? Bool, false)
        XCTAssertTrue(text(none).contains("chat_id"), text(none))
        let unknown = await send("memory_card", ["action": "add", "content": "岚舟怕打雷。"], chatId: "chat-nowhere")
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        XCTAssertTrue(text(unknown).contains("找不到"), text(unknown))
        XCTAssertTrue(cards(floorA).isEmpty && cards(floorB).isEmpty, "不猜楼层")
    }

    func testMemorySwitchesStillApply() async throws {
        allow()
        let conv = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == "chat-b" })
        conv.memoryEnabled = false
        try context.save()
        let off = await send("memory_card", ["action": "add", "content": "岚舟怕打雷。"])
        XCTAssertEqual(off["ok"] as? Bool, false)
        XCTAssertTrue(text(off).contains("关了记忆参与"), text(off))
        let remember = await send("remember", ["name": "怕打雷", "description": "岚舟怕打雷", "body": "岚舟说「我怕打雷」。", "asked_by_user": true])
        XCTAssertEqual(remember["ok"] as? Bool, false)

        conv.memoryEnabled = true
        try context.save()
        UserDefaults.standard.set(false, forKey: "mem_master")
        let master = await send("memory_card", ["action": "add", "content": "岚舟怕打雷。"])
        XCTAssertEqual(master["ok"] as? Bool, false)
        XCTAssertTrue(text(master).contains("没开"), text(master))
        XCTAssertTrue(cards(floorB).isEmpty)
    }

    func testOnlyMemoryToolsAndBadArgumentsAreRefused() async {
        allow()
        let other = await send("run_command", ["command": "ls"])
        XCTAssertEqual(other["ok"] as? Bool, false, "不在清单里的工具不执行")
        let write = await send("fs_write", ["path": "notes/todo.md", "content": "x"])
        XCTAssertEqual(write["ok"] as? Bool, false, "文件工具在 CC 这头只碰 memory/ 和 Prompt 文件夹（写 memory/ 见 MemoryFolderWriteTests）")
        XCTAssertTrue(text(write).contains("memory/"), text(write))
        let missing = await send("remember", ["name": "只有标题"])
        XCTAssertEqual(missing["ok"] as? Bool, false, "缺必填参数：和聊天里同一道预检")
        let outside = await send("fs_read", ["path": "notes/todo.md"])
        XCTAssertEqual(outside["ok"] as? Bool, false)
        XCTAssertTrue(text(outside).contains("memory/"), text(outside))
    }

    // MARK: - 助手自己的记忆、待续、读

    func testRememberThenReadItBackThroughTheMemoryTree() async throws {
        let pid = floorB
        try await Task.detached { try FileLibraryStore.write("notes/别的.md", content: "纸鸢 不是记忆", profileId: pid) }.value
        let r = await send("remember", ["name": "纸鸢的约定", "description": "星砚答应帮岚舟刻纸鸢", "importance": 5,
                                        "body": "岚舟说「帮我刻一只纸鸢」，我答应了。", "asked_by_user": true])
        XCTAssertEqual(r["ok"] as? Bool, true, text(r))
        XCTAssertTrue(text(r).contains("「B 楼」这一层"), text(r))
        let stored = SelfMemoryStore.list(memoryRoot: FileLibraryStore.memoryRoot(profileId: floorB), checkPath: AppPaths.checked)
        XCTAssertEqual(stored.map(\.name), ["纸鸢的约定"])
        XCTAssertEqual(stored.first?.source, "chat-b")
        XCTAssertTrue(SelfMemoryStore.list(memoryRoot: FileLibraryStore.memoryRoot(profileId: floorA), checkPath: AppPaths.checked).isEmpty)

        let found = await send("fs_search", ["keyword": "纸鸢"])
        XCTAssertEqual(found["ok"] as? Bool, true, text(found))
        let lines = text(found).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("memory/") }, "只给记忆树里的，文件库别的文件不带：\(text(found))")
        let listed = await send("fs_list", [:])
        XCTAssertTrue(text(listed).contains("memory/self/"), text(listed))
        XCTAssertFalse(text(listed).contains("notes/"), text(listed))
        let path = "memory/self/" + (try XCTUnwrap(stored.first)).fileName
        let read = await send("fs_read", ["path": path])
        XCTAssertEqual(read["ok"] as? Bool, true, text(read))
        XCTAssertTrue(text(read).contains("帮我刻一只纸鸢"), text(read))

        let forgot = await send("forget_memory", ["target": "纸鸢的约定", "reason": "刻好了"])
        XCTAssertEqual(forgot["ok"] as? Bool, true, text(forgot))
    }

    func testPendingNotes() async {
        let added = await send("pending_notes", ["action": "add", "text": "帮岚舟问皮影作坊周三开不开"])
        XCTAssertEqual(added["ok"] as? Bool, true, text(added))
        let list = await send("pending_notes", ["action": "list"])
        XCTAssertEqual(list["ok"] as? Bool, true, text(list))
        XCTAssertTrue(text(list).contains("帮岚舟问皮影作坊周三开不开"), text(list))
    }

    func testRecallRunsOnThatFloor() async {
        allow()
        // 卡是在另一个窗口里记下的（recall 默认不翻当前窗口）
        _ = await send("memory_card", ["action": "add", "content": "岚舟每周三去槐序巷皮影作坊学雕皮影。"], chatId: "chat-b2")
        let r = await send("recall", ["op": "search", "query": "皮影作坊", "scope": "c"])
        XCTAssertEqual(r["ok"] as? Bool, true, text(r))
        XCTAssertTrue(text(r).contains("皮影作坊"), text(r))
        let bad = await send("recall", ["op": "nonsense"])
        XCTAssertEqual(bad["ok"] as? Bool, false)
    }

    func testActorName() {
        XCTAssertEqual(MemoryCCBridge.actorName("星砚"), "CC 里的星砚")
        XCTAssertEqual(MemoryCCBridge.actorName("  "), "CC 里的助手")
    }
}
