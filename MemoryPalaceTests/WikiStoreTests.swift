import XCTest
@testable import 记忆花园

/// C3 wiki 存储（plan-memory-c3-catalog 2.1）：md 往返、宽容读、历史快照 / 恢复、记录只追加、不触发的词
final class WikiStoreTests: XCTestCase {

    private var root: URL!
    private var wiki: WikiStore!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-store-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sample(records: [String] = ["2026-10-12 搬进五楼（出处：窗口《搬家》第 3 条）（到 2026-10-22）"]) -> WikiPage {
        WikiPage(path: "楼层/人/小慧", kind: .person, triggers: ["小慧", "慧慧"], hook: "她提到小慧、室友、合租的时候先看这页",
                 title: "小慧", now: "室友，合租五楼（自 2026-09 起）。\n\n第二段：常一起做饭。", records: records,
                 links: [.init(target: "楼层/地点/五楼出租屋", relation: .supplement, why: "一起住过"),
                         .init(target: "楼层/人/阿明", relation: .contradiction, why: "")])
    }

    func testMarkdownRoundTrip() {
        let page = sample()
        let md = page.markdown
        XCTAssertTrue(md.hasPrefix("---\n类: 人\n触发词: [小慧, 慧慧]\n钩子: 她提到小慧"))
        XCTAssertTrue(md.contains("# 小慧\n> 钩子：她提到小慧"))
        XCTAssertTrue(md.contains("- [[楼层/地点/五楼出租屋]] · 补充 · 一起住过\n"))
        XCTAssertTrue(md.contains("- [[楼层/人/阿明]] · 矛盾\n"))
        let back = WikiPage.parse(md, path: page.path)
        XCTAssertEqual(back, page)
        XCTAssertEqual(back.markdown, md)

        let empty = WikiPage(path: "工程/空", title: "空")
        XCTAssertEqual(WikiPage.parse(empty.markdown, path: empty.path), empty)
    }

    func testTolerantParse() {
        let text = """
        ---
        类：地点  # 手写注释
        触发词:
          - 出租屋
          - 五楼
        ---
        > 钩子：她提到住的地方

        ## 记录
        * 2026-10-01 看房
        2026-10-02 签约

        ## 连到
        - 随手写的一行
        - [[楼层/人/小慧]] · 共鸣 · 一起住 · 很久
        - [[楼层/x]] · 替代
        """
        let page = WikiPage.parse(text, path: "楼层/地点/五楼出租屋")
        XCTAssertEqual(page.kind, .place)
        XCTAssertEqual(page.triggers, ["出租屋", "五楼"])
        XCTAssertEqual(page.hook, "她提到住的地方", "frontmatter 没钩子就看「> 钩子：」那行")
        XCTAssertEqual(page.title, "五楼出租屋", "没标题用文件名")
        XCTAssertEqual(page.now, "", "缺段当空")
        XCTAssertEqual(page.records, ["2026-10-01 看房", "2026-10-02 签约"])
        XCTAssertEqual(page.links, [.init(target: "楼层/人/小慧", relation: .resonance, why: "一起住 · 很久")])

        let bare = WikiPage.parse("随便写点", path: "工程/草稿")
        XCTAssertEqual(bare, WikiPage(path: "工程/草稿", title: "草稿", extra: .init(preamble: "随便写点")), "没有段的正文也留着")
    }

    /// astra 10-16 #3：第一段 `##` 前、标题和钩子以外的正文（备注、段落、代码围栏）原样留着，渲染时放回标题和钩子后面
    func testPreambleSurvivesProposalSave() throws {
        let path = "楼层/人/小慧"
        let text = """
        ---
        类: 人
        触发词: [小慧]
        钩子: 她提到小慧时
        ---
        # 小慧
        > 钩子：她提到小慧时
        > 她自己加的引用

        我的备注：别在她面前提搬家。

        第二段，空一行。
        ```swift
        ## 这不是段标题
        let x = 1
        ```

        ## 现在
        室友（自 2026-09 起）。

        ## 记录
        - 2026-10-12 搬进五楼
        """
        let page = WikiPage.parse(text, path: path)
        XCTAssertEqual(page.extra?.preamble, """
        > 她自己加的引用

        我的备注：别在她面前提搬家。

        第二段，空一行。
        ```swift
        ## 这不是段标题
        let x = 1
        ```
        """)
        XCTAssertEqual(page.extra?.sections, [], "围栏里的 ## 不当段标题")
        XCTAssertEqual(page.now, "室友（自 2026-09 起）。")
        XCTAssertTrue(page.markdown.contains("> 钩子：她提到小慧时\n\n> 她自己加的引用\n\n我的备注"), "放回标题和钩子后面、第一段 ## 前面")
        XCTAssertEqual(WikiPage.parse(page.markdown, path: path), page, "往返不变")

        try wiki.saveRaw(text, path: path)
        var appended = try XCTUnwrap(wiki.read(path))
        appended.records.append("2026-10-13 一起做饭")
        try wiki.save(appended)
        let after = try XCTUnwrap(wiki.read(path))
        XCTAssertEqual(after.extra?.preamble, page.extra?.preamble, "批一条无关的改动，前言不丢")
        XCTAssertEqual(after.records, ["2026-10-12 搬进五楼", "2026-10-13 一起做饭"])
    }

    func testUnknownPartsSurviveRewrite() throws {
        let path = "楼层/人/小慧"
        let text = """
        ---
        类: 人
        别名备注: 她自己加的
        触发词: [小慧]
        标签:
          - 室友
          - 老朋友
        钩子: 她提到小慧时
        ---
        # 小慧
        > 钩子：她提到小慧时

        ## 现在
        室友（自 2026-09 起）。

        ## 记录
        - 2026-10-12 搬进五楼

        ## 连到
        - 随手写的一行
        - [[楼层/地点/五楼]] · 补充 · 一起住
        - [[楼层/x]] · 替代

        ## 我的备注
        第一行

          缩进的第二段

        ## 照片
        - 一张合照
        """
        let page = WikiPage.parse(text, path: path)
        XCTAssertEqual(page.links, [.init(target: "楼层/地点/五楼", relation: .supplement, why: "一起住")])
        XCTAssertEqual(page.extra?.meta, ["别名备注: 她自己加的", "标签:", "  - 室友", "  - 老朋友"])
        XCTAssertEqual(page.extra?.linkLines, ["- 随手写的一行", "- [[楼层/x]] · 替代"])
        XCTAssertEqual(page.extra?.sections, [.init(heading: "我的备注", body: "第一行\n\n  缩进的第二段"), .init(heading: "照片", body: "- 一张合照")])
        XCTAssertEqual(page.triggers, ["小慧"], "已知键照常解析")

        let md = page.markdown
        XCTAssertEqual(WikiPage.parse(md, path: path), page)
        XCTAssertEqual(WikiPage.parse(md, path: path).markdown, md, "往返稳定")
        XCTAssertTrue(md.contains("钩子: 她提到小慧时\n别名备注: 她自己加的\n标签:\n  - 室友\n  - 老朋友\n---\n"))
        XCTAssertTrue(md.hasSuffix("## 连到\n- [[楼层/地点/五楼]] · 补充 · 一起住\n- 随手写的一行\n- [[楼层/x]] · 替代\n\n## 我的备注\n第一行\n\n  缩进的第二段\n\n## 照片\n- 一张合照\n"),
                      "未知段放在连到后面、原顺序：\(md)")

        try wiki.saveRaw(text, path: path)
        var edited = try XCTUnwrap(wiki.read(path))
        edited.records.append("2026-10-15 约了复诊")
        edited.links.append(.init(target: "楼层/人/阿明", relation: .resonance, why: ""))
        try wiki.save(edited)
        let back = try XCTUnwrap(wiki.read(path))
        XCTAssertEqual(back.extra, page.extra, "提案落盘重写不丢她加的东西")
        XCTAssertEqual(back.records, ["2026-10-12 搬进五楼", "2026-10-15 约了复诊"])
        XCTAssertEqual(back.links.count, 2)
        XCTAssertNil(sample().extra)
        XCTAssertNil(WikiPage.parse(sample().markdown, path: path).extra, "没有认不出的东西 = nil")
    }

    func testPaths() throws {
        XCTAssertTrue(WikiStore.isValidPagePath("楼层/人/小慧"))
        XCTAssertTrue(WikiStore.isValidPagePath("工程/记忆宫殿"))
        for bad in ["楼层", "别的/x", "楼层/../x", "楼层/.history/x", "楼层//x", "楼层/INDEX", "楼层/x.md", "/楼层/x", "楼层/x/"] {
            XCTAssertFalse(WikiStore.isValidPagePath(bad), bad)
        }
        XCTAssertThrowsError(try wiki.save(WikiPage(path: "别的/x", title: "x")))
        XCTAssertTrue(WikiStore.isValidFolderPath("楼层"))
        XCTAssertFalse(WikiStore.isValidFolderPath(""))
    }

    func testVersionAndRead() throws {
        XCTAssertNil(wiki.version(of: "楼层/人/小慧"))
        XCTAssertNil(wiki.read("楼层/人/小慧"))
        let v = try wiki.save(sample())
        XCTAssertEqual(wiki.version(of: "楼层/人/小慧"), v)
        XCTAssertEqual(v, WikiStore.version(of: Data(sample().markdown.utf8)))
        XCTAssertEqual(wiki.read("楼层/人/小慧"), sample())
        XCTAssertTrue(wiki.history("楼层/人/小慧").isEmpty, "新页没有旧版")
    }

    func testHistorySnapshotsAndRestore() throws {
        let path = "楼层/人/小慧"
        var page = sample()
        try wiki.save(page, now: t0)
        let v1 = page.markdown
        page.now = "第二版"
        try wiki.save(page, now: t0)
        XCTAssertEqual(try wiki.save(page, now: t0), wiki.version(of: path), "内容没变不写、不存历史")
        page.now = "第三版"
        try wiki.save(page, now: t0)
        page.now = "第四版"
        try wiki.save(page, now: t0.addingTimeInterval(3600))

        let entries = wiki.history(path)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries[1].name.hasSuffix("-2.md"), "同秒加序号：\(entries.map(\.name))")
        XCTAssertEqual(wiki.historyText(path, entry: entries[2].name), v1, "新→旧，最后一个是第一版")
        XCTAssertEqual(WikiPage.parse(wiki.historyText(path, entry: entries[0].name) ?? "", path: path).now, "第三版")
        XCTAssertNotNil(entries[0].date)

        let restored = try wiki.restore(path, entry: entries[2].name, now: t0.addingTimeInterval(7200))
        XCTAssertEqual(wiki.readRaw(path), v1)
        XCTAssertEqual(wiki.version(of: path), restored)
        XCTAssertEqual(wiki.history(path).count, 4, "恢复前当前版也存一版")
        XCTAssertEqual(WikiPage.parse(wiki.historyText(path, entry: wiki.history(path)[0].name) ?? "", path: path).now, "第四版")
        XCTAssertThrowsError(try wiki.restore(path, entry: "nope.md"))
    }

    func testRecordsAppendOnly() throws {
        let path = "楼层/人/小慧"
        var page = sample(records: ["a", "b"])
        try wiki.save(page)
        page.records = ["a", "b", "c"]
        XCTAssertNoThrow(try wiki.save(page))
        page.records = ["a", "c"]
        XCTAssertThrowsError(try wiki.save(page)) { XCTAssertEqual($0 as? WikiStore.WikiError, .recordsNotAppendOnly(path)) }
        page.records = ["改了 a", "b", "c"]
        XCTAssertThrowsError(try wiki.save(page))
        XCTAssertEqual(wiki.read(path)?.records, ["a", "b", "c"], "拒了不写")

        let before = wiki.history(path).count
        try wiki.saveRaw(page.markdown, path: path)
        XCTAssertEqual(wiki.read(path)?.records, ["改了 a", "b", "c"], "编辑器入口不校验")
        XCTAssertEqual(wiki.history(path).count, before + 1, "照样存历史")
    }

    func testStopWords() throws {
        XCTAssertEqual(wiki.stopWords(), [])
        try wiki.setStopWords([" 电影 ", "", "今天", "电影", "  "])
        XCTAssertEqual(wiki.stopWords(), ["电影", "今天"])
        XCTAssertEqual(String(decoding: try Data(contentsOf: wiki.stopWordsURL), as: UTF8.self), "电影\n今天\n")
        try "a\n\n a\r\nb\n".write(to: wiki.stopWordsURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(wiki.stopWords(), ["a", "b"])
    }

    func testPagePathsSkipHidden() throws {
        try wiki.save(sample())
        try wiki.save(WikiPage(path: "工程/记忆宫殿", title: "记忆宫殿"))
        var page = sample()
        page.now = "改"
        try wiki.save(page)
        try wiki.setStopWords(["x"])
        try WikiStore.writeAtomic(Data("{}".utf8), to: root.appendingPathComponent(".proposals/a.json"))
        try WikiStore.writeAtomic(Data("# x".utf8), to: root.appendingPathComponent("楼层/INDEX.md"))
        XCTAssertEqual(wiki.pagePaths(), ["工程/记忆宫殿", "楼层/人/小慧"])
        XCTAssertEqual(wiki.pagePaths(under: "楼层"), ["楼层/人/小慧"])
    }
}
