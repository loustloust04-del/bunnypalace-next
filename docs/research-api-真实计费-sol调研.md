# LLM API 真实计费与花费估算调研

- 调研日期：2026-10-11；只读研究，不改应用或上游仓库代码。
- 对象：Swift 原生 macOS/iOS、多 provider、用户自带 key。
- 证据标记：**代码**＝读取实现；**官方文档**＝读取供应商文档；**推测**＝工程建议，未运行验证；**未查证**＝本轮没有充分证据。
- 状态：调研完成；各节已分批保存。源码快照与研究缓存只放 `/tmp`。

## 0. 核心结论与边界

**可以做得很接近供应商计费，但无法只靠一个 tokenizer 或价格目录就让所有 provider 的数字自动等于账单。** 建议采用四层：发送前预算、真实 usage 的规则费用、供应商报告的单次费用、组织／账号账单对账。不要给四者同一个“真实费用”标签。

1. **OpenRouter 优先直接读 `usage.cost`，丢末尾 SSE 时按 generation ID 补查。** 这是本轮明确确认的普通调用单次花费路径；官方现已自动返回 usage，旧 `include:true` 已废弃。证据：第 1.1／4.2 节官方接口＋Cherry Studio、Roo Code、LiteLLM 源码。
2. **OpenAI、Anthropic、Gemini、DeepSeek 默认仍按真实 usage × 对应规则算。** OpenAI／Anthropic 有组织 Cost API，但有权限、聚合粒度与覆盖限制，不能替代普通 BYOK 聊天 key 的每次金额。证据：第 1 节官方文档。
3. **先补 provider-specific usage 语义和价格维度，再补 tokenizer。** 缓存计数包含关系、1h 写价、长 context、thinking、多模态／工具／tier 的遗漏会让事后金额系统性偏离；发送前 tokenizer 只改善预算。证据：第 2／3／4 节源码。
4. **优先借鉴 Cherry Studio 的 provenance／snapshot、LobeChat 的 usage converter、LiteLLM／Langfuse／Helicone 的规则。** Portkey 新公开价格数据可作交叉核对来源；不需要把这些服务引入客户端数据路径。全部建议属于源码支持的工程推论，未在我们的 app 实现或跑账单实验。

背景中的本 app 实现由粟粟提供，本轮没有读取／验证其源码。报告不涉及范围外站点，也没有修改任何应用或上游源码。

## 1. 供应商返回真实花费及账单接口

### 1.1 OpenRouter：当前最适合单次真实花费的路径

**官方文档。** 当前 `usage.cost` 是账号被扣的金额，`cost_details.upstream_inference_cost` 是上游成本；流式在最后一个 SSE 返回，非流式在完整响应返回。一个重要更新：`usage: {include:true}` 与 OpenRouter 的 `stream_options:{include_usage:true}` **已经废弃且无效**，usage 自动返回。这不能照搬到 OpenAI 原生接口。[Usage Accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting)

保留 response `id`，可用同一账号的 bearer key 调用 `GET https://openrouter.ai/api/v1/generation?id=gen-...`，读取 `data.total_cost`、`usage`、native token、provider、`is_byok`、tier。generation 的上游费用字段仅 BYOK 请求可用；不能把它无条件加到所有请求的 cost 上。[generation API](https://openrouter.ai/docs/api/api-reference/generations/get-request-&-usage-metadata-for-a-generation)

**精度／延迟：** 接口金额是供应商报告值，比本地模型目录乘法更接近单次扣费；文档没有保证固定小数位、generation 可查询延迟或 SLA，均为**未查证**。客户端宜保留原始金额，显示时舍入。SSE 断流可能丢失末尾 usage，generation 可作补账路径；退避重试是工程建议，不能假称某个延迟是官方保证。充值手续费、税和上游独立账单应与 inference 消费区分。

### 1.2 OpenAI：真实账单聚合可取，普通请求不返回单次美元金额

**官方文档。** `GET /v1/organization/usage/completions` 提供 token 聚合；`GET /v1/organization/costs` 返回费用 bucket 和 `amount`。当前费用 API 只支持 `1d`，支持 `project_id`、`user_id`、`line_item`、`api_key_id`、`api_source` 分组与分页；不是 response ID 查询接口。[Usage completions](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/completions)、[Costs](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs)

组织管理接口要求 Admin API key，普通聊天 key 不自动具备权限。BYOK app 的默认能力应是响应 usage × 官方规则；组织账单同步只能另做可选功能。Cost API 的更新延迟、固定金额精度及单次分摊准确度，本轮**未查证**。[Admin overview](https://developers.openai.com/api/reference/administration/overview)

### 1.3 Anthropic：组织 Cost API 有明确限制

**官方文档。** `/v1/organizations/usage_report/messages` 按分钟／小时／日统计 usage；`/v1/organizations/cost_report` 按日返回费用，金额为**美分的 decimal string**，转美元须除以 100。文档称通常请求结束后 5 分钟内出现，可持续每分钟轮询；不是立即单条费用。个人账户不可用，workspace-scoped key 不可用，需要相应组织管理凭证。Cost API 可按 workspace／description 分组，**不包含 Priority Tier 花费**，不能宣称覆盖全部组织账单。[Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)

### 1.4 Gemini／DeepSeek：本轮未找到普通生成响应的真实美元费用

Gemini token 文档提供 `usageMetadata` 和 `countTokens`，并非美元字段；DeepSeek 官方价目以 cache hit／miss 输入和输出来计费。建议仍走真实 usage × 官方规则；**“存在普通 key 的单请求 cost 查询接口”未查证**，不将“没找到”写成绝对不存在。[Gemini tokens](https://ai.google.dev/gemini-api/docs/tokens)、[DeepSeek pricing](https://api-docs.deepseek.com/quick_start/pricing/)

> 普通 BYOK key、组织管理员 key、OpenRouter 内部 BYOK 是三种不同概念。账单聚合能对账，不代表能把组织当天所有费用精确归因到某条消息。

## 2. 精确价格规则与数据源

### 2.1 LiteLLM：可参考完整计价引擎，不能只复制价格 JSON

**代码。** `cost_calculator.py` 负责分派，具体规则在 `llm_cost_calc/utils.py` 和各 provider 中。当前通用计算按**整次 prompt 长度**选择上下文价格，越过门槛后输入、输出、缓存一起换价；并非只给超过 200k 的部分涨价。`service_tier` 参与 rate key，显式 0 与缺省不同。参见 [BerriAI/litellm · `litellm/litellm_core_utils/llm_cost_calc/utils.py:630-798`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/litellm/litellm_core_utils/llm_cost_calc/utils.py#L630-L798)。

**代码。** batch 单独 rate，reasoning 有独立 rate／输出价 fallback，音频／图像有独立 bucket，缓存含 1h write。Google Search 的 `web_search_billing_unit` 分 `per_prompt`／`per_query`，不能把搜索结果条数当请求数。参见 [BerriAI/litellm · `litellm/litellm_core_utils/llm_cost_calc/utils.py:305-407`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/litellm/litellm_core_utils/llm_cost_calc/utils.py#L305-L407)、[BerriAI/litellm · `litellm/litellm_core_utils/llm_cost_calc/utils.py:1045-1133`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/litellm/litellm_core_utils/llm_cost_calc/utils.py#L1045-L1133)、[BerriAI/litellm · `litellm/llms/gemini/cost_calculator.py:29-70`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/litellm/llms/gemini/cost_calculator.py#L29-L70)。具体型号某个字段是否齐全仍须逐项核验；支持规则不代表目录每条都正确。

价格来源是仓库 `model_prices_and_context_window.json`，远程加载加打包备份；可记录 source、revision、ETag 与 fallback，值得用于账本溯源。[BerriAI/litellm · `litellm/litellm_core_utils/get_model_cost_map.py:421-479`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/litellm/litellm_core_utils/get_model_cost_map.py#L421-L479)。定时更新 workflow 每周日跑并提 PR，不能等同所有官方价格每周自动准确刷新：[BerriAI/litellm · `.github/workflows/auto_update_price_and_context_window.yml:1-39`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/.github/workflows/auto_update_price_and_context_window.yml#L1-L39)。

**不能照搬的 fallback：** 当前 LiteLLM 缺缓存价时回退输入价，缺 1h 写价时回退普通写价；它是项目策略，不是供应商已验证规则。我们要标“规则不完整”，而非把未知的价格推定为 0.1×／1.25×。[BerriAI/litellm · `litellm/litellm_core_utils/llm_cost_calc/utils.py:638-648`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/litellm/litellm_core_utils/llm_cost_calc/utils.py#L638-L648)。

### 2.2 Langfuse：优先外部提供的 cost，缺失再推导

**代码。** 有任何 `provided_cost_details` 就不继续计算其他 cost points；否则按 usage key 找 rate，使用 `Decimal.mul`。这种设计能避免真实总额和本地费用重复加算。注意它信任调用方提供的 cost，**并不意味着自动向供应商 Cost API 拉账单**。[langfuse/langfuse · `worker/src/services/IngestionService/index.ts:1696-1767`](https://github.com/langfuse/langfuse/blob/cb2cebae9f8e7d53e8e514780fce8493d680ecfb/worker/src/services/IngestionService/index.ts#L1696-L1767)。

Tier matcher 支持 usage 正则汇总阈值、`model_parameters`／metadata 条件，按优先级找首个满足项，再回 default：[langfuse/langfuse · `packages/shared/src/server/pricing-tiers/matcher.ts:18-154`](https://github.com/langfuse/langfuse/blob/cb2cebae9f8e7d53e8e514780fce8493d680ecfb/packages/shared/src/server/pricing-tiers/matcher.ts#L18-L154)。适合表达 context、tier、batch 等条件。自维护默认表位于 `worker/src/constants/default-model-prices.json`，另有每日价格 audit workflow；有审计任务不代表每天自动完成正确更新：[langfuse/langfuse · `.github/workflows/model-price-audit.yml:1-10`](https://github.com/langfuse/langfuse/blob/cb2cebae9f8e7d53e8e514780fce8493d680ecfb/.github/workflows/model-price-audit.yml#L1-L10)。

### 2.3 Helicone：provider-specific usage 语义、缓存 TTL 与模态拆分

**代码。** 同一 threshold calculator 针对 Google AI Studio 使用输入＋缓存读，针对 Anthropic 使用未缓存输入＋读＋5m 写＋1h 写；随后计算各类费用。说明“总 prompt”必须先按 provider 规范化。[Helicone/helicone · `packages/cost/models/calculate-cost.ts:114-166`](https://github.com/Helicone/helicone/blob/067d9290acb4f1fc9320e902fc67b4b399b50363/packages/cost/models/calculate-cost.ts#L114-L166)。

费用拆分包括 `cacheWrite5mCost`、`cacheWrite1hCost`、image/audio/video/file、`webSearchCost`；存在 `modelUsage.cost` 时覆盖本地总数。该判断是 truthiness，**0 cost 不走覆盖分支**，我们的实现应检查字段存在而非真假。[Helicone/helicone · `packages/cost/models/calculate-cost.ts:198-281`](https://github.com/Helicone/helicone/blob/067d9290acb4f1fc9320e902fc67b4b399b50363/packages/cost/models/calculate-cost.ts#L198-L281)。价格在 `packages/cost/models/` 自维护，OpenRouter 有抓 models API 的生成脚本；本轮未验证其自动刷新 SLA。

### 2.4 OpenLIT：有真实 usage，成本仍是本地乘法

**代码。** Python `get_chat_model_cost` 按每 1k token 的自维护价格计算输入／输出／缓存读写，`prompt_tokens_include_cache` 控制是否先减缓存，unknown model 或异常返回 0。读到的函数**没有** context tier、5m／1h split、service tier 或按次工具费用参数，不能作为全部维度准确的证明。[openlit/openlit · `sdk/python/src/openlit/__helpers.py:335-406`](https://github.com/openlit/openlit/blob/066e2c582c7e0365437f1eeda65ece4c4360ff58/sdk/python/src/openlit/__helpers.py#L335-L406)。

SDK 默认拉 GitHub 的 `assets/pricing.json`，支持替换 URL／本地文件；读取失败返回空表。[openlit/openlit · `sdk/python/src/openlit/__helpers.py:454-489`](https://github.com/openlit/openlit/blob/066e2c582c7e0365437f1eeda65ece4c4360ff58/sdk/python/src/openlit/__helpers.py#L454-L489)。Anthropic adapter 明确 `input_tokens` 不含缓存，读取响应 usage 再交给计算器：[openlit/openlit · `sdk/python/src/openlit/instrumentation/anthropic/utils.py:584-595`](https://github.com/openlit/openlit/blob/066e2c582c7e0365437f1eeda65ece4c4360ff58/sdk/python/src/openlit/instrumentation/anthropic/utils.py#L584-L595)。因此“真实 token”与“真实美元”是两件事。

### 2.5 Portkey 与 models.dev

**代码／数据 schema。** Portkey 新公开的 `Portkey-AI/models` 比只读 Gateway 更有价值：价格 JSON 有 `calculate` 算式树、`additional_units.cache_write_1h`、`batch_config`、按 region／execution_modes 选 standard／batch／fast 的配置。Google 部分用 `...-lte-200k`／`...-gt-200k` 分开记录，而非一个输入输出价格。[Portkey-AI/models · `pricing/anthropic.json:85-112`](https://github.com/Portkey-AI/models/blob/3da190b394705621abc08a1b06141e79e9e73c7b/pricing/anthropic.json#L85-L112)、[Portkey-AI/models · `pricing/anthropic.json:795-860`](https://github.com/Portkey-AI/models/blob/3da190b394705621abc08a1b06141e79e9e73c7b/pricing/anthropic.json#L795-L860)、[Portkey-AI/models · `pricing/google.json:2236-2303`](https://github.com/Portkey-AI/models/blob/3da190b394705621abc08a1b06141e79e9e73c7b/pricing/google.json#L2236-L2303)。

**单位特别不同：美分／token 或美分／unit**，美元总额＝数量×price／100；不是 USD／token。[Portkey-AI/models · `openapi.yaml:7-20`](https://github.com/Portkey-AI/models/blob/3da190b394705621abc08a1b06141e79e9e73c7b/openapi.yaml#L7-L20)、[Portkey-AI/models · `openapi.yaml:64-70`](https://github.com/Portkey-AI/models/blob/3da190b394705621abc08a1b06141e79e9e73c7b/openapi.yaml#L64-L70)。main 的 JSON 更新经 workflow 验证再上传／同步；sync 脚本目标是 `gateway-enterprise-node` 的 `src/services/winky/configs`，本轮**未读到该非公开运行引擎**，不能保证 schema 每个算式执行或账单精度。[Portkey-AI/models · `.github/workflows/sync-to-s3.yml:1-23`](https://github.com/Portkey-AI/models/blob/3da190b394705621abc08a1b06141e79e9e73c7b/.github/workflows/sync-to-s3.yml#L1-L23)、[Portkey-AI/models · `scripts/sync-to-gateway.js:3-21`](https://github.com/Portkey-AI/models/blob/3da190b394705621abc08a1b06141e79e9e73c7b/scripts/sync-to-gateway.js#L3-L21)。

**官方文档。** OpenRouter models API 不仅有 prompt/completion，还支持 cache、reasoning、request、image、web_search 单位价和 `pricing.overrides`：按 prompt threshold、UTC 时间窗等覆盖，条件里 `min_prompt_tokens` 是严格大于。标价来自 top provider，不能代表路由后所有 endpoint 的收费。[Models schema / Pricing Overrides](https://openrouter.ai/docs/guides/overview/models)

**代码。** 当前 models.dev schema 已有 `reasoning`、`input_audio`、`output_audio`、`cache_read`／`cache_write`、任意 context `tiers`，输出兼容 `context_over_200k`。因此问题不只是目录“只有一对输入输出价”，也可能是消费侧丢了维度。但当前这个 Cost schema 没有 5m／1h、按次工具、storage-time、service tier 字段：[anomalyco/models.dev · `packages/core/src/schema.ts:73-112`](https://github.com/anomalyco/models.dev/blob/e6932ba604bb3644f62993c19ad5d93a47490aac/packages/core/src/schema.ts#L73-L112)。

**models.dev 更新：代码。** 当前 sync workflow 每小时第 17 分运行，checkout `dev`，按 provider 拉模型目录，校验后通过自动化分支／PR 报告变化；这不等于每个价格都即时更新到发布目录。[anomalyco/models.dev · `.github/workflows/sync-models.yml:1-25`](https://github.com/anomalyco/models.dev/blob/e6932ba604bb3644f62993c19ad5d93a47490aac/.github/workflows/sync-models.yml#L1-L25)、[anomalyco/models.dev · `.github/workflows/sync-models.yml:110-148`](https://github.com/anomalyco/models.dev/blob/e6932ba604bb3644f62993c19ad5d93a47490aac/.github/workflows/sync-models.yml#L110-L148)。OpenRouter importer 把带 `min_prompt_tokens` 且输入／输出价齐全的 override 转为 context tier；读到的函数**不保留时间窗条件**。不能用转换后的通用目录替代所有 endpoint 的完整价格规则。[anomalyco/models.dev · `packages/core/src/sync/providers/openrouter.ts:180-195`](https://github.com/anomalyco/models.dev/blob/e6932ba604bb3644f62993c19ad5d93a47490aac/packages/core/src/sync/providers/openrouter.ts#L180-L195)。

### 2.6 必须表达的价格维度与官方语义

| 维度 | 要表达的规则 | 已读取证据 |
| --- | --- | --- |
| 长上下文 | 按 model 的 prompt 门槛选择整个请求费率；边界 `>`／`>=` 需明确；不能把 200k 写成所有型号的规则 | LiteLLM／Helicone 上述代码；[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing) |
| Anthropic 缓存 | 读取 `cache_creation.ephemeral_5m_input_tokens`／`ephemeral_1h_input_tokens`，两者之和等于 aggregate write，不能重复加算；常见写价 1.25×／2×、读价 0.1×，**存在型号读价例外**，不得全局套倍率 | [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing)、[Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)、Helicone 上述代码 |
| batch | 单独执行模式及 rate；Claude Message Batches 明确 50% 折扣；不要用“延迟请求”自动推定 batch | [Claude batch](https://platform.claude.com/docs/en/build-with-claude/batch-processing)、LiteLLM batch rates |
| reasoning／thinking | OpenAI／Anthropic 的输出总量含相应思考计费时不能再加一次；Gemini `candidatesTokenCount` 与 `thoughtsTokenCount` 要分清 | 见第 4 节 LobeChat usage converter；[OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning)、Gemini pricing |
| 图片／音频 | 接收模态 token breakdown，必要时按张、分辨率、秒等计量；文本 tokenizer 不覆盖附件 | Helicone 上述代码、[OpenAI pricing](https://developers.openai.com/api/docs/pricing) |
| 搜索／执行／存储 | 输入 token 之外可能有按调用／query／容器／时间的费用；搜索次数、搜索结果数不是同一量；Gemini 显式缓存还有 token-hour 存储费 | LiteLLM Gemini calculator、Gemini pricing、OpenAI pricing |
| priority／flex | 记录响应实际 `service_tier` 并选择匹配表；fallback 至标准价应标规则缺失 | LiteLLM 上述代码；[OpenAI Flex](https://developers.openai.com/api/docs/guides/flex-processing) |
| 免费额度／合同价／优惠／税 | 不能从每次 token 数单独推断账号级净账单 | **推测**：需账单对账和账号规则；本轮未验证每家结算细节 |

**单位陷阱：** models.dev 常用 USD／1M token；LiteLLM 字段是 USD／token；OpenLIT 函数表是 USD／1k；Portkey 价格数据是美分／token 或 unit；Anthropic Cost API 是美分。输入统一化时必须带原单位与币种。

## 3. 发送前 token 与费用预估

### 3.1 供应商 count API：Swift 可以直接 HTTP 调用

| Provider | 发送前入口 | 能准确到什么程度 | 证据 |
| --- | --- | --- | --- |
| OpenAI | `POST /v1/responses/input_tokens`，带目标 model 与实际 input／tools 等支持字段，返回 `input_tokens` | 供应商按请求计数；不是输出预测、cache hit 预测或 cost 接口；本轮没有核实计数接口费用／限流／全模型支持范围 | **官方文档**：[input tokens API](https://developers.openai.com/api/reference/resources/responses/subresources/input_tokens/methods/count) |
| Anthropic | `POST /v1/messages/count_tokens`，目标 model、system、messages、tools | 官方明确仍为 estimate，与生成时可能有小差异；免费、独立限流；不执行缓存命中逻辑；当前文档列出部分 server tools、MCP、URL／file 图片文档输入不支持 | **官方文档**：[Token counting](https://platform.claude.com/docs/en/build-with-claude/token-counting) |
| Gemini | `POST /v1beta/models/{model}:countTokens`，用实际 contents／生成请求支持结构 | 服务端计数支持多模态；执行后的 usage 才包含生成与思考结果。工具 schema、system、附件必须走最终 payload 对应结构 | **官方文档**：[Count tokens guide](https://ai.google.dev/gemini-api/docs/tokens) |
| DeepSeek | 本轮未确认一个通用线上 count endpoint | 官方提供离线 tokenizer zip；其字符换算只是大概比例，最终以响应 usage 为准；zip 是否匹配全部当前型号未查证 | **官方文档＋未查证接口**：[Token Usage / 离线 tokenizer](https://api-docs.deepseek.com/quick_start/token_usage/)；客户端例见 Chatbox |
| OpenRouter | 普通 completion 自动带 native tokenizer 的事后 usage | 本轮未确认支持所有上游的统一发送前 count API | **官方文档**：第 1 节 Usage Accounting |

**推测／建议。** 原生端用 `URLSession` 就能调用这些接口，不需要嵌 Python，也不需要额外中间服务。输入框即时数字用本地快速计数；发送前或接近上下文门槛时再对**最终请求**调用官方 count，按 provider＋model＋payload hash 短期缓存结果。额外请求的网络延迟、限流、附件再上传成本需要 UI 合并和 debounce；本轮未在 iOS／macOS 验证。

### 3.2 已读到的本地 tokenizer 实践

- **Cherry Studio：代码。** OpenAI 方言用 `gpt-tokenizer/encoding/o200k_base` 真 BPE，约 2.2 MB ranks，lazy load；其他方言用 `tokenx`。源码自己指出 OpenAI-compatible 的其他模型使用该 BPE 仍只是近似。[CherryHQ/cherry-studio · `src/main/ai/tokens/textTokenizer.ts:1-39`](https://github.com/CherryHQ/cherry-studio/blob/506264e73ad6d8cff3570fdba6231e6aab6df9b6/src/main/ai/tokens/textTokenizer.ts#L1-L39)。
- **Chatbox：代码。** 默认 `js-tiktoken/lite`＋`cl100k_base`；DeepSeek 则按中文约 0.6、ASCII 约 0.3 加权，不是其真实 BPE。真 tokenizer 只在 encoding 匹配时成立。[chatboxai/chatbox · `src/shared/token-estimation/tokenizer.ts:8-37`](https://github.com/chatboxai/chatbox/blob/0ac6385ae1ff5bf778777826da3c5edcd55b61b8/src/shared/token-estimation/tokenizer.ts#L8-L37)、[chatboxai/chatbox · `src/shared/token-estimation/tokenizer.ts:96-140`](https://github.com/chatboxai/chatbox/blob/0ac6385ae1ff5bf778777826da3c5edcd55b61b8/src/shared/token-estimation/tokenizer.ts#L96-L140)。
- **NextChat：代码。** ASCII 字母约 0.25、其他 ASCII 0.5、非 ASCII 1.5，是字符启发式；可用于上下文裁剪提示，不能证明费用精度。[ChatGPTNextWeb/NextChat · `app/utils/token.ts:1-22`](https://github.com/ChatGPTNextWeb/NextChat/blob/839a24df5d655eb8c3477fb35e8da578dc206f39/app/utils/token.ts#L1-L22)。
- **Langfuse：代码。** tiktoken 加每条 message／name overhead，unknown encoding 回 `cl100k_base`；Claude 使用旧的 `@anthropic-ai/tokenizer`，不证明覆盖当前全部 Claude 模型。[langfuse/langfuse · `worker/src/features/tokenisation/usage.ts:1-35`](https://github.com/langfuse/langfuse/blob/cb2cebae9f8e7d53e8e514780fce8493d680ecfb/worker/src/features/tokenisation/usage.ts#L1-L35)、[langfuse/langfuse · `worker/src/features/tokenisation/usage.ts:168-226`](https://github.com/langfuse/langfuse/blob/cb2cebae9f8e7d53e8e514780fce8493d680ecfb/worker/src/features/tokenisation/usage.ts#L168-L226)。
- **tokencost：代码。** OpenAI 用 tiktoken 和 ChatML overhead；Claude 有调用 `Anthropic().beta.messages.count_tokens` 的路径，但 model 支持列表硬编码、注释仍称 beta。应参考调用方式，不能照搬旧列表。[AgentOps-AI/tokencost · `tokencost/costs.py:162-191`](https://github.com/AgentOps-AI/tokencost/blob/e7f7c1928084af55bb4955102327982401ed8649/tokencost/costs.py#L162-L191)、[AgentOps-AI/tokencost · `tokencost/costs.py:203-276`](https://github.com/AgentOps-AI/tokencost/blob/e7f7c1928084af55bb4955102327982401ed8649/tokencost/costs.py#L203-L276)。

### 3.3 Swift 本地 BPE 的可行性及限制

**代码。** [aespinilla/Tiktoken](https://github.com/aespinilla/Tiktoken) 是 SwiftPM 包，声明 iOS 13／macOS 10.15 以上；有 BPE 编码实现和 URLSession 词表下载＋本地 cache。但读到的 model mapping 只到旧 GPT-4／GPT-3.5 的 `cl100k_base`，不能把它称为当前 `o200k_base`／所有 OpenAI 模型即插即用支持。参见 [aespinilla/Tiktoken · `Package.swift:1-29`](https://github.com/aespinilla/Tiktoken/blob/4ad6460448278f7a28f1e4ee2723500369f20acb/Package.swift#L1-L29)、[aespinilla/Tiktoken · `Sources/Tiktoken/Model.swift:20-68`](https://github.com/aespinilla/Tiktoken/blob/4ad6460448278f7a28f1e4ee2723500369f20acb/Sources/Tiktoken/Model.swift#L20-L68)、[aespinilla/Tiktoken · `Sources/Tiktoken/Load.swift:85-106`](https://github.com/aespinilla/Tiktoken/blob/4ad6460448278f7a28f1e4ee2723500369f20acb/Sources/Tiktoken/Load.swift#L85-L106)。

**推测／建议。** 真正选型要核对目标 encoding 的 ranks、pre-tokenization regex、Unicode 行为、special token、工具消息模板，并以官方 tokenizer 同一测试向量校验。词表离线打包、后台 actor 计数可避免输入框网络与主线程压力。也可用经过校验的 Rust／C tokenizer 桥接；本轮没有做桥接、性能或移动端包大小实测，因此不指定它为已验证最优依赖。

### 3.4 “误差多大”的可证实边界

**没有查到这些项目对“多 provider、多语言、工具、多模态最终请求”的可信统一误差百分比。** 不写“启发式误差 10%”或“BPE 99% 准确”。Anthropic 文档只称可能有小差异，未给误差上界；不同模型版本的 tokenizer 也会变化。把 Chatbox 默认 `cl100k` 或任意字符系数用于所有 provider，没有已证实的误差保障。

**推测／建议。** 验收时分别测：(a) preflight 输入 count 对最终 usage 输入的绝对差／相对差；(b) 单次规则费用对供应商 reported cost；(c) 日聚合对 Cost API。覆盖中文、英文、代码、emoji、tools、图片、PDF、长上下文边界、缓存 TTL、thinking。按 provider＋model＋请求形态报告 P50／P95 与偏差，不能把 token 误差当美元误差。

发送前即使输入 token 精确，也无法预知实际输出／thinking 长度、缓存命中、动态路由、工具执行次数；应该显示**输入估值＋输出预算区间**，而非一条必定等于账单的总额。此项为工程推论。

## 4. 同类客户端与工具源码对照

下表是**读到的指定路径结论**，不把局部搜索无结果扩大为“整个项目没有此功能”。代码引用均固定提交；仓库默认分支有重命名／重构时仍用实际 canonical repository。可观测平台详见第 2 节。

| 项目 | 读到的计数／费用做法 | 对我们有用或应避免的地方 | 证据强度与出处 |
| --- | --- | --- | --- |
| LobeChat／LobeHub | `computeChatCost` 支持 fixed、tiered、lookup；按 total prompt 选整次价格，有模态、cache、reasoning bucket，缺 lookup 参数输出 issue | 最值得读 usage 归一化。支持 schema 不等于所有 provider 被正确覆盖；读到的 Anthropic converter 只有合并 cache write，未保留 5m／1h 分拆 | **代码**：[lobehub/lobehub · `packages/model-runtime/src/core/usageConverters/utils/computeChatCost.ts:274-305`](https://github.com/lobehub/lobehub/blob/ca2b24cfdf22739fdb58cfe8ae7c96290a58214c/packages/model-runtime/src/core/usageConverters/utils/computeChatCost.ts#L274-L305)、[lobehub/lobehub · `packages/model-runtime/src/core/usageConverters/utils/computeChatCost.ts:430-486`](https://github.com/lobehub/lobehub/blob/ca2b24cfdf22739fdb58cfe8ae7c96290a58214c/packages/model-runtime/src/core/usageConverters/utils/computeChatCost.ts#L430-L486)、[lobehub/lobehub · `packages/model-runtime/src/core/usageConverters/anthropic.ts:7-30`](https://github.com/lobehub/lobehub/blob/ca2b24cfdf22739fdb58cfe8ae7c96290a58214c/packages/model-runtime/src/core/usageConverters/anthropic.ts#L7-L30) |
| Cherry Studio | registry 将 OpenRouter 标为 `reportsActualCost:true`、USD；提取顶层或 `usage.cost`，实际成本优先，本地公式次之；保存 `costSource`、pricingSnapshot | 非常贴合 BYOK 本地账本；0 真实费用允许；缓存 unknown 回输入价仍是策略，不是官方证明；本地通用 bucket 未分写 TTL | **代码**：[CherryHQ/cherry-studio · `packages/provider-registry/src/providers/openrouter.ts:7-16`](https://github.com/CherryHQ/cherry-studio/blob/506264e73ad6d8cff3570fdba6231e6aab6df9b6/packages/provider-registry/src/providers/openrouter.ts#L7-L16)、[CherryHQ/cherry-studio · `src/main/ai/utils/billingCost.ts:5-53`](https://github.com/CherryHQ/cherry-studio/blob/506264e73ad6d8cff3570fdba6231e6aab6df9b6/src/main/ai/utils/billingCost.ts#L5-L53)、[CherryHQ/cherry-studio · `src/main/data/services/AiUsageRecordService.ts:1270-1323`](https://github.com/CherryHQ/cherry-studio/blob/506264e73ad6d8cff3570fdba6231e6aab6df9b6/src/main/data/services/AiUsageRecordService.ts#L1270-L1323) |
| Chatbox | shared tokenizer 默认真 `cl100k_base`，DeepSeek 启发式；此前 tokenizer 错误会回 0，但给 logger seam | 可借鉴本地轻量依赖；不能把 0 当真的零 token；本轮未证实完整官方账单对账引擎 | **代码**：第 3 节 tokenizer 引用；[chatboxai/chatbox · `src/shared/token-estimation/tokenizer.ts:17-37`](https://github.com/chatboxai/chatbox/blob/0ac6385ae1ff5bf778777826da3c5edcd55b61b8/src/shared/token-estimation/tokenizer.ts#L17-L37) |
| NextChat | `estimateTokenLength` 字符加权，chat store 用它统计／裁剪历史 | 与现有 HeuristicEstimator 同类，不能帮助事后费用对账；本轮未证明读取供应商真实金额 | **代码**：[ChatGPTNextWeb/NextChat · `app/utils/token.ts:1-22`](https://github.com/ChatGPTNextWeb/NextChat/blob/839a24df5d655eb8c3477fb35e8da578dc206f39/app/utils/token.ts#L1-L22)、[ChatGPTNextWeb/NextChat · `app/store/chat.ts:148-166`](https://github.com/ChatGPTNextWeb/NextChat/blob/839a24df5d655eb8c3477fb35e8da578dc206f39/app/store/chat.ts#L148-L166) |
| Open WebUI | `normalize_usage` 保留 raw fields；`merge_usage` 可累计 `cost`／`total_cost` 和细项，middleware 将多调用 usage 入消息／DB | 已有费用透传与多请求汇总，不宜说“完全无 cost tracking”；读到的路径没有供应商 Cost API 对账或完整规则引擎证明 | **代码**：[open-webui/open-webui · `backend/open_webui/utils/response.py:13-65`](https://github.com/open-webui/open-webui/blob/f8ae8a6c328946dc62cd0712961a0632574581bf/backend/open_webui/utils/response.py#L13-L65)、[open-webui/open-webui · `backend/open_webui/utils/response.py:100-143`](https://github.com/open-webui/open-webui/blob/f8ae8a6c328946dc62cd0712961a0632574581bf/backend/open_webui/utils/response.py#L100-L143)、[open-webui/open-webui · `backend/open_webui/utils/middleware.py:5216-5264`](https://github.com/open-webui/open-webui/blob/f8ae8a6c328946dc62cd0712961a0632574581bf/backend/open_webui/utils/middleware.py#L5216-L5264) |
| LibreChat | 自维护 `tx.ts` 输入输出／缓存价、premiumTokenValues；spendStructuredTokens 保存 input/read/write 并以总 input 选费率；可 YAML／OpenRouter 配置覆盖 | 是应用自己的 token transaction／balance 体系，并非供应商扣费接口；不要把内部 balance 当外部账单。读到结构没有 1h write 专桶 | **代码**：[LibreChat-AI/LibreChat · `packages/data-schemas/src/methods/tx.ts:359-496`](https://github.com/LibreChat-AI/LibreChat/blob/e1dfc10449ff713faffacd60273fddcfe2c0a698/packages/data-schemas/src/methods/tx.ts#L359-L496)、[LibreChat-AI/LibreChat · `packages/data-schemas/src/methods/spendTokens.ts:93-138`](https://github.com/LibreChat-AI/LibreChat/blob/e1dfc10449ff713faffacd60273fddcfe2c0a698/packages/data-schemas/src/methods/spendTokens.ts#L93-L138)、[LibreChat-AI/LibreChat · `packages/api/src/endpoints/pricing.ts:52-97`](https://github.com/LibreChat-AI/LibreChat/blob/e1dfc10449ff713faffacd60273fddcfe2c0a698/packages/api/src/endpoints/pricing.ts#L52-L97) |
| SillyTavern | 多种 tokenizer（tiktoken／SentencePiece／web tokenizer），含可下载 DeepSeek 词表；OpenRouter UI 用 models API 价 × 配置 max context／max output 显示最大 prompt cost，加搜索费用常数 | 展示的费用是预算上限式估算，不是实际 prompt 或账单；下载词表须核对版本，旧 Claude tokenizer 不代表当前准确 | **代码**：[SillyTavern/SillyTavern · `src/endpoints/tokenizers.js:251-264`](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/src/endpoints/tokenizers.js#L251-L264)、[SillyTavern/SillyTavern · `public/scripts/openai.js:1803-1827`](https://github.com/SillyTavern/SillyTavern/blob/06bde939fb1e9c4c8d8641d810f0a916b5bce127/public/scripts/openai.js#L1803-L1827) |
| Jan | `useTokensCount` 读取最近服务端 usage、live local stats、local model context props | 读到的是上下文与 token 指标，未查证云端美元规则或 Cost API 对账；本地 tokenizer／免费本地推理不应与云 API spend 混同 | **代码**：[janhq/jan · `web-app/src/hooks/useTokensCount.ts:71-110`](https://github.com/janhq/jan/blob/f2cd837fabe99cd6b8bbe985891bab8782e4034b/web-app/src/hooks/useTokensCount.ts#L71-L110) |
| ccusage | 本轮当前实现已以 Rust core 为主；`auto` 优先 JSONL 的 `cost_usd`，缺失按 price × usage；`display` 只显示日志金额，`calculate` 重算；读取 5m／1h 分拆及长上下文 | 三种模式和历史价格有借鉴价值；日志 `costUSD` 是否为真实扣款需看日志生产者，**不是因为字段叫 cost 就证明 invoice 一致**。Claude Code 订阅场景的 API 等价价格也不等于实际订阅账单 | **代码**：[ccusage/ccusage · `rust/crates/ccusage-core/src/cost.rs:9-45`](https://github.com/ccusage/ccusage/blob/b4507e731b318c5a954c448db6602dc8241b7571/rust/crates/ccusage-core/src/cost.rs#L9-L45)、[ccusage/ccusage · `rust/crates/ccusage-core/src/cost.rs:93-160`](https://github.com/ccusage/ccusage/blob/b4507e731b318c5a954c448db6602dc8241b7571/rust/crates/ccusage-core/src/cost.rs#L93-L160)；数据来源 [ccusage/ccusage · `rust/crates/ccusage-core/src/pricing.rs:54-85`](https://github.com/ccusage/ccusage/blob/b4507e731b318c5a954c448db6602dc8241b7571/rust/crates/ccusage-core/src/pricing.rs#L54-L85) |
| tokencost（AgentOps） | LiteLLM price data 本地快照＋可 refresh；输入输出／cached token 乘价，Python Decimal；Claude count API、OpenAI tiktoken | 轻量估算库，并非复用 LiteLLM JSON 就自动拥有整个 cost_calculator 的 tier／TTL／工具逻辑 | **代码**：[AgentOps-AI/tokencost · `tokencost/constants.py:27-82`](https://github.com/AgentOps-AI/tokencost/blob/e7f7c1928084af55bb4955102327982401ed8649/tokencost/constants.py#L27-L82)、[AgentOps-AI/tokencost · `tokencost/costs.py:308-333`](https://github.com/AgentOps-AI/tokencost/blob/e7f7c1928084af55bb4955102327982401ed8649/tokencost/costs.py#L308-L333)；计数见第 3 节 |
| Aider（补充） | model 层委托 LiteLLM 计数与上下文；适合说明非 UI 客户端复用统一库的方式 | Python 应用的复用方式不能直接搬进 iOS；Swift 更适合消费规则数据或移植有限规则 | **代码**：[Aider-AI/aider · `aider/models.py:650-669`](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/models.py#L650-L669) |

ccusage 的 price snapshots 当前每小时自动更新 LiteLLM 和 models.dev 两路输入：[ccusage/ccusage · `.github/workflows/update-pricing.yaml:1-35`](https://github.com/ccusage/ccusage/blob/b4507e731b318c5a954c448db6602dc8241b7571/.github/workflows/update-pricing.yaml#L1-L35)。这证明更新策略，不证明日志金额就是实际扣款。

### 4.1 一定要读的 usage 语义实例

**LobeChat：代码。** OpenAI `completion_tokens` 已含 reasoning，converter 用减法得到 text bucket，另留 reasoning；Gemini 则将 candidates＋thoughts 作为 total output。不要把两个 provider 都统一做 `completion + reasoning`。[lobehub/lobehub · `packages/model-runtime/src/core/usageConverters/openai.ts:97-127`](https://github.com/lobehub/lobehub/blob/ca2b24cfdf22739fdb58cfe8ae7c96290a58214c/packages/model-runtime/src/core/usageConverters/openai.ts#L97-L127)、[lobehub/lobehub · `packages/model-runtime/src/core/usageConverters/google-ai.ts:16-59`](https://github.com/lobehub/lobehub/blob/ca2b24cfdf22739fdb58cfe8ae7c96290a58214c/packages/model-runtime/src/core/usageConverters/google-ai.ts#L16-L59)。

**Cherry Studio：代码。** 每个上游调用独立入 usage row；UI 可以累计 token，但 raw usage 只保留最后一步，源码警告不得用这个 raw 推导累计供应商费用。应对每次 invocation 的金额求和。[CherryHQ/cherry-studio · `src/main/ai/runtime/aiSdk/observers/usage.ts:13-21`](https://github.com/CherryHQ/cherry-studio/blob/506264e73ad6d8cff3570fdba6231e6aab6df9b6/src/main/ai/runtime/aiSdk/observers/usage.ts#L13-L21)、[CherryHQ/cherry-studio · `src/main/ai/runtime/aiSdk/observers/usage.ts:42-66`](https://github.com/CherryHQ/cherry-studio/blob/506264e73ad6d8cff3570fdba6231e6aab6df9b6/src/main/ai/runtime/aiSdk/observers/usage.ts#L42-L66)。

### 4.2 OpenRouter 客户端／SDK补充

**Roo Code：代码。** `OpenRouterHandler` 收集流中最后的 `chunk.usage`，直接输出 `totalCost`，并保留输入／输出／cacheRead／reasoning。这是明确“用了返回金额而非单价乘法”的客户端例子。[RooCodeInc/Roo-Code · `src/api/providers/openrouter.ts:475-495`](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/api/providers/openrouter.ts#L475-L495)。

**应谨慎借鉴：** 它的 `totalCost` 无条件相加 `upstream_inference_cost + cost`，适用于展示某些 BYOK 的总支出，但不等于单独 OpenRouter 账号扣费；普通请求、OpenRouter BYOK、重复语义的字段必须分开处理，不能照抄成通用账单公式。其请求仍传 `include_usage:true`，当前 OpenRouter 官方已称无效，说明代码也可能滞后。[RooCodeInc/Roo-Code · `src/api/providers/openrouter.ts:304-313`](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/api/providers/openrouter.ts#L304-L313)、第 1 节官方来源。

**openrouter-go：代码。** SDK 的 `Usage.Cost` 是 `*float64`，能够区分缺失与 0；同时保留 `IsBYOK` 和 `CostDetails`。另有明确名为 EstimateCost 的本地乘法 helper，不混成唯一金额。[hra42/openrouter-go · `models.go:237-269`](https://github.com/hra42/openrouter-go/blob/b49f991c6ebf34180f3a50804551f692f7f98be1/models.go#L237-L269)、[hra42/openrouter-go · `cost.go:40-64`](https://github.com/hra42/openrouter-go/blob/b49f991c6ebf34180f3a50804551f692f7f98be1/cost.go#L40-L64)。Go 不能直接用于 Swift，但字段／状态设计可以照此分开。

**LiteLLM：代码。** OpenRouter Responses adapter 从 `response.usage.cost` 读取，并保存在 provider-reported cost header；成本分派读取该值作为优先路径。[BerriAI/litellm · `litellm/llms/openrouter/responses/transformation.py:75-103`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/litellm/llms/openrouter/responses/transformation.py#L75-L103)、[BerriAI/litellm · `litellm/cost_calculator.py:1974-1989`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/litellm/cost_calculator.py#L1974-L1989)、[BerriAI/litellm · `litellm/cost_calculator.py:2054-2067`](https://github.com/BerriAI/litellm/blob/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5/litellm/cost_calculator.py#L2054-L2067)。

本轮**未确认一个当前客户端的 generation 退避补账实现**；报告中的 generation 路径依据官方 API，不冒充已验证的第三方实现。

### 4.3 是否直接用供应商组织账单 API？

本轮已读的上述客户端路径，**没有确认一个把普通聊天 key 自动升级为 OpenAI／Anthropic 组织账单权限、再精确分配到每条消息的实现**。这是局部源码与官方权限／聚合模型共同支持的限制，不是全 GitHub 项目的否定断言。管理员报表集成和普通 BYOK 客户端是不同产品能力。

## 5. 推荐的 Swift BYOK 分层方案

### 5.1 每个 provider 的默认能力

| Provider | 单次费用主路径 | 必补规则／限制 | 推荐依据强度 |
| --- | --- | --- | --- |
| OpenRouter | `usage.cost` → 保存 provider-reported；缺失时 generation ID 异步补查；缺金额才本地 provisional estimate | 原始币种／金额，provider／model／tier；上游 BYOK 花费与 OpenRouter 扣费分栏，不能无条件相加；末尾 SSE 丢失不得记 0 | **代码＋官方文档**：Cherry／Roo／Go／LiteLLM 第 4.2 节及第 1.1 节 |
| OpenAI | 真实响应 usage × 对应型号／日期／tier 规则；可选 admin 日账单对账 | 输入内 cached 子集先扣再计；reasoning 通常含于 output；音频／图像；服务端搜索／执行／存储；batch／priority／flex；价格表缺字段就标 partial | **代码＋官方文档**：Lobe usage converter 第 4.1 节、LiteLLM 第 2 节、官方 pricing；组织 API 第 1.2 节 |
| Anthropic | `input_tokens`＋各缓存项＋`output_tokens` 分别计价；可选组织 Cost API | input 不含 cache read／write；5m／1h 写拆桶；门槛需用完整 prompt；模型例外不能套固定 0.1×；web search／execution／batch／speed；Priority 合同费用另处理 | **代码＋官方文档**：Helicone／OpenLIT／Portkey 第 2 节、Claude pricing／cache 文档、第 1.3 节 |
| Gemini | `usageMetadata` × 规则 | cached 是 prompt 子集；candidates＋thoughts；audio／image 模态；toolUsePromptTokenCount 及实际 search query 计量；long-context、batch、免费额度；显式 cache token-hour 单列 | **代码＋官方文档**：Lobe Google converter 第 4.1 节、LiteLLM Gemini calculator 第 2 节、Gemini pricing |
| DeepSeek | 响应 prompt/completion 及 hit/miss × 官方价格 | 验证 hit/miss 总量关系，thinking 是否已含 completion；模型版本和实际官方 endpoint 价格，不套 OpenRouter 或别家托管同名模型价格 | **官方文档＋局部代码**：DeepSeek pricing 第 1.4 节；Lobe OpenAI converter 兼容 hit/miss 第 4.1 节。普通 key 单次美元 API **未查证** |

### 5.2 分层与数字命名

**以下均为建议／推测，有对应源码设计证据；不是本 app 已实现能力。**

| 层 | 建议显示／账本类型 | 依据 |
| --- | --- | --- |
| A 发送前 | `estimated`：输入 count 来源（provider count／本地 BPE／heuristic）、输出预算区间、缓存 hit/miss 两种情景 | 官方 count API 与第 3 节源码。输出／工具未知，不能承诺精确单个总价 |
| B 事后规则费用 | `calculated`：真实 usage、使用的价格快照、已覆盖／未覆盖的计价维度 | Cherry pricingSnapshot、LiteLLM／Helicone／Langfuse 规则；真实 token 并不自动保证价格完整 |
| C 单次供应商金额 | `providerReported`：读取真实金额覆盖展示值，保留本地 calculated 供比较；金额存在且 0 也优先 | [CherryHQ/cherry-studio · `src/main/data/services/AiUsageRecordService.ts:1272-1317`](https://github.com/CherryHQ/cherry-studio/blob/506264e73ad6d8cff3570fdba6231e6aab6df9b6/src/main/data/services/AiUsageRecordService.ts#L1272-L1317)、[hra42/openrouter-go · `models.go:237-269`](https://github.com/hra42/openrouter-go/blob/b49f991c6ebf34180f3a50804551f692f7f98be1/models.go#L237-L269) |
| D 聚合账单核对 | `reconciled`：只在供应商账号／project／workspace 同一时间范围内比较完整费用，记录差额；不按 token 比例伪造“每条已对账” | OpenAI／Anthropic 官方 Cost API 第 1 节；每条分配方案未获得精确接口证据 |

金额不要将 `unknown`、`partial`、`pending` 转成 0。缺价格维度时，可显示“已知部分金额＋未覆盖项”，该条不计入“已完整计价条数”。来源数据本身可能返回 0；显式的 0 和缺字段必须分开。证据：Cherry 在非零桶缺 rate 时不生成完整成本、Go 的 optional cost；Helicone truthiness 的反例，第 2／4 节。

### 5.3 保留现有 usage.jsonl，但让它可复算与补账

建议每次**上游 invocation**保存：provider／请求 endpoint／requested 和 resolved model、response／generation ID、UTC 时间、key 的非秘密标识、operation／batch／实际 service tier、原始 usage（保留未来字段）、规范化且互斥的计价桶、tool 次数与缓存 TTL／存储时长、`costSource`、原币种／原始金额、price source／revision／effective time／snapshot、missing dimensions。多次 agent／工具循环分别记账，再按 message／turn 聚合。

原始计数的“包含关系”要明确：OpenAI cached／reasoning 是总量子集时不能再加到总量；Anthropic 缓存项通常另加到 input 才是总 prompt；Gemini candidates 和 thoughts 需分别处理。具体响应形态优先于模型名猜测。依据：第 4.1 节三个 usage converter。

**推测。** Swift 用 `Decimal`（从原始十进制字符串构造）或明确刻度整数处理金额和单价；不要在每桶中途四舍五入，再显示时舍入。JSON 数字若先过 `Double` 会丢原始十进制表达，因此 provider 金额保留原 payload。补查得到真实费用后，JSONL 追加引用同一 invocation 的 correction／settlement 事件，聚合只取最新有效版本，避免 calculated 与 providerReported 双计。Langfuse 的 Decimal 运算与 provided cost 优先、Cherry 的冻结快照支持这个方向，但具体事件格式未实现／未验证。

### 5.4 价格数据更新：目录与规则分工

**建议／推测。** 保留 models.dev 做模型发现和基础价格，正确读取已有 `tiers`／reasoning／audio；从 LiteLLM 或 Portkey 数据补我们实际支持的型号／维度。对重要 provider 以官方价目和 response usage 契约核对，不整体盲合并，也不按同名模型跨 provider 搬价。

价格快照至少记录数据版本、获取日期、有效起止时间、币种和单位、provider／model／operation／tier／context predicate；换价不应重写过去消费的历史单价。采用随 app 打包的快照＋可更新缓存；远程数据异常保留 last known good 并显示时效。更新频率可按日检查，但这是我们的选择，非“GitHub 目录每天保证同步”。证据：LiteLLM source metadata、Cherry 冻结 snapshot、ccusage `find_at` 路径：[CherryHQ/cherry-studio · `src/main/ai/utils/usageCapture.ts:53-103`](https://github.com/CherryHQ/cherry-studio/blob/506264e73ad6d8cff3570fdba6231e6aab6df9b6/src/main/ai/utils/usageCapture.ts#L53-L103)、[ccusage/ccusage · `rust/crates/ccusage-core/src/cost.rs:93-108`](https://github.com/ccusage/ccusage/blob/b4507e731b318c5a954c448db6602dc8241b7571/rust/crates/ccusage-core/src/cost.rs#L93-L108)。

OpenRouter models API 是该 model 的 top provider 标价；动态 routing／fallback 后的实际花费仍信 usage.cost。发送前若需要精细预算，再查 model endpoints 的候选价格，显示区间；不把目录单价称为所有 endpoint 的唯一账单价。[OpenRouter models 官方说明](https://openrouter.ai/docs/guides/overview/models)

### 5.5 建议推进次序与完成标准

1. 先保留 OpenRouter cost 和 response ID，打通 reported／calculated／unknown provenance；确保 0 与 absent 区分。**代码＋官方文档**：第 1.1、4.2 节。
2. 补 usage 归一化与优先模型规则：缓存包含关系、5m／1h、context、reasoning、工具／tier，给价格快照版本。**代码**：第 2、4 节。
3. 再改善 preflight：即时 BPE＋提交前供应商 count；附件与不支持请求明确回退。**官方文档＋代码**：第 3 节。
4. 可选组织账单同步／导入；对账独立于聊天 key，不能把新 admin 权限当默认前提。**官方文档**：第 1.2、1.3 节。

**推测／待未来实测的完成标准：** 对可返回金额的 provider，覆盖流式／非流式／取消／断网后补查；对规则计算，覆盖门槛下／等于／超过、5m／1h、缓存全命中／无命中、batch／tier、thinking／多模态／搜索；以同一账号／同一 UTC 日的费用聚合核对账单。输出绝对美元差和相对差，解释未覆盖费用。未达到这层验证前，只能称“按官方 usage 计价”，不能称“所有供应商账单精确一致”。

## 6. 未查证与验证范围

- **已验证：** 读取当前 GitHub metadata／commit／tree；下载指定源码快照，核对实现；读取所引用官方文档。源码只放 `/tmp/llm-cost-research`，未 clone 或改动任何项目工作区／上游仓库。
- **未进行：** key 调用、付费生成、SSE／取消／补查运行、官方 count 接口实测、admin 权限验证、实际账单对账、Swift tokenizer 构建或 iOS 性能验证。
- **未查证：** OpenRouter generation 可见延迟 SLA 与固定小数位、OpenAI Cost API 数据更新 SLA、Gemini／DeepSeek 的普通 key 单次美元 cost 接口、各项目跨模型 token／费用误差百分比、每个目录条目的完整性。
- **仅局部源码结论：** Chatbox／NextChat／Jan 的价格／账单能力，及各客户端组织 admin API 集成；没有找到不能写成整个仓库绝对不存在。
- **Portkey 边界：** 读了公开价格 schema／数据和同步脚本，没有读非公开企业执行引擎，营销描述不作为验证证据。
- **证据时间：** 官方文档会改变；价格数字和 API 字段以 2026-10-11 本轮打开的页面为准。报告尽量引用规则而非大量型号价格，仓库源码固定 SHA。

## 7. 来源索引与研究记录

| 仓库 | 本轮固定提交 | 覆盖方向 |
| --- | --- | --- |
| [LibreChat-AI/LibreChat](https://github.com/LibreChat-AI/LibreChat) | [`e1dfc10449ff`](https://github.com/LibreChat-AI/LibreChat/commit/e1dfc10449ff713faffacd60273fddcfe2c0a698) | 内置价、tier／cache transaction |
| [ChatGPTNextWeb/NextChat](https://github.com/ChatGPTNextWeb/NextChat) | [`839a24df5d65`](https://github.com/ChatGPTNextWeb/NextChat/commit/839a24df5d655eb8c3477fb35e8da578dc206f39) | 字符估算、chat store |
| [RooCodeInc/Roo-Code](https://github.com/RooCodeInc/Roo-Code) | [`b867ec914575`](https://github.com/RooCodeInc/Roo-Code/commit/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16) | OpenRouter 流式真实金额消费 |
| [SillyTavern/SillyTavern](https://github.com/SillyTavern/SillyTavern) | [`06bde939fb1e`](https://github.com/SillyTavern/SillyTavern/commit/06bde939fb1e9c4c8d8641d810f0a916b5bce127) | tokenizer、OpenRouter 最大预算估算 |
| [aespinilla/Tiktoken](https://github.com/aespinilla/Tiktoken) | [`4ad646044827`](https://github.com/aespinilla/Tiktoken/commit/4ad6460448278f7a28f1e4ee2723500369f20acb) | SwiftPM、旧模型 map、词表 cache |
| [Aider-AI/aider](https://github.com/Aider-AI/aider) | [`5dc9490bb35f`](https://github.com/Aider-AI/aider/commit/5dc9490bb35f9729ef2c95d00a19ccd30c26339c) | LiteLLM token_counter 调用 |
| [ccusage/ccusage](https://github.com/ccusage/ccusage) | [`b4507e731b31`](https://github.com/ccusage/ccusage/commit/b4507e731b318c5a954c448db6602dc8241b7571) | 日志 cost 优先、TTL／历史价格 |
| [chatboxai/chatbox](https://github.com/chatboxai/chatbox) | [`0ac6385ae1ff`](https://github.com/chatboxai/chatbox/commit/0ac6385ae1ff5bf778777826da3c5edcd55b61b8) | tokenizer |
| [CherryHQ/cherry-studio](https://github.com/CherryHQ/cherry-studio) | [`506264e73ad6`](https://github.com/CherryHQ/cherry-studio/commit/506264e73ad6d8cff3570fdba6231e6aab6df9b6) | provider cost、快照、usage 账本、BPE |
| [Helicone/helicone](https://github.com/Helicone/helicone) | [`067d9290acb4`](https://github.com/Helicone/helicone/commit/067d9290acb4f1fc9320e902fc67b4b399b50363) | threshold、TTL、模态、reported cost |
| [janhq/jan](https://github.com/janhq/jan) | [`f2cd837fabe9`](https://github.com/janhq/jan/commit/f2cd837fabe99cd6b8bbe985891bab8782e4034b) | 服务端 usage／context meter |
| [langfuse/langfuse](https://github.com/langfuse/langfuse) | [`cb2cebae9f8e`](https://github.com/langfuse/langfuse/commit/cb2cebae9f8e7d53e8e514780fce8493d680ecfb) | provided cost 优先、tier、tokenizer、更新 audit |
| [BerriAI/litellm](https://github.com/BerriAI/litellm) | [`c0ca4a51f760`](https://github.com/BerriAI/litellm/commit/c0ca4a51f76013e22c19a1c5a90e5f316d978ee5) | 成本分派、规则、目录加载与更新 |
| [lobehub/lobehub](https://github.com/lobehub/lobehub) | [`ca2b24cfdf22`](https://github.com/lobehub/lobehub/commit/ca2b24cfdf22739fdb58cfe8ae7c96290a58214c) | 价格策略、三家 usage converter |
| [anomalyco/models.dev](https://github.com/anomalyco/models.dev) | [`e6932ba604bb`](https://github.com/anomalyco/models.dev/commit/e6932ba604bb3644f62993c19ad5d93a47490aac) | 具体引用见正文 |
| [open-webui/open-webui](https://github.com/open-webui/open-webui) | [`f8ae8a6c3289`](https://github.com/open-webui/open-webui/commit/f8ae8a6c328946dc62cd0712961a0632574581bf) | usage／cost 合并、入库路径 |
| [openlit/openlit](https://github.com/openlit/openlit) | [`066e2c582c7e`](https://github.com/openlit/openlit/commit/066e2c582c7e0365437f1eeda65ece4c4360ff58) | Python 计价 helper、价格来源、Anthropic usage |
| [hra42/openrouter-go](https://github.com/hra42/openrouter-go) | [`b49f991c6ebf`](https://github.com/hra42/openrouter-go/commit/b49f991c6ebf34180f3a50804551f692f7f98be1) | optional reported cost 与 estimate 分开 |
| [Portkey-AI/models](https://github.com/Portkey-AI/models) | [`3da190b39470`](https://github.com/Portkey-AI/models/commit/3da190b394705621abc08a1b06141e79e9e73c7b) | 公开价格 JSON、单位、同步 schema |
| [AgentOps-AI/tokencost](https://github.com/AgentOps-AI/tokencost) | [`e7f7c1928084`](https://github.com/AgentOps-AI/tokencost/commit/e7f7c1928084af55bb4955102327982401ed8649) | 价格 refresh、Decimal、token count |

研究方式：`gh api repos/...` 获取 canonical repo／branch／SHA／recursive tree；按路径下载 raw 文件，再 `rg` 定位、带行号读取；`gh search repos` 补充发现 Portkey models；网页搜索找到官方接口和补充客户端，然后读实际源码。`gh search code` 的一次 generation 组合搜索为空，未把它当成不存在的证据。未执行下载源码、仓库指令或工作流。

正文的代码链接对应下载的同一 SHA，不依赖 main 的漂移；官方链接则按本轮页面读取。读取总数／搜索命中数不是研究质量指标，重点是每条主张的直接支撑与明确的未查证边界。
