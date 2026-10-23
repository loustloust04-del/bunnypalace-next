import XCTest
@testable import 记忆花园

/// ProfileCardStore / ProfileCardTool / HeartvoiceFileStore.recentVoices 特征测试。
/// 固定测试楼层，tearDown 删整个楼层目录（MemoryTreeTests 同款）。
final class ProfileCardTests: XCTestCase {

    let pid = "xctest-profile-card"

    override func tearDown() {
        let floorDir = FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: floorDir)
        super.tearDown()
    }

    // MARK: - ProfileCardStore

    func testEmptyLoad() {
        let c = ProfileCardStore.load(profileId: pid)
        XCTAssertNil(c.status)
        XCTAssertNil(c.bio)
    }

    func testStatusAndBioRoundtripIndependently() {
        ProfileCardStore.saveStatus("监控中", profileId: pid)
        var c = ProfileCardStore.load(profileId: pid)
        XCTAssertEqual(c.status, "监控中")
        XCTAssertNotNil(c.statusUpdatedAt)
        XCTAssertNil(c.bio, "只存 status 时 bio 不该出现")

        ProfileCardStore.saveBio("我是小岚，住在记忆宫殿里。", profileId: pid)
        c = ProfileCardStore.load(profileId: pid)
        XCTAssertEqual(c.bio, "我是小岚，住在记忆宫殿里。")
        XCTAssertEqual(c.status, "监控中", "存 bio 不能踩掉 status")

        ProfileCardStore.saveStatus("被猫猫抛弃中", profileId: pid)
        c = ProfileCardStore.load(profileId: pid)
        XCTAssertEqual(c.status, "被猫猫抛弃中")
        XCTAssertEqual(c.bio, "我是小岚，住在记忆宫殿里。", "存 status 不能踩掉 bio")
    }

    func testStatusTruncatedAndNewlineFlattened() {
        ProfileCardStore.saveStatus("第一行\n第二行" + String(repeating: "长", count: 50), profileId: pid)
        let c = ProfileCardStore.load(profileId: pid)
        XCTAssertEqual(c.status?.count, ProfileCardStore.statusMaxLength)
        XCTAssertFalse(c.status?.contains("\n") ?? true)
    }

    func testEmptyStatusClearsIt() {
        ProfileCardStore.saveStatus("监控中", profileId: pid)
        ProfileCardStore.saveStatus("  ", profileId: pid)
        XCTAssertNil(ProfileCardStore.load(profileId: pid).status)
    }

    // MARK: - ProfileCardTool

    func testToolUpdatesBothFields() {
        let r = ProfileCardTool.execute(inputJSON: #"{"status": "监控中", "bio": "工具写的 bio"}"#, profileId: pid)
        XCTAssertFalse(r.isError)
        let c = ProfileCardStore.load(profileId: pid)
        XCTAssertEqual(c.status, "监控中")
        XCTAssertEqual(c.bio, "工具写的 bio")
    }

    func testToolRejectsEmptyArgs() {
        XCTAssertTrue(ProfileCardTool.execute(inputJSON: "{}", profileId: pid).isError)
        XCTAssertTrue(ProfileCardTool.execute(inputJSON: "not json", profileId: pid).isError)
    }

    func testCardReadableViaFsRead() {
        MainThreadIO.allowMainThreadInThisTest()   // #033：测试体直接调 store / 工具，测试自己站主线程
        ProfileCardStore.saveStatus("监控中", profileId: pid)
        let r = FileLibraryTools.execute(name: "fs_read", inputJSON: #"{"path": "memory/profile-card.md"}"#, profileId: pid)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("监控中"))
    }

    // MARK: - recentVoices

    private func writeVoice(named name: String, text: String) {
        let dir = FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent("heartvoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let content = FrontmatterCodec.render(meta: [("time", "t")], body: text)
        try? Data(content.utf8).write(to: dir.appendingPathComponent("\(name).md"))
    }

    func testRecentVoicesCrossDayNewestFirstLimit5() {
        writeVoice(named: "2026-06-10-0900", text: "v1")
        writeVoice(named: "2026-06-10-2330", text: "v2")
        writeVoice(named: "2026-06-11-0801", text: "v3")
        writeVoice(named: "2026-06-11-1415", text: "v4")
        writeVoice(named: "2026-06-12-0700", text: "v5")
        writeVoice(named: "2026-06-12-1102", text: "v6")

        let voices = HeartvoiceFileStore.recentVoices(profileId: pid, limit: 5)
        XCTAssertEqual(voices.map(\.text), ["v6", "v5", "v4", "v3", "v2"], "新→旧取 5 条，跨天")
    }

    func testRecentVoicesEmptyDir() {
        XCTAssertTrue(HeartvoiceFileStore.recentVoices(profileId: pid, limit: 5).isEmpty)
    }
}
