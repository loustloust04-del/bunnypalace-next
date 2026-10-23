import Foundation
import CryptoKit
import Observation

/// 卡库 ⑧c 的本地文件存储（plan §1.1 末三行）。全部在 `Application Support/MemoryPalace/cardlibrary/` 下，
/// JSON 原子写，不进 UserDefaults；root 可注入（测试 / 临时库基准不碰真实目录）。
///
///     cardlibrary/
///       personas/personas.json          UserPersonaStore：[UserPersona]
///       personas/avatars/<id>.<ext>      头像原字节
///       imports/sources.json             ImportSourceStore：[ImportSource]（来源 → 相对路径 → 版本 → 目标 ID 集合 + 首次内容 hash）
///       imports/archive/<2位>/<sha256>   PackageArchive：原件按内容寻址，变化版本自然另存不覆盖
///       imports/reports/<batchId>.json   导入报告（撤回报告 <batchId>-retract.json）
///       imports/pending-batch.json       PendingImportBatch：未完成批次的完整目标清单，提交后删除
enum CardLibraryStorage {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("cardlibrary", isDirectory: true)
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 对象是从哪个导入来的（persona 等新对象自带；旧对象来源查 ImportSourceStore）
struct ImportOrigin: Codable, Hashable {
    var sourceId: String
    var batchId: String
    var relativePath: String
    var key: String?
}

// MARK: - UserPersonaStore

struct UserPersona: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var description: String = ""
    /// 相对 personas/ 目录（如 `avatars/<id>.png`）；nil = 没头像，显示首字
    var avatarAssetRef: String?
    /// 绑定的书：`global:<GlobalWorldBook.id>` / `floor:<WorldBook.id>` / `name:<源书名>`（包里没有这本书时）
    var worldSourceRefs: [String] = []
    /// 源记录原样（酒馆 power_user.personas[key] + persona_descriptions[key]）
    var rawJSONData: Data?
    var origin: ImportOrigin?
    var createdAt: Date = Date()
}

/// 身份库（plan §1.1）：只建存储与导入写入，不改现有身份 UI。读失败保留原文件并拒绝写入。
@Observable
final class UserPersonaStore {
    static let shared = UserPersonaStore()

    private(set) var personas: [UserPersona]
    @ObservationIgnored let directory: URL
    @ObservationIgnored private var loadError: Error?

    init(root: URL? = nil) {
        directory = (root ?? CardLibraryStorage.defaultRoot).appendingPathComponent("personas", isDirectory: true)
        do {
            let url = directory.appendingPathComponent("personas.json")
            personas = FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode([UserPersona].self, from: Data(contentsOf: url)) : []
        } catch {
            personas = []
            loadError = error
            NSLog("身份库读取失败，保留原文件并阻止覆盖：%@", error.localizedDescription)
        }
    }

    func avatarURL(_ persona: UserPersona) -> URL? {
        persona.avatarAssetRef.map { directory.appendingPathComponent($0) }
    }

    /// 头像先落盘，列表最后写；失败时清掉本次新写的头像
    func add(_ values: [UserPersona], avatars: [String: Data] = [:]) throws {
        if let loadError { throw loadError }
        var written: [URL] = []
        do {
            for persona in values {
                guard let ref = persona.avatarAssetRef, let data = avatars[persona.id] else { continue }
                let url = directory.appendingPathComponent(ref)
                try CardLibraryStorage.writeAtomically(data, to: url)
                written.append(url)
            }
            try persist(personas.filter { item in !values.contains { $0.id == item.id } } + values)
        } catch {
            written.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    func remove(ids: Set<String>) throws {
        if let loadError { throw loadError }
        let removed = personas.filter { ids.contains($0.id) }
        try persist(personas.filter { !ids.contains($0.id) })
        for persona in removed { if let url = avatarURL(persona) { try? FileManager.default.removeItem(at: url) } }
        // 列表里已不在、但头像文件残留的（列表写入前中断）
        for id in ids {
            let avatars = directory.appendingPathComponent("avatars", isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: avatars.path)) ?? [] where name.hasPrefix(id + ".") {
                try? FileManager.default.removeItem(at: avatars.appendingPathComponent(name))
            }
        }
    }

    private func persist(_ next: [UserPersona]) throws {
        try CardLibraryStorage.writeAtomically(try CardLibraryStorage.encoder.encode(next),
                                               to: directory.appendingPathComponent("personas.json"))
        personas = next
    }
}

// MARK: - 导入来源

/// 一个导入目标（「一文件多目标存集合」）。contentHash = 写入后首次内容 hash，撤回时据此判断改没改过
struct ImportTarget: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case card, floor, floorPreset, conversation, worldBook, globalWorldBook, preset, globalRegex, persona, attachment
    }

    var kind: Kind
    var id: String
    /// SwiftData 行 / 楼层附属对象所属楼层
    var profileId: String?
    var contentHash: String
    var retractedAt: Date?
}

struct ImportFileVersion: Codable, Hashable {
    enum Disposition: String, Codable {
        /// 新文件，按类别建了对象（targets 非空，或解析后无可建对象）
        case imported
        /// 只归档原字节（QR / 插件 / 未知 / backups / 辅助图 …）
        case archivedOnly
        /// 同路径内容变了：保留新版原件并报告，不覆盖、不再造一套
        case changedArchived
        /// 解析失败：原件已归档，可重试
        case failed
        /// 用户在盘点中排除：仍归档原件
        case excluded
    }

    var sha256: String
    var size: Int64
    var category: String
    var batchId: String
    var importedAt: Date
    var disposition: Disposition
    var targets: [ImportTarget] = []
}

struct ImportBatchSummary: Codable, Hashable {
    var id: String
    var date: Date
    var reportFile: String
    var retractedAt: Date?
}

struct ImportSource: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    /// 用户可见名（首次命名，重导选既有来源）
    var name: String
    var kind: String = "sillytavern"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// default-user 相对路径 → 版本（旧 → 新）
    var files: [String: [ImportFileVersion]] = [:]
    var batches: [ImportBatchSummary] = []

    func latest(_ relativePath: String) -> ImportFileVersion? { files[relativePath]?.last }

    /// 某路径历次导入建的、还没撤回的目标
    func liveTargets(_ relativePath: String) -> [ImportTarget] {
        (files[relativePath] ?? []).flatMap(\.targets).filter { $0.retractedAt == nil }
    }
}

/// 批次中断后要清 / 续的完整清单（plan §6.2-2）。确认落盘后才写任何对象。
struct PendingImportBatch: Codable {
    enum Phase: String, Codable {
        /// 正在写对象：中断 = 按清单清掉本批全部新增
        case writing
        /// 来源映射 / 报告已存：中断 = 幂等续完发布并删批次
        case committed
    }

    var id: String
    var sourceId: String
    var sourceIsNew: Bool
    var phase: Phase
    var createdAt: Date
    /// 本批新拷进归档的原件（之前没有的）；清理时只删这些
    var newArchiveBlobs: [String]
    /// 完整目标清单（全部预分配 ID）
    var targets: [ImportTarget]
    var reportFile: String
}

/// 来源清单 + 原件归档 + 报告 + 未完成批次，同一个 imports/ 目录
final class ImportSourceStore {
    static let shared = ImportSourceStore()

    let directory: URL
    private(set) var sources: [ImportSource]
    private var loadError: Error?

    init(root: URL? = nil) {
        directory = (root ?? CardLibraryStorage.defaultRoot).appendingPathComponent("imports", isDirectory: true)
        do {
            let url = directory.appendingPathComponent("sources.json")
            sources = FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode([ImportSource].self, from: Data(contentsOf: url)) : []
        } catch {
            sources = []
            loadError = error
            NSLog("导入来源读取失败，保留原文件并阻止覆盖：%@", error.localizedDescription)
        }
    }

    func source(id: String) -> ImportSource? { sources.first { $0.id == id } }

    func save(_ source: ImportSource) throws {
        var next = sources
        if let index = next.firstIndex(where: { $0.id == source.id }) { next[index] = source } else { next.append(source) }
        try persist(next)
    }

    func remove(sourceId: String) throws {
        try persist(sources.filter { $0.id != sourceId })
    }

    private func persist(_ next: [ImportSource]) throws {
        if let loadError { throw loadError }
        try CardLibraryStorage.writeAtomically(try CardLibraryStorage.encoder.encode(next),
                                               to: directory.appendingPathComponent("sources.json"))
        sources = next
    }

    // MARK: 原件归档（PackageArchive）

    var archiveDirectory: URL { directory.appendingPathComponent("archive", isDirectory: true) }

    /// 归档内相对 cardlibrary/ 的位置（报告里的「原件位置」）
    static func archivePath(_ sha256: String) -> String { "imports/archive/\(sha256.prefix(2))/\(sha256)" }

    func archiveURL(_ sha256: String) -> URL {
        archiveDirectory.appendingPathComponent(String(sha256.prefix(2)), isDirectory: true).appendingPathComponent(sha256)
    }

    func hasArchived(_ sha256: String) -> Bool { FileManager.default.fileExists(atPath: archiveURL(sha256).path) }

    /// 内容寻址：已有同 hash 不重拷；先拷临时名再改名，中断不留半截正式文件
    func archive(file: URL, sha256: String) throws {
        let target = archiveURL(sha256)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(sha256).\(UUID().uuidString).part")
        try FileManager.default.copyItem(at: file, to: temp)
        do { try FileManager.default.moveItem(at: temp, to: target) } catch {
            try? FileManager.default.removeItem(at: temp)
            if !FileManager.default.fileExists(atPath: target.path) { throw error }
        }
    }

    func removeArchived(_ shas: [String]) {
        for sha in shas { try? FileManager.default.removeItem(at: archiveURL(sha)) }
    }

    // MARK: 报告

    var reportsDirectory: URL { directory.appendingPathComponent("reports", isDirectory: true) }

    func writeReport<T: Encodable>(_ report: T, file: String) throws {
        try CardLibraryStorage.writeAtomically(try CardLibraryStorage.encoder.encode(report), to: reportsDirectory.appendingPathComponent(file))
    }

    func readReport<T: Decodable>(_ type: T.Type, file: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: reportsDirectory.appendingPathComponent(file)))
    }

    func removeReport(file: String) { try? FileManager.default.removeItem(at: reportsDirectory.appendingPathComponent(file)) }

    // MARK: 未完成批次

    var pendingBatchURL: URL { directory.appendingPathComponent("pending-batch.json") }

    func pendingBatch() throws -> PendingImportBatch? {
        guard FileManager.default.fileExists(atPath: pendingBatchURL.path) else { return nil }
        return try JSONDecoder().decode(PendingImportBatch.self, from: Data(contentsOf: pendingBatchURL))
    }

    func writePendingBatch(_ batch: PendingImportBatch) throws {
        try CardLibraryStorage.writeAtomically(try CardLibraryStorage.encoder.encode(batch), to: pendingBatchURL)
    }

    func removePendingBatch() throws {
        if FileManager.default.fileExists(atPath: pendingBatchURL.path) { try FileManager.default.removeItem(at: pendingBatchURL) }
    }
}
