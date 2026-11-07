# plan · 中转站兼容（实测驱动的修补）

⚠️ DON'T IMPLEMENT YET

> 2026-10-16 · 工位 backend-3（基于 master 7182a6cb0，模型兼容 P0 已合）。
> 证据：3 家 new-api 中转实测（msuicode / treegpt / ekanw，key 在 `~/.mp-test-keys/relays.json`，不入库），报告与原始字节在 `~/MemoryPalace-docs-media/relay-probe/2026-10-16/REPORT.md`。
> 前置：[plan-model-compat-p0](plan-model-compat-p0.md)、[review-model-compat-p0](review-model-compat-p0.md)。

## 0. 结论

中转的流本身很规整（`\n`、`data: `、有 `[DONE]`），P0 的解析层都接得住。出问题的是**报错和用量**：new-api 有自己的错误码、会给报错文字打码、按 max_tokens 预扣额度，P0 的分类器会把其中几种判错，导致白重试或给错提示。另有几处用量 / 思考的小偏差。全部是规则级修补，不动结构。

## 1. 修补清单

| # | 现象（实测） | 现在会怎样 | 改法 | 样本 |
|---|---|---|---|---|
| R1 | 503 `model_not_found`、500 `get_channel_failed`、文字「No available channel」= 分组里没这个模型 / 渠道全挂 | 被当 transient 白重试 2 次，最后说「服务器忙」 | 新 kind `.unavailableModel`：不重试；人话「这个中转的当前分组里没有可用的『{模型}』渠道，换个模型或去中转后台看分组」；「去改」跳卡的模型列表 | ekanw/err_nonexistent_model.json、msuicode/stream_claude-sonnet-4-6.sse |
| R2 | ekanw 按 max_tokens **预扣**：上限给大了回 403 `insufficient_user_quota`「余额不足」 | 判成欠费，提示充值换卡 | 403/402 + `insufficient_user_quota` 且这次发的输出上限 > 8192：走现有降上限重发一次（不学），重发仍失败才按欠费说；人话补一句「有的中转按最大输出预扣额度」 | ekanw/err_huge_max_tokens.json |
| R3 | new-api 给报错文字打码：`thinking.type.enabled` → `***.***.enabled` | `rejectsAdaptiveType`、`messages.N.reasoning_*` 等点路径规则认不出，自学失效 | 分类器取证文本先做「去打码」宽松匹配：`(\*{3}\.)+name` 视为任意前缀路径；点路径规则改成后缀匹配；补打码样本单测 | msuicode/anth_thinking_claude-opus-5-5.sse |
| R4 | 「max_tokens must be greater than thinking.budget_tokens」 | 被 `mentionsLimitTooLarge` 当成上限太大去降——方向反了，越降越错 | 文字里出现 `budget_tokens` 时不走 lowerOutputCap；改为本次把思考预算压到 `max_tokens - 1024` 以下重发一次（或关思考，见 Q2）；嵌套在 message 里的上游 JSON 被截断时也要能认 | ekanw/stream_claude-opus-4-6-thinking-单间.sse |
| R5 | 403「无权访问 xx 分组」 | 归到 badKey「key 不对」 | 新识别：文字含「分组」「group」+ 无权 / not allowed → 人话「这把 key 的分组不能用这个模型」，不跳改 key | treegpt/ns_kimi-k3.json |
| R6 | Gemini 经中转：顶层 reasoning_tokens=0，total > prompt + completion | 思考 token 漏算，花费偏低 | usage 规范化：reasoning 缺失或为 0 且 total − prompt − completion > 0 时，差值记为思考 token（并入输出计费）；只在 OpenAI 兼容路 | ekanw/stream_gemini-3.8-flash-high.sse、ns_gemini…json |
| R7 | msuicode 的 reasoning_content 是纯空白 | 产生空思考段，并占住「原生思考」位 | trim 后为空的思考片不算收到、不记 field | msuicode/tool_claude-opus-5-5_T0.sse |
| R8 | 工具参数被中转注入未声明的顶层键（`_call`、`reason`） | 原样传给我们自己的工具执行器，个别工具可能因多余参数报错 | 执行前按该工具 schema 过滤未声明的顶层键（schema 没有 `properties` 或 `additionalProperties: true` 时不过滤）；回放历史时保留原样（不改签名相关内容） | ekanw/tool_claude-thinking_T0.sse、msuicode/tool_claude-opus-5-5_T0.sse |
| R9 | 学习表 / 计价用的模型 id：中转响应里的 model 和请求的不一样（`按量K-claude-opus-4-6` → `claude-opus-4-6` / `K-…-7`） | 需确认现在按哪个记 | 核对：参数自适配学习键、账本、价格查找一律用**请求的** model id；若有地方读响应 model 就改掉 | ekanw 各 .sse |
| R10 | Anthropic 格式 message_start 的 input_tokens=1 是占位，真值只在 message_delta | 若先到的值被当最终值会算错 | 核对 usage 合并：message_delta 的非零值覆盖 start 的值（P0 已有「非零覆盖」的话就只补样本测试） | ekanw/anth_xapikey_claude-opus-4-6-K.sse |

**不做**：msuicode 疑似响应缓存（重新生成逐字相同）→ 只记进复盘，不做提示（误报风险大）；中转注入的系统提示（几千到几万 token，走缓存读）→ 我们管不了，复盘记一笔；假流式 → 不处理。

## 2. 测试样本

把上表样本拷进 `MemoryPalaceTests/Fixtures/relay/`：**脱敏**（key 已替换；request id 改固定值；去掉 Set-Cookie / Cf-Ray 等头；中转域名保留——它们不是隐私）。每条修补至少一个用原始字节的测试，P0 里「资料还原」的样本能被真样本替换的顺手替换。

## 3. 补测

- DeepSeek 经中转的续轮 400 仍没测到（三家都没 DeepSeek 渠道）。可以换一把 msuicode「国模通用」分组的 key 补测（有 deepseek-v4-pro）——**需要粟粟去要一把**（Q3）。

## 4. 待粟粟批注

**Q1 范围**：R1–R10 一次做完（推荐，都是小规则，一个阶段一次审）？还是只做 R1–R5（报错类）先合？

<⧫>  </⧫>

**Q2 R4 的处理**：推荐「把思考预算压到 max_tokens − 1024 以下重发一次」；另一个选择是「这次关思考重发」。

<⧫>  </⧫>

**Q3 补测 DeepSeek**：要不要去要一把带 DeepSeek 渠道的中转 key？

<⧫>  </⧫>

**Q4 样本进仓库**：脱敏后的中转原始响应（含中转域名、模型 id、回答内容「1+1=2」这类）进 `MemoryPalaceTests/Fixtures/relay/`，可以吗？推荐可以（不含 key / cookie / 个人信息）。

<⧫>  </⧫>

## 5. Todo

- [x] 样本脱敏拷入 Fixtures/relay（Q4）
- [x] R1 `.unavailableModel` 分类 + 人话 + 跳转 + 测试
- [x] R2 预扣型余额不足 → 降上限重发一次 + 测试
- [x] R3 去打码宽松匹配 + 点路径后缀匹配 + 测试
- [x] R4 budget_tokens 报错不降上限、压预算重发 + 截断嵌套 JSON 取证 + 测试
- [x] R5 分组无权识别 + 人话 + 测试
- [x] R6 total 差值记思考 token + 测试
- [x] R7 空白思考不算 + 测试
- [x] R8 工具参数按 schema 过滤 + 测试
- [x] R9 学习 / 账本 / 价格用请求 model id（核对 + 补测试）
- [x] R10 Anthropic 占位 usage（核对 + 补测试）
- [x] 回归（P0 全部套件 + BudgetGate）+ iOS build-for-testing
- [ ] astra 审一轮 + 裁决 + 修
- [ ] 复盘 review-relay-compat.md + now/backend-3 + 说明书事实
- [ ] 交合并
