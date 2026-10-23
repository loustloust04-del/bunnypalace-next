#if os(macOS)
import XCTest
@testable import 记忆花园

/// N4 真 SSH 验证（粟粟选 B：一次性容器）：真 OpenSSH 客户端 → 容器里的 sshd，远端 GNU rsync 做发送端、本机 openrsync 接收（N4 自动化没覆盖的
/// 组合），其余与 `CodingRemoteSyncTests` 同一条流水线：探测 → 白名单镜像 → 真实 roster + 扫描入库 → 远端删除传播到缓存。
/// **默认跳过**：`scripts/wake-native/remote-ssh-e2e.sh` 起容器、生成一次性密钥后经 `TEST_RUNNER_MP_REAL_SSH_*` 打开。
/// 不碰她的 `~/.ssh`：ssh 经 PATH 前置的包装脚本 `-F` 指向 tmp 配置（一次性密钥、IdentitiesOnly、不用 agent、不读写 known_hosts）
final class CodingRemoteRealSSHTests: XCTestCase {
    private static let host = "mpdevbox"
    private static let claudeU1 = ".claude/projects/-Users-tester-Github-wakefx/11111111-aaaa-bbbb-cccc-000000000001.jsonl"
    private static let codexR2 = ".codex/sessions/2026/08/02/rollout-2026-08-02T09-15-00-22222222-aaaa-bbbb-cccc-000000000002.jsonl"
    private static let grokS7 = ".grok/sessions/%2FUsers%2Ftester%2FGithub%2Fwakefx/77777777-aaaa-bbbb-cccc-000000000007"
    private static let dshLog = ".dsh/sessions/--Users-tester-Github-wakefx--/dsh-e2e4-0001/session.jsonl.zstd"

    private var dir: URL!
    private var dockerPath = ""
    private var container = ""
    private var remoteHome: URL { dir.appendingPathComponent("remote-home") }
    private var localHome: URL { dir.appendingPathComponent("local-home") }
    private var bin: URL { dir.appendingPathComponent("bin") }
    private var indexURL: URL { dir.appendingPathComponent("index.sqlite") }
    private var cacheRoot: URL { CodingRemote.cacheRoot(indexURL: indexURL) }
    private var cache: URL { CodingRemote.hostCacheDir(cacheRoot, host: Self.host) }
    private var environment: [String: String] { ["PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"] }
    /// Copilot 故意缺席：白名单里唯一「连父目录都不存在」的形状，排在 cursor…dsh 之前——openrsync / GNU rsync 截断文件列表的触发条件
    private var remoteAgents: [CodingAgent] { CodingAgent.allCases.filter { $0 != .copilot } }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["MP_REAL_SSH_KEY"], let port = env["MP_REAL_SSH_PORT"], let name = env["MP_REAL_SSH_CONTAINER"],
              let dockerBin = env["MP_REAL_SSH_DOCKER"] else {
            throw XCTSkip("真 SSH 验证：由 scripts/wake-native/remote-ssh-e2e.sh 起容器后打开")
        }
        dockerPath = dockerBin
        container = name
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-real-ssh-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: localHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

        let config = dir.appendingPathComponent("ssh_config")
        try """
            Host \(Self.host)
              HostName 127.0.0.1
              Port \(port)
              User tester
              IdentityFile \(key)
              IdentitiesOnly yes
              IdentityAgent none
              StrictHostKeyChecking no
              UserKnownHostsFile /dev/null
              GlobalKnownHostsFile /dev/null
              LogLevel ERROR

            """.write(to: config, atomically: true, encoding: .utf8)
        let ssh = bin.appendingPathComponent("ssh")
        try "#!/bin/sh\nexec /usr/bin/ssh -F '\(config.path)' \"$@\"\n".write(to: ssh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)

        // 远端 home：整套假 home 铺进容器；凭证在白名单外，必须留在远端
        try CodingFakeHome.stage(remoteHome)
        try fm.removeItem(at: remoteHome.appendingPathComponent(".copilot"))
        try Data("NOT-A-REAL-SECRET".utf8).write(to: remoteHome.appendingPathComponent(".codex/auth.json"))
        try docker(["cp", remoteHome.path + "/.", "\(container):/home/tester/"])
        try docker(["exec", container, "chown", "-R", "tester:tester", "/home/tester"])
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    @discardableResult
    private func docker(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "docker", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "docker \(args.joined(separator: " ")): \(text)"])
        }
        return text
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testRealSSHPipelineAgainstLinuxRsync() throws {
        let rsyncVersion = try docker(["exec", container, "rsync", "--version"]).split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(rsyncVersion.contains("rsync"), rsyncVersion)
        print("mp-real-ssh remote: \(rsyncVersion)")

        // ① 首次同步：缺父目录的 .copilot 之后的源照样全到，exclude 与凭证不进缓存
        let first = CodingRemote.syncHosts([Self.host], cacheRoot: cacheRoot, environment: environment)
        XCTAssertNil(first[Self.host] ?? "missing", "同步失败：\(first)")
        for rel in [Self.claudeU1, Self.codexR2, ".gemini/projects.json", ".kimi-code/session_index.jsonl", Self.dshLog] {
            XCTAssertTrue(exists(cache.appendingPathComponent(rel)), "\(rel) 没同步到缓存")
        }
        XCTAssertTrue(exists(cache.appendingPathComponent(Self.grokS7).appendingPathComponent("updates.jsonl")), "缺席源之后的目录型源被截断")
        XCTAssertTrue(exists(cache.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")), "SQLite 型的文件源没到")
        XCTAssertFalse(exists(cache.appendingPathComponent(".codex/auth.json")), "凭证进了缓存")
        XCTAssertFalse(exists(cache.appendingPathComponent(".copilot")))
        XCTAssertFalse(exists(cache.appendingPathComponent(".openclaw/agents/main/agent/openclaw-agent.sqlite")), "OpenClaw 凭证库进了缓存")

        // ② 真实 roster + 全量扫描：远程会话以三段 key 入库，缺席的 Copilot 之外每家都在
        let index = try CodingSessionIndex(url: indexURL)
        let roster = CodingSessionRoster.configured(home: localHome, environment: [:], overrides: CodingLocationOverrides(),
                                                    remoteHosts: [Self.host], cacheRoot: cacheRoot).active
        _ = try CodingSessionScanner(index: index, adapters: roster).run(full: true)
        let sessions = try index.listSessions(projectPath: nil, includeArchived: true, limit: 1000)
        XCTAssertFalse(sessions.isEmpty, "没有任何远程会话入库")
        for s in sessions {
            XCTAssertEqual(s.host, Self.host, s.key)
            XCTAssertTrue(s.key.hasPrefix("\(s.agent.rawValue):\(Self.host):"), "key 不是三段格式：\(s.key)")
        }
        let agents = Set(sessions.map(\.agent))
        for agent in remoteAgents { XCTAssertTrue(agents.contains(agent), "\(agent) 的远程会话没进库") }

        // ③ 远端删掉一条会话，再同步：缓存跟着删（--delete 在 GNU rsync 发送端照样生效）
        try docker(["exec", container, "rm", "/home/tester/\(Self.claudeU1)"])
        let second = CodingRemote.syncHosts([Self.host], cacheRoot: cacheRoot, environment: environment)
        XCTAssertNil(second[Self.host] ?? "missing", "第二次同步失败：\(second)")
        XCTAssertFalse(exists(cache.appendingPathComponent(Self.claudeU1)), "远端删了，缓存没跟着删")
        XCTAssertTrue(exists(cache.appendingPathComponent(Self.codexR2)), "别家的文件不该被删")
    }
}
#endif
