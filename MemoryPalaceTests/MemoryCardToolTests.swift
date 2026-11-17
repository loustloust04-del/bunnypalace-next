import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 助手动记忆条目的工具 `memory_card`：加 / 改 / 删 / 恢复 / 钉，每一笔进审计日志、能撤回；门和权限域。全虚构
@MainActor
final class MemoryCardToolTests: XCTestCase {
    private let pid = "xctest-memory-card-tool"
    private let actor = "星砚"
    private var saved: [String: Any] = [:]
    private var keys: [String] { ["mem_master", PermissionDomain.memoryCards.storageKey, PermissionDomain.memoryCards.legacy.key, PermissionCenter.floorsKey] }

    override func setUp() {
        super.setUp()
        saved = [:]
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) { saved[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
        UserDefaults.standard.set(true, forKey: "mem_master")
    }

    override func tearDown() {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    private func run(_ json: String, _ context: ModelContext, memoryEnabled: Bool = true, now: Date = Date()) -> MemoryCardTool.Result {
        MemoryCardTool.execute(inputJSON: json, profileId: pid, conversationId: "conv-1", memoryEnabled: memoryEnabled, actor: actor, context: context, now: now)
    }

    private func cards(_ context: ModelContext) -> [Memory] {
        SwiftDataMemoryStore().listAll(profileId: pid, context: context)
    }

    private func log() -> [MemoryAuditLog.Entry] {
        MemoryAuditLog.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
    }

    func testAddMakesALiveApprovedCardAndLogsIt() throws {
        let context = try makeContext()
        let r = run(#"{"action":"add","content":" 岚舟每周三去槐序巷皮影作坊学雕皮影。 ","subject":"岚舟","speaker":"用户自述","tags":["皮影","周三","皮影"],"importance":9,"reason":"刚聊到的"}"#, context)
        XCTAssertFalse(r.isError, r.text)
        let m = try XCTUnwrap(cards(context).first)
        XCTAssertEqual(m.content, "岚舟每周三去槐序巷皮影作坊学雕皮影。")
        XCTAssertEqual(m.subject, "岚舟")
        XCTAssertEqual(m.speaker, "用户自述")
        XCTAssertEqual(m.keywords, ["皮影", "周三"])
        XCTAssertEqual(m.importance, 5, "夹到 1–5")
        XCTAssertEqual(m.sourceConversationId, "conv-1")
        XCTAssertNotNil(m.reviewedAt, "她允许过才落的库，算批过")
        XCTAssertTrue(MemoryInjector.isInjectable(m), "加的卡直接进得了对话")
        XCTAssertNil(m.userEditedAt, "不冒充她亲手改过")
        XCTAssertNil(m.confidence, "没给置信度就空着，不记 100")
        XCTAssertFalse(m.isUserExplicit)
        XCTAssertTrue(r.text.contains(MemoryCardTool.short(m.id)), "回话里带 id：\(r.text)")

        let entry = try XCTUnwrap(log().first)
        XCTAssertEqual(entry.actor, actor)
        XCTAssertEqual(entry.action, .add)
        XCTAssertEqual(entry.via, MemoryAuditLog.viaChat)
        XCTAssertEqual(entry.note, "刚聊到的")
        XCTAssertEqual(entry.items.map(\.card), [m.id])

        XCTAssertFalse(run(#"{"action":"add","content":"岚舟每周三去槐序巷皮影作坊学雕皮影。"}"#, context).isError)
        XCTAssertEqual(cards(context).count, 1, "一字不差的不再加")
        XCTAssertTrue(run(#"{"action":"add","content":"  "}"#, context).isError)
    }

    /// 助手在聊天里记下的条目：出处 = 触发这一轮的那条用户消息（跳转锚 + 原话）；CC 那头不给出处就没有
    func testAddKeepsTheUserMessageThatTriggeredTheTurnAsSource() throws {
        let container = try ModelContainer(for: Memory.self, MessageNode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        func node(_ id: String, _ role: String, _ content: String, parent: String?) -> MessageNode {
            let n = MessageNode(id: id, role: role, content: content, contentType: "text", createTime: Date(), parentId: parent,
                                childrenIds: [], conversationId: "conv-1", profileId: pid)
            context.insert(n)
            return n
        }
        let long = String(repeating: "云桥城的皮影戏", count: 30)
        _ = node("u1", "user", "我每周三去槐序巷\n学雕皮影。\(long)", parent: nil)
        _ = node("t1", "tool", "工具结果", parent: "u1")
        let reply = node("a1", "assistant", "", parent: "t1")
        let more = node("a2", "assistant", "", parent: "a1")
        try context.save()

        let source = try XCTUnwrap(MemoryCardTool.source(of: reply, context: context), "跳过夹在中间的工具节点，找到那条用户消息")
        XCTAssertEqual(source.nodeId, "u1")
        XCTAssertNil(MemoryCardTool.source(of: more, context: context), "上面是另一条助手消息（续写）= 没有用户消息触发，不硬找")

        let r = MemoryCardTool.execute(inputJSON: #"{"action":"add","content":"岚舟每周三去槐序巷学雕皮影。"}"#, profileId: pid, conversationId: "conv-1",
                                       memoryEnabled: true, actor: actor, source: source, context: context)
        XCTAssertFalse(r.isError, r.text)
        let m = try XCTUnwrap(cards(context).first)
        XCTAssertEqual(m.sourceNodeId, "u1")
        XCTAssertEqual(m.sourceQuote, MemoryEntryLine.quote(source.text), "原话和 C2 写手存的是同一个存法")
        XCTAssertTrue(m.sourceQuote?.hasPrefix("我每周三去槐序巷 学雕皮影。") == true && m.sourceQuote?.hasSuffix("…") == true)

        _ = MemoryCardTool.execute(inputJSON: #"{"action":"add","content":"岚舟住在云桥城。"}"#, profileId: pid, conversationId: nil,
                                   memoryEnabled: true, actor: actor, via: MemoryAuditLog.viaCC, context: context)
        let fromCC = try XCTUnwrap(cards(context).first { $0.content == "岚舟住在云桥城。" })
        XCTAssertNil(fromCC.sourceNodeId)
        XCTAssertNil(fromCC.sourceQuote)
    }

    func testUndoAnAddSendsTheCardToDeleted() throws {
        let context = try makeContext()
        _ = run(#"{"action":"add","content":"星砚答应帮岚舟刻一只纸鸢。","pin":true}"#, context)
        let m = try XCTUnwrap(cards(context).first)
        XCTAssertTrue(m.isUserExplicit, "add 时 pin = 加的同时钉住")
        let entry = try XCTUnwrap(log().first)
        XCTAssertTrue(MemoryAuditLog.canUndo(entry, in: log()))
        let result = MemoryAuditLog.undo(entry, profileId: pid, context: context)
        XCTAssertEqual(result.restored, 1)
        XCTAssertNotNil(m.supersededAt, "撤回一笔 Add = 这张进 Deleted，还能在整理台放回来")
        XCTAssertEqual(result.entry?.action, .undo)
    }

    func testEditDeleteRestorePinByIdAndPath() throws {
        let context = try makeContext()
        _ = run(#"{"action":"add","content":"岚舟的皮影作坊在槐序巷口。","subject":"岚舟","confidence":70}"#, context)
        let m = try XCTUnwrap(cards(context).first)
        let short = MemoryCardTool.short(m.id)

        let edit = run(#"{"action":"edit","id":"\#(short)","content":"岚舟的皮影作坊在槐序巷尾。","tags":["作坊"]}"#, context)
        XCTAssertFalse(edit.isError, edit.text)
        XCTAssertEqual(m.content, "岚舟的皮影作坊在槐序巷尾。")
        XCTAssertEqual(m.keywords, ["作坊"])
        XCTAssertEqual(m.subject, "岚舟", "没传的不动")
        XCTAssertEqual(m.confidence, 70, "助手改字不把置信度记成 100")
        XCTAssertNil(m.userEditedAt)
        XCTAssertNil(m.embeddingData)
        XCTAssertEqual(log().first?.action, .edit)
        XCTAssertFalse(run(#"{"action":"edit","id":"\#(short)","content":"岚舟的皮影作坊在槐序巷尾。"}"#, context).text.isEmpty)
        XCTAssertEqual(log().count, 2, "没变化不记")

        let path = MemoryCardFolder.entries(profileId: pid, context: context).first?.path ?? ""
        XCTAssertTrue(path.hasPrefix("memory/cards/岚舟/"), path)
        XCTAssertFalse(run(#"{"action":"pin","id":"\#(path)"}"#, context).isError, "id 可以填文件库里那份的路径")
        XCTAssertTrue(m.isUserExplicit)
        XCTAssertEqual(log().first?.action, .pin)
        XCTAssertFalse(run(#"{"action":"unpin","id":"\#(m.id.uuidString)"}"#, context).isError)
        XCTAssertFalse(m.isUserExplicit)
        XCTAssertEqual(log().first?.action, .unpin)

        XCTAssertFalse(run(#"{"action":"delete","id":"\#(short)","reason":"记错了"}"#, context).isError)
        XCTAssertNotNil(m.supersededAt, "软删：进 Deleted")
        XCTAssertEqual(cards(context).count, 1, "不出库")
        XCTAssertEqual(log().first?.action, .delete)
        XCTAssertTrue(run(#"{"action":"edit","id":"\#(short)","content":"x"}"#, context).isError, "删了的不能改")

        // 撤回助手的删：和撤回她自己的一样
        let deleted = try XCTUnwrap(log().first)
        XCTAssertEqual(MemoryAuditLog.undo(deleted, profileId: pid, context: context).restored, 1)
        XCTAssertNil(m.supersededAt)

        XCTAssertFalse(run(#"{"action":"delete","id":"\#(short)"}"#, context).isError)
        XCTAssertFalse(run(#"{"action":"restore","id":"\#(short)"}"#, context).isError)
        XCTAssertNil(m.supersededAt)
        XCTAssertEqual(log().first?.action, .restore)
        XCTAssertTrue(log().allSatisfy { $0.actor == actor && $0.via == MemoryAuditLog.viaChat })
    }

    func testLookup() {
        let a = UUID(uuidString: "3F2A9C1B-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "3F2A9C1B-0000-4000-8000-000000000002")!
        let c = UUID(uuidString: "77AA9C1B-0000-4000-8000-000000000003")!
        XCTAssertEqual(MemoryCardTool.lookup("77aa9c1b", in: [a, b, c]), .found(c))
        XCTAssertEqual(MemoryCardTool.lookup("memory/cards/岚舟/77aa9c1b.md", in: [a, b, c]), .found(c))
        XCTAssertEqual(MemoryCardTool.lookup("memory/cards/岚舟/77aa9c1b.txt", in: [a, b, c]), .found(c), "老的 .txt 路径也认")
        XCTAssertEqual(MemoryCardTool.lookup(a.uuidString, in: [a, b, c]), .found(a))
        XCTAssertEqual(MemoryCardTool.lookup("3f2a9c1b", in: [a, b, c]), .ambiguous(2))
        XCTAssertEqual(MemoryCardTool.lookup("3f2a", in: [a, b, c]), .missing, "少于 8 位不认")
        XCTAssertEqual(MemoryCardTool.lookup("岚舟那张", in: [a, b, c]), .missing)
        XCTAssertEqual(MemoryCardFolder.fileNames([a, b, c])[c], "77aa9c1b.md")
        XCTAssertEqual(MemoryCardFolder.fileNames([a, b, c])[a], a.uuidString.lowercased() + ".md", "开头 8 位撞了的用完整编号")
    }

    func testRefusals() throws {
        let context = try makeContext()
        XCTAssertTrue(run(#"{"action":"add","content":"岚舟养了一只叫纸鸢的猫。"}"#, context, memoryEnabled: false).isError, "本窗关了记忆参与")
        UserDefaults.standard.set(false, forKey: "mem_master")
        XCTAssertTrue(run(#"{"action":"add","content":"岚舟养了一只叫纸鸢的猫。"}"#, context).isError, "记忆总开关关着")
        UserDefaults.standard.set(true, forKey: "mem_master")
        XCTAssertTrue(run(#"{"action":"merge"}"#, context).isError)
        XCTAssertTrue(run(#"{"action":"delete","id":"00000000"}"#, context).isError)
        XCTAssertTrue(cards(context).isEmpty)
        XCTAssertTrue(log().isEmpty, "没动成的不记")
    }

    /// 权限域：单列「记忆条目」，默认每次询问、而且是一笔一问；不允许 = 不下发；关参与窗 / 总开关关 = 不下发
    func testPermissionDomainAndRegistryGate() {
        XCTAssertEqual(PermissionDomain.forTool(named: MemoryCardTool.toolName), .memoryCards)
        XCTAssertEqual(PermissionCenter.level(.memoryCards, profileId: pid), .askOnce)
        XCTAssertTrue(PermissionDomain.memoryCards.asksEveryCall)
        XCTAssertFalse(PermissionDomain.shell.asksEveryCall)
        XCTAssertTrue(PermissionDomain.toolDomains.contains(.memoryCards))
        XCTAssertEqual(ToolDrawerCatalog.item(named: MemoryCardTool.toolName)?.gate, .permission(.memoryCards))
        XCTAssertTrue(ToolRegistry.memoryWriteNames.contains(MemoryCardTool.toolName))

        func offered(_ ctx: ToolGateContext) -> Bool { ToolRegistry.enabledDefinitions(ctx).contains { $0.name == MemoryCardTool.toolName } }
        XCTAssertTrue(offered(.init(family: .anthropic, deferMCP: false, profileId: pid)), "每次询问也下发，真调用时问")
        XCTAssertFalse(offered(.init(family: .anthropic, deferMCP: false, profileId: pid, memoryWriteTools: false)), "关参与窗不下发")
        PermissionCenter.setFloorLevel(.notAllowed, for: .memoryCards, profileId: pid)
        XCTAssertFalse(offered(.init(family: .anthropic, deferMCP: false, profileId: pid)), "这一层不允许 = 不下发")
        XCTAssertEqual(ToolRegistry.availability(of: MemoryCardTool.toolName, .init(family: .anthropic, deferMCP: false, profileId: pid)), false)
        PermissionCenter.setFloorLevel(.bypass, for: .memoryCards, profileId: pid)
        XCTAssertTrue(offered(.init(family: .anthropic, deferMCP: false, profileId: pid)))
        UserDefaults.standard.set(false, forKey: "mem_master")
        XCTAssertFalse(offered(.init(family: .anthropic, deferMCP: false, profileId: pid)), "记忆总开关关了不给")
    }

    /// 询问卡上多出的一行：要动的那张现在写的是什么
    func testPermissionDetailShowsTheCard() throws {
        let context = try makeContext()
        _ = run(#"{"action":"add","content":"岚舟怕打雷。","subject":"岚舟"}"#, context)
        let m = try XCTUnwrap(cards(context).first)
        let detail = PermissionGate.detail(domain: .memoryCards, toolName: MemoryCardTool.toolName,
                                           argumentsJSON: #"{"action":"delete","id":"\#(MemoryCardTool.short(m.id))"}"#, profileId: pid, context: context)
        XCTAssertEqual(detail, "这条记忆条目现在写的是：「岚舟怕打雷。」（About 岚舟）")
        XCTAssertNil(PermissionGate.detail(domain: .memoryCards, toolName: MemoryCardTool.toolName,
                                           argumentsJSON: #"{"action":"add","content":"x"}"#, profileId: pid, context: context))
        XCTAssertEqual(PermissionGate.detail(domain: .memoryCards, toolName: MemoryCardTool.toolName,
                                             argumentsJSON: #"{"action":"pin","id":"deadbeef"}"#, profileId: pid, context: context),
                       "没找到这条记忆条目：deadbeef")
        // 一笔一问的两个答案：只管这一次，都不往对话授权里记
        XCTAssertNil(PermissionGate.outcome(.allowedOnce, domain: .memoryCards, originalArgs: "{}").record)
        XCTAssertNil(PermissionGate.outcome(.deniedOnce, domain: .memoryCards, originalArgs: "{}").record)
    }

    /// 发给模型的字：不带系统内部的叫法，例子只用虚构的
    func testToolTextStaysPlain() {
        let d = MemoryCardTool.definition
        var text = d.description + MemoryCardTool.hintLine
        for (_, value) in d.properties { text += ((value as? [String: Any])?["description"] as? String) ?? "" }
        for word in ["碎片", "档案", "C2", "C3", "wiki", "主人"] { XCTAssertFalse(text.contains(word), word) }
        XCTAssertTrue(d.description.contains("岚舟"))
        XCTAssertEqual(d.required, ["action"])
        XCTAssertEqual((d.properties["action"] as? [String: Any])?["enum"] as? [String], ["add", "edit", "delete", "restore", "pin", "unpin"])
        XCTAssertTrue(SelfMemoryTool.systemHint(available: [SelfMemoryTool.rememberName, MemoryCardTool.toolName]).contains("memory_card"))
        XCTAssertFalse(SelfMemoryTool.systemHint(available: [SelfMemoryTool.rememberName]).contains("memory_card"), "没给这个工具就不提")
    }
}
