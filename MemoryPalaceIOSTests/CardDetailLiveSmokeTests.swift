import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

// 「详细度」真调模型的冒烟（plan-card-detail-slider §2）：走 app 里那条真路 `CardDetailRewrite.run`——发重写提示词、存记录、记日志，
// 再照详情页的 Save 落到卡上。全虚构的楼层（钟表铺；和提示词里的例子不重名）。
// 只断合同：拿到非空正文、记录落盘（喂了什么回了什么都在）、Save 后字段对。正文写得好不好只打印出来给人看。
// TEST_RUNNER_MP_C3_LIVE_* 由 xcodebuild 转成宿主 MP_C3_LIVE_*；真实 key 只在出站时注入
@MainActor
final class CardDetailLiveSmokeTests: XCTestCase {
    private var providers: ProviderManager?
    private var credentialId: String?
    private var modelId = ""
    private let names = MemoryExtractor.Names(userName: "青禾", assistantName: "小檐")
    private let pid = "live-card-detail-\(UUID().uuidString)"

    override func setUp() async throws {
        guard let value = getenv("MP_C3_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_C3_LIVE_API_KEY，不访问真实端点")
        }
        guard let model = getenv("MP_C3_LIVE_MODEL"), !String(cString: model).isEmpty else {
            throw XCTSkip("必须注入 TEST_RUNNER_MP_C3_LIVE_MODEL，模型不写死")
        }
        modelId = String(cString: model)
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "CardDetailLiveSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 300
        CatalogLiveAuthProtocol.key = String(cString: value)
        try CatalogLiveAuthProtocol.install()
    }

    override func tearDown() async throws {
        if let credentialId { providers?.removeCredential(id: credentialId) }
        providers = nil
        credentialId = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private func makeProvider() -> (ProviderManager, ProviderModel) {
        let id = "xctest-card-detail-live-\(UUID().uuidString)"
        credentialId = id
        let baseURL = getenv("MP_C3_LIVE_BASE_URL").map { String(cString: $0) } ?? "https://api.anthropic.com/v1"
        let model = ProviderModel(credentialId: id, modelId: modelId, name: modelId)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        providers = manager
        manager.addCredential(APICredential(id: id, name: "钟表铺 详细度 live", emoji: "", type: .anthropic,
            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"], models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        return (manager, model)
    }

    /// 一段编的对话：学修旧钟（这条要重写的事）· 小檐的建议她只回了哈哈 · 一句不相干的晚饭 · 后来改了时间
    private func lines() -> [FragmentVerdict.Line] {
        let rows: [(String, String, String)] = [
            ("user", "跟你说个事，上周开始我每周四晚上去梧桐巷那家钟表铺学修旧钟了", "2026-04-09 20:10"),
            ("assistant", "怎么想到去学这个", "2026-04-09 20:11"),
            ("user", "外公留下一座黄铜座钟，停了好多年。老师傅说机芯没坏，就是发条和擒纵轮脏了，让我自己拆着学", "2026-04-09 20:12"),
            ("assistant", "那你可以顺便开个修钟的账号记录过程", "2026-04-09 20:13"),
            ("user", "哈哈", "2026-04-09 20:13"),
            ("user", "今天拆到第三层齿轮，手抖得不行。我说「我这辈子没这么小心过」，老师傅笑了半天", "2026-04-09 20:15"),
            ("assistant", "慢慢来", "2026-04-09 20:16"),
            ("user", "晚饭吃的馄饨", "2026-04-09 20:20"),
            ("user", "对了，下个月起课改到每周六上午了，老师傅周四要去进货", "2026-04-09 20:25"),
        ]
        return rows.map { FragmentVerdict.Line(role: $0.0, text: $0.1, at: $0.2) }
    }

    func testRewriteBriefAndDetailedLive() async throws {
        let (manager, model) = makeProvider()
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("card-detail-live-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let caller = SessionSegmentWriter.modelCaller(model: model, providerManager: manager, conversationId: "", profileId: "",
                                                      kind: .memory, checkWriteBudget: false)
        for level in [CardDetail.Level.brief, .detailed] {
            let m = Memory(content: "每周四晚上去梧桐巷钟表铺学修旧钟，修的是外公留下的黄铜座钟。", category: "fact", keywords: [],
                           profileId: pid, extractedBy: "live", sourceConversationId: "conv-live-clock")
            m.subject = "青禾"
            m.speaker = "用户自述"
            m.sourceNodeId = "m1"
            m.occurredDay = "2026-04-09"
            m.confidence = 85
            context.insert(m)
            try context.save()
            let material = CardDetail.Material(windowTitle: "修钟", names: names, subject: m.subject, content: m.content,
                                               lines: lines(), anchor: 1)
            let prepared = CardDetailRewrite.Prepared(card: m.id, conversationId: "conv-live-clock", material: material, source: .segment)

            let began = Date()
            let out = await CardDetailRewrite.run(level, prepared: prepared, model: model.modelId, caller: caller, profileId: pid, memoryRoot: root)
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            let record = CardDetailRecord.load(id: out.recordId, memoryRoot: root)
            print("[CARD-DETAIL-LIVE] \(level.label) · \(model.modelId) · \(ms) ms · 失败=\(out.failure ?? "无") · 重问=\(record?.retried ?? false)")
            print("[CARD-DETAIL-LIVE] \(level.label) 原来：\(material.content)")
            print("[CARD-DETAIL-LIVE] \(level.label) 重写：\(out.text ?? "（没有）")")
            print("[CARD-DETAIL-LIVE] \(level.label) 模型原样回的：\(record?.calls.last?.reply ?? "（没有）")")

            let text = try XCTUnwrap(out.text, "\(level.label)：拿到正文（\(out.failure ?? "")）")
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotNil(record, "\(level.label)：记录落盘")
            XCTAssertEqual(record?.calls.first?.system, CardDetail.system(names: names, level: level))
            XCTAssertEqual(record?.calls.first?.user, CardDetail.user(material, level: level))
            XCTAssertNotNil(record?.calls.last?.reply)
            XCTAssertEqual(record?.text, text)
            XCTAssertNil(m.reviewedAt, "跑完不落库")

            let draft = CardDetailRewrite.Draft(level: level, text: text, sent: material.content, recordId: out.recordId, actor: model.modelId)
            let saved = CardDetailRewrite.save(draft, to: m, context: context)
            XCTAssertNil(saved.error)
            XCTAssertEqual(m.content, text)
            XCTAssertNotNil(m.reviewedAt)
            XCTAssertNil(m.userEditedAt)
            XCTAssertEqual(m.confidence, 85)
            XCTAssertEqual(saved.entry?.actor, model.modelId)
            XCTAssertEqual(saved.entry?.label, CardDetailRewrite.label(level))
            XCTAssertEqual(saved.entry?.dream, out.recordId)
        }
        let states = CardDetailRewrite.states(MemoryAuditLog.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertEqual(Set(states.values.compactMap(\.level)), [.brief, .detailed])
    }
}
