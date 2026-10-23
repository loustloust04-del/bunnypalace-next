//
//  SandboxRuntime.swift
//  离线沙箱的懒启动闸门 + 给 UI 订阅的状态。
//
//  **不在 app 启动路径上 boot**：rootfs 解压 ~300-600ms、boot ~10-40ms，都不该
//  挂在冷启动上；而且大多数会话根本用不到 guest。改成第一次真需要 guest 时
//  （T2 起是 run_command 调用，T1 阶段是探针）才 ensureReady()。
//
//  并发语义：ensureReady() 可以被多处同时调用，靠一个串行队列 + 已 ready 早退
//  保证解压和 boot 各只发生一次（ISHKernel.boot 不可重入——become_first_process()
//  每个进程只能来一次）。
//

import Foundation
import Observation

// `SandboxPhase` 挪到 `MemoryPalace/Services/DeviceTools/SandboxBanner.swift`（两端都编），
// 和「提示条显示什么」的纯函数放一起，好让 macOS 测试锚得住。相位的产生仍然只在这里。

@Observable
@MainActor
final class SandboxState {
    static let shared = SandboxState()
    private init() {}

    private(set) var phase: SandboxPhase = .idle

    fileprivate func set(_ next: SandboxPhase) { phase = next }
}

/// T4 ①：产品路径上的 RSS 取样点（boot 前 / boot 后 / 第一条命令跑完）。
/// T0 那组数字是**对照组**实验（专门造的探针路径）；这组是真实路径上的。
/// fork guard 的阈值也一起记，方便对着看：guest 内存到不到得了那条线。
enum SandboxRSS {
    private static let lock = NSLock()
    private(set) static var marks: [(String, Int)] = []

    static func mark(_ label: String) {
        let mb = residentMB()
        lock.lock(); marks.append((label, mb)); lock.unlock()
        print("[PROBE] RSS \(label) = \(mb) MB")
    }

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    /// fork guard 的天花板（ISHKernel.m:136-138：物理内存 1/4，clamp [500MB, 2GB]）
    static var forkGuardCeilingMB: Int {
        let ram = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        return min(max(ram / 4, 500), 2048)
    }

    private static var firstCommandMarked = false
    /// 第一条命令跑完只记一次（后面每条都记就成噪音了）
    static func markFirstCommandOnce() {
        lock.lock()
        guard !firstCommandMarked else { lock.unlock(); return }
        firstCommandMarked = true
        lock.unlock()
        mark("第一条命令后")
    }

    static func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        let pts = marks.map { "\($0.0)=\($0.1)MB" }.joined(separator: " / ")
        return "\(pts)（fork guard 天花板 \(forkGuardCeilingMB)MB，设备 RAM \(Int(ProcessInfo.processInfo.physicalMemory / 1_048_576))MB）"
    }
}

enum SandboxRuntime {
    /// 串行化 ensureReady：解压 + boot 各只做一次
    private static let queue = DispatchQueue(label: "com.susu.MemoryPalace.sandbox.boot")

    /// 幂等。返回 fakefs 根路径。可以从任意线程调用；内部会阻塞在串行队列上，
    /// 所以**别在主线程调**（boot 是同步的）。
    @discardableResult
    static func ensureReady() throws -> URL {
        let manager = RootfsManager.shared

        if manager.didResetWhileBooted {
            let msg = "沙箱已重置，请重启 app"
            Task { @MainActor in SandboxState.shared.set(.failed(msg)) }
            throw RootfsError.installFailed(msg)
        }

        return try queue.sync {
            // 已经起来了就直接用
            if ISHKernel.shared.isBooted && manager.isInstalled {
                Task { @MainActor in SandboxState.shared.set(.ready) }
                return manager.rootfsPath
            }

            do {
                Task { @MainActor in SandboxState.shared.set(.installing) }
                try manager.installIfNeeded()

                if !ISHKernel.shared.isBooted {
                    Task { @MainActor in SandboxState.shared.set(.booting) }
                    SandboxRSS.mark("boot 前")
                    let err = ISHKernel.shared.boot(withRootPath: manager.rootfsPath.path)
                    guard err == 0 else {
                        throw RootfsError.installFailed("ISHKernel.boot 返回 \(err)")
                    }
                    SandboxRSS.mark("boot 后")
                    // change consumer 必须在任何 bind mount 之前装（上游 ensureKernelBooted 的顺序）
                    SandboxChangeNotifier.installIfNeeded()
                    // R16：bind mount 会持久化进 rootfs（symlink + meta.db 行都落盘），
                    // 上次会话授权过的目录不清掉就会在这次悄悄保持可写。
                    // 必须 boot 之后、任何本次挂载之前跑一次。
                    SandboxMount.cleanResidue(rootfsPath: manager.rootfsPath)
                }

                Task { @MainActor in SandboxState.shared.set(.ready) }
                return manager.rootfsPath
            } catch {
                let msg = error.localizedDescription
                Task { @MainActor in SandboxState.shared.set(.failed(msg)) }
                throw error
            }
        }
    }
}

