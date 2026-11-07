# plan · 多家预设：数据表 + 区域/套餐 + 一键登录

> ⚠️ **DON'T IMPLEMENT YET** —— 草稿 r1，等粟粟批注。
>
> 2026-10-15 · 工位 backend-3（HEAD facd4d3bf）· 只写了文档，没改代码、没编译、没提交。
> 输入：`docs/research-model-compat.html` §5、`docs/research-model-compat/magpie-providers.md`（magpie `a65cf52`）、`ohmypi-providers.md`（omp 18.10.2）。端点逐条对过 magpie `internal/provider/presets.go` 原文和 omp KDL 原文；两边缺失或矛盾的，用 WebFetch 查了官方文档（出处写在表里）。
> 粟粟已拍：先把预设改成「数据表 + 区域」；第一批加国内套餐全套 + Kimi Code 会员 key + OpenRouter 一键登录 + 3–4 家聚合商；额度卡放第二步；/models 宽容解析；Copilot 只进 Debug；ChatGPT 登录保留并加风险提示；Claude 订阅等不做。

---

## 0. 一页结论

- **结构**：`APIProvider` 原地升级成数据表的一行，下挂 `regions`（≥1 个，第一个是默认）。一个区域写清两种接口格式各自的 base、拿 key 链接、models.dev 目录 id、要不要拉 `/models`。卡上只**多存一个可选字段 `regionId`**，地址照旧存在 `baseURL`，发请求的路径一行不改。
- **迁移**：老卡 `regionId == nil`，用规整后的 `baseURL` 反查区域；反查不到就当「这张卡的地址是自己改过的」，原样用。**不写盘、不备份、不动钥匙串**。现有 17 家的默认区域 = 它们现在的地址，所以老卡、导入的配置、引导页的行为全不变。
- **新增**：11 家新预设；5 家老预设补区域；OpenRouter 加一键登录。区域条目一共新增 35 个（明细见 §3）。
- **⚠️ 查官方文档时的新发现**：**大多数编码套餐的官方条款写着「只给编程/AI 工具用」**，有几家明说在别的工具里用可能停订阅或封号：火山、阿里 Coding Plan、腾讯、华为、千帆、智谱。明确不限的有阶跃 Step Plan 和 Kimi Code（Kimi 只要求不伪造客户端标识）。这件事会影响上架和用户账号安全，列为 **Q1**，要你拍。
- **待核**：10 处（9 个区域端点 + 1 个拿 key 链接）只有单方来源，实现前或实现时实测确认（§3.3）。还有 1 条全局规则要实测：Anthropic 格式的 base 一律补 `/v1`（§2.4）。
- **分 8 个阶段**，每个阶段都能单独合并（§6）。额度/余额卡是阶段 7，开工前再细化一版。Copilot 推荐单独写一个小 plan。
- **待批问题 12 个**（§8），每个都带推荐。

---

## 1. 现状（只列和本 plan 有关的）

| 位置 | 现状 | 对本 plan 的意义 |
|---|---|---|
| `Models/APIProvider.swift:185-192` | `APIProvider` 只有 `id/name/type/baseURL/extraHeaders/models`，17 家写成 `static let`，`presets` 数组定顺序（`:196-212`）；`kimiP` 套 `#if PERSONAL_APPS && DEBUG`（`:205-210, 375-389`），`localMLX` 按 `LocalLLMService.isSupported` 插入 | 升级成数据表时，`#if` 的写法要原样保留 |
| `Models/APIProvider.swift:82-178` | `APICredential` 自写 Codable，所有可选字段都 `decodeIfPresent`/`encodeIfPresent`；未知 type 走 `.unsupported` 原样写回 | 加 `regionId` 照这个套路，老版本读新存档会忽略多出的 key |
| `Models/BaseURLNormalizer.swift:10-27` | 只在**路径为空**时补 `/v1`；聊天直接拼 `base + "/messages"` 或 `"/chat/completions"`（`:30-38`，`ChatService.swift:1204/1506`） | 厂商给的 Anthropic base（如 `…/api/anthropic`）路径不空，不会被补 `/v1`，直接拼会变成 `…/api/anthropic/messages`，是错的。**表里的 Anthropic base 必须自己带好 `/v1`**（§2.4） |
| `Models/ProviderProbe.swift:26-59` | 拉模型只认 `json["data"]`，每项只取 `id`、`display_name`；`/models` 不通就整张卡存不了（编辑器走「仍然保存」） | 要做宽容解析；不提供 `/models` 的套餐（千帆、腾讯、华为）要能直接用种子清单 |
| `Views/APICredentialEditor.swift:431-515` | 「提供商」段：一个 `.menu` Picker 列全部预设 + 自定义；预设下只读显示 Base URL 和「实际请求」 | 「套餐与地区」「接口格式」「拿 key」三行就加在这一段里，不新开页、不往页尾塞 |
| `APICredentialEditor.swift:1374-1398, 1429-1449` | 换提供商：草稿模型清单换成新家的；已存的卡换家要确认（K6），换完重新拉模型 | 换区域要不要等同于换家，见 Q4 |
| `APICredentialEditor.swift:816-883` | ChatGPT 登录段，页脚第三行写着「实验性：codex backend 未公开，可能随时不可用」 | 风险提示从这里改（§5.6） |
| `Models/APIDraftStore.swift:8-38` | 草稿用**合成的** Codable 存 `presetSelection/customType/...` | 新字段必须是 Optional：合成的 Decodable 不认属性默认值，旧草稿缺 key 时会整条解码失败 |
| `Services/ChatGPTOAuth/` | PKCE（`PKCE.swift`，`enum ChatGPTOAuthPKCE`）；mac 用 NWListener 监听 :1455，iOS 用 WKWebView 拦截或手动粘贴回调 URL；全仓没有 `ASWebAuthenticationSession`，也没注册 URL scheme | OpenRouter 登录可以直接复用 PKCE；回调方式见 §5.5 |
| `OAuthConfig.swift:36-40` | UA `codex_cli_rs/0.0.0 (MemoryPalace)`，`client_version=0.0.0` | 放进「待实测」，本 plan 不改 |
| 别处读预设的地方 | `ConfigImporter.swift:111-124`（导入时按 presetId 补模型）、`AppIconView.swift:141-191`（品牌图 / 首字母；注释写着「`APIProvider`/`APICredential` 不加字段」）、`OnboardingFlowView.swift:154-178, 744-776`（引导只给 OpenAI / Anthropic / OpenRouter + 自定义）、`ConversationViewModel.swift:2649`（按 presetId 找便宜模型） | 全部只读 `id/name/type/baseURL/models`。这几个保留成计算属性，这些地方都不用改。AppIconView 那句注释是图标那单的红线，本单要改字段，顺手把注释更新掉 |

---

## 2. 数据结构草案

### 2.1 预设（只读表，不持久化）

```swift
/// 一家预设 = 数据表一行。编辑器的默认值、拿 key 链接、种子模型都从这里来。
/// 卡上只存 presetId + regionId + 实际 baseURL；表改了不影响已存的卡。
struct APIProvider: Identifiable {
    let id: String                       // 稳定：老 17 家一个都不改名
    var name: String                     // 显示名
    var group: PresetGroup               // 菜单分节
    var regions: [PresetRegion]          // ≥1；第一个是默认。老预设的第一个 = 原 baseURL（迁移靠它）
    var regionLabel: String = "套餐与地区"
    var defaultProtocol: ProviderType    // 区域两种格式都有时默认用哪种（Q3）
    var extraHeaders: [String: String] = [:]
    var models: [ProviderModel] = []     // 种子清单（老字段，沿用）
    var login: PresetLogin = .apiKey

    // —— 兼容老 call site（Onboarding / ConfigImporter / AppIconView / 编辑器），语义不变 ——
    var type: ProviderType { defaultRegion.offers(defaultProtocol) ? defaultProtocol : defaultRegion.protocols[0] }
    var baseURL: String { defaultRegion.endpoints[type] ?? "" }
    var defaultRegion: PresetRegion { regions[0] }
}

enum PresetGroup { case account, overseas, domestic, aggregator, local }

/// 区域 / 套餐变体。切换时这一组端点、链接、目录 id 一起换。
struct PresetRegion: Identifiable, Equatable {
    let id: String                       // 稳定，会落进卡里；改显示名不改 id
    var name: String                     // 「Coding Plan · 国内」
    var endpoints: [ProviderType: String]// MP 口径的 base（§2.4）；账号/桥/本机类只放一个
    var keysURL: URL? = nil              // 「去拿 key」
    var docsURL: URL? = nil
    var catalogIds: [String] = []        // models.dev provider id，查价 / 显示名时优先这几家
    var listsModels: Bool = true         // false = 不问 /models，直接用 seedModelIds
    var seedModelIds: [String] = []      // 区域专属种子（套餐常和按量不同）；空 = 用 APIProvider.models
    var keyHint: String? = nil           // 输入框占位，例「sk-sp- 开头的套餐 key」
    var isPlan: Bool = false             // 套餐：编辑器多一行「套餐 key 只能填在这里」
    var terms: PlanTerms? = nil          // 条款提示（Q1）
    var quota: QuotaSource? = nil        // 阶段 7 才填

    var protocols: [ProviderType] { [.openaiCompatible, .anthropic, .chatgptOAuth, .ccBridge, .localMLX].filter { endpoints[$0] != nil } }
    func offers(_ t: ProviderType) -> Bool { endpoints[t] != nil }
}

struct PlanTerms: Equatable { var summary: String; var url: URL }

enum PresetLogin { case apiKey, openRouter /* key 或一键登录 */, chatgptOAuth, bridge, local, discovery }
```

- **为什么原地升级 `APIProvider`，不另起 `ProviderPreset`**：老 call site 只读 `id/name/type/baseURL/models`，保留成计算属性后一行都不用动（手术式）。
- **表放哪**：新文件 `Models/APIProviderTable.swift`，Swift 字面量（Q2）。`APIProvider.swift` 里那 17 个 `static let` 挪进新文件，`presets` 还是一个计算出来的数组，`#if PERSONAL_APPS && DEBUG`、`LocalLLMService.isSupported` 这两处插入规则照搬。
- `endpoints` 以 `ProviderType` 作键：账号类（`chatgptOAuth` → `chatgpt.com/backend-api/codex`）、桥类（`ccBridge` → `ws://…`）、本机（`localMLX` → `""`）也能用同一形状，`type`/`baseURL` 两个计算属性对这些预设给出的值和现在一样。

### 2.2 卡（持久化，只加一个可选字段）

```swift
struct APICredential {
    // …原字段不动…
    /// 选的是预设里哪个区域。nil = 老卡 / 自定义卡 / 导入的旧配置，用 baseURL 反查（§4）。
    var regionId: String?
}
```

`CodingKeys` 加 `regionId`；decode 用 `decodeIfPresent`，encode 用 `encodeIfPresent`。接口格式不另存，现有的 `type` 就是。

### 2.3 查询函数（纯函数，单测全覆盖）

```swift
extension APIProvider {
    static func preset(id: String?) -> APIProvider?
    func region(id: String?) -> PresetRegion?
    /// 卡 → 区域：regionId 命中就用；否则拿规整后的 baseURL 去比对每个区域的每个 endpoint；都不中返回 nil
    func resolveRegion(for card: APICredential) -> PresetRegion?
}
```

### 2.4 Base 口径规则（表里每条都按这个写，单测锁住）

- **OpenAI 兼容**：写厂商文档给的 base，原样写（`/api/coding/paas/v4`、`/api/coding/v3`、`/v2/tokenplan/personal` 这类路径都不再补 `/v1`）。聊天时拼 `/chat/completions`，拉模型时拼 `/models`。
- **Anthropic 兼容**：写**厂商 base + `/v1`**。Anthropic SDK 的约定是 `base + /v1/messages`，MP 拼的是 `base + /messages`。千帆官方页给的完整调用路径就是 `…/anthropic/tokenplan/personal/v1/messages`，正好证实这条规则。其余各家**实现时每家实测一次**。
- 表里每个 base 都必须满足 `BaseURLNormalizer.normalize(x) == x`（单测），这样「卡上存的就是规整后的」这条不变量继续成立。

---

## 3. 预设清单

图例：✅M = magpie 原文 · ✅O = omp 原文 · ✅官 = 官方文档（WebFetch 2026-10-15）· **待核** = 只有单方来源或两边矛盾 · 斜体 = 现有地址（老卡迁移锚点，不改）。表里 base 都是 §2.4 口径。

### 3.1 现有 17 家：5 家补区域，OpenRouter 加登录，其余只搬家

只搬家的老预设：`chatgpt-oauth`、`anthropic`、`openai`、`deepseek`、`groq`、`xai`、`gemini`、`ollama`、`claude-p`、`cc-bridge`、`codex-bridge`，以及表外插入的 `local-mlx`、`kimi-p`（Debug）。它们都是单区域，端点、模型、请求头一个字不改。

| id（不改） | 显示名 | 区域（第一个是默认） | OpenAI 兼容 base | Anthropic base | 拿 key | catalog | 出处 |
|---|---|---|---|---|---|---|---|
| zhipu | 智谱 GLM | **按量** | *open.bigmodel.cn/api/paas/v4* | open.bigmodel.cn/api/anthropic/v1 | open.bigmodel.cn/usercenter/proj-mgmt/apikeys | zhipuai | ✅M ✅O |
| | | **Coding Plan**（套餐） | open.bigmodel.cn/api/coding/paas/v4 | 同上 | 同上 | zhipuai | ✅M ✅O；条款✅官 |
| dashscope | 通义千问（百炼） | **国内 · 按量** | *dashscope.aliyuncs.com/compatible-mode/v1* | dashscope.aliyuncs.com/apps/anthropic/v1 | bailian.console.aliyun.com/?tab=model#/api-key | alibaba | ✅M |
| | | 国际 · 按量 | dashscope-intl.aliyuncs.com/compatible-mode/v1 | dashscope-intl.aliyuncs.com/apps/anthropic/v1 | modelstudio.console.alibabacloud.com/?tab=playground#/api-key | alibaba | ✅M |
| | | Coding Plan · 国内（套餐） | coding.dashscope.aliyuncs.com/v1 | coding.dashscope.aliyuncs.com/apps/anthropic/v1 | bailian.console.aliyun.com/?tab=model#/api-key | — | ✅O ✅官（key `sk-sp-`） |
| | | Coding Plan · 国际（套餐） | coding-intl.dashscope.aliyuncs.com/v1 | **待核** | modelstudio.console.alibabacloud.com/ | — | ✅O 单源 → **待核** |
| | | Token Plan · 国内（套餐） | token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1 | token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic/v1 | bailian.console.aliyun.com/cn-beijing/subscription/token-plan/personal | — | ✅O ✅官。magpie 写的是 `token-plan.maas.qianwenaiapi.com`，与官方不一致，以官方为准 |
| | | Token Plan · 国际（套餐） | token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1 | **待核** | home.qwencloud.com/billing/subscription/token-plan-individual | — | ✅O 单源 → **待核** |
| doubao | 火山方舟（豆包） | **按量** | *ark.cn-beijing.volces.com/api/v3* | — | ark.volcengine.com/region:cn-beijing/apikey | — | ✅M |
| | | Coding Plan（套餐） | ark.cn-beijing.volces.com/api/coding/v3 | ark.cn-beijing.volces.com/api/coding/v1 | 同上 | — | ✅M ✅官；条款✅官 |
| | | Agent Plan（套餐） | ark.cn-beijing.volces.com/api/plan/v3 | ark.cn-beijing.volces.com/api/plan/v1 | 同上 | — | ✅M 单源 → **待核** |
| moonshot | Moonshot / Kimi | **国内** | *api.moonshot.cn/v1* | api.moonshot.cn/anthropic/v1 | platform.moonshot.cn/console/api-keys | moonshotai | ✅M |
| | | 国际 | api.moonshot.ai/v1 | api.moonshot.ai/anthropic/v1 | platform.moonshot.ai/console/api-keys | moonshotai | ✅M ✅O |
| siliconflow | SiliconFlow | **国内** | *api.siliconflow.cn/v1* | — | cloud.siliconflow.cn/account/ak | siliconflow | ✅M ✅O |
| | | 国际 | api.siliconflow.com/v1 | — | **待核**（cloud.siliconflow.com） | siliconflow | ✅O（`openai-compat.ts:2139-2142`） |
| openrouter | OpenRouter | 单区域 | *openrouter.ai/api/v1* | — | openrouter.ai/keys | openrouter | 不变，`login = .openRouter`（阶段 5） |

> doubao 的显示名从「豆包 (Volcengine)」改成「火山方舟（豆包）」：套餐是方舟的产品，不是豆包的。改名只影响显示，id 不变。不想改就留原名（Q10）。

### 3.2 新增 11 家

| id | 显示名 | 分组 | 区域（第一个是默认） | OpenAI 兼容 base | Anthropic base | 拿 key | catalog | 要不要拉 /models | 出处 |
|---|---|---|---|---|---|---|---|---|---|
| kimi-code | Kimi Code 会员 | 国内 | **国内** | api.kimi.com/coding/v1 | api.kimi.com/coding/v1 | www.kimi.com/code/console | kimi-code-plan-cn | 拉 | ✅M ✅O ✅官 |
| | | | 海外 | api.kimi.ai/coding/v1 | api.kimi.ai/coding/v1 | 同上 | kimi-code-plan-global | 拉 | ✅M ✅官 |
| zai | Z.AI（智谱国际） | 海外 | **按量** | api.z.ai/api/paas/v4 | api.z.ai/api/anthropic/v1 | z.ai/manage-apikey/apikey-list | zhipuai | 拉 | ✅M ✅O |
| | | | Coding Plan（套餐） | api.z.ai/api/coding/paas/v4 | 同上 | 同上 | zhipuai | 拉 | ✅M ✅O |
| minimax | MiniMax | 国内 | **国内** | api.minimaxi.com/v1 | api.minimaxi.com/anthropic/v1 | **待核**（platform.minimaxi.com 已 302 到 platform.minimax.cn） | minimax | 拉 | ✅M ✅O |
| | | | 国际 | api.minimax.io/v1 | api.minimax.io/anthropic/v1 | platform.minimax.io/user-center/basic-information/interface-key | minimax | 拉 | ✅M ✅O |
| xiaomi | 小米 MiMo | 国内 | **Token Plan · 国内**（套餐） | token-plan-cn.xiaomimimo.com/v1 | token-plan-cn.xiaomimimo.com/anthropic/v1 | platform.xiaomimimo.com/token-plan | xiaomi-token-plan-cn | 拉 | ✅M ✅O |
| | | | Token Plan · 新加坡（套餐） | token-plan-sgp.xiaomimimo.com/v1 | token-plan-sgp.xiaomimimo.com/anthropic/v1 | 同上 | xiaomi | 拉 | ✅M ✅O |
| | | | Token Plan · 欧洲（套餐） | token-plan-ams.xiaomimimo.com/v1 | token-plan-ams.xiaomimimo.com/anthropic/v1 | 同上 | xiaomi | 拉 | ✅M ✅O |
| | | | 按量 | api.xiaomimimo.com/v1 | api.xiaomimimo.com/anthropic/v1 | platform.xiaomimimo.com/#/console/api-keys | xiaomi | 拉 | ✅M ✅O |
| qianfan | 百度千帆 | 国内 | **Token Plan · 个人**（套餐） | qianfan.baidubce.com/v2/tokenplan/personal | qianfan.baidubce.com/anthropic/tokenplan/personal/v1 | console.bce.baidu.com/qianfan/resource/token-plan | — | **不拉**（`/models` 404），用种子 | ✅M ✅官 |
| | | | Token Plan · 企业（套餐） | qianfan.baidubce.com/v2/tokenplan/team | qianfan.baidubce.com/anthropic/tokenplan/team/v1 | 同上 | — | 不拉 | ✅M 单源 → **待核** |
| | | | 按量 | qianfan.baidubce.com/v2 | qianfan.baidubce.com/anthropic/v1 | console.bce.baidu.com/iam/#/iam/apikey/list | — | 拉 | ✅M ✅O |
| tencent | 腾讯云 | 国内 | **Token Plan**（套餐） | api.lkeap.cloud.tencent.com/plan/v3 | api.lkeap.cloud.tencent.com/plan/anthropic/v1 | console.cloud.tencent.com/tokenhub/tokenplan | — | 不拉，用种子 | ✅M ✅官 |
| | | | TokenHub 按量 · 国内 | tokenhub.tencentmaas.com/v1 | tokenhub.tencentmaas.com/v1 | console.cloud.tencent.com/tokenhub/apikey | tencent-tokenhub | 拉 | ✅M 单源 → **待核** |
| | | | TokenHub 按量 · 国际 | tokenhub-intl.tencentmaas.com/v1 | tokenhub-intl.tencentmaas.com/v1 | console.tencentcloud.com/tokenhub/apikey | tencent-tokenhub | 拉 | ✅M 单源 → **待核** |
| huawei | 华为云 MaaS | 国内 | **Token Plan**（套餐） | api.modelarts-maas.com/plan/v2 | api.modelarts-maas.com/plan/anthropic/v1 | console.huaweicloud.com/modelarts/?#/model-studio/authmanage | — | 不拉，用种子 | ✅M ✅官 |
| | | | 按量 | api.modelarts-maas.com/openai/v1 | api.modelarts-maas.com/anthropic/v1 | 同上 | — | 拉 | ✅M 单源 → **待核** |
| stepfun | 阶跃星辰 | 国内 | **Step Plan · 国内**（套餐） | api.stepfun.com/step_plan/v1 | api.stepfun.com/step_plan/v1 | platform.stepfun.com/interface-key | stepfun-step-plan | 拉 | ✅M ✅官 |
| | | | Step Plan · 国际（套餐） | api.stepfun.ai/step_plan/v1 | api.stepfun.ai/step_plan/v1 | platform.stepfun.ai/interface-key | stepfun-ai-step-plan | 拉 | ✅M 单源 → **待核** |
| | | | 按量 · 国内 | api.stepfun.com/v1 | api.stepfun.com/v1 | platform.stepfun.com/interface-key | stepfun | 拉 | ✅M 单源 → **待核** |
| | | | 按量 · 国际 | api.stepfun.ai/v1 | api.stepfun.ai/v1 | platform.stepfun.ai/interface-key | stepfun-ai | 拉 | ✅M ✅O |
| together | Together AI | 聚合 | 单区域 | api.together.xyz/v1 | — | api.together.ai/settings/api-keys | togetherai | 拉 | ✅M ✅O |
| fireworks | Fireworks | 聚合 | 单区域 | api.fireworks.ai/inference/v1 | — | app.fireworks.ai/settings/users/api-keys | fireworks-ai | 拉 | ✅M ✅O |
| nvidia | NVIDIA NIM | 聚合 | 单区域 | integrate.api.nvidia.com/v1 | — | build.nvidia.com/settings/api-keys | nvidia | 拉 | ✅M ✅O |

说明：

- **MiniMax 不拆「按量 / Token Plan」**：两家报告都显示套餐 key 和按量 key 用同一组端点（magpie 注释 #387：`sk-cp-` 套餐 key 能读到额度窗口），所以只分国内/国际。输入框占位写「按量 key 或 Token Plan 的 key 都填这里」（Q11）。
- **阶跃的 Anthropic base**：官方给的是 `api.stepfun.com/step_plan`，按 §2.4 规则写成 `…/step_plan/v1`。按量区域同理，`api.stepfun.com` → `api.stepfun.com/v1`。
- **腾讯 TokenHub 的 Anthropic**：magpie 注释说 messages 在 `/v1/messages`，所以 base 写 `tokenhub….com/v1`。
- **种子清单**：千帆、腾讯 Plan、华为 Plan、火山两种 Plan 的种子，照抄 magpie 在 `presets.go` 写死的模型 id（例：千帆 `qianfan-code-latest, deepseek-v4.1-flash, …, glm-5`；腾讯 `tc-code-latest, glm-5.3, …, hy3`；火山 `ark-code-latest, doubao-seed-2.1-pro, …, kimi-k3`）。显示名由 `ModelCatalog` 补，补不到就用 id。
- **聚合商为什么挑这几家**（Q6）：Together、Fireworks、NVIDIA NIM 在两份报告里都有，都是纯 OpenAI 兼容加 key，没有怪癖。再加上给 SiliconFlow 补一个国际区。备选：OpenCode Go（$10/月套餐，有额度接口）、ZenMux、AiHubMix（国内常用中转）、HuggingFace Router、Mistral、Cerebras。

**数量**：新增预设 11 家；老预设补区域 5 家。新增区域条目 35 个：老预设新加 10 个（老的默认区域不算），新预设 25 个（其中 3 家聚合商各 1 个，真正的多区域变体是 22 个）。发布版预设从 17 家变成 28 家（kimi-p 不在发布版，local-mlx 看设备）。

### 3.3 待核清单（10 处）

| # | 项 | 现有来源 | 怎么核 |
|---|---|---|---|
| 1 | 阿里 Coding Plan · 国际：Anthropic base | 无（omp 只写了 OpenAI base） | 官方国际站文档；或让粟粟/测试 key 打一次 |
| 2 | 阿里 Token Plan · 国际：两个 base | omp 单源 | QwenCloud 文档 |
| 3 | 火山 Agent Plan：两个 base | magpie 单源（注释引其 Hermes 页） | 火山文档 |
| 4 | 千帆 Token Plan · 企业 | magpie 单源 | 千帆企业版文档 |
| 5 | 腾讯 TokenHub 按量 · 国内 | magpie 单源 | 腾讯云文档 1823/130078 |
| 6 | 腾讯 TokenHub 按量 · 国际 | magpie 单源 | tencentcloud.com 文档 1300/78939 |
| 7 | 华为 MaaS 按量 | magpie 单源 | 华为云文档 |
| 8 | 阶跃 Step Plan · 国际 | magpie 单源（官方页只列国内域名） | platform.stepfun.ai 文档 |
| 9 | 阶跃 按量 · 国内 | magpie 单源 | 同上 |
| 10 | MiniMax 国内拿 key 链接 | magpie 写 platform.minimaxi.com，现已 302 到 platform.minimax.cn | 打开确认落地页 |

另有一条全局规则要实测：**Anthropic base = 厂商 base + `/v1`**。千帆已由官方页证实，其余各家实现时打一次 `/messages` 确认。

**核不了怎么办**：区域还是加进表，名字后面不挂「测试版」之类的字样。编辑器本来就会显示「实际请求」地址，测试连接失败也会给出状态码和上游原因，用户能看到哪里不通。实现时如果有一处核实为错，直接删掉那个区域，不留半成品。

### 3.4 条款摘要（Q1 的依据，全部是 2026-10-15 WebFetch 官方页）

| 套餐 | 官方说法（摘要） | 来源页 |
|---|---|---|
| 智谱 GLM Coding Plan | 在规定工具以外调 API，用不了套餐额度 | docs.bigmodel.cn/cn/coding-plan/overview |
| 阿里 Coding Plan | 只限编程工具；明确禁止用在自定义应用后端、自动化脚本；违规可能暂停订阅或封 key | help.aliyun.com/zh/model-studio/coding-plan |
| 火山 Coding Plan | 额度只在 AI 编程工具里生效；在非编程工具里用这个地址和 key，可能被判滥用，停订阅或封号 | docs.volcengine.com/docs/82379/1925114 |
| 腾讯 Token Plan | 「严禁 API 调用」，只限 AI 工具（例子：Claude Code、CodeBuddy、OpenClaw）；违规可能停订阅或封 key | cloud.tencent.com/document/product/1823/130060 |
| 华为 Token Plan | 额度只在 AI 工具里生效；非 AI 工具里用可能被判滥用 | support.huaweicloud.com/Token-plan-maas/tokenplan-maas-0001.html |
| 千帆 Token Plan | 只限 AI 编程和智能体工具里交互式使用，不能用于应用后端 | cloud.baidu.com/doc/qianfan/s/Dmrabu8b6 |
| 阶跃 Step Plan | **不限工具**：走 Step Plan 地址的调用都算套餐额度 | platform.stepfun.com/docs/zh/step-plan/overview |
| Kimi Code 会员 | **允许第三方工具**；但必须保留工具真实的客户端标识（User-Agent），篡改算违规 | www.kimi.com/code/docs/en/ |
| Z.AI / 阿里 Token Plan / 小米 / MiniMax | 没查到原文（未查） | — |

我们自己的请求本来就用系统默认 UA，不冒充别的客户端，所以 Kimi 那条天然满足。**本 plan 也不允许给这些预设加任何伪装请求头**（写进任务书禁区）。

---

## 4. 迁移

- **卡表**：不写盘、不跑一次性迁移、不备份（只加可选字段，旧数据不碰）。
  - `regionId == nil` 的卡在需要时用 `resolveRegion(for:)` 现算：规整后的 `baseURL` 等于某区域某格式的 base，就算那个区域。
  - 老 17 家的默认区域 = 它们现在的地址（表里斜体那一列），所以老卡一定能反查到默认区域。
  - 反查不到（用户以前选 ollama 改过地址、或者 #092 A 规整前就是怪地址）：编辑器的「套餐与地区」行显示「用的是这张卡自己的地址」，不自动改卡。
- **编辑器保存时**才把 `regionId` 写进卡（`persist` 是唯一落盘入口，plan-api-wave1 review §2 的约定不变）。
- **旧版本读新存档**：`APICredential.init(from:)` 用的是 keyed container，多出的 `regionId` 会被忽略；旧版本再存一次时这个字段会丢，下次新版本又能反查回来，不损数据。
- **iCloud 钥匙串 / 设置导出导入**：key 不变。导出的 credentials 会带上 `regionId`；`ConfigImporter` 补模型时改成「有 regionId 就用这个区域的种子，没有就用默认区域」（`ConfigImporter.swift:116-122`）。
- **草稿**（`APIDraft`）：加 `regionSelection: String?`、`presetProtocol: String?`，**必须是 Optional**（理由见 §1）。旧草稿读出来是 nil，就按「预设默认区域 + 默认格式」恢复。
- **预设 id**：老 17 家一个都不改；新 id 一旦上线也不再改，以后要合并预设就加 `aliases` 表（magpie `presetAliases` 的做法），本 plan 用不到。

---

## 5. UI 改动

原则：全部在编辑页现有的「提供商」段里加行，不新开页、不往设置页尾巴塞新段。设置页的副文案只描述功能。界面色系是暖奶白 + 浅灰薄荷：链接和按钮用 `Theme.branchIndicator`，提示文字用 `Theme.textSecondary`/`textMuted`，不用蓝、不用黄（警示图标也用灰）。

### 5.1 新建卡：选预设 → 选区域

「提供商」段从上到下（★ 是新加的行）：

1. **提供商**（原有的 `.menu` Picker）→ 按 `group` 分节：「海外」「国内」「聚合平台」「本机与账号」，最后是「自定义」（Q10）。菜单行还是只放文字 + 品牌图（`.menu` 只认 Text/Image/Label，`APICredentialEditor.swift:435` 那条注释的限制还在）。
2. ★ **套餐与地区**（`.menu` Picker）：只在预设区域数 > 1 时出现。选项就是 `region.name`。
3. ★ 套餐区域的说明行（`isPlan` 时，小字灰）：「套餐 key 只能填在套餐地址上，按量的 key 填这里会被拒。」
4. ★ **接口格式**（分段控件「OpenAI 兼容 / Anthropic」）：只在当前区域两种格式都有时出现，默认用 `defaultProtocol`（Q3）。已存的卡**也允许切**（原来的「自定义」卡禁止切协议，是因为地址要用户自己配；预设区域两种格式的地址都已知，切换不会错位）。切换算「换家」，见 Q4。
5. Base URL（原有，只读）+「实际请求」（原有）：自动跟着区域和格式变。
6. ★ **去拿 key**：一行链接「去 {预设名} 拿 key ↗」，打开 `region.keysURL`（iOS 用 `openURL`，mac 用系统浏览器）。
7. ★ 条款提示行（`terms != nil` 时，Q1 选 A 才有），样式抄现成的 `textOnlyNote`（图标 + 灰色小字）：
   > {预设名}官方说明：套餐额度只给编程类工具用。在记忆花园里用是你自己的选择，可能被限额或停用。 **看原文 ↗**

「API Key」段（原有）：输入框占位改成 `region.keyHint ?? "sk-..."`，其余不动。

**状态与交互细节**

- 新加 `@State regionSelection`、`@State presetProtocol`，一起进 `DraftSnapshot` 和 `APIDraft`（判脏、保活都要带上）。
- 换提供商：区域重置为第一个，格式重置为 `defaultProtocol`（当前区域没有这种格式就用它有的那种）。
- 换区域 / 换格式：走现有的 `resetDraftModelsForProvider()`（测试结论作废，草稿模型换成该区域的种子）。已存的卡要不要先确认，见 Q4。
- `currentType` / `currentBaseURL` 改成从「预设 + 区域 + 格式」三者算出来；自定义卡和 ollama 的分支不变。
- 引导页（`OnboardingFlowView`）**不动**，还是只给 OpenAI / Anthropic / OpenRouter + 自定义（Q12）。

### 5.2 编辑已有卡

- 打开时 `regionSelection = card.regionId ?? resolveRegion(for: card)?.id`。都没有就显示一行灰字「用的是这张卡自己的地址」，区域 Picker 照样能选，选了就按换家处理。
- 「换提供商？」确认框（`:370-379`）的文案把区域带上：「换成『{预设名} · {区域名}』会清掉…」。

### 5.3 卡列表 / 模型池

本 plan 不改。阶段 7 额度卡会在卡列表行加一行小字，到时候再出图。

### 5.4 品牌图

新预设没有品牌图，自动走首字母圆片（`ProviderIcon.monogram`，按预设名取首字，比如「智」「腾」「华」「阶」）。补图另开小单，不在本 plan 里。

### 5.5 OpenRouter 一键登录（阶段 5）

位置：选 OpenRouter 时，「API Key」段输入框上方多一行按钮。

- 按钮：**用 OpenRouter 账号登录**（图标 `person.crop.circle.badge.checkmark`，薄荷色）
- 登录成功后：key 自动填进输入框（只进草稿，点「保存」才落盘，和手填 key 走同一条路），按钮下一行小字：「已拿到 key。这把 key 在你的 OpenRouter 账号里，叫『记忆花园』，不用了可以去 OpenRouter 网站删掉。」
- 失败：红字原因（取消登录不算失败，静默）。

流程：

1. PKCE S256（复用 `ChatGPTOAuthPKCE`，不改名）。
2. 授权 URL：`https://openrouter.ai/auth?callback_url=<回调>&code_challenge=<…>&code_challenge_method=S256&key_label=记忆花园&state=<随机>`（参数以官方文档为准，2026-10-15 WebFetch）。
3. 用 `ASWebAuthenticationSession` 打开，iOS 和 mac 各一份。它不需要在 Info.plist 注册 URL scheme；mac 要提供 presentation anchor（设置窗口）。
4. 回调拿到 `code`（带了 `state` 就校验；omp 说 OpenRouter 不回传 state，官方文档说原样回传，所以**有就校验，没有就靠 PKCE**）。
5. `POST https://openrouter.ai/api/v1/auth/keys`，JSON `{code, code_verifier, code_challenge_method:"S256"}` → `{key}`。
6. 可选：`GET /api/v1/auth/key` 验一下 key（omp 用它做粘贴 key 的校验）。

**回调地址怎么选（Q7）**：官方文档只写了支持 `http://localhost:任意端口` 和公开的 https 网址，**没说自定义 scheme 行不行**。

- 推荐：先用自定义 scheme `memorygarden-oauth://openrouter` 实测。能用的话，两端都只走 `ASWebAuthenticationSession`，最省事。
- 不行的话：mac 改用 localhost 随机端口 + NWListener（照 `LoginCoordinator.waitForCallback` 的写法）。iOS 用官方的「无回调模式」：不带 `callback_url`，网页会显示授权码，用户复制回来粘贴。这一步复用 ChatGPT 登录那套「粘贴」行的样式。

新文件：`Services/ProviderOAuth/OpenRouterLogin.swift`，纯网络 + 拼 URL，单测覆盖。编辑器里只加按钮和状态。

### 5.6 ChatGPT 登录：风险提示（阶段 6）

- **常驻一行**（未登录、已登录都显示），放在登录按钮上方，样式同 `textOnlyNote`，图标 `exclamationmark.triangle`，用灰色：
  > 这个登录借用的是 Codex 命令行工具的通道，不是 OpenAI 给第三方 app 开放的正式接口。OpenAI 随时可能关掉它，也可能限制你的账号。不想冒这个险，就用 OpenAI 的 API key。
- **第一次点「用 ChatGPT 账号登录」时弹确认框**（`@AppStorage("chatgptOAuthRiskAcked")`，确认过一次就不再弹）：
  - 标题：用 ChatGPT 账号登录？
  - 正文：这种登录方式不是 OpenAI 正式开放给第三方的，可能随时失效，也可能影响你的账号。
  - 按钮：「我知道了，继续登录」 /「取消」
- 页脚（`:879`）第三行「实验性：codex backend 未公开，可能随时不可用。」**删掉**，和常驻那行重复了。前两行只描述功能，保留。
- 「设置副文案只描述功能」这条：风险话术只出现在编辑页的提示行和确认框里，不进设置页列表的副标题。

**UA 待实测（本 plan 不改代码）**：`codex_cli_rs/0.0.0`、`client_version=0.0.0`（`OAuthConfig.swift:36-40`）可能让后端不放行新模型（magpie `codex_request.go:23-27`；omp 钉 `0.159.0`）。实测步骤写在阶段 6 清单里。结果写进 `docs/now/backend-3.md`，要改版本号另开单。

### 5.7 额度 / 余额卡（阶段 7，开工前再细化一版）

- 数据：`PresetRegion.quota: QuotaSource?`

  ```swift
  enum QuotaSource {
      case planWindows(url: String, bareKeyAuth: Bool, reader: PlanReader)  // GLM / Z.AI / Kimi Code / MiniMax
      case balance(url: String, currency: String, reader: BalanceReader)    // DeepSeek / Moonshot / OpenRouter / SiliconFlow
  }
  ```

  端点（magpie `planquota.go:33-60`、`balance.go:50-66`）：
  - 智谱 `open.bigmodel.cn/api/monitor/usage/quota/limit`（Authorization 直接放裸 key，不带 Bearer）
  - Z.AI `api.z.ai/api/monitor/usage/quota/limit`
  - Kimi Code `{base}/usages`（Bearer）
  - MiniMax `{host}/v1/token_plan/remains`（只有套餐 key 有返回）
  - DeepSeek `api.deepseek.com/user/balance`
  - Moonshot `api.moonshot.{cn,ai}/v1/users/me/balance`
  - OpenRouter `openrouter.ai/api/v1/credits`
  - SiliconFlow `api.siliconflow.{cn,com}/v1/user/info`
- 什么时候拉：打开编辑页、打开 API 列表时拉，缓存 5 分钟，**不后台轮询**。拉失败就不显示，不报错。
- 显示：编辑页「提供商」段末尾加一行「本周期剩 62% · 3 小时后重置」/「余额 ¥12.30」。API 列表行的副标题后面加同样的短文字。这两处都在原框架里，具体样子出小样再定。
- 解析器照 magpie 的 reader 写，**测试样本用真响应（脱敏）**，别自己编 JSON（magpie LESSONS.md:27-35 的教训）。
- 和现有「对账」（`UsageReconciliationSection`，OpenRouter 用 key 识别）不合并，两者互不影响。

### 5.8 Copilot 设备码（推荐单列，Q8）

只写个形状，供单列 plan 参考：
- 只进 `#if PERSONAL_APPS && DEBUG`，和 `kimiP` 一样。
- 设备码 `github.com/login/device/code`，scope `read:user`。
- 卡用 `.openaiCompatible`，baseURL `https://api.githubcopilot.com`，key 存 GitHub token，客户端请求头放 `extraHeaders`。
- **待核**：omp 是长效 token 直接用（`github-copilot.ts:233-247`）；magpie 要先用 `copilot_internal/v2/token` 换短期 token（`account.go:951`）。要是必须换短期 token，就得加刷新逻辑，不能当普通 key 卡用，这也是推荐单列的原因之一。

---

## 6. 分阶段（每阶段一个可单独合并的分支提交组）

| 阶段 | 内容 | 用户能看到的变化 | 依赖 |
|---|---|---|---|
| **1 · 表结构 + 迁移** | `APIProviderTable.swift`；`APIProvider` 升级；`PresetRegion`；`APICredential.regionId`；`resolveRegion`；编辑器加「套餐与地区」「接口格式」「去拿 key」三行；`APIDraft` 加字段；ConfigImporter 走区域种子。**只把现有 17 家搬进表，端点一个不改** | 编辑页多一行「去拿 key」，别的看不出变化 | — |
| **2 · /models 宽容解析 + 种子清单** | `ProviderProbe` 能解 `data / models / result / items` 几种包法和裸数组，每项可以是字符串或对象（取 `id ‖ model ‖ name`）；读 `context_length ‖ context_window`、`architecture.input_modalities ‖ input_modalities`；`listsModels == false` 时不发请求、直接回种子；拉模型优先打区域的 OpenAI base（Anthropic 格式的卡也一样，因为很多 Anthropic 兼容端点没有 `/models`）；元数据存旁表（Q5） | 有些以前拉不到模型的中转能拉到了 | 1 |
| **3 · 国内套餐全套 + Kimi Code** | §3.1 的 5 家补区域（openrouter 除外）+ §3.2 的 8 家国内/海外厂商；条款提示行（看 Q1） | 新预设、新区域 | 1、2 |
| **4 · 聚合商** | Together / Fireworks / NVIDIA NIM（Q6） | 3 家新预设 | 1 |
| **5 · OpenRouter 一键登录** | §5.5 | OpenRouter 卡多一个登录按钮 | 1（不依赖 3） |
| **6 · ChatGPT 风险提示 + UA 实测** | §5.6 | 提示行 + 首次确认 | 无，可以最先合 |
| **7 · 额度 / 余额卡** | §5.7（开工前单独补一版细化） | 额度、余额小字 | 3 |
| **8 · Copilot（Debug）** | 推荐单列 plan（Q8） | 只有粟粟的 Debug 包有 | — |

阶段 1 的提交拆分：① 表 + 结构体 + 计算属性（零行为变化）② 卡字段 + 反查 ③ 编辑器 UI ④ 草稿 / 导入。每个提交都能单独 revert。

**和兼容线（research-model-compat P0/P1）的接口点**（只标出来，不展开）：

- **能力位 I**：阶段 2 解析出的 `context_length` / `input_modalities` 就是 I 要的输入。存储位置要和那条线一起定（Q5）。我这边只负责「解析 + 写进旁表」，消费方（看图拦截、上下文窗口）归那条线。
- **ResolvedCompat E**：区域可以给 E 当「部署契约」的输入（比如 `thinkingFormat` 按区域定）。本 plan 不往区域里加任何兼容开关；E 开工时，在 `PresetRegion` 上加字段即可。
- **思考显示 B**：套餐默认走 Anthropic 格式（Q3），就不依赖 B。B 落地后可以重新评估默认值。
- **ModelCatalog**：`catalogIds` 作为查找时的优先 provider 提示。现在 `ModelCatalog.lookup` 只按模型 id 全局查（`ModelCatalog.swift:225-243`），加 `model(for:preferring:)` 是阶段 2 的可选项，做不做看 Q5 的结论。

---

## 7. 测试

**跑法**：工位暂停本地编译，只跑测试。

- mac 单测：
  ```
  xcodegen generate && xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/<类名>
  ```
  只认输出里的 `Test Suite '<类名>' passed` 和 `** TEST SUCCEEDED **`。跑之前先正常退出粟粟的记忆花园.app（测试宿主和她用同一个库）。
- iOS：
  ```
  xcodebuild build-for-testing -scheme MemoryPalaceIOS -destination 'platform=iOS Simulator,id=<iOS 26 模拟器>'
  ```
  只认 `** TEST BUILD SUCCEEDED **`，并且输出里没有 `error:`。
- 正式编译、装 sim 验 UI，由 Warden 在集成区做。交合并时 `--why` 里写「要验 UI」和验收步骤。

**新增 / 修改的测试类**

| 测试类 | 覆盖 |
|---|---|
| `APIProviderTableTests`（新） | 预设 id 唯一；每家 ≥1 个区域、区域 id 在家内唯一；**老 17 家的 id 都在，默认区域的 type/baseURL/models/extraHeaders 和改造前逐字相同**（金样，改造前先抓下来）；所有 URL 能解析、是 https（ollama、桥、本机除外）；`normalize(base) == base`；Anthropic base 以 `/v1` 结尾；`keysURL` 是 https；`listsModels == false` 的区域种子不能为空；Release 配置下 kimi-p 不在表里 |
| `APICredentialRegionTests`（新） | 不带 `regionId` 的旧 JSON 解码 → nil；带 `regionId` 的往返编解码；`resolveRegion`：regionId 命中 / regionId 未知时退回 URL 反查 / URL 反查命中非默认区域 / 改过地址的卡 → nil；`.unsupported` 卡不受影响 |
| `ProviderProbeDiscoveryTests`（新） | 裸数组、`data`、`models`、`result`、`items`、字符串项、对象项；`context_length`、`architecture.input_modalities`；非聊天模型过滤（原 `isNonChatListing`）；`listsModels == false` 时不发请求（用 URLProtocol 桩计数）；Anthropic 卡拉模型打 OpenAI base。**样本用真响应**：OpenRouter `/api/v1/models` 是公开接口，可以直接抓；其余家用文档里的示例，注明出处 |
| `APIDraftStoreTests`（改） | 旧草稿（没有新字段）能解出来；新字段往返 |
| `ConfigImporterTests`（改或新） | 带 `regionId` 的导入用区域种子；不带的用默认区域 |
| `OpenRouterLoginTests`（新，阶段 5） | 授权 URL 参数；回调解析（code / error / 用户取消）；state 有就校验、没有也放行；换 key 的请求体（用 URLProtocol 桩）；返回体缺 `key` 时报错 |
| `QuotaReaderTests`（新，阶段 7） | 每家一份真响应（脱敏）样本 |

**手动验收（交给粟粟 / 集成区，sim 上做）**

1. 阶段 1：新建卡选「智谱 GLM」→ 区域行不出现（这时还没补区域）→ 「去拿 key」能打开；编辑一张老 DeepSeek 卡 → 什么都没变 → 保存 → 聊天正常。
2. 阶段 3：新建「Kimi Code 会员 · 国内」，Anthropic 格式，填测试 key → 测试连接通过 → 聊一句（需要粟粟的会员 key，或者跳过）；选「百度千帆 · Token Plan 个人」→ 不填 key 也能看到种子模型清单。
3. 阶段 5：OpenRouter 一键登录在 sim 和 mac 上各走一次，拿到 key → 保存 → 聊一句。
4. 阶段 6：ChatGPT 卡看到提示行；第一次点登录弹确认框，第二次不弹。

---

## 8. 待粟粟批注

> 每条都写了推荐。⧫ 写在这里就行。

**Q1（新发现，最要紧）· 套餐条款限「编程 / AI 工具」怎么办？**（依据 §3.4）
- A：照加，每个受限区域显示一行条款提示 +「看原文」链接；不冒充任何客户端；App Store 描述里不拿这些套餐做卖点；明确允许的（阶跃、Kimi Code）排在前面。
- B：发布版只放明确允许的（阶跃 Step Plan、Kimi Code）加没查到原文的（小米、MiniMax、Z.AI、阿里 Token Plan）；其余受限套餐只进 Debug。
- C：受限套餐全不加。

推荐 **A**。key 是用户自己的，选择也是用户自己的；我们讲清楚、不伪装，审核和厂商那边都站得住。几家条款列举的工具里也有 OpenClaw 这类通用 agent，「AI 工具」的边界本来就宽。

**Q2 · 表放哪？** Swift 字面量（编译期检查，不会出现解析失败的分支） vs 打包 JSON（以后能做远程更新）。推荐 **Swift**。远程更新等真有需要再说。

**Q3 · 两种格式都有时，默认用哪种？** 推荐：**套餐区域默认 Anthropic，按量区域默认 OpenAI 兼容（维持现状）**。理由：现在 OpenAI 兼容这条路不解析思考，DeepSeek / Kimi 的工具第二轮可能 400（兼容 research P0 B/C，推断未实测）；Anthropic 这条路思考和签名都通，这几家的 Anthropic 端点又是给 Claude Code 专门做的。等兼容线 B/C 合进来再评估。

**Q4 · 已存的卡换「套餐与地区」/「接口格式」，算不算换家？** 推荐 **算**：弹确认框，清掉旧模型重新拉。套餐和按量的模型清单常常不一样，留着旧模型聊天会 4xx。只换格式也算，因为两种格式的模型 id 可能不同（MiniMax 的大小写就是一例）。

**Q5 · 拉到的 context_length / input_modalities 存哪？**
- A：旁表（新文件 `ModelHints`，按「卡/模型」存，`ModelCatalog` 查找时先看它）。
- B：直接给 `ProviderModel` 加两个可选字段。

推荐 **A**。`ProviderModel` 是 Hashable，合成的相等判断会把新字段算进去，同 id 的模型可能变成「不相等」，牵连收藏、选择器这些用它当 tag 的地方。存储位置最好和兼容线 I 一起定，A 对那边的牵连最小。

**Q6 · 聚合商挑哪几家？** 推荐 **Together、Fireworks、NVIDIA NIM，再给 SiliconFlow 补国际区**。备选：OpenCode Go、ZenMux、AiHubMix、HuggingFace、Mistral、Cerebras。想换哪家直接划掉、写上新的。

**Q7 · OpenRouter 登录的回调？** 推荐 **先实测自定义 scheme**（两端都只走 ASWebAuthenticationSession）；不行的话 mac 退到 localhost 监听，iOS 退到复制授权码。

**Q8 · Copilot 放本 plan 末阶段还是单列？** 推荐 **单列**。它只进 Debug、要伪装成 Copilot 客户端、可能要刷新 token，风险评估和审查路线都和本 plan 不同。放在一起会拖住其他阶段的合并。

**Q9 · ChatGPT 风险提示的强度？** 推荐 **常驻一行 + 第一次登录前确认**。只改页脚太弱，每次登录都弹又太烦。

**Q10 · 预设菜单分节，以及「豆包」改名？** 推荐分「海外 / 国内 / 聚合平台 / 本机与账号 / 自定义」五节；doubao 显示名改成「火山方舟（豆包）」，id 不变。

**Q11 · MiniMax 不拆按量 / 套餐，只拆国内 / 国际？** 推荐 **是**：两边是同一组端点，拆开反而让人选错。

**Q12 · 引导页要不要加套餐入口？** 推荐 **不加**。引导页只管「最快能聊上」，套餐是进阶选择，等设置里跑稳了再说。

---

## 9. 不做

- **订阅登录不做**：Claude Pro/Max 订阅、Gemini CLI、Antigravity、Cursor、Devin / Kiro / Zed / Factory / Qoder 等。已记 backlog；以后做必须带风险警示。
- **SIWC（Sign in with ChatGPT）**：要先查 OpenAI 条款（research §5 档 2、Q6），不在本 plan。
- Kimi Code OAuth、xAI 设备码：有 key 就够了。
- 给任何预设加冒充官方客户端的请求头。
- 改 `OAuthConfig` 的 UA / 版本号（只实测）。
- 新预设的品牌图、OpenRouter 的 `HTTP-Referer: MemoryPalace/1.0`（不是 URL，归因可能不生效，另记一笔）。
- 引导页改动、卡列表 UI 改动（阶段 7 之前）。
- 兼容线的 ResolvedCompat / 思考解析 / 错误重试（另一个 plan）。

---

## 10. Todo（颗粒度清单）

### 阶段 0 · 核对（不改代码，可以和阶段 1 并行）
- [ ] 改造前抓金样：现有 17 家（含 Debug 的 kimi-p）的 `id/name/type/baseURL/extraHeaders/models` 序列化进测试 fixture
- [ ] §3.3 待核 1–10 逐条查官方文档，结论回填 §3 表（核实为错的区域直接删）
- [ ] §3.4「未查」的 4 家（Z.AI、阿里 Token Plan、小米、MiniMax）补查条款
- [ ] OpenRouter：用自定义 scheme 的 `callback_url` 手动走一遍授权页，看接不接受（只看页面，不换 key）

### 阶段 1 · 表结构 + 迁移
- [ ] 新建 `Models/APIProviderTable.swift`：`PresetGroup` / `PresetRegion` / `PlanTerms` / `PresetLogin`
- [ ] `APIProvider` 加 `group/regions/regionLabel/defaultProtocol/login`；`type`/`baseURL` 改成计算属性
- [ ] 17 个 `static let` 挪进表，保留 `#if PERSONAL_APPS && DEBUG` 和 `LocalLLMService.isSupported` 的插入规则
- [ ] `APIProviderTableTests`：金样逐字相同 + §7 的结构断言
- [ ] `APICredential` 加 `regionId`（CodingKeys / decodeIfPresent / encodeIfPresent / init 参数默认 nil）
- [ ] `APIProvider.preset(id:)` / `region(id:)` / `resolveRegion(for:)`
- [ ] `APICredentialRegionTests`
- [ ] 编辑器：`@State regionSelection` / `presetProtocol`；`currentType` / `currentBaseURL` 按三者计算
- [ ] 编辑器：「套餐与地区」Picker（区域 > 1 时出现）、「接口格式」分段（两种格式都有时出现）、「去拿 key」链接行、套餐说明行、`keyHint` 占位
- [ ] 编辑器：`makeDraft` 写 `regionId`；`providerChanged` 把区域和格式算进去（看 Q4）；确认框文案带上区域名
- [ ] 编辑器：`loadIfNeeded` 用 `regionId ?? resolveRegion`；反查不到时显示「用的是这张卡自己的地址」
- [ ] `DraftSnapshot` + `APIDraft` 加两个 Optional 字段；`APIDraftStoreTests` 补旧草稿兼容
- [ ] `ConfigImporter` 按区域补种子模型 + 测试
- [ ] `AppIconView.swift:141-146` 那句「不加字段」的注释改成现状
- [ ] 预设菜单分节（Q10）
- [ ] mac 定向单测 `** TEST SUCCEEDED **`；iOS `build-for-testing` `** TEST BUILD SUCCEEDED **`
- [ ] `docs/now/backend-3.md` 更新；交合并（`--why` 写验收步骤 1）

### 阶段 2 · /models 宽容解析 + 种子
- [ ] `ProviderProbe.parseModelList(_:)` 纯函数：各种包法、字符串项 / 对象项、`id ‖ model ‖ name`
- [ ] 读 `context_length ‖ context_window`、`architecture.input_modalities ‖ input_modalities`
- [ ] 元数据落旁表 `ModelHints`（Q5 = A 时）
- [ ] `listsModels == false` 时直接回种子、不发请求
- [ ] 拉模型优先用区域的 OpenAI base（Anthropic 格式的卡也一样）
- [ ] 抓 OpenRouter `/api/v1/models` 真样本存 fixture；`ProviderProbeDiscoveryTests`
- [ ] （可选，看 Q5）`ModelCatalog.model(for:preferring:)`
- [ ] 单测 + iOS build-for-testing；now 文档；交合并

### 阶段 3 · 国内套餐全套 + Kimi Code
- [ ] zhipu 补 Coding Plan 区域
- [ ] dashscope 补国际按量、Coding Plan 国内/国际、Token Plan 国内/国际
- [ ] doubao 补 Coding Plan / Agent Plan + 种子；显示名改成「火山方舟（豆包）」（看 Q10）
- [ ] moonshot 补国际区；siliconflow 补国际区
- [ ] 新增 kimi-code / zai / minimax / xiaomi / qianfan / tencent / huawei / stepfun（共 8 家）+ 各自的种子
- [ ] 每个区域写 `keysURL` / `keyHint` / `isPlan` / `catalogIds`
- [ ] 条款提示 `terms`（看 Q1）+ 编辑器条款提示行
- [ ] 每家 Anthropic base 实测 `/messages` 通（§2.4，没 key 的标「未实测」写进 now 文档）
- [ ] `APIProviderTableTests` 跟着扩：新区域的结构断言
- [ ] 单测 + iOS build-for-testing；now 文档；交合并（`--why` 写验收步骤 2）

### 阶段 4 · 聚合商
- [ ] together / fireworks / nvidia（看 Q6）
- [ ] 单测 + iOS build-for-testing；交合并

### 阶段 5 · OpenRouter 一键登录
- [ ] `Services/ProviderOAuth/OpenRouterLogin.swift`：拼 URL、PKCE（复用 `ChatGPTOAuthPKCE`）、换 key、可选的 key 校验
- [ ] `ASWebAuthenticationSession` 封装（iOS / mac 的 presentation anchor）
- [ ] 回调兜底：mac 用 localhost 监听，iOS 用粘贴授权码（看阶段 0 的实测结果和 Q7）
- [ ] 编辑器：OpenRouter 预设的 key 段加登录按钮、成功说明、失败红字；key 只进草稿
- [ ] `OpenRouterLoginTests`
- [ ] 单测 + iOS build-for-testing；交合并（`--why` 写验收步骤 3）

### 阶段 6 · ChatGPT 风险提示 + UA 实测
- [ ] 常驻提示行（§5.6 文案）
- [ ] 第一次登录前的确认框 + `@AppStorage("chatgptOAuthRiskAcked")`
- [ ] 删掉页脚第三行
- [ ] 实测（需要粟粟的 ChatGPT 卡，在她的 sim 上做，或请她点）：用 `client_version=0.0.0` 拉 `/codex/models`，记下清单；挑清单里最新的模型发一句，记状态码；对照用 `0.159.0` 拉一次。结论写进 now 文档，不改代码
- [ ] iOS build-for-testing；交合并（`--why` 写验收步骤 4）

### 阶段 7 · 额度 / 余额卡（开工前先补细化版 plan，等批注）
- [ ] 细化 plan：显示样式小样（HTML）、刷新时机、出错时怎么显示
- [ ] 收集各家真响应样本（脱敏，不进 git 的原件留本机）

### 阶段 8 · Copilot（Debug）
- [ ] 按 Q8 的结论：单独写 `docs/plan-copilot-debug.md`，或者在本 plan 里补一节

### 收尾（每个阶段合完都做）
- [ ] `review-provider-presets-<阶段>.md`（边界情况 / 和下一模块的交互风险 / 技术债）
- [ ] `manual/facts/` 里 API 相关条目交给说明书流水线 check
