import Foundation

/// WKWebView 默认 UA 缺 `Version/N.N` 字段——X.com 等反爬站据此判定"非真浏览器"拒服务（白屏）。
/// 用真 Safari UA 字串伪装，关键字段 `Version/18.0`。参考 satyricon-browser §8。
enum WebUserAgent {
    /// iPhone Safari 18 移动端 UA
    static let iOSMobile =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// macOS Safari 18 桌面端 UA
    static let macDesktop =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// 平台默认：iOS 用 iOSMobile / macOS 用 macDesktop
    static var platformDefault: String {
        #if os(iOS)
        return iOSMobile
        #else
        return macDesktop
        #endif
    }
}
