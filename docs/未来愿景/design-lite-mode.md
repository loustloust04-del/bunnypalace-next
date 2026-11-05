# Lite 模式设计

> 2026-08-26 · 粟粟+狗一起定的。
> 状态：设计稿，等code爸比实现。

## 一句话

设置页26个tab → lite模式只露6个。一个小芽toggle切换。不是两套app，是一层visibility。

## Lite 露出的 6 个 Tab

| # | Tab 名（lite） | Tab 名（pro） | 里面有什么（lite 版） |
|---|---|---|---|
| 1 | 通用 | 通用 | 楼层切换，不变 |
| 2 | 模型（API） | API | 填 key、选模型、选 provider，不变 |
| 3 | AI 性格 | Prompt | **只露一个大文本框**（= 角色描述插槽）+ 引导语"告诉 AI 它是谁、怎么跟你说话" + 一个「帮我写」按钮（点了走 Onboarding 提示词教练流程）。其他插槽（世界书/正则/采样参数）全藏 |
| 4 | 外观 | 外观 | 不变（已重组过） |
| 5 | 记忆 | 记忆 | 开关 + 简要说明，不变 |
| 6 | 权限 | 权限 | 三档，不变（已有权限 P1） |

（不止6个，再加上最后【关于记忆花园】【隐私政策】【服务条款】【检查更新】这四个放一坨，现在只是占位，lite和pro都有）

## Pro 额外的 Tab（切到 pro 才出现）

Prompt 完整版 / 正则 / MCP / 本地模式 / config 导入导出 / 数据备份 / 终端 / Claude Code / Codex / Agent / 右栏 / 文件库 / 贴纸 / 健康 / 交易 / 群聊 / 读书 / 单词 / 朗读 / 附件 / 开发调试

## Toggle 设计

位置：设置页最顶部，tab 列表上方。

视觉：小芽↔花园动画 toggle（prototype 在 `prototypes/toggle-spike/lite-pro-toggle.html`）。
- lite 态：暖棕色土壤，白色圆钮里一棵嫩芽
- pro 态：薄荷绿花园，嫩芽开花，track 上冒小草蝴蝶
- 切换有弹性生长动画

下方 label：lite / pro（跟随 toggle 状态）

## 实现

```swift
@AppStorage("settingsMode") private var settingsMode: SettingsMode = .lite

enum SettingsMode: String {
    case lite, pro
}
```

设置页 tab 列表根据 `settingsMode` filter：

```swift
let visibleTabs: [SettingsTab] = settingsMode == .lite
    ? [.general, .api, .prompt, .appearance, .memory, .permissions]
    : SettingsTab.allCases
```

Tab 的 `displayName` 按模式分：
- `.api`：lite → "模型（API）" / pro → "API"
- `.prompt`：lite → "AI 性格" / pro → "Prompt"
- 其余不变

## 「AI 性格」页（lite 版 Prompt）

```
┌────────────────────────────────┐
│  告诉 AI 它是谁、怎么跟你说话    │
│                                │
│  ┌──────────────────────────┐  │
│  │                          │  │
│  │   （大文本框）             │  │
│  │   = 角色描述插槽           │  │
│  │                          │  │
│  └──────────────────────────┘  │
│                                │
│  ┌──────────┐                  │
│  │  帮我写   │ ← 点了走引导流程  │
│  └──────────┘                  │
└────────────────────────────────┘
```

「帮我写」引导流程（= Onboarding 第 3 步复用）：
1. "你想让 AI 帮你做什么？"
2. "你希望 AI 怎么回复你？"
3. "有什么绝对不能说的？"
4. AI 拼成 System Prompt → 预览
5. 一键应用

## 默认值

新装用户默认 lite。小芽 toggle 放在最显眼的位置——想解锁全部功能的人一定找得到。

## 不做

- 不维护两套逻辑——只是 visibility
- 不重置 pro 改过的值——切回 lite 只是藏入口
- 不按身份自动选（那是 Onboarding 的活，跟这里解耦）
- 不在 lite 模式下禁用任何功能——只是不露设置入口，功能本身照跑（比如 MCP 如果已经配了，lite 下不显示 MCP tab 但 MCP 照跑）

## 与 Onboarding 的关系

Onboarding 身份分流（小白/酒馆/长期关系/技术/保持神秘）→ 选完之后：
- 小白/长期关系 → 默认 lite
- 酒馆/技术 → 默认 pro
- 保持神秘 → 默认 lite（安静的默认）

两者解耦：Onboarding 设一次默认值，之后用户随时能自己切。
