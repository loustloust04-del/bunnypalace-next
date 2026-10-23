#if PERSONAL_APPS
import Foundation
import Observation

/// 死亡天平（plan-death-scale §4.4）：只存本机 `Application Support/MemoryPalace/DeathScale/`，
/// 不进 SwiftData、不进楼层 filesystem/、不进 GlobalBackup。
enum DeathScale {
    enum Side: String, Codable, CaseIterable { case die, live }

    struct Reason: Codable, Identifiable, Equatable {
        let id: UUID
        var side: Side
        var text: String
        var weight: Int
        let createdAt: Date
        var modifiedAt: Date
    }

    struct LedgerEntry: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case add, remove, weight, text, hourOpen, hourClose, hourEdit, hourDelete }
        var id = UUID()
        let at: Date
        let kind: Kind
        var reasonId: UUID?
        var hourId: UUID?
        var side: Side?
        var from: String?
        var to: String?
        var text: String?
        let sumDie: Int
        let sumLive: Int
    }

    struct Hour: Codable, Identifiable, Equatable {
        let id: UUID
        var start: Date
        var end: Date?
    }

    static let weightRange = 1...9
}

enum DeathScaleTime {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "dd.MM.yyyy · HH:mm:ss"
        return f
    }()

    static func format(_ date: Date) -> String { formatter.string(from: date) }
}

@Observable
@MainActor
final class DeathScaleStore {
    static let shared = DeathScaleStore(root: DeathScaleStore.defaultRoot)

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("DeathScale", isDirectory: true)
    }

    private(set) var reasons: [DeathScale.Reason] = []
    private(set) var ledger: [DeathScale.LedgerEntry] = []
    private(set) var hours: [DeathScale.Hour] = []
    private(set) var carnet = ""
    private(set) var readableProfileIds: [String] = []
    private(set) var lastError: String?

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let now: () -> Date

    private struct Access: Codable { var readableProfileIds: [String] }

    init(root: URL, now: @escaping () -> Date = Date.init) {
        self.root = root
        self.now = { Self.second(now()) }
        reasons = Self.decode([DeathScale.Reason].self, from: url("reasons.json")) ?? []
        hours = Self.decode([DeathScale.Hour].self, from: url("hours.json")) ?? []
        readableProfileIds = Self.decode(Access.self, from: url("access.json"))?.readableProfileIds ?? []
        carnet = (try? String(contentsOf: url("carnet.md"), encoding: .utf8)) ?? ""
        if let data = try? Data(contentsOf: url("ledger.jsonl")) {
            let decoder = Self.decoder
            ledger = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(DeathScale.LedgerEntry.self, from: Data($0)) }
        }
    }

    // MARK: - 读

    func sum(_ side: DeathScale.Side) -> Int { Self.sum(side, in: reasons) }

    var openHour: DeathScale.Hour? { hours.last { $0.end == nil } }

    func canRead(profileId: String?) -> Bool {
        guard let profileId, !profileId.isEmpty else { return false }
        return readableProfileIds.contains(profileId)
    }

    // MARK: - 砝码

    @discardableResult
    func add(side: DeathScale.Side, text: String, weight: Int) -> DeathScale.Reason? {
        let t = now()
        let reason = DeathScale.Reason(id: UUID(), side: side, text: text, weight: Self.clamp(weight), createdAt: t, modifiedAt: t)
        var next = reasons
        next.append(reason)
        guard commitReasons(next) else { return nil }
        log(.add, at: t, reasonId: reason.id, side: side, to: String(reason.weight), text: text)
        return reason
    }

    func remove(_ id: UUID) {
        guard let old = reasons.first(where: { $0.id == id }) else { return }
        guard commitReasons(reasons.filter { $0.id != id }) else { return }
        log(.remove, at: now(), reasonId: id, side: old.side, from: String(old.weight), text: old.text)
    }

    func setWeight(_ id: UUID, _ weight: Int) {
        let w = Self.clamp(weight)
        guard let i = reasons.firstIndex(where: { $0.id == id }), reasons[i].weight != w else { return }
        let t = now()
        var next = reasons
        let old = next[i].weight
        next[i].weight = w
        next[i].modifiedAt = t
        guard commitReasons(next) else { return }
        log(.weight, at: t, reasonId: id, side: next[i].side, from: String(old), to: String(w), text: next[i].text)
    }

    func setText(_ id: UUID, _ text: String) {
        guard let i = reasons.firstIndex(where: { $0.id == id }), reasons[i].text != text else { return }
        let t = now()
        var next = reasons
        let old = next[i].text
        next[i].text = text
        next[i].modifiedAt = t
        guard commitReasons(next) else { return }
        log(.text, at: t, reasonId: id, side: next[i].side, from: old, to: text)
    }

    // MARK: - 时辰

    @discardableResult
    func startHour() -> DeathScale.Hour? {
        if let open = openHour { return open }
        let t = now()
        let hour = DeathScale.Hour(id: UUID(), start: t, end: nil)
        guard commitHours(hours + [hour]) else { return nil }
        log(.hourOpen, at: t, hourId: hour.id, to: DeathScaleTime.format(t))
        return hour
    }

    func endHour() {
        guard let open = openHour, let i = hours.firstIndex(where: { $0.id == open.id }) else { return }
        let t = max(now(), open.start)
        var next = hours
        next[i].end = t
        guard commitHours(next) else { return }
        log(.hourClose, at: t, hourId: open.id, from: DeathScaleTime.format(open.start), to: DeathScaleTime.format(t))
    }

    @discardableResult
    func addHour(start: Date, end: Date) -> DeathScale.Hour? {
        let start = Self.second(start), end = Self.second(end)
        guard end >= start else { lastError = "结束早于开始"; return nil }
        let hour = DeathScale.Hour(id: UUID(), start: start, end: end)
        guard commitHours((hours + [hour]).sorted { $0.start < $1.start }) else { return nil }
        log(.hourEdit, at: now(), hourId: hour.id, to: Self.span(hour))
        return hour
    }

    func editHour(_ id: UUID, start: Date, end: Date?) {
        guard let i = hours.firstIndex(where: { $0.id == id }) else { return }
        let start = Self.second(start), end = end.map(Self.second)
        if let end, end < start { lastError = "结束早于开始"; return }
        if end == nil, hours.contains(where: { $0.id != id && $0.end == nil }) { lastError = "已经有一段正在计时"; return }
        var next = hours
        let old = next[i]
        next[i].start = start
        next[i].end = end
        guard next[i] != old else { return }
        guard commitHours(next.sorted { $0.start < $1.start }) else { return }
        log(.hourEdit, at: now(), hourId: id, from: Self.span(old), to: Self.span(next[i]))
    }

    func deleteHour(_ id: UUID) {
        guard let old = hours.first(where: { $0.id == id }) else { return }
        guard commitHours(hours.filter { $0.id != id }) else { return }
        log(.hourDelete, at: now(), hourId: id, from: Self.span(old))
    }

    // MARK: - 小本子 / 可读楼层（不记账簿）

    func setCarnet(_ text: String) {
        guard text != carnet else { return }
        guard write(Data(text.utf8), to: "carnet.md") else { return }
        carnet = text
    }

    func grantRead(_ profileId: String) {
        guard !profileId.isEmpty, !readableProfileIds.contains(profileId) else { return }
        commitAccess(readableProfileIds + [profileId])
    }

    func revokeRead(_ profileId: String) {
        guard readableProfileIds.contains(profileId) else { return }
        commitAccess(readableProfileIds.filter { $0 != profileId })
    }

    // MARK: - 写盘

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// 存盘是 ISO8601 到秒，内存里也取整到秒，免得重开前后不相等
    nonisolated private static func second(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }

    private static func clamp(_ w: Int) -> Int { min(max(w, DeathScale.weightRange.lowerBound), DeathScale.weightRange.upperBound) }

    private static func sum(_ side: DeathScale.Side, in list: [DeathScale.Reason]) -> Int {
        list.filter { $0.side == side }.reduce(0) { $0 + $1.weight }
    }

    private static func span(_ h: DeathScale.Hour) -> String {
        DeathScaleTime.format(h.start) + " – " + (h.end.map(DeathScaleTime.format) ?? "…")
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    private var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }

    private func write(_ data: Data, to name: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url(name), options: writeOptions)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func commitReasons(_ next: [DeathScale.Reason]) -> Bool {
        guard let data = try? Self.encoder.encode(next), write(data, to: "reasons.json") else { return false }
        reasons = next
        return true
    }

    private func commitHours(_ next: [DeathScale.Hour]) -> Bool {
        guard let data = try? Self.encoder.encode(next), write(data, to: "hours.json") else { return false }
        hours = next
        return true
    }

    private func commitAccess(_ next: [String]) {
        guard let data = try? Self.encoder.encode(Access(readableProfileIds: next)), write(data, to: "access.json") else { return }
        readableProfileIds = next
    }

    private func log(_ kind: DeathScale.LedgerEntry.Kind, at: Date, reasonId: UUID? = nil, hourId: UUID? = nil,
                     side: DeathScale.Side? = nil, from: String? = nil, to: String? = nil, text: String? = nil) {
        let entry = DeathScale.LedgerEntry(at: at, kind: kind, reasonId: reasonId, hourId: hourId, side: side,
                                           from: from, to: to, text: text,
                                           sumDie: sum(.die), sumLive: sum(.live))
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        let file = url("ledger.jsonl")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                #if os(iOS)
                let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
                #else
                let attributes: [FileAttributeKey: Any] = [:]
                #endif
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: attributes) else {
                    lastError = "账簿文件建不出来"
                    return
                }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            ledger.append(entry)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
#endif
