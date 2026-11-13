import XCTest
@testable import 记忆花园

/// plan-model-vision-check §1.1：目录解析 modalities + 三档判断（旁表 > 目录 > 不知道；CC 一律能看）
final class VisionCapabilityTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionCapabilityTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private static let sample = Data(#"""
    {
      "deepseek": {"id": "deepseek", "models": {
        "deepseek-v4-flash": {"id": "deepseek-v4-flash", "name": "Flash", "modalities": {"input": ["text", "image"], "output": ["text"]}},
        "deepseek-v4-pro": {"id": "deepseek-v4-pro", "name": "Pro", "modalities": {"input": ["text"], "output": ["text"]}},
        "deepseek-old": {"id": "deepseek-old", "name": "Old"}
      }}
    }
    """#.utf8)

    private func loadedCatalog() async -> ModelCatalog {
        let data = Self.sample
        let catalog = ModelCatalog(cacheURL: tempDir.appendingPathComponent("model-catalog.json"), fetch: { data })
        await catalog.refreshIfStale(now: Date())
        return catalog
    }

    private func hints() -> ModelHints {
        ModelHints(fileURL: tempDir.appendingPathComponent("model-hints.json"))
    }

    private func model(_ id: String, card: String = "card") -> ProviderModel {
        ProviderModel(credentialId: card, modelId: id, name: id)
    }

    func testParseKeepsInputModalities() throws {
        let models = try ModelCatalog.parse(modelsDevJSON: Self.sample)
        XCTAssertEqual(models.first { $0.id == "deepseek-v4-flash" }?.inputModalities, ["text", "image"])
        XCTAssertEqual(models.first { $0.id == "deepseek-v4-pro" }?.inputModalities, ["text"])
        XCTAssertNil(models.first { $0.id == "deepseek-old" }?.inputModalities, "没标 = 不知道")
    }

    func testOldCacheWithoutFieldDecodesAsUnknown() throws {
        let json = Data(#"{"id":"m","providerId":"p","name":"m","reasoning":false,"reasoningEfforts":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CatalogModel.self, from: json).inputModalities)
    }

    /// 旧缓存（没有看图字段）读进来 → 不等 TTL 就重拉一次
    func testOldCacheWithoutModalitiesRefetchesEarly() async throws {
        let old = Data(#"{"deepseek":{"id":"deepseek","models":{"deepseek-v4-pro":{"id":"deepseek-v4-pro","name":"Pro"}}}}"#.utf8)
        let url = tempDir.appendingPathComponent("model-catalog.json")
        let now = Date()
        await ModelCatalog(cacheURL: url, fetch: { old }).refreshIfStale(now: now)
        let fresh = Self.sample
        let reopened = ModelCatalog(cacheURL: url, fetch: { fresh })
        XCTAssertTrue(reopened.loadCache())
        XCTAssertEqual(VisionCapability.of(model("deepseek-v4-pro"), providerType: .openaiCompatible, hints: hints(), catalog: reopened), .unknown)
        await reopened.refreshIfStale(now: now.addingTimeInterval(60))
        XCTAssertEqual(VisionCapability.of(model("deepseek-v4-pro"), providerType: .openaiCompatible, hints: hints(), catalog: reopened), .no)
    }

    func testCatalogDecides() async {
        let catalog = await loadedCatalog()
        let h = hints()
        XCTAssertEqual(VisionCapability.of(model("deepseek-v4-flash"), providerType: .openaiCompatible, hints: h, catalog: catalog), .yes)
        XCTAssertEqual(VisionCapability.of(model("deepseek-v4-pro"), providerType: .openaiCompatible, hints: h, catalog: catalog), .no)
        XCTAssertEqual(VisionCapability.of(model("deepseek-old"), providerType: .openaiCompatible, hints: h, catalog: catalog), .unknown)
        XCTAssertEqual(VisionCapability.of(model("nobody-knows"), providerType: .openaiCompatible, hints: h, catalog: catalog), .unknown)
    }

    func testCardHintBeatsCatalog() async {
        let catalog = await loadedCatalog()
        let h = hints()
        h.replace(credentialId: "card", with: ["deepseek-v4-pro": ModelHint(contextTokens: nil, inputModalities: ["text", "image"])])
        XCTAssertEqual(VisionCapability.of(model("deepseek-v4-pro"), providerType: .openaiCompatible, hints: h, catalog: catalog), .yes)
        XCTAssertEqual(VisionCapability.of(model("deepseek-v4-pro", card: "other"), providerType: .openaiCompatible, hints: h, catalog: catalog), .no)
    }

    func testCCAlwaysYes() async {
        let catalog = await loadedCatalog()
        XCTAssertEqual(VisionCapability.of(model("deepseek-v4-pro"), providerType: .ccBridge, hints: hints(), catalog: catalog), .yes)
    }
}
