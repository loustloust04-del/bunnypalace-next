import XCTest
@testable import 记忆花园

/// terminal_input 分片（#053 T26）：hub 单帧超 4096 字节整帧扔，客户端得自己切。
final class CCBridgeTerminalInputChunkTests: XCTestCase {

    private func chunks(_ s: String, limit: Int = 4096) -> [Data] {
        CCBridgeWebSocketClient.terminalInputChunks(Data(s.utf8), limit: limit)
    }

    func testShortInputIsOneChunk() {
        XCTAssertEqual(chunks("ls\r"), [Data("ls\r".utf8)])
        XCTAssertEqual(chunks(""), [])
    }

    func testLongChineseSplitsOnCharBoundaryAndReassembles() {
        let text = String(repeating: "长", count: 5000) + "END"   // 15003 字节
        let parts = chunks(text)
        XCTAssertGreaterThan(parts.count, 1)
        for p in parts {
            XCTAssertLessThanOrEqual(p.count, 4096)
            XCTAssertNotNil(String(data: p, encoding: .utf8), "每片都是完整 UTF-8")
        }
        XCTAssertEqual(parts.reduce(Data(), +), Data(text.utf8))
    }

    func testMixedWidthBoundary() {
        // 1 字节 + 3 字节 + 4 字节（emoji）交错，limit 取 5 逼着每次都要往回退
        let text = "a长😀b长😀"
        let parts = chunks(text, limit: 5)
        for p in parts {
            XCTAssertLessThanOrEqual(p.count, 5)
            XCTAssertNotNil(String(data: p, encoding: .utf8))
        }
        XCTAssertEqual(parts.reduce(Data(), +), Data(text.utf8))
    }

    func testExactLimitIsOneChunk() {
        XCTAssertEqual(chunks(String(repeating: "a", count: 4096)).count, 1)
        XCTAssertEqual(chunks(String(repeating: "a", count: 4097)).count, 2)
    }
}
