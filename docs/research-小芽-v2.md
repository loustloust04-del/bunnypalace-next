# Research：小芽 v2 —— 亲善的窗口 + 形象 + 本地大脑 + 放权但要盖章

- 日期：2026-09-26（🎩）
- 前作：`docs/plan-小芽助手.md` / `docs/review-小芽助手.md`（09-10 MVP）
- 设计小稿：`docs/design-小芽-v2.html`（布局三选一、盖章卡、试穿卡、账本、下载卡，全部真渲染）
- 状态：✅ 09-26 粟粟已裁 Q1–Q7（舞台头 / 设计稿 / 换椭圆肖像 / 本地可选 / 外观随我 / 只当表情 / Lily=英文名）→ [plan](plan-小芽-v2.md)

---

## 0. 我的理解（粟粟说的 vs 我补的假设）

| 粟粟说的 | 我的理解 |
|---|---|
| 对话窗口很丑很诡异，要亲善 | 重做 `AssistantPanelView` 的视觉，让它「像在跟一个小人说话」，不是「在用一个工具」 |
| 把二次元形象放进去 | 用这次给的两张图：9 表情印章（小芽本人）+ 9 个花店纹样（装饰）。**她要有表情，而且表情会随状态变** |
| html | **假设**：设计先出 HTML 小稿（设计文档一律 HTML 的老规矩）。另一种读法见 Q2 |
| 最好自动下一个 llama.cpp 或 MLXSwift | 小芽可以不靠楼层 API，用本机小模型跑；模型首次用时自动下载 |
| 所有改动必须人类批准（小模型蠢） | 没有任何写路径绕过批准。现在 MVP 已经是「提案→应用」，保留并加固 |
| 也要放权，比如改外观按钮 | 扩大她**能提案**的范围（不只是角色卡/预设/世界书，还有外观），批准门槛不降，但让批准变得轻松（看得见效果再盖章）+ 批完能撤销 |

⚠️ 消息里写了 [Image #1] [Image #2]，我收到的两张是**形象素材**，没有收到「现在窗口长什么样」的截图。§1 的诊断是读代码得出的；如果你说的「诡异」是某个具体现象（比如双标题栏、键盘顶飞、背景透底），截一张给我。

---

## 1. 现状诊断：为什么丑 / 诡异（`MemoryPalace/Views/Assistant/AssistantPanelView.swift`，210 行）

| 位置 | 现在 | 问题 |
|---|---|---|
| 头部 :41-60 | 28pt 的 `ya3d`（3D 红蘑菇帽+红墨镜）+ 系统字名字 + 「停止」 | 3D 写实小人跟新的墨绿印章风格完全两个世界；28pt 太小，存在感=0 |
| 分段 :30-35 | `header / Divider / list / Divider / input` | 两条横线把屏幕切成三截，工具面板感 |
| 空态 :80-92 | 一张「可以帮你：写角色卡/改预设…」功能清单卡 | 像说明书，不像打招呼 |
| 气泡 :94-114 | 直接借主聊天的 `Theme.userBubble`（白字）/`assistantBubble` | 是主聊天的缩水复刻；她说话和系统说话长一样，没有「她」 |
| 流式 :116-127 | 文字「思考中…」 | 没有任何角色反应 |
| 提案卡 :131-170 | `sidebarBg` 底 + 薄荷描边 + 「应用 / 丢弃」胶囊，detail 是纯文本 | 像系统弹窗；看不出改了什么（没有旧→新对照） |
| 应用后 :55-66（Engine） | 卡片直接消失 | 没有「批了」的反馈，也没法撤销 |
| 输入条 :174-194 | `arrow.up.circle.fill` 26pt | 跟主聊天输入条又不一样，两套都不像 |

一句话：**这个窗口里没有小芽**。只有一张 28pt 的图标，剩下全是通用聊天零件。

---

## 2. 形象素材分析

### 2.1 表情图（9 张）——小芽本人

切好在 `docs/assets/xiaoya-v2/`：`face-*.png`（去掉英文字幕，当表情/立绘用）+ `sticker-*.png`（带字幕，当表情包用）。

- 风格：单色墨绿（≈ #1E3D26）印章 / 丝网感，透明底，贝雷帽 + 小花 + 羽毛
- **单色 = 可以当 template 图随主题染色**（深色模式换成奶白墨），这是很大的便利
- 9 个情绪正好覆盖助手的状态机（见 §4.2 映射表）
- 跟现有 `ya3d`（3D 红蘑菇帽墨镜，Page2 桌面图标 + 面板头像都在用）**风格冲突** → 见 Q3

### 2.2 花店纹样（9 个）——装饰

帽子 / 花押字 L / 椭圆肖像 / 铃兰 / 蝴蝶结 / 靴子 / 马甲 / **椭圆邮戳印** / 五线谱。
- 椭圆邮戳 → **「已批准」盖章**（批准动作的视觉核心）
- 铃兰 / 五线谱 → 空态、分隔、下载卡装饰
- 图里写着 "Lily · The Little Florist · Lily's Atelier"——**名字跟「小芽」冲突**，见 Q7

### 2.3 配色约束（老规矩）

暖奶白纸底 + 墨绿线 + 浅灰薄荷只当一层点缀；**禁止深绿套浅绿**：表情图（深墨绿）只能压在奶白上，不能压在薄荷面上。用户气泡用浅薄荷 + 深色字（允许组合）。

---

## 3. 本地模型：三条路

| | Apple Foundation Models | **MLX Swift LM**（推荐） | llama.cpp |
|---|---|---|---|
| 下载 | 0（系统自带 ~3B） | 首次下载，Qwen3-1.7B-4bit ≈ 1 GB；4B ≈ 2.3 GB | 首次下载 GGUF，体量同左 |
| 平台 | iOS 26+ / **macOS 26+**（我们 mac 目标 15，要 `#available` 包） | iOS 16+ / macOS 14+ Apple silicon ✅ | 全平台 |
| 设备门槛 | 必须支持且**开启 Apple Intelligence**；**国行设备不可用**（地区限制） | A 系芯片有 Metal 即可，内存 8GB+ 舒服 | 同左，还能纯 CPU |
| 模拟器 | 跟宿主 mac 的 AI 状态走 | **跑不了**（MLX 要真 Metal GPU，待验证），只能真机 / mac 测 | 能跑（CPU） |
| 工具调用 | 原生 `Tool` 协议 | `generate` 流里直接吐 `.toolCall`（Qwen3 支持） | 要自己解析 |
| 结构化输出 | `@Generable` 强约束，蠢模型也不会写坏 JSON | 无强约束（靠 prompt + 解析兜底） | GBNF 语法强约束 |
| 中文 | 支持，但偏弱 | Qwen3 中文强 | 同模型 |
| 包体积 | 0 | + MLX metallib 约十几 MB | + xcframework 约十几 MB |
| 接入成本 | 最低 | 低（Swift 包，`loadModelContainer` + 进度回调） | 高（C API 自己包） |

**推荐 MLX Swift LM + Qwen3**：
- 你点名要自动下载，MLX 是纯 Swift 包、下载进度回调现成（`loadModelContainer(from: HubClient…) { progress in … }`），`generate` 流同时出文本和工具调用，改造成本最小
- Foundation Models 的国区 / 设备 / mac 26 三道门槛太多，当主力不稳；接口层留好，以后可以加成「零下载档」
- llama.cpp 唯一胜出点是 GBNF 强约束，但我们用「所有写操作都是提案 + 解析失败=不动作」已经兜住了，不值得多写一层 C 桥

**要验证的点（进 plan 前我自己跑）**：
1. `huggingface.co` 国内直连不通 → `HubClient` 能不能改 host 到 `hf-mirror.com`（或我们自己托管一份到 GitHub Release / 对象存储）
2. iOS 模拟器确实跑不了 MLX → 开发期在 mac 版上测，真机最终验
3. 1.7B 在 iPhone Air 上的首 token 延迟和 tok/s；要不要加 `increased-memory-limit` entitlement
4. Qwen3 的 thinking 模式要关（`/no_think`），不然小模型先絮叨半天
5. 模型文件放 `Application Support/Models/`，标 `isExcludedFromBackup`（1 GB 不能进 iCloud 备份）

**接入形状**：引擎里抽一层 `AssistantBackend`（云端 = 现在的 `ProviderRouter`；本机 = MLX），`AssistantEngine.runRound` 只认这层的事件流（文本块 / 工具调用 / 结束 / 出错）。不把本机模型做成主聊天的 provider——那是另一件事，别铺两摊。

---

## 4. 放权但要盖章：权限模型

### 4.1 三档

| 档 | 例子 | 流程 |
|---|---|---|
| 只读 | 查记忆、读预设、读世界书、看当前外观 | 自动执行，不打扰 |
| 可逆写 | 改预设插槽、建角色卡、改外观、改世界书条目 | **提案卡 → 你盖章 → 落地 → 进账本（可撤销）** |
| 破坏性 | 删世界书条目、覆盖整份预设 | 提案卡 → 盖章 → **再确认一次** → 落地 → 进账本 |

「所有改动必须人类批准」= 可逆写和破坏性两档**没有自动通道**。代码层面：写工具只产出 `AssistantAction`，执行函数只在你点按钮的回调里调，模型没有任何路径能直达（MVP 已是这样，v2 保持）。

### 4.2 放权 = 扩大提案范围 + 让批准变轻松

- **新工具包「外观」**（首批候选，见 Q5）：Page2 壁纸 / 图标外观（默认·透明·着色）/ 明暗 / 大图标 / 单个 app 图标的符号和颜色；她自己窗口的皮肤（纸色 / 墨色 / 表情大小）
- **试穿预览**：外观类提案卡里直接渲染「改前 / 改后」小样，用**真实的** `Page2WallpaperView` 渲染（预览必须复用真实路径），你看到效果再盖章
- **账本**：每次批准都存「改前快照」，在小芽窗口里能翻到「她改过什么」，每条一键撤销。这是给「小模型蠢」的第二道保险——就算你手快批错了也回得来
- **设置里按包开关**：创作 / 外观 / 记忆查询，每包一个开关，关掉的包工具定义都不发给模型（也顺便给小模型减负）

### 4.3 表情跟着状态走（不靠模型自觉）

小模型不可靠 → 表情**由事件驱动**，模型只能在旁边加一个可选的情绪标签：

| 事件 | 表情 |
|---|---|
| 空态 / 打招呼 | Smirk（她那个自信的笑） |
| 发出去了、等回复 | Huh? |
| 在调只读工具（翻资料） | Huh? + 状态行「在翻你的世界书…」 |
| 交出提案等盖章 | Cheer! |
| 你批准了 | Love~ |
| 你丢弃了 | Sigh… |
| 模型出错 / 解析失败 | Sob |
| 工具轮数撞上限 / 连续失败 | Chaos! |
| 她拒绝做不到的事 | Nope. |
| 被你打断（停止） | Shock! |

---

## 5. 给小模型减负（本地模式才开）

- 工具按页面裁剪：在世界书页只发世界书包 + 只读包；定义越少，小模型越不乱调
- 行为规则层现在 ~1200 字（`AssistantPrompts.rulesLayer`），本地模式用精简版（上下文窗口小）
- 解析失败 → 不动作 + Sob + 「我没弄懂，换个说法？」，绝不把半截 JSON 显示出来
- 历史窗口：本地模式从 60 条降到 ~12 条

---

## 6. 影响范围（预估）

| 文件 | 改动 |
|---|---|
| `Views/Assistant/AssistantPanelView.swift` | 重写（舞台头 / 纸底消息 / 盖章卡 / 试穿卡 / 账本入口） |
| `Views/Assistant/`（新） | `XiaoyaStage`（表情+状态行）、`AssistantProposalCard`、`AssistantLedgerView` |
| `Services/Assistant/AssistantEngine.swift` | 抽 `AssistantBackend`；表情状态机；批准时写账本 |
| `Services/Assistant/`（新） | `AssistantLocalBackend`（MLX）、`AssistantModelStore`（下载/校验/删除）、`AssistantLedger`（快照+撤销） |
| `Services/Assistant/AssistantTools.swift` | 加外观包；每个工具标档位 |
| `Views/Assistant/XiaoyaSettingsTab.swift` | 本地大脑下载卡 + 权限开关 |
| `Assets.xcassets` | 9 张 face（template 渲染）+ 邮戳 + 铃兰 |
| `project.yml` | 加 `mlx-swift-lm` 包依赖（iOS + mac） |
| `Page2VisualStyle.swift:179` | 若 Q3 选换图标：`ya3d` → 新形象 |

---

## 7. 开放问题（请 ⧫）

- **Q1 布局**：小稿里 A 舞台头 / B 桌宠常驻左下 / C 传统头像，我推荐 **A**（理由在小稿里）。
- **Q2「html」指什么**：(a) 设计先出 HTML 小稿 ← 我按这个做了；(b) 小芽窗口本身用 HTML/CSS 做（像 cssChat 那样），这样她能直接改自己窗口的 CSS。b 更「放权」，但键盘 / 性能 / 手势都要重走一遍 WKWebView 的坑，我不推荐。
- **Q3 图标**：Page2 桌面和面板头像的 `ya3d`（3D 红蘑菇）换成新形象吗？我建议换，两套风格并存很怪。
- **Q4 本地大脑**：
  - 默认后端：下载了就本地优先 / 还是一直用楼层 API，本地只是可选？
  - 下载时机：第一次打开小芽时弹一张下载卡（不自动开下，1 GB 要你点）/ 只在设置里手动？
  - 默认模型：1.7B（快、蠢一点）还是 4B（慢、聪明一点）？
- **Q5 放权首批**：外观包先放哪几项？（我列的：Page2 壁纸 / 图标外观 / 明暗 / 大图标 / 单个图标符号+颜色 / 她自己的窗口皮肤）要不要加主聊天的主题色、气泡色？
- **Q6 表情包**：带英文字幕的 sticker 要不要让她在回复里发（比如批准后回一张 Love~）？还是只当头部表情？
- **Q7 名字**：纹样图里写的是 "Lily · The Little Florist"。她还叫小芽吗？还是 Lily 是她的英文名 / 长大后的名字（之前定的是 pro = Rosemary）？

---

## 8. P0 实测（09-26，草稿目录 `scratchpad/mlx-spike`，不进仓库）

最小 xcodegen 工程（macOS 15 / iOS 26，同 MP），`mlx-swift-lm` **exactVersion 3.31.4** + `swift-transformers` **1.3.4**（只要 `Tokenizers`），分词适配手写 30 行（照 `MLXHuggingFaceMacros` 的 `TokenizerBridge` 展开抄，不引宏，不引 swift-syntax）。

| 问题 | 结论 | 证据 |
|---|---|---|
| 能不能引进来 | ✅ 3.31.4 **没有** `unsafeFlags` 和 traits（那是 main 分支 xgrammar 才加的）→ **必须钉 exactVersion 3.31.4**，升级前重审 | `Package.swift`@3.31.4 grep 无 unsafeFlags/traits；main 分支 :225-238 有 |
| 构建插件 | ⚠️ mlx-swift 带 `CudaBuild` 插件，xcodebuild 不加 `-skipPackagePluginValidation` 直接失败（「Validate plug-in “CudaBuild”」）。MP 的 build 命令 / fastlane / Xcode GUI 都要处理 | build.log |
| mac 推理 | ✅ Qwen3-1.7B-4bit：加载 0.3–0.7 s，首 token ~2 s（394 tok prompt 冷启动），生成 **101–110 tok/s**，峰值内存 **718 MB** | `/usr/bin/time -l` |
| 工具调用 | ✅ 「看世界书」→ `read_world_book(bookName:"花园")`；「把 e1 改成…」→ `propose_update_worldbook_entry` 三参数全对；闲聊 → 纯文本 | TOOLCALL 输出 |
| 关思考 | ✅ `UserInput(additionalContext: ["enable_thinking": false])` 生效，输出无 `<think>` | CHUNK 输出 |
| 蠢的样子 | 「换壁纸」（当时没外观工具）→ 答非所问「你先确认当前楼层的预设吗？」→ P4 的「做不到要明说」兜底有必要 | CHUNK 输出 |
| iOS 模拟器 | ❌ **一碰就崩**：`simctl spawn` 跑，SIGSEGV 在 `mlx::core::metal::Device::Device()` 的 strlen(NULL)（模拟器 Metal 设备没有架构名）→ 正式代码在 `targetEnvironment(simulator)` 下**绝不能初始化 MLX**，本地段整段隐藏 | `XySpikeiOS-2026-09-26-011244.ips` |
| iOS 真机编译 | ✅ arm64 Release 编译通过 | build-dev.log |
| 包体积 | ⚠️ 验证 app 39 MB（可执行 35 MB + `mlx-swift_Cmlx.bundle` metallib 3.7 MB + Hub/Crypto bundle）。主 app 预计 **+30 MB 量级** | `du -sh` |
| 下载 | ✅ 本机 HF 直连 OK；hf-mirror 权重直链 200 + `accept-ranges: bytes`（API 路径 308 重定向，别走 API 走 resolve 直链） | curl |

P0 总判：**通过**，P4 可做。plan 需要补三条：钉版本 + 插件信任、模拟器隔离、包体积告知。真机速度 / 内存（Air）仍待 P4 末尾真机验。

### 8.1 补记（09-26 P4 实施）：改钉 3.31.3

- 3.31.4 接进主工程时依赖解不出来：它要 swift-syntax `602..<604`，渲染器 `Packages/SwiftStreamingMarkdown` 的 `equatable` 1.0.10 要 `600..<602`（`swift-snapshot-testing` 1.18.1 也要 `<601`）。升 equatable 到 1.4.1 才兼容，但那是聊天正文渲染用的宏，跨 4 个小版本，不动。
- 3.31.3 要 swift-syntax `600.x`，三方可解（实际解到 600.0.1）。API 差别：`generate` 没有 `tools:` 参数；`Chat.Message` 不带工具调用 / id → 工具回合按 Qwen 原生 `<tool_call>` 正文 + tool 角色写。
- 3.31.3 实测（同一个 P0 spike 工程，Qwen3-1.7B-4bit）：「看世界书」→ `read_world_book(bookName:花园)`、「把 e1 改成…」→ `propose_update_worldbook_entry` 三参全对、闲聊纯文本。生成 17–30 tok/s（当时机器上别的 session 在编译，未排除负载因素）。
- 主工程内端到端（mac，15 个工具）：首轮 11.7 s（含加载）调了 `list_world_books`（多塞了一个书名参数），第二轮基于回灌结果正确总结，2.9 s。
