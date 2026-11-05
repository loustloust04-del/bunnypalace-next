import Foundation

/// plan-memory-migrate-3gen：记忆三代旧数据搬成 v5 的样子（DEBUG「搬成新样子…」，粟粟手动点，只搬当前这一层）。
/// 第一代老摘要落成 A2 第 0 段；第二代整段在起点以后的老收尾段拿掉、它盖的那截按 v5 补成 A2 正式段（起点以前开始的——
/// 含跨起点的——整段留着，Q4），老式压缩段（带【待续】）起点以后整段重写；每个要搬的窗口写一遍尾段、整个窗口重压成一段 A3。
/// 时间轴不在这里补：c2c3-v2 第 7 段起 A4 一天一条，由 `TimelineDaily` 按日重拼。
/// 一个窗口要么全搬好要么原样：新的 A2 / A3 在内存里写好，全成才提交；提交前落「正在搬」标记
/// （记下要换的每份文件原样），全部提交完才删——中途失败当场按它撤回，被杀了下次点先按它撤回再重搬（astra #2）。
/// 断网 / 被掐断 / 〔停下〕停在当前窗口之前，已提交的留着，再点一次只搬剩下的（Q2）
enum MemoryMigration {
    /// 搬迁备份管的五个文件夹：A2、A3、时间轴、待续本子、第一代老摘要
    static let folders = [SessionSummaryStore.folder, WindowSummaryStore.folder, TimelineStore.folder, PendingStore.folder, SummaryFileStore.folder]
    static let backupPrefix = "v5搬迁-"
    static let resultFileName = "搬迁结果.txt"
    /// 「正在搬」标记放在 记忆备份/ 下面这个文件夹，一个窗口一个
    static let markerFolder = "正在搬"
    /// 估钱：每次输出按上限算（同预算闸口径）
    static let outputTokens = 1500
    /// 格式不对重写一次的余量
    static let retryFactor = 1.15
    /// 估时：每次调用先按 25 秒，跑起来按实测
    static let secondsPerCall: TimeInterval = 25
    /// 还没写出来的段（要新写的正式段 / 尾段）估成这么多字
    static let placeholderChars = 800
    /// 连着几个窗口被拦下 / 出错就停
    static let stopAfter = 3
    /// 一次模型调用最多等多久（10-16：以前没有总上限，一次挂住进度就停在那个窗口不动）；超时 = 这个窗口出错，接着搬下一个。
    /// 10-16 晚：120 秒不够（长窗口一截 60 条、单条到 1500 字，Air 上真超时过），放到 300
    static let callTimeout: TimeInterval = 300
    /// 一个窗口主线上两边加起来不超过这么多条消息 = 太短，跳过不搬（不花钱，粟粟 10-16）
    static let shortWindowMax = 5

    typealias Source = MemoryRegeneration.Source
    typealias Message = SessionSegmentWriter.Message
    typealias Writer = SessionCloseout.Writer
    /// 一个写手的价：(写手, 输入 token, 输出 token) → 美元
    typealias Price = (Writer, Int, Int) -> Double
    /// 提交 / 撤回每一步之前喊一声：(窗口编号, 哪一步)（测试在这里注入写盘失败）
    typealias Fault = (String, String) throws -> Void

    struct Writers {
        let persona: String
        let speakers: SessionSegmentWriter.Speakers
        /// 各写手用自己的模型、记自己的账（M5）；第二个参数 = 窗口编号
        let caller: (Writer, String) -> SessionSegmentWriter.Caller
    }

    /// 备份没做完就点了〔停下〕（10-16）：拷了一半的已删掉，什么都没改
    struct StoppedBeforeBackup: LocalizedError, Equatable {
        var errorDescription: String? { "点了停下，备份没做完（拷了一半的已删掉）" }
    }

    /// 备份用的拷贝（10-16）：一个文件一个文件拷，每个之间看〔停下〕。拷之前 copyFolders 已经查过没有符号链接
    static let cancellableCopy: MemoryRegeneration.FileOp = { from, to in
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        // 排过序：文件夹总在它里面的东西前面
        for rel in try fm.subpathsOfDirectory(atPath: from.path).sorted() {
            try Task.checkCancellation()
            let src = from.appendingPathComponent(rel), dst = to.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: src.path, isDirectory: &isDir)
            if isDir.boolValue {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            } else {
                try fm.copyItem(at: src, to: dst)
            }
        }
    }

    /// 一次模型调用超过 callTimeout 没回完（10-16）：算出错，不算断网
    struct CallTimeout: LocalizedError, Equatable {
        let seconds: TimeInterval
        var errorDescription: String? { "模型 \(String(format: "%g", seconds)) 秒没回完，超时" }
    }

    enum MigrationError: LocalizedError, Equatable {
        case cannotCover(String)
        var errorDescription: String? {
            switch self {
            case .cannotCover(let why): return "上下文摘要补不上（\(why)）"
            }
        }
    }

    // MARK: - M1 分类

    enum Kind: Equatable {
        /// 已经是新样子
        case skip
        /// 只落第 0 段（不花钱）
        case seedOnly
        /// 补尾段 + 重压 A3
        case tailA3
        /// 起点以后有老收尾段：那截补成 A2 正式段，再尾段 + A3
        case a2Incremental
        /// 起点以后有老式压缩段（带【待续】）：起点以后的 A2 整段重写，再尾段 + A3
        case a2Full
        /// 太短（主线不超过 shortWindowMax 条消息）：跳过不搬（10-16）
        case short
    }

    struct Plan: Equatable {
        var kind: Kind

        var needsWork: Bool { kind != .skip && kind != .short }
        var writesA2: Bool { kind == .a2Incremental || kind == .a2Full }
        var writesA3: Bool { writesA2 || kind == .tailA3 }
    }

    /// 一个窗口现在的样子
    struct State {
        /// sessions/；没有就第一代当第 0 段；都没有 = 空的
        var a2: SessionSummary
        var a2OnDisk: Bool
        var a3: SessionSummary?
    }

    /// 纯函数（M1）：nil = 不在范围（起点以前、也不用落第 0 段）。「起点以后」= 整段在起点以后开始；跨起点的老段算老内容留着（Q4，astra #4）
    static func classify(_ st: State, messages: [Message], scope: Date) -> Plan? {
        guard let last = messages.last else { return nil }
        let seedMissing = !st.a2OnDisk && st.a2.segments.contains { $0.kind == .legacy }
        // 10-16：太短的不管在起点前后、有没有起点、缺不缺第 0 段，一律不碰（不落第 0 段）；本来就不在范围的照旧 nil
        let tooShort = messages.count <= shortWindowMax
        guard (last.date ?? .distantPast) >= scope else { return seedMissing ? Plan(kind: tooShort ? .short : .seedOnly) : nil }
        if tooShort { return Plan(kind: .short) }
        let notBefore = MemoryStartDay.firstAllowedIndex(messages.map(\.date), startDay: scope)
        let segs = st.a2.segments
        let kind: Kind
        // 老式段 = 带待续、又没标新写法（format 0）；新写的 A2 段也带待续（第 7 段起由 A4 搬），不算老式、不重写
        if segs.contains(where: { $0.kind == .rolling && !$0.pending.isEmpty && $0.format < SessionSegment.currentFormat && $0.start >= scope }) {
            kind = .a2Full
        } else if segs.contains(where: { $0.kind == .closeout && !$0.isTail && $0.start >= scope }) {
            kind = .a2Incremental
        } else if a3Done(st.a3, lastId: last.id), tailDone(segs, pathIds: messages.map(\.id), notBefore: notBefore) {
            kind = seedMissing ? .seedOnly : .skip
        } else {
            kind = .tailA3
        }
        return Plan(kind: kind)
    }

    /// v5 的 A3：一段、从头压、写到最后一条（v4-1 抄本多段，或最后那段 from > 0）
    static func a3Done(_ a3: SessionSummary?, lastId: String) -> Bool {
        guard let a3, a3.segments.count == 1, a3.segments[0].from == 0 else { return false }
        return a3.closedThrough == lastId
    }

    /// 尾段写到最后一条了，或者正式段已经盖到最后、不用尾段（v4-1 短窗口没有尾段 → 不算）
    static func tailDone(_ segments: [SessionSegment], pathIds: [String], notBefore: Int) -> Bool {
        let formal = segments.filter { $0.kind != .closeout }
        if SessionCloseout.windowTailStart(context: formal, pathIds: pathIds, notBefore: notBefore) >= pathIds.count { return true }
        return segments.last(where: \.isTail)?.lastNodeId == pathIds.last
    }

    // MARK: - M2 A2 要补的

    struct A2Work: Equatable {
        var keep: SessionSummary
        var parts: [Range<Int>]
        /// 非 nil = 补不上（拿掉的老段在这条主线上找不到），这个窗口不搬
        var problem: String?
    }

    /// 纯函数（M2）：A2 留哪些段 + 要补写的那几截（估算和真搬共用）。
    /// - a2Incremental：留第 0 段、合格的压缩段、起点以前开始的老收尾段（Q4）、尾段；拿掉整段在起点以后的老收尾段；
    ///   API 窗口补到锚点（同 `work`），CC 窗口补「写完了的份」，都不套首次补写的 150 条上限
    /// - a2Full：走 `work`，起点以前开始的段都留着
    /// 两种都再按实际覆盖核一遍（astra #3）：拿掉的段盖的、起点以后的那几条，留着的段 + 要补的 + 尾段都没盖到 → 逐个空缺补写
    static func a2Work(_ plan: Plan, a2: SessionSummary, source: Source, scope: Date, now: Date) -> A2Work {
        let ids = source.messages.map(\.id), dates = source.messages.map(\.date)
        let notBefore = MemoryStartDay.firstAllowedIndex(dates, startDay: scope)
        var keep = a2
        var base: [Range<Int>] = []
        switch plan.kind {
        case .a2Full:
            let w = MemoryRegeneration.work(old: a2, source: source, scopeStart: scope, now: now)
            keep = w.keep
            base = w.contextParts
        case .a2Incremental:
            keep.segments = a2.segments.filter { !($0.kind == .closeout && !$0.isTail && $0.start >= scope) }
            if source.isCC {
                base = SessionCloseout.ccCompressRanges(keep, pathIds: ids, dates: dates, notBefore: notBefore, now: now, capFirst: false)
            } else {
                let end = MemoryRegeneration.apiAnchor(old: a2, ids: ids, dates: dates, scopeStart: scope)
                if end > 0 {
                    base = SessionCloseout.pendingRanges(keep, pathIds: ids, dates: dates, end: end, notBefore: notBefore, capFirst: false)
                        .flatMap { SessionCloseout.chunks($0) }
                }
            }
        case .skip, .seedOnly, .tailA3, .short:
            return A2Work(keep: a2, parts: [], problem: nil)
        }
        let removed = a2.segments.filter { !keep.segments.contains($0) }
        guard let gaps = uncovered(removed: removed, keep: keep.segments, parts: base, ids: ids, dates: dates, notBefore: notBefore) else {
            return A2Work(keep: a2, parts: [], problem: "有一段要换下来的老段在这条主线上找不到，可能切过分支")
        }
        let parts = (base + gaps.flatMap { SessionCloseout.chunks($0) }).sorted { $0.lowerBound < $1.lowerBound }
        return A2Work(keep: keep, parts: parts, problem: nil)
    }

    /// 一段在这条主线上实际盖住哪几条：最后一条按 lastNodeId 找、开头按开始时间找；第 0 段 = [0, to)。找不到 = nil
    static func span(_ seg: SessionSegment, ids: [String], dates: [Date?]) -> Range<Int>? {
        if seg.kind == .legacy { return 0..<min(seg.to, ids.count) }
        guard let last = seg.lastNodeId, let i = ids.lastIndex(of: last) else { return nil }
        let start = dates.firstIndex { ($0 ?? .distantPast) >= seg.start } ?? seg.from
        return min(start, i)..<(i + 1)
    }

    /// 纯函数（astra #3）：拿掉的段（尾段不算，它反正整段重写）盖的起点以后那几条里，留着的正式段、要补的、补完以后的尾段
    /// 都没盖到的空缺。nil = 有拿掉的段在主线上找不到（补不上）
    static func uncovered(removed: [SessionSegment], keep: [SessionSegment], parts: [Range<Int>], ids: [String], dates: [Date?],
                          notBefore: Int) -> [Range<Int>]? {
        var covered = IndexSet()
        for s in keep where s.kind != .closeout {
            if let r = span(s, ids: ids, dates: dates) { covered.insert(integersIn: r) }
        }
        for p in parts { covered.insert(integersIn: p) }
        let tailStart = max(covered.last.map { $0 + 1 } ?? 0, notBefore, ids.count - SessionCloseout.firstCloseoutCap)
        if tailStart < ids.count { covered.insert(integersIn: tailStart..<ids.count) }
        var need = IndexSet()
        for s in removed where !s.isTail {
            guard let r = span(s, ids: ids, dates: dates) else { return nil }
            if max(r.lowerBound, notBefore) < r.upperBound { need.insert(integersIn: max(r.lowerBound, notBefore)..<r.upperBound) }
        }
        need.subtract(covered)
        return need.rangeView.map { $0.lowerBound..<$0.upperBound }
    }

    // MARK: - M8 估算

    struct Call: Equatable {
        let writer: Writer
        /// 喂给模型的 system + user 估多少 token
        let tokens: Int
    }

    /// 纯函数（M8）：不调模型，把每次要喂的东西真拼出来数 token；还没写出来的段按 placeholderChars 字估。
    /// 次数和真搬（假写手、格式都对）一一对应
    static func estimateCalls(_ plan: Plan, state st: State, source src: Source, scope: Date, now: Date,
                              persona: String, speakers: SessionSegmentWriter.Speakers) -> [Call] {
        let est = HeuristicEstimator()
        let messages = src.messages, ids = messages.map(\.id)
        let notBefore = MemoryStartDay.firstAllowedIndex(messages.map(\.date), startDay: scope)
        var calls: [Call] = []
        var s = st.a2
        if plan.writesA2 {
            let w = a2Work(plan, a2: s, source: src, scope: scope, now: now)
            s = w.keep
            if !w.parts.isEmpty { s.segments.removeAll { $0.isTail } }
            let system = SessionSegmentWriter.systemPrompt(persona: persona, speakers: speakers, kind: .rolling)
            for part in w.parts {
                let at = SessionCloseout.insertionIndex(s, chunkStart: messages[part.lowerBound].date)
                let user = SessionSegmentWriter.userContent(messages: Array(messages[part]), speakers: speakers,
                                                            previous: s.segments[..<at].last { $0.kind != .closeout }, kind: .rolling)
                calls.append(Call(writer: .context, tokens: est.estimate(system + user)))
                s.segments.insert(placeholder(.rolling, messages, part), at: at)
            }
        }
        if plan.writesA3, !messages.isEmpty {
            // 尾段：同 writeTail 的判断
            let formal = s.segments.filter { $0.kind != .closeout }
            let start = SessionCloseout.windowTailStart(context: formal, pathIds: ids, notBefore: notBefore)
            let noop = s.segments.last(where: \.isTail).map {
                ($0.from == start && $0.lastNodeId == ids.last)
                    || SessionCloseout.wouldRegress(mark: $0.lastNodeId, markDate: $0.end, snapshot: messages)
            } ?? false
            if start < messages.count, !noop {
                let system = SessionSegmentWriter.systemPrompt(persona: persona, speakers: speakers, kind: .closeout)
                let user = SessionSegmentWriter.userContent(messages: Array(messages[start...]), speakers: speakers,
                                                            previous: formal.last, kind: .closeout)
                calls.append(Call(writer: .context, tokens: est.estimate(system + user)))
                var tail = placeholder(.closeout, messages, start..<messages.count)
                tail.isTail = true
                s.segments.removeAll { $0.isTail }
                s.segments.append(tail)
            }
            // A3：同 recompressWindow 的输入
            let segs = s.segments.filter { $0.kind != .closeout || $0.isTail }
            let rawStart = SessionCloseout.windowTailStart(context: segs, pathIds: ids, notBefore: notBefore)
            let raw = rawStart < messages.count ? Array(messages[rawStart...]) : []
            if !segs.isEmpty || !raw.isEmpty {
                let system = WindowSummaryWriter.systemPrompt(persona: persona, speakers: speakers, chars: MemoryWriterSettings.a3Chars)
                let user = WindowSummaryWriter.userContent(title: src.title, segments: segs, rawTail: raw, speakers: speakers)
                calls.append(Call(writer: .window, tokens: est.estimate(system + user)))
            }
        }
        return calls
    }

    /// 还没写出来的段：位置、锚点和真写的一样，正文按 placeholderChars 字占位
    static func placeholder(_ kind: SessionSegment.Kind, _ messages: [Message], _ r: Range<Int>) -> SessionSegment {
        let fill = String(repeating: "记", count: placeholderChars / 2)
        return SessionSegment(kind: kind, title: "（还没写）", start: messages[r.lowerBound].date ?? Date(),
                              end: messages[r.upperBound - 1].date ?? Date(), from: r.lowerBound, to: r.upperBound,
                              lastNodeId: messages[r.upperBound - 1].id, story: fill, quotes: fill, pending: "")
    }

    // MARK: - 先算（不调模型）

    struct WindowPlan: Equatable {
        let id: String
        let title: String
        let plan: Plan
        /// 估的调用次数（不含格式不对的重写）、钱
        let calls: Int
        let cost: Double
    }

    struct Survey: Equatable {
        var scopeStart: Date?
        /// 要动的窗口（按最后一条消息先后，就是搬的顺序）
        var windows: [WindowPlan] = []
        /// 已经是新样子，跳过
        var skipped = 0
        /// 太短跳过（10-16）
        var short = 0
        /// 要搬但搬不了的（文件读不了 / 格式对不上 / 补不上），一个窗口一行，原样留着
        var broken: [String] = []

        var calls: Int { windows.map(\.calls).reduce(0, +) }
        var cost: Double { windows.map(\.cost).reduce(0, +) }
        var paid: [WindowPlan] { windows.filter { $0.calls > 0 } }
        var tailA3: Int { windows.filter { $0.plan.kind == .tailA3 }.count }
        var a2: Int { windows.filter { $0.plan.writesA2 }.count }
        var seedOnly: Int { windows.filter { $0.plan.kind == .seedOnly }.count }
        /// 给她看的：格式不对重写的余量算进去
        var displayCalls: Int { Int((Double(calls) * MemoryMigration.retryFactor).rounded(.up)) }
        var displayCost: Double { cost * MemoryMigration.retryFactor }
        var seconds: TimeInterval { Double(displayCalls) * MemoryMigration.secondsPerCall }
        var priciest: [WindowPlan] { Array(paid.sorted { $0.cost > $1.cost }.prefix(3)) }
    }

    /// 一个窗口现在的样子（严格读盘，astra #9：读不了 / 格式对不上就抛，不当「没有」）。
    /// 有「正在搬」标记的（上次提交到一半）按撤回以后的样子算（astra #2）
    static func state(_ id: String, root: URL) throws -> State {
        var onDisk = try SessionSummaryStore.loadStrict(conversationId: id, in: SessionSummaryStore.dir(root: root))
        var a3 = try WindowSummaryStore.loadStrict(conversationId: id, in: root)
        if let m = try loadMarker(id, memoryRoot: root) {
            if m.a2Touched { onDisk = try m.a2.flatMap { try SessionSummaryStore.parseStrict($0.text, path: $0.name) } }
            if m.a3Touched { a3 = try m.a3.flatMap { try SessionSummaryStore.parseStrict($0.text, path: $0.name) } }
        }
        let seed = onDisk == nil
            ? try SummaryFileStore.loadStrict(conversationId: id, memoryRoot: root).flatMap { SessionSummaryStore.legacySeed(from: $0, conversationId: id) }
            : nil
        let a2 = onDisk ?? seed ?? SessionSummary(conversationId: id, title: "", compressedCount: 0, segments: [], updatedAt: .distantPast)
        return State(a2: a2, a2OnDisk: onDisk != nil, a3: a3)
    }

    /// 要搬但不能搬的理由（A2 补不上）；nil = 能搬
    static func blocker(_ plan: Plan, state st: State, source src: Source, scope: Date, now: Date) -> MigrationError? {
        if plan.writesA2, let p = a2Work(plan, a2: st.a2, source: src, scope: scope, now: now).problem { return .cannotCover(p) }
        return nil
    }

    static func displayName(_ title: String, _ id: String) -> String {
        "《\(title.isEmpty ? String(id.prefix(8)) : title)》"
    }

    /// 先算：哪些窗口要搬、各是哪种、大概几次调用多少钱（不调模型）。
    /// candidates(起点) = 起点以后动过、开着记忆参与、没进回收站的窗口（真实接线从库里查）；再加上只有第一代老摘要的（Q3）、
    /// 有「正在搬」标记的。source 返回 nil = 窗口删了 / 关了记忆参与，不搬
    static func survey(profileId: String, startDay: Date?, now: Date, persona: String, speakers: SessionSegmentWriter.Speakers,
                       price: Price, candidates: (Date?) -> [String], source: (String) -> Source?, memoryRoot: URL? = nil) -> Survey {
        let root = memoryRoot ?? FileLibraryStore.memoryRoot(profileId: profileId)
        let scope = MemoryRegeneration.scopeStart(startDay: startDay, memoryRoot: root)
        var out = Survey(scopeStart: scope)
        let onDisk = Set(SessionSummaryStore.all(in: SessionSummaryStore.dir(root: root)).map(\.conversationId))
        let seedOnly = SummaryFileStore.conversationIds(in: root).filter { !onDisk.contains($0) }
        var listed: [(plan: WindowPlan, last: Date)] = []
        for id in Set(candidates(scope)).union(seedOnly).union(markerIds(memoryRoot: root)) {
            // 10-16：搬迁时点了〔停下〕，清点到这儿就不往下数（run 接着收尾）
            if Task.isCancelled { break }
            guard let src = source(id) else { continue }
            do {
                let st = try state(id, root: root)
                // 没有起点（「记忆从哪天开始」没设、也没有第三刀以后写的段）：只落第 0 段
                guard let plan = classify(st, messages: src.messages, scope: scope ?? .distantFuture) else { continue }
                guard plan.needsWork else {
                    if plan.kind == .short { out.short += 1 } else { out.skipped += 1 }
                    continue
                }
                let calls = try scope.map { (scope: Date) throws -> [Call] in
                    if let b = blocker(plan, state: st, source: src, scope: scope, now: now) { throw b }
                    return estimateCalls(plan, state: st, source: src, scope: scope, now: now, persona: persona, speakers: speakers)
                } ?? []
                let cost = calls.map { price($0.writer, $0.tokens, outputTokens) }.reduce(0, +)
                listed.append((WindowPlan(id: id, title: src.title, plan: plan, calls: calls.count, cost: cost),
                               src.messages.last?.date ?? .distantPast))
            } catch {
                out.broken.append("\(displayName(src.title, id))\(error.localizedDescription)，这个窗口不搬、原样留着")
            }
        }
        out.windows = listed.sorted { ($0.last, $0.plan.id) < ($1.last, $1.plan.id) }.map(\.plan)
        return out
    }

    // MARK: - M5–M7 搬

    enum Step: Int {
        case seed = 1, context, tail, window, commit

        var name: String {
            switch self {
            case .seed: return "第 0 段"
            case .context: return "上下文摘要"
            case .tail: return "尾段"
            case .window: return "窗口总结"
            case .commit: return "提交"
            }
        }
    }

    /// 一个窗口没搬成（还什么都没换）：哪一步；error = nil 是写手跳过（预算闸 / 模型没回内容）
    struct StepFailure: Error {
        let step: Step
        let error: Error?
    }

    /// 提交写盘半路失败：当场按标记撤回了（rollbackError = nil），或者撤回也没做完（标记留着，下次点先按它撤回）
    struct CommitFailure: Error {
        let error: Error
        let rollbackError: Error?
        let marker: URL

        func text(_ name: String) -> String {
            let head = "\(name)第 \(Step.commit.rawValue) 步 \(Step.commit.name)：写盘失败（\(error.localizedDescription)），"
            guard let r = rollbackError else { return head + "已经撤回，这个窗口原样留着" }
            return head + "撤回也没做完（\(r.localizedDescription)）：半成品记在 \(marker.path)，下次点「搬成新样子」会先按它撤回"
        }
    }

    /// 给一次调用套总上限（10-16）：两个子任务赛跑，先完的算，输的那个被取消。真实写手底下是 URLSession 的 async data(for:)，
    /// 取消就断请求，不是挂在 continuation 上等回调，group 收尾不会被它卡住
    static func timed(_ caller: @escaping SessionSegmentWriter.Caller, seconds: TimeInterval) -> SessionSegmentWriter.Caller {
        { system, user in
            try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { try await caller(system, user) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw CallTimeout(seconds: seconds)
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        }
    }

    /// 进度行上「这一步」的字（10-16）：分段循环报真实段号；同一步第二次调用 = 格式不对重写
    final class StepLabel {
        private(set) var text: String
        var calls = 0

        init(_ text: String = "") { self.text = text }

        func set(_ t: String) {
            text = t
            calls = 0
        }
    }

    /// 调模型返回 nil 记一笔（分得清「没东西要写」和「写手跳过」），顺手数调了几次；每次调用前后都看〔停下〕（astra #12）
    final class Probe {
        var skipped = false
        var calls = 0

        func watch(_ caller: @escaping SessionSegmentWriter.Caller) -> SessionSegmentWriter.Caller {
            { [self] system, user in
                try Task.checkCancellation()
                calls += 1
                let raw = try await caller(system, user)
                try Task.checkCancellation()
                if raw == nil { skipped = true }
                return raw
            }
        }
    }

    /// 一个窗口要提交的：nil = 这样不换
    struct Commit {
        var a2: SessionSummary?
        var a3: SessionSummary?

        var isEmpty: Bool { a2 == nil && a3 == nil }
    }

    /// 搬一个窗口（M6）：① 第 0 段落位 → ② A2 补正式段 → ③ 尾段 → ④ A3 重压。新的 A2 / A3 在内存里写好，全成才提交（`commitWindow`）。提交以前哪一步没成抛 `StepFailure`，这个窗口一个字不改；
    /// 提交半路失败抛 `CommitFailure`。counter 只数调用次数（估「还要多久」）。
    /// 10-16：每次调用套 callTimeout 总上限；每次调用前用 step 报一声在写什么（「写 A2 第 2 / 5 段」「压 A3」，格式不对重写那次带「（重试）」）
    static func migrateWindow(id: String, source src: Source, state st: State, plan: Plan, scope: Date, now: Date,
                              profileId: String, writers: Writers, counter: Probe, callTimeout: TimeInterval = MemoryMigration.callTimeout,
                              step report: @escaping (String) -> Void = { _ in }, fault: Fault = { _, _ in },
                              memoryRoot: URL? = nil) async throws {
        let root = memoryRoot ?? FileLibraryStore.memoryRoot(profileId: profileId)
        let messages = src.messages
        let notBefore = MemoryStartDay.firstAllowedIndex(messages.map(\.date), startDay: scope)
        func caller(_ w: Writer, _ probe: Probe, _ label: StepLabel) -> SessionSegmentWriter.Caller {
            let watched = probe.watch(counter.watch(timed(writers.caller(w, id), seconds: callTimeout)))
            return { system, user in
                report(label.calls > 0 ? label.text + "（重试）" : label.text)
                label.calls += 1
                return try await watched(system, user)
            }
        }
        var step = Step.seed
        let commit: Commit
        do {
            var s = st.a2
            s.title = src.title
            if plan.writesA2 {
                step = .context
                let probe = Probe()
                let w = a2Work(plan, a2: s, source: src, scope: scope, now: now)
                if let p = w.problem { throw StepFailure(step: .context, error: MigrationError.cannotCover(p)) }
                s = w.keep
                s.title = src.title
                let label = StepLabel()
                let done = try await SessionCloseout.writeContextParts(w.parts, messages: messages, into: &s, title: src.title,
                                                                       persona: writers.persona, speakers: writers.speakers,
                                                                       caller: caller(.context, probe, label), save: { _ in },
                                                                       onPart: { label.set("写 A2 第 \($0) / \($1) 段") })
                if !done || probe.skipped { throw StepFailure(step: .context, error: nil) }
            }
            var a3: SessionSummary?
            if plan.writesA3 {
                step = .tail
                let tailProbe = Probe(), windowProbe = Probe()
                do {
                    let r = try await SessionCloseout.composeWindowSummary(
                        context: s, messages: messages, title: src.title, notBefore: notBefore, persona: writers.persona,
                        speakers: writers.speakers, tailCaller: caller(.context, tailProbe, StepLabel("写 A2 尾段")),
                        windowCaller: caller(.window, windowProbe, StepLabel("压 A3")))
                    if tailProbe.skipped { throw StepFailure(step: .tail, error: nil) }
                    if windowProbe.skipped { throw StepFailure(step: .window, error: nil) }
                    if let r {
                        s = r.context
                        a3 = r.window
                    }
                } catch let error where !(error is StepFailure) {
                    throw StepFailure(step: windowProbe.calls > 0 ? .window : .tail, error: error)
                }
            }
            // 〔停下〕：模型都调完了，提交以前再看一眼；进了提交就不看了，靠标记保证要么做完要么撤回（astra #12）
            try Task.checkCancellation()
            let a2Changed = (st.a2OnDisk || !s.segments.isEmpty) && (s != st.a2 || !st.a2OnDisk)
            commit = Commit(a2: a2Changed ? s : nil, a3: a3)
        } catch let f as StepFailure {
            throw f
        } catch {
            throw StepFailure(step: step, error: error)
        }
        try commitWindow(commit, id: id, root: root, profileId: profileId, rootInjected: memoryRoot != nil, fault: fault)
    }

    // MARK: - 「正在搬」标记（astra #2 #8）

    /// 提交前落下，记着这个窗口要换的每样原来什么样；全部提交完删掉。下次点「搬成新样子」看到它 = 上次提交到一半，先按它撤回
    struct Marker: Codable, Equatable {
        struct File: Codable, Equatable {
            var name: String
            var text: String
        }
        struct Pending: Codable, Equatable {
            var id: String
            var text: String
        }
        var conversationId: String
        var a2Touched = false
        /// 原来的 sessions/ 文件（nil = 原来没有）
        var a2: File?
        var a3Touched = false
        var a3: File?
        /// 月份 → 这个窗口在那个月原来的条目（月文件格式，只有这个窗口的）
        var months: [String: String] = [:]
        /// 真加进待续本子的（提交那一刻、写盘之前记下）
        var addedPending: [Pending] = []
    }

    static func markerDir(memoryRoot: URL) -> URL {
        MemoryRegeneration.backupRoot(memoryRoot: memoryRoot).appendingPathComponent(markerFolder, isDirectory: true)
    }

    static func markerURL(_ id: String, memoryRoot: URL) -> URL {
        markerDir(memoryRoot: memoryRoot).appendingPathComponent("\(id).json")
    }

    static func markerIds(memoryRoot: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: markerDir(memoryRoot: memoryRoot).path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func loadMarker(_ id: String, memoryRoot: URL) throws -> Marker? {
        let url = markerURL(id, memoryRoot: memoryRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(Marker.self, from: Data(contentsOf: url)) } catch { throw MemoryReadError.corrupt(url.path) }
    }

    static func saveMarker(_ m: Marker, memoryRoot: URL) throws {
        try FileManager.default.createDirectory(at: markerDir(memoryRoot: memoryRoot), withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: markerURL(m.conversationId, memoryRoot: memoryRoot), options: .atomic)
    }

    /// 恢复了备份：标记记的「原来」不作数了
    static func clearMarkers(memoryRoot: URL) {
        try? FileManager.default.removeItem(at: markerDir(memoryRoot: memoryRoot))
    }

    /// 提交：先落标记，再按 sessions → windows 提交，全成删标记。
    /// 落标记以前失败 = 什么都没换（`StepFailure`）；之后失败当场撤回（`CommitFailure`）
    static func commitWindow(_ c: Commit, id: String, root: URL, profileId: String, rootInjected: Bool = false, fault: Fault) throws {
        guard !c.isEmpty else { return }
        let sessions = SessionSummaryStore.dir(root: root)
        var marker = Marker(conversationId: id)
        do {
            if c.a2 != nil {
                marker.a2Touched = true
                marker.a2 = try original(id, in: sessions)
            }
            if c.a3 != nil {
                marker.a3Touched = true
                marker.a3 = try original(id, in: WindowSummaryStore.dir(root: root))
            }
            try saveMarker(marker, memoryRoot: root)
        } catch {
            throw StepFailure(step: .commit, error: error)
        }
        do {
            if let a2 = c.a2 {
                try fault(id, "sessions")
                // 先保全、后覆盖（同日常存段）：旧的 / 重写好的 A2 里的待续先进本子或待补
                try TimelineDaily.preserveBeforeSave(a2, profileId: profileId, memoryRoot: rootInjected ? root : nil, sessionsDir: sessions)
                try SessionSummaryStore.save(a2, in: sessions)
            }
            if let a3 = c.a3 {
                try fault(id, "windows")
                try WindowSummaryStore.save(a3, in: root)
            }
            try fault(id, "完成")
        } catch {
            var rollbackError: Error?
            do { try rollback(marker, memoryRoot: root, profileId: profileId, rootInjected: rootInjected, fault: fault) } catch let e {
                rollbackError = e
            }
            throw CommitFailure(error: error, rollbackError: rollbackError, marker: markerURL(id, memoryRoot: root))
        }
        try? FileManager.default.removeItem(at: markerURL(id, memoryRoot: root))
    }

    /// 这个窗口在这个文件夹里原来那份（严格读；没有 = nil）
    private static func original(_ id: String, in dir: URL) throws -> Marker.File? {
        guard let url = try MemoryReadError.existingFile(prefix: String(id.prefix(8)) + "-", in: dir) else { return nil }
        return Marker.File(name: url.lastPathComponent, text: try MemoryReadError.read(url))
    }

    /// 按标记撤回（可以重复做）：待续删掉这次真加进去的（编号 + 窗口 + 原文都对上才删）、时间轴这几个月换回这个窗口原来的条目、
    /// A3 / A2 换回原来那份；都成了删标记。哪一步失败就抛，标记留着
    static func rollback(_ m: Marker, memoryRoot root: URL, profileId: String, rootInjected: Bool = false,
                         fault: Fault = { _, _ in }) throws {
        try fault(m.conversationId, "撤回")
        let id = m.conversationId
        if !m.addedPending.isEmpty {
            try PendingStore.checkReadable(profileId: profileId, memoryRoot: rootInjected ? root : nil)
            try PendingStore.mutate(profileId: profileId, memoryRoot: rootInjected ? root : nil) { items in
                items.removeAll { i in i.conversationId == id && m.addedPending.contains { $0.id == i.id && $0.text == i.text } }
            }
        }
        let live = TimelineStore.dir(root: root)
        for (month, text) in m.months.sorted(by: { $0.key < $1.key }) {
            let orig = TimelineStore.parse(text)
            try TimelineStore.mutateStrict(month: month, in: live) { $0.filter { $0.conversationId != id } + orig }
        }
        if m.a3Touched { try putOriginal(m.a3, id, in: WindowSummaryStore.dir(root: root)) }
        if m.a2Touched { try putOriginal(m.a2, id, in: SessionSummaryStore.dir(root: root)) }
        let url = markerURL(id, memoryRoot: root)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func putOriginal(_ file: Marker.File?, _ id: String, in dir: URL) throws {
        let fm = FileManager.default
        let current = try MemoryReadError.existingFile(prefix: String(id.prefix(8)) + "-", in: dir)
        guard let file else {
            if let current { try fm.removeItem(at: current) }
            return
        }
        let target = dir.appendingPathComponent(file.name)
        if let current, current.lastPathComponent != file.name { try fm.removeItem(at: current) }
        if (try? String(contentsOf: target, encoding: .utf8)) != file.text {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(file.text.utf8).write(to: target, options: .atomic)
        }
    }

    // MARK: - 跑

    struct Progress: Equatable {
        /// 第几个（从 1 起）/ 一共几个
        var index: Int
        var total: Int
        var title: String
        var spent: Double
        var remaining: TimeInterval
        /// 这个窗口正在做哪一步（「压 A3」），空 = 刚开始（10-16）
        var step = ""
    }

    struct Report: Equatable {
        var backup: URL
        var done = 0
        var skipped = 0
        /// 太短跳过（10-16）
        var short = 0
        var spent: Double = 0
        /// 没成的，一个窗口一行
        var failures: [String] = []
        /// 中途停下的原因（nil = 跑完了）
        var stopped: String?
    }

    /// 备份 → 撤回上次提交到一半的 → 先算 → 一个窗口一个窗口搬（按顺序，不并发）→ 结果写进备份文件夹。
    /// 备份核不上 / 有符号链接就抛错、什么都不改。不看写入预算（真实接线的 caller 不查），全局预算闸照查：连着 3 个窗口写手跳过就停（M5）。
    /// 断网 / 被掐断 / 〔停下〕：停在当前窗口之前，已提交的留着（M7）。一次调用超过 callTimeout 算这个窗口出错（10-16）
    /// 10-16 astra #2：备份逐个文件、撤回逐个窗口、清点逐个窗口之间都看〔停下〕；备份没做完就停 = 抛 `StoppedBeforeBackup`
    /// （拷了一半的删掉），之后停 = 结果里如实写做到哪一步。
    /// memoryRoot（10-16 手搬演练）：非空 = 整趟都在这个根上搬（备份 / 正在搬标记在它旁边的「记忆备份」，待续本子读写它下面那份、
    /// 不碰这一层的缓存和偏好）；nil = 这一层的真根
    static func run(profileId: String, startDay: Date?, now: Date, writers: Writers, price: Price,
                    candidates: (Date?) -> [String], source: (String) -> Source?,
                    copy: MemoryRegeneration.FileOp = MemoryMigration.cancellableCopy, fault: Fault = { _, _ in },
                    callTimeout: TimeInterval = MemoryMigration.callTimeout, memoryRoot: URL? = nil,
                    progress: @escaping (Progress) -> Void = { _ in }) async throws -> Report {
        let root = memoryRoot ?? FileLibraryStore.memoryRoot(profileId: profileId)
        let injected = memoryRoot != nil
        if Task.isCancelled { throw StoppedBeforeBackup() }
        let backup: URL
        do {
            backup = try MemoryRegeneration.makeBackup(memoryRoot: root, name: backupPrefix + MemoryRegeneration.stamp(now),
                                                       folders: folders, copy: copy)
        } catch is CancellationError {
            throw StoppedBeforeBackup()
        }
        var report = Report(backup: backup)
        /// 还没开始搬就停下：结果照样写进备份文件夹
        func stopBeforeMigrating(_ why: String) -> Report {
            report.stopped = why
            try? Data(resultText(report).utf8).write(to: backup.appendingPathComponent(resultFileName), options: .atomic)
            return report
        }
        // 上次提交到一半被杀的：先按标记撤回，再当普通窗口重搬；撤不回的这次不搬
        var blocked: Set<String> = []
        let marked = markerIds(memoryRoot: root)
        for (k, id) in marked.enumerated() {
            // 已经开始的那个撤回做完再停（撤回本身可以重做，标记留着下次点接着撤）
            if Task.isCancelled {
                return stopBeforeMigrating("点了停下：备份做完了，上次搬到一半的还有 \(marked.count - k) 个没撤回（下次点会先撤回），还没开始搬")
            }
            do {
                if let m = try loadMarker(id, memoryRoot: root) {
                    try rollback(m, memoryRoot: root, profileId: profileId, rootInjected: injected, fault: fault)
                }
            } catch {
                blocked.insert(id)
                report.failures.append("《\(id.prefix(8))》上次搬到一半的半成品没撤回（\(error.localizedDescription)），"
                                       + "标记在 \(markerURL(id, memoryRoot: root).path)，这个窗口这次不搬")
            }
        }
        let plan = survey(profileId: profileId, startDay: startDay, now: now, persona: writers.persona, speakers: writers.speakers,
                          price: price, candidates: candidates, source: source, memoryRoot: memoryRoot)
        if Task.isCancelled { return stopBeforeMigrating("点了停下：备份做完了，还没开始搬") }
        report.skipped = plan.skipped
        report.short = plan.short
        report.failures += plan.broken
        let meter = MemoryWriteLog.CostMeter()
        let counter = Probe()
        let started = Date()
        var skipsInARow = 0, errorsInARow = 0
        await MemoryWriteLog.$meter.withValue(meter) {
            for (i, w) in plan.windows.enumerated() where !blocked.contains(w.id) {
                let name = displayName(w.title, w.id)
                if Task.isCancelled {
                    report.stopped = stopText(at: i + 1, name: name, cancelled: true)
                    break
                }
                let left = plan.windows[i...].map(\.calls).reduce(0, +), callsBefore = counter.calls
                // 10-16：每次调用前都报一声（进度行看得出没卡死），已花 / 还要多久跟着更新
                func emit(_ step: String) {
                    let perCall = counter.calls > 0 ? Date().timeIntervalSince(started) / Double(counter.calls) : secondsPerCall
                    progress(Progress(index: i + 1, total: plan.windows.count, title: w.title, spent: meter.usd ?? 0,
                                      remaining: Double(max(left - (counter.calls - callsBefore), 0)) * perCall, step: step))
                }
                emit("")
                // 没有起点：只落第 0 段（同 survey）
                let scope = plan.scopeStart ?? .distantFuture
                guard let src = source(w.id) else {
                    report.skipped += 1
                    continue
                }
                // 先算以后又变了（比如上一次搬到一半）：按现在的样子重新分
                let prepared: (State, Plan)?
                do {
                    let st = try state(w.id, root: root)
                    prepared = classify(st, messages: src.messages, scope: scope).flatMap { $0.needsWork ? (st, $0) : nil }
                    if let p = prepared?.1, plan.scopeStart != nil,
                       let b = blocker(p, state: st, source: src, scope: scope, now: now) { throw b }
                } catch {
                    // 读不了 / 补不上：这个窗口原样留着；不算「连着」
                    report.failures.append("\(name)\(error.localizedDescription)，这个窗口不搬、原样留着")
                    skipsInARow = 0
                    errorsInARow = 0
                    continue
                }
                guard let prep = prepared else {
                    report.skipped += 1
                    continue
                }
                let (st, p) = prep
                do {
                    try await migrateWindow(id: w.id, source: src, state: st, plan: p, scope: scope, now: now, profileId: profileId,
                                            writers: writers, counter: counter, callTimeout: callTimeout,
                                            step: emit, fault: fault, memoryRoot: memoryRoot)
                    report.done += 1
                    skipsInARow = 0
                    errorsInARow = 0
                } catch let f as StepFailure {
                    if let e = f.error, SessionCloseout.isTransient(e) {
                        report.stopped = stopText(at: i + 1, name: name, cancelled: Task.isCancelled || e is CancellationError)
                        break
                    }
                    let head = "\(name)第 \(f.step.rawValue) 步 \(f.step.name)："
                    // 连着 = 同一类一个接一个（astra #14）：换了类别清另一个计数；格式不对、补不上打断「连着」
                    switch f.error {
                    case nil:
                        skipsInARow += 1
                        errorsInARow = 0
                        report.failures.append(head + "被预算闸拦下或模型没回内容，这个窗口原样留着")
                    case MemoryWriterError.format(let p)?:
                        skipsInARow = 0
                        errorsInARow = 0
                        report.failures.append(head + "格式不对（\(p)），这个窗口原样留着")
                    case let e? where e is MigrationError:
                        skipsInARow = 0
                        errorsInARow = 0
                        report.failures.append(head + "\(e.localizedDescription)，这个窗口原样留着")
                    case let e?:
                        errorsInARow += 1
                        skipsInARow = 0
                        report.failures.append(head + "出错（\(e.localizedDescription)），这个窗口原样留着")
                    }
                } catch let c as CommitFailure {
                    errorsInARow += 1
                    skipsInARow = 0
                    report.failures.append(c.text(name))
                } catch {
                    errorsInARow += 1
                    skipsInARow = 0
                    report.failures.append("\(name)出错（\(error.localizedDescription)），这个窗口原样留着")
                }
                if skipsInARow >= stopAfter {
                    report.stopped = "连着 \(stopAfter) 个窗口被预算闸拦下或模型没回内容，停在第 \(i + 1) 个。看看预算和模型，再点一次接着搬"
                    break
                }
                if errorsInARow >= stopAfter {
                    report.stopped = "连着 \(stopAfter) 个窗口出错，停在第 \(i + 1) 个。看看模型和网络，再点一次接着搬"
                    break
                }
            }
        }
        report.spent = meter.usd ?? 0
        try? Data(resultText(report).utf8).write(to: backup.appendingPathComponent(resultFileName), options: .atomic)
        return report
    }

    static func stopText(at index: Int, name: String, cancelled: Bool) -> String {
        "停在第 \(index) 个\(name)：\(cancelled ? "点了停下" : "断网或被掐断")。搬好的留着、这个没动，再点一次接着搬"
    }

    // MARK: - 给她看的字（U2–U4）

    static func money(_ usd: Double) -> String { String(format: "$%.2f", usd) }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时\(minutes % 60 == 0 ? "" : " \(minutes % 60) 分")"
    }

    /// 确认框（第三节）：楼层名、分类计数、次数 / 钱 / 时间、最贵三个、搬不了的、单项关着的提醒、备份位置
    static func confirmText(_ s: Survey, floor: String, models: [Writer: String], off: [MemoryWriterID], backupFolder: String) -> String {
        var lines: [String] = []
        if let scope = s.scopeStart {
            var head = "这一层「\(floor)」：从 \(MemoryStartDay.format(scope)) 起 \(s.paid.count) 个窗口要搬——"
            head += "\(s.tailA3) 个只要补尾段和重压窗口总结，\(s.a2) 个要补写上下文摘要"
            if s.seedOnly > 0 { head += "；另有 \(s.seedOnly) 个只有老摘要的窗口，落成第 0 段（不花钱）" }
            if s.short > 0 { head += "；\(s.short) 个太短（不超过 \(shortWindowMax) 条消息），跳过不搬" }
            lines.append(head + "；\(s.skipped) 个已经是新样子，跳过。")
        } else {
            lines.append("这一层「\(floor)」没找到起点（「记忆从哪天开始」没设、也没有改版后写的段）：只把 \(s.seedOnly) 个只有老摘要的窗口落成第 0 段（不花钱）"
                         + (s.short > 0 ? "；\(s.short) 个太短（不超过 \(shortWindowMax) 条消息），跳过不搬。" : "。"))
        }
        if s.calls > 0 {
            let priced = "上下文摘要用「\(models[.context] ?? "")」、窗口总结用「\(models[.window] ?? "")」"
            var cost = "大概 \(s.displayCalls) 次模型调用，约 \(money(s.displayCost))（\(priced)的价），约 \(duration(s.seconds))。"
            if !s.priciest.isEmpty { cost += "最贵的\(s.priciest.count == 3 ? "三" : "几")个：" + s.priciest.map { "《\($0.title)》" }.joined() + "。" }
            lines.append(cost)
        }
        if !s.broken.isEmpty {
            lines.append("另有 \(s.broken.count) 个窗口搬不了（文件读不了 / 格式对不上 / 补不上），原样留着，结果里逐条写。")
        }
        if !off.isEmpty {
            lines.append(off.map(\.code).joined(separator: " / ") + " 关着：搬完以后不会自动跟上新消息，打开后才接着写。")
        }
        lines.append("先整份备份到「\(backupFolder)」。跑的时候屏幕常亮，别切走 App。")
        return lines.joined(separator: "\n")
    }

    /// 进度行：「正在搬 12 / 80 ·《色色》· 压 A3 · 已花 $0.31 · 还要约 9 分钟」（步骤 10-16 加，刚开始没有）
    static func progressText(_ p: Progress) -> String {
        "正在搬 \(p.index) / \(p.total) ·《\(p.title.isEmpty ? "没有标题" : p.title)》" + (p.step.isEmpty ? "" : "· \(p.step) ")
            + "· 已花 \(money(p.spent)) · 还要约 \(duration(p.remaining))"
    }

    /// 结果段（同时存进备份文件夹的「搬迁结果.txt」）：成 / 没成 / 跳过 / 花了多少 / 停在哪 / 老段在备份哪 / 没成的逐条
    static func resultText(_ r: Report) -> String {
        let backup = r.backup.lastPathComponent
        var out = (r.stopped == nil ? "搬完了：" : "没搬完：")
            + "成 \(r.done) 个，没成 \(r.failures.count) 个，跳过 \(r.skipped) 个\(r.short > 0 ? "，太短跳过 \(r.short) 个" : "")。"
            + "花了 \(money(r.spent))。备份在 \(backup)。"
        if let s = r.stopped { out += "\n" + s }
        out += "\n被换下来的老段、老抄本都在备份「\(backup)」里：上下文摘要的老段在 \(SessionSummaryStore.folder)/，"
            + "窗口总结的老抄本在 \(WindowSummaryStore.folder)/（第一代老摘要没动，还在 \(SummaryFileStore.folder)/）。"
        if !r.failures.isEmpty { out += "\n没成的：\n" + r.failures.joined(separator: "\n") }
        return out
    }
}
