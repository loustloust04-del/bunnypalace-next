# C2/C3 v2 · P5 复盘：文件库「Prompt」与 Prompt 页同一份数据

> §1–6 是首交（已提交 `fda1bfa0e`）。astra 审查返工（P0×3、P1×2、P2-7）见 §7，§2–4 已按返工后的现状改写；行号以返工后工作区为准。

范围：`plan-memory-c2c3-v2.md` 第 5 段实现 1–7、提交 5。基线 HEAD `e62b23fa4`（开工时工作区有第 3 段并行改动，本段不碰那些文件）。不做 git 写操作、不开模拟器、不碰真机和真人数据。第 6 段种子本身（清旧产物、agent 跑法、两批审批、可视化）、第 4 段审批都没做。

## 1. 按第 5 段第 1–7 条

1. **虚拟根「Prompt」**：`MemoryPalace/Services/PromptFolder.swift`。虚拟路径 `.prompt/…`（点开头，避开她文件库里可能有的真 `prompt/` 文件夹）。只取 `presetId == profile.presetId && ownerProfileId == profile.id` 的楼层实例（`:117-119`），缺实例不回退模板；插槽按 `SlotOrder.ordered` 列（`:122-140`）。文件库侧 `Views/FileLibrary/FileLibraryPromptFolder.swift:10-29` 并进文件夹索引、插槽保持 Prompt 页顺序、紧挨在「记忆」后面；`FileLibraryPanelView.swift:111-126` 观察 PresetManager / 当前楼层，实例一变就重排。
2. **一个插槽一个文件、两边同源**：显示名 = `slot.name` 原样，正文 = `slot.content`（空槽、关闭槽都列）。保存 `PromptFolder.save`（`:142-167`）按 presetId + slotId 重读实例、只改这一段，走可抛错的 `PresetManager.persistNew`，写盘成功才更新内存；打开后同一段被别处改过 → `conflict`；预设换了 / 槽删了 → `gone`。编辑器用 `FileEditorSheet.text(.plain)`（`FileLibraryPanelView.swift:255-280`），保存失败弹「保存失败」不关。Prompt 页：`PersonaSettingsTab.swift:74` 新增 `iOSSimpleDirty`，`:2439-2472` 只提交这次改过的栏，`:1645-1648` 实例变化时刷新没在编辑的栏。
3. **marker / 楼层字段**：marker 只给 `slot.content`；记忆 / 对话历史 / 上下文摘要 / 用户画像四个自动填充槽只读（`PromptFolder.swift:73-74`，与 `SlotEditPage` 一致）。三份格式模板不进。「楼层字段」= `Profile` 的 systemPrompt / userPersona / characterDescription / characterPersonality / scenario / chatExamples / postInstructions，只列填过的（`:12-38`、`:133-137`），保存走新增 `ProfileManager.updateProfileChecked`（`MemoryPalaceApp.swift:378-386`，先写盘再改内存，楼层顺序不变）。采样 / 开关 / 深度 / 角色 / rawJSONData 不导出。
4. **完整底图**：`MemoryPalace/Services/Wiki/CatalogFloorBase.swift`：插槽按页面顺序全收（关着的标 `isEnabled = false`，不丢）；空 marker 槽沿组装的「显式槽优先、楼层字段兜底」在原位放字段原文；其余填过的字段完整排后面；名字宏展开；不截断、不跨槽去重、不调 PromptAssembler / TavernSync。每段带 `PromptFolder` 稳定路径作来源。`CatalogRunner.swift:595`（weak presetManager）、`:622-631`（`attach(presetManager:)` + `floorBase(profile:)`，MainActor 取不可变值），`MemoryPalaceApp.swift:1436` 注入。**没接进写手提示词**，`CatalogFloorPrompt`（五段 + 3000 截断）原样留给现在的写手。
5. **重名 / 空名 / 斜杠**：路径 = `.prompt/<presetId>.<slotId>.txt`（两段各自百分号编码，`.` `/` 都编掉，`PromptFolder.swift:86-113`）；字段 = `.prompt/fields/<属性键>.txt`。显示名不参与路径，改名不改身份；空名标题空、副标题「未命名」（`FileLibraryPromptFolder.swift:32-41`），不写回。
6. **只补虚拟目录**：没改查看器 / 列表性能实现，没做 3000 截断；没有改动时间的虚拟条目不显示时间（`FileLibraryPanelView.swift:804-812` 等，判 `.distantPast`）。长按只有复制路径；新建文件名以 `.prompt/` 开头被拦，在 Prompt 文件夹里点＋不预填路径（新文件落在文件库根）（`:1260`、`:1068-1071`、`:1708-1710`）。
7. **备份**：不新建任何文件，备份照旧存 `savedPresets` / `savedProfiles`，恢复后由同一份数据重建列表（单测模拟恢复的 JSON 重编码往返）。主聊天 fs 工具没有接这个虚拟根（plan 写的是「若访问」，本段不加）；种子对 Prompt 只读的接法留第 6 段。

## 2. 边界情况

- 楼层还指着模板（没实例）时，「Prompt」里只剩楼层字段，插槽一个都不列；进一次 Prompt 页（`ensureFloorInstance`）就会实例化。没在文件库里主动实例化。
- 同一段两边都开着：文件库编辑器和 Prompt 页插槽编辑页（iPhone / iPad）都对正文做 baseline 冲突检查（§7.2）；mac Prompt 页的插槽行内编辑是每键直写（按当前渲染的下标），不做冲突检查。
- 编辑器开着时插槽被删 / 预设被切：不自动关，保存时报「已不在当前楼层的预设里」，没存的字留在编辑器里给她复制。
- 楼层列表只读（#037）时字段保存抛「楼层列表读取失败…」；预设读坏（`blockWrites`）时插槽保存抛原错误；两种内存都不变。
- 简单模式：`iOSSimpleDirty` 只在写盘成功后清掉实际存上的栏；失败 / 槽没了留着、弹一次「保存失败」，刷新、重进页面、切到插槽模式都不丢这些草稿（§7.1）。mac 每键同步存，写不进时每次按键都会再弹（只在楼层 / 预设读坏的只读状态下出现）。
- 库里在这段之前就有的真 `.prompt/` 文件：列在「Prompt」里、只读能看，但改名 / 删除 / 移出都被拒，只能去 Finder / 文件 App 处理（§7.3）。真文件的路径若正好等于某个虚拟插槽路径（`.prompt/<预设UUID>.<槽id>.txt`），会和虚拟条目撞 id，没处理。
- 楼层字段为空不列；在文件库里把字段清空后它会从列表消失（数据就是空了）。

## 3. 与第 6 段交互的风险

- 第 6 段种子用 `PromptFolder.entries` / `CatalogFloorBase.sections` 的 `path` 作稳定读源与 Cite；路径格式（`.prompt/<enc>.<enc>.txt`）一旦被提案存进出处就不能再改。出处校验要按 `PromptFolder.source(of:)` 解析，不要按显示名。
- `CatalogRunner.floorBase(profile:)` 依赖 `attach(presetManager:)`；没注入时返回 nil（测试里的 `CatalogRunner()` 就是 nil）。后段接进 `makeJob` 时要决定 nil 是报错还是退回旧 `CatalogFloorPrompt`。
- 底图收关着的槽（标 `isEnabled = false`），不收自动填充槽里存的字；被显式槽覆盖的楼层字段不收（关着的槽填了字也算覆盖，和组装一致）。第 9 段写日常「详见人设」规则时要决定关着的槽算不算「人设已有」。
- 底图字段放置：空 marker 槽才在原位兜底（`main` 不是 marker，所以 main 空着时 `systemPrompt` 排后面；main 填了字时 `systemPrompt` 被覆盖不收），和组装一致；`characterPersonality` 永远在后面（组装里它是借 characterFormat 拼进角色描述的，格式模板不收）。
- 主聊天 fs 工具对 `.prompt` 一律拒（含读）。第 6 段种子要读 Prompt 时走 `PromptFolder.entries` / `CatalogFloorBase`，不能走 fs_read。
- 种子要读「楼层字段」时注意：只列非空字段，空字段不是「不存在的文件」而是没有这一项。

## 4. 技术债务

- 文件库 body 每次求值都会现算 `livePromptEntries`（读 `presetManager.presets`），Prompt 页拖采样滑条时文件库若同时可见会跟着重算 body；数据量小（一份实例的插槽），没做缓存。
- **P2-6（审查裁定不修，只记债）**：文件库 / Prompt 页 / 插槽编辑页的保存都在主线程同步编码并原子重写整个预设 blob（字段保存重写整个楼层列表，还会调 `prepareProfile`）。这是现有预设保存的通用写法，本段没改；预设集合大时可能卡一下，耗时没实测。
- mac Prompt 页插槽行内编辑（名称 / 角色 / 深度 / 正文）仍按渲染时的下标、拿渲染时的 preset 快照每键直写（`PersonaSettingsTab.swift` 原有代码），不做冲突检查。审查点名的是 iOS 插槽编辑页，mac 行内这条没改。
- 自动填充判断 `PromptSlot.isAutoFilled` 是按 `PromptAssembler` 里各 marker 分支手抄的 id 清单；组装以后改了哪个 marker 读不读存储正文，要同步改这里。
- 事实文档 `scripts/manual` 的 `npm run check` 没跑成：工位没装 node_modules（缺 gray-matter），没装依赖。
- 实际 UI 走查（列表、编辑器、Prompt 页同步、iPhone 宽度）没做，交车头。

## 5. 验证

- 基线（改动前）：mac build-for-testing `** TEST BUILD SUCCEEDED **`；9 套件 161 测全过（SlotOrder / FileLibraryMemoryFolder / FileLibraryDisplay / CatalogWriter / CatalogRetrievalCancellation / PromptRealPathGolden / InspectorRealPath / PersonaRequestBody / CatalogSeed）。
- 最终：mac build-for-testing `** TEST BUILD SUCCEEDED **`；iOS（MemoryPalaceIOS，iOS 模拟器目的地，只编不跑）`** TEST BUILD SUCCEEDED **`；12 套件 188 测全过（上面 9 套 + 新增 `PromptFolderTests` 12 条 + ProtectedDataGateTests + CallControllerTests）。两组金样未变、未 RECORD。

## 6. 走查要点（交车头）

1. 文件库首页「文件夹」：「记忆」后面紧跟「Prompt」，小字「N 段 · 和 Prompt 页同步」。
2. 进「Prompt」：顺序和 Prompt 页插槽模式一致；关着的槽副标题「已关闭」；最后有「楼层字段」文件夹（卡建的楼层里应有助手性格 / 对话示例等）。
3. 点一个自建槽改一句 → 保存 → 去 Prompt 页插槽模式看同一槽；反过来在 Prompt 页简单模式改「后置提醒」→ 回文件库看到新内容，且文件库刚改的「系统指令」没被盖回去。
4. 点「🧠 记忆」槽：只读预览，没有保存键。长按任一项只有「复制路径」；在「Prompt」里点＋，预填路径为空（不会建进 Prompt）。
5. 换一个楼层：「Prompt」跟着换成那层的插槽；另一层 / 预设模板不变。

## 7. astra 审查返工（P0×3、P1×2、P2-7；P2-6 只记债）

### 7.1 P0 简单模式提前清 dirty
- `PersonaSettingsTab.swift:2448-2453` `persistIOSSimpleDrafts` 改调 `:2457-2477` `commitSimpleDrafts`：只把 dirty 栏写进最新实例，走可抛错的 `PresetManager.persistNew`；返回还没存上的栏——写盘失败 = 全部 dirty 留着，槽没了 = 那几栏留着，其余存上了才清。错误进 `iOSSimpleSaveError`，`:131` + `:2556-2566` `SaveFailedAlert` 弹出。
- 草稿不被换掉：`refreshedSimpleDrafts` 只刷新非 dirty 栏；`syncIOSSimpleDrafts` 同一份预设还有 dirty 时只刷新别的栏、不重置（`:2415-2419`）；`invalidateIOSSimpleDrafts` 有 dirty 时不清（`:2401`），切到插槽模式 flush 后有 dirty 不失效（`:1661`）。
- 没改到的口子：通过预设选择器换到另一份预设时，旧预设上没存上的 dirty 草稿会丢（换预设前已有的 flush 会再试一次并弹错）。

### 7.2 P0 插槽编辑页按旧下标整组写回
- `PromptFolder.swift:174-200` 新增 `PromptSlotEdit`：打开时钉 `profileId + presetId + baseline 槽`；`commit` 经 `ownedSlot`（`:164-172`）校验楼层当前预设、实例归属，按 slotId 重找；只写改过的名称 / 角色 / 深度（非 marker），正文按 baseline 做冲突检查（和文件库同一口径），自动填充槽不动正文；`persistNew` 成功才算存上。
- `PersonaSettingsTab.swift:2571-2620`：`SlotEditPage` 改按 `slotId` 显示和保存，`onAppear` 只建一次会话（`:2748-2757`），`saveAndExit` 成功才 `dismiss()`，失败弹「保存失败」、字留着；删除按会话里的 presetId + slotId。`SlotNavigationModifier`（`:2767-2823`）和列表入口（`:63`、`:2050`、`:2114`）从下标改成 slot id，编辑期间删槽 / 重排都不会把页面换成另一个槽。

### 7.3 P0 `.prompt` 和物理文件隔离
- `CalendarPrivacy.swift:37` `FileLibraryAccess.Zone` 加 `prompt = ".prompt"`，沿用已有的规范化 + 解符号链接判定（`./`、大小写、`a/../`、经符号链接都算）；`:83-84` 读写都拒；`:91-96` `listedVisible` 把 `.prompt` 从注入清单 / 提及清单里藏掉；`:98-103` 拒绝文案和 `isPromptZone`。主聊天 fs_* 走已有的 `denial` / `visible`，所以 fs_read / fs_write / fs_append / fs_edit / fs_rename（两端）/ fs_delete 都拒，fs_list / fs_search 不列。
- `FileLibraryStore.swift:228-230` `rejectPromptZone`，接在所有物理写入口：写 `:511`、追加 `:529`、删除 `:593`、改名两端 `:608-609`、`createIfAbsent` `:629`、`writeData` `:658`（`edit` 走写）。读不拦。
- 呈现方式（我定的）：库里已有的真 `.prompt/` 文件不遮住——`FileLibraryPromptFolder.swift:10-31` 把它们并在虚拟插槽 / 楼层字段后面列（文件夹计数相加），不再覆盖索引；`FileLibraryPanelView.swift:1636-1639` 只有路径在虚拟条目里才走插槽编辑，其余 `.prompt` 真文件 `:1656-1660` 只读打开；`:1524` 刷新显示时只清虚拟条目的缓存，不清真文件的。

### 7.4 P1 底图「显式槽优先、楼层字段兜底」
- `CatalogFloorBase.swift:33-50`：对应槽填了字（开着关着都算）就把那个字段记为已路由、不再追加；对应 marker 槽空着才在原位放字段原文；没有独立槽的字段（助手性格、后置提醒）和没被路由的字段照旧完整排后面。

### 7.5 P1 自动填充只读清单
- `Preset.swift:54-58` 新增 `PromptSlot.isAutoFilled`：对话历史 / 上下文摘要 / 时间轴 / 用户画像 / 记忆 / 世界书前 / 世界书后（按 `PromptAssembler.swift:363-470` 各 marker 分支，这几个都不读存储正文）。共用处：文件库列表和保存守卫（`PromptFolder.swift:125`、`:150`）、编辑会话（`:192`）、底图（`CatalogFloorBase.swift:38`）、Prompt 页 mac 行内（`PersonaSettingsTab.swift:731`）和 iOS 插槽编辑页（`:2690`）。旧的四项清单全部删掉。

### 7.6 P2-7 测试（`MemoryPalaceTests/PromptFolderTests.swift`，12 → 17 条）
- 新增 `testSimpleModeKeepsDraftsWhenSaveFailsOrSlotIsGone`：写盘失败 dirty 留着、不改内存、刷新不换草稿；槽没了那栏留着，别的栏照存。
- 新增 `testSlotEditPageCommitsOnlyChangedFieldsAndChecksContentConflict`：编辑页开着时文件库改了正文 → 只改名字不覆盖正文；改正文报冲突；新会话正常存正文和深度。
- 新增 `testSlotEditPageAfterReorderDeleteSwitchOrWriteFailureNeverHitsAnotherSlot`：重排后按 id 改对槽且其他槽不变；写盘失败不改内存；换预设后报 gone、同 id 的另一份实例不变；删槽后报 gone。
- 新增 `testPhysicalPromptPathsAreRejectedButExistingFilesStayReadable`（临时文件库根）：`.prompt/…`、`./.prompt/…`、`.PROMPT/…`、`a/../.prompt/…`、经符号链接，写 / 追加 / 独占新建都拒；`writeData`、改名两端、`edit`、删除都拒；六个 fs 工具都回拒绝文案；`visible` / `listedVisible` 藏掉；已有真文件照样能读、在列表里、并进「Prompt」索引且计数正确。
- 新增 `testFloorBaseDropsFieldsCoveredByExplicitSlotsAndKeepsSlotlessFields`。
- 改写 `testBackupRestoreRebuildsSameEntriesWithoutPromptCopies`：**生产链路没跑**——`GlobalExporter.dumpUDDataAsJSON` 和 `PendingImportApplier.applyStagingUserDefaults` 都是 private，读写写死真实 BlobStore 根和 `UserDefaults.standard`，隔离环境里调不了入口（缺的就是这两个入口的根 / defaults 注入）。测试照抄两端对 `savedPresets` / `savedProfiles` 的处理（pretty + sortedKeys 落 `userdefaults/*.json` → `jsonObject` → `data(withJSONObject:)` → `BlobStore.set`），验恢复后实例 id / ownerProfileId / sourceTemplateId 关联正确、列表同源，blobs / 恢复根 / 临时文件库里都没有虚拟副本。
- `testMarkerFilesExposeOnlyStoredContentAndAutoFilledAreReadOnly` 扩到七个自动填充槽：时间轴保存拒、世界书槽编辑会话只改名不改正文、底图不收它的存储正文。
- `testLibraryAndPromptPageEditTheSameInstanceAndSurviveReload` 改走 `commitSimpleDrafts`。

### 7.7 返工验证
- mac build-for-testing `** TEST BUILD SUCCEEDED **`；iOS（MemoryPalaceIOS）`** TEST BUILD SUCCEEDED **`（`SlotEditPage` 只在 iOS 编，这一遍覆盖到）。
- 25 套件 326 测全过：PromptFolderTests（17）/ SlotOrder / FileLibraryMemoryFolder / FileLibraryDisplay / CatalogWriter / CatalogRetrievalCancellation / PromptRealPathGolden / InspectorRealPath / PersonaRequestBody / CatalogSeed / ProtectedDataGate / CallController / FileLibraryListCache / FileLibraryHostFixes / CalendarPrivacy / MemoryTree / ToolResultOffload / ProfileCard / CCMemorySync / Timeline / ToolTucking / ToolHintGating / ToolDrawer / TurnStatusNote / WorldInfoSlot。两组金样未变、未 RECORD。
- 走查补充（交车头）：iPhone 进 Prompt 页插槽模式，点一个自建槽进编辑页，此时在文件库改它的正文，回编辑页只改名字保存 → 名字变、正文是文件库那版；再改正文保存 → 弹「这段在别处改过了…」不退出。时间轴 / 世界书槽进编辑页显示「此插槽由系统自动填充」。

## 8. sim 走查界面小修（返工 2）

走查截图 `scratchpad/p5-walk/`。只改 `FileLibraryPromptFolder.swift`、`FileLibraryPanelView.swift` 和测试；第 4 段在改的 WikiProposal* / Catalog* / WikiSuggestTool / ToolRegistry 没碰。

1. **卡片不显示标记**：`FileLibraryPromptFolder.display`（`:61-71`）把「未命名 / 已关闭 / 自动填充」同时放进 `chips`，卡片纸面上方显示成标签；列表视图照旧写在副标题。
2. **「楼层字段」显示条件与位置**：`merge`（`:24-33`）字段数为 0（含没有真文件）就不放这个文件夹，`index[".prompt/fields"]` 也置空；`foldersAfterFiles`（`:37`）让 Prompt 根先列插槽、再列文件夹——卡片 / 列表视图在 `FileLibraryPanelView.swift:598-609`，树视图在 `:1388-1392`。
3. **面包屑**：`FileLibraryPromptFolder.breadcrumb`（`:43-45`）用 `PromptFolder.displayName` 换名，`FileLibraryPanelView.swift:557` 改用它：「文件库 / Prompt / 楼层字段」。别的文件夹的面包屑不变（记忆树仍显示内部名，没顺手改）。
4. **隐藏新建与排序**：`FileLibraryPanelView.swift:641-642` `inPromptFolder`（只认 `.prompt` 和 `.prompt/fields` 两个虚拟目录）；排序菜单 `:646-666`、iOS 顶栏 ＋ `:995-1004`、mac「⋯」里的「新建文件…」`:1011` 在虚拟目录里不出。视图模式切换保留。真 `.prompt` 文件照样列、只读打开；真 `.prompt` 的子文件夹不算虚拟目录，那里仍有 ＋（写入会被物理层拒）。
5. **自动填充槽空白预览**：`readOnlyText`（`:48-50`）空的自动填充槽给「这一段发送时由系统自动填充。」，`FileLibraryPanelView.swift:275-278` 只读预览用它；有存储正文的照原样显示，可编辑的空槽不加说明。
6. **长按「复制路径」**：`fileItem`（`FileLibraryPanelView.swift:946-962`）是虚拟插槽 / 字段就不挂长按菜单和长按预览；真 `.prompt` 文件和其他文件照旧（「复制路径」保留）。

测试：`PromptFolderTests` 17 → 19 条——新增 `testFloorFieldsFolderOnlyWhenFilledAndAfterSlots`（没填字段不出文件夹、填了才出且计数对、只有 Prompt 根把文件夹排后面）、`testPromptFolderChromeUsesDisplayNamesAndHidesSortAndCreate`（面包屑名字和路径、虚拟目录判定、空自动填充槽说明 / 有字照显 / 可编辑空槽不加）；`testLibraryFolderSitsBesideMemoryAndKeepsSlotOrder` 加卡片标签断言。长按菜单是否挂上、按钮是否隐藏属视图层，没有单测，靠走查。

验证：mac build-for-testing `** TEST BUILD SUCCEEDED **`，iOS（MemoryPalaceIOS）`** TEST BUILD SUCCEEDED **`；9 套件 157 测全过（PromptFolderTests 19 / FileLibraryMemoryFolder / FileLibraryDisplay / FileLibraryHostFixes / FileLibraryListCache / CalendarPrivacy / SlotOrder / PromptRealPathGolden / InspectorRealPath），金样未变、未 RECORD。编译当时带着第 4 段的在改文件，没挂。

走查补充：卡片视图看「世界书 (前)」等槽有「自动填充」标签；彩蛋楼层（没填楼层字段）进 Prompt 不出「楼层字段」，卡建楼层里它在最后；面包屑「文件库 / Prompt」；Prompt 里右上只有「⋯」、工具行只有视图切换；点空的「🧠 记忆」看到那句说明；长按插槽没有菜单。

