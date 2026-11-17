import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 花园记忆文件夹 ↔ 电脑上 CC 的家，app 这一半：
/// 导出的那棵树（`GardenTree`）就是助手用文件工具看到的那一棵；CC 在电脑上改的文件（`GardenFolderInbox`）走同一条写入路、同一道三档权限。
/// 这里拿两个字典当「电脑」：`disk` = 盘上的文件，`base` = 花园上次给的那一版，照 hub（cc-bridge/garden-tree.ts）的规矩摆。全虚构
@MainActor
final class GardenMemorySyncTests: XCTestCase {
    private let pid = "gdnsync-xctest"
    private let floor = "槐序巷"
    private var container: ModelContainer!
    private var context: ModelContext!
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

    private var disk: [String: String] = [:]
    private var base: [String: String] = [:]
    private var sent: [[String: Any]] = []
    private let persona = ".prompt/fields/characterDescription.txt"

    override func setUpWithError() throws {
        try super.setUpWithError()
        saved = [:]
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: k) { saved[k] = v }
            UserDefaults.standard.removeObject(forKey: k)
        }
        UserDefaults.standard.set(true, forKey: "mem_master")
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("gdn-sync-\(UUID().uuidString)")
        previousLibraryRoot = FileLibraryStore.testRootOverride
        FileLibraryStore.testRootOverride = libraryRoot
        container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        context = ModelContext(container)
        suite = "GardenMemorySyncTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let blobs = libraryRoot.appendingPathComponent("blobs", isDirectory: true)
        presets = PresetManager(root: blobs, defaults: defaults)
        var p = Profile(id: pid, name: floor, emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
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
        disk = [:]
        base = [:]
        sent = []
        GardenFolderInbox.reset()
        GardenFolderInbox.transport = .init(connected: { true }, send: { [weak self] frame in self?.sent.append(frame) })
        GardenFolderInbox.ask = { _, _, _ in XCTFail("这一档不该出询问卡"); return .deniedOnce }
    }

    override func tearDownWithError() throws {
        GardenFolderInbox.reset()
        GardenFolderInbox.transport = nil
        GardenFolderInbox.ask = { await PermissionPromptCenter.shared.decide($0, detail: $1, folderChange: $2) }
        GardenMemorySync.resetForTesting()
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

    // MARK: - 小工具

    private func allowAll() { for d in domains { PermissionCenter.setFloorLevel(.bypass, for: d, profileId: pid) } }
    private func cards() -> [Memory] { SwiftDataMemoryStore().listAll(profileId: pid, context: context) }
    private func log() -> [MemoryAuditLog.Entry] { MemoryAuditLog.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) }
    private var now: Profile { profiles.profiles.first { $0.id == pid } ?? profile }

    @discardableResult
    private func addCard(_ content: String, about: String = "岚舟", tags: [String] = []) throws -> Memory {
        let m = try SwiftDataMemoryStore().add(content: content, category: "fact", keywords: tags, profileId: pid, isUserExplicit: false,
                                               extractedBy: "测试", sourceConversationId: nil, context: context)
        m.subject = about
        try context.save()
        return m
    }

    private func cardPath(_ m: Memory) -> String { "memory/cards/\(m.subject ?? "")/\(MemoryCardTool.short(m.id)).md" }

    /// 直接往这层楼的记忆树里放一份文件（后台写手写的那种）
    private func putOnDisk(_ rel: String, _ text: String) throws {
        let url = FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func snapshot() async -> GardenTree.Snapshot {
        let files = PromptFolderTools.files(profileId: pid)
        let (p, c) = (now, container!)
        return await Task.detached { GardenTree.snapshot(profile: p, device: "岚舟的手机", container: c, promptFiles: files) }.value
    }

    /// 花园 → 电脑：整棵树摆到「电脑」上
    @discardableResult
    private func export() async -> GardenTree.Snapshot {
        let snap = await snapshot()
        let contents = await Task.detached { snap.contents(snap.entries.map(\.path)) }.value
        disk = Dictionary(uniqueKeysWithValues: contents.map { ($0.path, $0.content) })
        base = disk
        return snap
    }

    /// CC 在电脑上改了一份（content nil = 删）→ 作为待落的修改送给花园 → 照结果把「电脑」摆好。返回这一笔的结果
    @discardableResult
    private func cc(_ path: String, _ content: String?) async -> [String: Any] {
        let id = UUID().uuidString
        var change: [String: Any] = ["id": id, "path": path, "op": content == nil ? "delete" : "write"]
        if let was = base[path] { change["base"] = GardenTree.hash(was) }
        if let content { change["content"] = content }
        disk[path] = content
        await GardenFolderInbox.receive(["type": "garden_tree_changes", "floor": floor, "profile_id": pid, "changes": [change]],
                                        profiles: profiles.profiles, context: context)
        return settle(id, origin: path)
    }

    /// 这一笔最后回的结果；照 hub 的规矩把「电脑」摆成花园现在的样子（等她点的不动）
    private func settle(_ id: String, origin: String) -> [String: Any] {
        let results = sent.filter { $0["type"] as? String == "garden_tree_change_result" && $0["floor"] as? String == floor }
            .flatMap { $0["results"] as? [[String: Any]] ?? [] }.filter { $0["id"] as? String == id }
        guard let r = results.last else { XCTFail("这一笔没有回结果"); return [:] }
        XCTAssertEqual(r["from"] as? String, origin)
        guard r["status"] as? String != "waiting" else { return r }
        let final = r["path"] as? String ?? origin
        let content = r["content"] as? String
        if final != origin || content == nil { disk[origin] = nil; base[origin] = nil }
        if let content { disk[final] = content; base[final] = content }
        return r
    }

    private func status(_ r: [String: Any]) -> String { r["status"] as? String ?? "" }
    private func message(_ r: [String: Any]) -> String { r["message"] as? String ?? "" }

    /// 「电脑」上的和花园现在导出的一字不差。照结果摆完就该一致的是 CC 改得到的每一份；
    /// 跟着变的只读页（日志、钉住的清单、目录）要等下一次同步带过来——这里再同步一次，然后整棵一字不差
    private func assertMirrors(file: StaticString = #filePath, line: UInt = #line) async {
        let snap = await snapshot()
        let contents = await Task.detached { snap.contents(snap.entries.map(\.path)) }.value
        let garden = Dictionary(uniqueKeysWithValues: contents.map { ($0.path, $0.content) })
        for path in Set(disk.keys).union(garden.keys) where disk[path] != garden[path] {
            let stored = FileLibraryTools.storedWikiPath(path, user: "岚舟")
            var derived = path == GardenTree.readmePath
            if case .readOnly = MemoryFolderWrite.kind(stored) { derived = true }
            XCTAssertTrue(derived, "\(path) 两边不一样：电脑上 \(disk[path] ?? "（没有）") ／ 花园 \(garden[path] ?? "（没有）")", file: file, line: line)
        }
        await export()
        XCTAssertEqual(disk, garden, file: file, line: line)
    }

    private func fs(_ name: String, _ input: [String: Any]) async -> String {
        let json = String(data: try! JSONSerialization.data(withJSONObject: input), encoding: .utf8)!
        let r = await FileLibraryTools.run(name: name, inputJSON: json, profileId: pid, userName: "岚舟", actor: "星砚",
                                           conversationId: nil, memoryEnabled: true, via: MemoryAuditLog.viaChat, context: context)
        XCTAssertFalse(r.isError, r.text)
        return r.text
    }

    // MARK: - 花园 → 电脑：导出的就是助手看到的那棵树

    func testTreeIsWhatFileToolsShowMinusWhatStaysOnDevice() async throws {
        let kept = try addCard("岚舟每周三去槐序巷皮影作坊学雕皮影。", tags: ["皮影"])
        let gone = try addCard("删掉的一张。")
        try SwiftDataMemoryStore().supersede(id: gone.id, context: context)
        try putOnDisk("timeline/2026-11-12.md", "# 2026-11-12\n\n主调：雕皮影。\n")
        try putOnDisk("wiki/\(WikiStore.userBranch)/喜好.md", "# 喜好\n\n## 现在\n[[\(WikiStore.userBranch)/喜好]] 爱吃巷口的面。\n")
        try putOnDisk("wiki/\(WikiStore.branches[1])/private_秘密.md", "# 秘密\n")
        try putOnDisk("cc/notes.md", "从 CC 那边同步来的\n")
        try putOnDisk("log/c2-dream/notes.json", "{}")
        _ = await fs("fs_write", ["path": "memory/self/刻纸鸢.md", "content": "---\nname: 刻纸鸢\n---\n\n答应帮岚舟刻一只纸鸢。"])

        let snap = await export()
        let paths = Set(snap.entries.map(\.path))
        // 列的：fs_list 里 memory/ 和 .prompt/ 下的每一行，去掉不带出设备的，加一份说明
        let listed = await fs("fs_list", [:]).split(separator: "\n").compactMap { $0.components(separatedBy: "  (").first }
            .filter { $0.hasPrefix("memory/") || $0.hasPrefix(".prompt/") }
        XCTAssertFalse(listed.isEmpty)
        XCTAssertEqual(paths, Set(listed.filter { GardenTree.exclusion($0) == nil } + [GardenTree.readmePath]))
        XCTAssertTrue(paths.contains(cardPath(kept)))
        XCTAssertTrue(paths.contains("memory/wiki/岚舟/喜好.md"), "wiki 本人那组是名字，同助手看到的")
        XCTAssertTrue(paths.contains(persona) && paths.contains("memory/log/审计日志.md") && paths.contains(MemoryCardFolder.pinnedPath))
        XCTAssertTrue(paths.contains("memory/timeline/2026-11-12.md") && paths.contains("memory/self/刻纸鸢.md"))
        for stays in ["memory/cards/Deleted/\(MemoryCardTool.short(gone.id)).md", "memory/wiki/\(WikiStore.branches[1])/private_秘密.md",
                      "memory/cc/notes.md", "memory/log/c2-dream/notes.json"] {
            XCTAssertTrue(listed.contains(stays), "助手自己看得到：\(stays)")
            XCTAssertFalse(paths.contains(stays), "不带到电脑上：\(stays)")
        }
        // 读的：每一份和 fs_read 读到的一字不差
        // （fs_read 回给模型时不带最后那个换行，别的一样）
        func bare(_ text: String?) -> String? { text.map { $0.hasSuffix("\n") ? String($0.dropLast()) : $0 } }
        for path in paths where path != GardenTree.readmePath {
            let read = await fs("fs_read", ["path": path])
            XCTAssertEqual(bare(disk[path]), bare(read), path)
            let one = await GardenTree.text(of: path, profile: now, container: container)
            XCTAssertEqual(one, disk[path], path)
        }
        XCTAssertTrue(disk["memory/wiki/岚舟/喜好.md"]?.contains("[[岚舟/喜好]]") == true)

        // 没变：指纹不变；改一条记忆条目：只有那一条（和跟着它变的日志）的指纹变
        let again = await snapshot()
        XCTAssertEqual(again.digest, snap.digest)
        XCTAssertEqual(again.entries, snap.entries)
        kept.keywords = ["皮影", "周三"]
        try context.save()
        let changed = await snapshot()
        XCTAssertNotEqual(changed.digest, snap.digest)
        let before = Dictionary(uniqueKeysWithValues: snap.entries.map { ($0.path, $0.hash) })
        XCTAssertEqual(changed.entries.filter { before[$0.path] != $0.hash }.map(\.path), [cardPath(kept)])
    }

    func testReadmeTellsCCWhatTheTreeIsAndHowToWrite() async throws {
        let snap = await export()
        let readme = try XCTUnwrap(disk[GardenTree.readmePath])
        XCTAssertEqual(GardenMemorySync.lastReadme[pid], nil, "只有真同步才记")
        for word in ["# 花园记忆 · 槐序巷", "岚舟的手机", "memory/cards/<说的是谁>/<编号>.md", "memory/self/", "memory/pending/待续.md", "memory/wiki/",
                     "memory/timeline/", "只读", "about", "tags", "不要写 `id`", "characterDescription.txt` = 助手设定",
                     "_sync/收件回执.md", "_sync/没落下的/", "每次询问", "CC 里的星砚", "private_", "槐序巷皮影作坊"] {
            XCTAssertTrue(readme.contains(word), word)
        }
        let main = PromptFolder.path(for: .slot(presetId: now.presetId, slotId: PromptSlot.mainId))
        XCTAssertTrue(readme.contains("`\(main)`：插槽"), "插槽的文件名是编号，说明里写着各是哪一段")
        XCTAssertFalse(readme.contains("做梦"))
        XCTAssertEqual(snap.oversize, [])
    }

    // MARK: - 电脑 → 花园

    func testCCEditsLandThroughFileToolsAndBothSidesMatch() async throws {
        allowAll()
        let m = try addCard("岚舟每周三去槐序巷皮影作坊学雕皮影。", tags: ["皮影"])
        await export()
        let path = cardPath(m)

        // 改一条记忆条目的 tags
        let tagged = await cc(path, try XCTUnwrap(disk[path]).replacingOccurrences(of: "tags: [皮影]", with: "tags: [皮影, 周三]"))
        XCTAssertEqual(status(tagged), "landed", message(tagged))
        XCTAssertEqual(m.keywords, ["皮影", "周三"])
        // 改助手设定
        let set = await cc(persona, "星砚是槐序巷皮影作坊的学徒，说话慢。")
        XCTAssertEqual(status(set), "landed", message(set))
        XCTAssertEqual(now.characterDescription, "星砚是槐序巷皮影作坊的学徒，说话慢。")
        // 新建一条：文件名换成它的编号
        let made = await cc("memory/cards/岚舟/新条目.md", "---\ntags: [纸鸢]\nimportance: 3\n---\n\n星砚答应帮岚舟刻一只燕子形的纸鸢。")
        XCTAssertEqual(status(made), "landed", message(made))
        let new = try XCTUnwrap(cards().first { $0.content.contains("燕子形") })
        XCTAssertEqual(made["path"] as? String, cardPath(new))
        XCTAssertEqual(new.keywords, ["纸鸢"])
        XCTAssertNil(new.sourceConversationId, "不挂在哪一场对话上")
        XCTAssertNil(disk["memory/cards/岚舟/新条目.md"])

        // 两边一致：电脑上的 = 花园再导出的
        await assertMirrors()

        // 留痕：CC 里的{助手名}，来处 CC；她撤得回；Prompt 的版本历史里标着是谁
        let entries = log()
        XCTAssertEqual(entries.map(\.actor), ["CC 里的星砚", "CC 里的星砚"])
        XCTAssertEqual(entries.map(\.via), [MemoryAuditLog.viaCC, MemoryAuditLog.viaCC])
        XCTAssertEqual(entries.map(\.action), [.add, .edit])
        XCTAssertEqual(MemoryAuditLog.undo(try XCTUnwrap(entries.last), profileId: pid, context: context).restored, 1)
        XCTAssertEqual(m.keywords, ["皮影"])
        let key = try XCTUnwrap(PromptFolderTools.versionKey(path: persona, profileId: pid))
        let history = try await versions.versions(key: key)
        XCTAssertEqual(history.map(\.actor), ["CC 里的星砚", nil])

        // 同一版再送一遍（hub 重启后重发）：不重复落
        let twice = await cc(persona, "星砚是槐序巷皮影作坊的学徒，说话慢。")
        XCTAssertEqual(status(twice), "landed")
        let after = try await versions.versions(key: key)
        XCTAssertEqual(after.count, 2)
    }

    func testOtherKindsLandTheSameWay() async throws {
        allowAll()
        try putOnDisk("wiki/\(WikiStore.userBranch)/喜好.md", "# 喜好\n\n## 现在\n爱吃巷口的面。\n")
        _ = await fs("fs_write", ["path": "memory/self/刻纸鸢.md", "content": "---\nname: 刻纸鸢\n---\n\n答应帮岚舟刻一只纸鸢。"])
        await export()
        // wiki 页：路径里是名字，落盘还原成本人那组；改之前的一版进历史
        let wiki = await cc("memory/wiki/岚舟/喜好.md", "# 喜好\n\n## 现在\n爱吃巷口的面，不要香菜。\n")
        XCTAssertEqual(status(wiki), "landed", message(wiki))
        let store = WikiStore(profileId: pid)
        let (page, history) = await Task.detached { (store.readRaw("\(WikiStore.userBranch)/喜好"), store.history("\(WikiStore.userBranch)/喜好")) }.value
        XCTAssertTrue(page?.contains("不要香菜") == true)
        XCTAssertEqual(history.count, 1)
        // 自己的记忆：改正文；删文件 = 标成失效
        let selfPath = "memory/self/刻纸鸢.md"
        let edited = await cc(selfPath, try XCTUnwrap(disk[selfPath]).replacingOccurrences(of: "一只纸鸢", with: "两只纸鸢"))
        XCTAssertEqual(status(edited), "landed", message(edited))
        XCTAssertTrue(disk[selfPath]?.contains("两只纸鸢") == true)
        let dropped = await cc(selfPath, nil)
        XCTAssertEqual(status(dropped), "landed", message(dropped))
        XCTAssertTrue((dropped["content"] as? String)?.contains("superseded") == true, "文件还在，标成了失效：电脑上放回花园现在的样子")
        await assertMirrors()
    }

    /// CC 在电脑上给待续加一行 = 新加一条（那边没有窗口，记在 `PendingStore.ccWindow` 名下）；改已有的行照旧
    func testCCAddsAPendingLine() async throws {
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        try XCTSkipUnless(PendingNotesTool.enabled, "时间轴开关在这台机器上关着")
        allowAll()
        await export()
        let path = MemoryFolderWrite.pendingPath
        let added = await cc(path, "- 帮岚舟查云桥城的灯会是哪天\n")
        XCTAssertEqual(status(added), "landed", message(added))
        func items() async -> [PendingItem] {
            await Task.detached { [pid] in PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) ?? [] }.value
        }
        var now = await items()
        XCTAssertEqual(now.map(\.text), ["帮岚舟查云桥城的灯会是哪天"])
        XCTAssertEqual(now.first?.conversationId, PendingStore.ccWindow)
        let landed = try XCTUnwrap(disk[path])
        XCTAssertTrue(landed.contains("id=p0001") && landed.contains("conv=\(PendingStore.ccWindow)"), "电脑上放回花园补好注释的那一行：\(landed)")
        let second = await cc(path, landed + "\n- 给星砚带一包槐花糖\n")
        XCTAssertEqual(status(second), "landed", message(second))
        let done = await cc(path, try XCTUnwrap(disk[path]).replacingOccurrences(of: "id=p0001 state=open", with: "id=p0001 state=done"))
        XCTAssertEqual(status(done), "landed", message(done))
        now = await items()
        XCTAssertEqual(now.map(\.state), [.done, .open])
        XCTAssertEqual(now.map(\.text), ["帮岚舟查云桥城的灯会是哪天", "给星砚带一包槐花糖"])
        await assertMirrors()
    }

    func testConflictReadOnlyAndBadFormatComeBackWithTheGardensVersion() async throws {
        allowAll()
        let m = try addCard("岚舟每周三去槐序巷皮影作坊学雕皮影。", tags: ["皮影"])
        try putOnDisk("timeline/2026-11-12.md", "# 2026-11-12\n\n主调：雕皮影。\n")
        await export()
        let path = cardPath(m)
        let old = try XCTUnwrap(disk[path])

        // 冲突：花园里那份先变了（她在整理台改的），CC 照旧版改
        m.content = "岚舟改到每周四去槐序巷皮影作坊。"
        try context.save()
        let conflict = await cc(path, old.replacingOccurrences(of: "tags: [皮影]", with: "tags: [皮影, CC 加的]"))
        XCTAssertEqual(status(conflict), "conflict", message(conflict))
        XCTAssertEqual(m.keywords, ["皮影"], "没落")
        XCTAssertTrue(disk[path]?.contains("每周四") == true, "电脑上恢复成花园现在的样子")

        // 只读：时间轴改了 / 删了、说明改了、树外面的文件
        for (target, content) in [("memory/timeline/2026-11-12.md", "CC 改的主调" as String?), ("memory/timeline/2026-11-12.md", nil),
                                  (GardenTree.readmePath, "CC 改的说明"), ("随手记.md", "不在树里")] {
            let r = await cc(target, content)
            XCTAssertEqual(status(r), "readonly", "\(target)：\(message(r))")
            XCTAssertFalse(message(r).isEmpty)
        }
        XCTAssertEqual(disk["memory/timeline/2026-11-12.md"], "# 2026-11-12\n\n主调：雕皮影。\n")
        XCTAssertNil(disk["随手记.md"])

        // 格式不对：说清哪一行；Prompt 里不能新建 / 删；不带出设备的位置写不进来
        let bad = await cc(path, try XCTUnwrap(disk[path]).replacingOccurrences(of: "pinned: no", with: "mood: 开心"))
        XCTAssertEqual(status(bad), "rejected")
        XCTAssertTrue(message(bad).contains("认不出「mood」"), message(bad))
        let newSlot = await cc(".prompt/新的插槽.txt", "x")
        XCTAssertEqual(status(newSlot), "rejected")
        XCTAssertTrue(message(newSlot).contains("Prompt 页"), message(newSlot))
        let noDelete = await cc(persona, nil)
        XCTAssertEqual(status(noDelete), "rejected")
        XCTAssertEqual(disk[persona], "")
        let hidden = await cc("memory/wiki/\(WikiStore.branches[1])/private_秘密.md", "# 秘密\n")
        XCTAssertEqual(status(hidden), "rejected")
        XCTAssertTrue(message(hidden).contains("private_"), message(hidden))
        XCTAssertTrue(log().isEmpty, "一笔都没落")
        disk[GardenTree.readmePath] = nil   // 说明只有真同步时才有上一份可恢复
        var mirror = disk
        mirror[GardenTree.readmePath] = nil
        let snap = await snapshot()
        let contents = await Task.detached { snap.contents(snap.entries.map(\.path).filter { $0 != GardenTree.readmePath }) }.value
        XCTAssertEqual(mirror, Dictionary(uniqueKeysWithValues: contents.map { ($0.path, $0.content) }))
    }

    // MARK: - 三档权限，没有对话可以出审批卡

    func testAskEveryTimeUsesThePopupOneByOneAndKeepsWaiting() async throws {
        let a = try addCard("岚舟每周三去槐序巷皮影作坊学雕皮影。")
        let b = try addCard("岚舟怕打雷。")
        await export()
        XCTAssertEqual(PermissionCenter.level(.memoryCards, profileId: pid), .askOnce, "默认档")

        // 第一笔她允许，第二笔她划走（以后再说）
        var asked: [(PermissionDomain, String?, PermissionPromptCenter.FolderChange)] = []
        var answers: [PermissionPromptCenter.Decision] = [.timedOut]
        GardenFolderInbox.ask = { domain, detail, note in
            asked.append((domain, detail, note))
            return answers.isEmpty ? .timedOut : answers.removeFirst()
        }
        let first = await cc(cardPath(a), try XCTUnwrap(disk[cardPath(a)]).replacingOccurrences(of: "每周三", with: "每周四"))
        XCTAssertEqual(status(first), "waiting", "她没点：一直等着，电脑上保持 CC 改后的样子")
        XCTAssertTrue(disk[cardPath(a)]?.contains("每周四") == true)
        XCTAssertEqual(a.content, "岚舟每周三去槐序巷皮影作坊学雕皮影。")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].0, .memoryCards)
        XCTAssertTrue(asked[0].1?.contains("岚舟每周三去槐序巷皮影作坊学雕皮影。") == true, "弹窗上看得到要动的那一条现在写的是什么")
        XCTAssertEqual(asked[0].2, .init(what: "修改 \(cardPath(a))", index: 1, total: 1))
        XCTAssertEqual(GardenFolderInbox.waiting.map(\.path), [cardPath(a)])

        // 又来一笔：划走过的那笔不追着再弹，新的这笔弹；她允许
        answers = [.allowedOnce]
        let second = await cc(cardPath(b), try XCTUnwrap(disk[cardPath(b)]).replacingOccurrences(of: "怕打雷", with: "不怕打雷了"))
        XCTAssertEqual(status(second), "landed", message(second))
        XCTAssertEqual(b.content, "岚舟不怕打雷了。")
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(asked[1].2.total, 2, "弹窗上说得出一共等着几处")
        XCTAssertEqual(GardenFolderInbox.waiting.map(\.path), [cardPath(a)], "划走的那笔还在等")

        // 她在设置里对等着的那笔点 Approve
        let id = try XCTUnwrap(GardenFolderInbox.waiting.first?.id)
        await GardenFolderInbox.resolve(id, allow: true, profiles: profiles.profiles, context: context)
        XCTAssertEqual(status(settle(id, origin: cardPath(a))), "landed")
        XCTAssertEqual(a.content, "岚舟每周四去槐序巷皮影作坊学雕皮影。")
        XCTAssertTrue(GardenFolderInbox.waiting.isEmpty)
        XCTAssertEqual(log().map(\.actor), ["CC 里的星砚", "CC 里的星砚"])
        await assertMirrors()

        // 拒绝：不落，电脑上恢复
        answers = [.deniedOnce]
        let no = await cc(cardPath(b), try XCTUnwrap(disk[cardPath(b)]).replacingOccurrences(of: "不怕打雷了", with: "CC 想改的"))
        XCTAssertEqual(status(no), "denied")
        XCTAssertEqual(b.content, "岚舟不怕打雷了。")
        await assertMirrors()
    }

    func testChangingTheLevelReleasesOrRefusesWhatIsWaiting() async throws {
        let a = try addCard("岚舟每周三去槐序巷皮影作坊学雕皮影。")
        await export()
        GardenFolderInbox.ask = { _, _, _ in .timedOut }
        let one = await cc(cardPath(a), try XCTUnwrap(disk[cardPath(a)]).replacingOccurrences(of: "每周三", with: "每周四"))
        let two = await cc(persona, "星砚说话慢。")
        XCTAssertEqual([status(one), status(two)], ["waiting", "waiting"])
        let ids = GardenFolderInbox.waiting.map(\.id)
        XCTAssertEqual(ids.count, 2)

        // 权限里把 C2 记忆条目那一档改成自动允许、Prompt 改成不允许，再点「立即同步」：等着的不用再问
        PermissionCenter.setFloorLevel(.bypass, for: .memoryCards, profileId: pid)
        PermissionCenter.setFloorLevel(.notAllowed, for: .promptEdit, profileId: pid)
        GardenFolderInbox.ask = { _, _, _ in XCTFail("重看一遍不弹窗"); return .deniedOnce }
        await GardenFolderInbox.recheck(profiles: profiles.profiles, context: context)
        XCTAssertEqual(status(settle(ids[0], origin: cardPath(a))), "landed")
        let refused = settle(ids[1], origin: persona)
        XCTAssertEqual(status(refused), "denied")
        XCTAssertTrue(message(refused).contains("「Prompt」这一档是不允许"), message(refused))
        XCTAssertEqual(a.content, "岚舟每周四去槐序巷皮影作坊学雕皮影。")
        XCTAssertEqual(now.characterDescription, "")
        XCTAssertTrue(GardenFolderInbox.waiting.isEmpty)
        await assertMirrors()
    }

    // MARK: - 挪文件 / 删文件

    func testMovingACardFileChangesWhoItIsAboutInsteadOfLosingTheCard() async throws {
        allowAll()
        let m = try addCard("岚舟每周三去槐序巷皮影作坊学雕皮影。")
        await export()
        let old = cardPath(m)
        let text = try XCTUnwrap(disk[old])
        let moved = "memory/cards/星砚/\(MemoryCardTool.short(m.id)).md"
        // CC 用 mv 把一条记忆条目的文件挪到另一个文件夹：hub 看到的是「新建一份」+「删掉原来那份」
        let created = await cc(moved, text)
        XCTAssertEqual(status(created), "landed", message(created))
        XCTAssertEqual(m.subject, "星砚", "按文件夹改「说的是谁」")
        XCTAssertEqual(cards().count, 1, "没有多出一张")
        // 模拟 hub：原来那份 CC 已经挪走了
        disk[old] = text
        let removed = await cc(old, nil)
        XCTAssertEqual(status(removed), "landed", message(removed))
        XCTAssertNil(m.supersededAt, "原位置上已经没有这一条，删不到它")
        await assertMirrors()

        // 真删：删掉它的文件 = 进 Deleted（能放回），电脑上不再有
        let deleted = await cc(moved, nil)
        XCTAssertEqual(status(deleted), "landed", message(deleted))
        XCTAssertNotNil(m.supersededAt)
        XCTAssertEqual(log().first?.action, .delete)
        await assertMirrors()
        XCTAssertEqual(GardenFolderInbox.settingAbout("只有正文", to: "岚舟"), "---\nabout: 岚舟\n---\n\n只有正文")
    }

    // MARK: - 发帧的零件

    func testBatchesStayUnderTheFrameBudgetAndProblemsReadPlainly() {
        let big = String(repeating: "皮", count: GardenMemorySync.frameBytes / 3 - 100)
        let batches = GardenMemorySync.batches([("a.md", big), ("b.md", big), ("c.md", "小")])
        XCTAssertEqual(batches.map { $0.map(\.path) }, [["a.md"], ["b.md", "c.md"]])
        XCTAssertEqual(GardenMemorySync.batches([]).count, 1, "一份都没有也给 hub 一帧收口")
        XCTAssertTrue(GardenMemorySync.problem(["reason": "other_device", "owner_name": "测试机"]).contains("「测试机」"))
        // 附加 hub（别的电脑）发来的这类帧一律丢：只有主 hub 那台电脑上的 CC 动得了记忆
        for type in ["garden_tree_need", "garden_tree_result", "garden_tree_changes"] {
            XCTAssertEqual(CCBridgeWebSocketClient.secondaryFrameGate(type), .drop, type)
        }
        XCTAssertFalse(GardenMemorySync.enabled(defaults), "默认关")
        XCTAssertEqual(GardenMemorySync.enabledKey, "gardenMemoryToCCEnabled", "开关的键不变：她开着的升级后不用重开")
        XCTAssertEqual(GardenMemorySync.deviceId(defaults), GardenMemorySync.deviceId(defaults))
        XCTAssertEqual(GardenMemorySync.floorName(profile), floor)
        // 指纹两头要算出同一个：hub 那边的 treeHash（cc-bridge/garden-tree.test.ts 钉着同一个值）
        XCTAssertEqual(GardenTree.hash("岚舟每周三去槐序巷皮影作坊学雕皮影。\n"), "8a6ac19ade6c7392754b4e41f0cab070")
    }
}
