# S13 复盘 · bench输出定因与根内原子替换

本刀只改bench侧；实际构建/复验结果见[sol-log](../perf-mac/sol-log.md)本条，不把CLI当完整R1-0。

## 1. 边界情况

- 旧候选输出明确：Blob映射和savedProfiles保存权限失败，ProfileManager.addProfile在持久化失败后不publish/switch，最终notePreparedProfile因当前楼层不符而exit78。TestHostIsolation的78出口要求测试角色标记，host清洗环境不带这些标记；不能把旧78猜成测试宿主误入。
- 同一内核白名单的最小Foundation CLI实测：`.atomic`报Cocoa513/EPERM，直接根内写成功。没有进一步证明Foundation内部究竟哪一个根外操作被拒，未据此扩白名单。
- bench配置增加同目录mkstemp、写全字节、rename替换；写/rename失败保留旧目标，暂存退出清理。CLI在原沙盒下已证明替换、失败保旧和无暂存残留，核心回归增加2行既有内容替换验证。
- helper不做fsync，不承诺掉电持久性；临时文件0600，未试图复制正式文件的全部属性。仅bench使用，非bench/iOS仍走原Foundation写法。
- host合并候选stdout/stderr到根内单文件，最多256KiB；溢出或写入不完整判RED，不能截断成通过。生产偏好值和辅助命令stderr仍不落盘；内容不转发到host JSON。

## 2. 与下一模块交互的风险

- BlobStore和启动配置报告两个已知写点改用根内替换；其他未触发写点不在本刀，完整首启仍须真实R1-0通过，不能靠静态编译或核心CLI放行。
- bench侧Blob原子写实现与正式包不同，所有bench对照臂一致，但Blob写入成本不能直接外推为正式包数值；这是隔离成本，不是性能优化收益。
- 定因运行新增7条`~/.claude`路径mtime变化，host保持RED；不打开内容、不归因其他进程而豁免，也不靠重置marker绕过。若复验仍出现，需车头协调真正静默窗口而不是改判据。
- cua守护恢复后按自有PID返回空窗口，旧候选没有可验的GUI；不假称首启弹框已完成人工拒绝。新候选若有弹框，必须打印等待语并等粟粟本人点拒绝。

## 3. 技术债务与未验证项

- 内核写白名单、只mac、生产内容禁读、偏好仅内存逐key、七根只路径mtime均不放宽。launchd代理、TOCTOU读边界和长期未触发行为的既有限制不变。
- 新永久回归只在现有核心CLI加2行，不新增测试框架或active-bench消费者宿主。有界日志与失败保旧使用真实合成CLI冒烟，不伪造app证据。
- 本刀不是R1-1测量台或基线；即便首启修好，完整观察/元数据/偏好/网络/observer任一RED仍按用户规则停，不继续改第二个问题。
- 所有自有合成根在证据保存后删除，原始日志仅外部证据；不清生产根、用户数据库或共享缓存，不将磁盘余量变化归因于本刀清理。
- 最终Release+PERF_BENCH构建成功，UUID`307C0D12-F989-378D-99C3-AA1FFC9EE1B9`；真实复验不再exit78，已产出当前bench楼层、双UUID、六开关及双observer/callback值，但host仍RED、完整观察0秒，不能标R1-0通过。
- 新证明混用`/tmp`与`/private/tmp`，被host的逐字段canonical检查拒绝；不把该拒绝直接说成真实写出根，也不放宽host。下一刀应对实际getter结果用既有POSIX check规范后再输出，不可硬填预期路径。
- 复验自身日志新增示例卡图片保存权限错误；按不过即停只记坏消息，没有顺手扩修。cua新会话返回自有窗口空列表，无GUI/隐私拒绝验收。
- 最终七根更新路径0、生产偏好same，仍不能替代整体通过。两次运行后均立即释放mac；临时合成根/家目录/marker/源码/二进制已清，只保留编译模块缓存；证据4份且每份<1MB。
