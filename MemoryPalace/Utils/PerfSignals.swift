#if (DEBUG || PERF_BENCH) && os(iOS)
import MetricKit

/// MetricKit 自定义区间（plan-perf-watch §3.2）：进日报 signpostMetrics。
/// 翻页：松手（scrollViewWillEndDragging 且会翻页）→ finishPaging，按方向分名，mxSignpostAnimation 带卡顿率；
///   程序化翻页不打；上一次没落定就又松手 = 先把旧的结束（不单独标取消，名字必须是字面量）。
/// 冷启到能打字的扩展启动任务撤了（astra R2 M06：超时收尾会把 15s 写成一次「完成的启动」，污染直方图）；
/// 冷启看日报自带的 applicationLaunchMetrics。
/// 头文件警告 mxSignpost 很贵且会被系统限流：只打翻页。测量台各角色进程（RUN / OBSERVE / SEED / RESTORE）与测试宿主里不打。
@MainActor
enum PerfSignals {
    private static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        let measuring = ["MP_PERF_RUN", "MP_PERF_OBSERVE", "MP_PERF_SEED", "MP_PERF_RESTORE"].contains { env[$0] != nil }
        return !measuring && env["XCTestConfigurationFilePath"] == nil
    }()
    private static let log = MXMetricManager.makeLogHandle(category: "mp")
    private static var flip: (id: OSSignpostID, from: Int, to: Int)?

    static func flipBegan(from: Int, to: Int) {
        guard enabled else { return }
        flipSettled()
        let id = OSSignpostID(log: log)
        switch (from, to) {
        case (0, 1): mxSignpostAnimationIntervalBegin(log: log, name: "flip01", signpostID: id)
        case (1, 0): mxSignpostAnimationIntervalBegin(log: log, name: "flip10", signpostID: id)
        case (1, 2): mxSignpostAnimationIntervalBegin(log: log, name: "flip12", signpostID: id)
        case (2, 1): mxSignpostAnimationIntervalBegin(log: log, name: "flip21", signpostID: id)
        default: return
        }
        flip = (id, from, to)
    }

    static func flipSettled() {
        guard let f = flip else { return }
        flip = nil
        switch (f.from, f.to) {
        case (0, 1): mxSignpost(.end, log: log, name: "flip01", signpostID: f.id)
        case (1, 0): mxSignpost(.end, log: log, name: "flip10", signpostID: f.id)
        case (1, 2): mxSignpost(.end, log: log, name: "flip12", signpostID: f.id)
        default: mxSignpost(.end, log: log, name: "flip21", signpostID: f.id)
        }
    }
}
#endif
