# Plan：离线沙箱 Phase 2 —— iOS iSH 后端 + 文件库 mount

> ⚠️ **DON'T IMPLEMENT YET** — 等粟粟 ⧫ 批注后按 go 执行。
> 上游：`docs/research-离线沙箱.md`（粟粟 08-25 六条已拍：A 去 Commons Clause / 读写 / iCloud v1 不挂 / 独立挂载 / askOnce / Phase 1 先走）+ `docs/plan-离线沙箱-phase1.md`（macOS `run_command` 已落地并 master）。
> 侦察报告：`docs/prompts/2026-08-25-sandbox/reports/{A,B,C,D,probe}-report.md`。本 plan 不重复 research，只把「做什么、按什么顺序、验什么」钉下来。
> 批注约定：⧫=粟粟，`<⧫> </⧫>` 内为粟粟标注。

## 0. 完成标准（DoD）

iPhone 上同一个 `run_command` 工具能在 app 内的 Alpine guest 里跑命令（无 Mac、无网络也行）；guest 里 `/mnt/library/<楼层>` 就是当前楼层文件库，两边读写互见；askOnce 弹卡 / 权限页行 / 停止杀树 / 超时 / 输出截断与 macOS 同语义；rootfs 随 app 打包首启解压；661+ 测试绿、双端 build 绿；粟粟真机清单 §5 全过。

## 1. 冻结的设计决策

### 1.1 许可（前置，不动代码）
- 粟粟已拍 **A**：mneme-atrium 去 Commons Clause，整体 AGPL-3 无附加条款。**Phase 2 第一个 commit 之前**要落地：改 `LICENSE`、README 许可段、加 `THIRD_PARTY_LICENSES.md`（iSH GPLv3 + LICENSE.IOS 例外 + Alpine 包聚合）。私有仓 MP 补一份同款 LICENSE（现在没有）。<⧫>code 爸比改，Phase 2 首 commit 前落地</⧫>
- `deps/ish` 作为 **git submodule** 指向 `OpenMinis/ish-arm64`（我们不 fork 它，先跟着走；要改的只有 `main.c` 这类探针，不进产品）。

### 1.2 构建链（A §1-2 + 探针实证）
- `scripts/build-ish.sh <platform>`：从 OpenMinis `deps/build_ish.sh` 改——参数化 SDK（`iphoneos` / `iphonesimulator`），输出 `deps/libs/<platform>/{libish,libish_emu,libfakefs}.a` + `deps/include/ish/`。**必须断言 `libvdso.so.elf` 非零**（找不到 lld 时上游静默 `touch` 空文件）。前置工具：meson / ninja / llvm / **lld** / libarchive（`brew`），脚本开头自检，缺一个直接失败不降级。
- `scripts/prepare-rootfs.sh`：从 `prepare_alpine_rootfs.sh` 改——去掉 Minis 品牌（motd / PS1 / 浏览器 wrapper / minis-mcp-cli），`/etc/resolv.conf` 在 fakefsify **之前**写（上游在之后写，guest 里看不见——探针实证）；用 `python3 zipfile` 打包（macOS `zip` 不设 UTF-8 flag，老教训）；产物 `deps/resources/alpine-rootfs.zip`（实测 3.8MB）。
- `project.yml`：iOS target 加 `HEADER_SEARCH_PATHS`、`OTHER_LDFLAGS` 走 **`.a` 完整路径**（按 `$(PLATFORM_NAME)` 分目录，上游 `AppARM64.xcconfig` 同款，绕 xcodegen 依赖推断）、`- sdk: libsqlite3.tbd` / `libresolv.tbd` / `SystemConfiguration.framework`、`SWIFT_OBJC_BRIDGING_HEADER`、rootfs zip 作 `type: file, buildPhase: resources`（**不能当目录打包**，Xcode 会平铺）。macOS target **不链**。
- 所有 ObjC 胶水放 **`Sandbox/ish/`**（新顶层目录，只挂 iOS target 的 sources），不进共用的 `MemoryPalace/`——避免两端无差别编译。

### 1.3 胶水移植（A §4）
| 文件 | 处置 |
|---|---|
| `ISHShellExecutor.h/.m` | 整搬（零 Minis 依赖）——`run_command` iOS 引擎，非交互管道，逐行回调 + exit code |
| `CurrentRoot.h/.m` | 整搬（RootfsPatch 覆盖层） |
| `ISHKernel.h/.m` | 搬 + 手术：删 27 个 offload import/注册、DNS 路径改 App Group 外的 `Library/MemoryPalace/sandbox/dns`、去 `MinisChat` 字串；保留 boot 序列 / fork guard / JIT crash handler / bind mount API / change consumer / path hook；**CPU governor 与后台保活不搬**（MP 已判不学静音音频，长命令前台跑） |
| `RootfsManager.swift` | 搬 + 换 logger + ZIP reader 换 ZIPFoundation；安装位置 `Library/Application Support/MemoryPalace/sandbox/rootfs/`（不放 Documents——那是文件库的家，且 `.mpb` 全量备份会扫 Documents）；`isExcludedFromBackup = true`；reset = 标记 + 提示重启（`become_first_process` 不可逆） |
| `Terminal/*` | 不搬（Phase 4 用 SwiftTerm） |
| bridging header | 新写 `Sandbox/ish/MemoryPalace-Bridging-Header.h`：`ish/ish.h` + `fs/devices.h` + 两个胶水头 |

### 1.4 `run_command` 双后端
- `RunCommandTool` 拆成 **协议 + 两实现**：`RunCommandBackend { spawn(command, cwd, env) → handle; wait/collect; killTree }`，macOS = 现在的 posix_spawn 实现，iOS = `ISHShellExecutor`。`clean` / `truncate` / `Bounded` 收集器 / envelope / 注册表 / cancel 抽到共享层（QA 席点名别让第二个后端复制这些）。
- iOS 契约差异（明写进工具描述，按平台分文案）：cwd 默认 `/mnt/library/<slug>`；`cwd` 相对路径按它解析，绝对路径只允许 guest 路径；超时上限同 600；**app 必须在前台**——切后台 ~30s 系统会杀掉 guest shell（不做保活），工具结果会报 `cancelled`，systemHint 明说。
- 文案：iOS 后端**可以叫「沙箱」**（这才是真隔离）；`PermissionDomain.shell.summary` 按平台分：macOS「在这台 Mac 上运行命令」/ iOS「在 app 内的 Linux 沙箱里运行命令（不能碰沙箱外的东西）」。权限页行 iOS 露出。
- `cancelAssistantTurn` 里 `RunCommandTool.cancel` 的 `#if os(macOS)` 去掉（codex 评审纠正过：现在是平台包着的）。
- 环境：guest env 只给 `PATH/HOME/TERM/LANG/TZ` + 上游那批 workaround（`OPENSSL_armcap=0` / `GODEBUG` / `GOMAXPROCS=2` / `PYTHONMALLOC` / node 的 `--jitless`）——**不注入任何 MP 密钥**（Minis 把 Keychain 密钥灌进 guest env 是反面教材）。

### 1.5 文件库 mount（粟粟拍：读写 / 独立挂载 / iCloud v1 不挂；B 报告 R1-R16 处置）
- 挂载点 `/mnt/library/<slug>`（每楼层独立，R1/R15），宿主侧 = `FileLibraryStore.filesystemRoot(profileId:)`——**只挂 `filesystem/`**，`.memorypalace/` 天然在外（R14）；代码里断言挂载源就是这个函数的返回值，不给参数化。
- 挂载时机：会话首次调用 `run_command` 时按 `conversation.profileId` 挂（与 AI 工具同源，R15）；已挂的楼层不重复挂；总数受 `FAKEFS_MAX_BIND_MOUNTS=32` 约束（楼层通常个位数）。
- **boot 时先清残留**（R16 探针实证 bind 持久化进 rootfs）：枚举 `data/mnt/library/*` symlink 与 `meta.db` 里 `/mnt/library/` 前缀的行，全删再按本次策略注册；只读/授权状态永远以宿主为真相源。
- iCloud 楼层：`FileLibraryStore.iCloudEnabled && iCloudFloorsRoot() != nil` 时**不挂**，`run_command` 的 cwd 回落 `/root`，工具结果里说明「iCloud 楼层暂不能挂进沙箱」（R4）。
- 固定挂载点目录在 `installIfNeeded` 阶段建好且约定为空（R2）；bind 前 `lstat` 落点，非空真实目录拒绝挂（不让 C 层静默 rm -rf）。
- 不用 `read_only` 模式（R3 硬链接穿透）——粟粟拍的就是读写。
- Swift 侧写 `meta.db` 的两处（`ensureParentDirsInMetaDB` / 清残留）加 `sqlite3_busy_timeout(3000)` + 检返回值（R8）。
- 挂载后台预热：拿 `FileLibraryStore.list()` 结果单事务批量塞 `meta.db`（R12，抄 `batchEnsureFakefsMetadata`）；挂载点名字不带 `minis`。
- 宿主侧顺手补三处（与挂不挂都该修）：`FileLibraryStore.resolve()` 补 `resolvingSymlinksInPath`（R5）；建文件时文件名 clamp 255 字节（R10）；面板/编辑器冲突检测从 mtime 改内容哈希（R11）。
- `FileLibraryStore` 加进程级串行队列（R7，对现存并发写也有益）；guest 写事件走 `fakefs_install_change_consumer` → post `.fileLibraryDidChange`（面板刷新）。
- R6（`.atomic` 换 inode）/ R9（guest symlink 变怪文件）：文档化，不修。

### 1.6 内存 / 前台
- 搬 fork guard（阈值 = 物理内存 1/4 clamp [500MB, 2GB]）；boot 前后用 `DeviceInfoTool.residentMB()` 各量一次写 `[PROBE]` 日志，真机三台数据进 review。
- app 切后台：不保活；正在跑的命令收到 SIGKILL 后按 `cancelled` 报；UI 在命令跑时顶部给一条「命令在跑，别切走」的小提示。<⧫>要</⧫>
- **保活/后台 Phase 2 不做，Phase 3 用灵动岛（Live Activity）做**——粟粟：那是正当的保活理由，比静音音频好。Phase 2 只在前台跑、切后台按 `cancelled` 报。
- 崩溃隔离是信号级：`ISHKernel` 的 `jit_crash_handler` 必须在 boot 最先装；guest 线程崩溃只挂起该线程。

### 1.7 本期不做
终端 UI 复用（Phase 4）/ 无 Mac 回落路由（Phase 4）/ apk 网络装包的可用性保证（探针在 Mac 上 apk 假成功，真机另测，先不承诺）/ iCloud 楼层挂载 / 「运行」面板 iOS 版（数据源换 guest 进程表，Phase 4 一起）。

## 2. 分期与 todo

### T0 · runway 探针（粟粟 08-26「现在就跑」→ 08-26 01:20 发车：opus5 独立 worktree `sandbox-t0`，prompt `docs/prompts/2026-08-26-sandbox-t0/probe-t0.md`）
- [x] `scripts/build-ish.sh iphonesimulator` + `iphoneos` 两份 `.a`（含 VDSO 非零断言）✅ 4.5s / 2.8s，各 1.03MB，VDSO 2960B，负向测试（藏 lld）硬失败
- [x] `project.yml` 链接面落地（只 iOS target），bridging header，xcodegen 过 ✅ 零链接错误；A 报告三个未验语法点全 CONFIRMED；**必需宏 `ISH_INTERNAL=1 GUEST_ARM64=1`**（A 报告说是文档臆造——错，上游 pbxproj 里有）
- [x] 模拟器 boot ✅ 6.6ms，`Linux … 4.20.69-ish … aarch64`，Alpine 3.21.0；真机 Air ✅ 12ms（iPhone 14 unavailable 回落）
- [x] RSS ✅ boot +6~10MB；boot+两条命令后常驻 **+5MB**（对照组实证，先前看到的 +100MB 是 MP 自己启动）；热命令固定开销 ~207ms/条（iOS 后端延迟基线，比 macOS 高一个量级）
- **判定：不重排。** T0 报告 `sandbox-t0` 分支 `docs/prompts/2026-08-26-sandbox-t0/reports/t0-report.md`（1.5 小时，估 1-2 天）
- 带进 T1/T2 的账：① `CurrentRoot.m` `FsApplyOverlay` nil URL 守卫（MP 不打包 RootfsPatch.bundle → 上游必崩，已修 6 行，**T2 不能丢**）② `build-ish.sh` 的 `ISH_DIR` 现在指 refs 临时目录、`deps/libs` gitignore、无 preBuildScript → 干净 clone iOS build 必炸，**T1 第一件事**换 submodule + preBuildScript ③ 新 worktree 跑 iOS build 前要 `bun install`（cc-bridge 产物是 macOS target 的 spec 校验前置，与 ish 无关）④ **Air 真机和 Air 模拟器现在是 `sandbox-t0` 的 Debug 包**，下次验 master 前重装 ⑤ `simctl install` 每次换数据容器会重新解压 rootfs（真机不会），首启 UI 别按模拟器定预期

### T1 · 构建与 rootfs（08-26 02:40 发车：T0 同一 worker 续命，`sandbox-t0` 分支，master 基线；T2 等 master 合完 device-tools 再合进来）
- [x] `deps/ish` git submodule 钉 `19c690c`（嵌套子模块一个不 init，逐条查过依据）；`ISH_DIR` 指仓库内；preBuildScript 增量（删光 `deps/libs` 自造回 1:39，再 build 4.8s 秒过）；**干净 clone 全链路 BUILD SUCCEEDED**（clone 32s → rootfs 13s → xcodebuild ~17min 全新 SPM）✅
- [x] `prepare-rootfs.sh`：配置写在 fakefsify **之前**（解 tar → staging → 重打 tar，uid/gid 钉 0）、去 Minis 品牌、python zipfile；meta.db 路径集只多 `/etc/resolv.conf` ✅ 双端 `cat /etc/resolv.conf` 实证有内容
- [x] `RootfsManager` 680→182 行：ZIPFoundation / Application Support + excludedFromBackup / staging 整体 move / `isInstalled` 查 meta.db / `applyDefaultMountOverlay` 与 SQLite 直写不搬 ✅
- [x] 懒启动 `SandboxRuntime.ensureReady()` 串行幂等（真机首次 424ms / 二次 0.38ms）+ 顶部薄荷绿提示条（截图 `t1-banner.png`）✅
- T1 报告 `sandbox-t0` `reports/t1-report.md`（7 commit，`e5263aac`）。留给 T2：`scripts/bootstrap-sandbox.sh` 一条命令拉齐 rootfs+两平台 `.a`；`.gitmodules` 去 `branch` 字段只留 SHA（`--remote` 会静默推到 tip）；`didResetWhileBooted` 要有消费方（起 guest 前查 → 「请重启 app」）；DEBUG 的 `holdForProbe()` 收口删。**坑**：`devicectl launch -- -flag 1` 参数进 `ProcessInfo.arguments` 不进 `NSArgumentDomain`，靠 `UserDefaults` 读的调试开关静默不跑

### T2 · 胶水移植 + 后端协议（08-26 04:00 发车：同 worker；先把 `origin/worktree-device-tools` 合进 `sandbox-t0` 拿到 Phase 1 的 run_command，不等 master）
- [x] `ISHKernel` 手术版 + `ISHShellExecutor` + `CurrentRoot` 进 `Sandbox/ish/` ✅（T1 已落，T2 核过 `FsApplyOverlay` nil 守卫没丢）
- [x] `RunCommandBackend` 协议 + macOS/iOS 两实现；共享层抽出 ✅ `ce65abc1`（`MacShellBackend.swift` / `Sandbox/ish/ISHShellBackend.swift`，共享层留 `RunCommandTool.swift`）
- [x] iOS `run_command` 跑通 echo / 非零退出 / 超时杀树 / 停止 / 截断 ✅（仓库无 iOS 单测 target，改用 `SandboxProbe` 八场景：模拟器 + iPhone Air 逐条一致，稳态 214–234ms；探针第一跑抓到 **wait status 被当退出码**的真 bug → `92fb5c5a` 逐位解码）
- [x] 权限行 iOS 露出、文案按平台、`cancelAssistantTurn` 去 `#if` ✅（macOS 文案反向锚断言不许出现「沙箱」；guest 环境 12 项白名单不继承 app env，`TZ` 用 POSIX 反号 `LCL∓h`）
- 三绿：`Executed 668 tests, with 0 failures` / iOS BUILD SUCCEEDED / 双端探针。报告 `docs/prompts/2026-08-26-sandbox-t0/reports/t2-report.md`（08-26 05:30 完成，中途撞 session limit 一次续命）。
- T2 留下的（进 T3/T4）：切后台 30s→cancelled **未真机复现**（T4 实测）；`lineCallback` 全在主队列，极端形状（`yes | head -200000`）T4 前量一次；`didResetWhileBooted` 无 UI 出口；iOS cwd 不做 containment，挂上文件库后重审；cc-bridge `bun install` 债仍在（T2 靠源码哈希相同软链主 worktree 产物绕过，换机器不成立）。

### T3 · 文件库 mount（按额度墙切三段，每段 ≤1h、每项 commit+push）
- ~~T3a~~ ✅（05:45 发车 → 06:12 完成，26 分钟 4 commit `05e4b62e`，668 测绿 / iOS 绿 / 模拟器五场景）
  - [x] 空 `mnt/library/` **必须走 `prepare-rootfs.sh` staging tar → fakefsify**（安装后 mkdir 没 inode，guest 看不见；与 T1 `resolv.conf` 同坑）`30a92b61`；顺带补 `.rootfs-version`(v2) 闸（T1 只比 `.arch`，改 rootfs 结构不重装）
  - [x] `SandboxMount.cleanResidue`：boot 后、任何挂载前；只删 `data/mnt/library/*` 的 symlink（真目录保留告警）+ meta.db `/mnt/library/` 前缀 paths/stats 行；**不删 `/mnt/library` 自己**（bind 要父目录在 meta.db）；两处 `busy_timeout(3000)` + 检返回值 `0ab3d964`
  - [x] `mount(profileId:)`：源 `assert == FileLibraryStore.filesystemRoot()`（private→internal 零语义）；lstat 非空拒挂；不重挂；上限 32；读写。slug 自派生：**不用 `floorSlug`**（可能中文且可改名）、**不用 `hashValue`**（每进程加盐→上次挂载变清不掉的残留）
  - [x] iOS cwd 语义定稿：默认 `/mnt/library/<slug>`，相对按它解析，绝对原样放行**不做**宿主式 containment——guest 命名空间是边界（探针 6A/6B 双向实证出不去），边界在「挂了什么」
  - [x] iCloud 楼层 `.skippedICloud` → cwd 回落 `/root`，新增 `resultNote(profileId:)`（协议默认空实现）写进 envelope `note`；⚠️ **PLAUSIBLE 未实测**（探针环境 `iCloudEnabled == false`）→ T3b 手开开关验
  - [x] 五场景全过，残留清理有两轮对照硬证据（run A 尾宿主留 2 条 symlink → run B 头 `ls /mnt/library` 数出 0）`28d5160e`
  - 顺带发现：`FileLibraryStore.floorSlug` 兜底 `楼层-<前8字母数字>` 会碰撞（代码层 CONFIRMED；orchestrator 核：`Profile.id` 是 UUID，前 8 hex 碰撞 ~1/4e9 每对，**产品层风险极低**，worker 撞的是自己起的 `probe-floor-a/b`）→ T3c 顺手让兜底走 `uniqueSlug` 去重，不抢优先级
  - 方法论：两个坑都是**验证路径和被验证行为共用副作用**（残留检查自己触发了挂载）——写探针先问「这条检查会不会改变它要测的状态」
- ~~T3b~~ ✅（06:08 发车 → 06:41 完成，4 commit `5a3413ef`，668 测绿 / iOS 绿 / 模拟器 + Air 逐条一致）
  - [x] 预热落地（单事务批量，`ish_stat` 16B 4×LE u32 核过真库，210 条 10-17ms 异步失败只记日志）`f34c8672`——**但 200 文件规模无可靠收益**：模拟器 233(冷)/237(热) ms、Air 290/233；首次量出的 -31% 全是 asbestos JIT 冷启动混进「冷」那次（本进程第一条 guest 命令），加一条丢弃命令吸收后翻转。代码留着，**别声称有收益**；T3c 在 2000+ 文件重测，无收益就删
  - [x] change consumer：`SandboxChangeBridge`（ObjC 薄壳，handler 是 block 且 struct 含 `char[1024]`）+ Swift 200ms 时间窗合并 → post 现有 `.fileLibraryDidChange`；证据：一条命令连写 20 文件 → 原始事件 21 条 / 通知 1 次 / ring 丢弃 0，两端一致
  - [ ] iCloud 分支 **仍 PLAUSIBLE**：两端 `iCloudFloorsRoot()` 都 nil（容器未就绪）→ 条件 false 走正常挂载，`.skippedICloud` 从未被执行；要验需 iCloud 容器就绪的设备，worker 没为测试改产品判定（对）→ 留粟粟真机清单
  - [x] 逃逸矩阵 `fca60aef`：E1/E2/E4 非逃逸（guest 造的 symlink 在宿主上只是普通文本文件；`../..` 止于 guest 根）；E3 硬链接跨挂载点成功（R6 家族，已文档化不修，生命周期问题非越权读）；**🔴 E5 真发现**：宿主侧放进 `filesystem/` 的真 symlink `peek → ../.memorypalace`，guest `ls peek/` 空但 `cat peek/secret.md` 读出内容（readdir 不跟随 / lookup 跟随的不对称，与 T0 探针 6C 同源）
  - [x] Air 真机重跑 `30721b11`：mount/预热/节流/逃逸四面与模拟器逐条一致（首跑 E3 `No such file` 是探针素材依赖 T3a 遗留文件，改自带素材后一致）
  - **E5 处置（待粟粟拍）**：R14「只挂 `filesystem/`，`.memorypalace/` 天然在外」有个没写的前提——`filesystem/` 里没有指向外面的真 symlink。guest 自己**造不出**这种 symlink（E1/E2 证），所以不是「AI 自己越狱」，必须宿主侧动作（Files.app 放的、同步工具建的）。本质 = R5（`resolve()` 缺 `resolvingSymlinksInPath`）在沙箱侧的同一个洞 → 建议归 T3c 宿主三修一起修，**修宿主侧**（挂载时扫一遍拒绝/剥离指向库根外的 symlink + `FileLibraryStore` 写入时拒）比让 fakefs 不跟随更彻底
- T3c（粟粟 06:30 拍先不派 → 11:04 「继续可以派」发车，同 worker 续命；每条修法配 macOS 单测）
  - ~~T3c~~ ✅（11:04 发车 → 11:25 完成，23 分钟 4 commit `df8ef4df`，**680 测绿**（668+12 新锚 `FileLibraryHostFixesTests`）/ iOS 绿 / E5 端到端复验）
  - [x] R5 `resolve()` 先 `resolvingSymlinksInPath` 再判 containment——**root 和 target 两边都解**（否则 macOS `/var→/private/var` 单边对不上）；所有读写口都过 `resolve()`，一处堵七个入口 `9280c7be`
  - [x] E5 两道：(a) `SandboxMount` bind 前 `escapingSymlinks` 全库扫，越界 → `.refusedSymlinkEscape(paths:)` 拒挂、cwd 回落 `/root`、`resultNote` 列违规相对路径（不自动删改用户文件）；(b) 写入口 `validateNotSymlink` 拒把 symlink 当普通文件覆盖；端到端 `eb1b4d24`：扫出 `["peek"]` → 拒挂 → envelope `cwd:"/root"` + `note` 全文（**真进 envelope 不只是日志**）→ 删 peek → 挂成
  - [x] R10 255 **UTF-8 字节** clamp，grapheme 边界、保扩展名；300 字中文名真落盘、组合 emoji 不切出 U+FFFD
  - [x] R11 冲突检测 mtime → SHA256（CryptoKit 无新依赖），纯函数 `hasExternalConflict`；`FileEditorSheet.onSave` 签名 `Date?`→baseline 内容，**第二消费方 `TopicBox/TopicCardSheet` 是编译器逼出来的**
  - [x] R7 串行队列：写全过队列、读不排；`edit` 读-改-写整体入队 → 拆 `writeLocked` 内部变体（`sync` 嵌套会死锁）；锚：50 并发写同一文件终态完整等于某一次 payload
  - [x] `floorSlug` 兜底走 `uniqueSlug`，不迁移存量
  - [x] 预热 2000 文件重测：冷中位 411ms vs 热 466ms，分布重叠方向偏负 → **删 `warmMetadata` 全套** `9f0f42ea`（change consumer + SQLite 小工具保留，`mount()` 留注释钉数字防再加）
  - **取舍待粟粟知晓**：E5 是**全库拒挂**粒度——一个越界 symlink 让整楼层挂不上；安全上对（宁可不挂），但用户库里长期有这种链接沙箱就一直不可用。「跳过违规路径挂其余」要 path hook（bind 是整目录），复杂度高一量级，未做，T4 观察真实使用再定
  - 债：`escapingSymlinks` 每次挂载全树扫，万级文件库有可感延迟，成瓶颈再缓存
  - [ ] review 文档写清 `mounted` 进程内表 vs rootfs 持久 bind 双轨（表空≠没挂，真相源 rootfs，每 boot 清一遍）；`cleanResidue` 只清 `/mnt/library/` 前缀，将来别的 bind 走同根或扩清理

### T4 · 收口（12:12 发车，同 worker 续命；加：切后台复现 / lineCallback 极端形状 / 重置沙箱按钮 / 合 origin/master 进 sandbox-t0 只合不推 / review 三块 + §四 真机清单）
- ~~T4~~ ✅（12:12 发车 → 12:39 完成，28 分钟 5 commit `ef15bf86`，680 测绿 / iOS 绿 / 探针冒烟；**合 `origin/master` 33 commit 进 `sandbox-t0` `ddd568d4`，代码零冲突**只 NOW.md 戳）
- [x] fork guard **本来就在**（T0 搬 `ISHKernel.m` 时保留，1/4 RAM clamp [500, 2048]MB，boot 第 6.5 步装）；RSS 三点：模拟器 233→238→374MB，**Air 90→97→208MB**——boot +5/+7MB 可信，「第一条命令后」那跳混着 MP 自身启动增长；真机稳态离天花板 10 倍 `3f4bb919`
- [ ] **前台提示 ❌ 没落地（orchestrator 08-26 18:40 纠正）**：worker 报告和 `3f4bb919` 的 commit message 都说做了，但 diff 里 `SandboxStatusBanner.swift` 只加了一行 `.animation(value: RunCommandMonitor.shared.running.count)`，`bannerText` 仍只有 installing/booting/failed 三态，整棵树 grep 不到「别切走」；codex 模拟器 QA 在 `sleep 20` 窗口内截图实证顶部无提示条（BUG-4）。「没截到图」其实是没东西可截。**明天补**：`SandboxStatusBanner` 加「相位就绪 && `running` 非空 → 命令在跑，别切走 + terminal 图标」分支（`running` 是 @Observable，body 里显式读才订阅——P1 askOnce 卡同坑），模拟器 `sleep 20` 窗口截图为证
- [x] **🔴 切后台实测推翻 T2 说法** `65f92470`：Air 锁屏后**整个 app 被挂起，`sleep 90` 到 180s 仍未返回、进程没被杀——命令原地冻结**（既不完成也不报错）；模拟器完整跑完 90.3s exit 0，**不具代表性**。工具描述 + `systemHint` 已按实测改写；「回前台续跑/超时/永挂」没验成（Air 锁着 devicectl 报 Locked）→ **真机清单第 8 条 + Phase 3 保活设计前提**（review §2.1 第一条）。债：`ISHShellBackend.swift:9` 文件头注释仍是旧说法，下次顺手改
- [x] `lineCallback` 极端形状**触发阈值已改** `881d9030`：`yes|head -200000` 改前 1.48s / 主线程心跳 6%（饿 1.4s 超 1s 线，根因逐行 `dispatch_async` = 20 万主队列 turn）→ 按读块批量交付 0.47s / 22%（-68%）；`seq 1 200000` 48% 不变（本就无压力）。worker 自我更正：`65f92470` message 写「没超 1s 不改」是看错数，`881d9030` 纠正
- [x] 重置沙箱按钮：设置 → 文件库 → 沙箱区 `#if os(iOS)`，`RootfsManager.reset()` + 二次确认，文案「删除沙箱内所有文件并恢复初始状态，重启 app 后生效。」
- [x] `docs/review-离线沙箱-phase2.md` 三块 + §四 真机清单 12 条；review 补记 T3 漏的并发风险：**guest 写 ↔ 宿主写无跨进程锁**（`writeQueue` 管不到 guest，两边同写同一文件丢一边，各自原子不写半截）
- [x] NOW.md + 项目卡（orchestrator）
- [ ] **粟粟 08-26 13:55：「沙箱」区藏在文件库页最底下鬼看得见 → 明天弄显眼**（候选：设置根列表独立「沙箱」入口 / 文件库页提顶 / lite 是否露一起拍）；模拟器实测她翻到底才找到

### T5 · codex 模拟器端到端 QA 回灌（08-26，对话方 claude-p × codex computer-use；报告 `docs/prompts/2026-08-26-sandbox-t0/reports/codex-qa-phase2-sim.md`，两次撞 codex 账户墙 13:32 / 18:25，第三段 23:08 cron 续 9-11）
- 1-6 ✅：claude-p Bonjour 一键添加 / **垫片真调 `run_command`**（Alpine 真输出、cwd `/mnt/library/default-workspace`）/ 权限页行 + 沙箱文案 / 文件库双向且面板**不用手动刷新**就出现 guest 写的文件 / 中文名双向 / 切楼层不串味
- 7 ❌ BUG-4 前台提示条不存在（上面已纠正为未落地）
- 8 ❌ BUG-5 **claude-p 文本 function-calling 垫片不稳定**：`sleep 60` 那轮把 `<tool_call>{…run_command…}</tool_call>` 当普通文本吐进气泡，工具没执行——归 `~/claude-proxy` 垫片（同 provider 其他轮正常），不是沙箱；切后台实验因此没做
- BUG-1 **新加 provider 继承「启用预算限额」但额度 $0.00**，首发被预算闸拦——app 默认值问题，明天看
- BUG-2 展开第二张工具卡后模拟器 AX 树 0×0，Home→唤起落空白新对话**丢未发送草稿**——AX 归模拟器/idb，草稿丢失是否 app 的事待查
- BUG-3 重启 app 后首条命令那轮显示「（已停止）」：文案只有 `cancelAssistantTurn` 会写（`ConversationViewModel.swift:1774-1799`），非 provider 错误；复现一次未再现，触发源未定（嫌疑：刚启动那几秒的楼层/会话切换走了 cancel）
- 第三段 23:08 → 23:43 正常退出（未撞墙），报告 188 行 + 61 张截图定稿
- 9 ❌ **BUG-6 重置后契约缺失**：重置动作本身 ✅（设置页「已重置，请重启 app。」）；但重启前跑命令报 **`CwdError`** 而非约定的「沙箱已重置，请重启 app」（**真根因 orchestrator 核定**：`ISHShellBackend.prepare()` 其实先查了 `didResetWhileBooted` 并抛 `CwdError(message: "沙箱已重置，请重启 app")`（`:26-27`），但共享层 `RunCommandTool.swift:65` 用 `error.localizedDescription` 转 `not_available`，而 `CwdError` 是裸 `struct: Error`（`:119`）没实现 `LocalizedError` → 描述退化成「…CwdError error 1」，文案丢失；修法一行：`CwdError: LocalizedError { var errorDescription: String? { message } }`）；重启后 askOnce 点允许却收「命令执行请求超时未获确认」（只出现一次未重试，PLAUSIBLE，明天复现）；「正在准备沙箱…」launch 0-1.3s 没截到——**orchestrator 不认这条**：T1 是懒启动，横幅在第一条命令触发 `ensureReady` 时才闪几百 ms，review §四 第 1 条「打开就闪」的描述本身写错了，改 review 不改代码
- 10 ⚠️ 模拟器没登 iCloud，开关按不开（「iCloud 不可用：请确认已登录…」），`.skippedICloud` 分支**依然没人跑过**——只能粟粟真机
- 11 ✅ TopicCardSheet：普通保存 + 外部修改冲突（横幅「文件已在外部修改…」+ 保存拒「请关闭重开后再保存」）都对，补上了 T3c 的 D3 实证空洞
- 12 跳过（模拟器无飞行模式）
- codex 对作者自评的出入表：7/9 明确失败，8 无可比结果，1 替代路径未验（真正删 app 重装首启没做），其余无出入；并指出 review `:55`「冻结期间 UI 一直显示命令在跑」与截图冲突（同 BUG-4 根因）
### T6a · QA 回灌修复第一段 ✅（08-27 03:16 发车 → 03:45，新 opus5 worker 自建 worktree 开 `sandbox-t6a` 基于 `ef15bf86`，5 commit `02896f18`，**685 测绿**（+5）/ iOS 绿 / 提示条截图实证；`sandbox-t0` 已快进到同一点）
- [x] BUG-4 提示条真做：判定抽纯函数 `SandboxBanner.content(phase:runningCount:)`（`MemoryPalace/Services/DeviceTools/SandboxBanner.swift:50-58`，`SandboxPhase` 一并搬进共用 sources 让 macOS 锚得住）；banner `@State monitor = RunCommandMonitor.shared` + body 显式读（`SandboxStatusBanner.swift:19,23`）；探针新 mode `-sandboxProbe long_command`；截图 `shots-t6a/01-running-t{3,9,18}s.png` 顶部有条、`02-after-done.png` 自动收 `c836ffaf`
- [x] BUG-6 `CwdError: LocalizedError`（`RunCommandTool.swift:122-125`）；锚走 `any Error` 存在性派发；全仓 6 个自定义 Error 审过，5 个本来带，`ElevenLabsError` 消费方 `as?` 取字段非同类 `558932fb`
- [x] 设置根「ish沙箱」（`SettingsView.swift:33` case / `:133` 紧贴文件库下同组同 guide / `:202` 目的地 / macOS 穷举 switch 补空分支 `:375` + 横向 tab bar 过滤 `:285`）；新页 `Sandbox/ish/SandboxSettingsTab.swift`（状态 + 重置，从文件库页搬走）；lite 未露；截图 `20-settings-root.png` / `21-sandbox-page.png` `2587d03c`
- [x] review §四 ① 改懒启动 + `:55` 改「挂起期间 UI 不刷新，回前台提示条继续到命令真返回」+ 第 9 条路径改「设置 → ish沙箱」；`ISHShellBackend.swift:9` 头注释 `1cc1826e`
- worker 提的四个决策：① **测试命令是 `-scheme MemoryPalaceTests`**（`MemoryPalace` scheme 没 test action）→ 写进 NOW.md 纪律 ② `CwdError` 一型两义（沙箱不可用 / 参数非法）→ 记债不拆 ③ **iOS 没单测 target 在收利息**（这次靠把判定挪进共用 sources 绕，只对不依赖 UIKit/ObjC 的逻辑有效）→ Phase 4 前粟粟拍 ④ 新页「已挂载楼层」是进程内表，冷启动进设置永远 0 → T6b 改文案「本次启动已挂载」
- harness 坑：前一位无 isolation 的 subagent `EnterWorktree(path)` 守卫不跟走、git 全挡 → 已记编排怪癖表 + feedback 草稿；跨天续 worker 用 `isolation: worktree` + 自开分支

### T6b · QA 回灌第二段 ✅（08-27 03:50 → 04:06，同 worker `sandbox-t6a`，3 commit `478ed2cd`，**691 测绿**（+6）/ iOS 绿；`sandbox-t0` 已快进）——**三条 codex 归因全不准，真根因各不相同**
- [x] **BUG-1 真根因不是 per-provider 预算**（没有这回事，`GlobalBudgetStore.swift:3-10` 粟粟 04-23 决策一份总账）：`enabled` 默认 true（`:26-30`）+ `budgetUSD = UserDefaults.double` 无 key 返回 0（`:41`）+ `BudgetCalculator.gate` 把 `<= 0` 判「未拨款一律拦」→ **全新安装第一条消息就被自己的闸拦死**。修：`isBudgetSet`（看 key 存不存在，`GlobalBudgetStore.swift:29,39`），从未拨款 = 不限（`BudgetCalculator.swift:84`），明确填 0 仍拦（`:86`）；UI 未拨款显示空 + 占位「不限」；`BudgetGateTests` 4 锚 `d6b71ac3`。⚠️ **代价：全新安装现在没有花费保护**——要默认保护得定一个首次额度（产品数字，等粟粟）
- [x] **BUG-3「（已停止）」诊断，未改代码**：四层调用链单一路径——文案只在 `ConversationViewModel.swift:1789/1793` → 只 `cancelAssistantTurn` → 唯一调用者 `CardFlowView.swift:1243` → 条件 `showStopButton`（`:2060-2062`）。**app 自己不会写这行字**：发送键和停止键同一个键，发送成功 `:2227` 立刻清空文本按钮当场翻成 stop → **第二次点击 = 取消整轮**（无 askOnce 无工具卡）。冷启动第一条最慢，自动化「点了没反应再点」正好落窗口；与「只出现一次」吻合。排除：`profileWillSwitch`（`:100-124`）不调 cancel 只清 ref；沙箱路径不碰；`:2988`「工具调用达到上限 8 轮，已停止」是另一文案
- [x] **askOnce 超时查到一条真缺陷，只加取证未改语义**：三个嫌疑（sheet 订阅 / respond 先后 / conversationId）逐条排除；活下来的是 **30s 从 `decide()` 起表而不是从卡片真 present 起表**（`PermissionPromptCenter.swift:49-55`），宿主 `.sheet` 挂在 `CardFlowView.swift:1427`，与 `AskUserQuestionSheet` / 预算 alert / `fileImporter` 抢 present 名额——别的挡着卡就弹不出来、计时照走（`:31` 老注释早承认「常见于卡根本没弹出来」）。**「点了允许却超时」= 第一张没 present 超时不落档 → 模型重试 → 用户点的是第二张**（PLAUSIBLE）。本轮：`respond` 落空静默 → 打日志（`:64`）、纠正 `:25-26` 错注释、`PermissionPromptCenterTests` 2 锚（含迟到点击不误伤当前卡）`c99db56c`
- [x] `SandboxSettingsTab.swift:48-50` →「本次启动已挂载 N 个楼层」
- **要粟粟拍三件**：① 首次默认额度给不给、给多少（不给 = 新装无花费保护）② stop 键防连点（发送后 ~500ms 忽略窗 / 换位 / 二次确认——改的是记录在案的三态取舍）③ askOnce「卡真 present 了才起表」根治（改权限语义；配套把权限卡挪出 `CardFlowView` 的 present 名额）
- **粟粟 08-27 04:35 拍「10｜按你推荐」** → T6c（同 worker）：① 默认额度 $10（未拨款=10、填 0 仍全停、清空回默认，不限要填大数）② stop 发送后 500ms 忽略窗（不换位不二次确认）③ 卡真 present 才起 30s + decide 后 60s 未 present 兜底 timedOut + `PermissionPromptHost` 挪根视图；验收：卡弹出等 35s 再点允许必须执行

### T6c · 粟粟三拍落地 ✅（08-27 04:20 → 04:51，同 worker，5 commit `4735cf4a`，**700 测绿**（+9）/ iOS 绿 / askonce 探针三截图；`sandbox-t0` 已快进）
- [x] 默认额度 $10 三档定稿：从未拨款 = 10（`BudgetCalculator.swift:84`）/ 填了按填的 / 填 0 = 全停（`:86`）；**没有「不限」专用档**，要不限填大数；UI 未拨款显示 `10.00` + 「默认」胶囊（`APISettingsTab.swift:521-527,557-564`），副文案只描述功能，清空保存回 10，进度条按有效额度；`ConversationViewModel.swift:3969-3975` blocked 文案改（走到那只可能是明确填 0）；6 锚含双向 override `ef54388e`
- [x] stop 防连点：`ComposerStopGuard` 纯函数（`CardFlowView.swift:2042`）+ `lastSentAt` `:2071` + 发送成功打点 `:2254`（两端）+ stop 分支先过闸 `:2242`；时钟倒流按窗口内处理（宁漏一次 stop 不误取消）；4 锚 `61660145`
- [x] askOnce 根治：计时拆两段——`decide()` 只挂 60s `presentationTimeout` 兜底（`PermissionPromptCenter.swift:49`），30s 作答表由 `markPresented`（`PermissionPromptSheet.swift:71` onAppear）才起（`:64-78`）；顺手堵原有泄漏（每问一次漏一个睡着的 Task → 结清即 `cancelTimers()`）；宿主挪到 `MemoryPalaceApp.swift:795` WindowGroup 根两端都挂；**探针反证宿主生效**（单测在宿主 app 里跑时 Host 真把 sheet 弹出来了 → `#if DEBUG init(isolatedForTesting:)`）；模拟器 `-sandboxProbe askonce`：t=0 未上屏 → t=1s 上屏 → 18.4s 点允许 → allowed `5d3d7aea` `6ff5286e`
- worker 推回我的验收「等 35s 再点允许必须成功」——对：改的是起表时机不是加长 30s，模拟器上卡 1s 露脸后作答预算仍 30s；决定性证据是单测 `testAnswerClockDoesNotRunBeforePresented`（作答表 0.2s 不 present 等 0.6s：旧红新绿）。真正的 BUG-9 现场（卡被别的 sheet 挡住延迟露脸）模拟器造不出，宿主挪根后该场景理论上不再发生
- **要粟粟拍三件（独立于本次改动）**：① 30s 作答预算要不要加长（如 60s）② 要不要真正的「不限」档（开关 ON 无上限，第四档）③ `presentationTimeout` 60s 钉常量不做设置项（我倾向就这样）

- **明天批次汇总**（按优先级，全部 7 条已由 T6a/T6b 完成或诊断）：① 前台提示条真做（BUG-4）② 重置后 `not_available("沙箱已重置…")` 检查提到 cwd/挂载之前（BUG-6）③ 沙箱设置显眼（**粟粟 08-27 拍：设置根列表一行「ish沙箱」，放文件库下面同一坨**；lite 先不露）④ 新 provider 预算闸默认 $0（BUG-1）⑤ 「已停止」触发源 + askOnce 允许后超时复现（BUG-3 / 9）⑥ review §四 第 1 条改成「首条命令时闪」⑦ `ISHShellBackend.swift:9` 头注释
- [x] 许可文件落地 ✅（08-26 01:40：mneme-atrium `3169ca7` 去 Commons Clause + THIRD_PARTY_LICENSES.md + README 改口，已推公开仓；MP 私有仓根补同款 LICENSE + 清单）

估：T0 1-2 天 / T1 2 天 / T2 3-4 天 / T3 4-5 天 / T4 1 天 ≈ **2-3 周**。

## 3. 测试

- 构建脚本：VDSO 非零断言有测（故意藏掉 lld → 脚本必须失败）
- `RunCommandToolTests` 按平台跑两遍（macOS 现有 14 条 + iOS 模拟器同名用例）
- mount：`FileLibraryStore` 串行队列 / `resolve` symlink 拒绝 / 文件名 clamp 单测；清残留逻辑对着假 `data/mnt/library/` 目录单测
- 备份：`.mpb` 不含 rootfs（`isExcludedFromBackup` + Application Support 不在扫描面）——`SchemaCoverageCheck` 加断言

## 4. 风险（研究里已展开，这里只列会改排期的）

1. **T0 链不通 / boot 不起**（最大）：模拟器 slice、`-DLOG_HANDLER_NSLOG` 拉 CF、bridging header 首次引入 ObjC——任何一条都可能卡一天
2. **真机内存**：MP 本身零内存压力处理 + 20 万节点无实测 RSS；guest 起来后 jetsam 谁先死没人知道——T0 必须带 RSS 数
3. **App Store 审核**：iSH/Minis 在架是先例不是保证；`apk add` 不限制
4. 许可文件改动是公开动作（mneme-atrium 换许可证）——粟粟亲自做还是我做，拍一下 <⧫>我做</⧫>

## 5. 粟粟真机清单（iPhone）

1. 首启看到「准备沙箱…」→ 几秒后消失
2. 权限页有「运行命令」行，默认「每次询问」
3. 新对话「用 shell 看看我文件库有什么」→ 弹卡（带 `$ ls …`）→ 允许 → 输出里是你文件库的文件名
4. 让它 `echo 你好 > /mnt/library/<楼层>/沙箱写的.md` → 文件库面板立刻出现这个文件，能打开
5. 在文件库面板新建一个文件 → 让它 `ls` → 看得见
6. 切一个楼层再来 → 路径变成那个楼层，内容不串
7. `sleep 300` timeout 5 → 超时；命令跑到一半切后台 30s 再回来 → 结果报 `cancelled`
8. 断网（飞行模式）→ 3-5 照样能跑
9. Mac 端行为不变

## 6. 粟粟已拍 —— ✅ 2026-08-26
1. ✅ 许可文件 **code 爸比改**（Phase 2 首 commit 前落地）
2. ✅ 前台提示 **要**
3. ✅ T0 **现在就跑**
4. 追加：保活+后台 Phase 2 不做，**Phase 3 用灵动岛做**（Live Activity 是正当保活理由，比静音音频好）
