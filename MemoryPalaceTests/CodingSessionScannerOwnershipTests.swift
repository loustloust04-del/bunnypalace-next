#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-a3：扫描归属（最长根）、同 key 多副本裁决与回退、事务内守卫、幸存副本上位、墓碑挡副本、按会话找实例。
/// 用假 adapter（`ok…` 能解析、别的抛错），全在 tmp。
final class CodingSessionScannerOwnershipTests: XCTestCase {
    struct FakeAdapter: CodingSessionAdapter {
        let agent: CodingAgent
        let root: URL

        var dataRoots: [URL] { [root] }

        func listSessionFiles() -> [CodingSessionFileRef] {
            CodingParse.listJSONLRefs(root, agent, nativeId: { $0 })
        }

        func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
            let text = try String(contentsOfFile: ref.filePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("ok") else { throw CodingSessionError.unreadable(ref.filePath) }
            let meta = CodingSessionMeta(key: "\(agent.rawValue):\(ref.nativeId)", nativeId: ref.nativeId, agent: agent, title: text,
                                         projectPath: "", projectName: "", filePath: ref.filePath, createdAt: ref.mtimeMs,
                                         updatedAt: ref.mtimeMs, messageCount: 1, sizeBytes: ref.size, gitBranch: nil, model: nil,
                                         tokensUsed: nil, archived: false, source: nil)
            return CodingParsedSession(meta: meta, units: [CodingIndexUnit(seq: 0, role: .user, timestamp: nil, text: text)], unknownLines: 0)
        }

        func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
            CodingParsedTranscript(meta: try parseSession(ref).meta, mainline: [], sidechains: [], unknownLines: 0)
        }

        func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
            FakeAdapter(agent: agent, root: dir)
        }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-scan-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func write(_ rel: String, _ text: String, mtime: TimeInterval) throws -> URL {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: url.path)
        return url
    }

    private func fake(_ agent: CodingAgent, _ rel: String) -> FakeAdapter {
        FakeAdapter(agent: agent, root: dir.appendingPathComponent(rel))
    }

    private func makeIndex() throws -> CodingSessionIndex {
        try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
    }

    func testFileBelongsOnlyToLongestRoot() throws {
        try write("a/y.jsonl", "ok outer", mtime: 1_000)
        let deep = try write("a/deep/x.jsonl", "ok inner", mtime: 1_000)
        let outer = fake(.pi, "a"), inner = fake(.omp, "a/deep")
        let index = try makeIndex()
        _ = try CodingSessionScanner(index: index, adapters: [outer, inner]).run()
        XCTAssertNotNil(try index.session(key: "pi:y"))
        XCTAssertNotNil(try index.session(key: "omp:x"))
        XCTAssertNil(try index.session(key: "pi:x"), "更深的根认领了，外层实例不许写")
        XCTAssertEqual(CodingSessionRoster.ownerIndex(of: deep.path, in: [outer, inner]), 1)
        XCTAssertNil(CodingSessionRoster.ownerIndex(of: "/elsewhere/z.jsonl", in: [outer, inner]))
        XCTAssertNil(CodingSessionRoster.ownerIndex(of: dir.appendingPathComponent("a/y.jsonl").path, in: [fake(.pi, "a-sibling")]),
                     "前缀相同的兄弟目录不算")
        XCTAssertEqual(CodingSessionRoster.ownerIndex(of: dir.appendingPathComponent("db/state.db").path + "#s1",
                                                      in: [fake(.hermes, "db/state.db")]), 0, "虚拟路径剥回库路径再认")
    }

    func testFallbackWhenWinnerBrokenFromStart() throws {
        let older = try write("r1/s.jsonl", "ok old", mtime: 1_000)
        try write("r2/s.jsonl", "broken", mtime: 2_000)
        let index = try makeIndex()
        _ = try CodingSessionScanner(index: index, adapters: [fake(.pi, "r1"), fake(.pi, "r2")]).run()
        XCTAssertEqual(try index.session(key: "pi:s")?.title, "ok old", "胜者坏了回退败者，会话不能消失")
        XCTAssertEqual(try index.session(key: "pi:s")?.filePath, older.path)
    }

    func testGuardAndSurvivorPromotion() throws {
        let older = try write("r1/s.jsonl", "ok old", mtime: 1_000)
        let newer = try write("r2/s.jsonl", "ok new", mtime: 2_000)
        let a = fake(.pi, "r1"), b = fake(.pi, "r2")
        let index = try makeIndex()
        let scanner = CodingSessionScanner(index: index, adapters: [a, b])
        _ = try scanner.run()
        XCTAssertEqual(try index.session(key: "pi:s")?.title, "ok new", "mtime 新者胜")

        _ = try scanner.scanFiles([try XCTUnwrap(a.fileRef(older))])
        XCTAssertEqual(try index.session(key: "pi:s")?.filePath, newer.path, "败方后发的增量不覆盖仍在盘上的胜方")

        _ = try scanner.scanFiles([try XCTUnwrap(a.fileRef(older)), try XCTUnwrap(b.fileRef(newer))])
        XCTAssertEqual(try index.session(key: "pi:s")?.filePath, newer.path, "同一批两份也按 mtime 裁")

        try FileManager.default.removeItem(at: newer)
        _ = try scanner.scanFiles([], removedPaths: [newer.path])
        XCTAssertEqual(try index.session(key: "pi:s")?.filePath, older.path, "胜者被删 → 幸存副本上位")
        XCTAssertEqual(try index.session(key: "pi:s")?.title, "ok old")
    }

    func testTombstonedKeyBlocksEveryCopy() throws {
        try write("r1/s.jsonl", "ok old", mtime: 1_000)
        try write("r2/s.jsonl", "ok new", mtime: 2_000)
        let index = try makeIndex()
        let scanner = CodingSessionScanner(index: index, adapters: [fake(.pi, "r1"), fake(.pi, "r2")])
        _ = try scanner.run(isTombstoned: { _, key in key == "pi:s" })
        XCTAssertNil(try index.session(key: "pi:s"), "删过的会话，别的副本也不得复活")
    }

    func testOwnerOfMetaPicksInstanceByRoot() {
        let a = fake(.pi, "r1"), b = fake(.pi, "r2")
        func meta(_ agent: CodingAgent, _ path: String) -> CodingSessionMeta {
            CodingSessionMeta(key: "\(agent.rawValue):s", nativeId: "s", agent: agent, title: "t", projectPath: "", projectName: "",
                              filePath: path, createdAt: 1, updatedAt: 1, messageCount: 1, sizeBytes: 1,
                              gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil)
        }
        XCTAssertEqual(CodingSessionRoster.owner(of: meta(.pi, dir.appendingPathComponent("r2/s.jsonl").path), in: [a, b])?.dataRoots,
                       b.dataRoots, "按根找实例，不是同家第一个")
        XCTAssertEqual(CodingSessionRoster.owner(of: meta(.pi, "/elsewhere/s.jsonl"), in: [a, b])?.dataRoots, a.dataRoots, "根外回同家第一个")
        XCTAssertNil(CodingSessionRoster.owner(of: meta(.omp, "/elsewhere/s.jsonl"), in: [a, b]))
    }
}
#endif
