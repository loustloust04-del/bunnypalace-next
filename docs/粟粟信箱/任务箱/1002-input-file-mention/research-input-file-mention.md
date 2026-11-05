# research：page1 输入框 @ 文件 + 附件面板「最近文件」

> 10-02 · 研究 + 小样（[design-input-file-mention.html](design-input-file-mention.html)），未动 .swift。基于 master `758123814`。
> 路径前缀省略 `MemoryPalace/`。

粟粟原话两件事：
- **A** 输入框打 `@嗷` → 弹文件库里名字匹配的文件（`嗷呜嗷呜.md`），选中就当附件发给 AI。
- **B** 点发送文件不再直接弹系统文件单：学「最近照片」在底部弹一条横滑「最近文件」，外加「文件库」「手机里的文件」两个入口。

---

## 1. 输入框和「＋」面板现在长什么样

| 东西 | 位置 | 说明 |
|---|---|---|
| 日常聊天输入条 | `Views/CardFlowView.swift:1344` `ChatInputBar` | 两端共用：iOS 由 `Views/InputBarStack.swift:76` 挂，mac 由 `Views/Chat/MacChatComposerHost.swift:26` 挂 |
| 文字框容器 | `Views/CardFlowView.swift:2356` `InputFieldContainer` | `VStack { 斜杠浮板?; fieldBox }`，iOS 玻璃 `shellGlass(.rect(cornerRadius: 20), tint: 0.15)`；mac 是 `mainBg` 圆角 11 + hairline（`:2486-2492`）|
| 附件条 | `Views/CardFlowView.swift:1556` `AttachmentChipRow`（定义 `:1952`）| 引用 + 附件 + 排队消息同一横排，✕ 删除；文件 chip 点开预览 |
| 「＋」面板 | `Views/StickerKeyboardPanel.swift`（挂载 `CardFlowView.swift:1143`）| 工具栏胶囊（键盘 / 相册 / 📎 / 贴纸 / 便笺 / 待办 / 骰子 / 计时 / 画板 / 风格）+ 下方内容区 |
| 最近照片横条 | `Views/PhotoStripPanel.swift`（iOS only，挂 `StickerKeyboardPanel.swift:228`）| 80pt 方格（`:15`）、圆角 10，前面「拍照」「全部照片」两颗；多选描边 2.5 + `checkmark.circle.fill`（`:150-161`）；工具栏出「附加 N 张」胶囊（`StickerKeyboardPanel.swift:107-127`）→ `triggerAttach` → `attachSelected()` 转 JPEG 进 `selectedAttachments` |

**现在的「文件」路径**：📎 `StickerKeyboardPanel.swift:82` → `.fileImporter(allowedContentTypes: [.data], 多选)`（`:288-293`）→ `handleAttachmentImport`（`:304`）→ `AttachmentTextExtractor.extract(from:)` → `selectedAttachments.append`。mac 另有拖放走同一函数（`CardFlowView.swift:1182 acceptFileDrop`，`:824/:960 onDrop`）。

## 2. 文件附件发给模型的形态

- 模型：`Models/ChatAttachment.swift:23 PendingChatAttachment`，kind = text / image / card；非图带 `fileData` 原始字节。
- 抽取：`Services/AttachmentTextExtractor.swift:37 extract(from:)`
  - 上限 `maxFileBytes = 25MB`（`:26`），图片另限 8MB（`ChatAttachment.swift:24`）。
  - 图片 → `.image`（字节进视觉通道）；pdf → PDFKit 抽文字；文本 / 代码 / json → 读文字；zip/xlsx 等 → 空文字 + 原始字节。抽出文字截 `maxExtractedCharacters = 60_000`（`:27`）。
- 拼进消息：`ChatAttachmentPromptBuilder.modelInput`（`ChatAttachment.swift:108`）——非 CC 模型看到的是正文后面的
  ```
  [附件：嗷呜嗷呜.md · Markdown 文稿]
  …正文…
  [/附件]
  ```
  图片是 `[图片附件：名 · 类型]` 占位 + 图像块。`segments(...)`（`:154`）把文件存成 `.fileData`（CC 收真文件）。发送入口 `ViewModels/ConversationViewModel.swift:2602`。
- **结论**：文件库文件只要拿到绝对 URL（`FileLibraryStore.absoluteURL`，`Services/FileLibraryStore.swift:890`），直接喂 `AttachmentTextExtractor.extract(from:)` 就和「手机里的文件」完全同形，**发送链一行不用改**。

## 3. 现有补全浮层 / @ 的语义

| 现有 | 位置 | 能不能复用 |
|---|---|---|
| CC 斜杠命令浮板 | `Views/CCSlashCommandSuggestions.swift:36`；挂在 `InputFieldContainer` 文字框正上方 `CardFlowView.swift:2474-2483`，`showSlashSuggestions = isCCBridge && text.hasPrefix("/")`（`:2455`）| **复用挂载位**：同一个 `VStack` 里加 `if let q = mentionQuery { FileMentionSuggestions(...) }`，iOS / mac 自动都有。视图本身是 CC 荧光绿风格，样子不复用 |
| 群聊 @ 成员 | `Views/GroupRoom/AgoraRoomViewController.swift:179 mentionPrefix`（正则 `(?:^\|\s)@([A-Za-z0-9_.-]*)$`，只看全文末尾、只认 ASCII）；UI 是 UIKit 横向小卡片 `GroupRoomComposerView.swift:276` | 只借思路（「末尾 @token」判定），正则要放开中文；UI 不同栈不复用 |

- 日常聊天里 **`@` 目前没有任何语义**（`CardFlowView.swift`、`ChatInputTextView.swift`、发送路径均无 `@` 处理），不冲突。
- 留神：CC 自己认 `@path` 语法。选中候选后把 `@嗷` 这段**从文字里删掉、换成附件 chip**，文字里不留 `@`，CC 收的是 `.fileData` 真文件，不撞。
- **iOS 输入框提交节流是坑**：`Views/ChatInputTextView.swift:525-535` 文字回写 binding 是去抖 + 「提交点」制（斜杠有专门的 `slash` / `slashLive` 提交点）。`@` 不加提交点，`text` 绑定会晚到，候选跟不上手。实现时照 `slashLive` 加「末尾是 @token 时每键提交」；组字（拼音 marked text）期间不提交，所以 `@嗷` 在拼音上屏后才出候选——这正好（拼音中间态 `@ao` 不该匹配）。
- 只认**文字末尾**的 @token（同群聊）。光标在中间打 @ 不出候选——v1 可接受，要支持得把 `selectedRange` 透出来，改动面大一档。

## 4. 文件库数据怎么拿、怎么匹配

- 列表：`FileLibraryStore.list(profileId:skippingTopLevelDirs:)`（`Services/FileLibraryStore.swift:230`）返回 `FileMeta(path, bytes, modifiedAt)`，楼层目录 `libraryRoot`（`:107`）。**同步枚举整库**，带 books 时主线程 546ms（注释 `:228`）→ 候选必须后台取 + 缓存（输入框首次出现 `@` / 面板打开时预取一次，`skippingTopLevelDirs: ["books"]`）。
- 可见性：`FileLibraryAccess.visible(path, profileId:)`（`Services/Calendar/CalendarPrivacy.swift:33`），journal 闸关时过滤，和 system prompt 文件清单同口径（`ConversationViewModel.swift:3077`）。
- 显示：`FileLibraryDisplay.fileName / parentFolder / badge / timeText`（`Views/FileLibrary/FileLibraryDisplay.swift:24/28/34/283`）；小方块 `FileLibraryTile.file(path, profileId:, side:)`（`Views/FileLibrary/FileLibraryRows.swift:98`），图片自动走 `FileThumbnailView`（`Views/FileLibraryPanelView.swift:2217`，带 NSCache）。**B 的横条直接用这个 tile，side 放到 80**。
- page0 全局搜索的文件搜：`SearchService.searchFiles(keyword:profileId:)`（`Services/SearchService.swift:1168`）= 路径 + 开头 4KB 子串（`MacSearchQuery.contains`）；`keyword == nil` 时给「最近改过的 12 个」——**B 的「最近文件」数据源直接用这个 nil 分支**（后台、已排序）。但 @ 不该匹配正文（`@嗷` 会命中正文含「嗷」的一堆文件），**@ 只匹配文件名 / 文件夹名**，单写一个纯函数。
- 匹配规则建议（纯函数，好写单测）：
  1. 文件名（去扩展名）**前缀** > 文件名**子串** > 文件夹名子串；同档按修改时间新→旧；最多 5 条。
  2. 大小写 / 全半角不敏感（`localizedStandardContains` / `folding`）。
  3. 拼音首字母可选：`applyingTransform(.toLatin)` 已在 `Models/Page2LibraryNameKey.swift:9` 用过，可做 `@aw` → 嗷呜。但中文输入法下打 `@aw` 会先组字，实用价值低，建议 v1 不做（拍板 Q3）。
  - `@嗷` → `嗷呜嗷呜.md`：前缀命中，第一条。✅

## 5. 文件库文件发给 AI 的形态

- **推荐：当本地文件附件**——`absoluteURL` → `AttachmentTextExtractor.extract(from:)` → `selectedAttachments.append`。和📎同形：附件条出 chip，模型收到 `[附件：…]` 全文（≤6 万字），图片走视觉，CC 收真文件，消息里存 `.fileData` 能回看能编辑重发。
- 备选「只引用路径」（文字里留 `@notes/嗷呜嗷呜.md`，让模型 `fs_read` 拉）：省 token，但模型不一定读，工具关掉的楼层 / 不支持工具的 provider 直接失效，也和「发这个文件给 ai」不符。不推荐做 v1。
- 注意：附件是**发送那一刻的快照**，之后文件库里改了文件，旧消息里的附件不变（和📎同语义）。
- iCloud：文件库开 iCloud（`:28-97`，默认关）后，未下载的文件在磁盘上是 `.xxx.md.icloud` 占位，**`isSupportedFile`（`:896`）按扩展名过滤会把它们漏掉**——候选里不出现，不会选到读不了的文件；代价是云端还没下的文件 @ 不到。要覆盖就照 `Services/BookStore.swift:375-392` 的 `startDownloadingUbiquitousItem`：列出占位（灰一档 + 云标），选中触发下载、chip 显示「下载中」，下完再抽取。建议 v1 不做。

## 6. mac

- mac 和 iOS 共用 `ChatInputBar → InputFieldContainer`，**A 的候选浮层挂同一处，两端都有**。mac 额外：↑↓ 选、Return / Tab 确认、Esc 关（现在 Return = 发送，候选打开时要截走），要在 mac 输入框按键分流处加。
- mac 「＋」面板也是 `StickerKeyboardPanel`，但没有 `PhotoStripPanel`（相册走系统 PhotosPicker，`:74-80`）。B 在 mac：📎 点开同一块「最近文件」横条（mac 面板本来就顶替输入条，放得下）+「文件库…」「电脑上的文件…」；拖放进输入框照旧。
- 「文件库…」：v1 做一个**轻量选择 sheet**（搜索框 + 列表 + 多选，数据同 `list()`），两端共用，不改 `FileLibraryPanelView` 本身（它是 page2 工位的热点文件）。

## 7. 影响面 / 冲突

要动：`CardFlowView.swift`（`InputFieldContainer` 挂浮层 + 选中回调，`AttachmentChipRow` 不用改）、`ChatInputTextView.swift`（加 @ 提交点）、`StickerKeyboardPanel.swift`（📎 改为切「文件条」不再直接弹 fileImporter）；新增 `FileMentionSuggestions.swift` / `FileStripPanel.swift` / `FileLibraryPickerSheet.swift` + 匹配纯函数 + 单测。发送链（`ChatAttachment.swift` / `AttachmentTextExtractor.swift` / VM）不动。

| 工位 | 动 CardFlowView 的位置 | 和本需求冲突 |
|---|---|---|
| NOW.md 文件锁 | `CardFlowView.swift` / `ContentView.swift` / `PagingViewController.swift` 已标锁（perf-flash）| ⚠️ 合前同步 master |
| zone/page1 | 无源码改动（只有 docs）| 无 |
| zone/page1-2（聊天列表性能，交合并中）| `CardFlowView` :490-561、:787-791（主体）、:3590-3691（BubbleView）；`ChatInputTextView` 未动 | 低：不在 ChatInputBar / InputFieldContainer 段 |
| zone/page1-3（ask 卡）| 只动 `Views/Cards/` | 无 |
| zone/page1-4（时间分隔 / 长按菜单）| `CardFlowView` :440、:771-774、:3484-3565 | 低 |
| zone/page1-5（长按浮层）| `CardFlowView` :4018-4078（FolderPickerSheet）| 无 |
| zone/page2-apps-2（文件库编辑器）| 改 `FileLibraryPanelView.swift`（未提交）| B 若复用文件库面板选择模式会撞；用独立选择 sheet 则无 |

结论：同文件不同段，git 能自动合；输入框段（:1344-2750）、`StickerKeyboardPanel` / `PhotoStripPanel` / `ChatInputTextView` 当前没有别的工位在改。UIKit 新聊天页 P1a 已暂停（`docs/now/page1-2.md`），输入框不会被重写掉。
