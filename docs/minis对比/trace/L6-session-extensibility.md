# L6 —— 会话对象模型与扩展性：skills、人格、工作区、分叉

先读 `COMMON.md`（同目录）。本文件只写这条 lane 独有的东西。

## 这条轴问什么

**「一个会话」到底是什么对象，以及用户和第三方能往里塞什么。**

OM 的 `Agent/Session/` 六个 store 很能说明它的对象模型：SkillStore（技能）、SoulStore（人格？）、MCPStore、SessionForkManager（分叉）、SessionLockStore（锁）、MCPOAuthController。
MP 在这条轴上**有厚资产**（楼层系统、preset 插槽、角色卡、对话树分支、MCP），所以这条 lane 特别要注意：**不要写成单向自卑清单**。很可能 MP 在几处是领先的。

## OM 侧读什么（`src/ios/Agent/Session/`）

- `SkillStore.swift` —— **skills 系统**。README 说：一个 skill = 一个带 `SKILL.md` 的文件夹（指令 + 可选脚本/引用/资源），按需加载；元数据常驻上下文用于触发，正文和资源用到才加载。**且声称兼容为 Claude / Codex / OpenClaw / Hermes 写的 skills**。
  重点：加载/触发机制、元数据与正文的分离、skill 从哪来（用户装？内置？远程仓库？）。
- `SoulStore.swift` —— 先搞清 Soul 是什么（人格？系统提示？角色？），再和 MP 的角色卡 / preset 对照。
- `SessionForkManager.swift` —— **分叉**。这条对 MP 极重要：MP 的核心资产之一就是对话树 + 分支冒泡。**看清 OM 的分叉是「从某条消息开新会话」还是「树内分支」**——这两者是不同的产品语义。
- `MCPStore.swift` + `MCPOAuthController.swift` —— MCP 接入与 OAuth（**MCP server 的 OAuth**，MP 可能没有这块）。
- `SessionLockStore.swift` —— 锁（和 L2 同步轴有交集，你侧重会话语义那面即可）。
- 另外看 **workspaces**：README 说「Organise work into separate contexts, addressable via `minis://workspace/`」。去代码里找 workspace 的实现（可能在 `Shared/` 或 `Agent/Chat/ChatStore.swift`），搞清它和 session 的关系。

## MP 侧对照坐标

- **楼层系统**：`ProfileManager`，每楼层独立配置，统一 ModelContainer + profileId predicate 做多租户。这是 MP 的「工作区」对等物。
- **Preset 插槽**：酒馆式 prompt 组装，`PromptSlot` + `SamplingParams` + `PromptAssembler`。
- **角色卡**：`Models/CharacterCard.swift`。
- **对话树**：分支冒泡 + `effectiveChildrenMap` + 后台线程加载。`Models/Conversation.swift`、MessageNode 相关。
- **World Book / Regex 脚本**：`Models/WorldBook.swift`、`GlobalWorldBook.swift`、`RegexScript.swift`——酒馆生态那一套 MP 是有的。
- **右侧面板插件**：`Models/RightPanelPlugin.swift`。

## 车头给的额外情报（你查不到的）

1. **MP 有一条明确的产品红线：不做角色卡 / RP 相关的一切**（在「不做清单」里）。角色卡代码存在是历史资产，但**不要给出扩展 RP 方向的建议**。
2. **MP 的分支树是真实资产也是真实复杂度**。它比「fork 出新会话」重——MP 的分支是同一棵树内的兄弟节点，UI 上能在气泡上左右切分支。
   → 判断 OM 的 fork 时请对照这个：**如果 OM 只是「复制历史开新会话」，那 MP 是领先的**，该写进 §反向发现；如果 OM 有 MP 没有的东西（比如 fork 的合并、比较），那是可学的。
3. **MP 的 skills 现状 = 无**。但 MP 有几个相邻物：preset 插槽（prompt 层的组装）、MCP 工具（能力层）、文件库（资源层）、`RightPanelPlugin`。
   → 关键判断：**MP 该不该有 skills？** 注意 MP 是陪伴型产品，用户是粟粟这样的人 + 未来的普通用户。skills 的价值在「让 AI 会干某类活」，这和 MP 的「让 AI 记住你、按你要的方式说话」是不是一回事？这个问题请正面回答，别绕。
4. **MP 有一条铁律**：app 自己的文件库/记忆**永不**借 CC 桥让本地 CC 读写——「cc 是 cc，自己的文件是自己的文件」，工具循环建在 app 内。
   → 如果你的 skills 建议涉及「让 skill 跑脚本」，注意 MP 没有本地沙箱（OM 有 iSH），别顺手把 CC 桥当执行器。
5. **`SoulStore` 对照时注意**：MP 有一条硬约束——UI 字符串和 LLM prompt **禁止硬编码 AI/用户名和人称代词**（她/他），一律变量或 `{{user}}` / `{{char}}` 宏，fallback 用中性词。看 OM 怎么处理这块。
6. MP 的 MCP 已经跑起来了（app 内 MCP 客户端 + 本机 mcp-server），有实测教训：MCP server 的 SSE transport 曾因 `AsyncLineSequence` 吞空行 / Swift 里 `\r\n` 是单 grapheme 而连不上——**这些是传输层的，不在本 lane**，提一句是让你知道 MP 的 MCP 不是纸面功能。你重点看 OM 的 `MCPOAuthController`：**MCP server 的 OAuth 授权** MP 大概率没有，这可能是一条干净的可采纳项。

## 特别要回答的

1. **Skills：MP 该不该做**。正面回答 + 理由。如果该做，最小可用形态是什么（能不能就是「文件夹 + SKILL.md + 按需加载」，复用 MP 现有的文件库）？如果不该做，说清 MP 的哪个现有机制已经覆盖了它的价值。
2. Workspace（OM）vs 楼层（MP）：**哪个抽象更好**？各自把什么绑在了一起（数据？配置？人格？历史？）。MP 的楼层是「统一库 + profileId 谓词」，这个选择有没有让 MP 更灵活或更受限？
3. Soul（OM）vs preset 插槽 + 角色卡（MP）：谁的表达力强？MP 的酒馆式插槽是不是过度设计了（对普通用户）？
4. Fork（OM）vs 分支树（MP）：给明确判断，谁更好，以及**MP 的分支树有没有 OM 那种「锁 / 多设备」维度没考虑到的问题**。
5. `MCPOAuthController`：MP 缺不缺这块？缺的话代价档位。
