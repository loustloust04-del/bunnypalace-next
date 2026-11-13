import Foundation
import SwiftData

// MARK: - [Bunny] 推特同步：网关 /api/tweets/pull → 上游 TwitterPullImporter
//
// 网关把记忆库里同步来的推文转成上游「拉取包」格式（audit/design-twitter.md）；这里拉下来写成临时
// twitter-pull.json，原样交给上游导入器：按真实 tweetId 幂等，之后再导官方存档会补全正文/回复/图片（上游逻辑）。
// 增量：记住上次拿到的最新记忆库时间（UTC），下次带 ?since=。

enum BunnyTwitterSync {   // [Bunny 11-13] 去掉 @MainActor：由后台上下文调用

    /// [Bunny 11-13] 后台上下文版本（导入上千条推文不占主线程）
    static func runInBackground(container: ModelContainer, profileId: String, full: Bool = false) async throws -> String {
        try await Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            return try await run(profileId: profileId, context: ctx, full: full)
        }.value
    }
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

        if full { purgePulledTweets(profileId: profileId, context: context) }

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

    /// 整包重同步前清掉「只从网关拉来」的推文：只动占位账号（pull- 前缀）名下的推文，
    /// 导过官方存档的真账号不受影响。用于修正早期网关接口的编号错误（11-07：回复推文撞号）。
    private static func purgePulledTweets(profileId: String, context: ModelContext) {
        let pid = profileId
        let all = (try? context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate { $0.profileId == pid }))) ?? []
        var removed = 0
        for t in all where t.accountId.hasPrefix(TwitterPullImporter.pulledAccountPrefix) {
            context.delete(t); removed += 1
        }
        if removed > 0 { try? context.save() }
        UserDefaults.standard.removeObject(forKey: sinceKey)
    }
}
