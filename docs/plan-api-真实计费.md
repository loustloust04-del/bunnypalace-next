# plan：API 算钱从粗估到真估

> ⚠️ DON'T IMPLEMENT YET —— 等粟粟批注 / 说 go
> research：[research-api-真实计费.md](research-api-真实计费.md)（粗估点 #1–#10 编号沿用）· 工位 `tmp-api-cost`
> 目标（粟粟 10-11）：用量页 / 账本 / 消息 footer 的钱数**跟供应商后台对得上**；三步都做。中转站 / 倍率不做。

## 验收标准

- **OpenRouter**：任选一天，账本当天合计 vs OpenRouter 后台当天用量，差额 < 1%。
- **Anthropic / OpenAI 直连**：有 Admin key 时，按天对账差额 < 1%（Anthropic Priority Tier 不在它的 Cost API 里，不计）。
- **其他（DeepSeek / Gemini 等）**：没有账单接口可对，验收 = 单测覆盖每个计价维度 + 拿一次真实响应手算对上。
- 历史旧账本不回填，照旧现算，界面标「估算」。

## 设计

### A. 账本记录在记账那一刻落金额（#4）

`UsageRecord` 新增字段（短 key，旧行解码缺省 nil，不坏）：

| 字段 | key | 含义 |
|---|---|---|
| `costUSD: Double?` | `cost` | 这次调用的钱 |
| `costSource: CostSource?` | `cs` | `reported`（供应商给的）/ `calculated`（usage×价，维度齐）/ `partial`（有维度缺价，金额只含已知部分）|
| `priceVersion: String?` | `pv` | 用的价格版本（models.dev 拉取日期 或 `builtin-2026-10`）|
| `cacheWrite1h: Int` | `cw1h` | 1h 缓存写入量（`cacheWrite` 仍是总写入量，含 1h 部分）|
| `webSearches: Int` | `ws` | 按次计费的搜索次数 |
| `responseId: String?` | `rid` | OpenRouter generation id（补查用）|

- `cost(price:)` 改成：有 `costUSD` 直接返回；没有（旧行）才现算，`costSource` 视为 `estimated`（不落盘，只在读时）。
- 用量页：合计照旧，「未计价」旁边再加「部分计价 N 次」「估算（旧记录）N 次」两个小字（只在 >0 时出现）。
- `MessageNode.usageCostUSD`（消息 footer）同步改成用同一个金额，不再自己另算（`ConversationViewModel.swift:5125`）。
- 金额用 `Double`：单次几美分，Double 相对误差 1e-15，用不着 sol 建议的 `Decimal`。

### B. 读 OpenRouter 的真实金额（#1 #2）

- 流式 / 非流式解析 `usage.cost` → `TokenUsage.reportedCostUSD`；`prompt_tokens_details.cache_write_tokens` → `cacheWriteTokens`（现在只进诊断日志）；顶层 `id` → `responseId`。
- 判定「供应商给了金额」看**字段在不在**，0 也算真 0（Helicone 那个 truthiness 坑不踩）。
- 只认 openrouter.ai 的 base URL 才信 `usage.cost`（别的 OAI 兼容口万一也回个 cost 字段，语义不明，不信）。
- 末尾 usage chunk 丢了（断流 / 取消）：有 `responseId` 就后台延迟补查 `GET /api/v1/generation?id=`（10s / 30s / 2min 三次退避），拿到 `total_cost` 后往账本**追加一条更正行**（同 `rid`、`kind` 不变、标 `correction`），汇总时同 `rid` 取最后一条。补查失败就留着本地算的。
- `stream_options.include_usage` 对 OR 已废弃但无害，不动（别的 OAI 口还要它）。

### C. 补计价维度（#3 #5 #6 #7）

`ModelPricing` 加：
- `cacheWrite1hUSDPerMTok`（缺省 = 输入 ×2，Anthropic 官方口径）；现有 `cacheWrite` 视为 5m。
- `tiers: [(aboveInputTokens: Int, pricing)]`：总 prompt **超过**门槛则整次换价（输入 / 输出 / 缓存一起换，LiteLLM / Helicone 同口径）。
- `webSearchUSDPerCall`（Anthropic $10 / 1000 次；目录没有就按厂商写死，缺价 → `partial`）。

解析侧：
- `ModelCatalog` 读 models.dev 的 `cost.context_over_200k` 和 `cost.tiers`（实现前先拉一份 live `api.json` 核实字段形状，写进测试 fixture）。
- 直连 Anthropic：读 `usage.cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`、`usage.server_tool_use.web_search_requests`。
- DeepSeek：读 `prompt_cache_hit_tokens`（有 `cached_tokens` 时以哪个为准，实测一次定）。
- Gemini（走 OAI 兼容口）：实测一次 `completion_tokens` 含不含 thoughts，不含就把 reasoning 加回 output。
- 「缺维度」的判定：响应里出现了某类计量（1h 写、搜索次数、超门槛）但价格表里没有对应价 → `partial`，**不拿倍率猜**。缓存读 / 5m 写缺价仍按 0.1× / 1.25× 兜底（这两个各家一致，算 `calculated`）。

### D. 价格表清理（#8 #10）

- 删 `ModelPricing.swift:4` 中转倍率注释。
- 手写兜底表更新到 2026-10 官方价（补 Claude 5 系 / Haiku 4.5 / GPT 当前型号，改掉 Opus 4.x 的 15/75），并标 `priceVersion = builtin-2026-10`。

### E. 发送前预估（第三步 · #9）

- 只给保险闸用，不影响事后账。
- 保险闸开着、且启发式估算落在限额 ±25% 以内（临界）时，才调官方计数接口，免得每次发消息多一个请求：
  - 直连 Anthropic：`POST /v1/messages/count_tokens`（免费）
  - 直连 OpenAI：`POST /v1/responses/input_tokens`
  - 其他：照旧启发式
- 计数接口超时 2s 或失败 → 回落启发式，不挡发送。

### F. 按天对账（第三步）

设置 → 用量页底部加「对账」区：
- **OpenRouter**：用现有 key 调 `GET /api/v1/key`（`usage_daily` 等字段，实现前核实）。
- **Anthropic / OpenAI**：粟粟另填 **Admin key**（存钥匙串，和聊天 key 分开）→ Anthropic `cost_report`（美分，÷100）/ OpenAI `/v1/organization/costs`（按天）。
- 显示最近 7 天：每天「账本 / 供应商 / 差额 %」，差额 >1% 标红。只读，不改账本。
- ⧫ 问：对账区进 Release 还是只进 Debug？（Admin key 对普通用户门槛高，我倾向 Release 但默认折叠）

## 影响范围

`Models/ModelPricing.swift` `ModelCatalog.swift` `UsageLedger.swift` `UsageSummary.swift` `GlobalBudgetStore.swift` · `Utils/BudgetCalculator.swift` `TokenEstimator.swift` · `Services/ChatService.swift`（OAI / Anthropic 解析 + 账本写入）· `ViewModels/ConversationViewModel.swift:5125` · `Views/UsageSettingsPage.swift` · 新文件：对账 service + 补查 service · 测试。
不碰：请求体 / 缓存挂标策略 / 流式逻辑本身 / SwiftData schema（`usageCostUSD` 已有字段，只改赋值来源）。

## 风险

- `usage.jsonl` 加字段：旧版 app 读新行会忽略未知 key（Codable 默认），新版读旧行缺省 nil —— 双向兼容，加一条测试钉住。
- 更正行：汇总要按 `rid` 去重，不然 OR 断流那次会被算两遍 → 测试覆盖。
- models.dev 字段形状不确定 → 先拉 live 数据再写解析。

## Todo

**A 账本**
- [x] ✅ A1 `UsageRecord` 加 6 个字段 + 编解码 + 旧行兼容测试
- [x] ✅ A2 `TokenUsage` 加 `reportedCostUSD` `cacheWrite1hTokens` `webSearches` `responseId`
- [x] ✅ A3 记账时算好金额落盘（`UsageRecord.init(provider:…)`），`cost(price:)` 优先读存值
- [x] ✅ A4 汇总按 `rid` 取最后一条（更正行）+ 测试
- [x] ✅ A5 消息 footer `usageCostUSD` 改用同一金额
- [x] ✅ A6 用量页加「部分计价」「估算（旧记录）」计数
- [x] ✅ A7 `GlobalBudgetStore` 预算已用改读存值

**B OpenRouter**
- [x] ✅ B1 流式 / 非流式解析 `usage.cost`、`cache_write_tokens`、`id`（仅 openrouter.ai）
- [x] ✅ B2 generation 补查 service（退避三次 + 追加更正行）
- [x] ✅ B3 测试：有 cost / cost=0 / 缺 cost / 补查成功 / 补查失败

**C 计价维度**
- [x] ✅ C1 拉 live models.dev `api.json`，确认 `context_over_200k` / `tiers` 形状，做 fixture
- [x] ✅ C2 `ModelPricing` 加 1h 写价、tiers、搜索单价；`cost()` 改成按桶算 + 返回是否 partial
- [x] ✅ C3 `ModelCatalog` 解析 tiers
- [x] ✅ C4 直连 Anthropic 解析 5m/1h 分桶、`web_search_requests`
- [x] ✅ C5 DeepSeek `prompt_cache_hit_tokens`（实测定口径）
- [x] ✅ C6 Gemini OAI 兼容口 thoughts 是否含在 output（实测定）
- [x] ✅ C7 单测：门槛下 / 等于 / 超过、5m / 1h、全命中 / 无命中、搜索、缺价 → partial

**D 清理**
- [x] ✅ D1 删中转倍率注释
- [x] ✅ D2 兜底价表更新到 2026-10 + `priceVersion`

**E 发送前**
- [x] ✅ E1 Anthropic count_tokens / OpenAI input_tokens 客户端（2s 超时回落）
- [x] ✅ E2 保险闸临界时才调用 + 测试

**F 对账**
- [x] ✅ F1 Admin key 钥匙串存取（Anthropic / OpenAI）
- [x] ✅ F2 三家日账单拉取（OR `/key`、Anthropic `cost_report`、OpenAI `costs`）——先核实 OR 字段
- [x] ✅ F3 用量页「对账」区 UI（7 天，差额 >1% 标红）

**收口**
- [x] ✅ 测试全绿（11 个类定向，逐类 grep 到 Test Suite passed，10-11 18:19）
- [x] ✅ 审实现一轮，逐条裁（实现是 sol → 改由 gpt-6-astra 审；F1–F10 全修，Q1/Q3 留待实测）
- [ ] 真实对账：粟粟 OR 账号跑一天 → 差额 < 1%
- [ ] 说明书 `manual/facts` 用量页同步（等真实对账后再写，见复盘）
- [x] ✅ `docs/now/tmp-api-cost.md` + review-api-真实计费.md
