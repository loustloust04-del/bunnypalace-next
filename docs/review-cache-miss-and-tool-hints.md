# 复盘：提示缓存每轮只写不读 + 工具关了不带说明（10-15）

research：[缓存](research-cache-miss-1015.md) · [工具说明](research-tool-prompt-off.md)

## 做了什么
- **缓存**：请求体统一 `.sortedKeys`（`BaseChatProvider.encodeBody`，OpenAI 兼容 / Anthropic / ChatGPT OAuth 六处）。`CachePrefixStabilityTests` 六例，修前全红、修后全绿。
- **工具说明**（粟粟 10-15 选 A）：卡片说明三档（card_guide 能调→目录 / 她关了 card_guide 或总开关→不发 / 卡发不了工具→全文），点名的 roll_dice / ask_user / run_command 没有就去句；`<文件库>` 跟 fs_* 是否下发走，默认模板里的 fs 工具清单只提能调到的；`<设备>` 逐项、`<命令>` 只在有 run_command；〔当前能用的工具〕没收起的就不提〔更多工具〕；抽屉页顶部加总开关 + 常驻一行「中途开关工具贵一条」。
- 金样 G1–G8 重录，diff 只有三处预期变化（见 74e6d0d0b 提交说明）。

## 1. 边界情况
- **改完第一条一定断一次**：装上新包后每个对话第一条都会整段重写（键顺序从随机变成固定），之后才命中。粟粟验的时候看第二条起。
- 卡上关了工具调用 / 本机模型 / CC 这几种「本来就发不了工具」的卡：卡片说明照旧全文，但全文里提到 roll_dice / ask_user / run_command 的句子现在会去掉（这些卡本来也调不了）。
- `<文件库>` 里「需要看内容时用 fs_read」、记忆树「可用 fs_read / fs_search 查阅」两句没按可用性拆：她只关 fs_read、留着别的 fs 工具时还会看到。少见，没做。
- 用户自定义的文件库模板不改写（没法知道她写了什么）。

## 2. 和下一步的交互风险
- **缓存**：中途开关工具 / 改抽屉 → system 也跟着变（新行为），那一条整段重写，和改 tools 一样。抽屉页已常驻提示。
- 检查器「上一次真实发出」显示的 JSON 现在是排好序的键，和以前看着顺序不同，内容不变。
- `fileLibrarySystemHint(profileId:available:tucked:)` 新增两个可选参数，老调用（MainThreadIOBudgetTests）照旧。
- 〔状态〕里文件库那一行改成跟 `<文件库>` 段走（`fileLibraryHint?.hasPrefix("<文件库>")`）：fs 工具全关时不再说「具体文件用 fs_list 查看」。

## 3. 技术债
- 「10-11 以前为什么还能命中」没钉死（10-14 同一天合了 #089 / #093 / #094）。不影响结论和修法。
- 缓存回归测试只覆盖测试宿主能造的形状（无 MCP、无服务端 web_search 真回包、无图片附件的第二轮）。
- 卡片 / 文件库去句是按原文字符串替换：以后改了那几句原文，替换会静默失效——`ToolHintGatingTests` 有「全开时原文不变」「关了不再提工具名」两类断言兜着。

## astra 审查（gpt-6-astra，1 轮，6 条 P2，无 P0/P1）

| # | 意见 | 裁决 |
|---|---|---|
| 1 | 总开关关了，「我的记忆」尾注仍教 fs_read / remember，目录模式仍指路 recall | 收：组装层按这一轮能调到的工具去句（`PromptAssembler.droppingOffToolMentions`，不碰聊天历史） |
| 2 | 文件夹说明 / 常驻世界书里写 `{{time}}` 宏 → system 每分钟变，缓存断 | **不收（另开单）**：以前就有、和工具 / 键顺序无关，只在她自己写了时间宏时触发 |
| 3 | 文件库模板写死全部 fs_* + 〔更多工具〕；记忆树按记忆开关推荐 remember 等；〔我的记忆〕只开 remember 仍提 edit / forget；`<命令>` 仍推荐 fs_write / fs_edit | 收：全部按可用集合逐项生成（模板那句 astra 看到时已在 476fa6fd8 修了） |
| 4 | 日历 / 提醒只开查询仍说「读写」 | 收：整组 → 原文；缺了点名剩下的，只剩查说「查」、只剩写说「改」 |
| 5 | 搜索说明：browse_url 关了仍强制用它；search_web 收起时整段说明消失 | 收：按含收起工具的可用集合判断，browse_url 关时给不提它的版本 |
| 6 | 模型调 card_guide 拿到的写法没去句 | 收：执行时按这一轮能调到的工具去句 |

astra 另确认：`.sortedKeys` 未发现回归（嵌套排序、数组顺序保留、去 key 转义仍匹配）；`CachePrefixStabilityTests` 比的是原文字节、不是恒真；预览 / 三处实发同一口径。

## 说明书
不涉及（行为修复 + 抽屉页一行开关，说明书里工具抽屉那页等集中更新时补）。

---

## 缓存保留 1 小时（10-15 追加）

粟粟：「这个不应该也给user自己改吗」→「做，1h」。

### 做了什么
- `SamplingParams.cacheLongTTL`（nil 视为 1 小时，false 表示 5 分钟）。所有 cache_control 标记都通过 `BaseChatProvider.cacheMark` 生成：Anthropic 直连的 system、最后一条 assistant、块级标记，以及 OpenRouter 上的 Claude。同一请求内 TTL 一致，不会出现「长 TTL 必须排在短 TTL 前面」的问题。
- 预设 Prompt 页「缓存命中优化」开关打开时，下面会出现「缓存保留：1 小时 / 5 分钟」分段选择和一行费用说明；设置搜索可以用「缓存保留 / ttl」找到。
- 中转不认 ttl 的情况：`AnthropicProvider.cacheRejection` 判定条件是 4xx、报错里提到 ttl、而且这次确实发了 1 小时。满足时：
  - 只把这个地址记进 TTL 黑名单（`anthropicCacheLongTTLHostBlacklist`），以后都按 5 分钟；
  - 路由层把这一条按 5 分钟重发一次，被拒的那次不扣预算。
  其余提到 cache 的 4xx 照旧拉黑整个缓存。实发和预览都通过 `samplingForHost`，口径一致。
- 测试：
  - `CacheTTLTests` 4 例：默认 1h、选 5 分钟、黑名单退回、分类器；
  - `ParamAutoAdaptRouterTests.testLongTTLRejectedRetriesWithFiveMinutesAndRemembers`：本机假服务器端到端，覆盖被拒 → 重发成功 → 下一条一次就过、缓存没被关掉；
  - `ProviderOrderingTests` 夹具的标记多了 `ttl:1h`，属预期。

### 1. 边界情况
- **只在 Anthropic 直连 / 中转卡上做了自动退回**。OpenRouter（OpenAI 兼容路径）挂了 1h 却被拒时，这一条会报错。OpenRouter 文档支持 Anthropic 的 `ttl:"1h"`，实际概率低；真碰上了，把预设改成 5 分钟就行。
- 中转拒绝时，报错里如果**不提 ttl**（只说 cache 或字段名不详），会按旧规则拉黑整个缓存。比以前（5 分钟能用）退得更多，而且这一条照旧报错。目前见过的「不认字段」报错都带字段路径（`cache_control.ttl`），没有专门处理。
- 一个对话中途切换 1 小时 / 5 分钟，下一条会不会整段重写，没有实测。对话里只是 ttl 字段变了，前缀内容不变；保守估计贵一条。
- 只发一条就走的对话，1 小时写入（2×）比 5 分钟（1.25×）贵。这是粟粟选的默认值，说明文字里写了。

### 2. 和下一步的交互风险
- TTL 黑名单与缓存黑名单是两个 UserDefaults 键，互不影响；目前两者都没有 UI 入口可以清除（旧债，跟缓存黑名单一样）。
- 账本按 API 回的 `ephemeral_1h_input_tokens` / `ephemeral_5m_input_tokens` 分桶计价，这次没改。

### 3. 技术债
- 「被拒了自动退回 5 分钟」只学地址、不学模型。同一个中转的不同模型理论上可能表现不同，没做拆分。
- 预设导出 / 导入（酒馆 JSON 映射）不带 `cacheLongTTL`——`cacheFriendly` 本来也不带，老缺口，没顺手补。

### astra 审查（gpt-6-astra，1 轮，5 条 P2，无 P0/P1）

| # | 意见 | 裁决 |
|---|---|---|
| 1 | 判定只看正文含 ttl：429「Request throttled」/「ThrottlingException」也含 ttl → 限流被永久记成不认 1 小时 | 收：只认 400 / 422，且 ttl 要单独成词；测试补限流两例 + 422 字段路径一例 |
| 2 | TTL 重发和参数自愈共用一次额度：先去 temperature 再撞 ttl 会报错 | 收：TTL 分支不占自愈额度（沿用当前 attempt），以「地址已进黑名单」作为不会再进的保证；路由测试补「先参数再 ttl」一例 |
| 3 | OpenRouter 选 5 分钟后，账本仍把写入记成 1 小时（没回金额时按 2× 算） | 收：`usageCacheWriteIs1h` 跟实际发的 ttl 走 |
| 4 | OpenRouter 没有自动退回 | 不收：只对 openrouter 地址生效，OpenRouter 文档支持 Anthropic 1h；被拒时把预设改成 5 分钟即可（§1 已写） |
| 5 | 预设导出再导入丢「5 分钟」 | 不收（记债）：同一映射里 `cacheFriendly` 本来就丢，属老缺口 |
