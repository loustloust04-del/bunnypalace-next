# Plan：设置-权限管理页 P1

> ⚠️ **DON'T IMPLEMENT YET** — 等粟粟 ⧫ 批注后按 go 执行。
> 上游：`docs/research-权限管理.md`（08-24 粟粟已拍：方向 A 分期 / 引用层 / P1 上三档 / 改默认值 / 首次引导记着不进 scope / TCC 先修已单独动刀）。
> 批注约定：⧫=粟粟，`<⧫> </⧫>` 内为粟粟标注。

## 0. P1 的边界

**做**：域级读写适配器 + 三档权限模型 + 新「权限」tab（三区）+ 原 tab 行换同款控件 + 默认值收紧迁移 + 系统权限状态区。
**不做**（记着别丢）：拒绝文案深链跳转（P2，先文字指引）· AI 改设置工具与 ConfigSchema 大修（P3）· 首次引导（引导系统的活）· 预算 0 元新装拦（挂引导系统）· Minis 式「配置工具」区（P3 一起）。

## 1. 架构：PermissionCenter（域级读写适配器）

新文件 `MemoryPalace/Services/Permissions/PermissionCenter.swift`：

```swift
enum PermissionDomain: String, CaseIterable {
    // 注入类（AI 能看什么）—— 三档
    case healthApple, healthWeight, healthMeds, healthCycle, healthIntimacy
    case trading, memory, images, fileLibrary, topicBox
    // 工具类（AI 能做什么）—— 三档
    case tools, webSearch, voiceProactive, pocket
    // 自主行为类（后台/远端）—— 二值（askOnce 对无对话语境的后台行为无意义）
    case ccNudge, tradingNightly, agentAutonomy, coRead, agora
}
enum PermissionLevel: Int { case bypass = 0, askOnce = 1, notAllowed = 2 }  // UI：自动允许/每次询问/不允许
```

- **每域一个 descriptor**：显示名 + 一句话说明（Minis 式）+ 档位集（三档 or 二值）+ 读写闭包。**读写闭包封装原有副作用**——这是 verify 挑刺的正解：健康域写 `HealthService.shared.injectionEnabled`（单例缓存）不直写 defaults；预算域走 `GlobalBudgetStore.setEnabled`；远端域闭包里发对应 WS 帧（set_cc_config / trading_watchlist / agent_config_set / agora settings.update，五种帧不新建统一通道，适配器每域封自己的）
- **真相源**：三档域新增 `perm.<domain>` key 存档位；**旧 Bool key 退役为迁移源**（读点全改走 `PermissionCenter`）。二值域不加新 key，适配器直通旧闸
- **迁移**（一次性，启动跑）：旧 key 有显式值 → 开=bypass/关=notAllowed 写入 `perm.*`；无显式值 → 按**旧默认**写入（保老用户行为，见 §4）
- Agent 域的 `wsLoaded` 守卫和 `onAgentStatusResult` 单 closure 问题：closure 升级为多播（`[UUID: closure]` 字典），AgentSettingsTab 与权限页各自注册——这是 P1 里唯一动 `CCBridgeWebSocketClient` 的点

## 2. 三档语义落地

**注入类**：
- bypass = 现状「开」，组装时直接注入
- notAllowed = 不注入；该域的意向协议 hint 同步不下发（health writer/trading 注入等各自的挂点走 `PermissionCenter.allowed()`）
- askOnce = **该对话首次要注入此域时弹卡**问一次（复用问问题 sheet 壳：域名+说明+允许/本次不要，30s 超时=deny），grant 记 per-对话集合（内存+对话字段皆可，推荐 `Conversation.permGrants: [String]` 落库——杀进程重开不重复问）；deny 后本对话此域静默不注入
- 弹卡时机在发送路径，实现为组装前 async 检查——**不阻塞打字，只在点发送且域有数据且未 grant 时弹**

**工具类**：
- bypass/notAllowed 同今日开/关（schema 不下发）
- askOnce = schema 下发，**调用时**挂起弹卡（问问题 pending 状态机同构件，OpenMinis 同款 continuation+超时）；deny → tool result 返回：`permission_denied：用户未允许本次使用「<域>」。可请用户到 设置→权限 调整。`（P1 纯文字，无深链）

**防自授权预埋**：`perm.*` 全家 + `PermissionCenter` 管的 key 在 `ConfigSchema` 里标 `aiWritable: false` 新属性（P1 只加标记字段+把 perm keys 补进 schema；AI 侧强制在 P3 实装）。用户自己的 config 导入导出可带权限配置（用户行为不设防）。

## 3. UI

**新「权限」tab**（第 26 tab，双端；iOS 入口随现有设置页结构）：
- 区 1「AI 能看什么」：注入类 8 行（健康拆 5 行太多→**健康一行进子页**，子页内 5 域各一行；其余各一行）。行=图标+域名+一句话说明+档位 menu（Minis 式下拉）
- 区 2「AI 能做什么」：工具类 4 行（三档）+ 自主行为类 5 行（开关，副文案只写「开了会发生什么」——老规矩）
- 区 3「系统权限」：通知/麦克风/相机/照片/健康/运动 状态行（已允许/已拒绝/未请求，各自 API 可查）+「前往系统设置」；本地网络 iOS 无查询 API → 只留说明行+跳转
- **原 tab 行换控件**（引用层）：原 9 个 tab 里对应行的 Toggle 替换为与权限页同款档位 menu（同一 descriptor 渲染，两处天然同步）；二值域原 tab 不动
- 配色/风格贴现有设置页（List+Section 老模式），不新造视觉

## 4. 默认值收紧（拍板 #4）

改 4 组：`health.inject.weight/meds` 开→**关**、`ccNudgeEnabled` 开→**关**、`trading.nightly.enabled` 开→**关**（`health.injectionEnabled` Apple Health 随健康组一并 开→关，凑整个「健康默认全关」语义；⧫ 不同意就单独说）。
**迁移保护**：改默认前先跑一次性迁移——旧 key **无显式值**的写入旧默认（true），然后代码默认改 false。效果：老用户（含从没动过开关的）行为不变，只有真·新装按新默认。mem_master M0 同款手法。

## 5. 影响范围

- 新增：`Services/Permissions/`（PermissionCenter + descriptors + 迁移）、`Views/PermissionsSettingsTab.swift`（+健康子页）
- 改：ConversationViewModel（注入/工具下发挂点 ~6 处）、ToolRegistry、HealthService、HealthLogStore、TradingStore、MemoryService 挂点、CCBridgeWebSocketClient（closure 多播）、9 个 SettingsTab 的对应行、SettingsView 枚举、ConfigSchema（补 perm keys + aiWritable 字段）
- 不碰：hub 侧 TS（远端域用现有帧）、PromptAssembler 内核、Preset 插槽

## 6. 测试与验收

- 单测：档位存取/迁移矩阵（显式开/显式关/无值 ×新旧默认）/ askOnce grant 幂等 / 拒绝文案 / ConfigSchema perm keys 在册
- 复现器：askOnce 弹卡两路径（注入类发送时/工具类调用时）模拟器实证
- 双端 build + 全套测试绿；装 Air（cwd=master→Air 分流规则）
- 粟粟真机清单（review 里给）：权限页三区看一遍 / 把健康某域调 askOnce 发一句看弹卡 / notAllowed 域确认不注入 / 原 tab 行与权限页同步

## 7. Todo checklist

- [x] T0 PermissionCenter 骨架：Domain/Level + `perm.*` 存取 + 迁移器（老装机判定=库里有对话；sentinel `perm_migrated_v1`）✅
- [x] T1 本地简单域接入 ✅（memory/voiceProactive 按 §2 取舍只两档，askOnce 挂 P2——MemoryService 十几个读点穿 grants 是独立刀）
- [x] T2 单例域接入 ✅（healthApple 组装路径绕缓存 bool 直问 PermissionCenter；setLevel 踢 HealthService 缓存有单测锚）
- [x] T3 远端域适配器 **部分** ✅：nudge/夜跑/agora 真适配器行（sendCCConfig / reportWatchlist 副作用封装）；**agent+共读 = 状态提示+归位设置-Agent**——verify 挑刺过其 WS 补丁机器是 view 私有状态 + 单 closure 顶掉雷，P1 不硬搬，closure 多播挂 P2
- [x] T4 注入路径改造 ✅（assemblePrompt/expandUserMacros/buildAPIMessages/topicBox/trading hint 全走 grants；sendMessage 步骤4-6 Task 化前置弹卡；regenerate/editAndResend 不弹卡=未答域安全不注入，记 review）
- [x] T5 工具路径改造 ✅（tool loop 逐 call 闸：notAllowed 拒/askOnce 弹卡；ask_user 工具自身豁免；permission_denied 文案带设置指引）
- [x] T6 权限 tab 三区 UI ✅（健康子页/系统权限状态行/macOS 给定高防塌 0）
- [x] T7 原 tab 行替换 ✅（健康5/交易1/MCP1/附件图片1/文件库2/记忆2/朗读1/CC pocket1/API webSearch1 = 全部写路径归 PermissionCenter.setLevel）
- [x] T8 默认值收紧迁移 ✅（§4 四组+声明默认同步翻）
- [x] T9 ConfigSchema ✅（perm.* 14 键入册 + aiWritable 标记；"71 个"死数注释改活口径）
- [ ] T10 单测全套 + 复现器两路径实证（PermissionCenterTests 已写，跑全套中）
- [ ] T11 双端 build 绿 + 装机（worktree cwd→iPhone 14 分流）+ review-权限管理.md + 更新 NOW.md
