import MemoryCore
import XCTest
import SwiftData
import ObjectiveC
@testable import 记忆花园

// TEST_RUNNER_MP_C3_LIVE_* 由 xcodebuild 转成宿主进程的 MP_C3_LIVE_*（API_KEY、BASE_URL、MODEL）。
@MainActor
final class CatalogLiveSmokeTests: XCTestCase {
    private var root: URL?
    private var providers: ProviderManager?
    private var credentialId: String?

    override func setUp() async throws {
        guard let value = getenv("MP_C3_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_C3_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "CatalogLiveSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        try CatalogLiveAuthProtocol.install()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-live-\(UUID().uuidString)", isDirectory: true)
        root = directory
        try await Task.detached { try Self.seedFiles(root: directory) }.value
    }

    override func tearDown() async throws {
        RequestBodyTap.handler = nil
        if let credentialId { providers?.removeCredential(id: credentialId) }
        providers = nil
        credentialId = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
        if let root {
            try await Task.detached { try FileManager.default.removeItem(at: root) }.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "模拟数据目录必须删除")
        }
        root = nil
    }

    func testAnthropicTopicProducesProposal() async throws {
        try await run(type: .anthropic, organizeNow: false)
    }

    func testAnthropicOrganizeNowProducesProposal() async throws {
        try await run(type: .anthropic, organizeNow: true)
    }

    func testAnthropicDailyProducesProposal() async throws {
        try await run(type: .anthropic, organizeNow: false, daily: true)
    }

    func testOpenAITopicProducesProposal() async throws {
        try await run(type: .openaiCompatible, organizeNow: false)
    }

    func testAnthropicAssistantDirectionProducesProposal() async throws {
        try await run(type: .anthropic, organizeNow: false, assistant: true)
    }

    func testC2ExtractionContentAndAttributionLive() async throws {
        let defaults = UserDefaults.standard
        let previousPrompt = defaults.object(forKey: FragmentPool.customPromptKey)
        defaults.removeObject(forKey: FragmentPool.customPromptKey)
        defer {
            if let previousPrompt {
                defaults.set(previousPrompt, forKey: FragmentPool.customPromptKey)
            } else {
                defaults.removeObject(forKey: FragmentPool.customPromptKey)
            }
        }

        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let (manager, model) = makeProvider(type: .anthropic)
        let caller = FragmentModelRoute.caller(for: .remote(model), providerManager: manager,
                                               conversationId: "c2-live-fictional", profileId: "", kind: .memory)
        struct Scenario {
            let label: String
            let turns: [(role: String, content: String)]
            let subjectTerms: [String]
            let speaker: String?
            let facts: [[String]]
            let category: String?
        }
        // 全部为人工编造；不把它们描述成角色扮演，以免与提取器排除剧情的规则混淆。
        let scenarios = [
            Scenario(label: "长期属性", turns: [
                ("user", "说到日常饮品，我这三年一直偏爱月棠茶，平时都会选它，这个偏好以后也不会轻易变。今天只是闲聊，不是在临时点单。"),
                ("assistant", "明白，我们聊的是岚舟稳定的日常饮品偏好。")
            ], subjectTerms: ["岚舟"], speaker: "用户自述",
                     facts: [["岚舟"], ["月棠茶"], ["偏爱", "喜欢", "偏好"]], category: nil),
            Scenario(label: "纯讨论与工具失败", turns: [
                ("user", "只讨论一个假设：假如临时演示里的按钮变成圆形，会不会更容易点击？没有产品决定，也不是我的个人偏好。"),
                ("assistant", "圆形是否好点取决于尺寸和间距，这只是方案讨论。"),
                ("user", "刚才演示工具临时显示 DEMO_TOOL_TIMEOUT，能解释这个错误吗？不要把它当成长久状态。"),
                ("assistant", "这是演示工具这次调用超时，没有得到结果，也没有形成任何决定。")
            ], subjectTerms: [], speaker: nil, facts: [], category: nil),
            Scenario(label: "AI普通观察不是用户事实", turns: [
                ("user", "请只点评这次临时界面演示里的按钮，演示中的操作不代表我的长期偏好。"),
                ("assistant", "我观察到岚舟在演示里点了蓝色按钮。我猜岚舟长期偏爱蓝色，也许以后都会选蓝色。"),
                ("user", "这仅仅是演示，点了什么都不能推断我的长期偏好；我没有确认你的猜测。")
            ], subjectTerms: [], speaker: nil, facts: [], category: nil),
            Scenario(label: "AI长期承诺", turns: [
                ("user", "星砚，你会怎样执行‘纸灯暂停’这条长期约定？"),
                ("assistant", "星砚向岚舟承诺：以后只要岚舟在对话里说‘纸灯暂停’，星砚就停止给建议，直到岚舟明确说‘恢复建议’才继续。这不是只对本轮有效，而是今后持续遵守的约定。"),
                ("user", "明白了。")
            ], subjectTerms: ["星砚", "纸灯暂停", "暂停建议", "约定"], speaker: "AI 承诺",
                     facts: [["星砚"], ["岚舟"], ["纸灯暂停"], ["恢复"], ["停止", "暂停"]],
                     category: "relationship"),
            Scenario(label: "依赖上下文的代词", turns: [
                ("user", "现在要定下桌游《雾港棋盘》今后长期采用的默认规则，接下来只讨论这一个桌游。"),
                ("assistant", "《雾港棋盘》每局的轮数，以及每轮由谁领航，最终怎么定？"),
                ("user", "它就固定每局三轮，而且每轮轮流领航。这两条就是最终规则，以后都按这个办，不是只试一局。")
            ], subjectTerms: ["雾港棋盘"], speaker: "用户自述",
                     facts: [["雾港棋盘"], ["每局", "每场", "一局"], ["三轮", "3轮"], ["轮流", "轮换", "轮替", "交替"], ["领航"]],
                     category: nil)
        ]
        func normalized(_ text: String) -> String {
            text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).joined()
        }

        for (caseIndex, scenario) in scenarios.enumerated() {
            let messages = scenario.turns.enumerated().map { index, turn in
                FragmentPool.Message(id: "c2-live-\(caseIndex)-\(index)", role: turn.role,
                                     content: turn.content, date: nil)
            }
            let tag = "[C2 LIVE \(caseIndex + 1)/\(scenarios.count) · \(scenario.label)]"
            print("\(tag) BEGIN")
            var round = 0
            let result: FragmentPool.Batch?
            do {
                result = try await FragmentPool.run(messages, names: names, local: false, caller: { system, user in
                    round += 1
                    print("\(tag) ROUND \(round) REQUEST")
                    do {
                        let raw = try await caller(system, user)
                        print("\(tag) ROUND \(round) RAW BEGIN\n\(CatalogLiveAuthProtocol.redacted(raw ?? "<nil>"))\n\(tag) ROUND \(round) RAW END")
                        return raw
                    } catch {
                        print("\(tag) ROUND \(round) ERROR \(CatalogLiveAuthProtocol.redacted(String(reflecting: error)))")
                        throw error
                    }
                })
            } catch {
                print("\(tag) FINAL ERROR rounds=\(round) \(CatalogLiveAuthProtocol.redacted(String(reflecting: error)))")
                XCTFail("\(scenario.label)：C2 调用抛错，见该组 RAW 日志：\(CatalogLiveAuthProtocol.redacted(error.localizedDescription))")
                continue
            }
            print("\(tag) FINAL rounds=\(round) \(CatalogLiveAuthProtocol.redacted(String(reflecting: result)))")
            guard let batch = result else {
                XCTFail("\(scenario.label)：生产调用不能被预算闸或空响应跳过")
                continue
            }
            XCTAssertEqual(batch.rejected, 0, "\(scenario.label)：唯一重写后仍有不合格输出，见该组 RAW 和 FINAL 原因")
            guard let expectedSpeaker = scenario.speaker else {
                XCTAssertTrue(batch.fragments.isEmpty, "\(scenario.label)：讨论、工具失败和未经用户确认的AI观察均不得生成碎片")
                continue
            }
            XCTAssertFalse(batch.fragments.isEmpty, "\(scenario.label)：应提取长期事实或承诺")
            for fragment in batch.fragments {
                XCTAssertFalse(normalized(fragment.content).isEmpty, "\(scenario.label)：正文不能为空")
                XCTAssertLessThanOrEqual(fragment.content.count, 200, "\(scenario.label)：正文按String.count不得超过200字")
                XCTAssertFalse(messages.contains { normalized($0.content) == normalized(fragment.content) },
                               "\(scenario.label)：去空白和标点后仍不能原样复制消息")
                XCTAssertFalse((fragment.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(scenario.label)：新默认必须提供非空subject")
                XCTAssertEqual(fragment.speaker, expectedSpeaker, "\(scenario.label)：不能混淆用户自述与AI承诺")
                if let category = scenario.category {
                    XCTAssertEqual(fragment.category, category, "\(scenario.label)：AI承诺必须归入relationship")
                }
            }
            let matches = batch.fragments.filter { fragment in
                guard let subject = fragment.subject,
                      scenario.subjectTerms.contains(where: { subject.contains($0) }) else { return false }
                return scenario.facts.allSatisfy { alternatives in
                    alternatives.contains { fragment.content.contains($0) }
                }
            }
            XCTAssertFalse(matches.isEmpty, "\(scenario.label)：同一条碎片应有明确subject，并独立写全实体、事实及约定条件，不能只写我你或那个规则")
        }
    }

    /// 只量不判：12 段编造的乱聊天走真实 C2，逐条打印碎片全部字段，评判由人读日志
    func testC2QualityProbeLive() async throws {
        let defaults = UserDefaults.standard
        let previousPrompt = defaults.object(forKey: FragmentPool.customPromptKey)
        defaults.removeObject(forKey: FragmentPool.customPromptKey)
        defer {
            if let previousPrompt {
                defaults.set(previousPrompt, forKey: FragmentPool.customPromptKey)
            } else {
                defaults.removeObject(forKey: FragmentPool.customPromptKey)
            }
        }

        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let (manager, model) = makeProvider(type: .anthropic)
        let caller = FragmentModelRoute.caller(for: .remote(model), providerManager: manager,
                                               conversationId: "c2-probe-fictional", profileId: "", kind: .memory)
        // 全部人工编造。岚舟 = 阿舟；猫 琥珀将军 = 豆包；朋友 林栖 = 栖栖；老师 钟予白 = 钟老师；项目 潮汐手账 = 潮汐 / 那个手账 app。
        // 12 段对话和预期在 Resources/MemoryBench/memory-bench-c2-probe.json，和审计台试写台同一份
        let probe = try XCTUnwrap(MemoryBenchStore.builtInSets().first { $0.id == "c2-probe" }, "内置 C2 探针没打进 app 包")

        func json(_ fragment: FragmentPool.Fragment) -> String {
            let object: [String: Any] = [
                "msg": fragment.msg,
                "content": fragment.content,
                "subject": fragment.subject ?? NSNull(),
                "speaker": fragment.speaker ?? NSNull(),
                "tags": fragment.tags,
                "category": fragment.category,
                "importance": fragment.importance,
                "emotion": fragment.emotion,
                "resolved": fragment.resolved ?? NSNull(),
                "valid_until": fragment.validUntil?.value ?? NSNull()
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return "<json 编码失败>"
            }
            return String(decoding: data, as: UTF8.self)
        }

        for testCase in probe.cases {
            let input = try MemoryBenchC2Writer.input(testCase)
            let messages = try MemoryBenchC2Writer.messages(input, caseId: testCase.id)
            let label = "\(testCase.id) \(testCase.title)"
            print("[C2-PROBE] \(label) · 预期：\(testCase.note ?? "")")
            for (index, turn) in input.messages.enumerated() {
                print("[C2-PROBE-TURN] \(label) · [\(index + 1)] \(turn.role == "user" ? "岚舟" : "星砚")：\(turn.content)")
            }
            var round = 0
            let result: FragmentPool.Batch?
            do {
                result = try await FragmentPool.run(messages, names: names, local: false, onFirstRejection: { count, reason in
                    print("[C2-PROBE-REWRITE] \(label) · 第一轮 \(count) 张不合格，重写一次：\(CatalogLiveAuthProtocol.redacted(reason))")
                }, caller: { system, user in
                    round += 1
                    let raw = try await caller(system, user)
                    print("[C2-PROBE-RAW] \(label) · 第 \(round) 轮\n\(CatalogLiveAuthProtocol.redacted(raw ?? "<nil>"))\n[C2-PROBE-RAW-END]")
                    return raw
                })
            } catch {
                print("[C2-PROBE-ERROR] \(label) · rounds=\(round) \(CatalogLiveAuthProtocol.redacted(String(reflecting: error)))")
                print("[C2-PROBE-END] \(label) · 0 条")
                XCTFail("\(label)：C2 调用抛错或 JSON 解析失败：\(CatalogLiveAuthProtocol.redacted(error.localizedDescription))")
                continue
            }
            guard let batch = result else {
                print("[C2-PROBE-END] \(label) · 0 条（空响应）")
                XCTFail("\(label)：C2 返回空响应")
                continue
            }
            if batch.rejected > 0 {
                print("[C2-PROBE-REJECT] \(label) · 重写后仍丢弃 \(batch.rejected) 张：\(CatalogLiveAuthProtocol.redacted(batch.rejectionReasons.joined(separator: "；")))")
            }
            for fragment in batch.fragments {
                print("[C2-PROBE-FRAG] " + CatalogLiveAuthProtocol.redacted(json(fragment)))
            }
            print("[C2-PROBE-END] \(label) · \(batch.fragments.count) 条")
        }
    }

    /// 审计台试写台骨架跑 C2 探针（plan-memory-audit-home-trial 段 ②）：12 段 ×「现行」× 注入的模型（MP_C3_LIVE_MODEL，粟粟：live 用 Haiku）。
    /// 只断言跑得通、记录完整（每格有输出 / token / 钱，requests.jsonl 每格一行，run.json 读回来一样，占位分算得出来）；不断言分数。
    /// 每格条目 + 自动配的判断 + 整份 run.json 打进日志，人读
    func testC2BenchProbeLive() async throws {
        let (manager, model) = makeProvider(type: .anthropic)
        let probe = try XCTUnwrap(MemoryBenchStore.builtInSets().first { $0.id == "c2-probe" }, "内置 C2 探针没打进 app 包")
        let writer = MemoryBenchC2Writer()
        let empty = try XCTUnwrap(UserDefaults(suiteName: "xctest-bench-live-\(UUID().uuidString)"))
        let recipe = try XCTUnwrap(writer.builtInRecipes(defaults: empty).first, "「现行」配方")
        let store = MemoryBenchStore(root: try XCTUnwrap(root).appendingPathComponent("bench", isDirectory: true))
        let run = try await MemoryBenchRunner.run(writer: writer, set: probe, recipes: [recipe], models: [MemoryBenchModelRef(model)],
                                                  store: store, profileId: "",
                                                  caller: MemoryBenchRunner.liveCaller(providerManager: manager, profileId: ""))
        XCTAssertEqual(run.status, .done)
        XCTAssertEqual(run.cells.count, probe.cases.count)
        for cell in run.cells {
            let usage = cell.usage.map { "\($0.input)/\($0.output) token（\($0.source)）" } ?? "token 未知"
            let usd = cell.usd.map { String(format: "$%.4f", $0) } ?? "金额未知"
            print("[BENCH-C2] \(cell.caseId) · \(cell.items.count) 条 · \(usage) · \(usd)（\(cell.costSource?.rawValue ?? "-")） · \(cell.ms)ms"
                  + (cell.error.map { " · 出错：\(CatalogLiveAuthProtocol.redacted($0))" } ?? ""))
            for item in cell.items {
                let judged = run.judgments.first { $0.cellId == cell.id && $0.item == item.index }
                print("[BENCH-C2-ITEM] \(cell.caseId) · \(judged.map { "\($0.verdict.rawValue)（\($0.labelId ?? "")）" } ?? "待判") · "
                      + CatalogLiveAuthProtocol.redacted("\(item.text) · subject=\(item.fields["subject"] ?? "") · speaker=\(item.fields["speaker"] ?? "")"))
            }
            for check in cell.checks where !check.passed {
                print("[BENCH-C2-CHECK] \(cell.caseId) · \(check.name) · " + CatalogLiveAuthProtocol.redacted(check.detail ?? ""))
            }
            XCTAssertNil(cell.error, "\(cell.caseId)：\(cell.error ?? "")")
            XCTAssertNotNil(cell.output, "\(cell.caseId) 输出记下来了")
            XCTAssertNotNil(cell.usage, "\(cell.caseId) token 记下来了")
            XCTAssertNotNil(cell.usd, "\(cell.caseId) 钱记下来了")
            XCTAssertEqual(cell.costSource, .measured, "\(cell.caseId) Haiku 在价目表里，按实测记")
            XCTAssertEqual(cell.usage?.source, MemoryBenchUsage.measured, "\(cell.caseId) 回包报了完整用量")
        }
        XCTAssertEqual(store.requests(runId: run.id).count, run.cells.count, "每格一行完整日志")
        XCTAssertEqual(store.run(id: run.id), run, "run.json 读回来一样")
        let score = try XCTUnwrap(run.scores.first, "占位分算得出来")
        let parts = score.parts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[BENCH-C2-SCORE] \(score.mainName) \(score.main.map { String(format: "%.3f", $0) } ?? "没有可判的") · \(parts)")
        let json = String(decoding: try MemoryBench.encoder.encode(run), as: UTF8.self)
        print("[BENCH-C2-RUNJSON]\n\(CatalogLiveAuthProtocol.redacted(json))\n[BENCH-C2-RUNJSON-END]")
    }

    /// 第 6 段种子完整走一遍：一个 agent 全读 → 目录（批前零请求）→ 全批 → 同一任务逐页写 → 正文全批 → 入库。
    /// 日志打出 .runs 路径和每轮 anchor，车头在真机上对照文件库「整理记录」和记忆日志
    func testSeedOutlineThenPagesThenWikiLive() async throws {
        let root = try XCTUnwrap(root)
        try await Task.detached { try Self.seedCCFiles(root: root) }.value
        let container = try ModelContainer(for: Memory.self, Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let (manager, model) = makeProvider(type: .anthropic)
        let profileId = "xctest-c3-live-seed-\(UUID().uuidString.prefix(8))"
        let deps = CatalogAgent.Deps(makeBackend: {
            AssistantCloudBackend(model: model, providerManager: manager, usage: UsageContext(kind: .catalogSeed, profileId: profileId))
        }, gate: { text in
            await CatalogBudget.globalGate(model: model, providerManager: manager, text: text)
        })
        let slot = PromptFolder.path(for: .slot(presetId: "live-preset", slotId: "live-slot"))
        var job = CatalogJob(profileId: profileId, memoryRoot: root, container: container,
                             names: MemoryExtractor.Names(userName: "测试用户", assistantName: "测试助手"),
                             floorPrompt: "", modelName: model.modelId,
                             caller: { _, _ in nil }, agentDeps: deps)
        job.floorBase = CatalogFloorBase(sections: [
            .init(path: slot, name: "人工模拟设定", text: "这里只有人工模拟数据。测试用户住在虚构的云桥城，养了一只叫纸鸢的猫。回答时先给结论。", isEnabled: true),
        ])
        let wikiRoot = root.appendingPathComponent("wiki")
        let wiki = WikiStore(root: wikiRoot)
        let store = WikiProposalStore(wiki: wiki)
        func load() async -> ([WikiProposal], [String]) {
            await Task.detached { (store.list(), wiki.pagePaths()) }.value
        }

        let first = await CatalogSession(job: job).seed(entry: .persona)
        XCTAssertEqual(first.failures, [], first.summary)
        var (proposals, pages) = await load()
        let outline = try XCTUnwrap(proposals.first { CatalogSeedDrafts.isOutline($0) }, first.summary)
        XCTAssertTrue(pages.isEmpty, "目录没批不写页")
        XCTAssertEqual(proposals.count, 1, "批目录前没有正文提案")
        XCTAssertTrue(outline.items.allSatisfy { $0.state == .pending })
        let outlineSources = Set(outline.items.flatMap { $0.change.direction?.sources ?? [] })
        XCTAssertTrue(outlineSources.isSuperset(of: ["memory/cc/user_movies.md", "memory/cc/project_reader.md"]), "\(outlineSources)")
        for item in outline.items {
            let d = try XCTUnwrap(item.change.direction)
            print(CatalogLiveAuthProtocol.redacted("[C3 live seed] 目录 · \(d.kind?.rawValue ?? "") · \(d.path) · \(d.title) · 钩子：\(d.hook) · 原料：\((d.sources ?? []).joined(separator: "、"))"))
        }
        Self.printNotes(taskId: outline.id, wiki: wiki, tag: "seed", items: outline.items.count)

        try await WikiProposalReview.approve(outline.id, store: store, profileId: profileId, context: context)
        let second = await CatalogSession(job: job).resumeSeed(outline.id)
        XCTAssertEqual(second.failures, [], second.summary)
        (proposals, pages) = await load()
        let contents = proposals.filter { $0.directionRef?.proposalId == outline.id }
        XCTAssertEqual(contents.count, outline.items.count, "获批的每一页都交了正文提案")
        XCTAssertTrue(pages.isEmpty, "正文没批不落页")
        let done = await Task.detached { CatalogSeed.completion(wiki: wiki) }.value
        XCTAssertEqual(done?.taskId, outline.id, "整份目录处理完、获批页都交了正文才完成")
        let allText = String(decoding: try JSONEncoder().encode(proposals), as: UTF8.self)
        for excluded in ["private_x.md", "FEEDBACK_ONLY_C3_SEED", "PRIVATE_ONLY_C3_SEED", "回答时先给结论"] {
            XCTAssertFalse(allText.contains(excluded), "私人 / 回复规矩不进 wiki：\(excluded)")
        }

        for content in contents {
            try await WikiProposalReview.approve(content.id, store: store, profileId: profileId, context: context)
        }
        (_, pages) = await load()
        XCTAssertFalse(pages.isEmpty, "第二批批了才写进 wiki")
        print(CatalogLiveAuthProtocol.redacted("[C3 live seed] 入库 \(pages.count) 页：" + pages.joined(separator: "、")))

        MemoryWriteLog.flush()
        let run = try XCTUnwrap(outline.run)
        print("[C3 live seed] .runs：" + wikiRoot.appendingPathComponent(run.path).path)
        for entry in MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId)).reversed() where entry.note.hasPrefix("种子 · 第") {
            XCTAssertEqual(entry.run?.path, run.path, "每轮日志指向同一份记录")
            print(CatalogLiveAuthProtocol.redacted("[C3 live seed] 日志 · \(entry.note.prefix(80)) · anchor \(entry.run?.anchor ?? "无")"))
        }
        let text = try await Task.detached { try String(contentsOf: wikiRoot.appendingPathComponent(run.path), encoding: .utf8) }.value
        XCTAssertEqual(text.components(separatedBy: "· 单开一段对话").count - 1, contents.count, "写正文每页单开一段对话、各有一段原料清单")
        print("[C3-RUN-BEGIN] \(run.path)")
        print(Data(CatalogLiveAuthProtocol.redacted(text).utf8).base64EncodedString())
        print("[C3-RUN-END]")
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: profileId).deletingLastPathComponent())
    }

    /// 第 11 段：新用户三问（虚构答案）→ 目录 → 全批 → 逐页正文；打印目录和正文，只断言调用成功
    func testSurveyOutlineThenPagesLive() async throws {
        let root = try XCTUnwrap(root)
        let container = try ModelContainer(for: Memory.self, Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let (manager, model) = makeProvider(type: .anthropic)
        let profileId = "xctest-c3-live-survey-\(UUID().uuidString.prefix(8))"
        let deps = CatalogAgent.Deps(makeBackend: {
            AssistantCloudBackend(model: model, providerManager: manager, usage: UsageContext(kind: .catalogSeed, profileId: profileId))
        }, gate: { text in
            await CatalogBudget.globalGate(model: model, providerManager: manager, text: text)
        })
        var job = CatalogJob(profileId: profileId, memoryRoot: root, container: container,
                             names: MemoryExtractor.Names(userName: "测试用户", assistantName: "测试助手"),
                             floorPrompt: "", modelName: model.modelId,
                             caller: { _, _ in nil }, agentDeps: deps)
        job.seedModel = "remote:\(model.credentialId)/\(model.modelId)"
        let wikiRoot = root.appendingPathComponent("wiki")
        let wiki = WikiStore(root: wikiRoot)
        let store = WikiProposalStore(wiki: wiki)
        let answers = CatalogSurvey.answers(["测试用户", "在虚构的云桥城做独立游戏，算创业，正在做一款叫「纸鸢」的解谜游戏", "晚上十一点以后不想被提醒工作"])
        let taskId = UUID().uuidString
        let created = try await Task.detached {
            try await CatalogSurvey.create(taskId: taskId, profileId: profileId, answers: answers, wiki: wiki, blocked: nil, now: Date())
        }.value
        XCTAssertEqual(created, .started)

        let first = await CatalogSession(job: job).resumeSeed(taskId)
        XCTAssertEqual(first.failures, [], first.summary)
        let loaded = await Task.detached { store.load(taskId) }.value
        let outline = try XCTUnwrap(loaded, first.summary)
        for item in outline.items {
            let d = try XCTUnwrap(item.change.direction)
            print(CatalogLiveAuthProtocol.redacted("[C3 live survey] 目录 · \(d.kind?.rawValue ?? "") · \(d.path) · \(d.title) · 钩子：\(d.hook) · 原料：\((d.sources ?? []).joined(separator: "、"))"))
        }
        Self.printNotes(taskId: taskId, wiki: wiki, tag: "survey", items: outline.items.count)

        try await WikiProposalReview.approve(outline.id, store: store, profileId: profileId, context: context)
        let second = await CatalogSession(job: job).resumeSeed(taskId)
        XCTAssertEqual(second.failures, [], second.summary)
        let contents = await Task.detached { store.list().filter { $0.directionRef?.proposalId == taskId } }.value
        for content in contents {
            for item in content.items {
                print(CatalogLiveAuthProtocol.redacted("[C3 live survey] 正文 · \(content.title ?? "") · \(item.change.kindLabel) · \(item.change.targetPath ?? "")"))
                if case .newPage(let page) = item.change {
                    print(CatalogLiveAuthProtocol.redacted("[C3 live survey]   现在：\(page.now)"))
                    for record in page.records { print(CatalogLiveAuthProtocol.redacted("[C3 live survey]   记录：\(record)")) }
                }
                if case .appendRecords(_, let lines) = item.change {
                    for record in lines { print(CatalogLiveAuthProtocol.redacted("[C3 live survey]   记录：\(record)")) }
                }
            }
        }
        if let run = outline.run { print("[C3 live survey] .runs：" + wikiRoot.appendingPathComponent(run.path).path) }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: profileId).deletingLastPathComponent())
    }

    /// 第 8a 段：模型分拣真端点一次（虚构碎片 + 用户新建的一页「{{user}}/手作」），逐条打印模型判断和代码基线判断；分歧只记录，不当门槛
    func testModelSorterVersusCodeBaselineLive() async throws {
        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let (manager, model) = makeProvider(type: .anthropic)
        let caller = FragmentModelRoute.caller(for: .remote(model), providerManager: manager, conversationId: "", profileId: "", kind: .catalog)
        let pages = [
            WikiInjectionSnapshot.Page(path: "人/林栖", title: "林栖", triggers: ["栖栖"], hook: "岚舟提到林栖、陶艺工作室的时候先看这页", now: "岚舟的大学室友，在云桥城开陶艺工作室。"),
            WikiInjectionSnapshot.Page(path: "{{user}}/身体", title: "身体", triggers: ["偏头痛", "乳糖不耐"], hook: "岚舟说身体不舒服的时候先看这页", now: "换季容易偏头痛。"),
            WikiInjectionSnapshot.Page(path: "{{user}}/手作", title: "手作", triggers: ["陶艺课"], hook: "岚舟聊到自己动手做东西的时候先看这页", now: ""),
        ]
        func fragment(_ subject: String, _ tags: [String], _ content: String, day: Int) -> CatalogFragment {
            var f = CatalogFragment(id: UUID(), content: content, category: "fact", day: "2026-10-\(day)")
            f.subject = subject
            f.keywords = tags
            f.speaker = "用户自述"
            return f
        }
        // 全部人工编造；「手作」是她新建的页，第 3 条应能归进去
        let pool = [
            fragment("林栖", ["林栖", "陶艺展"], "林栖下个月去成都参加陶艺展，是第一次参加正式展览。", day: 12),
            fragment("岚舟", ["偏头痛", "换季"], "岚舟换季又犯了偏头痛，发作时怕光，只能拉窗帘躺着。", day: 12),
            fragment("岚舟", ["陶艺", "周末"], "岚舟周六去上了陶艺课，捏了一个歪歪的杯子，打算下周上釉。", day: 13),
            fragment("豆包", ["豆包", "吸尘器"], "豆包一听到吸尘器就钻进床底。", day: 13),
            fragment("豆包", ["豆包", "处方粮"], "豆包体检肌酐偏高，要长期吃肾脏处方粮。", day: 14),
            fragment("豆包", ["豆包", "搬家"], "搬家那几天豆包一直躲在纸箱里不出来。", day: 15),
            fragment("岚舟", ["穿搭"], "岚舟今天穿了红色外套。", day: 15),
            fragment("岚舟", ["潜水", "计划"], "岚舟计划明年春天考潜水证，先报游泳班。", day: 16),
            fragment("半盏", ["半盏", "旧书店"], "岚舟每周六下午固定去鹿鸣巷的半盏旧书店。", day: 16),
        ]
        let code = CatalogSorter.group(pool, pages: pages, blocked: [names.user, names.char], user: names.user)
        var rounds = 0
        let sorted = try await CatalogModelSorter.run(pool, pages: pages, names: names, caller: { system, user in
            rounds += 1
            let raw = try await caller(system, user)
            print("[C3-SORT-RAW] 第 \(rounds) 次\n\(CatalogLiveAuthProtocol.redacted(raw ?? "<nil>"))\n[C3-SORT-RAW-END]")
            return raw
        }, drafts: nil)
        let got = try XCTUnwrap(sorted, "模型没回 / 被拦")
        func verdict(_ id: UUID, _ grouped: CatalogSorter.Grouped, single: [UUID]) -> String {
            if let t = grouped.topics.first(where: { $0.fragmentIds.contains(id) }) { return (t.existing ? "归 " : "开新页 ") + t.path }
            return single.contains(id) ? "单条就够" : "留池"
        }
        var differ = 0
        for (i, f) in pool.enumerated() {
            let m = verdict(f.id, got.grouped, single: got.single)
            let c = verdict(f.id, code, single: [])
            if m != c { differ += 1 }
            print("[C3-SORT-LIVE] \(CatalogSorter.label(i)) · \(f.subject ?? "") · \(f.content) · 模型：\(m) · 代码：\(c)" + (m == c ? "" : " · 分歧"))
        }
        print("[C3-SORT-LIVE] \(model.modelId) · 请求 \(rounds) 次 · 分歧 \(differ) 条 · 模型暂存 / 新页不到 3 条 \(got.waiting) 条 · 代码拿不准 \(code.unclear) 条")
        XCTAssertLessThanOrEqual(rounds, 2, "最多一次重写")
    }

    /// 第 8b 段：模型分拣带 A4 时间轴真端点一次（虚构两天的 topics + 一组碎片），打印模型的 timeline_proposals 和代码基线的时间轴提案；
    /// 分歧只记录，只断言调用成功
    func testTimelineProposalsModelVersusCodeBaselineLive() async throws {
        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let (manager, model) = makeProvider(type: .anthropic)
        let caller = FragmentModelRoute.caller(for: .remote(model), providerManager: manager, conversationId: "", profileId: "", kind: .catalog)
        let pages = [
            WikiInjectionSnapshot.Page(path: "人/豆包", title: "豆包", triggers: ["橘猫"], hook: "岚舟提到豆包、猫的时候先看这页", now: "橘猫，4 岁。"),
            WikiInjectionSnapshot.Page(path: "{{user}}/手作", title: "手作", triggers: ["陶艺课"], hook: "岚舟聊到自己动手做东西的时候先看这页", now: ""),
        ]
        // 全部人工编造：毕设连续两天（该提）、陶艺课连续两天但字面对上「手作」页（不该提）、其余只出现一天
        let days = [
            CatalogTimeline.Day(date: "2026-10-20", topics: ["毕设", "搬家"]),
            CatalogTimeline.Day(date: "2026-10-21", topics: ["毕设", "陶艺课"]),
            CatalogTimeline.Day(date: "2026-10-22", topics: ["陶艺课", "豆包体检"]),
        ]
        let source = CatalogTimeline.Source(history: Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0.topics) }), fresh: days)
        func fragment(_ subject: String, _ tags: [String], _ content: String, day: Int) -> CatalogFragment {
            var f = CatalogFragment(id: UUID(), content: content, category: "fact", day: "2026-10-\(day)")
            f.subject = subject
            f.keywords = tags
            f.speaker = "用户自述"
            return f
        }
        let pool = [
            fragment("豆包", ["豆包", "体检"], "豆包体检肌酐偏高，要长期吃肾脏处方粮。", day: 22),
            fragment("岚舟", ["陶艺", "周末"], "岚舟周六去上了陶艺课，捏了一个歪歪的杯子。", day: 21),
            fragment("毕设", ["毕设", "导师"], "导师让毕设加一个用户测试环节。", day: 21),
        ]
        let blocked = [names.user, names.char]
        let code = CatalogSorter.group(pool, pages: pages, blocked: blocked, user: names.user)
        let codeTimeline = CatalogSorter.timeline(source, pages: pages, blocked: blocked, taken: code.topics)
        var rounds = 0
        let sorted = try await CatalogModelSorter.run(pool, pages: pages, timeline: CatalogTimeline.modelDays(source), names: names,
                                                      caller: { system, user in
            rounds += 1
            let raw = try await caller(system, user)
            print("[C3-TIMELINE-RAW] 第 \(rounds) 次\n\(CatalogLiveAuthProtocol.redacted(raw ?? "<nil>"))\n[C3-TIMELINE-RAW-END]")
            return raw
        }, drafts: nil)
        let got = try XCTUnwrap(sorted, "模型没回 / 被拦")
        for t in got.grouped.timeline.map({ CatalogTimeline.identified($0, history: source.history) }) {
            print("[C3-TIMELINE-LIVE] 模型 · \(t.path) · \(t.kind?.rawValue ?? "") · 依据 \(t.days) · 来源 \(t.basis) · \(t.reason)")
        }
        for t in codeTimeline { print("[C3-TIMELINE-LIVE] 代码 · \(t.path) · 来源 \(t.basis) · \(t.reason)") }
        let m = Set(got.grouped.timeline.map(\.title)), c = Set(codeTimeline.map(\.title))
        print("[C3-TIMELINE-LIVE] \(model.modelId) · 请求 \(rounds) 次 · 模型 \(m.sorted()) · 代码 \(c.sorted())"
            + (m == c ? "" : " · 分歧：只模型 \(m.subtracting(c).sorted())、只代码 \(c.subtracting(m).sorted())"))
        XCTAssertLessThanOrEqual(rounds, 2, "最多一次重写")
    }

    func testHaikuDailyRejectionFeedbackCorrectsTheatreAttributionLive() async throws {
        let (manager, model) = makeProvider(type: .anthropic)
        guard model.modelId.lowercased().contains("haiku") else {
            throw XCTSkip("本用例只跑 Haiku，请注入 TEST_RUNNER_MP_C3_LIVE_MODEL")
        }
        let root = try XCTUnwrap(root).appendingPathComponent("feedback-live", isDirectory: true)
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let store = WikiProposalStore(wiki: wiki)
        let profileId = "xctest-c3-feedback-\(UUID().uuidString)"
        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let row = Memory(content: "岚舟和星砚驾驶纸舟从云桥城旧码头启航，沿剧场航线穿过了雾桥。", category: "fact", profileId: profileId)
        context.insert(row)
        try context.save()
        var fragment = CatalogFragment(id: row.id, content: row.content, category: "fact", day: "2026-11-01")
        fragment.subject = "岚舟"
        fragment.speaker = "用户自述"
        let topic = CatalogSorter.Topic(path: "主题/云桥城航行", title: "云桥城航行", kind: .topic, existing: false,
                                        fragmentIds: [fragment.id], hook: "提到云桥城航行时先看这页")
        let caller = FragmentModelRoute.caller(for: .remote(model), providerManager: manager,
                                               conversationId: "", profileId: profileId, kind: .catalog)
        let run = CatalogRunRecord(wiki: wiki, topic: "虚构两轮驳回改归因", kind: "B-2 Haiku live")
        func material(_ topic: CatalogSorter.Topic, fragments: [CatalogFragment]) async -> CatalogWriter.Material {
            await CatalogWriter.material(topic, fragments: fragments, floorPrompt: "岚舟与星砚是同行伙伴。", wiki: wiki,
                                         memoryRoot: root, now: Date())
        }
        func write(_ m: CatalogWriter.Material, round: Int) async throws -> CatalogItems.Parsed {
            let result = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { system, user in
                let raw = try await caller(system, user)
                run.section("第 \(round) 稿 · 实际请求与回复", body: system + "\n\n" + user + "\n\n" + (raw ?? "<nil>"))
                return raw
            }, drafts: nil, run: run)
            return try XCTUnwrap(result, "第 \(round) 轮没有正文")
        }
        func page(_ parsed: CatalogItems.Parsed) throws -> (WikiProposal.Item, WikiPage) {
            let item = try XCTUnwrap(parsed.items.first { $0.change.targetPath == topic.path })
            guard case .newPage(let page) = item.change else {
                throw NSError(domain: "CatalogLiveSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "应交同主题新页"])
            }
            return (item, page)
        }
        let firstMaterial = await material(topic, fragments: [fragment])
        XCTAssertNil(firstMaterial.feedback)
        let first = try await write(firstMaterial, round: 1)
        let (item, firstPage) = try page(first)
        XCTAssertTrue(firstPage.now.contains("岚舟"), "第一稿应展示待纠正的本人归因")
        XCTAssertFalse(firstPage.now.contains("设定中"), "若第一稿已正确归因，本夹具没有复现误归因，不能算纠正证据")
        let proposal = WikiProposal(origin: .scheduled, createdAt: Date(), items: [item])
        try await Task.detached { try store.save(proposal) }.value
        let reason = "这是剧场背景，只能写成设定"
        try await WikiProposalReview.reject(proposal.id, itemIds: [item.id], reasons: [item.id: reason],
                                           store: store, profileId: profileId, context: context)
        let secondMaterial = await material(topic, fragments: [fragment])
        let prompt = CatalogWriter.userContent(secondMaterial, names: names)
        let feedback = try XCTUnwrap(prompt.range(of: "【审核反馈 ·"))
        let hook = try XCTUnwrap(prompt.range(of: "【定好的钩子】"))
        let search = try XCTUnwrap(prompt.range(of: "【搜回来的原料】"))
        XCTAssertLessThan(hook.lowerBound, feedback.lowerBound)
        XCTAssertLessThan(feedback.lowerBound, search.lowerBound)
        XCTAssertTrue(prompt.contains(reason))
        let unrelatedTopic = CatalogSorter.Topic(path: "主题/星砚的画具", title: "星砚的画具", kind: .topic, existing: false)
        let unrelated = await material(unrelatedTopic, fragments: [])
        let unrelatedPrompt = CatalogWriter.userContent(unrelated, names: names)
        XCTAssertFalse(unrelatedPrompt.contains(reason))
        XCTAssertNil(unrelated.feedback)
        let second = try await write(secondMaterial, round: 2)
        let (_, secondPage) = try page(second)
        let sentences = secondPage.now.components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        XCTAssertFalse(sentences.isEmpty)
        XCTAssertTrue(sentences.contains { $0.contains("设定中") }, secondPage.now)
        XCTAssertNotEqual(secondPage.factDomain, .realWorld, "不能标成本人现实域")
        run.section("B-2 两轮证据 · 全虚构", body: "模型：\(model.modelId)\n第一稿：\n\(firstPage.markdown)\n驳回：\(reason)\n第二稿：\n\(secondPage.markdown)\n不相关主题：\n\(unrelatedPrompt)")
        await run.flush()
        let text = try await Task.detached { try String(contentsOf: run.url, encoding: .utf8) }.value
        print("[C3-RUN-BEGIN] \(run.url.lastPathComponent)")
        print(Data(CatalogLiveAuthProtocol.redacted(text).utf8).base64EncodedString())
        print("[C3-RUN-END]")
    }

    /// 第 9 段：写作者新稿真端点（全部虚构）。① 普通页、行为模式页各一页；② 同一底图下的语义矩阵一页（增量 / 共存 / 冲突 / {c}观察 / 未兑现承诺）；
    /// ③ 种子一页（人设事实完整写，不写详见人设）。打印完整正文、检查结果和修订状态；只断言调用成功、交出了条目，不断言模型写的内容
    func testWriterNewDraftPagesLive() async throws {
        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let (manager, model) = makeProvider(type: .anthropic)
        let caller = FragmentModelRoute.caller(for: .remote(model), providerManager: manager, conversationId: "", profileId: "", kind: .catalog)
        let root = try XCTUnwrap(root)
        let wiki = WikiStore(root: root.appendingPathComponent("writer-live-wiki", isDirectory: true))
        let floor = "〔岚舟的身份〕\n岚舟在云桥城做插画师，养了一只叫豆包的橘猫。对芒果过敏。住在鹿鸣巷 3 楼。"
        func fragment(_ subject: String, _ content: String, day: String, speaker: String = "用户自述") -> CatalogFragment {
            var f = CatalogFragment(id: UUID(), content: content, category: "fact", day: day)
            f.subject = subject
            f.speaker = speaker
            return f
        }
        func show(_ label: String, _ got: CatalogItems.Parsed, rounds: Int) {
            for item in got.items {
                switch item.change {
                case .newPage(let page): print("[C3-WRITER-LIVE] \(label) 新页\n\(page.markdown)\n[C3-WRITER-LIVE-END]")
                case .appendRecords(let path, let lines): print("[C3-WRITER-LIVE] \(label) 追加 \(path)\n" + lines.joined(separator: "\n"))
                case .rewriteNow(let path, let old, let new, _): print("[C3-WRITER-LIVE] \(label) 改现在 \(path)\n旧：\(old)\n新：\(new)")
                case .link(let from, let link): print("[C3-WRITER-LIVE] \(label) 连线 \(from) → \(link.target) · \(link.relation.rawValue) · \(link.why)")
                default: print("[C3-WRITER-LIVE] \(label) 条目：\(item.change.kindLabel) \(item.change.targetPath ?? "")")
                }
                print("[C3-WRITER-LIVE] judgment：\(item.judgment?.rawValue ?? "无") · 条目上没过的检查：\(item.checks ?? [])")
            }
            print("[C3-WRITER-LIVE] \(model.modelId) · \(label) · 请求 \(rounds) 次 · 没过：\(got.revisionNotes) · 修订：\(got.revision ?? "无") · 收不进页的内容：\(got.unapplied.map { "\($0.page ?? "") \($0.raw)" }) · 只记日志：\(CatalogChecks.soft(got.items, names: names)) · 扔掉：\(got.dropReasons) · single：\(got.single.count) · covered：\(got.covered.count)")
        }
        func write(_ m: CatalogWriter.Material, _ label: String) async throws {
            var rounds = 0
            let parsed = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { system, user in
                rounds += 1
                let raw = try await caller(system, user)
                print("[C3-WRITER-RAW] \(label) 第 \(rounds) 次\n\(CatalogLiveAuthProtocol.redacted(raw ?? "<nil>"))\n[C3-WRITER-RAW-END]")
                return raw
            }, drafts: nil)
            let got = try XCTUnwrap(parsed, "\(label)：模型没回 / 被拦")
            XCTAssertFalse(got.items.isEmpty, "\(label)：交出了条目")
            show(label, got, rounds: rounds)
        }
        func search(_ topic: CatalogSorter.Topic) -> CatalogRetrieval.Result {
            CatalogRetrieval.Result(aline: .init(terms: topic.terms, hits: [], found: [:]), fragments: [], labels: [:], vectorStatus: "不可用")
        }

        // ① 普通页、行为模式页
        let cases: [(topic: CatalogSorter.Topic, fragments: [CatalogFragment])] = [
            (CatalogSorter.Topic(path: "人/豆包", title: "豆包", kind: .person, aliases: ["包包"], existing: false), [
                fragment("豆包", "豆包是三岁的公橘猫，已经绝育。", day: "2026-10-10"),
                fragment("豆包", "豆包体检肌酐偏高，兽医让它长期吃肾脏处方粮。", day: "2026-10-12"),
                fragment("豆包", "豆包一听到吸尘器就钻进床底。", day: "2026-10-13"),
                fragment("豆包", "搬家那几天豆包一直躲在纸箱里不出来。", day: "2026-10-15"),
            ]),
            (CatalogSorter.Topic(path: "{{user}}/行为模式/赶稿", title: "赶稿", kind: .user, existing: false), [
                fragment("岚舟", "插画稿截稿前三天，岚舟总是先去整理画具、刷视频，说「还来得及」。", day: "2026-09-25"),
                fragment("岚舟", "岚舟截稿前一晚通宵赶完 9 月的绘本插画，交稿后说「我怎么又这样」。", day: "2026-09-28"),
                fragment("岚舟", "10 月封面稿又拖到最后两天，岚舟说「来不及了」，星砚陪着把稿子拆成小块才开始画。", day: "2026-10-20"),
            ]),
        ]
        for c in cases {
            let m = CatalogWriter.Material(topic: c.topic, floorPrompt: floor, indexLines: [], pageRaw: nil, search: search(c.topic), fragments: c.fragments)
            try await write(m, c.topic.path)
        }

        // ② 语义矩阵：同一底图 + 已有页，碎片各占一种情况
        let path = "{{user}}/日常"
        try wiki.save(WikiPage(path: path, kind: .user, triggers: ["日常", "住处"], hook: "当岚舟聊住处、作息、养宠时先看这页", title: "日常",
                               now: "住在鹿鸣巷 3 楼（详见人设）。喜欢猫（自 2026-08 起）。", records: ["2026-08-20 收养豆包（出处：碎片 00000000）"]))
        let matrix = [
            fragment("岚舟", "岚舟从 10 月起每天早上跑步 3 公里。", day: "2026-10-05"),
            fragment("岚舟", "岚舟说其实也很喜欢狗，以后想再养一只柯基。", day: "2026-10-08"),
            fragment("岚舟", "岚舟 10 月中搬到了鹿鸣巷 5 楼。", day: "2026-10-15"),
            fragment("岚舟", "星砚觉得岚舟熬夜画稿后第二天情绪会明显低落。", day: "2026-10-18", speaker: "助手观察"),
            fragment("岚舟", "星砚答应下周帮岚舟整理一批参考图，还没做。", day: "2026-10-19", speaker: "助手"),
        ]
        let topic = CatalogSorter.Topic(path: path, title: "日常", kind: .user, existing: true, fragmentIds: matrix.map(\.id))
        let read = try XCTUnwrap(wiki.readVersioned(path))
        let matrixMaterial = CatalogWriter.Material(topic: topic, floorPrompt: floor, indexLines: [], pageRaw: read.text, versions: [path: read.version],
                                                    search: search(topic), fragments: matrix)
        print("[C3-WRITER-LIVE] 语义矩阵：f1 增量（跑步）· f2 共存（也喜欢狗）· f3 冲突（3 楼 → 5 楼）· f4 星砚观察 · f5 星砚未兑现承诺")
        try await write(matrixMaterial, "语义矩阵 " + path)

        // ③ 种子：人设事实完整写进页
        let seedRoot = root.appendingPathComponent("writer-live-seed", isDirectory: true)
        let container = try ModelContainer(for: Memory.self, Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let profileId = "xctest-c3-live-writer-seed-\(UUID().uuidString.prefix(8))"
        let deps = CatalogAgent.Deps(makeBackend: {
            AssistantCloudBackend(model: model, providerManager: manager, usage: UsageContext(kind: .catalogSeed, profileId: profileId))
        }, gate: { text in
            await CatalogBudget.globalGate(model: model, providerManager: manager, text: text)
        })
        var job = CatalogJob(profileId: profileId, memoryRoot: seedRoot, container: container, names: names, floorPrompt: "",
                             modelName: model.modelId, caller: { _, _ in nil }, agentDeps: deps)
        job.floorBase = CatalogFloorBase(sections: [
            .init(path: PromptFolder.path(for: .slot(presetId: "live-preset", slotId: "live-persona")), name: "人工模拟设定",
                  text: "岚舟在云桥城做插画师，接绘本和封面稿。养了一只叫豆包的三岁橘猫。对芒果过敏，随身带抗过敏药。住在鹿鸣巷 3 楼。", isEnabled: true),
        ])
        let seedWiki = WikiStore(root: seedRoot.appendingPathComponent("wiki"))
        let seedStore = WikiProposalStore(wiki: seedWiki)
        let first = await CatalogSession(job: job).seed(entry: .persona)
        XCTAssertEqual(first.failures, [], first.summary)
        let listed = await Task.detached { seedStore.list() }.value
        let outline = try XCTUnwrap(listed.first { CatalogSeedDrafts.isOutline($0) }, first.summary)
        try await WikiProposalReview.approve(outline.id, store: seedStore, profileId: profileId, context: ModelContext(container))
        let second = await CatalogSession(job: job).resumeSeed(outline.id)
        XCTAssertEqual(second.failures, [], second.summary)
        let contents = await Task.detached { seedStore.list() }.value.filter { $0.directionRef?.proposalId == outline.id }
        XCTAssertFalse(contents.isEmpty, "种子交出了正文")
        for content in contents {
            for item in content.items {
                if case .newPage(let page) = item.change {
                    print(CatalogLiveAuthProtocol.redacted("[C3-WRITER-LIVE] 种子 新页\n\(page.markdown)\n[C3-WRITER-LIVE-END]"))
                } else {
                    print("[C3-WRITER-LIVE] 种子 条目：\(item.change.kindLabel) \(item.change.targetPath ?? "")")
                }
                print("[C3-WRITER-LIVE] 种子 条目上没过的检查：\(item.checks ?? [])")
            }
            print("[C3-WRITER-LIVE] 种子 · \(content.title ?? "") · 修订：\(content.revision ?? "无") · 收不进页的内容：\(content.unapplied?.count ?? 0)")
        }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: profileId).deletingLastPathComponent())
    }

    /// 第 10 段：虚构的一页旧页 + 几条碎片让写手写一次，打印同一次的来源检查（丢掉的行）和 Coverage / Preservation 诊断；只断言调用成功
    func testWriterCoveragePreservationLive() async throws {
        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let (manager, model) = makeProvider(type: .anthropic)
        let caller = FragmentModelRoute.caller(for: .remote(model), providerManager: manager, conversationId: "", profileId: "", kind: .catalog)
        let root = try XCTUnwrap(root)
        let wiki = WikiStore(root: root.appendingPathComponent("diagnostics-live-wiki", isDirectory: true))
        let path = "人/豆包"
        try wiki.save(WikiPage(path: path, kind: .person, triggers: ["豆包", "包包"], hook: "当岚舟聊豆包吃饭、看病、躲人时先看这页", title: "豆包",
                               now: "三岁的公橘猫，已绝育（自 2026-08 起）。吃普通成猫粮，一天两顿（自 2026-08 起）。怕吸尘器，一响就钻床底（自 2026-09 起）。",
                               records: ["2026-08-20 被岚舟收养（出处：碎片 00000000）"]))
        func fragment(_ content: String, day: String) -> CatalogFragment {
            var f = CatalogFragment(id: UUID(), content: content, category: "fact", day: day)
            f.subject = "豆包"
            f.speaker = "用户自述"
            return f
        }
        let fragments = [
            fragment("豆包体检肌酐偏高，兽医让它从 10 月起改吃肾脏处方粮。", day: "2026-10-12"),
            fragment("豆包这周开始一天喂三顿小份。", day: "2026-10-14"),
            fragment("岚舟说今天天气不错。", day: "2026-10-15"),
        ]
        let topic = CatalogSorter.Topic(path: path, title: "豆包", kind: .person, aliases: ["包包"], existing: true, fragmentIds: fragments.map(\.id))
        let read = try XCTUnwrap(wiki.readVersioned(path))
        let material = CatalogWriter.Material(topic: topic, floorPrompt: "〔岚舟的身份〕\n岚舟在云桥城做插画师，养了一只叫豆包的橘猫。", indexLines: [],
                                              pageRaw: read.text, versions: [path: read.version],
                                              search: CatalogRetrieval.Result(aline: .init(terms: topic.terms, hits: [], found: [:]), fragments: [],
                                                                              labels: [:], vectorStatus: "不可用"),
                                              fragments: fragments)
        let run = CatalogRunRecord(wiki: wiki, topic: "豆包", kind: "第 10 段 live")
        var rounds = 0
        let parsed = try await CatalogWriter.write(material, names: names, wiki: wiki, caller: { system, user in
            rounds += 1
            let raw = try await caller(system, user)
            print("[C3-DIAG-RAW] 第 \(rounds) 次\n\(CatalogLiveAuthProtocol.redacted(raw ?? "<nil>"))\n[C3-DIAG-RAW-END]")
            return raw
        }, drafts: nil, run: run)
        let got = try XCTUnwrap(parsed, "模型没回 / 被拦")
        print("[C3-DIAG-LIVE] \(model.modelId) · 请求 \(rounds) 次 · 条目 \(got.items.count) · 修订：\(got.revision ?? "无")")
        print("[C3-DIAG-LIVE] 来源检查\n" + CatalogDiagnostics.faithfulness(got))
        print("[C3-DIAG-LIVE] Coverage\n" + CatalogDiagnostics.coverage(got, sources: material.sources))
        print("[C3-DIAG-LIVE] Preservation\n" + CatalogDiagnostics.preservation(got))
        CatalogDiagnostics.record(got, sources: material.sources, final: true, title: "写手 · 豆包", run: run)
        await run.flush()
        print("[C3-DIAG-LIVE] 运行记录：\(run.url.path)")
    }

    /// 第 7 段：A4 主调真端点（全部虚构）：一组编的 A2 段标题跑一次主调 + 话题词，打印原文和解析结果；只断言调用成功、拿到主调
    func testTimelineHeadlineLive() async throws {
        let (manager, model) = makeProvider(type: .anthropic)
        let caller = SessionSegmentWriter.modelCaller(model: model, providerManager: manager, conversationId: "", profileId: "",
                                                      kind: .timeline, checkWriteBudget: false)
        let titles = ["修设置页的报错", "给橘猫豆包挑处方粮", "鹿鸣巷旧书店淘到一本画册", "睡前聊考潜水证"]
        var raw: String?
        let draft = try await TimelineWriter.write(date: "2026-10-12", titles: titles) { system, user in
            raw = try await caller(system, user)
            return raw
        }
        print("[A4-LIVE] \(model.modelId) · 标题：\(titles.joined(separator: " / "))")
        print("[A4-LIVE-RAW] \(CatalogLiveAuthProtocol.redacted(raw ?? "<nil>"))")
        print("[A4-LIVE] 主调：\(draft?.headline ?? "<nil>")（\(draft?.headline.count ?? 0) 字）· 话题：\(draft?.topics ?? [])")
        let d = try XCTUnwrap(draft, "模型没回 / 被拦")
        XCTAssertFalse(d.headline.isEmpty)
    }

    private func makeProvider(type: ProviderType) -> (ProviderManager, ProviderModel) {
        let id = "xctest-catalog-live-\(UUID().uuidString)"
        credentialId = id
        let baseURL = getenv("MP_C3_LIVE_BASE_URL").map { String(cString: $0) } ?? "https://api.anthropic.com/v1"
        let modelId = getenv("MP_C3_LIVE_MODEL").map { String(cString: $0) } ?? "claude-sonnet-4-6"
        let model = ProviderModel(credentialId: id, modelId: modelId, name: modelId)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        providers = manager
        manager.addCredential(APICredential(id: id, name: "Catalog live test", emoji: "", type: type,
                                            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"],
                                            models: [model], toolsSupported: true))
        // 持久化层只接触占位符；真实 key 由测试内的网络协议在发往端点前替换。
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        return (manager, model)
    }

    /// 两批：自动 / 助手先只交方向（不调模型），批了才查、写；手动说一次就进 agent。正文都要第二次批才落页
    private func run(type: ProviderType, organizeNow: Bool, daily: Bool = false, assistant: Bool = false) async throws {
        let root = try XCTUnwrap(root)
        let container = try ModelContainer(for: Memory.self, Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for id in ["c3movie1-smoke-window", "c3movie2-smoke-window"] {
            context.insert(Conversation(id: id, title: "人工模拟电影窗口", createTime: Date(), updateTime: Date(), currentNodeId: "", profileId: ""))
        }
        for (index, text) in [
            "2026-10-12 电影：看完《星际穿越》，喜欢诺兰把时间和亲情交织起来的讲法。这天开始做持续更新的电影观影计划，准备跨片比较导演。",
            "2026-10-13 电影：重看《盗梦空间》，对诺兰电影中的开放式结尾很感兴趣。继续更新同一电影观影计划，把它与前一天的《星际穿越》作比较。",
            "2026-10-14 电影：看了《重庆森林》，喜欢王家卫的色彩和城市气氛。同一电影观影计划加入王家卫，下一步继续对照诺兰和王家卫。"
        ].enumerated() {
            let row = Memory(content: text, category: "fact", keywords: ["电影", "导演", "诺兰", "王家卫"], profileId: "")
            row.subject = "电影"
            row.occurredDay = "2026-10-\(12 + index)"
            row.importance = 3
            row.reviewedAt = Date()
            context.insert(row)
        }
        try context.save()

        let (manager, model) = makeProvider(type: type)
        var modelRequests = 0
        let caller = FragmentModelRoute.caller(for: .remote(model), providerManager: manager, conversationId: "", profileId: "", kind: .catalog)
        let job = CatalogJob(profileId: "", memoryRoot: root, container: container,
                             names: MemoryExtractor.Names(userName: "测试用户", assistantName: "测试助手"),
                             floorPrompt: "这里只包含人工模拟数据。电影是持续变化的兴趣主题；电影、导演和看片讨论一起整理，保留日期与出处，不编造事实。",
                             modelName: model.modelId,
                             caller: { system, user in
                                 modelRequests += 1
                                 return try await caller(system, user)
                             },
                             agentDeps: .init(makeBackend: {
                                 modelRequests += 1
                                 return AssistantCloudBackend(model: model, providerManager: manager, usage: UsageContext(kind: .catalog))
                             }, gate: { text in
                                 await CatalogBudget.block(model: model, providerManager: manager, text: text)
                             }))
        let wikiRoot = root.appendingPathComponent("wiki")
        func load() async -> ([WikiProposal], [String]) {
            await Task.detached {
                let wiki = WikiStore(root: wikiRoot)
                return (WikiProposalStore(wiki: wiki).list(), wiki.pagePaths())
            }.value
        }
        let report: CatalogRunReport
        if daily || assistant {
            if daily {
                let first = await CatalogSession(job: job).daily()
                XCTAssertEqual(first.proposals, 1, first.summary)
            } else {
                let path = "主题/电影"
                let r = await Task.detached {
                    WikiSuggestTool.execute(inputJSON: "{\"path\":\"\(path)\",\"reason\":\"刚聊到跨片比较诺兰和王家卫\"}",
                                            wiki: WikiStore(root: wikiRoot), profileId: "")
                }.value
                XCTAssertFalse(r.isError, r.text)
            }
            let (pending, pagesBefore) = await load()
            XCTAssertEqual(modelRequests, 0, "方向待批：没有任何模型请求（分拣 / 搜索 / 写手）")
            XCTAssertTrue(pagesBefore.isEmpty)
            let direction = try XCTUnwrap(pending.first)
            XCTAssertEqual(direction.origin, assistant ? .assistant : .scheduled)
            XCTAssertTrue(direction.items.allSatisfy { $0.change.direction != nil && $0.state == .pending })
            let pendingIds = Set(direction.items.compactMap { $0.change.direction?.clues }.flatMap { $0 })
            XCTAssertEqual(pendingIds.count, assistant ? 0 : 3)
            let store = WikiProposalStore(wiki: WikiStore(root: wikiRoot))
            try await WikiProposalReview.approve(direction.id, store: store, profileId: "", context: context)
            XCTAssertEqual(modelRequests, 0, "批方向这一步本身不调模型")
            report = await CatalogSession(job: job).directions(direction.id)
            XCTAssertGreaterThan(modelRequests, 0, "批了才查、写")
            let ranTwice = await CatalogSession(job: job).directions(direction.id)
            XCTAssertEqual(ranTwice.skipped, "没有要执行的方向", "同一方向不重付")
            let result = await Task.detached { WikiProposalStore(wiki: WikiStore(root: wikiRoot)).load(direction.id) }.value
            for item in result?.items ?? [] {
                print(CatalogLiveAuthProtocol.redacted("[C3 live] 方向《\(item.change.direction?.title ?? "")》结果：\(item.change.direction?.result ?? "（无）")"))
            }
        } else if organizeNow {
            report = await CatalogSession(job: job).organizeNow()
        } else {
            report = await CatalogSession(job: job).organizeTopic("电影")
        }
        let records = try await Task.detached {
            let folder = root.appendingPathComponent("wiki/.runs")
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }
                .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        }.value
        XCTAssertEqual(records.count, daily ? 2 : 1, "自动：提方向一份 + 执行方向一份；其余一次一份")
        let writing = records.filter { $0.1.contains("系统提示") }
        XCTAssertEqual(writing.count, 1, "只有批了以后那次才有模型请求")
        for (name, text) in records {
            if text.contains("系统提示") {
                XCTAssertTrue(text.contains("星际穿越"), "记录必须保留真实返回的模拟原料")
            } else {
                XCTAssertTrue(text.contains("没调模型"), "提方向那份记录不该有模型请求")
            }
            print("[C3-RUN-BEGIN] \(name)")
            print(Data(CatalogLiveAuthProtocol.redacted(text).utf8).base64EncodedString())
            print("[C3-RUN-END]")
        }
        XCTAssertEqual(report.failures, [])
        XCTAssertNil(report.blocked)
        XCTAssertNil(report.skipped)
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.incomplete, 0)
        XCTAssertGreaterThanOrEqual(report.proposals, 1, report.summary)
        let evidence = writing.flatMap { CatalogRunRecord.searchEvidence(in: $0.1) }
        let alineBodies = evidence.flatMap(\.aline)
        XCTAssertTrue(alineBodies.contains { $0.contains("星际穿越") || $0.contains("重庆森林") }, "自动和手动都必须真正取回 A 线模拟原料")
        let chars = evidence.reduce(0) { $0 + $1.searchedChars }
        let assignedChars = evidence.reduce(0) { $0 + $1.assignedChars }
        XCTAssertGreaterThan(chars, 0, "工具说明、未命中提示和直接分配碎片不算检索正文")
        let (all, pagesBeforeContent) = await load()
        let content = all.filter { !$0.items.contains { $0.change.direction != nil } }
        XCTAssertEqual(content.count, report.proposals)
        XCTAssertEqual(content.reduce(0) { $0 + $1.items.count }, report.items)
        XCTAssertTrue(pagesBeforeContent.isEmpty, "正文没批不落页")
        if daily || assistant {
            XCTAssertTrue(content.allSatisfy { $0.directionRef != nil }, "正文提案关联原方向")
        } else {
            XCTAssertTrue(all.allSatisfy { $0.request != nil }, "手动请求本身就是方向授权，记在正文提案上，不出待批方向")
        }
        let store = WikiProposalStore(wiki: WikiStore(root: wikiRoot))
        for proposal in content {
            try await WikiProposalReview.approve(proposal.id, store: store, profileId: "", context: context)
        }
        let (_, pagesAfter) = await load()
        XCTAssertFalse(pagesAfter.isEmpty, "第二次批才落页")
        let route = type == .anthropic ? "Anthropic" : "OpenAI"
        let mode = daily ? "自动两批" : assistant ? "助手方向两批" : organizeNow ? "现在整理" : "整理一个主题：电影"
        print(CatalogLiveAuthProtocol.redacted("[C3 live] \(route) · \(CatalogLiveAuthProtocol.host ?? "") · \(model.modelId) · \(mode) · 查回正文 \(chars) 字 · 直接分配碎片 \(assignedChars) 字 · 向量 \(evidence.map(\.vectorStatus).joined(separator: "；")) · \(report.proposals) 份提案 · \(report.items) 条 · 批后 \(pagesAfter.count) 页"))
        for proposal in content {
            print(CatalogLiveAuthProtocol.redacted("[C3 live] 提案《\(proposal.title ?? "未命名")》· \(proposal.items.count) 条"))
        }
    }


    /// 要点卡流程的中间量：批数 / 卡数 / 对齐合并了哪些 / 目录项数（只打印，不断言）
    private nonisolated static func printNotes(taskId: String, wiki: WikiStore, tag: String, items: Int) {
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        guard let task = tasks.load(taskId) else { return }
        let batches = task.notes?.batches ?? []
        print(CatalogLiveAuthProtocol.redacted("[C3 live \(tag)] 要点卡：\(batches.count) 批（没出成 \(batches.filter { !$0.ok }.count)）· 卡 \(task.carded?.count ?? 0) 张 · 请求 \(task.rounds) 次 · 目录 \(items) 项"))
        if let aligned = tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: taskId) {
            print(CatalogLiveAuthProtocol.redacted("[C3 live \(tag)] 对齐：\(aligned.groups.count) 个实体 · 合进本人 \(aligned.userPaths.count) 份 · 丢掉 \(aligned.dropped.count) 组"))
            for g in aligned.groups where !g.mergedFrom.isEmpty || g.existingPage != nil {
                print(CatalogLiveAuthProtocol.redacted("[C3 live \(tag)] 合并 · \(g.display) ← \(g.mergedFrom.joined(separator: "、"))" + (g.existingPage.map { " → 已有页 \($0)" } ?? "")))
            }
        }
        if let clusters = tasks.loadNotes(SeedNoteClusters.self, name: CatalogSeedTaskStore.clusteredFileName, id: taskId) {
            print(CatalogLiveAuthProtocol.redacted("[C3 live \(tag)] 聚类：本人页 \(clusters.userPages.map(\.path).joined(separator: "、")) · 主题页 \(clusters.topics.map(\.path).joined(separator: "、")) · 没归进目录 \(clusters.unplaced.count) 份"))
        }
    }

    private nonisolated static func seedCCFiles(root: URL) throws {
        let folder = root.appendingPathComponent("cc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [
            "user_movies.md": """
            ---
            name: 喜欢的电影类型
            description: 测试用户长期稳定的电影偏好
            type: user
            ---
            # 喜欢的电影类型
            测试用户喜欢科幻电影，也喜欢悬疑推理电影。选片时关注时间叙事和开放式结尾。
            """,
            "user_sleep.md": """
            ---
            name: 作息习惯
            description: 测试用户的日常作息与休息习惯
            metadata:
              type: user
            ---
            # 作息习惯
            测试用户作息偏晚，通常凌晨一点入睡、早晨九点起床。每天保留午休，下午避免摄入咖啡因。
            """,
            "project_reader.md": """
            ---
            name: 纸舟离线阅读项目
            description: 阅读工具的目标与本地数据约束
            metadata:
              type: project
            ---
            # 纸舟离线阅读项目
            纸舟项目是一款离线阅读工具，首要目标是全文检索。所有索引保存在本地，不上传阅读内容。
            """,
            "feedback_style.md": """
            ---
            name: 回复风格反馈
            description: 只用于反馈过滤的人工标记
            type: feedback
            ---
            # 回复风格反馈
            FEEDBACK_ONLY_C3_SEED：回答先给三句结论。
            """,
            "private_x.md": """
            ---
            name: 私密收藏
            description: 不得播种的私密用户资料
            type: user
            ---
            # 私密收藏
            PRIVATE_ONLY_C3_SEED：私密收藏地点是琥珀盒。
            """,
            "journal_notes.md": """
            ---
            name: 测试用户的日记
            description: 测试用户的个人记录
            type: user
            ---
            # 测试用户的日记
            DIARY_ONLY_C3_SEED：今天梦见紫色的纸鲸。
            """
        ]
        for (name, body) in files {
            let content = name == "user_movies.md" || name == "project_reader.md" || name == "journal_notes.md"
                ? CCMemorySync.wrap(body, at: Date(timeIntervalSince1970: 1_792_195_200))
                : body
            try content.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private nonisolated static func seedFiles(root: URL) throws {
        for index in 0..<2 {
            let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12 + index, hour: 20))!
            let id = index == 0 ? "c3movie1-smoke-window" : "c3movie2-smoke-window"
            let title = index == 0 ? "电影与诺兰" : "电影与王家卫"
            let story = index == 0
                ? "电影讨论中，测试用户说喜欢《星际穿越》和《盗梦空间》，偏爱诺兰对时间结构的处理；电影让他想起家人与承诺。"
                : "电影讨论中，测试用户说《重庆森林》的城市色彩很吸引自己，最近也开始关注王家卫，喜欢不同导演各有风格，不是放弃诺兰。"
            let segment = SessionSegment(kind: .closeout, title: title, start: start, end: start.addingTimeInterval(1800), from: 0, to: 8, lastNodeId: nil,
                                         story: story, quotes: index == 0 ? "测试用户：电影里我喜欢诺兰的时间叙事。" : "测试用户：王家卫电影的色彩也很打动我。", pending: "继续看电影并比较导演风格")
            try WindowSummaryStore.save(SessionSummary(conversationId: id, title: title, compressedCount: 0, segments: [segment], updatedAt: start), in: root)
            let entry = TimelineEntry(start: start, end: start.addingTimeInterval(1800), conversationId: id, title: title,
                                      text: "- " + story, pending: "继续看电影", day: MemoryDay.key(start))
            try TimelineStore.mutateMonth(String(entry.dayKey.prefix(7)), in: TimelineStore.dir(root: root)) { $0.entries.append(entry) }
        }
    }
}

// 只替换运行时鉴权，所有请求体和真实 HTTP/SSE 响应原样通过；不生成任何模拟响应。
final class CatalogLiveAuthProtocol: URLProtocol, URLSessionDataDelegate {
    static let placeholder = "catalog-live-runtime-key"
    nonisolated(unsafe) static var key: String?
    nonisolated(unsafe) static var host: String?
    nonisolated(unsafe) private static var factories: (Method, Method)?
    nonisolated(unsafe) private static var sharedFactories: (Method, Method)?
    nonisolated(unsafe) static var nonStreamingSession: URLSession?
    /// 真跑取证：每个转发出去的请求体（已换 key 之前的原文，不含请求头）交给它看一眼；只在内存里，别落盘
    nonisolated(unsafe) static var onOutgoingBody: ((Data) -> Void)?

    static func install() throws {
        guard let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.default)),
              let replacement = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.catalogLiveDefault)),
              let shared = class_getClassMethod(URLSession.self, #selector(getter: URLSession.shared)),
              let sharedReplacement = class_getClassMethod(URLSession.self, #selector(URLSession.catalogLiveShared)) else {
            throw NSError(domain: "CatalogLiveSmoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "找不到测试会话配置入口"])
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogLiveAuthProtocol.self]
        nonStreamingSession = URLSession(configuration: configuration)
        method_exchangeImplementations(original, replacement)
        factories = (original, replacement)
        method_exchangeImplementations(shared, sharedReplacement)
        sharedFactories = (shared, sharedReplacement)
        guard URLSessionConfiguration.default.protocolClasses?.contains(where: { $0 == CatalogLiveAuthProtocol.self }) == true else {
            uninstall()
            throw NSError(domain: "CatalogLiveSmoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "测试鉴权协议未安装"])
        }
    }

    static func uninstall() {
        if let factories { method_exchangeImplementations(factories.0, factories.1) }
        factories = nil
        if let sharedFactories { method_exchangeImplementations(sharedFactories.0, sharedFactories.1) }
        sharedFactories = nil
        nonStreamingSession?.invalidateAndCancel()
        nonStreamingSession = nil
    }
    private var session: URLSession?
    private var forwardingTask: URLSessionDataTask?
    private var rejected = false
    private var errorBytes = Data()

    static func redacted(_ text: String) -> String {
        guard let key, !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "[REDACTED]")
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host, request.url?.host == host else { return false }
        return request.value(forHTTPHeaderField: "x-api-key") == placeholder ||
            request.value(forHTTPHeaderField: "Authorization") == "Bearer " + placeholder
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let key = Self.key else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        var outgoing = request
        if let stream = outgoing.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(buffer, count: count)
            }
            outgoing.httpBodyStream = nil
            outgoing.httpBody = bytes
        }
        if let body = outgoing.httpBody { Self.onOutgoingBody?(body) }
        if outgoing.value(forHTTPHeaderField: "x-api-key") != nil { outgoing.setValue(key, forHTTPHeaderField: "x-api-key") }
        if outgoing.value(forHTTPHeaderField: "Authorization") != nil { outgoing.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        forwardingTask = session.dataTask(with: outgoing)
        forwardingTask?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        rejected = (response as? HTTPURLResponse).map { $0.statusCode >= 400 } ?? false
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if rejected { errorBytes.append(data) }
        else { client?.urlProtocol(self, didLoad: data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !errorBytes.isEmpty {
            client?.urlProtocol(self, didLoad: Data(Self.redacted(String(decoding: errorBytes, as: UTF8.self)).utf8))
        }
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
        session.finishTasksAndInvalidate()
        forwardingTask = nil
        self.session = nil
    }

    override func stopLoading() {
        forwardingTask?.cancel()
        session?.invalidateAndCancel()
    }
}

private extension URLSessionConfiguration {
    @objc dynamic class func catalogLiveDefault() -> URLSessionConfiguration {
        let configuration = catalogLiveDefault()
        configuration.protocolClasses = [CatalogLiveAuthProtocol.self] + (configuration.protocolClasses ?? [])
        return configuration
    }
}

private extension URLSession {
    @objc dynamic class func catalogLiveShared() -> URLSession {
        guard let session = CatalogLiveAuthProtocol.nonStreamingSession else { preconditionFailure("测试鉴权会话未安装") }
        return session
    }
}
