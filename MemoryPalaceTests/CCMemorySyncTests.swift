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
        // 与 hub isPrivateName、种子同一条：文件名以 private_ 开头，不分大小写
        for name in ["private_diary_key.md", "private_anything.md", "PRIVATE_x.md", "Private_y.md", "sub/private_z.md"] {
            XCTAssertTrue(CCMemorySync.isExcluded(name: name), name)
        }
        // 名字带日记的照常同步（要挡哪份写进 hub 名单），只看名字不看内容
        for name in ["my_Diary.md", "岚舟的日记本.md", "project_beacon_penpals.md", "privately.md",
                     "note_PRIVATE_z.md", "project_private_repo_direction.md", "project_private_x.md", "note_private_y.md"] {
            XCTAssertFalse(CCMemorySync.isExcluded(name: name), name)
        }
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

    func testParseManifestDropsPrivateNamesSoTheyAreNeverFetched() {
        let r = CCMemorySync.parseManifest(["ok": true, "files": [
            ["name": "a.md", "sha256": "h1"], ["name": "PRIVATE_b.md", "sha256": "h2"], ["name": "Private_c.md", "sha256": "h3"],
            ["name": "project_private_d.md", "sha256": "h4"],
        ]])
        XCTAssertEqual(r, [CCMemorySync.RemoteEntry(name: "a.md", sha256: "h1"), CCMemorySync.RemoteEntry(name: "project_private_d.md", sha256: "h4")])
    }

    func testLocalHashesNeverReadsPrivateOrLinkedFilesButStillListsThemForDeletion() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cc-local-\(UUID().uuidString)")
        let outside = fm.temporaryDirectory.appendingPathComponent("cc-local-outside-\(UUID().uuidString).md")
        defer { try? fm.removeItem(at: dir); try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "岚舟".write(to: dir.appendingPathComponent("ok.md"), atomically: true, encoding: .utf8)
        for name in ["private_x.md", "PRIVATE_y.md", "Private_z.md"] {
            try "SYNTH_PRIVATE_MARKER".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "SYNTH_OUTSIDE_MARKER".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link.md"), withDestinationURL: outside)
        var opened: [String] = []
        let hashes = CCMemorySync.localHashes(dir: dir) { url in
            opened.append(url.lastPathComponent)
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(opened, ["ok.md"], "私人文件、符号链接一次都不读")
        XCTAssertEqual(Set(hashes.keys), ["ok.md", "private_x.md", "PRIVATE_y.md", "Private_z.md", "link.md"])
        let todo = CCMemorySync.diff(remote: [.init(name: "ok.md", sha256: hashes["ok.md"]!), .init(name: "link.md", sha256: "h")], local: hashes)
        XCTAssertEqual(todo.delete, ["PRIVATE_y.md", "Private_z.md", "private_x.md"], "本地多出来的私人文件按名字删")
        XCTAssertEqual(todo.fetch, ["link.md"], "本地是链接的重取，写回时换成普通文件")
    }

    func testReadNoFollowRefusesLinksDirectoriesAndFifos() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cc-nofollow-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
        try "星砚".write(to: dir.appendingPathComponent("plain.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link.md"), withDestinationURL: dir.appendingPathComponent("plain.md"))
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("pipe.md").path, 0o600), 0)
        XCTAssertEqual(try CCMemorySync.readNoFollow(dir.appendingPathComponent("plain.md")), "星砚")
        for name in ["link.md", "folder.md", "pipe.md"] {
            XCTAssertThrowsError(try CCMemorySync.readNoFollow(dir.appendingPathComponent(name)), name)
        }
    }

    func testLocalScanSwappedToLinkIsNotReadAndDirectoriesAreNeverDeleted() throws {
        enableForTestFloor()
        let fm = FileManager.default
        let dir = CCMemorySync.directory(profileId: pid)
        let outside = fm.temporaryDirectory.appendingPathComponent("cc-del-outside-\(UUID().uuidString).md")
        defer { try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: dir.appendingPathComponent("archive.md"), withIntermediateDirectories: true)
        try "留着".write(to: dir.appendingPathComponent("archive.md/keep.txt"), atomically: true, encoding: .utf8)
        try "SYNTH_PRIVATE_MARKER".write(to: dir.appendingPathComponent("private_x.md"), atomically: true, encoding: .utf8)
        for name in ["stale.md", "swap.md", "PRIVATE_y.md"] {
            try "旧".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "外面".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link.md"), withDestinationURL: outside)

        var read: [String] = []
        let hashes = CCMemorySync.localHashes(dir: dir) { url in
            if url.lastPathComponent == "swap.md" {   // 列名字时还是普通文件，读之前一刻换成指向私人文件的链接
                try fm.removeItem(at: url)
                try fm.createSymbolicLink(at: url, withDestinationURL: dir.appendingPathComponent("private_x.md"))
            }
            let text = try CCMemorySync.readNoFollow(url)
            read.append(url.lastPathComponent)
            return text
        }
        XCTAssertEqual(read, ["stale.md"], "换成链接的那份没读出来")
        XCTAssertEqual(hashes["swap.md"], "")
        XCTAssertNil(hashes["archive.md"], "目录不进删除候选")

        CCMemorySync.handleManifest(["ok": true, "files": []])
        let left = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["archive.md"], "清单为空：普通文件、链接、私人文件都按名字删，目录不动")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("archive.md/keep.txt"), encoding: .utf8), "留着")
        XCTAssertTrue(fm.fileExists(atPath: outside.path), "删的是链接本身，不是链接目标")
        CCMemorySync.removeFileOrLink(dir.appendingPathComponent("archive.md"))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("archive.md/keep.txt").path))
    }

    /// hub → app → 种子：拿 hub 测试逐字核过的快照（fixtures/cc-memory-sync/pipeline.json 的 expected）当 hub 发来的清单和文件，
    /// 再把 leaked 当成 hub 漏发的私人文件一起塞进来；app 落盘后种子读，标记一个都不能出现，私人文件一次都不打开
    func testSyntheticHubToAppToSeedPipeline() throws {
        struct Pipeline: Decodable { let expected: [String: String]; let leaked: [String: String]; let markers: [String] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/cc-memory-sync/pipeline.json")
        let p = try JSONDecoder().decode(Pipeline.self, from: Data(contentsOf: url))
        enableForTestFloor()
        let sent = p.expected.merging(p.leaked) { a, _ in a }
        let remote = CCMemorySync.parseManifest(["ok": true, "files": sent.map { ["name": $0.key, "sha256": FileLibraryStore.sha256Hex(Data($0.value.utf8))] }])
        let dir = CCMemorySync.directory(profileId: pid)
        let todo = CCMemorySync.diff(remote: try XCTUnwrap(remote), local: CCMemorySync.localHashes(dir: dir))
        XCTAssertEqual(Set(todo.fetch), Set(p.expected.keys), "漏发的私人文件不进要取的名单")
        CCMemorySync.handleFiles(["files": sent.map { ["name": $0.key, "content": $0.value] }])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), Set(p.expected.keys))
        XCTAssertEqual(CCMemorySync.localHashes(dir: dir), remote?.reduce(into: [String: String]()) { $0[$1.name] = $1.sha256 }, "落盘后哈希与 hub 同口径，不会反复重取")

        var opened: [String] = []
        let scan = try CatalogSeed.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) { url in
            opened.append(url.lastPathComponent)
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(Set(opened), Set(p.expected.keys))
        XCTAssertEqual(Set(scan.sources.map(\.name)), Set(p.expected.keys))
        let seen = (scan.sources.map { $0.title + $0.body } + scan.notes + scan.skipped).joined(separator: "\n")
        for marker in p.markers { XCTAssertFalse(seen.contains(marker), marker) }
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
            ["name": "project_lanzhou_diary.md", "content": md("岚舟日记本", "钥匙存日记本的项目")],   // 名字带日记照常落
            ["name": "../escape.md", "content": "x"],
        ]])
        let dir = CCMemorySync.directory(profileId: pid)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.sorted(), ["project_lanzhou_diary.md", "project_theater.md"])
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
