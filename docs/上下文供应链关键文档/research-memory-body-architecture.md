# Research: 楼层连贯记忆体 — push/pull 双轨与记忆树收敛（⚁ 拓扑模式产物）

> 2026-06-11 · 回答粟粟三问：到底怎么改？要改架构吗？别的 AI 怎么搞上下文供应链？
> 目标语句：**每个楼层必须成为一个连贯记忆体**——含每日摘要/对话摘要（楼层级）、AI 可 grep 摘要、Mac 接网关。
> 前置文档：`docs/research-context-topology.md`（现状拓扑+打架点）。本文是目标态。
> 业界引用经 2026-06-11 检索验证（文末 Sources）；标"训练知识"的未二次检索。

---

## 一、因果骨架（5 句）

1. "连贯记忆体"的真正障碍不是缺机制，而是**记忆资产散在四种存储里、且只有 push 一条路**——记忆在 SwiftData、摘要在 UserDefaults、文件在 filesystem、历史在 store；模型只能吃组装管道喂的那一口，看不见全量。
2. push 管道（M1/M2 检索注入）解决"自动想起"，pull 工具（grep/搜索）解决"主动回忆"；业界已收敛为 **push 小核心 + pull 大外存 + 后台整理 + （可选）自编辑** 四件套，我们四缺二（pull 面残缺、后台整理没有）。
3. **最脆弱一环是摘要存储**：UserDefaults 里的摘要不可 grep、不可同步、不进检索管道、不进文件库——每日摘要/对话摘要做得越多，孤岛越大，下游全堵死。
4. 楼层目录 `floors/{slug}/` 已存在且有路径防护，是统一命名空间的天然载体——不需要新架构，需要把散件**收敛**进它。
5. 网关（Mac）是调度层不是功能层：重活（每日摘要/向量回填/GC）下沉 Mac 是优化；设备端必须独立能跑（「app 必须自包含」红线）。

**对"要改架构吗"的直接回答：不改骨架。** 组装管道、M1/M2 检索管道、楼层隔离、工具循环、cache 分层全部保留。要做的是一次**收敛与暴露**：①文档态记忆资产收敛进楼层记忆树 ②pull 面从"仅文件库"扩到"记忆树 + 历史搜索" ③后台整理任务化。全部用现有零件。

## 二、别的 AI 前/后端怎么搞（对照表）

| 系统 | push（注入侧） | pull（检索侧） | 后台整理 | 自编辑 | 对我们的启示 |
|------|--------------|---------------|---------|--------|------------|
| **Letta (MemGPT)** | Core memory blocks 常驻 in-context | Recall=可搜对话历史 + Archival=工具查档案库 | **sleep-time compute**：后台 agent 闲时重组记忆/合并/重写画像块 | core_memory_append/replace 工具 | 三层完全体范本；"每日摘要"= sleep-time 的同款 |
| **Claude memory tool（官方 API beta）** | 启动时检查记忆目录 | **`/memories` 文件目录**：view/create/str_replace/insert/delete，客户端落盘，模型原生受训文件操作 | 无（留给客户端） | ✅ 文件即记忆 | "AI grep 摘要"的官方背书：**文件系统就是记忆接口** |
| **ChatGPT memory**（训练知识） | saved memories（原子事实）+ 跨对话历史 RAG 注入 | 无显式工具（隐式 RAG） | 有（画像聚合） | bio 工具写入 | 双层：事实 + 历史引用；闭源不可控 |
| **mem0 / Zep**（训练知识） | 提取管道（类 AUDN）→ 向量/时序图谱 → 检索注入 | API 检索 | 图谱聚合/会话摘要 | ✗ | 与我们 M1/M2 同路线，我们已不落后 |
| **SillyTavern**（本地源码可查） | lorebook 关键词扫描 + summarize 扩展 + vector storage | ✗ 无工具 | ✗ | ✗ | 纯 push 的天花板就是酒馆——我们已对齐，再往上必须加 pull |
| **paramecium**（已有对比文档） | 向量+BM25+图谱检索注入 | admin 面板（人看，模型不可查） | 10min 轮询同步 | ✗ | 见 roadmap-memory-system 第一节 |
| **Claude Code / Cursor**（自身经验） | CLAUDE.md/规则文件启动注入 | **grep/read 全量代码库** | ✗ | auto-memory 写文件 | 纯 pull 在"资产=文件"时成立；我们文件库已是此形态 |

**收敛结论**：没有一家是纯 push。越接近"连贯记忆体"目标的系统（Letta、Claude memory tool），越是**小 push + 大 pull + 文件/块状记忆 + 后台整理**。我们 push 侧已是第一梯队（RRF 融合 + cache 分层是酒馆和多数客户端没有的），缺的是 pull 面和后台整理。

## 三、差距矩阵（楼层记忆资产盘点）

| 记忆资产 | 现存储 | push 可达 | pull 可达（模型能查） | 备注 |
|---------|--------|----------|---------------------|------|
| 原子记忆 | SwiftData | ✅ 检索管道 | ❌ | 衰减/向量需要结构化，留 SwiftData |
| 对话摘要 | **UserDefaults** | ✅ 整段注入 | ❌ | 🔴 最脆弱一环 |
| 每日摘要 | 不存在 | — | — | 未来功能，落点待定 ← 本文定 |
| 用户画像 | 不存在（M5） | — | — | 同上 |
| 文件库 | 文件 | ✅ hint 全文 | ✅ fs_* | 唯一双轨可达的资产 |
| 世界书 | SwiftData | ✅ 关键词扫描 | ❌ | 关键词机制即检索，暂不动 |
| 全量对话历史 | SwiftData | 窗口 40 条 | ❌ | **SearchService 很强但只给人用，模型搜不了自己的历史** |

## 四、目标架构：楼层记忆树

```
floors/{slug}/
├── filesystem/                  ← 现有文件库：AI 自由读写区（fs_*，不动）
└── memory/                      ← 新：楼层记忆树（系统生成，AI 只读 v1）
    ├── summaries/{convId前8}.md ← 对话摘要（从 UserDefaults 迁来；S3 落点）
    ├── daily/2026-06-11.md      ← 每日摘要（未来功能落点；Letta sleep-time 同款）
    └── profile.md               ← 用户画像（M5 落点）
```

五条原则：

1. **双真源分工**：SwiftData = 结构化资产真源（原子记忆/世界书/历史——衰减、向量、predicate 需要它）；文件 = 文档态资产真源（摘要/画像/每日——天生是文档，要 grep、要同步、要人手改）。**不做镜像双写**（双真源同步是债）。
2. **谁生成谁写入**：ContextSummarizer 写 `summaries/`，每日摘要 job 写 `daily/`，画像聚合写 `profile.md`。读取同样走文件（迁移后 UserDefaults 退役）。
3. **pull 统一面**：fs_list/fs_read/fs_search 的 scope 扩到 `memory/`（只读挂载，复用现有路径防护）→ "AI grep 到摘要"免费实现。再加一个 `search_history` 工具复用 SearchService（带 profileId 谓词，遵守"禁全量 fetch"红线）→ 模型获得 Letta 的 Recall memory，几乎零新代码。
4. **AI 对 memory/ v1 只读**：自编辑（Letta core_memory_replace / Claude memory tool 写操作）是 v2 决策，先防记忆树被模型写花。
5. **push 管道不变**：常驻记忆/命中记忆/当前对话摘要照旧注入；memory/ 树只是 pull 面 + 持久化面。push 给"该自动想起的"，pull 给"想主动回忆的"。

### push / pull 分工 contract

| 进 push（每轮注入） | 进 pull（模型按需查） |
|--------------------|---------------------|
| 常驻层记忆（画像类，BP1 内） | 旧对话摘要（其他对话的） |
| 本轮命中记忆（动态段下沉） | 每日摘要存量 |
| **当前对话**的摘要 | 全量历史（search_history） |
| 文件列表（不含全文，见拓扑文档 A1 修复） | 文件全文（fs_read） |
| 世界书命中 | 记忆树任意文件（fs_search/grep） |

**关键新连线（之前没意识到的）**：pull 的结果以 tool result 固化进对话历史，历史是 append-only——**天生缓存友好**；而 push 的动态段每轮变、必须下沉伪 user 才不打碎前缀。所以"向 pull 倾斜"不只是省 token，**本身就是缓存优化**。拓扑文档 A1（文件库全文从 system 撤下来）和本文方向是同一个箭头：把"大而易变"的内容从 push 搬到 pull。

## 五、摘要的层级管道（每日摘要怎么长出来）

```
单对话消息 ──S3压缩──▶ summaries/{conv}.md ──每日job聚合──▶ daily/{date}.md ──M5聚合──▶ profile.md
   (实时)              (对话级，超阈值触发)      (楼层级，跨对话)          (长期画像)
```

- 层级聚合 = "摘要的摘要"，正是 Memory.parentId 预留的思路，文件版实现更简单（每日 job 读 summaries/ 当日改动过的文件）。
- **边界声明（防自我污染回声环）**：AUDN 提取器的输入窗口**永不包含** memory/ 树内容——否则摘要被提取成记忆、记忆注入又进摘要，噪声逐轮放大。同理每日 job 只读对话摘要不读记忆库（各聚各的层）。
- 每日 job 触发：v1 = 打开 app 时补跑（昨日未结则结）；网关版 = Mac 定时跑。两者幂等（按日期文件存在性判断）。

## 六、网关（Mac）定位

- **角色**：调度层，不是功能层。任务清单：每日摘要、向量回填批跑、记忆 GC（cold 层清理）、未来大向量库。
- **红线**（既有教训「app 必须自包含」）：iOS 单机必须全功能可跑（用 cheapModel + 打开时补跑，慢但完整）；网关只是"谁来跑、跑得勤"的增强。
- **现成基建**：cc-bridge hub 已是 launchd 守护（RunAtLoad+KeepAlive+看门狗），加定时任务帧即可，不新起进程。
- **文件态记忆树是同步友好载体**：SwiftData 库不可同步（已有决策：同步只走 iCloud），而 memory/ 是纯文件——iCloud Documents 或 hub 帧同步都顺。**这是摘要文件化的第三个论据**（前两个：grep、人可读可改）。

## 七、迁移路径（不是大爆炸，5 步全部可独立 revert）

| 步 | 内容 | 规模 | 协调 |
|----|------|------|------|
| 1 | **摘要存储迁文件**：ContextSummarizer 读写改 `memory/summaries/`，UserDefaults 一次性迁移 | 小 | 🔴 **立刻同步给 S3 压缩 session**——它正在重做这块，趁 plan 未定稿把"存文件 + 读写抽 store 接口"写进去，避免返工 |
| 2 | pull 面扩展：fs_* scope 挂载 memory/（只读）+ system hint 提一句"楼层记忆树可查" | 小 | 不碰组装注入口，与 S3 无冲突 |
| 3 | `search_history` 工具：复用 SearchService，profileId 谓词 + 结果截断 | 中 | 注意 20 万 node 红线（predicate 层过滤） |
| 4 | 每日摘要 job（设备端版：打开时补跑） | 中 | 依赖步 1 |
| 5 | 网关增强：hub 定时帧跑步 4 的任务 + 向量回填 | 中 | 依赖步 4；可无限期推迟 |

v2 决策区（停车场）：AI 对 memory/ 受控写（自编辑）、世界书进 pull 面、原子记忆导出虚拟视图、记忆树 iCloud 同步。

## 八、⚁ 收尾：关系图与杠杆

```
                    ┌─────────── push（自动想起）───────────┐
                    │   M1/M2 检索管道 ──▶ 组装 ──▶ BP分层   │
   SwiftData ───────┤                                      ├──▶ 模型
   (结构化真源)      │                                      │     │
                    └──────────────────────────────────────┘     │
   楼层记忆树 ◀──────────── 写回（摘要job/S3/M5）◀────────────────┤
   (文档态真源)                                                   │
        │           ┌─────────── pull（主动回忆）───────────┐     │
        └──────────▶│  fs_grep/read + search_history       ├────▶│
   floors/{slug}/   └──────────────────────────────────────┘
        ▲                                  │
        └────── Mac网关/设备端job（sleep-time 整理）──────────────┘
```

最重要的 5 条连线：
1. 摘要 UserDefaults → 孤岛 → 每日摘要堵死（脆弱一环，步 1 拆除）
2. **pull 结果进历史 = append-only = 缓存友好**（新连线：向 pull 倾斜即缓存优化）
3. **SearchService 已存在只差暴露**（新连线：模型的 Recall memory 几乎零成本）
4. 文件态记忆树 → 同时解锁 grep / 同步 / 网关工作面 / 自编辑（hub node，一击四得）
5. 摘要 ↔ 提取的回声环 → 必须边界声明（第五节）

**如果只能改一个变量**：立楼层记忆树目录（步 1+2，摘要落文件 + fs 可达）。它是后面一切的命名空间。

⧫ 等粟粟批注：① contract 表（push/pull 分工）认不认 ② v1 对 memory/ 只读是否同意 ③ 步 1 是否现在就传给 S3 session ④ search_history 进不进这轮。DON'T IMPLEMENT YET。

---

Sources（2026-06-11 检索）：
- [Letta: Sleep-time Compute](https://www.letta.com/blog/sleep-time-compute) / [Memory Blocks](https://www.letta.com/blog/memory-blocks) / [Agent Memory](https://www.letta.com/blog/agent-memory)
- [Claude API Docs: Memory tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
- [Letta: Rearchitecting the Agent Loop（含对 Claude Code 的分析）](https://www.letta.com/blog/letta-v1-agent)
