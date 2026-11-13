import XCTest
import MemoryCore
@testable import memoryd

final class MemorydWikiAPITests: XCTestCase {
    private var floor: URL!
    private var service: MemorydService!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
        service = try MemorydFixture.service(floor)
    }

    override func tearDownWithError() throws {
        if let floor { MemorydFixture.remove(floor) }
    }

    func testIndexListsBranchesAndHidesPrivatePages() async throws {
        let response = await service.get("/api/wiki/index")
        XCTAssertEqual(response.status, 200)
        let groups = try XCTUnwrap(response.jsonDictionary?["groups"] as? [[String: Any]])
        let counts = Dictionary(uniqueKeysWithValues: groups.compactMap { group -> (String, Int)? in
            guard let path = group["path"] as? String, let count = group["count"] as? Int else { return nil }
            return (path, count)
        })
        XCTAssertEqual(counts["地点"], 1)
        XCTAssertEqual(counts["人"], 1, "private_ 开头的页不算")
        XCTAssertEqual(counts["主题"], 1)
        XCTAssertEqual(counts["{{user}}"], 1)
        let user = try XCTUnwrap(groups.first { $0["path"] as? String == "{{user}}" })
        XCTAssertEqual(user["title"] as? String, "本人")
    }

    func testGroupListsPagesOnly() async throws {
        let response = await service.get("/api/wiki/group/人")
        XCTAssertEqual(response.status, 200)
        let entries = try XCTUnwrap(response.jsonDictionary?["entries"] as? [[String: Any]])
        let paths = entries.compactMap { $0["path"] as? String }
        XCTAssertEqual(paths, ["人/星砚"])
        XCTAssertEqual(entries.first?["type"] as? String, "page")
        XCTAssertEqual(entries.first?["title"] as? String, "星砚")
    }

    func testRootGroupCountsComeFromSafeWiki() async throws {
        let response = await service.get("/api/wiki/group")
        XCTAssertEqual(response.status, 200)
        let entries = try XCTUnwrap(response.jsonDictionary?["entries"] as? [[String: Any]])
        let person = try XCTUnwrap(entries.first { $0["path"] as? String == "人" })
        XCTAssertEqual(person["count"] as? Int, 1, "private_ 页不计入分组页数")
    }

    func testGroupUnknownFolderIs404() async throws {
        let response = await service.get("/api/wiki/group/不存在")
        XCTAssertEqual(response.status, 404)
    }

    func testGroupRejectsInvalidPath() async throws {
        let traversal = await service.get("/api/wiki/group/..%2f..%2fetc")
        XCTAssertEqual(traversal.status, 400)
        let absolute = await service.get("/api/wiki/group/etc/passwd/../..")
        XCTAssertEqual(absolute.status, 400)
    }

    func testPageReturnsParsedContent() async throws {
        let response = await service.get("/api/wiki/page/地点/云桥城")
        XCTAssertEqual(response.status, 200)
        let page = try XCTUnwrap(response.jsonDictionary)
        XCTAssertEqual(page["title"] as? String, "云桥城")
        XCTAssertEqual(page["kind"] as? String, "地点")
        XCTAssertTrue((page["hook"] as? String ?? "").contains("航图"))
        XCTAssertTrue((page["now"] as? String ?? "").contains("航图"))
        XCTAssertEqual((page["records"] as? [String])?.count, 1)
        XCTAssertTrue((page["markdown"] as? String ?? "").contains("# 云桥城"))
    }

    func testPrivatePageIs404() async throws {
        let response = await service.get("/api/wiki/page/人/private_雾岛")
        XCTAssertEqual(response.status, 404)
        XCTAssertNil(response.jsonDictionary?["title"])
    }

    private static let seedCard = "memory/cc/seedlab-001.md|8c20f7454bf168f3423a7211f340dde7e0b6a74b0ea57b9a5819ccbf48bd395f"

    func testEntryCardWithoutOriginalIsCurrentUnavailable() async throws {
        let response = await service.get("/api/wiki/entry/2/主题/风铃/\(Self.seedCard.replacingOccurrences(of: "|", with: "%7C"))")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.jsonDictionary?["missing"] as? String, "currentUnavailable")
        XCTAssertNil(response.jsonDictionary?["text"])
    }

    func testEntryCardWithOriginalReturnsText() async throws {
        let wiki = WikiStore(root: floor.appendingPathComponent("wiki", isDirectory: true))
        try SeedNoteStore(wiki: wiki).saveOriginal(path: "memory/cc/seedlab-001.md",
            version: "8c20f7454bf168f3423a7211f340dde7e0b6a74b0ea57b9a5819ccbf48bd395f",
            text: "码头旧草图原文", sourceContext: nil)
        let response = await service.get("/api/wiki/entry/2/主题/风铃/\(Self.seedCard.replacingOccurrences(of: "|", with: "%7C"))")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.jsonDictionary?["text"] as? String, "码头旧草图原文")
        XCTAssertEqual(response.jsonDictionary?["complete"] as? Bool, true)
        XCTAssertNil(response.jsonDictionary?["next"], "一期不接续读，响应不带游标")
    }

    func testEntryRejectsPrivateCardAndPrivatePage() async throws {
        let privateCard = await service.get("/api/wiki/entry/2/主题/风铃/memory/cc/private_雾岛.md%7Cv1")
        XCTAssertEqual(privateCard.status, 400, "private_ 卡路径不进 reference")
        let privatePage = await service.get("/api/wiki/entry/2/人/private_雾岛/\(Self.seedCard.replacingOccurrences(of: "|", with: "%7C"))")
        XCTAssertEqual(privatePage.status, 404, "private_ 页不进 SafeWiki")
    }

    func testEntryWithoutMemoryCardPathIs404() async throws {
        let response = await service.get("/api/wiki/entry/2/主题/风铃/notes/seedlab-001.md%7Cv1")
        XCTAssertEqual(response.status, 404)
    }

    /// M1 r3：页段数前缀让「卡路径里再含 memory/」不歧义（页 / 卡两边都有 memory 段也切得对）
    func testEntrySplitsNestedMemoryCardByPageSegmentCount() async throws {
        let wiki = WikiStore(root: floor.appendingPathComponent("wiki", isDirectory: true))
        let cardPath = "memory/cc/archive/memory/n.md"
        let version = "v1"
        let memoryFile = floor.appendingPathComponent(cardPath)
        try FileManager.default.createDirectory(at: memoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "档案里的卡".write(to: memoryFile, atomically: true, encoding: .utf8)
        let store = SeedNoteStore(wiki: wiki)
        try store.saveOriginal(path: cardPath, version: version, text: "嵌套 memory 的卡正文", sourceContext: nil)
        try store.save(SeedNoteCard(path: cardPath, version: version, name: "n", layer: "CC", title: "嵌套卡", gist: "g",
            mentions: [], aboutUser: false, group: "主题", when: [], model: "fixture",
            madeAt: Date(timeIntervalSince1970: 1_700_000_000), run: CatalogRunLink(path: "seedlab/fixture")))

        let pageURL = wiki.root.appendingPathComponent("主题/风铃.md")
        var page = try String(contentsOf: pageURL, encoding: .utf8)
        let open = try XCTUnwrap(page.range(of: "条目: ["))
        let close = try XCTUnwrap(page.range(of: "]", range: open.upperBound..<page.endIndex))
        page.insert(contentsOf: ", \"\(cardPath)|\(version)\"", at: close.lowerBound)
        try page.write(to: pageURL, atomically: true, encoding: .utf8)

        let response = await service.get("/api/wiki/entry/2/主题/风铃/\(cardPath)%7C\(version)")
        XCTAssertEqual(response.status, 200)
        let target = try XCTUnwrap(response.jsonDictionary?["target"] as? [String: Any])
        let targetPage = try XCTUnwrap(target["page"] as? [String: Any])
        XCTAssertEqual(targetPage["path"] as? String, "主题/风铃")
        XCTAssertEqual(target["path"] as? String, cardPath)
        XCTAssertEqual(response.jsonDictionary?["text"] as? String, "嵌套 memory 的卡正文")
    }

    /// M1 r3：页段数不对 / 旧格式首段非整数 → 400
    func testEntryRejectsWrongSegmentCountAndLegacyShape() async throws {
        let wrongCount = await service.get("/api/wiki/entry/3/主题/风铃/memory/cc/archive/memory/n.md%7Cv1")
        XCTAssertEqual(wrongCount.status, 400, "n=3 把卡路径的 memory 段吃进页路径，剩下不是 memory/ 开头")
        let legacy = await service.get("/api/wiki/entry/主题/风铃/\(Self.seedCard.replacingOccurrences(of: "|", with: "%7C"))")
        XCTAssertEqual(legacy.status, 400, "旧格式首段不是整数")
    }

    func testTraversalIsRejected() async throws {
        let response = await service.get("/api/wiki/page/../../etc/passwd")
        XCTAssertEqual(response.status, 400)
    }

    /// S1：group 接口只读 SafeWiki 快照——`.group.md` 链接不跟、只装 private 页的文件夹不列、大写 `Private_` 不列
    func testGroupIgnoresLinksPrivateOnlyFoldersAndUpperCasePrivate() async throws {
        let fm = FileManager.default
        let outside = fm.temporaryDirectory.appendingPathComponent("memoryd-outside-\(UUID().uuidString).md")
        try "外部泄露钩子".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: outside) }

        let wiki = floor.appendingPathComponent("wiki", isDirectory: true)
        let linked = wiki.appendingPathComponent("地点/链组", isDirectory: true)
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linked.appendingPathComponent(".group.md"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: linked.appendingPathComponent("链页.md"), withDestinationURL: outside)

        let privateOnly = wiki.appendingPathComponent("主题/秘密组", isDirectory: true)
        try fm.createDirectory(at: privateOnly, withIntermediateDirectories: true)
        try "私密".write(to: privateOnly.appendingPathComponent("private_只私.md"), atomically: true, encoding: .utf8)
        try "大写".write(to: wiki.appendingPathComponent("人/Private_大写.md"), atomically: true, encoding: .utf8)

        let place = await service.get("/api/wiki/group/地点")
        XCTAssertEqual(place.status, 200)
        let placeEntries = try XCTUnwrap(place.jsonDictionary?["entries"] as? [[String: Any]])
        XCTAssertFalse(placeEntries.contains { ($0["path"] as? String)?.contains("链组") == true }, "链接目录不进")
        XCTAssertFalse(placeEntries.contains { ($0["hook"] as? String)?.contains("外部泄露钩子") == true }, "链接的 .group.md 不读")

        let theme = await service.get("/api/wiki/group/主题")
        let themeEntries = try XCTUnwrap(theme.jsonDictionary?["entries"] as? [[String: Any]])
        XCTAssertFalse(themeEntries.contains { ($0["path"] as? String)?.contains("秘密组") == true }, "只装 private 页的文件夹不列")

        let person = await service.get("/api/wiki/group/人")
        let personPaths = (person.jsonDictionary?["entries"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        XCTAssertEqual(personPaths, ["人/星砚"], "大写 Private_ 也不列")
    }
}

final class MemorydBenchAPITests: XCTestCase {
    private var floor: URL!
    private var service: MemorydService!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
        service = try MemorydFixture.service(floor)
    }

    override func tearDownWithError() throws {
        if let floor { MemorydFixture.remove(floor) }
    }

    func testListsBuiltinAndFloorSets() async throws {
        let response = await service.get("/api/bench/sets")
        XCTAssertEqual(response.status, 200)
        let sets = try XCTUnwrap(response.jsonDictionary?["sets"] as? [[String: Any]])
        let ids = sets.compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains("wiki-probe"))
        XCTAssertTrue(ids.contains("recall-24"))
        XCTAssertTrue(ids.contains("c2-probe"))
        let probe = try XCTUnwrap(sets.first { $0["id"] as? String == "wiki-probe" })
        XCTAssertEqual(probe["runnable"] as? Bool, true)
        let recall = try XCTUnwrap(sets.first { $0["id"] as? String == "recall-24" })
        XCTAssertEqual(recall["runnable"] as? Bool, true)
        XCTAssertEqual(recall["partial"] as? String, "13/24")
        XCTAssertFalse(ids.contains { $0.contains("floor") }, "楼层 JSON 不是题集")
    }

    /// S1：楼层 JSON 以 `memory-bench-` 开头，必须显式排除；靠 decode 失败跳过会每次请求记一条 error
    func testBuiltInSetsExcludeRecallFloorWithoutDecodeFailure() async throws {
        let loaded = await service.loadBuiltInSets()
        XCTAssertEqual(loaded.sets.map(\.id), ["a2-probe", "c2-probe", "recall-24", "wiki-probe"])
        XCTAssertEqual(loaded.skipped, [], "楼层 JSON 不该进解码失败列表（那会记 error）")
        let floorFile = try XCTUnwrap(MemorydResources.benchDirectory).appendingPathComponent("memory-bench-recall-floor-xingyan.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: floorFile.path), "文件在资源目录里，确实被过滤器排除")
    }

    func testSetDetailCarriesCasesAndLabels() async throws {
        let response = await service.get("/api/bench/sets/wiki-probe")
        XCTAssertEqual(response.status, 200)
        let set = try XCTUnwrap(response.jsonDictionary)
        let cases = try XCTUnwrap(set["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        let labels = try XCTUnwrap(cases.first?["labels"] as? [[String: Any]])
        XCTAssertEqual(labels.first?["kind"] as? String, "必须带")
    }

    func testUnknownSetIs404() async throws {
        let response = await service.get("/api/bench/sets/nope")
        XCTAssertEqual(response.status, 404)
    }

    func testRunUnknownSetIs404() async throws {
        let response = await service.post("/api/bench/run", json: #"{"setId":"nope"}"#)
        XCTAssertEqual(response.status, 404)
    }

    func testRunWikiProbeScoresOffline() async throws {
        let started = await service.post("/api/bench/run", json: #"{"setId":"wiki-probe"}"#)
        XCTAssertEqual(started.status, 200)
        let runId = try XCTUnwrap(started.jsonDictionary?["runId"] as? String)

        let detail = await service.get("/api/bench/runs/\(runId)")
        XCTAssertEqual(detail.status, 200)
        let run = try XCTUnwrap(detail.jsonDictionary)
        let cells = try XCTUnwrap(run["cells"] as? [[String: Any]])
        XCTAssertEqual(cells.count, 4)
        XCTAssertTrue(cells.allSatisfy { ($0["error"] as? String) == nil })
        let judgments = try XCTUnwrap(run["judgments"] as? [[String: Any]])
        XCTAssertEqual(judgments.count, 5, "「允许带」不出判断：1 + 1 + 2 + 1")
        XCTAssertTrue(judgments.allSatisfy { ($0["verdict"] as? String) == "对" })
        let scores = try XCTUnwrap(run["scores"] as? [[String: Any]])
        let main = try XCTUnwrap(scores.first?["main"] as? Double)
        XCTAssertEqual(main, 1.0, accuracy: 0.0001)
        XCTAssertEqual(scores.first?["mainName"] as? String, "标签判对比例")

        let saved = floor.appendingPathComponent("bench-runs/runs/\(runId)/run.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "结果落 MemoryBenchStore 的规范位置")
        XCTAssertFalse(FileManager.default.fileExists(atPath: floor.appendingPathComponent("bench-runs/\(runId).json").path),
                       "不再另写一份平铺的")

        let listed = await service.get("/api/bench/runs")
        let runs = try XCTUnwrap(listed.jsonDictionary?["runs"] as? [[String: Any]])
        XCTAssertTrue(runs.contains { $0["id"] as? String == runId })
    }

    func testPrivatePageNeverEntersHits() async throws {
        let started = await service.post("/api/bench/run", json: #"{"setId":"wiki-probe"}"#)
        let runId = try XCTUnwrap(started.jsonDictionary?["runId"] as? String)
        let detail = await service.get("/api/bench/runs/\(runId)")
        let cells = try XCTUnwrap(detail.jsonDictionary?["cells"] as? [[String: Any]])
        let privateCase = try XCTUnwrap(cells.first { ($0["caseId"] as? String) == "wiki-private-never" })
        let output = try XCTUnwrap(privateCase["output"] as? String)
        XCTAssertFalse(output.contains("private_雾岛"))
    }

    func testRecallSetRunsYHalfOrExplainsTimeZone() async throws {
        let started = await service.post("/api/bench/run", json: #"{"setId":"recall-24"}"#)
        XCTAssertEqual(started.status, 200)
        let runId = try XCTUnwrap(started.jsonDictionary?["runId"] as? String)
        let detail = await service.get("/api/bench/runs/\(runId)")
        let run = try XCTUnwrap(detail.jsonDictionary)
        let note = run["note"] as? String ?? ""
        if Calendar.current.timeZone.identifier == "America/Los_Angeles" {
            XCTAssertEqual((run["cells"] as? [[String: Any]])?.count, 13)
            XCTAssertTrue(note.contains("主分不可测（X 侧 11 题等刀 3）"), note)
        } else {
            XCTAssertEqual((run["cells"] as? [[String: Any]])?.count, 0)
            XCTAssertTrue(note.contains("宿主时区"), note)
            XCTAssertTrue(note.contains("America/Los_Angeles"), note)
        }
    }

    func testBadRunBodyIs400AndWrongMethodIs405() async throws {
        let bad = await service.post("/api/bench/run", json: #"{"setId":""}"#)
        XCTAssertEqual(bad.status, 400)
        let wrong = await service.post("/api/wiki/index", json: "{}")
        XCTAssertEqual(wrong.status, 405)
    }

    /// N2：副本 `wiki/不触发的词.txt` 里的词要像 app 一样从 terms / ranked 里排除；w1 两个词都在里面 → 没有检索词、不命中
    func testWikiStopWordsAreExcluded() async throws {
        let stop = floor.appendingPathComponent("wiki/\(WikiStore.stopWordsFileName)")
        try "潮汐\n船舱\n".write(to: stop, atomically: true, encoding: .utf8)

        let started = await service.post("/api/bench/run", json: #"{"setId":"wiki-probe"}"#)
        XCTAssertEqual(started.status, 200)
        let runId = try XCTUnwrap(started.jsonDictionary?["runId"] as? String)
        let detail = await service.get("/api/bench/runs/\(runId)")
        let cells = try XCTUnwrap(detail.jsonDictionary?["cells"] as? [[String: Any]])
        let cell = try XCTUnwrap(cells.first { ($0["caseId"] as? String) == "wiki-hit-cloudcity" })
        let output = try XCTUnwrap(cell["output"] as? String)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual((decoded["terms"] as? [String])?.isEmpty, true, "问句的词全在「不触发的词」里")
        XCTAssertEqual((decoded["words"] as? [String])?.isEmpty, true)
        XCTAssertEqual((decoded["hits"] as? [[String: Any]])?.isEmpty, true)
    }

    /// N4：超过一次上限（1500 > 60）是请求本身的问题 → 400，不是 500
    func testOversizedSetIs400() async throws {
        let cases = (0..<1500).map { index in
            MemoryBenchCase(id: "c\(index)", title: "c\(index)",
                            input: .object(["query": .string("潮汐")]), labels: [])
        }
        let set = MemoryBenchSet(id: "too-many", name: "1500 题", writer: OfflineWikiBenchWriter.id,
                                 source: .floor, cases: cases)
        let store = MemoryBenchStore(root: floor.appendingPathComponent("bench-runs", isDirectory: true))
        try store.saveSet(set)

        let response = await service.post("/api/bench/run", json: #"{"setId":"too-many"}"#)
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue((response.jsonDictionary?["error"] as? String ?? "").contains("一次最多"))
    }

    /// M2：出错格（副本里没有 wiki/）整格不计分，主分只剩没出错的格子
    func testErroredCellsAreNotScored() async throws {
        try FileManager.default.removeItem(at: floor.appendingPathComponent("wiki", isDirectory: true))
        let started = await service.post("/api/bench/run", json: #"{"setId":"wiki-probe"}"#)
        XCTAssertEqual(started.status, 200)
        let runId = try XCTUnwrap(started.jsonDictionary?["runId"] as? String)

        let detail = await service.get("/api/bench/runs/\(runId)")
        let run = try XCTUnwrap(detail.jsonDictionary)
        let cells = try XCTUnwrap(run["cells"] as? [[String: Any]])
        XCTAssertEqual(cells.filter { $0["error"] != nil }.count, 3)
        let judgments = try XCTUnwrap(run["judgments"] as? [[String: Any]])
        XCTAssertEqual(judgments.count, 1, "只剩没出错那格（纯表情）的一条")
        let scores = try XCTUnwrap(run["scores"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(scores.first?["main"] as? Double), 1.0, accuracy: 0.0001)
        let parts = try XCTUnwrap(scores.first?["parts"] as? [String: Any])
        XCTAssertEqual(parts["出错格"] as? Double, 3)
        XCTAssertTrue((run["note"] as? String ?? "").contains("3 格出错未计分"))
    }
}

/// M1：Host / Origin / Content-Type
final class MemorydGuardTests: XCTestCase {
    private var floor: URL!
    private var service: MemorydService!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
        service = try MemorydFixture.service(floor)
    }

    override func tearDownWithError() throws {
        if let floor { MemorydFixture.remove(floor) }
    }

    func testGoodHostIs200() async throws {
        let response = await service.raw("GET", "/api/wiki/index")
        XCTAssertEqual(response.status, 200)
        let localhost = await service.raw("GET", "/api/wiki/index", host: "localhost:\(MemorydTestPort.value)")
        XCTAssertEqual(localhost.status, 200)
    }

    func testForeignHostIs403() async throws {
        let response = await service.raw("GET", "/api/wiki/index", host: "evil.example:\(MemorydTestPort.value)")
        XCTAssertEqual(response.status, 403)
        XCTAssertNil(response.jsonDictionary?["groups"])
        let missing = await service.raw("GET", "/api/wiki/index", host: nil)
        XCTAssertEqual(missing.status, 403, "没有 Host 的 HTTP/1.1 请求也拒")
    }

    func testForeignOriginIs403() async throws {
        let response = await service.raw("GET", "/api/wiki/index", headers: ["origin": "https://evil.example"])
        XCTAssertEqual(response.status, 403)
        let same = await service.raw("GET", "/api/wiki/index", headers: ["origin": "http://127.0.0.1:\(MemorydTestPort.value)"])
        XCTAssertEqual(same.status, 200)
    }

    func testPlainTextPostIs415() async throws {
        let response = await service.post("/api/bench/run", json: #"{"setId":"wiki-probe"}"#, contentType: "text/plain")
        XCTAssertEqual(response.status, 415)
        let form = await service.post("/api/bench/run", json: #"{"setId":"wiki-probe"}"#,
                                      contentType: "application/x-www-form-urlencoded")
        XCTAssertEqual(form.status, 415)
    }

    func testJSONPostStillWorks() async throws {
        let response = await service.post("/api/bench/run", json: #"{"setId":"wiki-probe"}"#,
                                          contentType: "application/json; charset=utf-8")
        XCTAssertEqual(response.status, 200)
    }
}

/// S12：没挂载标记的目录拒绝启动
final class MemorydMountGuardTests: XCTestCase {
    func testUnmarkedFloorIsRefused() throws {
        let floor = try MemorydFixture.copiedFloor()
        defer { MemorydFixture.remove(floor) }
        XCTAssertThrowsError(try MemorydService(config: .init(floor: floor, profileId: "memoryd-test"), webRoot: nil)) { error in
            guard case MemorydError.notMounted = error else { return XCTFail("期望 notMounted，实际 \(error)") }
        }
        try "memoryd-mount 1\n".write(to: floor.appendingPathComponent(MemorydService.mountMarkerName),
                                      atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try MemorydService(config: .init(floor: floor, profileId: "memoryd-test"), webRoot: nil))
    }
}

/// 夹具卡：`wiki/.cards/<key>.json` + 页 frontmatter「条目」引用 → 索引里出现 `kind: card`
final class MemorydCardIndexTests: XCTestCase {
    private var floor: URL!
    private var service: MemorydService!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
        service = try MemorydFixture.service(floor)
    }

    override func tearDownWithError() throws {
        if let floor { MemorydFixture.remove(floor) }
    }

    func testCardHitByGistWord() async throws {
        let store = MemoryBenchStore(root: floor.appendingPathComponent("bench-runs", isDirectory: true))
        let set = MemoryBenchSet(id: "card-probe", name: "卡探针", writer: "wiki", source: .floor, cases: [
            MemoryBenchCase(id: "card-1", title: "草图命中卡", input: .object(["query": .string("草图")]),
                            labels: [MemoryBenchLabel(id: "card-1-m", kind: "必须带", text: "草图卡",
                                                      keys: ["card:memory/cc/seedlab-001.md"], from: "fixture")])
        ])
        try store.saveSet(set)

        let response = await service.post("/api/bench/run", json: #"{"setId":"card-probe"}"#)
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        let id = try XCTUnwrap(response.jsonDictionary?["runId"] as? String)
        let run = try XCTUnwrap(store.run(id: id))
        let cell = try XCTUnwrap(run.cells.first)
        XCTAssertNil(cell.error, String(describing: cell.error))
        XCTAssertTrue(cell.items.contains {
            $0.fields["kind"] == "card" && $0.fields["path"] == "memory/cc/seedlab-001.md"
        }, "\(cell.items)")
        XCTAssertEqual(run.judgments.filter { $0.cellId == cell.id }.map(\.verdict), [.right])
    }
}

/// E2-6：副本 `exports/floor-snapshot-*.json` 认出来 → `GET /api/status` 报快照；没有 / 楼层对不上单独说
final class MemorydStatusAPITests: XCTestCase {
    private var floor: URL!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
    }

    override func tearDownWithError() throws {
        if let floor { MemorydFixture.remove(floor) }
    }

    func testStatusReportsExportedSnapshot() async throws {
        let service = try MemorydFixture.service(floor)
        let response = await service.get("/api/status")
        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(response.jsonDictionary)
        XCTAssertEqual(object["profileId"] as? String, "memoryd-test")
        XCTAssertEqual(object["floor"] as? String, floor.path)
        let snapshot = try XCTUnwrap(object["conversationSnapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["file"] as? String, "exports/floor-snapshot-20261108-080000Z.json")
        XCTAssertEqual(snapshot["windows"] as? Int, 2, "回收站窗口也算")
        XCTAssertEqual(snapshot["nodes"] as? Int, 9)
        XCTAssertEqual(snapshot["schema"] as? Int, 2)
        XCTAssertEqual((snapshot["exportedAt"] as? NSNumber)?.int64Value, 1_794_124_800_000)
        XCTAssertEqual(object["note"] as? String,
                       "快照顶层 profileId（xingyan-floor）与 --profile-id（memoryd-test）不一致",
                       "顶层楼层对不上也说一句（窗口能读照读）")

        let maybeSource = await service.conversations
        let source = try XCTUnwrap(maybeSource)
        let windows = try source.windows(profileId: "memoryd-test", updatedSince: nil, includeTrashed: true)
        XCTAssertEqual(windows.count, 2, "快照里没有 profileId 的窗口按 --profile-id 归属")
    }

    func testWithoutExportsStatusSaysNoSnapshot() async throws {
        try FileManager.default.removeItem(at: floor.appendingPathComponent("exports", isDirectory: true))
        let service = try MemorydFixture.service(floor)
        let response = await service.get("/api/status")
        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(response.jsonDictionary)
        XCTAssertTrue(object["conversationSnapshot"] is NSNull)
        XCTAssertTrue((object["note"] as? String ?? "").contains("无对话快照"))
        let source = await service.conversations
        XCTAssertNil(source)
    }

    func testSnapshotForAnotherFloorIsReportedAsMismatch() async throws {
        let other = #"""
        {"schema": 2, "profileId": "另一个楼层", "windows": [
          {"id": "w", "title": "别层", "current": "n1", "memoryEnabled": true, "trashed": false,
           "profileId": "另一个楼层", "nodes": [{"id": "n1", "role": "user", "text": "甲", "at": 1793494800000}]}
        ]}
        """#
        let exports = floor.appendingPathComponent("exports", isDirectory: true)
        try other.write(to: exports.appendingPathComponent("floor-snapshot-20261109-000000Z.json"),
                        atomically: true, encoding: .utf8)

        let service = try MemorydFixture.service(floor)
        let response = await service.get("/api/status")
        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(response.jsonDictionary)
        let snapshot = try XCTUnwrap(object["conversationSnapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["file"] as? String, "exports/floor-snapshot-20261109-000000Z.json", "按文件名取最新")
        XCTAssertEqual(snapshot["windows"] as? Int, 1)
        let note = object["note"] as? String ?? ""
        XCTAssertTrue(note.contains("没有本楼层的窗口"), note)
        XCTAssertTrue(note.contains("快照顶层 profileId"), "顶层 profileId 对不上单独说一句：\(note)")
    }

    /// schema 1 风格快照（无 `schema` / `exportedAt` / 顶层 `profileId`，窗口无 `profileId`）：认得出、状态里为 null、不念 note
    func testSchemaOneStyleSnapshotStatusHasNoMetadataAndNoNote() async throws {
        let legacy = #"""
        {"windows": [
          {"id": "w", "title": "旧快照", "current": "n1", "memoryEnabled": true, "trashed": false,
           "nodes": [{"id": "n1", "role": "user", "text": "乙", "at": 1793494800000}]}
        ]}
        """#
        let exports = floor.appendingPathComponent("exports", isDirectory: true)
        try legacy.write(to: exports.appendingPathComponent("floor-snapshot-20261201-000000Z.json"),
                         atomically: true, encoding: .utf8)

        let service = try MemorydFixture.service(floor)
        let response = await service.get("/api/status")
        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(response.jsonDictionary)
        let snapshot = try XCTUnwrap(object["conversationSnapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["file"] as? String, "exports/floor-snapshot-20261201-000000Z.json")
        XCTAssertTrue(snapshot["exportedAt"] is NSNull, "旧快照没有导出的时间")
        XCTAssertTrue(snapshot["schema"] is NSNull, "旧快照没有 schema")
        XCTAssertNil(object["note"], "窗口按 --profile-id 归属、顶层没写 profileId，不念")
    }

    /// 超大毫秒时间不能把 status 转 Int64 转炸：输出 null + note
    func testOutOfRangeExportedAtReportsNullInsteadOfTrapping() async throws {
        let huge = #"""
        {"windows": [], "exportedAt": 9223372036854775807}
        """#
        let exports = floor.appendingPathComponent("exports", isDirectory: true)
        try huge.write(to: exports.appendingPathComponent("floor-snapshot-20990101-000000Z.json"),
                       atomically: true, encoding: .utf8)

        let service = try MemorydFixture.service(floor)
        let response = await service.get("/api/status")
        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(response.jsonDictionary)
        let snapshot = try XCTUnwrap(object["conversationSnapshot"] as? [String: Any])
        XCTAssertTrue(snapshot["exportedAt"] is NSNull, "越界时间输出 null")
        XCTAssertTrue((object["note"] as? String ?? "").contains("exportedAt 越界"), "\(object)")
    }

    /// 字典序更大的同名前缀目录不能遮住真正的快照文件
    func testDirectoryNamedLikeSnapshotIsSkipped() async throws {
        let fakeDir = floor.appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("floor-snapshot-20991231-000000Z.json", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)

        let service = try MemorydFixture.service(floor)
        let response = await service.get("/api/status")
        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(response.jsonDictionary)
        let snapshot = try XCTUnwrap(object["conversationSnapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["file"] as? String, "exports/floor-snapshot-20261108-080000Z.json",
                       "目录不合格，取下一个候选")
    }
}
