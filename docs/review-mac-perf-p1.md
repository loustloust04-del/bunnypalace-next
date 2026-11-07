# review · mac-perf P1（sol S3）

2026-10-16 · sol · 实验见`../perf-mac/实验日志.md` S3。

## 1. 边界情况

- mac Debug默认不写KBProbe，关闭时日志表达式不求值；侧栏额外的字符串构造/print/诊断计数也一起停。Release仍和原来一样关闭。
- 显式`mp.kbProbe.enabled=YES`后用串行后台队列，日志表达式仍在调用线程求值，避免把SwiftData/UI读取带到后台；只把已得字符串移交写盘。按调用提交顺序写完整行，句柄首用/原50MB截断都在写线程。
- `mp.stanch.P1=NO`恢复Debug始终启用、同步写入；每实例配置构造时快照，生产shared只构造一次。队列中的诊断日志在突然退出时可能丢尾部，没有为此增加flush/持久化机制。

## 2. 与下一阶段交互风险

- 不复活已删除的启动probe-2/4；iOS保留原enum实现，本轮只编mac。Sidebar的PerfCounters仅在该诊断启用时增长，未来R1独立计数不得依赖此默认关闭的计数器。
- R1对比需登记mp.stanch.P1及显式日志开关有效值，避免把探针本身的负担混进性能收益。
- 车头已转达perf子目录只读授权；本刀提交后先补S0a并重新排剩余刀，已提交H1/S1不返工。

## 3. 技术债与验证

- `KBProbeTests`3测0失败，grep到`Test Suite 'KBProbeTests' passed at 2026-10-16 16:55:47.969.`；真实临时文件验证显式开启时one/two有序完整写入、NO时立即同步落盘。默认关闭未求值/未建文件也有回归，临时偏好按例隔离。
- 证据`~/MemoryPalace-docs-media/perf-mac/sol/S3-P1-verification.txt`，1份<1MB，原始日志不入git。未做GUI、退出排空、真实主线程写盘时长或ABBA，不报告性能百分比；没有临时测试脚本遗留。
