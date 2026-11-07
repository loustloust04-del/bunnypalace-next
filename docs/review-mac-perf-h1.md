# review · mac-perf H1

2026-10-16 · sol · 计划`plan-mac-perf.md` §4 / 实验`../perf-mac/实验日志.md` S1。

## 1. 边界情况

- 后台active=0的时长是心跳往返，含App Nap / 调度延迟，不称系统hang。主线程应答时取结束点，不含后台队列收回执的延迟；sample触发行仍是下界。
- 新开关默认开；NO回旧格式 / active-only / 1s阈值，测试宿主安全门始终保留。测试无timer、无note写入；测试仅在显式临时目录实例驱动单次真实心跳。
- 真实smoke曾抓到新代码的首次终端速率时间点懒初始化下溢；已修为无首个区间时不计算，保留该smoke回归。首个速率值为0，不用于吞吐结论。
- 包UUID缺失会明确记unknown，不冒充已知身份；本轮Debug宿主实际读到了合法UUID。Release sample权限仍未实证，留T6。

## 2. 与下一刀交互风险

- 日志每行多了pid/bin/build/origin；现有DebugSettings只展示原文，无结构化parser需迁移。未来R1汇总脚本须按字段解析，并分包 / active口径，不混旧日志。
- H1让后续S1/P1/Code刀有来源可辨的日志；它不证明某个病因，也不替代S0a获准后的逐份主线程归因。测试宿主工具列表是临时配置，不能回答N3。
- 本机终端只加字节计数，不改PTY队列 / VT解析 / feed；实际吞吐和CC运行位置尚未验证。

## 3. 技术债与验证边界

- 最终mac专项命令grep到`Test Suite 'HangProbeTests' passed at 2026-10-16 16:39:52.278.`，4测0失败；600ms主线程阻塞实际回执0.68s。证据`~/MemoryPalace-docs-media/perf-mac/sol/S1-H1-verification.txt`。
- 未做Release self-sample、长期前后台观测、周期性sample触发实测、GUI或ABBA。未读原生产HangProbe目录；没有iOS / 模拟器 / 真机操作。
- 每次心跳的上下文、每条日志身份增加的开销未量；不把诊断字段补全报成卡顿下降。没有临时脚本或未实现的产品占位。
