# Plan：设备工具 P1（日历 / 提醒 / 剪贴板 + 四件露出）

> ⚠️ **DON'T IMPLEMENT YET** — 等粟粟 ⧫ 批注后按 go 执行。
> 上游：`docs/research-设备工具.md`（分期已拍「先弄工具」）。依赖：权限 P1（`PermissionDomain`/tool loop 闸/权限页）——本 plan 在 `worktree-device-tools`（基于 `worktree-permissions`）上做。
> 批注约定：⧫=粟粟，`<⧫> </⧫>` 内为粟粟标注。

## -1. 与《minis对比》线的接缝（08-24 读完 `docs/minis对比/对比报告.md` 后补）

对比线八个洞里三处直接咬到本 plan：

- **前置依赖：A1 `ToolCallPreflight`（对比线洞 1）**。`fs_write` 缺 `content` 清空文件的病根 = 参数缺失一路走到执行器；本 plan 的 11 个工具同病（`calendar_delete` 缺 `id`、`reminders_create` 缺 `title`…）。**设备工具不各自手搓校验，统一建在 preflight 上**：从 `ToolDefinition.required` 校验，缺参作为 `isError` 回灌让模型自愈。→ 执行顺序：A1 先落（对比线，天级），本 plan 的 T7 dispatcher 以它为前提。若 A1 没排上，本 plan 的 T0 自带一个最小 required 校验并注明「A1 落地后合并」。
- **`open_url` 不能开 `mp://`**——MP 目前 **0 个 URL scheme**（L1 实锤）。P1 白名单 = http(s) + `settings:`；`mp://` 等对比线 C4 URL spec。权限 P2 的拒绝深链同样挂 C4。
- **洞 3 工具循环中间请求不记账 + A2 熔断**：设备工具让每 turn 工具轮次更多，漏账放大；不归本 plan 修，但 review 里要盯。

**撞车面（三线共享文件）**：`ToolRegistry.swift` / `ConversationViewModel` tool loop / `PermissionsSettingsTab` / 各 SettingsTab / `ConfigSchema`。**合并顺序提案（等粟粟拍）**：① worktree-permissions（P1 权限，已验证）→ ② 对比线 A1 preflight + E1（小时级、天级两条独立小刀，master 直做）→ ③ worktree-device-tools（本 plan，rebase 到 ①②之上）→ ④ 对比线其余（B/C/D/F/G 组按她批的优先级）。理由：③依赖①的 PermissionDomain 和②的 preflight；②体积小先落不阻塞谁。

## -0.5. P2 已排：工具结果可交互卡片（粟粟 08-25 点名）

> 粟粟：「能不能做一个工具渲染可交互卡片（比如带上系统日历的一个标志什么的）」——**排 P2 第一刀，不设远期**。理由：它提升的是**已有能力**的体验密度，比再加三个新工具（Location/Maps/Weather）对日常更值；而且 P1 的 envelope 已经是结构化 JSON，卡片是顺着长出来的，不是新地基。

**做什么**：只给「产生/指向系统实体」的工具结果出卡片，其余保持现在的紧凑折叠行。
- `calendar_create` / `calendar_query`（单条命中时）→ 事件卡：系统日历图标 + 标题 + 时间 + 地点，点击 → `calshow:` 深链跳系统日历到那天
- `reminders_create` → 提醒卡：图标 + 标题 + 到期 + 列表，点击 → `x-apple-reminderkit://`
- `clipboard_read` 图片 / `ocr_image` → 缩略图 + 识别文字前两行
- 其余（device_info / open_url / notify_schedule / 各 query 多条）→ 维持折叠行

**怎么实现**（顺着 P1 的形状，不新建渲染管线）：
1. `DeviceToolIO.ok(_:card:)` 增补可选 `card` 字段：`{"type":"calendar_event","title":…,"start":…,"deeplink":"calshow:…"}`——**只加字段不改协议**，模型看到的仍是同一份 JSON（卡片字段对它是无害噪声，也可作为它复述的素材）
2. `MessageSegment.toolResult` 渲染层（`MessageSegmentsView`）解析 `card` → 有则出 `DeviceToolCardView`，无则维持现状
3. `DeviceToolCardView`：一个 switch on card.type 的轻量卡（Theme 配色，图标用 SF Symbols 的 calendar/checklist），点击走 `open_url` 同款白名单校验后 `UIApplication.open`
4. 深链 scheme 白名单加 `calshow:` / `x-apple-reminderkit:`（P1 的 open_url 白名单只有 http(s)+settings，这里是 UI 层直开不经模型，风险面不同）

**不做**：卡片内编辑（改时间/改标题）——那是双向同步语义，等真需要再说；也不做「卡片里再放按钮触发新工具」（会把渲染层变成第二个 agent 入口）。

**估**：天级。前置只有 P1（已完成）。

**实现记账（08-25 当晚落地）**：
- [x] envelope 加可选 `card` 字段 + `DeviceToolIO.card(...)` 构造器（协议零改动，老对话无字段自然走折叠行）
- [x] 出卡的工具：`calendar_create` / `calendar_query`（**仅单条命中**，多条列表用文字更好读）/ `reminders_create` / `clipboard_read`（图片）/ `ocr_image`
- [x] `DeviceToolCardView`：图标或缩略图 + 标题 + 副标题 + 详情 + 右上角跳转箭头；点击走深链
- [x] 深链白名单 `calshow:` / `x-apple-reminderkit:`（渲染层直开、不经模型，与 open_url 工具那套白名单分开）
- [x] 折叠行**保留**：它是「过程」，卡片是「结果」，点开还能看原始 JSON
- [x] **日历卡升级为系统原生详情**（粟粟点的「直接用苹果的」）：点卡片弹 `EKEventViewController`（EventKitUI 公开 API），苹果自己画的事件卡，自带编辑/删除/加提醒；重复事件按 occurrence 定位到那一次；拿不到 event id 或 macOS 回落 `calshow:` 深链
- [x] **核实并修正一处口误**：EventKitUI 只有 EKEventViewController / EKEventEditViewController / EKCalendarChooser 三个组件（SDK headers 实查），**提醒事项没有任何系统 UI 组件**——提醒卡只能跳 app，这是 Apple 的 API 缺口不是取舍
- [x] 图标口径：拿不到别家 app 的真实 icon（iOS 无公开 API + 商标），用 SF Symbols（苹果给开发者的官方符号集）；真正的「系统观感」靠上面那条原生 sheet 拿到

## 0. P1 边界

**做**：EventKitService + 日历三工具 + 提醒三工具 + 剪贴板读 + 四件露出（OCR/通知/开链接/设备信息）+ 四个权限域 + usage keys + 单测 + 模拟器实证。
**不做**：Location/Maps/Weather/Photos（P2）· 日历 update / 提醒 update（P1 先 create+delete/complete，改动作 P2）· 地理围栏提醒（要定位授权，随 P2）· 重复规则创建（查询要正确处理重复事件，创建重复事件 P2）· 通知 action 回对话深链（P1 通知只发，action 回流是 P2 增强）。

## 1. 地基：EventKitService + SystemAuthQueue

新文件 `MemoryPalace/Services/DeviceTools/`：

- `SystemAuthQueue`：全局串行授权队列——任何系统授权请求（EventKit/通知/未来 Photos/Location）都排队，一次只弹一个 sheet，每次完成留 0.5s cooldown（Minis HealthKit 同款）。超时（30s）= 显式 `.timeout` 错误，不是"当作拒绝"
- `EventKitService`：共享 `EKEventStore` 单例；`ensureEventsAccess()` / `ensureRemindersAccess()`（iOS 17+/macOS 14+ `requestFullAccess*`）；查询窗口默认**未来 7 天**、参数显式 `from/to`（ISO 8601 或相对 `-7d/+2h`）、`limit` 默认 20 截断时附 `total_available`；重复事件返回 `series_id + occurrence_date`；删除带 `span: this|future`
- `DeviceToolResult`：统一 envelope（`ok/data` 或 `ok:false/error{code,message}`）→ 渲染成给模型的紧凑文本；timeout/denied/not_available 三类 code 固定

## 2. 工具清单（ToolRegistry 注册，名字按 `fs_*` 惯例）

| 工具 | 参数 | 域 |
|---|---|---|
| `calendar_query` | from?, to?, limit?, calendar? | calendar |
| `calendar_create` | title, start, end?, all_day?, location?, notes?, calendar? | calendar |
| `calendar_delete` | id, occurrence_date?, span? | calendar |
| `reminders_query` | list?, include_completed?, due_before?, limit? | reminders |
| `reminders_create` | title, due?, list?, notes?, priority? | reminders |
| `reminders_complete` | id | reminders |
| `clipboard_read` | — | clipboard |
| `ocr_image` | attachment_id \| file_path, languages? | toolsMaster（输入是用户已给的图；不新增域） |
| `notify_schedule` | title, body, after_seconds \| at, id? | notifications（二值·自主行为区） |
| `open_url` | url | system（永远放行，不进权限页） |
| `device_info` | kind: info\|battery\|storage | system（同上） |

- 六个 EventKit 工具**各归各域**（研究 §四洞 2）：提醒工具绝不挂在 calendar 域下
- 工具描述里写清坐标/时区/重复事件语义（模型用得对比功能多重要）
- 内建工具数 16→27：全部走 `ToolSchemaRenderer` 字典序，prompt 前缀稳定；MCP defer 阈值不受影响（只算 MCP）

## 3. 权限接线

- `PermissionDomain` 新增 `calendar`、`reminders`、`clipboard`（三档，默认 **notAllowed**——新能力隐私向默认关，用户在权限页/首次弹卡开）+ `notifications`（二值，默认关，进「AI 自主行为」区）
- `forTool(named:)` 映射补四族；`injectionDomains/toolDomains` 更新；权限页「AI 能做什么」区自动多四行（descriptor 驱动，零 UI 代码）
- tool loop 闸零改动即生效：askOnce 调用时弹卡 / notAllowed 返回 permission_denied
- 系统授权状态区加「日历」「提醒事项」两行（EKEventStore.authorizationStatus）
- **新工具准入检查项**（研究 §四洞 3）：注册表里每个 Entry 必须能映射到一个域或明确 system 类——加一条单测锚死

## 4. usage keys（TCC 流程复用）

- iOS（`MemoryPalaceIOS-Info.plist`）：`NSCalendarsFullAccessUsageDescription`、`NSRemindersFullAccessUsageDescription`（+ 旧键 `NSCalendarsUsageDescription`/`NSRemindersUsageDescription` 一并放，零成本兜底）
- macOS（project.yml `INFOPLIST_KEY_*`）：同四键
- 剪贴板无 key；通知已有授权路径；Vision/Open/Device 无 key
- 验收：build 产物 Info.plist 逐键核验（权限 P1 那套命令）

## 5. 四件露出的实现要点

- `ocr_image`：解析 attachment_id → 附件库 UIImage / file_path → 文件库；走 `OCRStore` 同款 Vision 请求，**传 `CGImagePropertyOrientation`**（修 Minis EXIF 坑）；返回全文 + 按行块（bbox 归一化，原点左下——描述里写明）
- `notify_schedule`：`UNUserNotificationCenter` + `UNTimeIntervalNotificationTrigger`/`UNCalendarNotificationTrigger`；authorization 走 SystemAuthQueue；id 可幂等覆盖；P1 不做 category/action
- `open_url`：`UIApplication.open` / `NSWorkspace.open`；只允许 http(s) + `settings:`——别让模型开任意 scheme；`mp://` 等对比线 C4（MP 现无注册 scheme）
- `device_info`：型号/系统版本/电量/存储（`volumeAvailableCapacityForImportantUsage`）/app 内存 RSS

## 6. 影响范围

- 新增：`Services/DeviceTools/`（SystemAuthQueue / EventKitService / ClipboardTool / OCRImageTool / NotifyTool / OpenURLTool / DeviceInfoTool / DeviceToolResult）
- 改：`ToolRegistry`（+11 Entry）、`PermissionCenter`（+4 域 + forTool）、`ConversationViewModel` tool loop（+11 分支——或先抽一个 `DeviceToolDispatcher` 让 loop 只加一个 else-if）、`PermissionsSettingsTab`（系统状态区 +2 行）、两份 plist/project.yml、ConfigSchema（+4 perm keys）
- 不碰：hub、PromptAssembler 内核、现有 fs_* 工具

## 7. 测试与验收

- 单测：EventKitService 窗口/相对日期解析/重复事件 occurrence 语义（用 mock store 或 in-memory 日历）· SystemAuthQueue 串行+超时 envelope · forTool 四族映射 · 注册表准入锚 · envelope 渲染
- 模拟器实证：`calendar_create` → 系统日历 app 可见 → `calendar_query` 查回 → `calendar_delete` 消失；`reminders_create/complete` 同款；`clipboard_read` 读到粘贴板；`notify_schedule` 30s 后本地通知落地
- 双端 build + 全套测试绿 + 装机（worktree cwd→14；不可用则 Air，粟粟拍过先例）
- 粟粟真机清单：权限页新四行 · 日历域调「每次询问」让 AI 查日程看弹卡 · 让 AI 建个提醒 → 提醒事项 app 里看到 · 「读一下剪贴板」→ 系统粘贴提示 → AI 复述 · 发张图让 AI ocr

## 8. Todo checklist

- [x] T0 `Services/DeviceTools/` 地基：SystemAuthQueue + EventKitService + DeviceToolIO envelope ✅（超时→显式 error；授权串行 30s+0.5s cooldown）
- [x] T1 usage keys 四键进 iOS plist + macOS project.yml ✅ **build 产物 Info.plist 四键实证进包**
- [x] T2 `calendar_query/create/delete` ✅（默认未来 7 天窗口；重复事件 series_id+occurrence_date；删除 span this/future）
- [x] T3 `reminders_query/create/complete` ✅（fetch 10s 超时=显式 timeout）
- [x] T4 `clipboard_read` ✅（文本/URL 直回；图片→AttachmentStore 落附件返回 path）
- [x] T5 露出四件 ✅（ocr_image 传 EXIF 方向 / notify_schedule 一次性 / open_url 只 http(s)+settings / device_info info·battery·storage）
- [x] T6 PermissionDomain +4 + forTool + 权限页三行+通知行+系统状态两行 + ConfigSchema +4 ✅
- [x] T7 ToolRegistry +11 + DeviceToolDispatcher 单入口（tool loop 一个 else-if）+ required 预检（A1 最小版）+ systemHint 设备段 ✅
- [x] T8 DeviceToolsTests（日期/预检/域映射/新域默认关/注册表准入/envelope）✅ 写完，全套跑中
- [~] T9 双端 build 绿 ✅ + 全套 **592/592 绿** ✅（golden fixture 经 REGEN 钩子重生成：老 17 逐字节不变+新 11）· 模拟器实证四链 ⏳ 归真机清单
- [~] T10 装机 ✅（Air 00:46 包已强启，含权限 P1）+ review-设备工具.md ✅ 骨架 + NOW.md 行 ✅ · 粟粟真机清单 ⏳
