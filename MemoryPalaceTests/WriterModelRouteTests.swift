import XCTest
@testable import 记忆花园

/// v5 A7 / B2：每项单选模型（空 = 跟提取模型）；C2 也默认跟提取模型，选了本机没装 / 在后台 → 这一轮用提取模型并写清
final class WriterModelRouteTests: XCTestCase {

    private let memory = ProviderModel(credentialId: "card-a", modelId: "cheap", name: "cheap-1")
    private let other = ProviderModel(credentialId: "card-b", modelId: "big", name: "big-2")

    func testWriterModelFollowsExtractUnlessPicked() {
        XCTAssertEqual(MemoryWriterModels.resolve(choice: "", memoryModel: memory, available: [memory, other]), memory)
        XCTAssertEqual(MemoryWriterModels.resolve(choice: other.id, memoryModel: memory, available: [memory, other]), other)
        XCTAssertEqual(MemoryWriterModels.resolve(choice: "card-x/gone", memoryModel: memory, available: [memory, other]), memory,
                       "卡停了 / 模型删了退回提取模型")
    }

    func testContextUsesPerWriterModel() {
        let profile = Profile(id: "p", name: "T", emoji: "🧪", description: "", userName: "粟粟", assistantName: "小克")
        let ctx = SessionCloseout.Context(profile: profile, model: memory, writerModels: [.window: other])
        XCTAssertEqual(ctx.model(.window), other)
        XCTAssertEqual(ctx.model(.timeline), memory, "没选的跟提取模型")
        XCTAssertEqual(SessionCloseout.Writer.window.usage, .windowSummary, "A3 记账单独一类（A11）")
        XCTAssertEqual(SessionCloseout.Writer.timeline.usage, .timeline)
        XCTAssertEqual(SessionCloseout.Writer.context.usage, .summary)
    }

    private func route(_ choice: String, supported: Bool = true, active: Bool = true, installed: Set<String> = [AssistantLocalModel.smart.id]) -> FragmentModelRoute.Resolved {
        FragmentModelRoute.resolve(choice: choice, memoryModel: memory, remoteModels: [memory, other],
                                   localSupported: supported, appActive: active, localInstalled: { installed.contains($0) })
    }

    private let smart = FragmentModelRoute.localPrefix + AssistantLocalModel.smart.id

    /// 10-15 实测后改：默认跟提取模型（本机装没装都一样），不弹「没下」提示
    func testFragmentDefaultsToExtract() {
        for installed in [Set([AssistantLocalModel.smart.id]), []] {
            let r = route("", installed: installed)
            XCTAssertEqual(r.route, .remote(memory))
            XCTAssertFalse(r.isLocal)
            XCTAssertNil(r.fallbackNote)
            XCTAssertFalse(r.localMissing, "默认不是本机：不弹「没下」提示")
        }
        XCTAssertNil(FragmentModelRoute.localModelId(choice: ""))
        XCTAssertEqual(route(smart).route, .local(modelId: AssistantLocalModel.smart.id), "选了聪明款、装了 → 本机")
    }

    /// 老值 "extract"：选择器勾在默认项上，路由照旧走提取模型；别的值原样
    func testLegacyExtractChoiceShowsAsDefault() {
        XCTAssertEqual(FragmentModelRoute.pickerChoice(FragmentModelRoute.extractChoice), "")
        XCTAssertEqual(FragmentModelRoute.pickerChoice(""), "")
        XCTAssertEqual(FragmentModelRoute.pickerChoice(smart), smart)
        XCTAssertEqual(FragmentModelRoute.pickerChoice(other.id), other.id)
        XCTAssertEqual(route(FragmentModelRoute.extractChoice), route(""))
    }

    func testFragmentLocalMissingFallsBackAndFlags() {
        let r = route(smart, installed: [])
        XCTAssertEqual(r.route, .remote(memory))
        XCTAssertTrue(r.localMissing, "选了本机没装：第一次碰到弹一次提示用")
        XCTAssertEqual(r.fallbackNote, "本机模型没下，这一轮用 cheap-1")
    }

    func testFragmentBackgroundOrUnsupportedFallsBack() {
        XCTAssertEqual(route(smart, active: false).route, .remote(memory))
        XCTAssertFalse(route(smart, active: false).localMissing)
        XCTAssertEqual(route(smart, supported: false).fallbackNote, "这台设备跑不了本机模型，这一轮用 cheap-1")
    }

    func testFragmentExplicitChoices() {
        XCTAssertEqual(route(FragmentModelRoute.extractChoice).route, .remote(memory))
        XCTAssertEqual(route(other.id).route, .remote(other))
        XCTAssertEqual(route(FragmentModelRoute.localPrefix + AssistantLocalModel.light.id, installed: [AssistantLocalModel.light.id]).route,
                       .local(modelId: AssistantLocalModel.light.id))
    }
}
