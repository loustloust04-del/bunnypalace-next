# Plan：真灵动岛（Live Activity）

> 前置 research：`docs/research-真灵动岛.md`
> 粟粟已拍板（2026-08-28）：**生命周期 ④ 混合 · 要 push-to-start · compactTrailing 优先「等你」· 静态 widget 也做**
> ⧫ 粟粟批注（2026-08-29）：**锁屏单色方案 ✅ 用长度代替颜色 · 后台保活探索列入下一阶段（见 §七）**
> **✅ 批注完毕，可以开始实施** → **实施进度（2026-08-30 la0829）**：M0–M6 全部合入 `worktree-live-activity`（M4b ③ 冷启动对账在飞）；真机 checkpoint 待做，见 `docs/prompts/2026-08-29-live-activity/checkpoint-真机.md`；复盘 `docs/review-真灵动岛.md`。

> **v2（2026-08-28）**：粟粟给了她朋友的仓库
> [`Cheiineeey/ios-app-where-it-breaks`](https://github.com/Cheiineeey/ios-app-where-it-breaks)
> ——`01-live-activity/` 是一份**真机验过**的 Live Activity 工程 + 42 个坑的清单，
> 而且几乎全是「编译过、签名过、装机过，然后什么都没发生」的静默失败，
> 正好是本刀最怕的那一类。
>
> 读完对本 plan 的影响：**新增一条设计决定 D5（改架构，见下）**，
> 另有 10 个坑分别钉进 M0/M1/M2/M4/M6。逐条溯源见 §六。
> 下文凡标 `【坑 N】` 的都出自那份 STEPS.md，**已核对过对我们成不成立**（不成立的也写明）。

> **v3（2026-08-28）· codex 对抗性审阅后**：codex 判了 **2 个致命 + 6 高 + 4 中 + 2 低**，
> 我逐条回去核了代码和官方文档。**它对的地方比我预期多，其中 4 条是我自己写错的事实**：
>
> | 我原来写的 | 真相 | 核实方式 |
> |---|---|---|
> | D3：LA token 混进去会「把好 token 一起删掉」 | **错**。`pushTokens.delete(token)` 在每个 token 自己的闭包里，只删失败那一个 | 读 `hub.ts:1337-1350` |
> | §五：「sandbox/production 分环境 ✅」 | **错**。`env` 存了但从没用来选 endpoint；app 三处硬编码 `"sandbox"`；`HOST` 是模块级单值 | 读 `CCBridgeWebSocketClient.swift:90,97,1070` + `hub.ts:1339` + `apns.ts:15` |
> | research：start 的 `alert` 是**可选** | **错**，是**必需**。照原表构造 start 会失败 | Apple 原文 "Include an `alert` in the JSON payload." |
> | research：WidgetKit「不支持」Metal shader | **过强**。只是无官方保证，不等于已证实不可用 | Apple 未作禁用声明 |
> | D5：秒数停了就知道 hub 死了 | **错**。系统画的计时器**不会停** | 见下方 D5 更正 |
>
> 下文凡标 `〔codex〕` 的都是这轮改的。**未核实就采信不算数**——每条我都写了核实方式。

---

## 零、这份 plan 的形状

四项全要，所以拆成 **7 个里程碑**，每个都满足三条：

1. **能单独 build 通过**（三个 scheme：macOS / iOS / Tests）
2. **能单独验证**（有明确的「怎么算通过」，不是「应该行了」）
3. **能单独 commit + push**，出问题可以停在任何一个 M 上不往下走

顺序是按**风险从高到低 + 依赖**排的：新基建和视觉排前面（错了改起来便宜），
碰生产推送链路的排中间（有隔离验证兜底），锦上添花的排最后。

```
M0 基建（空壳 target）
 └→ M1 视觉（本地假数据起岛）        ← 视觉不满意在这里改，不牵扯服务端
     └→ M2 token 链路 + 注册协议(D6)   ← R1 防线 + 路由身份都在这里立
         └→ M3a 单次远程 update       ← ★ 最小可交付线
             └→ M3b 周期 scheduler
                 ├→ M4a 显式状态机（干活/等你/闲）
                 │   └→ M4b 兜底层（stale / 看门狗 / 重启对账 / 冷启动对账）
                 │       └→ M5 push-to-start
                 └→ M6 静态 widget（可与 M4/M5 并行）
```

**M3a 是最小可交付线**——但**前提是 M2 的注册协议（D6）做完了**〔两轮 codex 都点名〕：
只有 token 没有 `session_name`，hub 不知道该读哪个 transcript，会推出**看起来对但其实错**的数字。

M3a/M3b 和 M4a/M4b 的拆分也是 codex 提的：原来的 M3 把「发一条」和「定时发」揉在一起，
原来的 M4 塞了 FSM + 隐私 + 计时 UI + 看门狗 + 冷启动 + end 策略，**都已经不满足「能单独验证」**。

---

## 一、贯穿全程的六个设计决定

这四条是我提前拍死的，因为它们一旦写歪，后面每个 M 都要返工。**请重点批注。**

### D1. `ContentState` 里不放 `Date`，只放 `Int`（unix 秒）

**结论不变，理由改掉** 〔codex #13〕。

原来写的是「`Date` 跟 APNs 对不上」，**这话说过头了**：ActivityKit 并不禁用 `Date`，
Apple 自己的 `ActivityAttributes` 示例里就有 `ClosedRange<Date>`。

真正的约束是：**ActivityKit 用 Foundation 的默认解码策略**（`deferredToDate`，
即 2001 Apple reference date 的 double），所以服务端得**复刻那个编码**才对得上。
而 hub 是 TypeScript 写的，让它去复刻 Foundation 的私有约定是纯粹的自找麻烦，
且一旦对不上的表现是 **content-state 解不出来 → 岛静默不更新 → 跟代码写错一模一样**（R5）。

→ 所以：整个 `ContentState` 里不出现 `Date`，只用 `Int` unix 秒，
  当成**跨 Swift/TS 的协议约定**。Swift 侧要画时间时自己 `Date(timeIntervalSince1970:)`。

⚠️ 别跟 `aps.timestamp` 混为一谈——**那个字段官方就是要 unix 秒**，是另一回事。

### D2. 状态类型**拆两层**，纯数据那层放在 macOS 也编得到的地方

```
MemoryPalace/Services/CCActivityState.swift     ← 纯 Codable struct，无 import ActivityKit
                                                   macOS/iOS 都编 → 能进 MemoryPalaceTests
LiveActivityShared/CCActivityAttributes.swift   ← import ActivityKit，只挂 iOS app + widget
```

一箭双雕：

- 躲开 R4（`MemoryPalace/` 是 macOS+iOS 共编目录，`import ActivityKit` 会当场炸 macOS build，
  已在案 `feedback_shared_source_platform_switch`）
- **纯数据那层能在 macOS test target 里做 JSON round-trip 测试** —— 这是 R5 唯一靠谱的防线

**🔴 但「逐字段对拍」原来的写法不是一个能跑的测试设计** 〔codex #11〕：
bun test 拿不到 Swift `JSONEncoder` 的输出，两边各写一份 expected object **可能一起写错**。

改成 **golden fixture 三方对齐**：

```
LiveActivityShared/__fixtures__/content-state.golden.json   ← 唯一真相
LiveActivityShared/__fixtures__/attributes.golden.json      ← start 也要解 attributes，别漏
        ↑ Swift 单测 encode 后跟它比（放 M1）
        ↑ TS  单测 builder 出来跟它比（放 M3）
```

这样 M1 和 M3 **各自有一道真正可执行的契约关口**，而不是靠两边人肉抄同一个形状。
⚠️ 必须**同时覆盖 `content-state` 和 `attributes`**——远程 start 两个都要解。

### D3. 两套 token 完全隔离，一个字段都不共用

| | 现有（不许动） | 新增 |
|---|---|---|
| Map | `pushTokens` | `laTokens` / `laStartTokens` |
| 落盘 | `secrets/push-tokens.json` | `secrets/la-tokens.json` |
| WS 消息 | `register_push_token` | `register_la_token` |
| 发送函数 | `sendAPNs` | `sendLiveActivityAPNs` |

**🔴 原来写的理由是错的，我核过代码了** 〔codex #9〕：

原文说「LA token 混进去 → 好 token 被一起删掉 → 普通推送整条线坏掉」。
去看 `hub.ts:1337-1350`，`pushTokens.delete(token)` 在**每个 token 各自的 `.then` 闭包里**，
`token` 是那一轮循环绑定的——**只会删掉失败的那一个，好 token 一根汗毛都不掉**。
我是照着「危险直觉」写的，没回去读那十行。

**隔离的结论仍然成立，但正确的理由是这四条**：

1. **作用域不同**：device token 是**每设备一个**；LA update token 是**每个 Activity 一个**，
   而且会轮换（Apple 要求服务端在 token 变化时让旧的失效）
2. **topic 不同**：`…ios` vs `…ios.push-type.liveactivity`
3. **payload 形状不同**：`alert` vs `content-state`
4. **路由身份不同**：alert 按 `chat_id` 找人，LA 按 `session_name` 取数（见 M2 的注册协议）

混放的真实后果不是「连删」，是**把错类型的 token 喂给错的发送器 → 持续失败刷屏**，
而且错 topic 更可能拿到 `DeviceTokenNotForTopic`——**现有的删除条件里根本没有这个 reason**，
于是它会永远失败、永远不被清理。

### D4. 先给旧 alert 路径立护栏，再抽 helper（原写「一行不改」，自相矛盾）

它现在服务着主动消息 / nudge / 中庭 @ 三条线，且**没有 `apns.test.ts` 兜底**（R2）。

**🔴 原来的写法自相矛盾** 〔codex #7〕：「一行不改」和「把内部逻辑搬进 helper」不可能同时成立——
抽取**必然**改动 `sendAPNs` 的函数体。而且原 plan 只测新路径，
**最怕坏的那条反而裸奔**。改成：

```
① 先写 apns-alert.test.ts 锁住旧行为（characterization test）：
     header（topic / push-type: alert）、payload 形状、cert-missing 早退、
     JWT 50min 缓存、family:4、错误结果归一
② 再抽 postAPNs，跑 ① 必须全绿  ← 这一步才允许动 apns.ts
③ 然后加 sendLiveActivityAPNs + apns-liveactivity.test.ts
```

配套三条：

- **LA topic 由现有 `TOPIC` 推导**：`` `${TOPIC}.push-type.liveactivity` ``，
  **不要另写死一遍 bundle id**（同一个事实抄两份就等着分岔，【坑 42】）
- 传输层要**能注入 host 和 http2**，测试不读真证书
- ⚠️ `apns.ts` 是 macOS app 那四个内嵌 bridge 二进制的 **preBuildScript 输入**
  （`project.yml:67-81`）——改它会触发整套重编，改完要确认打包进去的是本次源码

### D5. 「跑了多久」白送给系统画，我只推系统不可能知道的部分 🆕

来自【坑 35】，友邻仓库里标了 🔴🔴，我认为**这是这份 plan 收到的最大一处修正**。

原 plan 把「时间类（系统自己画）」和「状态类（每帧你推）」当成二选一，选了状态类。
**分类是对的，「选一个」是错的**——同一张卡上两类混用才是最优解：

| 显示什么 | 交给谁 | 花不花推送预算 |
|---|---|:---:|
| 在干活 / 等你 / 闲着（phase） | **我推**（事件驱动，稀疏） | 花 |
| ctx / 5h / 7d 数字 | **我推**（2-5 分钟，priority 5） | 不计预算 |
| **这一轮已经跑了多久** | **系统画**（`Text(_:style:.timer)`） | **免费** |

这一条解掉 **R6 预算**：想让岛「看起来在动」原本只能靠加推送频率，
现在秒数自己在走，推送频率可以压到最低。

#### 🔴 但原来第二条理由是错的，必须改 〔codex #1 · 致命〕

原文写的是：「一个自己在走的秒数是活着的证据，**它一停你立刻知道出事了**」。

**秒数不会停。** `Text(_:style:.timer)` 是**系统**在画的，Apple 明说
动态日期「即使 widget extension 没在运行也会继续更新」。
hub 挂了、Mac 睡了、app 被杀了——**那个数字照样一秒一秒往上跑**。
我把友邻那条经验（在他们本机架构下成立）直接搬到我们「数据源在另一台机器」的架构上，搬错了。

而且原 plan 的验收写的是「**kill 掉 hub → 秒数停住 + 看门狗把它收了**」——
这个场景**物理上不可能成立**：看门狗跑在 hub 进程里，**hub 一死它跟着死**，
不可能有人去发 `event: end`。整条验收是自相矛盾的。

#### 改成：秒数管「多久」，`stale-date` 管「还算不算数」

| 想表达 | 靠什么 | 为什么 |
|---|---|---|
| 这一轮跑了多久 | `Text(_:style:.timer)` | 系统画，零预算。**它的价值是让「异常时长」可见**——「在干活 0:12」和「在干活 12:34」是两件完全不同的事，后者你就该去查了 |
| 数据还新不新 | 每次 update 带一个**短期 `stale-date`** | 到期系统把 activity 标 `.stale`，view 里读 `context.isStale` → 明确显示「连接中断 / 数据已过期」，**并把计时换掉别再走** |

**三种死法各归各管**（原来混成一锅）：

| 死法 | 谁来兜 |
|---|---|
| hub 活着，但 transcript 不动了（CC 卡住/跑完没人收） | **hub 侧看门狗**推 `event: end` |
| **hub 自己死了 / Mac 睡了 / 断网** | **只能靠 `stale-date`**——没有任何主体能主动 end。诚实接受，UI 说「数据已过期」 |
| app 重开发现有孤儿卡 | app 侧冷启动真 `end()`（【坑 22】）|
| 都没救 | 系统自己的 8 小时上限 |

#### 还有四条没想周全的（第二轮 codex 补的）

1. **计时器放哪没定**。`compactTrailing` 已经给了「等你/ctx%」，`minimal` 是色点，
   D5 没说秒数落在哪一格。→ **只放 expanded 和锁屏**；紧凑态不放
   （而且时长过 1h 后 `m:ss` 会变宽格式，紧凑态那点地方撑不住）。
2. **`run_id`**：常驻岛跨很多轮，得有个东西标识「这是第几轮」，
   `idle/done → working` 时重置 `sinceUnix` 并换新 `run_id`。没有它，
   重置时机会含糊，而且 hub 重启后没法对账（见 M4）。
3. **两台机器的时钟**：`sinceUnix` 是 Mac 上的 hub 生成的，秒数是 iPhone 按自己的钟画的。
   Mac 时钟偏一点，岛上就会显示负数或者凭空多几分钟。
   → 加一条真机用例：**故意把 Mac 时间拨偏 ±5 分钟**看岛上什么样。
4. **单个 activity 最长 8 小时**。常驻岛必然会撞到，
   → 要设计**滚动换岛**（旧的 end、新的 start），不能假装它能一直活着。

⚠️ 验收也跟着改。**不能要求一个已经死掉的 hub 自己发推送**——但我核了一下，
仓库里**有外部 supervisor**：`cc-bridge/launchd/com.susu.cc-bridge-hub.plist`
是 `KeepAlive=true`，另外还有一个 `com.susu.cc-bridge-watchdog.plist` 探 `/health` 并 kickstart。
所以正确的验收是两条：

- **kill hub → launchd 把它拉起来 → 新 hub 从持久状态对账、补发 `end`**（这条可测）
- **Mac 整个睡了/关机 → 没有任何主体能 end** → 只能看到 `stale-date` 到期后的「数据已过期」

⚠️ 另注：app 内嵌 hub 模式（`CCHubProcess.swift:198-208`）意外退出只置 `.crashed` **不自动重启**，
那条路径下只有第二条兜底。

⚠️ 配套：结束之后**必须换成定格图标别让它继续走**（【坑 35】末尾），
一个已经结束的任务还在计时比不显示更让人困惑。

**🔴 我们跟友邻的一处结构差异（读他们代码时发现的，不在坑清单里）**

他们把 `startedAt` 放在 **`attributes`**（`ReplyAttributes.swift:26`）——因为他们的 activity
是「一问一答一条命」，开始时刻整个生命周期都不变。

**我们不行。** 粟粟选的 ④ 是常驻岛，一个 activity 要跨很多轮 CC 对话活着，
「这一轮从什么时候开始」每轮都在变。
→ 所以 `sinceUnix` **必须放 `ContentState`**，不能放 `attributes`（attributes 一旦 start 就锁死）。
成本是每轮开始时多推一次——但那一下本来就要推 phase 跳变，**顺路带上，不额外花预算**。

### D6. token 注册协议要带够身份，不然 M3 根本不知道「给谁推什么」 🆕〔codex #2 · 致命〕

> **更名（2026-08-30 冻结）**：本节的 `device_id` 已更名 **`install_id`**（app 首次生成 UUID 存 UserDefaults），以 `docs/prompts/2026-08-29-live-activity/README.md`「D6 注册协议」为准。

原 plan 的 M2 只定义了 `sendLiveActivityToken(_:kind:)`——**只有 token 和 kind**。
codex 指出这不够用，我核了一遍，**成立**：

- LA update token 是**每个 Activity 一个**的，不是每设备一个
- 而 hub 要生成用量数字，必须先知道 `sessionName`
  （`hub.ts:976-991`：`sessionName → sessionMap → transcript`）
- 光有 token 拿不到 session，**多窗口/多 session 时直接推错数**

**注册记录改成**：

```jsonc
// update token：按 activity_id 存
{ "activity_id": "...", "token": "...", "previous_token": "...",
  "session_name": "mp-cc", "device_id": "...", "env": "sandbox|production",
  "preview": "full|hidden" }

// push-to-start token：按 device_id 存（它跟具体 activity 无关）
{ "device_id": "...", "token": "...", "env": "...", "preview": "..." }
```

四条配套规矩：

1. **token 轮换要显式替换旧值**（Apple 要求服务端在 token 变化时让旧的失效），
   所以记 `previous_token`
2. **app 侧要在 `didOpen` 全量补报**——现有 WS client 没连上时**直接丢帧**
   （`CCBridgeWebSocketClient.swift:367-381`），不补报就会永久丢失注册
3. **`preview` 必须进 LA 注册记录**〔codex #6〕。原 plan 说「复用现有 `preview: hidden` 开关」，
   但那个偏好存在 `pushTokens` 的 `PushInfo` 里，而 D3 把两套 Map 彻底隔离了——
   **hub 根本没法查到这台设备的 LA 该不该隐藏详情**。这是我自己 plan 内部的矛盾。
   → LA 记录自带 `preview`，**服务端缺字段时默认 `hidden`**（往安全那边倒）；设置变化时重报所有 LA token
4. **`env` 要真的用起来**，别重蹈现有 alert 路径的覆辙（见 §五的更正）

⚠️ 这条没做完，**M3 不能叫「最小可交付线」**——它会推，但推得不对。

---

## 二、里程碑

### M0 — Widget extension 基建（空壳，零业务）

**做什么**

- 新目录 `MemoryPalaceWidget/`：`MemoryPalaceWidgetBundle.swift`（先只返回一个空 `WidgetBundle`）、
  `Info.plist`、`MemoryPalaceWidget.entitlements`
- `project.yml` 新 target（照 `MemoryPalacePushNSE`（**`project.yml:236-271`**，
  原 plan 写的 `188-216` 是过期行号 〔codex #10〕）抄结构）：
  - `type: app-extension`，`platform: iOS`，`deploymentTarget: 26.0`
  - `NSExtensionPointIdentifier: com.apple.widgetkit-extension`
  - `PRODUCT_BUNDLE_IDENTIFIER: com.susu.MemoryPalace.ios.Widget`
  - `SKIP_INSTALL: YES`，`DEVELOPMENT_TEAM: ***（Team ID 已脱敏）***`（已在案：xcodegen 会洗掉 Team ID）
  - entitlements 加 `group.com.susu.MemoryPalace`（M6 要读快照）
  - iOS app `dependencies` 加 `- target: MemoryPalaceWidget / embed: true`
  - **明列 `CFBundleVersion` / `CFBundleShortVersionString`**，跟 app 发布版本一起走
    （NSE 就是这么写的；漏了会在提交时被拒）〔codex #10〕
  - 🔴 **`sources` 必须逐项明列** 〔codex #10〕：
    ```yaml
    sources:
      - path: MemoryPalaceWidget
      - path: LiveActivityShared
      - path: MemoryPalace/Services/CCActivityState.swift   # 精确到文件
    ```
    两个 app target 是把**整个 `MemoryPalace/` 目录**当 source
    （`project.yml:37-44`、`:121-130`），所以 `CCActivityState.swift` 会自动进它们，
    **但不会自动进新的 widget target**。而且这里绝不能写成 `MemoryPalace/Services`——
    那会把整个 Services 目录（SwiftData、WS client……）吸进 widget，当场炸。
- Silkscreen 进 widget bundle：`MemoryPalace/Resources/Fonts/Silkscreen-Regular.ttf`
  作为 `buildPhase: resources` 挂到 widget target，**并在 widget 自己的 Info.plist 写 `UIAppFonts`**
  （R8：extension 是独立 `.appex`，跟主 app 互相看不见 container；字体缺失是**静默 fallback 系统字**）
- 加 `NSSupportsLiveActivities` + `NSSupportsLiveActivitiesFrequentUpdates`
  → **只改 `MemoryPalaceIOS-Info.plist`** 〔codex：这个不用留到 M0 再查，静态就能定〕
  `project.yml:223` 显式设了 `INFOPLIST_FILE: MemoryPalaceIOS-Info.plist`，
  它**覆盖**了 `info.path` 指的 `MemoryPalace/Info-iOS.plist`（:166）——
  后者是孤儿文件，`MemoryPalaceIOS-Info.plist:7-9` 自己的注释就记着这件事
  （ATS 写在 info.properties 里没生效那次踩的）。
  验证方式：build 完 `plutil -p` 读**最终 app bundle 里**的 Info.plist 确认两个键在。

**🆕 两个必须当场验的坑**

- **【坑 8】🔴 `NSExtension` 必须是真的嵌套字典**
  `GENERATE_INFOPLIST_FILE` + `INFOPLIST_KEY_NSExtensionPointIdentifier` 生成的是**顶层键**，
  不是嵌套字典。后果是**编译过、签名过，装机那一刻才被拒**：
  ```
  Appex bundle ... does not define an NSExtension dictionary in its Info.plist
  (MIInstallerErrorDomain error 39) AppexBundleMissingNSExtensionDict
  ```
  → 我们照 NSE 用 xcodegen 的 `info: path: + properties:` 块（`project.yml:196-203`），
  它生成的是真 plist，**理论上没问题**。但「三道关口过了两道、最后一道才拦」这种坑
  不值得赌，M0 里加一步：`plutil -p` 打开生成出来的 `.appex/Info.plist` **肉眼确认嵌套结构**。

- **【坑 3 / 坑 11】App Group ID 三处必须一字不差**
  填不一致**不报错**，只会让 M6 的小组件永远显示 0。
  我们运气好：`group.com.susu.MemoryPalace` 已经注册且在跑（主 app + NSE 两处），
  **不会撞【坑 11】那个「名字被别人注册走了、而报错指向完全错误的方向」的雷**。
  M0 只是把它加成第三处，验证方式是 M6 真读到值。

**验证**（缺一不算过）

- [ ] `xcodegen generate` 后**四个** scheme 全 build 〔codex #10：原 plan 漏了 `StickerProbeUITests`〕：
      `MemoryPalace`(macOS) / `MemoryPalaceIOS` / `MemoryPalaceTests` / `StickerProbeUITests`
- [ ] 装机后 `ls .app/PlugIns/` 能看到**两个** `.appex`（PushNSE + Widget）
- [ ] **`plutil -p` 对两个 `.appex/Info.plist` 分别确认** `NSExtension` 是嵌套字典【坑 8】
- [ ] 两个 `.appex` 的签名和嵌入都正常（新增 widget 别把 NSE 挤坏了）〔codex #10〕
- [ ] `strings` 确认装上去的是新 bundle（已在案 `feedback_install_stale_app_bundle`）

**风险**：R3（xcodegen 洗配置）、R8（字体）、【坑 8】、【坑 3】

---

### M1 — 视觉：五种呈现 + 本地假数据起岛

**做什么**

- `MemoryPalace/Services/CCActivityState.swift`（纯数据，见 D2）：

  ```swift
  enum CCActivityPhase: String, Codable { case idle, working, waiting, done }

  struct CCActivityState: Codable, Hashable {
      var phase: CCActivityPhase = .idle
      var model: String?
      var ctx: Int?
      var fiveHour: Int?
      var sevenDay: Int?
      var detail: String?      // 「等你」的题面首行 / 完成摘要；隐私开关能抹掉（R9）
      var sinceUnix: Int?      // D1：不用 Date
  }
  ```
  显式写 `CodingKeys`，snake_case 对齐 hub 侧。

- `LiveActivityShared/CCActivityAttributes.swift`：`sessionName` 一个静态字段
- `MemoryPalaceWidget/CCLiveActivityView.swift`：五种呈现
  - `compactLeading`：像素图标
  - `compactTrailing`：**粟粟拍板 —— `waiting` 时优先显示「等你」，否则 `ctx%`**
  - `minimal`：一个色点（用 `Palette.usage` 的马卡龙三色）
  - `expanded`：模型 + 三个用量格 + 状态行
  - 锁屏/横幅：同 expanded + `.activityBackgroundTint(.black)`
- 像素零件搬运：`PixelFont` / `PixelIcon` / `PixelGlyph` / `Palette` / 扫描线
  → 这些现在散在 `Views/Pixel/` 和 `Views/Vocab/JournalKit.swift`，**只挑用得上的搬进 widget target**，
  不做「顺手重构成公共模块」（手术式修改）
  ⚠️ **`CRTEdge.metal` 不搬**：WidgetKit 对 Metal shader 无官方支持依据（research §3.6），
  而且灵动岛本来就是真的硬件弧角，不用假装
- app 里一个 **debug-only 入口**手动 `Activity.request` 塞假数据（`#if DEBUG`，设置页深处或长按刷新键）
- 🆕 **golden fixture 的 Swift 那一半**（D2）：`MemoryPalaceTests` 里 encode
  `CCActivityState` 和 `CCActivityAttributes`，跟 `__fixtures__/*.golden.json` 逐字节比。
  **这是 M1 的契约关口**，M3 那半在 hub 侧对同一份 fixture 比。

**🆕 三个坑**

- **【坑 2 / 23 / 34】紧凑态是硬上限，大概四五个字符，塞多了系统直接砍**
  ⚠️ 这条**直接影响粟粟拍的「compactTrailing 优先显示等你」**：
  「等你」两个汉字放得下，但 `ctx 47%` 六个字符放不下。
  → 定案：`waiting` 时显示 `等你`，否则**只显示 `47%` 这三四个字符**（不带 `ctx` 前缀）。
  完整的 `[ctx:47%]` 留给展开态。

- **【坑 5】用户能在系统设置里关掉实时活动**
  查 `ActivityAuthorizationInfo().areActivitiesEnabled`；关了的时候界面要说话，
  **别按下去没反应**——那会让人以为是 bug。

- **三条读他们代码抄来的小形状**（`Widget/ReplyLiveActivity.swift`、`FocusWidgetBundle.swift`）
  - `@main` **整个 extension 只能有一个**。Xcode 模板会自己生成一份带 `@main` 的，
    你再写一个就报 `'main' attribute can only apply to one type`，
    **而报错指的是你新写的那一行**，容易以为是自己写错。我们手写 bundle，注意别重复。
  - `compactTrailing` 里**别加 `.frame(maxWidth:)`**，会把内容顶到中间去。
  - `.keylineTint(...)` 是灵动岛展开时那圈描边色。友邻用的 `.cyan`，
    **我们换成 `Palette.mint`**（粟粟的配色规则：不要蓝）。

- **【坑 13】像素画会被系统抹平 —— 核对结论：我们不受影响** ✅
  那条讲的是 `Image` 的默认插值会把像素图糊掉（要 `.interpolation(.none)` + `.antialiased(false)`）。
  我们的 `PixelIcon`（`JournalKit.swift:440-461`）是 **`Canvas` 逐格 `ctx.fill(Path(CGRect))` 画矢量方块**，
  Silkscreen 也是矢量字体，**两者都不过插值那条路**。
  → 不用改，但 M1 上机时顺手确认一眼边缘是硬的。

**验证**

- [ ] 上机：灵动岛长按能展开，五种形态都对
- [ ] **肉眼确认是像素字不是系统字**（R8 的静默 fallback 只能靠眼睛抓）
- [ ] 三档颜色分别造一次假数据看过（薄荷/杏黄/草莓）
- [ ] `waiting` 假数据下 compactTrailing 显示的是「等你」，其余时候是**纯数字**【坑 2】
- [ ] 关掉系统的实时活动开关，界面有话说不是没反应【坑 5】
- [ ] 像素边缘是硬的没被抹平【坑 13】

**风险**：R8。**这一步跟 hub 完全解耦——视觉不满意在这里反复改，不牵扯任何服务端。**

---

### M2 — token 链路（app → hub），不发任何推送

**做什么**

- app 侧新文件 `MemoryPalace/Services/CCLiveActivityManager.swift`（`#if os(iOS)`）：
  - `Activity.request(..., pushType: .token)`
  - `for await token in activity.pushTokenUpdates` → 发 hub
  - `for await token in Activity<CCActivityAttributes>.pushToStartTokenUpdates` → 发 hub（M5 用，M2 先注册）
  - token 是 `Data`，转 hex，跟 `PushNotifications.swift:27` 同款写法
- `CCBridgeWebSocketClient` 加 `sendLiveActivityToken(...)`，照 `sendPushToken:88-91` 的范式，
  **但字段按 D6 的注册协议带全**（`activity_id` / `session_name` / `device_id` / `env` / `preview`），
  不是原来那个只有 `token + kind` 的版本
- hub 侧：`register_la_token` 分支 + `laTokens`（按 `activity_id`）/ `laStartTokens`（按 `device_id`）
  两个独立 Map + `secrets/la-tokens.json`（D3 / D6）
- 🆕 **监听要监听全局的**〔codex #2〕：除了 `Activity.request` 返回的那个实例，
  还要挂 `Activity<CCActivityAttributes>.activityUpdates`（新 activity 出现，比如远程 start 起的）
  和遍历 `Activity.activities`（app 重开时接回来的）。
  只听自己 `request` 回来那一个，**远程 start 起的岛永远拿不到 update token**
- 🆕 **`didOpen` 全量补报**〔codex #2〕：现有 WS client 没连上时直接丢帧
  （`CCBridgeWebSocketClient.swift:367-381`），不补报就会永久丢失注册

**🆕 生命周期：「常驻」不存在，得两条腿走**【坑 29/30/31】

粟粟选的 ④ 里有「常驻用量表」这一半，但友邻的仓库把这件事讲死了：

> **不存在「永久常驻」这回事。** 实时活动会因为三件跟你无关的事消失：
> 系统到点自己结束、用户在锁屏上划掉、手机重启。

`activityStateUpdates` 能吐 `.ended`/`.dismissed`/`.stale`，**但前提是那会儿你的进程还在跑**——
app 被挂起/划掉/重启之后没有任何代码在执行，事件自然接不到。所以要两条腿：

```
腿一（在场时听）  for await state in activity.activityStateUpdates { ... }
腿二（回来时核对）onChange(of: scenePhase) { if .active { await recheck() } }
```

【坑 30】的核心：**本地那个「我以为它在」永远以 `Activity<T>.activities` 为准**——
用户划掉这件事从不经过你的代码。
【坑 31】：挂上去的方法必须**幂等且可反复调用**（第一次挂 / 重开接回 / 被结束后重挂三合一），
且**进来第一件事是查有没有已经活着的，不查会出现两个岛**。

→ 能做到的上限是「**只要粟粟还在用这个 app，岛就一直在**」。
   「从来不打开 app 也永远在」做不到——这是系统边界。
   （真要一直在，那是 M6 的锁屏小组件的活，见【坑 29】和 M6。）

**验证**

- [ ] hub log 看到两种 token 落盘，`la-tokens.json` 内容正确
- [ ] **`push-tokens.json` 的 mtime 和内容一个字节没变**（R1 的直接证据，不是推理）
- [ ] `bun test cc-bridge/` 全绿（现有测试没被打断）
- [ ] 手动在锁屏划掉岛 → 回 app → 岛自己回来【坑 29/30/31】
- [ ] 连按两次「挂上」→ **只有一个岛**【坑 31】

**风险**：R1（这一步就是 R1 的防线）

---

### M3a / M3b — hub 发 update 推送 ← **M3a 是最小可交付线**

**做什么**

- **① 先写 `cc-bridge/apns-alert.test.ts`**（characterization，锁住旧行为）→ **② 再抽 `postAPNs`** → **③ 才加新路径**（D4 的三步，顺序不能反）
- `sendLiveActivityAPNs(record, event, contentState, opts)`
  - header：`` apns-topic: `${TOPIC}.push-type.liveactivity` ``（由现有 TOPIC 推导，不写死）、
    `apns-push-type: liveactivity`、`apns-priority`
  - **host 按 record 的 `env` 选**〔codex #3〕，不用模块级单值
  - payload：`{ aps: { timestamp, event, "content-state", "stale-date", ... } }`
- 新 `cc-bridge/apns-liveactivity.test.ts`：header 拼装 + 三种 event 的 payload 形状
  + **完整 payload `< 4096 bytes`**（ActivityKit 硬上限）〔codex #6〕
- **`cc-bridge/activity-state.test.ts`：TS builder 跟 M1 那份 golden fixture 比**（D2/R5）
- hub 新定时器，**独立于现有那条 30s**：
  - ⚠️ 现有的 `if (att.mpClients.size === 0) continue`（`hub.ts:1006`）跟 LA 需求正好相反 ——
    **不动它，另写一条**
  - 节奏 **2-5 分钟 + `apns-priority: 5`**（research §3.5：priority 5 不计入每小时预算；
    30s×120 次/小时必撞墙）
  - 每条 push 的 status/reason 都进 log（R6：撞预算的表现跟代码写错一模一样，没 log 查不动）
  - 🆕 **定时器进 `startHub`、存 handle、`wss.close` 时清掉**〔codex #8〕。
    hub 已经有 ping/nudge/keepalive/warroom/reap 好几组 timer，关闭时只显式清了 agora 那组
  - 🆕 **每 session 每轮只算一次用量再 fan-out**〔codex #8〕。
    `readTranscriptUsage` 是**同步**读尾部最多 512KB（`terminal-usage.ts:18-19`），
    按 token 重复执行会阻塞 hub 的终端流 / agora / keepalive
  - 🆕 **每个 activity 一条串行发送队列 + 单调递增 `timestamp`**〔codex #8/#12〕。
    低优先级数字更新和高优先级状态跳变可能并发甚至乱序，APNs 本身也允许重排；
    状态跳变先更新权威快照，定时推送读同一份快照
  - 🆕 **给 http2 加 timeout + `inFlight` 防重入**〔codex #8〕。
    现有 `apns.ts:73-101` 从连接到结束**没有任何超时**，请求挂住的话每轮定时器都会再堆一个连接
  - 🆕 每次 push 带 **`stale-date` = 下一次预期更新时间**（D5）；
    `ContentState` 里 **`updatedUnix` 要跟 `sinceUnix` 分开**〔codex #12〕——
    后者是本轮开始时间，拿它当「数据新鲜度」会让旧数字看起来很新

**验证**

- [ ] 隔离 hub E2E（另起端口 + 另一个 secrets 目录，R7 / `feedback_hub_test_isolation`），
      **绝不对生产 hub 发测试流量**
- [ ] 真机：app 杀掉后岛里的数字仍在变（**这一条就是整刀的价值判据**）
- [ ] 🆕 记录「APNs 接受时间」**和**「真机上实际变化时间」两个时刻〔codex #12〕——
      `priority: 5` 可能被合并/延迟/丢弃，**「发了 200」不等于「用户看见了」**，
      只看 status 200 会得出一个假的结论
- [ ] 挂一小时看 log 有没有 throttle

**风险**：R2、R5、R6、R7

---

### M4a / M4b — 状态机 + 兜底层

**做什么**

research §5.2 挖出来的关键事实：hub 判断「CC 在动」靠 tmux `pipe-pane`，而它
**第一个 client attach 才开、最后一个走就关**（`hub.ts:1017-1025`、`1067-1072`）——
**恰恰在 app 退到后台、最需要岛的时候没有**。所以状态判据全部换成不依赖 attach 的：

#### 🔴 原来那三个判据全都不够硬，两轮 codex 都点了 〔#5 / 高〕

我原来写的：

| phase | 原判据 | 为什么不行（已核实） |
|---|---|---|
| `working` | transcript mtime 前进过 | **假阳**：nudge/keepalive 会主动往 session 注消息（`hub.ts:2643-2699`），user/system/tool/compaction 记录也都推 mtime。**假阴**：长推理或长工具调用期间可能根本不写 JSONL |
| `waiting` | `askuser-pending.json` 非空 | 那是**全局**数组（`askuser.ts:41-58`），别的 session 卡权限会让**这个** session 假 waiting。好在条目自带 `sessionName`（`askuser.ts:20-25`），能过滤 |
| `done` | Stop hook `POST /thinking` | **不可靠**：`thinking-hook.py:79-100` 没 thinking 就直接 return，hub 端还要求非空且有 anchor（`hub.ts:1675-1689`）。没思考链的那一轮**永远等不到 done** |

**还有一条两轮里只有第二轮发现的**：codex session 的 transcript 在 `~/.codex/sessions`（`hub.ts:744`），
而 `claudeTranscriptPath` 写死 `~/.claude/projects/…`（`hub.ts:545-548`），
`terminalUsagePayload` 又永远调它（`hub.ts:980`）——**整套 mtime 判据对 codex session 全盘失效**。
（这是现有 `terminal_usage` 就有的口子，不是本刀引入的，但 M4 会踩上去。）

#### 改成显式事件驱动，mtime 降级成 heartbeat

hub 手里本来就有明确的事件，不用去猜：

| phase | 显式信号 | 位置 |
|---|---|---|
| `working` | app `send` 被接受 → 建 `run_id` | `hub.ts:1961-1978` |
| `waiting` | AskUser **pre**（同 session 过滤） | `askuser.ts:20-25` 的 `sessionName` |
| `working` | AskUser **post** | 同上 |
| `done` | MCP `reply` 到达 | `hub.ts:2507-2579` |
| `done` | **新增一个无条件的 Stop lifecycle 端点** | 不复用「有内容才发」的 thinking hook |

优先级：`waiting > done latch > working > idle`。
**mtime 只在「已知存在一个 working run」时用来推 `lastProgressAt`**（喂看门狗），
路径未知（codex session）时状态是 `unknown`，**不是立刻 timeout**。

#### 🔴 冷启动那条我抄错了对象 〔第二轮 codex · 高〕

原 plan M4 写「app 冷启动要真的 `end()` 掉孤儿卡」，抄的是友邻的【坑 22】。
**但那条经验的前提在我们这儿不成立**——

- 友邻：数据源是 **app 内的网络请求**，app 被杀 = 那一轮真的没了 → 该 end
- 我们：数据源是 **Mac 上的 hub**，**iPhone app 被杀恰恰是正常工作模式**，
  那一轮很可能还在好好跑，hub 也还在推

无条件 end 会**把一个 hub 正在正常更新的岛杀掉**，还让它的 update token 失效。
而且这跟 M2 写的「以 `Activity.activities` 为事实、接回来」**直接打架**——
我自己 plan 里两段互相矛盾。

**改成对账，不是清场**：

```
冷启动 → 枚举 Activity.activities → 重报 token → 连 hub
       → 按 activity_id / run_id / session_name 问 hub：这轮还活着吗
           ├ 活着        → reattach，什么都不做
           ├ 明确不在了/已超时 → end
           └ hub 暂时连不上 → 保留 + 显示 stale（不猜死活）
```

⚠️ 「用户划掉后回 app 要不要自动重挂」是**产品规则**（M2 那条腿），
跟「孤儿清理」是两件事，**别做成同一个入口**。

#### 拆成两步

原来的 M4 塞了 FSM + 隐私 + 计时 UI + 看门狗 + 冷启动 + end 策略，
已经不满足「能单独验证」了。拆：

- **M4a 显式状态机**：上面那张表 + 优先级 + `run_id`，四种 phase 真机各见一次
- **M4b 兜底层**：`stale-date` / 看门狗 / hub 重启对账 / 冷启动对账

- 状态**跳变**事件驱动推 `priority: 10`（跳变本来就稀疏，不会撞预算）；
  用量数字继续走 M3 的 2-5 分钟 `priority: 5`
- `detail` 字段受隐私开关控制（R9：岛在锁屏上人人可见）——
  复用现有推送那个 `preview: "hidden"` 开关，不新造一个

**🆕 收尾：不要假设「结束」一定会来**【坑 21/22/28】

友邻这条标了 🔴🔴🔴，是拿一次真事故换的，而且**我们的架构比他们更容易撞**：
他们的数据源在本机，我们的在 **Mac 上的 hub**——Mac 睡了 / hub 挂了 / tmux session 没了 /
Wi-Fi 断了，推送就停，而 app 那会儿多半也不在跑，**没有任何人来收尾**。
屏幕上就是一个永远亮着的「在干活」。

三道保险，缺一不可：

1. **D5 的秒数**（免费的活着证据）——秒数停了就是出事了，肉眼可辨
2. **hub 侧看门狗**：`working` 状态下 transcript mtime 超过 N 分钟没动
   → 自己判失败、主动推 `event: end`
3. **app 侧冷启动收摊**【坑 22】：app 重开时，上一轮那张卡可能还挂着，
   而那一轮的数据源早随进程没了。**要真的调 `end()`，不是把本地变量清掉就完事**——
   只清本地的话，锁屏上那张卡会一直显示「在干活」，而根本没有任何人在干。

⚠️ **`staleDate` 不是超时**【坑 21/28】：它只告诉系统「过了这点这些数别当真」（可能画灰），
**它不会替你结束 activity**，而且「画成灰」是状态不是保证的视觉效果，
随系统版本和显示位置变，**别把界面逻辑压在上面**。
给的时候也**别给余量**——一个已经作废的数字不该再「新鲜」一分钟。

**验证**

- [ ] 四种 phase 各在真机上看到过一次
- [ ] 隔离 hub 上跑一轮完整流程：发问 → working → 撞权限 → waiting → 回答 → working → done
- [ ] `preview: hidden` 时 `detail` 确实是空的
- [ ] 🔧 **改过的验收**：kill 隔离 hub → **supervisor 拉起新 hub → 新 hub 从持久状态对账补发 `end`**
      （原来写的「秒数停住 + 死掉的 hub 自己收尾」物理上不成立，见 D5）
- [ ] Mac 睡死那一路：只验「到 `stale-date` 后岛上显示数据已过期、计时不再假装在线」
- [ ] 🔧 app 杀掉重开：**对账**——hub 说还活着就 reattach，别 end（原来写的无条件 end 会误杀）
- [ ] 别的 session 卡在 AskUser 时，**这个** session 不能假 waiting
- [ ] codex session 上不会因为读不到 transcript 就判成 timeout（应为 unknown）

---

### M5 — push-to-start（岛自己冒出来）

**做什么**

- hub 用 `laStartTokens` 发 `event: "start"`，payload 带
  **`alert`（🔴 必需，原 plan 漏了）** + `attributes-type` + `attributes` + `content-state`
  - 🔴 **`alert` 是必需的**〔两轮 codex 都点了，我二次核过 Apple 原文〕：
    "Include an `alert` in the JSON payload."——漏了**直接启动失败**。
    ⚠️ 这个 alert 会弹给粟粟看，所以**必须用不泄密的固定文案**（R9），不能带对话内容
  - `attributes-type` 是**结构体类型名字符串**（`"CCActivityAttributes"`），不是全限定名
  - `input-push-token: 1`（iOS 18+，启动同时拿一个新 update token）：
    官方措辞是 "you can add"，**是可选**。我们**要加**——不加的话远程起的岛拿不到 update token
  - 三种 event 的字段契约写成**判别联合**，别用一个可选字段全都塞的大结构体〔codex #4〕
- 触发点：`idle → working` 或 `→ waiting` 且当前没有活着的 activity
- 生命周期协调：**常驻岛和事件拉起的岛不能打架**。定一条规则——
  同一时刻只允许一个 activity；hub 侧记 activity 存活状态，app 侧起岛前先查

**验证**

- [ ] app 完全杀掉 → 隔离 hub 发 start → 岛凭空出现
- [ ] 🆕 **不能只验「岛冒出来了」**〔codex #4〕：要跑完整链
      「远程 start → app 被唤醒后回传新的 update token → 再 update → end」
- [ ] 不会出现两个岛

---

### M6 — 静态 widget（锁屏 / 主屏）· 可与 M4/M5 并行

**做什么**

- App Group 快照：`MemoryPalace/Services/UsageSnapshotWriter.swift`
  （照 `PushIdentityWriter.swift:15-45` 的现成范式），主 app 收 `terminal_usage` 帧时写一份
- widget 侧 `UsageSnapshotStore` 读（照 `MemoryPalacePushNSE/SharedIdentityStore.swift`）
- `TimelineProvider` + `systemSmall` / `accessoryRectangular`

**⚠️ 必须先说清楚的限制**：widget 的 TimelineProvider 在 extension 进程跑，
**撑不住一条常驻 WS**，刷新时机又受系统预算控制（每天几十次量级）。
所以静态 widget 显示的**必然是「上次 app 开着时的数字」**。

🔧 〔codex 修正〕：原文写的是「**连不了**网」，**过强了**——
Apple 明确允许 extension 在 timeline/snapshot 活跃期间发有限的网络请求。
准确的说法是「**不能拿常驻 WS 当数据源**」。
我们仍然走 App Group 快照，理由是**更简单、离线时也诚实**，不是因为做不到。

→ 我的处理：**widget 上明确标「x 分钟前」**。宁可显示一个诚实的旧数字，
也不要一个看起来是实时、其实是昨天的数字。

**🆕 五个坑，其中一个要粟粟拍板**

- **【坑 37】🔴🔴 锁屏小组件是单色的 —— 马卡龙三色在那儿活不下来** ⧫ **粟粟已批（2026-08-29）：行，用长度代替颜色**
  系统走 vibrant 渲染把内容压成单色，好让它在任何壁纸上都看得清。**这不是 bug，是设计。**
  友邻还专门撤回过一个自己写错的「解法」：`widgetAccentedRenderingMode(.fullColor)`
  管的是 accented（染色）模式，**跟锁屏的 vibrant 是两回事**，不管用。

  对我们的具体后果：**薄荷/杏黄/草莓这套三档配色是整个用量显示的核心信号，
  它在锁屏小组件上会全变成同一种半透明的白。**

  **我的具体提案**（不是开放问题，粟粟直接改就行）——
  用量这类数据其实比桌宠好办：**颜色丢了，长度还在。**

  | family | 画什么 | 单色下还剩什么 |
  |---|---|---|
  | `accessoryCircular` | `Gauge` 圆环，填充比例 = ctx% | **环的长度**，一眼就知道满没满 |
  | `accessoryRectangular` | 三行 `ctx/5h/7d` + 各一条细横条 | **条的长度** + 像素数字 |
  | `accessoryInline` | `Label("ctx 47%", systemImage:)` | 只有字（inline 只能一行字+一个 SF Symbol【坑 38】）|

  彩色的完整版（带马卡龙三色）留给**桌面小组件**【坑 40】，那边不去色。
  另外 accessory 三种都要 `containerBackground(.clear, for: .widget)`，
  锁屏底不能自己画黑（会挡壁纸）。

  ⚠️ 这跟灵动岛/桌面那两处是**同一份数据的三种画法**，别写成三份逻辑【坑 42】。

- **【坑 36】锁屏 family 要显式声明**
  `.supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])`。
  漏声明的那一档，长按锁屏加小组件时**列表里根本没有**，不报错不警告。
  🔧 〔codex 修正措辞〕：官方语义是「**声明你实际支持的尺寸**」，
  不是「三种必须全声明」。我们三种都设计了内容，所以三种都声明——**是选择，不是平台强制**。

- **【坑 38】`accessoryInline` 是一行文字 + 一张可选图**
  加布局、改颜色**不生效也不报错**。
  🔧 〔codex 修正〕：官方定义是 "a single row of text and an optional image"，
  **不是「只能 SF Symbol」**。我们用 SF Symbol 是**安全的设计选择**，不是 API 限制。
  → 像素字在 inline 那档大概率用不上，别在那儿硬来。

- **【坑 41】🔴 iOS 17 起必须用 `containerBackground(for: .widget)`**
  直接在最外层写 `.background(...)` 编译不报错，只是桌面上有一圈对不齐的边、
  待机/锁屏场景下某些位置变纯白底。**我们的底色是纯黑，这条要是漏了会很显眼。**

- **【坑 42】🔴 小组件读不到 Live Activity 的 `attributes`，别在两处各写一份**
  它们是两套完全独立的东西。session 名之类的事实**走 App Group，别抄第二份**——
  抄了就等着分岔，而且不报错。
  （友邻说这是他们仓库里第三次撞同一条：坑 3 / 坑 30 / 坑 42，
  **凡是同一个事实被抄了两份，就等着它们分岔**。）

- **【坑 3 / 39】写完 App Group 要主动 `WidgetCenter.shared.reloadTimelines(ofKind:)`**
  小组件不会自己知道 App Group 里的值变了。
  ⚠️ `kind` 字符串必须跟 `StaticConfiguration(kind:)` **一字不差，写错不报错、只是永远不刷新**。
  → 定案：`kind` 抽成一个常量放共享层，两边都引它（这本身就是【坑 42】那条规矩的应用）。

**验证**

- [ ] 长按锁屏能在列表里**找到**这个 app【坑 36】
- [ ] 锁屏和主屏各放一个看过；**确认锁屏那块确实是单色**（提前接受，不是当 bug 修）【坑 37】
- [ ] 桌面那块颜色正常【坑 40】
- [ ] app 里数字变了 → `reloadTimelines` → 桌面那块跟着变【坑 39】
- [ ] app 杀掉几小时后，widget 上的时间戳确实在涨（说明「旧」这件事是可见的）

---

## 三、验证基线（每个 M 都要过）

```bash
cd "/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace"
xcodegen generate
xcodebuild -scheme MemoryPalace build          # macOS 不能被 iOS-only 代码炸（R4）
xcodebuild -scheme MemoryPalaceIOS build
xcodebuild -scheme MemoryPalaceTests test
xcodebuild -scheme StickerProbeUITests build   # ← 原 plan 漏了这个 scheme〔codex #10〕
cd cc-bridge && bun test
```

装机走 worktree 分流规则（已在案 `feedback_deploy_by_worktree`）；
装之前 `stat` + `strings .debug.dylib` 核新符号（`feedback_install_stale_app_bundle`）。

---

## 四、明确不做

- ❌ **CRT 弧面搬进 widget** —— Metal shader 无官方支持依据，且灵动岛本来就是真弧角
- ❌ **把像素零件重构成公共 module** —— 只搬用得上的（手术式修改）
- ❌ **动 `sendAPNs` / `pushTokens` / 现有 30s 定时器** —— 三个都是「加一条，不改原来那条」
- ❌ **拿生产 hub 测任何一步**
- ❌ **指望「岛永久常驻」**【坑 29】——系统会结束它、用户会划掉它、重启就没。
  能做到的上限是「只要还在用 app 就一直在」；真要一直在那是 M6 锁屏小组件的活
- ❌ **拿 `staleDate` 当超时用**【坑 21/28】

---

## 五、外部实证溯源：友邻仓库的 42 个坑，哪些砸中了我们

来源：[`Cheiineeey/ios-app-where-it-breaks`](https://github.com/Cheiineeey/ios-app-where-it-breaks)
`01-live-activity/STEPS.md`（真机验过的工程 + 坑清单）与 `04-push/README.md`。
**这些是别人拿真机时间换来的，不是我推理出来的**，所以单独列一节标明出处。

| 坑 | 讲什么 | 对我们 | 落在 |
|---|---|---|---|
| 35 🔴🔴 | 时间类/状态类**混用**才是最优解；秒数是「活着的证据」 | **改架构** → D5 | D5 / M4 |
| 21 🔴🔴🔴 | 别假设「结束」一定会来（真事故：亮了 12 分钟，服务端零日志） | **我们比他们更容易撞**（数据源在 Mac 上） | M4 |
| 29/30/31 🔴 | 「永久常驻」不存在；本地标记 ≠ 事实；挂岛必须幂等 | 粟粟选的 ④ 有常驻那一半，必须两条腿 | M2 |
| 37 🔴🔴 | 锁屏小组件是**单色** | **马卡龙三色在锁屏上活不下来**，要粟粟拍板 | M6 |
| 8 🔴 | `NSExtension` 必须真嵌套字典，否则装机才被拒 | 加一步 `plutil -p` 核 | M0 |
| 42 🔴 | 小组件读不到 LA 的 `attributes`，别抄两份 | `kind` 和 session 名走 App Group | M6 |
| 41 🔴 | iOS 17+ 必须 `containerBackground` | 我们底色纯黑，漏了很显眼 | M6 |
| 36 🔴 | 锁屏三种 family 要显式声明，否则列表里找不到 app | — | M6 |
| 22 🔴 | 冷启动要真 `end()`，不是清本地变量 | — | M4 |
| 2/23/34 | 紧凑态四五字符硬上限 | **改了粟粟拍的 compactTrailing 方案**（去掉 `ctx` 前缀） | M1 |
| 5 | 用户能在设置里关掉实时活动 | 界面要说话别没反应 | M1 |
| 3/39 | 小组件不会自己知道 App Group 变了；`kind` 写错不报错 | — | M6 |
| 28 | `staleDate` 不是超时、别给余量 | — | M4 |
| 38 | `accessoryInline` 只能一行字 + SF Symbol | 像素字在那档用不上 | M6 |
| 40 | 桌面彩色 / 锁屏单色，正脸放桌面 | — | M6 |

**核对后确认不影响我们的**（写下来免得以后重查）：

| 坑 | 为什么不影响 |
|---|---|
| 13（像素画被插值抹平） | `PixelIcon` 是 `Canvas` 画矢量方块（`JournalKit.swift:440-461`），Silkscreen 是矢量字体，**都不过插值那条路** |
| 11（`com.example.*` 被占，报错指向完全错误的方向） | 我们的 `group.com.susu.MemoryPalace` 已注册且在跑 |
| 1/9/10（`Text(timerInterval:)` 的区间和归零收尾） | 我们不做倒计时；但 D5 用的是 `style: .timer` 正计时，M4 上机时留意有没有同类边界 |
| 6/7（命令行签名 / iCloud 目录签名失败） | 我们的构建链路早就跑通了 |
| 04-push 第 2 堵墙（token 会变，每次启动都要上报） | ✅ `didRegisterForRemoteNotifications` 每次启动都 fire（`PushNotifications.swift:26-30`）|
| 04-push 第 4 堵墙（JWT 缓存别太久） | ✅ 缓存 50min（`apns.ts:38`），Apple 要求 <1h 且 ≥20min 才换一次 |
| 04-push 的 9 堵墙 | 见下方单独一条——**其中一条我核错了** |

### 🔴 更正：04-push「第 3 堵墙」我们**没有**过，那是一个继承下来的潜伏 bug 〔codex #3〕

原文我写的是「sandbox/production 分环境 ✅（hub 存 `env`）」。**错了**，
我只看到 `PushInfo` 里有个 `env` 字段就打了勾，没去追它有没有被用。核实结果：

| 环节 | 实际 |
|---|---|
| app 上报 | **三处全硬编码 `"sandbox"`**（`CCBridgeWebSocketClient.swift:90`、`:97`、`:1070`）|
| hub 存 | 存了 `env`，但调用时 `sendAPNs(token, title, body, contextId, metadata)` —— **压根没传**（`hub.ts:1339`）|
| apns.ts | `HOST` 是**模块级单值**，默认 sandbox（`apns.ts:15`）|

也就是说：**这条链路上 `env` 从头到尾没起过任何作用。**
Xcode 直装的 Debug 包能通，纯粹因为它本来就是 sandbox token。
**一旦走 TestFlight / 上架，全部 `BadDeviceToken`。**

→ 这不是本刀引入的，是**现有 alert 路径就有的潜伏 bug**。
   本刀的处理（手术式修改，不顺手扩大战场）：
   - **LA 这条新路径从第一天就按 per-record `env` 选 host**，不重蹈覆辙（D6 第 4 条）
   - 现有 alert 路径的这个 bug **单独记一笔进 review 文档**，
     不在这一刀里顺手改（它牵扯 app 端上报和 hub 端两处，够单独一刀）

> 一句话总结这份仓库对我们的价值：**它把「静默失败」这一类风险从「未知」变成了清单。**
> 本 plan 原来的 R1-R9 全是我从我们自己的代码里推出来的，
> 而上面这些是**别人在真机上撞出来的**，两者基本不重叠。

---

## 六、Todo checklist

### M0 基建
- [x] `MemoryPalaceWidget/` 目录 + 空 `WidgetBundle` + Info.plist + entitlements
- [x] `project.yml` 加 target，iOS app `embed: true`
- [x] 确认两份 iOS plist 哪份生效，只改生效那份加 `NSSupportsLiveActivities(+FrequentUpdates)`
- [x] Silkscreen ttf 进 widget resources + widget Info.plist `UIAppFonts`
- [x] 三 scheme build 通过 + 装机 `ls PlugIns/` 见 `.appex`
- [x] 🆕 `plutil -p` 核 `.appex/Info.plist` 的 `NSExtension` 是嵌套字典【坑 8】

### M1 视觉
- [x] `CCActivityState.swift`（纯数据，显式 CodingKeys，无 Date）
- [x] `CCActivityAttributes.swift`（iOS + widget）
- [x] 五种呈现 View
- [x] 像素零件搬运（不搬 metal）
- [x] `#if DEBUG` 手动起岛入口
- [x] 🆕 `areActivitiesEnabled` 关掉时界面要说话【坑 5】
- [x] 上机肉眼验：像素字 ✓ 三档色 ✓ waiting 优先 ✓ 紧凑态纯数字不超四五字符 ✓【坑 2】

### M2 token + 注册协议（D6）
- [x] `CCLiveActivityManager.swift`（两种 token 监听）
- [x] 🆕 挂 `Activity.activityUpdates` 全局监听（远程 start 起的岛也要能拿 update token）
- [x] `sendLiveActivityToken`，字段按 D6 带全（activity_id / session_name / device_id / env / preview）
- [x] 🆕 `didOpen` 全量补报（WS 断线窗口产生的 token 不能丢）
- [x] hub `register_la_token` + 两个独立 Map（update 按 activity_id / start 按 device_id）+ `la-tokens.json`
- [x] 🆕 token 轮换按稳定 ID **replace** 旧值，不是无限追加
- [x] 🆕 `activityStateUpdates` + `scenePhase` 回前台 recheck（两条腿）【坑 29/30】
- [x] 🆕 挂岛方法幂等 + 进来先查 `Activity.activities`（防两个岛）【坑 31】
- [x] 验 `push-tokens.json` 零变化 + `bun test` 全绿
- [ ] 划掉岛 → 回 app → 自己回来；连点两次只有一个岛

### M3a 单次远程 update ← 最小可交付线
- [x] 🆕 **先** `apns-alert.test.ts`（characterization，锁住旧行为）
- [x] **再**抽 `postAPNs`，跑上一条必须全绿
- [x] `sendLiveActivityAPNs`（topic 由 `${TOPIC}` 派生 / host 按 record 的 env 选）
- [x] `apns-liveactivity.test.ts` + payload `< 4096 bytes`
- [x] `activity-state.test.ts`（TS 侧对 golden fixture，Swift 侧那半在 M1）
- [ ] 隔离 hub 手动发一条 → 真机岛上数字变了

### M3b 周期 scheduler
- [x] 定时器进 `startHub` / 存 handle / `wss.close` 清理
- [x] 每 session 算一次再 fan-out（别按 token 重复读 512KB）
- [x] per-activity 串行队列 + 单调 timestamp + `inFlight` 防重入
- [x] http2 timeout
- [x] `stale-date` + `updatedUnix`（跟 `sinceUnix` 分开）
- [ ] 真机：app 杀掉数字仍在变
- [ ] 记录「APNs 接受时间」vs「真机实际变化时间」两个时刻

### M4a 显式状态机
- [x] app `send` 被接受 → working + 新 `run_id`（`hub.ts:1961-1978`）
- [x] AskUser pre/post → waiting/working，**按 sessionName 过滤**
- [x] MCP reply → done（`hub.ts:2507-2579`）
- [x] 🆕 新增**无条件** Stop lifecycle 端点（不复用「有内容才发」的 thinking hook）
- [x] 优先级 `waiting > done latch > working > idle`
- [x] 跳变事件驱动 priority 10
- [x] `detail` 接隐私开关（**per-LA-record 的 `preview`**，缺字段默认 hidden）
- [x] D5：expanded/锁屏放 `Text(_:style:.timer)`；结束换定格图标【坑 35】
- [ ] 四种 phase 真机各见一次；别的 session 卡权限不能污染这个 session

### M4b 兜底层
- [x] mtime 降级成 heartbeat（只在已知有 working run 时推 `lastProgressAt`）
- [x] codex session（`~/.codex/sessions`）判 `unknown` 不判 timeout
- [x] hub 持久化 `activity_id/run_id/session_name/phase/last_progress_at/token`
- [x] hub 启动时对账：上轮 working 且超时 → 立刻补发 `end`
- [x] `stale-date` 覆盖下一次推送窗口 + grace；view 里读 `context.isStale`
- [ ] app 冷启动**对账**（不是无条件 end）
- [x] `staleDate` 不给余量、不拿它当超时【坑 28】
- [x] 8 小时上限 → 滚动换岛（M5⑤）
- [ ] Mac 时钟拨偏 ±5 分钟的真机用例
- [ ] kill 隔离 hub → supervisor 拉起 → 新 hub 对账补 end

### M5 push-to-start
- [x] hub 发 `event: start`（**必需 `alert`** + attributes-type 类型名 + `input-push-token: 1`）
- [x] start 的 alert 用不泄密固定文案（R9）
- [ ] 完整链：远程 start → app 回传新 update token → update → end
- [x] 单 activity 互斥规则
- [ ] app 杀掉后岛凭空出现

### M6 静态 widget
- [x] 按 v2.1 已定的三 family 方案实现（Gauge 环 / 细横条 / Label）——
      正文已给具体提案，不再是开放问题〔codex 提醒 checklist 跟正文不同步〕
- [x] `UsageSnapshotWriter` / `UsageSnapshotStore`（`kind` 抽常量共享）【坑 39/42】
- [x] TimelineProvider + systemSmall + accessoryRectangular
- [x] 🆕 `.supportedFamilies([...])` 三种锁屏 family 显式声明【坑 36】
- [x] 🆕 `containerBackground(for: .widget)`【坑 41】
- [x] 「x 分钟前」诚实时间戳
- [ ] 锁屏 + 主屏各验一次（含「锁屏确实是单色」这一条）

### 收尾
- [ ] `review-真灵动岛.md`（边界情况 / 与下一模块交互风险 / 技术债）
- [ ] `NOW.md` + `PROJECT_ROADMAP.md` 更新

---

---

## 七、下一阶段探索（本刀之后）

### 后台保活

灵动岛的后台更新走的是 APNs（系统级推送，不需要 app 进程活着），**不等于 app 保活**。
当前 plan 的架构已经能做到「app 被杀了岛照样更新」，但 app 本身的后台能力仍受 iOS 限制。

值得探索的方向（不在本刀范围内，单独立项）：

- **BGTaskScheduler**：定期唤醒 app 做轻量操作（刷新数据、补报 token）
- **Silent push**（`content-available: 1`）：hub 侧事件驱动唤醒 app
- **评估哪些操作真正需要 app 活着** vs 纯靠 APNs 就够了

⧫ 粟粟批注（2026-08-29）：后台保活探索列入下一阶段。

---

**✅ 粟粟批注完毕（2026-08-29）。可以开始实施。**
