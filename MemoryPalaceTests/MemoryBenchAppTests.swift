import XCTest
import MemoryCore
@testable import 记忆花园

final class MemoryBenchAppTests: XCTestCase {
    private var dir: URL!
    private var store: MemoryBenchStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xctest-bench-app-\(UUID().uuidString)", isDirectory: true)
        store = MemoryBenchStore(root: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func set(_ id: String, writer: String = "c2", inputs: [String] = ["a"]) -> MemoryBenchSet {
        MemoryBenchSet(id: id, name: "考卷 \(id)", writer: writer, source: .floor, note: nil, createdAt: nil,
                       cases: inputs.enumerated().map { i, s in
                           MemoryBenchCase(id: "\(i)", title: "t", input: .object(["x": .string(s)]), labels: [], note: nil)
                       })
    }
    func testBuiltInC2ProbeShipsWithApp() throws {
        let sets = MemoryBenchStore.builtInSets()
        let probe = try XCTUnwrap(sets.first { $0.id == "c2-probe" }, "内置探针要打进 app 包")
        XCTAssertEqual(probe.writer, "c2")
        XCTAssertEqual(probe.source, .builtin)
        XCTAssertEqual(probe.cases.map(\.id), (1...12).map { String(format: "%02d", $0) })
        for c in probe.cases {
            let input = try MemoryBenchC2Writer.input(c)
            XCTAssertTrue((5...7).contains(input.messages.count), "\(c.id) 几轮对话原样搬过来")
            XCTAssertEqual(input.names.user, "岚舟")
            XCTAssertFalse(c.labels.isEmpty, "\(c.id) 预期拆成了标签")
            XCTAssertTrue(c.labels.allSatisfy { !$0.keys.isEmpty && [MemoryBenchLabel.shouldHave, MemoryBenchLabel.shouldNotHave].contains($0.kind) })
        }
        let haiku = probe.cases.flatMap(\.labels).filter { $0.from.contains("人判 10-23") }
        XCTAssertEqual(Set(haiku.map { $0.id.prefix(2) }), ["04", "05", "08", "10", "11"],
                       "Haiku 那 4 条错 + 试写台 live 复核出的 05（一次性建议记成承诺）挂成不该记")
        XCTAssertEqual(probe.revision, MemoryBenchStore.builtInSets().first { $0.id == "c2-probe" }?.revision, "版本号稳定")
    }
    func testSetsRoundTripAndBuiltInsFirst() throws {
        try store.saveSet(set("mine"))
        try store.saveSet(set("a2-set", writer: "a2"))
        XCTAssertEqual(store.floorSets().map(\.id).sorted(), ["a2-set", "mine"])
        let c2 = store.sets(writer: "c2")
        XCTAssertEqual(c2.first?.id, "c2-probe", "内置的在前")
        XCTAssertEqual(c2.last?.id, "mine")
        XCTAssertFalse(c2.contains { $0.writer != "c2" })
        try store.deleteSet(id: "mine")
        XCTAssertEqual(store.floorSets().map(\.id), ["a2-set"])
        try store.deleteSet(id: "not-there")
    }
}
