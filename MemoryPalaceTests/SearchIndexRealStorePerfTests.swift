import XCTest
@testable import 记忆花园

/// S5 Todo 0：拿真库副本量回填耗时 / 体积 / 查询耗时（数字写进 docs/review-search-s5.md）。
/// 副本只在本机 scratchpad，不存在就跳过；只读打开，只打印计数和耗时，不打印正文。
final class SearchIndexRealStorePerfTests: XCTestCase {

    private static let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["S5_REAL_STORE"]
        ?? "/private/tmp/claude-501/-Users-susu-Desktop-susu-project------MemoryPalace/6973a72e-6248-4a09-8ba4-2f0bbfba5415/scratchpad/s5/unified.store")

    func testBuildAndQueryOnRealStoreCopy() throws {
        guard FileManager.default.fileExists(atPath: Self.source.path) else {
            throw XCTSkip("没有真库副本：\(Self.source.path)")
        }
        let outDir = Self.source.deletingLastPathComponent().appendingPathComponent("s5-perf-\(UUID().uuidString)")
        let outURL = outDir.appendingPathComponent("search-index.sqlite")
        defer { try? FileManager.default.removeItem(at: outDir) }

        let src = try SQLiteDB(url: Self.source, readOnly: true)
        let store = try SearchIndexStore.open(at: outURL)
        let t0 = CFAbsoluteTimeGetCurrent()
        var readClean = 0.0
        var write = 0.0
        var total = 0
        var nodesByProfile: [String: Int] = [:]
        let s = try src.prepare("SELECT ZID, ZCONVERSATIONID, ZPROFILEID, ZROLE, ZCREATETIME, ZISTRASHED, ZCONTENT FROM ZMESSAGENODE ORDER BY ZID")
        var batch: [SearchIndexDoc] = []
        func flush() throws {
            let tw = CFAbsoluteTimeGetCurrent()
            try store.apply(upserts: batch, epoch: store.epoch)
            write += CFAbsoluteTimeGetCurrent() - tw
            batch.removeAll(keepingCapacity: true)
        }
        var tr = CFAbsoluteTimeGetCurrent()
        while try s.step() {
            let role = s.text(3) ?? ""
            let pid = s.text(2) ?? ""
            nodesByProfile[pid, default: 0] += 1
            batch.append(SearchIndexDoc(
                nodeId: s.text(0) ?? "", conversationId: s.text(1) ?? "", profileId: pid, role: role,
                created: s.optionalDouble(4).map(Date.init(timeIntervalSinceReferenceDate:)),
                trashed: s.int64(5) != 0,
                body: ContentCleaner.visibleText(s.text(6) ?? "", isUser: role == "user", cached: false),
                identifierKey: nil
            ))
            total += 1
            if batch.count == SearchIndexer.batchSize {
                readClean += CFAbsoluteTimeGetCurrent() - tr
                try flush()
                tr = CFAbsoluteTimeGetCurrent()
            }
        }
        readClean += CFAbsoluteTimeGetCurrent() - tr
        try flush()
        let tBuilt = CFAbsoluteTimeGetCurrent()
        let sizeBeforeOptimize = store.fileSizeBytes()
        try store.optimize()
        let tOpt = CFAbsoluteTimeGetCurrent()
        print(String(format: "[S5-PERF] nodes=%d build=%.2fs (read+clean+segment≈%.2fs write=%.2fs) optimize=%.2fs size=%.1fMB (before optimize %.1fMB)",
                     total, tBuilt - t0, readClean, write, tOpt - tBuilt,
                     Double(store.fileSizeBytes()) / 1_048_576, Double(sizeBeforeOptimize) / 1_048_576))

        let biggest = nodesByProfile.max { $0.value < $1.value }?.key ?? ""
        for word in ["键盘", "的", "花园"] {
            let tq = CFAbsoluteTimeGetCurrent()
            let hits = try XCTUnwrap(store.hits(word: word, profileId: biggest, roles: ["user", "assistant"]))
            let dtBig = CFAbsoluteTimeGetCurrent() - tq
            let tb = CFAbsoluteTimeGetCurrent()
            let bodies = try store.bodies(nodeIds: hits.map(\.nodeId))
            let dtBodies = CFAbsoluteTimeGetCurrent() - tb
            let ta = CFAbsoluteTimeGetCurrent()
            var all = 0
            for pid in nodesByProfile.keys {
                all += try XCTUnwrap(store.hits(word: word, profileId: pid, roles: ["user", "assistant"])).count
            }
            let dtAll = CFAbsoluteTimeGetCurrent() - ta
            print(String(format: "[S5-PERF] q=%@ biggestProfile hits=%d %.1fms bodies=%.1fms | all %d profiles hits=%d %.1fms",
                         word, hits.count, dtBig * 1000, dtBodies * 1000, nodesByProfile.count, all, dtAll * 1000))
            XCTAssertEqual(bodies.count, hits.count)
        }
    }
}
