import Foundation
import Observation

// MARK: - 小芽 v2 · 舞台表情（plan-小芽-v2 §3.2 v1.1）
// 表情全部由 app 事件决定，不靠模型自觉：主状态派生一张脸，短暂反馈（批了 / 丢了 / 停了…）压在上面 2.5 秒。

enum XiaoyaMood: String, CaseIterable {
    case smirk, huh, cheer, love, sigh, nope, shock, sob, chaos

    /// 剪纸版（线稿 + 奶白纸垫 + 纸边，原色渲染，plan §3.6）
    var assetName: String { "xiaoya-cut-\(rawValue)" }
}

struct XiaoyaStageState: Equatable {
    enum Base: Equatable {
        case idle
        case thinking
        case reading(String)   // 在翻什么：预设 / 卡库 / 世界书 / 记忆
        case awaitingStamp     // 有提案等你盖章
        case error
    }

    enum Feedback: Equatable {
        case approved, discarded, stopped, overwhelmed, refused
    }

    var base: Base = .idle
    var feedback: Feedback?

    var mood: XiaoyaMood {
        if let feedback {
            switch feedback {
            case .approved: return .love
            case .discarded: return .sigh
            case .stopped: return .shock
            case .overwhelmed: return .chaos
            case .refused: return .nope
            }
        }
        switch base {
        case .idle: return .smirk
        case .thinking, .reading: return .huh
        case .awaitingStamp: return .cheer
        case .error: return .sob
        }
    }

    var status: String {
        if let feedback {
            switch feedback {
            case .approved: return "改好了"
            case .discarded: return "好吧…"
            case .stopped: return "欸——停了"
            case .overwhelmed: return "脑子打结了"
            case .refused: return "这个我现在做不了"
            }
        }
        switch base {
        case .idle: return "在呢"
        case .thinking: return "在想…"
        case .reading(let what): return "在翻你的\(what)…"
        case .awaitingStamp: return "写好啦，等你盖章"
        case .error: return "出错了"
        }
    }

    var isBusy: Bool {
        switch base {
        case .thinking, .reading: return true
        default: return false
        }
    }

    /// 只读工具 → 状态行里「在翻你的 X」；写工具 / 未知工具返回 nil
    static func readingLabel(forTool name: String) -> String? {
        switch name {
        case "read_current_preset": return "预设"
        case "read_character": return "卡库"
        case "query_memories": return "记忆"
        case "list_world_books", "read_world_book": return "世界书"
        default: return nil
        }
    }
}

/// 短暂反馈的计时器：新反馈顶掉旧的，旧计时器到点不许清掉新反馈
@Observable
@MainActor
final class XiaoyaFeedbackClock {
    private(set) var feedback: XiaoyaStageState.Feedback?
    @ObservationIgnored private var token = 0

    func flash(_ feedback: XiaoyaStageState.Feedback, seconds: Double = 2.5) {
        token += 1
        let current = token
        self.feedback = feedback
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.token == current else { return }
            self.feedback = nil
        }
    }

    func clear() {
        token += 1
        feedback = nil
    }
}

/// 排查探针（09-26 抖动 / 收放 / 翻片）：DEBUG 且显式打开才打，Release 编译成空
enum XiaoyaProbe {
    #if DEBUG
    nonisolated(unsafe) static var enabled = ProcessInfo.processInfo.environment["XIAOYA_PROBE"] == "1"
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print(String(format: "[XYPROBE] %.3f ", CFAbsoluteTimeGetCurrent()) + message())
    }
    #else
    static func log(_ message: @autoclosure () -> String) {}
    #endif
}

/// 点一下小芽翻到纸背面，背面写的一句话（粟粟 09-26）。每句最多两行，一行不超过 7 个字，剪纸背面地方小
enum XiaoyaLines {
    static let all = [
        "别翻啦\n背面没彩蛋", "今天也在\n好好长大", "我在听\n慢慢说", "盖章的手感\n很好吧",
        "偷偷说\n我有点怕黑", "纸做的\n也会害羞", "记得喝水", "再翻\n我要晕了",
        "今天想\n写点什么", "我记性\n可好了", "有我在\n不慌", "被发现了\n这是背面",
        "别看\n这是草稿", "晚安也\n可以找我", "要夸夸吗", "我是纸\n但不薄情",
        "嘘\n背面是秘密", "改东西前\n先问我", "今天的你\n也很好", "翻一次\n许一个愿",
    ]

    /// 随机一句，不跟上一句重复
    static func random(excluding last: String?) -> String {
        let pool = all.filter { $0 != last }
        return pool.randomElement() ?? all[0]
    }
}
