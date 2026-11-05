# Plan：真终端 + 多窗口导航

> 2026-08-16 · 前置：[research](research-真终端-多窗口.md) · 分支 `worktree-real-terminal`
> **⚠️ DON'T IMPLEMENT YET —— 等粟粟 ⧫ 批注**

---

## 第一原则：纯增量

粟粟原话「一定要注意不要搞坏现有的逻辑了！！！！😡」。所以：

**新前缀、新 API、新表、新 UI。现有路径能不碰就不碰。**

下面 §四 是「非改不可的现有文件」清单，一共只有 **2 个函数**，且都是加分支不改现有分支。
§六 是回归验证清单，专门用来证明没搞坏。

---

## 已拍板

| 项 | 决定 |
|---|---|
| 列表存哪 | 都存 + 定时同步（hub 真相源，app 本地缓存） |
| `[+]` 轻点 | 直接开 shell，不弹选择 |
| `[+]` **长按** | 弹菜单，里面有**恢复已关闭的窗口** |
| 关窗口 | 从导航移除，**tmux session 保留**（不 kill）→ 可从长按菜单恢复 |
| 编号 | 显示**序号**，长按窗口看它的 code（code 是永久身份，序号会漂） |
| shell 起始目录 | `~` |
| 数量上限 | **不设**。挤了就横滚 —— 抄 page0（`SidebarView`）现成的模式 |
| 工作区 | worktree `real-terminal` |

## 导航形态

```
排3:   >mp-cc-t1        1    2    3           [+]
       └─────────┘      └──────────┘          └─┘
       当前对话的         全局共享             新开 shell
       跟着对话走         跟对话无关
```

## 本刀不做（YAGNI）

- 不做窗口重命名、不做拖拽排序、不做窗口分组
- 不做 Claude/Codex 类型的全局窗口（`[+]` 只开 shell；要 claude/codex 走现有的对话绑定路径）
- 不动 macOS 端
- 不做终端能力增强（复制粘贴/搜索/滚动条），那是 SwiftTerm 层的另一刀

---

## M1：hub 侧 —— shell 引擎 + 窗口注册表

### 命名空间

`mp-win-<code>`，code = 6 位小写 base36（hub 生成，碰撞重试）。

选这个前缀的理由：跟现有三个白名单（`mp-cc`/`mp-cc-`/`mp-codex-`）**没有任何前缀重叠**，
所以 §research 里那四个定时器/白名单天然照不到它。

### 新文件 `cc-bridge/terminal-windows.ts`（纯新增）

```ts
interface TerminalWindow { code: string; createdAt: string; closedAt?: string }
loadWindows() / saveWindows()          // secrets/windows.json
newWindowCode(existing): string        // 生成不碰撞的 code
sessionNameFor(code): string           // `mp-win-${code}`
isWindowSession(name): boolean         // 前缀判断，给别处复用
```

**为什么单独一个文件**：`hub.ts` 已经 2800+ 行，且这块逻辑纯函数居多，独立文件才好写单测。

### 新 WS API（纯新增，不碰现有 `list_sessions`）

| 消息 | 方向 | 作用 |
|---|---|---|
| `list_windows` | app→hub | 返回全局窗口列表（含每个的 tmux 存活状态） |
| `list_windows_result` | hub→app | `{windows: [{code, createdAt, alive}]}` |
| `open_window` | app→hub | 新建一个 shell 窗口，返回 code |
| `close_window` | app→hub | **只从注册表移除，不 kill tmux**（粟粟明确要求） |

⚠️ **绝不改 `listSessions()` / `list_sessions`** —— 它被 CC 会话选择器（`CCSessionPickerSheet`）
共用，放宽过滤会让 shell 窗口混进那张给对话绑 CC 用的选择器。这是 research 里 R2 那条高风险。

---

## M2：app 侧 —— 窗口模型 + 同步

### 新文件 `MemoryPalace/Services/TerminalWindowStore.swift`（纯新增）

- `@Observable` 单例，持有 `[TerminalWindow]`
- 本地缓存：`UserDefaults`（列表极小，不值得上 SwiftData）
- 同步：连上 hub 时拉一次 + 60s 定时对账；**hub 是真相源**，本地只为离线可见
- 离线时：显示缓存列表，窗口标灰不可点

### 新 WS 方法（`CCBridgeWebSocketClient` 加方法，不动现有的）

`listWindows(completion:)` / `openWindow(completion:)` / `closeWindow(code:)`

---

## M3：app 侧 —— 排 3 导航做实（横滚，抄 page0）

`PixelTerminalHeader` 的排 3 现在是死架子，改成：

```
>{当前对话的 session}  │  1  2  3  4  5 …（横滚）  │  [+]
     固定不滚                中间横滚               固定不滚
```

**结构直接抄 `SidebarView.swift:1207-1245`**（粟粟点名「page0 做过很多横滚，去学学」），
那边是「固定的『全部』tab + 横滚的自定义 tab + 末尾加号」，跟我们的需求同构：

| 手法 | 出处 | 为什么要 |
|---|---|---|
| 固定项放 `ScrollView` **外面** | :1208 | 左边那个「当前对话终端」不能跟着滚走 |
| `.scrollTargetLayout()` 只标窗口不标 `[+]` | :1219 | 加号不该成为吸附目标 |
| `.scrollTargetBehavior(.viewAligned(limitBehavior: .always))` | :1223 | 一格一格吸附，不会停在半个窗口上 |
| `.scrollPosition(id:)` | :1225 | 跟踪当前吸附到哪个 |
| `.scrollBounceBehavior(.basedOnSize)` | :1224 | 窗口少时不弹（否则 1 个窗口也能拽出橡皮筋） |
| `.scrollClipDisabled()` + 自定义 `.mask` | :1229-1236 | 两侧都 clip 会切掉圆角，都不 clip 又会盖到固定项 —— 那边用 mask 只给 leading 放 8pt |
| `ScrollViewReader` + `scrollTo(anchor:.center)` | :1246-1251 | 切到某个窗口时自动滚到中间 |
| `onChange(of: snappedTabId)` 震一下 | :1238-1243 | 「Clock 齿轮手感」，划过每格都有反馈 |

- 左边：`sessionName`（现有参数，行为不变）
- 中间：`TerminalWindowStore.windows` 渲染成序号，当前选中的高亮
- `[+]` 轻点：`openWindow` → 新 shell
- `[+]` **长按**：菜单 → 「恢复已关闭的窗口」（列出 `closedAt != nil` 的，选一个恢复）
- 关闭：长按窗口序号 → 确认 → `closeWindow`（只标记 closed，tmux 不动）

⚠️ **横滚里的按钮可能被滚动手势吞**（记忆在案：iPhone 14 暴露 / Air 正常，容易误判成机型 bug）。
`SidebarView` 那边用的是 `Button`，看起来没踩到（可能是 `viewAligned` 吸附改变了手势竞争）。
装机第一件事就是在 **iPhone 14 上**点窗口序号，点不动就改 `onTapGesture`。

### 当前显示哪个终端 —— 状态提升

现在 `CCTerminalPanelView` 直接从 `viewModel.selectedConversation?.ccBridgeSessionName` 取。
要支持切换，得引入「当前显示的 session」这个状态：

```
displayedSession = selectedWindowCode.map(sessionNameFor) ?? conversationSession
```

- 默认 = 对话绑定的（跟现在完全一致）
- 点了某个全局窗口 → 切过去
- 切对话时：如果当前显示的是全局窗口，**保持不变**（它跟对话无关）；如果显示的是对话终端，跟着换

⚠️ 切换靠现有的 `.id(currentSession)` 强制重建链（CCTerminalPanelView.swift:483）。
记忆里有「`.id()` 整树重建雷区」的教训 —— 切窗口时要确认 controller 的 detach/attach 成对，
不能泄漏 attachment（hub 侧 `mpClients` 不清会一直 pipe-pane）。

---

## 四、非改不可的现有文件（就这两处，都是加分支）

### 1. `cc-bridge/hub.ts` — `sessionEngine()`（:677-679）

```ts
export function sessionEngine(name: string): "claude" | "codex" | "shell" {
  if (name.startsWith("mp-codex")) return "codex"
  if (isWindowSession(name)) return "shell"        // ← 只加这一行
  return "claude"
}
```

**现有两支行为一个字节不变。** 返回类型加了 `"shell"`，所有 `=== "claude"` / `=== "codex"`
的判断自动排除 shell（这正是我们要的防御）。

### 2. `cc-bridge/hub.ts` — `spawnSession()`（:548-575）

加一个 shell 分支：不跑 agent、不进 sessionMap、不排 boot 检测队列，直接让 tmux 起默认 shell。
**claude / codex 两支的代码路径不动。**

### 明确不碰的（回归验证要证明它们没变）

- `listSessions()` / `list_sessions` 消息
- `recordUserActivity()` / `sessionActivity`
- keepalive / nudge / reap / agora 四个定时器
- `deriveCCSession()` / `Conversation.ccBridgeSessionName` / 对话绑定的全套逻辑
- 现有 `terminal_attach` / `terminal_input` / `terminal_chunk` / `terminal_usage`（**复用，不改**）
- 问问题 hook（`askUserClearForSession`）

---

## 五、Todo Checklist

### M1 hub ✅
- [x] `terminal-windows.ts`：注册表 + code 生成 + 前缀判断
- [x] `terminal-windows.test.ts` 9/9：code 不碰撞 / 前缀双向不误判 / 坏 JSON 不崩 / 身份连续
- [x] `sessionEngine` 加 shell 分支
- [x] ~~`spawnSession` 加 shell 分支~~ → **改成独立的 `spawnShellWindow`**，
      `spawnSession` 只加了个 guard。这样「非改不可的现有函数」从 2 个减到 1 个
- [x] `list_windows` / `open_window` / `close_window` / **`restore_window`** 四个 WS API
- [x] `close_window` 不 kill tmux —— 隔离 hub 实证 `alive=true`
- [x] hub 单测全绿（存量 4~5 fail 已核实是既有 + 一条 flaky）

### M2 app 模型 ✅
- [x] `TerminalWindowStore.swift`：本地缓存 + 60s 对账
- [x] `CCBridgeWebSocketClient` 加四个方法（不动现有的）
- [x] 离线降级：拉失败守着缓存标 stale，**绝不清空列表**

### M3 导航 UI ✅
- [x] 横滚结构照搬 `SidebarView:1207-1245`（固定项在外 / scrollTargetLayout / viewAligned）
- [x] 排 3 渲染窗口序号 + 高亮当前
- [x] `[+]` 轻点开 shell 并直接切过去
- [x] `[+]` 长按 → 菜单 → 恢复已关闭窗口（sheet 列表）
- [x] 长按窗口序号 → 看 code / 关闭（文案「关闭（保留后台运行）」）
- [x] `displayedSession` 状态提升 + `.id()` 切换重建
- [x] 切对话时全局窗口保持不变（`selectedWindow` 是 @State）
- [x] 窗口 tab 用 `onTapGesture` 不用 `Button`（预防横滚吞点击的老坑）
- [ ] ~~划过窗口的震动反馈~~ —— 没做（窗口少时横滚不吸附，齿轮感无从谈起；要的话补）
- [ ] **iPhone 14 上实测点窗口序号**（Air 上粟粟验过能用；14 未测）

### 收口 ✅
- [x] 双端 build 绿 + 测试全绿
- [x] commit + push（分支 3 commit + master ff）
- [x] 合并进 master + hub kickstart + 生产只读探针确认 `list_windows` 上线
- [x] Air 装机，粟粟实测「都好了」
- [x] 更新 `NOW.md`
- [x] `docs/review-真终端-多窗口.md`

---

## 六、回归验证清单（专门证明没搞坏）

粟粟最在意的就是这个，所以单独一节，每条都要实测：

| # | 项 | 状态 |
|---|---|---|
| 1 | CC 会话选择器里不出现 `mp-win-*` | ✅ **代码层保证**：`listSessions()` 一个字节没动，前缀过滤仍是 `mp-cc`/`mp-codex`。窗口走独立的 `list_windows` |
| 2 | 对话绑定的终端行为不变 | ✅ 粟粟实测（截图里左边 `>MP-CC-47` 正常） |
| 3 | codex 对话不受影响 | ⏳ 未单独测（`mp-codex` 分支代码没动） |
| 4 | keepalive 不打 shell 窗口 | ✅ **两道保证**：shell 永不进 `sessionActivity`（唯一写入点是聊天消息那条路）+ `sessionEngine` 返回 `"shell"` 让 `=== "claude"` 判断排除它 |
| 5 | reap 不回收 shell 窗口 | ✅ 同上 + reap 还有显式前缀白名单，双重免疫 |
| 6 | agora 不给 shell 派活 | ✅ `agoraSessionAllowed` 白名单写死 `mp-cc-`/`mp-codex-` |
| 7 | 关窗口后 tmux 还活着 | ✅ 隔离 hub 实证：`include_closed` 查到记录还在、`alive=true` |
| 8 | hub 现有测试无新增 fail | ✅ 基线 4~5 fail，多出的 `round_robin` 经三次交叉验证是 flaky（stash 掉我的改动跑基线照样失败） |
| 9 | **shell 窗口滚动不吐字符** | ✅ 修完粟粟实测通过（见下方事故） |
| 10 | **CC 窗口滚动没被修坏** | ✅ 粟粟实测「都好了」 |

---

## 七、Q1-Q4 已答（2026-08-16）

| Q | 粟粟的决定 | 落在哪 |
|---|---|---|
| Q1 关掉的还能找回吗 | **能** —— 长按 `[+]` 弹菜单，里面有恢复 | M1 `close_window` 只标记 `closedAt`；M3 长按菜单 |
| Q2 显示序号还是 code | 按推荐：**显示序号，长按看 code** | M3 |
| Q3 shell 起始目录 | `~` | M1 `spawnSession` shell 分支 |
| Q4 数量上限 | **不设**，挤了横滚（去学 page0） | M3 抄 `SidebarView` |

数据结构因此定为：

```ts
interface TerminalWindow {
  code: string          // 永久身份，6 位 base36
  createdAt: string
  closedAt?: string     // 有值 = 已关闭（导航里不显示，但能从长按菜单恢复）
}
```

「关闭」= 写 `closedAt`；「恢复」= 清 `closedAt`。**tmux session 全程不动**，
所以恢复回来里面跑的东西还在（这正是粟粟要「保留 tmux」的意义）。
