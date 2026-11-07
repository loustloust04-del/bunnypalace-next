# review · 工具抽屉（#093）

> plan：[plan-tool-drawer.md](plan-tool-drawer.md)（粟粟 10-14 批 Q1–Q11 按推荐）。
> 验收说明：`~/Desktop/cc-rp/API链路/工具抽屉-验收.md`。

## 做了什么（按提交，对应 plan §7 执行清单）

| 步 | 提交 | 内容 |
|---|---|---|
| 1 | `fbc053d68` | `ToolDrawerMode` / `ToolDrawerState`（楼层覆盖 → 全局 → 默认，JSON，不认识的档位丢掉）+ `ToolDrawerStore`（UserDefaults `toolDrawer.v1`，内存快照，version，`reload`） |
| 2 | `92cf2fac5` | `ToolGateContext.drawer`（默认 `.defaults`）；`defaultTuckedNames` / `defaultMode` / `mode(of:)`；enabled 要求抽屉不是关，inline / tucked 按档位分；元工具门控看这一轮收起的；`availability` 认 `.off` |
| 3 | `6506ea7e4` | `ToolRegistry.blurb(for:)` + `firstSentence`（和〔当前能用的工具〕同一种切法）；〔更多工具〕和 `MetaTools.search` 改调它 |
| 4 | `45c1fb062` | CVM 注入 / 工具循环两处 gate 传抽屉快照；服务端 web_search 认抽屉；「设置或工具抽屉里关着」 |
| 5 | `417dba7f2` | `unwrapTuckedInvoke(call, tucked:)` |
| 6 | `65e9d4f8c` | `ToolReplay.offeredOnly`：调过这一轮调不到的工具那条退纯文字；实发 `prepareRouterPayload(offered:)` 和检查器 `TurnPreview.requestBody` 同一步 |
| 7 | `8359ba5d3` | `PromptRealPathHarness` 隔离 `toolDrawer.v1` |
| 8 | `15c950fb8` | `ToolDrawerCatalog`（分组 / 给人看的一句话 / 上游门），不含 death_scale |
| 9 | `7e3aa82ad` | `CVM.previewTools` → `ToolDrawerPreview`；三处真发送记 `ToolSignature`（内存，按对话） |
| 10 | `9f3165f96` | `ToolDrawerPage` |
| 11 | `1e0d6d05e` | MCP 组（直写 `MCPProvider.setToolEnabled`） |
| 12 | `d0f8f25b8` | Prompt 页入口行 + sheet / `SettingsRoute.toolDrawer`；仪表盘底行；`PromptPreviewKey` 加抽屉 version |
| 13 | `255a8e8ca` | 权限页「AI 能做什么」footer + 设置搜索条目 |
| 14 | `75a2fa6b3` | 定向全跑 + 双端 build-for-testing |
| 15 | `528bd089b` | astra 一轮（见下） |
| 16 | 本提交 | 复盘 + 验收说明 + `docs/now/backend-2.md` + `manual/facts/model/model-api.md` |
| 17 | 没做 | 真请求实测要粟粟点头（本单禁止真请求） |

## 和 plan 不一样的地方

- **值类型放在 `ToolDefinition.swift`**：mp-code 命令行也编这个文件（project.yml 写死 sources），`ToolGateContext` 带上抽屉后它得认识 `ToolDrawerState`。所以 `ToolDrawerState` 不认识工具，只给 `override(name, profileId)`（没改过 = nil），默认档位由 `ToolRegistry.mode(of:)` 补。plan 写的 `state.mode(...)` 没有。
- **拆包集合（第 5 步，astra #3 后）**：plan 写「用 gate 算的 `tuckedDefinitions(gate)`」。改成 `invokableBuiltins(sentTools:)` = 这一轮**发出去的清单里没有**的内建工具（不含元工具）。原因：工具循环里 tools 数组第一轮就定了，中途把某工具从收起改成直接给，模型手上的 tool_invoke 按现读的抽屉就拆不了、被 reserved 拒掉。现在关着的也会被拆开，然后被执行前复查拒，回「没开」（以前是 handleMetaTool 回「不在更多工具里…这一轮没开」，同样是拒，文案不同）。
- **offered 多了 defer 的 MCP 目录**（第 6 步）：plan 只写「清单 + 收起的内建」。加 MCP 是为了「以前 ≤16 个直接调过、现在超阈值收进目录」的历史照旧包回 tool_invoke（能调到），不退文字。
- **offeredOnly 看 tool_invoke 里包的名字**（astra #2）：MCP 经 tool_invoke 调的，节点存的是外层 `tool_invoke`。现在看包着的名字（`MetaTools.resolve` 同款容错）这一轮还在不在 offered；读不出名字的不动。
- **`TurnPreview` 加了字段 `offeredTools`**：plan 说「已带 tuckedTools，不用加」，但 offered 还含 MCP 目录，只靠 tuckedTools 算不出来。`toolInjection` 返回值多带 `tucked` / `offered`，`prepareRouterPayload` 多一个 `offered:` 参数（CC 路径不传）。
- **工具签名（第 9 步，astra #5 后）**：plan 写「tools 名字 + 收起名字」。改成「tools 名字 + 清单外调得到的名字（收起的内建 + 收进目录的 MCP）」，defer 状态下增减 MCP 也提示。
- **跳转链接没做**：plan 写行下「去权限页 ›」「去设置 · 记忆 ›」、MCP 组头「去设置 · MCP ›」。从 page2 sheet / 右栏 sheet / 设置路由三种宿主跳到另一个设置页要各写一套导航，没做。代替：文件库 / 推特 / 搜索组头直接放权限页同一个档位控件（`PermissionLevelPicker`，能当场改）；设备组、编程会话行下写「权限：每次询问」；记忆开关只写原因（「设置 · 记忆 · 对话历史搜索 关着，开了才按这里生效」）；MCP 组尾写「和设置 · MCP 里的开关是同一个」。
- **card_guide 行没写「约 +X token」**：只写「关了：卡片写法全文放进系统提示」，没算差多少。
- **开关打开时回到默认档位**：关掉再打开，回到这个工具的默认（直接给 / 收起），不记关之前是哪一档。
- **第 7 步隔离只做了 harness**：`ToolRegistryTests` / `ToolTuckingTests` 都显式建 `ToolGateContext`（drawer 默认 `.defaults`），不读 `ToolDrawerStore`，不用隔离。BudgetGate 新加的一例自己存 / 还原抽屉状态。
- **抽屉页刷新**：plan 写 `.task(id: drawerVersion + model + profileId)`。另加了「上游开关快照」（权限档位 / 记忆 / 心声 / 回忆 / 搜索服务）和 MCP 已启用数：监听 `UserDefaults.didChangeNotification`，但只在快照真变了才改状态（页面自己算数字时碰到的写入不会让它绕圈）。
- **设置页（没绑对话）入口行**只写「逐个开关 AI 能用的工具」，不显示数字（数字要对话）。仪表盘底行在 sheet 宿主里是按钮（点了直接开抽屉），推入式宿主里是一行字「逐个开关：下面的「工具抽屉」」（推入式没法从仪表盘里程序化推一页）。
- `PersonaSettingsTab.toolsAbsentText` 改成 static（抽屉页复用）；`CVM.mcpDeferThreshold` 去掉 private（抽屉页显示阈值）。

## astra 一轮裁决（1 P1、3 P2、2 P3）

| # | 问题 | 怎么处理 |
|---|---|---|
| 1 P1 | 执行前复查用整批开头的抽屉快照：同一批前面的调用 await（读网页、审批卡）时关掉的工具还会执行 | 收。每个调用前、审批卡回来后各现建一次 gate 查 `availability`（`toolUnavailableNow`） |
| 2 P2 | MCP 经 tool_invoke 调的历史存外层名，`offeredOnly` 只看 `tool_invoke` 在不在，关掉的 MCP 照样按真工具块回放 | 收。看包着的名字。astra 还建议「新存档统一存解析后的目标名」——不收：改节点存法，牵连回放 / 卡片显示，另开单 |
| 3 P2 | 循环中途「收起 → 直接给」，tool_invoke 拆不了被拒 | 收。按发出去的清单算拆包集合（见上） |
| 4 P2 | MCP / 权限在别处改了，Prompt 页入口数字和检查器不刷新 | 部分收。MCP 已启用数进了三处防抖键；权限档位没进 Prompt 页（要么全局监听 defaults——#00207 卡顿返工那一页，不想在聊天时跟着每次 defaults 写入重算；要么给权限加版本号——改 PermissionCenter，超范围）。抽屉页自己会刷新。检查器本来（改前）就不跟权限变，回到页面会重算 |
| 5 P3 | defer 状态下增减 MCP，工具签名不变，缓存提示漏报 | 收。签名带清单外调得到的名字 |
| 6 P3 | MCP 超阈值时行状态还写「直接给」 | 收。写「收进目录（经 tool_search 找）」 |

## 1. 边界情况

- **工具循环中途改抽屉**：这一轮的 tools 数组第一轮就定了（缓存稳），中途关掉的工具下一次调用就拒（现读）；中途打开 / 改档位的，下一次完整发送才生效。
- **改前就有、默认态会变的一种历史**：历史里调过「这一轮调不到」的工具（权限关了的 fs_*、关掉的 MCP、经 tool_invoke 叫过一个拼错的名字），以前会被包成 tool_invoke 发，现在那条退纯文字。对这类老对话，升级后第一轮整段缓存重写一次。plan §3.2 已说明这一步不限于抽屉；G1–G6 金样里没有这种历史，没变。
- **楼层覆盖**：和全局一样的值也照记（是「本楼层改过」）；删掉楼层后它的覆盖留在 `toolDrawer.v1` 里不清（几十字节，读的时候查不到它）。以后删了的工具名同理，读的时候忽略。
- **全局只存和默认不同的**：把一个工具改回默认档位，全局那条删掉。
- **上游关着**：抽屉开着也不发；行变灰写原因，抽屉自己的状态保留，上游一开就按抽屉生效。工具总开关关 / 卡不支持 / CC / 本机模型：顶部写原因（和仪表盘同一句），整页变灰，还能改。
- **只关部分 fs_\***：文件库模板里还写着 fs_write 等名字（Q11 这单不裁）；能力说明段写了「以这里为准」，执行前复查兜底。
- **关 remember、留 edit_memory**：〔我的记忆〕段整段不出现（只看 remember 在不在）。
- **关 card_guide**：卡片写法全文回到系统提示，system 变大。
- **关 ask_user / roll_dice**：问答卡 / 骰子卡不再由工具产生。
- **缓存提示**：只比较本次 app 运行里这个对话上一次真发出去的工具；重启后没记录不提示。只看名字，不看 MCP 描述改没改。
- **token 粗估**：`TokenEstimator`，tools 按 sortedKeys 序列化；API 自己给工具加的隐藏系统提示（Anthropic 有）没算，**数量未查证**。
- **MCP 开关跨阈值**：在抽屉里开关一个 MCP 可能让总数跨过 16，整批在「直接给」和「收进目录」之间跳，顶部数字跟着跳，不拦。
- **跨设备**：抽屉存本机 UserDefaults，iPhone 和 Mac 各一份。

## 2. 和下一单（thinking 回传）交互风险

- **退纯文字的那条回复带着 thinking**：`offeredOnly` / `wireOrdered` / `orderedForProvider` 三处 `textFallback` 都只清 `toolRounds`、留正文。thinking 回传那单要是把签名过的 thinking 块挂在有工具调用的 assistant 消息上，这条退成纯文字时 thinking 块要一起处理（Anthropic 要求带 tool_use 的回合 thinking 原样回传；没了 tool_use 再带签名 thinking 是否被拒**未查证**）。三处 textFallback 要同一个规则，否则预览 ≠ 实发。
- **工具循环中途**：本单保证一个回合内 tools 数组不变；thinking 那单如果按回合回传 thinking，不受抽屉中途改动影响。但执行前复查现在会在中途拒掉工具，回给模型的是 isError 结果，thinking 块和这些结果的配对按原 tool_use id 走，不变。
- **`tool_choice`**：本单没发。#094 的 `ParamErrorClassifier` 不认识它；thinking 那单要是发 `tool_choice`（Anthropic 开 thinking 时只允许 auto / none），被拒时分类器认不出 → 不重试。
- **`ProviderRouter.sendStreaming(attempt:)`**：本单没碰调用点。
- **缓存前缀**：抽屉一改，tools + system + 历史整段重写一次。thinking 那单要是让 thinking 块进历史，改抽屉那一轮的缓存写入会更贵（多了 thinking 文本）。

## 3. 技术债务

- **MCP 经 tool_invoke 调的仍存外层名**（astra #2 建议存解析后的名字，没改存法）。回放靠解析参数里的名字。
- **没有跳到权限页 / 记忆设置 / MCP 设置的链接**（见上）。
- **Prompt 页入口数字和检查器不跟权限档位变**（astra #4 部分收），要回到页面才重算。
- **`ToolRegistry.all` 现建**：抽屉页每次 body、执行前复查每个调用（两次）都现建一遍注册表（四十来个定义）。量小，没缓存。
- **`ToolDrawerCatalog` 是手写名单**：加新工具要记得加一行（`ToolDrawerTests.testCatalogCoversRegistryExceptHiddenApp` 会逼着加）。
- **UI 没有在模拟器 / 真机上看过**（本单不许起模拟器），长相、iPhone 窄屏折行、mac sheet 尺寸、菜单 / 开关挤不挤都没验。
- **真请求没发过**（第 17 步要粟粟点头）：「关一个工具、发两轮、第二轮缓存恢复命中」没实测。
- **astra 只审了一轮**，修完没再审。
- **说明书**：`manual/facts/model/model-api.md` 事实层加了两条（抽屉、关掉后的执行 / 回放）；`npm run check` / `rewrite` / `build` 没跑（工位里 `scripts/manual` 没装依赖，rewrite 要调模型，本单不发请求），`manual.html` 等下次流水线一起生成。

## 验证

- mac `build-for-testing`：`** TEST BUILD SUCCEEDED **`（astra 修完之后的树）。
- iOS `build-for-testing`（MemoryPalaceIOS，iOS 26 模拟器 9451D1D2）：`** TEST BUILD SUCCEEDED **`（astra 修完之后的树；第 14 步那版也过过一次）。
- mac 定向（都读到 `Test Suite '…' passed`，astra 修完后的数）：ToolDrawerTests 17、ToolTuckingTests 13、ToolReplayTests 18、ToolRegistryTests 5、PromptRealPathGoldenTests 6、InspectorRealPathTests 17、MainThreadIOBudgetTests 3、ProviderOrderingTests 12、OutputTokenCapTests 26、SentRequestStoreTests 4、CardGuideToolTests 9、ParamAutoAdaptRouterTests 13、SettingsSearchTests 34、PermissionCenterTests 10、TurnStatusNoteTests 5、DeviceToolsTests 8、CodingToolsWiringTests 8、ToolEvalExportTests 1、DeathScaleAIToolTests 6（共 215）；BudgetGateTests 32（单跑）。
- 金样：G1–G6 和工具 schema 金样**没重录**，原样通过（默认抽屉 = 改前的分法，`offeredOnly` 对 G1–G6 是空操作，和 plan §3.4 预期一致）。
- 新增用例：ToolDrawerTests（全新 17 例）；InspectorRealPathTests 2 例（抽屉关一个 / 收一个 / 楼层覆盖一个，历史里调过关掉的 / 收起的：预览 body = 实发 body，previewTools 签名 = 实发记下的签名）；ToolReplayTests 2 例；ToolTuckingTests 2 例；ToolRegistryTests 抽屉复查；SettingsSearchTests 1 例；BudgetGateTests 1 例（抽屉关了直接叫 / 包着叫都回「没开」、第一轮清单里没有它）。
