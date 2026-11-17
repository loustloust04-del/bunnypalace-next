import XCTest
@testable import MemoryCore

/// 放到 CC 家的文件夹 / 文件名怎么洗。全虚构
final class GardenMemoryExportTests: XCTestCase {
    func testNamesCannotEscapeTheFolder() {
        XCTAssertEqual(GardenMemoryExport.fileStem("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(GardenMemoryExport.fileStem("a/b\\c:d\ne"), "a-b-c-d-e")
        XCTAssertEqual(GardenMemoryExport.fileStem("  ..  "), "其他")
        XCTAssertEqual(GardenMemoryExport.fileStem("README"), "其他")
        XCTAssertEqual(GardenMemoryExport.fileStem(String(repeating: "长", count: 200)).count, 80)
        XCTAssertEqual(GardenMemoryExport.fileStem("星砚楼"), "星砚楼")
    }
}
