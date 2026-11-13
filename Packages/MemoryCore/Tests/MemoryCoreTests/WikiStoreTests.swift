import XCTest
@testable import MemoryCore

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
        WikiPage(path: "人/小慧", kind: .person, triggers: ["小慧", "慧慧"], hook: "她提到小慧、室友、合租的时候先看这页",
                 title: "小慧", now: "室友，合租五楼（自 2026-09 起）。\n\n第二段：常一起做饭。", records: records,
                 links: [.init(target: "地点/五楼出租屋", relation: .supplement, why: "一起住过"),
                         .init(target: "人/阿明", relation: .contradiction, why: "")])
    }

    func testRelativeFilesSkipsHiddenAndExcludedEntriesWithoutOpeningThem() throws {
        try SafeWiki.write(Data("公开".utf8), name: "visible.md", in: ["主题"], under: root)
        let folder = try SafeWiki.folder(["主题"], under: root, create: false)
        for name in [".DS_Store", ".hidden", "private_fixture.md", "private_folder"] {
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(name),
                withDestinationURL: root.appendingPathComponent("does-not-exist"))
        }
        XCTAssertEqual(try wiki.relativeFiles("主题"), ["visible.md": WikiStore.version(of: Data("公开".utf8))])
    }

    func testMarkdownRoundTrip() {
        let page = sample()
        let md = page.markdown
        XCTAssertTrue(md.hasPrefix("---\n类: 人\n触发词: [小慧, 慧慧]\n钩子: 她提到小慧"))
        XCTAssertTrue(md.contains("# 小慧\n> 钩子：她提到小慧"))
        XCTAssertTrue(md.contains("- [[地点/五楼出租屋]] · 补充 · 一起住过\n"))
        XCTAssertTrue(md.contains("- [[人/阿明]] · 矛盾\n"))
        let back = WikiPage.parse(md, path: page.path)
        XCTAssertEqual(back, page)
        XCTAssertEqual(back.markdown, md)

        let empty = WikiPage(path: "工程/空", title: "空")
        XCTAssertEqual(WikiPage.parse(empty.markdown, path: empty.path), empty)
    }

    func testFactDomainFrontmatterPreservesKnownUnknownAndLegacyValues() throws {
        for domain in [SeedFactDomain.realWorld, .inWorld, .mixed, .unspecified] {
            let page = WikiPage(path: "主题/云桥城", kind: .topic, title: "云桥城", now: "设定中的旧码头", factDomain: domain)
            let parsed = WikiPage.parse(page.markdown, path: page.path)
            XCTAssertEqual(parsed, page)
            try wiki.save(page)
            XCTAssertEqual(wiki.read(page.path)?.factDomain, domain)
        }
        let invalid = "---\n事实域: fiction\n自定义: 林栖\n---\n# 云桥城\n## 现在\n旧码头"
        var page = WikiPage.parse(invalid, path: "主题/云桥城")
        XCTAssertNil(page.factDomain)
        XCTAssertEqual(page.extra?.meta, ["事实域: fiction", "自定义: 林栖"])
        page.now = "星砚在旧码头"
        try wiki.save(page)
        let rewritten = try XCTUnwrap(wiki.read(page.path))
        XCTAssertNil(rewritten.factDomain)
        XCTAssertEqual(rewritten.extra?.meta, page.extra?.meta)
        XCTAssertTrue(rewritten.markdown.contains("事实域: fiction\n"))
        page.factDomain = .inWorld
        let markdown = page.markdown
        XCTAssertEqual(markdown.components(separatedBy: "\n").filter { WikiPage.metaKey($0) == "事实域" }, ["事实域: inWorld"])
        XCTAssertTrue(markdown.contains("事实域（原写法，已换）: fiction\n"))
        try wiki.save(page)
        let classified = try XCTUnwrap(wiki.read(page.path))
        XCTAssertEqual(classified.factDomain, .inWorld)
        XCTAssertEqual(classified.extra?.meta, ["事实域（原写法，已换）: fiction", "自定义: 林栖"])
        XCTAssertEqual(classified.markdown, markdown)

        let legacy = WikiPage.parse("# 林栖", path: "人/林栖")
        XCTAssertNil(legacy.factDomain)
        XCTAssertFalse(legacy.markdown.contains("事实域:"))
        let json = #"{"path":"人/林栖","triggers":[],"hook":"","title":"林栖","now":"","records":[],"links":[]}"#
        XCTAssertNil(try JSONDecoder().decode(WikiPage.self, from: Data(json.utf8)).factDomain)
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
        - [[人/小慧]] · 共鸣 · 一起住 · 很久
        - [[主题/x]] · 替代
        """
        let page = WikiPage.parse(text, path: "地点/五楼出租屋")
        XCTAssertEqual(page.kind, .place)
        XCTAssertEqual(page.triggers, ["出租屋", "五楼"])
        XCTAssertEqual(page.hook, "她提到住的地方", "frontmatter 没钩子就看「> 钩子：」那行")
        XCTAssertEqual(page.title, "五楼出租屋", "没标题用文件名")
        XCTAssertEqual(page.now, "", "缺段当空")
        XCTAssertEqual(page.records, ["2026-10-01 看房", "2026-10-02 签约"])
        XCTAssertEqual(page.links, [.init(target: "人/小慧", relation: .resonance, why: "一起住 · 很久")])

        let bare = WikiPage.parse("随便写点", path: "工程/草稿")
        XCTAssertEqual(bare, WikiPage(path: "工程/草稿", title: "草稿", extra: .init(preamble: "随便写点")), "没有段的正文也留着")
    }

    /// astra 10-16 #3：第一段 `##` 前、标题和钩子以外的正文（备注、段落、代码围栏）原样留着，渲染时放回标题和钩子后面
    func testPreambleSurvivesProposalSave() throws {
        let path = "人/小慧"
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
        let path = "人/小慧"
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
        - [[地点/五楼]] · 补充 · 一起住
        - [[主题/x]] · 替代

        ## 我的备注
        第一行

          缩进的第二段

        ## 照片
        - 一张合照
        """
        let page = WikiPage.parse(text, path: path)
        XCTAssertEqual(page.links, [.init(target: "地点/五楼", relation: .supplement, why: "一起住")])
        XCTAssertEqual(page.extra?.meta, ["别名备注: 她自己加的", "标签:", "  - 室友", "  - 老朋友"])
        XCTAssertEqual(page.extra?.linkLines, ["- 随手写的一行", "- [[主题/x]] · 替代"])
        XCTAssertEqual(page.extra?.sections, [.init(heading: "我的备注", body: "第一行\n\n  缩进的第二段"), .init(heading: "照片", body: "- 一张合照")])
        XCTAssertEqual(page.triggers, ["小慧"], "已知键照常解析")

        let md = page.markdown
        XCTAssertEqual(WikiPage.parse(md, path: path), page)
        XCTAssertEqual(WikiPage.parse(md, path: path).markdown, md, "往返稳定")
        XCTAssertTrue(md.contains("钩子: 她提到小慧时\n别名备注: 她自己加的\n标签:\n  - 室友\n  - 老朋友\n---\n"))
        XCTAssertTrue(md.hasSuffix("## 连到\n- [[地点/五楼]] · 补充 · 一起住\n- 随手写的一行\n- [[主题/x]] · 替代\n\n## 我的备注\n第一行\n\n  缩进的第二段\n\n## 照片\n- 一张合照\n"),
                      "未知段放在连到后面、原顺序：\(md)")

        try wiki.saveRaw(text, path: path)
        var edited = try XCTUnwrap(wiki.read(path))
        edited.records.append("2026-10-15 约了复诊")
        edited.links.append(.init(target: "人/阿明", relation: .resonance, why: ""))
        try wiki.save(edited)
        let back = try XCTUnwrap(wiki.read(path))
        XCTAssertEqual(back.extra, page.extra, "提案落盘重写不丢她加的东西")
        XCTAssertEqual(back.records, ["2026-10-12 搬进五楼", "2026-10-15 约了复诊"])
        XCTAssertEqual(back.links.count, 2)
        XCTAssertNil(sample().extra)
        XCTAssertNil(WikiPage.parse(sample().markdown, path: path).extra, "没有认不出的东西 = nil")
    }

    func testPaths() throws {
        XCTAssertTrue(WikiStore.isValidPagePath("人/小慧"))
        XCTAssertTrue(WikiStore.isValidPagePath("工程/记忆宫殿"))
        for bad in ["人", "别的/x", "主题/../x", "主题/.history/x", "人//x", "主题/INDEX", "主题/x.md", "/主题/x", "主题/x/"] {
            XCTAssertFalse(WikiStore.isValidPagePath(bad), bad)
        }
        XCTAssertThrowsError(try wiki.save(WikiPage(path: "别的/x", title: "x")))
        XCTAssertTrue(WikiStore.isValidFolderPath("人"))
        XCTAssertFalse(WikiStore.isValidFolderPath(""))
    }

    /// 根下直接 9 组：本人（落盘字面量 {{user}}）+ 七类 + 工程；旧「楼层 / 工程」两支的楼层、拿名字 / 「用户」当文件夹的都不合法
    func testNineRootGroups() throws {
        XCTAssertEqual(WikiStore.branches, ["{{user}}", "人", "物", "地点", "时间", "事", "项目", "主题", "工程"])
        for good in ["{{user}}/品味", "{{user}}/行为模式/拖延曲线", "人/小雾", "地点/云桥城", "工程/记忆宫殿", "主题/电影/国产/甲"] {
            XCTAssertTrue(WikiStore.isValidPagePath(good), good)
        }
        for bad in ["楼层/人/小慧", "楼层/{{user}}/品味", "用户/品味", "岚舟/品味", "{{user}}", "人"] {
            XCTAssertFalse(WikiStore.isValidPagePath(bad), bad)
        }
        XCTAssertTrue(WikiStore.isValidFolderPath("{{user}}"))
        XCTAssertFalse(WikiStore.isValidFolderPath("楼层"))
        XCTAssertNoThrow(try wiki.save(WikiPage(path: "{{user}}/品味", kind: .user, title: "品味")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wiki.root.appendingPathComponent("{{user}}/品味.md").path), "落盘文件夹就叫 {{user}}")
    }

    /// 本人那组：落盘 {{user}}，给模型 / 人看是当前名字；改名后同一份页显示新名字，交回来的新名字路径落回 {{user}}
    func testUserBranchShownAndStored() {
        XCTAssertEqual(WikiStore.shown("{{user}}/品味", user: "岚舟"), "岚舟/品味")
        XCTAssertEqual(WikiStore.shown("- [[{{user}}/品味]] 品味", user: "星砚"), "- [[星砚/品味]] 品味", "改名后显示新名字")
        XCTAssertEqual(WikiStore.stored("星砚/品味", user: "星砚"), "{{user}}/品味")
        XCTAssertEqual(WikiStore.stored("{{user}}/品味", user: "星砚"), "{{user}}/品味", "字面量也认")
        XCTAssertEqual(WikiStore.stored("星砚", user: "星砚"), "{{user}}")
        XCTAssertEqual(WikiStore.stored("memory/wiki/星砚/品味.md", user: "星砚"), "memory/wiki/{{user}}/品味.md")
        XCTAssertEqual(WikiStore.stored("岚舟/品味", user: "星砚"), "岚舟/品味", "旧名字不认（不合法，照常被拦）")
        XCTAssertEqual(WikiStore.stored("星砚星/品味", user: "星砚"), "星砚星/品味", "只认整段")
        XCTAssertEqual(WikiStore.stored("人/小雾", user: "星砚"), "人/小雾")
    }

    /// 进：按解析器的路径位置换（不按字段名全局猜）：路径字段第一段名字 → {{user}}；别处只换明确的 [[双链]]；
    /// A 线出处的 layer、正文里长得像 JSON 的字都不动；空格写法、数组写成字符串（结构位置）也认；没东西换原样返回
    func testStoredJSONConvertsByPositionOnly() throws {
        func object(_ text: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let json = #"{"items":[{"type":"new_page","path":"星砚/品味","now":"星砚/咪咪是同一个人，见[[星砚/作息]]，原话 {\"path\":\"星砚/咪咪\"}","triggers":["星砚/咪咪"],"links":[{"to":"星砚/作息","why":"星砚/岚舟"}],"records":[{"text":"2026-10-01 说起星砚/岚舟","sources":["memory/wiki/星砚/作息.md","问卷/在做什么"],"aline":[{"layer":"星砚","window":"abcdef12"}]}]}],"covered_page":"星砚/身体","coverage":[{"input":"memory/wiki/星砚/作息.md","at":"星砚/品味 · 记录"}],"preservation":[{"page":"星砚/品味","old":"星砚/旧"}]}"#
        let back = try object(WikiStore.storedJSON(json, fields: .items, user: "星砚"))
        let item = try XCTUnwrap((back["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["path"] as? String, "{{user}}/品味")
        XCTAssertEqual(item["now"] as? String, #"星砚/咪咪是同一个人，见[[{{user}}/作息]]，原话 {"path":"星砚/咪咪"}"#, "正文只换双链，像 JSON 的字不当结构")
        XCTAssertEqual(item["triggers"] as? [String], ["星砚/咪咪"], "触发词不是路径，不换")
        let link = try XCTUnwrap((item["links"] as? [[String: Any]])?.first)
        XCTAssertEqual(link["to"] as? String, "{{user}}/作息")
        XCTAssertEqual(link["why"] as? String, "星砚/岚舟")
        let record = try XCTUnwrap((item["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["text"] as? String, "2026-10-01 说起星砚/岚舟")
        XCTAssertEqual(record["sources"] as? [String], ["memory/wiki/{{user}}/作息.md", "问卷/在做什么"])
        XCTAssertEqual((record["aline"] as? [[String: Any]])?.first?["layer"] as? String, "星砚", "A 线出处的 layer 不是路径")
        XCTAssertEqual(back["covered_page"] as? String, "{{user}}/身体", "协议里是 covered_page")
        let coverage = try XCTUnwrap((back["coverage"] as? [[String: Any]])?.first)
        XCTAssertEqual(coverage["input"] as? String, "memory/wiki/{{user}}/作息.md")
        XCTAssertEqual(coverage["at"] as? String, "{{user}}/品味 · 记录")
        let kept = try XCTUnwrap((back["preservation"] as? [[String: Any]])?.first)
        XCTAssertEqual(kept["page"] as? String, "{{user}}/品味")
        XCTAssertEqual(kept["old"] as? String, "星砚/旧")

        XCTAssertEqual(try object(WikiStore.storedJSON(#"{ "path" : "星砚" }"#, fields: .tool, user: "星砚"))["path"] as? String, "{{user}}", "空格写法也认；列本人这一组")
        XCTAssertEqual(try object(WikiStore.storedJSON(#"{"path":"星砚\/品味"}"#, fields: .tool, user: "星砚"))["path"] as? String, "{{user}}/品味")
        XCTAssertEqual(try object(WikiStore.storedJSON(#"{"aline":[{"layer":"A2","window":"x"}],"path":"A2/品味"}"#, fields: .tool, user: "A2"))["aline"] as? [[String: String]],
                       [["layer": "A2", "window": "x"]], "用户名叫 A2 时 A 线层也不动")
        let untouched = #"{"now":"星砚/咪咪是同一个人","triggers":["星砚/咪咪"]}"#
        XCTAssertEqual(WikiStore.storedJSON(untouched, fields: .items, user: "星砚"), untouched, "没有要换的原样（不重新编码）")
        let stringItems = #"{"items":"[{\"path\":\"星砚/品味\"}]"}"#
        let nested = try XCTUnwrap(try object(WikiStore.storedJSON(stringItems, fields: .items, user: "星砚"))["items"] as? String)
        XCTAssertTrue(nested.contains("{{user}}/品味"), "结构位置上数组写成字符串的也换")
        let sorter = try object(WikiStore.storedJSON(#"{"fragments":[{"f":"f1","page":"星砚/身体"},{"f":"f2","new":{"path":"星砚/作息","title":"星砚/作息"}},{"f":"f3","stash":"星砚/x"}],"timeline_proposals":[{"path":"星砚/毕设"}]}"#, fields: .sorter, user: "星砚"))
        let verdicts = try XCTUnwrap(sorter["fragments"] as? [[String: Any]])
        XCTAssertEqual(verdicts[0]["page"] as? String, "{{user}}/身体")
        XCTAssertEqual((verdicts[1]["new"] as? [String: Any])?["path"] as? String, "{{user}}/作息")
        XCTAssertEqual((verdicts[1]["new"] as? [String: Any])?["title"] as? String, "星砚/作息")
        XCTAssertEqual(verdicts[2]["stash"] as? String, "星砚/x")
        XCTAssertEqual(((sorter["timeline_proposals"] as? [[String: Any]])?.first?["path"]) as? String, "{{user}}/毕设")
        let regroup = try object(WikiStore.storedJSON(#"{"groups":[{"name":"星砚/x","members":["星砚/身体","人/小雾"]}]}"#, fields: .regroup, user: "星砚"))
        XCTAssertEqual(((regroup["groups"] as? [[String: Any]])?.first?["members"]) as? [String], ["{{user}}/身体", "人/小雾"])
    }

    /// 出：工具定义在值上换名字再编码；名字带引号 / 反斜杠的退成「用户」（拼进提示词的 JSON 行也不坏）
    func testShownValueAndQuotedName() throws {
        let schema: [String: Any] = ["name": "x", "parameters": ["properties": ["path": ["enum": ["{{user}}/品味"], "description": "放 {{user}}/ 下"]]]]
        let shown = try XCTUnwrap(WikiStore.shownValue(schema, user: "星砚") as? [String: Any])
        let props = try XCTUnwrap(((shown["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["path"] as? [String: Any])
        XCTAssertEqual(props["enum"] as? [String], ["星砚/品味"])
        XCTAssertEqual(props["description"] as? String, "放 星砚/ 下")
        XCTAssertEqual(WikiStore.userLabel(#"小"米"#), "用户")
        XCTAssertEqual(WikiStore.userLabel(#"小\米"#), "用户")
        let line = WikiStore.shown(#"{"path":"{{user}}/品味"}"#, user: #"小"米"#)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)), "提示词里的 JSON 行还是合格 JSON")
    }



    /// 编辑器保存按编辑差异逐行对上原文：显示一样的重复行（名字 / 宏）各自保留原文；只改其中一行时别的照旧
    func testStoredEditKeepsDuplicateLinesIdentity() {
        for raw in ["称呼：粟粟\n称呼：{{user}}", "称呼：{{user}}\n称呼：粟粟"] {
            let shown = WikiStore.shown(raw, user: "粟粟")
            XCTAssertEqual(WikiStore.storedEdit(shown + "\n新行", original: raw, user: "粟粟"), raw + "\n新行", raw)
            XCTAssertEqual(WikiStore.storedEdit("开头\n" + shown, original: raw, user: "粟粟"), "开头\n" + raw, "前面插一行也对得上")
        }
        let raw = "称呼：{{user}}\n中间\n称呼：粟粟\n[[{{user}}/作息]]"
        let edited = WikiStore.shown(raw, user: "粟粟").replacingOccurrences(of: "中间", with: "中间改了")
        XCTAssertEqual(WikiStore.storedEdit(edited, original: raw, user: "粟粟"), "称呼：{{user}}\n中间改了\n称呼：粟粟\n[[{{user}}/作息]]")
        XCTAssertEqual(WikiStore.storedEdit("称呼：粟粟\n称呼：粟粟\n[[粟粟/作息]]", original: raw, user: "粟粟"), "称呼：{{user}}\n称呼：粟粟\n[[{{user}}/作息]]",
                       "删掉的行不占位；剩下的按顺序对上原文")
    }

    /// 名字空的、和别的组同名的（叫「人」）、带斜杠的：本人那组显示成「用户」，不和任何组撞
    func testUserLabelFallback() {
        XCTAssertEqual(WikiStore.userLabel("  岚舟 "), "岚舟")
        for raw in ["", "  ", "人", "工程", "a/b", ".x", "{{user}}"] { XCTAssertEqual(WikiStore.userLabel(raw), "用户", raw) }
        XCTAssertFalse(WikiStore.branches.contains("用户"))
        XCTAssertEqual(WikiStore.shown("{{user}}/品味", user: "人"), "用户/品味")
        XCTAssertEqual(WikiStore.stored("用户/品味", user: "人"), "{{user}}/品味")
        XCTAssertEqual(WikiStore.stored("人/小雾", user: "人"), "人/小雾", "叫「人」时人那组照旧")
    }

    func testVersionAndRead() throws {
        XCTAssertNil(wiki.version(of: "人/小慧"))
        XCTAssertNil(wiki.read("人/小慧"))
        let v = try wiki.save(sample())
        XCTAssertEqual(wiki.version(of: "人/小慧"), v)
        XCTAssertEqual(v, WikiStore.version(of: Data(sample().markdown.utf8)))
        XCTAssertEqual(wiki.read("人/小慧"), sample())
        XCTAssertTrue(wiki.history("人/小慧").isEmpty, "新页没有旧版")
    }

    func testSnapshotAvoidsDestinationHistoryCollisionWithoutLeavingExtraCopies() async throws {
        let source = sample().path, target = "人/远港", wiki = wiki!, now = t0
        try wiki.save(sample(), now: t0)
        try wiki.save(WikiPage(path: target, title: "远港"), now: t0)
        let snapshots = try await Task.detached {
            let existing = try XCTUnwrap(wiki.snapshotCurrent(target, now: now))
            let entry = try XCTUnwrap(wiki.snapshotCurrent(source, now: now, avoidingHistoryAt: target))
            return (existing, entry)
        }.value
        let (existing, entry) = snapshots
        XCTAssertNotEqual(entry, existing)
        XCTAssertEqual(wiki.history(source).map(\.name), [entry])
        XCTAssertEqual(wiki.historyText(source, entry: entry), sample().markdown)
        XCTAssertEqual(wiki.history(target).map(\.name), [existing])
    }

    func testHistorySnapshotsAndRestore() throws {
        let path = "人/小慧"
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

        let restored = try wiki.restore(path, entry: entries[2].name, expectedVersion: wiki.version(of: path),
                                        now: t0.addingTimeInterval(7200))
        XCTAssertEqual(wiki.readRaw(path), v1)
        XCTAssertEqual(wiki.version(of: path), restored)
        XCTAssertEqual(wiki.history(path).count, 4, "恢复前当前版也存一版")
        XCTAssertEqual(WikiPage.parse(wiki.historyText(path, entry: wiki.history(path)[0].name) ?? "", path: path).now, "第四版")
        XCTAssertThrowsError(try wiki.restore(path, entry: "nope.md", expectedVersion: restored))
    }

    func testHistoryRestoreRejectsChangedOrDeletedPageWithoutWriting() throws {
        let path = "主题/虚构航线"
        try wiki.saveRaw("历史原文", path: path, now: t0)
        let openedVersion = try wiki.saveRaw("打开时原文", path: path, now: t0.addingTimeInterval(1))
        let entry = try XCTUnwrap(wiki.history(path).first)
        try wiki.saveRaw("别处改稿", path: path, now: t0.addingTimeInterval(2))
        let history = wiki.history(path)
        XCTAssertThrowsError(try wiki.restore(path, entry: entry.name, expectedVersion: openedVersion)) {
            guard case .conflict(let target, _) = $0 as? WikiStore.WikiError else { return XCTFail("应报版本冲突") }
            XCTAssertEqual(target, path)
        }
        XCTAssertEqual(wiki.readRaw(path), "别处改稿")
        XCTAssertEqual(wiki.history(path), history)

        try FileManager.default.removeItem(at: wiki.pageURL(path))
        XCTAssertThrowsError(try wiki.restore(path, entry: entry.name, expectedVersion: openedVersion)) {
            guard case .conflict(let target, _) = $0 as? WikiStore.WikiError else { return XCTFail("应报删除冲突") }
            XCTAssertEqual(target, path)
        }
        XCTAssertFalse(wiki.pageExists(path))
        XCTAssertEqual(wiki.history(path), history)
    }

    func testRecordsAppendOnly() throws {
        let path = "人/小慧"
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
        try WikiStore.writeAtomic(Data("# x".utf8), to: root.appendingPathComponent("主题/INDEX.md"))
        XCTAssertEqual(wiki.pagePaths(), ["人/小慧", "工程/记忆宫殿"])
        XCTAssertEqual(wiki.pagePaths(under: "人"), ["人/小慧"])
    }
}
