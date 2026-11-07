# plan · 记忆审计台 + C2 提示词修正

✅ 粟粟 10-16 go：⧫1–6 全部按推荐（见第十一节）。第八½节「常驻记忆」（规格第 7½ 节）是 go 之后补的，⧫7 粟粟 10-16 已定：按推荐改（见第十一节）。

> 规格 = `~/Desktop/cc-rp/记忆系统/审计台与C2提示词-规格.md`（10-16，第 7 节是她的拍板，冲突按它）；背景 = `记忆系统v5.md`。
> 行号 = backend-2 当前 HEAD `0ed0f77e9`。人名一律变量：模板里 `{{USER_NAME}}` / `{{CHAR_NAME}}`，界面里取楼层变量。
> 这一刀**不做**：C3、召回侧、去重、自动合并 / 删除 / 标失效、「可能重复」提示、审 B4。

## 一句话

C2 提示词把「事实」定义死、「不记」补齐、加好 / 坏例子、「没有就交空」写硬；C2 改成**每满 N 条（默认 20，可调）**写一次，API 和 CC 两条路共用一份水位；【开窗口】C 默认改成**不勾**（改过的人不动）；新做**审计台**（设置 → 记忆 → 整理 · 怎么管 第一行 + 记忆 app 记忆格 ⋯），一条一张卡：留 / 删 / 改字 / 改类别 / 跳回原消息 / 批量；老「整理记忆」整个删掉；收尾时**总共 ≤5 条消息的窗口不写 A2 尾段、不写 A3**；记忆 app 记忆格最上面加一行**常驻记忆 · N 条 ›**，二级页上半列每一轮都带的、每条写清为什么带，下半是从 ⋯ 挪过来的「下一轮会想起什么」，钉住的从普通列表挪进去、取消钉住挪回来（第八½节）。

**请求体**：只有【开窗口】C 默认变了；没动过这一勾的人，下一轮起「关于{用户}」那段不带了。改过的人一字不变。金样要在夹具里把 C 钉成「勾着」才原样过（见 1.9）。

---

## 〇、粟粟 10-16 已定（照录规格第 7 节）

原话：
> 条数可选（因为偏大的能勾更多） 别的都按推荐 还有就是，只聊了5句话以内的窗口不走A2A3（不然就是浪费啊！）

| # | 定了 |
|---|---|
| 1 | C2 条数用户可选，默认 20 |
| 2 | 【开窗口】C 默认改「不勾」，直到 C3 做好；已经改过这一勾的人不动 |
| 3 | 老「整理记忆」按钮删掉，由审计台取代 |
| 4 | 审计台以后接 C3 结果：这一刀只留位置 |
| 5 | 来源字段：plan 查证后定 → 见第七节（**结论：不加来源字段**） |
| 6 | ≤5 条消息的窗口不写 A2 / A3（第八节）；门槛按推荐写死 5 |
| 7½ | （go 之后补）记忆格放「常驻记忆」，下一轮会看见什么挪进去，钉了挪上去、取消钉挪下来（第八½节） |

---

## 一、读码结论（带行号）

### 1.1 C2 碎片池现状

- 模板 `FragmentPool.defaultTemplate`：`MemoryPalace/Services/FragmentPool.swift:189-202`。自定义模板键 `customFragmentPrompt`（`:187`），`systemPrompt` 非空就用自定义（`:204-210`）。设置页 C2 二级页已经显示「默认 / 自定义（想换回默认，进去点用默认模板）」（`MemoryWriterPages.swift:345`）——规格要的「自定义」小字提醒**已经有了，不动**。
- 送进去的那截：每条 `[3] 名字：…`、每条最多 600 字（`FragmentPool.swift:182`、`:218-228`）；本机路线按 system 实际字数封顶，装不下从最早的往外丢（`:224-226`，`FragmentModelRoute.localUserBudget` `:121-124`，本机总预算 6000 字、system 上限 3000 字，`LocalLLMService.swift:275-276`）。
- 落库 `FragmentPool.write`（`:306-328`）：写前 `contents = Set(store.listAll(...).map(\.content))`（`:311`）——**一字不差**才算重复，listAll 含已失效的，所以删掉的垃圾原样再出现不会重进；`store.add(...)`（`:316-318`）后补 `occurredDay / importance / emotion / resolved`（`:319-322`）。
- 「每满几条写一次」现在是**两套**：
  - **API 窗口**：`ConversationViewModel.extractMemoriesIfNeeded`（`ConversationViewModel.swift:4694-4750`），每 N **轮**（`mem_extract_interval` 默认 3，`MemoryService.swift:400-403`；`ExtractScheduler` `:425-436`，每个会话首轮必跑）取**最近 7 条**（`memoryExtractWindow = 7`，`ConversationViewModel.swift:2280`、`:4703`）。计数器是整个 VM 一份、跨对话共用（`:2281-2283`）。设置页 C2「提取间隔 每 N 轮一次 1…10」（`MemoryWriterPages.swift:186`、`:341`）。
  - **CC 窗口**：`FragmentCCWatch`（`FragmentPool.swift:386-432`），`threshold = 6`（`:388`）条新消息认领一截，**最多 15 条**（`:419`）；水位**只在内存里**，第一次见一个窗口只记位置不回头补（`:401-409`）。调用点 `SessionCloseout.swift:1196-1240`。
  - 规格说的「原来 6」= CC 的 6 条 / API 的 3 轮×2。

### 1.2 档案库模型 + Q5 查证

`store.add` 落到 `@Model final class Memory`（`MemoryPalace/Models/Memory.swift:6-91`），`SwiftDataMemoryStore.add`（`MemoryService.swift:55-73`）。现有字段对审计台的用处：

| 审计台要的 | 现有字段 | 有没有 |
|---|---|---|
| 正文 / 类别 | `content` / `category`（`Memory.swift:17-18`） | 有 |
| 重要度 | `importance: Int?`（`:55`，v5 C2 才有，老条目 nil） | C2 的有 |
| 日期 | `createdAt`（`:40`）；C2 另有 `occurredDay`（`:54`） | 有 |
| 来自哪个窗口 | `sourceConversationId`（`:27`） | 有（极老的可能 nil） |
| 原话出处 / 跳回 | `sourceNodeId`（`:33`）；老 AUDN 还有 `sourceQuote`（`:32`），C2 写 nil（`FragmentPool.swift:318`） | 有 |
| 失效（删了） | `supersededAt`（`:34`） | 有 |
| 钉住 | `isUserExplicit`（`:29`） | 有 |
| **审过（留）** | — | **没有** |
| **你改过** | — | **没有** |
| **来源（C2 写的）** | 没有专门字段；`extractedBy` 存的是模型名（`FragmentPool.swift:317`），和老 AUDN 一样，分不开 | 见下 |

**Q5 查证：有现成字段能认出「C2 写的」**——`importance` / `occurredDay` / `emotion` / `resolved` 四个 v5 字段：
- 全仓只有 `FragmentPool.write` 写它们（`FragmentPool.swift:319-322`），且每条 C2 都必写（`importance` 是校验过 1–5 的非可选 Int，`:279`）；
- 别处只有备份导入原样搬运（`GlobalBackup/Schemas/FullDocumentMapping.swift:392-395`、`:420-423`），老备份里没有这几个键 = nil（`FullDocuments.swift:239-243`）；
- 其余写 `Memory` 的地方都不碰它们：手加（`AddMemorySheet.swift:135-139`、`MemorySettingsPage.swift:308-311`，`extractedBy: "manual"`）、Claude 记忆导入（`ClaudeMemoryImporter.swift:156`）、样例种子（`ChatSampleSeed.swift:70`）。
- 这四个字段随 `2912861ed`（2026-10-15 17:33 -0700）加进来，`f6a3443a3` 合进 master 的时间 = **2026-10-15 20:29:28 -0700**（`git log -1 --format=%ci f6a3443a3`）。在那之前库里不可能有非 nil 的 `importance`（每台设备库独立，`cloudKitDatabase: .none`，`MemoryPalaceApp.swift:259`）。
- 结论：「v5 碎片池」= `importance != nil`，**比规格里的「创建时间 ≥ 10-15」更准**（时间规则会把 10-15 以后手加 / 导入的也算进来），老条目**不用补任何东西**。决定见第七节。

### 1.3 常驻层

`MemoryInjector.isPersistent`（`MemoryService.swift:891-893`）= `isUserExplicit || category == "relationship" || category == "preference"`；常驻层 / 命中层的拆分在 `:481`、`:501`、`:568`、`:595`、`:783`。**但只在开了关键词或按意思找时用它**；默认全量模式下常驻层只收钉住的、其余全部每轮兜底带（细节见 8½.1）。所以审计台改类别（关系 → 事实）只在那两种模式下才让它不常驻；**但钉住的（`isUserExplicit`）不管类别都常驻**——卡上要露出图钉，免得她以为改了类别就不常驻了。
注意：这一切都要 C 勾着才生效——`roundInputs` 里 C 不勾整个档案就是空数组（`MemoryService.swift:688-690`）。

### 1.4 「整理记忆」（要删的）——全部引用点

| 位置 | 内容 |
|---|---|
| `Services/MemoryHygiene.swift`（整文件 135 行） | `MemoryHygiene.sweep` / `pairDedup`，向量 sim>0.75 两两合并 |
| `Views/MemoryOrganizeSheet.swift`（整文件 95 行） | `MemoryOrganizer` + `MemoryOrganizeSheet`，只被下面两处用 |
| `Views/MemoryPageContent.swift` | 行枚举 `.organize`（`:14`）、节里的位置（`:46`）、`showOrganize`（`:94`、`:124-126`、`:132`）、`rowView` 分支（`:173`）、`organizeRow`（`:409-423`，锚 `leaf-mem-hygiene`） |
| `Views/MemoryPanelView.swift` | `showOrganize`（`:219`、`:266-268`、`:299`），⋯ 菜单「整理记忆…」（`:735-740`） |
| `Views/Settings/SettingsSearch.swift:710-712` | 搜索条目 `leaf-mem-hygiene` |
| `Services/MemoryService.swift:1083-1084` | `MemoryExtractor.dedupSimilarityThreshold`，只有 `MemoryHygiene.swift:17` 用 |
| `MemoryPalaceTests/MV5HygieneTests.swift:65-137` | `pairDedup` 6 个测试（同文件 `:30-63` 是做梦毕业的 3 个测试，**留着**） |
| 文案 | `MemoryRevival.swift:4`、`:41` 注释和 `MemoryTrashSheet.swift:45` 成批标题「整理时合并掉的」 |
| 说明书 | `manual/facts/modules/memory-settings.md:52`；`docs/MODULE_INDEX.md:111`（自动生成） |

删除影响：向量模型 / 向量补算（`MemoryEmbeddingBackfill`）不受影响，hygiene 只是它的一个用户；以前整理合并掉的那批照旧在「已删除」里能恢复。

### 1.5 「找回失效的记忆」= 现在的「已删除」弹层

`MemoryTrashSheet`（`Views/MemoryTrashSheet.swift`，头注「替掉『找回失效的记忆』」`:4`）。删 = 标失效 / 已失效里再删才真删的规则已经是现成的：`MemoryDeletePlan`（`MemoryService.swift:296-345`，`moveToTrash` `:325-334`）、`MemoryRevival.revive`（`MemoryRevival.swift:49-55`）。
成批分组：同一分钟内失效 ≥3 条算一批（`MemoryRevival.swift:6-39`），标题写「X 整理时合并掉的 · N」（`MemoryTrashSheet.swift:45`）——审计台「全部删掉 / 这一页全部删」也是同一刻成批标的，会被叫成「整理时合并掉的」，**标题要改**（第六节）。

### 1.6 设置 → 记忆

- 骨架只写一份：`MemoryPageLayout`（`MemoryPageContent.swift:7-50`），「整理 · 怎么管」= `[.pending, .organize, .trash]`（`:46`）；`SettingsSkeletonTests.testOrganizeInjectRetrieve` 锁着它（`SettingsSkeletonTests.swift:26-31`）。
- 二级页路由 `SettingsRoute`（`Views/Settings/SettingsRoute.swift:5-28`），mac 要在 `MacSettingsPage.swift:40-68` 补标题和目的页。
- C2 二级页：`MemoryWriterPage` 的 `.c2` 分支「怎么记」（`MemoryWriterPages.swift:339-358`）。
- 【开窗口】C：`MemoryOpenWindow.isChecked(.c)` = `(defaults.object(forKey: "mem_open_c") as? Bool) ?? true`（`MemoryWriterSettings.swift:171`）；界面两处 `@AppStorage(MemoryOpenWindow.cKey) private var openC = true`（`MemoryPageContent.swift:90`、`MemoryWriterPages.swift:503`）；勾选只经 `check()` 写键（`MemoryWriterPages.swift:550-562`）。
- **「已改过」怎么判**：这个键只有三种来路——① 她在开窗口页点过勾（写 true 或 false）；② 设置导入（`ConfigSchema.swift:106`；导出时没写过的键跳过，`ConfigExporter.swift:53`，所以导入只带来真改过的值）；③ 没有别的：v5 拆分迁移只写 a2 / a4 两个勾（`MemoryWriterSettings.swift:272-281`），复杂度滑条只动写入开关（`:136-141`），`@AppStorage` 的默认值不会落盘。⇒ **`defaults.object(forKey: "mem_open_c") != nil` = 改过**，改默认只需把 `?? true` 换成 `?? false`，改过的人自然不动，不用迁移。
- 搜索条目：`SettingsSearch.swift:700-712`。

### 1.7 记忆 app「记忆」格 ⋯

`MemoryPanelView.moreMenu`（`MemoryPanelView.swift:716-757`）：记忆格有「加一条记忆 / 选择」，所有格共用的下半截有「关系图 / 整理记忆… / 下一轮会想起什么」。跳回原消息现成的：`jumpToSource`（`:942-955`，`viewModel.navigateToSearchResult`）。弹层惯例：`.sheet(isPresented:)` 包一层 `NavigationStack`（同 `MemoryTrashSheet.swift:7-19`）。
记忆 app 的「设置」分段也嵌着同一个 `MemoryPageContent()`（`MemoryPanelView.swift:474`），所以设置里加的「审计台」行两边都有。

### 1.8 收尾 `SessionCloseout`（第 5½ 节）

- 收尾队列 `queue(...)`（`SessionCloseout.swift:589-646`）：对每个候选窗口已经读出主线消息 `messages = mainPath(conv, ...)`（`:615`；`mainPathNodes` 按 `conversationId` 取这一个窗口的节点、只留 user / assistant 非空，`:1077-1095`）——**条数现成，不用另加任何 fetch**，更不碰全量 MessageNode。
- A3 / A4 各自算到点没有（`:620-632`），`combined` 合并（`:579-584`），只把到点的写手放进 `writers`。
- 收尾正文 `closeoutBody`（`:784-866`）：`.window` 到点才进 A3 那一块，**A2 尾段就在这一块里**（`:796-819`），A4 在后面单独一块（`:842-858`）。
- 对话 ⋯「现在写」走 `closeoutNow`（`:872-905`），自己拼 `Candidate`，`writers` 默认两样都有（`:498-501`），不经过 `queue`。
- ⇒ 在 `queue` 里「≤5 条就不给 `.window` 排状态」：A2 尾段和 A3 一起不写，A4 照常，「现在写」不受影响。

### 1.9 请求体金样

`PromptRealPathGoldenTests` 跑 `PromptRealPathHarness`，夹具里放了两条档案（`PromptRealPathHarness.swift:215-220`，一条偏好一条事实），并把【开窗口】四个勾**钉成没写过**（`:140-144`，`setDefault(MemoryOpenWindow.cKey, nil)`）。G1 / G3 / G4 / G5 / G6 / G8 六份金样都带 `[关于User]\n- 用户养了一只叫团子的猫 [事实]\n- 用户喜欢暖奶白配色 [偏好]`（如 `Fixtures/prompt-golden/G1-openai-full.json`）；G2 是记忆关的，不受影响。
⇒ 默认改「不勾」后，**照现在的夹具这六份会少掉「关于User」那段**。规格第 8 节说「金样应原样过」，前提是金样代表「已经改过（勾着）的老用户」：夹具改成 `setDefault(MemoryOpenWindow.cKey, true)`，六份一字不变；「没写过 = 不带」由 `OpenWindowInjectionTests` 单测锁。C2 提示词不进聊天请求体，模板改动不影响金样。

---

## 二、C2 提示词（改 `FragmentPool.defaultTemplate`）

表的形状（JSON 字段、校验、拒收）不动。有自定义模板的人不覆盖。

新模板全文草稿（`【⧫n】`= 该题已定（10-16）加上的行；其余是规格第 1 节原样落进来）：

```
这不是在跟你聊天。你是填表的工具：读下面这段对话，把里面的事实一条一条填进表里。
事实 = 过一个月还成立、还用得上的事：{{USER_NAME}}是谁、有什么、在做什么、喜欢 / 讨厌什么、身体和生活的状况、和{{CHAR_NAME}}之间定下的约定和关系变化。
大多数对话里没有新事实，交 {"fragments":[]} 是正常的。宁可漏，不要凑。

只输出一个 JSON 对象，不要别的字：{"fragments":[{"msg":3,"content":"……","tags":["……"],"importance":3,"emotion":0,"resolved":null,"category":"fact"}]}；没有就 {"fragments":[]}。
- msg：这件事出自第几条（方括号里的编号）。日期不用写。
- content：一件事一条，120 字以内，干的陈述句，主语写名字（{{USER_NAME}} / {{CHAR_NAME}}），不用「我」「你」，不写感受评价。
- tags：关键词，最多 5 个。
- importance：1 到 5，5 = 一直要记得。
- emotion：-2 到 2，这件事带的情绪，0 = 平常。
- resolved：事情了结了填 true，还悬着填 false，说不上填 null。
- category：preference / fact / relationship / goal / context 选一个。
【⧫5】  relationship 只放{{USER_NAME}}和{{CHAR_NAME}}之间定下的约定、关系变化；拿不准填 fact。
亲密互动里{{USER_NAME}}说的自身喜好、身体感受、边界都是真事，要记；只有括号里的动作描写和架空设定才算演出来的剧情。

不记：
- 客套闲聊、在问不是在说的（比如「这个报错是啥意思」）、报错 / 网络 / 工具失败、演出来的剧情（跳出剧情说的真事照记）。
- 对话经过：谁说了什么、谁承认 / 解释 / 道歉、谁看不懂谁——这些是时间轴的事，不是事实。
- {{CHAR_NAME}}说的话、做的事（只有对{{USER_NAME}}的承诺例外）。
- 把一句话原样抄成一条：content 必须是你自己写的陈述句，不是某一条消息的复制。
- 正在进行的工作步骤（「在写 plan」「收到单子了」）；只记做成了 / 定下来的结果。

坏例子（这些都不该进表）：
- 「{{CHAR_NAME}}承认漏了部分」——对话经过
- 「{{USER_NAME}}：这个每个对话里放 A2 和 A3 啊？」——把一句提问原样抄了
- 「{{CHAR_NAME}}：已经加进去了」——{{CHAR_NAME}}自己的话
好例子：
- 「{{USER_NAME}}在做记忆宫殿 app 的记忆系统，10-15 定了 A / B / C 三条线的分法」
【⧫4】例子只示范写法，别把例子里的事填进表。
```

和现在的差别（逐条可追到规格）：
- 第 1 行「把以后值得记得的事」→「把里面的事实」，接第 2 行的定义（规格 1-1：定义放第一段）。
- 第 3 行「没有就交空」写硬，紧跟定义（规格 1-4）。
- 原第 2 行「只记{{USER_NAME}}自己的事……除非是对{{USER_NAME}}的承诺」**删掉**：意思被第 2 行定义 + 「不记」第 3 条完整覆盖，留着等于说两遍（这是唯一一处删字，批注可以要回来）。
- 「不记」原来那一行原样保留成第 1 条，后面 4 条是规格 1-2 原话。
- 坏例子 3 条 = 规格第 0 节截图那 3 条（人名换变量），好例子 1 条 = 规格 1-3 原样。
- 模板里不出现「粟粟」「狗狗」「小克」：单测锁 `!defaultTemplate.contains("粟粟")` 等。
- 长度约 1100 字，本机路线 system 上限 3000 字（`LocalLLMService.swift:275`），单测锁 `defaultTemplate.count < LocalChatProvider.systemBudget`。

---

## 三、C2「每满 N 条写一次」

### 界面
C2 二级页「怎么记」第一行：把「提取间隔 · 每 N 轮一次」（`MemoryWriterPages.swift:341`）换成
`LimitStepper(title: "每满几条写一次", value: "\(n) 条（两边加起来）", range: 6...40, step: 2)`，键 `mem_c2_every`，默认 20。

范围建议 **6–40、步长 2**：下限 6 = 原来的量；上限 40 = API 那条路现成的取历史上限（`buildSideModelMessages(maxMessages: 40)`，`ConversationViewModel.swift:2702`）。本机小模型装不下时从最早的往外丢，已有逻辑（1.1）。

### 两条路共用一份水位
- `FragmentCCWatch` 改名 `FragmentWatch`，API / CC 都用它：`due(..., threshold: N)`，门槛 `6` → 读设置；一截最多 `15` → **N**（`FragmentPool.swift:388`、`:419`；切了分支「只看最后 6 条」→ 最后 N 条）。认领 / 提交 / 释放 / 旧快照不倒退照旧。
- **水位落盘**：现在只在内存里，第一次见一个窗口只记位置。门槛到 20 以后，iOS 被系统杀进程很常见——每次重开只聊十来条的窗口会**永远轮不到**。改成 UserDefaults 一个小字典 `mem_c2_marks`（窗口 id → 最后那条的 id + 时间），最多留 300 个窗口、超了扔最旧的（约 30 KB，远离 UserDefaults 膨胀那条线）。第一次见的窗口照旧「只记位置不回头补」（升级后不会把老对话重新过一遍）。
- **API 那条路**（`extractMemoriesIfNeeded`）：去掉「每 3 轮 + 最近 7 条 + 首轮必跑」，改成取这条路径的消息、交给 `FragmentWatch.due`；消息用 `sessionMessages()`（`ConversationViewModel.swift:4756-4763`，和 A2 同一口径、带时间，工具调用写成中性的 `[调用了 …]`），照旧滤掉 agent 消息（`:4702`）。
- 作废：`ExtractScheduler`（`MemoryService.swift:422-436`）、`MemoryFlags.extractInterval`（`:398-403`）、`extractRoundCounter / hasExtractedEverInSession / memoryExtractWindow`（`ConversationViewModel.swift:2280-2283`）、`MV2ThrottlingTests` 整个文件；`ConfigSchema` 的 `mem_extract_interval`（`ConfigSchema.swift:94`）换成 `mem_c2_every`；`MemoryMasterImportSyncTests.swift:59` 的样例键跟着换；搜索关键词「提取间隔」换「每满几条」（`SettingsSearch.swift:701`）。
- 老键 `mem_extract_interval` 不迁移：单位是「轮」、窗口是 7 条，换算不过来；所有人落到 20。

---

## 四、【开窗口】C 默认改「不勾」

- `MemoryWriterSettings.swift:171`：`?? true` → `?? false`；两处 `@AppStorage(... cKey) private var openC = true` → `false`（`MemoryPageContent.swift:90`、`MemoryWriterPages.swift:503`），否则「勾了几项」和勾的样子对不上。
- 改过的人（键里有值）一字不变；没动过的（含新装）下一轮起档案不进 prompt。
- 开窗口页 C 那一行下面加一行小字（⧫3 已定）：不勾时「档案先不带，等 C3 整理好再开；聊天中靠『检索』按需想起」。
- 金样夹具钉 C = true（1.9）。
- **会影响什么**：C 一勾管的是整个档案（`MemoryService.swift:688-690`），不只碎片池——老原子档案、她手加 / 钉住的也一起不带（⧫3 已定：不单拎）。召回工具不看这一勾（`RecallTool` 里没有 `MemoryOpenWindow`），所以「按需想起来」还在。

---

## 五、审计台

### 5.1 入口
- 设置 → 记忆 →「整理 · 怎么管」：**第一行「审计台」**，待续在它下面，已删除在最后 → `[.audit, .pending, .trash]`。行副标题「没看过 N 条」。新路由 `SettingsRoute.memoryAudit`（mac 补标题「审计台」和目的页）。新搜索条目 `leaf-mem-audit`（关键词：审计台 / 审 / 留 / 删 / 碎片池 / 整理 / 去重），顶掉 `leaf-mem-hygiene`。
- 记忆 app ⋯：「整理记忆…」那个位置换成「审计台」（图标 `checklist`），开同一页的弹层（`NavigationStack` 包一层，mac 给 `.frame(width: 520, height: 600)`，同已删除弹层）。
- 页面只有一份：`MemoryAuditPage`（`Views/MemoryAuditPage.swift`），设置里推入，记忆 app 里弹层。

### 5.2 页面（从上到下，390 宽）
1. **一次性横条**（只在有的时候出）：「v5 碎片池有 N 条还没看过 · 全部删掉 ›」，右边一个 ✕。
   - N = C2 写的（`importance != nil`）、没看过、活着、**创建早于这一版第一次启动**的（⧫6 已定）。点了弹居中 alert「把 N 条碎片移到已删除？可以在已删除里恢复」→ 标失效。用过或点 ✕ 后不再出（UserDefaults 一个布尔）。
2. **状态三段**（Picker `.segmented`）：没看过 N / 留下 N / 删了 N。
3. **筛选行**：一行小字写当前条件（如「v5 碎片池 · 关系 · 7 天内 · 2 个窗口」，`lineLimit(1)` 截尾），行尾「筛选 ›」打开一个小 sheet，里面四个 Picker：
   - 来源：全部 / 改版前的原子档案 / v5 碎片池（第七节怎么认）
   - 类别：全部 / 偏好 / 事实 / 关系 / 目标 / 近况（标签沿用 `MemoryCardView.categoryLabels`，`MemoryPanelView.swift:1216-1219`）
   - 日期段：全部 / 今天 / 7 天内 / 30 天内 / 自己选（两个 compact `DatePicker`：从 / 到）
   - 来自哪个窗口：全部 + 当前结果里出现过的窗口标题（按条数多→少）
   - 不用横向滚动的筛选条（横向 ScrollView 里按钮会被吞），390 宽只有一行字 + 一个按钮，不会溢出。
4. **卡片列表**（`List`，新→旧按 `createdAt`；行样式同 `MemoryRow`：没有色条、行内不再套一层底）：
   - 正文（收起 3 行，点开全文）
   - 信息行（一行，截尾）：`类别 ▾ · ●●●○○ · 10-15 · 《窗口标题》 · 你改过 · 📌`（重要度只有 C2 的有；钉住的露图钉，提醒「钉住的不管什么类别都常驻」）
   - 底行右侧两个小按钮：**留**（`Theme.branchIndicator` 描边）/ **删**（`Theme.danger`）；「删了」状态下换成 **恢复** / **彻底删**（彻底删弹确认，沿用 `MemoryDeletePlan.purgeTitle` 文案）；「留下」状态下只剩 **删**。
   - iOS 另给左右滑：左滑「留」、右滑「删」；mac 右键菜单 + 悬停 ⋯（同 `MemoryRow` 做法）放同一组动作。
   - **点类别**（信息行第一个）：Menu 五选一，选了立刻存（关系 → 事实下一轮就不常驻）。
   - **点正文**：展开 → 露出「原话」（按 `sourceNodeId` 只取那一条 `MessageNode`，`fetchLimit 1`，前 300 字；老 AUDN 的没有节点就显示 `sourceQuote`；都没有写「没有出处」）+「跳到这条 ›」+「改字」。
   - **改字**：复用 `AddMemorySheet`（`AddMemorySheet.swift:121-149`），加一个参数让审计台进来时**不自动钉住**（⧫1 已定），存的时候记 `userEditedAt`。
   - **跳到这条**：同 `MemoryPanelView.jumpToSource`（`:942-955`）。设置页用 `@Environment(ConversationViewModel.self)`（可选，同 `RecallCardView.swift:131`）；拿不到（mac 设置窗是另一个窗口）就不出这个按钮。从记忆 app 弹层跳先关弹层。
5. **批量**：右上「选择」→ 多选（iOS `editMode` 同记忆格的做法，mac 原生多选）→ 底栏「留 N」「删 N」（「删了」状态是「恢复 N」「彻底删 N」+ 确认）。
6. **这一页全部删**：⋯ 菜单里「把筛出来的 N 条都删掉」（只在没看过 / 留下状态），居中 alert 写清条数，删 = 标失效。
7. 空状态：沿用 `MemoryEmptyState`（「没看过的都过完了」等）。

### 5.3 规则
- **留** = `reviewedAt = now`，从「没看过」挪到「留下」。
- **删** = 标失效（`MemoryDeletePlan.moveToTrash`），进已删除弹层，可恢复；审计台「删了」= 所有已失效（含以前做梦毕业 / 整理合并掉的）。恢复不清 `reviewedAt`：没审过的恢复回「没看过」。
- **彻底删**只在「删了」里（同第一刀规则）。
- 改字 / 改类别**算「留」**（⧫2 已定）：改字 / 改类别时同时写 `reviewedAt`，卡挪进「留下」。
- 不自动合并、不自动删、不自动标失效；不提示「可能重复」；不审 B4。
- **给 C3 留位置**（拍板 4）：「来源」做成一个枚举，以后加「C3 整理结果」一档；这一刀不加界面。

### 5.4 代码分层
- `Services/MemoryAudit.swift`（纯函数，好测）：`State`（没看过 / 留下 / 删了）、`Origin`、`Filter`（来源 / 类别 / 日期段 / 窗口）、`apply(_ memories:, filter:, state:, now:)`、`keep / trash / restore / purge / setCategory / editText`、`v5BannerCount(memories:, cutoff:)`。数据一次 `listAll`（同记忆 app），在内存里筛——**不写 optional 谓词**（SwiftData optional 谓词查不到）。窗口标题按 id 集合一次取 `Conversation`（`#Predicate { ids.contains($0.id) && $0.profileId == pid }`）。
- `Views/MemoryAuditPage.swift`：页面 + 弹层包装。

---

## 六、删老「整理记忆」

照 1.4 的表全删。另：
- 「已删除」弹层成批标题 `\(日期)整理时合并掉的 · N` → `\(日期)一起删掉的 · N`（`MemoryTrashSheet.swift:45`），注释同步（`MemoryRevival.swift:4`、`:41`）。
- `manual/facts/modules/memory-settings.md:52` 和记忆 app 那份说明书事实同步（跑 `scripts/manual/check.mjs`）。

---

## 七、字段（Q5 结论）

**不加来源字段。** `Memory` 上加一个计算属性 `var isFragment: Bool { importance != nil }`（注释写清：只有 C2 写 `importance`，`FragmentPool.swift:320`），审计台「来源」：v5 碎片池 = `isFragment`，改版前的原子档案 = `!isFragment && createdAt < 2026-10-15 20:29 -0700`，10-15 之后手加 / 导入的只出现在「全部」里。老条目零迁移。单测锁「C2 写库一定带 importance」。
理由：查证下来这个标记是精确的、现成的；C3 按 v5 写的是点 md + 分层索引，不往 `Memory` 写；真有第二个写手往这张表写 `importance` 时再加字段不迟。

**新加两个可选字段**（SwiftData 轻量迁移：都是 `Date?`，老条目 nil；名字不撞 `isDeleted`；查询不进谓词）：

| 字段 | 意思 | 谁写 |
|---|---|---|
| `reviewedAt: Date?` | 审过（留） | 审计台「留」、改字、改类别（⧫2 已定） |
| `userEditedAt: Date?` | 你改过 | 审计台改字；记忆 app「编辑记忆」（`AddMemorySheet.swift:124-131`）；`SwiftDataMemoryStore.update`（`MemoryService.swift:75-91`，只有召回卡片和 mac 条目区两个界面在调，`RecallCardView.swift:107`、`MemorySettingsPage.swift:324`） |

备份同步改（不改会被覆盖检查拦）：`FullMemoryDocument` 加两个 `var … : Date? = nil`（`FullDocuments.swift:214-244`，同 v5 四个字段的写法，老备份没这两个键 = nil）、`FullDocumentMapping.swift:370-424` 两个方向各加一行、`SchemaCoverageCheck.swift:268-282` 的样例补上。`kSchemaV` 不升（v5 加字段时也没升）。

---

## 八、短窗口不写 A2 尾段 / A3（规格第 5½ 节）

- `SessionCloseout` 加 `static let shortWindowMax = 5` 和纯函数 `skipsSummary(messageCount:) -> Bool`（`<= 5`）。
- `queue`（`SessionCloseout.swift:620-625`）：`if let t = triggers[.window], !skipsSummary(messageCount: messages.count)` 才给 `.window` 排状态。`messages` 是已经读出来的主线 user / assistant 非空消息（两边加起来），**不加 fetch**。
- 效果：≤5 条的窗口收尾只写 A4；A2 尾段在 A3 那一块里（`:796-819`），一起不写；聊到第 6 条以后下一次收尾照常写，A3 压整个窗口（含前 5 条）。
- 「现在写」走 `closeoutNow` 不经 `queue`，照样能手动写 A2 尾段 / A3。
- 窗口总结格「正在记」（`queue(includeWaiting: true)`）对短窗口也不显示 A3 在等，口径一致。
- 已经写了的短窗口 A2 / A3 不删。
- 「≤5 条」按整个窗口的条数算，不管「记忆从哪天开始」切掉了几条。
- 代价：短窗口的 A3 水位永远不动，巡检每次会读一下它的主线（≤5 条，就这一个窗口的节点；A4 本来也要读）。
- **三代搬迁那半（短窗口跳过不搬）另有人在做（`plan-memory-migrate-3gen.md`），不进本单。**

---

## 八½、常驻记忆（规格第 7½ 节，go 之后补）

原话：
> 对哦，还有钉住这个狗东西。。。 干脆子应用，记忆-记忆那里放一个常驻记忆（下一轮会看见什么也在这里，点了进二级菜单。（pin了就自动挪上来，不pin就移下去。）不然我根本不知道为什么有些记忆会被带着。

### 8½.1 读码：「每一轮都带」到底由哪些规则组成

每一轮的记忆原料只从 `MemoryInjector.roundInputs` 来（`MemoryService.swift:684-700`），实发 `composePrompt`（`ConversationViewModel.swift:2351-2356`）和「下一轮会想起什么」都走它。分两块：

**① 档案（`Memory`）的常驻层**，由 `activeRetrievers()` 按「检索」那一节的开关组队（`MemoryService.swift:659-672`），常驻层 = 里面唯一的 stable 一路 `PersistentRetriever`（`:471-481`）：

| 检索开关 | 常驻层收谁 | 其余的 |
|---|---|---|
| **默认**：全量注入开、关键词 / 按意思找都关（`:669-670`） | `explicitOnly: true` = **只有钉住的**（`isUserExplicit`） | `FullFallbackRetriever(excludePersistent: false)`（`:588-600`）：**其余全部也每一轮都带**，按创建时间新→旧装到预算满为止——不是「聊到才想起」 |
| 开了关键词或按意思找（`:663-668`） | `explicitOnly: false` = `isPersistent`（`:891-893`）= **钉住的 + 类别是关系 + 类别是偏好** | 关键词 / 向量命中的才带；全量开着的话剩下的再兜底装满 |
| 三个都关（`:671`） | 没有 | 一条都不带 |

- 共同的闸：总开关 && 这个对话开着记忆（`:686`）&& 【开窗口】C 勾着（`:688-690`），任一不满足整个档案是空的。
- 预算：常驻层先装，每条 `guard usedTokens + cost <= budget`（`:734`），装不下的这一轮就不带；预算 = 注入预算（默认 10000，`:612-615`）减去 B4 用掉的（`:697-698`）。
- 实际带了谁有现成记录：`buildInjectionSplit` 返回 `hits`，每条带 `retrieverId`（`"persistent"` = 常驻层，`"fullFallback"` = 全量兜底，`:450-457`），`PromptAssembler.memoryLayers` 原样往外交（`PromptAssembler.swift:696-704`），非 cacheFriendly 的路也是同一个 `buildInjectionSplit`（`:769`）。

**② {助手}的记忆（B4，`SelfMemory` 文件）**：`SelfMemoryInjection.build`（`SelfMemoryInjection.swift:23-68`），闸 = 总开关 && 对话记忆 && 【开窗口】B4 勾着（`MemoryService.swift:691-696`）。
- **重要度 5 的：全部带全文**（`:27`）；
- **重要度 <5 的最近 N 条带全文**（`:28`），N = `MemoryFlags.selfRecentCount` = `mem_self_recent_count`，**默认 5**（`MemoryService.swift:407`；设置在开窗口页「带全文的最近几条」1–30，`MemoryWriterPages.swift:507`、`:528-529`）——规格里的「最近 3 条」只是举例，界面一律读这个变量；
- 其余的每轮各带**一行目录**（`:47-56`）；预算是注入预算的 `mem_self_budget_percent`（默认 100%），全文装不下就降成目录行（`:41`）。`Built` 现在只交出条数（`:16-21`），没交出是哪几条。

**③ 钉住**：存储就是 `Memory.isUserExplicit`（`Memory.swift:29`）；`MemoryPinPlan.apply` 钉 / 取消钉，钉的时候顺手 `decayWeight = 1.0`（`MemoryService.swift:320-333`）；「编辑记忆」存的时候也自动钉（`AddMemorySheet.swift:124-131`）。列表排序 `MemoryArchiveOrder.split`：活着的**钉住在前**，其余按创建时间新→旧（`MemoryService.swift:265-277`）。

**④「下一轮会想起什么」现在**：记忆 app ⋯ 菜单最后一项（`MemoryPanelView.swift:741-745`）→ `InjectionPreviewSheet`（`:259-262`，定义 `:1065-1180`）。取数 = `roundInputs` + `PromptAssembler.memoryLayers(recentMessages: [])`（`:1167-1178`），和实发同一套函数（预览 = 实发），只是按「刚开始聊」预览、不带最近对话。分两段：「每次都会想起的」= stable 文本（B4 段 + 档案常驻层）、「聊到相关话题才会想起的」= volatile 文本（`:1091-1092`）。⚠️ 默认全量模式下第二段装的是 `fullFallback`，其实每轮都带，标题不对（⧫7）。

**⑤ 记忆 app「记忆」格结构**（`MemoryPanelView.memoryList` `:409-446`）：iOS 顶上常驻搜索框（`:436-444`）→ 出问题时一行红提醒（`:418-420`、`:518-537`）→ `listSections`（`:542-573`）：「{助手}自己记下的 · N」组（`:546-554`）→「从聊天里记住的 · N」组（`:556-563`，行 `memoryRow` `:653-672`：左滑钉 / 取消钉、右滑删）→ 最底「已删除 · N ›」（`:594-618`）。数据：`refreshMemories` 一次 `listAll`（`:978-1000`），`activeMemories` = 搜索过滤后 `MemoryArchiveOrder.split(...).active`（`:968-970`）。

### 8½.2 规则抽成一份（预览 = 实发）

新加 `MemoryResident`（放 `Services/MemoryResident.swift`，纯函数）：
- `archiveRule() -> ((Memory) -> Bool)?`：直接从 `activeRetrievers()` 里拿那一路 `PersistentRetriever` 的判定（`explicitOnly ? isUserExplicit : isPersistent`），**不另写一份规则**；三个都关 → nil。`isPersistent` 从 `fileprivate` 放成 internal（审计台单测本来也要）。
- `reason(_ m: Memory) -> String`：钉住 →「你钉的」；否则 →「标成\(categoryLabels[m.category])」（标签取现成的 `MemoryCardView.categoryLabels`，`MemoryPanelView.swift:1216-1219`）。
- `SelfMemoryInjection` 加一个纯函数 `fullCandidates(_:recentCount:) -> [(SelfMemory, Reason)]`，`build` 改成调它（行为一字不变），`Built` 多交一个 `fullSlugs: Set<String>`（实际装进全文的）。原因：`.five` →「\(助手)的记忆 · 重要度 5」，`.recent` →「\(助手)的记忆 · 最近 \(MemoryFlags.selfRecentCount) 条」。
- 「这一轮带不带」的灰字（都是变量拼的，没有写死的名字 / 数字）：
  - 总开关关 / 这个对话关了记忆 →「记忆关着，现在不带」
  - 【开窗口】C 没勾（档案那几条）→「C 没勾，现在不带」；B4 没勾（{助手}的那几条）→「B4 没勾，现在不带」（编号取 `MemoryWriterID.code`）
  - 预算装不下（规则上算常驻，但 `hits` 里没有它 / `fullSlugs` 里没有它）→「超出注入预算，这一轮没带」
  - 带着的：不写灰字。
  - 判「带没带」= 跑一遍 `roundInputs` + `memoryLayers`（和下半同一次计算），拿 `hits` 里 `retrieverId == "persistent"` 的 id 和 `fullSlugs`；C 没勾时 `roundInputs` 给的档案是空的，所以列表本身另用 `listActive` + `archiveRule()` 算出来，全部标灰。

### 8½.3 记忆格（在原框架里加一环）

- 搜索框下面、红提醒下面，**最上面一组只有一行**：`常驻记忆 · N 条 ›`，下一行小字「每一轮都带的，点进去看为什么」；有灰的时候小字换成「其中 M 条现在不带」。N = 档案里符合 `archiveRule()` 的（活着的）+ B4 的全文候选。整行一个 `NavigationLink` / 按钮，390 宽两行字，不会溢出。
- 「从聊天里记住的」组：**不搜的时候去掉符合 `archiveRule()` 的那些**——默认模式下就是钉住的；所以钉一条 → 它从这组消失、上面计数 +1；取消钉 → 回到这组（按创建时间排进去）。开了关键词 / 按意思找时，标成关系 / 偏好的也算常驻、也挪上去（跟实际注入一致；在常驻页把类别改成事实，它就挪回来）。组头计数跟着变。`MemoryArchiveOrder.split` 的「钉住在前」在这组里就没意义了，排序不改（`MemoryTrashSheet` 等别处还在用）。
- **搜索时照旧全列**（含常驻的，带图钉），不然搜不到钉住的；常驻那一行搜索时藏起来。
- 「{助手}自己记下的」组不动：B4 不能钉，重要度 5 / 最近 N 条在常驻页里**再列一遍**原因，原组里照旧在（B4 本来就整段带，挪走反而找不到）。
- ⋯ 菜单拿掉「下一轮会想起什么」（`MemoryPanelView.swift:741-745`）和它的 `showInjectionPreview` / sheet（`:220`、`:259-262`）；顶部注释 `:172` 同步。

### 8½.4 常驻页（二级页，`Views/MemoryResidentPage.swift`）

在记忆 app 里推入（记忆格本来就在 `NavigationStack` 里，同「待续」用 `SettingsNavRow` 推页的做法）；标题「常驻记忆」。

**上半「每一轮都会带的」**
- 档案那几条：一行 = 正文（2 行）+ 信息行「原因 · 类别 · 日期」+ 灰字（有的话）。行尾不放按钮（390 宽留给正文）：
  - iOS 左滑「取消钉住」（只钉住的有）；mac 右键 / 悬停 ⋯ 同一组动作
  - 点信息行里的类别 → Menu 五选一（同审计台，走 `MemoryAudit.setCategory`，⧫2 已定改类别也算「留」）
  - 取消钉住 → 立刻从这一节消失、回到记忆格普通列表（同一个 `.memoryDidChange` 刷新）
- {助手}的记忆那几条：一行 = 描述 + 「原因」+ 灰字；只看，不给动作（B4 在文件库里改，不在这一刀）。
- 两小组各一个组头：「关于\(用户称呼)」（`PromptAssembler.archiveLabel`，`PromptAssembler.swift:707-710`）/「\(助手)的记忆」。
- 默认全量模式下，在上半最后加一行小字：「全量注入开着：另外 M 条档案也每一轮都带（预算内）」，M = `hits` 里 `fullFallback` 的条数——说的是实情，不展开成列表（几百条）。

**下半「下一轮会看见什么」**
- 把 `InjectionPreviewSheet` 的 `List` 内容抽成 `InjectionPreviewSections`（同一份 `buildPreview`、同一个 `layerSection`），常驻页直接放进来；外壳 sheet 删掉。
- 第二段标题按 ⧫7（已定 10-16）：全量注入开着时写「全量注入开着：预算内都带」；开了关键词 / 按意思找才写「聊到相关话题才会想起的」。
- 上下两半用同一次 `roundInputs` + `memoryLayers` 的结果，进页、`.memoryDidChange`、切楼层时重算一次。

**空状态**：一条常驻都没有 →「现在没有每一轮都带的记忆。在记忆列表里左滑一条『钉住』，它就会到这里」（{助手}名字用变量）。

**390 宽**：每行只有文字 + 灰字，没有并排按钮；灰字 `lineLimit(1)`；mac 同一个页。

### 8½.5 不做
- 不改常驻规则本身（关系 / 偏好常驻不常驻、全量注入怎么装），只把现状摆出来。
- 不在常驻页里改 B4、不改 B4 的重要度。
- 设置页不加入口（规格只说记忆 app 记忆格）。

---

## 九、影响范围 / 风险

| 改动 | 会碰到谁 | 风险 / 处理 |
|---|---|---|
| C 默认不勾 | 没动过这一勾的老用户：下一轮起「关于{用户}」整段消失，包括手加 / 钉住的 | 拍板就是要这样；⧫3 已定不单拎；页面加说明小字 |
| C 默认不勾 | 金样六份 | 夹具钉 C = true 后原样过；不钉会红（1.9） |
| C2 新模板 | 有自定义模板的人 | 不覆盖；二级页已有「自定义」提示 |
| C2 新模板 | 本机 1.7B / 4B | 模板变长约 300 字，system 仍远低于 3000 字上限；对话那截可用字数少一点（6000 − system） |
| N 默认 20 | 每次调用 token 约 ×3，次数约 ÷3 | 总花费差不多；写入预算照旧兜底 |
| 两条路共用水位 + 落盘 | API 窗口不再「首轮必跑」；升级后老对话不回头补 | 单测锁；第一次见只记位置（同 CC 现状） |
| API 路输入换 `sessionMessages` | C2 看到的工具调用从完整回放变成 `[调用了 …]` | 和 A2 同口径，噪音更少 |
| 删 `ExtractScheduler` / `mem_extract_interval` | 老配置导入带这个键 | `ConfigSchema` 没这个键了 = 导入时忽略（导入器按 schema 认键） |
| `Memory` 加两个字段 | SwiftData 轻量迁移、全局备份 | 都是可选；备份文档 / 映射 / 覆盖检查同步改，覆盖检查测试兜着 |
| 删整理记忆 | 搜索、骨架测试、说明书 | 第六节逐条改；`SettingsSkeletonTests` 跟着改 |
| 审计台全部删 | 已删除弹层成批标题 | 改成「一起删掉的」 |
| 审计台改字 | 和老「编辑记忆会自动钉住」的规则不一致 | ⧫1 已定：审计台不钉；老入口不变 |
| 短窗口门槛 | 只在收尾队列判 | 「现在写」不受影响；已写的不删 |
| 跳回原消息 | mac 设置窗拿不到聊天 VM | 拿不到不出按钮；记忆 app 里一定有 |
| 常驻记忆：普通列表去掉常驻的 | 记忆格计数、多选、跳过来高亮（`highlightedId`）、搜索 | 搜索时照旧全列；跳过来的目标若是常驻的，先推常驻页再高亮（跳转入口 `consumeDesktopMemory`）；多选范围 = 当前看得见的行（`visibleRowIds` `MemoryPanelView.swift:972-974` 跟着去掉常驻的） |
| 常驻记忆：开关一变列表跟着变 | 开 / 关关键词、按意思找 | 规则直接取 `activeRetrievers()`，和实发一致；关系 / 偏好会在常驻页和普通列表之间挪，这是实情 |
| `SelfMemoryInjection.build` 拆函数 | 每轮实发的「我的记忆」段 | 只抽出候选、多交 `fullSlugs`，输出文本一字不变——金样里有「我的记忆」就由金样兜着，另加单测比对拆前拆后 |
| ⋯ 拿掉「下一轮会想起什么」 | 说明书 / 搜索 | 说明书同步；设置搜索里没有它 |

不碰：召回工具、向量补算、做梦毕业、A2 正式段（`compress` / `compressCC`）、A4、B 线写入、注入预算 / 检索那一节、常驻规则本身。

---

## 十、验收

**单测 / 金样（交之前全过，grep 到对应 Test Suite passed）**
- `FragmentPoolTests`：新模板含定义 / 交空 / 三条坏例子 / 好例子；变量都替换掉、模板里没有写死的人名；长度 < `LocalChatProvider.systemBudget`；`FragmentWatch` 门槛 = N、一截 ≤ N、切分支看最后 N 条、落盘后新实例读得回水位、超 300 个扔最旧；写库一定带 `importance`（来源标记的前提）。
- 删 `MV2ThrottlingTests`；`MemoryMasterImportSyncTests` 换样例键。
- `OpenWindowInjectionTests`：没写过 = C 不勾；写过 true / false 各自照旧；`testArchiveCheckGatesRoundInputs` 改成「默认不带、勾上才带」。
- `PromptRealPathGoldenTests`：夹具钉 C = true，七份金样**一字不变**。
- `SessionCloseoutQueueTests`：5 条的窗口 A3 不到点、A4 到点；6 条两样都到点；`closeoutNow` 对 3 条的窗口照写 A3。
- 新 `MemoryAuditTests`：三种状态 + 四种筛选的组合；留 → `reviewedAt`；删 → 失效且进「删了」；彻底删只对已失效；改字记 `userEditedAt` 且不钉；关系 → 事实后不再常驻（`isPersistent` 从 `fileprivate` 放成 internal 给测试用）；横条只数截止点之前的 C2；改字 / 改类别同时写 `reviewedAt`（⧫2）。
- 新 `MemoryResidentTests`：默认模式只有钉住的算常驻；开关键词后关系 / 偏好也算；三个都关一条不算；原因文字（你钉的 / 标成{类别} / {助手}的记忆 · 重要度 5 / 最近 {N} 条，N 改设置跟着变）；C 没勾 / B4 没勾 / 预算装不下各自的灰字；取消钉后不再算常驻。
- `SelfMemoryInjection`：拆出候选函数后 `build` 输出逐字不变（拿现有用例前后比），`fullSlugs` 和全文块一一对应。
- `SettingsSkeletonTests`：「整理 · 怎么管」= `[.audit, .pending, .trash]`；搜索有 `leaf-mem-audit`、没有 `leaf-mem-hygiene`。
- 全局备份覆盖检查（`SchemaCoverageCheck` 相关测试）过。
- mac + iOS（`MemoryPalaceIOS`，iOS 26 模拟器）build 认 `BUILD SUCCEEDED` 字样。

**真机 / 模拟器（照规格第 6 节）**
1. C2 打开，在一个聊正经事的窗口聊满 20 条 → 记忆格新出现的条目没有「谁说了什么」、没有{助手}的话、没有原样照抄的单句；一条都不写也算对。
2. 设置 → 记忆 → 整理 → 审计台：两代都列出来，四种筛选和三种状态都能用。
3. 顶上「v5 碎片池 N 条 · 全部删掉」→ 确认 → 记忆格里那批没了；已删除弹层能看到（标题「一起删掉的」）、能恢复。
4. 一条「关系」改成「事实」→ 下一轮检查器里常驻层没有它（**前提：开窗口 C 勾着、这条没钉住、检索里开着关键词或按意思找**；默认全量模式下关系本来就不进常驻层，见 8½.1）。
5. 多选删三条 → 都进已删除。
6. （5½）新开窗口只聊 4 条，等收尾 → 只出时间轴，没有 A3；对话 ⋯「现在写」→ A3 写出来。
7. 390 宽截图：横条、三段、筛选行、卡片、底栏都不溢出（交之前自己截图看过）；mac 设置窗里也走一遍。
8. （7½）记忆格最上面一行「常驻记忆 · N 条 ›」；左滑钉一条 → 它从「从聊天里记住的」消失、N +1；进常驻页看到它，原因「你钉的」；在常驻页左滑取消钉 → 回到普通列表。
9. （7½）常驻页下半和原来 ⋯「下一轮会想起什么」内容一样；⋯ 里没有这一项了；检查器里本轮记忆段和常驻页对得上。
10. （7½）开窗口 C 不勾 → 常驻页档案那几条照样列、灰着写「C 没勾，现在不带」；{助手}的记忆那几条原因写「最近 {N} 条」，N 跟着开窗口页的设置变。
11. （7½）390 宽常驻页、记忆格顶上那一行不溢出；mac 记忆面板里也走一遍。

---

## 十一、⧫ 拍板记录

1. 已定（10-16）：审计台里改字**不钉**，只记「你改过」；记忆 app 老的「编辑记忆」照旧钉。
2. 已定（10-16）：改字 / 改类别**算「留」**，卡直接挪进「留下」。
3. 已定（10-16）：C 不勾时**不单拎**钉住的，整个档案不带；开窗口页 C 下面加一行小字写清。
4. 已定（10-16）：好例子**照规格用**，模板末尾加「例子只示范写法，别把例子里的事填进表」。
5. 已定（10-16）：category 那行**加一句**「relationship 只放两人之间定下的约定、关系变化；拿不准填 fact」，表的形状不动。
6. 已定（10-16）：顶上「全部删掉」**只算这一版装上之前** C2 写的。
7. ⧫ 常驻页下半「下一轮会想起什么」现在分「每次都会想起的 / 聊到相关话题才会想起的」两段；可是默认的「全量注入」模式下，第二段其实也是每一轮都带（预算内全带），这个标题是错的。要不要按实际改？推荐：**改**——全量注入时第二段标题写「全量注入开着：预算内都带」，开了关键词 / 按意思找时才写「聊到相关话题才会想起的」；文字和内容照旧从同一个函数来（详见第八½节 8½.4）。

- ⧫7 已定（10-16）：常驻页下半第二段标题按实际——全量注入开着写「全量注入开着：预算内都带」，开了关键词 / 按意思找才写「聊到相关话题才会想起的」。

（技术取舍狗自己定了，有异议直接批：不加来源字段、水位落盘、两条路共用水位、N 范围 6–40 步长 2、老「提取间隔」不迁移、短窗口在收尾队列判、金样夹具钉 C、mac 设置窗不出「跳到这条」。）

---

## 十二、todo（每项一个原子提交；实现时勾 ✅）

- [x] 1. C2 新模板（`FragmentPool.defaultTemplate`，含 ⧫4 / ⧫5 两行）+ `FragmentPoolTests` 提示词那两个测试改写 + 不写死人名 / 长度上限单测 ✅
- [x] 2. `FragmentCCWatch` → `FragmentWatch`：门槛 / 一截 / 切分支都按 N（`mem_c2_every` 默认 20）；水位落盘 `mem_c2_marks`（≤300）；单测 ✅
- [x] 3. API 路换成 `FragmentWatch` + `sessionMessages`；删 `ExtractScheduler` / `extractInterval` / 计数器 / `memoryExtractWindow` / `MV2ThrottlingTests`；CC 路传 N ✅
- [x] 4. C2 二级页「每满几条写一次」步进器；`ConfigSchema` 换键、`MemoryMasterImportSyncTests` 换样例键、搜索关键词 ✅
- [x] 5. 【开窗口】C 默认不勾（`isChecked` + 两处 `@AppStorage`）+ C 行说明小字（⧫3 已定）+ `OpenWindowInjectionTests` + 金样夹具钉 C = true，跑金样确认一字不变 ✅
- [x] 6. 收尾短窗口门槛（`shortWindowMax` / `skipsSummary` / `queue`）+ `SessionCloseoutQueueTests` ✅（门槛共用 `MemoryMigration.shortWindowMax`，不另定义）
- [x] 7. `Memory` 加 `reviewedAt` / `userEditedAt` + `isFragment`；备份文档 / 映射 / 覆盖样例；`store.update` 和「编辑记忆」记 `userEditedAt`；写库带 `importance` 单测 ✅
- [x] 8. `Services/MemoryAudit.swift`（状态 / 来源 / 筛选 / 动作 / 横条计数 + 截止点首启记录）+ `MemoryAuditTests`；`isPersistent` 放成 internal ✅
- [x] 9. ✅ `Views/MemoryAuditPage.swift`：横条、三段、筛选行 + 筛选 sheet、卡片（类别 Menu / 展开原话 / 跳到这条 / 改字）、滑动 / 右键、批量底栏、这一页全部删
- [x] 10. 入口：`SettingsRoute.memoryAudit` + mac 标题 / 目的页；「整理 · 怎么管」= `[.audit, .pending, .trash]`；搜索 `leaf-mem-audit`；记忆 app ⋯「审计台」+ 弹层；`AddMemorySheet` 加「不钉」参数 ✅（「不钉」参数第 9 项已加）
- [x] 11. 删整理记忆：`MemoryHygiene.swift`、`MemoryOrganizeSheet.swift`、两处 `showOrganize` / 菜单 / 行、搜索条目、`dedupSimilarityThreshold`、`MV5HygieneTests` 的 pairDedup 段；已删除弹层成批标题改「一起删掉的」 ✅（设置页那处 / 搜索条目第 10 项已删）
- [x] 12. `SettingsSkeletonTests` 跟着改；`manual/facts` 同步（`check.mjs` 过） ✅（测试第 10 项已改；check 唯一硬错是 `00-start/connect-model.md` 引用的 Onboarding 文件不存在，和本单无关）
- [x] 13. （7½）`SelfMemoryInjection` 抽出全文候选函数 + `Built.fullSlugs`（输出逐字不变）+ 单测 ✅
- [x] 14. （7½）`Services/MemoryResident.swift`：`archiveRule()` 取自 `activeRetrievers()`、原因文字、灰字判定（总开关 / C / B4 / 预算）+ `MemoryResidentTests` ✅
- [x] 15. （7½）`InjectionPreviewSheet` 内容抽成 `InjectionPreviewSections`（第二段标题按 ⧫7），⋯ 里「下一轮会想起什么」和它的 sheet 拿掉 ✅
- [x] 16. （7½）`Views/MemoryResidentPage.swift`：上半档案 / {助手}的记忆两组 + 原因 + 灰字 + 取消钉 / 改类别 + 全量注入那行小字，下半放 `InjectionPreviewSections`，空状态 ✅
- [x] 17. （7½）记忆格：最上面「常驻记忆 · N 条 ›」一行；不搜时「从聊天里记住的」去掉常驻的（组头计数、`visibleRowIds`、跳过来高亮跟着改），搜索时照旧全列 ✅
- [x] 17b. （规格 7¼，粟粟 10-16 加）记忆 app 底栏「记忆 / 窗口总结 / 时间轴 / 审计台」（审计台占原「设置」最右位）；「设置」挪到每格左上角按钮，点开**弹 sheet**（粟粟 10-16：不要内嵌，不然用户迷惑），内容仍是原记忆设置；设置 → 记忆 → 整理里「审计台」一行照留；记忆格 ⋯ 的审计台入口拿掉；mac 底部胶囊同样四格 ✅
- [x] 18. （7½）说明书 `manual/facts` 记忆 app 那份同步（常驻记忆、⋯ 少一项） ✅（没有单独的记忆 app facts，写进 `memory-settings.md`）
- [ ] 19. mac + iOS build（认 `BUILD SUCCEEDED`）+ 定向测试套件全过 + 七份金样一字不变
- [ ] 20. 模拟器 390 宽截图自查（审计台、开窗口页、C2 二级页、常驻页、记忆格顶上那一行）；mac 设置窗 + 记忆面板走一遍
- [x] 21. 复盘 `docs/review-memory-audit-desk.md`（边界 / 和 C3 的接口 / 技术债）+ 更新 `docs/now/backend-2.md` ✅（另加 §四 要验 UI 清单）
