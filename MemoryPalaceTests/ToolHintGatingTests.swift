import MemoryCore
import XCTest
@testable import 记忆花园

/// 工具关了不带它的说明（粟粟 10-15）：卡片说明点名的工具、设备段逐项
final class ToolHintGatingTests: XCTestCase {

    private let cardTools: Set<String> = [DiceTool.toolName, AskUserTool.toolName, RunCommandTool.toolName]

    func testCardGuideUnchangedWhenAllNamedToolsAvailable() {
        XCTAssertEqual(ChatCardPromptGuide.adjusted(ChatCardPromptGuide.text, available: cardTools), ChatCardPromptGuide.text)
        XCTAssertEqual(ChatCardPromptGuide.adjusted(ChatCardPromptGuide.index, available: cardTools), ChatCardPromptGuide.index)
    }

    func testCardGuideDropsOffToolSentences() {
        for base in [ChatCardPromptGuide.text, ChatCardPromptGuide.index] {
            let out = ChatCardPromptGuide.adjusted(base, available: [])
            for name in cardTools { XCTAssertFalse(out.contains(name), "还提到 \(name)") }
            XCTAssertTrue(out.contains("要掷骰子 / 抽签时，发不带 result 的卡让对方自己掷"), "没骰子工具时教对方自己掷")
            XCTAssertTrue(out.contains("写进 MCP 工具的参数"))
        }
    }

    func testFileLibrarySentenceFollowsAvailableTools() {
        let all = Set(FileLibraryTools.Name.allCases.map(\.rawValue))
        let tucked: Set<String> = [FileLibraryTools.Name.rename.rawValue, FileLibraryTools.Name.delete.rawValue]
        XCTAssertEqual(FileLibraryTools.toolSentence(available: all, tucked: tucked), FileLibraryTools.defaultToolSentence, "全开时一字不差")
        XCTAssertTrue(FileLibraryTools.defaultInjectionTemplate.contains(FileLibraryTools.defaultToolSentence))
        XCTAssertEqual(FileLibraryTools.toolSentence(available: [FileLibraryTools.Name.read.rawValue], tucked: []), "可用 fs_read 工具读写")
        XCTAssertEqual(FileLibraryTools.toolSentence(available: [FileLibraryTools.Name.read.rawValue, FileLibraryTools.Name.delete.rawValue], tucked: []),
                       "可用 fs_read 工具读写（删文件用 fs_delete）")
    }

    func testSelfMemoryHintsFollowAvailableTools() {
        let all: Set<String> = [SelfMemoryTool.rememberName, SelfMemoryTool.editName, SelfMemoryTool.forgetName,
                                RecallTool.toolName, FileLibraryTools.Name.read.rawValue]
        XCTAssertTrue(SelfMemoryTool.systemHint(available: all).contains("- 改或忘掉你记过的：edit_memory / forget_memory。"))
        let rememberOnly = SelfMemoryTool.systemHint(available: [SelfMemoryTool.rememberName])
        XCTAssertFalse(rememberOnly.contains("edit_memory") || rememberOnly.contains("forget_memory"))

        XCTAssertEqual(SelfMemoryInjection.footerText(available: all), SelfMemoryInjection.footer, "都有时原文不变")
        XCTAssertEqual(SelfMemoryInjection.footerText(available: []), "")
        XCTAssertEqual(PromptAssembler.droppingOffToolMentions("a" + MemoryInjector.recallCatalogHint + SelfMemoryInjection.footer, available: all),
                       "a" + MemoryInjector.recallCatalogHint + SelfMemoryInjection.footer)
        XCTAssertEqual(PromptAssembler.droppingOffToolMentions("a" + MemoryInjector.recallCatalogHint + SelfMemoryInjection.footer, available: []), "a")
    }

    func testSearchHintWithoutBrowse() {
        XCTAssertTrue(WebSearchToolService.systemPrompt(assistantName: "小雾").contains("browse_url"))
        let noBrowse = WebSearchToolService.systemPrompt(assistantName: "小雾", browse: false)
        XCTAssertFalse(noBrowse.contains("browse_url"))
        XCTAssertTrue(noBrowse.contains("[citation](index:id)"))
    }

    func testCardGuideToolOutputDropsOffTools() {
        let raw = CardGuideTool.execute(inputJSON: #"{"kinds":["dice","ask"]}"#).text
        XCTAssertTrue(raw.contains(DiceTool.toolName))
        let filtered = CardGuideTool.execute(inputJSON: #"{"kinds":["dice","ask"]}"#, available: []).text
        for name in cardTools { XCTAssertFalse(filtered.contains(name), "工具返回里还提到 \(name)") }
    }

    func testDeviceHintListsOnlyAvailable() {
        let all = DeviceToolDispatcher.systemHint(available: DeviceToolDispatcher.names)
        for piece in ["calendar_*", "reminders_*", "clipboard_read", "ocr_image", "notify_schedule", "open_url", "device_info", "<命令>"] {
            XCTAssertTrue(all.contains(piece), piece)
        }
        XCTAssertTrue(all.contains("</设备>\n<命令>"), "两段之间一个换行，和以前一样")

        let ocrOnly = DeviceToolDispatcher.systemHint(available: [OCRImageTool.toolName])
        XCTAssertTrue(ocrOnly.contains("你可以用设备工具识别图片文字（ocr_image）。"))
        for piece in ["calendar_*", "reminders_*", "clipboard_read", "notify_schedule", "open_url", "device_info", "<命令>"] {
            XCTAssertFalse(ocrOnly.contains(piece), piece)
        }

        let remindersAll = DeviceToolDispatcher.systemHint(available: Set(RemindersTools.definitions.map(\.name)))
        XCTAssertTrue(remindersAll.contains("你可以用设备工具读写用户的提醒事项（reminders_*）。"))
        let calendarQueryOnly = DeviceToolDispatcher.systemHint(available: [CalendarTools.queryName])
        XCTAssertTrue(calendarQueryOnly.contains("你可以用设备工具查用户的系统日历（calendar_query）。"), "只剩查的不能说读写")
        let remindersCreateOnly = DeviceToolDispatcher.systemHint(available: [RemindersTools.createName])
        XCTAssertTrue(remindersCreateOnly.contains("你可以用设备工具改用户的提醒事项（reminders_create）。"))

        let commandNoFS = DeviceToolDispatcher.systemHint(available: [RunCommandTool.toolName])
        XCTAssertFalse(commandNoFS.contains("fs_"), "文件工具都关了，<命令> 里不再推荐 fs_*")

        XCTAssertTrue(commandNoFS.hasPrefix("<命令>"))
        XCTAssertFalse(commandNoFS.contains("<设备>"))

        XCTAssertEqual(DeviceToolDispatcher.systemHint(available: []), "")
    }
}
