import MemoryCore
import XCTest
@testable import 记忆花园

// TEST_RUNNER_MP_C3_LIVE_* 由 xcodebuild 转成宿主 MP_C3_LIVE_*；真实 key 只在出站时注入。
@MainActor
final class ALineLiveSmokeTests: XCTestCase {
    private var providers: ProviderManager?
    private var credentialId: String?
    private var modelId = ""
    private let speakers = SessionSegmentWriter.Speakers(userName: "岚舟", assistantName: "星砚")
    private let persona = "这是全虚构的星砚楼。你叫星砚，对方叫岚舟；林栖和雾岚是你们的朋友。"
    private let time = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        guard let value = getenv("MP_C3_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_C3_LIVE_API_KEY，不访问真实端点")
        }
        guard let model = getenv("MP_C3_LIVE_MODEL"), !String(cString: model).isEmpty else {
            throw XCTSkip("必须注入 TEST_RUNNER_MP_C3_LIVE_MODEL，模型不写死")
        }
        modelId = String(cString: model)
        guard modelId.lowercased().contains("haiku") else {
            throw XCTSkip("A 线 live 只跑 Haiku，请注入 TEST_RUNNER_MP_C3_LIVE_MODEL")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "ALineLiveSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 90
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

    func testA2RollingFiveBlockContractLive() async throws {
        try await run(
            system: SessionSegmentWriter.systemPrompt(persona: persona, speakers: speakers, kind: .rolling),
            user: SessionSegmentWriter.userContent(messages: messages(), speakers: speakers, previous: nil, kind: .rolling),
            kind: .summary
        ) { self.a2Problems($0, closeout: false) }
    }

    func testA2CloseoutFiveBlockContractLive() async throws {
        try await run(
            system: SessionSegmentWriter.systemPrompt(persona: persona, speakers: speakers, kind: .closeout),
            user: SessionSegmentWriter.userContent(messages: messages(), speakers: speakers, previous: nil, kind: .closeout),
            kind: .summary
        ) { self.a2Problems($0, closeout: true) }
    }

    func testA3ThreeSegmentsAndRawTailContractLive() async throws {
        let parts = Array(segments().prefix(3))
        try await run(
            system: WindowSummaryWriter.systemPrompt(persona: persona, speakers: speakers, segmentCount: parts.count),
            user: WindowSummaryWriter.userContent(title: "星砚楼远航筹备", segments: parts,
                rawTail: Array(messages().suffix(2)), speakers: speakers),
            kind: .windowSummary
        ) { raw in
            let problems = self.contractProblems(raw, a3: true)
            let output = SessionSegmentWriter.parse(raw)
            print("[ALINE-LIVE] \(self.name) soft: 【走向】\(output.story.count)字，期望≤300字")
            let quotes = [self.speakers.user + "：「", "我：「"].reduce(0) {
                $0 + output.quotes.components(separatedBy: $1).count - 1
            }
            print("[ALINE-LIVE] \(self.name) soft: 【原话】\(quotes)句，期望1句")
            return problems
        }
    }

    func testA3TenSegmentsLeanInputContractLive() async throws {
        let parts = segments()
        try await run(
            system: WindowSummaryWriter.systemPrompt(persona: persona, speakers: speakers, segmentCount: parts.count),
            user: WindowSummaryWriter.userContent(title: "星砚楼远航筹备", segments: parts, rawTail: [], speakers: speakers),
            kind: .windowSummary
        ) { raw in
            let problems = self.contractProblems(raw, a3: true)
            let count = SessionSegmentWriter.parse(raw).story.count
            // 500–800 字档向两端各容忍20%，不要求 Haiku 精确计字。
            print("[ALINE-LIVE] \(self.name) soft: 【走向】\(count)字，期望400–960字")
            return problems
        }
    }

    private func run(system: String, user: String, kind: UsageKind,
                     problems: @escaping @MainActor (String) -> [String]) async throws {
        let (manager, model) = makeProvider()
        let caller = SessionSegmentWriter.modelCaller(model: model, providerManager: manager,
            conversationId: "", profileId: "", kind: kind, checkWriteBudget: false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                var input = user
                for attempt in 1...2 {
                    let raw = try await caller(system, input) ?? ""
                    let failures = problems(raw)
                    print("[ALINE-LIVE] \(self.name) model=\(model.modelId) attempt=\(attempt) problems=\(failures)")
                    print("[ALINE-LIVE-RAW] \(CatalogLiveAuthProtocol.redacted(raw))")
                    if failures.isEmpty { return }
                    if attempt == 2 {
                        XCTFail("两次输出均未满足格式合同：\(failures.joined(separator: "；"))")
                        return
                    }
                    input = user + "\n\n（上次输出未满足格式合同：\(failures.joined(separator: "；"))。按原要求重新输出完整内容。）"
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func contractProblems(_ raw: String, a3: Bool) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        var problems: [String] = []
        if !firstLine.hasPrefix("标题：") { problems.append("第一行必须为「标题：」") }
        let title = firstLine.dropFirst(3).trimmingCharacters(in: .whitespaces)
        if title.isEmpty || title.count > (a3 ? 20 : 15) { problems.append("标题为空或超长") }
        let marks = SessionSummaryStore.lineLayerMarks(text).map(\.mark)
        let required = a3 ? ["【走向】", "【原话】", "【关键词】"] : ["【经过】", "【原话】", "【关键词】", "【待续】"]
        for mark in required where !marks.contains(mark) { problems.append("缺少行首\(mark)") }
        let output = SessionSegmentWriter.parse(text)
        if output.keywords.count > (a3 ? 10 : 5) { problems.append("关键词超量") }
        if text.contains("用户") { problems.append("出现「用户」") }
        return problems
    }

    private func a2Problems(_ raw: String, closeout: Bool) -> [String] {
        let problems = contractProblems(raw, a3: false)
        let output = SessionSegmentWriter.parse(raw)
        if output.pending.isEmpty || output.pending == "无" { print("[ALINE-LIVE] \(name) soft: 【待续】不能为无") }
        if !output.pending.contains("图") && !output.pending.contains("云桥城") { print("[ALINE-LIVE] \(name) soft: 【待续】漏了图或云桥城") }
        if closeout && (output.story.hasPrefix("这个窗口") || output.title.hasPrefix("这个窗口")) {
            print("[ALINE-LIVE] \(name) soft: 尾段以「这个窗口」重新介绍窗口")
        }
        return problems
    }

    private func makeProvider() -> (ProviderManager, ProviderModel) {
        let id = "xctest-aline-live-\(UUID().uuidString)"
        credentialId = id
        let baseURL = getenv("MP_C3_LIVE_BASE_URL").map { String(cString: $0) } ?? "https://api.anthropic.com/v1"
        let model = ProviderModel(credentialId: id, modelId: modelId, name: modelId)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        providers = manager
        manager.addCredential(APICredential(id: id, name: "星砚楼 A 线 live", emoji: "", type: .anthropic,
            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"], models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        return (manager, model)
    }

    private func messages() -> [SessionSegmentWriter.Message] {
        let lines = [
            "林栖想在星砚楼办茶灯会，我想用青瓷杯。",
            "青瓷杯配银叶茶，雾岚负责把灯挂在露台。",
            "露台风大，纸灯换成琉璃灯，杯子保留青瓷的。",
            "那就用琉璃灯和青瓷杯，林栖准备点心。",
            "茶灯会定在周六傍晚，银叶茶别泡太浓。",
            "定好了，雾岚带琉璃灯，林栖带栗子糕。",
            "换件事，云桥城的航图上，北门那条路被雾挡了。",
            "可以让林栖核对河岸标记，雾岚熟悉东门。",
            "先选东门，北门等看清航图再定。",
            "我把东门路线标在云桥城航图上，北门暂时不画。",
            "下次把云桥城那张图发我",
            "好，我留着标好东门的那张图，下次发给你。"
        ]
        return lines.enumerated().map { index, text in
            .init(id: "aline-fictional-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                  content: text, date: time.addingTimeInterval(Double(index * 60)))
        }
    }

    private func segments() -> [SessionSegment] {
        let rows: [(title: String, story: String, quote: String, keywords: [String])] = [
            ("定茶灯会", "岚舟和我把星砚楼茶灯会定在周六，青瓷杯配银叶茶，露台纸灯改琉璃灯。",
             "岚舟：「茶灯会定在周六傍晚，银叶茶别泡太浓。」", ["星砚楼", "青瓷杯", "银叶茶"]),
            ("航图改走东门", "话题从茶灯会转到云桥城航图；北门浓雾未散，岚舟先选东门，我负责标路线。",
             "岚舟：「先选东门，北门等看清航图再定。」", ["云桥城", "航图", "东门"]),
            ("核对渡口水位", "林栖送来旧航图，东门渡口水位与纸上不同。岚舟放弃直接渡河，改找上游石桥。",
             "我：「渡口水位变了，旧航图不能照着走，林栖会把上游石桥重新标出来。」", ["林栖", "渡口", "石桥"]),
            ("改用银叶罗盘", "雾岚试出雾中磁针偏转，岚舟取消夜航，用银叶罗盘和岸边钟楼共同定位，出发推到晨光后。",
             "岚舟：「不赶夜路，银叶罗盘也要和钟楼对一遍，晨光出来再出发。」", ["雾岚", "银叶罗盘", "钟楼"]),
            ("分船运琉璃灯", "原本只运航图，林栖提出把茶灯会的琉璃灯送到云桥城。岚舟改为两艘船，一艘载灯，一艘探路。",
             "我：「灯和探路的人别挤在一艘船，林栖带灯留后面，我先看河道。」", ["琉璃灯", "双船", "河道"]),
            ("码头会合改桥头", "雾岚发现东门码头在修，原定两船会合点不可用。岚舟把会合点移到石桥南端，取消码头卸货。",
             "岚舟：「码头不能靠就不赌，雾岚去石桥南端等，两艘船都按新会合点走。」", ["码头", "石桥南端", "会合点"]),
            ("云纹箱换防潮套", "航图箱漏水，岚舟不再让林栖随船携原图，改留原图在星砚楼，只带防潮套里的摹本。",
             "我：「原图留在星砚楼，云纹箱只装摹本，防潮套破了还有一份底稿。」", ["云纹箱", "防潮套", "摹本"]),
            ("茶灯会改迎航", "筹备从赶路转为迎接返航。岚舟把周六茶灯会移到石桥边，青瓷杯不出楼，改用木杯避免磕损。",
             "岚舟：「这次不在露台等，茶灯会搬到石桥边，青瓷杯留楼里，木杯带过去。」", ["茶灯会", "木杯", "返航"]),
            ("发现旧灯塔暗号", "雾岚认出旧灯塔闪光不是险情而是林栖的报平安暗号，岚舟撤掉绕远路线，恢复沿河直达。",
             "我：「旧灯塔连闪三下是林栖报平安，不是求救，沿河的直路可以恢复。」", ["旧灯塔", "暗号", "沿河路线"]),
            ("定晨航与迎灯", "出发路线、水位和会合点都定下；岚舟让林栖带防潮摹本，雾岚守石桥，我先探路，茶灯会改迎两船返航。",
             "岚舟：「晨光后出发，林栖护好摹本，雾岚在石桥等，回来就在桥边点琉璃灯。」", ["晨航", "石桥", "迎灯"])
        ]
        return rows.enumerated().map { index, row in
            SessionSegment(kind: .rolling, title: row.title,
                start: time.addingTimeInterval(Double(index * 720)), end: time.addingTimeInterval(Double(index * 720 + 660)),
                from: index * 12, to: (index + 1) * 12, lastNodeId: "aline-segment-\(index)",
                story: row.story, quotes: row.quote, pending: "", keywords: row.keywords, format: 2)
        }
    }
}
