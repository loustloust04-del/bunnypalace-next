import XCTest
@testable import 记忆花园

/// #033：断言本身会红、该放的放（已知债 / 本测试豁免 / 后台线程），计数开关按 site 记
final class MainThreadIOGuardTests: XCTestCase {

    let pid = "xctest-mainthread-io-guard"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.libraryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    func testMainThreadFileLibraryCallFailsTest() {
        XCTExpectFailure("文件库入口在主线程被调要记成失败") {
            _ = FileLibraryStore.exists("a.md", profileId: pid)
        }
    }

    func testToleratedDebtDoesNotFail() {
        MainThreadIO.tolerated("xctest 已知债") {
            _ = FileLibraryStore.exists("a.md", profileId: pid)
        }
    }

    func testPerTestExemptionDoesNotFail() {
        MainThreadIO.allowMainThreadInThisTest()
        _ = FileLibraryStore.exists("a.md", profileId: pid)
    }

    func testExemptionResetsBetweenTests() {
        // 上一个用例的豁免不会带过来：observer 在 testCaseWillStart 复位
        XCTExpectFailure("豁免只管一个测试") {
            _ = FileLibraryStore.exists("a.md", profileId: pid)
        }
    }

    func testBackgroundCallDoesNotFail() async {
        let pid = pid
        await Task.detached { _ = FileLibraryStore.exists("a.md", profileId: pid) }.value
    }

    /// 只计主线程：后台那次不进表
    @MainActor
    func testCountingBySiteMainThreadOnly() async {
        MainThreadIO.allowMainThreadInThisTest()
        let pid = pid
        MainThreadIO.beginCounting()
        _ = FileLibraryStore.exists("a.md", profileId: pid)
        _ = FileLibraryStore.exists("b.md", profileId: pid)
        await Task.detached { _ = FileLibraryStore.exists("c.md", profileId: pid) }.value
        let counts = MainThreadIO.endCounting()
        XCTAssertEqual(counts["stat FileLibraryStore.exists"], 2)
        MainThreadIO.note(.read, "xctest 计数关着")
        XCTAssertNil(MainThreadIO.endCounting()["read xctest 计数关着"])
    }
}
