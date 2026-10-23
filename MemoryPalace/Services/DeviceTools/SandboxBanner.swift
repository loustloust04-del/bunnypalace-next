import Foundation

/// 沙箱顶部提示条的**相位**与**「显示什么」的纯函数**。
///
/// 为什么在 `MemoryPalace/`（两端都编）而不是 `Sandbox/ish/`（只 iOS）：
/// 仓库里没有 iOS 单测 target，沙箱的验收全靠探针；把这段判定抽成不依赖 SwiftUI 的
/// 纯函数放进共用 sources，macOS 的 `MemoryPalaceTests` 才锚得住（BUG-4 就是
/// 「commit message 说做了、diff 里没有」这种没锚死的东西溜过去的）。
/// 相位的**产生**仍然只在 iOS（`SandboxRuntime`）。
enum SandboxPhase: Equatable {
    case idle
    case installing
    case booting
    case ready
    case failed(String)

    /// 给顶部提示条用的一句话；nil = 这个相位不该显示提示
    var bannerText: String? {
        switch self {
        case .idle, .ready: return nil
        case .installing: return "正在准备小电脑…"
        case .booting: return "正在启动小电脑…"
        case .failed(let msg): return "小电脑启动失败：\(msg)"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum SandboxBanner {
    /// 左侧图标形状。**不返回 SF Symbol 名和颜色**——那是视图层的事，
    /// 这里只说「哪一类」，纯函数就不用把 Theme 拖进测试。
    enum Icon: Equatable {
        case progress   // 转圈：沙箱正在准备/启动
        case failure    // 警告三角：起不来
        case running    // terminal：有命令在跑
    }

    struct Content: Equatable {
        let text: String
        let icon: Icon
    }

    /// **相位提示优先级高于「命令在跑」**：沙箱还没起来的时候，
    /// 「正在准备沙箱…」比「命令在跑」更该被看见（此时命令还卡在 prepare 里）。
    /// 命令跑完 `running` 空了自动收。
    static func content(phase: SandboxPhase, runningCount: Int) -> Content? {
        if let text = phase.bannerText {
            return Content(text: text, icon: phase.isFailure ? .failure : .progress)
        }
        if phase == .ready && runningCount > 0 {
            return Content(text: "命令在跑，别切走", icon: .running)
        }
        return nil
    }
}

/// 设置 › 手机里的小电脑 那句「当前楼层的文件库」（审计 T38：别再说「接进来 0 个楼层」）。纯函数，Mac 单测锚得住。
enum SandboxStatusText {
    enum Library: Equatable {
        /// 重置过，还没重启 App
        case resetPending
        case notInstalled
        /// 这个楼层开了 iCloud，暂时不挂
        case iCloud
        /// 上次挂的时候出了问题（原因原文）
        case problem(String)
        case mounted(guestPath: String)
        /// 这次打开 App 后还没用到过，用到时会挂在这里
        case notYet(guestPath: String)
    }

    static func library(_ state: Library) -> String {
        switch state {
        case .resetPending: return "小电脑已重置，重启 App 后生效"
        case .notInstalled: return "还没装好，第一次打开终端或 AI 用到时自动装"
        case .iCloud: return "这个楼层开了 iCloud 同步，文件库暂时接不进来"
        case .problem(let reason): return "没接进来：\(reason)"
        case .mounted(let path): return "在小电脑里的 \(path)"
        case .notYet(let path): return "打开终端或 AI 用到时，接到 \(path)"
        }
    }

    /// 重置确认框的说明（T39：写明文件库不受影响；有开着的终端先结束）
    static func resetMessage(openTerminals: Int) -> String {
        let base = "删掉小电脑里装过的软件和其他文件、恢复成刚装好的样子，你的文件库不受影响。重启 App 后生效。"
        return openTerminals > 0 ? "会先结束 \(openTerminals) 个开着的小电脑终端。" + base : base
    }
}
