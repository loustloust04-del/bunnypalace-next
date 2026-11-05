# Research: Paramecium v2 + Obelisk 对标 — 上下文供应链第二轮外部对比

> 2026-06-12 · 对比对象：`/Users/susu/Downloads/paramecium-main 2`（大改版）+ `/Users/susu/Downloads/obelisk-main`（新选手）
> 方法：两份 README 本人通读 + 双 Explore agent 深读代码 + 承重结论行号抽查亲核（排名公式 memory-gateway.py:437-451 / attic 注释 :19-22 / quote 校验 extract-memories.mjs:199-218 均核对原文）
> 我方基线：`docs/research-supply-chain-checkup.md`（昨天的体检，master @ 1a402e1）
> 前一轮对标：`docs/roadmap-memory-system.md` 第一节（对的是 paramecium **v1**）
> ⧫ 体检性质，等粟粟批注定落点。

---

## 〇、一句话结论

**Paramecium v2 把哲学推倒重来了（「忠于原文」三层记忆），Obelisk 把「模型查自己的历史」做成了成品——两家的重心都压在 pull 侧，正好砸在我们体检报告说"缺一条腿"的地方。** 同时她退役了一批我们刚抄完作业的机制（图谱出排名、tier、importance），而我们的开关哲学恰好免疫这种反复：她删机制，我们关开关。

---

## 一、Paramecium v1 → v2：她自己推翻了什么（对我们 roadmap 的回响）

上一轮我们对标 v1 抄了向量/BM25/图谱/cache 的作业。v2 的自我推翻清单（memory-gateway.py:19-22 cleanup 注释，亲核）：

| v1 机制 | v2 处置 | 我们的状态 | 含义 |
|---------|---------|-----------|------|
| 热度衰减 | 早删（v1 已删） | M8 做成开关 ✅ | 哲学吻合，开关让用户自己试 |
| **关系图谱注入** | **edges 冻结出排名/注入**（"edges frozen out of ranking"，:436 注释），数据保留可查 | **M3 刚做完**（一跳扩展，开关默认关） | 她两进两出都放弃了；我们开关默认关 = 风险已对冲，但 M3 解冻前多一个反面证据 |
| 情绪打分 polarity | 冻结出排名 | 没做（原案：等 tag 层） | 维持不做 ✓ |
| importance / 自动分层 tier / 相似性聚类 | 全部冻结 | 没做 | 维持不做 ✓ |
| 记忆条目 = 唯一载体 | **被「忠于原文」推翻**（见下） | AUDN 改写式（同 v1 思路） | ⚡ 本轮最大冲击，见第四节 |

她的退役方法论值得记一笔：**冻结不删除**——代码进 attic/、DB 列保留、数据不动，"拆东西之前先拿日志证明它没用"。和我们的开关哲学是同一族答案（她是开发者侧冻结，我们是用户侧开关）。

## 二、Paramecium v2 新立的东西（核心五件）

1. **L0 原文层**：全部聊天逐字存档，纯机械切窗（句界切 ≤350 字段 → 贪心打包 ≤700 字窗 + 1 段重叠，说话人/日期烤进窗口文本，archive-import.mjs:26-27,52-105）→ bge 向量 + FTS5。零 AI 零改写，"向量是门牌号，门后面是原话"。
2. **L1 摘录层带逐字引用锚**：便宜模型圈信息点（≤5 条/批），每条必须附 10-40 字**逐字 quote**，机械校验 quote 真在原文里（去空白后 includes，≥8 字），不过就整条扔（extract-memories.mjs:199-218）。注释原话：**"杀 hallucination 和大部分 memory-echo——旧事的复述在当前批次里没有字面出处"**。
3. **目录式注入 + recall 工具**：每轮只注入 ~150 token 的 L1 目录（`- [日期 分类] 60字摘要…` 一行一条），全文不进 push；模型想要细节自己调 recall（参数 query/exact/after/before/conv_id），L1+L0 双层并查，相关性地板 max_distance=0.55、每场对话最多 2 窗、archive 命中带 conv_id 可继续深挖。**access_count 只在 recall 时 +1——"被列进目录不算被回忆"**（inject 走 log_access=False，memory-gateway.py:463-496）。
4. **superseded 软失效**：新旧记忆矛盾（DS V3 判 contradicts/updates 且 conf≥0.75）→ 旧条目标 superseded_by，**退出排名但不删除**，可复活；pinned 神圣不可侵犯（extract-memories.mjs:237-265）。
5. **排名公式收敛成三因子**：`RRF(向量0.7+BM25 0.3, K=60) × (0.7+0.3·e^(-天/60)) × (1+0.05·ln(1+access)) × 有效期`（memory-gateway.py:437-451，亲核）。

防护杂项（小而硬）：注入 5s 超时返回空不阻塞聊天 / MCP 部分宕机用 last-known-good 工具列表防 cache bust / 图片先落盘存败即不压缩 / BM25 索引 5 分钟缓存 + 线程安全原子换 / 写时去重 sim>0.75 合并。压缩：60K token 触发、保留末 8 条 relay、锚点 cycleStart 推进、原始消息一条不删、摘要进 BP3。保温缓存教训："感觉在省钱"不算省钱，日志说了算（前缀字节对不上，拆了）。

## 三、Obelisk：「模型查自己的历史」的成品参考

CC skill：把 session JSONL（含 subagent/workflow/tool call）索引进 SQLite+FTS5（Node 内置，零依赖 ~400 行），**agent 自己写 JS 查询**（CodeAct），不发明查询 DSL。口号："Humans should not browse session history. Agents should query it."

对我们 search_history 设计最有用的部件（细节见 agent 提取，已存档于本文档撰写过程）：

- **三原语 + helper 面**：`search(text)`（FTS5，返回命中 + 同 session 时间邻居 context）→ `context(uuid)`（parent chain 因果链 + session/subagent/workflow 元数据）→ `sql()`（只读兜底）。外加 17 个 structured shortcuts（sessions/summaries/fileHistory/failures/workflowTree…）。**Helper first，raw SQL 最后**。
- **紧凑纪律**：索引时一律截断 10k 字；helper 返回投影字段不返回整行；synthesis 输出目标 <12k 字；"Counting 在 SQL 里做，不从 snippet 数"。
- **增量索引**：per 文件 mtime + lines_processed（append-only 假设），30s 防抖，WAL 模式读写不互堵。
- **只读闸**：query 脚本 sql() 只接受 SELECT/WITH（正则双重拒绝写操作）；写记忆走单独的 --remember runtime，只暴露 remember()。
- **记忆注册 = 人批准的结论**：检索产生可复用结论 → agent 提议 → **用户批准** → 写 markdown → remember() 注册（带 session_id + message_start/end 链回原文）。这是「检索 → 推理 → 批准 → 落档」的闸门设计，正好是我们记忆树 v2「AI 受控写」停车场项的参考答案。
- **Progressive disclosure**：主 prompt 只放契约+高危 pitfall，schema/recipe/陷阱放 references 按需读——和我们 MetaTools defer 同思路，但做得更体系。
- **空结果不兜底**：scoped 问题空数组是正确答案，禁止自动放宽——防"硬找一个不相干结果"。

不适用项：英文记忆层约束（我们中文产品）、agent 写任意 JS（app 内不给模型 CodeAct，工具面要收窄成参数化 API）。

## 四、哲学冲击：「忠于原文」打在我们 AUDN 的脸上吗？

她的开篇就是对我们这类系统的指控："让**转述**永久地代替了**真相**——三年后你搜到的不是你说过的话，而是某个旧版本小模型对你说的话的复述。"

逐层对一下，我们没那么惨，但有真伤：

| 层 | Paramecium v2 | 我们 | 判定 |
|----|---------------|------|------|
| 原文存档 | L0 档案（JSON 文件 + 切窗向量 + FTS5） | **SwiftData 20 万+ MessageNode，本来就一条不删** | 我们天生有 L0 的"存"，缺的是"检索面"——SearchService 只给人用（体检缺口 #1） |
| 摘录层 | L1 带逐字 quote 锚，机械校验 | AUDN 原子事实，有 `sourceConversationId`（对话级）但**无 quote、无消息级锚**（Memory.swift:28，亲核） | 真伤：我们的记忆条目无法"指回原话"，模型和用户都没法验证转述对不对 |
| 矛盾处理 | superseded 软失效可复活 | AUDN delete 硬删 | 真伤（小）：删了就没了，她的可逆 |
| 回声环 | quote 机械校验杀 memory-echo（复述无字面出处） | 结构隔离（提取窗口只吃原始消息，工具历史压成动作行）+ S3 字面去重 | 同一问题两种解法，我们的防注入侧、她的防提取侧——**可以叠加** |
| 强化信号 | 只有 recall 才 +1（"翻目录不算想起来"） | `recordAccess` 对整个 hot 候选池每轮 +1（CV:1368） | 我们的 access 信号被注入通胀，几乎没有区分度 |
| 摘要地位 | "省钱的默认视图"，原文兜底 | 同（锚定窗口 + 原文在库） | 已对齐 ✓ |
| 图片 | 原图先落盘，存败不压缩 | M7 同款（3 条前旧图换描述，原图保留兜底，CV:1577） | 已对齐 ✓ |

**结论**：「忠于原文」对我们不是推翻而是补全——我们的原文底座比她厚（结构化 SwiftData vs JSON 文件），但在"模型能摸到原文"这件事上是 0：push 全是转述（记忆/摘要/画像/日记），pull 只有文件库。她证明了 L0 检索面 + quote 锚是让转述系统"可验证"的两根钉子。

## 五、可抄清单（按体检缺口对位，含具体参数）

1. **search_history 升级为「recall」设计**（体检缺口 #1 的具象化，两家合参）：
   - 双层并查：L1=Memory 库语义检索（M2 管道现成）+ L0=对话原文检索（SearchService + 滑动窗上下文）。结果分段标来源，原文命中带 conversationId 可深挖（≈ obelisk 的 search→context 二段式）。
   - 参数面照抄 recall：`query / exact(逐字) / after / before / conversation_id`。
   - 防刷屏三件套：相关性地板（她 0.55 距离阈值）/ 每场对话上限 2 窗 / 结果截断（obelisk 10k 纪律）。
   - access 语义顺手修正：注入候选池不 +1，recall 命中才 +1（一行改动，让强化信号恢复区分度）。
   - 空结果不兜底（obelisk pitfall #4）。
2. **目录式注入开关**（push 减肥，配合 recall 成对出现）：现在 2000 token 全文注入 → 可选 "~150 token 目录模式"（`- [日期 分类] 一行摘要`），细节让模型 recall。对长用户记忆库是数量级省钱 + 给 BP1 减负。做成开关（`mem_inject_catalog`），不替用户选。
3. **L1 quote 锚**：提取 prompt 要求每条记忆附 10-40 字逐字引用 + 机械校验（norm 去空白 includes，≥8 字，不过整条扔，hard cap slice 不信 prompt）。给 Memory 加 `sourceQuote` + `sourceNodeId` 字段。副产物：杀提取侧回声（和我们的结构隔离叠加）+ 记忆面板可显示出处原文。
4. **superseded 软失效**：AUDN 的 delete 动作改为（或开关化为）标记 superseded——出排名不出库，用户手动钉住的不可失效。和"冻结不删除"哲学一致。
5. **记忆树 v2 自编辑的闸门**（停车场项的参考答案）：照 obelisk 的「agent 提议 → 用户批准 → 写文件 → 注册（链回 source 对话/消息）」流程，写闸在 runtime 层硬隔离（只读查询 vs 只写注册），不靠 prompt 自觉。
6. **小防护**：MCP last-known-good 工具列表（部分宕机不缩列表防 cache bust——我们有缓存列表，但"部分失败保留上次全量"这个细节可补）；BM25 索引若将来变慢可抄 5 分钟缓存 + 原子换。

## 六、不抄 / 我们已领先的

- **网关双进程 + cron 工人** — 我们进程内组装 + onComplete 触发，原生 app 优势不变。
- **她的压缩粒度**：60K token 才压、保留 8 条 relay —— 我们的滞后压缩 + 锚定窗口 + 三种失效保护更细，且有 26 个测试用例兜着；两家锚点思想相同。
- **BP2 日锚定** — 我们 M6 时间轴插槽（天级稳定进前缀）已是同款。
- **开关面板 / 楼层隔离 / S1 检查器（所见即所发）/ 预览=实发铁律** — 两家都没有，仍是我们核心差异化。
- **她的 token 估算**（CJK=1/ASCII=0.25）也是单一口径——反衬我们三套口径并存（体检缺口 #2）该收敛了，但抄谁的常数不重要，统一才重要。
- obelisk 的 agent 写任意 JS / 英文记忆约束 — 不适用。
- **保温缓存验尸教训** — 我们的前缀分歧探针 + 缓存仪表盘已是同一信仰（"日志说了算"），互相印证不用动。

## 七、建议落点（⧫ 等粟粟批注）

体检报告的下一步排序基本不变，但内容被这轮对标加厚了：

1. **search_history 立项升格为「recall 工具」research+plan**（缺口 #1）——直接按第五节 1 的参数面设计，L0 用 SearchService 复用（20 万 node 红线照守），L1 用 M2 管道复用。这是两家外部项目共同指向的同一刀。
2. **目录式注入开关**挂在 recall 之后做（没有 pull 的目录是断头路；有了 recall，目录才敢瘦）。
3. **quote 锚 + superseded** 作为 AUDN 提取器改造一刀（独立可 revert，不动检索管道）。
4. M3 解冻评审时把"paramecium 二次退役图谱"记为反面证据（开关默认关已对冲，不急）。
5. 记忆树 v2 自编辑继续停车，但参考答案已有（obelisk 闸门流程），解冻时拿来即用。

⧫ DON'T IMPLEMENT YET。

---

## 七、obelisk 本体深读补遗（2026-06-13 · ~/Downloads/obelisk-main 逐行）

> 第三节当时靠 agent 提取二手细节；本节是 repo 本体（SKILL.md 292 行 + scripts 956 行 + references×4）亲读增量。
> 对照对象：供应链 sprint 收官位的我们（recall ✅ / quote 锚 ✅ / supersede ✅ / 目录模式 ✅）。

### 已对齐不用动（sprint 已落地）

search→context 二段式 ≈ recall conv 前缀二跳；"空 scoped 结果是有效结果" ≈ 查无此事就说查无此事；memories+search 双层并查 ≈ recall L1+L0；10k 截断纪律 ≈ 防刷屏三件套；Progressive disclosure ≈ MetaTools defer。

### 新看到可抄的（按价值排）

1. **检索契约七条**（SKILL.md Retrieval Contract）：Scope First / Orient First / Helper First / Plan Before Probe / Structure Before Text / **Evidence Before Conclusion**（紧凑证据带稳定 ID 再综合）/ Persist Durable Conclusions（值得留的结论**主动提议**存记忆，用户批准才写）。
   → **可执行小刀**：浓缩三句进 recall 工具描述（"有 conv_id 先用 conv_id 别广搜；引用带出处再下结论；记忆是先前笔记不是最终权威，要紧处与原文对照"）+ kiwi 楼层引导词同理。纯提示词改动。
2. **记忆注册闸门的实物细节**（记忆树 v2 停车场项的参考答案，比第三节当时记的细）：
   - **写读分离运行时**：`--remember` 模式只暴露 remember()，不暴露任何检索 helper；查 ID 必须先走普通 query。写通道窄面=误写面最小。
   - **path 必须先存在**：markdown 文件由 Write 工具落盘（用户批准环节天然在这），remember() 只做注册——注册器永不创建内容。
   - **summary 自含性**：必须详细到"只看 memories() 结果不读文件就能判相关性"——含决策+理由+约束，不是标题。
   - 注册记录 survive index rebuilds，永不自动删。
3. **message_start/end 区间锚**：记忆记"结论从哪段对话得出"的区间，不是单点。我们 SC-B2 的 sourceNodeId 是单点（quote 所在消息）；提取一条记忆常源自多轮——区间是增强候选（Memory 加 sourceNodeIdEnd? 不急，记录）。
4. **SQLite+FTS5 索引层**（indexer.mjs：per 文件 mtime + lines_processed 增量、append-only 假设、WAL 读写不互堵、索引文本一律截 10k）——**20 万 node recall 性能的 B 计划**：手测若慢（验收清单挂着的项），给 MessageNode 建 FTS 边车索引照抄这套增量纪律，不动 SwiftData 主库。
5. **references 双文档分工**：retrieval-semantics.md 是"设计 frame 先读"，pitfalls.md 是"错了才读的 debug checklist"——错误驱动 vs 设计驱动分开放。我们 CC 记忆文件已是这个味道；app 内给模型的工具引导将来多了也可这样分层。
6. **索引语言统一 + guardrail**：obelisk 记忆层英文索引、运行时直接拒绝 CJK 查询/摘要（防索引语言分裂）。我们中文对中文没这问题；但 kiwi embedding 查询语言与库内语言一致性同理（中文库中文查，已天然满足）。

### 结论

obelisk 对我们的剩余价值集中在两处：**记忆树 v2 解冻时抄闸门实物**（写读分离 + path 先存在 + summary 自含），**recall 慢时抄索引层**。检索契约三句是随时可做的提示词小刀。其余已在 sprint 中等效落地。

### 7.4 三处落地记录（2026-06-13 当天）

1. **检索契约 + 提议批准** ✅ 落进 recall 工具描述尾三句（窄定位优先/引用带出处·记忆非权威/durable 结论先问再存）。
2. **闸门机制**：提示词层先行（上条尾句）；机制层（写读分离/path 先存在/summary 自含 + 注册表）= 记忆树 v2 施工图，停车场指针已接本节。
3. **FTS 边车**：✅ **数据结案停车**——unified.store 25.2 万 node 真库只读实测（Mac CLI 冷态、immutable 全表 LIKE）：高频词"猫"1.8 万命中 count 0.98s / **全量 fetch 上界 1.23s** / 低频 0.60s / 不存在词 0.36s。recall 实际有 maxL0Windows=4 早停远好于上界。结论：纯谓词扫描在 25 万 node 量级秒内，索引层不立项；真机 Air 复核降级为顺手项（预计 2-4 倍仍在验收线内）。

---

## 八、paramecium 本体深读补遗（2026-06-13 · ~/Downloads/paramecium-main 2 逐行）

> 对照供应链收官位的我们，第二节五件套 + 防护杂项已全落地。本节是剩余没学完的——收敛为三项 + 一个意外发现。

### 8.1 BP2/BP3 多块缓存断点（没学完的最大金矿 → B4 刀6 的实证输入）

草履虫实现（gateway.mjs:247-275 亲读）：**system 不是一段，是 block 数组**，每块独立挂 `cache_control`（全部 ttl 1h）：
- BP1 人设+画像（几乎不变）/ BP2 日记备忘（**按日锚定**：`_diaryCacheDay` 守卫，日内 vault 写入不毁缓存）/ BP3 **只放压缩摘要**。
- 关键收益：**摘要更新只 miss BP3 之后，BP1/BP2 保住**。我们现状 contextSummary 插槽在 system 大段中间（order 55）——每次压缩毁整段 system 缓存。滞后压缩已把 miss 降到每 N 轮一次，多块断点能把"那一次 miss"的代价从全 system 缩到摘要块。实测 60-80% 命中率背书。
- ~~前提：OR 多块透传需实测~~ → **✅ 实验完成（2026-06-13，粟粟授权 key 实测）**：OR→Anthropic 官方，三块 system 各挂 cache_control，R2 相同重发 cached_read 17836/17844（99.96%，成本 1/12）；R3 只改第三块（模拟摘要更新）cached_read=12224 恰为前两块 token 数——**多块透传 + 分段命中双实锤**。摘要更新场景成本 $0.0223→$0.0082（省 63%）。Anthropic 上限 4 断点，我们 BP1+BP4 已占 2，剩 2 个正好给 BP2（画像/日记/时间轴天级段）+BP3（摘要）。
- → 落点：B4 刀6 评估从"不知可不可行"升级为"有实证参考，差 OR 透传一个实验"。

### 8.2 写时去重 sim>0.75 并入强化（✅ 已落地 2026-06-13 当天）

memory-gateway.py:676-697 亲读：新记忆入库前向量查 top3，相似度 >0.75 → **不开新条**，文本并入旧条（<2000 字拼接否则替换）+ 旧条 heat+0.1、access+1。语义：近似重复=同一事实再确认=强化信号，不是新知识。
我们现状：executeActions 只有 content **全等** Set 去重——"喜欢暖奶白"vs"用户偏好暖奶白色调"会重复入库。落点：add 前用现成 embedding 管道（M2 VectorRetriever 同源）查近似，>阈值改 reinforce 旧条。**已落地（粟粟"继续冲"授权）**：与草履虫的差异——我们不拼接文本（原子事实哲学），只 reinforce 旧条 + 旧条无锚时补 quote；外加两个体系特有护栏（delete 重排先行防新事实被吸收丢失 / 对照面排除 superseded+revision 失配）。本地 NLContextualEmbedding 同步算，未就绪静默跳过。5 测试。

### 8.3 L0 语义档案搜索（大件，方向已记录，停车）

archive-import.mjs：句界切 ≤350 字段 → 贪心打包 ≤700 字窗 + 1 段重叠，说话人/日期**烤进窗口文本**再向量化——模糊印象（"那次聊到很晚的谈话"）也能召回原文。我们 recall L0 是 contains 逐字，语义档案是 recall research 记过的"二期"。工程量：25 万 node 切窗向量化 + 增量管道，不动，方向保留。

### 8.4 意外发现：BP4 落点差异（候选嫌疑人，记录不动）

草履虫 gateway.mjs:396 注释：**"array-wrapping assistant msgs breaks thinking on some providers"**——实战把 BP4 从末 assistant 挪到**末 user**。我们 ChatService.swift:391-393 正是"末 assistant 包 array 挂标"模式。粟粟的 OR 缓存是日志实测调通的（feedback_openrouter_cache_zero_hit），未观察到 thinking 破坏——**没坏不修**。记录：将来 OR 上 thinking 模型若出现思考丢失/截断，第一嫌疑人是这里，修法=断点挪末 user（命中语义几乎等价）。

### 结论

草履虫剩余价值三件：**多块断点给 B4 刀6 当实证拐杖**（差一个 OR 透传实验）、**写时近似去重小刀等批**、**L0 语义档案停车**。加一个 thinking 嫌疑人档案。其余全部已在 sprint 等效落地——两个对标对象至此都榨干。
