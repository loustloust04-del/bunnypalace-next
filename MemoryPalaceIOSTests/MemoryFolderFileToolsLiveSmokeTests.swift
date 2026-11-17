import SwiftData
import XCTest
@testable import 记忆花园

/// 助手用**文件工具**写记忆、改 Prompt 的真调模型冒烟：只证明这条路存在、跑得通（不看写得好不好）。全虚构的皮影作坊。
/// 走聊天页那条真路：`ConversationViewModel.sendMessage` → 模型自己调 `fs_write / fs_edit / fs_delete` → 工具循环头按「写的是哪一种」分域的权限闸 →
/// `FileLibraryTools.run` → `MemoryFolderWrite` / `PromptFolderTools`。
/// 记忆条目五步（同 `MemoryCardToolLiveSmokeTests`，只是换成文件工具）：
///   1 自动允许：fs_write 新建一份 = 加一张卡，不问；
///   2 每次询问 + 拒绝：fs_edit 改不动，卡没变、没记日志；
///   3 每次询问 + 允许这一次：改成了；一笔一问，不往对话授权里记；
///   4 不允许：fs_delete 被闸拒，卡没变；
///   5 自动允许：fs_delete = 进 Deleted，再 Undo 那一笔放回来。
/// 助手设定四步：
///   6 每次询问 + 拒绝：`.prompt/fields/characterDescription.txt` 没变、历史里没有新的一版；
///   7 每次询问 + 允许这一次：写进去了；历史里两版（写之前、写之后，写之后那版标着助手名）；
///   8 不允许：被闸拒，没变；
///   9 回到上一版：把历史里上一版存回去（她在编辑页的历史里点恢复走的就是 `PromptFolder.save`）。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里换进请求头；模型默认 Haiku（TEST_RUNNER_MP_STREAM_LIVE_MODEL 可换）。
/// 日志只打布尔 / 计数 / 这几份虚构内容，不打请求体
@MainActor
final class MemoryFolderFileToolsLiveSmokeTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialId: String?
    private var permSuite: String?
    private var previousPermDefaults: UserDefaults?
    private var floorToRemove: String?
    private var scratch: URL?
    private var managerSuite: String?

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "MemoryFolderFileToolsLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 900
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = "api.anthropic.com"
        try CatalogLiveAuthProtocol.install()
        // 档位换到一次性 suite，不碰宿主的 perm.*
        let suite = "xctest-memory-files-live-\(UUID().uuidString)"
        permSuite = suite
        previousPermDefaults = PermissionCenter.defaults
        PermissionCenter.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        if let credentialId { manager?.removeCredential(id: credentialId) }
        manager = nil
        credentialId = nil
        CatalogLiveAuthProtocol.onOutgoingBody = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
        if let previousPermDefaults { PermissionCenter.defaults = previousPermDefaults }
        previousPermDefaults = nil
        if let permSuite { UserDefaults(suiteName: permSuite)?.removePersistentDomain(forName: permSuite) }
        permSuite = nil
        if let managerSuite { UserDefaults(suiteName: managerSuite)?.removePersistentDomain(forName: managerSuite) }
        managerSuite = nil
        PromptFolderTools.profiles = nil
        PromptFolderTools.presets = nil
        PromptFolderTools.versionStore = .shared
        if let floorToRemove {
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: floorToRemove).deletingLastPathComponent())
        }
        floorToRemove = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
    }

    private struct Turn {
        /// 这一轮每次询问出的是哪个域的卡
        var asked: [PermissionDomain] = []
        /// 询问卡上有没有出现「本对话都允许」（一笔一问不该有）
        var grantOffered = false
        var finished = false
    }

    func testAssistantWritesCardsAndPromptThroughFileToolsAcrossThreePermissionLevels() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let providers = ProviderManager()
        manager = providers
        let id = "xctest-memory-files-live-\(UUID().uuidString)"
        credentialId = id
        let modelName = getenv("MP_STREAM_LIVE_MODEL").map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "claude-haiku-5-5"
        let model = ProviderModel(credentialId: id, modelId: modelName, name: modelName)
        providers.addCredential(APICredential(id: id, name: "文件写记忆 live", emoji: "", type: .anthropic,
                                              baseURL: "https://api.anthropic.com/v1", extraHeaders: ["anthropic-version": "2023-06-01"],
                                              models: [model], toolsSupported: true))
        providers.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

        // 楼层 + 这层自己的预设实例放在临时目录里（Prompt 文件夹要从两个 manager 取）
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-files-live-\(UUID().uuidString)")
        scratch = root
        let suite = "xctest-memory-files-live-managers-\(UUID().uuidString)"
        managerSuite = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let presets = PresetManager(root: root.appendingPathComponent("blobs", isDirectory: true), defaults: defaults)
        var profile = Profile(id: "xctest-memory-files-live-\(UUID().uuidString)", name: "文件写记忆 live", emoji: "", description: "",
                              userName: "岚舟", assistantName: "星砚")
        let instance = presets.instantiate(templateId: Preset.balanced.id, for: profile.id)
        profile.presetId = instance.id
        try presets.persistNew(instance)
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile, loadError: nil,
                                      root: root.appendingPathComponent("blobs", isDirectory: true), defaults: defaults, sideEffectsEnabled: false)
        try profiles.persistNew([profile])
        let versions = FileVersionStore(root: root.appendingPathComponent("versions", isDirectory: true))
        PromptFolderTools.profiles = profiles
        PromptFolderTools.presets = presets
        PromptFolderTools.versionStore = versions
        floorToRemove = profile.id
        let pid = profile.id
        let memoryRoot = FileLibraryStore.memoryRoot(profileId: pid)
        let field = PromptFolder.path(for: .field(.characterDescription))
        let key = try XCTUnwrap(PromptFolderTools.versionKey(path: field, profileId: pid))

        // 只开工具总开关和文件库（文件工具要它），别的域都关；要测的那个域单独设
        func setLevel(_ level: PermissionLevel, for domain: PermissionDomain) {
            for d in PermissionDomain.allCases {
                PermissionCenter.setDefaultLevel(d == .toolsMaster || d == .fileLibrary ? .bypass : .notAllowed, for: d)
            }
            PermissionCenter.setDefaultLevel(level, for: domain)
        }
        func cards() -> [Memory] { SwiftDataMemoryStore().listAll(profileId: pid, context: context) }
        func log() -> [MemoryAuditLog.Entry] { MemoryAuditLog.load(memoryRoot: memoryRoot).filter { $0.actor == "星砚" } }
        func persona() -> String { profiles.profiles.first { $0.id == pid }?.characterDescription ?? "" }

        let vm = ConversationViewModel()
        vm.startDraftConversation(profileId: pid)

        func send(_ text: String, answer: PermissionPromptCenter.Decision) async throws -> Turn {
            var turn = Turn()
            let current = profiles.profiles.first { $0.id == pid } ?? profile
            XCTAssertTrue(vm.sendMessage(text, model: model, profile: current, preset: presets.preset(byId: current.presetId) ?? Preset.balanced,
                                         providerManager: providers, context: context))
            let deadline = Date().addingTimeInterval(180)
            while vm.assistantTurnInFlight, Date() < deadline {
                if let request = PermissionPromptCenter.shared.pendingRequest {
                    turn.asked.append(request.domain)
                    if request.approval?.conversationGrant == true { turn.grantOffered = true }
                    PermissionPromptCenter.shared.respond(to: request.id, decision: answer)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            turn.finished = !vm.assistantTurnInFlight
            return turn
        }
        func report(_ step: String, _ turn: Turn) {
            print("[FILES-LIVE] \(step) finished=\(turn.finished) asked=\(turn.asked.map(\.rawValue)) grantOffered=\(turn.grantOffered) cards=\(cards().map { "\($0.supersededAt == nil ? "live" : "deleted")：\($0.content)" }) log=\(log().map { $0.action.rawValue }) persona=\(persona())")
        }

        // 1 自动允许：fs_write 新建一份 = 加一张卡
        setLevel(.bypass, for: .memoryCards)
        let added = try await send("请用 fs_write 工具在 memory/cards/岚舟/ 下新建一个文件 新的.md，内容只有一句正文：「岚舟每周三去槐序巷皮影作坊学雕皮影。」。只做这一件事，做完告诉我。", answer: .deniedOnce)
        report("1 自动允许·fs_write 加", added)
        XCTAssertTrue(added.finished, "这一轮要跑完")
        XCTAssertTrue(added.asked.isEmpty, "自动允许不问")
        let card = try XCTUnwrap(cards().first { $0.content.contains("皮影") }, "助手真的用文件工具加了一张卡")
        XCTAssertEqual(card.subject, "岚舟", "说的是谁 = 文件夹那一段")
        XCTAssertNil(card.userEditedAt, "不算她亲手改的")
        let addEntry = try XCTUnwrap(log().first { $0.action == .add }, "加的那一笔进了日志，操作人是助手")
        XCTAssertEqual(addEntry.via, MemoryAuditLog.viaChat)
        let path = try XCTUnwrap(MemoryCardFolder.entries(profileId: pid, context: context).first { $0.card == card.id }).path
        XCTAssertTrue(path.hasSuffix(".md"), path)
        let original = card.content

        // 2 每次询问 + 拒绝：改不动
        setLevel(.askOnce, for: .memoryCards)
        let refused = try await send("用 fs_edit 改 \(path) 这个文件：把「周三」改成「周五」，别的不动。", answer: .deniedOnce)
        report("2 每次询问·拒绝", refused)
        XCTAssertTrue(refused.asked.contains(.memoryCards), "写 memory/cards/ 出的是「记忆条目」的卡")
        XCTAssertFalse(refused.grantOffered, "一笔一问，卡上没有「本对话都允许」")
        XCTAssertEqual(card.content, original, "拒绝了就不动")
        XCTAssertFalse(log().contains { $0.action == .edit }, "没动成的不记")

        // 3 每次询问 + 允许这一次：改成了，但不往对话授权里记
        let allowed = try await send("这次我会点允许。再用 fs_edit 改一次 \(path)：把「周三」改成「周五」。", answer: .allowedOnce)
        report("3 每次询问·允许", allowed)
        XCTAssertTrue(allowed.asked.contains(.memoryCards))
        XCTAssertTrue(card.content.contains("周五"), "允许了才生效：\(card.content)")
        XCTAssertTrue(log().contains { $0.action == .edit && $0.items.contains { $0.card == card.id } })
        XCTAssertFalse((vm.selectedConversation?.permGrantsRaw ?? "").contains(PermissionDomain.memoryCards.rawValue), "不记对话授权")
        let edited = card.content

        // 4 不允许：闸直接拒
        setLevel(.notAllowed, for: .memoryCards)
        let entriesBefore = log().count
        let blocked = try await send("用 fs_delete 把 \(path) 这个文件删掉。", answer: .allowedOnce)
        report("4 不允许", blocked)
        XCTAssertFalse(blocked.asked.contains(.memoryCards), "不允许不问")
        XCTAssertNil(card.supersededAt, "卡没被动")
        XCTAssertEqual(log().count, entriesBefore)

        // 5 自动允许：fs_delete = 进 Deleted，再撤回那一笔
        setLevel(.bypass, for: .memoryCards)
        let deleted = try await send("现在可以了。用 fs_delete 把 \(path) 这个文件删掉。", answer: .deniedOnce)
        report("5 自动允许·fs_delete", deleted)
        XCTAssertNotNil(card.supersededAt, "删文件 = 进 Deleted，不出库")
        let deleteEntry = try XCTUnwrap(log().first { $0.action == .delete && $0.items.contains { $0.card == card.id } })
        XCTAssertEqual(MemoryAuditLog.undo(deleteEntry, profileId: pid, context: context).restored, 1, "Undo 能回")
        try context.save()
        XCTAssertNil(card.supersededAt)
        XCTAssertEqual(card.content, edited)

        // 6 助手设定 · 每次询问 + 拒绝
        setLevel(.askOnce, for: .promptEdit)
        let ask = "请用 fs_write 把 \(field) 这个文件（你的助手设定）写成一句话：「星砚是槐序巷皮影作坊的学徒，说话慢。」。只做这一件事。"
        let personaRefused = try await send(ask, answer: .deniedOnce)
        report("6 助手设定·拒绝", personaRefused)
        XCTAssertTrue(personaRefused.asked.contains(.promptEdit), "写 Prompt 文件夹出的是「Prompt」的卡")
        XCTAssertFalse(personaRefused.grantOffered)
        XCTAssertEqual(persona(), "")
        let none = try await versions.versions(key: key)
        XCTAssertTrue(none.isEmpty, "没写成的不落历史")

        // 7 助手设定 · 每次询问 + 允许这一次
        let personaAllowed = try await send("这次我会点允许。" + ask, answer: .allowedOnce)
        report("7 助手设定·允许", personaAllowed)
        XCTAssertTrue(personaAllowed.asked.contains(.promptEdit))
        XCTAssertTrue(persona().contains("皮影作坊的学徒"), persona())
        let history = try await versions.versions(key: key)
        XCTAssertEqual(history.first?.actor, "星砚", "写之后那一版标着是谁写的")
        XCTAssertEqual(history.count, 2, "写之前、写之后各一版")
        let written = persona()

        // 8 助手设定 · 不允许
        setLevel(.notAllowed, for: .promptEdit)
        let personaBlocked = try await send("用 fs_write 把 \(field) 写成「星砚不说话。」。", answer: .allowedOnce)
        report("8 助手设定·不允许", personaBlocked)
        XCTAssertFalse(personaBlocked.asked.contains(.promptEdit))
        XCTAssertEqual(persona(), written)

        // 9 回到上一版：历史里上一版的全文存回去（编辑页历史里点恢复走的同一个保存）
        let lastVersion = try XCTUnwrap(history.last)
        let previousText = try await versions.content(key: key, id: lastVersion.id)
        let previous = try XCTUnwrap(previousText)
        try PromptFolder.save(field, text: previous, baseline: written, profileId: pid, profiles: profiles, presets: presets)
        XCTAssertEqual(persona(), previous, "回到了助手动手之前的样子")
        print("[FILES-LIVE] done model=\(modelName) card=\(path) log=\(log().count) versions=\(history.count)")
    }
}
