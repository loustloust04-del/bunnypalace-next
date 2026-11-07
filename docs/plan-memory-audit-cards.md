# plan · 审计台改堆叠卡片 + 重要度滑条

✅ 粟粟 10-17 go：⧫1–7 全部按推荐（见第五节）；另加一条「留下 / 删了默认列表，但筛选栏旁一个按钮能切列表 ↔ 牌堆」（第 2.1 节）。

> 规格 = `~/Desktop/cc-rp/记忆系统/审计台与C2提示词-规格.md` **第 7¾ 节**（粟粟 10-17 定）；召回侧 = `~/Desktop/cc-rp/记忆系统/召回侧-规格.md`。
> 前情 = [plan-memory-audit-desk.md](plan-memory-audit-desk.md) / [review-memory-audit-desk.md](review-memory-audit-desk.md)（审计台第一版已合 master `4c05001a8`）。
> 行号 = backend-2 当前 HEAD `497e0bbb9`。
> 这一刀**不做**：左右划手势（规格原话禁止）、C3、召回侧分层翻（PageIndex 那套）、重要度 5 自动常驻、记忆格（记忆 app 第一格）列表的重要度显示、审 B4。

## 一句话

审计台「没看过」改成一叠卡片：一次只看最上面一张，卡底「删 / 留」，点了这张往左 / 右飞走、下一张翻上来；不加任何划的手势。右上「选择」切回现在的列表做批量；「留下」「删了」默认列表，筛选行一个按钮三段都能切列表 ↔ 牌堆。每张卡里一条重要度滑条（1–5，替换 ●●●●○），拖完松手就存；类别照旧点标签弹选择。顺手把「认 v5 碎片池」的标记从 `importance` 换成 C2 必写的另一个字段，否则老原子档案一拖重要度就被认成碎片池（见 1.2）。召回接最小一刀（⧫6）：recall 搜库按重要度加权、C 全量兜底按重要度排。

---

## 〇、粟粟已定（照录，不再问）

- 堆叠卡片（Tinder 式），**不要左划右划手势**（跟页面切换打架），只用按钮。
- 卡片上：正文、类别、日期、来自哪个窗口、出处（能跳回那条消息）；卡片**底部**两个按钮：留 / 删。
- 批量：右上角「选择」→ 切回列表视图，能多选留 / 删。
- 顶上筛选（没看过 / 留下 / 删了、来源、类别、日期、窗口）照旧，筛完堆叠只剩筛中的。
- 卡片内嵌**连续滑条 1–5**（替换 ●●●●○），直接拖，改完立刻生效。
- **重要度 = 召回优先级，就是一个东西**（10-17 确认）。
- 改类别在卡片里直接改（点类别标签弹选择）。
- 沿用前一版已定：删 = 标失效可恢复；改字 / 改类别**算「留」**（审计台 plan ⧫2）；改字不钉（⧫1）；横条只算这一版装上前 C2 写的（⧫6）。

原话：
> 对Tinder那种但是不要左划右划手势因为会跟页面切换操作打架。
> 对啊我说的就是这个重要度直接在卡片内能拖啊，而且这个不是反正都是碎片池。
> 重要度 和召回优先级 不是一个东西吗

---

## 一、读码结论

### 1.1 审计台现在长什么样

- **一页一份**：`MemoryAuditPage`（`Views/MemoryAuditPage.swift`），两处进同一页——记忆 app 底栏第四格（`MemoryPanelView.swift:375-380` iOS `Tab`，`:418-419` mac `switch tab`）和设置 → 记忆 → 整理第一行。父级持有 `MemoryAuditViewState`（`MemoryAuditPage.swift:10-21`：状态段 / 筛选 / 展开集合；`MemoryPanelView.swift:215`），mac 切格重建页面不丢。
- **主体是一张 `List(selection:)`**（`MemoryAuditPage.swift:64-77`），行 = `card(_:)`（`:241-272`），新→旧按 `createdAt`（`MemoryAudit.apply`，`MemoryAudit.swift:72-75`）。行里：
  - 正文收起 3 行、点开全文 + 原话 +「跳到这条 ›」+「改字」（`:243-265`，原话 `MemoryAuditSourceView` `:572-601`）；
  - 信息行 `类别 ▾ · ●●●○○ · 日期 · 《窗口》 · 你改过 · 📌`（`infoLine` `:275-313`；●●●○○ 在 `:277`，只有 `importance != nil` 才画；类别是 `Menu`，选了立刻 `MemoryAudit.setCategory` 存，`:282-300`）；
  - 底行右侧小胶囊：没看过「留 / 删」、留下「删」、删了「恢复 / 彻底删」（`buttons` `:316-327`）；
  - iOS 左右滑（`.swipeActions` `:68-69`，`leadingSwipe` / `trailingSwipe` `:343-364`），右键 / 长按同一组动作（`:75-77`、`:368-387`）。
- **顶上** `safeAreaInset(.top)`（`:81`、`header` `:149-214`）：一次性横条「v5 碎片池有 N 条还没看过 · 全部删掉 ›」、存盘失败红字（`:178-183`）、状态三段 Picker（`:184-190`）、筛选摘要 +「筛选 ›」（筛选 sheet `MemoryAuditFilterSheet` `:605-724`），mac 的 ⋯ 在筛选行尾（`:204-207`）。
- **批量**：iOS 工具栏右上 `MemorySelectButton`（`:419-422`，定义 `MemoryPanelView.swift:1163-1173`，就是切 `editMode`）→ 底栏「留 N / 删 N」（`batchButtons` `:447-464`），多选时藏系统页签栏（`:87`、`MemoryPanelView.swift:401`）。mac 没有「选择」按钮，靠 List 原生多选，选中了底部出操作条（`:97-99`、`:430-442`）。
- **存盘**：`didChange()`（`:523-534`）——存成功才清选择、发 `.memoryDidChange`；失败顶上一行红字「保存失败：…」、选择留着（10-16 astra #7）。重读 `reload()`（`:558-566`）一次 `listAll`。
- **空状态**：三段各一句（`:397-403`），筛完为零也走这个（不区分「真没了」和「被筛没了」）。

**堆叠怎么加进来**：不整页重做。顶上（横条 / 三段 / 筛选行）一字不动；只把**「没看过」且不在「选择」里**时的主体从 `List` 换成一叠卡片；「选择」一按、或切到「留下 / 删了」（见 ⧫1），主体就是现在这张 `List`，行为照旧。卡片和列表行共用同一个卡片内容视图（正文 / 类别 / 日期 / 窗口 / 原话 / 滑条），只是外框和按钮位置不同。

### 1.2 importance 现状的坑（必须先处理）

- 字段：`Memory.importance: Int?`（`Models/Memory.swift:55`，1–5）；**碎片池判定** `var isFragment: Bool { importance != nil }`（`:63-64`）。
- 全仓**只有 C2 写它**：`FragmentPool.write`（`Services/FragmentPool.swift:330-357`，`m.importance = f.importance` 在 `:342`），C2 校验过 1–5（`:299`）。另外只有全局备份原样搬（`FullDocumentMapping.swift:393`、`:423`）。记忆 app 列表行对档案一律 `importance = nil` 不画（`MemoryRow.swift:45`）。
- 谁靠 `isFragment` 认碎片池：
  1. 审计台「来源」筛选：`MemoryAudit.origin(of:)`（`MemoryAudit.swift:36-39`）——是碎片 → `.fragmentPool`；否则建于 10-15 20:29 前 → `.legacyAtomic`。
  2. 一次性横条要删的那批：`v5BannerTargets`（`MemoryAudit.swift:182-184`）= `isFragment && 没看过 && 截止点前建的`。
- **坑**：审计台一旦允许给老原子档案拖重要度，`importance` 从 nil 变成数字 → `isFragment` 变 true →
  - 「来源 = 改版前的原子档案」筛着时，**拖完这张卡当场从筛选结果里消失**（堆叠里就是卡自己没了）；「来源 = v5 碎片池」里凭空多出老条目；
  - 横条「v5 碎片池有 N 条 · 全部删掉」会把**拖过重要度、但还没按留的老档案**算进去——一点「全部删掉」就把她的老档案标失效。（如果拖重要度算「留」，那条因为不在「没看过」逃过一劫，但规则靠巧合兜着，不可靠。）
- **处理方案对比**：

| 方案 | 做法 | 迁移 / 备份 | 评价 |
|---|---|---|---|
| **A 换标记（推荐）** | `isFragment` 改看 `occurredDay != nil`。C2 每条必写 `occurredDay`（`FragmentPool.swift:341`，`MemoryDay.key` 返回非可选 `String`，`MemoryDay.swift:18`），且和 `importance` 是同一段连续赋值、一起存（`:341-345`，存一次 `:350`）——库里现有数据 `importance != nil ⇔ occurredDay != nil`，判定结果一条不变。除 C2 和备份映射（`FullDocumentMapping.swift:392`、`:422`）外没人写它 | **零迁移**，备份格式不变 | 一行改动；`importance` 从此谁都能拖，来源只看出身。风险：以后真有第二个写手往 `occurredDay` 写，判定又不准——单测锁「只有 C2 写 occurredDay」，到时再加来源字段（同前一版 plan 第七节的理由） |
| B 加来源字段 | `Memory` 加 `origin: String?`，C2 写 "c2"；老 C2 条目按 `importance != nil` 一次性补 | SwiftData 轻量迁移（可选字段，安全）；全局备份要同步改 `FullMemoryDocument`（`FullDocuments.swift:214-246`）、映射两向、`SchemaCoverageCheck.swift:268-282` 样例 | 最明确，但比 A 多三处备份改动 + 一段启动补数据，结果和 A 一样 |
| C 重要度另存 | 加 `userImportance`，C2 的 `importance` 只当出身标记 | 同 B | 两个字段表示「一个东西」，和规格「就是一个东西」拧着，不选 |

→ 推荐 **A**（⧫4 只问她「反正都是碎片池」的意思，技术上 A 两种答案都能兼容：她要「拖了就算碎片池」也只是改 `origin(of:)` 一处）。

### 1.3 `Int?` 和「连续滑条」

- 库里 `importance: Int?`；C2 交的是整数 1–5（`FragmentPool.swift:172`、`:299`）；小克的记忆（B4）也是整数 1–5，且「5 = 每轮全文带」（`SelfMemoryInjection.swift:41-42`）——全花园重要度是同一把五档尺。
- 改成 `Double`：SwiftData 改已有属性的类型**不是轻量迁移**，得新加一个 `Double?` 字段再搬值，备份文档 / 映射 / 覆盖检查都跟着改；C2 / 显示 / 召回都要换口径。
- **推荐：滑条拖起来是连续的（不设 step、不跳格），松手吸到最近的整数存 `Int`**。手感是「直接拖」，存的还是五档；整数也让「重要度 5」这种说法在 B4 / C 之间保持同一个意思。真要存 3.7 这种小数再按方案 B 那样加字段（⧫3）。
- 现成写法可抄：设置页「复杂度」滑条（`MemoryPageContent.swift:314-321`，`Binding` + `rounded()`），群聊间隔滑条松手才提交（`GroupChatSettingsTab.swift:62-65`，`onEditingChanged`）。mac 设置里另有 `MacSettingsSlider`（`GeneralSettingsPages.swift:202`），但审计台在记忆面板里，用系统 `Slider` 即可。

### 1.4 召回现在用不用 importance —— **完全不用**

全仓读 `Memory.importance` 的只有审计台那排圆点（`MemoryAuditPage.swift:277`）和 `isFragment`（`Memory.swift:64`）。各路排序：

| 路 | 在哪 | 怎么排 | 看不看重要度 |
|---|---|---|---|
| 常驻层（stable） | `PersistentRetriever` `MemoryService.swift:463-475` | 钉住（纯全量模式）/ 钉住 + 关系 + 偏好（开了关键词 / 向量），按 `createdAt` 升序（缓存前缀稳定） | 否。判定 `isPersistent` `:882-884`，注释原话「AUDN 无 importance，用 category 替代」 |
| 关键词 | `KeywordRetriever` `:479-524` | BM25 分降序 | 否 |
| 按意思找（向量） | `VectorRetriever` `:528-571` | 余弦 ≥0.35，降序取前 20 | 否 |
| 两路同开 | `rrfFuse` `:824-844` | RRF | 否 |
| 全量兜底 | `FullFallbackRetriever` `:576-591` | `createdAt` 降序，预算装不下截掉最老的 | 否 |
| recall 工具搜库（拉） | `RecallTool.searchL1` `RecallTool.swift:375-409` | 关键词 + 向量 RRF，**只给前 4 条**（`maxL1Hits` `:19`）；不给词时按 `createdAt` 降序 | 否 |

另外：C 档案的「推」现在默认就不推——【开窗口】C 默认不勾（`MemoryWriterSettings.swift:172`，`roundInputs` 里没勾就不取档案 `MemoryService.swift:687-689`），召回侧规格第 3 节也写明「C3 做好之前 C 不推」。所以眼下 C 的重要度真正能起作用的地方只有 **recall 工具搜库** 和 **C 勾着的人的全量兜底**。

**规格有没有要求这一刀接召回**：第 7¾ 节只有一句定义「重要度 = 召回优先级，就是一个东西」，没写「这一刀把召回接上」。召回侧规格里和「优先级」有关的只有：§0 推 C =「关系 / 偏好类常驻 + 关键词 / 向量命中」、§2 B4「重要度 5 全文」（那是小克的记忆自己的重要度）、§3¾ Q11「优先级」指 A 线按情绪浓度排（另一件事）——**都没有 C 的重要度进召回这一条**。可她 10-17 的原话说明她以为现在已经是一个东西了；只上滑条不接召回，滑条就是个摆设。→ ⧫6 问接不接，推荐接最小一刀（第 2.9 节）。

### 1.5 「拖了立刻生效」怎么存、算不算「留」

- **存的时机：松手存**。拖动中只改卡片自己的本地值（不碰 `Memory`、不存盘、不发通知）；`Slider` 的 `onEditingChanged(false)` 时把吸好的整数写进 `importance`、`updatedAt`，存盘 + 发 `.memoryDidChange`。不做拖动中节流写库：每次存盘都会发通知 → 记忆 app 后台重算常驻摘要（review 第三节「记忆格每次 refresh 都多跑一遍 summary」），拖一下发十几次没必要；松手就是「立刻」。
- **松手值没变就不存**（含「没定」的停在 3 没动）：免得手指碰一下滑条就把一条老档案标成「重要度 3 + 审过」。
- **失败**：沿用 `didChange()` 的红字（`MemoryAuditPage.swift:523-534`）；同改类别，不 rollback（主 context 全 app 共用，前一版复盘技术债），滑条停在新值。
- **算不算「留」**：照「改类别算留」（前一版 ⧫2，`MemoryAudit.setCategory` 同时写 `reviewedAt`，`MemoryAudit.swift:143-148`），拖重要度也写 `reviewedAt`。但堆叠里「算留」不能让卡自己飞走（拖完还想改类别 / 还想删）——见 ⧫2 和第 2.3 节「压住当前这张」。
- 性能：滑条的本地值放在**卡片子视图自己的 `@State`** 里，拖动只刷那一小块；要是放在页面上，每一帧都会重算 `rows`（`MemoryAuditPage.swift:56`：全量过滤 + 排序）。

### 1.6 手势 / 底栏 / mac

- 记忆 app 在页 2，左右划是翻页（她说的「页面切换」）；iOS 底栏是系统 `TabView`（`MemoryPanelView.swift:349-387`），点按切格。堆叠里**不挂任何 `DragGesture`**，卡片内唯一的横向拖动是滑条本身（`Slider` 自己吃掉手势，不外溢）。
- 列表视图里现有的 `.swipeActions` 是 `List` 行的系统左右滑（和记忆格同款），她没提，照旧保留（只在列表视图里）。
- **mac**：没有页面切换冲突，但同一份页面、同一套按钮，不另做一套（`MemoryPanelView.swift:409-433` 里审计台就是同一个 `MemoryAuditPage`）。mac 现在没有「选择」按钮（靠原生多选），牌堆模式下进不了多选 → 用筛选行的列表 ↔ 牌堆切换按钮（2.1）切到列表即可，不另加「选择」。
- **mac 键盘快捷键：这一刀不加**。记忆面板和聊天输入框在同一个窗口，不带 ⌘ 的键（↩ / ⌫ / ← →）会被当快捷键先截走，抢输入框；带 ⌘ 的（⌘Z）又和输入框撤销撞。要加以后再说。（技术取舍，有异议直接批。）

---

## 二、方案

### 2.1 什么时候是堆叠、什么时候是列表

| 状态段 | 默认 | 按切换按钮 | 按了「选择」（iOS） |
|---|---|---|---|
| 没看过 | **牌堆** | 列表 | 列表（现在那张，能多选留 / 删） |
| 留下 | 列表 | 牌堆 | 列表多选（照旧） |
| 删了 | 列表 | 牌堆 | 列表多选（照旧） |

列表行里同样换成滑条（见 2.4）。

**切换按钮**（⧫1 加的那条）：筛选行「筛选 ›」右边一个图标按钮——现在是列表就画 `rectangle.stack`（点了切牌堆），现在是牌堆就画 `list.bullet`（点了切列表），`accessibilityLabel`「切成牌堆 / 切成列表」。图标用棕灰 `Theme.textSecondary`：它直接压在浅薄荷页面底上，不用薄荷色（`feedback_no_green_on_green`）。iOS 在「选择」中藏起来（那时一定是列表）。mac 同一个按钮，mac 切到列表就是原生多选 + 底部操作条，所以 mac 不再另加「选择」。

**记不记、记在哪**：记在 `MemoryAuditViewState`（记忆 app 父级持有，`MemoryPanelView.swift:215`）里一个 `stackStates: Set<MemoryAudit.State>`，默认 `[.unreviewed]`。在记忆 app 里切格、mac 切格重建页面都不丢；切楼层（`clear()`）、App 重启回默认；设置页推进来的那份自己持有，每次进来都是默认。**不落盘**（不进 UserDefaults）——最简单，也不会出现「哪天切过一次、之后一直是牌堆自己忘了」。

**留下 / 删了切成牌堆时卡底的两颗按钮**（同列表行现有动作，`MemoryAuditPage.swift:316-327`，只多一个「下一张」的意思）：

| 段 | 左（往左飞） | 右（往右飞） |
|---|---|---|
| 没看过 | 删 | 留 |
| 留下 | 删 | 留（不改数据，只是这张过了、看下一张） |
| 删了 | 彻底删（照旧先弹确认） | 恢复 |

「留下」里按「留」不写库（不刷 `reviewedAt`），只把这张记进本次「看过了」集合（`MemoryAuditViewState.passed`），牌堆不再出它，换段 / 改筛选 / 切列表清空；所以「留下」里的牌堆过完一遍就空（空状态「这一叠看完了」）。撤回同样对它生效（从 `passed` 拿出来）。

### 2.2 卡片长相（iPhone 390 宽）

```
┌ 页面底 Theme.sidebarBg（浅灰薄荷）──────────────┐
│ [横条] v5 碎片池有 N 条还没看过 · 全部删掉 › ✕   │  ← 照旧
│ [ 没看过 41 | 留下 3 | 删了 12 ]                  │  ← 照旧
│ v5 碎片池 · 7 天内              筛选 ›  (mac: 选择 ⋯)│ ← 照旧
│  ┌────────────────────────────────────┐╮╮        │  后面两张露边：各下移 6pt、缩 0.96 / 0.92
│  │ 事实 ▾                     📌 你改过 ││        │  卡 = Theme.mainBg 暖奶白、圆角 16、细阴影
│  │                                     ││        │
│  │ 粟粟周三要去复诊……（正文，可滚）       ││        │  m.body；点正文展开原话
│  │                                     ││        │
│  │ 10月15日 · 《周三复诊》               ││        │  m.caption Theme.textMuted，一行截尾
│  │ ┌ 原话：……（展开才有）┐ 跳到这条 › 改字 ││        │
│  │ ─────────────────────────────────── ││        │
│  │ 重要度  1 ━━━━━━━●━━━━ 5      4      ││        │  Slider tint Theme.branchIndicator；没定写「没定」
│  │ ┌──────────┐      ┌──────────┐      ││        │
│  │ │    删     │      │    留     │      ││        │  删：Theme.danger 描边红字；留：薄荷实心白字
│  │ └──────────┘      └──────────┘      ││        │  （MemoryPrimaryButtonStyle，压在奶白卡上）
│  └────────────────────────────────────┘╯╯        │
│                ↶ 撤回上一张                        │  只在有可撤的时候出；棕灰字，压在页面底上
└──────────────── iOS 底栏（系统）────────────────┘
```

- 尺寸：卡宽 = 页宽 − 2×16（390 → 358），内边距 16（内容 326）；卡高填满「筛选行下方 → 撤回行上方」，正文区 `ScrollView` 自己滚，长正文 + 展开原话不撑破卡。估算可用高：390×844 约 500pt，最小的 iOS 26 机型（375×667）约 380pt，都放得下「类别行 + 4 行正文 + 日期行 + 滑条 + 按钮」。
- 两个按钮各占一半（(326−12)/2 ≈ 157pt），高 44，在卡里——**不压到 iOS 底缘手势带**（底栏在下面隔着）；设置页推进来时没有底栏，撤回行下面留安全区。
- 配色：只用暖奶白 / 浅灰薄荷 / 醒目薄荷 / 棕灰字 / 危险红，**没有蓝、没有黄**。按 `feedback_no_green_on_green`：实心薄荷「留」只放在奶白卡里（白字压实心薄荷，外面是奶白底 ✓），不放在浅薄荷页面底上；页面底上的新字（「↶ 撤回上一张」、筛完为零的「清掉筛选」）用棕黑 / 棕灰（`Theme.textPrimary` / `textSecondary`），不用薄荷字。滑条已填部分薄荷、未填系统灰，在奶白卡上 ✓。
- 类别标签就是现在那个 `Menu`（`MemoryAuditPage.swift:282-300`）。实现时（第 5 项）没挪到卡左上：牌堆卡和列表行共用同一份卡片内容，信息行（类别 ▾ · 日期 · 《窗口》 · 你改过 · 图钉）照旧在正文下面，等截图再定要不要挪。

### 2.3 堆叠的行为

- **一叠 = 现在的 `rows`**（`MemoryAudit.apply`，状态 = 没看过 + 筛选，新→旧），只画最上面三张（库里几百条也只建三张视图）。
- **压住当前这张**（`MemoryAuditViewState` 加 `topId: UUID?`）：一张卡翻到最上面就记下它的 id，之后只要它还活着，不管它还匹不匹配筛选，都留在最上面，直到按「留 / 删」或者换状态段 / 改筛选 / 进出「选择」。理由三个：①拖重要度 / 改类别 / 改字都算「留」，不压住卡会自己飞走；②「类别 = 关系」筛着时把它改成「事实」，不压住也会自己没了；③C2 在后台写进新碎片（新的排最前），不压住会把她正看的那张顶下去。纯函数 `MemoryAudit.deck(rows:all:state:top:passed:)`：top 在 `all` 里且同一状态段（「删了」段要已失效、另两段要活着）→ 放第一，其余按 `rows` 去掉 `passed`（2.1「留下」里按「留」过掉的）。别处把它删了（失效）/ 彻底删了 → 自动松开、下一张上来。
- **飞走**：「留」往右、「删」往左飞出 + 稍转一点角度 + 淡出，下一张从后面放大到位。动画由页面自己的状态驱动——在 `withAnimation` 里先把这张记进「刚飞走的」（id + 方向）、松开 top，再调 `MemoryAudit.keep / trash` 存盘；不靠存盘后的 `.memoryDidChange` → `reload()` 触发（那条链路异步，动画事务会丢，见 `feedback_swiftui_animation_transaction_traps`）。存盘失败：红字 + 这张飞回来。开了「减弱动态效果」就只淡入淡出。不对整叠加 `.id()`（`feedback_id_rebuild_minefield`）。
- **撤回上一张**（⧫7）：`MemoryAuditViewState` 记最近一次「留 / 删」（id、动作、之前的 `reviewedAt`）。删的 → `MemoryAudit.restore`（`MemoryAudit.swift:113-115`，恢复不清 `reviewedAt`，本来就没审过 → 回到没看过）；留的 → `reviewedAt` 还原成之前的值（没看过时是 nil）。撤回后它回到最上面并压住。只撤一层；之前拖过的重要度 / 改过的类别不撤（那些当场就生效了）。换状态段 / 改筛选 / 切楼层清掉。
- **空的时候**：
  - 「没看过」本来就过完了（筛选是默认）：照旧「没看过的都过完了 / 新记下的会先到这里」（`MemoryAuditPage.swift:399`）。
  - 有筛选、筛完为零：「这些条件下没有没看过的」+ 一个「清掉筛选」按钮（= 筛选 sheet 里的「全部清掉」，`:708`）。棕黑文字按钮（`Theme.textPrimary`）：压在浅薄荷页面底上，不放薄荷实心按钮（第 6 项改回，粟粟规矩「不要深绿套浅绿」）。
  - 最后一张飞走后：同上两种之一；「↶ 撤回上一张」还在，误删最后一张也能撤。
- 横条「全部删掉」、⋯「把筛出来的 N 条都删掉」照旧，删完堆叠跟着变（top 被删就松开）。

### 2.4 重要度滑条

- 新子视图 `MemoryAuditImportance(memory:onCommit:)`：`Slider(value: $draft, in: 1...5) { editing in … }`，不设 `step`；拖动中右边数字实时显示四舍五入后的整数；松手吸到整数（`withAnimation` 小回弹），和库里不同才调 `onCommit(Int)`。
- 库里是 nil（老档案 / 手加的）：滑块停在 3，数字处写「没定」（⧫5）；拖过并松手（值≠3，或拖离再回到 3）才存。
- 规则函数 `MemoryAudit.setImportance(_:_:now:)`：夹到 1–5，写 `importance`、`updatedAt`，写 `reviewedAt`（⧫2）。已失效的卡滑条禁用（同类别 Menu 现在的做法 `:300`）。
- 列表视图（留下 / 删了 / 选择中）：行里同样是这条滑条（替换 ●●●●○），「选择」中禁用（点行是选中）。滑条在 `List` 行里和行的左右滑不冲突：按在滑块上拖由 `Slider` 吃掉，按在别处划才触发行滑。
- 不改：记忆 app 第一格（`MemoryRow` 对档案不画重要度，`MemoryRow.swift:45`）、常驻页、C2 写入。

### 2.5 改类别

就是现在的类别 `Menu`（点标签弹五选一，`MemoryAuditPage.swift:282-300`，`MemoryAudit.setCategory` 立刻存、算留），挪到卡左上；堆叠里改完卡被压住不飞（2.3）。

### 2.6 批量 / 选择

- iOS：右上「选择」（现成 `MemorySelectButton`）一按 → `editMode` 变 active → 主体切成列表（就是现在那张 `List(selection:)`，批量底栏照旧）；「完成」→ 回堆叠，top 松开、从新的第一张开始。
- 切列表 / 切回都不带布局动画（`.animation(nil, value:)`，同 mac 切格 `MemoryPanelView.swift:422`），免得一叠卡和整张列表互相形变。

### 2.7 mac

- 同一份页面：没看过默认牌堆、同样两颗按钮 + 撤回；筛选行的列表 ↔ 牌堆切换按钮同 iOS，切到列表就是原生多选 + 底部操作条。选择记在 `MemoryAuditViewState.stackStates`（mac 切格重建页面不丢，同 astra #8）。
- 设置窗（mac 设置是另一个窗口）里拿不到聊天 VM，照旧不出「跳到这条」。
- 不加键盘快捷键（1.6）。

### 2.8 碎片池标记换成 `occurredDay`（方案 A）

- `Memory.isFragment` → `occurredDay != nil`，注释写清：只有 C2 写 `occurredDay`（`FragmentPool.swift:341`），`importance` 从此是谁都能改的重要度 / 召回优先级。
- `MemoryAudit.swift:23`、`:31` 的注释跟着改；规格第 5 节「C2 写库时打的标记」= `occurredDay`。
- 现有数据判定结果不变（1.2），备份不变，无迁移。

### 2.9 召回接重要度（⧫6 批了才做）

最小一刀，只动两处排序，常驻规则不碰：

- `Memory` 加计算属性 `recallPriority: Int { importance ?? 3 }`（没定的按 3，⧫5）。
- **recall 工具搜库**（`RecallTool.searchL1`，`RecallTool.swift:384-393`）：给了词时，在关键词 / 向量排好的名次上按重要度加权再取前 4——分 = `1/(61+名次) × (1 + 0.1 × (重要度 − 3))`（1 → ×0.8，3 → ×1，5 → ×1.2）。效果：重要度 5 的条目在相关度第 13 名以内能压过重要度 3 的第 1 名、第 31 名以内能压过重要度 1 的第 1 名；再往后相关度仍占上风。全是 3 / 没定 → 名次一点不变。不给词（按日期翻）照旧按时间。抽成纯函数 `RecallTool.weightByPriority(_:)` 好测。
- **C 档案全量兜底**（`FullFallbackRetriever`，`MemoryService.swift:584-590`）：排序从「新→旧」改成「重要度高→低，同重要度新→旧」——预算装不下时先丢重要度低的。行序只在她改重要度 / 新写入时变（现在新写入本来就会让行序变），不会逐轮漂移，不毁缓存。只影响【开窗口】C 勾着的人。
- **不动**：常驻层（重要度 5 不自动每轮带——C 现在默认不推、钉住已是「每轮都带」）、关键词 / 向量本身的打分、目录模式、记忆格「常驻记忆」页（它读同一套函数，自动跟着变）。
- 和召回侧那一刀的关系：召回侧会把 recall 改成按层往下翻（召回侧规格 §1.1），到时 `searchL1` 会被改写；加权函数是独立的纯函数，挪过去即可。

### 2.10 代码分层

- `Services/MemoryAudit.swift`：加 `setImportance`、`deck(rows:all:state:top:passed:)`、撤回用的 `Undo`（记录 + `undo(_:in:)`），纯函数好测。
- `Models/Memory.swift`：`isFragment` 换标记；（⧫6）`recallPriority`。
- 新文件 `Views/MemoryAuditStack.swift`：堆叠（`MemoryAuditStack`）、卡片内容（`MemoryAuditCardContent`，列表行和堆叠共用）、滑条（`MemoryAuditImportance`）。`MemoryAuditPage.swift` 已 724 行，不往里堆；页面只加「按状态 / 选择挑主体」那几行，`card(_:)` / `infoLine` 换成共用内容视图。
- `MemoryAuditViewState`：加 `topId`、`passed`、`lastAction`（撤回）、`stackStates`（默认 `[.unreviewed]`）；`clear()` 一起清。
- （⧫6）`Services/MemoryService.swift` `FullFallbackRetriever` 一处排序；`Services/RecallTool.swift` 一个纯函数 + 一行调用。

---

## 三、影响范围 / 风险

| 改动 | 会碰到谁 | 风险 / 处理 |
|---|---|---|
| `isFragment` 换 `occurredDay` | 审计台来源筛选、横条、`FragmentPoolTests` / `MemoryAuditTests` 的造数 | 现有数据结果不变；测试造数改成设 `occurredDay`；新测锁「老档案拖了重要度来源不变、不进横条」「C2 每条必写 occurredDay、手加不写」 |
| 任何条目都能有 `importance` | 以后谁再拿 `importance != nil` 当「C2 写的」就错 | `isFragment` 注释写清；grep 现在没有别处这么用（1.2） |
| 堆叠压住当前这张 | 别处同时删了它 / 切楼层 | `deck` 只压活着的；`profileWillSwitch` 已有 `auditState.clear()`（`MemoryPanelView.swift:324`），新字段一起清 |
| 后台 C2 写入新碎片 | 堆叠顺序 | 新的排在当前这张后面（压住），不会把她正看的顶掉 |
| 飞走动画 + 存盘失败 | 红字 + 卡飞回 | 动画先于存盘由本地状态驱动；失败把「刚飞走」撤掉 |
| 列表行加滑条 | 行变高一截；滑条 vs 行左右滑 / 选择 | 选择中禁用；手势由 `Slider` 自己吃；390 宽截图核 |
| 滑条松手才存 | 每次松手一次存盘 + 通知 → 记忆 app 后台重算常驻摘要 | 拖动中不存；值没变不存 |
| 撤回 | 「留」的撤回要还原之前的 `reviewedAt` | 记录里存原值；只一层；换段 / 筛选 / 楼层清 |
| （⧫6）兜底按重要度排 | C 勾着的人 prompt 里档案行序 | 全是 3 / 没定时行序不变 → 金样（夹具两条档案都没重要度，`PromptRealPathHarness.swift:216-221`）原样过；`CachePrefixStabilityTests` / `MemoryFullPresenceTests` / `CatalogInjectionTests` 照跑 |
| （⧫6）recall 加权 | recall 工具给模型的前 4 条 | 全没定时名次不变；新纯函数单测 |
| mac「选择」按钮 | 筛选行尾多一个字 | mac 面板窄时摘要 `lineLimit(1)` 截尾，按钮不挤掉 |
| 不碰 | C2 写入、常驻规则、备份格式、记忆 app 第一格、设置搜索注册表（入口没变） | — |

---

## 四、验收

**单测（交之前全过，grep 到对应 Test Suite passed；工位只跑 test / build-for-testing，不普通 build、不开模拟器）**
- `MemoryAuditTests`：
  - `isFragment` = `occurredDay != nil`；老原子档案设了 `importance` 仍是 `.legacyAtomic`、不进 `v5BannerTargets`；C2 碎片清掉 importance 仍是 `.fragmentPool`。
  - `setImportance`：夹 1–5、写 `importance` / `updatedAt` / `reviewedAt`；已失效的不动（或按 ⧫2 结果改断言）。
  - `deck`：top 活着时永远第一（即使不匹配筛选 / 已审过）；top 失效 / 不存在时按 rows；新写入不顶掉 top。
  - 撤回：删 → 恢复且回到没看过；留 → `reviewedAt` 还原为 nil；留下状态的卡撤回还原成原来的日期。
  - 造数 helper 改成设 `occurredDay`（`MemoryAuditTests.swift:18-23`、`:214`）。
- `FragmentPoolTests`：「来源靠 isFragment」那条（`:221-241`）改成断言每条 C2 都带 `occurredDay`，手加的没有。
- （⧫6）`RecallTool.weightByPriority`：全 3 名次不变；5 / 1 交换的边界例子；`FullFallbackRetriever`：重要度高的先、同重要度新的先、全没定 = 旧顺序。
- 金样 `PromptRealPathGoldenTests` **一字不变**（夹具档案没有重要度）；`CachePrefixStabilityTests`、`MemoryFullPresenceTests`、`CatalogInjectionTests`、`RecallVisibilityTests` 照过。
- mac + iOS（`MemoryPalaceIOS`，iOS 26 模拟器目的地）build-for-testing 认 `TEST BUILD SUCCEEDED` 字样。

**UI（截图自查）**
本工位不允许开模拟器 / 装包。截图自查**交 Warden**：提交时 `--why` 写「要验 UI」，Warden 合完用集成区产物装 sim（390 宽 iPhone）截图，再叫粟粟验。要看的：
1. 审计台格「没看过」是一叠卡：后面两张露边；卡里类别 ▾ / 正文 / 日期 · 窗口 / 滑条 / 删 · 留；点「留」往右飞、「删」往左飞，下一张翻上来；左右划卡片没有任何反应，划到边上照常翻页。
2. 拖滑条：数字跟着变，松手吸到整数；老档案显示「没定」；拖完卡不飞，再按留 / 删才飞；「来源 = 改版前的原子档案」筛着拖一条，卡还在、来源不变。
3. 点类别改成别的：卡不飞；「类别」筛着时也不飞。
4. 「↶ 撤回上一张」：删的回来、留的回来；最后一张飞走后还能撤。
5. 筛完为零：「这些条件下没有没看过的」+「清掉筛选」；真过完：「没看过的都过完了」。
6. 右上「选择」→ 列表多选留 / 删 →「完成」回牌堆；「留下」「删了」默认是列表、行里是滑条；筛选行切换按钮把「留下」切成牌堆，按「留」只过到下一张、库里不变，过完一遍是空状态；「删了」牌堆里「恢复」往右飞、「彻底删」先确认再往左飞；切格再回来选择还在，切楼层回默认。
7. 390 宽：横条、三段、筛选行、卡片、两颗按钮、撤回行都不溢出；颜色没有蓝黄、没有薄荷压浅薄荷。
8. mac 记忆面板 + mac 设置窗各走一遍：牌堆、筛选行切换按钮切到列表后原生多选、设置窗里没有「跳到这条」。
9. （⧫6）检查器：C 勾着、全量模式，把一条档案拖成 5、一条拖成 1，下一轮档案段里 5 的排前面；让小克 recall 一个词，重要度高的排得靠前。

---

## 五、⧫ 拍板记录

1. 已定（10-17）：「没看过」默认牌堆；「留下」「删了」默认列表（行里一样有滑条）。**加**：筛选栏旁一个按钮，三段都能切列表 ↔ 牌堆（第 2.1 节）。原话：「默认只给没看过，但是也可以选牌堆。」
2. 已定（10-17）：拖重要度也算「留」（同改类别）；牌堆里拖完 / 改完类别卡不自己飞走，按「留」或「删」才走。
3. 已定（10-17）：滑条拖起来连续，松手吸到最近的整数 1–5 存。
4. 已定（10-17）：老原子档案拖了重要度，「来源」仍算「改版前的原子档案」；认碎片池改看 C2 必写的 `occurredDay`，零迁移。
5. 已定（10-17）：没有重要度的老条目滑条停在 3、旁边写「没定」，拖了才存；召回时没定的按 3 算。
6. 已定（10-17）：接最小一刀——recall 工具搜库按重要度加权、C 档案勾着时全量兜底按重要度排（装不下先丢低的）；常驻规则不动，C 默认不推照旧。
7. 已定（10-17）：给「↶ 撤回上一张」，只撤最近一张，拖过的重要度 / 改过的类别不撤。

（技术取舍狗自己定的：认碎片池换 `occurredDay` 不加来源字段、松手存不节流、「留」往右飞「删」往左飞、只画最上面三张、mac 不加键盘快捷键、新视图单开文件。原定「mac 筛选行加『选择』」被列表 ↔ 牌堆切换按钮取代：mac 切到列表就是原生多选。）

---

## 六、todo（每项一个原子提交；实现时勾 ✅）

- [x] 1. ✅ `Memory.isFragment` 换成 `occurredDay != nil` + `MemoryAudit` 注释；`MemoryAuditTests` / `FragmentPoolTests` 造数与断言改；新测：老档案拖重要度来源不变、不进横条
- [x] 2. ✅ `MemoryAudit.setImportance`（写 `importance` / `updatedAt` / `reviewedAt`，⧫2）+ 单测
- [x] 3. ✅ `MemoryAudit.deck(rows:all:state:top:passed:)` + `MemoryAuditViewState` 加 `topId` / `passed` / `stackStates`（`clear()` 同清）+ 单测
- [x] 4. ✅ 抽 `MemoryAuditCardContent` + `MemoryAuditImportance` 滑条（本地拖、松手吸整数、没变不存、没定显示）到 `Views/MemoryAuditStack.swift`；列表行改用它（●●●●○ 去掉，选择中禁用）；mac / iOS build-for-testing
- [x] 5. ✅ `MemoryAuditStack`：前三张、卡内两颗按钮（三段各自的语义，2.1 表）、飞走动画（本地状态驱动、失败飞回、减弱动态效果）、压住当前这张、空状态 +「清掉筛选」；页面按 `stackStates` 和「选择」挑牌堆 / 列表
- [x] 6. ✅ 筛选行列表 ↔ 牌堆切换按钮（⧫1 加的，iOS 选择中藏；mac 同一个）
- [x] 7. ✅ 撤回上一张（⧫7）：`MemoryAudit.Undo` + 单测 + 牌堆下方按钮
- [x] 8. ✅ （⧫6）`Memory.recallPriority` + `FullFallbackRetriever` 排序 + `RecallTool.weightByPriority` + 单测；跑金样（一字不变）、缓存前缀 / 全量在场 / 目录 / 召回可见性测试
- [x] 9. ✅ 说明书 facts 同步（`manual/facts/modules/memory-settings.md` 审计台段；跑 `scripts/manual/check.mjs`）
- [x] 10. ✅ 定向测试全量过一遍（grep 到各 Test Suite passed）+ mac / iOS build-for-testing `TEST BUILD SUCCEEDED`
- [x] 11. ✅ 复盘 `docs/review-memory-audit-cards.md`（边界 / 和召回侧、C3 的交互风险 / 技术债 / 要验 UI 清单）+ `docs/now/backend-2.md`
- [ ] 12. 交合并，`--why` 写「要验 UI」——截图自查由 Warden 装 sim 后做（本工位不开模拟器），第四节 UI 清单给粟粟 / Warden
