import Foundation

/// 进度卡（粟粟 10-03「都按推荐」）：API 模型连调工具时对话底部那张卡的数据。
/// 只由工具循环写（看它往节点里记的 toolUse / toolResult），不让模型自己编进度。
struct TurnActivity: Equatable {
    struct Step: Equatable {
        let id: String
        let label: String
        let icon: String?
        let startedAt: Date
        /// nil = 还在跑
        var ok: Bool?
    }

    /// 卡住的原因（读审批中心 / 提问暂停，不存在这里）
    enum Block: Equatable {
        case approval(String)
        case question
    }

    let maxRounds: Int
    private(set) var round = 0
    private(set) var steps: [Step] = []

    init(maxRounds: Int) { self.maxRounds = maxRounds }

    var running: Step? { steps.last(where: { $0.ok == nil }) }

    /// round 从 1 数（循环里的 round 从 0 起，调用方 +1）
    mutating func startRound(_ r: Int) { round = min(max(r, 1), maxRounds) }

    /// 工具循环每往 segs 里记一段就喂进来
    mutating func observe(_ seg: MessageSegment, at now: Date = Date()) {
        switch seg {
        case .toolUse(let id, let name, _, let integration, let icon):
            guard !steps.contains(where: { $0.id == id }) else { return }
            steps.append(Step(id: id, label: Self.label(name: name, integration: integration), icon: icon, startedAt: now, ok: nil))
        case .toolResult(let id, _, let isError, _):
            guard let i = steps.firstIndex(where: { $0.id == id }), steps[i].ok == nil else { return }
            steps[i].ok = !isError
        default:
            return
        }
    }

    func headline(now: Date, blocked: Block? = nil) -> String {
        let head = "第 \(round)/\(maxRounds) 轮"
        switch blocked {
        case .approval(let what): return "\(head) · 等你批准：\(what)"
        case .question: return "\(head) · 等你回答"
        case nil: break
        }
        if let r = running { return "\(head) · 正在用 \(r.label)（\(Self.elapsed(now.timeIntervalSince(r.startedAt)))）" }
        // 工具都跑完了：模型可能接着调工具、也可能在写回复（不读 streamingText——那个每个字都变，进度卡跟着重画不值）
        return "\(head) · 在想下一步"
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒"
    }

    /// 卡上显示的名字：分支给的 integration 名（联网搜索、骰子…）；拦下来的调用（权限 / 参数错误 / 输出上限）显示工具本身
    static func label(name: String, integration: String?) -> String {
        if let integration, !integration.isEmpty, !["权限", "参数错误", "输出上限"].contains(integration) { return integration }
        return name.hasPrefix("fs_") ? "文件库" : name
    }
}
