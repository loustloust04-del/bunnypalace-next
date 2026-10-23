import XCTest
import AppKit
import SwiftStreamingMarkdown
@testable import 记忆花园

final class MacMarkdownFontResolverTests: XCTestCase {
    func testResolutionIsPerFontSizeWeightAndInvalidatedExplicitly() {
        var resolutions = 0
        let resolver = MacMarkdownFontResolver { key in
            resolutions += 1
            return MacMarkdownFontResolver.makeFonts(key)
        }
        for _ in 0..<200 { _ = resolver.fonts(name: "", size: 14, weight: .regular) }
        XCTAssertEqual(resolutions, 1)
        _ = resolver.fonts(name: "", size: 16, weight: .regular)
        _ = resolver.fonts(name: "", size: 14, weight: .bold)
        _ = resolver.fonts(name: "Helvetica", size: 14, weight: .regular)
        XCTAssertEqual(resolutions, 4)
        resolver.invalidate()
        _ = resolver.fonts(name: "", size: 14, weight: .regular)
        XCTAssertEqual(resolutions, 5)
    }

    func testCachedResultPreservesAllFontVariants() {
        let resolver = MacMarkdownFontResolver()
        for name in ["", "Helvetica", "SourceHanSerifSC-Regular", "missing-font-test"] {
            for weight in [NSFont.Weight.regular, .semibold, .bold] {
                let key = MacMarkdownFontResolver.Key(name: name, size: 15, weight: weight.rawValue)
                let expected = MacMarkdownFontResolver.makeFonts(key)
                let actual = resolver.fonts(name: name, size: 15, weight: weight)
                XCTAssertEqual(actual, expected)
            }
        }
    }

    func testRepeatedCustomFontResolutionBenchmark() {
        let key = MacMarkdownFontResolver.Key(name: "SourceHanSerifSC-Regular", size: 13.5, weight: NSFont.Weight.regular.rawValue)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 { _ = MacMarkdownFontResolver.makeFonts(key) }
        let uncachedMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let resolver = MacMarkdownFontResolver()
        _ = resolver.fonts(name: key.name, size: key.size, weight: .regular)
        let warmStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 { _ = resolver.fonts(name: key.name, size: key.size, weight: .regular) }
        let cachedMS = (CFAbsoluteTimeGetCurrent() - warmStart) * 1000
        print("[MAC FONT BENCH] 100 resolutions uncached=\(uncachedMS)ms cached=\(cachedMS)ms")
        // Timing is evidence, not a machine-dependent pass/fail threshold.
    }
}
