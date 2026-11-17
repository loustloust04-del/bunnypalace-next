import SwiftData
import XCTest
@testable import 记忆花园

/// 电脑文件夹楼层「看历史」（docs/plan-folder-floor.md P2）：一轮怎么变成消息、同步来的 session 怎么落进主库、
/// 同步引擎的收发和排队。夹具全是编的。
final class FolderHistoryTests: XCTestCase {
    private let pid = "xctest-fh-floor"
    private let hub = "hub-identity-1"
    private let sid = "11111111-0000-4000-8000-000000000000"
    private var key: String { "xiao:\(sid)" }
    private var convId: String { FolderHistory.conversationId(hubIdentity: hub, profileId: pid, key: key) }
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    private func meta(_ key: String, title: String = "顶栏重构", turns: Int = 2, epoch: Int = 1, seq: Int = 5, updatedAt: Double = 1_800_000_000_000) -> FolderHistory.SessionMeta {
        let parts = key.split(separator: ":").map(String.init)
        return .init(key: key, account: parts[0], sid: parts[1], title: title, createdAt: updatedAt - 60_000, updatedAt: updatedAt, turns: turns, epoch: epoch, seq: seq)
    }
    private func turn(_ id: String, _ text: String, from: String = "human", parts: [FolderHistory.Part] = [.text("答")], at: Double = 1_800_000_000_000) -> FolderHistory.Turn {
        .init(id: id, at: at, from: from, who: nil, text: text, images: nil, parts: parts, endAt: at + 5000)
    }
    private func turnsReply(_ turns: [FolderHistory.Turn], from: Int = 0, epoch: Int = 1, next: Int? = nil) -> FolderHistory.TurnsReply {
        .init(ok: true, error: nil, key: key, epoch: epoch, total: from + turns.count, from: from, turns: turns, next: next)
    }
    private func job(from: Int = 0, epoch: Int = 1, seq: Int = 5) -> FolderHistoryStore.Job {
        .init(profileId: pid, conversationId: convId, key: key, from: from, epoch: epoch, seq: seq, updatedAt: 0)
    }
    private func conversations(_ profile: String? = nil) -> [Conversation] {
        let p = profile ?? pid
        return (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == p }))) ?? []
    }
    private func nodes() -> [MessageNode] {
        let c = convId
        return ((try? context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == c }))) ?? [])
    }
    private func node(_ id: String) -> MessageNode? { nodes().first { $0.id == id } }
    @discardableResult
    private func list(_ metas: [FolderHistory.SessionMeta], gone: [String] = [], hubSessions: [String: String] = [:], profile: String? = nil) throws -> FolderHistoryStore.ListResult {
        try FolderHistoryStore.applyList(metas: metas, gone: gone, hubSessions: hubSessions, profileId: profile ?? pid, hubIdentity: hub, in: context)
    }

    // MARK: 一轮 → 消息

    func testServerJSONDecodes() {
        let reply: FolderHistory.TurnsReply = decode("""
        {"ok":true,"key":"xiao:\(sid)","epoch":1,"total":1,"from":0,"next":null,"turns":[{"id":"u1","at":1800000000000,"from":"session","who":"Warden",
        "text":"合好了","parts":[{"k":"thinking","text":"","ms":1200},{"k":"tool","id":"t1","name":"Read","brief":"a.swift"},{"k":"text","text":"收到"},{"k":"以后才有的","x":1}],"endAt":1800000005000}]}
        """)
        XCTAssertEqual(reply.turns?.first?.parts, [.thinking(""), .tool(id: "t1", name: "Read", brief: "a.swift"), .text("收到"), .unknown])
        let list: FolderHistory.SessionsReply = decode("""
        {"ok":true,"seq":7,"pending":false,"gone":[],"states":{"xiao:\(sid)":"busy"},"hub_sessions":{"xiao:\(sid)":"mp-cc-84"},
        "sessions":[{"key":"xiao:\(sid)","account":"xiao","sid":"\(sid)","title":"t","cwd":"/r","createdAt":1,"updatedAt":2,"turns":3,"answered":true,"epoch":1,"seq":7}]}
        """)
        XCTAssertEqual(list.sessions?.first?.turns, 3)
        XCTAssertEqual(list.states?["xiao:\(sid)"], "busy")
    }

    func testTurnBecomesInputPlusOneAnswerWithExistingSegments() throws {
        let t = turn("u1", "顶栏点了没反应", parts: [.thinking(""), .thinking("先看点击区域"), .tool(id: "t1", name: "Read", brief: "Views/TopBar.swift"), .text("找到了")])
        let out = FolderHistory.nodes(for: t, index: 3, conversationId: "c", parent: "c-2a")
        XCTAssertEqual(out.map(\.id), ["c-3u", "c-3a"])
        XCTAssertEqual(out[0].role, "user")
        XCTAssertEqual(out[0].content, "顶栏点了没反应")
        XCTAssertEqual(out[0].parentId, "c-2a")
        XCTAssertEqual(out[0].childrenIds, ["c-3a"])
        XCTAssertEqual(out[1].parentId, "c-3u")
        XCTAssertEqual(out[1].contentType, "segmented")
        let segments = try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(out[1].segmentsData))
        XCTAssertEqual(segments, [
            .thinking(text: "先看点击区域", signature: nil),
            .toolUse(id: "t1", name: "Read", inputJSON: "{}", integrationName: "Read · Views/TopBar.swift", iconName: "doc.text"),
            .toolResult(toolUseId: "t1", text: FolderHistory.toolResultNote, isError: false, integrationName: nil),
            .text("找到了"),
        ], "空的思考不放；工具配一条结果，现成的工具行才不会一直显示进行中")
        XCTAssertEqual(out[1].content, "<<<THINK>>>\n先看点击区域\n<<</THINK>>>\n\n🔧 Read Views/TopBar.swift\n\n找到了", "纯文本给搜索用，不带那句「在电脑上」")
    }

    func testTurnWithoutInputOrWithoutAnswer() {
        let noInput = FolderHistory.nodes(for: turn("a1", "", from: "none"), index: 0, conversationId: "c", parent: nil)
        XCTAssertEqual(noInput.map(\.id), ["c-0a"])
        XCTAssertNil(noInput[0].parentId)
        let noAnswer = FolderHistory.nodes(for: turn("u1", "问", parts: []), index: 1, conversationId: "c", parent: "c-0a")
        XCTAssertEqual(noAnswer.map(\.id), ["c-1u"])
        XCTAssertEqual(noAnswer[0].childrenIds, [])
        XCTAssertTrue(FolderHistory.nodes(for: turn("x", "", from: "none", parts: [.thinking("")]), index: 2, conversationId: "c", parent: nil).isEmpty)
    }

    func testInputTextSaysWhoSaidIt() {
        var t = turn("u", "合好了", from: "session")
        t.who = "Warden"
        XCTAssertEqual(FolderHistory.inputText(t), "【Warden 发来】\n合好了")
        XCTAssertEqual(FolderHistory.inputText(turn("u", "b1 completed", from: "system")), "（后台任务通知）b1 completed")
        var img = turn("u", "")
        img.images = 2
        XCTAssertEqual(FolderHistory.inputText(img), "（附了 2 张图）")
    }

    func testConversationIdIsStablePerHubAndFloor() {
        let a = FolderHistory.conversationId(hubIdentity: "h1", profileId: "p1", key: key)
        XCTAssertEqual(a, FolderHistory.conversationId(hubIdentity: "h1", profileId: "p1", key: key))
        XCTAssertNotEqual(a, FolderHistory.conversationId(hubIdentity: "h2", profileId: "p1", key: key))
        XCTAssertNotEqual(a, FolderHistory.conversationId(hubIdentity: "h1", profileId: "p2", key: key), "两层连同一台电脑：各有各的一份")
        XCTAssertTrue(a.hasPrefix(FolderHistory.conversationId(hubIdentity: "h1", profileId: "p1", key: "")))
    }

    // MARK: 列表落库

    func testListCreatesReadOnlyArchiveConversations() throws {
        let result = try list([meta(key)])
        let c = try XCTUnwrap(conversations().first)
        XCTAssertEqual(c.id, convId)
        XCTAssertEqual(c.title, "顶栏重构")
        XCTAssertEqual(c.provider, FolderHistory.provider)
        XCTAssertTrue(c.isFolderSession)
        XCTAssertTrue(c.isReadOnlyArchive, "这一段只读")
        XCTAssertFalse(c.memoryEnabled, "不进记忆")
        XCTAssertEqual(FolderHistoryStore.source(of: c), .init(key: key, hub: hub, epoch: 1, turns: 0, seq: 0))
        XCTAssertEqual(result.jobs, [.init(profileId: pid, conversationId: convId, key: key, from: 0, epoch: 1, seq: 5, updatedAt: 1_800_000_000_000)])
        XCTAssertEqual(result.ids, [key: convId])

        let again = try list([meta(key, title: "改名了", seq: 5)])
        XCTAssertEqual(conversations().count, 1, "再来一次是更新，不多一条")
        XCTAssertEqual(conversations().first?.title, "改名了")
        XCTAssertEqual(again.jobs.count, 1, "正文还没拉完（序号没对上）：还要拉")
    }

    func testListSkipsSessionsThePhoneOpenedItself() throws {
        let local = Conversation(id: "local-1", title: "手机上开的", createTime: Date(), updateTime: Date(), currentNodeId: "", provider: "cc-bridge", profileId: pid)
        local.ccBridgeSessionName = "mp-cc-84"
        context.insert(local)
        try context.save()
        let result = try list([meta(key)], hubSessions: [key: "mp-cc-84"])
        XCTAssertEqual(conversations().map(\.id), ["local-1"], "这条 session 就是手机上那条对话，不再来一份")
        XCTAssertTrue(result.jobs.isEmpty)
        // 电脑说是它开的、但这一层没有那条对话（在别的手机上开的）：照常同步
        XCTAssertEqual(try list([meta(key)], hubSessions: [key: "mp-cc-99"]).jobs.count, 1)
    }

    func testListDoesNotReviveTrashedOrTouchOtherFloors() throws {
        try list([meta(key)])
        let c = try XCTUnwrap(conversations().first)
        c.isTrashed = true
        c.title = "她删掉的"
        try context.save()
        XCTAssertTrue(try list([meta(key, title: "电脑上又改名了", seq: 9)]).jobs.isEmpty)
        XCTAssertEqual(conversations().first?.title, "她删掉的")
        XCTAssertEqual(conversations().first?.isTrashed, true)

        // 号被别的楼层的对话占着（不该发生）：不改别人的
        let other = Conversation(id: FolderHistory.conversationId(hubIdentity: hub, profileId: pid, key: "xiao:22222222-0000-4000-8000-000000000000"),
                                 title: "别人的", createTime: Date(), updateTime: Date(), currentNodeId: "", provider: "api", profileId: "other-floor")
        context.insert(other)
        try context.save()
        XCTAssertTrue(try list([meta("xiao:22222222-0000-4000-8000-000000000000")]).jobs.isEmpty)
        XCTAssertEqual(conversations("other-floor").first?.title, "别人的")
        XCTAssertEqual(conversations("other-floor").first?.provider, "api")
    }

    // MARK: 内容落库

    func testTurnsWriteALinearChainAndGrowTheLastTurn() throws {
        try list([meta(key, title: "")])
        XCTAssertEqual(conversations().first?.title, FolderHistoryStore.placeholderTitle)
        let first = try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "第一句"), turn("u1", "第二句", parts: [])]), job: job(), in: context)
        XCTAssertEqual(first, .written(next: nil))
        XCTAssertEqual(nodes().map(\.id).sorted(), ["\(convId)-0a", "\(convId)-0u", "\(convId)-1u"])
        XCTAssertEqual(node("\(convId)-0u")?.childrenIds, ["\(convId)-0a"])
        XCTAssertEqual(node("\(convId)-0a")?.childrenIds, ["\(convId)-1u"], "下一轮接在上一轮的回答后面")
        XCTAssertEqual(node("\(convId)-1u")?.parentId, "\(convId)-0a")
        XCTAssertTrue(nodes().allSatisfy { $0.profileId == pid })
        let c = try XCTUnwrap(conversations().first)
        XCTAssertEqual(c.currentNodeId, "\(convId)-1u")
        XCTAssertEqual(c.nodeCount, 3)
        XCTAssertEqual(c.title, "第一句", "电脑上没标题：用第一句话")
        XCTAssertEqual(FolderHistoryStore.source(of: c), .init(key: key, hub: hub, epoch: 1, turns: 2, seq: 5, leaf: "\(convId)-1u", leafBeforeLast: "\(convId)-0a"))

        // 第二轮后来答了，又多了第三轮：从第二轮重拉
        let jobs = try list([meta(key, title: "", turns: 3, seq: 8)]).jobs
        XCTAssertEqual(jobs.first?.from, 1)
        let more = try FolderHistoryStore.applyTurns(turnsReply([turn("u1", "第二句", parts: [.text("第二句的回答")]), turn("u2", "第三句")], from: 1),
                                                    job: job(from: 1, seq: 8), in: context)
        XCTAssertEqual(more, .written(next: nil))
        XCTAssertEqual(nodes().count, 6, "第二轮的输入没有重复建：原来 3 条 + 第二轮的回答 + 第三轮的两条")
        XCTAssertEqual(node("\(convId)-1u")?.childrenIds, ["\(convId)-1a"])
        XCTAssertEqual(node("\(convId)-1a")?.content, "第二句的回答")
        XCTAssertEqual(node("\(convId)-2u")?.parentId, "\(convId)-1a")
        XCTAssertEqual(conversations().first?.currentNodeId, "\(convId)-2a")
        XCTAssertTrue(try list([meta(key, title: "", turns: 3, seq: 8)]).jobs.isEmpty, "拉完了，序号对上，不再拉")
    }

    func testTurnsPageByPage() throws {
        try list([meta(key)])
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一")], next: 1), job: job(), in: context), .written(next: 1))
        XCTAssertEqual(FolderHistoryStore.source(of: try XCTUnwrap(conversations().first))?.seq, 0, "还有下一页：不算拉完")
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u1", "二")], from: 1), job: job(from: 1), in: context), .written(next: nil))
        XCTAssertEqual(nodes().count, 4)
        XCTAssertEqual(node("\(convId)-1u")?.parentId, "\(convId)-0a")
    }

    func testStaleRepliesAreDropped() throws {
        try list([meta(key)])
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一")], epoch: 2), job: job(), in: context), .stale, "电脑那头文件换过")
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u5", "跳着来的")], from: 5), job: job(from: 5), in: context), .stale, "中间缺了几轮")
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一")], from: 0), job: job(from: 1), in: context), .stale, "回来的不是要的那一页")
        var other = turnsReply([turn("u0", "别的 session 的内容")])
        other.key = "xiao:99999999-0000-4000-8000-000000000000"
        XCTAssertEqual(try FolderHistoryStore.applyTurns(other, job: job(), in: context), .stale, "回来的不是要的那条")
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([]), job: job(), in: context), .stale, "空页")
        XCTAssertTrue(nodes().isEmpty)

        // 已经落了两轮以后：比「最后一轮」还旧的页不认（不会把已落的轮数写小）
        _ = try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一"), turn("u1", "二"), turn("u2", "三")]), job: job(), in: context)
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u1", "二")], from: 1), job: job(from: 1), in: context), .stale)
        XCTAssertEqual(FolderHistoryStore.source(of: try XCTUnwrap(conversations().first))?.turns, 3)
        XCTAssertEqual(nodes().count, 6)
        for n in nodes() { context.delete(n) }
        try context.save()
        let c = try XCTUnwrap(conversations().first)
        c.isTrashed = true
        try context.save()
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一")]), job: job(), in: context), .stale, "她删掉的不再写")
    }

    func testMessageIdTakenBySomeoneElseDropsTheWholePage() throws {
        try list([meta(key)])
        let squatter = MessageNode(id: "\(convId)-0a", role: "assistant", content: "别的楼层的消息", contentType: "text", createTime: Date(),
                                   parentId: nil, childrenIds: [], conversationId: "someone-else", profileId: "other-floor")
        context.insert(squatter)
        try context.save()
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一")]), job: job(), in: context), .stale)
        let all = (try? context.fetch(FetchDescriptor<MessageNode>())) ?? []
        XCTAssertEqual(all.map(\.id), ["\(convId)-0a"], "这一页一条都没写进去（输入那条也没写）")
        XCTAssertEqual(all.first?.profileId, "other-floor")
        XCTAssertEqual(all.first?.content, "别的楼层的消息")
    }

    func testCollisionOnALaterPageLeavesExistingMessagesUntouched() throws {
        try list([meta(key)])
        _ = try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一")], next: 1), job: job(), in: context)
        context.insert(MessageNode(id: "\(convId)-1a", role: "assistant", content: "别的楼层的消息", contentType: "text", createTime: Date(),
                                   parentId: nil, childrenIds: [], conversationId: "someone-else", profileId: "other-floor"))
        try context.save()
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u1", "二")], from: 1), job: job(from: 1), in: context), .stale)
        try context.save()
        XCTAssertEqual(node("\(convId)-0a")?.childrenIds, [], "已有的上一条没有被接上半截")
        XCTAssertNil(node("\(convId)-1u"), "这一页的输入也没写")
        XCTAssertEqual(FolderHistoryStore.source(of: try XCTUnwrap(conversations().first))?.turns, 1)
    }

    func testWrongNextCursorIsRejected() throws {
        try list([meta(key)])
        XCTAssertEqual(try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一")], next: 5), job: job(), in: context), .stale, "下一页的起点和这一页接不上")
        XCTAssertTrue(nodes().isEmpty)
    }

    func testListedAndGoneInTheSameReplyKeepsTheSession() throws {
        try list([meta(key)])
        _ = try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一"), turn("u1", "二")]), job: job(), in: context)
        let result = try list([meta(key, turns: 3, seq: 9)], gone: [key])
        XCTAssertEqual(nodes().count, 4, "掉出去又回来的：以列表为准，正文不删")
        XCTAssertEqual(result.jobs.first?.from, 1, "接着从最后一轮往后拉，不是从头")
    }

    func testSourceWithoutLeafButWithMessagesIsRebuilt() throws {
        try list([meta(key)])
        _ = try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一"), turn("u1", "二")]), job: job(), in: context)
        let c = try XCTUnwrap(conversations().first)
        // 来源信息里没有「最后一条消息」（比如更早的版本存的）
        c.sourceMetadata = Data(#"{"key":"\#(key)","hub":"\#(hub)","epoch":1,"turns":2,"seq":5}"#.utf8)
        try context.save()
        let jobs = try list([meta(key, turns: 3, seq: 9)]).jobs
        XCTAssertTrue(nodes().isEmpty, "对不上的：清掉正文")
        XCTAssertEqual(jobs.first?.from, 0, "从头重拉，不会把后面的消息接成另一条链")
    }

    func testManyEmptyTurnsDoNotBreakTheChain() throws {
        try list([meta(key)])
        let empty = (1...250).map { turn("e\($0)", "", from: "none", parts: [.thinking("")]) }
        _ = try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "一")] + empty, next: 251), job: job(), in: context)
        _ = try FolderHistoryStore.applyTurns(turnsReply([turn("u251", "二百五十轮空的之后")], from: 251), job: job(from: 251), in: context)
        XCTAssertEqual(node("\(convId)-251u")?.parentId, "\(convId)-0a", "中间隔了多少空轮都接在上一条真消息后面")
        XCTAssertEqual(node("\(convId)-0a")?.childrenIds, ["\(convId)-251u"])
    }

    func testCopyIsNotOfferedForSyncedSessions() {
        let labels = { (s: ConversationMenu.State) in ConversationMenu.specs(place: .list, state: s, handlers: .init()).compactMap(\.quickLabel) }
        XCTAssertTrue(labels(.init()).contains("Copy"))
        XCTAssertFalse(labels(.init(isFolderSession: true)).contains("Copy"), "副本会丢掉归档身份，正文就能被备份、同步带走")
        XCTAssertTrue(labels(.init(isFolderSession: true)).contains("Delete"))
    }

    func testEpochChangeAndGoneWipeBodyButKeepTheConversation() throws {
        try list([meta(key)])
        _ = try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "旧的")]), job: job(), in: context)
        XCTAssertEqual(nodes().count, 2)
        let jobs = try list([meta(key, epoch: 2, seq: 9)]).jobs
        XCTAssertTrue(nodes().isEmpty, "文件换过：旧正文清掉重拉")
        XCTAssertEqual(jobs.first?.from, 0)
        XCTAssertEqual(jobs.first?.epoch, 2)

        _ = try FolderHistoryStore.applyTurns(turnsReply([turn("u0", "新的")], epoch: 2), job: job(epoch: 2, seq: 9), in: context)
        try list([], gone: [key])
        XCTAssertTrue(nodes().isEmpty, "掉出 30 天：正文删掉")
        XCTAssertEqual(conversations().first?.title, "顶栏重构", "标题留着")
        XCTAssertEqual(conversations().first?.nodeCount, 0)
    }

    // MARK: 不离开手机：按对话本身挡，这一层后来不连了也一样

    @MainActor
    func testSyncedSessionsAreNotExportedToCloudEvenOnAPlainFloor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fh-sync-test-\(UUID().uuidString)")
        SyncStore.overrideRoot = root
        defer {
            SyncStore.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
            SyncStoreTests.wipeLocalSyncState(pid: pid)
        }
        try list([meta(key)])   // 这一层没在 FolderFloor 登记里 = 现在是普通楼层
        context.insert(Conversation(id: "plain-1", title: "普通对话", createTime: Date(), updateTime: Date(), currentNodeId: "", provider: "api", profileId: pid))
        try context.save()
        let result = SyncStore.exportChanged(profileId: pid, context: context)
        XCTAssertEqual(result.exported, 1, "只导出普通的那条")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: SyncStore.syncRoot(profileId: pid)!.path)) ?? []
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files.contains { $0.contains(convId) })
    }

    // MARK: 同步引擎

    @MainActor
    private func engine(floors: [Profile], sent: @escaping (String, [String: Any]) -> Void) -> FolderHistorySync {
        let e = FolderHistorySync()
        let c = container!
        e.profiles = { floors }
        e.container = { c }
        e.defaults = UserDefaults(suiteName: "xctest-fh-\(UUID().uuidString)")!
        e.hubFacts = { _ in (identity: "hub-identity-1", defaultAccount: "default", supported: true) }
        e.send = { hubId, payload in sent(hubId, payload); return true }
        return e
    }
    private func floor(_ id: String, account: String?) -> Profile {
        var p = Profile(id: id, name: id, emoji: "", description: "", userName: "你", assistantName: "助手")
        p.folderHubId = "h1"
        p.folderHubIdentity = "hub-identity-1"
        p.folderAccount = account
        return p
    }
    private func frame(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    @MainActor
    private func wait(_ what: String, _ condition: @escaping () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what)
    }

    @MainActor
    func testEngineListsThenFetchesBodiesNewestFirstAndKeepsStates() async throws {
        var sent: [[String: Any]] = []
        let e = engine(floors: [floor(pid, account: "xiao"), Profile(id: "plain", name: "普通", emoji: "", description: "", userName: "你", assistantName: "助手")]) { hubId, payload in
            XCTAssertEqual(hubId, "h1")
            sent.append(payload)
        }
        e.handle(hubId: "h1", type: "hello", data: nil)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]["op"] as? String, "sessions")
        XCTAssertEqual(sent[0]["after"] as? Int, 0)

        let older = "xiao:22222222-0000-4000-8000-000000000000", foreign = "default:33333333-0000-4000-8000-000000000000"
        func m(_ k: String, _ updated: Double) -> [String: Any] {
            let p = k.split(separator: ":").map(String.init)
            return ["key": k, "account": p[0], "sid": p[1], "title": "标题", "createdAt": 1, "updatedAt": updated, "turns": 1, "epoch": 1, "seq": 7]
        }
        e.handle(hubId: "h1", type: "folder_req_result", data: frame([
            "type": "folder_req_result", "req_id": sent[0]["req_id"] as Any, "ok": true, "seq": 7, "pending": false, "gone": [],
            "sessions": [m(older, 1000), m(key, 2000), m(foreign, 3000)], "states": [key: "wait", foreign: "busy"],
        ]))
        await wait("列表落库后开始拉正文") { sent.count == 2 }
        XCTAssertEqual(conversations().count, 2, "这一层只收它那个账号的 session")
        XCTAssertEqual(sent[1]["op"] as? String, "turns")
        XCTAssertEqual(sent[1]["key"] as? String, key, "新的先拉")
        XCTAssertEqual(e.states, [convId: "wait"])

        e.handle(hubId: "h1", type: "folder_req_result", data: frame([
            "type": "folder_req_result", "req_id": sent[1]["req_id"] as Any, "ok": true, "key": key, "epoch": 1, "total": 1, "from": 0,
            "turns": [["id": "u0", "at": 1, "from": "human", "text": "问", "parts": [["k": "text", "text": "答"]], "endAt": 2]],
        ]))
        await wait("这条写完接着拉下一条") { sent.count == 3 }
        XCTAssertEqual(sent[2]["key"] as? String, older)
        XCTAssertEqual(nodes().count, 2)

        // 有一条正文没拉成：下一次问的是全量列表（游标已经往前走了，只问「之后有变化的」就再也轮不到它）
        e.handle(hubId: "h1", type: "folder_req_result", data: frame(["type": "folder_req_result", "req_id": sent[2]["req_id"] as Any, "ok": false, "error": "没有这条对话"]))
        try? await Task.sleep(for: .milliseconds(50))
        e.handle(hubId: "h1", type: "folder_changed", data: frame(["type": "folder_changed", "keys": [key]]))
        await wait("再问一次列表") { sent.count == 4 }
        XCTAssertEqual(sent[3]["after"] as? Int, 0)
        e.handle(hubId: "h1", type: "folder_req_result", data: frame([
            "type": "folder_req_result", "req_id": sent[3]["req_id"] as Any, "ok": true, "seq": 9, "sessions": [m(older, 1000), m(key, 2000)], "states": [:],
        ]))
        await wait("没拉成的那条重新排上；拉完的那条不再拉") { sent.count == 5 }
        XCTAssertEqual(sent[4]["key"] as? String, older)
        XCTAssertTrue(e.states.isEmpty, "状态每次是全量，这次没有了就清掉")

        // 这次拉成了：之后的变化通知只问「之后有变化的」
        e.handle(hubId: "h1", type: "folder_req_result", data: frame([
            "type": "folder_req_result", "req_id": sent[4]["req_id"] as Any, "ok": true, "key": older, "epoch": 1, "total": 1, "from": 0,
            "turns": [["id": "u0", "at": 1, "from": "human", "text": "问", "parts": [["k": "text", "text": "答"]], "endAt": 2]],
        ]))
        try? await Task.sleep(for: .milliseconds(50))
        e.handle(hubId: "h1", type: "folder_changed", data: frame(["type": "folder_changed", "keys": [key]]))
        await wait("再问列表") { sent.count == 6 }
        XCTAssertEqual(sent[5]["after"] as? Int, 9)
    }

    @MainActor
    func testEngineGivesUpOnASessionAfterRepeatedFailuresUntilReconnect() async throws {
        var sent: [[String: Any]] = []
        let e = engine(floors: [floor(pid, account: "xiao")]) { _, payload in sent.append(payload) }
        func listReply(_ n: Int) -> Data {
            frame(["type": "folder_req_result", "req_id": sent[n]["req_id"] as Any, "ok": true, "seq": 7, "states": [:],
                   "sessions": [["key": key, "account": "xiao", "sid": sid, "title": "t", "createdAt": 1, "updatedAt": 2, "turns": 1, "epoch": 1, "seq": 7]]])
        }
        e.handle(hubId: "h1", type: "hello", data: nil)
        for round in 0..<FolderHistorySync.maxFailures {
            let listAt = round * 2
            await wait("第 \(round + 1) 次列表") { sent.count == listAt + 1 }
            XCTAssertEqual(sent[listAt]["after"] as? Int, 0, "有没拉成的：问全量")
            e.handle(hubId: "h1", type: "folder_req_result", data: listReply(listAt))
            await wait("第 \(round + 1) 次拉正文") { sent.count == listAt + 2 }
            e.handle(hubId: "h1", type: "folder_req_result", data: frame(["type": "folder_req_result", "req_id": sent[listAt + 1]["req_id"] as Any, "ok": false, "error": "坏了"]))
            try? await Task.sleep(for: .milliseconds(50))
            e.handle(hubId: "h1", type: "folder_changed", data: nil)
        }
        let n = FolderHistorySync.maxFailures * 2
        await wait("失败够三次以后的那次列表") { sent.count == n + 1 }
        e.handle(hubId: "h1", type: "folder_req_result", data: listReply(n))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sent.count, n + 1, "连着三次没成的那条先放下，不再拉")
        e.handle(hubId: "h1", type: "folder_changed", data: nil)
        await wait("再有变化") { sent.count == n + 2 }
        XCTAssertEqual(sent[n + 1]["after"] as? Int, 7, "全量列表成功过了：之后只问有变化的，不再每次问全量")

        e.handle(hubId: "h1", type: "folder_req_result", data: frame(["type": "folder_req_result", "req_id": sent[n + 1]["req_id"] as Any, "ok": true, "seq": 7, "sessions": [], "states": [:]]))
        try? await Task.sleep(for: .milliseconds(50))
        e.handle(hubId: "h1", type: "hello", data: nil)
        await wait("重新连上：全量列表") { sent.count == n + 3 }
        e.handle(hubId: "h1", type: "folder_req_result", data: listReply(n + 2))
        await wait("重新连上以后那条再试一次") { sent.count == n + 4 }
        XCTAssertEqual(sent[n + 3]["op"] as? String, "turns")
    }

    @MainActor
    func testEngineDoesNothingWithoutLinkedFloorOrSupport() {
        var sent = 0
        let none = engine(floors: [Profile(id: "plain", name: "普通", emoji: "", description: "", userName: "你", assistantName: "助手")]) { _, _ in sent += 1 }
        none.handle(hubId: "h1", type: "hello", data: nil)
        let old = engine(floors: [floor(pid, account: nil)]) { _, _ in sent += 1 }
        old.hubFacts = { _ in (identity: "hub-identity-1", defaultAccount: "default", supported: false) }
        old.handle(hubId: "h1", type: "hello", data: nil)
        XCTAssertEqual(sent, 0, "没有连着这台电脑的楼层 / 那台还是老 hub：一帧都不发")
    }
}
