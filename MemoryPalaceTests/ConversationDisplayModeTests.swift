import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 升级前的 Conversation（没有 displayMode 列），只用来造一个老库，验证轻量迁移后全是文章
enum ConversationDisplayModeLegacyStore {
    @Model
    final class Conversation {
        @Attribute(.unique) var id: String
        var profileId: String = ""
        var title: String
        var createTime: Date
        var updateTime: Date
        var currentNodeId: String
        var nodeCount: Int = 0

        init(id: String, title: String, currentNodeId: String, profileId: String) {
            self.id = id
            self.title = title
            self.createTime = Date()
            self.updateTime = Date()
            self.currentNodeId = currentNodeId
            self.profileId = profileId
        }
    }
}

/// 气泡 / 文章共存第二步：每个对话自己记模式，「当前是不是气泡」只从 ViewModel 出
final class ConversationDisplayModeTests: XCTestCase {
    private var tempDirs: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        tempDirs.forEach { try? FileManager.default.removeItem(at: $0) }
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ConversationDisplayModeTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func memoryContainer() throws -> ModelContainer {
        let schema = ProfileManager.makeFullSchema()
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    private func insertConversation(_ ctx: ModelContext, id: String, pid: String, mode: ConversationDisplayMode,
                                    messages: Int = 2) -> Conversation {
        let ids = (0..<messages).map { "\(id)-\($0)" }
        let conv = Conversation(id: id, title: id, createTime: Date(), updateTime: Date(),
                                currentNodeId: ids.last ?? "", provider: "api", profileId: pid)
        conv.mode = mode
        conv.nodeCount = messages
        ctx.insert(conv)
        for (i, nodeId) in ids.enumerated() {
            ctx.insert(MessageNode(id: nodeId, role: i.isMultiple(of: 2) ? "user" : "assistant", content: "\(id) \(i)",
                                   contentType: "text", createTime: Date(), parentId: i == 0 ? nil : ids[i - 1],
                                   childrenIds: i + 1 < ids.count ? [ids[i + 1]] : [], conversationId: id, profileId: pid))
        }
        return conv
    }

    @MainActor
    private func load(_ vm: ConversationViewModel, _ conv: Conversation, _ ctx: ModelContext) async throws {
        vm.loadConversation(conv, context: ctx)
        for _ in 0..<200 where vm.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - 1. 老库升级后全是文章

    func testLegacyStoreMigratesToArticleRegardlessOfOldGlobalSwitch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("display-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let url = dir.appendingPathComponent("legacy.store")
        do {
            let schema = Schema([ConversationDisplayModeLegacyStore.Conversation.self])
            let legacy = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            ])
            let ctx = ModelContext(legacy)
            for i in 0..<3 {
                ctx.insert(ConversationDisplayModeLegacyStore.Conversation(id: "old-\(i)", title: "老对话 \(i)",
                                                                           currentNodeId: "n\(i)", profileId: "p"))
            }
            try ctx.save()
        }

        // 升级那一刻全局开关开着气泡：不能影响迁移结果；启动清理把残留键删掉
        let defaults = makeDefaults()
        defaults.set(true, forKey: "chatBubbleMode")
        _ = ThemeManager(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "chatBubbleMode"), "启动时删掉全局显示方式的残留键")

        let schema = ProfileManager.makeFullSchema()
        let upgraded = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        ])
        let convs = try ModelContext(upgraded).fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.id)]))
        XCTAssertEqual(convs.map(\.id), ["old-0", "old-1", "old-2"])
        XCTAssertEqual(Set(convs.map(\.displayMode)), ["article"], "老对话一律文章")
        XCTAssertTrue(convs.allSatisfy { $0.mode == .article && !$0.isBubbleMode })
    }

    func testUnknownDisplayModeReadsAsArticle() {
        let conv = Conversation(id: "x", title: "x", createTime: Date(), updateTime: Date(), currentNodeId: "")
        XCTAssertEqual(conv.mode, .article, "新建默认文章")
        conv.displayMode = "something-else"
        XCTAssertEqual(conv.mode, .article)
        conv.mode = .bubble
        XCTAssertEqual(conv.displayMode, "bubble")
    }

    // MARK: - 2. 新建默认文章，传 bubble 是气泡

    @MainActor
    func testCreateNewConversationDefaultsToArticle() throws {
        let container = try memoryContainer()
        let ctx = ModelContext(container)
        let vm = ConversationViewModel()
        let plain = vm.createNewConversation(title: "默认", profileId: "p", context: ctx)
        XCTAssertEqual(plain.mode, .article)
        let bubble = vm.createNewConversation(title: "气泡", profileId: "p", displayMode: .bubble, context: ctx)
        XCTAssertEqual(bubble.mode, .bubble)
        let stored = try ModelContext(container).fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: stored.map { ($0.title, $0.displayMode) }),
                       ["默认": "article", "气泡": "bubble"], "落库的就是这一列")
    }

    @MainActor
    func testNewDraftDefaultsToArticleAndLongPressPicksBubble() {
        let vm = ConversationViewModel()
        vm.startNewConversation(profileId: "p", fresh: true, cards: nil)
        XCTAssertEqual(vm.selectedConversation?.mode, .article, "点「+」= 文章")
        XCTAssertFalse(vm.isBubbleMode)

        vm.startNewConversation(profileId: "p", fresh: true, displayMode: .bubble, cards: nil)
        XCTAssertEqual(vm.selectedConversation?.mode, .bubble, "长按「+」选气泡")
        XCTAssertTrue(vm.isBubbleMode)

        // ⌘N（不带 fresh）停在同楼层空草稿上：不重建，只换成这次要的模式
        let draft = vm.selectedConversation
        vm.startNewConversation(profileId: "p", cards: nil)
        XCTAssertTrue(vm.selectedConversation === draft)
        XCTAssertEqual(vm.selectedConversation?.mode, .article)
    }

    // MARK: - 3. 同一个 ViewModel 切选中对话，isBubbleModeActive 和 Theme.chat 跟着变

    @MainActor
    func testSwitchingSelectedConversationDrivesThemeBubbleMode() async throws {
        let manager = ThemeManager.shared
        let saved = (manager.isBubbleModeActive, manager.selectedThemeId, manager.themeMode)
        defer {
            manager.isBubbleModeActive = saved.0
            manager.selectTheme(id: saved.1)
            manager.themeMode = saved.2
        }
        let copyId = try XCTUnwrap(manager.saveThemeCopy(from: AppThemeDefinition.defaultTheme.id, name: "共存二", select: true))
        defer { manager.deleteTheme(id: copyId) }
        var light = ThemeTokenSet.palaceLightDefault
        light.userBubble = ThemeColorValue(hex: 0x8A2345)
        light.bubbleModeUserBubble = ThemeColorValue(hex: 0x007AFF)
        manager.replaceTokenSet(light, for: .light, themeId: copyId)
        manager.themeMode = .light

        let container = try memoryContainer()
        let ctx = ModelContext(container)
        let a = insertConversation(ctx, id: "conv-A", pid: "p", mode: .bubble)
        let b = insertConversation(ctx, id: "conv-B", pid: "p", mode: .article)
        try ctx.save()

        let vm = ConversationViewModel()
        try await load(vm, a, ctx)
        XCTAssertTrue(vm.isBubbleMode)
        XCTAssertTrue(manager.isBubbleModeActive)
        XCTAssertEqual(Theme.chat.tokens.userBubble.hexString.lowercased(), "#007aff", "A 是气泡：聊天页用气泡模式色")
        XCTAssertEqual(Theme.chat.tokens, light.applyingBubbleModeColors())

        try await load(vm, b, ctx)
        XCTAssertFalse(vm.isBubbleMode)
        XCTAssertFalse(manager.isBubbleModeActive)
        XCTAssertEqual(Theme.chat.tokens.userBubble.hexString.lowercased(), "#8a2345", "B 是文章：聊天页取普通色")

        try await load(vm, a, ctx)
        XCTAssertTrue(manager.isBubbleModeActive, "切回 A 当场变回气泡")

        // 在对话菜单里把 A 换成文章：模式和配色当场跟着变
        vm.setDisplayMode(.article, for: a, context: ctx)
        XCTAssertFalse(vm.isBubbleMode)
        XCTAssertFalse(manager.isBubbleModeActive)
        XCTAssertEqual(Theme.chat.tokens.userBubble.hexString.lowercased(), "#8a2345")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == "conv-A" })).first?.displayMode, "article", "换模式即落库")

        // 换的不是当前选中的对话：不动聊天页配色
        vm.setDisplayMode(.bubble, for: b, context: ctx)
        XCTAssertFalse(manager.isBubbleModeActive)
        XCTAssertEqual(b.mode, .bubble)
    }

    /// 返工②：选中对象不变，外部（同步导入）直接改它的 displayMode，聊天页配色也要跟上
    @MainActor
    func testExternalDisplayModeChangeOnSelectedConversationRefreshesTheme() async throws {
        let manager = ThemeManager.shared
        let saved = (manager.isBubbleModeActive, manager.selectedThemeId, manager.themeMode)
        defer {
            manager.isBubbleModeActive = saved.0
            manager.selectTheme(id: saved.1)
            manager.themeMode = saved.2
        }
        let copyId = try XCTUnwrap(manager.saveThemeCopy(from: AppThemeDefinition.defaultTheme.id, name: "共存二外部", select: true))
        defer { manager.deleteTheme(id: copyId) }
        var light = ThemeTokenSet.palaceLightDefault
        light.userBubble = ThemeColorValue(hex: 0x8A2345)
        light.bubbleModeUserBubble = ThemeColorValue(hex: 0x007AFF)
        manager.replaceTokenSet(light, for: .light, themeId: copyId)
        manager.themeMode = .light

        let ctx = ModelContext(try memoryContainer())
        let conv = insertConversation(ctx, id: "conv-ext", pid: "p", mode: .article)
        try ctx.save()
        let vm = ConversationViewModel()
        try await load(vm, conv, ctx)
        XCTAssertFalse(manager.isBubbleModeActive)

        // 同 SyncStore.mergeDisplayMode：直接写这一列，不经过 vm
        conv.displayMode = ConversationDisplayMode.bubble.rawValue
        for _ in 0..<40 where !manager.isBubbleModeActive { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(vm.selectedConversation === conv, "选中对象没换")
        XCTAssertTrue(manager.isBubbleModeActive, "外部改了模式，配色跟着同步")
        XCTAssertEqual(Theme.chat.tokens.userBubble.hexString.lowercased(), "#007aff")

        conv.displayMode = ConversationDisplayMode.article.rawValue
        for _ in 0..<40 where manager.isBubbleModeActive { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(manager.isBubbleModeActive, "再改回来也跟着（盯梢每次重新布下）")
        XCTAssertEqual(Theme.chat.tokens.userBubble.hexString.lowercased(), "#8a2345")
    }

    @MainActor
    func testSetDisplayModeStampsTimeWithoutTouchingUpdateTime() throws {
        let ctx = ModelContext(try memoryContainer())
        let conv = insertConversation(ctx, id: "conv-stamp", pid: "p", mode: .article)
        try ctx.save()
        let updated = conv.updateTime
        XCTAssertNil(conv.displayModeUpdatedAt)
        ConversationViewModel().setDisplayMode(.bubble, for: conv, context: ctx)
        XCTAssertEqual(conv.updateTime, updated, "换模式不推进 updateTime（列表按它排）")
        let stamp = try XCTUnwrap(conv.displayModeUpdatedAt)
        XCTAssertEqual(conv.syncStamp, max(updated, stamp), "同步按内容 / 模式较新的那个判断")
    }

    // MARK: - 4. 换模式不丢分支

    @MainActor
    func testSwitchingModeKeepsBranches() async throws {
        let container = try memoryContainer()
        let ctx = ModelContext(container)
        let pid = "p"
        //   U1 ┬ A1 ─ U2 ─ A3
        //      └ A2
        let conv = Conversation(id: "branchy", title: "分支", createTime: Date(), updateTime: Date(),
                                currentNodeId: "A3", provider: "api", profileId: pid)
        ctx.insert(conv)
        let tree: [(String, String?, [String])] = [
            ("U1", nil, ["A1", "A2"]), ("A1", "U1", ["U2"]), ("A2", "U1", []), ("U2", "A1", ["A3"]), ("A3", "U2", [])
        ]
        for (id, parent, kids) in tree {
            ctx.insert(MessageNode(id: id, role: id.hasPrefix("U") ? "user" : "assistant", content: id, contentType: "text",
                                   createTime: Date(), parentId: parent, childrenIds: kids, conversationId: conv.id, profileId: pid))
        }
        try ctx.save()

        let vm = ConversationViewModel()
        try await load(vm, conv, ctx)
        vm.switchBranch(at: "U1", to: 1)
        XCTAssertEqual(vm.currentPath.map(\.id), ["U1", "A2"], "在第 2 支上")
        let path = vm.currentPath.map(\.id)
        let selection = BranchSelection.decode(conv.branchSelectionData)
        let current = conv.currentNodeId
        let branchKeys = Set(vm.branchInfoMap.keys)
        XCTAssertFalse(branchKeys.isEmpty)
        func children() throws -> [String: [String]] {
            Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<MessageNode>())
                .map { ($0.id, $0.childrenIds) })
        }
        let kids = try children()

        vm.setDisplayMode(.bubble, for: conv, context: ctx)
        XCTAssertTrue(vm.isBubbleMode)
        vm.setDisplayMode(.article, for: conv, context: ctx)
        XCTAssertFalse(vm.isBubbleMode)

        XCTAssertEqual(vm.currentPath.map(\.id), path)
        XCTAssertEqual(BranchSelection.decode(conv.branchSelectionData), selection)
        XCTAssertEqual(conv.currentNodeId, current)
        XCTAssertEqual(Set(vm.branchInfoMap.keys), branchKeys)
        XCTAssertEqual(try children(), kids, "分支数据一条没动")

        // 重开：还在第 2 支，另一支也还在
        let reader = ModelContext(container)
        let reopened = try XCTUnwrap(reader.fetch(FetchDescriptor<Conversation>()).first)
        let vm2 = ConversationViewModel()
        try await load(vm2, reopened, reader)
        XCTAssertEqual(vm2.currentPath.map(\.id), ["U1", "A2"])
        vm2.switchBranch(at: "U1", to: 0)
        XCTAssertEqual(vm2.currentPath.map(\.id), ["U1", "A1", "U2", "A3"], "另一支完整")
    }

    // MARK: - 5. 旧配置文件里带 chatBubbleMode 也能导入

    private final class NoSecrets: ConfigSecretStore {
        func allAccounts() -> [String] { [] }
        func get(account: String) -> String? { nil }
        func set(_ value: String, account: String) {}
    }

    func testImportingOldConfigWithChatBubbleModeIgnoresIt() throws {
        XCTAssertFalse(ConfigSchema.allScalarEntries.contains { $0.key == "chatBubbleMode" }, "配置项已下线")
        let defaults = makeDefaults()
        let root: [String: Any] = [
            "schema_version": 1,
            ConfigSchema.Section.appearance.rawValue: ["chatBubbleMode": "true", "hideTimestamp": true],
        ]
        XCTAssertNoThrow(try ConfigImporter.importAll(JSONSerialization.data(withJSONObject: root),
                                                      defaults: defaults, secrets: NoSecrets()))
        XCTAssertTrue(defaults.bool(forKey: "hideTimestamp"), "同一段里别的键照常导入")
        XCTAssertNil(defaults.object(forKey: "chatBubbleMode"), "旧键不写回")
    }
}
