# mac性能 S9 · R1-0静态隔离复盘

本切片只交静态候选与专用CLI/隔离普通mac单测证据，不是bench首启或R1-0真实隔离通过。当前启动门按车头裁决：**等车头astra审查 → 等粟粟说现在测 → R1-0实证 → 后续测量台**。具体结果/命令见[研究](research-mac-perf-r1-0.md)、[切片日志](../perf-mac/sol-log.md)及外部证据，不在这里重复整份验证表。

## 1. 边界情况

- `Configuration.check`对缺失末端路径逐级找最深已存在祖先，使用POSIX realpath解析全部祖先软链，拼回缺失段后按路径组件检查根，返回该结果；不再把它交给Foundation.standardizedFileURL重写`/private/tmp`别名。悬空/循环链接、非ENOENT/ENOTDIR错误均拒绝，不回落未解析路径。
- 永久核心CLI保留根外祖先软链/缺失末端反例，并经根内软链真实写入、从目标读回。非bench五个getter另用absoluteString逐字比较FileManager原值；这不是“所有消费者的行为都已逐项证明相同”。
- 原生Foundation temporaryDirectory实测不随TMPDIR改道。mac可达显式临时入口改走AppPaths，非bench/iOS仍返回原生值；不据此声称OS/第三方SDK的隐式临时文件都已改道。
- 既有缓存清理测试会扫用户共享tmp。只抽出现有临时件清理步骤让它接受明确目录，测试只建/删自己的目录；正常清理入口继续组合原步骤。本轮没有调用全局URLCache/WebKit清理来验临时路径。
- host脚本对生产偏好仅在内存逐key比较；结果不含值。七根只路径/mtime，读不到/输出越界/证据缺失均判红。mtime不能覆盖删除或回填旧时间，也不能把别的进程写入归因bench；有变化仍判红，不凭猜测豁免。
- 真实路径检查不是openat式原子文件能力，不防同UID并发替换祖先链接；当前约束是host新建、私有、自有合成根。审查重点仍包括最终拼接路径、枚举预取和构造期探测，不能把替换根getter自动等同全部IO入口已覆盖。

## 2. 与下一模块交互的风险

- `BenchIsolation.active`与`TestHostIsolation.active`分离：bench保留HangProbe，普通单测宿主仍不起探针。新增MCP传输门只限bench；误用TestHostIsolation.blocks会拦显式假MCP服务，本轮已复现并修正，自动加载MCP的既有测试宿主门未撤。
- bench六个MP_PERF入口只认0/1、缺省全开，在App构造前写独立域。后续必须核实际进程配置JSON/构建条件，不能把“设置过env/键值相同”当A/B不同；P1尤其只在Debug有原执行路径。
- 当前host驱动只做新根的`MP_PERF_SEED=isolation`实证，不支持复用旧根或正式RUN/ABBA。真实楼层、UUID、observer回调/列表和路径报告必须由候选进程生成；合成报告自测不能替代它。
- R1-3/4模板要处理SQLite中绝对路径：不能换克隆目录后凭计数相同就放行。模板应固定工作根/重新写入并核指纹，后续按plan实施，不在S9装假bulk数据或假RUN路径。
- 网络socket拒绝/观察覆盖启动根进程及继承子进程，不是对launchd代理进程的全机归因证明；WebKit等系统代理与未触发入口需astra重点核查。外部终端/CLI也不能以HOME已改道代替全局凭据隔离，后续L-term必须使用合成TUI，不启动她的真实CC会话。
- 单测会把DerivedData Debug包用于普通测试宿主，不把该位置当作已冻结的Debug bench归档。真正测量包须另存、记UUID/条件、通过独立身份核验，且只按自有PID操作。
- 首启必须先过本轮审查，再等她在场不用电脑的T3窗口；隐私框她当面全点不允许。不以测试宿主已隔离、preflight READY或build成功代替这两道门。

## 3. 技术债务与未验证项

- 真实七根前后扫描、生产域内存对比、bench网络生命周期、真实楼层/observer顺序、Release sample权限和cua表面均未实证；本轮普通mac单测不是bench首启，不给UI/性能结论。
- realpath/lstat会增加bench文件路径处理成本；尚未测开销，后续A/A与指标解释必须承认这部分，尤其不能把减少校验调用的收益全归给生产IO优化。
- 没有新增通用测试框架/helper库；测试行数按最保守上界核算（整份host脚本也算测试）仍在两倍限制内，具体数在研究/外部证据。MCP沿用原回归断言，不重钉错误文字来掩盖门控回归。
- 测试输出仍出现DetachedSignatures缺失和Security主线程诊断；没有压制，也不把它们当性能问题已解决。iOS不在本轮授权内，编译交Warden。
- 临时诊断源码和二进制已删；永久核心自测留仓库，module cache/失败合成目录仅在批准的/tmp前缀。取证不进git。
- 止血批的日常体验、ABBA、manifest启动读和active Code SQL仍按原plan后续处理；S9不是新的性能刀或R1基线MILESTONE。
