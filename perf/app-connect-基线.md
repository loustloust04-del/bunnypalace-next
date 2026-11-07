# app 冷启动连 hub · 基线（尺子 connectV2-r2）

> 2026-10-11 20:1x · 🎩 backend-4 · 数据：hub 秒连账本近 6h，`bun scripts/connect-ledger.ts --hours 6`（ledgerStats-r2，仅成功上报样本）
> 计划：[plan-app-instant-connect](../docs/plan-app-instant-connect.md) · 尺子：[实验日志「尺子 r2」](app-connect-实验日志.md)

## 样本

- 带 r2 字段的 launch 共 45 次，其中 43 次来自同一台 iPhone（dev 972BBF8C，Air，Debug 包，4 个不同 bin：同一天连续装了几版），3 次来自另一设备 C4B9C055（不在 6h 窗口内）。**模拟器 0 次**（模拟器被别的工位占着，粟粟日常的模拟器还没装上带尺子的包）。
- 启动来源全是 `unknown`（Air 上 icon 拉起没被识别，见下「尺子遗留」）。
- 各 bin 分组的分位数方向一致，下面取四组 p50 的范围；n=5–11 一组，样本仍小，看方向不看小数点。

## 一次冷启动的时间花在哪（iPhone，Debug）

| 段 | p50（四组范围） | 说明 |
|---|---|---|
| 进程起点 → 可早连（bootstrapEligible） | 100–127ms | 受保护数据闸门 + pending import 检查完 |
| 可早连 → 开始连（ContentView.onAppear） | 191–329ms | 建库、楼层、卡库、开屏内容门、首屏构造——**A2 的空间** |
| 开始连 → 首个请求 | 3–4ms | |
| 探测 URLSession 任务生命周期 | 25–103ms | 同局域网，真网络很小 |
| **探测回调 → 主线程** | **537–881ms** | 回调到了，主线程没空——**A1 的空间** |
| WS resume → delegate 回调 | 22–29ms | |
| WS 回调 → 主线程进入 | 1–30ms | |
| 开始连 → client_info 发出（终点） | 648–1230ms | |
| **进程起点 → client_info 发出（全程）** | **972–1607ms** | p75 1343–2030ms |

**关键现象**：连接窗口里主线程忙 = 整个窗口（`busy_ms = busy_max_ms = busy_window_ms`，>50ms 块数恒为 1）。也就是 `ContentView.onAppear` 一触发连接，主线程紧接着就是**一整块 0.5–1.2s 不放手**的工作，探测结果、WS 打开、client_info 全排在它后面。网络本身（探测 + WS 握手）合计只有 50–130ms。

## 判断

1. **先做 A1**（探测选赢家 / 开 WS / 发 client_info 挪进独立串行 transport executor，不经主线程）：直接绕开那一整块，开始连 → client_info 预计从 p50 650–1230ms 降到 ~60–150ms，全程从 ~1.0–1.6s 降到 ~0.4–0.6s。**单刀即可让 iPhone 进 1 秒**。
2. **A2 排第二**（进程级早连）：在 A1 之上再省可早连 → 开始连的 190–330ms。
3. **那一整块 0.5–1.2s 主线程工作是什么**还不知道（首屏三页构造 / 首帧布局 / 首屏数据查询的嫌疑最大，对应 research A6）。它不挡 A1 之后的连接，但挡粟粟第一次点击 / 打字——值得单独抓一次 Time Profiler（Release 包，要占设备，排期另问）。
4. 模拟器还没数据，A1 合并后连同模拟器一起看。

## 尺子遗留（不阻塞 A1）

- `launch_src` 在 iPhone 上全是 `unknown`：icon 冷启动没被识别。
- `bin` 是 `.debug.dylib` 的 UUID（Debug 包预期如此）。
- A1 上线时必须在 `ConnectRuler.switches()` 登记 `A1` 开关，否则新旧样本混组。
