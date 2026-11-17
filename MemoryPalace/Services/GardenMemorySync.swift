import Foundation
import MemoryCore
import SwiftData
#if os(iOS)
import UIKit
#endif

/// 花园记忆文件夹 ↔ 电脑上 CC 的家（粟粟 11-14「对 CC 来说文件夹就该在电脑上、CC 读写本地文件、改动流回花园」）。
///
/// 花园 → 电脑：把一层楼对外的那棵树（`GardenTree`：`memory/` + `.prompt/` + 一份说明）同步到 `<CC 家>/garden-memory/<楼层>/`。
/// 先报整棵树的指纹（没变就到此为止）→ hub 要清单 → hub 只要变了的那几份 → 分批发全文。读库读盘都在后台。
/// 电脑 → 花园：hub 发现 CC 改了文件，发 `garden_tree_changes` 来，交给 `GardenFolderInbox` 落。
///
/// 什么时候同步：连上主 hub、发 CC 消息前、记忆 / Prompt 变了（攒几秒）、开开关、点「立即同步」。只跟主 hub 同步（附加 hub 的帧动不了记忆）。
/// 一层楼在电脑上的文件夹只跟一台设备：别的设备同名的楼层会被 hub 拒掉，在设置里开开关 / 点「立即同步」才接手
@MainActor
enum GardenMemorySync {
    static let enabledKey = "gardenMemoryToCCEnabled"
    static let lastSyncKey = "gardenMemoryToCCLastAt"
    static let lastCountKey = "gardenMemoryToCCLastCount"
    /// 上一次没同步成的原因（设置页那行状态用）；成了就清掉
    static let problemKey = "gardenMemoryToCCProblem"
    /// 这台设备同步过哪些楼层（id）：连上 hub、记忆变了时同步这几层
    static let floorsKey = "gardenMemoryToCCFloors"
    /// 这台设备在 hub 那边的编号（第一次用时生成）
    static let deviceKey = "gardenMemoryToCCDevice"
    static let didChange = Notification.Name("GardenMemorySyncDidChange")
    /// 她自己贴进 CC 的 CLAUDE.md 的那一行（app 不改她手写的那份）
    static let pointerLine = "你的长期记忆在 garden-memory/ 文件夹里，先读里面的 README.md。想不起来、或聊到以前的事时，先去那里搜。"

    /// 一帧里清单最多多少条、全文最多多少字节（同 hub 的 garden-tree.ts：app 收发一帧上限 1MB）
    static let listBatch = 500
    static let frameBytes = 256 * 1024
    /// 一次同步多久没走完算作废（hub 没回 / 断了）
    static let staleAfter: TimeInterval = 60
    /// 记忆变了以后攒多久再同步（整理、写手常常连着改好几笔）
    static let changeDelay: TimeInterval = 5

    /// app 根接上（`ContentView`）：楼层从哪取、落改动用哪个库
    struct Wiring {
        var profiles: () -> [Profile]
        var current: () -> Profile?
        var context: ModelContext
    }
    static var host: Wiring?

    private final class Run {
        let id = UUID().uuidString
        let profile: Profile
        let floor: String
        let claim: Bool
        let container: ModelContainer
        weak var client: CCBridgeWebSocketClient?
        var snapshot: GardenTree.Snapshot?
        let startedAt = Date()
        /// 发全文的活一个接一个做（hub 分几帧要，回的顺序不能乱）
        var work: Task<Void, Never>?

        init(profile: Profile, floor: String, claim: Bool, container: ModelContainer, client: CCBridgeWebSocketClient) {
            self.profile = profile
            self.floor = floor
            self.claim = claim
            self.container = container
            self.client = client
        }
    }

    /// 正在同步的（楼层文件夹名 → 这一次）
    private static var runs: [String: Run] = [:]
    /// 同步途中又有人要同步的楼层：走完再来一次
    private static var again: Set<String> = []
    /// 每条连接上各楼层上次同步成的那棵树的指纹（进程内）：没变不发
    private static var lastDigest: [ObjectIdentifier: [String: String]] = [:]
    /// 各楼层上一次发出去的说明全文（CC 改了说明时拿它恢复）
    private(set) static var lastReadme: [String: String] = [:]
    private static var observers: [NSObjectProtocol] = []
    private static var pendingChange: Task<Void, Never>?
    private static var inbox: Task<Void, Never>?

    static func enabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

    static func floorName(_ profile: Profile) -> String { GardenMemoryExport.fileStem(profile.name) }

    static func deviceId(_ defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: deviceKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceKey)
        return id
    }

    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    private static func head(_ profile: Profile, defaults: UserDefaults) -> [String: Any] {
        ["floor": floorName(profile), "title": profile.name, "device": deviceId(defaults), "device_name": deviceName, "profile_id": profile.id]
    }

    // MARK: - 什么时候同步

    /// 同步一层楼。`claim` = 这层楼在电脑上的文件夹改成跟这台设备（她在设置里开开关 / 点「立即同步」）；`force` = 树没变也问一遍 hub
    static func sync(profile: Profile, container: ModelContainer?, client: CCBridgeWebSocketClient = .shared,
                     defaults: UserDefaults = .standard, force: Bool = false, claim: Bool = false) {
        guard enabled(defaults), client.isPrimary, client.isConnected, let container = container ?? host?.context.container else { return }
        var floors = defaults.stringArray(forKey: floorsKey) ?? []
        if !floors.contains(profile.id) {
            floors.append(profile.id)
            defaults.set(floors, forKey: floorsKey)
        }
        let floor = floorName(profile)
        if let running = runs[floor], running.client === client, Date().timeIntervalSince(running.startedAt) < staleAfter {
            again.insert(profile.id)
            return
        }
        let run = Run(profile: profile, floor: floor, claim: claim, container: container, client: client)
        runs[floor] = run
        let promptFiles = PromptFolderTools.files(profileId: profile.id)
        let device = deviceName
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                GardenTree.snapshot(profile: profile, device: device, container: container, promptFiles: promptFiles)
            }.value
            guard runs[floor] === run else { return }
            guard enabled(defaults) else { runs[floor] = nil; return }
            run.snapshot = snapshot
            lastReadme[profile.id] = snapshot.content(GardenTree.readmePath)
            let digest = snapshot.digest
            if !force, !claim, lastDigest[ObjectIdentifier(client)]?[floor] == digest {
                finish(run, defaults: defaults)
                return
            }
            var hello = head(profile, defaults: defaults)
            hello["type"] = "garden_tree_hello"
            hello["digest"] = digest
            if claim { hello["claim"] = true }
            client.send(hello) { error in
                guard error != nil else { return }
                Task { @MainActor in if runs[floor] === run { runs[floor] = nil } }
            }
        }
    }

    /// 这台设备同步过的每一层都同步一遍（一层都没记过 = 升级上来开关已经开着：从当前这一层起）
    static func syncAll(client: CCBridgeWebSocketClient = .shared, defaults: UserDefaults = .standard, force: Bool = false) {
        guard enabled(defaults), let host else { return }
        let ids = defaults.stringArray(forKey: floorsKey) ?? []
        let profiles = host.profiles()
        let targets = ids.isEmpty ? [host.current()].compactMap { $0 } : profiles.filter { ids.contains($0.id) }
        for profile in targets { sync(profile: profile, container: host.context.container, client: client, defaults: defaults, force: force) }
    }

    /// 连上主 hub：同步一遍（hub 这才知道这层楼的 app 在线，把 CC 攒着的修改送过来）
    static func connected(client: CCBridgeWebSocketClient, defaults: UserDefaults = .standard) {
        guard client.isPrimary else { return }
        lastDigest[ObjectIdentifier(client)] = nil
        runs = runs.filter { $0.value.client !== client }
        if observers.isEmpty {
            for name in [Notification.Name.memoryDidChange, .fileLibraryDidChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in noteChanged() }
                })
            }
        }
        syncAll(client: client, defaults: defaults)
    }

    /// 记忆 / Prompt 变了：攒一会儿再同步
    static func noteChanged(defaults: UserDefaults = .standard) {
        guard enabled(defaults) else { return }
        pendingChange?.cancel()
        pendingChange = Task {
            guard (try? await Task.sleep(nanoseconds: UInt64(changeDelay * 1_000_000_000))) != nil else { return }
            syncAll(defaults: defaults)
        }
    }

    /// 关开关：这台设备同步过的楼层都从 CC 那边拿掉。CC 改了还没落进花园的（含等她点的）不丢：
    /// hub 在删树之前把那几份另存到那层楼的 `_sync/没落下的/`、记进回执（`garden-tree.ts` 的 `keepUnlanded`）；这边只清掉等她点的那一列
    static func remove(profiles: [Profile], client: CCBridgeWebSocketClient = .shared, defaults: UserDefaults = .standard) {
        let ids = defaults.stringArray(forKey: floorsKey) ?? []
        for profile in profiles where ids.contains(profile.id) || ids.isEmpty {
            var frame = head(profile, defaults: defaults)
            frame["type"] = "garden_tree_remove"
            client.send(frame) { _ in }
        }
        runs = [:]
        again = []
        lastDigest[ObjectIdentifier(client)] = nil
        for key in [lastSyncKey, lastCountKey, problemKey, floorsKey] { defaults.removeObject(forKey: key) }
        GardenFolderInbox.reset()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: - hub 来的帧

    static func receive(_ frame: [String: Any], client: CCBridgeWebSocketClient, defaults: UserDefaults = .standard) {
        guard enabled(defaults), client.isPrimary else { return }
        switch frame["type"] as? String {
        case "garden_tree_need": need(frame, client: client, defaults: defaults)
        case "garden_tree_result": result(frame, client: client, defaults: defaults)
        case "garden_tree_changes":
            guard let host else { return }
            GardenFolderInbox.transport = .init(connected: { [weak client] in client?.isConnected == true },
                                                send: { [weak client] in client?.send($0) { _ in } })
            // 一帧一帧按到的先后落（同一批里新建排在删除前面，顺序不能乱）
            let previous = inbox
            inbox = Task {
                await previous?.value
                await GardenFolderInbox.receive(frame, profiles: host.profiles(), context: host.context, awaitAnswers: false)
            }
        default: break
        }
    }

    private static func need(_ frame: [String: Any], client: CCBridgeWebSocketClient, defaults: UserDefaults) {
        guard let floor = frame["floor"] as? String, let run = runs[floor], run.client === client, let snapshot = run.snapshot else { return }
        if frame["manifest"] as? Bool == true {
            let entries = snapshot.entries
            var start = 0
            repeat {
                let end = min(start + listBatch, entries.count)
                var manifest = head(run.profile, defaults: defaults)
                manifest["type"] = "garden_tree_manifest"
                manifest["sync"] = run.id
                manifest["digest"] = snapshot.digest
                manifest["claim"] = run.claim
                manifest["files"] = entries[start..<end].map { ["path": $0.path, "hash": $0.hash] }
                manifest["last"] = end >= entries.count
                client.send(manifest) { _ in }
                start = end
            } while start < entries.count
            return
        }
        guard frame["sync"] as? String == run.id, let paths = frame["paths"] as? [String] else { return }
        let last = frame["last"] as? Bool == true
        let previous = run.work
        run.work = Task {
            await previous?.value
            let files = await Task.detached(priority: .utility) { snapshot.contents(paths) }.value
            guard runs[floor] === run else { return }
            let parts = batches(files)
            for (index, batch) in parts.enumerated() {
                client.send(["type": "garden_tree_files", "floor": floor, "sync": run.id,
                             "files": batch.map { ["path": $0.path, "content": $0.content] },
                             "last": last && index == parts.count - 1]) { _ in }
            }
        }
    }

    /// 按一帧的字节上限分批；一份都没有也给一批空的（hub 靠最后一帧收口）
    static func batches(_ files: [(path: String, content: String)]) -> [[(path: String, content: String)]] {
        var out: [[(path: String, content: String)]] = []
        var batch: [(path: String, content: String)] = []
        var bytes = 0
        for file in files {
            let size = file.content.utf8.count + file.path.utf8.count
            if !batch.isEmpty, bytes + size > frameBytes {
                out.append(batch)
                batch = []
                bytes = 0
            }
            batch.append(file)
            bytes += size
        }
        out.append(batch)
        return out
    }

    private static func result(_ frame: [String: Any], client: CCBridgeWebSocketClient, defaults: UserDefaults) {
        guard frame["removed_floor"] as? Bool != true, let floor = frame["floor"] as? String else { return }
        let run = runs[floor].flatMap { run in
            run.client === client && (frame["sync"] == nil || frame["sync"] as? String == run.id) ? run : nil
        }
        if frame["ok"] as? Bool == true {
            defaults.set(Date().timeIntervalSince1970, forKey: lastSyncKey)
            // 说明那一份不算
            if let count = frame["files"] as? Int { defaults.set(max(count - 1, 0), forKey: lastCountKey) }
            defaults.removeObject(forKey: problemKey)
            if let run, let digest = run.snapshot?.digest { lastDigest[ObjectIdentifier(client), default: [:]][floor] = digest }
        } else {
            defaults.set(problem(frame), forKey: problemKey)
        }
        if let run { finish(run, defaults: defaults) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// hub 没收这一次的原因，写成设置页那行看得懂的话
    static func problem(_ frame: [String: Any]) -> String {
        switch frame["reason"] as? String {
        case "other_device":
            let owner = (frame["owner_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "另一台设备"
            return "这一层在电脑上的文件夹现在跟的是「\(owner)」，这台没同步。点「立即同步」改成跟这台。"
        case "incomplete": return "有几份没传完，下次同步会补上。"
        case let reason?: return "电脑那边没收下（\(reason)）。"
        case nil: return "电脑那边没收下。"
        }
    }

    private static func finish(_ run: Run, defaults: UserDefaults) {
        if runs[run.floor] === run { runs[run.floor] = nil }
        guard again.remove(run.profile.id) != nil, let client = run.client else { return }
        sync(profile: run.profile, container: run.container, client: client, defaults: defaults)
    }

    #if DEBUG
    /// 测试收尾：进程内记着的全清掉
    static func resetForTesting() {
        runs = [:]
        again = []
        lastDigest = [:]
        lastReadme = [:]
        pendingChange?.cancel()
        pendingChange = nil
    }
    #endif
}
