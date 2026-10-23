import MachO
import XCTest
@testable import 记忆花园

/// 秒连尺子（plan-app-instant-connect §2）：时间戳表、忙段累加、候选记录、connect_report 新字段组装
final class ConnectRulerTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testOffsetsRelativeToEntryFirstOccurrenceWins() {
        let marks: [LaunchMarks.Mark] = [
            .init(name: "entry", ns: 1_000 * ms), .init(name: "props", ns: 1_120 * ms),
            .init(name: "initBegin", ns: 1_400 * ms), .init(name: "contentAppear", ns: 2_000 * ms),
            .init(name: "contentAppear", ns: 9_000 * ms),
        ]
        XCTAssertEqual(LaunchMarks.offsets(marks), ["entry": 0, "props": 120, "initBegin": 400, "contentAppear": 1_000])
    }

    func testOffsetsConnectFromEpisodeEntry() {
        let marks: [LaunchMarks.Mark] = [.init(name: "entry", ns: 1_000 * ms), .init(name: "connect", ns: 9_999 * ms)]
        XCTAssertEqual(LaunchMarks.offsets(marks, connectNs: 1_300 * ms)?["connect"], 300)
    }

    func testOffsetsNilWithoutEntryAnchor() {
        XCTAssertNil(LaunchMarks.offsets([.init(name: "props", ns: 5)]))
    }

    func testBusyAccumulatorCountsSegmentsBlocksAndInProgress() {
        var acc = BusyAccumulator(startNs: 0)
        acc.close(at: 30 * ms)          // 窗口起点所在的段：30ms
        acc.open(at: 100 * ms)
        acc.close(at: 180 * ms)         // 80ms 块
        acc.close(at: 500 * ms)         // 没开段的重复收段不算
        acc.open(at: 600 * ms)
        let s = acc.summary(at: 660 * ms)   // 进行中 60ms 也算，且 >50ms
        XCTAssertEqual(s.ms, 170, accuracy: 0.001)
        XCTAssertEqual(s.blocks50, 2)
        XCTAssertEqual(s.maxMs, 80, accuracy: 0.001)
        XCTAssertFalse(s.capped)
        // summary 不改累加器本身
        XCTAssertEqual(acc.summary(at: 610 * ms).ms, 120, accuracy: 0.001)
    }

    func testBusyWindowFinishIsIdempotentAndRemovesObservers() {
        let start = ConnectClock.nowNs()
        let w = ConnectBusyWindow(startNs: start)
        let s1 = w.finish(at: start + 10 * ms)
        XCTAssertEqual(s1.ms, 10, accuracy: 0.001)
        XCTAssertEqual(w.finish(at: start + 999 * ms), s1)
    }

    func testCandidateJSONOnlyNumbersAndHost() {
        let c = ConnectCandidateRecord(host: "192.168.31.20", resumeNs: 10 * ms, callbackNs: 50 * ms, enterNs: 580 * ms,
                                       endNs: 585 * ms, won: true, late: false, taskMs: 36.6, gen: 4, slot: 1)
        let o = c.json(entryNs: 0)
        XCTAssertEqual(o["h"] as? String, "192.168.31.20")
        XCTAssertEqual(o["task_ms"] as? Int, 37)
        XCTAssertEqual(o["id"] as? String, "4.1")
        XCTAssertEqual(o["round"] as? Int, 4)
        XCTAssertEqual(o["at_ms"] as? Int, 10)
        XCTAssertEqual(o["cb_ms"] as? Int, 40)
        XCTAssertEqual(o["queue_ms"] as? Int, 530)
        XCTAssertEqual(o["handle_ms"] as? Int, 5)
        XCTAssertEqual(o["won"] as? Bool, true)
        XCTAssertNil(o["late"])
        XCTAssertEqual(Set(o.keys), ["id", "round", "h", "at_ms", "task_ms", "cb_ms", "queue_ms", "handle_ms", "won"])

        let lost = ConnectCandidateRecord(host: "100.1.2.3", resumeNs: nil, callbackNs: 0, enterNs: 0, endNs: 0, won: false, late: true)
        XCTAssertNil(lost.json(entryNs: 0)["task_ms"])
        XCTAssertNil(lost.json(entryNs: 0)["cb_ms"])
        XCTAssertEqual(lost.json(entryNs: 0)["late"] as? Bool, true)
    }

    func testProbeRoundTimingsMapsTaskToSlotAndResolves() {
        let t = ProbeRoundTimings()
        t.register(slot: 0, taskId: 7)
        t.register(slot: 1, taskId: 8)
        t.noteTask(taskId: 7, ms: 5)     // metrics 先于 resume 时刻到也能落位
        t.noteResume(slot: 0, at: 100)
        t.noteResume(slot: 1, at: 200)
        t.noteTask(taskId: 8, ms: 42)
        t.noteTask(taskId: 99, ms: 1)   // 不认识的 task 丢掉
        XCTAssertEqual(t.resumeNs(slot: 1), 200)
        XCTAssertEqual(t.taskMs(slot: 0), 5)
        XCTAssertEqual(t.taskMs(slot: 1), 42)

        var ep = ConnectRulerEpisode(entryNs: 0)
        ep.noteCandidate(ConnectCandidateRecord(host: "b", resumeNs: 200, callbackNs: 300, enterNs: 400, endNs: 500,
                                                won: true, late: false, timings: t, slot: 1))
        XCTAssertNil(ep.candidates[0].taskMs)
        ep.resolveMetrics()
        XCTAssertEqual(ep.candidates[0].taskMs, 42)
    }

    func testEpisodeFieldsMonotonicOffsetsAndWallStamps() {
        var ep = ConnectRulerEpisode(entryNs: 1_000 * ms)
        let task = ObjectIdentifier(NSObject())
        ep.noteRequest(at: 1_020 * ms, wall: Date(timeIntervalSince1970: 100))
        ep.noteWSResume(attempt: 3, gen: 7, via: "7.0", at: 1_600 * ms, wall: Date(timeIntervalSince1970: 200))   // 首个请求已记，不覆盖
        ep.noteClientInfo(at: 1_850 * ms)   // 没打开前不认
        XCTAssertTrue(ep.noteOpen(task: task, lastTask: task, attempt: 3, currentGen: 7, wsOpenNs: 1_650 * ms,
                                  wsOpenWall: Date(timeIntervalSince1970: 100.625), uiNs: 1_900 * ms, uiWall: Date(timeIntervalSince1970: 100.875)))
        ep.noteClientInfo(at: 1_905 * ms)
        ep.noteClientInfo(at: 1_990 * ms)   // 只认第一次
        ep.busy = BusySummary(ms: 412.4, blocks50: 3, maxMs: 230.6, capped: false, windowMs: 900)
        ep.launchFail = true
        let launch = ConnectRulerEpisode.LaunchInfo(segs: ["entry": 0, "connect": 900], preMainMs: 380.4, source: "icon", recovery: ["stRecover"])
        let counts = ConnectRunCounters.Snapshot(started: 2, ok: 1, replaced: 1, reportFailed: 0)
        let o = ep.fields(finishNs: 1_910 * ms, deviceId: "dev-1", launch: launch, counts: counts)

        XCTAssertEqual(o["rev"] as? String, ConnectRuler.revision)
        XCTAssertEqual(o["build"] as? String, "debug")
        XCTAssertEqual(o["run"] as? String, ConnectRuler.runId)
        XCTAssertEqual(o["dev"] as? String, "dev-1")
        XCTAssertEqual(o["sw"] as? [String: String], [:])
        XCTAssertEqual(o["bin"] as? String, ConnectRuler.binaryUUID)
        XCTAssertEqual(o["counts"] as? [String: Int], ["started": 2, "ok": 1, "replaced": 1, "report_failed": 0])
        XCTAssertEqual(o["launch_src"] as? String, "icon")
        XCTAssertEqual(o["recovery"] as? [String], ["stRecover"])
        XCTAssertEqual(o["first_req_ms"] as? Int, 20)
        XCTAssertEqual(o["ws_resume_ms"] as? Int, 600)
        XCTAssertEqual(o["ws_open_ms"] as? Int, 650)
        XCTAssertEqual(o["ui_ms"] as? Int, 900)
        XCTAssertEqual(o["client_info_ms"] as? Int, 905)
        XCTAssertEqual(o["finish_ms"] as? Int, 910)
        XCTAssertEqual(o["ws_attempt"] as? Int, 3)
        XCTAssertEqual(o["ws_gen"] as? Int, 7)
        XCTAssertNil(o["ws_invalid"])
        XCTAssertEqual(o["first_request_at"] as? Int, 100_000)
        XCTAssertEqual(o["ws_open_at"] as? Int, 100_625)
        XCTAssertEqual(o["ui_connected_at"] as? Int, 100_875)
        XCTAssertEqual(o["busy_ms"] as? Int, 412)
        XCTAssertEqual(o["busy_n50"] as? Int, 3)
        XCTAssertEqual(o["busy_max_ms"] as? Int, 231)
        XCTAssertNil(o["busy_capped"])
        XCTAssertEqual(o["busy_window_ms"] as? Int, 900)
        XCTAssertEqual(o["ws_via"] as? String, "7.0")
        XCTAssertNil(o["cand_dropped"])
        XCTAssertEqual(o["segs"] as? [String: Int], ["entry": 0, "connect": 900])
        XCTAssertEqual(o["pre_main_ms"] as? Int, 380)
        XCTAssertEqual(o["launch_fail"] as? Bool, true)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(o))
    }

    func testEpisodeFieldsOmitWhatWasNeverReached() {
        let o = ConnectRulerEpisode(entryNs: 5).fields(finishNs: 5, deviceId: "d", launch: nil)
        for k in ["launch_src", "recovery", "first_req_ms", "ws_open_ms", "ui_ms", "client_info_ms", "ws_attempt", "ws_open_at", "busy_ms", "segs", "pre_main_ms", "launch_fail", "ws_invalid"] {
            XCTAssertNil(o[k], k)
        }
        XCTAssertEqual((o["candidates"] as? [Any])?.count, 0)
    }

    /// sol R1-4：旧 task 的 didOpen 在新一段探测期间过了 ===，归属对不上只计 invalid，不写时间戳
    func testOpenFromStaleAttemptIsInvalid() {
        let oldTask = NSObject(), newTask = NSObject()   // 要持有：临时对象一释放地址就会被复用
        let old = ObjectIdentifier(oldTask), new = ObjectIdentifier(newTask)
        let wall = Date(timeIntervalSince1970: 1)
        var ep = ConnectRulerEpisode(entryNs: 0)
        // 这一段还没开过 WS（新一段在探测），旧 task 打开
        XCTAssertFalse(ep.noteOpen(task: old, lastTask: old, attempt: 1, currentGen: 2, wsOpenNs: 5, wsOpenWall: wall, uiNs: 6, uiWall: wall))
        ep.noteWSResume(attempt: 2, gen: 3, via: "direct", at: 10, wall: wall)
        // task 不是最后那次尝试的
        XCTAssertFalse(ep.noteOpen(task: old, lastTask: new, attempt: 2, currentGen: 3, wsOpenNs: 15, wsOpenWall: wall, uiNs: 16, uiWall: wall))
        // 代次已变
        XCTAssertFalse(ep.noteOpen(task: new, lastTask: new, attempt: 2, currentGen: 4, wsOpenNs: 15, wsOpenWall: wall, uiNs: 16, uiWall: wall))
        // 尝试不属于这一段
        XCTAssertFalse(ep.noteOpen(task: new, lastTask: new, attempt: 5, currentGen: 3, wsOpenNs: 15, wsOpenWall: wall, uiNs: 16, uiWall: wall))
        XCTAssertNil(ep.uiNs)
        XCTAssertNil(ep.wsOpenNs)
        let o = ep.fields(finishNs: 20, deviceId: "d", launch: nil)
        XCTAssertEqual(o["ws_invalid"] as? Int, 4)
        XCTAssertNil(o["ws_open_ms"])
        XCTAssertTrue(ep.noteOpen(task: new, lastTask: new, attempt: 2, currentGen: 3, wsOpenNs: 15, wsOpenWall: wall, uiNs: 16, uiWall: wall))
        XCTAssertFalse(ep.noteOpen(task: new, lastTask: new, attempt: 2, currentGen: 3, wsOpenNs: 17, wsOpenWall: wall, uiNs: 18, uiWall: wall))   // 同一段只认第一次打开
        withExtendedLifetime((oldTask, newTask)) {}
    }

    // MARK: 样本身份 / 启动来源（sol R1-2、R1-5）

    func testBinaryUUIDReadsLoadedImage() throws {
        let uuid = try XCTUnwrap(ConnectRuler.binaryUUID)
        XCTAssertNotNil(UUID(uuidString: uuid))
        XCTAssertNotEqual(uuid, UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)).uuidString)
    }

    func testImageUUIDParsesSyntheticHeader() {
        var buf = [UInt8](repeating: 0, count: 256)
        let want = UUID()
        buf.withUnsafeMutableBytes { raw in
            var mh = mach_header_64()
            mh.magic = MH_MAGIC_64
            mh.ncmds = 2
            raw.storeBytes(of: mh, as: mach_header_64.self)
            var off = MemoryLayout<mach_header_64>.size
            raw.storeBytes(of: load_command(cmd: UInt32(LC_SEGMENT_64), cmdsize: 24), toByteOffset: off, as: load_command.self)
            off += 24
            raw.storeBytes(of: uuid_command(cmd: UInt32(LC_UUID), cmdsize: UInt32(MemoryLayout<uuid_command>.size), uuid: want.uuid),
                           toByteOffset: off, as: uuid_command.self)
        }
        let got = buf.withUnsafeBytes { ConnectRuler.imageUUID($0.baseAddress!) }
        XCTAssertEqual(got, want.uuidString)
        XCTAssertNil([UInt8](repeating: 0, count: 64).withUnsafeBytes { ConnectRuler.imageUUID($0.baseAddress!) })
    }

    func testDeviceIdIsRandomAndStable() throws {
        let suite = "ConnectRulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = ConnectRuler.deviceId(defaults)
        XCTAssertNotNil(UUID(uuidString: a))
        XCTAssertEqual(ConnectRuler.deviceId(defaults), a)
    }

    func testLaunchSourcePrecedence() {
        XCTAssertEqual(ConnectRuler.launchSource(notes: ["launch.fg"], prewarm: true), "prewarm")
        XCTAssertEqual(ConnectRuler.launchSource(notes: ["launch.push", "voipPush"], prewarm: false), "push")
        XCTAssertEqual(ConnectRuler.launchSource(notes: ["launch.fg", "voipPush"], prewarm: false), "icon")
        XCTAssertEqual(ConnectRuler.launchSource(notes: ["launch.bg", "voipPush"], prewarm: false), "voip")
        XCTAssertEqual(ConnectRuler.launchSource(notes: ["launch.bg"], prewarm: false), "unknown")
        XCTAssertEqual(ConnectRuler.launchSource(notes: [], prewarm: false), "unknown")
    }

    func testCountersBumpReturnsNewValue() {
        let before = ConnectRunCounters.snapshot().replaced
        XCTAssertEqual(ConnectRunCounters.bump(\.replaced), before + 1)
        XCTAssertEqual(ConnectRunCounters.snapshot().replaced, before + 1)
    }

    // MARK: 候选有界 / 忙段 deadline（sol R1-6、R1-8）

    func testCandidatesKeepLatestWithDroppedCount() {
        var ep = ConnectRulerEpisode(entryNs: 0)
        for i in 0..<(ConnectRulerEpisode.maxCandidates + 5) {
            ep.noteCandidate(ConnectCandidateRecord(host: "h", resumeNs: nil, callbackNs: 0, enterNs: 0, endNs: 0,
                                                    won: false, late: false, gen: i, slot: 0))
        }
        XCTAssertEqual(ep.candidates.count, ConnectRulerEpisode.maxCandidates)
        XCTAssertEqual(ep.candidates.first?.gen, 5)
        XCTAssertEqual(ep.candidates.last?.gen, ConnectRulerEpisode.maxCandidates + 4)
        XCTAssertEqual(ep.fields(finishNs: 0, deviceId: "d", launch: nil)["cand_dropped"] as? Int, 5)
    }

    func testBusyClipsAtDeadline() {
        // 窗口 100ms：一段从 80 忙到 175 只算到 100；deadline 之后开的段不算
        var acc = BusyAccumulator(startNs: 0, capNs: 100 * ms)
        acc.close(at: 20 * ms)
        acc.open(at: 80 * ms)
        acc.close(at: 175 * ms)
        acc.open(at: 180 * ms)
        let s = acc.summary(at: 300 * ms)
        XCTAssertEqual(s.ms, 40, accuracy: 0.001)
        XCTAssertTrue(s.capped)
        XCTAssertEqual(s.windowMs, 100, accuracy: 0.001)
        XCTAssertEqual(s.blocks50, 0)

        // 还在 deadline 内结束：不 capped，窗口按实际长度
        var short = BusyAccumulator(startNs: 0, capNs: 100 * ms)
        short.open(at: 10 * ms)
        let t = short.summary(at: 70 * ms)
        XCTAssertFalse(t.capped)
        XCTAssertEqual(t.ms, 60, accuracy: 0.001)
        XCTAssertEqual(t.windowMs, 70, accuracy: 0.001)

        // 一段没收、直接在 deadline 之后 finish：同样裁到 deadline 并标 capped
        let u = BusyAccumulator(startNs: 0, capNs: 100 * ms).summary(at: 250 * ms)
        XCTAssertEqual(u.ms, 100, accuracy: 0.001)
        XCTAssertTrue(u.capped)
    }
}
