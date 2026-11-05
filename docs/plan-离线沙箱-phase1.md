# Plan：离线沙箱 Phase 1 —— macOS 原生 `run_command`

> ⚠️ **DON'T IMPLEMENT YET** — 等粟粟 ⧫ 批注后按 go 执行。
> 上游：`docs/research-离线沙箱.md`（2026-08-25 粟粟六条已拍：A 去 Commons Clause / 读写 / iCloud v1 不挂 / 独立挂载 / askOnce / **Phase 1 先走**）。
> 本期**只做 macOS、只用原生 `/bin/zsh`、零 iSH、零 GPL 代码**。目的：把「工具 → 权限 → 执行 → 渲染 → 取消」整条链在最便宜的后端上先跑通，Phase 2 的 iOS iSH 后端接同一个工具名。
> 批注约定：⧫=粟粟，`<⧫> </⧫>` 内为粟粟标注。

## 0. 完成标准（DoD）

macOS 上任一 API provider 的模型能调用 `run_command` 在这台 Mac 上跑 shell 命令；第一次调用弹 askOnce 卡（卡上能看到要跑的命令），允许后本对话不再问；权限页有「运行命令」行（默认「每次询问」）；超时和「停止」按钮都能杀掉**整棵**进程树不留孤儿；iOS 端此工具不存在、权限页无此行；650+ 测试绿、双端 build 绿。

## 1. 冻结的设计决策

### 1.1 工具契约

```
name: run_command
description: 在用户的 Mac 上运行一条 shell 命令（/bin/zsh -c）。每次调用是独立进程，无共享会话；
             工作目录默认是当前楼层的文件库根。适合列目录/搜索/跑脚本/调用命令行工具；
             改文件库里文件内容优先用 fs_write/fs_edit（原子写）。
properties:
  command          string  必填。≤ 4000 字符；更长的先 fs_write 成脚本再运行
  timeout_seconds  integer 可选。默认 120，上限 600
  cwd              string  可选。绝对路径，或相对文件库根的路径；默认文件库根
required: [command]
```

返回（`DeviceToolIO` envelope，与设备工具族同形）：
- 命令正常跑完（不论退出码）→ `ok:true`，`data = {exit_code, stdout, stderr, duration_ms, truncated, cwd}`。**非零退出码是合法结果不是工具错误**——模型要看到 stderr 自己判断。
- 起不来 / 超时 / 被取消 → `fail(code, message)`，code ∈ `failed` / `timeout` / `cancelled`；超时与取消的 message 末尾附已收到的输出（各最多 2000 字符）让模型知道跑到哪了。
- 输出上限：stdout、stderr **各** 15000 字符，超出保留头 7500 + 尾 7500 + `[…已截断，共 N 字符]`（Minis 同款头尾策略，`truncated:true`）。

### 1.2 执行（`Services/DeviceTools/RunCommandTool.swift`，`#if os(macOS)` 整文件）

- `/bin/zsh -c <command>`；环境 = app 环境 + PATH 前置 `/usr/local/bin:/opt/homebrew/bin:~/.bun/bin:~/.local/bin`（`CCHubProcess.swift:130-132` 同套路）+ `TERM=dumb` + `NO_COLOR=1` + `LANG` 若空补 `en_US.UTF-8`。**不注入任何 MP 自己的密钥/token**（Minis 把 Keychain 密钥注进 guest env 是反面教材，research §2.4）。
- **进程组**：子进程必须成为自己的进程组组长，超时/取消用 `kill(-pgid, SIGTERM)` → 200ms → `SIGKILL`。推荐机制 `posix_spawn` + `POSIX_SPAWN_SETPGROUP`（Foundation `Process` 不暴露 pgid；`Process.terminate()` 只杀 zsh 本身，`sleep 100 &` 之类子进程会变孤儿——这正是 Minis `[T-ish-thread-leak]` 那条教训的 macOS 版）。实现路径不冻结，**冻结的是验收：`sleep 100 & sleep 100` 超时后 `pgrep sleep` 为空**。
- stdout/stderr 各一根管道，后台线程读到 EOF；等待 `waitpid`。整个执行在 `Task.detached` 里，工具循环 `await`。
- **取消**：`cancelAssistantTurn`（`ConversationViewModel.swift:1771`）现在只 `providerRouter.cancel()`，工具循环里正在跑的工具不会被打断。加一个 `@MainActor` 注册表 `RunCommandTool.running[conversationId] = pgid`，`cancelAssistantTurn` 里调 `RunCommandTool.cancel(conversationId:)`。
- `cwd`：相对路径经 `FileLibraryStore.resolve` 同款 containment（不能 `..` 出库根）；绝对路径放行（macOS 无沙箱、askOnce 已授权整条对话，再加目录白名单是假安全）。目录不存在 → `invalid_param`。

### 1.3 权限（`PermissionCenter.swift`）

- 新域 `case shell`：`displayName`「运行命令」；`summary`「AI 可在这台 Mac 上运行 shell 命令（默认在文件库目录里，会真实改动文件）」——**文案红线（核查席）：macOS 后端零隔离，权限行/弹卡/工具描述/systemHint 一律不得出现「沙箱」二字**，那个词留给 Phase 2 的 iOS iSH；`legacy = ("deviceTools.shell", false)`；**`defaultLevel = .askOnce`**（粟粟拍；其余设备工具域是 notAllowed）；`forTool`：`name == "run_command" → .shell`；`toolDomains` 追加。
- 🔴 **红线**：`forTool` 兜底是 `.toolsMaster`（默认 bypass）。忘加映射 = shell 默认裸奔。**写测试锚死**：`PermissionDomain.forTool(named: "run_command") == .shell` 且 `.shell.defaultLevel == .askOnce`。
- 权限页 `PermissionsSettingsTab.swift:93-101`「AI 能做什么」加一行，`#if os(macOS)` 包（iOS 本期没有这个工具，不出幽灵行）。
- askOnce 卡带命令预览：`PermissionPromptCenter.Request` 加 `detail: String?`，`request(_:detail:)` 新签名（老调用方默认 nil）；`PermissionPromptSheet` 有 detail 就多显示一行等宽小字。detail = 命令第一行截 80 字符（Minis 教训：只展示第一条命令，`&&`/`|` 后面全截，否则长命令把按钮挤出屏）。工具循环的 `toolPermissionDenial` 在 `run_command` 时把 `command` 参数第一行传进去。
- `ConfigSchema` 防自授权：确认 `perm.shell` 在 AI 不可写面之内（权限 P1 是按 `perm.` 前缀还是逐 key 列的？实现时查，若逐 key 则补）。

### 1.4 注册与提示

- `DeviceToolDispatcher.definitions` 里 `#if os(macOS)` 追加 `RunCommandTool.definition`；`execute` switch 加 case。ToolRegistry / preflight / 权限闸 / tool loop 分支自动搭车（D 报告 §1.3 实证）。`ToolRegistry.swift:50` 注释「设备工具 11 件」改 12。
- `DeviceToolDispatcher.systemHint` 追加 `<命令>` 段（macOS only）：可以用 `run_command` 在用户 Mac 上跑命令、工作目录默认文件库根、每次独立进程无状态、长任务给 `timeout_seconds`、输出超长会截断、**turn 结束后什么都不再跑——别许诺「我会继续监控」**（Minis prompt 里最值钱的一句）。
- golden fixture 重生成：`REGEN_TOOLS_GOLDEN=1` 跑 `testSchemaMatchesGoldenFixture` → `/tmp/tools-schema-golden.json` 拷回。这是一次显式的形状变更审计，review 记账。

### 1.5 渲染（`MessageSegmentsView.swift` `ToolCallCardView`）

- result 段包 `ScrollView(.horizontal, showsIndicators: false)`——`ls -l`/表格类输出等宽对齐不被折行毁掉。
- 结果文本过一遍 ANSI 剥离（先 grep 仓里有没有现成的；没有就 20 行正则 `\u{1B}\[[0-9;?]*[ -/]*[@-~]`）。
- `run_command` 的折叠行默认展开（`isExpanded` 初值按 name），跑完命令不用再点一下。
- 不出 `DeviceToolCard`（单行横条装不下多行输出，D §1.4）。

### 1.6 本期不做（记在 review 债）

流式输出 / 命令级逐条批准 / 目录白名单 / iOS 后端 / 文件库 mount / 终端 UI 复用 / 「无 Mac 回落」路由。

## 1.7 Phase 1.1 「运行」右栏面板（粟粟 08-25 23:40 拍：学 otty 右栏，先只要 Process + Ports；macOS UI 以后大重构，先能用）

- 右栏插件 `run`（图标 `terminal.fill`，名「运行」），macOS only；`RightPanelView` 加一个 case。
- **Process**：正在跑的 `run_command`——命令首行 / 组长 pid / 跑了多久 / 「停止」（走 `RunCommandTool.cancel`），下面缩进列同进程组的子进程（`ps -axo pid,pgid,etime,comm` 按 pgid 过滤）。没有就「没有在跑的命令」。
- **Ports**：这些进程监听的 TCP 端口（`lsof -nP -iTCP -sTCP:LISTEN -a -p …`），没有就「No listening ports」。
- 数据源：`RunCommandMonitor`（`@Observable`，`RunCommandTool` 起/收命令时登记）；面板可见且有命令在跑时每 1s 刷一次快照（`ps`/`lsof` 走 `Process`，后台线程）。
- 不做：Working Directory 块（含编辑器自动检测——粟粟：看用户装了啥，自动检测再放）、会话统计；Phase 2 iSH 上线换数据源，面板形状不变。
- Todo：
  - [x] R0 `RunCommandMonitor` + `RunCommandTool` 登记/注销 ✅
  - [x] R1 `RunPanelView`（Process / Ports 两段 + 停止）✅
  - [x] R2 插件注册 + `RightPanelView` case（macOS）✅
  - [x] R3 测试：monitor 登记/停止清空、快照解析（14/14）✅
  - [x] R4 build ✅ 装 ✅ → 粟粟 08-26 00:25「看见 port 了」✅

## 2. 影响面

| 文件 | 改动 |
|---|---|
| `Services/DeviceTools/RunCommandTool.swift` | 新，macOS only：definition + execute + 进程组 + 超时 + 注册表/cancel |
| `Services/DeviceTools/DeviceToolDispatcher.swift` | definitions / execute / systemHint 三处（macOS 条件） |
| `Services/Permissions/PermissionCenter.swift` | 新域七处 |
| `Services/Permissions/PermissionPromptCenter.swift` | `Request.detail` + `request(_:detail:)` |
| `Views/PermissionPromptSheet`（所在文件实现时定位） | 显示 detail |
| `Views/PermissionsSettingsTab.swift` | 一行（macOS） |
| `ViewModels/ConversationViewModel.swift` | `toolPermissionDenial` 传 detail；`cancelAssistantTurn` 调 `RunCommandTool.cancel` |
| `Views/MessageSegmentsView.swift` | 横滚 + ANSI + 默认展开 |
| `Services/Tools/ToolRegistry.swift` | 注释计数 |
| `MemoryPalaceTests/Fixtures/tools-schema-golden.json` | 重生成 |
| `MemoryPalaceTests/RunCommandToolTests.swift` | 新：echo / 非零退出 / 超时杀树 / 截断 / 默认 cwd / 权限映射红线 |

## 3. 测试

- `echo hi` → `exit_code 0, stdout "hi\n"`
- `exit 3; ` → `ok:true, exit_code 3`（不是 isError）
- `sleep 100 & sleep 100` + `timeout_seconds:1` → `timeout`，1.5s 内返回，`pgrep -x sleep` 为空
- `yes | head -c 40000` → `truncated:true`，stdout 长度 ≈ 15000 + 标记
- 不传 cwd → `data.cwd == FileLibraryStore.libraryRoot(profileId:).path`；`cwd:"../.."` → `invalid_param`
- `PermissionDomain.forTool("run_command") == .shell`、`.shell.defaultLevel == .askOnce`、`.shell ∈ toolDomains`
- golden 重生成后旧 28 条逐字节不变（只多一条）

## 4. 粟粟真机清单（macOS）

1. 设置-权限「AI 能做什么」有「运行命令」，默认「每次询问」
2. 对话里说「列一下我文件库根目录」→ 弹卡（卡上看得到 `ls …` 那行）→ 允许 → 折叠行直接展开显示结果
3. 同对话再让它跑一条 → 不再弹
4. 新对话再来 → 又弹一次
5. 权限改「不允许」→ 模型收到拒绝文案并引导去设置
6. 让它 `sleep 300` 并 timeout 5 → 5 秒后报超时；`ps aux | grep sleep` 无残留
7. 让它跑长命令，中途点「停止」→ 进程消失，气泡「（已停止）」
8. iPhone 端：工具列表没有 `run_command`，权限页没这行

## 5. Todo

- [x] T0 `PermissionDomain.shell` 七处 + 红线测试 ✅
- [x] T1 `RunCommandTool`：definition / posix_spawn 进程组 / 双管道 / 超时杀树 / 截断 / cwd containment ✅（ANSI 剥离挪到工具侧做——JSON 里的 `` 渲染层难剥，且模型也省 token）
- [x] T2 注册表 + dispatcher + systemHint（macOS 条件）+ ToolRegistry 注释 ✅
- [x] T3 取消：注册表 + `cancelAssistantTurn` 接线（按 `activeConversationId`）✅
- [x] T4 askOnce 卡 detail（Request / request 签名 / sheet / toolPermissionDenial 传参）✅
- [x] T5 权限页一行（macOS）+ ConfigSchema `perm.shell` 黑名单 ✅
- [x] T6 渲染：run_command 折叠行改成「$ 命令 / stdout / stderr / exit」三段等宽 + 横滚 + 默认展开 ✅（比 plan 多做了可读拆段——原始 JSON 里 `\n` 是转义串，一行糊死）
- [x] T7 测试八条（多一条 clean）+ golden 重生成（旧 28 条逐字节不变，只加 run_command）✅
- [x] T8 双端 build + 全量测试 + 装 Mac ✅（macOS build ✅ / 全量 658/658 ✅ / iOS build ✅ / Mac app 重开到新包 ✅；真机清单 §4 等粟粟——弹卡/停止按钮这类 GUI 步 osascript 被 TCC 挡，代跑不了）
- [x] T9 review-离线沙箱-phase1.md ✅ + NOW.md + 项目卡
- [x] T10（评审后追加）双席 diff 评审收口 `f159746d`：codex 5 阻塞 + kimi 2 实证全修；**冻结决策修订**——§0「整棵树不留孤儿」改为「同一进程组」（setsid/launchctl 守护进程实证能逃，属能力边界）；§1.1 截断标记不再报「共 N 字符」（内层报真字节总量）；§1.3 参数预检在权限闸之前；新增「shell 授权设备本地，全量备份导入剥离」
