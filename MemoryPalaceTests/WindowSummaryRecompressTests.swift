import MemoryCore
import XCTest
@testable import 记忆花园

/// v5 §六 D1 / D2：A2 收下尾段（每次收尾整段重写，被正式压缩后换成正式段）；A3 每次收尾读 A2 全部段 + 尾段真·再压约 300 字
final class WindowSummaryRecompressTests: XCTestCase {

    let pid = "xctest-window-recompress"
    private let speakers = SessionSegmentWriter.Speakers(userName: "粟粟", assistantName: "小克")
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in ["mem_master", "mem_content_summary", "mem_content_timeline", "mem_write_a3", MemoryStartDay.key, "mem_a3_chars"] {
            saved[k] = UserDefaults.standard.object(forKey: k)
        }
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(true, forKey: "mem_content_summary")
        UserDefaults.standard.set(true, forKey: "mem_write_a3")
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        UserDefaults.standard.removeObject(forKey: MemoryStartDay.key)
        UserDefaults.standard.removeObject(forKey: "mem_a3_chars")
    }

    override func tearDown() {
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func date(_ h: Int, _ m: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: h, minute: m))!
    }

    private func msgs(_ n: Int) -> [SessionSegmentWriter.Message] {
        (0..<n).map { .init(id: "n\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "第\($0)条", date: date(9, $0)) }
    }

    private let formal = SessionSegment(kind: .rolling, title: "前面", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60),
                                        from: 0, to: 4, lastNodeId: "n3", story: "前面的经过", quotes: "粟粟：「嗯」", pending: "")
    private let good = "标题：一段\n【经过】接着聊\n【原话】粟粟：「嗯」"
    private let goodWindow = "标题：一段\n【走向】转向北门\n【原话】粟粟：「嗯」\n【关键词】北门"

    func testTailRoundTripsWithFlag() {
        var tail = formal
        tail.kind = .closeout
        tail.isTail = true
        let s = SessionSummary(conversationId: "c", title: "t", compressedCount: 4, segments: [formal, tail], updatedAt: Date())
        let back = SessionSummaryStore.parse(SessionSummaryStore.render(s))
        XCTAssertEqual(back?.segments.map(\.isTail), [false, true])
        XCTAssertEqual(SessionSummaryStore.injectableSegments(back?.segments ?? [], windowIds: [], windowStart: 100).count, 1,
                       "尾段不注入（注入仍只带压缩段和第 0 段）")
    }

    func testWriteTailReplacesOldTailAfterFormal() async throws {
        let s = SessionSummary(conversationId: "c", title: "t", compressedCount: 4, segments: [formal], updatedAt: .distantPast)
        let one = try await SessionCloseout.writeTail(context: s, messages: msgs(6), notBefore: 0, persona: "", speakers: speakers, save: { _ in }) { _, _ in self.good }
        XCTAssertEqual(one?.segments.count, 2)
        XCTAssertEqual(one?.segments.last?.from, 4, "从正式段水位线之后")
        XCTAssertEqual(one?.segments.last?.isTail, true)
        let two = try await SessionCloseout.writeTail(context: try XCTUnwrap(one), messages: msgs(8), notBefore: 0, persona: "",
                                                      speakers: speakers, save: { _ in }) { _, _ in "标题：又聊\n【经过】更多\n【原话】粟粟：「好」" }
        XCTAssertEqual(two?.segments.map(\.title), ["前面", "又聊"], "整段重写，不叠两个尾段")
        XCTAssertEqual(two?.segments.last?.lastNodeId, "n7")
        let same = try await SessionCloseout.writeTail(context: try XCTUnwrap(two), messages: msgs(8), notBefore: 0, persona: "",
                                                       speakers: speakers, save: { _ in }) { _, _ in XCTFail("没新消息不该调模型"); return nil }
        XCTAssertNil(same)
    }

    func testFormalCompressionDropsTail() async throws {
        var tail = formal
        tail.kind = .closeout
        tail.isTail = true
        tail.from = 4
        var s = SessionSummary(conversationId: "c", title: "t", compressedCount: 4, segments: [formal, tail], updatedAt: .distantPast)
        let done = try await SessionCloseout.writeContextParts([4..<8], messages: msgs(10), into: &s, title: "t", persona: "", speakers: speakers,
                                                               caller: { _, _ in self.good }, save: { _ in })
        XCTAssertTrue(done)
        XCTAssertFalse(s.segments.contains(where: \.isTail), "被正式压缩后换成正式段")
        XCTAssertEqual(s.segments.count, 2)
    }

    func testRecompressReadsAllSegmentsPlusTail() async throws {
        var tail = formal
        tail.kind = .closeout
        tail.isTail = true
        tail.title = "尾巴"
        tail.story = "尾段的经过"
        tail.from = 4
        tail.lastNodeId = "n5"
        var legacyCloseout = formal
        legacyCloseout.kind = .closeout
        legacyCloseout.title = "老收尾段"
        let s = SessionSummary(conversationId: "c", title: "t", compressedCount: 4, segments: [formal, legacyCloseout, tail], updatedAt: .distantPast)
        var asked = ""
        let w = try await SessionCloseout.recompressWindow(context: s, messages: msgs(6), title: "看病", notBefore: 0, persona: "",
                                                           speakers: speakers, caller: { _, user in asked = user; return self.goodWindow })
        XCTAssertTrue(asked.contains("前面的经过") && asked.contains("尾段的经过"), "A2 全部段 + 尾段")
        XCTAssertFalse(asked.contains("老收尾段"), "老收尾段不算")
        XCTAssertFalse(asked.contains("第5条"), "尾段已经盖到最后：不再给原文")
        XCTAssertEqual(w?.segments.count, 1, "压成一段，不再是 A2 的抄本")
        XCTAssertEqual(w?.closedThrough, "n5")
    }

    func testRecompressWithoutA2UsesRawMessages() async throws {
        let s = SessionSummary(conversationId: "c", title: "t", compressedCount: 0, segments: [], updatedAt: .distantPast)
        var asked = ""
        _ = try await SessionCloseout.recompressWindow(context: s, messages: msgs(4), title: "t", notBefore: 0, persona: "",
                                                       speakers: speakers, caller: { _, user in asked = user; return self.goodWindow })
        XCTAssertTrue(asked.contains("这个窗口的对话") && asked.contains("第3条"))
    }

    func testCloseoutWritesTailIntoA2AndRecompressesA3() async throws {
        var calls: [String] = []
        let item = SessionCloseout.Candidate(conversationId: "conv-rc-0001", title: "看病", messages: msgs(6))
        let profile = Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "粟粟", assistantName: "小克")
        let ctx = SessionCloseout.Context(profile: profile, model: ProviderModel(credentialId: "x", modelId: "m", name: "m"))
        let stop = await SessionCloseout().closeout(item, ctx: ctx) { system, _ in
            calls.append(system.contains("「窗口总结」") ? "A3" : "A2尾段")
            return system.contains("「窗口总结」") ? self.goodWindow : self.good
        }
        XCTAssertFalse(stop)
        XCTAssertEqual(calls, ["A2尾段", "A3"], "先收尾段进 A2，再重压 A3")
        XCTAssertEqual(SessionSummaryStore.load(conversationId: "conv-rc-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.map(\.isTail), [true])
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-rc-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.count, 1)
        MemoryWriteLog.flush()
        let log = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        XCTAssertEqual(Set(log.map(\.writer)), ["A2", "A3"], "成败都记日志")
    }

    /// 三代搬迁 M3：尾段用 A2 的 caller、重压用 A3 的 caller，各调一次
    func testComposeUsesSeparateCallers() async throws {
        let s = SessionSummary(conversationId: "c", title: "t", compressedCount: 4, segments: [formal], updatedAt: .distantPast)
        var tail: [String] = [], window: [String] = []
        let r = try await SessionCloseout.composeWindowSummary(
            context: s, messages: msgs(8), title: "t", notBefore: 0, persona: "", speakers: speakers,
            tailCaller: { system, _ in tail.append(system); return self.good },
            windowCaller: { system, _ in window.append(system); return self.goodWindow })
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(window.count, 1)
        XCTAssertTrue(tail.allSatisfy { $0.contains("尾段") })
        XCTAssertTrue(window.allSatisfy { $0.contains("「窗口总结」") })
        XCTAssertEqual(r?.context.segments.last?.isTail, true)
        XCTAssertEqual(r?.window.segments.count, 1)
    }
}
