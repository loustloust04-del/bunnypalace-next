import XCTest
@testable import 记忆花园

/// 报错「去改」识别（plan-api-draft-and-fix-jump §5-2）。输入都从真生成方拿（failureMessage / classify / 本地报错函数），防文案漂移
final class FixJumpTests: XCTestCase {
    private static var dir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/param-errors")
    }

    private func sample(_ name: String) throws -> String {
        try String(contentsOf: Self.dir.appendingPathComponent(name), encoding: .utf8)
    }

    private let sent = ParamErrorClassifier.SentShape(body: [
        "model": "m", "messages": [], "stream": true, "temperature": 0.7, "top_p": 0.95, "max_tokens": 16384,
    ])

    private func failure(_ body: String, status: Int, sent: ParamErrorClassifier.SentShape? = nil,
                         learned: ParamCompat.Learned = .init()) -> String {
        ProviderRouter.failureMessage("原文", status: status, host: "relay.example.com", modelId: "m", cap: nil, sent: sent ?? self.sent,
                                      errorBody: body, providerType: .openaiCompatible, learnedNow: learned)
    }

    func testHTTPStatusKinds() {
        XCTAssertEqual(FixJump.kind(for: failure("{}", status: 401)), .badKey)
        XCTAssertEqual(FixJump.kind(for: failure("{}", status: 403)), .badKey)
        XCTAssertEqual(FixJump.kind(for: failure("{}", status: 404)), .badURL)
        XCTAssertNil(FixJump.kind(for: failure("{}", status: 429)), "429 不出按钮")
        XCTAssertNil(FixJump.kind(for: failure("{}", status: 500)), "5xx 不出按钮")
        XCTAssertNil(FixJump.kind(for: failure("{}", status: 0)), "网络错不出按钮")
        XCTAssertNil(FixJump.kind(for: failure("{}", status: 400)), "认不出的 400 不出按钮")
    }

    func testLocalErrorKinds() {
        XCTAssertEqual(FixJump.kind(for: FixJump.noKeyMessage("我的中转")), .badKey)
        XCTAssertEqual(FixJump.kind(for: FixJump.missingProviderMessage("cred-x")), .cardMissing)
        XCTAssertEqual(FixJump.kind(for: FixJump.unsupportedCardMessage("futureType")), .cardMissing)
        XCTAssertEqual(FixJump.kind(for: FixJump.budgetPreflightMessage), .budget)
    }

    func testClassifierExplainKinds() throws {
        XCTAssertEqual(FixJump.kind(for: failure(try sample("anthropic-prefill.json"), status: 400)), .prefill)

        var effort = sent
        effort.keys.insert("reasoning_effort")
        effort.values["reasoning_effort"] = "none"
        XCTAssertEqual(FixJump.kind(for: failure(try sample("reasoning-effort-none.json"), status: 400, sent: effort)), .reasoning)

        var hot = sent
        hot.values["temperature"] = "3.0"
        XCTAssertEqual(FixJump.kind(for: failure(try sample("loc-value-error.json"), status: 422, sent: hot)), .samplingValue)
    }

    func testLearnedAndPriority() throws {
        let learned = ParamCompat.Learned(groups: [ParamCompat.Group.sampling])
        XCTAssertEqual(FixJump.kind(for: failure(try sample("openai-temperature-unsupported-value.json"), status: 400, learned: learned)), .learned)
        XCTAssertEqual(FixJump.kind(for: failure("{}", status: 401, learned: learned)), .badKey, "已记住 + 401：这次失败的原因是 401")
        XCTAssertEqual(FixJump.Kind.learned.buttonTitle, "去看")
        XCTAssertEqual(FixJump.Kind.badKey.buttonTitle, "去改")
    }

    func testOtherErrorsHaveNoButton() {
        XCTAssertNil(FixJump.kind(for: "当轮回传的思考块没被接受（多半是中转改了请求）。原文：x"))
        XCTAssertNil(FixJump.kind(for: "The request timed out."))
    }

    /// 只对 ⚠️ 标记拆出来的报错跑：普通正文提到「保险闸」不出按钮
    func testOnlyMarkedErrorsCount() {
        XCTAssertNil(ChatSystemMessage.split("预算保险闸是个好东西").error)
        let marked = ChatSystemMessage.split("半截正文\n\n⚠️ " + FixJump.budgetPreflightMessage).error
        XCTAssertEqual(marked.flatMap(FixJump.kind(for:)), .budget)
    }

    func testParsing() {
        XCTAssertEqual(FixJump.cardName(inNoKeyError: FixJump.noKeyMessage("我的 中转")), "我的 中转")
        XCTAssertEqual(FixJump.host(inTail: failure("{}", status: 401)), "relay.example.com")
        XCTAssertNil(FixJump.host(inTail: "没尾巴"))
    }

    func testCredentialLookupNeverOpensWrongCard() {
        func card(_ id: String, _ name: String, _ url: String) -> APICredential {
            APICredential(id: id, name: name, emoji: "🔑", presetId: nil, type: .openaiCompatible, baseURL: url, extraHeaders: [:], models: [])
        }
        let a = card("cred-a", "甲", "https://relay.example.com/v1")
        let b = card("cred-b", "乙", "https://other.example.com/v1")
        let tail = failure("{}", status: 401)
        XCTAssertEqual(FixJump.credentialId(ledgerProviderId: "cred-b", errorText: tail, credentials: [a, b]), "cred-b", "账本记的卡还在 → 就是它")
        // astra #8：账本明确记的卡已删，不再按 host 猜成同 host 的另一张
        let a2 = card("cred-a2", "甲2", "https://relay.example.com/v1")
        XCTAssertNil(FixJump.credentialId(ledgerProviderId: "cred-gone", errorText: tail, credentials: [a2, b]), "账本里的卡已删 → 只开卡列表")
        XCTAssertEqual(FixJump.credentialId(ledgerProviderId: nil, errorText: FixJump.noKeyMessage("乙"), credentials: [a, b]), "cred-b",
                       "没进账本的本地报错按卡名（唯一）")
        let b2 = card("cred-b2", "乙", "https://third.example.com/v1")
        XCTAssertNil(FixJump.credentialId(ledgerProviderId: nil, errorText: FixJump.noKeyMessage("乙"), credentials: [a, b, b2]), "同名两张 → 卡列表")
        XCTAssertEqual(FixJump.credentialId(ledgerProviderId: nil, errorText: tail, credentials: [a, b]), "cred-a", "host 唯一 → 认")
        XCTAssertNil(FixJump.credentialId(ledgerProviderId: nil, errorText: tail, credentials: [a, a2, b]), "同 host 两张 → 卡列表")
        XCTAssertNil(FixJump.credentialId(ledgerProviderId: nil, errorText: "x", credentials: [a, b]))
    }

    /// plan-model-compat-p0 §7.5：额度 / 超长两类，人话从 failureMessage 拿
    private func failure(_ body: String, status: Int, kind: ChatErrorClassifier.Kind, retried: Int = 0) -> String {
        ProviderRouter.failureMessage("原文", status: status, host: "relay.example.com", modelId: "m", cap: nil, sent: sent,
                                      errorBody: body, providerType: .openaiCompatible, learnedNow: .init(), kind: kind, retried: retried)
    }

    func testQuotaAndContextTooLongKinds() {
        let quota = failure(#"{"error":{"message":"Insufficient Balance"}}"#, status: 402, kind: .quota)
        XCTAssertEqual(FixJump.kind(for: quota), .quota, quota)
        XCTAssertEqual(FixJump.Kind.quota.buttonTitle, "去看")
        let long = failure(#"{"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#, status: 400, kind: .contextTooLong)
        XCTAssertEqual(FixJump.kind(for: long), .contextTooLong, long)
        XCTAssertTrue(long.contains("上下文深度"), long)
        XCTAssertEqual(FixJump.Kind.contextTooLong.buttonTitle, "去改")
    }

    func testNewKindsDoNotStealKeyOrURL() {
        XCTAssertEqual(FixJump.kind(for: failure("{}", status: 401, kind: .quota)), .badKey, "401 带欠费词也先算 key")
        XCTAssertEqual(FixJump.kind(for: failure("{}", status: 403, kind: .contextTooLong)), .badKey)
        XCTAssertEqual(FixJump.kind(for: failure("{}", status: 404, kind: .quota)), .badURL)
    }

    func testRetryableKindsHaveNoButton() {
        let transient = failure("{}", status: 503, kind: .transient, retried: 2)
        XCTAssertTrue(transient.hasPrefix("服务器暂时出问题，已自动重试 2 次还是不行"), transient)
        XCTAssertNil(FixJump.kind(for: transient))
        let limited = failure("{}", status: 429, kind: .rateLimited(retryAfter: 30))
        XCTAssertTrue(limited.hasPrefix("被限流了，大约 30 秒后再发"), limited)
        XCTAssertNil(FixJump.kind(for: limited))
        XCTAssertNil(FixJump.kind(for: failure("{}", status: 400, kind: .contentFiltered)))
    }

    func testLedgerLookupByNode() async {
        var r = UsageRecord(time: Date(), providerId: "cred-ledger-\(UUID().uuidString)", providerName: "", providerType: "openaiCompatible",
                            model: "m", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0, durationMs: 0, status: .error,
                            kind: .chat, conversationId: nil, profileId: nil, subscription: false, tokensOnly: false)
        let node = "node-\(UUID().uuidString)"
        r.messageNodeId = node
        UsageLedger.shared.append(r)   // 测试宿主写临时账本
        let found = await FixJump.ledgerProviderId(nodeId: node)
        XCTAssertEqual(found, r.providerId)
        let none = await FixJump.ledgerProviderId(nodeId: "node-none")
        XCTAssertNil(none)
    }
}
