#if os(macOS)
import Foundation

/// 思考链回传的 hook 自检安装（仅 Mac——hub/CC 都跑在 Mac 上）。
/// app 启动时调：把 bundle 里的 thinking-hook.py / askuser-hook.py 装到 Application Support，
/// 并确保 CC workdir 的项目级 settings.json 开了 showThinkingSummaries + 挂了 Stop / AskUserQuestion hook。
///
/// settings.json 一律经 `AgentConfigEditor` 改（research-magpie 2.3）：只动我们那几个 key，
/// 用户的 key 顺序/缩进/注释原样保留；内容没变不写；解析不了不动；原子写保权限。
/// 被改掉的原值先记进 stash（`<support>/cc/settings-stash.json`），`uninstall()` 据此还原。
enum CCThinkingHookInstaller {
    /// 测试注入：非 nil 时 workdir = root/cc-rp，support = root/support（跟 BackupStore.overrideRoot 同款）。
    static var overrideRoot: URL?

    /// CC workdir，跟 hub.ts 的 ccWorkdir() 默认值一致。
    static var workdir: URL {
        if let overrideRoot { return overrideRoot.appendingPathComponent("cc-rp", isDirectory: true) }
        if let path = ProcessInfo.processInfo.environment["MP_CC_WORKDIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let legacy = NSString(string: "~/Desktop/cc-rp").expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: legacy, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace/cc-bridge/cc-rp", isDirectory: true)
    }

    /// hook 脚本与 stash 所在目录：Application Support/MemoryPalace/cc
    static var supportDir: URL {
        let base = overrideRoot?.appendingPathComponent("support", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MemoryPalace/cc", isDirectory: true)
    }

    static var settingsURL: URL { workdir.appendingPathComponent(".claude/settings.json") }
    static var stashURL: URL { supportDir.appendingPathComponent("settings-stash.json") }

    private static let thinkingMarker = "thinking-hook.py"
    private static let askMarker = "askuser-hook.py"
    private static let askEvents = ["PreToolUse", "PostToolUse"]

    static func ensureInstalled() {
        if TestHostIsolation.blocks(.ccHook) { return }   // #035：测试宿主不改 cc-rp 的 settings.json
        let fm = FileManager.default
        guard fm.fileExists(atPath: workdir.path) else { return }   // 没配 CC 桥，不折腾
        guard let bundled = Bundle.main.url(forResource: "thinking-hook", withExtension: "py"),
              let hookData = try? Data(contentsOf: bundled) else { return }

        // 1. hook 脚本装到 Application Support（内容变了就覆盖 = 随 app 升级）
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let hookDst = supportDir.appendingPathComponent(thinkingMarker)
        if fm.contents(atPath: hookDst.path) != hookData {
            try? AgentConfigEditor.writeAtomic(hookData, to: hookDst)
        }
        // 问问题 CC 桥（plan-问问题-cc桥）：askuser-hook.py 装到同目录
        var askPath: String?
        if let askBundled = Bundle.main.url(forResource: "askuser-hook", withExtension: "py"),
           let askData = try? Data(contentsOf: askBundled) {
            let askDst = supportDir.appendingPathComponent(askMarker)
            if fm.contents(atPath: askDst.path) != askData {
                try? AgentConfigEditor.writeAtomic(askData, to: askDst)
            }
            askPath = askDst.path
        }

        // 2. workdir/.claude/settings.json（解析不了会抛错 → 不动文件）
        _ = try? applySettings(thinkingHookPath: hookDst.path, askHookPath: askPath)
    }

    /// 开 showThinkingSummaries + 挂 Stop hook（+ AskUserQuestion 的 Pre/PostToolUse hook）。
    /// 返回是否写了文件；settings.json 解析不了时抛错且不动文件、不记 stash。
    @discardableResult
    static func applySettings(thinkingHookPath: String, askHookPath: String?) throws -> Bool {
        var pending: [(keyPath: String, original: Any?)] = []
        let wrote = try AgentConfigEditor.update(fileAt: settingsURL) { text in
            pending = []
            var t = text
            let current = try AgentConfigEditor.value(at: ["showThinkingSummaries"], in: t)
            if (current as? Bool) != true {
                pending.append(("showThinkingSummaries", current))
                t = try AgentConfigEditor.setting(true, at: ["showThinkingSummaries"], in: t)
            }

            var hooksRecorded = false
            func ensureHook(event: String, marker: String, entry: AgentConfigEditor.OrderedObject) throws {
                let existing = try AgentConfigEditor.value(at: ["hooks", event], in: t)
                if let arr = existing as? [Any], arr.contains(where: { entryRuns($0, marker: marker) }) { return }
                if !hooksRecorded {
                    hooksRecorded = true
                    pending.append(("hooks", try AgentConfigEditor.value(at: ["hooks"], in: t)))
                }
                pending.append(("hooks.\(event)", existing))
                t = try AgentConfigEditor.appending(entry, toArrayAt: ["hooks", event], in: t)
            }

            try ensureHook(event: "Stop", marker: thinkingMarker,
                           entry: .init([("hooks", [command("python3 '\(thinkingHookPath)'")])]))
            if let askHookPath {
                for event in askEvents {
                    try ensureHook(event: event, marker: askMarker, entry: .init([
                        ("matcher", "AskUserQuestion"),
                        ("hooks", [command("python3 '\(askHookPath)'")]),
                    ]))
                }
            }
            return t
        }
        if wrote {
            var stash = AgentConfigStash(url: stashURL)
            for p in pending { stash.record(file: settingsURL, keyPath: p.keyPath, original: p.original) }
            try stash.save()
        }
        return wrote
    }

    /// 卸载还原：摘掉我们挂的 hook，按 stash 把改过的 key 还原（原来没有的删掉），再清掉 stash 里这份文件的记录。
    /// 用户后来自己加的 hook / key 不受影响。返回是否写了文件。
    @discardableResult
    static func uninstall() throws -> Bool {
        var stash = AgentConfigStash(url: stashURL)
        let entries = stash.entries(for: settingsURL)
        var wrote = false
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            wrote = try AgentConfigEditor.update(fileAt: settingsURL) { text in
                var t = text
                for (event, marker) in [("Stop", thinkingMarker)] + askEvents.map({ ($0, askMarker) }) {
                    t = try AgentConfigEditor.removingItems(inArrayAt: ["hooks", event], in: t) { entryRuns($0, marker: marker) }
                    if case .absent? = entries["hooks.\(event)"],
                       let arr = try AgentConfigEditor.value(at: ["hooks", event], in: t) as? [Any], arr.isEmpty {
                        t = try AgentConfigEditor.removing(at: ["hooks", event], in: t)
                    }
                }
                if case .absent? = entries["hooks"],
                   let hooks = try AgentConfigEditor.value(at: ["hooks"], in: t) as? [String: Any], hooks.isEmpty {
                    t = try AgentConfigEditor.removing(at: ["hooks"], in: t)
                }
                switch entries["showThinkingSummaries"] {
                case .absent?: t = try AgentConfigEditor.removing(at: ["showThinkingSummaries"], in: t)
                case .value(let v)?: t = try AgentConfigEditor.setting(v, at: ["showThinkingSummaries"], in: t)
                case nil: break
                }
                return t
            }
        }
        stash.forget(file: settingsURL)
        try stash.save()
        return wrote
    }

    private static func command(_ cmd: String) -> AgentConfigEditor.OrderedObject {
        .init([("type", "command"), ("command", cmd)])
    }

    /// 一条 hook 配置项里是否有命令跑的是 marker 脚本
    private static func entryRuns(_ entry: Any, marker: String) -> Bool {
        (((entry as? [String: Any])?["hooks"] as? [Any]) ?? []).contains {
            (($0 as? [String: Any])?["command"] as? String)?.contains(marker) == true
        }
    }
}

/// 被我们改掉的 agent 配置原值（magpie `agent/stash.go` 同思路）。
/// 形状：`{ "<配置文件绝对路径>": { "<key.path>": {"value": 原值} | {"absent": true} } }`。
/// 同一 key 只记第一次（重复安装不会把「已被我们改过的值」当成原值）。
struct AgentConfigStash {
    enum Entry { case absent, value(Any) }

    let url: URL
    private var table: [String: [String: [String: Any]]]

    init(url: URL) {
        self.url = url
        let data = FileManager.default.contents(atPath: url.path)
        table = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: [String: [String: Any]]] } ?? [:]
    }

    private static func key(_ file: URL) -> String { file.resolvingSymlinksInPath().path }

    mutating func record(file: URL, keyPath: String, original: Any?) {
        var entries = table[Self.key(file)] ?? [:]
        guard entries[keyPath] == nil else { return }
        entries[keyPath] = original.map { ["value": $0] } ?? ["absent": true]
        table[Self.key(file)] = entries
    }

    func entries(for file: URL) -> [String: Entry] {
        (table[Self.key(file)] ?? [:]).compactMapValues { e in
            if e["absent"] as? Bool == true { return .absent }
            return e["value"].map { .value($0) }
        }
    }

    mutating func forget(file: URL) {
        table.removeValue(forKey: Self.key(file))
    }

    func save() throws {
        let data = try JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgentConfigEditor.writeAtomic(data, to: url, newFilePermissions: 0o600)
    }
}
#endif
