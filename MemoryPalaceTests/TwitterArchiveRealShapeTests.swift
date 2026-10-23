import XCTest
@testable import 记忆花园

/// 粟粟真存档（2026-09-24）里跑出来、小样本没覆盖到的形状。
/// 每一条都对应一个真看到的问题：媒体一张没配上、`&lt;` 原样显示、t.co 短链露在正文里、
/// 转推被当成自己说的话、长推只剩前半截、注册时间解不出。
final class TwitterArchiveRealShapeTests: XCTestCase {

    private func parse(_ json: String) throws -> [ParsedTweet] {
        try TwitterArchiveReader.parseTweets(Data("window.YTD.tweets.part0 = \(json)".utf8))
    }

    private func tweet(_ fields: String) -> String {
        #"[{"tweet":{"id_str":"7","created_at":"Wed Oct 10 20:19:24 +0000 2018","favorite_count":"0","retweet_count":"0","#
            + fields + "}}]"
    }

    // MARK: 媒体文件名

    func testVideoCandidatesIncludeMp4VariantNames() throws {
        // 视频文件用的是某个 mp4 码率的文件名，不是缩略图的；m3u8 不是文件
        let t = try parse(tweet(#"""
        "full_text":"v","extended_entities":{"media":[{"id_str":"9","type":"video",
          "media_url_https":"https://pbs.twimg.com/ext_tw_video_thumb/9/pu/img/THUMB.jpg",
          "video_info":{"variants":[
            {"url":"https://video.twimg.com/ext_tw_video/9/pu/vid/1280x720/AAA-b_c.mp4?tag=12"},
            {"url":"https://video.twimg.com/ext_tw_video/9/pu/pl/LIST.m3u8?tag=12"},
            {"url":"https://video.twimg.com/ext_tw_video/9/pu/vid/480x270/BBB.mp4"}]}}]}
        """#))
        let stems = t[0].media[0].fileNameStems
        XCTAssertEqual(stems.first, "7-THUMB")
        XCTAssertTrue(stems.contains("7-AAA-b_c"), "文件名主干里本身可能带 -，别按 - 切")
        XCTAssertTrue(stems.contains("7-BBB"))
        XCTAssertFalse(stems.contains("7-LIST"))
    }

    // MARK: 正文清理

    func testUnescapesHTMLEntities() throws {
        // 存档正文是 HTML 转义过的，粟粟的存档里有 35 条带 &lt;/&gt;
        let t = try parse(tweet(#""full_text":"a &lt;3 &amp; b &gt; c""#))
        XCTAssertEqual(t[0].text, "a <3 & b > c")
    }

    func testReplacesLinksAndDropsMediaLink() throws {
        // 推特界面上：链接显示成 display_url，媒体那条 t.co 不显示（图已经在下面了）
        let t = try parse(tweet(#"""
        "full_text":"看 https://t.co/aaa 图 https://t.co/mmm",
        "entities":{"urls":[{"url":"https://t.co/aaa","display_url":"example.com/post","expanded_url":"https://example.com/post"}]},
        "extended_entities":{"media":[{"id_str":"1","type":"photo","url":"https://t.co/mmm",
          "media_url_https":"https://pbs.twimg.com/media/X.jpg"}]}
        """#))
        XCTAssertEqual(t[0].text, "看 example.com/post 图")
    }

    func testLeavesLinksAloneWhenEntityHasNoShortURL() throws {
        let t = try parse(tweet(#""full_text":"x https://t.co/abc","entities":{"urls":[{"expanded_url":"https://e.com"}]}"#))
        XCTAssertEqual(t[0].text, "x https://t.co/abc")
    }

    // MARK: 转推

    func testRecognizesRetweet() throws {
        let t = try parse(tweet(#"""
        "full_text":"RT @alice: 原文前半截…",
        "entities":{"user_mentions":[{"screen_name":"alice","name":"爱丽丝"}]}
        """#))
        XCTAssertEqual(t[0].retweetedScreenName, "alice")
        XCTAssertEqual(t[0].retweetedName, "爱丽丝")
        XCTAssertEqual(t[0].text, "原文前半截…", "RT @x: 前缀拿掉，转推头单独画")
    }

    func testPlainTweetIsNotARetweet() throws {
        let t = try parse(tweet(#""full_text":"说 RT @alice: 不算转推""#))
        XCTAssertNil(t[0].retweetedScreenName)
    }

    // MARK: 账号

    func testParsesAccountCreatedAtWithFractionalSeconds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-acc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"window.YTD.account.part0 = [{"account":{"accountId":"1","username":"u","createdAt":"2026-03-02T04:19:47.577Z"}}]"#.utf8)
            .write(to: dir.appendingPathComponent("account.js"))
        let acc = try XCTUnwrap(TwitterArchiveReader.parseAccount(in: dir))
        XCTAssertEqual(try XCTUnwrap(acc.createdAt).timeIntervalSince1970, 1772425187.577, accuracy: 0.01)
    }

    // MARK: 长推

    func testParsesNoteTweets() throws {
        let notes = try TwitterArchiveReader.parseNoteTweets(Data(#"""
        window.YTD.note_tweet.part0 = [{"noteTweet":{"noteTweetId":"5","createdAt":"2018-10-10T20:19:24.000Z",
          "core":{"text":"很长很长的全文 &amp; 结尾","hashtags":[],"mentions":[],"urls":[],"cashtags":[]}}}]
        """#.utf8))
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].text, "很长很长的全文 & 结尾")
        XCTAssertEqual(notes[0].createdAt.timeIntervalSince1970, 1539202764, accuracy: 0.01)
    }

    func testMatchesNoteToTheTweetPostedAtTheSameMoment() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let tweets: [(id: String, text: String, createdAt: Date)] = [
            ("a", "别的推", at.addingTimeInterval(-60)),
            ("b", "很长很长的…", at.addingTimeInterval(1)),   // 存档里时间可能差一两秒
        ]
        let notes = [ParsedNoteTweet(text: "很长很长的全文", createdAt: at)]
        XCTAssertEqual(TwitterArchiveReader.matchNotes(notes, to: tweets), ["b": "很长很长的全文"])
    }

    func testAmbiguousNoteMatchUsesTextPrefix() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let tweets: [(id: String, text: String, createdAt: Date)] = [
            ("a", "另一条同秒发的", at), ("b", "开头一样 https://t.co/x", at)]
        let notes = [ParsedNoteTweet(text: "开头一样，后面还有很多", createdAt: at)]
        XCTAssertEqual(TwitterArchiveReader.matchNotes(notes, to: tweets), ["b": "开头一样，后面还有很多"])
    }
}
