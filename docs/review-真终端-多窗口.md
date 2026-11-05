# Review：真终端 + 多窗口导航

> 2026-08-16 · [research](research-真终端-多窗口.md) · [plan](plan-真终端-多窗口.md)
> 分支 `worktree-real-terminal` 3 commit → master ff → 装机验收「都好了」

---

## 一、边界情况

### 已处理

| 场景 | 行为 |
|---|---|
| 注册表 JSON 坏 / 不是数组 / 混脏记录 | 返回空列表，**绝不抛** —— 注册表坏了最多窗口列表空，不能让 hub 起不来。单测覆盖 |
| code 碰撞 | 重抽 50 次，再撞用时间戳兜底，绝不返回重复 |
| 关闭不存在的 code / 重复关闭 / 重复添加同 code | 全部 no-op，不抛。首次 `closedAt` 不被二次关闭覆盖 |
| 拉列表失败（离线） | **守着本地缓存标 stale**，UI 标灰。绝不清空 —— 网络抖一下让窗口全消失是最糟的体验 |
| 关闭期间 tmux 被外部杀掉（重启 Mac） | `restore_window` 会补 `spawnShellWindow`，恢复菜单里也标了「已停止（恢复会重开一个）」 |
| 全局窗口误走 `spawnSession` | 开头 guard 拦下并 warn，不会在 shell 窗口里起一个 claude |
| 全局窗口的 `onAppear` | 跳过 `spawnSession`（那条会 spawn claude），但**保留 attach 兜底** |

### 没处理（已知缺口）

1. **窗口数量真无上限**（粟粟拍的）。横滚扛得住，但注册表会一直长——关闭的记录永不清理，
   开关几百次后 `windows.json` 会有几百条。目前没有清理策略。
2. **关闭的窗口列表也无上限**。恢复菜单是个 `List`，几十条以后要滚很久。
3. **多设备并发**。两台设备同时开窗口，各自乐观更新，60s 对账后以 hub 为准——
   中间窗口期两边看到的列表可能不一致。窗口数量少时无感，没做冲突解决。
4. **shell 窗口的 usage 格子**。顶栏 `[ctx][5h][7d]` 对 shell 无意义（它没有 transcript），
   hub 的 `terminalUsagePayload` 拿不到 `sessionMap` 绑定会返回 null，所以格子恒显示 `--`。
   不难看但也没意义，将来可以在 shell 窗口时把排 2 换成别的（比如 cwd / git 分支）。
5. **横滚的震动反馈没做**。`SidebarView` 那套「划过每格震一下」需要 `scrollPosition(id:)`
   跟踪，窗口少时压根不触发吸附，做了也感觉不到。

---

## 二、与下一模块（真灵动岛 / Live Activity）的交互风险

1. **窗口列表会成为 Live Activity 的数据源之一**。现在 `TerminalWindowStore` 是 `@MainActor`
   单例，Widget Extension 是**独立进程**读不到它。真灵动岛那刀要么走 App Group 共享容器，
   要么让 hub 直接推 APNs（后者更符合现有架构，hub 已经有 usage 数据 + APNs 通道）。

2. **`selectedWindow` 是 view 层 `@State`，没有持久化**。杀掉 app 重开会回到对话终端。
   如果真灵动岛要显示「你正在看哪个窗口」，这个状态得提到能被外部读的地方。

3. **`sessionEngine` 现在有三个返回值**。将来再加引擎（比如远程 ssh 会话单独成类），
   记得检查所有 `=== "claude"` 的判断——它们是「非 codex 非 shell 即 claude」的隐式默认。

---

## 三、技术债

| # | 债 | 影响 | 建议 |
|---|---|---|---|
| D1 | 注册表只增不减（关闭记录永久保留） | 低 | 加个「彻底删除」入口，或者恢复菜单里超过 N 条自动清理最老的 |
| D2 | shell 窗口顶栏 usage 恒 `--` | 低 | 排 2 在 shell 窗口时换成 cwd / git 分支更有用 |
| D3 | iPhone 14 上没测过点击 | 中 | 横滚吞点击是记忆在案的老坑（14 暴露 / Air 正常）。已预防性用 `onTapGesture`，但没在 14 上验证过 |
| D4 | `hasPrefix("mp-win-")` 在 Swift 侧散落三处 | 低 | 前缀常量目前 TS 侧有 `WINDOW_PREFIX`，Swift 侧是字面量。抽个常量更稳 |
| D5 | 多设备并发无冲突解决 | 低 | 60s 对账兜底，窗口数量少时无感 |
| D6 | `terminal-windows.json` 落盘无并发保护 | 低 | 单 hub 进程串行写，目前不会撞 |

---

## 四、途中的一个真事故：一滚就吐 `65;1;1M` 满屏

**现象**：shell 窗口一滚动，命令行被 `65;1;1M64;1;1M…` 刷满（粟粟截图）。

**根因**：`handleWheelPan` 把触摸 pan 转成 SGR 1006 鼠标序列（`ESC[<64;1;1M`）发给远端。
这段代码的注释**自己写着它的前提**：

> CC 恒在 alt-buffer 且开了鼠标模式（tmux mouse_any=1），但 SwiftTerm 这边 mouseMode
> 因 onInit 的 ESC c reset 而恒 .off 不可靠 → 不判 mouseMode，直接转发滚轮

那个前提只对 CC/codex 成立。裸 zsh 在 normal buffer、**没开鼠标上报**，收到这串就当字面
字符打进命令行。

**为什么不能改判 `mouseMode`**：它对 CC 是「假 off」（被 `ESC c` reset 抹了）、对 shell 是
「真 off」，两者读数一模一样，区分不了。只能按 session 身份判。

**修法**：两道闸——手势层直接不消费（交给 SwiftTerm 本地滚 scrollback，shell 在 normal
buffer 本来就有历史），`sendScrollWheel` 里再拦一次防将来别的调用方重蹈覆辙。

**教训（值得进记忆）**：给终端复用「为 TUI 设计的输入转换」时，必须检查那个转换的隐含前提
（alt-buffer / 鼠标上报 / 特定键位映射）在新场景下还成不成立。转义序列不被识别时不会报错，
**会变成字面字符**——是静默失败的一种。

---

## 五、验收状态

plan §六 的 10 条回归清单：**8 条已验**（其中 5 条是代码层结构性保证 + 3 条实测），
2 条待补（codex 对话未单独测 / iPhone 14 未测点击）。

粟粟实测结论：**「都好了」**——shell 出得来、能跑命令、滚动不吐字符、CC 窗口没被修坏。
