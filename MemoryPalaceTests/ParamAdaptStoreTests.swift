import XCTest
@testable import 记忆花园

/// #094 记忆表（plan-param-autoadapt §4.3）：读写 / 清单条 / 全清 / 键规范化 / 200 条上限 / 隔离 suite
final class ParamAdaptStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "xctest.paramAdapt.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let sampling = ParamCompat.Learned(groups: [ParamCompat.Group.sampling])

    func testLearnReadRemoveAndPersist() {
        let store = ParamAdaptStore(defaults: defaults)
        XCTAssertNil(store.entry(providerType: .openaiCompatible, baseURL: "https://relay.example.com/v1", modelId: "gpt-5"))
        store.learn(providerType: .openaiCompatible, baseURL: "https://Relay.Example.com/v1/", modelId: "GPT-5", adding: sampling, rawError: String(repeating: "x", count: 500))
        let hit = store.entry(providerType: .openaiCompatible, baseURL: "https://relay.example.com/v1", modelId: "gpt-5")
        XCTAssertEqual(hit?.learned.groups, [ParamCompat.Group.sampling], "大小写、尾 / 不影响")
        XCTAssertEqual(hit?.rawError.count, 300)
        XCTAssertNil(store.entry(providerType: .openaiCompatible, baseURL: "https://other.example.com/v1", modelId: "gpt-5"), "别的地址不共享")

        store.learn(providerType: .openaiCompatible, baseURL: "https://relay.example.com/v1", modelId: "gpt-5",
                    adding: .init(groups: [ParamCompat.Group.seed], maxTokensKey: "max_completion_tokens"), rawError: "e2")
        let merged = store.entry(providerType: .openaiCompatible, baseURL: "https://relay.example.com/v1", modelId: "gpt-5")
        XCTAssertEqual(merged?.learned.groups, [ParamCompat.Group.sampling, ParamCompat.Group.seed], "组取并集")
        XCTAssertEqual(merged?.learned.maxTokensKey, "max_completion_tokens")
        XCTAssertEqual(merged?.summary, "不发 temperature、top_p、seed · 改用 max_completion_tokens")

        let reopened = ParamAdaptStore(defaults: defaults)
        XCTAssertEqual(reopened.entry(providerType: .openaiCompatible, baseURL: "https://relay.example.com/v1", modelId: "gpt-5")?.learned, merged?.learned, "落盘")

        store.learn(providerType: .openaiCompatible, baseURL: "https://b.example.com", modelId: "m", adding: sampling, rawError: "")
        XCTAssertEqual(store.all.count, 2)
        store.remove(key: ParamAdaptStore.key(providerType: .openaiCompatible, baseURL: "https://b.example.com", modelId: "m"))
        XCTAssertEqual(store.all.count, 1)
        store.removeAll()
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertNil(defaults.data(forKey: ParamAdaptStore.defaultsKey))
    }

    func testEmptyDeltaWritesNothing() {
        let store = ParamAdaptStore(defaults: defaults)
        store.learn(providerType: .openaiCompatible, baseURL: "https://a.example.com", modelId: "m", adding: .init(), rawError: "x")
        XCTAssertTrue(store.all.isEmpty)
    }

    func testCapEvictsOldest() {
        let store = ParamAdaptStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(ParamAdaptStore.limit + 5) {
            store.learn(providerType: .openaiCompatible, baseURL: "https://a.example.com", modelId: "m\(i)", adding: sampling, rawError: "",
                        now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(store.all.count, ParamAdaptStore.limit)
        XCTAssertNil(store.entry(providerType: .openaiCompatible, baseURL: "https://a.example.com", modelId: "m0"))
        XCTAssertNil(store.entry(providerType: .openaiCompatible, baseURL: "https://a.example.com", modelId: "m4"))
        XCTAssertNotNil(store.entry(providerType: .openaiCompatible, baseURL: "https://a.example.com", modelId: "m5"))
        XCTAssertEqual(store.all.first?.entry.modelId, "m\(ParamAdaptStore.limit + 4)", "新的在前")
    }

    func testResolveReadsStoreFirst() {
        let store = ParamAdaptStore(defaults: defaults)
        let base = "https://relay.example.com/v1"
        XCTAssertTrue(ParamCompat.resolve(providerType: .openaiCompatible, baseURL: base, modelId: "gpt-4o",
                                          reasoningEffort: "auto", store: store).sendsSampling)
        store.learn(providerType: .openaiCompatible, baseURL: base, modelId: "gpt-4o", adding: sampling, rawError: "")
        let c = ParamCompat.resolve(providerType: .openaiCompatible, baseURL: base, modelId: "gpt-4o", reasoningEffort: "auto", store: store)
        XCTAssertFalse(c.sendsSampling)
        XCTAssertEqual(c.source, .learned)
    }

    /// astra #6：同一地址、同一模型，OpenAI 兼容口学到的不影响 Anthropic 口；同协议不同 key 仍共享
    func testProviderTypeSeparatesEntries() {
        let store = ParamAdaptStore(defaults: defaults)
        let base = "https://relay.example.com/v1"
        store.learn(providerType: .openaiCompatible, baseURL: base, modelId: "claude-opus-4-7",
                    adding: .init(groups: [ParamCompat.Group.reasoning]), rawError: "")
        XCTAssertNotNil(store.entry(providerType: .openaiCompatible, baseURL: base, modelId: "claude-opus-4-7"))
        XCTAssertNil(store.entry(providerType: .anthropic, baseURL: base, modelId: "claude-opus-4-7"))
        XCTAssertEqual(ParamCompat.resolve(providerType: .anthropic, baseURL: base, modelId: "claude-opus-4-7",
                                           reasoningEffort: "high", store: store).dropped, [])
        XCTAssertEqual(store.all.first?.entry.typeLabel, "OpenAI 兼容")
    }

    /// astra #7：只规范 scheme / host 大小写、去尾 /，路径大小写保留
    func testKeyKeepsPathCase() {
        func key(_ base: String) -> String { ParamAdaptStore.key(providerType: .openaiCompatible, baseURL: base, modelId: "m") }
        XCTAssertEqual(key("HTTPS://Relay.Example/v1/"), key("https://relay.example/v1"))
        XCTAssertNotEqual(key("https://relay.example/TenantA/v1"), key("https://relay.example/tenanta/v1"))
        XCTAssertEqual(ParamAdaptStore.normalizedBase("HTTPS://Relay.Example/TenantA/v1//"), "https://relay.example/TenantA/v1")
    }

    func testSharedStoreIsTestSuiteNotRealDefaults() {
        // 测试宿主把 standard 换成了本工位 suite（TestHostIsolation），shared 用 standard → 不碰粟粟的真偏好
        XCTAssertTrue(TestHostIsolation.active)
        XCTAssertTrue(TestHostIsolation.defaultsSuiteName.contains(".xctest."))
    }
}
