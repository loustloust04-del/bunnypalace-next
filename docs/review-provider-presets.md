# review · 多家预设 阶段 1–6 收尾

> 2026-10-15 · 工位 page0（分支 `zone/page0`，相对 master 7 个提交 `38b46c298 … 9441b0b26`）
> plan：`docs/plan-provider-presets.md`，**在 backend-3 工位，不在本分支**（合并前要么把 plan 一起带进来，要么把这里的引用改成 master 上的路径）。plan 里的 todo 勾选框还没勾，plan 是只读的，留给车头处理。
> 审查：sol 三轮（阶段 1 / 阶段 2–4 / 阶段 5–6），原文在车头 scratchpad 的 `review-presets-s1.out`、`review-presets-s234.out`、`review-presets-s56.out`。
> 本文只记风险和欠账，不复述做了什么（做了什么看提交说明和 `docs/now/page0.md`）。

| 提交 | 内容 |
|---|---|
| `38b46c298` | 阶段 1：预设改成数据表 + 区域；卡加可选 `regionId`；编辑页多出「套餐与地区 / 接口格式 / 去拿 key」三行 |
| `905921bf7` | 阶段 2：`/models` 宽容解析；`listsModels == false` 的区域直接给种子；模型元数据存旁表 `ModelHints` |
| `aaf0af666` | 阶段 1 审查修复 4 条 |
| `da4934c44` | 阶段 3+4：老 5 家补区域，新增 11 家；条款提示；套餐区域默认用 Anthropic 格式 |
| `8564d42d2` | 阶段 6+5：ChatGPT 登录风险提示 + 第一次登录确认；OpenRouter 一键登录 |
| `3eba21d06` | 阶段 2–4 审查修复 3 条 |
| `9441b0b26` | 阶段 5–6 审查修复 6 条 |

---

## 1. 边界情况

### 1.1 先验证：Anthropic 格式的预设卡，聊天请求不带 `anthropic-version`（推断，未实测）

- **原因**：新增的 11 家预设都没有 `extraHeaders`。这是故意的，`APIProviderTableTests.testNewPresetsCarryNoHeaders` 就锁着这一条，目的是不加任何冒充客户端的请求头。但这样一来，`CredentialDraft.makeCredential` 只会给**自定义** Anthropic 卡补 `anthropic-version`（`CredentialDraft.swift:125-127`），预设卡拿到的是空字典。
- **测试连接和聊天走的路不一样**：
  - 测试连接走 `ProviderProbe.applyAuth`，会自己补这个头（`ProviderProbe.swift:260-262`），所以测试能通过。
  - 聊天走 `ChatService`，只设 `x-api-key`，其余用卡上的 `extraHeaders`（`ChatService.swift:1218-1222`、`:1518-1522`），所以不会带这个头。
- **影响范围**：
  - 所有套餐区域，因为它们默认就是 Anthropic 格式（`APIProviderTable.swift:27`）；
  - 老的智谱 / 通义 / Moonshot 卡切到 Anthropic 格式之后；
  - Kimi Code 会员、阶跃、小米、千帆、腾讯、华为、MiniMax 的 Anthropic 格式。
- **会怎样**：厂商的兼容端点如果要求带这个头，就会出现「测试连接是绿的，一聊就 400」。很多兼容端点不检查这个头，但目前一家都没实测过。
- **怎么办**：验收时至少挑一家套餐用 Anthropic 格式真聊一句（见 §5）。如果 400 了，最小的修法是在 `makeCredential` 里对 `type == .anthropic` 的卡统一补 `anthropic-version`。这个头是 Anthropic 协议本身要求的，不算冒充客户端。

### 1.2 输入异常 / 空状态

- **共用 Anthropic 地址的区域，反查会认错**：
  - 智谱的「按量」和「Coding Plan」用的是同一个 Anthropic base（`APIProviderTable.swift:323,327`），Z.AI 也一样（`:489,492`）。
  - 卡上没有 `regionId` 时（导入不带这个字段的旧配置，或者旧版本 app 把卡重新存过一次），`resolveRegion` 只按地址找，第一个匹配的就是「按量」（`APIProviderTable.swift:96-102`）。
  - plan §4 里说「丢了 `regionId` 还能反查回来、不损数据」，这句话对这两家的 Anthropic 卡不成立。后果是：编辑页显示的区域不对、条款提示不显示，以后的额度卡也会去拉错区域的额度。
  - 现在发生的概率很低，因为卡表不走 iCloud，只有导入导出时才会碰到。阶段 7 开工前要定下来：区域只认 `regionId`，或者反查时遇到多个同时匹配就当作认不出来。
- **套餐 key 填到按量区域**：只有一行灰字提醒（`APICredentialEditor.swift:489-493`）。`keyHint` 只是输入框的占位文字，不检查 key 前缀（`sk-sp-` / `tp-` / `sk-tp-`）。填错了要等测试连接才知道，看到的是 401 或「余额不足」。
- **种子模型的显示名就是模型 id**：`seedModels(in:)` 直接写 `name: $0`（`APIProviderTable.swift:105-110`），没有按 plan §3.2 说的用 `ModelCatalog` 补名字。火山、千帆、腾讯、华为套餐的模型清单里看到的都是 `ark-code-latest` 这样的 id。
- **不提供 `/models` 的 4 个区域**（千帆个人 / 企业、腾讯 Token Plan、华为 Token Plan）：
  - 清单永远是照抄 magpie 的种子，厂商上新模型只能手动加；
  - 这几个区域也永远没有 `ModelHints`。
- **OpenRouter 登录**：
  - 每登录一次，就在她的 OpenRouter 账号里新建一把叫「记忆花园」的 key。登了没保存、重复登录、删卡，app 都不会吊销这把 key，只有一行字提醒她自己去网站删（`APICredentialEditor.swift:999-1004`）。
  - 粘授权码模式下授权码 10 分钟就过期。过期后显示的是「换 key 失败（HTTP 4xx）：」加上游原文的前 300 字节（`OpenRouterLogin.swift:179-184`），没有说成人话。
  - 本机监听模式 5 分钟超时（`OpenRouterLogin.swift:52`）。浏览器里登得慢，回来时监听已经停了，浏览器会显示连不上。界面上会显示「等了 5 分钟没等到登录结果」。
  - 一键登录按钮只在提供商选的是 OpenRouter 预设时出现（`APICredentialEditor.swift:879-881`）。用「自定义」填 OpenRouter 地址的卡没有这个按钮。
- **ModelHints 旁表**：
  - 文件损坏时读出来是空的，下次写入会把整份覆盖掉（`ModelHints.swift:46-51`），过程中不报错。
  - 旁表不在整机备份、设置导出、iCloud 里。换了设备要重新拉一次模型才有。
  - 没拉过 `/models` 的老卡没有旁表数据。

### 1.3 并发 / 失败重试

- **OpenRouter 登录的归属**：sol 三轮审查之后，换家、取消、关页都会让这一轮登录作废（`OpenRouterLogin.swift:464-562`），晚到的结果不会写进 key。没覆盖到的一个情况：iOS 上 `presentationAnchor` 的兜底写法是 `UIWindow(windowScene: scenes[0])`（`OpenRouterLogin.swift:290-299`），如果连一个前台 scene 都没有就会越界崩溃。按钮只能在前台点到，所以理论上碰不到，记一笔。
- **ModelHints 同一张卡两路同时写**：编辑页保存（`CredentialDraft.swift:195`）和 `ProviderManager.fetchModels`（`APIProvider.swift:921`）都是整张卡整份替换，后写的那个生效。两边拉的是同一个清单，问题不大。
- **拉模型失败**：编辑页有「仍然保存」可以退路（原有行为）。`listsModels == false` 的区域不发请求，所以不会失败。

---

## 2. 和下一模块交互的风险

### 2.1 阶段 7：额度 / 余额卡

- **数据结构还没加**：`PresetRegion` 里还没有 `quota` 字段（plan §5.7 的 `QuotaSource`）。开工时在区域上加这个字段即可，卡不用动。
- **区域认错就拉错额度**：拉额度要先知道卡属于哪个区域，§1.2 说的「共用地址反查认错」会直接导致拉错额度。用的是卡自己地址的卡（`_own_`）没有区域，就不显示额度。
- **每家拉额度的写法不一样**：
  - 智谱 / Z.AI 是 Authorization 里直接放 key，不带 `Bearer`；
  - Kimi Code 的地址是 `{base}/usages`，base 用的是区域里的 `/coding/v1`；
  - MiniMax 只有套餐 key 能拉到额度，按量 key 会返回空或报错。显示逻辑要把这种情况当作「不显示」，不能报错。
- **请求频率**：打开 API 列表时每张卡都去拉一次。卡多的话一次会发 N 个请求，缓存 5 分钟这条要写进测试。
- **和现有对账的关系**：`UsageReconciliationSection`（对账，OpenRouter 用 key 识别）已经存在，两边不合并，但同一张 OpenRouter 卡的页面上会同时出现「余额」和「对账」。出小样时把两者放在一起看。
- **测试样本**：plan 写了用脱敏后的真响应。这份样本**不能进 git 原件**（CLAUDE.md 隐私规则），只提交脱敏后的。

### 2.2 Copilot（单独写 plan，只进 Debug）

- **和本单的「不冒充客户端」规则冲突**：Copilot 要伪装成 Copilot 客户端的请求头，而本单测试 `testNewPresetsCarryNoHeaders` 锁住了新预设不带请求头。所以单列的 plan 必须写清楚一个例外：只在 `#if PERSONAL_APPS && DEBUG` 下生效，测试也按 Debug / Release 分开断言（照 `testKimiPOnlyInPersonalDebug` 的写法）。
- **登录方式没有现成的枚举值**：`PresetLogin` 里没有设备码这一项（`APIProviderTable.swift:78-80`），要新加一个 case。如果需要用短期 token 换，就不能当普通 key 卡处理，`CredentialCommitter.commit` 的 `default: setApiKey` 分支也不适用，要单独设计刷新逻辑。
- **菜单位置**：`presets` 的插入写法照 kimi-p（`APIProviderTable.swift:139-144`）。菜单分节放「本机与账号」还是「海外」，要在 plan 里写明。

### 2.3 兼容线：ResolvedCompat（E）

- **E 的判断依据是地址，不是预设**：E 现在用 `KnownHost.detect(baseURL)` 按地址判断是哪家（见 backend-3 的 `plan-model-compat-p0.md` §3），不读 `presetId` / `regionId`。本单新增的地址（`api.kimi.com/coding`、`api.stepfun.*`、`token-plan-*.xiaomimimo.com`、`qianfan…/tokenplan` 等）都不在它的地址表里，会走「通用」那档。
- **建议**：E 正式版加「部署契约」时，优先用 `APIProvider.preset(id:)?.resolveRegion(for:)` 拿到区域，再读区域上的字段，地址判断只作兜底。注意两点：
  - **不要直接读 `card.regionId`**，老卡上这个字段是空的，一律走 `resolveRegion`；
  - 用的是卡自己地址的卡没有区域，要有默认值。

### 2.4 兼容线：能力位 I 读取 ModelHints

- **怎么查**：旁表按「卡 id → 模型 id」存（`ModelHints.swift:29-31`），I 查的时候要用卡 id 加裸的模型 id，不能用 `卡id/模型id` 这种复合 id。
- **为什么会查不到**：
  - Anthropic 格式的卡拉模型时，打的是区域的 OpenAI base（`ProviderProbe.swift:52-53`）。两种格式的模型 id 如果不一样（plan 里举过 MiniMax 大小写的例子），按 Anthropic 卡的模型 id 去查旁表就会落空。
  - 新卡在保存之前，元数据只在页面手里（`draftHints`），保存成功后才写进旁表（`CredentialDraft.swift:147-150,195`）。I 在保存前读不到。
  - 小芽引导和 Onboarding 拉模型都不写旁表（§3 第 1 条）。
- **数字本身的含义**：`contextTokens` 是厂商 `/models` 返回的 `context_length ‖ context_window`，和 `ModelCatalog` 里的上下文窗口可能对不上（OpenRouter 返回的是路由后的值）。以谁为准由 I 决定。plan 写的是「`ModelCatalog` 查找时先看它」，这条还没实现。
- **没有数据的情况**：旁表为空（种子区域、没拉过模型、换了设备），I 要按「不知道」处理，不能按「0」或「不支持图片」处理。

### 2.5 套餐默认 Anthropic 格式，和兼容线 B / C 的关系

- **为什么默认 Anthropic**：plan 的 Q3 选了「套餐区域默认 Anthropic」（`APIProviderTable.swift:24-28`），理由是 OpenAI 兼容这条路还不解析思考，工具第二轮可能 400。
- **B / C 合进来之后**：重新评估要不要改回默认 OpenAI 兼容。改默认只影响**新建的卡**，老卡的格式存在卡上，不会变。`testPlanRegionsDefaultToAnthropic` 锁着现在的默认值，改的时候一起改。
- **Anthropic 这条路也有风险**：现在聊天对很多模型会明写 `thinking: adaptive`、`display: summarized` 等参数（见 model-api 事实层）。国内厂商的 Anthropic 兼容端点不一定认这些参数，第一句可能被拒一次，然后靠 `ParamErrorClassifier` 自愈。加上 §1.1 的 `anthropic-version` 问题，套餐卡第一次真聊要专门看一眼。
- **C1 默认表不覆盖 Kimi Code**：C1 的默认表只写了 deepseek / moonshot / openrouter 这几个 host。Kimi Code 用户如果手动切到 OpenAI 格式，拿不到思考回传，K3 的工具续轮仍然可能 400。

---

## 3. 技术债

1. **小芽引导和 Onboarding 拉模型不写 ModelHints**：`XiaoyaKeyCardModel.swift:71`、`OnboardingFlowView.swift:936` 调的是不带 `hints` 的 `ProviderProbe.fetchModels`。从这两处建的卡，要等第一次在编辑页「刷新模型」后才有元数据。
2. **只填了数据、没人用的字段**：
   - `catalogIds` 每个区域都填了，但没有任何地方读它，`ModelCatalog` 还是只按模型 id 全局查（plan §6 里 `model(for:preferring:)` 是可选项，没做）；
   - `docsURL` 一个都没填。
3. **自定义 scheme 回调没实测**：`memorygarden-oauth://openrouter` 只能用 `defaults` 键 `openRouterLoginCallbackMode = customScheme` 打开，界面上没有入口（`OpenRouterLogin.swift:19-45`）。默认值已经按审查第 6 条改成 mac 用本机监听、iOS 粘授权码，所以 iOS 的 `ASWebAuthenticationSession` 路径实际上没人走过。
4. **只靠探测或第三方资料撑着的地址**：提交 `da4934c44` 说待核的 10 处都用官方页或无 key 探测核过了。下面这些**没有带 key 实际打过**，探测只能证明这条路由存在，不能证明套餐 key 在这里扣的是对的额度、种子模型 id 是对的：
   - 火山 Agent Plan，两种格式：只有 magpie 一个来源，而且探测时正确地址和乱写的对照地址都回 401，**连路由存不存在都分不出来**；
   - 千帆 Token Plan 企业版：只有 magpie 一个来源，探测 401 / 422，对照 404；
   - 腾讯 TokenHub 按量（国内 / 国际）：只有 magpie 一个来源，探测 401，对照 404；
   - 华为 MaaS 按量：只有 magpie 一个来源，探测 400，对照 404；
   - 阶跃 Step Plan 国际、按量国内：只有 magpie 一个来源，探测 401，对照 404；
   - 阿里 Coding Plan 国际的 Anthropic base：没有任何资料，是按规则拼出来的，探测 401，对照 404；
   - 阿里 Token Plan 国际：只有 omp 一个来源。OpenAI base 探测成立；Anthropic base 正确地址和对照地址都回 401，分不出来；
   - 拿 key 链接：MiniMax 国内（`platform.minimax.cn/console/access?tab=api-keys`）、SiliconFlow 国际（`cloud.siliconflow.com/account/ak`），是按 plan 的待核项改的，没打开确认过落地页。
5. **「Anthropic base 补 `/v1`」这条规则，有 3 家探测分不出来**：探测的做法是对比「正确地址」和「故意写错路径的对照地址」的返回码。下面三家都是先查 key 再看路径，带不带 `/v1` 都回 401：
   - 火山 Coding Plan / Agent Plan（`/api/coding/v1`、`/api/plan/v1`）；
   - 腾讯 Token Plan（`/plan/anthropic/v1`）；
   - 阿里 Token Plan 国际（`/apps/anthropic/v1`）。

   其余 15 家探测结果成立（正确地址回 401 / 400 / 422，对照地址回 404）。这三家要等有 key 再确认。
6. **条款没查到原文的几家没挂提示**：
   - Z.AI Coding Plan 很可能和智谱一样只给编程工具用，但没查到原文，没有挂条款提示；
   - 阿里 Token Plan、小米、MiniMax 也一样没挂（plan §3.4「未查」）；
   - 火山 Agent Plan 在 plan 里没列条款，也没挂。
7. **ChatGPT 的 UA 实测没做**（plan 阶段 6 最后一项）：`codex_cli_rs/0.0.0`、`client_version=0.0.0` 会不会让后端不放行新模型，需要她的 ChatGPT 卡来测。结论还没写进 now 文档。
8. **新预设没有品牌图**：走的是首字母圆片。菜单里这些家只显示文字（`.menu` 的行不能画圆片，见 `APICredentialEditor.swift:452-459`）。
9. **OpenRouter 的 `HTTP-Referer: MemoryPalace/1.0` 不是 URL**：来源归因可能不生效（plan §9 已记）。
10. **说明书只做到事实层**：`manual/facts/model/model-api.md` 已经同步（说明书流程第 1 步）；`npm run check` 硬错 0，提醒 33 条（大多是 STALE，正文页要 rewrite 才会消；另有 `20-model/index.md` FAT ≈2615 token）。第 3–5 步（`npm run rewrite -- --page connect-model / model`、补截图、`npm run build` 并提交 HTML）**没做**，留给后续。正文页 rewrite 时要特别写：提供商菜单分节、套餐与地区、条款提示、OpenRouter 一键登录。
11. **复盘的 roadmap 索引行没加**：`docs/PROJECT_ROADMAP.md` 是多工位共用文件，交给合并时由 Warden 统一加。

---

## 4. 审查裁决表

| 轮 | # | 严重度 | 问题 | 裁决 | 落在 |
|---|---|---|---|---|---|
| 阶段 1 | 1 | 应修 | 切走再切回「用自己地址」的卡，会带回另一家的地址，而且不弹换家确认 | 收：换回原来那家时，地址和协议一起还原（`CredentialDraft.switchPreset`） | `aaf0af666` |
| 阶段 1 | 2 | 应修 | 恢复旧草稿后把改动全撤回，仍然被判成有改动（旧草稿的 `nil` 和明写的默认值被当成不同） | 收：判断有没有改动时，`nil` 和默认值算同一个（`effectiveRegionSelection` / `effectivePresetProtocol`） | `aaf0af666` |
| 阶段 1 | 3 | 应修 | 只有一个区域的预设，「用自己地址」的卡没有入口切回官方地址 | 收：这种卡也显示区域 Picker，多一项「这张卡自己的地址」，选官方地址按换家处理 | `aaf0af666` |
| 阶段 1 | 4 | 建议 | 金样测试没锁住默认区域最终用的种子模型 | 收：金样再比一遍 `seedModels(in: defaultRegion)` | `aaf0af666` |
| 阶段 2–4 | 1 | 应修 | 新卡拉到的元数据记在公共的 `"draft"` 名下，保存后用真实卡 id 查不到；删卡不清 | 收：元数据先放在页面草稿里，保存成功时按真实卡 id 写入；删卡时一并清除 | `3eba21d06` |
| 阶段 2–4 | 2 | 应修 | 已有的卡切到套餐区域，沿用旧的 OpenAI 格式，没有用套餐默认的 Anthropic | 收：区域 Picker 切换时让目标区域重新定默认格式；装载旧卡的路径不变（`switchRegion`） | `3eba21d06` |
| 阶段 2–4 | 3 | 应修 | `/models` 返回里首选字段是 JSON `null` 时，后面的备选字段读不到 | 收：每个字段先各自转类型，再按顺序取第一个有值的 | `3eba21d06` |
| 阶段 5–6 | 1 | **阻断** | 登录结果没有和发起时的提供商绑定，换了家之后 OpenRouter 的 key 会被写进别家的卡 | 收：加 `OpenRouterLoginRunner`，发起时记下这一轮的 id 和提供商；换家、取消、关页即作废，结果回来先核对 | `9441b0b26` |
| 阶段 5–6 | 2 | 应修 | 粘授权码模式下点取消，取消不了正在进行的换 key 请求；旧结果回来还会清掉新一轮的状态 | 收：换 key 的任务也归到同一轮登录，取消时连任务一起取消 | `9441b0b26` |
| 阶段 5–6 | 3 | 应修 | 关掉编辑页登录还在继续；自定义 scheme 的流程不响应任务取消 | 收：所有退出路径（取消、关页、换家）都接到取消；自定义 scheme 加取消处理，取消时收掉登录页 | `9441b0b26` |
| 阶段 5–6 | 4 | 应修 | 回调地址没有校验；本机监听收到第一个请求就交出结果，还没校验 code 和 state | 收：scheme / host / 端口 / path 必须完全匹配；state 为空、重复或对不上一律拒；本机监听只认 `GET /callback`，先校验再交出结果，无关请求只回 404 | `9441b0b26` |
| 阶段 5–6 | 5 | 应修 | 本机监听把一次 TCP 收到的数据当成完整的 HTTP 请求 | 收：攒到完整的请求行再处理，上限 8KB | `9441b0b26` |
| 阶段 5–6 | 6 | 建议 | 默认用自定义 scheme，但没有它能用的证据 | 收（改法和建议略有不同）：默认改成官方文档写明支持的方式（mac 本机监听，iOS 粘授权码），自定义 scheme 降为实验选项。端到端的证据靠 §5 粟粟验收补 | `9441b0b26` |

三轮共 13 条，全部收下，没有拒的。sol 每轮都写了「没跑 Xcode 宿主测试、没跑实际 UI、没发真网络请求」。修复提交自己跑过的验证：mac 定向测试（`aaf0af666`：5 类 71 测；`3eba21d06`：8 类；`9441b0b26`：4 类 70 测）加 iOS `build-for-testing` SUCCEEDED。**真实 UI 和真 key 聊天，三轮都没有人跑过。**

---

## 5. 粟粟验收步骤

> 装包默认用 `sim`，mac 用 `mac`（设备排队走 `device-lease`）。iOS 的设置入口是对话列表页底部齿轮 › 设置 › 「API」（简版叫「模型（API）」）；mac 是设置窗口 › API。

**A. 提供商菜单和老卡（sim 和 mac 各看一遍）**
1. API 页点 ＋ →「提供商」菜单：看到「海外 / 国内 / 聚合平台 / 本机与账号」四节，最后是「自定义」。火山那家叫「火山方舟（豆包）」；OpenRouter、SiliconFlow 在「聚合平台」里。
2. 随便选一家（比如 DeepSeek）：「提供商」段底部有「去 DeepSeek 拿 key ↗」，点了能打开对应网页。
3. 打开一张**老 DeepSeek 卡**：地址、模型都和以前一样；多了一行「去拿 key」，没有其他变化。改一下昵称保存，聊一句正常。
4. 打开一张**老智谱卡**（没有的话跳过）：「套餐与地区」显示「按量」，「接口格式」显示原来的「OpenAI 兼容」，地址不变。不动任何东西点保存，不会弹「换提供商？」。

**B. 套餐区域**
5. 新建 →「火山方舟（豆包）」→「套餐与地区」选「Coding Plan」：
   - 「接口格式」自动变成 Anthropic；
   - 出现灰字「套餐 key 只能填在套餐地址上…」；
   - 出现条款提示「火山方舟（豆包）官方说明：套餐额度只给编程类工具用…」+「看原文 ↗」，点开是火山官方文档；
   - 「模型」区是 14 个种子模型。
6. 新建 →「阶跃星辰」→「Step Plan · 国内」：有套餐灰字，**没有**条款提示。
7. 新建 →「百度千帆」→「Token Plan · 个人」：不填 key，「模型」区也能看到 9 个种子模型（`qianfan-code-latest` 打头）。
8. （有 key 的话）任挑一家套餐用 Anthropic 格式「测试连接」，通过后**保存并真聊一句**。这一步专门验证 §1.1 的 `anthropic-version` 问题：测试是绿的但聊天 400，就是那个问题。

**C. ChatGPT 账号卡**
9. 打开 ChatGPT 账号卡：「ChatGPT 账号」区顶部有一行灰色三角提示「这个登录借用的是 Codex 命令行工具的通道…」；页脚只剩两行，「实验性：…」那行没了。
10. 第一次点「用 ChatGPT 账号登录」：弹「用 ChatGPT 账号登录？」→ 点「我知道了，继续登录」进入原来的登录流程。之后再点不会再弹；「重新登录」也不弹。

**D. OpenRouter 一键登录**
11. **mac**：新建 → OpenRouter →「API Key」段点「用 OpenRouter 账号登录」→ 系统浏览器打开 OpenRouter → 登录授权 → 浏览器显示「登录结果已经交回记忆花园…」→ 回到 app，key 已经自动填好，下面有「已拿到 key…叫『记忆花园』…」→ 保存 → 聊一句。
12. **iOS（sim）**：点同一个按钮 → Safari 打开登录页 → 授权后网页上显示授权码 → 复制 → 回 app 点「粘贴」→「完成登录」→ 出现「正在换 key…」，然后 key 自动填好 → 保存 → 聊一句。
13. 登录中途换一家提供商，再换回 OpenRouter：之前那轮登录作废，key 框不会被写入。
14. 验完去 OpenRouter 网站的 Keys 页，把测试时生成的「记忆花园」key 删掉（app 不会自己删）。

**说明书**：事实层已同步，正文页还没 rewrite，不用验。
