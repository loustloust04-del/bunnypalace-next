import Foundation
import CryptoKit

/// A4 编辑器版本历史：每次保存存一份全文快照（不用 git，见 docs/plan-uiux-editor-tavern-ia.md A4）。
/// 落 Application Support/MemoryPalace/versions/<楼层 id 或 global>/<编码后的 key>/：index.json（旧→新）+ 每版一个 <id>.txt。
/// 不在 iCloud 容器里；GlobalExporter 按子目录白名单拷，不扫 versions/。root 可注入，测试走临时目录。
actor FileVersionStore {
    static let shared = FileVersionStore()
    static let maxVersions = 100

    enum Source: String, Codable, Sendable {
        case manualSave, autoSave, external, restore
    }

    struct Key: Hashable, Sendable {
        let scope: String
        let name: String

        /// 文件库真文件：楼层 id + 库内相对路径
        static func file(profileId: String, relativePath: String) -> Key {
            var path = Substring(relativePath)
            while path.hasPrefix("/") { path = path.dropFirst() }
            return Key(scope: profileId, name: "fs/" + path)
        }

        /// 虚拟文件（角色卡字段 / 世界书条目 / 预设插槽）：调用方给稳定字符串，如 card/<cardId>/description；不属于楼层的落 global
        static func virtual(_ name: String, profileId: String? = nil) -> Key {
            Key(scope: profileId ?? "global", name: "vf/" + name)
        }

        /// 角色卡长字段（卡不属于楼层）；field 用 CharacterCard 的属性名
        static func cardField(cardId: String, field: String) -> Key {
            virtual("card/\(cardId)/\(field)")
        }

        /// 世界书条目正文：bookId 同 WorldBookListItem.bookId（全局书 id / 楼层书 uuid），卡库和旧面板同一份历史
        static func worldBookEntry(bookId: String, entryId: UUID) -> Key {
            virtual("worldbook/\(bookId)/\(entryId.uuidString)")
        }

        /// 楼层编辑里的系统指令
        static func floorSystemPrompt(profileId: String) -> Key {
            virtual("floor/\(profileId)/systemPrompt", profileId: profileId)
        }
    }

    struct Version: Codable, Equatable, Sendable {
        let id: String
        let date: Date
        let source: Source
        let bytes: Int
        let sha256: String
    }

    enum StoreError: Error {
        case keyCollision
    }

    private struct Index: Codable {
        var scope: String
        var name: String
        var versions: [Version]
    }

    private static let indexFileName = "index.json"
    private static let tempPrefix = ".tmp-"

    nonisolated let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL? = nil) {
        self.root = root ?? AppPaths.checked(AppPaths.applicationSupport
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true))
    }

    // MARK: - API

    /// 和最新一版内容相同返回 nil 不记；超过 maxVersions 删最老
    @discardableResult
    func record(key: Key, content: String, source: Source) throws -> Version? {
        let dir = directory(for: key)
        var index = try loadIndex(key: key, dir: dir) ?? Index(scope: key.scope, name: key.name, versions: [])
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if index.versions.last?.sha256 == hash { return nil }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let version = Version(id: UUID().uuidString.lowercased(), date: Date(), source: source,
                              bytes: data.count, sha256: hash)
        try Self.writeAtomically(data, to: contentURL(dir: dir, id: version.id))
        index.versions.append(version)
        let overflow = max(0, index.versions.count - Self.maxVersions)
        let dropped = index.versions.prefix(overflow)
        index.versions.removeFirst(overflow)
        try Self.writeAtomically(try encoder.encode(index), to: AppPaths.checked(dir.appendingPathComponent(Self.indexFileName)))
        // 先落 index 再删：中途崩了只多几个孤儿 .txt，不会出现 index 指向不存在的版本
        for old in dropped { try? FileManager.default.removeItem(at: contentURL(dir: dir, id: old.id)) }
        return version
    }

    /// 新→旧
    func versions(key: Key) throws -> [Version] {
        try loadIndex(key: key, dir: directory(for: key))?.versions.reversed() ?? []
    }

    func content(key: Key, id: String) throws -> String? {
        let dir = directory(for: key)
        // id 只认 index 里有的，外部传的 id 不拼进路径
        guard let index = try loadIndex(key: key, dir: dir),
              let version = index.versions.first(where: { $0.id == id }) else { return nil }
        let url = contentURL(dir: dir, id: version.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func delete(key: Key) throws {
        let dir = directory(for: key)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - 路径

    nonisolated func directory(for key: Key) -> URL {
        AppPaths.checked(root.appendingPathComponent(Self.encodeComponent(key.scope), isDirectory: true)
            .appendingPathComponent(Self.encodeComponent(key.name), isDirectory: true))
    }

    private func contentURL(dir: URL, id: String) -> URL {
        AppPaths.checked(dir.appendingPathComponent(id + ".txt"))
    }

    /// 目录名编码：只留 [a-z0-9_-]，其余字节（含大写、`.`、`/`、`%`）一律 %XX 大写十六进制。
    /// 结果不含 `/`、`.`，大小写不敏感的文件系统上也不撞；过长截断 + `~` + sha256（`~` 不会出现在普通编码里）。
    static func encodeComponent(_ raw: String) -> String {
        guard !raw.isEmpty else { return "%" }
        var out = ""
        for byte in raw.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        guard out.utf8.count > 200 else { return out }
        var head = String(out.prefix(120))
        if let pct = head.lastIndex(of: "%"), head.distance(from: pct, to: head.endIndex) < 3 {
            head = String(head[..<pct])
        }
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return head + "~" + digest
    }

    // MARK: - 读写

    /// 没有 → nil；有但读不通 → 抛，调用方不拿空 index 覆盖
    private func loadIndex(key: Key, dir: URL) throws -> Index? {
        let url = AppPaths.checked(dir.appendingPathComponent(Self.indexFileName))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let index = try decoder.decode(Index.self, from: Data(contentsOf: url))
        guard index.scope == key.scope, index.name == key.name else { throw StoreError.keyCollision }
        return index
    }

    /// 同目录写临时文件再 rename(2)，读者要么看到旧文件要么看到新文件
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(tempPrefix + UUID().uuidString)
        do {
            try data.write(to: tmp)
            guard rename(tmp.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
