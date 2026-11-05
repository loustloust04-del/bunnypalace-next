# Research：真灵动岛（Live Activity）

> 2026-08-28 · 前置：假灵动岛（`PixelTerminalHeader`）已完成并上机
> 状态：**等粟粟确认理解 → 才进 plan**

---

## 一、这一刀的边界

粟粟原话的路线图：「你先把这个假的灵动岛做完，然后下一步做真终端，再下一步做真灵动岛」。
前两步都已合 master。这是第三步。

代码注释里我自己写过的定义（`PixelTerminalHeader.swift:21-22`）：

> 这是 app 内画的「假灵动岛」。真的 Live Activity（点灵动岛展开）是另一刀，
> 两者并存：**假的管 app 内，真的管 app 外**。

所以这一刀的价值判据只有一条：**手机锁着 / 在别的 app 里的时候，我能不能一眼看到 CC 的状态。**
凡是「app 已经在前台才能看到」的东西，都不算这一刀的收益。

---

## 二、现状盘点

### 2.1 已经有的（比想象中多）

| 件 | 位置 | 对这一刀的意义 |
|---|---|---|
| APNs 发送器 | `cc-bridge/apns.ts:1-102` | ES256 JWT 签名、`node:http2`、`family:4` 钉 IPv4 的坑都踩过了。**改造成本主要在 header 和 payload，不在传输层** |
| device token 注册链 | `PushNotifications.swift:26-30` → `CCBridgeWebSocketClient.sendPushToken:88` → hub `register_push_token:2248` → `secrets/push-tokens.json` | 现成的「app 拿到 token 发给 hub、hub 落盘」范式，Live Activity token 照抄一份就行 |
| 用量数据源 | `cc-bridge/terminal-usage.ts` | ctx 从 transcript 反扫自算，5h/7d 读 statusline 落盘。**hub 已经能算出灵动岛要显示的全部数字** |
| 用量下发 | `hub.ts:976-1009` `terminalUsagePayload` / `sendTerminalUsage` / 30s 定时器 | 逻辑可复用，但**触发条件要另开一条**（见 §5.3） |
| app-extension 先例 | `MemoryPalacePushNSE`（`project.yml:188-216`） | xcodegen 建 extension target + `embed: true` + `SKIP_INSTALL` 的写法已经在库里跑通 |
| App Group | `group.com.susu.MemoryPalace`（主 app + NSE entitlements 都有） | widget target 加进来即可 |
| aps-environment | `MemoryPalaceIOS.entitlements` = `development` | Live Activity push 不需要额外 entitlement |
| 像素零件 | `PixelFont.swift`、`PixelIcon`/`PixelGlyph`（`JournalKit.swift:440,465`）、`PixelScanlines`、`Palette` | 视觉语言现成 |

### 2.2 完全没有的

对 `ActivityKit` / `WidgetKit` / `ActivityAttributes` / `NSSupportsLiveActivities` 全库搜索 **0 命中**。
没有 Widget target，唯一的 extension 是 Push NSE。

（这条 2026 年更早的横评报告已经查过一遍，结论一致：`docs/minis对比/reports/L1-report.md:83-86`。
那份报告当时明确写了「本轮未查证 APNs Live Activity token/服务端能力，不能替粟粟拍板」——
**本篇就是来补这个洞的**。）

---

## 三、事实核查（本轮查证，非记忆）

查证渠道：Hermes → Apple 官方文档。以下都是要写进代码的准确字段名。

### 3.1 APNs 请求头

```
apns-topic:      com.susu.MemoryPalace.ios.push-type.liveactivity   ← 主 app bundle id + 固定后缀
apns-push-type:  liveactivity
apns-priority:   5 或 10
```

⚠️ 现有 `sendAPNs` 写死的是 `apns-topic: com.susu.MemoryPalace.ios` + `apns-push-type: alert`，
`:path` 也写死 `/3/device/${token}`（这个 path Live Activity 一样用）。

### 3.2 payload（`aps` 内）

| event | 必需 | 可选 |
|---|---|---|
| `start` | `timestamp` `event` `content-state` `attributes-type` `attributes` **`alert`** | `input-push-token`（iOS 18+）|
| `update` | `timestamp` `event` `content-state` | `stale-date` `alert` `relevance-score` |
| `end` | `timestamp` `event` `content-state` | `dismissal-date` `alert` |

> **🔴 更正（2026-08-28，codex 审阅指出，已二次核实）**：
> 这张表原来把 `start` 的 `alert` 写成**可选**，**是错的**。
> Apple 在 "Starting and updating Live Activities with ActivityKit push notifications"
> 的 requirements 列表里明写 **"Include an `alert` in the JSON payload."**，
> 理由是「让人知道有个 Live Activity 被启动了，不要吓到他们」。
> 照原表构造 start payload 会**启动失败**。
>
> 顺带核清一条：`input-push-token: 1`（iOS 18+，「启动的同时拿一个新的 update token」）
> 官方措辞是 "you can add"，**是可选不是必需**——codex 建议「应明确带上」是**建议**不是规范要求。

- `attributes-type` = **ActivityAttributes 结构体的类型名字符串**（不是全限定名）
- 不传 `dismissal-date`，结束后锁屏最多保留 4 小时
- `content-state` 的 JSON 结构必须跟 Swift 侧 `ContentState` 的 `Codable` 表示逐字段对上，**对不上是静默不更新，不报错**

### 3.3 版本门槛

- `Activity.pushTokenUpdates`（远程 update/end）：iOS 16.1+
- `Activity.pushToStartTokenUpdates`（**远程 start**，app 没开也能让岛冒出来）：**iOS 17.2+**
- 本项目 `IPHONEOS_DEPLOYMENT_TARGET: 26.0` → 两个都能用，不需要任何版本兜底分支

### 3.4 Info.plist

```xml
<key>NSSupportsLiveActivities</key><true/>
<key>NSSupportsLiveActivitiesFrequentUpdates</key><true/>   <!-- iOS 16.2+，可选 -->
```

### 3.5 更新频率预算（这条影响架构，重点）

Apple **不公布具体数字**，只说「每小时有一个 ActivityKit push 预算」。已确认的规则：

- `apns-priority` 不写 → 默认 10 → 立即投递 → **计入预算**
- `apns-priority: 5` → 低优先级 → **不计入预算**
- 开 `NSSupportsLiveActivitiesFrequentUpdates` 可放宽，但**用户能在系统设置里关掉它**
- 代码侧可查 `ActivityAuthorizationInfo.frequentPushesEnabled`

👉 **推论**：现有 `terminal_usage` 的 30s 节奏（每小时 120 次）直接搬去推 Live Activity 会撞预算。
用量数字不是秒级信息，节流到 2-5 分钟 + `priority: 5` 才是对的量级。

### 3.6 WidgetKit 里的 SwiftUI 能力边界（决定像素风能还原多少）

| API | 能不能用 | 对我们的影响 |
|---|---|---|
| `Canvas` | ✅ | 备用手段 |
| `GeometryReader` | ✅ | |
| `.distortionEffect` / `.colorEffect` / `.layerEffect`（Metal） | ⚠️ **无官方保证**（不等于已证实不可用） | **本刀不采用** CRT 边缘畸变（`CRTEdge.metal`） |
| 自定义字体 | ⚠️ 有条件 | extension 是独立 `.appex` bundle，**跟主 app 互相看不见对方的 container**。Silkscreen 必须**再进一份 widget target**，且 `UIAppFonts` 写在 **widget 自己的 Info.plist** 里 |
| 动画 | ⚠️ 受限 | 上限 2 秒；系统忽略你写的 animation modifier 用自己的时序；`Transaction` 不可用；Always-On 息屏不播动画 |

👉 **推论**：真岛的视觉 = 像素字 + 扫描线 + 马卡龙三色，**做得到**；
CRT 弧面 = 假岛专属，**本刀不采用**。

> **更正（codex 审阅）**：原文写的是「做不到」，**证据不支持这么强的结论**。
> Apple 一边说 widget 只支持部分 SwiftUI 能力，一边正常公开着 `distortionEffect` API，
> **没有明确的「WidgetKit 禁用」声明**。所以准确的表述是
> 「**渲染支持未获官方保证，且非产品必需，故不采用**」。
> 真要下「做不到」的结论，得单独做一个最小 extension 真机 probe —— 为这个功能不值得。
> （而且灵动岛本来就是真的硬件弧角，不需要假装。）
另有一个白捡的好处：**灵动岛底色本来就是纯黑**，跟这套像素终端配色天生合拍。

---

## 四、更新链路：三条路，得选

这是本刀唯一的架构分叉。

### 路 A：纯本地更新（`pushType: nil` + `activity.update()`）

app 收 WS 的 `terminal_usage` 帧，直接更新本地 activity。

- 👍 零服务端改动，零 APNs 风险，半天能上
- 👎 **app 一挂起 WS 就断，岛就冻在最后一个数字上**
- 👎 「app 外能看到」这个唯一价值判据，正好没满足

（横评报告里 OM 就是这么做的：`pushType: nil`。但 OM 的任务跑在本机；
我们的权威状态在 Mac 上的 hub，本地更新拿不到。**照抄会得到一个假的岛**。）

### 路 B：APNs 远程 update（`pushType: .token`）

app 起 activity 时要 `.token`，监听 `activity.pushTokenUpdates` 拿 per-activity token，
按现有 `register_push_token` 的范式发给 hub；hub 定时推 `event: update`。

- 👍 **app 被杀了也在更新**——这才是产品要的
- 👍 hub 侧数据全现成（§2.1）
- 👎 要动 `apns.ts`（新增一条发送路径）+ hub 新增 token 注册表和定时器
- 👎 岛的**创建**仍需 app 至少前台跑过一次

### 路 C：B + push-to-start（`pushToStartTokenUpdates`）

再多注册一个 push-to-start token；hub 发 `event: start` 就能**凭空把岛拉出来**。

- 👍 「CC 干完活了 / CC 卡在等权限」→ 岛自己冒出来，手机在兜里也知道
- 👎 多一个 token 生命周期要管；start payload 要带 `attributes-type` + `attributes`，字段对不上是静默失败，调试体感差

**我的推荐：B 打底，C 作为 B 之后的独立一小步。**
理由：B 做完就已经满足唯一价值判据；C 是锦上添花，且 C 的所有基建（token 范式、
liveactivity header、content-state 编解码）都在 B 里建好了，追加成本小。
**不推荐 A**——它满足不了这一刀存在的理由。

---

## 五、内容与生命周期：显示什么、什么时候出现

### 5.1 显示什么

最省事也最合理的答案：**跟假岛排 2 一样**——`[模型] [ctx:xx%] [5h:xx%] [7d:xx%]`。
数据 hub 已经在算，配色规则（`Palette.usage`，0-39 薄荷 / 40-69 杏黄 / 70+ 草莓）
跟桌面 statusline 和假岛三处同源，不需要新决策。

四种呈现形态要各画一版：

| 形态 | 空间 | 建议内容 |
|---|---|---|
| `compactLeading` | 很窄 | 一个像素图标 |
| `compactTrailing` | 很窄 | `ctx%`（最常看的那个数） |
| `minimal`（多个 activity 时） | 极窄 | `ctx%` 或一个色点 |
| `expanded`（长按展开） | 大 | 三个用量格 + 模型 + 状态行 |
| 锁屏 / 横幅 | 中 | 同 expanded，`activityBackgroundTint(.black)` |

### 5.2 什么时候出现、什么时候消失

这是需要粟粟拍板的产品问题，我列出四种，标出各自的**真实成本**：

**① 常驻用量表**（像 vibe-island）
设置里一个开关，开了就一直挂着。
→ 最简单，B 路做完即得。缺点：一直占着锁屏一格。

**② 跟着 CC 终端页走**
进终端页 start，离开 end。
→ 最简单，但**价值最低**：app 在前台你本来就看得见。不推荐单独用。

**③ 跟着「CC 在干活」走**（等结果场景，价值最高）
CC 开始一轮 → 岛出现；跑完 → 岛报「完成」然后消失。

⚠️ **这里有一个必须先说的技术发现**：
hub 现在判断「CC 在动」靠的是 tmux `pipe-pane` 的输出流，而 `pipe-pane` 是
**第一个 app client attach 时才开、最后一个离开就关**（`hub.ts:1017-1025`、`1067-1072`）。
也就是说——**恰恰在 app 退到后台、最需要岛的时候，这个信号没了**。

替代信号（都不依赖 attach，本轮盘点出来的）：
- **transcript 文件 mtime**：CC 干活就往 JSONL 追加。`readTranscriptUsage` 本来就 `statSync` 它，
  加一个 mtime 判据几乎零成本。**这是最靠谱的一条。**
- **`askuser-pending.json`**：等权限/等回答是落盘持久化的（`askuser.ts:46-58`），
  能直接支撑「小克在等你」这个状态——**这个状态的推送价值可能比用量数字还高**。
- Stop hook 的 `POST /thinking`：一轮结束的明确信号（`hub.ts:1661`）。

**④ ①+③ 混合**：常驻显示用量，CC 干活时切成任务态，等权限时高亮报警。
→ 信息密度最高，也最贴「我想一眼知道小克在干嘛」。成本比 ③ 只多一点（多几个 content-state 分支）。

### 5.3 推送节奏（跟 §3.5 的预算约束绑死）

- 常驻用量：**2-5 分钟一次 + `apns-priority: 5`**（不计预算）
- 状态跳变（开始干活 / 等权限 / 完成）：**事件驱动 + `priority: 10`**，跳变本来就稀疏
- ⚠️ **不能复用现有那个 30s 定时器**：它 `if (att.mpClients.size === 0) continue`（`hub.ts:1006`），
  没人 attach 就不发——正好跟 Live Activity 的需求相反。必须**另开一条**，不动原来那条。

---

## 六、风险清单（粟粟点名过的「不要搞坏现有的逻辑」）

按「会不会弄坏已经在跑的东西」排序：

| # | 风险 | 为什么危险 | 打算怎么防 |
|---|---|---|---|
| R1 | **LA token 混进 `pushTokens`** | 现有 `sendRegisteredPushes` 在收到 410/`BadDeviceToken` 时会**删 token**（`hub.ts:1344-1348`）。LA token 拿去发 alert 必然被拒 → 把好 token 一起删掉 → **普通推送整个坏掉** | LA token 走**完全独立的 Map + 独立落盘文件**，两边永不互相喂 |
| R2 | 改 `sendAPNs` 签名/行为 | 它现在服务着主动消息、nudge、中庭 @ 三条线，且没有 `apns.test.ts` 兜底 | **不改它**。抽一个内部 `postAPNs(path, headers, payload)`，让新旧两条各自调；新增 `apns-liveactivity.test.ts` |
| R3 | 新 target 让 xcodegen 洗掉现有配置 | 已经在案的教训：`feedback_xcodegen_team_id`、`feedback_merge_requires_xcodegen` | project.yml **只做加法**；生成后 `git diff .xcodeproj` 不看（gitignore），改为 build 全部三个 scheme 验证 |
| R4 | `ActivityAttributes` 放进 `MemoryPalace/` | 那个目录 macOS 和 iOS **两个 target 共编**，`import ActivityKit` 会当场炸 macOS build。已在案：`feedback_shared_source_platform_switch` | 新建独立目录（照 `Sandbox/ish` 的先例），只挂 iOS app + widget 两个 target |
| R5 | content-state 字段对不上 | **静默不更新，不报错**，最难查的一类 | Swift 侧 `ContentState` 显式写 `CodingKeys`；hub 侧的 payload 构造加单测逐字段比对 |
| R6 | 预算撞墙 → 岛不动了 | 看起来跟「代码写错了」一模一样 | 常驻走 `priority: 5`；hub log 每条 LA push 的 status/reason |
| R7 | 拿生产 hub 测 | 已在案：`feedback_hub_test_isolation` | 隔离 hub（另起端口 + 另一个 secrets 目录），照真终端那刀的做法 |
| R8 | Silkscreen 在 widget 里不显示 | extension bundle 拿不到主 app 的资源，且字体缺失是**静默 fallback 到系统字**（已在案：`PixelFont` 注释） | ttf 进 widget target + widget 自己的 `UIAppFonts`；上机第一件事就是肉眼确认是像素字 |
| R9 | 锁屏泄密 | 岛在锁屏上人人可见 | 只放数字和状态，**不放对话内容**（跟现有推送的 `preview: hidden` 是同一类考虑，可复用那个开关） |

---

## 七、要粟粟拍板的（不替你选）

1. **生命周期选哪个**（§5.2 的 ①/②/③/④）。我倾向 **④**，但这决定了工作量：①≈1 天，④≈2-3 天。
2. **要不要 push-to-start**（§4 路 C）。我建议**先不做**，B 落地并在真机稳定跑几天后再追加。
3. **状态优先级**：如果只能在窄的 `compactTrailing` 里放一个东西，你要 `ctx%` 还是「小克在等你」？
4. **要不要顺手做锁屏/主屏的静态 widget**。横评报告的结论是**不建议**为了对齐而做（`L1-report.md:100-104`），我同意，除非你有具体想看的东西。

---

## 八、我对这刀的理解（一句话）

**假岛是我画的一张图；真岛是把 hub 已经算好的那几个数字，通过 APNs 送到锁屏上，
让手机在兜里的时候我也知道小克在干嘛。** 技术上最大的两件事是：
① 建 widget extension target（新基建，但库里有 NSE 先例）；
② 给 `apns.ts` 开第二条发送路径（`liveactivity` header + `content-state` payload），
并且**保证它碰不到现在正常工作的那条**。

---

**⚠️ DON'T IMPLEMENT YET —— 等粟粟确认理解，再进 plan。**
