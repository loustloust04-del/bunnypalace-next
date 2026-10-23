import XCTest
#if PAGE2_CORE_FIXTURE
@testable import Page2Core
#else
@testable import 记忆花园
#endif

final class Page2LibraryNameKeyTests: XCTestCase {
    func testChineseToolsSortByPinyin() {
        let names = ["有声书", "文件库", "日历", "卡库", "记忆", "健康", "话题盒", "读书", "单词", "终端"]
        XCTAssertEqual(names.sorted { Page2LibraryNameKey($0) < Page2LibraryNameKey($1) },
                       ["单词", "读书", "话题盒", "健康", "记忆", "卡库", "日历", "文件库", "有声书", "终端"])
    }
    func testToneCaseSpacesAndWidthShareTheSameKey() {
        XCTAssertEqual(Page2LibraryNameKey("ＣＣ　终端"), Page2LibraryNameKey("cc zhong duan"))
        XCTAssertEqual(Page2LibraryNameKey("日历"), Page2LibraryNameKey("Rì lì"))
        XCTAssertEqual(Page2LibraryNameKey("  Éclair\n"), Page2LibraryNameKey("eclair"))
        XCTAssertEqual(Page2LibraryNameKey("绿色"), Page2LibraryNameKey("lǜ sè"))
    }
    func testIndexAndSortUseTheSameSections() {
        let names = ["😀工具", "有声书", "123工具", "日历", "Alpha", "单词", "", "éclair"]
        let keys = names.map(Page2LibraryNameKey.init).sorted()
        XCTAssertEqual(keys.map(\.section), Array("ADERY###"))
        XCTAssertEqual(Page2LibraryNameKey("重庆").section, "C")
    }
    func testNumbersUseNaturalOrderInsideAlphabeticNames() {
        XCTAssertLessThan(Page2LibraryNameKey("App 2"), Page2LibraryNameKey("App 10"))
        XCTAssertFalse(Page2LibraryNameKey("日历") < Page2LibraryNameKey("日历"))
    }
}
