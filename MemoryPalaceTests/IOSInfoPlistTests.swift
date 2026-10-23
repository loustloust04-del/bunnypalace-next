import XCTest

/// #041：iOS 包的 Info.plist 是根目录 `MemoryPalaceIOS-Info.plist`（INFOPLIST_FILE），
/// 不是 project.yml info.properties 生成的 `MemoryPalace/Info-iOS.plist`。voip 曾只写进后者 →
/// PushKit 不发 VoIP token → CC 来电报 "device has not enabled native calls"。
final class IOSInfoPlistTests: XCTestCase {

    private func iosInfoPlist(file: StaticString = #filePath) throws -> [String: Any] {
        let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("MemoryPalaceIOS-Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testBackgroundModesIncludeVoipAndAudio() throws {
        let modes = try XCTUnwrap(iosInfoPlist()["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("voip"), "缺 voip：PushKit 不发 VoIP token，CC 原生来电失效")
        XCTAssertTrue(modes.contains("audio"), "缺 audio：有声书/通话后台播放失效")
    }

    func testDeclaresNoNonExemptEncryption() throws {
        XCTAssertEqual(try iosInfoPlist()["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    }

    func testExportsToolTabType() throws {
        let decls = try XCTUnwrap(iosInfoPlist()["UTExportedTypeDeclarations"] as? [[String: Any]])
        let toolTab = try XCTUnwrap(decls.first { $0["UTTypeIdentifier"] as? String == "com.susu.MemoryPalace.tool-tab" },
                                    "缺 tool-tab 声明：iPad 拖放工具 tab 时 SwiftUI 丢类型")
        XCTAssertEqual(toolTab["UTTypeConformsTo"] as? [String], ["public.data"])
    }
}
