import Foundation

/// 每个人的 `memory/heartbeat/`（plan §2）：
/// `tasks.json` = 任务；`runs/yyyy-MM/<runId>.json` = 每次执行；`shots/<runId>/<n>.jpg` = 截图。
/// 执行记录留 60 天，删执行连截图一起删；任务不自动删。文件都小，同步读写，调用方自己挑线程
public struct WakeStore: Sendable {
    public let root: URL

    public init(memoryRoot: URL) {
        root = memoryRoot.appendingPathComponent("heartbeat", isDirectory: true)
    }

    public static let keepDays = 60

    private var tasksURL: URL { root.appendingPathComponent("tasks.json") }
    private var runsDir: URL { root.appendingPathComponent("runs", isDirectory: true) }
    private var shotsDir: URL { root.appendingPathComponent("shots", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private static let month: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM"
        return f
    }()

    // MARK: 任务

    public func tasks() -> [WakeTask] {
        guard let data = try? Data(contentsOf: tasksURL) else { return [] }
        return (try? Self.decoder.decode([WakeTask].self, from: data)) ?? []
    }

    public func saveTasks(_ tasks: [WakeTask]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.encoder.encode(tasks).write(to: tasksURL, options: .atomic)
    }

    public func task(_ id: String) -> WakeTask? { tasks().first { $0.id == id } }

    /// 有就换，没有就加
    public func upsert(_ task: WakeTask) throws {
        var all = tasks()
        if let i = all.firstIndex(where: { $0.id == task.id }) { all[i] = task } else { all.append(task) }
        try saveTasks(all)
    }

    /// 删任务（它的执行记录留着，到期按 60 天删）
    public func deleteTask(_ id: String) throws {
        try saveTasks(tasks().filter { $0.id != id })
    }

    // MARK: 执行

    public func save(_ run: WakeRun) throws {
        let dir = runsDir.appendingPathComponent(Self.month.string(from: run.startedAt), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(run).write(to: dir.appendingPathComponent("\(run.id).json"), options: .atomic)
    }

    /// 新的在前；taskId 给了只看这个任务的
    public func runs(taskId: String? = nil, limit: Int = 100) -> [WakeRun] {
        let fm = FileManager.default
        let months = ((try? fm.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var out: [WakeRun] = []
        for month in months {
            let files = (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)) ?? []
            var runs: [WakeRun] = []
            for file in files where file.pathExtension == "json" {
                guard let run = Self.decodeRun(file), taskId == nil || run.taskId == taskId else { continue }
                runs.append(run)
            }
            out += runs.sorted { $0.startedAt > $1.startedAt }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    private static func decodeRun(_ file: URL) -> WakeRun? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(WakeRun.self, from: data)
    }

    public func run(_ id: String) -> WakeRun? {
        runs(limit: .max).first { $0.id == id }
    }

    /// 今天（calendar 的这一天）已经跑了几次（跳过的不算）
    public func runsCount(on day: Date, calendar: Calendar) -> Int {
        runs(limit: 200).filter { calendar.isDate($0.startedAt, inSameDayAs: day) && $0.status != .skipped }.count
    }

    // MARK: 截图

    public func shotURL(runId: String, name: String) -> URL {
        shotsDir.appendingPathComponent(runId, isDirectory: true).appendingPathComponent(name)
    }

    /// 存一张，回文件名
    public func saveShot(_ jpeg: Data, runId: String, index: Int) throws -> String {
        let name = "\(index).jpg"
        let url = shotURL(runId: runId, name: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        return name
    }

    // MARK: 修剪 / 清空

    /// 删 60 天前的执行和它们的截图
    public func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86400)
        let fm = FileManager.default
        for month in (try? fm.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)) ?? [] {
                guard let run = Self.decodeRun(file), run.startedAt < cutoff else { continue }
                try? fm.removeItem(at: file)
                try? fm.removeItem(at: shotsDir.appendingPathComponent(run.id, isDirectory: true))
            }
            if ((try? fm.contentsOfDirectory(atPath: month.path)) ?? []).isEmpty { try? fm.removeItem(at: month) }
        }
    }

    /// 「清空 heartbeat 记录」：执行和截图全删，任务留着
    public func clearRuns() {
        try? FileManager.default.removeItem(at: runsDir)
        try? FileManager.default.removeItem(at: shotsDir)
    }
}
