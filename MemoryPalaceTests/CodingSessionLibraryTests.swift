#if os(macOS)
import XCTest
import SwiftData
@testable import 记忆花园

/// W-N N1-a：注入实例的 Library（刷新 / 选中 / 墓碑）、keyset 分页、用户状态、续跑脚本、删除路径。
/// 全部在 tmp：fixture 拷一份当假 HOME，索引与用户状态也在 tmp。
@MainActor
final class CodingSessionLibraryTests: XCTestCase {
    private var dir: URL!
    private var home: URL { dir.appendingPathComponent("home") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures, to: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func adapters() -> [CodingSessionAdapter] {
        [
            ClaudeCodeAdapter(root: home.appendingPathComponent("claude/projects")),
            CodexAdapter(sessionsDir: home.appendingPathComponent("codex/sessions"),
                         archivedDir: home.appendingPathComponent("codex/archived_sessions"),
                         stateDB: home.appendingPathComponent("codex/state_5.sqlite")),
            KimiCodeAdapter(root: home.appendingPathComponent("kimi/sessions"), indexPath: home.appendingPathComponent("kimi/session_index.jsonl")),
        ]
    }

    private func makeLibrary() -> (CodingSessionLibrary, CodingSessionState) {
        let state = CodingSessionState(url: dir.appendingPathComponent("state.json"))
        let library = CodingSessionLibrary(indexURL: dir.appendingPathComponent("index.sqlite"), adapters: adapters(), state: state)
        return (library, state)
    }

    /// plan-mac-hang-probe §2：监听一批一批送来，窗口内只刷一次（正在跑的 CC 会话每几秒写一次，逐批刷会占满主线程）
    func testIncrementalRefreshIsCoalesced() async throws {
        let (library, _) = makeLibrary()
        await library.refresh()?.value
        let before = library.incrementalFlushCount
        for i in 0..<5 { library._testApplyIncremental(changedPaths: ["/tmp/\(i).jsonl"]) }
        try await Task.sleep(nanoseconds: UInt64((CodingSessionLibrary.incrementalInterval + 0.6) * 1_000_000_000))
        XCTAssertEqual(library.incrementalFlushCount - before, 1, "5 批变化合并成一次刷新")
        XCTAssertEqual(library.totalSessions, 9, "合并后照样刷新")
    }

    func testRefreshAndSelectOnInjectedInstance() async throws {
        let (library, _) = makeLibrary()
        await library.refresh()?.value
        XCTAssertEqual(library.totalSessions, 9)
        XCTAssertFalse(library.isScanning)

        library.select("claude-code:11111111-aaaa-bbbb-cccc-000000000001")
        for _ in 0..<60 {
            if case .loaded = library.detail { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .loaded(let box) = library.detail else { return XCTFail("详情没落地：\(library.detail)") }
        XCTAssertEqual(box.transcript.meta.title, "QR login revamp")
    }

    /// 菜单栏快看（research-magpie §2.6）：「最近几分钟有写入」= 在外面终端里跑着的会话；点了 = 激活 Code 组并打开那条
    func testRecentlyActiveAndOpenSessionForMenuBar() async throws {
        let (library, _) = makeLibrary()
        await library.refresh()?.value
        let all = library.recentlyActive(now: Date(timeIntervalSince1970: 4_000_000_000), within: 4_000_000_000, limit: 50)
        XCTAssertEqual(all.count, 9)
        let latest = try XCTUnwrap(all.first)
        XCTAssertEqual(all.map(\.updatedAt), all.map(\.updatedAt).sorted(by: >), "新到旧")
        let justAfter = Date(timeIntervalSince1970: Double(latest.updatedAt) / 1000 + 60)
        let recent = library.recentlyActive(now: justAfter, within: 180)
        XCTAssertTrue(recent.contains { $0.key == latest.key })
        XCTAssertTrue(recent.allSatisfy { Double($0.updatedAt) / 1000 >= justAfter.timeIntervalSince1970 - 180 })
        XCTAssertTrue(library.recentlyActive(now: justAfter.addingTimeInterval(3600), within: 180).isEmpty)

        XCTAssertFalse(library.isActive)
        XCTAssertTrue(library.openSession(key: latest.key))
        XCTAssertTrue(library.isActive)
        XCTAssertEqual(library.selectedKey, latest.key)
        XCTAssertFalse(library.openSession(key: "claude-code:no-such-session"))
    }

    private func loadedLibrary() async throws -> CodingSessionLibrary {
        let (library, _) = makeLibrary()
        await library.refresh()?.value
        library.select("claude-code:11111111-aaaa-bbbb-cccc-000000000001")
        for _ in 0..<100 {
            if case .loaded = library.detail { return library }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Fixture did not load")
        return library
    }

    func testSameSessionRefreshKeepsLoadedBranchUntilReplacementArrives() async throws {
        let library = try await loadedLibrary()
        let revision = library.detailRevision
        guard case .loaded(let before) = library.detail else { return XCTFail("not loaded") }
        library.reloadDetail()
        XCTAssertTrue(library.isRefreshingDetail)
        guard case .loaded(let during) = library.detail else { return XCTFail("Refresh removed the scroll host") }
        XCTAssertEqual(during, before)
        for _ in 0..<100 {
            if !library.isRefreshingDetail { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(library.isRefreshingDetail)
        XCTAssertGreaterThan(library.detailRevision, revision)
        XCTAssertNil(library.detailRefreshError)
        guard case .loaded = library.detail else { return XCTFail("Refresh did not replace in place") }
    }

    func testNewReplyReplacesDataWithoutEnteringLoading() async throws {
        let library = try await loadedLibrary()
        guard case .loaded(let before) = library.detail else { return XCTFail("not loaded") }
        let row: [String: Any] = [
            "type": "assistant", "uuid": "refresh-test-reply", "parentUuid": "s-0001",
            "sessionId": before.transcript.meta.nativeId, "timestamp": "2026-08-01T10:03:00.000Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": "new reply after refresh"]]]
        ]
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: before.transcript.meta.filePath))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8) + JSONSerialization.data(withJSONObject: row) + Data("\n".utf8))
        library.reloadDetail()
        guard case .loaded = library.detail else { return XCTFail("Append unmounted reading content") }
        for _ in 0..<100 {
            if !library.isRefreshingDetail { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .loaded(let after) = library.detail else { return XCTFail("not loaded") }
        XCTAssertTrue(after.transcript.mainline.contains { $0.text == "new reply after refresh" })
        XCTAssertGreaterThan(after.transcript.mainline.count, before.transcript.mainline.count)
    }

    func testFileAppendAutomaticallyReachesVisibleTranscript() async throws {
        let library = try await loadedLibrary()
        guard case .loaded(let before) = library.detail else { return XCTFail("not loaded") }
        let row: [String: Any] = [
            "type": "assistant", "uuid": "refresh-test-reply", "parentUuid": "s-0001",
            "sessionId": before.transcript.meta.nativeId, "timestamp": "2026-08-01T10:03:00.000Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": "new reply after refresh"]]]
        ]
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: before.transcript.meta.filePath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8) + JSONSerialization.data(withJSONObject: row) + Data("\n".utf8))
        try handle.close()
        let start = Date()
        guard case .loaded = library.detail else { return XCTFail("Append unmounted reading content") }
        for _ in 0..<300 {
            if case .loaded(let current) = library.detail, current.transcript.mainline.count > before.transcript.mainline.count { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("[sync-probe] append-to-detail seconds=\(Date().timeIntervalSince(start))")
        guard case .loaded(let after) = library.detail else { return XCTFail("not loaded") }
        XCTAssertTrue(after.transcript.mainline.contains { $0.text == "new reply after refresh" })
        XCTAssertGreaterThan(after.transcript.mainline.count, before.transcript.mainline.count)
    }

    func testRefreshFailureRetainsReadingContentAndSurfacesError() async throws {
        let library = try await loadedLibrary()
        guard case .loaded(let before) = library.detail else { return XCTFail("not loaded") }
        try FileManager.default.removeItem(atPath: before.transcript.meta.filePath)
        library.reloadDetail()
        for _ in 0..<100 {
            if !library.isRefreshingDetail { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .loaded(let after) = library.detail else { return XCTFail("Failure removed the scroll host") }
        XCTAssertEqual(after, before)
        XCTAssertNotNil(library.detailRefreshError)
    }

    func testSelectionChangeDoesNotKeepPreviousTranscriptOrAcceptLateRefresh() async throws {
        let library = try await loadedLibrary()
        library.reloadDetail()
        library.select("missing-session")
        try await Task.sleep(for: .milliseconds(150))
        guard case .failed(let key, _, _) = library.detail else { return XCTFail("Old result replaced new selection") }
        XCTAssertEqual(key, "missing-session")
        XCTAssertFalse(library.isRefreshingDetail)
        XCTAssertNil(library.detailRefreshError)
    }

    func testMacCCBridgeFinalEditDoesNotNavigateAwayFromHistory() throws {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let conversation = Conversation(id: "cc-scroll", title: "fixture", createTime: Date(),
            updateTime: Date(), currentNodeId: "cc-node", profileId: "test-floor")
        let node = MessageNode(id: "cc-node", role: "assistant", content: "old", contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [], conversationId: conversation.id,
            profileId: conversation.profileId)
        node.ccMessageId = "cc-message"
        context.insert(conversation)
        context.insert(node)
        let model = ConversationViewModel()
        model.selectedConversation = conversation
        model.currentPath = [node]
        model.isViewAtBottom = false
        model.applyCCEdit(chatId: conversation.id, ccMessageId: "cc-message", content: "final", context: context)
        XCTAssertEqual(node.content, "final")
        XCTAssertTrue(node.ccEdited)
        XCTAssertNil(model.scrollToNodeId)
        model.isViewAtBottom = true
        model.applyCCEdit(chatId: conversation.id, ccMessageId: "cc-message", content: "new final", context: context)
        XCTAssertEqual(model.macCCTailRevision, 1)
        XCTAssertNil(model.scrollToNodeId)
        model.scrollToNodeId = nil
        model.applyCCEdit(chatId: conversation.id, ccMessageId: "cc-message", content: "stream", streaming: true, context: context)
        XCTAssertNil(model.scrollToNodeId)
        let older = MessageNode(id: "older-node", role: "assistant", content: "older", contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [], conversationId: conversation.id,
            profileId: conversation.profileId)
        older.ccMessageId = "older-message"
        context.insert(older)
        model.currentPath = [older, node]
        model.applyCCEdit(chatId: conversation.id, ccMessageId: "older-message", content: "late edit", context: context)
        XCTAssertNil(model.scrollToNodeId, "Following the tail must not navigate to an older edited reply")
        XCTAssertEqual(model.macCCTailRevision, 1)
        model.scrollToNodeId = "explicit-search-target"
        model.applyCCEdit(chatId: conversation.id, ccMessageId: "cc-message", content: "final during navigation", context: context)
        XCTAssertEqual(model.scrollToNodeId, "explicit-search-target")
        XCTAssertEqual(model.macCCTailRevision, 1)
    }

    func testMacScrollIntentOnlyChangesFromUserOrExplicitNavigation() {
        var policy = MacCodingScrollPolicy()
        XCTAssertFalse(policy.followsTail)
        policy.observe(distanceToBottom: 0, source: .layout)
        XCTAssertFalse(policy.followsTail)
        policy.observe(distanceToBottom: 0, source: .user)
        XCTAssertTrue(policy.followsTail)
        XCTAssertFalse(policy.shouldFollow(isUserScrolling: true))
        XCTAssertTrue(policy.shouldFollow(isUserScrolling: false))
        policy.observe(distanceToBottom: 600, source: .layout)
        XCTAssertTrue(policy.followsTail, "A newly appended reply must not clear tail following")
        policy.observe(distanceToBottom: 200, source: .user)
        XCTAssertFalse(policy.followsTail)
        policy.observe(distanceToBottom: 0, source: .programmatic)
        XCTAssertFalse(policy.followsTail, "Programmatic movement must not steal reading intent")
        policy.observe(distanceToBottom: 0, source: .user)
        policy.explicitNavigation()
        XCTAssertFalse(policy.followsTail)
        policy.follow()
        XCTAssertTrue(policy.followsTail, "打开即回底 / 回底钮显式开跟随（plan-mac-code-mode-gaps §4-5）")
        policy.observe(distanceToBottom: 900, source: .layout)
        XCTAssertTrue(policy.followsTail, "开跟随后内容变高不掉跟随")
    }

    func testTombstonedSessionIsNotRevived() async throws {
        let (library, state) = makeLibrary()
        let wire = home.appendingPathComponent("kimi/sessions/wd_wakefx_abc123/session_88888888-aaaa-bbbb-cccc-000000000008/agents/main/wire.jsonl")
        state.bury(path: wire.path, key: "kimi:session_88888888-aaaa-bbbb-cccc-000000000008")
        await library.refresh()?.value
        XCTAssertEqual(library.totalSessions, 8)
    }

    func testKeysetPagingIsDisjointAndComplete() async throws {
        let (library, _) = makeLibrary()
        await library.refresh()?.value
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        var seen: [String] = []
        var cursor: CodingSessionMeta?
        while true {
            let page = try index.listSessions(projectPath: nil, limit: 4, after: cursor)
            seen.append(contentsOf: page.map(\.key))
            guard page.count == 4, let last = page.last else { break }
            cursor = last
        }
        XCTAssertEqual(seen.count, 9)
        XCTAssertEqual(Set(seen).count, 9, "翻页不重")
        let all = try index.listSessions(projectPath: nil, limit: 100)
        XCTAssertEqual(seen, all.map(\.key), "顺序与一次取全相同")
    }

    // MARK: - 用户状态

    func testStateRoundTrip() {
        let url = dir.appendingPathComponent("state.json")
        let state = CodingSessionState(url: url)
        state.toggleFavorite("a")
        state.togglePin("b")
        state.toggleFavorite("c")
        state.toggleFavorite("c")
        state.bury(path: "/p", key: "a")
        state.setTerminal("iterm")
        let reloaded = CodingSessionState(url: url)
        XCTAssertEqual(reloaded.snapshot, state.snapshot)
        XCTAssertFalse(reloaded.isFavorite("a"), "删掉的会话顺手出收藏")
        XCTAssertTrue(reloaded.isPinned("b"))
        XCTAssertTrue(reloaded.tombstoneCheck("/p", "x"))
        XCTAssertTrue(reloaded.tombstoneCheck("/other", "a"))
        XCTAssertEqual(reloaded.snapshot.terminal, "iterm")
    }

    // MARK: - 续跑脚本

    private func meta(_ agent: CodingAgent, id: String, project: String) -> CodingSessionMeta {
        CodingSessionMeta(key: "\(agent.rawValue):\(id)", nativeId: id, agent: agent, title: "t", projectPath: project,
                          projectName: "p", filePath: "/f", createdAt: 0, updatedAt: 0, messageCount: 0, sizeBytes: 0,
                          gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil)
    }

    func testResumeScript() throws {
        let existing = dir.path
        let claude = try XCTUnwrap(CodingSessionResume.script(for: meta(.claudeCode, id: "u-1", project: existing)))
        XCTAssertTrue(claude.contains("cd '\(existing)'\n"))
        XCTAssertTrue(claude.contains("claude '--resume' 'u-1'"))
        XCTAssertFalse(claude.contains("exit 1"))

        let gone = try XCTUnwrap(CodingSessionResume.script(for: meta(.claudeCode, id: "u-1", project: "/nonexistent/project")))
        XCTAssertFalse(gone.contains("cd "), "项目目录没了就不 cd（N0-1）")

        XCTAssertTrue(CodingSessionResume.script(for: meta(.codex, id: "t-2", project: ""))?.contains("codex 'resume' 't-2'") == true)
        XCTAssertTrue(CodingSessionResume.script(for: meta(.kimi, id: "session_9", project: ""))?.contains("kimi '--session' 'session_9'") == true)
        XCTAssertEqual(CodingShellQuote.single("it's"), "'it'\\''s'")
    }

    // MARK: - 删除路径（N1 回收站清单全靠它）

    func testSessionPaths() throws {
        let claudeDir = home.appendingPathComponent("claude/projects/-Users-tester-Github-wakefx")
        let file = claudeDir.appendingPathComponent("11111111-aaaa-bbbb-cccc-000000000001.jsonl").path
        let claude = ClaudeCodeAdapter(root: home.appendingPathComponent("claude/projects"))
        let m = CodingSessionMeta(key: "claude-code:11111111-aaaa-bbbb-cccc-000000000001", nativeId: "11111111-aaaa-bbbb-cccc-000000000001",
                                  agent: .claudeCode, title: "", projectPath: "", projectName: "", filePath: file, createdAt: 0,
                                  updatedAt: 0, messageCount: 0, sizeBytes: 0, gitBranch: nil, model: nil, tokensUsed: nil,
                                  archived: false, source: nil)
        XCTAssertEqual(claude.sessionPaths(m), [file], "没有边车目录时只挪主文件")
        let sidecar = claudeDir.appendingPathComponent("11111111-aaaa-bbbb-cccc-000000000001/subagents")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        XCTAssertEqual(claude.sessionPaths(m), [file, sidecar.deletingLastPathComponent().path])

        let wire = home.appendingPathComponent("kimi/sessions/wd_wakefx_abc123/session_88888888-aaaa-bbbb-cccc-000000000008/agents/main/wire.jsonl")
        var km = m
        km.filePath = wire.path
        let kimi = KimiCodeAdapter(root: home.appendingPathComponent("kimi/sessions"), indexPath: home.appendingPathComponent("x"))
        XCTAssertEqual(kimi.sessionPaths(km), [home.appendingPathComponent("kimi/sessions/wd_wakefx_abc123/session_88888888-aaaa-bbbb-cccc-000000000008").path])

        var cm = m
        cm.filePath = "/codex/rollout.jsonl"
        let codex = CodexAdapter(sessionsDir: home, archivedDir: home, stateDB: home)
        XCTAssertEqual(codex.sessionPaths(cm), ["/codex/rollout.jsonl"])
    }
}
#endif
