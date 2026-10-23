import Foundation
import XCTest
@testable import 记忆花园

final class APNsEnvironmentTests: XCTestCase {
    /// 模拟 CMS 包：明文 plist 前后夹着二进制垃圾。
    private func profile(aps: String?) -> Data {
        let ents = aps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Entitlements</key><dict>\(ents)</dict></dict></plist>
        """
        return Data([0x30, 0x82, 0x00, 0xFF]) + Data(plist.utf8) + Data([0xA0, 0x00, 0x31])
    }

    func testDevelopmentProfileIsSandbox() {
        XCTAssertEqual(APNsEnvironment.environment(fromProvisioningProfile: profile(aps: "development")), "sandbox")
    }

    func testAdHocProfileIsProduction() {
        XCTAssertEqual(APNsEnvironment.environment(fromProvisioningProfile: profile(aps: "production")), "production")
    }

    /// App Store / TestFlight 包里没有 embedded.mobileprovision。
    func testNoProfileIsProduction() {
        XCTAssertEqual(APNsEnvironment.environment(fromProvisioningProfile: nil), "production")
        XCTAssertEqual(APNsEnvironment.environment(fromProvisioningProfile: Data("garbage".utf8)), "production")
    }
}
