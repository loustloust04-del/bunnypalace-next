import XCTest
@testable import 记忆花园

/// #033：测试 bundle 的 NSPrincipalClass（project.yml INFOPLIST_KEY_NSPrincipalClass）。加载时注册：
/// 文件库入口在主线程被调 → 记成当前测试的失败；宿主 app 启动期（还没有当前测试）只打印。
/// testCaseWillStart 比 setUp 先到：每个测试开头复位豁免，豁免要在 setUp 第一行调。
@objc(MPMainThreadIOObserver)
final class MainThreadIOTestObserver: NSObject, XCTestObservation {
    private var current: XCTestCase?

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
        MainThreadIO.violationHandler = { [weak self] message in
            guard let test = self?.current else {
                print("[MainThreadIO] 测试开始前：\(message)")
                return
            }
            test.record(XCTIssue(type: .assertionFailure, compactDescription: message))
        }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        current = testCase
        MainThreadIO.allowMainThreadInThisTest(false)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        current = nil
        MainThreadIO.allowMainThreadInThisTest(false)
    }
}
