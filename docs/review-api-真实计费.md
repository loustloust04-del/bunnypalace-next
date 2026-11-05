# review：API 算钱从粗估到真估

> 2026-10-11 · 工位 `tmp-api-cost` · [plan](plan-api-真实计费.md) / [research](research-api-真实计费.md)
> 实现 gpt-6.1-sol（A1–F3 24 项 + 自查 9 个修正）→ gpt-6-astra 审一轮（5 P0 / 5 P1 / 3 待核，车头逐条裁，F1–F10 全修）→ 车头跑定向测试抓出 5 个回归 → 两轮修到全绿。
> 验证：11 个测试类定向 passed（APICost / BillingReconciliation / BudgetGate / ModelCatalog / ReviewCostFix / UsageLedger / OutputTokenCap / ProviderOrdering / PromptRealPathGolden / CardSlashRequestBody / PersonaRequestBody）；只有 macOS 测试编译，iOS 等集成区。**没有真实账单对账证据**。

## 1. 边界情况（没处理 / 只做了一半）

- **OR 补查不跨进程**：断流后的 generation 补查是进程内任务，app 退出就丢；那一笔留着本地算的金额（标 partial）。
- **OR `/key` 只给当天 / 本周 / 本月**：对账区 OR 只能对「今天」，前 6 天显示「未提供」，不摊算。
- **直连 Admin key 的组织范围核不了**：Admin key 和聊天 key 是否同一组织无法验证 → 只展示金额、不判差额不标红。
- **DeepSeek 峰时 / 节假日价**没建模：当前型号只算基础价并标 partial。
- **价格缓存文件格式没动**（守禁区）：新维度（1h 写、阶梯、搜索价）只驻内存，冷启动刷新失败 → 新记录 partial。
- **缺价 / 缺 usage 的预算**按保守价扣（`budgetFallback`），拿到 OR 实价后补差额；没做通用「预留 → 结算」系统。
- **Q1 待实测**：Gemini OAI 兼容口 `completion_tokens` 是否已含 thoughts——只有响应里明确分桶时才相加。
- **Q3 未做**：供应商按请求开始还是结束归日没核；本地按结束时间归日，跨午夜的单笔可能落到相邻日。
- **待实测（要粟粟的 key）**：OR 金额（含 0）/ 断流补查 / 一天对账 < 1%；DeepSeek 命中字段；两家 count 接口；Admin key 存取与 Cost API。

## 2. 与下一模块交互的风险

- **`usage.jsonl` 新增字段**：新版读旧行缺省 nil（标「估算」）；旧版读新行忽略未知字段。更正行 token 全 0、只带金额 → 退回旧版最多多算调用次数、不多算钱（测试钉住）。
- **`TokenUsage` 多了一堆字段**（`ledgerCostUSD` / `ledgerSpendRecorded` / `ledgerRecord` / `completeness` …）：任何新调用方要扣预算，必须走 Router 记账、看 `ledgerSpendRecorded`，自己再 `commitSpend` 会双扣。
- **请求代际**：`ChatService` 的 delegate / 排队回调现在全部核对请求代际，provider 在预检期间强持有——以后改流式 / 取消逻辑要保住这两条（`BudgetGateTests` 两个回归就是这里坏的）。
- **保险闸语义变了**：临界（±25%）才调官方计数，但**最终门控永远在发送前按当时余额跑**；不需要计数的端点同步放行。
- **消息 footer** = 该节点所有调用（工具轮 + 最终轮）按 rid / requestId 去重求和；任一轮金额未知 → footer 显示未知，不拿部分和冒充。

## 3. 技术债务

- 预算预留系统（通用的「先占后结」）只做了简化版。
- OR 补查队列没持久化。
- 价格目录缓存只存 4 个字段，新维度靠每次启动刷新。
- `BudgetGateTests` 回归 2 原始的 8 秒超时本轮未复现，修的是发送时序回退，完整延迟来源未查明。
- 说明书 `manual/facts` 用量页**未同步**（等真实对账后再写，避免写进没验证的承诺）。
- 现有那张 Anthropic / OR 卡上的对账要粟粟手动填 Admin key 才能用。
