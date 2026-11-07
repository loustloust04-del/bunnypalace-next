# review · 请求参数自适配（#094）

> plan：[plan-param-autoadapt.md](plan-param-autoadapt.md)（粟粟 10-14 批 Q1–Q10 按推荐）。
> 验收说明：`~/Desktop/cc-rp/API链路/参数自适配-验收.md`。

## 做了什么（按提交，对应 plan §7 执行清单）

| 步 | 内容 |
|---|---|
| 1 | `ModelLineage`：按血统认 anthropic / openai（去命名空间、点号 / 连字符同认、日期段 >255 停、版本 <10 防 `claude-opus-45`） |
| 2 | `ParamCompat.resolve`：学到的 > models.dev 目录 > 血统 > 推理档 > 默认；`supported(_:)` 把不发的字段改成 builder 当「不发」的值 |
| 3 | router 实发 / 预览在 `OutputTokenCap.resolved` 后统一过 `ProviderRouter.adaptedSampling`；删 `dropsSamplingTemperature` / `maxTokensKey(baseURL:)`；builder 两个参数合成 `compat:`（默认 `.permissive`） |
| 4 | `needsAdaptive` 改调血统（`claude-opus-4.7` 认得出）；Anthropic builder 采样 / 思考格式 / output_config 按 compat；设置页「当前模型不支持…」提示所有端点都按 ParamCompat |
| 5 | `ParamAdaptStore`：UserDefaults 小字典 `paramAdaptByEndpoint.v1`，键 = 规范化 baseURL + 模型 id，最多 200 条 |
| 6 | InspectorRealPathTests 补「记忆表有条目」一例：预览 = 实发，都剥掉 |
| 7 | provider 组好 body 时存 `SentShape`（顶层键 + 采样 / 推理档值） |
| 8 | `ParamErrorClassifier` + 15 份报错样本 |
| 9 | router `capAwareFailed` → `adaptiveFailed`：400 / 422、只第一次（`attempt`）、没输出才重试；R8 并进同一次重试 |
| 10 | 出错正文补数组 / `detail` / `metadata.raw` 形状；自愈不了说人话、认不出加（host · 模型 · HTTP 400） |
| 11 | `lastParamAdaptation` → 聊天页临时提示胶囊；诊断日志 / 面包屑 |
| 12 | 模型池行「自动适配：…」+ ×；开发调试页「参数自适配」整表 + 全部清空；设置搜索注册表 |

和 plan 不一样的地方：

- **builder 先认了 `compat.dropped`**（seed / reasoning / stream_options）是在第 3 步就做了，第 6 步只剩测试。
- **`handleErrorBody` 对 OpenRouter 多做了一点**：plan 写「只在提取不到 message 时补形状」，但 OpenRouter 的 message 永远是「Provider returned error」，等于没说。现在有 `metadata.raw` 时把上游原文接在后面（「Provider returned error：`temperature` is deprecated…」）。非流式（记忆写手等）的 `extractError` 也改成走同一个函数。
- **重试那次又 400 且点名了新参数**：照 Q3「立刻记」也记下，不再重试，报错尾巴加一句「（已记住：…，下次自动照办）」。plan 没写这一支。
- **样本里 FastAPI / Gemini 两条换了字段**：plan 写的是 `top_k`，但 OpenAI 兼容口的 body 根本不发 `top_k`（「只认真发了的字段」会直接判 unknown），换成 `top_p` 和 `seed`。
- **haiku 5.0 的采样**：按 plan（抄 oh-my-pi）haiku ≥5.5 才不收采样，所以 `claude-haiku-5`（5.0）在 Anthropic 卡上现在会发 temperature（以前 `needsAdaptive` 子串匹配 `haiku-5` 一律不发）。思考格式仍是 adaptive。真不收的话第一次 400 会自愈。

## astra 一轮裁决（2 个 P1、5 个 P2，全收）

| # | 问题 | 怎么处理 |
|---|---|---|
| 1 P1 | 被拒的 400 缺 usage，按预估扣了预算；余额只够一次时，自愈那次被保险闸拦下。复盘写的「400 不扣费」和代码不符 | 只在「400 / 422、第一次、没输出、马上重发」那一支给这次请求的结算打标，账本照记 `.error`，预算扣 0；别的缺 usage 的错误照旧按预估扣。补测：余额只够一次，重试照样发出去 |
| 2 P1 | metadata.raw 展开、诊断日志、记忆表 rawError 原样带出正文里的 key / `?key=` | 分类看原文；展示、日志、落盘一律走 `ParamErrorClassifier.redacted`：复用 `SentRequestStore.redact` 换掉当前 key（原文 + 转义形式），URL 去 query / userinfo。失败出口气泡、非流式 `extractError`、日志、记忆表都过它 |
| 3 P2 | 发了 adaptive、报「Assistant prefill is not supported with adaptive thinking.」也被当成「改用 budget」学下来 | 只在点名 `thinking.type`、明确拒 adaptive（或只列 enabled / disabled）时才换 budget；正文说预填的不碰思考格式，说人话、不学、不重试。补这句原文的样本 |
| 4 P2 | 结构化的「值不支持」被文字规则改判成「字段不支持」（不带引号的 `does not support none`），永久关推理；任何采样 `unsupported_value` 都整组去 | 结构化 `param + code` 优先，文字只补结构化没说到的字段；采样 `unsupported_value` 只有正文明说只收默认值才整组去，其余值不对说人话、不学。不带引号的档位值也认 |
| 5 P2 | R8 兜底不看状态码，429 / 500 正文提到 max_tokens 也降上限重发 | 整个重试决策（学参数和降上限）先过 400 / 422。补 429 / 500 + 「reduce max_tokens」测试 |
| 6 P2 | 同一地址的 OpenAI 兼容卡和 Anthropic 卡共用一条记录，互相关参数 | 键加协议类型；同协议同地址不同 key 仍共享。调试页表格带协议名 |
| 7 P2 | 整个 URL 小写，`/TenantA` 和 `/tenanta` 撞成一条 | 用 URLComponents 只规范 scheme / host，路径大小写保留，仍去尾 `/` |

astra 另外提到、不改的：`claude-haiku-5`（5.0）现在会发 temperature（plan 批过的行为，见上）；后台 `sendNonStreaming` 不过 ParamCompat（见 §3）。

## 补丁 · temperature 和 top_p 只收一个（10-14 粟粟报 bug，#093 工位插单）

| 改了什么 | 怎么认 / 怎么改 | 验证 |
|---|---|---|
| Opus 4.6 默认预设（0.7 + 0.95）回 400「`temperature` and `top_p` cannot both be specified for this model」（#094 之前就有，不是回归） | `ModelLineage.singleSampler`：Anthropic 血统 opus ≥4.1、sonnet ≥4.5、haiku ≥4.5、且没被 `rejectsSampling` 整组拦掉的 → `ParamCompat.singleSampler`。两个都要发时留 temperature、不发 top_p；temperature 是默认值（不发）时 top_p 照发。Anthropic builder 非思考分支 + OpenAI 兼容 builder（OpenRouter / 中转上的 claude）都认；思考分支本来只发 top_p，不动；top_k 不动（没找到它也被拒的证据） | ParamCompatTests 3 例（血统 / resolve / 两个 builder 的 body） |
| 认不出血统的名字（中转起的）撞这句 400 | `ParamErrorClassifier` 认「cannot both be specified / use only one…」且两个都真发了 → `.singleSampler`：记进记忆表 `single_sampler` 组（**不是**整组不收，Q1 整组规则的例外，因为报错说的是「不能同时」不是「不收」），没输出时重发一次只带 temperature；聊天闪「✂️ 这个模型 temperature 和 top_p 只收一个，已去掉 top_p」；设置 · 全部模型那行 / 开发调试表写「不发 top_p（和 temperature 只收一个）」 | ParamErrorClassifierTests 1 例（样本 `anthropic-temperature-top-p-both.json` 是粟粟报的原文）、ParamAutoAdaptRouterTests 1 例（自愈 + 记住 + 第二次直接只发一个） |
| 金样 | G4（claude-sonnet-4-5）重录：唯一变化是 body 里 `top_p` 没了。ProviderOrderingTests 的 `anthropic-plain` / `anthropic-first-turn` 两条改前夹具同样只去掉 `top_p`（PersonaRequestBodyTests 吃同一份夹具）。G1–G3、G5、G6（gpt-4o）不变 | mac build-for-testing + 20 套件 273 测 + BudgetGate 32 全过 |

没有官方清单：只按公开报告（Opus 4.1、Sonnet 4.5、Sonnet 4.6 点名）+ 粟粟实撞的 Opus 4.6 推断范围；Haiku 4.5 是按「同代都这样」算进来的，**未查证**。范围外的模型撞上了照样会被 400 自愈学到。粟粟要是想反过来留 top_p，改 builder 里两处判断即可。

## 1. 边界情况

- **误学**：中转临时抽风、报错恰好点名 temperature → 被记住，之后一直不发。只认 400 / 422、只认点名且这次真发了的字段，设置里能看能清；没有过期（Q4）。
- **整组去**：只拒 top_p 也会连 temperature 一起不发（Q1）。那个模型在这个地址上温度调了没用。
- **同协议、同地址、不同 key 共享**一条记录（任务书要的就是地址 + 模型；astra #6 后按协议分开）。同一个中转背后不同 key 路由到不同上游、规矩不同的情况会互相影响。
- **两个对话同时撞同一个模型**：都学、写同一条，组取并集，幂等；没有锁以外的协调。
- **认不出的写法**：报错只说 `invalid parameter` 不点名字段 → `.unknown`，不重试，原文 +（host · 模型 · HTTP 400）。中文报错（国内中转自己翻译的「参数 temperature 不支持」）认不出（正则全是英文）。
- **流式中途出错**：已经收到输出（或已收到 `[DONE]`）一律不重试；SSE 里的 `error` 事件状态码是 200，本来就不进自愈。
- **被拒那次的预算扣 0**：只在「400 / 422 参数拒收、马上自愈重发」这一支，账本照记 `.error`（`[.error, .ok]` 两条），`budgetChargeUSD` 记 0，不会把重试那次挤出保险闸（astra #1）。别的缺 usage 的错误仍按预估扣（宁可多扣）。重试那次照常过一次保险闸预估。
- **自愈只看 `errorBody`**：中转把错误放在响应头、正文为空 → `.unknown`。
- **推理档规则**：OpenAI 血统 + 推理档开着就不发采样组，目录说 gpt-5.4 收温度也一样（plan §3.1 第 4 条）。gpt-5.4 在推理档「默认」时到底收不收温度未查证，第一次 400 会自愈。
- **Q10 的认法**靠 `code: unsupported_value`（结构化优先），或报错里带着这次发的档位值（带引号，或「does not support none」「none is not supported」）。只说「reasoning_effort is not supported」不带值 → 当成整个字段不收，去掉推理档重发（这和 Q10「不悄悄换档」不完全一样：不是换档，是不发；结果是用模型默认档）。
- **采样参数值不对**（`unsupported_value` 但没说只收默认值、或「temperature must be between…」）→ 说人话、不学、不重试。正文措辞要是既不带「only the default」也不带值，会被当成字段不收整组去。
- **脱敏只认当前这张卡的 key 和 URL 里的 query / userinfo**；正文里别的形式的凭据（比如上游另一家的 key 不在 URL 里）照原样显示。
- **测试宿主里目录是空的**，目录这一层只在单测里用注入的 catalog 测过，真目录（models.dev 缓存）没跑过整链路。

## 2. 和下一单「工具抽屉」交互的风险

- **`tool_choice`**：这单没发也没认（plan §1.2）。工具抽屉要是开始发 `tool_choice`，被拒时现在的分类器认不出（`knownFields` 里没有）→ `.unknown` 不重试。要的话在 `ParamErrorClassifier.knownFields` + `ParamCompat.Group` 加一组，builder 读 `compat.dropped`。
- **`tools` 本身被拒**（老模型不支持工具）不在这单范围，分类器不会去掉 `tools`。抽屉改 tools 形状时，400 自愈不会帮忙兜。
- **`SentShape` 只存顶层键**：抽屉要是把东西塞进嵌套字段（如 `tools[].cache_control`），报错点名嵌套路径时只会按顶层键对。
- **`ProviderRouter.sendStreaming` 多了 `attempt:` 参数**（放在 `ordered:` 后，有默认值）。抽屉改调用点时别传 1。
- **重试复用同一套回调**：抽屉要是在 `onToolCalls` 里改 router 状态（usageContext 等），重试那次会再走一遍同样的回调链；目前只有 VM 主聊天用。

## 3. 技术债务

- **后台 `sendNonStreaming`（记忆写手、摘要、标题等）不过 ParamCompat**：那些 body 本来就不带采样参数（OpenAI 兼容口连输出上限都不带，Anthropic 只带 `max_tokens`），不会撞「温度不兼容」。它们的报错也不进 400 自愈，只走脱敏后的 `extractError`。
- **分类器读两遍**：`adaptiveFailed` 判一次、`failureMessage` 说人话又判一次（同一份正文，纯函数，多花一次解析）。
- **措辞未查证的样本**：Anthropic「`temperature` is deprecated for this model」、「thinking.type.enabled is not supported… Use thinking.type.adaptive」、「temperature: range: 0..1」、OpenRouter `metadata.raw` 的外层形状、中转嵌 JSON 的样子，都是按资料 / 参照物注释还原的，不是真原文。10-14 只有「does not support assistant message prefill」是实测过的，但后半句是补的。有真原文（`CacheDiagLog` 里「✂️ 参数自适配」那条带前 300 字）就换进 `MemoryPalaceTests/Fixtures/param-errors/`。
- **没有真请求实测**（任务书禁止）。
- **记忆表不过期**（Q4 选 A），条目只增不减到 200 条上限。
- **`ParamAdaptStore` 是 `@Observable` + 锁**：写都在主线程（router 回调），读也可能在别处；观察通知跟着主线程走，没做跨线程保证。
- **设置页提示**只看「学到的 / 目录 / 血统」，不管推理档那条（开推理强度时 OpenAI 推理模型也不收温度，提示不出）。
- **说明书**：`manual/facts/model/model-api.md` 事实层已改（参数自适配、记住的参数、说人话、报错形状，带文件:行号）；`npm run check` / `rewrite` / `build` 没跑——工位里 `scripts/manual` 没装依赖（缺 gray-matter），rewrite 要调模型，本单不发请求。`manual.html` 等下次有人跑流水线时一起生成。

## 验证

- mac `build-for-testing`：`** TEST BUILD SUCCEEDED **`（10-14 18:1x，全部提交之后的树）。
- 定向（都读到 `Test Suite '…' passed`）：ParamCompatTests 11、ParamAdaptStoreTests 5、ParamErrorClassifierTests 9、ParamAutoAdaptRouterTests 9、OutputTokenCapTests 26、ReasoningEffortTests 12、PromptRealPathGoldenTests 6、InspectorRealPathTests 15、MainThreadIOBudgetTests 3、ProviderOrderingTests 12、ToolReplayTests 16、SentRequestStoreTests 4、SettingsSearchTests 33、BudgetGateTests 31（单独跑）、CardSlashRequestBodyTests 2、PersonaRequestBodyTests 4、RegexPipelineTests 18、NonStreamParseTests 5。
- 金样 G1–G6 **没重录**，原样通过（gpt-4o / claude-sonnet-4-5 都收采样，测试宿主目录为空、记忆表隔离 → 实发 body 一个字节没变，和 plan §3.9 预期一致）。
- iOS 没编（本工位只允许 mac 两种命令）。新代码没有平台分支，`DebugSettingsTab` 新 Section 用的 API 两端都有；iOS 编译交给集成区。
- 每一步是边做边提交、攒到最后一次编译验证的（编译锁排队 55 分钟），中间提交没有逐个单独编过。
- **astra 修完之后**（10-14 18:4x）：build-for-testing 再过；ParamCompatTests 11、ParamAdaptStoreTests 7、ParamErrorClassifierTests 14、ParamAutoAdaptRouterTests 13、OutputTokenCapTests 26、PromptRealPathGoldenTests 6（金样仍没重录）、InspectorRealPathTests 15、MainThreadIOBudgetTests 3、ProviderOrderingTests 12、ToolReplayTests 16、SentRequestStoreTests 4、ReasoningEffortTests 12、SettingsSearchTests 33、NonStreamParseTests 5、BudgetGateTests 31（单独跑）全部 passed。
