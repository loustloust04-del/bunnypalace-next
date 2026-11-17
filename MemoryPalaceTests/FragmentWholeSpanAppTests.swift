import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// C2 整段写手在 app 这一半（plan-c2-whole-span-writer）：认领整截、什么时候走老写法、前文、已记的卡、落库字段、process 分流。全虚构
final class FragmentWholeSpanAppTests: XCTestCase {
    private let pid = "xctest-fragment-whole"
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")

    private func tempDefaults() -> UserDefaults {
        let suite = "xctest-fragment-whole-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    private func path(_ n: Int) -> (ids: [String], dates: [Date?]) {
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        return ((0..<n).map { "c\($0)" }, (0..<n).map { t.addingTimeInterval(TimeInterval($0 * 60)) })
    }

    func testClaimTakesEverythingAfterWatermarkUpToCharBudget() async {
        let watch = FragmentWatch(defaults: tempDefaults())
        let p10 = path(10), p30 = path(30)
        let first = await watch.due(conversationId: "w", pathIds: p10.ids, dates: p10.dates, threshold: 6, sizes: Array(repeating: 100, count: 10))
        XCTAssertNil(first, "第一次见：先记下位置")
        let all = await watch.due(conversationId: "w", pathIds: p30.ids, dates: p30.dates, threshold: 6, sizes: Array(repeating: 100, count: 30))
        XCTAssertEqual(all?.range, 10..<30, "够字数就认领水位之后全部，不止前 6 条")
        await watch.release(conversationId: "w", token: all!.token)
        let capped = await watch.due(conversationId: "w", pathIds: p30.ids, dates: p30.dates, threshold: 6,
                                     sizes: Array(repeating: 100, count: 30), maxChars: 900)
        XCTAssertEqual(capped?.range, 10..<19, "到字数上限为止")
        await watch.release(conversationId: "w", token: capped!.token)
        let floor = await watch.due(conversationId: "w", pathIds: p30.ids, dates: p30.dates, threshold: 6,
                                    sizes: Array(repeating: 1000, count: 30), maxChars: 900)
        XCTAssertEqual(floor?.range, 10..<16, "上限再小也至少给够 N 条")
        await watch.commit(conversationId: "w", token: floor!.token)
        let rest = await watch.due(conversationId: "w", pathIds: p30.ids, dates: p30.dates, threshold: 6, sizes: Array(repeating: 100, count: 30))
        XCTAssertEqual(rest?.range, 16..<30, "水位只推进到认领的末尾，剩下的下一轮")
        await watch.release(conversationId: "w", token: rest!.token)
        let classic = await watch.due(conversationId: "w", pathIds: p30.ids, dates: p30.dates, threshold: 6)
        XCTAssertEqual(classic?.range, 16..<22, "不给 sizes = 老的认领：前 N 条")
    }

    func testShortTailIsWrittenOnceTheWindowIsPutDown() async {
        let defaults = tempDefaults()
        let watch = FragmentWatch(defaults: defaults)
        let p2 = path(2), p9 = path(9), p14 = path(14)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await watch.due(conversationId: "w", pathIds: p2.ids, dates: p2.dates, threshold: 200, sizes: Array(repeating: 100, count: 2), now: t)
        _ = await watch.due(conversationId: "w", pathIds: p9.ids, dates: p9.dates, threshold: 200, sizes: Array(repeating: 100, count: 9), now: t)
        var tails = await watch.tails(idle: 0, now: t)
        XCTAssertEqual(tails, [], "攒了 7 条，不到 10 条不写")
        _ = await watch.due(conversationId: "w", pathIds: p14.ids, dates: p14.dates, threshold: 200, sizes: Array(repeating: 100, count: 14), now: t)
        tails = await watch.tails(idle: 3600, now: t.addingTimeInterval(60))
        XCTAssertEqual(tails, [], "攒了 12 条但还在聊，不写")
        tails = await watch.tails(idle: 0, except: ["w"], now: t)
        XCTAssertEqual(tails, [], "正开着的那个窗口不算")
        tails = await FragmentWatch(defaults: defaults).tails(idle: 3600, now: t.addingTimeInterval(7200))
        XCTAssertEqual(tails, ["w"], "放下够久了就该写；重启 app 也还记得")
        let claim = await watch.due(conversationId: "w", pathIds: p14.ids, dates: p14.dates, threshold: FragmentWatch.wholeTailMinimum,
                                    sizes: Array(repeating: 100, count: 14), now: t.addingTimeInterval(7200))
        XCTAssertEqual(claim?.range, 2..<14, "尾巴整截认领")
        await watch.commit(conversationId: "w", token: claim!.token, now: t.addingTimeInterval(7200))
        tails = await watch.tails(idle: 0, now: t.addingTimeInterval(9000))
        XCTAssertEqual(tails, [], "写过了就不再算")
    }

    func testWhenTheOldWriterStillRuns() {
        let d = tempDefaults()
        XCTAssertTrue(FragmentWatch.usesWhole(local: false, defaults: d))
        XCTAssertFalse(FragmentWatch.usesWhole(local: true, defaults: d), "本机模型装不下整截")
        // 存没存自定义提示词都不换写法（粟粟 11-13）：旧 key 里的老格式模板、新 key 里她改的整段提示词，都还是整段写手
        d.set("我自己改的老格式模板 {{USER_NAME}}", forKey: FragmentPool.customPromptKey)
        XCTAssertTrue(FragmentWatch.usesWhole(local: false, defaults: d), "旧 key 有值不影响整段写手")
        XCTAssertNil(FragmentPool.activeWholeTemplate(defaults: d), "整段写手不读旧 key")
        XCTAssertFalse(FragmentWatch.usesWhole(local: true, defaults: d), "本机模型还是老写手，它读的还是旧 key 那份")
        XCTAssertEqual(FragmentPool.systemPrompt(names: .init(userName: "岚舟", assistantName: "星砚"), defaults: d), "我自己改的老格式模板 岚舟")
        d.set(FragmentPool.wholeTemplate + "\n多一句。", forKey: FragmentPool.customWholePromptKey)
        XCTAssertTrue(FragmentWatch.usesWhole(local: false, defaults: d), "存了自定义整段提示词还是整段写手")
        d.removeObject(forKey: FragmentPool.customPromptKey)
        d.removeObject(forKey: FragmentPool.customWholePromptKey)
        d.set("classic", forKey: FragmentWatch.writerKey)
        XCTAssertFalse(FragmentWatch.usesWhole(local: false, defaults: d))
        XCTAssertEqual(FragmentWatch.wholeEvery(d), 200)
        d.set(9999, forKey: FragmentWatch.wholeEveryKey)
        XCTAssertEqual(FragmentWatch.wholeEvery(d), 400)
    }

    /// app 里真跑的那条路（`process`）：她存了自定义整段提示词，发给模型的 system 就是她那份（占位符换好），照样写一次、核对一次
    func testProcessSendsHerWholeTemplateAndStillVerifies() async throws {
        let d = tempDefaults()
        let mine = FragmentPool.wholeTemplate.replacingOccurrences(of: "宁可少写不要写废条目。", with: "宁可少写不要写废条目。{{USER_NAME}} 的口头禅不用记。")
        XCTAssertNotEqual(mine, FragmentPool.wholeTemplate)
        d.set(mine, forKey: FragmentPool.customWholePromptKey)
        d.set("老格式模板，整段写手不该读到", forKey: FragmentPool.customPromptKey)
        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let messages = (0..<3).map { FragmentPool.Message(id: "n\($0)", role: "user", content: "第 \($0) 句", date: t) }
        let seen = Systems()
        let outcome = await FragmentPool.process(messages, names: names, caller: { system, _ in
            await seen.add(system)
            return #"[{"subject":"岚舟","type":"fact","origin":"said","content":"只用水性颜料。","msgs":[1]}]"#
        }, local: false, profileId: pid, modelName: "测试模型", fallbackNote: nil,
           whole: .init(windowTitle: "模型船", before: [], known: []), defaults: d) { $0.count }
        XCTAssertEqual(outcome, .done(added: 1))
        let systems = await seen.all
        XCTAssertEqual(systems.count, 2, "写一次、核对一次")
        let days = FragmentPool.wholeDays(messages)
        XCTAssertEqual(Set(systems), [FragmentPool.wholeRendered(mine, names: names, windowTitle: "模型船", from: days.from, to: days.to)])
        XCTAssertTrue(systems[0].contains("岚舟 的口头禅不用记。") && !systems[0].contains("老格式模板"))
        // 没存 = 默认那份
        d.removeObject(forKey: FragmentPool.customWholePromptKey)
        let plain = Systems()
        _ = await FragmentPool.process(messages, names: names, caller: { system, _ in await plain.add(system); return "[]" },
                                       local: false, profileId: pid, modelName: "测试模型", fallbackNote: nil,
                                       whole: .init(windowTitle: "模型船", before: [], known: []), defaults: d) { $0.count }
        let defaultSystems = await plain.all
        XCTAssertEqual(defaultSystems, [FragmentPool.wholeSystem(names: names, windowTitle: "模型船", from: days.from, to: days.to)])
    }

    private actor Systems {
        var all: [String] = []
        func add(_ system: String) { all.append(system) }
    }

    func testBeforeWalksBackUntilCharBudget() {
        let rows = ["甲甲甲", "乙乙乙", "丙丙丙", "丁丁丁"]
        XCTAssertEqual(Array(FragmentWatch.before(rows, upTo: 3, size: \.count, maxChars: 6)), ["乙乙乙", "丙丙丙"])
        XCTAssertEqual(Array(FragmentWatch.before(rows, upTo: 3, size: \.count, maxChars: 100)), ["甲甲甲", "乙乙乙", "丙丙丙"])
        XCTAssertTrue(FragmentWatch.before(rows, upTo: 0, size: \.count).isEmpty)
        XCTAssertTrue(FragmentWatch.before(rows, upTo: 2, size: \.count, maxChars: 2).isEmpty)
    }

    @MainActor
    func testWriteKeepsSinceTagsAndKnownCardsAreThisWindowOnly() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = SwiftDataMemoryStore()
        try store.add(content: "别的窗口的一条", category: "fact", keywords: [], profileId: pid, isUserExplicit: false,
                      extractedBy: "old", sourceConversationId: "other", context: context)
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let messages = (0..<3).map { FragmentPool.Message(id: "n\($0)", role: "user", content: "第 \($0) 句", date: t) }
        let batch = try FragmentPool.decodedWhole("""
        [{"subject":"岚舟","type":"fact","origin":"said","volatile":false,"tags":["偏好","会变","做法"],"content":"只用水性颜料。","msgs":[2],"since":"2026-09-30"},
         {"subject":"星砚","type":"instruction","origin":"assistant","volatile":true,"tags":["创作"],"content":"上色时别催她。","msgs":[3]}]
        """, messageCount: 3)
        let added = try FragmentPool.write(batch.fragments, messages: messages, profileId: pid, conversationId: "conv-w",
                                           extractedBy: "测试模型", store: store, context: context)
        XCTAssertEqual(added, 2)
        let all = store.listAll(profileId: pid, context: context)
        let fact = try XCTUnwrap(all.first { $0.content == "只用水性颜料。" })
        XCTAssertEqual(fact.occurredDay, "2026-09-30", "她说的起始日子优先")
        XCTAssertEqual([fact.subject, fact.speaker, fact.category, fact.sourceNodeId], ["岚舟", "用户自述", "fact", "n1"])
        XCTAssertNil(fact.reviewedAt, "存成没审过的")
        XCTAssertEqual(fact.keywords, ["偏好"], "模型给的 tags 收进标签；它自己写的「会变」「做法」不算")
        let way = try XCTUnwrap(all.first { $0.content == "上色时别催她。" })
        XCTAssertEqual(way.occurredDay, "2026-10-14", "没给起始日子就用出处那条的")
        XCTAssertEqual([way.category, way.speaker], ["preference", "AI 观察"])
        XCTAssertEqual(way.keywords, ["做法", "会变", "创作"], "「做法」「会变」只由 type / volatile 决定")
        let known = FragmentPool.knownCards(profileId: pid, conversationId: "conv-w", store: store, context: context)
        XCTAssertEqual(Set(known.map(\.content)), ["只用水性颜料。", "上色时别催她。"], "只带这个窗口出过的")
    }

    /// 写手给的置信度：解析 → 落库 → 另一个 context 读回是同一个数；没给的是空；越界的夹到 0–100；老写手没有这个数
    @MainActor
    func testWriterConfidenceIsStoredAndReadBack() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = SwiftDataMemoryStore()
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let messages = (0..<5).map { FragmentPool.Message(id: "n\($0)", role: "user", content: "第 \($0) 句", date: t) }
        let batch = try FragmentPool.decodedWhole("""
        [{"subject":"岚舟","type":"fact","origin":"said","confidence":88,"content":"只用水性颜料。","msgs":[1]},
         {"subject":"岚舟","type":"fact","origin":"said","content":"住在云桥城。","msgs":[2]},
         {"subject":"麦芽","type":"fact","origin":"said","confidence":150,"content":"麦芽是岚舟养的猫。","msgs":[3]},
         {"subject":"星砚","type":"instruction","origin":"assistant","confidence":-5,"content":"上色时别催她。","msgs":[4]}]
        """, messageCount: 5)
        XCTAssertEqual(batch.fragments.map(\.confidence), [88, nil, 100, 0])
        XCTAssertEqual(try FragmentPool.write(batch.fragments, messages: messages, profileId: pid, conversationId: "conv-c",
                                              extractedBy: "测试模型", store: store, context: context), 4)

        let classic = try XCTUnwrap(FragmentPool.parse(
            #"{"fragments":[{"msg":5,"content":"船想送给林栖。","tags":[],"importance":3,"emotion":0,"resolved":null,"category":"fact","subject":"岚舟","speaker":"用户自述"}]}"#,
            visible: 1...5))
        XCTAssertEqual(try FragmentPool.write(classic.fragments, messages: messages, profileId: pid, conversationId: "conv-c",
                                              extractedBy: "测试模型", store: store, context: context), 1)
        let manual = try store.add(content: "手加的一条。", category: "fact", keywords: [], profileId: pid, isUserExplicit: true,
                                   extractedBy: "", sourceConversationId: nil, context: context)
        XCTAssertNil(manual.confidence)

        let back = Dictionary(uniqueKeysWithValues: store.listAll(profileId: pid, context: ModelContext(container)).map { ($0.content, $0.confidence) })
        XCTAssertEqual(back, ["只用水性颜料。": 88, "住在云桥城。": nil, "麦芽是岚舟养的猫。": 100, "上色时别催她。": 0,
                              "船想送给林栖。": nil, "手加的一条。": nil])
    }

    func testProcessRoutesToWholeWriterWhenContextGiven() async {
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let messages = [FragmentPool.Message(id: "n0", role: "user", content: "我只用水性颜料", date: t)]
        let seen = Seen()
        let caller: SessionSegmentWriter.Caller = { system, user in
            await seen.record(system: system, user: user)
            return #"[{"subject":"岚舟","type":"fact","origin":"said","content":"只用水性颜料。","msgs":[1]}]"#
        }
        let context = FragmentPool.WholeContext(windowTitle: "模型船", before: [], known: [.init(subject: "岚舟", content: "住在云桥城。")])
        var written: [FragmentPool.Fragment] = []
        let outcome = await FragmentPool.process(messages, names: names, caller: caller, local: false, profileId: pid,
                                                 modelName: "测试模型", fallbackNote: nil, whole: context) { fragments in
            written = fragments
            return fragments.count
        }
        XCTAssertEqual(outcome, .done(added: 1))
        XCTAssertEqual(written.map(\.content), ["只用水性颜料。"])
        let system = await seen.system, user = await seen.user
        XCTAssertTrue(system.contains("这个窗口叫「模型船」"))
        XCTAssertTrue(user.contains("## 已记的卡\n\n- 岚舟：住在云桥城。") && user.contains("## 新对话（#1–#1）"))
    }

    private func withExtractOn(_ body: () async -> Void) async {
        let switches = ["mem_master", "mem_content_facts"]
        let saved = switches.map { UserDefaults.standard.object(forKey: $0) }
        for key in switches { UserDefaults.standard.set(true, forKey: key) }
        defer {
            for (key, value) in zip(switches, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        await body()
    }

    private func latestLog(_ profileId: String) -> MemoryWriteLog.Entry? {
        MemoryWriteLog.flush()
        let root = FileLibraryStore.memoryRoot(profileId: profileId)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return MemoryWriteLog.entries(memoryRoot: root).first { $0.writer == "C2" }
    }

    /// app 默认写完再核对一次：两次调用都记进这一批的账，日志说清是「写 + 核对」
    func testProcessWritesThenVerifiesAndMetersBothCalls() async throws {
        let floor = "xctest-fragment-whole-verify"
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let messages = (0..<3).map { FragmentPool.Message(id: "n\($0)", role: "user", content: "第 \($0) 句", date: t) }
        let draft = #"[{"subject":"岚舟","type":"fact","origin":"said","content":"只用水性颜料。","msgs":[1]},{"subject":"岚舟","type":"fact","origin":"said","content":"前文里的事。","msgs":[2]}]"#
        let fixed = #"[{"subject":"岚舟","type":"fact","origin":"said","content":"只用水性颜料，油性的味道受不了。","msgs":[1]}]"#
        let seen = Users()
        var written: [String] = []
        await withExtractOn {
            let outcome = await MemoryWriteLog.metered {
                await FragmentPool.process(messages, names: names, caller: { _, user in
                    MemoryWriteLog.addCost(0.01)
                    return await seen.next(user) == 0 ? draft : fixed
                }, local: false, profileId: floor, modelName: "测试模型", fallbackNote: nil,
                   whole: .init(windowTitle: "模型船", before: [], known: [])) { fragments in
                    written = fragments.map(\.content)
                    return fragments.count
                }
            }
            XCTAssertEqual(outcome, .done(added: 1))
        }
        let users = await seen.all
        XCTAssertEqual(users.count, 2, "写一次、核对一次")
        XCTAssertTrue(users[1].contains("## 你刚交的这一批\n\n" + draft))
        XCTAssertEqual(written, ["只用水性颜料，油性的味道受不了。"], "落库的是核对后的那份")
        let entry = try XCTUnwrap(latestLog(floor))
        XCTAssertEqual(entry.costUSD ?? 0, 0.02, accuracy: 1e-9, "两次调用的花费都在这一条里")
        XCTAssertEqual(entry.note, "记下 1 条 · 写 + 核对（初稿 2 张）")
    }

    /// 核对那次回的不是 JSON、重写后才合格：不算「首轮拒收」；核对彻底没成就留初稿、日志照实说
    func testVerifyRoundFormatRetryIsNotAFirstRoundRejection() async throws {
        let floor = "xctest-fragment-whole-verify-retry"
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let messages = [FragmentPool.Message(id: "n0", role: "user", content: "我只用水性颜料", date: t)]
        let draft = #"[{"subject":"岚舟","type":"fact","origin":"said","content":"只用水性颜料。","msgs":[1]}]"#
        let seen = Users()
        await withExtractOn {
            let outcome = await MemoryWriteLog.metered {
                await FragmentPool.process(messages, names: names, caller: { _, user in
                    MemoryWriteLog.addCost(0.01)
                    return await seen.next(user) == 1 ? "我核对一下" : draft
                }, local: false, profileId: floor, modelName: "测试模型", fallbackNote: "重新记 · 第 1 / 2 批",
                   whole: .init(windowTitle: "模型船", before: [], known: [])) { $0.count }
            }
            XCTAssertEqual(outcome, .done(added: 1))
        }
        let calls = await seen.all.count
        XCTAssertEqual(calls, 3, "写 1 次 + 核对 1 次 + 核对的格式重写 1 次")
        let entry = try XCTUnwrap(latestLog(floor))
        XCTAssertEqual(entry.note, "记下 1 条 · 写 + 核对（初稿 1 张） · 重新记 · 第 1 / 2 批")
        XCTAssertFalse(entry.note.contains("首轮拒收"))
        XCTAssertNil(entry.rejected)
        XCTAssertEqual(entry.costUSD ?? 0, 0.03, accuracy: 1e-9)

        let kept = "xctest-fragment-whole-verify-kept"
        await withExtractOn {
            let outcome = await MemoryWriteLog.metered {
                await FragmentPool.process(messages, names: names, caller: { _, user in
                    user.contains("## 你刚交的这一批") ? nil : draft
                }, local: false, profileId: kept, modelName: "测试模型", fallbackNote: nil,
                   whole: .init(windowTitle: "模型船", before: [], known: [])) { $0.count }
            }
            XCTAssertEqual(outcome, .done(added: 1), "核对那次被预算拦下：初稿照存")
        }
        XCTAssertEqual(latestLog(kept)?.note, "记下 1 条 · 写 + 核对（核对那次没成，留初稿）")
    }

    /// 健康状态那几项记在 standard 里：测前测后都清掉，连续失败从 0 数
    private func cleanHealth(_ floor: String) {
        let keys = ["ok", "err", "errmsg", "streak", "model"].map { "mem_health_extract_\($0)_\(floor)" }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        addTeardownBlock {
            for key in keys { UserDefaults.standard.removeObject(forKey: key) }
            MemoryWriteLog.flush()
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: floor).deletingLastPathComponent())
        }
    }

    /// 整段写手整包格式不对：记失败、这一截留着（水位不动）；冷却里自动触发不认领、不调模型，她手动的照认领；
    /// 冷却过了再试同一截，写成了才挪水位。连续失败照常累计、成功清零，记忆日志每次失败都有一条
    func testWholeFormatFailureKeepsTheSpanAndRetriesOnlyAfterCooldown() async throws {
        let floor = "xctest-fragment-whole-held"
        cleanHealth(floor)
        let watch = FragmentWatch(defaults: tempDefaults())
        let p10 = path(10), p30 = path(30)
        let sizes = Array(repeating: 100, count: 30)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let cool = SessionCloseout.formatCooldown
        _ = await watch.due(conversationId: "w", pathIds: p10.ids, dates: p10.dates, threshold: 200, sizes: Array(sizes.prefix(10)), now: t)
        _ = await watch.due(conversationId: "w", pathIds: p30.ids, dates: p30.dates, threshold: 200, sizes: sizes, now: t)
        let messages = (10..<30).map { FragmentPool.Message(id: "c\($0)", role: "user", content: "第 \($0) 句", date: p30.dates[$0]) }
        let card = #"[{"subject":"岚舟","type":"fact","origin":"said","content":"只用水性颜料。","msgs":[1]}]"#
        let seen = Users()
        /// 触发一次：认领到了就跑一包、按结果收水位；没认领到 = nil
        func trigger(at now: Date, manual: Bool = false, reply: String) async -> FragmentPool.Outcome? {
            guard let claim = await watch.due(conversationId: "w", pathIds: p30.ids, dates: p30.dates, threshold: FragmentWatch.wholeTailMinimum,
                                              sizes: sizes, manual: manual, now: now) else { return nil }
            XCTAssertEqual(claim.range, 10..<30, "每次认领的都是同一截")
            let outcome = await FragmentPool.process(messages, names: names, caller: { _, user in
                _ = await seen.next(user)
                return reply
            }, local: false, profileId: floor, modelName: "测试模型", fallbackNote: nil,
               whole: .init(windowTitle: "模型船", before: [], known: [])) { $0.count }
            await watch.finish(conversationId: "w", claim: claim, outcome: outcome, now: now)
            return outcome
        }
        await withExtractOn {
            var outcome = await trigger(at: t, reply: "我想想")
            XCTAssertEqual(outcome, .held, "两次都不是合格 JSON")
            XCTAssertFalse(FragmentPool.Outcome.held.settled)
            var calls = await seen.all.count
            XCTAssertEqual(calls, 2, "写一次、格式重写一次")
            var backlog = await watch.backlog(conversationId: "w", pathIds: p30.ids)
            XCTAssertEqual(backlog, 20, "水位没动：这一截还在")
            XCTAssertEqual(MemoryHealthStore.failStreak(.extract, profileId: floor), 1)

            outcome = await trigger(at: t.addingTimeInterval(60), reply: card)
            XCTAssertNil(outcome, "冷却里自动触发不认领")
            outcome = await trigger(at: t.addingTimeInterval(cool - 1), reply: card)
            XCTAssertNil(outcome)
            var tails = await watch.tails(idle: 0, now: t.addingTimeInterval(60))
            XCTAssertEqual(tails, [], "收尾巴也不来找它")
            calls = await seen.all.count
            XCTAssertEqual(calls, 2, "冷却里一次模型都没调")
            let classic = await watch.due(conversationId: "w", pathIds: p30.ids, dates: p30.dates, threshold: 6, now: t.addingTimeInterval(60))
            XCTAssertEqual(classic?.range, 10..<16, "老写手的认领不看这个冷却")
            if let classic { await watch.release(conversationId: "w", token: classic.token) }

            outcome = await trigger(at: t.addingTimeInterval(120), manual: true, reply: "还是不行")
            XCTAssertEqual(outcome, .held, "她手动的不看冷却；又没成")
            XCTAssertEqual(MemoryHealthStore.failStreak(.extract, profileId: floor), 2, "反复失败照常累计（到 3 状态卡变红）")
            outcome = await trigger(at: t.addingTimeInterval(cool + 60), reply: card)
            XCTAssertNil(outcome, "冷却从最近一次失败算起")

            let later = t.addingTimeInterval(120 + cool + 1)
            tails = await watch.tails(idle: 0, now: later)
            XCTAssertEqual(tails, ["w"], "冷却过了")
            outcome = await trigger(at: later, reply: card)
            XCTAssertEqual(outcome, .done(added: 1), "冷却过了再试同一截")
            backlog = await watch.backlog(conversationId: "w", pathIds: p30.ids)
            XCTAssertEqual(backlog, 0, "写成了才挪水位")
            XCTAssertEqual(MemoryHealthStore.failStreak(.extract, profileId: floor), 0)
        }
        MemoryWriteLog.flush()
        let failures = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: floor)).filter { $0.writer == "C2" && !$0.ok }
        XCTAssertEqual(failures.map(\.rejected), [1, 1], "每次失败记忆日志里都有一条")
    }

    /// 交回来是 JSON、但一条合格的都没有：同样留着等冷却后再试
    func testWholeBatchWithNoValidCardIsHeldToo() async {
        let floor = "xctest-fragment-whole-held-rows"
        cleanHealth(floor)
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        let messages = [FragmentPool.Message(id: "n0", role: "user", content: "我只用水性颜料", date: t)]
        await withExtractOn {
            let outcome = await FragmentPool.process(messages, names: names, caller: { _, _ in
                #"[{"subject":"岚舟","content":"只用水性颜料。"}]"#
            }, local: false, profileId: floor, modelName: "测试模型", fallbackNote: nil,
               whole: .init(windowTitle: "模型船", before: [], known: [])) { $0.count }
            XCTAssertEqual(outcome, .held)
        }
    }

    private actor Users {
        var all: [String] = []
        func next(_ user: String) -> Int {
            all.append(user)
            return all.count - 1
        }
    }

    private actor Seen {
        var system = ""
        var user = ""
        func record(system: String, user: String) {
            self.system = system
            self.user = user
        }
    }
}
