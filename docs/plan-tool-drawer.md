# plan · 工具抽屉（Prompt 子应用里逐个开关工具）

> ✅ 10-14 粟粟批：Q1–Q11 都按推荐。排在参数自适配之后做（两单都改 ChatService）。

> 来源：任务书 `~/Desktop/cc-rp/API链路/派单/prompt-工具抽屉.md`。粟粟 10-14 原话：「工具有一大堆……应该弄一个工具抽屉（每个工具随时可以开关），先放到 prompt 子应用里」。
> 基线：`zone/backend-2`（#089 请求体修复之后的代码），行号都以这份为准。
> 不在本单：CC 楼层（工具由 Claude Code 自带）、本机模型（不发工具）、小芽自己的工具（`AssistantTools`，另一套）。

---

## 0. 一句话方案

在 `ToolGateContext` 里加一份「抽屉快照」，注册表按它分三态：**直接给 / 收在〔更多工具〕/ 关**。
- 默认值 = 现在的分法（`tuckedNames` 里的收起，其余直接给），所以不动抽屉时，tools 数组、system、金样一个字节都不变。
- 抽屉只能**收窄**：上游开关（权限域、记忆开关、卡级工具开关、工具总开关）关着的工具，抽屉里开着也不发。
- 注入、〔更多工具〕、能力说明、执行前复查、元工具目录都从注册表取，所以接一处全跟着变。

---

## 1. 现状（带出处）

### 1.1 门控链路：一个内建工具要过几道门才进请求

| 层 | 在哪 | 管什么 |
|---|---|---|
| ① 卡级开关 | `ConversationViewModel.swift:3299–3301`（`provider.toolsSupported == false` → `.cardToolsOff`） | 这张卡不支持 function calling：整轮不发工具 |
| ② 工具总开关 | `CVM:3303`（`PermissionCenter.capabilityEnabled(.toolsMaster)` → `.masterOff`） | 设置 · 权限 / 设置 · MCP 里的「工具调用」，关了整轮不发 |
| ③ 平台 / 上游特例 | `CVM:3313–3314` | CC Bridge、本机模型不发 |
| ④ 注册表门控 | `ToolRegistry.swift:16–87` 每个 `Entry.enabledIf` | **按权限域或功能开关**，不按单个工具（见 1.2） |
| ⑤ 直接给 / 收起 | `ToolRegistry.swift:91–105` `tuckedNames`（静态，只随平台变）；`:139–147` `inlineDefinitions` / `tuckedDefinitions` | 收起的不进 tools 数组，进〔更多工具〕，经 `tool_invoke` 调 |
| ⑥ 元工具 | `ToolRegistry.swift:81–84` | `deferMCP`（MCP > 16 个）或有收起的内建工具时，才发 `tool_search / tool_inspect / tool_invoke` |
| ⑦ 拼 tools 数组 | `CVM:3323–3355` | 内建（注册表）+ MCP（`MCPProvider`）+ Anthropic 服务端 `web_search`，**按名字字典序排**（`:3355`，缓存前缀） |
| ⑧ system 说明 | `CVM:3356–3397` | 文件库模板、〔外部工具〕/ MCP 段、〔更多工具〕（`:3367–3371`，blurb 取 `tuckedBlurbs`）、设备说明、〔回忆〕、〔我的记忆〕、搜索提示，末尾 `capabilitySection(tools)`（`:3396`） |
| ⑨ 执行前复查 | `CVM:4057–4066`（`ToolRegistry.availability(of:)`，`ToolRegistry.swift:152–157`） | 模型照着历史叫一个这一轮没发的内建工具 → 回「没开」错误，不执行 |
| ⑩ 权限闸 | `CVM:4068` `toolPermissionGate` | askOnce 弹卡 / notAllowed 拒 |

`ToolGateContext`（`ToolDefinition.swift:16–29`）现在只装 `family / deferMCP / profileId`；建它的地方只有两处：注入 `CVM:3318`、工具循环每轮的 `toolGate`（`CVM:3271–3277`，在 `:4018` 每次回调里现算）。

### 1.2 「按域」门控的实际分组（注册表 39 件，mac + 非 PERSONAL 计；`ToolRegistryTests.swift` 断言 39 / 40）

| 组 | 工具（默认态） | 上游门 |
|---|---|---|
| 文件库 | fs_list / fs_read / fs_search / fs_write / fs_append / fs_edit（直接给）；fs_rename / fs_delete / update_profile_card（收起） | 权限域 `.fileLibrary`（`ToolRegistry.swift:20–24`） |
| 记忆 | remember / edit_memory / forget_memory（直接给） | 记忆总开关 `MemoryFlags.masterEnabled`（`SelfMemoryTool.swift:11`） |
| | recall（直接给） | 设置 · 记忆「对话历史搜索」`mem_content_convhistory`（`RecallTool.swift:12–14`） |
| | inner_voice（直接给） | 记忆总开关 + 「心声」`mem_content_heartvoice`（`InnerVoice.swift:10–12`） |
| 设备 | calendar_query / calendar_create（直接给）、calendar_delete（收起） | `.calendar` |
| | reminders_query / reminders_create（直接给）、reminders_complete（收起） | `.reminders` |
| | clipboard_read（收起） | `.clipboard` |
| | notify_schedule（直接给） | `.notifications` |
| | ocr_image / open_url / device_info（收起） | 只随工具总开关（`PermissionCenter.swift:195`） |
| | run_command（mac 直接给 / iOS 收起，`ToolRegistry.swift:98–100`） | `.shell` |
| 推特 | local_twitter（收起） | `.twitter` |
| 搜索 | web_search（Anthropic 服务端工具，**不在注册表**，`CVM:3333–3336`） | `.webSearch` |
| | search_web（OpenAI 系 + 配了搜索后端）、browse_url（OpenAI 系） | `.webSearch`（`ToolRegistry.swift:57–66`） |
| 其他 | ask_user / roll_dice / card_guide（直接给，常开） | 只随工具总开关（`:48–54`） |
| | code_search / code_list_sessions / code_get_session / code_list_projects（mac，收起） | `.codingSessions` |
| | tool_search / tool_inspect / tool_invoke | 自动（⑥） |
| （隐藏） | death_scale（PERSONAL_APPS） | 按楼层授权（`:31–36`）——**隐藏子应用，抽屉里不列** |

→ 现在想「只关 fs_write、留 fs_read」做不到，只能整个文件库域关掉。

### 1.3 MCP 特例
- 工具清单来自 `MCPProvider.enabledTools(for:)`（`MCPProvider.swift:240–253`）：server.enabled + 每个 tool 自己的 `tool.enabled`。
- 单个工具开关已经有：设置 · MCP 每个 tool 一个 Toggle（`MCPSettingsView.swift:207–209` → `MCPProvider.setToolEnabled`，`:132–143`），持久化在 `mcp_servers_v1`，**全局**，不分楼层。
- 执行端 `callToolText`（`:284–286`）也按 `enabledTools` 查，关掉的工具调不到 → 天然有执行前复查。
- 收起：MCP 不能逐个收，**超过 16 个整体收进目录**（`CVM:3265` `mcpDeferThreshold`、`:3322`）。

### 1.4 Anthropic 服务端 web_search 特例
- 形状 `{type: web_search_20250305, name: web_search, max_uses}`（`WebSearchToolService.swift:31–41`），API 服务端执行。
- 不能收进〔更多工具〕：`tool_invoke` 是客户端元工具，调不到服务端工具。
- `ToolReplay.clientToolNames` 不算它（`ToolReplay.swift:195–199`），历史回放不涉及。

### 1.5 现在界面上能看到工具的地方
- Prompt 页「用量 · 缓存 · 上下文」仪表盘展开后有「AI 工具（本对话实发 N 个）」只读清单（`PersonaSettingsTab.swift:1035–1075`），底下一行「开关：文件库→设置·文件库｜回忆·心声→设置·记忆｜MCP→设置·MCP」（`:1069`）。
- 设置 · 权限「AI 能做什么」（`PermissionsSettingsTab.swift:128–150`）按域三档。

### 1.6 「Prompt 子应用」在哪
- page2 的 prompt 子应用：`MemoryPanelView.swift:103–104` → `PersonaSettingsTab(useSheetNavigation: true, viewModel: viewModel)`；page2 资料库分在「创作与资料」（`Page2LibraryView.swift:27`）。
- 设置 → Prompt：`SettingsView.swift:226`（Pro 模式才是 `PersonaSettingsTab()`，Lite 是 `LitePersonaPage`）、mac `:548`。这里 `viewModel == nil`，没绑对话。
- 两处是同一个 View，页面主干 `iOSPromptPageContent`（`PersonaSettingsTab.swift:1585–1734`），从上到下：预设（`:1604`）→ 用量·缓存仪表盘（`:1610–1615`）→ 模式选择器（`:1618–1623`）→ 按模式切换的内容 → iOS「相关」（`:1669`）。

---

## 2. 改法（按任务书「要做」1–5）

### 2.1 抽屉入口和页面（要做 1）

**位置**：Prompt 页，「用量 · 缓存 · 上下文」仪表盘和模式选择器之间，新加一个 Section，只放一行入口：

```
┌──────────────────────────────────────────────┐
│ 🧰 工具抽屉                                    │
│    直接给 21 · 收起 9 · 约 4.6k token        ›  │
└──────────────────────────────────────────────┘
```

点进去是单独一页 `ToolDrawerPage`（新文件）：
- iOS：`NavigationLink`（同「相关」组的写法）；
- page2 / 右栏（`useSheetNavigation == true`）：照 `SlotNavigationModifier` 的做法用 sheet；
- mac 设置页：`SettingsNavRow(.toolDrawer)`，`SettingsRoute` 加一个 case。

不直接铺在 Prompt 页里：Prompt 页已经很长，而且有防抖预览任务（#00207 卡顿返工就在这一页），抽屉单独一页，重算只在这页开着时跑。

仪表盘里「AI 工具」只读清单保留（它是「这一轮实发了什么」），底下那行改成「逐个开关：工具抽屉」，点了跳过去。

**页面长相**（暖奶白底 `Theme.mainBg`，卡片底 `Theme.assistantBubble.opacity(0.5)`，开关着色 `Theme.branchIndicator`（默认主题是薄荷），次要字 `Theme.textMuted`；不用蓝、不用黄，提示行也只用 `textSecondary`，不做黄色警示）：

```
工具抽屉
┌──────────────────────────────────────────────────┐
│ 范围   [ 全局 ][ 本楼层 · {floorName} ]             │
│                                                  │
│ 本轮下发 21 个工具 · 收起 9 个 · 约 4.6k token      │
│ 按这个对话的模型「{modelName}」算：                  │
│ 工具定义约 3.1k + 工具说明约 1.5k（粗估）             │
│ ⓘ 工具变了：下一轮整段缓存重写一次，之后恢复命中。      │ ← 只在和上次实发不同时出现
│   改几个再发，也只断这一次。                          │
└──────────────────────────────────────────────────┘

文件库                                  权限：自动允许 ▾
┌──────────────────────────────────────────────────┐
│ fs_read     {assistantName} 读文件库里的文件          │
│             直接给                 [直接给 ▾]  (  ●) │
│ fs_write    {assistantName} 新建或整篇覆盖写文件       │
│             关                                (●  ) │
│ fs_delete   {assistantName} 删文件库里的文件          │
│             收在更多工具           [收起 ▾]   (  ●) │
│ …                                                │
└──────────────────────────────────────────────────┘

设备
┌──────────────────────────────────────────────────┐
│ calendar_query  {assistantName} 查你的日历           │
│                 权限：不允许 · 去权限页 ›     (⊘ 灰) │
│ notify_schedule {assistantName} 到点给{userName}发通知 │
│                 直接给                 [直接给 ▾] (  ●)│
└──────────────────────────────────────────────────┘

搜索
│ web_search      服务端搜索（Anthropic 卡）            │
│                 直接给 · 这个工具不能收起        (  ●) │
│ search_web      这一轮用不到（Anthropic 卡用服务端搜索）│

其他
│ tool_search / tool_inspect / tool_invoke             │
│                 自动：有收起的工具时才给（不能手动关）   │

MCP · {serverName}                         去设置 · MCP ›
│ some_tool       {描述第一句}                   (  ●) │
│                 超过 16 个时整体收进目录（现在 23 个）   │
```

一行的结构：工具名（等宽小字）+ 一句话说明 + 状态字（`直接给` / `收在更多工具` / `关`，被上游关掉时写原因）；右边一个 Toggle，开着时左边多一个小菜单「直接给 / 收起」。iPhone 窄屏时说明折两行，菜单和开关不挤。

**分组**：文件库 / 记忆 / 设备 / 推特 / 搜索 / 其他 / MCP（按 server 再分）。分组和说明写在一份新的 `ToolDrawerCatalog`（新文件），按工具名查：组、给人看的一句话（人名一律用 `assistantName` / `userName` 变量渲染，不写死）、上游门的说明（「权限 · 文件库」「设置 · 记忆 · 对话历史搜索」「常开」）。和 `tuckedBlurbs`（给模型看的第二人称）分开放，两边受众不同。**death_scale 不进目录、不出现在抽屉**（隐藏子应用规矩）；它照旧按楼层授权发，抽屉不管它。

**范围切换**（Q1 推荐方案）：
- 「全局」：改的是所有楼层的默认；
- 「本楼层」：没单独改过的行显示小字「跟随全局」；改了就记成本楼层覆盖，行上长按（mac 右键）「恢复跟随全局」，页底一个「本楼层全部恢复跟随全局」。

**设置 → Prompt（没绑对话）**：抽屉能改，顶上数字那块显示「设置页没有绑定对话——到聊天里的 Prompt 看这一轮实发」（和现有 `unboundTurnNotice` 同一句）；范围切换照常（楼层取当前楼层）。

**入口范围**：只加在 Pro 的 `PersonaSettingsTab`；Lite 的 `LitePersonaPage` 不加（Q10）。设置搜索（`SettingsSearch.swift`）加一条「工具抽屉」，关键词：工具 / 抽屉 / tools / 开关。

### 2.2 开关真生效（要做 2）

**数据**：
```
enum ToolDrawerMode: String, Codable { case inline, tucked, off }

struct ToolDrawerState: Equatable {
    var global: [String: ToolDrawerMode]               // 只存和默认不同的
    var floors: [String: [String: ToolDrawerMode]]     // profileId → 覆盖
    static let defaults = ToolDrawerState(global: [:], floors: [:])
    func mode(_ name: String, profileId: String?) -> ToolDrawerMode
        // 本楼层覆盖 ?? 全局 ?? ToolRegistry.defaultMode(name)
}
```
- 存 UserDefaults 一个键 `toolDrawer.v1`（JSON，几十个条目，不会撑大 defaults 域）。
- `ToolDrawerStore`（`@MainActor @Observable`，单例）：启动读一次，内存里拿快照；改动写回并 `version += 1`。不写文件，所以组 prompt 的主线程不新增读盘（MainThreadIOBudget 不动）。
- 不认识的名字（以后删了的工具）读的时候忽略，不报错。
- 每台设备各记各的，不跨设备同步（同权限档位）。

**接到注册表**（`ToolRegistry.swift`）：
- `ToolGateContext` 加 `drawer: ToolDrawerState`，**默认参数 `.defaults`**——现有测试、调用不用改就是现状。
- 两个建 gate 的地方（`CVM:3318`、`CVM:3271–3277`）传 `ToolDrawerStore.shared.state`。
- `tuckedNames` 改名 `defaultTuckedNames`（语义变成「默认收起」）；新增 `defaultMode(name)`。
- `enabledDefinitions(ctx)`：在 `enabledIf` 之外再要求 `mode != .off`。
- `inlineDefinitions` / `tuckedDefinitions`：按 `mode == .inline / .tucked` 分，不再按静态集合。
- 元工具（`:81–84`）：门控改成「`deferMCP` 或有任一 `enabledIf && mode == .tucked` 的内建工具」；元工具本身不吃抽屉状态（Q4）。
- `availability(of:)`：`mode == .off` → `false`。执行前复查（⑨）、`toolUnavailableMessage`（「设置里关着」→ 改成「设置或工具抽屉里关着」）照旧。
- 新增 `blurb(for:)`：`tuckedBlurbs[name] ?? 描述第一句`（第一句的切法和 `capabilitySection` 一致，抽成一个共用小函数）。〔更多工具〕（`CVM:3370`）和 `MetaTools.search`（`MetaTools.swift:50`）都改调它——用户自己收起的工具（比如 fs_write）没有手写 blurb，也有一句话。

**其他吃「这一轮有哪些工具」的地方，自动跟着变**（都从 `builtinNames` / `tools` 取）：设备说明段、到点提醒分流（`DeviceToolDispatcher.timingHint`）、〔回忆〕、〔我的记忆〕（看 remember 在不在）、搜索提示、`capabilitySection`、`CardGuideTool.isOffered`（card_guide 关了 → 卡片写法全文回到 system，见 Q5）。

**服务端 web_search**：`CVM:3334` 的条件加一项「抽屉里 web_search 不是关」。只有开 / 关两态。

**和权限域的关系**（Q2 推荐：并存，抽屉只收窄）：
- 生效 = 上游门开 **且** 抽屉不是关。抽屉开着、权限关着 → 不发；抽屉不能越过权限。
- 界面不打架的做法：
  - 组正好对应一个权限域的（文件库 / 推特 / 搜索），组头右侧直接放 `PermissionLevelPicker(domain:)`——就是权限页那个控件，读写同一个 `PermissionCenter`，两处天然同步（`MCPSettingsView.swift:101` 已经这样复用过工具总开关）；
  - 设备组一行一个域，行下小字写「权限：每次询问」；
  - 上游关着的行：开关变灰、状态写原因 +「去权限页 ›」/「去设置 · 记忆 ›」，**抽屉自己的状态保留**，上游一开就按抽屉状态生效；
  - 工具总开关关着 / 卡不支持工具 / CC / 本机模型：顶部那块直接说原因（复用 `toolsAbsentText`），整页行变灰，还能改（改的是下次生效的状态）。
- 权限页那边不加东西，只在「AI 能做什么」组 footer 加一句「单个工具的开关在 Prompt → 工具抽屉」。

**MCP**（Q3 推荐：进同一抽屉，只开关、只全局）：
- MCP 组的 Toggle 直接调 `MCPProvider.setToolEnabled`——和设置 · MCP 是同一个真相源，不另存一份。
- 不能逐个收起（> 16 个整体收进目录的现状不变），行下说明写「超过 16 个时整体收进目录（现在 N 个）」；改开关可能让总数跨过 16，界面上顶部数字会跟着跳。
- 没有楼层覆盖：在「本楼层」范围下 MCP 组标「全局」，开关照样改全局。
- 存储键用 `mcp:<serverId>/<toolName>` 只在界面层区分，和内建同名的 MCP 工具照旧被 `reserved` 挡掉（`CVM:3405`）。

### 2.3 每行切「直接给 / 收进更多工具」（要做 3）
- 内建工具都能切（包括默认收起的改成直接给，比如 fs_delete）。
- 不能切的，菜单不出现，状态字后面写原因：
  - web_search（服务端，tool_invoke 调不到）；
  - 元工具三件（它们本身就是「更多工具」的门）；
  - MCP（见上）。
- 收起后：不进 tools 数组，进〔更多工具〕（blurb 见 2.2），`tool_search` 能搜到，`tool_invoke` 能调，直接叫名字也照常执行（现状如此，`MetaTools` 注释）。
- `unwrapTuckedInvoke`（`CVM:3241–3250`）现在看静态 `tuckedNames`，改成吃这一轮的收起集合：`unwrapTuckedInvoke(call, tucked: Set<String>)`，工具循环里用 `gate` 算出的 `tuckedDefinitions(gate)` 名字（`CVM:4036` 附近，`gate` 在 `:4018` 已经有）。关着的工具被 `tool_invoke` 包着叫 → 不拆 → 交给 `handleMetaTool` → `reserved` 命中 → 回「不在更多工具里…这一轮没开」（现有文案，`CVM:3414–3415`）。

### 2.4 顶部「本轮下发 N 个、约 X token」（要做 4）
- 来源：新增 `CVM.previewTools(model:providerManager:profileId:) -> ToolDrawerPreview`，内部就是 `toolInjectionDetailed(... silent: true)`——和实发同一个函数，不另算（「预览 = 实发」的规矩）。不跑 `composePrompt`，所以比 Prompt 页的整轮预览便宜得多。
- 算：
  - N = `tools.count`（含元工具、服务端 web_search、MCP）；
  - 收起 = `tucked.count`；
  - token ≈ `TokenEstimator.estimate`（tools 数组按 sortedKeys 序列化）+ `TokenEstimator.estimate(systemHint)`；分开显示「工具定义 / 工具说明」两段，标「粗估」。
  - API 自己给工具加的那段隐藏系统提示不算（Anthropic 有，数量没核，**未查证**）。
- 刷新：页面 `.task(id: drawerVersion + model + profileId)` 防抖 0.25 秒再算，只在页面在屏幕上时算（照 `promptPageOnScreen` 那套），不在 body 里同步算。
- Prompt 页入口那一行的数字同源：用同一个 `previewTools`，入口行自己的 `.task` 防抖。
- **顺手修**：Prompt 页整轮预览的防抖键 `PromptPreviewKey`（`PersonaSettingsTab.swift:1407–1412`）现在只有楼层 / 预设 / 模型，抽屉一改仪表盘「AI 工具」和组装 / 请求页不会刷新——键里加 `ToolDrawerStore.shared.version`。

### 2.5 顺序稳定 + 缓存提示（要做 5）
- 顺序：tools 数组仍是 `CVM:3355` 按名字字典序排，抽屉不引入任何别的顺序；〔更多工具〕仍按名字排（`:3324`）；`capabilitySection` 跟 tools 顺序。开关不变，字节不变。
- 断几次：工具定义排在缓存前缀最前面，改任何一个开关 → 下一轮 tools + system + 历史整段重写一次缓存，之后恢复命中。连着改几个再发，只断一次。
- 提示一句：
  - 实发时（`CVM:3046 / 4890 / 5023` 三处真发送调 `toolInjection` 的地方）记一个「工具签名」= tools 名字列表 + 收起名字列表，存在 `ToolDrawerStore` 内存里，按对话存，不落盘；
  - 抽屉页 / 入口行算出的当前签名和它不同 → 显示「ⓘ 工具变了：下一轮整段缓存重写一次，之后恢复命中。改几个再发，也只断这一次。」；
  - app 重启后没记录 → 不显示（不猜）。
  - 不读 SentRequestStore 的盘，也不解析 body 文本。

---

## 3. 和 #089 的接口

### 3.1 capabilitySection（〔当前能用的工具〕）
- 吃的是最终的 `tools` 数组（`CVM:3396` / `:3599–3610`），所以关掉的工具自动不在里面，收起的也不在（收起的在〔更多工具〕，这段末尾已写「〔更多工具〕里列的也能用」）。不用改它。
- 已知不一致（不在本单修）：文件库模板（`FileLibraryTools.defaultInjectionTemplate` / 用户自定义模板）里写死了 fs_* 的名字。只关掉 fs_write 时，模板还会提到 fs_write。能力说明段里写了「冲突时以这里为准」，执行前复查也会拒。要不要按工具裁模板，见 Q11。

### 3.2 历史里调过、这一轮关掉的工具：wireOrdered 退纯文字
现状（`ToolReplay.swift:185–206`）：
- `wireCall`：一个调用的名字不在这一轮 tools 里，**只要 tools 里有 tool_invoke 就包成 tool_invoke**；
- `wireOrdered`：包完还不在清单里的，那条回复退纯文字 +〔系统记录〕。

抽屉让「关掉的工具」变多，这里有个错位：某工具被关了，但这一轮恰好有 tool_invoke（别的工具收起着），历史里对它的调用会被包成 `tool_invoke{name: fs_write}` 发出去——等于告诉模型「你之前是通过更多工具调的它」，模型照做再调一次，只会拿到「没开」。

改法：
- `ToolReplay` 加一个纯函数 `offeredOnly(_ ordered:, offered: Set<String>)`：某条回复里有调用的名字 ∉ offered → 只这条走 `textFallback`。
- offered = `clientToolNames(tools)` ∪ 这一轮收起的内建名字。
- 放在两个已有的 `orderedForProvider` 调用点旁边（实发 `CVM:2551`，检查器 `TurnPreview.requestBody` `CVM:5405`），两边同一个函数，预览 = 实发。`TurnPreview` 已经带 `tuckedTools`（`:5393`），不用加字段；实发那边从 injection 结果拿 `tucked`。
- 这样到 ChatService 时，剩下不在 tools 里的调用一定是「收起的」，`wireCall` 包回 tool_invoke 是对的；ChatService 不用改。
- 这一步不限于抽屉：权限域关掉的工具也走它（以前同样会被错包）。默认设置下 G1–G6 金样历史里没有这种调用，预期不变（实现时以金样为准，见 §5）。

### 3.3 tool_invoke 包回
- 收起 → 直接给（比如把 fs_delete 改成直接给）：历史里当时经 tool_invoke 调的 fs_delete（节点存的是内层名字），以后按直接调用发。和「当时实际发的」字节不同，但只在改开关那一轮断一次缓存，语义也对。
- 直接给 → 收起（比如把 fs_write 收起）：历史里直接调的 fs_write，以后包成 tool_invoke 发——就是 #089 对收起工具定的规矩，不新增情况。
- `unwrapTuckedInvoke` 改吃动态收起集合（2.3）。`ToolTuckingTests` 的拆包用例跟着改签名。

### 3.4 金样会怎么变
| 金样 | 抽屉默认状态 | 说明 |
|---|---|---|
| `Fixtures/tools-schema-golden.json`（`ToolRegistryTests.testSchemaMatchesGoldenFixture`） | **不变** | 定义本身一个字没动 |
| `Fixtures/prompt-golden/G1–G6`（PromptRealPathGoldenTests） | **不变，不许重录** | 默认态 tools / system / 历史和现在逐字节一样；3.2 的 pre-pass 在默认态下对 G1–G6 是空操作（实现时如果红了，先查是不是夹具里有被权限关掉的历史调用，再决定） |
| InspectorRealPathTests | 不变 | 新增一例「抽屉关一个、收一个：预览 = 实发」 |

**测试宿主隔离**：抽屉存在真 UserDefaults。粟粟本机改过抽屉的话，测试宿主会读到她的设置把金样弄红。`PromptRealPathHarness`、`MainThreadIOBudgetTests`、`ToolRegistryTests` / `ToolTuckingTests` 都要把 `toolDrawer.v1` 存原值 → 清掉 → tearDown 还原（harness 已有 `setDefault` 这套，`PromptRealPathHarness.swift:105–116`）。`ToolDrawerStore` 另给测试一个重载入口（读 defaults 之后刷新内存快照）。

---

## 4. 测试

**新增**：
- `ToolDrawerTests`（新文件）：
  - 默认态的分法 = 改造前的 `inlineDefinitions / tuckedDefinitions`（逐个名字比，mac / iOS 各自平台）；
  - 楼层覆盖优先于全局，「恢复跟随全局」删掉覆盖；
  - `.off` → 不在 enabled / inline / tucked，`availability == false`；上游门关着时抽屉开着也是 false；
  - 用户收起一个默认直接给的（fs_write）→ 进 tucked、元工具出现、`blurb(for:)` 回描述第一句；
  - 全部收起的都关了、又没 deferMCP → 元工具消失；
  - JSON 存取往返、未知名字忽略；
  - `ToolDrawerCatalog` 覆盖注册表全部工具（death_scale 除外），每个都有组和一句话；目录里没有 death_scale。
- `ToolReplayTests`：`offeredOnly`——关掉的工具那条退纯文字，收起的不退、交给 wireCall 包回。
- `ToolTuckingTests`：动态收起集合下的拆包（用户收起的 fs_write 能拆；关掉的不拆）；`testEveryTuckedToolHasABlurb` 改成「每个工具 `blurb(for:)` 非空」。
- capabilitySection：关一个工具后这段里没有它（纯函数，喂 tools 数组）。
- InspectorRealPathTests：抽屉关一个、收一个、楼层覆盖一个 → 预览 tools / system / body = 实发。
- 签名比较（缓存提示）：同样的工具 → 不提示；改一个 → 提示；只改顺序以外的东西（不可能发生，断言签名按名字排序）。

**会动的现有测试**：
- `ToolTuckingTests`（`tuckedNames` → `defaultTuckedNames`、拆包签名）；
- `ToolRegistryTests.testAvailabilityRecheck` 加抽屉用例（其余不动）；
- 三个夹具 / harness 加抽屉键隔离。

**必跑**（mac 定向，grep 到每个目标类的「Test Suite … passed」才算）：
- `ToolRegistryTests`（工具金样）、`ToolTuckingTests`、`ToolReplayTests`、`ToolDrawerTests`；
- `PromptRealPathGoldenTests` G1–G6（不重录）、`InspectorRealPathTests`；
- `MainThreadIOBudgetTests`（上限不许上调；抽屉只读内存）；
- `PermissionCenterTests`、`CardGuideToolTests`、`TurnStatusNoteTests`（顺带）。
- 双端 build-for-testing 交集成区（iOS 用 MemoryPalaceIOS + iOS 26 模拟器，只认 SUCCEEDED）。

---

## 5. 风险

- **缓存**：每改一次开关，下一轮整段缓存重写（工具定义在前缀最前）。长对话一次全价写入约 1.25 倍输入价。界面已提示；改法是「改完再发」。
- **测试宿主读她的真抽屉**：不隔离会让金样在她机器上红、在集成区绿（或反过来）。§3.4 已列隔离。
- **MCP 跨阈值**：在抽屉里开关 MCP 工具可能让总数跨过 16，整批在「直接给」和「收进目录」之间跳，tools 数组大变。界面会显示，不拦。
- **说明文字和工具对不上**：文件库模板写死工具名（Q11）；〔我的记忆〕段只看 remember 在不在：关 remember、留 edit_memory 时这段整段不出现。都由「能力说明为准」+ 执行前复查兜住，不会真执行。
- **ask_user / roll_dice / card_guide 关掉**：ask 卡 / 骰子卡不再由工具产生；card_guide 关掉后卡片写法全文回到 system（变大，行下会提示）。
- **工具循环中途改开关**：这一轮的 tools 数组在开头定了不变（缓存稳）；执行前复查每次现读（`CVM:4018`），中途关掉的工具下一次调用就拒。可接受。
- **Prompt 页预览不刷新**：§2.4 把抽屉版本加进 `PromptPreviewKey`，漏了就会出现「抽屉改了、仪表盘还是旧的」。
- **mac 导航**：mac 右栏宿主里推入页别带 `.navigationTitle`、嵌套 NavigationStack 推入页会盖住整列（两条老教训）。mac 右栏走 sheet，设置页走 `SettingsNavRow` 路由。
- **跨设备**：抽屉存本机 UserDefaults，iPhone 和 Mac 各一份。
- **不读盘**：抽屉数据只在 UserDefaults；预览走 `silent: true`，不写 breadcrumb（`CVM:3286–3288` 那个死循环教训）。

---

## 6. 要粟粟拍板（每条第一个是推荐）

- **Q1 开关按什么范围记**
  - **A（推荐）全局默认 + 楼层可覆盖**：楼层人设差别大（有的楼层不该有文件库写权限），一份数据结构就能装下；楼层覆盖单独一个 commit，不要可以整个撤。
  - B 只全局：最简单，但楼层之间没法区分。
  - C 跟预设走（存进 Preset）：导出预设会带上工具配置、预设 JSON 变形状、Prompt 预览键要跟着变，牵连大。
- **Q2 权限域开关和抽屉的关系**
  - **A（推荐）并存，抽屉只收窄**：生效 = 上游开且抽屉不关；组头 / 行下直接放权限页同一个控件（同一个真相源，不会两处不同步）；上游关着的行变灰并写原因。权限还管「每次询问」和注入类，抽屉只管「发不发、怎么发」，职责不重叠。
  - B 合并：抽屉取代权限页「AI 能做什么」。一个域管好几个工具、还有三档，塞进一行开关说不清；权限页还有注入类，拆不干净。
  - C 并存但抽屉不显示权限状态：会出现「抽屉开着、实际没发」，她看不懂。
- **Q3 MCP 进不进同一个抽屉**
  - **A（推荐）进，按 server 分组，只开关、只全局，直写 MCPProvider**：和设置 · MCP 同一真相，不多一份；收起照旧按 16 个阈值整体走。
  - B 进，并且能逐个收起、能按楼层覆盖：要在 MCP 之上再加一层过滤，两处开关会出现不一致，阈值逻辑要重写。
  - C 不进，只放「去设置 · MCP」跳转。
- **Q4 元工具（tool_search / inspect / invoke）能不能手动关**
  - **A（推荐）不能**，只读一行「自动：有收起的工具时才给」。关了收起的工具就全调不到。
  - B 能关，关了等于把所有收起的工具一起关。
- **Q5 常开三件（ask_user / roll_dice / card_guide）能不能关**
  - **A（推荐）能**：「每个工具随时可以开关」。card_guide 行下写「关了：卡片写法全文放进系统提示（约 +X token）」。
  - B 不能，只读。
- **Q6 历史里调过、现在关掉的工具怎么发**
  - **A（推荐）那条回复退纯文字 +〔系统记录〕**（§3.2 的 pre-pass），不包成 tool_invoke 误导模型。
  - B 照旧：tools 里有 tool_invoke 就包。
- **Q7 服务端 web_search**
  - **A（推荐）只给开 / 关**，不能收起（tool_invoke 调不到服务端工具）。
- **Q8 设置 → Prompt（没绑对话）里能不能改抽屉**
  - **A（推荐）能改**，顶上数字那块写「到聊天里的 Prompt 看这一轮实发」。
  - B 只读，必须从聊天 / page2 进。
- **Q9 抽屉改了要不要有「恢复默认」**
  - **A（推荐）有**：页底「全部恢复默认」（全局范围）/「本楼层全部恢复跟随全局」（楼层范围），点了二次确认。
  - B 没有。
- **Q10 Lite 模式（`LitePersonaPage`）要不要入口**
  - **A（推荐）不加**，Pro 才有（Lite 本来就不碰工具细节）。
  - B 加。
- **Q11 只关了部分 fs_* 时，文件库模板里的工具名要不要裁**
  - **A（推荐）这单不裁**：能力说明段说了「以这里为准」，执行前复查兜底；模板是你能自己改的文字，按工具裁会碰你的自定义模板。
  - B 默认模板按开着的工具裁（只裁默认模板，不动自定义的）。

> death_scale 不进抽屉：不是问题，是规矩（隐藏子应用，任何入口不暴露），直接这么做。

---

## 7. 执行清单（每项单独 commit，可单独撤）

- [x] ✅ 1 数据层：`ToolDrawerMode` / `ToolDrawerState`（默认 + 楼层覆盖解析 + JSON 存取）+ `ToolDrawerStore`（UserDefaults `toolDrawer.v1`、内存快照、version、测试重载入口）+ `ToolDrawerTests` 的数据部分
- [x] ✅ 2 注册表接抽屉：`ToolGateContext.drawer`（默认 `.defaults`）、`defaultTuckedNames` / `defaultMode`、enabled / inline / tucked 按 mode 分、元工具门控、`availability` 认 `.off`；更新 `ToolTuckingTests` / `ToolRegistryTests`；工具金样必须不动
- [x] ✅ 3 `blurb(for:)` + 第一句切法共用：〔更多工具〕和 `MetaTools.search` 改调它；单测
- [x] ✅ 4 CVM 两处建 gate 传抽屉快照；服务端 web_search 认抽屉；`toolUnavailableMessage` 文案
- [x] ✅ 5 `unwrapTuckedInvoke` 吃动态收起集合，工具循环里传 `tuckedDefinitions(gate)`；单测
- [x] ✅ 6 `ToolReplay.offeredOnly` + 实发 / 检查器两处接上；`ToolReplayTests` + InspectorRealPath 新例
- [x] ✅ 7 测试隔离：`PromptRealPathHarness`、`MainThreadIOBudgetTests`、注册表相关测试清 / 还原 `toolDrawer.v1`；跑 G1–G6（不重录）、InspectorRealPath、MainThreadIOBudget
- [x] ✅ 8 `ToolDrawerCatalog`：分组、给人看的一句话（`assistantName` / `userName` 变量）、上游门说明；不含 death_scale；覆盖测试
- [x] ✅ 9 `CVM.previewTools` + token 粗估 + 实发记工具签名（内存）；签名比较单测
- [x] ✅ 10 `ToolDrawerPage`：范围切换、顶部统计 + 缓存提示、分组行（Toggle + 直接给 / 收起菜单 + 状态字 + 上游原因 / 跳转）、恢复默认
- [x] ✅ 11 MCP 组：按 server 分组，Toggle 直写 `MCPProvider.setToolEnabled`，阈值说明
- [x] ✅ 12 Prompt 页入口行（仪表盘和模式选择器之间）：iOS NavigationLink / 右栏 sheet / mac `SettingsRoute.toolDrawer`；仪表盘「AI 工具」底行改成跳抽屉；`PromptPreviewKey` 加抽屉 version
- [x] ✅ 13 权限页「AI 能做什么」footer 一句 + 设置搜索条目
- [x] ✅ 14 mac 定向全跑（§4 必跑清单，逐个 grep「Test Suite … passed」）+ 双端 build-for-testing 交集成区
- [x] ✅ 15 astra 审一轮、逐条裁
- [x] ✅ 16 复盘 `docs/review-tool-drawer.md`（含「说明书 manual/facts 已同步 / 不涉及」一项）+ 验收说明 `~/Desktop/cc-rp/API链路/工具抽屉-验收.md`（含：关一个 / 收一个后检查器「下一轮预览」怎么核、缓存提示什么时候出现）
- [ ] ⏳ 17 （粟粟点头后）一次真请求：关一个工具、发两轮，看第二轮缓存恢复命中
