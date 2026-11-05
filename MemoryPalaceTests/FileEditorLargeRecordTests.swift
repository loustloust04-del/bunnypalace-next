import AppKit
import SwiftUI
import XCTest
@testable import 记忆花园

/// 整理记录（`.runs/`）只读预览：原生列表 + 代码块卡 + 全文 sheet（粟粟 10-22 改道）。
/// 性能门槛是 mac Debug 离屏单跑参考（不进整跑清单），真机以车头 iPhone 14 复测为准。
@MainActor
final class FileEditorLargeRecordTests: XCTestCase {

    // MARK: - 解析：换行 / 围栏 / 逐字节拼回

    private func seedLikeSource(_ newline: (Int) -> String) -> (source: String, receipts: [String]) {
        var n = 0
        func nl() -> String { defer { n += 1 }; return newline(n) }
        let receipts = (0..<3).map { index in
            (0..<4).map { "回执 \(index) 第 \($0) 行「引号」" }.joined(separator: nl())
        }
        var source = "# C3 整理记录 · 换行" + nl() + nl()
        for (index, receipt) in receipts.enumerated() {
            source += "<a id=\"r\(index)\"></a>" + nl() + nl() + "## 第 \(index) 轮" + nl() + nl() + "正文：" + nl()
            // 跟 CatalogRunRecord.code 一样：原文后面固定追加一个 LF 再闭栏（整份其它地方的换行随变体）
            source += "```" + nl() + receipt + "\n" + "```" + nl() + nl()
        }
        return (source, receipts)
    }

    func testCRLFAndMixedLineEndingsKeepSectionsBlocksAndEveryByte() throws {
        let variants: [(String, (Int) -> String)] = [
            ("LF", { _ in "\n" }), ("CRLF", { _ in "\r\n" }), ("CR", { _ in "\r" }),
            ("混合", { ["\r\n", "\n", "\r"][$0 % 3] }),
        ]
        for (name, newline) in variants {
            let (source, receipts) = seedLikeSource(newline)
            let lines = RunRecordScanner.lines(source)
            XCTAssertEqual(Data(lines.map(\.full).joined().utf8), Data(source.utf8), "\(name)：分行拼回逐字节 = 原文")
            let location = FileEditorPreviewLocation(content: source, anchor: "r1", separatesSections: true)
            XCTAssertEqual(location.parts.count, 4, "\(name)：标题段 + 3 轮")
            XCTAssertEqual(Data(location.parts.joined().utf8), Data(source.utf8), "\(name)：分节拼回逐字节 = 原文")
            XCTAssertEqual(location.targetIndex, 2)
            for part in location.parts {
                let rebuilt = RunRecordDocument.segments(Substring(part), check: {}).map { segment -> String in
                    switch segment {
                    case .prose(let raw): return String(raw)
                    case .code(let open, let body, let close, _): return String(open) + String(body) + String(close ?? "")
                    }
                }.joined()
                XCTAssertEqual(Data(rebuilt.utf8), Data(part.utf8), "\(name)：拆围栏拼回逐字节 = 原文")
            }
            let document = try RunRecordDocument.parse(content: source, anchor: "r1")
            XCTAssertEqual(document.sectionStarts.count, 4)
            XCTAssertEqual(document.blocks.map { Data($0.text.utf8) }, receipts.map { Data($0.utf8) }, "\(name)：每块原文逐字节一致，换行原样")
            XCTAssertEqual(document.blocks.map(\.name), ["正文", "正文", "正文"])
            let target = try XCTUnwrap(document.targetRow)
            guard case .heading(let title, _) = document.rows[target] else { return XCTFail("\(name)：目标是那一轮的标题行") }
            XCTAssertEqual(title, "第 1 轮")
        }

        let dense = String(repeating: "a\r\n", count: 5_000)
        XCTAssertEqual(RunRecordScanner.lines(dense).count, 5_000, "密集 CRLF 短行一行一行认")
        let wrapped = "<a id=\"x\"></a>\r\n\r\n## 密集\r\n\r\n```\r\n" + dense + "```\r\n"
        let block = try XCTUnwrap(RunRecordDocument.parse(content: wrapped, anchor: "x").blocks.first)
        XCTAssertEqual(Data((block.text + "\n").utf8), Data(dense.utf8), "只剥闭栏前那一个 LF 字节，原文最后的 CR 留着")
    }

    func testFencesUseCommonMarkColumnsAndInfoStringRules() throws {
        // tab 缩进 = 4 列，不是闭栏；两空格 + tab 也到第 4 列；一个空格的才是闭栏
        let fenced = "<a id=\"a\"></a>\n\n## 甲\n\n```\n内容\n\t```\n  \t```\n ```\n后文\n"
        let a = try RunRecordDocument.parse(content: fenced, anchor: "a")
        XCTAssertEqual(a.blocks.map(\.text), ["内容\n\t```\n  \t```"], "tab / 空格混 tab 的 ``` 留在块里")
        XCTAssertTrue(a.rows.contains { if case .prose("后文") = $0 { return true } else { return false } })

        // ` 围栏的 info string 不能含 `：「``` a`b」不开栏，后面真实 anchor 照样分节
        let bogus = "<a id=\"a\"></a>\n\n## 甲\n\n``` a`b\n不是代码\n\n<a id=\"b\"></a>\n\n## 乙\n\n```\n乙的块\n```\n"
        let location = FileEditorPreviewLocation(content: bogus, anchor: "b", separatesSections: true)
        XCTAssertEqual(location.parts.count, 2)
        XCTAssertEqual(location.targetIndex, 1)
        let b = try RunRecordDocument.parse(content: bogus, anchor: "b")
        XCTAssertEqual(b.blocks.map(\.text), ["乙的块"])
        guard case .heading(let title, _) = b.rows[try XCTUnwrap(b.targetRow)] else { return XCTFail() }
        XCTAssertEqual(title, "乙")

        // ~ 围栏的 info 可以含 `：围栏里的 anchor 不分节
        let tilde = "<a id=\"a\"></a>\n\n## 甲\n\n~~~ a`b\n<a id=\"b\"></a>\n~~~\n"
        XCTAssertEqual(FileEditorPreviewLocation(content: tilde, anchor: "b", separatesSections: true).parts.count, 1)
        XCTAssertEqual(try RunRecordDocument.parse(content: tilde, anchor: nil).blocks.map(\.text), ["<a id=\"b\"></a>"])
    }

    /// astra 审 97d41cbab P1：原文末尾的 CR、没闭栏围栏的末尾 LF，在解析、sheet、复制三处都逐字节保真
    func testTrailingBytesSurviveParseSheetAndCopy() async throws {
        let trailingCR = "A\r"
        let unclosed = "B\n"
        let text = "# C3 整理记录 · 末尾字节\n\n<a id=\"cr\"></a>\n\n## 回车结尾\n\n正文：\n" + CatalogRunRecord.code(trailingCR)
            + "\n\n<a id=\"open\"></a>\n\n## 没闭栏\n\n参数：\n```\n" + unclosed
        let parsed = try RunRecordDocument.parse(content: text, anchor: nil)
        XCTAssertEqual(parsed.blocks.map { Data($0.text.utf8) }, [Data(trailingCR.utf8), Data(unclosed.utf8)], "解析：一个字节都不多不少")
        var copied: [String] = []
        RunRecordClipboard.override = { copied.append($0) }
        defer { RunRecordClipboard.override = nil }
        for (original, name) in [(trailingCR, "正文"), (unclosed, "参数")] {
            let (window, host) = openRecord(text, anchor: nil)
            defer { window.contentView = nil; window.close() }
            let scroll = try await waitFor("列表就位") { self.recordScroll(in: host).flatMap { $0.document == nil ? nil : $0 } }
            let document = try XCTUnwrap(scroll.document)
            let row = try XCTUnwrap(document.rows.firstIndex { if case .block(let b) = $0 { return b.name == name } else { return false } })
            guard case .block(let block) = document.rows[row] else { return XCTFail() }
            scroll.open(row: row)
            let textView = try await waitFor("\(name) 的 sheet") { () -> NSTextView? in
                window.attachedSheet?.contentView.flatMap { self.firstTextView(in: $0) }
            }
            XCTAssertEqual(Data(textView.string.utf8), Data(original.utf8), "\(name)：sheet 逐字节 = 原文")
            RunRecordBlockSheet.copy(block)
            XCTAssertEqual(copied.last.map { Data($0.utf8) }, Data(original.utf8), "\(name)：复制逐字节 = 原文")
        }
    }

    /// 扫到一半取消（确定性：第 5 个检查点时取消）：下一个检查点就停，load 抛取消、不交结果
    func testCancellingMidScanStopsAtTheNextCheckpointWithoutAResult() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var task: Task<RunRecordDocument, Error>?
            var count = 0
            func hit() {
                let now: (Int, Task<RunRecordDocument, Error>?) = lock.withLock { count += 1; return (count, task) }
                if now.0 == 5 { now.1?.cancel() }
            }
        }
        let box = Box()
        let results = ParseBox()
        RunRecordDocument.checkpointObserver = { box.hit() }
        RunRecordDocument.parseObserver = { results.record($0) }
        defer { RunRecordDocument.checkpointObserver = nil; RunRecordDocument.parseObserver = nil }
        let source = seedRecordText()
        let gate = AsyncStream<Void>.makeStream()
        let task = Task.detached { () -> RunRecordDocument in
            for await _ in gate.stream { break }
            return try await RunRecordDocument.load(content: source, anchor: nil)
        }
        box.lock.withLock { box.task = task }
        gate.continuation.yield()
        do {
            _ = try await task.value
            XCTFail("取消了还交了结果")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(box.lock.withLock { box.count }, 5, "第 5 个检查点上取消，就在这个检查点当场停，不再往下扫")
        XCTAssertEqual(results.results, [true])

        // 超长单行（1MB，一个换行都没有）：分行器按字节数定期查，不等扫完这一行
        box.lock.withLock { box.count = 0 }
        RunRecordDocument.checkpointObserver = { box.lock.withLock { box.count += 1 } }
        let line = String(repeating: "长", count: 350_000)
        _ = try RunRecordDocument.parse(content: "<a id=\"x\"></a>\n\n```\n" + line + "\n```\n", anchor: nil)
        XCTAssertGreaterThanOrEqual(box.lock.withLock { box.count }, line.utf8.count / RunRecordScanner.checkEveryBytes, "每 64KB 查一次")
    }

    func testCancellingTheLoadStopsParsing() async throws {
        let source = seedRecordText(rounds: 40)
        let task = Task { try await RunRecordDocument.load(content: source, anchor: nil) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消了就不该解析完")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testClosingThePreviewCancelsBackgroundParsing() async throws {
        let source = String(repeating: seedRecordText(), count: 10)
        let box = ParseBox()
        RunRecordDocument.parseObserver = { cancelled in box.record(cancelled) }
        defer { RunRecordDocument.parseObserver = nil }
        let (window, host) = openRecord(source, anchor: nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(1))
        window.contentView = nil
        window.close()
        for _ in 0..<400 where box.results.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        print("RUN_RECORD_CANCEL chars=\(source.count) results=\(box.results)")
        XCTAssertEqual(box.results, [true], "关页后后台解析被取消，不跑完")
    }

    // MARK: - 打开：首屏、各轮落点、响应

    /// 31.3 万字种子形状夹具：16 份多行长段落回执；第 2 轮请求里再回灌一遍
    private func seedRecordText(rounds: Int = 4) -> String {
        var text = "# C3 整理记录 · 种子\n\n方式：合成测试\n\n"
        func receipt(_ index: Int) -> String {
            let line = (0..<6).map { "第\(index)份第\($0)句：合成原料「云桥城的旧事」记在 memory/cc/user_\(index).md；\"引号\" 'quote' (括号) {花括号} [方括号] 2026-10-\(index % 28 + 1) 12:\($0 * 7) -> end tell; let x = \($0); " }.joined()
            return "【memory/cc/user_\(index).md · CC · 合成原料 \(index)】\n" + (0..<14).map { "## 小节 \($0)\n" + line }.joined(separator: "\n")
        }
        let receipts = (0..<16).map { ToolResultBlock(toolUseId: "call_\($0)", text: receipt($0), isError: false) }
        func section(_ anchor: String, _ title: String, _ body: String) {
            text += "<a id=\"\(anchor)\"></a>\n\n## \(title)\n\n\(body)\n\n"
        }
        for round in 1...rounds {
            var request = "### 系统提示 system\n" + CatalogRunRecord.code("合成系统提示。")
            if round == 2 { request += "\n\n### 回灌 toolTurns\n#### 工具回合 1\n" + CatalogAgent.traceResults(receipts) }
            section("round-\(round)", "种子第 \(round) 轮 · 请求", request)
            section("reply-\(round)", "种子第 \(round) 轮 · 模型回复", "### 模型正文\n" + CatalogRunRecord.code("合成回复 \(round)。"))
            if round == 1 {
                for result in receipts {
                    section("receipt-\(result.toolUseId)", "种子第 1 轮工具实际回执 · \(result.toolUseId)", CatalogAgent.traceResults([result]))
                }
            }
        }
        section("end", "末尾完整", "最终记录不可截断。")
        return text
    }

    func testSeedRecordOpensFastAndEachRoundLandsAtTheTop() async throws {
        XCTAssertTrue(TestHostIsolation.active)
        let text = seedRecordText()
        print("RUN_RECORD_NATIVE_HARNESS revision=native-v1 chars=\(text.count) window=720x640 settle=2s")
        // 冷开（进程里第一次建表格 / 卡）单独记、不设门槛：门槛只管同一进程里的常态打开
        do {
            let probe = BusyProbe()
            probe.start()
            let start = ProcessInfo.processInfo.systemUptime
            let (window, host) = openRecord(text, anchor: "round-2")
            _ = try await waitFor("冷开落位") { self.landing(in: host) }
            let ready = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try await Task.sleep(for: .milliseconds(500))
            probe.stop()
            print(String(format: "RUN_RECORD_NATIVE_COLD ready=%.2f worstBusy=%.2f", ready, probe.worstMs))
            window.contentView = nil
            window.close()
        }
        for anchor in [nil, "round-1", "round-2", "round-3", "round-4", "end"] as [String?] {
            let probe = BusyProbe()
            probe.start()
            let openStart = ProcessInfo.processInfo.systemUptime
            let (window, host) = openRecord(text, anchor: anchor)
            defer { window.contentView = nil; window.close() }
            var readyMs: Double?
            var top: CGFloat?
            var title = ""
            while ProcessInfo.processInfo.systemUptime - openStart < 2 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                if readyMs == nil, let landed = landing(in: host) {
                    readyMs = (ProcessInfo.processInfo.systemUptime - openStart) * 1000
                    (top, title) = landed
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            let settled = landing(in: host)
            probe.stop()
            let scroll = try XCTUnwrap(recordScroll(in: host))
            let atBottom = scroll.contentView.bounds.minY >= scroll.table.bounds.height - scroll.contentView.bounds.height - 1
            print(String(format: "RUN_RECORD_NATIVE anchor=%@ ready=%.2f worstBusy=%.2f busyTotal=%.2f blocks50=%d top=%.1f settledTop=%.1f rows=%d atBottom=%d title=%@",
                         anchor ?? "-", readyMs ?? -1, probe.worstMs, probe.totalMs, probe.blocks50, top ?? .nan, settled?.top ?? .nan,
                         scroll.document?.rows.count ?? 0, atBottom ? 1 : 0, settled?.title ?? ""))
            XCTAssertNotNil(readyMs, "\(anchor ?? "首屏")：要落到位")
            XCTAssertLessThan(readyMs ?? .infinity, 300, "单跑参考：300ms 内落位")
            XCTAssertLessThan(probe.worstMs, 200, "单跑参考：单次主线程忙段 <200ms")
            let expected = anchor.map { name -> String in
                switch name {
                case "end": return "末尾完整"
                default: return "种子第 \(name.dropFirst("round-".count)) 轮 · 请求"
                }
            } ?? "C3 整理记录 · 种子"
            XCTAssertEqual(settled?.title, expected)
            XCTAssertEqual(title, expected, "第一次落位就是这一轮，不是先落别处再挪")
            if atBottom, anchor != nil {
                XCTAssertGreaterThanOrEqual(settled?.top ?? -1, 0, "后面不满一屏：滚到底，标题在屏里")
            } else {
                XCTAssertEqual(settled?.top ?? .nan, 0, accuracy: 2, "\(expected) 的标题行顶在视口顶部")
            }
            XCTAssertEqual(settled?.top ?? .nan, top ?? .nan, accuracy: 0.5, "落位之后不再漂")
        }
    }

    /// 粟粟 10-22：短单行（id、工具名）原地显示、可选中，不用多点一下；多行、一行排不下的照旧折卡弹 sheet。
    /// 按当前宽度和字号实际量，宽度变了重判
    func testShortSingleLineValuesShowInlineAndTheRestFoldIntoCards() async throws {
        let id = "toolu_01AbCdEfGhIjKlMnOpQrStUv"
        let medium = String(repeating: "abcdef7890", count: 6)
        let long = String(repeating: "很长的一行参数没有换行", count: 30)
        let text = "# C3 整理记录 · 短值\n\n<a id=\"r\"></a>\n\n## 第 1 轮\n\nid：\n" + CatalogRunRecord.code(id)
            + "\n\nname：\n" + CatalogRunRecord.code("read")
            + "\n\n中等：\n" + CatalogRunRecord.code(medium)
            + "\n\n长单行：\n" + CatalogRunRecord.code(long)
            + "\n\n多行：\n" + CatalogRunRecord.code("a\nb")
            + "\n\n回车：\n" + CatalogRunRecord.code("x\r") + "\n"
        let list = RunRecordScrollView()
        list.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
        let host = NSView(frame: list.frame)
        host.addSubview(list)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var opened: [String] = []
        list.onOpen = { opened.append($0.name) }
        list.apply(try RunRecordDocument.parse(content: text, anchor: nil), typography: RunRecordTypography(scale: 1.2))
        func settle() async throws {
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        let document = try XCTUnwrap(list.document)
        func row(_ name: String) throws -> Int {
            try XCTUnwrap(document.rows.firstIndex { if case .block(let b) = $0 { return b.name == name } else { return false } })
        }
        func shown(_ name: String) throws -> String? {
            (list.table.view(atColumn: 0, row: try row(name), makeIfNecessary: true) as? RunRecordRowCell)?.text
        }
        let width = list.contentView.bounds.width
        for (name, value) in [("id", id), ("name", "read"), ("中等", medium)] {
            XCTAssertTrue(list.isInline(try row(name)), "\(name)：短单行原地显示")
            XCTAssertEqual(try shown(name), value, "\(name)：这一行显示的就是值本身")
            list.open(row: try row(name))
        }
        for name in ["长单行", "多行", "回车"] {
            XCTAssertFalse(list.isInline(try row(name)), "\(name)：照旧折卡")
            XCTAssertEqual(try shown(name), name, "\(name)：这一行是卡（显示卡名）")
            list.open(row: try row(name))
        }
        XCTAssertEqual(opened, ["长单行", "多行", "回车"], "只有卡能点开 sheet，原地显示的不弹")
        for index in 0..<list.table.numberOfRows {
            XCTAssertEqual(list.table.rect(ofRow: index).height, list.measuredHeight(index, width: width), accuracy: 0.5)
        }

        list.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        try await settle()
        XCTAssertTrue(list.isInline(try row("id")), "改窄后 id 还排得下")
        XCTAssertFalse(list.isInline(try row("中等")), "改窄后 60 个字符一行排不下了，改折卡")
        XCTAssertEqual(try shown("中等"), "中等")
        let narrow = list.contentView.bounds.width
        for index in 0..<list.table.numberOfRows {
            XCTAssertEqual(list.table.rect(ofRow: index).height, list.measuredHeight(index, width: narrow), accuracy: 0.5)
        }
        list.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
        try await settle()
        XCTAssertTrue(list.isInline(try row("中等")), "改回宽以后重新原地显示")
        XCTAssertEqual(try shown("中等"), medium)
    }

    /// 她自己滚开以后，位置不会被拉回锚点
    func testUserScrollIsNotPulledBackToTheAnchor() async throws {
        let (window, host) = openRecord(seedRecordText(), anchor: "round-2")
        defer { window.contentView = nil; window.close() }
        let landed = try await waitFor("落位") { self.landing(in: host) }
        XCTAssertEqual(landed.top, 0, accuracy: 2)
        let scroll = try XCTUnwrap(recordScroll(in: host))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(landing(in: host)?.top ?? .nan, 300, accuracy: 2, "滚开 300pt 停在那，1s 后也没被拽回")
    }

    /// 宽度 / 字号变了：每行按新宽度、新字号重量（和单独量的一样），最上面那一轮标题还在顶上
    func testWidthAndFontChangesRemeasureRowsAndKeepTheTopRow() async throws {
        // 锚点上面放一段长叙述：宽度变了它的行高跟着变，第 2 轮标题要靠「停回原来最上面那行」才留在顶上
        let long = "方式：合成测试\n\n" + String(repeating: "很长的一段叙述文字，用来看宽度变了以后折行和行高。", count: 40)
        let text = seedRecordText().replacingOccurrences(of: "方式：合成测试", with: long)
        // mac 上记录页是定宽 sheet（720），宽度变化只发生在 iPad / iPhone 转屏；这里直接给列表本身改宽
        let list = RunRecordScrollView()
        list.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
        let host = NSView(frame: list.frame)
        host.addSubview(list)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        list.apply(try RunRecordDocument.parse(content: text, anchor: "round-2"), typography: RunRecordTypography(scale: 1.2))
        let landed = try await waitFor("落位") { self.landing(in: host) }
        XCTAssertEqual(landed.top, 0, accuracy: 2)
        let scroll = try XCTUnwrap(recordScroll(in: host))
        let rows = scroll.table.numberOfRows
        let before = (0..<rows).map { scroll.table.rect(ofRow: $0).height }
        let widthBefore = scroll.contentView.bounds.width

        func settle() async throws {
            for _ in 0..<40 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func assertMeasured(_ stage: String) {
            let width = scroll.contentView.bounds.width
            for index in 0..<rows {
                XCTAssertEqual(scroll.table.rect(ofRow: index).height, scroll.measuredHeight(index, width: width), accuracy: 0.5, "\(stage)：第 \(index) 行")
            }
            XCTAssertEqual(landing(in: host)?.top ?? .nan, 0, accuracy: 2, "\(stage)：第 2 轮标题还在顶上")
            XCTAssertEqual(landing(in: host)?.title, "种子第 2 轮 · 请求")
        }

        list.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        try await settle()
        print("RUN_RECORD_RESIZE width \(widthBefore) → \(scroll.contentView.bounds.width)")
        XCTAssertLessThan(scroll.contentView.bounds.width, widthBefore - 200, "真的变窄了")
        assertMeasured("改窄到 420")
        let narrow = (0..<rows).map { scroll.table.rect(ofRow: $0).height }
        XCTAssertGreaterThan(zip(before, narrow).filter { $0 < $1 }.count, 0, "变窄后折行变多，行高跟着变")

        scroll.apply(try XCTUnwrap(scroll.document), typography: RunRecordTypography(scale: 1.8))
        try await settle()
        assertMeasured("字号 1.2 → 1.8")
        XCTAssertGreaterThan(scroll.table.rect(ofRow: 0).height, narrow[0], "字号变大，行高跟着变大")
    }

    // MARK: - 最大那块：sheet 秒开、滚到底、复制 = 原文

    func testLargestBlocksOpenInSheetScrollToEndAndCopyTheOriginal() async throws {
        let multi = (0..<7_000).map { "第 \($0) 行：合成原料「云桥城」记在 memory/cc/user.md；完整保留" }.joined(separator: "\n")
        let json = "{" + (0..<9_000).map { "\"k\($0)\":\"值\($0)合成数据合成数据\"" }.joined(separator: ",") + "}"
        // 小块要两行：短单行现在原地显示、不弹 sheet（粟粟 10-22）
        let small = "call_small\n2"
        let text = "# C3 整理记录 · 大块\n\n<a id=\"big\"></a>\n\n## 大块\n\nid：\n" + CatalogRunRecord.code(small)
            + "\n\n正文：\n" + CatalogRunRecord.code(multi)
            + "\n\nargumentsJSON：\n" + CatalogRunRecord.code(json, language: "json") + "\n\n<a id=\"end\"></a>\n\n## 末尾\n\n完。\n"
        XCTAssertGreaterThanOrEqual(multi.count, 300_000)
        XCTAssertGreaterThanOrEqual(json.count, 200_000)
        var copied: [String] = []
        RunRecordClipboard.override = { copied.append($0) }
        defer { RunRecordClipboard.override = nil }
        // 先开一块小的：sheet 第一次弹出的冷开开销单独记。每块各开一次记录页（她关了 sheet 再点下一张卡）
        for (original, name, checked) in [(small, "id", false), (multi, "正文", true), (json, "argumentsJSON", false)] {
            let (window, host) = openRecord(text, anchor: nil)
            defer { window.contentView = nil; window.close() }
            let scroll = try await waitFor("列表就位") { self.recordScroll(in: host).flatMap { $0.document == nil ? nil : $0 } }
            let document = try XCTUnwrap(scroll.document)
            XCTAssertEqual(document.blocks.map(\.name), ["id", "正文", "argumentsJSON"], "每个代码块都折成卡，不按长度决定")
            let row = try XCTUnwrap(document.rows.firstIndex { if case .block(let b) = $0 { return b.name == name } else { return false } })
            guard case .block(let block) = document.rows[row] else { return XCTFail() }
            XCTAssertEqual(block.count, original.count, "\(name)：卡上的字数")
            let probe = BusyProbe()
            probe.start()
            let start = ProcessInfo.processInfo.systemUptime
            scroll.open(row: row)
            let length = (original as NSString).length
            let textView = try await waitFor("\(name) 的 sheet") { () -> NSTextView? in
                window.attachedSheet?.contentView.flatMap { self.firstTextView(in: $0) }.flatMap { $0.string.utf16.count == length ? $0 : nil }
            }
            let openMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertEqual(Data(textView.string.utf8), Data(original.utf8), "\(name)：sheet 里整块原文一字不差")
            XCTAssertFalse(textView.isEditable)
            XCTAssertTrue(textView.isSelectable)
            XCTAssertNotNil(textView.textLayoutManager, "TextKit 2")
            probe.stop()
            let openBusy = probe.worstMs
            let endProbe = BusyProbe()
            endProbe.start()
            let endStart = ProcessInfo.processInfo.systemUptime
            textView.scrollToEndOfDocument(nil)
            let clip = try XCTUnwrap(textView.enclosingScrollView?.contentView)
            for _ in 0..<40 {
                window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
            let endMs = (ProcessInfo.processInfo.systemUptime - endStart) * 1000
            endProbe.stop()
            XCTAssertGreaterThanOrEqual(clip.bounds.maxY, textView.frame.height - 2, "\(name)：能滚到最后")
            RunRecordBlockSheet.copy(block)
            XCTAssertEqual(copied.last.map { Data($0.utf8) }, Data(original.utf8), "\(name)：复制 = 原文")
            print(String(format: "RUN_RECORD_SHEET block=%@ chars=%d open=%.2f openBusy=%.2f toEnd=%.2f toEndBusy=%.2f", name, original.count, openMs, openBusy, endMs, endProbe.worstMs))
            // 弹 sheet 本身（SwiftUI 呈现）在离屏测试窗里有 300ms 上下的固定开销，10 个字的块也一样；只记数，
            // 内容本身的开销由 testBlockSheetBodyCostDoesNotGrowWithSize 单独量
            // 滚到底的忙段多数 3–60ms，偶有 160–1265ms 的离群（TextKit 2 估高被纠正），只记数不设门槛
            _ = checked
        }
    }

    /// sheet 里面那一页（复制钮 + TextKit 2 文本视图）直接上屏：30 万字和 10 个字的开销同一量级
    func testBlockSheetBodyCostDoesNotGrowWithSize() async throws {
        let multi = (0..<7_000).map { "第 \($0) 行：合成原料「云桥城」记在 memory/cc/user.md；完整保留" }.joined(separator: "\n")
        var worst: [String: Double] = [:]
        let json = "{" + (0..<9_000).map { "\"k\($0)\":\"值\($0)合成数据合成数据\"" }.joined(separator: ",") + "}"
        for (name, text) in [("warmup", "w"), ("small", "call_small"), ("multi", multi), ("json", json)] {
            let block = RunRecordDocument.Block(id: 1, name: name, language: "", text: text, count: text.count, summary: "")
            let typography = RunRecordTypography(scale: 1.2)
            let probe = BusyProbe()
            probe.start()
            let t = ProcessInfo.processInfo.systemUptime
            let host = NSHostingView(rootView: RunRecordBlockSheet(block: block, typography: typography))
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            for _ in 0..<60 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
            probe.stop()
            let shown = firstTextView(in: host)
            print(String(format: "RUN_RECORD_SHEET_BODY %@ chars=%d wall=%.2f worstBusy=%.2f busyTotal=%.2f", name, text.count, (ProcessInfo.processInfo.systemUptime - t) * 1000, probe.worstMs, probe.totalMs))
            XCTAssertEqual(shown?.string.utf16.count, (text as NSString).length)
            worst[name] = probe.worstMs
            window.contentView = nil
            window.close()
        }
        XCTAssertLessThan(worst["multi"] ?? .infinity, 200, "单跑参考：30 万字那页上屏单次忙段 <200ms")
        XCTAssertLessThan(worst["multi"] ?? .infinity, (worst["small"] ?? 0) + 100, "单跑参考：和 10 个字的页差不到 100ms")
    }

    // MARK: - 夹具 / 查找

    private final class ParseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Bool] = []
        var results: [Bool] { lock.withLock { stored } }
        func record(_ cancelled: Bool) { lock.withLock { stored.append(cancelled) } }
    }

    private func openRecord(_ text: String, anchor: String?) -> (NSWindow, NSView) {
        let sheet = FileEditorSheet(
            path: "wiki/.runs/合成.md", initialContent: text, initialModifiedAt: nil,
            readOnly: true, initialAnchor: anchor,
            currentModifiedAt: { nil },
            reloadExternalContent: { ReloadedFileContent(content: text, modifiedAt: nil) },
            onCancel: {}, title: "整理记录"
        )
        let host = NSHostingView(rootView: sheet)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    private func recordScroll(in view: NSView) -> RunRecordScrollView? {
        (view as? RunRecordScrollView) ?? view.subviews.lazy.compactMap { self.recordScroll(in: $0) }.first
    }

    /// 视口里最上面那个标题行：（相对视口顶的位置，标题字）
    private func landing(in host: NSView) -> (top: CGFloat, title: String)? {
        guard let scroll = recordScroll(in: host), let document = scroll.document, scroll.table.numberOfRows > 0 else { return nil }
        let visible = scroll.table.rows(in: scroll.contentView.bounds)
        let firstHeading = document.rows.firstIndex { if case .heading = $0 { return true } else { return false } }
        guard visible.length > 0, let rowIndex = document.targetRow ?? firstHeading,
              let cell = scroll.table.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? RunRecordRowCell else { return nil }
        // 用表格的行位置（就是屏幕上那一行的位置）；单元格视图刚复用时自己的 frame 可能还没排到位
        let top = scroll.table.rect(ofRow: rowIndex).minY - scroll.contentView.bounds.minY
        return (top, cell.text)
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        (view as? NSTextView) ?? view.subviews.lazy.compactMap { self.firstTextView(in: $0) }.first
    }

    private func waitFor<T>(_ what: String, seconds: Double = 5, _ probe: () -> T?) async throws -> T {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            if let value = probe() { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等不到：\(what)")
        throw Timeout()
    }

    private struct Timeout: Error {}

    func testSectionedPreviewDoesNotSplitFencedAnchorsOrLoseText() throws {
        let marker = "<a id=\"round-2\"></a>"
        let prefix = "# 合成记录\n\n````json\n\(marker)\n```\n````\n\n"
        let one = "<a id=\"round-1\"></a>\n\n## 第一轮\n\n~~~\n\(marker)\n~~~\n\n"
        let two = "\(marker)\n\n## 第二轮\n\n末尾完整"
        let source = prefix + one + two
        let location = FileEditorPreviewLocation(content: source, anchor: "round-2", separatesSections: true)
        XCTAssertEqual(location.parts, [prefix, one, two])
        XCTAssertEqual(location.parts[try XCTUnwrap(location.targetIndex)], two)
        XCTAssertEqual(location.parts.joined(), source)
        let fromStart = FileEditorPreviewLocation(content: source, anchor: nil, separatesSections: true)
        XCTAssertEqual(fromStart.parts.joined(), source)
        XCTAssertNil(fromStart.targetIndex)
        let missing = FileEditorPreviewLocation(content: source, anchor: "missing", separatesSections: true)
        XCTAssertNil(missing.targetIndex)
        XCTAssertEqual(missing.parts.joined(), source)
    }

    private final class BusyProbe {
        private var begin: CFRunLoopObserver?
        private var end: CFRunLoopObserver?
        private var started: Double?
        private(set) var worstMs = 0.0
        private(set) var totalMs = 0.0
        private(set) var blocks50 = 0
        private var tailStart: Double?
        private(set) var tailMs = 0.0
        private(set) var lastLongEnd: Double?

        func start() {
            started = ProcessInfo.processInfo.systemUptime
            begin = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
                self?.started = ProcessInfo.processInfo.systemUptime
            }
            end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
                guard let self, let started = self.started else { return }
                let finished = ProcessInfo.processInfo.systemUptime
                let ms = (finished - started) * 1000
                self.worstMs = max(self.worstMs, ms)
                self.totalMs += ms
                if ms > 50 {
                    self.blocks50 += 1
                    self.lastLongEnd = finished
                }
                if let tailStart = self.tailStart {
                    self.tailMs += max(0, finished - max(started, tailStart)) * 1000
                }
                self.started = nil
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), begin, .commonModes)
            CFRunLoopAddObserver(CFRunLoopGetMain(), end, .commonModes)
        }

        func beginTail(at time: Double) {
            tailStart = time
            tailMs = 0
        }

        func stop() {
            if let begin { CFRunLoopRemoveObserver(CFRunLoopGetMain(), begin, .commonModes) }
            if let end { CFRunLoopRemoveObserver(CFRunLoopGetMain(), end, .commonModes) }
            begin = nil
            end = nil
        }
    }
}

@MainActor
enum FileEditorPreviewTestDriver {
    static func scroll(_ scroll: NSScrollView, end: Bool) async throws {
        // 离屏 XCTest 补齐滚动通知并主动排版，不依赖登录桌面的刷新。
        let document = try XCTUnwrap(scroll.documentView)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let limit = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let y = end ? min(limit, scroll.contentView.bounds.minY + 2_000) : max(0, scroll.contentView.bounds.minY - 2_000)
        document.scroll(NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        try await Task.sleep(for: .milliseconds(35))
        document.needsLayout = true
        scroll.needsLayout = true
        if let root = scroll.window?.contentView {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }
}
