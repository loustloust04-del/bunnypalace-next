import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 文件库 › 记忆 › 记忆条目 / 日志：每张卡一份 md（各项是 frontmatter，删了的在 Deleted）、她改了落到卡上并留痕、助手的 fs_* 读得到、两份日志看得懂。全虚构
@MainActor
final class MemoryCardFolderTests: XCTestCase {
    private let pid = "xctest-memory-card-folder"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @discardableResult
    private func add(_ text: String, subject: String?, _ context: ModelContext, category: String = "fact", tags: [String] = [],
                     at: Date = Date()) throws -> Memory {
        let m = try SwiftDataMemoryStore().add(content: text, category: category, keywords: tags, profileId: pid, isUserExplicit: false,
                                               extractedBy: "测试", sourceConversationId: "conv", context: context)
        m.subject = subject
        m.occurredDay = "2026-11-02"
        m.createdAt = at
        m.updatedAt = at
        try context.save()
        return m
    }

    private func root() -> URL { FileLibraryStore.memoryRoot(profileId: pid) }

    func testEveryLiveCardIsOneEntryGroupedByAbout() throws {
        let context = ModelContext(try makeContainer())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try add("岚舟每周三去槐序巷皮影作坊。", subject: "岚舟", context, category: "preference", tags: ["皮影"], at: t)
        let b = try add("星砚答应陪岚舟刻纸鸢。", subject: "星砚", context, at: t.addingTimeInterval(60))
        let c = try add("槐序巷口新开了一家灯铺。", subject: nil, context, at: t.addingTimeInterval(120))
        let gone = try add("已经不要的一张。", subject: "岚舟", context, at: t.addingTimeInterval(180))
        MemoryAudit.trash([gone])
        MemoryAudit.keep([b])
        b.isUserExplicit = true
        try context.save()

        let entries = MemoryCardFolder.entries(profileId: pid, context: context)
        XCTAssertEqual(entries.map(\.card), [gone.id, c.id, b.id, a.id], "新的在前；删了的也有一份")
        XCTAssertEqual(entries.map(\.folder), ["memory/cards/Deleted", "memory/cards/没写是谁", "memory/cards/星砚", "memory/cards/岚舟"])
        let ea = try XCTUnwrap(entries.last)
        XCTAssertEqual(ea.path, "memory/cards/岚舟/\(MemoryCardTool.short(a.id)).md")
        XCTAssertEqual(ea.state, "Draft")
        XCTAssertEqual(entries[0].state, "Deleted")
        XCTAssertEqual(entries[2].state, "Archive")
        XCTAssertTrue(entries[2].pinned)
        XCTAssertEqual(ea.content, """
        ---
        id: \(a.id.uuidString.lowercased())
        state: Draft
        created: \(ea.content.components(separatedBy: "created: ")[1].prefix(10))
        day: 2026-11-02
        about: 岚舟
        from:
        tags: [偏好, 皮影]
        importance:
        confidence:
        pinned: no
        source: conv
        ---

        岚舟每周三去槐序巷皮影作坊。

        """)
        let display = FileLibraryCardFolder.display(entries[2])
        XCTAssertEqual(display.title, "星砚答应陪岚舟刻纸鸢。")
        XCTAssertEqual(display.chips, ["Archive", "Pinned"])

        // 文件库的文件夹索引：记忆 › 记忆条目 › 说的是谁；日志里两份现排的在最前
        var index = FileLibraryMemoryFolder.folderIndex([])
        let pinned = MemoryCardFolder.pinnedFile(entries)
        XCTAssertTrue(pinned.content.contains("- 星砚答应陪岚舟刻纸鸢。（\(entries[2].path)）"), pinned.content)
        FileLibraryCardFolder.merge(entries, logs: MemoryLogFolder.files(memoryRoot: root()) + [pinned], into: &index)
        XCTAssertEqual(index["memory"]?.folders.first { $0.path == MemoryCardFolder.root }?.fileCount, 3, "记忆条目那一格的张数不算删了的")
        XCTAssertEqual(index[MemoryCardFolder.root]?.folders.map(\.path),
                       ["memory/cards/没写是谁", "memory/cards/星砚", "memory/cards/岚舟", "memory/cards/Deleted"], "Deleted 排最后")
        XCTAssertEqual(index[MemoryCardFolder.root]?.files.map(\.path), [MemoryCardFolder.pinnedPath])
        XCTAssertEqual(index["memory/cards/岚舟"]?.files.map(\.path), [ea.path])
        XCTAssertEqual(index[MemoryLogFolder.folder]?.files.map(\.path), [MemoryLogFolder.auditPath, MemoryLogFolder.writePath])
        XCTAssertEqual(FileLibraryMemoryFolder.displayName(MemoryCardFolder.root, assistantName: "星砚"), "C2 原子事实")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory/pending", assistantName: "星砚"), "待续")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory/log", assistantName: "星砚"), "日志")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName("memory/heartbeat", assistantName: "星砚"), "自己醒来")
        XCTAssertEqual(FileLibraryMemoryFolder.displayName(MemoryLogFolder.dreamFolder, assistantName: "星砚"), FragmentDream.actor + "记录")
    }

    /// 类别当标签显示的那份对照，和整理台 Edit 页（`MemoryAuditTraits`）同一个结果
    func testCategoryTagsMatchTheEditPage() {
        for (key, _) in MemoryAuditFilterSheet.categories {
            XCTAssertEqual(MemoryCardFolder.shownTags(category: key, keywords: ["皮影", "偏好"]),
                           MemoryAuditTraits.shownTags(category: key, keywords: ["皮影", "偏好"]), key)
        }
        for (_, label) in MemoryAuditFilterSheet.categories {
            XCTAssertEqual(MemoryCardFolder.categoryKey(forTag: label), MemoryAuditTraits.categoryKey(forTag: label), label)
        }
        XCTAssertEqual(MemoryCardFolder.plainCategory, MemoryAuditTraits.plainCategory)
    }

    func testSavingAnEntryChangesTheCardAndLogsIt() throws {
        let context = ModelContext(try makeContainer())
        let m = try add("岚舟每周三去槐序巷皮影作坊。", subject: "岚舟", context, tags: ["皮影"])
        m.confidence = 60
        try context.save()
        let entry = try XCTUnwrap(MemoryCardFolder.entries(profileId: pid, context: context).first)
        let text = entry.content
            .replacingOccurrences(of: "岚舟每周三去槐序巷皮影作坊。", with: "岚舟每周四去槐序巷皮影作坊。")
            .replacingOccurrences(of: "tags: [皮影]", with: "tags: [皮影, 关系, #周四]")
            .replacingOccurrences(of: "pinned: no", with: "pinned: yes")

        // 没动的原样存 = 什么都不变、不记
        let same = try MemoryCardFolder.save(card: m.id, text: entry.content, baseline: entry.content, stamp: entry.modifiedAt, profileId: pid, context: context)
        XCTAssertEqual(same, entry.modifiedAt)
        XCTAssertTrue(MemoryAuditLog.load(memoryRoot: root()).isEmpty)

        let stamp = try MemoryCardFolder.save(card: m.id, text: text, baseline: entry.content, stamp: entry.modifiedAt, profileId: pid, context: context)
        XCTAssertEqual(m.content, "岚舟每周四去槐序巷皮影作坊。")
        XCTAssertEqual(m.keywords, ["皮影", "周四"])
        XCTAssertEqual(m.category, "relationship", "写了类别名的标签存回类别")
        XCTAssertTrue(m.isUserExplicit)
        XCTAssertEqual(m.subject, "岚舟", "没碰的不动")
        XCTAssertEqual(m.confidence, MemoryAudit.handEditedConfidence, "她亲手改的 = 100")
        XCTAssertNotNil(m.userEditedAt)
        XCTAssertNotNil(m.reviewedAt)
        XCTAssertEqual(stamp, m.updatedAt)
        let logged = try XCTUnwrap(MemoryAuditLog.load(memoryRoot: root()).first)
        XCTAssertEqual(logged.actor, MemoryAuditLog.you)
        XCTAssertEqual(logged.via, MemoryAuditLog.viaFileLibrary)
        XCTAssertEqual(logged.action, .edit)

        // 别处改过（卡的改动时间对不上打开时的）= 拒存
        XCTAssertThrowsError(try MemoryCardFolder.save(card: m.id, text: text, baseline: entry.content, stamp: entry.modifiedAt, profileId: pid, context: context)) {
            XCTAssertEqual($0 as? MemoryCardFolder.EditError, .conflict)
        }
        // 同一页接着改第二次：基线是上次存的那份，置信度那一行没碰 → 不会被写回 60
        let second = text.replacingOccurrences(of: "about: 岚舟", with: "about: 岚舟和星砚")
        try MemoryCardFolder.save(card: m.id, text: second, baseline: text, stamp: stamp, profileId: pid, context: context)
        XCTAssertEqual(m.subject, "岚舟和星砚")
        XCTAssertEqual(m.confidence, MemoryAudit.handEditedConfidence)

        // 只读的项、空正文、认不出的值、认不出的项、头没了、撤回
        let now = m.updatedAt
        for bad in [second.replacingOccurrences(of: "created: ", with: "created: 1999-"),
                    second.replacingOccurrences(of: "source: conv", with: "source: 别的窗口"),
                    second.replacingOccurrences(of: "岚舟每周四去槐序巷皮影作坊。", with: ""),
                    second.replacingOccurrences(of: "pinned: yes", with: "pinned: maybe"),
                    second.replacingOccurrences(of: "state: Draft", with: "state: Kept"),
                    second.replacingOccurrences(of: "importance:", with: "importance: 9"),
                    second.replacingOccurrences(of: "about:", with: "mood: 开心\nabout:"),
                    second.replacingOccurrences(of: "---\nid", with: "id")] {
            XCTAssertThrowsError(try MemoryCardFolder.save(card: m.id, text: bad, baseline: second, stamp: now, profileId: pid, context: context), bad)
        }
        XCTAssertEqual(m.subject, "岚舟和星砚", "存不成的不动卡")
        let last = try XCTUnwrap(MemoryAuditLog.load(memoryRoot: root()).first)
        XCTAssertEqual(MemoryAuditLog.undo(last, profileId: pid, context: context).restored, 1)
        XCTAssertEqual(m.subject, "岚舟")
        // 删了的：要改先把 state 改回来；彻底删了的 = 不在了
        MemoryAudit.trash([m])
        let fifth = second.replacingOccurrences(of: "每周四", with: "每周五")
        XCTAssertThrowsError(try MemoryCardFolder.save(card: m.id, text: fifth, baseline: second, stamp: m.updatedAt, profileId: pid, context: context))
        XCTAssertEqual(m.content, "岚舟每周四去槐序巷皮影作坊。")
        XCTAssertThrowsError(try MemoryCardFolder.save(card: UUID(), text: second, baseline: second, stamp: m.updatedAt, profileId: pid, context: context)) {
            XCTAssertEqual($0 as? MemoryCardFolder.EditError, .gone)
        }
    }

    /// 助手的 fs_*：列得出、读得到、搜得到记忆条目和两份日志（写在 `MemoryFolderWriteTests`）
    func testAssistantFileToolsSeeCardsAndLogs() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let m = try add("岚舟每周三去槐序巷皮影作坊。", subject: "岚舟", context)
        let path = "memory/cards/岚舟/\(MemoryCardTool.short(m.id)).md"
        _ = MemoryCardTool.execute(inputJSON: #"{"action":"pin","id":"\#(path)","reason":"岚舟说这条要一直记着"}"#, profileId: pid, conversationId: "conv",
                                   memoryEnabled: true, actor: "星砚", context: context)

        // 文件工具要在后台线程跑（主线程碰盘会被拦）
        let pid = pid
        func fs(_ name: String, _ json: String, container: ModelContainer? = container) async -> FileLibraryTools.Result {
            await Task.detached { FileLibraryTools.execute(name: name, inputJSON: json, profileId: pid, container: container) }.value
        }
        let list = await fs("fs_list", "{}").text
        XCTAssertTrue(list.contains(path), list)
        XCTAssertTrue(list.contains(MemoryLogFolder.auditPath))
        let read = await fs("fs_read", #"{"path":"\#(path)"}"#)
        XCTAssertFalse(read.isError, read.text)
        XCTAssertTrue(read.text.contains("id: \(m.id.uuidString.lowercased())") && read.text.contains("岚舟每周三去槐序巷皮影作坊。"), read.text)
        XCTAssertTrue(read.text.contains("pinned: yes"))
        let moved = await fs("fs_read", #"{"path":"memory/cards/改过名的/\#(MemoryCardTool.short(m.id)).md"}"#)
        XCTAssertTrue(moved.text.contains("皮影作坊"), "文件夹那段不对也按文件名找")
        let missing = await fs("fs_read", #"{"path":"memory/cards/岚舟/00000000.md"}"#)
        XCTAssertTrue(missing.isError)
        let hits = await fs("fs_search", #"{"keyword":"皮影作坊"}"#).text
        XCTAssertTrue(hits.contains("\(path): 岚舟每周三去槐序巷皮影作坊。"), hits)

        let audit = await fs("fs_read", #"{"path":"\#(MemoryLogFolder.auditPath)"}"#).text
        XCTAssertTrue(audit.contains("星砚 · Pin 1 · 聊天") && audit.contains("理由：岚舟说这条要一直记着"), audit)
        let writes = await fs("fs_read", #"{"path":"\#(MemoryLogFolder.writePath)"}"#)
        XCTAssertFalse(writes.isError)

        let write = await fs("fs_write", #"{"path":"\#(path)","content":"x"}"#)
        XCTAssertTrue(write.isError, "写要走 FileLibraryTools.run（主线程的库 + 留痕），这个只读入口不写")
        XCTAssertEqual(m.content, "岚舟每周三去槐序巷皮影作坊。")
        let bare = await fs("fs_list", "{}", container: nil)
        XCTAssertFalse(bare.text.contains("memory/cards/"), "没给库（这场对话关了记忆参与）就没有卡")
        XCTAssertTrue(bare.text.contains(MemoryLogFolder.auditPath))
    }

    func testReadableLogsAndDreamRecordIds() {
        XCTAssertTrue(MemoryLogFolder.auditText([]).contains("还没有记录"))
        let line = MemoryWriteLog.Entry(time: Date(timeIntervalSince1970: 1_800_000_000), writer: "C2", ok: true, note: "写了 3 张\n《皮影》", model: "测试模型", costUSD: 0.0123)
        let text = MemoryLogFolder.writeText([line])
        XCTAssertTrue(text.contains("C2 碎片池 · 写好了 · 写了 3 张 《皮影》 · 测试模型 · $0.012"), text)
        XCTAssertEqual(MemoryLogFolder.dreamRecordId("memory/log/c2-dream/20261113-140201-ab12.json"), "20261113-140201-ab12")
        XCTAssertNil(MemoryLogFolder.dreamRecordId("memory/log/c2-dream/notes.json"))
        XCTAssertNil(MemoryLogFolder.dreamRecordId("memory/log/写入日志.md"))
        XCTAssertTrue(MemoryVirtualFiles.isVirtual(MemoryLogFolder.auditPath))
        XCTAssertTrue(MemoryVirtualFiles.isVirtual("memory/cards/岚舟/3f2a9c1b.md"))
        XCTAssertFalse(MemoryVirtualFiles.isVirtual("memory/self/INDEX.md"))
    }
}
