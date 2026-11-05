# Research：设置-权限管理页

> 2026-08-23 · 粟粟 `/orchestration 权限管理` 发车。三路只读侦察（codex×2 代码轴 + kimi k3 文档轴）+ 车头抽查行号 + OpenMinis 源码亲读。
> 原始报告：`docs/prompts/2026-08-23-perm-research/reports/{A,B,C}.log`；参考拆解：同目录 `reference-minis.md` / `reference-openminis.md`。
> **状态：✅ 2026-08-24 粟粟已拍板（方向A分期 / 引用层 / P1上三档 / 改默认 / 加引导记着 / TCC先修）。下一步：plan。**

## 一、粟粟要什么（参考坐标系）

「就像 Minis app 那样」= 一页横切「AI 能碰什么」：

1. **两层**：代理对设置本身的读写权（配置工具区）≠ 代理对数据域的访问权（隐私区），分开管
2. **每行 = 域 + 一句话说明 + 档位下拉**，不是裸 toggle。OpenMinis 源码实证三档：`Bypass / Ask Once / Not Allowed`
3. **拒绝语义显式**：AI 被拒时收到 `permission_denied` + 跳设置的深链，能在聊天里引导用户去开；Ask Once = 按会话授权，弹卡 30s 超时自动拒
4. 设置页只露隐私敏感域（media/system 类永远放行不进页面）——防膨胀
5. 防自授权：权限开关本身在 AI 可写面之外（OpenMinis 用隐藏占位符，AI 翻它一律 `permission_denied`）

license 口径（粟粟拍）：OpenMinis GPL-3 可对照写；注意 mneme-atrium 是 AGPL-3+Commons Clause，逐字搬的文件需豁免出 Commons Clause，按 MP 域重写则无事。

## 二、现状全景（三轴侦察结论）

### 2a. 散闸清单：权限语义的开关约 40+，散在 9 个设置 tab + 面板 + 无 UI

按「AI 能碰什么」归类（完整表在 reports/A.log，此处为权限页候选域）：

| 域 | 现有闸（key） | 默认 | 现在住哪 |
|---|---|---|---|
| 健康-Apple Health | `health.injectionEnabled` | 开 | 设置-健康 |
| 健康-体重/吃药 | `health.inject.weight/meds` | 开（粟粟拍板的有意默认） | 设置-健康 |
| 健康-月经 | `health.inject.cycle` | 关 | 设置-健康 |
| 健康-亲密 | `health.show.intimacy` + `health.inject.intimacy` 双轴 | 关/关 | 设置-健康 |
| 交易（关注+持仓+开仓理由+最近平仓） | `trading.inject.watchlist`（key 名窄于实际范围） | 关 | 设置-交易 |
| 记忆注入 | `mem_master` + 内容类 `mem_content_*` 一族 | 开 | 设置-记忆 |
| 图片上下文 | `sendImagesToModel` / `imageTranscriptionEnabled` | 开/开 | 设置-附件 |
| 文件库 | `fileLibraryEnabled`（连坐 `update_profile_card` 等 fs 工具） | 开 | 设置-文件库 |
| 话题盒 | `topicBoxInjectionEnabled` | 开 | 设置-文件库 |
| 工具总开关 | `sendToolsEnabled`（关=请求不带 tools） | 开 | 设置-MCP 顶部 |
| MCP server/单工具 | `MCPServerConfig.enabled` / `tools[].enabled` | 新增默认开 | 设置-MCP |
| 联网搜索 | `webSearchEnabled` + backend + 黑名单 | 关 | 设置-API |
| 语音条协议 | `voice_proactive_enabled` | 关 | 设置-朗读 |
| CC 遥控浏览器 | `pocketEnabled`（开页/执行 JS/截图/读 DOM，权限性质最强） | 关 | 设置-Claude Code |
| CC 主动找我 | `ccNudgeEnabled` | 开 | 设置-Claude Code |
| Agent 自主任务 | hub `enabled` + 楼层 + `dailyBudgetUSD` + `pausedUntil` | 关/$0.50 | 设置-Agent |
| 共读三闸 | `coRead.daemon/cc/vocab` | 关×3 | 设置-Agent |
| 群聊发言 | `agoraEnabled` + `speech_mode` 四档（仅@/接力/自由/轮流） | 关/仅@ | 开发调试+群聊 |
| 交易夜跑 | 夜跑开关+间隔+上限 | 开 | 设置-交易 |

侦察抓到的结构性问题（权限页要顺手解的）：

- **可疑叠加对 ×3**：`mem_inject_full` 开着时开 keyword/vector 是叠加不是切换（「我已切智能检索」错觉）；`health.injectionEnabled` 名字像总闸实际只管 Apple Health；LAN/Tailscale 双绑定是并列监听不是二选一
- **默认值需产品确认**：`globalBudgetEnabled=true`+额度 0（新装用户全拦——注释明说是「防烧 key」有意保险闸，但新装体验=首发被拦）；`ccNudgeEnabled`/交易夜跑默认开（主动后台行为）；MCP 新 server/新工具默认全开
- **无 UI 但生效的闸**：`fileLibraryFullContent`（有效回滚闸无 UI 且不在 ConfigSchema）；Regex/世界书多个字段只能随导入进入
- **UI 有但语义空**：`mem_inject_tag`/`mem_content_filehistory`/`mem_infra_gateway` 灰行无消费点；`ccPushPreview` 整区 `.disabled`；Prompt 页 `squashSystemMessages` 等三件有 UI 无运行时消费
- **文档矛盾 14 组**（reports/C.log）：其中 3 组已对码裁决——`mem_inject_budget` 真默认 **10000**（UI @AppStorage=10000 + 运行时回落 10_000 + 启动迁移删除旧 2000 存档，三层证据；文档 2000 是历史值）、Regex `promptOnly` 死/活（A 已裁：无 `isPrompt:true` 调用方=UI 语义漂移）、Agent 页 iOS 现状（已裁：R5 后 iOS 开放走 WS 补丁）

### 2a+. verify 补漏的 10 个闸（第一轮浓缩表没收进的）

对话级 `memoryEnabled`（该对话不贡献也不接收记忆）· 楼层级 `PromptSlot.isEnabled`（可独立关记忆/画像/世界书等注入 marker）· 世界书三层（整本/单条/scope 对话）· 对话级写作风格 `currentStyleId`（隐藏注入）· `localModeEnabled`+`syncEnabledProfiles`（联网/同步通道，本地模式强制视同步为关）· `fileLibraryICloudEnabled` / `apiKeyCloudSync`（外部同步通道，后者迁移全部 Keychain account）· `backupAutoEnabled`（切后台自主写 iCloud）· `Medication.reminderEnabled`（单药通知，默认开）· `ccHubEnabledByUser`+`ccBindLan/Tailscale`（进程与监听通道）· `ccKeepalivePolicies`（per-session 保暖档）。证据行号在 reports/verify.log。

### 2b. 系统权限面（TCC）：1 个崩溃级雷 + 1 个授权文案风险 + 2 个上架风险，独立于权限页也该修

- 🔴 **Motion 缺 usage key（崩溃级，verify CONFIRMED）**：冷启动无开关守卫调 `ShakeMonitor.start()`（摇一摇），有效 plist 无 `NSMotionUsageDescription`——缺 key 访问 Motion 按 Apple 文档会崩（与朗读 TCC 杀进程同类）
- ⚠️ **LocalNetwork 文案不在 bundle 根 Info.plist（授权文案风险，非崩溃）**：文案写在 project.yml info 段生成的 `Info-iOS.plist`，但 target 显式 `INFOPLIST_FILE: MemoryPalaceIOS-Info.plist`（project.yml:171）——那份文件作为普通资源进包但系统不认，LAN 连 hub 的权限弹窗没有我们的文案
- ~~Speech 缺 key~~ **撤案（verify REFUTED）**：通话用 iOS 26 `SpeechAnalyzer` 端上转写，不走 `SFSpeechRecognizer` 授权契约，且代码先请求了麦克风权限
- ⚠️ 上架：麦克风文案还写「App 不会录音」但通话已真实录音转写；相机 key 两处两套文案——verify 已裁：build setting 的「拍照发送给 AI」覆盖手写 plist 的「扫码配对」
- ⚠️ macOS Documents 直用无文案（拒绝后 `try?` 静默失败）；Family Controls entitlement 残留无代码
- 凭据面：「iCloud Keychain 同步」开关实际重写 service 下**全部** account（CC token/MCP secrets/ElevenLabs 连坐）；MCP OAuth 字段是死 UI；MCP JSON 编辑页明文展示 Keychain 回填的 secret

### 2c. config 现状（粟粟点名问的）

MP 的 config = **用户手动导入导出设置 JSON**（plan-settings-config，C-D1~D3 拍的是 JSON/不含 Keychain/全替换——但 verify 对码：实现实际是**只覆盖出现字段的 patch/merge**（ConfigImporter.swift:40-62），与当年拍的「全替换」不符，算一笔实现漂移账），**AI 完全摸不到**——ToolRegistry 无任何工具指向它。Minis 的「配置工具」层（agent 运行时读改设置）在 MP 尚不存在。
地基现成但已锈：`ConfigSchema` 是全部设置 key 的类型化白名单，注释自称 71 key 全量（实际数组已 77 项且仍非全量），漏 `sendToolsEnabled`/`pocketEnabled`/`mem_recall_card`/`mem_recall_feedback`/词汇开关等，`chatBubbleMode` 类型写错。**若做「AI 改设置」，第一刀修 schema，权限 key 列入 AI 不可写黑名单（防自授权）。**

### 2d. 关键背景

- 设置已 25 个 tab——权限页做成第 26 个还是收编重组，是方向决策
- MP 有 ask_user/问问题 pending 状态机（挂起工具循环弹卡收答案）——Ask Once 档的同构件现成
- 279 份文档无一提过权限页 = 纯绿地，无历史承诺

## 三、方向提案（等粟粟拍）

**方向 A · 权限总控页（推荐）**：新「权限」tab，Minis 结构二层：
- 「AI 能看什么」区：上表 19 域收编为**引用层**——权限页的行与原 tab 的开关读写同一 key（不搬家不破坏现有肌肉记忆），行右侧挂档位
- 「AI 能做什么」区：工具总开关/MCP/遥控浏览器/Agent 自主/夜跑/nudge
- 「系统权限」区：通知/麦克风/相机/照片/健康/本地网络的**状态行**（已授权/被拒/未请求）+ 跳系统设置深链
- 三档模型只给「注入类+工具类」域（Bypass=现在的开 / Ask Once=本轮问一次·接问问题状态机 / Not Allowed=不注入且拒绝文案带 `mp://` 深链）；纯展示类不升档
- ⚠️ verify 挑刺（成立）：「纯引用层零行为变化」不可行——健康/交易闸是自建 Binding+tick 非 @AppStorage（外页改值原页不刷新）；`HealthService`/`GlobalBudgetStore` 把值缓存进单例（直写同 key 不改运行态）；一批 setter 带不可省略副作用（Keychain 迁移/hub 进程启停/五种互不统一的 WS 帧：set_cc_config/set_bind/agent_config_set/agora settings.update/trading_watchlist）；Agent 的 WS patch 逻辑封在 AgentSettingsTab 私有方法里且 `onAgentStatusResult` 是单 closure，新页注册会顶掉旧页
- 分期（按挑刺修正）：**P1 = 抽「域级读写适配器」**（每域一个入口封装值+副作用，权限页与原 tab 都改走它）+ 系统权限状态行 → P2 三档+拒绝语义 → P3 「AI 改设置」工具（修 ConfigSchema+防自授权，且必须走 P1 适配器不能直写 UserDefaults）

**方向 B · 只做系统权限状态页**：小刀，只有 2b 的状态行+深链。不解决散闸问题。

**方向 C · Minis 全套一步到位**：A 的 P1-P3 一口气。风险：P3 依赖 schema 大修+审计面，步子大。

**独立于方向的顺手账（建议无论选哪个都先修，半天）**：Motion 崩溃雷 + LocalNetwork 文案归位 + 麦克风/相机文案——崩溃/上架级，和权限页解耦。

## 四、决策点（⧫ 区）—— ✅ 2026-08-24 粟粟已拍

1. ✅ **方向 A 分期**
2. ✅ **引用层**（原开关留在原 tab，权限页引用同一 key）
3. ✅ **P1 就上三档**
4. ✅ **改默认值**（体重/吃药/nudge/夜跑的默认值趁收编一起改）
5. ✅ **加首次引导**（属于引导系统的工作，先记着，不在权限页 scope 内）
6. ✅ **先修**（Motion 崩溃雷 + 文案三件，独立小刀不等权限页）

## 五、核查记录

PERM-verify（codex 新实例，对抗姿态）抽查 26 条：20 CONFIRMED / 4 REFUTED（Speech 雷、config 全替换、budget 2000、health「总闸」语义）/ 2 措辞修正（LocalNetwork、Motion「无条件」）；补漏闸 10 个；方向 A 挑刺 5 条全部吸收进 §三。全文剩余未验证项：hub 侧最终默认值与执行效果（app 静态不可判，标注处均已注明）、真机 TCC 复现。原始核查报告 `docs/prompts/2026-08-23-perm-research/reports/verify.log`。
