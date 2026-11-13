import Foundation

enum TurnStatusStreamFixture {
    static func reply(_ text: String) throws -> Data {
        let args = String(decoding: try JSONEncoder().encode(["status": text]), as: UTF8.self)
        let status = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        let question = #"{"questions":[{"question":"选哪种口味？","options":["巧克力","香草"]}]}"#
        let ask = String(decoding: try JSONEncoder().encode(question), as: UTF8.self)
        let event = #"data: {"choices":[{"delta":{"reasoning_content":"先确认口味，再给出建议。","tool_calls":[{"index":0,"id":"status-call","type":"function","function":{"name":"set_turn_status","arguments":\#(status)}},{"index":1,"id":"ask-call","type":"function","function":{"name":"ask_user","arguments":\#(ask)}}]},"finish_reason":"tool_calls"}]}"#
        return Data((event + "\n\ndata: [DONE]\n\n").utf8)
    }

    static let finalReply = Data("data: {\"choices\":[{\"delta\":{\"content\":\"选好了。\"}}]}\n\ndata: [DONE]\n\n".utf8)
}
