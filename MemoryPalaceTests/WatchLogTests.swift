import XCTest
@testable import 记忆花园

/// plan-cinema-app §2：认片（视频 id 规范化）、记进度、继续看、回填、上限
@MainActor
final class WatchLogTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("watchlog-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testItemKeys() throws {
        let bili = try XCTUnwrap(WatchLog.item(for: URL(string: "https://m.bilibili.com/video/BV1xx411c7mD?p=2&share=1")!, title: "猫猫_哔哩哔哩_bilibili"))
        XCTAssertEqual(bili.key, "bili:BV1xx411c7mD#2")
        XCTAssertEqual(bili.source, .bilibili)
        XCTAssertEqual(bili.title, "猫猫")
        // 嵌入页和原视频页是同一部
        let embed = try XCTUnwrap(WatchLog.item(for: URL(string: "https://player.bilibili.com/player.html?bvid=BV1xx411c7mD&p=2&t=30")!))
        XCTAssertEqual(embed.key, bili.key)
        XCTAssertEqual(embed.url, "https://www.bilibili.com/video/BV1xx411c7mD/?p=2")

        let yt = try XCTUnwrap(WatchLog.item(for: URL(string: "https://youtu.be/dQw4w9WgXcQ?t=42")!, title: "Song - YouTube"))
        XCTAssertEqual(yt.key, "yt:dQw4w9WgXcQ")
        XCTAssertEqual(yt.title, "Song")
        XCTAssertEqual(yt.defaultCover, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")

        // 直链：去参数（签名 / 过期时间变了还是同一部）
        let a = try XCTUnwrap(WatchLog.item(for: URL(string: "https://cdn.example.com/films/a.mp4?sign=1")!))
        let b = try XCTUnwrap(WatchLog.item(for: URL(string: "https://cdn.example.com/films/a.mp4?sign=2")!))
        XCTAssertEqual(a.key, "url:cdn.example.com/films/a.mp4")
        XCTAssertEqual(a.key, b.key)
        XCTAssertEqual(a.source, .link)
        XCTAssertEqual(a.title, "a.mp4")

        // 普通网页：只有确实在放视频才记
        XCTAssertNil(WatchLog.item(for: URL(string: "https://example.com/post/1")!))
        XCTAssertEqual(WatchLog.item(for: URL(string: "https://example.com/post/1?x=1")!, pageWithVideo: true)?.key, "url:example.com/post/1")
        XCTAssertNil(WatchLog.item(for: URL(string: "file:///tmp/a.mp4")!))

        // 浏览历史里的假标题当没有
        XCTAssertEqual(WatchLog.item(for: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, title: "YouTube")?.title, "")
        XCTAssertEqual(WatchLog.item(for: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!, title: "wplayer embedded player")?.title, "")
        XCTAssertEqual(WatchLog.fileItem(name: "瑞克和莫蒂 S1E1.mkv").key, "file:瑞克和莫蒂 S1E1.mkv")
        XCTAssertEqual(WatchLog.fileItem(name: "瑞克和莫蒂 S1E1.mkv").title, "瑞克和莫蒂 S1E1")
    }

    func testRecordAndContinue() throws {
        let log = WatchLog(directory: dir)
        let item = try XCTUnwrap(WatchLog.item(for: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, title: "Song"))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        log.record(item, position: 10, duration: 1000, conversationId: "c1", at: t0)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertTrue(log.continueWatching.isEmpty, "1% 还不算看到一半")

        log.record(item, position: 300, duration: 1000, conversationId: "c2", frame: Data([0xFF, 0xD8]), at: t0.addingTimeInterval(10))
        var e = try XCTUnwrap(log.entry(item.key))
        XCTAssertEqual(e.plays, 1, "10 秒后再写是同一次")
        XCTAssertEqual(e.position, 300)
        XCTAssertEqual(e.conversations, ["c2", "c1"])
        XCTAssertEqual(e.cover, "yt_dQw4w9WgXcQ.jpg", "有画面就换掉网上的缩略图")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.coverDirectory.appendingPathComponent("yt_dQw4w9WgXcQ.jpg").path))
        XCTAssertEqual(log.continueWatching.map(\.id), [item.key])

        log.record(item, position: 980, duration: 1000, at: t0.addingTimeInterval(3600))
        e = try XCTUnwrap(log.entry(item.key))
        XCTAssertEqual(e.plays, 2, "隔一小时再看算第二次")
        XCTAssertTrue(log.continueWatching.isEmpty, "过了 95% 算看完")

        // 写进文件，重开还在
        let reopened = WatchLog(directory: dir)
        XCTAssertEqual(reopened.entries, log.entries)

        reopened.remove(item.key)
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.coverDirectory.appendingPathComponent("yt_dQw4w9WgXcQ.jpg").path))
    }

    func testUnknownSourceDecodesAsWeb() throws {
        let json = #"[{"id":"quark:1","title":"t","source":"quark","url":"u","lastWatched":"2026-11-12T00:00:00Z","plays":1,"conversations":[]}]"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try d.decode([WatchLogEntry].self, from: Data(json.utf8)).first?.source, .web)
    }

    func testNewestFirstAndLimit() {
        let log = WatchLog(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(WatchLog.limit + 5) {
            log.record(WatchLog.fileItem(name: "\(i).mp4"), position: nil, duration: nil, at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(log.entries.count, WatchLog.limit)
        XCTAssertEqual(log.entries.first?.id, "file:\(WatchLog.limit + 4).mp4")
        XCTAssertNil(log.entry("file:0.mp4"), "最旧的被挤掉")
    }

    func testBackfill() throws {
        let log = WatchLog(directory: dir)
        let watched = try XCTUnwrap(WatchLog.item(for: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD")!, title: "看过的"))
        log.record(watched, position: 50, duration: 100, at: Date(timeIntervalSince1970: 2_000_000))
        log.backfill([
            ("https://www.bilibili.com/video/BV1xx411c7mD/?spm=x", "历史里的标题_哔哩哔哩_bilibili", Date(timeIntervalSince1970: 1_000_000)),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "Song - YouTube", Date(timeIntervalSince1970: 1_500_000)),
            ("https://youtu.be/dQw4w9WgXcQ", "重复的", Date(timeIntervalSince1970: 1_400_000)),
            ("https://example.com/news", "不是视频", Date(timeIntervalSince1970: 1_600_000)),
        ])
        XCTAssertEqual(log.entries.map(\.id), ["bili:BV1xx411c7mD#1", "yt:dQw4w9WgXcQ"])
        XCTAssertEqual(log.entry("bili:BV1xx411c7mD#1")?.title, "看过的", "已有的不动")
        XCTAssertEqual(log.entry("yt:dQw4w9WgXcQ")?.title, "Song")
        XCTAssertNil(log.entry("yt:dQw4w9WgXcQ")?.position)

        log.enrich("yt:dQw4w9WgXcQ", title: "别的", cover: "https://x/y.jpg", duration: 212)
        XCTAssertEqual(log.entry("yt:dQw4w9WgXcQ")?.title, "Song", "有标题不覆盖")
        log.record(WatchLog.Item(key: "yt:abcdefghijk", source: .youtube, url: "https://www.youtube.com/watch?v=abcdefghijk", title: "YouTube"),
                   position: nil, duration: nil)
        log.enrich("yt:abcdefghijk", title: "真标题", cover: nil, duration: nil)
        XCTAssertEqual(log.entry("yt:abcdefghijk")?.title, "真标题", "假标题被补上")
        XCTAssertEqual(log.entry("yt:dQw4w9WgXcQ")?.duration, 212)
        XCTAssertEqual(log.entry("yt:dQw4w9WgXcQ")?.cover, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", "有封面不覆盖")
    }

    func testParseBilibili() throws {
        let json = #"{"code":0,"data":{"title":"合集","pic":"http://i0.hdslb.com/a.jpg","duration":900,"pages":[{"page":1,"part":"上","duration":400},{"page":2,"part":"下","duration":500}]}}"#
        XCTAssertEqual(CinemaMeta.parseBilibili(Data(json.utf8), part: 2), CinemaMeta.Meta(title: "合集 · 下", cover: "https://i0.hdslb.com/a.jpg", duration: 500))
        let single = #"{"code":0,"data":{"title":"单 P","pic":"https://i0.hdslb.com/b.jpg","duration":61,"pages":[{"page":1,"part":"单 P","duration":61}]}}"#
        XCTAssertEqual(CinemaMeta.parseBilibili(Data(single.utf8), part: 1), CinemaMeta.Meta(title: "单 P", cover: "https://i0.hdslb.com/b.jpg", duration: 61))
        XCTAssertNil(CinemaMeta.parseBilibili(Data(#"{"code":-404,"message":"啥都木有"}"#.utf8), part: 1))
    }

    func testDayLabel() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 18))!
        XCTAssertEqual(CinemaText.day(now.addingTimeInterval(-3600), now: now, calendar: cal), "今天")
        XCTAssertEqual(CinemaText.day(now.addingTimeInterval(-86400), now: now, calendar: cal), "昨天")
    }
}
