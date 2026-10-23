import Foundation

// MARK: - 按天统计缓存：落盘（plan-calendar §2.2）
// Application Support/MemoryPalace/calendar/{profileId}/：manifest.json + convs/{convId}.json
// 本地、不进文件库、不进备份，丢了能重算。一个对话一个小文件，只写变了的。

struct ActivityManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = ActivityManifest.currentVersion
    /// 归日用的时区：变了就全量重算
    var timeZone = TimeZone.current.identifier
    /// 待重扫的对话
    var dirty: Set<String> = []
    /// 有删除但不知道是哪个对话 / 首次建立：下次刷新做一次节点数对账
    var needsReconcile = true
    /// 上次对账的日期（yyyy-MM-dd）：每天至少对账一次，兜住导入 / 恢复 / 同步补节点
    var reconciledDay: String?
}

struct ActivityCacheStore: Sendable {
    let root: URL

    static func defaultRoot(profileId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MemoryPalace/calendar", isDirectory: true)
            .appendingPathComponent(sanitize(profileId), isDirectory: true)
    }

    init(root: URL) { self.root = root }
    init(profileId: String) { self.root = Self.defaultRoot(profileId: profileId) }

    private var convsDir: URL { root.appendingPathComponent("convs", isDirectory: true) }
    private var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    static func sanitize(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
    }

    private func ensureDirs() {
        try? FileManager.default.createDirectory(at: convsDir, withIntermediateDirectories: true)
    }

    // MARK: manifest

    func loadManifest() -> ActivityManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(ActivityManifest.self, from: data)
    }

    func saveManifest(_ m: ActivityManifest) {
        ensureDirs()
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: manifestURL, options: .atomic) }
    }

    // MARK: 逐对话

    private func url(for convId: String) -> URL { convsDir.appendingPathComponent(Self.sanitize(convId) + ".json") }

    func save(_ c: ConversationContribution) {
        ensureDirs()
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: url(for: c.convId), options: .atomic) }
    }

    func remove(convId: String) {
        try? FileManager.default.removeItem(at: url(for: convId))
    }

    func loadAll() -> [String: ConversationContribution] {
        let files = (try? FileManager.default.contentsOfDirectory(at: convsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [String: ConversationContribution] = [:]
        let decoder = JSONDecoder()
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let c = try? decoder.decode(ConversationContribution.self, from: data) {
                out[c.convId] = c
            }
        }
        return out
    }

    /// 全量重建：删掉整个楼层目录
    func wipe() {
        try? FileManager.default.removeItem(at: root)
    }
}
