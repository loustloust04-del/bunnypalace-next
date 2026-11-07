⚠️ DON'T IMPLEMENT YET

# plan · UI/UX 三波：统一编辑器 → 酒馆小修 → 设置/子应用入口

> 依据：`docs/research-ux-audit-api-onboarding.html`（10-14 两路审查，75 条）。API 后端那几波（#089 / #092 / #094 / #093 / thinking）归 cc-rp「API链路」，**本 plan 一行不碰**。
> 状态：**等粟粟批注，DON'T IMPLEMENT YET**。⧫ 批注写在对应条目下面。

## 0 · 撞车检查（10-14 晚，扫了全部 worktree 的已提交 + 未提交改动）

| 谁 | 动了什么 | 对本 plan 的影响 |
|---|---|---|
| backend-2 · #093 工具抽屉（做完待合） | `PersonaSettingsTab.swift` +138 行、`SettingsRoute` / `SettingsSearch` / `MacSettingsPage` / 新 `ToolDrawerPage` | **B（Prompt 页）和 C（设置入口）必须等 #093 合进 master 再开**，基于它改 |
| cc-rp API 线 · thinking 回传（刚派） | ChatService / provider / 检查器 | 不相交 |
| agent-ae1e… / release-tf / tmp-perfhunt | 9 月旧工位，0 未提交 | 死工位，忽略 |

→ **A（编辑器）现在就能开**，在 page2-apps 工位做；B、C 排在 #093 合并之后。

---

## A · 统一编辑器（现在开）

### A0 · 【P0】编辑器不能撤回 —— 先复现，再修
粟粟报：文件库编辑器不能撤回。代码里的两个嫌疑（**未实测**）：
1. **iPhone 上没有撤销入口**：`FileEditorKeyboardBar.swift` 里没有 undo / redo 按钮；CodeMirror 的 `basicSetup` 自带撤销历史，但只认 ⌘Z，iPhone 软键盘按不出来；WKWebView 的摇一摇/三指撤销也接不到 CodeMirror。
2. **Swift 回推内容污染撤销历史**：`markdown-editor.js:44-57` `setEditorContent` 把整篇替换当一次普通事务 dispatch，没有 `addToHistory.of(false)`。Swift 每次打字后都会回推 payload（`MarkdownWebEditorView.swift:53`），只要内容不一致（比如 revision 竞态），撤销栈里就多一步「整篇替换」→ 撤一下整篇跳回旧版本，或者撤不动。
3. 源码模式是裸 `TextEditor`（`FileLibraryPanelView.swift:2071`），mac 上 ⌘Z 应该能用，iOS 同样没有按钮。

做法：
- 先在 sim 上复现（Markdown 模式打几段 → 撤销；源码模式同样），把真正的原因写进复盘，再修。
- 浮条加「↶ 撤销 / ↷ 重做」两个按钮（Markdown 模式发命令给 CodeMirror 的 `undo` / `redo`；源码模式走 `UndoManager`）；mac 保证 ⌘Z / ⇧⌘Z 两种模式都通。
- 回推整篇替换加 `Transaction.addToHistory.of(false)`，并且内容相同就不 dispatch（现在已有 `===` 判断，查 revision 竞态那条路）。
- 切换「源码 ↔ Markdown」模式后撤销历史怎么办：推荐**各自保留**，切回去还能撤；做不到就至少不丢内容。

### A1 · 把 `FileEditorSheet` 变成「编辑一段文本」也能用
现状：`FileEditorSheet(path:initialContent:initialModifiedAt:currentModifiedAt:reloadExternalContent:onSave:onCancel:onOpenWikiLink:readOnly:)`，已被记忆画像（`MemoryProfileSheet.swift:121`）和话题盒（`TopicCardSheet.swift:91`）当「虚拟文件」复用过，所以路子是通的。
- 加一个便捷构造：`FileEditorSheet.text(title:, text:, mode: .markdown / .plain, onSave:)`——没有外部改动检测、没有 wiki 链接，保存就回调。
- `title` 显示在顶栏（现在显示的是 path，角色卡字段要显示「角色卡 · 描述」这种）。
- 纯文本字段（世界书关键词、正则）不走 Markdown 渲染，默认源码模式。

### A2 · 迁移：长文本一律「行内预览 + 点开全屏」
每个长文本字段在原位置只显示前 3–4 行预览 + 字数，点一下打开 A1 的编辑器。按顺序：

| # | 位置 | 现状 | 本次做 |
|---|---|---|---|
| 1 | 卡库「编辑卡」`CharacterCardEditor.swift:111-122` | TextEditor 塞 List 行、minHeight 60、嵌套滚动翻不动；**「性格」字段界面上没有** | 描述 / 性格 / 场景 / 开场白 / 示例对话 / 系统指令 全部改预览行；补上性格；标题从「编辑自定义助手模板」改成「编辑角色卡」 |
| 2 | 卡库世界书条目 `WorldBookEntryEditView.swift:146-148` | TextEditor minHeight 120 | 正文改预览行；关键词仍行内（短） |
| 3 | 旧世界书面板 `WorldBookPanelView.swift:1029` `WorldBookEntryEditor` | 另一套 | 同上（两套世界书界面合并归 B，这里只换编辑器） |
| 4 | 楼层编辑的系统提示词（TextEditor minHeight 120） | 内嵌 | 预览行 |
| 5 | `LiteSlotFullscreenEditor`（`LitePersonaPage.swift:159`） | 自己的全屏 | 换成 A1 |
| 6 | Prompt 页全屏编辑（`PersonaSettingsTab.swift:1514`）、`PromptEditorPage` | 自己的全屏 | **等 #093 合**再换（同文件） |

**不迁**（不是 md 长文）：`RegexScriptEditor` / `RegexRuleEditor`（正则）、`StyleEditorView`（CSS，可选用源码模式，本次不动）、`InputExpandSheet`（聊天输入框展开，属于发消息流程）。
<⧫>先不换</⧫> → 定：不换。

### A3 · 表单 sheet 防误关
所有带编辑的 sheet（卡编辑、世界书条目、楼层编辑、API 卡编辑除外——那个归 API 线）：有未保存改动时 `interactiveDismissDisabled`，下滑弹「放弃改动？」。

### A4 · 【新】编辑器「git 化」：版本历史 + diff（可选开关）
粟粟要：编辑器能选 git 化，看历史和 diff。

**关键取舍 —— 用真 git 还是 App 自己存快照：**

| | 真 git（libgit2 打包进 App） | 自建快照（推荐） |
|---|---|---|
| 能管什么 | 只能管**真文件**（文件库） | 文件库 **和** 角色卡字段 / 世界书条目 / 预设插槽这些「虚拟文件」都能管 |
| 自包含 | 要打包 libgit2（iOS 能编，包体 +2–3MB，维护成本高） | 纯 Swift，零依赖 |
| mac 上用命令行 `git log` | 能 | 不能（可加「导出成 git 仓库」） |
| diff 显示 | 一样要自己画 | 自己画（Swift `CollectionDifference` 按行算） |

**推荐自建快照**：A1 之后角色卡、世界书都走同一个编辑器，历史也应该跟编辑器走，真 git 管不到它们。
<⧫>真git吧反正咱都有ish了（）但是如果太麻烦就快照</⧫> → 查完了，**太麻烦，按你的兜底走快照**。理由（带证据）：
  - iOS 的 iSH rootfs（Alpine 3.21 aarch64，6 个包）**没有 git**，离线装不上；guest 出网没验证通过，`apk add` 还会假装成功（`docs/research-离线沙箱.md:168`）。要用就得把 git 打进 rootfs 重发（体积 +，`RootfsManager.swift:49-55`）。
  - **mac 没有 iSH**，只能调本机 `/usr/bin/git`；没装命令行工具的机器上它会弹系统安装框。两端得写两套。
  - App 切后台 iSH 命令原地冻结（`ISHShellBackend.swift:9-11`）；iCloud 楼层不挂进 guest（`SandboxMount.swift:173-176`）；guest 里跑 git status/diff 估计秒级。
  - `.git` 放在楼层 `filesystem/` 下会出现在文件列表和 Files.app 里。
  - 角色卡 / 世界书 / 预设在 BlobStore 大 JSON 里，进 git 还得先做一条一文件的镜像和双向同步。
  → 定：**App 自存快照**，两端一套 Swift；以后要的话 mac 加「导出成 git 仓库」。

自建快照的做法：
- 开关：文件库按**文件夹**开「记录版本」（文件夹外观 sheet 里加一行）；角色卡 / 世界书 / 预设默认开（数据小）。
- 存：每次保存记一版（全文 + 时间 + 来源「手动保存 / 自动保存 / 外部改动」），内容相同不记；每个文件最多 100 版，超过删最老（⧫ 上限要不要改）。存在 App Support 下 `versions/<profileId>/<文件 key>/`，**不进 iCloud、不进全局备份**（⧫ 要不要进备份？）。
- 看：编辑器「…」菜单 →「版本历史」：列表（时间 + 增删行数），点一版看**和当前的 diff**（增绿删红，行级；mac 左右并排，iPhone 上下统一视图），可「恢复到这版」（恢复本身也记一版，所以恢复可以再撤）。
- 和 A0 的关系：撤销管「这次打开之内」，版本历史管「跨次保存」。

---

## B · 酒馆小修（**等 #093 合进 master 再开**；Prompt 页和卡库只小修，不大改）

| # | 问题（审查出处） | 做法 |
|---|---|---|
| B1 | 【P0】卡库改卡不同步楼层，卡主页还显示新文字像生效了（`CharacterHomeView.swift:117-121,170`、`CharacterCard.swift:401-411`） | 保存卡时，如果有楼层绑着这张卡：弹「同步到 N 个楼层？」默认是。同步写 profile 的描述 / 场景 / 示例 / 性格 + 楼层预设实例里的 main / jailbreak 槽（只覆盖**导卡时原样拷过去、之后没被改过**的槽，改过的跳过并提示）。灰着的「应用到这个楼层」做实。<⧫>按你推荐</⧫> → 定：保存时问同步。 |
| B2 | 【P1】Prompt 页看不到卡、在「助手设定」打字会顶掉整段卡描述（`PersonaSettingsTab.swift:100-106`、`PromptAssembler.swift:683-710`） | 顶部加一行「正在编辑：<楼层名> · 角色卡 <X>」，点卡名跳卡库；槽位为空时把卡的字段灰色显示出来，旁边写「在这里写会替换卡描述」 |
| B3 | 卡库世界书默认显示「全部」 | 默认「本楼层在用」，下面一个「全部世界书」入口 |
| B4 | 卡库底部 tab 栏随上下滑收起 | 固定不收 |
| B5 | 开场白只有卡主页「＋ 新聊天」才带，引导里「开始对话」不带 | 统一：从卡建的楼层，任何入口开新对话都带开场白 |
| B6 | 卡楼层把 {{user}} 硬编码成「你」 | 用引导里填的用户名（楼层没填就用全局的） |
| B7 | 【推断】引导里导卡会切楼层、ContentView 按 `.id(profile.id)` 整树重建、引导被重置回欢迎页 | 先上 sim 复现；真的就让引导在楼层切换后继续 |
| B8 | 世界书 4 个入口 2 套界面 | 旧 `WorldBookPanelView` 的入口指向卡库世界书，旧界面保留代码不删（本波只改入口） |

## C · 设置 / 子应用入口重排（**等 #093 合**，B 之后；纯挪入口，不改功能）

原则（10-14 我说的那套，你没反对就照这个）：
1. **设置只放全局**：通用、权限、数据、外观、API 与模型、Prompt 组装、记忆、用量、AI 连接与拓展、编程工具、关于。
2. **内容进子应用**：设置里的「世界书」「正则」tab 撤掉入口，改成卡库里的页（设置搜索仍能搜到，跳到卡库对应页）。
3. **子应用设置只有一个真身，在子应用里（右上角齿轮）**；设置 →「子应用」变目录页，列出每个子应用，点进去打开同一个页面。「模块」折叠组（贴纸 / 健康 / 日历 / 交易 / 书房 / 单词 / 群聊）并进「子应用」。
4. **统一叫法**：「API」（pro）和「模型（API）」（lite）→ 都叫「**模型和API**」<⧫>就叫模型和API吧</⧫>；「Prompt」（pro）/「AI 性格」（lite）不动——是同一份数据的完整版和简化版两个不同页面（`SettingsView.swift:226`），名字不同说得通；「系统指令」三个入口留一个。
5. 设置搜索补关键词（收藏、温度、世界书、角色卡、版本历史）。

---

## 执行方式
- **A 现在开**，page2-apps 工位（已占）。按「车头不改代码」：我写任务书派子 agent 实现，我验收。A0 → A1 → A2(1-5) → A3 → A4 依次，每项一个 commit。
- **B、C**：#093 合进 master 后，本工位 merge master 再开；B 在 page2-apps，C 涉及设置根目录，在 page0 工位另开 session 或本工位顺序做（⧫ 你定，默认本工位顺序做，避免两处同时动设置）。
- 编译：工位暂停本地编译（10 月规矩），只跑定向测试；双端编译交集成区。UI 验收装 sim。
- 每波做完写 `docs/review-<波>.md`，合并走 merge-queue。

## 不做
- API 设置页本身（API 线管）。波次 1 留下的 6 条 API 界面尾巴（胶囊显示卡 emoji、当前模型不在收藏时置顶、预设过期模型清单、额外请求头、引导 Anthropic 中转、API 表单草稿持久化）我会转告 API 线，不在这里做。
- 卡库 / Prompt 页大改版、两套世界书界面代码合并。

## Todo
### A（现在）
- [x] A0-1 sim 复现撤回问题，记录真因 ✅（工位禁装包，改用无头 Chrome harness 跑真 js/bundle + 桩 Swift 回推；真因：打开时首推全文进了撤销历史→撤到底清空文件；revision 只在内容变时更新→外部重新载入被丢）
- [x] A0-2 浮条加撤销 / 重做（两种模式）；mac ⌘Z / ⇧⌘Z 通 ✅（宽屏格式条也加；源码模式 mac 单测过）
- [x] A0-3 回推整篇替换不进撤销历史；查 revision 竞态 ✅
- [x] A0-4 模式切换后撤销不丢内容 ✅（实时编辑器常驻不拆，历史保留；源码模式历史切走即丢）
- [x] A1 `FileEditorSheet.text(...)` 便捷构造 + 顶栏标题 ✅（画像 / 话题盒是真文件、要外部改动检测，原样保留）
- [x] A2-1 角色卡编辑器全字段预览行 + 补性格 + 改标题 ✅
- [x] A2-2 卡库世界书条目 ✅
- [x] A2-3 旧世界书面板条目 ✅
- [x] A2-4 楼层编辑系统提示词 ✅
- [x] A2-5 Lite 插槽全屏 ✅
- [x] A3 编辑类 sheet 防误关 ✅
- [x] A4-1 快照存储 + 开关 ✅（FileVersionStore + LineDiff + 单测；开关是 UI，随 A4-2 接）
- [x] A4-2 版本历史列表 + diff 视图 + 恢复 ✅
- [ ] A 复盘 review-uiux-editor.md
### B（#093 合后）
- [x] B1 改卡同步楼层 ／ 「应用到这个楼层」做实 ✅
- [x] B2 Prompt 页「正在编辑」条 + 空槽灰显卡字段 ✅
- [x] B3 卡库世界书默认本楼层 ✅
- [x] B4 卡库 tab 栏不收起 ✅
- [x] B5 开场白统一 ✅
- [x] B6 {{user}} 用用户名 ✅
- [x] B7 引导导卡重置（先复现）✅（静态确认会丢，进度挪到进程内单例；待 sim 验）
- [x] B8 旧世界书入口改指向 ✅
- [ ] B 复盘
### C（B 后）
- [x] C1 设置根目录按全局 / 内容分 ✅
- [x] C2 世界书 / 正则入口迁到卡库 ✅
- [x] C3 子应用设置归位 + 「模块」并进「子应用」 ✅
- [x] C4 统一叫法 ✅
- [x] C5 设置搜索关键词 ✅
- [ ] C 复盘

---

## D · 新手尾巴（粟粟 10-15「好」；编辑器修整那批交了再开）

API 侧尾巴（表单草稿保活、报错「去改」、胶囊卡 emoji、过期清单、额外请求头、引导 Anthropic 中转、Azure query 地址）10-15 已转 API 线（backend-001），本 plan 不做。

| # | 问题（审查出处） | 做法 |
|---|---|---|
| D1 | 不知道去哪导入角色卡（新用户 阶段 5「入口盘点」） | 卡库卡墙空态和顶栏加明显的「导入角色卡」；page0 / 设置搜索「导入」「角色卡」「酒馆」都能直达导入；引导完成页指路改对 |
| D2 | 引导填的「Ta 叫什么」「怎么称呼你」之后在 Prompt 页找不到，名字只写进当前楼层（阶段 1） | Prompt 页 / AI 性格页「正在编辑」行下显示并可改 AI 名、用户称呼（就是楼层 assistantName / userName）；（引导侧写全局默认的部分并进新引导）|
| ~~D3~~ | ~~引导不预填「小芽」~~ | **撤**：粟粟 10-15 引导整个重做成和小芽对话（`docs/plan-onboarding-xiaoya.md`），旧引导不再修，问题并进新引导的要求 |
| ~~D4~~ | ~~导卡摘要弹窗不丢~~ | **撤**：同上 |

### Todo
- [ ] D1 导入角色卡入口
- [ ] D2 AI 名 / 用户称呼在 Prompt 页可见可改
- [ ] D 复盘
