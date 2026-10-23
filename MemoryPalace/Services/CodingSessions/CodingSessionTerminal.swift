#if os(macOS)
import AppKit

/// 续跑目标（plan-wake-native-n1 §2.6，Wake `services/terminal/macos.rs`）：MP 自己的终端面板 + 四家 shell 终端 + Claude / Codex 桌面版深链。
enum CodingResumeTarget: String, CaseIterable, Sendable {
    /// MP 自己的终端面板（plan-mp-local-terminal A5）：`CodingSessionLibrary.resume` 必拦下来开面板，下面的分发走不到它
    case memoryPalace = "memory-palace"
    case terminal
    case iterm
    case warp
    case ghostty
    case claudeDesktop = "claude-desktop"
    case codexDesktop = "codex-desktop"

    var displayName: String {
        switch self {
        case .memoryPalace: return "记忆花园"
        case .terminal: return "终端"
        case .iterm: return "iTerm"
        case .warp: return "Warp"
        case .ghostty: return "Ghostty"
        case .claudeDesktop: return "Claude 桌面版"
        case .codexDesktop: return "Codex 桌面版"
        }
    }

    var isDeepLink: Bool { self == .claudeDesktop || self == .codexDesktop }

    /// 深链目标只接自家 agent 的会话；shell 目标只接有续跑形制的家
    func supports(_ agent: CodingAgent) -> Bool {
        switch self {
        case .claudeDesktop: return agent == .claudeCode
        case .codexDesktop: return agent == .codex
        default: return CodingSessionResume.canResume(agent)
        }
    }

    private var bundleName: String {
        switch self {
        case .memoryPalace: return ""
        case .terminal: return "Terminal.app"
        case .iterm: return "iTerm.app"
        case .warp: return "Warp.app"
        case .ghostty: return "Ghostty.app"
        case .claudeDesktop: return "Claude.app"
        case .codexDesktop: return "ChatGPT.app"
        }
    }

    /// 同名不同物的 app 按 bundle id 验明正身（旧版 ChatGPT.app 不注册 codex://）
    private var bundleMarker: String? {
        switch self {
        case .claudeDesktop: return "com.anthropic.claudefordesktop"
        case .codexDesktop: return "com.openai.codex"
        default: return nil
        }
    }

    /// 已安装的 .app（`/Applications` 优先，再试 `~/Applications`；终端在系统目录）
    func appPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        if self == .memoryPalace { return Bundle.main.bundlePath }
        let candidates = self == .terminal
            ? ["/System/Applications/Utilities/Terminal.app"]
            : ["/Applications/\(bundleName)", home.appendingPathComponent("Applications/\(bundleName)").path]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            guard let marker = bundleMarker else { return path }
            if let plist = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")),
               plist.range(of: Data(marker.utf8)) != nil {
                return path
            }
        }
        return nil
    }

    static func installed(for agent: CodingAgent) -> [CodingResumeTarget] {
        allCases.filter { $0.supports(agent) && $0.appPath() != nil }
    }
}

extension CodingSessionResume {
    /// 单行 shell 命令（iTerm / Ghostty / Warp 用）：项目目录在就先 cd
    static func shellCommand(for meta: CodingSessionMeta) -> String? {
        guard let invocation = invocation(for: meta) else { return nil }
        let (bin, args) = invocation
        let run = ([bin] + args.map(CodingShellQuote.single)).joined(separator: " ")
        if !meta.projectPath.isEmpty, FileManager.default.fileExists(atPath: meta.projectPath) {
            return "cd \(CodingShellQuote.single(meta.projectPath)) && \(run)"
        }
        return run
    }

    /// 按目标续跑；失败回错误说明
    @discardableResult
    static func resume(_ meta: CodingSessionMeta, target: CodingResumeTarget) -> String? {
        switch target {
        case .memoryPalace:
            // 走不到：Library.resume 先拦下来开面板（这里回一句只为 switch 完备）
            return "记忆花园的终端要从界面打开"
        case .terminal:
            return resume(meta)
        case .iterm:
            guard let raw = shellCommand(for: meta) else { return noResume(meta) }
            let command = appleScriptQuote(raw)
            return osascript([
                "tell application \"iTerm\" to activate",
                "tell application \"iTerm\" to create window with default profile",
                "tell current session of current window of application \"iTerm\" to write text \"\(command)\"",
            ])
        case .ghostty:
            guard let command = shellCommand(for: meta) else { return noResume(meta) }
            return run("/usr/bin/open", ["-na", "Ghostty", "--args", "-e", "/bin/zsh", "-lic", "\(command); exec /bin/zsh -il"])
        case .warp:
            guard let command = shellCommand(for: meta) else { return noResume(meta) }
            guard !command.contains("\n") else { return "Warp 只接单行命令" }
            let yaml = "name: MP Resume\nwindows:\n  - tabs:\n      - layout:\n          commands:\n            - exec: |-\n                \(command)\n"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mp-warp-resume.yaml")
            do {
                try yaml.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return "写 Warp 启动配置失败：\(error.localizedDescription)"
            }
            return run("/usr/bin/open", ["warp://launch/\(url.path)"])
        case .claudeDesktop, .codexDesktop:
            switch desktopURL(for: meta, target: target) {
            case .success(let url):
                return NSWorkspace.shared.open(url) ? nil : "打不开\(target.displayName)"
            case .failure(let message):
                return message.text
            }
        }
    }

    struct Failure: Error { let text: String }

    /// 桌面版深链。对端只认裸 UUID——不合格就地报错（`open` 对已注册 scheme 恒成功，对端静默丢弃看不见）。
    /// Claude：先查 desktop 自己的会话索引，这条 CLI 会话已被某个 desktop 会话收编就发那条的 stem，避免重复导入
    static func desktopURL(for meta: CodingSessionMeta, target: CodingResumeTarget,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Result<URL, Failure> {
        guard target.supports(meta.agent) else { return .failure(Failure(text: "\(target.displayName)打不开 \(meta.agent.displayName) 的会话")) }
        var id = meta.nativeId
        if target == .claudeDesktop, isUUID(id), let owned = claudeDesktopOwnedStem(cliId: id, home: home) {
            id = owned
        }
        guard isUUID(id) else { return .failure(Failure(text: "\(target.displayName)只能打开 UUID 形态的会话（这条是 `\(id)`）")) }
        let prefix = target == .claudeDesktop ? "claude://resume?session=" : "codex://threads/"
        guard let url = URL(string: prefix + id) else { return .failure(Failure(text: "深链拼不出来")) }
        return .success(url)
    }

    /// 在 Claude 桌面版会话索引（claude-code-sessions/<账户>/<组织>/local_*.json）里找拥有这个 CLI 会话 id 的记录，
    /// 返回其 stem uuid；多份命中取 mtime 最新（基本即当前账户）。每次现扫，不缓存（desktop 随时在写）
    static func claudeDesktopOwnedStem(cliId: String, home: URL) -> String? {
        guard !cliId.isEmpty else { return nil }
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        let fm = FileManager.default
        var best: (date: Date, stem: String)?
        let needle = Data(cliId.utf8)
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file), data.range(of: needle) != nil,
                          let json = (try? JSONSerialization.jsonObject(with: data)) as? CodingParse.JSON else { continue }
                    let owns = ["cliSessionId", "unarchivedCliSessionId", "preClearCliSessionId"].contains { json[$0] as? String == cliId }
                        || ((json["priorCliSessionIds"] as? [Any])?.contains { $0 as? String == cliId } ?? false)
                    guard owns, let sessionId = json["sessionId"] as? String, sessionId.hasPrefix("local_") else { continue }
                    let stem = String(sessionId.dropFirst(6))
                    guard isUUID(stem) else { continue }
                    let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if best == nil || date > best!.date { best = (date, stem) }
                }
            }
        }
        return best?.stem
    }

    /// 裸 UUID（8-4-4-4-12 hex，大小写不限）
    static func isUUID(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count == 36 else { return false }
        for (i, c) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if c != UInt8(ascii: "-") { return false }
            } else if !((48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c)) {
                return false
            }
        }
        return true
    }

    /// AppleScript 字符串只转 `\` 与 `"`（命令恒单行）
    static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func osascript(_ lines: [String]) -> String? {
        run("/usr/bin/osascript", lines.flatMap { ["-e", $0] })
    }

    private static func run(_ tool: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return message.isEmpty ? "\(tool) 退出码 \(process.terminationStatus)" : message
        }
        return nil
    }
}
#endif
