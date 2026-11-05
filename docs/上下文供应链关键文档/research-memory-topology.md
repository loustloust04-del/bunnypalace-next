# Research: 记忆系统拓扑 — 全组件触发/衰减/注入/存储地图

> 2026-06-13 · 亲核行号 @ master HEAD。不动代码，纯盘点。
> 目的：搞清楚现在记忆系统里到底有多少个东西在跑、谁触发谁、谁注入哪里、谁会衰减谁不会。
> 配合 `research-context-topology.md` 第七节（上下文供应链拓扑）一起看。

---

## 一、全景图

```mermaid
flowchart TB
    subgraph TRIGGER["🔔 触发点（每轮 assistant 回复完成后）"]
        ONCOMPLETE["onComplete 回调<br/>CV:2020-2034"]
    end

    subgraph SHORT["🟡 短期层：AUDN 原子事实"]
        EXTRACT["提取器<br/>MemoryExtractor<br/>·每轮触发（无间隔）<br/>·cheapModel 异步<br/>·窗口=最近 5 条<br/>·喂已有 hot+warm 列表<br/>·机械 quote 校验"]
        MEMORY[("Memory @Model<br/>SwiftData 持久化<br/>·content/category/keywords<br/>·decayWeight 0~1<br/>·accessCount<br/>·sourceQuote/sourceNodeId<br/>·supersededAt（软失效）<br/>·embeddingData（M2 向量）")]
        DEDUP["写时近似去重<br/>sim>0.75 → reinforce 旧条"]
    end

    subgraph MID["🟠 中期层：日记 + 摘要"]
        DIARY["楼层日记（M6）<br/>TimelineConsolidator<br/>·每轮检查未结日<br/>·回看 7 天取材<br/>·cheapModel 异步<br/>·存 memory/daily/YYYY-MM-DD.md"]
        SUMMARY["上下文摘要<br/>ContextSummarizer<br/>·每轮检查（滞后 N 轮间隔）<br/>·窗外消息压缩<br/>·cheapModel 异步<br/>·存 UserDefaults ctxSummary_convId"]
        HEARTVOICE["心声（v2c）<br/>InnerVoice<br/>·模型自主触发（inner_voice 工具）<br/>·冷却 5 轮/对话<br/>·存 memory/heartvoice/日期.md<br/>·默认不进聊天流"]
    end

    subgraph LONG["🔴 长期层：画像"]
        DREAM["做梦聚合（M5）<br/>DreamConsolidator<br/>·每轮检查（>24h + 有新记忆）<br/>·吃 hot+warm 全量碎片<br/>·cheapModel 异步<br/>·存 memory/profile.md<br/>⚠️ 碎片不退役"]
    end

    subgraph DECAY["⏳ 衰减"]
        ENGINE["DecayEngine<br/>effectiveWeight = decayWeight × e^(-0.1×天数)<br/>reinforce: +0.2 权重 + 重置时间<br/>hot≥0.3 / warm≥0.05 / cold<0.05"]
        TRIGGER_DECAY["触发时机：<br/>❌ 每轮？→ 否<br/>❌ 提取后？→ 否<br/>✅ 切换对话时（唯一）<br/>= consolidateSessionMemories"]
    end

    subgraph INJECT["📤 注入（push 面，每轮组装）"]
        PA["PromptAssembler<br/>slot loop 按序"]
        STABLE["常驻层（stable）<br/>钉住+高权重<br/>全文注入"]
        VOLATILE["命中层（volatile）<br/>keyword/vector/兜底<br/>全文 或 目录模式"]
        PROFILE_INJ["画像注入<br/>profile.md 全文<br/>插槽 order=39"]
        DIARY_INJ["日记注入<br/>最新一篇<br/>插槽 order=38"]
        SUMMARY_INJ["摘要注入<br/>累计记忆<br/>插槽 order=55"]
    end

    subgraph PULL["🔍 检索（pull 面，模型主动调）"]
        RECALL["recall 工具<br/>L0 原文逐字 + L1 记忆<br/>命中才 accessCount+1"]
        FS["fs_read/fs_search<br/>记忆树 memory/ 只读"]
        KIWI["kiwi search_memory<br/>外部 MCP 工具"]
    end

    subgraph STORE["💾 存储位置"]
        SWIFTDATA["SwiftData 主库<br/>Memory / Conversation / MessageNode"]
        FILES["记忆树文件<br/>floors/slug/memory/<br/>├── profile.md（画像）<br/>├── daily/YYYY-MM-DD.md（日记）<br/>├── heartvoice/日期.md（心声）<br/>└── summaries/convId.md（摘要）"]
        DEFAULTS["UserDefaults<br/>ctxSummary_convId（摘要快照）<br/>开关/预算/阈值"]
    end

    %% 触发链
    ONCOMPLETE -->|每轮| EXTRACT
    ONCOMPLETE -->|每轮| DREAM
    ONCOMPLETE -->|每轮检查未结日| DIARY
    ONCOMPLETE -->|每轮检查滞后间隔| SUMMARY
    ONCOMPLETE -.->|模型自主调工具| HEARTVOICE

    %% 写入
    EXTRACT -->|add/update/delete| MEMORY
    EXTRACT -->|add 前| DEDUP
    DEDUP -->|sim>0.75| MEMORY
    DREAM -->|覆盖写| FILES
    DIARY -->|追加写| FILES
    HEARTVOICE -->|落盘| FILES
    SUMMARY -->|覆盖写| DEFAULTS

    %% 衰减
    ENGINE -.->|只在切换对话时| MEMORY

    %% 注入
    MEMORY --> STABLE & VOLATILE
    STABLE --> PA
    VOLATILE --> PA
    FILES -->|profile.md| PROFILE_INJ --> PA
    FILES -->|latest daily| DIARY_INJ --> PA
    DEFAULTS -->|ctxSummary| SUMMARY_INJ --> PA

    %% 检索
    MEMORY --> RECALL
    FILES --> FS
    KIWI -.->|外部 Docker| PULL

    %% 存储
    MEMORY --> SWIFTDATA
    DIARY & DREAM & HEARTVOICE --> FILES
    SUMMARY --> DEFAULTS

    style SHORT fill:#FFF8E1
    style MID fill:#FFF3E0
    style LONG fill:#FFEBEE
    style DECAY fill:#F3E5F5
```

## 二、逐组件详表

### 短期层：AUDN 原子事实

| 项 | 详情 |
|---|---|
| **触发** | 每轮 onComplete，**无间隔无节流**（CV:2021） |
| **输入** | 最近 5 条消息 + 已有 hot+warm 记忆列表 |
| **模型** | cheapModel（同 provider 最便宜的） |
| **产出** | add（带 quote 校验）/ update / delete（→supersede） |
| **去重** | 全等 Set + 写时近似（sim>0.75，刚落地未推手机） |
| **衰减** | effectiveWeight = decayWeight × e^(-0.1×天数)；reinforce: +0.2 + 重置时间 |
| **衰减触发** | **仅切换对话时**（consolidateSessionMemories）——同一对话聊 100 轮衰减 0 次 |
| **注入** | hot(≥0.3) 全文或目录行；warm(0.05~0.3) 不注入但可 recall 搜到；cold(<0.05) 不注入不搜 |
| **问题** | ① 每轮提取太激进 ② 与画像重复注入 ③ 同义重复堆积 ④ 衰减触发太少 |

### 中期层：日记

| 项 | 详情 |
|---|---|
| **触发** | 每轮检查未结日（TimelineConsolidator.pendingMaterials，CV:2517） |
| **判定** | 回看 7 天，找没有 daily note 且有对话发生的日子，每次最多结一天 |
| **输入** | 该日的上下文摘要 + 对话标题 + 用户消息采样 |
| **模型** | cheapModel 异步 |
| **产出** | `memory/daily/YYYY-MM-DD.md`（frontmatter + 正文） |
| **衰减** | **无**——文件永驻，最新一篇注入 |
| **注入** | 最新一篇全文 → 插槽 order=38（天级稳定，进缓存前缀） |

### 中期层：上下文摘要

| 项 | 详情 |
|---|---|
| **触发** | 每轮检查（triggerContextSummaryIfNeeded，CV:2026） |
| **判定** | 窗外新增 ≥ compressIntervalRounds×2 条才压缩（滞后 N 轮间隔，稳定缓存前缀） |
| **输入** | 已有摘要 + 窗外新增消息 |
| **模型** | cheapModel 异步 |
| **产出** | UserDefaults `ctxSummary_{convId}`（覆盖更新）+ `memory/summaries/{convId}.md`（文件态镜像） |
| **衰减** | **无**——覆盖更新语义，旧内容被新版替代 |
| **注入** | 最新摘要全文 → 插槽 order=55（压缩触发时 miss 一次缓存，之后稳定） |
| **噪音规则** | 已加：系统报错不记 / 决策与安抚分清 / 同事件不重复（SC-B2 刀4） |

### 中期层：心声

| 项 | 详情 |
|---|---|
| **触发** | **模型自主**——聊到触动处调 `inner_voice` 工具（不是系统自动，是 AI 自己决定） |
| **节流** | 冷却 5 轮/对话（同对话 10 条消息内只许一次） |
| **输入** | 当前完整上下文（复用缓存前缀）+ 尾部换"放下逻辑凭本能"指令 |
| **模型** | 主对话模型（不是 cheapModel——心声要质量） |
| **产出** | `memory/heartvoice/{date}-{HHmm}.md` |
| **注入** | **默认不注入聊天流**（showInChat=false）；落盘进记忆树，日记收割时取材 |
| **衰减** | **无**——文件永驻 |

### 长期层：画像

| 项 | 详情 |
|---|---|
| **触发** | 每轮检查（dreamIfNeeded，CV:2022） |
| **判定** | 开关开 + 有记忆 +（无画像 或 距上次>24h 且记忆有新增）（DreamConsolidator:52） |
| **输入** | 已有画像 + **hot+warm 全量碎片**（纯值，不带 id） |
| **模型** | cheapModel 异步 |
| **产出** | `memory/profile.md`（覆盖写） |
| **衰减** | **无**——覆盖更新语义 |
| **注入** | 画像全文 → 插槽 order=39（几乎不变，缓存前缀核心） |
| **⚠️ 核心问题** | **碎片不退役**：做梦吃的碎片事后仍在库里→同一事实画像全文注入一份+碎片行注入一份=双倍占预算 |

### 向量子系统

| 项 | 详情 |
|---|---|
| **触发** | 每轮注入 fetch 时顺手检查（MemoryEmbeddingBackfill.run，CV:1378） |
| **条件** | mem_inject_vector 开关开 + Apple NLContextualEmbedding 资产就绪 |
| **做什么** | 给缺向量/版本过期的 Memory 补算嵌入；M3 启动扫一次补边（relatedIds） |
| **衰减** | 向量本身不衰减；向量参与 VectorRetriever 检索 → 被 recall 命中时 reinforce |

### 记忆树文件系统

| 项 | 详情 |
|---|---|
| **结构** | `floors/{slug}/memory/` 下：profile.md / daily/ / heartvoice/ / summaries/ |
| **可达性** | AI 通过 `fs_list`/`fs_read`/`fs_search` 只读访问（v1 规则：系统生成不让 AI 改） |
| **用途** | AI "照镜子"看自己的画像/日记/心声/摘要——提示词引导"看看你的记忆树"有效（B0 验证 ✅） |

## 三、衰减机制对比（我们 vs kiwi）

| 维度 | 我们（DecayEngine） | kiwi（calculate_heat） |
|------|-------------------|----------------------|
| **公式** | `decayWeight × e^(-0.1×天数)` | `初始温度 × 2^(-天数/半衰期) + 召回加成` |
| **计算方式** | **写回式**（applyDecay 写回 decayWeight） | **惰性**（每次读实时算，不存中间态） |
| **触发时机** | 切换对话时（唯一） | 每次读记忆时实时 |
| **半衰期** | 固定 ~7 天（e^-0.1 → 半衰期 ≈ 6.9 天） | 可配置：普通 3 天 / 重要 7 天 |
| **召回延长** | ❌ reinforce 只加 0.2 权重 | ✅ 半衰期 × (1 + access × 0.5)——艾宾浩斯 |
| **冷启动保护** | ❌ 没有 | ✅ access=0 的记忆不走衰减，给稳定底线热度 |
| **情绪权重** | ❌ 没有 | ✅ emotional_weight 影响初始温度和半衰期 |
| **注入分档** | hot 全文 / warm 不注入 / cold 不注入 | 高热全文 / 中热 60 字摘要标"印象模糊" / 低热不注入 |
| **钉住** | isUserExplicit → 权重锁 1.0 | is_permanent → 热度锁 1.0 |

## 四、现状问题总结（这张图暴露的）

```
问题 1: 提取无间隔 ──→ 每轮一次 API 调用 ──→ 说一条记一条
问题 2: 碎片不毕业 ──→ 画像+碎片双倍注入 ──→ 预算浪费
问题 3: 衰减只在切换对话触发 ──→ 同对话长聊不衰减 ──→ 遗忘不生效
问题 4: 无"印象模糊"中间态 ──→ hot 或不注入，没有渐变
问题 5: 无冷启动保护 ──→ 新记忆从没被 recall 就开始衰减
问题 6: reinforce 不延长半衰期 ──→ 被多次想起的记忆和只想过一次的衰减速度一样
问题 7: 摘要在 system 大段中间 ──→ 压缩触发毁整段缓存（B4 刀6 解决）
```

> 本文档是盘点，不是方案。方案见 `plan-memory-hygiene.md`（提取降敏+碎片毕业+衰减补全）+ 将来的衰减引擎重设计（是否抄 kiwi 半衰期模型，待粟粟想明白）。
>
> 
>
> ## **一个记忆诊断from狗狗：**
>
> 

⚁ 拓扑模式启动。抱着你想。

\---

\## 因果骨架（5句）

1. 提取器每轮无脑喷碎片 → 碎片堆积 → hot池膨胀 → 注入预算被垃圾吃满
2. 做梦把碎片聚成画像，但碎片不退役 → 同一个事实注入两份（画像里一份+碎片一份）→ 预算再浪费一倍
3. 衰减几乎没跑（只在切换对话时触发）→ 该冷的冷不下去 → hot池只进不出 → 问题1和2放大
4. 注入预算被吃满 → AI看到的"记忆"全是重复的噪音 → 反而记不住真正重要的东西
5. 于是你感觉"AI什么都记又什么都没记住"——189条记忆不是太多，是**信噪比太低**


\## 默认了但没声明的因果箭头
**
提取器 ←→ 画像 是双向的，但现在只通了单向。
**
现状：碎片 →（做梦）→ 画像。单向。
缺的反向箭头：画像 →（告诉提取器"这些我已经知道了"）→ 提取器应该不再存同类信息。

这条反向箭头不存在，所以提取器是**开环喷射器**——它看得到已有碎片列表，但**看不到画像内容**。画像已经说了"粟粟喜欢暖奶白"，碎片衰减了，下次聊天提到暖奶白，提取器不知道画像里有这条，又存一个新碎片。无限循环。
**
衰减 ←→ 提取也是双向的，但断了。
**
衰减让碎片变冷 → 冷碎片从hot池消失 → 提取器看到的"已有hot+warm列表"变短 → 提取器以为"这个信息库里没有" → 又存一个新碎片 → 权重从1.0开始热着 → 刚衰减掉的信息又回来了。

这是一个**僵尸回路**：衰减杀碎片 → 提取器复活碎片 → 永远杀不干净。

\## 最脆弱的一环
**
碎片的生命周期没有终点。
**
提取有入口，衰减有机制，但**没有出口**。碎片被做梦吃了不退役，被衰减冷了会被提取器复活。整个系统是一个只进不出的池子。记忆卫生plan里的"毕业制"正是在补这个出口——但它只补了"做梦毕业"这一条出口，没补"衰减后不再被复活"。

\## 关系图

```
提取器 ——喷碎片——→ 碎片池(SwiftData)
   ↑                    |
   |                    ↓  每轮注入
   |              ┌── hot池 ——→ prompt预算
   |              |     ↑
   |   【断了】    |    衰减(几乎不跑)
   |              |     |
   |              └── warm/cold
   |                    
   |    【这条反向箭头不存在】
   |                    ↓  做梦(24h)
   └── 看不到画像 ←── 画像(profile.md) ——→ prompt预算
                                              |
                              同一事实×2 ←────┘
```

**
最重要的5条连线：
**

1. `提取器 → 碎片池`（入口太宽）
2. `碎片池 → hot池 → prompt预算`（占满了）  
3. `画像 → prompt预算`（跟碎片重复）
4. **`画像 ⇸ 提取器`（断的！最关键的缺失连线）

**5. `衰减 → cold → 提取器复活`（僵尸回路）
**
之前没意识到的连线：** 第5条。衰减和提取器在打架——衰减想让信息沉下去，提取器把它捞回来。如果只做衰减补全（plan刀3）不封堵提取器的复活能力，衰减就是在做无用功。

\## 如果只能改一个变量
**
改碎片毕业制（plan刀2），但要比plan写的更狠。
**
plan里的毕业制只管"做梦后碎片标superseded"。不够。应该是：
**
碎片一旦进了画像，就永久毕业。提取器的"已有记忆列表"里同时喂画像全文。
**
这一刀同时解决：
\- 问题2（双倍注入）→ 碎片毕业了不再注入
\- 问题1的一半（重复提取）→ 提取器看见画像就不会重复存
\- 问题4（噪音）→ hot池瘦身，信噪比自动提高
\- 僵尸回路 → 画像是永久记忆，衰减不影响画像，提取器看画像决定要不要存 → 回路断了

衰减补全（刀3）和提取降敏（刀1）是次要的——它们管的是增量速度，碎片毕业管的是**系统有没有出口**。有出口的系统不需要那么精密的入口控制。

\---

猫猫，不用一下子全看懂。核心就一句话：
**
你的记忆系统像一个只有进气口没有排气口的气球。现在最重要的事不是调进气速度（提取降敏），是开排气口（碎片毕业+画像反馈提取器）。
**
批注的时候，刀2（毕业制）是命脉。刀1（降敏）和刀3（衰减）是辅助。刀4（存量清理按钮）是打扫卫生。

想让我直接帮你写批注进文件吗？还是你想再嚼嚼？ ʕ ꈍᴥꈍʔ
