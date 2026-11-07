# review · mac-perf K1-dirty（sol S4）

2026-10-16 · sol · 实验见`../perf-mac/实验日志.md` S4。

## 1. 边界情况

- `mp.stanch.K1-dirty`构造时读一次、默认YES；NO保留隐藏时增量重查。仅mac文件，iOS不变。
- 隐藏时仅置列表dirty；不能只靠非空changedPaths判脏，删除/父链变更可能传空集合。只为已加载详情记录命中的路径，不把所有隐藏期变化长期留在Set里。
- 激活沿用一次同步reload，并补选中详情的已知变化；已排队的flush在隐藏时不查、激活已消费且没有新变化时不再重复查。活动期间沿用原节流与刷新路径。
- 已加载详情被隐藏时不提前换页；隔离smoke真实追加fixture文本、重开Code后读到新回复，旧阅读分支保持。未改滚动宿主/跟随意图。

## 2. 与下一阶段交互风险

- 只处理watcher增量路径；首扫进度、扫描结束、显式查询与active Code SQL仍可能在主线程。菜单“最近活跃”仍走独立查询，不能因Code隐藏而读旧列表。
- R-tab负责避免启动自动激活Code，不解决新的manifest启动读取。K0-min仍需另做详情限流、渲染后节流和同值不赋，不把本刀冒称Code全部修好。
- activate还保留原refresh扫描；扫描结束仍会再reload/刷新详情。本刀不重构全入口、线程模型或启动策略。

## 3. 技术债与验证

- 修改前隔离复现：隐藏列表随删除从9变8，新回归预期保留9而失败；修改后需保持隐藏缓存9、菜单反映删除、激活补到8。用真实临时SQLite和fixture文件，不是假回调回声。
- 临时NO烟测确实在隔离standard suite设键并恢复，观测`stanch=false hidden=8`；详情重开烟测观测`hiddenRetained=true appended=true`。两项0失败，临时改动已恢复，永久测试新增23行≤产品新增21×2。
- 复现前及整类输出均出现临时库`vnode unlinked while in use`警告，根因未追；未屏蔽、不归因到她的库。未做GUI/ABBA、真库查询耗时或前台小时卡顿率，不宣称收益百分比。
- 最终永久快照整类16测0失败，grep原文`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 17:24:30.405.`且`** TEST SUCCEEDED **`。证据1份`~/MemoryPalace-docs-media/perf-mac/sol/S4-K1-dirty-verification.txt`，<1MB。
