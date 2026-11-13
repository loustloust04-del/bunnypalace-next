#if os(macOS)
import MemoryCore
import AppKit
import SwiftUI
import XCTest
@testable import 记忆花园

@MainActor
final class RecallCardSmokeTests: XCTestCase {
    func testReceiptRendersOffscreen() throws {
        let selected: [RecallItem] = [
            .init(source: .init(profileId: "fictional-smoke", kind: .page, path: "人/林栖", version: "p1"),
                  text: "[档案·本轮相关]\n[[人/林栖]] 林栖\n现在：在云桥城整理地图", identities: ["林栖"], tokenCost: 30),
            .init(source: .init(profileId: "fictional-smoke", kind: .card, path: "memory/cc/航线.md", version: "c1"),
                  text: "[档案·本轮相关]\n条目：云桥航线\n要点：沿河航行\n下钻：memory/cc/航线.md|c1", identities: [], tokenCost: 30),
            .init(source: .init(profileId: "fictional-smoke", kind: .fragment, path: "fragment", version: "f1"),
                  text: "[关于星砚·本轮相关]\n林栖喜欢手绘地图", identities: [], tokenCost: 20)
        ]
        var receipt = RecallTurnReceipt(decision: .init(
            turnId: "turn", branchAnchor: "branch", origin: .user, gateReason: .search,
            tuning: RecallTestTuning.make(), topicAnchor: "云桥城", selected: selected, candidates: selected,
            suppressions: [], ignored: [], thawed: [], stateAfterResponse: .init()))
        receipt.reads = [
            .init(toolCallId: "read1", turnId: "turn", layer: "wiki", target: "人/林栖"),
            .init(toolCallId: "read2", turnId: "turn", layer: "original", target: "fictional-missing", status: "not_found")
        ]
        receipt.injectionRecord = .init(tokens: 128, stableCount: 2, hitCount: 3, at: Date(timeIntervalSince1970: 0))
        let node = MessageNode(id: "smoke-assistant", role: "assistant", content: "岚舟找到了地图",
                               contentType: "text", createTime: nil, parentId: nil, childrenIds: [],
                               conversationId: "fictional-smoke", profileId: "fictional-smoke")
        node.recallReceipt = receipt
        guard case .receipt(let model) = RecallCardPresentation.make(receipt: node.recallReceipt, legacyHitsEmpty: node.recallHits.isEmpty, mode: .inline) else {
            XCTFail("Receipt was not projected"); return
        }
        let host = NSHostingView(rootView: RecallReceiptCardContent(model: model, rowSpacing: 12, snippetSize: 14)
            .padding(20).frame(width: 540).environment(\.themeScope, .chat))
        let size = host.fittingSize
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recall-card-smoke.png")
        try data.write(to: url)
        print("RECALL_CARD_SMOKE image=\(url.path) groups=\(model.groups.map { $0.rows.count }) reads=\(model.reads.map(\.status)) size=\(size)")
        XCTAssertEqual(model.groups.map(\.kind), [.page, .card, .fragment])
        XCTAssertEqual(model.reads.map(\.status), ["success", "not_found"])
    }

    func testMessageRecallCardRendersReceiptWithoutLegacyHitsAndCollapsesEmptyNode() throws {
        let suite = "xctest-message-recall-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DisclosureMode.inline.rawValue, forKey: DisclosureKind.recall.key)
        let item = RecallItem(
            source: .init(profileId: "fictional-smoke", kind: .page, path: "人/林栖", version: "p1"),
            text: "[档案·本轮相关]\n[[人/林栖]] 林栖\n现在：在云桥城整理地图",
            identities: ["林栖"], tokenCost: 30)
        var receipt = RecallTurnReceipt(decision: .init(
            turnId: "turn", branchAnchor: "branch", origin: .user, gateReason: .search,
            tuning: RecallTestTuning.make(), topicAnchor: "云桥城", selected: [item], candidates: [item],
            suppressions: [], ignored: [], thawed: [], stateAfterResponse: .init()))
        let attempt = receipt.beginAttempt(id: "attempt")
        receipt.markAttempt(attempt, status: .interrupted)
        let node = MessageNode(id: "receipt-assistant", role: "assistant", content: "岚舟找到了地图",
                               contentType: "text", createTime: nil, parentId: nil, childrenIds: [],
                               conversationId: "fictional-smoke", profileId: "fictional-smoke")
        node.recallReceipt = receipt
        let host = NSHostingView(rootView: MessageRecallCardView(node: node)
            .frame(width: 540).environment(\.themeScope, .chat).defaultAppStorage(defaults))
        let initialSize = host.fittingSize
        host.setFrameSize(initialSize)
        host.layoutSubtreeIfNeeded()
        let receiptHeight = host.fittingSize.height
        XCTAssertGreaterThan(initialSize.height, 0, "首帧不能依赖空视图的 task 才加载回执")
        XCTAssertGreaterThan(receiptHeight, 0, "有回执、无旧 hits 时，首次布局必须显示「想起来了」")

        let emptyNode = MessageNode(id: "empty-assistant", role: "assistant", content: "没有召回",
                                    contentType: "text", createTime: nil, parentId: nil, childrenIds: [],
                                    conversationId: "fictional-smoke", profileId: "fictional-smoke")
        let emptyHost = NSHostingView(rootView: MessageRecallCardView(node: emptyNode)
            .frame(width: 540).environment(\.themeScope, .chat).defaultAppStorage(defaults))
        emptyHost.setFrameSize(emptyHost.fittingSize)
        emptyHost.layoutSubtreeIfNeeded()
        let emptyHeight = emptyHost.fittingSize.height
        XCTAssertEqual(emptyHeight, 0, "无回执、无旧 hits 时不能留下占位高度")
        print("RECALL_MESSAGE_CARD_SMOKE initialHeight=\(initialSize.height) receiptHeight=\(receiptHeight) emptyHeight=\(emptyHeight)")

        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("message-recall-card-smoke.png")
        try data.write(to: url)
        print("RECALL_MESSAGE_CARD_SMOKE image=\(url.path)")
    }

    func testColdStartKeepsVerifiedCard() async throws {
        try await Task.detached {
            let fixture = try RecallFullTextFixture()
            let card = try fixture.card()
            try fixture.page(cards: [card])
            let wiki = fixture.wiki
            let snapshot = WikiInjection.load(wiki)
            let ref = RecallSourceRef(profileId: fixture.profileId, kind: .card, path: card.path, version: card.version)
            let result = await RecallFullTextRetriever.fetch(
                profileId: fixture.profileId, text: "unrelated question", snapshot: snapshot,
                excluding: { [] }, tuning: RecallTestTuning.make(), source: { wiki }, indexer: .shared, keeping: [ref])
            XCTAssertEqual(result.kept.map(\.path), [card.path])
            print("RECALL_KEEP_COLD_SMOKE kept=\(result.kept.map(\.path)) status=\(result.status.state)")
            await fixture.clean()
        }.value
    }
}
#endif
