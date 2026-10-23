import XCTest
import SwiftData
import ZIPFoundation
@testable import 记忆花园

/// 导入管线的特征测试。用真 fixture 走完整链路：解包 → 定位 → 解析 → 分批写库 → 媒体落盘。
final class TwitterArchiveImporterTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sandbox: URL!          // 每个用例一个临时根，媒体落这里不碰真实 Application Support
    private let floorA = "xctest-imp-a"
    private let floorB = "xctest-imp-b"

    private var fixture: URL {
        get throws {
            try XCTUnwrap(Bundle(for: Self.self).url(forResource: "twitter-archive", withExtension: nil))
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: TweetEntry.self, TweetMedia.self, TwitterArchiveAccount.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tw-imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        context = nil; container = nil; sandbox = nil
        try super.tearDownWithError()
    }

    private func runImport(_ source: URL, floor: String) async throws -> TwitterImportResult {
        try await TwitterArchiveImporter.importArchive(
            at: source, profileId: floor, context: context, mediaRoot: sandbox
        )
    }

    private func tweets(_ floor: String) throws -> [TweetEntry] {
        try context.fetch(TwitterQueries.timeline(profileId: floor, limit: 1000))
    }

    /// 数总行数**不能**走 `timeline`——它带 fetchLimit，数出来永远不超过 limit。
    /// （实测踩过：1200 条的批次测试一直报 1000，查了半天是这里。）
    private func tweetCount(_ floor: String) throws -> Int {
        try context.fetchCount(FetchDescriptor<TweetEntry>(
            predicate: #Predicate { $0.profileId == floor }))
    }

    func testImportsFolderArchive() async throws {
        let r = try await runImport(try fixture, floor: floorA)
        XCTAssertEqual(r.tweetsImported, 3)
        XCTAssertEqual(try tweets(floorA).map(\.tweetId).sorted(),
                       ["1000000000000000001", "1000000000000000002", "1000000000000000003"])
    }

    func testImportsZipArchive() async throws {
        let zip = sandbox.appendingPathComponent("archive.zip")
        try FileManager.default.zipItem(at: try fixture, to: zip, shouldKeepParent: true)
        let r = try await runImport(zip, floor: floorA)
        XCTAssertEqual(r.tweetsImported, 3, "zip 和文件夹两种入口都要吃")
    }

    func testMapsFieldsIncludingFlattenedEntities() async throws {
        _ = try await runImport(try fixture, floor: floorA)
        let first = try XCTUnwrap(try tweets(floorA).first { $0.tweetId == "1000000000000000001" })
        XCTAssertEqual(first.favoriteCount, 12)
        XCTAssertEqual(first.retweetCount, 3)
        XCTAssertEqual(first.hashtagsJoined, "测试")
        XCTAssertEqual(first.mentionsJoined, "someone")
        XCTAssertEqual(first.urlsJoined, "https://example.com/post")
        XCTAssertEqual(first.mediaCount, 0)
    }

    func testMapsReplyAndMediaCount() async throws {
        _ = try await runImport(try fixture, floor: floorA)
        let reply = try XCTUnwrap(try tweets(floorA).first { $0.tweetId == "1000000000000000002" })
        XCTAssertEqual(reply.inReplyToTweetId, "1000000000000000001")
        let withMedia = try XCTUnwrap(try tweets(floorA).first { $0.tweetId == "1000000000000000003" })
        XCTAssertEqual(withMedia.mediaCount, 1)
    }

    func testCopiesMediaFileIntoMediaRoot() async throws {
        let r = try await runImport(try fixture, floor: floorA)
        XCTAssertEqual(r.mediaCopied, 1)
        let rows = try context.fetch(FetchDescriptor<TweetMedia>())
        let media = try XCTUnwrap(rows.first)
        XCTAssertEqual(media.tweetId, "1000000000000000003")
        let onDisk = sandbox.appendingPathComponent(floorA).appendingPathComponent(media.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path),
                      "媒体要落到 mediaRoot/<profileId>/ 下，路径：\(onDisk.path)")
    }

    func testImportsTwitterStyleZip64Archive() async throws {
        // 真导出包的写法（全 ZIP64、首条偏移 0）。ZIPFoundation 读它是 0 个文件，粟粟真存档就是这么挂的
        let zip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "twitter-zip", withExtension: nil))
            .appendingPathComponent("twitter-style.zip")
        let r = try await runImport(zip, floor: floorA)
        XCTAssertEqual(r.tweetsImported, 3)
        XCTAssertEqual(r.mediaCopied, 1)
        XCTAssertNotNil(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).first?.avatarFileName)
    }

    func testUsesFullTextFromNoteTweets() async throws {
        // 长推在 tweets.js 里只有前半截，全文在 note-tweet.js（粟粟存档里有 8 条）
        _ = try await runImport(try fixture, floor: floorA)
        let t = try XCTUnwrap(try tweets(floorA).first { $0.tweetId == "1000000000000000002" })
        XCTAssertEqual(t.text, "回复别人的推文，其实后面还有很长一段 & 结尾")
    }

    func testStoresRetweetAuthor() async throws {
        let dir = sandbox.appendingPathComponent("rt/data")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"window.YTD.account.part0 = [{"account":{"accountId":"1","username":"me"}}]"#.utf8)
            .write(to: dir.appendingPathComponent("account.js"))
        try Data(#"""
        window.YTD.tweets.part0 = [{"tweet":{"id_str":"50","full_text":"RT @alice: 原文…",
          "created_at":"Wed Oct 10 20:19:24 +0000 2018","favorite_count":"0","retweet_count":"4",
          "entities":{"user_mentions":[{"screen_name":"alice","name":"爱丽丝"}]}}}]
        """#.utf8).write(to: dir.appendingPathComponent("tweets.js"))
        _ = try await runImport(dir.deletingLastPathComponent(), floor: floorA)
        let t = try XCTUnwrap(try tweets(floorA).first)
        XCTAssertEqual(t.retweetedScreenName, "alice")
        XCTAssertEqual(t.retweetedName, "爱丽丝")
        XCTAssertEqual(t.text, "原文…")
    }

    func testImportsAccountAndProfile() async throws {
        _ = try await runImport(try fixture, floor: floorA)
        let acc = try XCTUnwrap(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).first)
        XCTAssertEqual(acc.screenName, "susu_test")
        XCTAssertEqual(acc.displayName, "禾禾")
        XCTAssertEqual(acc.bio, "测试用的简介 with an = sign")
        XCTAssertEqual(acc.profileId, floorA)
    }

    func testImportsAvatarAndBannerFromProfileMedia() async throws {
        // 存档的 profile.js 只给远端 URL，但 data/profile_media/ 里有原图。
        // 不联网，所以头像只能从这里拿。
        _ = try await runImport(try fixture, floor: floorA)
        let acc = try XCTUnwrap(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).first)

        let avatar = try XCTUnwrap(acc.avatarFileName, "头像文件名要落库")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent(floorA).appendingPathComponent(avatar).path),
            "头像要落到 mediaRoot/<profileId>/ 下")

        let banner = try XCTUnwrap(acc.bannerFileName, "横幅文件名要落库")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent(floorA).appendingPathComponent(banner).path))
        XCTAssertNotEqual(avatar, banner, "头像和横幅不能认成同一个文件")
    }

    func testReimportKeepsHandEditedProfile() async throws {
        // 粟粟在应用里改过的名字/简介/头像，重新导入存档不能被冲回去
        _ = try await runImport(try fixture, floor: floorA)
        try TwitterProfileEditor.save(
            TwitterProfileDraft(displayName: "改过的名", screenName: "susu_test", bio: "改过的简介",
                                location: "", website: ""),
            avatar: Data([7]), profileId: floorA, context: context,
            mediaDir: sandbox.appendingPathComponent(floorA))
        let editedAvatar = try XCTUnwrap(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).first?.avatarFileName)

        _ = try await runImport(try fixture, floor: floorA)
        let acc = try XCTUnwrap(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).first)
        XCTAssertEqual(acc.displayName, "改过的名")
        XCTAssertEqual(acc.bio, "改过的简介")
        XCTAssertEqual(acc.avatarFileName, editedAvatar)
    }

    func testArchiveWinsOverEditsMadeToADifferentAccount() async throws {
        // 粟粟 2026-09-24 真机：先在示例账号上试过编辑资料，再导真存档，结果真资料全被「别覆盖手改」挡掉了。
        // 手改保护只该护着**同一个账号**的重新导入
        let demo = TwitterArchiveAccount(profileId: floorA, accountId: TwitterDemoSeed.demoAccountId,
                                         screenName: "demo", displayName: "示例里改过的名")
        demo.editedAt = Date()
        context.insert(demo)
        try context.save()

        _ = try await runImport(try fixture, floor: floorA)
        let rows = try context.fetch(FetchDescriptor<TwitterArchiveAccount>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].displayName, "禾禾")
        XCTAssertEqual(rows[0].screenName, "susu_test")
        XCTAssertEqual(rows[0].bio, "测试用的简介 with an = sign")
        XCTAssertNotNil(rows[0].avatarFileName)
        XCTAssertNotNil(rows[0].bannerFileName)
        XCTAssertNil(rows[0].editedAt, "换成存档资料后就不再算手改过")
    }

    func testRestoreFromArchiveUndoesHandEdits() async throws {
        // 已经被挡住的情况（粟粟手机上现在就是）：编辑页一键恢复成存档里的
        _ = try await runImport(try fixture, floor: floorA)
        let original = try XCTUnwrap(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).first)
        let avatar = original.avatarFileName
        try TwitterProfileEditor.save(
            TwitterProfileDraft(displayName: "改过", screenName: "x", bio: "改过", location: "", website: ""),
            avatar: Data([1]), profileId: floorA, context: context, mediaDir: sandbox.appendingPathComponent(floorA))

        XCTAssertTrue(TwitterProfileEditor.canRestoreFromArchive(profileId: floorA, context: context))
        try TwitterProfileEditor.restoreFromArchive(profileId: floorA, context: context)
        let acc = try XCTUnwrap(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).first)
        XCTAssertEqual(acc.displayName, "禾禾")
        XCTAssertEqual(acc.screenName, "susu_test")
        XCTAssertEqual(acc.bio, "测试用的简介 with an = sign")
        XCTAssertEqual(acc.avatarFileName, avatar)
        XCTAssertNil(acc.editedAt)
    }

    func testCannotRestoreWithoutAnImportedArchive() throws {
        try TwitterProfileEditor.save(
            TwitterProfileDraft(displayName: "只发过推", screenName: "", bio: "", location: "", website: ""),
            profileId: floorA, context: context, mediaDir: sandbox)
        XCTAssertFalse(TwitterProfileEditor.canRestoreFromArchive(profileId: floorA, context: context))
    }

    func testSurvivesArchiveWithoutProfileMedia() async throws {
        // 有些存档没有 profile_media/，不能因此报错
        let stripped = sandbox.appendingPathComponent("no-pm")
        try FileManager.default.copyItem(at: try fixture, to: stripped)
        try FileManager.default.removeItem(at: stripped.appendingPathComponent("data/profile_media"))
        _ = try await runImport(stripped, floor: floorB)
        let acc = try XCTUnwrap(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).first)
        XCTAssertNil(acc.avatarFileName)
    }

    func testIsIdempotent() async throws {
        _ = try await runImport(try fixture, floor: floorA)
        let second = try await runImport(try fixture, floor: floorA)
        XCTAssertEqual(try tweetCount(floorA), 3, "同一份存档导两次不能翻倍")
        XCTAssertEqual(second.tweetsImported, 0)
        XCTAssertEqual(second.tweetsSkipped, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TweetMedia>()).count, 1, "媒体也不能翻倍")
        XCTAssertEqual(try context.fetch(FetchDescriptor<TwitterArchiveAccount>()).count, 1,
                       "账号是一楼层一条，不能累积")
    }

    func testFloorsAreIndependent() async throws {
        _ = try await runImport(try fixture, floor: floorA)
        _ = try await runImport(try fixture, floor: floorB)
        XCTAssertEqual(try tweetCount(floorA), 3)
        XCTAssertEqual(try tweetCount(floorB), 3, "另一个楼层要能独立导同一份存档")
    }

    /// 分批写库（每 500 条落一次）在小 fixture 上跑不出来，用合成存档压一下。
    func testImportsMoreThanOneBatch() async throws {
        let synthetic = sandbox.appendingPathComponent("big")
        let data = synthetic.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let rows = (0..<1200).map { i in
            """
            {"tweet":{"id_str":"9\(String(format: "%06d", i))","full_text":"合成第 \(i) 条",\
            "created_at":"Wed Oct 10 20:19:24 +0000 2018","favorite_count":"0","retweet_count":"0"}}
            """
        }.joined(separator: ",\n")
        try "window.YTD.tweets.part0 = [\n\(rows)\n]".write(to: data.appendingPathComponent("tweets.js"),
                                                             atomically: true, encoding: .utf8)
        // 探针：先确认合成文件本身解得出 1200 条，把「解析器问题」和「导入器问题」切开
        let parsed = try TwitterArchiveReader.parseTweets(
            Data(contentsOf: data.appendingPathComponent("tweets.js")))
        XCTAssertEqual(parsed.count, 1200, "合成文件本身就该解出 1200 条")
        XCTAssertEqual(Set(parsed.map(\.id)).count, 1200, "合成的 id 必须互不相同")

        let r = try await runImport(synthetic, floor: floorA)
        XCTAssertEqual(r.tweetsImported + r.tweetsSkipped, 1200, "进+跳 必须等于总数，不能凭空少")
        XCTAssertEqual(r.tweetsImported, 1200, "跨批次不能丢条目")
        XCTAssertEqual(try tweetCount(floorA), 1200)
    }

    func testReportsProgressPhasesInOrder() async throws {
        // 大存档要导好几分钟，没有阶段反馈 UI 看着像卡死
        let recorded = Recorder()
        _ = try await TwitterArchiveImporter.importArchive(
            at: try fixture, profileId: floorA, context: context, mediaRoot: sandbox,
            onProgress: { phase, fraction in recorded.add(phase, fraction) })

        XCTAssertEqual(recorded.phases, [.parse, .finish], "文件夹入口没有解包阶段")
        XCTAssertTrue(recorded.fractions.allSatisfy { $0 >= 0 && $0 <= 1 }, "进度必须落在 0...1")
        XCTAssertEqual(recorded.fractions.last, 1.0, "结束时要给满格，不然进度条永远差一点")
    }

    func testReportsUnzipPhaseForZipInput() async throws {
        let zip = sandbox.appendingPathComponent("archive.zip")
        try FileManager.default.zipItem(at: try fixture, to: zip, shouldKeepParent: true)
        let recorded = Recorder()
        _ = try await TwitterArchiveImporter.importArchive(
            at: zip, profileId: floorA, context: context, mediaRoot: sandbox,
            onProgress: { phase, fraction in recorded.add(phase, fraction) })
        XCTAssertEqual(recorded.phases.first, .unzip, "zip 入口第一段是解包")
    }

    /// 回调跨线程来，计数要加锁
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [TwitterImportPhase] = []
        private var values: [Double] = []
        func add(_ p: TwitterImportPhase, _ f: Double) {
            lock.lock(); defer { lock.unlock() }
            if seen.last != p { seen.append(p) }
            values.append(f)
        }
        var phases: [TwitterImportPhase] { lock.lock(); defer { lock.unlock() }; return seen }
        var fractions: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testThrowsWhenArchiveHasNoDataDirectory() async throws {
        let empty = sandbox.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        do {
            _ = try await runImport(empty, floor: floorA)
            XCTFail("没有 data/ 的目录应该报错，而不是静默导入 0 条")
        } catch {
            XCTAssertEqual(error as? TwitterArchiveError, .noArchiveData)
        }
    }
}
