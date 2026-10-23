import XCTest
@testable import 记忆花园

/// 推特存档解析器的特征测试。存档的 data/*.js 是「JS 赋值包着 JSON」，
/// 剥壳是整条链路的地基，先把它钉死。
final class TwitterArchiveStripWrapperTests: XCTestCase {

    private func strip(_ s: String) throws -> String {
        let out = try TwitterArchiveReader.stripJSWrapper(Data(s.utf8))
        return String(decoding: out, as: UTF8.self)
    }

    func testStripsStandardTweetsWrapper() throws {
        let raw = #"window.YTD.tweets.part0 = [ {"tweet": {"id_str": "1"}} ]"#
        XCTAssertEqual(try strip(raw), #"[ {"tweet": {"id_str": "1"}} ]"#)
    }

    func testStripsAccountWrapperWithDifferentPartNumber() throws {
        let raw = #"window.YTD.account.part7 = [{"account":{}}]"#
        XCTAssertEqual(try strip(raw), #"[{"account":{}}]"#)
    }

    func testKeepsEqualsSignsInsideJSONBody() throws {
        // 正文里带 = 的推文（URL query、颜文字）不能被二次切断——只切第一个 =
        let raw = #"window.YTD.tweets.part0 = [{"tweet":{"full_text":"a=b&c=d"}}]"#
        XCTAssertEqual(try strip(raw), #"[{"tweet":{"full_text":"a=b&c=d"}}]"#)
    }

    func testToleratesLeadingWhitespaceAndBOM() throws {
        let raw = "\u{FEFF}  window.YTD.tweets.part0 = [1]"
        XCTAssertEqual(try strip(raw), "[1]")
    }

    func testAcceptsBarePayloadWithoutWrapper() throws {
        // 有人会自己把壳剥了再喂进来；裸 JSON 原样放行，不报错
        XCTAssertEqual(try strip(#"[{"tweet":{}}]"#), #"[{"tweet":{}}]"#)
    }

    func testThrowsWhenPayloadIsNotJSONArrayOrObject() throws {
        XCTAssertThrowsError(try strip("window.YTD.tweets.part0 = not-json")) { error in
            XCTAssertEqual(error as? TwitterArchiveError, .malformedWrapper)
        }
    }
}

/// 推特 `created_at` 的解析。格式是 Twitter v1.1 的 `"Wed Oct 10 20:19:24 +0000 2018"`，
/// 必须钉 `en_US_POSIX`——否则设备切到中文/阿拉伯历时月份名对不上，静默解析失败。
final class TwitterDateParsingTests: XCTestCase {

    func testParsesStandardUTCTimestamp() {
        let d = TwitterArchiveReader.parseDate("Wed Oct 10 20:19:24 +0000 2018")
        XCTAssertEqual(d?.timeIntervalSince1970, 1539202764)
    }

    func testParsesNonZeroTimezoneOffset() {
        // 同一瞬间写成 +0800，应得到早 8 小时的 epoch
        let d = TwitterArchiveReader.parseDate("Thu Oct 11 04:19:24 +0800 2018")
        XCTAssertEqual(d?.timeIntervalSince1970, 1539202764)
    }

    func testReturnsNilForGarbage() {
        XCTAssertNil(TwitterArchiveReader.parseDate("not a date"))
    }

    func testReturnsNilForEmptyString() {
        XCTAssertNil(TwitterArchiveReader.parseDate(""))
    }
}

/// 把一个 tweets part 文件解成结构体。存档的形状有真实差异——
/// 计数字段在导出里是**字符串**（`"favorite_count": "12"`），但有些存档是数字，两种都要吃。
final class TwitterTweetParsingTests: XCTestCase {

    private func parse(_ json: String) throws -> [ParsedTweet] {
        try TwitterArchiveReader.parseTweets(Data("window.YTD.tweets.part0 = \(json)".utf8))
    }

    func testParsesCoreFields() throws {
        let t = try parse(#"""
        [{"tweet":{"id_str":"111","full_text":"你好 world",
          "created_at":"Wed Oct 10 20:19:24 +0000 2018",
          "favorite_count":"12","retweet_count":"3"}}]
        """#)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].id, "111")
        XCTAssertEqual(t[0].text, "你好 world")
        XCTAssertEqual(t[0].createdAt.timeIntervalSince1970, 1539202764)
        XCTAssertEqual(t[0].favoriteCount, 12)
        XCTAssertEqual(t[0].retweetCount, 3)
    }

    func testAcceptsNumericCountsToo() throws {
        let t = try parse(#"""
        [{"tweet":{"id_str":"112","full_text":"x",
          "created_at":"Wed Oct 10 20:19:24 +0000 2018",
          "favorite_count":7,"retweet_count":0}}]
        """#)
        XCTAssertEqual(t[0].favoriteCount, 7)
        XCTAssertEqual(t[0].retweetCount, 0)
    }

    func testParsesReplyFields() throws {
        let t = try parse(#"""
        [{"tweet":{"id_str":"113","full_text":"回复","created_at":"Wed Oct 10 20:19:24 +0000 2018",
          "favorite_count":"0","retweet_count":"0",
          "in_reply_to_status_id_str":"111","in_reply_to_screen_name":"susu_test"}}]
        """#)
        XCTAssertEqual(t[0].inReplyToTweetId, "111")
        XCTAssertEqual(t[0].inReplyToScreenName, "susu_test")
    }

    func testReplyFieldsAreNilWhenAbsent() throws {
        let t = try parse(#"""
        [{"tweet":{"id_str":"114","full_text":"x","created_at":"Wed Oct 10 20:19:24 +0000 2018",
          "favorite_count":"0","retweet_count":"0"}}]
        """#)
        XCTAssertNil(t[0].inReplyToTweetId)
        XCTAssertNil(t[0].inReplyToScreenName)
    }

    func testParsesEntities() throws {
        let t = try parse(#"""
        [{"tweet":{"id_str":"115","full_text":"x","created_at":"Wed Oct 10 20:19:24 +0000 2018",
          "favorite_count":"0","retweet_count":"0",
          "entities":{"hashtags":[{"text":"测试"},{"text":"swift"}],
                      "user_mentions":[{"screen_name":"someone"}],
                      "urls":[{"expanded_url":"https://example.com/post"}]}}}]
        """#)
        XCTAssertEqual(t[0].hashtags, ["测试", "swift"])
        XCTAssertEqual(t[0].mentions, ["someone"])
        XCTAssertEqual(t[0].urls, ["https://example.com/post"])
    }

    func testParsesExtendedEntitiesMedia() throws {
        let t = try parse(#"""
        [{"tweet":{"id_str":"116","full_text":"x","created_at":"Wed Oct 10 20:19:24 +0000 2018",
          "favorite_count":"0","retweet_count":"0",
          "extended_entities":{"media":[{"id_str":"999","type":"photo",
            "media_url_https":"https://pbs.twimg.com/media/pic.jpg",
            "sizes":{"large":{"w":"1200","h":"800"}}}]}}}]
        """#)
        XCTAssertEqual(t[0].media.count, 1)
        XCTAssertEqual(t[0].media[0].id, "999")
        XCTAssertEqual(t[0].media[0].kind, "photo")
        // 真存档里媒体文件叫 <tweetId>-<媒体 URL 的文件名>.<ext>（2026-09-24 对粟粟真存档核实），
        // 早先以为的 <tweetId>-<mediaId> 留作兜底
        XCTAssertEqual(t[0].media[0].fileNameStems, ["116-pic", "116-999"])
        XCTAssertEqual(t[0].media[0].width, 1200)
        XCTAssertEqual(t[0].media[0].height, 800)
    }

    func testSkipsMalformedTweetWithoutAbortingBatch() throws {
        // 缺 id_str 的一条要跳过，后面的正常条目不能被带走
        let t = try parse(#"""
        [{"tweet":{"full_text":"没有 id","created_at":"Wed Oct 10 20:19:24 +0000 2018"}},
         {"tweet":{"id_str":"117","full_text":"好的","created_at":"Wed Oct 10 20:19:24 +0000 2018",
           "favorite_count":"0","retweet_count":"0"}}]
        """#)
        XCTAssertEqual(t.map(\.id), ["117"])
    }

    func testSkipsTweetWithUnparsableDate() throws {
        let t = try parse(#"""
        [{"tweet":{"id_str":"118","full_text":"x","created_at":"not a date",
          "favorite_count":"0","retweet_count":"0"}}]
        """#)
        XCTAssertTrue(t.isEmpty)
    }

    func testReturnsEmptyForEmptyArray() throws {
        XCTAssertTrue(try parse("[]").isEmpty)
    }
}

/// 档案布局层：定位 data/、按 part 序号排序、解析账号与资料。
/// 用 fixtures/twitter-archive 这份真形状小样本跑（R5 mock 假绿的教训）。
final class TwitterArchiveLayoutTests: XCTestCase {

    /// fixture 以 folder 资源进测试 bundle，保留目录结构
    private var archiveRoot: URL {
        get throws {
            let url = try XCTUnwrap(
                Bundle(for: Self.self).url(forResource: "twitter-archive", withExtension: nil),
                "fixtures/twitter-archive 没进测试 bundle，检查 project.yml 的 resources 注册"
            )
            return url
        }
    }

    func testLocatesDataDirectoryAtRoot() throws {
        let data = try XCTUnwrap(TwitterArchiveReader.locateDataDirectory(in: archiveRoot))
        XCTAssertEqual(data.lastPathComponent, "data")
    }

    func testLocatesDataDirectoryNestedOneLevelDown() throws {
        // 存档常多套一层（解压出 "Your archive" 目录再套 data/）
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tw-nested-\(UUID().uuidString)")
        let inner = tmp.appendingPathComponent("Your archive")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: archiveRoot.appendingPathComponent("data"),
                                         to: inner.appendingPathComponent("data"))
        let found = try XCTUnwrap(TwitterArchiveReader.locateDataDirectory(in: tmp))
        XCTAssertEqual(found.lastPathComponent, "data")
    }

    func testReturnsNilWhenNoDataDirectory() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tw-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNil(TwitterArchiveReader.locateDataDirectory(in: tmp))
    }

    func testCollectsTweetPartFilesInPartOrder() throws {
        let data = try XCTUnwrap(TwitterArchiveReader.locateDataDirectory(in: archiveRoot))
        let parts = TwitterArchiveReader.tweetPartFiles(in: data)
        // tweets.js（part0）必须排在 tweets-part1.js 前面——按字典序排会反
        XCTAssertEqual(parts.map(\.lastPathComponent), ["tweets.js", "tweets-part1.js"])
    }

    func testParsesAccount() throws {
        let data = try XCTUnwrap(TwitterArchiveReader.locateDataDirectory(in: archiveRoot))
        let account = try XCTUnwrap(TwitterArchiveReader.parseAccount(in: data))
        XCTAssertEqual(account.accountId, "1234567890")
        XCTAssertEqual(account.screenName, "susu_test")
        XCTAssertEqual(account.displayName, "禾禾")
    }

    func testParsesProfileBioEvenWithEqualsSign() throws {
        let data = try XCTUnwrap(TwitterArchiveReader.locateDataDirectory(in: archiveRoot))
        let profile = try XCTUnwrap(TwitterArchiveReader.parseProfile(in: data))
        XCTAssertEqual(profile.bio, "测试用的简介 with an = sign")
        XCTAssertEqual(profile.avatarURL, "https://pbs.twimg.com/profile_images/1/avatar.jpg")
    }

    func testParsesAllTweetsAcrossParts() throws {
        let data = try XCTUnwrap(TwitterArchiveReader.locateDataDirectory(in: archiveRoot))
        let all = try TwitterArchiveReader.tweetPartFiles(in: data)
            .flatMap { try TwitterArchiveReader.parseTweets(Data(contentsOf: $0)) }
        XCTAssertEqual(all.map(\.id), ["1000000000000000001",
                                       "1000000000000000002",
                                       "1000000000000000003"])
        XCTAssertEqual(all[2].media.first?.fileNameStems.first, "1000000000000000003-pic")
    }
}
