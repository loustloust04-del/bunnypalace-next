import XCTest
@testable import 记忆花园

/// #089 P1 / P2〔状态〕：每轮会变的东西挂在最新一条用户消息前，不进 system
final class TurnStatusNoteTests: XCTestCase {

    func testStatusTimeLine() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 21, minute: 40, second: 37))!
        XCTAssertEqual(ConversationViewModel.statusTimeLine(now: date, timeZone: shanghai), "现在：2026-10-11 周日 21:40（UTC+8 Asia/Shanghai）")
        let india = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertTrue(ConversationViewModel.statusTimeLine(now: date, timeZone: india).contains("UTC+5:30 Asia/Kolkata"))
        let la = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertTrue(ConversationViewModel.statusTimeLine(now: date, timeZone: la).contains("UTC-7 America/Los_Angeles"))
    }

    /// P1-c：能力说明按真实工具生成
    func testCapabilitySection() {
        let tools: [[String: Any]] = [
            ["name": "fs_read", "description": "读文件库里的一个文件。可分段读。"],
            ["type": "function", "function": ["name": "recall", "description": "搜我们的对话历史\n第二行"]],
            ["type": "web_search_20250305", "name": "web_search", "max_uses": 5],
        ]
        let text = ConversationViewModel.capabilitySection(tools)
        XCTAssertTrue(text.hasPrefix("〔当前能用的工具〕"))
        XCTAssertTrue(text.contains("\n- fs_read — 读文件库里的一个文件\n"), text)
        XCTAssertTrue(text.contains("\n- recall — 搜我们的对话历史\n"), text)
        XCTAssertTrue(text.hasSuffix("\n- web_search（服务端执行）"), text)
    }

    /// P3-a：同名药合成一条、时间并集（审查里「联苯双酯（8:00/21:00）、联苯双酯（8:00/21:00/21:02）」）
    func testMergedMeds() {
        let text = ConversationViewModel.mergedMedsText([
            ("联苯双酯", [480, 1260]), ("维生素D", [540]), ("联苯双酯", [480, 1260, 1262]),
        ])
        XCTAssertEqual(text, "联苯双酯（8:00/21:00/21:02）、维生素D（9:00）")
    }

    /// P3-b：tool_search 对收起的内建工具返回和〔更多工具〕同一句
    func testToolSearchUsesTuckedBlurb() {
        let def = ToolDefinition(name: FileLibraryTools.Name.rename.rawValue, description: "长描述……", properties: [:], required: [])
        let out = MetaTools.search(query: "", catalog: [], builtins: [def])
        XCTAssertTrue(out.contains(ToolRegistry.tuckedBlurbs[FileLibraryTools.Name.rename.rawValue]!), out)
        XCTAssertFalse(out.contains("长描述"))
    }

    func testFileLibrarySummaryLine() {
        XCTAssertEqual(ConversationViewModel.fileLibrarySummaryLine(paths: []), "文件库：空")
        let line = ConversationViewModel.fileLibrarySummaryLine(paths: [
            "topics/a.md", "attachments/c1/照片-1.jpg", "attachments/c2/语音.m4a", "readme.md", "topics/b.md",
        ])
        XCTAssertEqual(line, "文件库：attachments 2 / topics 2 / 根目录 1（共 5 个，具体文件用 fs_list 查看）")
    }
}
