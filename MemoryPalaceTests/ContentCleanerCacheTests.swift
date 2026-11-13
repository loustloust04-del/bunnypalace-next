import MemoryCore
import XCTest
@testable import 记忆花园

/// 10-31 正文末尾截断 / ```react 框露出：ContentCleaner 缓存命中不核对原文（research-article-truncation-1031 §1.4）
final class ContentCleanerCacheTests: XCTestCase {

    /// 气泡：流式逐字写 "\(id)_\(n)" 键 → 收口剥 react → 静态按新字数查键，不能拿到流式快照
    func testStreamingSnapshotPoisonsStaticKeyAfterReactSettle() {
        let id = "repro-\(UUID().uuidString)"
        let stream = "```react\n❤️\n```\n\n（在你嘴唇上笑了一下）\n\n……猫猫亲回来了。\n\n（把你抱紧了一点，鼻子蹭着你的头发，蹭了好一会儿。）"
        for n in 1...stream.count {
            let live = String(stream.prefix(n))
            _ = ContentCleaner.clean(live, cacheKey: "\(id)_\(live.count)")
        }
        let settled = ChatReactionIntent.settle(stream).text
        XCTAssertLessThan(settled.count, stream.count)
        let shown = ContentCleaner.clean(settled, cacheKey: "\(id)_\(settled.count)")
        XCTAssertEqual(shown, settled)
    }

    /// 文章模式同样会中：意向块（以 voice 为例）收口剥掉，content 变短
    func testIntentBlockStripCollidesInArticleMode() {
        let id = "repro-\(UUID().uuidString)"
        let block = "```voice\n嗯，晚安\n```\n\n"
        let stream = block + "说完就睡吧。明天见。"
        for n in 1...stream.count { _ = ContentCleaner.clean(String(stream.prefix(n)), cacheKey: "\(id)_\(n)") }
        let final = String(stream.dropFirst(block.count))
        XCTAssertEqual(ContentCleaner.clean(final, cacheKey: "\(id)_\(final.count)"), final)
    }

    /// cacheKey: node.id 那批调用点：键不变、content 被改写（剥块 / 意向写回 / 编辑）后要返回新结果
    func testSameKeyDifferentSourceRecomputes() {
        let key = "node-\(UUID().uuidString)"
        let before = "改写前的正文【12†L1-L2】还带引用"
        XCTAssertEqual(ContentCleaner.clean(before, cacheKey: key), "改写前的正文还带引用")
        let after = "改写后的正文，没有标记"
        XCTAssertEqual(ContentCleaner.clean(after, cacheKey: key), after)
        let afterWithRef = "又改了一次【turn0search3】"
        XCTAssertEqual(ContentCleaner.clean(afterWithRef, cacheKey: key), "又改了一次")
    }
}
