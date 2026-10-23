import XCTest
@testable import 记忆花园

/// #064 终端首页 3D：外机信息值类型（hello 帧由 #046 解析，这里只测映射）。
final class TerminalHostInfoTests: XCTestCase {

    func testInitDefaultsAreAllUnknown() {
        let info = TerminalHostInfo()
        XCTAssertNil(info.hostName)
        XCTAssertNil(info.modelId)
        XCTAssertNil(info.modelName)
        XCTAssertNil(info.claudeInstalled)
        XCTAssertNil(info.codexInstalled)
        XCTAssertEqual(info.deviceClass, .allInOne)
    }

    func testFieldwiseInit() {
        let info = TerminalHostInfo(
            hostName: "susu 的 MacBook",
            modelId: "Mac17,4",
            modelName: "MacBook Air (15-inch, M5)",
            claudeInstalled: true,
            codexInstalled: false
        )
        XCTAssertEqual(info.hostName, "susu 的 MacBook")
        XCTAssertEqual(info.claudeInstalled, true)
        XCTAssertEqual(info.codexInstalled, false)
        XCTAssertEqual(info.deviceClass, .laptop)
    }

    func testDeviceClassFollowsModel() {
        XCTAssertEqual(TerminalHostInfo(modelId: "Macmini9,1").deviceClass, .desktop)
        XCTAssertEqual(TerminalHostInfo(modelName: "iMac (24-inch, 2024)").deviceClass, .allInOne)
        XCTAssertEqual(TerminalHostInfo(modelId: "Mac16,10", modelName: "Mac mini (2024)").deviceClass, .desktop)
        XCTAssertEqual(TerminalHostInfo(hostName: "只有主机名").deviceClass, .allInOne)
    }

    func testFromHello() {
        let hello = HubHello(frame: [
            "type": "hello", "host_name": "粟粟的 MacBook", "host_model_id": "Mac17,4",
            "host_model_name": "MacBook Air (15-inch, M5)", "tools": ["claude": true, "codex": false],
        ])
        let info = TerminalHostInfo(hello: try! XCTUnwrap(hello))
        XCTAssertEqual(info.hostName, "粟粟的 MacBook")
        XCTAssertEqual(info.deviceClass, .laptop)
        XCTAssertEqual(info.claudeInstalled, true)
        XCTAssertEqual(info.codexInstalled, false)
    }

    func testFromOldHubHelloWithoutModel() {
        let info = TerminalHostInfo(hello: HubHello())
        XCTAssertEqual(info.deviceClass, .allInOne)
        XCTAssertNil(info.claudeInstalled)
    }
}
