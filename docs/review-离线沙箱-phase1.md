# Review：离线沙箱 Phase 1 —— macOS 原生 `run_command`

> 2026-08-25 · plan `docs/plan-离线沙箱-phase1.md` 全项落地。实现记账在 plan §5。
> 数字：macOS build 绿 / `RunCommandToolTests` 8/8 / 全量测试与 iOS build 见 §零。

## 零. 验证记录

- [x] 全量测试（MemoryPalaceTests scheme）：**658/658 绿**（commit `ac9f6051`；中途两条写死计数 11/28 改 12/29，一条真 bug：老装机迁移把无历史 key 的 shell 写成 notAllowed → 迁移跳过 shell + 断言锚死）
- [x] iOS build（`MemoryPalaceIOS`，generic/platform=iOS）绿——工具与权限行都 `#if os(macOS)`，iOS 二进制不含
- [x] 装 Mac：**踩坑记账**——我三次重开的都是主 checkout 的 DerivedData（`fowvtox…`，master 包，没有 run_command），粟粟打开权限页没那行才发现；本 worktree 的产物在 `agehlpir…`，符号在 `记忆花园.debug.dylib`（macOS Debug 也是 split dylib）。22:50 已换到正确包并重钉 Dock
- [x] QA 席（opus5）独立过 diff：**报告未落盘**——agent 撞 session 额度墙（19:20 重置）死在写报告前，但它的探针脚本（`~/.claude/jobs/0853efa0/tmp/probe.swift`，把进程层逐字抄出去单测）留下四道题，全部收割：
  1. **管道读无界** → 已修：头 64K + 尾 64K 环形、中间丢弃计数（`PipeCollector.Bounded`），`yes` 跑到超时 2.4s 返回、消息 <6000 字；测试 `testUnboundedOutputStaysBounded`
  2. **库内 symlink 把相对 cwd 带出库** → 已修：containment 两边 `resolvingSymlinksInPath` 再比（与 B 报告 R5 同根，`FileLibraryStore.resolve` 那处仍欠着）；测试加 symlink 逃逸用例
  3. 快退出命令会不会白付 `killTree` 200ms → 不会：组已空 `kill(-pgid)` ESRCH 直接返回（`testEcho` 63ms 佐证）
  4. `perl -e 'POSIX::setsid'` 之类能逃出进程组 → 能，接受（边界 2）
  修后 `RunCommandToolTests` 9/9，commit `3022b49a`；全量 **659/659** 绿、iOS build 绿；Mac app 重开到该二进制。
- [x] **双席正式评审**（21:50 额度回来后，同一任务单 `qa-phase1-diff.md`；两席各被回收一次后 resume 续命）：
  - **codex Review A**（`reports/codex-qa-phase1.md`，25KB）：5 阻塞 —— ① stop 后旧工具 handler 继续存结果并再请求模型一轮（**所有工具的老病**，run_command 把它暴露）→ 修：`turnGeneration` 代际，stop/切楼层 +1，handler 每个 call 前和收尾前对照；② 权限闸早于参数闸，坏 JSON 先弹无预览卡还消费 grant → 修：preflight 提到权限闸前；③ `shell:allow` 随全量备份跨设备免问 → 修：`PermissionGrants.strippingDeviceLocal` 导入时剥 shell；④ DoD/文案对 setsid/launchctl 守护进程的绝对承诺不成立（实证能逃）→ 修文案为「同一进程组」+ 明说守护进程不在此列；⑤ 截断标记的 N 是压缩后长度不是真总量 → 修：有界读记 total 字节，外层标记不再报 N。非阻塞里也收了：ECHILD 显式 nil 不谎报 exit 0、切楼层杀命令、`PermissionCenterTests` 改快照/恢复不清真库（P1 遗留）、杀树测试用唯一脚本名。
  - **kimi Review B**（`reports/kimi-qa-phase1.md`，15KB）：阻塞项无；新实证两条——ECHILD 谎报（同上）与命令自己 `kill -TERM $$` 被报成「用户停止」→ 修：`cancelled` 集合区分用户停止 vs 其他信号；其余与 codex 重叠。它还**修正了我自评边界 2**：close(fd) 会让阻塞 read 以 0 返回，读线程不会悬着（两席实验一致）。
  - 修后 `RunCommandToolTests` 11/11，commit `f159746d`；golden 重生成（只 run_command 描述变）`b494b10b`；**全量 661/661 绿、iOS build 绿**；Mac app 重开到 22:25 二进制。
  - 未采纳/留债：多字节 UTF-8 恰落 64K 边界会出 U+FFFD（外观）；`addchdir_np` 在 macOS 26 SDK deprecated（部署 15 保留）；pgid 复用理论窗口；fail envelope 走通用折叠不走三段（可读性）。

### 零.1 粟粟真机首验撞出的（08-25 23:00）

- **askOnce 卡在 macOS 从来没弹过**（P1 遗留，真 UI 首次跑到）：`.sheet(item: Binding(get: { PermissionPromptCenter.shared.pendingRequest }))` 的 getter 里读 `@Observable` 不被 SwiftUI 订阅，值变了不重渲 → 30s 超时 → **被当成用户拒绝写进对话**。修 `c27a1ab9`：抽 `PermissionPromptHost` 在 body 显式读；`decide()` 三态，超时不落档下次再问（工具路径 + 注入路径都改）。全量 661/661、iOS 绿。
- 顺带：她第一句「看看文件库有什么文件」模型选了 `fs_list` 不用 `run_command`——正确行为，不是 bug。
- **23:38 复验通过**：新对话「用shell跑ls -la」→ 卡弹出 → 允许 → 命令跑成；证据 = `unified.store` 里该对话 `permGrantsRaw = shell:allow`（超时不落档后，这个值只有点允许才会写）。真机清单 §四 第 1、2 条 ✅。NSLog 探针进不了 unified log（`log show` 按进程/pid 都空），下次探针写文件。

### 零.2 Phase 1.1「运行」右栏面板（08-25 23:55，`0880682b`）

粟粟看 otty 右栏点名：先只要 Process + Ports。`RunCommandMonitor`（起/收命令登记）→ 面板每 1s `ps -axo pid,pgid,etime,comm` 按 pgid 过滤 + `lsof -nP -iTCP -sTCP:LISTEN -a -p …`，解析是纯函数（单测 14/14）；「停止」走 `RunCommandTool.cancel`。macOS only。全量 **664/664**、iOS 绿。留债：Working Directory 块（编辑器按已装自动检测）、会话统计；Phase 2 换 guest 进程表数据源。

### 零.3 顺手抓的老 bug（08-26 00:20）：macOS 输入框 ⌘V 不响应

粟粟报「宫殿 app 不能复制粘贴」。键探针（NSEvent 本地监视器写文件）证明按键那一刻焦点/菜单/剪贴板全正常 → 是别人先吃了键：`StickerCanvasLayer.swift` 在 macOS 挂了一组隐藏按钮绑 ⌘C / ⌘V / ⌫ / `[` / `]`，**无条件生效**（没选中贴纸时动作是空的，但 SwiftUI `keyboardShortcut` 先于菜单消费按键）。老代码，与本线无关。修：只在 `selectedPlacedStickerId != nil` 时挂。

## 一. 边界情况

1. **`killTree` 的 pgid 复用窗口**：SIGTERM → 200ms → `kill(-pgid, 0)` 再 SIGKILL。200ms 内 pgid 被系统复用给别的进程组（理论可能，pid 回绕）会误杀。Minis 用重验 task 指针防这条；我们没有内核态句柄，只能靠概率。**接受**（macOS pid 回绕 ~99999，200ms 内命中几乎不可能），review 记一笔。
2. **逃出进程组的子进程**：`perl POSIX::setsid` / `launchctl submit` 派生的进程不在我们的组里，杀不到（两席实证）；`nohup`/`disown` 逃不掉。管道侧：`finish(grace: 1.0)` 超时后关 fd，**阻塞的 read 以 0 返回、线程正常退出**（两席实验一致，我原判「悬着」不准）。**接受但文案改口**：工具描述与 systemHint 只承诺「同一进程组」，并明说守护进程不在此列、别启动。正常 daemonize 的 CLI（dev server、updater）也会这样，不需要恶意模型——所以这是能力边界不是安全论证。
3. **超时 = 整棵树死**：`timeout_seconds` 到点直接 SIGTERM/SIGKILL，没有「再宽限」。长任务模型要自己给大 timeout（≤600）。600 秒上限期间**整轮 assistant turn 阻塞**（工具循环串行 await，无流式），UI 只有等待气泡；停止按钮能杀。这是 plan §1.6 明确不做的流式输出的代价。
4. **输出编码**：`String(decoding:as:UTF8)` 对非 UTF-8 字节替换成 U+FFFD，不崩。二进制输出会变一堆 �，模型看得懂是二进制。
5. **`cwd` 绝对路径放行** = 模型可在任何目录跑（`/`、`~`、`/System`）。这是设计决定（macOS 无沙箱，askOnce 已授权整条对话，目录白名单是假安全）——但意味着 **askOnce 一次允许 = 本对话内 AI 拥有你的用户级 shell**。粟粟拍了 askOnce 够用；真机清单 §四 第 5 条让她亲眼看一次拒绝路径。
6. **环境变量继承 app 全部 env**：MP 进程的 env 里有什么，子进程就有什么。MP 自己不往 env 塞密钥（hub token 只给 hub 子进程）；但如果 app 是从带密钥 env 的终端启动的（`ANTHROPIC_API_KEY=… open …`），会继承。**未处理**——Phase 2 前决定要不要白名单 env（`PATH/HOME/LANG/TERM/TMPDIR/USER/SHELL`）。
7. **并发**：同一对话内模型一轮发两个 `run_command`——工具循环串行执行，`running[conversationId]` 只记最后一个；前一个已结束不影响。跨对话并发各自 key，互不干扰。
8. **askOnce 卡 detail 只在 `run_command` 传**；其他域 detail=nil，卡不变。`Request.detail` 是 `let`，老调用方全走默认参数。

## 二. 与 Phase 2（iOS iSH 后端）的接缝

- **工具名/契约冻结**：`run_command` + `command/timeout_seconds/cwd` + envelope 字段（`exit_code/stdout/stderr/duration_ms/truncated/cwd`）。iOS 后端必须吐同形 JSON，渲染层 `shellView` 才复用。
- **`RunCommandTool` 整文件 `#if os(macOS)`**；Phase 2 的形状是 `RunCommandTool` 变协议/两实现，或 dispatcher 按平台选后端——二选一时别让 iOS 后端复制 `clean/truncate`（抽到共享）。
- **文案红线要带过去**：iOS 后端**才**能叫沙箱；`PermissionDomain.shell.summary` 现在写「在这台 Mac 上」，iOS 上线时要按平台分文案（`#if` 或 `displayName` 不变、`summary` 分）。
- **取消**：iOS 侧对应 `ISHShellExecutor.killProcessGroup` 语义（pgid 或祖先链），`cancelAssistantTurn` 的钩子已是平台无关的入口。
- **cwd 语义**：macOS 默认文件库根；iOS 挂载后默认应是 `/mnt/library/<slug>`——同一个「默认 = 当前楼层文件库」的语义，路径不同。
- **`running` 注册表按 `activeConversationId`**：Phase 2 若允许后台/非活跃对话跑命令（AUTONOMY），这个 key 要换成命令自己的 id。

## 三. 技术债务

1. **ANSI 剥离在工具侧做了，plan 写的是渲染侧**——决定改在源头（模型也省 token），但意味着 UI 永远看不到颜色。可接受。
2. **`shellView` 解析在 View 里每次 body 跑 JSONSerialization**（`ToolCallCardView` 是 private，结果文本不大）。热路径若有感知再缓存。
3. **`testTimeoutKillsWholeTree` 断言「系统里没有 `sleep 100`」**——粟粟机器上别的进程恰好有 `sleep 100` 会误红。低概率，红了看 marker 那条断言。
4. **测试写真实文件库根目录**（`FileLibraryStore.libraryRoot(profileId: "test-run-command-…")`）会在 `Documents/记忆宫殿/floors/` 留一个测试楼层目录，与设备工具测试同款脏。有 `StorageMaintenance` 清理吗？未查。
5. **`env` 白名单未做**（边界 6）。
6. **plan spec gate 跳过**：粟粟直接 go，codex 席位当时不可用；本 review 由 QA 席（opus5）独立过 diff 补位（见 §零）。

## 四. 粟粟真机清单（macOS）

> 08-26 00:25 粟粟：「都修好了，我也看见 port 了」——1/2/3（弹卡/允许/不重复弹）+ 运行面板 Ports ✅；4-8 未逐条验，随用随报。

1. 设置 → 权限 →「AI 能做什么」有「运行命令」行，默认「每次询问」
2. 对话里说「列一下我文件库根目录」→ 弹卡（卡上看得到 `$ ls …`）→ 允许 → 折叠行直接展开：`$ 命令` / 输出
3. 同对话再让它跑一条 → 不再弹
4. 新对话再来 → 又弹一次
5. 权限改「不允许」→ 模型收到拒绝文案并引导去设置
6. 让它 `sleep 300`（timeout 5）→ 5 秒后报超时；`ps aux | grep sleep` 无残留
7. 让它跑长命令，中途点「停止」→ 进程消失，气泡「（已停止）」
8. iPhone 端：模型的工具列表没有 `run_command`，权限页没这行
