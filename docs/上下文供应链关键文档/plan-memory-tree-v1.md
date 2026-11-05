# Plan: 记忆树 v1 + 供应链 pull 化第一刀

> 2026-06-11 · 基于 `docs/research-memory-body-architecture.md`（粟粟已批：Q1 认 contract / Q2 v1 只读 / Q3 见下方 review / Q4 search_history 下轮）
> 关联：`docs/research-context-topology.md`（打架点 A1/A2）
> ⚠️ DON'T IMPLEMENT YET — 等粟粟批注

---

## 〇、S3 压缩实现 review（Q3 验收结论）

压缩 session 两个 commit（992b8b7 + 959e5af）逐行读完：

**做对的（4 件）**：
- ✅ 摘要插槽化（contextSummaryId, order 55）——位置=顺序，符合预设哲学；旧 preset 有迁移 + 无插槽实例有兜底
- ✅ 滞后压缩：`ctx_compress_interval` 默认 5 轮才重压 + force 手动压缩——正是拓扑文档 A2 建议的"低频批量跳变"
- ✅ 摘要稳定后回归前缀（不再下沉）——前提成立时方向正确
- ✅ 顺手修了打架点 C 的一个症状：AUDN 提取字面去重（实测"焦糖布丁注入两遍"）

**缺的最后一块（本 plan 第 4 刀补上）**：
- ⚠️ **历史窗口没锚定**。`PromptAssembler.swift:83-84` 仍是 `suffix(contextDepth)`，`coveredCount` 只用于摘要自身记账（grep 全项目核实，无人用它裁窗口）。后果：对话超 40 条后**每轮滑 1-2 条 → messages 前缀每轮变 → BP4 rolling 每轮 miss**。摘要回前缀目前只保住了 BP1（system，小头）；大头（历史 10-30k token）在长对话里每轮全价。窗口锚到摘要边界后，两次压缩之间历史 append-only，BP4 才真正活过来——这是滞后压缩设计收益的另一半。
- 🟡 小记录：去重是字面匹配，改写式重复拦不住（够用，不修）；`mem_content_summary` 开关与压缩触发的关系实现时顺手核一遍。

## 一、范围

**做（4 刀，相互独立可单独 revert）**：
1. 摘要存储迁文件（记忆树步 1）
2. memory/ 只读挂载进 fs 工具（记忆树步 2）
3. 文件库 hint pull 化（拓扑 A1 修复，按 Q1 认下的"大而易变放 pull"）
4. 历史窗口锚定（S3 遗留缝）

**不做（已批/停车场）**：search_history（Q4 下轮）/ 每日摘要 job（依赖本轮稳定，下轮）/ AI 写 memory/（Q2 只读）/ system 多块挂标（留给预算协调器轮）/ MCP 记忆 Retriever（独立 research 待立项）

**协调注记**：第 3、4 刀动 `PromptAssembler.swift`（:83-85, :272-278 行段）。`docs/plan-assembly-message-stream.md`（待批注）也要动 PA——本 plan 先行，那边落地时 rebase 对照。压缩 session 已完工，无并行冲突。

## 二、改动详单

### 刀 1 · 摘要迁文件：`memory/summaries/{convId 前 8}.md`

- **新目录**：`floors/{slug}/memory/summaries/`，与 `filesystem/` 平级。`FileLibraryStore` 加 `memoryRoot(profileId:)`（复用现有 slug/路径防护逻辑）。
- **文件格式**：YAML frontmatter（conversationId 全量 / coveredCount / updatedAt）+ 正文=摘要文本。人可读可改，AI 可 grep（刀 2 后）。
- **文件名（⧫③ 已批：两个都要）**：`{convId前8}-{标题slug}.md`——convId 前 8 是稳定锚（load 按 `{convId前8}-*.md` glob 匹配），标题 slug 是可读糖（清洗特殊字符、截 24 字、空标题 fallback "untitled"）；save 时发现标题变了 → 自动 rename 跟随。
- **`ContextSummarizer` 改造**：`save/load` 从 UserDefaults 改文件读写，**抽 `SummaryStore` 协议口**（research 步 1 的约束，当时没来得及给压缩 session，现在补上）；保留 ContextSummary struct 不变，序列化层替换。
- **一次性迁移**：启动时扫 `ctxSummary_` 前缀的 UserDefaults key → 写文件 → 删 key；守卫 `memoryTreeMigrated_v1`，幂等。迁移失败的 key 保留不删（下次重试），不静默吞错（log + 计数）。
- **楼层归属**：UserDefaults 旧 key 只有 conversationId，迁移时按 conversation.profileId 查楼层落对应目录；查不到的（对话已删）丢弃并 log。

### 刀 2 · memory/ 只读挂载

- `FileLibraryTools` 的路径解析支持虚拟前缀 `memory/` → 映射到 `memoryRoot`；`fs_list` 合并列出（`memory/summaries/xxx.md` 形态）；`fs_read`/`fs_search` 正常读。
- **写类工具（fs_write/append/edit/rename/delete）对 `memory/` 前缀直接返回 isError："记忆树为只读区"**（Q2 决策）。
- 文件库 system hint 加一句话："楼层记忆树（对话摘要等）在 memory/ 下，可用 fs_read / fs_search 查阅"。
- 路径防护沿用 FileLibraryStore.resolve 同款（拒绝绝对路径/../，前缀校验）。

### 刀 3 · 文件库 hint pull 化（A1）

- **撤**："本对话碰过的文件 · 当前最终内容"段（最多 10×4000 字）从 system hint 移除——模型需要时 `fs_read`（pull 结果固化进历史，缓存友好；本轮刚写的内容本来就在 tool result 里）。
- **留**：文件列表，但**去掉 size 字节数**（size 每次写都变=高频抖动源；列表只在新建/删除/重命名时才变=低频）。
- **引导**：hint 明示"文件内容未注入，读取用 fs_read"。
- **行为风险与对策**：模型可能变懒不主动读。S1 检查器 + 日用实测对比一周；若质量明显降，回滚开关 `fileLibraryFullContent`（默认关）恢复旧行为——开关在本刀一并实现，UI 不加（UserDefaults 手动），避免设置页膨胀。

### 刀 4 · 历史窗口锚定

- **现状**：CV `buildAPIMessages(maxMessages: contextDepth)` 先截 + PA:83 再截，均为 suffix 滑动窗。
- **改法**：有摘要时窗口起点锚 `coveredCount`（`dropFirst(coveredCount)`），两次压缩之间窗口只在尾部生长（append-only）；压缩触发时 coveredCount 跳 N×2，窗口边界与摘要同步跳变 = 每 ~5 轮付一次同步 miss。
- **截断收敛为一处**：CV 层锚定截断后，PA:83 改为只信传入（或传实际长度），消灭双截断（否则 PA 把 50 条裁回 40，锚定白做）。
- **保护 cap**：摘要长期没跑成（预算拦/模型坏）时窗口无限涨——窗口 > contextDepth×2 时退回 `suffix(contextDepth)` 并 log（宁可缓存 miss 不可上下文爆炸）。
- **无摘要对话**：行为不变（suffix）。

## 三、风险与回滚

| 刀 | 风险 | 回滚 |
|----|------|------|
| 1 | 迁移丢摘要（楼层归属查错）| 迁移不删失败 key + log；git revert 后旧版本读 UserDefaults 仍在（已迁走的 key 不在了——revert 前跑反向脚本或接受重新生成，摘要可再生成本低）|
| 2 | 虚拟路径穿透防护 | 纯增量，revert 即无 |
| 3 | 模型不主动读文件 → 回答质量降 | `fileLibraryFullContent` 开关秒回旧行为 |
| 4 | 锚定逻辑错 → 上下文缺段/爆涨 | cap 兜底 + 独立 commit 可单独 revert |

数据安全：全程不动 SwiftData schema；摘要是可再生数据（最坏情况重压一次）。

## 四、验证清单

- [ ] `xcodegen generate && xcodebuild -scheme MemoryPalace build` 双端通过
- [ ] 刀 1：带旧摘要的库启动 → 控制台迁移计数；`floors/{slug}/memory/summaries/` 出现 .md（frontmatter 完整）；继续聊到再压缩 → 文件更新；重启 → 不重复迁移
- [ ] 刀 2：对模型说"看看你的记忆树" → fs_list 列出 memory/，fs_read 能读摘要；让它写 memory/ → 收到只读报错且不中断回合
- [ ] 刀 3：S1 检查器对比——system 里无文件全文、列表无 size；fs_write 一个文件后下一轮：前缀分歧探针报告 **BP1 无分歧**（A1 修复的核心验收）
- [ ] 刀 4：>40 条的对话连发 3 轮（不触发压缩）→ 探针确认 messages 前缀逐字稳定、BP4 命中（缓存仪表盘 cache_read > 0）；第 5 轮压缩触发 → 一次 miss 后下轮恢复命中
- [ ] 回归：<40 条短对话行为不变；无摘要插槽的旧 preset 兜底注入仍工作；CC Bridge 对话不受影响（不走 tools/hint）

## 五、Task Checklist（执行追踪器）

- [x] FileLibraryStore.memoryRoot + 路径防护扩展（100c160）
- [x] SummaryStore 文件读写（frontmatter 编解码）（100c160，文件名两个都要：{convId前8}-{标题slug}.md + rename 跟随）
- [x] ContextSummarizer.save/load 切换 + 调用点核查（100c160，全链 +profileId）
- [x] UserDefaults → 文件一次性迁移（幂等 + 失败保留）（100c160）
- [x] fs_* 虚拟前缀 memory/（list/read/search 通、写类拒）（9e38e26）
- [x] hint 加记忆树一句话（固定文本不列文件名，保前缀稳定）（9e38e26）
- [x] hint 撤碰过文件全文 + fileLibraryFullContent 开关（15dd608；列表本来就没 size，plan 笔误）
- [x] CV 窗口锚定 coveredCount + cap + PA 双截断收敛（415a317，预览同步换 windowed）
- [x] build 双端通过（macOS + iOS BUILD SUCCEEDED）；运行时验证清单 → 粟粟手测（见 review）
- [x] 复盘 review-memory-tree-v1.md + roadmap 同步

预估：~4 文件核心改动（FileLibraryStore / ContextSummarizer / FileLibraryTools / ConversationViewModel+PromptAssembler），净 ~300-400 行，1.5-2 天。

---

⧫ 批注区（2026-06-11 已批）：① 不激进，按 plan ② cap contextDepth×2 可以 ③ 两个都要 → `{convId前8}-{标题slug}.md`，rename 跟随

✅ GO — 实施中。
