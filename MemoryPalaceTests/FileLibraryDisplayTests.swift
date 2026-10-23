import XCTest
@testable import 记忆花园

/// 文件库 v2 列表层显示（plan-file-library-v2 §4 / §2 / §11）
final class FileLibraryDisplayTests: XCTestCase {

    private let vocab = """
    ---
    level: B2
    pos: 形容词
    created: 2026-09-28T10:00:00
    ---
    # ephemeral

    短暂的，转瞬即逝的。

    **小岚**说像夏天傍晚的那阵凉风。
    """

    func testMarkdownTitleUsesFirstHeadingAfterFrontmatter() {
        XCTAssertEqual(FileLibraryDisplay.title(path: "vocab/ephemeral.md", preview: vocab), "ephemeral")
    }

    func testMarkdownTitleFallsBackToStem() {
        XCTAssertEqual(FileLibraryDisplay.title(path: "trading/持仓总表.md", preview: "NVDA 8%"), "持仓总表")
        XCTAssertEqual(FileLibraryDisplay.title(path: "a/b.md", preview: nil), "b")
        XCTAssertEqual(FileLibraryDisplay.title(path: "x.md", preview: "## 二级不算\n正文"), "x")
    }

    func testTruncatedFrontmatterIsNotBody() {
        let cut = "---\nlevel: B2\npos: 形容词\nnote: 很长很长"
        XCTAssertEqual(FileLibraryDisplay.title(path: "v/w.md", preview: cut), "w")
        XCTAssertNil(FileLibraryDisplay.summary(path: "v/w.md", preview: cut))
    }

    func testHTMLTitlePrefersTitleThenH1() {
        let t = "<html><head><title>光合作用 &middot; 第 2 课</title></head><body><h1>别的</h1></body>"
        XCTAssertEqual(FileLibraryDisplay.title(path: "学堂/x/课堂笔记.html", preview: t), "光合作用 · 第 2 课")
        let h = "<body><h1 class=\"a\">细胞<b>分裂</b></h1><p>有丝分裂</p></body>"
        XCTAssertEqual(FileLibraryDisplay.title(path: "s.html", preview: h), "细胞 分裂")
        XCTAssertEqual(FileLibraryDisplay.title(path: "dir/s.htm", preview: "<style>p{}</style>"), "s")
        XCTAssertEqual(FileLibraryDisplay.title(path: "\(StudyTemplate.noteRoot)/细胞分裂/\(StudyTemplate.noteFileName)", preview: "<meta charset=utf-8>"), "细胞分裂")
    }

    func testHTMLSummarySkipsHeadAndStyle() {
        let h = "<html><head><style>body{color:red}</style></head><body><h1>标题</h1><p>叶绿体里发生两段反应</p><p>第二段</p>"
        XCTAssertEqual(FileLibraryDisplay.summary(path: "a.html", preview: h), "叶绿体里发生两段反应")
    }

    func testHTMLPreviewSkipsLongHeadStyle() {
        let css = String(repeating: ".node{fill:#e8f0e8;stroke:#333} ", count: 70)
        XCTAssertGreaterThan(css.count, 2000)
        let raw = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>关系拓扑</title><style>\(css)</style></head><body><h1>关系拓扑</h1><p>小岚和花园的三条线</p><p>第二段</p></body></html>"
        XCTAssertNil(FileLibraryDisplay.summary(path: "关系拓扑.html", preview: String(raw.prefix(280))))
        let preview = FileLibraryDisplay.previewText(path: "关系拓扑.html", raw: raw)
        XCTAssertLessThanOrEqual(preview.count, 280)
        let entry = FileLibraryDisplay.entry(path: "关系拓扑.html", preview: preview)
        XCTAssertEqual(entry.title, "关系拓扑")
        XCTAssertEqual(entry.summary, "小岚和花园的三条线")
        XCTAssertEqual(entry.lines, ["小岚和花园的三条线", "第二段"])
        XCTAssertEqual(FileLibraryDisplay.previewText(path: "a.md", raw: raw), String(raw.prefix(280)))
    }

    func testNonMarkdownTitlesKeepExtension() {
        XCTAssertEqual(FileLibraryDisplay.title(path: "trading/snapshot.json", preview: "{}"), "snapshot.json")
        XCTAssertEqual(FileLibraryDisplay.title(path: "attachments/海边.jpg", preview: nil), "海边.jpg")
    }

    func testSummaryStripsMarkdownAndSkipsTitle() {
        XCTAssertEqual(FileLibraryDisplay.summary(path: "vocab/ephemeral.md", preview: vocab), "短暂的，转瞬即逝的。")
        let lines = FileLibraryDisplay.bodyLines(path: "vocab/ephemeral.md", preview: vocab, limit: 3)
        XCTAssertEqual(lines, ["短暂的，转瞬即逝的。", "小岚说像夏天傍晚的那阵凉风。"])
        let md = "# T\n---\n> - [链接](http://x) 和 [[双链|别名]] `代码`\n"
        XCTAssertEqual(FileLibraryDisplay.summary(path: "n.md", preview: md), "链接 和 双链 代码")
        XCTAssertEqual(FileLibraryDisplay.summary(path: "n.md", preview: "# T\n## 释义\n"), "释义")
        XCTAssertNil(FileLibraryDisplay.summary(path: "snap.json", preview: "{\"a\":1}"))
        XCTAssertEqual(FileLibraryDisplay.summary(path: "a.txt", preview: "\n\n第一行\n第二行"), "第一行")
    }

    func testChipsShortFieldsFirstThree() {
        XCTAssertEqual(FileLibraryDisplay.chips(path: "vocab/ephemeral.md", preview: vocab), ["B2", "形容词"])
        let many = "---\na: 一\nb: 二\nc: 这个值超过八个字了啊啊\nd: 三\ne: 四\ntitle: x\n---\n# x\n"
        XCTAssertEqual(FileLibraryDisplay.chips(path: "n.md", preview: many), ["一", "二", "三"])
        XCTAssertEqual(FileLibraryDisplay.chips(path: "n.html", preview: many), [])
    }

    func testSystemFolderMapping() {
        XCTAssertEqual(FileLibraryFolderStyle.displayName(forFolder: "vocab"), "词条笔记")
        XCTAssertEqual(FileLibraryFolderStyle.displayName(forFolder: StudyTemplate.noteRoot), "学堂笔记")
        XCTAssertEqual(FileLibraryFolderStyle.displayName(forFolder: "trading"), "投研")
        XCTAssertEqual(FileLibraryFolderStyle.displayName(forFolder: "attachments"), "聊天附件")
        XCTAssertEqual(FileLibraryFolderStyle.displayName(forFolder: "trading/NVDA"), "NVDA")
        XCTAssertEqual(FileLibraryFolderStyle.displayName(forFolder: "随便"), "随便")
        XCTAssertNil(FileLibraryFolderStyle.system("study"))
        XCTAssertEqual(FileLibraryFolderStyle.forFolder("随便"), .plain)
        XCTAssertEqual(FileLibraryFolderStyle.forFile("trading/NVDA/a.md").tint, FileLibraryFolderStyle.system("trading")?.tint)
        XCTAssertEqual(FileLibraryFolderStyle.forFile("trading.md"), .plain)
    }

    func testFolderContents() {
        let d = { (s: Double) in Date(timeIntervalSince1970: s) }
        let files = [
            FileLibraryStore.FileMeta(path: "trading/持仓.md", bytes: 1, modifiedAt: d(50)),
            FileLibraryStore.FileMeta(path: "trading/NVDA/a.md", bytes: 1, modifiedAt: d(10)),
            FileLibraryStore.FileMeta(path: "trading/NVDA/b.md", bytes: 1, modifiedAt: d(30)),
            FileLibraryStore.FileMeta(path: "trading/img/x.png", bytes: 1, modifiedAt: d(5)),
            FileLibraryStore.FileMeta(path: "tradingx/y.md", bytes: 1, modifiedAt: d(5)),
            FileLibraryStore.FileMeta(path: "根.md", bytes: 1, modifiedAt: d(1)),
        ]
        let root = FileLibraryDisplay.contents(of: "", in: files)
        XCTAssertEqual(root.folders.map(\.path), ["trading", "tradingx"])
        XCTAssertEqual(root.folders.first?.fileCount, 4)
        XCTAssertEqual(root.folders.first?.latest, d(50))
        XCTAssertEqual(root.files.map(\.path), ["根.md"])
        let t = FileLibraryDisplay.contents(of: "trading", in: files)
        XCTAssertEqual(t.folders.map(\.path), ["trading/NVDA", "trading/img"])
        XCTAssertEqual(t.folders.first?.latest, d(30))
        XCTAssertEqual(t.folders.last?.imageCount, 1)
        XCTAssertEqual(t.files.map(\.path), ["trading/持仓.md"])
        let empty = FileLibraryDisplay.contents(of: "空", in: files)
        XCTAssertTrue(empty.folders.isEmpty && empty.files.isEmpty)
        XCTAssertEqual(FileLibraryDisplay.breadcrumb("trading/NVDA").map(\.path), ["", "trading", "trading/NVDA"])
    }

    func testFolderIndexMatchesContents() {
        let d = { (s: Double) in Date(timeIntervalSince1970: s) }
        let files = [
            FileLibraryStore.FileMeta(path: "trading/持仓.md", bytes: 1, modifiedAt: d(50)),
            FileLibraryStore.FileMeta(path: "trading/NVDA/a.md", bytes: 1, modifiedAt: d(10)),
            FileLibraryStore.FileMeta(path: "trading/NVDA/b.md", bytes: 1, modifiedAt: d(30)),
            FileLibraryStore.FileMeta(path: "trading/img/x.png", bytes: 1, modifiedAt: d(5)),
            FileLibraryStore.FileMeta(path: "根.md", bytes: 1, modifiedAt: d(1)),
        ]
        let index = FileLibraryDisplay.folderIndex(files)
        for folder in ["", "trading", "trading/NVDA", "trading/img"] {
            let a = index[folder]
            let b = FileLibraryDisplay.contents(of: folder, in: files)
            XCTAssertEqual(a?.folders, b.folders, folder)
            XCTAssertEqual(a?.files.map(\.path), b.files.map(\.path), folder)
        }
        XCTAssertNil(index["空"])
    }

    func testEntryMatchesIndividualFunctions() {
        let e = FileLibraryDisplay.entry(path: "vocab/ephemeral.md", preview: vocab)
        XCTAssertEqual(e.title, "ephemeral")
        XCTAssertEqual(e.summary, "短暂的，转瞬即逝的。")
        XCTAssertEqual(e.chips, ["B2", "形容词"])
        XCTAssertEqual(e.lines, ["短暂的，转瞬即逝的。", "小岚说像夏天傍晚的那阵凉风。"])
        XCTAssertEqual(FileLibraryDisplay.snippet(in: e.searchText, query: "凉风", before: 2, length: 6), "…那阵凉风。")
        XCTAssertEqual(FileLibraryDisplay.entry(path: "a.json", preview: "{\n\"a\": 1\n}").lines, ["{", "\"a\": 1", "}"])
        XCTAssertEqual(FileLibraryDisplay.entry(path: "a.png", preview: nil).title, "a.png")
    }

    func testBadge() {
        XCTAssertEqual(FileLibraryDisplay.badge("a.md"), "MD")
        XCTAssertEqual(FileLibraryDisplay.badge("a.HTM"), "HTML")
        XCTAssertEqual(FileLibraryDisplay.badge("a.json"), "JSON")
        XCTAssertEqual(FileLibraryDisplay.badge("a.jpeg"), "JPG")
        XCTAssertEqual(["a.png", "b.JPG", "c.heic", "d.gif", "e.webp"].map(FileLibraryDisplay.badge), ["PNG", "JPG", "HEIC", "GIF", "WEBP"])
        XCTAssertEqual(FileLibraryDisplay.badge("a.pdf"), "PDF")
    }

    func testSearchSnippet() {
        let s = FileLibraryDisplay.searchSnippet(path: "n.md", preview: "# 标题\n今天下了一整天的雨，窗台那盆绿萝在做光合作用，你说它也在等太阳。", query: "光合", before: 6, length: 16)
        XCTAssertEqual(s, "…那盆绿萝在做光合作用，你说它也在…")
        XCTAssertEqual(FileLibraryDisplay.searchSnippet(path: "n.md", preview: "光合作用", query: "光合"), "光合作用")
        XCTAssertNil(FileLibraryDisplay.searchSnippet(path: "n.md", preview: "无关", query: "光合"))
        let html = "<head><title>光合</title><style>body{font-family:x}</style></head><body><p>叶绿体做光合作用</p>"
        XCTAssertEqual(FileLibraryDisplay.searchSnippet(path: "a.html", preview: html, query: "光合", before: 3, length: 10), "…绿体做光合作用")
        XCTAssertNil(FileLibraryDisplay.searchSnippet(path: "a.html", preview: html, query: "font"))
    }

    func testTimeText() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 15, minute: 30))!
        func t(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> String {
            FileLibraryDisplay.timeText(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!, now: now, calendar: cal)
        }
        XCTAssertEqual(t(2026, 10, 1, 15, 18), "12 分钟前")
        XCTAssertEqual(t(2026, 10, 1, 15, 30), "1 分钟前")
        XCTAssertEqual(t(2026, 10, 1, 9, 5), "09:05")
        XCTAssertEqual(t(2026, 9, 30, 23, 59), "昨天")
        XCTAssertEqual(t(2026, 9, 28, 8, 0), "9月28日")
        XCTAssertEqual(t(2025, 12, 31, 8, 0), "2025年12月31日")
    }
}
