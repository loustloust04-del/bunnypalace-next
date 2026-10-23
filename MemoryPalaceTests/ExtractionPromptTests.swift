import XCTest
@testable import 记忆花园

/// 第二刀 A2：提取提示词改成人设本人视角、真名、原话为主；逐字出处校验仍在。
final class ExtractionPromptTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "customMemoryExtractionPrompt")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "customMemoryExtractionPrompt")
        super.tearDown()
    }

    private let names = MemoryExtractor.Names(userName: "猫", assistantName: "小克")

    func testPersonaIsWhoYouAreWithRealNames() {
        let p = MemoryExtractor.buildPrompt(existingMemories: [], profile: nil, systemPrompt: "你是{{char}}，{{user}}的伴侣。", names: names)
        XCTAssertTrue(p.hasPrefix("你是小克。下面是你的人设：\n你是小克，猫的伴侣。"), String(p.prefix(80)))
        XCTAssertFalse(p.contains("记忆管理助手"))
        XCTAssertFalse(p.contains("{{"), "占位符和宏都换掉了")
        XCTAssertTrue(p.contains("原话占 30–50%"))
        XCTAssertTrue(p.contains("出处要求"), "逐字出处附录照旧拼在末尾")
    }

    /// 返工（Air 验收：新档案写成「粟粟提到……」）：示例带「」原话；写清 quote 只是出处，不代替 content 里的原话
    func testContentMustCarryQuotesNotJustQuoteField() {
        let p = MemoryExtractor.buildPrompt(existingMemories: [], profile: nil, systemPrompt: "", names: names)
        XCTAssertTrue(p.contains("\"content\": \"猫说：「"), "输出示例的 content 就是带原话的样子")
        XCTAssertFalse(p.contains("\"content\": \"档案内容\""))
        XCTAssertTrue(p.contains("不能因为给了 quote 就把 content 写成转述"))
        XCTAssertTrue(p.contains("quote 只是出处，不代替 content 里的原话"), "出处附录也写一遍")
        XCTAssertTrue(p.contains("不要写成「猫提到……」的转述"))
    }

    func testTranscriptUsesRealNamesNotUserAI() {
        let req = MemoryExtractor.buildRequest(
            recentMessages: [(id: "1", role: "user", content: "我怕打雷"), (id: "2", role: "assistant", content: "我在呢")],
            existingMemories: [], profile: nil, systemPrompt: "", names: names)
        let transcript = req.messages[0].content
        XCTAssertTrue(transcript.contains("猫: 我怕打雷"))
        XCTAssertTrue(transcript.contains("小克: 我在呢"))
        XCTAssertFalse(transcript.contains("用户:") || transcript.contains("AI:"))
    }

    func testEmptyNamesFallBack() {
        let n = MemoryExtractor.Names(userName: "  ", assistantName: "")
        XCTAssertEqual(n.user, "用户")
        XCTAssertEqual(n.char, "我")
    }

    func testCustomPromptGetsNamePlaceholders() {
        UserDefaults.standard.set("我是{{CHAR_NAME}}，整理{{USER_NAME}}的档案。{{MEMORIES}}", forKey: "customMemoryExtractionPrompt")
        let p = MemoryExtractor.buildPrompt(existingMemories: [], profile: nil, systemPrompt: "", names: names)
        XCTAssertTrue(p.hasPrefix("我是小克，整理猫的档案。无"))
        XCTAssertTrue(p.contains("出处要求"))
    }
}
