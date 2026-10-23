import XCTest
import SwiftData
@testable import 记忆花园

/// 卡库 ⑧c：整包持久新增导入 / 恢复 / 重导 / 撤回 / 备份字段。全部合成夹具 + 临时 SQLite / 临时 suite / 临时目录，不碰 app 存储。
@MainActor
final class SillyTavernCommitTests: XCTestCase {

    // MARK: - 临时世界

    private final class World {
        let dir: URL
        let suite: String
        var container: ModelContainer!

        init(dir: URL, suite: String) throws {
            self.dir = dir
            self.suite = suite
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            container = try Self.openContainer(dir)
        }

        static func openContainer(_ dir: URL) throws -> ModelContainer {
            let schema = ProfileManager.makeFullSchema()
            let config = ModelConfiguration("t", schema: schema, url: dir.appendingPathComponent("t.store"), allowsSave: true, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: [config])
        }

        var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
        var cardsRoot: URL { dir.appendingPathComponent("blobs") }
        var libraryRoot: URL { dir.appendingPathComponent("cardlibrary") }

        /// 每次都从存储重读（相当于重启）
        func env() -> SillyTavernImportCommitter.Environment {
            var profiles = SillyTavernImportCommitter.storedProfiles(defaults, root: cardsRoot)
            if profiles.isEmpty {
                profiles = [Profile(id: "orig", name: "原楼层", emoji: "", description: "", userName: "你", assistantName: "助手")]
                try! BlobStore.set(try! JSONEncoder().encode(profiles), forKey: "savedProfiles", root: cardsRoot)
            }
            let manager = ProfileManager(container: container, profiles: profiles, currentProfile: profiles[0], loadError: nil,
                                         root: cardsRoot, defaults: defaults, sideEffectsEnabled: false)
            let cards = CharacterCardManager(root: cardsRoot, libraryRoot: libraryRoot, defaults: defaults)
            manager.characterCardManager = cards
            return .init(container: container, profiles: manager, presets: PresetManager(root: cardsRoot, defaults: defaults), cards: cards,
                         globalRegex: GlobalRegexStore(defaults: defaults), globalBooks: GlobalWorldBookManager(root: cardsRoot, defaults: defaults),
                         personas: UserPersonaStore(root: libraryRoot), sources: ImportSourceStore(root: libraryRoot),
                         defaults: defaults, cardsRoot: cardsRoot, cardLibraryRoot: libraryRoot)
        }

        /// 「崩溃」现场：此刻全部持久状态复制一份
        func clone(to target: URL) throws -> World {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for name in ["t.store", "t.store-wal", "t.store-shm", "blobs", "cardlibrary"] {
                let src = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: src.path) { try FileManager.default.copyItem(at: src, to: target.appendingPathComponent(name)) }
            }
            let suite = "\(self.suite).clone.\(UUID().uuidString.prefix(6))"
            UserDefaults(suiteName: suite)!.setPersistentDomain(defaults.persistentDomain(forName: self.suite) ?? [:], forName: suite)
            return World(clonedAt: target, suite: suite)
        }

        private init(clonedAt dir: URL, suite: String) {
            self.dir = dir
            self.suite = suite
        }

        func open() throws { container = try Self.openContainer(dir) }

        func destroy() {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private var workDir: URL!
    private var worlds: [World] = []

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("st-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        SillyTavernImportCommitter.faultHook = nil
    }

    override func tearDown() async throws {
        SillyTavernImportCommitter.faultHook = nil
        worlds.forEach { $0.destroy() }
        worlds = []
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeWorld(_ name: String = "w") throws -> World {
        let world = try World(dir: workDir.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))"), suite: "SillyTavernCommitTests.\(UUID().uuidString)")
        worlds.append(world)
        return world
    }

    // MARK: - 夹具

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    private func jsonl(_ lines: [Any]) -> Data {
        Data(lines.map { String(decoding: json($0), as: UTF8.self) }.joined(separator: "\n").utf8)
    }

    private func pngCard(_ card: [String: Any]) -> Data {
        func chunk(_ type: String, _ body: Data) -> Data {
            var out = Data()
            var length = UInt32(body.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            out.append(Data(type.utf8))
            out.append(body)
            out.append(Data(count: 4))
            return out
        }
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(chunk("tEXt", Data("chara".utf8) + Data([0]) + Data(json(card).base64EncodedString().utf8)))
        data.append(chunk("IEND", Data()))
        return data
    }

    private var aliceChat: Data {
        jsonl([
            ["user_name": "u", "character_name": "c", "chat_metadata": ["persona": "me.png"]],
            ["name": "Alice", "is_user": false, "send_date": "2025-06-03T07:24:12.123Z", "mes": "A1 显示版",
             "swipes": ["A0", "A1 源", "A2"], "swipe_id": 1, "swipe_info": [[:], [:], [:]], "variables": [["hp": 1]], "extra": [:]],
            ["name": "U", "is_user": true, "mes": "看附件", "extra": ["file": ["url": "/user/files/note.txt", "name": "note.txt"]]],
            ["name": "Alice", "is_user": false, "mes": "看图", "extra": ["image": "/user/images/Alice/gone.png"]],
            ["name": "System", "is_user": false, "is_system": true, "mes": "被隐藏", "extra": [:]],
            ["name": "Alice", "is_user": false, "mes": "末尾", "extra": [:]],
        ])
    }

    private var packageFiles: [String: Data] {
        let alice: [String: Any] = [
            "spec": "chara_card_v2",
            "data": ["name": "Alice", "first_mes": "hi",
                     "character_book": ["entries": [["keys": ["k"], "content": "c", "enabled": true, "insertion_order": 1]]],
                     "extensions": ["world": "Lore", "regex_scripts": [["scriptName": "r", "findRegex": "/a/g", "replaceString": "b"]]]],
        ]
        return [
            "settings.json": json([
                "power_user": ["personas": ["me.png": "我"], "persona_descriptions": ["me.png": ["description": "d", "lorebook": "Lore"]]],
                "extension_settings": ["regex": [["scriptName": "g", "findRegex": "/x/", "replaceString": "y", "disabled": false]]],
                "world_info_settings": ["world_info": ["globalSelect": ["Lore"]]],
            ]),
            "secrets.json": Data(#"{"api_key_openai":"SECRET"}"#.utf8),
            "characters/Alice.png": pngCard(alice),
            "characters/Bob.json": json(["spec": "chara_card_v2", "data": ["name": "Bob", "first_mes": "yo"]]),
            "characters/Alice/expression.png": Data([1, 2, 3]),
            "chats/Alice/Alice - 1.jsonl": aliceChat,
            "chats/Ghost/Ghost - 1.jsonl": jsonl([["chat_metadata": [:]], ["name": "Ghost", "is_user": false, "mes": "boo"]]),
            "worlds/Lore.json": json(["entries": ["0": ["uid": 0, "key": ["a"], "content": "x"]]]),
            "worlds/Free.json": json(["entries": ["0": ["uid": 0, "key": ["b"], "content": "y"]]]),
            "OpenAI Settings/P1.json": json(["temperature": 1, "prompts": [["identifier": "main", "name": "Main", "content": "m"]]]),
            "QuickReplies/qr.json": json(["name": "qr", "qrList": []]),
            "User Avatars/me.png": Data([9, 9]),
            "user/files/note.txt": Data("n".utf8),
            "backups/chat_Alice_1.jsonl": Data("{}".utf8),
            "extensions/plugin/index.js": Data("alert(1)".utf8),
            "groups/g1.json": json(["id": "g1", "name": "群", "members": ["Alice.png", "Bob.json"], "chats": ["gc1"], "chat_id": "gc1"]),
            "group chats/gc1.jsonl": jsonl([["chat_metadata": [:], "user_name": "u"], ["name": "Alice", "is_user": false, "mes": "群1"]]),
        ]
    }

    private func plan(_ files: [String: Data]? = nil) throws -> SillyTavernPackagePlan {
        let root = workDir.appendingPathComponent("pkg-\(UUID().uuidString.prefix(6))/default-user")
        for (path, data) in files ?? packageFiles {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let staging = workDir.appendingPathComponent("staging-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return try SillyTavernPackageImporter.inventory(source: root, stagingParent: staging)
    }

    private func conversations(_ world: World) throws -> [Conversation] {
        try ModelContext(world.container).fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.provider == "sillytavern" }))
    }

    private func nodes(_ world: World, _ conversationId: String) throws -> [MessageNode] {
        try ModelContext(world.container).fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == conversationId }))
    }

    /// 存储里的对象数快照（恢复 / 撤回前后比对）
    private func fingerprint(_ world: World) throws -> String {
        let context = ModelContext(world.container)
        let store = ImportSourceStore(root: world.libraryRoot)
        let blobs = (FileManager.default.enumerator(atPath: store.archiveDirectory.path)?.allObjects as? [String] ?? [])
            .filter { $0.split(separator: "/").count == 2 }.count
        return [
            SillyTavernImportCommitter.storedProfiles(world.defaults, root: world.cardsRoot).count,
            try context.fetchCount(FetchDescriptor<Conversation>()), try context.fetchCount(FetchDescriptor<MessageNode>()),
            try context.fetchCount(FetchDescriptor<WorldBook>()),
            CharacterCardManager(root: world.cardsRoot, libraryRoot: world.libraryRoot, defaults: world.defaults).cards.count,
            PresetManager(root: world.cardsRoot, defaults: world.defaults).presets.count, GlobalWorldBookManager(root: world.cardsRoot, defaults: world.defaults).books.count,
            GlobalRegexStore(defaults: world.defaults).scripts.count, UserPersonaStore(root: world.libraryRoot).personas.count,
            store.sources.count, blobs, (try store.pendingBatch()) == nil ? 0 : 1,
        ].map(String.init).joined(separator: "/")
    }

    // MARK: - 提交

    func testCommitCreatesObjectsBindingsAndReport() throws {
        let world = try makeWorld()
        let env = world.env()
        let report = try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "测试"), env: env)

        // 卡：两张都存；Alice 有聊天 → 唯一新楼层并绑定；Bob 没聊天只存卡；许可 unknown
        let cards = CharacterCardManager(root: world.cardsRoot, libraryRoot: world.libraryRoot, defaults: world.defaults).cards
        XCTAssertEqual(cards.count, 2)
        let alice = try XCTUnwrap(cards.first { $0.name == "Alice" })
        XCTAssertEqual(alice.bindingState, .active)
        XCTAssertNil(cards.first { $0.name == "Bob" }?.linkedProfileId)
        XCTAssertTrue(cards.allSatisfy { $0.extensionConsent == .unknown })
        XCTAssertEqual(alice.regexScripts.count, 1, "卡规则留卡上")

        // 楼层：Alice + 缺卡占位 Ghost + 群聊归档；默认不切楼层
        let profiles = SillyTavernImportCommitter.storedProfiles(world.defaults, root: world.cardsRoot)
        XCTAssertEqual(profiles.count, 4)
        XCTAssertEqual(env.profiles.currentProfile.id, "orig")
        XCTAssertEqual(env.profiles.profiles.count, 4, "提交后发布进列表")
        XCTAssertEqual(report.numbers.placeholderFloors, 1)
        XCTAssertEqual(report.numbers.groupArchiveFloors, 1)

        // 对话：Alice 1、Ghost 1、群聊 1；群聊只读归档、不进记忆
        let all = try conversations(world)
        XCTAssertEqual(all.count, 3)
        let group = try XCTUnwrap(all.first { $0.archiveKind != nil })
        XCTAssertTrue(group.isReadOnlyArchive)
        XCTAssertFalse(group.memoryEnabled)
        let aliceChat = try XCTUnwrap(all.first { $0.profileId == alice.linkedProfileId })
        XCTAssertTrue(aliceChat.memoryEnabled)
        XCTAssertNotNil(aliceChat.personaId, "聊天 header persona → 身份 id")
        XCTAssertNotNil(aliceChat.sourceMetadata)

        // 节点：合成根 + 3 候选 + 4 条；mes≠选中 swipe 两份都在；隐藏消息不进显示 / API
        let aliceNodes = try nodes(world, aliceChat.id)
        XCTAssertEqual(aliceNodes.count, 1 + 3 + 4)
        let selected = try XCTUnwrap(aliceNodes.first { $0.content == "A1 显示版" })
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(selected.sourceMetadata)) as? [String: Any])
        XCTAssertEqual(meta["sourceSwipeText"] as? String, "A1 源")
        XCTAssertNotNil(meta["rawLine"])
        XCTAssertNotNil((meta["fields"] as? [String: Any])?["variables"])
        let hidden = try XCTUnwrap(aliceNodes.first { $0.content == "被隐藏" })
        XCTAssertEqual(hidden.sourceVisibility, "hidden")
        XCTAssertFalse(hidden.hasDisplayableContent)
        XCTAssertFalse(PromptAssembler.historyNodes(aliceNodes).contains { $0.id == hidden.id || $0.isSyntheticRoot })
        XCTAssertEqual(aliceChat.nodeCount, 4, "显示计数只数当前分支，不含合成根、隐藏和没选中的 swipe")
        let resolution = BranchSelection.resolve(links: aliceNodes.map { .init(id: $0.id, parentId: $0.parentId, childrenIds: $0.childrenIds) },
                                                 selection: BranchSelection.decode(aliceChat.branchSelectionData),
                                                 legacyCurrentNodeId: aliceChat.currentNodeId)
        XCTAssertFalse(resolution.changed)
        XCTAssertEqual(resolution.leafId, aliceChat.currentNodeId)

        // 附件：在包里的 → 受控资源 ID；缺的 → 占位 + 报告
        let fileNode = try XCTUnwrap(aliceNodes.first { $0.content == "看附件" })
        let fileMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fileNode.sourceMetadata)) as? [String: Any])
        XCTAssertTrue(((fileMeta["attachments"] as? [[String: Any]])?.first?["resource"] as? String)?.hasPrefix("archive:") == true)
        let imageNode = try XCTUnwrap(aliceNodes.first { $0.content == "看图" })
        let imageMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(imageNode.sourceMetadata)) as? [String: Any])
        XCTAssertEqual((imageMeta["attachments"] as? [[String: Any]])?.first?["missing"] as? Bool, true)
        XCTAssertEqual(report.numbers.attachmentRefsResolved, 1)
        XCTAssertEqual(report.numbers.attachmentRefsMissing, 1)
        XCTAssertTrue(report.issues.contains { $0.action.contains("留占位") && $0.line != nil })

        // 世界书：Lore 被全局 + 卡引用 → 全局书开着 + Alice 楼层一份；Free 没绑 → 全局停用；卡内书进楼层
        let globals = GlobalWorldBookManager(root: world.cardsRoot, defaults: world.defaults).books
        XCTAssertEqual(globals.first { $0.name == "Lore" }?.isEnabled, true)
        XCTAssertEqual(globals.first { $0.name == "Free" }?.isEnabled, false)
        let pid = try XCTUnwrap(alice.linkedProfileId)
        let floorBooks = try ModelContext(world.container).fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == pid }))
        XCTAssertEqual(floorBooks.count, 2)
        XCTAssertEqual(Set(profiles.first { $0.id == pid }!.linkedWorldBookIDs), Set(floorBooks.map(\.id.uuidString)))

        // 全局正则默认关；预设模板；身份带头像 + 书引用
        XCTAssertEqual(GlobalRegexStore(defaults: world.defaults).scripts.map(\.disabled), [true])
        XCTAssertEqual(PresetManager(root: world.cardsRoot, defaults: world.defaults).templates.filter { $0.name == "P1" }.count, 1)
        let personas = UserPersonaStore(root: world.libraryRoot)
        let me = try XCTUnwrap(personas.personas.first)
        XCTAssertEqual(me.id, aliceChat.personaId)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(personas.avatarURL(me))), Data([9, 9]))
        XCTAssertTrue(me.worldSourceRefs.contains { $0.hasPrefix("global:") })

        // 来源清单 = 报告 = 实际；凭据不归档；QR / 扩展 / 备份只归档
        let source = try XCTUnwrap(ImportSourceStore(root: world.libraryRoot).sources.first)
        for kind in ImportTarget.Kind.allCases {
            let ids = Set(source.files.values.flatMap { $0 }.flatMap(\.targets).filter { $0.kind == kind }.map(\.id))
            XCTAssertEqual(ids.count, report.objects[kind.rawValue], kind.rawValue)
        }
        XCTAssertEqual(report.objects["conversation"], 3)
        XCTAssertEqual(report.objects["card"], 2)
        XCTAssertNil(source.files["secrets.json"])
        XCTAssertEqual(source.files["QuickReplies/qr.json"]?.last?.disposition, .archivedOnly)
        XCTAssertTrue(ImportSourceStore(root: world.libraryRoot).hasArchived(try XCTUnwrap(source.files["extensions/plugin/index.js"]?.last?.sha256)))
        XCTAssertTrue(source.liveTargets("characters/Alice.png").map(\.kind).contains(.floor))
        XCTAssertTrue(source.files.values.flatMap { $0 }.flatMap(\.targets).filter { $0.kind != .attachment }.allSatisfy { !$0.contentHash.isEmpty })
        XCTAssertNil(try ImportSourceStore(root: world.libraryRoot).pendingBatch())
        let reportText = String(decoding: try Data(contentsOf: ImportSourceStore(root: world.libraryRoot).reportsDirectory
            .appendingPathComponent("\(report.batchId).json")), as: UTF8.self)
        XCTAssertFalse(reportText.contains("A1 显示版") || reportText.contains("SECRET"), "报告不含正文 / 凭据")
        XCTAssertEqual(report.numbers.messagesWithSwipes, 1)
        XCTAssertEqual(report.numbers.multiCandidateMessages, 1)
    }

    func testGroupArchiveBlocksSendFlag() throws {
        let conversation = Conversation(id: "g", title: "g", createTime: Date(), updateTime: Date(), currentNodeId: "")
        XCTAssertFalse(conversation.isReadOnlyArchive)
        conversation.archiveKind = Conversation.groupReadOnlyArchive
        XCTAssertTrue(conversation.isReadOnlyArchive)
    }

    // MARK: - 重导

    func testReimportSkipsSameHashAndChangedFileKeepsTwoVersions() throws {
        let world = try makeWorld()
        let first = try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "测试"), env: world.env())
        let after = try fingerprint(world)
        let sourceId = first.sourceId

        let again = try SillyTavernImportCommitter.commit(plan: try plan(), source: .existing(id: sourceId), env: world.env())
        XCTAssertEqual(try fingerprint(world), after, "同来源同文件同 hash：零增量")
        XCTAssertEqual(again.objects.values.reduce(0, +), 0)
        XCTAssertEqual(again.categories.reduce(0) { $0 + $1.created }, 0)

        var files = packageFiles
        files["chats/Alice/Alice - 1.jsonl"] = aliceChat + Data("\n{\"name\":\"U\",\"is_user\":true,\"mes\":\"新的一行\"}".utf8)
        files["worlds/New.json"] = json(["entries": ["0": ["uid": 0, "key": ["n"], "content": "z"]]])
        let changed = try SillyTavernImportCommitter.commit(plan: try plan(files), source: .existing(id: sourceId), env: world.env())
        XCTAssertEqual(changed.categories.first { $0.key == "chat" }?.changed, 1)
        XCTAssertEqual(changed.objects["conversation"], 0, "变化不覆盖、不再造一套")
        XCTAssertEqual(changed.objects["globalWorldBook"], 1, "新路径按新文件导入")
        XCTAssertEqual(try conversations(world).count, 3)
        let versions = try XCTUnwrap(ImportSourceStore(root: world.libraryRoot).source(id: sourceId)?.files["chats/Alice/Alice - 1.jsonl"])
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.last?.disposition, .changedArchived)
        XCTAssertTrue(versions.allSatisfy { ImportSourceStore(root: world.libraryRoot).hasArchived($0.sha256) })
        XCTAssertTrue(changed.issues.contains { $0.relativePath == "chats/Alice/Alice - 1.jsonl" && $0.action.contains("未覆盖") && $0.archivePath != nil })
    }

    /// 盘点时排除：报告写排除原因；同来源再导时取消排除就能导进来（⑧c 界面）
    func testExcludedFileReportedAndImportableLater() throws {
        let world = try makeWorld()
        let ghost = "chats/Ghost/Ghost - 1.jsonl"
        let first = try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "测试"), excluded: [ghost], env: world.env())
        XCTAssertEqual(first.numbers.placeholderFloors, 0)
        XCTAssertEqual(first.categories.first { $0.key == "chat" }?.excluded, 1)
        XCTAssertTrue(first.issues.contains { $0.relativePath == ghost && $0.reason.hasPrefix("盘点时排除：没有对应的卡") && $0.retryable && $0.archivePath != nil })
        XCTAssertFalse(first.issues.contains { $0.relativePath == "chats/Ghost" }, "排除了就不再报「建占位楼层」")

        let again = try SillyTavernImportCommitter.commit(plan: try plan(), source: .existing(id: first.sourceId), excluded: [ghost], env: world.env())
        XCTAssertEqual(again.objects.values.reduce(0, +), 0, "再排除一次：零增量")

        let third = try SillyTavernImportCommitter.commit(plan: try plan(), source: .existing(id: first.sourceId), env: world.env())
        XCTAssertEqual(third.objects["conversation"], 1, "取消排除：按新文件导入")
        XCTAssertEqual(third.numbers.placeholderFloors, 1)
        XCTAssertEqual(third.categories.reduce(0) { $0 + $1.created }, 1)
        XCTAssertEqual(ImportSourceStore(root: world.libraryRoot).source(id: first.sourceId)?.files[ghost]?.last?.disposition, .imported)
    }

    // MARK: - 撤回

    func testRetractKeepsEditedConversationItsFloorAndCardDeletesRest() throws {
        let world = try makeWorld()
        let env = world.env()
        let before = try fingerprint(world)
        let report = try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "测试"), env: env)
        let alice = try XCTUnwrap(CharacterCardManager(root: world.cardsRoot, libraryRoot: world.libraryRoot, defaults: world.defaults).cards.first { $0.name == "Alice" })
        let pid = try XCTUnwrap(alice.linkedProfileId)
        let context = ModelContext(world.container)
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == pid })).first)
        let leafId = conversation.currentNodeId
        let leaf = try XCTUnwrap(context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == leafId })).first)
        let added = MessageNode(id: "new-msg", role: "user", content: "导入后新说的", contentType: "text", createTime: Date(),
                                parentId: leaf.id, childrenIds: [], conversationId: conversation.id, profileId: pid)
        leaf.childrenIds.append(added.id)
        context.insert(added)
        conversation.currentNodeId = added.id
        try context.save()

        let retract = try SillyTavernImportCommitter.retract(sourceId: report.sourceId, env: world.env())
        XCTAssertEqual(try conversations(world).map(\.id), [conversation.id])
        XCTAssertTrue(SillyTavernImportCommitter.storedProfiles(world.defaults, root: world.cardsRoot).contains { $0.id == pid })
        let cards = CharacterCardManager(root: world.cardsRoot, libraryRoot: world.libraryRoot, defaults: world.defaults).cards
        XCTAssertEqual(cards.map(\.name), ["Alice"], "绑定楼层留下的卡留；Bob 删")
        let kept = Dictionary(grouping: retract.items.filter { $0.action == .kept }, by: \.kind)
        XCTAssertEqual(kept["conversation"]?.first?.reason, "导入后有新消息或改动")
        XCTAssertEqual(kept["floor"]?.first?.reason, "有保留的对话")
        XCTAssertNotNil(kept["persona"], "保留的对话用着这个身份")
        XCTAssertTrue(kept["globalWorldBook"]?.contains { $0.reason == "保留的身份绑着它" } == true)
        // 其余：占位楼层、群聊归档楼层与对话、Bob、预设模板、Free、全局正则都删
        XCTAssertEqual(SillyTavernImportCommitter.storedProfiles(world.defaults, root: world.cardsRoot).count, 2)
        XCTAssertEqual(PresetManager(root: world.cardsRoot, defaults: world.defaults).templates.filter { $0.name == "P1" }.count, 0)
        XCTAssertNil(GlobalWorldBookManager(root: world.cardsRoot, defaults: world.defaults).books.first { $0.name == "Free" })
        XCTAssertTrue(GlobalRegexStore(defaults: world.defaults).scripts.isEmpty)
        XCTAssertEqual(retract.items.count, Set(retract.items.map(\.id)).count, "逐项、每个目标一条")
        // 原件、报告保留；来源记录标撤回
        let store = ImportSourceStore(root: world.libraryRoot)
        XCTAssertNotNil(store.source(id: report.sourceId)?.batches.first?.retractedAt)
        XCTAssertNoThrow(try store.readReport(SillyTavernImportReport.self, file: "\(report.batchId).json"))
        XCTAssertNotEqual(try fingerprint(world), before)

        // 再撤一次：已撤的不再处理，留下的照旧留
        let second = try SillyTavernImportCommitter.retract(sourceId: report.sourceId, env: world.env())
        XCTAssertEqual(second.count(.deleted), 0)
    }

    // MARK: - 失败 / 崩溃恢复

    func testInjectedFailureRollsBackEverythingAndKeepsOriginals() throws {
        for point in ["afterArchive", "afterObjects", "afterSources"] {
            let world = try makeWorld(point)
            try seedOriginals(world)
            let before = try fingerprint(world)
            SillyTavernImportCommitter.faultHook = { if $0 == point { throw CocoaError(.fileWriteUnknown) } }
            XCTAssertThrowsError(try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "测试"), env: world.env()), point)
            SillyTavernImportCommitter.faultHook = nil
            XCTAssertEqual(try fingerprint(world), before, "[\(point)] 进程内失败按清单清干净")
            try assertOriginals(world)
        }
    }

    func testCrashSnapshotsRecoverWithoutResidueOrResume() throws {
        for point in ["afterBatch", "afterObjects", "afterSources", "afterCommitted"] {
            let world = try makeWorld(point)
            try seedOriginals(world)
            let before = try fingerprint(world)
            var crashed: World?
            SillyTavernImportCommitter.faultHook = { name in
                guard name == point else { return }
                crashed = try world.clone(to: self.workDir.appendingPathComponent("crash-\(point)-\(UUID().uuidString.prefix(4))"))
            }
            _ = try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "测试"), env: world.env())
            SillyTavernImportCommitter.faultHook = nil
            let finished = try fingerprint(world)
            // 「重启」：从崩溃那一刻的存储重开
            let restarted = try XCTUnwrap(crashed)
            worlds.append(restarted)
            try restarted.open()
            XCTAssertEqual(try fingerprint(restarted).split(separator: "/").last, "1", "[\(point)] 崩溃现场留着批次")
            let outcome = try SillyTavernImportCommitter.recover(env: restarted.env())
            if point == "afterCommitted" {
                XCTAssertEqual(outcome, .finished(batchId: try XCTUnwrap(ImportSourceStore(root: restarted.libraryRoot).sources.first?.batches.first?.id)))
                XCTAssertEqual(try fingerprint(restarted), finished, "[\(point)] 已提交：幂等续完，与正常完成一致")
            } else {
                XCTAssertEqual(try fingerprint(restarted), before, "[\(point)] 未提交：清掉本批全部新增")
            }
            try assertOriginals(restarted)
        }
    }

    func testNewCommitRefusedWhileBatchPending() throws {
        let world = try makeWorld()
        SillyTavernImportCommitter.faultHook = { if $0 == "afterCommitted" { throw CocoaError(.fileWriteUnknown) } }
        XCTAssertThrowsError(try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "测试"), env: world.env()))
        SillyTavernImportCommitter.faultHook = nil
        XCTAssertThrowsError(try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "再来"), env: world.env())) {
            guard case SillyTavernImportCommitter.Failure.batchPending = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertNotEqual(try SillyTavernImportCommitter.recover(env: world.env()), .none)
        XCTAssertNoThrow(try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "再来"), env: world.env()))
    }

    private func seedOriginals(_ world: World) throws {
        let env = world.env()
        let (conversation, nodes) = CharacterFloorService.makeChat(title: "原对话", greetings: ["原开场"], profileId: "orig")
        let context = ModelContext(world.container)
        context.insert(conversation)
        nodes.forEach { context.insert($0) }
        context.insert(WorldBook(name: "原书", profileId: "orig"))
        try context.save()
        try env.cards.add(CharacterCard(from: try TavernCard.parseJSON(data: json(["spec": "chara_card_v2", "data": ["name": "原卡"]]))))
        try env.presets.persistNew([Preset(id: "orig-preset", name: "原预设")])
        try env.globalBooks.add(contentsOf: [GlobalWorldBook(id: "orig-book", name: "原全局书")])
        var script = RegexScript()
        script.id = "orig-regex"
        try env.globalRegex.save([script])
        try env.personas.add([UserPersona(id: "orig-persona", name: "原身份")])
    }

    private func assertOriginals(_ world: World, file: StaticString = #filePath, line: UInt = #line) throws {
        let context = ModelContext(world.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == "orig" })), 1, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == "orig" })), 1, file: file, line: line)
        XCTAssertTrue(CharacterCardManager(root: world.cardsRoot, libraryRoot: world.libraryRoot, defaults: world.defaults).cards.contains { $0.name == "原卡" }, file: file, line: line)
        XCTAssertNotNil(PresetManager(root: world.cardsRoot, defaults: world.defaults).preset(byId: "orig-preset"), file: file, line: line)
        XCTAssertTrue(GlobalWorldBookManager(root: world.cardsRoot, defaults: world.defaults).books.contains { $0.id == "orig-book" }, file: file, line: line)
        XCTAssertTrue(GlobalRegexStore(defaults: world.defaults).scripts.contains { $0.id == "orig-regex" }, file: file, line: line)
        XCTAssertTrue(UserPersonaStore(root: world.libraryRoot).personas.contains { $0.id == "orig-persona" }, file: file, line: line)
        XCTAssertTrue(SillyTavernImportCommitter.storedProfiles(world.defaults, root: world.cardsRoot).contains { $0.id == "orig" }, file: file, line: line)
    }

    // MARK: - 旧导入器兼容（缺新键）

    func testLegacyPayloadWithoutNewKeysKeepsSemantics() throws {
        let node = ImportedNodePayload(id: "n1", role: "user", content: "hi", contentType: "text", createTime: nil, parentId: nil, childrenIds: [])
        let made = makeImportedNode(node, conversationId: "c", profileId: "p")
        XCTAssertNil(made.sourceMetadata)
        XCTAssertNil(made.sourceVisibility)
        made.sourceMetadata = Data("{}".utf8)
        made.sourceVisibility = "narrator"
        XCTAssertFalse(importedNodeDiffers(from: made, incoming: node), "缺键不算差异")
        applyImportedNode(node, to: made)
        XCTAssertEqual(made.sourceMetadata, Data("{}".utf8), "缺键不清本地值")
        XCTAssertEqual(made.sourceVisibility, "narrator")

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ImportedConversationPayload(id: "c", title: "t", createTime: date, updateTime: date, currentNodeId: "n1",
                                                  provider: "chatgpt", nodes: [node])
        let conversation = Conversation(id: "c", title: "t", createTime: date, updateTime: date, currentNodeId: "n1")
        conversation.personaId = "keep"
        XCTAssertFalse(importedConversationMetadataDiffers(from: conversation, incoming: payload))
        applyImportedConversationMetadata(payload, to: conversation, nodeCount: 1)
        XCTAssertEqual(conversation.personaId, "keep")
        XCTAssertNil(conversation.archiveKind)

        var tagged = payload
        tagged.personaId = "p1"
        tagged.sourceMetadata = Data("m".utf8)
        let copy = payloadAsCopy(tagged, profileId: "profile-x")
        XCTAssertEqual(copy.personaId, "p1")
        XCTAssertEqual(copy.sourceMetadata, Data("m".utf8))
        XCTAssertEqual(copy.nodes.first?.id, copyId("n1", profileId: "profile-x"))

        // 旧撤销快照（无新键）照样解码
        let oldSnapshot = #"{"id":"c","title":"t","createTime":0,"updateTime":0,"currentNodeId":"n1","isFavorite":false,"nodeCount":1,"isDeleted":false,"provider":"chatgpt"}"#
        let snapshot = try JSONDecoder().decode(ConversationSnapshot.self, from: Data(oldSnapshot.utf8))
        XCTAssertNil(snapshot.personaId)
        let oldNode = #"{"id":"n1","role":"user","content":"hi","contentType":"text","childrenIds":[],"conversationId":"c","isFavorite":false,"isDeleted":false}"#
        XCTAssertNil(try JSONDecoder().decode(MessageNodeSnapshot.self, from: Data(oldNode.utf8)).sourceVisibility)
    }

    // MARK: - 备份字段 + 目录

    func testFullBackupDocumentsRoundTripNewFieldsAndOldDocumentsDecode() throws {
        let conversation = Conversation(id: "c", title: "t", createTime: Date(timeIntervalSince1970: 1), updateTime: Date(timeIntervalSince1970: 2),
                                        currentNodeId: "n", provider: "sillytavern", profileId: "p")
        conversation.personaId = "persona"
        conversation.archiveKind = Conversation.groupReadOnlyArchive
        conversation.sourceMetadata = Data("conv-meta".utf8)
        let node = MessageNode(id: "n", role: "assistant", content: "x", contentType: "text", createTime: nil, parentId: nil,
                               childrenIds: [], conversationId: "c", profileId: "p")
        node.sourceMetadata = Data("node-meta".utf8)
        node.sourceVisibility = "hidden"
        let doc = FullConversationDocument(model: conversation, nodes: [node])
        let decoded = try JSONDecoder().decode(FullConversationDocument.self, from: JSONEncoder().encode(doc))
        let restored = decoded.toConversationModel()
        XCTAssertEqual(restored.personaId, "persona")
        XCTAssertEqual(restored.archiveKind, Conversation.groupReadOnlyArchive)
        XCTAssertEqual(restored.sourceMetadata, Data("conv-meta".utf8))
        let restoredNode = try XCTUnwrap(decoded.nodes.first?.toNodeModel())
        XCTAssertEqual(restoredNode.sourceMetadata, Data("node-meta".utf8))
        XCTAssertEqual(restoredNode.sourceVisibility, "hidden")
        XCTAssertTrue(restoredNode.isSourceHidden)

        // 旧备份（无新键）照样解码为 nil
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as? [String: Any])
        for key in ["personaId", "archiveKind", "sourceMetadata"] { raw.removeValue(forKey: key) }
        var rawNode = try XCTUnwrap((raw["nodes"] as? [[String: Any]])?.first)
        rawNode.removeValue(forKey: "sourceMetadata")
        rawNode.removeValue(forKey: "sourceVisibility")
        raw["nodes"] = [rawNode]
        let old = try JSONDecoder().decode(FullConversationDocument.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(old.toConversationModel().personaId)
        XCTAssertNil(old.nodes.first?.toNodeModel().sourceVisibility)

        // SchemaCoverageCheck：新列 Model ↔ Document 一一覆盖
        let modelFields = Set(SchemaCoverageCheck.modelFieldNames(conversation))
        XCTAssertTrue(modelFields.isSuperset(of: ["personaId", "archiveKind", "sourceMetadata"]))
        let docFields = Set(SchemaCoverageCheck.documentFieldNames(sample: doc))
        XCTAssertTrue(docFields.isSuperset(of: ["personaId", "archiveKind", "sourceMetadata"]))
        XCTAssertTrue(Set(SchemaCoverageCheck.modelFieldNames(node)).isSuperset(of: ["sourceMetadata", "sourceVisibility"]))
        XCTAssertTrue(Set(SchemaCoverageCheck.documentFieldNames(sample: FullNodeDocument(model: node))).isSuperset(of: ["sourceMetadata", "sourceVisibility"]))
    }

    /// cardlibrary/ 整目录搬到别处（= 全量备份导出 → 恢复）后照样能读：内部只存相对路径
    func testCardLibraryDirectoryIsRelocatable() throws {
        let world = try makeWorld()
        let report = try SillyTavernImportCommitter.commit(plan: try plan(), source: .new(name: "测试"), env: world.env())
        let moved = workDir.appendingPathComponent("restored/cardlibrary")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: world.libraryRoot, to: moved)
        let personas = UserPersonaStore(root: moved)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(personas.personas.first.flatMap(personas.avatarURL))), Data([9, 9]))
        let sources = ImportSourceStore(root: moved)
        XCTAssertEqual(sources.sources.first?.id, report.sourceId)
        XCTAssertTrue(sources.sources.first!.files.values.flatMap { $0 }.allSatisfy { sources.hasArchived($0.sha256) })
        XCTAssertNoThrow(try sources.readReport(SillyTavernImportReport.self, file: "\(report.batchId).json"))
    }

    // MARK: - 身份库

    func testPersonaStoreRefusesOverwriteWhenUnreadable() throws {
        let root = workDir.appendingPathComponent("p")
        let store = UserPersonaStore(root: root)
        try store.add([UserPersona(id: "a", name: "甲", avatarAssetRef: "avatars/a.png")], avatars: ["a": Data([1])])
        XCTAssertEqual(UserPersonaStore(root: root).personas.map(\.name), ["甲"])
        try store.remove(ids: ["a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("personas/avatars/a.png").path))
        try Data("坏".utf8).write(to: root.appendingPathComponent("personas/personas.json"))
        let broken = UserPersonaStore(root: root)
        XCTAssertThrowsError(try broken.add([UserPersona(name: "乙")]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("personas/personas.json")), Data("坏".utf8))
    }
}

// MARK: - ③-4 楼层身份（settings 关联 / 默认身份）

extension SillyTavernCommitTests {
    private func personaPackage(connectCarolTo carolPersona: String? = nil, extraCard: String? = nil) -> [String: Data] {
        func card(_ name: String) -> Data { json(["spec": "chara_card_v2", "data": ["name": name, "first_mes": "hi"]]) }
        func chat(_ name: String) -> Data {
            jsonl([["user_name": "u", "character_name": name, "chat_metadata": [:]], ["name": name, "is_user": false, "mes": "在"]])
        }
        var descriptions: [String: Any] = [
            "me.png": ["description": "d1", "connections": [["type": "character", "id": "Alice.json"], ["type": "character", "id": "Dave.json"]]],
            "you.png": ["description": "d2"],
            "x.png": ["description": "d3", "connections": [["type": "character", "id": "Dave.json"], ["type": "character", "id": "Bob.json"]]],
        ]
        if let carolPersona {
            descriptions[carolPersona] = ["description": "改", "connections": [["type": "character", "id": "Carol.json"]]]
        }
        var files: [String: Data] = [
            "settings.json": json(["power_user": ["personas": ["me.png": "我", "you.png": "你二", "x.png": "叉"],
                                                  "persona_descriptions": descriptions, "default_persona": "you.png"]]),
            "characters/Alice.json": card("Alice"), "characters/Carol.json": card("Carol"),
            "characters/Dave.json": card("Dave"), "characters/Bob.json": card("Bob"),
            "chats/Alice/Alice - 1.jsonl": chat("Alice"), "chats/Carol/Carol - 1.jsonl": chat("Carol"),
            "chats/Dave/Dave - 1.jsonl": chat("Dave"), "chats/Ghost/Ghost - 1.jsonl": chat("Ghost"),
        ]
        if let extraCard {
            files["characters/\(extraCard).json"] = card(extraCard)
            files["chats/\(extraCard)/\(extraCard) - 1.jsonl"] = chat(extraCard)
        }
        return files
    }

    /// 楼层名 → 楼层身份名（"-" = 没指定）
    private func floorPersonas(_ world: World) -> [String: String] {
        let personas = UserPersonaStore(root: world.libraryRoot).personas
        var out: [String: String] = [:]
        for profile in SillyTavernImportCommitter.storedProfiles(world.defaults, root: world.cardsRoot) where profile.id != "orig" {
            out[profile.name] = profile.personaId.map { id in personas.first { $0.id == id }?.name ?? "?" } ?? "-"
        }
        return out
    }

    func testFloorPersonaFromConnectionsAndDefaultOnlyForNewFloors() throws {
        let world = try makeWorld()
        let report = try SillyTavernImportCommitter.commit(plan: try plan(personaPackage()), source: .new(name: "身份"), env: world.env())
        XCTAssertEqual(floorPersonas(world), ["Alice": "我", "Carol": "你二", "Dave": "-", "Ghost": "你二"],
                       "连着的用连着的；没连的用默认身份；一张卡连两个身份不猜")
        XCTAssertTrue(report.issues.contains { $0.reason == "「Dave.json」连了 2 个身份" })
        XCTAssertTrue(report.issues.contains { $0.reason == "身份连着「Bob.json」，这次没给它新建楼层" })
        XCTAssertTrue(try conversations(world).allSatisfy { $0.personaId == nil }, "聊天 header 没身份就不写对话身份（楼层身份不抄进对话）")

        // 重导：settings 变了只归档、Carol 改连 x → 已导入的楼层不追溯；新卡 Eve 的楼层也不按变了的 settings 落身份
        _ = try SillyTavernImportCommitter.commit(plan: try plan(personaPackage(connectCarolTo: "x.png", extraCard: "Eve")),
                                                  source: .existing(id: report.sourceId), env: world.env())
        let after = floorPersonas(world)
        XCTAssertEqual(after["Carol"], "你二")
        XCTAssertEqual(after["Eve"], "-")
    }

    func testRetractKeepsPersonaStillUsedByKeptFloor() throws {
        let world = try makeWorld()
        let env = world.env()
        let report = try SillyTavernImportCommitter.commit(plan: try plan(personaPackage()), source: .new(name: "身份"), env: env)
        var carol = try XCTUnwrap(env.profiles.profiles.first { $0.name == "Carol" })
        carol.description = "她改过"
        env.profiles.updateProfile(carol)
        let retract = try SillyTavernImportCommitter.retract(sourceId: report.sourceId, env: world.env())
        XCTAssertTrue(retract.items.contains { $0.action == .kept && $0.kind == "persona" && $0.reason == "还有楼层用这个身份" })
        XCTAssertEqual(UserPersonaStore(root: world.libraryRoot).personas.map(\.name), ["你二"], "只留还在的楼层用着的那个")
    }
}
