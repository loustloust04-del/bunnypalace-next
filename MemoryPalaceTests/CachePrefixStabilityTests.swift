import MemoryCore
import XCTest
@testable import 记忆花园

/// 缓存不命中（10-14 起每轮只写不读）回归：同一对话连发两轮，真发出去的 body 里缓存前缀（tools → system → 上一轮断点那条 assistant 为止的消息）逐字节相同。
/// 根因是 JSON 键顺序：Swift 字典每个实例遍历顺序不同，不排序序列化 → 工具 schema / 历史 tool_use 的 input 每轮换顺序 → 前缀从头就变。
@MainActor
final class CachePrefixStabilityTests: XCTestCase {

    private var harness: PromptRealPathHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    /// a2 带一轮工具调用（input 多个键，键顺序漂移会露出来），然后连发两条
    private func twoTurns(_ scenario: PromptScenario, toolsOff: Bool = false, wiki: [WikiPage] = [],
                          toolPath: String = "notes/a.md", toolResult: String = "第一行\n第二行",
                          messages: (first: String, second: String) = ("星砚准备第三条消息", "星砚准备第四条消息")) async throws -> (first: [UInt8], second: [UInt8]) {
        let h = try await PromptRealPathHarness.make(scenario)
        harness = h
        h.overrideDefault(RecallTuningStore.storageKey, try JSONEncoder().encode([h.profile.id: RecallTestTuning.make()]))
        if toolsOff { h.overrideDefault(PermissionDomain.toolsMaster.storageKey, PermissionLevel.notAllowed.rawValue) }
        if !wiki.isEmpty { try await h.seedWiki(wiki) }
        let segs: [MessageSegment] = [
            .toolUse(id: "toolu_prefix_1", name: "fs_read", inputJSON: #"{"path":"\#(toolPath)","offset":1,"limit":20}"#,
                     integrationName: nil, iconName: nil),
            .toolResult(toolUseId: "toolu_prefix_1", text: toolResult, isError: false, integrationName: nil),
        ]
        h.a2.setSegments(segs)
        try h.context.save()
        let first = try await send(h, messages.first, reply: "岚舟回复三")
        let second = try await send(h, messages.second, reply: "岚舟回复四")
        return (Array(first.utf8), Array(second.utf8))
    }

    private func send(_ h: PromptRealPathHarness, _ text: String, reply: String) async throws -> String {
        let convId = try XCTUnwrap(h.viewModel.selectedConversation?.id)
        let before = SentRequestStore.shared.version(convId)
        XCTAssertTrue(h.viewModel.sendMessage(text, model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await h.waitForTurn()
        XCTAssertGreaterThan(SentRequestStore.shared.version(convId), before, "没有真发请求")
        try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" }).content = reply
        try h.context.save()
        let turn = await SentRequestStore.shared.latest(conversationId: convId)
        return try XCTUnwrap(turn?.requests.first?.body)
    }

    /// 第一轮的缓存前缀在第二轮里原样出现：顶层缓存相关键逐字节相同；断点那条 assistant 之前的消息逐字节相同；
    /// 断点那条本身只差 cache_control / 字符串与单文本块两种写法（渲染一样）
    private func assertPrefixStable(_ pair: (first: [UInt8], second: [UInt8]), appendsMemorySystem: Bool = false,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let a = RawJSON.members(pair.first), b = RawJSON.members(pair.second)
        for key in ["tools", "thinking", "model", "tool_choice"] {
            XCTAssertEqual(a[key].map(RawJSON.text), b[key].map(RawJSON.text), "顶层 \(key) 两轮不同", file: file, line: line)
        }
        if appendsMemorySystem {
            let oldSystem = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(a["system"]))) as? [[String: Any]])
            let newSystem = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(b["system"]))) as? [[String: Any]])
            let oldText = oldSystem.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            let newText = newSystem.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            XCTAssertTrue(newText.hasPrefix(oldText), "动态记忆追加为 system，不得改写此前稳定前缀", file: file, line: line)
        } else {
            XCTAssertEqual(a["system"].map(RawJSON.text), b["system"].map(RawJSON.text), file: file, line: line)
        }
        let ma = RawJSON.elements(try XCTUnwrap(a["messages"])), mb = RawJSON.elements(try XCTUnwrap(b["messages"]))
        let k = try XCTUnwrap(ma.lastIndex { RawJSON.members($0)["role"].map(RawJSON.text) == #""assistant""# }, file: file, line: line)
        XCTAssertGreaterThan(mb.count, k)
        for i in 0..<k {
            XCTAssertEqual(RawJSON.text(ma[i]), RawJSON.text(mb[i]), "第 \(i) 条消息两轮不同", file: file, line: line)
        }
        XCTAssertEqual(try Self.normalized(ma[k]), try Self.normalized(mb[k]), "断点那条 assistant 两轮不同", file: file, line: line)
    }

    private static func normalized(_ raw: [UInt8]) throws -> String {
        var msg = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any])
        if let s = msg["content"] as? String { msg["content"] = [["type": "text", "text": s]] }
        if let blocks = msg["content"] as? [[String: Any]] {
            msg["content"] = blocks.map { var b = $0; b.removeValue(forKey: "cache_control"); return b }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: msg, options: .sortedKeys), as: UTF8.self)
    }

    func testAnthropicCacheFriendlyWithTools() async throws {
        try assertPrefixStable(try await twoTurns(PromptScenario(name: "prefix-anthropic", providerType: .anthropic, cacheFriendly: true)))
    }

    func testAnthropicRelayBlacklisted() async throws {
        try assertPrefixStable(try await twoTurns(PromptScenario(name: "prefix-relay", providerType: .anthropic,
                                                                 cacheFriendly: true, anthropicBlacklisted: true)))
    }

    func testAnthropicCacheFriendlyOff() async throws {
        try assertPrefixStable(try await twoTurns(PromptScenario(name: "prefix-anthropic-plain", providerType: .anthropic)))
    }

    func testAnthropicToolsOff() async throws {
        try assertPrefixStable(try await twoTurns(PromptScenario(name: "prefix-anthropic-notools", providerType: .anthropic,
                                                                 cacheFriendly: true), toolsOff: true))
    }

    func testAnthropicThinking() async throws {
        try assertPrefixStable(try await twoTurns(PromptScenario(name: "prefix-opus-thinking", providerType: .anthropic,
                                                                 cacheFriendly: true, modelId: "claude-opus-5-5")))
    }

    func testOpenAICompatible() async throws {
        try assertPrefixStable(try await twoTurns(PromptScenario(name: "prefix-openai", cacheFriendly: true)))
    }

    /// 新命中的记忆追加到 system；此前的稳定前缀逐字节保留，不再承诺变化后的整份 system 可复用缓存。
    func testWikiIndexStableAndHitsVolatile() async throws {
        let pair = try await twoTurns(PromptScenario(name: "prefix-wiki", providerType: .anthropic, cacheFriendly: true), wiki: [
            WikiPage(path: "工程/云桥城", kind: .project, triggers: ["云桥城展览"], hook: "聊云桥城展览的时候", title: "云桥城", now: "在筹备合成展览。"),
            WikiPage(path: "人/林栖", kind: .person, hook: "提到林栖的时候", title: "林栖", now: "展览合作者。"),
        ], messages: ("星砚准备第三条消息", "星砚想聊云桥城展览"))
        try assertPrefixStable(pair, appendsMemorySystem: true)
        let first = RawJSON.text(pair.first), second = RawJSON.text(pair.second)
        XCTAssertTrue(first.contains("[C 档案 · 索引]") && second.contains("[C 档案 · 索引]"))
        XCTAssertFalse(first.contains("[C 档案 · 本轮相关]"), "第一轮没说到触发词")
        XCTAssertTrue(second.contains("[C 档案 · 本轮相关]"), "第二轮有效发言点名云桥城才命中")
    }

    /// 本人页路径投影和历史工具回放不变；新增动态记忆只能追加到稳定 system 之后。
    func testUserBranchWikiAndToolReplayPrefixStable() async throws {
        let pair = try await twoTurns(PromptScenario(name: "prefix-user-branch", providerType: .anthropic, cacheFriendly: true), wiki: [
            WikiPage(path: "{{user}}/云桥展览", kind: .user, triggers: ["云桥城展览"], hook: "聊云桥城展览的时候", title: "云桥展览", now: "在筹备合成星图展览。",
                     links: [.init(target: "{{user}}/星图", relation: .supplement, why: "")]),
            WikiPage(path: "{{user}}/星图", kind: .user, hook: "聊星图的时候", title: "星图", now: "林栖绘制的合成星图。"),
        ], toolPath: "memory/wiki/User/云桥展览.md", toolResult: "# 云桥展览\n- [[User/星图]] · 补充",
           messages: ("星砚准备第三条消息", "星砚想聊云桥城展览"))
        try assertPrefixStable(pair, appendsMemorySystem: true)
        let first = RawJSON.text(pair.first).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertFalse(first.contains("[C 档案 · 本轮相关]"), "历史工具回放不能替代当前真实用户的触发证据")
        let second = RawJSON.text(pair.second).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(first.contains("[[User/云桥展览]]") && second.contains("[[User/云桥展览]]"), "索引里本人那组是名字")
        XCTAssertTrue(second.contains("[C 档案 · 本轮相关]"))
        XCTAssertFalse(first.contains("[[{{user}}") || second.contains("[[{{user}}"), "发出去的 wiki 路径没有宏")
        XCTAssertTrue(first.contains("memory/wiki/User/云桥展览.md"), "工具回放原样")
    }

    func testPinnedExpiryAcrossFiveKeepsStableUTF8AndChangesOnlyReminder() throws {
        let keys = ["mem_inject_keyword", "mem_inject_full", "mem_inject_vector", "mem_inject_graph", "mem_inject_catalog"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for key in keys { UserDefaults.standard.set(key == "mem_inject_full", forKey: key) }
        let profile = Profile(id: "xctest-prefix-expiry", name: "T", emoji: "", description: "", userName: "阿青", assistantName: "阿白")
        let content = String(repeating: "钉住的复诊安排", count: 8)
        let pinned = Memory(content: content, category: "fact", profileId: profile.id, isUserExplicit: true)
        pinned.validUntil = try XCTUnwrap(FragmentPool.validUntilDate("2026-10-22"))
        let beforeFive = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 4, minute: 59)))
        let afterFive = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 5)))
        let wiki = WikiInjectionSnapshot(indexLines: ["- [[主题/身体]] 身体 — 提到复诊时"])
        let before = PromptAssembler.memoryLayers(profile: profile, selfMemory: nil, memories: [pinned], recentMessages: [],
                                                  budget: 10_000, wiki: wiki, now: beforeFive)
        let after = PromptAssembler.memoryLayers(profile: profile, selfMemory: nil, memories: [pinned], recentMessages: [],
                                                 budget: 10_000, wiki: wiki, now: afterFive)
        XCTAssertEqual(Array(before.stable.utf8), Array(after.stable.utf8), "过 05:00 不准改根索引或钉住正文的缓存前缀")
        XCTAssertTrue(after.stable.contains(content))
        XCTAssertFalse(after.stable.contains("已过期"))
        XCTAssertTrue(before.volatile.isEmpty)
        XCTAssertTrue(after.volatile.contains("[已过期的钉住项]\n- \(String(content.prefix(40)))（已过期）"))
        XCTAssertFalse(after.volatile.contains(content), "动态提醒只带正文前 40 字，不重复全文")
        XCTAssertEqual(after.hits.map(\.memoryId), [pinned.id])
    }
}

/// 只认结构不解码的 JSON 切片（紧凑 JSON）：取顶层对象各键 / 数组各元素的原文字节，用来逐字节比
enum RawJSON {
    static func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    static func members(_ b: [UInt8]) -> [String: [UInt8]] {
        guard b.first == UInt8(ascii: "{") else { return [:] }
        var out: [String: [UInt8]] = [:]
        var i = 1
        while i < b.count, b[i] != UInt8(ascii: "}") {
            let keyEnd = end(b, from: i)
            let key = text(Array(b[(i + 1)..<(keyEnd - 1)]))
            let start = keyEnd + 1   // 跳过冒号
            let stop = end(b, from: start)
            out[key] = Array(b[start..<stop])
            i = stop
            if i < b.count, b[i] == UInt8(ascii: ",") { i += 1 }
        }
        return out
    }

    static func elements(_ b: [UInt8]) -> [[UInt8]] {
        guard b.first == UInt8(ascii: "[") else { return [] }
        var out: [[UInt8]] = []
        var i = 1
        while i < b.count, b[i] != UInt8(ascii: "]") {
            let stop = end(b, from: i)
            out.append(Array(b[i..<stop]))
            i = stop
            if i < b.count, b[i] == UInt8(ascii: ",") { i += 1 }
        }
        return out
    }

    /// 从 start 起的一个值的结束位置（不含）
    private static func end(_ b: [UInt8], from start: Int) -> Int {
        var i = start
        switch b[i] {
        case UInt8(ascii: "\""):
            i += 1
            while b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
            return i + 1
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while true {
                switch b[i] {
                case UInt8(ascii: "\""):
                    i = end(b, from: i)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
        default:
            while ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(b[i]) { i += 1 }
            return i
        }
    }
}
