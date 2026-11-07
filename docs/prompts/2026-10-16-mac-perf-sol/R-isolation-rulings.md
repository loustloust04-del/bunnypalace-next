# 车头裁决：bench 改道 astra 审（13 条）

总原则：**内核写白名单当主防线**——host 的 sandbox 配置从「allow default + 七根 deny」改成「file-write* 默认 deny，只放行 bench 根 + 系统必需的临时 / 缓存位置（逐条列出并说明）」，读不收紧。app 层只给**跨进程交接**加 bench 闸（外部终端 / 桌面深链 / AppleScript、废纸篓、系统通知、网络）。不做通用沙盒框架、不做 openat 能力边界；驱动器（cua）只点场景脚本里的控件，不点导出 / 删除 / 在终端继续。

| # | 裁决 | 落实 |
|---|---|---|
| 1 | 收 | 缺失后缀含 `.` / `..` 直接拒；补该组合反例 |
| 2 | 收 | bench 下外部续跑、桌面深链、AppleScript 执行入口一律拒（一处闸） |
| 3 | 收（改法） | 内核写白名单兜住绝对路径写；bench 下本机终端 / `run_command` 只允许受控合成可执行程序，通用 shell 入口禁用 |
| 4 | 降级 | 不改 SwiftTerm；bench 终端只接合成输出器，shared tmp 的 unlink 由内核写白名单挡住；在 research 里记限制 |
| 5 | 收（改法） | `NSWorkspace.recycle` bench 下禁用（或根内回收）；保存面板导出由内核白名单兜住，驱动器不点导出 |
| 6 | 收（优先） | **恢复非 bench 原语义**：原来 `.first?` / `guard … else return nil` 的调用点保留可选降级，只对拿到的 URL 做 bench 检查；iOS 分支逐字回原样。补一条「查询为空不崩」用例 |
| 7 | 收 | Cursor slug 搜索在 bench 下从已校验的根内起点开始，不探根外祖先 |
| 8 | 收 | bench 安装 / 探针逻辑放进 `#if DEBUG \|\| PERF_BENCH`；正式 Release 完全不响应 MP_PERF_* 变量 |
| 9 | 收 | 系统通知适配器 schedule / cancel 走既有 notifications 闸 |
| 10 | 降级 | 内核写白名单兜住；只在 research 记一行，不补消费者级用例 |
| 11 | 收（轻） | MiniBrowser load / LinkPreview 网络发起处加 bench 离线闸；host 网络审计覆盖不到 launchd 代理这点写进 research 局限，不另造验证 |
| 12 | 收部分 | 只补 #1 组合、#6 语义、#7 Cursor 三类用例 + 内核白名单的 host 自测；不建 active-bench 消费者宿主框架 |
| 13 | 收前半 | 枚举返回 checked 后的 URL；TOCTOU 不做（内核白名单兜底），记局限 |

裁完即收口：落实后不再全量复审，车头只核阻断项（#1–#3、#5、#6、#8）是否落实。
