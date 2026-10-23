import Foundation

/// hub 连上时最先发的 `hello` 帧（#046 T3）：这台电脑叫什么、两个家和干活目录、装没装 tmux / claude / codex。
/// 配置或工具探测变了 hub 会再广播一次。老 hub 不发 → App 侧整个是 nil，界面按「不知道」画（不显示目录、不拦 Agent）。
///
/// 解析一律容错：字段缺失 / 类型不对都只当「没说」，不让一帧坏数据把连接层弄崩。
struct HubHello: Equatable {
    struct Dirs: Equatable {
        var claudeHome: String?
        var codexHome: String?
        /// nil = 没单独设，[+] 开的窗口落在各自的家
        var agentWorkdir: String?
    }

    /// 三态：true 装了 / false 没装 / nil 还不知道（hub 探测没跑完，或老 hub 没报）。只有 false 才拦。
    struct Tools: Equatable {
        var tmux: Bool?
        var claude: Bool?
        var codex: Bool?
    }

    var hubVersion: String?
    var hostName: String?
    /// `hw.model`，如 `Mac17,4`
    var hostModelId: String?
    /// 如「MacBook Air (15-inch, M5)」，Intel 机器没有
    var hostModelName: String?
    var dirs: Dirs
    var tools: Tools
    var capabilities: Set<String>

    init(hubVersion: String? = nil, hostName: String? = nil, hostModelId: String? = nil, hostModelName: String? = nil,
         dirs: Dirs = Dirs(), tools: Tools = Tools(), capabilities: Set<String> = []) {
        self.hubVersion = hubVersion
        self.hostName = hostName
        self.hostModelId = hostModelId
        self.hostModelName = hostModelName
        self.dirs = dirs
        self.tools = tools
        self.capabilities = capabilities
    }

    /// type 不是 hello 返回 nil；其余字段坏了只丢那一项。
    init?(frame: [String: Any]) {
        guard frame["type"] as? String == "hello" else { return nil }
        hubVersion = Self.text(frame["hub_version"])
        hostName = Self.text(frame["host_name"])
        hostModelId = Self.text(frame["host_model_id"])
        hostModelName = Self.text(frame["host_model_name"])
        let d = frame["dirs"] as? [String: Any] ?? [:]
        dirs = Dirs(claudeHome: Self.text(d["claude_home"]),
                    codexHome: Self.text(d["codex_home"]),
                    agentWorkdir: Self.text(d["agent_workdir"]))
        let t = frame["tools"] as? [String: Any] ?? [:]
        tools = Tools(tmux: Self.flag(t["tmux"]), claude: Self.flag(t["claude"]), codex: Self.flag(t["codex"]))
        capabilities = Set((frame["capabilities"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    /// 首页 / 状态行上的名字：「粟粟的 MacBook Pro · MacBook Air (15-inch, M5)」，缺哪段省哪段
    var displayName: String? {
        let parts = [hostName, hostModelName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `hub_config` 回帧（get_hub_config / set_agent_workdir 成功）只带三个目录：合进现有这份。
    /// key 不在帧里的保持原样；在帧里但是 null / 空串的清掉（agent_workdir 清掉 = 回到家）。
    mutating func merge(hubConfig frame: [String: Any]) {
        if frame.keys.contains("agent_workdir") { dirs.agentWorkdir = Self.text(frame["agent_workdir"]) }
        if frame.keys.contains("claude_home") { dirs.claudeHome = Self.text(frame["claude_home"]) }
        if frame.keys.contains("codex_home") { dirs.codexHome = Self.text(frame["codex_home"]) }
    }

    private static func text(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// JSONSerialization 把 true/false 解成 NSNumber：只认真布尔，数字 0/1 不算（hub 不会这么发，发了也当没说）
    private static func flag(_ any: Any?) -> Bool? {
        guard let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
}

/// `list_dirs` 的回帧：一层子文件夹（hub 只列文件夹、隐藏点开头的、最多 500 个）。
struct HubDirListing: Equatable {
    /// hub realpath 过的绝对路径
    var path: String
    /// nil = 已经在根上了
    var parent: String?
    var dirs: [String]
    var truncated: Bool

    /// 成功给 listing，失败给 hub 的中文原因（或兜底一句）。type 不对返回 nil。
    static func parse(_ frame: [String: Any]) -> Result<HubDirListing, CCBridgeRemoteError>? {
        guard frame["type"] as? String == "dir_list" else { return nil }
        if let error = frame["error"] as? String, !error.isEmpty {
            return .failure(CCBridgeRemoteError(reason: error))
        }
        guard let path = frame["path"] as? String, !path.isEmpty else {
            return .failure(CCBridgeRemoteError(reason: "电脑没说这是哪个文件夹"))
        }
        let parent = (frame["parent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let dirs = (frame["dirs"] as? [Any] ?? []).compactMap { $0 as? String }
        return .success(HubDirListing(path: path, parent: parent, dirs: dirs, truncated: frame["truncated"] as? Bool == true))
    }
}
