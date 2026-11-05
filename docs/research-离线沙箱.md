# Research · 离线沙箱（iSH ARM64 嵌入 MP）

> 2026-08-25 · 粟粟「离线沙箱，试试！」→ 车队 SBX 批次（4 侦察 + 1 构建探针 + 1 对抗核查）。
> 底料：OpenMinis `09fc199`（`deps/ish` = `OpenMinis/ish-arm64` fork `19c690c`）。报告与 trace 在 `docs/prompts/2026-08-25-sandbox/`。
> **状态：✅ 2026-08-25 粟粟已拍（A去Commons Clause / 读写 / iCloud v1不挂 / 独立挂载 / askOnce / Phase 1先走）。下一步：Phase 1 plan。**

## 0. 一句话

**技术上能做，而且内核侧比想象轻**（本机从零到 iOS 可链接产物不到半分钟、静态库 1MB、rootfs zip 3.8MB、0 新 entitlement、bind mount 六步实测全通且和文件库天然对口）；**重的是 app 侧胶水 + 十六条对接风险 + 一道产品级门：GPL-3**。这道门不是工程问题，是粟粟要拍的许可路线——拍了才有排期意义（→ 已拍，见 §10）。

## 1. 粟粟要什么（原话）与形态判断

- 「等会，等会，我们也想离线自包含啊」「先弄工具，然后设为独立远线」「主要我很喜欢它可以 mount，所以我们的自己搓的那个文件库也能用」「离线沙箱，试试！」

形态判断（编排者，08-24 已口头过一次，本文落字）：

- **沙箱 = MP 工具循环里的一个 `run_command` 工具**（Minis 同款 `shell_execute`），脑随便接：家里 claude-proxy / 出门云 API / 未来本地模型。**不是把 CC 塞进沙箱**——CC 是 cc-bridge 那条腿，两条腿互补：有 Mac = 真终端（tmux over hub），无 Mac = 口袋 Linux。
- **文件库 bind mount 是第一公民**：guest 里 `/mnt/library/<楼层>` 直接就是 `Documents/记忆宫殿/floors/<slug>/filesystem/`，shell 工具在库上干活，MP 原生侧同时能看到。
- **macOS 不需要 iSH**：MP macOS 无 App Sandbox，`Process()` 起 `/bin/zsh` 就是 `run_command`（`CCHubProcess.swift` 已有 spawn/PATH/pipe/watchdog 样板）。iSH 只在 iOS 是必需品——"一个工具、两个后端"。（核查席点出、编排者认账：**这条是粟粟没提过、编排者加的戏**，已作为 §10-5 亮牌并获拍。真正的坑是语义：同一个工具名，**macOS 后端没有任何隔离**——「沙箱」这个词只对 iOS 的 iSH 成立。用户可见的文案（权限行/弹卡/工具描述）在 macOS 上**不得称沙箱**，要写「在这台 Mac 上运行命令」。）

## 2. 它是怎么做的（机制，已核实）

### 2.1 引擎与内核

- **Asbestos 不是 JIT**：upstream 2024 改名，是 threaded-code 解释器——每个 guest 基本块编成一串预编译 ARM64 gadget 的指针，尾调用链式执行，不生成机器码、不需要 W^X（`deps/ish/README_arm64.md:19-30`）。所以 **iOS 不需要 JIT entitlement**；Minis/iSH 的 entitlements 里都没有内存/JIT 键（A §5）。
- ARM64 guest 同架构分发 → 开销 3-30×（x86 版 15-100×），48 位地址空间让 Node/Go/Rust 能跑；README 声称「10,000+ 用户」（出处在 `deps/ish/README_arm64.md:12-17`，不在 OpenMinis 主 README）。
- 内核 = C 实现的 Linux syscall 层（fork/exec/signal/pipe/epoll/futex）+ fakefs（SQLite `meta.db` 存 mode/uid/inode，数据落真目录）+ socket 直通宿主网络栈（无 NAT；guest 能到 LAN，`127.0.0.1` 是 iPhone 自己不是 Mac）。

### 2.2 bind mount（本线的心脏）——「表驱动直连宿主 + 懒元数据」

编排者亲读 + B 报告核实，**与 OpenMinis 自己文档的「symlink 机制」说法只对一半**：

- 挂载 = 往 32 槽全局表 `g_bind_mounts[]` 写一行（guest 前缀 → 宿主 realpath），并在 `data/` 下建一个**相对路径** symlink（`fake.c:1083-1116`；绝对 symlink 在 iOS 上失败）。
- **热路径不走 symlink**：open/stat/readdir/unlink/rename/mkdir 全部先查表拿宿主绝对路径再直调 libc（`fake.c:390-421`）。symlink 只服务 4 条残余路径（`utime`、`symlink`、`link`、Minis 宿主侧 `noff_resolve_host_path`）。
- **readdir 读的是宿主真目录**（`fake.c:1019-1023` → `real.c:236`），`meta.db` 没行的条目由 `bind_mount_ensure_inode`（`fake.c:342-374`）现场 `stat` 宿主补行（mode 写死 0755/0644/0777，uid=gid=0）。→ **MP 原生写进库的文件，guest `ls` 立刻可见，零同步动作**。（探针实测见 §6。）
- 反方向：guest 每次写/删/改名进 1024 槽环形缓冲 + `fakefs_install_change_consumer` 批推宿主（`fake.c:1477-1526`、`ISHKernel.m:1381`）——MP 刷文件库面板靠它。
- 只读挂载靠 `is_under_readonly_bind_mount` 前缀比较在 9 个 syscall 入口返 EROFS（`fake.c:322-338` + 表见 B a3），**不信任 mode 位**（iSH 进程是 root）。
- 表每次 `fakefs_mount` 被 memset（`fake.c:1373`）→ 每次冷启动重建，容器 UUID 变化免疫；MP 文件库与 rootfs 是**同容器兄弟目录**，相对 symlink 稳定、不需要 security scope、不涉及 FileProvider XPC——**比 OpenMinis 挂外部 vault 简单一个数量级**（B a1）。
- 还有 per-`fs_context` 路径翻译 hook（`fake.c:255-278`）：同一 guest 路径按会话映射不同宿主目录，但 hook 路由的路径**故意不进 meta.db**（`fake.c:428-441`）。楼层路由若走它要先吃透这条约束。

### 2.3 OpenMinis 的「挂载文件夹」产品层（粟粟看到的那个功能）

`MountedFoldersManager`/`MountedFolderCoordinator`（`src/ios/Views/Settings/`）：security-scoped bookmark 持 scope 整个生命周期、resolve 必须离主线程（FileProvider 同步 XPC 卡主线程 20s 被 0x8BADF00D 杀，注释里的血泪）、iCloud/三方 provider 占位符三级唤醒（coordinate → signalEnumerator → 250ms 轮询 10s）、失败降级 `.contentsUnavailable` 宁可不挂也不让 shell 读空、上限 10 个（给 32 槽留余量）、原生侧读写全过 `NSFileCoordinator`、**只把顶层挂载点写 meta.db 不递归**（vault 可能巨大）。这一层 MP 挂**自家**文件库**用不上**（不是外部 URL），但它的占位符处理与只读双层执行是现成参照。

### 2.4 agent 集成（C 报告翻了我五条过时前提后的真相）

- 工具叫 **`shell_execute`**（`AIChatViewModel+ToolDefinitions.swift:39-50`）：参数 `tool_title` / `command`（≤1000 字符，长脚本先 `file_write`）/ `timeout`（默认 900s）/ `delay`（等待不占 shell）。
- **无 PTY、无 FIFO、全并发**：每次调用 fork 一个新 `/bin/sh`，命令走 stdin 管道，stdout/stderr 分管道逐行回调；FIFO 串行 2026-05-25 删（`ISHExecutionCoordinator.swift:26-38`）；结束 = 进程退出通知 + 管道 EOF；无 prompt 正则、无 echo 去除（只有 `\r` 折叠 + ANSI 剥离）。
- 输出上限：喂模型 15000 字符（头尾各半 + `[OUTPUT TRUNCATED]`），UI 流式 30000 字符，每 ≥0.2s flush 一次进消息 block；有专门的命令胶囊卡 + 点开详情页。
- 取消：`killProcessGroup` 按 pgid **或祖先链**匹配（busybox ash 会 setpgid 导致 pgid-only 漏杀 `sleep`），SIGTERM → 200ms → SIGKILL，拒绝 pid ≤ 1，延迟 SIGKILL 前重验 task 指针防 PID 复用（`ISHShellExecutor.m:555-628`）。超时必须杀整组，否则子进程 emu 线程堆积 → jetsam（`[T-ish-thread-leak]`）。
- system prompt 教法（逐字在 C 报告轴 1.1）：主动用 shell、`delay` 代 `sleep`、**「turn 结束 = 什么都不跑」防空许诺**、预埋平台知识（musllinux 无 wheel → `apk add py3-*`、ash 无 globstar、后台服务必须重定向防 SIGPIPE、matplotlib `Agg`）。
- **密钥暴露**：Keychain 里的用户 env var 直接进 guest envp，`env` 全可见；只在喂回模型前打码（`EnvVarRedactor`），不挡 guest 进程不挡 UI。MP 不能走这条。
- 交互终端 `src/ios/iSH/Terminal/`（3,290 行自绘）是给用户的，走单 PTY；与 agent 路径无关。MP 有 SwiftTerm，可整块不要。

### 2.5 iOS 生存面（C 轴 2）

- **内存**：无 entitlement，靠软件层——fork guard 量 `phys_footprint`（Jetsam 真用的指标），阈值 = 物理内存 1/4 clamp [500MB, 2GB]，超阈值且（系统压力非 normal 或 >1.5× 阈值）时**阻塞 guest fork 最多 2s** 等退出进程释放，超时仍放行（拒绝会让 busybox xargs 静默丢工作项）（`ISHKernel.m:84-293`）；另有 guest 匿名 mmap 全局硬上限 4GB（`mm.h:8-13`，注释数字过时）。两代失败史在注释里：固定 500MB 在 12GB 设备每次 fork 都触发；旧版「等待永不拒绝」= 纯 10s 延迟。
- **后台**：iOS 26 实测后台 60s 滑窗烧满 48 CPU-s 即被杀；Minis 有闭环 CPU governor（GREEN/YELLOW/RED，RED duty 3%，每 tick 把 guest 从链式执行里戳出来付睡眠债，长任务收敛到 ~63% 速度，`docs/ish-bg-cpu-governor-design.md` 已落地设备验证）+ 静音音频/定位/`beginBackgroundTask` 四层保活。**不保活时 ~30s 后 `stopCurrentCommand()` 杀掉正在跑的 guest shell**。MP 已判「不学静音音频保活」（《minis对比》）→ **长命令只能前台跑**，UI 要明说。
- **崩溃隔离是信号级不是地址空间级**：SIGSEGV/BUS/ILL/TRAP 兜住（JIT 内跳 trampoline；guest 线程永久挂起不 `_exit`），SIGABRT 故意不拦，**越界写踩宿主数据结构兜不住**（guest 内存就是 app 自己的 mmap 页）。
- **reset 不可热重挂**：`become_first_process()` 不可逆，重置 rootfs 后 kernel 仍 `isBooted`，下次执行崩；只能「标记 + 要求重启 app」（`RootfsManager.swift:21-31`）。
- 冷启动：首次从 bundle 解压 `alpine-rootfs.zip`（自带 ZIP reader，无进度回调），只有状态级 overlay 无百分比；仓内无实测毫秒数。

## 3. 嵌进 MP 要做什么（A + D）

### 3.1 最小嵌入清单

| 类别 | 内容 | 量级 |
|---|---|---|
| 复制 | `deps/ish` fork 全树（README 自称 86 commits / +23k 行，浅 clone 看不到）；`build_ish.sh`（433 行）+ `prepare_alpine_rootfs.sh`（383 行）改输出路径/品牌串；`RootfsPatch.bundle`（15.6KB） | — |
| **整文件搬** | `ISHShellExecutor.h/.m`（126+880，零 Minis 依赖，= `run_command` 引擎）、`CurrentRoot.h/.m`（15+115） | 1,136 行 |
| **搬+删改** | `ISHKernel.h/.m`（187+1,919）：删 27 个 offload import + 27 个注册，改 DNS 路径；`RootfsManager.swift`（680）：换 logger、ZIP reader 可换 ZIPFoundation | 2,786 行 |
| **新写** | MP 首个 bridging header（MP 现 0 个 .m/.c/.h）；`run_command` 工具 + 协调器（参照 `ISHExecutionCoordinator.swift` 852 行）；build 脚本参数化 **三份 slice**（device / simulator / macosx——`build_ish.sh` 只出 device 一份，simulator 必须单独编）；rootfs 单归档打包 | 中 |
| 不写 | 终端 UI（MP 有 SwiftTerm，省 3,290 行） | — |
| 构建 | `libish.a` / `libish_emu.a` / `libfakefs.a`（macOS arm64 实测 566K/456K/23K ≈ **1.02MB**）；VDSO 被 `.incbin` 编进 libish.a 不入 bundle | — |
| 声明 | `libsqlite3.tbd` + `libresolv.tbd` + `SystemConfiguration.framework`；`HEADER_SEARCH_PATHS` / `OTHER_LDFLAGS` 走完整路径（上游 `AppARM64.xcconfig` 同款，绕 xcodegen 依赖推断）；**0 新 entitlement** | — |

胶水合计 3,922 行（不含终端）。project.yml 草稿在 A §2.2（PLAUSIBLE，未跑 xcodegen；三处未验语法已标）。

三个构建坑（A §1.5）：**VDSO 找不到 llvm 时静默 `touch` 空文件编进库，构建全绿运行期 guest 拿零字节 VDSO**——脚本必须加非零断言；`ISH_INTEGRATION.md` 三处与真工程不符（`-ObjC -all_load` / `-DISH_INTERNAL` / ZIPFoundation），当营销材料读；`Copy Alpine Rootfs` build phase 是空壳，rootfs 走普通 Resources。

### 3.2 MP 侧接入点（D §1）

- 工具总数 28（golden fixture 实数）；**defer 阈值 16 只数 MCP 工具**，加内建工具不触发 meta-tools 模式（`ConversationViewModel.swift:2391,2417-2418`）。
- 按设备工具族样板，`run_command` 必碰 5 处：新 `RunCommandTool.swift`（样板 `OpenURLTool.swift` 47 行）、`DeviceToolDispatcher.swift` 三处、`PermissionCenter.swift` 七处、`PermissionsSettingsTab.swift` 一行、golden fixture 重生成。ToolRegistry / preflight / 权限闸 / tool loop 分支**自动搭车**。
- **🔴 红线**：`PermissionDomain.forTool` 兜底是 `.toolsMaster`，其 `defaultLevel` 是 `.bypass`（`PermissionCenter.swift:138, 82-83`）。**shell 工具忘加 domain case = 默认自动放行不进权限页**。新域默认 `.askOnce`（或 `.notAllowed`），写测试锚死。
- 渲染：命令输出走折叠行（`ToolCallCardView`，等宽 + 2000 字截断 + 展开），不走 card（单行横条装不下）。缺三件：横向滚动、ANSI 剥离、默认收起。
- 工具循环现状：串行 await + 8 轮上限、结果一次性回灌无流式通道、`withTimeout` 是唯一超时原语（30s 的 `SystemAuthQueue` 是给授权 sheet 的不是命令）。长命令会阻塞整轮。
- **MP 现在零内存压力处理**（全仓 grep 无 `didReceiveMemoryWarning`/`os_proc_available_memory`），SwiftData 20 万节点常驻内存**没有任何实测数字**；唯一探针是 `DeviceInfoTool.residentMB()`——沙箱预算的分母得先量出来。

### 3.3 终端 UI 与两条腿路由（D §2-3）

- SwiftTerm 只在 `CCTerminalPanelView.swift`（775 行）消费；终端路径上 hub 调用点**只有 6 处**、5 处在 `CCTerminalController` 类体内；`CCBridgeWebSocketClient` 的终端 API 签名已经是 protocol 形状 → 加 `protocol TerminalBackend` + 注入即可。**iOS 上 SwiftTerm 没有本地 PTY 路径**（`LocalProcess.swift` 是 `#if !os(iOS)`），guest 只能走 `feed(byteArray:)` + delegate `send`，恰好与 hub 路径同两个原语。装不进契约的一处：`terminal_init` 靠 hub `capture-pane` 喂快照，本地 PTY 要自维护 scrollback。
- hub 可达性真相源 `CCBridgeWebSocketClient.isConnected: Bool`（app 级单例），无连接状态枚举，重连无限退避从不升级；**聊天发送路径无任何守卫**（`sendCCFireAndForget` 照发，600s 后等待气泡静默消失）。「无 Mac → 口袋 Linux」最窄挂点是 `sendCCFireAndForget`（三个 CC 入口汇流处），语义最正确的是 `isCC` 判定（散在 3+4 处，先抽 helper），真相源该 publish 一个 enum（形状抄 `ProxyHealth`）。
- 旁证：`CCHubProcess.swift` 是「app 拉起并监管本地执行后端」的现成范式（Process + PATH + 双 Pipe + 10s 心跳 + 三连败重启），macOS-only。

### 3.4 包体（D §4）

Debug iOS `.app` 222MB 里 **104.5MB 是 Release 不存在的 `debug.dylib`**；真实 Release 估 125-135MB（PLAUSIBLE，锚：6-19 macOS archive 单 slice ≈16MB）。加 1MB 静态库 + rootfs zip 3.8MB（探针实测）→ **落点 ~130-140MB，离 200MB 蜂窝阈值还有余量**（比 D 报告写时的估算宽松——当时 rootfs 未知）。**回血最便宜的一刀**：4717 个平铺生词 `.md`（47.7MB + 1MB 签名清单）合成单归档。另：**rootfs 不能当资源目录打包**——Xcode 会把目录平铺（vocab-corpus 已实证），必须单归档首启解压。

## 4. 文件库 mount 对接：十六条风险（B (c) 十五条 + 探针实测一条）

| # | 风险 | 级 | 解法方向（研究提案） |
|---|---|---|---|
| R1 | 楼层切换重挂载不清 meta.db → 跨楼层 inode/mode 串味（A 的目录行配 B 的文件，`cat` 崩语义） | D | **每楼层独立挂载点 `/mnt/library/<slug>`**，行永不复用；或切换时 `removeFakefsPath` 清子树 |
| R2 | `remove_tree_at` 对真实目录递归 rm -rf（挂载点选到 rootfs 已有内容处 = 永久删） | D | 挂载点固定专用空目录 + bind 前 `lstat` 拒绝非空 |
| R3 | 硬链接绕过只读（`link` 只查 dst） | D | 不用 `read_only` 模式（RW 或不挂）；若必须只读改 fork 一行补 src 检查 |
| R4 | iCloud 占位符：guest 看到 `.笔记.md.icloud`，`open()` 不触发下载；MP 原生侧同样零处理 → 两边一起瞎 | F | **v1 禁止 iCloud 楼层挂载**（开关开则不 bind，UI 说明）；后续抄 `ensureDownloaded` 挂原生侧 |
| R5 | 宿主 symlink 透明穿透逃出库根（`ensure_inode` 用 `stat` 非 `lstat`；MP `resolve()` 也不解析 symlink） | F | MP `resolve()` 补 `resolvingSymlinksInPath`——**不管挂不挂都该补**；guest 自建 symlink 逃不出宿主沙箱（`..` 也不是向量，已核实） |
| R6 | MP `.atomic` 写换 inode，guest 已开 fd 写进孤儿 | D | 两边写者都短命（AI 工具/一条命令），文档化 + 面板指纹检测；不做长驻 fd |
| R7 | 两边同时写同一文件无任何互斥（MP 无锁无队列，写者 4 类十几个入口） | D | `FileLibraryStore` 加进程级串行队列（对现存 bug 也有益）+ 挂载路径 `flock`；保守项：挂只读、写回 AI 工具 |
| R8 | Swift 侧写 meta.db 无 busy handler 静默失败 → 挂载点「时有时无」 | F | `sqlite3_busy_timeout` + 检返回值 |
| R9 | guest `ln -s` 在库里留「内容为目标字符串的普通文件」，`mkfifo` 留真 FIFO | F | 接受为可容忍脏 + 文档；备份枚举已挡 FIFO |
| R10 | 文件名 >255 UTF-8 字节（>85 汉字）在 guest 里**静默消失**（`real.c:242-246`） | F | 建文件时 clamp 字节长度（现只对楼层名截 40 字） |
| R11 | `utime` 无只读检查也不走翻译表，guest `touch` 打穿 MP 的 mtime 乐观锁 | F | 冲突检测改内容哈希（本来更可靠） |
| R12 | 首次 `ls -R` 每文件一次 SQLite 写事务（WAL 已开所以不 fsync） | X | 复用 `list()` 结果批量预热 `meta.db`；挂载点名字**别带 `minis`**（有按字串触发的 `fprintf` 噪声） |
| R13 | 挂载点是 rootfs 祖先时反查全失效 readdir 报错 inode | F | 挂载点只能是 `filesystem/` 叶子，**永远不挂 `Documents/`**；启动时 `fakefs_set_rootfs_data_path` |
| R14 | `.memorypalace/`（manifest 参与备份哈希）若挂载点上提就暴露 | F | 挂载点写死 `filesystemRoot(profileId:)` 返回值，加断言 |
| R15 | AI 工具按 `conversation.profileId`、面板按 `currentProfile` → mount 跟谁？ | F | mount 跟会话楼层（与 AI 工具一致）；配 R1 每楼层独立路径就不用 remount |
| **R16** | **bind 持久化进 rootfs**：symlink + meta.db 行落盘，下次启动不注册也按路径可写，旧 RW bind 绕过新 RO bind（探针实测 §6） | D | boot 时先清 `data/` 残留 symlink + meta.db 行再注册；只读/授权状态**以宿主侧为真相源每次重投影**，不信 rootfs 残留 |

另三条顺手账（不属本线）：`migrateLegacyFilesIfNeeded` 全失败时标完成永不重试（`FileLibraryStore.swift:567-569`，疑 bug）；macOS `iCloudDocumentsRoot()` 裸路径构造没登 iCloud 也非 nil → 实际三态（本地 / 真 iCloud / 伪 iCloud 纯本地目录）；`resolve()` 不解析 symlink（R5）。

## 5. 许可与上架（C 轴 3 + A 冲突 1）——🔴 产品级门

**文本事实**（只引条款，不下法律结论）：

- iSH **GPLv3**（`0e3a4144` 后贡献额外 GPLv2），`LICENSE.IOS` 承诺不追究**仅因 App Store 条款与 GPL 冲突**导致的违反，前提「comply with the GPL in all other respects, including its requirements to provide users with source code」。
- OpenMinis 自认：「Minis is GPLv3 because it links iSH (GPLv3) and PRoot (GPLv2)」（`BUILDING.md:263`）。
- MP 私有仓无 LICENSE；公开发布点 mneme-atrium = **AGPL-3.0 + Commons Clause（禁售）**。
- GPL-3 §10「You may not impose any further restrictions」+ §7「non-permissive additional terms are considered further restrictions」；§13 允许与 AGPL-3 作品链接但「The terms of this License will continue to apply to the part which is the covered work」。
- **冲突点**：静态链 `libish.a` 后，Commons Clause 对整个作品是 §10 意义的附加限制；`LICENSE.IOS` 豁免不覆盖自加限制。

**路线（PLAUSIBLE，粟粟拍）**：
- (a) mneme-atrium 去掉 Commons Clause，整体 AGPL-3 无附加条款（OpenMinis 走的就是纯 GPL-3）。代价：失去「禁售」——但 AGPL 本身已让闭源转售无利可图，且粟粟的名字/品牌/上架身份不受影响。
- (b) 保留 Commons Clause → **不能链 GPL 代码 → iOS 侧没有离线 Linux**（没有非 GPL 的等价物：iSH 是唯一的 iOS 用户态 Linux；a-Shell 是 BSD 但不是 Linux、也不给你 apk/pip 生态）。macOS 侧原生 shell 不受影响。
- (c) 「沙箱做成可选独立模块」在 iOS 上**不成立**——不能动态加载可执行代码，静态链就是整体作品。
- 核查席（kimi，报告被掐前的笔记 `reports/verify-partial.md`）补的两条：**GPLv2 双许可不改变结论**（`0e3a4144` 后贡献额外 GPLv2，但 GPLv2 §6 同样「不得施加进一步限制」，且只有部分作者同意回溯再许可，整体仍是 GPLv3）；理论上的 (d) 向 iSH 全体版权方要 Commons-Clause 兼容的例外——`LICENSE.IOS` 证明该项目集体授过例外，但贡献者众多，不现实；(e) 沙箱独立成**另一个 app**——许可上成立（MP 不链 GPL）、产品上不成立（iOS 无跨 app 的 shell 通道）。

**上架**：iSH 本尊在架（2020 年 2.5.2 风波后撤销，PLAUSIBLE 外部事实）；OpenMinis 在架且 `apk add` **完全不限制**、system prompt 还鼓励装包；`ITSAppUsesNonExemptEncryption=false`。审核风险判**中低**，前提是 GPL 合规（源码可得）。

## 6. 探针实证（本机构建 + bind mount 实验，`reports/probe-report.md` 635 行含原始输出）

**构建（这台 M 系 Mac，10 核）**：

| 步 | 结果 |
|---|---|
| macOS CLI 冷构建 | meson 7.2s + ninja 7.9s ≈ **11 秒**，`ish` 728KB，三 `.a` 1.02MB |
| Alpine 3.21 aarch64 rootfs | 下载 3.67MiB → fakefsify → 目录 **9.5MB**（`meta.db` 92KB）→ zip **3.8MB** |
| guest 首条命令 | `uname -a; cat /etc/alpine-release; ls /` **0.436s**（含冷启动+挂载+预热），第二次 0.020s |
| iOS 静态库 `build_ish.sh release` | **10.2s**，`libish.a` 545KB / `libish_emu.a` 446KB / `libfakefs.a` 22KB，`lipo`+`otool` 核实 **platform 2 (iOS) minos 14.0**，VDSO 2,960B **真构建**（非 stub） |

从零到 iOS 可链接产物**不到半分钟**——构建链不是战役的重头。

**bind mount 六步（harness = `main.c` 读 `ISH_BIND_*` 三个环境变量在 `xX_main_Xx()` 后调一次 `fakefs_bind_mount`；diff 在报告末）**：

| 问题 | 实测 |
|---|---|
| 宿主写 → guest 可见 | ✅ **同一进程内立刻可见**（readdir + 路径 lookup 双通道，无需重挂） |
| guest 写 → 宿主可见 | ✅ 立刻；宿主 owner `susu:staff` 真实用户、0644/0755，可直接编辑 |
| 中文文件名 | ✅ 双向无损（`笔记.md` 读、`来自guest.md` 写） |
| 只读 | **EROFS** 退出码 1，递归生效，对 guest root 有效，create/mkdir/append/truncate/unlink 全覆盖（与 `fake.h:18-25` 注释说的 EACCES+顶层 0555 不符，注释过时） |
| 逃逸 | ❌ guest 自造 symlink 在宿主只是 11 字节文本文件；相对 `../../..` 只到 guest 根；`ls /Users` ENOENT。**宿主真 symlink 指家目录，guest 列目录得空**（R13 反查 MISS 副作用把条目全跳掉了——是意外挡住不是设计；**按路径 `cat` 单个文件未测**，B 的代码判断仍成立，R5 保留） |

**⚠️ 最重要的运维发现——bind 持久化进 rootfs（新增 R16）**：`fakefs_bind_mount` 写进 `data/` 的 symlink 和 meta.db 里的挂载点行**随 rootfs 落盘**。实测：(1) 完全不注册的 run 里 `/mnt/lib` readdir 空但**按路径 open/read/write 全通**，宿主真多出文件；(2) 只要本次注册了任一 bind，旧的未注册 `/mnt/lib` 连 readdir 都恢复且**可写**——同一宿主目录，`/mnt/ro` 只读拒写、残留的 `/mnt/lib` 照写。**只读保护被同 rootfs 里的旧读写 bind 完全绕过。** 重新注册会刷新 mode，双向可逆。→ MP 宿主侧必须把 bind 表当**持久状态**管：每次 boot 先枚举清掉 `data/` 残留 symlink + meta.db 行，再按本次策略注册；否则上次授权过的目录下次悄悄保持可写。

**三条前提冲突（探针上报）**：① 第二发写的 harness 缺 `#define ISH_INTERNAL`（`fake.h:1-3` 闸门）编译不过，已在 main.c 内补；② **工具链缺 `lld`**——`vdso/arm64/meson.build:25` 硬编码 `-fuse-ld=lld`，brew `llvm` 不含 lld（独立 formula），CLI 硬失败、iOS 静默 stub VDSO；已 `brew install lld` + PATH 前置（超出「网络只 Alpine 镜像」红线，特此记账）——**任何复现机器都要装 lld**；③ `prepare_alpine_rootfs.sh` 在 fakefsify **之后**写 `/etc/resolv.conf`，meta.db 无 inode，**guest 里那个文件根本不存在**（对照 `/etc/apk/repositories` 因 tar 里原有所以可见）——印证「转换后往 `data/` 新建文件对 guest 无效，bind 路径除外」。

**网络**：guest DNS 走宿主解析器能解（拿到 fake-IP `198.18.0.4`，说明宿主有 VPN/代理），但 TCP connect `errno=4`(EINTR)，`apk add` 卡 60s 后**假成功返回 0** 什么都没装。根因（emulator socket 路径 vs 宿主 fake-IP 只在 tun 内可路由）本次未区分；**apk 退出码不可信**。iOS 真机上另测。

## 7. 两条腿关系图

```
                 ┌──────────── 脑（随便接）────────────┐
                 │ claude-proxy(家) / 云 API(出门) / 本地模型(未来) │
                 └──────────────────┬──────────────────┘
                                    │ MP 自己的 agent loop（ToolRegistry + 权限闸 + 8 轮）
            ┌───────────────────────┼───────────────────────┐
            │                       │                       │
   fs_* 文件库工具            run_command 工具            设备工具族
   （原生，两端）        ┌──────────┴──────────┐         （原生，两端）
                        │ macOS: Process()+zsh │ iOS: iSH guest（Alpine）
                        │ （零 iSH）           │  └ /mnt/library/<slug> = 文件库 bind mount
                        └─────────────────────┘

   cc-bridge（另一条腿，不动）：手机 → hub → tmux → 真 CC + Mac 真终端（SwiftTerm 同一 UI，加 TerminalBackend 缝后 guest PTY 可作第二后端）
   路由：hub 可达（enum）→ 真终端；不可达 → 口袋 Linux。挂点见 §3.3。
```

**CC 不进沙箱**：跑得起来跑不动（V8 jitless 逐条解释、RSS 与 MP 共存走钢丝、脑仍需联网）。08-24 已口头判定，本文钉死。

## 8. 分期提案（研究口径，不排期；工程量按 CC 工时）

| 期 | 内容 | 量级 | 依赖 |
|---|---|---|---|
| **0 拍板与量测** | 许可路线拍板（§5）；`DeviceInfoTool.residentMB()` 量 MP 稳态/导入峰值 RSS 基线；生词语料单归档回血 47.7MB（独立小刀，随时可做） | 天级 | 无 |
| **1 macOS 原生 `run_command`** | 工具 + `PermissionDomain.shell`（默认 askOnce）+ 折叠行加横滚/ANSI 剥离 + `Process()` 后端（抄 `CCHubProcess`）+ 超时杀进程组 | 2-3 天 | 0 拍板 |
| **2 iOS iSH 嵌入** | 三 slice 构建矩阵 + VDSO 断言；胶水移植（ISHKernel 本地化 / ShellExecutor 整搬 / RootfsManager 换 ZIPFoundation）；bridging header；rootfs 单归档首启解压；boot + fork guard；`run_command` iOS 后端；前台约束 UI | 1-2 周 | 1 |
| **3 文件库 mount** | 每楼层 `/mnt/library/<slug>`；R2/R13/R14 挂载点约束 + R8 busy_timeout + R12 预热 + R5 `resolve()` symlink + R10 名长 clamp + R11 哈希锁 + R7 串行队列；v1 禁 iCloud 楼层；change consumer 刷面板 | 1 周 | 2 |
| **4 终端 UI + 路由** | `TerminalBackend` protocol + guest PTY 进 SwiftTerm（本地 scrollback）；hub 可达性 enum + `sendCCFireAndForget` 回落口袋 Linux | 1 周 | 2 |

合计 **4-6 周**，战役级，**远线成立**。Phase 1 单独有价值（macOS 的 AI 拿到真 shell），且把工具/权限/渲染整条链在零 iSH 的情况下先跑通——是最便宜的验证。

## 9. 已核实事实账本（campaign 级，供后续 plan/对抗核查引用，不必重验）

- 编排者亲读：`fake.c:1019-1070` readdir 走宿主真目录 + 懒补 meta.db；`fake.c:342-374` `bind_mount_ensure_inode`；`ISHKernel.m:1381` change consumer；`fake.c:255-278` fs_context hook；`fake.c:99-106` 表结构。
- 抽查 C（5/5 对）：`shell_execute` 定义行、FIFO 删除注释、`MountedFoldersManager` 存在、fork guard 注释、governor 文档状态。
- 抽查 D（3/3 对）：defer 阈值、`forTool` 兜底、`isConnected` Bool。
- 抽查 A（3/3 对）：VDSO 空 stub、27 offload 注册、LICENSE.md:1。
- 抽查 B（4/4 对）：`link` 只查 dst、NAME_MAX 跳过、mount 表 memset、`utime` 直通。

**翻案清单（编排者的过时前提，来源 = OpenMinis 自己过时的 `docs/specs/ios-sandbox-ish-summary.md`，教训 = 旧文档「事实」必须降级为假设再转译）**：`execute_command`→`shell_execute`；FIFO 串行→全并发；prompt 正则→进程退出+EOF；100KB→15k/30k 字符；10 分钟抢占→死代码，实际 900s per-command；PTY→stdin 管道；`os_proc_available_memory`+400MB→phys_footprint fork guard；「10k 用户在主 README」→在 fork README；「symlink 指绝对路径」→相对路径且非热路径；「hub 可达性在 AgentBridge」→`CCBridgeWebSocketClient`；「defer 阈值算内建」→只算 MCP；「Debug 215MB」→104MB 是 debug.dylib。

## 10. 粟粟已拍 —— ✅ 2026-08-25

1. ✅ **许可路线 A**：去掉 Commons Clause，整体 AGPL-3。AGPL 本身已够硬，去掉利于社区+解锁口袋 Linux
2. ✅ **读写**：mount 就要能用不是能看；串行队列+短命写者纪律兜风险
3. ✅ **iCloud 楼层 v1 不挂**：占位符坑太深，本地楼层先跑通
4. ✅ **每楼层独立挂载点**：`/mnt/library/<slug>`，切楼层不 remount 不串味
5. ✅ **askOnce**：每对话首次弹卡问一次，够用
6. ✅ **Phase 1 先单独走**：不碰 GPL，2-3 天，macOS API 模型拿到真 shell，先验证整条链
