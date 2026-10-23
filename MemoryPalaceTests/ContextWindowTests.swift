import XCTest
@testable import 记忆花园

/// 窗口锚定纯函数（刀4）+ 滞后压缩判定（messagesToSummarize）特征测试。
final class ContextWindowTests: XCTestCase {

    // MARK: - anchoredWindowStart（锚定窗口）

    func testNotOverWindowReturnsNil() {
        XCTAssertNil(ConversationViewModel.anchoredWindowStart(fullCount: 40, covered: 10, depth: 40))
        XCTAssertNil(ConversationViewModel.anchoredWindowStart(fullCount: 5, covered: 2, depth: 40))
    }

    func testNoSummaryReturnsNil() {
        XCTAssertNil(ConversationViewModel.anchoredWindowStart(fullCount: 50, covered: nil, depth: 40))
        XCTAssertNil(ConversationViewModel.anchoredWindowStart(fullCount: 50, covered: 0, depth: 40))
    }

    func testFreshCompressionAnchorsExactly() {
        // 刚压缩完：covered = full - depth → 窗口恰好 depth
        XCTAssertEqual(ConversationViewModel.anchoredWindowStart(fullCount: 50, covered: 10, depth: 40), 10)
    }

    func testWindowGrowsAppendOnlyBetweenCompressions() {
        // 压缩后又聊了 6 条：窗口 46，起点不变 → 前缀稳定（append-only）
        XCTAssertEqual(ConversationViewModel.anchoredWindowStart(fullCount: 56, covered: 10, depth: 40), 10)
        // 正好到 cap（depth×2）仍锚定
        XCTAssertEqual(ConversationViewModel.anchoredWindowStart(fullCount: 90, covered: 10, depth: 40), 10)
    }

    func testCapExceededFallsBack() {
        // 摘要长期没跑成，窗口 > depth×2 → nil（退滑动窗，宁可 miss 不可爆上下文）
        XCTAssertNil(ConversationViewModel.anchoredWindowStart(fullCount: 91, covered: 10, depth: 40))
    }

    func testBranchSwitchMismatchFallsBack() {
        // 切分支后路径变短：covered 失配，窗口 < depth → nil
        XCTAssertNil(ConversationViewModel.anchoredWindowStart(fullCount: 50, covered: 45, depth: 40))
        // covered 甚至超过 full → 也是 nil 不是崩
        XCTAssertNil(ConversationViewModel.anchoredWindowStart(fullCount: 50, covered: 99, depth: 40))
    }

    // MARK: - messagesToSummarize（滞后压缩判定）

    let pid = "xctest-ctx-window"
    let convId = "11223344-aaaa-bbbb-cccc-ddddeeeeffff"
    let intervalKey = "ctx_compress_interval"
    var savedInterval: Int = 0

    override func setUp() {
        super.setUp()
        savedInterval = UserDefaults.standard.integer(forKey: intervalKey)
        UserDefaults.standard.set(5, forKey: intervalKey)
    }

    override func tearDown() {
        if savedInterval > 0 { UserDefaults.standard.set(savedInterval, forKey: intervalKey) }
        else { UserDefaults.standard.removeObject(forKey: intervalKey) }
        let floorDir = FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: floorDir)
        super.tearDown()
    }

    private func msgs(_ n: Int) -> [(role: String, content: String)] {
        (0..<n).map { (role: $0 % 2 == 0 ? "user" : "assistant", content: "消息\($0)") }
    }

    private func plantSummary(covered: Int) {
        SummaryFileStore.save(ContextSummary(summary: "已有摘要", coveredCount: covered, updatedAt: Date()),
                              conversationId: convId, profileId: pid, conversationTitle: "t")
    }

    func testUnderDepthNeedsNothing() {
        XCTAssertNil(ContextSummarizer.messagesToSummarize(allMessages: msgs(40), contextDepth: 40, conversationId: convId, profileId: pid))
    }

    func testFirstCompressionTakesAllOldMessages() throws {
        let r = try XCTUnwrap(ContextSummarizer.messagesToSummarize(allMessages: msgs(52), contextDepth: 40, conversationId: convId, profileId: pid))
        XCTAssertEqual(r.oldMessages.count, 12)
        XCTAssertNil(r.existingSummary)
    }

    func testUpToDateSkips() {
        plantSummary(covered: 12)
        XCTAssertNil(ContextSummarizer.messagesToSummarize(allMessages: msgs(52), contextDepth: 40, conversationId: convId, profileId: pid))
    }

    func testLaggingSkipsUntilIntervalReached() {
        plantSummary(covered: 12)
        // 窗外新增 9 条 < 5轮×2 → 滞后不压（摘要稳定留前缀）
        XCTAssertNil(ContextSummarizer.messagesToSummarize(allMessages: msgs(61), contextDepth: 40, conversationId: convId, profileId: pid))
    }

    func testIntervalReachedCompresses() throws {
        plantSummary(covered: 12)
        // 窗外新增 10 条 = 5轮×2 → 该压了
        let r = try XCTUnwrap(ContextSummarizer.messagesToSummarize(allMessages: msgs(62), contextDepth: 40, conversationId: convId, profileId: pid))
        XCTAssertEqual(r.oldMessages.count, 22)
        XCTAssertEqual(r.existingSummary?.coveredCount, 12)
    }

    func testForceIgnoresLag() throws {
        plantSummary(covered: 12)
        let r = try XCTUnwrap(ContextSummarizer.messagesToSummarize(allMessages: msgs(61), contextDepth: 40, conversationId: convId, profileId: pid, force: true))
        XCTAssertEqual(r.oldMessages.count, 21, "手动压缩无视滞后间隔")
    }
}
