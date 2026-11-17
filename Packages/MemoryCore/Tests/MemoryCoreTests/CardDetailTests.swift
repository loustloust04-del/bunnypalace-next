import XCTest
@testable import MemoryCore

/// 条目的「详细度」重写：提示词拼法、材料怎么排、解码、重问一次。全虚构
final class CardDetailTests: XCTestCase {
    private let names = MemoryExtractor.Names(userName: "青禾", assistantName: "小檐")

    private func material(before: [FragmentVerdict.Line] = []) -> CardDetail.Material {
        CardDetail.Material(windowTitle: "修钟", names: names, subject: "青禾", content: "在梧桐巷钟表铺学修旧钟。",
                            lines: [.init(role: "user", text: "这周开始去梧桐巷钟表铺\n学修旧钟", at: "2026-04-02 20:00"),
                                    .init(role: "assistant", text: "修的哪一座")],
                            before: before, anchor: 1)
    }

    func testSystemCarriesTheSharedRulesAndOnlyThatLevel() {
        for level in CardDetail.Level.allCases {
            let s = CardDetail.system(names: names, level: level)
            XCTAssertTrue(s.contains("青禾 想把这条改成「\(level.label)」的写法"))
            XCTAssertTrue(s.contains("「关于」不改，也不要把它写进正文开头"), "主语留在关于里")
            XCTAssertTrue(s.contains("不写悬空的指代"))
            XCTAssertTrue(s.contains("一个字也不要补"), "不编")
            XCTAssertTrue(s.contains("不写对话经过"))
            XCTAssertTrue(s.contains("{\"content\":\"……\"}"))
            XCTAssertTrue(s.contains("这次要的是「\(level.label)」那一种。"))
            for other in CardDetail.Level.allCases where other != level {
                XCTAssertFalse(s.contains("「\(other.label)」的写法："), "只带这一档的要求")
            }
            for word in ["主人", "recall", "碎片", "活档案", "A2", "C2"] { XCTAssertFalse(s.contains(word), "提示词里不出现「\(word)」") }
        }
        let detailed = CardDetail.system(names: names, level: .detailed)
        XCTAssertTrue(detailed.contains("不受平时「一条最多四句」的限制"))
        XCTAssertTrue(detailed.contains("用引号照原话写"))
        let brief = CardDetail.system(names: names, level: .brief)
        XCTAssertTrue(brief.contains("三个月后不翻原文也看得懂"))
        XCTAssertTrue(brief.contains("- 一定比「现在的正文」短。"), "简略不能比现在的正文长")
        XCTAssertFalse(detailed.contains("一定比「现在的正文」短"))
    }

    func testUserLaysOutTextBeforeAndCard() {
        let plain = CardDetail.user(material(), level: .brief)
        XCTAssertTrue(plain.hasPrefix("这段对话所在的窗口叫「修钟」。"))
        XCTAssertFalse(plain.contains("## 前文"), "没有前文就没有那一块")
        XCTAssertTrue(plain.contains("## 原文（#1–#2）\n\n#1 2026-04-02 20:00 · 青禾：这周开始去梧桐巷钟表铺 ⏎ 学修旧钟\n#2 · 小檐：修的哪一座"))
        XCTAssertTrue(plain.contains("## 这条条目\n\n关于：青禾\n出自：#1\n现在的正文：在梧桐巷钟表铺学修旧钟。"))
        XCTAssertTrue(plain.hasSuffix("按「简略」的写法重写正文。"))

        let withBefore = CardDetail.user(material(before: [.init(role: "user", text: "前一句"), .init(role: "assistant", text: "紧挨着的")]),
                                         level: .detailed)
        XCTAssertTrue(withBefore.contains("## 前文（只供看懂，不要从这里取事）\n\n#-1 · 青禾：前一句\n#0 · 小檐：紧挨着的\n\n## 原文"))
    }

    func testDecoded() throws {
        XCTAssertEqual(try CardDetail.decoded("{\"content\":\" 在梧桐巷钟表铺学修旧钟。 \"}"), "在梧桐巷钟表铺学修旧钟。")
        XCTAssertEqual(try CardDetail.decoded("<think>想想</think>\n好的：{\"content\":\"一句\"}"), "一句")
        XCTAssertThrowsError(try CardDetail.decoded("就这样吧"))
        XCTAssertThrowsError(try CardDetail.decoded("{\"content\":\"  \"}"))
        XCTAssertThrowsError(try CardDetail.decoded("{\"text\":\"一句\"}"))
    }

    func testRunRetriesOnceThenThrows() async throws {
        let m = material()
        var asked: [String] = []
        let first = try await CardDetail.run(m, level: .brief) { system, user in
            XCTAssertEqual(system, CardDetail.system(names: self.names, level: .brief))
            asked.append(user)
            return "{\"content\":\"在梧桐巷钟表铺学修旧钟。\"}"
        }
        XCTAssertEqual(asked, [CardDetail.user(m, level: .brief)])
        XCTAssertEqual(first, CardDetail.Outcome(text: "在梧桐巷钟表铺学修旧钟。", retried: false))
        asked = []
        let second = try await CardDetail.run(m, level: .detailed) { _, user in
            asked.append(user)
            return asked.count == 1 ? "我看看" : "{\"content\":\"两句。三句。\"}"
        }
        XCTAssertEqual(asked.count, 2)
        XCTAssertTrue(asked[1].hasSuffix(CardDetail.retryNote))
        XCTAssertEqual(second, CardDetail.Outcome(text: "两句。三句。", retried: true))
        do {
            _ = try await CardDetail.run(m, level: .brief) { _, _ in "还是不会" }
            XCTFail("两次都不合格要抛")
        } catch {}
        let gated = try await CardDetail.run(m, level: .brief) { _, _ in nil }
        XCTAssertNil(gated)
    }
}
