import XCTest
@testable import 记忆花园

/// #054 考古 App 路：提示词进包、请求格式、成功门槛、模型选择、路由默认值。不发网络。
@MainActor
final class VocabArcheologistTests: XCTestCase {

    func testSystemPromptShipsInBundle() throws {
        let prompt = try XCTUnwrap(VocabArcheologist.systemPrompt(), "App 包里没有考古提示词")
        XCTAssertTrue(prompt.hasPrefix("# 语言考古学家"))
        XCTAssertTrue(prompt.contains("一句话本质"))
    }

    func testUserMessageMatchesNightlyScript() {
        XCTAssertEqual(VocabArcheologist.userMessage(word: "ephemeral"), "本轮要考古的单词：ephemeral")
    }

    func testAcceptNeedsMoreThan500Bytes() {
        XCTAssertNil(VocabArcheologist.accept(String(repeating: "a", count: 500)))
        XCTAssertNil(VocabArcheologist.accept("  \n" + String(repeating: "a", count: 500) + "\n  "))
        XCTAssertEqual(VocabArcheologist.accept(String(repeating: "a", count: 501)), String(repeating: "a", count: 501))
        // 中文按字节算：167 字 × 3B = 501B
        XCTAssertNotNil(VocabArcheologist.accept(String(repeating: "词", count: 167)))
    }

    func testRouteDefault() {
        let key = VocabArcheologyRoute.storageKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #if PERSONAL_APPS
        XCTAssertEqual(VocabArcheologyRoute.current, .mac, "私用版默认要和以前一样走 Mac")
        UserDefaults.standard.set("app", forKey: key)
        XCTAssertEqual(VocabArcheologyRoute.current, .app)
        #else
        UserDefaults.standard.set("mac", forKey: key)
        XCTAssertEqual(VocabArcheologyRoute.current, .app, "开源版只有 App 路")
        #endif
    }
}
