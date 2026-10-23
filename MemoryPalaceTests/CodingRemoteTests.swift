#if os(macOS)
import XCTest
@testable import 记忆花园

/// N4 远程主机：照抄 Wake `remote.rs` 单测（only_missing_sources 两方言 / remove_cached / 布局覆盖全家 / host 名注入 / 白名单 shell 安全且无凭证 /
/// 探测参数形状 / 探测输出白名单序 / rsync 参数形状）+ `models.rs` session_key_roundtrip + `services/terminal` 两条 ssh 续跑命令
final class CodingRemoteTests: XCTestCase {
    func testOnlyMissingSourcesRecognizesBothRsyncDialects() {
        // GNU rsync（Linux 远端做发送端，经本地客户端转出）
        let gnu = "rsync: [sender] link_stat \"/home/u/.codex/state_5.sqlite-wal\" failed: No such file or directory (2)\n"
            + "rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338)\n"
        XCTAssertTrue(CodingRemote.onlyMissingSources(gnu))
        // openrsync（macOS 远端做发送端）
        XCTAssertTrue(CodingRemote.onlyMissingSources("rsync(63771): error: .codex/state_5.sqlite-wal: (l)stat: No such file or directory\n"))
        // 混进一条权限错误就不算「只是消失」
        let mixed = "rsync: [sender] link_stat \"/x\" failed: No such file or directory (2)\n"
            + "rsync: [sender] send_files failed to open \"/y\": Permission denied (13)\n"
        XCTAssertFalse(CodingRemote.onlyMissingSources(mixed))
        // 一行错误都没有的 23：形状未知，不认
        XCTAssertFalse(CodingRemote.onlyMissingSources(""))
        XCTAssertFalse(CodingRemote.onlyMissingSources("rsync error: some files/attrs were not transferred (code 23)\n"))
    }

    func testRemoveCachedReportsFailuresButNotAbsence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 不存在：无事
        XCTAssertNil(CodingRemote.removeCached(dir.appendingPathComponent("nope")))
        // 文件与目录都删得掉
        let file = dir.appendingPathComponent("f")
        try Data("x".utf8).write(to: file)
        XCTAssertNil(CodingRemote.removeCached(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let sub = dir.appendingPathComponent("d/e")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertNil(CodingRemote.removeCached(dir.appendingPathComponent("d")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sub.path))
        // 路径穿过一个普通文件（ENOTDIR）：不是「不存在」，必须报错
        try Data("x".utf8).write(to: file)
        let error = try XCTUnwrap(CodingRemote.removeCached(file.appendingPathComponent("child")))
        XCTAssertTrue(error.contains("查不了旧缓存"), error)
    }

    func testLayoutsCoverEveryAgentExactlyOnce() {
        // 新增 agent 忘了补远程布局表，这里就是第一道报警
        var seen = Set<CodingAgent>()
        for layout in CodingRemote.layouts {
            XCTAssertTrue(seen.insert(layout.agent).inserted, "duplicate layout \(layout.agent)")
            XCTAssertFalse(layout.syncPaths.isEmpty)
            for path in layout.syncPaths {
                XCTAssertFalse(path.hasPrefix("/"), "sync path must be home-relative")
                XCTAssertFalse(path.contains(".."))
            }
            XCTAssertFalse(layout.mount.hasPrefix("/"))
        }
        for agent in CodingAgent.allCases {
            XCTAssertTrue(seen.contains(agent), "missing remote layout for \(agent)")
        }
        // 与 roster 声明序一致（Wake 布局表按 create_adapters 顺序）
        XCTAssertEqual(CodingRemote.layouts.map(\.agent), CodingSessionRoster.adapters(home: URL(fileURLWithPath: "/nonexistent"), environment: [:]).map(\.agent))
    }

    func testHostNameValidationBlocksInjection() {
        XCTAssertTrue(CodingRemote.validHostName("devbox"))
        XCTAssertTrue(CodingRemote.validHostName("corey@192.168.1.5"))
        XCTAssertTrue(CodingRemote.validHostName("my-host.example.com"))
        XCTAssertTrue(CodingRemote.validHostName("a"))
        // 选项注入与 key 分隔符
        XCTAssertFalse(CodingRemote.validHostName("-oProxyCommand=evil"))
        XCTAssertFalse(CodingRemote.validHostName(""))
        XCTAssertFalse(CodingRemote.validHostName("host:22"))
        XCTAssertFalse(CodingRemote.validHostName("host name"))
        XCTAssertFalse(CodingRemote.validHostName("host/../x"))
        XCTAssertFalse(CodingRemote.validHostName(".hidden"))
        // Swift 的 isLetter 认全部 Unicode 字母：非 ASCII 必须挡
        XCTAssertFalse(CodingRemote.validHostName("主机"))
        XCTAssertFalse(CodingRemote.validHostName("devbox\u{00E9}"))
    }

    func testSyncPathsAreShellSafe() {
        // 白名单路径不加引号直接进探测脚本（sh -c 单引号串内）与 rsync 源参数
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        for path in CodingRemote.allSyncPaths {
            XCTAssertTrue(path.allSatisfy { safe.contains($0) }, "sync path \(path) needs quoting")
        }
        // 凭证绝不在名单上
        XCTAssertFalse(CodingRemote.allSyncPaths.contains { $0.contains("auth.json") || $0.contains("oauth_creds") })
    }

    func testProbeArgumentsShape() {
        let args = CodingRemote.probeArguments(host: "devbox")
        XCTAssertEqual(Array(args[..<3]), ["-oBatchMode=yes", "-oConnectTimeout=10", "devbox"])
        // 一整条 sh -c '…'：每个白名单路径都在 for 列表里，循环体按行回显存在项
        let script = args[3]
        XCTAssertTrue(script.hasPrefix("sh -c 'for p in "))
        for path in CodingRemote.allSyncPaths {
            XCTAssertTrue(script.contains(" \(path) ") || script.contains(" \(path);"), "\(path) 不在探测列表里")
        }
        XCTAssertTrue(script.hasSuffix("; do if [ -e \"$p\" ]; then printf \"%s\\n\" \"$p\"; fi; done'"))
    }

    func testPresentPathsKeepsOnlyWhitelistInLayoutOrder() {
        // 乱序、重复、rc 文件的杂音、白名单项的父目录 / 子路径、绝对路径都要滤掉
        let out = "Welcome to devbox\n.grok/sessions\n.codex/sessions\n.codex\n.codex/sessions\n  .claude/projects  \n.claude/projects/evil\n/etc/passwd\n"
        XCTAssertEqual(CodingRemote.presentPaths(out), [".claude/projects", ".codex/sessions", ".grok/sessions"])
        XCTAssertTrue(CodingRemote.presentPaths("").isEmpty)
    }

    func testRsyncArgumentsShape() {
        let args = CodingRemote.rsyncArguments(host: "devbox", dest: URL(fileURLWithPath: "/tmp/cache/devbox"),
                                               paths: [".claude/projects", ".codex/state_5.sqlite"])
        XCTAssertEqual(args[0], "-az")
        XCTAssertTrue(args.contains("-R"))
        XCTAssertTrue(args.contains("--delete"))
        XCTAssertTrue(args.contains("ssh -oBatchMode=yes -oConnectTimeout=10"))
        // 只有探测确认存在的源，且都是 host:./ 锚定的 home 相对路径
        XCTAssertEqual(args.filter { $0.hasPrefix("devbox:") }, ["devbox:./.claude/projects", "devbox:./.codex/state_5.sqlite"])
        // 目标在最后
        XCTAssertEqual(args.last, "/tmp/cache/devbox")
        // 各家声明的 exclude 全部落到命令行（OpenClaw 的凭证靠它挡）
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-*")
        for pattern in CodingRemote.layouts.flatMap(\.exclude) {
            XCTAssertTrue(args.contains("--exclude=\(pattern)"), "\(pattern) 未进 rsync 参数")
            XCTAssertTrue(pattern.allSatisfy { safe.contains($0) }, "exclude \(pattern) needs quoting")
        }
        XCTAssertTrue(args.contains("--exclude=openclaw-agent.sqlite*"))
    }

    func testSessionKeyRoundtrip() {
        let local = CodingSessionKey.make(.claudeCode, host: "", nativeId: "u1")
        XCTAssertEqual(local, "claude-code:u1")
        XCTAssertEqual(CodingSessionKey.nativeId(of: local, agent: .claudeCode, host: ""), "u1")
        let remote = CodingSessionKey.make(.claudeCode, host: "devbox", nativeId: "u1")
        XCTAssertEqual(remote, "claude-code:devbox:u1")
        XCTAssertEqual(CodingSessionKey.nativeId(of: remote, agent: .claudeCode, host: "devbox"), "u1")
        // 本地实例不认三段 key；别的 host / 别的家都不认
        XCTAssertNil(CodingSessionKey.nativeId(of: remote, agent: .claudeCode, host: ""))
        XCTAssertNil(CodingSessionKey.nativeId(of: remote, agent: .claudeCode, host: "other"))
        XCTAssertNil(CodingSessionKey.nativeId(of: remote, agent: .codex, host: "devbox"))
    }

    private func remoteMeta(_ agent: CodingAgent, _ id: String, _ project: String) -> CodingSessionMeta {
        CodingSessionMeta(key: CodingSessionKey.make(agent, host: "devbox", nativeId: id), nativeId: id, agent: agent, title: "",
                          projectPath: project, projectName: "", filePath: "", createdAt: 0, updatedAt: 0, messageCount: 0,
                          sizeBytes: 0, gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil, host: "devbox")
    }

    func testSshResumeCommandQuotesNestedLayers() {
        // 内层 cd 的单引号在外层被 '\'' 转义，整条可直接贴 POSIX shell
        XCTAssertEqual(CodingSessionResume.sshCommand(for: remoteMeta(.codex, "abc-123", "/home/dev/my project")),
                       #"ssh -t devbox 'cd '\''/home/dev/my project'\'' && codex resume abc-123'"#)
    }

    func testSshResumeCommandVariants() {
        // 无 cwd：落 ssh 默认 home，不产出空 cd
        XCTAssertEqual(CodingSessionResume.sshCommand(for: remoteMeta(.claudeCode, "u-1", "")), "ssh -t devbox 'claude --resume u-1'")
        // opencode2 会话换二进制，与本地续跑同一分流
        var meta = remoteMeta(.opencode, "s1", "/w")
        meta.source = "opencode2"
        XCTAssertEqual(CodingSessionResume.sshCommand(for: meta), "ssh -t devbox 'cd /w && opencode2 --session s1'")
        // 本地会话不产出 ssh 命令
        meta = remoteMeta(.codex, "abc", "/w")
        meta.host = ""
        XCTAssertNil(CodingSessionResume.sshCommand(for: meta))
        // 没有续跑形制的家不出
        XCTAssertNil(CodingSessionResume.sshCommand(for: remoteMeta(.kiro, "k", "/w")))
    }
}
#endif
