# Plan：小芽助手（Page2 创作助手应用）

- 日期：2026-09-10（pi-lane）
- 前置研究：`docs/research-ai-virtual-phone-对比.md` §7（小卷六课）
- 状态：**待粟粟 ⧫ 批注，don't implement yet**

## 1. 一句话定义

把 AVP「小卷」验证过的模式移植过来：一个住在 Page2 桌面上的**创作助手应用**，人设是已有的小芽（lite）/ Rosemary（pro），帮用户写预设/角色卡/世界书/正则，降低「你控制它怎么说话」的技能门槛。

## 2. 已确认决策（粟粟说的）

- ✅ 立项，做成 **Page2 应用**（不是浮动挂件）
- ✅ 人设沿用 **小芽 / 长大叫 Rosemary**（`docs/未来愿景/design-onboarding.md` 已有规矩：lite=小芽，pro=rosemary，**不准叫小雾**）
- ✅ 应用图标：`~/Desktop/芽3d.png`（3D 小芽：红蘑菇帽+羽毛+红墨镜+郁金香，已看过，风格贴合 Page2 针脚点阵）

## 3. 摸底结论（实现的地基）

| 地基 | 现状 | 用法 |
|---|---|---|
| Page2 应用 = `RightPanelTool` | `RightPanelPlugin.swift`，工具注册进 `RightPanelToolManager.tools`，Page2 桌面网格/dock 都从它读 | 加一条 tool 记录即上架桌面 |
| 图标支持图片素材 | `AppIconView.isAssetName`（Page2AppearanceEditor.swift:188）已支持 asset 名 | 芽3d.png 进 Assets.xcassets，icon 字段填 asset 名 |
| 工具调用基建 | **已有**：`ChatToolTypes.swift` + `DeviceToolDispatcher`（日历/提醒/剪贴板/OCR/通知/OpenURL/RunCommand）+ `ToolCallPreflight` | 助手的工具执行层站在上面，不重造 |
| AI 名字存储 | onboarding 设计稿：写 `assistantName` AppStorage，lite 默认「小芽」/ pro 默认「rosemary」 | 助手名/称呼从这儿读 |
| lite/pro 可见性 | `liteVisibleToolIds` 白名单（RightPanelPlugin.swift:22） | 决定小芽进不进白名单（见开放问题） |
| 分层 prompt 模式 | 小卷验证：PERSONA + CAPABILITIES + PAGE_PROMPT + 状态 | 照搬架构，内容重写为小芽口吻 |

⚠️ 注意：`Page2DesktopView.swift` 是 `#if os(iOS)`——Page2 桌面目前 **iOS 独占**。macOS 侧没有这个桌面。这影响平台策略，见开放问题 Q1。

## 4. 架构设计（照小卷六课落地）

### 4.1 分层 prompt
```
system = 小芽人设层（固定，照 design-onboarding 的口吻：sprout🌱，亲昵但有分寸）
       + 能力清单层（从已注册工具包自动生成）
       + 页面上下文层（用户当前焦点模块：预设页/卡库/世界书/记忆页/对话页）
       + 当前状态层（正在编辑的草稿内容摘要）
```
全局 `AssistantContext`（observable）：各模块 onAppear 时上报「我在哪 + 手头草稿」，小芽面板读它。

### 4.2 双协议
复用 ChatService 的 tool call 通路：provider 支持原生 tool calling 走原生，否则文本协议降级。小卷的实战教训直接内置：Gemini reasoning 回传、剥离幻觉时间戳。

### 4.3 工具包（MVP 范围）
学小卷的「app 内部能力 LLM 化」，但 MVP 只上创作三件套 + 一个查询：

| 包 | 工具 | 说明 |
|---|---|---|
| 预设套件 | 读取预设 / 新建（以现有为底复制）/ 改单个插槽 / 改采样参数 | 对应 PromptSlot + SamplingParams |
| 角色卡套件 | 读取 / 创建 / 改单字段 | 写作规范 prompt 参考小卷 7 段式，改成小芽口吻 |
| 世界书套件 | 读取 / 增删条目 / 改单条目 | GlobalWorldBook + WorldBook |
| 记忆查询 | 按关键词/楼层查记忆 | 只读。小芽能回答「你还记得我喜欢什么吗」 |

**明确不做（MVP 外）**：CSS 美化、生图素材管线、正则套件、九宫格那套。理由：MP 没有自定义 CSS 系统，生图无基建，别为移植而移植。

### 4.4 行为状态机写进 prompt（不学代码分支）
「草稿全空+用户描述 → 全量生成；有内容+要求改 → 只出对应字段的 action；闲聊 → 不出 action」。输出走结构化 action 协议，UI 层解析后落到 SwiftData（落库前 diff 预览 + 用户确认，见安全节）。

### 4.5 模型槽
MVP 直接复用当前楼层的 API 配置（不做独立辅助槽）。辅助槽等记忆模块改造（时间线投影那个 plan）一起上，别铺两摊子。

## 5. 安全闸门（创作助手特有的风险）

小芽能**写**用户数据，三条铁律：
1. 所有写操作（建卡/改预设/改世界书）先出 **diff 预览卡片**，用户点「应用」才落库——对应小卷「校准九宫格弹窗」的精神：关键环节人介入
2. action 协议解析失败 = 不动作，只回话，绝不半落库
3. 工具参数校验走现有 `ToolCallPreflight` 同款模式

## 6. 影响范围（新文件为主，不动现有逻辑）

- `MemoryPalace/Models/AssistantTypes.swift`（新）：工具包定义、action 协议、消息模型
- `MemoryPalace/Services/Assistant/AssistantEngine.swift`（新）：agent 循环、双协议适配
- `MemoryPalace/Services/Assistant/AssistantTools*.swift`（新）：四个工具包
- `MemoryPalace/Services/Assistant/AssistantPrompts.swift`（新）：分层 prompt + 写作规范
- `MemoryPalace/Views/Assistant/AssistantPanelView.swift`（新）：聊天面板 + diff 预览卡片
- `RightPanelPlugin.swift`：默认工具列表加 `xiaoya` 一条（+ 是否进 lite 白名单）
- `Assets.xcassets/ya3d.imageset`：图标
- 各模块上报上下文：预设/卡库/世界书/记忆页各加一处 onAppear 上报（手术式，一处一行）

## 7. 开放问题（等 ⧫ 裁决）

- **Q1 平台**：✅ iOS 先行（macOS 无 Page2，本 plan 不含 mac 入口）
- **Q2 lite 可见性**：✅ 进 `liteVisibleToolIds` 白名单
- **Q3 面板形态**：✅ 右侧面板，跟日历它们一致
- **Q4 人设**：✅ 不设前置评审文档；人设 prompt 存设置、**设置里可改**（默认值=小芽人设，用户可覆写）

## 8. Todo checklist（实施追踪器）

- [x] 开放问题 Q1-Q4 裁决（iOS先行 / 进白名单 / 右侧面板 / 设置可改人设）
- [x] 芽3d.png 进 Assets.xcassets（ya3d，缩到 512px 397KB）
- [x] AssistantTypes.swift：工具包/action 协议/消息模型
- [x] AssistantPrompts.swift：小芽人设层 + 页面层 + 写作规范（设置可覆写，xiaoya.personaOverride）
- [x] AssistantEngine.swift：agent 循环 + 原生 tool calling（复用 ProviderRouter）
- [x] AssistantContext 全局上下文 + 四模块上报点（预设/卡库/世界书/记忆）
- [x] 预设套件工具（读当前预设/改插槽/改采样/以模板新建副本）
- [x] 角色卡套件工具（列/读/建/改单字段）
- [x] 世界书套件工具（列/读/增/改/删条目）
- [x] 记忆查询工具（只读，关键词+limit）
- [x] AssistantPanelView：聊天 UI + 提案预览卡片 + 应用/丢弃
- [x] RightPanelTool 注册 `xiaoya` + lite 白名单 + Page2 桌面 ya3d 图标特例
- [x] 设置「小芽」页（人设覆写编辑）+ 设置搜索条目
- [x] build 验证（mac + sim 双端 ✅）
- [x] 楼层锚：提案带 profileId，切楼层后应用作废（防写错楼层）
- [ ] 实测：让小芽写一张角色卡、改一个预设插槽、回答「我喜欢什么」（需真机/模拟器，待粟粟或 MobAI）
- [x] review 文档 + NOW.md 更新
