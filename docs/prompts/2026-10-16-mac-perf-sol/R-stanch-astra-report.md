Working...
**未发现可确认的阻断项。** 以下失败场景为静态推演（[INFERENCE]），不是运行复现；行号对应 `62f30f4bb`。

| # | 严重度(阻断/应修/建议) | 文件:行号 | 问题 | 失败场景 | 建议 |
|---|---|---|---|---|---|
| 1 | 应修 | `CodingSessionLibrary.swift:394–405,798–808` | **`beforeWaiting` 闸只覆盖同步列表 flush，不覆盖随后异步落地的详情渲染。** `reloadDetail()` 排任务后立即注册 observer；详情仍可能在冷却或解析。另一方面，详情冷却在写入 `detail` **之前**已经起算。 | 列表 flush 后先空闲、释放闸；详情稍后落地并长时间布局。布局耗尽剩余冷却时间后，已排队的下一次 flush／详情解析可以紧接着执行，没有承诺的“渲染结束后再休息一个窗口”。 | 将详情更新对应的冷却／释放与该代结果落地后的 `beforeWaiting` 对齐；保留无详情变化时的列表路径。验证须包含“先空闲、后解析完成、再长布局”，不能只在列表通知中模拟忙段。 |
| 2 | 应修 | `MemoryPalaceTests/CodingSessionLibraryTests.swift:280–288`；`CodingSessionLibrary.swift:716–724` | **“拒绝迟到结果”测试实际上取消的是尚未启动的刷新任务。** 同一 MainActor 调用中，`reloadDetail()` 后立即 `select("missing-session")`，中间没有挂起点。 | 测试没有制造旧解析已开始／已取得结果、然后切换选择的时序；旧结果覆盖、A→B→A 代际错误仍可能漏检。 | 用可控的真实解析 adapter 确认 A 已开始，再选 B；B 落地后释放并等待 A 完成，断言详情、错误和 revision 没被 A 改写。补 A→B→A。 |
| 3 | 应修 | `MemoryPalaceTests/CodingSessionLibraryTests.swift:143–158`；`CodingSessionLibrary.swift:738–741` | **“连续写入”实际是任务启动前的一次突发。** 五次写文件／`reloadDetail()` 之间没有 `await`，调度任务在循环结束前无法执行。 | 当前断言证明了启动前合并和首次冷却，却没有覆盖“解析期间又来更新，必须再补一轮”。即使漏掉 `detailReloadPending` 的后续消费，这个用例仍可能通过。 | 将写入分布到冷却中、解析已读取快照后两个阶段；等待真实调度收尾，核对最终文本和相邻解析间隔，并确认没有重叠解析。 |
| 4 | 应修 | `MemoryPalaceTests/CodingSessionLibraryTests.swift:199–208,225–227,269–277` | **静默／保留阅读内容的关键断言落在刷新 Task 启动之前。** 删除文件的失败用例又会在 `fileRef/fromMeta` 前置检查失败，没有覆盖后台解析抛错后的保旧分支。 | 刷新运行中短暂切成 `.loading`、翻动 `isRefreshingDetail`，结束后恢复，现有断言可能全部通过；真实解析失败时移除阅读内容也缺少对应覆盖。 | 在解析已开始且尚未完成时检查或观察状态转换；另保留有效文件引用，让真实解析路径抛错，验证旧正文完整保留且错误可见。 |
| 5 | 建议 | `docs/plan-mac-perf.md:165`；`HangProbe.swift:12`、`SyncStore.swift:12`、`KBProbe.swift:35`、`CodingSessionLibrary.swift:117–118`、`MacWorkspacePreferences.swift:44` | §4 仍承诺 PERF 包识别 `MP_PERF_<刀>`，但六刀实现只读取 UserDefaults／构造参数，未接入这些环境开关。 | 后续 runner 只用环境变量切 A/B，实际两臂仍运行相同默认配置，形成无效对照。 | 明确这些环境入口尚未实现、不得用于本批对照；若属于本批交付契约，则补齐读取优先级及有效配置核验。 |

补充结论：

- **开关**：六个 `mp.stanch.*` 默认均为 YES；静态检查可见 NO 回退路径。H1 的测试宿主安全门不回退，符合约定；P1 在 Release 始终关闭日志。读取并非统一“进程启动”：H1／S1 是首次访问静态值，P1 是实例初始化，K0／K1／R-tab 是所属实例构造时。
- **正确性与滚动**：未找到新增死锁、主线程同步等待解析或旧选择结果直接覆盖新选择的路径。失败保旧、稳定的 `meta.key` 滚动宿主及按阅读意图跟随的代码仍在；现有滚动测试只验证策略对象，不能代替实际滚动面验收。
- **iOS**：新增行为均有 macOS 条件隔离；`SyncEngine` 的 iOS 分支仍执行原四次计数，KBProbe 保留原实现。静态未见新增 iOS 编译路径问题，**未编译验证**。
- 测试使用真实 fixture／解析器／SQLite／文件写入，并非仅测 mock；主要缺口是上述异步时序。全程未改仓库文件、未 git 写、未 build/test、未操作设备或联网，未读取禁区。
