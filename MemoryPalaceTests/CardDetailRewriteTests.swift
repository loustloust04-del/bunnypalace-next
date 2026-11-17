import XCTest
import SwiftData
import MemoryCore
@testable import 记忆花园

/// 条目的「详细度」app 这一半（plan-card-detail-slider）：取哪一截原文、Save 落到卡上的字段和那一笔、从日志推档位和写手原句、
/// 拖过的卡「C2 整理」不改、跑一次存记录不碰库。全虚构
final class CardDetailRewriteTests: XCTestCase {
    private let pid = "xctest-card-detail"
    private let names = MemoryExtractor.Names(userName: "青禾", assistantName: "小檐")

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("card-detail-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @MainActor
    private func card(_ text: String, in context: ModelContext, conversation: String? = "conv-clock", node: String? = nil) -> Memory {
        let m = Memory(content: text, category: "fact", keywords: [], profileId: pid, extractedBy: "测试", sourceConversationId: conversation)
        m.subject = "青禾"
        m.sourceNodeId = node
        m.occurredDay = "2026-04-02"
        m.confidence = 70
        context.insert(m)
        return m
    }

    // MARK: - 取哪一截

    func testPickPrefersTheA2SegmentThenTheWriterSpan() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let ids = (0..<30).map { "n\($0)" }
        let dates: [Date?] = (0..<30).map { base.addingTimeInterval(Double($0) * 60) }
        // 每条 3000 字、每满 10 条写一次：写手那一截 = 0..<20（到 6 万字）、20..<30
        let sizes = Array(repeating: 3_000, count: 30)
        let segment = SessionSegment(kind: .rolling, title: "修钟", start: base.addingTimeInterval(600), end: base.addingTimeInterval(1140),
                                     from: 10, to: 20, lastNodeId: "n19", story: "", quotes: "", pending: "")
        let stray = SessionSegment(kind: .rolling, title: "别的分支", start: base, end: base, from: 0, to: 3, lastNodeId: "x9",
                                   story: "", quotes: "", pending: "")

        let inSegment = CardDetailRewrite.pick(anchor: "n12", segments: [stray, segment], pathIds: ids, dates: dates, sizes: sizes, every: 10)
        XCTAssertEqual(inSegment, .init(range: 10..<20, before: 10..<10, source: .segment), "锚点在 A2 段里 = 那一段，不带前文")

        let inSpan = CardDetailRewrite.pick(anchor: "n25", segments: [stray, segment], pathIds: ids, dates: dates, sizes: sizes, every: 10)
        XCTAssertEqual(inSpan, .init(range: 20..<30, before: 16..<20, source: .span), "没有段盖到 = 写手那一截 + 1.2 万字前文")

        XCTAssertNil(CardDetailRewrite.pick(anchor: "gone", segments: [segment], pathIds: ids, dates: dates, sizes: sizes, every: 10),
                     "锚点不在主线上 = 找不到")
        XCTAssertNil(CardDetailRewrite.pick(anchor: nil, segments: [], pathIds: ids, dates: dates, sizes: sizes, every: 10))
    }

    @MainActor
    func testGatherWithoutSourceIsUnavailable() throws {
        let container = try makeContainer()
        let m = card("在梧桐巷钟表铺学修旧钟。", in: container.mainContext, conversation: nil)
        guard case .unavailable(let why) = CardDetailRewrite.gather(.init(m), profileId: pid, names: names, container: container, every: 200,
                                                                    memoryRoot: tempRoot()) else {
            return XCTFail("没有出处不该拿得到材料")
        }
        XCTAssertTrue(why.contains("没记出处"))
    }

    // MARK: - 确认框

    func testAskTextSaysModelSourceCostAndDraft() {
        let material = CardDetail.Material(windowTitle: "修钟", names: names, subject: "青禾", content: "学修旧钟。",
                                           lines: [.init(role: "user", text: "a"), .init(role: "assistant", text: "b")],
                                           before: [.init(role: "user", text: "c")], anchor: 1)
        let span = CardDetailRewrite.Prepared(card: UUID(), conversationId: "conv-clock", material: material, source: .span)
        let text = CardDetailRewrite.askText(.detailed, prepared: span, model: "测试模型", cost: 0.004)
        XCTAssertTrue(text.contains("用 测试模型"))
        XCTAssertTrue(text.contains("写手写这一批时看到的 2 条，外加前面 1 条前文"))
        XCTAssertTrue(text.contains("重写成「Detailed」"))
        XCTAssertTrue(text.contains("估计花不到 $0.01"))
        XCTAssertTrue(text.contains("不看写入预算"))
        XCTAssertTrue(text.contains("点 Save 才存"))
        let segment = CardDetailRewrite.Prepared(card: UUID(), conversationId: "conv-clock", material: material, source: .segment)
        let medium = CardDetailRewrite.askText(.medium, prepared: segment, model: "测试模型", cost: nil)
        XCTAssertTrue(medium.contains("上下文摘要盖的 2 条"))
        XCTAssertTrue(medium.contains("按写手平时的写法重写一句"))
        XCTAssertTrue(medium.contains("估不出花多少"))
    }

    // MARK: - Save

    @MainActor
    func testSaveSwapsTextCountsAsApprovedNotHandEdited() throws {
        let container = try makeContainer()
        let context = container.mainContext
        addTeardownBlock { try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: self.pid).deletingLastPathComponent()) }
        let m = card("在梧桐巷钟表铺学修旧钟。", in: context)
        try context.save()
        let draft = CardDetailRewrite.Draft(level: .detailed, text: "2026-04 起在梧桐巷钟表铺学修旧钟，修的第一座是外公的座钟。",
                                            sent: m.content, recordId: "detail-20260402-200000-abcd", actor: "测试模型")
        let out = CardDetailRewrite.save(draft, to: m, context: context)
        XCTAssertNil(out.error)
        XCTAssertEqual(m.content, draft.text)
        XCTAssertNotNil(m.reviewedAt, "拖一下算批过")
        XCTAssertNil(m.userEditedAt, "不算她亲手改的字")
        XCTAssertEqual(m.confidence, 70, "置信度不动")
        let entry = try XCTUnwrap(out.entry)
        XCTAssertTrue(out.logged)
        XCTAssertEqual(entry.actor, "测试模型")
        XCTAssertEqual(entry.label, "Detail · Detailed")
        XCTAssertEqual(entry.dream, "detail-20260402-200000-abcd")
        XCTAssertNotNil(entry.note)
        XCTAssertEqual(entry.action, .edit)
        XCTAssertFalse(MemoryAuditLog.isHers(entry))
        let logged = MemoryAuditLog.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        XCTAssertEqual(logged.first?.id, entry.id)
        XCTAssertEqual(CardDetailRewrite.states(logged)[m.id]?.level, .detailed)

        // 送去之后别处改过：不存
        let stale = CardDetailRewrite.Draft(level: .brief, text: "学修旧钟。", sent: "不是现在的字", recordId: nil, actor: MemoryAuditLog.you)
        let refused = CardDetailRewrite.save(stale, to: m, context: context)
        XCTAssertEqual(refused.error, CardDetailRewrite.changedText)
        XCTAssertEqual(m.content, draft.text)
    }

    // MARK: - 从日志推档位、写手原句

    func testStatesReplayLevelsOriginalAndUndo() throws {
        let one = UUID(), two = UUID()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func state(_ text: String, at: Double) -> MemoryAuditLog.CardState {
            let m = Memory(content: text, category: "fact", profileId: pid)
            m.updatedAt = base.addingTimeInterval(at)
            return MemoryAuditLog.CardState(m)
        }
        func step(_ card: UUID, _ from: String, _ to: String, _ at: Double, label: String?, actor: String = "测试模型") -> MemoryAuditLog.Entry {
            MemoryAuditLog.entry([(card, state(from, at: at - 1), state(to, at: at), nil)], actor: actor, label: label,
                                 now: base.addingTimeInterval(at))!
        }
        var log: [MemoryAuditLog.Entry] = []   // 从旧到新
        log.append(step(one, "写手那句", "简略那句", 1, label: CardDetailRewrite.label(.brief)))
        log.append(step(one, "简略那句", "详细那句", 2, label: CardDetailRewrite.label(.detailed)))
        var states = CardDetailRewrite.states(log.reversed())
        XCTAssertEqual(states[one], .init(level: .detailed, original: "写手那句"), "连拖：原句是第一次改之前那句")

        log.append(step(one, "详细那句", "写手那句", 3, label: CardDetailRewrite.label(.medium), actor: MemoryAuditLog.you))
        states = CardDetailRewrite.states(log.reversed())
        XCTAssertEqual(states[one], .init(level: .medium, original: "写手那句"))
        XCTAssertTrue(CardDetailRewrite.protected(log.reversed()).contains(one), "拖过（含点回适中）都不许整理改")

        log.append(step(one, "写手那句", "她自己写的", 4, label: nil, actor: MemoryAuditLog.you))
        states = CardDetailRewrite.states(log.reversed())
        XCTAssertNil(states[one], "她后来亲手改了正文 = 不再算哪一档")
        XCTAssertFalse(CardDetailRewrite.protected(log.reversed()).contains(one))

        let rewrite = step(two, "原来", "简略", 5, label: CardDetailRewrite.label(.brief))
        log.append(rewrite)
        XCTAssertEqual(CardDetailRewrite.states(log.reversed())[two]?.level, .brief)
        let undo = MemoryAuditLog.entry([(two, state("简略", at: 5), state("原来", at: 6), nil)], undoOf: rewrite.id,
                                        now: base.addingTimeInterval(6))!
        log.append(undo)
        XCTAssertNil(CardDetailRewrite.states(log.reversed())[two], "Undo 掉那一笔 = 回到没拖过")

        XCTAssertNil(CardDetailRewrite.level(ofLabel: "Rewrite"), "「C2 整理」的 label 不算")
    }

    // MARK: - 跑一次：存记录、记日志，不碰库

    @MainActor
    func testRunSavesARecordAndLogLineWithoutTouchingTheCard() async throws {
        let container = try makeContainer()
        let root = tempRoot()
        let m = card("在梧桐巷钟表铺学修旧钟。", in: container.mainContext)
        try container.mainContext.save()
        let material = CardDetail.Material(windowTitle: "修钟", names: names, subject: "青禾", content: m.content,
                                           lines: [.init(role: "user", text: "这周开始去梧桐巷钟表铺学修旧钟", at: "2026-04-02 20:00")], anchor: 1)
        let prepared = CardDetailRewrite.Prepared(card: m.id, conversationId: "conv-clock", material: material, source: .segment)
        let ok = await CardDetailRewrite.run(.brief, prepared: prepared, model: "测试模型", caller: { _, _ in "{\"content\":\"在梧桐巷钟表铺学修旧钟。\"}" },
                                             profileId: pid, memoryRoot: root)
        XCTAssertEqual(ok.text, "在梧桐巷钟表铺学修旧钟。")
        XCTAssertNil(ok.failure)
        XCTAssertTrue(CardDetailRecord.isId(ok.recordId))
        let record = try XCTUnwrap(CardDetailRecord.load(id: ok.recordId, memoryRoot: root))
        XCTAssertEqual(record.level, .brief)
        XCTAssertEqual(record.calls.count, 1)
        XCTAssertEqual(record.calls.first?.system, CardDetail.system(names: names, level: .brief))
        XCTAssertEqual(record.calls.first?.user, CardDetail.user(material, level: .brief))
        XCTAssertEqual(record.text, ok.text)
        XCTAssertNil(m.reviewedAt, "跑完不落库，等她 Save")
        MemoryWriteLog.flush()
        XCTAssertEqual(MemoryWriteLog.entries(memoryRoot: root).first?.dream, ok.recordId)

        let failed = await CardDetailRewrite.run(.detailed, prepared: prepared, model: "测试模型", caller: { _, _ in "不会" },
                                                 profileId: pid, memoryRoot: root)
        XCTAssertNil(failed.text)
        XCTAssertNotNil(failed.failure)
        XCTAssertEqual(CardDetailRecord.load(id: failed.recordId, memoryRoot: root)?.calls.count, 2, "格式不对重问过一次，两次都存了")
        XCTAssertEqual(m.content, "在梧桐巷钟表铺学修旧钟。")
    }

    // MARK: - 拖过的卡，「C2 整理」并别的卡进来时不许改它的正文

    @MainActor
    func testDreamDoesNotRewriteADetailedCard() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let root = tempRoot()
        let old = card("每周三晚上去梧桐巷钟表铺。", in: context)
        try context.save()
        // 她拖过详细度（照 Save 的写法记一笔进这份楼层日志）
        let before = MemoryAuditLog.CardState(old)
        old.content = "2026-04 起每周三晚上去梧桐巷钟表铺学修旧钟。"
        old.reviewedAt = Date()
        old.updatedAt = Date()
        try context.save()
        let entry = try XCTUnwrap(MemoryAuditLog.entry([(old.id, before, MemoryAuditLog.CardState(old), nil)], actor: "测试模型",
                                                       label: CardDetailRewrite.label(.detailed), dream: "detail-x"))
        try MemoryAuditLog.append(entry, memoryRoot: root)
        let detailed = old.content

        let messages = [FragmentPool.Message(id: "m1", role: "user", content: "钟表铺改到每周四晚上了", date: Date())]
        let fresh = card("钟表铺改到每周四晚上。", in: context, node: "m1")
        try context.save()
        var sent = ""
        let summary = await FragmentDream.run(
            FragmentDream.Input(profileId: pid, conversationId: "conv-clock", windowTitle: "修钟", names: names, messages: messages,
                                cardIds: [fresh.id], resident: [], modelName: "测试模型", caller: { _, user in
                                    sent = user
                                    return #"{"verdicts":[{"card":"N1","verdict":"merge","ref":"E1","text":"每周四晚上去梧桐巷钟表铺。","why":"改时间了"}]}"#
                                }),
            container: container, defaults: .standard, memoryRoot: root, manual: true)
        XCTAssertTrue(sent.contains("[E1]〔锁〕 2026-04 起每周三晚上"), "拖过的卡在材料里带锁")
        XCTAssertEqual(old.content, detailed, "正文没被改")
        XCTAssertEqual(summary?.count(.unsure), 1)
        XCTAssertEqual(MemoryAudit.state(of: fresh), .unreviewed)
    }
}
