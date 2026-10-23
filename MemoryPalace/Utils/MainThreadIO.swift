import Foundation
import os

/// #033 主线程不碰盘（plan-mainthread-io-assert）：文件库入口在主线程被调 → 单测记成当前测试失败（测试 bundle 的 observer 注册 `violationHandler`），
/// app / Air 只记日志（每个调用点首次一条，之后只累计），不崩、不改行为。顺带给碰盘点计数，计数测试用来钉住热函数的碰盘次数。
enum MainThreadIO {
    /// 计的是入口 / 操作调用次数，不是 syscall 数；mkdir 单列（目录不存在时会真的建）
    enum Kind: String { case enumerate, stat, read, write, mkdir }

    /// 测试 bundle 注册：主线程违规交给它记成当前测试的失败。nil = 只记日志
    nonisolated(unsafe) static var violationHandler: ((String) -> Void)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counting = false
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var violations: [String: Int] = [:]
    // 下面两个只在主线程读写（违规只可能发生在主线程，后台调用不看它们）
    nonisolated(unsafe) private static var toleratedDebts: [StaticString] = []
    nonisolated(unsafe) private static var allowedInThisTest = false
    private static let log = Logger(subsystem: "com.susu.MemoryPalace", category: "MainThreadIO")

    /// 文件库入口：计数 + 主线程检查
    static func assertOffMain(_ kind: Kind, _ site: StaticString) {
        note(kind, site)
        guard Thread.isMainThread else { return }
        let debt = toleratedDebts.last
        let key = "\(kind.rawValue) \(site)"
        // 已知债和非债分开累计：先撞上债的 site，后来走非债路径时照样首次记一条
        let tally = debt.map { "\(key) [已知债 \($0)]" } ?? key
        lock.lock()
        let n = (violations[tally] ?? 0) + 1
        violations[tally] = n
        lock.unlock()
        if debt != nil {
            if n == 1 { log.error("主线程碰盘 \(tally, privacy: .public)") }
            return
        }
        if !allowedInThisTest, let violationHandler {
            let stack = Thread.callStackSymbols.dropFirst(2).prefix(8).joined(separator: "\n")
            violationHandler("主线程碰盘：\(key)\n\(stack)")
            return
        }
        if n == 1 { log.error("主线程碰盘 \(key, privacy: .public)") }
    }

    /// 旁路 store 用：只计数。只计主线程——计数测试量的就是「主线程碰了几次盘」，后台 warmList 之类并发的不算，结果才确定
    static func note(_ kind: Kind, _ site: StaticString, times: Int = 1) {
        guard Thread.isMainThread else { return }
        lock.lock(); defer { lock.unlock() }
        guard counting else { return }
        counts["\(kind.rawValue) \(site)", default: 0] += times
    }

    /// 生产代码里已知的主线程碰盘：照记日志，不判红。debt 写原因 / 单号
    static func tolerated<T>(_ debt: StaticString, _ body: () throws -> T) rethrows -> T {
        guard Thread.isMainThread else { return try body() }
        toleratedDebts.append(debt)
        defer { toleratedDebts.removeLast() }
        return try body()
    }

    /// 直接测 store 的单测（测试方法本身站在主线程）：豁免本测试，observer 在下个测试开始时复位
    static func allowMainThreadInThisTest(_ on: Bool = true) { allowedInThisTest = on }

    static func beginCounting() {
        lock.lock(); defer { lock.unlock() }
        counts = [:]
        counting = true
    }

    /// key = "kind site"
    static func endCounting() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        counting = false
        return counts
    }

    /// 进程内主线程违规累计（含已知债），key = "kind site"
    static func violationCounts() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return violations
    }
}
