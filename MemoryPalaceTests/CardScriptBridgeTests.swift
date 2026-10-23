import XCTest
import JavaScriptCore
@testable import 记忆花园

/// 卡库第二批 B3 / B4：窄通道校验链、限频、楼层 / swipe 映射、范围解析、变量惰性初始化与上限、
/// 写消息「本楼及之后」闸、快照截窗口、事件差分、存储新列兼容与备份往返
@MainActor
final class CardScriptBridgeTests: XCTestCase {

    private let identity = HTMLEmbedIdentity(profileId: "p", conversationId: "c", nodeId: "n2", segmentId: "h0")

    private func json(_ o: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func object(_ d: Data?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d ?? Data())) as? [String: Any] ?? [:]
    }

    // MARK: - 校验链

    private func gateInput(method: String = "replaceVariables",
                           args: String = #"{"variables":{"a":1},"option":{"type":"chat"}}"#) -> CardScriptGate.Input {
        CardScriptGate.Input(registered: (identity, true), claimedNodeId: "n2", claimedSegmentId: "h0",
                             activeToken: "tok", token: "tok", currentProfileId: "p", currentConversationId: "c",
                             runDenial: nil, method: method, args: args)
    }

    private func reject(_ input: CardScriptGate.Input, _ limiter: inout CardScriptRateLimiter) -> CardScriptRejection? {
        if case .failure(let e) = CardScriptGate.check(input, limiter: &limiter, now: 0) { return e }
        return nil
    }

    func testGateRejectsEachStepInOrder() {
        var limiter = CardScriptRateLimiter()
        XCTAssertNil(reject(gateInput(), &limiter), "全对：放行")

        var i = gateInput(); i.registered = nil
        XCTAssertEqual(reject(i, &limiter), .unregisteredToken)
        i = gateInput(); i.registered = (identity, false)
        XCTAssertEqual(reject(i, &limiter), .notInteractive, "静态实例不能 call")
        for mutate in [{ (x: inout CardScriptGate.Input) in x.claimedNodeId = "n1" },
                       { $0.claimedSegmentId = "h1" },
                       { $0.currentProfileId = "q" },
                       { $0.currentConversationId = "other" },
                       { $0.activeToken = "another" }] {
            var x = gateInput(); mutate(&x)
            XCTAssertEqual(reject(x, &limiter), .identityMismatch)
        }
        i = gateInput(); i.runDenial = "网页脚本没开"
        XCTAssertEqual(reject(i, &limiter), .notPermitted("网页脚本没开"))
        XCTAssertEqual(reject(gateInput(method: "generate"), &limiter), .methodNotAllowed("generate"))
        // B5 起 triggerSlash 进原生白名单（triggerSlashWithResult 在子页里走同一个，原生不认这个名字）
        XCTAssertEqual(reject(gateInput(method: "triggerSlashWithResult"), &limiter), .methodNotAllowed("triggerSlashWithResult"))
        let huge = #"{"variables":{"a":""# + String(repeating: "x", count: CardScriptLimits.argsBytes) + #""}}"#
        XCTAssertEqual(reject(gateInput(args: huge), &limiter), .tooLarge("参数"))
        XCTAssertEqual(reject(gateInput(args: "[1]"), &limiter), .badArguments("不是 JSON 对象"))
        XCTAssertEqual(reject(gateInput(args: #"{"variables":[1]}"#), &limiter), .badArguments("variables 必须是对象"))
        XCTAssertEqual(reject(gateInput(args: #"{"variables":{},"option":{"type":"global"}}"#), &limiter), .unsupported("global 作用域的变量"))
        XCTAssertEqual(reject(gateInput(method: "setChatMessages", args: #"{"messages":[{"message_id":0,"swipes":["a"]}]}"#), &limiter),
                       .unsupported("setChatMessages 的 swipes"))
        XCTAssertEqual(reject(gateInput(method: "setChatMessages", args: #"{"messages":[{"message_id":1.5}]}"#), &limiter),
                       .badArguments("每条都要有整数 message_id"))
        XCTAssertEqual(reject(gateInput(method: "setChatMessages", args: #"{"messages":[],"option":{"refresh":"x"}}"#), &limiter),
                       .badArguments("refresh 只能是 none / affected / all"))
        XCTAssertTrue(CardScriptRejection.unregisteredToken.isSilent && CardScriptRejection.identityMismatch.isSilent)
        XCTAssertFalse(CardScriptRejection.rateLimited.isSilent)
    }

    func testRateLimitPerInstance() {
        var limiter = CardScriptRateLimiter()
        let input = gateInput()
        for k in 0..<CardScriptLimits.callsPerSecond {
            if case .failure = CardScriptGate.check(input, limiter: &limiter, now: 10 + Double(k) * 0.01) { XCTFail("第 \(k) 次不该拒") }
        }
        guard case .failure(.rateLimited) = CardScriptGate.check(input, limiter: &limiter, now: 10.5) else { return XCTFail("第 21 次应限频") }
        var other = input; other.token = "tok2"; other.activeToken = "tok2"
        guard case .success = CardScriptGate.check(other, limiter: &limiter, now: 10.5) else { return XCTFail("别的实例不受影响") }
        guard case .success = CardScriptGate.check(input, limiter: &limiter, now: 11.2) else { return XCTFail("过了 1 秒恢复") }
        // 被前面步骤拒的不占额度
        var limiter2 = CardScriptRateLimiter(limit: 1)
        _ = CardScriptGate.check(gateInput(method: "generate"), limiter: &limiter2, now: 0)
        guard case .success = CardScriptGate.check(input, limiter: &limiter2, now: 0) else { return XCTFail("白名单外的没占额度") }
    }

    func testRequestParsing() {
        let parsed = CardScriptRequest.parse(method: .replaceVariables, args: #"{"variables":{"b":2,"a":1},"option":{"type":"message","message_id":"latest"}}"#)
        guard case .success(.replaceVariables(let scope, let table)) = parsed else { return XCTFail() }
        XCTAssertEqual(scope, .message(nil))
        XCTAssertEqual(String(data: table, encoding: .utf8), #"{"a":1,"b":2}"#)
        guard case .success(.replaceVariables(.message(-2), _)) = CardScriptRequest.parse(method: .replaceVariables,
            args: #"{"variables":{},"option":{"type":"message","message_id":-2}}"#) else { return XCTFail() }
        guard case .success(.replaceVariables(.chat, _)) = CardScriptRequest.parse(method: .replaceVariables, args: #"{"variables":{}}"#) else { return XCTFail("缺 option = chat") }
        let s = CardScriptRequest.parse(method: .setChatMessages,
            args: #"{"messages":[{"message_id":3,"message":"新","data":{"x":1},"swipe_id":1}],"option":{"refresh":"none"}}"#)
        guard case .success(.setChatMessages(let w, let refresh)) = s else { return XCTFail() }
        XCTAssertEqual(refresh, "none")
        XCTAssertEqual(w.first?.message, "新")
        XCTAssertEqual(w.first?.swipeId, 1)
        XCTAssertEqual(object(w.first?.data)["x"] as? Int, 1)
        XCTAssertNil(CardScriptRequest.integer(true))
        XCTAssertNil(CardScriptRequest.integer(1.5))
        XCTAssertEqual(CardScriptRequest.integer(-3), -3)
    }

    // MARK: - 楼层 / swipe 映射 + 写消息闸

    /// 0 开场（3 个兄弟，选中第 2 个）· 1 用户 · 2 助手（本实例所在）· 3 用户 · 4 助手（2 个兄弟）
    private let path = [
        CardPathFloor(nodeId: "g1", forkId: "root", swipeCount: 3, swipeIndex: 1),
        CardPathFloor(nodeId: "u1"),
        CardPathFloor(nodeId: "n2"),
        CardPathFloor(nodeId: "u3"),
        CardPathFloor(nodeId: "a4", forkId: "u3", swipeCount: 2, swipeIndex: 0),
    ]

    private func plan(_ writes: [CardMessageWrite], own: String = "n2") -> Result<[CardWriteStep], CardScriptRejection> {
        CardScriptPlanner.plan(.setChatMessages(writes, refresh: "affected"), path: path, ownNodeId: own)
    }

    func testFloorAndSwipeMapping() {
        XCTAssertNil(CardPathFloor(nodeId: "x", forkId: "f", swipeCount: 1).forkId, "单候选没有分叉点")
        XCTAssertEqual(CardPathFloor(nodeId: "x", forkId: "f", swipeCount: 2, swipeIndex: 9).swipeIndex, 1)
        XCTAssertEqual(CardScriptPlanner.resolve(-1, count: 5), 4)
        XCTAssertEqual(CardScriptPlanner.resolve(nil, count: 5), 4, "nil = 最新一楼")
        XCTAssertEqual(CardScriptPlanner.resolve(-5, count: 5), 0)
        XCTAssertNil(CardScriptPlanner.resolve(-6, count: 5))
        XCTAssertNil(CardScriptPlanner.resolve(5, count: 5))
        XCTAssertNil(CardScriptPlanner.resolve(0, count: 0))

        XCTAssertEqual(try plan([CardMessageWrite(messageId: 0, swipeId: 2)]).get(), [.switchSwipe(forkId: "root", index: 2)], "开场切到第 3 个")
        XCTAssertEqual(try plan([CardMessageWrite(messageId: 0, swipeId: 9)]).get(), [.switchSwipe(forkId: "root", index: 2)], "越界钳到末个（同助手 clamp）")
        XCTAssertEqual(try plan([CardMessageWrite(messageId: 0, swipeId: 1)]).get(), [], "已经是这个：不动")
        XCTAssertEqual(try plan([CardMessageWrite(messageId: 1, swipeId: 1)]).get(), [], "单候选楼层：不动")
        XCTAssertEqual(try plan([CardMessageWrite(messageId: -1, swipeId: 1)]).get(), [.switchSwipe(forkId: "u3", index: 1)], "负数楼号")
        XCTAssertEqual(try plan([CardMessageWrite(messageId: 7, swipeId: 1)]).get(), [], "不存在的楼层跳过")
    }

    func testWriteGateOwnFloorAndAfter() {
        XCTAssertEqual(try plan([CardMessageWrite(messageId: 2, message: "本楼")]).get(), [.editMessage(nodeId: "n2", text: "本楼")])
        XCTAssertEqual(try plan([CardMessageWrite(messageId: 4, message: "之后")]).get(), [.editMessage(nodeId: "a4", text: "之后")])
        XCTAssertEqual(try plan([CardMessageWrite(messageId: -1, message: "末楼")]).get(), [.editMessage(nodeId: "a4", text: "末楼")])
        XCTAssertEqual(plan([CardMessageWrite(messageId: 1, message: "早楼")]), .failure(.earlierFloor))
        XCTAssertEqual(plan([CardMessageWrite(messageId: 4, message: "后"), CardMessageWrite(messageId: 0, message: "早")]), .failure(.earlierFloor),
                       "一条越权整个调用拒，什么都不写")
        XCTAssertEqual(plan([CardMessageWrite(messageId: 4, message: "x")], own: "gone"), .failure(.earlierFloor), "本实例不在当前路径：不许改正文")
        let data = Data(#"{"hp":3}"#.utf8)
        XCTAssertEqual(try plan([CardMessageWrite(messageId: 0, data: data)]).get(), [.setMessageVariables(nodeId: "g1", table: data)], "data 不受楼层闸")
        // 同楼合并 + 正文 / 变量先于切 swipe
        let merged = try? plan([CardMessageWrite(messageId: 0, swipeId: 0), CardMessageWrite(messageId: 4, message: "a"),
                                CardMessageWrite(messageId: 4, data: data)]).get()
        XCTAssertEqual(merged, [.editMessage(nodeId: "a4", text: "a"), .setMessageVariables(nodeId: "a4", table: data),
                                .switchSwipe(forkId: "root", index: 0)])
        // 变量作用域
        XCTAssertEqual(try CardScriptPlanner.plan(.replaceVariables(scope: .chat, table: data), path: path, ownNodeId: "n2").get(), [.setChatVariables(data)])
        XCTAssertEqual(try CardScriptPlanner.plan(.replaceVariables(scope: .message(nil), table: data), path: path, ownNodeId: "n2").get(),
                       [.setMessageVariables(nodeId: "a4", table: data)])
        guard case .failure(.outOfRange) = CardScriptPlanner.plan(.replaceVariables(scope: .message(9), table: data), path: path, ownNodeId: "n2") else {
            return XCTFail("越界楼号报错")
        }
    }

    // MARK: - 变量

    func testVariableLazyInitAndLimits() throws {
        let header = json(["chat_metadata": ["variables": ["好感": "3"]], "user_name": "u"])
        let convMeta = Data(json(["source": "sillytavern", "header": header]).utf8)
        XCTAssertEqual(CardVariables.chatInitial(conversationMetadata: convMeta)["好感"] as? String, "3")
        XCTAssertTrue(CardVariables.chatInitial(conversationMetadata: nil).isEmpty)
        XCTAssertTrue(CardVariables.chatInitial(conversationMetadata: Data(#"{"header":"{坏"}"#.utf8)).isEmpty)
        let stored = Data(#"{"好感":"9"}"#.utf8)
        XCTAssertEqual(CardVariables.effectiveChat(stored: stored, conversationMetadata: convMeta)["好感"] as? String, "9", "写过就用自己的，不再读导入原件")

        // 选中候选挂整个 variables[]：拆给第 i 个兄弟，越界 / 非对象给空
        let selected = Data(json(["selected": true, "candidate": 1, "fields": ["variables": [["a": 0], ["a": 1], "坏"]]]).utf8)
        func meta(_ i: Int) -> Data { Data(json(["selected": false, "candidate": i]).utf8) }
        XCTAssertEqual(CardVariables.messageInitial(nodeMetadata: meta(0), selectedMetadata: selected, fallbackIndex: 9)["a"] as? Int, 0)
        XCTAssertEqual(CardVariables.messageInitial(nodeMetadata: selected, selectedMetadata: selected, fallbackIndex: 9)["a"] as? Int, 1)
        XCTAssertTrue(CardVariables.messageInitial(nodeMetadata: meta(2), selectedMetadata: selected, fallbackIndex: 0).isEmpty, "非对象给空")
        XCTAssertTrue(CardVariables.messageInitial(nodeMetadata: meta(5), selectedMetadata: selected, fallbackIndex: 0).isEmpty, "越界给空")
        XCTAssertEqual(CardVariables.messageInitial(nodeMetadata: nil, selectedMetadata: selected, fallbackIndex: 1)["a"] as? Int, 1, "没元数据按兄弟序号")
        let dictForm = Data(json(["selected": true, "fields": ["variables": ["0": ["k": "v"]]]]).utf8)
        XCTAssertEqual(CardVariables.messageInitial(nodeMetadata: nil, selectedMetadata: dictForm, fallbackIndex: 0)["k"] as? String, "v", "旧对象形态")
        XCTAssertTrue(CardVariables.messageInitial(nodeMetadata: nil, selectedMetadata: nil, fallbackIndex: 0).isEmpty, "非导入消息")
        XCTAssertTrue(CardVariables.isSelectedCandidate(selected))
        XCTAssertFalse(CardVariables.isSelectedCandidate(meta(0)))
        XCTAssertEqual(CardVariables.effectiveMessage(stored: stored, nodeMetadata: meta(0), selectedMetadata: selected, fallbackIndex: 0)["好感"] as? String, "9")

        // 上限 256KB
        guard case .success = CardVariables.encode(["s": String(repeating: "x", count: CardScriptLimits.variableTableBytes - 20)]) else { return XCTFail() }
        XCTAssertEqual(CardVariables.encode(["s": String(repeating: "x", count: CardScriptLimits.variableTableBytes)]).failureValue,
                       .tooLarge("变量表（上限 256KB）"))
        let big = #"{"messages":[{"message_id":0,"data":{"s":""# + String(repeating: "y", count: CardScriptLimits.variableTableBytes) + #""}}]}"#
        XCTAssertEqual(CardScriptRequest.parse(method: .setChatMessages, args: big).failureValue, .tooLarge("变量表（上限 256KB）"))
    }

    // MARK: - 快照

    func testSnapshotTruncatesWindowAndKeepsOwnFloor() throws {
        let body = String(repeating: "字", count: 2000)   // 每楼约 6KB
        let floor = { (i: Int) in
            CardSnapshotFloor(role: i % 2 == 0 ? "assistant" : "user", name: "n", message: "\(i)<script>\(body)",
                              swipeId: 0, swipes: ["\(i)"], swipesData: [["i": i]])
        }
        let full = CardScriptSnapshot.build(count: 5, floor: floor, currentId: 2, chat: ["c": 1], charName: "岚", userName: "你")
        XCTAssertFalse(full.contains("<"), "可直接嵌进 <script>")
        let f = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(full.utf8)) as? [String: Any])
        XCTAssertEqual((f["messages"] as? [Any])?.count, 5)
        XCTAssertEqual(f["firstId"] as? Int, 0)
        XCTAssertEqual(f["lastId"] as? Int, 4)
        XCTAssertEqual(f["currentId"] as? Int, 2)
        XCTAssertEqual(f["char"] as? String, "岚")
        let m2 = try XCTUnwrap((f["messages"] as? [[String: Any]])?[2])
        XCTAssertEqual((m2["data"] as? [String: Any])?["i"] as? Int, 2)
        XCTAssertEqual(m2["message"] as? String, "2<script>\(body)", "转义后解析回原文")

        let cut = CardScriptSnapshot.build(count: 200, floor: floor, currentId: 3, chat: [:], charName: "c", userName: "u", maxBytes: 60_000)
        XCTAssertLessThanOrEqual(cut.utf8.count, 60_000 + 512)
        let c = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cut.utf8)) as? [String: Any])
        let ids = (c["messages"] as? [[String: Any]] ?? []).compactMap { $0["message_id"] as? Int }
        XCTAssertEqual(c["truncated"] as? Bool, true)
        XCTAssertEqual(ids.last, 199, "从最新一楼往前装")
        XCTAssertEqual(ids.first, 3, "本楼被截掉也单独带上")
        XCTAssertGreaterThan(c["firstId"] as? Int ?? 0, 3)
        XCTAssertEqual(c["lastId"] as? Int, 199)
    }

    // MARK: - 事件

    private func sig(_ id: String, _ role: String = "assistant", _ text: String = "", fork: String? = nil) -> CardEventFloorSig {
        CardEventFloorSig(nodeId: id, role: role, contentHash: text.hashValue, forkId: fork)
    }

    func testEventDiff() {
        let base = [sig("g"), sig("u1", "user")]
        XCTAssertEqual(CardScriptEvents.diff(old: base, new: base, wasGenerating: false, isGenerating: false), [])
        // 发送 → 生成开始（助手占位还在生成中不报收到）→ 生成结束
        let sent = base + [sig("u2", "user"), sig("a2")]
        XCTAssertEqual(CardScriptEvents.diff(old: base, new: sent, wasGenerating: false, isGenerating: true),
                       [CardScriptEvent(name: "generation_started", args: #"["normal",{},false]"#),
                        CardScriptEvent(name: "message_sent", args: "[2]")])
        let done = base + [sig("u2", "user"), sig("a2", "assistant", "回复")]
        XCTAssertEqual(CardScriptEvents.diff(old: sent, new: done, wasGenerating: true, isGenerating: false),
                       [CardScriptEvent(name: "message_received", args: #"[3,"normal"]"#),
                        CardScriptEvent(name: "generation_ended", args: "[3]")])
        // 编辑
        let edited = [sig("g", "assistant", "改了"), sig("u1", "user")]
        XCTAssertEqual(CardScriptEvents.diff(old: base, new: edited, wasGenerating: false, isGenerating: false),
                       [CardScriptEvent(name: "message_edited", args: "[0]"), CardScriptEvent(name: "message_updated", args: "[0]")])
        // 切 swipe（同一分叉点换了孩子）
        let a = [sig("g1", fork: "root"), sig("u", "user")]
        let b = [sig("g2", fork: "root"), sig("v", "user")]
        XCTAssertEqual(CardScriptEvents.diff(old: a, new: b, wasGenerating: false, isGenerating: false), [CardScriptEvent(name: "message_swiped", args: "[0]")])
        // 删除（末尾 / 中间）
        XCTAssertEqual(CardScriptEvents.diff(old: done, new: base + [sig("u2", "user")], wasGenerating: false, isGenerating: false),
                       [CardScriptEvent(name: "message_deleted", args: "[3]")])
        XCTAssertEqual(CardScriptEvents.diff(old: [sig("x"), sig("y"), sig("z")], new: [sig("x"), sig("z")], wasGenerating: false, isGenerating: false),
                       [CardScriptEvent(name: "message_deleted", args: "[2]")])
        // 收到（非生成：比如后台追加）
        XCTAssertEqual(CardScriptEvents.diff(old: base, new: base + [sig("a9")], wasGenerating: false, isGenerating: false),
                       [CardScriptEvent(name: "message_received", args: #"[2,"normal"]"#)])
    }

    // MARK: - 宿主：一次完整的 call

    private final class Probe {
        var js: [String] = []
        var active: String?
        var executed: [CardScriptRequest] = []
        var refreshed = 0
    }

    private func makeHost(_ probe: Probe) -> HTMLEmbedHost {
        let host = HTMLEmbedHost()
        host.eval = { probe.js.append($0) }
        host.activeKey = { probe.active }
        host.setActiveKey = { probe.active = $0 }
        host.runDenial = nil
        host.currentScope = { ("p", "c") }
        host.bridge = { id, mode in HTMLEmbedBridge(segmentId: id.segmentId, snapshot: mode == .interactive ? #"{"v":1,"lastId":2}"# : nil) }
        host.execute = { req, _ in probe.executed.append(req); return .success(false) }
        host.refreshAfterWrite = { probe.refreshed += 1 }
        host.replaceSources([(identity, "<p>面板</p>")])
        return host
    }

    func testHostCallFlowAndRejections() throws {
        let probe = Probe()
        let host = makeHost(probe)
        host.now = { 100 }
        host.handle(.run(nodeId: "n2", segmentId: "h0"))
        let token = try XCTUnwrap(host.interactive?.token)
        let doc = try XCTUnwrap(host.registry.entry(token)?.document)
        XCTAssertTrue(doc.contains("window.TavernHelper = TH"), "交互文档带垫片")
        XCTAssertTrue(doc.contains(#""snapshot":{"v":1,"lastId":2}"#), "快照预置进文档")

        probe.js = []
        host.handle(.call(token: token, nodeId: "n2", segmentId: "h0", callId: "c1", method: "replaceVariables",
                          args: #"{"variables":{"a":1}}"#))
        XCTAssertEqual(probe.executed.count, 1)
        XCTAssertEqual(probe.js.count, 2, "先 snapshotUpdate 后 result")
        XCTAssertTrue(probe.js[0].contains(#""type":"snapshotUpdate""#))
        XCTAssertTrue(probe.js[1].contains(#""type":"result","id":"c1","ok":true"#))

        // 伪造：别的 token / 冒充别的段 → 不执行、不回包
        probe.js = []
        host.handle(.call(token: "forged", nodeId: "n2", segmentId: "h0", callId: "c2", method: "replaceVariables", args: "{}"))
        host.handle(.call(token: token, nodeId: "n1", segmentId: "h0", callId: "c3", method: "replaceVariables", args: "{}"))
        XCTAssertEqual(probe.executed.count, 1)
        XCTAssertTrue(probe.js.isEmpty)
        // 白名单外：回错误
        host.handle(.call(token: token, nodeId: "n2", segmentId: "h0", callId: "c4", method: "generate", args: "{}"))
        XCTAssertTrue(probe.js.last?.contains(#""ok":false,"error":"记忆花园暂不支持 generate""#) == true)
        // 刷调用（同一秒里第 1 次已用掉 1 个额度）
        for k in 0..<30 {
            host.handle(.call(token: token, nodeId: "n2", segmentId: "h0", callId: "r\(k)", method: "replaceVariables", args: #"{"variables":{}}"#))
        }
        XCTAssertEqual(probe.executed.count, CardScriptLimits.callsPerSecond)
        XCTAssertTrue(probe.js.last?.contains("调用太频繁") == true)
        // 撤权后：拒
        host.runDenial = "关了"
        XCTAssertNil(host.interactive, "撤权当场销毁")
        host.now = { 200 }
        host.handle(.call(token: token, nodeId: "n2", segmentId: "h0", callId: "z", method: "replaceVariables", args: #"{"variables":{}}"#))
        XCTAssertEqual(probe.executed.count, CardScriptLimits.callsPerSecond)
    }

    func testHostResizeClampAndReports() throws {
        let probe = Probe()
        let host = makeHost(probe)
        host.handle(.mount(nodeId: "n2", segmentId: "h0"))
        let token = try XCTUnwrap(host.registry.entries.keys.first)
        let entry = try XCTUnwrap(host.registry.entry(token))
        XCTAssertEqual(entry.mode, .staticView)
        let nonce = try XCTUnwrap(entry.nonce)
        XCTAssertTrue(entry.document.contains("<script nonce=\"\(nonce)\">"), "静态只带量高度脚本")
        XCTAssertFalse(entry.document.contains("TavernHelper"))
        XCTAssertTrue(HTMLEmbedPolicy.contentSecurityPolicy(.staticView, nonce: nonce).contains("script-src 'nonce-\(nonce)';"))

        probe.js = []
        host.handle(.resize(token: token, nodeId: "n2", segmentId: "h0", height: 40))
        host.handle(.resize(token: token, nodeId: "n2", segmentId: "h0", height: 5000))
        host.handle(.resize(token: token, nodeId: "n2", segmentId: "h0", height: 512.2))
        host.handle(.resize(token: "forged", nodeId: "n2", segmentId: "h0", height: 300))
        XCTAssertEqual(probe.js.count, 3)
        XCTAssertTrue(probe.js[0].hasSuffix(", 120.0)"))
        XCTAssertTrue(probe.js[1].hasSuffix(", 2000.0)"))
        XCTAssertTrue(probe.js[2].hasSuffix(", 513.0)"))

        host.handle(.cspReport(token: token, nodeId: "n2", segmentId: "h0", kind: "csp", text: "img-src https://i.imgur.com/a.png"))
        host.handle(.cspReport(token: token, nodeId: "n2", segmentId: "h0", kind: "unsupported", text: "triggerSlash"))
        host.handle(.cspReport(token: "forged", nodeId: "n2", segmentId: "h0", kind: "unsupported", text: "x"))
        let report = try XCTUnwrap(host.runtimeReports["p"])
        XCTAssertEqual(report.blockedCount, 1)
        XCTAssertEqual(report.unsupportedAPIs, ["triggerSlash"])

        XCTAssertEqual(HTMLEmbedMessage(body: ["type": "htmlCall", "nodeId": "n", "segmentId": "h0", "token": "t", "callId": "c", "method": "m", "args": "{}"]),
                       .call(token: "t", nodeId: "n", segmentId: "h0", callId: "c", method: "m", args: "{}"))
        XCTAssertNil(HTMLEmbedMessage(body: ["type": "htmlCSP", "nodeId": "n", "segmentId": "h0", "token": "t", "kind": "other"]))
        XCTAssertNil(HTMLEmbedMessage(body: ["type": "htmlResize", "nodeId": "n", "segmentId": "h0", "token": "t", "height": "x"]))
    }

    func testHostRerunsOwnSegmentAfterEditingIt() throws {
        let probe = Probe()
        let host = makeHost(probe)
        host.execute = { [unowned host] _, _ in
            host.replaceSources([(self.identity, "<p>改过的面板</p>")])   // 模拟 refresh 后段内容变了
            return .success(true)
        }
        host.refreshAfterWrite = { probe.refreshed += 1 }
        host.handle(.run(nodeId: "n2", segmentId: "h0"))
        let first = try XCTUnwrap(host.interactive?.token)
        host.handle(.call(token: first, nodeId: "n2", segmentId: "h0", callId: "c", method: "setChatMessages",
                          args: #"{"messages":[{"message_id":2,"message":"x"}]}"#))
        XCTAssertEqual(probe.refreshed, 1)
        let second = try XCTUnwrap(host.interactive?.token)
        XCTAssertNotEqual(first, second, "按新内容重跑")
        XCTAssertEqual(host.registry.entry(second)?.content, "<p>改过的面板</p>")
    }

    // MARK: - 子页 JS 纯函数（JavaScriptCore 直接跑注入的那段）

    func testShimHelpersRangeMergeUnset() throws {
        let ctx = try XCTUnwrap(JSContext())
        ctx.evaluateScript(CardScriptShim.helpers)
        func eval(_ s: String) -> String { ctx.evaluateScript("JSON.stringify(\(s))")?.toString() ?? "?" }
        XCTAssertEqual(eval("__mpTH.stringToRange('0-9', 0, 9)"), #"{"start":0,"end":9}"#)
        XCTAssertEqual(eval("__mpTH.stringToRange('3', 0, 9)"), #"{"start":3,"end":3}"#)
        XCTAssertEqual(eval("__mpTH.stringToRange('-1', 0, 9)"), #"{"start":9,"end":9}"#, "负数＝从末尾数")
        XCTAssertEqual(eval("__mpTH.stringToRange('-3--1', 0, 9)"), #"{"start":7,"end":9}"#)
        XCTAssertEqual(eval("__mpTH.stringToRange('7-2', 0, 9)"), #"{"start":2,"end":7}"#, "倒序排好")
        XCTAssertEqual(eval("__mpTH.stringToRange('5-20', 0, 9)"), #"{"start":5,"end":9}"#, "越界钳位（同助手 string_to_range）")
        XCTAssertEqual(eval("__mpTH.stringToRange('-20', 0, 9)"), #"{"start":0,"end":0}"#)
        XCTAssertEqual(eval("__mpTH.stringToRange('a-b', 0, 9)"), "null")
        XCTAssertEqual(eval("__mpTH.stringToRange(' 3', 0, 9)"), "null")
        XCTAssertEqual(eval("__mpTH.merge({a:{x:1,y:[1,2]},b:1}, {a:{y:[9],z:2},c:undefined})"), #"{"a":{"x":1,"y":[9],"z":2},"b":1}"#, "数组整个替换、对象深合并")
        XCTAssertEqual(eval("__mpTH.merge(__mpTH.merge({}, {a:1,b:{c:1}}), {a:2,b:{d:2}})"), #"{"a":2,"b":{"c":1,"d":2}}"#)
        XCTAssertEqual(eval("(function(){var o={a:{b:[{c:1,d:2}]}}; var r=__mpTH.unset(o,'a.b[0].c'); return [r,o];})()"), #"[true,{"a":{"b":[{"d":2}]}}]"#)
        XCTAssertEqual(eval("(function(){var o={'a.b':1,a:{b:2}}; __mpTH.unset(o,'a.b'); return o;})()"), #"{"a":{"b":2}}"#, "整串是现成的键就按键删（同 lodash isKey）")
        XCTAssertEqual(eval("(function(){var o={a:{\"x y\":1}}; __mpTH.unset(o,'a[\"x y\"]'); return o;})()"), #"{"a":{}}"#)
        XCTAssertEqual(eval("__mpTH.utf8Bytes('a字')"), "4")
        XCTAssertEqual(eval("__mpTH.substitute('{{char}}和{{User}}', {char:'岚', user:'你'})"), #""岚和你""#)
    }

    // MARK: - 存储新列：旧数据缺键兼容 + 备份往返

    func testNewColumnsBackupRoundTripAndOldDocuments() throws {
        let conversation = Conversation(id: "c", title: "t", createTime: Date(timeIntervalSince1970: 1), updateTime: Date(timeIntervalSince1970: 2),
                                        currentNodeId: "n", provider: "sillytavern", profileId: "p")
        XCTAssertNil(conversation.cardVariablesData)
        conversation.cardVariablesData = Data(#"{"好感":"5"}"#.utf8)
        let node = MessageNode(id: "n", role: "assistant", content: "x", contentType: "text", createTime: nil, parentId: nil,
                               childrenIds: [], conversationId: "c", profileId: "p")
        XCTAssertNil(node.cardVariablesData)
        XCTAssertNil(node.cardEditedAt)
        node.cardVariablesData = Data(#"{"hp":3}"#.utf8)
        node.cardEditedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let doc = FullConversationDocument(model: conversation, nodes: [node])
        let decoded = try JSONDecoder().decode(FullConversationDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(decoded.toConversationModel().cardVariablesData, Data(#"{"好感":"5"}"#.utf8))
        let restoredNode = try XCTUnwrap(decoded.nodes.first?.toNodeModel())
        XCTAssertEqual(restoredNode.cardVariablesData, Data(#"{"hp":3}"#.utf8))
        XCTAssertEqual(restoredNode.cardEditedAt, Date(timeIntervalSince1970: 1_700_000_000))

        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as? [String: Any])
        raw.removeValue(forKey: "cardVariablesData")
        var rawNode = try XCTUnwrap((raw["nodes"] as? [[String: Any]])?.first)
        rawNode.removeValue(forKey: "cardVariablesData")
        rawNode.removeValue(forKey: "cardEditedAt")
        raw["nodes"] = [rawNode]
        let old = try JSONDecoder().decode(FullConversationDocument.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(old.toConversationModel().cardVariablesData)
        XCTAssertNil(old.nodes.first?.toNodeModel().cardVariablesData)
        XCTAssertNil(old.nodes.first?.toNodeModel().cardEditedAt)

        XCTAssertTrue(Set(SchemaCoverageCheck.modelFieldNames(conversation)).contains("cardVariablesData"))
        XCTAssertTrue(Set(SchemaCoverageCheck.documentFieldNames(sample: doc)).contains("cardVariablesData"))
        XCTAssertTrue(Set(SchemaCoverageCheck.modelFieldNames(node)).isSuperset(of: ["cardVariablesData", "cardEditedAt"]))
        XCTAssertTrue(Set(SchemaCoverageCheck.documentFieldNames(sample: FullNodeDocument(model: node))).isSuperset(of: ["cardVariablesData", "cardEditedAt"]))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
