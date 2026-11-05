# Roadmap: 记忆系统（对标 Paramecium 之后的独立路线图）

> 2026-06-10 · 基于 `/Users/susu/Downloads/paramecium-main/README.md` 深读 + 我方代码深读
> （MemoryService / Memory model / ConversationViewModel 提取链 / ContextSummarizer / MemorySettingsTab / ChatService）
> 哲学前提：**我们不选"kiwi 全量加法"也不选"paramecium 极简减法"——每个机制做成开关，用户自己在复杂度光谱上滑。** 这份 roadmap 就是把灰开关逐个点亮的顺序表。

---

## 一、逐项对比：Paramecium vs 记忆宫殿（代码实测，不是印象）

### 她有我们没有的

| # | Paramecium | 我们的现状（代码证据） | 差距性质 |
|---|-----------|----------------------|---------|
| 1 | **向量语义检索**（ChromaDB cosine） | 无。`Memory.embeddingData` 字段已预留但全程没人写没人读 | 缺整条检索路 |
| 2 | **BM25 关键词检索**（jieba） | `keywords` 字段注释写着"用于未来 BM25"，实际只是**子串 contains 匹配**（`MemoryService.swift matchesKeyword`），无 idf 无打分 | 有路但是土路 |
| 3 | **关系图谱一跳扩展**（edges.jsonl，提取时与最近 20 条比对建边，命中一条沿边拉相关） | 无任何记忆间关联。`parentId` 预留但没用 | 缺整个机制 |
| 4 | **BP1-BP4 prompt cache**（命中率 60-80%，费用砍半） | `ChatService.swift` 全文无 `cache_control`，Anthropic 缓存完全没用上 | 缺，纯省钱项 |
| 5 | **用户画像（profiles）注入时常驻读** | `mem_content_profile` 灰开关占位，无实现 | 缺 |
| 6 | **图片小模型转述省 token** | 无（附件原图每轮重发） | 缺，省钱项 |
| 7 | **提取记忆第一人称 + 主观情感色彩** | 我们规定**第三人称客观**（"用户喜欢…"，extractionPrompt 规则 5） | 风格分歧，见 M8 |
| 8 | **SHA-256 对话去重**（防重复提取） | 每轮 fire-and-forget 提取，靠"窗口只看最近 N 条 + 模型自判 NOOP"软去重 | 弱于她，但我们按轮提取本身更细 |

### 我们有她没有的

| # | 记忆宫殿 | Paramecium |
|---|---------|-----------|
| 1 | **原生 app**：SwiftData 本地、零服务器、零部署。她要跑两个进程 + nginx | 网关架构 |
| 2 | **跨窗口记忆天生免费**：单 store + profileId 隔离，换对话/换窗口记忆本来就在。她要每 10 分钟轮询同步 | 需要轮询 |
| 3 | **AUDN 完整闭环**：模型可 add/**update**/**delete**（新旧矛盾时删旧加新）。她只有 add + 拆分 | 只进不改 |
| 4 | **衰减引擎 hot/warm/cold**（她实测后删了——见 M8 的开关化结论） | 主动删除 |
| 5 | **白板文件库**：AI 主动 fs_read/write/edit 真 .md 文件，记忆之外的第二通道 | 无 |
| 6 | **开关面板**：注入策略 × 内容层 × 基建 全部可开关 —— **核心差异化** | 替用户钉死一种配置 |
| 7 | **上下文检查器（S1）**：注入了什么、请求长什么样，所见即所发 | admin 面板只看记忆库 |
| 8 | **预算闸**：提取共用 provider 预算，没钱自动跳过 | 无 |
| 9 | 上下文总结已有雏形（ContextSummarizer，超 contextDepth 自动摘要旧消息） | 每几轮总结（约等价） |

### 一句话定位

她的"简单"是**复杂走完一圈后的削减**（向量/BM25/图谱全有，删的是衰减和情绪）。我们还没走到向量，谈不上减法。但我们有她给不了的：**原生、零部署、开关自选复杂度**。这份 roadmap = 把她验证过的机制逐个搬进来，**每个都做成开关**。

---

## 二、Roadmap（按依赖顺序排，每个 M 对应设置里的开关）

### M0 · 还债（先做，半天级）
- [ ] **`mem_master` 总开关接线**：现在只是设置页摆设，`buildInjection` / `extractMemoriesIfNeeded` 都没读它。关总开关应当 = 不注入 + 不提取
- [ ] **macOS `MemorySettingsTab` 开关框架补齐**（目前只有 iOS `IOSMemoryPage` 有）
- [ ] 开关读取时机统一说明：UserDefaults 在 buildInjection 内部读，改开关下次对话生效（可接受，文档化即可）

### M1 · 检索 pipeline 重构（向量/tag 的地基，不动行为）
- [ ] 把 `buildInjection` 的 `if useKeyword / else if useFull` 二选一结构重构为**多检索器各产候选 → 融合排序（RRF）→ 预算裁剪**
- [ ] 检索器协议：`(memories, recentMessages) -> [(memory, score)]`，常驻层 / 关键词 / 全量兜底先各自变成一个检索器
- [ ] 行为回归验证：重构后注入结果与现状一致（S1 检查器对照）
- ⚠️ review-memory-keyword-injection.md 已预言：不重构直接加第三路，开关组合会爆炸

### M2 · 真检索：BM25 + 向量（点亮「向量语义」开关）
- [ ] **BM25**：子串匹配升级为 NLTokenizer 分词 + tf-idf 打分（`keywords` 字段的本来使命）
- [ ] **向量**：用 Apple 原生 `NLContextualEmbedding`（on-device，零依赖零服务器——我们不需要 ChromaDB，原生 app 的优势）写入已预留的 `embeddingData`
- [ ] 新记忆提取时顺手向量化；旧记忆懒补（首次开开关时后台批量跑）
- [ ] 双路召回进 M1 的 RRF 融合
- 对应开关：`mem_inject_vector`（向量）+ 关键词开关升级为真 BM25

### M3 · 关系图谱一跳扩展（检索增强）
- [ ] Memory 间建边：提取新记忆时与最近 N 条算相似度（复用 M2 向量），超阈值建边（新 `MemoryEdge` model 或 ids 数组）
- [ ] 注入时：命中记忆沿边一跳扩展，扩展项打折扣分进融合
- [ ] 记忆面板可视化（她有力导向图，我们原生做更顺）
- 对应开关：建议新增「关联扩展」开关（默认关）

### M4 · BP1-BP4 prompt cache（省钱核心，独立于检索线，可提前插队）
- [ ] AnthropicProvider 加 `cache_control` 支持
- [ ] PromptAssembler 已有 TaggedSegment 分段——按变化频率排：BP1 人设+常驻记忆（几乎不变）/ BP2 世界书+画像（天级）/ BP3 会话摘要 / BP4 倒数第二条 user 消息 rolling
- [ ] 关键纪律：**前缀逐字节不变**才命中。动态注入（关键词命中的记忆）必须塞 BP 标记之后
- [ ] S1 检查器显示哪段挂了缓存标（可见性延续）
- 对应开关：`mem_infra` 区新增「prompt cache」开关
- 参考：NyraSeithhh/cache 实测 96% 命中；她实测费用砍半

### M5 · 用户画像 / 做梦聚合（点亮「用户画像」开关）
- [ ] 定期（或手动触发）小模型把 facts 聚合成一段画像文本，存为特殊记忆（`parentId` 派上用场：摘要的摘要）
- [ ] 画像进常驻层（M4 后挂 BP1，缓存友好）
- 对应开关：`mem_content_profile`

### M6 · 时间轴摘要（点亮「时间轴摘要」开关）
- [ ] 日/月/年层级压缩（≈ kiwi calendar），ContextSummarizer 思路从"单对话"扩到"跨对话时间轴"
- 对应开关：`mem_content_timeline`

### M7 · 图片转述省 token（点亮「文件/发图历史」的一半）
- [ ] 图片附件首轮后用小模型转述成文字，后续轮次传转述不传原图
- 对应开关：建议挂在基建区「图片转述」

### M8 · 分歧项开关化（哲学落地：不替用户做选择）
- [ ] **热度衰减开关**：paramecium 实测"冷者愈冷恶性循环"删掉了；kiwi 留着。我们做成开关（关 = effectiveWeight 恒等于 decayWeight，不随时间衰减），让用户自己试
- [ ] **提取人称开关**：第三人称客观（现状，工具感）vs 第一人称主观情感（paramecium，陪伴感）——extractionPrompt 模板二选一，custom prompt 已有入口
- [ ] **情绪权重**：她删了、kiwi 有。先不做，等 tag 层（`mem_inject_tag`）一起设计，避免再加一个孤立字段

### 不做 / 天生免费
- **跨窗口记忆同步**：单 SwiftData store，天生跨窗口，不需要她的 10 分钟轮询
- **网关进程**：我们是原生 app，"网关做的事"= PromptAssembler 在进程内做。`mem_infra_gateway`（缝 kiwi 重活下沉 Mac）维持灰占位，等真有重活（大向量库）再议

---

## 三、建议优先级（粟粟批注区）

我的排序：**M0 → M4（省钱见效最快、独立）→ M1 → M2 → M3 → M5 → M6/M7/M8 按心情**。
理由：M4 不依赖检索重构、每天都在省钱；M1-M3 是一条依赖链；M5 以后是体验增强。

⧫ 等你批注调整顺序 / 砍项 / 加项。DON'T IMPLEMENT YET。

## Checklist 总览

- [x] M0 mem_master 接线 + macOS 开关补齐（2026-06-10 真机验收通过）
- [x] M1 buildInjection → 多检索器融合 pipeline（随 M2 双路召回实战验证）
- [x] M2 BM25 + NLContextualEmbedding 向量双路召回（2026-06-11 实测：零关键词语义命中通过，阈值 0.35；见 review-m2-vector-retrieval.md）
- [x] M3 记忆关系边 + 一跳扩展 + 可视化（2026-06-11 实现完毕，真机验收中；见 review-m3-memory-graph.md）
- [x] M4 BP1-BP4 cache_control + S1 可见（2026-06-11 实测验收：DeepSeek 命中 74%、Opus 经 OR 命中 97% 费用÷8；见 review-m4-prompt-cache.md）
- [x] M5 用户画像聚合（2026-06-11 实现完毕，真机验收中；见 review-m5-user-profile-dream.md）
- [x] M6 时间轴摘要（2026-06-11 楼层日记 memory/daily/ + 📅插槽 + 滞后结算，TimelineTests 10 用例；见 review-m6-timeline.md。**记忆线 M0-M8 全部收官** 🎉）
- [x] M7 图片转述（2026-06-11 实现完毕，真机验收中；见 review-m7-image-transcription.md）
- [x] M8 衰减/人称开关化（2026-06-11；情绪权重按原案等 tag 层）
