import XCTest
@testable import 记忆花园

/// 卡库第二批 B8：她 25 张调助手 API 的前端卡 + 8 份含脚本聊天的脱敏结构用例（`Fixtures/CardFrontends`）。
/// 守两件事：用例里没有原文（只许占位「文本N / 名字N」、外链只许 .invalid、内置库 CDN 和 SVG 命名空间）；
/// 静态扫描口径和研究 §3.1 一致（20 张在子集 C，其余 5 张能被认出「用到了还不支持的」）。WebKit 实跑矩阵在 harness 里。
final class CardFrontendFixtureTests: XCTestCase {
    private struct Fixture {
        let id: String
        let kind: String
        let subsetC: Bool
        let texts: [String]
    }

    private func fixtures() throws -> [Fixture] {
        let dir = Bundle(for: Self.self).url(forResource: "CardFrontends", withExtension: nil)
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/CardFrontends")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { url in
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let parts = (obj["fragments"] as? [[String: Any]]) ?? (obj["messages"] as? [[String: Any]]) ?? []
            return Fixture(id: obj["case"] as? String ?? "", kind: obj["kind"] as? String ?? "",
                           subsetC: obj["subsetC"] as? Bool ?? false, texts: parts.compactMap { $0["text"] as? String })
        }
    }

    func testFixturesHoldNoOriginalText() throws {
        let all = try fixtures()
        XCTAssertEqual(all.filter { $0.kind == "card" }.count, 25)
        XCTAssertEqual(all.filter { $0.kind == "chat" }.count, 8)
        let han = try NSRegularExpression(pattern: #"[\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}]+"#)
        let url = try NSRegularExpression(pattern: #"(?:https?:)?//((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,})(?::\d+)?(/[^\s'"`<>()\\]*)?"#)
        for f in all {
            XCTAssertFalse(f.texts.isEmpty, f.id)
            for text in f.texts {
                let ns = text as NSString
                for m in han.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let run = ns.substring(with: m.range)
                    XCTAssertTrue(run.allSatisfy { "文本名字".contains($0) }, "\(f.id)：只许占位里的汉字")
                    XCTAssertLessThanOrEqual(run.count, 6, "\(f.id)：连续汉字不超过 6 个")
                }
                for m in url.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let host = ns.substring(with: m.range(at: 1)).lowercased()
                    guard !host.hasSuffix(".invalid"), host != "www.w3.org" else { continue }   // w3.org = SVG 命名空间
                    let path = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
                    XCTAssertNotNil(CardWebLibrary.localPath(forRemote: "https://" + host + path), "\(f.id)：外链只许 .invalid 和内置库 CDN（\(host)）")
                }
            }
        }
    }

    func testStaticScanMatchesResearchCoverage() throws {
        let cards = try fixtures().filter { $0.kind == "card" }
        XCTAssertEqual(cards.filter(\.subsetC).count, 20, "研究 §3.1 子集 C：20 / 25")
        let core: Set<CardUnsupportedFeature> = [.mvu, .worldBook, .audio, .generate]
        var flaggedInC: [String] = []
        for card in cards {
            let found = Set(CardFeatureScanner.scan(card.texts)).intersection(core)
            if card.subsetC {
                if !found.isEmpty { flaggedInC.append(card.id) }
            } else {
                XCTAssertFalse(found.isEmpty, "\(card.id)：子集外的卡角色页要显示「用到了还不支持的」")
            }
        }
        // 研究按 API 名算进子集 C、但网页里其实还靠世界书 / MVU 的：01 02 写世界书条目（/setentryfield）、25 读 Mvu；
        // 18 只是卡里自己有个叫 refreshWorldbook 的函数（扫描按名字认，偏严）
        XCTAssertEqual(flaggedInC, ["card-01", "card-02", "card-18", "card-25"])
    }
}
