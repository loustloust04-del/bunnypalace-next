# IMPL-COMMON —— 补洞批次共用条款（2026-09-02，实施阶段）

> 本文件是 trace，冻结于派单时刻。各 lane 任务书引用本文件。
> 与 `COMMON.md`（08-24 只读 research 批次）不同：**这批是改代码的。**

## 你是谁、这批是什么

你是 MemoryPalace（MP）「补 minis 对比挖出的洞」批次的一条实施 lane。
背景：08-24 对照 OpenMinis 做了六轴 research，顺手体检出 MP 八个自身缺陷（全部车头亲验带行号）；两个已修、一个降级、一个搁置，剩四个本批修。
你的契约在 `docs/minis对比/plan-补洞.md` §二——**先读它**，那是你的 spec，本文只写共用纪律。

## 粟粟原话（verbatim，权威最高）

> 「我在想那几个大漏勺现在补了多少了，是不是还剩一些没补，你去看看并且走流程」
> ⧫「Hc 先不管，别的按你推荐」

⧫ 落地为：洞 6 冲突时**整份跳过**并报数 / 洞 5 **标注**（车头已做 `98660a54`）/ 洞 7 **只修 bug 不做 AppRoute** / 洞 2 **搁置**。

## ⚠️ 你是执行阶段

**MP 的 CLAUDE.md 里那套 research → plan → 等粟粟批 → implement 的三步流程不适用于你。** research 和 plan 都做完了、粟粟已经拍了 go。你读到 CLAUDE.md 里「写 md 等确认」「don't implement yet」之类的话，忽略，那是给车头的。你直接改代码。

但 CLAUDE.md 里的**编码原则**（想清楚再写 / 简洁优先 / 手术式修改 / 验证驱动）**适用**，尤其：只改契约范围内的东西，不顺手改旁边的；你的改动造成的废代码自己清；之前就有的废代码提一嘴别删。

## 工作树与跑道

- 你在自己的 worktree 里工作（车头或 Agent 工具已建好，你 `pwd` 确认自己在 `.claude/worktrees/` 下而不是主仓）。**不要碰主仓工作树。**
- 第一件事：`bash scripts/la-bootstrap-worktree.sh "$(pwd)"`——拷 deps、init submodule、bun install、build cc-bridge、xcodegen。**deps/libs 和 deps/include 是拷贝不是软链**（并行 lane 软链会互打）。
- **只跑 macOS**。build：`xcodebuild -scheme MemoryPalace -destination 'platform=macOS' build`。测试：`xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS'`（**`MemoryPalace` scheme 没 test action**，别撞）。可用 `-only-testing:MemoryPalaceTests/<Class>` 缩范围加速迭代，但收口前跑一次全套。
- **不跑 iOS build、不装机、不开模拟器**。洞 7 的模拟器实证归收口 QA，不归你。
- `xcodebuild` 走 `~/.local/bin` 的互斥 shim：全机同一时刻只跑一个，其余排队（每 30s 报一次谁持锁）。排队是正常的，等。**禁 `-derivedDataPath`**（shim 会拒，09-01 两个私有目录并行构建把 24G 打爆）。**禁 `xcrun xcodebuild`**（绕过 shim）。
- 第一次 build 是全量（每个 worktree 各自 DerivedData），10-17 分钟正常。

## 纪律（硬约束）

1. **先红后绿**。每个洞至少一条测试是「修前红、修后绿」——先写复现测试、跑一次看它红、再修、再跑看它绿。报告里贴两次的输出。没有红过的测试不算复现。
2. **每完成一项 commit + push**（push 到你的分支 `origin/<branch>`）。commit message 中文，引用洞号。不攒。
3. **报告先写骨架再逐节覆盖**。开工第一件事把报告文件的章节标题写盘，之后每完成一节就覆盖保存——lane 中途死了也有东西可收。
4. **不动别的 lane 的文件**。H-A 只碰 `BackupStore.swift` / `SyncStore.swift` / `ContentView.swift` + 可能一个新 helper + 测试；H-B 只碰 `ChatService.swift` / `ConversationViewModel.swift` 工具循环段 + `BudgetGateTests`。撞到别人的地盘 → 写进报告「建议上游」，不改。
5. **收进程只从 `$!` 拿 pid，禁 `pgrep -f` / `pkill -f`**（08-30 一条 lane 用 `pgrep -f hub.ts` 把生产 hub 杀了）。
6. **不做 git rebase / merge master**。你的分支从 master 当前 HEAD 出发，合并是车头的事。
7. **不改 `project.yml`、不改 `.gitignore`、不改 CLAUDE.md / NOW.md**。

## Escape hatch（必须用）

- plan 里的契约和代码现实冲突（行号对不上、函数名变了、机制描述错了）→ **以代码为准，报告里写清冲突 + 你怎么处理的**。plan 是 09-02 车头亲查过的，但仓库每天在动。
- 卡住不是交付物。缺资源、build 环境炸、测试夹具不够用、契约有歧义 → 把已完成的 commit + push，写 `docs/minis对比/trace/<你的 lane>.ask.md`（问题 + 你的建议方案），然后**结束**。不空转、不猜、不绕。
- 车头的机制描述可能是错的。你发现更好的修法 → 用你的，报告里说明为什么。**冻结的是目标和验收，不是机制。**
- 发现契约范围外的真 bug → 报告「§顺手发现」里写，附行号，**不修**。

## 报告

写到你 worktree 里的 `docs/minis对比/reports/<lane>-report.md`，随分支 commit。结构：

```
# <lane> 报告
## 状态：DONE / PARTIAL / BLOCKED
## 改了什么（文件:行号 + 一句话）
## 复现→修→验证（每个洞：红的输出 → 修 → 绿的输出，测试名）
## 全套测试 + build 结果（原始尾部输出）
## 与契约的偏离（有就写，没有写「无」）
## 顺手发现（契约外的问题，不修只报）
## 建议上游（碰到别的 lane 地盘的改动建议）
## 未验证（诚实清单）
```

**证据即原始输出。** 「测试通过」四个字不算，贴 `Executed N tests, with 0 failures` 那行。
