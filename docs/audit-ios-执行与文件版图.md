# Audit：iOS 端「执行」与「文件」版图

> 2026-09-24 · 只读审计，没改代码。
> 代码依据：主仓 `master @ 73b8e009`（iOS 相关代码 mint worktree 没动）。`research-runtime-unify.md` 在 `.worktrees/mac-mint-appearance/docs/`。
> 下文路径：Swift 相对 `MemoryPalace/`，hub 相对 `cc-bridge/`，文档相对 `docs/`。
> 发行版（`release/tf-2026-09`）比 master 多一道 `ReleaseGate`：沙箱、`[+]`里的「沙箱 shell…」、军机处、交易都藏了，CC 终端留着。下表写的是 master 的状态，受闸影响的另外注明。

---

## A. 执行环境盘点

| 名字（代码 / UI） | 谁在用 | 命令实际跑在哪 | 传输 | 默认工作目录 | 能看到什么文件系统 | 状态 | 关键文件 |
|---|---|---|---|---|---|---|---|
| `run_command` iOS 后端 / 「ish沙箱」 | 模型（普通对话里的工具） | **手机**：app 进程里的 iSH，跑 Alpine aarch64 | 进程内。每次调用 fork 一个新的 `/bin/sh`，命令从 stdin 进去；没有 PTY，调用之间不保留状态 | `/mnt/library/<slug>`，也就是当前楼层文件库的挂载点。挂不上时（iCloud 楼层 / 库里有指向库外的 symlink / 挂载失败）回落到 `/root` | guest 自己的 rootfs，加上**当前楼层**的 `filesystem/`（读写）。记忆树、`.memorypalace/`、别的楼层、iCloud 楼层都看不到。没有网络保证（`apk` 的退出码不可信） | **已落地**：真机验收 1-6 过了，7-12 部分没验（`粟粟信箱/ish-verification-feedback.md`）。TF 版被闸掉 | `Sandbox/ish/ISHShellBackend.swift:49`（cwd），`SandboxMount.swift`，`Services/DeviceTools/RunCommandTool.swift` |
| 口袋 Linux 终端（人手直接操作 iSH） | 用户自己 | 手机 iSH | 计划：`protocol TerminalBackend`，把 guest PTY 接进 SwiftTerm（`feed` / `send`），scrollback 自己维护 | — | 同上 | **计划，没开工**。对应 `research-离线沙箱.md` §8 的 Phase 4（「终端 UI + 路由」，约 1 周，依赖 Phase 2）。09-06 验收时粟粟把它标成 🔴 缺陷：「人类不能直接操作沙箱」 | `research-离线沙箱.md` §3.3 / §8，`粟粟信箱/ish-verification-feedback.md` |
| **rootshell**（说明） | — | — | — | — | — | **它不是 MP 的功能。** 是 `kitknox/rootshell`（MIT，43 万行的 iOS 终端 App），克隆在 `记忆宫殿/rootshell/` 当参照。**已经做完的**：键盘工具条整套照抄（`Views/Terminal/` 13 个文件）、设置搜索、主题页的做法。**已拍、没做**：层级三刀（状态点、标题链、排2 分家，`plan-terminal-hierarchy.md`），层2 用 libghostty 换掉 SwiftTerm（先单独 research），层3「SSH 救援通道」（只在 hub 挂了时从手机救它）。**不抄**：层4 的 VNC / SFTP 等。「口袋 Linux 终端」和 rootshell 的代码没关系，只是 rootshell 对比报告 §5.6 提过「`[+]` 里放沙箱 shell 入口」 | `research-rootshell-compare.md` §7-8，`未来愿景/迷路map.md:80` |
| 右页「CC 终端」（对话绑定的那个 tab） | 用户看、偶尔敲；里面跑的是 Agent | **Mac**：hub 起的 tmux。Claude 对话是 `mp-cc-<对话id前8位>`，Codex 对话是 `mp-codex-N`；对话没绑 session 时回落到主 session `mp-cc` | WS `/cc`，帧是 `terminal_attach / input / resize / detach` ⇄ `terminal_init / chunk` | claude 在 **`~/Desktop/cc-rp`**，codex 在 **`~/Desktop/gpt-rp`**（hub 决定，见 C） | 整台 Mac，按用户权限 | 已落地，TF 版也留着（`5bb873be`） | `Views/CCTerminalPanelView.swift:701`，`hub.ts:776` |
| `[+]` 轻点 / 「新建终端窗口」 | 用户 | Mac：hub tmux `mp-win-<code>`，跑 `$SHELL -l` | 同上；开窗是 `open_window` 帧 | `$HOME` | 整台 Mac | 已落地 | `Views/Pixel/PixelTerminalHeader.swift:319-337`，`terminal-launch.ts`，`hub.ts:1167` |
| `[+]`「新建 Claude Code 窗口」 | 用户，里面是 claude | Mac tmux `mp-win-<code>`，每次都是全新的 claude（新的 `--session-id`，**不进 session-map**，和任何对话都没关系） | 同上 | `cc-rp` | 整台 Mac | 已落地 | `terminal-launch.ts:31-38` |
| `[+]`「新建 Codex 窗口」 | 用户，里面是 codex | Mac tmux `mp-win-<code>` | 同上 | `gpt-rp` | 整台 Mac | 已落地 | 同上 |
| `[+]`「沙箱 shell…」 | 用户 | **什么都不跑**。它打开的是 `SandboxSettingsTab`，只有状态和重置，页面里没有 shell | — | — | — | 入口已落地，但名不副实。TF 版随闸藏掉（`7581edbf`） | `PixelTerminalHeader.swift:326,342` |
| `[+]`「恢复关闭的窗口…」 | 用户 | 重新接上 Mac 上还活着的 `mp-win-*` | `restore_window` | 原来的 | — | 已落地 | 同上 `:328` |
| Agent 对话，tmux 传输（默认） | Agent：claude / codex | Mac tmux（和第一行的「CC 终端」是同一个 session） | WS `send` 帧 → hub 用 `tmux send-keys` 注入 → CC 调 MCP `reply` 回话 | cc-rp / gpt-rp | 整台 Mac | 已落地 | `hub.ts:3048`，`ConversationViewModel.swift:1989` |
| Agent 对话，stream 传输（「不带终端」） | Agent：claude | Mac 上的子进程 `claude -p --input-format stream-json` | WS ⇄ hub ⇄ stdio | cc-rp（`hub.ts:998`） | 整台 Mac | 已落地 | `stream-runner.ts`，`plan-cc-dual-transport.md` |
| **用户在终端里 ssh 到 Mac** | — | **这条路不存在。** iOS 上没有 SSH 客户端（没有 Citadel / libssh），iSH 用的 minirootfs 里也没有 openssh。唯一沾边的情况：在 `mp-win-*` 窗口里敲 `ssh`，但那个 shell 本来就在 Mac 上，ssh 只能往外连别的机器（NAS、VPS），和 hub 同源。App 外面装第三方 SSH App 走 Tailscale 当然可以，但那不在 MP 里 | — | — | — | **计划**：rootshell 层3「SSH 救援通道」，只配一个「我的 Mac」profile，用途只有 hub 挂了时救它。粟粟批了 ✅，没开工，排在开源之后 | `research-rootshell-compare.md` §7「层3」、表格第 258 行 |
| 单词考古（`vocab_archeology`） | 用户点按钮 → 脚本在 Mac 上调模型 | Mac：hub 用 `Bun.spawn` 跑 `scripts/vocab/vocab-daily.ts --word`，6 分钟超时 | WS 帧 → 结果用 `vocab_corpus_result` 整篇推回手机 | 没指定，继承 hub 进程的 cwd（`cc-bridge/`）；产物写进**仓库**的 `MemoryPalace/Resources/vocab-corpus/` | 整台 Mac | 已落地（Mac 不在线时提示「考古需要 Mac 在线」） | `hub.ts:1323`，`Services/VocabCorpusStore.swift:45` |
| 交易研究（`ticker_research`） | 用户点按钮 → Mac 上的 claude | Mac：`claude -p … --permission-mode acceptEdits` | WS | **`~/Desktop/susu-project/axismundi`**（`MP_AXISMUNDI_DIR`） | 整台 Mac | 已落地，TF 闸掉 | `trading-research.ts:9,203` |
| 中庭里的 CC 执行者 | 群聊里的 Agent | Mac tmux `mp-cc-<n>` | 另一条 WS，路径 `/agora`（同 host、同 token） | cc-rp | 整台 Mac | 已落地 | `agora-cc-executor.ts`，`Services/AgoraClient.swift:66-80` |
| 军机处派单（`warroom_request`） | 用户一句话 → 中枢 CC 拆单 → 执行者 | Mac：中枢是 `mp-cc-2521523d`（cc-rp）；子单用 `Bun.spawn` 在**目标仓库的 cwd** 里跑 | WS | 中枢在 cc-rp，执行者在目标 repo | 整台 Mac | 已落地，TF 闸掉 | `hub.ts:3446`，`warroom-dispatch.ts:263` |
| 自主任务（设置 → Agent） | 模型（agent-runner 直接拿 API key 调） | Mac 上的 hub 进程；spawn 型触发器会跑固定命令 | 手机经 WS `agent_status` / `agent_config_set` 读写 | 数据在 `~/Library/Application Support/MemoryPalace/agent` | 整台 Mac | 已落地 | `agent-runner.ts:14,230` |
| CC 遥控手机里的浏览器（pocket） | Mac 上的 CC | **反方向：命令在手机上执行**（手机 App 里已登录的 WebView：goto / js / html / screenshot） | CC curl hub `/pocket/cmd` → WS `pocket_cmd` → 手机 → `pocket_result` 回来 | — | 手机 WebView 的页面 | 已落地 | `hub.ts:1645,2883`，`Services/CCBridgeWebSocketClient.swift:836`，`plan-pocket-browser.md` |

---

## B. 文件存储盘点

| 名字 | 物理位置 | 谁写 | 谁读 | 和 Mac 上的同名东西是不是同一份 | 状态 |
|---|---|---|---|---|---|
| **楼层文件库** `floors/<slug>/filesystem/` | **iOS 默认在 App 沙盒** `Documents/记忆宫殿/floors/<slug>/filesystem/`（Files App「我的 iPhone」里看得到，因为开了 `UIFileSharingEnabled`）。**每台设备单独开了「iCloud」开关之后**，才会改到 iCloud 容器 `iCloud.com.susu.MemoryPalace/Documents/floors/…` | 用户（面板、编辑器）；模型（`fs_*`）；iOS `run_command` 通过 bind mount 写；附件（见下行）；话题卡 | 用户、模型、iSH（仅本地楼层） | **默认不是同一份。** Mac 默认在 `~/Documents/记忆宫殿/floors/`，iPhone 默认在自己的 App 沙盒里。开关存在各自设备的 `UserDefaults` 里，不跨设备同步。只有**两端都打开**时才落到同一个容器（Mac 那边走的是 `~/Library/Mobile Documents/iCloud~com~susu~MemoryPalace/Documents`）。**「Agent 在 Mac 上改了文件，手机多久能看到」**：Agent 的 cwd 是 cc-rp，默认根本不碰文件库。就算它按绝对路径去写，也只有两端都开 iCloud 时才会到手机，延迟完全看 iCloud Drive，库本身没有同步引擎。对话同步那边实测是「秒到几十秒」（`plan-cross-device-sync.md`），文件库没测过 | 已落地。「iCloud 楼层不挂进 iSH」这条分支**真机没跑过**（`plan-离线沙箱-phase2.md` T3 / T5-10） |
| 附件 `filesystem/attachments/<对话id前8>-<标题>/` | 在文件库里面，跟着开关走 | AttachmentStore：发送或收到的图和文件都存这里，包括 CC 通过 outbox 发来的 | 渲染时读；API / CC 需要时按路径读回来 | 同上 | 已落地（`plan-attachment-auto-library.md` A1-A3） |
| 话题卡 `filesystem/topics/*.md` | 在文件库里面 | 模型（`fs_write` 投题）、用户（TopicCardSheet） | 话题盒面板；iSH 里能看到 | 同上。**掉落账本**另放在 `App Support/MemoryPalace/topicBox/<pid>.json`，只在本机 | 已落地 |
| **记忆树** `floors/<slug>/memory/`（旁边还有 `tool-results/`） | **永远在本机** `Documents/记忆宫殿/floors/<slug>/memory/`，不跟 iCloud 开关走 | 系统（摘要、提取） | 模型（`fs_*` 只读）；iSH **看不到** | **不是同一份，也不同步**。同步 S3「记忆池 / 画像文档化」还没做 | 已落地；同步是计划 |
| 贴纸 png | `App Support/MemoryPalace/stickers/<profileId>/` | 用户导入 | App | 不同步，只能靠全局备份导出再导入 | 已落地 |
| 对话同步文档 `sync/<pid>/conversations/*.json` | iCloud 容器 `Documents/sync/` | SyncEngine（前台每 5 秒泵一次，按楼层开关） | 对端 SyncEngine | 是同一份，这是设计本意 | S1/S2 已落地，S3/S4 没做 |
| iSH rootfs | `App Support/MemoryPalace/sandbox/rootfs/`（`data/` 加 `meta.db`），不进 iCloud 备份 | guest 里的命令 | guest | 只在手机上有 | 已落地。**App 重启后保留**（`/root`、`/tmp`、装过的包，代码里没清；`/tmp` 重启会不会被清没实测）。以下情况会**整个重装**：用户点「重置」（要重启 App），或 `rootfsVersion` / 架构标签变了。每次 boot 会清掉 `/mnt/library/*` 的 bind 残留（R16） |
| 考古结果 | 手机 `Documents/vocab-corpus-live/<词>.md` | hub 推回来的帧 | 单词页 | 源文件在 Mac **仓库**的 `Resources/vocab-corpus/`，是拷贝不是同步 | 已落地 |
| 发给 CC 的文件（手机→CC） | **Mac** `~/Desktop/cc-rp/mp-inbox/<chat_id前16>/` | hub（把 `send` 帧里的 base64 落盘） | CC | 手机上另外在附件目录留一份，两份互不关联 | 已落地 |
| CC 发回的文件（CC→手机） | Mac `cc-rp/mp-outbox/<chat16>/` → 经 WS 到手机 → 进附件目录 | CC、hub | 用户 | 两份 | 已落地 |
| hub 的状态 | Mac `cc-bridge/secrets/`（`session-map.json`、`bind-config.json`、窗口表） | hub | hub | 只在 Mac 上 | 已落地 |
| **计划中的「挂载文件夹」** | **MP 的文档里没有定义过。**唯一出处是 `research-离线沙箱.md` §2.3，写的是 **OpenMinis** 的 `MountedFoldersManager`：用户选外部文件夹，持有 security-scoped bookmark，挂进 iSH，最多 10 个。当时是拿来当参照，结论是「MP 挂**自家**文件库用不上它」。粟粟 08-25 拍的 §10-3「iCloud 楼层 v1 不挂」，以及 phase2 plan 里「不做」那一栏的「iCloud 楼层挂载」，说的都是**自家文件库**的 iCloud 形态，不是外部文件夹。另一个接近的概念是 `research-file-library-localization-2026-06-08.md` 里的备选方案：「用户选一个文件夹当文件库根」（类似 Obsidian vault），也没排期。所以「挂什么（Mac 目录？iCloud 别的文件夹？Files App provider？）、挂给谁（iSH？文件库面板？Agent？）」**目前都没有答案** | — | — | — | **没定义** |

---

## C. 「ccrp」

**ccrp 就是 `~/Desktop/cc-rp`，是 hub 进程的固定常量。** 不是配对时选的，也没写在 session-map 里。

- 来源：`hub.ts:696` 的 `ccWorkdir() = process.env.MP_CC_WORKDIR ?? $HOME/Desktop/cc-rp`。launchd 的 plist（`launchd/com.susu.cc-bridge-hub.plist`）没设这个变量，所以生产环境就是 `~/Desktop/cc-rp`。Codex 走的是另一个常量 `codexWorkdir() = MP_CODEX_WORKDIR ?? ~/Desktop/gpt-rp`（`:698`，07-20 拍的「不和小克挤 cc-rp」）。
- 手机上发起 Agent 对话时，**手机只决定 session 名，不决定目录**。Claude 对话是 `deriveCCSession` 算出来的 `mp-cc-<对话id前8位>`（`ConversationViewModel.swift:1989`）；Codex 对话是新建时分配的 `mp-codex-N`（`SidebarView.swift:2090`）。hub 收到 `send`（或 `spawn_cc`）后按引擎挑目录：`spawnSession` 在 `hub.ts:776`，stream 在 `:998`，全局窗口在 `terminal-launch.ts`。**客户端和 hub 之间没有任何一个帧带 `cwd` 字段**，也就是说手机连「现在在哪个目录」都不知道。
- session-map（`secrets/session-map.json`）里只存 `claudeSessionId / chatId / transport / updatedAt`，**没有 cwd**。
- cc-rp 不光是「工作目录」，还有好几样东西绑在它身上：transcript 路径是从它推出来的（`hub.ts:731-734`，`~/.claude/projects/<cc-rp 转义后的名字>/`），`mp-inbox` / `mp-outbox` 都放在它下面（`:1259-1295`），Mac 端的 `CCThinkingHookInstaller` 默认往它的 `.claude/settings.json` 里装 hook，它根目录的 `CLAUDE.md` 是小克的人设和记忆。**实际上它是小克的家，不是某个项目。**
- **能不能换？** 整体换：改 env 再重启 hub。按对话换：现在不行。要做的话需要：`send` / `spawn_cc` / `open_window` 加一个 cwd 字段，session-map 存下这个 cwd，`transcriptPathFor` 改成按 session 取 cwd，inbox / outbox 的落点重新定，codex 收割 session id 时按 cwd 过滤的那段（`:799`、`:1197`）也要跟着改。
- **Mac 端同一条对话的目录是不是也是它？** 是。Mac 版 MP 通过 loopback 连同一个 launchd hub，所以还是 cc-rp。**例外**：如果 Mac 上用的是 App 内嵌的 hub（`CCHubProcess`，「启动 CC 桥接」那个开关），`MP_CC_WORKDIR` 会被设成 `~/Library/Application Support/MemoryPalace/cc-bridge/cc-rp`（`CCHubProcess.swift:86,128`），**而 `MP_CODEX_WORKDIR` 没设**，codex 仍然落在 `~/Desktop/gpt-rp`。另外，Mac 的 Code 会话（在本机 PTY 里续跑）用的是那条会话原本的 cwd，和 cc-rp 完全是两套东西。

---

## D. 通往 Mac 的所有路

| 通道 | 协议 | 谁在用 | 需要 hub 吗 | 需要 Tailscale 吗 | 状态 |
|---|---|---|---|---|---|
| hub `/cc` | WS（带 token）。主地址和备用地址竞速探测 `/health`，谁先通用谁 | CC / Codex 对话、CC 终端、推送 token 注册、考古、交易、共读信号、军机处、自主任务的配置、pocket 反向命令 | 是 | 在家走 LAN，出门要开 | 已落地 |
| hub `/agora` | WS，和上面同 host、同 token | 中庭群聊 | 是 | 同上 | 已落地 |
| 配对 `/pair` | Mac 上走 loopback HTTP 生成二维码，手机扫码存下 URL 和 token | 一次性配对 | 是 | 否 | 已落地 |
| claude-p | HTTP。Bonjour 服务类型 `_mpclaude._tcp`，连的是 Mac 上的 `~/claude-proxy`（**和 hub 无关的另一个进程**） | 模型（纯文字的 `claude -p`） | **否** | Bonjour 只在局域网里能发现；手填地址能不能走 Tailscale 没验过 | 已落地 |
| APNs / Live Activity | hub → Apple → 手机，单向 | 推送、灵动岛 | 是 | 否 | 已落地 |
| iCloud 容器 | iCloud Drive | 文件库（两端都开开关时）、对话同步 `sync/` | 否 | 否 | 已落地 |
| VPS 上的 hub | 同 `/cc` 那条 WS，只是对面换成 Linux 服务器 | Agent | 那台服务器上的 hub | 是 | 半成品（`cc-bridge/deploy/`） |
| ~~SSH 只读镜像（Code 会话同步）~~ | SSH + rsync | **这条不是手机的路。** `CodingRemote.swift` 整个文件包在 `#if os(macOS)` 里，是 **Mac 去拉别的机器**的会话记录。iOS 上根本没有 Code 这个 tab | — | — | Mac 端已落地；**iOS 上不存在** |
| SSH 救援通道 | SSH（Citadel） | 只在 hub 挂了时，从手机进 Mac 把它救起来 | 否 | 是 | **计划**（rootshell 层3） |
| iSH 里 ssh | — | — | — | — | 不存在（rootfs 里没有 ssh 客户端，apk 装包也不可靠） |
| Files App 的 SMB | — | MP 没有这部分代码。系统 Files App 自己能连 SMB，但 MP 不读外部 provider（因为「挂载文件夹」没定义） | — | — | 不存在 |

所以回答你的问题：通往 Mac、带执行能力的独立通道**只有 hub 一条**（`/cc` 和 `/agora` 都在它上面）。你说的第二条 SSH 镜像其实是 Mac 自己往外拉。另外两条独立的路是 **claude-p**（只是模型，不能执行）和 **iCloud**（只能传文件）。

---

## E. 钉不进两根轴的

1. **用户自己。** 裸 shell 窗口（`mp-win-*` 跑 `$SHELL`）和计划中的口袋 Linux 终端，干活的既不是模型也不是 Agent，是人。runtime-unify 的第一根轴里没有「人」这一格。
2. **没有对话的 Agent。** `[+]` 新建的 Claude / Codex 窗口在 Mac 上真在跑 Agent，但它们不进 session-map，不属于任何对话，也就没有地方挂「项目 chip」。
3. **pocket 反向。** 发令的是 Mac 上的 Agent，执行的是手机里的 WebView。同一个动作同时占了「Mac」和「手机」两格，而且方向和别的功能是反的。
4. **在 Mac 上跑的模型。** 自主任务（agent-runner 用 API key，跑在 hub 进程里）和 claude-p（纯文字，但必须有一台 Mac），都属于「模型 × 我的 Mac」。runtime-unify 的表里这一格写的是「v1 不做」，可实际上已经有两样东西住在这里了。
5. **藏起来的 Agent。** 考古、交易研究、军机处执行者都是 claude 或脚本在 Mac 上跑，用户看到的只是一个按钮。它们的 cwd 也不是 cc-rp，分别是 hub 自己的目录、axismundi、目标仓库。说它们是 Agent 吧，它们又没有「项目」可选。
6. **文件库横跨好几格。** 同一个楼层的 `filesystem/` 可能在手机的 App 沙盒里、在 iCloud 容器里、在 Mac 的 `~/Documents` 里，同时又被 bind 进 iSH，出现在 guest 路径 `/mnt/library/<slug>` 下。它在哪取决于**两台设备各自的开关**，和「谁干活」「在哪台机器」都没关系。
7. **附件和收发件箱。** 从手机发给 CC 的一个文件会变成两份（手机的附件目录一份，Mac 的 `mp-inbox` 一份），回程也一样。它们属于「在两台机器之间传递」，不属于任何一台机器。
8. **cc-rp 一个目录两种身份。** 它既是 Agent 干活的地方，又是小克的人设、记忆和收发件箱。「项目」这个概念把「身份的家」和「干活的目录」混在了一起。一旦允许换项目，小克的人设跟不跟着走？这件事没有定义。
9. **hub 本身。** 它不是模型也不是 Agent。它在 Mac 上，却有两个宿主：launchd 和 App 内嵌，两者的 cc-rp 位置不一样。VPS 上也可以跑一个 hub。
10. **iCloud 和 Tailscale。** 一个是存储，一个是网络，都不属于哪台机器，但它们决定了「在哪台机器」这件事能不能成立。

---

## F. 对方案 A 的影响

**手机上 Agent 对话的两个默认值，现在实际是：**
- **电脑**：就是配对过的那一个 hub（`ccBridgeBaseURLOverride` 主地址 + `ccBridgeBaseURLBackup` 备用地址，只有这一组）。代码里没有「多台电脑」的概念，也不知道对面叫什么名字：hub 没有 `hello` 帧，不报主机名。
- **项目**：Claude 对话固定是 `~/Desktop/cc-rp`，Codex 对话固定是 `~/Desktop/gpt-rp`。由 hub 的环境变量决定，App 选不了，**而且手机拿不到这个值**，因为没有任何帧带 cwd。

**「项目 chip」在手机上第一版能做到：只读显示，而且要打个折扣。**
- 只读显示：App 要么把 cc-rp / gpt-rp 写死（只对 launchd hub 成立），要么让 hub 新增一个帧报 `ccWorkdir()` / `codexWorkdir()`。前者零改动但靠约定，后者要改 hub。
- 从 hub 拉列表来选：**现在做不到**。hub 没有 `list_projects` 或 `list_dir` 帧。warroom 的索引表里确实存着历史会话的 cwd，但只能通过 loopback HTTP `/warroom/sessions` 查，手机访问不了。
- 就算有了列表，「选了真能生效」还要走完 C 里列的那一串 hub 改动。另外还要先定下来 E-8：换项目的时候，小克的人设和记忆跟不跟着走。

**rootshell 和挂载文件夹做完之后，要不要加第三根轴？**
依据现在的盘点：
- rootshell 层3 做完，只是多一条**传输**（SSH），属于 runtime-unify 分层里的第 ③ 层「怎么连」，不产生新的「谁」或「哪台机器」。
- 口袋 Linux 终端做完，会把 E-1「用户自己」变成一个常驻、看得见的入口：第一根轴要么加一个「人」，要么承认终端不走这根轴。
- 「文件在哪」**现在就已经独立于那两根轴了**（E-6、E-7）：同一个楼层文件库，在 iSH 里看得到还是看不到，取决于 iCloud 开关，而不是谁在干活或在哪台机器；手机上的 Agent 看到的是 Mac 的整个文件系统，iSH 只看到当前那一个楼层。挂载文件夹如果定义成「外部文件夹挂给 iSH」，就会再加一种「文件源」，而这种文件源不属于任何一台「电脑」。

所以证据指向的是：「执行者看得到的文件树」是一个独立的维度，今天散落在 iCloud 开关、bind mount、cc-rp 常量三处。要不要把它升格成一根轴，要等「挂载文件夹」挂什么、挂给谁定下来以后才能判断。这件事要粟粟来定义（见 B 的最后一行）。
