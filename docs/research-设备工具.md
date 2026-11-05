# Research：设备工具（把 Minis 的设备能力偷过来）

> 2026-08-24 · 粟粟拍「反正看都看了，先把 minis 的都偷过来」→「先弄工具，然后（离线沙箱）设为独立远线」。
> 源：OpenMinis 本地 clone 亲读 + DEVT-scout 逐族实现档案（codex read-only，`docs/prompts/2026-08-24-device-tools/reports/minis-offloads-report.md`，19 族 + 横切 + 6 条冲突）。
> license 口径沿用权限 research §一（GPL-3 可对照写；逐字搬的文件需豁免出 Commons Clause）。
> **状态：✅ 分期已拍（先弄工具）；本文为 plan 的底料。离线沙箱另立远线，本文不涉。**

## 一、架构判定（偷什么、不偷什么）

Minis 的设备工具是 **Linux 沙箱里的 shell 命令**（`apple-calendar list …`）→ iSH 内核 execve 拦截 → ObjC handler。MP 不走沙箱（沙箱是独立远线），我们的工具是 **ToolRegistry 原生 function call**。偷三样：

1. **能力集与子命令设计**（每族哪些动作、参数怎么切、结果什么形状）
2. **原生实现套路**（EventKit/CoreLocation 的调用模式、授权串行化、超时、坑）
3. **横切约定**（JSON envelope / 日期约定 / 主线程边界 / 超时必须显式 error）

**不偷**它家的权限闸——scout 抓出四个洞正好是反面教材（§四）。权限模型用我们自己的 P1 三档：每个新族 = `PermissionDomain` 加一行，tool loop 闸即生效，权限页自动出行。

**每族固定成本**：Service + ToolDefinition 注册 + usage key（有效 plist + build 产物核验，TCC 流程复用）+ PermissionDomain 一行 + 单测。

## 二、能力矩阵（Minis 全集 × MP 现状 × 判定）

| 族 | Minis 能力（scout CONFIRMED） | MP 现状 | 判定 |
|---|---|---|---|
| Calendar | list/freebusy/calendars/create/update/delete，EKEventStore 单例，iOS17+ `requestFullAccessToEvents` | ❌ 无 EventKit | **P1** |
| Reminders | list/create/update/complete/delete，EKReminder，含地理围栏 | ❌ | **P1**（与 Calendar 共 EventKitService） |
| Clipboard | get/set/clear/status，文本/URL/图片 | 只有写（复制按钮） | **P1**（读：系统自带粘贴提示=天然权限 UI；无 usage key） |
| Notification | pending/delivered/settings/schedule/cancel，一次性/重复/action | ✅ MedReminder 底座 | **P1 露出**（Minis 的 action 点击回不到 agent——我们可以回到对话，差异化点） |
| Vision | ocr/barcode/classify/detect(仅矩形)/faces/similarity | ✅ OCRStore/BookOCRIndexer | **P1 露出** ocr_image（顺手修它家的 EXIF 方向坑） |
| Open | 打开 URL/scheme/settings 页 | ⚠️ **MP 无注册 URL scheme**（`docs/minis对比` L1 grep 实锤 0 个；app 内导航≠深链）| **P1 露出**（只开 http(s)/settings；`mp://` 等对比线 C4 URL spec 落地） |
| Device | info/battery/storage | 琐碎 | **P1 露出**（system 类，不进权限页） |
| Location | current/geocode/forward，`requestLocation` 一次性 + CLGeocoder，WGS-84 主+GCJ-02 附 | ❌ | **P2**（Maps/Weather 的底座） |
| Maps | search/route/eta，MKLocalSearch/MKDirections，全主线程 | ❌ | **P2**（MapKit 免 key 低难度） |
| Weather | current/hourly/daily/minute/alerts，WeatherKit | ❌ | **P2**（要 `com.apple.developer.weatherkit` entitlement） |
| Photos | list/near/albums/export/import/favorite/delete，PHAsset 全家 | 有 PhotosPicker（用户主动给） | **P2**（「AI 主动翻相册」新语义配三档） |
| HealthKit | 26 子命令含写入（血压 HKCorrelation 等） | ✅ 只读 5 类 | **P2 候选**：扩读类型（HRV/血氧/state-of-mind），写入不做 |
| Alarm | set/timer/list/cancel，**AlarmKit iOS 26+** | ❌ | **P3**（MP 最低 iOS 26 正好够；场景待验证；它家要自建标签库补 AlarmKit 不返 label） |
| NLP | language/tokenize/ner/sentiment/embed | ✅ NaturalLanguage 在用 | **不做工具**（模型自己就是 NLP） |
| Speak/Speech | TTS/转写 | ✅ 语音条/通话全套 | **不做工具**（产品级功能已有） |
| Media/Player | 系统音乐控制/本地播放 | 有声书播放器 | **P3**（共听线定了再说；Player 强依赖它家 UI，移植难度高） |
| HomeKit | list/get/set/scenes | ❌ | **不做**（entitlement + 长生命周期对象图 + 离灵魂远）⧫ 可捞 |
| NFC / Bluetooth | 读卡（含 EMV 银行卡！）/BLE 读写 | ❌ | **不做**（真机+entitlement+协议矩阵重；NFC 读 EMV 敏感） |
| Config/Sessions/ModelUse/FFmpeg/BrowserUse | 它家私有域 | — | 不移植 |

## 三、横切约定（从 scout 档案里抄的，写进 P1 的地基）

- **结果 envelope**：成功 `{ok,tool,action,data}` / 失败 `{ok:false,error:{code,message}}`；工具结果给模型用紧凑文本+关键字段即可，不照抄 JSON 全形
- **授权串行队列**：多个系统授权 sheet 不能同时弹（Calendar/Photos/Media/Speech/Notification 都用串行 queue，HealthKit 还留 0.5s cooldown）——MP 做一个共享的 `SystemAuthQueue`
- **超时必须产生显式 error**：scout 指出它家老代码（EventKit/Photos/HomeKit/Notification）只等 semaphore 不检查，超时被当空结果/成功——MP 统一 timeout→error envelope
- **主线程边界**：UIKit/HomeKit/CoreBluetooth/NFC 在主线程建；可能阻塞 XPC 的 AVAudioSession/Media 刻意 off-main 防 `0x8BADF00D` watchdog
- **日期约定**：接受 ISO 8601 + 相对（`-7d/-2h`）+ 无时区本地；输出设备本地时区 ISO。⚠️ 它家 `--days N` 是"过去 N 天"（反直觉），我们默认窗口**未来 7 天**并显式 past/future
- **重复事件**：`eventIdentifier` 是系列 ID，单次实例靠 `occurrence_date`；删除要指定 span（this/future）
- **iOS 17+ 双 usage key**：`NSCalendarsFullAccessUsageDescription` / `NSRemindersFullAccessUsageDescription`（旧 key 仍要留给旧系统路径；MP 最低 iOS 26 只需新 key，但 macOS 15 路径也要核）

## 四、它家权限模型的四个洞（MP 已天然避开，写下来防退化）

1. 自有开关只比较 shell 第一个 token——`env apple-photos`/`sh -c` 绕过。MP 闸在 tool dispatch 层（tool loop 逐 call）✅
2. Calendar/Reminders 开关不隔离——禁 reminders 仍可经 `apple-calendar reminders` 改提醒。MP：两族**各自的工具**归**各自的域**，不共享入口 ✅ 设计约束
3. NFC/Bluetooth 根本不在权限清单里却可执行（NFC 能读银行卡）。MP：不做这两族；且新工具必须先有域再注册（plan 加检查项）
4. Speech（录麦克风）被标 bypass/无个人数据；Weather 会主动定位却标 system。MP：**凡触发系统授权的都是隐私域**，进权限页

## 五、MP 侧设计要点（进 plan）

- **EventKitService**（共享 EKEventStore + 授权串行 + 超时）→ `calendar_query/create/delete` + `reminders_query/create/complete` 六工具
- **clipboard_read**：文本/URL 回文本；图片→落成聊天附件路径（MP 附件库）；macOS 走 NSPasteboard 分支
- **ocr_image**：输入=附件 id 或文件库路径 → 复用 OCRStore 管线；传 EXIF orientation（修它家坑）；bbox 归一化坐标原点说明写进工具描述
- **notify_schedule**：复用 MedReminder 的 UNUserNotificationCenter 底座；category action 点击 → 深链回对话（它家做不到的）；归「AI 自主行为」区二值域（AI 主动打扰）
- **open_url / device_info**：system 类，永远放行不进权限页（Minis 纪律）
- **权限域新增**：`calendar` / `reminders` / `clipboard`（三档）+ `notifications`（二值，自主行为区）；`forTool` 映射补四族
- **usage keys**：Calendars(FullAccess) / Reminders(FullAccess) 进 `MemoryPalaceIOS-Info.plist`；macOS target 走 `INFOPLIST_KEY_*`；build 产物核验（TCC 流程）
- **双端**：EventKit/UNUserNotificationCenter/Vision macOS 全可用——工具双端生效；Clipboard 分 UIPasteboard/NSPasteboard

## 六、分期（已拍：先弄工具）

- **P1 核心包**：Calendar + Reminders + Clipboard 新做；OCR/通知/开链接/设备信息 露出 → `plan-设备工具.md`
- **P2 外部世界包**：Location + Maps + Weather + Photos 查询 + HealthKit 扩读
- **P3**：Alarm（AlarmKit）/ Media
- **不做**：HomeKit / NFC / Bluetooth / NLP / Speak / Speech（理由见矩阵）
