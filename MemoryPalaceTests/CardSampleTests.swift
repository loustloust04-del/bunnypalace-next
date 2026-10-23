import XCTest
@testable import 记忆花园

/// 卡库第二批 B9：示例卡「白石」——首次加载插入（新用户 / 已有用户）、删除 / 归档后不补回、标记挡住插入、
/// 原 PNG / JSON 导出、开场面板用到的 API 都在支持子集里。全部临时目录 / 临时 suite，不碰 app 存储
@MainActor
final class CardSampleTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    /// 仓库里的卡 JSON（app 资源同一份；harness 里 #filePath 指回 worktree 的测试文件）
    private var resource: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MemoryPalace/Resources/SampleCards/\(CardSample.resourceName).json")
    }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("b9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "CardSampleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func manager() -> CharacterCardManager {
        CharacterCardManager(root: dir.appendingPathComponent("blobs"), libraryRoot: dir.appendingPathComponent("cardlibrary"), defaults: defaults)
    }

    private var dismissed: Bool { defaults.bool(forKey: CardLibraryPreferences.sampleCardDismissedKey) }

    func testNewUserGetsSampleOnceWithOriginalPNG() throws {
        let cards = manager()
        cards.insertSampleCardIfNeeded(resource: resource)
        cards.insertSampleCardIfNeeded(resource: resource)
        XCTAssertEqual(cards.cards.map(\.id), [CardSample.id], "只插一次")
        let sample = try XCTUnwrap(manager().cards.first)
        XCTAssertEqual(sample.name, "白石")
        XCTAssertEqual(sample.bindingState, .unbound, "只进卡库，不建楼层")
        XCTAssertEqual(sample.extensionConsent, .unknown)
        XCTAssertEqual(sample.sendConsent, .unknown)
        XCTAssertNotNil(sample.originals.imageFile, "原 PNG 拆到文件")
        XCTAssertNotNil(sample.originals.thumbnail)
        XCTAssertTrue(sample.hasWorldBook)
        XCTAssertEqual(sample.greetings.count, 3)
        XCTAssertTrue(sample.needsExtensionConsent && sample.hasFrontendGreeting, "开场网页：进角色页会看到许可横幅")
        // 没改过：PNG / JSON 都是原字节
        XCTAssertEqual(try TavernCardExport.json(card: sample, edits: nil), try Data(contentsOf: resource))
        let png = try TavernCardExport.png(card: sample, original: sample.imageData, cover: nil, edits: nil)
        XCTAssertFalse(png.rewritten)
        XCTAssertEqual(png.data, sample.imageData)
        XCTAssertEqual(try TavernCard.parsePNG(data: png.data).name, "白石")
        XCTAssertEqual(TavernCardPNGWriter.tavernRead(png.data).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary },
                       try JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? NSDictionary)
    }

    func testExistingUserGetsSampleAppended() throws {
        let cards = manager()
        try cards.add(CharacterCard(name: "岚", description: "", personality: "", scenario: "", firstMes: "你好"))
        cards.insertSampleCardIfNeeded(resource: resource)
        XCTAssertEqual(manager().cards.map(\.name), ["岚", "白石"], "已有用户：原来的卡不动，示例卡加在后面")
    }

    func testDeletedSampleNeverComesBack() throws {
        let cards = manager()
        cards.insertSampleCardIfNeeded(resource: resource)
        try cards.delete(try XCTUnwrap(cards.cards.first))
        XCTAssertTrue(cards.cards.isEmpty)
        XCTAssertTrue(dismissed, "删了就记下")
        cards.insertSampleCardIfNeeded(resource: resource)
        let reopened = manager()
        reopened.insertSampleCardIfNeeded(resource: resource)
        XCTAssertTrue(reopened.cards.isEmpty, "重启后也不补回")
    }

    func testArchivedSampleCountsAsDismissed() throws {
        let cards = manager()
        cards.insertSampleCardIfNeeded(resource: resource)
        var sample = try XCTUnwrap(cards.cards.first)
        sample.bindingState = .active
        sample.linkedProfileId = "p1"
        try cards.update(sample)
        XCTAssertFalse(dismissed, "进过楼层不算删")
        try cards.delete(try XCTUnwrap(cards.cards.first))
        XCTAssertNotNil(cards.cards.first?.archivedAt, "绑着楼层的删除 = 归档")
        XCTAssertTrue(dismissed)
        let reopened = manager()
        reopened.insertSampleCardIfNeeded(resource: resource)
        XCTAssertEqual(reopened.cards.count, 1, "归档的那张还在存储里，不再插第二张")
    }

    func testDismissedFlagBlocksInsertAndOtherCardsDoNotSetIt() throws {
        let cards = manager()
        let other = CharacterCard(name: "岚", description: "", personality: "", scenario: "", firstMes: "")
        try cards.add(other)
        try cards.delete(other)
        XCTAssertFalse(dismissed, "删别的卡不碰标记")
        defaults.set(true, forKey: CardLibraryPreferences.sampleCardDismissedKey)
        cards.insertSampleCardIfNeeded(resource: resource)
        XCTAssertTrue(cards.cards.isEmpty)
        XCTAssertTrue(ConfigSchema.appStorageKeys.contains { $0.key == CardLibraryPreferences.sampleCardDismissedKey }, "标记进设置导出")
    }

    func testSampleEnteredFloorLooksLikeAnyCard() throws {
        let sample = try CardSample.make(json: Data(contentsOf: resource))
        let chat = CharacterFloorService.makeChat(title: sample.name, greetings: sample.greetings, profileId: "p")
        XCTAssertEqual(chat.1.filter { !$0.isSyntheticRoot }.count, 3, "三个开场 = 同一楼三个 swipe")
    }

    /// 开场面板：三类能力都用到，用到的 API / 命令都在本批支持的子集里
    func testOpeningPanelsUseSupportedSubset() throws {
        let sample = try CardSample.make(json: Data(contentsOf: resource))
        XCTAssertTrue(sample.unsupportedFeatures.isEmpty, "静态扫描没有不支持的功能")
        for (i, greeting) in sample.greetings.enumerated() {
            let segments = try XCTUnwrap(MessageHTMLSegments.split(greeting))
            XCTAssertEqual(segments.filter { $0.kind == .html }.count, 1)
            XCTAssertTrue(greeting.contains("swipe_id: Number("), "开场选择器切 swipe")
            XCTAssertTrue(greeting.contains("class=\"chip on\" data-i=\"\(i)\""), "第 \(i + 1) 个开场高亮自己")
            XCTAssertTrue(greeting.contains("getVariables({ type: 'chat' })") && greeting.contains("type: 'message'"), "状态栏读写 chat / message 变量")
            XCTAssertTrue(greeting.contains("triggerSlash('/send '"), "选项按钮替你发消息")
        }
        for say in ["这块石头有什么来历？", "我在你旁边坐下，陪你磨一会儿。"] {
            guard case .success(let plan) = CardSlash.plan("/send \(say)|/trigger", charName: "白石", userName: "你") else {
                return XCTFail("选项命令要能解析")
            }
            XCTAssertEqual(plan.sendTexts, [say])
        }
    }
}
