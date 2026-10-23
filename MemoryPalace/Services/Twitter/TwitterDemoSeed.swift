import Foundation
import SwiftData
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 示例数据：没有真存档时先让界面有东西看。
///
/// 所有示例推的 id 都是**确定的** `demo-N`，清理时按这批 id 精确删——
/// 这样「清示例」永远不会误伤真存档里的推（真推的 id 是推特的雪花号）。
enum TwitterDemoSeed {

    /// 示例账号的 accountId。真账号不会长这样，清理时靠它区分。
    static let demoAccountId = "demo-account"

    private struct Sample {
        let n: Int
        let text: String
        let hoursAgo: Double
        var favorite = 0
        var retweet = 0
        var replyTo: String? = nil
        var tags = ""
        var hasMedia = false
    }

    private static let samples: [Sample] = [
        Sample(n: 1, text: "存档导进来之后，这里就是你自己的时间线了。\n这几条是示例，随时可以清掉。",
               hoursAgo: 1, favorite: 12, retweet: 3, hasMedia: true),
        Sample(n: 2, text: "带图的推长这样——一张给大图，多张会排成两列网格。",
               hoursAgo: 5, favorite: 4),
        Sample(n: 3, text: "这条是回复，正文上面会多一行灰字。",
               hoursAgo: 26, replyTo: "someone"),
        Sample(n: 4, text: "话题标签会用薄荷绿标出来，点开详情能看到全部。",
               hoursAgo: 50, favorite: 31, retweet: 8, tags: "示例 页面二"),
        Sample(n: 5, text: "搜索框搜的是正文和话题标签，结果不分页、一次给全。",
               hoursAgo: 80, favorite: 2),
        Sample(n: 6, text: "顶上那行小字是推文总数和时间跨度，导入后会跟着真数据走。",
               hoursAgo: 140),
        Sample(n: 7, text: "往下滑会自动翻页，一次取一屏，不会一口气把几万条全拉出来。",
               hoursAgo: 200, favorite: 7),
        Sample(n: 8, text: "这是最早的一条示例。", hoursAgo: 400, retweet: 1),
    ]

    private static var demoIds: [String] { samples.map { "demo-\($0.n)" } }
    private static let mediaFileName = "demo-sample.png"

    // MARK: - 查询

    static func isInstalled(profileId: String, context: ModelContext) throws -> Bool {
        let ids = demoIds
        return try context.fetchCount(FetchDescriptor<TweetEntry>(
            predicate: #Predicate { $0.profileId == profileId && ids.contains($0.tweetId) })) > 0
    }

    // MARK: - 装 / 清

    static func install(profileId: String, context: ModelContext, mediaRoot: URL? = nil) throws {
        // 重复点「看看样子」不能越点越多
        guard try !isInstalled(profileId: profileId, context: context) else { return }

        let dir = (mediaRoot ?? TwitterArchiveImporter.defaultMediaRoot())
            .appendingPathComponent(profileId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 占位图要真落盘，不然媒体位置只是个空块，看不出布局
        if let png = placeholderPNG() {
            try? png.write(to: dir.appendingPathComponent(mediaFileName), options: .atomic)
        }

        let now = Date()
        // 示例推文挂在当前账号上；楼层里还没账号就挂在下面新建的示例账号上
        let owner = TwitterAccounts.active(profileId: profileId, context: context)?.accountId ?? demoAccountId
        for s in samples {
            let id = "demo-\(s.n)"
            let entry = TweetEntry(
                profileId: profileId, tweetId: id, text: s.text,
                createdAt: now.addingTimeInterval(-s.hoursAgo * 3600),
                favoriteCount: s.favorite, retweetCount: s.retweet,
                inReplyToTweetId: s.replyTo == nil ? nil : "demo-1",
                inReplyToScreenName: s.replyTo,
                hashtagsJoined: s.tags,
                mediaCount: s.hasMedia ? 1 : 0)
            entry.accountId = owner
            context.insert(entry)
            if s.hasMedia {
                context.insert(TweetMedia(profileId: profileId, tweetId: id, mediaId: "demo-m\(s.n)",
                                          kind: "photo", fileName: mediaFileName,
                                          width: 1200, height: 800))
            }
        }

        // 已经有真账号就别动它
        let existing = try context.fetch(FetchDescriptor<TwitterArchiveAccount>(
            predicate: #Predicate { $0.profileId == profileId }))
        if existing.isEmpty {
            context.insert(TwitterArchiveAccount(
                profileId: profileId, accountId: demoAccountId,
                screenName: "demo", displayName: "示例账号",
                bio: "这是示例数据，导入真存档后可以清掉。",
                sourceName: "示例"))
        }
        try context.save()
    }

    static func remove(profileId: String, context: ModelContext) throws {
        let ids = demoIds
        for row in try context.fetch(FetchDescriptor<TweetEntry>(
            predicate: #Predicate { $0.profileId == profileId && ids.contains($0.tweetId) })) {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<TweetMedia>(
            predicate: #Predicate { $0.profileId == profileId && ids.contains($0.tweetId) })) {
            context.delete(row)
        }
        // 只清示例自己造的那个账号，真账号留着。
        // 示例账号被手动编辑过（editedAt 非空）就已经是粟粟自己的了：留下、脱掉示例身份。
        // 示例账号名下粟粟自己发的推要跟着走：账号留下就改挂新 id；账号删了就清成空，
        // 由 `TwitterAccounts.adoptOrphans` 归给下一个当前账号——不然它们挂在一个不存在的账号上，谁也看不见。
        let demoId = demoAccountId
        for row in try context.fetch(FetchDescriptor<TwitterArchiveAccount>(
            predicate: #Predicate { $0.profileId == profileId && $0.accountId == demoId })) {
            let heir = row.editedAt != nil ? "local-" + UUID().uuidString : ""
            for t in try context.fetch(FetchDescriptor<TweetEntry>(predicate: #Predicate {
                $0.profileId == profileId && $0.accountId == demoId
            })) { t.accountId = heir }
            if row.editedAt != nil { row.accountId = heir } else { context.delete(row) }
        }
        try context.save()
    }

    // MARK: - 占位图

    /// 用 CoreGraphics + ImageIO 直接出 PNG：跨平台一套代码，不碰 AppKit/UIKit 分叉。
    /// 颜色取项目的薄荷绿 #8EBD9F，跟强调色一致。
    private static func placeholderPNG(width: Int = 600, height: Int = 400) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: 0x8E / 255, green: 0xBD / 255, blue: 0x9F / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 中间压一道浅色横条，免得纯色看不出是不是没加载出来
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.28)
        ctx.fill(CGRect(x: 0, y: height / 2 - 18, width: width, height: 36))

        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
