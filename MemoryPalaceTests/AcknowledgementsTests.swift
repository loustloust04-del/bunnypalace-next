import XCTest
@testable import 记忆花园

/// 开源致谢（#014）：两端共用一份数据，按平台过滤；测试宿主是 mac 包。
final class AcknowledgementsTests: XCTestCase {
    private var names: Set<String> {
        Set(Acknowledgements.current.flatMap(\.entries).map(\.name))
    }

    func testMacListsMacOnlyComponents() {
        for name in ["Wake", "Sparkle", "zstd", "cc-bridge"] {
            XCTAssertTrue(names.contains(name), "mac 致谢页缺 \(name)")
        }
    }

    func testMacOmitsIOSOnlyComponents() {
        for name in names {
            XCTAssertFalse(name.hasPrefix("iSH") || name.hasPrefix("OpenMinis") || name.hasPrefix("Alpine") || name == "VariableBlur",
                           "mac 致谢页不该有 iOS 独有的 \(name)")
        }
        XCTAssertFalse(Acknowledgements.current.contains { $0.title == "离线沙箱" })
    }

    func testAppItselfAndNoEmptySections() {
        XCTAssertEqual(Acknowledgements.current.first?.entries.first?.licenseType, "AGPL-3.0")
        XCTAssertFalse(Acknowledgements.current.contains { $0.entries.isEmpty })
    }

    /// 节身份稳定（重建会让页面重绘时丢展开状态）
    func testSectionIdentityIsStable() {
        XCTAssertEqual(Acknowledgements.current.map(\.id), Acknowledgements.current.map(\.id))
    }

    /// cc-bridge 展开显示包根的 ATTRIBUTION.md（不是只给一句路径）
    func testCCBridgeShowsBundledAttribution() throws {
        let entry = try XCTUnwrap(Acknowledgements.current.flatMap(\.entries).first { $0.name == "cc-bridge" })
        XCTAssertEqual(entry.textFileName, "ATTRIBUTION")
        XCTAssertEqual(entry.textFileExtension, "md")
        XCTAssertTrue(Acknowledgements.loadText("ATTRIBUTION", extension: "md")?.contains("Bun") ?? false)
    }

    /// 每条指向的全文都真在包里（防拼错文件名；cc-bridge 读包根的 ATTRIBUTION.md）
    func testEveryLicenseTextResolvesInBundle() {
        for entry in Acknowledgements.current.flatMap(\.entries) {
            guard let file = entry.textFileName else { continue }
            let text = Acknowledgements.loadText(file, extension: entry.textFileExtension)
            XCTAssertFalse(text?.isEmpty ?? true, "\(entry.name)：包里找不到 \(file).\(entry.textFileExtension)")
        }
    }
}
