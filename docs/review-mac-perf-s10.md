# S10 复盘 · bench隔离审查收口

裁决：[13条车头裁决](prompts/2026-10-16-mac-perf-sol/R-isolation-rulings.md)。本切片不做bench首启或性能测量；验证结果以[sol-log](../perf-mac/sol-log.md)本条和外部证据为准。

## 1. 边界情况

- 路径：缺失后缀含`.`/`..`拒绝，祖先realpath处理符号链接，枚举返回checked后的规范URL；仍不承诺校验到IO之间同UID并发替换的读安全。内核在实际写边界限制到bench根，不建设openat能力框架。
- 内核：`file-write*`默认拒绝；唯一系统写例外为现存`/dev/null`的数据写。不放开共享tmp或用户cache根。host对自有原生共享tmp样本的写/unlink均拒绝，不涉及别人的样本。
- 首启失败：[INFERENCE] Cocoa/WebKit/PTY若必须写其他系统位置，现策略可能导致相应功能失败；尚未运行bench进程，不能把此事记为已发生或推导必需豁免。T3窗口中发现就停，拿实际拒绝证据判断，不预放宽共享目录。
- 非bench：三个探针恢复可选查询降级，iOS有效源码逐字回到S9前；空查询回归调用产品KBProbe路径解析，不只测试Foundation或转发。正式Release隔离核心忽略测量变量，五项路径保持FileManager原值。

## 2. 与下一模块交互的风险

- T3必须粟粟明确说「现在测」且当面把首启隐私框全点不允许。当前没有窗口授权；不启动bench，不运行生产七根find或偏好快照。
- 下一步先真实R1-0：独立包/根/角色、生产七根路径mtime、偏好仅内存逐key、网络/进程生命周期、observer与T6。隔离不过不进入R1-1测量台，更不能把CLI/单测当基线。
- 外部终端、桌面深链、AppleScript、默认系统废纸篓及通知均闸住；导出写由内核兜底，cua驱动器不点导出/删除/在终端继续。
- MiniBrowser/LinkPreview在发起处离线，但launchd管理的代理不在host进程树IP socket审计内；不能声称已经验证代理规则继承或整个网络生命周期无流量。

## 3. 技术债务与未验证项

- 不改SwiftTerm，受控合成输出不是通用根外读取策略；显式数据库写由内核兜底，按裁决不新增消费者级宿主/用例。
- 固定printf只完成安全输出入口，不是L-term持续负载。真实负载器仍属于尚未开展的R1-1，不能把它冒充已交付测量台。
- 新永久测试仅点段组合、空查询语义、Cursor根内真实扫描解析及host白名单；没有新增active-bench消费者测试框架。
- 本轮两份mac构建、14类230测0失败，但自有合成库仍输出SQLite“vnode unlinked while in use”诊断；保留日志，未扩大本刀修既有测试清理时序。核心首轮编译超时及Security/DetachedSignatures提示也不隐藏。
- 未执行真实bench、PTY、TCC、七根/偏好、observer/T6、cua、A/A/ABBA和性能基线；本轮无性能收益结论，也不是R1 MILESTONE。
