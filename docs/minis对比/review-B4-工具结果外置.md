# Review：B4 工具结果外置

> 2026-09-09 · plan `plan-B4-工具结果外置.md` 全项执行完。commit 链：`28b60328`（代码）→ `d1141684`（测试）→ `5d6b12d1`（golden 重生成）。
> 验证：macOS `MemoryPalaceTests` 874 条，B4 相关 11+1+4 全绿；全量 3 红 = golden（已重生成后绿）+ `RunCommandToolTests` 2 条计时老账（16–17s，见 §三）。iOS build 0 error。floors 目录数本类测试 615→615。
> **未做**：模拟器手测 4/5（需要真实 provider key，我不能填）→ `docs/needsusu.md`。**没装实机**。

## 一、边界情况

| 情况 | 现在的行为 | 评价 |
|---|---|---|
| 落盘失败（目录不可写 / 磁盘满） | 仍头截，尾注写「完整结果存档失败（原因），只有这段预览」，不抛、不阻塞 loop | 够用 |
| 单行巨型结果（一行 > 50KB 的 JSON） | 按字符边界切到 50KB，尾注明说「按行读也取不全，请缩小查询范围」 | 模型没法用 offset 取回这一行；这是行模型的固有边界，pi 同款 |
| `fs_search` 命中太多 | 走收口点，外置到 `tool-results/`；模型若再 `fs_read` 它，按 2000 行分页 | 有限，不会无限套娃 |
| 空结果 / 空文件 | 原样返回；带范围时「（空文件，共 0 行）」 | — |
| `offset`/`limit` 是浮点、负数、超末尾 | `NSNumber.intValue`；offset<1 当 1；limit≤0 忽略；offset 超末尾 → isError 带总行数 | — |
| 同一 `toolUseId` 重复出现 | 文件名相同 → 原子覆盖 | 无害 |
| 用户停止 / 切楼层（`turnGeneration` 变） | 外置扫描在 guard **之前**跑：被取消的 turn 也可能落几个文件 | 无害（受 50 上限）；要挪到 guard 后也行，`setSegments` 在 guard 后 |
| `run_command` 中文输出 stdout+stderr 各 15000 字 | envelope 单行 ≈ 90KB → 被首行切断外置；卡片 `shellView` JSON 解析失败退化为原始文本 | 全文在存档里能开；三段式展示丢了。见 §三 |
| iCloud 多设备 | `tool-results/` 永远本地；另一台设备上模型续读会得到「非法路径/不存在」isError | 模型自愈；不同步是 D2 有意的 |
| 楼层改名 | 存档在楼层目录下，随 `renameFloorDirectoryIfNeeded` 一起搬 | 同 `memory/` |
| 问问题暂停路径 `otherResults` | 来自收口点之后，已外置 | ✅ |
| 预算收尾指令拼在最后一个 result 后 | 拼在尾注之后 | 语义不变 |
| 全量备份（GlobalBackup）是否包含 `tool-results/` | **未查证** | 大概率不含；含不含都不算错，但要知道 |

## 二、与下一模块交互的风险

- **B3 token-aware ContextPolicy**：B4 只保证「单个结果 ≤ 50KB」，N 个结果 × 50KB 仍能顶窗。B3 做的时候把 `ToolResultOffload.maxBytes` 当单结果上界输入，整体预算归 B3。
- **三处字面量耦合**（改一处必改另两处，都有测试锚但不是编译期约束）：
  1. 尾注里的路径 ↔ `embeddedPath(in:)` 的正则 ↔ `FileLibraryStore.toolResultComponent` 的字符集 `[A-Za-z0-9_-]`；
  2. 卡片判 fs_read 被截依赖 `"[已截断："` 字面量；
  3. `fileRead` 的尾注格式与 `apply` 的尾注格式各写一份（有意没抽共用，两边措辞不同）。
- **prompt 前缀变了一次**：`fileLibrarySystemHint` 固定文案加了一句 `tool-results/` 说明 → 所有开文件库的对话缓存 miss 一次，之后稳定。
- **golden fixture**：`tools-schema-golden.json` 已随 fs_read schema 重生成（唯一 diff = fs_read 双家：描述改写 + `offset`/`limit` 可选 integer + path 描述注明只读前缀）。下次再改 schema 记得 `TEST_RUNNER_REGEN_TOOLS_GOLDEN=1`。
- **ChatGPT OAuth provider 的 toolTurns 序列化**：H-B 时它走 `ProviderRouter.sendStreaming` 的同一条路，B4 没单独验。**未查证**。
- **卡片全文 sheet**：`Text` 直渲最多 1MB，性能没量过；1MB 纯文本在 iPhone 上大概率卡一下。

## 三、技术债

| # | 债 | 量级 |
|---|---|---|
| 1 | 删对话不清 `tool-results/<conv>/`；每对话 50 上限但**无总量上限**（50 × ≥50KB ≈ 每对话 ≤ 几 MB） | 小，攒到设置页「清理」一起做 |
| 2 | `run_command` 内层头尾截断丢中段，没交给外置；中文大输出还会触发首行切断 + 三段式退化 | v2：内层 cap 抬高 + envelope 拆 stdout 单独外置 |
| 3 | `manual/facts/` 只有 `data-import` / `model-api` 两个 facts 文件，没有文件库/工具一节——fs_read offset/limit 与 `tool-results/` 两条事实**没地方写**，等 M4 派批时补 | 说明书线 |
| 4 | 全量测试一跑 floors +10（`RunCommandToolTests` 等泄漏，H-Q P2 老账）；2 条计时红从 H-Q 的「变慢」到今天 16–17s（目录 495→625，`uniqueSlug` O(N²) P1 老账） | ✅ 09-09 收口：粟粟拍删 625 个垃圾目录（635→10）；`uniqueSlug` 改一次读名单、`RunCommandToolTests` 随机段前置 + tearDown；两条计时测试 16s→2s，跑完 floors 10→10 |
| 5 | `FileLibraryStore.readAny` 是给显示侧临时拼的三路读；再多一个虚拟前缀就该收成 `resolveAny` | 小 |
| 6 | 手测 4/5 未做 | needsusu |
