import XCTest
@testable import 记忆花园
final class NativeVoiceCallTests: XCTestCase {
    func testPayloadValidityAndExpiration() throws {
        let call = NativeVoiceCall(call_id: UUID().uuidString, chat_id: UUID().uuidString, caller: "AI", created_at: 1000, expires_at: 61_000, status: "ringing")
        XCTAssertTrue(call.valid); XCTAssertFalse(call.terminal)
        XCTAssertTrue(call.expired(at: Date(timeIntervalSince1970: 62)))
        var ended = call; ended.status = "ended"; XCTAssertTrue(ended.terminal)
        XCTAssertEqual(try JSONDecoder().decode(NativeVoiceCall.self, from: JSONEncoder().encode(call)), call)
        XCTAssertFalse(NativeVoiceCall(call_id: "bad", chat_id: call.chat_id, caller: "AI", created_at: 0, expires_at: 60_000).valid)
        XCTAssertFalse(NativeVoiceCall(call_id: call.call_id, chat_id: call.chat_id, caller: "AI", created_at: 0, expires_at: 120_000).valid)
    }
}
