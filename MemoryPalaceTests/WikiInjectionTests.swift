import XCTest
import SwiftData
@testable import 记忆花园

/// C3 ② 注入（plan-memory-c3-catalog 第六节 / todo 13–15）：根索引 + 命中页 + 命中的「留下」碎片、钉住照带、按类别常驻停掉、
/// 去重、已过期、触发词扫描（4 条 / 3 页 / 排除名字和不触发的词 / 排序 / 大小写）、缓存失效、常驻页那一行
final class WikiInjectionTests: XCTestCase {

    private let pid = "xctest-wiki-injection"
    private let keys = ["mem_inject_keyword", "mem_inject_full", "mem_inject_vector", "mem_inject_graph", "mem_master",
                        MemoryOpenWindow.cKey, MemoryOpenWindow.b4Key, "mem_inject_budget", "mem_inject_catalog"]
    private var saved: [String: Any?] = [:]
    private var root: URL!
    private var wiki: WikiStore!

    override func setUpWithError() throws {
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.b4Key)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-inject-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root)
    }

    override func tearDownWithError() throws {
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ day: Int, _ hour: Int, month: Int = 10) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func page(_ path: String, _ title: String, triggers: [String] = [], hook: String = "", now: String = "") -> WikiInjectionSnapshot.Page {
        WikiInjectionSnapshot.Page(path: path, title: title, triggers: triggers, hook: hook, now: now)
    }

    private func profile() -> Profile {
        Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "阿青", assistantName: "阿白")
    }

    /// 碎片池的一条：留下（reviewedAt）/ 没看过 / 旧档案（不是碎片）
    private func fragment(_ content: String, kept: Bool = true, organizedPage: String? = nil, pinned: Bool = false) -> Memory {
        let m = Memory(content: content, category: "fact", profileId: pid, isUserExplicit: pinned)
        m.occurredDay = "2026-10-10"
        m.reviewedAt = kept ? at(10, 12) : nil
        m.organizedPage = organizedPage
        m.organizedAt = organizedPage == nil ? nil : at(10, 12)
        return m
    }

    // MARK: - 触发词

    func testWindowIsLastFourMessages() {
        let s = WikiInjectionSnapshot(pages: [page("楼层/人/小慧", "小慧"), page("楼层/地点/五楼", "五楼")])
        let recent = ["五楼那间屋", "a", "b", "c", "小慧来了"]
        XCTAssertEqual(WikiInjection.hits(s, recent: recent, excluding: []).map(\.page.title), ["小慧"], "第 5 条往前不扫")
        XCTAssertEqual(WikiInjection.hits(s, recent: Array(recent.suffix(4)) + ["五楼"], excluding: []).map(\.page.title), ["五楼", "小慧"])
    }

    func testExcludesNamesAndStopWordsEvenTitle() {
        var s = WikiInjectionSnapshot(pages: [page("楼层/人/阿青", "阿青", triggers: ["青青"]), page("楼层/身体", "身体", triggers: ["复诊"]),
                                              page("工程/记忆宫殿", "记忆宫殿", triggers: ["审计台"])])
        s.stopWords = ["复诊", "身体"]
        let hits = WikiInjection.hits(s, recent: ["阿青说身体还行，复诊在下周，阿白记一下记忆宫殿"], excluding: ["阿青", "阿白"])
        XCTAssertEqual(hits.map(\.page.title), ["记忆宫殿"], "名字和不触发的词不算，就算是页的标题")
        XCTAssertEqual(WikiInjection.hits(s, recent: ["青青来了"], excluding: ["阿青"]).map(\.word), ["青青"], "同页别的触发词照样触发")
    }

    func testCaseInsensitiveEnglishLiteralChinese() {
        let s = WikiInjectionSnapshot(pages: [page("工程/fable", "Fable", triggers: ["ccRP"])])
        XCTAssertEqual(WikiInjection.hits(s, recent: ["今天 fable 又挂了"], excluding: []).first?.word, "Fable")
        XCTAssertEqual(WikiInjection.hits(s, recent: ["CCRP 起不来"], excluding: []).first?.word, "ccRP")
        let zh = WikiInjectionSnapshot(pages: [page("楼层/人/小慧", "小慧")])
        XCTAssertTrue(WikiInjection.hits(zh, recent: ["小 慧"], excluding: []).isEmpty, "中文逐字")
    }

    func testAtMostThreeAndOrdering() {
        let s = WikiInjectionSnapshot(pages: [
            page("a", "猫"), page("b", "狗"), page("c", "鱼"), page("d", "鸟"), page("e", "兔"),
        ])
        // 最近一条：狗在最前；鱼和猫同一条里，猫出现两次但位置在鱼后面 → 位置先比
        let latest = "狗和鱼还有猫猫"
        XCTAssertEqual(WikiInjection.hits(s, recent: ["鸟", latest], excluding: []).map(\.page.title), ["狗", "鱼", "猫"], "最多 3 页，鸟只在更早的那条")
        // 同位置（同一个词起头）比次数：触发词不同但在同一处
        let tie = WikiInjectionSnapshot(pages: [page("x", "小慧", triggers: []), page("y", "小慧家", triggers: ["慧慧"])])
        XCTAssertEqual(WikiInjection.hits(tie, recent: ["小慧家慧慧"], excluding: []).map(\.page.title), ["小慧家", "小慧"], "同位置次数多的在前")
        // 最近一条都没有：往前一条比
        XCTAssertEqual(WikiInjection.hits(s, recent: ["兔子和鸟", "别的", "今天"], excluding: []).map(\.page.title), ["兔", "鸟"])
    }

    func testIndexLinesOnlyEntries() {
        let md = "# C 档案\n\(WikiStore.overfullMarker)\n\n## 工程（1 页）\n- [[工程/记忆宫殿]] 记忆宫殿 — 聊这个 app 时\n\n## 楼层（2 页）\n- [[楼层/人/]] 人 — 她提到身边的人时（2 页）\n"
        XCTAssertEqual(WikiInjection.indexLines(md), ["- [[工程/记忆宫殿]] 记忆宫殿 — 聊这个 app 时", "- [[楼层/人/]] 人 — 她提到身边的人时（2 页）"])
        XCTAssertEqual(WikiInjection.indexBlock(WikiInjectionSnapshot()), "", "没条目不带这一块")
    }

    // MARK: - 已过期（05:00 分界）

    func testExpiredSentenceInNow() {
        let text = "在吃二甲双胍（自 2026-09 起）。下周三复诊（到 2026-10-22）。月底前交（到 2026-10）。"
        XCTAssertEqual(WikiInjection.markExpired(text, now: at(23, 4)), text, "23 号凌晨 4 点还算 22 号")
        XCTAssertEqual(WikiInjection.markExpired(text, now: at(23, 5)),
                       "在吃二甲双胍（自 2026-09 起）。下周三复诊（到 2026-10-22，已过期）。月底前交（到 2026-10）。")
        XCTAssertEqual(WikiInjection.markExpired(text, now: at(1, 5, month: 11)),
                       "在吃二甲双胍（自 2026-09 起）。下周三复诊（到 2026-10-22，已过期）。月底前交（到 2026-10，已过期）。", "只写到月：过了那个月")
        let once = WikiInjection.markExpired(text, now: at(1, 5, month: 11))
        XCTAssertEqual(WikiInjection.markExpired(once, now: at(1, 5, month: 11)), once, "已经标过的不再标")
    }

    func testExpiredFragment() throws {
        let m = fragment("下周三复诊")
        m.validUntil = try XCTUnwrap(FragmentPool.validUntilDate("2026-10-22"))
        XCTAssertFalse(WikiInjection.isExpired(m, now: at(23, 4)))
        XCTAssertTrue(WikiInjection.isExpired(m, now: at(23, 5)))
        let (_, volatile, _) = MemoryInjector.buildInjectionSplit(memories: [m], now: at(23, 5))
        XCTAssertEqual(volatile, "- 下周三复诊 [事实]（已过期）", "照带，行尾标，不删")
        XCTAssertEqual(MemoryInjector.buildInjectionSplit(memories: [m], now: at(23, 4)).volatile, "- 下周三复诊 [事实]")
    }

    func testExpiredPinnedReminderOnlyForInjectedItemsAndWithinBudget() throws {
        let included = fragment("钉住的复诊", pinned: true)
        let excluded = fragment(String(repeating: "没有预算带入的钉住项", count: 20), pinned: true)
        included.createdAt = at(1, 12)
        excluded.createdAt = at(2, 12)
        let until = try XCTUnwrap(FragmentPool.validUntilDate("2026-10-22"))
        included.validUntil = until
        excluded.validUntil = until
        let title = "[已过期的钉住项]"
        let reminder = "- 钉住的复诊（已过期）"
        let reminderCost = Memory.estimateTokens(title + "\n") + Memory.estimateTokens(reminder)
        let dateSuffix = "（有效到 2026-10-22）"
        let includedCost = included.tokenCount + Memory.estimateTokens(dateSuffix)
        let budget = includedCost + reminderCost
        let split = MemoryInjector.buildInjectionSplit(memories: [included, excluded], budget: budget, now: at(23, 5))
        XCTAssertEqual(split.stable, "- 钉住的复诊\(dateSuffix) [事实]")
        XCTAssertEqual(split.volatile, title + "\n" + reminder)
        XCTAssertEqual(split.hits.map(\.memoryId), [included.id], "提醒不重复计作一次记忆命中")
        XCTAssertFalse((split.stable + split.volatile).contains("没有预算"))

        let tight = MemoryInjector.buildInjectionSplit(memories: [included], budget: includedCost + reminderCost - 1, now: at(23, 5))
        XCTAssertEqual(tight.stable, split.stable, "提醒预算不能反过来改变稳定层选择")
        XCTAssertTrue(tight.volatile.isEmpty, "标题和提醒一起计费，预算不够不能留下空标题")

        let otherPinned = fragment("另一条必须照带的钉住项", pinned: true)
        otherPinned.createdAt = at(3, 12)
        let fullStableBudget = includedCost + otherPinned.tokenCount
        let before = MemoryInjector.buildInjectionSplit(memories: [included, otherPinned], budget: fullStableBudget, now: at(23, 4))
        let after = MemoryInjector.buildInjectionSplit(memories: [included, otherPinned], budget: fullStableBudget, now: at(23, 5))
        XCTAssertEqual(Array(before.stable.utf8), Array(after.stable.utf8), "动态提醒不能挤出后续钉住项")
        XCTAssertTrue(before.stable.contains("钉住的复诊\(dateSuffix) [事实]"), "有效日取 validUntil 前一秒的记忆日，不是到期时刻的日历日")
        XCTAssertFalse(after.stable.contains("已过期"), "跨记忆日只改变动态提醒，不改稳定层的有效日")
        XCTAssertTrue(after.stable.contains(otherPinned.content))
        XCTAssertTrue(after.volatile.isEmpty, "稳定层已花完预算则省略动态提醒")
    }

    // MARK: - 三样注入 + 去重

    func testLayersIndexPagesFragmentsAndDedup() {
        let snapshot = WikiInjectionSnapshot(
            indexLines: ["- [[楼层/人/小慧]] 小慧 — 她提到小慧时", "- [[工程/项目/]] 项目（2 页）"],
            pages: [page("楼层/人/小慧", "小慧", triggers: ["慧慧"], hook: "她提到小慧时", now: "室友（自 2026-09 起）。约了看房（到 2026-10-01）。")])
        let pinned = fragment("钉住的一条", pinned: true)
        pinned.organizedPage = "楼层/人/小慧"
        let into = fragment("小慧搬进来了", organizedPage: "楼层/人/小慧")
        let other = fragment("团子体检正常")
        let layers = PromptAssembler.memoryLayers(profile: profile(), selfMemory: nil, memories: [pinned, into, other],
                                                  recentMessages: ["慧慧今天回来"], budget: nil, wiki: snapshot, now: at(11, 12))
        XCTAssertEqual(layers.stable, """
        [C 档案 · 索引]
        - [[楼层/人/小慧]] 小慧 — 她提到小慧时
        - [[工程/项目/]] 项目（2 页）

        [关于阿青]
        - 钉住的一条 [事实]
        """)
        XCTAssertEqual(layers.volatile, """
        [C 档案 · 本轮相关]
        [[楼层/人/小慧]] 小慧
        钩子：她提到小慧时
        现在：室友（自 2026-09 起）。约了看房（到 2026-10-01，已过期）。

        [关于阿青·本轮相关]
        - 团子体检正常 [事实]
        """, "整理进命中页的碎片不带（钉住的照带）")
        XCTAssertEqual(layers.pages.map(\.word), ["慧慧"])

        let quiet = PromptAssembler.memoryLayers(profile: profile(), selfMemory: nil, memories: [pinned, into, other],
                                                 recentMessages: ["今天天气好"], budget: nil, wiki: snapshot, now: at(11, 12))
        XCTAssertTrue(quiet.volatile.contains("小慧搬进来了"), "页没命中：碎片照带")
        XCTAssertFalse(quiet.volatile.contains("[C 档案 · 本轮相关]"))

        let empty = PromptAssembler.memoryLayers(profile: profile(), selfMemory: nil, memories: [other], recentMessages: ["慧慧"],
                                                 budget: nil, wiki: WikiInjectionSnapshot(), now: at(11, 12))
        XCTAssertFalse(empty.stable.contains("C 档案"), "wiki 空：不带索引")
        XCTAssertFalse(empty.volatile.contains("C 档案"))
    }

    /// 非缓存友好路（记忆插槽一整段）：B4 → 索引 → [关于X] → 命中页
    func testMarkerPathCarriesWiki() {
        let snapshot = WikiInjectionSnapshot(indexLines: ["- [[楼层/人/小慧]] 小慧 — 她提到小慧时"],
                                             pages: [page("楼层/人/小慧", "小慧", hook: "她提到小慧时", now: "室友。")])
        var preset = Preset.balanced
        preset.sampling.cacheFriendly = false
        let segs = PromptAssembler.assembleTagged(preset: preset, profile: profile(), memories: [fragment("团子体检正常")],
                                                  chatHistory: [("user", "小慧回来了")], wiki: snapshot).segments
        let memory = segs.first { $0.source == .memory }?.content ?? ""
        XCTAssertEqual(memory, """
        [C 档案 · 索引]
        - [[楼层/人/小慧]] 小慧 — 她提到小慧时

        [关于阿青]
        - 团子体检正常 [事实]

        [C 档案 · 本轮相关]
        [[楼层/人/小慧]] 小慧
        钩子：她提到小慧时
        现在：室友。
        """)
    }

    // MARK: - 每轮的输入：钉住照带、按类别常驻停掉、只带留下的碎片、C 没勾三样都不带

    @MainActor
    func testRoundInputsCandidatesAndGate() async throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let pinnedOld = Memory(content: "钉住的旧档案", category: "fact", profileId: pid, isUserExplicit: true)
        let relationOld = Memory(content: "关系类旧档案", category: "relationship", profileId: pid)
        let kept = fragment("留下的碎片")
        let unseen = fragment("没看过的碎片", kept: false)
        let gone = fragment("删了的碎片")
        gone.supersededAt = Date()
        [pinnedOld, relationOld, kept, unseen, gone].forEach { context.insert($0) }
        try context.save()
        try wiki.save(WikiPage(path: "楼层/人/小慧", kind: .person, triggers: ["慧慧"], hook: "她提到小慧时", title: "小慧", now: "室友。"))
        try wiki.rebuildAllIndexes()
        _ = try await WikiInjectionCache.shared.warm(root.path) { [wiki] in wiki! }

        let store = SwiftDataMemoryStore()
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        let on = MemoryInjector.roundInputs(profileId: pid, conversationMemoryEnabled: true, store: store, context: context, wikiStore: wiki)
        XCTAssertEqual(Set(on.memories.map(\.content)), ["钉住的旧档案", "留下的碎片"])
        XCTAssertEqual(on.wiki?.pages.map(\.title), ["小慧"])
        XCTAssertFalse(MemoryInjector.isPersistent(relationOld), "按类别常驻停掉")

        let layers = PromptAssembler.memoryLayers(profile: profile(), selfMemory: nil, memories: on.memories, recentMessages: ["慧慧"],
                                                  budget: on.archiveBudget, wiki: on.wiki)
        XCTAssertTrue(layers.stable.contains("[C 档案 · 索引]\n- [[楼层/人/]] 人（1 页）"), "根索引的条目行（分组行）")
        XCTAssertTrue(layers.stable.contains("[关于阿青]\n- 钉住的旧档案 [事实]"))
        XCTAssertTrue(layers.volatile.contains("[C 档案 · 本轮相关]") && layers.volatile.contains("- 留下的碎片 [事实]"))
        XCTAssertFalse((layers.stable + layers.volatile).contains("关系类旧档案"))
        XCTAssertFalse((layers.stable + layers.volatile).contains("没看过的碎片"))

        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.cKey)
        let off = MemoryInjector.roundInputs(profileId: pid, conversationMemoryEnabled: true, store: store, context: context, wikiStore: wiki)
        XCTAssertTrue(off.memories.isEmpty, "C 没勾：钉住的也不带（同改前）")
        XCTAssertNil(off.wiki, "C 没勾：根索引、命中页都不带")
    }

    // MARK: - 缓存

    @MainActor
    func testCacheInvalidatesOnWikiWriteAndMemoryChange() async throws {
        let cache = WikiInjectionCache.shared
        let key = root.path
        let source: WikiInjectionCache.Source = { [wiki] in wiki! }
        try wiki.save(WikiPage(path: "楼层/人/小慧", title: "小慧"))
        try wiki.rebuildAllIndexes()
        _ = try await cache.warm(key, source)
        XCTAssertTrue(cache.isFresh(key))
        XCTAssertEqual(cache.snapshot(key, source)?.indexLines.count, 1, "新的：主线程直接给")

        try wiki.save(WikiPage(path: "楼层/人/阿明", title: "阿明"))
        XCTAssertFalse(cache.isFresh(key), "写了页就作废")
        XCTAssertEqual(cache.snapshot(key, source)?.pages.count, 1, "主线程不读盘：先给旧的")
        _ = try await cache.warm(key, source)
        XCTAssertEqual(cache.snapshot(key, source)?.pages.map(\.title), ["小慧", "阿明"])

        try wiki.setStopWords(["小慧"])
        _ = try await cache.warm(key, source)
        XCTAssertEqual(cache.snapshot(key, source)?.stopWords, ["小慧"], "不触发的词改了也作废")

        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        XCTAssertFalse(cache.isFresh(key), "记忆变更通知也作废")
        _ = try await cache.warm(key, source)
        XCTAssertTrue(cache.isFresh(key))

        let other = "xctest-wiki-cold-\(UUID().uuidString)"
        XCTAssertNil(cache.snapshot(other) { WikiStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(other)) },
                     "冷的：主线程这一轮拿不到（后台去建）")
    }

    @MainActor
    func testWikiInjectionInvalidationIgnoresInternalAndUnchangedWrites() async throws {
        let cache = WikiInjectionCache.shared
        let key = root.path
        let source: WikiInjectionCache.Source = { [wiki] in wiki! }
        try wiki.save(WikiPage(path: "楼层/测试页", title: "测试页"))
        _ = try await cache.warm(key, source)
        let version = cache.version
        let unrelated = [
            ".history/楼层/测试页/20261017-120000.md",
            ".proposals/proposal.json",
            ".proposals/drafts/draft.md",
            ".proposals/drafts/INDEX.md",
            ".group.md",
            "楼层/人/.group.md",
            "notes.txt",
            "楼层/notes.txt",
        ]
        for path in unrelated {
            try WikiStore.writeAtomic(Data("内部资料".utf8), to: root.appendingPathComponent(path))
            XCTAssertEqual(cache.version, version, path)
            XCTAssertTrue(cache.isFresh(key), path)
        }

        for path in ["INDEX.md", "楼层/INDEX.md", "楼层/测试页.md", WikiStore.stopWordsFileName] {
            let url = root.appendingPathComponent(path)
            let data = Data("新内容 \(path)".utf8)
            let before = cache.version
            try WikiStore.writeAtomic(data, to: url)
            XCTAssertEqual(cache.version, before + 1, path)
            XCTAssertFalse(cache.isFresh(key), path)
            _ = try await cache.warm(key, source)
            try WikiStore.writeAtomic(data, to: url)
            XCTAssertEqual(cache.version, before + 1, "相同内容不失效：\(path)")
            XCTAssertTrue(cache.isFresh(key), path)
        }
    }

    @MainActor
    func testWarmedSnapshotRemainsRoundInputAfterInvalidationAndNewBuild() async throws {
        let stores = try cacheStores()
        try stores.old.rebuildAllIndexes()
        try stores.new.rebuildAllIndexes()
        let cache = WikiInjectionCache()
        let reads = ReadCounter()
        let source: WikiInjectionCache.Source = { reads.next() == 1 ? stores.old : stores.new }
        let warmed = try await cache.warm("fixed-round", source)
        cache.invalidate()
        XCTAssertFalse(cache.isFresh("fixed-round"))
        let newer = try await cache.warm("fixed-round", source)
        XCTAssertGreaterThan(newer.generation, warmed.generation)
        XCTAssertEqual(newer.snapshot.pages.map(\.title), ["新页"])
        XCTAssertEqual(warmed.snapshot.pages.map(\.title), ["旧页"])

        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        let round = MemoryInjector.roundInputs(profileId: pid, conversationMemoryEnabled: true, store: SwiftDataMemoryStore(),
                                               context: context, wikiStore: stores.new, warmedWiki: warmed, useCachedWiki: false)
        XCTAssertEqual(round.wiki, warmed.snapshot, "本轮不能再读预览缓存或改用新代次")
        let layers = PromptAssembler.memoryLayers(profile: profile(), selfMemory: nil, memories: round.memories,
                                                  recentMessages: ["旧页 新页"], budget: round.archiveBudget, wiki: round.wiki)
        XCTAssertTrue(layers.stable.contains("旧页"))
        XCTAssertTrue(layers.volatile.contains("[[楼层/旧页]] 旧页"))
        XCTAssertFalse((layers.stable + layers.volatile).contains("新页"))
    }

    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var returned = false

        func next() -> Int { lock.withLock { reads += 1; return reads } }
        var count: Int { lock.withLock { reads } }
        var didReturn: Bool { lock.withLock { returned } }
        func markReturned() { lock.withLock { returned = true } }
    }

    private func cacheStores() throws -> (old: WikiStore, new: WikiStore) {
        let old = WikiStore(root: root.appendingPathComponent("old"))
        let new = WikiStore(root: root.appendingPathComponent("new"))
        try old.save(WikiPage(path: "楼层/旧页", title: "旧页"))
        try new.save(WikiPage(path: "楼层/新页", title: "新页"))
        return (old, new)
    }

    func testCacheBuildDiscardsInvalidatedReadAndRetries() async throws {
        let stores = try cacheStores()
        let cache = WikiInjectionCache()
        let reads = ReadCounter()
        let source: WikiInjectionCache.Source = { [weak cache] in
            if reads.next() == 1 {
                cache?.invalidate()
                return stores.old
            }
            return stores.new
        }
        let snapshot = await Task.detached { cache.build("retry", source) }.value
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(snapshot.pages.map(\.title), ["新页"])
        XCTAssertTrue(cache.isFresh("retry"))
    }

    func testCacheBuildStopsAfterThreeRetriesWithoutForgingFreshness() async throws {
        let stores = try cacheStores()
        let cache = WikiInjectionCache()
        let reads = ReadCounter()
        let snapshot = await Task.detached {
            cache.build("bounded") { [weak cache] in
                _ = reads.next()
                cache?.invalidate()
                return stores.old
            }
        }.value
        XCTAssertEqual(reads.count, 4, "初次读取 + 最多三次重试")
        XCTAssertEqual(snapshot.pages.map(\.title), ["旧页"])
        XCTAssertFalse(cache.isFresh("bounded"), "最后一次内容仍属于读取前代次")
    }

    func testWarmWaitsPastStaleRetryLimitForCurrentGeneration() async throws {
        let stores = try cacheStores()
        let cache = WikiInjectionCache()
        let reads = ReadCounter()
        let finalRead = expectation(description: "下一批读取开始")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let source: WikiInjectionCache.Source = { [weak cache] in
            let read = reads.next()
            if read <= 4 {
                cache?.invalidate()
                return stores.old
            }
            if read == 5 {
                finalRead.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return stores.new
        }
        let warming = Task {
            let warmed = try await cache.warm("warm", source)
            reads.markReturned()
            return warmed
        }
        await fulfillment(of: [finalRead], timeout: 5)
        XCTAssertFalse(reads.didReturn, "build 降级为旧快照时 warm 仍不能交付")
        XCTAssertFalse(cache.isFresh("warm"))
        release.signal()
        let warmed = try await warming.value
        XCTAssertTrue(cache.isFresh("warm"))
        XCTAssertEqual(warmed.generation, cache.version)
        XCTAssertEqual(warmed.snapshot.pages.map(\.title), ["新页"])
    }

    func testWarmCancellationDoesNotWaitForBlockedDiskSource() async throws {
        let stores = try cacheStores()
        let cache = WikiInjectionCache()
        let started = expectation(description: "后台读取已阻塞")
        let canceled = expectation(description: "取消等待及时返回")
        let release = DispatchSemaphore(value: 0)
        let reads = ReadCounter()
        defer { release.signal() }
        let source: WikiInjectionCache.Source = {
            if reads.next() == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return stores.new
        }
        let warming = Task {
            defer { canceled.fulfill() }
            return try await cache.warm("cancel", source)
        }
        await fulfillment(of: [started], timeout: 5)
        warming.cancel()
        await fulfillment(of: [canceled], timeout: 1)
        XCTAssertFalse(cache.isFresh("cancel"))
        release.signal()
        do {
            _ = try await warming.value
            XCTFail("取消必须抛 CancellationError，不能交付快照")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        _ = try await cache.warm("cancel", source)
        XCTAssertTrue(cache.isFresh("cancel"), "取消一个等待者不取消共用后台重建")
    }

    func testWarmTimesOutAfterFiveSecondsWhileSourceRemainsBlocked() async throws {
        let stores = try cacheStores()
        let started = expectation(description: "读取已阻塞")
        let finished = expectation(description: "总等待五秒后结束")
        let release = DispatchSemaphore(value: 0)
        let reads = ReadCounter()
        let cache = WikiInjectionCache(source: {
            if reads.next() == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 8)
            }
            return stores.new
        })
        defer { release.signal() }
        let startedAt = Date()
        let warming = Task {
            defer { finished.fulfill() }
            return try await cache.warm("timeout") { stores.old }
        }
        await fulfillment(of: [started], timeout: 2)
        await fulfillment(of: [finished], timeout: 6)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 4.8, "五秒是整次 warm 的期限，不能提前当作失败")
        XCTAssertFalse(cache.isFresh("timeout"), "超时不能等阻塞 source 自行返回")
        XCTAssertEqual(reads.count, 1)
        release.signal()
        do {
            _ = try await warming.value
            XCTFail("超时不能交付旧快照或空快照")
        } catch {
            XCTAssertEqual(error as? WikiInjectionCache.WarmError, .timedOut)
        }
        let recovered = try await cache.warm("timeout") { stores.old }
        XCTAssertEqual(recovered.snapshot.pages.map(\.title), ["新页"], "超时只移除自身 waiter，不取消共享重建")
    }

    func testScheduledRebuildStopsAfterThreeBatchesAndFailsWaiter() async throws {
        let stores = try cacheStores()
        let cache = WikiInjectionCache()
        let reads = ReadCounter()
        let source: WikiInjectionCache.Source = { [weak cache] in
            if reads.next() <= 12 {
                cache?.invalidate()
                return stores.old
            }
            return stores.new
        }
        do {
            _ = try await cache.warm("continuous-invalidation", source)
            XCTFail("持续失效达到总上限时必须失败，不能无限后台重试或偷发旧代次")
        } catch {
            XCTAssertEqual(error as? WikiInjectionCache.WarmError, .rebuildLimitReached)
        }
        XCTAssertEqual(reads.count, 12, "三批，每批初次读取 + 三次重试")
        XCTAssertFalse(cache.isFresh("continuous-invalidation"))
        let recovered = try await cache.warm("continuous-invalidation", source)
        XCTAssertEqual(reads.count, 13, "达到上限后该后台任务已结束，下一次 warm 可以重新开始")
        XCTAssertEqual(recovered.snapshot.pages.map(\.title), ["新页"])
        XCTAssertEqual(recovered.generation, cache.version)
    }

    func testSlowerBuildCannotOverwriteNewerEntryInSameGeneration() async throws {
        let stores = try cacheStores()
        let cache = WikiInjectionCache()
        let started = expectation(description: "较早的读取已阻塞")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let slow = Task.detached {
            cache.build("overlap") {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return stores.old
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let newer = await Task.detached { cache.build("overlap") { stores.new } }.value
        release.signal()
        let older = await slow.value
        XCTAssertEqual(newer.pages.map(\.title), ["新页"])
        XCTAssertEqual(older, newer, "后结束的旧读取返回已发布的新 entry")
        XCTAssertEqual(cache.snapshot("overlap") { stores.new }, newer)
    }

    func testDirectBuildPostsRebuildNotificationOnMainThread() async throws {
        let stores = try cacheStores()
        let cache = WikiInjectionCache()
        let rebuilt = expectation(description: "直接 build 也刷新检查器")
        rebuilt.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(forName: WikiInjectionCache.didRebuild, object: nil, queue: nil) { _ in
            guard cache.isFresh("notification") else { return }
            XCTAssertTrue(Thread.isMainThread)
            rebuilt.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = await Task.detached { cache.build("notification") { stores.new } }.value
        await fulfillment(of: [rebuilt], timeout: 2)
    }

    // MARK: - 常驻页那一行

    func testResidentLine() {
        let hits = [WikiPageHit(page: page("楼层/人/小慧", "小慧"), word: "慧慧"),
                    WikiPageHit(page: page("工程/记忆宫殿", "记忆宫殿"), word: "审计台")]
        XCTAssertEqual(WikiInjection.residentLine(indexCount: 12, hits: hits), "根索引 12 行 · 本轮命中：小慧（“慧慧”）、记忆宫殿（“审计台”）")
        XCTAssertEqual(WikiInjection.residentLine(indexCount: 3, hits: []), "根索引 3 行 · 本轮没命中")
    }

    @MainActor
    func testResidentSummaryWikiRow() async throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try wiki.save(WikiPage(path: "楼层/人/小慧", kind: .person, triggers: ["慧慧"], hook: "她提到小慧时", title: "小慧", now: "室友。"))
        try wiki.save(WikiPage(path: "工程/记忆宫殿", kind: .project, triggers: ["审计台"], title: "记忆宫殿"))
        try wiki.rebuildAllIndexes()
        _ = try await WikiInjectionCache.shared.warm(root.path) { [wiki] in wiki! }
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        MainThreadIO.allowMainThreadInThisTest()

        let s = MemoryResident.summary(profile: profile(), conversationMemoryEnabled: true, container: container, selfMemories: [],
                                       recentMessages: ["审计台卡住了", "慧慧说没事"], wikiStore: wiki)
        XCTAssertEqual(s.wiki?.text, "根索引 2 行 · 本轮命中：小慧（“慧慧”）、记忆宫殿（“审计台”）")
        XCTAssertNil(s.wiki?.gate)
        XCTAssertTrue(s.volatile.contains("[C 档案 · 本轮相关]"), "下半预览同一份")

        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.cKey)
        let off = MemoryResident.summary(profile: profile(), conversationMemoryEnabled: true, container: container, selfMemories: [],
                                         recentMessages: ["慧慧"], wikiStore: wiki)
        XCTAssertEqual(off.wiki?.text, "根索引 2 行 · 本轮没命中")
        XCTAssertEqual(off.wiki?.gate, .archiveUnchecked)
        XCTAssertFalse(off.stable.contains("C 档案"))
    }

    func testSettingsStampCarriesWikiVersion() {
        XCTAssertNotEqual(MemoryResident.settingsStamp(wikiVersion: 1), MemoryResident.settingsStamp(wikiVersion: 2))
    }
}
