import XCTest
@testable import 记忆花园

/// 记忆写手 / 重新生成走的非流式整包解析（10-14「按新规则重写」报「无法解析响应」）
final class NonStreamParseTests: XCTestCase {

    func testLoneSurrogateEscapeIsReplacedNotRejected() throws {
        // node 的 JSON.stringify 会把落单的代理项原样吐成 \ud83d，Foundation 整包拒收
        let anthropic = Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"写完了\ud83d 好"}]}"#.utf8)
        XCTAssertNil(try? JSONSerialization.jsonObject(with: anthropic), "前提：Foundation 确实拒收")
        XCTAssertEqual(try AnthropicProvider().parseNonStreamBody(anthropic).text, "写完了\u{FFFD} 好")

        let openAI = Data(#"{"choices":[{"message":{"content":"尾巴\udc00"}}]}"#.utf8)
        XCTAssertEqual(try OpenAICompatibleProvider().parseNonStreamBody(openAI).text, "尾巴\u{FFFD}")
    }

    func testSurrogatePairsAndEscapedBackslashesUntouched() {
        let raw = #"{"a":"😀 😀 \\ud83d 中"}"#
        let fixed = BaseChatProvider.replacingLoneSurrogateEscapes(Data(raw.utf8))
        XCTAssertEqual(String(decoding: fixed, as: UTF8.self), raw, "成对的、被转义的反斜杠、普通 \\u 都不动")
    }

    func testOpenAIContentArrayAndNull() throws {
        let parts = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"甲"},{"type":"text","text":"乙"}]}}]}"#.utf8)
        XCTAssertEqual(try OpenAICompatibleProvider().parseNonStreamBody(parts).text, "甲乙")
        let null = Data(#"{"choices":[{"message":{"content":null}}]}"#.utf8)
        XCTAssertEqual(try OpenAICompatibleProvider().parseNonStreamBody(null).text, "")
    }

    func testAnthropicThinkingFirstBlock() throws {
        let body = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"想","signature":"s"},{"type":"text","text":"正文"}]}"#.utf8)
        XCTAssertEqual(try AnthropicProvider().parseNonStreamBody(body).text, "正文")
    }

    func testUnparsableErrorCarriesBodyHead() {
        let html = Data(("<html>" + String(repeating: "很", count: 300) + "</html>").utf8)
        XCTAssertThrowsError(try AnthropicProvider().parseNonStreamBody(html)) { error in
            let msg = error.localizedDescription
            XCTAssertTrue(msg.hasPrefix("无法解析响应（回包开头：<html>很"), msg)
            XCTAssertEqual(msg.count, "无法解析响应（回包开头：）".count + 200)
        }
        XCTAssertThrowsError(try OpenAICompatibleProvider().parseNonStreamBody(Data(#"{"id":"x"}"#.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, #"无法解析响应（回包开头：{"id":"x"}）"#)
        }
        XCTAssertThrowsError(try OpenAICompatibleProvider().parseNonStreamBody(Data())) { error in
            XCTAssertEqual(error.localizedDescription, "无法解析响应（回包是空的）")
        }
    }
}
