import XCTest
@testable import 记忆花园

/// 推特导出包的解压。
///
/// 不用 ZIPFoundation 的原因：推特的包全程 ZIP64、第一个条目偏移是 0，
/// ZIPFoundation 0.9.20 把 ZIP64 字段里的 0 当成「没填」，读出 0 个文件（粟粟真存档 2026-09-24 实测）。
/// 夹具由 scripts/make-twitter-zip-fixtures.py 按真包的写法生成。
final class TwitterZipExtractorTests: XCTestCase {

    private var dest: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tw-zip-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let dest { try? FileManager.default.removeItem(at: dest) }
        dest = nil
        try super.tearDownWithError()
    }

    private func fixture(_ name: String) throws -> URL {
        let dir = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "twitter-zip", withExtension: nil))
        return dir.appendingPathComponent(name)
    }

    private var sourceData: URL {
        get throws {
            try XCTUnwrap(Bundle(for: Self.self).url(forResource: "twitter-archive", withExtension: nil))
                .appendingPathComponent("data")
        }
    }

    func testExtractsTwitterStyleZip64Archive() throws {
        try TwitterZipExtractor.extract(try fixture("twitter-style.zip"), to: dest)
        for name in ["account.js", "profile.js", "tweets.js", "tweets-part1.js"] {
            XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("data/\(name)")),
                           try Data(contentsOf: try sourceData.appendingPathComponent(name)),
                           "\(name) 解出来要跟原文件一字不差")
        }
    }

    func testExtractsMediaFolders() throws {
        try TwitterZipExtractor.extract(try fixture("twitter-style.zip"), to: dest)
        let fm = FileManager.default
        for sub in ["tweets_media", "profile_media"] {
            let want = try fm.contentsOfDirectory(atPath: try sourceData.appendingPathComponent(sub).path)
                .filter { !$0.hasPrefix(".") }.sorted()
            let got = try fm.contentsOfDirectory(atPath: dest.appendingPathComponent("data/\(sub)").path).sorted()
            XCTAssertEqual(got, want)
        }
    }

    func testHandlesStoredEntries() throws {
        try TwitterZipExtractor.extract(try fixture("twitter-style.zip"), to: dest)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("data/README.txt.stored"), encoding: .utf8),
                       "stored entry body")
    }

    func testFilterSkipsWhatImportDoesNotNeed() throws {
        // 私信媒体这类东西导入用不上，也不该落到磁盘上
        try TwitterZipExtractor.extract(try fixture("twitter-style.zip"), to: dest,
                                        include: TwitterZipExtractor.neededForImport)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("data/tweets.js").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("data/profile_media").path))
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("data/direct_messages_media").path))
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("Your archive.html").path))
    }

    func testNeededForImportRules() {
        let keep = ["data/tweets.js", "data/tweets-part3.js", "data/account.js", "data/note-tweet.js",
                    "data/tweets_media/1-a.jpg", "data/profile_media/9-b.jpg",
                    "twitter-2026/data/tweets.js"]  // 包外面又套了一层文件夹也要认
        let drop = ["data/direct_messages_media/1-a.jpg", "Your archive.html", "assets/images/x.svg",
                    "data/grok_chat_media/x.png", "data/deleted_tweets_media/1.jpg", "data/",
                    // data/ 下的 js 也不是都要：私信正文、广告、IP 记录一律不解
                    "data/direct-messages.js", "data/ip-audit.js", "data/like.js"]
        for p in keep { XCTAssertTrue(TwitterZipExtractor.neededForImport(p), p) }
        for p in drop { XCTAssertFalse(TwitterZipExtractor.neededForImport(p), p) }
    }

    func testRefusesPathTraversal() {
        XCTAssertThrowsError(try TwitterZipExtractor.extract(try fixture("zip-slip.zip"), to: dest)) {
            guard case TwitterZipError.unsafePath = $0 else { return XCTFail("应当是 unsafePath，实际 \($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.deletingLastPathComponent().appendingPathComponent("evil.js").path))
    }

    func testRejectsNonZip() throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).zip")
        try Data("definitely not a zip".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertThrowsError(try TwitterZipExtractor.extract(junk, to: dest)) {
            XCTAssertEqual($0 as? TwitterZipError, .notAZip)
        }
    }

    func testReportsProgressUpToOne() throws {
        var seen: [Double] = []
        try TwitterZipExtractor.extract(try fixture("twitter-style.zip"), to: dest, onProgress: { seen.append($0) })
        XCTAssertEqual(seen.last, 1)
        XCTAssertEqual(seen, seen.sorted(), "进度只能往前走")
    }
}
