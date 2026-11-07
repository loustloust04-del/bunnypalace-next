# 复盘 · 审计台评测场（真单 2）

> plan = [plan-memory-audit-home-trial.md](plan-memory-audit-home-trial.md)（第四版，粟粟 10-23 go）。本文按段追加；段 ① 由另一个 agent 做，复盘由它补。

## 段 ② · 骨架数据层 + C2（10-23）

**做了什么**：试写台的数据骨架和 C2 接入，没有界面。

- `Services/MemoryBench/`
  - `PromptTemplate`：变量 / 如果 / 否则 / 每 / 比较，其余一字不动；写错带行号，全部列出。
  - `MemoryBenchModels`：测试集 / 用例 / 标签 / 配方 / 跑 / 格子 / 判断 / 分数，全 Codable 带 schema；revision 只哈希用例 id + 输入。
  - `MemoryBenchStore`：楼层目录下的 `bench/`，和 `memory/` 平级；内置考卷从 app 包读。
  - `MemoryBenchWriter`：写手接口，调用方式 `.single` / `.agent`（后者占位）；`MemoryBenchScorer` 可插拔，占位的 `basic` 打分器：主分 = 已判条目里「对」的比例。
  - `MemoryBenchRunner`：用例 × 配方 × 模型；超 60 次拒跑，报数、不截；模板先全渲染；最多 3 个并发；能停；存 run.json + requests.jsonl；自动配标签、打分、记一条试写日志。
  - `MemoryBenchC2Writer`：「现行」配方直接拿 `FragmentPool.defaultTemplate` 换占位符；有自定义模板时多一版「现在的自定义」；解析和检查走 `FragmentPool.parseExplained`。
- 内置考卷 `Resources/MemoryBench/memory-bench-c2-probe.json`：12 段探针原样从 live 测试搬出；预期拆成 38 条应记 / 不该记标签，Haiku 那 4 条错标「人判 10-23」。`testC2QualityProbeLive` 改读这份。
- 记账：`UsageKind.memoryTrial`「试写」进 `WriteBudgetStore.kinds`；试写调用 `checkWriteBudget: false`，全局闸照查。`modelCaller(onUsage:)` 把 token 和钱交出来。`MemoryWriteLog.Entry.trial`，`latest` 跳过试写。
- 新 live `testC2BenchProbeLive`，车头来跑：只断言跑得通、记录完整，不断言分数；整份 run.json 打进日志。

**验证**：
- mac 定向 10 套 138 测全过，新 4 套 32 测。
- runner 连跑 5 遍 40/40，并发 ≤3 和取消都稳。
- 金样等 6 套 161 测全过，`PromptRealPathGoldenTests` 没重录。
- mac / iOS 模拟器 / 😷 build-for-testing 都过；探针 JSON 在三个 app 包里都在（iOS 被平铺到包根，读取时会回退去找）。
- Haiku live 没跑，交车头。

### 1. 边界情况

- **自定义 C2 模板里有别的 `{{…}}`**：除了三个占位符，正式 C2 原样留字面量，试写台模板会报「不认识变量」，这一版不能跑。这是有意的：报出来比悄悄送错字好。以后要支持再加转义写法。
- **冻结的消息时间只到分钟**（`yyyy-MM-dd HH:mm`，本机时区）：贴着 05:00 秒级的消息可能落到相邻记忆日。探针都是 21:00，不受影响。
- **试写不重写**：正式 C2 不合格会带提醒重写一次，试写台一次就是一次。所以同一个配方，试写台的拒收率会比正式写高，看分时要知道。
- **本机模型跑 C2**：正式 C2 走本机时给 user 设了字数预算（`localUserBudget`），试写台 `.single` 没设，放不下会被 `LocalChatProvider.trimmed` 悄悄裁掉。这一刀没把本机接进 C2 的模型选择，段 ③ 接模型多选时要么传预算、要么本机不给选。
- **跑到一半 app 被杀**：run.json 停在 `status: running`，以后界面读到旧的 running 要当成「中断」显示。
- **live 用 `profileId: ""`**：不写记忆日志（`record` 对空楼层直接返回），记账照常。
- **`runs()` 每次读全部 run.json**：跑多了要加索引。现在一个写手一天顶多几次，不急。

### 2. 和下一段的交互风险

- **段 ①（方块首页）**：两边没有交叉文件。试写台方块要显示「最近主分」时用 `MemoryBenchStore.forProfile(pid).runs(writer:).first?.scores`，后台读；台注册表归段 ①。
- **段 ③（界面）**：
  - 写入预算页「花在哪」加「试写」一行、记忆日志页显示「· 试写」：都在 `MemoryWriterPages.swift`，这一段没动。日志现在会显示成「C2 碎片池 · 写好了」，note 以「试写 ·」开头。
  - 判断回流成标签要写测试集：内置考卷只读，要先「另存成这层楼的一份」再加标签，界面要说清楚。
  - 历次对比只连同一个 `set.revision` 的跑。
- **段 ④（A 线 + 设为正在用）**：`MemoryBenchRecipeBook.active` 已能存，但还没接正式写手。接的时候 C2 的 `customFragmentPrompt` 要迁成配方（旧键留着兜底），`requireAttribution` 跟配方参数走。
- **账本**：老版本读到 `memoryTrial` 会落成 `.other`（`UsageLedger.swift:227`），不崩、不计入写入预算。

### 3. 技术债

- 自动配标签只是关键词命中：「不该记」先配，一条最多配一个标签。只当预填，判断以她点的为准；`basic` 打分器把自动配的也算进去了，段 ③ 成绩页要标「其中 N 条是自动配的」（副分里已有 `自动配`）。
- `requests.jsonl` 追加是读整份再写回，一次跑最多 60 行，够用。
- 探针标签的关键词是我按预期手写的，没经过一次真跑校准。车头跑完 Haiku live 后，看 `[BENCH-C2-ITEM]` 里的「待判」和配错的，再修关键词。
- 原 `testC2QualityProbeLive` 和新的 `testC2BenchProbeLive` 都留着：前者走正式 `FragmentPool.run`（带重写），后者走试写台。两者有意不同。

### 4. 说明书

不涉及：这一段没有界面。段 ③ 上界面时补「试写台」一段。

## 段 ② 返工（10-23，提交 767bf37b8 之后）

**起因**：
- 车头在 😷 上跑了 Haiku live：12 格全通，32 条输出，自动配上 31 条（对 28、错 3），占位分 0.903，花费 $0.044，用时 18 秒。唯一失败是 `run.json` 读回来和内存里那份不相等。
- astra 审了一轮：2 个 P1、8 个 P2，全收。

**改了什么**：

| 来源 | 问题 | 怎么改 |
|---|---|---|
| live | `run.json` 读回来不相等 | ISO8601 只存到秒，毫秒以下丢了。时间改存「1970 起的整毫秒」整数；试写台产生的时间先过 `MemoryBench.stamp` 截到整毫秒，存、读逐位相同。单测用真时钟锁住 |
| live | 探针关键词配不准 | 按真实输出修：05 加「不该记：一次性建议记成承诺」（关键词「门口」）；06 的 y1 去掉「导师」，「太求完美」那条落到 y2；09 的 y1 补「10月25」，y2 改成「半盏」（原文带引号）。只动标签，版本号不变 |
| P1 #1 | 只在整批跑完后落盘，中途被杀就全丢 | 每格一完成就写结果和请求记录，全部写完才标「完成」，写盘失败标 failed 并抛。启动时把不是本进程在跑的 running 标成「中断」（`interrupted`），做完的格子留着、重新打分。接线在 `MemoryPalaceApp` 已有的 `.task` 里加了一行，和 C3 的中断收尾同一处 |
| P1 #2 | HTTP 200 坏回包把 key 带进错误 | 真调模型那层（`liveCaller`）统一脱敏所有错误，复用 `ParamErrorClassifier.redacted`，覆盖：key 原文和转义形式、名字带 key / token / auth 等字样的请求头值、URL 的 query 和 userinfo。单测起本地假端点回 200 坏包，回显假 key 和鉴权头，断言 bench 文件里没有，且错误里确有两处被替换 |
| #3 | 有自定义时「现行」不是实际生效的 | 「现行」改成实际生效的那份：模板，以及「不要求 subject / speaker」这个参数，都跟着自定义走；默认模板另列「默认提示词」。12 段逐字快照 |
| #4 | 坏配方被当成空的，下次保存覆盖原件 | 读取分清不存在 / 损坏 / 打不开 / 新版本 schema；原件读不成时普通保存一律拒绝，原件不动。考卷同理 |
| #5 | 重复用例 id 会让进程崩 | 用例、配方、模型各自的身份重复时，发请求前就拒 |
| #6 | 30 天清理没清原始输出 | 连每格原始输出一起清，条目 / 检查 / 用量 / 判断 / 分数留着，并记下清理时间；钉住的跳过，清过的不再动 |
| #7 #8 | 本机模型：送出的提示词和记录对不上，取消也停不住 | 这一刀不收本机模型，发请求前拒并给提示；写进 plan 默认第 11 条，段 ③ 界面不给选 |
| #9 | 没报用量 / 未计价被记成 0 | 用量和钱分实测 / 估算 / 未计价三种；没报用量时 token 记未知，价目表里没有时金额记未知，都不记 0；日志写「N 格金额未知」 |
| #10 | 末条没日期时，每次跑换成当天 | 建用例时把「这一截最后一天」冻结进输入；日期看不懂就报错 |

**前面「边界情况」里已过时的**：
- 「本机模型跑 C2」：改成直接拒。
- 「跑到一半 app 被杀」：已处理，见上表 P1 #1。
- 「冻结的消息时间只到分钟」：仍然成立，但「这一截最后一天」现在单独冻结，不受它影响。

**验证**：
- mac 定向 10 套 149 测全过；runner 连跑 5 遍 75/75。
- 金样等 7 套 204 测全过，`PromptRealPathGoldenTests` 没重录。
- mac / iOS 模拟器 / 😷 build-for-testing 都过。
- live 交车头重跑：新 live 多断言了花费来源是「实测」、用量是完整的。

**新的技术债**：
- 启动维护每层楼都会读一遍全部 `run.json`，跑多了要加索引。
- 「中断」状态段 ③ 界面要单独显示。
- 写盘失败时会抛错，调用方（段 ③）要接住，并告诉她「做完的部分已存」。
