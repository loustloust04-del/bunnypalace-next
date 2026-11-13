import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// C2 严格填表、一次整包重写、最终批次原子写入；水位与预算沿原有合同。
final class FragmentPoolTests: XCTestCase {

    private let pid = "xctest-fragment-pool"
    private let names = MemoryExtractor.Names(userName: "粟粟", assistantName: "小克")
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: FragmentPool.customPromptKey)
        UserDefaults.standard.removeObject(forKey: FragmentPool.customPromptKey)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: FragmentPool.customPromptKey) }
        else { UserDefaults.standard.removeObject(forKey: FragmentPool.customPromptKey) }
        super.tearDown()
    }

    private func msgs(_ n: Int) -> [FragmentPool.Message] {
        (0..<n).map { i in
            FragmentPool.Message(id: "n\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "第\(i)条",
                                 date: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12, minute: i)))
        }
    }

    private func card(msg: Int = 1, content: String = "粟粟周三要复诊", tags: String = "[\"复诊\"]", importance: Int = 4,
                      emotion: Int = -1, resolved: String = "false", category: String = "\"context\"",
                      subject: String? = "\"测试人物\"", speaker: String? = "\"用户自述\"") -> String {
        let attribution = (subject.map { ",\"subject\":\($0)" } ?? "") + (speaker.map { ",\"speaker\":\($0)" } ?? "")
        return "{\"msg\":\(msg),\"content\":\"\(content)\",\"tags\":\(tags),\"importance\":\(importance),\"emotion\":\(emotion),\"resolved\":\(resolved),\"category\":\(category)\(attribution)}"
    }

    /// 本机路线 system 封顶 3000 字：默认模板（连换完名字后）都得在里面，不然尾巴的例子会被截掉
    func testDefaultTemplateFitsLocalSystemBudget() {
        XCTAssertLessThan(FragmentPool.defaultTemplate.count, LocalChatProvider.systemBudget)
        XCTAssertLessThan(FragmentPool.systemPrompt(names: names).count, LocalChatProvider.systemBudget)
    }

    func testDefaultSystemExpandsNamesWithoutHardcodedNames() {
        for forbidden in ["粟粟", "狗狗", "小克"] {
            XCTAssertFalse(FragmentPool.defaultTemplate.contains(forbidden))
        }
        let system = FragmentPool.systemPrompt(names: .init(userName: "岚汐", assistantName: "杉澈"), day: "2026-10-20")
        XCTAssertFalse(system.contains("{{"))
        XCTAssertTrue(system.contains("岚汐"))
        XCTAssertTrue(system.contains("杉澈"))
        for forbidden in ["粟粟", "狗狗", "小克"] { XCTAssertFalse(system.contains(forbidden)) }
    }

    func testNote() {
        XCTAssertEqual(FragmentPool.note(added: 4, rejected: 1, fallback: nil), "记下 4 条 · 拒收 1 张（格式不对）")
        XCTAssertEqual(FragmentPool.note(added: 0, rejected: 0, fallback: "本机模型没下，这一轮用 x"), "记下 0 条 · 本机模型没下，这一轮用 x")
    }

    // MARK: - 严格

    func testStrictEnvelope() {
        XCTAssertEqual(FragmentPool.strictObjectText("{\"fragments\":[]}"), "{\"fragments\":[]}")
        XCTAssertEqual(FragmentPool.strictObjectText("```json\n{\"fragments\":[]}\n```"), "{\"fragments\":[]}", "一层 ```json 围栏可以")
        XCTAssertNotNil(FragmentPool.strictObjectText("```\n{\"fragments\":[]}\n```"))
        XCTAssertNil(FragmentPool.strictObjectText("好的：{\"fragments\":[]}"), "前面有废话不收")
        XCTAssertNil(FragmentPool.strictObjectText("{\"fragments\":[]} 就这些"), "后面有废话不收")
        XCTAssertNil(FragmentPool.strictObjectText("```json\n```json\n{}\n```\n```"), "两层围栏不收")
        XCTAssertNil(FragmentPool.parse("{\"facts\":[]}", visible: 1...3), "没有 fragments 整包不合格")
        XCTAssertNil(FragmentPool.parse("[]", visible: 1...3))
    }

    /// 开头那一块 <think>…</think> 先剥掉再走严格规则；没收尾 / 不在开头 / 第二块都不剥
    func testLeadingThinkBlockStripped() {
        XCTAssertEqual(FragmentPool.strictObjectText("<think>\n好的，我需要分析 {这段} 对话\n</think>\n\n{\"fragments\":[]}"), "{\"fragments\":[]}")
        XCTAssertEqual(FragmentPool.strictObjectText("<think></think>```json\n{\"fragments\":[]}\n```"), "{\"fragments\":[]}", "剥完再认一层围栏")
        XCTAssertNil(FragmentPool.strictObjectText("<think>想到一半 {\"fragments\":[]}"), "没收尾不合格")
        XCTAssertNil(FragmentPool.strictObjectText("好的<think></think>{\"fragments\":[]}"), "不在开头不剥")
        XCTAssertNil(FragmentPool.strictObjectText("<think>a</think><think>b</think>{\"fragments\":[]}"), "只剥开头那一块")
        XCTAssertNil(FragmentPool.strictObjectText("<think>a</think>{\"fragments\":[]} 就这些"), "剥完照样严格")
        XCTAssertEqual(FragmentPool.parse("<think>\n嗯\n</think>\n{\"fragments\":[\(card())]}", visible: 1...3)?.fragments.count, 1)
    }

    /// 本机预算按实际 system 字数算（trimmed 同一口径），让出重来那句；长段不再白丢开头
    func testLocalBudgetUsesActualSystemLength() {
        let note = FragmentPool.retryNote.count
        XCTAssertEqual(FragmentModelRoute.localUserBudget(system: String(repeating: "字", count: 550)), 6000 - 550 - note)
        XCTAssertEqual(FragmentModelRoute.localUserBudget(system: String(repeating: "字", count: 5000)), 6000 - 3001 - note,
                       "system 超 3000 按 trimmed 截后的 3001 算")
    }

    private func longMsgs(_ n: Int, chars: Int = 500) -> [FragmentPool.Message] {
        (0..<n).map { i in FragmentPool.Message(id: "L\(i)", role: i % 2 == 0 ? "user" : "assistant",
                                                content: "第\(i + 1)条" + String(repeating: "嗯", count: chars), date: nil) }
    }

    func testLocalRunSendsMoreAndRetryFitsTrimmed() async throws {
        var sent: [(system: String, user: String)] = []
        _ = try? await FragmentPool.run(longMsgs(15), names: names, local: true) { system, user in
            sent.append((system, user)); return "不是 JSON"
        }
        XCTAssertEqual(sent.count, 2)
        for s in sent {
            let t = LocalChatProvider.trimmed(system: s.system, messages: [(role: "user", content: s.user)], hasImages: false)
            XCTAssertEqual(t.history.first?.content, s.user, "送进去的整截（含重来那句）trimmed 不再截")
        }
    }

    /// msg 只认模型看得到的编号：被预算丢掉的前几条不算合法出处
    func testMsgMustBeVisibleToModel() async throws {
        XCTAssertEqual(FragmentPool.parse("{\"fragments\":[\(card(msg: 2)),\(card(msg: 5, content: "粟粟喜欢暖奶白"))]}", visible: 4...6)?.rejected, 1)
        let msgs = longMsgs(15)
        let window = FragmentPool.window(msgs, names: names, charBudget: FragmentModelRoute.localUserBudget(system: FragmentPool.systemPrompt(names: names)))
        XCTAssertGreaterThan(window.visible.lowerBound, 1)
        XCTAssertEqual(window.visible.upperBound, 15)
        XCTAssertEqual(FragmentPool.window(msgs, names: names, charBudget: nil).visible, 1...15)
        let b = try await FragmentPool.run(msgs, names: names, local: true) { _, _ in
            "{\"fragments\":[\(self.card(msg: 1)),\(self.card(msg: 15, content: "粟粟喜欢暖奶白"))]}"
        }
        XCTAssertEqual(b?.fragments.map(\.msg), [15])
        XCTAssertEqual(b?.rejected, 1, "第 1 条模型没看到：扔")
        let remote = try await FragmentPool.run(msgs, names: names) { _, _ in "{\"fragments\":[\(self.card(msg: 1))]}" }
        XCTAssertEqual(remote?.fragments.count, 1, "云上不截：第 1 条照收")
    }

    func testSingleBadCardDropped() {
        let raw = "{\"fragments\":[\(card()),\(card(msg: 9)),\(card(importance: 7)),\(card(tags: "[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\"]")),{\"msg\":1},\(card(content: String(repeating: "长", count: 201)))]}"
        let b = FragmentPool.parse(raw, visible: 1...3)
        XCTAssertEqual(b?.fragments.count, 1)
        XCTAssertEqual(b?.rejected, 5, "编号越界 / 重要度越界 / tags 超限 / 缺字段 / 正文超限各扔一张")
    }

    func testUnknownCategoryRejected() {
        let b = FragmentPool.parse("{\"fragments\":[\(card(resolved: "null", category: "\"mood\""))]}", visible: 1...2)
        XCTAssertEqual(b?.fragments, [])
        XCTAssertEqual(b?.rejected, 1)
    }

    func testContentCharacterBoundariesWithoutTruncation() throws {
        for length in [121, 160, 200] {
            let content = String(repeating: "船", count: length)
            let batch = try XCTUnwrap(FragmentPool.parse("{\"fragments\":[\(card(content: content))]}", visible: 1...1))
            XCTAssertEqual(batch.fragments.map(\.content), [content])
            XCTAssertEqual(batch.rejected, 0)
        }
        let emoji = String(repeating: "👩🏽‍🚀", count: 200)
        XCTAssertEqual(FragmentPool.parse("{\"fragments\":[\(card(content: emoji))]}", visible: 1...1)?.fragments.first?.content, emoji)
        for content in [String(repeating: "船", count: 201), emoji + "船"] {
            let batch = try XCTUnwrap(FragmentPool.parse("{\"fragments\":[\(card(content: content))]}", visible: 1...1))
            XCTAssertEqual(batch.fragments, [])
            XCTAssertEqual(batch.rejected, 1)
        }
    }

    func testMissingAndMalformedCommonFieldsRejectedForBothTemplates() throws {
        let base = card()
        let fields = [
            "\"msg\":1,", "\"content\":\"粟粟周三要复诊\",", "\"tags\":[\"复诊\"],",
            "\"importance\":4,", "\"emotion\":-1,", "\"category\":\"context\","
        ]
        let missing = fields.map { base.replacingOccurrences(of: $0, with: "") }
        let malformed = [
            base.replacingOccurrences(of: "\"msg\":1", with: "\"msg\":\"1\""),
            base.replacingOccurrences(of: "\"content\":\"粟粟周三要复诊\"", with: "\"content\":null"),
            card(tags: "null"), card(tags: "\"复诊\""), card(tags: "[1]"),
            card(category: "null"), card(category: "\"invalid\""), card(category: "1"),
            card(importance: 0), card(importance: 6), card(emotion: -3), card(emotion: 3),
            card(content: "   ")
        ]
        for requireAttribution in [true, false] {
            for raw in missing + malformed {
                let batch = try XCTUnwrap(FragmentPool.parse("{\"fragments\":[\(raw)]}", visible: 1...1, requireAttribution: requireAttribution))
                XCTAssertEqual(batch.fragments, [], raw)
                XCTAssertEqual(batch.rejected, 1, raw)
            }
        }
        for category in FragmentPool.categories {
            XCTAssertEqual(FragmentPool.parse("{\"fragments\":[\(card(category: "\"\(category)\""))]}", visible: 1...1)?.fragments.first?.category, category)
        }
    }

    func testAttributionAbsentVersusInvalidAndAllProtocolSpeakers() throws {
        for raw in [card(subject: nil), card(speaker: nil), card(subject: nil, speaker: nil)] {
            XCTAssertEqual(FragmentPool.parse("{\"fragments\":[\(raw)]}", visible: 1...1)?.rejected, 1)
            let legacy = try XCTUnwrap(FragmentPool.parse("{\"fragments\":[\(raw)]}", visible: 1...1, requireAttribution: false))
            XCTAssertEqual(legacy.fragments.count, 1)
            XCTAssertEqual(legacy.rejected, 0)
        }
        for requireAttribution in [true, false] {
            for raw in [
                card(subject: "\"  \""), card(subject: "3"), card(subject: "null"), card(subject: "[]"),
                card(speaker: "\"  \""), card(speaker: "\"用户观察\""), card(speaker: "3"), card(speaker: "null")
            ] {
                let batch = try XCTUnwrap(FragmentPool.parse("{\"fragments\":[\(raw)]}", visible: 1...1, requireAttribution: requireAttribution))
                XCTAssertEqual(batch.fragments, [], raw)
                XCTAssertEqual(batch.rejected, 1)
            }
        }
        for speaker in ["用户自述", "AI 观察", "AI 承诺"] {
            let raw = card(subject: "\"  璃央  \"", speaker: "\"\(speaker)\"")
            let fragment = try XCTUnwrap(FragmentPool.parse("{\"fragments\":[\(raw)]}", visible: 1...1, requireAttribution: false)?.fragments.first)
            XCTAssertEqual(fragment.subject, "璃央")
            XCTAssertEqual(fragment.speaker, speaker)
        }
    }

    func testActualTemplateBranchControlsMissingAttributionAndIsFrozenDuringRewrite() async throws {
        let defaults = tempDefaults()
        let legacyCard = card(subject: nil, speaker: nil)
        let raw = "{\"fragments\":[\(legacyCard)]}"
        let custom = "保留的旧模板 {{USER_NAME}}"
        defaults.set(custom, forKey: FragmentPool.customPromptKey)
        var calls = 0
        let legacy = try await FragmentPool.run(msgs(1), names: names, defaults: defaults) { _, _ in calls += 1; return raw }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(legacy?.fragments.first?.subject)
        XCTAssertNil(legacy?.fragments.first?.speaker)
        XCTAssertEqual(defaults.string(forKey: FragmentPool.customPromptKey), custom)

        defaults.removeObject(forKey: FragmentPool.customPromptKey)
        calls = 0
        let current = try await FragmentPool.run(msgs(1), names: names, defaults: defaults) { _, _ in
            calls += 1
            defaults.set(custom, forKey: FragmentPool.customPromptKey)
            return raw
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(current?.fragments, [])
        XCTAssertEqual(current?.rejected, 1, "重写期间设置变化不能放松本次默认合同")

        defaults.set(custom, forKey: FragmentPool.customPromptKey)
        calls = 0
        let commonInvalid = try await FragmentPool.run(msgs(1), names: names, defaults: defaults) { _, _ in
            calls += 1
            return "{\"fragments\":[\(self.card(category: "\"invalid\"", subject: nil, speaker: nil))]}"
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(commonInvalid?.fragments, [])
        XCTAssertEqual(defaults.string(forKey: FragmentPool.customPromptKey), custom)
    }

    @MainActor
    func testMissingEmotionRewritesOnceAndNeverWrites() async throws {
        let switches = ["mem_master", "mem_content_facts"]
        let saved = switches.map { UserDefaults.standard.object(forKey: $0) }
        for key in switches { UserDefaults.standard.set(true, forKey: key) }
        defer {
            for (key, value) in zip(switches, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            MemoryWriteLog.flush()
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        }
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let missing = card().replacingOccurrences(of: "\"emotion\":-1,", with: "")
        var calls = 0
        var writes = 0
        let outcome = await FragmentPool.process(msgs(1), names: names, caller: { _, user in
            calls += 1
            if calls == 2 { XCTAssertTrue(user.contains("emotion")) }
            return "{\"fragments\":[\(missing)]}"
        }, local: false, profileId: pid, modelName: "synthetic-emotion", fallbackNote: nil) { fragments in
            writes += 1
            return try FragmentPool.write(fragments, messages: self.msgs(1), profileId: self.pid, conversationId: "missing-emotion",
                                          extractedBy: "synthetic-emotion", store: SwiftDataMemoryStore(), context: context)
        }
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Memory>()), 0)
    }

    func testDefaultRejectsAIObservationAndRewritesOnlyOnce() async throws {
        let raw = "{\"fragments\":[\(card(speaker: "\"AI 观察\""))]}"
        var calls = 0
        let batch = try await FragmentPool.run(msgs(1), names: names, defaults: tempDefaults()) { _, user in
            calls += 1
            if calls == 2 { XCTAssertTrue(user.contains("speaker")) }
            return raw
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(batch?.fragments, [])
        XCTAssertEqual(batch?.rejected, 1)
    }

    func testCustomTemplateAcceptsAllThreeSpeakersWithoutRewrite() async throws {
        let defaults = tempDefaults()
        defaults.set("旧自定义保留 {{USER_NAME}}", forKey: FragmentPool.customPromptKey)
        let speakers = ["用户自述", "AI 观察", "AI 承诺"]
        for speaker in speakers {
            var calls = 0
            let batch = try await FragmentPool.run(msgs(1), names: names, defaults: defaults) { _, _ in
                calls += 1
                return "{\"fragments\":[\(self.card(speaker: "\"\(speaker)\""))]}"
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(batch?.fragments.first?.speaker, speaker)
            XCTAssertEqual(batch?.rejected, 0)
        }
    }

    func testSubjectFortyCharacterBoundaryAndRewriteWithoutTruncation() async throws {
        for subject in [String(repeating: "槐", count: 40), String(repeating: "👩🏽‍🚀", count: 40)] {
            for requireAttribution in [true, false] {
                let accepted = try XCTUnwrap(FragmentPool.parse("{\"fragments\":[\(card(subject: "\"\(subject)\""))]}",
                                                               visible: 1...1, requireAttribution: requireAttribution))
                XCTAssertEqual(accepted.fragments.first?.subject, subject)
                let refused = try XCTUnwrap(FragmentPool.parse("{\"fragments\":[\(card(subject: "\"\(subject)槐\""))]}",
                                                              visible: 1...1, requireAttribution: requireAttribution))
                XCTAssertEqual(refused.fragments, [])
                XCTAssertEqual(refused.rejected, 1)
            }
            var calls = 0
            let batch = try await FragmentPool.run(msgs(1), names: names, defaults: tempDefaults()) { _, user in
                calls += 1
                if calls == 2 { XCTAssertTrue(user.contains("subject")) }
                return "{\"fragments\":[\(self.card(subject: "\"\(subject)槐\""))]}"
            }
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(batch?.fragments, [])
            XCTAssertEqual(batch?.rejected, 1, "超长 subject 不能被裁到 40 字收下")
        }
    }

    func testCopiedSymbolsAreIgnoredWithoutFuzzyMatching() async throws {
        for suffix in ["～", "~", "^", "🐈", "👩🏽‍🚀"] {
            let message = FragmentPool.Message(id: "symbol-source", role: "user", content: "璃央喜欢猫" + suffix, date: nil)
            let raw = "{\"fragments\":[\(card(content: "璃央喜欢猫", subject: "\"璃央\""))]}"
            var calls = 0
            let batch = try await FragmentPool.run([message], names: names, defaults: tempDefaults()) { _, user in
                calls += 1
                if calls == 2 { XCTAssertTrue(user.contains("content")) }
                return raw
            }
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(batch?.fragments, [])
            XCTAssertEqual(batch?.rejected, 1)
        }
        let near = card(content: "璃央长期喜欢猫", subject: "\"璃央\"")
        let messages = [FragmentPool.Message(id: "not-exact", role: "user", content: "璃央喜欢猫～", date: nil)]
        XCTAssertEqual(FragmentPool.parse("{\"fragments\":[\(near)]}", visible: 1...1, messages: messages)?.fragments.first?.content, "璃央长期喜欢猫")
    }

    func testStoredExactLegacyDefaultUsesCurrentContractButSingleEditRemainsCustom() async throws {
        // 独立保留 e62b23fa4 的历史输入，避免测试与生产常量一同改错仍自证通过。
        let legacy = """
这不是在跟你聊天。你是填表的工具：读下面这段对话，把里面的事实一条一条填进表里。
事实 = 过一个月还成立、还用得上的事：{{USER_NAME}}是谁、有什么、在做什么、喜欢 / 讨厌什么、身体和生活的状况、和{{CHAR_NAME}}之间定下的约定和关系变化。
大多数对话里没有新事实，交 {"fragments":[]} 是正常的。宁可漏，不要凑。

只输出一个 JSON 对象，不要别的字：{"fragments":[{"msg":3,"content":"……","tags":["……"],"importance":3,"emotion":0,"resolved":null,"category":"fact"}]}；没有就 {"fragments":[]}。
- msg：这件事出自第几条（方括号里的编号）。日期不用写。
- content：一件事一条，120 字以内，干的陈述句，主语写名字（{{USER_NAME}} / {{CHAR_NAME}}），不用「我」「你」，不写感受评价。
- tags：关键词，最多 5 个。
- importance：1 到 5，5 = 一直要记得。
- emotion：-2 到 2，这件事带的情绪，0 = 平常。
- resolved：事情了结了填 true，还悬着填 false，说不上填 null。
- category：preference / fact / relationship / goal / context 选一个。
  relationship 只放{{USER_NAME}}和{{CHAR_NAME}}之间定下的约定、关系变化；拿不准填 fact。
- valid_until：只有带明确日子的事才写（复诊、截止、约好的那天），写到那天为止，格式 YYYY-MM-DD；「明天」「下周三」这类相对日期按那条消息自己的日期（编号后面那个日子）换算成日子，没标日子的按这一截最后一天（{{DATE}}）。没有就不写这个字段。
亲密互动里{{USER_NAME}}说的自身喜好、身体感受、边界都是真事，要记；只有括号里的动作描写和架空设定才算演出来的剧情。

不记：
- 客套闲聊、在问不是在说的（比如「这个报错是啥意思」）、报错 / 网络 / 工具失败、演出来的剧情（跳出剧情说的真事照记）。
- 对话经过：谁说了什么、谁承认 / 解释 / 道歉、谁看不懂谁——这些是时间轴的事，不是事实。
- {{CHAR_NAME}}说的话、做的事（只有对{{USER_NAME}}的承诺例外）。
- 把一句话原样抄成一条：content 必须是你自己写的陈述句，不是某一条消息的复制。
- 正在进行的工作步骤（「在写 plan」「收到单子了」）；只记做成了 / 定下来的结果。

坏例子（这些都不该进表）：
- 「{{CHAR_NAME}}承认漏画了船帆」——对话经过
- 「{{USER_NAME}}：这艘模型船要装两面帆吗？」——把一句提问原样抄了
- 「{{CHAR_NAME}}：船帆已经加进去了」——{{CHAR_NAME}}自己的话
好例子：
- 「{{USER_NAME}}在制作灯塔航线模型船，10-15 定下双帆方案」
例子只示范写法，别把例子里的事填进表。
"""
        let defaults = tempDefaults()
        let missing = "{\"fragments\":[\(card(subject: nil, speaker: nil))]}"
        for stored in [legacy, " \n" + legacy + "\n "] {
            defaults.set(stored, forKey: FragmentPool.customPromptKey)
            var calls = 0
            let batch = try await FragmentPool.run(msgs(1), names: names, defaults: defaults) { _, _ in
                calls += 1
                return missing
            }
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(batch?.fragments, [])
            XCTAssertEqual(batch?.rejected, 1)
            XCTAssertEqual(defaults.string(forKey: FragmentPool.customPromptKey), stored, "识别旧默认不写回或覆盖存储")
        }
        let edited = "那" + legacy.dropFirst()
        defaults.set(edited, forKey: FragmentPool.customPromptKey)
        var calls = 0
        let custom = try await FragmentPool.run(msgs(1), names: names, defaults: defaults) { _, _ in calls += 1; return missing }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(custom?.fragments.count, 1)
        XCTAssertNil(custom?.fragments.first?.subject)
        XCTAssertNil(custom?.fragments.first?.speaker)
        XCTAssertEqual(defaults.string(forKey: FragmentPool.customPromptKey), edited)
    }

    func testVerbatimCopyRejectedAndRewrittenOnlyOnce() async throws {
        let messages = [FragmentPool.Message(id: "copy-source", role: "user", content: "璃央，长期只喝\n无糖的麦茶。", date: nil)]
        let copy = card(content: "璃央长期只喝无糖的麦茶！", subject: "\"璃央\"")
        let rewritten = card(content: "璃央的常用饮品是无糖麦茶。", subject: "\"璃央\"")
        var calls = 0
        let result = try await FragmentPool.run(messages, names: names) { _, user in
            calls += 1
            if calls == 2 { XCTAssertTrue(user.contains("content"), "反馈应定位被拒字段") }
            return "{\"fragments\":[\(calls == 1 ? copy : rewritten)]}"
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result?.fragments.map(\.content), ["璃央的常用饮品是无糖麦茶。"])

        calls = 0
        let badAgain = try await FragmentPool.run(messages, names: names) { _, _ in
            calls += 1
            return "{\"fragments\":[\(copy)]}"
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(badAgain?.fragments, [])
        XCTAssertEqual(badAgain?.rejected, 1)
        let nearCopy = card(content: "璃央长期只喝无糖的麦茶，并偏好温饮。", subject: "\"璃央\"")
        XCTAssertEqual(FragmentPool.parse("{\"fragments\":[\(nearCopy)]}", visible: 1...1, messages: messages)?.fragments.count, 1,
                       "本单不做近似照抄检测")
    }

    @MainActor
    func testFinalMixedRewriteIsTheOnlyBatchWrittenAndExactDuplicatesAddedOnce() async throws {
        let switches = ["mem_master", "mem_content_facts"]
        let saved = switches.map { UserDefaults.standard.object(forKey: $0) }
        for key in switches { UserDefaults.standard.set(true, forKey: key) }
        defer {
            for (key, value) in zip(switches, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            MemoryWriteLog.flush()
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        }
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let store = SwiftDataMemoryStore()
        let firstOnly = card(content: "璃央以前收藏过星帆棋。", subject: "\"璃央\"")
        let final = card(msg: 2, content: "烛墨承诺每月陪璃央整理星帆棋。", category: "\"relationship\"",
                         subject: "\"烛墨\"", speaker: "\"AI 承诺\"")
        var calls = 0
        var writes = 0
        let outcome = await FragmentPool.process(msgs(3), names: names, caller: { _, _ in
            calls += 1
            XCTAssertEqual(store.listAll(profileId: self.pid, context: ModelContext(container)).count, 0,
                           "两轮模型请求期间都不应落第一轮好卡")
            return calls == 1
                ? "{\"fragments\":[\(firstOnly),\(self.card(category: "\"invalid\""))]}"
                : "{\"fragments\":[\(final),\(final),\(self.card(subject: nil)),{\"msg\":1}]}"
        }, local: false, profileId: pid, modelName: "synthetic-c2", fallbackNote: nil) { fragments in
            writes += 1
            XCTAssertEqual(calls, 2)
            return try FragmentPool.write(fragments, messages: self.msgs(3), profileId: self.pid, conversationId: "c2-smoke",
                                          extractedBy: "synthetic-c2", store: store, context: context)
        }
        XCTAssertEqual(outcome, .done(added: 1))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(writes, 1)
        let stored = store.listAll(profileId: pid, context: ModelContext(container))
        let memory = try XCTUnwrap(stored.first)
        XCTAssertEqual(stored.map(\.content), ["烛墨承诺每月陪璃央整理星帆棋。"])
        XCTAssertEqual(memory.subject, "烛墨")
        XCTAssertEqual(memory.speaker, "AI 承诺")
        XCTAssertEqual(memory.sourceNodeId, "n1")
        XCTAssertEqual(memory.category, "relationship")
        print("[P2 C2 smoke] modelCalls=\(calls), writeBatches=\(writes), stored=\(stored.count), subject=\(memory.subject ?? "nil"), speaker=\(memory.speaker ?? "nil"), source=\(memory.sourceNodeId ?? "nil")")
    }

    @MainActor
    func testLivePromiseQuoteFeedbackAndAtomicPersistence() async throws {
        let fictionalNames = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let messages = [
            FragmentPool.Message(id: "quote-user", role: "user", content: "星砚，你会怎样执行‘纸灯暂停’这条长期约定？", date: nil),
            FragmentPool.Message(id: "quote-assistant", role: "assistant", content: "星砚向岚舟承诺：以后只要岚舟在对话里说‘纸灯暂停’，星砚就停止给建议，直到岚舟明确说‘恢复建议’才继续。这不是只对本轮有效，而是今后持续遵守的约定。", date: nil),
            FragmentPool.Message(id: "quote-acknowledgement", role: "user", content: "明白了。", date: nil)
        ]
        let brokenFirst = #"{"fragments":[{"msg":2,"content":"星砚承诺：岚舟在对话中说"纸灯暂停"时，星砚立即停止给建议，直到岚舟明确说"恢复建议"才继续；此约定长期有效，不限于单次对话。","tags":["纸灯暂停","约定","建议","长期"],"importance":5,"emotion":0,"resolved":false,"category":"relationship","subject":"星砚对岚舟的承诺——纸灯暂停约定","speaker":"AI 承诺"}]}"#
        let brokenSecond = #"{"fragments":[{"msg":2,"content":"星砚承诺：岚舟在对话中说"纸灯暂停"时，星砚立即停止给出建议，直到岚舟明确说"恢复建议"后才继续。此约定长期持续有效，不限于单次对话。","tags":["纸灯暂停","建议暂停","长期约定","关键词触发"],"importance":5,"emotion":0,"resolved":false,"category":"relationship","subject":"星砚对岚舟的约定","speaker":"AI 承诺"}]}"#
        let corrected = #"{"fragments":[{"msg":2,"content":"星砚承诺：岚舟在对话中说\"纸灯暂停\"时，星砚立即停止给建议，直到岚舟明确说\"恢复建议\"才继续；此约定长期有效，不限于单次对话。","tags":["纸灯暂停","约定","建议","长期"],"importance":5,"emotion":0,"resolved":false,"category":"relationship","subject":"星砚对岚舟的承诺——纸灯暂停约定","speaker":"AI 承诺"}]}"#
        let expectedContent = #"星砚承诺：岚舟在对话中说"纸灯暂停"时，星砚立即停止给建议，直到岚舟明确说"恢复建议"才继续；此约定长期有效，不限于单次对话。"#
        let quotePid = "xctest-fragment-quotes-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let switches = ["mem_master", "mem_content_facts"]
        let saved = switches.map { defaults.object(forKey: $0) }
        for key in switches { defaults.set(true, forKey: key) }
        defer {
            for (key, value) in zip(switches, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            for field in ["ok", "err", "errmsg", "streak", "model"] {
                defaults.removeObject(forKey: "mem_health_extract_\(field)_\(quotePid)")
            }
            MemoryWriteLog.flush()
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: quotePid).deletingLastPathComponent())
        }
        let fault = try XCTUnwrap(brokenFirst.range(of: "纸灯暂停")).lowerBound
        let expectedPosition = brokenFirst.distance(from: brokenFirst.startIndex, to: fault) + 1
        for repairs in [true, false] {
            let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let store = SwiftDataMemoryStore()
            let previous = MemoryHealthStore.status(.extract, profileId: quotePid)
            var requests: [String] = []
            var writes = 0
            let outcome = await FragmentPool.process(messages, names: fictionalNames, caller: { _, user in
                requests.append(user)
                XCTAssertEqual(store.listAll(profileId: quotePid, context: ModelContext(container)).count, 0,
                               "首轮和重写请求期间均不得提前存卡")
                return requests.count == 1 ? brokenFirst : (repairs ? corrected : brokenSecond)
            }, local: false, profileId: quotePid, modelName: "fictional-live-quotes", fallbackNote: nil) { fragments in
                writes += 1
                return try FragmentPool.write(fragments, messages: messages, profileId: quotePid, conversationId: "quote-smoke",
                                              extractedBy: "fictional-live-quotes", store: store, context: context)
            }
            XCTAssertEqual(requests.count, 2, "只允许一次重写")
            let retry = try XCTUnwrap(requests.last)
            let feedbackStart = try XCTUnwrap(retry.range(of: FragmentPool.retryNote)).upperBound
            let feedback = String(retry[feedbackStart...])
            XCTAssertTrue(feedback.contains("第 \(expectedPosition) 字符"), feedback)
            XCTAssertTrue(feedback.contains("纸灯暂停"), "反馈必须包含错误附近的原文：\(feedback)")
            XCTAssertTrue(feedback.contains(#"\""#), feedback)
            XCTAssertTrue(feedback.contains("「」"), feedback)
            let stored = store.listAll(profileId: quotePid, context: ModelContext(container))
            let status = MemoryHealthStore.status(.extract, profileId: quotePid)
            if repairs {
                XCTAssertEqual(outcome, .done(added: 1))
                XCTAssertEqual(writes, 1)
                XCTAssertEqual(stored.map(\.content), [expectedContent], "合法转义引号原样解码，不替换为中文引号")
                let memory = try XCTUnwrap(stored.first)
                XCTAssertEqual(memory.subject, "星砚对岚舟的承诺——纸灯暂停约定")
                XCTAssertEqual(memory.speaker, "AI 承诺")
                XCTAssertEqual(memory.sourceNodeId, "quote-assistant")
                XCTAssertEqual(memory.category, "relationship")
                XCTAssertEqual(status.failStreak, 0)
                XCTAssertNotNil(status.lastOK)
            } else {
                XCTAssertEqual(outcome, .rejected)
                XCTAssertTrue(outcome.settled)
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(stored.count, 0, "两轮非法均不得自动抢救或落库")
                XCTAssertEqual(status.failStreak, previous.failStreak + 1)
                XCTAssertEqual(status.lastOK, previous.lastOK)
                XCTAssertNotNil(status.lastError)
            }
            MemoryWriteLog.flush()
            let log = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: quotePid)).filter { $0.writer == "C2" && $0.ok == repairs }
            XCTAssertEqual(log.count, 1)
            XCTAssertTrue(log.first?.note.contains("JSON") == true)
            if !repairs { XCTAssertEqual(log.first?.rejected, 1) }
            print("[P2 fix3 quote smoke] repaired=\(repairs), calls=\(requests.count), writes=\(writes), stored=\(stored.count), outcome=\(outcome), failStreak=\(status.failStreak)")
            print("[P2 fix3 quote feedback] \(feedback)")
        }
    }

    func testOutboundDefaultQuoteGuidanceDoesNotChangeCustomTemplate() async throws {
        let defaults = tempDefaults()
        let fictionalNames = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        var sent: [String] = []
        _ = try await FragmentPool.run(msgs(1), names: fictionalNames, defaults: defaults) { system, _ in
            sent.append(system)
            return "{\"fragments\":[]}"
        }
        let system = try XCTUnwrap(sent.first)
        let rule = try XCTUnwrap(system.components(separatedBy: .newlines).first { line in
            ["content", "subject", "tags", "「」"].allSatisfy { line.contains($0) }
        })
        XCTAssertTrue(rule.contains("双引号"))
        XCTAssertTrue(rule.contains("不要") || rule.contains("不用"))
        let custom = "保持旧自定义 {{USER_NAME}} / {{CHAR_NAME}}"
        defaults.set(custom, forKey: FragmentPool.customPromptKey)
        _ = try await FragmentPool.run(msgs(1), names: fictionalNames, defaults: defaults) { system, _ in
            sent.append(system)
            return "{\"fragments\":[]}"
        }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last, "保持旧自定义 岚舟 / 星砚")
        XCTAssertEqual(defaults.string(forKey: FragmentPool.customPromptKey), custom)
    }

    func testRetryOnceThenRejectWhole() async throws {
        var calls = 0
        do {
            _ = try await FragmentPool.run(msgs(3), names: names) { _, _ in calls += 1; return "我记下了这些：……" }
            XCTFail("两次都不合格应该整包拒收")
        } catch MemoryWriterError.format {}
        XCTAssertEqual(calls, 2)

        calls = 0
        let ok = try await FragmentPool.run(msgs(3), names: names) { _, _ in
            calls += 1
            return calls == 2 ? "{\"fragments\":[\(self.card())]}" : "随便"
        }
        XCTAssertEqual(ok?.fragments.count, 1)
        XCTAssertEqual(calls, 2)

        let skipped = try await FragmentPool.run(msgs(3), names: names) { _, _ in nil }
        XCTAssertNil(skipped, "预算闸 / 空输出：不算失败")
    }

    // MARK: - 落库：只加；一字不差的不加；新字段

    @MainActor
    func testWriteOnlyAddsWithFields() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = SwiftDataMemoryStore()
        try store.add(content: "粟粟周三要复诊", category: "context", keywords: [], profileId: pid, isUserExplicit: false,
                      extractedBy: "old", sourceConversationId: nil, context: context)
        let batch = try XCTUnwrap(FragmentPool.parse("{\"fragments\":[\(card()),\(card(msg: 2, content: "粟粟喜欢暖奶白", emotion: 1, resolved: "null", category: "\"preference\""))]}",
                                                     visible: 1...3))
        let added = try FragmentPool.write(batch.fragments, messages: msgs(3), profileId: pid, conversationId: "conv-f",
                                           extractedBy: "本机 4B", store: store, context: context)
        XCTAssertEqual(added, 1, "一字不差的不加")
        let all = store.listAll(profileId: pid, context: context)
        XCTAssertEqual(all.count, 2)
        let new = try XCTUnwrap(all.first { $0.content == "粟粟喜欢暖奶白" })
        XCTAssertEqual(new.importance, 4)
        XCTAssertEqual(new.emotion, 1)
        XCTAssertNil(new.resolved)
        XCTAssertEqual(new.occurredDay, "2026-10-14")
        XCTAssertEqual(new.sourceNodeId, "n1", "msg 2 = 第二条")
        XCTAssertEqual(new.keywords, ["复诊"])
        XCTAssertEqual(new.category, "preference")
        XCTAssertNil(all.first { $0.content == "粟粟周三要复诊" }?.supersededAt, "旧的不改不删")
    }

    /// 审计台「来源」靠 isFragment（= occurredDay != nil）认 C2 写的：C2 写库每条都必须带 occurredDay（和 importance）；手加的都不带
    @MainActor
    func testWriteAlwaysCarriesImportance() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = SwiftDataMemoryStore()
        let manual = try store.add(content: "手加的一条", category: "fact", keywords: [], profileId: pid, isUserExplicit: true,
                                   extractedBy: "manual", sourceConversationId: nil, context: context)
        let raw = "{\"fragments\":[\(card(msg: 1, content: "甲", importance: 1)),\(card(msg: 2, content: "乙", importance: 5, category: "\"fact\"")),\(card(msg: 3, content: "丙", importance: 3, category: "\"relationship\""))]}"
        let batch = try XCTUnwrap(FragmentPool.parse(raw, visible: 1...3))
        let added = try FragmentPool.write(batch.fragments, messages: msgs(3), profileId: pid, conversationId: "conv-f",
                                           extractedBy: "m", store: store, context: context)
        XCTAssertEqual(added, 3)
        let written = store.listAll(profileId: pid, context: context).filter { $0.id != manual.id }
        XCTAssertEqual(written.count, 3)
        for m in written {
            XCTAssertNotNil(m.importance, "C2 写的每条都带 importance：\(m.content)")
            XCTAssertNotNil(m.occurredDay, "C2 写的每条都带 occurredDay（碎片池标记）：\(m.content)")
            XCTAssertTrue(m.isFragment)
        }
        XCTAssertEqual(Set(written.compactMap(\.importance)), [1, 3, 5])
        XCTAssertNil(manual.occurredDay)
        XCTAssertFalse(manual.isFragment, "手加的不算碎片池")
    }

    /// 审计台两个新字段：老条目 nil；备份文档两个方向都带上（老备份没这两个键 = nil）
    func testAuditFieldsBackupRoundTrip() throws {
        let m = Memory(content: "x", category: "fact", profileId: pid)
        XCTAssertNil(m.reviewedAt)
        XCTAssertNil(m.userEditedAt)
        let t1 = Date(timeIntervalSince1970: 1_800_000_000), t2 = Date(timeIntervalSince1970: 1_800_000_100)
        m.reviewedAt = t1
        m.userEditedAt = t2
        let doc = FullMemoryDocument(model: m)
        let back = doc.toModel()
        XCTAssertEqual(back.reviewedAt, t1)
        XCTAssertEqual(back.userEditedAt, t2)

        let data = try JSONEncoder().encode(FullMemoryDocument(model: Memory(content: "y", category: "fact", profileId: pid)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["reviewedAt"] = nil
        json["userEditedAt"] = nil
        let old = try JSONDecoder().decode(FullMemoryDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.reviewedAt, "老备份没这个键 = nil")
        XCTAssertNil(old.userEditedAt)
    }

    /// 备份导入时重要度夹到 1–5，没定的仍是 nil（10-17 astra #5）
    func testBackupImportClampsImportance() {
        let cases: [(Int?, Int?)] = [(nil, nil), (0, 1), (6, 5), (Int.min, 1), (Int.max, 5), (3, 3)]
        for (raw, want) in cases {
            let m = Memory(content: "x", category: "fact", profileId: pid)
            m.importance = raw
            XCTAssertEqual(FullMemoryDocument(model: m).toModel().importance, want, "\(String(describing: raw))")
        }
    }


    // MARK: - 窗口触发：每满 N 条（API / CC 共用，水位落盘）

    /// 前 n 条（c0…），每分钟一条
    private func ccPath(_ n: Int) -> (ids: [String], dates: [Date?]) {
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        return ((0..<n).map { "c\($0)" }, (0..<n).map { t.addingTimeInterval(TimeInterval($0 * 60)) })
    }

    /// 每个测试一份临时 UserDefaults 域，不碰 standard
    private func tempDefaults() -> UserDefaults {
        let suite = "xctest-fragment-watch-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    func testCCWatermark() async {
        let watch = FragmentWatch(defaults: tempDefaults())
        let p20 = ccPath(20), p25 = ccPath(25), p26 = ccPath(26)
        let first = await watch.due(conversationId: "cc", pathIds: p20.ids, dates: p20.dates, threshold: 6)
        XCTAssertNil(first, "第一次见：先记下位置，不回头补")
        let five = await watch.due(conversationId: "cc", pathIds: p25.ids, dates: p25.dates, threshold: 6)
        XCTAssertNil(five, "5 条不够")
        let six = await watch.due(conversationId: "cc", pathIds: p26.ids, dates: p26.dates, threshold: 6)
        XCTAssertEqual(six?.range, 20..<26)
        await watch.commit(conversationId: "cc", token: six!.token)
        let again = await watch.due(conversationId: "cc", pathIds: p26.ids, dates: p26.dates, threshold: 6)
        XCTAssertNil(again, "处理完了，水位线挪到最后了")
    }

    /// astra #3：没处理成（预算跳过 / 断网 / 被打断）水位不动，下次照样认领；正在跑时同一个窗口不再认领；
    /// 10-16 astra #1：一截最多 N 条，从水位之后顺序取（不取最后 N 条）
    func testCCWatermarkCommitsOnlyAfterSuccess() async {
        let watch = FragmentWatch(defaults: tempDefaults())
        let p20 = ccPath(20), p26 = ccPath(26), p27 = ccPath(27)
        _ = await watch.due(conversationId: "cc", pathIds: p20.ids, dates: p20.dates, threshold: 6)
        let claimed = await watch.due(conversationId: "cc", pathIds: p26.ids, dates: p26.dates, threshold: 6)
        XCTAssertEqual(claimed?.range, 20..<26)
        let busy = await watch.due(conversationId: "cc", pathIds: p27.ids, dates: p27.dates, threshold: 6)
        XCTAssertNil(busy, "这个窗口正在跑：不再认领")
        await watch.release(conversationId: "cc", token: claimed!.token)
        let retry = await watch.due(conversationId: "cc", pathIds: p27.ids, dates: p27.dates, threshold: 6)
        XCTAssertEqual(retry?.range, 20..<26, "没处理成：水位没动，照样从水位之后顺序认领")
        await watch.commit(conversationId: "cc", token: retry!.token)
        let done = await watch.due(conversationId: "cc", pathIds: p27.ids, dates: p27.dates, threshold: 6)
        XCTAssertNil(done, "水位到 c25，后面只剩 1 条")
    }

    /// 10-16 astra #1：积压 25 条、N=20，第一次失败放回后又来 2 条——重试还是从水位之后的前 20 条，
    /// 水位只推到这一批末尾，剩下的分批接着认领；没有一条被跳过
    func testBacklogClaimedInOrderNoSkip() async {
        let watch = FragmentWatch(defaults: tempDefaults())
        let p5 = ccPath(5), p30 = ccPath(30), p32 = ccPath(32), p45 = ccPath(45)
        _ = await watch.due(conversationId: "b", pathIds: p5.ids, dates: p5.dates, threshold: 20)   // 水位 c4
        var covered: [Range<Int>] = []

        let first = await watch.due(conversationId: "b", pathIds: p30.ids, dates: p30.dates, threshold: 20)
        XCTAssertEqual(first?.range, 5..<25, "积压 25 条：先认领水位之后的前 20 条")
        await watch.finish(conversationId: "b", claim: first!, outcome: .failed)

        let retry = await watch.due(conversationId: "b", pathIds: p32.ids, dates: p32.dates, threshold: 20)
        XCTAssertEqual(retry?.range, 5..<25, "放回后又来 2 条：还是从 c5 起，不滑到最后 20 条")
        await watch.finish(conversationId: "b", claim: retry!, outcome: .done(added: 1))
        covered.append(retry!.range)

        let rest = await watch.due(conversationId: "b", pathIds: p32.ids, dates: p32.dates, threshold: 20)
        XCTAssertNil(rest, "水位只推到 c24：剩 7 条，不够 20")
        let next = await watch.due(conversationId: "b", pathIds: p45.ids, dates: p45.dates, threshold: 20)
        XCTAssertEqual(next?.range, 25..<45, "接着从 c25 认领")
        await watch.finish(conversationId: "b", claim: next!, outcome: .done(added: 0))
        covered.append(next!.range)

        XCTAssertEqual(covered.map(\.lowerBound), [5, 25])
        XCTAssertEqual(covered[0].upperBound, covered[1].lowerBound, "前后两批首尾相接：没有消息被跳过")
        let after = await watch.due(conversationId: "b", pathIds: p45.ids, dates: p45.dates, threshold: 20)
        XCTAssertNil(after)
    }

    /// 积压超过两批：一次触发只认领一批，每次触发往后挪一批
    func testBacklogDrainsOneBatchPerTrigger() async {
        let watch = FragmentWatch(defaults: tempDefaults())
        let p2 = ccPath(2), p40 = ccPath(40)
        _ = await watch.due(conversationId: "d", pathIds: p2.ids, dates: p2.dates, threshold: 6)   // 水位 c1
        var ranges: [Range<Int>] = []
        while let c = await watch.due(conversationId: "d", pathIds: p40.ids, dates: p40.dates, threshold: 6) {
            ranges.append(c.range)
            await watch.finish(conversationId: "d", claim: c, outcome: .done(added: 0))
        }
        XCTAssertEqual(ranges, [2..<8, 8..<14, 14..<20, 20..<26, 26..<32, 32..<38], "剩 2 条（c38、c39）等下一批")
    }

    /// 10-16 astra #2：只有写成 / 合法空包 / 整包拒收才提交；跳过 / 网络或存储失败放回
    func testFinishCommitsOnlySettledOutcomes() async {
        XCTAssertTrue(FragmentPool.Outcome.done(added: 0).settled, "合法空包")
        XCTAssertTrue(FragmentPool.Outcome.rejected.settled, "两次都不合格，整包拒收")
        XCTAssertFalse(FragmentPool.Outcome.failed.settled, "网络 / 存储失败")
        XCTAssertFalse(FragmentPool.Outcome.skipped.settled)
        let watch = FragmentWatch(defaults: tempDefaults())
        let p2 = ccPath(2), p8 = ccPath(8)
        _ = await watch.due(conversationId: "f", pathIds: p2.ids, dates: p2.dates, threshold: 6)
        let a = await watch.due(conversationId: "f", pathIds: p8.ids, dates: p8.dates, threshold: 6)
        await watch.finish(conversationId: "f", claim: a!, outcome: .failed)
        let b = await watch.due(conversationId: "f", pathIds: p8.ids, dates: p8.dates, threshold: 6)
        XCTAssertEqual(b?.range, 2..<8, "失败：放回，照样认领")
        await watch.finish(conversationId: "f", claim: b!, outcome: .rejected)
        let c = await watch.due(conversationId: "f", pathIds: p8.ids, dates: p8.dates, threshold: 6)
        XCTAssertNil(c, "整包拒收：提交，不再重试")
    }

    /// 10-16 astra #3：认领超时被新任务接手后，旧任务的 token 提交 / 放回 / 写库前检查都无效
    func testStaleTokenCannotCommitOrRelease() async {
        let watch = FragmentWatch(defaults: tempDefaults())
        let p2 = ccPath(2), p8 = ccPath(8), p14 = ccPath(14)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await watch.due(conversationId: "s", pathIds: p2.ids, dates: p2.dates, threshold: 6, now: t0)
        let a = await watch.due(conversationId: "s", pathIds: p8.ids, dates: p8.dates, threshold: 6, now: t0)
        let t1 = t0.addingTimeInterval(FragmentWatch.claimTimeout + 1)
        var holdsA = await watch.holds(conversationId: "s", token: a!.token, now: t1)
        XCTAssertFalse(holdsA, "超时：A 作废，写库前检查不过")
        let b = await watch.due(conversationId: "s", pathIds: p8.ids, dates: p8.dates, threshold: 6, now: t1)
        XCTAssertEqual(b?.range, 2..<8, "超时后 B 接手同一截")
        XCTAssertNotEqual(a?.token, b?.token)

        await watch.release(conversationId: "s", token: a!.token)
        let third = await watch.due(conversationId: "s", pathIds: p8.ids, dates: p8.dates, threshold: 6, now: t1)
        XCTAssertNil(third, "A 的 release 清不掉 B 的认领")
        await watch.commit(conversationId: "s", token: a!.token, now: t1)
        holdsA = await watch.holds(conversationId: "s", token: a!.token, now: t1)
        XCTAssertFalse(holdsA)
        let holdsB = await watch.holds(conversationId: "s", token: b!.token, now: t1)
        XCTAssertTrue(holdsB, "A 的 commit 无效，B 还认领着")

        await watch.release(conversationId: "s", token: b!.token)
        let again = await watch.due(conversationId: "s", pathIds: p14.ids, dates: p14.dates, threshold: 6, now: t1)
        XCTAssertEqual(again?.range, 2..<8, "A 的 commit 没推水位")

        // 没人接手、自己超时了再 commit：只清认领，水位不动
        let t2 = t1.addingTimeInterval(FragmentWatch.claimTimeout + 1)
        await watch.commit(conversationId: "s", token: again!.token, now: t2)
        let still = await watch.due(conversationId: "s", pathIds: p14.ids, dates: p14.dates, threshold: 6, now: t2)
        XCTAssertEqual(still?.range, 2..<8, "超时的 commit 不推水位")
    }

    /// astra #4：晚到的旧快照（找不到水位、又比水位旧）不倒退、不重复提取；真切了分支（比水位新）只看最后 N 条
    func testCCStaleSnapshotDoesNotRewind() async {
        let watch = FragmentWatch(defaults: tempDefaults())
        let p10 = ccPath(10), p16 = ccPath(16), p8 = ccPath(8)
        _ = await watch.due(conversationId: "cc", pathIds: p10.ids, dates: p10.dates, threshold: 6)
        let c16 = await watch.due(conversationId: "cc", pathIds: p16.ids, dates: p16.dates, threshold: 6)
        await watch.commit(conversationId: "cc", token: c16!.token)   // 水位 c15
        let stale = await watch.due(conversationId: "cc", pathIds: p8.ids, dates: p8.dates, threshold: 6)
        XCTAssertNil(stale, "旧快照：不动")
        let later = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!
        let branch = (0..<9).map { "b\($0)" }
        let branchDates: [Date?] = (0..<9).map { later.addingTimeInterval(TimeInterval($0 * 60)) }
        let switched = await watch.due(conversationId: "cc", pathIds: branch, dates: branchDates, threshold: 6)
        XCTAssertEqual(switched?.range, 3..<9, "切了分支：只看最后 6 条")
        await watch.commit(conversationId: "cc", token: switched!.token)
        let p17 = ccPath(17)
        let old = await watch.due(conversationId: "cc", pathIds: p17.ids, dates: p17.dates, threshold: 6)
        XCTAssertNil(old, "水位已经在新分支上：旧路径更旧，不倒退")
    }

    /// 门槛 / 一截 / 切分支都按设置 `mem_c2_every`（没写过 = 20；越界夹到 6…40）
    func testThresholdFollowsSetting() async {
        let d = tempDefaults()
        XCTAssertEqual(FragmentWatch.every(d), 20, "没写过 = 默认 20")
        d.set(3, forKey: FragmentWatch.everyKey)
        XCTAssertEqual(FragmentWatch.every(d), 6)
        d.set(99, forKey: FragmentWatch.everyKey)
        XCTAssertEqual(FragmentWatch.every(d), 40)
        d.removeObject(forKey: FragmentWatch.everyKey)

        let watch = FragmentWatch(defaults: d)
        let p5 = ccPath(5), p24 = ccPath(24), p25 = ccPath(25), p40 = ccPath(40)
        _ = await watch.due(conversationId: "w", pathIds: p5.ids, dates: p5.dates)
        let nineteen = await watch.due(conversationId: "w", pathIds: p24.ids, dates: p24.dates)
        XCTAssertNil(nineteen, "默认 20：19 条不够")
        let twenty = await watch.due(conversationId: "w", pathIds: p25.ids, dates: p25.dates)
        XCTAssertEqual(twenty?.range, 5..<25)
        await watch.release(conversationId: "w", token: twenty!.token)
        let more = await watch.due(conversationId: "w", pathIds: p40.ids, dates: p40.dates)
        XCTAssertEqual(more?.range, 5..<25, "攒了 35 条：一截最多 20，从水位之后顺序取")
        await watch.commit(conversationId: "w", token: more!.token)

        d.set(10, forKey: FragmentWatch.everyKey)
        let later = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!
        let branch = (0..<15).map { "b\($0)" }
        let branchDates: [Date?] = (0..<15).map { later.addingTimeInterval(TimeInterval($0 * 60)) }
        let switched = await watch.due(conversationId: "w", pathIds: branch, dates: branchDates)
        XCTAssertEqual(switched?.range, 5..<15, "改成 10：切了分支只看最后 10 条")
    }

    /// 水位落盘：新实例（重开 app）读得回来，不再当「第一次见」；认领不落盘（重开后不算正在跑）
    func testWatermarkPersistsAcrossInstances() async {
        let d = tempDefaults()
        let p10 = ccPath(10), p16 = ccPath(16), p30 = ccPath(30)
        let a = FragmentWatch(defaults: d)
        _ = await a.due(conversationId: "w", pathIds: p10.ids, dates: p10.dates, threshold: 6)
        let claimed = await a.due(conversationId: "w", pathIds: p16.ids, dates: p16.dates, threshold: 6)
        XCTAssertEqual(claimed?.range, 10..<16)

        let b = FragmentWatch(defaults: d)
        let reopened = await b.due(conversationId: "w", pathIds: p16.ids, dates: p16.dates, threshold: 6)
        XCTAssertEqual(reopened?.range, 10..<16, "上一个实例认领了没提交就没了：水位还在 c9，新实例照样认领")
        await b.commit(conversationId: "w", token: reopened!.token)

        let c = FragmentWatch(defaults: d)
        let none = await c.due(conversationId: "w", pathIds: p16.ids, dates: p16.dates, threshold: 6)
        XCTAssertNil(none, "提交过的水位读回来了：没有新消息")
        let next = await c.due(conversationId: "w", pathIds: p30.ids, dates: p30.dates, threshold: 6)
        XCTAssertEqual(next?.range, 16..<22, "从 c15 往后顺序数，一截最多 6 条")
    }

    /// 最多记 300 个窗口：超了扔最久没动的，被扔的下次当第一次见
    func testMarksCappedAt300DropOldest() async {
        let d = tempDefaults()
        let watch = FragmentWatch(defaults: d)
        let p = ccPath(3)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0...FragmentWatch.maxMarks {
            _ = await watch.due(conversationId: "w\(i)", pathIds: p.ids, dates: p.dates, now: t0.addingTimeInterval(TimeInterval(i)))
        }
        let stored = d.dictionary(forKey: FragmentWatch.marksKey) ?? [:]
        XCTAssertEqual(stored.count, FragmentWatch.maxMarks)
        XCTAssertNil(stored["w0"], "最旧的那个扔了")
        XCTAssertNotNil(stored["w1"])
        XCTAssertNotNil(stored["w\(FragmentWatch.maxMarks)"])

        let reopened = FragmentWatch(defaults: d)
        let p9 = ccPath(9)
        let w0 = await reopened.due(conversationId: "w0", pathIds: p9.ids, dates: p9.dates, threshold: 6)
        XCTAssertNil(w0, "被扔的：当第一次见，只记位置")
        let w1 = await reopened.due(conversationId: "w1", pathIds: p9.ids, dates: p9.dates, threshold: 6)
        XCTAssertEqual(w1?.range, 3..<9, "留着的：水位在 c2，接着数")
    }

    /// 10-16 astra #5：C2 写库字段全赋好后只存一次——存完从另一个 context 读回来，每条都带 importance
    @MainActor
    func testWriteSavesOnceWithImportance() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let raw = "{\"fragments\":[\(card(msg: 1, content: "甲", importance: 2)),\(card(msg: 2, content: "乙", importance: 5))]}"
        let batch = try XCTUnwrap(FragmentPool.parse(raw, visible: 1...3))
        let added = try FragmentPool.write(batch.fragments, messages: msgs(3), profileId: pid, conversationId: "conv-f",
                                           extractedBy: "m", store: SwiftDataMemoryStore(), context: context)
        XCTAssertEqual(added, 2)
        XCTAssertFalse(context.hasChanges, "write 里已经存过")
        let other = ModelContext(container)
        let stored = SwiftDataMemoryStore().listAll(profileId: pid, context: other)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(Set(stored.compactMap(\.importance)), [2, 5], "落盘的每条都带 importance")
        XCTAssertTrue(stored.allSatisfy { $0.emotion != nil && $0.occurredDay != nil })

        let unsaved = SwiftDataMemoryStore().insertUnsaved(content: "丙", category: "fact", keywords: [], profileId: pid, isUserExplicit: false,
                                                            extractedBy: "m", sourceConversationId: nil, sourceQuote: nil, sourceNodeId: nil,
                                                            context: context)
        XCTAssertTrue(context.hasChanges, "insertUnsaved 只插入不存")
        XCTAssertEqual(SwiftDataMemoryStore().listAll(profileId: pid, context: ModelContext(container)).count, 2)
        context.delete(unsaved)
    }

    // MARK: - valid_until（规格 4⅞-3：带明确日子的事到哪天）

    private func dated(_ card: String, _ value: String) -> String {
        String(card.dropLast()) + ",\"valid_until\":\(value)}"
    }

    func testCustomTemplatePreservedAndMacrosExpanded() {
        let defaults = tempDefaults()
        let custom = "{{USER_NAME}} / {{CHAR_NAME}} / {{DATE}}"
        defaults.set(custom, forKey: FragmentPool.customPromptKey)
        XCTAssertEqual(FragmentPool.systemPrompt(names: names, defaults: defaults, day: "2026-10-14"), "粟粟 / 小克 / 2026-10-14")
        XCTAssertEqual(defaults.string(forKey: FragmentPool.customPromptKey), custom)
    }

    /// astra 10-16 #10：一批跨天时「明天复诊」按来源那条消息的日子算（记忆日 05:00 分界）
    func testCrossDayBatchDatesEachMessage() async throws {
        func at(_ day: Int, _ hour: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let msgs = [
            FragmentPool.Message(id: "a", role: "user", content: "明天复诊", date: at(18, 21)),
            FragmentPool.Message(id: "b", role: "user", content: "还没睡", date: at(20, 3)),
            FragmentPool.Message(id: "c", role: "assistant", content: "早点睡", date: at(20, 9)),
        ]
        var sent: (system: String, user: String)?
        _ = try await FragmentPool.run(msgs, names: names) { system, user in
            sent = (system, user)
            return "{\"fragments\":[]}"
        }
        let got = try XCTUnwrap(sent)
        XCTAssertTrue(got.user.contains("[1] 2026-10-18 · 粟粟：明天复诊"), "来源那条自己的日子")
        XCTAssertTrue(got.user.contains("[2] 2026-10-19 · 粟粟：还没睡"), "05:00 前算前一天")
        XCTAssertTrue(got.user.contains("[3] 2026-10-20 · 小克：早点睡"))
        let probe = tempDefaults()
        probe.set("{{DATE}}", forKey: FragmentPool.customPromptKey)
        var expandedDay: String?
        _ = try await FragmentPool.run(msgs, names: names, defaults: probe) { system, _ in
            expandedDay = system
            return "{\"fragments\":[]}"
        }
        XCTAssertEqual(expandedDay, "2026-10-20", "DATE 必须使用本批最后一条消息的记忆日")
    }

    func testValidUntilParsedLenientlyPerField() {
        let raw = "{\"fragments\":[" + [
            dated(card(), "\"2026-10-22\""),
            dated(card(msg: 2, content: "坏日子"), "\"2026-02-30\""),
            dated(card(msg: 3, content: "数字"), "20261022"),
            card(content: "没写"),
            dated(card(content: "空的"), "null"),
        ].joined(separator: ",") + "]}"

        let b = FragmentPool.parse(raw, visible: 1...3)

        XCTAssertEqual(b?.fragments.count, 5, "日子坏了只丢这个字段，不拒整张卡")
        XCTAssertEqual(b?.rejected, 0)
        XCTAssertEqual(b?.fragments.map { $0.validUntil?.value }, ["2026-10-22", nil, nil, nil, nil])
        XCTAssertNil(FragmentPool.validDay("2026-1-5"))
        XCTAssertNil(FragmentPool.validDay("10/22"))
        XCTAssertEqual(FragmentPool.validDay(" 2026-12-31 "), "2026-12-31")
    }

    @MainActor
    func testValidUntilWrittenAsEndOfThatMemoryDay() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let raw = "{\"fragments\":[" + dated(card(), "\"2026-10-22\"") + "," + card(msg: 2, content: "喜欢暖奶白") + "]}"
        let batch = try XCTUnwrap(FragmentPool.parse(raw, visible: 1...3))
        _ = try FragmentPool.write(batch.fragments, messages: msgs(3), profileId: pid, conversationId: "conv-v",
                                   extractedBy: "m", store: SwiftDataMemoryStore(), context: context)
        let all = SwiftDataMemoryStore().listAll(profileId: pid, context: ModelContext(container))
        let dated = try XCTUnwrap(all.first { $0.content == "粟粟周三要复诊" })
        XCTAssertEqual(dated.validUntil, Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 5)),
                       "到那天为止 = 次日 05:00")
        XCTAssertNil(all.first { $0.content == "喜欢暖奶白" }?.validUntil)
    }
}
