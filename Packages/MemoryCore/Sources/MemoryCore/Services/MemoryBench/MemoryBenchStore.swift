import Foundation

/// 试写台的存储（plan-memory-audit-home-trial 3.2）：楼层目录下的 `bench/`，和 `memory/` 平级——
/// 不在 `memory/`（那里点开头的目录只对 wiki 隐藏，助手 fs 工具会看到、能改，fs_search 还会扫）也不在 `filesystem/`，
/// 助手工具和文件库都看不到；楼层迁 iCloud 只搬 `filesystem/` 和元数据，它留在本地。
///
///     bench/sets/<测试集>.json          她在这层楼建的考卷（内置的随 app 走，不在这）
///     bench/recipes/<写手>.json         她存的版本 + 正在用的那份
///     bench/runs/<跑>/run.json          一次跑：配方快照、每格结果、判断、分数
///     bench/runs/<跑>/requests.jsonl    完整日志：每格送了什么、回了什么
///
/// 同步文件 IO，调用方放后台。读坏了的文件当没有（不崩、不覆盖）
public struct MemoryBenchStore: Sendable {
    public let root: URL

    public static let folderName = "bench"
    /// 完整日志留几天（分数、判断、每格输出永远留；钉住的跑不清）
    public static let keepLogDays = 30
    /// 随 app 走的考卷（`Resources/MemoryBench/<名字>.json`）
    public static let builtInSetNames = ["memory-bench-c2-probe", "memory-bench-recall-24"]

    public init(root: URL) {
        self.root = root
    }

    /// 这层楼的 `bench/`
    public static func forMemoryRoot(_ memoryRoot: URL) -> MemoryBenchStore {
        MemoryBenchStore(root: memoryRoot
            .deletingLastPathComponent()
            .appendingPathComponent(folderName, isDirectory: true))
    }

    private var setsDir: URL { root.appendingPathComponent("sets", isDirectory: true) }
    private var recipesDir: URL { root.appendingPathComponent("recipes", isDirectory: true) }
    private var runsDir: URL { root.appendingPathComponent("runs", isDirectory: true) }

    private func runDir(_ id: String) -> URL { runsDir.appendingPathComponent(Self.fileName(id), isDirectory: true) }

    /// id → 文件名：只用字母数字 _ -，别的（中文、斜杠…）换成哈希，免得越出目录
    public static func fileName(_ id: String) -> String {
        let ok = !id.isEmpty && id.count <= 80
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" }
        return ok ? id : "h" + MemoryBench.digest(Data(id.utf8))
    }

    // MARK: - 读写小工具

    /// 读不成的几种：都不能当成「没有」，否则下次保存就把原件盖掉了（astra zd2 #4）
    public enum LoadError: LocalizedError, Equatable {
        /// 文件在，但打不开
        case unreadable(String)
        /// 读得出，但不是这份 JSON 该有的样子
        case corrupt(String)
        /// 新版本 app 写的，这个版本看不懂
        case unsupportedSchema(file: String, schema: Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let f): return "「\(f)」打不开，先不动它"
            case .corrupt(let f): return "「\(f)」坏了（不是能读的格式），原件留着没覆盖"
            case .unsupportedSchema(let f, let s): return "「\(f)」是新版本写的（schema \(s)），这个版本看不懂，先不动它"
            }
        }
    }

    private struct SchemaProbe: Decodable {
        let schema: Int?
    }

    /// 不存在 = nil；在但读不成 = 抛 `LoadError`
    private func load<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let name = url.lastPathComponent
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LoadError.unreadable(name) }
        guard let probe = try? MemoryBench.decoder.decode(SchemaProbe.self, from: data) else { throw LoadError.corrupt(name) }
        if let s = probe.schema, s > MemoryBench.schema { throw LoadError.unsupportedSchema(file: name, schema: s) }
        do { return try MemoryBench.decoder.decode(type, from: data) } catch { throw LoadError.corrupt(name) }
    }

    /// 普通保存：原来那份在但读不成（坏了 / 新版本 / 打不开）就拒绝，不覆盖
    private func save<T: Codable>(_ value: T, to url: URL, as type: T.Type) throws {
        _ = try load(type, at: url)
        try write(value, to: url)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MemoryBench.encoder.encode(value).write(to: url, options: .atomic)
    }

    /// 列表用：坏的跳过
    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        (try? load(type, at: url)) ?? nil
    }

    private func jsonFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - 考卷

    /// 随 app 走的考卷；先找 `MemoryBench/` 子目录，打包时被平铺了就找包根
    public static func builtInSets(bundle: Bundle = .main) -> [MemoryBenchSet] {
        builtInSetNames.compactMap { name in
            guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "MemoryBench")
                    ?? bundle.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let set = try? MemoryBench.decoder.decode(MemoryBenchSet.self, from: data) else { return nil }
            return set
        }
    }

    public func floorSets() -> [MemoryBenchSet] {
        jsonFiles(in: setsDir).compactMap { read(MemoryBenchSet.self, at: $0) }
    }

    /// 内置的在前，这层楼的在后；writer = nil 全要
    public func sets(writer: String? = nil, bundle: Bundle = .main) -> [MemoryBenchSet] {
        (Self.builtInSets(bundle: bundle) + floorSets()).filter { writer == nil || $0.writer == writer }
    }

    /// 同 id 的原件读不成就拒绝（不覆盖）
    public func saveSet(_ set: MemoryBenchSet) throws {
        try save(set, to: setsDir.appendingPathComponent(Self.fileName(set.id) + ".json"), as: MemoryBenchSet.self)
    }

    public func deleteSet(id: String) throws {
        let url = setsDir.appendingPathComponent(Self.fileName(id) + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - 配方

    private func recipeURL(_ writer: String) -> URL { recipesDir.appendingPathComponent(Self.fileName(writer) + ".json") }

    /// 没存过 = 空配方簿；文件在但读不成抛 `LoadError`（不能当成空的，否则下次保存就覆盖了原件）
    public func recipeBook(writer: String) throws -> MemoryBenchRecipeBook {
        try load(MemoryBenchRecipeBook.self, at: recipeURL(writer)) ?? MemoryBenchRecipeBook(writer: writer, active: nil, versions: [])
    }

    public enum RecipeError: LocalizedError, Equatable {
        case tooMany(Int)

        public var errorDescription: String? {
            switch self {
            case .tooMany(let n): return "一个写手最多存 \(n) 版，先删掉几版"
            }
        }
    }

    /// 原件读不成（坏了 / 新版本 / 打不开）就拒绝保存，原件留着
    public func saveRecipeBook(_ book: MemoryBenchRecipeBook) throws {
        guard book.versions.count <= MemoryBenchRecipeBook.maxVersions else { throw RecipeError.tooMany(MemoryBenchRecipeBook.maxVersions) }
        try save(book, to: recipeURL(book.writer), as: MemoryBenchRecipeBook.self)
    }

    // MARK: - 跑

    public func saveRun(_ run: MemoryBenchRun) throws {
        try write(run, to: runDir(run.id).appendingPathComponent("run.json"))
    }

    public func run(id: String) -> MemoryBenchRun? {
        read(MemoryBenchRun.self, at: runDir(id).appendingPathComponent("run.json"))
    }

    /// 新的在前；可按写手 / 考卷筛
    public func runs(writer: String? = nil, setId: String? = nil) -> [MemoryBenchRun] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { read(MemoryBenchRun.self, at: $0.appendingPathComponent("run.json")) }
            .filter { (writer == nil || $0.writer == writer) && (setId == nil || $0.set.id == setId) }
            .sorted { $0.at > $1.at }
    }

    public func appendRequests(_ requests: [MemoryBenchRequest], runId: String) throws {
        guard !requests.isEmpty else { return }
        let url = runDir(runId).appendingPathComponent("requests.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = (try? Data(contentsOf: url)) ?? Data()
        for r in requests {
            data.append(try MemoryBench.lineEncoder.encode(r))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    public func requests(runId: String) -> [MemoryBenchRequest] {
        guard let data = try? Data(contentsOf: runDir(runId).appendingPathComponent("requests.jsonl")) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? MemoryBench.decoder.decode(MemoryBenchRequest.self, from: Data($0)) }
    }

    /// 超过 keepLogDays 天、没钉住的跑：删完整日志 + 清掉 run.json 里每格的原始输出（条目、检查、用量、判断、分数留着）。
    /// 钉住的整份跳过；清过的不再动。返回清了几次跑
    @discardableResult
    public func pruneLogs(now: Date = Date(), keepDays: Int = keepLogDays) -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(keepDays) * 86400)
        var pruned = 0
        for var run in runs() where !run.pinned && run.at < cutoff && run.status != .running {
            let log = runDir(run.id).appendingPathComponent("requests.jsonl")
            let hasLog = FileManager.default.fileExists(atPath: log.path)
            let hasOutput = run.cells.contains { $0.output != nil }
            guard hasLog || hasOutput else { continue }
            if hasOutput {
                for i in run.cells.indices { run.cells[i].output = nil }
                run.outputsPrunedAt = MemoryBench.stamp(now)
                guard (try? saveRun(run)) != nil else { continue }
            }
            if hasLog { try? FileManager.default.removeItem(at: log) }
            pruned += 1
        }
        return pruned
    }

}
