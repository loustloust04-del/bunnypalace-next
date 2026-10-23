#if os(macOS)
import XCTest
@testable import 记忆花园

/// 编程会话消息 → 聊天页渲染器的段序列（plan-coding-detail-as-chat §2.1）。
/// 这里锁的是**配对不变量**：每个工具调用「紧邻」吐出 use → result——合卡只看相邻同 id，
/// 而好几家 adapter 的 tool id 恒为空串（Cursor），靠 id 唯一是靠不住的（R-CD Q1）
final class CodingMessageSegmentsTests: XCTestCase {

    private func message(role: CodingRole = .assistant, text: String = "", thinking: String? = nil,
                         calls: [CodingToolCall] = [], images: [CodingImage] = []) -> CodingMessage {
        CodingMessage(seq: 1, role: role, kind: .text, text: text, truncated: false,
                      toolCalls: calls, thinking: thinking, timestamp: nil, model: nil,
                      imageCount: images.count, images: images)
    }

    private func call(id: String = "t1", name: String = "Bash", input: String? = "{\n  \"command\" : \"ls\"\n}",
                      output: String? = "a.txt", isError: Bool = false) -> CodingToolCall {
        CodingToolCall(id: id, name: name, inputPreview: "ls", input: input, output: output,
                       isError: isError, sidechainRef: nil)
    }

    /// 顺序：thinking → 正文 → 工具（跟换壳前的阅读顺序一致）
    func testOrderThinkingThenTextThenTools() {
        let segs = CodingMessageSegments.segments(for: message(text: "正文", thinking: "想了想", calls: [call()]))
        XCTAssertEqual(segs.count, 4)
        guard case .thinking(let t, let sig) = segs[0] else { return XCTFail("第一段应是 thinking") }
        XCTAssertEqual(t, "想了想")
        XCTAssertNil(sig)
        guard case .text(let body) = segs[1] else { return XCTFail("第二段应是正文") }
        XCTAssertEqual(body, "正文")
        guard case .toolUse = segs[2] else { return XCTFail("第三段应是 toolUse") }
        guard case .toolResult = segs[3] else { return XCTFail("第四段应是 toolResult") }
    }

    /// 空的不产段（别喂给渲染器一堆空块）
    func testEmptyPiecesProduceNoSegments() {
        XCTAssertTrue(CodingMessageSegments.segments(for: message()).isEmpty)
        XCTAssertTrue(CodingMessageSegments.segments(for: message(text: "", thinking: "")).isEmpty)
    }

    /// 图片不进段：`.image` 在 MessageSegmentsView 里是 EmptyView，图归 CodingImageStrip 画
    func testImagesStayOutOfSegments() {
        let image = CodingImage(mediaType: "image/png", data: Data([0x89, 0x50]))
        let segs = CodingMessageSegments.segments(for: message(text: "看图", images: [image]))
        XCTAssertEqual(segs.count, 1)
        guard case .text = segs[0] else { return XCTFail("只应剩正文那一段") }
    }

    /// 没有输出（或空输出）的工具只产 toolUse，不产一个空的 result
    func testToolWithoutOutputProducesOnlyUse() {
        let segs = CodingMessageSegments.segments(for: message(calls: [call(output: nil), call(id: "t2", output: "")]))
        XCTAssertEqual(segs.count, 2)
        for seg in segs {
            guard case .toolUse = seg else { return XCTFail("不该产出 toolResult") }
        }
    }

    /// **不变量 1**：同一条消息里两个工具**撞 id**，各自带 output → 仍然是 use/res/use/res 紧邻交替。
    /// 合卡只看「下一段是不是同 id 的 result」，紧邻就正确，不依赖 id 唯一
    func testDuplicateToolIdsStayAdjacentlyPaired() {
        let segs = CodingMessageSegments.segments(
            for: message(calls: [call(id: "same", output: "一"), call(id: "same", output: "二")]))
        XCTAssertEqual(segs.count, 4)
        guard case .toolUse(let id0, _, _, _, _) = segs[0],
              case .toolResult(let r0, let text0, _, _) = segs[1],
              case .toolUse(let id1, _, _, _, _) = segs[2],
              case .toolResult(let r1, let text1, _, _) = segs[3] else { return XCTFail("应是 use/res/use/res") }
        XCTAssertEqual(id0, r0)
        XCTAssertEqual(id1, r1)
        XCTAssertEqual(text0, "一")
        XCTAssertEqual(text1, "二")
    }

    /// **不变量 2**：id 为空串（Cursor 恒空）+ 前一个工具没有输出 → 第二个的 result 不会被误认成第一个的
    func testEmptyToolIdWithMissingOutputDoesNotMispair() {
        let segs = CodingMessageSegments.segments(
            for: message(calls: [call(id: "", name: "Read", output: nil), call(id: "", name: "Bash", output: "跑完了")]))
        XCTAssertEqual(segs.count, 3)
        guard case .toolUse(_, let first, _, _, _) = segs[0] else { return XCTFail("第一段应是 toolUse") }
        XCTAssertEqual(first, "Read", "没输出的那个后面不跟 result")
        guard case .toolUse(_, let second, _, _, _) = segs[1] else { return XCTFail("第二段应是 toolUse") }
        XCTAssertEqual(second, "Bash")
        guard case .toolResult(_, let text, _, _) = segs[2] else { return XCTFail("第三段应是 toolResult") }
        XCTAssertEqual(text, "跑完了")
    }

    /// 失败标记要带过去（工具卡靠它出「· 失败」）
    func testErrorFlagCarriesOver() {
        let segs = CodingMessageSegments.segments(for: message(calls: [call(output: "boom", isError: true)]))
        guard case .toolResult(_, _, let isError, _) = segs[1] else { return XCTFail("应有 toolResult") }
        XCTAssertTrue(isError)
    }

    /// 折叠行摘要：口径跟 CodingParse.makePreview 同一份（命令 / 路径优先），空输入不出摘要
    func testToolSummaryUsesParsePreview() {
        XCTAssertEqual(CodingMessageSegments.toolSummary(name: "Bash", inputJSON: "{\"command\": \"cd /tmp && ls\"}"),
                       "cd /tmp && ls")
        XCTAssertEqual(CodingMessageSegments.toolSummary(name: "Read", inputJSON: "{\"file_path\": \"/a/b.swift\"}"),
                       "/a/b.swift")
        XCTAssertNil(CodingMessageSegments.toolSummary(name: "Bash", inputJSON: ""))
        XCTAssertNil(CodingMessageSegments.toolSummary(name: "Bash", inputJSON: "{}"))
    }
}
#endif
