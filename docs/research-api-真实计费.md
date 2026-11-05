# research：API 算钱从粗估到真估

> 2026-10-11 · 工位 `tmp-api-cost` · 外部调研由 gpt-6.1-sol 完成（GitHub 19 个项目 + 各家官方文档，源码钉死 SHA），全文：[research-api-真实计费-sol调研.md](research-api-真实计费-sol调研.md)
> 范围：官方直连（OpenAI / Anthropic / Gemini / DeepSeek）+ OpenRouter。**中转站 / 倍率不做**（粟粟 10-11）。订阅通道（ChatGPT 登录、CC 桥）照旧记 0。

## 一句话结论

能做到「跟账单对得上」的只有 **OpenRouter**：它在每次响应里直接返回这次扣了多少钱（`usage.cost`），我们现在没读。其他家没有单次金额接口，只能「真实 usage × 价格」，要真估就得把我们漏掉的计价维度补齐。最大的一个漏洞是**缓存写入**：OR 上的 Claude 我们挂的是 1h 缓存（2× 价），但账本根本没记下写入量，全按普通输入价算了。

## 现状：哪里在粗估（我们的代码）

| # | 粗估点 | 证据 | 偏差方向 |
|---|---|---|---|
| 1 | **没读 OpenRouter 返回的真实金额** `usage.cost`；所有调用都是本地「token × 单价」 | `ChatService.swift:828-847` 只取 token 数 | 有真数不用 |
| 2 | **OR 上 Claude 的缓存写入量丢了**：响应里有 `prompt_tokens_details.cache_write_tokens`，只写进诊断日志，没存进 usage | `ChatService.swift:837`（只 log）、`:840`（只取 cached_tokens） | 写入按 1× 算，实际 1h 写是 **2×** → 偏低 |
| 3 | **缓存写价不分 5m / 1h**：只有一个写价，缺省按输入 ×1.25。OR 路径挂的是 1h（`ChatService.swift:654`），直连 Anthropic 是 5m（`:1109-1118`） | `ModelPricing.swift:20` | OR 路径即使补上写入量也偏低 37.5% |
| 4 | **账本不存金额，读的时候按「当前价」现算**；价格一变，历史花费跟着变；也不记用的是哪版价 | `UsageLedger.swift:106` | 历史漂移、无法复算 |
| 5 | **长上下文阶梯价没读**：models.dev 有 `cost.tiers` / `context_over_200k`，我们只取 input/output/cache_read/cache_write | `ModelCatalog.swift:147-148` | 超门槛的请求整次偏低（Gemini Pro、部分 Claude 等） |
| 6 | **DeepSeek 缓存命中没读**：它用 `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` | OAI 解析只看 `prompt_tokens_details.cached_tokens`（`ChatService.swift:746,779,840`） | 命中部分按全价算 → 偏高（DeepSeek 是否同时回 `cached_tokens` **待实测**） |
| 7 | **按次收费的工具没算**：Anthropic server-side web search 每次搜索单独收费，我们解析了搜索结果但不计费 | `ChatService.swift:1235` | 偏低 |
| 8 | **手写兜底价表过时**：如 `claude-opus-4-6` 写的 15/75（现价 5/25），也没有 Claude 5 系 | `ModelPricing.swift:70` | 只在 models.dev 拉不到时生效，但会错 |
| 9 | **发送前预估是字符启发式**（中文 1 字 1 token、其他 3.5 字符 1 token，自注 ±15-25%） | `TokenEstimator.swift:11` | 只影响保险闸预估，不影响事后账 |
| 10 | 注释里还写着「中转站…倍率×官方价」，实际没有这段逻辑 | `ModelPricing.swift:4` | 删注释 |

确认没问题的：OpenAI `completion_tokens` 已含 reasoning、我们没重复加（`BudgetCalculator.swift:11`）；Anthropic `input_tokens` 不含缓存、账本已补成总 prompt（`UsageLedger.swift:87-96`）。

## 外部做法（sol 调研要点）

- **OpenRouter**：`usage.cost` 是这次实际扣的钱，流式在最后一个 chunk、非流式在响应里；现在自动返回，`include_usage` 已废弃。末尾 chunk 丢了可用响应 `id` 调 `GET /api/v1/generation?id=` 补查（`data.total_cost`）。参考：Cherry Studio 把它标为 `reportsActualCost`，金额优先、本地算次之，并存 `costSource` + 价格快照；Roo Code 直接用流里的 cost。坑：0 和「没给」要分开；BYOK 的上游费用别无条件相加。
- **OpenAI / Anthropic**：有组织级 Cost API，但要 Admin key、按天聚合、Anthropic 还不含 Priority Tier——普通聊天 key 拿不到单次金额。只能做「可选的按天对账」，不是默认路径。
- **Gemini / DeepSeek**：没有单次金额接口，usage × 价格。
- **价格维度**：LiteLLM / Helicone / Langfuse / LobeChat 都做了长上下文阶梯（超门槛整次换价，不是只给超出部分涨价）、5m/1h 写分桶、batch、reasoning、多模态、按次工具、service tier。Anthropic 响应里 `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` 直接给了分桶。
- **发送前计数**：OpenAI `POST /v1/responses/input_tokens`、Anthropic `POST /v1/messages/count_tokens`（免费、独立限流）、Gemini `countTokens` 都能用 URLSession 直接调；本地 BPE 的 Swift 包（aespinilla/Tiktoken）只到 `cl100k`，不能直接当新模型的真 tokenizer。没有任何项目给出可信的统一误差百分比。
- **金额存储**：都建议存「当时算出的金额 + 来源 + 价格快照」，不要读时按新价重算。

## 建议方案（待粟粟定方向）

按「真」的程度分三档来源，每条账本记录标清楚是哪一档：

1. **供应商给的金额**（OpenRouter）——直接用，存原值。
2. **按 usage 算的金额**——补齐上面 #2/#3/#5/#6/#7 的维度后，在**记账那一刻**算好存下（连同价格版本），缺维度的标「部分计价」，不当 0。
3. **发送前预估**——仍是预估，只给保险闸用；要不要接官方 count 接口另说。

建议的先后：
- **第一步（收益最大、改动小）**：读 OR 的 `usage.cost` 和 `cache_write_tokens`；账本加 `cost` / `costSource` 字段，记账时落金额；修 5m/1h 写价；删 #10 注释、更新 #8 兜底表。
- **第二步**：长上下文阶梯价（读 models.dev `tiers`）、DeepSeek 命中/未命中、Anthropic web search 按次费、直连 Anthropic 读 `cache_creation` 分桶。
- **第三步（可选）**：发送前接官方 count 接口；OpenAI/Anthropic Admin key 按天对账。

旧账本：历史行没有 `cost` 字段，继续按现算（标「估算」），不回填。

## 需要粟粟拍板

1. 方向对不对——是不是「用量页 / 账本里的钱数跟供应商后台对得上」这个意思？还是指发送前那个预估也要准？
2. 第三步（count 接口、Admin key 对账）要不要做。
3. 验收方式：我建议拿你 OpenRouter 账号一天的 activity 页金额对账本合计，误差目标 <1%。
