import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 用文件工具写 memory/ = 写那种记忆；写 Prompt 文件夹 = 改那一段。聊天里（`FileLibraryTools.run`）和 CC 那头（`MemoryCCBridge`）同一条路、
/// 同一道按种类分域的闸。全虚构
@MainActor
final class MemoryFolderWriteTests: XCTestCase {
    private let pid = "fswmema-xctest"
    private var container: ModelContainer!
    private var context: ModelContext!
    private var conversation: Conversation!
    private var profile: Profile!
    private var saved: [String: Any] = [:]
    private var libraryRoot: URL!
    private var previousLibraryRoot: URL?
    private var suite: String!
    private var defaults: UserDefaults!
    private var presets: PresetManager!
    private var profiles: ProfileManager!
    private var versions: FileVersionStore!
    private let domains: [PermissionDomain] = [.memoryCards, .memorySelf, .memoryFiles, .promptEdit, .fileLibrary]
    private var keys: [String] {
        ["mem_master", "mem_content_timeline", PermissionCenter.floorsKey] + domains.flatMap { [$0.storageKey, $0.legacy.key] }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        saved = [:]
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) { saved[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
        UserDefaults.standard.set(true, forKey: "mem_master")
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mem-fsw-\(UUID().uuidString)")
        previousLibraryRoot = FileLibraryStore.testRootOverride
        FileLibraryStore.testRootOverride = libraryRoot
        container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        context = ModelContext(container)
        conversation = Conversation(id: "chat-fsw", title: "皮影作坊", createTime: .now, updateTime: .now, currentNodeId: "", profileId: pid)
        context.insert(conversation)
        try context.save()

        suite = "MemoryFolderWriteTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let blobs = libraryRoot.appendingPathComponent("blobs", isDirectory: true)
        presets = PresetManager(root: blobs, defaults: defaults)
        var p = Profile(id: pid, name: "槐序巷", emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
        let instance = presets.instantiate(templateId: Preset.balanced.id, for: p.id)
        p.presetId = instance.id
        try presets.persistNew(instance)
        profiles = ProfileManager(container: container, profiles: [p], currentProfile: p, loadError: nil,
                                  root: blobs, defaults: defaults, sideEffectsEnabled: false)
        try profiles.persistNew([p])
        profile = p
        versions = FileVersionStore(root: libraryRoot.appendingPathComponent("versions", isDirectory: true))
        PromptFolderTools.profiles = profiles
        PromptFolderTools.presets = presets
        PromptFolderTools.versionStore = versions
    }

    override func tearDownWithError() throws {
        PromptFolderTools.profiles = nil
        PromptFolderTools.presets = nil
        PromptFolderTools.versionStore = .shared
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) }
        PendingStore.forget(profileId: pid)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        FileLibraryStore.testRootOverride = previousLibraryRoot
        defaults.removePersistentDomain(forName: suite)
        if let libraryRoot { try? FileManager.default.removeItem(at: libraryRoot) }
        context = nil; container = nil
        try super.tearDownWithError()
    }

    private func allowAll() { for d in domains { PermissionCenter.setFloorLevel(.bypass, for: d, profileId: pid) } }

    /// 聊天里的助手（不过闸：闸在工具循环头，另测）
    private func fs(_ name: String, _ input: [String: Any]) async -> FileLibraryTools.Result {
        let json = String(data: try! JSONSerialization.data(withJSONObject: input), encoding: .utf8)!
        return await FileLibraryTools.run(name: name, inputJSON: json, profileId: pid, userName: "岚舟", actor: "星砚",
                                          conversation: conversation, context: context)
    }

    /// CC 里的助手（过闸）
    private func cc(_ tool: String, _ input: [String: Any], ask: PermissionGate.Ask? = nil) async -> [String: Any] {
        let frame: [String: Any] = ["type": "memory_cmd", "id": "req-1", "tool": tool, "input": input, "chat_id": conversation.id]
        return await MemoryCCBridge.handle(frame, profiles: [profile], context: context,
                                           ask: ask ?? { _, _, _ in XCTFail("这一档不该出询问卡"); return .deniedOnce })
    }

    private func cards() -> [Memory] { SwiftDataMemoryStore().listAll(profileId: pid, context: context) }
    private func log() -> [MemoryAuditLog.Entry] { MemoryAuditLog.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) }
    private var memoryRoot: URL { FileLibraryStore.memoryRoot(profileId: pid) }

    // MARK: - 记忆条目

    /// 用文件工具新建的条目也带出处（聊天里给了触发这一轮的那条用户消息）
    func testCardMadeByFileToolKeepsItsSource() async throws {
        let source = MemoryCardTool.Source(nodeId: "u1", text: "我怕打雷，\n小时候在云桥城被吓过。")
        let made = await FileLibraryTools.run(name: "fs_write", inputJSON: #"{"path":"memory/cards/岚舟/怕打雷.md","content":"岚舟怕打雷。"}"#,
                                              profileId: pid, userName: "岚舟", actor: "星砚", conversation: conversation, source: source,
                                              context: context)
        XCTAssertFalse(made.isError, made.text)
        let m = try XCTUnwrap(cards().first)
        XCTAssertEqual(m.sourceNodeId, "u1")
        XCTAssertEqual(m.sourceQuote, "我怕打雷， 小时候在云桥城被吓过。")
    }

    func testCardIsAMarkdownFileWithFrontmatter() async throws {
        let made = await fs("fs_write", ["path": "memory/cards/岚舟/新的一张.md", "content": """
        ---
        tags: [皮影, 周三]
        importance: 4
        from: 用户自述
        ---

        岚舟每周三去槐序巷皮影作坊学雕皮影。
        """])
        XCTAssertFalse(made.isError, made.text)
        let m = try XCTUnwrap(cards().first)
        XCTAssertEqual(m.content, "岚舟每周三去槐序巷皮影作坊学雕皮影。")
        XCTAssertEqual(m.subject, "岚舟", "头里没写 about：拿文件夹那一段")
        XCTAssertEqual(m.keywords, ["皮影", "周三"])
        XCTAssertEqual(m.importance, 4)
        XCTAssertEqual(m.sourceConversationId, conversation.id)
        let path = "memory/cards/岚舟/\(MemoryCardTool.short(m.id)).md"
        XCTAssertTrue(made.text.contains(path), "回话里给真的路径（文件名 = 卡的编号）：\(made.text)")
        XCTAssertEqual(log().first?.action, .add)
        XCTAssertEqual(log().first?.actor, "星砚")
        XCTAssertEqual(log().first?.via, MemoryAuditLog.viaChat)

        let read = await fs("fs_read", ["path": path])
        XCTAssertTrue(read.text.contains("---\nid: \(m.id.uuidString.lowercased())\nstate: Archive\ncreated: "), read.text)
        XCTAssertTrue(read.text.contains("about: 岚舟\nfrom: 用户自述\ntags: [皮影, 周三]\nimportance: 4\nconfidence:\npinned: no\nsource: chat-fsw\n---\n\n岚舟每周三"), read.text)
        // 文件库的属性卡读得出每一项
        XCTAssertEqual(MarkdownFrontmatter.split(MemoryCardFolder.text(m)).fields.first { $0.key == "tags" }?.value, "皮影、周三")
        XCTAssertEqual(MarkdownFrontmatter.split(MemoryCardFolder.text(m)).body, m.content)

        // 改一项、改正文：只动写了的；算批过，不算她亲手改
        let edited = await fs("fs_edit", ["path": path, "old_string": "每周三", "new_string": "每周四"])
        XCTAssertFalse(edited.isError, edited.text)
        XCTAssertEqual(m.content, "岚舟每周四去槐序巷皮影作坊学雕皮影。")
        XCTAssertNil(m.userEditedAt)
        XCTAssertNil(m.embeddingData)
        XCTAssertEqual(log().first?.action, .edit)
        let pinned = await fs("fs_edit", ["path": path, "old_string": "pinned: no", "new_string": "pinned: yes"])
        XCTAssertFalse(pinned.isError, pinned.text)
        XCTAssertTrue(m.isUserExplicit)
        XCTAssertEqual(log().first?.action, .pin)
        let partial = await fs("fs_write", ["path": path, "content": "---\ntags:\n  - 皮影\n  - 关系\nconfidence: 80\n---\n岚舟每周四去槐序巷皮影作坊学雕皮影。"])
        XCTAssertFalse(partial.isError, partial.text)
        XCTAssertEqual(m.keywords, ["皮影"])
        XCTAssertEqual(m.category, "relationship")
        XCTAssertEqual(m.confidence, 80)
        XCTAssertEqual(m.importance, 4, "没写的项不动")
        XCTAssertTrue(m.isUserExplicit)

        // 只读的项、认不出的项、不对的值：拒，说清是哪一项，卡不动
        for (bad, word) in [("---\nid: 00000000-0000-4000-8000-000000000000\n---\n岚舟每周四去槐序巷皮影作坊学雕皮影。", "只读"),
                            ("---\nmood: 开心\n---\n岚舟每周四去槐序巷皮影作坊学雕皮影。", "认不出「mood」"),
                            ("---\nimportance: 9\n---\n岚舟每周四去槐序巷皮影作坊学雕皮影。", "1–5"),
                            ("---\nfrom: 路人\n---\n岚舟每周四去槐序巷皮影作坊学雕皮影。", "from 只能写"),
                            ("---\ntags: [皮影]\n", "没有收尾")] {
            let r = await fs("fs_write", ["path": path, "content": bad])
            XCTAssertTrue(r.isError && r.text.contains(word), "\(word)：\(r.text)")
        }
        XCTAssertEqual(m.importance, 4)

        // 挪文件夹 = 改 about；删 = 进 Deleted；改 state = 放回
        let moved = await fs("fs_rename", ["old_path": path, "new_path": "memory/cards/星砚/\(MemoryCardTool.short(m.id)).md"])
        XCTAssertFalse(moved.isError, moved.text)
        XCTAssertEqual(m.subject, "星砚")
        let deleted = await fs("fs_delete", ["path": "memory/cards/星砚/\(MemoryCardTool.short(m.id)).md"])
        XCTAssertFalse(deleted.isError, deleted.text)
        XCTAssertNotNil(m.supersededAt)
        XCTAssertEqual(log().first?.action, .delete)
        let gone = "memory/cards/Deleted/\(MemoryCardTool.short(m.id)).md"
        let list = await fs("fs_list", [:])
        XCTAssertTrue(list.text.contains(gone) && list.text.contains(MemoryCardFolder.pinnedPath), list.text)
        let whileDeleted = await fs("fs_edit", ["path": gone, "old_string": "每周四", "new_string": "每周五"])
        XCTAssertTrue(whileDeleted.isError && whileDeleted.text.contains("state"), whileDeleted.text)
        let back = await fs("fs_edit", ["path": gone, "old_string": "state: Deleted", "new_string": "state: Draft"])
        XCTAssertFalse(back.isError, back.text)
        XCTAssertNil(m.supersededAt)
        XCTAssertNil(m.reviewedAt, "放回成 Draft")
        XCTAssertEqual(log().first?.action, .restore)

        // 她在记忆日志里撤得回助手用文件做的这一笔
        XCTAssertEqual(MemoryAuditLog.undo(try XCTUnwrap(log().first), profileId: pid, context: context).restored, 1)
        XCTAssertNotNil(m.supersededAt)
        let pinnedList = await fs("fs_write", ["path": MemoryCardFolder.pinnedPath, "content": "x"])
        XCTAssertTrue(pinnedList.isError && pinnedList.text.contains("只读"), pinnedList.text)
    }

    func testHerEditInTheFileLibraryCanDeleteAndRestore() throws {
        let m = try SwiftDataMemoryStore().add(content: "星砚答应陪岚舟刻纸鸢。", category: "fact", keywords: [], profileId: pid, isUserExplicit: false,
                                               extractedBy: "测试", sourceConversationId: "chat-fsw", context: context)
        let text = MemoryCardFolder.text(m)
        let stamp = try MemoryCardFolder.save(card: m.id, text: text.replacingOccurrences(of: "state: Draft", with: "state: Deleted"), baseline: text,
                                              stamp: m.updatedAt, profileId: pid, context: context)
        XCTAssertNotNil(m.supersededAt)
        XCTAssertEqual(MemoryCardFolder.entries(profileId: pid, context: context).first?.folder, "memory/cards/Deleted")
        let deleted = MemoryCardFolder.text(m)
        try MemoryCardFolder.save(card: m.id, text: deleted.replacingOccurrences(of: "state: Deleted", with: "state: Archive"), baseline: deleted,
                                  stamp: stamp, profileId: pid, context: context)
        XCTAssertNil(m.supersededAt)
        XCTAssertNotNil(m.reviewedAt)
        XCTAssertEqual(log().map(\.action), [.restore, .delete])
        XCTAssertTrue(log().allSatisfy { $0.actor == MemoryAuditLog.you && $0.via == MemoryAuditLog.viaFileLibrary })
    }

    // MARK: - 自己的记忆 / 待续 / wiki 页 / 只读的

    func testSelfMemoryThroughFiles() async throws {
        let made = await fs("fs_write", ["path": "memory/self/纸鸢的约定.md", "content": """
        ---
        name: 纸鸢的约定
        description: 答应陪岚舟刻一只纸鸢
        metadata:
          type: project
          importance: 4
        ---

        岚舟说「开春前刻好」。我答应了。
        """])
        XCTAssertFalse(made.isError, made.text)
        let listed = await Task.detached { [memoryRoot] in SelfMemoryStore.list(memoryRoot: memoryRoot, checkPath: AppPaths.checked) }.value
        let m = try XCTUnwrap(listed.first)
        XCTAssertEqual([m.name, m.type, m.origin, m.source ?? ""], ["纸鸢的约定", "project", "self", "chat-fsw"])
        XCTAssertEqual(m.importance, 4)
        let file = "memory/self/\(m.fileName)"
        let index = await fs("fs_read", ["path": MemoryFolderWrite.selfIndexPath])
        XCTAssertTrue(index.text.contains("答应陪岚舟刻一只纸鸢"), index.text)

        let edited = await fs("fs_edit", ["path": file, "old_string": "开春前刻好", "new_string": "清明前刻好"])
        XCTAssertFalse(edited.isError, edited.text)
        let bad = await fs("fs_edit", ["path": file, "old_string": "importance: 4", "new_string": "importance: 9"])
        XCTAssertTrue(bad.isError && bad.text.contains("1–5"), bad.text)
        let origin = await fs("fs_edit", ["path": file, "old_string": "origin: self", "new_string": "origin: asked"])
        XCTAssertTrue(origin.isError && origin.text.contains("只读"), origin.text)
        let forgot = await fs("fs_delete", ["path": file])
        XCTAssertFalse(forgot.isError, forgot.text)
        let after = await Task.detached { [memoryRoot] in SelfMemoryStore.list(memoryRoot: memoryRoot, checkPath: AppPaths.checked) }.value
        XCTAssertEqual(after.first?.body, "岚舟说「清明前刻好」。我答应了。")
        XCTAssertEqual(after.first?.isActive, false, "删文件 = 标成失效，文件还在")
        let indexWrite = await fs("fs_write", ["path": MemoryFolderWrite.selfIndexPath, "content": "x"])
        XCTAssertTrue(indexWrite.isError && indexWrite.text.contains("自动排的"), indexWrite.text)
    }

    func testPendingThroughFiles() async throws {
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        try XCTSkipUnless(PendingNotesTool.enabled, "时间轴开关在这台机器上关着")
        let first = await fs("fs_append", ["path": MemoryFolderWrite.pendingPath, "content": "- 帮岚舟问皮影作坊周三开不开"])
        XCTAssertFalse(first.isError, first.text)
        func items() async -> [PendingItem] {
            await Task.detached { [pid, memoryRoot] in PendingStore.load(profileId: pid, floorMemoryRoot: memoryRoot) ?? [] }.value
        }
        var now = await items()
        XCTAssertEqual(now.map(\.text), ["帮岚舟问皮影作坊周三开不开"])
        XCTAssertEqual(now.first?.conversationId, conversation.id)
        let done = await fs("fs_edit", ["path": MemoryFolderWrite.pendingPath, "old_string": "state=open", "new_string": "state=done"])
        XCTAssertFalse(done.isError, done.text)
        let reworded = await fs("fs_edit", ["path": MemoryFolderWrite.pendingPath, "old_string": "周三开不开", "new_string": "周四开不开"])
        XCTAssertFalse(reworded.isError, reworded.text)
        now = await items()
        XCTAssertEqual(now.first?.state, .done)
        XCTAssertEqual(now.first?.text, "帮岚舟问皮影作坊周四开不开")
        let meta = await fs("fs_edit", ["path": MemoryFolderWrite.pendingPath, "old_string": "conv=chat-fsw", "new_string": "conv=别的窗口"])
        XCTAssertTrue(meta.isError && meta.text.contains("只有 state 能改"), meta.text)
        let junk = await fs("fs_append", ["path": MemoryFolderWrite.pendingPath, "content": "随手写的一句"])
        XCTAssertTrue(junk.isError && junk.text.contains("这一行认不出来：随手写的一句"), junk.text)
        // 她在文件库里：改字 / 删行行，新加不行
        let text = await Task.detached { [pid] in MemoryFolderWrite.pendingText(profileId: pid) }.value
        let hers = await Task.detached { [pid] in
            Swift.Result { try MemoryFolderWrite.savePending(text: text + "\n- 买灯笼纸", profileId: pid, writer: .you) }
        }.value
        XCTAssertThrowsError(try hers.get())
        _ = try await Task.detached { [pid] in
            try MemoryFolderWrite.savePending(text: "---\nversion: 1\n---\n", profileId: pid, writer: .you)
        }.value
        now = await items()
        XCTAssertTrue(now.isEmpty, "删掉那一行 = 删掉那一条")
    }

    func testWikiPageThroughFiles() async throws {
        let group = WikiStore.branches[1]
        let path = "memory/wiki/\(group)/皮影作坊.md"
        let made = await fs("fs_write", ["path": path, "content": "# 皮影作坊\n\n## 现在\n岚舟每周三去槐序巷的皮影作坊。\n"])
        XCTAssertFalse(made.isError, made.text)
        let store = WikiStore(profileId: pid)
        let page = "\(group)/皮影作坊"
        let created = await Task.detached { store.readRaw(page) }.value
        XCTAssertTrue(created?.contains("每周三") == true)
        let edited = await fs("fs_edit", ["path": path, "old_string": "每周三", "new_string": "每周四"])
        XCTAssertFalse(edited.isError, edited.text)
        let (now, history) = await Task.detached { (store.readRaw(page), store.history(page)) }.value
        XCTAssertTrue(now?.contains("每周四") == true)
        XCTAssertEqual(history.count, 1, "改之前的那一版进了历史")
        let noTitle = await fs("fs_write", ["path": "memory/wiki/\(group)/没标题.md", "content": "只有一句话"])
        XCTAssertTrue(noTitle.isError && noTitle.text.contains("# 标题"), noTitle.text)
        let index = await fs("fs_write", ["path": "memory/wiki/INDEX.md", "content": "x"])
        XCTAssertTrue(index.isError && index.text.contains("只读"), index.text)
        let hidden = await fs("fs_write", ["path": "memory/wiki/.proposals/x.md", "content": "x"])
        XCTAssertTrue(hidden.isError && hidden.text.contains("没有这个文件"), hidden.text)
    }

    func testReadOnlyPlacesSayWhy() async {
        for (path, word) in [("memory/timeline/2026-11.md", "时间轴"), ("memory/windows/abc.md", "窗口总结"), ("memory/sessions/abc.md", "段摘要"),
                             ("memory/log/审计日志.md", "日志只记不改"), ("memory/cc/notes.md", "CC"), ("memory/heartvoice/2026-11-14-0900.md", "心声"),
                             ("memory/user-card.md", "对方自己的资料卡")] {
            let r = await fs("fs_write", ["path": path, "content": "x"])
            XCTAssertTrue(r.isError && r.text.contains("只读") && r.text.contains(word), "\(path)：\(r.text)")
        }
        let escape = await fs("fs_write", ["path": "memory/../notes/x.md", "content": "x"])
        XCTAssertTrue(escape.isError && escape.text.contains("非法路径"), escape.text)
        conversation.memoryEnabled = false
        let off = await fs("fs_write", ["path": "memory/cards/岚舟/x.md", "content": "岚舟怕打雷。"])
        XCTAssertTrue(off.isError && off.text.contains("记忆参与"), off.text)
        XCTAssertTrue(cards().isEmpty)
    }

    /// CC 在电脑上的记忆文件夹里给待续加一行：没有窗口可挂，记在 `PendingStore.ccWindow` 名下；没做完的每轮都带
    func testPendingLineAddedOutsideAWindow() async throws {
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        try XCTSkipUnless(PendingNotesTool.enabled, "时间轴开关在这台机器上关着")
        let input = ["path": MemoryFolderWrite.pendingPath, "content": "- 帮岚舟查云桥城的灯会是哪天"]
        let json = String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8)!
        let r = await FileLibraryTools.run(name: "fs_append", inputJSON: json, profileId: pid, userName: "岚舟", actor: "CC 里的星砚",
                                           conversationId: nil, memoryEnabled: true, via: MemoryAuditLog.viaCC, context: context)
        XCTAssertFalse(r.isError, r.text)
        let items = await Task.detached { [pid, memoryRoot] in PendingStore.load(profileId: pid, floorMemoryRoot: memoryRoot) ?? [] }.value
        XCTAssertEqual(items.map(\.text), ["帮岚舟查云桥城的灯会是哪天"])
        XCTAssertEqual(items.first?.conversationId, PendingStore.ccWindow)
        XCTAssertEqual(items.first?.state, .open)
        let open = await Task.detached { [pid, memoryRoot] in PendingStore.openByConversation(profileId: pid, floorMemoryRoot: memoryRoot) }.value
        // 这几天时间轴是空的也带
        let alone = TimelineStore.injection(records: [:], entries: [:], today: "2026-11-14", currentConversationId: "chat-fsw",
                                            windowIds: [], openPending: open)
        XCTAssertTrue(alone.text?.contains("[待续]") == true && alone.text?.contains("- 在 CC 里记的：帮岚舟查云桥城的灯会是哪天") == true, alone.text ?? "nil")
        let floor = TimelineStore.injection(memoryRoot: memoryRoot, now: Date(), currentConversationId: "chat-fsw", windowIds: [],
                                            openPending: { open })
        XCTAssertTrue(floor.text?.contains("在 CC 里记的") == true, floor.text ?? "nil")
        let none = TimelineStore.injection(records: [:], entries: [:], today: "2026-11-14", currentConversationId: "chat-fsw",
                                           windowIds: [], openPending: [:])
        XCTAssertNil(none.text, "没有这一组就照旧什么都不带")
    }

    /// 整理提案 / 要点卡 / 页历史在 memory/wiki/ 下各有一处，读得到、列得到、写不了；提案和要点卡进同步给 CC 的那棵树，页历史不进
    func testWikiRecordsAreReadOnlyFiles() async throws {
        let group = WikiStore.branches[1]
        let page = "memory/wiki/\(group)/皮影作坊.md"
        _ = await fs("fs_write", ["path": page, "content": "# 皮影作坊\n\n## 现在\n岚舟每周三去槐序巷的皮影作坊。\n"])
        _ = await fs("fs_edit", ["path": page, "old_string": "每周三", "new_string": "每周四"])
        let store = WikiStore(profileId: pid)
        let suggested = await Task.detached { [pid] in
            WikiSuggestTool.execute(inputJSON: #"{"path":"地点/云桥城","reason":"岚舟说下个月去云桥城看灯会"}"#, wiki: store, profileId: pid, userName: "岚舟")
        }.value
        XCTAssertFalse(suggested.isError, suggested.text)
        try await Task.detached {
            try SeedNoteStore(wiki: store).save(SeedNoteCard(path: "memory/cc/星砚.md", version: "v1", name: "星砚", layer: "CC", title: "云桥城灯会",
                                                             gist: "岚舟和星砚约好去云桥城看灯会。", mentions: [.init(name: "云桥城", group: "地点")],
                                                             aboutUser: false, group: "地点", when: ["下个月"], model: "test", madeAt: Date(),
                                                             run: CatalogRunLink(path: "run")))
            try SeedNoteStore(wiki: store).save(SeedNoteCard(path: "memory/cc/private_林栖.md", version: "v1", name: "林栖", layer: "CC", title: "私人的",
                                                             gist: "不该出现。", mentions: [], aboutUser: false, group: "人", when: [], model: "test",
                                                             madeAt: Date(), run: CatalogRunLink(path: "run")))
        }.value

        let listed = await fs("fs_list", [:])
        let lines = listed.text.components(separatedBy: "\n")
        func path(under folder: String) -> String? {
            lines.first { $0.hasPrefix(folder + "/") }.flatMap { $0.components(separatedBy: "  (").first }
        }
        let proposal = try XCTUnwrap(path(under: MemoryRecordsFolder.proposalsFolder), listed.text)
        let history = try XCTUnwrap(path(under: MemoryRecordsFolder.historyFolder + "/\(group)/皮影作坊"), listed.text)
        XCTAssertEqual(lines.filter { $0.hasPrefix(MemoryRecordsFolder.notesFolder + "/") }.count, 2)

        let proposalText = await fs("fs_read", ["path": proposal]).text
        XCTAssertTrue(proposalText.contains("Pending") && proposalText.contains("地点/云桥城") && proposalText.contains("岚舟说下个月去云桥城看灯会"), proposalText)
        let historyText = await fs("fs_read", ["path": history]).text
        XCTAssertTrue(historyText.contains("每周三") && !historyText.contains("每周四"), "历史里是改之前的那一版：\(historyText)")
        var notes: [String] = []
        for line in lines where line.hasPrefix(MemoryRecordsFolder.notesFolder + "/") {
            let r = await fs("fs_read", ["path": line.components(separatedBy: "  (")[0]])
            if !r.isError { notes.append(r.text) }
        }
        XCTAssertEqual(notes.count, 1, "出自私人原料的那张读不到")
        XCTAssertTrue(notes.first?.contains("云桥城灯会") == true && notes.first?.contains("岚舟和星砚约好去云桥城看灯会。") == true
                      && notes.first?.contains("- 云桥城（地点）") == true, notes.first ?? "")

        allowAll()
        for (target, word) in [(proposal, "审计台"), (history, "历史"), (MemoryRecordsFolder.notesFolder + "/x.md", "要点卡")] {
            let w = await fs("fs_write", ["path": target, "content": "x"])
            XCTAssertTrue(w.isError && w.text.contains("只读") && w.text.contains(word), "\(target)：\(w.text)")
            let d = await fs("fs_delete", ["path": target])
            XCTAssertTrue(d.isError && d.text.contains("只读"), d.text)
        }
        XCTAssertEqual(PermissionDomain.forCall(named: "fs_write", argumentsJSON: #"{"path":"\#(proposal)"}"#), .fileLibrary, "只读的不另问，执行时拒")

        let snapshot = await Task.detached { [profile, container] in
            GardenTree.snapshot(profile: profile!, device: "测试机", container: container, promptFiles: [])
        }.value
        XCTAssertNotNil(snapshot.content(proposal))
        XCTAssertNil(snapshot.content(history), "页历史只在花园里看")
        XCTAssertFalse(snapshot.entries.contains { $0.path.hasPrefix(MemoryRecordsFolder.historyFolder + "/") })
        XCTAssertEqual(snapshot.entries.filter { $0.path.hasPrefix(MemoryRecordsFolder.notesFolder + "/") }.count, 1, "读不到的不进树")
    }

    // MARK: - 权限：写的是哪一种就归哪个域

    /// 写待续（pending_notes 记一条 / 标做完 / 淡了）过「自己的记忆」那一档，默认自动允许；suggest_wiki_direction 过「记忆文件」那一档；只是看的不问
    func testPendingToolAndWikiSuggestionAreGated() async throws {
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        try XCTSkipUnless(PendingNotesTool.enabled, "时间轴开关在这台机器上关着")
        func domain(_ tool: String, _ args: String) -> PermissionDomain { PermissionDomain.forCall(named: tool, argumentsJSON: args) }
        XCTAssertEqual(domain("pending_notes", #"{"action":"add","text":"x"}"#), .memorySelf)
        XCTAssertEqual(domain("pending_notes", #"{"action":"done","id":"p0001"}"#), .memorySelf)
        XCTAssertEqual(domain("pending_notes", #"{"action":"faded","id":"p0001"}"#), .memorySelf)
        XCTAssertEqual(domain("pending_notes", #"{"action":"list"}"#), .toolsMaster)
        XCTAssertEqual(domain(WikiSuggestTool.toolName, #"{"path":"地点/云桥城","reason":"x"}"#), .memoryFiles)
        XCTAssertEqual(PermissionDomain.forTool(named: WikiSuggestTool.toolName), .memoryFiles)

        // 默认（自动允许）：记一条不问，直接写
        let added = await cc("pending_notes", ["action": "add", "text": "帮岚舟问皮影作坊周三开不开"])
        XCTAssertEqual(added["ok"] as? Bool, true, added["result"] as? String ?? "")
        let listed = await cc("pending_notes", ["action": "list"])
        XCTAssertTrue((listed["result"] as? String ?? "").contains("帮岚舟问皮影作坊周三开不开"), listed["result"] as? String ?? "")

        // 她改成每次询问：出的是「自己的记忆」那张卡，没点允许就不标
        PermissionCenter.setFloorLevel(.askOnce, for: .memorySelf, profileId: pid)
        var asked: [PermissionDomain] = []
        let refused = await cc("pending_notes", ["action": "done", "id": "p0001"], ask: { d, _, _ in asked.append(d); return .deniedOnce })
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(asked, [.memorySelf])
        var items = await Task.detached { [pid, memoryRoot] in PendingStore.load(profileId: pid, floorMemoryRoot: memoryRoot) ?? [] }.value
        XCTAssertEqual(items.map(\.state), [.open], "她没点允许就不标")

        // 不允许：直接拒，不问；看照旧
        PermissionCenter.setFloorLevel(.notAllowed, for: .memorySelf, profileId: pid)
        let denied = await cc("pending_notes", ["action": "done", "id": "p0001"])
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertTrue((denied["result"] as? String ?? "").contains("自己的记忆"), denied["result"] as? String ?? "")
        let stillLists = await cc("pending_notes", ["action": "list"])
        XCTAssertEqual(stillLists["ok"] as? Bool, true)

        // 回到自动允许
        PermissionCenter.setFloorLevel(.bypass, for: .memorySelf, profileId: pid)
        let done = await cc("pending_notes", ["action": "done", "id": "p0001"])
        XCTAssertEqual(done["ok"] as? Bool, true, done["result"] as? String ?? "")
        items = await Task.detached { [pid, memoryRoot] in PendingStore.load(profileId: pid, floorMemoryRoot: memoryRoot) ?? [] }.value
        XCTAssertEqual(items.map(\.state), [.done])

        // 提整理方向：记忆文件那一档是不允许时被拒，不问
        PermissionCenter.setFloorLevel(.notAllowed, for: .memoryFiles, profileId: pid)
        let gate = await PermissionGate.toolGate(toolName: WikiSuggestTool.toolName, argumentsJSON: #"{"path":"地点/云桥城","reason":"x"}"#,
                                                 conversation: conversation, context: context,
                                                 ask: { _, _, _ in XCTFail("不允许时不该问"); return .deniedOnce })
        guard case .deny = gate else { return XCTFail("不允许时提方向要被拒") }
        PermissionCenter.setFloorLevel(.askOnce, for: .memoryFiles, profileId: pid)
        var askedWiki: [PermissionDomain] = []
        let asking = await PermissionGate.toolGate(toolName: WikiSuggestTool.toolName, argumentsJSON: #"{"path":"地点/云桥城","reason":"x"}"#,
                                                   conversation: conversation, context: context,
                                                   ask: { d, _, _ in askedWiki.append(d); return .allowedOnce })
        guard case .proceed = asking else { return XCTFail("点了允许就放行") }
        XCTAssertEqual(askedWiki, [.memoryFiles])
    }

    func testDomainsFollowWhatIsWritten() {
        func domain(_ tool: String, _ args: String) -> PermissionDomain { PermissionDomain.forCall(named: tool, argumentsJSON: args) }
        XCTAssertEqual(domain("fs_write", #"{"path":"memory/cards/岚舟/x.md"}"#), .memoryCards)
        XCTAssertEqual(domain("fs_edit", #"{"path":"memory/self/x.md"}"#), .memorySelf)
        XCTAssertEqual(domain("fs_edit", #"{"path":"memory/self/../cards/岚舟/x.md"}"#), .memoryCards, "绕路的路径按落到哪算")
        XCTAssertEqual(domain("fs_append", #"{"path":"memory/pending/待续.md"}"#), .memorySelf, "待续是助手自己的备忘：和它自己的记忆同一档")
        XCTAssertEqual(domain("fs_delete", #"{"path":"memory/wiki/\#(WikiStore.branches[1])/皮影作坊.md"}"#), .memoryFiles)
        XCTAssertEqual(domain("fs_write", #"{"path":".prompt/fields/characterDescription.txt"}"#), .promptEdit)
        XCTAssertEqual(domain("fs_write", #"{"path":"notes/todo.md"}"#), .fileLibrary)
        XCTAssertEqual(domain("fs_read", #"{"path":"memory/cards/岚舟/x.md"}"#), .fileLibrary, "读照旧")
        XCTAssertEqual(domain("fs_write", #"{"path":"memory/timeline/2026-11.md"}"#), .fileLibrary, "只读的不另问，执行时拒")
        XCTAssertEqual(PermissionDomain.forTool(named: "remember"), .memorySelf)
        XCTAssertEqual(PermissionCenter.level(.memorySelf, profileId: pid), .bypass)
        XCTAssertEqual(PermissionCenter.level(.memoryFiles, profileId: pid), .askOnce)
        XCTAssertEqual(PermissionCenter.level(.promptEdit, profileId: pid), .askOnce)
        for d in [PermissionDomain.memoryCards, .memorySelf, .memoryFiles, .promptEdit] {
            XCTAssertTrue(d.asksEveryCall, d.rawValue)
            XCTAssertTrue(PermissionDomain.toolDomains.contains(d), d.rawValue)
        }
    }

    func testThreeLevelsThroughTheCCBridge() async throws {
        // 每次询问：出的是「记忆条目」那张卡，卡上有要动的东西；点了才写，留痕标 CC
        var asked: [(PermissionDomain, String?)] = []
        let allowOnce: PermissionGate.Ask = { domain, detail, _ in asked.append((domain, detail)); return .allowedOnce }
        let made = await cc("fs_write", ["path": "memory/cards/岚舟/a.md", "content": "岚舟怕打雷。"], ask: allowOnce)
        XCTAssertEqual(made["ok"] as? Bool, true, made["result"] as? String ?? "")
        XCTAssertEqual(asked.map { $0.0 }, [.memoryCards])
        XCTAssertEqual(asked.first?.1, "新加一条记忆条目")
        let m = try XCTUnwrap(cards().first)
        XCTAssertEqual(log().first?.actor, "CC 里的星砚")
        XCTAssertEqual(log().first?.via, MemoryAuditLog.viaCC)
        XCTAssertFalse(PermissionGrants(raw: conversation.permGrantsRaw).isResolved(.memoryCards), "一笔一问，不记对话授权")

        let path = "memory/cards/岚舟/\(MemoryCardTool.short(m.id)).md"
        let refused = await cc("fs_edit", ["path": path, "old_string": "打雷", "new_string": "打闪"], ask: { domain, detail, _ in
            XCTAssertEqual(detail, "这条记忆条目现在写的是：「岚舟怕打雷。」")
            return .deniedOnce
        })
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(m.content, "岚舟怕打雷。")

        // 不允许：不问，直接拒
        PermissionCenter.setFloorLevel(.notAllowed, for: .memoryCards, profileId: pid)
        let denied = await cc("fs_delete", ["path": path])
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertTrue((denied["result"] as? String ?? "").contains("记忆条目"), denied["result"] as? String ?? "")
        XCTAssertNil(m.supersededAt)

        // 自动允许：不问，直接写
        PermissionCenter.setFloorLevel(.bypass, for: .memoryCards, profileId: pid)
        let deleted = await cc("fs_delete", ["path": path])
        XCTAssertEqual(deleted["ok"] as? Bool, true, deleted["result"] as? String ?? "")
        XCTAssertNotNil(m.supersededAt)

        // 自己的记忆默认自动允许；CC 这头文件工具只碰 memory/ 和 Prompt 文件夹
        let own = await cc("fs_write", ["path": "memory/self/怕打雷.md", "content": "---\nname: 怕打雷\ndescription: 岚舟怕打雷\n---\n\n岚舟说「一打雷就睡不着」。"])
        XCTAssertEqual(own["ok"] as? Bool, true, own["result"] as? String ?? "")
        let outside = await cc("fs_write", ["path": "notes/todo.md", "content": "x"])
        XCTAssertEqual(outside["ok"] as? Bool, false)
        XCTAssertTrue((outside["result"] as? String ?? "").contains("memory/"), outside["result"] as? String ?? "")
    }

    // MARK: - Prompt 文件夹

    func testPromptFolderThroughFiles() async throws {
        let field = ".prompt/fields/characterDescription.txt"
        let list = await fs("fs_list", [:])
        XCTAssertTrue(list.text.contains("\(field)  (0B)  楼层字段「助手设定」"), list.text)
        let main = PromptFolder.path(for: .slot(presetId: profile.presetId, slotId: PromptSlot.mainId))
        XCTAssertTrue(list.text.contains(main), list.text)

        // 每次询问：卡上看得到改的是哪一段、改前改后的开头
        var details: [String?] = []
        let asked = await cc("fs_write", ["path": field, "content": "星砚是槐序巷皮影作坊的学徒，说话慢，爱问为什么。"], ask: { domain, detail, _ in
            XCTAssertEqual(domain, .promptEdit)
            details.append(detail)
            return .allowedOnce
        })
        XCTAssertEqual(asked["ok"] as? Bool, true, asked["result"] as? String ?? "")
        XCTAssertEqual(details, ["要改的是楼层字段「助手设定」。现在：「（空）」→ 写成：「星砚是槐序巷皮影作坊的学徒，说话慢，爱问为什么。」"])
        XCTAssertEqual(profiles.profiles.first?.characterDescription, "星砚是槐序巷皮影作坊的学徒，说话慢，爱问为什么。")
        XCTAssertTrue((asked["result"] as? String ?? "").contains("下一条消息起生效"), asked["result"] as? String ?? "")

        // 版本历史：写之前、写之后各一版，写之后那版标着是谁；回到上一版 = 把上一版存回去
        let key = try XCTUnwrap(PromptFolderTools.versionKey(path: field, profileId: pid))
        var history = try await versions.versions(key: key)
        XCTAssertEqual(history.map(\.actor), ["CC 里的星砚", nil])
        XCTAssertEqual(FileVersionHistory.label(history[0]), "CC 里的星砚 写的")
        let previous = try await versions.content(key: key, id: history[1].id)
        XCTAssertEqual(previous, "")

        PermissionCenter.setFloorLevel(.bypass, for: .promptEdit, profileId: pid)
        let edited = await fs("fs_edit", ["path": field, "old_string": "说话慢", "new_string": "说话快"])
        XCTAssertFalse(edited.isError, edited.text)
        XCTAssertEqual(profiles.profiles.first?.characterDescription, "星砚是槐序巷皮影作坊的学徒，说话快，爱问为什么。")
        history = try await versions.versions(key: key)
        XCTAssertEqual(history.first?.actor, "星砚")
        let read = await fs("fs_read", ["path": field])
        XCTAssertTrue(read.text.contains("说话快"), read.text)
        let hits = await fs("fs_search", ["keyword": "皮影作坊的学徒"])
        XCTAssertTrue(hits.text.contains("\(field): 星砚是"), hits.text)

        // 插槽：改正文行；系统自动填充的只读；不能删、不能新建
        let slot = await fs("fs_write", ["path": main, "content": "你是{{char}}，在槐序巷陪{{user}}刻皮影。"])
        XCTAssertFalse(slot.isError, slot.text)
        XCTAssertEqual(presets.preset(byId: profile.presetId)?.prompts.first { $0.id == PromptSlot.mainId }?.content, "你是{{char}}，在槐序巷陪{{user}}刻皮影。")
        if let auto = PromptFolderTools.files(profileId: pid).first(where: { $0.note.contains("只读") }) {
            let r = await fs("fs_write", ["path": auto.path, "content": "x"])
            XCTAssertTrue(r.isError && r.text.contains("自动填充"), r.text)
        }
        let deleted = await fs("fs_delete", ["path": field])
        XCTAssertTrue(deleted.isError && deleted.text.contains("Prompt 页"), deleted.text)
        let new = await fs("fs_write", ["path": ".prompt/新的插槽.txt", "content": "x"])
        XCTAssertTrue(new.isError && new.text.contains("没有这个文件"), new.text)

        // 不允许：直接拒
        PermissionCenter.setFloorLevel(.notAllowed, for: .promptEdit, profileId: pid)
        let denied = await cc("fs_edit", ["path": field, "old_string": "说话快", "new_string": "不说话"])
        XCTAssertEqual(denied["ok"] as? Bool, false)
        XCTAssertTrue((denied["result"] as? String ?? "").contains("Prompt"), denied["result"] as? String ?? "")
        XCTAssertEqual(profiles.profiles.first?.characterDescription, "星砚是槐序巷皮影作坊的学徒，说话快，爱问为什么。")
    }
}
