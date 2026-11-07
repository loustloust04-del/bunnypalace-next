# plan · 请求参数自适配

> ✅ 10-14 粟粟批：Q1–Q10 都按推荐。可以动手。
>
> 来源：任务书 `~/Desktop/cc-rp/API链路/派单/prompt-参数自适配.md`（粟粟 10-14：新用户填好接口发第一条就报「温度不兼容」）。
> 基线：backend-2 工位，#089 请求体修复之后的代码（HEAD `5dbc802e1`）。
> 不在本单：OAuth、接入流程（填 URL / key、拉模型列表、收藏）、ChatGPT 登录（Responses API）、本机模型、CC。

---

## 0. 一句话

所有端点组请求前都按「模型是谁」统一决定发哪些参数：先查本机学到的记忆，再查 models.dev 目录，最后按模型血统认（去掉 `anthropic/` 这种前缀，`claude-opus-4.7` 和 `claude-opus-4-7` 认成同一个）。
万一还是 400、报错又点名了某个参数，就去掉它（或换成对的写法）再发一次，只发一次，同时按「地址 + 模型」记住，以后直接不发。

---

## 1. 现状（写死的规则，各自只在哪生效）

文件都在 `MemoryPalace/` 下，行号是 HEAD `5dbc802e1`。

### 1.1 参数规则清单

| # | 规则 | 位置 | 只在哪生效 | 漏掉的情况 |
|---|---|---|---|---|
| R1 | OpenAI 推理模型不发 temperature / top_p | `Services/ChatService.swift:661-669` `dropsSamplingTemperature` | **只认 host == api.openai.com**（:662） | 中转站、OpenRouter 上的 `openai/gpt-5`、Azure、别家兼容口一律照发。测试还把「OpenRouter 上的 gpt-5 照发」写成了期望（`MemoryPalaceTests/OutputTokenCapTests.swift:138`） |
| R2 | 推理档不是 auto / none 就去掉 temperature / top_p | 同上 :663 | 同上，只认官方 | 同上 |
| R3 | `max_completion_tokens` 键名 | `ChatService.swift:655-657` `maxTokensKey` | 只认 api.openai.com | 中转站转发 GPT-5 / o 系 → 400「Unsupported parameter: 'max_tokens'… Use 'max_completion_tokens'」 |
| R4 | Claude Opus 4.7+ / 5 系不发 temperature / top_p / top_k | `ChatService.swift:1348` 用 `ReasoningEffort.needsAdaptive` | 只在 **Anthropic 格式的卡**里 | ① OpenAI 兼容格式的中转 / OpenRouter（`anthropic/claude-opus-4.7`）上照发；② `needsAdaptive` 是子串匹配（`Services/ReasoningEffort.swift:45-48`），只认 `opus-4-7` 这种连字符写法，**`claude-opus-4.7`（点号，OpenRouter 和不少中转的写法）认不出** → 照发 temperature，思考还走老的 budget_tokens 格式，两处都会 400 |
| R5 | adaptive / budget 两种思考格式 | `ReasoningEffort.swift:34`、`ChatService.swift:1325-1330` | Anthropic 卡 | 同 R4 ②，点号写法走错格式 |
| R6 | 开思考时 temperature / top_k 不发、top_p 只发 0.95–1 | `ChatService.swift:1349-1352` | Anthropic 卡 | — |
| R7 | 设置页「当前模型不支持 Temperature / Top P / Top K」提示 | `Views/PersonaSettingsTab.swift:276-278`、`:356-359` | 只在 Anthropic 卡 + `needsAdaptive` | 中转 / OpenRouter / OpenAI 推理模型都不提示 |
| R8 | 输出上限越界 → 降到 8192 重试一次 | `ChatService.swift:1960-1976` `capAwareFailed`；判断词 `Services/OutputTokenCap.swift:54-57` | 所有走 router 的流式请求 | 见 1.3：和 R3 的 400 会互相误伤 |
| R9 | Anthropic 中转不吃 cache_control → 拉黑 host | `ChatService.swift:1122-1127` `onHTTPError` | Anthropic 卡，**下一次**才生效，这次不重试 | 本单不动，见 §4.8 |

参数默认值是 `Models/Preset.swift:58-59`：temperature 0.7、top_p 0.95。builder 只在不等于 1.0 时才发（`ChatService.swift:834-837`），所以**默认预设每条消息都带 temperature 和 top_p**。新用户第一条就 400，原因就在这：R1 / R4 只管官方地址。

### 1.2 其他会被拒的参数（现在都无条件发）

| 参数 | 位置 | 谁可能拒 |
|---|---|---|
| `stream_options: {include_usage: true}` | `ChatService.swift:825` | 老版本 Azure、部分中转（magpie 把它列为可选字段，被点名就去掉，`internal/gateway/gateway.go:3420-3421`） |
| `frequency_penalty` / `presence_penalty`（非 0 才发） | `:839-840` | OpenAI 推理模型、部分推理模型 |
| `seed`（≥0 才发） | `:841` | 部分兼容口 |
| `reasoning_effort` / `reasoning.effort` | `:842` → `ReasoningEffort.swift:176-183` | 不认识这个字段的老兼容口；目录说不推理时已经不发（`ReasoningEffort.swift:60-64`） |
| `thinking` / `output_config` | `:1350-1351` | 见 R4 ②；Vertex 不收 `output_config`（oh-my-pi `rules/classes/anthropic.kdl` 注释） |
| 末条 assistant（预填） | 预设深度 0 的 assistant 段、`continuePrefill`（`Preset.swift:73`） | **10-14 实测** opus-5-5 / sonnet-5-5：400「This model does not support assistant message prefill」（`docs/review-request-body.md:66-67`） |

`tool_choice` 我们没发（全仓库只在 `OfficialTokenCounter.swift:27` 出现），本单不管。

### 1.3 现有 400 处理

- 出错文本只解析 `{"error":{"message"}}` 和 `{"error":"…"}` 两种形状（`ChatService.swift:322-333`）。Gemini 兼容口回的是顶层数组、FastAPI / vLLM 回 `{"detail":[…]}`、OpenRouter 把上游原文塞在 `error.metadata.raw` 里，这几种都只能显示「API 错误 (400)」。
- router 的回调只拿到字符串（`onError: (String)`），状态码和原始正文在 provider 上（`httpStatusCode` / `errorBody`，`ChatService.swift:40-41`，同模块可读）。
- **R8 的误伤**：`mentionsOutputLimit` 只要正文里出现 `max_tokens` 就算「上限太大」。OpenAI 说「`max_tokens` 不支持、请用 `max_completion_tokens`」也会命中，于是用**同一个错的键名**降到 8192 再发，必然再 400。默认输出上限是 16384（> 8192），所以中转 + GPT-5 的新用户一次会白打两个 400。

### 1.4 目录现在能用多少

- `Models/ModelCatalog.swift` 已经从 models.dev 读了 `temperature` 字段（:15-16、:189），查找也会去 `vendor/` 前缀、去日期、点号换连字符、最长前缀（:200-242）。**只有 R1 用了它，而且只在官方地址。**
- 本机缓存（10-12）抽查：Claude opus-4-7 / opus-5 / opus-5-5 / sonnet-5 / sonnet-5-5 / haiku-5-5 / fable-5、OpenAI gpt-5 / gpt-5-mini / gpt-5.5 / gpt-5.6 / o3 / o4-mini 都标了 `temperature: false`；gpt-5.1 / 5.2 / 5.4 标 `true`（这几个在推理档 none 时收 temperature）。目录对新模型基本是对的，问题在**没被用到**。
- 测试宿主里目录是空的（`ModelCatalog.swift:28-33`）。所以离线兜底必须有一层不靠目录的规则——这就是血统规则。

### 1.5 「预览 = 实发」现在怎么保证

- 实发：`ProviderRouter.sendStreaming`（`ChatService.swift:1756`）第一行先 `OutputTokenCap.resolved`（:1784），再交给各 provider 的 `sendStreaming`，provider 里算 `maxTokensKey` / `dropsSamplingTemperature`（:603-604），调 `buildRequestBody`。
- 预览：`ProviderRouter.previewRequestBody`（:2133）同样第一行 `OutputTokenCap.resolved`（:2142），再**并排抄了一遍** :603-604 那两行（:2146-2148），调同一个 `buildRequestBody`。
- 锁：`PromptRealPathGoldenTests`（金样 G1–G6，模型是 `gpt-4o` / `claude-sonnet-4-5`、地址 `http://127.0.0.1:9`）、`InspectorRealPathTests`（同一次运行里先预览、再重新生成抓实发，整份相等）。
- 检查器的「上一次真实发出」来自 `SentRequestStore`，过了保险闸那一刻按回合存（`ChatService.swift:318`），回合内每次发送都追加（#089 astra 第 7 条）。

---

## 2. 参照物（只读，没改）

### 2.1 magpie（`~/Desktop/susu-project/magpie`，Go；调研见 `docs/research-magpie.md` §2.5）

| 抄什么 | 它在哪 | 我们放哪 |
|---|---|---|
| **目录决定发不发 temperature**：按模型 id 查目录的 `Temperature *bool`，false 就不发 temperature / top_p；任何端点都查，新模型不用改代码 | `internal/provider/models.go:760-771` `RejectsTemperature`；目录字段 `internal/catalog/catalog.go:31`、`:265`、`:609`；厂商自己的列表覆盖 models.dev `internal/catalog/live.go:477-479`；组 body 时传进去 `internal/gateway/gateway.go:3274` | `ParamCompat.resolve` 的「目录」一层（§3.1） |
| **去 vendor 前缀再匹配** | `catalog.go:836-843` `bareID`（取最后一个 `/` 之后、小写）；Bedrock 地域前缀 `catalog.go:845-858` | 我们 `ModelCatalog.lookup` 已经有（`ModelCatalog.swift:226-242`），沿用 |
| **按「provider + 模型 + 字段」记住被拒过的东西**，下次直接不发 | `gateway.go:303-305` `unfit` 表，`:3180-3190` `fits` / `markUnfit`；键形如 `offRefused(model)`（`:4207-4213`） | `ParamAdaptStore`（§3.3）。差别：magpie 只存内存，我们落盘 + 设置里能看能清（任务书要求） |
| **认报错**：只看请求里真发了的字段；结构化优先（OpenAI 的 `param` + `code == unsupported_parameter`、FastAPI / Mistral 的 `extra_forbidden` + `loc`、`metadata.raw` 里嵌的上游 JSON），再用三条正则兜文字（`unknown name/field/parameter`、`unsupported parameter: x`、`'x' is not supported`）；带 `loc` 的校验错误、`unsupported_value` 不算「不支持这个字段」 | `gateway.go:3413-3415` `refusesField`、`:3417-3421` `optionalFields`、`:3426-3448` `refusedOptional`、`:3450-3452` 三条正则、`:3454-3530` `unsupportedOptionalField` | `ParamErrorClassifier`（§3.4）。我们对**采样参数**的 `unsupported_value` 例外处理：OpenAI 回「Only the default (1) value is supported」时去掉它就是对的 |
| **400 / 422 都算「请求被拒」** | `gateway.go:3621-3623` `badRequest` | 同 |
| **重试的写法**：认出来 → 改请求 → 再发；`tool_choice` 被拒（`toolChoiceRefused`，`:4219-4229`）、关推理被拒（`effortLevelsNamed`，`:4236-4238`）各有一条 | `gateway.go:3304-3345`、`:2870-2918` | §3.5。差别：magpie 是循环（每次去掉一个），我们只重试一次，所以要**整组去**（§3.2、Q1） |

### 2.2 oh-my-pi（`~/.bun/install/global/node_modules/@oh-my-pi/`，pi-catalog / pi-ai 18.10.2）

| 抄什么 | 它在哪 | 我们放哪 |
|---|---|---|
| **按血统认模型**：全 id 小写，「裸名」= 最后一个 `/` 之后；类（class）用 `namespace`（按 `/ . :` 切段）/ `bounded`（等于或后面跟 `- _ . :` 或数字）/ `prefix` / `exact` / `glob` 匹配；家族（family）用 glob；版本从 `claude-` / `gpt-` 后第一个数字起读最多三段（`.` 或 `-数字` 分隔，每段 ≤255） | 语法说明 `pi-catalog/src/compat/rules/README.md` 「Taxonomy grammar」；实现 `pi-catalog/src/compat/taxonomy.ts:51-160`（`bareOf` / `boundedMatch` / `matcherMatches` / `rankFamilies` / `extractRevision`）、`revision.ts:28-123` | `ModelLineage.classify`（§3.1）。**只抄 anthropic、openai 两类**：`rules/taxonomy/anthropic.kdl`（`namespace "anthropic" bounded` + `bounded "claude"`，家族 opus / sonnet / haiku / fable / mythos，`revision prefix="claude-" anywhere`）；`rules/taxonomy/openai.kdl`（`prefix "gpt-"`、o1 / o3 / o4 系、`revision prefix="gpt-" anywhere`） |
| **哪些血统不收采样参数**（`supports-sampling-params #false`） | `rules/classes/anthropic.kdl`（第二个 `class "anthropic"` 块开头）：opus `>=4.7 <10`、sonnet / fable / mythos `>=5 <10`、haiku `>=5.5 <10`；`<10` 是防 `claude-opus-45` 这种去了分隔符的写法被读成 45。`rules/classes/openai.kdl:3-13`：o 系、`revision >=5` 全不收 | `ModelLineage` 里一张小表（§3.1） |
| **组 body 之前统一剥一次**：compat 说不收采样参数，就从选项里删 temperature / top_p / top_k / min_p / 三种 penalty，任何 provider 都先过这一道 | `pi-ai/src/stream.ts:1209-1232` `withSupportedSamplingParams`，调用点 `:924`、`:1282` | `ParamCompat.supported(_ SamplingParams)`，放在 router 的 `OutputTokenCap.resolved` 旁边，实发和预览都过（§3.2） |
| **Anthropic 分支再守一道**：开了思考（thinking 不是 undefined / disabled）就不发采样参数 | `pi-ai/src/providers/anthropic.ts:5695-5707` | 我们已有（R6），把 R4 的判断换成同一个血统函数 |
| **compat 记录的分层**：默认 → 按地址 → 规则 → 用户显式覆盖，后者赢 | `pi-catalog/src/compat/resolve.ts:1-17` 文件头说明、`:1319-1360` `resolveModelPolicy` | `ParamCompat.resolve` 的顺序（§3.1）：学到的 > 目录 > 血统 > 默认发 |
| `max_tokens` 键名按地址定 | `resolve.ts:428-435`（mistral / moonshot / zai / 智谱 / chutes / fireworks / deepseek 用 `max_tokens`，其余默认 `max_completion_tokens`）、`:523` | **不照抄**：它默认 `max_completion_tokens`，我们中转多，默认反过来更稳。键名错了靠 400 自愈改名（Q8） |
| 末条 assistant：Anthropic 一律补一条「Continue.」 | `anthropic.ts:4608-4619`、`:6311-6345`；`supports-assistant-prefill` 只给 ollama 开（`rules/providers/ollama.kdl:21`） | 不照抄，见 Q7（预填是粟粟有意保留的） |

**两边不一致的地方**：oh-my-pi 说 GPT `>=5` 全部不收采样参数；models.dev 说 gpt-5.1 / 5.2 / 5.4 收（推理档 none 时）。任务书写的是「目录优先」，所以按目录走，目录没收录才用血统（Q2）。

---

## 3. 改法

### 3.1 认模型：`ParamCompat.resolve`（新文件 `Services/ParamCompat.swift`）

输入：provider 类型、baseURL、模型 id、推理档。输出一份小记录：

```swift
struct ParamCompat {
    var sendsSampling: Bool          // temperature / top_p / top_k / 两种 penalty
    var dropped: Set<String>         // 学到的、不在采样组里的：seed / stream_options / reasoning_effort / output_config …
    var maxTokensKey: String         // OpenAI 兼容口用
    var anthropicAdaptive: Bool      // Anthropic 思考格式
    var source: Source               // .learned / .catalog / .lineage / .default（给设置页提示、日志用）
}
```

**判断顺序（先命中先用）**：

1. **学到的**（§3.3 记忆表，键 = 规范化 baseURL + 模型 id）：说不发就不发。只会「去掉」，不会「加回来」。
2. **目录**：`ModelCatalog.shared.model(for:)?.temperature == false` → 不发采样组。`true` → 发（但仍受第 4 条推理档规则约束）。`nil` → 往下。
3. **血统**（`ModelLineage.classify`，抄 oh-my-pi taxonomy）：
   - 认类：Anthropic = 任一段（按 `/ . :` 切）bounded 匹配 `anthropic` / `claude`；OpenAI = 裸名 `gpt-` / `chatgpt-` / `codex-` 开头、或 o1 / o3 / o4 系、或有一段是 `openai`。
   - 认家族 + 版本：见 §2.2。例：`anthropic/claude-opus-4.7` → anthropic · opus · 4.7；`claude-opus-4-7-20260101` → 4.7（日期段 >255 停）；`claude-3-7-sonnet-20250219` → sonnet · 3.7；`gpt-4o` → openai · gpt · 4；`openai/o4-mini` → o 系。
   - 不收采样参数：opus ≥4.7 <10、sonnet / fable / mythos ≥5 <10、haiku ≥5.5 <10、OpenAI o 系、GPT ≥5。
   - Anthropic adaptive：opus ≥4.7、sonnet / fable / mythos ≥5、haiku ≥5（沿用现在 `needsAdaptive` 的范围，不按 oh-my-pi 收紧到 haiku 5.5，避免行为变化）。
   - 认不出（`unknown`）→ 往下。
4. **推理档规则**（R2 推广）：OpenAI 血统 + 推理档不是 auto / none → 不发采样组。不再限定官方地址。
5. **默认**：发。

`maxTokensKey`：官方 api.openai.com → `max_completion_tokens`（R3 不变）；记忆表里学到改名 → 用学到的；其余 `max_tokens`。

`anthropicAdaptive`：记忆表学到的 > 血统。`ReasoningEffort.needsAdaptive(_:)` 保留函数名，内部改调血统（所有调用点 `ReasoningEffort.swift:34`、`ChatService.swift:1326`、`:1348`、`PersonaSettingsTab.swift:277` 一起修好点号写法）。

### 3.2 组 body 前统一剥一次（抄 `withSupportedSamplingParams`）

我们的 builder 本来就把「等于默认值」当「不发」：temperature / top_p == 1.0、top_k == 0、penalty == 0、seed < 0、推理档 == auto（`ChatService.swift:834-842`、`:1349-1357`）。所以剥参数 = 把 `SamplingParams` 里对应字段改成「不发」的值，一个纯函数：

```swift
extension ParamCompat {
    func supported(_ s: SamplingParams) -> SamplingParams   // 采样组 → 1.0 / 1.0 / 0 / 0 / 0；dropped 里有 seed → -1；有 reasoning → "auto"
}
```

**放的位置**：`ProviderRouter.sendStreaming`（`ChatService.swift:1784`）和 `previewRequestBody`（`:2142`）第一行都已经是 `samplingParams.map { OutputTokenCap.resolved(…) }`，在同一行后面接 `.map { compat.supported($0) }`。实发和预览走同一个函数，**预览 = 实发不用另外操心**。

不在 `SamplingParams` 里的两样（键名、`stream_options`）给 builder 传 compat：

- OpenAI：`buildRequestBody` 现有的 `maxTokensKey:` / `dropTemperature:` 两个参数换成一个 `compat: ParamCompat = .permissive`（默认值让老测试和金样调用点不用改）。provider 里 `:603-604` 和预览里 `:2146-2148` 那两段并排代码合成一句 `ParamCompat.resolve(...)`。
- Anthropic：builder 里 `samplingDeprecated`（`:1348`）改调同一个血统函数；思考格式用 `compat.anthropicAdaptive`。
- `dropsSamplingTemperature` 删掉（被 3.1 第 2、4 条吸收），它的单测改写成 `ParamCompat` 的单测。

**不改预设**：剥的只是这一次请求，预设里还是 0.7。只动参数，不动消息、工具、模型名。唯一会改值的是已有的「上限降到 8192」。设置页 R7 的提示改成按 `ParamCompat.resolve(...).sendsSampling` 判断，所有端点都提示。

### 3.3 记住（新 `ParamAdaptStore`）

- 键：`规范化 baseURL`（小写、去尾 `/`）+ `|` + 模型 id（小写）。同地址不同 key 共享（任务书要的就是地址 + 模型）。
- 值：被拒的参数组（`sampling` / `seed` / `stream_options` / `reasoning` / `output_config` / `thinking_format` / `max_tokens_key`）、改名目标、学到的时间、原始报错前 300 字（给设置页看）。
- 存：`UserDefaults` 一个小字典 `paramAdaptByEndpoint.v1`，最多 200 条（超了删最老的）。测试宿主用隔离的 suite（照 `ModelCatalog.shared` 的测试分支）。
- 什么时候写：报错**点名**了参数、而且这个参数这次确实发了 → 立刻写（Q3）。

### 3.4 认报错（新 `ParamErrorClassifier`，抄 magpie `refusedOptional`）

输入：状态码、原始正文（`provider.errorBody`）、这次实发 body 的顶层键（provider 发出时顺手存一份键名集合，`startBudgetCheckedRequest` 那里）。只在 400 / 422（Q9）。

步骤：
1. 解 JSON（字典或数组），递归看 `error` / `message` / `detail` / `details` / `errors` / `description` / `metadata` / `raw`；字符串里嵌着 JSON（中转常这样）就从第一个 `{` / `[` 起再解一次（magpie 同款）。
2. 结构化命中：`param == 字段` 且 `code == unsupported_parameter`；`param` 是采样字段且 `code == unsupported_value`（「Only the default value is supported」）；`type == extra_forbidden` 且 `loc == [body, 字段]`。
3. 文字命中（字段名必须是这次真发了的顶层键）：magpie 三条正则 + 补几条：`字段.{0,40}(deprecated|not supported|unsupported|not permitted|unknown|unrecognized)`、`Use 'max_completion_tokens'`。
4. 特例：
   - 「Use 'max_completion_tokens' instead」/「`max_tokens` is not supported」→ **改键名**（不是降上限）；
   - 上限太大（`max_tokens: N > M`、too large、exceeds、maximum）→ 交给原来的降 8192（R8），只有在不是改键名时；
   - `thinking.type.enabled` 不支持 / 提到 adaptive → 换 adaptive；`adaptive` 不认识 → 换 budget；别的 thinking 报错 → 去掉思考（推理档按「默认」）；
   - `output_config` 被拒 → 只去掉 `output_config`；
   - 「does not support assistant message prefill」→ 预填（Q7）；
   - 值不对（带 `loc` 的校验错误、temperature 超范围如 Anthropic 只收 0–1、推理档某一档不收）→ **不重试**，说人话（Q10）。
5. **一次就整组去**：点名 temperature / top_p / top_k 任一个 → 整个采样组都不发（OpenAI 一次只报一个参数，只重试一次的话逐个去会卡住，Q1）。

输出：`.fix([Fix])`（去哪些 / 改什么）或 `.explain(String)`（说人话、不重试）或 `.unknown`。

### 3.5 400 自愈：把 R8 合成一套

`ProviderRouter.sendStreaming` 里的 `capAwareFailed`（`ChatService.swift:1960-1976`）换成 `adaptiveFailed`：

- **条件**（全满足才重试）：
  - provider 是 OpenAI 兼容或 Anthropic；
  - 状态码 400 / 422；
  - 没收到任何流式输出（`streamingContent.isEmpty`、没有 `receivedDone`、没有工具调用分片）；
  - 这次是**第一次**发——给 `sendStreaming` 加一个内部参数 `attempt: Int = 0`，重试那次传 1，不再靠「重试时上限已经是 8192」这种巧合防循环。
- **做法**：认出来要去的参数 → 写记忆表 → 失败那次照旧记账（`record(nil, .error)`，现有）→ 原参数原样再调一次 `sendStreaming(attempt: 1)`。重试会重新走 `ParamCompat.resolve`，这时记忆表里已经有了，自然不发；预览也读同一张表。
- 上限越界（R8）照旧把 `retry.maxTokens = 8192` 带进重试；和改键名、去参数可以**同一次重试一起做**，总共还是只多发一次。
- 第二次还 400：不再重试，按 §3.7 说人话。两次都在 `SentRequestStore` 同一回合里（追加），检查器能看到被拒的那份和重试的那份。
- 非 400 / 422、已经收到输出、ccBridge / ChatGPT 登录 / 本机：一律不碰。

### 3.6 不静默

- 自适配发生（只算 400 自愈学到新东西的那一次；目录 / 血统本来就知道的不提示，任务书第 4 条「一致时不重复提示」）→ router 记 `lastParamAdaptation`（同 `lastReplyHitOutputLimit` 的写法，`ChatService.swift:1695`），聊天页在 onComplete / onError 里读到就出一行小灰字：
  「这个模型不收 temperature / top_p，已自动去掉」/「这个接口要用 max_completion_tokens，已自动改」。形式见 Q5。
- 日志：`CacheDiagLog` 记一条（地址 host、模型、去了什么、原始报错前 300 字），`BreadcrumbLog` 记一行 ✂️（同 R8）。
- 之后同一地址 + 模型不再提示（记忆表已有）。

### 3.7 认不出就说人话、不重试

`handleErrorBody`（`ChatService.swift:322-333`）只在**提取不到 message** 时补形状（数组、`detail`、`metadata.raw`）；再在 router 失败出口加一层：

- 找到了参数名、但不是「不支持」类（值不对）：`<host> 不收参数 temperature 现在的值（1.5）。原文：…`
- 什么都认不出：原文照旧 + 尾巴 `（<host> · <模型> · HTTP 400）`。原来只有「API 错误 (400)」的情况至少能看到是哪家、哪个模型。
- `readableError` 现有的模型下线那句（`:361-364`）不动。

### 3.8 设置里能看能清

列出记忆表：`<host> · <模型>：不发 temperature、top_p · 10-14`，每行可清，底部「全部清空」。清掉后下次照常发，再被拒会再学一次。入口见 Q6。

### 3.9 和别的东西的关系

- **金样不变**：G1–G6 用的是 `gpt-4o`（openai · gpt · 4，收采样）和 `claude-sonnet-4-5`（< 5，收采样、budget 思考），测试宿主目录为空、记忆表隔离 → 实发 body 一个字节都不变。若变了 = 实现有 bug，不许重录。
- **InspectorRealPathTests**：预览和实发都过 `ParamCompat`，照样相等。补一例：记忆表里写一条 → 预览和实发都没有 temperature。
- **R9 cache_control 黑名单**：不并进来。同一个 400 正文里同时提到 cache 时，`onHTTPError` 先拉黑，自愈重试那次自然不挂标，两者不打架。
- **ChatGPT 登录**：body 不发 temperature（`ChatGPTOAuthProvider.swift` buildRequestBody 只有 `reasoning`），本单不碰。
- **非流式（记忆提取、摘要）**：不发采样参数，不碰。

---

## 4. 测试

都是单测，不发真请求。重试用现有的 `ScriptedHTTPServer`（`OutputTokenCapTests.swift:264-306` 那套）。

### 4.1 报错样本 → 识别结果（`ParamErrorClassifierTests`）

样本放 `MemoryPalaceTests/Fixtures/param-errors/*.json`。标「未查证」的是按资料 / 参照物注释还原的形状，实现时如果 `CacheDiagLog` 里有真原文就换成真的。

| 样本 | 来源 | 期望 |
|---|---|---|
| OpenAI `Unsupported value: 'temperature' does not support 0.7 … Only the default (1) value is supported.`，`param: temperature, code: unsupported_value` | `docs/plan-output-token-cap.md:125`（issue 原文） | 去采样组 |
| OpenAI `Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.`，`code: unsupported_parameter` | `docs/research-output-token-cap.md:84` | 改键名，**不**降 8192 |
| Anthropic 采样参数 deprecated（10-11 实测，原文措辞未查证） | `ChatService.swift:1347` 注释 | 去采样组 |
| Anthropic `This model does not support assistant message prefill` | 10-14 实测 | 预填（Q7） |
| Anthropic `thinking.type.enabled` 不支持、要 adaptive（措辞未查证） | oh-my-pi `anthropic.kdl` 注释 | 换 adaptive |
| Anthropic temperature 超 0–1（措辞未查证） | — | 不重试，说人话 |
| OpenRouter 包一层：`error.metadata.raw` 里是 Anthropic 的 JSON 字符串 | magpie 看 `metadata` / `raw` | 按里层认 |
| 中转把上游 JSON 嵌在文字里：`upstream error: {"error":{…"param":"temperature"…}} (request id: …)` | magpie `unsupportedOptionalField` 字符串分支 | 按嵌的 JSON 认 |
| FastAPI / vLLM 422：`{"detail":[{"type":"extra_forbidden","loc":["body","top_k"],…}]}` | magpie `extra_forbidden` 分支 | 去采样组 |
| Gemini 兼容口顶层数组：`[{"error":{"message":"Invalid JSON payload received. Unknown name \"top_k\": Cannot find field."}}]` | magpie 注释 | 去采样组 |
| `Unrecognized request argument supplied: stream_options` | magpie `optionalFields` | 去 `stream_options` |
| 正文提到 temperature 但我们没发 temperature | magpie「只看真发了的字段」 | `.unknown` |
| 带 `loc` 的值校验错误 | magpie | 不重试，说人话 |
| `max_tokens is too large: 16384. This model supports at most 8192 completion tokens.` | 现有 `capError` 样本（`OutputTokenCapTests.swift:252`） | 降 8192（R8 原行为） |
| Cloudflare HTML 页 / 空正文 | — | `.unknown`，原文 + host / 模型 / 状态码 |
| 500 / 429 带同样文字 | — | 不碰 |

### 4.2 重试（router，`ScriptedHTTPServer`）

- 第一次 400 temperature → 第二次 body 没有 temperature / top_p → 成功；正好 2 个请求；账本 `[.error, .ok]`。
- 两次都 400 → 只 2 个请求，错误文本说人话。
- 400 改键名 + 上限 16384 → 第二次 `max_completion_tokens: 16384`（不是 8192），只 2 个请求（修 1.3 的误伤）。
- 400 上限太大 → 第二次 8192（现有 3 个 R8 测试原样通过）。
- 已收到流式输出后断开 / 500 / 429 → 不重试。
- 同一请求同时「改键名 + 去采样」→ 一次重试做完。

### 4.3 记忆表

- 写 / 读 / 清单条 / 全清；键规范化（大小写、尾 `/`）；200 条上限淘汰最老的；测试宿主隔离不碰真 UserDefaults。
- 学到之后再发：第一次就不带参数，不再 400，不再出提示。

### 4.4 认模型（`ParamCompatTests`）

- 血统：`claude-opus-4-7` / `claude-opus-4.7` / `anthropic/claude-opus-4.7` / `us.anthropic.claude-opus-4-7-v1:0` / `claude-opus-45`（4.5，收采样）/ `claude-sonnet-4-6`（收）/ `claude-haiku-5-5`（不收）/ `gpt-4o`（收）/ `openai/gpt-5`（不收）/ `o3-mini`（不收）/ `deepseek-reasoner`（认不出 → 收）。
- 顺序：目录 true 但记忆表说不收 → 不发；目录 false → 不发；目录 nil → 血统。
- `needsAdaptive("claude-opus-4.7") == true`（现在是 false）。
- `previewRequestBody` 与实发 body 相等（记忆表有条目时）。

### 4.5 会改的现有测试

- `OutputTokenCapTests.swift:138`：`openai/gpt-5` 在 OpenRouter 上推理档 high 现在期望「照发」，改成「不发」——这正是本单要修的。
- `OutputTokenCapTests.swift:128-140`、`ReasoningEffortTests.swift:132-133` 里调 `dropsSamplingTemperature` 的改成调 `ParamCompat`，断言值除 :138 外不变。
- 金样 G1–G6：**不应该变**。

---

## 5. 风险

1. **误学**：中转临时抽风、报错恰好点名 temperature → 被记住、以后一直不发。缓解：只在 400 / 422、只认点名、只认这次真发了的字段；设置页能看能清（Q4 问要不要过期）。
2. **整组去**会顺带去掉其实收的参数（比如只拒 top_k，temperature 也被去了）。代价是那个模型的温度调了没用；换来的是只重试一次就能过。Q1。
3. **目录说收、实际不收**（gpt-5.4 + 推理档 auto，默认档是不是 none 未查证）→ 第一次 400，自愈后记住。只多一个 400，用户看到一行灰字。
4. **去掉 `stream_options`** 后这家可能不回用量 → 保险闸 / 账本退回估算（现有路径，`completeness: .missing`）。
5. **血统认错**：中转起的怪名字（`cc-claude-opus-4-7`）认不出 → 回到 400 自愈，不会更坏。蒸馏模型名里带 `Claude-…-Opus`（oh-my-pi 专门有 override）可能被认成 Claude → 最多是不发温度，无害。
6. **两个对话同时撞同一个模型**：都学、写同一条，幂等。
7. **重试多花一次保险闸预估**：400 不扣费，预估只是读一次。
8. **抽成 `compat:` 参数**会碰 `buildRequestBody` 的签名，测试里直接调 builder 的地方多（`OutputTokenCapTests`、`ProviderOrderingTests` 等）。用默认值 `.permissive` 保持调用点不变。
9. OpenRouter 自己会不会替我们过滤不支持的参数（未查证）。不管它过不过滤，我们按血统不发都对。

---

## 6. 要粟粟拍板

**Q1 一次重试怎么去参数**
- **A（推荐）**：点名 temperature / top_p / top_k 任一个，整个采样组（含两种 penalty）都不发，也按整组记住。理由：OpenAI 一次只报一个参数，只重试一次的话逐个去会在第二个上又 400；oh-my-pi 的 `withSupportedSamplingParams` 也是整组删。
- B：只去点名的那个，第二次还 400 就报错，下次发再学下一个。

**Q2 目录和血统说法不一样听谁的**
- **A（推荐）**：目录优先（任务书原话），目录没收录才用血统；推理档开着的 OpenAI 血统模型一律不发。理由：目录是逐个模型的数据，比按版本号一刀切细；gpt-5.1 / 5.4 在推理档 none 时确实收温度，一刀切会让这几个模型的温度白调。
- B：任一层说不收就不发。最保险，代价同上。

**Q3 什么时候记住**
- **A（推荐）**：报错点名了、我们也确实发了 → 立刻记。理由：报错本身就是证据；如果等重试成功才记（magpie 的做法），遇到同时拒两个参数的模型，重试失败就什么都没学到，下次还从头撞。
- B：重试成功才记。

**Q4 记多久**
- **A（推荐）**：一直记着，设置里手动清。理由：模型的参数规矩很少变；过期了反而每隔一阵子撞一次 400。
- B：30 天过期自动忘。
- C：只记到 app 退出（magpie 的做法）。

**Q5 小灰字长什么样**
- **A（推荐）**：复用聊天页现有的临时提示胶囊（`transientNotice`，`ConversationViewModel.swift:106`；`CardFlowView.swift:4807` `TransientNoticeCapsule`），显示几秒淡出。理由：零存储改动，已有现成样式；学到之后不会再出，频率很低。
- B：那条回复气泡下面常驻一行灰字（只存内存，重启消失）。要两套聊天页都加 UI。
- C：存进消息节点，永久显示。要动数据。

**Q6 设置入口放哪**
- **A（推荐）**：API 卡编辑页的模型行，在 models.dev 那行小字下面再加一行「自动适配：不发 temperature / top_p」+ 清除按钮（`Views/APICredentialEditor.swift:1676` 附近）；调试页另放完整列表和「全部清空」。理由：就在出问题的模型旁边，不用找。
- B：设置根列表新开一行「参数自适配」。
- C：只放调试页。

**Q7 「不支持 assistant 预填」怎么办**（opus-5-5 / sonnet-5-5 实测会拒）
- **A（推荐）**：认出来说人话、不重试：「这个模型不收预填（预设里深度 0 的 assistant 段 / 续写预填），去预设里关掉」。理由：预填是你有意保留的内容，自动改会让它悄悄失效；参数自适配只动参数不动内容。
- B：自动在末尾补一条合成用户消息「（继续）」重试并记住（oh-my-pi 的做法是补「Continue.」）。

**Q8 `max_tokens` / `max_completion_tokens` 要不要主动猜**
- **A（推荐）**：不猜，非官方地址默认还是 `max_tokens`，被拒了自愈改名并记住。理由：中转对 `max_completion_tokens` 认不认差别很大，猜错反而把原本能用的弄坏；自愈只多一个 400。
- B：OpenAI 推理血统（o 系、GPT-5+）在非 OpenRouter 地址主动用 `max_completion_tokens`（oh-my-pi 默认就是它）。

**Q9 哪些状态码算「参数被拒」**
- **A（推荐）**：400 和 422。理由：FastAPI / vLLM 系的自建端点参数校验错误回 422（magpie `badRequest` 同样两个）。
- B：只 400（任务书原话）。

**Q10 推理档某一档不被接受（如「'none' is not supported」）**
- **A（推荐）**：不重试，说人话「这个模型不收推理强度「关」，换一档」。理由：推理档是你明确选的，悄悄换掉不合适。
- B：学 magpie 自动降到这个模型最低一档开着的再发一次（`gateway.go:3325-3333`）。

---

## 7. 执行清单（每项单独 commit，可单独撤）

- [x] 1. `ModelLineage`：类 / 家族 / 版本解析（只 anthropic、openai），纯函数 + 单测（§4.4 血统那组）。不接任何调用点。
- [x] 2. `ParamCompat.resolve` + `supported(_ SamplingParams)`：学到的 > 目录 > 血统 > 推理档 > 默认；记忆表先用空实现。单测。
- [x] 3. router 接入：`sendStreaming` / `previewRequestBody` 在 `OutputTokenCap.resolved` 后接 `ParamCompat.supported`；OpenAI provider 和预览里并排的 `maxTokensKey` / `dropsSamplingTemperature` 两行合成 `ParamCompat.resolve`；删 `dropsSamplingTemperature`，改写它的单测（含 `:138` 期望翻转）。跑金样 G1–G6 + InspectorRealPathTests，必须不变。
- [x] 4. `needsAdaptive` 改调血统（修点号写法）；Anthropic builder `samplingDeprecated` 改调同一函数；`PersonaSettingsTab` 提示改按 `ParamCompat` 判断（所有端点）。单测 `claude-opus-4.7`。
- [x] 5. `ParamAdaptStore`：UserDefaults 小字典、键规范化、200 条上限、测试隔离；接进 `ParamCompat.resolve` 第 1 层。单测（§4.3）。
- [x] 6. builder 的 `compat:` 参数：键名、`stream_options` 读记忆表；预览同口径。InspectorRealPathTests 补「记忆表有条目」一例。
- [x] 7. provider 发出时存这次 body 的顶层键集合（给分类器用）。
- [x] 8. `ParamErrorClassifier` + `Fixtures/param-errors/` 样本 + 单测（§4.1 全表）。
- [x] 9. router 自愈：`capAwareFailed` → `adaptiveFailed`，`attempt` 参数、400 / 422、无输出才重试、学 → 记账 → 重发；R8 并进同一次重试。router 单测（§4.2），现有 3 个 R8 测试原样过。
- [x] 10. 认不出 / 值不对说人话：`handleErrorBody` 补数组 / `detail` / `metadata.raw` 形状；失败出口补 host / 模型 / 状态码。单测。
- [x] 11. 提示：router `lastParamAdaptation` → 聊天页小灰字（按 Q5）+ `CacheDiagLog` / `BreadcrumbLog`。
- [x] 12. 设置页查看 / 清除（按 Q6）。
- [x] 13. 定向测试全绿（ParamCompat / ParamErrorClassifier / ParamAdaptStore / OutputTokenCap / ReasoningEffort / PromptRealPathGolden / InspectorRealPath / SentRequestStore），读到各 Test Suite passed。
- [x] 14. 复盘 `docs/review-param-autoadapt.md`；验收说明写到 `~/Desktop/cc-rp/API链路/参数自适配-验收.md`；`docs/now/backend-2.md` 更新；说明书已同步 / 不涉及（`manual/facts/`）。
