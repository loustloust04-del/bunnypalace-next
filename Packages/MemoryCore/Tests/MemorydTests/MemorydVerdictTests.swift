import XCTest
import MemoryCore
@testable import memoryd

/// 实验台的「写完再对着档案下结论」：两种拿材料的办法、每次调用都进调用记录、裁判的两种判法、请求不对怎么拒。
/// 模型是假的（按 system 认是哪种调用，回写好的 JSON）；材料全虚构
final class MemorydVerdictTests: XCTestCase {
    private var floor: URL!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
    }

    override func tearDownWithError() throws {
        if let floor { MemorydFixture.remove(floor) }
    }

    /// 夹具里 a2 / a3 这次排到了第几张已有的卡（E几）
    private static let labels: (a2: String, a3: String) = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MemoryCoreTests/Fixtures/verdict-round-yunqiao.json")
        let job = try! JSONDecoder().decode(FragmentVerdict.Job.self, from: Data(contentsOf: url))
        let existing = FragmentVerdict.related(to: job.newCards, in: job.archive).existing.map(\.id)
        return ("E\(existing.firstIndex(of: "a2")! + 1)", "E\(existing.firstIndex(of: "a3")! + 1)")
    }()

    private static let verdictReply = """
    {"verdicts":[{"card":"N1","verdict":"drop","reason":"in_prompt","why":"用户资料里有"},{"card":"N2","verdict":"merge","ref":"\(labels.a3)","text":"改带锁的"},
    {"card":"N3","verdict":"keep"},{"card":"N4","verdict":"merge","ref":"\(labels.a2)"}]}
    """

    /// 假模型：OpenAI 兼容的回包；记下每次收到的 system
    private func fakeModel(reply: String = MemorydVerdictTests.verdictReply, seen: @escaping @Sendable (String) -> Void = { _ in }) -> MemorydModel {
        MemorydModel(base: URL(string: "https://model.invalid/v1")!, modelId: "fake-model", key: "k", wire: .openai) { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let system = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            seen(system)
            let text: String
            if system.hasPrefix("你是裁判。") {
                text = #"{"related":[{"card":"N4","same":["P2","P99"]},{"card":"N8","same":["P13"]}]}"#
            } else if system.hasPrefix("你是裁判，") {
                text = #"{"rulings":[{"card":"N1","ok":true,"should":"drop","reason":"in_prompt","why":"对"},{"card":"N3","ok":false,"should":"merge","ref":"E1","why":"并错了"}]}"#
            } else {
                text = reply
            }
            let reply: [String: Any] = ["choices": [["message": ["content": text], "finish_reason": "stop"]],
                                        "usage": ["prompt_tokens": 100, "completion_tokens": 20]]
            return (try JSONSerialization.data(withJSONObject: reply),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func service(model: MemorydModel?) throws -> MemorydService {
        let service = try MemorydService(config: .init(floor: floor, profileId: "memoryd-test", allowUnmounted: true, model: model),
                                         webRoot: MemorydResources.webRoot)
        service.bind(port: MemorydTestPort.value)
        return service
    }

    private func fixtureJob() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MemoryCoreTests/Fixtures/verdict-round-yunqiao.json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func finished(_ id: String, on service: MemorydService) async throws -> [String: Any] {
        for _ in 0..<200 {
            let detail = await service.get("/api/experiments/\(id)").jsonDictionary ?? [:]
            if detail["status"] as? String != "running" { return detail }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("一直没跑完")
        return [:]
    }

    func testInlineJobRunsEveryModelAndLogsEveryCall() async throws {
        let seen = SeenSystems()
        let service = try service(model: fakeModel { seen.add($0) })
        let started = await service.post("/api/c2/verdict", json: """
        {"name":"虚构夹具","job":\(try fixtureJob()),"runs":[{"model":"fake-model","times":2}],
         "judge":"fake-model","judgeRelated":true,"judgeRuns":true,"probeKeepAll":true}
        """)
        XCTAssertEqual(started.status, 200, String(decoding: started.body, as: UTF8.self))
        let id = try XCTUnwrap(started.jsonDictionary?["id"] as? String)
        XCTAssertEqual(started.jsonDictionary?["newCards"] as? Int, 11)
        XCTAssertEqual(started.jsonDictionary?["pool"] as? Int, 15)
        let detail = try await finished(id, on: service)
        XCTAssertEqual(detail["status"] as? String, "done")
        XCTAssertEqual(detail["model"] as? String, "fake-model×2")
        XCTAssertEqual((detail["options"] as? [String: Any])?["steps"] as? [String], ["verdict"])
        let report = try XCTUnwrap(detail["verdict"] as? [String: Any])
        XCTAssertEqual(report["name"] as? String, "虚构夹具")
        XCTAssertEqual(report["lines"] as? Int, 23)
        let job = try JSONDecoder().decode(FragmentVerdict.Job.self, from: Data(try fixtureJob().utf8))
        XCTAssertEqual(report["residentChars"] as? Int, job.resident.reduce(0) { $0 + $1.text.count })
        XCTAssertEqual(report["residentCut"] as? Int, 0)
        let runs = try XCTUnwrap(report["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.map { $0["n"] as? Int }, [1, 2, 1], "最后一份是造出来的「全部留下」对照")
        XCTAssertEqual(runs.last?["model"] as? String, MemorydVerdictRequest.probeModel)
        XCTAssertEqual((runs.last?["verdicts"] as? [[String: Any]])?.map { $0["action"] as? String }, Array(repeating: "keep", count: 11))
        let verdicts = try XCTUnwrap(runs.first?["verdicts"] as? [[String: Any]])
        XCTAssertEqual(verdicts.count, 11, "模型只交了 4 张，剩下的也各有一条")
        XCTAssertEqual(verdicts.prefix(5).map { $0["action"] as? String }, ["drop", "unsure", "keep", "merge", "unsure"])
        XCTAssertEqual(verdicts[1]["downgraded"] as? String, "想改一条不许改的记忆条目（岚舟 亲手改过、钉住的，或已经整理进页的）")
        XCTAssertEqual(verdicts[4]["downgraded"] as? String, "模型没给这张结论")
        XCTAssertEqual((runs.first?["signals"] as? [String: [String]])?["n5"], ["citedOther"])
        let related = try XCTUnwrap(report["related"] as? [String: Any])
        XCTAssertEqual(related["same"] as? [String: [String]], ["n4": ["a2"], "n8": ["x1"]], "池里没有的编号丢掉")
        let judged = try XCTUnwrap(report["judged"] as? [[String: Any]])
        XCTAssertEqual(judged.map { $0["model"] as? String }, [MemorydVerdictRequest.probeModel], "裁判不判自己跑的那一次；那份对照要判")
        let rulings = try XCTUnwrap(judged.first?["rulings"] as? [[String: Any]])
        XCTAssertEqual(rulings.map { $0["should"] as? String }, ["drop:in_prompt", "merge:E1"])

        // 每次调用一行，吃进去的和回出来的都能取到
        let log = try XCTUnwrap(detail["callLog"] as? [[String: Any]])
        XCTAssertEqual(log.map { $0["step"] as? String }, ["verdict", "verdict", "judge", "judge"])
        XCTAssertEqual(detail["calls"] as? Int, 4)
        XCTAssertEqual(detail["inputTokens"] as? Int, 400)
        let firstCall = await service.get("/api/experiments/\(id)/calls/1").jsonDictionary
        let first = try XCTUnwrap(firstCall)
        let system = try XCTUnwrap(first["system"] as? String)
        XCTAssertTrue(system.hasPrefix("你在核对一批刚写好的记忆条目。这些卡是从 岚舟 和 星砚 的一段对话里记下来的"))
        XCTAssertTrue(system.contains("### 用户资料\n岚舟住在云桥城。"), "聊天时带着的内容在 system 里")
        XCTAssertFalse(system.contains("写成页"), "请求里没要 wiki 页：副本里有页也不带，和以前发的一样")
        XCTAssertEqual(report["wikiPages"] as? Int, 0)
        XCTAssertEqual(report["existingWhole"] as? Bool, true, "池子放得下：没删的 12 张全给")
        XCTAssertEqual((report["existing"] as? [String])?.count, 12)
        XCTAssertTrue((first["user"] as? String)?.contains("[N11] 今天手指被胶水粘住了。（关于：岚舟；") == true)
        XCTAssertEqual(first["reply"] as? String, Self.verdictReply)
        let rulingCall = await service.get("/api/experiments/\(id)/calls/4").jsonDictionary
        let ruling = try XCTUnwrap(rulingCall)
        let brief = try XCTUnwrap(ruling["user"] as? String)
        XCTAssertTrue(brief.contains("## 任务说明\n\n你在核对一批刚写好的记忆条目。") && brief.contains("## 材料\n\n这段对话所在的窗口叫「模型船」。"))
        XCTAssertTrue(brief.hasSuffix("## 它交的结论\n\n" + (1...11).map { "N\($0)：keep" }.joined(separator: "\n")), "裁判拿到的是那份「全部留下」")
        // 真结论写给裁判看是什么样
        let material = FragmentVerdict.Material(job: job, related: FragmentVerdict.related(to: job.newCards, in: job.archive))
        let shown = MemorydVerdictRunner.rendered(try FragmentVerdict.decoded(Self.verdictReply, material: material).verdicts, material: material)
        XCTAssertTrue(shown.hasPrefix("N1：drop（reason：in_prompt） —— 用户资料里有\nN2：unsure（它本来交的是 merge，因为「想改一条不许改的记忆条目（岚舟 亲手改过、钉住的，或已经整理进页的）」被改成了拿不准）\nN3：keep\nN4：merge（ref \(Self.labels.a2)，不改它）\nN5：unsure（因为「模型没给这张结论」被改成了拿不准）"))
        XCTAssertEqual(Set(seen.all).count, 3, "下结论、判捞卡、判结论三种 system")

        // 列表里有它；存了盘，换一个服务也读得到
        let list = await service.get("/api/experiments").jsonDictionary?["experiments"] as? [[String: Any]]
        XCTAssertEqual(list?.first?["id"] as? String, id)
        let again = try self.service(model: nil)
        let stored = await again.get("/api/experiments/\(id)").jsonDictionary
        XCTAssertEqual((stored?["verdict"] as? [String: Any])?["name"] as? String, "虚构夹具")
        let prompt = await service.get("/api/c2/verdict/prompt").jsonDictionary?["text"] as? String
        XCTAssertEqual(prompt, FragmentVerdict.instructions(names: .init(userName: "{u}", assistantName: "{c}")))
    }

    /// 拿写卡实验的一批当新卡：原文从快照取，别的实验的卡当池子，点名哪几张算删过的 / 带锁的
    func testJobFromAnEarlierWriteExperiment() async throws {
        func card(_ message: Int, _ content: String) -> MemorydExperiment.Card {
            .init(message: message, content: content, subject: "岚舟", speaker: "用户自述", category: "fact", importance: 3, tags: [])
        }
        func experiment(_ id: String, conversation: String, batches: [MemorydExperiment.FragmentBatch]) -> MemorydExperiment {
            var options = MemorydExperiment.Options(conversationId: conversation)
            options.userName = "岚舟"
            options.assistantName = "星砚"
            options.steps = ["c2"]
            var e = MemorydExperiment(id: id, at: Date(), status: "done", options: options, windowTitle: "潮汐与航图", model: "fake-model",
                                      totalMessages: 4, ranMessages: 4)
            e.fragments = batches
            return e
        }
        let source = experiment("11111111-1111-1111-1111-111111111111", conversation: "xingyan-window-0001", batches: [
            .init(from: 1, to: 2, cards: [card(1, "更早的一张")]),
            .init(from: 3, to: 4, cards: [card(3, "潮水子夜才退。"), card(4, "第二张"), card(9, "出处对不上的")]),
        ])
        let other = experiment("22222222-2222-2222-2222-222222222222", conversation: "别的窗口", batches: [
            .init(from: 1, to: 9, cards: [card(1, "潮水要到子夜才退。"), card(2, "带锁的一张，说潮水。"), card(3, "第三张，说航图。")]),
        ])
        let dir = floor.appendingPathComponent("bench-runs/experiments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        for e in [source, other] { try encoder.encode(e).write(to: dir.appendingPathComponent(e.id + ".json")) }
        try "人设全文\n第二行".write(to: floor.appendingPathComponent("exports/resident.md"), atomically: true, encoding: .utf8)

        let service = try service(model: fakeModel())
        let started = await service.post("/api/c2/verdict", json: """
        {"experiment":"\(source.id)","batch":1,"residentFile":"resident.md",
         "archive":[{"experiment":"\(source.id)","batches":[0]},{"experiment":"\(other.id)","deleted":[0],"protected":[1]}],
         "runs":[{"model":"fake-model"}]}
        """)
        XCTAssertEqual(started.status, 200, String(decoding: started.body, as: UTF8.self))
        let id = try XCTUnwrap(started.jsonDictionary?["id"] as? String)
        let detail = try await finished(id, on: service)
        let report = try XCTUnwrap(detail["verdict"] as? [String: Any])
        XCTAssertEqual(report["lines"] as? Int, 2, "第 3–4 条")
        XCTAssertEqual(report["residentChars"] as? Int, 8)
        let new = try XCTUnwrap(report["newCards"] as? [[String: Any]])
        XCTAssertEqual(new.map { $0["message"] as? Int }, [1, 2, nil], "出处换成这一批里的第几条；对不上的不带")
        let pool = try XCTUnwrap(report["pool"] as? [[String: Any]])
        XCTAssertEqual(pool.map { $0["id"] as? String }, ["p1.1", "p2.1", "p2.2", "p2.3"])
        XCTAssertEqual(pool.map { $0["otherWindow"] as? Bool }, [false, true, true, true])
        XCTAssertEqual(pool.map { $0["isDeleted"] as? Bool }, [false, true, false, false])
        XCTAssertEqual(pool.map { $0["isProtected"] as? Bool }, [false, false, true, false])
        let callBody = await service.get("/api/experiments/\(id)/calls/1").jsonDictionary
        let call = try XCTUnwrap(callBody)
        XCTAssertTrue((call["system"] as? String)?.hasSuffix("### 聊天时带着的提示词\n人设全文\n第二行") == true)
        let user = try XCTUnwrap(call["user"] as? String)
        XCTAssertTrue(user.contains("这段对话所在的窗口叫「潮汐与航图」。"))
        XCTAssertTrue(user.contains("## 原文（#1–#2）\n\n#1 "))
        XCTAssertTrue(user.contains("## 删过的卡\n\n[D1] 潮水要到子夜才退。（关于：岚舟）"))

        let missing = await service.post("/api/c2/verdict", json: #"{"experiment":"\#(source.id)","batch":7,"runs":[{"model":"fake-model"}]}"#)
        XCTAssertEqual(missing.status, 400)
        let outside = await service.post("/api/c2/verdict",
                                         json: #"{"experiment":"\#(source.id)","residentFile":"../x","runs":[{"model":"fake-model"}]}"#)
        XCTAssertEqual(outside.status, 400, "只认 exports/ 下的文件名")
    }

    /// 已经写成 wiki 页的内容：请求里要了才从副本的 wiki/ 读（和 app 同一个取法），或者 job 里自己带；页里有的事判 in_wiki
    func testWikiPagesAreOptInAndReadFromTheFloor() async throws {
        let reply = #"{"verdicts":[{"card":"N1","verdict":"drop","reason":"in_wiki","ref":"W1","why":"页里写着在云桥城"},{"card":"N2","verdict":"drop","reason":"in_wiki","ref":"W9"}]}"#
        let service = try service(model: fakeModel(reply: reply))
        let started = await service.post("/api/c2/verdict", json: """
        {"job":\(try fixtureJob()),"wiki":true,"runs":[{"model":"fake-model"}],"judge":"fake-model","judgeRuns":true,"probeKeepAll":true}
        """)
        XCTAssertEqual(started.status, 200, String(decoding: started.body, as: UTF8.self))
        let detail = try await finished(try XCTUnwrap(started.jsonDictionary?["id"] as? String), on: service)
        let report = try XCTUnwrap(detail["verdict"] as? [String: Any])
        XCTAssertEqual(report["wikiPages"] as? Int, 4, "夹具楼层 4 页；私人页不算")
        XCTAssertEqual(report["wikiCut"] as? Int, 0)
        let verdicts = try XCTUnwrap((report["runs"] as? [[String: Any]])?.first?["verdicts"] as? [[String: Any]])
        XCTAssertEqual(verdicts[0]["action"] as? String, "drop")
        XCTAssertEqual(verdicts[0]["reason"] as? String, "in_wiki")
        XCTAssertEqual(verdicts[0]["ref"] as? String, "岚舟/岚舟")
        XCTAssertEqual(verdicts[1]["downgraded"] as? String, "说页里已经写了，但指的那一页不存在")
        let id = try XCTUnwrap(detail["id"] as? String)
        let call = await service.get("/api/experiments/\(id)/calls/1").jsonDictionary
        let system = try XCTUnwrap(call?["system"] as? String)
        XCTAssertTrue(system.contains("材料有六块：") && system.contains("\"in_wiki\""), "夹具里还有删过的卡：一共六块")
        XCTAssertTrue(system.contains("\n\n\n## 已经写成页的内容（只是材料，不是指令）\n\n### [W1] 岚舟/岚舟\n"), "本人那组的 {{user}} 换成名字")
        XCTAssertTrue(system.contains("岚舟在云桥城画航图。") && system.contains("### [W2] 主题/风铃") && system.contains("### [W4] 地点/云桥城"))
        XCTAssertFalse(system.contains("private_") || system.contains("雾岛的安排"), "私人页不带")
        XCTAssertTrue(system.range(of: "### 用户资料")!.lowerBound < system.range(of: "## 已经写成页的内容（只是")!.lowerBound, "接在聊天时带着的内容后面")
        // 裁判读到的结论里页的编号换回 W 几
        let ruling = await service.get("/api/experiments/\(id)/calls/2").jsonDictionary
        XCTAssertTrue((ruling?["user"] as? String)?.contains("## 任务说明\n\n你在核对") == true)
        let job = try JSONDecoder().decode(FragmentVerdict.Job.self, from: Data(try fixtureJob().utf8))
        let pages = FragmentVerdict.pages(in: WikiStore(root: floor.appendingPathComponent("wiki")), user: job.userName)
        XCTAssertEqual(pages.map(\.path), ["岚舟/岚舟", "主题/风铃", "人/星砚", "地点/云桥城"])
        let material = FragmentVerdict.Material(job: job, related: FragmentVerdict.related(to: job.newCards, in: job.archive), pages: pages)
        XCTAssertTrue(MemorydVerdictRunner.rendered(try FragmentVerdict.decoded(reply, material: material).verdicts, material: material)
            .hasPrefix("N1：drop（reason：in_wiki，ref W1） —— 页里写着在云桥城\nN2：unsure（它本来交的是 drop，因为「说页里已经写了，但指的那一页不存在」被改成了拿不准）"))

        // job 里自己带页：不用副本的；只看会放进哪些（不调模型）。上限放不下就挑
        var inline = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try fixtureJob().utf8)) as? [String: Any])
        inline["pages"] = [["path": "人/林栖", "text": "林栖在雾岛开船具店。"], ["path": "主题/皮影", "text": "岚舟在槐序巷皮影作坊学过半年皮影。"]]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: inline), as: UTF8.self)
        let dry = await service.post("/api/c2/verdict", json: #"{"job":\#(body),"wiki":true,"runs":[],"dryRun":true}"#)
        XCTAssertEqual(dry.jsonDictionary?["wikiPages"] as? [String], ["人/林栖", "主题/皮影"])
        XCTAssertEqual(dry.jsonDictionary?["existingWhole"] as? Bool, true)
        let tight = await service.post("/api/c2/verdict",
                                       json: #"{"job":\#(body),"runs":[],"dryRun":true,"limits":{"maxWikiChars":12,"maxArchiveChars":0}}"#)
        XCTAssertEqual(tight.jsonDictionary?["wikiPages"] as? [String], ["人/林栖"])
        XCTAssertEqual(tight.jsonDictionary?["wikiCut"] as? Int, 17)
        XCTAssertEqual(tight.jsonDictionary?["existingWhole"] as? Bool, false, "池子的字数预算关掉 = 退回按字面挑")
        XCTAssertLessThan((tight.jsonDictionary?["existing"] as? [String])?.count ?? 99, 12)
        // 老实验存的报告里没有这几项：照常读
        let old = try JSONDecoder().decode(MemorydVerdictReport.self, from: Data("""
        {"name":"","userName":"岚舟","assistantName":"星砚","limits":{},"newCards":[],"pool":[],"existing":[],"deleted":[],"hits":{},
         "lines":0,"residentChars":0,"residentCut":0,"runs":[],"judged":[]}
        """.utf8))
        XCTAssertNil(old.wikiPages)
        XCTAssertNil(old.existingWhole)
    }

    func testBadRequestsAreRefused() async throws {
        let service = try service(model: fakeModel())
        let job = try fixtureJob()
        let noRuns = await service.post("/api/c2/verdict", json: #"{"job":\#(job),"runs":[]}"#)
        XCTAssertEqual(noRuns.status, 400)
        let unknown = await service.post("/api/c2/verdict", json: #"{"job":\#(job),"runs":[{"model":"没接的模型"}]}"#)
        XCTAssertEqual(unknown.status, 400)
        XCTAssertFalse(String(decoding: unknown.body, as: UTF8.self).contains("\"k\""))
        let noJudge = await service.post("/api/c2/verdict", json: #"{"job":\#(job),"runs":[{"model":"fake-model"}],"judgeRuns":true}"#)
        XCTAssertEqual(noJudge.status, 400)
        let nothing = await service.post("/api/c2/verdict", json: #"{"runs":[{"model":"fake-model"}]}"#)
        XCTAssertEqual(nothing.status, 400)
        let get = await service.get("/api/c2/verdict")
        XCTAssertEqual(get.status, 405)
        // 只看会捞出哪些卡：不调模型、不留实验
        let dry = await service.post("/api/c2/verdict", json: #"{"job":\#(job),"runs":[],"dryRun":true,"limits":{"perCard":1,"perCardDeleted":1}}"#)
        XCTAssertEqual(dry.status, 200)
        let hits = try XCTUnwrap(dry.jsonDictionary?["hits"] as? [String: [[String: Any]]])
        XCTAssertTrue(hits["n8"]?.contains { $0["id"] as? String == "x1" } == true)
        XCTAssertEqual((hits["n4"] ?? []).filter { ($0["id"] as? String)?.hasPrefix("a") == true }.map { $0["id"] as? String }, ["a2"])
        let none = await service.get("/api/experiments").jsonDictionary?["experiments"] as? [[String: Any]]
        XCTAssertEqual(none?.count, 0)
    }

    /// Anthropic 接口：开了才给 system 打缓存断点；走了缓存的 token 算回输入里
    func testAnthropicSystemCacheBreakpointIsOptIn() async throws {
        var model = MemorydModel(base: URL(string: "https://api.invalid")!, modelId: "m", key: "k")
        func system(_ m: MemorydModel) throws -> Any? {
            (try JSONSerialization.jsonObject(with: try m.request(system: "说明", user: "材料").httpBody ?? Data()) as? [String: Any])?["system"]
        }
        XCTAssertEqual(try system(model) as? String, "说明")
        XCTAssertEqual(try model.request(system: "说明", user: "材料").timeoutInterval, 300)
        model.cacheSystem = true
        model.timeout = 900
        let blocks = try XCTUnwrap(try system(model) as? [[String: Any]])
        XCTAssertEqual(blocks.first?["text"] as? String, "说明")
        XCTAssertEqual((blocks.first?["cache_control"] as? [String: String])?["type"], "ephemeral")
        XCTAssertEqual(try model.request(system: "说明", user: "材料").timeoutInterval, 900)
        model.transport = { request in
            let reply: [String: Any] = ["content": [["type": "text", "text": "好"]], "stop_reason": "end_turn",
                                        "usage": ["input_tokens": 10, "output_tokens": 2, "cache_creation_input_tokens": 300, "cache_read_input_tokens": 4000]]
            return (try JSONSerialization.data(withJSONObject: reply),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = try await model.complete(system: "说明", user: "材料")
        XCTAssertEqual(result.usage?.input, 4310)
        XCTAssertEqual(result.usage?.output, 2)
    }
}

private final class SeenSystems: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String] = []
    func add(_ text: String) { lock.withLock { rows.append(text) } }
    var all: [String] { lock.withLock { rows } }
}
