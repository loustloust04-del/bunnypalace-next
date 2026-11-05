import XCTest
@testable import 记忆花园

/// 小芽引导 key 卡（plan-onboarding-xiaoya-impl §3，H1 / H2）：作废规则、canTest / canSave、只有「就用这个」调落盘。
/// 测试和拉模型全用假闭包，不发网络、不碰卡表和钥匙串。humanReason 的映射测试归 P1a（ProviderProbe 那边）。
@MainActor
final class XiaoyaKeyCardModelTests: XCTestCase {

    private enum Outcome { case ok, fail401 }

    private func makeModel(_ outcome: Outcome) -> XiaoyaKeyCardModel {
        XiaoyaKeyCardModel(probe: { _, _, _ in
            switch outcome {
            case .ok:
                return .success(ProviderProbe.TestSuccess(summary: "", model: "gpt-4o-mini", fetchedModels: []))
            case .fail401:
                return .failure(ProviderProbe.Failure(status: 401, message: "API Key 无效（401）：Incorrect API key provided",
                                                      url: "https://api.openai.com/v1/chat/completions"))
            }
        }, fetch: { _, _ in
            .success(["gpt-4o-mini", "gpt-4.1"].map { ProviderModel(credentialId: "x", modelId: $0, name: $0) })
        })
    }

    /// 自定义中转 + 填好地址和 key，测一次
    private func tested(_ outcome: Outcome) async -> XiaoyaKeyCardModel {
        let model = makeModel(outcome)
        model.selectProvider(CredentialDraft.customSelection)
        model.setBaseURL("relay.example.com")
        model.setKey("sk-test")
        await model.test()
        return model
    }

    private func isEdit(_ m: XiaoyaKeyCardModel) -> Bool { m.phase == .edit }

    // MARK: 作废规则：四种改动 × 成功 / 失败

    func testEveryEditInvalidatesSucceededAndFailedResults() async {
        let edits: [(String, (XiaoyaKeyCardModel) -> Void)] = [
            ("换了服务商", { $0.selectProvider(APIProvider.anthropic.id) }),
            ("换了协议", { $0.setProtocol(.anthropic) }),
            ("改了地址", { $0.setBaseURL("relay2.example.com") }),
            ("改了 key", { $0.setKey("sk-test-2") }),
        ]
        for outcome in [Outcome.ok, .fail401] {
            for (prefix, edit) in edits {
                let model = await tested(outcome)
                switch (outcome, model.phase) {
                case (.ok, .succeeded), (.fail401, .failed): break
                default: XCTFail("测试后状态不对：\(model.phase)")
                }
                edit(model)
                XCTAssertTrue(isEdit(model), "\(prefix) 后应回编辑态")
                XCTAssertTrue(model.note?.hasPrefix(prefix) == true, "\(prefix) 的提示：\(model.note ?? "nil")")
                XCTAssertNil(model.pickedModel)
                XCTAssertFalse(model.canSave)
            }
        }
    }

    func testSameValueDoesNotInvalidate() async {
        let model = await tested(.ok)
        model.setKey("sk-test")
        model.setBaseURL("relay.example.com")
        model.setProtocol(.openaiCompatible)
        model.selectProvider(CredentialDraft.customSelection)
        guard case .succeeded = model.phase else { return XCTFail("没改动不该作废") }
        XCTAssertNil(model.note)
    }

    func testEditingBeforeAnyTestShowsNoNote() {
        let model = makeModel(.ok)
        model.selectProvider(APIProvider.anthropic.id)
        model.setKey("sk-1")
        XCTAssertTrue(isEdit(model))
        XCTAssertNil(model.note)
    }

    func testChangeProviderAfterSuccessGoesBackToEdit() async {
        let model = await tested(.ok)
        model.changeProvider()
        XCTAssertTrue(isEdit(model))
        XCTAssertEqual(model.note, "重新选服务商")
    }

    /// 测试在途时改了 key：回来的结果作废，不覆盖编辑态
    func testEditDuringTestDropsLateResult() async {
        var model: XiaoyaKeyCardModel!
        model = XiaoyaKeyCardModel(probe: { _, _, _ in
            await MainActor.run { model.setKey("sk-changed") }
            return .success(ProviderProbe.TestSuccess(summary: "", model: "gpt-4o-mini", fetchedModels: []))
        }, fetch: { _, _ in .success([]) })
        model.setKey("sk-original")
        await model.test()
        XCTAssertTrue(isEdit(model))
        XCTAssertEqual(model.note, "改了 key：要重新测")
        XCTAssertEqual(model.key, "sk-changed")
    }

    func testNextTestClearsNote() async {
        let model = await tested(.fail401)
        model.setKey("sk-test-2")
        XCTAssertNotNil(model.note)
        await model.test()
        XCTAssertNil(model.note)
    }

    // MARK: canTest

    func testCanTest() {
        let model = makeModel(.ok)
        XCTAssertFalse(model.canTest, "没 key 不能测")
        model.setKey("   ")
        XCTAssertFalse(model.canTest, "只有空白也不算")
        model.setKey("sk-1")
        XCTAssertTrue(model.canTest, "预设 + key 就能测")
        model.selectProvider(CredentialDraft.customSelection)
        XCTAssertFalse(model.canTest, "自定义中转没填地址不能测")
        model.setBaseURL("relay.example.com")
        XCTAssertTrue(model.canTest)
    }

    // MARK: canSave / 保存

    func testCanSaveOnlyAfterSuccessWithAModel() async {
        let failed = await tested(.fail401)
        XCTAssertFalse(failed.canSave)

        let model = await tested(.ok)
        XCTAssertTrue(model.canSave, "成功后默认选中推荐模型")
        guard case .succeeded(let s) = model.phase else { return XCTFail() }
        XCTAssertEqual(s.models.map(\.modelId).sorted(), ["gpt-4.1", "gpt-4o-mini"])
        XCTAssertEqual(s.models.first?.modelId, s.recommended, "推荐的排第一")

        model.setManualModel("my-model")
        XCTAssertNil(model.pickedModel, "手填会清掉单选")
        XCTAssertEqual(model.chosenModel, "my-model")
        model.setManualModel("  ")
        XCTAssertNil(model.chosenModel)
        XCTAssertFalse(model.canSave, "手填清空且没单选：不能存")
        model.pick("gpt-4.1")
        XCTAssertTrue(model.canSave)
    }

    func testSaveCallsCommitOnceWithDraftKeyAndModel() async {
        let model = await tested(.ok)
        model.pick("gpt-4.1")
        var calls: [(CredentialDraft, String, String)] = []
        let saved = model.save { draft, key, modelId in
            calls.append((draft, key, modelId))
            return "cred-123"
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0.presetSelection, CredentialDraft.customSelection)
        XCTAssertEqual(calls.first?.0.customBaseURL, "relay.example.com")
        XCTAssertEqual(calls.first?.0.models.map(\.modelId).sorted(), ["gpt-4.1", "gpt-4o-mini"])
        XCTAssertEqual(calls.first?.1, "sk-test")
        XCTAssertEqual(calls.first?.2, "gpt-4.1")
        XCTAssertEqual(saved, XiaoyaKeySaved(credentialId: "cred-123", providerName: "relay.example.com", modelId: "gpt-4.1"))
    }

    func testSaveRefusedWithoutSuccess() async {
        let model = await tested(.fail401)
        var called = false
        XCTAssertNil(model.save { _, _, _ in called = true; return "x" })
        XCTAssertFalse(called, "没测通不许落盘")
    }

    // MARK: 测试前手填模型（sol #8）

    /// 不给 /models 的中转：探测器的真实行为是「卡上没模型又拉不到清单就失败」，手填了模型就拿它发 hi
    private func relayWithoutModels(_ preferredSeen: @escaping (String?) -> Void) -> XiaoyaKeyCardModel {
        XiaoyaKeyCardModel(probe: { credential, _, preferred in
            preferredSeen(preferred)
            guard let model = ProviderProbe.testModel(preferred: preferred, lastUsed: nil, models: credential.models) else {
                return .failure(ProviderProbe.Failure(status: 404, message: "卡上还没有模型，地址不对（404）——手填一个模型 ID 再测",
                                                      url: "https://relay.example.com/v1/models"))
            }
            return .success(ProviderProbe.TestSuccess(summary: "", model: model, fetchedModels: []))
        }, fetch: { _, _ in .failure(ProviderProbe.Failure(status: 404, message: "404", url: nil)) })
    }

    func testManualModelBeforeTestIsPassedAsPreferredAndBecomesChoice() async {
        var seen: [String?] = []
        let model = relayWithoutModels { seen.append($0) }
        model.selectProvider(CredentialDraft.customSelection)
        model.setBaseURL("relay.example.com")
        model.setKey("sk-test")
        await model.test()
        guard case .failed = model.phase else { return XCTFail("没手填、拉不到清单：应失败") }

        model.setManualModel("  deepseek-chat ")
        XCTAssertEqual(model.testingModelHint, "deepseek-chat", "测试中那行报手填的模型")
        await model.test()
        XCTAssertEqual(seen, [nil, "deepseek-chat"], "手填的模型 ID 传给 ProviderProbe.test 的 preferredModelId")
        guard case .succeeded(let s) = model.phase else { return XCTFail("拿手填的模型测通") }
        XCTAssertEqual(s.testedModel, "deepseek-chat")
        XCTAssertEqual(model.chosenModel, "deepseek-chat", "测通的就是要存的")
        XCTAssertTrue(model.canSave)
        let saved = model.save { _, _, id in id }
        XCTAssertEqual(saved?.modelId, "deepseek-chat")
    }

    func testManualModelStillNeeds2xxToSave() async {
        let model = makeModel(.fail401)
        model.selectProvider(CredentialDraft.customSelection)
        model.setBaseURL("relay.example.com")
        model.setKey("sk-test")
        model.setManualModel("my-model")
        XCTAssertFalse(model.canSave, "没测不能存")
        await model.test()
        XCTAssertEqual(model.chosenModel, "my-model")
        XCTAssertFalse(model.canSave, "测不通照样不能存")
        XCTAssertNil(model.save { _, _, _ in XCTFail("不许落盘"); return "x" })
    }

    func testManualModelSurvivesFieldEditsButNotProviderChange() async {
        let model = await tested(.fail401)
        model.setManualModel("my-model")
        model.setKey("sk-test-2")
        XCTAssertEqual(model.manualModel, "my-model", "改 key 重测还用它")
        model.selectProvider(APIProvider.anthropic.id)
        XCTAssertEqual(model.manualModel, "", "换了家就清掉")
    }

    // MARK: 服务商列表 / 地址 / 推荐

    func testGuidedPresetsExcludeSingletonsAndLocal() {
        let ids = Set(XiaoyaKeyCardModel.guidedPresets.map(\.id))
        for excluded in [APIProvider.ccBridge.id, APIProvider.codexBridge.id, APIProvider.chatgptOAuth.id,
                         APICredential.localId, APIProvider.ollama.id, APIProvider.claudeP.id] {
            XCTAssertFalse(ids.contains(excluded), excluded)
        }
        for included in [APIProvider.openai.id, APIProvider.anthropic.id, APIProvider.gemini.id, APIProvider.openrouter.id] {
            XCTAssertTrue(ids.contains(included), included)
        }
    }

    func testEndpointPreviewUsesSaveNormalizer() {
        let model = makeModel(.ok)
        model.selectProvider(CredentialDraft.customSelection)
        XCTAssertNil(model.endpointPreview)
        model.setBaseURL("relay.example.com/")
        XCTAssertEqual(model.endpointPreview, "https://relay.example.com/v1/chat/completions")
        model.setProtocol(.anthropic)
        XCTAssertEqual(model.endpointPreview, "https://relay.example.com/v1/messages")
        XCTAssertEqual(model.draft.makeCredential(id: "x", existing: nil).baseURL, "https://relay.example.com/v1")
    }

    func testRecommendPicksCheapestPricedElseTested() {
        let models = ["big", "small", "embed-x"].map { ProviderModel(credentialId: "c", modelId: $0, name: $0) }
        let prices: [String: ModelPricing] = [
            "big": ModelPricing(10, 30),
            "small": ModelPricing(0.2, 0.8),
            "embed-x": ModelPricing(0.01, 0),
        ]
        XCTAssertEqual(XiaoyaKeyCardModel.recommend(models, tested: "big", price: { prices[$0] }), "small", "embedding 不算")
        XCTAssertEqual(XiaoyaKeyCardModel.recommend(models, tested: "big", price: { _ in nil }), "big")
    }

    func testUpstreamStripsOurPrefix() {
        let f401 = ProviderProbe.Failure(status: 401, message: "API Key 无效（401）：Incorrect API key", url: nil)
        XCTAssertEqual(XiaoyaKeyCardModel.upstream(of: f401), "Incorrect API key")
        let f404 = ProviderProbe.Failure(status: 404, message: "地址不对（404）——检查 Base URL 是不是到 /v1 为止：404 page not found", url: nil)
        XCTAssertEqual(XiaoyaKeyCardModel.upstream(of: f404), "404 page not found")
        let bare = ProviderProbe.Failure(status: 502, message: "服务端暂时不可用（502）", url: nil)
        XCTAssertNil(XiaoyaKeyCardModel.upstream(of: bare), "上游没给原文就不显示这行")
        let timeout = ProviderProbe.Failure(status: nil, message: "连不上：The request timed out.", url: nil)
        XCTAssertEqual(XiaoyaKeyCardModel.upstream(of: timeout), "The request timed out.")
    }
}
