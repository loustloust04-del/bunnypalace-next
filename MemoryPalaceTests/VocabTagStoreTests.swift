import XCTest
@testable import 记忆花园

final class VocabTagStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-tag-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testEmptyStoreLoadsEmpty() {
        XCTAssertEqual(VocabTagStore.load(dir: dir), [:])
        XCTAssertEqual(VocabTagStore.allTags(dir: dir), [])
        XCTAssertEqual(VocabTagStore.tags(word: "nag", dir: dir), [])
    }

    func testToggleAddsAndRemoves() {
        VocabTagStore.toggle(word: "nag", tag: "雅思a话题", dir: dir)
        XCTAssertEqual(VocabTagStore.tags(word: "nag", dir: dir), ["雅思a话题"])
        VocabTagStore.toggle(word: "nag", tag: "雅思a话题", dir: dir)
        XCTAssertEqual(VocabTagStore.tags(word: "nag", dir: dir), [])
        // 空 tag 键被清掉，不留空数组
        XCTAssertNil(VocabTagStore.load(dir: dir)["nag"])
    }

    func testTrimAndIgnoreEmpty() {
        VocabTagStore.toggle(word: "nag", tag: "  雅思a话题  ", dir: dir)
        XCTAssertEqual(VocabTagStore.tags(word: "nag", dir: dir), ["雅思a话题"])
        VocabTagStore.toggle(word: "nag", tag: "   ", dir: dir)
        XCTAssertEqual(VocabTagStore.tags(word: "nag", dir: dir), ["雅思a话题"])
    }

    func testAllTagsAggregatesSorted() {
        VocabTagStore.toggle(word: "nag", tag: "b组", dir: dir)
        VocabTagStore.toggle(word: "jerk", tag: "a组", dir: dir)
        VocabTagStore.toggle(word: "level", tag: "a组", dir: dir)
        XCTAssertEqual(VocabTagStore.allTags(dir: dir), ["a组", "b组"])
    }

    func testWordsByTag() {
        VocabTagStore.toggle(word: "nag", tag: "a组", dir: dir)
        VocabTagStore.toggle(word: "jerk", tag: "a组", dir: dir)
        VocabTagStore.toggle(word: "level", tag: "b组", dir: dir)
        XCTAssertEqual(VocabTagStore.words(tag: "a组", dir: dir), ["nag", "jerk"])
    }

    func testCorruptFileLoadsEmpty() {
        try? Data("not json".utf8).write(to: dir.appendingPathComponent("vocab-tags.json"))
        XCTAssertEqual(VocabTagStore.load(dir: dir), [:])
    }
}

// MARK: - R5-4/R6 词形归一（真实 ECDICT 数据面——R5 mock 测试假绿的教训）

final class VocabCanonicalizeTests: XCTestCase {
    /// 从 repo 真 json 建反查表（测试 bundle 没有 app 资源，#filePath 定位 repo 文件）。
    static let realBaseForm: (String) -> String? = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("MemoryPalace/Resources/ngsl/ecdict_subset.json")
        struct E: Codable { var x: String? }
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: E].self, from: data) else {
            return { _ in nil }
        }
        let realFormRoles: Set<String> = ["p", "d", "i", "3", "s", "r", "t"]
        var reverse: [String: String] = [:]
        for (word, e) in map {
            guard let x = e.x else { continue }
            for part in x.split(separator: "/") {
                let pieces = part.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2, realFormRoles.contains(String(pieces[0])) else { continue }
                let f = String(pieces[1]).trimmingCharacters(in: .whitespaces).lowercased()
                guard !f.isEmpty, f != word else { continue }
                if let cur = reverse[f], cur <= word { continue }
                reverse[f] = word
            }
        }
        return { reverse[$0] }
    }()

    func testRealDataSwitchedNormalizes() {
        XCTAssertEqual(VocabCollector.canonicalizeCore("switched", baseForm: Self.realBaseForm), "switch",
                       "粟粟实测打回的案例：ECDICT 有 switched 词条也必须归一")
    }

    func testRealDataAbolishedNormalizes() {
        XCTAssertEqual(VocabCollector.canonicalizeCore("abolished", baseForm: Self.realBaseForm), "abolish")
    }

    func testBaseWordNotInverted() {
        // ECDICT exchange 的 0: 是原型指针不是变形——abandon 不许倒挂成 abandoned
        XCTAssertEqual(VocabCollector.canonicalizeCore("abandon", baseForm: Self.realBaseForm), "abandon")
        XCTAssertEqual(VocabCollector.canonicalizeCore("switch", baseForm: Self.realBaseForm), "switch")
    }

    func testWhitelistProtectsAmbiguous() {
        XCTAssertEqual(VocabCollector.canonicalizeCore("left", baseForm: Self.realBaseForm), "left")
        XCTAssertEqual(VocabCollector.canonicalizeCore("found", baseForm: Self.realBaseForm), "found")
    }

    func testPhraseUntouched() {
        XCTAssertEqual(VocabCollector.canonicalizeCore("bump into", baseForm: { _ in "X" }), "bump into")
    }

    func testLemmatizerFallback() {
        // 反查无命中 → NLTagger（真跑系统 lemmatizer）
        XCTAssertEqual(VocabCollector.canonicalizeCore("carrying", baseForm: { _ in nil }), "carry")
    }

    func testUnknownWordStays() {
        XCTAssertEqual(VocabCollector.canonicalizeCore("zzyzx", baseForm: { _ in nil }), "zzyzx")
    }
}

// MARK: - 收词出处 ref 分流（R6b：thinking 锚死链回归）

final class VocabSourceRefTests: XCTestCase {
    func testThinkingAnchorKeepsMarker() {
        XCTAssertEqual(VocabCollector.chatRef(nodeId: "thinking:node-123"), "thinking#node-123",
                       "思考链收词保留标记（跳回要弹思考链+闪词）")
        XCTAssertEqual(VocabCollector.parseThinkingRef("thinking#node-123"), "node-123")
        XCTAssertNil(VocabCollector.parseChatRef("thinking#node-123"))
    }

    func testLegacyThinkingRefParses() {
        XCTAssertEqual(VocabCollector.parseThinkingRef("chat#thinking:node-123"), "node-123",
                       "R6b 期间误存的 thinking ref 兼容")
        XCTAssertNil(VocabCollector.parseChatRef("chat#thinking:node-123"),
                     "chat 解析不接 thinking（parseThinkingRef 接管）")
    }

    func testVocabAnchorsRouteToVocabRef() {
        XCTAssertEqual(VocabCollector.chatRef(nodeId: "vocab:abolish"), "vocab#abolish")
        XCTAssertEqual(VocabCollector.chatRef(nodeId: "vocabnote:brew"), "vocab#brew")
        XCTAssertNil(VocabCollector.parseChatRef("chat#vocab:abolish"))
        XCTAssertEqual(VocabCollector.parseVocabRef("chat#vocab:abolish"), "abolish")
    }

    func testPlainNodePassthrough() {
        XCTAssertEqual(VocabCollector.chatRef(nodeId: "node-9"), "chat#node-9")
        XCTAssertEqual(VocabCollector.parseChatRef("chat#node-9"), "node-9")
    }
}
