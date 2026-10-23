import Foundation
import SwiftData

/// CR-2 阅读在场信号：60s 打点 + 事件流 + hub 快照上报。
/// AUTONOMY 的第一个真实在场数据面——AI 由此知道「她今天读了多久、读到哪、动了几笔」。
///
/// 存储（楼层级 filesystem/ 根，notes.json 同款原子写；不动 SwiftData schema）：
/// - `reading-log.json`：按日累计秒数 + 每书细分（保 30 天）
/// - `reading-events.jsonl`：一行一事件（highlight/note/askAI/vocab/reply），>2000 行裁半保尾
/// hub 侧 `agent/reading-status.json` 由 60s tick 顺手经 WS 上报（best-effort，断连下个 tick 重发）。
enum ReadingSignals {

    // MARK: - 路径

    static func logURL(profileId: String) -> URL {
        FileLibraryStore.libraryRoot(profileId: profileId).appendingPathComponent("reading-log.json")
    }

    static func eventsURL(profileId: String) -> URL {
        FileLibraryStore.libraryRoot(profileId: profileId).appendingPathComponent("reading-events.jsonl")
    }

    // MARK: - 数据结构

    struct ReadingLog: Codable {
        var days: [String: Day] = [:]
        struct Day: Codable {
            var totalSeconds: Int = 0
            var books: [String: Book] = [:]
        }
        struct Book: Codable {
            var seconds: Int = 0
            var lastChapter: Int = 0
        }
    }

    struct Event: Codable {
        let ts: Date
        let type: String     // highlight | note | askAI | vocab | reply
        let book: String
        let chapter: Int
        var word: String? = nil
    }

    /// 本地时区日界 key（yyyy-MM-dd）。
    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - 60s 打点

    /// 阅读器每 60s 调一次：累加今日/该书秒数 + 裁 30 天 + 上报 hub 快照。
    static func logTick(bookSafeName: String, bookDisplayName: String, chapter: Int,
                        profileId: String, seconds: Int = 60, now: Date = Date()) {
        var log = loadLog(profileId: profileId)
        let key = dayKey(now)
        var day = log.days[key] ?? ReadingLog.Day()
        day.totalSeconds += seconds
        var book = day.books[bookSafeName] ?? ReadingLog.Book()
        book.seconds += seconds
        book.lastChapter = chapter
        day.books[bookSafeName] = book
        log.days[key] = day
        prune(&log, keep: 30, now: now)
        saveLog(log, profileId: profileId)

        reportStatus(log: log, bookDisplayName: bookDisplayName, chapter: chapter,
                     profileId: profileId, now: now)
    }

    /// 30 天外的 day key 裁掉。
    static func prune(_ log: inout ReadingLog, keep: Int, now: Date = Date()) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -keep, to: now) else { return }
        let cutoffKey = dayKey(cutoff)
        log.days = log.days.filter { $0.key >= cutoffKey }   // yyyy-MM-dd 字典序=时间序
    }

    // MARK: - 事件流

    static func logEvent(type: String, book: String, chapter: Int, word: String? = nil,
                         profileId: String, now: Date = Date()) {
        let url = eventsURL(profileId: profileId)
        let event = Event(ts: now, type: type, book: book, chapter: chapter, word: word)
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else { return }

        var lines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        lines.append(line)
        if lines.count > 2000 {
            lines = Array(lines.suffix(1000))
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// 今日事件计数（status 上报用）。文件 ≤2000 行，全读可接受。
    static func todayEventCounts(profileId: String, now: Date = Date()) -> [String: Int] {
        let url = eventsURL(profileId: profileId)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let key = dayKey(now)
        var counts: [String: Int] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)),
                  dayKey(event.ts) == key else { continue }
            counts[event.type, default: 0] += 1
        }
        return counts
    }

    // MARK: - 人格包（CR-4.5 R1：daemon 带她的 AI 的人格与记忆读书）

    /// 楼层人格 + 记忆摘要，随 reading_context 上行给 hub → ReaderDaemon 的 system prompt。
    /// 轻量拼接（不跑聊天组装管线——那套含工具/文件库等机制段，读书用不上）。
    static func buildPersonaPackage(profile: Profile, context: ModelContext) -> String {
        var parts: [String] = []
        parts.append("你是\(profile.assistantName)。你在陪\(profile.userName)读书。")

        let personaFields = [profile.systemPrompt, profile.characterDescription, profile.characterPersonality]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !personaFields.isEmpty {
            parts.append(String(personaFields.joined(separator: "\n\n").prefix(4_000)))
        }

        let pid = profile.id
        let desc = FetchDescriptor<Memory>(predicate: #Predicate { $0.profileId == pid })
        let memories = (try? context.fetch(desc)) ?? []
        if !memories.isEmpty {
            let injection = MemoryInjector.buildInjection(memories: memories, budget: 1_000)
            if !injection.isEmpty {
                parts.append("【你对\(profile.userName)的了解】\n\(injection)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - hub 上报（best-effort）

    private static func reportStatus(log: ReadingLog, bookDisplayName: String, chapter: Int,
                                     profileId: String, now: Date) {
        let key = dayKey(now)
        let today = log.days[key]
        let iso = ISO8601DateFormatter().string(from: now)
        CCBridgeWebSocketClient.shared.send([
            "type": "reading_status",
            "status": [
                "date": key,
                "todaySeconds": today?.totalSeconds ?? 0,
                "currentBook": bookDisplayName,
                "currentChapter": chapter,
                "todayEvents": todayEventCounts(profileId: profileId, now: now),
                "updatedAt": iso,
            ],
        ]) { _ in }
    }

    // MARK: - IO

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func loadLog(profileId: String) -> ReadingLog {
        guard let data = try? Data(contentsOf: logURL(profileId: profileId)),
              let log = try? decoder.decode(ReadingLog.self, from: data) else { return ReadingLog() }
        return log
    }

    private static func saveLog(_ log: ReadingLog, profileId: String) {
        let url = logURL(profileId: profileId)
        guard let data = try? {
            let e = encoder
            e.outputFormatting = [.sortedKeys]
            return try e.encode(log)
        }() else { return }
        try? data.write(to: url, options: .atomic)
    }
}
