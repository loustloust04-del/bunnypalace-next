import XCTest
@testable import 记忆花园

/// #064 终端首页 3D：型号 → 外形类别（plan-terminal-3d §四）。
final class TerminalDeviceClassTests: XCTestCase {

    // MARK: 本机

    func testLocalPhoneAndTablet() {
        XCTAssertEqual(TerminalDeviceClass.local(machineIdentifier: "iPhone18,4"), .phone)
        XCTAssertEqual(TerminalDeviceClass.local(machineIdentifier: "iPad16,3"), .tablet)
    }

    func testLocalUnknownFallsBackToPhone() {
        XCTAssertEqual(TerminalDeviceClass.local(machineIdentifier: "iPod9,1"), .phone)
        XCTAssertEqual(TerminalDeviceClass.local(machineIdentifier: ""), .phone)
    }

    // MARK: 外机 · Apple Silicon 按名字

    func testAppleSiliconByModelName() {
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "Mac17,4", modelName: "MacBook Air (15-inch, M5)"), .laptop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "Mac15,8", modelName: "MacBook Pro (16-inch, Nov 2023)"), .laptop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "Mac16,10", modelName: "Mac mini (2024)"), .desktop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "Mac16,9", modelName: "Mac Studio (2025)"), .desktop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "Mac14,8", modelName: "Mac Pro (2023)"), .desktop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "Mac16,2", modelName: "iMac (24-inch, 2024)"), .allInOne)
    }

    /// 「iMac Pro」里含「Mac Pro」，必须先判 iMac
    func testIMacProIsAllInOne() {
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "iMacPro1,1", modelName: "iMac Pro"), .allInOne)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: nil, modelName: "iMac Pro (2017)"), .allInOne)
    }

    func testAppleSiliconIdWithoutNameIsAllInOne() {
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "Mac17,4", modelName: nil), .allInOne)
    }

    // MARK: 外机 · Intel 按前缀

    func testIntelByModelIdPrefix() {
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "MacBookPro18,3", modelName: nil), .laptop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "MacBookAir10,1", modelName: nil), .laptop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "MacBook10,1", modelName: nil), .laptop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "Macmini9,1", modelName: nil), .desktop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "MacPro7,1", modelName: nil), .desktop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "MacStudio1,1", modelName: nil), .desktop)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "iMac21,1", modelName: nil), .allInOne)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "iMacPro1,1", modelName: nil), .allInOne)
    }

    // MARK: 判不出

    func testUnknownFallsBackToAllInOne() {
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: nil, modelName: nil), .allInOne)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "", modelName: ""), .allInOne)
        XCTAssertEqual(TerminalDeviceClass.remote(modelId: "VMware20,1", modelName: "Linux Box"), .allInOne)
    }

    func testIsLocal() {
        XCTAssertTrue(TerminalDeviceClass.phone.isLocal)
        XCTAssertTrue(TerminalDeviceClass.tablet.isLocal)
        XCTAssertFalse(TerminalDeviceClass.desktop.isLocal)
        XCTAssertFalse(TerminalDeviceClass.laptop.isLocal)
        XCTAssertFalse(TerminalDeviceClass.allInOne.isLocal)
    }
}
