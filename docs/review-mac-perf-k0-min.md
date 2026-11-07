# review · mac-perf K0-min（sol S6）

2026-10-16 · sol · 实验见`../perf-mac/实验日志.md` S6；本页测试数字为S6历史记录，异步落地边界与时序回归已由[S7收口](review-mac-perf-s7.md)补齐。

## 1. 边界情况

- `mp.stanch.K0-min`默认YES、构造时读一次；NO保留原即时详情刷新、刷新指示、同值替换/revision增长及flush起点计时，其他止血刀仍各自生效。
- 同一选择的详情刷新只有一个调度任务；S7修正为等当前代结果落地后的beforeWaiting，再按`max(2s, 10×本次解析墙钟耗时)`冷却。等待期间合并请求，解析期间又来的请求留下一轮。新选择立即加载，旧调度取消/代号隔离；已开始的同步解析不保证中途停止，旧结果不能覆盖新选择。
- 静默刷新不翻`isRefreshingDetail`；初次加载仍走loading，失败仍保留原阅读内容并给错误。测试改为await真实刷新任务，不再把指示器当完成信号。重试按钮仍复用该限流；大文件/I/O慢时可见更新会更晚，不是硬性最大延迟保证。
- 后台比较索引meta、全部消息（含文本/工具/图片）、sidechains与unknownLines，不拿旧Box的meta+条数浅比较代替。结果完全一致不换detail、不加revision；同条数文本编辑必须更新。仍整份解析/比较，未做增量解析。
- S7修正增量释放：含详情的flush等异步刷新链（含pending）落地/idle后再到`beforeWaiting / Int.max / commonModes`记下一窗口起点、释放新dirty；没有详情变化仍走列表idle。该口径不等于RenderServer/GPU呈现结束。

## 2. 与下一阶段交互风险

- K1-dirty仍负责隐藏增量；详情调度等到就绪时若Code已隐藏，转回dirty/当前详情路径，等激活补齐。已开始的解析可以完成，不扩展成全后台任务取消架构。
- R-tab避免启动自动激活；manifest启动同步读、active SQL、首扫及工具后台工作仍未解决。真正的前台每小时卡顿率、GUI滚动/焦点、Release采样与ABBA留R1及她日常包验收。
- 未更换父视图/滚动宿主，保留原滚动意图；初次选择/错误/换选择的状态分支与既有回归必须保住。

## 3. 技术债与验证

- 沿用单文件门面、Task/代号与现有Int.max空闲观察惯例，没有另建节流框架或改共享模型/iOS。定向测试的专用adapter只给真实Claude解析加220ms受控耗时并计时，不返回假转录，不把它的耗时当生产性能数据。
- 首轮编译通过，18测中唯一失败是新连续写夹具缺少Claude `message.id`，按既有分块语义被合并；只补合法独立消息id，不改解析器、不放宽精确末条断言。首轮render-idle、同值/revision与其余既有用例通过；最终结果与NO实测见实验日志。
- 临时库vnode unlinked等既有宿主警告不隐藏；没有真库、生产偏好、iOS或设备操作。后续隔离bench仍需单独证明，测试宿主隔离不充当bench隔离。
- 修正夹具后的永久快照整类18测0失败，grep原文`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 17:46:27.345.`且`** TEST SUCCEEDED **`。受控成本场景只有初载+1次合并刷新，间隔2.3227s≥要求2.3064s，末条确实可见；render-idle后间隔2.0049s。同值`revision=1→1 / refreshing=false`，同条数文本编辑、失败保旧、切换选择和滚动意图回归均通过。
- 隔离standard suite实设键NO，2项0失败，grep`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 17:48:53.006.`；观测旧时钟`gapAfterIdle=1.7051s`、即时详情0.0208s、`refreshingAtStart=true / revision=1→2`。只证明回退语义，不是ABBA收益。
- 产品+102/-12、永久测试+114/-17，114≤204；临时烟测已完整恢复到18测成功时的FF7D快照，产品4FE6未再改。证据1份`~/MemoryPalace-docs-media/perf-mac/sol/S6-K0-min-verification.txt`（3498 bytes），不入git。
