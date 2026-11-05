import XCTest
@testable import 记忆花园

/// #067 第 4 步：首屏画像卡底的提醒——正常时没有，连续失败 3 次才出一行，提取优先
final class MemoryHealthWarningTests: XCTestCase {

    let pid = "xctest-health-warning"
    private let switches = ["mem_master", "mem_content_facts", "mem_content_profile", "mem_content_summary", "mem_content_timeline"]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in switches {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.set(true, forKey: k)
        }
    }

    override func tearDown() {
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        // v5 F1：成败会记日志（memory/log/），测完连楼层目录一起清
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        let d = UserDefaults.standard
        for kind in ["extract", "dream", "summary", "context", "timeline"] {
            for field in ["ok", "err", "errmsg", "streak", "model"] {
                d.removeObject(forKey: "mem_health_\(kind)_\(field)_\(pid)")
            }
        }
        super.tearDown()
    }

    private func fail(_ kind: MemoryHealthStore.Kind, times: Int) {
        for _ in 0..<times {
            MemoryHealthStore.recordError(kind, profileId: pid, message: "boom", modelName: "m")
        }
    }

    func testNoWarningWhenHealthy() {
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
        MemoryHealthStore.recordOK(.extract, profileId: pid, modelName: "m")
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
    }

    func testTwoFailuresStayQuiet() {
        fail(.dream, times: 2)
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
    }

    /// v5 Q4：画像下线，「写不成画像」不再提醒
    func testDreamNoLongerWarns() {
        fail(.dream, times: 3)
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
    }

    func testExtractWinsOverOthers() {
        fail(.timeline, times: 3)
        fail(.extract, times: 3)
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近记不住新东西了")
    }

    /// v5 · 0.1：总开关关着 / 这一项关着 → 不红，计数不清（再开回来照样红）
    func testOffDoesNotWarnAndKeepsStreak() {
        fail(.timeline, times: 3)
        UserDefaults.standard.set(false, forKey: "mem_master")
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
        XCTAssertFalse(MemoryHealthStore.isOn(.timeline))
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
        XCTAssertEqual(MemoryHealthStore.status(.timeline, profileId: pid).failStreak, 3, "计数不清")
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近写不成时间轴")
    }

    func testFailureDetailListsReasonStreakModel() {
        fail(.context, times: 3)
        let s = MemoryHealthStore.status(.context, profileId: pid)
        let text = MemoryHealthStatusView.failureDetail(s)
        XCTAssertTrue(text.hasPrefix("原因：boom · 连续 3 次 · 用的 m"), text)
    }

    func testRecoveryClearsWarning() {
        fail(.summary, times: 3)
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近写不成窗口总结")
        MemoryHealthStore.recordOK(.summary, profileId: pid, modelName: "m")
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
    }

    // MARK: - C2（astra v5 裁决）

    private let c2Messages = [FragmentPool.Message(id: "n0", role: "user", content: "周三复诊", date: Date())]

    private func runC2(_ caller: @escaping SessionSegmentWriter.Caller, wrote: (() -> Void)? = nil) async -> FragmentPool.Outcome {
        await FragmentPool.process(c2Messages, names: MemoryExtractor.Names(userName: "粟粟", assistantName: "小克"), caller: caller,
                                   local: false, profileId: pid, modelName: "m", fallbackNote: nil) { _ in
            wrote?()
            return 0
        }
    }

    /// 车头 #13：C2 连续 3 包整包拒收按失败计，状态卡那行变红；日志照记拒收；成功一包清零；关着不计不红
    func testWholeBatchRejectionsTurnRedAfterThree() async {
        for _ in 0..<2 {
            let o = await runC2 { _, _ in "不是 JSON" }
            XCTAssertEqual(o, .rejected)
        }
        XCTAssertFalse(MemoryHealthStore.status(.extract, profileId: pid).needsAttention, "两包还不红")
        _ = await runC2 { _, _ in "不是 JSON" }
        let s = MemoryHealthStore.status(.extract, profileId: pid)
        XCTAssertEqual(s.failStreak, 3)
        XCTAssertTrue(s.needsAttention, "第三包：状态卡那行变红")
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近记不住新东西了")
        MemoryWriteLog.flush()
        let log = MemoryWriteLog.entries(profileId: pid).filter { $0.writer == "C2" }
        XCTAssertEqual(log.count, 3)
        XCTAssertTrue(log.allSatisfy { !$0.ok && $0.rejected == 1 }, "日志里拒收照记")
        XCTAssertTrue(log.allSatisfy { $0.note.contains("JSON") && $0.note.contains("1") })
        XCTAssertEqual(MemoryWriteLog.rejectedThisWeek(log), 3)

        let ok = await runC2 { _, _ in "{\"fragments\":[]}" }
        XCTAssertEqual(ok, .done(added: 0))
        XCTAssertEqual(MemoryHealthStore.status(.extract, profileId: pid).failStreak, 0, "成功一包清零")

        XCTAssertFalse(FragmentPool.recordFailure(URLError(.notConnectedToInternet), profileId: pid, modelName: "m"), "断网不算")
        XCTAssertFalse(FragmentPool.recordFailure(FragmentPoolError.interrupted, profileId: pid, modelName: "m"), "被打断不算")
        UserDefaults.standard.set(false, forKey: "mem_content_facts")
        XCTAssertFalse(FragmentPool.recordFailure(MemoryWriterError.format("x"), profileId: pid, modelName: "m"), "C2 关着不计")
        let off = await runC2 { _, _ in XCTFail("关着不调模型"); return nil }
        XCTAssertEqual(off, .skipped)
        XCTAssertEqual(MemoryHealthStore.status(.extract, profileId: pid).failStreak, 0)
    }

    func testAllCardRejectionsTurnRedWithoutWritingOrAdvancingLastOK() async {
        let lastOK = Date(timeIntervalSince1970: 1_800_000_000)
        UserDefaults.standard.set(lastOK.timeIntervalSince1970, forKey: "mem_health_extract_ok_\(pid)")
        let badContent = c2Card.replacingOccurrences(of: "\"content\":\"粟粟周三复诊\"", with: "\"content\":\"\"")
        let badImportance = c2Card.replacingOccurrences(of: "\"importance\":3", with: "\"importance\":0")
        var calls = 0
        var writes = 0
        for packet in 1...3 {
            var round = 0
            let outcome = await runC2({ _, _ in
                calls += 1
                round += 1
                let cards = Array(repeating: round == 1 ? badContent : badImportance, count: round == 1 ? packet + 1 : packet)
                return "{\"fragments\":[\(cards.joined(separator: ","))]}"
            }, wrote: { writes += 1 })
            XCTAssertEqual(outcome, .rejected)
            let status = MemoryHealthStore.status(.extract, profileId: pid)
            XCTAssertEqual(status.failStreak, packet)
            XCTAssertEqual(status.needsAttention, packet == 3)
            XCTAssertEqual(status.lastOK, lastOK, "拒收不能伪报成功")
        }
        XCTAssertEqual(calls, 6)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近记不住新东西了")
        let status = MemoryHealthStore.status(.extract, profileId: pid)
        XCTAssertTrue(status.lastErrorMessage?.contains("content") == true)
        XCTAssertTrue(status.lastErrorMessage?.contains("4") == true)
        XCTAssertTrue(status.lastErrorMessage?.contains("importance") == true)
        MemoryWriteLog.flush()
        let log = MemoryWriteLog.entries(profileId: pid).filter { $0.writer == "C2" }
        XCTAssertEqual(log.count, 3)
        for packet in 1...3 {
            let entry = log.first { $0.rejected == packet }
            XCTAssertNotNil(entry)
            XCTAssertEqual(entry?.ok, false)
            XCTAssertEqual(entry?.rejected, packet, "结构化拒收数沿用最终结果的真实数量")
            XCTAssertTrue(entry?.note.contains("content") == true)
            XCTAssertTrue(entry?.note.contains(String(packet + 1)) == true, "日志保留与最终数量不同的首轮拒收数量")
            XCTAssertTrue(entry?.note.contains("importance") == true)
        }
        XCTAssertEqual(MemoryWriteLog.rejectedThisWeek(log), 6)
        print("[P2 fix1 health smoke] calls=\(calls), writes=\(writes), streak=\(status.failStreak), lastOKUnchanged=\(status.lastOK == lastOK), logs=\(log.count), rejected=\(MemoryWriteLog.rejectedThisWeek(log))")

        let empty = await runC2({ _, _ in
            calls += 1
            return "{\"fragments\":[]}"
        }, wrote: { writes += 1 })
        XCTAssertEqual(empty, .done(added: 0))
        XCTAssertEqual(calls, 7)
        XCTAssertEqual(writes, 1, "合法空包仍走成功出口")
        XCTAssertEqual(MemoryHealthStore.status(.extract, profileId: pid).failStreak, 0)
        XCTAssertNotEqual(MemoryHealthStore.status(.extract, profileId: pid).lastOK, lastOK)
        XCTAssertNil(MemoryHealthWarning.text(profileId: pid))
        MemoryWriteLog.flush()
        XCTAssertEqual(MemoryWriteLog.entries(profileId: pid).filter { $0.writer == "C2" }.count, 4)
    }

    func testMixedRepairWritesGoodCardsOnceAndKeepsFirstRejection() async {
        let badContent = c2Card.replacingOccurrences(of: "\"content\":\"粟粟周三复诊\"", with: "\"content\":\"\"")
        let badImportance = c2Card.replacingOccurrences(of: "\"importance\":3", with: "\"importance\":0")
        UserDefaults.standard.set(2, forKey: "mem_health_extract_streak_\(pid)")
        var calls = 0
        var writes = 0
        let outcome = await FragmentPool.process(c2Messages, names: MemoryExtractor.Names(userName: "粟粟", assistantName: "小克"), caller: { _, _ in
            calls += 1
            return calls == 1
                ? "{\"fragments\":[\(self.c2Card),\(badContent),\(badContent)]}"
                : "{\"fragments\":[\(self.c2Card),\(badImportance)]}"
        }, local: false, profileId: pid, modelName: "m", fallbackNote: "测试回退") { fragments in
            writes += 1
            XCTAssertEqual(fragments.count, 1)
            XCTAssertEqual(fragments.first?.content, "粟粟周三复诊")
            return fragments.count
        }
        XCTAssertEqual(outcome, .done(added: 1))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(MemoryHealthStore.status(.extract, profileId: pid).failStreak, 0)
        XCTAssertNotNil(MemoryHealthStore.status(.extract, profileId: pid).lastOK)
        MemoryWriteLog.flush()
        let log = MemoryWriteLog.entries(profileId: pid).filter { $0.writer == "C2" }
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.ok, true)
        XCTAssertEqual(log.first?.rejected, 1)
        XCTAssertTrue(log.first?.note.contains("content") == true)
        XCTAssertTrue(log.first?.note.contains("2") == true, "首轮两张不合格不能被最终的一张覆盖")
        XCTAssertTrue(log.first?.note.contains("测试回退") == true)
    }

    func testFullRepairKeepsFirstRejectionInSingleSuccessLog() async {
        let badContent = c2Card.replacingOccurrences(of: "\"content\":\"粟粟周三复诊\"", with: "\"content\":\"\"")
        var calls = 0
        var writes = 0
        let outcome = await runC2({ _, _ in
            calls += 1
            return calls == 1 ? "{\"fragments\":[\(badContent),\(badContent)]}" : "{\"fragments\":[\(self.c2Card)]}"
        }, wrote: { writes += 1 })
        XCTAssertEqual(outcome, .done(added: 0))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(MemoryHealthStore.status(.extract, profileId: pid).failStreak, 0)
        XCTAssertNotNil(MemoryHealthStore.status(.extract, profileId: pid).lastOK)
        MemoryWriteLog.flush()
        let log = MemoryWriteLog.entries(profileId: pid).filter { $0.writer == "C2" }
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.ok, true)
        XCTAssertNil(log.first?.rejected)
        XCTAssertTrue(log.first?.note.contains("content") == true)
        XCTAssertTrue(log.first?.note.contains("2") == true, "完全修复后仍保留首轮数量")
    }

    func testSecondRoundInvalidJSONKeepsFirstCardRejection() async {
        let badContent = c2Card.replacingOccurrences(of: "\"content\":\"粟粟周三复诊\"", with: "\"content\":\"\"")
        var calls = 0
        var writes = 0
        let outcome = await runC2({ _, _ in
            calls += 1
            return calls == 1 ? "{\"fragments\":[\(badContent),\(badContent)]}" : "不是 JSON"
        }, wrote: { writes += 1 })
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(writes, 0)
        let status = MemoryHealthStore.status(.extract, profileId: pid)
        XCTAssertEqual(status.failStreak, 1)
        XCTAssertNil(status.lastOK)
        XCTAssertTrue(status.lastErrorMessage?.contains("content") == true)
        MemoryWriteLog.flush()
        let log = MemoryWriteLog.entries(profileId: pid).filter { $0.writer == "C2" }
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.ok, false)
        XCTAssertEqual(log.first?.rejected, 1, "第二轮 JSON 整包非法按 1 计")
        XCTAssertTrue(log.first?.note.contains("content") == true)
        XCTAssertTrue(log.first?.note.contains("2") == true)
        XCTAssertTrue(log.first?.note.contains("JSON") == true)
    }

    func testSkippedRetryKeepsFirstRejectionWithoutChangingHealth() async {
        let badContent = c2Card.replacingOccurrences(of: "\"content\":\"粟粟周三复诊\"", with: "\"content\":\"\"")
        let lastOK = Date(timeIntervalSince1970: 1_800_000_000)
        UserDefaults.standard.set(lastOK.timeIntervalSince1970, forKey: "mem_health_extract_ok_\(pid)")
        UserDefaults.standard.set(2, forKey: "mem_health_extract_streak_\(pid)")
        var calls = 0
        var writes = 0
        for skip in 0..<4 {
            UserDefaults.standard.set(true, forKey: "mem_master")
            var round = 0
            let outcome = await runC2({ _, _ in
                calls += 1
                round += 1
                if round == 1 { return "{\"fragments\":[\(badContent),\(badContent)]}" }
                switch skip {
                case 0: return nil
                case 1:
                    UserDefaults.standard.set(false, forKey: "mem_master")
                    return "{\"fragments\":[]}"
                case 2: throw URLError(.notConnectedToInternet)
                default: throw FragmentPoolError.interrupted
                }
            }, wrote: { writes += 1 })
            XCTAssertEqual(outcome, .skipped)
            let status = MemoryHealthStore.status(.extract, profileId: pid)
            XCTAssertEqual(status.failStreak, 2)
            XCTAssertEqual(status.lastOK, lastOK)
            XCTAssertNil(status.lastError)
        }
        XCTAssertEqual(calls, 8)
        XCTAssertEqual(writes, 0)
        MemoryWriteLog.flush()
        let log = MemoryWriteLog.entries(profileId: pid).filter { $0.writer == "C2" }
        XCTAssertEqual(log.count, 4, "每个最终跳过仅一条诊断日志")
        XCTAssertTrue(log.allSatisfy { !$0.ok && $0.rejected == 2 })
        XCTAssertTrue(log.allSatisfy { $0.note.contains("content") && $0.note.contains("2") })
    }

    /// astra #1（C2）：等模型时关了总开关 → 这包不落库、不算失败
    func testC2SwitchOffDuringCallDiscards() async {
        var wrote = false
        let o = await runC2({ _, _ in
            UserDefaults.standard.set(false, forKey: "mem_master")
            return "{\"fragments\":[]}"
        }, wrote: { wrote = true })
        XCTAssertEqual(o, .skipped)
        XCTAssertFalse(wrote, "不落库")
        XCTAssertEqual(MemoryHealthStore.status(.extract, profileId: pid).failStreak, 0)
        XCTAssertNil(MemoryHealthStore.status(.extract, profileId: pid).lastOK)
    }

    private struct SaveFailed: Error {}

    /// 10-16 astra #2：请求超时 / 落库失败记失败但放回水位（下次重来）；两次都不合格整包拒收才提交
    func testC2NetworkAndSaveFailuresReleaseFormatRejectionCommits() async {
        let names = MemoryExtractor.Names(userName: "粟粟", assistantName: "小克")
        let suite = "xctest-c2-settle-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let watch = FragmentWatch(defaults: d)
        let ids = (0..<8).map { "n\($0)" }
        let dates: [Date?] = ids.indices.map { Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 60) }
        _ = await watch.due(conversationId: "c", pathIds: Array(ids.prefix(2)), dates: Array(dates.prefix(2)), threshold: 6)

        let timedOut = await runC2 { _, _ in throw URLError(.timedOut) }
        XCTAssertEqual(timedOut, .failed, "超时：记失败")
        let a = await watch.due(conversationId: "c", pathIds: ids, dates: dates, threshold: 6)
        await watch.finish(conversationId: "c", claim: a!, outcome: timedOut)

        let saveFailed = await FragmentPool.process(c2Messages, names: names, caller: { _, _ in "{\"fragments\":[\(self.c2Card)]}" },
                                                    local: false, profileId: pid, modelName: "m", fallbackNote: nil) { _ in
            throw SaveFailed()
        }
        XCTAssertEqual(saveFailed, .failed, "落库失败：记失败")
        let b = await watch.due(conversationId: "c", pathIds: ids, dates: dates, threshold: 6)
        XCTAssertEqual(b?.range, 2..<8, "超时放回了：同一截照样认领")
        await watch.finish(conversationId: "c", claim: b!, outcome: saveFailed)

        let rejected = await runC2 { _, _ in "不是 JSON" }
        XCTAssertEqual(rejected, .rejected)
        let c = await watch.due(conversationId: "c", pathIds: ids, dates: dates, threshold: 6)
        XCTAssertEqual(c?.range, 2..<8, "落库失败放回了：同一截照样认领")
        await watch.finish(conversationId: "c", claim: c!, outcome: rejected)
        let none = await watch.due(conversationId: "c", pathIds: ids, dates: dates, threshold: 6)
        XCTAssertNil(none, "整包拒收：提交，不再重试")
    }

    private let c2Card = "{\"msg\":1,\"content\":\"粟粟周三复诊\",\"tags\":[],\"importance\":3,\"emotion\":0,\"resolved\":null,\"category\":\"fact\",\"subject\":\"粟粟\",\"speaker\":\"用户自述\"}"
}
