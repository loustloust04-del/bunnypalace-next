import XCTest
import SwiftData
@testable import 记忆花园

/// air-backup.py ↔ app 的快照请求（research-backup-while-open A2）。临时目录 + 合成库，直接调 processPending（不起监听）。
final class AirSnapshotResponderTests: XCTestCase {
    private var dir: URL!
    private var responder: AirSnapshotResponder!
    private var container: ModelContainer!
    private let fm = FileManager.default

    private var root: URL { responder.root }
    private var requests: URL { responder.requests }

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("air-snap-\(UUID().uuidString)", isDirectory: true)
        let live = dir.appendingPathComponent("live", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        let store = live.appendingPathComponent("unified.store")
        let schema = ProfileManager.makeFullSchema()
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration("unified", schema: schema, url: store, cloudKitDatabase: .none)])
        let ctx = ModelContext(container)
        for i in 0..<50 {
            ctx.insert(MessageNode(id: "n\(i)", role: "user", content: "m\(i)", contentType: "text", createTime: Date(),
                                   parentId: nil, childrenIds: [], conversationId: "c", profileId: "p"))
        }
        try ctx.save()
        responder = AirSnapshotResponder(root: dir.appendingPathComponent("air-snapshot", isDirectory: true),
                                         store: store, external: live.appendingPathComponent(".unified_SUPPORT", isDirectory: true))
        responder.appBuild = { "test-build" }
        responder.fingerprint = { "fp" }
        responder.freeBytes = { _ in nil }
        try fm.createDirectory(at: responder.requests, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        container = nil
        try? fm.removeItem(at: dir)
    }

    private func drop(_ name: String, age: TimeInterval = 0) throws {
        let url = requests.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        if age > 0 { try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path) }
    }

    private func failure(_ id: String) throws -> AirSnapshotResponder.Failure {
        try JSONDecoder().decode(AirSnapshotResponder.Failure.self, from: Data(contentsOf: responder.failureURL(id)))
    }

    private func listing(_ url: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func testRequestProducesSnapshotAndConsumesRequest() throws {
        try drop("r1.request")
        responder.processPending()
        let m = try JSONDecoder().decode(StoreSnapshotter.Manifest.self,
                                         from: Data(contentsOf: root.appendingPathComponent("r1/snapshot.json")))
        XCTAssertEqual(m.id, "r1")
        XCTAssertEqual(m.messageCount, 50)
        XCTAssertEqual(m.appBuild, "test-build")
        XCTAssertEqual(listing(requests), [], "做完删请求")
        XCTAssertEqual(listing(root), ["r1", "requests"])

        responder.processPending()
        XCTAssertEqual(listing(root), ["r1", "requests"], "没有新请求：不重做、不删成品")
    }

    func testReleaseDeletesSnapshotAndFailure() throws {
        try drop("r1.request")
        responder.processPending()
        try drop("r1.release")
        try Data("{}".utf8).write(to: responder.failureURL("r1"))
        responder.processPending()
        XCTAssertEqual(listing(root), ["requests"])
        XCTAssertEqual(listing(requests), [])
    }

    func testReleaseBeforeServedCancelsRequest() throws {
        try drop("r1.request")
        try drop("r1.release")
        responder.processPending()
        XCTAssertEqual(listing(root), ["requests"], "Mac 已放弃（超时发了 release）：不再做")
        XCTAssertEqual(listing(requests), [])
    }

    func testOnlyNewestOfSeveralRequestsIsDone() throws {
        try drop("old.request", age: 60)
        try drop("new.request")
        responder.processPending()
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("new/snapshot.json").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("old").path))
        XCTAssertEqual(try failure("old").reason, "被更新的请求 new 取代")
        XCTAssertEqual(listing(requests), [])
    }

    func testRequestForServedIdIsNotRedone() throws {
        try drop("r1.request")
        responder.processPending()
        let first = try fm.attributesOfItem(atPath: root.appendingPathComponent("r1/unified.store").path)[.modificationDate] as? Date
        try drop("r1.request")
        responder.processPending()
        let second = try fm.attributesOfItem(atPath: root.appendingPathComponent("r1/unified.store").path)[.modificationDate] as? Date
        XCTAssertEqual(first, second)
        XCTAssertEqual(listing(requests), [])
    }

    func testFailureIsWrittenForAirBackupToReport() throws {
        responder.freeBytes = { _ in 1 }
        try drop("r1.request")
        responder.processPending()
        XCTAssertTrue(try failure("r1").reason.contains("设备空间不够"))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("r1").path))
        XCTAssertEqual(listing(requests), [])
        XCTAssertFalse(listing(root).contains { $0.hasPrefix(".tmp-") })
    }

    func testInvalidIdsAreDroppedWithoutTouchingPaths() throws {
        try drop("bad id!.request")
        try drop("..request")
        responder.processPending()
        XCTAssertEqual(listing(requests), [])
        XCTAssertEqual(listing(root), ["requests"])
        XCTAssertTrue(AirSnapshotResponder.isValid("20261106-221500-ab12_C"))
        XCTAssertFalse(AirSnapshotResponder.isValid("a/b"))
        XCTAssertFalse(AirSnapshotResponder.isValid(String(repeating: "a", count: 65)))
    }

    func testStaleLeftoversAreCleaned() throws {
        let tmp = root.appendingPathComponent(".tmp-crashed", isDirectory: true)
        let oldDone = root.appendingPathComponent("old", isDirectory: true)
        let freshDone = root.appendingPathComponent("fresh", isDirectory: true)
        for d in [tmp, oldDone, freshDone] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: responder.failureURL("oldfail"))
        let threeHours = Date().addingTimeInterval(-3 * 3600)
        for p in [oldDone.path, responder.failureURL("oldfail").path] {
            try fm.setAttributes([.modificationDate: threeHours], ofItemAtPath: p)
        }
        try drop("forgotten.release", age: 3 * 3600)
        responder.processPending()
        XCTAssertEqual(listing(root), ["fresh", "requests"], "残留 .tmp-、2 小时前的成品 / 失败记录清掉；新的留着")
    }
}
