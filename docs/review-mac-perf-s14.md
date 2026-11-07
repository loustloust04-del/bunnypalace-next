# S14复盘 · 路径证明、示例卡原子写与内核写证据

## 1. 边界情况

- 实际`AppPaths` getter经`Configuration.check`的POSIX realpath再写报告；host实际值与期望值同样解析。只接受等价系统祖先别名，根外/祖先软链逃逸、根内报告软链及不匹配HOME/TMP仍拒绝；不是用预期路径替代实际getter。
- 根外canary是host自建的`/tmp`同父级`marker-*`普通可写文件。bench仅`open(O_WRONLY|O_NOFOLLOW|O_CLOEXEC)`：不创建、不截断、不写；意外放行也关闭并拒绝出证。真实CLI中inode/size/mtime不变。
- 只有`~/.claude`的mtime列表不单独判RED；仍保存路径/mtime，消失、遍历错误、映射变化或证据超限照旧失败。其余六根规则不变。
- Sandbox消息按subject PID、存活时间窗、系统emitter归属；NDJSON结束标志/计数、显式loss和受控拒写可见性都检查。权限不足、遮蔽、缺canary或查询不完整不能判通过。
- 日志只证明被拒绝的请求。真实CLI另有`/dev/dtracehelper`拒绝，仍保留；不当作已允许写或借机添加白名单。一次额外“只有canary”断言因此失败，接受观测、纠正判据，没有重跑helper。
- 示例卡链路是`CardSample.make → CharacterCardManager.add/persist/write → CardOriginalStore.externalize/write → CardLibraryStorage.writeAtomically`。最后一层仍用Foundation `.atomic`，现仅active mac bench复用根内暂存/rename；正常包及iOS原写法不变。没有取得Foundation内部PNG故障调用栈，不冒称精确到内部哪条系统调用。

## 2. 与下一模块交互的风险

- `macIsolationV1`报告新增必需的`kernelWriteProbe`；新host拒绝没有真实本PID拒写字段的旧包。必须以本轮Release+PERF_BENCH候选及其新UUID配对，不能继续用S13包或伪造报告。
- 保存实际传给`sandbox-exec -p`的策略及SHA-256；主防线仍为根外默认拒写，只放bench根及既有`/dev/null`数据端点。内核日志空集不证明没有允许写。
- 有效策略加本PID内核拒写是允许范围的证明；不是全量allowed-write事件追踪，也不证明日志系统绝对无丢失。launchd代理、长期行为和校验后同UID替换仍保留S10局限。
- bench Blob及卡原件IO实现与正常包不同，性能数字不能直接外推；本刀没有性能收益结论，未换父视图或宿主。
- T3已关闭。下一次先等粟粟明确“现在测”，再取本轮mac租约、跑真实R1-0；出现隐私框才打印“等粟粟点不允许”并等本人操作，不代点；不过即停并释放mac。

## 3. 技术债务与未验证项

- 无GUI核心CLI14项拒绝、真实getter规范化、原子PNG字节替换/暂存清理和真实内核canary已执行；host20项合成自测GREEN。构建/类passed最终原文见[切片日志](../perf-mac/sol-log.md)与外部S14-verification.txt，不以旧S10/S13结果充数。
- 没有bench App.main/真实示例卡完整首启、TCC拒绝、GUI、七根/生产偏好新一轮实证、完整观察窗或R1基线；相关真实验证必须留给T3，不能拿CLI替代。
- 未为读取全量allowed-write事件安装特权工具/改系统日志配置，也不提供假审计回退。若下一次日志不可读取、被遮蔽或canary不可见，需BLOCKED请车头处理具体权限/证据缺口，不绕过。
- 没有新通用helper库、active-bench消费者宿主或未实现的占位接口；一次性CLI源码/二进制及合成根测后删除，原始证据仅留外部目录。

- 本轮最终静态门：mac Debug/Release+PERF_BENCH两份build成功，六类47测0失败、逐类passed与TEST SUCCEEDED已grep（22:49:42.956）；宿主真实隔离，非bench五项路径原值对照通过。产品新增164、测试新增83≤328，未保留重复PNG读取/未改错误分支的新测试。
- Release新UUID=`4F758868-5338-38BC-A949-ACFC0A7B4D5B`，静态preflight READY仅不启动的身份预检。首个/private/tmp入口被既有CLI字面/tmp契约拒绝，修输入通过，未放宽路径。原有私有单测Security/DetachedSignatures提示仍在；未压制、未归为生产App新故障。

