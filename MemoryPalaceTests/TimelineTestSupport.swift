import Foundation
@testable import 记忆花园

/// 测试夹具：往月文件里放一条老时间轴条目（旧的一天 × 一窗口格式，现在只读）
extension TimelineStore {
    static func seedLegacy(_ e: TimelineEntry, in dir: URL) throws {
        try mutateMonth(String(e.dayKey.prefix(7)), in: dir) { $0.entries.append(e) }
    }
}
