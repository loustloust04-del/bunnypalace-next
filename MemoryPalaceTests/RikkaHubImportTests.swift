import XCTest
import SwiftData
@testable import 记忆花园

/// 消息 id 前缀 `rikkahub:<原对话id>`（对话 id 是 `<原对话id>@rikkahub`）
private func nodePrefix(_ payload: ImportedConversationPayload) -> String {
    RikkaHubPayloadBuilder.nodeIdPrefix(String(payload.id.dropLast("@rikkahub".count)))
}

/// #048 RikkaHub 备份解析（A 段：纯解析，不写库）。夹具 fixtures/rikkahub/ 由 scripts/make-rikkahub-fixtures.py 生成，内容全是编的
private enum RikkaHubFixture {
    static func zip(_ name: String, in test: XCTestCase) throws -> URL {
        let dir = try XCTUnwrap(Bundle(for: type(of: test)).url(forResource: "rikkahub", withExtension: nil))
        return dir.appendingPathComponent(name)
    }

    /// 按导入的白名单解进一个新 staging
    static func stage(_ name: String, in test: XCTestCase, include: ((String) -> Bool)? = nil) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rikkahub-test-\(UUID().uuidString)")
        try TwitterZipExtractor.extract(try zip(name, in: test), to: dest, include: include ?? RikkaHubArchive.neededForImport)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dest) }
        return dest
    }

    static let utc = TimeZone(identifier: "UTC")!

    static func payloads(_ name: String, in test: XCTestCase, names: [String: String] = [:])
        throws -> (payloads: [String: ImportedConversationPayload], warnings: RikkaHubWarnings, nilCount: Int) {
        let staging = try stage(name, in: test)
        let db = try RikkaHubDatabase(stagingDir: staging)
        let resolver = RikkaHubAttachmentResolver(stagingDir: staging)
        var warnings = RikkaHubWarnings()
        var result: [String: ImportedConversationPayload] = [:]
        var nilCount = 0
        for row in try db.conversations() {
            let (positions, broken) = try db.positions(of: row.id)
            warnings.brokenJSON += broken
            if let payload = RikkaHubPayloadBuilder.build(row: row, positions: positions, assistantName: names[row.assistantId],
                                                          timeZone: utc, resolver: resolver, warnings: &warnings) {
                result[row.id] = payload
            } else {
                nilCount += 1
            }
        }
        return (result, warnings, nilCount)
    }

    static func segments(_ node: ImportedNodePayload) throws -> [MessageSegment] {
        try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(node.segmentsData))
    }
}

private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

final class RikkaHubDatabaseTests: XCTestCase {
    func testWhitelistSkipsSettingsSkillsFontsAndShm() {
        XCTAssertTrue(RikkaHubArchive.neededForImport("rikka_hub.db"))
        XCTAssertTrue(RikkaHubArchive.neededForImport("rikka_hub-wal"))
        XCTAssertTrue(RikkaHubArchive.neededForImport("upload/a.png"))
        XCTAssertTrue(RikkaHubArchive.neededForImport("media_creation/s/out.png"))
        XCTAssertFalse(RikkaHubArchive.neededForImport("settings.json"))
        XCTAssertFalse(RikkaHubArchive.neededForImport("rikka_hub-shm"))
        XCTAssertFalse(RikkaHubArchive.neededForImport("skills/demo/SKILL.md"))
        XCTAssertFalse(RikkaHubArchive.neededForImport("fonts/fake.ttf"))
        XCTAssertFalse(RikkaHubArchive.neededForImport("upload/nested/a.png"))
        XCTAssertFalse(RikkaHubArchive.neededForImport("upload/../settings.json"))
        XCTAssertFalse(RikkaHubArchive.neededForImport("media_creation//x"))
    }

    func testStagingNeverContainsSettings() throws {
        let staging = try RikkaHubFixture.stage("g3-v27.zip", in: self)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("settings.json").path))
        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathComponent("skills").path))
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("upload/aaaa-photo.png").path))
        XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("media_creation/sess1/out.png").path))
    }

    func testCurrentGeneration() throws {
        let db = try RikkaHubDatabase(stagingDir: try RikkaHubFixture.stage("g3-v27.zip", in: self))
        XCTAssertEqual(db.schemaVersion, 27)
        XCTAssertEqual(db.generation, .nodeTable)
        XCTAssertFalse(db.isNewerThanKnown)
        let rows = try db.conversations()
        XCTAssertEqual(rows.count, 9)
        let branch = try XCTUnwrap(rows.first { $0.title == "多版本对话" })
        XCTAssertTrue(branch.isPinned)
        XCTAssertEqual(branch.customSystemPrompt, "你是测试用的系统提示")
        XCTAssertEqual(rows.first { $0.title == "文件夹里的对话" }?.folderId, "22222222-ffff-4fff-8fff-000000000001")
        XCTAssertEqual(try db.positions(of: branch.id).positions.map(\.messages.count), [2, 3, 1, 1])
        XCTAssertEqual(try db.memories().map(\.content), ["用户喜欢喝茶", "用户住在杭州", "用户是开发者"])
        XCTAssertEqual(try db.folders(), [RikkaHubFolderRow(id: "22222222-ffff-4fff-8fff-000000000001",
                                                            assistantId: "11111111-bbbb-4bbb-8bbb-000000000002", name: "工作")])
    }

    /// 老包直接拷活库：最新那段对话和记忆只在 WAL 里，必须回放才读得到
    func testLegacyWALIsReplayedOnStagingCopy() throws {
        let staging = try RikkaHubFixture.stage("g2-v11-wal.zip", in: self)
        let wal = staging.appendingPathComponent("rikka_hub-wal")
        XCTAssertGreaterThan(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int), 0)

        let db = try RikkaHubDatabase(stagingDir: staging)
        XCTAssertEqual(db.schemaVersion, 11)
        XCTAssertEqual(db.generation, .nodesColumn)
        XCTAssertEqual(Set(try db.conversations().map(\.title)), ["老对话（主库里）", "新对话（只在 WAL 里）"])
        XCTAssertEqual(try db.memories().map(\.content), ["老版本记忆"])
        XCTAssertEqual(try db.folders(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("rikka_hub.db").path))
    }

    func testFlatGeneration() throws {
        let db = try RikkaHubDatabase(stagingDir: try RikkaHubFixture.stage("g1-v5.zip", in: self))
        XCTAssertEqual(db.generation, .flatMessages)
        let row = try XCTUnwrap(try db.conversations().first)
        XCTAssertEqual(try db.positions(of: row.id).positions.map(\.messages.count), [1, 1])
    }

    func testSettingsOnlyBackupHasNoDatabase() throws {
        let staging = try RikkaHubFixture.stage("settings-only.zip", in: self)
        XCTAssertThrowsError(try RikkaHubDatabase(stagingDir: staging)) {
            XCTAssertEqual($0 as? RikkaHubError, .missingDatabase)
        }
    }

    func testNewerSchemaIsFlagged() throws {
        let staging = try RikkaHubFixture.stage("g3-v27.zip", in: self)
        try SQLiteDB(url: staging.appendingPathComponent("rikka_hub.db")).exec("PRAGMA user_version = 28")
        let db = try RikkaHubDatabase(stagingDir: staging)
        XCTAssertTrue(db.isNewerThanKnown)
        XCTAssertEqual(try db.conversations().count, 9)
    }

    func testGarbageDatabaseThrows() throws {
        let staging = try RikkaHubFixture.stage("g3-v27.zip", in: self)
        try Data(repeating: 0x41, count: 4096).write(to: staging.appendingPathComponent("rikka_hub.db"))
        XCTAssertThrowsError(try RikkaHubDatabase(stagingDir: staging))
    }

    func testNonRikkaHubDatabaseThrows() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("rikkahub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: staging) }
        try SQLiteDB(url: staging.appendingPathComponent("rikka_hub.db")).exec("CREATE TABLE other (x)")
        XCTAssertThrowsError(try RikkaHubDatabase(stagingDir: staging)) {
            XCTAssertEqual($0 as? RikkaHubError, .notRikkaHub)
        }
    }
}

final class RikkaHubMessageMapperTests: XCTestCase {
    func testLegacyPartTypeNames() {
        for raw in ["text", "Text", "UIMessagePart.Text", "me.rerere.ai.ui.UIMessagePart.Text"] {
            XCTAssertEqual(RikkaHubMessageMapper.normalizedPartType(raw), "text")
        }
        XCTAssertEqual(RikkaHubMessageMapper.normalizedPartType("me.rerere.ai.ui.UIMessagePart.ToolCall"), "tool_call")
        XCTAssertEqual(RikkaHubMessageMapper.normalizedPartType("server_tool"), "server_tool")
    }

    func testLocalDateTimeForms() throws {
        let utc = RikkaHubFixture.utc
        let base = try XCTUnwrap(RikkaHubMessageMapper.parseLocalDateTime("2026-03-05T10:00", in: utc))
        XCTAssertEqual(base, Date(timeIntervalSince1970: 1772704800))
        XCTAssertEqual(RikkaHubMessageMapper.parseLocalDateTime("2026-03-05T10:00:01.250", in: utc)?.timeIntervalSince(base) ?? 0,
                       1.25, accuracy: 0.0001)
        XCTAssertEqual(RikkaHubMessageMapper.parseLocalDateTime("2026-03-05T10:00:02.123456789", in: utc)?.timeIntervalSince(base) ?? 0,
                       2.123456789, accuracy: 0.00001)
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(RikkaHubMessageMapper.parseLocalDateTime("2026-03-05T18:00", in: shanghai), base)
        for bad in ["not-a-date", "2026-02-30T10:00", "2026-03-05 10:00", "2026-03-05T10:00Z", "2026-03-05T10:00:00.1234567890"] {
            XCTAssertNil(RikkaHubMessageMapper.parseLocalDateTime(bad, in: utc), bad)
        }
    }

    func testAttachments() throws {
        let (payloads, warnings, _) = try RikkaHubFixture.payloads("g3-v27.zip", in: self)
        let conv = try XCTUnwrap(payloads["33333333-0000-4000-8000-000000000002"])
        let user = try XCTUnwrap(conv.nodes.first { $0.role == "user" })
        let segs = try RikkaHubFixture.segments(user)
        XCTAssertEqual(segs.count, 7)
        XCTAssertEqual(segs[0], .text("看看这些"))
        XCTAssertEqual(segs[1], .image(name: "aaaa-photo.png", type: "image/png", data: png))
        XCTAssertEqual(segs[2], .fileData(name: "笔记.txt", mime: "text/plain", data: Data("合成笔记\n第二行\n".utf8)))
        XCTAssertEqual(segs[3], .file(name: "missing.png", uuid: "file:///data/user/0/me.rerere.rikkahub/files/upload/missing.png"))
        XCTAssertEqual(segs[4], .image(name: "image.png", type: "image/png", data: png))
        XCTAssertEqual(segs[5], .file(name: "generated.png", uuid: "https://example.invalid/generated.png"))
        guard case .file(_, let rejectedURL) = segs[6] else { return XCTFail("越界路径应该是占位") }
        XCTAssertTrue(rejectedURL.contains("/../../databases/"))

        let assistant = try XCTUnwrap(conv.nodes.first { $0.role == "assistant" })
        XCTAssertEqual(try RikkaHubFixture.segments(assistant).last, .image(name: "out.png", type: "image/png", data: png))

        XCTAssertEqual(warnings.missingAttachments, 3)
        XCTAssertEqual(warnings.rejectedPaths, 1)
    }

    /// parts 里夹了坏元素：好的照导，坏的计「认不出」
    func testBadPartElementDoesNotDropSiblings() {
        var warnings = RikkaHubWarnings()
        let object: [String: Any] = ["role": "user", "parts": [["type": "text", "text": "前"], NSNull(), 42, ["type": "text", "text": "后"]]]
        let message = RikkaHubMessageMapper.message(object, timeZone: .gmt,
                                                    resolver: RikkaHubAttachmentResolver(stagingDir: URL(fileURLWithPath: "/nonexistent")),
                                                    warnings: &warnings)
        XCTAssertEqual(message.segments, [.text("前"), .text("后")])
        XCTAssertEqual(warnings.unknownParts, 2)
    }

    func testReasoningAndTools() throws {
        let (payloads, _, _) = try RikkaHubFixture.payloads("g3-v27.zip", in: self)
        let conv = try XCTUnwrap(payloads["33333333-0000-4000-8000-000000000003"])
        let assistant = try XCTUnwrap(conv.nodes.first { $0.role == "assistant" })
        XCTAssertEqual(try RikkaHubFixture.segments(assistant), [
            .thinking(text: "用户想知道时间，调用工具。", signature: nil),
            .toolUse(id: "call_1", name: "get_time", inputJSON: "{\"tz\":\"Asia/Shanghai\"}", integrationName: nil, iconName: nil),
            .toolResult(toolUseId: "call_1", text: "10:00", isError: false, integrationName: nil),
            .image(name: "aaaa-photo.png", type: "image/png", data: png),
            .toolUse(id: "srv_1", name: "web_search", inputJSON: "{\"q\":\"time\"}", integrationName: nil, iconName: nil),
            .toolResult(toolUseId: "srv_1", text: "{\"error\":\"timeout\"}", isError: true, integrationName: nil),
            .text("现在是 10:00。"),
        ])
    }

    func testUnknownPartsAreDroppedAndCounted() throws {
        let (payloads, warnings, _) = try RikkaHubFixture.payloads("g3-v27.zip", in: self)
        let conv = try XCTUnwrap(payloads["33333333-0000-4000-8000-000000000008"])
        let node = try XCTUnwrap(conv.nodes.first { $0.role == "assistant" })
        XCTAssertEqual(try RikkaHubFixture.segments(node), [.text("前面"), .text("后面")])
        XCTAssertEqual(warnings.unknownParts, 1)
        XCTAssertEqual(conv.title, "RikkaHub 对话")
    }
}

final class RikkaHubPayloadBuilderTests: XCTestCase {
    private let branchId = "33333333-0000-4000-8000-000000000001"

    private func node(_ payload: ImportedConversationPayload, _ suffix: String) throws -> ImportedNodePayload {
        try XCTUnwrap(payload.nodes.first { $0.id == "\(nodePrefix(payload)):\(suffix)" }, suffix)
    }

    /// 编辑版本、重新生成版本都是兄弟；只有选中的接后续
    func testVariantsBecomeSiblingsAndOnlySelectedContinues() throws {
        let (payloads, _, _) = try RikkaHubFixture.payloads("g3-v27.zip", in: self, names: ["11111111-aaaa-4aaa-8aaa-000000000001": "小研"])
        let conv = try XCTUnwrap(payloads[branchId])
        XCTAssertEqual(conv.id, "\(branchId)@rikkahub")
        XCTAssertTrue(conv.nodes.allSatisfy { $0.id.hasPrefix("rikkahub:\(branchId):") })
        XCTAssertEqual(conv.provider, "rikkahub")
        XCTAssertEqual(conv.nodes.count, 1 + 2 + 3 + 1 + 1)

        let root = try node(conv, "root")
        XCTAssertTrue(root.isSyntheticRoot)
        XCTAssertNil(root.parentId)
        let u1 = "33333333-0001-4000-8000-000000000001", u2 = "33333333-0001-4000-8000-000000000002"
        let a1 = "33333333-0001-4000-8000-000000000003", a2 = "33333333-0001-4000-8000-000000000004"
        let a3 = "33333333-0001-4000-8000-000000000005"
        let u3 = "33333333-0001-4000-8000-000000000006", a4 = "33333333-0001-4000-8000-000000000007"
        XCTAssertEqual(root.childrenIds, ["\(nodePrefix(conv)):\(u1)", "\(nodePrefix(conv)):\(u2)"])
        XCTAssertEqual(try node(conv, u1).childrenIds, [])
        XCTAssertEqual(try node(conv, u2).childrenIds, [a1, a2, a3].map { "\(nodePrefix(conv)):\($0)" })
        XCTAssertEqual(try node(conv, a1).childrenIds, [])
        XCTAssertEqual(try node(conv, a2).childrenIds, ["\(nodePrefix(conv)):\(u3)"])
        XCTAssertEqual(try node(conv, a3).parentId, "\(nodePrefix(conv)):\(u2)")
        XCTAssertEqual(conv.currentNodeId, "\(nodePrefix(conv)):\(a4)")
        XCTAssertEqual(BranchSelection.decode(conv.branchSelectionData),
                       ["\(nodePrefix(conv)):root": "\(nodePrefix(conv)):\(u2)", "\(nodePrefix(conv)):\(u2)": "\(nodePrefix(conv)):\(a2)"])

        XCTAssertEqual(try node(conv, u1).content, "你好 👋\r\n第二行")
        XCTAssertEqual(try node(conv, u1).createTime, Date(timeIntervalSince1970: 1772359200))
        XCTAssertEqual(conv.createTime, Date(timeIntervalSince1970: 1772359200))
        XCTAssertEqual(conv.updateTime, Date(timeIntervalSince1970: 1772359450))

        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(conv.sourceMetadata)) as? [String: Any])
        XCTAssertEqual(meta["assistantName"] as? String, "小研")
        XCTAssertEqual(meta["pinned"] as? Bool, true)
        XCTAssertEqual(meta["customSystemPrompt"] as? String, "你是测试用的系统提示")
        let a1Meta = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(try node(conv, a1).sourceMetadata)) as? [String: [String: Any]])
        XCTAssertEqual((a1Meta["rikkahub"]?["modelSnapshot"] as? [String: String])?["displayName"], "Fake GPT")
        XCTAssertEqual(a1Meta["rikkahub"]?["createdAt"] as? String, "2026-03-01T10:01:05")
    }

    /// fork 复用消息 id：两段对话的节点 id 不能撞（花园节点 id 全库 unique）
    func testForkSharingMessageIdsDoesNotCollide() throws {
        let (payloads, _, _) = try RikkaHubFixture.payloads("g3-v27.zip", in: self)
        let fork = try XCTUnwrap(payloads["33333333-0000-4000-8000-000000000004"])
        XCTAssertEqual(fork.nodes.count, 1 + 2 + 3)
        let all = payloads.values.flatMap { $0.nodes.map(\.id) }
        XCTAssertEqual(all.count, Set(all).count)
        XCTAssertEqual(Set(payloads.values.map(\.id)).count, payloads.count)
    }

    func testOutOfRangeSelectionAndEmptyPositionAndEmptyConversation() throws {
        let (payloads, warnings, nilCount) = try RikkaHubFixture.payloads("g3-v27.zip", in: self)
        let conv = try XCTUnwrap(payloads["33333333-0000-4000-8000-000000000007"])
        XCTAssertEqual(conv.currentNodeId, "\(nodePrefix(conv)):33333333-0007-4000-8000-000000000003")
        XCTAssertEqual(warnings.clampedSelections, 1)
        XCTAssertEqual(warnings.emptyPositions, 1)
        XCTAssertNil(payloads["33333333-0000-4000-8000-000000000009"])
        XCTAssertEqual(nilCount, 1)
        XCTAssertEqual(warnings.emptyConversations, 1)
        XCTAssertEqual(payloads.count, 8)
    }

    func testBadTimestampLeavesNodeTimeEmpty() throws {
        let (payloads, warnings, _) = try RikkaHubFixture.payloads("g3-v27.zip", in: self)
        let conv = try XCTUnwrap(payloads["33333333-0000-4000-8000-000000000006"])
        let bad = try node(conv, "33333333-0006-4000-8000-000000000004")
        XCTAssertNil(bad.createTime)
        XCTAssertEqual(warnings.badTimestamps, 1)
    }

    /// 老格式：类名 type、tool_call + TOOL 角色 tool_result 并进前一个 assistant
    func testLegacyToolNodesFoldIntoPreviousAssistant() throws {
        let (payloads, warnings, _) = try RikkaHubFixture.payloads("g2-v11-wal.zip", in: self)
        XCTAssertEqual(payloads.count, 2)
        let conv = try XCTUnwrap(payloads["55555555-0000-4000-8000-000000000001"])
        XCTAssertEqual(conv.nodes.map(\.role), ["system", "user", "assistant", "assistant"])
        let caller = try node(conv, "55555555-0001-4000-8000-000000000002")
        XCTAssertEqual(try RikkaHubFixture.segments(caller), [
            .text("我查一下"),
            .toolUse(id: "c1", name: "search", inputJSON: "{\"q\":\"x\"}", integrationName: nil, iconName: nil),
            .toolResult(toolUseId: "c1", text: "{\"result\":\"找到了\"}", isError: false, integrationName: nil),
        ])
        XCTAssertEqual(caller.childrenIds, ["\(nodePrefix(conv)):55555555-0001-4000-8000-000000000004"])
        XCTAssertEqual(conv.currentNodeId, "\(nodePrefix(conv)):55555555-0001-4000-8000-000000000004")
        XCTAssertEqual(warnings.unknownParts, 0)
    }

    func testFlatGenerationBuildsLinearChain() throws {
        let (payloads, _, _) = try RikkaHubFixture.payloads("g1-v5.zip", in: self)
        let conv = try XCTUnwrap(payloads.values.first)
        XCTAssertEqual(conv.nodes.map(\.content), ["", "最早的版本", "平铺消息"])
        XCTAssertEqual(countDisplayableNodes(conv.nodes), 2)
    }

    /// 假 key / 假密码 / 假系统提示 / 假鉴权头都只在 settings.json 里，绝不能出现在任何导出物里
    func testNoSettingsSecretsLeakIntoPayloads() throws {
        for name in ["g3-v27.zip", "g2-v11-wal.zip", "g1-v5.zip"] {
            let (payloads, _, _) = try RikkaHubFixture.payloads(name, in: self, names: ["11111111-aaaa-4aaa-8aaa-000000000001": "小研"])
            for payload in payloads.values {
                var blobs = [Data(payload.title.utf8), payload.sourceMetadata ?? Data(), payload.branchSelectionData ?? Data()]
                for node in payload.nodes {
                    blobs += [Data(node.content.utf8), node.segmentsData ?? Data(), node.sourceMetadata ?? Data()]
                }
                for blob in blobs {
                    XCTAssertNil(String(decoding: blob, as: UTF8.self).range(of: "FAKE"), name)
                }
            }
        }
    }
}

final class RikkaHubSettingsPeekTests: XCTestCase {
    func testOnlyAssistantNamesAreRead() throws {
        let staging = try RikkaHubFixture.stage("g3-v27.zip", in: self, include: { $0 == RikkaHubArchive.settingsEntry })
        let data = try Data(contentsOf: staging.appendingPathComponent("settings.json"))
        XCTAssertEqual(RikkaHubSettingsPeek.assistantNames(fromSettingsJSON: data), [
            "11111111-aaaa-4aaa-8aaa-000000000001": "小研",
            "11111111-bbbb-4bbb-8bbb-000000000002": "Tool 助手",
        ])
        XCTAssertNil(RikkaHubSettingsPeek.assistantNames(fromSettingsJSON: Data("[]".utf8)))
        XCTAssertEqual(RikkaHubSettingsPeek.assistantNames(fromSettingsJSON: Data("{\"assistants\":[{\"id\":\"x\",\"name\":\"  \"}]}".utf8)), [:])
    }
}

// MARK: - B 段：扫描 / 预览 / 写库 / 撤回（内存库 + 临时目录；附件不外置到真文件库）

private let rikkaPid = "profile-rrrrrrrr"

private func makeRikkaContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
        ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

final class RikkaHubScanTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("rikkahub-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func allFiles(_ root: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL]) ?? []
    }

    func testZipIsRecognizedAndSettingsNeverStaged() throws {
        let scan = try ExportPackageScanner.scan([try RikkaHubFixture.zip("g3-v27.zip", in: self)], tempRoot: work)
        defer { scan.cleanup() }
        XCTAssertFalse(scan.isEmpty)
        let package = try XCTUnwrap(scan.rikkaHubPackages.first)
        XCTAssertEqual(scan.rikkaHubPackages.count, 1)
        XCTAssertTrue(package.hasSettings)
        XCTAssertEqual(package.assistantNames["11111111-aaaa-4aaa-8aaa-000000000001"], "小研")
        XCTAssertEqual(Set(scan.ignoredLabels), ["技能包", "字体"])
        XCTAssertTrue(scan.unrecognized.isEmpty, "\(scan.unrecognized)")
        let names = allFiles(scan.stagingDir).map(\.lastPathComponent)
        XCTAssertFalse(names.contains("settings.json"))
        XCTAssertFalse(names.contains("SKILL.md"))
        XCTAssertTrue(names.contains("rikka_hub.db"))
        XCTAssertTrue(names.contains("aaaa-photo.png"))
        for file in allFiles(scan.stagingDir) where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let data = try Data(contentsOf: file)
            XCTAssertNil(data.range(of: Data("FAKE".utf8)), file.lastPathComponent)
        }
    }

    /// 单独选中解压出来的 settings.json：不拷进 staging，只当「只有设置」
    func testDirectlyPickedSettingsNeverStaged() throws {
        let src = work.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let settings = src.appendingPathComponent("settings.json")
        try Data(#"{"assistants":[{"id":"a1","name":"小研"}],"providers":[{"apiKey":"sk-FAKE"}]}"#.utf8).write(to: settings)
        let scan = try ExportPackageScanner.scan([settings], tempRoot: work)
        defer { scan.cleanup() }
        XCTAssertTrue(scan.isEmpty)
        XCTAssertEqual(scan.rikkaHubSettingsOnly, ["settings.json"])
        XCTAssertFalse(allFiles(scan.stagingDir).contains { $0.lastPathComponent == "settings.json" })
    }

    func testSettingsOnlyBackupIsExplainedNotImported() throws {
        let scan = try ExportPackageScanner.scan([try RikkaHubFixture.zip("settings-only.zip", in: self)], tempRoot: work)
        defer { scan.cleanup() }
        XCTAssertTrue(scan.isEmpty)
        XCTAssertEqual(scan.rikkaHubSettingsOnly, ["settings-only.zip"])
        XCTAssertTrue(scan.unrecognized.isEmpty)
    }

    func testUnzippedFolderAndOldWALPackage() throws {
        let folder = work.appendingPathComponent("picked")
        try TwitterZipExtractor.extract(try RikkaHubFixture.zip("g3-v27.zip", in: self), to: folder, include: { _ in true })
        let scan = try ExportPackageScanner.scan([folder, try RikkaHubFixture.zip("g2-v11-wal.zip", in: self)],
                                                 tempRoot: work.appendingPathComponent("tmp"))
        defer { scan.cleanup() }
        XCTAssertEqual(scan.rikkaHubPackages.count, 2)
        XCTAssertTrue(scan.rikkaHubPackages.allSatisfy { $0.assistantNames["11111111-aaaa-4aaa-8aaa-000000000001"] == "小研" })
        let names = allFiles(scan.stagingDir).map(\.lastPathComponent)
        XCTAssertFalse(names.contains("settings.json"))
        XCTAssertTrue(names.contains("rikka_hub-wal"))
        XCTAssertFalse(names.contains("rikka_hub-shm"))
    }

    func testPreviewCounts() throws {
        let scan = try ExportPackageScanner.scan([try RikkaHubFixture.zip("g3-v27.zip", in: self)], tempRoot: work)
        defer { scan.cleanup() }
        let preview = ImportPreview.make(scan).rikkaHub
        XCTAssertEqual(preview.conversations, 9)
        XCTAssertEqual(preview.memories, 3)
        XCTAssertEqual(preview.assistantFolders, 2)
        XCTAssertEqual(preview.folderFolders, 1)
        XCTAssertEqual(preview.attachments, 3)
        XCTAssertGreaterThanOrEqual(preview.multiVersionPositions, 2)
        XCTAssertFalse(preview.newerThanKnown)
        XCTAssertTrue(preview.failures.isEmpty)
        for label in ["设置和 API key", "收藏", "生图记录"] { XCTAssertTrue(preview.ignored.contains(label), label) }
        XCTAssertFalse(preview.ignored.contains("工作区"))
    }
}

@MainActor
final class RikkaHubImportEndToEndTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("rikkahub-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func scan(_ name: String) throws -> ExportPackageScan {
        let scan = try ExportPackageScanner.scan([try RikkaHubFixture.zip(name, in: self)],
                                                 tempRoot: work.appendingPathComponent(UUID().uuidString))
        addTeardownBlock { scan.cleanup() }
        return scan
    }

    /// 跟 ImportRunner 同一条路，只是附件不外置（测试宿主不能写真文件库）
    private func importG3(_ ctx: ModelContext, merge: Bool = false) throws
        -> (RikkaHubImporter.Outcome, PayloadImportEngine, ImportRecord) {
        let s = try scan("g3-v27.zip")
        let record = ImportRecord(fileName: "g3", provider: RikkaHubPayloadBuilder.provider, mode: merge ? .merge : .normal,
                                  profileId: rikkaPid)
        ctx.insert(record)
        let engine = try PayloadImportEngine(context: ctx, profileId: rikkaPid, record: record, merge: merge, copyConflicts: false)
        let outcome = try RikkaHubImporter.run(s.rikkaHubPackages, conversations: true, memories: true, profileId: rikkaPid,
                                               recordId: record.id, engine: engine, context: ctx,
                                               timeZone: RikkaHubFixture.utc, attachments: { segments, _, _ in segments })
        engine.writeRecordCounts()
        try ctx.save()
        return (outcome, engine, record)
    }

    private func undo(_ ctx: ModelContext, _ recordId: UUID) throws {
        let changes = try ctx.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate { $0.recordId == recordId }))
        for change in changes { try restoreConversationChange(change, in: ctx) }
        try ctx.save()
    }

    func testImportFoldersMemoriesRerunAndUndo() throws {
        let ctx = ModelContext(try makeRikkaContainer())
        let (outcome, engine, record) = try importG3(ctx)
        XCTAssertEqual(engine.counts.added, 8)
        XCTAssertEqual(engine.counts.ignored, 1, "空对话计未导入")
        XCTAssertEqual(outcome.foldersCreated, 3)
        XCTAssertEqual(outcome.memoriesAdded, 3)
        XCTAssertTrue(record.supportsUndo)

        let tags = try ctx.fetch(FetchDescriptor<ConversationTag>())
        XCTAssertEqual(Set(tags.map(\.name)), ["小研", "Tool 助手", "Tool 助手 · 工作"])
        XCTAssertTrue(tags.allSatisfy { $0.instructions.isEmpty }, "D4：说明留空")
        let convs = try ctx.fetch(FetchDescriptor<Conversation>())
        let byTitle = Dictionary(convs.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        let workFolder = try XCTUnwrap(tags.first { $0.name == "Tool 助手 · 工作" })
        let researcher = try XCTUnwrap(tags.first { $0.name == "小研" })
        XCTAssertEqual(byTitle["文件夹里的对话"]?.folderId, workFolder.id, "在 RikkaHub 文件夹里的只进最细那个")
        XCTAssertEqual(byTitle["多版本对话"]?.folderId, researcher.id)
        XCTAssertTrue(convs.allSatisfy { $0.provider == "rikkahub" && $0.id.hasSuffix("@rikkahub") })
        let memories = try ctx.fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(Set(memories.map(\.content)), ["（RikkaHub 助手「小研」）用户喜欢喝茶", "（RikkaHub 助手「小研」）用户住在杭州",
                                                     "（RikkaHub 助手「Tool 助手」）用户是开发者"])
        XCTAssertTrue(memories.allSatisfy { $0.extractedBy == RikkaHubImporter.memorySource && !$0.isUserExplicit })

        // 再导一次：对话全跳过，文件夹 / 记忆不重复
        let (again, engine2, record2) = try importG3(ctx)
        XCTAssertEqual(engine2.counts.added, 0)
        XCTAssertEqual(engine2.counts.skipped, 8)
        XCTAssertEqual(again.foldersCreated, 0)
        XCTAssertEqual(again.foldersExisting, 3)
        XCTAssertEqual(again.memoriesAdded, 0)
        XCTAssertFalse(record2.supportsUndo, "什么都没写就不给撤回")

        // 撤回第一次：对话、节点、文件夹、记忆都没了
        try undo(ctx, record.id)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Conversation>()).isEmpty)
        let rikkaNodes = try ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == rikkaPid }))
        XCTAssertTrue(rikkaNodes.isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ConversationTag>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Memory>()).isEmpty)
    }

    func testNothingFromSettingsReachesTheStore() throws {
        let ctx = ModelContext(try makeRikkaContainer())
        _ = try importG3(ctx)
        var blobs: [Data] = []
        for c in try ctx.fetch(FetchDescriptor<Conversation>()) {
            blobs += [Data(c.title.utf8), c.sourceMetadata ?? Data(), c.branchSelectionData ?? Data()]
        }
        for n in try ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == rikkaPid })) {
            blobs += [Data(n.content.utf8), n.segmentsData ?? Data(), n.sourceMetadata ?? Data()]
        }
        for m in try ctx.fetch(FetchDescriptor<Memory>()) { blobs.append(Data(m.content.utf8)) }
        for t in try ctx.fetch(FetchDescriptor<ConversationTag>()) { blobs += [Data(t.name.utf8), Data(t.instructions.utf8)] }
        for r in try ctx.fetch(FetchDescriptor<ImportRecord>()) { blobs.append(Data(r.fileName.utf8)) }
        XCTAssertFalse(blobs.isEmpty)
        for blob in blobs { XCTAssertNil(blob.range(of: Data("FAKE".utf8))) }
    }

    func testFullRunnerOnOldWALPackage() throws {
        let container = try makeRikkaContainer()
        let s = try scan("g2-v11-wal.zip")
        let summary = ImportRunner.run(scan: s, preview: ImportPreview.make(s), selection: ImportSelection(),
                                       options: .init(), profileId: rikkaPid, container: container,
                                       libraryCreate: { _ in false }, progress: { _, _ in })
        XCTAssertNil(summary.failure)
        XCTAssertEqual(summary.conversations.added, 2, "只在 WAL 里的那段也导进来")
        XCTAssertEqual(summary.rikkaHub?.memoriesAdded, 1)
        XCTAssertTrue(summary.notes.contains { $0.contains("时区") })
        let ctx = ModelContext(container)
        let record = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ImportRecord>()).first)
        XCTAssertEqual(record.provider, "rikkahub")
        XCTAssertTrue(record.supportsUndo)
        XCTAssertEqual(record.addedConversationCount, 2)
    }
}
