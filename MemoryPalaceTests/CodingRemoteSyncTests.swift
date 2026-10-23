#if os(macOS)
import XCTest
@testable import 记忆花园

/// N4 远程同步端到端（照抄 Wake `tests/remote_sync.rs`：假 ssh + 真 rsync + 真实 roster / 扫描器）。卡 Wake 2026-09-02 实测出的两个 bug——
/// 缺父目录的源让 openrsync 发送端截断文件列表、任何缺源都让 rsync 跳过 --delete——断言「远端缺一大半 agent 时，存在的照样全到、删除照样传播」，
/// 再接 roster + 扫描确认远程会话以 `{agent}:{host}:{native}` 入库、移除主机后按「磁盘已删」出清。
/// 假 ssh 把远端命令交给 sh 在假 home 里跑（与真 ssh 把命令串交给远端登录 shell 同形）；rsync 用系统真身（本机 openrsync 两端）。
/// 环境（PATH 前置假 ssh）只经注入的 environment 传给子进程，不改测试进程的环境
final class CodingRemoteSyncTests: XCTestCase {
    private var dir: URL!
    private var remoteHome: URL { dir.appendingPathComponent("remote-home") }
    private var localHome: URL { dir.appendingPathComponent("local-home") }
    private var bin: URL { dir.appendingPathComponent("bin") }
    private var indexURL: URL { dir.appendingPathComponent("index.sqlite") }
    private var cacheRoot: URL { CodingRemote.cacheRoot(indexURL: indexURL) }
    private var devboxCache: URL { CodingRemote.hostCacheDir(cacheRoot, host: "devbox") }
    private var environment: [String: String] { ["PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"] }

    private static let claudeU1 = ".claude/projects/-Users-tester-Github-wakefx/11111111-aaaa-bbbb-cccc-000000000001.jsonl"
    private static let codexR2 = ".codex/sessions/2026/08/02/rollout-2026-08-02T09-15-00-22222222-aaaa-bbbb-cccc-000000000002.jsonl"
    private static let grokS7 = ".grok/sessions/%2FUsers%2Ftester%2FGithub%2Fwakefx/77777777-aaaa-bbbb-cccc-000000000007"
    private static let dshLog = ".dsh/sessions/--Users-tester-Github-wakefx--/dsh-e2e4-0001/session.jsonl.zstd"

    /// 假远端上装着的 agent（Copilot 故意缺席：`.copilot` 是白名单里唯一「连父目录都不存在」的形状，且排在 cursor…dsh 之前——正是截断 bug 的触发条件）
    private var remoteAgents: [CodingAgent] { CodingAgent.allCases.filter { $0 != .copilot } }

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync") else { throw XCTSkip("rsync not installed") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-remote-sync-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: localHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try CodingFakeHome.stage(remoteHome)
        try fm.removeItem(at: remoteHome.appendingPathComponent(".copilot"))
        // 凭证在白名单外，必须留在远端
        try Data("NOT-A-REAL-SECRET".utf8).write(to: remoteHome.appendingPathComponent(".codex/auth.json"))
        // 假 ssh：吞掉 -o 选项与 host；host = down 模拟连不上（ssh 的 255）；其余把拼接后的远端命令交给 sh 在假 home 里执行——探测脚本与
        // rsync --server 都走这条。MP_TEST_VANISH 指向一个文件时，第一次 rsync --server 起跑前把它删掉（只删一次，.done 标记），
        // 模拟「探测到 rsync 之间远端 agent 退出删了 -wal」
        let ssh = bin.appendingPathComponent("ssh")
        try """
            #!/bin/sh
            while [ $# -gt 0 ]; do case "$1" in -*) shift;; *) break;; esac; done
            host=$1; shift
            if [ "$host" = down ]; then echo 'ssh: connect to host down port 22: Connection refused' >&2; exit 255; fi
            if [ -n "$MP_TEST_VANISH" ] && [ ! -e "$MP_TEST_VANISH.done" ]; then case "$*" in *'rsync --server'*) rm -f "$MP_TEST_VANISH"; : > "$MP_TEST_VANISH.done";; esac; fi
            export HOME='\(remoteHome.path)'
            cd "$HOME" || exit 99
            exec sh -c "$*"

            """.write(to: ssh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func sync(_ hosts: [String], extra: [String: String] = [:]) -> [String: String?] {
        CodingRemote.syncHosts(hosts, cacheRoot: cacheRoot, environment: environment.merging(extra) { _, new in new })
    }

    private func roster(_ hosts: [String]) -> [CodingSessionAdapter] {
        CodingSessionRoster.configured(home: localHome, environment: [:], overrides: CodingLocationOverrides(),
                                       remoteHosts: hosts, cacheRoot: cacheRoot).active
    }

    private func count(_ index: CodingSessionIndex, _ agent: CodingAgent) throws -> Int {
        try index.countSessions(filter: CodingListFilter(agents: [agent]), includeArchived: true)
    }

    func testRemotePipelineEndToEnd() throws {
        // ① 首次同步：.copilot（缺父目录）之后的 cursor…dsh 必须到位，exclude 与凭证不进缓存。同时让 opencode-next.db 在探测之后、
        // rsync 之前消失：rsync 报只含 ENOENT 的 23，必须重探一轮并成功，而不是记成同步失败
        let vanish = remoteHome.appendingPathComponent(".local/share/opencode/opencode-next.db")
        let first = sync(["devbox"], extra: ["MP_TEST_VANISH": vanish.path])
        XCTAssertTrue(exists(URL(fileURLWithPath: vanish.path + ".done")), "假 ssh 没触发消失钩子")
        XCTAssertEqual(first.count, 1)
        XCTAssertNil(first["devbox"] ?? "missing", "探测后消失的源应重探一轮，不是报错")
        XCTAssertFalse(exists(devboxCache.appendingPathComponent(".local/share/opencode/opencode-next.db")), "消失的源不该进缓存")
        XCTAssertTrue(exists(devboxCache.appendingPathComponent(".local/share/opencode/opencode.db")))
        for rel in [Self.claudeU1, Self.codexR2, ".gemini/projects.json", ".kimi-code/session_index.jsonl", Self.dshLog] {
            XCTAssertTrue(exists(devboxCache.appendingPathComponent(rel)), "\(rel) 没同步到缓存")
        }
        XCTAssertTrue(exists(devboxCache.appendingPathComponent(Self.grokS7).appendingPathComponent("updates.jsonl")), "缺席源之后的目录型源被截断")
        XCTAssertFalse(exists(devboxCache.appendingPathComponent(".codex/auth.json")), "凭证进了缓存")
        XCTAssertFalse(exists(devboxCache.appendingPathComponent(".copilot")))
        XCTAssertTrue(exists(devboxCache.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")), "SQLite 型的文件源没到")
        XCTAssertFalse(exists(devboxCache.appendingPathComponent(".openclaw/agents/main/agent/openclaw-agent.sqlite")), "OpenClaw 凭证库进了缓存")

        // ② 真实 roster + 全量扫描：远程会话以三段 key 入库，host / native id / 文件路径都对
        let index = try CodingSessionIndex(url: indexURL)
        let scanner = CodingSessionScanner(index: index, adapters: roster(["devbox"]))
        _ = try scanner.run(full: true)
        let total = try index.countSessions(filter: CodingListFilter(), includeArchived: true)
        XCTAssertGreaterThan(total, 0, "没有任何远程会话入库")
        let sessions = try index.listSessions(projectPath: nil, includeArchived: true, limit: 1000)
        let cachePrefix = CodingParse.canonicalPath(devboxCache.path)
        for s in sessions {
            XCTAssertEqual(s.host, "devbox", s.key)
            XCTAssertTrue(s.key.hasPrefix("\(s.agent.rawValue):devbox:"), "key 不是三段格式：\(s.key)")
            XCTAssertFalse(s.nativeId.contains(":"), "native id 混进了 host 段：\(s.nativeId)")
            XCTAssertTrue(CodingParse.canonicalPath(CodingVirtualPath.strip(s.filePath)).hasPrefix(cachePrefix), "文件路径不在缓存内：\(s.filePath)")
        }
        let agents = Set(sessions.map(\.agent))
        for agent in remoteAgents { XCTAssertTrue(agents.contains(agent), "\(agent) 的远程会话没进库") }
        XCTAssertEqual(try index.hostCounts()["devbox"], total, "远程主机页计数与列表不一致")
        let claudeBefore = try count(index, .claudeCode)

        // ③ 远端变化：删一个 grok 会话目录、整个卸掉 Codex、新增一个 claude 文件；再同步 + 增量扫描，三种变化都要传播到缓存与库
        let fm = FileManager.default
        try fm.removeItem(at: remoteHome.appendingPathComponent(Self.grokS7))
        try fm.removeItem(at: remoteHome.appendingPathComponent(".codex"))
        let added = ".claude/projects/-Users-tester-Github-wakefx/eeeeeeee-aaaa-bbbb-cccc-00000000000e.jsonl"
        try fm.copyItem(at: remoteHome.appendingPathComponent(Self.claudeU1), to: remoteHome.appendingPathComponent(added))
        XCTAssertNil(sync(["devbox"])["devbox"] ?? "missing")
        XCTAssertFalse(exists(devboxCache.appendingPathComponent(Self.grokS7)), "源树内的删除未传播（--delete 被缺源压掉）")
        XCTAssertFalse(exists(devboxCache.appendingPathComponent(".codex/sessions")), "整棵源消失未传播到缓存")
        XCTAssertTrue(exists(devboxCache.appendingPathComponent(added)), "新增文件没同步到缓存")
        XCTAssertTrue(exists(devboxCache.appendingPathComponent(Self.claudeU1)), "无关的树被误删")
        _ = try scanner.run()
        XCTAssertEqual(try count(index, .grok), 0, "远端删掉的 grok 会话还挂在库里")
        XCTAssertEqual(try count(index, .codex), 0, "远端卸掉的 codex 会话还挂在库里")
        XCTAssertGreaterThanOrEqual(try count(index, .claudeCode), claudeBefore)

        // ④ 连不上的主机：错误照实回、缓存一字不动（不能把「连不上」当「远端空了」）
        let downCache = CodingRemote.hostCacheDir(cacheRoot, host: "down")
        let keep = downCache.appendingPathComponent(".claude/projects/p/keep.jsonl")
        try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: keep)
        let error = try XCTUnwrap(sync(["down"])["down"] ?? nil, "连不上的主机必须回错误")
        XCTAssertTrue(error.contains("Connection refused"), error)
        XCTAssertTrue(exists(keep), "探测失败不得清缓存")

        // ⑤ 移除主机的数据面：配置删掉 → roster 不再含该主机 → 扫描把行按「磁盘已删」出清 → 孤儿缓存清理只删它、不碰仍配置着的 down
        let removed = roster([])
        XCTAssertFalse(removed.contains { $0.host == "devbox" }, "移除后的主机仍在 roster 里")
        _ = try CodingSessionScanner(index: index, adapters: removed).run()
        XCTAssertNil(try index.hostCounts()["devbox"], "移除主机后它的会话还在库里")
        CodingRemote.purgeOrphanCaches(cacheRoot, known: ["down"])
        XCTAssertFalse(exists(devboxCache), "移除主机的缓存目录没清")
        XCTAssertTrue(exists(downCache), "仍配置着的主机缓存被误清")
    }

    /// 本机与远端同一 native id（她把会话目录同步过的常见情形）：分组 key 带实例 host，两份各自成行、互不覆盖
    func testLocalAndRemoteCopiesOfSameSessionStaySeparate() throws {
        try FileManager.default.createDirectory(at: localHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures.appendingPathComponent("claude/projects"),
                                         to: localHome.appendingPathComponent(".claude/projects"))
        XCTAssertNil(sync(["devbox"])["devbox"] ?? "missing")
        let index = try CodingSessionIndex(url: indexURL)
        _ = try CodingSessionScanner(index: index, adapters: roster(["devbox"])).run(full: true)
        let native = "11111111-aaaa-bbbb-cccc-000000000001"
        let local = try XCTUnwrap(index.session(key: "claude-code:\(native)"), "本机那份没入库")
        let remote = try XCTUnwrap(index.session(key: "claude-code:devbox:\(native)"), "远端那份没入库")
        XCTAssertEqual(local.host, "")
        XCTAssertEqual(remote.host, "devbox")
        XCTAssertNotEqual(local.filePath, remote.filePath)
        XCTAssertTrue(CodingParse.canonicalPath(local.filePath).hasPrefix(CodingParse.canonicalPath(localHome.path)))
    }

    /// 等 Library 的同步与扫描链（收工补扫 / pendingRescan）全部落定
    @MainActor
    private func settle(_ library: CodingSessionLibrary) async {
        for _ in 0..<600 {
            if let task = library.remoteSyncTask {
                await task.value
                continue
            }
            if library.isScanning {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            break
        }
        await library.refresh()?.value
    }

    /// Library 层（Wake workbench 远程流程）：添加（非法名拒写）→ 只同步这台 → 行带 host → 远程禁删 → 停用出清、缓存保留 → 重开收编 →
    /// 移除出清 + 缓存删除；连不上的主机记错误、不写成功时间
    @MainActor
    func testLibraryAddSyncDisableEnableRemove() async throws {
        let state = CodingSessionState(url: dir.appendingPathComponent("state.json"))
        let library = CodingSessionLibrary(indexURL: indexURL, state: state, home: localHome, environment: environment)
        XCTAssertNotNil(library.addRemoteHost("-oProxyCommand=evil"), "非法名拒写")
        XCTAssertTrue(state.remoteHosts.isEmpty)
        XCTAssertNil(library.addRemoteHost(" devbox "))
        await settle(library)

        let index = try CodingSessionIndex(url: indexURL)
        let row = try XCTUnwrap(library.remoteHostRows().first)
        XCTAssertEqual(row.name, "devbox")
        XCTAssertNil(row.lastSyncError)
        XCTAssertNotNil(row.lastSyncAt)
        let total = try XCTUnwrap(index.hostCounts()["devbox"])
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(row.count, total)

        let meta = try XCTUnwrap(index.listSessions(projectPath: nil, includeArchived: true, limit: 1).first)
        XCTAssertEqual(meta.host, "devbox")
        var deleteError: String?
        library.delete(meta) { deleteError = $0 }
        XCTAssertEqual(deleteError, CodingSessionLibrary.remoteReadOnly, "远程会话只读")
        XCTAssertNotNil(CodingSessionResume.sshCommand(for: meta).map { $0.hasPrefix("ssh -t devbox ") })

        await library.setRemoteHostEnabled("devbox", enabled: false)?.value
        await settle(library)
        XCTAssertNil(try index.hostCounts()["devbox"], "停用 = 出清")
        XCTAssertTrue(exists(devboxCache), "停用保留缓存")

        await library.setRemoteHostEnabled("devbox", enabled: true)?.value
        await settle(library)
        XCTAssertEqual(try index.hostCounts()["devbox"], total, "重开 = 收编缓存")

        await library.removeRemoteHost("devbox")?.value
        await settle(library)
        XCTAssertNil(try index.hostCounts()["devbox"], "移除 = 出清")
        for _ in 0..<100 where exists(devboxCache) { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(exists(devboxCache), "移除 = 缓存删除")
        XCTAssertTrue(state.remoteHosts.isEmpty)

        XCTAssertNil(library.addRemoteHost("down"))
        await settle(library)
        let down = try XCTUnwrap(library.remoteHostRows().first { $0.name == "down" })
        XCTAssertTrue(down.lastSyncError?.contains("Connection refused") == true, down.lastSyncError ?? "nil")
        XCTAssertNil(down.lastSyncAt, "失败不写成功时间")
    }

    /// 装饰器契约：逐成员转发（没写的成员会落到协议扩展默认实现 = 静默绕过 inner 覆写）+ 每个 meta 出口都改写
    func testRemoteAdapterForwardsEveryMemberAndRewritesEveryExit() throws {
        // 空缓存目录上构造：数据根都落在各家 mount 之下（同步是异步的，实例构造时缓存可能还没落盘）
        let templates = CodingSessionRoster.adapters(home: localHome, environment: [:])
        let empty = CodingRemote.adapters(templates: templates, host: "devbox", cacheRoot: cacheRoot)
        XCTAssertEqual(empty.map(\.agent), CodingRemote.layouts.map(\.agent))
        for (adapter, layout) in zip(empty, CodingRemote.layouts) {
            XCTAssertEqual(adapter.host, "devbox")
            let mount = devboxCache.appendingPathComponent(layout.mount).path
            XCTAssertFalse(adapter.dataRoots.isEmpty, "\(layout.agent)：没有数据根")
            for root in adapter.dataRoots {
                XCTAssertTrue(CodingLocations.pathOwns(mount, root.path), "\(layout.agent)：数据根 \(root.path) 不在 \(mount) 之下")
            }
            XCTAssertEqual(adapter.withCustomRoot(dir.appendingPathComponent("x")).host, "devbox", "withCustomRoot 丢了装饰")
        }

        XCTAssertNil(sync(["devbox"])["devbox"] ?? "missing")
        let remote = CodingRemote.adapters(templates: templates, host: "devbox", cacheRoot: cacheRoot)
        var parsedAgents = Set<CodingAgent>()
        for adapter in remote {
            let refs = adapter.listSessionFiles()
            for ref in refs {
                let inner = try XCTUnwrap((adapter as? CodingRemoteAdapter)?.inner)
                let url = URL(fileURLWithPath: ref.filePath)
                XCTAssertEqual(adapter.fileRef(url), inner.fileRef(url), "\(ref.filePath) fileRef 没转发")
                let session = try adapter.parseSession(ref)
                let transcript = try adapter.parseTranscript(ref)
                for meta in [session.meta, transcript.meta] {
                    XCTAssertEqual(meta.host, "devbox")
                    XCTAssertEqual(meta.key, CodingSessionKey.make(adapter.agent, host: "devbox", nativeId: meta.nativeId))
                    if !meta.parentKey.isEmpty { XCTAssertTrue(meta.parentKey.contains(":devbox:"), meta.parentKey) }
                }
                parsedAgents.insert(adapter.agent)
            }
            if let quick = adapter.quickMeta(refs) {
                for meta in quick.values { XCTAssertTrue(meta.key.hasPrefix("\(adapter.agent.rawValue):devbox:"), meta.key) }
            }
            adapter.beginScan()
            for link in adapter.parentLinks() {
                XCTAssertTrue(link.child.hasPrefix("\(adapter.agent.rawValue):devbox:"), link.child)
                XCTAssertTrue(link.parent.hasPrefix("\(adapter.agent.rawValue):devbox:"), link.parent)
            }
        }
        // Grok / Hermes 的父链经装饰器仍在
        for agent in [CodingAgent.grok, .hermes] {
            let adapter = try XCTUnwrap(remote.first { $0.agent == agent })
            adapter.beginScan()
            XCTAssertTrue(adapter.managesParentLinks)
            XCTAssertFalse(adapter.parentLinks().isEmpty, "\(agent) parentLinks 被默认实现顶掉")
        }
        for agent in remoteAgents { XCTAssertTrue(parsedAgents.contains(agent), "\(agent) 经装饰器没解析出会话") }
    }

    /// 逐成员转发：探针 adapter 把协议 18 个成员全部覆写成可辨认的值，装饰器必须原样交出（meta 出口改写 key / host / parentKey）——
    /// 装饰器漏写哪个成员，就会落到协议扩展的默认实现，这里对应那条断言就红
    func testRemoteAdapterForwardsEverySpyMember() throws {
        let box = SpyBox()
        let root = dir.appendingPathComponent("spy")
        let remote = CodingRemoteAdapter(inner: SpyAdapter(root: root, box: box), host: "devbox")
        let ref = CodingSessionFileRef(agent: .grok, nativeId: "n-list", filePath: root.appendingPathComponent("s.jsonl").path, mtimeMs: 1, size: 1)
        XCTAssertEqual(remote.agent, .grok)
        XCTAssertEqual(remote.host, "devbox")
        XCTAssertEqual(remote.dataRoots, [root])
        XCTAssertEqual(remote.listSessionFiles(), [ref])
        XCTAssertEqual(remote.fileRef(URL(fileURLWithPath: "/x"))?.nativeId, "spy-file")
        let quick = try XCTUnwrap(remote.quickMeta([ref])?[ref.filePath])
        XCTAssertEqual(quick.key, "grok:devbox:n-quick")
        XCTAssertEqual(quick.host, "devbox")
        XCTAssertEqual(remote.mergeQuickMeta(quick, quick).title, "merged", "mergeQuickMeta 没转发")
        let session = try remote.parseSession(ref).meta
        XCTAssertEqual(session.key, "grok:devbox:n-session")
        XCTAssertEqual(session.host, "devbox")
        XCTAssertEqual(session.parentKey, "grok:devbox:parent", "meta 里的父 key 也要改写")
        XCTAssertEqual(try remote.parseTranscript(ref).meta.key, "grok:devbox:n-transcript")
        XCTAssertThrowsError(try remote.loadSidechain(ref, id: "x"), "loadSidechain 没转发")
        XCTAssertEqual(remote.sessionPaths(session), ["spy-a", "spy-b"])
        remote.beginScan()
        XCTAssertEqual(box.beginScans, 1, "beginScan 没转发")
        XCTAssertTrue(remote.managesParentLinks)
        XCTAssertEqual(remote.parentLinks().map { "\($0.child)>\($0.parent)" }, ["grok:devbox:c>grok:devbox:p"])
        XCTAssertTrue(remote.isParentLinkEvent("spy-event"))
        XCTAssertTrue(remote.supportsIndividualRootRemoval)
        let custom = remote.withCustomRoot(dir.appendingPathComponent("custom"))
        XCTAssertEqual(custom.host, "devbox")
        XCTAssertEqual(custom.dataRoots, [dir.appendingPathComponent("custom")])
        let excluded = try XCTUnwrap(remote.excludingDataRoots([root]))
        XCTAssertEqual(excluded.host, "devbox")
        XCTAssertEqual(excluded.dataRoots, [root.appendingPathComponent("excluded")])
    }
}

private final class SpyBox: @unchecked Sendable {
    var beginScans = 0
}

private struct SpyError: Error {}

/// 协议 18 个成员全部覆写成可辨认的值（默认实现给不出这些值）
private struct SpyAdapter: CodingSessionAdapter {
    let root: URL
    let box: SpyBox

    var agent: CodingAgent { .grok }
    var dataRoots: [URL] { [root] }

    private func meta(_ id: String) -> CodingSessionMeta {
        CodingSessionMeta(key: "grok:\(id)", nativeId: id, agent: .grok, title: id, projectPath: "", projectName: "", filePath: "",
                          createdAt: 0, updatedAt: 0, messageCount: 0, sizeBytes: 0, gitBranch: nil, model: nil, tokensUsed: nil,
                          archived: false, source: nil, parentKey: "grok:parent")
    }

    func listSessionFiles() -> [CodingSessionFileRef] {
        [CodingSessionFileRef(agent: .grok, nativeId: "n-list", filePath: root.appendingPathComponent("s.jsonl").path, mtimeMs: 1, size: 1)]
    }

    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        CodingSessionFileRef(agent: .grok, nativeId: "spy-file", filePath: url.path, mtimeMs: 7, size: 7)
    }

    func quickMeta(_ refs: [CodingSessionFileRef]) -> [String: CodingSessionMeta]? {
        Dictionary(uniqueKeysWithValues: refs.map { ($0.filePath, meta("n-quick")) })
    }

    func mergeQuickMeta(_ parsed: CodingSessionMeta, _ quick: CodingSessionMeta) -> CodingSessionMeta {
        var merged = parsed
        merged.title = "merged"
        return merged
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        CodingParsedSession(meta: meta("n-session"), units: [], unknownLines: 0)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        CodingParsedTranscript(meta: meta("n-transcript"), mainline: [], sidechains: [], unknownLines: 0)
    }

    func loadSidechain(_ ref: CodingSessionFileRef, id: String) throws -> [CodingMessage] { throw SpyError() }

    func sessionPaths(_ meta: CodingSessionMeta) -> [String] { ["spy-a", "spy-b"] }

    func beginScan() { box.beginScans += 1 }

    var managesParentLinks: Bool { true }

    func parentLinks() -> [(child: String, parent: String)] { [(child: "grok:c", parent: "grok:p")] }

    func isParentLinkEvent(_ path: String) -> Bool { path == "spy-event" }

    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter { SpyAdapter(root: dir, box: box) }

    var supportsIndividualRootRemoval: Bool { true }

    func excludingDataRoots(_ roots: [URL]) -> CodingSessionAdapter? {
        SpyAdapter(root: root.appendingPathComponent("excluded"), box: box)
    }
}
#endif
