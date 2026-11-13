import Foundation
import MemoryCore

/// memoryd v1 的离线写手：只测「一句话 → wiki 全文索引命中哪些页」这一段，跑的是 app 的召回管线
/// （`RecallFullText.terms → queryWeights → query → search → ranked → verified`），不读对话树、不调模型。
/// 用例输入：`{"query": "…"}`；标签：`必须带` / `允许带` / `禁止带` / `应跳过`，
/// 键写作 `page:<路径>` 或 `page:<路径>|<版本>`。
struct OfflineWikiBenchWriter: MemoryBenchWriter {
    static let id = "wiki"

    enum InputError: LocalizedError {
        case notQueryCase

        var errorDescription: String? { "memoryd v1 只跑 {\"query\": \"…\"} 形状的用例" }
    }

    var id: String { Self.id }
    var title: String { "翻 wiki" }
    var callStyle: MemoryBenchCallStyle { .local }
    var labelKinds: [String] { ["必须带", "允许带", "禁止带", "应跳过"] }
    var variableCatalog: [MemoryBenchVariable] { [] }
    /// 命中列表里没有可以逐条判的条目，主分只能是「按标签判对的比例」，所以别沿用 app 的「判对比例」这个名字
    var scorers: [any MemoryBenchScorer] { [OfflineWikiBenchScorer()] }

    static func query(of testCase: MemoryBenchCase) throws -> String {
        guard case .object(let object) = testCase.input,
              case .string(let query)? = object["query"],
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputError.notQueryCase
        }
        return query
    }

    static func isRunnable(_ testCase: MemoryBenchCase) -> Bool {
        (try? query(of: testCase)) != nil
    }

    func builtInRecipes(defaults: UserDefaults) -> [MemoryBenchRecipe] {
        [MemoryBenchRecipe(id: "current", writer: Self.id, name: "现行", system: "", user: "",
                           params: [:], checks: "none", builtIn: true)]
    }

    func variables(for testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) throws -> [String: MemoryBenchValue] {
        [:]
    }

    func parse(output: String, testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) -> MemoryBenchParsed {
        guard let data = output.data(using: .utf8),
              let result = try? MemoryBench.decoder.decode(OfflineWikiBenchOutput.self, from: data) else {
            return MemoryBenchParsed(items: [],
                checks: [MemoryBenchCheck(name: "输出可解析", passed: false, hard: true, detail: "不是 memoryd 的 wiki 输出")])
        }
        let items = result.hits.enumerated().map { index, hit in
            MemoryBenchItem(index: index, text: "\(hit.kind) \(hit.path)", fields: [
                "kind": hit.kind,
                "path": hit.path,
                "version": hit.version,
                "layer": "wiki页",
            ])
        }
        let checks = [MemoryBenchCheck(name: "查询词", passed: !result.terms.isEmpty, hard: false,
                                       detail: result.terms.isEmpty ? "没有可用检索词，按跳过处理" : result.terms.joined(separator: "、"))]
        return MemoryBenchParsed(items: items, checks: checks)
    }

    /// 每条标签一个判断：`必须带` 命中 = 对，`禁止带` 命中 = 错，`应跳过` 只在没有任何命中时算对。
    /// `item` 用「命中数 + 标签序号」，保证同格多条判断不互相覆盖（`effectiveJudgments` 按 cellId#item 去重）。
    func autoJudge(items: [MemoryBenchItem], labels: [MemoryBenchLabel]) -> [(item: Int, verdict: MemoryBenchVerdict, labelId: String)] {
        var out: [(item: Int, verdict: MemoryBenchVerdict, labelId: String)] = []
        for (offset, label) in labels.enumerated() {
            let item = items.count + offset
            switch label.kind {
            case "必须带":
                out.append((item, label.keys.contains(where: { Self.hit($0, in: items) != nil }) ? .right : .wrong, label.id))
            case "禁止带":
                out.append((item, label.keys.contains(where: { Self.hit($0, in: items) != nil }) ? .wrong : .right, label.id))
            case "应跳过":
                out.append((item, items.isEmpty ? .right : .wrong, label.id))
            default:
                continue
            }
        }
        return out
    }

    /// `page:<路径>` / `page:<路径>|<版本>` → 命中的条目下标
    static func hit(_ key: String, in items: [MemoryBenchItem]) -> Int? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let kind = String(key[..<colon])
        let rest = String(key[key.index(after: colon)...])
        let path = rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
        let version = rest.contains("|") ? rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) : nil
        return items.firstIndex { item in
            item.fields["kind"] == kind && item.fields["path"] == path
                && (version == nil || item.fields["version"] == version)
        }
    }
}

/// 只改名字的占位打分器：算法还是 `MemoryBenchBasicScorer`（「对」的判断数 / 已判数），
/// 但这个数在 wiki 写手这里是「标签判对比例」，和 app 页面的「判对比例」不是一回事
struct OfflineWikiBenchScorer: MemoryBenchScorer {
    let id = "basic"
    let version = 1
    let mainName = "标签判对比例"

    func score(cells: [MemoryBenchCell], judgments: [MemoryBenchJudgment]) -> (main: Double?, parts: [String: Double]) {
        MemoryBenchBasicScorer().score(cells: cells, judgments: judgments)
    }
}

struct OfflineWikiBenchOutput: Codable, Equatable, Sendable {
    struct Hit: Codable, Equatable, Sendable {
        var kind: String
        var path: String
        var version: String
    }

    var query: String
    /// `RecallFullText.terms` 切出来的词（已去掉「不触发的词」）
    var terms: [String]
    /// `RecallFullText.query(weights:)` 筛过、真拿去检索的词
    var words: [String]
    var hits: [Hit]
}
