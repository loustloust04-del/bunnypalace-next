import XCTest
import ZIPFoundation
@testable import 记忆花园

/// 卡库 ⑧a／⑧b：酒馆整包只读盘点 + 纯解析关联。全部合成夹具，不碰 app 存储。
final class SillyTavernImportTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("st-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - 夹具

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func jsonl(_ lines: [Any]) -> Data {
        Data(lines.map { line -> String in
            if let raw = line as? String { return raw }
            return String(decoding: json(line), as: UTF8.self)
        }.joined(separator: "\n").utf8)
    }

    /// 最小 PNG 卡：签名 + tEXt(chara) + IEND（解析器不验 CRC）
    private func pngCard(_ card: [String: Any]) -> Data {
        func chunk(_ type: String, _ body: Data) -> Data {
            var out = Data()
            var length = UInt32(body.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            out.append(Data(type.utf8))
            out.append(body)
            out.append(Data(count: 4))
            return out
        }
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(chunk("tEXt", Data("chara".utf8) + Data([0]) + Data(json(card).base64EncodedString().utf8)))
        data.append(chunk("IEND", Data()))
        return data
    }

    /// 主角色聊天：header + 7 条消息 + 1 坏行（第 4 行）
    private var aliceChat: Data {
        jsonl([
            ["user_name": "unused", "character_name": "unused", "chat_metadata": ["persona": "me.png", "world_info": "Lore", "attachments": [["url": "x"]]]],
            ["name": "Alice", "is_user": false, "is_system": false, "send_date": "2025-06-03T07:24:12.123Z", "mes": "A1 显示版",
             "swipes": ["A0", "A1 源", "A2"], "swipe_id": 1, "swipe_info": [[:], ["send_date": "2025-06-03T07:25:00.000Z"], [:]],
             "variables": [["hp": 1]], "hash_sheets": ["s": 1], "tableEditMatches": [], "extra": ["reasoning": "r"]],
            ["name": "U", "is_user": true, "send_date": "2025-06-03T07:26:00.000Z", "mes": "问", "extra": ["files": [["url": "f"]]]],
            "{not json",
            ["name": "Alice", "is_user": false, "mes": "M", "swipes": ["X", "M"], "swipe_id": 7, "swipe_info": [[:], [:]], "extra": [:]],
            ["name": "Alice", "is_user": false, "mes": "ZZ", "swipes": ["P", "Q"], "swipe_id": -1, "extra": [:]],
            ["name": "System", "is_user": false, "is_system": true, "mes": "被隐藏", "extra": [:]],
            ["name": "旁白", "is_user": false, "is_system": false, "mes": "旁白", "extra": ["type": "narrator"]],
            ["name": "System", "is_user": false, "is_system": true, "mes": "帮助", "extra": ["type": "help"]],
        ])
    }

    /// 一个最小但各类都有的 default-user 目录内容（相对路径 → 字节）
    private var packageFiles: [String: Data] {
        let helperCard: [String: Any] = [
            "spec": "chara_card_v2",
            "data": ["name": "Alice", "first_mes": "hi", "alternate_greetings": ["hey"],
                     "character_book": ["entries": [["keys": ["k"], "content": "c", "enabled": true, "insertion_order": 1]]],
                     "extensions": ["world": "Lore", "regex_scripts": [["scriptName": "r", "findRegex": "/a/g", "replaceString": "b"]],
                                    "tavern_helper": [["scripts", [["name": "s"]]], ["variables", [:]]]]],
        ]
        return [
            "settings.json": json([
                "power_user": ["personas": ["me.png": "我"], "persona_descriptions": ["me.png": ["description": "d", "lorebook": "Lore"]]],
                "extension_settings": ["regex": [["scriptName": "g", "findRegex": "/x/", "replaceString": "y"]],
                                       "character_attachments": ["Alice.png": [["url": "a"]]]],
                "world_info_settings": ["world_info": ["globalSelect": ["Lore"], "charLore": [["name": "Alice.png", "extraBooks": ["Missing"]]]]],
            ]),
            "secrets.json": Data(#"{"api_key_openai":"SECRET-SHOULD-NOT-BE-READ"}"#.utf8),
            "characters/Alice.png": pngCard(helperCard),
            "characters/Bob.json": json(["spec": "chara_card_v2", "data": ["name": "Bob", "first_mes": "yo",
                                                                            "extensions": ["TavernHelper_scripts": []]]]),
            "characters/Alice/expression.png": Data([1, 2, 3]),
            "chats/Alice/Alice - 1.jsonl": aliceChat,
            "chats/Alice/Alice - 2.jsonl": jsonl([["chat_metadata": [:], "user_name": "u", "character_name": "c"]]),
            "chats/Ghost/Ghost - 1.jsonl": jsonl([["chat_metadata": [:]], ["name": "Ghost", "is_user": false, "mes": "boo"]]),
            "worlds/Lore.json": json(["entries": ["0": ["uid": 0, "key": ["a"], "content": "x"]]]),
            "OpenAI Settings/P1.json": json(["temperature": 1, "prompts": [["identifier": "main", "name": "Main", "content": "m"]],
                                             "extensions": ["regex_scripts": [["scriptName": "pr", "findRegex": "/p/", "replaceString": "q"]]]]),
            "QuickReplies/qr.json": json(["name": "qr", "qrList": []]),
            "User Avatars/me.png": Data([9]),
            "user/files/note.txt": Data("n".utf8),
            "user/images/Alice/pic.jpeg": Data([7]),
            "backups/chat_Alice_1.jsonl": Data("{}".utf8),
            "extensions/plugin/index.js": Data("alert(1)".utf8),
            "themes/t.json": Data("{}".utf8),
            "groups/g1.json": json(["id": "g1", "name": "群", "members": ["Alice.png", "Bob.json"], "chats": ["gc1", "gc2"], "chat_id": "gc2"]),
            "group chats/gc1.jsonl": jsonl([["chat_metadata": [:], "user_name": "u"], ["name": "Alice", "is_user": false, "mes": "群1"]]),
            "group chats/gc2.jsonl": jsonl([["name": "Bob", "is_user": false, "mes": "旧格式无 header"], ["name": "U", "is_user": true, "mes": "嗯"]]),
        ]
    }

    private func writeTree(_ root: URL, _ files: [String: Data]) throws {
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    private func makeZip(_ name: String, prefix: String = "", files: [String: Data], symlinks: [String: String] = [:],
                         compression: CompressionMethod = .none) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: prefix + path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: compression) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        for (path, target) in symlinks {
            let data = Data(target.utf8)
            try archive.addEntry(with: prefix + path, type: .symlink, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    private func staging() -> URL {
        let url = workDir.appendingPathComponent("staging-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertRejects(_ source: URL, limits: SillyTavernPackageLimits = .standard,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ check: (SillyTavernPackageError) -> Bool) {
        let parent = staging()
        XCTAssertThrowsError(try SillyTavernPackageParser.snapshot(source: source, stagingParent: parent, limits: limits), file: file, line: line) { error in
            guard let error = error as? SillyTavernPackageError else { return XCTFail("错误类型不对：\(error)", file: file, line: line) }
            XCTAssertTrue(check(error), "拒绝原因不对：\(error)", file: file, line: line)
        }
        // 拒绝时不留半截 staging
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.count, 0, file: file, line: line)
    }

    // MARK: - ⑧a 三种包装 + 目录

    func testZipRootIsUserDirectory() throws {
        let plan = try SillyTavernPackageImporter.inventory(source: makeZip("root.zip", files: packageFiles), stagingParent: staging())
        defer { plan.snapshot.removeStaging() }
        XCTAssertEqual(plan.snapshot.sourceKind, .zip)
        XCTAssertEqual(plan.snapshot.rootPrefix, "")
        assertPackageNumbers(plan)
    }

    func testZipWithOneWrapperFolder() throws {
        // 包装层之外的 readme 不盘点
        let wrapped = Dictionary(uniqueKeysWithValues: packageFiles.map { ("default-user/" + $0.key, $0.value) })
            .merging(["readme.txt": Data("outside".utf8)]) { a, _ in a }
        let plan = try SillyTavernPackageImporter.inventory(source: makeZip("wrap.zip", files: wrapped), stagingParent: staging())
        defer { plan.snapshot.removeStaging() }
        XCTAssertEqual(plan.snapshot.rootPrefix, "default-user/")
        XCTAssertTrue(plan.snapshot.skipped.contains { $0.reason.contains("用户目录外 1 项") })
        assertPackageNumbers(plan)
    }

    func testZipWithDataDefaultUserFolders() throws {
        let plan = try SillyTavernPackageImporter.inventory(source: makeZip("data.zip", prefix: "data/default-user/", files: packageFiles),
                                                            stagingParent: staging())
        defer { plan.snapshot.removeStaging() }
        XCTAssertEqual(plan.snapshot.rootPrefix, "data/default-user/")
        assertPackageNumbers(plan)
    }

    func testDirectoryDefaultUserAndParentFolder() throws {
        let root = workDir.appendingPathComponent("st/data/default-user")
        try writeTree(root, packageFiles)
        let direct = try SillyTavernPackageImporter.inventory(source: root, stagingParent: staging())
        defer { direct.snapshot.removeStaging() }
        XCTAssertEqual(direct.snapshot.sourceKind, .directory)
        XCTAssertEqual(direct.snapshot.rootPrefix, "")
        assertPackageNumbers(direct)

        let parent = try SillyTavernPackageImporter.inventory(source: workDir.appendingPathComponent("st/data"), stagingParent: staging())
        defer { parent.snapshot.removeStaging() }
        XCTAssertEqual(parent.snapshot.rootPrefix, "default-user/")
        XCTAssertEqual(parent.summary, direct.summary)
        // 两条路得到的逐文件 hash 一致
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: parent.snapshot.entries.map { ($0.relativePath, $0.sha256) }),
                       Dictionary(uniqueKeysWithValues: direct.snapshot.entries.map { ($0.relativePath, $0.sha256) }))
    }

    func testNotAPackageAndAmbiguousRoot() throws {
        let other = try makeZip("other.zip", files: ["photos/a.jpg": Data([1])])
        assertRejects(other) { $0 == .notAPackage }
        let two = try makeZip("two.zip", files: ["a/settings.json": Data("{}".utf8), "b/settings.json": Data("{}".utf8)])
        assertRejects(two) { $0 == .ambiguousRoot(["a/", "b/"]) }
    }

    private func assertPackageNumbers(_ plan: SillyTavernPackagePlan, file: StaticString = #filePath, line: UInt = #line) {
        let s = plan.summary
        XCTAssertEqual(s.cards, 2, file: file, line: line)
        XCTAssertEqual(s.cardAssets, 1, "子目录图片不算卡", file: file, line: line)
        XCTAssertEqual(s.cardsWithHelperScripts, 1, "键值对数组形式的 tavern_helper.scripts；空的旧键不算", file: file, line: line)
        XCTAssertEqual(s.cardsWithRegex, 1, file: file, line: line)
        XCTAssertEqual(s.cardsWithBook, 1, file: file, line: line)
        XCTAssertEqual(s.chats, 3, file: file, line: line)
        XCTAssertEqual(s.placeholderCharacters, 1, file: file, line: line)
        XCTAssertEqual(s.messages, 8, file: file, line: line)
        XCTAssertEqual(s.badChatLines, 1, file: file, line: line)
        XCTAssertEqual(s.swipeGroups, 3, file: file, line: line)
        XCTAssertEqual(s.candidates, 7, file: file, line: line)
        XCTAssertEqual(s.contentNodes, 8 - 3 + 7, file: file, line: line)
        XCTAssertEqual(s.syntheticRoots, 2, "空聊天不建合成根", file: file, line: line)
        XCTAssertEqual(s.mesDiffers, 1, file: file, line: line)
        XCTAssertEqual(s.swipeIdOutOfRange, 2, file: file, line: line)
        XCTAssertEqual(s.worlds, 1, file: file, line: line)
        XCTAssertEqual(s.presets, 1, file: file, line: line)
        XCTAssertEqual(s.globalRegex, 1, file: file, line: line)
        XCTAssertEqual(s.presetRegex, 1, file: file, line: line)
        XCTAssertEqual(s.cardRegex, 1, file: file, line: line)
        XCTAssertEqual(s.quickReplies, 1, file: file, line: line)
        XCTAssertEqual(s.personas, 1, file: file, line: line)
        XCTAssertEqual(s.personaAvatars, 1, file: file, line: line)
        XCTAssertEqual(s.groups, 1, file: file, line: line)
        XCTAssertEqual(s.groupChats, 2, file: file, line: line)
        XCTAssertEqual(s.attachments, SillyTavernAttachmentCounts(userFiles: 1, userImages: 1, chatAttachmentRefs: 1, messageFileRefs: 1,
                                                                   messageMediaRefs: 0, globalDataBankRefs: 0, characterDataBankRefs: 1),
                       file: file, line: line)
        XCTAssertEqual(s.backups, 1, file: file, line: line)
        XCTAssertEqual(s.extensionFiles, 1, file: file, line: line)
        XCTAssertEqual(s.unknownFiles, 1, file: file, line: line)
        XCTAssertTrue(s.hasCredentials, file: file, line: line)
        XCTAssertEqual(s.fileCount, packageFiles.count, file: file, line: line)
        // 世界书引用：卡、聊天、persona、全局各指向 Lore；角色附加书 Missing 找不到
        XCTAssertEqual(s.worldBindings, 5, file: file, line: line)
        XCTAssertEqual(plan.worldBindings.filter { $0.resolvedPath == nil }.map(\.bookName), ["Missing"], file: file, line: line)
        XCTAssertTrue(plan.problems.contains { $0.relativePath == "secrets.json" && $0.reason == "含凭据，不导入" }, file: file, line: line)
    }

    // MARK: - ⑧a 安全

    func testSecretsNeitherCopiedNorHashed() throws {
        let plan = try SillyTavernPackageImporter.inventory(source: makeZip("s.zip", files: packageFiles), stagingParent: staging())
        defer { plan.snapshot.removeStaging() }
        let secret = try XCTUnwrap(plan.snapshot.entries.first { $0.relativePath == "secrets.json" })
        XCTAssertEqual(secret.category, .credentials)
        XCTAssertNil(secret.sha256)
        XCTAssertEqual(secret.size, Int64(packageFiles["secrets.json"]!.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.snapshot.url(for: "secrets.json").path))
        let staged = try FileManager.default.subpathsOfDirectory(atPath: plan.snapshot.stagingDirectory.path)
        for path in staged {
            let data = (try? Data(contentsOf: plan.snapshot.stagingDirectory.appendingPathComponent(path))) ?? Data()
            XCTAssertNil(data.range(of: Data("SECRET-SHOULD-NOT-BE-READ".utf8)), path)
        }
    }

    func testSnapshotIsReadOnlyCopyWithHashes() throws {
        let root = workDir.appendingPathComponent("du")
        try writeTree(root, packageFiles)
        let plan = try SillyTavernPackageImporter.inventory(source: root, stagingParent: staging())
        defer { plan.snapshot.removeStaging() }
        let entry = try XCTUnwrap(plan.snapshot.entries.first { $0.relativePath == "worlds/Lore.json" })
        XCTAssertEqual(entry.category, .world)
        XCTAssertEqual(entry.sha256?.count, 64)
        let attrs = try FileManager.default.attributesOfItem(atPath: plan.snapshot.url(for: entry.relativePath).path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o444)
        // 源目录未被改
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("worlds/Lore.json")), packageFiles["worlds/Lore.json"])
    }

    func testZipPathTraversalRejected() throws {
        var files = packageFiles
        files["../evil.txt"] = Data("x".utf8)
        assertRejects(try makeZip("trav.zip", files: files)) { $0 == .unsafePath("../evil.txt") }
        var nested = packageFiles
        nested["characters/../../evil.txt"] = Data("x".utf8)
        assertRejects(try makeZip("trav2.zip", files: nested)) { if case .unsafePath = $0 { return true }; return false }
        var absolute = packageFiles
        absolute["/etc/evil"] = Data("x".utf8)
        assertRejects(try makeZip("abs.zip", files: absolute)) { if case .unsafePath = $0 { return true }; return false }
    }

    func testZipSymlinkEscapingRejectedInsideSkipped() throws {
        assertRejects(try makeZip("link.zip", files: packageFiles, symlinks: ["characters/link.png": "../../../etc/passwd"])) {
            $0 == .unsafeSymlink("characters/link.png")
        }
        // 指到包装层外（但还在压缩包里）也算越界
        assertRejects(try makeZip("link2.zip", prefix: "default-user/", files: packageFiles,
                                  symlinks: ["chats/link": "../../outside.txt"])) { $0 == .unsafeSymlink("chats/link") }
        let ok = try SillyTavernPackageImporter.inventory(
            source: makeZip("link3.zip", files: packageFiles, symlinks: ["characters/alias.png": "Alice.png"]), stagingParent: staging())
        defer { ok.snapshot.removeStaging() }
        XCTAssertTrue(ok.snapshot.skipped.contains { $0.relativePath == "characters/alias.png" })
        XCTAssertEqual(ok.summary.cards, 2, "包内链接不跟随、不重复建卡")
    }

    func testDirectorySymlinkEscapingRejected() throws {
        let root = workDir.appendingPathComponent("du-link")
        try writeTree(root, packageFiles)
        let outside = workDir.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("worlds/escape.json"), withDestinationURL: outside)
        assertRejects(root) { $0 == .unsafeSymlink("worlds/escape.json") }

        try FileManager.default.removeItem(at: root.appendingPathComponent("worlds/escape.json"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("worlds/alias.json").path, withDestinationPath: "Lore.json")
        let plan = try SillyTavernPackageImporter.inventory(source: root, stagingParent: staging())
        defer { plan.snapshot.removeStaging() }
        XCTAssertEqual(plan.summary.worlds, 1)
        XCTAssertTrue(plan.snapshot.skipped.contains { $0.relativePath == "worlds/alias.json" })
    }

    func testPathCollisionRejected() throws {
        var files = packageFiles
        files["characters/alice.png"] = Data([1])
        assertRejects(try makeZip("case.zip", files: files)) { if case .pathCollision = $0 { return true }; return false }
        var fileVsDir = packageFiles
        fileVsDir["worlds"] = Data([1])
        assertRejects(try makeZip("filedir.zip", files: fileVsDir)) { if case .pathCollision = $0 { return true }; return false }
    }

    func testLimits() throws {
        var tight = SillyTavernPackageLimits.standard
        tight.maxFileCount = 5
        assertRejects(try makeZip("count.zip", files: packageFiles), limits: tight) { if case .tooManyFiles = $0 { return true }; return false }

        tight = .standard
        tight.maxFileBytes = 64
        assertRejects(try makeZip("big.zip", files: packageFiles), limits: tight) { if case .fileTooLarge = $0 { return true }; return false }

        tight = .standard
        tight.maxTotalBytes = 1024
        assertRejects(try makeZip("total.zip", files: packageFiles), limits: tight) { if case .tooLarge = $0 { return true }; return false }

        // 2 MiB 全零 deflate 后压缩比上千：压缩炸弹
        var bomb = packageFiles
        bomb["backups/zeros.bin"] = Data(count: 2 << 20)
        assertRejects(try makeZip("bomb.zip", files: bomb, compression: .deflate)) { $0 == .suspiciousCompression("backups/zeros.bin") }

        tight = .standard
        tight.diskMarginBytes = Int64.max / 2
        assertRejects(try makeZip("disk.zip", files: packageFiles), limits: tight) { if case .insufficientDiskSpace = $0 { return true }; return false }
    }

    func testCategories() {
        let cases: [(String, SillyTavernFileCategory)] = [
            ("characters/a.png", .card), ("characters/a.json", .card), ("characters/a/b.png", .cardAsset), ("characters/.DS_Store", .unknown),
            ("chats/a/x.jsonl", .chat), ("chats/x.jsonl", .unknown), ("group chats/g.jsonl", .groupChat), ("groups/g.json", .group),
            ("worlds/w.json", .world), ("OpenAI Settings/p.json", .preset), ("OpenAI Settings/readme.md", .unknown),
            ("QuickReplies/q.json", .quickReply), ("User Avatars/u.png", .personaAvatar), ("user/files/f.txt", .userFile),
            ("user/images/a/b.jpeg", .userImage), ("user/workflows/w.json", .unknown), ("backups/b.jsonl", .backup),
            ("extensions/x/y.js", .extensionFile), ("settings.json", .settings), ("secrets.json", .credentials), ("themes/t.json", .unknown),
        ]
        for (path, expected) in cases {
            XCTAssertEqual(SillyTavernPackageParser.category(for: path), expected, path)
        }
    }

    // MARK: - ⑧b JSONL

    func testChatParserIsolatesBadLineAndKeepsFields() {
        let parsed = SillyTavernChatParser.parse(aliceChat, relativePath: "chats/Alice/a.jsonl")
        XCTAssertEqual(parsed.status, .partial)
        XCTAssertTrue(parsed.isSuccess)
        XCTAssertEqual(parsed.badLines, [SillyTavernBadLine(line: 4, reason: "JSON 坏了")])
        XCTAssertEqual(parsed.messages.map(\.line), [2, 3, 5, 6, 7, 8, 9])
        XCTAssertEqual(parsed.header?.personaRef, "me.png")
        XCTAssertEqual(parsed.header?.worldRef, "Lore")
        XCTAssertEqual(parsed.header?.characterName, "unused")
        let first = parsed.messages[0]
        XCTAssertEqual(Set(first.preservedFields.keys), ["variables", "hash_sheets", "tableEditMatches"])
        XCTAssertEqual(first.preservedFields["hash_sheets"], Data(#"{"s":1}"#.utf8))
        XCTAssertNotNil(first.sendDate)
        XCTAssertEqual(parsed.messages.map(\.visibility), [.normal, .normal, .normal, .normal, .hidden, .narrator, .uiSystem])
    }

    func testChatParserMissingHeaderOrBrokenFileIsNotSuccess() {
        let noHeader = SillyTavernChatParser.parse(jsonl([["name": "A", "is_user": false, "mes": "x"]]), relativePath: "chats/A/a.jsonl")
        XCTAssertEqual(noHeader.status, .failed("缺 header"))
        XCTAssertEqual(noHeader.messages.count, 1, "消息仍保留给报告，不丢")
        XCTAssertFalse(noHeader.isSuccess)

        let broken = SillyTavernChatParser.parse(Data("{oops\n[1,2]\n".utf8), relativePath: "chats/A/b.jsonl")
        XCTAssertEqual(broken.status, .failed("整个文件读不出"))
        XCTAssertEqual(broken.badLines.map(\.line), [1, 2])

        XCTAssertEqual(SillyTavernChatParser.parse(Data(), relativePath: "chats/A/c.jsonl").status, .failed("空文件"))

        let headerOnly = SillyTavernChatParser.parse(jsonl([["chat_metadata": [:]]]), relativePath: "chats/A/d.jsonl")
        XCTAssertEqual(headerOnly.status, .ok, "只有 header 的空聊天是合法的")

        let groupOld = SillyTavernChatParser.parse(jsonl([["name": "A", "is_user": false, "mes": "x"]]), relativePath: "group chats/g.jsonl",
                                                   requireHeader: false)
        XCTAssertEqual(groupOld.status, .ok)
    }

    // MARK: - ⑧b swipe → 分支

    func testSwipeBranchTree() throws {
        let parsed = SillyTavernChatParser.parse(aliceChat, relativePath: "chats/Alice/a.jsonl")
        let built = SwipeBranchBuilder.build(parsed, idPrefix: "t", title: "a", fallbackDate: Date(timeIntervalSince1970: 0))
        let nodes = Dictionary(uniqueKeysWithValues: built.payload.nodes.map { ($0.id, $0) })

        // 首组挂合成根，合成根另计
        let root = try XCTUnwrap(nodes["t-root"])
        XCTAssertTrue(root.isSyntheticRoot)
        XCTAssertEqual(root.role, "system")
        XCTAssertEqual(root.childrenIds, ["t-L2-0", "t-L2-1", "t-L2-2"])
        XCTAssertEqual(built.syntheticRootId, "t-root")
        XCTAssertEqual(built.contentNodeCount, 11)
        XCTAssertEqual(built.payload.nodes.count, 12)

        // mes≠选中 swipe：活动正文取 mes，源 swipe 进 metadata，不多算候选
        XCTAssertEqual(nodes["t-L2-1"]?.content, "A1 显示版")
        XCTAssertEqual(built.nodeSources["t-L2-1"]?.sourceSwipeText, "A1 源")
        XCTAssertEqual(nodes["t-L2-0"]?.content, "A0")
        XCTAssertNil(built.nodeSources["t-L2-0"]?.sourceSwipeText)
        XCTAssertEqual(built.mesDiffCount, 1)
        XCTAssertEqual(built.candidateCount, 7)

        // 只有选中的接后续
        XCTAssertEqual(nodes["t-L2-1"]?.childrenIds, ["t-L3-0"])
        XCTAssertEqual(nodes["t-L2-0"]?.childrenIds, [])
        XCTAssertEqual(nodes["t-L3-0"]?.parentId, "t-L2-1")
        XCTAssertEqual(nodes["t-L3-0"]?.role, "user")

        // 越界 swipe_id：按 mes 匹配；匹配不到退首候选，正文仍是 mes
        XCTAssertEqual(built.issues, [
            .init(line: 5, kind: .swipeIdOutOfRange(sourceId: 7, count: 2, matched: 1)),
            .init(line: 6, kind: .swipeIdOutOfRange(sourceId: -1, count: 2, matched: nil)),
        ])
        XCTAssertEqual(nodes["t-L3-0"]?.childrenIds, ["t-L5-0", "t-L5-1"])
        XCTAssertEqual(nodes["t-L5-1"]?.childrenIds, ["t-L6-0", "t-L6-1"])
        XCTAssertEqual(built.nodeSources["t-L5-1"]?.sourceSwipeId, 7)
        XCTAssertNil(built.nodeSources["t-L5-1"]?.sourceSwipeText)
        XCTAssertEqual(nodes["t-L6-0"]?.content, "ZZ")
        XCTAssertEqual(built.nodeSources["t-L6-0"]?.sourceSwipeText, "P")
        XCTAssertEqual(nodes["t-L6-1"]?.content, "Q")

        // 元数据：整行原件、插件字段只挂选中节点；swipe_info 按候选
        XCTAssertNotNil(built.nodeSources["t-L2-1"]?.rawLine)
        XCTAssertNil(built.nodeSources["t-L2-0"]?.rawLine)
        XCTAssertEqual(built.nodeSources["t-L2-1"]?.preservedFields.keys.sorted(), ["hash_sheets", "tableEditMatches", "variables"])
        XCTAssertEqual(nodes["t-L2-1"]?.createTime, SillyTavernChatParser.parseDate("2025-06-03T07:25:00.000Z"))
        XCTAssertEqual(built.nodeSources["t-L7-0"]?.visibility, .hidden)
        XCTAssertEqual(nodes["t-L7-0"]?.role, "assistant", "is_system 不升级成 system 角色")

        // 选择表（③b 格式）+ 唯一 resolver 走出来的路径
        XCTAssertEqual(built.selection, ["t-root": "t-L2-1", "t-L3-0": "t-L5-1", "t-L5-1": "t-L6-0"])
        XCTAssertEqual(BranchSelection.decode(built.payload.branchSelectionData), built.selection)
        XCTAssertEqual(built.payload.currentNodeId, "t-L9-0")
        let resolution = BranchSelection.resolve(
            links: built.payload.nodes.map { BranchSelection.Link(id: $0.id, parentId: $0.parentId, childrenIds: $0.childrenIds) },
            selection: built.selection, legacyCurrentNodeId: built.payload.currentNodeId)
        XCTAssertEqual(resolution.pathIds, ["t-root", "t-L2-1", "t-L3-0", "t-L5-1", "t-L6-0", "t-L7-0", "t-L8-0", "t-L9-0"])
        XCTAssertFalse(resolution.changed)
        XCTAssertEqual(built.payload.provider, "sillytavern")
        XCTAssertEqual(countDisplayableNodes(built.payload.nodes), 11, "合成根不进显示计数")
    }

    func testEmptyChatHasNoRoot() {
        let parsed = SillyTavernChatParser.parse(jsonl([["chat_metadata": [:]]]), relativePath: "chats/A/e.jsonl")
        let built = SwipeBranchBuilder.build(parsed, idPrefix: "e", title: "e", fallbackDate: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(built.payload.nodes.isEmpty)
        XCTAssertNil(built.syntheticRootId)
        XCTAssertEqual(built.payload.currentNodeId, "")
        XCTAssertNil(built.payload.branchSelectionData)
    }

    // MARK: - ⑧b 关联

    func testAssociationsPlaceholderAndGroupArchive() throws {
        let plan = try SillyTavernPackageImporter.inventory(source: makeZip("assoc.zip", files: packageFiles), stagingParent: staging())
        defer { plan.snapshot.removeStaging() }

        // 卡按头像 stem ↔ chats/<stem>/，一角色多 chat；header 占位名不参与
        let alice = try XCTUnwrap(plan.characters.first { $0.stem == "Alice" })
        XCTAssertEqual(alice.cardPath, "characters/Alice.png")
        XCTAssertEqual(alice.chats.map(\.relativePath), ["chats/Alice/Alice - 1.jsonl", "chats/Alice/Alice - 2.jsonl"])
        XCTAssertEqual(plan.characters.first { $0.stem == "Bob" }?.chats.count, 0)

        // 缺卡的 chat → 占位角色
        let ghost = try XCTUnwrap(plan.characters.first { $0.stem == "Ghost" })
        XCTAssertTrue(ghost.isPlaceholder)
        XCTAssertEqual(ghost.chats.count, 1)
        XCTAssertTrue(plan.problems.contains { $0.relativePath == "chats/Ghost" })

        // 卡：内书、绑定书、正则、助手脚本
        let card = try XCTUnwrap(plan.cards.first { $0.stem == "Alice" })
        XCTAssertEqual(card.card.name, "Alice")
        XCTAssertEqual(card.characterBook?.entries.count, 1)
        XCTAssertEqual(card.worldBinding, "Lore")
        XCTAssertTrue(card.hasHelperScripts)
        XCTAssertFalse(try XCTUnwrap(plan.cards.first { $0.stem == "Bob" }).hasHelperScripts)

        // 预设名取文件名，预设正则另列；persona
        XCTAssertEqual(plan.presets.first?.name, "P1")
        XCTAssertEqual(plan.presets.first?.regexScripts.map(\.scriptName), ["pr"])
        XCTAssertEqual(plan.globalRegex.map(\.scriptName), ["g"])
        XCTAssertEqual(plan.personas.first?.name, "我")
        XCTAssertEqual(plan.personas.first?.lorebook, "Lore")
        XCTAssertTrue(plan.personas.first?.hasAvatarFile ?? false)
        XCTAssertEqual(plan.worlds.first?.name, "Lore")
        XCTAssertEqual(Set(plan.worldBindings.map(\.owner)), [.card("characters/Alice.png"), .chat("chats/Alice/Alice - 1.jsonl"),
                                                              .persona("me.png"), .global, .characterExtra("Alice.png")])

        // 群聊：有 / 无 header 都只读归档，按 chats 关联群组
        XCTAssertEqual(plan.groups.first?.chatIds, ["gc1", "gc2"])
        XCTAssertEqual(plan.groupChats.count, 2)
        for chat in plan.groupChats {
            XCTAssertTrue(chat.readOnlyArchive)
            XCTAssertEqual(chat.groupId, "g1")
            XCTAssertEqual(chat.status, .ok)
        }
        XCTAssertEqual(plan.groupChats.map(\.built.messageCount).sorted(), [1, 2])
    }

    func testHelperScriptFormats() {
        XCTAssertTrue(SillyTavernPackageImporter.hasHelperScripts(["tavern_helper": ["scripts": [["n": 1]]]]))
        XCTAssertFalse(SillyTavernPackageImporter.hasHelperScripts(["tavern_helper": ["scripts": []]]))
        XCTAssertTrue(SillyTavernPackageImporter.hasHelperScripts(["tavern_helper": [["scripts", [["n": 1]]]]]))
        XCTAssertTrue(SillyTavernPackageImporter.hasHelperScripts(["TavernHelper_scripts": [["n": 1]]]))
        XCTAssertFalse(SillyTavernPackageImporter.hasHelperScripts(["regex_scripts": [["n": 1]]]))
    }
}
