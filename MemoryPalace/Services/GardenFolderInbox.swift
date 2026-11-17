import Foundation
import MemoryCore
import SwiftData

/// CC 在电脑上改了记忆文件夹里的文件（`<CC 家>/garden-memory/<楼层>/`），hub 把每一处作为「待落的修改」送来，这里把它落进花园。
///
/// 落法和聊天里的助手用文件工具写是同一条路（`FileLibraryTools.run` → `MemoryFolderWrite` / `PromptFolderTools`），
/// 只是不挂在哪一场对话上；留痕记「CC 里的{助手名}」、来处 CC，她能 Undo / 回到上一版。
/// 规矩：
/// - 花园是准：修改带着它基于的那一版的指纹，花园里那份已经不是这一版 = 冲突，不落。
/// - 三档权限按写的是哪一种分域（同文件工具）：自动允许直接落；不允许退回；每次询问 = 一笔一问——
///   没有对话可以出审批卡，用现成的权限弹窗（`PermissionPromptCenter`，弹窗上写明是 CC 在电脑上改的第几处）；
///   她划走 / 没看见 = 以后再说，这一笔一直等着（不超时丢），设置 › 记忆 里列着，能逐笔点。
/// - 每一笔都回结果（落了 / 等她点 / 被拒 / 冲突 / 只读 / 没落下及原因）和花园里那一份现在的全文，hub 照着把电脑上的文件摆好、写回执。
@MainActor
enum GardenFolderInbox {
    enum Op: String { case write, delete }
    enum Status: String { case landed, waiting, denied, conflict, readonly, rejected }

    struct Change: Equatable, Identifiable {
        var id: String
        var floor: String
        var profileId: String
        /// 树里的相对路径（给助手看的写法）
        var path: String
        var op: Op
        /// 它基于的那一版的指纹；nil = 新建的
        var base: String?
        var content: String

        init?(_ raw: [String: Any], floor: String, profileId: String) {
            guard let id = raw["id"] as? String, let path = raw["path"] as? String, let op = (raw["op"] as? String).flatMap(Op.init(rawValue:)) else { return nil }
            self.id = id
            self.floor = floor
            self.profileId = profileId
            self.path = path
            self.op = op
            self.base = raw["base"] as? String
            self.content = raw["content"] as? String ?? ""
        }

        /// 设置里那一列和弹窗上说的：动的是哪一份
        var what: String { (op == .delete ? "删除 " : base == nil ? "新建 " : "修改 ") + path }
    }

    struct Outcome {
        var change: Change
        var status: Status
        var message: String
        /// 落下后这一份在树里的位置（新建的 C2 记忆条目文件名会换成它的编号）
        var path: String
        /// 花园里那一份现在的全文；nil = 花园里没有这份
        var content: String?

        var frame: [String: Any] {
            var out: [String: Any] = ["id": change.id, "from": change.path, "status": status.rawValue, "message": message, "path": path]
            if let content { out["content"] = content }
            return out
        }
    }

    /// 结果从哪条连接回（hub 送修改来的那一条）
    struct Transport {
        var connected: () -> Bool
        var send: ([String: Any]) -> Void
    }
    static var transport: Transport?

    typealias Ask = @MainActor (PermissionDomain, _ detail: String?, PermissionPromptCenter.FolderChange) async -> PermissionPromptCenter.Decision
    /// 问她一笔（默认 = 权限弹窗；测试换成直接给答案的）
    static var ask: Ask = { await PermissionPromptCenter.shared.decide($0, detail: $1, folderChange: $2) }

    static let didChange = Notification.Name("GardenFolderInboxDidChange")
    /// 等她点的（按到的先后）
    private(set) static var waiting: [Change] = []
    /// 弹窗问过的（她划走的不追着再弹；设置 › 记忆 里那一列还能点）
    private static var asked: Set<String> = []
    private static var pumping = false

    static func reset() {
        waiting = []
        asked = []
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: - 入口

    /// `awaitAnswers` false = 判完、回完这一帧就返回，等她点的在后面慢慢问（真连时这样：下一帧不用等她点完才轮到）
    static func receive(_ frame: [String: Any], profiles: [Profile], context: ModelContext, awaitAnswers: Bool = true) async {
        guard let floor = frame["floor"] as? String, let profileId = frame["profile_id"] as? String,
              let raw = frame["changes"] as? [[String: Any]] else { return }
        var results: [[String: Any]] = []
        for item in raw {
            guard let change = Change(item, floor: floor, profileId: profileId) else { continue }
            // 同一份又改了：只认后来这一版
            waiting.removeAll { $0.floor == floor && $0.path == change.path }
            let outcome = await judge(change, approved: false, profiles: profiles, context: context)
            if outcome.status == .waiting { waiting.append(change) }
            results.append(outcome.frame)
        }
        send(floor: floor, results)
        NotificationCenter.default.post(name: didChange, object: nil)
        if awaitAnswers { await pump(profiles: profiles, context: context) } else { Task { await pump(profiles: profiles, context: context) } }
    }

    /// 她在设置里对一笔点了 Approve / Reject
    static func resolve(_ id: String, allow: Bool, profiles: [Profile], context: ModelContext) async {
        guard let change = waiting.first(where: { $0.id == id }), transport?.connected() == true else { return }
        let outcome = allow ? await judge(change, approved: true, profiles: profiles, context: context)
            : await refused(change, .denied, "她没允许这一笔。", profiles: profiles, context: context)
        settle(change, outcome)
    }

    /// 等着的按现在的档位重看一遍，不弹窗（她在权限里把那一档改成自动允许 / 不允许之后点「立即同步」）：不用再问的直接落 / 退回
    static func recheck(profiles: [Profile], context: ModelContext) async {
        for change in waiting where transport?.connected() == true {
            let outcome = await judge(change, approved: false, profiles: profiles, context: context)
            if waiting.contains(change) { settle(change, outcome) }
        }
    }

    private static func send(floor: String, _ results: [[String: Any]]) {
        guard !results.isEmpty else { return }
        transport?.send(["type": "garden_tree_change_result", "floor": floor, "results": results])
    }

    private static func settle(_ change: Change, _ outcome: Outcome) {
        guard outcome.status != .waiting else { return }
        waiting.removeAll { $0 == change }
        send(floor: change.floor, [outcome.frame])
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 等着的一笔一笔问。她划走 / 没看见 = 这一轮到此为止，剩下的接着等
    private static func pump(profiles: [Profile], context: ModelContext) async {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while transport?.connected() == true, let next = waiting.first(where: { !asked.contains($0.id) }) {
            asked.insert(next.id)
            // 等的这会儿档位、花园里那一份都可能变了：先重判
            var outcome = await judge(next, approved: false, profiles: profiles, context: context)
            if outcome.status == .waiting {
                guard let profile = profiles.first(where: { $0.id == next.profileId }), let call = fileCall(for: next, profile: profile) else { continue }
                let detail = PermissionGate.detail(domain: call.domain, toolName: call.tool, argumentsJSON: call.args, profileId: profile.id, context: context)
                let note = PermissionPromptCenter.FolderChange(what: next.what, index: (waiting.firstIndex(of: next) ?? 0) + 1, total: waiting.count)
                let decision = await ask(call.domain, detail, note)
                // 这中间她在设置里点掉了 / CC 又改了这一份
                guard waiting.contains(next) else { continue }
                switch decision {
                case .allowed, .allowedOnce:
                    outcome = await judge(next, approved: true, profiles: profiles, context: context)
                case .denied, .deniedOnce:
                    outcome = await refused(next, .denied, "她没允许这一笔。", profiles: profiles, context: context)
                case .timedOut, .modified:
                    return
                }
            }
            settle(next, outcome)
        }
    }

    // MARK: - 判一笔

    private struct Call {
        var tool: String
        var args: String
        var domain: PermissionDomain
    }

    /// 这一笔换成文件工具的一次调用（路径还原成落盘写法）
    private static func fileCall(for change: Change, profile: Profile, path: String? = nil, content: String? = nil) -> Call? {
        let stored = FileLibraryTools.storedWikiPath(path ?? change.path, user: profile.userName)
        let tool = (change.op == .delete ? FileLibraryTools.Name.delete : .write).rawValue
        var input: [String: Any] = ["path": stored]
        if change.op == .write { input["content"] = content ?? change.content }
        guard let data = try? JSONSerialization.data(withJSONObject: input), let args = String(data: data, encoding: .utf8) else { return nil }
        return Call(tool: tool, args: args, domain: PermissionDomain.forCall(named: tool, argumentsJSON: args))
    }

    private static func refused(_ change: Change, _ status: Status, _ message: String, profiles: [Profile], context: ModelContext) async -> Outcome {
        var content: String?
        if let profile = profiles.first(where: { $0.id == change.profileId }) {
            content = change.path == GardenTree.readmePath ? GardenMemorySync.lastReadme[profile.id]
                : await GardenTree.text(of: change.path, profile: profile, container: context.container)
        }
        return Outcome(change: change, status: status, message: message, path: change.path, content: content)
    }

    /// `approved` = 她已经点过允许（不再看「每次询问」那一档）
    static func judge(_ change: Change, approved: Bool, profiles: [Profile], context: ModelContext) async -> Outcome {
        func no(_ status: Status, _ message: String) async -> Outcome {
            await refused(change, status, message, profiles: profiles, context: context)
        }
        guard let profile = profiles.first(where: { $0.id == change.profileId }) else {
            return await no(.rejected, "这台设备的花园里没有这一层了。")
        }
        let path = change.path
        let container = context.container
        let isPrompt = PromptFolder.isPromptPath(path)

        // 1. 不在这棵树里的位置
        if path == GardenTree.readmePath { return await no(.readonly, "这份说明是花园排的，每次同步都会换成新的。") }
        guard isPrompt || FileLibraryMemoryFolder.isMemoryPath(path) else {
            return await no(.readonly, "这棵树里只有 memory/ 和 \(PromptFolder.root)/ 两处，别的文件不要放进来。")
        }
        if let why = GardenTree.exclusion(path) { return await no(.rejected, why) }
        let stored = FileLibraryTools.storedWikiPath(path, user: profile.userName)
        if !isPrompt {
            guard let normalized = MemoryFolderWrite.normalized(stored), normalized == stored else { return await no(.rejected, "路径不对：\(path)") }
            switch MemoryFolderWrite.kind(normalized) {
            case .readOnly(let why): return await no(.readonly, why)
            case .missing: return await no(.readonly, "这个位置不给助手用。")
            default: break
            }
        }

        // 2. 花园里这一份现在的样子：已经是 CC 写的那样就不用动；不是它基于的那一版 = 冲突
        let current = await GardenTree.text(of: path, profile: profile, container: container)
        if isPrompt {
            // Prompt 文件夹里只能改已有条目的正文（同文件工具）：注定落不下的不拿去问她
            let file = PromptFolderTools.files(profileId: profile.id).first { $0.path == path }
            if change.op == .delete || file == nil {
                return await no(.rejected, "\(PromptFolder.root)/ 里只能改已有文件的正文；新建、删除、开关插槽要在 app 的 Prompt 页做。")
            }
            if file?.editable == false { return await no(.readonly, PromptFolder.SaveError.readOnly.localizedDescription) }
        }
        if change.op == .write ? current == change.content : current == nil {
            return Outcome(change: change, status: .landed, message: "花园里已经是这样了。", path: path, content: current)
        }
        var target = path
        var content = change.content
        var movedCard: UUID?
        if change.op == .write, current == nil, MemoryCardFolder.isCardPath(stored),
           let behind = cardBehind(change, stored: stored, profileId: profile.id, context: context) {
            // 这份文件说的是一条已有的 C2 记忆条目（文件挪了文件夹 / 另存了一份）：当成改那一条，别新加一条
            guard behind.card.supersededAt == nil else {
                return await no(.rejected, "这条记忆条目在花园里已经删了（在 \(MemoryCardFolder.deletedFolder) 里），要放回来在花园里做。想新加一条就不要写 id。")
            }
            target = behind.path
            content = behind.content
            movedCard = behind.card.id
        } else if current.map(GardenTree.hash) != change.base {
            return await no(.conflict, current == nil ? "花园里这份已经没有了。" : "花园里这份已经不是你改的那一版了。")
        }

        // 3. 三档权限（按写的是哪一种分域）
        guard let call = fileCall(for: change, profile: profile, path: target, content: content) else { return await no(.rejected, "内容编不成请求。") }
        if !approved {
            switch PermissionCenter.level(call.domain, profileId: profile.id) {
            case .bypass: break
            case .notAllowed: return await no(.denied, "花园的权限里「\(call.domain.displayName)」这一档是不允许。")
            case .askOnce: return await no(.waiting, "要她在花园里点允许（\(call.domain.displayName)）。")
            }
        }

        // 4. 落：同聊天里文件工具的那一条路
        var before: Set<String> = []
        if current == nil, movedCard == nil { before = await GardenTree.paths(profile: profile, container: container) }
        let card = movedCard ?? (MemoryCardFolder.isCardPath(stored) && current != nil ? cardId(at: stored, profileId: profile.id, context: context) : nil)
        let r = await FileLibraryTools.run(name: call.tool, inputJSON: call.args, profileId: profile.id, userName: profile.userName,
                                           actor: MemoryCCBridge.actorName(profile.assistantName), conversationId: nil, memoryEnabled: true,
                                           via: MemoryAuditLog.viaCC, context: context)
        guard !r.isError else { return await no(.rejected, r.text) }

        // 5. 落下后它在树里的位置（C2 记忆条目会挪文件夹 / 进 Deleted；新建的文件名会换）
        var final = path
        if let card {
            let now = MemoryCardFolder.entries(profileId: profile.id, context: context).first { $0.card == card }?.path
            final = now.flatMap { GardenTree.exclusion($0) == nil ? $0 : nil } ?? path
        } else if current == nil, change.op == .write {
            let after = await GardenTree.paths(profile: profile, container: container)
            let made = after.subtracting(before)
            if !after.contains(path), made.count == 1, let only = made.first { final = only }
        }
        let landed = await GardenTree.text(of: final, profile: profile, container: container)
        return Outcome(change: change, status: .landed, message: final == path ? "" : "落下后在 \(final)。", path: final, content: landed)
    }

    private static func cardId(at stored: String, profileId: String, context: ModelContext) -> UUID? {
        MemoryCardFolder.entries(profileId: profileId, context: context).first { $0.path == stored }?.card
    }

    /// 一份「新建」的 C2 记忆条目文件其实说的是一条已有的（头里带着它的 id，或文件名就是它的编号）：
    /// 返回那一条、它现在的文件、要写上去的全文——文件夹换了而头里的 about 没动，就按文件夹改「说的是谁」（同 `fs_rename` 挪文件的规矩）
    private static func cardBehind(_ change: Change, stored: String, profileId: String, context: ModelContext) -> (card: Memory, path: String, content: String)? {
        let all = SwiftDataMemoryStore().listAll(profileId: profileId, context: context)
        let head = try? MemoryCardFolder.parse(change.content)
        var id = head?[.id].flatMap(UUID.init(uuidString:)).flatMap { id in all.contains { $0.id == id } ? id : nil }
        if id == nil, case .found(let byName) = MemoryCardTool.lookup(stored, in: all.map(\.id)) { id = byName }
        guard let id, let card = all.first(where: { $0.id == id }),
              let entry = MemoryCardFolder.entries(all).first(where: { $0.card == id }), entry.path != stored else { return nil }
        let parts = stored.split(separator: "/").map(String.init)
        let folder = parts.count == 4 ? parts[2] : nil
        let was = MemoryAudit.cleaned(card.subject) ?? ""
        guard let folder, folder != MemoryCardFolder.deletedFolder, MemoryCardFolder.root + "/" + folder != entry.folder,
              (head?[.about] ?? was) == was else { return (card, entry.path, change.content) }
        return (card, entry.path, settingAbout(change.content, to: folder == MemoryCardFolder.noSubjectFolder ? "" : folder))
    }

    /// 把条目头里的 about 换成给的值（没有头就补一个）
    static func settingAbout(_ text: String, to about: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func bare(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        let line = about.isEmpty ? "about:" : "about: \(about)"
        guard let open = lines.firstIndex(where: { !bare($0).isEmpty }), bare(lines[open]) == "---",
              let close = lines[(open + 1)...].firstIndex(where: { bare($0) == "---" }) else {
            return "---\n\(line)\n---\n\n" + text
        }
        if let index = lines[(open + 1)..<close].firstIndex(where: { bare($0).lowercased().hasPrefix(MemoryCardFolder.Key.about.rawValue) }) {
            lines[index] = line
        } else {
            lines.insert(line, at: close)
        }
        return lines.joined(separator: "\n")
    }
}
