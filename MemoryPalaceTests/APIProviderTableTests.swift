import XCTest
@testable import 记忆花园

/// 预设数据表（plan-provider-presets §7）：老 17 家（+ Debug 的 kimi-p、本机模型）搬进表后，
/// 默认区域的 type / baseURL / extraHeaders / models 和改造前逐字相同；外加表结构断言。
final class APIProviderTableTests: XCTestCase {

    private struct Golden {
        let id: String
        let name: String
        let type: ProviderType
        let baseURL: String
        let extraHeaders: [String: String]
        /// nil = 运行时生成（本机模型跟着 AssistantLocalModel.catalog），另比
        let models: [(String, String)]?
    }

    /// 改造前从 APIProvider.swift 原件抓的金样。只有 doubao 的显示名按 Q10 改了（原「豆包 (Volcengine)」）
    private let golden: [Golden] = {
        var list = [
            Golden(id: "chatgpt-oauth", name: "GPT OAuth (账号登录)", type: .chatgptOAuth, baseURL: "https://chatgpt.com/backend-api/codex",
                   extraHeaders: [:],
                   models: [("gpt-5.2", "GPT-5.2")]),
            Golden(id: "anthropic", name: "Anthropic", type: .anthropic, baseURL: "https://api.anthropic.com/v1",
                   extraHeaders: ["anthropic-version": "2023-06-01"],
                   models: [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"), ("claude-haiku-5-5", "Claude Haiku 5.5"), ("claude-fable-5-1", "Claude Fable 5.1"), ("claude-opus-4-8", "Claude Opus 4.8"), ("claude-sonnet-4-6", "Claude Sonnet 4.6"), ("claude-opus-4-6", "Claude Opus 4.6"), ("claude-haiku-4-5", "Claude Haiku 4.5")]),
            Golden(id: "openai", name: "OpenAI", type: .openaiCompatible, baseURL: "https://api.openai.com/v1",
                   extraHeaders: [:],
                   models: [("gpt-4o", "GPT-4o"), ("gpt-4o-mini", "GPT-4o Mini"), ("gpt-4.1", "GPT-4.1"), ("gpt-4.1-mini", "GPT-4.1 Mini"), ("gpt-4.1-nano", "GPT-4.1 Nano"), ("o3", "o3"), ("o3-mini", "o3 Mini"), ("o4-mini", "o4 Mini")]),
            Golden(id: "openrouter", name: "OpenRouter", type: .openaiCompatible, baseURL: "https://openrouter.ai/api/v1",
                   extraHeaders: ["HTTP-Referer": "MemoryPalace/1.0", "X-Title": "MemoryPalace"],
                   models: [("anthropic/claude-sonnet-4", "Claude Sonnet 4"), ("anthropic/claude-haiku-4", "Claude Haiku 4"), ("anthropic/claude-sonnet-4.5", "Claude Sonnet 4.5"), ("openai/gpt-4o", "GPT-4o"), ("openai/gpt-4o-mini", "GPT-4o Mini"), ("openai/gpt-4.1", "GPT-4.1"), ("google/gemini-2.5-pro-preview", "Gemini 2.5 Pro"), ("google/gemini-2.5-flash-preview", "Gemini 2.5 Flash"), ("deepseek/deepseek-chat", "DeepSeek V3"), ("deepseek/deepseek-reasoner", "DeepSeek R1"), ("x-ai/grok-3-mini", "Grok 3 Mini")]),
            Golden(id: "deepseek", name: "DeepSeek", type: .openaiCompatible, baseURL: "https://api.deepseek.com/v1",
                   extraHeaders: [:],
                   models: [("deepseek-chat", "DeepSeek V3"), ("deepseek-reasoner", "DeepSeek R1")]),
            Golden(id: "groq", name: "Groq", type: .openaiCompatible, baseURL: "https://api.groq.com/openai/v1",
                   extraHeaders: [:],
                   models: [("llama-3.3-70b-versatile", "Llama 3.3 70B"), ("llama-3.1-8b-instant", "Llama 3.1 8B"), ("gemma2-9b-it", "Gemma 2 9B"), ("mixtral-8x7b-32768", "Mixtral 8x7B")]),
            Golden(id: "xai", name: "xAI", type: .openaiCompatible, baseURL: "https://api.x.ai/v1",
                   extraHeaders: [:],
                   models: [("grok-3", "Grok 3"), ("grok-3-mini", "Grok 3 Mini")]),
            Golden(id: "siliconflow", name: "SiliconFlow", type: .openaiCompatible, baseURL: "https://api.siliconflow.cn/v1",
                   extraHeaders: [:], models: []),
            Golden(id: "dashscope", name: "通义千问 (DashScope)", type: .openaiCompatible, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                   extraHeaders: [:], models: []),
            Golden(id: "zhipu", name: "智谱 (GLM)", type: .openaiCompatible, baseURL: "https://open.bigmodel.cn/api/paas/v4",
                   extraHeaders: [:], models: []),
            Golden(id: "doubao", name: "火山方舟（豆包）", type: .openaiCompatible, baseURL: "https://ark.cn-beijing.volces.com/api/v3",
                   extraHeaders: [:], models: []),
            Golden(id: "gemini", name: "Google Gemini", type: .openaiCompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                   extraHeaders: [:], models: []),
            Golden(id: "moonshot", name: "Moonshot / Kimi", type: .openaiCompatible, baseURL: "https://api.moonshot.cn/v1",
                   extraHeaders: [:], models: []),
            Golden(id: "ollama", name: "Ollama (本地)", type: .openaiCompatible, baseURL: "http://localhost:11434/v1",
                   extraHeaders: [:], models: []),
            Golden(id: "claude-p", name: "claude-p", type: .anthropic, baseURL: "",
                   extraHeaders: ["anthropic-version": "2023-06-01"], models: []),
            Golden(id: APICredential.localId, name: "本机模型", type: .localMLX, baseURL: "",
                   extraHeaders: [:], models: nil),
            Golden(id: "cc-bridge", name: "Claude Code (本地)", type: .ccBridge, baseURL: "ws://127.0.0.1:7890/cc",
                   extraHeaders: [:], models: [("cc-local", "Claude Code")]),
            Golden(id: "codex-bridge", name: "Codex (本地)", type: .ccBridge, baseURL: "ws://127.0.0.1:7890/cc",
                   extraHeaders: [:], models: [("codex-local", "Codex")]),
        ]
        #if PERSONAL_APPS && DEBUG
        list.append(Golden(id: "kimi-p", name: "kimi-p", type: .anthropic, baseURL: "http://192.168.31.20:8793",
                           extraHeaders: ["anthropic-version": "2023-06-01"],
                           models: [("k3", "Kimi K3"), ("k3-256k", "Kimi K3-256K")]))
        #endif
        return list
    }()

    /// 阶段 3 / 4 新增的 11 家（Kimi Code、阶跃排前面，plan Q1）
    private let newIds = ["kimi-code", "stepfun", "zai", "minimax", "xiaomi", "qianfan", "tencent", "huawei",
                          "together", "fireworks", "nvidia"]

    /// 不走 https 的：本机 / 局域网 / 桥
    private let localIds: Set<String> = ["ollama", "kimi-p", "cc-bridge", "codex-bridge", "claude-p", APICredential.localId]

    // MARK: 金样

    func testDefaultRegionMatchesGoldenVerbatim() {
        for g in golden {
            if g.id == APICredential.localId && !LocalLLMService.isSupported { continue }
            guard let p = APIProvider.preset(id: g.id) else { return XCTFail("预设 \(g.id) 不见了") }
            XCTAssertEqual(p.name, g.name, g.id)
            XCTAssertEqual(p.type, g.type, g.id)
            XCTAssertEqual(p.baseURL, g.baseURL, g.id)
            XCTAssertEqual(p.extraHeaders, g.extraHeaders, g.id)
            let expected = g.models ?? AssistantLocalModel.catalog.map { ($0.id, $0.title) }
            XCTAssertEqual(p.models.map(\.modelId), expected.map(\.0), g.id)
            XCTAssertEqual(p.models.map(\.name), expected.map(\.1), g.id)
            XCTAssertTrue(p.models.allSatisfy { $0.credentialId == g.id }, g.id)
            // 编辑器换家 / 新建时实际用的种子（区域种子可覆盖 p.models）
            let seeds = p.seedModels(in: p.defaultRegion, credentialId: p.id)
            XCTAssertEqual(seeds.map(\.modelId), expected.map(\.0), g.id)
            XCTAssertEqual(seeds.map(\.name), expected.map(\.1), g.id)
            XCTAssertTrue(seeds.allSatisfy { $0.credentialId == g.id }, g.id)
        }
    }

    func testPresetOrderUnchanged() {
        var expected = ["chatgpt-oauth", "anthropic", "openai", "openrouter", "deepseek", "groq", "xai",
                        "siliconflow", "dashscope", "zhipu", "doubao", "gemini", "moonshot", "ollama", "claude-p", "cc-bridge", "codex-bridge"]
        expected += newIds
        if LocalLLMService.isSupported { expected.insert(APICredential.localId, at: expected.firstIndex(of: "ollama")! + 1) }
        #if PERSONAL_APPS && DEBUG
        expected.insert("kimi-p", at: expected.firstIndex(of: "claude-p")! + 1)
        #endif
        XCTAssertEqual(APIProvider.presets.map(\.id), expected)
    }

    func testKimiPOnlyInPersonalDebug() {
        #if PERSONAL_APPS && DEBUG
        XCTAssertNotNil(APIProvider.preset(id: "kimi-p"))
        #else
        XCTAssertNil(APIProvider.preset(id: "kimi-p"), "Release 不带 kimi-p")
        #endif
    }

    // MARK: 结构

    func testIdsUniqueAndRegionsWellFormed() {
        let ids = APIProvider.presets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for p in APIProvider.presets {
            XCTAssertFalse(p.regions.isEmpty, p.id)
            let rids = p.regions.map(\.id)
            XCTAssertEqual(Set(rids).count, rids.count, p.id)
            XCTAssertFalse(rids.contains(CredentialDraft.ownRegion), p.id)
            for r in p.regions {
                XCTAssertFalse(r.protocols.isEmpty, "\(p.id)/\(r.id) 一个端点都没有")
                if !r.listsModels {
                    XCTAssertFalse(r.seedModelIds.isEmpty && p.models.isEmpty, "\(p.id)/\(r.id) 不拉 /models 就得有种子")
                }
            }
        }
    }

    func testEndpointsFollowBaseRules() {
        for p in APIProvider.presets {
            for r in p.regions {
                for (type, base) in r.endpoints where !base.isEmpty {
                    let tag = "\(p.id)/\(r.id)/\(type.rawValue)"
                    guard let url = URL(string: base), let scheme = url.scheme else { XCTFail("解析不了 \(tag)"); continue }
                    if !localIds.contains(p.id) { XCTAssertEqual(scheme, "https", tag) }
                    guard type == .openaiCompatible || type == .anthropic, p.id != "kimi-p" else { continue }
                    XCTAssertEqual(BaseURLNormalizer.normalize(base, type: type), base, "\(tag) 不是规整后的地址")
                    if type == .anthropic { XCTAssertTrue(base.hasSuffix("/v1"), "\(tag) Anthropic base 要带 /v1") }
                }
            }
        }
    }

    func testKeysURLsAreHTTPS() {
        for p in APIProvider.presets {
            for r in p.regions {
                if let u = r.keysURL { XCTAssertEqual(u.scheme, "https", "\(p.id)/\(r.id)") }
            }
        }
        for id in ["openai", "anthropic", "deepseek", "groq", "xai", "gemini", "zhipu", "dashscope", "doubao", "moonshot", "siliconflow", "openrouter"] {
            XCTAssertNotNil(APIProvider.preset(id: id)?.defaultRegion.keysURL, "\(id) 少了「去拿 key」")
        }
        // 补区域的老 5 家 + 新 11 家：每个区域都有「去拿 key」
        for id in ["zhipu", "dashscope", "doubao", "moonshot", "siliconflow"] + newIds {
            guard let p = APIProvider.preset(id: id) else { XCTFail("预设 \(id) 不见了"); continue }
            for r in p.regions { XCTAssertNotNil(r.keysURL, "\(id)/\(r.id) 少了「去拿 key」") }
        }
    }

    // MARK: 阶段 3 / 4

    func testNewPresetsAndRegions() {
        let expected: [String: [String]] = [
            "zhipu": ["payg", "coding"],
            "dashscope": ["cn-payg", "intl-payg", "coding-cn", "coding-intl", "token-cn", "token-intl"],
            "doubao": ["payg", "coding", "agent"],
            "moonshot": ["cn", "intl"],
            "siliconflow": ["cn", "intl"],
            "kimi-code": ["cn", "global"],
            "stepfun": ["plan-cn", "plan-intl", "payg-cn", "payg-intl"],
            "zai": ["payg", "coding"],
            "minimax": ["cn", "intl"],
            "xiaomi": ["plan-cn", "plan-sgp", "plan-ams", "payg"],
            "qianfan": ["personal", "team", "payg"],
            "tencent": ["plan", "hub-cn", "hub-intl"],
            "huawei": ["plan", "payg"],
            "together": ["default"], "fireworks": ["default"], "nvidia": ["default"],
        ]
        for (id, rids) in expected {
            XCTAssertEqual(APIProvider.preset(id: id)?.regions.map(\.id), rids, id)
        }
        XCTAssertEqual(APIProvider.preset(id: "zai")?.group, .overseas)
        for id in ["together", "fireworks", "nvidia", "siliconflow", "openrouter"] {
            XCTAssertEqual(APIProvider.preset(id: id)?.group, .aggregator, id)
        }
    }

    /// 老预设补了区域，默认区域的 id 和地址不动（老卡反查靠它）
    func testOldDefaultRegionIdsUnchanged() {
        let defaults = ["zhipu": "payg", "dashscope": "cn-payg", "doubao": "payg", "moonshot": "cn", "siliconflow": "cn"]
        for (id, rid) in defaults {
            XCTAssertEqual(APIProvider.preset(id: id)?.defaultRegion.id, rid, id)
        }
    }

    /// Q3：两种格式都有时，套餐区域默认 Anthropic、按量区域默认 OpenAI 兼容
    func testPlanRegionsDefaultToAnthropic() {
        for p in APIProvider.presets {
            for r in p.regions where r.offers(.openaiCompatible) && r.offers(.anthropic) {
                XCTAssertEqual(p.type(in: r, preferring: nil), r.isPlan ? .anthropic : .openaiCompatible, "\(p.id)/\(r.id)")
                XCTAssertEqual(p.type(in: r, preferring: .openaiCompatible), .openaiCompatible, "\(p.id)/\(r.id) 选了就听选的")
            }
        }
        XCTAssertEqual(APIProvider.preset(id: "kimi-code")?.type, .anthropic)
        XCTAssertEqual(APIProvider.preset(id: "xiaomi")?.type, .anthropic, "默认区域是 Token Plan")
        XCTAssertEqual(APIProvider.preset(id: "minimax")?.type, .openaiCompatible, "MiniMax 不分套餐，按按量算")
    }

    /// Q1 = A：官方条款限编程工具的 6 家套餐区域都挂条款提示 + 原文链接；明说允许的（Kimi Code、阶跃）不挂
    func testRestrictedPlansCarryTerms() {
        let restricted: Set<String> = ["zhipu/coding", "dashscope/coding-cn", "dashscope/coding-intl", "doubao/coding",
                                       "tencent/plan", "huawei/plan", "qianfan/personal", "qianfan/team"]
        var withTerms: Set<String> = []
        for p in APIProvider.presets {
            for r in p.regions {
                guard let terms = r.terms else { continue }
                withTerms.insert("\(p.id)/\(r.id)")
                XCTAssertTrue(r.isPlan, "\(p.id)/\(r.id) 只有套餐挂条款")
                XCTAssertEqual(terms.url.scheme, "https", "\(p.id)/\(r.id)")
                XCTAssertFalse(terms.summary.isEmpty)
            }
        }
        XCTAssertEqual(withTerms, restricted)
    }

    /// 不加任何冒充客户端的请求头（任务书禁区）：新预设一个请求头都不带
    func testNewPresetsCarryNoHeaders() {
        for id in newIds {
            XCTAssertEqual(APIProvider.preset(id: id)?.extraHeaders, [:], id)
        }
    }

    func testPlansWithoutModelListUseSeeds() {
        for (id, rid) in [("qianfan", "personal"), ("qianfan", "team"), ("tencent", "plan"), ("huawei", "plan")] {
            guard let p = APIProvider.preset(id: id), let r = p.region(id: rid) else { XCTFail("\(id)/\(rid)"); continue }
            XCTAssertFalse(r.listsModels, "\(id)/\(rid)")
            XCTAssertFalse(p.seedModels(in: r, credentialId: "c").isEmpty, "\(id)/\(rid)")
        }
        let qf = APIProvider.qianfan
        XCTAssertEqual(qf.seedModels(in: qf.region(id: "personal"), credentialId: "c").first?.modelId, "qianfan-code-latest")
        XCTAssertFalse(qf.region(id: "personal")!.seedModelIds.contains("glm-5"), "glm-5 只有企业版")
        XCTAssertTrue(qf.region(id: "team")!.seedModelIds.contains("glm-5"))
        XCTAssertTrue(APIProvider.preset(id: "qianfan")!.region(id: "payg")!.listsModels)
    }

    /// 老卡（选的是新区域的地址、没存 regionId）也能反查到新区域
    func testResolveNewRegionByURL() {
        let card = APICredential(id: "c", name: "卡", emoji: "🍐", presetId: "zhipu", type: .openaiCompatible,
                                 baseURL: "https://open.bigmodel.cn/api/coding/paas/v4")
        XCTAssertEqual(APIProvider.zhipu.resolveRegion(for: card)?.id, "coding")
        let old = APICredential(id: "c", name: "卡", emoji: "🍐", presetId: "dashscope", type: .openaiCompatible,
                                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(APIProvider.dashscope.resolveRegion(for: old)?.id, "cn-payg")
    }

    // MARK: 菜单 / 查询

    func testMenuSectionsCoverEveryPresetOnce() {
        let sections = APIProvider.menuSections
        XCTAssertEqual(sections.map(\.title), ["海外", "国内", "聚合平台", "本机与账号"])
        let flat = sections.flatMap { $0.presets.map(\.id) }
        XCTAssertEqual(flat.sorted(), APIProvider.presets.map(\.id).sorted())
        XCTAssertEqual(Set(flat).count, flat.count)
    }

    func testTypeInRegionFallsBackToOfferedProtocol() {
        let both = PresetRegion(id: "both", name: "两种", endpoints: [.openaiCompatible: "https://a.example/v1", .anthropic: "https://a.example/anthropic/v1"])
        let oaiOnly = PresetRegion(id: "oai", name: "只有 OpenAI", endpoints: [.openaiCompatible: "https://b.example/v1"])
        let p = APIProvider(id: "t", name: "T", group: .domestic, regions: [both, oaiOnly], defaultProtocol: .anthropic)
        XCTAssertEqual(p.type, .anthropic)
        XCTAssertEqual(p.baseURL, "https://a.example/anthropic/v1")
        XCTAssertEqual(p.type(in: both, preferring: .openaiCompatible), .openaiCompatible)
        XCTAssertEqual(p.type(in: oaiOnly, preferring: .anthropic), .openaiCompatible)
        XCTAssertEqual(p.type(in: oaiOnly, preferring: nil), .openaiCompatible)
    }

    func testSeedModelsPreferRegionSeeds() {
        let plan = PresetRegion(id: "plan", name: "套餐", endpoints: [.openaiCompatible: "https://p.example/v1"], seedModelIds: ["plan-a", "plan-b"])
        let payg = PresetRegion(id: "payg", name: "按量", endpoints: [.openaiCompatible: "https://q.example/v1"])
        let p = APIProvider(id: "t", name: "T", group: .domestic, regions: [payg, plan], defaultProtocol: .openaiCompatible,
                            models: [ProviderModel(credentialId: "t", modelId: "m1", name: "M 1")])
        XCTAssertEqual(p.seedModels(in: plan, credentialId: "c").map(\.modelId), ["plan-a", "plan-b"])
        XCTAssertEqual(p.seedModels(in: payg, credentialId: "c").map(\.modelId), ["m1"])
        XCTAssertEqual(p.seedModels(in: nil, credentialId: "c").map(\.name), ["M 1"])
        XCTAssertTrue(p.seedModels(in: plan, credentialId: "c").allSatisfy { $0.credentialId == "c" })
    }
}
