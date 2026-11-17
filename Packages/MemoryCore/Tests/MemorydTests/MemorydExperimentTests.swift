import XCTest
import MemoryCore
@testable import memoryd

/// 实验台：能选的 C2 提示词、占位怎么换、选项怎么收口、对话列表的条数。夹具全虚构
final class MemorydExperimentTests: XCTestCase {
    private var floor: URL!
    private var service: MemorydService!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
        service = try MemorydFixture.service(floor)
    }

    override func tearDownWithError() throws {
        if let floor { MemorydFixture.remove(floor) }
    }

    func testAppPromptTemplateFillsBackToTheAppPrompt() {
        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let filled = MemorydExperimentRunner.filled(MemorydExperimentRunner.appPromptTemplate(), names: names, window: "模型船",
                                                    from: "2026-10-12", to: "2026-10-13")
        XCTAssertEqual(filled, FragmentPool.wholeSystem(names: names, windowTitle: "模型船", from: "2026-10-12", to: "2026-10-13"),
                       "页面上那份「手机上现在跑的」换回名字和日期 = app 真在用的那份")
    }

    func testPromptListHasAppAndBundledDraftWithNoPlaceholderLeftAfterFilling() async throws {
        let response = await service.get("/api/c2/prompts")
        XCTAssertEqual(response.status, 200)
        let prompts = try XCTUnwrap(response.jsonDictionary?["prompts"] as? [[String: Any]])
        XCTAssertEqual(prompts.compactMap { $0["id"] as? String }, ["app", "old"])
        XCTAssertEqual(prompts.first?["text"] as? String, MemorydExperimentRunner.appPromptTemplate())
        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        for prompt in prompts {
            let text = try XCTUnwrap(prompt["text"] as? String)
            XCTAssertTrue(text.contains("{u}") && text.contains("{c}") && text.contains("{窗口名}") && text.contains("{起}") && text.contains("{止}"))
            let filled = MemorydExperimentRunner.filled(text, names: names, window: "模型船", from: "2026-10-12", to: "2026-10-13")
            for placeholder in ["{u}", "{c}", "{窗口名}", "{起}", "{止}"] {
                XCTAssertFalse(filled.contains(placeholder), "\(prompt["id"] ?? "") 里 \(placeholder) 没换掉")
            }
            XCTAssertTrue(filled.contains("「模型船」") && filled.contains("2026-10-12 到 2026-10-13"))
        }
        let wrong = await service.post("/api/c2/prompts", json: "{}")
        XCTAssertEqual(wrong.status, 405)
    }

    func testConversationListCountsAreTheWriterMainlineCounts() async throws {
        let maybeSource = await service.conversations
        let source = try XCTUnwrap(maybeSource)
        let windows = try source.windows(profileId: "memoryd-test", updatedSince: nil, includeTrashed: false)
        XCTAssertEqual(windows.map(\.id), ["xingyan-window-0001"], "回收站里的不列")
        let serial = try Dictionary(uniqueKeysWithValues: windows.map {
            ($0.id, try MemorydExperimentRunner.messages(window: $0, source: source).count)
        })
        XCTAssertEqual(serial, ["xingyan-window-0001": 4], "主线上有正文的：分支上没选的那条、隐藏的、删掉的都不算")
        XCTAssertEqual(try MemorydExperimentRunner.messageCounts(source: source, profileId: "memoryd-test"), serial,
                       "一起数出来的和一个一个数的一样")
        for _ in 0..<2 {
            let response = await service.get("/api/conversations")
            XCTAssertEqual(response.status, 200)
            let rows = try XCTUnwrap(response.jsonDictionary?["conversations"] as? [[String: Any]])
            XCTAssertEqual(rows.map { $0["id"] as? String }, ["xingyan-window-0001"])
            XCTAssertEqual(rows.first?["messages"] as? Int, 4)
            XCTAssertEqual(rows.first?["title"] as? String, "潮汐与航图")
        }
    }

    func testConversationListWithoutSnapshotIs404() async throws {
        try FileManager.default.removeItem(at: floor.appendingPathComponent("exports", isDirectory: true))
        let bare = try MemorydFixture.service(floor)
        let response = await bare.get("/api/conversations")
        XCTAssertEqual(response.status, 404)
    }

    func testOptionsDefaultToTheAppWriterAndAreClamped() throws {
        let bare = try JSONDecoder().decode(MemorydExperiment.Options.self, from: Data(#"{"conversationId":"w"}"#.utf8))
        XCTAssertEqual([bare.c2Prompt, bare.c2PromptName, bare.writer], ["", "", "whole"])
        XCTAssertEqual(bare.c2Rounds, 1, "老请求不带这几项 = app 现在那份、只写一次")
        var raw = MemorydExperiment.Options(conversationId: "w")
        raw.c2Rounds = 7
        raw.c2Prompt = " \n"
        raw.c2PromptName = "自己写的"
        let normal = MemorydExperimentRunner.normalized(raw)
        XCTAssertEqual(normal.c2Rounds, 1, "只认 1 / 2")
        XCTAssertEqual(normal.c2PromptName, "", "提示词是空的 = 跑 app 那份，不挂别的名字")
        raw.c2Rounds = 2
        raw.c2Prompt = "读 {u} 和 {c} 的对话"
        let custom = MemorydExperimentRunner.normalized(raw)
        XCTAssertEqual(custom.c2Rounds, 2)
        XCTAssertEqual(custom.c2PromptName, "自己写的")
    }

    /// 实验结果里的卡带着写手给的置信度（和 app 落库用的是同一个解析、同一个数）；存盘再读回不丢；老结果文件没这个键 = 空
    func testResultCardKeepsWriterConfidence() throws {
        let batch = try FragmentPool.decodedWhole(
            #"[{"subject":"岚舟","type":"fact","origin":"said","confidence":150,"content":"只用水性颜料。","msgs":[1]}]"#, messageCount: 1)
        let f = try XCTUnwrap(batch.fragments.first)
        let card = MemorydExperiment.Card(message: f.msg, content: f.content, subject: f.subject, speaker: f.speaker, category: f.category,
                                          importance: f.importance, tags: f.tags, confidence: f.confidence, day: f.occurredDay)
        XCTAssertEqual(card.confidence, 100, "越界的已经夹到 0–100")
        let data = try JSONEncoder().encode(card)
        XCTAssertEqual(try JSONDecoder().decode(MemorydExperiment.Card.self, from: data), card)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json.removeValue(forKey: "confidence") as? Int, 100)
        XCTAssertNil(try JSONDecoder().decode(MemorydExperiment.Card.self, from: JSONSerialization.data(withJSONObject: json)).confidence)
    }

    /// 实验结果里的卡带着写手标的全部出处（主线第几条），和 app 落库进 `Memory.sourceNodeIds` 的是同一串；老结果文件没这个键 = 空
    func testResultCardKeepsEveryMessageTheWriterNamed() throws {
        let batch = try FragmentPool.decodedWhole(
            #"[{"subject":"岚舟","type":"fact","origin":"said","content":"在槐序巷皮影作坊学刻皮。","msgs":[3,1,3]}]"#, messageCount: 3)
        let f = try XCTUnwrap(batch.fragments.first)
        let base = 20
        let card = MemorydExperiment.Card(message: base + f.msg, content: f.content, subject: f.subject, speaker: f.speaker, category: f.category,
                                          importance: f.importance, tags: f.tags, confidence: f.confidence, day: f.occurredDay,
                                          messages: f.msgs.map { $0.map { base + $0 } })
        XCTAssertEqual(card.message, 23, "跳转锚仍是写手交的第一个")
        XCTAssertEqual(card.messages, [21, 23])
        let data = try JSONEncoder().encode(card)
        XCTAssertEqual(try JSONDecoder().decode(MemorydExperiment.Card.self, from: data), card)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "messages")
        XCTAssertNil(try JSONDecoder().decode(MemorydExperiment.Card.self, from: JSONSerialization.data(withJSONObject: json)).messages)
    }
}
