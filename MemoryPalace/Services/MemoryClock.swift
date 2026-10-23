import Foundation

/// 记忆注入取「现在」的地方（时间轴挑最近几条按它算）。测试能钉住一个固定时刻，金样不会每天变红；
/// 钉的值只在测试进程里生效（App 里设了也不认）
enum MemoryClock {
    nonisolated(unsafe) static var fixedForTests: Date?

    static var now: Date {
        if let d = fixedForTests, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return d }
        return Date()
    }
}
