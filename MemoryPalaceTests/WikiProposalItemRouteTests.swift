import MemoryCore
import XCTest
#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import SwiftData
import Vision
#endif
@testable import 记忆花园

/// 目录项详情在 mac 设置窗里走 `SettingsRoute.memoryProposalItem`（astra 10-23 P2）：页顶 ‹ › 只认 `[SettingsRoute]`，
/// 目录项进了 path 才回得去、前进得回来
final class WikiProposalItemRouteTests: XCTestCase {
    #if os(macOS)
    @MainActor
    func testRouteTitleAndSelection() {
        XCTAssertEqual("虛構".applyingTransform(StringTransform("Hant-Hans"), reverse: false), "虚构")
        XCTAssertEqual(SettingsRoute.memoryProposalItem.title, "目录项")
        XCTAssertEqual(SettingsRoute(rawValue: "memoryProposalItem"), .memoryProposalItem)
        let before = WikiProposalSelection.shared.item
        defer { WikiProposalSelection.shared.item = before }
        let target = Self.target()
        WikiProposalSelection.shared.item = target
        XCTAssertEqual(WikiProposalSelection.shared.item?.id, target.id)
    }

    private static func target() -> WikiProposalItemTarget {
        let d = WikiProposal.Direction(path: "人/阿青", title: "阿青", hook: "聊到阿青", action: .newPage, reason: "常提", mode: .daily)
        let fragment = WikiProposalItemTarget.fragment(id: UUID(), title: "阿青养猫", content: "阿青养了一只猫", quote: nil, day: nil)
        return WikiProposalItemTarget(proposalId: UUID().uuidString, item: .init(change: .direction(d), baseVersion: nil),
                                      seedTask: nil, fragments: [fragment])
    }

    @MainActor
    @Observable
    final class PathBox {
        var path: [SettingsRoute] = []
    }

    /// 同设置窗：值驱动 path + `navigationDestination(for: SettingsRoute.self)` 落到 `macDestination`
    private struct Host: View {
        @Bindable var box: PathBox

        var body: some View {
            NavigationStack(path: $box.path) {
                Text("根页面")
                    .font(.system(size: 28))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)   // 透明底上的黑字截图后 OCR 认不出
                    .navigationDestination(for: SettingsRoute.self) { $0.macDestination }
            }
            .environment(\.settingsRouteHost, true)
        }
    }

    /// 推进目录项 → ‹（removeLast）回到上一层 → ›（append）又回到目录项，页面内容都在
    @MainActor
    func testBackAndForwardRestoreItemPage() async throws {
        XCTAssertTrue(TestHostIsolation.active)
        guard TestHostIsolation.active, let home = TestHostIsolation.home else { return }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let profile = Profile(id: UUID().uuidString, name: "目录项路由", emoji: "", description: "",
                              userName: "测试者", assistantName: "测试助手")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "WikiProposalItemRouteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let memoryRoot = FileLibraryStore.memoryRoot(profileId: profile.id)
        XCTAssertTrue(TestHostIsolation.contains(memoryRoot, home))
        guard TestHostIsolation.contains(memoryRoot, home) else { return }
        defer { try? FileManager.default.removeItem(at: memoryRoot.deletingLastPathComponent()) }

        let before = WikiProposalSelection.shared.item
        defer { WikiProposalSelection.shared.item = before }
        WikiProposalSelection.shared.item = Self.target()

        let box = PathBox()
        let content = Host(box: box)
            .modelContainer(container)
            .environment(profiles)
            .environment(ThemeManager.shared)
        let controller = NSHostingController(rootView: content)
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }

        try await expect(["根页面"], absent: [], host: host, window: window)
        box.path = [.memoryProposalItem]
        try await expect(["阿青", "原料1份"], absent: ["根页面"], host: host, window: window)
        box.path.removeLast()
        try await expect(["根页面"], absent: ["原料1份"], host: host, window: window)
        box.path.append(.memoryProposalItem)
        try await expect(["阿青", "原料1份", "阿青养猫"], absent: ["根页面"], host: host, window: window)
    }

    /// 提案页能看详情的块整块挂了点进去的手势（粟粟 10-24「为什么不是点那个块直接点进去」）：块里的「驳回」打开原因输入，不推入详情。
    /// 合成鼠标事件打到 OCR 认出来的字上。块身本身推入测不了：测试宿主里合成 NSEvent 只有 AppKit 按钮收得到，
    /// SwiftUI 的 onTapGesture（列表里外都一样）一次都不触发，这里不假装测了。
    /// sheet 内按钮在测试宿主里无法可靠合成点击：r2 的 SwiftUIAppKitButton 无 title / attributedTitle，AX 树无按钮；
    /// r3 的 hitTest 只到 SheetHostingView → NSThemeFrame，合成鼠标事件不触发；r4 按 frame / 最近 x 匹配后，
    /// performClick / sendAction / cell.performClick 仍无响应。这里只验开 sheet，不验 sheet 内按钮；
    /// 取消 / 存 / 驳回的行为由 WikiRejectionTests / WikiReopenTests（服务层）和 sim 手点覆盖。
    @MainActor
    func testRejectionPillOpensReasonSheetWithoutPushingOrChangingState() async throws {
        if screenIsLocked { throw XCTSkip("Mac 锁屏，宿主窗不跑显示周期") }
        XCTAssertTrue(TestHostIsolation.active)
        guard TestHostIsolation.active, let home = TestHostIsolation.home else { return }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let profile = Profile(id: UUID().uuidString, name: "整块点进", emoji: "", description: "",
                              userName: "测试者", assistantName: "测试助手")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "WikiProposalItemRouteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let memoryRoot = FileLibraryStore.memoryRoot(profileId: profile.id)
        XCTAssertTrue(TestHostIsolation.contains(memoryRoot, home))
        guard TestHostIsolation.contains(memoryRoot, home) else { return }
        defer { try? FileManager.default.removeItem(at: memoryRoot.deletingLastPathComponent()) }

        let d = WikiProposal.Direction(path: "人/阿青", title: "阿青", hook: "聊到阿青", action: .newPage, reason: "常提", mode: .daily)
        let detailItem = WikiProposal.Item(change: .direction(d), baseVersion: nil)
        let plainItem = WikiProposal.Item(change: .appendRecords(path: "主题/火锅", lines: ["周五吃了火锅"]), baseVersion: nil)
        XCTAssertTrue(WikiProposalItemTarget.hasDetail(detailItem))
        XCTAssertFalse(WikiProposalItemTarget.hasDetail(plainItem))
        let proposal = WikiProposal(origin: .scheduled, createdAt: Date(), items: [detailItem, plainItem])
        let store = WikiProposalStore(wiki: WikiStore(profileId: profile.id))
        try store.save(proposal)

        let before = WikiProposalSelection.shared.item
        defer { WikiProposalSelection.shared.item = before }
        WikiProposalSelection.shared.item = nil

        let box = PathBox()
        let content = NavigationStack(path: Binding(get: { box.path }, set: { box.path = $0 })) {
            WikiProposalDetailPage(proposalId: proposal.id, viewModel: nil)
                .background(Color.white)
                .navigationDestination(for: SettingsRoute.self) { $0.macDestination }
        }
        .environment(\.settingsRouteHost, true)
        .environment(\.settingsRoutePush) { box.path.append($0) }
        .modelContainer(container)
        .environment(profiles)
        .environment(ThemeManager.shared)
        let controller = NSHostingController(rootView: content)
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }

        try await expect(["阿青", "周五吃了火锅", "驳回"], absent: [], host: host, window: window)

        // 能看详情那块里的「驳回」只打开原因输入，不推入详情、不改变任一条目的状态。
        try await click("驳回", below: "聊到阿青", host: host, window: window)
        let sheet = try await waitForSheet(window: window)
        defer { sheet.sheetParent?.endSheet(sheet) }
        let sheetHost = try XCTUnwrap(sheet.contentView?.superview)
        try await expect(["驳回这条", "驳回原因", "0200", "取消"], absent: [], host: sheetHost, window: sheet)
        XCTAssertEqual(store.load(proposal.id)?.items.first?.state, .pending)
        XCTAssertEqual(box.path, [], "点块里的驳回不该推入")
        XCTAssertNil(WikiProposalSelection.shared.item)
        XCTAssertEqual(store.load(proposal.id)?.items.last?.state, .pending, "没详情那块不该被连带")
    }

    /// 只验主窗「重新编辑」打开含驳回上下文的 sheet；sheet 内按钮的宿主限制和覆盖边界见上一用例。
    @MainActor
    func testReopenPillOpensContextSheetWithoutPushingOrChangingState() async throws {
        if screenIsLocked { throw XCTSkip("Mac 锁屏，宿主窗不跑显示周期") }
        XCTAssertTrue(TestHostIsolation.active)
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let profile = Profile(id: UUID().uuidString, name: "虚构重开验收", emoji: "", description: "",
                              userName: "虚构测试者", assistantName: "虚构助手")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "WikiReopenUI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let memoryRoot = FileLibraryStore.memoryRoot(profileId: profile.id)
        guard let home = TestHostIsolation.home, TestHostIsolation.contains(memoryRoot, home) else { return XCTFail("夹具未隔离") }
        defer { try? FileManager.default.removeItem(at: memoryRoot.deletingLastPathComponent()) }
        let row = Memory(content: "虚构纸舟在剧场夜航", category: "fact", profileId: profile.id)
        context.insert(row)
        try context.save()
        let page = WikiPage(path: "主题/虚构纸舟", kind: .topic, triggers: [], hook: "谈到剧场时",
            title: "虚构纸舟", now: "剧场设定",
            records: ["虚构纸舟在剧场夜航（出处：\(CatalogSources.label(row.id))）"])
        let item = WikiProposal.Item(change: .newPage(page: page), fragmentIds: [row.id],
            staleReason: "虚构旧页提示", withdrawals: [.init(at: Date(), receiptId: "fictional-withdrawal", note: "虚构撤回原因")])
        let proposal = WikiProposal(origin: .manual, createdAt: Date(), items: [item])
        let store = WikiProposalStore(wiki: WikiStore(profileId: profile.id))
        try store.save(proposal)
        _ = try await WikiProposalReview.reject(proposal.id, reasons: [item.id: "只写剧场设定"],
            store: store, profileId: profile.id, context: context)
        let rejected = try XCTUnwrap(store.load(proposal.id))
        let rejectedAt = row.organizeRejectedAt
        let box = PathBox()
        let content = NavigationStack(path: Binding(get: { box.path }, set: { box.path = $0 })) {
            WikiProposalDetailPage(proposalId: proposal.id, viewModel: nil)
                .navigationDestination(for: SettingsRoute.self) { $0.macDestination }
        }
        .environment(\.settingsRouteHost, true)
        .environment(\.settingsRoutePush) { box.path.append($0) }
        .modelContainer(container)
        .environment(profiles)
        .environment(ThemeManager.shared)
        let controller = NSHostingController(rootView: content)
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await expect(["重新编辑", "只写剧场设定"], absent: [], host: host, window: window)
        try await click("重新编辑", host: host, window: window)
        let sheet = try await waitForSheet(window: window)
        defer { sheet.sheetParent?.endSheet(sheet) }
        let sheetHost = try XCTUnwrap(sheet.contentView?.superview)
        try await expect(["重新编辑", "驳回原因", "只写剧场设定", "撤回原因", "旧页提示"], absent: [], host: sheetHost, window: sheet)
        XCTAssertEqual(store.load(proposal.id), rejected, "打开不重开")
        XCTAssertEqual(row.organizeRejectedAt, rejectedAt)
        XCTAssertEqual(box.path, [], "点重新编辑不该推入")
    }

    @MainActor
    func testSingleRejectionSheetShowsLimitAndBlocksOverlongReason() async throws {
        let item = Self.target().item
        var canConfirm: Bool?
        let sheet = WikiProposalRejectionSheet(items: [item], batch: false) { _ in XCTFail("文案用例不提交驳回") }
        let (window, host) = rejectionHost(sheet.buttonStyle(RejectionButtonProbe { canConfirm = $0 }))
        defer { window.orderOut(nil); window.close() }
        try await expect(["驳回这条", "0200"], absent: ["最多200字"], host: host, window: window)
        XCTAssertEqual(canConfirm, true)
        let input = try XCTUnwrap(editableTextView(in: host))
        window.makeFirstResponder(input)
        input.insertText(String(repeating: "字", count: 201), replacementRange: NSRange(location: 0, length: 0))
        try await expect(["201200", "最多200字"], absent: [], danger: ["最多200字"], host: host, window: window)
        XCTAssertEqual(canConfirm, false, "超限时驳回钮必须禁用")
        input.insertText("虚构设定", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
        try await expect(["4200"], absent: ["最多200字"], host: host, window: window)
        XCTAssertEqual(canConfirm, true, "缩短原因后驳回钮恢复可用")
    }

    @MainActor
    func testBatchRejectionSheetShowsCommonReasonAndPerItemOverrides() async throws {
        let items = [Self.target().item, Self.target().item]
        let sheet = WikiProposalRejectionSheet(items: items, batch: true) { _ in XCTFail("文案用例不提交驳回") }
        let (window, host) = rejectionHost(sheet)
        defer { window.orderOut(nil); window.close() }
        try await expect(["整批驳回", "共用原因", "逐条覆盖", "0200"], absent: [], host: host, window: window)
    }

    @MainActor
    private func rejectionHost<Content: View>(_ sheet: Content) -> (NSWindow, NSView) {
        let controller = NSHostingController(rootView: sheet)
        controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 520)
        controller.view.wantsLayer = true
        let window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return (window, controller.view.superview ?? controller.view)
    }

    @MainActor
    private func editableTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap { self.editableTextView(in: $0) }.first
    }

    // 锁屏不提供 AX 树；通过 ButtonStyle 观察控件实际收到的公开 isEnabled 环境，不取私有 State。
    private struct RejectionButtonProbe: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        let observe: (Bool) -> Void

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: isEnabled, initial: true) { _, enabled in
                    if configuration.role == .destructive { observe(enabled) }
                }
        }
    }

    private var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as NSDictionary?)?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    @MainActor
    private func sheetDiagnostics(_ window: NSWindow) -> String {
        "windows=\(NSApp.windows.map(\.title)), occlusionState=\(window.occlusionState), "
            + "CGSSessionScreenIsLocked=\(String(describing: (CGSessionCopyCurrentDictionary() as NSDictionary?)?["CGSSessionScreenIsLocked"]))"
    }

    @MainActor
    private func waitForSheet(window: NSWindow, file: StaticString = #filePath, line: UInt = #line) async throws -> NSWindow {
        if screenIsLocked { throw XCTSkip("Mac 锁屏，宿主窗不跑显示周期") }
        let host = try XCTUnwrap(window.contentView, file: file, line: line)
        for _ in 0..<80 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            if let sheet = window.attachedSheet ?? NSApp.windows.first(where: { $0.sheetParent === window }) { return sheet }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("等待 sheet 超时：\(sheetDiagnostics(window))", file: file, line: line)
        return try XCTUnwrap(window.attachedSheet ?? NSApp.windows.first { $0.sheetParent === window }, file: file, line: line)
    }

    /// OCR 找到这段字（`below`：取在那段字下面、离它最近的一处），在字的中心合成一次左键点击
    @MainActor
    private func click(_ text: String, below anchor: String? = nil, host: NSView, window: NSWindow,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        var boxes: [String: [CGRect]] = [:]
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            boxes = [:]
            if let pixels = cached(host)?.cgImage {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: pixels).perform([request])
                for candidate in (request.results ?? []).compactMap({ $0.topCandidates(1).first }) {
                    for needle in [text, anchor].compactMap({ $0 }) {
                        var from = candidate.string.startIndex
                        while let r = candidate.string.range(of: needle, range: from..<candidate.string.endIndex) {
                            // 「已驳回」不算「驳回」那颗胶囊
                            let prefixed = r.lowerBound > candidate.string.startIndex && candidate.string[candidate.string.index(before: r.lowerBound)] == "已"
                            if !prefixed, let b = try candidate.boundingBox(for: r)?.boundingBox { boxes[needle, default: []].append(b) }
                            from = r.upperBound
                        }
                    }
                }
            }
            if boxes[text] != nil, anchor.map({ boxes[$0] != nil }) ?? true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        var hits = boxes[text] ?? []
        if let anchor, let a = boxes[anchor]?.first {
            hits = hits.filter { $0.midY < a.midY }.sorted { $0.midY > $1.midY }   // Vision 原点在左下：下面 = y 更小
        }
        guard let hit = hits.first else {
            XCTFail("OCR 没找到「\(text)」：\(boxes)", file: file, line: line)
            return
        }
        let point = NSPoint(x: hit.midX * host.bounds.width, y: (host.isFlipped ? 1 - hit.midY : hit.midY) * host.bounds.height)
        let location = host.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // 两个都排进事件队列（列表的 mouseDown 会自己开追踪循环从队列里等 mouseUp）
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
    }

    @MainActor
    private func expect(_ expected: [String], absent: [String], danger: [String] = [], host: NSView, window: NSWindow,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        func folded(_ text: String) -> String {
            text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        }
        let expected = expected.map(folded), absent = absent.map(folded), danger = danger.map(folded)
        var visible: [String] = []
        var red: Set<String> = []
        for _ in 0..<80 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            // NSTableView 等 AppKit 子视图要 layer.render 才抓得到；SwiftUI 文字有时只在 cacheDisplay 里，两种都认
            visible = []
            red = []
            for bitmap in [snapshot(host), cached(host)] {
                guard let pixels = bitmap?.cgImage else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: pixels).perform([request])
                for result in request.results ?? [] {
                    guard let candidate = result.topCandidates(1).first else { continue }
                    let text = folded(candidate.string).filter { $0.isLetter || $0.isNumber }
                    visible.append(text)
                    if !danger.isEmpty, let bitmap, hasRedInk(result.boundingBox, in: bitmap) {
                        for needle in danger where text.contains(needle) { red.insert(needle) }
                    }
                }
            }
            if expected.allSatisfy({ t in visible.contains { $0.contains(t) } }),
               !absent.contains(where: { t in visible.contains { $0.contains(t) } }),
               danger.allSatisfy({ red.contains($0) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for t in expected {
            XCTAssertTrue(visible.contains { $0.contains(t) }, "缺 \(t)，OCR：\(visible)", file: file, line: line)
        }
        for t in absent {
            XCTAssertFalse(visible.contains { $0.contains(t) }, "不该有 \(t)，OCR：\(visible)", file: file, line: line)
        }
        for t in danger {
            XCTAssertTrue(red.contains(t), "「\(t)」应显示红字，OCR：\(visible)", file: file, line: line)
        }
    }

    private func hasRedInk(_ box: CGRect, in bitmap: NSBitmapImageRep) -> Bool {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        let minX = max(0, Int(box.minX * Double(width))), maxX = min(width, Int(ceil(box.maxX * Double(width))))
        let minY = max(0, Int((1 - box.maxY) * Double(height))), maxY = min(height, Int(ceil((1 - box.minY) * Double(height))))
        guard minX < maxX, minY < maxY else { return false }
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > color.greenComponent + 0.2,
                   color.redComponent > color.blueComponent + 0.1 { return true }
            }
        }
        return false
    }

    @MainActor
    private func cached(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @MainActor
    private func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 1
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = view.bounds.size
        context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: scale, y: -scale)
        layer.render(in: context.cgContext)
        return bitmap
    }
    #endif
}
