import XCTest
@testable import 记忆花园

/// 卡库 ⑧c 界面：盘点页 / 报告页 / 来源列表 / 撤回结果 / 错误文案的纯逻辑（SillyTavernImportPresentation）。
/// 盘点用合成包 + 临时目录，不碰 app 存储。
@MainActor
final class SillyTavernImportUITests: XCTestCase {
    private typealias P = SillyTavernImportPresentation

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("st-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    private func jsonl(_ lines: [Any]) -> Data {
        Data(lines.map { String(decoding: json($0), as: UTF8.self) }.joined(separator: "\n").utf8)
    }

    private func plan(_ files: [String: Data]) throws -> SillyTavernPackagePlan {
        let root = workDir.appendingPathComponent("pkg/default-user")
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let staging = workDir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return try SillyTavernPackageImporter.inventory(source: root, stagingParent: staging)
    }

    private var package: [String: Data] {
        var chat = jsonl([
            ["user_name": "u", "character_name": "Alice", "chat_metadata": [:]],
            ["name": "Alice", "is_user": false, "mes": "a", "swipes": ["a", "b"], "swipe_id": 0],
            ["name": "U", "is_user": true, "mes": "u1", "swipes": ["u1"], "swipe_id": 0],
        ])
        chat.append(Data("\n{坏行".utf8))
        return [
            "settings.json": json(["power_user": ["personas": ["me.png": "我"],
                                                  "persona_descriptions": ["me.png": ["description": "d", "lorebook": "Missing"]]]]),
            "secrets.json": Data(#"{"k":"v"}"#.utf8),
            "characters/Alice.json": json(["spec": "chara_card_v2", "data": ["name": "Alice", "first_mes": "hi",
                                                                              "extensions": ["tavern_helper": ["scripts": [["name": "s"]]]]]]),
            "characters/Bob.json": json(["spec": "chara_card_v2", "data": ["name": "Bob", "first_mes": "yo"]]),
            "chats/Alice/Alice - 1.jsonl": chat,
            "chats/Ghost/Ghost - 1.jsonl": jsonl([["chat_metadata": [:]], ["name": "Ghost", "is_user": false, "mes": "boo"]]),
            "worlds/Bad.json": Data("{not json".utf8),
            "OpenAI Settings/P.json": json(["temperature": 1, "prompts": []]),
        ]
    }

    // MARK: - 盘点页

    func testInventoryCountsAttentionAndExclusions() throws {
        let plan = try plan(package)
        defer { plan.snapshot.removeStaging() }

        XCTAssertEqual(P.counts(plan.summary).map(\.value), ["2 张", "2 份", "0 本", "1 份", "0 组", "1 个"])
        XCTAssertEqual(P.messageNote(plan.summary), "共 3 条消息，其中 2 条带 swipes、1 条有多个候选", "带 swipes 和真多候选分开说")

        let attention = P.attention(plan)
        let titles = attention.map(\.title)
        XCTAssertTrue(titles.contains("1 张卡带脚本"))
        XCTAssertTrue(titles.contains("群聊"))
        XCTAssertTrue(titles.contains("1 份聊天找不到卡"))
        XCTAssertTrue(titles.contains("1 个坏文件"))
        XCTAssertTrue(titles.contains("1 行聊天坏了"))
        XCTAssertTrue(titles.contains("含 API 凭据"))
        XCTAssertEqual(attention.first { $0.title == "1 本世界书找不到" }?.detail, "被引用但包里没有：Missing")
        XCTAssertEqual(attention.first { $0.title == "群聊" }?.detail, "0 个 · 本包未包含")

        let items = P.excludable(plan)
        XCTAssertEqual(items.map(\.key), ["chats/Alice/Alice - 1.jsonl", "chats/Ghost", "worlds/Bad.json"], "凭据不在可排除里")
        XCTAssertEqual(items.first { $0.key == "chats/Ghost" }?.paths, ["chats/Ghost/Ghost - 1.jsonl"], "缺卡目录展开成文件")
        XCTAssertEqual(items.first { $0.key == "chats/Alice/Alice - 1.jsonl" }?.reason, "1 行坏了")
        XCTAssertEqual(P.excludedPaths(items, excludedKeys: ["chats/Ghost", "worlds/Bad.json"]),
                       ["chats/Ghost/Ghost - 1.jsonl", "worlds/Bad.json"])
        XCTAssertTrue(P.excludedPaths(items, excludedKeys: []).isEmpty)
    }

    func testDefaultSourceFromFileNameOrExistingSource() {
        XCTAssertEqual(P.defaultSource(fileName: "酒馆完整备份.zip", sources: []), .new(name: "酒馆完整备份"))
        XCTAssertEqual(P.defaultSource(fileName: "default-user", sources: []), .new(name: "酒馆"))
        let existing = ImportSource(name: "酒馆完整备份")
        XCTAssertEqual(P.defaultSource(fileName: "酒馆完整备份.zip", sources: [existing]), .existing(id: existing.id), "同名 = 重导")
    }

    // MARK: - 报告页

    private func report(isReimport: Bool = false, created: Int = 2, issues: [SillyTavernImportReport.Issue] = []) -> SillyTavernImportReport {
        var card = SillyTavernImportReport.Category(key: "card", title: "角色卡")
        card.sourceFiles = 2; card.created = created; card.skipped = 2 - created; card.unsupported = 1
        var chat = SillyTavernImportReport.Category(key: "chat", title: "聊天")
        chat.sourceFiles = 3; chat.created = 1; chat.changed = 1; chat.excluded = 1
        var credentials = SillyTavernImportReport.Category(key: "credentials", title: "API 凭据")
        credentials.sourceFiles = 1; credentials.skipped = 1
        let empty = SillyTavernImportReport.Category(key: "world", title: "世界书")
        var numbers = SillyTavernImportReport.Numbers()
        numbers.messages = 10; numbers.messagesWithSwipes = 4; numbers.multiCandidateMessages = 2; numbers.candidates = 5
        return SillyTavernImportReport(batchId: "b", sourceId: "s", sourceName: "源", createdAt: Date(), isReimport: isReimport,
                                       categories: [card, chat, credentials, empty],
                                       objects: ["card": created, "floor": created == 0 ? 0 : 1, "attachment": 3],
                                       numbers: numbers, issues: issues, warnings: ["w"])
    }

    func testReportRowsSplitSwipesAndTrueMultiCandidate() {
        let r = report(issues: [.init(relativePath: "chats/A/a.jsonl", line: 4, field: nil, reason: "坏行", action: "跳过", retryable: false, archivePath: "x"),
                                .init(relativePath: "characters/A.json", line: nil, field: "extensions.tavern_helper", reason: "带脚本", action: "保存", retryable: true, archivePath: nil)])
        XCTAssertEqual(P.categoryRows(r).map(\.key), ["card", "chat"], "空类别和凭据不进表")
        XCTAssertEqual(P.categoryRows(r).first?.unsupported, 1)
        XCTAssertEqual(P.categoryFootnotes(r).count, 2, "变化 / 排除另起一行说")

        let content = Dictionary(uniqueKeysWithValues: P.contentRows(r).map { ($0.title, $0.value) })
        XCTAssertEqual(content["带 swipes 的消息"], "4 条")
        XCTAssertEqual(content["真多候选"], "2 条 · 共 5 个候选")
        XCTAssertNil(content["隐藏消息"], "0 的不列")

        XCTAssertEqual(P.objectRows(r).map(\.title), ["角色卡", "楼层", "附件"])
        XCTAssertEqual(P.issueRows(r).map(\.location), ["chats/A/a.jsonl · 第 4 行", "characters/A.json · extensions.tavern_helper"])
        XCTAssertEqual(P.headline(r), "导入已完成 · 还有 2 项问题")
        XCTAssertEqual(P.headline(report(isReimport: true, created: 0)), "没有新东西 · 3 个文件和上次一样，全部跳过")
        XCTAssertEqual(P.headline(report()), "导入已完成")
    }

    // MARK: - 来源列表

    func testBatchRowsCountObjectsNewestFirstAndFirstCard() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        var source = ImportSource(name: "源")
        source.batches = [.init(id: "b1", date: old, reportFile: "b1.json"),
                          .init(id: "b2", date: new, reportFile: "b2.json", retractedAt: new)]
        func version(_ batch: String, _ targets: [ImportTarget]) -> ImportFileVersion {
            ImportFileVersion(sha256: batch, size: 1, category: "card", batchId: batch, importedAt: old, disposition: .imported, targets: targets)
        }
        source.files = [
            "characters/B.json": [version("b1", [.init(kind: .card, id: "cardB", contentHash: "h")])],
            "characters/A.json": [version("b1", [.init(kind: .card, id: "cardA", contentHash: "h"), .init(kind: .floor, id: "f", contentHash: "h")])],
            "chats/A/a.jsonl": [version("b1", [.init(kind: .conversation, id: "c", contentHash: "h"), .init(kind: .floor, id: "f", contentHash: "h"),
                                               .init(kind: .attachment, id: "att", contentHash: "h")])],
            "worlds/W.json": [version("b2", [.init(kind: .globalWorldBook, id: "w", contentHash: "h", retractedAt: new),
                                             .init(kind: .card, id: "cardW", contentHash: "h", retractedAt: new)])],
        ]
        let rows = P.batchRows(source)
        XCTAssertEqual(rows.map(\.id), ["b2", "b1"], "新的在前")
        XCTAssertEqual(rows.last?.objectCount, 4, "同一对象挂多个路径只算一次，附件不算")
        XCTAssertEqual(rows.first?.retractedCount, 2)
        XCTAssertTrue(P.batchSubtitle(rows.first!).contains("已撤回 2 个"))
        XCTAssertEqual(P.firstCardId(source: source, batchId: "b1"), "cardA", "按相对路径排第一张")
        XCTAssertNil(P.firstCardId(source: source, batchId: "b2"), "撤回掉的卡不定位")
        XCTAssertNil(P.firstCardId(source: nil, batchId: "b1"))
    }

    // MARK: - 撤回结果

    func testRetractGroupsListKeptDeletedGoneWithReasons() {
        let report = SillyTavernRetractReport(sourceId: "s", batchIds: ["b"], date: Date(), items: [
            .init(kind: "card", id: "1", relativePath: "characters/A.json", action: .kept, reason: "卡改过或已用卡"),
            .init(kind: "conversation", id: "2", relativePath: "chats/B/b.jsonl", action: .deleted, reason: "未改动、未被引用"),
            .init(kind: "floor", id: "3", relativePath: "chats/B/b.jsonl", action: .deleted, reason: "未改动，里面的导入对话都已删"),
            .init(kind: "globalWorldBook", id: "4", relativePath: "worlds/W.json", action: .alreadyGone, reason: "已经不在了"),
        ])
        let groups = P.retractGroups(report)
        XCTAssertEqual(groups.map(\.title), ["留下（1）", "删掉（2）", "已经不在（1）"])
        XCTAssertEqual(groups.first?.items.first?.title, "角色卡 · characters/A.json")
        XCTAssertEqual(groups.first?.items.first?.reason, "卡改过或已用卡")
        XCTAssertEqual(P.retractSummary(report), "删了 2 项，留下 1 项，1 项已经不在")
        XCTAssertTrue(P.retractConfirmMessage.contains("改过的") && P.retractConfirmMessage.contains("留下"))
    }

    // MARK: - 错误

    func testFailureTextsNeverClaimSuccess() {
        let pending = P.failure(SillyTavernImportCommitter.Failure.batchPending)
        XCTAssertTrue(pending.needsRecovery)
        XCTAssertTrue(pending.message.contains("没收尾"))

        let disk = P.failure(CocoaError(.fileWriteOutOfSpace))
        XCTAssertFalse(disk.needsRecovery)
        XCTAssertTrue(disk.message.contains("磁盘空间不够") && disk.message.contains("没有导入"))
        let posixDisk = P.failure(NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]))
        XCTAssertTrue(posixDisk.message.contains("磁盘空间不够"), "底层 ENOSPC 也认")

        let permission = P.failure(CocoaError(.fileReadNoPermission))
        XCTAssertTrue(permission.message.contains("没有读写权限") && permission.message.contains("没有导入"))

        let limit = P.failure(SillyTavernPackageError.tooManyFiles(30_000))
        XCTAssertTrue(limit.message.contains("文件太多") && limit.message.contains("没有导入"))
        let space = P.failure(SillyTavernPackageError.insufficientDiskSpace(needed: 10, available: 1))
        XCTAssertTrue(space.message.contains("磁盘空间不够"))

        let rollback = P.failure(SillyTavernImportCommitter.Failure.rollback(original: "a", cleanup: "b"))
        XCTAssertTrue(rollback.needsRecovery, "清理没完成 = 下次要恢复")

        XCTAssertEqual(P.recoveryText(.none), "没有要恢复的，可以直接导入。")
        XCTAssertTrue(P.recoveryText(.rolledBack(batchId: "b", targets: 7)).contains("7 项"))
    }
}
