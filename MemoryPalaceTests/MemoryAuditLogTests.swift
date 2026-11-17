import XCTest
import SwiftData
@testable import 记忆花园

/// 整理台的操作记录和撤回（plan-memory-audit-log L1 / L2）。全虚构
final class MemoryAuditLogTests: XCTestCase {
    private let pid = "xctest-audit-log"

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-log-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func makeStore() throws -> (ModelContext, SwiftDataMemoryStore) {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return (ModelContext(container), SwiftDataMemoryStore())
    }

    @MainActor
    private func add(_ text: String, _ context: ModelContext, _ store: SwiftDataMemoryStore) throws -> Memory {
        try store.add(content: text, category: "fact", keywords: ["会变"], profileId: pid, isUserExplicit: false,
                      extractedBy: "测试", sourceConversationId: "conv", context: context)
    }

    /// 照整理台的做法：动之前拍一张、动、动之后拍一张，排成一笔
    @MainActor
    private func record(_ ms: [Memory], _ change: () -> Void) -> MemoryAuditLog.Entry? {
        let before = ms.map { ($0.id, MemoryAuditLog.CardState($0)) }
        change()
        return MemoryAuditLog.entry(zip(before, ms).map { ($0.0.0, $0.0.1, MemoryAuditLog.CardState($0.1), nil) })
    }

    @MainActor
    func testActionIsReadFromWhatChanged() throws {
        let (context, store) = try makeStore()
        let a = try add("只用水性颜料。", context, store), b = try add("船送给雾岚。", context, store)
        XCTAssertNil(record([a]) {}, "没变不记")
        XCTAssertEqual(record([a, b]) { MemoryAudit.keep([a, b]) }?.action, .approve)
        XCTAssertEqual(record([a]) { MemoryAudit.editText(a, "只用水性颜料，油性的受不了。") }?.action, .edit)
        XCTAssertEqual(record([a]) { MemoryAudit.setCategory(a, "preference") }?.action, .category)
        XCTAssertEqual(record([a]) { _ = MemoryAudit.setImportance(a, 5) }?.action, .importance)
        let both = record([a, b]) { _ = MemoryAudit.trash([a]); _ = MemoryAudit.setImportance(b, 1) }
        XCTAssertEqual(both?.action, .mixed)
        XCTAssertEqual(both?.items.count, 2)
        XCTAssertEqual(record([a, b]) { MemoryAudit.restore([a]) }?.items.map(\.card), [a.id], "只记真变了的那张")
    }

    @MainActor
    func testFileRoundTripNewestFirstAndPrune() throws {
        let root = tempRoot()
        let (context, store) = try makeStore()
        let a = try add("只用水性颜料。", context, store)
        let now = Date()
        var old = try XCTUnwrap(record([a]) { MemoryAudit.keep([a]) })
        old.at = now.addingTimeInterval(-100 * 86400)
        var purge = try XCTUnwrap(MemoryAuditLog.entry([(a.id, .init(a), nil, .init(a))]))
        purge.at = now.addingTimeInterval(-40 * 86400)
        let fresh = try XCTUnwrap(record([a]) { _ = MemoryAudit.trash([a]) })
        for entry in [old, purge, fresh] { try MemoryAuditLog.append(entry, memoryRoot: root) }
        XCTAssertEqual(MemoryAuditLog.load(memoryRoot: root).map(\.id), [fresh.id, purge.id, old.id])
        XCTAssertEqual(MemoryAuditLog.load(memoryRoot: root)[1].action, .purge)
        MemoryAuditLog.prune(memoryRoot: root, now: now)
        let left = MemoryAuditLog.load(memoryRoot: root)
        XCTAssertEqual(left.map(\.id), [fresh.id, purge.id], "90 天前的整笔丢掉")
        XCTAssertNil(left[1].items[0].full, "彻底删的副本过了 30 天拿掉")
        XCTAssertFalse(MemoryAuditLog.canUndo(left[1], in: left), "副本没了就放不回来")
        XCTAssertTrue(MemoryAuditLog.canUndo(left[0], in: left))
        XCTAssertTrue(MemoryAuditLog.load(memoryRoot: tempRoot()).isEmpty)
    }

    @MainActor
    func testUndoPutsBackOnlyCardsLeftAsTheyWere() throws {
        let root = tempRoot()
        let (context, store) = try makeStore()
        let a = try add("只用水性颜料。", context, store), b = try add("船送给雾岚。", context, store)
        try MemoryAuditLog.append(try XCTUnwrap(record([a, b]) { _ = MemoryAudit.trash([a, b]) }), memoryRoot: root)
        MemoryAudit.restore([b])   // 这张后来又被动过
        let saved = try XCTUnwrap(MemoryAuditLog.load(memoryRoot: root).first, "从文件读回来的也认得出没动过的卡")
        let result = MemoryAuditLog.undo(saved, profileId: pid, context: context)
        XCTAssertEqual([result.restored, result.skipped], [1, 1])
        XCTAssertNil(a.supersededAt)
        let undoEntry = try XCTUnwrap(result.entry)
        XCTAssertEqual([undoEntry.action, undoEntry.undoOf.map { $0 == saved.id } == true ? .undo : .mixed], [.undo, .undo])
        try MemoryAuditLog.append(undoEntry, memoryRoot: root)
        let all = MemoryAuditLog.load(memoryRoot: root)
        XCTAssertFalse(MemoryAuditLog.canUndo(saved, in: all), "撤过的不能再撤")
        XCTAssertTrue(MemoryAuditLog.canUndo(all[0], in: all), "撤回这一笔本身能撤")
        _ = MemoryAuditLog.undo(all[0], profileId: pid, context: context)
        XCTAssertNotNil(a.supersededAt, "撤回的撤回 = 又删了")
    }

    @MainActor
    func testPurgedCardComesBackFromItsCopy() throws {
        let (context, store) = try makeStore()
        let a = try add("只用水性颜料。", context, store)
        a.subject = "岚舟"
        a.speaker = "用户自述"
        a.occurredDay = "2026-10-12"
        a.confidence = 88
        a.sourceNodeIds = ["n1", "n3"]
        _ = MemoryAudit.trash([a])
        try context.save()
        let id = a.id
        let entry = try XCTUnwrap(MemoryAuditLog.entry([(id, .init(a), nil, .init(a))]))
        XCTAssertEqual(MemoryAudit.purge(ids: [id], profileId: pid, context: context), 1)
        try context.save()
        XCTAssertTrue(store.listAll(profileId: pid, context: context).isEmpty)

        XCTAssertEqual(MemoryAuditLog.undo(entry, profileId: "别的楼层", context: context).restored, 0, "别的楼层放不回来")
        let result = MemoryAuditLog.undo(entry, profileId: pid, context: context)
        try context.save()
        XCTAssertEqual(result.restored, 1)
        let back = try XCTUnwrap(store.listAll(profileId: pid, context: context).first)
        XCTAssertEqual([back.id.uuidString, back.content, back.subject, back.speaker, back.occurredDay, back.sourceConversationId],
                       [id.uuidString, "只用水性颜料。", "岚舟", "用户自述", "2026-10-12", "conv"])
        XCTAssertEqual(back.keywords, ["会变"])
        XCTAssertEqual(back.confidence, 88, "写手给的置信度跟着放回来")
        XCTAssertEqual(back.sourceNodeIds, ["n1", "n3"], "全部出处跟着放回来")
        XCTAssertNotNil(back.supersededAt, "回到彻底删之前的样子：还在 Deleted 里")
        XCTAssertEqual(MemoryAuditLog.undo(entry, profileId: pid, context: context).skipped, 1, "库里已经有这张就不再放一份")
    }

    /// 改写手给的四项也是一笔 Edit：落库对、文件里记着改前改后，Undo 四项一起回到改之前
    @MainActor
    func testTraitEditIsLoggedAndUndoPutsAllFourBack() throws {
        let root = tempRoot()
        let (context, store) = try makeStore()
        let a = try add("麦芽怕打雷。", context, store)
        a.subject = "麦芽"
        a.speaker = "用户自述"
        a.confidence = 80
        try context.save()

        var edit = MemoryAudit.Edit(a)
        edit.subject = " 岚舟 "
        edit.speaker = "AI 观察"
        edit.keywords = ["宠物", " 日常", "宠物"]
        edit.confidence = nil
        let entry = try XCTUnwrap(record([a]) { MemoryAudit.apply(edit, to: a) })
        try context.save()
        XCTAssertEqual(entry.action, .edit, "正文没动、只改四项也记成 Edit")
        let saved = try XCTUnwrap(store.listAll(profileId: pid, context: context).first)
        XCTAssertEqual([saved.subject, saved.speaker], ["岚舟", "AI 观察"])
        XCTAssertEqual(saved.keywords, ["宠物", "日常"])
        XCTAssertNil(saved.confidence)
        XCTAssertNotNil(saved.reviewedAt)

        try MemoryAuditLog.append(entry, memoryRoot: root)
        let loaded = try XCTUnwrap(MemoryAuditLog.load(memoryRoot: root).first)
        XCTAssertEqual(loaded.items[0].before.traits, MemoryAuditLog.Traits(subject: "麦芽", speaker: "用户自述", keywords: ["会变"], confidence: 80))
        XCTAssertEqual(loaded.items[0].after?.traits, MemoryAuditLog.Traits(subject: "岚舟", speaker: "AI 观察", keywords: ["宠物", "日常"], confidence: nil))

        let result = MemoryAuditLog.undo(loaded, profileId: pid, context: context)
        try context.save()
        XCTAssertEqual([result.restored, result.skipped], [1, 0])
        XCTAssertEqual(result.entry?.action, .undo)
        let back = try XCTUnwrap(store.listAll(profileId: pid, context: context).first)
        XCTAssertEqual([back.subject, back.speaker, back.content], ["麦芽", "用户自述", "麦芽怕打雷。"])
        XCTAssertEqual(back.keywords, ["会变"])
        XCTAssertEqual(back.confidence, 80)
        XCTAssertNil(back.reviewedAt, "回到没审过")

        // 改完又被别处动了四项里的一项：这一笔对不上，不放回
        let again = try XCTUnwrap(record([a]) { MemoryAudit.apply(edit, to: a) })
        a.keywords = ["宠物"]
        XCTAssertEqual(MemoryAuditLog.undo(again, profileId: pid, context: context).skipped, 1)
        XCTAssertEqual(a.subject, "岚舟")
    }

    /// 粟粟 11-13「如果人改过就confidence=100」：这一笔照旧进记录（改前改后都记着），Undo 把置信度放回改之前；
    /// 只改类别 / 重要度带出来的 100 不把那一笔改叫 Edit
    @MainActor
    func testHandEditConfidenceIsLoggedAndUndone() throws {
        let root = tempRoot()
        let (context, store) = try makeStore()
        let a = try add("岚舟在云桥城学陶艺。", context, store)
        a.keywords = ["陶艺"]
        a.importance = 3
        a.confidence = 60
        try context.save()

        var edit = MemoryAudit.Edit(a)
        edit.text = "岚舟在云桥城南岸学陶艺。"
        edit.keywords = ["陶艺", "日常"]
        let entry = try XCTUnwrap(record([a]) { MemoryAudit.apply(edit, to: a) })
        try context.save()
        XCTAssertEqual(entry.action, .edit)
        XCTAssertEqual(a.confidence, 100)
        try MemoryAuditLog.append(entry, memoryRoot: root)
        let loaded = try XCTUnwrap(MemoryAuditLog.load(memoryRoot: root).first)
        XCTAssertEqual([loaded.items[0].before.traits?.confidence, loaded.items[0].after?.traits?.confidence], [60, 100])
        let result = MemoryAuditLog.undo(loaded, profileId: pid, context: context)
        try context.save()
        XCTAssertEqual([result.restored, result.skipped], [1, 0])
        let back = try XCTUnwrap(store.listAll(profileId: pid, context: context).first)
        XCTAssertEqual(back.content, "岚舟在云桥城学陶艺。")
        XCTAssertEqual(back.keywords, ["陶艺"])
        XCTAssertEqual(back.confidence, 60, "Undo 把置信度放回改之前")

        edit = MemoryAudit.Edit(a)
        edit.category = "preference"
        let category = try XCTUnwrap(record([a]) { MemoryAudit.apply(edit, to: a) })
        XCTAssertEqual(category.action, .category, "只改类别带出来的 100 不算改四项")
        XCTAssertEqual([category.items[0].before.traits?.confidence, category.items[0].after?.traits?.confidence], [60, 100])
        XCTAssertEqual(MemoryAuditLog.undo(category, profileId: pid, context: context).restored, 1)
        XCTAssertEqual([a.category, a.confidence.map(String.init)], ["fact", "60"])

        edit = MemoryAudit.Edit(a)
        edit.importance = 5
        XCTAssertEqual(record([a]) { MemoryAudit.apply(edit, to: a) }?.action, .importance)
        XCTAssertEqual(a.confidence, 100)

        a.confidence = 60
        edit = MemoryAudit.Edit(a)
        edit.confidence = 100
        XCTAssertEqual(record([a]) { MemoryAudit.apply(edit, to: a) }?.action, .edit, "她只把置信度亲手填成 100 还是一笔 Edit")
        a.confidence = 60
        edit = MemoryAudit.Edit(a)
        edit.importance = 2
        edit.keywords = ["日常"]
        XCTAssertEqual(record([a]) { MemoryAudit.apply(edit, to: a) }?.action, .edit, "重要度和标签一起改是 Edit")
    }

    /// 整理台以外她亲手改字的两处（召回卡片 / 设置里的条目区）走 `SwiftDataMemoryStore.update`：真改了才记 100
    @MainActor
    func testStoreUpdateByHandSetsConfidenceTo100() throws {
        let (context, store) = try makeStore()
        let a = try add("星砚答应周末陪岚舟去云桥城。", context, store)
        a.confidence = 60
        try context.save()
        try store.update(id: a.id, content: a.content, keywords: a.keywords, context: context)
        XCTAssertEqual(a.confidence, 60, "原样存回不动")
        try store.update(id: a.id, content: "星砚答应周六陪岚舟去云桥城。", keywords: a.keywords, context: context)
        XCTAssertEqual(a.confidence, 100)
    }

    /// 加四项之前落盘的老记录（没有 traits）：照样读得出、撤得回，撤回时不碰卡上的四项
    @MainActor
    func testOldRecordWithoutTraitsStillDecodesAndUndoes() throws {
        let root = tempRoot()
        let (context, store) = try makeStore()
        let a = try add("住在云桥城南岸。", context, store)
        a.subject = "岚舟"
        a.confidence = 70
        a.updatedAt = Date(timeIntervalSince1970: 1_792_800_060)
        a.userEditedAt = a.updatedAt
        a.reviewedAt = a.updatedAt
        let entryId = UUID()
        let line = """
        {"id":"\(entryId.uuidString)","at":1792800060000,"actor":"You","action":"Edit","items":[{"card":"\(a.id.uuidString)",\
        "before":{"content":"住在云桥城。","category":"fact","updatedAt":1792800000000},\
        "after":{"content":"住在云桥城南岸。","category":"fact","reviewedAt":1792800060000,"userEditedAt":1792800060000,"updatedAt":1792800060000}}]}
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (line + "\n").write(to: MemoryAuditLog.url(memoryRoot: root), atomically: true, encoding: .utf8)

        let old = try XCTUnwrap(MemoryAuditLog.load(memoryRoot: root).first, "老格式读得出")
        XCTAssertEqual([old.id, old.items[0].card], [entryId, a.id])
        XCTAssertEqual(old.action, .edit)
        XCTAssertNil(old.items[0].before.traits)
        XCTAssertNil(old.items[0].after?.traits)
        XCTAssertTrue(MemoryAuditLog.canUndo(old, in: [old]))

        let result = MemoryAuditLog.undo(old, profileId: pid, context: context)
        XCTAssertEqual([result.restored, result.skipped], [1, 0])
        XCTAssertEqual(a.content, "住在云桥城。")
        XCTAssertNil(a.reviewedAt)
        XCTAssertEqual([a.subject, a.keywords.first], ["岚舟", "会变"], "老记录不知道四项，撤回不碰")
        XCTAssertEqual(a.confidence, 70)
        let undoEntry = try XCTUnwrap(result.entry)
        try MemoryAuditLog.append(undoEntry, memoryRoot: root)
        XCTAssertEqual(MemoryAuditLog.load(memoryRoot: root).map(\.id), [undoEntry.id, entryId], "新老两种格式的行在同一份文件里都读得出")
    }

    // MARK: - 她逐条删过的（「C2 整理」拿来当「删过的卡」）

    /// 只认：现在还删着，而且让它变成删掉的最后那一笔是她逐条删的。整批的、「C2 整理」的、助手的、放回来的、撤掉的都不算
    @MainActor
    func testHandDeletedIsOnlyWhatSheDeletedOneByOne() throws {
        let root = tempRoot()
        let (context, store) = try makeStore()
        /// 记一笔并落进文件（照 `MemoryEntryActions.commit` 的做法：动之前拍一张、动、动之后拍一张）
        @discardableResult
        func log(_ ms: [Memory], actor: String = MemoryAuditLog.you, via: String? = nil, bulk: Bool? = false,
                 label: String? = nil, _ change: () -> Void) throws -> MemoryAuditLog.Entry {
            let before = ms.map { ($0.id, MemoryAuditLog.CardState($0)) }
            change()
            let entry = try XCTUnwrap(MemoryAuditLog.entry(zip(before, ms).map { ($0.0.0, $0.0.1, MemoryAuditLog.CardState($0.1), nil) },
                                                           actor: actor, label: label, via: via, bulk: bulk))
            try MemoryAuditLog.append(entry, memoryRoot: root)
            return entry
        }
        func undo(_ entry: MemoryAuditLog.Entry) throws -> MemoryAuditLog.Entry {
            let made = try XCTUnwrap(MemoryAuditLog.undo(entry, profileId: pid, context: context).entry)
            try MemoryAuditLog.append(made, memoryRoot: root)
            return made
        }
        func judged() -> Set<UUID> {
            let all = store.listAll(profileId: pid, context: context)
            return MemoryAuditLog.handDeleted(all.map { (id: $0.id, supersededAt: $0.supersededAt) }, entries: MemoryAuditLog.load(memoryRoot: root))
        }
        func card(_ text: String) throws -> Memory { try add(text, context, store) }

        // 她单删 → 算
        let single = try card("岚舟打算搬去栎川镇。")
        try log([single]) { _ = MemoryAudit.trash([single]) }
        // 她在文件库里把一条改成 Deleted → 算
        let inLibrary = try card("岚舟在云桥城租过一间朝北的屋子。")
        try log([inLibrary], via: MemoryAuditLog.viaFileLibrary) { _ = MemoryAudit.trash([inLibrary]) }
        // 她多选、一条条点了其中两条再删 → 两条都算
        let pickedA = try card("星砚爱喝冷掉的茶。"), pickedB = try card("岚舟怕打雷。")
        try log([pickedA, pickedB]) { _ = MemoryAudit.trash([pickedA, pickedB]) }
        // 整批入口（Delete all / 全选再删），就算只有一条 → 不算
        let swept = try card("槐序巷皮影作坊周一不开门。"), sweptB = try card("栎川镇的集市逢五开。"), sweptOne = try card("云桥城的渡船末班是九点。")
        try log([swept, sweptB], bulk: true) { _ = MemoryAudit.trash([swept, sweptB]) }
        try log([sweptOne], bulk: true) { _ = MemoryAudit.trash([sweptOne]) }
        // 老记录（没有标记）：只动一条的算，一笔动了几条的不算
        let oldOne = try card("岚舟不吃芹菜。"), oldManyA = try card("星砚的灯是黄铜的。"), oldManyB = try card("岚舟有一把旧伞。")
        try log([oldOne], bulk: nil) { _ = MemoryAudit.trash([oldOne]) }
        try log([oldManyA, oldManyB], bulk: nil) { _ = MemoryAudit.trash([oldManyA, oldManyB]) }
        // 「C2 整理」的 Drop、助手删的（就算名字也叫 You）→ 不算
        let dropped = try card("今天栎川镇下雨。")
        try log([dropped], actor: FragmentDream.actor, bulk: nil, label: "Drop") { _ = MemoryAudit.trash([dropped]) }
        let byAssistant = try card("岚舟想学皮影。"), byNamesake = try card("岚舟想养一只猫。"), byCC = try card("岚舟想去看海。")
        try log([byAssistant], actor: "星砚", via: MemoryAuditLog.viaChat, bulk: nil) { _ = MemoryAudit.trash([byAssistant]) }
        try log([byNamesake], actor: MemoryAuditLog.you, via: MemoryAuditLog.viaChat, bulk: nil) { _ = MemoryAudit.trash([byNamesake]) }
        try log([byCC], actor: "CC 里的星砚", via: MemoryAuditLog.viaCC, bulk: nil) { _ = MemoryAudit.trash([byCC]) }
        // 删了又 Restore → 不算
        let restored = try card("岚舟在槐序巷皮影作坊学刻皮影。")
        try log([restored]) { _ = MemoryAudit.trash([restored]) }
        try log([restored]) { MemoryAudit.restore([restored]) }
        // Restore 之后她又单删 → 算
        let again = try card("岚舟的皮影箱是樟木的。")
        try log([again], bulk: true) { _ = MemoryAudit.trash([again]) }
        try log([again]) { MemoryAudit.restore([again]) }
        try log([again]) { _ = MemoryAudit.trash([again]) }
        // 「C2 整理」删的，她放回来又亲手单删 → 算
        let reDeleted = try card("星砚说栎川镇晚上冷。")
        try log([reDeleted], actor: FragmentDream.actor, bulk: nil, label: "Drop") { _ = MemoryAudit.trash([reDeleted]) }
        try log([reDeleted]) { MemoryAudit.restore([reDeleted]) }
        try log([reDeleted]) { _ = MemoryAudit.trash([reDeleted]) }
        // Undo 掉删除那一笔 → 不算
        let undone = try card("岚舟周五晚上去作坊。")
        _ = try undo(try log([undone]) { _ = MemoryAudit.trash([undone]) })
        // 撤回的撤回 = 又回到她那次删 → 算
        let undoneTwice = try card("岚舟刻皮影只用牛皮。")
        _ = try undo(try undo(try log([undoneTwice]) { _ = MemoryAudit.trash([undoneTwice]) }))
        // 她单删、Restore、再把 Restore 撤掉 = 又回到她那次删 → 算；「C2 整理」删的同样走一遍 → 还是不算
        let restoreUndone = try card("云桥城南岸有一家旧书店。")
        try log([restoreUndone]) { _ = MemoryAudit.trash([restoreUndone]) }
        _ = try undo(try log([restoreUndone]) { MemoryAudit.restore([restoreUndone]) })
        let dropRestoreUndone = try card("星砚提过一家面馆。")
        try log([dropRestoreUndone], actor: FragmentDream.actor, bulk: nil, label: "Drop") { _ = MemoryAudit.trash([dropRestoreUndone]) }
        _ = try undo(try log([dropRestoreUndone]) { MemoryAudit.restore([dropRestoreUndone]) })
        // 她单删之后，被没留痕的路子放回来又删掉（时间对不上日志里那一下）→ 不算
        let drifted = try card("岚舟的自行车是绿色的。")
        try log([drifted]) { _ = MemoryAudit.trash([drifted]) }
        drifted.supersededAt = try XCTUnwrap(drifted.supersededAt).addingTimeInterval(60)
        // 日志里根本没有的删法 → 不算
        let unlogged = try card("岚舟的旧手机壳是蓝的。")
        _ = MemoryAudit.trash([unlogged])
        // 她单删、彻底删、又从记忆日志放回来（还在 Deleted 里）→ 算
        let purged = try card("岚舟在栎川镇的旧地址。")
        try log([purged]) { _ = MemoryAudit.trash([purged]) }
        try context.save()
        let purge = try XCTUnwrap(MemoryAuditLog.entry([(purged.id, .init(purged), nil, .init(purged))]))
        try MemoryAuditLog.append(purge, memoryRoot: root)
        let purgedId = purged.id
        XCTAssertEqual(MemoryAudit.purge(ids: [purgedId], profileId: pid, context: context), 1)
        try context.save()
        XCTAssertFalse(MemoryAuditLog.handDeletedStamps(MemoryAuditLog.load(memoryRoot: root)).keys.contains(purgedId), "彻底删了的不在库里，也不算")
        _ = try undo(purge)
        try context.save()

        XCTAssertEqual(judged(), [single.id, inLibrary.id, pickedA.id, pickedB.id, oldOne.id, again.id, reDeleted.id, undoneTwice.id,
                                  restoreUndone.id, purgedId])
        for (m, why) in [(swept, "整批"), (sweptB, "整批"), (sweptOne, "整批入口只有一条"), (oldManyA, "老记录一笔几条"), (dropped, "C2 整理的 Drop"),
                         (byAssistant, "助手删的"), (byNamesake, "助手正好也叫 You"), (byCC, "CC 里的助手删的"), (restored, "放回来了"),
                         (undone, "删除被撤了"), (dropRestoreUndone, "C2 整理删的，放回又撤"), (drifted, "时间对不上"), (unlogged, "没留痕")] {
            XCTAssertFalse(judged().contains(m.id), "不该算：\(why)")
        }

        // 标记存进文件、读得回来；老行没有这一项 = nil
        let lines = MemoryAuditLog.load(memoryRoot: root)
        XCTAssertEqual(lines.first { $0.items.map(\.card) == [sweptOne.id] }?.bulk, true)
        XCTAssertEqual(lines.first { $0.items.map(\.card) == [single.id] }?.bulk, false)
        XCTAssertNil(lines.first { $0.items.map(\.card) == [oldOne.id] }?.bulk)
        XCTAssertNil(lines.first { $0.undoOf != nil }?.bulk, "Undo 那一笔不带标记")
        XCTAssertTrue(MemoryAuditLog.legacyOneByOne(try XCTUnwrap(lines.first { $0.items.map(\.card) == [oldOne.id] })))
        XCTAssertTrue(MemoryAuditLog.handDeleted([], entries: lines).isEmpty)
        XCTAssertTrue(MemoryAuditLog.handDeletedStamps([]).isEmpty)
    }
}
