import Foundation

/// L2 单词在场信号：刷词/复习/收词时打点 → 10s 节流全量快照上行 hub 落 `agent/vocab-status.json`。
/// CC / daemon 由此知道「她现在在背什么、今天学得怎么样」。
/// 开关在 hub 侧（config coRead.vocab，缺省关 = 收到帧不落盘），app 照发零开关逻辑。
/// 抄 ReadingSignals（CR-2）形状；best-effort，断连不重试（下次动作自然重发）。
@MainActor
enum VocabSignals {

    // MARK: - 今日状态（UserDefaults 持久，跨日自动作废）

    struct Collected: Codable, Equatable {
        let word: String
        let from: String       // 来源人话（"聊天" / 书名 / "生词本"）
    }

    struct TodayState: Codable {
        var day: String = ""
        var studied: Int = 0                // 刷词 mark 数（挂点递增，不查库——markedAt 会混收词）
        var recentWords: [String] = []      // 最近刷/复习 ≤10，最新在前
        var collected: [Collected] = []     // 今日新收 ≤10
        var lastActionAt: Date? = nil
        var activityRaw: String? = nil      // studying | reviewing
        var currentSource: String = ""      // 在背哪个词书（人话，只报名字）
    }

    private static let stateKey = "vocabSignalsToday"
    /// 距最近动作超过这个窗口，快照 activity 报 null（"这会儿没在背"）。
    static let activityWindow: TimeInterval = 300
    /// 节流：挂点密集触发（一分钟十几张卡）只发最后一版快照。
    static let throttle: TimeInterval = 10

    // MARK: - 挂点入口

    /// 刷词 mark 后调（VocabSessionStore.markCurrent）。
    static func recordStudy(word: String, source: String) {
        touch { s in
            s.studied += 1
            s.activityRaw = "studying"
            s.currentSource = source
            bump(&s.recentWords, word)
        }
    }

    /// 复习打分后调（VocabReviewStore.submitRating）。reviewed/wrongTop 从 review-log 算，这里只记在场。
    static func recordReview(word: String, source: String) {
        touch { s in
            s.activityRaw = "reviewing"
            s.currentSource = source
            bump(&s.recentWords, word)
        }
    }

    /// 收词成功后调（VocabCollector 两个出口）。
    static func recordCollect(word: String, from: String) {
        touch { s in
            let c = Collected(word: word, from: from)
            guard !s.collected.contains(where: { $0.word == word }) else { return }
            s.collected.append(c)
            s.collected = Array(s.collected.suffix(10))
        }
    }

    private static func bump(_ list: inout [String], _ word: String) {
        list.removeAll { $0 == word }
        list.insert(word, at: 0)
        list = Array(list.prefix(10))
    }

    private static func touch(_ mutate: (inout TodayState) -> Void) {
        var s = loadToday()
        mutate(&s)
        s.lastActionAt = Date()
        saveToday(s)
        scheduleReport()
    }

    // MARK: - 快照组装（纯函数，可测）

    /// 今日复习统计：行数 + again 词按次数降序 top5。
    static func todayReviewStats(log: [VocabReviewLogEntry], now: Date = Date()) -> (reviewed: Int, wrongTop: [String]) {
        let key = ReadingSignals.dayKey(now)
        var reviewed = 0
        var wrong: [String: Int] = [:]
        for e in log where ReadingSignals.dayKey(e.ts) == key {
            reviewed += 1
            if e.rating == "again" { wrong[e.word, default: 0] += 1 }
        }
        let top = wrong.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5).map(\.key)
        return (reviewed, top)
    }

    /// 连续学习天数。今天没学不打断（从昨天起数）；今天学了从今天起数。
    static func streakDays(dayKeys: Set<String>, now: Date = Date()) -> Int {
        var cursor = Calendar.current.startOfDay(for: now)
        if !dayKeys.contains(ReadingSignals.dayKey(cursor)) {
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = prev
        }
        var streak = 0
        while dayKeys.contains(ReadingSignals.dayKey(cursor)) {
            streak += 1
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    static func buildSnapshot(state: TodayState, log: [VocabReviewLogEntry], now: Date = Date()) -> [String: Any] {
        let (reviewed, wrongTop) = todayReviewStats(log: log, now: now)
        var dayKeys = Set(log.map { ReadingSignals.dayKey($0.ts) })
        if state.studied > 0 || !state.collected.isEmpty || !state.recentWords.isEmpty {
            dayKeys.insert(ReadingSignals.dayKey(now))
        }
        let active = state.lastActionAt.map { now.timeIntervalSince($0) <= activityWindow } ?? false
        // NSNull 不是省 key：CC 读到显式 null 才知道"这会儿没在背"（JSONSerialization 对 Optional 会 throw）
        let activity: Any = (active ? state.activityRaw : nil).map { $0 as Any } ?? NSNull()
        return [
            "date": ReadingSignals.dayKey(now),
            "updatedAt": ISO8601DateFormatter().string(from: now),
            "activity": activity,
            "currentSource": state.currentSource,
            "recentWords": state.recentWords,
            "today": [
                "studied": state.studied,
                "reviewed": reviewed,
                "wrongTop": wrongTop,
                "collected": state.collected.map { ["word": $0.word, "from": $0.from] },
            ],
            "streak": streakDays(dayKeys: dayKeys, now: now),
        ]
    }

    // MARK: - 节流上行

    private static var reportTask: Task<Void, Never>? = nil

    private static func scheduleReport() {
        guard reportTask == nil else { return }
        reportTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(throttle))
            reportTask = nil
            report()
        }
    }

    private static func report() {
        let log = VocabCardStore.loadLog(dir: VocabCollector.reviewDeckDir)
        let snapshot = buildSnapshot(state: loadToday(), log: log)
        CCBridgeWebSocketClient.shared.send([
            "type": "vocab_status",
            "status": snapshot,
        ]) { _ in }
    }

    // MARK: - IO

    static func loadToday(now: Date = Date()) -> TodayState {
        let key = ReadingSignals.dayKey(now)
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let s = try? JSONDecoder().decode(TodayState.self, from: data),
              s.day == key else {
            var fresh = TodayState()
            fresh.day = key
            return fresh
        }
        return s
    }

    private static func saveToday(_ s: TodayState) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }
}
