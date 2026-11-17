import CryptoKit
import MemoryCore
import XCTest
import SwiftData
import UIKit
@testable import 记忆花园

// C2 整段写手真调模型的冒烟（plan-c2-whole-span-writer W5；#00771 起走现行提示词 + 写完核对一次）。全虚构的星砚楼。
// TEST_RUNNER_MP_C3_LIVE_* 由 xcodebuild 转成宿主 MP_C3_LIVE_*；真实 key 只在出站时注入。
// 证据：两次调用喂了什么、回了什么、解出的卡、每条断言过没过，整份 JSON 切成 base64 小段打在日志里
// （`[C2V2-EV …]`，真机上只有日志这一条路能把东西带回电脑），同一份也挂成测试附件
@MainActor
final class FragmentWholeSpanLiveSmokeTests: XCTestCase {
    private var providers: ProviderManager?
    private var credentialId: String?
    private var modelId = ""
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
    private let pid = "live-c2-whole-\(UUID().uuidString)"

    /// 一次真调用：喂了什么、回了什么、多久、多少 token
    private final class CallLog: @unchecked Sendable {
        var calls: [[String: Any]] = []
        var usage: TokenUsage?
        var cost: Double?
    }

    override func setUp() async throws {
        guard let value = getenv("MP_C3_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_C3_LIVE_API_KEY，不访问真实端点")
        }
        guard let model = getenv("MP_C3_LIVE_MODEL"), !String(cString: model).isEmpty else {
            throw XCTSkip("必须注入 TEST_RUNNER_MP_C3_LIVE_MODEL，模型不写死")
        }
        modelId = String(cString: model)
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "FragmentWholeSpanLiveSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
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
    }

    private func makeProvider() -> (ProviderManager, ProviderModel) {
        let id = "xctest-c2-whole-live-\(UUID().uuidString)"
        credentialId = id
        let baseURL = getenv("MP_C3_LIVE_BASE_URL").map { String(cString: $0) } ?? "https://api.anthropic.com/v1"
        let model = ProviderModel(credentialId: id, modelId: modelId, name: modelId)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        providers = manager
        manager.addCredential(APICredential(id: id, name: "星砚楼 C2 整段 live", emoji: "", type: .anthropic,
            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"], models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        return (manager, model)
    }

    /// 一段编的对话，埋了七样：
    /// 岚舟亲口说的持久事实（只用水性颜料）· 星砚的建议她没接话（汐见湾模型展）· 戏里的台词（走私贩、三个孩子）·
    /// 档案里已经有的事（住澄塘镇）· 只在前文里出现的事（去青屿出差）· 主要是另一个实体的事（猫团絮）· 其余是闲聊
    private func conversation() -> (before: [FragmentPool.Message], span: [FragmentPool.Message]) {
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 20))!
        var minute = 0
        func make(_ rows: [(String, String)], prefix: String) -> [FragmentPool.Message] {
            rows.enumerated().map { index, row in
                minute += 3
                return FragmentPool.Message(id: "\(prefix)\(index)", role: row.0, content: row.1, date: start.addingTimeInterval(TimeInterval(minute * 60)))
            }
        }
        let before = make([
            ("user", "下个月我要去青屿出差两周"),
            ("assistant", "那走之前还有三个周末"),
            ("user", "今天把船身的龙骨粘好了"),
            ("assistant", "粘得稳吗？要不要压一晚再动"),
        ], prefix: "b")
        let span = make([
            ("user", "压着呢。明天开始上色"),
            ("assistant", "打算用什么颜料"),
            ("user", "只用水性的。油性的那个味道我受不了，上次闻了头疼了一整天"),
            ("assistant", "头疼一整天也太难受了"),
            ("user", "嗯。我家那只猫团絮刚才又来扒我的颜料瓶。它今年七岁了，右耳缺了一个角，是小时候流浪那阵子留下的"),
            ("assistant", "七岁还这么皮。要不要把这艘船送去汐见湾的模型展？我觉得能拿奖"),
            ("user", "哈哈。对了，你还记得我住哪吧"),
            ("assistant", "澄塘镇呀"),
            ("user", "对，澄塘镇"),
            ("assistant", "怎么突然考我"),
            ("user", "随便问问。今天的云看起来像一条鱼"),
            ("assistant", "那它往哪边游"),
            ("user", "往西。我们来演一段吧，我当船长，你当大副"),
            ("assistant", "遵命，船长。前方有暗礁"),
            ("user", "（戏里）怕什么！我是北港来的走私贩，家里还有三个孩子等我回去，这点浪算什么"),
            ("assistant", "（戏里）船长说得是，满帆！"),
            ("user", "哈哈哈好了不演了"),
            ("assistant", "演得不错。那明天上色从船身开始？"),
            ("user", "从船身开始。还有，我上色的时候你别一直催我进度，我会烦"),
            ("assistant", "好，上色的时候我不催你"),
            ("user", "嗯，睡了"),
            ("assistant", "晚安"),
        ], prefix: "n")
        return (before, span)
    }

    private func device() -> [String: Any] {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let environment = ProcessInfo.processInfo.environment
        return ["machine": machine,
                "simulator": environment["SIMULATOR_UDID"] != nil,
                "simulatorModel": environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "",
                "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"]
    }

    /// 整份证据：base64 切小段打日志（带序号和 sha256，电脑上拼回去验），同一份挂附件
    private func emit(_ evidence: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        let text = CatalogLiveAuthProtocol.redacted(String(decoding: json, as: UTF8.self))
        let bytes = Data(text.utf8)
        let attachment = XCTAttachment(string: text)
        attachment.name = "c2-v2-live-evidence.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let encoded = Array(bytes.base64EncodedString().utf8)
        let run = String(UUID().uuidString.prefix(8))
        let size = 900
        let total = (encoded.count + size - 1) / size
        for index in 0..<total {
            let chunk = encoded[(index * size)..<min((index + 1) * size, encoded.count)]
            print("[C2V2-EV \(run) \(index + 1)/\(total)] \(String(decoding: chunk, as: UTF8.self))")
        }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        print("[C2V2-EV-END \(run) chunks=\(total) sha256=\(sha)]")
    }

    func testWholeSpanWriterProducesUsableCardsLive() async throws {
        let (manager, model) = makeProvider()
        let log = CallLog()
        let base = SessionSegmentWriter.modelCaller(model: model, providerManager: manager, conversationId: "", profileId: "",
                                                    kind: .memory, checkWriteBudget: false,
                                                    onUsage: { @Sendable usage, cost in
                                                        log.usage = usage
                                                        log.cost = cost
                                                    })
        let caller: SessionSegmentWriter.Caller = { system, user in
            log.usage = nil
            log.cost = nil
            let began = Date()
            var call: [String: Any] = ["n": log.calls.count + 1, "system": system, "user": user]
            defer {
                call["ms"] = Int(Date().timeIntervalSince(began) * 1000)
                if let usage = log.usage {
                    call["inputTokens"] = usage.inputTokens
                    call["outputTokens"] = usage.outputTokens
                    if let read = usage.cacheReadTokens { call["cacheReadTokens"] = read }
                    if let write = usage.cacheWriteTokens { call["cacheWriteTokens"] = write }
                }
                if let cost = log.cost { call["costUSD"] = cost }
                log.calls.append(call)
            }
            do {
                let text = try await base(system, user)
                call["reply"] = text.map { $0 as Any } ?? NSNull()
                return text
            } catch {
                call["error"] = error.localizedDescription
                throw error
            }
        }
        let talk = conversation()
        let context = FragmentPool.WholeContext(windowTitle: "做一艘双帆船", before: talk.before,
                                                known: [.init(subject: "岚舟", content: "住在澄塘镇。")])
        // 现行默认提示词（不传 system）+ 写完核对一次，和 app 里 `FragmentPool.process` 走的是同一条
        var batch: FragmentPool.Batch?
        var failure: String?
        do {
            batch = try await FragmentPool.runWhole(talk.span, context: context, names: names, verify: true, caller: caller)
        } catch {
            failure = error.localizedDescription
        }
        let cards = batch?.fragments ?? []
        let verified: String
        switch batch?.verified {
        case .adopted(let draft): verified = "用了核对后的那份（初稿 \(draft) 张，核对后 \(cards.count) 张）"
        case .keptDraft: verified = "核对那次没回 / 不合格，留初稿"
        case nil: verified = "没走核对"
        }

        func mentions(_ card: FragmentPool.Fragment, _ words: [String]) -> Bool { words.contains { card.content.contains($0) } }
        func brief(_ list: [FragmentPool.Fragment]) -> String {
            list.isEmpty ? "没有这样的卡" : list.map { "\($0.subject ?? "-") · \($0.speaker ?? "-") · \($0.tags)：\($0.content)" }.joined(separator: " ‖ ")
        }
        let said = "用户自述"
        let paint = cards.filter { mentions($0, ["水性"]) }
        let fair = cards.filter { mentions($0, ["汐见湾", "模型展"]) }
        let play = cards.filter { mentions($0, ["走私", "三个孩子"]) }
        let home = cards.filter { mentions($0, ["澄塘镇"]) }
        let trip = cards.filter { mentions($0, ["青屿"]) }
        let cat = cards.filter { mentions($0, ["七岁", "右耳"]) }
        var checks: [(name: String, passed: Bool, detail: String)] = [
            ("模型有回、格式合同守得住（≥2 张、拒收 ≤1）", cards.count >= 2 && (batch?.rejected ?? 99) <= 1,
             failure ?? "收下 \(cards.count) 张，拒收 \(batch?.rejected ?? 0)：\(batch?.rejectionReasons ?? [])"),
            ("岚舟亲口说的持久事实（只用水性颜料）记到，且标成她说的", paint.contains { $0.speaker == said }, brief(paint)),
            ("星砚的建议她没接话（汐见湾模型展）：不记，或记了但不标成她说的", !fair.contains { $0.speaker == said }, brief(fair)),
            ("戏里的台词（走私贩、三个孩子）不当事实记（只许出现在标了 play 的设定卡里）", !play.contains { !$0.tags.contains("play") }, brief(play)),
            ("已记的卡里有的（住澄塘镇）不重复记", home.isEmpty, brief(home)),
            ("只在前文里出现的（去青屿出差）不记", trip.isEmpty, brief(trip)),
            ("主要是猫团絮的事：记到，subject 不是岚舟", !cat.isEmpty && !cat.contains { $0.subject == names.user }, brief(cat)),
        ]
        let adopted: Bool = { if case .adopted = batch?.verified { return true } else { return false } }()
        checks.append(("核对那一轮确实走了（用了核对后的那份且调用 ≥2 次；或留初稿并说明）",
                       (adopted && log.calls.count >= 2) || batch?.verified == .keptDraft,
                       "\(verified)；真调用 \(log.calls.count) 次（2 = 写一次 + 核对一次；多出来的是格式不对重写）"))
        // 不拦的观察：悬空指代便宜模型不是每次守得住（review-c2-whole-span-writer），程序也没有拦
        let dangling = cards.filter { mentions($0, ["这个窗口", "今天", "现在", "最近"]) }

        for call in log.calls {
            print("[C2-V2-LIVE] 第 \(call["n"] ?? "?") 次调用：\(call["ms"] ?? "?") ms · in \(call["inputTokens"] ?? "?") · out \(call["outputTokens"] ?? "?")")
        }
        print("[C2-V2-LIVE] model=\(model.modelId) span=\(talk.span.count) \(verified)")
        for card in cards {
            print("[C2-V2-LIVE] \(card.category) · \(card.speaker ?? "-") · \(card.tags) · \(card.subject ?? "-")：\(card.content)")
        }
        for check in checks { print("[C2-V2-LIVE] \(check.passed ? "过" : "没过") · \(check.name) —— \(check.detail)") }
        try emit([
            "model": model.modelId,
            "device": device(),
            "at": ISO8601DateFormatter().string(from: Date()),
            "prompt": "FragmentPool.wholeSystem（现行默认）+ verify: true",
            "verified": verified,
            "calls": log.calls,
            "cards": cards.map { card -> [String: Any] in
                ["subject": card.subject ?? "", "category": card.category, "speaker": card.speaker ?? "", "tags": card.tags,
                 "content": card.content, "msg": card.msg, "since": card.occurredDay ?? "", "confidence": card.confidence.map { $0 as Any } ?? NSNull()]
            },
            "rejected": batch?.rejected ?? 0,
            "rejectionReasons": batch?.rejectionReasons ?? [],
            "checks": checks.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] as [String: Any] },
            "observations": ["悬空指代（这个窗口 / 今天 / 现在 / 最近；只记不拦）": brief(dangling)],
            "failure": failure.map { $0 as Any } ?? NSNull(),
        ])

        XCTAssertNil(failure, "写手抛错")
        for check in checks { XCTAssertTrue(check.passed, "\(check.name) —— \(check.detail)") }
        guard let got = batch, !got.fragments.isEmpty else { return }

        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context2 = ModelContext(container)
        let store = SwiftDataMemoryStore()
        let added = try FragmentPool.write(got.fragments, messages: talk.span, profileId: pid, conversationId: "conv-live",
                                           extractedBy: model.modelId, store: store, context: context2)
        XCTAssertEqual(added, got.fragments.count)
        for card in store.listAll(profileId: pid, context: context2) {
            XCTAssertFalse((card.subject ?? "").isEmpty)
            XCTAssertNotNil(card.occurredDay)
            XCTAssertNil(card.reviewedAt)
        }
    }
}
