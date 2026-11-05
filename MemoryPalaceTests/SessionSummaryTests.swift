import XCTest
@testable import 记忆花园

/// 第三刀：窗口摘要分段追加 / 三层 / 水位线 / 收尾切段 / 跨窗口时间轴（plan-memory-fix-3）
final class SessionSummaryTests: XCTestCase {

    let pid = "xctest-session-summary"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func seg(_ title: String, kind: SessionSegment.Kind = .rolling, from: Int, to: Int, last: String? = nil,
                     start: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> SessionSegment {
        SessionSegment(kind: kind, title: title, start: start, end: start.addingTimeInterval(600), from: from, to: to,
                       lastNodeId: last, story: "经过\(title)", quotes: "粟粟：「原话\(title)」", pending: "待续\(title)")
    }

    // MARK: - 存储

    func testRenderParseRoundTripKeepsSegmentsInOrder() {
        let s = SessionSummary(conversationId: "conv-abcdef123", title: "复诊那件事", compressedCount: 40,
                               segments: [seg("一", from: 0, to: 20, last: "n20"), seg("二", kind: .closeout, from: 20, to: 40, last: "n40")],
                               updatedAt: Date(timeIntervalSince1970: 1_790_001_000))
        let back = SessionSummaryStore.parse(SessionSummaryStore.render(s))
        XCTAssertEqual(back, s)
    }

    func testSaveAppendDoesNotTouchOldSegments() throws {
        var s = SessionSummaryStore.loadOrSeed(conversationId: "conv-append-1", profileId: pid, title: "标题")
        s.segments.append(seg("一", from: 0, to: 10, last: "n10"))
        try SessionSummaryStore.save(s, profileId: pid)
        var again = try XCTUnwrap(SessionSummaryStore.load(conversationId: "conv-append-1", profileId: pid))
        again.segments.append(seg("二", from: 10, to: 20, last: "n20"))
        try SessionSummaryStore.save(again, profileId: pid)
        let final = try XCTUnwrap(SessionSummaryStore.load(conversationId: "conv-append-1", profileId: pid))
        XCTAssertEqual(final.segments.map(\.title), ["一", "二"])
        XCTAssertEqual(final.segments[0], s.segments[0])
    }

    func testLegacySummaryBecomesSegmentZero() {
        SummaryFileStore.save(ContextSummary(summary: "老的累计摘要", coveredCount: 30, updatedAt: Date()),
                              conversationId: "conv-legacy-1", profileId: pid, conversationTitle: "老对话")
        let s = SessionSummaryStore.loadOrSeed(conversationId: "conv-legacy-1", profileId: pid, title: "老对话")
        XCTAssertEqual(s.compressedCount, 30)
        XCTAssertEqual(s.segments.count, 1)
        XCTAssertEqual(s.segments[0].kind, .legacy)
        XCTAssertEqual(s.segments[0].story, "老的累计摘要")
        XCTAssertNotNil(SummaryFileStore.load(conversationId: "conv-legacy-1", profileId: pid), "老文件不动")
    }

    // MARK: - 水位线

    func testResumeIndexPrefersNodeIdThenFallsBackToCount() {
        let s = SessionSummary(conversationId: "c", title: "", compressedCount: 0,
                               segments: [seg("一", from: 0, to: 3, last: "b")], updatedAt: Date())
        XCTAssertEqual(SessionSummaryStore.resumeIndex(s, pathIds: ["a", "b", "c", "d"]), 2, "按 id 找到 b，从它后面接")
        XCTAssertEqual(SessionSummaryStore.resumeIndex(s, pathIds: ["x", "y", "z", "w"]), 3, "id 找不到（切过分支）退回下标")
        XCTAssertEqual(SessionSummaryStore.resumeIndex(s, pathIds: ["x"]), 1, "夹在路径长度内")
    }

    func testPendingRangeNoDuplicateNoGapAndFirstCloseoutCap() {
        let ids = (0..<200).map { "n\($0)" }
        let empty = SessionSummary(conversationId: "c", title: "", compressedCount: 0, segments: [], updatedAt: Date())
        XCTAssertEqual(SessionCloseout.pendingRanges(empty, pathIds: ids, dates: []), [50..<200], "一段都没有：最多从倒数 150 条开始")
        let done = SessionSummary(conversationId: "c", title: "", compressedCount: 0,
                                  segments: [seg("一", from: 50, to: 200, last: "n199")], updatedAt: Date())
        XCTAssertEqual(SessionCloseout.pendingRanges(done, pathIds: ids, dates: []), [], "总结到最后一条了，不重复写")
        XCTAssertEqual(SessionCloseout.pendingRanges(done, pathIds: ids + ["n200", "n201"], dates: []), [200..<202], "接着聊了：只写新的")
    }

    func testChunksSplitLongTail() {
        XCTAssertEqual(SessionCloseout.chunks(0..<130, size: 60), [0..<60, 60..<120, 120..<130])
        XCTAssertEqual(SessionCloseout.chunks(5..<9, size: 60), [5..<9])
    }

    // MARK: - 注入

    func testInjectionFullRecentSegmentsAndTitlesForOlder() throws {
        let s = SessionSummary(conversationId: "conv-abcdef123", title: "t", compressedCount: 0,
                               segments: [seg("一", from: 0, to: 1), seg("二", from: 1, to: 2), seg("三", from: 2, to: 3)],
                               updatedAt: Date())
        let text = try XCTUnwrap(SessionSummaryStore.injectionText(s, fullCount: 2))
        XCTAssertTrue(text.contains("· 一"))
        XCTAssertFalse(text.contains("经过一"), "更早的只放标题")
        XCTAssertTrue(text.contains("经过二") && text.contains("经过三"))
        XCTAssertFalse(text.contains("待续三"), "c2c3-v2 第 7 段：段里的【待续】不注入，待续只有待续本子一份")
        XCTAssertTrue(text.contains("conversation_id=conv-abc"))
    }

    /// c2c3-v2 第 7 段（车头 B）：段里的待续只留在文件里给 A4 搬——注入、recall、A3 重压输入、A 线检索都不拼；文件存读原样
    func testSegmentPendingOnlyInFileNotInModelText() throws {
        let s = SessionSummary(conversationId: "conv-pending1", title: "t", compressedCount: 0,
                               segments: [seg("一", from: 0, to: 1, last: "n1"), seg("二", from: 1, to: 2, last: "n2"), seg("三", from: 2, to: 3, last: "n3")],
                               updatedAt: Date(timeIntervalSince1970: 1_790_001_000))
        XCTAssertFalse(SessionSummaryStore.segmentText(s.segments[0]).contains("待续"))
        XCTAssertFalse(try XCTUnwrap(SessionSummaryStore.injectionText(s, fullCount: 3)).contains("待续"))
        XCTAssertFalse(SessionSummaryStore.recallText(s).contains("待续"), "recall 不列段里的待续（包括更早段落那块）")
        let a3Input = WindowSummaryWriter.userContent(title: "t", segments: s.segments, rawTail: [], speakers: .init(userName: "粟粟", assistantName: "小克"))
        XCTAssertFalse(a3Input.contains("待续"), "A3 重压输入不带")
        XCTAssertFalse(CatalogALineReader.segmentParts(s.segments[0]).map(\.text).joined().contains("待续"))
        let file = SessionSummaryStore.render(s)
        XCTAssertTrue(file.contains("【待续】待续一"), "文件里原样留着，A4 从这里搬")
        XCTAssertEqual(SessionSummaryStore.parse(file)?.segments.map(\.pending), ["待续一", "待续二", "待续三"])
    }

    /// c2c3-v2 第 7 段（车头 B）：新写的 A2 段带格式标记 w=1，存读保留；以前的文件没有 = 0
    func testSegmentFormatMarkerRoundTrip() async throws {
        let req = SessionSegmentWriter.Request(messages: [.init(id: "1", role: "user", content: "嗯", date: Date())], kind: .rolling, from: 0,
                                               persona: "", speakers: .init(userName: "粟粟", assistantName: "小克"), previous: nil)
        let out = try await SessionSegmentWriter.write(req) { _, _ in "标题：一\n【经过】经过\n【原话】粟粟：「嗯」\n【待续】周三问" }
        let written = try XCTUnwrap(out)
        XCTAssertEqual(written.format, SessionSegment.currentFormat)
        let s = SessionSummary(conversationId: "conv-format1", title: "t", compressedCount: 0, segments: [written, seg("老", from: 1, to: 2)],
                               updatedAt: Date(timeIntervalSince1970: 1_790_001_000))
        let file = SessionSummaryStore.render(s)
        XCTAssertTrue(file.contains(" w=\(SessionSegment.currentFormat)"))
        XCTAssertEqual(SessionSummaryStore.parse(file)?.segments.map(\.format), [SessionSegment.currentFormat, 0], "老段没标照读 = 0")
    }

    // MARK: - 写手

    func testTranscriptUsesFloorNamesNotUserAI() {
        let msgs = [SessionSegmentWriter.Message(id: "1", role: "user", content: "下周三复诊", date: nil),
                    SessionSegmentWriter.Message(id: "2", role: "assistant", content: "记住了", date: nil)]
        let t = SessionSegmentWriter.transcript(msgs, speakers: .init(userName: "粟粟", assistantName: "小克"))
        XCTAssertEqual(t, "粟粟：下周三复诊\n\n小克：记住了")
        let sys = SessionSegmentWriter.systemPrompt(persona: "你是小克。", speakers: .init(userName: "粟粟", assistantName: "小克"), kind: .rolling)
        XCTAssertTrue(sys.hasPrefix("你是小克。"))
        XCTAssertTrue(sys.contains("【经过】") && sys.contains("【原话】"))
        XCTAssertTrue(sys.contains("【待续】") && sys.contains("真的没有就写「无」"), "c2c3-v2 第 7 段：A2 恢复写待续（A4 拼日时搬进待续本子）")
        XCTAssertFalse(sys.contains("【时间轴】"))
        XCTAssertTrue(sys.contains("接着上一段写") && sys.contains("不要用「这个窗口」开头"))
        XCTAssertFalse(sys.contains("发生了什么、我当时怎么想"), "10-16 A2 只拍片子：【经过】不再要求写当时怎么想")
        XCTAssertTrue(sys.contains("只写发生了什么") && sys.contains("不写我当时怎么想、什么感受"))
        XCTAssertTrue(SessionSegmentWriter.systemPrompt(persona: "", speakers: .init(userName: "", assistantName: ""), kind: .closeout).contains("尾段"), "v5 D1：收尾那截是 A2 的尾段")
    }

    /// v4-1 §四：上一段全文进输入、待续不进
    func testUserContentFeedsPreviousFullTextWithoutPending() {
        let prev = seg("一", from: 0, to: 10, last: "n9")
        let text = SessionSegmentWriter.userContent(messages: [], speakers: .init(userName: "粟粟", assistantName: "小克"), previous: prev, kind: .rolling)
        XCTAssertTrue(text.contains("经过一") && text.contains("粟粟：「原话一」"))
        XCTAssertFalse(text.contains("待续一"))
    }

    /// 格式两次都不合格：不存、抛格式错；第一次不合格带提醒重写
    func testWriterRetriesOnceThenThrowsFormat() async throws {
        let req = SessionSegmentWriter.Request(
            messages: [.init(id: "1", role: "user", content: "嗯", date: Date())], kind: .rolling, from: 0, persona: "",
            speakers: .init(userName: "粟粟", assistantName: "小克"), previous: nil)
        var calls = 0
        do {
            _ = try await SessionSegmentWriter.write(req) { _, _ in calls += 1; return "（想了很久）……想到了" }
            XCTFail("应该抛")
        } catch MemoryWriterError.format {}
        XCTAssertEqual(calls, 2)
        let ok = try await SessionSegmentWriter.write(req) { _, user in
            user.contains("提醒") ? "标题：好了\n【经过】接着聊\n【原话】粟粟：「嗯」\n【待续】不该留下" : "这个窗口聊了很多"
        }
        XCTAssertEqual(ok?.title, "好了")
        XCTAssertEqual(ok?.pending, "不该留下", "【待续】存进段的 pending")
    }

    func testParseOutputAndForbiddenAddress() {
        let raw = """
        标题：复诊安排
        【经过】粟粟说下周三复诊，我记下了。
        【原话】粟粟：「记住我下周三要去复诊」
        我：「记住了」
        【待续】周三问结果
        【时间轴】聊了复诊安排，约好周三问结果。
        """
        let o = SessionSegmentWriter.parse(raw)
        XCTAssertEqual(o.title, "复诊安排")
        XCTAssertEqual(o.story, "粟粟说下周三复诊，我记下了。")
        XCTAssertEqual(o.quotes, "粟粟：「记住我下周三要去复诊」\n我：「记住了」")
        XCTAssertFalse(o.quotes.contains("周三问结果") || o.quotes.contains("时间轴"), "【待续】【时间轴】不进原话")
        XCTAssertEqual(o.pending, "周三问结果", "【待续】单独收，多写的【时间轴】丢掉")
        XCTAssertEqual(SessionSegmentWriter.parse("标题：一\n【经过】经过\n【原话】我：「嗯」\n【待续】\n- 甲\n- 乙").pending, "甲\n乙", "一条一行")
        XCTAssertEqual(SessionSegmentWriter.parse("标题：一\n【经过】经过\n【原话】我：「嗯」\n【待续】无").pending, "", "「无」= 没有")
        XCTAssertFalse(SessionSegmentWriter.hasForbiddenAddress(o))
        XCTAssertNil(SessionSegmentWriter.formatProblem(raw))

        var bad = o
        bad.story = "用户说要复诊"
        XCTAssertTrue(SessionSegmentWriter.hasForbiddenAddress(bad))
        var quoted = o
        quoted.story = "她说「我不是用户」"
        XCTAssertFalse(SessionSegmentWriter.hasForbiddenAddress(quoted), "引号里的原话不算")
    }

    /// 10-16：只拦拿「用户」称呼她（用户说 / 问 / 要…当主语、说话人写成「用户：」）；聊 app 时的普通名词放行
    func testForbiddenAddressOnlyCatchesUserAsAddress() {
        let ok = [
            "标题：用户画像怎么做\n【经过】我们聊了别的用户怎么用这个 app，又对了一遍用户画像。\n【原话】粟粟：「新用户第一次打开会懵」\n我：「那先做引导」",
            "标题：注册流程\n【经过】粟粟想让每个用户都能自己选楼层，其他用户说的问题也记下了。\n【原话】粟粟：「用户说看不懂」",
        ]
        for raw in ok { XCTAssertNil(SessionSegmentWriter.formatProblem(raw), raw) }
        let bad = [
            "标题：复诊\n【经过】用户说下周三复诊，我记下了。\n【原话】粟粟：「周三」",
            "标题：复诊\n【经过】我问她哪天，用户问我能不能提醒。\n【原话】粟粟：「周三」",
            "标题：复诊\n【经过】用户要我记住周三。\n【原话】粟粟：「周三」",
            "标题：复诊\n【经过】说好周三去。\n【原话】用户：「记住周三」\n我：「好」",
            "标题：复诊\n【经过】说好周三去。\n【原话】我：「好」\n用户：「周三」",
        ]
        for raw in bad { XCTAssertEqual(SessionSegmentWriter.formatProblem(raw), "不要用「用户」称呼对方", raw) }
    }

    /// 10-16 astra #4 / #5：主语隔时间词 / 副词、常见人物动作、宾语写法都拦；「用户说明 / 问题 / 需求…」名词组合和跨行引文放行
    func testForbiddenAddressSubjectObjectAndNounCombos() {
        let ok = [
            "补全用户说明", "整理用户问题", "改了用户说明书", "列了用户需求", "聊用户体验", "用户名不能重复",
            "粟粟说「测试文本：\n用户：你好\n助手：你好」", "我们的用户都喜欢简洁", "老用户和用户画像对不上", "给新用户做引导",
        ]
        for t in ok { XCTAssertFalse(SessionSegmentWriter.addressesAsUser(t), t) }
        let bad = [
            "用户提到下周复诊", "用户喜欢暖奶白", "用户今天说想休息", "我答应提醒用户吃药", "用户讨厌下雨",
            "用户刚才又想吃火锅", "用户也同意了", "用户还拒绝了", "用户决定周三去", "用户说明天复诊",
            "我告诉用户别熬夜", "给用户倒了杯水", "陪用户聊到半夜", "跟用户约好了", "我和用户一起看了电影",
        ]
        for t in bad { XCTAssertTrue(SessionSegmentWriter.addressesAsUser(t), t) }
        XCTAssertNil(SessionSegmentWriter.formatProblem("标题：测试\n【经过】粟粟说「测试文本：\n用户：你好\n助手：你好」\n【原话】粟粟：「补全用户说明」"),
                     "跨行引文里的说话人不算")
        XCTAssertEqual(SessionSegmentWriter.formatProblem("标题：复诊\n【经过】用户提到下周复诊。\n【原话】粟粟：「周三」"), "不要用「用户」称呼对方")
    }

    // MARK: - 标题必须一行（10-16）

    /// 模型没给标题时兜底只取经过的第一行（以前 prefix(15) 把换行带进标题）
    func testFallbackTitleTakesFirstLineOnly() {
        XCTAssertEqual(SessionSegmentWriter.parse("标题：\n【经过】（翻了翻笔记）\n\n对上了\n\n后面接着说\n【原话】粟粟：「嗯」").title, "（翻了翻笔记）")
        XCTAssertEqual(SessionSegmentWriter.parse("【经过】一二三四五六七八九十一二三四五六七\n第二行\n【原话】粟粟：「嗯」").title,
                       "一二三四五六七八九十一二三四五", "第一行再截 15 字")
    }

    /// 标题里带换行也写成一行：段头紧跟机读行，严格读读得回来
    func testRenderKeepsMultilineTitleOnOneLine() throws {
        var s = SessionSummary(conversationId: "conv-oneline-1", title: "多行\n标题", compressedCount: 0,
                               segments: [seg("一", from: 0, to: 2, last: "n2")], updatedAt: Date(timeIntervalSince1970: 1_790_001_000))
        s.segments[0].title = "（翻了翻笔记）\n\n对上了\r\n"
        let raw = SessionSummaryStore.render(s)
        let lines = raw.components(separatedBy: "\n")
        let head = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("## ") })
        XCTAssertTrue(lines[head + 1].hasPrefix("<!-- seg "))
        let back = try XCTUnwrap(try SessionSummaryStore.parseStrict(raw, path: "t"))
        XCTAssertEqual(back.segments.map(\.title), ["（翻了翻笔记） 对上了"])
        XCTAssertEqual(back.title, "多行 标题")
    }

    /// 老文件：段标题断成几行 → 严格读并回一行再读；只修这一种形状，别的照旧判坏
    func testStrictReadRepairsSpilledTitleOnly() throws {
        let good = SessionSummary(conversationId: "conv-spill-1", title: "t", compressedCount: 0,
                                  segments: [seg("一", from: 0, to: 2, last: "n2"), seg("二", kind: .closeout, from: 2, to: 4, last: "n4")],
                                  updatedAt: Date(timeIntervalSince1970: 1_790_001_000))
        let raw = SessionSummaryStore.render(good)
        let spilled = raw.replacingOccurrences(of: " · 二\n<!-- seg", with: " · 二\n\n续上的半句\n\n<!-- seg")
        XCTAssertNotEqual(spilled, raw)
        XCTAssertEqual(SessionSummaryStore.parse(spilled)?.segments.count, 1, "宽松读把断开的那段吞进上一段（病根）")
        let fixed = try XCTUnwrap(try SessionSummaryStore.parseStrict(spilled, path: "t"))
        XCTAssertEqual(fixed.segments.map(\.title), ["一", "二 续上的半句"])
        XCTAssertEqual(fixed.segments[1].lastNodeId, "n4")
        XCTAssertEqual(fixed.segments[1].kind, .closeout)
        XCTAssertEqual(fixed.segments[0], good.segments[0], "前一段原样")
        XCTAssertEqual(fixed.segments[1].story, good.segments[1].story)

        func corrupt(_ text: String, _ why: String) {
            XCTAssertThrowsError(try SessionSummaryStore.parseStrict(text, path: "t"), why) { e in
                XCTAssertEqual(e as? MemoryReadError, .corrupt("t"), why)
            }
        }
        let headingLine = try XCTUnwrap(raw.components(separatedBy: "\n").first { $0.hasSuffix(" · 二") })
        corrupt(raw.replacingOccurrences(of: headingLine + "\n", with: ""), "段头整行没了：往上找到的是上一段的机读行")
        corrupt(raw.replacingOccurrences(of: " · 二\n<!-- seg", with: " · 二\n1\n2\n3\n4\n5\n6\n7\n<!-- seg"), "夹的行太多")
        corrupt(raw.replacingOccurrences(of: " · 二\n<!-- seg", with: " · 二\n" + String(repeating: "长", count: 41) + "\n<!-- seg"), "夹的字太长")
        corrupt(raw.replacingOccurrences(of: headingLine + "\n", with: "## 正文里的小标题\n夹一行\n"), "不是「## 时间 · 标题」样子的不认")
        corrupt(raw.replacingOccurrences(of: headingLine + "\n", with: "## 示例 · 标题\n夹一行\n"), "有「 ·」但不是真时间头的不认")

        // 10-16 astra #1：正文里写了段格式示例（上一段的经过里），段数恰好凑得上也不许修成新段
        let segMeta = "<!-- seg kind=rolling from=0 to=1 -->"
        let realHead = String(headingLine.prefix { $0 != "·" }) + "· 示例"
        for (example, why) in [
            ("## 示例 · 标题\n【经过】正文\n" + segMeta, "astra 原例：假段头 + 层标记"),
            (realHead + "\n【经过】正文\n" + segMeta, "真时间头但夹行带【经过】"),
            (realHead + "\n```\n" + segMeta, "夹行是代码围栏"),
            (realHead + "\n<!-- 注释 -->\n" + segMeta, "夹行是 HTML 注释"),
        ] {
            corrupt(raw.replacingOccurrences(of: headingLine, with: example + "\n\n" + headingLine), why)
        }
        XCTAssertNil(SessionSummaryStore.repairSpilledTitles("## 示例 · 标题\n【经过】正文\n" + segMeta))
    }

    /// 跨日段头（终点带日期）断了标题也修得回来
    func testStrictReadRepairsSpilledTitleCrossDay() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var cross = seg("二", from: 2, to: 4, last: "n4", start: start)
        cross.end = start.addingTimeInterval(2 * 86_400)
        let s = SessionSummary(conversationId: "conv-spill-x", title: "t", compressedCount: 0,
                               segments: [seg("一", from: 0, to: 2, last: "n2"), cross], updatedAt: start)
        let raw = SessionSummaryStore.render(s)
        XCTAssertTrue(raw.contains("–\(SessionSummaryStore.timeRange(cross).split(separator: "–").last!) · 二"))
        let spilled = raw.replacingOccurrences(of: " · 二\n<!-- seg", with: " · 二\n后半句\n<!-- seg")
        let fixed = try XCTUnwrap(try SessionSummaryStore.parseStrict(spilled, path: "t"))
        XCTAssertEqual(fixed.segments.map(\.title), ["一", "二 后半句"])
    }

    /// 搬迁读窗口现状走严格读：断标题的老文件能读、不再列进「格式对不上」
    func testMigrationStateReadsSpilledTitleFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spill-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let s = SessionSummary(conversationId: "spill002-aaaa", title: "t", compressedCount: 0,
                               segments: [seg("一", from: 0, to: 2, last: "n2"), seg("二", kind: .closeout, from: 2, to: 4, last: "n4")],
                               updatedAt: Date(timeIntervalSince1970: 1_790_001_000))
        let spilled = SessionSummaryStore.render(s).replacingOccurrences(of: " · 二\n<!-- seg", with: " ·\n\n续上的半句\n\n<!-- seg")
        let dir = SessionSummaryStore.dir(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(spilled.utf8).write(to: dir.appendingPathComponent("spill002-t.md"))
        let st = try MemoryMigration.state("spill002-aaaa", root: root)
        XCTAssertTrue(st.a2OnDisk)
        XCTAssertEqual(st.a2.segments.map(\.title), ["一", "续上的半句"], "标题整个从下一行开始的也并得回来")
    }

    /// 时间轴条目头里的窗口标题带换行也写成一行，严格读不判坏
    func testTimelineRenderKeepsWindowTitleOnOneLine() throws {
        let e = TimelineEntry(start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_000_600),
                              conversationId: "conv-tl-oneline", title: "两行\n标题", text: "- 聊了一件事", pending: "",
                              day: "2026-09-21", lastNodeId: "n9")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-oneline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(TimelineStore.render([e], month: "2026-09").utf8).write(to: dir.appendingPathComponent("2026-09.md"))
        let back = try TimelineStore.entriesStrict(month: "2026-09", in: dir)
        XCTAssertEqual(back.map(\.title), ["两行 标题"])
        XCTAssertEqual(back.first?.lastNodeId, "n9")
    }
}
