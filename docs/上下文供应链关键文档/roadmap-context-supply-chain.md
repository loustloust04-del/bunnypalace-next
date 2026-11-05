# Roadmap: 上下文供应链批次路线图（体检 + 对标 收束）

> 2026-06-12 · 输入：`docs/research-supply-chain-checkup.md`（体检，master @ 1a402e1）+ `docs/research-paramecium-v2-obelisk.md`（对标）
> 性质：**规划，不实施**。本文档定批次顺序、边界、依赖、验收标准；每个非平凡批次动工前仍走项目三步流程（research → plan → implement），各批的 plan-{}.md 才是改动详单。
> ⚠️ DON'T IMPLEMENT YET — 等粟粟批注。
>
> **铁律：每个批次结束 = macOS+iOS 双端 BUILD SUCCEEDED + 现有行为不退化。** 实现手段全部沿用项目既有哲学：新行为一律开关化（默认值=现状）、新字段一律 optional（SwiftData 轻量迁移）、新工具纯增量、每刀独立 commit 可单独 revert。不存在"先破坏再修好"的批次。

---

## 〇、批次总览与依赖图

```
B0 验证债清收（不写功能代码）          🟡 大半（BP1/记忆树/摘要✅；BP4/M2/B16 待粟粟）
 │
 ├──▶ B1 recall 工具（pull 面收口）──▶ B3 目录式注入开关
 │        （B3 硬依赖 B1）              B1 ✅ 06-12   B3 ✅ 06-13
 │
 ├──▶ B2 提取器改造（quote 锚 + superseded + 写通道 NOOP）   ✅ 06-12
 │
 └──▶ B4 全局预算协调器（地基批，涉及面最广，靠后）          ⬅️ 当前位置（唯一剩余）
          （吃 B0 的 S1 验证结论；BP2/BP3 评估归它）

B5 MCP 记忆 Retriever research（纯文档，可穿插任意空隙）     ✅ 已批 A 先行，注入侧停车
插队：B27 组装顺序 P0（06-12 实锤，不在原规划内）            ✅ 06-12/13 收口
```

排序理由一句话：B0 先（不验证就盖楼是沙地）；B1 是两份报告共同指向的同一刀且解锁 B3；B2 独立不阻塞人；B4 触面最广，等功能刀做完、测试网和 S1 工具都在再动；B5 不动代码随时插。

---

## B0 · 验证债清收 + 文档对账（不写功能代码，~1 天，粟粟主导我配合）

**为什么第一**：刀3/刀4 的缓存收益、M2 召回质量至今是"已实现未验证"。后续 B1/B3/B4 全部建在这些机制上，先确认地基没裂。

**内容**：
1. 三项行为手测（review-memory-tree-v1 遗留）：
   - 对模型说"看看你的记忆树" → 是否主动 fs_list/fs_read（提示词引导有效性）
   - fs_write 一个文件后下一轮 → 前缀分歧探针报告 **BP1 无分歧**（刀3 核心验收）
   - >40 条对话连发 3 轮 → 缓存仪表盘 cache_read > 0；压缩轮一次 miss 后恢复（刀4 核心验收）
2. M2 向量召回质量日用实测（M3 解冻的 gate；顺手把"paramecium 二次退役图谱"记进 M3 评审材料）
3. B16 连发手测（遗留）
4. **PROJECT_ROADMAP 块 0 重写**：S3/S4/B21 状态修正、记忆树 v1 主线补录、本路线图 B0-B5 替换旧 sprint 表（纯文档，零风险）

**可编译保证**：不动源代码，天然满足。
**验收**：三项手测有结论记录（通过/不通过+证据截图或日志）；roadmap 块 0 与现实一致。
**失败分支**：若 BP1/BP4 验收不通过 → 在 B1 之前插入修复刀（按探针指出的分歧点修），不带病前进。

**进展（2026-06-13 对账）**：块 0 重写 ✅；记忆树引导 ✅ / BP1 缓存 ✅ / 摘要质量勉强 ✅（三连问题已转 B2 刀4 修掉）——见 review-recall-tool 第五节。**剩余：BP4 长对话缓存 / M2 召回质量（M3 解冻 gate）/ B16 连发手测**，三项都在粟粟手里，是 B4 动工的前置。

---

## B1 · recall 工具 — pull 面收口（先 research+plan，实施 ~2 天）

**目标**：模型获得"主动回忆"能力——查自己的对话历史（L0 原文）+ 记忆库（L1），对标 paramecium recall + obelisk search/context 二段式。体检缺口 #1。

**先行文档**：`research-recall-tool.md`（SearchService 现状能力盘点 + 工具 schema 设计）→ `plan-recall-tool.md`。设计已在对标文档第五节具象化，research 重点只剩两件：SearchService 的谓词能力边界（20 万 node 红线下能不能做窗口上下文）、recall 与 fs_search 的职责边界（文件 vs 历史，描述写清防模型混用）。

**刀序（每刀独立 commit + revert）**：
1. **刀1 L0 原文检索**：新工具 `recall`（✅ 已批命名：给模型的语义暗示是"想起来"不是"查数据库"）——参数 `query / exact / after / before / conversation_id`。复用 SearchService，**profileId 谓词 + predicate 层过滤**（禁全量 fetch 红线）。命中带前后窗口上下文 + conversationId（可二段深挖，≈ obelisk search→context）。防刷屏三件套：相关性排序截断 / 每对话上限 2 窗 / 单结果截断（obelisk 10k 纪律，我们按字数定常数）。**空结果不兜底**——查无此事就说查无此事。
2. **刀2 L1 记忆并查**：同一工具内双层返回，记忆命中走 M2 管道现成检索器，结果分段标来源（`[日期 · 记忆]` vs `[日期 · 原文 conv:xxx]`）。
3. **刀3 access 语义修正**：`recordAccess` 从"进 hot 候选池就 +1"（CV:1368）改为"recall 命中才 +1"。⚠️ 顺序锁：此刀必须在刀1/刀2 之后——先关注入侧 +1 而 recall 不存在，衰减引擎的强化信号会断粮。
4. **刀4 暴露与可见**：工具 hint 一句话（固定文本保前缀稳定）+ S1 检查器显示 recall 调用与结果。

**开关**：挂独立开关 `recall_enabled`（默认开，纯增量工具不改任何现有注入；若粟粟要保守可默认关，批注定）。
**不退化保证**：纯增量——不动 push 管道、不动现有注入；刀3 是唯一行为改动，且只影响 accessCount 增长速率（衰减引擎读数变化是设计意图，S1 可观察）。
**验收**：build 双端；对模型问"我上个月说过 XX 吗" → recall 调用 → 原话带出处返回；20 万 node 库实测响应时间可接受；S1 看到完整调用链；XCTest 补谓词/截断/空结果用例。
**协调**：动 CV 工具分发段 + MemoryService——不碰 PromptAssembler 注入口，与 assembly-message-stream plan 无重叠。

---

## B2 · 提取器改造 — quote 锚 + superseded + 写通道 contract（~1.5 天）

**目标**：让转述可验证（指得回原话）、让遗忘可逆（不变形条件的提取侧落地）。对标文档第五节 3/4 + 体检缺口 #5。

**刀序**：
1. **刀1 quote 锚字段**：Memory 加 `sourceQuote: String?` + `sourceNodeId: String?`（双 optional，轻量迁移，旧记忆为 nil 不受影响）。
2. **刀2 提取校验**：提取 prompt 要求每条附 10-40 字逐字引用；解析后机械校验（norm 去空白 → ≥8 字 → `contains` 原文，不过整条扔；hard cap slice 不信 prompt——paramecium extract-memories.mjs:199-218 同款）。**只对新提取生效**，旧记忆照常参与检索。副产物：杀提取侧回声，与现有结构隔离叠加。
3. **刀3 superseded 软失效**：Memory 加 `supersededById: UUID?`（optional）。AUDN 的 delete 动作改为标记 superseded——出排名（检索管道过滤）不出库；用户手动钉住（isUserExplicit）的不可被失效。开关 `mem_supersede_soft` **默认开**（✅ 已批：可逆优于不可逆），记忆面板显示"已失效"灰条供复活；关开关=回 delete 现状行为。
4. **刀4 写通道 contract**：提取 prompt 加规则"对话内容明显在编辑文件库文件时输出 NOOP"（拓扑 C 草案第 2 条，掐断文件↔记忆双写）。顺手带上 B0 手测发现的**系统噪音过滤**（粟粟 06-12：走错管道等系统报错被当剧情事件记录、哄人话被当正式决策——提取/摘要 prompt 加"系统故障与安抚性表态不入记忆"规则，复盘见 review-recall-tool 第五节）。
5. **刀5 出处可见**：记忆面板记忆详情显示 sourceQuote + 跳转源对话（有 sourceNodeId 时）。

**不退化保证**：全部字段 optional；校验只拦新增提取；superseded 开关关闭时行为=现状 delete。
**验收**：build 双端；新提取的记忆带 quote 且能跳回原话；伪造 quote 的提取被机械拦截（单测）；矛盾场景旧记忆变灰而非消失；XCTest 补校验/过滤用例。
**协调**：动 MemoryExtractor + MemoryService 过滤 + Memory model——不碰组装链。

---

## B3 · 目录式注入开关 — push 减肥（依赖 B1，~1 天）

**目标**：可选的"~150 token 目录模式"：命中记忆只注入一行式目录，细节模型自己 recall。对长记忆库是数量级省 token + BP 减负。**硬依赖 B1**：recall 不存在时目录是断头路，模型看见标题却拿不到内容=功能退化,所以此批永远排 B1 后。

**内容**：
1. 开关 `mem_inject_catalog`（**默认关** = 现状全文注入，零退化）。
2. 开启时：**volatile 命中层**（BM25/向量/兜底命中）从全文换目录行 `- [日期 分类] 60 字内摘要`；**stable 常驻层保持全文**（对齐 paramecium：L2 画像全文 + L1 目录——常驻层是人格地基不能瘦）。cacheFriendly 下沉结构不变，只是下沉的内容变薄。
3. 目录尾固定一句："想看细节用 recall 工具"（固定文本）。
4. S1 检查器标注目录模式 + 显示省下的 token 估算。

**不退化保证**：开关默认关；开启后若模型不主动 recall 导致质量降 → 关开关秒回全文模式（与刀3 fileLibraryFullContent 同款对冲思路）。
**验收**：build 双端；S1 对比开关前后注入体积；开目录模式实聊——模型见目录后 recall 率观察（日用一周，质量主观评估归粟粟）。
**协调**：动 MemoryInjector.buildInjectionSplit 输出格式 + PA 记忆槽段——**与 assembly-message-stream plan 相邻，动工前对行段**（同体检协调注记惯例）。

---

## B4 · 全局预算协调器 — 地基批（先 research+plan，实施 ~2-3 天）

**目标**：拓扑打架点 B 清账——"没有任何一层知道总和是多少"。四块功能共同地基，M8（上下文总结完整版）前置。放最后因为触面最广（PA/世界书/记忆/文件库/S1），需要 B0 验证结论 + 既有测试网兜底。

**先行文档**：`research-budget-coordinator.md` + plan（含与 S1 检查器、ContextSummarizer 的接口设计）。

**预计刀序**（research 后可能调整，这里定边界）：
1. **刀1 估算口径统一**：三套 token 估算（Memory CJK×2 / TokenEstimator×1 / PostProcessor×1.5）收敛为一个 TokenEstimator 单一真源。⚠️ 退化风险点：记忆预算语义会变（同样 2000 预算装的条数变化）——S1 前后对照，必要时换算默认值保持有效容量不变。
2. **刀2 申报制协调器**：各源（历史/记忆/世界书/文件库 hint/摘要/画像/日记）组装时申报用量 → 超总预算按优先级裁剪（历史 > 记忆 > 世界书 > 文件库）。**默认总预算=无限（行为=现状）**，设了值才生效——开关化保零退化。
3. **刀3 世界书预算闸**：命中条目按优先级进预算（现状无闸全注是唯一无保护源）。
4. **刀4 PT1 决案**：PromptPostProcessor 死代码**删除**（✅ 已批）——协调器替代其本来使命，414 行死代码清掉；git 历史就是 attic，要复活随时翻得回。连带清掉 S1 设置页的 squash/postProcess 幽灵 UI（有 UI 无执行的 S1 遗留项一并收尾）。
5. **刀5 S1 占比条**：各源 token 占比可视化。
6. **刀6 BP2/BP3 评估**：~~research 时评估 OR 多断点透传行为~~ → **✅ 透传实验完成（06-13）：OR→Anthropic 官方多块断点完全透传且分段命中**（重发 99.96% read / 只改末块时前块保命中，省 63%）。刀6 升级为 GO 可做：BP2=画像/日记/时间轴天级段、BP3=摘要（现状摘要在 system 大段中间，每次压缩毁整段 BP1——拆块后只 miss 摘要块）。实施时与刀2 申报制同批设计 system 分块结构。
7. **观察项（不承诺）**：onComplete 5 个后台任务的预算窗口协调（拓扑 D 恶化中）——research 一并盘点，是否立刀等 research 结论。

**不退化保证**：协调器默认旁路（无限预算）；每刀独立 commit；估算口径统一是唯一默认行为变化，用 S1 对照验收。
**验收**：build 双端；S1 显示各源申报与裁剪结果；超预算场景裁剪顺序正确（XCTest）；默认配置下注入结果与改前逐字一致（前缀分歧探针）。

**research 必须吃的新输入（B1-B3/B27 落地后追加，2026-06-13）**：
- **计费口径先例**：B3 目录模式下"渲染行 token ≠ Memory.tokenCount"（差 3-8 倍）——各源申报量必须按**实际渲染行**算，不能按模型对象字段合计（review-catalog-injection 第二节）。
- **世界书现在有三个注入口**：插槽 case（before/after 桶，B27 刀3）、后处理段（examples/atDepth/AN + 兜底）、cacheFriendly volatile 下沉——刀3 的预算闸要罩全三处（review-B27 第二节）。
- **B27 后组装链结构已变**：世界书预扫描在 slot loop 前、marker 链中段多 worldInfo case——刀2 申报点设计以现行 PromptAssembler 为准，别按旧行号。

---

## B5 · MCP 记忆 Retriever research（纯文档，穿插，0 代码）

**目标**：粟粟"mcp 往前提"想法立项——MCP 记忆 server 作为 Retriever 进 M1 融合管道（注入侧）+ 可选提取 sink（写侧），而非只当工具。产出 `research-mcp-memory-retriever.md`，含：
- Retriever 协议适配设计（M1 留的口）+ 超时/降级（不能让外部 server 拖死组装——参考 paramecium 注入 5s 超时返回空）
- **前置问题**：MCP 全局生效 vs 记忆/世界书/文件库按 profileId 隔离的对不齐(拓扑 C 附带发现)
- 顺手补：MCP 工具列表 last-known-good 细节（部分 server 失败时保留上次全量,防 cache bust——对标第五节 6）

**实施不在本路线图承诺内**，research 批注后单独立批。

**结局（2026-06-13 已批收口）**：research + 实施 plan 两轮批注后粟粟拍板 **A 先行**——kiwi-mem 当普通 MCP 挂（pull 工具模式 0 开发），Retriever 注入侧（push"自动在场"）**停车待日用验证**（看模型调用率 + 背景记忆不自动在场烦不烦，结论定开工/退役，plan-mcp-memory-retriever.md 保留）。落地副产物：防缩守卫提前修掉（6fd45d1）+ kiwi 部署上线（硅基流动 + bge-m3，挂 `/memory/mcp` 6 工具）+ 顺手抓出 StreamableHTTP 的 CRLF 单 grapheme 解析 bug（ed71ca2，curl 通 app 超时的根因）。

---

## 停车场（本路线图不做，防忘）

- **记忆树 v2 自编辑**：参考答案已有（obelisk 闸门：提议→批准→写文件→注册链回原文），等 v1 日用验证后解冻。**06-13 施工图已备**：闸门实物三纪律（写读分离运行时/path 先存在/summary 自含）见对标文档第七节；提示词层的"提议→批准"已先行落进 recall 描述
- **M3 解冻评审**：材料齐（M2 质量数据 + paramecium 二次退役反面证据），B0 后粟粟定
- **plan-assembly-message-stream**：独立线，待批注；与 B3/B4 都动 PA——**先批注的先动，后动者 rebase 对行段**。⚠️ 06-13 更新：B27 已先行落地，该 plan 的"不改世界书"前提作废，**批注前必须先 rebase 到 B27 后的组装链结构**（T2 对齐预扫描分桶 + 插槽 case）
- 网关定时帧 / 记忆树 iCloud 同步 / timeline v2b moment 管道：维持停车

---

## 预估与节奏

| 批次 | 规模 | 前置 | 预估 | 实际 |
|------|------|------|------|------|
| B0 | 手测+文档 | — | 1 天（粟粟主导） | 🟡 大半（BP4/M2/B16 余） |
| B1 | research+plan+4 刀 | B0 | 2.5 天 | ✅ 06-12 |
| B2 | 5 刀 | 无硬前置 | 1.5 天 | ✅ 06-12 |
| B3 | 1 开关+格式 | **B1** | 1 天 | ✅ 06-13 |
| B4 | research+plan+5-6 刀 | B0（建议 B1-B3 后） | 3 天 | ⬅️ 唯一剩余 |
| B5 | 纯 research | — | 0.5 天，穿插 | ✅ 06-13 拍板 A，注入侧停车 |
| B27 插队 | research+plan+6 刀 | —（P0 实锤） | — | ✅ 06-12/13 |

总计 ~9.5 天。每批结束：build 双端通过 + 该批验收清单全勾 + commit/push + review-{批次}.md 复盘后才进下批。
实际节奏（06-12~13 两天）：B1/B2/B3/B5/B27 全落地——批注循环当天往返是主因；剩 B4 等 B0 手测残项。

## Checklist 总览（执行追踪器）

- [ ] B0 验证债清收 + roadmap 块 0 重写（块 0 重写 ✅；BP1/记忆树/摘要手测 ✅ 06-12；**剩 BP4 / M2 质量 / B16 待粟粟——B4 的 gate**）
- [x] B1 recall 工具（2026-06-12 四刀全落地 + 15 测试，见 review-recall-tool.md；运行时手测待粟粟）
- [x] B2 提取器改造（2026-06-12 五刀全落地 + 12 测试，见 review-extractor-quote-supersede.md；运行时手测 + 拦截率一周观察待粟粟）
- [x] B3 目录式注入开关（2026-06-13 三刀落地 + 10 测试，见 review-catalog-injection.md；toggle 默认关，开了之后的 recall 率观察归粟粟）
- [ ] B4 全局预算协调器 — 🟡 紧急冲刺半程（06-13）：刀4 PT1删 ✅ + 刀3 世界书闸 ✅（wb_inject_budget 默认0=无限）；刀1 口径统一/刀2 申报制/刀5 S1占比/刀6 BP2-BP3 留（需 B0 残项手测 + 粟粟在场对照，见 handoff-supply-chain-2026-06-13-emergency.md）
- [x] B27 组装顺序 P0（插队，2026-06-12/13 收口）：Bug A 关闭 marker 仍注入 + Bug B 世界书接管插槽 + UI 解锁，复盘 review-B27.md；真机验收待粟粟
- [x] B5 MCP 记忆 Retriever research + plan（research/plan-mcp-memory-retriever.md）— 批注轮2 拍板 **A 先行**：kiwi 当普通 MCP 挂日用（pull 工具模式，0 开发），Retriever 注入侧（push）**停车待验证**——日用看模型调用率 + 背景记忆不自动在场烦不烦，结论定开工/退役。防缩守卫已落地 6fd45d1

---

⧫ 批注记录（2026-06-12 已批）：
1. superseded **默认开** ✅
2. PT1 死代码**删** ✅
3. 工具命名 **recall** ✅
4. 批次顺序没毛病 ✅

~~路线图定稿。等粟粟说 GO 开工。~~

**当前状态（2026-06-13）**：sprint 进入收官位——B1/B2/B3/B5/B27 全落地，**只剩 B4**。B4 动工前置：粟粟补完 B0 残项手测（BP4 长对话缓存 / M2 召回质量 / B16 连发）。运行时验收清单全部汇总在 `docs/粟粟的批注验收队列-2026-06-13.md`。
