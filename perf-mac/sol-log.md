# mac 性能 · sol 切片日志

## S0 BLOCKED 2026-10-16 16:16
- 做了什么：读完性能手册 / 旧调研计划 / R0裁决，重核当前工位全部候选；research追加§7现场表、候选表与暂定刀单，plan §4 / §9同步已修边界。执行中已重读10-16任务书v2，mac编译豁免及验证后自行提交 / 连续执行规则已知悉；S0未改产品代码。
- 改动文件（`git diff --stat -- docs/research-mac-perf.md docs/plan-mac-perf.md`）：research +104行；plan 36行变动；两文件合计125 insertions / 15 deletions。另新建本日志。commit号：无；S0现场证据门未过，未把BLOCKED切片提交为完成。
- 验证：目录read/glob + grep进程头 / ips身份 / 精确Powerstats段核查；文档结构、57项编号与53个显式源码路径核验。原文：`S0_DOC_CHECK PASS: candidates=57, explicit_source_paths=53, evidence_files=1, evidence_bytes=5507, table_columns=OK`。S0为只读调查，未运行xcodebuild / 测试宿主 / app，**没有测试类passed原文，不冒称通过**。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S0-system-report-inventory.md`（5507 bytes，1份，未入git）。原始报告 / 日志 / 截图未入库。
- 没做到 / 坏消息：四个诊断目录没有花园专属spin/hang等报告；通用daily IO两份的6+8个花园段及WindowServer附属段缺main标记 / 自有符号，不能当卡顿频次。HangProbe根在硬规矩2禁读目录，本轮连目录都未列举，无法逐份拆日志主线程、补最长时长、按本期频次重排。没有新报告不等于修好。N3仍未知但不是阻塞项。
- 静态重要更正：T5临时家目录 / 偏好 / 钥匙串隔离已有，不重复做；测试宿主仍启动HangProbe，测试门并入H1。P1启动probe-2/4已删，只剩KBProbe。文件库枚举已后台化、Warroom文本解析已移出主线程、书架盘读已后台化，不能重复下旧刀。
- BLOCKED需要谁决定：车头提供仅含栈和元数据的HangProbe日志 / sample脱敏副本到上述证据目录（本切片合计≤5文件、单个≤1MB）；**推荐先用副本**。另一选择是粟粟明确授予原`perf/`子目录日志只读例外，其余Application Support/MemoryPalace继续禁读。不绕硬规矩、不为取证启动她的app。
- 下一切片：先解阻并补齐S0a，完成本期归因 / 排序与S0验证提交，再做S1（H1第一刀）；当前不进入下一刀、不启动bench。

## S0 DONE 2026-10-16 16:18
- 做了什么：**仅静态部分完成归档**；车头明确批准先提交research §7 / plan §4 §9 / 本日志，S0a现场取证仍待授权，不声称整个S0证据闭环。
- 改动文件：`docs/research-mac-perf.md`、`docs/plan-mac-perf.md`、`perf-mac/sol-log.md`；静态快照commit见本条所在提交，消息`docs(mac-perf): S0 静态重核（sol），现场日志待授权`。
- 验证：沿用本轮已执行的`S0_DOC_CHECK PASS`和`S0_LOG_CHECK PASS`，无产品代码变化、无xcodebuild或测试passed声明；工作区仅上述三文件有变动。
- 证据文件：仍为`~/MemoryPalace-docs-media/perf-mac/sol/S0-system-report-inventory.md`，不入git。
- 没做到 / 坏消息：S0a日志逐份归因、时长和本期频次重排仍BLOCKED；禁读目录未触碰。
- 下一切片：按车头裁决直接开始S1=H1（时长 / 包身份 / 测试宿主不起），不等待S0a；日志获准后再补现场。

## S1 DONE 2026-10-16 16:39
- 做了什么：H1补主线程应答时取结束点的单调时长、后台active标记、每行pid / 包UUID / 构建来源与工具 / 详情 / 本机终端字节上下文；500ms触发下界，测试宿主不启动timer / 不写note。`mp.stanch.H1`默认开，NO回旧口径，安全门不回退。
- 改动文件：产品3文件`HangProbe.swift` / `MemoryPalaceApp.swift` / `LocalTerminalSession.swift`，diff-stat 68 insertions / 18 deletions；新增`HangProbeTests.swift`；实验日志、H1复盘、plan checklist、worktree状态、roadmap索引及本日志。commit：本条所在H1提交（S0静态前序`ba7991c50`）。
- 验证：`MP_ZONE_PAUSE=/nonexistent xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/HangProbeTests`；grep原文`Test Suite 'HangProbeTests' passed at 2026-10-16 16:39:52.278.`，4测0失败且`** TEST SUCCEEDED **`。实际宿主有`[test-host] ... xctestVisible=1`。
- runtime smoke：显式临时目录实例走真实tick→主线程回执→ack→文件，主线程阻塞600ms、记录0.68s和包身份 / 上下文；默认shared及该实例的周期timer均未启动。不是格式化假时长。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S1-H1-verification.txt`（1份，<1MB，不入git）。
- 没做到 / 坏消息：真实smoke首跑抓到新终端字节率首次时间点懒初始化下溢，exit65 / SIGTRAP；已修并由同一smoke通过。未做周期sample触发、Release self-sample权限、真实终端吞吐、GUI或ABBA；不宣称卡顿下降。S0a原现场日志仍待授权。
- 下一切片：S2=计划S1，删除同步诊断全表计数 / 状态同值不写；不等S0a、不停止续做。

## S2 DONE 2026-10-16 16:48
- 做了什么：计划S1，mac默认跳过同步泵四次纯诊断全表count，导入/导出账本sortedKeys编码同值不atomic替换。`mp.stanch.S1`默认开、启动读一次，NO恢复旧行为；iOS条件分支不变。
- 改动文件：`SyncEngine.swift` +15/-8，`SyncStore.swift` +9，`SyncStoreTests.swift` +32；实验日志、S1复盘、plan、roadmap索引、worktree状态及本日志。永久新增测试32行≤产品新增24行×2；临时NO用例已完整移除。commit：本条所在S2提交；前序H1为`0a82a40e7`。
- 验证：`MP_ZONE_PAUSE=/nonexistent xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/SyncStoreTests`，grep原文`Test Suite 'SyncStoreTests' passed at 2026-10-16 16:46:45.498.`（11测0失败）。真实导入/导出/空转/标题变更及账本文件mtime链路通过。
- 回退：同命令仅选临时`SyncStoreTests/testStateRollbackSmoke`，grep原文`Test Suite 'SyncStoreTests' passed at 2026-10-16 16:47:31.347.`（1测0失败），NO下相同状态仍重写。临时用例已按hashline寄存器恢复为已通过的永久用例快照229E。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S2-S1-verification.txt`（1份，<1MB，不入git）。
- 没做到 / 坏消息：首轮新测试用URL缓存mtime误报2次断言，改读新鲜文件属性后整类通过。状态比较仍有编码和小文件读取；业务全量查询/激活重活不改。未启动生产同步泵、未量SQL次数/卡顿率/ABBA，不读真库、不测iOS。
- 下一切片：S3=P1剩余KBProbe，继续执行。

## S3 DONE 2026-10-16 16:55
- 做了什么：P1剩余KBProbe，mac默认关、显式开启后后台串行写；消息表达式仍调用线程求值，侧栏同步构造/print一起停。`mp.stanch.P1`默认开，NO恢复Debug始终启用/同步写；不复活启动旧计数，iOS原enum未改。
- 改动文件：`KBProbe.swift` +53/-1、`SidebarView.swift` +3、新增`KBProbeTests.swift`63行（≤产品新增56×2），实验日志、P1复盘、plan、roadmap索引、worktree状态及本日志。commit：本条所在P1提交；前序S1为`d54ec8632`。
- 验证：`MP_ZONE_PAUSE=/nonexistent xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/KBProbeTests`；grep原文`Test Suite 'KBProbeTests' passed at 2026-10-16 16:55:47.969.`，3测0失败且`** TEST SUCCEEDED **`。默认不求值/不建文件、显式开启真实完整有序写盘、NO真实同步回退均通过；临时偏好逐例隔离。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S3-P1-verification.txt`（1份，<1MB，不入git）。
- 没做到 / 坏消息：未做真实主线程文件IO耗时、GUI/ABBA；显式开日志后退出可能丢排队尾部，没有增加flush。默认关诊断计数后，后续测量台不得依赖该KBProbe侧栏计数。
- 下一步（车头追加指令）：本刀提交后**先补S0a**。粟粟已批原`~/Library/Application Support/MemoryPalace/perf/`指定日志/采样只读，逐份只看主线程栈和元数据；摘录放外部证据目录、不入git，其他数据根继续禁读。重排剩余刀，已提交H1/S1不返工，再按新序接续。

## S0a DONE 2026-10-16 17:09
- 做了什么：获准perf子目录只读后，逐份拆完20份采样并关联精确文件名触发元数据；14份测试注入单列，19份有主线程树/1份空图。非测试两份启动manifest同步读、两份Code增量主线程SQL；更新research §7.5–§7.7及plan §4/§9。
- 改动文件：`docs/research-mac-perf.md`、`docs/plan-mac-perf.md`、`perf-mac/sol-log.md`、`docs/now/mac.md`，4个md，无产品/测试文件。commit：本条所在S0a提交；前序P1为`f6420e9a8`。
- 验证：实际运行只读清点脚本，输出`S0A_INVENTORY_SMOKE sample_files=20 unique_names=20 main_trees=19 no_main_graph=1 xct_injected=14`；两份逐栈表各10行。只读调查不跑app/测试/构建，**没有Test Suite passed原文，不冒领**。本期元数据236 start +1101 hang下界 +13 active应答 +195 CPU busy =1545条；203个采样引用只有20份留存。
- 证据文件：外部目录`~/MemoryPalace-docs-media/perf-mac/sol/`下`S0a-hang-log-metadata.txt`3911 bytes、`S0a-samples-early.md`15106 bytes、`S0a-samples-late.md`13233 bytes；本切片3份（含原S0摘要共4份），均<1MB、不入git；原件不改删。
- 没做到 / 坏消息：缺183份历史采样；共享旧日志没有逐行pid/UUID，23.0s是未留样的触发下界，15.15s只是未归因的旧心跳往返。首轮脚本漏识别`Main Thread / DispatchQueue_<multiple>`曾误报8空图，已逐份校正为1，聊天也已更正。新L-manifest仍未处理，不能删比较/直接dispatch破坏启动目录改名与迁移时序；排到R1后首批实证。旧包桥接path update当前已默认后台，不重复实现。未做GUI/ABBA/前台小时率，不据空闲样本否定转菊花。
- 下一切片：按现场重排为**S4=K1-dirty → S5=R-tab → S6=K0-min**；H1/S1/P1不返工，继续到止血MILESTONE停合。

## S4 DONE 2026-10-16 17:24
- 做了什么：K1-dirty默认隐藏Code增量只记脏，已排队flush再验active/dirty；删除事件的空changedPaths也记dirty，只保留当前已加载详情命中路径，激活补列表与详情，菜单查询不受隐藏限制。NO真实键回退旧隐藏刷新，整个产品文件原有mac条件编译。
- 改动文件：`CodingSessionLibrary.swift`+21、`CodingSessionLibraryTests.swift`+23（≤42）；实验日志、K1复盘、plan、roadmap索引、工位状态、本日志。commit：本条所属S4提交；S0a为`79005b30a`。
- 验证：`MP_ZONE_PAUSE=/nonexistent xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/CodingSessionLibraryTests`；grep原文`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 17:24:30.405.`，16测0失败且`** TEST SUCCEEDED **`。修改前新回归因隐藏9→8预期失败一次，修改后`K1_DIRTY_SMOKE hidden=9 activated=8`。
- runtime / 回退：同命令选本类两个临时修改的方法，2测0失败，grep`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 17:23:43.531.`；真实隔离suite设键NO观测`stanch=false hidden=8`，真实fixture追加后`hiddenRetained=true appended=true`。临时改动清掉、恢复永久C265后才做最终整类复测。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S4-K1-dirty-verification.txt`，1份3061 bytes，不入git。
- 没做到 / 坏消息：首扫进度/完成、显式查询与active Code SQL仍未后台化；激活仍保留原扫描。测试输出有临时库vnode unlinked警告，复现前也有，未掩盖/扩展修复。未操作她的app/真库、未做GUI/ABBA或卡顿率收益；新manifest启动读取未解决。
- 下一切片：S5=R-tab，接着做，不等车头。

## S5 DONE 2026-10-16 17:28
- 做了什么：R-tab默认YES使启动不自动回Code；手动Code选择/标签/原持久化格式不改，NO回旧恢复，Code隐藏优先。只在mac偏好类改恢复策略，ContentView仅两行注释。
- 改动文件：`MacWorkspacePreferences.swift`+7/-3（功能新增5行）、`ContentView.swift`+2/-2注释、`MacWorkspacePreferencesTests.swift`+8/-2（8≤功能新增5×2）；实验日志、复盘、plan、roadmap索引、工位状态、本日志。commit：本条所属S5提交；K1-dirty为`442492eec`。
- 验证：`MP_ZONE_PAUSE=/nonexistent xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/MacWorkspacePreferencesTests`；grep原文`Test Suite 'MacWorkspacePreferencesTests' passed at 2026-10-16 17:28:31.897.`，10测0失败且`** TEST SUCCEEDED **`。
- runtime：真实独立suite写Code存档、重建读默认/NO/隐藏优先，观测`R_TAB_SMOKE saved=code default=chats rollback=code hidden=chats`；无新测试框架、无临时用例。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S5-R-tab-verification.txt`，1份1313 bytes，不入git。
- 没做到 / 坏消息：未做GUI启动/NO恢复、手动点击或ABBA；未操作她的app/生产偏好/数据，不测iOS。后台首扫仍在；manifest启动读取与active Code SQL仍未解决。
- 下一切片：S6=K0-min四项，完成止血批后MILESTONE停合。

## S6 MILESTONE 2026-10-16 17:50
- 做了什么：K0-min四项齐：同一选择的详情刷新合并/单飞、解析完按max(2s,10×耗时)冷却；增量flush至beforeWaiting/Int.max才释放并起下一窗口；静默不翻isRefreshingDetail；后台全值比较，相同不替换detail/不加revision。换选择取消调度并用代号拒旧结果，隐藏时转K1 dirty。
- 改动文件：`CodingSessionLibrary.swift`+102/-12，`CodingSessionLibraryTests.swift`+114/-17（114≤204）；实验日志、K0复盘、plan、research接续、roadmap索引、工位状态及本日志。commit：本条所属S6提交；R-tab为`b4d5dbd37`。
- 验证：`MP_ZONE_PAUSE=/nonexistent xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/CodingSessionLibraryTests`；grep原文`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 17:46:27.345.`，18测0失败且`** TEST SUCCEEDED **`。真实fixture连续5写仅初载+1解析，2.3226688s≥2.3064304s且末条精确可见；idle后下一flush间隔2.0049250s；同值revision=1→1/refreshing=false，同条数编辑、失败保旧、换选择与滚动意图过。
- 回退smoke：同命令选`testIncrementalCooldownStartsAfterRenderIdle`与`testUnchangedSilentRefreshKeepsReadingContentAndRevision`两个临时修改方法；grep`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 17:48:53.006.`，2测0失败。隔离standard suite实际键NO：idle后1.7051229s、详情0.0208384s、refreshingAtStart=true/revision=1→2。键值用defer恢复，临时测试完整还原为18测成功的FF7D，产品4FE6未再改。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S6-K0-min-verification.txt`，1份3498 bytes，不入git。没有新通用测试框架/helper库，专用adapter仍真实解析fixture，只加220ms受控耗时。
- 没做到 / 坏消息：首轮18测唯一失败是夹具漏Claude message.id造成合法分块合并，只补独立id，不改解析器/放宽断言，第二轮整类通过。大文件/重试也受冷却，更新更晚；仍全量解析/比较。临时库unlink等宿主警告未掩盖；未做GUI/Release采样/ABBA或日常卡顿率，新manifest启动读及active SQL未解决。
- MILESTONE交付：H1`0a82a40e7`、S1`d54ec8632`、P1`f6420e9a8`、K1-dirty`442492eec`、R-tab`b4d5dbd37`、K0-min（本提交）六刀完成；S0静态`ba7991c50`、S0a`79005b30a`及外部逐份表齐。请车头验收/合并，推荐保留六刀默认开；合并期间本分支不再提交。
- 下一步：**现在停，不启动R1**。车头合并/给继续后再做隔离bench与基线；新L-manifest列后续实证优先，不能宣称本批已消除转菊花。

## S7 MILESTONE 2026-10-16 18:16
- 做了什么：按车头收astra #1–#5，详情任务包含该代结果落地后的beforeWaiting，冷却从此起算；含详情增量等刷新链/idle再释放，无详情变化仍直接列表idle。真实snapshot闸覆盖迟到A/ABA、跨冷却与快照后写入、pending收尾、无重叠、解析中静默及真实权限错误保旧。§4明确MP_PERF_<刀>未接线，留R1，本批不得使用。
- 改动文件：`git diff --cached --stat`摘要为10 files changed, 223 insertions(+), 107 deletions(-)。`CodingSessionLibrary.swift`+45/-13共58改动行；`CodingSessionLibraryTests.swift`+110/-88（测试新增110≤2×58=116，产品预算明确按增删改动计）；plan §4/§9、research接续、S7新复盘/K0复盘更正、实验日志、roadmap索引、工位状态、本日志。commit：本条所属S7提交；基点`62f30f4bb`。
- 修前：同mac命令只选`testContinuousWritesCoalesceDetailAtMeasuredParseCost`，旧产品1测3断言失败（18:06:09），先idle后3s长布局，后续解析仅隔0.00405s、闸提前释放；不是重跑确认审查静态推演。
- 验证：`MP_ZONE_PAUSE=/nonexistent xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/CodingSessionLibraryTests`；grep原文`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 18:13:39.434.`，16测0失败且`** TEST SUCCEEDED **`。合并旧弱时序用例，类18→16；不是缩小运行筛选。
- runtime：布局后解析间隔2.4422007≥2.2374417s，3次真实解析无重叠且末条精确burst-2，最后解析后下一flush观察间隔2.6076795s；迟到A/ABA的revision分别2→2、3→3；有效引用真实解析报权限错误保正文/revision=1→1，错误可见。各快照闸挂起中loaded/refreshing=false，同值仍1→1。临时宿主home/suite及xctestVisible=1均有输出。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S7-review-verification.txt`，1份4430 bytes，不入git；原现场报告/日志未再读改。无新测试框架/通用helper库。
- 没做到 / 坏消息：本轮未重跑NO，相关NO分支未改、S6真实键证据保留；既有fixture SQLite unlink警告未掩盖。长布局为3s受控主线程忙段模拟，不是实际GUI/GPU证明；GUI/Release/ABBA/日常卡顿率未验，manifest启动读与active SQL仍未修。等待刷新链会让含详情列表更新更晚；仍无最大延迟保证。
- MILESTONE：请车头收S7后验收合并，推荐保留K0默认开；**现在停，不启动R1，合并期间不再提交**。后续仅等车头继续再接隔离bench与基线。

## S8 BLOCKED 2026-10-16 18:25
- 做了什么：R1-0前置重核，基点`0438097b`；独立临时Foundation命令行实证CFFIXED_USER_HOME+HOME，8项路径均在临时根，getpwuid仍根外。没有启动app/测量，不把测试宿主或iOS PerfHarness冒充mac bench隔离。
- 改动文件：新增`docs/research-mac-perf-r1-0.md`40行；`git diff --stat`为plan §9、工位状态、本日志3 files changed, 15 insertions(+)。产品/测试0改动，无永久测试/测试框架。commit：**无**，车头明确#00488合完通知前禁止commit；本轮也未暂存，仅改工作区。
- 验证：`swiftc -module-cache-path /tmp/mp-macperf-sol/r1-module-cache -o /tmp/mp-macperf-sol/r1-home-probe-0438097b /tmp/mp-macperf-sol/r1-home-probe-0438097b.swift`后以独立HOME/CFFIXED_USER_HOME运行；exit 0，原文`FOUNDATION_HOME_PROBE PASS; no app, preferences, keychain or network APIs called`，getpwuid结果inside=false。无xcodebuild/类passed，不冒充单测/app隔离通过。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S8-R1-preflight.txt`（3084 bytes）及`S8-r1-home-probe.swift`（1453 bytes），2份均<1MB，不入git；临时二进制已删，源码已外置存证。
- 没做到 / 坏消息：仅完成独立home探针；AppPaths/副作用隔离、完整bench实证、测量台/包/基线均未完成。没读她的真库/偏好域、没操作她的app、没对生产hub发流量、没碰iOS；无性能收益结论。
- BLOCKED：plan §3.2.4要求生产根marker/find及完整偏好对比，但任务书硬规矩2/7仍禁生产根读写/~/.claude修改，偏好只许具体布局键，车头又说“其余规矩不变”。需车头请粟粟明确：推荐marker放/tmp、七根只读元数据不读内容；偏好仅本机内存逐key比较、不输出/落盘值；不批则由车头改验收契约。T3推荐她在场但不用电脑的窗口，不默选无人值守。
- 下一切片：授权边界明确后回R1-0继续路径/副作用隔离，实证不过不往下；收到“合完了”才按切片补提交，Warden退回先停等车头修复指令。

### S8授权解除与补提交 · 2026-10-16 18:53
- 粟粟批1a + T3=b，任务书2a/2b已由车头单独提交；车头确认#00488已合master`8dfdae7b`、本工位已快进并保留改动。原授权阻断/提交冻结解除，不代表给了真启动窗口。
- 本次只补提交S8调查/plan裁决/工位状态/切片日志4份文档（本条所属S8提交），沿用18:25独立CLI的实际PASS证据；不把S9尚未验证的产品/脚本工作区混入该提交。无新增构建/测试/现场读取。
- 继续S9静态准备、mac编译、脚本自测；准备完先BLOCKED「等粟粟说现在测」，首启隐私框由她当面拒绝。不是R1基线MILESTONE。

## S9 BLOCKED 2026-10-16 19:09
- 做了什么：R1-0静态路径/副作用隔离及专用host脚本；保留Code真实扫描/监听负载。补了slug/构造期环境根/嵌套枚举入口；临时目录改道与Swift路径拒绝尚未通过，不能启动bench。
- 改动文件：阻断文档追加前`git diff --stat`为126个已跟踪文件+673/-461；另有新`AppPaths.swift`、`BenchIsolation.swift`、`scripts/perf/mac-isolation.py`、`scripts/perf/mac-isolation-core-selftest.swift`。本条并更新research、plan §3.2/§4/§9、实验日志、工位状态。**S9未通过，不暂存/commit**；S8文档已补提交`4e02f009b`，未混入S9代码。
- 验证：`python3 scripts/perf/mac-isolation.py self-test` exit 0，`status=GREEN, synthetic_only=true`（12项）；`xcodegen generate` exit 0。核心用`swiftc -parse-as-library ... BenchIsolation.swift AppPaths.swift ...core-selftest.swift`后独立HOME/CFFIXED/TMPDIR运行，两次均编译成功、运行exit 133；第1次`自测须在独立HOME/TMPDIR中运行，Foundation改道必须真实生效`，第2次`隔离边界错误接受：深层符号链接逃逸`。**无xcodebuild build/test，无Test Suite passed原文，不冒充类测试或app实证**。
- 证据文件：`~/MemoryPalace-docs-media/perf-mac/sol/S9-R1-static-verification.txt`，1份3774 bytes；仅自己合成数据/路径与输出，不入git。中间源码/二进制/合成目录只在`/tmp/mp-macperf-sol/`，不再运行该核心二进制。
- 没做到 / 坏消息：原生Foundation临时目录不随TMPDIR改道，已补AppPaths显式入口但mac尾项仍未收尾；`Configuration.check`未拒绝祖先软链逃出根且末端文件缺失的场景。Python合成symlink检查过不能代替Swift真实检查。核心同一自测失败2次，按硬规矩5停止，不跑第3次、不弱化断言；整包编译/签名包/UUID、七根/偏好/网络实证、observer/T6/GUI/基线均未完成。
- BLOCKED：请车头裁决修复/复验，推荐先修缺失末端路径的祖先符号链接解析、获明确许可后复验核心，再收尾mac临时入口/编译。不是只等窗口即可测；后续静态通过仍须BLOCKED「等粟粟说现在测」，首启她当面拒绝隐私框。
- 下一切片：车头解除此门后先完成R1-0，不跳测量台/基线。未启动任何app、不碰她的app/真库/生产偏好/生产hub/iOS/设备，无性能收益或R1 MILESTONE声明。


## S9复验轮 BLOCKED 2026-10-16 20:07
- 做了什么：按车头解除裁决，修最深已存在祖先realpath/缺失末端边界并保留根外反例，新增根内软链真实落盘；收尾mac临时入口、五项非bench原值对照。保留Code扫描/监听。MCP误封显式假服务已复现并改为只限bench，原自动加载安全门不动。
- 改动文件：`git diff --cached --stat`为141 files changed, 2134 insertions(+), 486 deletions(-)。包含AppPaths/BenchIsolation、跨域根/侧效门、2个专用隔离脚本、AppPathsTests及StorageMaintenance自有临时目录回归、project.yml显式mp-code源清单和研究/plan/复盘/索引/日志/工位状态。产品新增987行、增删1458行；测试上界974行（整份879行host脚本也算测试），≤仅新增两倍1974，无新通用框架/helper库。commit：本条所属`perf(mac): S9`切片提交；S8文档为`4e02f009b`。
- 验证：最终`MP_ZONE_PAUSE=/nonexistent xcodebuild -scheme MemoryPalace -configuration Debug ... build`及同scheme `Release ... 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PERF_BENCH' ... build`均`** BUILD SUCCEEDED **`；仅`-destination 'platform=macOS'`、独立bundle id，走shim。完整22类mac定向`xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/<类>`，184测0失败且`** TEST SUCCEEDED **`；grep原文`Test Suite 'AppPathsTests' passed at 2026-10-16 19:46:57.559.`、`Test Suite 'MCPStdioTransportTests' passed at 2026-10-16 19:47:37.772.`；全部22类原文在外部证据。宿主home/suite/keychain独立且xctestVisible=1。
- smoke / 身份：核心CLI `MAC_ISOLATION_CORE_SELF_TEST PASS rejected=8 native_temporary_redirected=false`，根内软链真实写入/读回；host12项合成自测GREEN。Release真实Info为`com.susu.MemoryPalace.perfbench`，arm64 UUID `F0914E23-2C55-35CD-B8BF-CC1B57958261`；preflight exit0/READY且not_runtime_proof=true，没执行run。
- 证据文件：仅外部`~/MemoryPalace-docs-media/perf-mac/sol/S9-R1-static-verification.txt`与`S9-R1-revalidation-verification.txt`两份，均<1MB；后者含完整最终命令、22类passed、失败与预算。临时诊断源码/二进制已删，永久核心自测留仓库。
- 没做到 / 坏消息：新轮核心首遍仍因路径别名处理exit133，保留POSIX结果后过；追加4类首次36测8断言失败，MCP门修正后完整22类重跑全过，未弱化断言。系统Security/DetachedSignatures/AppIntents等提示不压制。真实bench未首启，生产七根/域对比、网络生命周期、observer/T6、GUI/基线均未实证；Debug未冻结测量归档，iOS未编。未操作她的/Applications花园、真库或生产hub。
- BLOCKED：**等车头审查**，请派astra审改道；推荐保留当前fail-closed边界，不跳审。审过后仍须**等粟粟说现在测**，首启隐私框她当面全拒。复盘在`docs/review-mac-perf-r1-0.md`，本轮不是R1 MILESTONE。
- 下一步：审查收口→T3窗口→真实R1-0隔离；不过不往R1-1测量台/基线走，不宣称性能改善。


## S10 BLOCKED 2026-10-16 21:00
- 做了什么：落实车头13条隔离审查裁决：内核写白名单为主防线、app跨进程门与固定合成程序；优先恢复可选降级和iOS逐字原样，再补缺失点段组合、Cursor根内真实扫描解析、测量编译门/通知/离线/枚举规范URL。plan §9已记裁决表，不改SwiftTerm、不建消费者宿主或通用框架。
- 改动文件：本切片30文件（19个产品Swift、2个XCTest、2个隔离脚本、7份计划/研究/实验/复盘/索引/工位/切片日志）；产品Swift+250/-41，测试保守+121/-18（整个Python脚本改动也算测试）≤2×250=500。只add本切片文件；commit为本条所属`perf(mac): S10`提交，不含外部证据/私人数据，不commit -a。
- 验证：`MP_ZONE_PAUSE=/nonexistent xcodebuild -scheme MemoryPalace -configuration Debug -destination 'platform=macOS' PRODUCT_BUNDLE_IDENTIFIER=com.susu.MemoryPalace.perfbench ONLY_ACTIVE_ARCH=YES build`及同scheme Release加`'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PERF_BENCH'`均`** BUILD SUCCEEDED **`。`env -u MP_PERF_RUN -u MP_PERF_SEED -u MP_PERF_ROOT -u MP_PERF_WINDOW_APPROVED MP_ZONE_PAUSE=/nonexistent xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS' -only-testing:MemoryPalaceTests/<类>`定向14类，230测0失败且`** TEST SUCCEEDED **`；已grep全部类，原文`Test Suite 'AppPathsTests' passed at 2026-10-16 20:55:49.690.`、`Test Suite 'CursorAdapterContractTests' passed at 2026-10-16 20:56:22.769.`、`Test Suite 'TestHostIsolationTests' passed at 2026-10-16 20:56:28.648.`。
- smoke / 包身份：核心CLI `MAC_ISOLATION_CORE_SELF_TEST PASS rejected=10 native_temporary_redirected=false`含根内软链真实写入/读回；`python3 scripts/perf/mac-isolation.py self-test`18项GREEN；无GUI普通Release CLI用实际核心/路径层忽略RUN/SEED、五项路径原值相同。最终Release静态BID=`com.susu.MemoryPalace.perfbench`，arm64 UUID=`3FFF5D25-8ECC-3C3B-98E5-6CDA6DA9F713`；未运行包。普通测试宿主home/suite/keychain独立，Debug输出未冻结成测量归档。
- 证据文件：仅`~/MemoryPalace-docs-media/perf-mac/sol/S10-R1-isolation-verification.txt`1份<1MB，含完整命令/全部14类passed/预算/身份/坏消息，不入git；临时诊断源码/两个自有CLI二进制已删，永久核心回归留仓库。
- 没做到 / 坏消息：核心首轮编译120秒超时，仅`error: interrupted`，没有修前行为复现；改完点段拒绝后新轮过。合成CodingSessionLibrary库/边车仍输出SQLite“vnode unlinked while in use”，另有Security主线程/DetachedSignatures/AppIntents提示；不压制、不扩大本刀修既有清理时序。真实bench、PTY/隐式临时落点、七根/偏好/网络生命周期、observer/T6、cua/基线均未实证，无R1 MILESTONE/收益声明，无iOS/设备操作。
- BLOCKED：**等粟粟说现在测**，首启隐私框她当面全点不允许。车头仅核阻断项，不再全量复审；无窗口不启动bench，不碰她的/Applications花园、真库或生产hub，不靠扩大系统写白名单绕门。
- 下一切片：T3明确授权后先跑真实R1-0隔离核验（任务书2a只路径mtime/偏好内存逐key、不披露值），不过即停；过了才进R1-1测量台，固定printf不得冒充L-term负载器。[研究](../docs/research-mac-perf-r1-0.md) / [复盘](../docs/review-mac-perf-s10.md)。


## S11 BLOCKED 2026-10-16 21:32
- 做了什么：收到车头传达粟粟T3「现在测」，重读任务书2a/2b与真实host启动/核验边界，先按plan §3.3申请mac租约；前置闸拒绝，立即停，真实R1-0未开始。
- 改动文件：仅`docs/plan-mac-perf.md`（当前停点/§9）、`docs/now/mac.md`、本日志3份阻断记录；无产品/测试/生产脚本改动。commit为本条所属`perf(mac): S11 记录T3租约闸阻断`，只add这3文件，不commit -a。
- 验证：`device-lease acquire mac --why 'sol S11 T3真实R1-0隔离核验，粟粟已说现在测'`，实际exit 75；原文`[device-lease] ⛔ 工位暂停模拟器 / 设备装包（粟粟 10-02）：工位暂停本地编译（粟粟 10-02：不要编译两遍，工位最多跑测试）。mac 不能租 mac——验 UI 等合进 master 后由 Warden 统一装 sim，提交时 --why 里写『要验 UI』`。本轮未build/test，**没有Test Suite passed原文**，不拿S10通过充当本轮运行证据。
- 证据文件：仅`~/MemoryPalace-docs-media/perf-mac/sol/S11-R1-0-lease-blocked.txt`，1份1266 bytes，不入git；不含生产内容或偏好值。
- 没做到 / 坏消息：没有取得mac租约，未启动bench/生产app，未触发首启弹框；未运行包预检、七根find、生产域内存对比、网络生命周期、observer/T6、cua或基线，不能判断实际隔离是否通过。无自有bench进程需回收，也无本轮租约可释放；未重试或用编译豁免/暂停文件/sim/Warden代做绕闸。
- BLOCKED：T3窗口已获授权，但mac运行租约仍被工位暂停闸拒绝。需粟粟明确处理；推荐仅放行本轮T3的mac租约，保持只mac、写白名单、生产数据限制不变；不把当前失败当作可跳过租约的授权。
- 下一切片：获租约门处理许可且T3仍有效后，先真实R1-0，不过即停。首启弹框才在终端打印「等粟粟点不允许」并等本人点完，不代点；通过才记DONE及继续窗口内实测，不占窗口做R1-1静态准备。窗口结束或需她再操作即BLOCKED停。


## S12 BLOCKED 2026-10-16 21:40
- 做了什么：收到车头明确mac运行/租约专项豁免后取得mac租约，按任务书2a做首轮真实R1-0；原内核写白名单、根/身份预检和生产元数据/内存偏好边界不变。候选非零退出与运行证明缺失，按「不过即停」停止，未重跑。
- 改动文件：仅`docs/plan-mac-perf.md`、`docs/research-mac-perf-r1-0.md`、`docs/now/mac.md`和本日志4份记录；产品/永久测试改动0。commit为本条所属`perf(mac): S12 记录真实隔离首轮RED`，只add本切片文件，不commit -a；临时PID通知入口已删，合成运行根暂留。
- 验证：`MP_ZONE_PAUSE=/nonexistent device-lease acquire mac --why "sol T3 R1-0 隔离核验（粟粟已说现在测）"`实际`LEASED mac`。原host真实`run --app <S10 Release候选> --root /tmp/mp-macperf-sol/bench-s12-t3-3ea7d34d883a --uuid 3FFF5D25-8ECC-3C3B-98E5-6CDA6DA9F713 --seed isolation --window-approved --observe-seconds 30 --timeout 180`，PID63047；最终host exit70/RED，`app_exit=78`、APP_EXIT/ATTESTATION，观察完成0秒。没有build/test/类passed，不拿S10静态通过替代本轮。
- 已观测边界：偏好内存逐key same、变化键0，无值输出/落盘；七根均完成路径mtime检查，6存在更新路径0，Caches根原不存在，扫描无错误/无内容读取。5次进程树socket采样、max_owned_processes=1，无网络失败分类，但不构成完整观察或网络生命周期通过。
- 证据文件：仅外部`~/MemoryPalace-docs-media/perf-mac/sol/S12-R1-0-report.json`（3304 bytes）与`S12-R1-0-run.txt`（3061 bytes），均<1MB、不入git；前者仅授权元数据/偏好键名，后者命令/租约/失败/清理。
- 没做到 / 坏消息：缺实际配置/楼层/observer证明，不能确认App.main/GUI完整首启。`cua-driver call list_windows '{"pid":63047,"session":"sol-s12-r1"}'`返回daemon不在/exit1，没有窗口或截图，无法确认首启弹框及人工拒绝，未代点。退出78原因未知：原host丢弃stderr，不推断是哪个权限问题。无T6、UI回归/基线、R1 DONE或MILESTONE。
- 清理 / BLOCKED：host按原finally完成自有树清理，无PROCESS_CLEANUP失败；测完立即`device-lease release mac`，实际`[device-lease] 已释放 mac`。当前停在候选退出78/证明缺失与cua不可连接，不再占窗口做静态准备、不改白名单/生产脚本、不走iOS/sim。
- 下一切片建议：等车头裁决；推荐先恢复cua、把bench自身失败原因有界落在bench根以定位78，权限不变；获准且T3有效后重做真实R1-0，不过即停，不跳R1-1。当前没有要求粟粟点击未确认的弹框。


## S13 BLOCKED 2026-10-16 22:12
- 做了什么：按车头批准恢复后的cua/根内日志定因旧78；原写白名单下最小CLI复现Foundation `.atomic`的Cocoa513/EPERM，而直接写成功。bench Blob和启动证明改同目录暂存+rename，保留楼层fail-closed、原子替换，非bench/iOS原写法；不改写白名单。
- 改动文件：本切片4份源码/核心回归（BenchIsolation、BlobStore、mac-isolation.py、core-selftest.swift）+7份研究/计划/复盘/索引/实验/工位/切片日志。产品Swift新增34；整个host脚本改动也当测试则新增55≤2×34=68，永久核心回归仅2行，无框架。只add本切片文件，commit为本条所属`perf(mac): S13 bench根内日志与原子替换`，不commit -a。
- 验证：原沙盒真实CLI日志合并/262144字节溢出RED通过；实际配置helper替换正确、rename失败保旧/无暂存残留PASS；核心CLI `MAC_ISOLATION_CORE_SELF_TEST PASS rejected=10 native_temporary_redirected=false`含真实原子替换。`MP_ZONE_PAUSE=/nonexistent xcodebuild -scheme MemoryPalace -configuration Release -destination 'platform=macOS' 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PERF_BENCH' PRODUCT_BUNDLE_IDENTIFIER=com.susu.MemoryPalace.perfbench ONLY_ACTIVE_ARCH=YES build`实际`** BUILD SUCCEEDED **`；新arm64 UUID=`307C0D12-F989-378D-99C3-AA1FFC9EE1B9`。本轮未跑XCTest，**无类passed原文**，不冒用S10。
- 真实运行：两次均按指定`MP_ZONE_PAUSE=/nonexistent device-lease acquire mac --why "sol T3 R1-0 隔离核验（粟粟已说现在测）"`拿到。旧包PID49391输出679字节，Blob错误→楼层fail78，另有`~/.claude`7条路径mtime更新，保持RED不归因豁免。重编后唯一复验PID25734、`run --seed isolation --window-approved --observe-seconds 30 --timeout 180`，无旧78，host70/RED/ATTESTATION，候选由host清理为-15，观察完成0秒。
- 最终证据：已生成bench楼层、双新UUID、六开关全开和observer/callback Int.min/Int.max；证明root/caches为/private/tmp，其余4路径字段/tmp，host canonical拒绝；不直接定性成真实写出根、不放宽判断。七根全检查6存在更新0/1个Caches原缺，偏好same/变化键0，无值落盘，6次socket采样不代表完整生命周期。
- 证据文件：仅外部`~/MemoryPalace-docs-media/perf-mac/sol/`下`S13-diagnose.json`、`S13-verification.txt`、`S13-final-report.json`、`S13-final-output.log`4份、均<1MB，不进git；只含授权元数据与bench自身输出。
- 没做到 / 坏消息：最终433字节自身日志还有示例卡图片保存权限错；cua旧会话已结束，按工具提示用新标签查询自有PID窗口仍空，无截图/GUI/首启人工拒绝验收，未代点。完整R1-0未过，无T6/基线/DONE/MILESTONE/性能收益，未操作生产app、生产内容或iOS。
- 清理 / BLOCKED：两次都测完立即`device-lease release mac`（均实际「已释放 mac」）；本轮/旧合成根、CLI家目录、marker、探针源码/二进制全部清，glob只剩模块缓存。候选路径证明与新示例卡错误不过即停，未进一步修/重跑；无lease继续占窗口。
- 下一切片建议：车头准后，对实际getter结果用现有Configuration.check/POSIX realpath规范再输出（不硬填预期、不改host判据），另定因示例卡保存权限；有效T3再真实R1-0，不跳R1-1。详见[研究](../docs/research-mac-perf-r1-0.md#s13--定因修复后仍blocked--2026-10-16-2212) / [复盘](../docs/review-mac-perf-s13.md)。

## S14 BLOCKED 2026-10-16 22:53
- 做了什么：按车头S13裁决，将实际getter和host期望双侧realpath，补卡原件最后一层active mac bench原子写；只`.claude`mtime保留但不单独RED，其余六根及消失/错误/超限照旧。host保存精确策略/SHA-256，新增本PID只open、不创建/截断/写的根外marker canary及有界系统Sandbox日志；不扩写白名单、不改非bench/iOS原写法。
- 改动文件（stat摘要）：4份源码/核心回归（BenchIsolation、SillyTavernImportStores、mac-isolation.py、core-selftest.swift）+7份计划/研究/复盘/索引/实验/工位/切片日志，共11文件。产品新增164（Swift47+host117），测试新增83（核心17+host66）≤328；移除重复普通PNG读取/同值覆盖和未改错误分支的新测试，无框架。commit为本条所属`perf(mac): S14 规范路径与bench卡原件，补内核拒写证据`（实际号见交付回复/外部验证记录），只add这11文件，不commit -a。
- 验证：`MP_ZONE_PAUSE=/nonexistent xcodebuild -scheme MemoryPalace -configuration Debug -destination 'platform=macOS' PRODUCT_BUNDLE_IDENTIFIER=com.susu.MemoryPalace.perfbench ONLY_ACTIVE_ARCH=YES build`与同参数Release加`'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PERF_BENCH'`均实际`** BUILD SUCCEEDED **`。`xcodebuild test -scheme MemoryPalaceTests -destination 'platform=macOS'`只定向AppPathsTests、TestHostIsolationTests、CardSampleTests、CardStorageMigrationTests、CardLibrarySaveTests、CardPNGExportTests（完整env/六个-only-testing参数见外部记录）；六类47测0失败，全类passed已grep及`** TEST SUCCEEDED **`。原文`Test Suite 'CardSampleTests' passed at 2026-10-16 22:49:42.771.`、`Test Suite 'TestHostIsolationTests' passed at 2026-10-16 22:49:42.956.`；宿主真实xctest-home/私有suite/keychain，非bench五项FileManager原值对照通过。
- 无GUI烟测：核心CLI `MAC_ISOLATION_CORE_SELF_TEST PASS rejected=14 native_temporary_redirected=false`；最终host20项合成自测GREEN。真实产品CLI PID89790规范实际getter、68字节PNG替换/JSON保存/暂存清理，marker inode/size/mtime未变；新host读到kernel PID0发出的本PID canary及dtrace两条拒写，完成/可见性通过，不是完整App验证。
- 新候选：Release BID=`com.susu.MemoryPalace.perfbench`，arm64 UUID=`4F758868-5338-38BC-A949-ACFC0A7B4D5B`，静态preflight READY/`not_runtime_proof=true`，未建运行根或启动；Debug随后用作普通隔离单测宿主，不是冻结测量归档。首个/private/tmp输入被既有CLI字面/tmp契约拒绝，改调用输入通过，没有放宽路径判据。
- 证据文件：外部`~/MemoryPalace-docs-media/perf-mac/sol/`下`S14-kernel-probe.json`、`S14-kernel-cli.json`、`S14-host-selftest.json`、`S14-preflight.json`、`S14-verification.txt`，恰5份、各<1MB，不入git；原始私有cache路径只在外部旧PID记录，md不抄。
- 没做到 / 坏消息：附加“只有canary”断言被实际`/dev/dtracehelper`拒写推翻，保留全部拒绝、不重跑helper/加放行；deny不是已允许写。Sandbox不提供allowed写全量事件，策略/内核canary不证明系统绝无丢失；缺权限/完整记录/来源/可见性仍RED。原有私有单测临时同名文件迁移失败、Security主线程/DetachedSignatures提示保留，未压制/扩修。没有新bench App.main、完整示例卡/TCC/GUI、生产七根/偏好新实证、完整观察或R1基线，不声明性能收益。
- 清理 / BLOCKED：T3已关闭，本轮未acquire mac或用cua；一次性源码/二进制/家、kernel合成根/marker全部清，glob无本轮遗留，模块缓存保留。**BLOCKED「等粟粟说现在测」**：仅需本人新窗口授权，不借旧窗口自行跑bench。
- 下一切片：新T3获准后取mac租约、以新候选重新做真实R1-0，不过即停并立即释放；有隐私框才打印「等粟粟点不允许」等本人处理，不代点。隔离真过才记DONE，不跳R1-1。[研究](../docs/research-mac-perf-r1-0.md#s14--t3关闭后的静态修复与内核证据--2026-10-16) / [复盘](../docs/review-mac-perf-s14.md)。

## S15 BLOCKED 2026-10-19 21:16
- 做了什么：按最新新T3“测啊”指令，立即停止R1-1/R1-2静态调查并取消两个scout；产品工作区未改，未编译。使用车头刚核UUID=`4F758868-5338-38BC-A949-ACFC0A7B4D5B`的S14现成Release，先执行指定租约前置门，门失败后立即停，不启动候选。
- 改动文件：仅plan、R1-0 research、工位状态与本日志4份记录；产品/测试改动0。commit为本条所属`perf(mac): S15 记录新T3租约会话身份阻断`（实际号在交付回复/外部证据），只add本切片4文件，不commit -a。
- 验证命令与实际原文：`MP_ZONE_PAUSE=/nonexistent device-lease acquire mac --why "sol T3 R1-0 隔离核验（粟粟10-19说测啊）"`后台执行一次，exit64/0.09秒；`[device-lease] 你的 session 进程 56409 已经不在了（CLAUDE_PID / MP_SESSION_PID 要是常驻进程）`。没有build/test或新的类passed；不借S14的47测当本轮通过。cua仅status/describe，daemon running，没有窗口查询/点击。
- 证据文件：外部`~/MemoryPalace-docs-media/perf-mac/sol/S15-R1-0-blocked.txt`单份<1MB，不入git；只含命令/退出/会话元数据，无生产数据内容。
- 没做到 / 坏消息：未取到mac租约，尚未运行真实R1-0；没有bench PID、TCC弹框、生产偏好比较、七根扫描、内核拒写/网络生命周期或完整观察结果。未启动/退出她的app，未代点或虚构等待弹框，无DONE/MILESTONE/基线或性能收益。
- 清理 / BLOCKED：没有自有lease可释放，没有新/tmp运行根/marker可清，不删他人/旧模块缓存。不改/伪造CLAUDE_PID、MP_SESSION_PID或租约脚本，不绑定临时shell/他人PID、不让别人代持或换设备。当前阻断是可信会话身份失效，不是尚未收到“现在测”。
- 下一切片建议：由启动器修复本会话真实常驻PID注入/重新挂接；车头确认修好且T3仍有效，再由本会话原命令acquire，LEASED后才真实R1-0。真正弹框才终端打印「等粟粟点不允许」并等她处理，不过即停、测完立即release并清自有合成根；不占本窗口恢复静态调查。[研究](../docs/research-mac-perf-r1-0.md#s15--新t3开启但租约身份失效--2026-10-19-2116)。

## S16 DONE 2026-10-19 23:22
- 做了什么：按车头指定`MP_SESSION_PID=90376 MP_SESSION_ID=sol-macperf`后台取得mac租约，用S14现成Release UUID=`4F758868-5338-38BC-A949-ACFC0A7B4D5B`跑真实R1-0隔离实证；不重编。临时Notice只通知自有PID，不改变原main/perform_run核验、观察或清理。
- 改动文件：仅plan、R1-0 research、工位状态、本日志4份记录；产品/测试0。commit为本条所属`perf(mac): S16 记录真实隔离GREEN与后续实测缺口`（实际号见交付回复/外部证据）；只add本片4文件，不commit -a。
- 实际命令：`MP_SESSION_PID=90376 MP_SESSION_ID=sol-macperf MP_ZONE_PAUSE=/nonexistent device-lease acquire mac --why "sol T3 R1-0（粟粟10-19说测）"`→`LEASED mac`。原host `run --app <S14现成包> --root /tmp/mp-macperf-sol/bench-s16-t3-e8acfaaf7dc4 --uuid 4F758868-5338-38BC-A949-ACFC0A7B4D5B --seed isolation --window-approved --observe-seconds 30 --timeout 180`→host exit0/GREEN、failures空、PID52453，完整观察30.110896秒。没有build/test或新类passed，不借旧47测充数。
- 实证：独立BID/bench楼层/双UUID/规范getter/startup observer注册回调Int.min/Int.max核对；七根扫描完整无错/消失，六根更新0、Caches原缺仍缺，`.claude`3条mtime只记；生产偏好same/变化键0，无值输出落盘。系统kernel唯一同PID拒写为受控marker，canary可见/query_complete=true，精确策略/哈希留证；不声称allowed全量事件或系统无丢失。130次IP socket采样/max_owned1，有限窗不是逐包/系统代理保证。
- 实际界面：cua按自有PID见窗口14728当前Space/on_screen，截图开屏/输入区，AX预算截断；未见可确认隐私框、未虚构打印等待或代点，不声称全局TCC/完整GUI验收。自身263字节日志无旧保存错误，隔离根真实PNG/JSON原件存在，HangProbe只有start。`xcrun xctrace list templates`成功、Time Profiler/SwiftUI/Animation Hitches列出，未录trace。
- 证据：仅外部`~/MemoryPalace-docs-media/perf-mac/sol/`下`S16-R1-0-report.json`、`S16-bench-window.png`、`S16-bench-output.log`、`S16-R1-0-run.txt`4份、各<1MB，不入git；无生产数据内容。
- 清理：收齐报告后立即`MP_SESSION_PID=90376 MP_SESSION_ID=sol-macperf device-lease release mac`，实际`[device-lease] 已释放 mac`。app_exit=-15是host正常清理，不是崩溃；自有bench根/marker已删，glob未找到，不动模块/他人缓存。
- 没做到 / 后续BLOCKED：DONE仅隔离。T6自采未自然触发，已核私有takeSample走心跳/CPU门、调试页仅日志/Finder，没有已验证可用的强制自采驱动；本计划PerfHarnessMac/R1-2也未实现。不能用外部sample替代自采、空夹具代替性能基线或在本窗口重编。无A/A、基线/MILESTONE/性能收益；完整R1-0的T6/TCC仍未宣称齐。
- 下一步推荐：请车头结束本窗口后恢复已授权R1-1/R1-2静态，并裁决仅bench可控自采触发方案，后续候选/窗口实证；当前停在后续前置缺口，不是隔离失败，不重跑已经通过的隔离，也不自行恢复静态调查。[实证](../docs/research-mac-perf-r1-0.md#s16--真实隔离实证done--2026-10-19-2322)。


## S17 DONE 2026-10-20 00:40
- 测量台、M1–M9 真驱动和入口绑定静态齐：19份源码/回归、6份文档。
- mac 两包、正式包符号核验及七类最终通过；CPU 单位校准过，首轮测试夹具漏建已修。
- 命令、完整 passed 与提交号见外部 S17 证据；没启动 bench、没租设备，iOS 留 Warden。
- 下一片接 R1-2 和仅测量包的自采；界面、夹具和基线还没验。[复盘](../docs/review-mac-perf-r1-harness.md)。

## S18 BLOCKED 2026-10-20 01:25
- 钩子和仅测量包自采静态齐；改动 15 份产品源码、1 份 host、2 份回归、7 份文档，细节外部留证。
- mac 两包、正式包符号、八类 68 测、偏好原组件 CLI 和 host 自测通过；iOS 留 Warden。
- 没启动 bench、没租设备、不念；真实自采、界面和基线没验。[复盘](../docs/review-mac-perf-r1-hooks.md)。
- 等车头开窗；窗口内先验本包自采和钩子，不拿合成回执当实证。

## S19 BLOCKED 2026-10-20 01:35
- 本包自采产出了，但 host 因文件大小门和内核 canary 不可见判 RED，未验钩子、场景或 A/A。
- 已立即释放 mac、清自有根；只改六份记录，不重编、不重跑、不念；命令、身份和摘录在外部 S19 证据。
- 验证：原 host 失败，完整观察没开始；本轮没跑单测，不拿旧 passed 充数。
- 等车头裁决：推荐流式核验原采样、只留有界摘录，并解决 canary 可见性；判据未放宽。

## S20 BLOCKED 2026-10-20 01:55
- host 流式核验和实时日志已改；同包自采样本、完整观察过了，系统 canary 仍不可见，整体 RED。
- host 自测与真实日志流烟测通过；App 没重编，改动一份脚本及七份记录，细节外部 S20 留证。
- 已释放 mac、清自有根；没重跑，没验钩子、场景或 A/A，未取得界面截图，不念。
- 等车头裁决可读内核日志来源/权限；不能拿 App 自报拒写替代系统证据，判据不放宽。

## S21 DONE 2026-10-20 15:11
- 全机计数和静默四证已接；最终同包走可见 canary 的常规路径 GREEN，静默分支仅自测。
- host 最终自测过；首轮全机流格式不兼容已修，一份脚本及七份记录，细节外部 S21 留证。
- 未重编、未查 HID；mac 已释放、根已清，真实钩子、场景和 A/A 未验，不念。
- 接着核现成种子与运行器；A/A 若执行，记粟粟在用电脑、数据可能有噪声。

## S22 BLOCKED 2026-10-20 16:31
- 去掉哈希/重复核验，补真实种子和 mac 运行器；本切片改动摘要见外部 S22。
- 两份 mac 编译、普通 Release 无测量符号和新增行为烟测过；没重跑旧整套或未改类，iOS 留 Warden。
- 窗口编译期间到点；没租 mac、没启动新包，临时烟测已清，真实钩子、场景和 A/A 没验。
- 等车头开窗，用归档测量候选隔离一次后继续；跨窗模板暂存需裁决，建议独立合成目录。

## S23 BLOCKED 2026-10-20 16:52
- 获批模板目录/HID 门已接，新目录烟测过；改动摘要和现有失败报告见外部 S23。
- 首条 CLI 根别名被拒未起 App；修正后实际一次隔离 RED，全机日志活跃却缺自身 canary，不越闸。
- 已释放 mac、清根/marker；没重编、没重核 UUID、没哈希或重跑旧自测，未取得性能数字。
- 等车头裁决：建议只修 host 等订阅就绪再试，不放宽判据；真实钩子、M1–M9、A/A 未跑。

## S24 BLOCKED 2026-10-20 17:03
- 只修 host 随机串握手，15 秒门；新增的唯一真实自测通过，改动摘要见外部 S24。
- 同包本窗唯一复验已见 logger 串，仍缺自身 canary、同因 RED；按裁决不再调、不重跑。
- mac 已释放、自有根/marker 已清；没重编、重核 UUID 或哈希，真实钩子、M1–M9、A/A 没跑，没拿到性能数字。
- 等车头裁决后续，不放宽当前判据；本轮三份小证据保留失败和握手结果。

## S25 BLOCKED 2026-10-20 19:10
- 四证判据与唯一新增自测已过，S24 旧证按授权复用 GREEN，原始失败保留；没重跑隔离或核 UUID。
- 免 HID 后首轮 host 启动前报 KeyError:0，App 未启动，九场景零完成，仍无性能数字。
- 已释放 mac、清自有工作/批次根，获批模板目录保留；查询选项已修并真实烟测，出错后没追加 App 运行。
- 本切片摘要及三份小证据见外部 S25；A/A 注记已接但没执行，不伪造报告，不念。

## S26 BLOCKED 2026-10-20 20:40
- 真种子已完成：2700 对话/25万节点、Code 增量 45 次，冻结待复用；host/bench 修复及摘要见外部 S26。
- mac Release+PERF 构建、新包一次隔离 GREEN；未重跑旧自测、Debug/iOS、哈希或同包身份核验。
- 首次 M1 未激活前台，10 秒超时、最长忙段 1.58 秒，不算基线；续跑直到截止未拿到测量锁，最后阻因未留，激活修复尚未实测。
- 有效场景 0、A/A 未跑，噪声注记保留；mac 已释放、工作根已清，模板仅留合成种子。等车头开窗续跑，不重做种子。

## S27 BLOCKED 2026-10-20 20:59
- 复用冻结种子和 GREEN 单跑 M1，没重编/重隔离；新增 runtime 阻因和五分钟诊断，摘要见外部 S27。
- 两个新增边界烟测过；实际五分钟卡点是屏幕锁住且睡眠，负载/内存正常，本人当前 console 元数据确认真锁屏。
- App 未启动，激活修复未实证，有效场景 0、A/A 未跑；不绕认证、不删前台门。
- mac 已自动释放、本批根已清、合成模板保留；车头先解锁并亮屏后续窗，下一步仍先验 M1。

## S28 BLOCKED 2026-10-20 23:30
- 静默等门/批次防睡眠已实证，三项新增 host 烟测过；没重编、重隔离、哈希、重查 UUID 或重跑旧测试。
- Cua 会话和窗口创建竞态已修，自有窗口真前台已验证；M1 仍 10 秒就绪超时，不能算基线。
- 已查明默认左栏关闭却要求可见行，输入原生见证另待验证；有效场景 0、M1–M9 整批/A/A 未跑。
- 最后又锁屏，静等至截止收尾；mac/临时根回收、种子留，摘要外部 S28。下切片先修 bench 测量器再换包实证，不硬过。

## S29 READY
- 包好了，可以跑。
- 一次 mac Release+PERF 构建通过，测量器类 9 测通过；先隔离新包，再单跑 M1。
- 等门只看解锁和亮屏，不查 HID，不念。

## S29 BLOCKED 2026-10-21 00:31
- 必挂前置已补，定向 9 测、一次 Release+PERF 通过；包和符号已归档，摘要外部 S29。
- 新包首次真实隔离 RED：生产 agent 目录两份日志 mtime 更新，七根零更新未过，不能归因。
- App EPERM/marker 不变/偏好 same 过但不够；未跑新 M1、整批或 A/A，不重跑、不放宽。
- mac 已释放、本轮根/marker 清、种子留；建议车头给该目录安静窗口同包重验，不动生产进程。

## S30 CONTINUE 2026-10-21 01:04
- 同包定点隔离 GREEN，44.36 秒结束且早于下一触发；判据未改、生产未动，证据外部 S30。
- 单 M1 仍超时；真实自有窗口已见聊天行和未聚焦 TextField，旧见证只找 NSTextView，不把零回调当零卡顿。
- 全部断言保留，整批/A/A 未开始；继续 S31 修原生输入见证和 M6 编辑器路径，不停下问车头。
- 本轮根、marker 和诊断脚手架清，包/种子留；不重核旧包 UUID、不哈希、不刷旧测试。

## S31 READY 2026-10-21 01:31
- 包好了，可以跑；原生输入三测通过，新 mac Release+PERF 一次编成，归档和单次身份记录在外部 S31。
- 修未聚焦 TextField 见证、实际 bounds 交集和 M6 原生字段编辑器；原十秒/场景/隔离判据不变，未动生产。
- 立即新包定点隔离，过后单 M1、整批和 A/A；冻结种子复用，不哈希、不重核旧包、不重跑已过整套。

## S31 CONTINUE 2026-10-21 01:52
- 新包定点隔离 DONE：GREEN，50.82 秒且早于下一触发；四证全过，注记「系统日志未记本次拒写」，证据外部 S31。
- 单 M1 仍被原断言拦截：侧栏已就绪，composer 见证缺失、输入未就绪，有效样本 0，整批/A/A 未开始。
- 原生三测和一次编包过的事实保留，不冒充端到端通过；继续 S32 把见证贴到实际 mac 输入域，并修同类矩形越界。
- 本轮自有进程/租约/临时根已回收，冻结种子和配额账留；不喊、不问、不重核旧包或哈希。

## S32 READY 2026-10-21 03:24
- 包好了，可以跑；先用现成 S31 取得完整真实 NSView，才修三行并只编一次新 mac 候选，证据外部 S32。
- 实物里的聊天输入和物理见证都在，输入可接焦点；只拒离窗登记覆盖、修真实几何，不挪 UI、不造焦点、不改十秒或断言。
- 新包/符号归档、身份只核一次；立即定点隔离后续单 M1、整批/A/A，原失败和调试暂停均不算性能样本。

## S32 BLOCKED 2026-10-21 03:34
- 现包真实 NSView 已取到，输入本在且可接焦点；只改三行测量器、一次 mac 编包已过/提交，未重刷旧测试，证据外部 S32。
- 新包定点隔离 RED：总日志行数在 PID 过滤前超限；四证观测都过，但审计没完成，不自判 GREEN，修后 M1/整批/A/A 均未跑。
- mac、进程、临时根/marker/脚手架已回收，模板/配额留；没动生产/iOS/判据，没再编。
- 需车头裁决；建议全机只计数、本 PID 证据单独限额，丢失/格式错/本 PID 超限仍 RED，四证不改、同包定点重验，当前未实施。

## S33 HOST DONE 2026-10-21 03:51
- host 限额已修：全机只计数、本 PID 证据单独限额；唯一新增自测 GREEN，没刷旧套、没编 App，证据外部 S33。
- 同一 S32 包定点重验 GREEN，44.39 秒、四证全过；保留「系统日志未记本次拒写」注记，没放宽判据。
- 隔离阶段 mac 已释放，已接单 M1→原九场景→正式 A/A；后续尚未验完，不叫基线完成。
- host 工程故障以后自行修完继续；真实隔离风险、认证和原 T4 配额不绕，命令/改动/提交在外部记录。

## S33 DONE 2026-10-21 03:59
- host 新自测与同包定点隔离 GREEN，未编 App/重核身份；S32 登记修复的真实单 M1 终于通过。
- 正式 1 进程：就绪 1.821 秒，最长主线程忙 9.42 毫秒；探针不进分母，这不是基线或尾延迟。
- M2 A/B/C 的原生点击都失败，直接打开各阶段过；点击仍拿扩大的 visibleRect 算位置，继续 S34 按实物纠正，不改断言。
- 原 T4 已 8/8，不绕账或换身份；进程/租约/临时根已清、模板留，修后实测需追加额度或次日窗，必要证据外部 S33。

## S34 READY 2026-10-21 04:13
- 包好了，可以跑；M2 只修一行点击范围，实物几何烟测旧点在行外、新点在行内，一次 mac 候选编成/归档，身份只核一次。
- 今晚按累计拿锁两小时、不按八块卡；单块仍十五分钟，编译排队先杀自有测量/负载再放锁，空后重跑新进程，部分样本不进分母。
- 仅新增调度边界自测 GREEN（真实文件锁/预算/让锁分母），未刷旧套、未伪造生产队列，证据外部 S34。
- 立即新包定点隔离后 M2–M9/A/A；不重跑单 M1，不改十秒/断言/四证，不清账、不念。

## S34 补裁决 2026-10-21
- 按车头最新裁决，本窗额度账只记不挡，取消机械休息；单块十五分钟、编译优先和真实隔离边界仍留，不清账、不念。
- 仅新增记账非阻断自测 GREEN，默认未授权政策与单块边界仍守；无需重编 App，候选不变，隔离/原场景连续入口已启动。

## S34 实测推进 2026-10-21
- 新包隔离 GREEN；M2 全部冷/热/同会话/原生点击阶段过，M3 原报告完整校验过；都只是单进程实证，数字外部，不称基线。
- Cua 实际已激活但 AX 焦点旁证暂缺、负载均值两处 host 误拦已去；原生 active/key/业务断言不动，噪声快照与旧失败原样留。
- M3 后再启误读上次楼层，入口显式传合成楼层启动参数；早退原文已采到，不碰根外偏好、不改隔离守卫，继续 M4–M9/A/A，不重编或重核身份。

## S34 场景推进 2026-10-21
- M4 启动楼层已纠正；只有日历打开超时，其余开合阶段过，失败保留、不称 M4 通过，独立 M5–M9 继续。
- 日历先取实物再集中修测量器，不凭读码再盲编；同包/隔离继续复用，没碰生产数据、没放开写白名单或认证。

## S34 DONE 2026-10-21
- 首批实数已出：M2 全阶段、M3 原报告、M7/M8及完整十分钟 M9 过；都非正式基线，数字和噪声记录外部。
- M4 日历、M5 出现事件、M6 两条历史不足及滚动边界问题已留原失败；先取实物，再集中修下一候选，不缩断言/分母、不再刷已过项。
- 本轮原生取证/测量进程、负载和租约已收；仅下一候选一次 mac 编译在跑，不念，继续失败项与正式 A/A。

## S35 READY 2026-10-21 05:23
- 包好了，可以跑；M4停靠前置/M5页出现身份/M6长历史与滚动边界集中一次 mac 编成、归档，身份只核一次。
- 代码仅 mac bench；冻结模板、十秒/一像素/业务断言和正式分母不改，不刷旧自测或旧包已过项。
- 立即新包隔离一次后复验 M4/M5/M6，过了原 A/A；这是待实测候选，不称修复已闭环，细节外部 S35。

## S35 host DONE 2026-10-21
- 四证汇总漏接已有 Claude 目录 mtime 豁免，误判已修；真实 EPERM、marker不变、其余根无更新、偏好相同，原噪声路径仍完整留。
- 只新增该边界自测 GREEN：其它根、根消失、未获豁免或缺数据仍拒；同一次实证重判 GREEN，不重跑隔离、不编 App、不重核身份。
- 失败项后验与原 A/A 已接着跑；细节外部 S35，不改原写白名单，不念。

## S35 采集修正 2026-10-21
- 日历业务/动画/稳定帧已到，但连续忙块让安静窗过不了；这是原计划要求保留的超时读数，不应逼成全绿。
- 修 host 不把超时当协议缺损：原失败/断言/十秒保留且不丢分母；有超时就不报成功子集的 ready 分位数，A/A 单列失败数，真正动作/证据错误仍拒。
- 仅新增该统计边界自测 GREEN，原生原报告完整校验过且仍标失败；不重播日历、不编 App，接着 M5/M6 和原 A/A。

## S35 A/A 续跑 2026-10-21
- 失败项收集完成，超时照留；A/A 已采九十三个进程，运行中的内存 warning 又被 host 当停点，现改为记噪声，原快照不删。
- 只新增该边界自测 GREEN，默认/过期策略、critical、编译和锁屏控制保留；完整样本不重跑，仅中断那次换新 ID，计划分母不变。
- 同包、同隔离接着原 A/A；不编 App、不重核身份、不清账，不念。

## S35 生产器修正 2026-10-21
- A/A 已采一百零七个进程；首个 L1b 窗文件真在长，但写入器一直持有句柄，原生文件事件直到关闭才到，不是该放松监听断言。
- 同沙盒实测定因；只改每次追加后关闭，剂量/节奏不动，真正生产器烟测已触发全部三文件回调。该无事件窗留作无效，原完整样本不重跑。
- 同包、不重编/重核/隔离，换新 ID 只重试该窗后续原 A/A；冻结模板和原分母不改，不念。

## S35 DONE 2026-10-21 10:02
- A/A 已收齐，采集完整但性能红；日历、流式和少量 Code 点击超时都留着，分母没缩。
- 两臂各十二进程、两档各三完整窗；噪声带和原生失败已写基线，命令/身份/原报告只放外部同名证据。
- 复用 A 臂继续补缺的四档，不重编/重验旧项；还不是 R1 MILESTONE，不念。

## S36 BLOCKED 2026-10-21 12:02
- 五档各三完整窗已齐，后台激活三次超时也留着；终端真实PTY零喂入，不能凑有效分母。
- 同白名单已证实开PTY被内核拒绝；没扩权限，需车头审最小设备例外，不放开整个设备目录。
- 两份主线程归因已取，SwiftUI没有效数据；数字/命令和原失败只放外部同名证据，不重编/重验旧项。
- mac已释放、工作根/脚手架清，模板/原账/有效批次留；解权限后补终端和剩余R1，不念。

## S37 READY 2026-10-21
- 同源mac Debug包好了，已归档、身份只核一次；冻结Release不重编，五档实数不重验。
- 五分钟解锁门已挂，新状态边界烟测GREEN；锁屏不开App、不租设备，解锁亮屏后自动续跑到新截止。
- PTY例外等批、沙盒不动；继续剩余归因/Debug/UI，完整命令和包索引在外部同名证据，不念。

## S38 READY 2026-10-21
- 独立mac UI回归和仅bench的流式/主线程前置已编好；首轮查询API写错，已修，没启动App。
- 新host只测新增隔离边界，烟测GREEN；UI归档不替换原Release和同源Debug，身份各只核一次。
- 定向单测和真实UI还没跑；五分钟解锁门继续挂着，PTY不动、不念，细节只在外部同名证据。

## S39 READY 2026-10-21
- 两个离线工具实跑过，mac两配置、正式包剔符号和相关两类单测过；没跑bench或租设备。
- 设置分组读盘挪后台，临时输入已清；旧日期中位数与历史稿不符、旧栈已没了，不补造。
- 解锁门继续挂，自动接剩余归因/Debug/独立UI；命令、passed原文和包索引在外部同名证据，不念。

## S40 READY 2026-10-21
- 两条PTY数据写获批已加，唯一真实PTY自测GREEN；没加其他设备或元数据权限，没跑旧用例。
- 旧host隔离凭据已失效；解锁后只做一次新隔离，过了补终端三窗，再接原顺序。
- 解锁门继续，没租设备或启动bench；旧包/种子/有效数据不重编重验，细节外部同名证据。

## S40 DONE · PTY与新隔离实证 2026-10-21
- 精确例外的唯一自测过，新host真实隔离过，App真实PTY已收字节；包没重编或重核身份。
- 两次终端全长窗末尾失焦，均作废留原报告，三个有效窗还没齐；正定位，不改判据。
- mac已释放；只读诊断继续接剩余原顺序，命令/原件/坏消息在外部同名证据，不念。

## S41 DONE · 选窗修复 2026-10-21
- host不再选零尺寸占位窗，测量/归因/UI都改传精确主窗；只跑新用例过，真实选窗已验。
- 激活仍partial，终端三有效窗仍缺，不把局部修复写成全绿；App没重编、隔离没重复。
- 独立归因继续，不重录已有两项；细节和坏消息在外部同名证据，[复盘](../docs/review-mac-perf-r1-window.md)。

## S42 DONE · 归因事实收口，仍有缺口 2026-10-21
- 八份新栈表真实导出，已有两份没重录；四份失焦只作线索，不补基线分母。
- SwiftUI能保存但更新/因果都零行，没冒充全绿；测量器指纹成本也没当产品病因。
- 原策略继续核正常停录，先接可达Debug/UI；原件和坏消息在外部同名证据，[复盘](../docs/review-mac-perf-r1-profiler.md)。

## S44 DONE · 指纹不入窗口 2026-10-21
- 查了冻结S35源码：before/after指纹都不直接进ready/busy，整进程占比不拿来扣旧数字。
- 启动索引修复、M2树数据应用两个产品热点已进基线，采样CPU不冒充墙时。
- 没重跑测量或编包；边界在外部同名证据，[复盘](../docs/review-mac-perf-r1-fingerprint.md)，接着修Debug启动。

## S45 BLOCKED · UI测试器初始化 2026-10-21
- 客户端Home和错误参数已修，改到UI类编译过，真实客户端/主窗已启动；AUT没重编、隔离没重做。
- XCTest卡系统自动化授权，业务0/10；车头已定安全设置+认证，UI挂起等粟粟决定，不改不绕。
- 其他R1按Debug、SwiftUI、终端继续；命令/原件在外部同名证据，[复盘](../docs/review-mac-perf-r1-ui-host.md)。

## S47 DONE · Debug限时收口 2026-10-21
- 主线程空闲但只有状态栏窗；关计时任务仍无首窗，没拿到Debug对照数。
- 无窗激活被拒，试改已撤回；不改十秒、不重编旧包，按限时保留缺口。
- 部分早期临时报告未保全，原批次零分母及摘录在外部同名证据，[复盘](../docs/review-mac-perf-r1-debug-window.md)。

## S48 BLOCKED · 车头暂停实测 2026-10-21
- 附着正常停录时目标仍活，SwiftUI更新/因果仍空，按限时记缺口不再深挖。
- 自有bench、录制、负载已无残留，mac已释放；没动她的App和常亮进程。
- 等车头继续后先补终端三窗；UI认证另挂起，原件在外部同名证据，[复盘](../docs/review-mac-perf-r1-swiftui-pause.md)。
- 合成工作根已清，冻结种子、原账和必要原批次保留。

## S49 BLOCKED · 键鼠窗口结束 2026-10-21
- 终端有效窗仍为零；Cua服务缺失已按标准模式恢复监听，未改权限。
- 再起跑前闲置不足两分钟，门禁拒绝启动，本窗结束；Debug未开始。
- 自有进程、租约、临时服务和合成根已收尾；冻结种子及原账保留。
- 等车头继续，仍先终端三窗；证据在外部同名文件，[复盘](../docs/review-mac-perf-r1-terminal-resume.md)。

## S50 BLOCKED · 起跑闲置未达标 2026-10-21
- 只有六百秒起跑门、无附加等待；实读不足一分钟，Native没启动，终端仍零有效窗、Debug未开始。
- 原宿主读法后续也未达标；不据此认定粟粟回来，不自动重试。
- 自起服务已停、mac为空；等车头继续，建议先保持Cua前置就绪，证据在外部同名文件。

## S51 DONE · HID归因已修，终端未齐 2026-10-21
- 初始只等六百秒，自注入/bench前台活动不再当窗口外输入；新七项行为自测过，实际已过门起跑。
- 两轮被backend-2直通测试打断，未计长窗；没动别人进程、没放宽判据。
- Cua保持就绪，协调无测试窗口后继续终端；原件在外部同名证据，23:30前收尾。

## S52 BLOCKED · 截止收尾 2026-10-21
- 最后一轮直到截止仍未获初始六百秒准入，Native没启动；终端仍缺三窗，Debug未开始。
- 不是窗口外输入触发；没有逐次初始读数，来源不能归因，不冒报测量结果。
- mac为空，转基线/提交/自有资源收尾；Cua保持前置就绪，证据在外部同名文件。

- S53 DONE · 2026-10-22：六处冲突按master行为解完，保留perf/隔离钩子及双方target；补齐两处iOS平台限制，mac/iOS均BUILD SUCCEEDED；未跑实测。
