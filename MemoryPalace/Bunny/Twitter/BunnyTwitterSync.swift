import Foundation
import SwiftData

// MARK: - [Bunny] 推特同步：网关 /api/tweets/pull → 上游 TwitterPullImporter
//
// 网关把记忆库里同步来的推文转成上游「拉取包」格式（audit/design-twitter.md）；这里拉下来写成临时
// twitter-pull.json，原样交给上游导入器：按真实 tweetId 幂等，之后再导官方存档会补全正文/回复/图片（上游逻辑）。
// 增量：记住上次拿到的最新记忆库时间（UTC），下次带 ?since=。

@MainActor
enum BunnyTwitterSync {
    static let sinceKey = "bunny.twitter.lastLatestTs"
    static let lastRunKey = "bunny.twitter.lastRunAt"

    static var lastRunAt: Date? { UserDefaults.standard.object(forKey: lastRunKey) as? Date }

    /// 距上次 ≥ minInterval 才跑（给自动触发用）
    static func runIfDue(profileId: String, context: ModelContext, minInterval: TimeInterval = 30 * 60) async -> String? {
        guard BunnyGateway.isConfigured, !profileId.isEmpty else { return nil }
        if let last = lastRunAt, Date().timeIntervalSince(last) < minInterval { return nil }
        return try? await run(profileId: profileId, context: context)
    }

    /// full = true 时忽略增量，整包重拉（导入器幂等，不会重复）
    @discardableResult
    static func run(profileId: String, context: ModelContext, full: Bool = false) async throws -> String {
        var path = "/api/tweets/pull"
        if !full, let since = UserDefaults.standard.string(forKey: sinceKey),
           let q = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?since=" + q
        }
        let data = try await BunnyGateway.get(path, timeout: 60)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let count = (obj?["tweets"] as? [Any])?.count ?? 0
        let latest = (obj?["bunny"] as? [String: Any])?["latestTs"] as? String
        UserDefaults.standard.set(Date(), forKey: lastRunKey)
        guard count > 0 else { return "没有新推文" }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("bunny-twitter-pull-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let manifest = dir.appendingPathComponent("twitter-pull.json")
        try data.write(to: manifest)
        let r = try TwitterPullImporter.importPull(manifest: manifest, profileId: profileId, context: context,
                                                   mediaRoot: TwitterArchiveImporter.defaultMediaRoot())
        try? context.save()
        if let latest { UserDefaults.standard.set(latest, forKey: sinceKey) }
        return "拉到 \(count) 条，新增 \(r.tweetsImported) 条，已存在 \(r.tweetsSkipped) 条"
    }
}
