import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 记忆条目露面都以「说的是谁」开头（`MemoryEntryLine`）；存的正文不动；新写的条目存出处原话。全虚构
@MainActor
final class MemoryEntryLineTests: XCTestCase {
    private let pid = "xctest-memory-entry-line"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Memory.self, MessageNode.self, Conversation.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
    }

    private func memory(_ text: String, subject: String?, _ context: ModelContext) throws -> Memory {
        let m = try SwiftDataMemoryStore().add(content: text, category: "fact", keywords: [], profileId: pid, isUserExplicit: false,
                                               extractedBy: "测试", sourceConversationId: "conv", context: context)
        m.subject = subject
        try context.save()
        return m
    }

    func testOneJoinForEveryPlace() {
        XCTAssertEqual(MemoryEntryLine.text(subject: "岚舟", content: "认为云桥城的灯太亮。"), "岚舟 · 认为云桥城的灯太亮。")
        XCTAssertEqual(MemoryEntryLine.text(subject: " 岚舟 ", content: "认为云桥城的灯太亮。"), "岚舟 · 认为云桥城的灯太亮。")
        XCTAssertEqual(MemoryEntryLine.text(subject: "岚舟", content: "岚舟认为云桥城的灯太亮。"), "岚舟认为云桥城的灯太亮。", "正文本来就以主语开头的不拼")
        XCTAssertEqual(MemoryEntryLine.text(subject: nil, content: "云桥城的灯太亮。"), "云桥城的灯太亮。", "没写是谁的老条目照旧")
        XCTAssertEqual(MemoryEntryLine.text(subject: "  ", content: "云桥城的灯太亮。"), "云桥城的灯太亮。")
        XCTAssertEqual(MemoryEntryLine.text(subject: "星砚", content: "岚舟养的云貂。"), "星砚 · 岚舟养的云貂。", "正文里提到别人不算以主语开头")
    }

    func testInjectionLinesLeadWithSubjectAndCostFollows() throws {
        let context = try context()
        let m = try memory("认为云桥城的灯太亮。", subject: "岚舟", context)
        let plain = try memory("云桥城的灯太亮。", subject: nil, context)
        let now = Date()

        let full = MemoryInjector.injectionPayload(m, stable: false, catalog: false, now: now)
        XCTAssertEqual(full.text, "- 岚舟 · 认为云桥城的灯太亮。 [事实]")
        XCTAssertEqual(full.cost, m.tokenCount + Memory.estimateTokens("岚舟 · "), "计费跟着实际带出去的字")
        XCTAssertTrue(MemoryInjector.catalogLine(m).hasSuffix("] 岚舟 · 认为云桥城的灯太亮。"))
        XCTAssertEqual(MemoryInjector.injectedCost(m, catalog: true), Memory.estimateTokens(MemoryInjector.catalogLine(m)))

        let old = MemoryInjector.injectionPayload(plain, stable: false, catalog: false, now: now)
        XCTAssertEqual(old.text, "- 云桥城的灯太亮。 [事实]")
        XCTAssertEqual(old.cost, plain.tokenCount)
        XCTAssertEqual(m.content, "认为云桥城的灯太亮。", "存的正文不变")
    }

    func testFolderFileKeepsBodyPureAndListTitleLeads() throws {
        let context = try context()
        let m = try memory("认为云桥城的灯太亮。", subject: "岚舟", context)
        m.sourceQuote = "云桥城的灯\n真的太亮了"
        try context.save()

        let entry = try XCTUnwrap(MemoryCardFolder.entries(profileId: pid, context: context).first)
        XCTAssertEqual(entry.text, "岚舟 · 认为云桥城的灯太亮。", "文件库列表标题带主语")
        XCTAssertTrue(entry.content.contains("\nabout: 岚舟\n"))
        XCTAssertTrue(entry.content.contains("\nquote: 云桥城的灯 真的太亮了\n"), "出处原话在头里，一行")
        XCTAssertTrue(entry.content.hasSuffix("---\n\n认为云桥城的灯太亮。\n"), "正文不拼主语：改了存回来不会把主语存进正文")
        XCTAssertTrue(MemoryCardFolder.Key.quote.readOnly)

        // 原样存回去：什么都不变
        let stamp = m.updatedAt
        try MemoryCardFolder.save(card: m.id, text: entry.content, baseline: entry.content, stamp: stamp, profileId: pid, context: context)
        XCTAssertEqual(m.content, "认为云桥城的灯太亮。")
        XCTAssertEqual(m.subject, "岚舟")
        // 改 quote 被拒
        let hacked = entry.content.replacingOccurrences(of: "quote: 云桥城的灯 真的太亮了", with: "quote: 别的话")
        XCTAssertThrowsError(try MemoryCardFolder.save(card: m.id, text: hacked, baseline: entry.content, stamp: stamp, profileId: pid, context: context))
    }

    func testNewFragmentsStoreSourceQuoteFromFirstSourceMessage() throws {
        let context = try context()
        let long = String(repeating: "林栖在云桥城南塔守灯。", count: 20)
        let messages = [
            FragmentPool.Message(id: "n0", role: "user", content: "岚舟说：\n云桥城的灯太亮。", date: nil),
            FragmentPool.Message(id: "n1", role: "assistant", content: long, date: nil),
        ]
        let fragments = [
            FragmentPool.Fragment(msg: 1, content: "认为云桥城的灯太亮。", tags: [], importance: 3, emotion: 0, resolved: nil,
                                  category: "fact", subject: "岚舟", speaker: "用户自述"),
            FragmentPool.Fragment(msg: 2, content: "在云桥城南塔守灯。", tags: [], importance: 3, emotion: 0, resolved: nil,
                                  category: "fact", subject: "林栖", speaker: "AI 观察"),
        ]
        let store = SwiftDataMemoryStore()
        XCTAssertEqual(try FragmentPool.write(fragments, messages: messages, profileId: pid, conversationId: "conv", extractedBy: "测试",
                                              store: store, context: context), 2)
        let all = store.listAll(profileId: pid, context: context)
        let first = try XCTUnwrap(all.first { $0.subject == "岚舟" })
        XCTAssertEqual(first.sourceQuote, "岚舟说： 云桥城的灯太亮。", "换行并成空格")
        XCTAssertEqual(first.sourceNodeId, "n0", "原话和跳转锚是同一条消息")
        let second = try XCTUnwrap(all.first { $0.subject == "林栖" })
        XCTAssertEqual(second.sourceQuote, String(long.prefix(MemoryEntryLine.quoteLimit)) + "…", "长消息只存开头一截")
    }

    func testEditPageSourceFallsBackWhenMessageGone() throws {
        typealias Shown = MemorySourceTray.Shown
        XCTAssertEqual(MemorySourceTray.shown(live: "现在的原文", stored: "存下的", hasAnchor: true), Shown(quote: "现在的原文", gone: false))
        XCTAssertEqual(MemorySourceTray.shown(live: nil, stored: "存下的", hasAnchor: true), Shown(quote: "存下的", gone: true),
                       "消息没了：用存下的原话，并说一声")
        XCTAssertEqual(MemorySourceTray.shown(live: nil, stored: nil, hasAnchor: true), Shown(quote: nil, gone: true))
        XCTAssertEqual(MemorySourceTray.shown(live: nil, stored: "存下的", hasAnchor: false), Shown(quote: "存下的", gone: false))
        XCTAssertNil(MemorySourceTray.shown(live: nil, stored: nil, hasAnchor: false), "手加的条目没有出处")

        let context = try context()
        let m = try memory("认为云桥城的灯太亮。", subject: "岚舟", context)
        m.sourceNodeId = "n0"
        XCTAssertNil(MemoryConversationLink.sourceText(of: m, profileId: pid, context: context), "消息不在库里")
    }

    /// 整段写手交 msgs:[3,1,3,5]：存这一批 #1 #3 #5 那几条的 id（锚点仍是它交的第一个 #3）；
    /// 托盘按存的顺序取多条，删了 / 藏了 / 别的窗口的跳过；只挂一条或没挂的 = 空（照旧只显示锚点那一条）
    func testWholeWriterKeepsEverySourceAndTrayReadsThemInOrder() throws {
        let context = try context()
        let t = Date(timeIntervalSince1970: 1_793_000_000)
        let texts = [("user", "下周去槐序巷皮影作坊"), ("assistant", "要带什么吗"), ("user", "带上刻刀\n和那块牛皮"),
                     ("assistant", "好"), ("user", "青禾也一起去")]
        let messages = texts.enumerated().map { FragmentPool.Message(id: "p\($0.offset + 1)", role: $0.element.0, content: $0.element.1,
                                                                    date: t.addingTimeInterval(Double($0.offset) * 60)) }
        let batch = try FragmentPool.decodedWhole("""
        [{"subject":"岚舟","type":"fact","origin":"said","content":"下周和青禾去槐序巷皮影作坊，带刻刀和牛皮。","msgs":[3,1,3,5]},
         {"subject":"岚舟","type":"fact","origin":"said","content":"要带刻刀。","msgs":[3]}]
        """, messageCount: 5)
        let store = SwiftDataMemoryStore()
        XCTAssertEqual(try FragmentPool.write(batch.fragments, messages: messages, profileId: pid, conversationId: "conv", extractedBy: "测试",
                                              store: store, context: context), 2)
        let all = store.listAll(profileId: pid, context: context)
        let trip = try XCTUnwrap(all.first { $0.content.hasPrefix("下周") })
        XCTAssertEqual(trip.sourceNodeIds, ["p1", "p3", "p5"])
        XCTAssertEqual(trip.sourceNodeId, "p3", "跳转锚仍是写手交的第一个")
        XCTAssertEqual(trip.sourceQuote, "带上刻刀 和那块牛皮")
        let knife = try XCTUnwrap(all.first { $0.content == "要带刻刀。" })
        XCTAssertEqual(knife.sourceNodeIds, ["p3"])

        for (offset, message) in messages.enumerated() {
            let node = MessageNode(id: message.id, role: message.role, content: message.content, contentType: "text",
                                   createTime: message.date, parentId: nil, childrenIds: [], conversationId: "conv", profileId: pid)
            if offset == 0 { node.isTrashed = true }
            context.insert(node)
        }
        context.insert(MessageNode(id: "q1", role: "user", content: "别的窗口", contentType: "text", createTime: t,
                                   parentId: nil, childrenIds: [], conversationId: "other", profileId: pid))
        try context.save()
        trip.sourceNodeIds = ["p1", "p3", "q1", "p5"]
        let shown = MemoryConversationLink.sourceMessages(of: trip, profileId: pid, context: context)
        XCTAssertEqual(shown.map(\.text), ["带上刻刀\n和那块牛皮", "青禾也一起去"], "删了的、别的窗口的跳过；原文一个字不改")
        XCTAssertEqual(shown.map(\.isUser), [true, true])
        XCTAssertEqual(MemorySourceMessages.head(shown[0], assistant: "星砚", now: t).hasPrefix("You · "), true)
        XCTAssertEqual(MemorySourceMessages.head(MemorySourceMessage(isUser: false, at: nil, text: "好"), assistant: "星砚"), "星砚")
        XCTAssertEqual(MemoryConversationLink.sourceMessages(of: knife, profileId: pid, context: context), [], "只挂一条：照旧")
        let manual = try memory("手加的。", subject: nil, context)
        XCTAssertEqual(MemoryConversationLink.sourceMessages(of: manual, profileId: pid, context: context), [])
    }
}
