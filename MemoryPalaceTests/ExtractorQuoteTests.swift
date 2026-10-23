import XCTest
import SwiftData
@testable import 记忆花园

/// SC-B2 提取器改造特征测试：quote 机械校验 / 解析带 quote / supersede 软失效 / 钉住保护。
final class ExtractorQuoteTests: XCTestCase {

    let pid = "xctest-extractor"
    var container: ModelContainer!
    var context: ModelContext!
    let store = SwiftDataMemoryStore()

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Memory.self, configurations: config)
        context = ModelContext(container)
        UserDefaults.standard.removeObject(forKey: "mem_supersede_soft")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "mem_supersede_soft")
        container = nil
        super.tearDown()
    }

    private var window: [(id: String, role: String, content: String)] {
        [
            (id: "n1", role: "user", content: "我最近养了一只橘猫，名字叫年糕，特别黏人"),
            (id: "n2", role: "assistant", content: "年糕这个名字好可爱！"),
            (id: "n3", role: "user", content: "对了我下个月要搬去杭州工作了"),
        ]
    }

    private var windowText: String { window.map(\.content).joined(separator: "\n") }

    // MARK: - 机械校验纯函数

    func testValidQuotePasses() {
        XCTAssertTrue(MemoryExtractor.validateQuote("养了一只橘猫，名字叫年糕", windowText: windowText))
    }

    func testWhitespaceDifferenceStillPasses() {
        // norm 去空白后匹配（模型常吐多余空格）
        XCTAssertTrue(MemoryExtractor.validateQuote("养了一只橘猫， 名字叫 年糕", windowText: windowText))
    }

    func testTooShortQuoteRejected() {
        XCTAssertFalse(MemoryExtractor.validateQuote("橘猫年糕", windowText: windowText), "norm 后 <8 字拒绝")
    }

    func testParaphrasedQuoteRejected() {
        XCTAssertFalse(MemoryExtractor.validateQuote("用户养了一只叫年糕的橘色猫咪", windowText: windowText), "改写不是逐字，拒绝")
    }

    func testNilQuoteRejected() {
        XCTAssertFalse(MemoryExtractor.validateQuote(nil, windowText: windowText))
    }

    func testLocateQuoteFindsMessage() {
        XCTAssertEqual(MemoryExtractor.locateQuote("下个月要搬去杭州", in: window), "n3")
        XCTAssertNil(MemoryExtractor.locateQuote("完全不存在的话", in: window))
    }

    // MARK: - 解析带 quote

    func testParseActionsReadsQuote() {
        let json = """
        {"actions": [
          {"type": "add", "content": "用户养了橘猫年糕", "category": "fact", "keywords": ["猫"], "quote": "养了一只橘猫，名字叫年糕"},
          {"type": "add", "content": "无出处条目", "category": "fact", "keywords": []}
        ]}
        """
        let actions = MemoryExtractor.parseActions(json)
        XCTAssertEqual(actions.count, 2)
        if case .add(_, _, _, let quote) = actions[0] {
            XCTAssertEqual(quote, "养了一只橘猫，名字叫年糕")
        } else { XCTFail("第一条应为 add") }
        if case .add(_, _, _, let quote) = actions[1] {
            XCTAssertNil(quote)
        } else { XCTFail("第二条应为 add") }
    }

    // MARK: - executeActions：quote 拦截与锚定

    func testAddWithoutValidQuoteBlocked() throws {
        let actions: [MemoryAction] = [
            .add(content: "无出处的记忆", category: "fact", keywords: [], quote: nil),
            .add(content: "改写出处的记忆", category: "fact", keywords: [], quote: "完全编造的引用内容啊"),
        ]
        try MemoryExtractor.executeActions(actions, store: store, profileId: pid,
                                           extractedBy: "test", sourceConversationId: nil,
                                           recentMessages: window, context: context)
        XCTAssertEqual(store.listAll(profileId: pid, context: context).count, 0, "quoteRequiredForAdd=true 时无效 quote 整条拦截")
    }

    func testAddWithValidQuoteStoresAnchor() throws {
        let actions: [MemoryAction] = [
            .add(content: "用户要搬去杭州工作", category: "context", keywords: ["杭州"], quote: "下个月要搬去杭州工作"),
        ]
        try MemoryExtractor.executeActions(actions, store: store, profileId: pid,
                                           extractedBy: "test", sourceConversationId: "conv1",
                                           recentMessages: window, context: context)
        let all = store.listAll(profileId: pid, context: context)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].sourceQuote, "下个月要搬去杭州工作")
        XCTAssertEqual(all[0].sourceNodeId, "n3")
    }

    // MARK: - supersede 软失效

    func testDeleteBecomesSupersedeWhenFlagOn() throws {
        let mem = try store.add(content: "用户喝乌龙茶", category: "preference", keywords: [],
                                profileId: pid, isUserExplicit: false, extractedBy: "test",
                                sourceConversationId: nil, context: context)
        try MemoryExtractor.executeActions([.delete(id: mem.id)], store: store, profileId: pid,
                                           extractedBy: "test", sourceConversationId: nil,
                                           recentMessages: [], context: context)
        let all = store.listAll(profileId: pid, context: context)
        XCTAssertEqual(all.count, 1, "软失效：出排名不出库")
        XCTAssertNotNil(all[0].supersededAt)
        XCTAssertTrue(store.listHot(profileId: pid, context: context).isEmpty, "listHot 过滤已失效")
        XCTAssertTrue(store.listHotAndWarm(profileId: pid, context: context).isEmpty, "listHotAndWarm 过滤已失效")
    }

    /// 记忆修复第一刀：mem_supersede_soft 只管做梦毕业，AI 的删除永远软失效（此前这条测的是旧行为「关 = 物理删除」，第一刀漏改）
    func testDeleteStaysSoftEvenWhenFlagOff() throws {
        UserDefaults.standard.set(false, forKey: "mem_supersede_soft")
        let mem = try store.add(content: "用户喝乌龙茶", category: "preference", keywords: [],
                                profileId: pid, isUserExplicit: false, extractedBy: "test",
                                sourceConversationId: nil, context: context)
        try MemoryExtractor.executeActions([.delete(id: mem.id)], store: store, profileId: pid,
                                           extractedBy: "test", sourceConversationId: nil,
                                           recentMessages: [], context: context)
        let all = store.listAll(profileId: pid, context: context)
        XCTAssertEqual(all.count, 1, "开关关也不真删")
        XCTAssertNotNil(all.first?.supersededAt)
    }

    func testPinnedMemoryRefusesSupersedeAndDelete() throws {
        let mem = try store.add(content: "钉住的重要记忆", category: "fact", keywords: [],
                                profileId: pid, isUserExplicit: true, extractedBy: "test",
                                sourceConversationId: nil, context: context)
        // 软模式
        try MemoryExtractor.executeActions([.delete(id: mem.id)], store: store, profileId: pid,
                                           extractedBy: "test", sourceConversationId: nil,
                                           recentMessages: [], context: context)
        XCTAssertNil(store.listAll(profileId: pid, context: context).first?.supersededAt, "钉住拒失效")
        // 硬模式
        UserDefaults.standard.set(false, forKey: "mem_supersede_soft")
        try MemoryExtractor.executeActions([.delete(id: mem.id)], store: store, profileId: pid,
                                           extractedBy: "test", sourceConversationId: nil,
                                           recentMessages: [], context: context)
        XCTAssertEqual(store.listAll(profileId: pid, context: context).count, 1, "钉住拒物理删除")
    }

    func testSupersededExcludedFromExtractorCandidates() throws {
        // 已失效不再喂提取器（listHotAndWarm 是提取器的"当前记忆"来源），防反复 delete 同一条
        let mem = try store.add(content: "旧偏好", category: "preference", keywords: [],
                                profileId: pid, isUserExplicit: false, extractedBy: "test",
                                sourceConversationId: nil, context: context)
        try store.supersede(id: mem.id, context: context)
        XCTAssertTrue(store.listHotAndWarm(profileId: pid, context: context).isEmpty)
    }

    // MARK: - 写时近似去重（paramecium sim>0.75）

    private func memoryWithVector(_ content: String, _ vector: [Float], revision: Int = 7,
                                  superseded: Bool = false) -> Memory {
        let m = Memory(content: content, category: "fact", keywords: [], profileId: pid)
        m.embeddingData = MemoryVector.data(from: vector)
        m.embeddingRevision = revision
        if superseded { m.supersededAt = Date() }
        return m
    }

    func testNearDuplicateFoundAboveThreshold() {
        let old = memoryWithVector("用户喜欢暖奶白配色", [1, 0, 0])
        // 新向量与旧向量夹角小（点积 0.95 > 0.75）
        let hit = MemoryExtractor.findNearDuplicate(vector: [0.95, 0.312, 0], revision: 7, in: [old])
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.content, "用户喜欢暖奶白配色")
    }

    func testDissimilarNotDuplicate() {
        let old = memoryWithVector("用户喜欢暖奶白配色", [1, 0, 0])
        XCTAssertNil(MemoryExtractor.findNearDuplicate(vector: [0, 1, 0], revision: 7, in: [old]), "正交向量不算重复")
    }

    func testSupersededExcludedFromDedup() {
        // 矛盾更新场景：被失效的旧版本不许吸收新事实（否则 supersede 被去重打穿）
        let old = memoryWithVector("用户爱喝乌龙茶", [1, 0, 0], superseded: true)
        XCTAssertNil(MemoryExtractor.findNearDuplicate(vector: [0.99, 0.141, 0], revision: 7, in: [old]))
    }

    func testRevisionMismatchExcluded() {
        // 模型升级后旧向量不在同一空间，不比对
        let old = memoryWithVector("用户喜欢暖奶白配色", [1, 0, 0], revision: 3)
        XCTAssertNil(MemoryExtractor.findNearDuplicate(vector: [1, 0, 0], revision: 7, in: [old]))
    }

    func testDeleteOrderedBeforeAdd() throws {
        // delete旧+add新 同批：delete 必须先执行（软失效后新事实不被旧条吸收）
        let mem = try store.add(content: "用户爱喝乌龙茶", category: "preference", keywords: [],
                                profileId: pid, isUserExplicit: false, extractedBy: "test",
                                sourceConversationId: nil, context: context)
        // 给旧条造一个与任何文本都"近似"的场景不可行（embed 在测试机可能未就绪），
        // 这里验证执行序本身：add 在前 delete 在后的输入，执行后旧条已失效且新条存在
        let actions: [MemoryAction] = [
            .add(content: "用户现在喝茉莉奶绿", category: "preference", keywords: [], quote: "我现在喝茉莉奶绿啦"),
            .delete(id: mem.id),
        ]
        try MemoryExtractor.executeActions(actions, store: store, profileId: pid,
                                           extractedBy: "test", sourceConversationId: nil,
                                           recentMessages: [(id: "n1", role: "user", content: "我现在喝茉莉奶绿啦")],
                                           context: context)
        let all = store.listAll(profileId: pid, context: context)
        XCTAssertNotNil(all.first(where: { $0.content == "用户爱喝乌龙茶" })?.supersededAt, "旧条被失效")
        XCTAssertNotNil(all.first(where: { $0.content == "用户现在喝茉莉奶绿" }), "新条正常入库")
    }

    // MARK: - update 出处语义

    func testUpdateKeepsQuoteWhenNoNewQuote() throws {
        let mem = try store.add(content: "旧内容", category: "fact", keywords: [],
                                profileId: pid, isUserExplicit: false, extractedBy: "test",
                                sourceConversationId: nil, sourceQuote: "原始出处引用片段啊", sourceNodeId: "n9",
                                context: context)
        try MemoryExtractor.executeActions(
            [.update(id: mem.id, content: "新内容", keywords: [], quote: nil)],
            store: store, profileId: pid, extractedBy: "test", sourceConversationId: nil,
            recentMessages: window, context: context)
        let m = store.listAll(profileId: pid, context: context)[0]
        XCTAssertEqual(m.content, "新内容")
        XCTAssertEqual(m.sourceQuote, "原始出处引用片段啊", "无新 quote 时保留原始出处")
        XCTAssertEqual(m.sourceNodeId, "n9")
    }
}
