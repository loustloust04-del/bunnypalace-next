import Foundation

/// 记忆实验台的记录落盘（plan-memory-lab §3）：楼层记忆根下单独一格
///
///     <楼层记忆根>/lab/records/<编号>.json     一句一个文件
///     <楼层记忆根>/lab/sets/<编号>.json        一份测试集一个文件（`MemoryLabStore+Sets.swift`）
///     <楼层记忆根>/lab/params/<编号>.json      存下来的一组参数一个文件（`MemoryLabStore+Params.swift`）
///
/// 不自动清。一条里有整段提示词和她的原话：`lab/` 不进助手的文件工具、不进文件库列表、不带到电脑上给 CC
/// （app 侧 `FileLibraryStore.memoryUnlistedFolders`）。同步文件 IO，调用方放后台。
public struct MemoryLabStore: Sendable {
    public static let folderName = "lab"
    /// 这个版本认得的记录 / 测试集格式；比它新的能列出来，但不改写（免得丢掉看不懂的字段）
    public static let schema = 1

    public let root: URL

    public init(memoryRoot: URL) {
        root = memoryRoot.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    private var recordsDir: URL { root.appendingPathComponent("records", isDirectory: true) }
    var setsDir: URL { root.appendingPathComponent("sets", isDirectory: true) }
    var paramsDir: URL { root.appendingPathComponent("params", isDirectory: true) }

    private func url(_ id: String) -> URL {
        recordsDir.appendingPathComponent(MemoryBenchStore.fileName(id) + ".json")
    }

    public enum StoreError: LocalizedError, Equatable {
        case missing(String)
        case newerSchema(String)
        case missingSet(String)
        case newerSetSchema(String)
        case setExists(String)
        case missingParams(String)
        case newerParamsSchema(String)
        case paramsExists(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let id): return "找不到这条记录（\(id)）"
            case .newerSchema(let id): return "这条记录（\(id)）是新版本写的，这个版本不改它"
            case .missingSet(let id): return "找不到这份测试集（\(id)）"
            case .newerSetSchema(let id): return "这份测试集（\(id)）是新版本写的，这个版本不改它"
            case .setExists(let id): return "已经有这份测试集了（\(id)）"
            case .missingParams(let id): return "找不到这组参数（\(id)）"
            case .newerParamsSchema(let id): return "这组参数（\(id)）是新版本写的，这个版本不改它"
            case .paramsExists(let id): return "已经有这组参数了（\(id)）"
            }
        }
    }

    public func save(_ record: MemoryLabRecord) throws {
        try FileManager.default.createDirectory(at: recordsDir, withIntermediateDirectories: true)
        try MemoryBench.encoder.encode(record).write(to: url(record.id), options: .atomic)
    }

    /// 没有 / 读不成 = nil
    public func record(id: String) -> MemoryLabRecord? {
        read(url(id))
    }

    /// 全部，按说的先后（旧的在前，同一刻按编号）；读不成的跳过。整条都解码（提示词、回执），只在要整条时用
    public func records() -> [MemoryLabRecord] {
        recordFiles().compactMap(read)
            .sorted { $0.input.at != $1.input.at ? $0.input.at < $1.input.at : $0.id < $1.id }
    }

    /// 轻读全部：顺序同 `records()`，每条只解码编号 / 那句话 / `sentenceId` / 判断 / 回指。列表、计数用它，点开某一句再 `record(id:)`
    public func heads() -> [MemoryLabRecord.Head] {
        recordFiles().compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? MemoryBench.decoder.decode(MemoryLabRecord.Head.self, from: $0) }
        }.sorted { $0.input.at != $1.input.at ? $0.input.at < $1.input.at : $0.id < $1.id }
    }

    private func recordFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: recordsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    /// 改拇指 / 批注：只动 `judgment`，原地重写那一个文件。
    ///
    ///     try store.judge(id: record.id) { $0.verdict = .up }
    ///     try store.judge(id: record.id) { $0.note = "…" }
    @discardableResult
    public func judge(id: String, at: Date = MemoryBench.now(),
                      _ change: (inout MemoryLabRecord.Judgment) -> Void) throws -> MemoryLabRecord {
        guard var record = record(id: id) else { throw StoreError.missing(id) }
        guard (record.schema ?? 1) <= Self.schema else { throw StoreError.newerSchema(id) }
        var judgment = record.judgment ?? .init()
        change(&judgment)
        judgment.at = at
        record.judgment = judgment
        try save(record)
        return record
    }

    public struct Summary: Equatable, Sendable {
        /// 说过几句
        public var count: Int
        public var up: Int
        public var down: Int

        public init(count: Int = 0, up: Int = 0, down: Int = 0) {
            self.count = count
            self.up = up
            self.down = down
        }
    }

    public func summary() -> Summary {
        Self.summary(heads())
    }

    public static func summary(_ heads: [MemoryLabRecord.Head]) -> Summary {
        var out = Summary()
        for head in heads {
            out.count += 1
            switch head.judgment?.verdict {
            case .up: out.up += 1
            case .down: out.down += 1
            case nil: break
            }
        }
        return out
    }

    public static func summary(_ records: [MemoryLabRecord]) -> Summary {
        summary(records.map(MemoryLabRecord.Head.init))
    }

    private func read(_ url: URL) -> MemoryLabRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MemoryBench.decoder.decode(MemoryLabRecord.self, from: data)
    }
}
