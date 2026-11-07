# review · mac-perf S1（sol S2）

2026-10-16 · sol · 实验见`../perf-mac/实验日志.md` S2。

## 1. 边界情况

- mac默认不跑pump前后四次纯诊断count；同步导入/导出本身、回执、idleCount、通知及恢复纪元逻辑不改。NO恢复诊断count及原每次写账本行为；iOS路径保持原逻辑，未编iOS。
- 状态用既有sortedKeys编码与当前本机文件字节比较；同值不atomic替换，文件缺失/不同仍正常写。既有删除指纹、墓碑等调用都经过这两个save入口，不加进程缓存/失效机制。
- 永久回归在隔离临时根验证空转不重写、变更仍更新指纹并传播标题；回退在全新隔离宿主临时用例实测，随后完整移除，避免进程缓存开关污染全套测试。

## 2. 与下一刀交互风险

- 只去掉probe-5a/5b代价，不把exportChanged仍会fetch楼层全部Conversation、active时restart等A12成本说成已修。
- 同值比较仍编码并读取小账本；省的是atomic替换，不是全部IO。没有新cache，不新增跨调用一致性契约，原并发写入时序未改。
- 下一刀P1不应动这里的同步语义；H1包身份可用于后续现场筛选，S0a仍须获准后补。

## 3. 技术债与验证

- ON整类11测0失败，grep到`Test Suite 'SyncStoreTests' passed at 2026-10-16 16:46:45.498.`；NO临时smoke1测通过（16:47:31）。证据`~/MemoryPalace-docs-media/perf-mac/sol/S2-S1-verification.txt`。
- 首轮测试误读URL缓存mtime导致2断言失败，改为新鲜文件属性读取后通过；未改产品去迁就缓存。未启动生产同步泵、未测真实SQL次数/卡顿率/ABBA，也未操作她的偏好域/真库或iOS。
