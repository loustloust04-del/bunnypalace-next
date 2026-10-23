#if os(macOS)
import Foundation

/// 编程会话服务层的诊断日志口子（W-N N6）：服务层要编进不含 app 的 `mp-code` 命令行工具，不能再引用 ChatService 里的 CacheDiagLog。
/// 默认丢弃；app 启动时接到 CacheDiagLog（设置→调试可看），mp-code 不接
enum CodingDiagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: @Sendable (String) -> Void = { _ in }

    static func log(_ text: String) {
        lock.lock()
        let current = sink
        lock.unlock()
        current(text)
    }

    static func setSink(_ newSink: @escaping @Sendable (String) -> Void) {
        lock.lock()
        sink = newSink
        lock.unlock()
    }
}
#endif
