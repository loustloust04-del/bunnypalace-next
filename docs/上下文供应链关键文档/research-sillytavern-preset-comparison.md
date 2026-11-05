# Research: 酒馆 Preset 体系 vs 记忆宫殿（楼层实例化后）

> 2026-06-10 · 源码证据来自本地 `~/Projects/Sandbox/sillytavern_git`（文件:行号均指该 repo）
> 我方对照基于楼层实例化改造后的现状（docs/plan-preset-floor-instance.md，commits 2bfe3da→daf95d7）

## 一句话结论

**酒馆的 preset 内容本来就是全局共享的（= 我们修掉的那个"跨楼层"行为），它靠「角色卡覆盖 + per-角色顺序表」来做差异化；我们走得更远——整份实例隔离。两边没有谁抄错谁，是两种作用域哲学，但我们的模型更贴合"楼层=独立世界"的产品心智。**

## 酒馆的分层（数据归属）

| 数据 | 存哪 | 作用域 |
|---|---|---|
| prompts[]（含 main/jailbreak 的**实际内容**） | preset JSON | **全局**，所有角色共享 |
| prompt_order（顺序 + enabled 开关） | preset JSON 内 per-character_id 一条 | **per-角色**（仅顺序/开关，无内容） |
| 角色设定/性格/场景/对话示例 | 角色卡 | per-角色，preset 里只有 marker 占位 |
| persona 描述 | 用户设置 | 全局用户层 |
| system_prompt / post_history_instructions 覆盖 | 角色卡字段 | per-角色，组装时**动态覆盖** preset 的 main/jailbreak |

关键机制：

1. **编辑 prompt 内容永远改全局**：UI 改 prompt → `updatePromptByIdentifier()` 直接写全局 `serviceSettings.prompts[]`（PromptManager.js:928-931）。酒馆没有"为某个角色单独改 prompt 内容"的覆盖层——**酒馆用户天然接受"改预设=所有角色都变"**。
2. **per-角色差异靠两条路**：
   - 角色卡的 `system_prompt`/`post_history_instructions` 在组装时覆盖 main/jailbreak 的 content（openai.js:1469-1484），preset 可用 `forbid_overrides` 拒绝覆盖（PromptManager.js:320-323，只有 main/jailbreak 可被覆盖）
   - `prompt_order` 按 character_id 存每个角色自己的顺序和 enabled 开关（PromptManager.js:1207-1209），还有 global/character 两种策略（PromptManager.js:335-337）
3. **marker 体系**和我们一致：charDescription/personality/scenario/personaDescription/dialogueExamples/chatHistory/worldInfo 都是占位符，内容组装时从角色卡/用户设置/聊天填充（PromptManager.js:2018-2078）。
4. **组装顺序**：按 prompt_order 遍历 → marker 填充 → injection 分 RELATIVE（嵌在 order 流里）/ ABSOLUTE（按 depth 0-4 分层插历史，同层按 injection_order 高→低，层内再按 system→user→assistant 排）（openai.js:790-842）。
5. **切 preset**：prompts[] 整体替换，角色卡/persona/聊天/世界书不变；自定义过的 per-角色 order 不跨 preset 继承（PromptManager.js:1136-1140 没有就按默认初始化）。

## 对比表：酒馆 vs 记忆宫殿

| 维度 | 酒馆 | 记忆宫殿（实例化后） | 评 |
|---|---|---|---|
| preset 内容作用域 | 全局共享，改了全角色生效 | 模板全局，楼层持有整份实例，互不干涉 | 我们更强隔离；酒馆的行为正是粟粟报的 bug |
| per-角色差异化手段 | 角色卡覆盖 main/jailbreak + per-角色 order/开关 | 整份实例（内容+结构+采样+正则全 per-楼层） | 我们一个机制覆盖了它两个机制的能力 |
| 角色卡 system_prompt/PHI | 组装时**动态覆盖**，卡改了立即反映；forbid_overrides 可拒 | 建楼层时**一次性写入**实例 main/jailbreak 槽 | 差异点：我们卡更新后楼层不自动跟（楼层编辑器自己改）；不需要 forbid_overrides |
| marker 占位 | content 永远空，纯占位 | marker 可存 content，非空时屏蔽 profile 字段 | 我们多一层 override 语义（SlotEditPage 文案已说明），酒馆更纯粹 |
| 采样参数作用域 | 跟 preset 走（全局） | per-楼层实例 | 我们隔离更彻底 |
| order 与内容的关系 | prompt_order（顺序）与 prompts（内容）分离存储 | 一体：实例的 prompts 数组自带顺序（injectionOrder）+ enabled | 我们简单；代价是没有"同一套内容多套顺序" |
| injection 体系 | RELATIVE/ABSOLUTE 两种 position；depth 0-4 分层 + 同层 injection_order + role 排序 | 只有 depth>0 从末尾倒数插入 + 全局 injectionOrder；无 position 概念、无同层 role 排序 | 我们是简化版；导入复杂酒馆预设时 ABSOLUTE/同层排序语义会丢 |
| 切 preset | prompts 全换、角色内容不变、自定义 order 不继承 | 切模板=换实例（旧实例保留可切回）、profile 字段不变 | 我们的"切回保留改动"比酒馆体验好 |

## 兼容性检查（导入酒馆预设）

- 我们的 `fromSillyTavernJSON` 把 main/jailbreak 等列入 builtInMarkers → 导入的 main 是 marker，**content 空时读 profile.systemPrompt**（PromptAssembler.swift:286-289）——恰好对齐酒馆"角色卡覆盖 main"的语义（楼层 ≈ 角色卡）✓
- 丢失项（导入时静默降级）：`injection_position`（我们导入时写死 0，ABSOLUTE 预设的插槽会被当 RELATIVE 排进顺序流）、同 depth 多插槽的 injection_order 高→低 + role 分组排序（我们 depth 插入只按 depth 排）。复杂的"深度注入型"酒馆预设（比如夏瑾 Pro 这类）组装出来的位置会和酒馆有出入。
- `prompt_order` 我们取最后一条（character-specific）的 enabled 状态，多角色 order 的预设只保留一套 ✓ 可接受（我们没有 per-实例多 order 概念）。

## 值得借鉴 / 不值得借鉴

**值得（如果以后遇到对应需求再做，现在不动）：**
1. `injection_position` RELATIVE/ABSOLUTE + 同层排序——等粟粟真的导入重度酒馆预设发现组装位置不对时再补。
2. 酒馆"卡覆盖动态生效"——如果以后角色卡库支持"更新卡后同步到已建楼层"，参考 forbid_overrides 设计冲突规则。

**不值得：**
1. prompt_order 与 prompts 分离——为"一套内容多套顺序"加复杂度，我们的楼层实例已覆盖该需求。
2. 全局 prompt 库 + 覆盖层模型——正是这次修掉的行为。

## 后置提醒（jailbreak）在两边的定位

酒馆：jailbreak 内容存全局 preset，可被角色卡 post_history_instructions 覆盖；默认预设内容为空。
我们（本次修正后）：出厂默认空，per-楼层实例存内容，角色卡建楼层时一次性写入。**两边现在语义对齐**——内容空 = 不注入，谁写了归谁。
