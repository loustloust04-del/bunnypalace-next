# 计划书：Caelum's Console × 工具对接（2026-11-07）

> 用户方向（11-07）：大肥兔的 Caelum's Console 做成一个页面，融入粟粟的仿 iOS 桌面；粟粟已有的功能直接复用；Caelum 的工具逐个对上；UI 细节后续慢慢抠。

## 1. 目标
1. 新兔桌面上出现一个「Caelum's Console」App，打开即是大肥兔熟悉的首页（CARE / LOG / DAILY / WITH YOU 四段）。
2. 格子背后：上游有的功能 → 打开上游模块（健康、经期、待办、纪念日、推特、亲密记录）；上游没有的 → 兔兔页面（Murmur、留言板、他做给你的、游戏室、今日屏幕、饮水进食、心愿单、一起听）。
3. Caelum 的 87 个工具（docs/CAELUM-TOOLBOX.md，旧仓）在新兔下全部可用：A 类（纯服务端）不动；B 类（靠 App 上报）随功能补上报；C 类（hub 帧往返）在 hub 翻译层或新兔对接。

## 2. 架构
- **入口**：Models/RightPanelPlugin.swift 默认工具表加 `bunnyConsole`；Views/MemoryPanelView.swift 的路由 switch 加一行 → `BunnyConsoleView`（MemoryPalace/Bunny/Console/）。两处各 1–2 行，登记为补丁 BP-007。需核实：老用户已存的工具表会不会自动出现新工具。
- **数据层**：`BunnyGateway`（Bunny/Gateway/）——网关地址 + 口令（Keychain）、统一请求、缓存、失败降级；Console 各格子、推特同步、健康同步、上报都用它。
- **格子组件**：每格一个小 View + 数据源协议（取数、点击去向），上游模块通过其现有打开方式跳转（待 GPT 任务 T3 查清入口）。
- **兔兔页面**：按大肥兔旧代码移植（7f2c6c4df），数据仍在网关，App 只做界面与上报。
- **工具对接**：hub 翻译层（cc-bridge/hub.ts 的 [Bunny] 段）把旧帧与上游帧互译（ask_choice ↔ ask_user、book_note / fetch_chapter ↔ 上游阅读、pocket_* ↔ pocket_result 等，待 GPT 任务 T4 出字段对照）；新兔侧缺的帧处理放 Bunny 模块。

## 3. 分期
| 期 | 内容 | 产出 / 验收 |
|---|---|---|
| P0 | BunnyGateway + 网关设置页；推特同步（网关接口已上线） | 新兔里看到 1,167 条推文；设置页能测连通 |
| P1 | Console 骨架（桌面入口 + 四段布局 + 上游格子跳转） | 桌面出现图标，点进去布局正确，健康/待办/纪念日/推特能跳 |
| P2 | 健康：药品柜同步、经期同步、健康推送（步数/睡眠）、DailyContext（饮水进食）、健康数据导入 | Console CARE / LOG 有真数据；Caelum meds_* / vitals_* 结果与 App 一致 |
| P3 | WITH YOU 兔兔页：Murmur、留言板、他做给你的、游戏室 | 各页可看可写，与 Caelum 工具互通 |
| P4 | 刻痕扩展（心愿单、里程碑/备注/标签）、今日屏幕 | 数据与旧兔一致 |
| P5 | 一起听（听歌房 + music_command）、共读帧、选择卡、Pocket、看屏幕 | 对应工具在新兔下可用 |
| P6 | UI 打磨、换车前验收 | 用户主观验收 |

每期：先读旧码与上游码 → 写最小改动 → CI 出测试包 → 用户真机验收 → 在工具清单上打勾。

## 4. 分工
- Claude：架构、编码、hub/网关改动、部署（服务重启先征得用户同意）、验收记录。
- GPT：只读调研与规格（见 audit/gpt/tasks-2026-11-07.md），为每期提供文件:行号级依据。
- 用户：真机验收、拍板 UI 与取舍、签名/账号相关操作。

## 5. 风险
- 上游桌面工具表对老用户的合并方式（新工具可能不显示）。
- hub / 网关是线上服务：每次改动备份 + 可回滚，重启挑空闲时段。
- 隐私闸：上游经期、亲密默认关闭，需要用户手动开启。
- 推送：.next 测试包无推送，相关提醒类功能需在换车后才能完整验证。

## 附：P1 预研（2026-11-07，Claude）
- 打开别的 App：桌面点图标走 Page2HomeView.openTool(id)（截快照、设 launchFrames、写 page2RecentTool_v1、改 selectedToolId 绑定）；后台切换走 Page2AppShell.shared.open(id)。Console 内部的格子要跳到粟粟的 App，需要一个不依赖 Page2HomeView 绑定的入口——待 GPT T3 确认（可能需在 Page2AppShell 上加一个公开的「请求打开」方法，或发通知让桌面代为打开）。
- 上游数据接口：HealthLogStore（weight/meds/cycle/intimacy 各自的隐私闸 static var、upsert 方法）、HealthCycleStore（fetchDays、toggleToday）、AnniversaryStore（本地 SwiftData）；待办 Store 待定位。
- 数据源取舍：大肥兔 Console 的格子读网关（与 Caelum 工具同一份数据）；粟粟模块读本地。P1 先让格子读网关、点进去开粟粟模块；P2 做网关 ↔ 本地双向同步后两边一致。
