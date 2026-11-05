import Foundation

// MARK: - 新用户三问（C2/C3 v2 第 11 段）：答案只当一个种子任务的原料，绑定目标楼层；目录、正文两批照种子

enum CatalogSurvey {
    static let layer = "问卷"
    static let prefix = "问卷/"
    /// 每次问卷的原答案（wiki 根下隐藏文件夹，同 .runs / .proposals 一级）：不随任务、提案、整理记录清理，出处靠它查回原话
    static let folder = ".survey"

    struct Question: Sendable {
        var key: String
        var title: String
    }

    /// 只有这三问（不扩题）；答案路径 = 问卷/<key>
    static let questions = [
        Question(key: "称呼", title: "想让我叫你什么"),
        Question(key: "在做什么", title: "平时在做什么（工作 / 学习 / 创业）"),
        Question(key: "应该知道的", title: "有没有我应该知道的"),
    ]

    struct Answer: Codable, Equatable, Sendable {
        var key: String
        var question: String
        var text: String

        var path: String { CatalogSurvey.prefix + key }
    }

    /// 一次问卷的原答案：任务 id、答题日期
    struct Source: Codable, Equatable, Sendable {
        var taskId: String
        var profileId: String
        var day: String
        var answeredAt: Date
        var answers: [Answer]
    }

    /// 现在生成不了的原因，和她能怎么恢复
    enum Blocker: String, Codable, Sendable {
        case memoryOff, c3Off, noModel, localModel, background

        var reason: String {
            switch self {
            case .memoryOff: return "记忆总开关关着"
            case .c3Off: return "C3（整理编目）关着"
            case .noModel: return "还没有能用的模型"
            case .localModel: return "C3 选的本机模型现在用不了（没下好，或这台设备跑不了）"
            case .background: return "app 在后台，本机模型跑不了"
            }
        }

        var fix: String {
            switch self {
            case .memoryOff: return "去「设置 › 记忆」打开记忆总开关，再到 C3 页「种子」点「继续这个种子任务」"
            case .c3Off: return "去「设置 › 记忆」把 C3 打开，再到 C3 页「种子」点「继续这个种子任务」"
            case .noModel: return "先在「设置 › 模型和API」配好一把钥匙，再到「设置 › 记忆 › C3」的「种子」点「继续这个种子任务」"
            case .localModel: return "在 C3 页下好这个本机模型或换一个模型，再点「种子」里的「继续这个种子任务」"
            case .background: return "回到前台后，去 C3 页「种子」点「继续这个种子任务」"
            }
        }
    }

    enum Outcome: Codable, Equatable, Sendable {
        /// 答案存进目标楼层，接着出目录
        case started
        /// 答案存好了，现在生成不了：可稍后生成
        case later(Blocker)
        /// 全空 / 全跳过：什么都不建
        case empty
        case failed
    }

    /// 三格答案（顺序同 questions）→ 填了的那几条
    static func answers(_ texts: [String]) -> [Answer] {
        zip(questions, texts).compactMap { q, raw in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Answer(key: q.key, question: q.title, text: text)
        }
    }

    /// 答题日期（当地日历日）
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func sourcePath(_ taskId: String) -> String { folder + "/" + taskId + ".json" }

    /// 一条答案的出处：指向这次问卷的原答案文件，带答题日期
    static func cite(key: String, taskId: String, day: String) -> WikiProposal.Cite {
        WikiProposal.Cite(layer: layer, day: day, filePath: sourcePath(taskId), name: key)
    }

    /// 记录行「（出处：问卷「在做什么」2026-10-22#1A2B3C4D）」：日期 + 任务 id 前 8 位，分得清是哪一次问卷，也查得回原答案
    static func label(_ cite: WikiProposal.Cite) -> String {
        let task = (cite.filePath ?? "").split(separator: "/").last.map { String($0.prefix(8)) } ?? ""
        return "问卷「\(cite.name ?? "")」\(cite.day ?? "")#\(task)"
    }

    /// 从记录行出处里的那一项查回原答案（任务、提案、整理记录清掉了也查得到）。后台调
    static func resolve(_ label: String, wiki: WikiStore) -> (source: Source, answer: Answer)? {
        guard label.hasPrefix("问卷「"), let close = label.firstIndex(of: "」"), let hash = label.lastIndex(of: "#") else { return nil }
        let key = String(label[label.index(label.startIndex, offsetBy: 3)..<close])
        let short = String(label[label.index(after: hash)...])
        let dir = wiki.root.appendingPathComponent(folder, isDirectory: true)
        guard short.count == 8, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in names where name.hasPrefix(short) && name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let source = try? decoder.decode(Source.self, from: data),
                  let answer = source.answers.first(where: { $0.key == key }) else { continue }
            return (source, answer)
        }
        return nil
    }

    /// 一条答案给模型看的正文（详情页比现状版本也用这一份拼法）
    static func answerText(_ a: Answer, day: String) -> String {
        "答题日期：\(day)\n问：\(a.question)\n答：\(a.text)"
    }

    /// 原料：这次的答案（带答题日期，必须读，唯一能当出处）+ 楼层 wiki 已有的索引和页（只看；要更新已有页先读它）。后台调
    static func materials(_ answers: [Answer], day: String, memoryRoot: URL, wiki: WikiStore) -> CatalogSeedMaterials {
        var out = CatalogSeedMaterials()
        for a in answers {
            let text = answerText(a, day: day)
            out.items.append(.init(path: a.path, name: a.question, layer: layer, text: text, version: WikiStore.version(of: Data(text.utf8))))
        }
        out.addWiki(wiki, memoryRoot: memoryRoot)
        return out
    }

    /// 答案先存成目标楼层的一份原答案（不随任务清理），再落成一个还没开跑的种子任务（同一个任务 id 只建一次，再来不覆盖）；全空不建。
    /// blocked = 现在跑不了的原因：任务停着，等她照提示恢复后在 C3 页点「继续这个种子任务」。后台调
    static func create(taskId: String, profileId: String, answers: [Answer], wiki: WikiStore, blocked: Blocker?, now: Date) async throws -> Outcome {
        guard !answers.isEmpty else { return .empty }
        let outcome: Outcome = blocked.map { .later($0) } ?? .started
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        if tasks.load(taskId) != nil { return outcome }
        let sourceURL = wiki.root.appendingPathComponent(sourcePath(taskId))
        if !FileManager.default.fileExists(atPath: sourceURL.path) {
            let source = Source(taskId: taskId, profileId: profileId, day: day(now), answeredAt: now, answers: answers)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try WikiStore.writeAtomic(encoder.encode(source), to: sourceURL)
        }
        let run = CatalogRunRecord(wiki: wiki, topic: "种子 · " + CatalogSeedEntry.survey.label, kind: "种子（新用户三问：答案 → 目录 → 逐页写）", now: now)
        run.section("问卷答案（\(day(now)) 答的，只有这几句能当出处；原答案存在 wiki/\(sourcePath(taskId))）",
                    body: answers.map { "- \($0.path) · \($0.question)\n\n" + CatalogRunRecord.code($0.text) }.joined(separator: "\n\n"))
        await run.flush()
        var task = CatalogSeedTask(id: taskId, profileId: profileId, entry: .survey, modelName: "", modelKey: nil, createdAt: now, run: run.link())
        task.answers = answers
        if let blocked {
            task.state = .stopped
            task.note = "还没生成：\(blocked.reason)。\(blocked.fix)"
        }
        try tasks.save(task)
        return outcome
    }
}
