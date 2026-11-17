import SwiftData
import XCTest
@testable import 记忆花园

/// 电脑文件夹楼层（docs/plan-folder-floor.md P1）：楼层多出来的三个字段、连 / 不连时跟着改什么、
/// 新对话连哪台、hello 里的文件夹和账号、发消息帧带账号、背后关掉的几样问的那个登记。
final class FolderFloorTests: XCTestCase {

    private func floor(_ id: String, hub: String? = nil, identity: String? = nil, account: String? = nil, model: String = "") -> Profile {
        var p = Profile(id: id, name: id, emoji: "", description: "", userName: "你", assistantName: "助手")
        p.folderHubId = hub
        p.folderHubIdentity = identity
        p.folderAccount = account
        p.preferredModel = model
        return p
    }

    override func tearDown() {
        FolderFloor.refresh([])
        super.tearDown()
    }

    // MARK: 楼层字段

    func testOldProfileJSONDecodesWithoutFolderFields() throws {
        let plain = floor("old")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        for key in ["folderHubId", "folderHubIdentity", "folderAccount"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.folderHubId, "老数据没有这几个键，解出来是空 = 普通楼层")
        XCTAssertNil(decoded.folderHubIdentity)
        XCTAssertNil(decoded.folderAccount)
        XCTAssertEqual(decoded.id, "old")
    }

    func testFolderFieldsRoundTrip() throws {
        let linked = floor("garden", hub: "h1", identity: "hub-id-1", account: "xiao")
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(linked))
        XCTAssertEqual(decoded.folderHubId, "h1")
        XCTAssertEqual(decoded.folderHubIdentity, "hub-id-1")
        XCTAssertEqual(decoded.folderAccount, "xiao")
    }

    // MARK: 登记

    func testRegistryTracksLinkedFloorsOnly() {
        FolderFloor.refresh([floor("a"), floor("b", hub: "h1", identity: "i1", account: "xiao"), floor("c", hub: "")])
        XCTAssertFalse(FolderFloor.isFolder("a"))
        XCTAssertTrue(FolderFloor.isFolder("b"))
        XCTAssertFalse(FolderFloor.isFolder("c"), "空串不算连着")
        XCTAssertFalse(FolderFloor.isFolder("nope"))
        XCTAssertEqual(FolderFloor.link("b"), .init(hubId: "h1", hubIdentity: "i1", account: "xiao"))

        FolderFloor.refresh([floor("b")])
        XCTAssertFalse(FolderFloor.isFolder("b"), "不连了以后登记跟着清")
    }

    // MARK: 连 / 不连

    func testLinkingSwitchesModelToCCCard() {
        let p = FolderFloor.linked(floor("g", model: "some-model"), hubId: "h1", hubIdentity: "i1", account: nil, ccModelId: "cc-card")
        XCTAssertEqual(p.folderHubId, "h1")
        XCTAssertEqual(p.folderHubIdentity, "i1")
        XCTAssertNil(p.folderAccount)
        XCTAssertEqual(p.preferredModel, "cc-card", "连上以后新开的对话是 CC 对话")
    }

    func testUnlinkingClearsAndResetsModelOnlyIfStillCCCard() {
        let wasCC = FolderFloor.unlinked(floor("g", hub: "h1", identity: "i1", account: "xiao", model: "cc-card"), ccModelId: "cc-card")
        XCTAssertNil(wasCC.folderHubId)
        XCTAssertNil(wasCC.folderHubIdentity)
        XCTAssertNil(wasCC.folderAccount)
        XCTAssertEqual(wasCC.preferredModel, "", "还是 CC 卡就回到跟随全局")

        let changed = FolderFloor.unlinked(floor("g", hub: "h1", model: "her-own-pick"), ccModelId: "cc-card")
        XCTAssertEqual(changed.preferredModel, "her-own-pick", "她自己换过模型的不动")
    }

    // MARK: 新对话连哪台

    func testHubForNewConversation() {
        FolderFloor.refresh([floor("plain"), floor("g", hub: "h1", identity: "i1")])
        let none: (String) -> String? = { _ in nil }

        XCTAssertNil(FolderFloor.hubForNewConversation(profileId: "plain", exists: { _ in true }, idForIdentity: none, unbound: "unbound"),
                     "普通楼层走原来的规则")
        XCTAssertEqual(FolderFloor.hubForNewConversation(profileId: "g", exists: { $0 == "h1" }, idForIdentity: none, unbound: "unbound"), "h1")
        XCTAssertEqual(FolderFloor.hubForNewConversation(profileId: "g", exists: { _ in false }, idForIdentity: { $0 == "i1" ? "h9" : nil }, unbound: "unbound"), "h9",
                       "本机 id 对不上（恢复备份 / 换设备）但身份相同的那台在 → 认回来")
        XCTAssertEqual(FolderFloor.hubForNewConversation(profileId: "g", exists: { _ in false }, idForIdentity: none, unbound: "unbound"), "unbound",
                       "那台不在了 → 待绑定，不回落到别的电脑")
    }

    // MARK: 选择页

    func testHubChoice() {
        XCTAssertEqual(FolderFloor.choice(connected: false, hello: nil), .offline)
        XCTAssertEqual(FolderFloor.choice(connected: false, hello: HubHello(hostName: "x")), .offline, "没连上时上次的 hello 不作数")
        XCTAssertEqual(FolderFloor.choice(connected: true, hello: HubHello(hostName: "x")), .notFolder)
        var hello = HubHello(hostName: "x")
        hello.folder = .init(path: "/Users/susu/Desktop/garden", accounts: [])
        XCTAssertEqual(FolderFloor.choice(connected: true, hello: hello), .folder(path: "/Users/susu/Desktop/garden"))
    }

    func testDisplayPath() {
        XCTAssertEqual(FolderFloor.displayPath("/Users/susu/Desktop/garden"), "~/Desktop/garden")
        XCTAssertEqual(FolderFloor.displayPath("/Users/susu"), "~")
        XCTAssertEqual(FolderFloor.displayPath("/opt/work"), "/opt/work")
    }

    // MARK: hello

    func testHelloParsesFolderModeAndAccounts() throws {
        let hello = try XCTUnwrap(HubHello(frame: [
            "type": "hello", "host_name": "mimiair", "mode": "folder", "folder": "/Users/susu/Desktop/garden",
            "accounts": [["id": "default", "label": "默认"], ["id": "xiao", "label": "🍆"], ["id": ""], "junk"],
        ]))
        XCTAssertEqual(hello.folder?.path, "/Users/susu/Desktop/garden")
        XCTAssertEqual(hello.folder?.accounts, [.init(id: "default", label: "默认"), .init(id: "xiao", label: "🍆")], "坏条目丢掉")
    }

    func testHelloWithoutFolderModeIsNotAFolder() throws {
        XCTAssertNil(try XCTUnwrap(HubHello(frame: ["type": "hello", "host_name": "mimiair"])).folder, "主 hub / 老 hub 不报")
        XCTAssertNil(try XCTUnwrap(HubHello(frame: ["type": "hello", "mode": "folder"])).folder, "说是文件夹模式却没给路径 → 当没说")
        XCTAssertNil(try XCTUnwrap(HubHello(frame: ["type": "hello", "folder": "/x"])).folder, "没说 mode → 不算")
    }

    // MARK: 发消息帧

    func testSendFrameCarriesAccountOnlyWhenGiven() {
        let with = CCBridgeWebSocketClient.sendFrame(chatId: "c", messageId: "m", content: "hi", user: "u",
                                                     session: "mp-cc-1", replyTo: nil, attachments: [], account: "xiao")
        XCTAssertEqual(with["account"] as? String, "xiao")
        let without = CCBridgeWebSocketClient.sendFrame(chatId: "c", messageId: "m", content: "hi", user: "u",
                                                        session: "mp-cc-1", replyTo: nil, attachments: [])
        XCTAssertNil(without["account"], "普通楼层的帧和原来逐字一样")
        let empty = CCBridgeWebSocketClient.sendFrame(chatId: "c", messageId: "m", content: "hi", user: "u",
                                                      session: "mp-cc-1", replyTo: nil, attachments: [], account: "")
        XCTAssertNil(empty["account"])
    }

    // MARK: 被拦下以后等待泡要清（11-17 走查发现：账号启动检查秒退，hub 的阶段帧只精确到秒，等待泡一直转）

    @MainActor
    func testWaitingBubbleClearsWhenTurnSettlesWithinTheSameSecond() {
        let vm = ConversationViewModel()
        let sent = Date(timeIntervalSince1970: 1_800_000_000.8)   // 这一秒的后半段发出
        let sameSecond = Date(timeIntervalSince1970: 1_800_000_000)   // 帧里的时间：同一秒，没有小数

        vm.ccWaitingSince["c1"] = sent
        vm.ccWaitingHub["c1"] = "h1"
        vm.ccTurnSettled(chatId: "c1", hubId: "h1", settledAt: sameSecond)
        XCTAssertNil(vm.ccWaitingSince["c1"], "刚发出就被拦下（同一秒收口）：等待泡清掉")

        vm.ccWaitingSince["c2"] = sent
        vm.ccWaitingHub["c2"] = "h1"
        vm.ccTurnSettled(chatId: "c2", hubId: "h1", settledAt: sameSecond.addingTimeInterval(-1))
        XCTAssertNotNil(vm.ccWaitingSince["c2"], "上一秒的旧收口帧（重连重放）不清她刚发的等待；不往后多容一秒")
        vm.ccTurnSettled(chatId: "c2", hubId: "other", settledAt: sameSecond.addingTimeInterval(5))
        XCTAssertNotNil(vm.ccWaitingSince["c2"], "别的电脑的帧不清")
        vm.ccTurnSettled(chatId: "c2", hubId: "h1", settledAt: sameSecond.addingTimeInterval(3))
        XCTAssertNil(vm.ccWaitingSince["c2"], "正常：几秒后收口，清掉")
    }

    // MARK: 发消息带账号：认「这一层连的那台」（kimi P1 审 #7）

    func testAccountSentWhenHubMatchesByIdOrIdentity() {
        let link = FolderFloor.Link(hubId: "h1", hubIdentity: "i1", account: "xiao")
        XCTAssertEqual(FolderFloor.account(link: link, conversationHubId: "h1", conversationHubIdentity: nil), "xiao")
        XCTAssertEqual(FolderFloor.account(link: link, conversationHubId: "h9", conversationHubIdentity: "i1"), "xiao",
                       "那台在本机换了 id、按身份认回去的对话也带")
        XCTAssertNil(FolderFloor.account(link: link, conversationHubId: "h9", conversationHubIdentity: "other"), "发给别的电脑的不带")
        XCTAssertNil(FolderFloor.account(link: .init(hubId: "h1", hubIdentity: nil, account: "xiao"), conversationHubId: "h9", conversationHubIdentity: nil),
                     "两边都没有身份不算相同")
        XCTAssertNil(FolderFloor.account(link: .init(hubId: "h1", hubIdentity: "", account: "xiao"), conversationHubId: "h9", conversationHubIdentity: ""),
                     "两边身份都是空串也不算相同")
        XCTAssertNil(FolderFloor.account(link: nil, conversationHubId: "h1", conversationHubIdentity: "i1"), "普通楼层不带")
        XCTAssertNil(FolderFloor.account(link: .init(hubId: "h1", hubIdentity: "i1", account: nil), conversationHubId: "h1", conversationHubIdentity: "i1"),
                     "没选账号 = 用那台默认的，不带")
    }

    // MARK: 同步的读写本身也挡（kimi P1 审 #4）

    @MainActor
    func testSyncPrimitivesDoNothingForFolderFloor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-sync-test-\(UUID().uuidString)")
        SyncStore.overrideRoot = root
        let id = "xctest-folder-sync-prim-\(UUID().uuidString)"
        defer {
            SyncStore.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
            SyncStoreTests.wipeLocalSyncState(pid: id)
        }
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let conversation = Conversation(id: "c-\(id)", title: "连上之前", createTime: Date(), updateTime: Date(), currentNodeId: "", provider: "api", profileId: id)
        context.insert(conversation)
        try context.save()
        let docs = { (try? FileManager.default.contentsOfDirectory(atPath: SyncStore.syncRoot(profileId: id)!.path))?.count ?? 0 }

        // 对照：还是普通楼层时，同一套夹具确实会导出一份文档（不然下面的 0 什么都证明不了）
        XCTAssertEqual(SyncStore.exportChanged(profileId: id, context: context).exported, 1)
        XCTAssertEqual(docs(), 1)

        FolderFloor.refresh([floor(id, hub: "h1")])
        conversation.title = "连上之后"
        conversation.updateTime = Date().addingTimeInterval(60)
        try context.save()
        let exported = SyncStore.exportChanged(profileId: id, context: context)
        XCTAssertEqual(exported.scanned, 0, "不扫、不导出")
        XCTAssertEqual(exported.exported, 0)
        XCTAssertEqual(docs(), 1, "云上原来那份不动，也不多出新的")

        // 云上那份还是「连上之前」：导入要是没挡住，会被扫到
        XCTAssertEqual(SyncStore.importAll(profileId: id, context: context).documentsScanned, 0)
        XCTAssertEqual(conversation.title, "连上之后")
        FolderFloor.refresh([])
        XCTAssertEqual(SyncStore.importAll(profileId: id, context: context).documentsScanned, 1, "对照：不连了以后同一份文档扫得到")
    }

    // MARK: 开窗纸条：这一层默认不弹，她的开关照旧管用（粟粟 11-17「默认关，反正有开关」）

    func testOpenWindowNoteDefaultsOffForFolderFloorButHerSwitchWins() {
        let suite = "xctest-folder-note-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        FolderFloor.refresh([floor("plain"), floor("g", hub: "h1")])

        XCTAssertTrue(MemoryOpenWindowNote.enabled(profileId: "plain", defaults: d), "普通楼层没设过 = 弹")
        XCTAssertFalse(MemoryOpenWindowNote.enabled(profileId: "g", defaults: d), "连着电脑文件夹的楼层没设过 = 不弹")

        MemoryOpenWindowNote.set(true, profileId: "g", defaults: d)
        XCTAssertTrue(MemoryOpenWindowNote.enabled(profileId: "g", defaults: d), "她打开了就弹")
        MemoryOpenWindowNote.set(false, profileId: "plain", defaults: d)
        XCTAssertFalse(MemoryOpenWindowNote.enabled(profileId: "plain", defaults: d), "普通楼层她关了的照旧不弹")

        FolderFloor.refresh([floor("plain"), floor("g")])
        XCTAssertTrue(MemoryOpenWindowNote.enabled(profileId: "g", defaults: d), "不连了：她设过的值还在")
    }

    // MARK: 背后关掉的几样

    func testSyncNeverOnForFolderFloor() {
        let id = "xctest-folder-sync-\(UUID().uuidString)"
        SyncStore.setEnabled(true, profileId: id)
        defer { SyncStore.setEnabled(false, profileId: id) }
        guard SyncStore.isEnabled(profileId: id) else { return }   // 本机开着本地模式 / 基准隔离时本来就恒关，没法对比
        FolderFloor.refresh([floor(id, hub: "h1")])
        XCTAssertFalse(SyncStore.isEnabled(profileId: id), "连着文件夹的楼层：开关开着也不同步")
        FolderFloor.refresh([])
        XCTAssertTrue(SyncStore.isEnabled(profileId: id), "不连了就恢复她原来的开关")
    }
}
