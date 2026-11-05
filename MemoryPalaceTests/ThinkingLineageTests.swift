import XCTest
@testable import 记忆花园

/// thinking 回传 §3.5：默认就想 / 默认档位 / display 默认 omitted 三张血统表（点号、OpenRouter 前缀、日期段都认）
final class ThinkingLineageTests: XCTestCase {

    func testThinksByDefault() {
        for m in ["claude-opus-5-5", "claude-opus-5", "anthropic/claude-opus-5.5", "claude-sonnet-5-5", "claude-sonnet-5",
                  "claude-haiku-5-5", "claude-haiku-5-5-20261001", "us.anthropic.claude-sonnet-5-v1:0",
                  "claude-fable-5-1", "claude-fable-5", "claude-mythos", "claude-mythos-5-1"] {
            XCTAssertTrue(ModelLineage.thinksByDefault(m), m)
        }
        for m in ["claude-opus-4-8", "claude-opus-4-7", "claude-opus-4.6", "claude-sonnet-4-6", "claude-sonnet-4-5",
                  "claude-haiku-5", "claude-haiku-4-5", "claude-3-7-sonnet-20250219", "claude-opus-45",
                  "gpt-5", "o3", "deepseek-reasoner", "cc-claude-opus-5-5", ""] {
            XCTAssertFalse(ModelLineage.thinksByDefault(m), m)
        }
    }

    func testDefaultEffort() {
        for m in ["claude-opus-5-5", "claude-opus-5.5", "anthropic/claude-haiku-5.5", "claude-haiku-5-5-20261001"] {
            XCTAssertEqual(ModelLineage.defaultEffort(m), "medium", m)
        }
        for m in ["claude-opus-5", "claude-sonnet-5-5", "claude-sonnet-5", "claude-fable-5-1", "claude-mythos", "claude-opus-4-7", "gpt-5"] {
            XCTAssertEqual(ModelLineage.defaultEffort(m), "high", m)
        }
    }

    func testDisplayDefaultOmitted() {
        for m in ["claude-opus-4-7", "claude-opus-4.8", "claude-opus-5-5", "claude-sonnet-5", "anthropic/claude-sonnet-5.5",
                  "claude-haiku-5-5", "claude-fable-5-1", "claude-mythos"] {
            XCTAssertTrue(ModelLineage.displayDefaultOmitted(m), m)
        }
        for m in ["claude-opus-4-6", "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-haiku-5", "claude-3-7-sonnet-20250219",
                  "gpt-5", "deepseek-reasoner"] {
            XCTAssertFalse(ModelLineage.displayDefaultOmitted(m), m)
        }
    }
}
