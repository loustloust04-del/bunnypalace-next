import Foundation
import MemoryCore

/// 实验台的「写完一批再对着档案下结论」（plan-c2-target §1.5 步 4，还没进 app）。
/// 用的是包里的 `FragmentVerdict`（提示词、捞卡、解码校验都在那边）；这里只管：从哪拿材料、跑哪几个模型各几次、
/// 要不要请裁判、把每次调用存进实验的调用记录。结果挂在 `MemorydExperiment.verdict`，页面和别的实验同一处看
struct MemorydVerdictRequest: Decodable, Sendable {
    /// 拿一次写卡实验里的卡当档案
    struct ArchiveRef: Decodable, Sendable {
        var experiment: String
        /// 只要哪几批（从 0 数）；不给 = 全部
        var batches: [Int]?
        /// 这次实验的卡里（按上面挑完之后的先后，从 0 数）哪几张当「她删过的」、哪几张当「她改过 / 钉住的」
        var deleted: [Int]?
        var protected: [Int]?
    }

    /// 副本 `exports/fragments.json` 里的旧卡也放进池子
    struct Exported: Decodable, Sendable {
        /// other = 别的窗口的；same = 这个窗口的；all = 全部
        var scope: String
        /// true = 当「她删过的」
        var deleted: Bool?
    }

    struct RunSpec: Decodable, Sendable {
        var model: String
        var times: Int?
    }

    /// 这次叫什么（列表里显示）
    var name: String?
    /// 直接给整份材料（虚构夹具走这条）；给了就不看下面三项
    var job: FragmentVerdict.Job?
    /// 或者：哪次写卡实验的第几批当新卡，原文从快照里取那一批对应的消息
    var experiment: String?
    var batch: Int?
    var archive: [ArchiveRef]?
    var exported: Exported?
    /// 「聊天时本来就带着的内容」：副本 `exports/` 下的一个文本文件（没有这份导出就不给，那一块是空的）
    var residentFile: String?
    /// true = 副本 `wiki/` 下已经落盘的页也放进材料（和 app 同一个取法）；job 里自己带了 pages 就用 job 的。不给 = 没有这一块
    var wiki: Bool?
    var runs: [RunSpec]
    var limits: FragmentVerdict.Limits?
    /// 裁判用哪个模型；下面两项给了才用得上
    var judge: String?
    /// 请裁判对着整池判「该捞的捞到没有」
    var judgeRelated: Bool?
    /// 请裁判逐张判每个被测模型第一次的结论
    var judgeRuns: Bool?
    /// true = 只回这组上限会捞出哪些卡（不调模型、不留实验），调上限时用
    var dryRun: Bool?
    /// true = 另外造一份「全部留下」的假结论也请裁判判一遍：看裁判是不是什么都说行（要 judgeRuns）
    var probeKeepAll: Bool?

    static let probeModel = "（对照：全部留下）"

    static let maxTimes = 5
}

struct MemorydVerdictReport: Codable, Equatable, Sendable {
    struct Run: Codable, Equatable, Sendable {
        var model: String
        /// 这个模型的第几次（从 1 数）
        var n: Int
        var verdicts: [FragmentVerdict.Verdict] = []
        /// 新卡 id → 代码算出来的信号
        var signals: [String: [String]] = [:]
        var stray = 0
        var retried = false
        var failed = false
        var error: String?
    }

    /// 裁判对着整池判：每张新卡，池里哪些和它是同一件事
    struct RelatedJudgment: Codable, Equatable, Sendable {
        var judge: String
        var same: [String: [String]] = [:]
        var error: String?
    }

    struct Ruling: Codable, Equatable, Sendable {
        var card: String
        var ok: Bool
        var should: String?
        var why: String?
    }

    struct JudgedRun: Codable, Equatable, Sendable {
        var judge: String
        var model: String
        var n: Int
        var rulings: [Ruling] = []
        var error: String?
    }

    var name: String
    var userName: String
    var assistantName: String
    var limits: FragmentVerdict.Limits
    var newCards: [FragmentVerdict.NewCard]
    /// 整个池子（挑之前）
    var pool: [FragmentVerdict.ArchiveCard]
    /// 挑出来喂给模型的（id，按编号 E1… / D1… 的先后）
    var existing: [String]
    var deleted: [String]
    var hits: [String: [FragmentVerdict.Hit]]
    var lines: Int
    /// 「聊天时本来就带着的内容」给了多少字、裁掉多少字
    var residentChars: Int
    var residentCut: Int
    /// 还在的卡是整池都给了，还是挑的；这一项和下面两项老实验里没有 = nil
    var existingWhole: Bool?
    /// 已经写成 wiki 页的内容给了几页、没放进去多少字
    var wikiPages: Int?
    var wikiCut: Int?
    var runs: [Run] = []
    var related: RelatedJudgment?
    var judged: [JudgedRun] = []
}

enum MemorydVerdictRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 从副本里拼出一份材料：新卡 = 那次写卡实验的那一批，原文 = 快照里那一批对应的消息，池子 = 点名的几次实验的卡（+ 旧导出）。
    /// pages = 副本里已经落盘的 wiki 页怎么取（参数是用户名）；请求里 `wiki` 给了 true 才取
    static func job(_ request: MemorydVerdictRequest, experiments: (String) -> MemorydExperiment?, exported: () -> [MemorydService.ExportedFragment],
                    conversations: (any ConversationSource)?, profileId: String, exportsDir: URL,
                    pages: (String) -> [FragmentVerdict.Page] = { _ in [] }) throws -> FragmentVerdict.Job {
        if var job = request.job {
            if job.resident.isEmpty, let file = request.residentFile { job.resident = try resident(file, in: exportsDir) }
            if job.pages.isEmpty, request.wiki == true { job.pages = pages(job.userName) }
            return job
        }
        guard let id = request.experiment, let source = experiments(id) else { throw Failure(message: "请求体要 job，或者 experiment（一次写卡实验的 id）") }
        let batchIndex = request.batch ?? 0
        guard source.fragments.indices.contains(batchIndex) else { throw Failure(message: "那次实验没有第 \(batchIndex) 批") }
        let batch = source.fragments[batchIndex]
        guard let conversations, let window = try conversations.window(profileId: profileId, idOrPrefix: source.options.conversationId) else {
            throw Failure(message: "快照里没有那次实验的对话")
        }
        let path = try MemorydExperimentRunner.messages(window: window, source: conversations)
        guard batch.from >= 1, batch.to <= path.count, batch.from <= batch.to else { throw Failure(message: "那一批的消息范围和快照对不上") }
        let lines = path[(batch.from - 1)..<batch.to].map {
            FragmentVerdict.Line(role: $0.role, text: $0.content, at: $0.date.map { stamp.string(from: $0) })
        }
        let new = batch.cards.enumerated().map { offset, card in
            FragmentVerdict.NewCard(id: "n\(offset + 1)", content: card.content, subject: card.subject, speaker: card.speaker,
                                    message: (batch.from...batch.to).contains(card.message) ? card.message - batch.from + 1 : nil)
        }
        var pool: [FragmentVerdict.ArchiveCard] = []
        for (refIndex, ref) in (request.archive ?? []).enumerated() {
            guard let from = experiments(ref.experiment) else { throw Failure(message: "没有这次实验：\(ref.experiment)") }
            let batches = from.fragments.indices.filter { ref.batches?.contains($0) ?? true }
            let cards = batches.flatMap { from.fragments[$0].cards }
            let other = from.options.conversationId != source.options.conversationId
            for (offset, card) in cards.enumerated() {
                pool.append(.init(id: "p\(refIndex + 1).\(offset + 1)", content: card.content, subject: card.subject, otherWindow: other,
                                  isProtected: ref.protected?.contains(offset) == true, isDeleted: ref.deleted?.contains(offset) == true))
            }
        }
        if let old = request.exported {
            for card in exported() {
                let same = card.conversationId == window.id
                guard old.scope == "all" || (old.scope == "same") == same else { continue }
                pool.append(.init(id: "old\(card.i)", content: card.content, subject: card.subject, otherWindow: !same,
                                  isDeleted: old.deleted == true))
            }
        }
        return FragmentVerdict.Job(windowTitle: window.title, userName: source.options.userName, assistantName: source.options.assistantName,
                                   lines: Array(lines), newCards: new, archive: pool,
                                   resident: try request.residentFile.map { try resident($0, in: exportsDir) } ?? [],
                                   pages: request.wiki == true ? pages(source.options.userName) : [])
    }

    /// 只认 `exports/` 下的文件名（不许带路径）
    private static func resident(_ file: String, in exportsDir: URL) throws -> [FragmentVerdict.ResidentSection] {
        guard !file.contains("/"), !file.contains(".."), let text = try? String(contentsOf: exportsDir.appendingPathComponent(file), encoding: .utf8) else {
            throw Failure(message: "exports/ 下读不到 \(file)")
        }
        return [.init(title: "聊天时带着的提示词", text: text)]
    }

    // MARK: - 裁判

    static let relatedSystem = """
    你是裁判。下面有两组卡：「新卡」（N1、N2…）和「旧卡」（P1、P2…）。
    对每张新卡，从旧卡里找出和它说的是同一件具体的事的：一字不差的重复、换了说法的重复、是它的旧版本（后来情况变了）、互相矛盾的，都算。
    只是同一个话题、同一个人、同一类事，不算。拿不准的不算。
    只输出一个 JSON 对象，前后不要别的字：{"related":[{"card":"N1","same":["P3","P17"]},{"card":"N2","same":[]}]}
    每张新卡正好一条。
    """

    static func relatedUser(new: [FragmentVerdict.NewCard], pool: [FragmentVerdict.ArchiveCard]) -> String {
        func line(_ label: String, _ subject: String?, _ content: String) -> String {
            "[\(label)] \(subject.map { $0 + "：" } ?? "")\(content.replacingOccurrences(of: "\n", with: " ⏎ "))"
        }
        return "## 新卡\n\n" + new.enumerated().map { line("N\($0.offset + 1)", $0.element.subject, $0.element.content) }.joined(separator: "\n")
            + "\n\n## 旧卡\n\n" + pool.enumerated().map { line("P\($0.offset + 1)", $0.element.subject, $0.element.content) }.joined(separator: "\n")
    }

    static let rulingSystem = """
    你是裁判，检查另一个模型做的一份核对结果。
    那个模型拿到的「任务说明」和「材料」原样附在下面，最后是「它交的结论」。
    请你自己对着材料逐张判断：它给每张新卡的结论，直接照做会不会出错？
    - ok=true：照做没问题。措辞上的小出入不算错；这张确实不好判、它说拿不准，也算 true。
    - ok=false：照做会出错——留了不该留的、删了该留的、并错了卡、把已有的卡改错了、改写改歪了意思、明明很清楚却说拿不准。
    should 写你认为对的结论：keep / drop / merge / rewrite / unsure（drop 再写 reason，merge 再写 ref）。
    只输出一个 JSON 对象，前后不要别的字：{"rulings":[{"card":"N1","ok":true,"should":"keep","why":"……"}]}
    每张新卡正好一条，why 一句话。
    """

    /// 把一次的结论写成裁判读得懂的几行（编号换回 N / E / D / W）
    static func rendered(_ verdicts: [FragmentVerdict.Verdict], material: FragmentVerdict.Material) -> String {
        func label(_ id: String?) -> String {
            guard let id else { return "?" }
            if let at = material.existing.firstIndex(where: { $0.id == id }) { return "E\(at + 1)" }
            if let at = material.deleted.firstIndex(where: { $0.id == id }) { return "D\(at + 1)" }
            if let at = material.pages.firstIndex(where: { $0.path == id }) { return "W\(at + 1)" }
            return "?"
        }
        return verdicts.enumerated().map { offset, verdict in
            var line = "N\(offset + 1)：\(verdict.action.rawValue)"
            switch verdict.action {
            case .drop: line += "（reason：\(verdict.reason?.rawValue ?? "?")\(verdict.reason == .deleted || verdict.reason == .inWiki ? "，ref \(label(verdict.ref))" : "")）"
            case .merge: line += "（ref \(label(verdict.ref))" + (verdict.text.map { "，把它改成：\($0)" } ?? "，不改它") + "）"
            case .rewrite: line += "（改成：\(verdict.text ?? "")\(verdict.origin.map { "，origin \($0)" } ?? "")）"
            case .unsure:
                if let problem = verdict.downgraded {
                    line += "（\(verdict.modelAction.map { "它本来交的是 \($0.rawValue)，" } ?? "")因为「\(problem)」被改成了拿不准）"
                }
            case .keep: break
            }
            return line + (verdict.why.map { " —— \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    private static func object(_ raw: String) -> [String: Any]? {
        var text = raw
        if text.hasPrefix("<think>"), let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    }

    private static func number(_ any: Any?, prefix: Character) -> Int? {
        guard let text = (any as? String) ?? (any as? NSNumber)?.stringValue else { return nil }
        let cleaned = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.filter(\.isLetter).allSatisfy({ $0 == prefix }) else { return nil }
        return Int(cleaned.filter(\.isNumber))
    }

    static func parsedRelated(_ raw: String, new: [FragmentVerdict.NewCard], pool: [FragmentVerdict.ArchiveCard]) -> [String: [String]]? {
        guard let rows = object(raw)?["related"] as? [[String: Any]] else { return nil }
        var out: [String: [String]] = [:]
        for row in rows {
            guard let card = number(row["card"], prefix: "N"), new.indices.contains(card - 1) else { continue }
            out[new[card - 1].id] = (row["same"] as? [Any] ?? []).compactMap { number($0, prefix: "P") }
                .filter { pool.indices.contains($0 - 1) }.map { pool[$0 - 1].id }
        }
        return out
    }

    static func parsedRulings(_ raw: String, new: [FragmentVerdict.NewCard]) -> [MemorydVerdictReport.Ruling]? {
        guard let rows = object(raw)?["rulings"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let card = number(row["card"], prefix: "N"), new.indices.contains(card - 1), let ok = row["ok"] as? Bool else { return nil }
            var should = row["should"] as? String
            if let reason = row["reason"] as? String, !reason.isEmpty { should = (should ?? "") + ":" + reason }
            if let ref = (row["ref"] as? String) ?? (row["ref"] as? NSNumber)?.stringValue, !ref.isEmpty { should = (should ?? "") + ":" + ref }
            return .init(card: new[card - 1].id, ok: ok, should: should, why: row["why"] as? String)
        }
    }

    // MARK: - 跑

    /// 被测模型各跑几次 →（要的话）裁判判捞卡 → 裁判判每个模型第一次的结论。每次调用都进调用记录
    static func run(_ start: MemorydExperiment, job: FragmentVerdict.Job, request: MemorydVerdictRequest,
                    models: [(spec: MemorydVerdictRequest.RunSpec, model: MemorydModel)], judge: MemorydModel?, callsDir: URL,
                    onUpdate: @escaping @Sendable (MemorydExperiment) async -> Void) async -> MemorydExperiment {
        var result = start
        guard var report = start.verdict else { return result }
        let meter = ExperimentMeter()
        let calls = ExperimentCallLog(dir: callsDir)
        let related = FragmentVerdict.related(to: job.newCards, in: job.archive, limits: report.limits)
        let wiki = FragmentVerdict.picked(job.pages, for: job.newCards, limits: report.limits)
        let material = FragmentVerdict.Material(job: job, related: related, pages: wiki.pages)
        // 材料里带了删过的卡才多出那一块的说明；不带 = 和 app 里「C2 整理」发的一字不差
        let system = FragmentVerdict.system(names: job.names, resident: job.resident, limits: report.limits, deleted: !related.deleted.isEmpty,
                                            wiki: wiki)

        func caller(_ step: String, _ label: String, model: MemorydModel) -> SessionSegmentWriter.Caller {
            { system, user in
                let started = Date()
                do {
                    let reply = try await model.complete(system: system, user: user)
                    meter.add(reply.usage)
                    calls.add(step: step, label: label, system: system, user: user, reply: reply.text, usage: reply.usage,
                              seconds: Int(Date().timeIntervalSince(started)), error: nil)
                    return reply.text
                } catch {
                    calls.add(step: step, label: label, system: system, user: user, reply: nil, usage: nil,
                              seconds: Int(Date().timeIntervalSince(started)), error: error.localizedDescription)
                    throw error
                }
            }
        }
        func publish(_ progress: String) async {
            let totals = meter.totals
            result.progress = progress
            result.calls = totals.calls
            result.inputTokens = totals.input
            result.outputTokens = totals.output
            result.callLog = calls.all
            result.verdict = report
            await onUpdate(result)
        }

        for (spec, model) in models {
            let times = min(max(spec.times ?? 1, 1), MemorydVerdictRequest.maxTimes)
            for n in 1...times {
                guard !Task.isCancelled else { break }
                await publish("下结论 \(model.modelId) 第 \(n) / \(times) 次")
                var row = MemorydVerdictReport.Run(model: model.modelId, n: n)
                do {
                    if let out = try await FragmentVerdict.run(material, system: system,
                                                               caller: caller("verdict", "\(model.modelId) 第 \(n) 次", model: model)) {
                        row.verdicts = out.verdicts
                        row.stray = out.stray
                        row.retried = out.retried
                        row.failed = out.failed
                        for verdict in out.verdicts {
                            let signals = FragmentVerdict.signals(for: verdict, material: material).map(\.rawValue)
                            if !signals.isEmpty { row.signals[verdict.card] = signals }
                        }
                    } else {
                        row.error = "模型没回内容"
                    }
                } catch {
                    row.error = error.localizedDescription
                }
                report.runs.append(row)
            }
        }

        if let judge, request.judgeRelated == true, !job.archive.isEmpty, !Task.isCancelled {
            await publish("裁判：该捞的捞到没有")
            var row = MemorydVerdictReport.RelatedJudgment(judge: judge.modelId)
            do {
                let raw = try await caller("judge", "裁判 \(judge.modelId)：对着整池找同一件事的卡", model: judge)(
                    relatedSystem, relatedUser(new: job.newCards, pool: job.archive))
                if let same = raw.flatMap({ parsedRelated($0, new: job.newCards, pool: job.archive) }) {
                    row.same = same
                } else {
                    row.error = "裁判交的读不懂"
                }
            } catch {
                row.error = error.localizedDescription
            }
            report.related = row
        }

        if let judge, request.judgeRuns == true, !Task.isCancelled {
            if request.probeKeepAll == true {
                report.runs.append(.init(model: MemorydVerdictRequest.probeModel, n: 1,
                                         verdicts: job.newCards.map { FragmentVerdict.Verdict(card: $0.id, action: .keep) }))
            }
            // 裁判不判自己那一次
            for run in report.runs where run.n == 1 && run.error == nil && !run.failed && run.model != judge.modelId {
                guard !Task.isCancelled else { break }
                await publish("裁判：判 \(run.model) 的结论")
                var row = MemorydVerdictReport.JudgedRun(judge: judge.modelId, model: run.model, n: run.n)
                do {
                    let brief = "## 任务说明\n\n\(system)\n\n\n## 材料\n\n\(FragmentVerdict.user(material))\n\n\n## 它交的结论\n\n\(rendered(run.verdicts, material: material))"
                    let raw = try await caller("judge", "裁判 \(judge.modelId)：判 \(run.model) 第 1 次的结论", model: judge)(rulingSystem, brief)
                    if let rulings = raw.flatMap({ parsedRulings($0, new: job.newCards) }) {
                        row.rulings = rulings
                    } else {
                        row.error = "裁判交的读不懂"
                    }
                } catch {
                    row.error = error.localizedDescription
                }
                report.judged.append(row)
            }
        }

        result.status = Task.isCancelled ? "failed" : "done"
        if Task.isCancelled { result.note = "中途停下" }
        result.finishedAt = Date()
        await publish("")
        return result
    }
}
