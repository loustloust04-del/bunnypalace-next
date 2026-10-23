#if os(macOS)
import XCTest
@testable import 记忆花园

/// 整套假 home（Wake `tests/common` 的 `stage_dir_fixtures` + `stage_sidecars`）：目录夹具按各家 home 下的尾段摆好（pi 的树同时复制成 omp），
/// SQLite 型现建库（建库 SQL 复用各契约类），侧档现写。远程同步 e2e 把它当「远端机器的 home」
enum CodingFakeHome {
    static let project = "/Users/tester/Github/wakefx"

    static func stage(_ home: URL) throws {
        let fm = FileManager.default
        let fixtures = CodingSessionAdapterTests.fixtures
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        for (src, dst) in [("claude", ".claude"), ("codex", ".codex"), ("cursor", ".cursor"), ("gemini", ".gemini"), ("grok", ".grok"),
                           ("kimi", ".kimi-code"), ("kiro", ".kiro"), ("pi", ".pi"), ("pi", ".omp"), ("qoder", ".qoder")] {
            try fm.copyItem(at: fixtures.appendingPathComponent(src), to: home.appendingPathComponent(dst))
        }

        let copilot = home.appendingPathComponent(".copilot")
        try fm.createDirectory(at: copilot, withIntermediateDirectories: true)
        CodingContract.execSQL(copilot.appendingPathComponent("session-store.db"), CopilotAdapterContractTests.fixtureSQL)

        let opencode = home.appendingPathComponent(".local/share/opencode")
        try fm.createDirectory(at: opencode, withIntermediateDirectories: true)
        CodingContract.execSQL(opencode.appendingPathComponent("opencode.db"), OpenCodeAdapterContractTests.stableSQL)
        CodingContract.execSQL(opencode.appendingPathComponent("opencode-next.db"), OpenCodeAdapterContractTests.nextSQL)

        try Data(#"{"projects":{"/Users/tester/Github/wakefx":"wakefx-gem"}}"#.utf8)
            .write(to: home.appendingPathComponent(".gemini/projects.json"))
        let antigravity = home.appendingPathComponent(".gemini/antigravity-cli")
        try fm.createDirectory(at: antigravity, withIntermediateDirectories: true)
        CodingContract.execSQL(antigravity.appendingPathComponent("conversation_summaries.db"), AntigravityAdapterContractTests.fixtureSQL)

        try (#"{"sessionId":"session_88888888-aaaa-bbbb-cccc-000000000008","sessionDir":"/x","workDir":"/Users/tester/Github/wakefx"}"# + "\n"
             + #"{"sessionId":"session_99999999-aaaa-bbbb-cccc-000000000009","sessionDir":"/x","workDir":"/Users/tester/Github/wakefx"}"# + "\n")
            .write(to: home.appendingPathComponent(".kimi-code/session_index.jsonl"), atomically: true, encoding: .utf8)

        // dsh：检入的两帧 zstd 日志 + 一个子代理会话（fileRef 过滤）
        let dshProject = home.appendingPathComponent(".dsh/sessions/--Users-tester-Github-wakefx--")
        try fm.createDirectory(at: dshProject.appendingPathComponent("dsh-e2e4-0001"), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("dsh/session.jsonl.zstd"),
                        to: dshProject.appendingPathComponent("dsh-e2e4-0001/session.jsonl.zstd"))
        try fm.createDirectory(at: dshProject.appendingPathComponent("dsh-sub-0002"), withIntermediateDirectories: true)
        try (#"{"type":"session","version":0,"id":"dsh-sub-0002","createdAt":1786100000000,"cwd":"/Users/tester/Github/wakefx","origin":"subagent","delegationDepth":1}"# + "\n"
             + #"{"type":"user/message","seq":0,"time":1786100001000,"data":{"id":"m","role":"user","content":[{"type":"text","text":"child task"}],"source":{"kind":"user"}}}"# + "\n")
            .write(to: dshProject.appendingPathComponent("dsh-sub-0002/session.jsonl"), atomically: true, encoding: .utf8)

        let hermes = home.appendingPathComponent(".hermes")
        try fm.createDirectory(at: hermes, withIntermediateDirectories: true)
        CodingContract.execSQL(hermes.appendingPathComponent("state.db"), HermesAdapterContractTests.fixtureSQL)

        // openclaw：现版库与旧版 jsonl 同在一个 agent 目录（真机形态）
        let claw = home.appendingPathComponent(".openclaw/agents/main")
        try fm.createDirectory(at: claw.appendingPathComponent("agent"), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("openclaw/agents/main/sessions"), to: claw.appendingPathComponent("sessions"))
        CodingContract.execSQL(claw.appendingPathComponent("agent/openclaw-agent.sqlite"), OpenClawAdapterContractTests.fixtureSQL)
    }
}
#endif
