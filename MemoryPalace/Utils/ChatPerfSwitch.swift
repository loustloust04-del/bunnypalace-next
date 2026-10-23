import Foundation

/// 聊天页局部刀开关（plan-chat-list-perf §3）。DEBUG / PERF_BENCH 构建可用 env 改（同包 ABBA 对照；设了该键时只有 "1" 算开，其它值一律算关），
/// 普通 Release 恒为默认值
enum ChatPerfSwitch {
    /// L4 A3 共享显示数据快照（MP_PERF_A3）
    static let a3 = flag("MP_PERF_A3", default: false)
    /// L7 A5 翻到 chat 页时强制布局 + 重发几何按条件跳过（MP_PERF_A5）；ABBA worstGap −34 / −56ms 后默认开
    static let a5 = flag("MP_PERF_A5", default: true)
    /// L6 A7 ContentView 观察边界：顶栏等读 currentPath 衍生量的块包进观察围栏（MP_PERF_A7）
    static let a7 = flag("MP_PERF_A7", default: false)

    private static func flag(_ key: String, default on: Bool) -> Bool {
        #if DEBUG || PERF_BENCH
        if let v = ProcessInfo.processInfo.environment[key] { return v == "1" }
        #endif
        return on
    }
}
