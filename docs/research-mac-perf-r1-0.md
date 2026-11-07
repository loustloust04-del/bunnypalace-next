# R1 核验 · A/A齐、五档有效，L-term真实PTY权限阻断

下文保留历史。完整A/A 220/220及五个M9档各三完整窗已取得，原生超时使性能仍RED；后台激活首事件3/3未确认也原样留，不删分母。L-term真实PTY零喂入，同白名单openpty/posix_openpt即EPERM，未经批准不扩根外设备权限。两份自有PID Time Profiler已录/导出，SwiftUI无有效数据；实数与边界见[基线](../perf-mac/基线.md)。mac已释放、工作根/脚手架已清，模板/原账/有效原批次留，不冒称R1全项完成或缩减剩余验收。

## 已完成：独立家目录探针（不是app隔离通过）

只编译/运行临时Foundation命令行程序，设置`CFFIXED_USER_HOME`和`HOME`到`/tmp/mp-macperf-sol/r1-home-0438097b/home`；不启动任何记忆花园包、不读生产目录/偏好/钥匙串、不发网络请求。

| 入口 | 实际结果 |
|---|---|
| FileManager.home、NSHomeDirectory、URL.homeDirectory、tilde | 全部在独立根内 |
| Application Support、Caches、Documents、NSSearchPath.support | 全部在独立根内 |
| Darwin `getpwuid(getuid())` | **仍在独立根外**；未导出真实路径 |

命令exit 0，输出`FOUNDATION_HOME_PROBE PASS; no app, preferences, keychain or network APIs called`。这只完成plan §3.2第2项；不能代替AppPaths越界防护、副作用关闭、生产根不变与网络实证。

S8取证时源码边界（后续S9会移动/改写，不当当前已实现状态）：
- `MemoryPalace/MemoryPalaceApp.swift:708–723`：AppEntry仅接现有`TestHostIsolation.installIfTestHost()`。
- `MemoryPalace/Utils/TestHostIsolation.swift:66–76`：要求XCTest标志/MP_TEST_HOST；不是普通bench入口。`:188–191`也明确getpwuid不受HOME/CFFIXED影响。
- `MemoryPalace/Utils/PerfHarness.swift:1`仅iOS；当前文件清单未见AppPaths/PerfHarnessMac，不以旧iOS设施冒充mac隔离或测量台。

## 已批授权与仍在的真启动门

粟粟已选1a、T3=b，任务书硬规矩2a/2b为当前真相源，原S8授权冲突解除：

| 已批项 | 边界 |
|---|---|
| 七个敏感根 | marker仅/tmp；find -newer只看路径/mtime，不打开内容、不向生产根写入 |
| 完整生产偏好逐key对比 | 值仅在本机内存比较；只报相同或变动键名，不显示、不落盘值 |
| T3=b | 只在她在场不用电脑时测；先完成静态准备/mac编译/脚本自测，bench真启动前必须BLOCKED「等粟粟说现在测」，首启她当面全点不允许 |

S8没有执行过生产根扫描/偏好对比，也未启动候选包；上述是批准的后续动作，不伪称已实证。

marker/mtime只能证明未观察到写入，不能证明未读取；后续仍必须完成所有路径收口、越界trap、副作用关闭与全生命周期网络核验。单测改根也不能当作bench隔离。

## 证据与接续

- 外部仅2份、均<1MB：`~/MemoryPalace-docs-media/perf-mac/sol/S8-R1-preflight.txt`（实际命令/输出）和`S8-r1-home-probe.swift`（可复现源码）；不入git。
- 临时探针源码已移出`/tmp`存证，临时二进制已删；module cache/空home仍在批准的`/tmp/mp-macperf-sol/`。产品与测试代码未改，无新增永久测试、无测试框架，无xcodebuild/类passed记录。
- 车头已通知合完，恢复按切片只add本切片文件再commit。接续S9先完成路径/副作用隔离、mac编译及脚本自测；真启动前按2b停交粟粟。完整隔离未过不进入测量台/基线，不能宣称R1 MILESTONE。

## S9 · 10-16 19:09 BLOCKED：核心自测两次失败

### 工作区准备，不是已交付隔离

- 新增`AppPaths` / `BenchIsolation`，在AppEntry启动标记/App构造之前校验独立bundle、角色、窗口标志、HOME/CFFIXED/root；拟将持久根与Code根收口，并关闭钥匙串、hub客户端/子进程、网络自动发现、同步、备份、更新等副作用。Code扫描/监听仍保留在独立home，不靠关掉核心负载造好成绩。
- 新增`scripts/perf/mac-isolation.py`：preflight与实际run分开；run要求显式窗口确认，marker只在/tmp，七根只路径/mtime，生产偏好只内存逐key比较、只报键名；继承kernel deny与自有进程树网络核验。**未对生产根或偏好执行这些步骤**。
- 静态审查补了楼层slug越界、Code深层枚举先检查子项再取元数据、Qoder/Hermes构造期环境根等入口；但Swift核心路径拒绝仍有下述实测失败，不能把这些补丁称为安全边界已成立。

### 实际验证与坏消息

| 命令/场景 | 实际结果 | 边界 |
|---|---|---|
| `python3 scripts/perf/mac-isolation.py self-test` | exit 0，`status=GREEN`、`synthetic_only=true`，12项检查 | 合成目录/普通辅助进程；含kernel拒绝合成读写/socket、元数据失败判红、仅内存偏好比较；不等于Swift边界或app实证 |
| 核心Swift自测，第1次 | 编译成功，运行exit 133：`自测须在独立HOME/TMPDIR中运行，Foundation改道必须真实生效` | 后续独立诊断：home改道成立，原生temporaryDirectory不随TMPDIR改道；尾斜杠/0700也未改变结果，只导出布尔值与自己的临时路径 |
| 核心Swift自测，第2次 | 编译成功，运行exit 133：`隔离边界错误接受：深层符号链接逃逸` | 根内`home/escape`指向自己根外的合成目录，检查其尚不存在的`file`被接受；没有读取生产文件 |
| `xcodegen generate` | exit 0，工程生成成功 | 没有运行xcodebuild build/test；没有类passed、签名包/UUID、app/observer/sample/基线结果 |

第1次失败后，工作区新增`AppPaths.temporaryDirectory`并迁移mac可达显式入口；正常包/iOS仍返回原生目录。**不能再以TMPDIR已设置声称Foundation临时根已改道**。迁移尚未收尾，`HTMLArtifactCardView.swift:231`等尾项仍待处理；没有据此放行真实bench。

第2次证明`BenchIsolation.Configuration.check`当前的`standardizedFileURL.resolvingSymlinksInPath`组合未拒绝该缺失末端路径场景；不是Python合成检查能替代的事实。保留失败断言，不改预期、不跑第3次、不继续编包/启动。

### 停点与接续建议

- 按硬规矩5 BLOCKED，需车头裁决两次失败后的修复/复验。**推荐先修“缺失末端路径的祖先符号链接解析”，获明确复验许可后再跑核心自测，过后收尾临时入口并做mac编译。** 不用换测试名/切片号规避次数限制。
- T3=b仍在：静态准备/编译过后，真实启动前必须再BLOCKED「等粟粟说现在测」；目前不是仅等窗口就可以测。
- S9不提交/暂存，工作区保留供车头处理；S8已提交`4e02f009b`。本轮未启动任何app、未操作她的app/真库、未读生产偏好或七根内容、未发生产hub流量、不碰iOS/设备。
- 证据仅1份：`~/MemoryPalace-docs-media/perf-mac/sol/S9-R1-static-verification.txt`（3774 bytes，不入git）；临时源码/二进制/合成目录留在`/tmp/mp-macperf-sol/`用于接续，不得把核心二进制再运行一次。无R1 MILESTONE或性能收益结论。


## S9复验收口 · 10-16 20:07 · BLOCKED「等车头审查」

车头批准修代码后开启新轮；本轮只完成其①–③，按④停审。最终产品源码在MCP门控修正后冻结，后续仅改文档/存证，不为提交再编。

| 验收 | 实际结果 |
|---|---|
| 祖先realpath边界 | 核心CLI exit 0、8项拒绝；根外祖先软链加缺失末端拒绝，根内软链经check后真实写入并从目标读回`inside-only` |
| 非bench原值 | `AppPathsTests`逐项对比home/appSupport/caches/documents/temporary的absoluteString与FileManager，整类通过 |
| host脚本 | 12项合成自测GREEN；不当作Swift或app运行证明 |
| 最终mac构建 | Debug、Release+PERF_BENCH均`** BUILD SUCCEEDED **`；只批准scheme/destination、走shim，Release于20:06收口 |
| 最终定向单测 | 完整22类184测、0失败；已逐类grep passed，19:47:38收口且`** TEST SUCCEEDED **` |
| Release候选静态身份 | bundle=`com.susu.MemoryPalace.perfbench`；arm64 UUID=`F0914E23-2C55-35CD-B8BF-CC1B57958261`；真实包preflight exit 0 / READY，明确`not_runtime_proof=true` |

### 改动与验证中的坏消息

- `Configuration.check`现在以最深已存在祖先的POSIX realpath为起点，拼回缺失段、按组件判根并返回结果。新轮首遍仍因“数据路径越出独立根”exit 133；独立C探针返回`/private/tmp/...`，去掉对realpath拼接结果的Foundation.standardizedFileURL再处理后，同一CLI通过。未削弱根外反例。
- 原生temporaryDirectory仍不随TMPDIR改道；mac可达显式入口已收口。先前漏判为iOS的`FileEditorShareFile`其实是共用类型，也已迁移；剩余原生调用均为非mac分支/纯iOS文件或AppPaths的非bench返回值。
- 为安全运行相关回归，把既有临时件清理步骤抽到同文件`cleanTemporaryFiles(at:)`，普通清理继续组合原步骤，测试只处理自己创建的目录，不清全局URLCache/WebKit。
- 追加副作用回归发现新增MCP传输门误封显式假服务，首次4类36测8断言失败；只将该新增门改为BenchIsolation.active，MCPProvider自动加载的原测试宿主门保留，原测试断言未改。最终原4类全部并入22类重跑，MCP原整类11测通过。
- 正常测试宿主实际日志再次给出本工位DerivedData下xctest-home、独立suite/keychain、`xctestVisible=1`；没有把普通测试宿主称为bench首启。系统Security/DetachedSignatures等诊断未压制。
- `project.yml`只给显式mp-code源码清单加入AppPaths/BenchIsolation；bench bundle id仍由命令行覆盖，不硬改正式包或iOS配置。

### 交接约束

- 测试新增保守上界974行（把879行host脚本全部算测试），产品新增987行、增删合计1458行；即仅按产品新增两倍1974行也满足限制。没有新通用测试框架/helper库。
- 候选包仍在本工位DerivedData的Release输出；这里只读Info/UUID和preflight，没有执行run、sample、cua、生产根find/生产偏好对比，也未冻结Debug bench归档。Debug输出随后被用于普通单测宿主，不能直接当冻结测量包。
- 本切片证据2份均<1MB，只在`~/MemoryPalace-docs-media/perf-mac/sol/`：`S9-R1-static-verification.txt`保留初阻断，`S9-R1-revalidation-verification.txt`保留复验失败/最终全部类passed/命令/UUID。诊断临时源码与二进制已删，永久核心自测保留。
- [复盘](review-mac-perf-r1-0.md)列真实路径TOCTOU、系统代理/隐式临时目录、模板绝对路径和校验开销等风险。**请车头派astra审；审过后才进入BLOCKED「等粟粟说现在测」**。真实R1-0不过不做R1-1，无R1基线或性能收益声明。


## S10 · 10-16 · 隔离审查裁决落地

车头已批准13条裁决并取消再次全量审查；逐项处理表在[plan §9](plan-mac-perf.md#10-16-s10--隔离审查13条裁决车头批准直接落实)。本轮以`64f5e017f`为基点，只做裁决范围，不启动bench。

### 主防线与跨进程边界

- host策略保留原七根读保护及`deny network*`，改为**默认`deny file-write*`，仅bench规范根允许写**。不把七根写黑名单称为隔离，也不新增根外读承诺。
- 唯一具名系统写例外：`file-write-data`到现存`/dev/null`，用于丢弃输入/输出；没有该设备的创建/删除/元数据权限，没有共享`/tmp`、原生用户temporaryDirectory或cache目录豁免。没有真实app证据，不猜测系统临时/缓存需要哪些豁免；真实启动缺权限即停。
- app层统一拒绝外部终端、桌面深链、AppleScript和默认`NSWorkspace.recycle`交接；本机终端/`run_command`只允许固定`/usr/bin/printf`及固定参数、环境、bench根cwd，不接通用shell、任意cwd/env/程序。该短输出**不是L-term恒定负载器**。
- `SystemTimerNotifications.schedule/cancel`使用既有notifications门；本地计时状态保留，cancel仍先失效本地代号。MiniBrowser的加载/导航及LinkPreview真正发起元数据请求处明确bench离线，离线HTML禁远程子资源。
- 驱动器后续仅点场景控件，不点导出/删除/在终端继续；保存面板最终写入与显式可写数据库路径由内核白名单兜底，不新增数据库消费者用例。

### 兼容性与本轮已运行的无GUI证据

| 项 | 观测 |
|---|---|
| #1 缺失段组合 | 核心CLI `MAC_ISOLATION_CORE_SELF_TEST PASS rejected=10 native_temporary_redirected=false`；两条新增点段组合被拒，既有根内软链仍真实写入/读回 |
| #6 iOS恢复 | KBProbe、BridgeProbe、WebSearchProbe的iOS有效源码与`4e02f009b`逐字比较全相同；未运行iOS编译/设备 |
| #8 正式Release | 实际BenchIsolation/AppPaths不带DEBUG/PERF_BENCH编译，独立HOME无GUI CLI带RUN/SEED仍inactive；五项路径absoluteString等于FileManager原值 |
| 内核白名单 | host18项合成自测GREEN：根内建/写/改名/删成功；未列入七根的绝对写、祖先软链逃逸、原生共享tmp自有样本写/unlink均拒；`/dev/null`数据写成功 |

核心CLI首轮`swiftc`120秒编译超时，只有`error: interrupted`，**没有反例运行结果**；补完点段拒绝后新轮0.74秒编译并运行通过。不得把首轮超时记成修前行为复现。正式Release CLI只证明实际隔离核心/路径层，不等于已启动正式app。

### 接受的局限（不是未披露的隔离承诺）

1. 不改SwiftTerm：仅接受控合成输出；内核挡shared tmp写/unlink，但可信输出限制不是根外读取的通用策略。
2. 路径校验返回规范URL，URL枚举原地返回checked结果；校验后到IO前的同UID替换仍有TOCTOU，不实现openat/目录FD能力框架。写仍由内核在实际访问时兜底，读不作更强承诺。
3. host的lsof审计仅自身进程树IP socket采样；launchd管理的WebKit/LinkPresentation等代理不在该树中。离线入口门和内核网络规则不等于已验证系统代理继承或完整生命周期无流量。
4. 尚无真实bench启动、PTY/系统隐式临时落点或TCC实证；不为使app能启动而预放宽共享目录。七根find/生产域逐key内存比较、observer/T6、cua和基线均未执行。


### S10最终静态验收 / BLOCKED「等粟粟说现在测」

- 最终mac Debug与Release+PERF_BENCH均`** BUILD SUCCEEDED **`；只批准scheme/macOS destination，走shim。其后相关14类230测0失败，20:56:28收口且`** TEST SUCCEEDED **`，全部14类passed已grep。
- 两条新增XCTest回归实际通过：`AppPathsTests.testEmptyDocumentsQueryPreservesNilFallback`直接调用KBProbe产品URL解析；`CursorAdapterContractTests.testBenchScopedCursorScansAndDecodesOnlyItsProjectNamespace`创建根内真实目录、复制仓库合成夹具并真实枚举/解析，根外slug返回空。没有active-bench消费者宿主框架。
- 正常测试宿主真实home位于本工位DerivedData的xctest-home，独立suite/keychain，`xctestVisible=1`；这不是bench首启。Debug产物随后作为正常测试宿主使用，未冻结Debug测量归档。
- 最终Release包静态bundle=`com.susu.MemoryPalace.perfbench`，arm64 UUID=`3FFF5D25-8ECC-3C3B-98E5-6CDA6DA9F713`，只读元数据，未运行。S9旧UUID不再代表当前候选。
- 产品Swift+250/-41；测试保守新增121行（整个Python脚本改动也算测试），≤2×250=500。只加裁决准许的三类与host自测，无新框架/helper库。临时诊断源码/CLI二进制已清理。
- 坏消息：核心首轮编译超时保留；本次测试还输出自有`mp-coding-library-*`合成库/边车仍打开时被unlink的SQLite诊断，以及Security主线程/DetachedSignatures等提示。测试全过不等于无警告；未压制，也不扩大S10修既有测试清理时序。
- 外部证据仅`~/MemoryPalace-docs-media/perf-mac/sol/S10-R1-isolation-verification.txt`一份、<1MB，含命令、全部类passed、两份build、身份/预算/坏消息；不入git。[S10复盘](review-mac-perf-s10.md)已索引。

**S10当时只等T3「现在测」**，首启隐私框粟粟当面全拒；车头仅核阻断项，不再全量复审。当时未启动bench/生产app、未做生产根/偏好或网络生命周期实证、未用cua或iOS/设备。完整R1-0不过不进R1-1，未产生R1基线/MILESTONE或性能收益结论。


## S12 · 首轮真实R1-0 RED · 2026-10-16 21:37

S11文档提交`ac292668c`后，车头传达粟粟明确专项许可：只有本次mac租约可加`MP_ZONE_PAUSE=/nonexistent`，T3仍开着；实际取得`LEASED mac`。运行S10构建的Release候选，预检核BID/UUID和独立根后才发启动请求；没有启动生产app或触碰其文件内容。

| 核验项 | 本轮实际结果 |
|---|---|
| 真实启动请求 | PID`63047`；独立根`/private/tmp/mp-macperf-sol/bench-s12-t3-3ea7d34d883a`；原写白名单不变 |
| 总结论 | host exit70 / RED，记录`app_exit=78`，失败分类`APP_EXIT`、`ATTESTATION` |
| 运行落点/楼层/observer | 配置证明缺失；不能确认App.main/GUI完整首启或运行中的包/楼层/observer契约 |
| 完整观察窗 | 请求30秒，完成0秒；不是有效隔离观察或基线 |
| 七根路径/mtime | 7根均检查，无扫描错误：6根存在、更新路径0；Caches根原本不存在且未出现；不读取内容 |
| 生产偏好 | host内存逐key比较`same`、`changed_keys=[]`；未输出/落盘值 |
| 进程树网络 | 5次采样、最多1个自有进程；无网络失败分类，不证明完整生命周期或launchd代理无流量 |
| 首启界面 | 按自有PID调用cua `list_windows`即报daemon不在/exit1，无窗口/截图；无法确认有无弹框或人工拒绝，未代点 |
| 清理/窗口 | host完成原finally自有树清理，无PROCESS_CLEANUP失败；测完立即release mac，原文「已释放 mac」 |

实际走原`perform_run`/`emit`；临时入口仅在写入自有PID时通知调用方，不改沙盒、生产快照、观察或清理逻辑，已删除。没有永久产品/测试改动，也没运行build/test；S10的230测不能冒充本轮通过。

本轮**BLOCKED**，不过即停，不重跑、不扩白名单、不进R1-1或采集T6/基线；没有DONE/MILESTONE。退出78具体原因未知，原host丢弃stderr，不能凭缺日志推断原因。推荐下一切片先恢复cua并给bench自身失败原因增加有界根内记录，保留权限边界；车头准后再在有效T3重做R1-0。

外部证据2份，均<1MB且不入git：`~/MemoryPalace-docs-media/perf-mac/sol/S12-R1-0-report.json`（3304 bytes，仅授权路径mtime/偏好键名/运行元数据）和`S12-R1-0-run.txt`（3061 bytes，命令/租约/失败/清理）。合成bench根暂留原状，不打开它推测失败原因。


## S13 · 定因修复后仍BLOCKED · 2026-10-16 22:12

车头批准只在bench根收候选stdout/stderr，定因后只修bench侧、重编Release+PERF_BENCH再作一次复验；写白名单不动、不过即停、合成根测后清。cua status实际running；只用自有PID，没有打开生产数据内容。

### 退出78的证据链与修复

本工位直接78出口为BenchIsolation.fail及TestHostIsolation.fail（常量78）；后者依赖测试标记，host清洗环境不携带。旧包日志先输出`[perfbench] isolated`，故不是身份/Home安装门失败；随后Blob映射和savedProfiles保存permission错误，`ProfileManager.addProfile`先persistNew再publish/switch，异常只记录不切楼层，最后`notePreparedProfile`失败。没有削弱楼层检查或伪造当前楼层。

最小Foundation CLI在原写白名单下实测`.atomic`报Cocoa513/EPERM，而直接写15字节成功；没证明Foundation内部具体哪项根外操作被拒，不据此扩白名单。bench Configuration改为同目录mkstemp/写全字节/rename，Blob与启动证明使用它，普通包/iOS仍原写法。实际helper同沙盒通过替换、失败保旧及暂存清理；核心CLI新增2行既有内容替换并PASS rejected=10。新host输出上限256KiB，超限/短写RED，不收生产偏好值或辅助stderr。

### 实际结果（不合并成通过）

| 项 | 旧包定因 | 修复后唯一复验 |
|---|---|---|
| 候选 | UUID `3FFF5D25…`，PID49391 | UUID `307C0D12-F989-378D-99C3-AA1FFC9EE1B9`，PID25734；Release构建成功 |
| 退出/结论 | app78，host RED：APP_EXIT/METADATA_CHANGED/ATTESTATION | app-15是host失败后SIGTERM清理；host70/RED，仅ATTESTATION，无旧78 |
| 运行证明 | 缺失 | 已生成；bench楼层、双UUID、六开关、observer/callback Int.min/Int.max正确，路径canonical拒绝 |
| 证明路径 | 无 | root/caches为/private/tmp，其余4字段用/tmp别名；不改host判断，不据此断言已写出根 |
| 七根元数据 | `~/.claude`7条更新，未打开内容/未归因豁免 | 7根均检查，6存在更新路径0，Caches根原缺，扫描无错误 |
| 生产偏好 | same、变化键0 | same、变化键0；两轮均无值打印/落盘 |
| 完整观察/网络 | 观察0秒，不能称全生命周期通过 | 观察0秒，6次采样、最多1自有进程，不能称完整生命周期通过 |
| 自身输出 | 679 bytes，两个Blob保存错和楼层fail | 433 bytes，不再有旧Blob/楼层fail；新增示例卡图片保存permission错误 |
| cua/人工弹框 | 守护恢复、窗口空列表 | 旧会话已结束，按工具提示用新标签后窗口仍空；无截图/隐私拒绝验收，未代点 |
| 租约 | 取得后运行，结束立即release | 重取后运行，结束立即release，实际「已释放 mac」 |

只对当前阻断作证据收口，没有扩修示例卡或改canonical判据。下一刀推荐对**实际getter结果**用既有POSIX check规范后写报告，不硬填期望路径；另定因示例卡权限，车头准且T3有效后重跑。当前仍BLOCKED，不进R1-1/T6或基线，无DONE/MILESTONE/性能收益结论。

### 交付与空间

- 新增产品Swift34行；将整个host脚本改动也当测试则新增55≤2×34=68，永久核心回归仅2行，无新测试框架/消费者宿主。本轮没有XCTest类passed，不借S10的230测充数。
- 唯一Release+PERF_BENCH mac build成功，走原shim、批准scheme/destination；CLI和真实app已实际运行，不是仅编译。非bench/iOS按编译门保留原逻辑，未编iOS。
- 证据只有外部`~/MemoryPalace-docs-media/perf-mac/sol/`下`S13-diagnose.json`、`S13-verification.txt`、`S13-final-report.json`、`S13-final-output.log`四份，每份<1MB，不入git；含真实元数据/自身日志，未开生产内容。
- 所有自有合成根、旧CLI家目录、marker和探针源码/二进制已清；glob确认仅余`r1-module-cache/`。一次df由30G后见104G，未归因于本刀，不清共享/生产缓存。复盘见[review-mac-perf-s13](review-mac-perf-s13.md)。

## S14 · T3关闭后的静态修复与内核证据 · 2026-10-16

车头准实际getter/host期望两边realpath、噪声mtime不独立归因、示例卡bench权限修复；关闭T3，要求两份mac构建/相关定向后再等“现在测”。本轮没有启动bench/生产app、取得mac租约、跑cua/生产七根或生产偏好实证。

### 已运行的证据与代码边界

| 项 | 本轮实际观测 | 对应代码 |
|---|---|---|
| S13真实内核旧事件 | 只查已结束PID25734的精确4秒窗；1条候选原生cache目录创建被拒。未打开目录内容，不把它当成功根外写 | host按eventMessage的subject PID筛选，不按emitter PID |
| getter/host规范化 | 核心CLI `PASS rejected=14`；真实无GUICLI的home/support/cache/documents实际getter均规范到独立根。host合成等价祖先别名通过、逃逸仍拒 | BenchIsolation.swift:103、:253；mac-isolation.py:553 |
| 噪声根 | host自测仅忽略`.claude`mtime判据，仍保存列表；消失与其他根变化不忽略 | mac-isolation.py:355 |
| 本PID真实拒写 | 独立CLI PID89790，host真实log show得到canary与`/dev/dtracehelper`两条deny；emitter为kernel PID0，subject正确；完成记录/可见性通过 | BenchIsolation.swift:109；mac-isolation.py:620 |
| 原子写 | 同一写白名单下CLI替换68字节PNG数据、保存JSON且无暂存遗留；marker inode/size/mtime未变 | Configuration.writeAtomically；CardLibraryStorage.writeAtomically |

示例卡源码链为`CardSample.make → CharacterCardManager.add/persist/write → CardOriginalStore.externalize/write → CardLibraryStorage.writeAtomically`，最后一层此前仍用Foundation `.atomic`。现只在`(DEBUG || PERF_BENCH) && os(macOS)`的active bench复用根内原子替换；普通包/iOS仍原写法，没有停用示例卡或吞掉错误。真实首启是否已消除权限错仍须T3，不把源码链/CLI称作PNG故障栈或完整App验证。

### 证据判据与坏消息

- 实际策略全文及SHA-256随host运行证据保存，`file-write*`根外默认拒绝，例外仍只有bench根及`/dev/null`数据端点；未添加cache/shared tmp/dtrace放行。
- 新StartupReport必需本PID `kernelWriteProbe`：host自有marker仅请求写句柄、不创建/截断/写。系统日志要求subject PID、精确存活窗、Sandbox系统emitter、NDJSON唯一结束及计数；显式loss、权限不足/遮蔽或看不到canary不能通过。
- 一次附加“只有canary”断言被实际`/dev/dtracehelper`拒写推翻；CLI本身exit0、核心写入成功。保留两个拒绝事件，不把denied自动当已允许根外写，也不重跑helper/扩白名单。
- `sandboxd(8)`只承诺violation日志。完整读取+canary可见不是系统绝无丢失，更不是全量allowed-write事件审计；无未声明允许范围的证据来自实际启动的精确白名单。未安装特权审计器/改日志配置，系统代理等旧局限仍在。
- 宽查旧PID所有消息曾超256KiB被拒；改为精确Sandbox写事件才得到有界原文。没有截断伪造通过。raw读取工具额外附页尾已报issue，归档从完整现成JSON对象提取，没有重跑自测。

临时CLI不替代bench App.main、真实示例卡/GUI/TCC、生产七根/偏好或完整观察窗。完整构建/定向passed与清理结果记本轮[切片日志](../perf-mac/sol-log.md)；[S14复盘](review-mac-perf-s14.md)列证据局限和下一窗口契约。仍无R1-0通过、R1基线/MILESTONE或性能收益。

### S14最终静态验收 / BLOCKED「等粟粟说现在测」

- mac Debug与Release+PERF_BENCH分别build成功（顺序命令含排队788.04秒）；六类47测0失败，22:49:42.956收口，全部类passed与TEST SUCCEEDED已grep。测试宿主实际xctest-home/私有suite/keychain，五项非bench路径逐字等于FileManager原值；Debug随后用于普通隔离单测，不是冻结测量归档。
- 当前Release独立BID=`com.susu.MemoryPalace.perfbench`，arm64 UUID=`4F758868-5338-38BC-A949-ACFC0A7B4D5B`。静态preflight READY、`not_runtime_proof=true`，未建运行根或首启。首个调用传/private/tmp被既有CLI字面/tmp根契约拒绝；只改输入按原契约通过，不放宽路径判据。
- 最终host代码20项自测GREEN；产品新增164（Swift47+host117），测试新增83（核心17+host66）≤328，无新框架。新普通PNG重复读取/同值覆盖及未改错误分支测试已移除，原CardSample七项照跑。单测原有临时同名文件迁移失败的预期诊断、Security主线程及DetachedSignatures提示保留，不压制/扩修。
- 自有一次性源码/二进制/家、kernel合成根/marker已删，glob无本轮合成根遗留；模块缓存保留。外部证据恰五份、每份<1MB：`S14-kernel-probe.json`、`S14-kernel-cli.json`、`S14-host-selftest.json`、`S14-preflight.json`、`S14-verification.txt`，均在`~/MemoryPalace-docs-media/perf-mac/sol/`，不入git。
- **只剩本人T3窗口门**：不自行启动bench/申请租约，不拿CLI、预检或47测冒充真实R1-0；等“现在测”后取mac租约并跑原真实隔离核验，隐私框本人拒绝，不过即停并释放。未产生R1-0 DONE、基线或MILESTONE。

## S15 · 新T3开启但租约身份失效 · 2026-10-19 21:16

车头先准R1-1/R1-2静态代码先行、iOS Debug留Warden；调查只读、产品代码未改。随后最新指令明确新T3已开、立即停止静态工作，使用S14现成Release真实R1-0。两个scout已取消；未编译或继续静态实现。

指定acquire后台执行仅一次，exit64/0.09秒：`[device-lease] 你的 session 进程 56409 已经不在了（CLAUDE_PID / MP_SESSION_PID 要是常驻进程）`。这是会话身份门失败，不是bench退出或host隔离RED；未获得mac租约。cua仅status/describe，daemon running，不是已观察候选窗口。

没有启动/退出任何候选或生产app，没有bench PID/隐私框、生产偏好逐key比较、七根扫描、内核拒写审计、完整观察或基线；未代点或虚构打印“等粟粟点不允许”。候选UUID依据车头刚核的S14值，没有重核或重编。未取得租约因此无自有lease可释放；没有新建/tmp运行根或marker，不删除他人/旧模块缓存。没有build/test或新类passed，S14的47测不充作本轮验证。

**BLOCKED，等当前会话身份修复**：推荐由启动器重注入真实存活的常驻session PID/重新挂接执行会话；不伪造CLAUDE_PID/MP_SESSION_PID、不绑定临时shell/别的session或让别人代持mac。修好后车头确认T3仍有效，本会话再按原命令acquire；LEASED后才跑真实R1-0，届时执行S14双侧realpath、`.claude`mtime仅记/内核拒写主证据的原判据，不过即停。外部证据仅`~/MemoryPalace-docs-media/perf-mac/sol/S15-R1-0-blocked.txt`，<1MB，不入git。

## S16 · 真实隔离实证DONE · 2026-10-19 23:22

按车头指定session后台acquire实际LEASED，原host/main/perform_run启动S14现成Release，无重编。临时Notice只通知自有PID52453，不改变任何核验/观察/清理。host exit0/GREEN、failures=[]，完整30.110896秒观察，app_exit=-15为host观察完成后的清理。role seed、BID perfbench、当前楼层perf-bench-profile、binaryUUID/codeUUID均为预期4F758868…；实际getter已规范，startup observer/callback为Int.min/Int.max。

七根metadata完整、无错误/消失：六根更新0，Caches原缺仍缺；`.claude`3条mtime更新保留但不独立RED。生产偏好内存逐key same、changed_keys空，无值输出/落盘。系统Sandbox日志唯一同PID拒写为host受控根外marker，canary可见、query_complete=true，精确策略与SHA-256已存、白名单未扩；`lossless_system_delivery_proven=false`/无allowed全量事件审计的边界保留。130次自有树IP socket采样、最多1进程，不声称逐包或launchd代理完整性。

实际cua只查自有PID/窗口14728，当前Space/on_screen、980×632；截图见开屏/输入区，AX节点预算截断，不冒称完整GUI回归。未见可确认的隐私弹框、未虚构打印等待或代点，不等于已证明全局TCC全拒。候选自身输出263字节，仅isolated/migration check，无旧Blob/楼层/示例卡保存错误；隔离根实际有sample-baishi.png/json（只查自有文件名），HangProbe仅147字节start、无自采样本。

窗口内补齐`xcrun xctrace list templates`（exit0/3.42秒），Time Profiler、SwiftUI、Animation Hitches列出，无独立Hangs模板名；未录trace。T6本轮未自然触发；已核takeSample私有且由心跳/CPU自然门调用，调试页仅日志与Finder入口，没有已验证可用的强制自采驱动。不以外部sample冒充App内自采，不制造空夹具性能数字。

收齐报告后立即按指定两变量release，实际“已释放 mac”（0.67秒）；bench根与marker已删，glob未找到，不动模块/他人缓存。外部仅4份、各<1MB：`S16-R1-0-report.json`、`S16-bench-window.png`、`S16-bench-output.log`、`S16-R1-0-run.txt`，均在`~/MemoryPalace-docs-media/perf-mac/sol/`，不入git。没有新build/test/类passed、A/A/基线或性能收益。

**后续BLOCKED**：隔离已经DONE，缺的是现成包尚无PerfHarnessMac/R1-2驱动，以及T6可控自采触发；不是重测已过隔离。推荐车头结束本窗口后恢复已批准R1-1/2静态，裁决仅bench自采触发方案后在后续包/窗口验。当前不借此恢复静态调查或重编；完整R1-0的T6/TCC未宣称完成。

## S18 · 静态收齐，等车头开窗
- 偏好原组件 CLI、host 合成自测、八类 68 测通过；mac 两包与正式包符号隔离已验，原始细节在外部 S18 证据。
- 可控自采只给测量包的隔离种子角色；host 核对实际子进程结束和本 PID 主线程采样，不改写白名单。
- 这不是新包运行实证；T6、原生界面、夹具和基线未验，iOS 留 Warden。[复盘](review-mac-perf-r1-hooks.md)。

## S19 · 真实自采 RED，等车头裁决
- 原自采子进程正常退出、产出本 PID 主线程采样；host 全文件大小门拒绝，另有内核 canary 不可见，未进入完整观察。
- 偏好相同、七根无更新；仅查自有 PID，未见可确认弹框，不代点或念；已释放 mac、清自有根。
- 产品、host 和白名单未改，未重编/重跑；钩子、M1–M9、A/A 未做，四份有界证据仅外部 S19 留存。
- 推荐车头批准流式核验原采样、只留有界摘录，并处理内核拒写日志可见性；当前不把真实产出改判为通过。

## S20 · 流式自采已过，实时日志仍 RED
- App 回执字节数与原文件一致；哈希/mtime 明标 host 来源，两次分块扫全文件核对本 PID、主线程与稳定性，不复制原样本。
- 日志流先于 App 启动，严格本轮 marker/Sandbox；正常结束后仍缺 canary，不能用 App 自报 EPERM 或七根无更新替代。
- host 最终自测、真实流启停烟测及同包完整观察通过；整体仍 RED，界面截图未取得，钩子、场景、A/A 未验。
- 已释放 mac、清根，只留四份外部 S20 证据；等车头裁决日志可见性前置，不自行提权、改系统配置或白名单。

## S21 · 常规隔离 GREEN，静默分支已自测
- 粟粟批准的零行通道四证已落地；全机有日志但缺本 PID canary 仍 RED，不输出其他进程的日志内容。
- 首轮全机流格式不兼容已修，最终自测过；同包实际通道活跃、canary 可见，完整观察通过，原始失败及最终报告外部留证。
- 本轮不是静默降级：普通路径沿用 S13 噪声记录；不冒称七根严格零或静默四证实测，界面快照未取得。
- 两轮 mac 均释放、自有根已清；继续核真实夹具，A/A 若执行记粟粟在用电脑、数据可能有噪声，尚无 A/A 或基线结果。

## S22 · 静态收口，等车头开窗
- 去冗余规则、真实种子、mac 运行器和分析入口已补；两份 mac 编译及普通 Release 无测量符号通过，仅烟测新增行为。
- 编译期间窗口到点；未租 mac、未启动新包，旧 GREEN 不当新包隔离。后续用归档候选，不能启动当前普通 Release 产物。
- 真实种子读回、钩子、M1–M9/A/A 没验；跨窗模板暂存位置需车头定，建议独立合成目录、测完清 tmp。
- 本切片四份外部 S22 小证据；脚本烟测自有根/进程已清，无新隔离或性能结论。

## S23 · 本窗隔离 RED，等车头裁决
- 获批模板目录与 60 秒 HID 门已接，新目录恢复烟测过；首条 CLI 根别名错误在 App 启动前拒绝，纠正后实际只起一次。
- 全机 Sandbox 147 行，自身 canary 不可见；自采元数据核验过，七根更新零、偏好 same 不抵消红灯，没进入钩子/场景/A/A。
- mac 已释放，自有根/marker 已删，无首批性能数字；沿用候选与一次 UUID 核验，不重编、不哈希、不重跑旧自测。
- 现有 host 只固定 drain(0.25)，[INFERENCE] 订阅启动竞态尚未排除；建议车头批准只修就绪门后复验，判据不放宽，细节外部 S23。

## S24 · 握手确认后仍同因 RED，停止
- 随机 logger 串在流中出现后才启动候选，15 秒上限；只跑新增这一个真实握手自测，结果 GREEN。
- 本窗同包唯一复验已确认握手，但自身 canary 仍不可见，整体 RED；握手修复没有解除阻断，不宣称找到根因。
- mac 已释放、自有根/marker 已删；没重编、没重核 UUID、没哈希或重跑旧自测，不再自行调整。
- 真实钩子/M1–M9/A/A 没跑，首批性能数字未取得；三份外部 S24 小证据，按车头同因再红即停裁决等待。

## S25 · 四证复用 GREEN，启动错误后收尾
- 唯一新增四证自测过；S24 EPERM、marker 不变、七根零更新、偏好 same 均满足，另存获批重判，注记「系统日志未记本次拒写」。
- 没重跑隔离/哈希/UUID 核验；本窗免 HID，A/A 噪声注记已传，但没有实际 A/A 报告。
- 首轮 host 报 KeyError:0，工作根/App 尚未创建，九场景零完成；租约已释放，自有工作/批次根已清。
- 登记表查询选项已修，真实查询烟测过；按出错收尾未追加 App 实测，三份外部 S25 小证据，无性能结论。

## S26 · 新包一次隔离 GREEN，真种子完成后到点收尾
- 根内 Code 创建改直接 open，没有扩大白名单；mac Release+PERF 构建后新包只核一次身份/隔离，真实四证 GREEN，原件见外部 S26。
- 真种子 2700 对话/25万节点、Code 增量 45 次已冻结；模板诊断文件已清，仅留合成种子和续跑入口。
- 首次 M1 未激活前台、就绪超时，不计基线；之后直到截止未拿测量锁，最后阻因没有被旧 host 记录，前台激活修复尚未实测。
- 有效场景 0、A/A 未跑，噪声注记保留；mac/工作根已回收，BLOCKED「等车头开窗」，不重复隔离、哈希或已过自测。

## S27 · 五分钟查明本人桌面真锁屏
- 复用 S26 冻结种子和 GREEN，无新编译/隔离/哈希/身份核验；先单 M1，host 新增 runtime 原因及五分钟诊断。
- 只跑两个新增边界烟测；真实门等了五分钟，负载/内存正常，阻因明确为锁屏/显示器睡眠，当前本人在台 session 的锁定元数据为真。
- 没启动 App、没测得合格场景，激活修复未验，A/A 未跑；这不是隔离 RED，也不能用放宽前台门解决。
- mac 已自动释放、本批根已清、冻结种子保留；BLOCKED「车头先解锁并亮屏后续窗」，元数据和改动摘要外部 S27，不念。

## S28 · 静默等门实证，下一刀先修 bench 就绪
- 三个新增边界过；真实解锁后自动运行，批次防睡眠/回收、Cua 会话及窗口等待已走到真前台验证，同包/种子/GREEN不重做。
- 同包 M1 仍 10 秒超时，末段已有超过五秒无长忙；默认 `leftShown=false` 不挂左栏，`coldStart` 空 action 却要求 `sidebarVisible`（布局 93/480–506、壳 118–123、驱动 256–270），不能靠 host 激活解决。
- 输入只找 NSTextView，真实声明为 TextField，原生字段编辑器行为尚未实证；初始前台为假、结束为真也不满足严格校验。建议修 bench 固定初态/就绪见证与启动时序，不改变 M1 条件或放宽断言。
- 最后再锁屏至截止，未再启动 App；已回收 mac/本批根、种子留，有效场景 0、整批/A/A 未跑。下一切片换包修复后一次隔离再测，必要摘录外部 S28，无新包/收益声明。

## S29 · 独立冷进程必挂前置审查

| 场景 | 默认状态与要求 | 本刀处理 |
|---|---|---|
| M1 | 左栏默认关闭，却要求当前楼层可见行；启动快照可能早于激活 | 先开左栏、等真实条件/前台；不改进程 T0 和绝对十秒 |
| M2 | 已开左栏并等楼层/行/点击回调注册 | 不改；离屏目标行是否需主动滚动留实测风险 |
| M3 | 切楼层不打开左栏，却要求可见行 | 循环前开左栏 |
| M4 | 已展开列、开 dock，真实开面板会选页签 | 无确定必挂，不改 |
| M5 | 已开真实设置窗并等页签注册/出现计数 | 无确定必挂，不改 |
| M6 | 冷进程左栏未开，就等侧栏注册 | 注册前开左栏 |
| M7 | 已走真实窗口生命周期并恢复状态 | 无确定必挂，不改 |
| M8 | 选 Code 不展开左栏，却要求真实行可见 | 选 Code 前开左栏 |
| M9 | L1b/background/L1c 要求可见 Code 行，但左栏未开 | 仅这些档开左栏，其他档不变 |

输入原生类型未实证，本刀不猜改；新包实际单 M1 仍是第一道门。仅测量器类九测、一份测量包已过；包/符号/源码对应信息和命令见外部 S29。

## S29 · 首次真实隔离 RED，停止本窗测量
- 首次 CLI 用 canonical 别名被 preflight 拒绝，未启动 App；只改调用路径写法后，唯一一次真实新包隔离完成完整观察，仍 RED，不把调用错误冒充隔离实证。
- 非噪声生产 agent 根两份日志 mtime 更新；App EPERM、marker 不变、偏好 same 都过，但七根零更新未过，严格四证判 RED，不继续 M1/整批/A/A。
- 源码写明词典仪表盘每两分钟刷新，activity 由 hub 写；这只是并发来源线索，不能仅凭路径/mtime 归因。没打开生产日志内容，不调整例外。
- 已释放 mac、清本轮根/marker、保留包/符号/冻结种子；建议车头给该目录安静窗口同包重验，不关闭生产进程、不放宽四证。完整报告与必要摘录外部 S29。

## S30 · 实际调度避让成功，输入见证继续修
- 只按车头给的生产五分钟调度避让，不读生产 activity 内容；同包定点隔离 44.36 秒 GREEN，完整观察在下一触发前结束，判据和生产进程均未改。
- 单 M1 的前台/key 已成立、侧栏 body 已出现，但原十秒到期，测量尚未开始；这不是“零回调等于零卡顿”，后续未启动。
- 只读自有窗口显示 A/B/C 等合成行及 `chat-input-field` TextField；旧见证仅找 NSTextView。保留未聚焦可编辑控件要求，下一刀补真实原生控件识别及 M6 编辑器路径，不靠点击伪造通过。
- 图和裁剪 AX 摘录只在外部 S30，系统菜单/最近文档不保留，自有根/脚手架已清；按脚本/bench bug 修好继续的裁决进入 S31，原场景/A/A 不缩减。

## S31 · 原生输入与真实几何修复（尚待新包实证）
- 旧见证只认 NSTextView，现接受未聚焦可编辑/启用的 TextField/TextView，且 M6 在真实打字时请求字段编辑器；M1 不抢输入焦点、不删十秒/T0/场景断言。
- 原生边界断言两次失败已保留：控件在 composer 外，但 AppKit visibleRect 延伸至全窗口。修为 bounds 与 visibleRect 交集后再转坐标，新一轮三个相关原生用例通过，不改名重置旧失败。
- 用例含实际 SwiftUI 竖向 TextField 的 first-responder 行为；新增产品 36 行、测试 67 行，无框架/通用 helper，隔离测试宿主已在真实输出确认。
- 新 mac Release+PERF 一次编译通过，候选/符号归档且新包身份只核一次；旧包不重核，原冻结种子保留，立即新包定点隔离后续原场景/A/A，不把单测或编包当性能/隔离实证。

## S31 · 真实补记：隔离过，M1 缺实际输入见证
- 新包按实际五分钟调度空档启动，50.82 秒 GREEN，四证全过、早于下一触发；系统日志未记本次拒写，判据未改、生产未动。
- 原 M1 明确侧栏 true、composer missing、input false，原十秒拦截且无有效回调；0/10，未运行后续场景/A/A，不把原生控件三测说成已解决现场失败。
- 保留必要诊断外部 S31；自有根/批次、进程/租约已清，模板/配额不动。下一刀直挂真实 mac 输入域、拒未入窗覆盖，并修同类矩形边界，不造焦点、不做失败兜底。

## S32 · 原生实物已到，保留原位置修登记
- 现成 S31、同一冻结合成根、原内核隔离定点启动；完整 NSView 层级在外部 S32，类名/frame/window/隐藏/接焦点字段齐，未截断、未读文本或生产数据。
- 聊天输入实际是可接焦点且未隐藏的同窗控件，输入区原生 Witness 同样已入窗可见；侧栏搜索的 field editor 才是当前 first responder，不能要求聊天输入预先被聚焦。
- 登记实现允许离窗实例覆盖活实例；只拒绝该无效写入，并将可见范围夹实际 bounds、转到同一坐标。不挪控件、不加私有类名/位置兜底，是否闭环由新包原 M1 决定。
- 产品源码仅测量器三行，零新增测试、未重刷已过类；一次 mac 候选已编成/归档、身份只核一次。三种调试通道故障留证、调试暂停结果排除，立即定点隔离/原 M1，原十秒/断言/沙盒和后续分母不改。

## S32 · 隔离 RED 收口，等车头裁决日志限额
- 新候选定点 51.74 秒，早于下一生产触发；四证观测过，但总流行数在 subject PID/时间窗过滤前超过上限，内核审计未完成，保持原 RED，不自行重分类。
- 不能推断超限都属于 bench 或其他进程；目前只确认上限检查位置，未读/保留其他进程消息或改解析器，修后 M1/整批/正式 A/A 均未开始。
- 推荐车头批准全机仅计数、本 PID 证据单独限额，字节/丢失/格式错误仍拦，四证不变；同候选重验、不再编包，不改变旧失败事实。
- mac/自有进程、根/marker/脚手架已清，模板/配额留；原生完整字段、一次编包、包身份、隔离失败和源码提交均在外部 S32，未宣称基线完成。

## S33 · host 限额修复与同包重验通过
- 车头批准全机仅计数/本 PID 证据单独限额；逐行解析不建全机对象列表，丢失、格式错、本 PID 写证据超限仍 RED，原字节上限/来源/完成计数检查保留，关闭清临时原文。
- 唯一新增自测 GREEN；全机超过旧上限不泄漏外 PID，本 PID 恰好上限完整保留，超限/丢失/格式仍拒。修正该格式分支原有构造参数错误，无旧套重刷或测试框架。
- 同 S32 包/符号/冻结种子，未重编、未重核 UUID/哈希；定点重验 44.39 秒 GREEN、四证全过，系统日志未记本次拒写注记保留，原 RED 历史不改。
- 隔离租约即释，已接原单 M1/整批/正式 A/A，当前未称基线完成；原 T4/十秒/断言/分母不变，host 工程问题按裁决自行修完继续，命令/候选与完整判定外部 S33。

## S33 · 首个有效 M1，M2 原生点击失败
- 正式 M1 一进程原断言全过、显示回调有效，前置探针另行排除；就绪 1.821 秒、最长主线程忙 9.42 毫秒，采样峰值非系统终身峰值，不称基线或尾延迟分布。
- M2 A/B/C 冷/热/同 ID 和前置过，sendEvent 都失败；整 M2 进程不计有效分母，后续未启动，原失败完整保留外部 S33。
- 原生实物行视图的 visibleRect 超 bounds，click 尚用该大矩形而非真实行范围；S34 只夹实际 bounds、保持原点击事件/窗口坐标与所有判据。
- 本日原 T4 8/8，准备代码/一次候选后待车头追加额度或次日窗，不重置/改身份绕账；自有进程/租约/根清，批准模板/配额保留，余下原场景/A/A 不缩减。

## S34 · 今晚追加预算与编译优先
- 显式授权期限覆盖本窗，块数仅记账不阻断，累计两小时和每块十五分钟仍硬限；预算按剩余时间保留清理余量、不重置账，默认无授权模式原块数政策不变。
- 真实活队列票优先：一秒内检查并中断自有测量，杀 App/停负载后先放锁，再关自有 Cua；部分结果不纳分母，换 ID 从冻结根重跑。编译让锁后空队列可重拿，普通块间休息保留。
- M2 点击仅夹实际 bounds，实物几何烟测确认旧点在外、新点在内，一次 mac 候选已编成/归档；不改界面/焦点/十秒/断言，不重复单 M1。
- 仅新增调度自测通过真实临时文件锁、时间/块数边界及让锁分母；尚未为验证伪造生产编译排队。新包待定点隔离后 M2–M9/正式 A/A，余量不足只留有效部分，必要记录外部 S34。
- 最新追加：本窗额度账只记不挡、无机械休息，仅新增该行为自测 GREEN；默认未授权政策/单块上限不动，不重编候选、不刷旧自测，继续真实测量，不因自定账停。










