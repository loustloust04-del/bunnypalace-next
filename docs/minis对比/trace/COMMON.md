# COMMON —— minis 对比批次共用条款（2026-08-24）

> 本文件是 trace，冻结于派单时刻。各 lane prompt 引用本文件，不复制内容。

## 粟粟原话（verbatim）

> 「对比我们的项目和 minis，看看哪些地方可以学习」

无更多口头限定。轴的切分是车头（orchestrator）的判断，不是粟粟指定的。

## 两边是什么

**我们 = MemoryPalace（MP）**，仓库 `/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace`。
macOS 15+ / iOS 26+ 原生 SwiftUI + SwiftData 应用，产品名「记忆花园」，Bundle `com.susu.MemoryPalace`。
定位：**AI 对话浏览器 + 聊天客户端**——导入历史对话、实时 AI 聊天、AI 记住你、你控制它怎么说话。
规模：395 Swift 文件 114K 行（Models 6K / Services 34K / ViewModels 5K / Views 65K）+ 测试 68 文件 9.3K 行。
两端共用源码（未守卫的 macOS-only view 在 iOS 也编译）。

**对照物 = OpenMinis（OM）**，本地只读 clone 在
`/private/tmp/claude-501/-Users-susu-Desktop-susu-project------MemoryPalace/21f01c6d-ed23-4569-b935-7bb3469bb3ec/scratchpad/OpenMinis`
（commit `09fc199`，2026-08-19，GPL-3）。
iOS（Swift/SwiftUI）+ Android（Kotlin/Compose）双端。iOS 侧 204K 行：
`src/ios/Agent` 102 文件 70K ／ `Providers` 69 文件 31K ／ `Views` 81 文件 61K ／ `Shared` 45 文件 8.5K ／
`NativeOffloads` 5K ／ `Debug` 13K ／ `iSH` 4K ／ `FileProvider` 1.1K ／ `ShareExtension` 0.3K ／ `AgentWidget` 0.4K ／ 测试 20 文件 3.9K。
定位：**装在手机里的私有 agent**——给模型一台真电脑（设备内 Alpine Linux 沙箱）、浏览器自动化、skills、持久记忆、深度系统集成。
规范文档在 `docs/specs/`。

**两者是同一物种的两个方向**：OM 往「agent 能替你干活」走，MP 往「陪伴 / 对话 / 记忆 / 人格可控」走。
对比的价值不在于比谁功能多，而在于：**OM 已经解决、而 MP 正在流血或尚未面对的那些问题**。

## 本批次要什么

一份**可决策的采纳清单**，不是功能对照表，不是散文观感。

粟粟是有经验的独立开发者。她要的是「哪些地方可以学习」——包含三类答案，缺一不可：
1. OM 做了而 MP 没有、且 MP 该有的（能力缺失）
2. 两边都有但 OM 的实现更好的（实现更优）
3. **MP 已经比 OM 好的**（反向发现——避免报告变成单向自卑清单，知道自己哪里领先同样是决策输入）

以及一类必须显式写出的：OM 有但 MP **不该学**的，附理由（产品定位不同 / 代价不成比例 / 我们已有等效物）。

## 产出格式（硬契约）

写到 `docs/prompts/2026-08-24-minis-compare/reports/<你的 lane 号>-report.md`。

开头必须有一个 **TL;DR 表**：每行 = 发现标题 + 差距性质 + 采纳建议 + 代价档位。让人扫一眼就能挑。

正文每条发现按此结构（缺哪块写「未查证」，不要留空也不要编）：

```
### <编号>. <一句话标题>

- **OM 怎么做**：机制描述 + 证据 `文件:行号`（必须是你真读过的行，不是搜索命中）
- **MP 现状**：同样带 `文件:行号`；确实没有就写「无」并说明你是怎么确认「没有」的
- **差距性质**：能力缺失 / 实现更优 / 我们更好 / 不适用
- **采纳建议**：直接搬 / 改造搬 / 只借思路 / 不建议 —— 并说清「搬什么」的边界
- **代价档位**：小时级 / 天级 / 周级 / 架构级（粗粒度即可，不要精确估时）
- **风险与前置**：会撞 MP 的什么？依赖什么先做？
```

结尾必须有两节：
- **§反向发现**：MP 比 OM 做得好的地方（同样带证据）。**没找到也要写「没找到，我找了 X Y Z」**，不许省略本节。
- **§不建议学**：OM 有但 MP 不该学的，附理由。

## 红线

- **纯只读**。不改 MP 任何一个文件、不改 OM clone、不 build、不跑测试、不 git 操作。唯一写入 = 你自己的报告文件。
- **证据即行号**。任何关于代码的断言必须能追到 `文件:行号`。grep 命中不算读过——被引用的行你要真的看过上下文。
- **区分事实与推断**。你没验证的写「推断」或「未查证」，不要让推断裸奔进结论。宁可交白卷也不要编。
- **不要复述 MP 的 CLAUDE.md / NOW.md 内容当发现**。那些粟粟自己写的，她知道。

## License 口径（粟粟 08-23 已拍）

可以对照 OM 源码写分析，不受清洁室束缚。但注意：MP 的公开发布点 mneme-atrium 是 AGPL-3 + Commons Clause（禁售），GPL-3 代码不允许附加新限制。
→ **本批次只做分析，不产生逐字搬运**。你的报告里可以引用少量代码片段作为证据（几行，说明机制），但采纳建议一律写成「按 MP 架构原生实现」，不要写成「把这个文件拷过去」。

## 已完成、不要重做

**权限模型轴 08-23 已深做过**，成果在 `docs/prompts/2026-08-23-perm-research/`：
`reference-minis.md`（Minis 权限页截图转写）、`reference-openminis.md`（OM 权限实现源码级拆解）、
`reports/A-report.md` `B-report.md` `C-report.md` `verify-report.md`。
→ 你的 lane 如果撞到权限（`Agent/Offload/OffloadPermissionManager.swift`、`Shared/Config/MinisConfigPermissionStore.swift`），
**引用那批结论即可，不要重新拆解**。除非你发现那批的结论有错——那种情况请显式指出并给证据。

## Escape hatch（必须用）

- 前提和现实冲突（本文件写的规模/路径/结论对不上代码）→ **报告冲突 + 你的替代方案**，不要默默按错前提执行。
- 卡住不是交付物。缺资源、路径读不到、范围有歧义 → 写清「我卡在哪、我建议怎么办」，把已完成部分交出来，然后结束。不要空转，不要猜。
- 车头（orchestrator）的轴切分可能是错的。**你有权反驳**：如果你在自己 lane 里发现更重要的东西在轴外，写进报告的「§轴外发现」，说明为什么它比本 lane 的内容更值得粟粟看。
- 本文件是车头的转写，可能有转写漂移。粟粟的原话在最上面——原话优先于转写。

## 报告长度

不设下限也不设上限，但**密度优先**：宁可 8 条有行号有代价的发现，不要 30 条「OM 有 X，我们没有 X」的清单。
车头会亲自读完每一份，不会只看摘要。
