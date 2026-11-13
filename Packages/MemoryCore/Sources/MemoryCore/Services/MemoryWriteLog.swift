import Foundation

/// 记忆日志（plan §十一）：一次后台写一条——时间 / 编号 / 成了 · 没成 / 原因 / 模型 / 花了多少。
/// 存楼层 `memory/log/写入日志.jsonl`，只追加，保留 30 天或 1000 条（先到先删）；不放 UserDefaults（3.8MB 卡顿的教训）。
/// 写在串行队列上（谁调都不卡）；读只在打开日志页时、在后台读
public enum MemoryWriteLog {}

public extension MemoryWriteLog {

    struct Entry: Codable, Equatable, Identifiable {
        public var id = UUID()
        public var time: Date
        /// 编号：A2 / A3 / A4 / C2
        public var writer: String
        public var ok: Bool
        /// 成了：写了什么（「第 3 段 · 《看病》」）；没成：原因
        public var note: String
        public var model: String
        public var costUSD: Double?
        /// C2 拒收了几张（格式不对；整包拒收记 1）
        public var rejected: Int?
        public var run: CatalogRunLink? = nil
        /// 审计台试写台跑的（不算失败、不进健康；状态行「最近那条」跳过它）。老行没有这个字段 = nil
        public var trial: Bool? = nil

        public init(id: UUID = UUID(), time: Date, writer: String, ok: Bool, note: String, model: String,
                    costUSD: Double? = nil, rejected: Int? = nil, run: CatalogRunLink? = nil, trial: Bool? = nil) {
            self.id = id
            self.time = time
            self.writer = writer
            self.ok = ok
            self.note = note
            self.model = model
            self.costUSD = costUSD
            self.rejected = rejected
            self.run = run
            self.trial = trial
        }
    }

    static let folder = "log"
    static let fileName = "写入日志.jsonl"
    static let keepDays = 30
    static let keepCount = 1000

    static func fileURL(memoryRoot: URL) -> URL {
        memoryRoot
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static let queue = DispatchQueue(label: "memorypalace.memory-write-log", qos: .utility)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // MARK: - 这次调用花了多少（同一个写手任务里记账的那几笔）

    /// 一个写手任务的花费表：`metered` 包住一次写，`SessionSegmentWriter.modelCaller` 记账后往里加，
    /// `MemoryHealthStore.recordOK / recordError` 记日志时取
    final class CostMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var total: Double = 0
        private var touched = false

        public init() {}

        public func add(_ usd: Double) {
            lock.lock(); total += usd; touched = true; lock.unlock()
        }

        public var usd: Double? {
            lock.lock(); defer { lock.unlock() }
            return touched ? total : nil
        }
    }

    @TaskLocal static var meter: CostMeter?

    static func metered<T>(_ body: () async throws -> T) async rethrows -> T {
        try await $meter.withValue(CostMeter()) { try await body() }
    }

    static func addCost(_ usd: Double) {
        meter?.add(usd)
    }

    // MARK: - 写


    /// 没有健康种类的（C3 批提案）直接按编号记。trial = 试写台跑的（cost 给了就用它，不看 meter）
    static func record(writer: MemoryWriterID, profileId: String, ok: Bool, note: String, model: String,
                       rejected: Int? = nil, now: Date = Date(), run: CatalogRunLink? = nil,
                       trial: Bool = false, cost: Double? = nil, memoryRoot: @autoclosure () -> URL) {
        guard !profileId.isEmpty else { return }
        let entry = Entry(time: now, writer: writer.code, ok: ok, note: note, model: model, costUSD: cost ?? meter?.usd,
                          rejected: rejected.flatMap { $0 > 0 ? $0 : nil }, run: run, trial: trial ? true : nil)
        let url = fileURL(memoryRoot: memoryRoot())
        queue.async { append(entry, to: url, now: now) }
    }

    /// 测试用：等队列里的写完
    static func flush() {
        queue.sync {}
    }

    private static func append(_ entry: Entry, to url: URL, now: Date) {
        var list = decode((try? Data(contentsOf: url)) ?? Data())
        list.append(entry)
        list = pruned(list, now: now)
        let data = list.compactMap { try? encoder.encode($0) }.reduce(into: Data()) { out, line in
            out.append(line)
            out.append(0x0A)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            MemoryLogging.shared.log("📝 记忆日志: ❌ 写盘失败 — \(error.localizedDescription)")
        }
    }

    // MARK: - 读（后台）

    /// 新的在前
    static func entries(memoryRoot: URL) -> [Entry] {
        let url = fileURL(memoryRoot: memoryRoot)
        return queue.sync { decode((try? Data(contentsOf: url)) ?? Data()) }.sorted { $0.time > $1.time }
    }

    // MARK: - 纯函数（可测）

    static func decode(_ data: Data) -> [Entry] {
        data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    /// 30 天以前的删；还多于 1000 条删最早的
    static func pruned(_ list: [Entry], now: Date) -> [Entry] {
        let since = now.addingTimeInterval(-TimeInterval(keepDays) * 86400)
        let kept = list.filter { $0.time >= since }.sorted { $0.time < $1.time }
        return Array(kept.suffix(keepCount))
    }


    /// 这一项最近那条（状态卡每一行点了跳这里）；试写台的不算
    static func latest(_ writer: MemoryWriterID, in list: [Entry]) -> Entry? {
        list.filter { $0.writer == writer.code && $0.trial != true }.max { $0.time < $1.time }
    }
}
