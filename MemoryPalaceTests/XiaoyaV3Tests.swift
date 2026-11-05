import XCTest
@testable import 记忆花园

/// 小芽引导 v3（plan-onboarding-xiaoya-impl §12）：Tip 1.1–1.4 一条条出 + 未看计数、tips.json 旧格式兼容、
/// 马克笔概念词首次展开、开场自我介绍续跑不错位、命名扫描（gardenOS，不回潮 atriumOS / page0/1/2）、贴纸规则。
/// 全部走 XiaoyaScriptFixture 的临时目录 + 内存偏好，不碰真实 AssistantChat/
@MainActor
final class XiaoyaV3Tests: XCTestCase {
    private var f: XiaoyaScriptFixture!

    override func setUp() async throws { f = try XiaoyaScriptFixture() }
    override func tearDown() async throws { f.clean() }

    private var chatDir: URL { f.root.appendingPathComponent("AssistantChat", isDirectory: true) }

    private func tipRunner() -> XiaoyaScriptRunner {
        let runner = XiaoyaScriptRunner(store: XiaoyaScriptStore(directory: chatDir), defaults: f.defaults, pacing: .instant,
                                        pairSupported: true, tipsSupported: true)
        runner.bind(f.engine)
        runner.attach(world: f.world)
        return runner
    }

    private func tipMessages() -> [(id: UUID, ref: XiaoyaTipRef, answer: XiaoyaCardAnswer?)] {
        f.engine.messages.compactMap { msg in
            guard case .tip(let ref)? = msg.card?.card else { return nil }
            return (msg.id, ref, msg.card?.answer)
        }
    }

    /// 走「保持神秘」到收尾：Tip 1.1 发在对话里
    private func runToTips(_ runner: XiaoyaScriptRunner) async throws {
        runner.start()
        await runner.idle()
        let identity = try XCTUnwrap(runner.progress?.awaitingMessageId)
        runner.answer(identity, .picked("ghost"))
        await runner.idle()
    }

    // MARK: B · Tip 1.1–1.4

    func testTipsStepOneByOneAndCountUnseen() async throws {
        let runner = tipRunner()
        try await runToTips(runner)
        XCTAssertEqual(tipMessages().map(\.ref.label), ["1.1"])
        XCTAssertEqual(runner.tips.unseenCount, 3)

        // 懂了，下一条 → 1.2，未看少一条
        runner.answer(tipMessages()[0].id, .tipNext)
        await runner.idle()
        XCTAssertEqual(tipMessages().map(\.ref.label), ["1.1", "1.2"])
        XCTAssertEqual(tipMessages()[0].answer, .tipNext)
        XCTAssertEqual(runner.tips.unseenCount, 2)
        XCTAssertEqual(runner.tipPulse, 1, "同一组后面几张不再亮")

        // 以后再看 → 不发卡，小芽说一句剩下几条
        runner.answer(tipMessages()[1].id, .tipLater)
        await runner.idle()
        XCTAssertEqual(tipMessages().count, 2)
        XCTAssertEqual(f.texts.last, XiaoyaScriptLines.tipsLater(2))
        XCTAssertEqual(runner.tips.unseenCount, 2)

        // 答过的卡不能再答
        runner.answer(tipMessages()[1].id, .tipNext)
        await runner.idle()
        XCTAssertEqual(tipMessages().count, 2)

        // 灯泡里点开 1.3 / 1.4 算看过，写回 tips.json
        runner.openTip(XiaoyaTipRef(number: 1, kind: .toList))
        runner.openTip(XiaoyaTipRef(number: 1, kind: .floors))
        XCTAssertEqual(runner.tips.unseenCount, 0)
        XCTAssertEqual(XiaoyaTipStore(directory: chatDir).load().unseenCount, 0)
    }

    func testLastTipOnlyCloses() async throws {
        let runner = tipRunner()
        try await runToTips(runner)
        for _ in 0..<3 {
            runner.answer(try XCTUnwrap(tipMessages().last?.id), .tipNext)
            await runner.idle()
        }
        XCTAssertEqual(tipMessages().map(\.ref.label), ["1.1", "1.2", "1.3", "1.4"])
        XCTAssertEqual(runner.tips.unseenCount, 0)
        runner.answer(try XCTUnwrap(tipMessages().last?.id), .tipNext)
        await runner.idle()
        XCTAssertEqual(tipMessages().count, 4, "1.4 之后没有下一条")
        XCTAssertEqual(tipMessages().last?.answer, .tipNext)
    }

    func testTipCatalogLabelsAndNext() {
        let refs = XiaoyaTipCatalog.refs(for: 1)
        XCTAssertEqual(refs.map(\.label), ["1.1", "1.2", "1.3", "1.4"])
        XCTAssertEqual(XiaoyaTipCatalog.next(after: refs[0]), refs[1])
        XCTAssertNil(XiaoyaTipCatalog.next(after: refs[3]))
        XCTAssertEqual(XiaoyaCard.tip(refs[1]).prompt, "Tip 1.2：去聊天")
        for kind in XiaoyaTipKind.allCases {
            XCTAssertFalse(XiaoyaScriptLines.tip(kind, strip: true).summary.isEmpty)
            XCTAssertFalse(XiaoyaScriptLines.tip(kind, strip: false).summary.isEmpty)
        }
        for answer: XiaoyaCardAnswer in [.tipNext, .tipLater] {
            XCTAssertEqual(try JSONDecoder().decode(XiaoyaCardAnswer.self, from: JSONEncoder().encode(answer)), answer)
        }
    }

    func testOldTipsFileCountsWholeGroupAsSeen() throws {
        // v2 写的 tips.json：只有 received，一组四张当年一口气都发在对话里了
        let old = #"{"received":[{"number":1,"receivedAt":781000000}]}"#
        let log = try JSONDecoder().decode(XiaoyaTipLog.self, from: Data(old.utf8))
        XCTAssertEqual(log.received.map(\.number), [1])
        XCTAssertEqual(log.unseenCount, 0)
        XCTAssertEqual(log.items.count, 4)

        let store = XiaoyaTipStore(directory: f.root.appendingPathComponent("tips-old"))
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load().unseenCount, 0)

        // 新格式写回去：带 seen，读回来一样
        var fresh = XiaoyaTipLog()
        XCTAssertTrue(fresh.record(1))
        XCTAssertTrue(fresh.markSeen(XiaoyaTipRef(number: 1, kind: .toDesk)))
        XCTAssertFalse(fresh.markSeen(XiaoyaTipRef(number: 1, kind: .toDesk)))
        store.save(fresh)
        let back = store.load()
        XCTAssertEqual(back, fresh)
        XCTAssertEqual(back.unseenCount, 3)
        XCTAssertTrue(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self).contains("seen"))
    }

    // MARK: E · 马克笔概念词

    func testGlossaryParsing() {
        let line = "要一把 [[API key]]，再看看[[楼层]]和[[楼层]]，**粗体**不算"
        XCTAssertEqual(XiaoyaGlossary.words(in: line), ["API key", "楼层"])
        XCTAssertEqual(XiaoyaGlossary.markdown("这是[[楼层]]。"), "这是**楼层**。")
        XCTAssertEqual(XiaoyaGlossary.plain("这是[[楼层]]。"), "这是楼层。")
        XCTAssertEqual(XiaoyaGlossary.pieces("a[[模型]]b"), [.text("a"), .mark("模型"), .text("b")])
        XCTAssertEqual(XiaoyaGlossary.words(in: "没有标记"), [])

        var log = XiaoyaGlossaryLog()
        let first = UUID(), second = UUID()
        XCTAssertEqual(log.record("先说[[楼层]]，再说[[不在词表]]", messageId: first), ["楼层"], "不在词表的词只画马克笔，不展开")
        XCTAssertEqual(log.record("又是[[楼层]]，还有[[模型]]", messageId: second), ["模型"], "第二次出现不再展开")
        XCTAssertEqual(log.terms(for: first).map(\.word), ["楼层"])
        XCTAssertEqual(log.terms(for: second).map(\.word), ["模型"])
        XCTAssertEqual(log.terms.map(\.word), ["楼层", "模型"])
    }

    func testEveryMarkedWordInScriptIsInTheTable() throws {
        let text = try String(contentsOf: Self.source("MemoryPalace/Services/Assistant/XiaoyaScriptLines.swift"), encoding: .utf8)
        let code = text.split(separator: "\n").map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
        let words = Set(XiaoyaGlossary.words(in: code))
        XCTAssertFalse(words.isEmpty)
        for word in words { XCTAssertNotNil(XiaoyaGlossary.term(word), "台词里的 [[\(word)]] 不在词表里") }
        for term in XiaoyaGlossary.terms { XCTAssertFalse(term.definition.isEmpty) }
        XCTAssertEqual(Set(XiaoyaGlossary.terms.map(\.word)), ["楼层", "API key", "模型", "记忆", "gardenOS"])
    }

    func testFirstMentionExpandsOnceAndSurvivesRelaunch() async throws {
        await f.start()
        await f.answer(.picked("newbie"))
        await f.answerFaces(user: "栗子", ta: "阿梨")
        let floorLine = try XCTUnwrap(f.engine.messages.first { $0.text == XiaoyaScriptLines.faceTaNamed("阿梨") })
        let keyLine = try XCTUnwrap(f.engine.messages.first { $0.text == XiaoyaScriptLines.keyIntro("newbie")[0] })
        XCTAssertEqual(f.script.glossary.terms(for: floorLine.id).map(\.word), ["楼层"])
        XCTAssertEqual(f.script.glossary.terms(for: keyLine.id).map(\.word), ["API key"])

        // 钥匙存好后「钥匙好使」带模型；再说到楼层（小白跟我说句话之后）不再展开
        await f.answer(XiaoyaScriptFixture.saved)
        let worked = try XCTUnwrap(f.engine.messages.first { $0.text == XiaoyaScriptLines.keyWorks(model: "gpt-4o-mini") })
        XCTAssertEqual(f.script.glossary.terms(for: worked.id).map(\.word), ["模型"])
        XCTAssertEqual(f.script.glossary.terms.map(\.word), ["楼层", "API key", "模型"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: chatDir.appendingPathComponent("glossary.json").path), "跟 history.json 同目录 → 进备份")

        await f.relaunch()
        XCTAssertEqual(f.script.glossary.terms(for: floorLine.id).map(\.word), ["楼层"], "重开后解释还跟在原来那句下面")

        // 再走一遍：同样的台词只画马克笔，不再展开
        f.script.replay()
        await f.script.idle()
        await f.answer(.picked("newbie"))
        await f.answerFaces(user: "栗子", ta: "阿梨")
        XCTAssertEqual(f.script.glossary.entries.count, 3)
    }

    func testGlossaryFileSurvivesCorruption() throws {
        let store = XiaoyaGlossaryStore(directory: f.root.appendingPathComponent("gloss-test"))
        var log = XiaoyaGlossaryLog()
        _ = log.record("[[记忆]]", messageId: UUID())
        store.save(log)
        XCTAssertEqual(store.load(), log)
        try Data("{oops".utf8).write(to: store.fileURL)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "坏文件挪开留底")
    }

    // MARK: F · 开场自我介绍

    func testOpeningIntroducesFirstAndKeepsBeatCount() async throws {
        let open = XiaoyaScriptLines.open
        XCTAssertEqual(open.count, 3, "三句：句数变了旧进度续跑会错位")
        XCTAssertTrue(open[0].contains("欢迎来到记忆花园"))
        XCTAssertTrue(open[0].contains(AssistantPrompts.assistantName))
        XCTAssertEqual(open[2], "先认识一下：你是哪种园丁？")
        var p = XiaoyaScriptProgress()
        p.step = .open
        XCTAssertEqual(XiaoyaScriptRunner.beats(for: p, pairSupported: true).count, 5)

        await f.start()
        XCTAssertEqual(Array(f.texts.prefix(3)), open)
        let waiting = try XCTUnwrap(f.awaited?.id)
        let count = f.engine.messages.count
        f.historyStore.save(f.engine.messages)     // history.json 是 0.5 s 合并写：被杀前已落盘的那份
        await f.relaunch()
        XCTAssertEqual(f.engine.messages.count, count, "已经在等分流卡：重开不重放开场")
        XCTAssertEqual(f.script.progress?.awaitingMessageId, waiting)
    }

    func testOldProgressMidOpeningResumesWithoutReplay() async throws {
        // v2 版本开场说到第 2 句被杀（emitted = 1 拍表情 + 2 句）：接着说第 3 句再出卡，前两句不重说
        var p = XiaoyaScriptProgress()
        p.step = .open
        p.emitted = 3
        f.scriptStore.save(p)
        f.defaults.set("started", forKey: XiaoyaScriptRunner.onboardingKey)
        await f.relaunch()
        XCTAssertEqual(f.texts.filter { XiaoyaScriptLines.open.contains($0) }, [XiaoyaScriptLines.open[2]])
        XCTAssertEqual(f.cardKinds, ["choice:newbie"])
    }

    // MARK: G · 命名

    private static let banned = try! NSRegularExpression(pattern: "atriumOS", options: [.caseInsensitive])
    private static let pageWord = try! NSRegularExpression(pattern: "page ?[012]", options: [.caseInsensitive])

    private static func source(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
    }

    private static func hits(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 源文件里的字符串字面量（注释除外）
    private static func literals(_ path: String) throws -> [String] {
        let text = try String(contentsOf: source(path), encoding: .utf8)
        let literal = try NSRegularExpression(pattern: #""([^"\\\n]|\\.)*""#)
        return text.split(separator: "\n").flatMap { line -> [String] in
            let code = line.components(separatedBy: "//").first ?? ""
            return literal.matches(in: code, range: NSRange(code.startIndex..., in: code)).map { (code as NSString).substring(with: $0.range) }
        }
    }

    func testNoAtriumOSInUserFacingCopy() throws {
        let files = [
            "MemoryPalace/Services/Assistant/XiaoyaScriptLines.swift",
            "MemoryPalace/Services/Assistant/AssistantPrompts.swift",
            "MemoryPalace/Services/Assistant/AssistantTools.swift",
            "MemoryPalace/Services/Assistant/AssistantChange.swift",
            "MemoryPalace/Services/Assistant/AssistantLedger.swift",
            "MemoryPalace/Services/Assistant/AssistantStamp.swift",
            "MemoryPalace/Views/Assistant/Onboarding/XiaoyaInfoCardView.swift",
            "MemoryPalace/Views/Assistant/Onboarding/XiaoyaPairCardView.swift",
            "MemoryPalace/Views/Assistant/Onboarding/XiaoyaTipCardView.swift",
            "MemoryPalace/Views/RightPanelSettingsView.swift",
            "MemoryPalace/Views/Page2/Chat/ChatSkinSettingsPage.swift",
        ]
        var checked = 0
        for file in files {
            for s in try Self.literals(file) {
                XCTAssertFalse(Self.hits(Self.banned, s), "\(file) 里还有 atriumOS：\(s)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100)
        // 台词表也不说 page0/1/2（XiaoyaV2Tests 有同样的断言，这里连工具描述一起扫）
        for s in try Self.literals("MemoryPalace/Services/Assistant/XiaoyaScriptLines.swift") {
            XCTAssertFalse(Self.hits(Self.pageWord, s), "台词里出现 page 说法：\(s)")
        }
    }

    func testPromptAndToolDescriptionsUseGardenNames() {
        let naming = AssistantPrompts.gardenNaming
        for word in ["记忆花园", "gardenOS", "聊天", "所有对话"] { XCTAssertTrue(naming.contains(word), "叫法里少了 \(word)") }
        for layer in [AssistantPrompts.defaultPersona(name: "小芽"), AssistantPrompts.rulesLayer, AssistantPrompts.compactRules] {
            XCTAssertFalse(Self.hits(Self.banned, layer))
        }
        XCTAssertTrue(AssistantPrompts.defaultPersona(name: "小芽").contains(naming))

        func descriptions(_ value: Any) -> [String] {
            if let dict = value as? [String: Any] {
                return dict.flatMap { key, v -> [String] in
                    if key == "description", let s = v as? String { return [s] }
                    return descriptions(v)
                }
            }
            if let array = value as? [Any] { return array.flatMap(descriptions) }
            return []
        }
        let all = AssistantTools.allDefinitions.flatMap(descriptions)
        XCTAssertGreaterThan(all.count, 10)
        for d in all {
            XCTAssertFalse(Self.hits(Self.banned, d), "工具描述里还有 atriumOS：\(d)")
            XCTAssertFalse(Self.hits(Self.pageWord, d), "工具描述里出现 page 说法：\(d)")
        }
    }

    // MARK: A · 贴纸规则

    func testStickerRules() {
        let L = XiaoyaScriptLines.self
        XCTAssertEqual(XiaoyaStickerRule.sticker(forLine: L.open[2]), .ques)
        XCTAssertEqual(XiaoyaStickerRule.sticker(forLine: L.end), .heart)
        XCTAssertEqual(XiaoyaStickerRule.sticker(forLine: L.keyWorks(model: "m")), .heart)
        XCTAssertEqual(XiaoyaStickerRule.sticker(forLine: L.ghost[1]), .excl)
        XCTAssertEqual(XiaoyaStickerRule.sticker(forLine: L.floorFailed("x")), .excl, "失败那句以重要为准，不当提问")
        XCTAssertNil(XiaoyaStickerRule.sticker(forLine: L.open[0]))
        XCTAssertTrue(XiaoyaStickerRule.stamps(XiaoyaScriptFixture.saved))
        XCTAssertFalse(XiaoyaStickerRule.stamps(.picked("newbie")))
        XCTAssertFalse(XiaoyaStickerRule.stamps(.tipNext))

        let ask = AssistantChatMessage(isUser: false, text: L.open[2], source: .script)
        let done = AssistantChatMessage(isUser: false, text: L.end, source: .script)
        let key = AssistantChatMessage(isUser: false, text: "", source: .script,
                                       card: XiaoyaCardState(card: .keyForm, answer: XiaoyaScriptFixture.saved))
        let model = AssistantChatMessage(isUser: false, text: "你是哪种园丁？")      // 模型说的：不贴
        let me = AssistantChatMessage(isUser: true, text: "为什么？", source: .script)
        let decor = XiaoyaStickerRule.decorations([ask, key, done, model, me])
        XCTAssertEqual(decor.count, XiaoyaStickerRule.limit, "一屏最多两张")
        XCTAssertEqual(decor[done.id], .line(.heart))
        XCTAssertEqual(decor[key.id], .stamp)
        XCTAssertNil(decor[ask.id], "更早的让位")
    }

    func testFreshStampOnlyAfterCompletingAStep() async {
        await f.start()
        await f.answer(.picked("tech"))
        XCTAssertNil(f.script.freshStamp, "选园丁类型不算完成一步")
        let keyCard = f.awaited?.id
        await f.answer(XiaoyaScriptFixture.saved)
        XCTAssertEqual(f.script.freshStamp, keyCard)
        f.script.stampPlayed(UUID())
        XCTAssertEqual(f.script.freshStamp, keyCard)
        f.script.stampPlayed(keyCard!)
        XCTAssertNil(f.script.freshStamp)
    }

    func testDictionaryAlwaysListsEveryWord() async throws {
        // 没走过引导（老用户）：5 个词照样全列，都没讲过
        XCTAssertEqual(f.script.glossary.dictionary.map(\.term), XiaoyaGlossary.terms)
        XCTAssertFalse(f.script.glossary.dictionary.contains { $0.spoken })

        await f.start()
        await f.answer(.picked("newbie"))
        await f.answerFaces()
        await f.answer(XiaoyaScriptFixture.saved)
        let dictionary = f.script.glossary.dictionary
        XCTAssertEqual(dictionary.count, XiaoyaGlossary.terms.count)
        XCTAssertEqual(Set(dictionary.map(\.term.word)), Set(XiaoyaGlossary.terms.map(\.word)))
        let spoken = f.script.glossary.terms.map(\.word)
        XCTAssertFalse(spoken.isEmpty)
        XCTAssertEqual(dictionary.prefix(spoken.count).map(\.term.word), spoken, "讲过的按先后排前面")
        XCTAssertTrue(dictionary.prefix(spoken.count).allSatisfy(\.spoken))
        XCTAssertFalse(dictionary.dropFirst(spoken.count).contains { $0.spoken })
    }

    func testMarkTapAndDictionaryRowOpenSameSheetTerm() {
        let line = "建一个 Ta 的[[楼层]]，再要一把 [[API key]]，[[不在词表]]"
        var log = XiaoyaGlossaryLog()
        _ = log.record(line, messageId: UUID())

        for entry in log.dictionary {
            let fromRow = XiaoyaGlossary.term(entry.term.word)
            XCTAssertEqual(fromRow, entry.term, "词典行弹的就是这一行的词")
            XCTAssertEqual(fromRow?.id, entry.term.word, "sheet(item:) 按词认")
        }
        let fromMarks = XiaoyaGlossary.words(in: line).compactMap(XiaoyaGlossary.term)
        XCTAssertEqual(fromMarks.map(\.word), ["楼层", "API key"])
        for term in fromMarks {
            XCTAssertEqual(term, log.dictionary.first { $0.term.word == term.word }?.term, "点马克笔词和点词典行弹同一张")
        }
        XCTAssertNil(XiaoyaGlossary.term("不在词表"), "不在词表的词点了不弹")
    }
}
