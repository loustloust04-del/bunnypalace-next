import XCTest
import MemoryCore
@testable import memoryd

/// `scripts/real-set-a-assemble.sh`：seedlab 页提案 + 要点卡 + CC 原料 → memoryd 可挂的楼层副本 + 自召回题集
final class RealSetAssembleTests: XCTestCase {
    private var temp: URL!
    private var seedlab: URL!
    private var cc: URL!
    private var root: URL!

    private let stamp = "20260101T000000000Z"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MemorydTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // MemoryCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // 仓库根
    }

    private var script: URL { repoRoot.appendingPathComponent("scripts/real-set-a-assemble.sh") }
    private var mountScript: URL { repoRoot.appendingPathComponent("scripts/memoryd-mount.sh") }
    private var fixtureFloor: URL { repoRoot.appendingPathComponent("Packages/MemoryCore/Tests/MemoryCoreTests/Fixtures/memoryd-floor") }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("real-set-assemble-\(UUID().uuidString)", isDirectory: true)
        seedlab = temp.appendingPathComponent("seedlab-run", isDirectory: true)
        cc = temp.appendingPathComponent("cc materials", isDirectory: true)
        root = temp.appendingPathComponent("floor-snapshots", isDirectory: true)
        let fm = FileManager.default

        let pages = seedlab.appendingPathComponent("proposal-pages", isDirectory: true)
        try fm.createDirectory(at: pages, withIntermediateDirectories: true)
        let wiki = fixtureFloor.appendingPathComponent("wiki", isDirectory: true)
        for group in try fm.contentsOfDirectory(atPath: wiki.path) where !group.hasPrefix(".") {
            try fm.copyItem(at: wiki.appendingPathComponent(group), to: pages.appendingPathComponent(group))
        }
        try fm.copyItem(at: wiki.appendingPathComponent(".cards"), to: seedlab.appendingPathComponent(".cards"))

        let outside = temp.appendingPathComponent("outside.md")
        try "外部".write(to: outside, atomically: true, encoding: .utf8)
        try "私密卡".write(to: seedlab.appendingPathComponent(".cards/private_卡.json"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: seedlab.appendingPathComponent(".cards/链卡.json"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: pages.appendingPathComponent("地点/链页.md"), withDestinationURL: outside)

        try fm.createDirectory(at: cc, withIntermediateDirectories: true)
        let fixture = repoRoot.appendingPathComponent("scripts/seedlab/fixture")
        for name in try fm.contentsOfDirectory(atPath: fixture.path) where name.hasSuffix(".txt") {
            try fm.copyItem(at: fixture.appendingPathComponent(name),
                            to: cc.appendingPathComponent(String(name.dropLast(4)) + ".md"))
        }
        try fm.copyItem(at: fixture.appendingPathComponent("manifest.json"), to: cc.appendingPathComponent("manifest.json"))
        try "私密原料".write(to: cc.appendingPathComponent("private_原料.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: cc.appendingPathComponent("链原料.md"), withDestinationURL: outside)
    }

    override func tearDownWithError() throws {
        if let temp { try? FileManager.default.removeItem(at: temp) }
    }

    @discardableResult
    private func run(_ arguments: [String], stamp stampValue: String? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["MP_REAL_SET_STAMP"] = stampValue ?? stamp
        return try runProcess("/bin/bash", [script.path] + arguments, environment: environment)
    }

    private func runProcess(_ executable: String, _ arguments: [String],
                            environment: [String: String]? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    private var targetMemory: URL { root.appendingPathComponent("\(stamp)/memory", isDirectory: true) }
    private var pages: URL { seedlab.appendingPathComponent("proposal-pages", isDirectory: true) }
    private var cards: URL { seedlab.appendingPathComponent(".cards", isDirectory: true) }

    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func selfRecallSet(_ snapshotStamp: String? = nil) throws -> [String: Any] {
        let url = root.appendingPathComponent("\(snapshotStamp ?? stamp)/memory/bench-runs/sets/self-recall.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func selfRecallCases(_ snapshotStamp: String? = nil) throws -> [[String: Any]] {
        try XCTUnwrap(try selfRecallSet(snapshotStamp)["cases"] as? [[String: Any]])
    }

    private func queries(_ cases: [[String: Any]]) -> [String: String] {
        var out: [String: String] = [:]
        for item in cases {
            let keys = (item["labels"] as? [[String: Any]])?.first?["keys"] as? [String] ?? []
            if let key = keys.first, let query = (item["input"] as? [String: Any])?["query"] as? String {
                out[key] = query
            }
        }
        return out
    }

    func testAssemblesLayoutSkipRulesAndSelfRecallSet() throws {
        let result = try run([seedlab.path, cc.path, root.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 1, "只输出一行计数：\(result.stdout)")
        for name in ["云桥城", "星砚", "岚舟", "风铃", "private_雾岛", "seedlab-001"] {
            XCTAssertFalse(result.stdout.contains(name), "计数行不能带页名 / 文件名：\(result.stdout)")
        }
        XCTAssertTrue(result.stdout.contains("页 4 组 4 卡 1 cc 20 题 4"), result.stdout)
        XCTAssertTrue(result.stdout.contains("跳过 private_* 3 链接 3"), result.stdout)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: targetMemory.appendingPathComponent("wiki/地点/云桥城.md").path))
        XCTAssertTrue(fm.fileExists(atPath: targetMemory.appendingPathComponent("wiki/{{user}}/岚舟.md").path))
        XCTAssertTrue(fm.fileExists(atPath: targetMemory.appendingPathComponent("wiki/人/.group.md").path))
        XCTAssertFalse(fm.fileExists(atPath: targetMemory.appendingPathComponent("wiki/人/private_雾岛.md").path))
        XCTAssertFalse(fm.fileExists(atPath: targetMemory.appendingPathComponent("wiki/地点/链页.md").path))

        let cards = try fm.contentsOfDirectory(atPath: targetMemory.appendingPathComponent("wiki/.cards").path)
        XCTAssertEqual(cards, ["78befea21f6dc6680625dbcb87745e704d7dcecc63abd27541f34c27e42f36c2.json"],
                       "卡要落在 wiki/.cards/<key>.json")

        let ccFiles = try fm.contentsOfDirectory(atPath: targetMemory.appendingPathComponent("cc").path)
        XCTAssertEqual(ccFiles.filter { $0.hasSuffix(".md") }.count, 20)
        XCTAssertFalse(ccFiles.contains("manifest.json"))
        XCTAssertFalse(ccFiles.contains("private_原料.md"))
        XCTAssertFalse(ccFiles.contains("链原料.md"))

        let data = try Data(contentsOf: targetMemory.appendingPathComponent("bench-runs/sets/self-recall.json"))
        let set = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(set["id"] as? String, "self-recall")
        XCTAssertEqual(set["writer"] as? String, "wiki")
        XCTAssertEqual(set["source"] as? String, "floor")
        XCTAssertTrue((set["note"] as? String ?? "").contains("钩子 → 本页"))
        let cases = try XCTUnwrap(set["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        var keys = Set<String>()
        for (index, item) in cases.enumerated() {
            let title = try XCTUnwrap(item["title"] as? String)
            XCTAssertEqual(title, "自召回 #\(index + 1)")
            for name in ["云桥城", "星砚", "岚舟", "风铃", "private_雾岛"] {
                XCTAssertFalse(title.contains(name), "题目标题不能带页名：\(title)")
            }
            let input = try XCTUnwrap(item["input"] as? [String: Any])
            XCTAssertFalse((input["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let labels = try XCTUnwrap(item["labels"] as? [[String: Any]])
            XCTAssertEqual(labels.count, 1)
            XCTAssertEqual(labels[0]["kind"] as? String, "必须带")
            keys.formUnion(labels[0]["keys"] as? [String] ?? [])
        }
        XCTAssertEqual(keys, ["page:人/星砚", "page:地点/云桥城", "page:主题/风铃", "page:{{user}}/岚舟"])
    }

    func testRefusesExistingNonEmptySnapshot() throws {
        let first = try run([seedlab.path, cc.path, root.path])
        XCTAssertEqual(first.status, 0, first.stderr)
        let second = try run([seedlab.path, cc.path, root.path])
        XCTAssertNotEqual(second.status, 0)
        XCTAssertTrue(second.stdout.isEmpty)
        XCTAssertTrue(second.stderr.contains("已存在且非空"), second.stderr)
    }

    func testPermissionErrorStaysPathFreeAndCleansStaging() throws {
        let page = pages.appendingPathComponent("人/星砚.md")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: page.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: page.path) }

        let result = try run([seedlab.path, cc.path, root.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("errno 13"), result.stderr)
        XCTAssertFalse(result.stderr.contains("星砚"), "stderr 不能带页名：\(result.stderr)")
        XCTAssertFalse(result.stderr.contains("Traceback"), "stderr 不能带 Traceback：\(result.stderr)")
        let leftovers = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".\(stamp).tmp-") }, "临时目录没清：\(leftovers)")
    }

    func testSkipsCardsWhosePathIsPrivate() throws {
        try write(#"{"path":"memory/cc/Private_原料.md","version":"v1"}"#, at: cards.appendingPathComponent("aaaa.json"))
        try write("不是 JSON", at: cards.appendingPathComponent("bbbb.json"))

        let result = try run([seedlab.path, cc.path, root.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("卡 2"), "私密卡要跳过、坏卡照拷：\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("跳过 private_* 4"), result.stdout)
        let staged = try FileManager.default.contentsOfDirectory(atPath: targetMemory.appendingPathComponent("wiki/.cards").path)
        XCTAssertFalse(staged.contains("aaaa.json"))
        XCTAssertTrue(staged.contains("bbbb.json"))
    }

    func testBodyHookFeedsQuery() throws {
        try write("# 正文钩页\n\n> 钩子：正文里的钩子\n", at: pages.appendingPathComponent("物/正文钩.md"))

        let result = try run([seedlab.path, cc.path, root.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try queries(selfRecallCases())["page:物/正文钩"], "正文里的钩子")
    }

    func testWhitespaceParityWithWikiStore() throws {
        try write("---\n触发词: \"' 辛壳 '\"\n---\n", at: pages.appendingPathComponent("人/辛壳.md"))
        try write("# 换行段\n", at: pages.appendingPathComponent("人/换行\n.md"))

        let result = try run([seedlab.path, cc.path, root.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("页 6 组 4"), "换行段名要算一页：\(result.stdout)")
        let byKey = try queries(selfRecallCases())
        XCTAssertEqual(byKey["page:人/辛壳"], "辛壳")
        XCTAssertEqual(byKey["page:人/换行\n"], "换行段")
    }

    func testSkipsUpperAndMixedCasePrivateAndLinkedFolders() throws {
        let fm = FileManager.default
        try write("# 私密\n", at: pages.appendingPathComponent("Private_分组/x.md"))
        try write("# 私密\n", at: pages.appendingPathComponent("人/PRIVATE_丙.md"))
        try write("私密", at: cc.appendingPathComponent("PRIVATE_秘钥.md"))
        let outside = temp.appendingPathComponent("外部目录", isDirectory: true)
        try write("# 外\n", at: outside.appendingPathComponent("外.md"))
        try fm.createSymbolicLink(at: pages.appendingPathComponent("主题/链组"), withDestinationURL: outside)

        let result = try run([seedlab.path, cc.path, root.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("页 4 组 4 卡 1 cc 20 题 4"), result.stdout)
        XCTAssertTrue(result.stdout.contains("跳过 private_* 6 链接 4"), result.stdout)
        XCTAssertFalse(fm.fileExists(atPath: targetMemory.appendingPathComponent("wiki/Private_分组").path))
        XCTAssertFalse(fm.fileExists(atPath: targetMemory.appendingPathComponent("wiki/人/PRIVATE_丙.md").path))
        XCTAssertFalse(fm.fileExists(atPath: targetMemory.appendingPathComponent("wiki/主题/链组").path))
        XCTAssertFalse(fm.fileExists(atPath: targetMemory.appendingPathComponent("cc/PRIVATE_原料.md").path))
    }

    func testLinkedCardsDirectoryIsSkipped() throws {
        let fm = FileManager.default
        let real = temp.appendingPathComponent("真卡片", isDirectory: true)
        try fm.moveItem(at: cards, to: real)
        try fm.createSymbolicLink(at: cards, withDestinationURL: real)

        let result = try run([seedlab.path, cc.path, root.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("卡 0"), result.stdout)
        XCTAssertTrue(result.stdout.contains("跳过 private_* 2 链接 3"), result.stdout)
        XCTAssertFalse(fm.fileExists(atPath: targetMemory.appendingPathComponent("wiki/.cards").path))
    }

    func testLinkedProposalPagesIsRefused() throws {
        let fm = FileManager.default
        let real = temp.appendingPathComponent("真页面", isDirectory: true)
        try fm.moveItem(at: pages, to: real)
        try fm.createSymbolicLink(at: pages, withDestinationURL: real)

        let result = try run([seedlab.path, cc.path, root.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("没有 proposal-pages 文件夹"), result.stderr)
        XCTAssertFalse(fm.fileExists(atPath: root.path))
    }

    func testRefusesSnapshotRootInGitRepoOrInsideInput() throws {
        let fm = FileManager.default
        let repo = temp.appendingPathComponent("假仓库", isDirectory: true)
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let inRepo = repo.appendingPathComponent("snaps", isDirectory: true)
        let repoResult = try run([seedlab.path, cc.path, inRepo.path])
        XCTAssertNotEqual(repoResult.status, 0)
        XCTAssertTrue(repoResult.stderr.contains("git 仓库"), repoResult.stderr)
        XCTAssertFalse(fm.fileExists(atPath: inRepo.path))

        let before = try fm.contentsOfDirectory(atPath: seedlab.path).sorted()
        let insideSeedlab = seedlab.appendingPathComponent("snap", isDirectory: true)
        let seedlabResult = try run([seedlab.path, cc.path, insideSeedlab.path])
        XCTAssertNotEqual(seedlabResult.status, 0)
        XCTAssertTrue(seedlabResult.stderr.contains("不能放在输入目录里面"), seedlabResult.stderr)
        XCTAssertFalse(fm.fileExists(atPath: insideSeedlab.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: seedlab.path).sorted(), before)

        let insideCC = cc.appendingPathComponent("snap", isDirectory: true)
        let ccResult = try run([seedlab.path, cc.path, insideCC.path])
        XCTAssertNotEqual(ccResult.status, 0)
        XCTAssertFalse(fm.fileExists(atPath: insideCC.path))
    }

    func testCapsAtSixtyRoundRobinAcrossGroups() throws {
        let fm = FileManager.default
        try fm.removeItem(at: pages)
        try fm.createDirectory(at: pages, withIntermediateDirectories: true)
        for index in 0..<40 {
            try write("---\n钩子: 人组题 \(index)\n---\n",
                     at: pages.appendingPathComponent(String(format: "人/p%02d.md", index)))
        }
        for index in 0..<26 {
            try write("---\n钩子: 项目组题 \(index)\n---\n",
                     at: pages.appendingPathComponent(String(format: "项目/q%02d.md", index)))
        }

        let first = try run([seedlab.path, cc.path, root.path], stamp: "20260101T000000000Z")
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertTrue(first.stdout.contains("页 66 组 2 卡 1 cc 20 题 60"), first.stdout)
        let set = try selfRecallSet("20260101T000000000Z")
        XCTAssertTrue((set["note"] as? String ?? "").contains("共 66 页，各组轮流取前 60"), set["note"] as? String ?? "")
        let cases = try selfRecallCases("20260101T000000000Z")
        XCTAssertEqual(cases.count, 60)
        var perGroup: [String: Int] = [:]
        for key in queries(cases).keys {
            let group = key.dropFirst("page:".count).split(separator: "/").first.map(String.init) ?? ""
            perGroup[group, default: 0] += 1
        }
        XCTAssertEqual(perGroup["人"], 34)
        XCTAssertEqual(perGroup["项目"], 26)

        let second = try run([seedlab.path, cc.path, root.path], stamp: "20260102T000000000Z")
        XCTAssertEqual(second.status, 0, second.stderr)
        let firstData = try Data(contentsOf: root.appendingPathComponent("20260101T000000000Z/memory/bench-runs/sets/self-recall.json"))
        let secondData = try Data(contentsOf: root.appendingPathComponent("20260102T000000000Z/memory/bench-runs/sets/self-recall.json"))
        XCTAssertEqual(firstData, secondData)
    }

    /// 端到端：组装 → `memoryd-mount.sh` → memoryd 跑 `self-recall`
    func testSelfRecallRunsThroughMountedCopy() async throws {
        let assembled = try run([seedlab.path, cc.path, root.path])
        XCTAssertEqual(assembled.status, 0, assembled.stderr)

        let copy = temp.appendingPathComponent("mounted", isDirectory: true)
        let mounted = try runProcess("/bin/bash", [mountScript.path, targetMemory.path, copy.path])
        XCTAssertEqual(mounted.status, 0, mounted.stderr)

        let service = try MemorydService(config: .init(floor: copy, profileId: "self-recall-e2e", allowUnmounted: false),
                                         webRoot: MemorydResources.webRoot)
        service.bind(port: MemorydTestPort.value)

        let sets = await service.get("/api/bench/sets")
        let list = try XCTUnwrap(sets.jsonDictionary?["sets"] as? [[String: Any]])
        let selfRecall = try XCTUnwrap(list.first { $0["id"] as? String == "self-recall" })
        XCTAssertEqual(selfRecall["runnable"] as? Bool, true)
        XCTAssertEqual(selfRecall["caseCount"] as? Int, 4)

        let response = await service.post("/api/bench/run", json: #"{"setId":"self-recall"}"#)
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        let body = try XCTUnwrap(response.jsonDictionary)
        XCTAssertEqual(body["cells"] as? Int, 4)
        XCTAssertEqual(body["measurable"] as? Int, 4)

        let runId = try XCTUnwrap(body["runId"] as? String)
        let store = MemoryBenchStore(root: copy.appendingPathComponent("bench-runs", isDirectory: true))
        let run = try XCTUnwrap(store.run(id: runId))
        let main = try XCTUnwrap(run.scores.first?.main)
        XCTAssertEqual(main, 0.25, accuracy: 1e-12, "夹具固定，1/4 判对")
        print("self-recall 主分：\(main)（\(run.judgments.filter { $0.verdict == .right }.count)/\(run.judgments.count) 判对）")
    }
}
