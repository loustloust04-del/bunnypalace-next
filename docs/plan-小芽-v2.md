# Plan：小芽 v2 —— 舞台窗口 + 盖章与账本 + 外观放权 + 本地大脑（可选）

- 日期：2026-09-26（🎩）
- 前置：[research](research-小芽-v2.md) · [设计小稿](design-小芽-v2.html)
- 状态：**v1.1 —— 粟粟 09-26「都按你推，给 astra 审 plan 后开始」；astra R1「改了再放行」已逐条裁决（文末 §10），执行中**
- 审查：[prompt](prompts/2026-09-26-xiaoya-v2/R1-plan-review.md) / [报告](prompts/2026-09-26-xiaoya-v2/reports/r1-plan-review-astra.md)

## 0. 已裁决（09-26 粟粟）

| # | 裁决 |
|---|---|
| Q1 布局 | **A 舞台头** |
| Q2 html | 指设计稿（已交 `design-小芽-v2.html`），窗口本身仍是 SwiftUI |
| Q3 图标 | 换成纹样图**最右上那个椭圆肖像**（`motif-cameo`），`ya3d` 退役 |
| Q4 本地大脑 | **可选**：默认仍用楼层 API；设置里自己选模型、自己点下载、自己打开「用本地大脑」 |
| Q5 放权首批 | 随我定 → 见 §4 |
| Q6 表情 | 只当舞台头表情，不在回复里发贴纸（带字幕的 sticker 不入库） |
| Q7 名字 | **Lily = 英文名**。中文叫小芽，舞台头名字旁带小字 Lily |

## 1. 分期总览

| 期 | 内容 | 依赖 | 可独立交付 |
|---|---|---|---|
| **P0** | MLX 可行性验证（一次性实验，不进仓库） | — | 结论写回 research §8 |
| **P1** | 舞台窗口：表情 / 消息 / 输入条 / 图标换肖像 | — | ✅ 装上就能看 |
| **P2** | 盖章卡 v2 + 账本 + 撤销 + 权限包开关 | P1 | ✅ |
| **P3** | 外观工具包 + 试穿预览（iOS） | P2 | ✅ |
| **P4** | 本地大脑（MLX + Qwen3，可选） | P0 通过 | ✅ |

P0 和 P1 可以并行：P0 只在草稿目录里跑，不碰工程文件。**P0 不通过 → P4 暂停，回来跟你商量（退 llama.cpp 或放弃本地），P1–P3 照常。**

---

## 2. P0 · MLX 可行性验证（✅ 09-26 已完成，结论见 research §8）

> 实测结论：钉 `mlx-swift-lm` **exactVersion 3.31.4** + `swift-transformers` **1.3.4**（只要 `Tokenizers`，手写 30 行 `TokenizerBridge`，不引宏）；xcodebuild 必须 `-skipPackagePluginValidation`（mlx-swift 的 CudaBuild 插件）；mac 110 tok/s、峰值 718 MB、工具调用三类全对；**iOS 模拟器初始化 MLX 必 SIGSEGV**；包体积 +30 MB 量级。下面是原始问题清单，留档。

要回答四个问题，每个都得有实测证据：

1. **能不能引进来**：mlx-swift-lm 3.31.x 里 xgrammar 那个目标用了 `unsafeFlags(["-w"])`，SPM 对「用版本号引入的依赖」可能直接拒绝。用 xcodegen 起一个最小工程（macOS 15 / iOS 26，跟我们一致）按版本号引入 `MLXLLM` + `MLXLMCommon`，build mac 和具体模拟器，看能不能过。另外它默认开着 `FoundationModelsIntegration`（要 iOS 27），确认只引 MLXLLM 时不受影响。
2. **能不能下、下到哪**：自己写下载器（URLSession + Range 续传，文件清单写死），先走 `huggingface.co`、失败再走 `hf-mirror.com`（两边今天都通，1.7B 权重 968 MB，支持续传）。下完用 `loadModelContainer(directory:)` 从本地目录加载，不走 `~/.cache/huggingface`。
3. **能不能用工具**：Mac 上跑 Qwen3-1.7B-4bit，把我们现有的 3 个工具定义（OpenAI 格式字典，MLX 的 `ToolSpec` 就是同一格式）喂进去，问「帮我看看当前预设」，看 `generate` 流里有没有吐出 `.toolCall`、参数对不对；关思考模式（`enable_thinking: false` 或 `/no_think`）。记首 token 时间和 tok/s。
4. **模拟器行不行**：Apple 芯片 Mac 上的 iOS 模拟器能不能跑（文档说只有 Intel 模拟器不行，实测为准）。不行的话开发期用 mac 版测，iPhone 最后真机验。

产出：research §8「P0 实测」，含命令和输出摘录。

---

## 3. P1 · 舞台窗口

### 3.1 素材
- `Assets.xcassets/xiaoya-face-{smirk,huh,cheer,love,sigh,nope,shock,sob,chaos}.imageset`：从 `docs/assets/xiaoya-v2/face-*` 重新从原图切 @3x（原图 1024，单张约 300px 够 96pt@3x），**template 渲染**，这样深色模式能染成奶白墨
- `xiaoya-cameo.imageset`：纹样图右上椭圆肖像，template
- 删除 `ya3d.imageset`（我的改动让它变成死资源）

### 3.2 表情状态机
- 新 `Services/Assistant/XiaoyaMood.swift`：`enum XiaoyaMood { smirk, huh, cheer, love, sigh, nope, shock, sob, chaos }` + 资源名
- `AssistantEngine` 新增 `mood: XiaoyaMood`、`status: String`（舞台状态行），在这些点上切（全部是 app 事件，不靠模型）：

| 事件（代码位置） | mood | 状态行 |
|---|---|---|
| 空历史 / 回合结束且无提案 | smirk | 「在呢」 |
| `send` 发出 | huh | 「在想…」 |
| `onToolCalls` 里只读工具 | huh | 「在翻你的{预设/世界书/卡库/记忆}…」 |
| 回合结束有提案 | cheer | 「写好啦，等你盖章」 |
| 盖章 | love | 「改好了」 |
| 丢弃 | sigh | 「好吧…」 |
| 按停止 | shock | 「欸——停了」 |
| `onError` / 工具参数错 | sob | 「出错了」 |
| 撞 `maxRounds` | chaos | 「脑子打结了」 |
| 模型调了未开放 / 不存在的工具（执行层拦下） | nope | 「这个我现在做不了」 |

- **v1.1（B10/D2）**：不做关键词判拒绝。表情 = 一份**主状态**（idle / thinking / reading / awaitingStamp(有任一 pending 卡) / error）派生 + 一个**短暂反馈**（love / sigh / shock / chaos / nope，2.5 s，带 runId，旧计时器失效）。反馈结束回到主状态派生的表情（有 pending 仍是 cheer，生成中仍是 huh），不是一律回 smirk

### 3.3 视图（`Views/Assistant/`）
- `XiaoyaStageView.swift`（新）：左表情 96pt（`maxWidth 132`，底对齐）+ 名字「小芽」+ 小字 *Lily* + 状态行（huh 时三点跳动）；切表情 0.25s 淡入 + 1.06 弹一下；随滚动收成 44pt 一行（`onScrollGeometryChange` 挂在消息 ScrollView 上，Bool 两态 + **滞回**：offset > 60 收、< 12 放；**舞台外框保持固定占位高度只动画内部**，不改 viewport，避免和「流式跟底」互相顶；用户手动上翻时停止自动跟底，回到底部再恢复）；右上保留「账本」按钮（P2 接上）
- `AssistantPanelView.swift` 重写：
  - 去掉两条 `Divider`；舞台下一条扇贝纸边
  - 她的话：无气泡，左侧 2pt 墨线；你的话：浅薄荷气泡 + 深色字（允许组合，不踩深绿套浅绿）
  - 时间分隔：同一天只标一次，隔 >30 分钟再标
  - 空态：舞台就是空态（smirk + 「下午好～今天想折腾点什么？」按时段换问候），消息区只放一句能力说明 + 铃兰角标，不再是功能清单卡
  - 流式：沿用她的墨线样式，文字未到时显示三点
  - 输入条：纸色输入框 + 墨绿圆发送钮；生成中发送钮变成停止方块（原头部「停止」删掉）
- 配色：新 `XiaoyaSkin`（`paper` / `ink` / `inkSoft` / `mint` / `line` 五个色 + 表情尺寸），默认值 = 设计稿；深色模式一套对应值。P3 的「窗口皮肤」工具就是改它
- 名字（v1.1 D5）：舞台和 prompt **同一来源** `AssistantPrompts.assistantName`；英文小字 `AssistantPrompts.englishName`：名字是默认「小芽」时显示 *Lily*，用户自定义名字或 pro 模式（Rosemary）时不显示。Rosemary 逻辑不动（粟粟「都按你推」认了 §8 默认）

### 3.4 图标
- `Page2VisualStyle.swift:179`：`ya3d` 特例 → `xiaoya-cameo`，按 Page2 图标的 glyph 规则着色（透明 / 着色外观也跟着走，不再是原色图特例）
- `RightPanelPlugin.swift:176/183` dock / 设置里的 `leaf.fill` → `xiaoya-cameo`。**v1.1（A3）**：`AppIconView.isAssetName` 现在只认 `ri-` 前缀（`AppIconView.swift:41`），扩成 `ri-` 或 `xiaoya-` 前缀，加 AppIconTests 断言。**（C3）**`RightPanelToolManager.load` 已按内置定义覆写 icon/name（`RightPanelPlugin.swift:120-135`），不需要另做迁移
- `SettingsView.swift:122,178` / `SettingsSearch.swift:202` 的 `leaf.fill` 同步换（`DashboardManager` / `BookReaderSheet` 的叶子与小芽无关，不动）

### 3.5 mac
`AssistantPanelView` 两端共用（mac 在右栏）。舞台在右栏 ~320pt 宽下要排得开：表情 80pt。P1 验收包含 mac 右栏截图。

---

## 3.6 P1.5 · 剪纸舞台（粟粟 09-26 追加，[小样](design-小芽-v2-剪纸舞台.html)）

粟粟：「太黄了，顶部舞台和底部不要一个颜色，更舞台剪纸一点（小芽也变成剪纸），这样就不怕亮暗主题」→ 看了小样：「都挺好看的，干脆都做了放小芽设置里；太阳和月亮对应亮 / 暗主题；这个边框（拼贴菱格）特别喜欢，再做一个这个主题的」。

- **舞台 = 一件自带颜色的纸剧场**，不跟亮暗主题换底色；只有天上的东西跟主题：亮色出太阳、暗色出月亮（拼贴剧场暗色时整张纸换夜蓝，亮羊皮纸块在暗色 UI 里太刺眼）
- **四套**（`XiaoyaStageTheme`，`AppStorage("xiaoya.stageTheme")`，默认薄荷夜场）：薄荷夜场 / 胭脂剧场 / 粉绿马戏（条纹帘 + 三角彩旗 + 八角星）；拼贴剧场（菱格金星边 + 羊皮纸 + 手描棕边 + 红丝绒 + 云 + 闪光星 + 带脸太阳）
- **画法**：整台用一个 `Canvas` 画（背景 / 帘 / 彩旗 / 星 / 日月 / 地台），底边锯齿 / 撕纸边用裁剪形状做，不依赖聊天区颜色；舞台背景向上漫进顶部安全区（状态栏下面也是舞台）
- **剪纸小芽**：九张 `xiaoya-cut-*`（线稿外垫一层填满的奶白纸 + 纸边，原色渲染，不再 template），投影一层；换表情 = 绕 Y 轴翻一下纸片
- **名字小票**：奶白小票（带两个打孔）斜贴，印名字 / Lily / 状态行
- **聊天区**：跟 app 主题；亮色纸色从奶黄 `#F7F3E8` 改成偏灰 `#F3F3EF`
- **收起态**：只画幕布底色 + 顶边装饰 + 小剪纸 + 名字，不画帘和日月
- **设置 › 小芽 › 舞台**：四张迷你舞台（真 Canvas 渲染）点选；设置搜索登记
- `xiaoya-face-*` template 资源退役（改用 cut）；`AppIconTests` 同步

## 4. P2 · 盖章卡 v2 + 账本 + 权限包

### 4.1 提案数据结构升级（`Models/AssistantTypes.swift`）
- `AssistantAction` 加：
  - `fields: [DiffField]`（`label` / `old` / `new`），卡片按字段画「旧的划掉 + 新的荧光笔」
  - `tier: Tier`（`reversible` / `destructive`）
  - `status: Status`（`pending` / `approved` / `discarded` / `undone` / `failed`）
  - `ledgerId: UUID?`
- **v1.1（A1）**：synthesized Codable 对缺键的非 Optional 属性**会抛错**（带默认值也一样），旧 history 会整份解失败被清空 → `AssistantAction` 写自定义 `init(from:)` + `decodeIfPresent`（照 `Page2Appearance.swift:27-41`）；`AssistantChatStore.load` 解失败时**不覆盖原文件**（改名 `.corrupt-<时间>` 留底再起空）。旧 pending 卡（无 expected-old）标 `legacy`：只读展示 +「让小芽重新提一次」，不能盖章
- **v1.1（A2，现网 bug）**：世界书 add 提案 payload 没有 `entryId` 键，而 `WorldBookEntryPayload` 的 `entryId` 非 Optional → 现在「加世界书条目」盖章必失败；delete 同理。修法：add / update / delete 三种 payload 分型
- **v1.1（B1）**：展示用 `fields`（label/old/new，可截断）与机器用 `patch` 分开。`patch` = `[PatchField(key, before: JSONValue?, after: JSONValue?)]`，`before` 是**完整原值**（`nil` = 原本不存在，`""` 是合法空值），只有出现在 patch 里的字段才会被写；世界书 comment 不传 = 不动（修掉现在 apply 无条件覆盖 comment 的问题，`AssistantTools.swift:449`）；采样参数按类型比较（Int 字段拒收小数）
- **v1.1（B3）**：提案锚 = `profileId` + `targetId`（presetId / bookId / cardId / toolId）+ 子键（slotId / entryId / field）；同层换了预设也判失效；createPreset 模板已删 → 失败，不 fallback
- 行为变化：现在盖章后提案卡是**删掉**的（`AssistantEngine.swift` applyAction 里 `removeAll`）→ 改为留在原位、改状态，折叠成「新内容 + 邮戳 + 撤销」
- **v1.1（C5）**：`wireHistory` 不再把所有卡都标「本轮提案」，按持久化 status 写紧凑结果（「[提案「x」：已盖章 / 没要 / 已撤销 / 失败：原因]」）；`appliedNotes` 内存附注删掉，重启后模型也知道结果
- **v1.1（C1）**：history 保持全量留档（粟粟 09-11 的决定），但 `messages.didSet` 同步整份 encode 改为 0.5 s 合并 + 后台写
- `AssistantTools` 每个 `propose*` 改成产出 `fields` 而不是拼 `detail` 字符串

### 4.2 盖章卡视图（`AssistantProposalCard.swift`，新）
- pending：类别小标（世界书 · 改条目）+ 标题 + 字段对照 + 「不要 / ✓ 盖章」
- destructive：盖章后弹 `confirmationDialog`「确定删除「xx」？」再落地
- approved：邮戳（SwiftUI 画的椭圆双线 +「已批准」+「SUSU · 日期」，-12° 旋转，从 1.4 倍缩到 1 带一点回弹）+ 左下「撤销」
- discarded：卡片淡成 40% + 「没要」小字；undone：邮戳换成「已撤销」灰章
- failed：保留卡 + 红字原因 + sob 表情

### 4.3 落地前再核一次旧值（review-小芽助手 §1 留的债）
提案时把完整旧值存进 `patch.before`；盖章时重新读当前值，**跟提案时不一样**（你手动改过） → 不落地，卡片提示「这之后内容变了，让小芽重新看一眼」。

**v1.1（B4）唯一落地入口** `AssistantEngine.stamp(actionId)` 依次核：`status == pending`（approved/discarded/undone/legacy 一律拒，双击只落一次）→ 所属包当前仍开启 → 楼层锚 + 目标锚 → expected-old → 执行。UI 隐藏按钮只是体验，保护在这里。
**v1.1（B9）** 每次 send 固定 `runId` + `originProfileId`；收到 `.profileWillSwitch` 立刻 cancel；所有回调先核 runId，旧 run 的晚到事件丢弃。

### 4.4 账本（`Services/Assistant/AssistantLedger.swift`，新）
- 存 `Application Support/AssistantChat/ledger.json`，跟聊天记录分开，保留最近 200 条且总量 ≤ 4 MB（先到先裁）；被裁掉的条目，其卡片显示「超出撤销保留范围」（C2）
- 条目：`id / actionId / date / title / category / kind / profileId / target / patch(每个 touched 字段的 typed before+after；创建/删除存实体快照+原位置+邻居 id) / undone / undoOf`（D1：after 必须留，用来判「之后又改过」）
- **提交顺序（B5）**：业务写入 → 取回执（实际 before/after、新建实体 id、删除位置）→ 写账本 → 卡片状态 approved。业务失败 = failed 不写账；业务成功但账本写失败 = 卡片标「已生效，但没记进账本（无法撤销）」，不假装可撤销。apply 前先按 actionId 查账本，已有 = 幂等返回。世界书 save 失败时把本次改的那条 entry 恢复原值，不做全 context rollback
- **快照在盖章那一刻取**（不是提案那一刻），撤销按 kind 还原：

| kind | 撤销 |
|---|---|
| createCharacter | 按 apply 时记下的卡 id 删卡 |
| updateCharacterField | 字段写回 before |
| createPreset | 楼层 presetId 切回 before，删掉新建的实例 |
| updatePresetSlot / Sampling | 写回 before |
| add / update / delete 世界书条目 | 删掉 / 写回 / 按原位置插回 |
| page2Appearance / appIcon / windowSkin（P3） | 整份写回 before |

- 撤销前比对「当前值 == after」；不等（之后又被改过）→ 弹确认「这之后又改过，撤销会覆盖掉」
- 楼层锚：撤销时楼层不对 → 拒绝并提示切回那层
- 撤销是你的操作，本身不再走盖章；撤销也记一笔（`undoOf` 指向原条目，原条目原子标 undone；撤销记录本身不再提供撤销）
- 撤销 `createPreset` 用 `removeInstance`（不是 `delete`，后者拒内置标记）；删除类撤销按原 index 插回，parent 不在 / id 已被占用 → 失败提示
- 入口：舞台右上按钮 → `AssistantLedgerView.swift`（新，sheet），按设计稿 §05

### 4.5 权限包（设置 › 小芽）
- 包：`read`（查记忆 / 读预设 / 读卡 / 读世界书 / 读外观）、`creation`、`appearance`、`windowSkin`
- `AppStorage("xiaoya.pack.<id>")`，默认：read / creation / appearance 开，windowSkin 关（设计稿就是这样画的）。**v1.1（C6）**：`XiaoyaPackPolicy.isEnabled(_:)` 统一处理缺键默认值，设置页 / definitions / execute / stamp 四处同读，不各自 `bool(forKey:)`
- 关掉的包：工具定义不发给模型 + `execute` 层再拦一次（双保险）
- 硬规则写在代码里、不给开关：**不存在任何「免盖章」档**

---

## 5. P3 · 外观工具包 + 试穿（Q5 我定的首批）

**首批放权**（都可逆、影响面只在 Page2 和她自己的窗口）：
1. Page2 壁纸：`ios26 / mist / dusk / flora`（不含「我的照片」——要选文件，模型做不了）+ 明亮遮罩
2. 图标外观：默认 / 透明 / 着色 + 着色色相 / 饱和度
3. 明暗：浅 / 深 / 自动
4. 大图标开关
5. ~~小组件底色 `widgetTone`~~（v1.1 A5：全仓没有渲染消费者，删）
6. 单个 app 图标：符号（限 `Page2IconEditor` 现有 16 个）+ 颜色
7. 她自己的窗口皮肤（`XiaoyaSkin` 预设：奶白 / 旧纸 / 夜读，外加表情大小）——独立 `XiaoyaSkinStore`（UserDefaults 一个 key，两端共享），不塞进 Page2AppearanceStore

**不放**：主聊天主题色 / 气泡色（影响面大，等这批用一阵再说）、壁纸照片、图标自定义图片。

工具：
- `read_appearance`（read）：当前 Page2Appearance + 各项可选值
- `propose_page2_appearance`：只传要改的字段，全部枚举 / 范围校验，越界 = 工具报错，不产提案
- `propose_app_icon`：`toolId` 必须在已注册工具里
- `propose_window_skin`

**v1.1 约束**：
- （A8）只对自由桌面（`page2HomePresentation_v1 == "free"`）生效；针脚桌面不读 Page2AppearanceStore → `read_appearance` 报告桌面类型，针脚桌面下外观提案直接报「现在用的是针脚主屏，这些设置不影响它」，不产提案
- （B2）提案只存 patch；**盖章时从当下 committed `value` 复制，套 patch 再 save**，不存整份 draft；单 app 图标只动 `icons[toolId]`（原本没有 = 撤销时删 key）
- （B6）卡片只渲染传入的 before/after 值，**绝不调 `shared.preview` / 不嵌 `Page2AppearanceEditor`**（它 onDisappear 会 save）
- （C4）Page2Appearance 模型 + store 两端共有 → patch 校验 / 套用 / 快照比较放共享层（mac 测试能测）；预览视图和工具注册 `#if os(iOS)`
- store 是 `@MainActor`（`Page2AppearanceStore.swift:8`），stamp 路径标 MainActor

试穿（`AssistantProposalCard` 内）：
- Page2 类：左右两块小屏，**用真实的 `Page2WallpaperView(appearance:)` + 图标行渲染**。（A4）`Page2AppIcon` 现在只读 `.shared.displayed`，给它加显式 `appearance` 参数（默认仍读 shared）；两块小屏按同一虚拟桌面尺寸（390×844）渲染后整体 `scaleEffect`，避免壁纸 80pt 外扩在小尺寸下比例失真
- 皮肤类：左右两块迷你舞台
- 盖章 = committed value + patch → `Page2AppearanceStore.save`；返回 false = failed，不写账；before 快照读 committed `value`（不是 displayed）
- mac：外观包整体 `#if os(iOS)`（mac 没有 Page2 桌面），mac 端工具定义里不出现

---

## 6. P4 · 本地大脑（可选，P0 通过后做）

### 6.1 引擎抽层
- `Services/Assistant/AssistantBackend.swift`（新）：
  ```swift
  enum AssistantBackendEvent { case text(String), toolCalls([ToolCallBlock]), done(String), failed(String) }
  protocol AssistantBackend { func run(system: String, history: [(role: String, content: String)], tools: [[String: Any]], toolTurns: [ToolTurn]) -> AsyncStream<AssistantBackendEvent>; func cancel() }
  ```
- `AssistantCloudBackend`：包现在的 `ProviderRouter.sendStreaming` 回调（行为不变）
- `AssistantLocalBackend`：MLX `generate` 流 → 同样的事件；`ToolTurn` 转成 Qwen 的 tool 消息
- **v1.1（A7）事件契约**：复用真实类型 `ToolCallBlock`（`ChatToolTypes.swift:6-23`）；一次 run **只有一个终止事件**——本轮 `.toolCall` 全部收齐，流结束时发一次 `toolCalls(all)` 或 `done(text)`，`.info` 不当终止；cancel 同时结束消费 Task 与生成 Task 并 await；load / prepare / generate 抛错 → failed。ToolTurn → MLX：`.assistant(content, toolCalls:)` 在前、按 id 配对的 `.tool(content, id:)` 在后；`isError` 用结果文本前缀 `[error] ` 表达。ToolSpec 递归转 `[String: any Sendable]`，不用 `as!`。工具定义同时进 `UserInput.tools`（给模板）和 `generate(tools:)`（给解析器）
- 解析失败时 MLX 会把残块当普通文本吐出 → 本地模式对最终文本做边界检查：含 `<tool_call>` / 以 `{"name"` 开头的残块不显示，换成 sob +「我没弄懂，换个说法？」
- `AssistantEngine.runRound` 只认事件流；`resolveModel` 那段挪进 CloudBackend

### 6.2 模型管理（`Services/Assistant/AssistantModelStore.swift`，新）
- 目录：`qwen3-1.7b-4bit`（约 1.0 GB，默认选中）/ `qwen3-4b-4bit`（约 2.3 GB）；每个写死文件清单 + 大小
- 下载：前台 URLSession，Range 续传；HF → hf-mirror 失败自动换；进度 / 暂停 / 继续 / 删除
- **v1.1（B7）**：清单钉 **revision**（URL 用 `resolve/<revision>/`，两个镜像拿到的一定是同一版）+ 每文件字节数 + 权重文件 sha256（HF LFS oid）；partial 与 installed 分目录，全部校验通过后原子 rename 成 installed；200 = 整个重下、206 核 `Content-Range` 起点、416 = 已完整则校验否则删了重下；磁盘剩余 < 所需 × 1.2 不开下；**默认只走 Wi-Fi**（`allowsExpensiveNetworkAccess = false`），在蜂窝下显示「用流量下载（1 GB）」按钮让你选
- 存 `Application Support/XiaoyaModels/<id>/`，目录标 `isExcludedFromBackup`
- 下载中切后台被杀 → 下次进设置显示「已下 620 MB，继续」
- 模型只在小芽面板打开且开了本地时加载。**v1.1（B8）**卸载时机：面板不在前台（mac 用 `isFrontmostTool`，iOS 用 Page2 当前 app / scenePhase）/ app 进后台 / 内存警告 / 关掉本地开关；卸载前 cancel 并 await 生成结束。输入 + 工具结果按 token 预算截断（本地 3000 tok）

### 6.3 设置 › 小芽 ›「本地大脑」段（放页面底部）
- 模型二选一 / 下载卡（设计稿 §06 样式）/ 「用本地大脑」开关（**默认关**，没装好时置灰）/ 删除模型
- 舞台状态行在本地模式下带个小叶子标记，让你知道现在是本地在答

### 6.4 本地模式给小模型减负
- 规则层精简版（现 ~1200 字 → ~400 字）
- ~~工具按页面裁剪~~（v1.1 D4：外观类没有页面上报，裁剪会让外观工具永远进不来）→ 先发**全部已开启包**的工具（描述用精简版），P4 实测准确率差再加裁剪规则；权限的真正闸门始终在执行层
- 历史窗口 60 → 12 条；关思考；`maxTokens` 800
- 工具参数解析失败 → 不动作 + sob +「我没弄懂，换个说法？」

### 6.5 平台
- mac（Apple 芯片）+ iOS 真机；Intel mac / 不支持 Metal 的设备：本地段整段隐藏
- **v1.1（D8，P0 实测）**：iOS 模拟器初始化 MLX 必崩 → `AssistantLocalBackend` 及一切 `import MLX*` 的代码在 `#if targetEnvironment(simulator)` 下编译成空壳，设置里本地段隐藏
- 依赖：`mlx-swift-lm` exactVersion 3.31.4 + `swift-transformers` exactVersion 1.3.4，只链 `MLXLLM` / `MLXLMCommon` / `Tokenizers`；CLAUDE.md 构建命令、`scripts/` 里的 xcodebuild 调用、fastlane 都加 `-skipPackagePluginValidation`（Xcode 界面里首次打开需点一次「Trust & Enable」）；升级 mlx-swift-lm 前重审（main 已引入 unsafeFlags / traits）
- 包体积 +30 MB 量级，review 里如实写
- 是否需要 `increased-memory-limit` entitlement：看 P0 / 真机实测内存再定

---

## 7. 测试（`MemoryPalaceTests`，module「记忆花园」）

- **v1.1（D7）按 astra 报告「最小验收矩阵」落样本**（报告 §四 末表），下面是承接的测试文件
- `XiaoyaMoodTests`：主状态派生 + 短暂反馈过期 + runId 失效
- `AssistantLedgerTests`：每个 kind 盖章 → 撤销后还原；「之后又改过」检测；楼层锚拒绝
- `AssistantActionCodableTests`：旧 `history.json`（无新字段、含 pending）能解且旧 pending 变 legacy；解失败不覆盖原文件；世界书 add/update/delete 三型 payload 都能解（A2 回归）
- `AssistantToolPackTests`：关掉的包不出现在 definitions，`execute` 也拒绝；关包后历史 pending 卡 stamp 被拒；approved 再 stamp / 双击只落一次；缺键默认值（新装 / 升级未开设置 / 显式关）
- `AssistantAppearanceToolTests`（mac 可跑的共享层）：越界值报错不产提案；patch 套在「盖章当下」的 committed value 上，不覆盖期间改过的其他字段；单图标撤销原本不存在 → 删 key；save 返回 false 不写账
- `AssistantModelStoreTests`：清单齐全 / sha256 不符、200/206/416 分支、镜像回退、partial→installed 原子切换（URLProtocol 桩）
- `AssistantLocalBackendEventTests`（事件适配层，用假流不加载模型）：多个 `.toolCall` 后只终止一次、残块文本被拦、取消后晚到事件丢弃
- 手测：模拟器 iPhone 截图（舞台 9 表情 / 盖章 → 邮戳 → 撤销 / 试穿卡 / 账本）+ mac 右栏截图；本地大脑在 mac 实跑一轮「帮我看看当前预设」

---

## 8. 待你 ⧫ 的小点（✅ 09-26「都按你推」：Rosemary 不动 / dock+设置一起换 / 首批照 §5，astra 删 widgetTone）

- **pro 模式**：现在 pro 模式叫 Rosemary。Lily 是英文名，那 pro 还叫 Rosemary 吗？（我默认不动）
- **dock / 设置里的图标**：跟 Page2 桌面一起换成椭圆肖像（我默认一起换）
- **外观首批**（§5）有没有要加 / 要删的

---

## 9. Todo（v1.1）

### P0 · MLX 验证 ✅
- [x] 最小 xcodegen 工程，exactVersion 3.31.4 引 MLXLLM + MLXLMCommon + Tokenizers，build mac + iOS 模拟器 + iOS 真机架构 ✅
- [x] 下载 Qwen3-1.7B-4bit（HF 直连 / hf-mirror 直链都通）✅
- [x] mac 本地目录加载 + 工具调用三类 + 关思考 + 110 tok/s / 718 MB ✅
- [x] iOS 模拟器：初始化 MLX 必崩 → 模拟器隔离 ✅
- [x] 结论写 research §8 ✅

### P1 · 舞台窗口
- [x] 9 张表情 + 椭圆肖像入 Assets（template；单一尺寸——mac 资源目录不认 @3x；奶白部分按亮度转透明，否则 template 染成实心剪影）✅
- [x] `AppIconView.isAssetName` 认 `xiaoya-` 前缀 + AppIconTests（A3）✅
- [x] 图标：Page2 桌面 / dock / 设置 / 设置搜索换 `xiaoya-cameo`；两处 `ya3d` 视图引用改掉后删 `ya3d.imageset` ✅
- [x] `XiaoyaMood`：主状态派生 + 短暂反馈（token 失效）+ 引擎埋点（B10/D2）✅
- [x] 名字：`englishName`（默认小芽→Lily，自定义 / Rosemary→无）（D5）✅
- [x] `XiaoyaSkin`（浅 / 深两套默认值）✅
- [x] `XiaoyaStageView`（浮层 + 列表固定顶边距 + 两态滞回 + 固定表情槽位，换脸名字不跳）（B11）✅
- [x] `AssistantPanelView` 重写（墨线 / 薄荷气泡 / 时间分隔 / 空态问候 / 输入条 + 停止钮 / 离底停跟随；短对话从顶部排）✅
- [x] `XiaoyaMoodTests` ✅（6 例；连同 AppIconTests 12 例、SettingsSearchTests 全过）
- [x] build 双端 ✅；截图改为 mac 离屏渲染（浅 / 深 / 空态 / 9 表情 + 收起态）——粟粟的 iPhone 模拟器当时正跑别的 session 的 `--kb-probe-seed` 键盘探针，按「一台模拟器」规矩没装。**iOS 实机 / 模拟器目视待补**
- [x] commit + push ✅

### P1.5 · 剪纸舞台
- [x] 九张剪纸资源 `xiaoya-cut-*`（1.3× 原图、原色、奶白纸垫 + 纸边）入库；`xiaoya-face-*` 退役；`XiaoyaMood.assetName` 改 cut；AppIconTests 同步 ✅
- [x] `XiaoyaStageTheme`（四套配色 + 标题 + 存储键；拼贴剧场暗色换夜蓝纸）✅
- [x] `XiaoyaStageBackdrop`（一个 Canvas：条纹帘剧场 / 拼贴剧场；亮太阳 / 暗月牙；锯齿 / 撕纸底边；收起态只画底色 + 顶边装饰）✅
- [x] `XiaoyaStageView` 重排：背景漫进顶部安全区、剪纸小芽 + 翻片换脸、名字小票、账本钮 ✅
- [x] `XiaoyaSkin` 亮色纸改偏灰 `#F3F3EF`（去掉扇贝纸边）✅
- [x] 设置「舞台」2×2 迷你舞台（真布景渲染）+ 设置搜索 ✅
- [x] 测试 + mac 离屏四套 × 亮暗截图 ✅（主仓当时被别的 session 的读书半成品编不过，改在隔离 worktree `xy-air` 验证）
- [x] 装 Air（连同 P2 + 输入条）✅ 1d16b82e，装前备份小芽记录到 ~/Backups/MemoryPalace-Air-xiaoya-20260926-0346；**顶部安全区观感待粟粟目视**
- [x] commit + push ✅

### P2 · 盖章 + 账本 + 权限
- [x] `AssistantAction` 手写解码 + change / status / failure / ledgerId；load 失败改名留底不覆盖；旧 pending → legacy（A1）✅
- [x] 世界书 add/update/delete 分型（修现网 bug）；update 的 after 由 before 套改动字段得出，备注不传不动（A2/B1）✅
- [x] 各 `propose*` 产出带类型的 `AssistantChange`（完整改前 + 改后 + 目标锚 presetId / bookId / cardId；卡 id / 条目 id 提案时就定）（B1/B3）——实现上**不另存 fields / patch**，卡片对照从 change 算 ✅
- [x] `XiaoyaPackPolicy`（查阅 / 创作两包，缺键 = 开）+ definitions 过滤 + execute 拦截（C6）✅
- [x] 唯一落地入口 `stamp`：status / 权限 / 楼层锚 + 目标锚 / 改前值 / 账本幂等（B4）✅
- [x] runId + originProfileId + profileWillSwitch 取消 + 晚到丢弃（B9）✅
- [x] `AssistantLedger`：回执、写账失败如实标注、200 条 / 4 MB 裁剪、undoOf、按 kind 撤销 + 冲突要确认（B5/C2/D1）✅；落地 / 撤销走 `AssistantWorkspace` 接口，测试用内存假货不碰真卡库
- [x] `wireHistory` 按状态回灌，删 appliedNotes（C5）；history 写盘 0.5 s 合并 + 后台（C1）✅
- [x] `AssistantProposalCard`（pending / 删除二次确认 / 已批准邮戳 + 撤销 / 没要 / 已撤销 / 失败红字 / 旧卡 / 超出保留）✅
- [x] `AssistantLedgerView`（舞台右上入口）+ 设置「能做什么」两个开关 + 设置搜索条目 ✅
- [x] 测试：`AssistantStampTests` 15 / `AssistantLedgerTests` 12（旧历史兼容、坏文件留底、双击只落一次、丢弃 / 旧卡不能盖、关包后历史卡被拒、改前值变了失败、状态回灌、包归属）✅ + `SettingsSearchTests` 全过
- [x] build 双端 ✅；mac 离屏渲染四种卡状态目视 ✅。**模拟器 / 真机走一遍「加条目 → 盖章 → 撤销」待补**
- [x] 顺带（粟粟 09-26）：输入条照 Page1——iOS 玻璃胶囊、mac 圆角框、发送钮收进框内三态 ✅
- [x] commit + push ✅

### P3 · 外观放权
- [x] 共享层 `Page2AppearancePatch`：校验 / 套到当下 committed 值 / 取改前值 / 去掉没变的项（两端编译，mac 测）（B2/C4）✅
- [x] `read_appearance`（含桌面类型 + 舞台 + 可选值）/ `propose_page2_appearance` / `propose_app_icon`（iOS）/ `propose_stage_theme`（两端）；针脚桌面不产提案（A8）✅
- [x] ~~`XiaoyaSkinStore`~~ → 窗口皮肤并入「换舞台」（剪纸舞台落地后皮肤就是舞台主题）✅
- [x] `Page2AppIcon(appearanceOverride:)`；试穿卡「现在 → 盖章后」迷你主屏 / 单图标 / 迷你舞台，不碰 shared.preview（A4/B6）✅
- [x] 盖章 = 当下 committed + patch → save；save 失败抛错、不写账；单图标撤销原本没有 → 删 key ✅
- [x] 新权限包「外观」（默认开）+ 设置开关 + 搜索关键词 ✅
- [x] `AssistantAppearanceTests` 11 例 ✅
- [x] 双端 build ✅；已装 Air（173bb666，含别的 session 的 c7c070d7）。**「换个秋天一点的主屏」→ 试穿 → 盖章 → 回桌面 → 撤销 真机一遍待粟粟**
- [x] commit + push ✅

### P4 · 本地大脑（分支 `xiaoya-p4`，等粟粟信任构建插件后再合）
- [x] `project.yml` 加 mlx-swift-lm **3.31.3** / swift-transformers 1.3.4（exactVersion）——3.31.4 跟渲染器的 equatable 解不出 swift-syntax，改钉 3.31.3，工具调用实测照样可用 ✅；构建入口的插件信任 **待粟粟**（review §0）
- [x] `AssistantBackend` 抽层 + CloudBackend（行为不变）（A7）✅
- [x] `AssistantModelStore`（钉 revision + sha256 / partial→installed / 200·206·416 / 镜像回退 / 磁盘预算 / 默认仅 Wi-Fi / 删除 / 不进备份）+ 6 例假网络测试（B7）✅
- [x] `AssistantLocalBackend`（一轮只一个终止事件 / Qwen 格式工具回合 / 残块拦截 / 关思考 / 模拟器空壳）+ 收集器测试（A7/D8）✅
- [x] 卸载时机：面板消失 / 后台 / mac 切走 / 内存警告 / 关开关 / 删模型（B8）✅
- [x] 设置「本地大脑」段（开关默认关 / 选模型 / 下载进度 / 暂停继续 / 用流量下载 / 删除）+ 设置搜索 ✅
- [x] mac 实跑：真模型 读工具 → 回灌 → 回答 全链 ✅
- [ ] 真机验证（口罩机或合 master 后 Air，**先问粟粟**）：下载 1 GB / 峰值内存 / 首 token / tok/s / 切后台
- [x] commit + push（分支）✅

### 收尾
- [ ] `review-小芽-v2.md`（边界 / 下一模块风险 / 技术债，含包体积）
- [ ] NOW.md 更新 + roadmap 索引

## 10. astra R1 裁决（09-26）

报告 `prompts/2026-09-26-xiaoya-v2/reports/r1-plan-review-astra.md`：5 阻断 + 20 重要/建议。🎩 抽核 A2（`AssistantTools.swift:467-473` add payload 无 entryId 键）/ A3（`AppIconView.swift:41` 只认 `ri-`）/ A5（`widgetTone` 仅 3 处声明）/ B6（`Page2AppearanceEditor.swift:248` onDisappear 即 save）/ C3（`RightPanelPlugin.swift:126-129` 已覆写 icon）五处全中。

| 编号 | 裁决 | 落点 |
|---|---|---|
| A1 旧 history 解码 | 收 | §4.1 / P2-1 |
| A2 世界书 payload（现网 bug） | 收 | §4.1 / P2-2 |
| A3 图标判据 | 收 | §3.4 / P1-2 |
| A4 试穿图标只读 shared | 收 | §5 / P3-4 |
| A5 widgetTone 无消费者 | 收：删出首批 | §5 |
| A6 main 与 tag 混用 | 已由 P0 实测解决 | §2 / research §8 |
| A7 事件契约 / 真实类型 | 收 | §6.1 |
| A8 针脚桌面不吃外观 | 收：不产提案 + 说明 | §5 |
| B1 typed patch / 空值语义 | 收 | §4.1 |
| B2 整份 draft 覆盖 | 收：盖章时套 patch | §5 |
| B3 预设目标锚 | 收 | §4.1 |
| B4 唯一落地闸门 | 收 | §4.3 |
| B5 提交顺序 / 失败一致性 | 收（不做跨存储事务，失败如实标注） | §4.4 |
| B6 preview 副作用 | 收 | §5 |
| B7 下载完整性 / 蜂窝 | 收 | §6.2 |
| B8 隐藏 tab 保活 / 内存 | 收 | §6.2 |
| B9 runId / 切层 | 收 | §4.3 |
| B10 关键词判 nope | 收：删启发式 | §3.2 |
| B11 滚动反馈环 | 收：固定占位 + 滞回 | §3.3 |
| C1 history 写盘 | 部分收：保留全量留档（粟粟 09-11 决定），只改写盘方式 | §4.1 |
| C2 账本裁剪后撤销失联 | 收 | §4.4 |
| C3 不需要图标迁移 | 收 | §3.4 |
| C4 平台 / 测试分层 | 收 | §5 |
| C5 wireHistory 回灌 | 收 | §4.1 |
| C6 权限缺键默认 | 收 | §4.5 |
| C7 验收缺项 | 收 | §9 |
| D1 账本要留 after | 收 | §4.4 |
| D2 表情状态简化 | 收 | §3.2 |
| D3 不先做 FM | 同意，不变 | — |
| D4 按页裁工具会挡外观 | 收：先全量实测 | §6.4 |
| D5 名字同源 | 收：同源 + englishName；Rosemary 不动（粟粟已认） | §3.3 |
| D6 图标范围 | 同意 | §3.4 |
| D7 验收矩阵 | 收 | §7 |
| D8 P0 回填 | 收 | §6.5 |
