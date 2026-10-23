import XCTest
@testable import 记忆花园

/// CC 小克 memory 同步（plan-cc-memory-sync）：排除兜底、增量比对、删除跟随、落盘 + fs 工具只读可翻。
/// 用固定测试楼层 id，tearDown 删整个楼层目录并复原开关。
final class CCMemorySyncTests: XCTestCase {

    let pid = "xctest-cc-memory-sync"
    private let keys = [CCMemorySync.enabledKey, CCMemorySync.profileKey, CCMemorySync.lastSyncKey, CCMemorySync.lastCountKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        for k in keys { if let v = d.object(forKey: k) { saved[k] = v }; d.removeObject(forKey: k) }
    }

    override func tearDown() {
        let floorDir = FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: floorDir)
        let d = UserDefaults.standard
        for k in keys { d.removeObject(forKey: k) }
        for (k, v) in saved { d.set(v, forKey: k) }
        super.tearDown()
    }

    private func md(_ name: String, _ desc: String, _ body: String = "正文") -> String {
        "---\nname: \(name)\ndescription: \(desc)\ntype: project\n---\n\n\(body)\n"
    }

    private func enableForTestFloor() {
        UserDefaults.standard.set(true, forKey: CCMemorySync.enabledKey)
        UserDefaults.standard.set(pid, forKey: CCMemorySync.profileKey)
    }

    // MARK: - 纯函数

    func testExclusionMatchesHubRules() {
        XCTAssertTrue(CCMemorySync.isExcluded(name: "private_diary_key.md", content: md("钥匙", "x")))
        XCTAssertTrue(CCMemorySync.isExcluded(name: "my_Diary.md", content: md("a", "b")))
        XCTAssertTrue(CCMemorySync.isExcluded(name: "x.md", content: md("小克的日记本", "b")))
        XCTAssertTrue(CCMemorySync.isExcluded(name: "x.md", content: md("a", "加密 diary 钥匙")))
        // 粟粟 D2：正文里只是提到日记，照常同步
        XCTAssertFalse(CCMemorySync.isExcluded(name: "project_beacon_penpals.md", content: md("BEACON笔友", "AI留言墙", "钥匙存日记本")))
    }

    func testSafeNames() {
        XCTAssertTrue(CCMemorySync.isSafeName("feedback_x.md"))
        XCTAssertFalse(CCMemorySync.isSafeName("../escape.md"))
        XCTAssertFalse(CCMemorySync.isSafeName("a/b.md"))
        XCTAssertFalse(CCMemorySync.isSafeName(".hidden.md"))
        XCTAssertFalse(CCMemorySync.isSafeName("notes.txt"))
    }

    func testParseManifestRejectsFailuresAndUnsafeNames() {
        XCTAssertNil(CCMemorySync.parseManifest(["ok": false, "files": []]))
        let r = CCMemorySync.parseManifest(["ok": true, "files": [
            ["name": "a.md", "sha256": "h1"], ["name": "../b.md", "sha256": "h2"], ["name": "c.md"],
        ]])
        XCTAssertEqual(r, [CCMemorySync.RemoteEntry(name: "a.md", sha256: "h1")])
    }

    func testDiffFetchesChangedAndNewDeletesGone() {
        let remote = [CCMemorySync.RemoteEntry(name: "same.md", sha256: "s"),
                      CCMemorySync.RemoteEntry(name: "changed.md", sha256: "new"),
                      CCMemorySync.RemoteEntry(name: "added.md", sha256: "a")]
        let local = ["same.md": "s", "changed.md": "old", "gone.md": "g"]
        let d = CCMemorySync.diff(remote: remote, local: local)
        XCTAssertEqual(Set(d.fetch), ["changed.md", "added.md"])
        XCTAssertEqual(d.delete, ["gone.md"])
    }

    func testWrapUnwrapKeepsHashOfOriginal() {
        let original = md("剧场", "猫狗剧场")
        let wrapped = CCMemorySync.wrap(original, at: Date())
        XCTAssertTrue(wrapped.hasPrefix(CCMemorySync.headerPrefix))
        XCTAssertEqual(CCMemorySync.unwrap(wrapped), original)
        XCTAssertEqual(CCMemorySync.unwrap(original), original, "没有头注释的原样返回")
    }

    func testPromptHintOnlyForTargetFloorWhenEnabled() {
        XCTAssertEqual(CCMemorySync.promptHint(profileId: pid), "", "默认关")
        enableForTestFloor()
        XCTAssertTrue(CCMemorySync.promptHint(profileId: pid).contains("memory/cc/"))
        XCTAssertEqual(CCMemorySync.promptHint(profileId: "other-floor"), "", "别的楼层不提")
    }

    // MARK: - 落盘 + 哈希回读 + fs 工具

    func testHandleFilesWritesAndLocalHashMatchesHub() throws {
        enableForTestFloor()
        let content = md("剧场", "猫狗剧场", "雷雨那场")
        CCMemorySync.handleFiles(["files": [
            ["name": "project_theater.md", "content": content],
            ["name": "private_diary_key.md", "content": md("钥匙", "x")],   // hub 不该发，发了也不落
            ["name": "../escape.md", "content": "x"],
        ]])
        let dir = CCMemorySync.directory(profileId: pid)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["project_theater.md"])
        let hashes = CCMemorySync.localHashes(dir: dir)
        XCTAssertEqual(hashes["project_theater.md"], FileLibraryStore.sha256Hex(Data(content.utf8)), "与 hub 同口径（去头注释后的原文）")
    }

    func testDisabledIgnoresFrames() throws {
        UserDefaults.standard.set(pid, forKey: CCMemorySync.profileKey)
        CCMemorySync.handleFiles(["files": [["name": "a.md", "content": "x"]]])
        let names = (try? FileManager.default.contentsOfDirectory(atPath: CCMemorySync.directory(profileId: pid).path)) ?? []
        XCTAssertTrue(names.isEmpty, "开关关着不落盘")
    }

    func testSyncedFilesSearchableButReadOnlyForAI() {
        MainThreadIO.allowMainThreadInThisTest()   // #033：测试体直接调 store / 工具，测试自己站主线程
        enableForTestFloor()
        CCMemorySync.handleFiles(["files": [["name": "project_theater.md", "content": md("剧场", "猫狗剧场", "雷雨那场")]]])
        let search = FileLibraryTools.execute(name: "fs_search", inputJSON: #"{"keyword": "雷雨那场"}"#, profileId: pid)
        XCTAssertTrue(search.text.contains("memory/cc/project_theater.md"), search.text)
        let write = FileLibraryTools.execute(name: "fs_write", inputJSON: #"{"path": "memory/cc/project_theater.md", "content": "hack"}"#, profileId: pid)
        XCTAssertTrue(write.isError)
    }

    func testRemoveLocalDeletesFolder() {
        enableForTestFloor()
        CCMemorySync.handleFiles(["files": [["name": "a.md", "content": md("a", "b")]]])
        CCMemorySync.removeLocal(profileId: pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CCMemorySync.directory(profileId: pid).path))
    }
}
