# Research：真终端 + 多窗口导航

> 2026-08-16 · 需求来源：粟粟「真终端/多窗口导航/不就可以别的机器了？现在已经差不多了只不过只能用 claude 和 codex 的终端，以后最好能用任何终端」
> 状态：**research，等粟粟确认理解后才进 plan**

---

## 一、粟粟拍板的导航形态

```
排3:   >mp-cc-t1        1    2    3           [+]
       └─────────┘      └──────────┘          └─┘
       跟着对话走         全局共享             新开
```

| 位置 | 内容 | 行为 |
|---|---|---|
| **左边固定一个** | 当前对话绑定的终端 | 切对话它就变 —— 保持现在「一对话一终端」的形式 |
| **右边 N 个** | 全局窗口，编号 1/2/3 | **跟对话无关**，从任何对话进 CC 终端页看到的都是同一批 |
| `[+]` | 新开一个全局窗口 | |

**明确不要**：把所有开着的 session 都列进导航。粟粟原话「那会爆炸」—— 她机器上现在有 20+ 个 `mp-cc-*`。
导航里的数量恒等于 `1 + 她自己开的几个`，永远可控。

---

## 二、关键发现：终端底层**早就是通用的**

这刀不是「实现一个终端」，是「解开一处分流」。三个环节里只有一个写死：

| 环节 | 实现 | 通用性 |
|---|---|---|
| 输入 | `terminal_input` → `tmux send-keys -H <hex>`（hub.ts:2063-2075） | ✅ 注释原文「支持任意 ANSI escape」。只认 session 名，不关心 pane 里跑什么 |
| 输出 | `pipe-pane` 抓 pane 字节流 → `terminal_chunk`（hub.ts:918-923） | ✅ 同样不关心内容 |
| **起会话** | `sessionEngine()` 按名字前缀分流（hub.ts:677-679） | ❌ **唯一的限制** |

```ts
export function sessionEngine(name: string): "claude" | "codex" {
  return name.startsWith("mp-codex") ? "codex" : "claude"
}
```

`spawnSession`（hub.ts:548-575）据此拼命令：codex 走 `codex` / `codex resume <id>`，其余走
`claude --model ... --mcp-config ...`。**没有「什么都不跑，就给我一个 shell」这一支。**

**ssh 零成本**：shell 起来后粟粟自己敲 `ssh nas` 就是了，不需要任何额外代码。

---

## 三、现状代码地图

### 3.1 对话 ↔ 终端的绑定

- `Conversation.ccBridgeSessionName: String?`（Conversation.swift:62）
- 派生规则：`deriveCCSession(convId)` = `mp-cc-<convId 前 8 位>`（ConversationViewModel.swift:1979-1982）
- 自动获得：任何用 ccBridge 聊过的对话都会补上这个字段（ConversationViewModel.swift:1924-1931）
- codex 对话：新建时直接写 `mp-codex-<n>`（SidebarView.swift:1767 / CardFlowView.swift:1207,1218）
- 复制对话时**不继承**（ConversationViewModel.swift:3638 注释：「CC session 绑定不能共享」）
- CC 终端页读它：`viewModel.selectedConversation?.ccBridgeSessionName ?? "mp-cc"`（CCTerminalPanelView.swift:477-479）

### 3.2 现有命名空间

| 前缀 | 谁建的 | 用途 |
|---|---|---|
| `mp-cc-<8位hash>` | app 自动派生 | 对话绑定的 claude |
| `mp-codex-<n>` | 侧栏长按新建 | 对话绑定的 codex |
| `mp-cc-t1` / `mp-cc-art1` / `mp-cc-30..45` | 手工 / 历史 | 杂项 |

全局窗口需要**第四个命名空间**，且要能跟上面三个区分开（否则 `list_sessions` 分不清哪些该进导航）。

### 3.3 hub 已有的 session API

- `list_sessions` → `list_sessions_result`（hub.ts:1948-1951）。**只返回 `mp-cc` 前缀**，注释写明「避免暴露用户其它 tmux 工作」
- `spawn_session`（app 侧 `CCBridgeWebSocketClient.spawnSession`，幂等，已存在返回 `session_exists`）
- **没有 kill/close session 的 API** ← 要新增

---

## 四、要新建的东西

### hub 侧（小）

1. `sessionEngine` 加 `"shell"` 分支（按新前缀）
2. `spawnSession` 的 shell 分支：**不跑任何 agent**，让 tmux 起默认 shell
3. 绕开 claude/codex 专有逻辑 —— 这几处必须逐一确认对 shell 不误触发：
   - boot 完成检测（claude 等 TUI 就绪 / codex 等弹窗清空）
   - `sessionMap` 的 resume 绑定（shell 没有 resume 概念）
   - `askUserClearForSession(name, "respawn")`（问问题 hook 收账，shell 不涉及）
   - keepalive / nudge / 空闲推送这些定时器是否按 session 遍历
4. 新增 kill session API（导航要能关窗口）
5. `list_sessions` 的过滤规则要能把「全局窗口」单独择出来

### app 侧（中，且含一个架构决策）

1. 排 3 导航做实：左固定 + 右列表 + `[+]` + 关闭
2. **全局窗口列表存哪** —— 见 §五 Q1
3. 新建时选类型（Claude / Codex / Shell）的入口
4. 切换窗口时 CC 终端页要重新 attach（现在靠 `.id(currentSession)` 强制重建，这条链可以复用）

---

## 五、粟粟已拍板

| Q | 决定 |
|---|---|
| 全局窗口列表存哪 | **都存 + 定时同步**（本地存一份、hub 存一份，定期对账） |
| `[+]` 新建怎么选类型 | **直接开 shell**，不弹选择 |
| 窗口怎么关 | **从导航移除，但 tmux session 保留**（不 kill，里面跑的东西不能死） |
| 编号 | **1/2/3 只是示意，不是真名** —— 每个窗口自带**独特码**（永久身份，不随位置漂） |
| 工作区 | **新 worktree**（`worktree-real-terminal`） |

> 粟粟原话：「一定要注意不要搞坏现有的逻辑了！！！！😡」
> → 本刀的第一原则是**纯增量**：新前缀、新 API、新 UI，现有路径一个字节不改。
> 每一处「要改现有文件」的地方都必须在 plan 里单独列出并说明为什么非改不可。

---

## 六、风险

| # | 风险 | 严重度 |
|---|---|---|
| ~~R1~~ | ~~shell session 误触发 claude/codex 专有逻辑~~ —— **已排查，比预估低得多**，见下方「R1 排查实录」 | 低 |
| **R2** | **`listSessions()` 被 CC 会话选择器共用** —— 放宽它的前缀过滤，shell 窗口会混进那张选择器（它是给对话绑 CC 用的） | **高**（「搞坏现有逻辑」最可能发生在这） |
| R3 | 终端页 session 切换靠 `.id()` 强制重建整树 —— 记忆里有「`.id()` 整树重建雷区」的教训，切窗口时要留意 controller/attach 的生命周期 | 中 |
| R4 | shell 里能跑任意命令（含破坏性）。这是粟粟自己的机器+自己的手机，且现在通过 CC 本来就能跑命令，风险不比现状高 | 低 |
| R5 | SwiftTerm 在 iPhone 上的终端能力（复制粘贴 / 滚动 / 搜索 / 长文本）对交互式 shell 够不够用，没实测过 | 中 |

### R1 排查实录（读代码取证，非推测）

先说结论：**shell session 对 hub 的三个定时器 + agora 全部天然免疫。**

关键在于这些定时器的候选集**不是**「遍历所有 tmux session」，而是 `sessionActivity` 这个 Map：

| 定时器 | 候选集来源 | shell 会中招吗 |
|---|---|---|
| keepalive 保暖 ping（:2571-2590） | `planKeepalive(sessionActivity, …)` | ❌ shell 永不进这个 Map |
| nudge 主动搭话（:2530-2545） | `for (const [session, act] of sessionActivity)` | ❌ 同上 |
| reap 7 天回收（:2777-2790） | `sessionActivity` **且** 显式前缀白名单 | ❌ 双重免疫 |
| agora 房间派活（:1377-1382） | `listSessions().filter(agoraSessionAllowed)`，白名单写死 `mp-cc-`/`mp-codex-` | ❌ 免疫 |

**`sessionActivity` 的唯一写入点是 `recordUserActivity`（:1348），只在 app 发聊天消息那条路上被调（:1917）。
终端输入走的是完全另一条路（`terminal_input` → `send-keys`，:2063），不碰它。**

所以只要全局窗口用新前缀、且不作为聊天目标，就进不了 `sessionActivity`。

⚠️ 但仍然要给 `sessionEngine` 加 shell 分支，两个理由：
1. `spawnSession` 需要它决定起什么命令
2. 防御性 —— 现在 `sessionEngine` 是「非 codex 即 claude」，将来谁再写一处
   `sessionEngine(s) === "claude"` 的判断，shell 就会被误判进去

---

## 七、下一步

粟粟确认本文理解无误 + 回答 Q1-Q5 后 → 写 `docs/plan-真终端-多窗口.md`（含颗粒度 todo checklist）→ 等 ⧫ 批注 → 才开工。

**本文不含任何代码改动。**
