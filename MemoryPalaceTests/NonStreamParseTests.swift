import XCTest
@testable import 记忆花园

/// 记忆写手 / 重新生成走的非流式整包解析（10-14「按新规则重写」报「无法解析响应」）
final class NonStreamParseTests: XCTestCase {

    func testWhitespaceNonStreamBodyDoesNotBecomeEffectiveResponse() {
        let examples: [(BaseChatProvider, String, String)] = [
            (OpenAICompatibleProvider(),
             #"{"choices":[{"message":{"content":" \t\r\n　"}}]}"#,
             #"{"choices":[{"message":{"content":" 星砚的正文\n"}}]}"#),
            (AnthropicProvider(),
             #"{"stop_reason":"end_turn","content":[{"type":"text","text":" \t\r\n　"}]}"#,
             #"{"stop_reason":"end_turn","content":[{"type":"text","text":" 星砚的正文\n"}]}"#)
        ]
        for (provider, whitespace, visible) in examples {
            var effective = 0
            provider.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { XCTFail($0) })
            provider.onEffectiveEvent = { effective += 1 }
            provider.rawBody = Data(whitespace.utf8)
            provider.handleNonStreamBody()
            XCTAssertEqual(effective, 0, "空白整包在取消前不能提交回忆轮")
            provider.cancel()
            provider.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { XCTFail($0) })
            provider.rawBody = Data(visible.utf8)
            provider.handleNonStreamBody()
            XCTAssertEqual(effective, 1, "有可见正文的整包不等节拍器就生效")
            provider.cancel()
        }
    }

    func testEffectiveResponseIsReportedBeforeNonStreamToolPacing() {
        let examples: [(BaseChatProvider, String, String)] = [
            (OpenAICompatibleProvider(),
             #"{"choices":[{"message":{"content":null,"reasoning_content":"岚舟思考"}}],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#,
             #"{"choices":[{"finish_reason":"tool_calls","message":{"content":null,"tool_calls":[{"id":"call-recall","function":{"name":"recall","arguments":"{\"query\":\"林栖\"}"}}]}}]}"#),
            (AnthropicProvider(),
             #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"岚舟思考","signature":"s"}],"usage":{"input_tokens":3,"output_tokens":1}}"#,
             #"{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"call-recall","name":"recall","input":{"query":"林栖"}}]}"#)
        ]
        for (provider, thinkingOnly, tool) in examples {
            var effective = 0
            var tools = 0
            provider.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { XCTFail($0) })
            provider.onEffectiveEvent = { effective += 1 }
            provider.onToolCalls = { _ in tools += 1 }
            provider.rawBody = Data(thinkingOnly.utf8)
            provider.handleNonStreamBody()
            XCTAssertEqual(effective, 0, "整包思考 / 用量不推进真实轮")
            provider.cancel()
            provider.resetState(onToken: { _ in }, onComplete: { _, _ in }, onError: { XCTFail($0) })
            provider.rawBody = Data(tool.utf8)
            provider.handleNonStreamBody()
            XCTAssertEqual(effective, 1, "整包有效工具解析后立即生效，不等假流式节拍器")
            XCTAssertEqual(tools, 0)
            provider.cancel()
            XCTAssertEqual(effective, 1, "节拍器前取消不能抹掉已收到的有效响应")
        }
    }

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
