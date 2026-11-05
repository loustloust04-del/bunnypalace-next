# DeepTutor 学习模块研究 + 记忆宫殿轻量学习模块对比方案

> research 阶段产物（pi-study，2026-08-31）。源码证据基于 DeepTutor v1.6.2 clone（`HKUDS/DeepTutor`）。
> 等粟粟确认理解后再进 plan。

---

## 一、DeepTutor 的核心逻辑是什么

**一句话：它不是"一个学习 app"，而是 chat agent loop 上的一个 capability（`mastery`）——真正的核心是一个刻意不含任何 LLM 调用的确定性引擎，LLM 只负责教学话术和判断，所有"学到哪了/下一步学什么"的决策都是纯函数算出来的。**

三层结构：

| 层 | 位置 | 规模 | 职责 |
|---|---|---|---|
| 确定性引擎 | `deeptutor/learning/` | ~5200 行纯 Python | 数据模型 + 掌握度计算 + 门槛判定 + 复习调度 + 持久化。**零 LLM、零 IO（policy.py 原话："No LLM calls, no I/O"）** |
| 工具面 + loop hooks | `deeptutor/capabilities/mastery/` | ~2000 行 | 9 个 `mastery_*` 工具挂进聊天 agent loop，ask_user 卡片绑定 |
| 教学话术 | `prompts/zh/system.md`（19 行）+ `prompts/zh.yaml` | ~110 行 | 导师 system prompt，驱动模型按引擎指令教学 |

### 关键机制（按价值排序，全带证据）

**1. 知识点四分类 + 双轨门槛**（`learning/models.py` KnowledgeType / `policy.py:36-49`）
- 每个知识点标四种类型之一：`memory`（记忆/事实）`procedure`（程序/步骤）`concept`（概念）`design`（开放判断）
- 门槛分双轨：**定量型**（memory/procedure）= 做题正确率 ≥ 0.9 才算会（注释："~0.9 mirrors Alpha School's '90% before you advance'"）；**定性型**（concept/design）= 学习者用费曼技巧自己解释，导师判断通过才算会——因为"概念题没有标准答案可以字符串匹配"

**2. 掌握度计算：recency-weighted + confidence cap**（`learning/mastery.py`，全文件 40 行）
- 最近 5 次作答加权 `(0.5, 0.7, 0.85, 0.95, 1.0)`，越近权重越高 → 早期犯错后来恢复会被奖励
- **信心上限**：只有 1 次作答最多 0.5 分，2 次最多 0.8 分 → "一次蒙对不算会"。这是整个防作弊设计里最小最妙的一件
- 注释明说："This is the one place the pedagogy math lives. To plug in a richer model (e.g. IRT/BKT), replace `compute_mastery` alone"——和我们 `SM2.swift` 头注释"将来换 FSRS 只换这里"是同一个设计姿势

**3. 门即游标（the gate IS the cursor）**（`policy.py:177-244` `next_objective`）
- **没有"当前阶段"计数器**。下一步学什么是纯函数现算的：①有待批的题 → 先批 ②有到期复习 → 先复习 ③按模块/知识点顺序找第一个没过门的 → 攻克它 ④全过 → complete
- 已证明掌握的自动跳过 = "test out / 压缩路径"是免费的，因为它读的是掌握证据而不是固定进度条
- 旧版有 7 个 stage 状态机，他们简化后**删掉了**，legacy stage 只做反序列化映射（`models.py:44-52`）——教训：stage 计数器是债，门才是真相

**4. pending question 服务端持久化**（`models.py` PendingQuestion / `capabilities/mastery/loop.py`）
- 题目登记时把**标准答案存在服务端**，永不经模型之手跨轮传递；呈现给学习者的投影里**连解析都不带**（防泄答案）
- 模型改成成题时，卡片 UI 用持久化状态**覆盖**模型自报的题面/选项（`_bind_pending_ask_user_args`）——不信模型记性
- 交互有完整状态机：registered → awaiting_input → answered → graded / abandoned，SQLite CAS + lease 保证崩溃恢复和幂等重试

**5. 间隔重复按知识类型分序列**（`learning/scheduler.py:10-15`）
- memory: `[0,1,3,7,14,30,60]` 天 / concept: `[3,7,14,30]` / procedure: `[3,7,14]` / design: `[14,28]`
- 连对 2 次跳两级（加速毕业），错一次降一级；有active错题的知识点复习优先级提到最高

**6. 出题纪律写进 prompt 且结构性兜底**
- prompt 要求：干扰项必须各自对应一种具体常见误解，长度/措辞与正确项相当，**绝不暗示答案**
- 结构性兜底：generic ask_user 会给选项加"(推荐)"后缀，mastery 卡片用正则**强制 strip**（`loop.py:36`）——"good for a preference card, disastrous on a quiz"

**7. 错误四分类**（`models.py` ErrorType）：`structural`（知识结构性）`deviation`（理解偏差）`application`（应用错误）`metacognitive`（元认知）。判分先用确定性粗分（白卷=metacognitive，其余=application），LLM 在 error_diagnosis 阶段再细分

**8. learner override + provenance**（`policy.py:74-90`）：学习者可以声明"这个我会了"直接过门，但所有展示面都标记来源是 `system`（考出来的）还是 `learner`（自称的）——证据永不被自称覆盖

### 它的大，大在哪（我们不需要的部分）

- 多引擎 RAG（LlamaIndex/PageIndex/GraphRAG/LightRAG/Obsidian…）、Book 编译器、知识库版本化 —— 材料的**供给**侧
- SQLite CAS/lease/多 session 并发防御 —— 它是多用户 web 服务
- ask_user 卡片前端、learning dashboard、15 渠道 IM —— 平台层
- 导师 loop 本身：每轮强制 `mastery_status` 驱动教学的 agent 循环

---

## 二、对比：我们已有什么、缺什么

### 记忆宫殿已有的地基（大部分不用重造）

| DeepTutor 的件 | 我们对应物 | 现状 |
|---|---|---|
| SM-2 类调度内核 | `Models/Vocab/SM2.swift` | ✅ 纯函数变体，头注释就写着"换 FSRS 只换这里"；还有题型阶梯（认读→拼写→造句随成熟度爬坡，`SM2.exercise`）——DeepTutor 没有题型阶梯 |
| AI 判分 | Vocab 复习「AI 静默判分，断网降自评」（NOW.md 07-08） | ✅ 已打磨过 |
| 题目卡片 + 暂停/恢复 | ask_user 问问题（08-04 收口）：工具循环暂停→选项卡→Q/A 落真实 user 泡 | ✅ 这就是 DeepTutor `mastery_quiz`+`ask_user` 的对应物，链路已通 |
| 引擎工具挂进对话 | `RecallTool.swift`（模型主动翻历史+记忆，每轮≤3 次熔断） | ✅ 工具化模式现成 |
| 导师人格 | Preset 插槽（酒馆式 PromptSlot 组装） | ✅ "导师"可以就是一个 preset |
| 状态注入 | 记忆模块双层注入（stable/volatile、2000 token 预算） | ✅ 学习状态摘要可以走同一条注入链 |
| 间隔重复 | 记忆模块 hot/warm/cold 衰减（`Memory.swift:200`） | 🟡 有衰减但那是"记忆保鲜"，不是"主动考核" |
| 学习状态面板 | 记忆管理面板 `MemoryPanelView` | ✅ 模式可复用 |

### 真缺的东西（DeepTutor 有、我们零）

1. **知识点地图**（LearningPath → Module → KnowledgePoint 三层结构）——我们没有"学的是什么"的建模
2. **掌握度门槛**（mastery score + gate）——记忆模块的衰减强度不是掌握度，没有"过没过线"概念
3. **pending question 状态机**（登记题目存答案→跨轮批改）——ask_user 是即时的，没有"出了题等下轮批"的持久化
4. **probe/test-out**（先探会没会再决定教不教）
5. **错误分类学**（错题本只有 vocab 的 wrongTop，没有结构化错误记录）

### 哲学差异（决定轻量版形态）

DeepTutor 是**导师驱动**：每轮 `mastery_status` 决定教什么，AI 是驾校教练，对话是教学的载体。
记忆宫殿是**陪伴驱动**：AI 记住你、你控制它怎么说话，对话本身就是目的。

**所以轻量版不该复刻导师 loop，而该把"掌握度"做成一层状态，挂在现有对话和复习界面上**——像记忆模块那样：引擎默默记账，AI 自然地带考，而不是每轮被引擎牵着走。

---

## 三、轻量学习模块方案（草案，待拍）

### 路线 A：导师 loop 复刻（重，不推荐第一步做）

完整照搬：9 个 mastery_* 工具 + 每轮 status 驱动 + 卡片绑定 + 导师 preset。体验最接近 DeepTutor，但等于在对话系统里再插一个 agent loop，与我们"陪伴优先"的调性冲突，工程量也大（估 1500+ 行 + 工具循环改造）。

### 路线 B：状态层 + 两个工具（轻，推荐）

**核心思想：引擎记账（纯函数），对话自然发生，考核复用已有 ask_user 链。**

**B1. 数据模型（SwiftData，~200 行）**
- `LearningPath`（名字/目标/来源对话或材料）→ `StudyModule`（有序）→ `KnowledgePoint`（四类型 memory/concept/procedure/design）
- `masteryLevels: [kpId: Double]`、`quizAttempts`、`pendingQuestion`（题面+答案+状态）、`sm2States: [kpId: SM2State]`
- 挂楼层（profileId predicate），和记忆模块同一套隔离

**B2. MasteryEngine 纯函数 enum（~150 行，直接移植）**
- `computeMastery(correctness: [Bool]) -> Double` —— 照抄 recency weights + confidence cap（40 行里最值的 20 行）
- `nextObjective(progress) -> NextStep` —— 简化版 gate-as-cursor：pending → due review → 第一个没过门的 kp
- 门槛：定量 0.9 / 定性导师判（先用 AI 判，同 vocab 静默判分链）
- 可测：和 SM2 一样的纯函数测试姿势

**B3. 复习调度：复用 SM2，不按类型分序列（0 新代码）**
DeepTutor 的分类型序列是它 SM-2 缺失的补偿；我们 SM2 的 ease/interval 自适应本来就覆盖这个。类型只影响**门槛**和**考法**（concept 考解释、memory 考默写），不影响调度。省一整个 scheduler。

**B4. 聊天集成：两个工具 + 一条注入**
- `study_quiz` 工具：登记题目（答案存 SwiftData，不过模型手——学 DeepTutor 最关键的一条）→ 复用 ask_user 暂停链呈现卡片 → 答完 `study_grade` 批改记账
- 注入：学习状态摘要（当前路径/进行中 kp/到期复习数/最近错题）走记忆模块同一条 stable 层注入，AI 聊天时自然知道"该考考她了"——这就实现了 NOW.md 里已有的「错词优先考她」模式（vocab_status 给 CC 桥那条链）的 app 内版
- **不做**每轮强制 status 调用；AI 想查有工具，不查也能靠注入感知

**B5. 学习地图 UI（最后做，可砍）**
复用记忆面板模式：路径列表 → 模块 → 知识点掌握度色块。v1 甚至可以不要 UI，纯对话驱动 + 记忆面板里加个 tab。

### 砍单（明确不做）

- ❌ RAG/知识库/材料解析 —— 知识点来源 v1 就是对话里 AI 提议 + 粟粟确认
- ❌ Book 编译、课程生成
- ❌ 错误四分类 LLM 诊断 —— 错题存原文+正解即可（vocab wrongTop 同款）
- ❌ learner override provenance —— v1 直接允许手动标"会了"，不分来源（DeepTutor 分来源是因为它有 dashboard 给别人看）
- ❌ 多 stage 状态机、lease/CAS —— 单用户本地
- ❌ probe 独立阶段 —— 并入"定量题第一次作答就是 probe"

### 规模估计

| 件 | 行数估 |
|---|---|
| SwiftData 模型 | ~200 |
| MasteryEngine + 测试 | ~150 + ~150 |
| 两个工具 + ask_user 链接线 | ~200 |
| 注入层 | ~80 |
| **v1 合计** | **~800（不含 UI）** |

对比 DeepTutor 同功能面 ~7000 行 + 整个 agent loop 依赖。

---

## 四、开放问题（等粟粟拍）

1. **路线确认**：B（状态层+两工具）还是先做个更小的 B0（只有数据模型+引擎+注入，工具都没有，纯靠 AI 在对话里自由考）？
2. **知识点从哪来**：v1 用「对话里 AI 提议建路径 + 粟粟确认」够不够？还是要支持从读书模块的书里生成？
3. **考核形态**：对话里随口考（轻）为主，还是也要一个独立复习页（Vocab 复习页那种）？
4. **硬门槛要不要**：DeepTutor 是不过门不推进（驾校式）；我们做成"门槛只影响展示和 AI 的教学建议，不锁死"是不是更合调性？
5. **挂哪**：新楼层类型？还是任何楼层都能开学习路径？

---

## 附：DeepTutor 关键文件索引（复核用）

- `deeptutor/learning/policy.py` — 心脏：门槛 + next_objective + map_summary
- `deeptutor/learning/mastery.py` — 40 行掌握度计算
- `deeptutor/learning/scheduler.py` — 分类型间隔重复
- `deeptutor/learning/models.py` — 全部数据模型（含 legacy 迁移映射，能看到他们简化前的 7-stage 设计）
- `deeptutor/learning/grading.py` — 确定性判分（选择题归一化比对/短答案 SequenceMatcher≥0.85/开放题关键词命中≥60%）
- `deeptutor/capabilities/mastery/loop.py` — ask_user 卡片绑定 + 答案提示 strip
- `deeptutor/capabilities/mastery/tools.py` — 9 个工具：status/quiz/grade/assess/skip_question/build/paths/switch/leave
- `deeptutor/capabilities/mastery/prompts/zh/system.md` — 19 行导师 prompt，值得全文读一遍
