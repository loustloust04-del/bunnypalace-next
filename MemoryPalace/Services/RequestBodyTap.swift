#if DEBUG
import Foundation

/// 测试观测点：各 provider 建完实发 body 后交一份（handler 为 nil 时什么都不做）。Release 不编进去。
enum RequestBodyTap {
    static var handler: (([String: Any]) -> Void)?

    static func emit(_ body: [String: Any]) {
        handler?(body)
    }
}
#endif
