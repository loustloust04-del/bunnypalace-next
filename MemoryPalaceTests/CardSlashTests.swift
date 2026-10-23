import XCTest
@testable import 记忆花园

/// 卡库第二批 B5 / B6（+ 附带三项）：slash 解析（引号 / 管道 / 白名单）、sendConsent 三态 + 缺键 + 重置、
/// 防护（生成中 / 3 秒 / 等确认 / 非激活实例）、宿主 triggerSlash 全流程、自动运行选择、本地模式 CSP、picsum 跳转、edited 文案。
/// 全部临时目录 / 临时 suite，不碰 app 存储
@MainActor
final class CardSlashTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("b56-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "CardSlashTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func plan(_ text: String) -> CardSlashPlan? {
        if case .success(let p) = CardSlash.plan(text, charName: "岚", userName: "阿禾") { return p }
        return nil
    }

    private func failure(_ text: String) -> CardScriptRejection? {
        if case .failure(let e) = CardSlash.plan(text, charName: "岚", userName: "阿禾") { return e }
        return nil
    }

    // MARK: - slash 解析

    func testSlashQuotesFollowTavernRawQuotes() {
        XCTAssertEqual(plan("/send 你好")?.actions, [.send("你好")], "不带引号")
        XCTAssertEqual(plan(#"/send "推开门，走进去""#)?.actions, [.send(#""推开门，走进去""#)], "/send 是 rawQuotes：默认引号原样保留（同酒馆）")
        XCTAssertEqual(plan(#"/send raw=false "推开门，走进去""#)?.actions, [.send("推开门，走进去")], "raw=false 去引号")
        XCTAssertEqual(plan(#"/setinput "带 引号""#)?.actions, [.setInput("带 引号")], "/setinput 去引号")
        XCTAssertEqual(plan(#"/setinput "前半"后半  "#)?.actions, [.setInput("前半后半")], "引号后面的字接上（酒馆 join('')）")
        XCTAssertEqual(plan(#"/echo title="标题 有空格" severity=warning 正文"#)?.actions, [.echo("正文")], "命名参数（带引号 / 不带）不进正文")
        XCTAssertEqual(plan("/send    前后空白   ")?.actions, [.send("前后空白")])
        XCTAssertEqual(failure(#"/setinput "没闭合"#), .badArguments("/setinput 的引号没闭合"))
    }

    func testSlashPipesInjectionAndMacros() {
        let sendTrigger = plan("/send 我推开门|/trigger")
        XCTAssertEqual(sendTrigger?.actions, [.send("我推开门"), .trigger])
        XCTAssertEqual(sendTrigger?.steps, [.sendAndReply("我推开门")], "/send 紧跟 /trigger = 手动发送同一个入口")
        XCTAssertEqual(sendTrigger?.result, "")
        XCTAssertEqual(plan("/send 甲 | /send 乙 | /trigger")?.steps, [.append("甲"), .sendAndReply("乙")])
        XCTAssertEqual(plan("/trigger")?.steps, [.reply])
        XCTAssertEqual(plan("/send 只加")?.steps, [.append("只加")])

        XCTAssertEqual(plan("/echo 早上好 | /setinput")?.actions, [.echo("早上好"), .setInput("早上好")], "没写参数吃上一条的结果")
        XCTAssertEqual(plan("/echo 早上好 || /setinput")?.actions, [.echo("早上好"), .setInput("")], "|| 不注入")
        XCTAssertEqual(plan("/echo a | /setinput 前{{pipe}}后")?.actions, [.echo("a"), .setInput("前a后")], "{{pipe}}")
        XCTAssertEqual(plan("/echo a | /setinput b")?.result, "b", "返回管道最后的值")
        XCTAssertEqual(plan(#"/echo 竖线\|在这"#)?.actions, [.echo("竖线|在这")], #"\| 是字面竖线"#)
        XCTAssertEqual(plan("/echo {{getvar::a|b}}")?.actions, [.echo("{{getvar::a|b}}")], "{{ }} 里的竖线不切")
        XCTAssertEqual(plan("/setinput 我是{{user}}，你是{{CHAR}}")?.actions, [.setInput("我是阿禾，你是岚")], "名字走有效身份")
        XCTAssertEqual(plan(#"/echo \{\{user\}\}"#)?.actions, [.echo("{{user}}")], "转义的花括号不展开")
        XCTAssertEqual(plan("随便的字 | // 注释 | /echo x")?.actions, [.echo("x")], "不是命令的字 / 注释丢掉")
        XCTAssertEqual(plan("/echo")?.actions, [], "空 echo 不提示")
    }

    func testSlashRejectsNonWhitelistAndBadShapes() {
        XCTAssertEqual(failure("/gen 写一段"), .unsupported("/gen"))
        XCTAssertEqual(failure("/gen 写一段")?.message, "记忆花园暂不支持 /gen")
        XCTAssertEqual(failure("/send 好 | /setvar key=a 1 | /trigger"), .unsupported("/setvar"), "管道里有一条不认 → 整条不执行")
        XCTAssertEqual(failure("/sendas name=岚 你好"), .unsupported("/sendas"))
        XCTAssertEqual(failure("/send at=0 插到最前"), .unsupported("/send 的 at 参数"))
        XCTAssertEqual(failure("/echo {: /send x :}"), .unsupported("slash 闭包 {: … :}"))
        XCTAssertEqual(failure("/send   "), .badArguments("/send 没有要发的文字"))
        XCTAssertEqual(failure("/trigger | /trigger"), .refused("一次只能让 AI 回复一次"))
        XCTAssertEqual(failure("/trigger | /send 晚了"), .refused("/trigger 之后不能再 /send"))
        XCTAssertEqual(failure("只是字"), .badArguments("没有可执行的命令"))

        XCTAssertEqual(CardScriptRequest.parse(method: .triggerSlash, args: #"{"command":"/send hi"}"#), .success(.triggerSlash("/send hi")))
        XCTAssertEqual(CardScriptRequest.parse(method: .triggerSlash, args: #"{"command":1}"#), .failure(.badArguments("command 必须是字符串")))
        let big = #"{"command":"/echo "# + String(repeating: "x", count: CardSlash.maxBytes) + #""}"#
        XCTAssertEqual(CardScriptRequest.parse(method: .triggerSlash, args: big), .failure(.tooLarge("slash 命令")))
    }

    func testDegradedStepsFillInputInPlace() throws {
        let p = try XCTUnwrap(plan("/echo 提示 | /send 推开门 | /trigger"))
        XCTAssertEqual(p.degradedSteps(cardName: "白石"),
                       [.toast("提示"), .fillInput("推开门"), .toast("「白石」不能替你发消息，要发的话放进了输入框")])
        XCTAssertEqual(try XCTUnwrap(plan("/trigger")).degradedSteps(cardName: "白石"), [.toast("「白石」不能替你让 AI 回复")])
    }

    // MARK: - sendConsent 三态 / 缺键 / 重置

    private func encoded(_ card: CharacterCard) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
    }

    func testSendConsentThreeStatesAndMissingKey() throws {
        var card = CharacterCard(name: "岚", description: "", personality: "", scenario: "", firstMes: "")
        XCTAssertEqual(card.sendConsent, .unknown)
        XCTAssertNil(try encoded(card)["sendConsent"], "unknown 不写键：没问过的卡 blob 字节不变")
        for state in [CardSendConsent.allowed, .denied] {
            card.sendConsent = state
            XCTAssertEqual(try encoded(card)["sendConsent"] as? String, state.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(CharacterCard.self, from: JSONEncoder().encode(card)).sendConsent, state)
        }
        var raw = try encoded(card)
        raw.removeValue(forKey: "sendConsent")
        XCTAssertEqual(try JSONDecoder().decode(CharacterCard.self, from: JSONSerialization.data(withJSONObject: raw)).sendConsent, .unknown, "缺键 = unknown")
        raw["sendConsent"] = "maybe"
        XCTAssertEqual(try JSONDecoder().decode(CharacterCard.self, from: JSONSerialization.data(withJSONObject: raw)).sendConsent, .unknown, "认不得的值 = unknown")
    }

    private func rule(_ replace: String) -> RegexScript {
        var r = RegexScript()
        r.id = "r"
        r.findRegex = "a"
        r.replaceString = replace
        return r
    }

    func testSendConsentResetsWithExtensionConsent() throws {
        let manager = CharacterCardManager(root: dir.appendingPathComponent("blobs"), libraryRoot: dir.appendingPathComponent("cardlibrary"), defaults: defaults)
        var card = CharacterCard(name: "岚", description: "", personality: "", scenario: "", firstMes: "")
        card.id = "c1"
        card.regexScripts = [rule("b")]
        card.extensionConsent = .allowed
        card.sendConsent = .allowed
        try manager.add(card)

        var renamed = try XCTUnwrap(manager.cards.first)
        renamed.name = "岚二"
        try manager.update(renamed)
        XCTAssertEqual(manager.cards.first?.sendConsent, .allowed, "规则 / 脚本没变：不打回")

        var changed = try XCTUnwrap(manager.cards.first)
        changed.regexScripts = [rule("c")]
        try manager.update(changed)
        XCTAssertEqual(manager.cards.first?.extensionConsent, .unknown)
        XCTAssertEqual(manager.cards.first?.sendConsent, .unknown, "规则变了：和 extensionConsent 一起打回 unknown")

        var denied = try XCTUnwrap(manager.cards.first)
        denied.sendConsent = .denied
        try manager.update(denied)
        let reopened = CharacterCardManager(root: dir.appendingPathComponent("blobs"), libraryRoot: dir.appendingPathComponent("cardlibrary"), defaults: defaults)
        XCTAssertEqual(reopened.cards.first?.sendConsent, .denied, "落盘往返")
    }

    // MARK: - 防护

    private func card(_ consent: CardSendConsent, allowed: Bool = true, id: String = "c1") -> CardSlashGate.Card {
        CardSlashGate.Card(id: id, name: "白石", consent: consent, allowed: allowed)
    }

    private func decide(_ text: String, origin: CardSlashGate.Origin? = .user, card: CardSlashGate.Card?, generating: Bool = false,
                        awaiting: Bool = false, throttle: inout CardSlashThrottle, now: TimeInterval = 0) -> Result<CardSlashGate.Decision, CardScriptRejection> {
        CardSlashGate.decide(CardSlashGate.Input(plan: plan(text)!, origin: origin, card: card, generating: generating, awaitingConfirm: awaiting),
                             throttle: &throttle, now: now)
    }

    func testSlashGuardsBusyThrottleAndInstances() {
        var t = CardSlashThrottle()
        XCTAssertEqual(decide("/send 好|/trigger", card: card(.allowed), throttle: &t), .success(.run([.sendAndReply("好")])))
        XCTAssertEqual(decide("/send 好|/trigger", card: card(.allowed), throttle: &t, now: 1), .failure(.refused("点得太快了：同一张卡 3 秒内只能发一次")))
        XCTAssertEqual(decide("/send 好|/trigger", card: card(.allowed, id: "c2"), throttle: &t, now: 1), .success(.run([.sendAndReply("好")])), "别的卡不受影响")
        XCTAssertEqual(decide("/send 好|/trigger", card: card(.allowed), throttle: &t, now: 3.01), .success(.run([.sendAndReply("好")])), "3 秒后放行")

        XCTAssertEqual(decide("/trigger", card: card(.allowed), generating: true, throttle: &t, now: 10), .failure(.refused("正在生成回复，等这条写完再点")))
        XCTAssertEqual(decide("/send x", card: card(.unknown), awaiting: true, throttle: &t, now: 10), .failure(.refused("上一条还在等你确认")))
        XCTAssertEqual(decide("/trigger", card: card(.allowed), throttle: &t, now: 10), .success(.run([.reply])), "被拒的两次没占 3 秒额度")
        XCTAssertEqual(decide("/echo 嗨 | /setinput", card: card(.unknown), generating: true, throttle: &t, now: 10.5),
                       .success(.run([.toast("嗨"), .fillInput("嗨")])), "不发消息的命令不问、不限 3 秒、生成中也行")

        XCTAssertEqual(decide("/send x", card: card(.unknown), throttle: &t, now: 20),
                       .success(.ask(CardSendConfirmation(cardName: "白石", texts: ["x"], replies: false))))
        XCTAssertEqual(decide("/send x|/trigger", card: card(.denied), throttle: &t, now: 30),
                       .success(.degrade([.fillInput("x"), .toast("「白石」不能替你发消息，要发的话放进了输入框")])))

        XCTAssertEqual(decide("/send x", origin: nil, card: card(.allowed), throttle: &t, now: 40), .failure(.refused("只有正在运行的网页能用 triggerSlash")), "非激活实例")
        XCTAssertEqual(decide("/send x", card: nil, throttle: &t, now: 40), .failure(.refused("只有卡聊天里的网页能用 triggerSlash")))
        XCTAssertEqual(decide("/send x", origin: .auto, card: card(.allowed, allowed: false), throttle: &t, now: 40), .failure(.refused("「白石」还没启用")),
                       "自动运行的实例只认已许可的卡")
        XCTAssertEqual(decide("/send x", origin: .auto, card: card(.allowed), throttle: &t, now: 40), .success(.run([.append("x")])))
    }

    // MARK: - 宿主：triggerSlash 全流程

    private final class SlashProbe {
        var js: [String] = []
        var active: String?
        var performed: [CardSlashStep] = []
        var confirms: [CardSendConfirmation] = []
        var pending: ((CardSendChoice?) -> Void)?
        var consent: CardSendConsent = .unknown
        var generating = false
        var scope = (profileId: "p", conversationId: "c")
        var hasCard = true
    }

    private let identity = HTMLEmbedIdentity(profileId: "p", conversationId: "c", nodeId: "n2", segmentId: "h0")

    private func makeHost(_ probe: SlashProbe) -> HTMLEmbedHost {
        let host = HTMLEmbedHost()
        host.eval = { probe.js.append($0) }
        host.activeKey = { probe.active }
        host.setActiveKey = { probe.active = $0 }
        host.runDenial = nil
        host.currentScope = { probe.scope }
        host.bridge = { id, mode in HTMLEmbedBridge(segmentId: id.segmentId, snapshot: mode == .interactive ? #"{"v":1,"lastId":2}"# : nil) }
        host.execute = { _, _ in .success(false) }
        host.slash = CardSlashHost(
            card: { probe.hasCard ? CardSlashGate.Card(id: "c1", name: "白石", consent: probe.consent, allowed: true) : nil },
            names: { ("岚", "阿禾") },
            isGenerating: { probe.generating },
            confirm: { c, done in probe.confirms.append(c); probe.pending = done },
            setConsent: { _, consent in probe.consent = consent },
            perform: { step in probe.performed.append(step); return nil })
        host.replaceSources([(identity, "<p>面板</p>"), (HTMLEmbedIdentity(profileId: "p", conversationId: "c", nodeId: "n4", segmentId: "h0"), "<p>新</p>")])
        return host
    }

    private func call(_ host: HTMLEmbedHost, token: String, id: String, _ command: String, node: String = "n2") {
        let args = String(data: try! JSONSerialization.data(withJSONObject: ["command": command]), encoding: .utf8)!
        host.handle(.call(token: token, nodeId: node, segmentId: "h0", callId: id, method: "triggerSlash", args: args))
    }

    func testHostTriggerSlashConfirmOnceAllowDenyAndRejections() throws {
        let probe = SlashProbe()
        let host = makeHost(probe)
        var clock: TimeInterval = 100
        host.now = { clock }
        host.handle(.run(nodeId: "n2", segmentId: "h0"))
        let token = try XCTUnwrap(host.interactive?.token)
        XCTAssertEqual(host.interactive?.origin, .user)

        // unknown → 弹确认；确认期间别的发消息调用被拒
        call(host, token: token, id: "s1", "/send 我推开门|/trigger")
        XCTAssertEqual(probe.confirms, [CardSendConfirmation(cardName: "白石", texts: ["我推开门"], replies: true)])
        XCTAssertTrue(host.awaitingSendConfirm)
        clock = 104
        call(host, token: token, id: "s2", "/send 再来")
        XCTAssertTrue(probe.js.last?.contains(#""id":"s2","ok":false,"error":"上一条还在等你确认""#) == true)
        XCTAssertEqual(probe.performed, [.toast("上一条还在等你确认")], "被拒有轻提示")
        probe.performed = []
        probe.pending?(.once)
        XCTAssertFalse(host.awaitingSendConfirm)
        XCTAssertEqual(probe.performed, [.sendAndReply("我推开门")])
        XCTAssertEqual(probe.consent, .unknown, "只这一次：不记")
        XCTAssertTrue(probe.js.last?.contains(#""id":"s1","ok":true,"value":"""#) == true)

        // 允许并记住 → 写 allowed；之后直接发
        clock = 110
        probe.performed = []
        call(host, token: token, id: "s3", "/send 第二句")
        probe.pending?(.allowAlways)
        XCTAssertEqual(probe.consent, .allowed)
        XCTAssertEqual(probe.performed, [.append("第二句")])
        clock = 114
        probe.performed = []
        let confirmsBefore = probe.confirms.count
        call(host, token: token, id: "s4", "/send 第三句|/trigger")
        XCTAssertEqual(probe.confirms.count, confirmsBefore, "allowed 不再问")
        XCTAssertEqual(probe.performed, [.sendAndReply("第三句")])

        // 3 秒内再点 → 拒
        clock = 115
        probe.performed = []
        call(host, token: token, id: "s5", "/send 太快")
        XCTAssertTrue(probe.js.last?.contains("3 秒内只能发一次") == true)
        XCTAssertEqual(probe.performed, [.toast("点得太快了：同一张卡 3 秒内只能发一次")])

        // 生成中 → 拒
        clock = 130
        probe.generating = true
        probe.performed = []
        call(host, token: token, id: "s6", "/trigger")
        XCTAssertTrue(probe.js.last?.contains("正在生成回复") == true)
        probe.generating = false

        // 不允许（设置里改成 denied）→ 降级填输入框 + 提示
        probe.consent = .denied
        clock = 140
        probe.performed = []
        call(host, token: token, id: "s7", "/send 填进去|/trigger")
        XCTAssertEqual(probe.performed, [.fillInput("填进去"), .toast("「白石」不能替你发消息，要发的话放进了输入框")])

        // 确认框里点「不允许」→ 写 denied、降级
        probe.consent = .unknown
        clock = 150
        probe.performed = []
        call(host, token: token, id: "s8", "/send 不要|/trigger")
        probe.pending?(.deny)
        XCTAssertEqual(probe.consent, .denied)
        XCTAssertEqual(probe.performed, [.fillInput("不要"), .toast("「白石」不能替你发消息，要发的话放进了输入框")])

        // 划掉不选 → 不发、不记；确认期间换了对话 → 不发
        probe.consent = .unknown
        clock = 160
        probe.performed = []
        call(host, token: token, id: "s9", "/send 划掉")
        probe.pending?(nil)
        XCTAssertEqual(probe.performed, [])
        XCTAssertTrue(probe.js.last?.contains(#""error":"没有发送""#) == true)
        clock = 170
        call(host, token: token, id: "s10", "/send 换对话")
        probe.scope = ("p", "other")
        probe.pending?(.allowAlways)
        XCTAssertEqual(probe.performed, [])
        XCTAssertEqual(probe.consent, .unknown)
        XCTAssertTrue(probe.js.last?.contains("对话已经换了，没有发送") == true)
        probe.scope = ("p", "c")

        // 白名单外命令 → 报不支持并记进运行时报告
        call(host, token: token, id: "s11", "/gen 写")
        XCTAssertTrue(probe.js.last?.contains(#""error":"记忆花园暂不支持 \/gen""#) == true, "JSON 里斜杠转义成 \\/")
        XCTAssertTrue(host.runtimeReports["p"]?.unsupportedAPIs.contains("/gen") == true)
        // echo / setinput 照常（不问）
        probe.performed = []
        call(host, token: token, id: "s12", "/echo 嗨|/setinput")
        XCTAssertEqual(probe.performed, [.toast("嗨"), .fillInput("嗨")])
        XCTAssertTrue(probe.js.last?.contains(#""id":"s12","ok":true,"value":"嗨""#) == true)
    }

    func testHostTriggerSlashRejectsNonActiveAndUnpermitted() throws {
        let probe = SlashProbe()
        let host = makeHost(probe)
        probe.consent = .allowed
        // 静态实例：校验链第 2 步就拒（不回包、不执行）
        host.handle(.mount(nodeId: "n2", segmentId: "h0"))
        let staticToken = try XCTUnwrap(host.registry.entries.keys.first)
        call(host, token: staticToken, id: "x1", "/send 静态")
        XCTAssertEqual(probe.performed, [])
        XCTAssertTrue(probe.js.allSatisfy { !$0.contains("x1") })

        host.handle(.run(nodeId: "n2", segmentId: "h0"))
        let first = try XCTUnwrap(host.interactive?.token)
        host.handle(.run(nodeId: "n4", segmentId: "h0"))      // 换成别的段：旧 token 失效
        call(host, token: first, id: "x2", "/send 旧实例")
        XCTAssertEqual(probe.performed, [], "被换掉的实例不能调用")

        let live = try XCTUnwrap(host.interactive?.token)
        host.runDenial = "「白石」的扩展还没启用"
        call(host, token: live, id: "x3", "/send 撤权")
        XCTAssertEqual(probe.performed, [], "未许可的卡：撤权当场销毁，调用被拒")

        host.runDenial = nil
        probe.hasCard = false
        host.handle(.run(nodeId: "n4", segmentId: "h0"))
        call(host, token: try XCTUnwrap(host.interactive?.token), id: "x4", "/send 非卡", node: "n4")
        XCTAssertTrue(probe.js.last?.contains("只有卡聊天里的网页能用 triggerSlash") == true)
        XCTAssertEqual(probe.performed, [])
    }

    // MARK: - B6 自动运行

    private func msg(_ id: String, html: String? = "h0", streaming: Bool = false, assistant: Bool = true) -> CardAutoRun.Message {
        CardAutoRun.Message(nodeId: id, isAssistant: assistant, firstHTMLSegment: html, streaming: streaming)
    }

    func testAutoRunSelectsLatestAndYieldsToManualUntilNewMessage() {
        var s = CardAutoRun.State()
        XCTAssertEqual(CardAutoRun.decide([msg("a1"), msg("u2", assistant: false), msg("a3")], state: &s, enabled: true, interactiveSegmentKey: nil),
                       .run(nodeId: "a3", segmentId: "h0"), "最新一条助手消息的第一个网页段")
        XCTAssertEqual(CardAutoRun.decide([msg("a1"), msg("a3")], state: &s, enabled: true, interactiveSegmentKey: "a3|h0"), .none, "同一条不重复跑")
        XCTAssertEqual(CardAutoRun.decide([msg("a1"), msg("a3")], state: &s, enabled: true, interactiveSegmentKey: "a1|h0"), .none, "手动跑了旧的：留着")
        XCTAssertEqual(CardAutoRun.decide([msg("a1"), msg("a3")], state: &s, enabled: true, interactiveSegmentKey: nil), .none, "收起 / 离屏后同一条不自动拉起")
        XCTAssertEqual(CardAutoRun.decide([msg("a3"), msg("u4", assistant: false)], state: &s, enabled: true, interactiveSegmentKey: "a1|h0"), .none,
                       "你发了一条（最新的助手消息没换）：不动")
        XCTAssertEqual(CardAutoRun.decide([msg("a3"), msg("a5", streaming: true)], state: &s, enabled: true, interactiveSegmentKey: "a1|h0"), .none, "生成中先不动")
        XCTAssertEqual(CardAutoRun.decide([msg("a3"), msg("a5")], state: &s, enabled: true, interactiveSegmentKey: "a1|h0"),
                       .run(nodeId: "a5", segmentId: "h0"), "新消息到：新的接上（旧的随之降回静态）")
        XCTAssertEqual(CardAutoRun.decide([msg("a5"), msg("a6", html: nil)], state: &s, enabled: true, interactiveSegmentKey: "a5|h0"), .stop,
                       "新消息没有网页：旧的降回静态")
        XCTAssertEqual(CardAutoRun.decide([msg("a6", html: nil)], state: &s, enabled: false, interactiveSegmentKey: nil), .none, "未许可 / 总开关关：不跑")
        XCTAssertEqual(s, CardAutoRun.State())
        XCTAssertEqual(CardAutoRun.decide([msg("a5"), msg("a6", html: "h1")], state: &s, enabled: true, interactiveSegmentKey: nil),
                       .run(nodeId: "a6", segmentId: "h1"), "重新允许：最新一条接着跑")
        var fresh = CardAutoRun.State()
        XCTAssertEqual(CardAutoRun.decide([msg("a1", html: nil)], state: &fresh, enabled: true, interactiveSegmentKey: "x|h0"), .none, "第一次看到且没有网页：不动别处")
    }

    func testHostAutoRunOriginAndManualOverride() throws {
        let probe = SlashProbe()
        let host = makeHost(probe)
        host.autoRunEnabled = false
        host.autoRunLatest([msg("n2")])
        XCTAssertNil(host.interactive, "没许可：维持现状")
        host.autoRunEnabled = true
        host.autoRunLatest([msg("n2")])
        XCTAssertEqual(host.interactive?.identity.segmentKey, "n2|h0")
        XCTAssertEqual(host.interactive?.origin, .auto)
        XCTAssertTrue(probe.js.last?.contains(#""mode":"interactive""#) == true)

        host.handle(.run(nodeId: "n4", segmentId: "h0"))     // 手动跑另一条
        XCTAssertEqual(host.interactive?.origin, .user)
        host.autoRunLatest([msg("n2")])
        XCTAssertEqual(host.interactive?.identity.nodeId, "n4", "手动的留到下一条新消息")
        host.autoRunLatest([msg("n2"), msg("n4")])
        XCTAssertEqual(host.interactive?.identity.nodeId, "n4", "新消息正好就是手动跑的那条：不重建")
        XCTAssertEqual(host.registry.entries.values.filter { $0.mode == .interactive }.count, 1, "全应用 1 个交互实例")

        host.runDenial = "关了"
        host.autoRunLatest([msg("n2")])
        XCTAssertNil(host.interactive, "总开关关：不自动跑")
    }

    // MARK: - 本地模式 / picsum / edited

    func testLocalModeCardChatOnlyKeepsBundledLibrary() {
        var allowed = CharacterCard(name: "岚", description: "", personality: "", scenario: "", firstMes: "")
        allowed.extensionConsent = .allowed
        var denied = allowed
        denied.extensionConsent = .deferred
        XCTAssertEqual(HTMLEmbedPermission.network(boundCard: allowed, localMode: true), .cardLocal)
        XCTAssertEqual(HTMLEmbedPermission.network(boundCard: allowed, localMode: false), .card(allowed: true))
        XCTAssertEqual(HTMLEmbedPermission.network(boundCard: denied, localMode: true), .card(allowed: false))
        XCTAssertEqual(HTMLEmbedPermission.network(boundCard: nil, localMode: true), .offline, "非卡：现状")
        for mode in [HTMLEmbedMode.staticView, .interactive] {
            let local = HTMLEmbedPolicy.contentSecurityPolicy(mode, nonce: mode == .staticView ? "n" : nil, network: .cardLocal)
            XCTAssertEqual(local, HTMLEmbedPolicy.contentSecurityPolicy(mode, nonce: mode == .staticView ? "n" : nil, network: .card(allowed: false)),
                           "本地模式 = 只留内置库")
            XCTAssertFalse(local.contains("https://"), local)
            XCTAssertTrue(local.contains("style-src 'unsafe-inline' mp-card:") && local.contains("font-src data: mp-card:"))
        }
        XCTAssertTrue(HTMLEmbedNetwork.cardLocal.isCard)
        XCTAssertEqual(HTMLEmbedNetwork.cardLocal.blockedNote, "本地模式开着，白名单里的也先挡着。")
        XCTAssertEqual(HTMLEmbedNetwork.card(allowed: true).blockedNote, "")

        // 切本地模式：已挂的 iframe 按新 CSP 重挂
        let probe = SlashProbe()
        let host = makeHost(probe)
        host.network = .card(allowed: true)
        host.handle(.mount(nodeId: "n2", segmentId: "h0"))
        let before = try? XCTUnwrap(host.registry.entries.keys.first)
        probe.js = []
        host.network = .cardLocal
        XCTAssertTrue(probe.js.contains { $0.contains("mp.htmlSuspend") } && probe.js.contains { $0.contains("mp.htmlResume") })
        XCTAssertNil(host.registry.entry(before ?? ""), "旧 token 作废")
        host.handle(.mount(nodeId: "n2", segmentId: "h0"))
        let entry = host.registry.entries.values.first
        XCTAssertEqual(entry?.network, .cardLocal)
        XCTAssertFalse(entry?.document.contains("https://i.imgur.com") ?? true)
    }

    func testPicsumRedirectHostWhitelisted() {
        XCTAssertTrue(CardWebWhitelist.image.contains("fastly.picsum.photos"))
        let allowed = HTMLEmbedPolicy.contentSecurityPolicy(.interactive, network: .card(allowed: true))
        XCTAssertTrue(allowed.contains("https://picsum.photos https://fastly.picsum.photos;"), "picsum.photos 302 过去的图床也放")
        XCTAssertTrue(HTMLEmbedPolicy.nativeCardShellPolicy.contains("https://fastly.picsum.photos"))
        XCTAssertFalse(HTMLEmbedPolicy.contentSecurityPolicy(.interactive, network: .card(allowed: false)).contains("picsum"))
        XCTAssertFalse(HTMLEmbedPolicy.contentSecurityPolicy(.interactive, network: .cardLocal).contains("picsum"))
        XCTAssertFalse(allowed.contains("script-src 'unsafe-inline' mp-card: https"), "只放图片")
    }

    func testEditedMarkText() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 1; comps.hour = 21; comps.minute = 36
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(CardEditedText.title(cardName: "白石", at: date), "这条消息被「白石」的网页在 21:36 改过。")
        XCTAssertEqual(CardEditedText.title(cardName: nil, at: date), "这条消息被卡里的网页在 21:36 改过。")
        XCTAssertEqual(CardEditedText.note, "网页只能改这一条和之后的消息。")
        XCTAssertEqual(CardEditedText.label, "edited")
    }
}
