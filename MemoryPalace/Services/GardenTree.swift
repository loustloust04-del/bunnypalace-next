import CryptoKit
import Foundation
import MemoryCore
import SwiftData

/// 同步到电脑上给 CC 读写的那棵树（粟粟 11-14「对 CC 来说文件夹就该在电脑上、CC 读写本地文件、改动流回花园」）：
/// 就是这层楼的助手用 `fs_list / fs_read` 在 `memory/` 和 `.prompt/` 下看到的那一棵——列哪些、每份读到什么，用的是文件工具的同一套函数
/// （`FileLibraryTools.memoryFiles / memoryText / shownPath`、`PromptFolderTools.files`），所以路径和内容两头一致；
/// 在这之上只滤掉不该出设备的（`exclusion`），再加一份给 CC 看的说明（`README.md`）。纯读，不改任何东西
enum GardenTree {
    static let readmePath = "README.md"
    /// 一份最大多少字节，超了不带（同 hub 的 GARDEN_TREE_MAX_FILE_BYTES：app 收发一帧的上限是 1MB，留一半）
    static let maxFileBytes = 512 * 1024
    /// 带出去的只有这两种（一条记忆一个 md，Prompt 的一段一个 txt）；别的后缀是程序自己用的账
    static let extensions: Set<String> = ["md", "txt"]

    struct Entry: Equatable, Sendable {
        /// 给助手看的路径（wiki 本人那组是名字）= 电脑上的相对路径
        var path: String
        var hash: String
        /// 落盘写法的路径；现排的（C2 记忆条目、日志、Prompt、说明）是 nil，全文在 `text`
        fileprivate var stored: String?
        fileprivate var text: String?
    }

    struct Snapshot: Sendable {
        var profileId: String
        var userName: String
        var entries: [Entry]
        /// 太大没带的（路径）
        var oversize: [String]

        /// 整棵树的指纹：一份没变就一个字不差（hub 存着上一次的，对得上就连清单都不用发）
        var digest: String {
            GardenTree.hash(entries.map { $0.path + "\t" + $0.hash }.sorted().joined(separator: "\n"))
        }

        /// 一份的全文。盘上的现在才读（读到的和算指纹时不一样了也照给：hub 会按指纹不收，下一轮再来）
        func content(_ path: String) -> String? {
            entries.first { $0.path == path }.flatMap(text)
        }

        /// 一批路径的全文（读不到的跳过）
        func contents(_ paths: [String]) -> [(path: String, content: String)] {
            let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            return paths.compactMap { path in byPath[path].flatMap(text).map { (path, $0) } }
        }

        private func text(_ entry: Entry) -> String? {
            if let text = entry.text { return text }
            guard let stored = entry.stored else { return nil }
            return try? FileLibraryTools.memoryText(stored, profileId: profileId, user: userName, container: nil)
        }
    }

    static func hash(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    // MARK: - 哪些不带出设备

    /// 这条路径（落盘写法或给助手看的写法都行）为什么不带到电脑上；nil = 带。
    /// 只有这几条，都是按位置 / 名字的规矩，不看内容：
    /// 私人的（任何一段以 `private_` 开头，同 CC 记忆同步和种子的规矩）、从 CC 那边同步进来的（再送回去是绕圈）、删了的 C2 记忆条目（同原来的导出）、
    /// wiki 页的历史版本（每改一次多一份，只在花园里看）、
    /// 不是 md / txt 的（程序自己用的账）
    static func exclusion(_ path: String) -> String? {
        if WikiProposalSources.isPrivate(path) { return "名字以 private_ 开头的是私人的，不带到电脑上。" }
        if path == ccFolder || path.hasPrefix(ccFolder + "/") { return "memory/cc/ 是从 CC 那边同步进花园的，要改去 CC 自己的记忆里改。" }
        if path.hasPrefix(MemoryRecordsFolder.historyFolder + "/") { return "页历史只在花园里看，不带到电脑上。" }
        if path.hasPrefix(deletedCards + "/") {
            return "删了的记忆条目不带到电脑上。要删一条，删掉它的文件或把 state 改成 \(MemoryCardFolder.states[2])；要放回来在花园里做。"
        }
        guard extensions.contains((path as NSString).pathExtension.lowercased()) else { return "这棵树里只有 .md 和 .txt。" }
        return nil
    }

    private static let ccFolder = FileLibraryMemoryFolder.root + "/" + CCMemorySync.subdir
    private static let deletedCards = MemoryCardFolder.root + "/" + MemoryCardFolder.deletedFolder

    // MARK: - 整棵

    /// 盘上文件的指纹缓存：路径 + 改动时间 + 大小没变就不重读（每次给 CC 发消息前都会排一遍）
    private static let cacheLock = NSLock()
    private static var hashCache: [String: (modifiedAt: Date, bytes: Int, hash: String)] = [:]

    /// 后台调（读盘 + 现排全部的 C2 记忆条目）。`promptFiles` = 主线程先取好的 `PromptFolderTools.files`
    nonisolated static func snapshot(profile: Profile, device: String, container: ModelContainer?,
                                     promptFiles: [PromptFolderTools.File]) -> Snapshot {
        let profileId = profile.id, user = profile.userName
        var entries: [Entry] = []
        var oversize: [String] = []
        func add(_ path: String, text: String) {
            guard text.utf8.count <= maxFileBytes else { oversize.append(path); return }
            entries.append(Entry(path: path, hash: hash(text), stored: nil, text: text))
        }
        // 现排的那几份（C2 记忆条目、钉住的清单、两份日志）全文一次取齐；列哪些照 `fs_list` 的那一份
        let virtual = Dictionary(MemoryVirtualFiles.all(profileId: profileId, container: container).map { ($0.path, $0.content) },
                                 uniquingKeysWith: { first, _ in first })
        for meta in FileLibraryTools.memoryFiles(profileId: profileId, container: container) where exclusion(meta.path) == nil {
            let shown = FileLibraryTools.shownPath(meta.path, user: user)
            if let text = virtual[meta.path] { add(shown, text: text); continue }
            guard meta.bytes <= maxFileBytes else { oversize.append(shown); continue }
            let key = profileId + "\u{0}" + user + "\u{0}" + meta.path
            let cached = cacheLock.withLock { hashCache[key] }
            if let cached, cached.modifiedAt == meta.modifiedAt, cached.bytes == meta.bytes {
                entries.append(Entry(path: shown, hash: cached.hash, stored: meta.path, text: nil))
                continue
            }
            guard let text = try? FileLibraryTools.memoryText(meta.path, profileId: profileId, user: user, container: nil) else { continue }
            guard text.utf8.count <= maxFileBytes else { oversize.append(shown); continue }
            let h = hash(text)
            cacheLock.withLock { hashCache[key] = (meta.modifiedAt, meta.bytes, h) }
            entries.append(Entry(path: shown, hash: h, stored: meta.path, text: nil))
        }
        for file in promptFiles where exclusion(file.path) == nil { add(file.path, text: file.content) }
        add(readmePath, text: readme(profile: profile, device: device, promptFiles: promptFiles, oversize: oversize))
        return Snapshot(profileId: profileId, userName: user, entries: entries, oversize: oversize)
    }

    // MARK: - 一份

    /// 树里一份现在的全文（`path` = 给助手看的写法）；不在树里（没有 / 不带出设备）= nil。说明那一份不在这里取
    @MainActor
    static func text(of path: String, profile: Profile, container: ModelContainer?) async -> String? {
        guard exclusion(path) == nil else { return nil }
        if PromptFolder.isPromptPath(path) { return PromptFolderTools.files(profileId: profile.id).first { $0.path == path }?.content }
        guard FileLibraryMemoryFolder.isMemoryPath(path) else { return nil }
        let stored = FileLibraryTools.storedWikiPath(path, user: profile.userName)
        let profileId = profile.id, user = profile.userName
        // 一条 C2 记忆条目只在它现在的那个位置（`MemoryVirtualFiles.read` 按文件名也读得到旧位置，这里不认）
        if MemoryCardFolder.isCardPath(stored), stored != MemoryCardFolder.pinnedPath {
            guard MemoryFlags.masterEnabled, let container else { return nil }
            return await Task.detached(priority: .userInitiated) {
                MemoryCardFolder.entries(profileId: profileId, container: container).first { $0.path == stored }?.content
            }.value
        }
        let text = await Task.detached(priority: .userInitiated) {
            try? FileLibraryTools.memoryText(stored, profileId: profileId, user: user, container: container)
        }.value
        guard let text, text.utf8.count <= maxFileBytes else { return nil }
        return text
    }

    /// 树里现在有哪些路径（给助手看的写法；不含说明那一份）。新建的文件落下后去了哪，靠前后各列一次比出来
    @MainActor
    static func paths(profile: Profile, container: ModelContainer?) async -> Set<String> {
        let profileId = profile.id, user = profile.userName
        let memory = await Task.detached(priority: .userInitiated) {
            FileLibraryTools.memoryFiles(profileId: profileId, container: container).map(\.path).filter { exclusion($0) == nil }
                .map { FileLibraryTools.shownPath($0, user: user) }
        }.value
        return Set(memory + PromptFolderTools.files(profileId: profileId).map(\.path).filter { exclusion($0) == nil })
    }

    // MARK: - 给 CC 看的说明

    /// 每次同步都带的那份 README：这棵树是什么、每一处是哪种记忆、怎么改、改了去哪看结果。
    /// 里面不放时间和数量（内容没变就不重发）；例子全是虚构的
    static func readme(profile: Profile, device: String, promptFiles: [PromptFolderTools.File], oversize: [String]) -> String {
        let user = profile.userName.isEmpty ? "对方" : profile.userName
        let assistant = profile.assistantName.isEmpty ? "助手" : profile.assistantName
        let fields = PromptFolder.Field.allCases.map { "`\($0.rawValue).txt` = \($0.label)" }.joined(separator: "、")
        let slots = promptFiles.filter { !$0.path.hasPrefix(PromptFolder.fieldsFolder + "/") }.map { "- `\($0.path)`：\($0.note)" }
        let states = MemoryCardFolder.states
        var out = """
        # 花园记忆 · \(profile.name)

        这个文件夹是「记忆花园」app 里「\(profile.name)」这一层的记忆，和 app 里 文件库 › 记忆 是同一棵树（来自 \(device)）。
        \(assistant)在花园里记下的、整理出来的东西都在这里：一条记忆一个文件，直接读、直接搜。和\(user)当面说的冲突时，以当面说的为准。

        ## 里面有什么

        | 位置 | 是什么 | 能不能改 |
        |---|---|---|
        | `memory/cards/<说的是谁>/<编号>.md` | 记忆条目：从聊天里一条条记下来的事实，一条一句话 | 能改、能新建、能删 |
        | `memory/cards/Pinned.md` | 钉住的记忆条目的清单 | 只读 |
        | `memory/self/<短标题>.md` | \(assistant)自己的记忆（主动记下的）；`\(SelfMemoryStore.indexFileName)` 是目录 | 能改、能新建、能删；目录只读 |
        | `memory/pending/待续.md` | 待续：说好以后再聊、再做的事，一条一行 | 能改已有的行；新加一条就加一行 `- 内容`（后面的注释不用写，落进花园后会补上） |
        | `memory/wiki/<组>/…/<页>.md` | wiki 页：按人、物、地点、事整理成篇的记忆；各层 `INDEX.md` 是目录 | 页能改、能新建、能删；目录只读 |
        | `memory/wiki/Proposals/` | wiki 的整理提案：等\(user)批的、批过的、驳回的，一份一个文件 | 只读 |
        | `memory/wiki/Notes/` | 要点卡：种子整理时照每份原料出的一张 | 只读 |
        | `memory/timeline/` | 时间轴：一天一条 | 只读 |
        | `memory/windows/` | 窗口总结：一个聊天窗口一份 | 只读 |
        | `memory/sessions/` | 上下文摘要：一个窗口里一段一段的摘要 | 只读 |
        | `memory/heartvoice/` | 心声：当时那一刻写下的 | 只读 |
        | `memory/log/` | 日志：记忆条目的每一笔改动、后台每一次写入 | 只读 |
        | `memory/profile-card.md`、`memory/user-card.md` | \(assistant)的资料卡、\(user)的资料卡 | 前一张能改，后一张只读 |
        | `.prompt/fields/<名字>.txt` | 这一层 Prompt 的楼层字段（见「改助手设定」） | 能改正文；不能新建、删 |
        | `.prompt/<一串编号>.txt` | 这一层当前预设的插槽（见「改助手设定」） | 能改正文（系统自动填的除外）；不能新建、删 |
        | `_sync/收件回执.md` | 你在这里改的每一笔，落没落进花园 | 只读 |
        | `README.md` | 这份说明 | 只读 |

        `.prompt` 以点开头，`ls` 默认不显示，按路径直接读。上面没列到的也都只读。

        ## 记忆条目长什么样

        开头两行 `---` 之间是这一条的各项，一行一项；下面是正文，一句离开上下文也看得懂的话。

        ```
        ---
        id: 3f9a1c2e-0000-4000-8000-000000000000
        state: \(states[1])
        created: 2026-11-12
        about: 岚舟
        from: \(FragmentPool.speakers[0])
        tags: [皮影, 周三]
        importance: 4
        confidence: 90
        pinned: no
        ---

        岚舟每周三去槐序巷皮影作坊学雕皮影。
        ```

        - 能改的项：\(MemoryCardFolder.editableKeys)，和正文。`about` = 说的是谁；`from` = 谁说的，只能写 \(FragmentPool.speakers.joined(separator: " / "))，不知道就留空；`importance` 1–5；`confidence` 0–100；`pinned` yes / no（钉住的每轮都带）；`state` 是 \(states[0])（还没人看过）/ \(states[1])（批过了）/ \(states[2])（删掉）。
        - 只读的项：\(MemoryCardFolder.readOnlyKeys)，是这一条的来历，原样留着。
        - 改一条：直接改它的文件。没写的项不动。
        - 新加一条：在 `memory/cards/<说的是谁>/` 下新建一个 `.md`，文件名随便起，落进花园后会换成这一条的编号。可以只写一句正文；要带各项就照上面写头，不要写 `id`。例：

        ```
        ---
        tags: [纸鸢]
        importance: 3
        ---

        星砚答应帮岚舟刻一只燕子形的纸鸢。
        ```

        - 删一条：删掉它的文件，或把 `state` 改成 \(states[2])。花园里它进 \(MemoryCardFolder.deletedFolder)，\(user)能放回；删了的不出现在这个文件夹里。
        - 换「说的是谁」：改 `about`，文件会自己挪到对应的文件夹。不要复制出第二份。

        `memory/self/` 和 wiki 页各有自己的头，照同一个文件夹里别的文件的样子写。

        ## 改助手设定

        `.prompt/fields/` 下是这一层的楼层字段：\(fields)。改文件的正文就是改那一段，从\(user)的下一条消息起生效；花园里会存下改之前的那一版，能回到上一版。

        """
        if !slots.isEmpty {
            out += "\n`.prompt/` 下其余的是这一层当前预设的插槽：\n" + slots.joined(separator: "\n") + "\n"
        }
        out += """

        只能改已有文件的正文；新建、删除、开关插槽要在 app 里做。

        ## 改了以后

        - 你在这里改、新建、删的文件会自动送回花园去落。落之前按花园里那一种记忆的权限走：自动允许的直接落；「每次询问」的要等\(user)在花园里点允许；「不允许」的会被退回。
        - 每一笔都记着是「CC 里的\(assistant)」改的，\(user)能撤回。
        - 结果在 `_sync/收件回执.md`，新的在前：落下了 / 被拒 / 冲突 / 只读 / 没落下（格式不对会写明是哪一行）。没落下的，这里的文件会恢复成花园现在的样子，你写的那份另存在 `_sync/没落下的/`。
        - 花园 app 没开着的时候，你改的先留在这里排着，回执的「还没落进花园」里看得到；app 连上以后按顺序送。
        - 花园是准：你改的时候花园里那份已经变了，就算冲突，不落。看另存的那份，照花园现在的样子重新改。
        - 只读的文件改了会被恢复。不在 `memory/` 和 `.prompt/` 里的文件不要放进来。

        ## 没带过来的

        名字以 `private_` 开头的、删了的记忆条目、wiki 页的历史版本（只在花园里看）、从 CC 这边同步进花园的笔记（`memory/cc/`）、不是 `.md` / `.txt` 的文件，不在这个文件夹里。

        """
        if !oversize.isEmpty {
            out += "这几份超过 \(maxFileBytes / 1024)KB，也没带：\n" + oversize.sorted().map { "- `\($0)`" }.joined(separator: "\n") + "\n"
        }
        return out
    }
}
