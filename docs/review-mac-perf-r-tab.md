# review · mac-perf R-tab（sol S5）

2026-10-16 · sol · 实验见`../perf-mac/实验日志.md` S5。

## 1. 边界情况

- `mp.stanch.R-tab`默认YES，只改变启动恢复：上次手动选中Code也先回聊天。仍保留Code标签、手动激活与原标签存档，不把存档改写成chats。
- NO恢复旧策略；即使NO，Code可见性关闭仍优先回聊天。标志构造时从注入的偏好域读一次，生产shared需重启生效。
- `restoredLeftPanelTab`只有ContentView启动恢复这一处产品消费；未改手动选项、activate、菜单/终端导航或持久化格式。

## 2. 与下一阶段交互风险

- 与K1-dirty配合避免启动自动激活Code，不能阻止用户主动打开Code，也不能替代K0-min或active SQL优化。
- 不解决已取证的启动manifest同步读取；后台首扫仍保留。不能把默认回聊天称为全启动路径无卡顿。
- 未更换父视图/滚动宿主，不改变焦点、键盘、菜单、窗口缩放或深色契约。真实GUI启动/NO恢复留R1隔离bench，不操作她的app。

## 3. 技术债与验证

- 沿用现有独立UserDefaults suite契约测试，不新建框架或helper；验证真实存档/重建实例、默认恢复、NO和可见性优先级。测试域按例删除，生产偏好不改。
- 产品功能新增5行、永久测试新增8行≤10；其余为Mac偏好/ContentView共4行注释调整。没有引入新UI开关、迁移或兼容路径。
- `MacWorkspacePreferencesTests`整类10测0失败，grep原文`Test Suite 'MacWorkspacePreferencesTests' passed at 2026-10-16 17:28:31.897.`且`** TEST SUCCEEDED **`；真实独立suite观测`R_TAB_SMOKE saved=code default=chats rollback=code hidden=chats`。
- 证据1份`~/MemoryPalace-docs-media/perf-mac/sol/S5-R-tab-verification.txt`（1313 bytes），不入git；无临时用例/脚本遗留。
