# Review：离线沙箱 Phase 2（iOS iSH 后端 + 文件库 mount）

> 模块：T0 runway → T1 构建/rootfs → T2 双后端 → T3a/b/c 文件库 mount + 宿主三修 → T4 收口
> 分支：`sandbox-t0`（未合 master）。上游 plan：`docs/plan-离线沙箱-phase2.md`
> 各段实证报告：`docs/prompts/2026-08-26-sandbox-t0/reports/t{0,1,2,3a,3b,3c,4}-report.md`
> 本文档按 MP review 格式三块写，末尾附 §四 粟粟真机清单。

---

## 一、边界情况（没处理的输入异常 / 并发 / 失败重试 / 空状态）

### 1.1 已知**不处理**、且有意识留着的

| # | 边界 | 现状行为 | 为什么不处理 |
|---|---|---|---|
| B1 | **iCloud 楼层** | `iCloudEnabled && iCloudFloorsRoot() != nil` → 不挂，cwd 回落 `/root`，envelope 带 `note` | 粟粟拍的 v1 不挂。**这条路至今没被执行过**——T3b 在模拟器和 Air 上都试了，两边 `iCloudFloorsRoot()` 都是 nil（容器未就绪），判定条件为 false 就走了正常挂载。代码是对的，但**实证等级仍是 PLAUSIBLE** |
| B2 | **越界 symlink → 全库拒挂** | `filesystem/` 里任何指向库外的真 symlink → 整个楼层挂不上，`note` 列出违规路径让用户去 Files.app 处理 | 安全方向是对的（宁可不挂）。但**粒度是全库**：一个链接就让沙箱对该楼层完全不可用。做「跳过违规路径挂其余」要 path hook（bind mount 是整目录的），复杂度高一个量级 |
| B3 | **硬链接跨挂载点**（R6 家族） | guest 可以 `ln 库里的文件 /root/x`，链接数变 2，卸载后引用仍在 rootfs | 不是越权读（它本来就能读那个文件）。是**生命周期**问题：将来若要做「退出楼层就断开访问」，这条要重新算 |
| B4 | **guest 造的 symlink**（R9） | 在宿主上落成「内容是目标路径的普通文本文件」 | fakefs 的设计如此，已文档化不修。好处是 guest 造不出真 symlink，逃逸通道从原理上封死 |
| B5 | **`cleanResidue` 只清 `/mnt/library/` 前缀** | 别的 bind（如果将来有）不会被清 | 目前只有文件库一处 bind。**将来加第二处 bind 必须同步扩这里**，否则新的那处会变成清不掉的持久残留 |
| B6 | **`.rootfs-version` 手动升版** | 改 `prepare-rootfs.sh` 产物结构必须手动 +1，否则老装机不重装 | T3a 踩过一次（加 `/mnt/library` 时设备上那份没有）。没做成自动（比如按 zip 哈希），因为要在 app 内算 3.9MB 的哈希 |

### 1.2 并发

- **宿主写**：T3c 加了进程级串行队列（`FileLibraryStore.writeQueue`），读不排队。50 并发写同一文件有测试锚。
  ⚠️ 队列内不许再调排队函数（`sync` 嵌套死锁）——`edit` 走 `writeLocked` 这类内部变体，**加新写入口时必须遵守这个约定**。
- **guest 写 ↔ 宿主写**：**没有跨进程锁**。guest 直接写宿主文件系统，`writeQueue` 管不到它。两边同时写同一个文件仍可能互相覆盖（各自是原子写，所以不会写出半截文件，但会丢一边的内容）。
- **`mounted` 进程内表 vs rootfs 里的持久 bind**：**双轨，且真相源是 rootfs**。进程内表只用来「不重复挂」；bind 本身会持久化进 rootfs（symlink + meta.db 行都落盘），所以每次 boot 先 `cleanResidue` 再按本次策略注册。**别把表空当成「没挂」**。

### 1.3 失败重试 / 空状态

- `prepare()`（解压 + boot）失败 → `not_available`，**不自动重试**。用户再发一条命令会重来一次。
- `didResetWhileBooted` → 本进程内所有 `run_command` 直接 `not_available("沙箱已重置，请重启 app")`。`become_first_process()` 不可逆，做不成热重挂。
- 空文件库：挂载点存在但空，`ls` 空——正常路径，无特殊处理。
- rootfs 解压中途失败：解到 `rootfs.staging` 再整体 move，**不留半成品**；`isInstalled` 同时要求 `data/` + `meta.db` + `.arch` + `.rootfs-version` 四者齐全。
- change ring 溢出：`fakefs_change_dropped_count()` 有计数，目前实测一直是 0；**溢出时只是丢通知**（面板不刷新），不影响文件正确性。

### 1.4 输入异常

- `command` > 4000 字符 → `invalid_param`。
- `cwd` 含换行/空字节 → `invalid_param`；绝对路径原样放行（guest 命名空间是边界，见 t3a-report §④）。
- 文件名 > 255 UTF-8 字节 → clamp（grapheme 边界，保留扩展名）。**只 clamp 末段**，中间目录段没 clamp。
- 超长输出 → `BoundedOutput` 头尾各 64KB + 丢弃计数，再过 `truncate` 头尾各 7500 字符。

---

## 二、与下一模块交互的风险

### 2.1 Phase 3（灵动岛 / Live Activity 保活）

| 风险 | 说明 |
|---|---|
| **T4 实证推翻了原有假设** | plan §1.6 和 T2 的工具描述都写着「切后台约 30s 系统杀掉 guest，命令按 `cancelled` 返回」。**Air 实测不是这样**：锁屏后整个 app 被挂起，`sleep 90` 跑到 180 秒仍未返回，app 进程**还活着**（没被杀）。也就是说命令是**原地冻结**，不是被杀。Phase 3 设计保活前必须以这个为准，别按「被杀」建模 |
| 回前台是否续跑**未验** | Air 是粟粟的设备且锁着，我无法远程解锁，「回前台那半」没测成。Phase 3 第一件事应该是把这半补上：回前台后命令是续跑完成、还是超时、还是永远挂着 |
| `RunCommandMonitor` 的时序 | 提示条 T6a 才真落地（T4 那次只加了 `.animation`，没有文案分支）。**app 挂起期间 UI 根本不刷新**——SwiftUI 停了，顶部那条停在切走前的样子；回到前台后注册表里那条记录仍在（命令还冻着），提示条继续显示「命令在跑，别切走」，直到命令真返回才收。如果 Phase 3 用 Live Activity 展示进度，要考虑「app 挂起期间 Activity 怎么更新」——那才是挂起期间唯一还能动的表面 |
| 共享状态 | `RunCommandTool.running` / `cancelled` 都是 `@MainActor` 字典。Live Activity 的回调不在主 actor 上，接的时候注意跳 actor |

### 2.2 Phase 4（终端 UI + iOS 运行面板）

| 风险 | 说明 |
|---|---|
| **`ISHKernel` 每进程只 boot 一次** | 终端 UI 想要交互 shell，走的是 `ISHKernel.executeCommand:`（PTY 路径），与 `run_command` 的 `ISHShellExecutor`（裸 pipe）是**两条路**。它们共享同一个已 boot 的内核，但 fd/进程组管理各管各的——终端起的进程不在 `RunCommandMonitor` 里 |
| **运行面板的数据源要换** | macOS 的 `RunPanelSnapshot` 靠 `ps`/`lsof`，guest 里没有等价物（busybox `ps` 只看得到 guest 进程）。`RunCommandMonitor` 已经是两端共享的、iOS 侧数据已在登记，缺的是 UI 和「进程树快照」的 guest 版实现 |
| **`lineCallback` 现在是按读块批量交付**（T4 改的） | 终端 UI 要逐行渲染时注意：一批可能有几千行，别在回调里做 per-line 的布局计算 |
| 接口契约 | `RunCommandBackend` 协议目前只服务 `run_command`。终端要复用得加「交互式 spawn」语义（stdin 持续可写、PTY、窗口尺寸），当前协议没有这些 |

### 2.3 与 master 主线

- 本分支已合 `origin/master` 到 `385fc6ca`（33 个 commit），冲突只有 `NOW.md` 的 HEAD 戳。**键盘线 / 流式线都没碰沙箱面**。
- 合并回 master 时要注意：`project.yml` 的 iOS target 多了 `Sandbox/ish` sources、`preBuildScripts`、三个 `sdk:` 依赖、`OTHER_LDFLAGS`/`HEADER_SEARCH_PATHS`/`GCC_PREPROCESSOR_DEFINITIONS`。**合完必须 `xcodegen generate`**。
- `FileLibraryStore` 改了语义（R5/R7/R10/R11 + `floorSlug` 兜底），有 12 条测试锚护着。`FileEditorSheet.onSave` 签名从 `Date?` 改成 baseline **内容**，两个消费方（`FileLibraryPanelView` / `TopicBox/TopicCardSheet`）都改了。

---

## 三、技术债务

| # | 债 | 影响 | 建议 |
|---|---|---|---|
| D1 | **cc-bridge `bun install`** | 新 clone / 新 worktree 里 `xcodegen generate` **和** macOS build 都过不去（`croner` / `@earendil-works/pi-ai` 解析不了）。与沙箱无关的老债，本批次一直靠「软链主 worktree 已构建的二进制 + 复制 `.sources-hash`」绕过 | 真修法就是 `cd cc-bridge && bun install`。已写进 `NOW.md` 纪律第 6 条 |
| D2 | **iCloud 分支从未执行过** | B1。代码路径未被覆盖 | 粟粟在自己登录 iCloud 的设备上手动跑一次；或加测试注入点（我没加，那会为了测试改产品判定条件） |
| D3 | **`TopicCardSheet` 的冲突判定没真机点过** | T3c 改了它的 `onSave` 签名，编译过、680 测绿，但**没有人真的在 UI 上点一次保存** | 进 §四 真机清单 |
| D4 | **回前台后命令是否续跑未验** | §2.1。这是 Phase 2 契约里最后一个空洞 | Phase 3 第一件事 |
| D5 | **预热已证伪并删除** | 200 / 2000 文件两次重测都无收益（2000 文件：冷中位 411ms vs 热中位 466ms，分布几乎完全重叠）。代码已删，`mount()` 里留了注释钉住数字 | **别再加回来**，除非有新数据 |
| D6 | **`.rootfs-version` 手动升版** | B6 | 改 rootfs 结构时记得 +1；或将来改成按 zip 哈希自动判 |
| D7 | **`escapingSymlinks` 每次挂载全树扫** | 库到万级文件会有可感延迟。当前挂载只在会话首次 `run_command` 发生，可接受 | 真成瓶颈再考虑缓存 + `.fileLibraryDidChange` 失效 |
| D8 | **R6 / R9 明确不修** | 硬链接生命周期 / guest symlink 落成普通文件 | 已文档化，见 B3/B4 |
| D9 | **`deps/ish` 是 depth-1 submodule 钉死 SHA** | `.gitmodules` 已去掉 `branch` 字段（防 `--remote` 静默前进）。升级要手改 gitlink 并 review diff | — |
| D10 | **`apk add` 不承诺** | guest 出网在 Mac 上实测不通（TCP connect `errno=EINTR`），真机没测 | 工具描述已明说「不保证有网络，别当方案前提」 |
| D11 | **探针代码留在产品里** | `SandboxProbe`（`#if DEBUG` + launch argument 触发）约 400 行 | Phase 4 收口时评估是否留 |

---

## 四、粟粟真机清单（iPhone）

> 装包：`sandbox-t0` 分支的 Debug build。⚠️ **Air 上现在装的就是这条分支**，验完 master 的东西要重装 master build。

1. **首次解压** — 删掉 app 重装 → 打开（**这时候顶部什么都不该有**，沙箱是懒启动，不在冷启动路径上）→ 第一次让 AI 跑命令时顶部才闪一条薄荷绿「正在准备沙箱…」，几百 ms 后消失
2. **问 AI 跑一条命令** — 新对话说「用 shell 看看沙箱里有什么」→ 应该弹 askOnce 权限卡（带 `$ …` 预览）→ 允许 → 输出是 Alpine 的目录
3. **权限页** — 设置 → 权限，应该有「运行命令」一行，默认「每次询问」，副文案是「AI 可在 app 内的 Linux 沙箱里运行命令（碰不到沙箱外的东西）」
4. **文件库双向** — 让 AI `echo 你好 > 沙箱写的.md`；文件库面板应立刻出现这个文件（change consumer 推的）；再在面板里新建一个文件，让 AI `ls` 应看得见
5. **中文文件名** — 让 AI 读一个中文名的笔记，再让它写一个中文名的文件，两边都不该乱码
6. **切楼层不串味** — 换一个楼层再让 AI `pwd; ls`，路径应该变成那个楼层的挂载点，内容不串
7. **「命令在跑，别切走」** — 让 AI 跑 `sleep 20`，命令期间顶部应有薄荷绿提示条 + 终端图标，命令结束自动收
8. **切后台**（⚠️ 这条是**验行为、不是验通过**）— 命令跑到一半锁屏，等 40 秒解锁回来，**如实记录**：命令是续跑完成了、超时了、还是一直挂着？这一条 Phase 2 没验成，你的结果就是答案
9. **重置沙箱** — 设置 → **ish沙箱**（T6a 从文件库页底提到设置根列表，就在「文件库」下面一行）→ 「重置沙箱」→ 确认。之后再让 AI 跑命令，应该收到「沙箱已重置，请重启 app」；重启 app 后恢复正常（会重新解压）
10. **iCloud 楼层** — 设置 → 文件库 → 打开 iCloud 同步，再让 AI 跑一条命令：工作目录应该回落 `/root`，且 AI 的回答里应提到「iCloud 楼层暂不能挂进沙箱，用 fs_* 工具」。**这条从没验成过，你是第一个**
11. **`TopicCardSheet` 保存** — 话题盒里打开一张卡编辑并保存，应正常保存；另开一处改同一文件再保存，应提示「文件已在外部修改」
12. **断网** — 飞行模式下第 2、4、5 条应照常可用（沙箱不需要网络）

