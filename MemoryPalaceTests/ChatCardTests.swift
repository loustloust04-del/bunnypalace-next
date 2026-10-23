import XCTest
@testable import 记忆花园

/// 聊天卡片第 1 期（docs/plan-chat-cards.md）
final class ChatCardTests: XCTestCase {

    func todo(_ id: String, _ done: Bool = false) -> ChatCard {
        .todo(TodoCard(id: id, title: "T", items: [.init(text: "a", done: done)]))
    }

    // MARK: - 解析

    func testParseTodo() {
        let code = #"{"id":"t-1","title":"周末","items":[{"text":"买牛奶","done":true},{"text":"洗衣服","done":false}]}"#
        guard case .todo(let t)? = ChatCard.parse(language: "card-todo", code: code) else { return XCTFail() }
        XCTAssertEqual(t.id, "t-1")
        XCTAssertEqual(t.items.map(\.done), [true, false])
    }

    func testParseIsLenient() {
        guard case .todo(let t)? = ChatCard.parse(language: "CARD-TODO", code: #"{"id":"","items":[{"text":"a"}]}"#) else { return XCTFail() }
        XCTAssertNil(ChatCard.todo(t).id)          // 空字符串 id 与缺 id 同义
        XCTAssertEqual(t.title, "")
        XCTAssertEqual(t.items, [TodoCard.Item(text: "a", done: false)])
    }

    func testParseRejectsBadInput() {
        XCTAssertNil(ChatCard.parse(language: "card-todo", code: #"{"id":"t-1","items":[{"te"#))
        XCTAssertNil(ChatCard.parse(language: "card-nope", code: "{}"))
        XCTAssertNil(ChatCard.parse(language: "python", code: "{}"))
    }

    // MARK: - 块文字 / 抽卡

    func testBlockTextRoundTrips() {
        let card = todo("t-1")
        XCTAssertTrue(card.blockText.hasPrefix("```card-todo\n"))
        XCTAssertTrue(card.blockText.hasSuffix("\n```"))
        XCTAssertEqual(ChatCardExtractor.cards(in: "前文\n\n" + card.blockText + "\n\n后文"), [card])
    }

    func testBlockTextUsesLongerFenceWhenContentHasBackticks() {
        let card = ChatCard.todo(TodoCard(id: "t-2", title: "代码", items: [.init(text: "写 ``` 围栏", done: false)]))
        XCTAssertTrue(card.blockText.hasPrefix("````card-todo\n"))
        XCTAssertEqual(ChatCardExtractor.cards(in: card.blockText), [card])
    }

    func testExtractorIsCaseInsensitiveAndSkipsBadOrForeignBlocks() {
        let upper = "```CARD-TODO\n{\"id\":\"u\",\"title\":\"\",\"items\":[]}\n```"
        let text = "```python\nx\n```\n\n```card-todo\n{坏的\n```\n\n" + upper + "\n\n```card-todo x`y\n{}\n```"
        XCTAssertEqual(ChatCardExtractor.cards(in: text).map(\.id), ["u"])
    }

    func testNewIdFormat() {
        let id = ChatCard.newId(prefix: "t")
        XCTAssertNotNil(id.range(of: #"^t-[0-9a-f]{4}$"#, options: .regularExpression), id)
    }

    func testMakeTodoFromLines() {
        let card = TodoCard.make(title: " 周末 ", lines: ["买牛奶", "  ", " 洗衣服"])
        XCTAssertEqual(card?.title, "周末")
        XCTAssertEqual(card?.items, [.init(text: "买牛奶", done: false), .init(text: "洗衣服", done: false)])
        XCTAssertTrue(card?.id?.hasPrefix("t-") ?? false)
        XCTAssertNil(TodoCard.make(title: "空", lines: ["", " "]))
    }

    /// 卡片块经过分气泡 / 气泡简化不被拆、不被改字节
    func testBlockTextSurvivesBubblePipeline() {
        let card = ChatCard.todo(TodoCard(id: "t-3", title: "# 不是标题", items: [.init(text: "``` 内含围栏", done: false)]))
        let message = "说明\n\n" + card.blockText + "\n\n结尾"
        let blocks = BubbleModeRow.splitBlocks(message)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(ChatCardExtractor.cards(in: BubbleMarkdownSimplifier.simplify(blocks[1])), [card])
    }

    // MARK: - 注册表

    func testRegistryKinds() {
        let good = #"{"id":"t","title":"","items":[]}"#
        XCTAssertEqual(ChatCardRegistry.kind(language: "html", code: "<p>", streaming: false), .html)
        XCTAssertEqual(ChatCardRegistry.kind(language: "card-todo", code: good, streaming: false),
                       .card(.todo(TodoCard(id: "t", title: "", items: []))))
        XCTAssertNil(ChatCardRegistry.kind(language: "python", code: "x", streaming: true))
        XCTAssertEqual(ChatCardRegistry.kind(language: "card-todo", code: #"{"id":"t","ite"#, streaming: true), .placeholder)
        XCTAssertNil(ChatCardRegistry.kind(language: "card-todo", code: #"{"id":"t","ite"#, streaming: false))
        XCTAssertEqual(ChatCardRegistry.kind(language: "card-nope", code: "{}", streaming: true), .placeholder)
        XCTAssertNil(ChatCardRegistry.kind(language: "card-nope", code: "{}", streaming: false))
    }

    /// 气泡模式用户消息：整块就是一张卡才画卡
    func testStandaloneCardBlock() {
        let block = todo("a").blockText
        XCTAssertEqual(ChatCardRegistry.standaloneCardBlock("  " + block + "\n")?.language, "card-todo")
        XCTAssertNil(ChatCardRegistry.standaloneCardBlock("文字\n" + block))
        XCTAssertNil(ChatCardRegistry.standaloneCardBlock("```python\nx\n```"))
        XCTAssertNil(ChatCardRegistry.standaloneCardBlock("普通文字"))
    }

    // MARK: - 待发卡片

    func testStagingReplacesSameIdKeepsOthers() throws {
        let image = try PendingChatAttachment.image(name: "p", typeDescription: "PNG", mimeType: "image/png", data: Data([1]))
        var list = ConversationViewModel.staging(todo("a"), into: [image])
        let firstAttachmentId = list[1].id
        list = ConversationViewModel.staging(todo("a", true), into: list)
        list = ConversationViewModel.staging(todo("b"), into: list)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[1].id, firstAttachmentId)
        XCTAssertEqual(list[1].chatCard, todo("a", true))
        XCTAssertEqual(list[2].chatCard, todo("b"))
    }

    func testAppendingCards() {
        let file = PendingChatAttachment.text(name: "f.txt", typeDescription: "文本", extractedText: "x", byteCount: 1)
        let atts: [PendingChatAttachment] = [.card(todo("a")), file, .card(todo("b"))]
        XCTAssertEqual(ChatAttachmentPromptBuilder.appendingCards(to: "看看", from: atts),
                       "看看\n\n" + todo("a").blockText + "\n\n" + todo("b").blockText)
        XCTAssertEqual(ChatAttachmentPromptBuilder.appendingCards(to: "", from: [.card(todo("a"))]), todo("a").blockText)
        XCTAssertEqual(ChatAttachmentPromptBuilder.appendingCards(to: "hi", from: [file]), "hi")
    }

    /// 预算预检用的 modelInput 与实发一致：卡片是正文，不包 [附件] 壳
    func testModelInputTreatsCardAsBody() {
        let text = ChatAttachmentPromptBuilder.modelInput(text: "看看", attachments: [.card(todo("a"))])
        XCTAssertEqual(text, "看看\n\n" + todo("a").blockText)
    }

    /// 卡片内容不参与宏展开：先展开正文，再拼卡片
    func testCardJSONUntouchedByMacros() {
        let card = ChatCard.todo(TodoCard(id: "m", title: "", items: [.init(text: "给 {{user}} 买礼物", done: false)]))
        let expanded = "你好 粟\"粟"   // 模拟 expandUserMacros("你好 {{user}}")，名字带引号
        let body = ChatAttachmentPromptBuilder.appendingCards(to: expanded, from: [.card(card)])
        XCTAssertEqual(ChatCardExtractor.cards(in: body), [card])
    }

    func testCardAttachmentDraftCoding() throws {
        // 旧格式草稿（无 .card）照常解码
        let legacy = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"f","kind":"text","typeDescription":"文本","extractedText":"x","byteCount":1}]"#
        let old = try JSONDecoder().decode([PendingChatAttachment].self, from: Data(legacy.utf8))
        XCTAssertEqual(old.first?.kind, .text)
        let data = try JSONEncoder().encode(old + [PendingChatAttachment.card(todo("a"))])
        let back = try JSONDecoder().decode([PendingChatAttachment].self, from: data)
        XCTAssertEqual(back.last?.chatCard, todo("a"))
        XCTAssertFalse(back[1].isImage)
        XCTAssertFalse(back[1].isFile)
    }

    // MARK: - 版本判定

    func testIndexUsesLastMessageThenLastOccurrenceInIt() {
        let a1 = todo("a"), a2 = todo("a", true)
        let index = ChatCardIndex.build([
            (id: "n1", text: a1.blockText),
            (id: "n2", text: a2.blockText + "\n\n" + todo("b").blockText),
            (id: "n3", text: a1.blockText),                        // A→B→A：内容回到 a1
        ])
        XCTAssertEqual(ChatCardIndex.status(of: a1, nodeId: "n1", index: index), .stale)   // 同内容但更早的消息
        XCTAssertEqual(ChatCardIndex.status(of: a2, nodeId: "n2", index: index), .stale)
        XCTAssertEqual(ChatCardIndex.status(of: a1, nodeId: "n3", index: index), .live)
        XCTAssertEqual(ChatCardIndex.status(of: todo("b"), nodeId: "n2", index: index), .live)
    }

    func testSameMessageEarlierVersionIsStale() {
        let index = ChatCardIndex.build([(id: "n1", text: todo("a").blockText + "\n\n" + todo("a", true).blockText)])
        XCTAssertEqual(ChatCardIndex.status(of: todo("a"), nodeId: "n1", index: index), .stale)
        XCTAssertEqual(ChatCardIndex.status(of: todo("a", true), nodeId: "n1", index: index), .live)
    }

    func testReadOnlyCases() {
        let noId = ChatCard.todo(TodoCard(id: nil, title: "", items: []))
        XCTAssertEqual(ChatCardIndex.status(of: noId, nodeId: "n1", index: [:]), .readOnly)
        XCTAssertEqual(ChatCardIndex.status(of: todo("a"), nodeId: nil, index: [:]), .readOnly)   // 流式尾巴 / 文件预览
        XCTAssertEqual(ChatCardIndex.status(of: todo("z"), nodeId: "n9", index: [:]), .live)
    }

    /// 分段消息：卡片在工具调用前的 .text 段，最终 content 不含它
    func testVisibleTextIncludesTextSegments() {
        let segs: [MessageSegment] = [.text("先给你\n\n" + todo("a", true).blockText), .text("好了")]
        let text = ChatCardIndex.visibleText(content: "好了", segments: segs)
        XCTAssertEqual(ChatCardExtractor.cards(in: text), [todo("a", true)])
        XCTAssertEqual(ChatCardIndex.visibleText(content: "纯文本", segments: nil), "纯文本")
    }

    // MARK: - 提示词

    private func assemble(history: [(role: String, content: String)], cacheFriendly: Bool) -> [TaggedSegment] {
        let profile = Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚",
                              systemPrompt: "系统指令", characterDescription: "")
        var preset = Preset(name: "t")
        preset.prompts = [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, isMarker: false, injectionOrder: 0),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60),
        ]
        preset.sampling.cacheFriendly = cacheFriendly
        return PromptAssembler.assembleTagged(preset: preset, profile: profile, memories: [],
                                              chatHistory: history, worldBooks: [], globalEntries: []).segments
    }

    func testCardGuideOnceBeforeHistoryAndNothingElseChanges() {
        let history: [(role: String, content: String)] = [("user", "你好"), ("assistant", "嗨")]
        for cacheFriendly in [false, true] {
            let segments = assemble(history: history, cacheFriendly: cacheFriendly)
            let guides = segments.indices.filter { segments[$0].source == .cardGuide }
            XCTAssertEqual(guides.count, 1)
            let firstHistory = segments.firstIndex { $0.source == .chatHistory }
            XCTAssertNotNil(firstHistory)
            XCTAssertLessThan(guides[0], firstHistory!)
            XCTAssertEqual(segments[guides[0]].role, "system")
            XCTAssertTrue(segments[guides[0]].content.contains("card-todo"))
            // 去掉新段后，其余段与不注入时逐字一致
            ChatCardPromptGuide.isEnabledForTesting = false
            let baseline = assemble(history: history, cacheFriendly: cacheFriendly)
            ChatCardPromptGuide.isEnabledForTesting = true
            XCTAssertEqual(segments.filter { $0.source != .cardGuide }.map(\.content), baseline.map(\.content))
            XCTAssertEqual(segments.filter { $0.source != .cardGuide }.map(\.role), baseline.map(\.role))
        }
    }

    // MARK: - 终审修复

    /// #1 索引缓存：节点键不变就不重读正文、不重建
    func testIndexCacheReusesUntilANodeKeyChanges() {
        var cache = ChatCardIndexCache()
        var reads = 0
        let a = todo("a").blockText, a2 = todo("a", true).blockText
        func nodes(_ k2: Int) -> [ChatCardIndexCache.Node] {
            [.init(id: "n1", key: 1, text: { reads += 1; return a }),
             .init(id: "n2", key: k2, text: { reads += 1; return a2 })]
        }
        XCTAssertEqual(cache.index(nodes(1))["a"]?.nodeId, "n2")
        XCTAssertEqual(reads, 2)
        _ = cache.index(nodes(1))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(cache.builds, 1)
        _ = cache.index(nodes(2))
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(cache.builds, 2)
    }

    /// #2 提示词示例不给具体 id；新 id 避开已有的
    func testPromptGuideUsesPlaceholderId() {
        XCTAssertFalse(ChatCardPromptGuide.text.contains("t-3f2a"))
        XCTAssertTrue(ChatCardPromptGuide.text.contains("没出现过"))
    }

    func testNewIdAvoidsTakenIds() {
        let all = Set((0...0xFFFF).map { "t-" + String(format: "%04x", $0) })
        let id = ChatCard.newId(prefix: "t", avoiding: all)
        XCTAssertFalse(all.contains(id))
        XCTAssertTrue(id.hasPrefix("t-"))
        let made = TodoCard.make(title: "", lines: ["x"], avoiding: all)
        XCTAssertFalse(all.contains(made?.id ?? "t-0000"))
    }

    /// #4 取消排队：同 id 以输入框里更新的那份为准，不出现两张
    func testRestoringQueuedCardsMergesById() {
        let current = ConversationViewModel.staging(todo("a", true), into: [])
        let file = PendingChatAttachment.text(name: "f", typeDescription: "文本", extractedText: "x", byteCount: 1)
        let restored = ConversationViewModel.restoring([.card(todo("a")), .card(todo("b")), file], into: current)
        XCTAssertEqual(restored.compactMap(\.chatCard), [todo("a", true), todo("b")])
        XCTAssertEqual(restored.count, 3)
    }

    /// #4 待发查找：输入框优先，其次排队里最后一份
    func testPendingLookupFallsBackToQueuedSends() {
        XCTAssertEqual(ConversationViewModel.pendingCard(id: "a", staged: [], queued: [[.card(todo("a"))], [.card(todo("a", true))]]),
                       todo("a", true))
        XCTAssertEqual(ConversationViewModel.pendingCard(id: "a", staged: [.card(todo("a"))], queued: [[.card(todo("a", true))]]),
                       todo("a"))
        XCTAssertNil(ConversationViewModel.pendingCard(id: "z", staged: [], queued: []))
    }

    /// #5 待发改动只叠在它的底稿那张上；底稿不明（新建 / 取消排队恢复）时照旧叠
    func testPendingOverlayOnlyOnItsBase() {
        XCTAssertTrue(ChatCardIndex.showsPending(baseNodeId: "n1", nodeId: "n1"))
        XCTAssertFalse(ChatCardIndex.showsPending(baseNodeId: "n1", nodeId: "n3"))
        XCTAssertTrue(ChatCardIndex.showsPending(baseNodeId: nil, nodeId: "n3"))
    }

    // MARK: - 外链元数据（第 2 期）

    @MainActor
    final class FakeFetcher: LinkMetadataFetching {
        var calls: [URL] = []
        var inFlight = 0
        var peak = 0
        var result: LinkPreviewFetchResult?
        var holds = false
        var gates: [CheckedContinuation<Void, Never>] = []

        func fetch(_ url: URL) async -> LinkPreviewFetchResult? {
            calls.append(url)
            inFlight += 1
            peak = max(peak, inFlight)
            if holds { await withCheckedContinuation { gates.append($0) } } else { await Task.yield() }
            inFlight -= 1
            return result
        }

        func releaseAll() {
            let pending = gates
            gates = []
            pending.forEach { $0.resume() }
        }
    }

    @MainActor
    private func makeStore(_ fetcher: FakeFetcher, dir: URL? = nil, offline: @escaping () -> Bool = { false },
                           now: @escaping () -> Date = Date.init) -> LinkPreviewStore {
        let directory = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("lp-\(UUID().uuidString)")
        return LinkPreviewStore(directory: directory, fetcher: fetcher, isOffline: offline, now: now, maxConcurrent: 3)
    }

    @MainActor
    func testLinkPreviewFetchesOnceAndPersists() async {
        let fetcher = FakeFetcher()
        fetcher.result = LinkPreviewFetchResult(title: "标题", imageData: Data([1, 2]), iconData: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lp-\(UUID().uuidString)")
        let store = makeStore(fetcher, dir: dir)
        let url = URL(string: "https://example.com/a")!
        async let a = store.preview(for: url)
        async let b = store.preview(for: url)
        let (p1, p2) = await (a, b)
        XCTAssertEqual(fetcher.calls.count, 1)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(p1.title, "标题")
        XCTAssertEqual(p1.host, "example.com")
        XCTAssertNotNil(p1.imageFile)
        let reopened = makeStore(FakeFetcher(), dir: dir)             // 模拟重启
        XCTAssertEqual(reopened.cached(url), p1)
    }

    @MainActor
    func testLinkPreviewFailureCachedForOneDay() async {
        let fetcher = FakeFetcher()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(fetcher, now: { clock })
        let url = URL(string: "https://dead.example/x")!
        let first = await store.preview(for: url)
        XCTAssertTrue(first.failed)
        _ = await store.preview(for: url)
        XCTAssertEqual(fetcher.calls.count, 1)
        clock = clock.addingTimeInterval(86_400 + 1)
        _ = await store.preview(for: url)
        XCTAssertEqual(fetcher.calls.count, 2)
    }

    @MainActor
    func testLinkPreviewConcurrencyCap() async {
        let fetcher = FakeFetcher()
        fetcher.holds = true
        let store = makeStore(fetcher)
        let tasks = (0..<10).map { i in Task { await store.preview(for: URL(string: "https://s\(i).example.com")!) } }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(fetcher.peak, 3)
        XCTAssertEqual(fetcher.calls.count, 3)
        fetcher.holds = false
        while fetcher.calls.count < 10 || !fetcher.gates.isEmpty {
            fetcher.releaseAll()
            await Task.yield()
        }
        for t in tasks { _ = await t.value }
        XCTAssertEqual(fetcher.peak, 3)
    }

    @MainActor
    func testLinkPreviewOfflineAndPrivateTargets() async {
        let fetcher = FakeFetcher()
        fetcher.result = LinkPreviewFetchResult(title: "T", imageData: nil, iconData: nil)
        var offline = false
        let store = makeStore(fetcher, offline: { offline })
        let url = URL(string: "https://example.com/p")!
        _ = await store.preview(for: url)
        offline = true
        let cachedWhileOffline = await store.preview(for: url)
        XCTAssertEqual(cachedWhileOffline.title, "T")                 // 本地模式：有缓存显示缓存
        let fresh = await store.preview(for: URL(string: "https://new.example.com")!)
        XCTAssertNil(fresh.title)                                     // 没缓存：简版
        XCTAssertEqual(fetcher.calls.count, 1)                        // 本地模式零请求
        offline = false
        for raw in ["http://localhost:8080/x", "http://192.168.1.2/", "http://10.0.0.1", "http://127.0.0.1",
                    "https://printer.local/", "https://user:pw@example.com/", "http://[::1]/"] {
            XCTAssertFalse(LinkPreviewStore.isPublicTarget(URL(string: raw)!), raw)
            _ = await store.preview(for: URL(string: raw)!)
        }
        XCTAssertEqual(fetcher.calls.count, 1)
        XCTAssertTrue(LinkPreviewStore.isPublicTarget(URL(string: "https://example.com")!))
    }

    @MainActor
    func testLateResultDroppedAfterSwitchingToOffline() async {
        let fetcher = FakeFetcher()
        fetcher.holds = true
        fetcher.result = LinkPreviewFetchResult(title: "迟到", imageData: nil, iconData: nil)
        var offline = false
        let store = makeStore(fetcher, offline: { offline })
        let url = URL(string: "https://slow.example.com")!
        let task = Task { await store.preview(for: url) }
        for _ in 0..<20 { await Task.yield() }
        offline = true
        fetcher.releaseAll()
        let p = await task.value
        XCTAssertNil(p.title)
        XCTAssertNil(store.cached(url))
    }

    // MARK: - 外链卡接入

    func testLinkViewOnlyWhenFinalizedAndHTTP() {
        XCTAssertNotNil(ChatCardRegistry.linkView(url: URL(string: "https://a.com")!, label: nil, streaming: false))
        XCTAssertNil(ChatCardRegistry.linkView(url: URL(string: "https://a.com")!, label: nil, streaming: true))
        XCTAssertNil(ChatCardRegistry.linkView(url: URL(string: "file:///etc/hosts")!, label: nil, streaming: false))
    }

    /// 正文里伪造的 mp-link 代码块不会变成外链卡（口子是分开的）
    func testFencedFakeLinkStaysCode() {
        XCTAssertNil(ChatCardRegistry.kind(language: "mp-link", code: "https://a.com", streaming: false))
    }

    // MARK: - 网页卡

    func testHTMLPageTitle() {
        XCTAssertEqual(HTMLCardView.pageTitle("<html><head><title> 小游戏 &amp; 计分 </title></head></html>"), "小游戏 & 计分")
        XCTAssertEqual(HTMLCardView.pageTitle("<TITLE>大写</TITLE>"), "大写")
        XCTAssertNil(HTMLCardView.pageTitle("<p>没有标题</p>"))
        XCTAssertNil(HTMLCardView.pageTitle("<title>  </title>"))
    }

    @MainActor
    func testSnapshotKeyAndPolicy() {
        let a = ChatHTMLSnapshotter.cacheKey(html: "<p>a</p>", offline: true)
        XCTAssertEqual(a, ChatHTMLSnapshotter.cacheKey(html: "<p>a</p>", offline: true))
        XCTAssertNotEqual(a, ChatHTMLSnapshotter.cacheKey(html: "<p>b</p>", offline: true))
        XCTAssertNotEqual(a, ChatHTMLSnapshotter.cacheKey(html: "<p>a</p>", offline: false))
        let offline = ChatHTMLSnapshotter.contentSecurityPolicy(offline: true)
        XCTAssertTrue(offline.contains("script-src 'unsafe-inline';"))
        XCTAssertFalse(offline.contains("https:"))
        XCTAssertTrue(offline.contains("connect-src 'none'"))
        XCTAssertTrue(ChatHTMLSnapshotter.contentSecurityPolicy(offline: false).contains("script-src 'unsafe-inline' https:"))
    }

    @MainActor
    func testSnapshotRefusesOversizedHTML() {
        var result: ChatHTMLSnapshotter.Result?
        ChatHTMLSnapshotter.shared.snapshot(html: String(repeating: "a", count: ChatHTMLSnapshotter.maxHTMLBytes + 1)) { result = $0 }
        XCTAssertEqual(result, .failed)
    }

    func testRegistryHTMLStreamingPlaceholder() {
        XCTAssertEqual(ChatCardRegistry.kind(language: "html", code: "<div>", streaming: true), .htmlPlaceholder)
        XCTAssertEqual(ChatCardRegistry.kind(language: "html", code: "<div>", streaming: false), .html)
    }

    func testHTMLBlocksBubbleLikeCards() {
        let html = "```html\n" + String(repeating: "<p>x</p>\n", count: 80) + "```"
        XCTAssertEqual(ChatCardRegistry.standaloneCardBlock(html)?.language, "html")
    }

    // MARK: - 第 2 期终审修复

    /// I3：没有 <head> 但有 <header> 的片段，CSP 必须进真正的 head（否则整页无策略）
    @MainActor
    func testCSPInjectionIgnoresHeaderTag() {
        let out = ChatHTMLSnapshotter.injectingCSP(into: "<header>标题</header><img src=\"https://x.com/a.png\">", offline: true)
        XCTAssertTrue(out.hasPrefix("<head><meta http-equiv=\"Content-Security-Policy\""), out)
        let withHead = ChatHTMLSnapshotter.injectingCSP(into: "<html><head lang=\"zh\"><title>t</title></head><body><header>h</header>", offline: true)
        XCTAssertTrue(withHead.contains("<head lang=\"zh\"><meta http-equiv="), withHead)
        XCTAssertFalse(withHead.contains("<header><meta"), withHead)
    }

    /// I4：不会抓取的情况（本地模式 / 私网）同步给简版，有缓存给缓存，否则 nil（才显示骨架）
    @MainActor
    func testImmediatePreview() async {
        let fetcher = FakeFetcher()
        fetcher.result = LinkPreviewFetchResult(title: "T", imageData: nil, iconData: nil)
        var offline = true
        let store = makeStore(fetcher, offline: { offline })
        let url = URL(string: "https://example.com/q")!
        XCTAssertNil(store.immediate(url)?.title)
        XCTAssertNotNil(store.immediate(url))                                   // 本地模式无缓存：简版
        offline = false
        XCTAssertNil(store.immediate(url))                                      // 在线无缓存：要抓
        XCTAssertNotNil(store.immediate(URL(string: "http://192.168.1.1")!))    // 私网：简版
        _ = await store.preview(for: url)
        XCTAssertEqual(store.immediate(url)?.title, "T")                        // 有缓存
    }

    // MARK: - 骰子 / 计时器（第 3 期）

    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testDiceExpressionParse() {
        XCTAssertEqual(DiceExpression.parse("2d6+1"), DiceExpression(count: 2, sides: 6, modifier: 1))
        XCTAssertEqual(DiceExpression.parse(" D20 "), DiceExpression(count: 1, sides: 20, modifier: 0))
        XCTAssertEqual(DiceExpression.parse("3d8 - 2"), DiceExpression(count: 3, sides: 8, modifier: -2))
        XCTAssertEqual(DiceExpression.parse("1d6+1000"), DiceExpression(count: 1, sides: 6, modifier: 1000))
        for bad in ["0d6", "21d6", "1d1", "1d1001", "2d6+", "d", "abc", "2x6", "1d2+1001",
                    "1d2+9223372036854775807", "1d2+99999999999999999999"] {
            XCTAssertNil(DiceExpression.parse(bad), bad)
        }
    }

    func testRollDiceAndOptions() {
        var rng = SeededRNG(state: 42)
        let rolled = DiceRoller.roll(DiceCard(id: "d-1", title: "", dice: "3d6+2", options: nil, result: nil), using: &rng)
        let rolls = rolled?.result?.rolls ?? []
        XCTAssertEqual(rolls.count, 3)
        XCTAssertTrue(rolls.allSatisfy { (1...6).contains($0) })
        XCTAssertEqual(rolled?.result?.total, rolls.reduce(0, +) + 2)
        XCTAssertEqual(rolled?.id, "d-1")

        let picked = DiceRoller.roll(DiceCard(id: "d-2", title: "吃什么", dice: nil, options: ["火锅", "寿司", "面"], result: nil), using: &rng)
        XCTAssertTrue((0..<3).contains(picked?.result?.pick ?? -1))
        XCTAssertNil(picked?.result?.rolls)

        XCTAssertNil(DiceRoller.roll(DiceCard(id: "d-3", title: "", dice: "bad", options: nil, result: nil), using: &rng))
        XCTAssertNil(DiceRoller.roll(DiceCard(id: "d-4", title: "", dice: nil, options: [], result: nil), using: &rng))
        // dice 与 options 都有：以 dice 为准
        let both = DiceRoller.roll(DiceCard(id: "d-5", title: "", dice: "1d4", options: ["a", "b"], result: nil), using: &rng)
        XCTAssertNotNil(both?.result?.rolls)
        XCTAssertNil(both?.result?.pick)
        // 模型写错的 pick
        XCTAssertNil(DiceCard(id: "d-6", title: "", dice: nil, options: ["a"], result: DiceResult(rolls: nil, total: nil, pick: 5)).validPick)
        XCTAssertEqual(DiceCard(id: "d-7", title: "", dice: nil, options: ["a", "b"], result: DiceResult(rolls: nil, total: nil, pick: 1)).validPick, 1)
    }

    func testParseDiceAndTimerCards() {
        guard case .dice(let d)? = ChatCard.parse(language: "card-dice", code: #"{"id":"d-1","title":"x","options":["a","b"],"result":{"pick":1}}"#) else { return XCTFail() }
        XCTAssertEqual(d.result?.pick, 1)
        guard case .timer(let t)? = ChatCard.parse(language: "card-timer", code: #"{"id":"c-1","title":"泡面","seconds":180}"#) else { return XCTFail() }
        XCTAssertTrue(t.autoStart)
        XCTAssertEqual(t.durationText, "3 分钟")
        XCTAssertEqual(t.finishedMessage, "⏰ 计时结束：泡面（3 分钟）")
        XCTAssertEqual(TimerCard(id: nil, title: "", seconds: 90, autoStart: false).durationText, "1 分 30 秒")
        XCTAssertEqual(TimerCard(id: nil, title: "", seconds: 3660, autoStart: false).durationText, "1 小时 1 分")
        XCTAssertEqual(TimerCard(id: nil, title: "", seconds: 45, autoStart: false).finishedMessage, "⏰ 计时结束：计时器（45 秒）")
        XCTAssertNil(ChatCard.parse(language: "card-timer", code: #"{"id":"c-2","seconds":0}"#))
        XCTAssertNil(ChatCard.parse(language: "card-timer", code: #"{"id":"c-3","seconds":90000}"#))
        let card = ChatCard.timer(t)
        XCTAssertEqual(ChatCardExtractor.cards(in: card.blockText), [card])
        XCTAssertEqual(card.kindLabel, "计时器")
        // 待发附件往返
        let data = try? JSONEncoder().encode([PendingChatAttachment.card(.dice(d)), .card(card)])
        let back = data.flatMap { try? JSONDecoder().decode([PendingChatAttachment].self, from: $0) }
        XCTAssertEqual(back?.compactMap(\.chatCard), [.dice(d), card])
    }

    @MainActor
    final class FakeNotifier: TimerNotificationScheduling {
        var scheduled: [String: Date] = [:]
        var chatIds: [String: String] = [:]
        func schedule(id: String, title: String, body: String, at: Date, conversationId: String) {
            scheduled[id] = at
            chatIds[id] = conversationId
        }
        func cancel(id: String) { scheduled[id] = nil }
    }

    @MainActor
    private func makeTimerStore(_ clock: @escaping () -> Date, _ notifier: FakeNotifier, suite: String) -> TimerCardStore {
        TimerCardStore(defaults: UserDefaults(suiteName: suite)!, clock: clock, notifier: notifier, live: false)
    }

    private func withSuite(_ body: (String) -> Void) {
        let suite = "chatcard-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        body(suite)
    }

    private let noodle = TimerCard(id: "c-1", title: "泡面", seconds: 180, autoStart: true)

    @MainActor
    func testTimerStartPauseResumeFinishOnce() {
        withSuite { suite in
            var now = Date(timeIntervalSince1970: 1_000)
            let notifier = FakeNotifier()
            let store = makeTimerStore({ now }, notifier, suite: suite)
            let key = TimerCardStore.key(conversationId: "conv", nodeId: "n1", cardId: "c-1")

            XCTAssertEqual(store.phase(key), .idle)
            store.start(key: key, conversationId: "conv", nodeId: "n1", card: noodle)
            XCTAssertEqual(store.phase(key), .running(endsAt: now.addingTimeInterval(180)))
            XCTAssertNotNil(notifier.scheduled[key])

            now = now.addingTimeInterval(60)
            store.pause(key)
            XCTAssertEqual(store.phase(key), .paused(remaining: 120))
            XCTAssertNil(notifier.scheduled[key])
            now = now.addingTimeInterval(1_000)
            store.checkExpired()
            XCTAssertTrue(store.outbox.isEmpty)

            store.start(key: key, conversationId: "conv", nodeId: "n1", card: noodle)
            XCTAssertEqual(store.phase(key), .running(endsAt: now.addingTimeInterval(120)))
            now = now.addingTimeInterval(121)
            store.checkExpired()
            store.checkExpired()
            XCTAssertEqual(store.outbox.map(\.text), ["⏰ 计时结束：泡面（3 分钟）"])
            XCTAssertEqual(store.phase(key), .finished)
            XCTAssertNotNil(notifier.scheduled[key])                   // 到点不撤系统通知（避免与投递竞态）

            store.reset(key)
            XCTAssertEqual(store.phase(key), .idle)
            store.start(key: key, conversationId: "conv", nodeId: "n1", card: noodle)
            now = now.addingTimeInterval(181)
            store.checkExpired()
            XCTAssertEqual(store.outbox.count, 2)
            XCTAssertNotEqual(store.outbox[0].id, store.outbox[1].id)  // 新一轮新事件
        }
    }

    @MainActor
    func testAutoStartUsesSendTimeExpiredSilentAndResetSticks() {
        withSuite { suite in
            var now = Date(timeIntervalSince1970: 10_000)
            let notifier = FakeNotifier()
            let store = makeTimerStore({ now }, notifier, suite: suite)
            let live = TimerCardStore.key(conversationId: "conv", nodeId: "n1", cardId: "c-1")
            store.registerAutoStart(key: live, conversationId: "conv", nodeId: "n1", card: noodle, sentAt: now.addingTimeInterval(-30))
            XCTAssertEqual(store.phase(live), .running(endsAt: now.addingTimeInterval(150)))

            let old = TimerCardStore.key(conversationId: "conv", nodeId: "n0", cardId: "c-0")
            store.registerAutoStart(key: old, conversationId: "conv", nodeId: "n0", card: noodle, sentAt: now.addingTimeInterval(-7 * 86_400))
            XCTAssertEqual(store.phase(old), .finished)
            XCTAssertNil(notifier.scheduled[old])
            store.registerAutoStart(key: old, conversationId: "conv", nodeId: "n0", card: noodle, sentAt: now)
            XCTAssertEqual(store.phase(old), .finished)                 // 再次出现不重启

            store.reset(live)                                            // 用户重置
            store.registerAutoStart(key: live, conversationId: "conv", nodeId: "n1", card: noodle, sentAt: now)
            XCTAssertEqual(store.phase(live), .idle)                     // 重置记住，不再自动开始
            now = now.addingTimeInterval(500)
            store.checkExpired()
            XCTAssertTrue(store.outbox.isEmpty)
        }
    }

    @MainActor
    func testOutboxSurvivesRelaunchUntilAcked() {
        withSuite { suite in
            var now = Date(timeIntervalSince1970: 50_000)
            let key = TimerCardStore.key(conversationId: "A", nodeId: "n1", cardId: "c-1")
            do {
                let store = makeTimerStore({ now }, FakeNotifier(), suite: suite)
                store.start(key: key, conversationId: "A", nodeId: "n1", card: noodle)
            }
            now = now.addingTimeInterval(200)
            do {
                let relaunched = makeTimerStore({ now }, FakeNotifier(), suite: suite)
                relaunched.checkExpired()                                // 关着 app 时到点
                XCTAssertEqual(relaunched.outbox.count, 1)
                XCTAssertNil(relaunched.claim(conversationId: "B"))     // 别的对话认领不到
                let event = relaunched.claim(conversationId: "A")
                XCTAssertNotNil(event)
                XCTAssertNil(relaunched.claim(conversationId: "A"))     // 已被认领（另一个窗口拿不到）
                relaunched.release(event!.id)                            // 发送失败：放回
            }
            do {
                let again = makeTimerStore({ now }, FakeNotifier(), suite: suite)   // 发送前又重启
                let event = again.claim(conversationId: "A")
                XCTAssertNotNil(event)
                again.ack(event!.id)
                XCTAssertTrue(again.outbox.isEmpty)
            }
            let final = makeTimerStore({ now }, FakeNotifier(), suite: suite)
            final.checkExpired()
            XCTAssertTrue(final.outbox.isEmpty)                          // 确认后不会再冒出来
        }
    }

    @MainActor
    func testPausedSurvivesRelaunch() {
        withSuite { suite in
            var now = Date(timeIntervalSince1970: 70_000)
            let key = TimerCardStore.key(conversationId: "A", nodeId: "n1", cardId: "c-1")
            do {
                let store = makeTimerStore({ now }, FakeNotifier(), suite: suite)
                store.start(key: key, conversationId: "A", nodeId: "n1", card: noodle)
                now = now.addingTimeInterval(30)
                store.pause(key)
            }
            now = now.addingTimeInterval(10_000)                          // 越过原到点时刻
            let notifier = FakeNotifier()
            let relaunched = makeTimerStore({ now }, notifier, suite: suite)
            relaunched.checkExpired()
            XCTAssertEqual(relaunched.phase(key), .paused(remaining: 150))
            XCTAssertTrue(relaunched.outbox.isEmpty)
            XCTAssertTrue(notifier.scheduled.isEmpty)
            relaunched.start(key: key, conversationId: "A", nodeId: "n1", card: noodle)
            XCTAssertEqual(relaunched.phase(key), .running(endsAt: now.addingTimeInterval(150)))
        }
    }

    @MainActor
    func testCancelStopsTimerSilently() {
        withSuite { suite in
            let now = Date(timeIntervalSince1970: 1)
            let notifier = FakeNotifier()
            let store = makeTimerStore({ now }, notifier, suite: suite)
            let key = TimerCardStore.key(conversationId: "c", nodeId: "n", cardId: "x")
            store.start(key: key, conversationId: "c", nodeId: "n", card: noodle)
            store.cancel(key)
            XCTAssertEqual(store.phase(key), .finished)
            XCTAssertNil(notifier.scheduled[key])
            XCTAssertTrue(store.outbox.isEmpty)
        }
    }

    func testRegistryDiceAndTimerKinds() {
        let dice = #"{"id":"d","title":"","dice":"1d6"}"#
        XCTAssertEqual(ChatCardRegistry.kind(language: "card-dice", code: dice, streaming: false),
                       .card(.dice(DiceCard(id: "d", title: "", dice: "1d6", options: nil, result: nil))))
        XCTAssertNotNil(ChatCardRegistry.view(language: "card-dice", code: dice, nodeId: "n", streaming: false))
        let timer = #"{"id":"c","title":"","seconds":60,"autoStart":false}"#
        XCTAssertNotNil(ChatCardRegistry.view(language: "card-timer", code: timer, nodeId: "n", streaming: false))
    }

    func testTimerClockText() {
        XCTAssertEqual(TimerCardView.clockText(180), "3:00")
        XCTAssertEqual(TimerCardView.clockText(59.2), "1:00")
        XCTAssertEqual(TimerCardView.clockText(3725), "1:02:05")
        XCTAssertEqual(TimerCardView.clockText(0), "0:00")
    }

    func testTimerDeliveryDecision() {
        let event = TimerFinishedEvent(id: "A|n1|c#1", conversationId: "A", nodeId: "n1", text: "⏰")
        func decide(conv: String? = "A", path: Set<String> = ["n1"], active: Bool = true,
                    busy: Bool = false, quote: Bool = false) -> TimerDelivery.Decision {
            TimerDelivery.shouldSend(event: event, selectedConversationId: conv, pathNodeIds: path,
                                     isActive: active, turnInFlight: busy, hasQuote: quote)
        }
        XCTAssertEqual(decide(), .send)
        XCTAssertEqual(decide(conv: "B"), .wait)          // 别的对话开着：等
        XCTAssertEqual(decide(conv: nil), .wait)
        XCTAssertEqual(decide(active: false), .wait)      // 后台：等
        XCTAssertEqual(decide(busy: true), .wait)         // 模型在回：等（不进普通排队）
        XCTAssertEqual(decide(quote: true), .wait)        // 输入框挂着引用：等
        XCTAssertEqual(decide(path: ["n9"]), .drop)       // 那条消息已不在当前路径（重新生成 / 切分支）
    }

    func testMakeDiceAndTimer() {
        let d = DiceCard.make(title: "", count: 2, sides: 6, avoiding: [])
        XCTAssertEqual(d.dice, "2d6")
        XCTAssertTrue(d.id?.hasPrefix("d-") ?? false)
        XCTAssertEqual(DiceCard.make(title: "吃", optionLines: ["火锅", " ", "面"], avoiding: [])?.options, ["火锅", "面"])
        XCTAssertNil(DiceCard.make(title: "", optionLines: ["只有一个"], avoiding: []))
        let t = TimerCard.make(title: "泡面", minutes: 3, seconds: 0, autoStart: true, avoiding: [])
        XCTAssertEqual(t?.seconds, 180)
        XCTAssertTrue(t?.id?.hasPrefix("c-") ?? false)
        XCTAssertNil(TimerCard.make(title: "", minutes: 0, seconds: 0, autoStart: true, avoiding: []))
    }

    func testPromptGuideCoversDiceAndTimer() {
        let text = ChatCardPromptGuide.text
        XCTAssertTrue(text.contains("card-dice"))
        XCTAssertTrue(text.contains("card-timer"))
        XCTAssertTrue(text.contains("autoStart"))
        XCTAssertFalse(text.contains("t-3f2a"))
    }

    /// 掷骰工具（plan-chat-cards-dice-tool Task 3）：教模型用 roll_dice，不再自己写结果；工具关着时有退路
    func testPromptGuideTeachesDiceTool() {
        let text = ChatCardPromptGuide.text
        XCTAssertTrue(text.contains("roll_dice"))
        XCTAssertFalse(text.contains("你替对方掷时直接带结果"))
        XCTAssertTrue(text.contains("没有 roll_dice"))
        XCTAssertFalse(text.contains("解码"))
        XCTAssertTrue(text.contains("id 传给 roll_dice"))                         // 替对方掷已有的卡
    }

    // MARK: - 第 3 期终审修复

    /// I1：卡片没来得及画出来就过期（锁屏 / 切走）→ 仍补发；真正的旧对话才静默
    @MainActor
    func testLateFirstSightStillFiresUnlessReallyOld() {
        withSuite { suite in
            let now = Date(timeIntervalSince1970: 1_000_000)
            let notifier = FakeNotifier()
            let store = makeTimerStore({ now }, notifier, suite: suite)
            let recent = TimerCardStore.key(conversationId: "A", nodeId: "n1", cardId: "c-1")
            store.registerAutoStart(key: recent, conversationId: "A", nodeId: "n1", card: noodle, sentAt: now.addingTimeInterval(-600))
            XCTAssertEqual(store.phase(recent), .finished)
            XCTAssertEqual(store.outbox.map(\.conversationId), ["A"])          // 10 分钟前的 3 分钟计时：补发
            XCTAssertNil(notifier.scheduled[recent])                          // 已经过了，不再预约通知
            let old = TimerCardStore.key(conversationId: "A", nodeId: "n0", cardId: "c-0")
            store.registerAutoStart(key: old, conversationId: "A", nodeId: "n0", card: noodle, sentAt: now.addingTimeInterval(-86_400))
            XCTAssertEqual(store.outbox.count, 1)                             // 一天前的：静默
        }
    }

    /// I1：回复写完 / CC 落地时从正文里找出要自动开始的计时器
    func testAutoStartTimersInContent() {
        let auto = ChatCard.timer(TimerCard(id: "c-1", title: "泡面", seconds: 180, autoStart: true))
        let manual = ChatCard.timer(TimerCard(id: "c-2", title: "", seconds: 60, autoStart: false))
        let noId = ChatCard.timer(TimerCard(id: nil, title: "", seconds: 60, autoStart: true))
        let text = "好的\n\n" + auto.blockText + "\n\n" + manual.blockText + "\n\n" + noId.blockText + "\n\n" + todo("t").blockText
        XCTAssertEqual(ConversationViewModel.autoStartTimers(in: text).map(\.id), ["c-1"])
    }

    /// I2：任何一个窗口在回复这个对话（或 CC 在等回复）都算忙
    @MainActor
    func testTurnInFlightAcrossWindows() {
        let a = ConversationViewModel()
        let b = ConversationViewModel()
        XCTAssertFalse(ConversationViewModel.isBusy(conversationId: "X"))
        a.assistantTurnInFlight = true
        a.activeConversationId = "X"
        XCTAssertTrue(ConversationViewModel.isBusy(conversationId: "X"))
        XCTAssertFalse(ConversationViewModel.isBusy(conversationId: "Y"))
        b.ccWaitingSince["Y"] = Date()
        XCTAssertTrue(ConversationViewModel.isBusy(conversationId: "Y"))
        a.assistantTurnInFlight = false
        a.activeConversationId = nil
        b.ccWaitingSince["Y"] = nil
        withExtendedLifetime((a, b)) {}
    }

    /// I3：通知带对话 id（点通知打开那个对话）
    @MainActor
    func testTimerNotificationCarriesConversation() {
        withSuite { suite in
            let notifier = FakeNotifier()
            let store = makeTimerStore({ Date(timeIntervalSince1970: 5) }, notifier, suite: suite)
            let key = TimerCardStore.key(conversationId: "A", nodeId: "n", cardId: "c")
            store.start(key: key, conversationId: "A", nodeId: "n", card: noodle)
            XCTAssertEqual(notifier.chatIds[key], "A")
        }
    }

    // MARK: - 真机反馈：骰子动画 / 计时器滚轮

    /// 翻滚节奏：先快后慢（减速停下），总时长约 0.9 秒
    func testDiceRollDelaysDecelerate() {
        let delays = DiceRollAnimation.delays
        XCTAssertGreaterThanOrEqual(delays.count, 8)
        XCTAssertEqual(delays, delays.sorted())                        // 单调变慢
        XCTAssertEqual(delays.reduce(0, +), 0.9, accuracy: 0.15)
    }

    func testDieFacePips() {
        XCTAssertEqual(DieFace.pips(for: 1), [4])                      // 3×3 格子里的位置 0…8
        XCTAssertEqual(DieFace.pips(for: 6), [0, 2, 3, 5, 6, 8])
        XCTAssertEqual(DieFace.pips(for: 5), [0, 2, 4, 6, 8])
        XCTAssertEqual(DieFace.pips(for: 7), [])                        // 非六面骰不画点
    }

    /// 时钟式滚轮：时 / 分 / 秒
    func testMakeTimerFromHoursMinutesSeconds() {
        XCTAssertEqual(TimerCard.make(title: "", hours: 1, minutes: 2, seconds: 3, autoStart: true, avoiding: [])?.seconds, 3723)
        XCTAssertNil(TimerCard.make(title: "", hours: 0, minutes: 0, seconds: 0, autoStart: true, avoiding: []))
        XCTAssertEqual(TimerCard.make(title: "", hours: 24, minutes: 0, seconds: 0, autoStart: true, avoiding: [])?.seconds, 86_400)
    }

    // MARK: - roll_dice 工具（模型自己掷）

    /// 工具结果 = 卡片块原文 + 空行 + 一行摘要（终审 I1：不把卡包进 JSON 字符串，免得模型抄出转义）
    private func diceToolCard(_ r: (text: String, isError: Bool)) -> DiceCard? {
        guard case .dice(let d)? = ChatCardExtractor.cards(in: r.text).first else { return nil }
        return d
    }

    private func diceToolSummary(_ r: (text: String, isError: Bool)) -> String? {
        r.text.components(separatedBy: "\n").last
    }

    func testDiceToolRollsExpression() throws {
        var rng = SeededRNG(state: 7)
        let r = DiceTool.execute(inputJSON: #"{"dice":"2d6+1","title":"攻击"}"#, using: &rng, takenIds: [])
        XCTAssertFalse(r.isError, r.text)
        guard let d = diceToolCard(r) else { return XCTFail(r.text) }
        XCTAssertTrue(r.text.hasPrefix(ChatCard.dice(d).blockText + "\n\n"), r.text)   // 卡片块原文在最前，可原样转发
        XCTAssertEqual(d.title, "攻击")
        XCTAssertEqual(d.dice, "2d6+1")
        let rolls = d.result?.rolls ?? []
        XCTAssertEqual(rolls.count, 2)
        XCTAssertEqual(d.result?.total, rolls.reduce(0, +) + 1)
        XCTAssertEqual(diceToolSummary(r), "2d6+1 → \(rolls[0]) + \(rolls[1]) + 1 = \(d.result!.total!)")
        XCTAssertTrue(d.id?.hasPrefix("d-") ?? false)
    }

    func testDiceToolPicksOptionAndTrimsNewlines() throws {
        var rng = SeededRNG(state: 9)
        let r = DiceTool.execute(inputJSON: #"{"options":[" 火锅\n","寿司","面"],"title":"\n吃什么\n"}"#, using: &rng, takenIds: [])
        XCTAssertFalse(r.isError, r.text)
        guard let d = diceToolCard(r) else { return XCTFail(r.text) }
        XCTAssertEqual(d.title, "吃什么")
        XCTAssertEqual(d.options, ["火锅", "寿司", "面"])
        XCTAssertEqual(diceToolSummary(r), "抽中：\(d.options![d.validPick!])")
    }

    /// 替对方掷已有的卡：给 id 就沿用（终审 I2），不另起新卡
    func testDiceToolReusesGivenId() {
        var rng = SeededRNG(state: 5)
        let r = DiceTool.execute(inputJSON: #"{"id":" d-1a2b ","dice":"d20"}"#, using: &rng, takenIds: ["d-1a2b"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(diceToolCard(r)?.id, "d-1a2b")
        for bad in [#"{"id":"t-1a2b","dice":"d6"}"#, #"{"id":1,"dice":"d6"}"#, #"{"id":"d-a b","dice":"d6"}"#, #"{"id":"d-","dice":"d6"}"#] {
            XCTAssertTrue(DiceTool.execute(inputJSON: bad, using: &rng, takenIds: []).isError, bad)
        }
    }

    func testDiceToolRejectsBadInput() {
        var rng = SeededRNG(state: 1)
        for input in [#"{}"#, #"{"dice":"3d7000"}"#, #"{"options":["只有一个"]}"#, #"not json"#,
                      #"{"dice":"1d6","options":["a","b"]}"#, #"{"dice":1}"#, #"{"title":1,"dice":"d6"}"#,
                      #"{"options":[1,2]}"#, #"{"options":["a",2]}"#, #"{"options":"a,b"}"#,
                      #"{"dice":"  ","options":[]}"#, #"{"dice":null}"#] {
            XCTAssertTrue(DiceTool.execute(inputJSON: input, using: &rng, takenIds: []).isError, input)
        }
        // 空白 dice + 合法 options = 只有 options
        XCTAssertFalse(DiceTool.execute(inputJSON: #"{"dice":" ","options":["a","b"]}"#, using: &rng, takenIds: []).isError)
        // 无参调用（有的 provider 发空串）按 {} 处理，报「要给 dice 或 options」，与 CC 端同文案
        XCTAssertEqual(DiceTool.execute(inputJSON: " ", using: &rng, takenIds: []).text, "要给 dice 或 options")
    }

    /// 同一轮里连掷两次：第二张不能撞第一张的 id
    func testDiceToolAvoidsTakenIds() throws {
        var rng = SeededRNG(state: 3)
        let all = Set((0...0xFFFF).map { "d-" + String(format: "%04x", $0) })
        let r = DiceTool.execute(inputJSON: #"{"dice":"d6"}"#, using: &rng, takenIds: all)
        guard let d = diceToolCard(r) else { return XCTFail(r.text) }
        XCTAssertFalse(all.contains(d.id!))
    }

    /// 两端逐字一致：cc-bridge/dice.test.ts 用同一个字面量
    func testDiceCardBlockMatchesBridgeFixture() {
        let card = DiceCard(id: "d-0001", title: "攻\"击\"/中文", dice: "2d6+1", options: nil,
                            result: DiceResult(rolls: [3, 5], total: 9, pick: nil))
        XCTAssertEqual(ChatCard.dice(card).blockText,
                       "```card-dice\n{\"dice\":\"2d6+1\",\"id\":\"d-0001\",\"result\":{\"rolls\":[3,5],\"total\":9},\"title\":\"攻\\\"击\\\"/中文\"}\n```")
    }

    @MainActor
    func testDiceToolIsRegisteredBehindToolsMaster() {
        XCTAssertTrue(ToolRegistry.all.contains { $0.definition.name == DiceTool.toolName })
        XCTAssertEqual(PermissionDomain.forTool(named: DiceTool.toolName), .toolsMaster)
    }

    // MARK: - 第 4 期：图表卡 / 音乐卡

    func testChartCardParsesAndRoundTrips() throws {
        let code = #"{"id":"g-1a2b","title":"本周睡眠","type":"bar","unit":"小时","series":[{"name":"睡眠","points":[["周一",7.5],["周二",6]]}]}"#
        guard case .chart(let c)? = ChatCard.parse(language: "card-chart", code: code) else { return XCTFail() }
        XCTAssertEqual(c.type, .bar)
        XCTAssertEqual(c.unit, "小时")
        XCTAssertEqual(c.series.first?.points.map(\.label), ["周一", "周二"])
        XCTAssertEqual(c.series.first?.points.map(\.value), [7.5, 6])
        XCTAssertEqual(ChatCard.chart(c).kindLabel, "图表")
        XCTAssertEqual(ChatCard.chart(c).id, "g-1a2b")
        XCTAssertEqual(ChatCardExtractor.cards(in: ChatCard.chart(c).blockText), [.chart(c)])
    }

    func testChartCardRejectsBadData() {
        let bad = [
            #"{"type":"bar","series":[]}"#,
            #"{"type":"radar","series":[{"points":[["a",1]]}]}"#,                                  // 不认识的图型
            #"{"type":"bar","series":[{"points":[{"x":"a","y":1}]}]}"#,
            #"{"type":"bar","series":[{"points":[["a","7.5"]]}]}"#,
            #"{"type":"bar","series":[{"points":[["a",1,2]]}]}"#,
            #"{"type":"bar","series":[{"points":[["  ",1]]}]}"#,
            #"{"type":"bar","series":[{"points":[]}]}"#,
            #"{"type":"bar","series":[{"points":[["a",1],[" a ",2]]}]}"#,                       // 同系列重复标签（R5 E1）
            #"{"type":"bar","series":[{"points":[["a",1e999]]}]}"#,                                 // 溢出（R5 E2）
            #"{"type":"bar","series":[{"points":[["a",NaN]]}]}"#,
            #"{"type":"bar","series":[{"points":[["a","Infinity"]]}]}"#,
            #"{"type":"pie","series":[{"points":[["a",1e308],["b",1e308]]}]}"#,                     // 饼图和溢出
            #"{"type":"pie","series":[{"points":[["a",-1],["b",2]]}]}"#,
            #"{"type":"pie","series":[{"points":[["a",0],["b",0]]}]}"#,
            #"{"type":"pie","series":[{"points":[["a",1]]},{"points":[["b",1]]}]}"#,
            #"{"type":"line","series":[{"points":[["a",1]]},{"points":[["a",1]]},{"points":[["a",1]]},{"points":[["a",1]]},{"points":[["a",1]]}]}"#,
        ]
        for code in bad { XCTAssertNil(ChatCard.parse(language: "card-chart", code: code), code) }
        let tooMany = (0...60).map { #"["p\#($0)",1]"# }.joined(separator: ",")
        XCTAssertNil(ChatCard.parse(language: "card-chart", code: #"{"type":"bar","series":[{"points":[\#(tooMany)]}]}"#))
        // 宽松：title / unit / name / id 可缺；整数值可用；不同系列可同名标签
        guard case .chart(let ok)? = ChatCard.parse(language: "card-chart", code: #"{"type":"line","series":[{"points":[[" 一 ",3]]},{"points":[["一",4]]}]}"#) else { return XCTFail() }
        XCTAssertEqual(ok.title, "")
        XCTAssertEqual(ok.series[0].name, "")
        XCTAssertEqual(ok.series[0].points[0].label, "一")
        XCTAssertNil(ChatCard.chart(ok).id)
    }

    private func musicCard(_ json: String) -> MusicCard? {
        if case .music(let m)? = ChatCard.parse(language: "card-music", code: json) { return m }
        return nil
    }

    func testMusicCardParsesAndValidatesLinks() throws {
        let code = #"{"id":"m-1","title":" 晴天 ","artist":"周杰伦","cover":"https://x.com/c.jpg","url":"https://x.com/a/song.MP3?token=1","link":"https://music.163.com/song?id=1"}"#
        guard let m = musicCard(code) else { return XCTFail() }
        XCTAssertEqual(m.title, "晴天")
        XCTAssertEqual(m.playableURL?.absoluteString, "https://x.com/a/song.MP3?token=1")
        XCTAssertEqual(m.linkURL?.host, "music.163.com")
        XCTAssertEqual(m.coverURL?.absoluteString, "https://x.com/c.jpg")
        XCTAssertEqual(ChatCard.music(m).kindLabel, "音乐")
        XCTAssertEqual(ChatCardExtractor.cards(in: ChatCard.music(m).blockText), [.music(m)])

        XCTAssertNil(musicCard(#"{"title":"  "}"#))
        XCTAssertNil(musicCard(#"{"artist":"x"}"#))
        XCTAssertNil(musicCard(#"{"title":1}"#))
        let weird = musicCard(#"{"title":"t","url":"http://x.com/a.mp3","link":"javascript:alert(1)","cover":"http://x.com/c.jpg"}"#)
        XCTAssertNotNil(weird)
        XCTAssertNil(weird?.playableURL)
        XCTAssertNil(weird?.linkURL)
        XCTAssertNil(weird?.coverURL)
        XCTAssertNil(musicCard(#"{"title":"t","url":"https://x.com/stream"}"#)?.playableURL)
        XCTAssertNotNil(musicCard(#"{"title":"t","url":"https://x.com/a.m4a"}"#)?.playableURL)
        XCTAssertNotNil(musicCard(#"{"title":"t","link":"http://x.com"}"#)?.linkURL)
        // 非公网目标不播、不拉封面（R5 U8）
        XCTAssertNil(musicCard(#"{"title":"t","url":"https://192.168.1.2/a.mp3","cover":"https://localhost/c.jpg"}"#)?.playableURL)
        XCTAssertNil(musicCard(#"{"title":"t","cover":"https://localhost/c.jpg"}"#)?.coverURL)
        // 可选字段类型错 = 没给，不拖垮整卡（R5 E3）
        let typed = musicCard(#"{"title":"t","cover":123,"url":{},"link":[1],"artist":5}"#)
        XCTAssertNotNil(typed)
        XCTAssertEqual(typed?.artist, "")
        XCTAssertNil(typed?.url)
    }

    /// 流式中图表 / 音乐卡即使 JSON 已完整也给占位（R5 D3）；定稿后给卡
    func testChartAndMusicArePlaceholdersWhileStreaming() {
        let chart = #"{"type":"bar","series":[{"points":[["a",1]]}]}"#
        XCTAssertEqual(ChatCardRegistry.kind(language: "card-chart", code: chart, streaming: true), .placeholder)
        XCTAssertNotEqual(ChatCardRegistry.kind(language: "card-chart", code: chart, streaming: false), .placeholder)
        XCTAssertEqual(ChatCardRegistry.kind(language: "card-music", code: #"{"title":"t"}"#, streaming: true), .placeholder)
    }

    // MARK: 第 4 期 · 动效与图表数学

    func testRubberBandAndReduceMotion() {
        XCTAssertEqual(ChatCardMotion.rubberBand(0.4, in: 0...1), 0.4)
        XCTAssertEqual(ChatCardMotion.rubberBand(1.4, in: 0...1), 1.14, accuracy: 1e-9)
        XCTAssertEqual(ChatCardMotion.rubberBand(-0.2, in: 0...1), -0.07, accuracy: 1e-9)
        XCTAssertEqual(ChatCardMotion.rubberBand(5, in: 0...1), 1.15, accuracy: 1e-9)          // 拉伸有上限（终审）
        XCTAssertEqual(ChatCardMotion.rubberBand(-5, in: 0...1), -0.15, accuracy: 1e-9)
        XCTAssertEqual(ChatCardMotion.animation(ChatCardMotion.snappy, reduceMotion: false), ChatCardMotion.snappy)
        XCTAssertEqual(ChatCardMotion.animation(ChatCardMotion.draw, reduceMotion: true), ChatCardMotion.fade)
    }

    private func chart(_ json: String) -> ChartCard {
        guard case .chart(let c)? = ChatCard.parse(language: "card-chart", code: json) else { fatalError(json) }
        return c
    }

    func testChartMathCategoriesAlignAcrossSeries() {
        let c = chart(#"{"type":"bar","unit":"小时","series":[{"name":"A","points":[["周一",1],["周二",2]]},{"name":"B","points":[["周二",3],["周三",4.25]]}]}"#)
        XCTAssertEqual(ChartMath.categories(c), ["周一", "周二", "周三"])
        XCTAssertNil(ChartMath.value(c.series[1], at: "周一"))
        XCTAssertEqual(ChartMath.value(c.series[1], at: "周三"), 4.25)
        let rows = ChartMath.tooltipRows(c, label: "周一")
        XCTAssertEqual(rows.map(\.name), ["A", "B"])
        XCTAssertEqual(rows.map(\.text), ["1 小时", "—"])
    }

    func testChartMathFormatAndDomain() {
        XCTAssertEqual(ChartMath.format(7), "7")
        XCTAssertEqual(ChartMath.format(7.5), "7.5")
        XCTAssertEqual(ChartMath.format(1.23456), "1.23")
        XCTAssertEqual(ChartMath.format(-2.10), "-2.1")
        XCTAssertEqual(ChartMath.format(12345678), "12,345,678")
        // Y 域由最终值定、含 0、上下各留 8%；全 0 → 0...1（R5 U7）
        let pos = ChartMath.yDomain(chart(#"{"type":"bar","series":[{"points":[["a",1],["b",2]]}]}"#))
        XCTAssertEqual(pos.lowerBound, 0)
        XCTAssertEqual(pos.upperBound, 2.16, accuracy: 1e-9)
        let mixed = ChartMath.yDomain(chart(#"{"type":"line","series":[{"points":[["a",-3],["b",2]]}]}"#))
        XCTAssertEqual(mixed.lowerBound, -3.24, accuracy: 1e-9)
        XCTAssertEqual(mixed.upperBound, 2.16, accuracy: 1e-9)
        XCTAssertEqual(ChartMath.yDomain(chart(#"{"type":"bar","series":[{"points":[["a",0]]}]}"#)), 0...1)
    }

    /// 环形命中：12 点起顺时针；落在环上才算（R5 U6）
    func testChartMathPieHit() {
        let pts = [ChartCard.Point(label: "a", value: 1), .init(label: "b", value: 0), .init(label: "c", value: 3)]
        let center = CGPoint(x: 100, y: 100)
        func hit(_ x: CGFloat, _ y: CGFloat) -> Int? {
            ChartMath.sliceIndex(at: CGPoint(x: x, y: y), center: center, outerRadius: 100, innerRatio: 0.58, points: pts)
        }
        XCTAssertEqual(hit(100, 20), 0)     // 正上方
        XCTAssertEqual(hit(180, 100), 2)    // 3 点钟：累计 1.0 → 跳过 0 值扇区 → c
        XCTAssertEqual(hit(100, 180), 2)
        XCTAssertEqual(hit(20, 100), 2)
        XCTAssertNil(hit(100, 100))         // 环心空洞
        XCTAssertNil(hit(100, -50))         // 环外
    }

    /// 选中：轻点选中 / 轻点同一项或空白收起（图表只有轻点，不抢聊天滚动）
    func testChartTap() {
        typealias M = ChartMath
        XCTAssertEqual(M.reduceTap(current: nil, hit: "一"), "一")
        XCTAssertEqual(M.reduceTap(current: "一", hit: "二"), "二")
        XCTAssertNil(M.reduceTap(current: "二", hit: "二"))
        XCTAssertNil(M.reduceTap(current: "二", hit: nil))
    }

    /// 进度条只在水平拖动占优时接管（不抢纵向滚动，终审 C1）
    func testMusicScrubOnlyHorizontal() {
        XCTAssertTrue(MusicScrub.accepts(CGSize(width: 12, height: 3)))
        XCTAssertFalse(MusicScrub.accepts(CGSize(width: 3, height: 12)))
        XCTAssertFalse(MusicScrub.accepts(CGSize(width: 5, height: 5)))
    }

    /// 浮标两边：中心夹在区内（R5 D1 / D4）
    func testTooltipEdgesClamp() {
        XCTAssertEqual(ChartMath.edges(center: 50, width: 40, bounds: 0...300).left, 30)
        XCTAssertEqual(ChartMath.edges(center: 5, width: 40, bounds: 0...300).left, 0)
        XCTAssertEqual(ChartMath.edges(center: 299, width: 40, bounds: 0...300).right, 300)
        XCTAssertEqual(ChartMath.edges(center: 50, width: 400, bounds: 0...300).left, 0)
    }

    // MARK: 第 4 期 · 音乐播放器

    @MainActor
    final class FakeMusicEngine: MusicEngine {
        var onTime: ((Int, Double, Double) -> Void)?
        var onEnd: ((Int) -> Void)?
        var onFail: ((Int) -> Void)?
        var onState: ((Int, MusicEngineState) -> Void)?
        var log: [String] = []
        var generation = 0
        func load(_ url: URL) -> Int { generation += 1; log.append("load \(url.lastPathComponent)"); return generation }
        func play() { log.append("play") }
        func pause() { log.append("pause") }
        func seek(to seconds: Double) { log.append("seek \(Int(seconds))") }
        func stop() { log.append("stop") }
        func setVolume(_ v: Float) { log.append("volume \(v)") }
        var liveLevel: Float?
        func currentLevel() -> Float? { liveLevel }
    }

    private static let songA = URL(string: "https://x.com/a.mp3")!
    private static let songB = URL(string: "https://x.com/b.mp3")!

    @MainActor
    func testMusicPlayerToggleSwitchAndEnd() {
        let engine = FakeMusicEngine()
        var willPlay = 0
        let player = MusicCardPlayer(engine: engine, isOffline: { false }, willPlay: { willPlay += 1 })

        player.toggle(key: "A", url: Self.songA)
        XCTAssertEqual(player.phase(for: "A"), .loading)
        XCTAssertEqual(willPlay, 1)
        engine.onTime?(1, 0, 200)
        XCTAssertEqual(player.phase(for: "A"), .playing)
        XCTAssertEqual(player.phase(for: "B"), .idle)

        player.toggle(key: "A", url: Self.songA)
        XCTAssertEqual(player.phase(for: "A"), .paused)
        player.toggle(key: "A", url: Self.songA)
        XCTAssertEqual(player.phase(for: "A"), .playing)
        XCTAssertEqual(engine.log.filter { $0.hasPrefix("load") }.count, 1)     // 继续不重新加载

        player.seek(fraction: 0.5)
        XCTAssertEqual(engine.log.last, "seek 100")
        player.seek(fraction: 1.7)
        XCTAssertEqual(engine.log.last, "seek 200")

        player.toggle(key: "B", url: Self.songB)
        XCTAssertEqual(player.phase(for: "A"), .idle)
        XCTAssertEqual(player.currentKey, "B")
        XCTAssertEqual(Array(engine.log.suffix(3)), ["stop", "load b.mp3", "play"])

        engine.onTime?(2, 200, 200)
        engine.onEnd?(2)
        XCTAssertEqual(player.phase(for: "B"), .idle)
        XCTAssertNil(player.currentKey)
        XCTAssertEqual(engine.log.last, "stop")                                 // 播完释放引擎（R5 U4）
        XCTAssertFalse(player.isActive)
    }

    /// 旧音轨的迟到失败 / 结束不影响新音轨（R5 U3）
    @MainActor
    func testMusicPlayerIgnoresStaleGenerationEvents() {
        let engine = FakeMusicEngine()
        let player = MusicCardPlayer(engine: engine, isOffline: { false }, willPlay: {})
        player.toggle(key: "A", url: Self.songA)          // gen 1
        player.toggle(key: "B", url: Self.songB)          // gen 2
        engine.onFail?(1)
        engine.onEnd?(1)
        XCTAssertEqual(player.phase(for: "B"), .loading)
        engine.onFail?(2)
        XCTAssertEqual(player.phase(for: "B"), .failed)
        engine.onEnd?(2)                                   // 失败后迟到的结束不冲掉「播放失败」（终审）
        XCTAssertEqual(player.phase(for: "B"), .failed)
        player.toggle(key: "B", url: Self.songB)           // 失败后再点 = 重新加载
        XCTAssertEqual(player.phase(for: "B"), .loading)
    }

    /// 本地模式：离线不加载；播放中切到本地模式立即停（R5 U1）；stop(key:) 只停对应的那首（R5 U2）
    @MainActor
    func testMusicPlayerOfflineAndKeyedStop() {
        let engine = FakeMusicEngine()
        var offline = true
        let player = MusicCardPlayer(engine: engine, isOffline: { offline }, willPlay: {})
        player.toggle(key: "A", url: Self.songA)
        XCTAssertEqual(player.phase(for: "A"), .idle)
        XCTAssertTrue(engine.log.isEmpty)

        offline = false
        player.toggle(key: "A", url: Self.songA)
        XCTAssertTrue(player.isActive)
        player.stop(key: "B")
        XCTAssertEqual(player.currentKey, "A")
        offline = true
        player.recheckOffline()
        XCTAssertNil(player.currentKey)
        XCTAssertEqual(engine.log.last, "stop")

        offline = false
        player.toggle(key: "A", url: Self.songA)
        player.stop(key: "A")
        XCTAssertNil(player.currentKey)
    }

    /// 语音条开播前先让出（停音乐、停听书）——真实调用，不是常量（R5 G1）
    @MainActor
    func testVoicePlayerYieldsBeforePlaying() {
        let voice = VoiceMessagePlayer()
        var yielded = 0
        voice.beforePlay = { yielded += 1 }
        voice.toggle(url: URL(fileURLWithPath: "/nonexistent/voice.m4a"), id: "v1")
        XCTAssertEqual(yielded, 1)
    }

    /// 封面：本地模式 / 非公网不拉；同一张只拉一次；拉回来时已离线则丢弃（R5 U8）
    @MainActor
    func testMusicCoverLoader() async {
        var offline = false
        var fetched: [URL] = []
        let loader = MusicCoverLoader(isOffline: { offline }, fetch: { url in fetched.append(url); return Data([1, 2, 3]) })
        let cover = URL(string: "https://x.com/c.jpg")!
        let result1 = await loader.load(cover)
        XCTAssertEqual(result1, Data([1, 2, 3]))
        _ = await loader.load(cover)
        XCTAssertEqual(fetched.count, 1)
        let privateCover = await loader.load(URL(string: "https://10.0.0.1/c.jpg")!)
        XCTAssertNil(privateCover)
        offline = true
        let offlineCover = await loader.load(URL(string: "https://x.com/d.jpg")!)
        XCTAssertNil(offlineCover)
        XCTAssertNil(loader.cached(cover))                     // 离线时连缓存也不给
        XCTAssertEqual(fetched.count, 1)

        let late = MusicCoverLoader(isOffline: { offline }, fetch: { _ in offline = true; return Data([9]) })
        offline = false
        let lateResult = await late.load(URL(string: "https://x.com/e.jpg")!)
        XCTAssertNil(lateResult)
    }

    func testMusicTimeText() {
        XCTAssertEqual(MusicTime.text(0), "0:00")
        XCTAssertEqual(MusicTime.text(65.9), "1:05")
        XCTAssertEqual(MusicTime.text(.nan), "0:00")
        XCTAssertEqual(MusicTime.text(3725), "62:05")
    }

    func testPromptGuideCoversChartAndMusic() {
        let text = ChatCardPromptGuide.text
        for s in ["card-chart", "card-music", "\"type\":\"bar\"", "pie", "图表 g-", "音乐 m-", "直链", "没有 roll_dice", "没出现过"] {
            XCTAssertTrue(text.contains(s), s)
        }
    }

    // MARK: 音乐卡重做（research §10.6）

    @MainActor
    func testMusicPlayerVolumeClampsAndReachesEngine() {
        let engine = FakeMusicEngine()
        let player = MusicCardPlayer(engine: engine, isOffline: { false }, willPlay: {})
        XCTAssertEqual(player.volume, 1)
        player.setVolume(0.4)
        XCTAssertEqual(player.volume, 0.4, accuracy: 1e-9)
        XCTAssertEqual(engine.log.last, "volume 0.4")
        player.setVolume(1.8)
        XCTAssertEqual(player.volume, 1)
        player.setVolume(-1)
        XCTAssertEqual(player.volume, 0)
    }

    func testMusicWaveHeightsAreStablePerSong() {
        let a = MusicWave.heights(seed: "https://x.com/a.mp3")
        XCTAssertEqual(a.count, MusicWave.count)
        XCTAssertEqual(a, MusicWave.heights(seed: "https://x.com/a.mp3"))
        XCTAssertNotEqual(a, MusicWave.heights(seed: "https://x.com/b.mp3"))
        XCTAssertTrue(a.allSatisfy { (0.25...1).contains($0) })
    }

    /// 波形 → 音量条：柱间隙收拢、高度统一，最后并成一条（§10.6）
    func testMusicWaveMorphsIntoVolumeBar() {
        let h = MusicWave.heights(seed: "s")
        let size = CGSize(width: 280, height: 40)
        let wave = MusicWave.bars(in: size, heights: h, volumeMorph: 0)
        XCTAssertEqual(wave.count, MusicWave.count)
        XCTAssertEqual(wave[1].minX - wave[0].maxX, MusicWave.gap, accuracy: 1e-6)
        XCTAssertEqual(wave.last!.maxX, 280, accuracy: 1e-6)
        XCTAssertTrue(wave.allSatisfy { abs($0.midY - 20) < 1e-9 && $0.height >= 4 })
        let bar = MusicWave.bars(in: size, heights: h, volumeMorph: 1)
        XCTAssertEqual(bar[1].minX, bar[0].maxX, accuracy: 1e-6)
        XCTAssertTrue(bar.allSatisfy { abs($0.height - MusicWave.volumeBarHeight) < 1e-6 })
    }

    /// 播放 ↔ 暂停：同一个图形插值（§10.6）
    func testPlayPauseShapeInterpolates() {
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let play = PlayPauseShape(morph: 0).path(in: rect)
        let pause = PlayPauseShape(morph: 1).path(in: rect)
        XCTAssertTrue(play.contains(CGPoint(x: 16, y: 16)))      // 三角形中间是实的
        XCTAssertFalse(pause.contains(CGPoint(x: 16, y: 16)))    // 两条竖杠中间是空的
        XCTAssertTrue(pause.contains(CGPoint(x: 11, y: 16)))
        XCTAssertEqual(PlayPauseShape(morph: 0.3).animatableData, 0.3)
    }

    // MARK: 内置曲「慢潮」（粟粟 09-26：小样里的音乐也加进去）

    func testBuiltinTrackParsing() {
        XCTAssertEqual(BuiltinTrack.parse("builtin:slowtide"), .slowTide)
        XCTAssertEqual(BuiltinTrack.parse(" BUILTIN:SlowTide "), .slowTide)
        XCTAssertNil(BuiltinTrack.parse("builtin:nope"))
        XCTAssertNil(BuiltinTrack.parse("https://x.com/a.mp3"))
        XCTAssertNil(BuiltinTrack.parse(nil))
        guard case .music(let m)? = ChatCard.parse(language: "card-music", code: #"{"title":"慢潮","url":"builtin:slowtide"}"#) else { return XCTFail() }
        XCTAssertEqual(m.builtinTrack, .slowTide)
        XCTAssertNil(m.playableURL)                                // 不走网络
    }

    func testSlowTideRendersDeterministically() {
        let a = SlowTide.render(sampleRate: 4000)
        XCTAssertEqual(a.count, Int(SlowTide.duration) * 4000)
        XCTAssertEqual(a, SlowTide.render(sampleRate: 4000))
        XCTAssertLessThanOrEqual(a.map(abs).max() ?? 0, 1)
        let rms = (a.reduce(0) { $0 + Double($1 * $1) } / Double(a.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.01)                             // 真有声音
        let intro = a[0..<(8 * 2 * 4000)], full = a[(10 * 2 * 4000)..<(20 * 2 * 4000)]
        func energy<S: Collection>(_ x: S) -> Double where S.Element == Float { x.reduce(0) { $0 + Double($1 * $1) } / Double(x.count) }
        XCTAssertGreaterThan(energy(full), energy(intro))            // 前奏轻、主段满
    }

    func testWAVHeader() {
        let data = WAV.encode([0, 0.5, -0.5, 1], sampleRate: 8000)
        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        let rate = data[24..<28].enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        XCTAssertEqual(rate, 8000)
    }

    /// 本地文件不受本地模式限制（内置曲不联网）
    @MainActor
    func testLocalFilePlaysOffline() {
        let engine = FakeMusicEngine()
        let player = MusicCardPlayer(engine: engine, isOffline: { true }, willPlay: {})
        player.toggle(key: "B", url: URL(fileURLWithPath: "/tmp/slowtide.wav"))
        XCTAssertEqual(player.currentKey, "B")
        player.recheckOffline()
        XCTAssertEqual(player.currentKey, "B")
        player.toggle(key: "N", url: Self.songA)                    // 网络音频照样拦
        XCTAssertNil(player.currentKey)
    }

    func testPromptGuideMentionsBuiltinTrack() {
        XCTAssertTrue(ChatCardPromptGuide.text.contains("builtin:slowtide"))
    }

    // MARK: 音乐卡重做终审修复

    /// 内置曲走播放器：合成中算加载中；合成完时若期间被别的歌顶掉 / 变旧版本停掉，就不播（终审 I2）
    @MainActor
    func testBuiltinPlaybackRaces() async {
        let engine = FakeMusicEngine()
        let file = URL(fileURLWithPath: "/tmp/slowtide.wav")
        let player = MusicCardPlayer(engine: engine, isOffline: { true }, willPlay: {}, builtinFile: { _ in file })

        player.toggleBuiltin(key: "A", track: .slowTide)
        XCTAssertEqual(player.phase(for: "A"), .loading)
        XCTAssertTrue(player.isPreparing(key: "A"))
        await player.builtinTask?.value
        XCTAssertEqual(player.currentKey, "A")                     // 本地模式也能放
        XCTAssertFalse(player.isPreparing(key: "A"))

        player.stop()
        player.toggleBuiltin(key: "A", track: .slowTide)
        player.toggle(key: "B", url: URL(fileURLWithPath: "/tmp/other.wav"))   // 合成期间换歌
        await player.builtinTask?.value
        XCTAssertEqual(player.currentKey, "B")

        player.stop()
        player.toggleBuiltin(key: "A", track: .slowTide)
        player.stop(key: "A")                                      // 合成期间变旧版本
        await player.builtinTask?.value
        XCTAssertNil(player.currentKey)
        XCTAssertEqual(player.phase(for: "A"), .idle)
    }

    @MainActor
    func testBuiltinPlaybackFailureShows() async {
        let player = MusicCardPlayer(engine: FakeMusicEngine(), isOffline: { false }, willPlay: {}, builtinFile: { _ in nil })
        player.toggleBuiltin(key: "A", track: .slowTide)
        await player.builtinTask?.value
        XCTAssertEqual(player.phase(for: "A"), .failed)             // 合成失败要有反馈（终审 minor 4）
    }

    /// 同一首同时首播只合成一次；文件名带谱的版本号（终审 minor 5 / 6）
    func testBuiltinMusicRendersOnceAndVersionsFile() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let counter = RenderCounter()
        async let a = BuiltinMusic.fileURL(for: .slowTide, directory: dir, render: { _ in counter.bump(); return [0, 0.1] })
        async let b = BuiltinMusic.fileURL(for: .slowTide, directory: dir, render: { _ in counter.bump(); return [0, 0.1] })
        let (ua, ub) = await (a, b)
        XCTAssertEqual(ua, ub)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(ua?.lastPathComponent, "slowtide-v\(SlowTide.version).wav")
        try? FileManager.default.removeItem(at: dir)
    }

    final class RenderCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// 内置曲卡不信模型写的标题 / 歌手：一律显示「慢潮 · 内置曲」（终审 I4）
    func testBuiltinCardShowsItsRealIdentity() {
        guard case .music(let m)? = ChatCard.parse(language: "card-music", code: #"{"title":"晴天","artist":"周杰伦","url":"builtin:slowtide"}"#) else { return XCTFail() }
        XCTAssertEqual(m.displayTitle, "慢潮")
        XCTAssertEqual(m.displaySubtitle, "内置曲 · 本地合成")
        guard case .music(let n)? = ChatCard.parse(language: "card-music", code: #"{"title":"晴天","artist":"周杰伦"}"#) else { return XCTFail() }
        XCTAssertEqual(n.displayTitle, "晴天")
        XCTAssertEqual(n.displaySubtitle, "周杰伦")
        XCTAssertTrue(ChatCardPromptGuide.text.contains("不要用内置曲代替"))
    }

    /// 时间浮标夹在波形范围内（终审 minor 3）
    func testScrubTipCenterClamps() {
        XCTAssertEqual(MusicScrub.tipCenter(progress: 0, width: 300, tipWidth: 40), 20)
        XCTAssertEqual(MusicScrub.tipCenter(progress: 1, width: 300, tipWidth: 40), 280)
        XCTAssertEqual(MusicScrub.tipCenter(progress: 0.5, width: 300, tipWidth: 40), 150)
    }

    // MARK: 模型漏写 card- 前缀（粟粟 09-26 真机：```music 没变卡片）

    func testShortLanguageAliasesParseOnlyValidCards() {
        let music = #"{"id":"m-c7a1","title":"慢潮","artist":"小克","url":"builtin:slowtide"}"#
        XCTAssertNotNil(ChatCard.parse(language: "music", code: music))
        XCTAssertNotNil(ChatCard.parse(language: "Music", code: music))
        XCTAssertEqual(ChatCardRegistry.kind(language: "music", code: music, streaming: false), .card(ChatCard.parse(language: "card-music", code: music)!))
        // 解析不了的「chart」/「todo」代码仍是普通代码块，流式中也不给占位
        XCTAssertNil(ChatCardRegistry.kind(language: "chart", code: "new Chart(ctx, {type: 'bar'})", streaming: false))
        XCTAssertNil(ChatCardRegistry.kind(language: "todo", code: "- [ ] 买牛奶", streaming: true))
        XCTAssertNil(ChatCardRegistry.kind(language: "python", code: music, streaming: false))
        // 版本索引也认得出
        XCTAssertEqual(ChatCardExtractor.cards(in: "放首歌\n\n```music\n\(music)\n```\n").count, 1)
    }

    func testPromptGuideAsksForFullFenceLanguage() {
        XCTAssertTrue(ChatCardPromptGuide.text.contains("语言名要写全"))
    }

    // MARK: 波形跟着鼓点弹（粟粟 09-26 真机：小样里有，app 里没了）

    func testWaveBounceNearPlayheadOnly() {
        let h = [Double](repeating: 0.5, count: MusicWave.count)
        XCTAssertEqual(MusicWave.bounced(h, progress: 0.5, level: 0), h)
        let b = MusicWave.bounced(h, progress: 0.5, level: 1)
        XCTAssertGreaterThan(b[MusicWave.count / 2], 0.5)            // 播放头处变高
        XCTAssertEqual(b[0], 0.5)                                     // 远处不动
        XCTAssertTrue(b.allSatisfy { $0 <= 1.35 })
    }

    /// 内置曲的音量起伏：按每秒 60 格算 RMS，归一到 0...1
    func testLevelsFromWAV() {
        let sr = 600
        var samples = [Float](repeating: 0, count: sr * 2)            // 前 1 秒静音，后 1 秒有声
        for i in sr..<(2 * sr) { samples[i] = i % 2 == 0 ? 0.5 : -0.5 }
        let levels = BuiltinMusic.levels(fromWAV: WAV.encode(samples, sampleRate: sr), perSecond: 60)
        XCTAssertEqual(levels.count, 120)
        XCTAssertEqual(levels[10], 0, accuracy: 1e-6)
        XCTAssertEqual(levels[100], 1, accuracy: 1e-3)
        XCTAssertEqual(MusicWave.level(levels, perSecond: 60, at: 1.5), levels[90])
        XCTAssertEqual(MusicWave.level(levels, perSecond: 60, at: 99), 0)   // 越界安全
    }

    /// 播放时间在两次回调之间按真实时间外推（波形每帧跟得上鼓点）
    @MainActor
    func testPlayerEstimatesTimeBetweenTicks() {
        let engine = FakeMusicEngine()
        var clock = Date(timeIntervalSince1970: 1000)
        let player = MusicCardPlayer(engine: engine, isOffline: { false }, willPlay: {}, now: { clock })
        player.toggle(key: "A", url: Self.songA)
        engine.onTime?(1, 10, 96)
        clock = clock.addingTimeInterval(0.2)
        XCTAssertEqual(player.estimatedTime(at: clock), 10.2, accuracy: 1e-6)          // Date 自身精度约 1e-7
        player.toggle(key: "A", url: Self.songA)                        // 暂停
        XCTAssertEqual(player.estimatedTime(at: clock.addingTimeInterval(5)), 10, accuracy: 1e-6)
    }

    // MARK: 外链歌曲也跟着鼓点弹（实时音量）

    func testLevelNormalizerAdaptsToLoudness() {
        var n = LevelNormalizer()
        XCTAssertEqual(n.push(0), 0)
        let quiet = (0..<30).map { _ in n.push(0.05) }.last!
        XCTAssertGreaterThan(quiet, 0.9)                            // 安静的歌也能弹满
        var m = LevelNormalizer()
        _ = m.push(0.5)
        XCTAssertLessThan(m.push(0.1), 0.3)                           // 比峰值小很多 → 低
        XCTAssertTrue((0..<100).map { _ in m.push(0.4) }.allSatisfy { $0 <= 1 })
    }

    func testRMS() {
        XCTAssertEqual(MusicMeter.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(MusicMeter.rms([]), 0)
    }

    /// 取音量：内置曲查表；外链歌用引擎的实时音量；不在放 = 0
    @MainActor
    func testPlayerLevelSources() {
        let engine = FakeMusicEngine()
        let player = MusicCardPlayer(engine: engine, isOffline: { false }, willPlay: {})
        engine.liveLevel = 0.7
        XCTAssertEqual(player.level(at: .now), 0)                      // 没在放
        player.toggle(key: "A", url: Self.songA)
        engine.onTime?(1, 1, 96)
        XCTAssertEqual(player.level(at: .now), 0.7, accuracy: 1e-6)
        player.toggle(key: "A", url: Self.songA)                        // 暂停
        XCTAssertEqual(player.level(at: .now), 0)
    }

    // MARK: 小毛病修复（粟粟 09-27）

    /// 骰子掷不了时说清楚为什么（以前「掷」点了没反应，§8.6-4）
    func testDiceRollProblemExplains() {
        XCTAssertNil(DiceRoller.problem(DiceCard(id: "d-1", title: "", dice: "2d6+1", options: nil, result: nil)))
        XCTAssertNil(DiceRoller.problem(DiceCard(id: "d-1", title: "", dice: nil, options: ["a", "b"], result: nil)))
        XCTAssertEqual(DiceRoller.problem(DiceCard(id: "d-1", title: "", dice: "3d7000", options: nil, result: nil)),
                       "骰子写法看不懂：3d7000（例：2d6+1、d20）")
        XCTAssertEqual(DiceRoller.problem(DiceCard(id: "d-1", title: "", dice: nil, options: [], result: nil)), "没有可抽的选项")
    }

    /// 到点消息被拒（预算等）：隔 10 分钟才再试、不反复弹；连败 3 次放弃（§8.6-3）
    @MainActor
    func testTimerDeliveryFailureBacksOffThenGivesUp() {
        withSuite { suite in
            var now = Date(timeIntervalSince1970: 80_000)
            let key = TimerCardStore.key(conversationId: "A", nodeId: "n1", cardId: "c-1")
            let store = makeTimerStore({ now }, FakeNotifier(), suite: suite)
            store.start(key: key, conversationId: "A", nodeId: "n1", card: noodle)
            now = now.addingTimeInterval(200)
            store.checkExpired()

            var event = store.claim(conversationId: "A")!
            XCTAssertFalse(store.deliveryFailed(event.id))            // 第 1 次失败：留着
            XCTAssertNil(store.claim(conversationId: "A"))            // 10 分钟内不再认领
            now = now.addingTimeInterval(601)
            event = store.claim(conversationId: "A")!
            XCTAssertFalse(store.deliveryFailed(event.id))            // 第 2 次
            now = now.addingTimeInterval(601)
            event = store.claim(conversationId: "A")!
            XCTAssertTrue(store.deliveryFailed(event.id))             // 第 3 次：放弃
            XCTAssertTrue(store.outbox.isEmpty)

            // 旧版本存下来的事件没有新字段也能读
            let old = #"[{"id":"e","conversationId":"A","nodeId":"n","text":"t"}]"#
            XCTAssertEqual(try? JSONDecoder().decode([TimerFinishedEvent].self, from: Data(old.utf8)).count, 1)
        }
    }

    // MARK: 音乐切对话继续放 + 顶部玻璃胶囊（粟粟 09-27）

    @MainActor
    func testMusicPlayerRemembersOriginAndPauseToggle() {
        let engine = FakeMusicEngine()
        let player = MusicCardPlayer(engine: engine, isOffline: { false }, willPlay: {})
        let origin = MusicOrigin(conversationId: "c1", nodeId: "n1", title: "晴天")
        player.toggle(key: "A", url: Self.songA, origin: origin)
        XCTAssertEqual(player.origin, origin)
        engine.onTime?(1, 1, 96)
        player.togglePauseCurrent()
        XCTAssertEqual(player.phase(for: "A"), .paused)
        player.togglePauseCurrent()
        XCTAssertEqual(player.phase(for: "A"), .playing)
        player.stop()
        XCTAssertNil(player.origin)
        player.togglePauseCurrent()                                  // 没在放：无事发生
        XCTAssertNil(player.currentKey)
    }

    func testNowPlayingCapsuleShowsOnlyInOtherConversations() {
        let origin = MusicOrigin(conversationId: "c1", nodeId: "n1", title: "晴天")
        XCTAssertTrue(MusicNowPlaying.shouldShow(origin: origin, isActive: true, currentConversationId: "c2"))
        XCTAssertTrue(MusicNowPlaying.shouldShow(origin: origin, isActive: true, currentConversationId: nil))
        XCTAssertFalse(MusicNowPlaying.shouldShow(origin: origin, isActive: true, currentConversationId: "c1"))
        XCTAssertFalse(MusicNowPlaying.shouldShow(origin: origin, isActive: false, currentConversationId: "c2"))
        XCTAssertFalse(MusicNowPlaying.shouldShow(origin: nil, isActive: true, currentConversationId: "c2"))
    }
}
