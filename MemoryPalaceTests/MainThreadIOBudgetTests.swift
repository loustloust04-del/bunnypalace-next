import XCTest
@testable import 记忆花园

/// #033 计数测试（plan-mainthread-io-assert §4.3）：组 prompt 三个热函数在主线程碰了几次盘。
/// 计的是入口 / 操作调用次数（MainThreadIO 铺点），不是 syscall 数。
/// ① 不随文件库大小涨：小库 / 大库只差文件库规模（文件、章节、日记），计数必须逐调用点一样（#00207 那种「逐文件」回归直接红）；
/// ② 棘轮上限：按调用点照现状封顶，只许降（防成本在调用点之间搬家）。实测低于上限会打印「可下调」——改的人顺手调低；
///    上调必须在提交里说明路径为什么变了。计数只记主线程同步闭包里的（后台 warmList 不算），所以是确定性的。
/// 开关全部钉死（不吃真偏好）：画像 / 时间轴 / 今日日记 / 纪念日注入开，全文回注关；交易未授权（研报读那条已知债不在这里量，见 review）。
@MainActor
final class MainThreadIOBudgetTests: XCTestCase {

    /// 上限：「kind 调用点」→ 次数（大库）。没列的调用点上限 0
    /// 热缓存下 hint 一次都不该碰盘
    static let hintBudget: [String: Int] = [:]
    static let composeBudget: [String: Int] = [
        // 10-08 首测基线（大库，开关见上）。旁路 store 的逐条读随自记 / 纪念日条数线性涨（两档条数一样，不在 flat 比较里）
        "enumerate AnniversaryStore.loadAll": 1, "read AnniversaryStore.load": 3,
        // 10-10 #066：时间轴注入从按天日记（DailyFileStore 4 次）换成跨窗口时间轴（本月 + 上月两个文件，读 2 次，不建目录）；
        // 窗口摘要先找 sessions/ 的新文件（枚举 1 次，文件不存在不读），没有再落回 summaries/ 老累计摘要
        "read TimelineStore.entries": 2, "enumerate SessionSummaryStore.existingFile": 1,
        "enumerate SelfMemoryStore.list": 1, "read SelfMemoryStore.list": 5,
        "enumerate SummaryFileStore.existingFile": 1, "mkdir SummaryFileStore.summariesDir": 1, "read SummaryFileStore.load": 1,
        "mkdir ProfileFileStore.fileURL": 1, "read ProfileFileStore.load": 1,
        "mkdir FileLibraryStore.libraryRoot": 2, "mkdir FileLibraryStore.memoryRoot": 5,
        // 历史里那张图按需读盘（附件已知债，AttachmentStore.read）
        "read FileLibraryStore.readData": 1, "stat FileLibraryStore.resolve": 1,
    ]
    /// previewTurn = 取工具（含 hint，热缓存 0）+ composePrompt，所以和 composePrompt 一样
    static let previewBudget = composeBudget

    struct Size {
        let name: String, folders: Int, filesPerFolder: Int, chapters: Int, journals: Int, selfMemories: Int, anniversaries: Int
    }
    /// 自记 / 纪念日两档一样：旁路 store 逐条读随条数线性涨是现状，不在「随文件库涨」的比较里
    static let small = Size(name: "小库", folders: 2, filesPerFolder: 5, chapters: 5, journals: 3, selfMemories: 5, anniversaries: 3)
    /// ≈ 粟粟主楼层 1394 个文件量级
    static let large = Size(name: "大库", folders: 30, filesPerFolder: 40, chapters: 300, journals: 60, selfMemories: 5, anniversaries: 3)

    /// 每次 make 换一个专属测试楼层：夹具不和别的测试共用目录，清理整层删（R2 sol I3）
    private var pid = ""
    private var harness: PromptRealPathHarness?

    override func tearDown() async throws {
        try await cleanup()
    }

    private func cleanup() async throws {
        await harness?.tearDown()
        harness = nil
        guard !pid.isEmpty else { return }
        let pid = pid
        self.pid = ""
        let floors = await Task.detached {
            Set([FileLibraryStore.libraryRoot(profileId: pid), FileLibraryStore.memoryRoot(profileId: pid)]
                .map { $0.deletingLastPathComponent() })
        }.value
        for floor in floors where FileManager.default.fileExists(atPath: floor.path) {
            try FileManager.default.removeItem(at: floor)
        }
        FileLibraryStore.forgetSlug(profileId: pid)
        FileLibraryStore.ListCache.forget(profileId: pid)
    }

    // MARK: - 夹具

    /// 绕开本仓直接写盘（同书房 / 附件 / 日记），后台写，不算主线程碰盘；写失败直接抛（R2 sol I2）
    private func seed(_ size: Size) async throws {
        let pid = pid
        try await Task.detached {
            let fm = FileManager.default
            let root = FileLibraryStore.libraryRoot(profileId: pid)
            func put(_ url: URL, _ text: String) throws {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            for f in 0..<size.folders {
                for i in 0..<size.filesPerFolder {
                    try put(root.appendingPathComponent("budget\(f)/sub/note\(i).md"), "第\(i)份笔记")
                }
            }
            for i in 0..<size.chapters {
                try put(root.appendingPathComponent(String(format: "books/budget-book/chapter_%04d.txt", i)), "章\(i)")
            }
            for i in 0..<size.journals {
                try put(root.appendingPathComponent(String(format: "journal/2026-%02d-%02d.md", i / 28 + 1, i % 28 + 1)), "日记\(i)")
            }
            for i in 0..<size.anniversaries {
                try put(root.appendingPathComponent("calendar/anniversaries/budget-\(i).json"), "{}")
            }
            let selfDir = SelfMemoryStore.directory(profileId: pid)
            for i in 0..<size.selfMemories {
                try put(selfDir.appendingPathComponent("budget-\(i).md"), "---\nname: budget-\(i)\ntype: user\n---\n自记 \(i)")
            }
            let memory = FileLibraryStore.memoryRoot(profileId: pid)
            try put(memory.appendingPathComponent("daily/2026-10-01.md"), "---\ndate: 2026-10-01\n---\n时间轴一天")
            try put(memory.appendingPathComponent("profile.md"), "---\nsourceCount: 1\n---\n画像")
        }.value
    }

    private func make(_ size: Size) async throws -> PromptRealPathHarness {
        pid = "xctest-mtio-budget-\(UUID().uuidString.prefix(8))"
        try await seed(size)
        let h = try await PromptRealPathHarness.make(PromptScenario(name: "budget-\(size.name)", profileId: pid, memoryFixtures: false))
        harness = h
        h.overrideDefault("mem_inject_profile", true)
        h.overrideDefault("mem_content_timeline", true)
        h.overrideDefault("fileLibraryFullContent", false)
        h.overrideDefault(CalendarPrivacy.journalVisibleKey(pid), false)
        h.overrideDefault(CalendarPrivacy.injectTodayJournalKey(pid), true)
        h.overrideDefault(CalendarPrivacy.anniversaryInjectKey(pid), true)
        // 热缓存：量稳态，不量启动后第一次。顺手核夹具真种进去了，规模差异才成立
        let files = await FileLibraryStore.freshList(profileId: pid).map(\.path)
        XCTAssertEqual(files.filter { $0.hasPrefix("budget") }.count, size.folders * size.filesPerFolder, "\(size.name) 笔记没种全")
        XCTAssertEqual(files.filter { $0.hasPrefix("books/budget-book/") }.count, size.chapters, "\(size.name) 章节没种全")
        XCTAssertEqual(files.filter { $0.hasPrefix("journal/") }.count, size.journals, "\(size.name) 日记没种全")
        return h
    }

    private func counting(_ body: () -> Void) -> [String: Int] {
        MainThreadIO.beginCounting()
        body()
        return MainThreadIO.endCounting()
    }

    private func byKind(_ counts: [String: Int]) -> [String: Int] {
        counts.reduce(into: [:]) { $0[String($1.key.split(separator: " ").first ?? ""), default: 0] += $1.value }
    }


    private func describe(_ counts: [String: Int]) -> String {
        counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }

    private func assertBudget(_ name: String, _ counts: [String: Int], _ budget: [String: Int],
                              file: StaticString = #filePath, line: UInt = #line) {
        print("[budget] \(name) 实测 \(describe(byKind(counts))) · 按调用点 \(describe(counts))")
        for (site, n) in counts where n > (budget[site] ?? 0) {
            XCTFail("\(name) 主线程 \(site) 实测 \(n) > 上限 \(budget[site] ?? 0)。全部：\(describe(counts))", file: file, line: line)
        }
        for (site, cap) in budget where (counts[site] ?? 0) < cap {
            print("[budget] 可下调：\(name) \(site) 上限 \(cap)，实测 \(counts[site] ?? 0)")
        }
    }

    private func preview(_ h: PromptRealPathHarness) {
        let turn = h.viewModel.previewTurn(profile: h.profile, preset: h.preset, providerManager: h.providerManager,
                                    globalModelId: nil, context: h.context, excludingNodeId: h.a2.id)
        XCTAssertNotNil(turn, "previewTurn 没出结果，计数量的是空路径")
    }

    private func compose(_ h: PromptRealPathHarness) {
        _ = h.viewModel.composePrompt(profile: h.profile, preset: h.preset, excludingNodeId: h.a2.id, context: h.context,
                                      globalEntries: h.viewModel.globalWorldBookEntries, fileLibraryHint: nil, mode: .preview)
    }

    private func measure(_ size: Size) async throws -> (hint: [String: Int], compose: [String: Int], preview: [String: Int]) {
        let h = try await make(size)
        let pid = pid
        let hintCounts = counting { _ = h.viewModel.fileLibrarySystemHint(profileId: pid) }
        let composeCounts = counting { compose(h) }
        let previewCounts = counting { preview(h) }
        return (hintCounts, composeCounts, previewCounts)
    }

    // MARK: - 用例

    /// 不随库大小涨 + 棘轮上限（大库）。小库 / 大库各起一次夹具
    func testHintComposePreviewFlatAndWithinBudget() async throws {
        let s = try await measure(Self.small)
        try await cleanup()
        let l = try await measure(Self.large)

        XCTAssertEqual(describe(s.hint), describe(l.hint), "fileLibrarySystemHint 主线程碰盘随文件库大小涨了")
        XCTAssertNil(byKind(l.hint)["enumerate"], "热缓存下 hint 不该枚举")
        XCTAssertNil(byKind(l.hint)["read"], "全文回注关着，hint 不该读文件")
        XCTAssertEqual(describe(s.compose), describe(l.compose), "composePrompt 主线程碰盘随文件库大小涨了")
        XCTAssertEqual(describe(s.preview), describe(l.preview), "previewTurn 主线程碰盘随文件库大小涨了")

        assertBudget("fileLibrarySystemHint", l.hint, Self.hintBudget)
        assertBudget("composePrompt", l.compose, Self.composeBudget)
        assertBudget("previewTurn", l.preview, Self.previewBudget)
    }

    /// 确定性：同一夹具连量 3 次，计数逐字一样
    func testCountsAreDeterministic() async throws {
        let h = try await make(Self.small)
        let runs = (0..<3).map { _ in counting { preview(h) } }
        XCTAssertEqual(Set(runs.map(describe)).count, 1, "三次计数不一致：\(runs.map(describe))")
    }

    /// 冷缓存（启动后第一次 / 夹具 forget 之后）：文件库摘要恰好同步枚举一次，走已知债不判红。修了冷路径就改这条
    /// （#089：文件清单从 hint 挪到〔状态〕的目录摘要，枚举跟着挪）
    func testColdCacheHintEnumeratesOnceAsKnownDebt() async throws {
        let h = try await make(Self.small)
        FileLibraryStore.ListCache.forget(profileId: pid)
        let pid = pid
        let counts = counting { _ = h.viewModel.fileLibrarySummary(profileId: pid) }
        XCTAssertEqual(counts["enumerate FileLibraryStore.list"], 1, describe(counts))
    }
}
