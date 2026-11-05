# review · 小芽 v3（P1 + P2 + md 正文化）

范围：[plan-小芽-v3](plan-小芽-v3.md)。提交：`ddacaa32`（P1）、`ffcff580`（P2）、`7f66cb6b`（本机模型改成提供商里的一项）、`5db089fe`（正文化 md）。P3（KV 前缀复用）未做。
验证：Mac 单测（Ledger / Appearance / LocalTurn / ModelStore / LocalChatProvider / AppIcon / ProviderManagerDefaults）全过；Mac 真模型集成测（两单排队按序跑完、Router → 本机卡流式出字、后台任务被拒）；iOS 真机编译通过并装 Air。**手机上的速度实测还没拿到**（打点已在包里，等她用过后拉操作记录）。

## 1. 边界情况

- **本机不带历史的「并一句」启发式**：只在小芽上一句是反问（没交卡、问号结尾）时，把她再上一句并进来。小芽用句号收尾的反问、或者她隔了几轮才回「随便」，都接不上；接不上时本机模型只看到「随便」，挂上全部工具，大概率反问第二次。
- **按关键词挑工具**：关键词表是手写的（角色 / 世界书 / 预设 / 记忆 / 外观）。没命中关键词又不在对应页面时全挂，prompt 回到约 2500 token；命中错组（比如「给角色写一条世界书设定」同时命中两组）时两组都挂，这是对的。
- **追问兜底只认「预览卡片」四个字**：模型换种说法（「看看卡片」「点一下应用」）假装交了提案，兜底不会触发。
- **编辑以前的话**：生成中不给编辑（菜单里不出现）；删掉的消息里没盖章的卡直接没了，盖过章的只剩账本里能撤。
- **主聊天用本机模型**：图片只会告诉模型「看不到」，不拦发送；上下文按字数截（中文约一字一 token，英文会高估字数、截得偏狠）。
- **iOS 进后台 / 内存警告**：`LocalLLMService` 会停掉全部排队请求并回 failed；mac 进后台不停（mac GPU 后台可用）。
- **本机模型卡被删**：小芽的模型选择还指着 `local-mlx/...`，会退到「还没接模型」的提示，重建卡（id 固定）就恢复。

## 2. 与下一模块的交互风险

- **`LocalLLMService` 是全局串行**：以后如果放开后台任务用本机（D1，前提是 app 保活），要加优先级——聊天插队到后台任务前面，否则她发一句要等记忆提取跑完。
- **`AssistantBackendRequest` 同时服务小芽和主聊天**：`maxTokens` / `nudge` 字段是小芽语义，主聊天只用 system/history；以后加字段注意两边默认值。
- **`XiaoyaModelChoice` 存的是复合模型 id**：API 卡改 id / 删卡 → 选择失效但不会自动清。`resolveStaleSelectedModel` 只管 `selectedChatModel`，没管 `xiaoya.model`。
- **提案工具描述在本机模式被追加「细节自己编」**：以后新增 `propose_` 工具自动吃到这句；如果某个工具不该自编（比如删除类），要从 `localDefinitions` 里排除。
- **`StreamingTextView` 改成泛型**：主聊天调用点没改，但以后给它加依赖 `StreamingMarkdownSource` 专有成员的代码会编不过——按泛型约束写。

## 3. 技术债

- **`query_memories` 是全量 fetch 再内存过滤**（v1 就这样，`AssistantTools.queryMemories`）：违反「关键词匹配走 SQLite predicate」。记忆多了会慢；v4 R1 动记忆时一起改。
- **P3 KV 前缀复用没做**：system + 工具每轮重算；多轮工具调用在手机上仍然慢。
- **下载器 LFS 卡死 bug 没修**：Air 上下 4B 时 `tokenizer.json` 0 字节卡住（跳到 CDN 后既不超时也不换镜像）；这次绕过去了（电脑下好推进手机），根因没查。
- **手动推进手机的模型目录没设 `isExcludedFromBackup`**：会进 iCloud 备份（2–3 GB）。
- **追问兜底 / 并句 / 关键词表都是启发式**，依据是 Mac 上每种写法 5–6 次的小样本（记在 plan §5 实测补记），没有回归测试集；换模型版本要重测。
- **说明书没同步**：本机模型、小芽模型选择、舞台齿轮都还没进 `manual/facts/`。
