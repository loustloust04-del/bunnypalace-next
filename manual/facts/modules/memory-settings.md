---
name: memory-settings
title: 记忆设置（v5）
area: modules
tier: free
platforms: [macos, ios]
entry:
  macos: 设置 › 记忆
  ios_pro: 设置 › 记忆；页 2 记忆 app › 每格左上角「设置」（弹 sheet）
  ios_lite: 设置 › 记忆（简化页）
covers:
  - MemoryPalace/Views/MemoryPageContent.swift
  - MemoryPalace/Views/MemoryWriterPages.swift
  - MemoryPalace/Views/MemorySettingsPage.swift
  - MemoryPalace/Services/MemoryWriterSettings.swift
  - MemoryPalace/Models/WriteBudgetStore.swift
  - MemoryPalace/Services/MemoryWriteLog.swift
  - MemoryPalace/Services/PendingStore.swift
  - MemoryPalace/Services/PendingNotesTool.swift
  - MemoryPalace/Services/FragmentPool.swift
  - MemoryPalace/Models/Memory.swift
  - MemoryPalace/Services/GlobalBackup/Schemas/FullDocuments.swift
  - MemoryPalace/Services/GlobalBackup/Schemas/FullDocumentMapping.swift
  - MemoryPalace/Services/GlobalBackup/SchemaCoverageCheck.swift
  - MemoryPalace/Views/PromptEditorPage.swift
  - MemoryPalace/Services/WindowSummaryWriter.swift
  - MemoryPalace/Views/WindowSummarySheet.swift
  - MemoryPalace/Views/MemorySessionsView.swift
  - MemoryPalace/Services/MemoryAudit.swift
  - MemoryPalace/Views/MemoryAuditPage.swift
  - MemoryPalace/Views/MemoryAuditHome.swift
  - MemoryPalace/Views/AuditStation.swift
  - MemoryPalace/Views/MemoryWikiPage.swift
  - MemoryPalace/Views/WikiProposalItemPage.swift
  - MemoryPalace/Services/Wiki/WikiProposalSources.swift
  - MemoryPalace/Services/MemoryResident.swift
  - MemoryPalace/Views/MemoryResidentPage.swift
  - MemoryPalace/Services/Wiki/CatalogRunner.swift
  - MemoryPalace/Services/Wiki/WikiInjection.swift
  - MemoryPalace/Services/Wiki/WikiProposal.swift
  - MemoryPalace/Services/Wiki/WikiProposalDisplay.swift
  - MemoryPalace/Views/WikiProposalViews.swift
  - MemoryPalace/Views/WikiViews.swift
  - MemoryPalace/Services/PromptFolder.swift
  - MemoryPalace/Views/FileLibrary/FileLibraryPromptFolder.swift
mentions:
  - MemoryPalace/Services/Wiki/CatalogSorter.swift
  - MemoryPalace/Services/Wiki/CatalogAgent.swift
  - MemoryPalace/Services/Wiki/CatalogRetrieval.swift
  - MemoryPalace/Services/Wiki/CatalogALineReader.swift
  - MemoryPalace/Services/Wiki/CatalogSearchReceipt.swift
  - MemoryPalace/Services/MemoryService.swift
  - MemoryPalace/Services/Search/SearchIndexStore.swift
  - MemoryPalace/Services/Search/SearchTextSegmenter.swift
  - MemoryPalace/Services/SearchService.swift
  - MemoryPalace/Services/Search/CatalogOriginalText.swift
  - MemoryPalace/Views/MemoryAuditStack.swift
  - MemoryPalace/Views/FileLibraryPanelView.swift
  - MemoryPalace/Views/FileLibrary/FileLibraryMemoryFolder.swift
  - MemoryPalace/Views/MemoryTreeBrowserSheet.swift
  - MemoryPalace/Services/FileLibraryTools.swift
  - MemoryPalace/MemoryPalaceApp.swift
  - MemoryPalace/Services/SessionCloseout.swift
  - MemoryPalace/Services/SessionSegmentWriter.swift
  - MemoryPalace/Services/TimelineWriter.swift
  - MemoryPalace/Services/TimelineStore.swift
  - MemoryPalace/ViewModels/ConversationViewModel.swift
  - MemoryPalace/Views/ContentView.swift
  - MemoryPalace/Views/MemoryPanelView.swift
  - MemoryPalace/Views/MemoryTimelineView.swift
  - MemoryPalace/Views/APISettingsTab.swift
  - MemoryPalace/Views/Settings/SettingsSearch.swift
  - MemoryPalace/Services/MemoryMigration.swift
  - MemoryPalace/Services/MemoryRegeneration.swift
  - MemoryPalace/Views/MemoryRegenerationSection.swift
---

## 使用与当前行为

- 页面从上到下：状态卡 → 顶上五行（记忆系统总开关、记忆从哪天开始、提取模型、写入预算、复杂度）→「写入 · 记什么」→「整理 · 怎么管」→「注入 · 塞什么进 prompt」→「检索 · 怎么挑记忆」。顺序固定在 `MemoryPageLayout.sections`（`MemoryPageContent.swift:7-50`），app 里不能拖动。
- 记忆 app 里没有「设置」格了：每一格左上角一个齿轮，点开弹 sheet「记忆设置」（运行状态 + 这一整页，右上「完成」）；首屏红色提醒「…，去看看 ›」也是打开这个 sheet `MemoryPanelView.swift:510-530`（settingsButton / settingsSheet）。
- 状态卡几行平铺：记新东西（C2）/ 写上下文摘要（A2）/ 写窗口总结（A3）/ 写时间轴（A4）。关着的项灰字「关着，没在写」不变红；总开关关着整卡一行「总开关关着 · 都暂停了」；写入预算用完灰字「写入预算用完，下周一再写」。右上 ⓘ 打开记忆日志，点某一行跳到日志里这一项最近一条 `MemorySettingsPage.swift:8-130`。
- 提取模型：右边只有小箭头，模型名写在副标题里；各项没单独选模型时都用它 `MemoryPageContent.swift`（extractModelRow）。
- 写入预算：主页一行显示「$已花 / $上限 · 每周」，点进去是和全局预算同一套控件（直接输美元数、已用、进度条、重置已用、保存），顶上多一个「关闭 / 周 / 日」。关闭 = 不限（默认）。只算后台写手 A2 A3 A4 C2 C3（「花在哪」五行）`MemoryWriterPages.swift:750`、`:760`、`WriteBudgetStore.swift:30`；超了后台写手跳过、不算失败；对话 ⋯「现在写」不看它 `WriteBudgetStore.swift` `MemoryWriterPages.swift`（WriteBudgetPage）`SessionSegmentWriter.swift`（modelCaller）。
- 复杂度滑条 0 / 轻 / 中 / 重：不存值，位置由写入开关算；拖一档改一组写入开关（0 = A2；轻 = A2 A4；中 = A2 A3 A4 B4 C2，新装默认；重 = 再加 B1）；手动改过显示「自定义」`MemoryWriterSettings.swift`（MemoryComplexity）。C3 不归滑条管：拖滑条不动它，「开 N 项」也不数它 `MemoryWriterSettings.swift:75`、`:124-129`。
- 写入 · 记什么：A2 上下文摘要 / A3 窗口总结 / A4 时间轴 / B1 心声 / B2 日记（还没做）/ B3 做梦（还没做）/ B4 {助手}的记忆 / C 档案 / C2 碎片池 / C3 整理编目（一句话「碎片和聊天整理成 wiki 页，先过目再写」`MemoryWriterSettings.swift:45`）。一行 = 编号名字 + 一句话 · 模型 + 开关，整行点进二级页；总开关关着整组变灰。
- 二级页同一个模板：开关 → 状态（红时原因 / 连续几次 / 模型，点了看日志）→ 模型（跟提取模型 / 单选；C2 / C3 默认跟提取模型，也能选本机聪明款 4B / 轻巧款 1.7B `MemoryWriterPages.swift:409-411`，选了本机有「下载本机模型」那一行；选了本机但没下 / app 在后台，这一轮用提取模型，没下第一次弹一次提示）→ 各自的行 → 本期花费。
  - A2：什么时候写（每 N 回合，默认 5 = Prompt 页那个数 / 停 N 分钟 / 只手动）；CC 窗口满 60 条或跨过 05:00 写；尾段说明。
  - A3 / A4：什么时候写（停 N 分钟，默认 12 小时 / 每 N 回合 / 只手动）、新开对话时先写掉 12 小时内聊过的；A3 另有「约多少字」（默认 300）。
  - B1：心声进聊天流；花费写「不算写入预算」。B4：N 条（看、改）、每日上限、每条正文上限、「图数据库 · 联想召回 · 还没做」。C：N 条（看、搜）。C2：每满几条写一次（默认 20 条，6–40，步长 2，「两边加起来」）、提取提示词（自定义的显示「自定义」，不被新默认覆盖）、本周拒收 N 次 `MemoryWriterPages.swift:341`。
  - C3：开关默认开（同 C2），总开关关着也算关 `MemoryWriterSettings.swift:85`、`:91-99`、`:107-110`。状态行：在整理「正在整理：{主题}（第 N 轮）」，后面还排着加「 · 后面排着 N 次」；关着「关着，没在整理」；写入预算用完写暂停原因；没跑过「还没整理过」；否则「{多久前} · {最近一条日志}」；点了打开记忆日志 `MemoryWriterPages.swift:170-216`。「怎么整理」一节：每天自动整理（默认开，「每天过了 05:00 第一次打开时整理一次」）/ 自动一次最多几个主题（默认 8，1–30，「N 个（剩下的下次）」）/ 手动整理最多几轮（默认 10，3–20，「每个主题 N 轮」）/ 不触发的词（「N 个」）`MemoryWriterPages.swift:499-515`、`CatalogRunner.swift:6-27`。开关、模型和这三行设置进配置导出，「哪天跑过」不进 `ConfigSchema.swift:125-130`。
  - 不触发的词页：顶上「加一个词」+「加」，一行一个词，左滑 / 右键「删掉」，空时「没有」，脚注「聊天里出现这些词，不会带出 wiki 页」；存楼层 wiki 里的 `不触发的词.txt`，后台读写；C 注入会把这些词从页标题 / 触发词里排除 `MemoryWriterPages.swift:218-288`、`WikiInjection.swift:40`、`:52-65`。
- 整理 · 怎么管：整理台（第一行，副标题「没看过 N 条」，直接推入整理台卡片页；10-23 前叫「审计台」，设置搜「审计台」也能搜到）、待续（没做完 / 淡了 / 做完了，左滑改状态、点一条改字；记忆 app 时间轴格顶上同一份）、已删除。老「整理记忆…」（两两合并意思相近的）整个删掉了，由整理台取代 `MemoryPageContent.swift:46`、`:406-413`（auditRow）。
- 已删除弹层：同一分钟内一起失效 ≥3 条的成批一组，标题「{日期}一起删掉的 · N」（做梦毕业 / 审计台批量删都会成批）`MemoryTrashSheet.swift:45`。
- 注入 · 塞什么进 prompt：开窗口带什么（A2 带全文几段 / A4 几条几天 + 待续只带没做完 / B4 带全文几条、最多占预算 / C 按检索挑 + wiki 根索引 / 触发词命中页；目录还没做），每一轮对所有窗口生效；目录式注入、想起来了、召回反馈、注入预算照旧。
  - 【开窗口】C 档案默认**不勾**（10-16 起，等 C3 整理好再开）：没动过这一勾的（含新装）档案整段不带，钉住的也不带；动过的（点过勾 / 设置导入带来的）照旧。不勾时 C 那行下面一行小字「档案先不带，等 C3 整理好再开；聊天中靠「检索」按需想起」。召回工具不看这一勾 `MemoryWriterSettings.swift:173-174`、`MemoryWriterPages.swift:692-699`。
  - 【开窗口】C 勾着时，稳定层在 B4 后带「[C 档案 · 索引]」= 根 INDEX 的条目行（保留 `[[路径]]`）；动态层带「[C 档案 · 本轮相关]」= 命中页的标题 / 钩子 / 现在，不带记录 `WikiInjection.swift:28-29`、`:43-48`、`:105-118`，`PromptAssembler.swift:703-719`。
  - 带碎片时只挑碎片池里点过「留下」的；钉住的每轮常驻，有有效期的在稳定层写「（有效到 YYYY-MM-DD）」。已整理进本轮命中页的碎片不再单独带（钉住的照带）`MemoryService.swift:673-690`、`:726-745`，`WikiInjection.swift:143-148`。
  - 过期只标注，不删、不降权：动态层碎片行尾加「（已过期）」；过期的钉住项另列「[已过期的钉住项]」；页「现在」里的「（到 YYYY-MM-DD）」过了那天写成「（到 YYYY-MM-DD，已过期）」`MemoryService.swift:730-745`、`:764-773`，`WikiInjection.swift:121-140`。
  - 触发词扫最近 4 条真实消息（含本轮刚发的），逐字匹配页标题 / 触发词，英文不分大小写，一轮最多 3 页；用户名、助手名和「不触发的词」不触发；助手消息只扫正文，思考段不扫 `WikiInjection.swift:26-27`、`:52-84`，`PromptAssembler.swift:722-727`，`MemoryResident.swift:71-80`、`:89-123`，`ConversationViewModel.swift:2879-2882`。
  - 注入快照按楼层缓存；wiki 页 / 索引 / 不触发的词变了就作废，后台重建。发送前只在记忆总开关、对话记忆、C 勾三样都开着时等预热，最多 5 秒；超时红字报错「等待 wiki 注入缓存超时，请稍后重试。」，不拿旧快照发 `WikiInjection.swift:157-175`、`:202-240`、`:301-328`，`WikiStore.swift:392-403`，`ConversationViewModel.swift:2493-2496`、`:3207-3226`、`:3270-3275`。
- 检索整节不动。重要度 = 召回优先级（10-17）：【开窗口】C 勾着时，全量兜底先按重要度高→低（没定的按 3，库里越界的先夹到 1–5，备份导入时也夹）、同重要度新→旧，注入预算装不下先丢重要度低的；{助手}用 recall 工具给词搜档案时，在关键词 / 向量排好的名次上按重要度轻加权（全没定时名次不变）；常驻规则不变（重要度 5 不会自动每轮带）`MemoryService.swift:581-593`（FullFallbackRetriever）`RecallTool.swift:420-428`（weightByPriority）`Memory.swift:67-71`（recallPriority / effectiveImportance）。
- 对话 ⋯ 里「现在写」：这个窗口开着的 A2 / A3 / A4 立刻写一遍，不等静默、不看冷却、不看写入预算，写完提示「写好了：A2 1 段 · A4 1 条」；总开关关着时灰掉 `MemoryWriterPages.swift`（WriteMemoryNowButton）`ConversationViewModel.swift`（writeMemoryNow）。
- C2 填严格 JSON，不带主聊天提示词；选定批次保留双方消息，每消息最多 600 字，本机仍按实际 system 和 6000 字总预算丢最早整条，编号不重编。JSON 或卡片校验失败都反馈具体原因，只重写一次；dataCorrupted 带解析器上下文，下标可用时补 Character 位置和前后各最多 10 Character 原文，并提示字符串内双引号转义或改用「」，不自动修补或放宽解码。最终整包才落库，好卡精确去重只加一次。第二轮全拒不 write、不记成功，沿既有 failStreak / 健康警告计失败；首轮具体原因及数量保留在唯一最终写手日志，预算 / 开关 / 瞬态跳过只留诊断、不改健康 `FragmentPool.swift:371-391,476-499,567-621`。
- C2 新默认提示词：按长期有用→属性/状态/偏好/关系变化→定下的结论/决定→AI 对本人的承诺依次判断；正文为 1–3 句、脱离原文可读，≤200 个 Swift Character（200 收、201 拒，不裁剪）。默认要求 content/subject/tags 内引用词语用「」，不要用英文双引号；代码仍接受合法 JSON 转义的引号。默认代码只接受用户自述和 AI 承诺，AI 观察触发唯一重写；例子全为虚构、名字走变量。保留真实感受/边界与架空动作的区分、相对日期换算及写后自检 `FragmentPool.swift:253-288,432-455`。
- C2 输出共同必填 `msg/content/tags/importance/emotion/category`，resolved 可选、tags≤5、importance 1–5、emotion 为整数 -2…2。非法 category 拒收；去 Unicode 空白、标点和 symbols 后与 msg 原文完全相同的 content 拒收，含符号 emoji 按完整 Character 簇忽略，不做近似照抄或语义去重。新默认 subject/speaker 必填；提供的 subject≤40 Character，超长拒收不裁剪。旧自定义缺归因键允许 nil，提供时不得空、null、错误类型或非法 speaker；自定义保留三个 speaker。存储值去首尾空白后逐字等于 e62b23fa4 那一份旧默认全文时，视为默认并走新版合同；改一字仍保留自定义，其余自定义主动恢复默认才切换，不写回存储、不建版本系统 `FragmentPool.swift:219-251,295-300,430-455`。
- Memory 的 subject/speaker 是可选持久字段，旧库及旧备份保持 nil/未知，不重提取、不扩写、不猜归因；全量备份/恢复和覆盖检查已贯通。C3 分拣、自动备料、agent 开场及两类搜索回执把归因放在同一条目行、正文之前，旧 nil 明示未知。元数据不进正文区间、不占 6000 字正文预算，截断后保留归因；原 keywords/f 编号及 P1 实际可见出处口径不变 `Memory.swift:31-33`、`FullDocuments.swift:251-253`、`FullDocumentMapping.swift:400-402,436-437`、`CatalogSorter.swift:555-557`、`CatalogWriter.swift:542-544`、`CatalogAgent.swift:349-351`、`CatalogRetrieval.swift:108-110`。
- C2 有效期仍可选：只有明确日子才填 valid_until（YYYY-MM-DD）；相对日期按来源消息自己的记忆日换算，缺日期按该批最后一天，05:00 日界不变。坏日子只丢字段、不拒整条；写库为该日次日 05:00，过期不删、不降权 `FragmentPool.swift:275,458-470,520`。
- C2 什么时候写：API 窗口和 CC 窗口同一套——每满 N 条新消息（`mem_c2_every`，默认 20，两边加起来）从上次写到的地方往后取一批 N 条，积压多了分批、每轮回复后追一批；水位存盘（最多记 300 个窗口，超了扔最久没动的），重开 app 不丢；第一次见到的窗口只记位置不回头补；成功 / 合法空包 / 两次格式不对才挪水位，断网、超时、写库失败留着下次再来。API 窗口送进去的消息和 A2 同口径（工具调用写成「[调用了 …]」）。以前的「每 3 轮 + 最近 7 条 + 首轮必跑」和 CC 的「每 6 条」都没了 `FragmentPool.swift:632-742`（FragmentWatch）`ConversationViewModel.swift`（extractMemoriesIfNeeded）`SessionCloseout.swift`（requestFragmentsCC）。
- C3 什么时候跑、怎么跑（产出全是提案，批了才写进 wiki；wiki 在楼层 `memory/wiki/`，一个点一页，索引代码生成）：
  - 每天自动：过了 05:00（记忆日分界），app 启动 / 回前台时看当前楼层今天管过没有；mac 一直开着，跨过 05:00 到点再看一次；iOS 没有后台定时，app 不打开不跑。一个楼层一天只看一次：C3 关 / 「每天自动整理」关 / 写入预算用完 → 今天不跑，记忆日志记一行原因 `CatalogRunner.swift:47-70`、`:393-427`、`MemoryPalaceApp.swift:1396-1397`、`:1458`。
  - 自动那次（两批，C2/C3 v2 第 4 段）：先清掉处理完满 30 天的提案和 30 天前的模型原始输出；**第一批只提方向，全由代码做、不调模型、不搜不写**——原料 = 碎片池 10-01 起、审计台已留、没删、没进页、没驳回、不在待批提案 / 待批方向线索里（「单条就够」的也在，但只跟着新碎片回来），至少要有一条没整理过的，否则日志「没有待整理的碎片」。每条碎片的标题 = 主体 + 关键词（旧碎片只有关键词；名字和「不触发的词」不算；都没有叫「未命名碎片 + 短编号」），不读正文。标题里逐字出现某页的标题 / 触发词 → 提「更新已有页」（碰上不止一页 = 拿不准，留着）；没碰上的按第一个标题词归，够 3 条才提「开新页」，路径先放「楼层/主题/<词>」，她可以改。同一页还有待批方向不重复提；处理过（批了 / 驳回）的页没有新碎片不再提。按线索多→少最多 N 个方向，剩下的写「还有 N 个方向下次再提」；某一层超过 30 行顺手提一次「分组调整」（这一步仍调模型，那层已有待批的不再提）；汇成一份「定时整理」提案 `CatalogRunner.swift:201-273`、`CatalogSorter.swift:80-112,427-517`。**第二批**：批了方向才执行（同一楼层锁、预算、停、`.runs` 照旧）：只给还在池里的线索，三路搜原料、读楼层 prompt / 相关索引 / 已有页全文和版本，日常方向一次写手，写完交一份关联原方向的正文提案，正文还要再批才落页 `CatalogRunner.swift:277-401`、`WikiProposal.swift:397-433`。
  - 手动（审计台 › wiki ›「整理提案」）：她点「现在整理」/「整理一个主题…」这一下就是方向授权，不再出待批方向让她重复批；提案上记她说的话和楼层。「现在整理」= 代码按碎片标题列主题（同自动的归组，不调分拣模型），再每个主题一个 agent，不设主题上限，每个主题一份「现在整理」正文提案；「整理一个主题…」= 一个 agent，不受 3 条门槛，来源「整理主题」。正文一律等她批了才落页。agent 的工具全只读（广搜聊天原文 / A4 / A3 / A2 / 已留碎片、往下翻某个窗口、定向追搜碎片、看 wiki 索引 / 读页），交提案是唯一出口；每轮发请求前过写入预算 + 全局闸，每轮写一行记忆日志；到了 N 轮或工具回执累计 40000 字，再给一次只能交的机会，这时交上来的标「没整理完」，还不交就不出提案 `CatalogRunner.swift:547-656`、`CatalogAgent.swift`（definitions/run）。
  - 写手 / agent 看的楼层提示是完整底图（Prompt 里人填的全部文字，含自建槽，不截断）。方向里定好（或她改过）的钩子作为写手 / agent 的明确输入，正文里新开页用它，已有页钩子不同就补一条改钩子等批 `CatalogWriter.swift:425-447,587-589`。
  - 写手 / agent 的结果（两种跑法一样）：有条目 → 一份正文提案（第二批）；分到的碎片里「页上已经写过」的，挂在这页第一条上，这页一条都没写就单出一条「确认已覆盖」（不改页，批了才标已整理进这页）；「单条就够」（写手 / agent 交 `single`；日常写手只认分到这个主题的线索，agent 认这次实际给过它的、没进页没驳回的碎片）；手动入口 covered 挂在 agent 实际读过的页上（可在交提案时点名 `covered_page`）直接打标、不进提案、照样能被找到，以后有同主题新碎片会被带回来重新归组；什么都没有不造假提案、不打标，方向上记「没有可写的材料：原因」；被拦 / 停 / 出错也只记在方向上，已交的照留，不自动续跑、不重试 `CatalogRunner.swift:371-401`、`CatalogWriter.swift:390-415`、`CatalogAgent.swift:686-688`。
  - {助手}提方向：工具 `suggest_wiki_direction`（总开关 + C3 开着才有，工具抽屉记忆组「{助手} 给记忆 wiki 提整理方向」默认直接给，可在抽屉里收起 / 关掉）。只交一条待批方向（路径、标题、为什么），来源「{助手}」；同一页有待批方向不重复交；这场对话关了记忆参与就拒。批了以后 agent 去查、写（最多 N 轮），正文再批 `WikiSuggestTool.swift`、`ToolRegistry.swift:51,157-167`、`ToolDrawerCatalog.swift:77`、`ConversationViewModel.swift:4696-4705`。
  - C3 检索：日常自动写手和手动工具共用薄适配，安全取得值快照后并行召回聊天原文、A 线及已留碎片。原文复用现有 FTS5 候选：连续汉字段保留整段相邻字短语，不同段 / 非汉字词仍 OR；按 `bm25(fts)` 在 profile、删除、role、date、scope 过滤后最多取 300 条。未就绪 / 不可索引 / 错误时复用搜索服务扫描，每个完整汉字段只查一次。两路均在既有窗口批次读取当前节点，按 `segmentsData` 只取 text，再按同组完整 terms 复核可见正文，不信旧索引的扁平正文；保留当前角色 / 时间 / 主支线，排除跨楼层、窗口 / 节点回收站等。未重建 / 重导数据，搜索框原 `hits` 按时间合同和原有正文结果不变 `SearchTextSegmenter.swift:44-81`、`SearchIndexStore.swift:335-379`、`SearchService.swift:176-300`、`CatalogOriginalText.swift:5-50`。
  - 原文格式边界：Claude / ChatGPT / RikkaHub / Kelivo 当前结构化导入可排除 thinking、toolUse / toolResult、附件提取和音频 script；原生思考 / 工具 / 旁路字段不作正文。坏 / 空 / 未知结构或明示结构化却缺结构，不退回扁平 content。无结构时只剥明确 `<<<THINK>>>`、`[thinking]` 和开头 `<think>` 边界；原生助手只后挂 audioRef 的 text 消息保留 content 正文。**无结构、无可靠标记或内部类型的裸工具结果仍无法与正文区分**，sourceMetadata 不能恢复丢失边界，不按 provider 名删除正文或用宽泛正则猜 `CatalogOriginalText.swift:5-50`、`CatalogImportedOriginalTests.swift:22-187`。
  - A 线复用 Recall 分词 / BM25 与只读 reader，旧格式及第 0 段仍可读。碎片仍是 10-01 起已留未删值快照，手动可回读已整理 / 整理驳回并标状态；BM25 + 向量按 UUID 融合，f 号不重编。缺失 / 旧 revision 向量只补合格候选，写回前重新核对正文、楼层与资格；不可用 / 部分失败不冒充零命中。各引擎分数只管召回；合并按出处去重，对同一候选集重算共享 BM25，再乘原文 1.2 / A 线 1.1 / 碎片 1.0，稳定全局排序，最多 10 条、搜索正文合计最多 6000 字，写手再跳过不相关材料。不按来源分桶，不预先丢掉词面分为零的向量独有候选。直接分配碎片、楼层 prompt、已有页不是搜索回执；种子全文不套本段预算 `CatalogRetrieval.swift`（Candidate/Result/search）、`MemoryService.swift`（MemoryBM25/MemoryRetrieval/MemoryEmbeddingBackfill）、`CatalogSorter.swift:105-129`。
  - 共享 BM25（10-22 返工）：入口先 NFKC / 小写，连续汉字切相邻双字，不生成单字、不跨空格/标点；其他文字仍用 NLTokenizer.word、至少 2 字。正文、查询、keywords 同口径，keywords 仍加入两份并计文档长度。查询按连续汉字段分组：3–6 字须含齐全部双字，否则该组不加分；≥7 字且当前候选 n≥20 时丢掉 df/n>0.5 的查询双字，n<20 不丢，等于 0.5 保留，不用停用词表；不同段 / 英文词仍 OR。「云桥城」命中自身长句，但不会仅因「桥城」或「云」而词面命中；单汉字 BM25 仍不支持，原文路可搜单字。碎片、A 线、Recall L1、KeywordRetriever 共用函数，主聊天词面命中与名次会变；向量独有候选、来源权重、10 条 / 6000 字及搜索框 FTS 格式 / 时间排序不改，无分词缓存 `MemoryService.swift:503-590,620-663,669-688`、`RecallTool.swift:446-462`。
  - C3 `.runs` 统计：拼接时记录正文 Character 区间，原文、A 线、搜回碎片与直接分配碎片分账。标题、日期、章节 / 待续标签、工具说明及省略号不算正文。按实际搜索预算及累计工具预算截断后的可见区间登记出处，尾部不能冒充已提供；旧 `.runs` 无原文字段仍能读、不回填 `CatalogSearchReceipt.swift:3-131`、`CatalogALineReader.swift:301,342`、`CatalogWriter.swift:465-475,560`、`CatalogAgent.swift:658-661`。
  - 手动 agent 交提案：确实没有值得写的才交空，并用 `reason` 说明；查过材料后空交没写 `reason`、条目全被扔，各回灌一次让它修正重交，输出被截断也回灌让它少写几条；最后一轮不再因空交 / 全被扔 / 截断驳回 `CatalogAgent.swift:72-77`、`:433-483`、`:509-525`。
  - `submit_proposal` 每次都记草稿到 `wiki/.proposals/drafts/`，正文最多 8000 字、原因列表最多 4000 字；每次运行最多 12 份，到顶后记忆日志写「草稿已达 12 份上限」，没到顶写草稿文件名 `CatalogAgent.swift:433-443`、`:482-483`、`:507`，`CatalogSorter.swift:174-198`、`:216-255`。
  - 种子（C2/C3 v2 第 6 段）：C3 二级页「种子」一节两个入口「从人设生成基础 wiki」「从 CC 记忆播种」，同一个机制 `MemoryWriterPages.swift:219-330`、`CatalogRunner.swift:426-640,940-962`。
    - 第一次开种子先清旧种子：把楼层整个 `memory/wiki`（含提案、状态、历史、整理记录）备份到 memory 旁「记忆备份/种子清理前-<时间>」（`.partial` 暂存、逐文件大小 + SHA256、写完成清单才发布，清理清单 `种子清理清单.json` 随备份存，再按清单核一遍），核过才删且只删三类：旧 `.seed-state.json`、全部旧「种子」提案（任何状态）、旧种子提案新建的页（连 `.history`）。认定只看提案记录（来源种子 + 已批新开页），不看标题、不追分组调整；旧种子改过的非种子页、留下的页里还连着被删页的，只列在结果里，不动。删之前先全部挪进暂存夹，挪不动就全部挪回 = 一个都不删；删完重建索引、收掉只剩 INDEX 的空分组。只做一次，旧的 `.runs` 留着 `CatalogSeedCleanup.swift:44-139`、`MemoryRegeneration.swift:74-77`。
    - 原料 = 本楼层 Prompt 里人填的全部文字（完整底图，含自建槽 / 关着的槽，不截断）、CC 记忆顶层全部 Markdown（不分类型、没 frontmatter 也读；`private_` 不打开、只记份数；符号链接 / 读不了 / 正文空的跳过并列出）、现有 wiki 根索引和每页全文 `CatalogSeedTask.swift:40-63`。
    - 一个 agent（同 CatalogAgent 循环和后端，不带{助手}的聊天 prompt，用 C3 选的模型）只有两个工具：`read`（只能读这次清单里的路径，每份完整读一次，读过的再读只回一句）和 `submit_proposal`（phase = outline 交整份目录：路径 / 七类 / 标题 / 钩子 / 原料；phase = page 交一个获批目录项的正文条目）。没读完不能交目录；目录项路径要在工程 / 楼层下、类只能七类、原料必须读过；正文条目只认这个目录项那一页，新开页的类 / 标题 / 钩子按目录；记录行出处只能是读过的原料，没有的行扔掉；已有页只能交更新 `CatalogSeedAgent.swift:55-347`、`CatalogSeedTask.swift:298-420`。
    - 不设原料字数 / 文件数 / 页数 / 轮数上限，回执全量进同一个请求，不截断、不摘要、不换模型；服务商说上下文太长就停下写「这次完整种子材料超出当前模型上下文，尚未完成（第 N 轮 · 模型 X）」+ 服务商原话，不记完成。没有替代闸门：不调工具只提醒、交得不合格只回错误，只有她点停、服务商报错、全局总闸会停。不查、不扣日常写入预算（全局总闸照查），花费记「wiki 种子」。任务绑 C3 所选模型的稳定身份（不是显示名），换了模型不续跑；所选本机模型用不了要回退到别的模型时，种子直接不跑 `CatalogRunner.swift:473-477,576-581,1148-1152`、`UsageLedger.swift:5,13`。
    - 交完目录就停（批前不在后台跑）；目录在审计台批 / 驳回后，同一个任务从 `wiki/.proposals/<任务 id>/task.json`（完整 history / 工具回合 / 原料清单和读到的版本）接着写，只写获批项，一页一份正文提案，正文还要再批才写进 wiki；不重读原料、不按页重开 agent。批改动只是控制消息。种子换了 C3 模型不续跑。停了 / 出错 / 被拦可在二级页点「继续这个种子任务」，也可「放弃这次种子」（剩下待批的目录项驳回）`WikiProposalViews.swift:676-712`。
    - 完成只按整份目录算：没有待批、至少一页获批、获批的页都交了正文提案（正文还待批不拦），才写新的 `.seed-state.json`（带任务 id）；只批了部分、空目录、目录全驳回、停 / 出错都不算完成 `CatalogRunner.swift:572-600`、`CatalogSeedTask.swift:141-152`。
    - 可视化：每轮请求（第一轮全量、之后只记新增）、每次文件调用的完整回执、目录 / 正文的校验和停下原因都写进同一份 `wiki/.runs/`，续跑接着同一份写；记忆日志每轮一行带同一份记录和这一轮的锚点；目录和正文提案都带记录链接，详情页「这次的整理记录 ›」打开；文件库 记忆 › wiki › 「种子待批」里每个任务一个文件夹，「目录」和各页草稿就是同一份待批提案，能看能改（待批的才能改；改完重新核路径 / 七类 / 出处 / 页版本，别处改过就拒），审计台立刻看到；审计台批的时候内容和她看到的不一样就拒批 `CatalogSeedDrafts.swift:56-246`、`FileLibrarySeedFolder.swift`、`FileLibraryPanelView.swift:291-302,1485,1547`、`WikiProposal.swift:343-353`。
    - 存储：本任务的目录、正文提案和任务快照都在 `wiki/.proposals/<任务 id>/`；收到工具调用先落盘再执行，正文按稳定提交 id 存，重启续跑先对账已存下的产物、不重新问模型 `WikiProposal.swift:195-256`、`CatalogSeedAgent.swift:138-190,321-330`、`CatalogRunner.swift:538-560`。wiki 原料只认楼层 wiki 根里的真实文件 / 文件夹，符号链接一律不读，各层分组索引都是原料 `CatalogSeedTask.swift:55-190`。
    - 30 天清理：任务还没结束的目录提案和任务快照不清；结束了的（完成 / 结束没完成 / 放弃，按结束时间）文件夹里没剩提案就连快照一起清，没交出目录的也清 `WikiProposal.swift:258-275`。
  - 同一楼层同时只跑一个，后来的（手动 / 自动）排队；「停」= 正在跑的不再发请求、排着的不跑；被写入预算 / 全局闸拦下或点了停，这个主题不出提案、后面的主题也不跑，前面已交的提案照留 `CatalogRunner.swift:72-96`、`:292-328`、`:442-472`。花费记在 C3 名下；选了本机模型不花钱 `CatalogRunner.swift:474-498`。
  - 停止也传入三路检索与快照：Session / Agent 的 CatalogCancel 与原生 Task.cancel 桥接，逐词扫描、窗口批次、文件读取、词袋 / 向量文档及写回间检查；取消不再继续回退 / 融合 / 登记来源，也不写部分补算向量。同楼层等待会话沿实际锁流程继续。已进入的单次 fetch / SQLite step / 文件读取解析 / 同步 embed 不抢占，完成这个单元后停，不启动下一批 `CatalogSorter.swift:105-129,330-350`、`CatalogRetrieval.swift:132-169`、`SearchService.swift:176-300`、`CatalogRunner.swift:680-710`、`CatalogRetrievalCancellationTests.swift:49-196`。
- 短窗口：整个窗口主线两边加起来不超过 5 条消息的，后台收尾不写 A2 尾段、不写 A3（A4 照写，「正在记」也不显示 A3 在等）；聊到第 6 条以后照常；对话 ⋯「现在写」不受影响；门槛和三代搬迁跳过短窗口是同一个数 `SessionCloseout.swift:601-603`（skipsSummary）、`:656`、`:816`，`MemoryMigration.swift:30`。
- 记忆 app「窗口总结」格：一行一个窗口，「记了 N 段」= 这个窗口 A2 的段数（第 0 段 + 正式段 + 尾段，老收尾段不算；只有窗口总结、没有 A2 的不写段数）`MemorySessionsView.swift`（WindowSummaryListLayout.rows）。点进去头上「A3 一段 · A2 N 段」：最上面 A3 一张卡（写到哪天；windows/ 只有一段、从头压的才算，v4-1 那种多段抄本显示「还没压成窗口总结」），下面 A2 一段一段从早到晚（改版前的累计摘要打头、尾段标「尾段 · 还在聊，会整段重写」），起点以前没搬的老收尾段灰字一组放最下面「老收尾段（v4，起点以前没搬）」；时间轴条目「看窗口总结」、对话 ⋯「窗口总结」同一页 `WindowSummarySheet.swift`（WindowSummaryReader.doc / WindowSummaryPage）。对话 ⋯「上下文摘要」也列尾段（标出来），老收尾段不列。
- 「正在记」那行按 A3 / A4 两个写入开关判：都关着写「A3 窗口总结、A4 时间轴都关着，窗口收尾不跑」，只关 A2 不影响收尾 `MemorySessionsView.swift`（queueNote）。
- 审计台首页（记忆 app 底栏最右一格「审计台」/ mac 右栏同一格，10-23 起）：两列方块，一块一个「台」——台名、现场数字（没事时那里写一句状态）、一行小字、右下图标；点一块推那个台，切楼层退回首页 `MemoryAuditHome.swift`。台是注册出来的（`AuditStation.all`：名字、图标、底色、现场数字怎么算、能不能点），首页不写死 `AuditStation.swift`。现在四块：
  - 整理台：「N 没看过」/「都看过了」，userBubble 底，点进去 = 下面的卡片页。
  - wiki：「N 待批」（还有待阅加「 · M 待阅」）/ 只剩待阅「N 待阅」/「N 页 · 没有待批」/「还没有页」——待批和待阅（没收进页、还没点「知道了」）分开数，assistantBubble 底，点进去 = wiki 台（见下）。
  - 试写台：灰着不能点，写「还在搭」（第 ③ 段点亮）。召回测试台：灰着不能点，写「以后做」。
  - 底色只用主题令牌（灰着的一律半透明 mainBg + 灰字），深浅色 / 换主题自动跟；现场数字每次回到首页、记忆有变、C3 跑完重算，后台读。
- 整理台（审计台 › 整理台；设置 → 记忆 → 整理 第一行直进）：档案一条一张卡 `MemoryAuditPage.swift` `MemoryAudit.swift` `MemoryAuditStack.swift`。
  - 顶上一次性横条「v5 碎片池有 N 条还没看过 · 全部删掉 ›」+ ✕：只算这一版第一次启动之前 C2 写的、没看过、活着的；点了居中确认后移到已删除（可恢复），用过或点 ✕ 不再出 `MemoryAudit.swift:166-188`。
  - 三段「没看过 N / 留下 N / 删了 N」（删了 = 所有已失效的，含以前做梦毕业 / 整理合并掉的）；一行小字写当前筛选条件 +「筛选 ›」弹层：来源（全部 / 改版前的原子档案 / v5 碎片池——C2 写的按带不带「发生在哪天」认，拖重要度不改来源 `Memory.swift:65`）、类别、日期（今天按 05:00 日界 / 7 天 / 30 天 / 自己选）、来自哪个窗口（按条数多→少）。
  - 牌堆 / 列表（10-17）：「没看过」默认是一叠卡（牌堆），「留下 / 删了」默认是列表；筛选行「筛选 ›」右边一个图标按钮三段都能切列表 ↔ 牌堆，选择只记到切楼层 / 重开 app 为止（不存盘）`MemoryAuditPage.swift:254-272`（layoutToggle）`:73`（showsStack）。
  - 牌堆：只画最上面三张，后两张露边；没有左右划的手势，只用卡底两颗按钮——没看过「删 / 留」、留下「删 / 留」（留下里的「留」不改库，只是看下一张，一叠过完写「这一叠看完了」）、删了「彻底删 / 恢复」（彻底删要确认）；留 / 恢复往右飞、删往左飞，减弱动态效果时只淡出；正文在卡里不折叠、自己滚 `MemoryAuditStack.swift:100-180`、`MemoryAuditPage.swift:411-461`。
  - 牌堆最上面那张压住：拖了重要度 / 改了类别（都算留）、改完不匹配筛选、后台新写进来更新的，它都不走，按了留 / 删才换下一张 `MemoryAudit.swift:79-85`（deck）。
  - 牌堆下面「↶ 撤回上一张」：只撤最近一张（留的回没看过、删的恢复、恢复的删回去、留下里过掉的拿回来），撤了那张回到最上面；彻底删撤不回；拖过的重要度 / 改过的类别不撤；换段、改筛选、切列表 / 牌堆、进出选择、切楼层都清掉；那张在别处又改过（对不上）撤回行置灰、撤不了；列表里没有撤回 `MemoryAudit.swift:86-146`、`MemoryAuditPage.swift:372-406`。
  - 牌堆空了：有筛选时「这些条件下没有没看过的 / 留下的 / 删掉的」+「清掉筛选」；其余同列表的空状态。
  - 重要度滑条（卡里，替换原来的圆点）：1–5 连续拖，松手吸到整数才存，算「留」；没定的停在 3、写「没定」，拖过才存；松手值没变不存；已失效的、iOS 列表「选择」中不能拖 `MemoryAuditStack.swift:183-240`（MemoryAuditImportance）、`MemoryAudit.swift:196-203`（setImportance）。
  - 卡片：列表里正文收起 3 行；信息行「类别 ▾ · 日期 · 《窗口》 · 你改过 · 图钉」，点类别五选一立刻存；点正文展开原话（只取出处那一条消息前 300 字，老档案用原话引用，都没有写「没有出处」）、「跳到这条 ›」（mac 设置窗里没有）、「改字」（不钉、记「你改过」）。列表按钮：没看过「留 / 删」，留下「删」，删了「恢复 / 彻底删」（彻底删要确认）。列表里 iOS 左右滑、mac 右键同一组动作；iOS「选择」切成列表多选批量（mac 切到列表就是原生多选）；⋯「把筛出来的 N 条都删掉」（居中确认）。
  - 规则：留 = 记审过；删 = 标失效进已删除；改字 / 改类别也算留；恢复不清审过（没审过的回没看过）；不自动合并 / 删 / 标失效、不提示可能重复、不审{助手}的记忆。保存失败顶上一行红字，不收尾。
  - 碎片卡（牌堆和列表同一张卡）信息行下面一行灰字：「已整理进《页名》」/「单条就够」/「整理时驳回」，都没有不显示；不算审计三态，留 / 删照旧 `MemoryAuditStack.swift:38-44`、`MemoryAudit.swift:190-196`。
- wiki 台（审计台 › wiki）：顶上两段「页 | 整理提案 N · 待阅 M」（待批 / 待阅分开数、是 0 的不写，后台读；几路刷新合成一次、旧读取不回写）`MemoryWikiPage.swift`。「页」= 两行「工程」「楼层」各带「N 页 ›」（小字「整理好的档案，一个点一页」），点进去一层层推 `WikiFolderPage`；没页时「还没有页——在「整理提案」批了提案才会写进来」+「去整理提案 ›」。「整理提案」= 原审计台第四段原样搬来（下面几条），数据不动。切楼层两段都回默认。
  - 整理提案顶上：「现在整理」「整理一个主题…」（弹框「整理一个主题」，输入框「比如：电影」，「开始 / 取消」，说明「搜这个词相关的聊天和碎片，整理成一份提案」）；在跑时换成「正在整理：{主题}（第 N 轮）」（排着的加「 · 后面排着 N 次」）+「停」；C3 关着（含总开关关着）两颗灰掉，下面「C3 整理在设置里关着」+「去设置」（推 C3 二级页）；跑完一行「上次：…」`WikiProposalViews.swift:100-178`。
  - 提案列表：一份一张卡「10-18 05:02 定时整理 · 新开 2 页 · 追加 9 行 · 改现在 1 处 · 连线 3 条」（来源：定时整理 / 现在整理 / 整理主题「主题」；是 0 的项不写；还有改钩子 / 分组调整），下一行「待批 N」/「已处理」，没整理完的加「· 没整理完」；空时「还没有整理提案」`WikiProposalViews.swift:77-98`、`:182-200`、`WikiProposalDisplay.swift:54-78`。
  - 目录项点进去（10-23）：方向项（种子目录 / 日常）那一行有「看详情和原料 ›」/「看详情 ›」，有碎片出处的正文条目有「看碎片全文 ›」；种子目录项上原来那一坨原料路径换成「原料 N 份」。推进去的页复用整理记录那套原生只读查看（iOS UICollectionView / mac NSTableView）：标题、路径 / 类 / 标题 / 钩子 / 理由（日常写「为什么」）/ 别名 / 依据 / 批了以后原地写，「原料 N 份 · CC n · wiki n …」下面每份一张卡（名称 · 层），点卡弹 sheet 用 TextKit 2 看全文、可选中可复制。正文先取种子任务这次实际读到的回执（任务解析和回执索引按 task.json 修改时间缓存），现状只取这一项列着的那几份、只用来比版本：变了 sheet 顶上和卡上标「这份原料在提案之后改过」，清空了标「改过（现在是空的）」，确实不存在才标「已经不在了」，读失败（权限 / 链接 / 编码）标「现在读不了（原因）」；离开页面后台读取在下一份之前停。现状走种子同一套白名单规矩，路径任一段以 private_ 开头的不列、不取、不读；SafeWiki 在打开文件、生成索引前就跳过私人页和私人文件夹（种子原料链同受保护），历史 INDEX 回执里指向私人页的行剥掉。mac 设置窗里目录项走 `SettingsRoute.memoryProposalItem`，页顶 ‹ › 回得去、前进得回来 `WikiProposalItemPage.swift`、`WikiProposalSources.swift`。批 / 驳回 / 改仍在提案页那一行上。
  - 提案详情按页分组（组头「标题 · 楼层 › 人 › …」）：新开页列钩子 / 触发词 / 现在 / 记录 / 连到 +「看整页 ›」（弹整页预览）；追加记录一行一条「+ …」浅底；改现在旧的浅灰删除线、新的在下（原来空写「（原来是空的）」）；连线「→ 《页》 · 关系 · 为什么」；改钩子 / 触发词「旧 → 新」；分组调整列层 / 新分组 / 挪动；带新旧判断的写「新旧判断：冲突 / 共存」`WikiProposalViews.swift:335-450`。
  - 原文出处明示用户 / 助手、主线 / 支线、消息节点；助手发言标「非用户事实」。只有本次实际提供的 nodeId 可引用，稳定楼层 / 窗口 / 时间 / 角色取登记快照，不信模型自报。审核加载时后台核验当前同楼层窗口未进回收站、节点仍存在且可见；有聊天视图时仅有效目标显示箭头，点击重新读取再核验。失效显示「原消息已删除 / 不可定位」，不导航、不误报切支线；只是换分支而节点还在，沿现有 node 定位。A2 必须是实际提供的段，A3 / A4 不能互借层；旧提案不猜 nodeId，旧 A 线概览不变 `CatalogWriter.swift:196-230`、`WikiProposalDisplay.swift:90-164`、`WikiProposalViews.swift:476-505,522-528,605-621`。
  - 每条「批 / 改 / 驳回」；「改」弹表单就地改文字（钩子、触发词、现在、记录行、为什么连、分组名和钩子；方向改目标页路径 / 标题 / 钩子，路径不合法就不改），「存」只存回提案、不写页；「确认已覆盖」没有「改」，下面列页上已经写过的碎片和「对照这一页现在的样子 ›」（页不在写「这一页已经不在了」）；「改」的保存和批 / 驳回 / 执行同一把锁；处理过的写「已批」/「已驳回」；页在提案之后被改过（或新开页已存在）这条置灰「页在这之后被改过，重新整理」，不能批 `WikiProposalViews.swift:351-367`、`:640-736`、`WikiProposalDisplay.swift:113-133`。
  - 底部（还有待批时）「整批驳回」（确认「整批驳回？」「剩下待批的条目全部驳回，用到的碎片以后不再自动整理」）/「整批批」= 剩下没处理的全批 `WikiProposalViews.swift:316-321`、`:524-542`。
  - 方向（「方向 · 更新已有页」/「方向 · 开新页」）显示标题、钩子、为什么、线索碎片（只列标题）、「批了以后查一次原料、写一次 / 自己查原料再写（最多几轮），写好的正文再交你批」；批了以后行下写「已批 · 还没开始写 / 正在查原料、写 / 交了 N 条正文等批 / 没有可写的材料：… / 被拦 / 停了 / 出错」。批方向不写页、不动碎片，批完自动开始执行；没跑成也记下原因（「C3 关着，没执行」「排队时点了停，没执行」「楼层或模型没准备好，没执行」），冷启动时上次进程没写完的记「交了 N 条正文等批（上次运行中断前已交）」或「上次运行中断，没交正文」，都不再执行；同一条只执行一次，重复点「批」或重复触发不重付；驳回方向不连带驳回线索碎片。正文提案头上写「你说的：…」（手动）或「这是批过的方向写出来的正文，批了才写进 wiki」`WikiProposalViews.swift`（statusLabel/changeBody/approve）、`WikiProposalDisplay.swift`（kindLabel/summary/WikiProposalDraft）。
  - 批了：写页（覆盖前整页存一版历史）→ 用到的碎片标已整理进那页 → 重建索引 → 记忆日志记一行；驳回：用到的碎片标「整理时驳回」，以后不再自动整理；失败顶上红字「没批成：…」/「没驳回成：…」`WikiProposal.swift:199-233`、`:293-300`、`WikiProposalViews.swift:545-581`。
  - 出处：碎片「碎片：前 40 字 ›」点了跳到那条消息（删了写「碎片（已经删了）」）；A 线「层 · 日期 · 《窗口》 · 第 N 段 · 消息 a–b ›」点了弹那个窗口的窗口总结 `WikiProposalViews.swift:454-501`。手动出的提案多一段可展开「它搜了什么」= 那次每一轮的记忆日志 `WikiProposalViews.swift:273-289`、`WikiProposalDisplay.swift:139-147`。处理完满 30 天的提案清掉，打开已清的写「这份提案不在了」`WikiProposal.swift:106`、`:156-158`、`WikiProposalViews.swift:296`。
  - mac 设置窗里推详情走设置路由；那里碎片出处不能点、窗口总结弹窗没有打开窗口的按钮 `WikiProposalViews.swift:9-24`、`:311-314`、`:461`。
- 常驻记忆（记忆 app 记忆格最上面一行「常驻记忆 · N 条 ›」，小字「每一轮都带的，点进去看为什么」或「其中 M 条现在不带」；搜索时藏起来）`MemoryPanelView.swift:463-489`（residentSection）`MemoryResidentPage.swift` `MemoryResident.swift`。
  - 「从聊天里记住的」那组不搜的时候不再列常驻的（常驻只认钉住的），钉一条它就挪上去、取消钉挪回来；搜索时照旧全列 `MemoryPanelView.swift:1031-1037`（activeMemories）`MemoryService.swift:457-469`、`:865-868`。
  - 常驻页上半「每一轮都会带的」有「C 档案」一组：写「根索引 N 行 · 本轮命中：页名（“命中词”）」，多页用顿号，没命中写「根索引 N 行 · 本轮没命中」；wiki 空不出这一组 `WikiInjection.swift:150-154`、`MemoryResident.swift:321-326`、`MemoryResidentPage.swift:107-121`。
  - 常驻页另列「关于{用户称呼}」一组（原因「你钉的」· 类别 ▾ · 日期，钉住的左滑 / 右键取消钉住）、「{助手}的记忆」一组（原因「重要度 5」/「最近 N 条」，N 跟开窗口页设置，只看）；这一轮没带的写灰字：记忆关着 / C 没勾 / B4 没勾 / 超出注入预算；全量注入开着时一行「另外 M 条档案也每一轮都带（预算内）」；一条都没有时写怎么钉。下半「下一轮会看见什么」= 原 ⋯「下一轮会想起什么」（那一项已从 ⋯ 拿掉），第二段标题按实际：只开全量注入写「全量注入开着：预算内都带」，开了关键词 / 按意思找写「聊到相关话题才会想起的」`MemoryPanelView.swift:1144-1160`（InjectionPreviewSections）。规则直接取实发用的检索器，和实际注入一致；在后台算，主线程不碰盘。
- wiki 的页（10-23 起从记忆格挪到审计台 › wiki 台，记忆格不再有「wiki · N 页」，两组记忆都空就出整页空状态）。点进去一层层推：分组行「标题 / 钩子 / N 页」，页行「标题 / 钩子」，空层「这里还没有页」；点页弹可编辑的页编辑器（同文件库，带历史）；后台读，记忆有变重读，切楼层退回 `WikiViews.swift:244-331`、`MemoryWikiPage.swift`。
- 文件库「记忆」文件夹里 `wiki` 显示「C 档案」；`.history` / `.proposals` / `.group.md` 这类点开头的不列 `MemoryTreeBrowserSheet.swift:109`、`FileLibraryMemoryFolder.swift:8-30`。INDEX.md（代码生成的索引）照旧只读；页点开是文件库同一个编辑器、可编辑：保存前比对磁盘，别处改过报「这页已在别处改过，请关闭重开后再保存。」；存前旧版进历史，存后后台重建索引；页里 [[双链]] 只在 wiki 里换页（不存在的页不建）`FileLibraryPanelView.swift:1630-1648`、`WikiViews.swift:50-98`、`FileLibraryMemoryFolder.swift:32-37`。
  - 顶栏「历史」（时钟图标；⋯ 里的版本历史也走它）：新→旧列版本，没有写「还没有旧版本，改过一次以后才有」；点一版看全文，「恢复这一版」要确认（「现在这版会先存进历史，随时能再换回来。」；编辑器里有没存的改动时改说会丢掉）`FileLibraryPanelView.swift:2076-2083`、`:2446-2480`、`:2846-2848`、`WikiViews.swift:101-239`。
- 文件库「Prompt」文件夹（和「记忆」平级、紧挨在它后面；小字「N 段 · 和 Prompt 页同步」）：当前楼层预设实例的插槽一个一行，按 Prompt 页顺序排（不跟文件名 / 时间排序），标题就是插槽名原样（重名、带斜杠照显示；没名字的标题空着、标「未命名」），空槽、关着的槽也列（标「已关闭」），不显示时间；列表视图标在副标题，卡片视图标成标签 `FileLibraryPromptFolder.swift:61-71`。插槽后面是「楼层字段」文件夹，列楼层上填过的旧字段（系统指令 / 用户描述 / 助手设定 / 助手性格 / 背景设定 / 对话示例 / 后置提醒，没填的不列）；一个都没填就不出这个文件夹 `FileLibraryPromptFolder.swift:24-37`、`FileLibraryPanelView.swift:598-603`、`:1392`。面包屑写「文件库 / Prompt / 楼层字段」`FileLibraryPromptFolder.swift:43-45`、`FileLibraryPanelView.swift:557`。这里没有「＋ 新建」和排序选择（顺序就是 Prompt 页的）`FileLibraryPanelView.swift:641-646`、`:995`、`:1011`。采样参数、开关、深度 / 角色、三份格式模板都不在这里 `PromptFolder.swift:118-136`、`FileLibraryPanelView.swift:111-126`、`:875-876`。
  - 点开是纯文本编辑器（标题 = 插槽名，没名字写「未命名插槽」），存的就是 Prompt 页那一份：按楼层 + 预设 + 插槽 id 找回去只改这一段，写盘成功才算存上；存不下弹「保存失败」；打开后 Prompt 页又改过同一段报「这段在别处改过了，请关闭重开后再保存。」；换了预设 / 插槽删了报「这个插槽已不在当前楼层的预设里（删了或换了预设），没有保存。」，不会改到别的槽。楼层字段存回楼层本身 `PromptFolder.swift:58-70`、`:141-172`、`FileLibraryPanelView.swift:255-280`、`MemoryPalaceApp.swift:378-386`。
  - 对话历史 / 上下文摘要 / 时间轴 / 用户画像 / 记忆 / 世界书（前）/ 世界书（后）这几个自动填充的槽（发送时用系统内容、不读槽里存的字）只能看（副标题「自动填充」），只显示槽里存的字，空着时写「这一段发送时由系统自动填充。」`FileLibraryPromptFolder.swift:48-50`；Prompt 页插槽编辑也同样只锁正文、写「此插槽由系统自动填充」，三处共用一个判断 `Preset.swift:54-58`、`PersonaSettingsTab.swift:731`、`:2690`。插槽和楼层字段没有长按菜单（内部路径复制出来也用不上），不能新建 / 改名 / 删（去 Prompt 页做）`FileLibraryPanelView.swift:946-962`、`:1730-1732`。
  - 文件库里的 `.prompt` 名字归这个虚拟文件夹：新建、写、追加、改、删、改名（从里面搬出或搬进去）一律拒「「.prompt」是 Prompt 插槽的虚拟文件夹，文件工具读写不了；插槽在 Prompt 页或文件库「Prompt」里看和改。」，按规范化后的路径判（`./.prompt`、大小写、`a/../`、经符号链接都算）；{助手}的 fs_* 工具连读也拒、fs_list / fs_search 不列 `CalendarPrivacy.swift:37`、`:83-103`、`FileLibraryStore.swift:228-230`。这之前就在库里的真 `.prompt/` 文件照样列在「Prompt」里（排在插槽后面），点开只读 `FileLibraryPromptFolder.swift:10-31`、`FileLibraryPanelView.swift:1656-1660`。
  - Prompt 页简单模式只提交这次改过的栏，没动的栏跟着别处（文件库）的改动刷新，不拿打开时的旧内容盖回去；写盘失败或那一栏的插槽没了：弹「保存失败」，字留着、下次再存，刷新也不会把它换掉 `PersonaSettingsTab.swift:1648-1651`、`:2448-2477`、`:2556-2566`。
  - Prompt 页插槽编辑页（iPhone / iPad）：打开时记住楼层、预设、插槽和当时的内容；保存按插槽 id 找回去、只改动过的项，正文被别处改过报「这段在别处改过了…」，插槽删了 / 换了预设报「已不在…」，存不下弹「保存失败」；存上了才退出，没存上字留在页面上 `PromptFolder.swift:174-200`、`PersonaSettingsTab.swift:2571-2620`。
  - 只是同一份数据换个地方看：不往磁盘复制，备份恢复的还是预设 / 楼层本身，恢复后这里自动重建。
- {助手}的文件工具看不到 wiki 内部：`fs_list` / `fs_search` 不列 wiki 里点开头的（历史、提案和模型原始输出、分组钩子），`fs_read` 读这些（路径规范化后判）回「没有这个文件」；wiki 的页、INDEX.md 和 memory/ 其他部分照旧只读能看 `FileLibraryTools.swift:72-77`、`:113-124`、`:284-290`。
- 记忆 app 底栏四格「记忆 / 窗口总结 / 时间轴 / 审计台」（iOS 系统页签栏、mac 底部胶囊同一份；审计台格是方块首页）；⋯ 里剩加一条 / 选择 / 暂停时间轴 / 关系图 `MemoryPanelView.swift:176-196`（MemoryPanelTab）。
- 记忆日志：每次后台写一条（时间 / 编号 / 成没成 / 原因 / 模型 / 花了多少），存楼层 `memory/log/写入日志.jsonl`，保留 30 天或 1000 条。筛选「全部 / A2 / A3 / A4 / C2 / C3」`MemoryWriterPages.swift:1001`；C3 每次提方向、每个方向的执行结果、手动 agent 每一轮、批提案各记一行 `CatalogRunner.swift:164-166`、`CatalogAgent.swift:377-382`。

## 未完成 / 隐藏

- 「用户画像 · 做梦聚合」下线：不再写、不再注入，设置页 / 记忆 app 首屏 / Lite 页 / 整理弹层的画像入口都拿掉；画像文件和开关值留着不动。
- B2 日记、B3 做梦、B4 图数据库、开窗口「目录」都标「还没做」。新开窗口弹「纸条」当场选带什么：以后。
- 审计台来源筛选没有「C3 整理结果」一档：只在注释里留了话，枚举里没有 `MemoryAudit.swift:23-29`。
- 种子（C2/C3 v2 第 6 段）只在单测和门控 live 方法里跑过；真机五处可视化（`.runs`、记忆日志按轮点开、文件库「整理记录」、「种子待批」草稿可看可改、审计台两次批）还没在 😷 iPhone 14 上看过（走查单 `docs/walkthrough-memory-c2c3-v2-p6.md`）。
- C3 旧计划第四段的 `propose_memory_edit`（改 A2 / 改 A4 / 改 wiki 页）没做；C2/C3 v2 第 4 段只加了最小的 `suggest_wiki_direction`（只提 wiki 方向），不扩 A 线 / C2 编辑，{助手}的 fs 对 memory/ 仍只读。完整 A4 来源的方向发现（A4 主调、到期复核、人设变化）在 v2 第 7、8 段，还没接。
- wiki 台的页不能搜；页和整理提案是同一台的两段。方块首页 / 整理台 / wiki 台 10-23 换入口后没在模拟器 / 真机上看过。
- 「高级 · 整理旧记忆（调试）」只在 DEBUG 构建里（TestFlight / Release 没有）：「搬成新样子…」把当前这一层三代旧数据（改造前累计摘要 / 第三刀老段和老收尾段 / v4-1 窗口总结抄本）搬成 v5 的样子——先算（不调模型）弹确认框（楼层、分几类、几次调用、约多少钱、约多久、最贵三个窗口），整份备份 sessions / windows / timeline / pending / summaries 五个文件夹到 `记忆备份/v5搬迁-<时间>/`，一个窗口一个窗口搬，一个窗口要么全搬好要么原样，断了再点只搬剩下的，跑时屏幕常亮、有〔停下〕，结果另存「搬迁结果.txt」；总开关关着置灰，A2 / A3 / A4 单项关着照样能搬。「从备份恢复…」只换那份备份管的文件夹（老 v4-1 备份 = 三个）`MemoryMigration.swift` `MemoryRegeneration.swift`（restore）`MemoryRegenerationSection.swift`。

## 验证边界

mac + iOS build-for-testing、记忆相关定向套件见 `docs/review-memory-v5-settings.md`、`docs/review-memory-migrate-3gen.md`（三代搬迁：只用假写手 / 测试楼层跑过，没在真数据、模拟器、真机上跑过；窗口总结格新排法没在 390 宽看过）。界面（390 宽、二级页、滑条、日志跳转、现在写）没在模拟器 / 真机上看过；审计台（含 10-17 牌堆 / 重要度滑条 / 撤回，见 `docs/review-memory-audit-cards.md`）、常驻记忆页、底栏四格 + 设置 sheet 只编过两端、跑过单测（`MemoryAuditTests` / `MemoryResidentTests` / `SessionCloseoutQueueTests` 等，见 `docs/plan-memory-audit-desk.md`），没在模拟器 / 真机上看过；本机模型填 JSON 的效果只在 Mac 上离线跑过合成样本（没在 app 里跑过）。C3 第一段（todo 1–11b）各项有单测；plan 第 12 项（两端 build-for-testing + 定向测试 + 审 + 复盘）还没勾，整理提案格、C3 二级页、文件库 C 档案、记忆格 wiki 都没在模拟器 / 真机上看过，真模型跑整理的效果和花费没实测（`docs/plan-memory-c3-catalog.md` 第十一节）。

文件库「Prompt」（C2/C3 v2 第 5 段，含 astra 返工）：`PromptFolderTests` 17 条单测 + mac / iOS build-for-testing 过；备份恢复只照抄了导出 / 恢复两端的序列化步骤（生产入口写死真实存储，没在隔离环境跑）；文件库列表 / 编辑器 / Prompt 页两边同步没在模拟器 / 真机上点过，见 `docs/review-memory-c2c3-v2-p5.md`。

C2/C3 v2 第 4 段（两批审批）：`CatalogDirectionTests` 15 条 + 受影响的 C3 套件行为测试、mac / iOS build-for-testing 过；真端点两批流程（`CatalogLiveSmokeTests` 五条）没跑，审计台方向卡、批后自动执行、工具抽屉默认关的开关都没在模拟器 / 真机上点过，见 `docs/review-memory-c2c3-v2-p4.md`。
