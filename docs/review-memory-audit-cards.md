# 复盘 · 审计台堆叠卡片 + 重要度滑条

> plan：[plan-memory-audit-cards.md](plan-memory-audit-cards.md)（todo 1–8 已提交：`5921a072c` `f3b9340d3` `a1f9a388d` `650306ff3` `d83adb428` `75680c4d7` `a08e2bf9b` `6cb42fd0b`；9 说明书 facts、10 定向测试、11 本复盘随最后一个提交）。规格：`~/Desktop/cc-rp/记忆系统/审计台与C2提示词-规格.md` 第 7¾ 节。说明书 facts：`manual/facts/modules/memory-settings.md`。

## 一、边界情况

**输入 / 数据**
- 碎片池标记换成 `occurredDay != nil`（`Memory.swift:65`）：C2 每条必写，和 `importance` 同一段赋值一起存，所以现有库判定一条不变；拖重要度不再改来源、不再被横条「全部删掉」带走（`testImportanceDoesNotDecideOrigin`）。以后真有第二个写手往 `occurredDay` 写，判定又会不准——到时加来源字段。
- 重要度：库里还是 `Int?` 1–5；滑条连续拖、松手四舍五入吸整数；`setImportance` 夹 1–5，已失效的不改、值没变不改（`MemoryAudit.swift:196-203`）。没定的停在 3、写「没定」，**手没拖过不存**；拖离再拖回 3 才会把「没定」存成 3。
- 召回：没定 = 3，库里越界的先夹到 1–5（有效重要度 `Memory.effectiveImportance` / `recallPriority`，`Memory.swift:67-71`；召回加权、全量兜底排序、滑条初始化都读它，`Int.min` / `Int.max` 不溢出；全局备份导入时也夹，没定的仍是 nil，`FullDocumentMapping.swift:423`，10-17 astra #5）。全没定 / 全 3 时，全量兜底和 recall 搜库的顺序与改之前一字不差（金样原样，`testWeightByPriorityKeepsOrderWhenAllUnsetOrThree`）。
- 牌堆空了：有筛选 →「这些条件下没有…」+「清掉筛选」；「留下 / 删了」牌堆过完一遍 →「这一叠看完了」；其余同列表空状态。最后一张飞走后「↶ 撤回上一张」那一行还在。

**并发 / 时序**
- 牌堆最上面那张压住（`MemoryAudit.deck`，`MemoryAudit.swift:79-85`）：拖了重要度 / 改了类别（都算留）、改完不匹配筛选、C2 后台新写进来更新的，都不会把它顶走；它在别处被删 / 彻底删 / 在「删了」里被恢复就自动松开（`testDeckReleasesTopThatLeftTheSegment`）。
- 飞走先由本地状态 `flight` 驱动（`MemoryAuditPage.swift:445-458`），飞完才动数据 + 存盘；飞的时候按钮、撤回都点不了，连点不会重复执行。按下时记楼层 / 牌堆代次 / 目标 id（`MemoryAudit.DeckAction`）：飞的时候换段 / 改筛选 / 切列表 / 切楼层 / 离开页面，代次 +1，飞完的回调整个作废（不动库、不记过掉 / 撤回、不动压住的）；代次对得上也要按 id 重新查一遍、核对同楼层且还在那一边（`MemoryAudit.canCommit`，`commit` `:462`，10-17 astra #1）。
- 换段 / 改筛选 / iOS 进出选择 / 切列表 ↔ 牌堆 / 切楼层都走 `MemoryAuditViewState.resetDeck(rows:)`（`MemoryAuditPage.swift:39`）：代次 +1、清 `passed` / `lastAction`、**按新条件直接压住首张**（首张 id 没变时「首张一变就压住」的 onChange 不触发，原来会漏锁，10-17 astra #4）；记忆 app 父级持有的视图状态切楼层走 `clear()`（也 +1 代次）。

**失败重试**
- 存盘失败：顶上红字；不 rollback 主 context（全 app 共用），只把这次动过的几个字段放回原值（`MemoryAudit.Fields`，页面 `persist` `:749`，10-17 astra #3）——牌堆里留 / 删 / 恢复失败的卡回到原来那一边、放回最上面，撤回记录不动（重试成功后撤回的基线还是原来的）；列表、批量删、改类别、滑条同样放回（滑条跟着弹回）。
- 撤回：动作时拍下动作前 / 后的字段（reviewedAt / supersededAt / updatedAt 精确值、类别、重要度、userEditedAt），撤回前逐一比「动作后」，对不上（别处又改过 / 已经不在）就不动、撤回行置灰（`MemoryAudit.canUndo` / `undo`，`MemoryAudit.swift:133-146`，10-17 astra #2）；对得上就把这几个字段放回动作前。撤回存不成同样放回，撤回记录留着能再试。
- 减弱动态效果：飞出只淡出；下一张放大 / 上移、滑条吸附都不动画，直接到位（`MemoryAuditStack.swift:120-124` / `:235-241`，10-17 astra #6）。

## 二、和下一模块的交互风险

- **召回侧那一刀**：召回侧规格要把 recall 改成按层往下翻（PageIndex 那套），`RecallTool.searchL1` 会被改写；重要度加权是独立纯函数 `RecallTool.weightByPriority`（`RecallTool.swift:420-428`），挪过去即可。全量兜底的排序（`MemoryService.swift:581-593`）只在【开窗口】C 勾着时生效，C 默认不勾，眼下大多数人感受不到。
- **C3**：C3 做好后 C 推根索引，档案条目不再按行塞——到时「重要度 = 召回优先级」要在索引 / 点 md 那层重新落一次（哪个点先带、哪条先翻）。审计台「来源」枚举照旧留着 C3 的位置。
- **常驻**：这一刀没动常驻规则（重要度 5 不自动每轮带）。粟粟要是以后要「C 档案重要度 5 = 每轮带」，改 `MemoryInjector.isPersistent` 会同时改常驻页、记忆格「从聊天里记住的」那组、`MemoryResident` 的原因文字。
- **记忆格**：记忆 app 第一格列表行（`MemoryRow`）对档案仍不画重要度；她在审计台拖了，记忆格里看不出来。
- **常驻页 / 下一轮会看见什么**：读的是同一套组装函数，兜底顺序变了它自动跟着变（MemoryResidentTests 过）。

## 三、技术债

- 列表模式没有撤回（只有牌堆有）；横条「全部删掉」、⋯「都删掉」也不记撤回。
- 彻底删存盘失败：对象在主 context 里已标删除，放不回来（不 rollback 共享 context），卡会留在最上面、红字；下一次别处存盘会把它真删掉（列表里原来就是这样）。
- 飞出距离写死 ±700pt（`MemoryAuditStack.swift:107-133`）：iPhone 和 mac 面板够飞出屏；iPad 宽窗口下靠淡出兜底，可能看得到没完全出屏。
- 类别标签的位置要等截图再定：牌堆卡和列表行共用一份卡片内容，「类别 ▾ · 日期 · 《窗口》 · 你改过 · 图钉」在正文下面，没按 plan 草图挪到卡左上。
- 原来就有的「筛选 ›」（和 mac 的 ⋯ 图标）是薄荷字 / 薄荷 glyph 压在浅薄荷页面底上（前一版就有，粟粟 10-17 说不用动）；这一刀新加的切换按钮、撤回、「清掉筛选」都是棕灰 / 棕黑。
- `MemoryService.swift:989` / `:1000` 的 Sendable 警告是早就有的（向量补算那段），不是这一刀引入的。
- mac 列表多选时滑条不禁用（mac 没有「选择」模式）。
- 说明书 `scripts/manual/check.mjs` 在本工位跑不起来（工位里没有 `node_modules`，缺 `gray-matter`）；facts 已改，页面 `npm run rewrite` / `build` 没跑。
- **只编过、跑过单测，没在界面上看过**：牌堆（露边、飞走、翻上来、撤回动画）、切换按钮、滑条（列表行里和左右滑抢不抢手势）、空状态文案、390 宽、mac 面板 / 设置窗。

## 四、要验的 UI（给粟粟 / Warden，本工位不开模拟器）

先装 sim（iPhone 390 宽），再 mac。删都是标失效、能恢复。

**iOS 390 宽**
1. 记忆 app → 审计台格：「没看过」是一叠卡，后面两张露边；卡里正文（长的在卡里滚）、类别 ▾ · 日期 · 《窗口》、重要度滑条、底部「删 / 留」。点「留」往右飞、「删」往左飞，下一张翻上来。在卡上左右划没反应，划到边上照常翻页。
2. 滑条：拖着数字跟着变、松手吸到整数；老档案显示「没定」；拖完卡不飞，再按留 / 删才走。筛选「来源 = 改版前的原子档案」时拖一条，卡还在，来源不变。
3. 点类别改成别的：卡不飞；「类别」筛着时也不飞。
4. 「↶ 撤回上一张」：删的回来、留的回来；最后一张飞走后还能撤；没得撤时那一行是空的（卡片高度不跳）。
5. 筛选到一条都没有：「这些条件下没有没看过的」+ 棕黑「清掉筛选」；真过完：「没看过的都过完了」。
6. 筛选行「筛选 ›」右边的切换按钮：「留下」切成牌堆，按「留」只看下一张（库里不变），过完一遍「这一叠看完了」；「删了」切成牌堆，「恢复」往右飞、「彻底删」先确认再往左飞。切到别的格再回来，选择还在。
7. 右上「选择」→ 列表多选留 / 删 →「完成」回牌堆；「留下」「删了」默认是列表、行里是滑条（滑条单独一行在留 / 删上面）；列表行左右滑和滑条互不打架。
8. 390 宽：横条、三段、筛选行（含切换按钮）、卡片、两颗按钮、撤回行都不溢出；颜色没有蓝黄、新加的东西没有薄荷压浅薄荷；类别标签位置看着顺不顺（技术债里那条）。
9. 设置 → 记忆 → 整理 → 审计台推进来：默认同样「没看过」是牌堆。

**mac**
10. 记忆面板审计台格：牌堆、按钮、撤回；切换按钮切到列表后原生多选 + 底部操作条；设置窗里没有「跳到这条」。

**召回（要真请求，等粟粟点头）**
11. 【开窗口】C 勾着、全量模式：一条档案拖成 5、一条拖成 1，检查器里下一轮档案段 5 的在前；预算压小时 1 的先掉。
12. 让{助手} recall 一个词，重要度高的排得靠前（只在搜中的候选里调先后）。

## 五、验证

- mac / iOS build-for-testing：每项各编一次，最后一次 `cards-8-mac.log` / `cards-8-ios.log` → `** TEST BUILD SUCCEEDED **`（之后只改 docs / manual）。
- 定向 19 套（`cards-10-t.log`）全过：MemoryAuditTests、FragmentPoolTests、MemoryResidentTests、RecallToolTests、RecallVisibilityTests、RecallWindowSummaryTests、RecallYesterdayTests、MemoryFullPresenceTests、CatalogInjectionTests、CachePrefixStabilityTests、MemoryInjectionMeterTests、PromptRealPathGoldenTests（金样原样，没 RECORD）、InspectorRealPathTests、OpenWindowInjectionTests、SettingsSkeletonTests、MemoryTrashTests、MemoryPanelSafetyTests、MemoryHealthWarningTests、MainThreadIOBudgetTests。
- 说明书已同步（facts）；页面重写 / 构建没跑。
- 10-17 astra 六条修复（飞完回调作废 / 撤回逐字段核对 / 存不成局部放回 / 重置压住首张 / 有效重要度夹值 + 备份导入夹值 / 减弱动态效果）：mac `cfix-1-mac.log`、iOS `cfix-1-ios.log` → `** TEST BUILD SUCCEEDED **`；`cfix-1-t.log` MemoryAuditTests、MemoryResidentTests、RecallToolTests、MemoryFullPresenceTests、FragmentPoolTests、PromptRealPathGoldenTests（金样原样，没 RECORD）、InspectorRealPathTests、CachePrefixStabilityTests、GlobalBackupAssistantTests、BackupStoreTests 全过。界面仍没看过。
