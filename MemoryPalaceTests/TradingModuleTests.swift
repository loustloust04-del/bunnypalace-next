#if PERSONAL_APPS
import XCTest
import SwiftData
@testable import 记忆花园

/// 交易 T0：TickerLinkifier 四用例 + frontmatter 解析 + {{trading}} 组合器闸 + ticker: 合成锚分流。
@MainActor
final class TradingModuleTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let pid = "xctest-trading-t0"

    override func setUp() {
        super.setUp()
        // #033：本类直接测 store，测试自己站在主线程调——不算生产违规
        MainThreadIO.allowMainThreadInThisTest()
        container = try! ModelContainer(
            for: TickerEntry.self, TradeEntry.self, MessageNode.self, BookEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        UserDefaults.standard.removeObject(forKey: TradingStore.watchlistGateKey)
        UserDefaults.standard.removeObject(forKey: PermissionDomain.trading.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TradingStore.watchlistGateKey)
        UserDefaults.standard.removeObject(forKey: PermissionDomain.trading.storageKey)
        container = nil
        super.tearDown()
    }

    // MARK: - TickerLinkifier

    func testLinkifyBasic() {
        XCTAssertEqual(TickerLinkifier.linkify("看看 $NVDA 怎么样"),
                       "看看 [$NVDA](ticker://open/NVDA) 怎么样")
        // 行首/标点邻接
        XCTAssertEqual(TickerLinkifier.linkify("$AAPL，$MSFT。"),
                       "[$AAPL](ticker://open/AAPL)，[$MSFT](ticker://open/MSFT)。")
    }

    func testLinkifyNegatives() {
        // 金额/小写/超长/前缀字符 全不命中
        XCTAssertEqual(TickerLinkifier.linkify("花了 $100 和 $1.5B"), "花了 $100 和 $1.5B")
        XCTAssertEqual(TickerLinkifier.linkify("$nvda 小写不认"), "$nvda 小写不认")
        XCTAssertEqual(TickerLinkifier.linkify("$TOOLONG 六位不认"), "$TOOLONG 六位不认")
        XCTAssertEqual(TickerLinkifier.linkify("US$NVDA 前面有字母不认"), "US$NVDA 前面有字母不认")
        XCTAssertEqual(TickerLinkifier.linkify("$NVDAx 后面有小写不认"), "$NVDAx 后面有小写不认")
    }

    func testLinkifySkipsCode() {
        let fenced = "```bash\necho $HOME\n```\n正文 $NVDA"
        XCTAssertEqual(TickerLinkifier.linkify(fenced),
                       "```bash\necho $HOME\n```\n正文 [$NVDA](ticker://open/NVDA)")
        XCTAssertEqual(TickerLinkifier.linkify("行内 `$PATH` 不动，$AMD 要动"),
                       "行内 `$PATH` 不动，[$AMD](ticker://open/AMD) 要动")
    }

    /// 行内公式里的 `$E` 不是股票代码；嵌套围栏里的也不动
    func testLinkifySkipsInlineMathAndNestedFences() {
        XCTAssertEqual(TickerLinkifier.linkify("质能 $E = mc^2$，另看 $NVDA"),
                       "质能 $E = mc^2$，另看 [$NVDA](ticker://open/NVDA)")
        let nested = "````md\n```\n$NVDA\n```\n$AMD\n````"
        XCTAssertEqual(TickerLinkifier.linkify(nested), nested)
    }

    func testLinkifySkipsExistingLinks() {
        let md = "[看 $NVDA 分析](https://example.com/a) 以及 $TSLA"
        XCTAssertEqual(TickerLinkifier.linkify(md),
                       "[看 $NVDA 分析](https://example.com/a) 以及 [$TSLA](ticker://open/TSLA)")
    }

    // MARK: - frontmatter

    func testParseFrontmatter() {
        let md = "---\nticker: NVDA\ndate: 2026-07-29\nrating: Underweight\nconfidence: 65\ndata_coverage: \"a=✓\"\n---\n\n# 正文"
        let fm = TradingStore.parseFrontmatter(md)
        XCTAssertEqual(fm["rating"], "Underweight")
        XCTAssertEqual(fm["date"], "2026-07-29")
        XCTAssertEqual(fm["confidence"], "65")
        XCTAssertEqual(fm["data_coverage"], "a=✓")
        XCTAssertTrue(TradingStore.parseFrontmatter("# 没有 frontmatter").isEmpty)
    }

    func testStripFrontmatter() {
        let md = "---\nticker: NVDA\nrating: Underweight\n---\n\n# 正文标题\n\n段落"
        XCTAssertEqual(TradingStore.stripFrontmatter(md), "# 正文标题\n\n段落")
        XCTAssertEqual(TradingStore.stripFrontmatter("# 无 fm"), "# 无 fm")
    }

    // MARK: - {{trading}} 组合器

    func testComposedSummaryGate() throws {
        context.insert(TickerEntry(profileId: pid, symbol: "nvda"))  // init 强制大写
        try context.save()

        // 闸默认关 → 空串
        XCTAssertEqual(TradingStore.composedTradingSummary(context: context, profileId: pid), "")

        TradingStore.watchlistGateEnabled = true
        let s = TradingStore.composedTradingSummary(context: context, profileId: pid)
        XCTAssertTrue(s.contains("$NVDA"), "开闸后应含大写 symbol，实际：\(s)")
        XCTAssertTrue(s.hasPrefix("关注自选："))

        // 别的楼层看不见
        XCTAssertEqual(TradingStore.composedTradingSummary(context: context, profileId: "other-profile"), "")
    }

    func testMacroExpanderTrading() {
        let out = MacroExpander.expand("看盘：{{trading}}", userName: "u", charName: "c", trading: "关注自选：$NVDA。")
        XCTAssertEqual(out, "看盘：关注自选：$NVDA。")
        // 不传 → 替换成空（不暴露字面量）
        XCTAssertEqual(MacroExpander.expand("{{trading}}", userName: "u", charName: "c"), "")
    }

    // MARK: - 研报回投落地（T0.5）

    func testTradingReportLanding() throws {
        // 坏 payload 拒收（不 ack 等补投）
        XCTAssertFalse(TradingReportLanding.handle(["ok": true], profileId: pid))
        XCTAssertFalse(TradingReportLanding.handle(
            ["symbol": "NVDA", "ok": true, "filename": "../evil.md", "content": "x"], profileId: pid))
        XCTAssertFalse(TradingReportLanding.handle(
            ["symbol": "NVDA", "ok": true, "filename": "a.md", "content": ""], profileId: pid))

        // 失败帧：返回 true（可 ack），只发通知解锁按钮
        XCTAssertTrue(TradingReportLanding.handle(
            ["symbol": "NVDA", "ok": false, "error": "busy"], profileId: pid))

        // ok 帧：落文件库 trading/<SYM>/ + 自动加入关注列表（入口闭环，08-02 粟粟"看不见"实锤）
        let fn = "2026-08-01-initiate.md"
        XCTAssertTrue(TradingReportLanding.handle(
            ["symbol": "NVDA", "ok": true, "filename": fn, "content": "# 裁决"],
            profileId: pid, context: context))
        XCTAssertEqual(try FileLibraryStore.read("trading/NVDA/\(fn)", profileId: pid), "# 裁决")
        let entries = try context.fetch(FetchDescriptor<TickerEntry>(
            predicate: #Predicate<TickerEntry> { $0.profileId == pid }))
        XCTAssertEqual(entries.map(\.symbol), ["NVDA"], "报告到达应自动加入关注")
        // 再来一份同 symbol 不重复加
        XCTAssertTrue(TradingReportLanding.handle(
            ["symbol": "NVDA", "ok": true, "filename": "2026-08-02-update.md", "content": "# u"],
            profileId: pid, context: context))
        XCTAssertEqual((try context.fetch(FetchDescriptor<TickerEntry>(
            predicate: #Predicate<TickerEntry> { $0.profileId == pid }))).count, 1)
        try? FileLibraryStore.delete("trading/NVDA/\(fn)", profileId: pid)
        try? FileLibraryStore.delete("trading/NVDA/2026-08-02-update.md", profileId: pid)
    }

    // MARK: - 财报进书架（earnings filing 分流）

    func testFilingBookImportTxt() async throws {
        let txt = "AMD 8-K filed 2026-07-01\n\n业绩正文……"
        let payload: [String: Any] = [
            "symbol": "AMD", "ok": true, "filename": "2026-08-03-earnings.md", "content": "# 收账",
            "filing": ["filename": "AMD-8-K-2026-07-01.txt", "format": "txt",
                       "book_name": "AMD 8-K 测试书", "data": Data(txt.utf8).base64EncodedString()],
        ]
        XCTAssertTrue(TradingReportLanding.handle(payload, profileId: pid, context: context))
        // importFilingBook 是异步 Task——轮询书目录出现（importTxt 落 BookStore 文件系统）
        let safeName = BookStore.safeName("AMD 8-K 测试书")
        let bookDir = BookStore.bookDir(safeName: safeName, profileId: pid)
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: bookDir.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookDir.path), "财报 txt 应进书架目录")
        try? FileManager.default.removeItem(at: bookDir)
        try? FileLibraryStore.delete("trading/AMD/2026-08-03-earnings.md", profileId: pid)
    }

    // MARK: - T1 交易卡（意向协议第四例）

    private func makeAssistantNode(_ content: String) -> MessageNode {
        let node = MessageNode(
            id: UUID().uuidString, role: "assistant", content: content, contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [], conversationId: "conv-t1",
            profileId: pid
        )
        context.insert(node)
        try! context.save()
        return node
    }

    func testTradeOpenCloseReview() throws {
        // open
        let n1 = makeAssistantNode("好的记下。\n```trade\n{\"type\":\"open\",\"symbol\":\"nvda\",\"side\":\"long\",\"qty\":100,\"price\":180.5,\"reason\":\"回调到位\"}\n```\n")
        TradeLogIntentWriter.processChatIntents(nodeId: n1.id, context: context)
        XCTAssertTrue(n1.content.contains("已记开仓"))
        XCTAssertFalse(n1.content.contains("```trade"), "块应被替换（幂等）")
        var trades = try context.fetch(FetchDescriptor<TradeEntry>(
            predicate: #Predicate<TradeEntry> { $0.profileId == pid }))
        XCTAssertEqual(trades.count, 1)
        XCTAssertEqual(trades[0].symbol, "NVDA")   // 小写归一
        XCTAssertEqual(trades[0].status, "open")
        XCTAssertEqual(trades[0].reason, "回调到位")

        // close（翻 tag + 盈亏推导）
        let n2 = makeAssistantNode("```trade\n{\"type\":\"close\",\"symbol\":\"NVDA\",\"price\":198.55}\n```")
        TradeLogIntentWriter.processChatIntents(nodeId: n2.id, context: context)
        XCTAssertTrue(n2.content.contains("已平"), n2.content)
        trades = try context.fetch(FetchDescriptor<TradeEntry>(
            predicate: #Predicate<TradeEntry> { $0.profileId == pid }))
        XCTAssertEqual(trades[0].status, "closed")
        XCTAssertEqual(trades[0].closedPnLPercent ?? 0, 10.0, accuracy: 0.01)

        // review 挂卡
        let n3 = makeAssistantNode("```trade\n{\"type\":\"review\",\"symbol\":\"NVDA\",\"note\":\"论点对，入场纪律差\"}\n```")
        TradeLogIntentWriter.processChatIntents(nodeId: n3.id, context: context)
        XCTAssertTrue(n3.content.contains("复盘已挂卡"))
        trades = try context.fetch(FetchDescriptor<TradeEntry>(
            predicate: #Predicate<TradeEntry> { $0.profileId == pid }))
        XCTAssertEqual(trades[0].reviewNote, "论点对，入场纪律差")
    }

    func testTradeGuards() throws {
        // 缺理由拒收
        let n1 = makeAssistantNode("```trade\n{\"type\":\"open\",\"symbol\":\"AMD\",\"qty\":10,\"price\":150}\n```")
        TradeLogIntentWriter.processChatIntents(nodeId: n1.id, context: context)
        XCTAssertTrue(n1.content.contains("未落地"))
        // 无持仓卡 close 拒收
        let n2 = makeAssistantNode("```trade\n{\"type\":\"close\",\"symbol\":\"AMD\"}\n```")
        TradeLogIntentWriter.processChatIntents(nodeId: n2.id, context: context)
        XCTAssertTrue(n2.content.contains("没找到"))
        // 空头盈亏方向修正
        let short = TradeEntry(profileId: pid, symbol: "TSLA", side: "short", quantity: 10, price: 200, reason: "太贵")
        short.status = "closed"; short.closePrice = 180
        context.insert(short); try context.save()
        XCTAssertEqual(short.closedPnLPercent ?? 0, 10.0, accuracy: 0.01, "做空下跌是赚")
    }

    func testComposedSummaryWithTrades() throws {
        TradingStore.watchlistGateEnabled = true
        let t = TradeEntry(profileId: pid, symbol: "NVDA", side: "long", quantity: 100, price: 180.5, reason: "回调到位")
        context.insert(t); try context.save()
        let s = TradingStore.composedTradingSummary(context: context, profileId: pid)
        XCTAssertTrue(s.contains("当前持仓"), s)
        XCTAssertTrue(s.contains("回调到位"), "开仓理由必须进注入面（拷问弹药）")
        XCTAssertFalse(TradingStore.composedTradingSummary(context: context, profileId: "other").contains("NVDA"))
    }

    // MARK: - 合成锚分流（VocabCollector.chatRef :101 硬约束）

    func testTickerAnchorRef() {
        XCTAssertEqual(VocabCollector.chatRef(nodeId: "ticker:NVDA"), "ticker#NVDA")
        XCTAssertEqual(VocabCollector.parseTickerRef("ticker#NVDA"), "NVDA")
        XCTAssertNil(VocabCollector.parseTickerRef("chat#abc"))
        // parseChatRef 不吃 ticker: 合成锚（防"原消息已删除"死链）
        XCTAssertNil(VocabCollector.parseChatRef("chat#ticker:NVDA"))
        XCTAssertEqual(VocabCollector.chatRef(nodeId: "real-node-id"), "chat#real-node-id")
    }
}
#endif
