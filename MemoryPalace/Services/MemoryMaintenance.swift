import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// 手动重写 / 搬迁 / 恢复共用全局互斥，持有者负责让日常写手停手。
/// iOS 常亮，结束 / 停下 / 出错都由它统一放开（body 不抛错，放开一定走到）
@MainActor
@Observable
final class MemoryMaintenance {
    static let shared = MemoryMaintenance()
    nonisolated static let busyText = "另一处正在重写、搬迁或恢复，等它做完再点"
    static let waitingText = "在等后台记忆任务写完…"

    /// 没跑成的原因（10-16）
    enum Refusal: Error, Equatable {
        /// 已经有一趟在跑
        case held
        /// 等够了日常写手还在写（在写的那几个）
        case writersBusy([String])
        /// 等的时候点了停下
        case cancelled

        var text: String {
            switch self {
            case .held: return MemoryMaintenance.busyText
            case .writersBusy(let jobs): return "后台还有记忆任务在写（\(jobs.joined(separator: "、"))），稍后再试"
            case .cancelled: return "点了停下，什么都没动"
            }
        }
    }

    static func text(_ r: Result<String, Refusal>) -> String {
        switch r {
        case .success(let s): return s
        case .failure(let f): return f.text
        }
    }

    /// 正在跑的那一趟（「搬迁」/「恢复」）；nil = 空着
    private(set) var holder: String?

    /// 拿不到资格 / 日常写手 idleTimeout 秒内没停手 / 等的时候被取消 = failure，body 不跑。
    /// 10-16：等写手有上限、可取消；不管哪条路出去，日常写手都放开、资格都还回去（waitUntilIdle 和 body 都不抛，放开一定走到）
    func exclusive<T>(_ what: String, keepAwake: Bool = false, idleTimeout: TimeInterval = SessionCloseout.idleWaitTimeout,
                      _ body: () async -> T) async -> Result<T, Refusal> {
        guard holder == nil else { return .failure(.held) }
        holder = what
        if keepAwake { Self.setIdleTimerDisabled(true) }
        defer {
            if keepAwake { Self.setIdleTimerDisabled(false) }
            holder = nil
        }
        // A4 一天一条也停手（c2c3-v2 第 7 段 astra #4）：新的一趟不进；在途那趟后面的提交在月文件锁里看纪元，作废
        TimelineDaily.gate.pause()
        defer { TimelineDaily.gate.resume() }
        await SessionCloseout.shared.setRegenerating(true)
        let result: Result<T, Refusal>
        switch await SessionCloseout.shared.waitUntilIdle(timeout: idleTimeout) {
        case .idle where Task.isCancelled: result = .failure(.cancelled)   // 10-16 astra #1：等到了也先看一眼停下
        case .idle: result = .success(await body())
        case .timedOut(let jobs): result = .failure(.writersBusy(jobs))
        case .cancelled: result = .failure(.cancelled)
        }
        await SessionCloseout.shared.setRegenerating(false)
        return result
    }

    /// iOS：跑的时候屏幕常亮（切走 App 请求会断，U3）
    private static func setIdleTimerDisabled(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}
