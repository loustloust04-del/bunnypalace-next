#if PERSONAL_APPS
import SwiftUI

/// 08 开屏 overlay 接入点：nil 表示不加罩；始终保留内容树，不启用普通开屏或参与其 readiness。
@MainActor
enum TutuLaunchSplash {
    static func make() -> AnyView? {
        nil
    }
}
#endif
