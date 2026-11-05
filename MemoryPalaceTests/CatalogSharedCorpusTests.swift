import XCTest
@testable import 记忆花园

@MainActor
final class CatalogSharedCorpusTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_792_367_900)

    private struct Sample {
        let marker: String
        let quartz: Int
        let zephyr: Int
        let filler: Int
        var body: String {
            ([marker] + Array(repeating: "quartz", count: quartz) + Array(repeating: "zephyr", count: zephyr)
                + Array(repeating: "filler", count: filler)).joined(separator: " ")
        }
    }

    private let raw = [
        Sample(marker: "rawone", quartz: 8, zephyr: 0, filler: 2),
        Sample(marker: "rawtwo", quartz: 2, zephyr: 0, filler: 15),
        Sample(marker: "rawthree", quartz: 1, zephyr: 0, filler: 3),
        Sample(marker: "rawfour", quartz: 4, zephyr: 0, filler: 6),
        Sample(marker: "rawfive", quartz: 1, zephyr: 0, filler: 30),
        Sample(marker: "rawsix", quartz: 3, zephyr: 0, filler: 0),
        Sample(marker: "rawseven", quartz: 1, zephyr: 0, filler: 10),
        Sample(marker: "raweight", quartz: 2, zephyr: 0, filler: 1),
    ]
    private let aline = [
        Sample(marker: "alineone", quartz: 0, zephyr: 1, filler: 0),
        Sample(marker: "alinetwo", quartz: 1, zephyr: 2, filler: 6),
        Sample(marker: "alinethree", quartz: 1, zephyr: 4, filler: 3),
        Sample(marker: "alinefour", quartz: 3, zephyr: 1, filler: 8),
    ]
    private let fragments = [
        Sample(marker: "fragmentone", quartz: 0, zephyr: 2, filler: 2),
        Sample(marker: "fragmenttwo", quartz: 6, zephyr: 0, filler: 1),
        Sample(marker: "fragmentthree", quartz: 1, zephyr: 0, filler: 3),
        Sample(marker: "fragmentfour", quartz: 3, zephyr: 0, filler: 20),
        Sample(marker: "fragmentfive", quartz: 2, zephyr: 0, filler: 10),
        Sample(marker: "fragmentsix", quartz: 1, zephyr: 0, filler: 1),
    ]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-shared-corpus-\(UUID().uuidString)")
        for (index, sample) in aline.enumerated() {
            let id = "aline00\(index + 1)-window"
            let segment = SessionSegment(kind: .rolling, title: "虚构素材", start: now.addingTimeInterval(-300), end: now,
                                         from: 0, to: 1, lastNodeId: nil, story: sample.body, quotes: "", pending: "")
            try SessionSummaryStore.save(.init(conversationId: id, title: "虚构素材", compressedCount: 1,
                                               segments: [segment], updatedAt: now), in: SessionSummaryStore.dir(root: root))
        }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testActualWriterTopTenUsesSharedCorpusNotIndependentLaneScores() async throws {
        let originals = raw.enumerated().map { index, sample in
            SearchService.CatalogNode(profileId: "synthetic-corpus", conversationId: "raw-window", nodeId: "raw-node-\(index)",
                                      title: "虚构素材", created: now, role: "user", onMain: true, body: sample.body)
        }
        let pool = fragments.map { CatalogFragment(id: UUID(), content: $0.body, category: "fact", day: MemoryDay.key(now)) }
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let material = await CatalogWriter.material(.init(path: "楼层/主题/异质语料", title: "quartz zephyr", kind: .topic, existing: false),
                                                     fragments: [], floorPrompt: "", wiki: wiki, memoryRoot: root, now: now,
                                                     snapshot: pool, embedder: CatalogFakeEmbedder.unavailable(),
                                                     originalSearch: { _, _, _ in originals })
        var actual = ""
        let parsed = try await CatalogWriter.write(material, names: .init(userName: "{u}", assistantName: "{c}"), wiki: wiki,
                                                   caller: { _, user in
            actual = user
            return "{\"items\":[{\"type\":\"new_page\",\"path\":\"楼层/主题/异质语料\",\"records\":[{\"text\":\"虚构语料中的第三段\",\"aline\":[{\"layer\":\"A2\",\"window\":\"aline003\",\"segment\":1}]}]}]}"
        }, drafts: nil)
        let markers = Set((raw + aline + fragments).map(\.marker))
        let actualOrder = actual.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz").inverted)
            .filter(markers.contains)
        // 独立 bm25s 0.2.14 Lucene oracle；参数及分路反例见 P1 复盘返工第 4 条。
        let sharedTopTen = ["alinethree", "alinetwo", "alineone", "fragmentone", "alinefour", "rawone", "rawsix", "rawfour", "raweight", "fragmenttwo"]
        let perLaneTopTen = ["fragmentone", "alinefour", "alinethree", "alinetwo", "fragmenttwo", "fragmentsix", "fragmentfive", "fragmentthree", "fragmentfour", "alineone"]
        XCTAssertEqual(actualOrder, sharedTopTen)
        XCTAssertNotEqual(actualOrder, perLaneTopTen)
        XCTAssertEqual(parsed?.items.first?.cites.first?.windowId, "aline003-window")
        XCTAssertEqual(parsed?.items.first?.cites.first?.segment, 1)
        print("[P1 FIX1 SHARED CORPUS] actual writer top ten: \(actualOrder.joined(separator: ","))")
    }
}
