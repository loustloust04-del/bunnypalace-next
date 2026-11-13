import MemoryCore
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
        WikiPage(path: "人/小慧", kind: .person, triggers: ["小慧", "慧慧"], hook: "她提到小慧、室友、合租的时候先看这页",
                 title: "小慧", now: "室友，合租五楼（自 2026-09 起）。\n\n第二段：常一起做饭。", records: records,
                 links: [.init(target: "地点/五楼出租屋", relation: .supplement, why: "一起住过"),
                         .init(target: "人/阿明", relation: .contradiction, why: "")])
    }

    func testFactDomainAndMarkedRecordsSurviveSaveReadSaveAndHistoryRestore() throws {
        for (index, domain) in [SeedFactDomain.realWorld, .inWorld, .mixed, .unspecified].enumerated() {
            let path = "主题/云桥城\(index)"
            let marker = domain == .realWorld ? "" : domain == .inWorld ? "设定 · " : "待判 · "
            let source = "memory/cc/虚构航线（副本）.md"
            let records = ["2026-10-09 · \(marker)云桥城夜航（\(source)）"]
            var page = WikiPage(path: path, title: "云桥城", now: "虚构航线概览。", records: records, factDomain: domain)
            try wiki.save(page, now: t0)
            let first = try XCTUnwrap(wiki.read(path))
            XCTAssertEqual(first.factDomain, domain)
            XCTAssertEqual(first.records, records)
            XCTAssertEqual(CatalogSources.split(first.records[0]).labels, [source])
            page = first
            page.now = "虚构航线的新概览。"
            try wiki.save(page, now: t0.addingTimeInterval(1))
            let second = try XCTUnwrap(wiki.read(path))
            XCTAssertEqual(second.factDomain, domain)
            XCTAssertEqual(second.records, records)
            XCTAssertEqual(second.markdown.components(separatedBy: "\n").filter { WikiPage.metaKey($0) == "事实域" },
                           ["事实域: \(domain.rawValue)"])
            let entry = try XCTUnwrap(wiki.history(path).first)
            try wiki.restore(path, entry: entry.name, expectedVersion: wiki.version(of: path), now: t0.addingTimeInterval(2))
            XCTAssertEqual(wiki.read(path)?.factDomain, domain)
            XCTAssertEqual(wiki.read(path)?.records, records)
        }
    }

    /// 原文编辑器 / 种子草稿保存：没改的行照落盘原文；改过的行只还原 [[双链]]、出处里的 wiki 本人那组、目录的路径行 / 原料行；
    /// 别处的「名字/…」不动，不全局替换
    func testEditorAndDraftStoreSymmetric() {
        let raw = "# 作息\n晚上早睡（出处：wiki {{user}}/作息；碎片 abcd1234）\n见 [[{{user}}/身体]]\n星砚/咪咪 的口头禅 {{user}}"
        let shown = WikiStore.shown(raw, user: "星砚")
        XCTAssertEqual(WikiStore.storedEdit(shown, original: raw, user: "星砚"), raw, "没改：原样回到落盘原文（含原文里别的 {{user}}）")
        let edited = shown.replacingOccurrences(of: "晚上早睡", with: "晚上十点睡") + "\n新行（出处：wiki 星砚 索引；wiki 星砚/作息 索引；wiki 人/小雾）\n星砚/岚舟 提到 [[星砚]]"
        XCTAssertEqual(WikiStore.storedEdit(edited, original: raw, user: "星砚"),
                       "# 作息\n晚上十点睡（出处：wiki {{user}}/作息；碎片 abcd1234）\n见 [[{{user}}/身体]]\n星砚/咪咪 的口头禅 {{user}}\n"
                       + "新行（出处：wiki {{user}} 索引；wiki {{user}}/作息 索引；wiki 人/小雾）\n星砚/岚舟 提到 [[{{user}}]]")
        XCTAssertEqual(WikiStore.storedCite("wiki 星砚星/作息", user: "星砚"), "wiki 星砚星/作息", "只认整段名字")
        XCTAssertEqual(CatalogSeedDrafts.storedDraftLine("路径: 星砚/作息", user: "星砚"), "路径: {{user}}/作息")
        XCTAssertEqual(CatalogSeedDrafts.storedDraftLine("- memory/wiki/星砚/作息.md", user: "星砚"), "- memory/wiki/{{user}}/作息.md")
        XCTAssertEqual(CatalogSeedDrafts.storedDraftLine("标题: 星砚/作息", user: "星砚"), "标题: 星砚/作息")
        XCTAssertEqual(CatalogSeedDrafts.storedDraftLine("钩子: 见 [[星砚/身体]]", user: "星砚"), "钩子: 见 [[{{user}}/身体]]")
    }



    /// 出处识别前先拿开行尾空白、还原后放回；「；」两边的空白也照留
    func testStoredLineKeepsTrailingWhitespace() {
        XCTAssertEqual(WikiStore.storedLine("晚上早睡（出处：wiki 星砚/作息）  ", user: "星砚"), "晚上早睡（出处：wiki {{user}}/作息）  ")
        XCTAssertEqual(WikiStore.storedLine("晚上早睡（出处：碎片 abcd1234； wiki 星砚/作息 ）\t", user: "星砚"), "晚上早睡（出处：碎片 abcd1234； wiki {{user}}/作息 ）\t")
        let raw = "晚上早睡（出处：wiki {{user}}/作息）"
        let edited = WikiStore.shown(raw, user: "星砚").replacingOccurrences(of: "早睡", with: "十点睡") + "  "
        XCTAssertEqual(WikiStore.storedEdit(edited, original: raw, user: "星砚"), "晚上十点睡（出处：wiki {{user}}/作息）  ")
        XCTAssertEqual(CatalogSources.split(WikiStore.storedLine("x（出处：wiki 星砚/作息）  ", user: "星砚").trimmingCharacters(in: .whitespaces)).labels,
                       ["wiki {{user}}/作息"], "后面按去空白解析时认得出还原后的出处")
    }

    /// 原文编辑器：恢复历史版本后，落盘基线跟着换成恢复的那版（同 WikiPageEditorSheet 的 onRestored），接着改完保存不误报「已在别处改过」
    func testEditorBaselineFollowsHistoryRestore() async throws {
        let path = "{{user}}/作息"
        try wiki.save(WikiPage(path: path, kind: .user, title: "作息", now: "早睡。"), now: t0)
        var page = try XCTUnwrap(wiki.read(path))
        page.now = "晚睡。"
        try wiki.save(page, now: t0.addingTimeInterval(60))
        let disk = WikiEditing.Baseline()
        disk.set(path, try XCTUnwrap(wiki.readRaw(path)))
        try wiki.restore(path, entry: try XCTUnwrap(wiki.history(path).first?.name),
                         expectedVersion: wiki.version(of: path), now: t0.addingTimeInterval(120))
        let restored = try XCTUnwrap(wiki.readRaw(path))
        XCTAssertTrue(restored.contains("早睡"))
        disk.set(path, restored)
        let base = try XCTUnwrap(disk.text(path))
        let edited = WikiStore.storedEdit(WikiStore.shown(restored, user: "星砚") + "\n补一行", original: base, user: "星砚")
        try await WikiEditing.save(edited, baseline: base, store: wiki, path: path)
        XCTAssertTrue(wiki.readRaw(path)?.hasSuffix("补一行") ?? false)
    }

    func testRestoredVersionSupportsAnotherRestoreAndManualSave() async throws {
        let path = "主题/虚构航线"
        try wiki.saveRaw("第一版", path: path, now: t0)
        let opened = try wiki.saveRaw("第二版", path: path, now: t0.addingTimeInterval(1))
        let first = try XCTUnwrap(wiki.history(path).first)
        let restored = try wiki.restore(path, entry: first.name, expectedVersion: opened, now: t0.addingTimeInterval(2))
        XCTAssertEqual(restored, WikiStore.version(of: Data("第一版".utf8)))
        XCTAssertEqual(wiki.version(of: path), restored)
        let second = try XCTUnwrap(wiki.history(path).first)
        XCTAssertEqual(wiki.historyText(path, entry: second.name), "第二版")
        let again = try wiki.restore(path, entry: second.name, expectedVersion: restored, now: t0.addingTimeInterval(3))
        XCTAssertEqual(again, opened)
        let beforeSave = Set(wiki.history(path).map(\.name))
        try await WikiEditing.save("恢复后手改", baseline: "第二版", store: wiki, path: path)
        XCTAssertEqual(wiki.readRaw(path), "恢复后手改")
        let added = wiki.history(path).filter { !beforeSave.contains($0.name) }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(wiki.historyText(path, entry: try XCTUnwrap(added.first).name), "第二版")
    }

}
