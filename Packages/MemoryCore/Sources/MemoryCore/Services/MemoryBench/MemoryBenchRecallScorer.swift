import Foundation

public struct MemoryBenchRecallScorer: MemoryBenchScorer {
    public let id = "recall"
    public let version = 2
    public let mainName = "错漏率反"

    public init() {}

    public func score(cells: [MemoryBenchCell], judgments: [MemoryBenchJudgment]) -> (main: Double?, parts: [String: Double]) {
        var parts = Dictionary(uniqueKeysWithValues: ["错注数", "漏注数", "门槛", "冷却", "预算", "未批", "无资料", "总轮数", "可判轮数", "不可测", "应跳过轮数", "实际搜索次数", "保持次数", "应带项数", "实带项数", "Y 定位对", "Y 定位错", "Y 定位不可测", "Y 越界", "最深层", "分页重复", "分页丢失", "应跳过却搜了", "护栏", "出错格"].map { ($0, 0.0) })
        let ids = Set(cells.map(\.id))
        let mine = judgments.filter { ids.contains($0.cellId) }
        var verdicts: [String: MemoryBenchVerdict] = [:]
        for judgment in mine {
            if let item = judgment.item { verdicts["\(judgment.cellId)#\(item)"] = judgment.verdict }
        }
        for cell in cells {
            if cell.checks.contains(where: { ["privacyLeak", "l2Impersonation", "originalOverrun"].contains($0.name) && !$0.passed }) {
                parts["护栏"] = 1
            }
            if cell.error != nil || cell.checks.contains(where: { $0.name == "召回输出 JSON" && $0.hard && !$0.passed }) {
                parts["出错格", default: 0] += 1
            }
            for item in cell.items {
                let f = item.fields
                let verdict = verdicts["\(cell.id)#\(item.index)"]
                switch f["kind"] {
                case "turn":
                    parts["总轮数", default: 0] += 1
                    for (field, key) in [("judgeable", "可判轮数"), ("skip", "应跳过轮数"), ("searched", "实际搜索次数"), ("kept", "保持次数")] where f[field] == "true" {
                        parts[key, default: 0] += 1
                    }
                    if f["judgeable"] == "false" { parts["不可测", default: 0] += 1 }
                    parts["应带项数", default: 0] += Double(f["required"] ?? "") ?? 0
                    if f["skip"] == "true", verdict == .wrong { parts["应跳过却搜了", default: 0] += 1 }
                case "x":
                    if f["judgeable"] == "false" { continue }
                    parts["实带项数", default: 0] += 1
                    if verdict == .wrong { parts["错注数", default: 0] += 1 }
                case "miss":
                    if verdict == .wrong {
                        parts["漏注数", default: 0] += 1
                        let reason = f["reason"] ?? "无资料"
                        parts[["门槛", "冷却", "预算", "未批"].contains(reason) ? reason : "无资料", default: 0] += 1
                    }
                case "location":
                    let key = verdict == .right ? "Y 定位对" : verdict == .wrong ? "Y 定位错" : "Y 定位不可测"
                    parts[key, default: 0] += 1
                case "y":
                    if verdict == .wrong { parts["Y 越界", default: 0] += 1 }
                    if ["success", "partial", "legacy"].contains(f["status"] ?? "") {
                        parts["最深层"] = max(parts["最深层"] ?? 0, Double(MemoryBenchRecallOutput.depth(f["layer"])))
                    }
                    parts["分页重复", default: 0] += Double(f["paginationRepeat"] ?? "") ?? 0
                    parts["分页丢失", default: 0] += Double(f["paginationGap"] ?? "") ?? 0
                default: break
                }
            }
        }
        let actual = parts["实带项数", default: 0]
        let denominator = actual + parts["漏注数", default: 0]
        let right = actual - parts["错注数", default: 0]
        let main = parts["护栏"] == 1 || parts["出错格", default: 0] > 0 || denominator == 0 ? nil : right / denominator
        return (main, parts)
    }
}
