# 复盘 · 模型兼容 P0（阶段 1–4）

> plan：[plan-model-compat-p0.md](plan-model-compat-p0.md)；research：[research-model-compat.html](research-model-compat.html)。工位 backend-3，分支 `zone/backend-3`，基线 `406f97e63`。
> 本文把 plan §10 说的「每阶段一份 review」合成一份。行号以 `MemoryPalace/` 为根、对应 HEAD `5bbc26649`。

## 0. 做了什么

| 阶段 | 实现提交 | 审查修复提交 | 一句话 |
|---|---|---|---|
| 1 · A SSE 解码器 | `b3ab3c9ac` | `30a64992e` | 三家共用按字节切行的 `SSELineDecoder`：认 CRLF / 单独 `\r`，中文跨分片不丢，`data:` 不带空格也认，流结束时把末行吐出来，错误正文按字节攒，单行超过 32 MB 就停 |
| 2 · E 骨架 | `27f3b1d4f` | `4518ab999` | `ResolvedCompat` + `KnownHost` 收拢 4 处 host 判断，每次请求只 resolve 一次；唯一的行为变化是 Q2（OpenRouter 只按 host 判） |
| 3 · B + C1 | `959b23703` | `90f081b84` | OpenAI 兼容路解析思考，放进「思考过程」；工具续轮按原字段名回传（DeepSeek / Kimi / OpenRouter 默认开）；报错里学会「要回传 / 不回传」 |
| 4 · D | `5a5d14742` | `5bbc26649` | `ChatErrorClassifier` + 还没出字时的有限重试 + 重试胶囊 + 人话 + 「去看 / 去改」 |
| 3b · C2 历史回传 | — | — | **没做**，等 Q4 实测（见 §2.1） |
| 0 · 实测 T1–T9 | — | — | **没做**，见 §3 |

验证（以提交说明为准，本文没有重跑）：每阶段都跑了 mac 定向回归 + BudgetGate 单跑，iOS `build-for-testing` SUCCEEDED，金样 G1–G8 没重录。没有真请求，也没装机。

---

## 1. 边界情况

### 1.1 输入异常

- **`<think>` 一直没闭合**：回复开头是 `<think>`、直到流结束都没等到 `</think>`，整段都算思考，正文为空（`ChatToolTypes.swift` `LeadingThinkTagSplitter.flush`）。阶段 3 审查修过之后，纯思考也会落库，界面只画思考行。**推断、没验证**：如果「思考过程」设成隐藏，这条回复在聊天页就是空的。
- **人设故意让回复以 `<think>` 开头**：Q3 对所有 OpenAI 兼容卡都开了拆分，这类回复的开头会被拆进思考，正则脚本 / `ContentCleaner` 看不到这段（以前在正文里）。正文中间出现的 `<think>` 不受影响。这是 Q3 接受的误伤面，还没有按卡关闭的开关。
- **OpenRouter `reasoning_details` 的形状**：合并规则是按文档 + 资料写的。同 index 合并；没有 index 时有 id 看 id，没有 id 的密文块不合并（审查 s3#1）。OR 只要改一种分片方式，回传就可能被拒（文档说顺序不能改）。T8 没测。
- **只有密文 `reasoning.encrypted`、没有文字**：不存思考段（界面上没有思考），但会照原样回传。这是设计如此。
- **SSE 多行 `data:` 拼接 / 空行派发**：刻意不做（plan §8）。哪家把一个 JSON 拆成多行 data 发，就会解析失败。
- **EOF 没有 `[DONE]`，但已经攒了工具调用**：仍然当普通完成处理，工具调用丢掉（属 P1 J）。阶段 1 只保证末行不丢。
- **单行 32 MB 上限**：按行长计算，和怎么切片无关（审查 s1#1）。超限走 `cancel()`，只发一次 onError。
- **报错分类只认词表**：自定义报错格式的中转（既不是 JSON，也不含词表里的词）会落到 `.other`：原文直接给她看，不重试。中文转义（`输…`）已经先解码再匹配（s4#6）。数字 `error.code` 只在 OpenRouter 上当成 HTTP 状态（s4#8），别家的业务码不会被误判成 5xx。
- **`Retry-After` 是 HTTP 日期**：要靠本机时钟算差值，时钟偏了等的时间也会偏。值超过 8 秒就不等，所以偏差影响的只是要不要重试、给她看的秒数。

### 1.2 并发

- **重试等待期间停止 / 发新消息**：用重试代际 `retryGeneration` 作废旧任务（`ChatService.swift:1891, 2292-2294`）。等待期间 `isStreaming` 算上 `pendingRetry`（`:1949`），停止按钮能停。`adaptiveFailed` 入口加了终态去重：流内 error 后又收到 `didCompleteWithError`，只处理一次（s4#1 阻断项，已修）。
- **流内 error 后又来 `[DONE]`**：已经加守卫，不再冲刷正文，也不再派发完成（s3#3）。
- **原生思考比 `<think>` 晚到**：原生优先。正文还没开始时，拆出来的原文整段还给正文；正文已经开始时，拆出来的思考作废，回传用原生字段名（s3#4）。
- **router 读 `lastReasoning`**：有序号守卫（照 `anthropicBlocksSerial` 的做法），换卡或提前失败时读到的是空。

### 1.3 失败重试

- **最坏请求次数**：首发 1 + 参数自愈 1 + 瞬态重试 2 = 4 次。两个计数互不重置。
- **连接断开**：只认状态 0 + `NSURLErrorNetworkConnectionLost`（-1005），重试 1 次（s4#2 撤回了 200 的放宽）。超时（-1001）、没网（-1009）都不重试，直接说人话。连接断开**照估算扣预算**，因为上游可能已经处理了这次请求。
- **扣不扣预算**：明确被拒的（408 / 429 / 5xx 带正文，或流内过载 / 限流 / 欠费）不管重不重试都扣 0（s4#3），连最后那一次也是 0。
- **已经出字后才失败**：不重试，保留已经出的正文，后面加「⚠️」。思考、工具调用也算出过字（Q11）。
- **「要回传」学会了，但这一轮没有可回传的思考**：不重发，说人话「这个接口要求把模型上一步的思考原样传回去，但这一轮没拿到…（可能被中转去掉了）」（`ChatService.swift:2488`）。注意：§2.1 那种「历史回合缺思考」的 400 也会落到这句话，而它写的原因「被中转去掉了」在那种情况下是错的。
- **不在重试范围内**：ChatGPT 登录通道、本机、CC，以及后台 `sendNonStreaming`（记忆写手 / 摘要 / 标题 / InnerVoice / Dream）。见 §3。

### 1.4 空状态

- `ReasoningCapture` 为空、中转把思考剥掉了：C1 不写字段（不编占位，Q5 未定）。DeepSeek 官方地址会因此 400，然后走上一条的人话。
- 纯思考、思考 + 报错、思考 + 已停止：都会落库（s3#2），没有正文时只画思考行。
- 自动适配表是空的：走 `ResolvedCompat` 的默认表（deepseek / moonshot / openrouter 开回传，其余关）。

---

## 2. 与下一模块交互的风险

### 2.1 3b · 历史回合回传（等 Q4 实测）——**DeepSeek 多轮带工具现在可能仍然 400**

- **文档说法**：DeepSeek 思考模式（默认开）下，请求**只要带 `tools`**，之前**所有**回合的 `reasoning_content` 都要回传，「even for turns where the model did not perform a tool call」；不回传就返回 400（plan §1.1）。
- **我们现在发什么**：C1 只回传**当轮**工具续轮的思考。历史回合的思考存在 `segments` 里，但没进 wire（`openAIWire` 不读，`ToolReplay.rounds` 不挂）。MP 几乎每条请求都带 tools（卡上 `toolsSupported` 默认开）。
- **会发生什么（按文档推断，未实测）**：同一个对话里，**从第二个用户回合起，第一次请求就可能 400**，不管上一轮有没有调过工具。第一轮正常，当轮的工具续轮也正常（C1）。
- **报错之后**：`ParamErrorClassifier` 认出「must be passed back」→ 学会 `reasoningReplayRequired`。但这一轮没有 toolTurns，所以不重发，她看到 §1.3 那句人话（原因写的是「被中转去掉了」，**这是误导**）。下一轮还是一样，这个对话带着工具基本没法继续聊。
- **影响范围**：DeepSeek 官方地址上走思考模式的模型（`deepseek-reasoner`，以及文档里默认思考的新 id）。老别名 `deepseek-chat` 走不走思考模式，要 T1 确认。Kimi K3 文档说多轮也必须带，同理。经 OpenRouter 用 DeepSeek，要不要带历史没有文档说明。
- **她现在能绕开的办法**：关掉那张卡的「工具」；或者换不带思考的模型（DeepSeek 文档：不带 tools 时历史思考会被忽略）。现在的「推理强度：关」**关不掉** DeepSeek 的思考，要等 P1 F。
- **下一步**：车头跑 Q4 实测（§3 最后一条的脚本）。T3 / T4 证实 400 → 按 plan §6 做 3b（`MessageSegment.thinking` 加 `source`、组装层挂思考、`openAIWire` 写历史，跨模型的写法看 T5 结果定）。不 400 → 3b 列进 P1，同时把 §1.3 那句人话改准。**在 3b 落地或证伪之前，不建议把套餐默认格式改回 OpenAI 兼容**（见 §2.3）。

### 2.2 P1 各项

| 项 | 和本单的接口 / 风险 |
|---|---|
| **F 关思考方言**（DeepSeek `thinking:{type:disabled}`、Kimi、Qwen、OR `reasoning.enabled:false`） | 现在 DeepSeek 思考默认开、我们关不掉，所以 §2.1 对所有 DeepSeek 思考模型都成立。F 落地后，「推理强度：关」才是 §2.1 的正经出口。开关应该放进 `ResolvedCompat`（`reasoningDisableMode`），**别在 builder 里另判 host** |
| **G MessageNode 记生成模型** | 3b 的「跨模型兜底」（Q5）需要知道历史那条是谁生成的。plan §6 选的是在段上加 `source`，不碰 MessageNode。如果 G 先做，3b 应该改读节点上的模型，别两套来源并存、各说各的 |
| **H 发送前统一整理消息序列** | 整理时不能合并 / 重排带 `reasoning_content` / `reasoning_details` 的 assistant 消息（OR 文档：顺序不能动），也不能把 tool_calls 那条的空 `content` 吃掉（`requiresAssistantContentForToolCalls` 默认关，Q12 未定）。H 要保证「预览 = 实发」，金样 G1–G8 是验收线 |
| **I 能力位消费 ModelHints** | 入口应该是 `ResolvedCompat.resolve`（每次请求只 resolve 一次，provider 和预览共用）。ModelHints 按「卡 id + 裸模型 id」查；Anthropic 格式的卡拉模型时打的是 OpenAI base，id 可能对不上；旁表为空要按「不知道」处理（master `docs/review-provider-presets.md` §2.4） |
| **J stop reason 补全** | `finish_reason: content_filter` / `refusal` / `pause_turn`、EOF 没有 `[DONE]` 但有工具调用：要和 `terminatedByError`、`hasEmittedOutput` 两个状态对齐。本单的 `.contentFiltered` 只认报错正文，J 来了别再写一套过滤人话，复用 `failureMessage` 的前缀 |
| E 正式版 | 剩下大约 10 个开关、卡上的用户覆盖、`APIUsageParser.isOpenRouter` 收拢。presets review §2.3 建议「先按预设区域、地址判断只作兜底」，这和现在纯按 `KnownHost` 判是两套依据，要一起设计 |

### 2.3 和已经合进 master 的「多家预设」线（`4b481eb54`）

- **套餐区域默认 Anthropic 格式**（`APIProviderTable.swift:24-28`，测试 `testPlanRegionsDefaultToAnthropic` 锁着）：当初的理由是「OpenAI 兼容路不解析思考、工具第二轮会 400」。B / C1 合进去以后，这个理由只解决了一半：**当轮**续轮好了，**历史回合（§2.1）还没好**。所以建议在 Q4 / 3b 有结论之前，默认值不动。
- **KnownHost 按地址判**：预设新增的地址大多落在 `.other`，C1 默认关，只能靠报错自学，而且要求中转把「must be passed back」原文透传出来。具体：
  - Kimi Code **国内** `api.kimi.com/coding` 算 `.moonshot`，C1 默认开（`ResolvedCompat.swift` `detect`，测试 `ResolvedCompatTests.swift:117,134` 锁着）。**master 上 presets review §2.5 最后一条说「C1 默认表不覆盖 Kimi Code」，国内这部分说得不对**；
  - Kimi Code **海外** `api.kimi.ai/coding` **不在表里**，C1 默认关；
  - 火山 / 硅基 / 百炼这些平台上的 DeepSeek，都是 `.other`。
- **合并冲突预警**：`manual/facts/model/model-api.md` 两条线都改了（presets 已经进了 master）。本分支合并时大概率要解冲突。`docs/plan-provider-presets.md` 在本分支，会随这次合并带进 master，presets review 第 4 行那句「plan 不在本分支」到时候就过期了。
- **ModelHints**：本单没读它，交给 I。

---

## 3. 技术债

- **报错样本全是资料还原的**：`MemoryPalaceTests/Fixtures/chat-errors/` 一共 17 份，每份都标了 `"source": "未实测…"`。分类器的词表和判定顺序都是照这些样本调的。T9 拿到原文后要逐份替换，再回归 `ChatErrorClassifierTests`。
- **Q4 实测没跑（阶段 0 整段没做）**：T1–T9 都没打。Q4 / Q5 / Q12 也就没定，3b、`requiresAssistantContentForToolCalls`、跨模型兜底都悬着。
  - 实测脚本：`/private/tmp/claude-501/-Users-susu-Desktop-susu-project------MemoryPalace/26708ffc-3fd7-4222-b706-7420e6ebce7b/scratchpad/reasoning_replay_probe.py`。
  - 用法：把 key 复制到剪贴板，再跑 `python3 -I <脚本> <base_url> <model>`。例如 `python3 -I reasoning_replay_probe.py https://api.deepseek.com/v1 deepseek-reasoner`。
  - 脚本覆盖 T1 / T2 / T3 / T3' / T4 / T4'，只输出状态码和截断到 400 字的原文；key 只从剪贴板读，不打印、不落盘。
  - **它放在 session 的临时目录里，可能被清掉**。要留就挪到 `~/MemoryPalace-docs-media/` 下（脚本不进 git，规矩见 `.claude/rules/docs.md`）。
- **小芽 AssistantEngine 的工具循环没接回传**：`Services/Assistant/AssistantEngine.swift:378` 还是 `ToolTurn(calls:results:)`，不带 `reasoning`。小芽用 DeepSeek / Kimi 思考模型调工具时，当轮续轮就可能 400（主聊天已经修了，小芽没修）。
- **ChatGPT 登录通道**：解码器换了，但错误分类 / 重试 / `usage_limit_reached.resets_at` 都不在本单。后台 `sendNonStreaming`（记忆写手、摘要、标题、InnerVoice、Dream）也不重试，失败照旧。
- **`Retry-After` 封顶 3600 秒的取舍**（`ChatErrorClassifier.swift:33`）：审查 s4#7 建议「非有限值置空」。实际做法是：inf / 超大值封顶到 1 小时，NaN / 负数置空。理由是服务器已经明说要等很久，如果置空就会按 2 秒 / 4 秒短退避去撞它。封顶后的值大于 8 秒，所以不重试，人话写「大约 3600 秒后再发」，这个数可能比真实值小。
- **说明书没走完**：`manual/facts/model/model-api.md` 加了 4 条事实（`959b23703` / `5a5d14742`）。之后两个审查修复提交改了行号和行为（比如文字型「不认 reasoning_content」也会学会不回传，facts 里只写了 422）。`npm run check` / `rewrite` / 截图 / `build` 都没做。合并时还要先解 §2.3 的冲突。
- **kimi 审没跑**：plan §10 要求每阶段 astra + kimi 各审一轮，四个阶段都只跑了 astra。
- **流式时不实时显示思考**（Q9，留 P1）：DeepSeek / Kimi 思考很长的时候，她要等很久才看到东西，只能看到「正在回复」。
- **预算估算**：`BudgetPreflight` 不算 `reasoning_details` 里的密文 `data`，会略微低估。思考全文存进 `segments`，不截断（DeepSeek / Kimi 可能上万字）。`TimelineConsolidator.momentLines` 会读到思考段（已知行为）。
- **Q2 的行为变化**：路径里含 `openrouter`、但 host 不是 openrouter.ai 的自建代理，不再挂 OR 缓存标，也不再走 deepseek 优先路由。阶段 2 审查后又收紧成「等于域名或以 `.域名` 结尾」，`xopenrouter.ai` 也不算了。测试已经锁住。
- **没读的限流头**：`x-ratelimit-reset-*`、`anthropic-ratelimit-*-reset`，只读了 `Retry-After`。
- **OAuth 通道的解码器改动**：只有单测，没真跑过订阅通道。

---

## 4. 审查裁决表（astra 四轮，全部收下）

| 轮 | # | 级别 | 问题 | 裁决 | 提交 |
|---|---|---|---|---|---|
| s1 | 1 | 应修 | 32 MB 上限受分片方式影响：超长行和 `\n` 同片到达能绕过；恰好 32 MB + 跨片 CRLF 被误拒 | 收：按行长计算，不计行尾 | `30a64992e` |
| s1 | 2 | 应修 | 超限取消没推进代际，已经排队的 token / 完成回调会在 onError 之后落地 | 收：超限走 `cancel()`，只发一次 onError | `30a64992e` |
| s1 | 3 | 应修 | 末行是流内 error 时，兜底结算会二次终止（error 被覆盖，或变成 onComplete） | 收：置 `terminatedByError`，兜底结算时复核 | `30a64992e` |
| s1 | 4 | 建议 | EOF 测试绕过了 `didCompleteWithError`，没断言回调次数 | 收：测试改走真实 delegate 入口，断言恰好一次 | `30a64992e` |
| s2 | 1 | 建议 | 检查器预览 body 和 placement note 各 resolve 一次 | 收：共用一次 | `4518ab999` |
| s2 | 2 | 建议 | 等价表没覆盖协议隔离 / 后缀边界（`xopenrouter.ai` 等） | 收，并另批收紧成「等于域名或 `.域名` 结尾」（行为变化，测试锁住）；补端口 / userinfo / Anthropic 卡 body 断言 | `4518ab999` |
| s3 | 1 | 应修 | 没 index 的不同密文块被合并成一块 | 收：有 id 按 id 分；缺 id 的密文不合并 | `90f081b84` |
| s3 | 2 | 应修 | 只有思考、没有正文（含报错 / 已停止）的回复不落库；`<think>` 路径属于回归 | 收：保存思考和正文气泡解耦，没正文只画思考行 | `90f081b84` |
| s3 | 3 | 应修 | 流内 error 之后的 `[DONE]` 又冲刷正文 | 收：共用终止守卫 | `90f081b84` |
| s3 | 4 | 应修 | 原生思考晚于 `<think>` 到达时混拼，字段名退回默认 | 收：原生优先，标签内容还给正文 / 作废，回传用原生字段名 | `90f081b84` |
| s3 | 5 | 应修 | 漏了 plan §5.2 的「文字型不认 reasoning_content」自学 | 收：只在回传过的前提下认，不误关推理强度 | `90f081b84` |
| s4 | 1 | 阻断 | 重复的错误回调留下取消不掉的重试任务 | 收：入口终态去重 + 重试代际 | `5bbc26649` |
| s4 | 2 | 阻断 | HTTP 200 之后断线也自动重发，越过了 Q6 的边界，可能重复计费 | 收：只认状态 0，而且不免预算 | `5bbc26649` |
| s4 | 3 | 应修 | 最后一次被拒仍按估算扣预算 | 收：明确被拒的都扣 0，和重不重试无关 | `5bbc26649` |
| s4 | 4 | 应修 | `quota` / `用量` 这类泛词把每分钟限流判成额度用完 | 收：短时窗口的证据优先 | `5bbc26649` |
| s4 | 5 | 应修 | HTTP 200 流内的 `rate_limit_error` 漏判 | 收：映射到 `.rateLimited` | `5bbc26649` |
| s4 | 6 | 应修 | 直接匹配原始 JSON，中文转义能绕过 | 收：先解码错误字段，再匹配 | `5bbc26649` |
| s4 | 7 | 应修 | `Retry-After: inf` 转 Int 崩溃 | 部分收：不再崩；inf / 超大值封顶 3600，NaN / 负数置空（取舍见 §3） | `5bbc26649` |
| s4 | 8 | 建议 | 数字 `error.code` 当 HTTP 状态用应该限定协议 | 收：只对 OpenRouter | `5bbc26649` |

审查原文在 session scratchpad 的 `review-compat-s{1..4}.out`（临时目录，不进 git）。

---

## 5. 粟粟验收步骤

> 要合进 master、装到模拟器上才能验。用你自己的卡，**每家都要先确认卡上的「工具」是开着的**。

**A. DeepSeek / Kimi 工具第二轮不再 400（C1）**
1. 用 DeepSeek 官方卡、思考模型（`deepseek-reasoner`），发一句一定会让它调工具的话（比如「查一下现在几点」/ 让它搜一下）。
   - 预期：工具卡出现，**工具结果回去之后那次请求不报 400**，最后有回复。
2. Kimi 官方卡（`api.moonshot.cn`，或 Kimi Code 国内 `api.kimi.com/coding` 的 OpenAI 格式），用 K2 thinking / K3，同样操作。预期同上。
3. **接着在同一个对话里再发第二句**，这一步是在顺带验 §2.1：
   - 如果出现「这个接口要求把模型上一步的思考原样传回去…」+ 400，就是 3b 的问题（已知，不是这次的回归）。告诉我一声就行，这正好就是 Q4 的实测结果。

**B. 思考出现在「思考过程」折叠里（B）**
4. 还是用上面的 DeepSeek / Kimi 卡发一句普通的话。等回复**完成后**，正文上方出现「思考过程」折叠，展开能看到思考；正文里不夹思考。
   - 流式输出时看不到思考，这是正常的（Q9）。
5. 「设置 → 思考过程」切到隐藏，再看同一条：思考不显示。

**C. 开头带 `<think>` 的中转（B / Q3）**
6. 找一张会把思考写在正文里、以 `<think>…</think>` 开头的卡（比如本机 Ollama 的 qwen3 / deepseek-r1，或者你知道这么返回的中转），发一句。
   - 预期：正文里不再出现 `<think>…</think>` 那段，它出现在「思考过程」里。
   - 如果你有人设是**故意**让回复以 `<think>` 开头的，看一眼它的正则脚本还正不正常（§1.1）。

**D. 断网 / 限流时出现重试胶囊（D）**
7. 限流：用 OpenRouter 的 `:free` 模型连续快速发几句，触发 429。
   - 预期：聊天页闪一条「⏳ 请求太频繁被限流了，N 秒后自动重试（1/2）」。重试成功就正常出回复；不成功就是一条带「被限流了…」开头的报错。
8. 断网：Mac 上用 Network Link Conditioner 设 100% Loss（或者发出去以后、出第一个字之前立刻关 Wi-Fi）。
   - 「连接中途断开」会出「⏳ 连接断了，马上重试一次」。
   - 发之前就没网（-1009）不会重试，直接说人话。**这是设计如此**（Q6）。
9. 重试胶囊出现时点停止：能停下来，之后也不会再自己发出去。

**E. 额度用完「去看」打开对的卡**
10. 用一张余额为 0 的卡（比如没充值的 DeepSeek 账号，回 402 Insufficient Balance；或者 OpenRouter 余额 0 用付费模型）。
    - 预期：报错开头是「这张卡的额度用完了或余额不足，充值或换一张卡」，带「去看」按钮。点开的是**这张卡**的编辑页，不是别的卡。

**F. 超长「去改」滚到「上下文深度」行**
11. 挑一个上下文小的模型，贴一大段超长文本发出去。
    - 预期：报错开头是「对话太长了，超过这个模型一次能读的长度…」，带「去改」。点开后跳到预设设置，并**滚到「上下文深度」那一行**（`SettingsJump.contextDepthAnchor`）。

- [ ] A 1–2 通过　- [ ] A3 结果记一下（400 / 不 400）　- [ ] B　- [ ] C　- [ ] D　- [ ] E　- [ ] F

---

## 6. review_phase 清单

- [x] 边界情况 / 交互风险 / 技术债
- [x] 审查裁决表（astra 四轮 19 条）
- [ ] kimi 审（四个阶段都没跑）
- [ ] 说明书：facts 已加，`check` / `rewrite` / `build` 未做（§3）
- [ ] 阶段 0 实测 → 定 Q4 / Q5 / Q12 → 3b 做不做
