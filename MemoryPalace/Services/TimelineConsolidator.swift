import Foundation
import SwiftData

// MARK: - 楼层日记（M6 时间轴摘要）

struct DailyNote {
    let date: String          // yyyy-MM-dd
    let text: String
    let sourceConversations: Int
    let sourceMessages: Int   // v2a：取材的 user 消息数（0 = v1 旧日记）
    let updatedAt: Date
}

/// 日记文件存取：floors/{slug}/memory/daily/{yyyy-MM-dd}.md（frontmatter 同三店模式）。
/// 人可在文件 app 翻编年史，AI 经 fs_read/grep 可查（memory/ 只读挂载）。
enum DailyFileStore {
    private static func dailyDir(profileId: String) -> URL {
        let dir = FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent("daily", isDirectory: true)
        MainThreadIO.note(.mkdir, "DailyFileStore.dailyDir")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func existingDates(profileId: String) -> Set<String> {
        MainThreadIO.note(.enumerate, "DailyFileStore.existingDates")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dailyDir(profileId: profileId).path)) ?? []
        return Set(names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
    }

    static func load(date: String, profileId: String) -> DailyNote? {
        let url = dailyDir(profileId: profileId).appendingPathComponent("\(date).md")
        MainThreadIO.note(.read, "DailyFileStore.load")
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let (meta, body) = FrontmatterCodec.parse(raw) else { return nil }
        return DailyNote(
            date: meta["date"] ?? date,
            text: body,
            sourceConversations: meta["sourceConversations"].flatMap { Int($0) } ?? 0,
            sourceMessages: meta["sourceMessages"].flatMap { Int($0) } ?? 0,
            updatedAt: meta["updatedAt"].flatMap { FrontmatterCodec.dateFormatter.date(from: $0) } ?? .distantPast
        )
    }

    /// 最新一篇（注入用）。yyyy-MM-dd 字典序 = 时间序。
    static func latest(profileId: String) -> DailyNote? {
        existingDates(profileId: profileId).max().flatMap { load(date: $0, profileId: profileId) }
    }

    static func save(_ note: DailyNote, profileId: String) {
        let url = dailyDir(profileId: profileId).appendingPathComponent("\(note.date).md")
        let content = FrontmatterCodec.render(meta: [
            ("date", note.date),
            ("sourceConversations", String(note.sourceConversations)),
            ("sourceMessages", String(note.sourceMessages)),
            ("updatedAt", FrontmatterCodec.dateFormatter.string(from: note.updatedAt)),
        ], body: note.text)
        do { try Data(content.utf8).write(to: url, options: .atomic) }
        catch { CacheDiagLog.shared.log("📅 日记: ❌ 写盘失败 — \(error.localizedDescription)") }
    }
}

/// 日记员：把"某天这个楼层聊了什么"凝成一篇日记。骨架同 DreamConsolidator（M5）。
/// 结算昨天不结今天；每次最多结一个未结日；防回声：只读对话摘要+标题，不读记忆库/画像。
enum TimelineConsolidator {

    /// 「跨窗口时间轴」开关（第三刀起管新时间轴；key 沿用，默认改开）。旧的按天日记停写，这个类只剩读旧日记和补写
    static var enabled: Bool {
        MemoryFlags.masterEnabled && ((UserDefaults.standard.object(forKey: "mem_content_timeline") as? Bool) ?? true)
    }

    /// 注入文本（开关开 + 有日记才注；最新一篇，天级稳定 → 缓存前缀友好）
    static func injectionText(profileId: String) -> String? {
        guard enabled, let note = DailyFileStore.latest(profileId: profileId) else { return nil }
        return "[时间轴·\(note.date)]\n\(note.text)"
    }

    /// 纯函数（可测）：candidates 按"最近优先"排（昨天→7天前，不含今天），
    /// 返回第一个「当天有活动且还没写过日记」的日期。nil = 没有待结算。
    static func pendingDay(candidates: [String], existing: Set<String>, active: Set<String>) -> String? {
        candidates.first { active.contains($0) && !existing.contains($0) }
    }

    static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    struct DiaryMaterials {
        let day: String
        let titles: [String]
        let summaries: [(title: String, body: String)]
        let userLines: [String]   // v2a 主料：当日 user 原话时间序（HH:mm ［标题］ 截120字）+ ✦moment 行
        let sampled: Bool         // 超 6000 字帽被抽稀过（材料里如实注明）
        let momentCount: Int      // v2b：从当日思考链收割的 ✦moment 数（心声/时刻标记行）
    }

    /// 取材（主线程，返回纯值供 Task.detached 用）。
    /// 自动路径：最近的未结活跃日；forceYesterday=手动补写（昨天，允许重写已有日记）。
    /// 已知近似：按 Conversation.updateTime 归日——连续多日聊同一对话时只算最后一天（复盘记录，v2 用 MessageNode 区间精确）。
    static func pendingMaterials(profileId: String, context: ModelContext, forceYesterday: Bool = false) -> DiaryMaterials? {
        let cal = Calendar.current
        let df = dayFormatter
        let candidates: [String] = (1...7).compactMap { cal.date(byAdding: .day, value: -$0, to: Date()).map(df.string(from:)) }
        guard let weekAgo = cal.date(byAdding: .day, value: -8, to: cal.startOfDay(for: Date())) else { return nil }

        // 近 7 天活跃对话（楼层谓词 + 日期下限，Conversation 表千行级）
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.profileId == profileId && $0.isTrashed == false && $0.updateTime >= weekAgo
        })
        let recent = (try? context.fetch(descriptor)) ?? []
        guard !recent.isEmpty else { return nil }

        let activeDates = Set(recent.map { df.string(from: $0.updateTime) })
        let day: String? = forceYesterday
            ? candidates.first
            : pendingDay(candidates: candidates, existing: DailyFileStore.existingDates(profileId: profileId), active: activeDates)
        guard let day else { return nil }

        let dayConvs = recent.filter { df.string(from: $0.updateTime) == day }
        guard !dayConvs.isEmpty else { return nil }
        let summaries: [(title: String, body: String)] = dayConvs.compactMap { conv in
            ContextSummarizer.load(conversationId: conv.id, profileId: profileId).map { (title: conv.title, body: $0.summary) }
        }

        // v2a 主料：当日 user 原话，跨对话按时间序（日记长在时间流上，不是对话框工件的再聚合）。
        // ⚠️ createTime 是 Date?——SwiftData optional 谓词陷阱（教训在案），按 conversationId 索引取、内存过滤。
        let hhmm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
        var timed: [(t: Date, line: String)] = []
        var momentCount = 0
        for conv in dayConvs {
            let convId = conv.id
            let nd = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> {
                $0.conversationId == convId && $0.profileId == profileId && !$0.isSyntheticRoot && $0.isTrashed == false
            })
            let nodes = (try? context.fetch(nd)) ?? []
            for n in nodes where n.role == "user" && !n.content.isEmpty && !n.isSourceHidden {
                guard let ct = n.createTime, df.string(from: ct) == day else { continue }
                timed.append((ct, "\(hhmm.string(from: ct)) ［\(conv.title)］ \(String(n.content.prefix(120)))"))
            }
            // v2b：收割当日 assistant 思考链里 AI 自发标记的 moment（心声:/✦时刻: 行）。
            // 思考链本就落库（segments/.thinking + ccThinking + <thinking> 文本），结算时回头捡，零实时钩子。
            for n in nodes where n.role == "assistant" && !n.isSourceHidden {
                guard let ct = n.createTime, df.string(from: ct) == day else { continue }
                for line in Self.momentLines(of: n) {
                    momentCount += 1
                    timed.append((ct, "\(hhmm.string(from: ct)) ✦［\(conv.title)］ \(line)"))
                }
            }
        }
        // v2c：当日心声全文进时间线（最高级高光）
        let dayStart = cal.startOfDay(for: df.date(from: day) ?? Date())
        for v in HeartvoiceFileStore.voices(on: day, profileId: profileId) {
            momentCount += 1
            let parts = v.time.split(separator: ":").compactMap { Int($0) }
            let dt = (parts.count == 2 ? cal.date(byAdding: DateComponents(hour: parts[0], minute: parts[1]), to: dayStart) : nil) ?? dayStart
            timed.append((dt, "\(v.time) 💭［心声］ \(String(v.text.prefix(200)))"))
        }
        timed.sort { $0.t < $1.t }
        var userLines = timed.map(\.line)
        // 截断纪律：6000 字帽，超出保首尾 + 均匀抽稀（不静默）
        var sampled = false
        let totalChars = { (ls: [String]) in ls.reduce(0) { $0 + $1.count } }
        if totalChars(userLines) > 6000, userLines.count > 10 {
            sampled = true
            var kept = userLines
            while totalChars(kept) > 6000, kept.count > 10 {
                // 保头 3 尾 3，中段隔一抽一
                let mid = Array(kept[3..<(kept.count - 3)])
                kept = Array(kept.prefix(3)) + mid.enumerated().compactMap { $0.offset % 2 == 0 ? $0.element : nil } + Array(kept.suffix(3))
            }
            userLines = kept
        }
        return DiaryMaterials(day: day, titles: dayConvs.map(\.title), summaries: summaries,
                              userLines: userLines, sampled: sampled, momentCount: momentCount)
    }

    /// v2b：从一条 assistant 消息的全部思考链来源（segments/.thinking + ccThinking + <thinking> 文本）
    /// 解析 AI 自发标记的 moment 行。约定行首：「心声:」「✦时刻:」「时刻:」（中英冒号均可）。
    static func momentLines(of node: MessageNode) -> [String] {
        var thinkingTexts: [String] = []
        if let segs = node.segments {
            for seg in segs { if case .thinking(let t, _) = seg { thinkingTexts.append(t) } }
        }
        if let cc = node.ccThinking, !cc.isEmpty { thinkingTexts.append(cc) }
        let extracted = ContentCleaner.extractThinking(from: node.content)
        if let t = extracted.thinking, !t.isEmpty { thinkingTexts.append(t) }
        // 粟粟预设强制的是 <thinking>…</thinking>（extractThinking 只认方括号），单独捞
        if let re = try? NSRegularExpression(pattern: "<thinking>([\\s\\S]*?)</thinking>", options: [.caseInsensitive]) {
            let ns = node.content as NSString
            for m in re.matches(in: node.content, range: NSRange(location: 0, length: ns.length)) {
                thinkingTexts.append(ns.substring(with: m.range(at: 1)))
            }
        }

        var out: [String] = []
        for text in thinkingTexts {
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
                for prefix in ["心声", "✦时刻", "时刻"] {
                    if line.hasPrefix(prefix + ":") || line.hasPrefix(prefix + "："),
                       case let body = String(line.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces),
                       !body.isEmpty {
                        out.append("\(prefix == "心声" ? "心声" : "时刻")｜\(String(body.prefix(120)))")
                        break
                    }
                }
            }
        }
        return out
    }

    private static let diaryPrompt = """
    你是楼层日记员。根据下面的材料，把「{date} 这一天」写成一篇按时间线展开的简短日记。

    写法纪律：
    - 主料是「当天的时间线」（用户原话按时间排列，带 HH:mm）——按上午/下午/深夜自然分段，写什么时候发生了什么、情绪怎么流动、做了什么决定、什么没做完
    - 带 ✦ 的行是 AI 当场标记的关键时刻——这一天的高光，优先入文
    - 带 💭 的行是 AI 当天自发写下的心声（它自己的内心独白）——日记里给它留一席之地，引用要忠实
    - 「背景参考」是各对话的累计摘要，可能包含早于当天的内容——只用来补充语境，别把旧事写成今天
    - 只基于给出的材料，不脑补；材料太薄就如实写短
    - 控制在 800 字以内。直接输出，不加标题、不加代码块
    """

    /// 结算一天。summaries=当日活跃对话的累计摘要（可空→降级流水账），titles=当日活跃对话标题。
    static func consolidate(
        profileId: String,
        day: String,
        summaries: [(title: String, body: String)],
        titles: [String],
        userLines: [String] = [],
        sampled: Bool = false,
        model: ProviderModel,
        providerManager: ProviderManager
    ) async throws -> DailyNote? {
        guard !titles.isEmpty || !summaries.isEmpty || !userLines.isEmpty else { return nil }
        CacheDiagLog.shared.log("📅 日记: 结算 \(day)（原话+✦ \(userLines.count) 条 / 摘要 \(summaries.count) 份 / 对话 \(titles.count) 个）")

        var user = "日期：\(day)\n\n当天活跃的对话：\n" + titles.map { "- \($0)" }.joined(separator: "\n")
        if !userLines.isEmpty {
            user += "\n\n当天的时间线（用户原话\(sampled ? "，当日较多已抽样" : "")）：\n" + userLines.joined(separator: "\n")
        }
        if !summaries.isEmpty {
            user += "\n\n背景参考（累计摘要，可能含早于当天的内容）：\n"
            for s in summaries {
                user += "\n### \(s.title)\n\(s.body)\n"
            }
        } else if userLines.isEmpty {
            user += "\n\n（材料很薄——按标题写一篇简短的流水账即可）"
        }
        let system = diaryPrompt.replacingOccurrences(of: "{date}", with: day)

        // 预算闸（同 ContextSummarizer / DreamConsolidator）
        if let provider = providerManager.provider(for: model) {
            let inputTok = HeuristicEstimator().estimate(system + user)
            let estimated = BudgetCalculator.actualCost(
                provider: provider, modelId: model.modelId,
                usage: TokenUsage(inputTokens: inputTok, outputTokens: 1024)
            )
            if case .blocked = providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated),
               !BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: estimated) {
                CacheDiagLog.shared.log("📅 日记: 跳过（预算闸）")
                return nil
            }
        }

        let router = ProviderRouter(usageContext: UsageContext(kind: .timeline, profileId: profileId))
        let response: String
        let usage: TokenUsage?
        do {
            (response, usage) = try await router.sendNonStreaming(
                model: model, messages: [(role: "user", content: user)],
                systemPrompt: system, providerManager: providerManager
            )
        } catch {
            CacheDiagLog.shared.log("📅 日记: ❌ 失败 — \(error.localizedDescription)")
            throw error
        }

        if let usage, let provider = providerManager.provider(for: model) {
            let cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
            await MainActor.run { providerManager.commitSpend(providerId: provider.id, amount: cost, usage: usage) }
        }

        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            CacheDiagLog.shared.log("📅 日记: ⚠️ 模型返回空内容")
            return nil
        }
        let note = DailyNote(date: day, text: text, sourceConversations: titles.count, sourceMessages: userLines.count, updatedAt: Date())
        DailyFileStore.save(note, profileId: profileId)
        CacheDiagLog.shared.log("📅 日记: ✅ \(day) → \(text.count) 字")
        return note
    }
}
