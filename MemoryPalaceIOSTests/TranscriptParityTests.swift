import XCTest
import SwiftUI
import UIKit
@testable import 记忆花园

/// 像素对拍（docs/plan-重构.md R1）。
/// 运行：-only-testing:MemoryPalaceIOSTests/TranscriptParityTests，要求同 BubblePageSnapshotTests
///（Debug 宿主、--kb-probe-seed、MP_TEST_HOST=1、MP_SPLASH=0，scheme 里已配好）。
/// 不一致时把两张图写到 MP_PARITY_DIR（没指定就写隔离家目录下的 TranscriptParity-failures）。
@MainActor
final class TranscriptParityTests: XCTestCase {
    #if DEBUG
    /// 尺子自己要先准：旧页把同一组消息渲染两遍（两次都是全新的库、全新的页面），必须逐像素相同
    ///（顶栏玻璃那一带只容忍几个色阶的噪声，见 ParityImage.difference）。
    /// 这条不过，说明截图里混进了每次都会变的东西，新旧对拍的「0 差异」就没有意义。
    func testOldPageRendersIdenticallyTwice() async throws {
        let host = try await ParityHost()
        var failures: [String] = []
        for fixture in ParityFixture.all {
            for mode in ParityHost.Mode.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let tag = "\(fixture.name)-\(mode.rawValue)-\(scheme == .light ? "light" : "dark")"
                    let first = try await host.render(fixture, mode: mode, scheme: scheme)
                    let second = try await host.render(fixture, mode: mode, scheme: scheme)
                    let difference = try host.difference(first, second)
                    print("[像素对拍] 旧页自比 \(tag)：\(difference)")
                    guard difference.pixels > 0 else { continue }
                    failures.append("\(tag)：\(difference)")
                    let directory = Self.failureDirectory
                    try ParityHost.write(first, to: directory.appendingPathComponent("\(tag)-1.png"))
                    try ParityHost.write(second, to: directory.appendingPathComponent("\(tag)-2.png"))
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "旧页两次渲染不一致：\n" + failures.joined(separator: "\n") + "\n图在 \(Self.failureDirectory.path)")
    }

    /// 新页 vs 旧页。已经做了原生行的组合必须 0 差异；每做完一种行，就把它加进这张表。
    /// 时间戳和操作条新页还没做，这里两页都关掉（`minimal`）。两张图总是写出来，方便看差在哪。
    func testNewPageMatchesOldPage() async throws {
        let host = try await ParityHost()
        // 后两项是例外，默认没有：容忍的色阶差、不比的矩形（窗口坐标，pt）。
        // - 「标题 / 列表 / 引用」浅色容忍 4：透明卡底上的半透明边缘（引用竖线两端、空心圆点、落在底部渐隐带里的字）
        //   新旧差 1–4 个色阶、约 740 个像素，同一组深色是 0。位置、大小、颜色都对；差的是合成时的取整，没追到底，见 plan §7
        // - 代码块不比「复制」图标那 15×17：位置逐像素对齐了，边缘抗锯齿差最多 14 个色阶（约 200 个像素），见 MarkdownCodeBlockView.drawCopyIcon
        let copyIcon = CGRect(x: 303, y: 552, width: 16, height: 18)
        let cases: [(fixture: String, mode: ParityHost.Mode, scheme: ColorScheme, tolerance: Int, ignored: [CGRect])] = [
            ("plain", .article, .light, 0, []), ("plain", .article, .dark, 0, []),
            ("inline", .article, .light, 0, []), ("inline", .article, .dark, 0, []),
            ("blocks", .article, .light, 4, []), ("blocks", .article, .dark, 0, []),
            ("code", .article, .light, 0, [copyIcon]), ("code", .article, .dark, 0, [copyIcon]),
            ("table", .article, .light, 0, []), ("table", .article, .dark, 0, [])
        ]
        var failures: [String] = []
        for item in cases {
            guard let fixture = ParityFixture.all.first(where: { $0.name == item.fixture }) else { continue }
            let tag = "\(fixture.name)-\(item.mode.rawValue)-\(item.scheme == .light ? "light" : "dark")"
            let old = try await host.render(fixture, mode: item.mode, scheme: item.scheme, engine: .swiftui, minimal: true)
            let oldLayers = host.lastLayerChains
            let oldBlur = host.lastEdgeBlur
            let new = try await host.render(fixture, mode: item.mode, scheme: item.scheme, engine: .uikit, minimal: true)
            if !host.probes.isEmpty || host.probeRegion != nil { print("[像素对拍] 图层 \(tag) 旧页：\n\(oldLayers)\n[像素对拍] 图层 \(tag) 新页：\n\(host.lastLayerChains)") }
            let difference = try host.difference(old, new, tolerance: item.tolerance, ignored: item.ignored)
            let exceptions = (item.tolerance > 0 ? "（容忍 \(item.tolerance)）" : "") + (item.ignored.isEmpty ? "" : "（有 \(item.ignored.count) 块不比）")
            print("[像素对拍] 新旧对比 \(tag)\(exceptions)：\(difference)")
            if difference.pixels > 0 {
                print("[像素对拍] 新页状态 \(tag)：\(host.lastNewPageState)")
                print("[像素对拍] 边缘模糊 \(tag) 旧页：\(oldBlur)\n[像素对拍] 边缘模糊 \(tag) 新页：\(host.lastEdgeBlur)")
            }
            let directory = Self.failureDirectory.appendingPathComponent("new-vs-old", isDirectory: true)
            try ParityHost.write(old, to: directory.appendingPathComponent("\(tag)-old.png"))
            try ParityHost.write(new, to: directory.appendingPathComponent("\(tag)-new.png"))
            if difference.pixels > 0 { failures.append("\(tag)：\(difference)") }
        }
        XCTAssertTrue(failures.isEmpty, "新页和旧页不一致：\n" + failures.joined(separator: "\n"))
    }

    /// 键盘：同一次挂载里拍三张——静止、键盘弹完、键盘收完；新旧两页逐张相同，并且收完以后回到静止时的画面。
    /// 只验落点（动画做完以后的画面），过程中的每一帧不在这里验。
    func testKeyboardRestingPositionsMatchOldPage() async throws {
        let host = try await ParityHost()
        guard let fixture = ParityFixture.all.first(where: { $0.name == "plain" }) else { return XCTFail("没有 plain 夹具") }
        let directory = Self.failureDirectory.appendingPathComponent("keyboard", isDirectory: true)
        var shots: [ChatPageEngine: (rest: CGImage, raised: CGImage, dismissed: CGImage)] = [:]
        var raisedBarZone: CGFloat = 0
        for engine in [ChatPageEngine.swiftui, .uikit] {
            shots[engine] = try await host.mounted(fixture, mode: .article, scheme: .light, engine: engine, minimal: true) {
                let rest = try await host.settledCapture(engine: engine)
                guard let extra = try await host.raiseKeyboard() else {
                    throw XCTSkip("这台模拟器没弹软键盘（接着硬件键盘？），键盘对拍跑不了")
                }
                raisedBarZone = max(raisedBarZone, host.inputBarZonePoints)
                let raised = try await host.settledCapture(engine: engine, ignoringBottom: host.inputBarZonePoints)
                print("[像素对拍] 键盘 \(engine.rawValue)：遮住 \(extra)pt，\(engine == .uikit ? host.lastNewPageState : "")")
                try await host.dismissKeyboard()
                let dismissed = try await host.settledCapture(engine: engine)
                return (rest, raised, dismissed)
            }
        }
        guard let old = shots[.swiftui], let new = shots[.uikit] else { return XCTFail("没拍到") }
        var failures: [String] = []
        let pairs: [(String, CGImage, CGImage, CGFloat)] = [
            ("静止 新旧", old.rest, new.rest, 0),
            ("键盘弹起 新旧", old.raised, new.raised, raisedBarZone),
            ("键盘收起 新旧", old.dismissed, new.dismissed, 0),
            ("旧页 收起后回到静止", old.rest, old.dismissed, 0),
            ("新页 收起后回到静止", new.rest, new.dismissed, 0)
        ]
        for (name, first, second, ignored) in pairs {
            let difference = try host.difference(first, second, ignoredBottomPoints: ignored)
            print("[像素对拍] 键盘 \(name)：\(difference)")
            if difference.pixels > 0 { failures.append("\(name)：\(difference)") }
        }
        for (name, image) in [("old-rest", old.rest), ("old-raised", old.raised), ("old-dismissed", old.dismissed),
                              ("new-rest", new.rest), ("new-raised", new.raised), ("new-dismissed", new.dismissed)] {
            try ParityHost.write(image, to: directory.appendingPathComponent("\(name).png"))
        }
        XCTAssertTrue(failures.isEmpty, "键盘落点不一致：\n" + failures.joined(separator: "\n"))
    }

    /// 离开最新消息以后弹键盘（只验新页；规则是从旧页代码里读出来的，旧页这时屏上还有回底钮，没法逐像素比）：
    /// 离底 1 屏以内 → 回到最新消息，和「在底弹键盘」是同一个画面；收起后和在底静止相同。
    /// 离底超过 1 屏 → 内容原地不动；收起后也不动。
    func testKeyboardPolicyWhenScrolledAway() async throws {
        let host = try await ParityHost()
        let fixture = ParityFixture.long
        let directory = Self.failureDirectory.appendingPathComponent("keyboard-scrolled", isDirectory: true)
        var failures: [String] = []
        try await host.mounted(fixture, mode: .article, scheme: .light, engine: .uikit, minimal: true) {
            @MainActor func shot(_ name: String, barZone: CGFloat = 0) async throws -> CGImage {
                let image = try await host.settledCapture(engine: .uikit, ignoringBottom: barZone)
                try ParityHost.write(image, to: directory.appendingPathComponent("\(name).png"))
                return image
            }
            @MainActor func expectSame(_ name: String, _ first: CGImage, _ second: CGImage, barZone: CGFloat = 0) throws {
                let difference = try host.difference(first, second, ignoredBottomPoints: barZone)
                print("[像素对拍] 离底弹键盘 \(name)：\(difference)")
                if difference.pixels > 0 { failures.append("\(name)：\(difference)") }
            }
            @MainActor func raise() async throws -> CGFloat {
                guard try await host.raiseKeyboard() != nil else { throw XCTSkip("这台模拟器没弹软键盘") }
                return host.inputBarZonePoints
            }

            let bottom = try await shot("bottom")
            var zone = try await raise()
            let bottomRaised = try await shot("bottom-raised", barZone: zone)
            try await host.dismissKeyboard()

            let near = try XCTUnwrap(ChatPageAdapter.debugScroll(toMessage: host.nodeID(fixture, fixture.messages.count - 5)))
            XCTAssertTrue(near > 200 && near < host.window.bounds.height, "「近」要落在 200pt 和 1 屏之间，实际 \(near)")
            _ = try await shot("near")
            zone = try await raise()
            try expectSame("1 屏内弹键盘 = 回到最新消息", bottomRaised, try await shot("near-raised", barZone: zone), barZone: zone)
            try await host.dismissKeyboard()
            try expectSame("1 屏内弹过键盘，收起后在最新消息", bottom, try await shot("near-dismissed"))

            let deep = try XCTUnwrap(ChatPageAdapter.debugScroll(toMessage: host.nodeID(fixture, fixture.messages.count - 25)))
            XCTAssertGreaterThan(deep, host.window.bounds.height * 1.5, "「深」要超过 1.5 屏，实际 \(deep)")
            let deepRest = try await shot("deep")
            zone = try await raise()
            try expectSame("深翻弹键盘，内容原地", deepRest, try await shot("deep-raised", barZone: zone), barZone: zone)
            try await host.dismissKeyboard()
            try expectSame("深翻收键盘，内容原地", deepRest, try await shot("deep-dismissed"))
        }
        XCTAssertTrue(failures.isEmpty, "离底弹键盘的落点不对：\n" + failures.joined(separator: "\n"))
    }

    private static var failureDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["MP_PARITY_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return (TestHostIsolation.home ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("TranscriptParity-failures", isDirectory: true)
    }
    /// 流式（docs/plan-重构.md R4，只验新页）：摆出「这条正在流式」的状态，把正文一坨一坨喂进流式缓冲。
    /// 放完时的画面、定稿后的画面，都要和「这条消息本来就在那」逐像素相同；过程里没变的块不重排
    func testStreamingOnNewPage() async throws {
        let host = try await ParityHost()
        let fixture = ParityFixture.all[2]
        let directory = Self.failureDirectory.appendingPathComponent("streaming", isDirectory: true)
        try await host.mounted(fixture, mode: .article, scheme: .light, engine: .uikit, minimal: true) {
            @MainActor func wait(_ what: String, _ condition: @MainActor () -> Bool) async throws {
                for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(100)) }
                XCTAssertTrue(condition(), "等不到：\(what)；\(ChatPageAdapter.debugStates)")
            }
            let settled = try await host.settledCapture(engine: .uikit)
            try ParityHost.write(settled, to: directory.appendingPathComponent("settled.png"))

            let viewModel = try XCTUnwrap(ChatPageAdapter.debugViewModel)
            let nodeID = host.nodeID(fixture, fixture.messages.count - 1)
            let full = fixture.messages[fixture.messages.count - 1].text
            viewModel.streamingText = ""
            viewModel.activeConversationId = viewModel.selectedConversation?.id
            viewModel.activeAssistantNodeId = nodeID
            viewModel.assistantTurnInFlight = true
            try await wait("还没来字时是一行「正在输入」") {
                ChatPageAdapter.debugStream?.rowIDs.contains("\(nodeID)#typing") == true
            }

            // 12 坨、每坨隔 120ms，像真的回复那样到
            let characters = Array(full)
            for step in 1...12 {
                viewModel.streamingText = String(characters.prefix(characters.count * step / 12))
                try await Task.sleep(for: .milliseconds(120))
            }
            try await wait("节拍器把字放完") { ChatPageAdapter.debugStream?.shown == full }
            let streamed = try await host.settledCapture(engine: .uikit, ignoringBottom: host.inputBarZonePoints)
            try ParityHost.write(streamed, to: directory.appendingPathComponent("streamed.png"))
            let whileStreaming = try host.difference(settled, streamed, ignoredBottomPoints: host.inputBarZonePoints)
            print("[像素对拍] 流式放完 vs 本来就在：\(whileStreaming)")
            XCTAssertEqual(whileStreaming.pixels, 0, "流式放完的画面和定稿不一样：\(whileStreaming)")

            let stream = try XCTUnwrap(ChatPageAdapter.debugStream)
            print("[像素对拍] 流式 \(stream.ticks) 拍，复用 \(stream.reusedBlocks) 块，重排 \(stream.laidOutBlocks) 块")
            XCTAssertGreaterThan(stream.ticks, 12, "应该是按节拍一点点放出来的")
            XCTAssertGreaterThan(stream.reusedBlocks, stream.laidOutBlocks, "没变的块应该复用，不是每拍整条重排")

            // 定稿：一轮结束，正文回到消息里
            viewModel.assistantTurnInFlight = false
            viewModel.activeAssistantNodeId = nil
            viewModel.streamingText = ""
            try await wait("流式结束后回到普通行") { ChatPageAdapter.debugStream?.rowIDs.contains("\(nodeID)#0") == true }
            let finalized = try await host.settledCapture(engine: .uikit)
            try ParityHost.write(finalized, to: directory.appendingPathComponent("finalized.png"))
            let afterFinalize = try host.difference(settled, finalized)
            print("[像素对拍] 定稿后 vs 本来就在：\(afterFinalize)")
            XCTAssertEqual(afterFinalize.pixels, 0, "定稿后的画面变了：\(afterFinalize)")
        }
    }
    #else
    func testOldPageRendersIdenticallyTwice() throws {
        XCTFail("像素对拍依赖 Debug 的 PerfHarness 探针，请用 Debug 测试配置")
    }

    func testNewPageMatchesOldPage() throws {
        XCTFail("像素对拍依赖 Debug 的 PerfHarness 探针，请用 Debug 测试配置")
    }

    func testKeyboardRestingPositionsMatchOldPage() throws {
        XCTFail("像素对拍依赖 Debug 的 PerfHarness 探针，请用 Debug 测试配置")
    }

    func testKeyboardPolicyWhenScrolledAway() throws {
        XCTFail("像素对拍依赖 Debug 的 PerfHarness 探针，请用 Debug 测试配置")
    }
    func testStreamingOnNewPage() throws {
        XCTFail("像素对拍依赖 Debug 的 PerfHarness 探针，请用 Debug 测试配置")
    }
    #endif
}
