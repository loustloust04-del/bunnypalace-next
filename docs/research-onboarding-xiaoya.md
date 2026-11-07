# research · 小芽对话式引导（替换六页表格）

> 2026-10-15 · 子 agent 只读代码 · 前置 [plan-onboarding-xiaoya](plan-onboarding-xiaoya.md) §六 · 小样 [design-onboarding-xiaoya.html](design-onboarding-xiaoya.html)
> 行号以 `MemoryPalace/` 为根，基于 `zone/page2-apps` 工作区（HEAD a438c37f0 + 未提交改动）。

## 1. 小芽现在怎么实现

| 部件 | 现状 |
|---|---|
| 入口 | 只有 page2 子应用一个：`Models/RightPanelPlugin.swift:255,262`（lite 白名单 `:27`），`Views/MemoryPanelView.swift:160-161` 渲染 `AssistantPanelView()` |
| 对话存储 | **不在 SwiftData、不属于任何楼层**：一份全局 JSON `Application Support/AssistantChat/history.json`（`Services/Assistant/AssistantChatStore.swift:15-19`），按条存 `AssistantChatMessage`（`Models/AssistantTypes.swift:92-116`）；账本另一份（`AssistantLedger.swift`）。全局备份不含这两份（`Services/GlobalBackup/` grep 无 `AssistantChat`） |
| 引擎 | `AssistantEngine`（`AssistantEngine.swift:31-71`）**每开一次面板 new 一个**（`Views/Assistant/AssistantPanelView.swift:22-24`），init 时读盘；切楼层收 `.profileWillSwitch` 静默取消（`:68-70`），工具回调核 `originProfileId`（`:351-354`） |
| 模型 | `xiaoya.model` 空 = 跟随 `selectedChatModel`（`:3-12`）；没模型时回一句写死的「我还没接模型呢」（`:103-106`）；可选本机 MLX（plan-小芽-v3） |
| 名字 | `xiaoya.name` 可改，没改时 lite=小芽 / pro=**Rosemary**（`AssistantPrompts.swift:12-24`），设置页有改名框（`Views/Assistant/XiaoyaSettingsTab.swift:8,23-25`） |
| 工具作用域 | 一律「当前楼层」：`AssistantEnv.profileId = currentProfile.id`（`AssistantTools.swift:16`），`query_memories` 只查当前楼层记忆（`:274-277`） |
| 舞台 | 剪纸舞台 4 套（`XiaoyaStageTheme.swift:7-42`，默认薄荷夜场）+ 九张剪纸表情 + 名字小票；聊天区皮肤 `XiaoyaSkin.swift:20-38`（亮 `#F3F3EF` 纸 / `#1E3D26` 墨 / `#DCE7DF` 你的气泡） |
| 盖章 | 写操作只出提案卡，`stamp` 唯一落地（`AssistantEngine.swift:139-178`），与引导无关但要共存 |

### 「小芽 app = 小芽楼层」差什么

1. **楼层本身**：没有小芽楼层。种子只有 `default-workspace`「对话空间」（`MemoryPalaceApp.swift:114-126`），读盘为空才种（`:434-445`）。要一个**保留 id**（如 `xiaoya`）的楼层：不可删、不可改名、不进「卡建楼层」逻辑。
2. **page1 换房间**：楼层 page1 现在只有 `CardFlowView` / 空态 / `agoraRoom` 三种（`Views/ContentView.swift:1717-1733`）。`agoraRoom` 就是「同一个 page1 换一个房间视图」的先例——小芽楼层照这个挂一个 `XiaoyaRoom`（舞台 + 小芽对话），不走 `ConversationViewModel`。
3. **同一份对话**：两个入口必须共用**一个** engine（现在每个面板各 new 一个、各自读盘，mac 上右栏和 page1 同时开就会互相覆盖写盘）→ 改成 `AssistantEngine.shared`，存储维持 JSON（推荐，不迁 SwiftData）。
4. **工具作用在谁身上**：人在小芽楼层时「当前楼层」= 小芽楼层，改预设 / 世界书会改到小芽自己头上。需要「目标楼层」概念：在别的楼层用 app = 当前楼层；在小芽楼层 = 最近待过的 Ta 楼层（舞台小票显示「正在帮：某某」可切）。
5. **同一份记忆**：小芽没有自己的记忆，`query_memories` 读的是当前楼层的。要么小芽楼层自带一份记忆（引导写入的称呼 / 园丁类型 / 有没有 Mac 先作钉住记忆），要么只读 Ta 楼层的——待拍板。
6. **名字不可改**：拍板「不被改名」与 `xiaoya.name` 改名框、pro=Rosemary 分叉冲突，要收掉。
7. **备份**：成了楼层后用户会默认它被备份，现在 history.json / 账本不在备份里。

## 2. page1 卡片组件现状（引导能不能直接复用）

| 组件 | 位置 | 能否在小芽房间直接用 |
|---|---|---|
| 卡片总表 | `Views/Cards/ChatCard.swift:1086-1103`：消息正文里的 ```` ```card-* ```` 围栏块 | 渲染可复用 |
| 选择 / 问答 / 表单卡 | `AskCard` `ChatCard.swift:662-678`，表单项 `Field` `:679-740`（文字/单选/多选/日期/数字/滑块，`secure` 只许文字） | **交互不行**：`AskCardView` 依赖 `ConversationViewModel` 环境（`AskCardView.swift:9`），没有就是只读（`:41-50`）；答案靠 `stageCard`/`sendCardNow` 进主聊天输入框（`ConversationViewModel+Cards.swift:38,57`） |
| 加密字段 | `AskCardView.swift:329-345,583-611` | **不能拿来存 key**：真值进 `SecretVault`、卡上留 `{{secret:id}}` 占位，是给工具替换用的，和 `APICredential` + 钥匙串两回事 |
| AskUserQuestion | `ConversationViewModel.swift:1936-1990` + `AskUserQuestionSheet.swift:7` | 绑主聊天工具循环，弹 sheet，不适合 |
| 待办卡 | `TodoCardView.swift:6` | 同上，只读可显示，勾选要 vm |

结论：plan §二「复用已有卡片、不需要新 UI」不成立。要么给卡片抽一层「答案回调」协议（vm 和小芽 engine 各实现一份），要么小芽房间做一套**引导专用卡**（选择 / 填 key / 导卡 / 起名 / 配对 / 待办），视觉对齐 AskCard。推荐后者先行，范围可控。

## 3. 旧引导写了什么（新引导必须全覆盖）

触发：`ContentView.swift:64,779` 按 `onboardingCompletedV1` 弹 fullScreenCover（仅 iOS，文件头 `#if os(iOS)`）；设置页可重走（`SettingsView.swift:300`）。

| 步 | 写入 | 证据 |
|---|---|---|
| 身份 | `onboardingIdentity`；**`settings.proMode` 默认值**（小白/陪伴 lite，其余 pro） | `OnboardingFlowView.swift:271-293` |
| Ta 叫什么 | `Profile.assistantName` + 镜像；留空写吉祥物名 | `:345-359` |
| 称呼 | `Profile.userName`（+ 无人读的 `onboardingUserName`） | `:555-561` |
| 酒馆导入 | 卡 → `enter(card:)` 建楼层并**立刻切过去**；世界书挂当前楼层；预设换当前楼层 presetId | `:437-505`，`Services/CharacterFloorService.swift:30,86` |
| key | 草稿测试（`ProviderProbe`，只认 2xx）→ `persistCard` 建卡 + 钥匙串（同协议同地址同 key 复用） | `:690-757`，`Models/ProviderProbe.swift:1-5,64-117` |
| 模型 | `selectedChatModel` = `<卡id>/<模型id>` + 收藏 | `:910-923` |
| 教练 / 陪伴 | 写预设插槽 charDescription / personaDescription；陪伴可导聊天记录 | `:930-984` |
| 技术 | 扫码 `CCPairingApply.apply` | `:1048-1051`，`Views/CCPairingViews.swift:214` |
| 完成 | `onboardingCompletedV1 = true`；**此时才请求推送权限** | `:1055-1103`，`PushNotifications.swift:20` |

没有主题 / 外观步（plan §一 写的第 5 步在代码里不存在）。

### 审查里的旧问题 → 新引导硬要求

1. **H1 测试只认 2xx，失败不往下走**：显示状态码 + 上游原因 + 实际请求地址（`ProviderProbe.Failure` 已带三样），失败停在原卡可改了重测；成功也不自动跳，由用户点「就用这个」。
2. **H2 测试不落盘，保存是唯一落盘点**；换服务商 / 改地址 = 新草稿，不复用旧卡。
3. **H3 自定义中转要能选协议**（OpenAI / Anthropic 兼容），保存前把规范化后的完整地址给用户看。
4. **H4 key 可切明文**核对。
5. **H5 存卡即设主模型 + 收藏**；拉不到模型可手填模型 ID，不卡死。
6. **H6 导卡不重置引导**：进度就是对话本身（JSON），不靠 `OnboardingResume` 这种进程内单例；导卡**建楼层但不自动切**，由用户点「去找 Ta」。
7. **H7 导入顺序不决定落点**：世界书 / 预设导入固定落到刚建的 Ta 楼层；预设导入提示会不会冲掉卡自带指令。
8. **H8 不把吉祥物名写进 Ta 的名字**；Ta 的名字 / 你的称呼写 `Profile`，并在 Prompt 页看得见。
9. **H9 称呼不只写一个楼层**：存成默认身份，之后新建 / 导卡楼层继承（`CharacterFloorService.floorUserName` `:126-129` 已读 `currentProfile.userName`，在小芽楼层导卡正好能读到）。
10. **H10 ghost / 跳过 key 的人要被指路**，指路文案用 lite 下的真实叫法（「模型和API」）。
11. **H11 推送权限、proMode 默认值**这两件旧完成页的副作用要保留。

## 4. 风险

- **首启判定（最大坑）**：新装要种小芽楼层 + 开引导；升级用户（已有楼层 / 卡 / 对话 / API 卡，或 `onboardingCompletedV1` 为真）一律不弹。只看 `onboardingCompletedV1` 不够——从没走完旧引导的老用户会被拉进新引导。用新键（如 `onboarding.xiaoyaV1`），并以「楼层列表里只有种子且没有任何会话 / 自建卡」判新装。楼层读盘失败进只读时（`MemoryPalaceApp.swift:434-443`）绝不能种、不能写。
- **保留 id 冲突**：用固定 id 而不是名字认小芽楼层，老用户自己建过叫「小芽」的楼层不受影响；删除 / 重命名 / 整包导入覆盖楼层列表时都要保住它。
- **填 key 复用 API 卡同一套**：`APICredentialEditor.makeDraft`（`Views/APICredentialEditor.swift:145-166`）和 `persist`（`:1364-1415`）都是 View 的 private 方法、读页面 @State，引导现在是自己抄了一份（`OnboardingFlowView.swift:690-734`）。要抽成「草稿 → `ProviderProbe.test` → 唯一提交」的共享服务，两边调同一个，否则又是两套口径（单例卡 id、本机模型、自动收藏这些分支只在编辑器里有）。
- **整树 `.id` 重建**：根视图 `.id(currentProfile.id)`（`MemoryPalaceApp.swift:1301`）。小芽房间的状态必须全在 engine 单例 + JSON 里；engine 单例活在视图树外，切楼层不能把正在走的本地剧本取消掉（现在 `.profileWillSwitch` 会 cancel 生成中）。
- **本地剧本 ↔ 真 AI 交接**：交接点 = 测通并保存 key 之后。前面的本地消息要标「剧本」，不进发给模型的历史（或压成一句「用户刚完成引导：称呼 X、园丁类型 Y、已配好 Z」的系统备注），否则模型会学着输出剧本里的卡片格式。剧本进行中输入框锁住或只接剧本内回答；跳过 key 的人一直停在本地模式，回复要有兜底（「先配把钥匙我才能真聊」）。
- **mac**：旧引导只有 iOS。小芽楼层在 mac 楼层列表里也会出现，page1 房间两端都要有；mac 首启要不要走引导待定。
- **小芽改名 / 人设覆写**：`xiaoya.personaOverride` 还在，人设能被整体替换——跟「始终是向导」是否冲突要一并定。
