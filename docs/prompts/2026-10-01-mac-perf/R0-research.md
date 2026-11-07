# R0：记忆花园 macOS 性能——调研 + 测量方案 + 计划初稿（只写文档，不改产品代码）

工作区：`/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/.claude/worktrees/mac`（分支 `zone/mac`，已由车头占位，你直接在这里干，不要另开 worktree）。

## 背景

粟粟（产品负责人、资深开发，中文）：mac 版「经常动不动点一个什么就转菊花」；「之前我们怎么折腾 iOS 的就怎么折腾 mac」。
iOS 那套 = huashu-flash 法：定义核心操作和「能用」终点 → 测量台（PerfHarness，`MP_PERF_*` 开关，Release+`PERF_BENCH`）→ 基线（冷缓存、每组 ≥10 次、p50/p75/p95）→ 一刀一 commit、每刀挂开关、ABBA 交替配对证明 → 棘轮锁住 → 每轮 plan 和结果交 astra 对抗审 → UI 回归 → 粟粟拍板看得见的变化。

## 先读（别重新推导）

- `perf/BRIEF.md`、`perf/报告.md`、`perf/实验日志.md`、`perf/基线.md`、`docs/plan-perf-flash.md`（§6 起是历次 astra 裁决）——iOS 的全过程、口径和踩坑。
- `docs/plan-launch-perf.md`（**顶部勘误**在 page2-shell 分支 6b5c53fa，可能还没进 master：`MainBlockMonitor` 只挂一个 order=0 观察者，在 CA 提交前收段，busy / 长块绝对值偏低 15–55%；新口径要双观察者 Int.min 开 / Int.max 收，page1-2 的 chatV1-r3 正在做）、`docs/research-launch-perf.md`。
- `MemoryPalace/Utils/PerfHarness.swift`（现在整个是 `os(iOS)`）、`scripts/perf/*`、`scripts/ui/ui-regress.sh`。
- `manual/facts/` 里 mac 相关、`docs/MODULE_INDEX.md`、近期 mac 相关 plan/research（`ls docs | grep -i mac`）。
- memory 索引 `~/.claude/projects/-Users-susu-Desktop-susu-project------MemoryPalace/memory/MEMORY.md` 里所有 mac / UserDefaults / SwiftData / 测试宿主 / pkill / 假 HOME 相关条目（必读：UserDefaults 域 3.8MB 收放面板 hang、mac 别用假 HOME 起第二实例、测试宿主会迁移真库+写真偏好、pkill -f 会杀她的 app、跑测试挡路就自己退她的 app）。

## 已有现场证据（车头 10-01 初看）

`/Library/Logs/DiagnosticReports/记忆花园_*`（26 份，全是 Debug 包 1.1.0）：
- 1 份 `.hang`（09-25 01:39，39.77s 无响应）：主线程全部样本卡在 `NSRunLoop.flushObservers → NSHostingView.beginTransaction → Update.ensure`（SwiftUI 更新事务），再往下要你读完。
- 22 份 disk writes：约每小时脏写 2GB，最多 7h 8.6GB；最重栈是后台队列 `sqlite3_exec → wal_checkpoint → pwrite`，上面是 `记忆花园.debug.dylib` 未符号化帧。
- 3 份 cpu_resource（90s CPU / 92–141s）。
- **09-28 之后没有新报告**——查清是改好了、还是她现在用的包不在统计里（看她现在跑的是哪个包：`ps` / `lsof` 只读查看）。

## 要你做的

1. **把现场证据查到根上**：hang / disk writes / cpu 的栈尽量符号化（Debug dylib 偏移 → 对应提交的构建；UUID 对不上就按偏移 + 代码阅读推断，标明置信度）。disk writes 那条要找出是谁在反复 `sqlite3_exec` 写库（SwiftData 主库？search-index？FTS 重建？），频率和触发条件。
2. **只读现场采样**（可选，若她的 mac 版正在跑）：`sample <pid> 3` / `spindump` 抓几次；**不杀、不启动、不改她的 app 和数据**。
3. **静态排查 mac 主线程重活**：mac 专属路径（侧栏、面板、设置、窗口/全屏、NSHostingView 层级、键盘 / 选区、@AppStorage / UserDefaults 写、主 context 上的 SwiftData fetch/save、同步文件 IO、图片解码）。列「点了会转菊花」的候选清单，每条带 `文件:行号` 证据和估计量级。
4. **定义 mac 核心操作和「能用」终点**（仿 iOS BRIEF 那张表）：冷启动到能打字、打开对话、切楼层、开/收侧栏和面板、打开设置各页、流式回复中滚动/输入、窗口缩放/全屏等——给候选，标推荐的 3–5 个主指标，其余作探针。
5. **测量方案**：PerfHarness 怎么扩到 macOS（直接用双观察者口径，`harnessRevision` 起 `macV1-r1`）；Release+`PERF_BENCH` mac 包；xctrace（Time Profiler / Hangs / Animation Hitches）本机录制带超时兜底；常驻卡顿记录器（DEBUG/PERF 包里主线程 >250ms 记栈 + 时间 + 当前页面，她日常用就能攒证据）。**mac 特有约束必须写清并给方案**：① 这台 mac 同时是全机编译服务器，负载噪声大——测量只在编译锁空闲 + 负载低时跑，怎么判定、怎么记录负载；② 同一 bundle id 不能两实例、她的真实数据在 `~/Library/Application Support/MemoryPalace`——测试楼层 seed / restore、退出她的 app 再测、测完恢复的完整流程和备份；③ 设备租约 `device-lease acquire mac`。
6. 产出（写进工作区并 commit 到 `zone/mac`，原子 commit，消息结尾带 `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`）：
   - `docs/research-mac-perf.md`：1–3 的发现，带证据和置信度。
   - `perf-mac/BRIEF.md`：仿 `perf/BRIEF.md` 的 mac 冲刺简报（核心操作表、不能动的东西、目标、口径、上线回滚）。
   - `docs/plan-mac-perf.md`：顶部 `⚠️ DON'T IMPLEMENT YET`；分轮（R1 测量台 + 卡顿记录器 + 基线、R2 起按归因下刀），每轮验证方法、开关、ABBA、UI 回归覆盖（mac 的 UI 回归现状要查清，没有就写怎么补）；末尾颗粒度 todo。
7. 回报：三份文档路径 + commit 号；最重要的 5 条发现（一句话一条）；需要粟粟拍板的问题。

## 红线

- **不改任何产品代码 / 脚本 / project.yml**，只写上面三份文档。
- 不 build、不启动/杀/安装 app、不碰设备、不申请 device-lease、不 say-zh、不 merge-queue、不写 NOW.md、不 push。
- 不读她真实数据库的内容（只看文件大小 / 修改时间 / WAL 大小这类元数据）。
- 不联网。
