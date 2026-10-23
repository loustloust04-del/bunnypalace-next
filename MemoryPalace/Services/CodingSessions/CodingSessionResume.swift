#if os(macOS)
import AppKit

/// 在终端继续（Wake `services/terminal`）：拼好命令写成临时 `.command` 交给系统打开（默认 = 终端）。
/// 不走 AppleScript → 不弹「控制终端」授权；脚本用交互登录 shell 跑，PATH 与她平时终端一致（R-WN #11）。
enum CodingSessionResume {
    /// (可执行名, 参数)（Wake `agent_bin` + `resume_args`）；没有按会话续跑形制的家（Kiro / Gemini / OpenClaw）回 nil。
    /// 项目目录在就先 cd（Claude / Qoder / dsh 必须在原目录，其余无害）
    static func invocation(for meta: CodingSessionMeta) -> (bin: String, args: [String])? {
        let id = meta.nativeId
        switch meta.agent {
        case .claudeCode: return ("claude", ["--resume", id])
        case .codex: return ("codex", ["resume", id])
        case .grok: return ("grok", ["--resume", id])
        // dsh web 没有按会话的深链：cd 到会话目录拉起 web，会话在界面里点着续
        case .dsh: return ("npx", ["@deepseek-ai/dsh", "web"])
        case .cursor: return ("cursor-agent", ["--resume", id])
        // OpenCode 2 与 stable 并存、装成 opencode2：v2 会话（source = opencode2）必须由它续
        case .opencode: return (meta.source == "opencode2" ? "opencode2" : "opencode", ["--session", id])
        case .pi: return ("pi", ["--session", id])
        case .omp: return ("omp", ["--resume", id])
        case .kimi: return ("kimi", ["--session", id])
        case .copilot: return ("copilot", ["--resume=\(id)"])
        case .antigravity: return ("agy", ["--conversation=\(id)"])
        case .qoder: return ("qoder", ["--resume", id])
        // --profile 必带：显式覆盖 Hermes 记住的 active_profile，会话在哪个档案库就开哪个
        case .hermes: return ("hermes", ["--profile", hermesProfile(meta.filePath), "--resume", id])
        case .kiro, .gemini, .openclaw: return nil
        }
    }

    static func canResume(_ agent: CodingAgent) -> Bool {
        ![.kiro, .gemini, .openclaw].contains(agent)
    }

    /// 详情头续跑钮文案：dsh 是拉起 web 让她自己点，不叫「继续」
    static func resumeLabel(_ agent: CodingAgent) -> String {
        agent == .dsh ? "打开 DeepSeek Harness" : "在终端继续"
    }

    static func noResume(_ meta: CodingSessionMeta) -> String {
        "\(meta.agent.displayName) 没有按会话续跑的命令"
    }

    /// Hermes 档案名：`profiles/<name>/state.db` → name，其余（主库）→ default（Wake `hermes::profile_of`）
    static func hermesProfile(_ filePath: String) -> String {
        let dir = URL(fileURLWithPath: CodingVirtualPath.strip(filePath)).deletingLastPathComponent()
        return dir.deletingLastPathComponent().lastPathComponent == "profiles" ? dir.lastPathComponent : "default"
    }

    /// 远程会话的「继续」（Wake `ssh_resume_command`）：`ssh -t <host> 'cd <远端 cwd> && <bin> <args>'`，只复制不代起终端。CLI 用裸名交
    /// 远端 PATH 解析（远端没装由远端 shell 报）；cwd 是远端路径、本地存在性判据无意义——非空就 cd，空则落 ssh 默认 home。本地会话回 nil
    static func sshCommand(for meta: CodingSessionMeta) -> String? {
        guard !meta.host.isEmpty, let invocation = invocation(for: meta) else { return nil }
        var inner = ([invocation.bin] + invocation.args).map(CodingShellQuote.posix).joined(separator: " ")
        if !meta.projectPath.isEmpty { inner = "cd \(CodingShellQuote.posix(meta.projectPath)) && \(inner)" }
        return "ssh -t \(CodingShellQuote.posix(meta.host)) \(CodingShellQuote.posix(inner))"
    }

    static func script(for meta: CodingSessionMeta) -> String? {
        guard let invocation = invocation(for: meta) else { return nil }
        let (bin, args) = invocation
        var lines = ["#!/bin/zsh -il"]
        // 项目目录没了就不 cd（N0-1：原来 `cd || exit` 让终端一打开就退）
        if !meta.projectPath.isEmpty, FileManager.default.fileExists(atPath: meta.projectPath) {
            lines.append("cd \(CodingShellQuote.single(meta.projectPath))")
        }
        lines.append(([bin] + args.map(CodingShellQuote.single)).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    /// 写临时脚本并打开；失败回错误说明
    @discardableResult
    static func resume(_ meta: CodingSessionMeta) -> String? {
        guard let body = script(for: meta) else { return noResume(meta) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mp-resume-\(UUID().uuidString.prefix(8)).command")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return "写续跑脚本失败：\(error.localizedDescription)"
        }
        return NSWorkspace.shared.open(url) ? nil : "打不开终端（.command 没有默认打开方式）"
    }

    static func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
#endif
