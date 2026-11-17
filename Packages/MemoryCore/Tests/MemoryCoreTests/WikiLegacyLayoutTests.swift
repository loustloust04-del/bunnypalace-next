import XCTest
@testable import MemoryCore

/// 旧摆法搬家（`楼层/<组>/…` → 现在的 9 组）：数据全是编的
final class WikiLegacyLayoutTests: XCTestCase {

    private var base: URL!
    private var memoryRoot: URL!
    private var wiki: WikiStore!
    private let user = "岚舟"

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-legacy-\(UUID().uuidString)", isDirectory: true)
        memoryRoot = base.appendingPathComponent("memory", isDirectory: true)
        wiki = WikiStore(root: memoryRoot.appendingPathComponent("wiki", isDirectory: true))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func url(_ relative: String) -> URL { wiki.root.appendingPathComponent(relative) }

    private func write(_ relative: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: url(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url(relative))
    }

    private func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }

    private func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

    /// 旧位置的一页（`relative` 不带 .md，写在 `楼层/` 下）
    private func legacy(_ relative: String, kind: WikiPage.Kind = .topic, hook: String = "", links: [WikiPage.Link] = [], records: [String] = []) throws {
        let title = String(relative.split(separator: "/").last ?? "")
        try write("楼层/\(relative).md", WikiPage(path: "楼层/\(relative)", kind: kind, triggers: [title], hook: hook, title: title,
                                                 now: "\(title)的现在", records: records, links: links).markdown)
    }

    /// wiki 根下所有东西（含隐藏的）：相对路径 → 内容 + 改动时间
    private func snapshot() -> [String: String] {
        guard let en = FileManager.default.enumerator(atPath: wiki.root.path) else { return [:] }
        var out: [String: String] = [:]
        while let rel = en.nextObject() as? String {
            let attrs = en.fileAttributes ?? [:]
            let stamp = (attrs[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) } ?? ""
            if (attrs[.type] as? FileAttributeType) == .typeDirectory {
                out[rel + "/"] = ""
            } else {
                out[rel] = stamp + "|" + (text(rel) ?? "")
            }
        }
        return out
    }

    private func scanned() -> [String] {
        SafeWiki.scan(wiki, memoryRoot: memoryRoot).pages.map(\.path)
    }

    func testNoLegacyFolderWritesNothing() throws {
        try wiki.save(WikiPage(path: "地点/云桥城", kind: .place, title: "云桥城"))
        try write(".history/地点/云桥城/20261001-000000.md", "旧版")
        let before = snapshot()
        XCTAssertFalse(wiki.hasLegacyLayout)
        XCTAssertEqual(wiki.relocateLegacyLayout(user: user), WikiStore.LegacyRelocation())
        XCTAssertEqual(snapshot(), before, "没有旧文件夹：连索引都不重建")

        let missing = WikiStore(root: base.appendingPathComponent("没有这层/wiki", isDirectory: true))
        XCTAssertEqual(missing.relocateLegacyLayout(user: user), WikiStore.LegacyRelocation())
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.root.path), "wiki 根不在也不建")
    }

    func testUserNameFolderMovesToUserBranch() throws {
        try legacy("岚舟/皮影收藏", kind: .user, hook: "聊到皮影时")
        try write("楼层/INDEX.md", "# 楼层\n")
        try write("楼层/岚舟/INDEX.md", "# 楼层/岚舟\n")
        XCTAssertEqual(scanned(), [], "搬之前现在的代码不认旧位置的页")

        let result = wiki.relocateLegacyLayout(user: user)

        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.skipped, [:])
        XCTAssertEqual(result.removedFolders, 2, "楼层/岚舟 和 楼层 都空了")
        XCTAssertEqual(scanned(), ["{{user}}/皮影收藏"])
        XCTAssertEqual(wiki.read("{{user}}/皮影收藏")?.hook, "聊到皮影时")
        XCTAssertEqual(wiki.read("{{user}}/皮影收藏")?.now, "皮影收藏的现在")
        XCTAssertFalse(exists("楼层"))
        XCTAssertFalse(exists(".history"), "搬家不算改页，不存历史")
    }

    func testKindFolderAndUserAliasesMove() throws {
        try legacy("地点/云桥城", kind: .place)
        try legacy("用户/作息", kind: .user)
        try legacy("{{user}}/口味", kind: .user)
        try legacy("工程/皮影台账", kind: .project)

        let result = wiki.relocateLegacyLayout(user: user)

        XCTAssertEqual(result.moved, 4)
        XCTAssertEqual(scanned(), ["地点/云桥城", "工程/皮影台账", "{{user}}/作息", "{{user}}/口味"].sorted())
        XCTAssertFalse(exists("楼层"))
    }

    func testUnknownFolderAndLoosePageStay() throws {
        try legacy("星砚/旧事")
        try legacy("散页")
        try write("楼层/星砚/INDEX.md", "# 楼层/星砚\n")
        let before = snapshot()

        let result = wiki.relocateLegacyLayout(user: user)

        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, [.unknownGroup: 2], "别人名字的文件夹、直接放在楼层下的页：不猜")
        XCTAssertEqual(result.removedFolders, 0)
        XCTAssertNil(result.logNote, "什么都没搬就不记日志")
        XCTAssertEqual(snapshot(), before)
    }

    func testExistingTargetIsNotOverwritten() throws {
        try wiki.save(WikiPage(path: "地点/云桥城", kind: .place, title: "云桥城", now: "现在这页"))
        try legacy("地点/云桥城", kind: .place)
        try legacy("地点/槐序巷皮影作坊", kind: .place)
        let kept = text("楼层/地点/云桥城.md")

        let result = wiki.relocateLegacyLayout(user: user)

        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.skipped, [.targetExists: 1])
        XCTAssertEqual(wiki.read("地点/云桥城")?.now, "现在这页")
        XCTAssertEqual(text("楼层/地点/云桥城.md"), kept, "同名的那页留在原地、原样")
        XCTAssertEqual(scanned(), ["地点/云桥城", "地点/槐序巷皮影作坊"])
        XCTAssertFalse(exists("楼层/地点/槐序巷皮影作坊.md"))
        XCTAssertEqual(result.removedFolders, 0, "里面还有没搬的页，文件夹留着")
    }

    func testHalfDoneMoveIsFinished() throws {
        try legacy("地点/云桥城", kind: .place)
        try write("地点/云桥城.md", try XCTUnwrap(text("楼层/地点/云桥城.md")))

        let result = wiki.relocateLegacyLayout(user: user)

        XCTAssertEqual(result.moved, 1, "新位置已是同一份内容：上次写好了没删旧的，这次补删")
        XCTAssertFalse(exists("楼层"))
    }

    func testLegacyLinksAreRewritten() throws {
        try legacy("岚舟/皮影收藏", kind: .user,
                   links: [.init(target: "楼层/地点/槐序巷皮影作坊", relation: .supplement, why: "在那儿买的"),
                           .init(target: "楼层/星砚/旧事", relation: .citation, why: ""),
                           .init(target: "人/星砚", relation: .resonance, why: "")],
                   records: ["去过 [[楼层/地点/云桥城]]（出处：对话）"])
        try legacy("地点/槐序巷皮影作坊", kind: .place, links: [.init(target: "楼层/岚舟/皮影收藏", relation: .supplement, why: "")])

        XCTAssertEqual(wiki.relocateLegacyLayout(user: user).moved, 2)

        let mine = try XCTUnwrap(wiki.read("{{user}}/皮影收藏"))
        XCTAssertEqual(mine.links.map(\.target), ["地点/槐序巷皮影作坊", "楼层/星砚/旧事", "人/星砚"], "对不上组的旧连线原样留着")
        XCTAssertEqual(mine.links.first?.why, "在那儿买的")
        XCTAssertEqual(mine.records, ["去过 [[地点/云桥城]]（出处：对话）"])
        XCTAssertEqual(wiki.read("地点/槐序巷皮影作坊")?.links.map(\.target), ["{{user}}/皮影收藏"])

        XCTAssertEqual(WikiStore.relocatingLegacyLinks("[[楼层/用户]] [[楼层/岚舟/a|别名]] [[楼层/]] 楼层/人/x [[楼层/人", user: user),
                       "[[{{user}}]] [[{{user}}/a|别名]] [[楼层/]] 楼层/人/x [[人")
    }

    func testDeeperGroupsAndGroupHooksAreKept() throws {
        try legacy("岚舟/行为模式/拖延曲线", kind: .user)
        try legacy("人/家人/星砚", kind: .person)
        try write("楼层/人/家人/.group.md", "---\n钩子: 聊到家里人时\n---\n")
        try wiki.save(WikiPage(path: "{{user}}/行为模式/早起", kind: .user, title: "早起"))
        try wiki.setGroupHook("{{user}}/行为模式", hook: "现在的钩子")
        try write("楼层/岚舟/行为模式/.group.md", "---\n钩子: 旧钩子\n---\n")

        XCTAssertEqual(wiki.relocateLegacyLayout(user: user).moved, 2)

        XCTAssertEqual(scanned(), ["人/家人/星砚", "{{user}}/行为模式/拖延曲线", "{{user}}/行为模式/早起"].sorted())
        XCTAssertEqual(wiki.groupHook("人/家人"), "聊到家里人时", "分组钩子跟着页走")
        XCTAssertEqual(wiki.groupHook("{{user}}/行为模式"), "现在的钩子", "新位置已有钩子不盖")
        XCTAssertFalse(exists("楼层"))
    }

    func testSecondRunChangesNothing() throws {
        try legacy("岚舟/皮影收藏", kind: .user, links: [.init(target: "楼层/地点/云桥城", relation: .supplement, why: "")])
        try legacy("地点/云桥城", kind: .place)
        try legacy("星砚/旧事")
        XCTAssertEqual(wiki.relocateLegacyLayout(user: user).moved, 2)
        let after = snapshot()

        let again = wiki.relocateLegacyLayout(user: user)

        XCTAssertEqual(again.moved, 0)
        XCTAssertEqual(again.skipped, [.unknownGroup: 1])
        XCTAssertEqual(again.removedFolders, 0)
        XCTAssertEqual(snapshot(), after)
    }

    func testIndexesListMovedPages() throws {
        try legacy("地点/云桥城", kind: .place, hook: "聊到老家时")
        try legacy("岚舟/皮影收藏", kind: .user)
        try write("楼层/INDEX.md", "# 楼层\n")
        try write("楼层/地点/INDEX.md", "# 楼层/地点\n\n- [[楼层/地点/云桥城]] 云桥城\n")

        let result = wiki.relocateLegacyLayout(user: user)

        XCTAssertFalse(result.indexFailed)
        XCTAssertEqual(text("INDEX.md"), """
        # C 档案

        ## {{user}}（1 页）
        - [[{{user}}/皮影收藏]] 皮影收藏

        ## 地点（1 页）
        - [[地点/云桥城]] 云桥城 — 聊到老家时

        """)
        XCTAssertEqual(text("地点/INDEX.md"), "# 地点\n\n- [[地点/云桥城]] 云桥城 — 聊到老家时\n")
        XCTAssertEqual(text("INDEX.md"), SafeWiki.scan(wiki, memoryRoot: memoryRoot).index(""), "盘上的索引和按真实文件算的一样")
        XCTAssertFalse(exists("楼层"), "旧位置的 INDEX.md 跟着删了")
    }

    func testHiddenFoldersAreNotTouched() throws {
        try legacy("岚舟/皮影收藏", kind: .user)
        try write(".history/楼层/岚舟/皮影收藏/20261001-000000.md", "旧版")
        try write(".proposals/p1.json", "{}")
        try write("楼层/.stash/留着.md", "别动")
        try write("楼层/岚舟/.history/留着.md", "别动")
        let hidden = snapshot().filter { $0.key.split(separator: "/").contains { $0.hasPrefix(".") } }

        XCTAssertEqual(wiki.relocateLegacyLayout(user: user).moved, 1)

        XCTAssertEqual(snapshot().filter { $0.key.split(separator: "/").contains { $0.hasPrefix(".") } }, hidden)
        XCTAssertTrue(exists("楼层/岚舟"), "里面还有隐藏目录，文件夹留着")
    }

    func testLinkedLegacyFolderIsNotFollowed() throws {
        let outside = base.appendingPathComponent("别处", isDirectory: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("地点"), withIntermediateDirectories: true)
        try Data("# 云桥城\n".utf8).write(to: outside.appendingPathComponent("地点/云桥城.md"))
        try FileManager.default.createSymbolicLink(at: url("楼层"), withDestinationURL: outside)

        XCTAssertEqual(wiki.relocateLegacyLayout(user: user), WikiStore.LegacyRelocation())
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("地点/云桥城.md").path))
        XCTAssertEqual(scanned(), [])
    }

    func testLogNoteHasCountsOnlyAndPrivatePagesStillMove() throws {
        try legacy("岚舟/private_日记", kind: .user)
        try legacy("地点/云桥城", kind: .place)
        try legacy("星砚/旧事")
        try wiki.save(WikiPage(path: "人/星砚", kind: .person, title: "星砚"))
        try legacy("人/星砚", kind: .person)

        let result = wiki.relocateLegacyLayout(user: user)

        XCTAssertTrue(exists("{{user}}/private_日记.md"), "私人页照样换位置")
        XCTAssertEqual(scanned(), ["人/星砚", "地点/云桥城"], "私人页还是不进扫描")
        XCTAssertEqual(result.logNote, "wiki 旧位置的 2 页搬到了现在的位置；2 页没搬（现在的位置已有同名页 1、认不出该放哪一组 1）")
    }
}
