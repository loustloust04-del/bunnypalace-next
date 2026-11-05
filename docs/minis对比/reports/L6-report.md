# L6 —— 会话对象模型与扩展性对比报告

## TL;DR

| 发现标题 | 差距性质 | 采纳建议 | 代价档位 |
|---|---|---|---|
| 1. MP 应该做「说明型 skills」，但第一版不跑脚本 | 能力缺失 | 改造搬：楼层内 `SKILL.md` + 按需读取 | 天级 |
| 2. OM 的 workspace 是「每会话工作文件区」，MP 缺这层隔离 | 能力缺失 | 改造搬：作为楼层下的会话子目录 | 天级 |
| 3. 楼层比 OM workspace 更适合 MP，不要替换 | 我们更好 | 不建议搬；只澄清两者粒度 | 小时级 |
| 4. MP preset 表达力高于 Soul，普通用户入口还可更简 | 我们更好 | 只借 Soul 的简单编辑表面 | 小时级 |
| 5. OM fork 是整个线性会话拷贝，MP 树内分支明显领先 | 我们更好 | 不建议替换语义 | 小时级 |
| 6. MP 当前没有多设备分支冲突，但也没有多设备会话同步 | 不适用（当前） | 只借思路：先做远程只读 + fork | 架构级 |
| 7. MP 的 MCP OAuth 是配置壳，OM 有完整的交互授权链 | 实现更优 | 改造搬：按 MP 架构原生实现 PKCE | 周级 |
| 8. OM 能按 session 披露 skill/MCP，MP MCP 现在全局生效 | 实现更优 | 改造搬：楼层默认 + 对话覆盖 | 天级 |
| 9. MP 原生 MCP tool 链比 OM 的 shell CLI 中转更紧 | 我们更好 | 不建议倒退；OAuth 接入现有 transport | 小时级 |
| 10. OM 有本地生物识别隐私锁，MP 没有 | 能力缺失 | 改造搬：优先锁楼层，再考虑单对话 | 天级 |

## 证据口径与 escape hatch

- 下文用 `OM/` 代指任务书指定的 OpenMinis clone 根目录，用 `MP/` 代指 MemoryPalace 仓库根目录。
- 任务书把 OM workspace 作为可能与「楼层」对等的抽象；README 也称它是「separate contexts」（`OM/README.md:38-44`）。但源码显示，workspace 的实际粒度是 `Library/MinisChat/minis/<sessionId>/workspace/`，通过 session id 路由到当前 iSH 任务（`OM/src/ios/Agent/Chat/AIChatViewModel+Misc.swift:100-111`；`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:232-236`；`OM/src/ios/Agent/ISH/MinisFsRouter.swift:19-28`）。这不是「人格 + 配置 + 全部历史」容器。
- 因此本报告不强行一对一：「OM workspace vs MP 楼层」拆成两个问题——会话级工作文件隔离是 OM 可学的；用 workspace 取代楼层则不成立。
- 本报告只是静态读码。按红线未 build、未跑测试、未运行 app、未做任何 git 操作。

## 发现

### 1. MP 应该做「说明型 skills」，但第一版不跑脚本

- **OM 怎么做**：`SkillStore` 区分 URL、文件、内置、会话内 agent 创建四种来源（`OM/src/ios/Agent/Session/SkillStore.swift:17-42`）；支持 GitHub URL 预取/commit（`OM/src/ios/Agent/Session/SkillStore.swift:703-765`）和带兄弟资源的 ZIP 导入（`OM/src/ios/Agent/Session/SkillStore.swift:811-874`）。系统 prompt 只放入最多 20 条 name/description/path，再让模型按需读 `SKILL.md`（`OM/src/ios/Agent/Session/SkillStore.swift:1248-1359`），实际请求组装也调用了这段元数据（`OM/src/ios/Agent/Chat/AIChatViewModel.swift:4461-4465`）。README 声称 Claude/Codex/OpenClaw/Hermes skills 通常可直接运行（`OM/README.md:69-79`），但这是项目声称，本 lane 未运行外部 skill 验证兼容性。
- **MP 现状**：无正式 skill 模型/加载器。确认方式：对 `MP/MemoryPalace/**/*.swift` 搜索 `SKILL.md` / `SkillStore` / `struct Skill` / `skillPrompt` / `available_skills`，零命中。邻近资产不等价：preset 是 prompt 槽位与采样参数（`MP/MemoryPalace/Models/Preset.swift:5-77`），MCP 是工具能力（`MP/MemoryPalace/Services/MCP/MCPProvider.swift:26-38`），文件库是按楼层持久文件并通过 `fs_read` 按需读取（`MP/MemoryPalace/Services/FileLibraryTools.swift:3-10`；`MP/MemoryPalace/Services/FileLibraryTools.swift:61-71`）。`RightPanelToolManager` 也只是固定内置工具的启用/排序表，不是第三方插件 API（`MP/MemoryPalace/Models/RightPanelPlugin.swift:16-29`；`MP/MemoryPalace/Models/RightPanelPlugin.swift:107-127`）。
- **差距性质**：能力缺失。
- **采纳建议**：改造搬。**MP 该做 skills**，因为「教 AI 怎么做一类事」不等于「让 AI 怎么说话」，也不等于「给 AI 一个工具」。最小版：每个楼层的文件库下约定 `skills/<slug>/SKILL.md`；YAML 只要 `name` / `description` / 可选 `version`；只把启用 skill 的 name/description/path 加到 prompt；模型匹配任务后用现有 `fs_read` 读正文。可允许 `references/` 和 `assets/`，但 v1 不执行 `scripts/`、不做远程市场、不声称跨 agent 全兼容。文件库已有 profile 根目录、防路径越界解析和文本/二进制扩展名白名单（`MP/MemoryPalace/Services/FileLibraryStore.swift:106-110`；`MP/MemoryPalace/Services/FileLibraryStore.swift:162-172`；`MP/MemoryPalace/Services/FileLibraryStore.swift:634-659`）。
- **代价档位**：天级（限上述说明型 MVP）。
- **风险与前置**：先定 skill 是楼层级还是全局级；本报告建议楼层级，因为它与人格、文件、记忆语境一致。还要限制元数据数量/长度、显式启停、展示指令来源。任务书明确 MP 没有 OM 式本地沙箱，不得把 CC 桥当 skill 执行器（`MP/docs/prompts/2026-08-24-minis-compare/L6-session-extensibility.md:38-40`）。

### 2. OM workspace 值得学的是「每会话工作文件隔离」

- **OM 怎么做**：每个 session 都有独立 `workspace`、`attachments`、`offloads`、`browser` 宿主目录；guest 中却始终看到统一的 `/var/minis/workspace/`（`OM/src/ios/Agent/Chat/AIChatViewModel+Misc.swift:100-120`）。`MinisFsRouter` 用 session 的 fs-context 把 guest path 改写到 `<sid>/<bucket>`（`OM/src/ios/Agent/ISH/MinisFsRouter.swift:30-53`；`OM/src/ios/Agent/ISH/MinisFsRouter.swift:81-110`）；workspace 文件也会以 `SessionFile` 单独加入 iCloud 同步队列（`OM/src/ios/Agent/Chat/ChatStore.swift:4331-4377`）。
- **MP 现状**：通用文件库根只接收 `profileId`（`MP/MemoryPalace/Services/FileLibraryStore.swift:106-110`），工具执行器也只传 `profileId`（`MP/MemoryPalace/Services/FileLibraryTools.swift:42-71`），所以同一楼层的多个对话共享同一个通用文件空间。这对「长期文件库」是特性，但对 agent 生成的中间数据、脚本文本、一次性结果是缺少会话边界。
- **差距性质**：能力缺失。
- **采纳建议**：改造搬。不新建一套「workspace 管理器」；在现有楼层文件库下加会话子命名空间，例如 `workspace/<conversationId>/`，让工具默认在当前对话工作区内读写；用户明确要跨对话复用时，再移入楼层共享区。
- **代价档位**：天级。
- **风险与前置**：要先定清对话删除时 workspace 是否同删、导出/备份是否包含、复制整棵对话树时如何处理。不应把现有楼层共享文件默认搬进会话私有区，否则会破坏长期记忆/资料的跨对话价值。

### 3. MP 楼层比 OM workspace 更适合 MP，不要替换

- **OM 怎么做**：OM 的 `ChatSession` 把会话历史与 model/category/folder/pin 等简短元数据绑在一起（`OM/src/ios/Agent/Chat/ChatStore.swift:41-64`）；workspace 是该 session 的文件桶（`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:232-236`）。Soul 仍是全局 `SOUL.md`（`OM/src/ios/Agent/Session/SoulStore.swift:136-142`；`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:265-269`），skills 目录也跨 session 共享（`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:271-275`），skill/MCP 为全局库另加 session enable override（`OM/src/ios/Agent/Session/SkillStore.swift:146-151`；`OM/src/ios/Agent/Session/MCPStore.swift:201-210`）。
- **MP 现状**：一个 `Profile` 同时绑定楼层名称、用户/助手名、system prompt、偏好模型、preset 以及个人语境字段（`MP/MemoryPalace/MemoryPalaceApp.swift:6-29`）。Conversation 用 `profileId` 归属楼层（`MP/MemoryPalace/Models/Conversation.swift:14-23`），WorldBook 还能选择对整个楼层或某个对话生效（`MP/MemoryPalace/Models/WorldBook.swift:100-110`），文件库也按楼层建根（`MP/MemoryPalace/Services/FileLibraryStore.swift:106-140`）。数据库上是一个 app-lifetime 固定的 `ModelContainer`，靠 `profileId` predicate 分租户（`MP/MemoryPalace/MemoryPalaceApp.swift:113-127`）。
- **差距性质**：我们更好。
- **采纳建议**：不建议用 OM workspace 取代楼层。对 MP 来说，楼层是「一个长期关系/主题上下文」，workspace 只是「某次会话的工作文件」。只借 OM 的会话子目录，放在楼层之下。统一库让切楼层不需重建 container，也为将来跨楼层统计/备份留了空间；代价是所有读写都必须带 `profileId`，这项约束在当前代码中已被明写（`MP/MemoryPalace/MemoryPalaceApp.swift:119-122`）。
- **代价档位**：小时级（只需命名/文档澄清）。
- **风险与前置**：楼层边界并未自动覆盖全部服务；MCP 目前就是全局生效（见发现 8）。以后新增任何记忆/文件/工具能力时，都要先回答「它属于全局、楼层还是对话」。

### 4. Soul 更简，但 MP preset 的表达力明显更强

- **OM 怎么做**：Soul 是一份全局 `SOUL.md`：frontmatter 只有 name/emoji/style/lang，正文是人格文本（`OM/src/ios/Agent/Session/SoulStore.swift:4-47`）。设置页对普通用户只暴露 Name、Style、Language 和一个 Personality Prompt 编辑器（`OM/src/ios/Views/Settings/SoulSettingsView.swift:32-62`）。prompt 组装时，app 用固定身份模板填 name，再追加 body 与 style（`OM/src/ios/Agent/Session/SoulStore.swift:379-450`；`OM/src/ios/Agent/Session/SoulStore.swift:453-487`）。
- **MP 现状**：`PromptSlot` 支持 role、启停、marker、注入深度、排序和禁止覆盖（`MP/MemoryPalace/Models/Preset.swift:5-35`）；默认骨架已组合用户描述、世界书、助手设定、时间轴、用户画像、记忆、摘要、历史等源（`MP/MemoryPalace/Models/Preset.swift:82-112`）。实际组装会按 order/depth 放置段落（`MP/MemoryPalace/Services/PromptAssembler.swift:118-141`；`MP/MemoryPalace/Services/PromptAssembler.swift:407-446`），并统一通过 `{{user}}` / `{{char}}` 宏从 profile 取用户与助手名（`MP/MemoryPalace/Services/PromptAssembler.swift:564-567`）。UI 默认是 `simple`，但同时提供插槽/JSON/组装/请求高级视图（`MP/MemoryPalace/Views/PersonaSettingsTab.swift:20-27`；`MP/MemoryPalace/Views/PersonaSettingsTab.swift:189-250`），简单模式只编辑五个高层字段（`MP/MemoryPalace/Views/PersonaSettingsTab.swift:801-819`）。
- **差距性质**：我们更好。
- **采纳建议**：只借思路，不替换引擎。MP 的表达力胜出，而且记忆/用户画像/时间轴/文件库都真的在用这个槽位系统，所以引擎层不算过度设计。对普通用户过度的是五个并列模式都在首屏可见；可学 Soul 的单页表面，保留「简单」为默认，把插槽/JSON/组装/请求收进一个「高级」入口。任务书明确不再发展角色卡/RP，因此只保留历史兼容，不以 Soul 对比为理由扩张该方向（`MP/docs/prompts/2026-08-24-minis-compare/L6-session-extensibility.md:31-34`）。
- **代价档位**：小时级（只改信息层级，不改组装引擎）。
- **风险与前置**：不能让高级用户失去请求真值预览；只是收起来，不删除。OM 的固定 fallback `Minis` 和固定身份句也不应搬（`OM/src/ios/Agent/Session/SoulStore.swift:388-423`），MP 继续用 profile 变量与宏。

### 5. OM fork 是整个线性会话拷贝，MP 树内分支明显领先

- **OM 怎么做**：`RawMessage` 只有 session id、role、parts 和 sort order，没有 parent/children 关系（`OM/src/ios/Agent/Chat/ChatStore.swift:360-374`）。远程 fork 先建一个新本地 session，再按顺序为远程每条 message 换新 id 并 append（`OM/src/ios/Agent/Session/SessionForkManager.swift:14-53`）；本地 duplicate 也是新 session + 线性 message copy（`OM/src/ios/Agent/Session/SessionForkManager.swift:56-94`）。该管理器的 fork API 只接收 session/device id，没有「从某条 message 开树内兄弟」的参数或 merge/compare 入口；我还搜了全 iOS 调用点，均只调这两个整会话 API。
- **MP 现状**：`MessageNode` 保存 `parentId` + `childrenIds`（`MP/MemoryPalace/Models/Conversation.swift:94-114`）。重新生成会把新 assistant 挂成旧回复的 sibling（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:3336-3388`），编辑重发会把新 user 挂成原 user 的 sibling（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:3433-3474`）。`rebuildPath` 依 branch choice 走树，且把不可见 system/tool 分叉冒泡到最近可见气泡（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:1009-1068`）；气泡 UI 会列出并切换兄弟分支（`MP/MemoryPalace/Views/CardFlowView.swift:3465-3513`）。就连「复制对话」也会重映射全部 parent/children，保留整棵树（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:3636-3682`）。
- **差距性质**：我们更好。
- **采纳建议**：不建议用 OM fork 替代 MP 分支。OM 的「fork 成独立会话」可以日后成为一个可选便利功能（从当前 path 复制到新对话），但不是对 MP 树语义的升级。OM 未展示分支合并或分支对比优势。
- **代价档位**：小时级（结论是保持现状；若另加 path-to-new-chat 则是天级）。
- **风险与前置**：MP 的优势同时是复杂度。树修复、软删除不断链、附件引用和主路径都要随复制/导出持续验证；本 lane 没有运行这些流程。

### 6. OM 的「锁」不是编辑锁；多设备分支问题在 MP 目前尚未发生

- **OM 怎么做**：`SessionLockStore` 是每会话的生物识别隐私锁，状态放 UserDefaults/内存，明确不进同步与导出（`OM/src/ios/Agent/Session/SessionLockStore.swift:5-20`）；它不是并发编辑锁。OM 的多设备会话策略是把 remote session 标记为只读（`OM/src/ios/Agent/Chat/ChatStore.swift:50-58`），要继续就 deep-copy 成本地 session（`OM/src/ios/Agent/Session/SessionForkManager.swift:14-53`）。
- **MP 现状**：SwiftData 配置明确把 `cloudKitDatabase` 设为 `.none`，数据库只在本地（`MP/MemoryPalace/MemoryPalaceApp.swift:185-200`）。所以当前没有「两台设备同时往一个 parent 加 child」的运行时冲突，但也没有会话树的多设备同步能力。本地树已能从 `parentId` 反向补齐不完整 `childrenIds`（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:790-802`），这是未来合并的好基础，但不是多设备冲突协议。
- **差距性质**：不适用（当前）。
- **采纳建议**：只借思路。如果 MP 将来做会话多设备同步，第一版先学 OM 的「远程只读快照 + fork 到本地」，不要直接对整棵树做 last-write-wins。**推断**：若未来直接同步可变 `childrenIds` 数组，同时添加 sibling 可能丢失其中一边；应以每个 MessageNode 的稳定 id + `parentId` 作为可合并真值，再派生 children map。
- **代价档位**：架构级。
- **风险与前置**：前置是粟粟先拍板「是否要同步 20 万+节点数据库」。需要单独定义节点 tombstone、当前主路径、附件、跨楼层隔离和冲突 UI；这些都不能从 OM 的线性 session fork 直接得到答案。

### 7. MP 的 MCP OAuth 现在是「配置壳」，OM 有真正授权会话

- **OM 怎么做**：OM 把非秘密 OAuth 配置（client id、授权/token endpoint、scope、redirect URI）与秘密分开（`OM/src/ios/Agent/Session/MCPOAuthController.swift:37-50`）；client secret 和 token 按设计进本地、不同步的 Keychain（`OM/src/ios/Agent/Session/MCPOAuthController.swift:16-25`；`OM/src/ios/Agent/Session/MCPOAuthController.swift:90-150`；`OM/src/ios/Agent/Session/MCPOAuthController.swift:175-203`）。`authorize` 实现 PKCE S256 + state，支持 localhost loopback 或 custom scheme 回调，然后交换 access/refresh token（`OM/src/ios/Agent/Session/MCPOAuthController.swift:269-345`；`OM/src/ios/Agent/Session/MCPOAuthController.swift:347-385`）。它目前只实现用户提供 client 配置的 static mode，dynamic discovery/DCR 仍保留未做（`OM/src/ios/Agent/Session/MCPOAuthController.swift:37-42`）。
- **MP 现状**：`MCPServerConfig` 与编辑页已有 `oauthClientId` / `oauthClientSecret` 字段（`MP/MemoryPalace/Services/MCP/MCPModels.swift:122-164`；`MP/MemoryPalace/Views/MCPSettingsView.swift:472-476`），secret 与 headers 也会清洗进 Keychain（`MP/MemoryPalace/Services/MCP/MCPProvider.swift:320-370`）。但 transport factory 只消费 URL + headers，完全不读这两个 OAuth 字段（`MP/MemoryPalace/Services/MCP/MCPTransport.swift:12-20`）。确认方式：全 MP Swift 搜索两字段，命中只在模型、设置表单、增删改和持久化；未找到授权 URL、PKCE/state、token exchange、refresh 或把 token 注入 transport 的路径。
- **差距性质**：实现更优。
- **采纳建议**：改造搬，按 MP 架构原生实现，不逐字搬 OM。第一步完成 provider-configured static PKCE：授权/token endpoint + scope + redirect；secret/token 继续进现有 Keychain；为 iOS 和 macOS 分别封装回调；连接前取有效 token 组 Authorization header，401/过期走单飞 refresh。再把 discovery/DCR 作为第二期，不把 OM static mode 误宣称为全部 MCP OAuth。
- **代价档位**：周级。
- **风险与前置**：回调 scheme/loopback、Keychain access group、多窗口 presentation anchor、refresh token rotation、同一 server 并发 401 都要先定义。在真流程实现前，当前「OAuth ID/Secret」UI 会让人以为配好就能授权；应暂时标注未支持或隐藏。

### 8. OM 的 session override 值得改造成 MP 的「楼层默认 + 对话覆盖」

- **OM 怎么做**：SkillStore 和 MCPStore 都有 `(session_id, item_id, is_enabled)` 覆盖表（`OM/src/ios/Agent/Session/SkillStore.swift:134-151`；`OM/src/ios/Agent/Session/MCPStore.swift:201-210`）。skill 的 session 选择先看 override，再回落全局启用值（`OM/src/ios/Agent/Session/SkillStore.swift:1150-1169`）；MCP 同样先解析 session override，再用它筛当前 session 的 prompt server 列表（`OM/src/ios/Agent/Session/MCPStore.swift:582-599`；`OM/src/ios/Agent/Session/MCPStore.swift:601-639`）。
- **MP 现状**：`Conversation.mcpServerIds` 字段还在，但注释明确表示「MCP 已改全局生效，字段保留不再读」（`MP/MemoryPalace/Models/Conversation.swift:72-73`）。真实发送路径也忽略 conversation，直接取 `MCPProvider.shared.activeServerIds`（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:2354-2365`），`activeServerIds` 就是所有全局 enabled server（`MP/MemoryPalace/Services/MCP/MCPProvider.swift:34-38`）。
- **差距性质**：实现更优。
- **采纳建议**：改造搬，但映射到 MP 的三层语义：全局「已安装/可用」；楼层「默认暴露哪些」；单对话「临时加/减」。skills 若实现也复用同一个作用域规则。不建议只复活旧 `mcpServerIds` 数组；先定义楼层默认和 override 的回落规则，再实现一个统一 capability policy。
- **代价档位**：天级。
- **风险与前置**：OM 当前可确认的是「prompt 披露层」使用 override；本 lane 未确认 guest `minis-mcp-cli` 是否会把被禁 server 做成强访问控制。MP 不应把「没把 tool schema 给模型」误当安全边界；调度器/执行器也必须按同一 policy 拒绝越权调用。迁移时现有用户的全局 enabled 集合应成为所有旧楼层的默认集合，避免升级后工具突然消失。

### 9. MP 原生 MCP tool 链比 OM 的 shell CLI 中转更紧

- **OM 怎么做**：MCPStore 向 system prompt 放入最多 20 个 server 名/note，然后教模型运行 `minis-mcp-cli tools/call`（`OM/src/ios/Agent/Session/MCPStore.swift:601-639`）。这与 OM 「给 agent 一台 iSH 电脑」的架构一致。
- **MP 现状**：`MCPProvider.connect` 直接根据 server config 建 transport/client、initialize，再 refresh tools（`MP/MemoryPalace/Services/MCP/MCPProvider.swift:138-169`）。发送前直接把工具渲染成 Anthropic/OpenAI 原生 schema；MCP 工具数超过 16 时改用三个元工具搜索/检查/调用，避免 schema 淹没上下文（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:2337-2381`）。
- **差距性质**：我们更好。
- **采纳建议**：不建议倒退为 shell CLI 中转。发现 7 的 OAuth 应服务现有 native transport：连接前取 token、请求时加 header、过期时 refresh，不应为了学 OM 另建 guest bridge。
- **代价档位**：小时级（作为 OAuth 设计约束，不需单独改实现）。
- **风险与前置**：原生链对 token 刷新的 actor/并发归属要求更高，不能让多个 heartbeat/tool call 同时 refresh。当前的 16 工具阈值是静态策略，本 lane 未测量它对不同模型的最优性。

### 10. OM 的生物识别隐私锁值得做，但在 MP 应先锁楼层

- **OM 怎么做**：用户可为单 session 持久一个锁标记，成功验证时只在内存记录 unlock timestamp，并按 idle timeout 重锁（`OM/src/ios/Agent/Session/SessionLockStore.swift:64-84`；`OM/src/ios/Agent/Session/SessionLockStore.swift:117-151`）。实际聊天界面会用材质层盖住内容、模糊标题，并用 LocalAuthentication 解锁（`OM/src/ios/Views/Chat/AIChatView.swift:5473-5519`；`OM/src/ios/Views/Chat/AIChatView.swift:5523-5546`）。底层使用 `.deviceOwnerAuthentication`，因此生物识别失败时由系统管理密码回落（`OM/src/ios/Agent/Session/SessionLockStore.swift:476-504`）。
- **MP 现状**：无 app/楼层/对话级 LocalAuthentication 门禁。确认方式：全 `MP/MemoryPalace/**/*.swift` 搜索 `LocalAuthentication` / `LAContext` / `biometric` / `Face ID` / `Touch ID` / `lockedSession`，除贴纸画布的「锁定图层」业务外无命中。
- **差距性质**：能力缺失。
- **采纳建议**：改造搬。MP 的用户心智边界是楼层，所以 v1 先支持「锁整个楼层」：侧栏隐藏/模糊楼层名和预览，进入后才解锁，进后台按设定重锁。只有真的出现「同一楼层里某个对话特别敏感」需求时，再加单对话 override。
- **代价档位**：天级。
- **风险与前置**：这只是 UI 隐私门，不是数据库加密。搜索结果、通知预览、widget、备份导出和应用切换器快照都要同时定义隐藏规则，否则只盖住聊天页会留侧漏。

## 核查边界

### Checked and clean

- 已读 OM 六个 `Agent/Session` store 的本 lane 相关完整机制与调用点：SkillStore、SoulStore、SessionForkManager、MCPStore、MCPOAuthController、SessionLockStore。
- 已读 OM workspace 的宿主目录、guest 路由、prompt 及 `SessionFile` 同步路径；没把 README 营销文案单独当作对象模型证据。
- 已读 MP 楼层/ProfileManager、Preset/PromptAssembler、Conversation/MessageNode/ConversationViewModel/CardFlowView、FileLibrary、MCP model/provider/transport/settings、WorldBook/Regex/RightPanelTool 相关上下文。
- 没有找到 OM 的树内分支、fork merge/compare，也没有找到 MP 的正式 skill 模型/加载器。这两项均同时检查了定义与调用点，不是只看一次 grep 命中。

### Not verified

- 未 build、未跑单测/UI 测试，未在真机验证 workspace 路由、生物识别门禁、iCloud sync 或 MCP 连接。
- 未用真实 OAuth MCP server 验证 OM 的 static PKCE，也未验证 token refresh/bridge 的完整端到端行为。
- 未导入并运行 Claude/Codex/OpenClaw/Hermes skill；“通常兼容”保留为 OM README 声称。
- 未验证 MP 未来多设备树合并；报告对 `childrenIds` 冲突的描述已明示标成推断。

## §反向发现

1. **楼层是比 OM workspace 更完整的产品边界。** MP 一个 profile 把名称、用户/助手名、system prompt、模型、preset 绑在长期上下文上（`MP/MemoryPalace/MemoryPalaceApp.swift:6-29`），历史、WorldBook 和文件也都有 profile 边界（`MP/MemoryPalace/Models/Conversation.swift:14-23`；`MP/MemoryPalace/Models/WorldBook.swift:100-110`；`MP/MemoryPalace/Services/FileLibraryStore.swift:106-140`）。OM workspace 则是 session 文件桶（`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:232-236`）。
2. **MP 的 prompt 表达力和人名变量化更强。** Slot 可编程 role/order/depth/marker（`MP/MemoryPalace/Models/Preset.swift:5-35`），组装链用 profile 的用户/助手名展开宏（`MP/MemoryPalace/Services/PromptAssembler.swift:564-567`）。OM Soul 只是全局 identity + style + body，且 fallback 仍固定为 `Minis`（`OM/src/ios/Agent/Session/SoulStore.swift:413-450`）。
3. **MP 的分支是真实的同树兄弟，而且产生、修复、导航、UI 切换和复制都理解这棵树。** 证据分别见 `MP/MemoryPalace/ViewModels/ConversationViewModel.swift:790-859`、`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:1009-1068`、`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:3336-3474`、`MP/MemoryPalace/Views/CardFlowView.swift:3465-3513`、`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:3636-3682`。OM 只复制整个线性 session（`OM/src/ios/Agent/Session/SessionForkManager.swift:14-94`）。
4. **MP 的上下文注入生态已超过单一 Soul 文本。** WorldBook 条目有关键词、选择逻辑、扫描深度、概率和多种注入位置（`MP/MemoryPalace/Models/WorldBook.swift:6-46`），PromptAssembler 会按 before/after/atDepth/author-note 语义放置（`MP/MemoryPalace/Services/PromptAssembler.swift:269-388`）。这些可作为普通的上下文工程资产保留，但不应据此继续扩展 RP/角色卡产品线。
5. **MP 的 MCP 不是纸面模型，且 native tool 调用路径比 OM 更紧。** Provider 会建 transport/client 并 refresh tools（`MP/MemoryPalace/Services/MCP/MCPProvider.swift:138-169`），实发前直接渲染模型原生 tool schema（`MP/MemoryPalace/ViewModels/ConversationViewModel.swift:2337-2381`）；OM 的 prompt 路径是告诉模型使用 guest CLI（`OM/src/ios/Agent/Session/MCPStore.swift:622-639`）。这是 MP 在本 lane 最明确的架构领先项之一。

## §不建议学

1. **不要在 skills v1 学 OM 的远程递归导入 + 脚本执行。** OM 会从 GitHub 递归下载 `SKILL.md` 同目录文件并写入 rootfs（`OM/src/ios/Agent/Session/SkillStore.swift:735-763`；`OM/src/ios/Agent/Session/SkillStore.swift:1756-1874`），其产品本来就把本地 Linux shell 当核心执行器（`OM/src/ios/Agent/Chat/AIChatViewModel.swift:1771-1805`）。MP 没有这个沙箱，v1 只做指令/引用/资源按需读取；不借 CC 桥执行 skill。
2. **不要用 OM workspace/fork 取代楼层/树内分支。** OM workspace 只是 `<sessionId>/workspace`（`OM/src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift:232-236`），fork 是新建 session 后全量拷贝 message（`OM/src/ios/Agent/Session/SessionForkManager.swift:14-94`）。它们可补「会话工作区」和「远程只读后续写」，但不是 MP 长期上下文与分支浏览的替代品。
3. **不要搬 OM 的 guest OAuth token bridge。** OM 为了让后台 iSH daemon 自行 refresh，会把 access/refresh token 和 client credential 复制到 chmod 600 的 guest 可见 JSON（`OM/src/ios/Agent/Session/MCPOAuthController.swift:16-27`；`OM/src/ios/Agent/Session/MCPOAuthController.swift:227-266`）。MP 的 MCP 是 native transport，应让 token 留在 Keychain/内存，不新增一份明文桥文件。
4. **不要把 OM SessionLockStore 当成数据加密或多设备编辑锁。** 它明确是 UserDefaults + 内存的 UI 门禁，不进 sync/export（`OM/src/ios/Agent/Session/SessionLockStore.swift:5-20`）。MP 可以学它改善窥屏风险，但若目标是静态数据保护或树合并，必须另做威胁模型和协议设计。
