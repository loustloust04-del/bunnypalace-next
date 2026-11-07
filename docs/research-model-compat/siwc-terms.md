# Research：Sign in with ChatGPT（SIWC）对接入方的资格与条款 —— 记忆花园能不能用

> 只读网络调研，2026-10-15。官方页面原文已落盘在 `scratchpad/siwc/*.main`（developers.openai.com 各页正文）、`terms_a.txt`（条款，Wayback 2026-10-07 快照）、`help_b.txt`（帮助中心，Wayback 2026-10-14 快照）。openai.com / help.openai.com 直连 403，所以条款和帮助中心用的是 Wayback 快照。
> 引文只摘关键短语，其余是中文转述，每条都附 URL。「未查到」就是没找到，不是推测。

## 0. 一句话结论

**按现行官方口径，记忆花园（闭源、上架 App Store 的商业产品）不在自助接入范围内，要走 interest form 申请，被选中才能用。** 技术上动态注册没有闸门，谁都能注册成功；但条款对「谁可以用」写得很清楚，硬接的话随时可能被 OpenAI 停用（条款 §6），Apple 审核按 5.2.2 要授权证明时我们也拿不出来。iOS 端官方只支持 `127.0.0.1` 回环回调，没有移动端指引，也不支持自定义 scheme。

---

## 1. 官方文档、条款在哪，谁能用

### 1.1 来源清单

| 类型 | URL | 备注 |
|---|---|---|
| 法律条款 | https://openai.com/policies/sign-in-with-chatgpt-terms/ | 2026-09-29 版，**最关键** |
| 开发者文档总览（OSS 流程） | https://developers.openai.com/siwc/token-sharing-open-source | |
| 注册与登录 | https://developers.openai.com/siwc/token-sharing-open-source/sign-in | |
| 账号与会话（刷新 / 撤销 / 用量） | https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions | |
| 错误码 | https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery | |
| 预览期限制 | https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations | |
| 模型与推理 | https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference | |
| Token 参考 | https://developers.openai.com/siwc/token-sharing-open-source/token-reference | |
| 自托管 VM | https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms | |
| Quickstart | https://developers.openai.com/siwc/quickstart | |
| UI/UX 指南 | https://developers.openai.com/siwc/ui-ux-guidelines | |
| Cookbook | https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt | 含「Usage policy and terms」一节 |
| 用户侧说明 | https://learn.chatgpt.com/docs/sign-in-with-chatgpt | 合作方名单 |
| 帮助中心 | https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites | |
| 商业接入申请表 | https://openai.com/form/sign-in-with-chatgpt-interest/ | |
| DevKit 许可证 | https://github.com/openai/sign-in-with-chatgpt-devkit/blob/main/LICENSE | **非商业许可** |

时间线（第三方报道，与官方页面一致）：2026-07 先上线身份登录；2026-09-29 DevDay 加入「用订阅额度」能力，状态是 limited preview。

### 1.2 谁能用：官方几处说法，结论一致

- **开发者文档总览**：这套文档讲的是 open-source 和 locally hosted 应用的接入；想在**付费或远程托管**的应用里提供，要去填 interest form。
  （token-sharing-open-source 页）
- **Quickstart**：SIWC 目前通过 limited trial 只开放给 selected commercial partners；用订阅额度这一项对 all open-source partners and **selected private clients** 开放。
  （quickstart 页）
- **Cookbook「Usage policy and terms」**：上线阶段，用订阅额度只开放给开源项目、本地运行的个人项目，以及 selected private apps；做付费或远程托管应用的，要先 join the waitlist，拿到许可才能给用户用。
- **帮助中心「For interested developers」**：目前只和有限的合作方一起上线；开源开发者直接看开发者文档；商业合作方（不论带不带 token sharing）填 interest form。
- **条款 §2「No charge」**：用户通过 SIWC 用自己的订阅时，不能被要求向你付费，也不能被要求升级到你应用的付费版。

**落到记忆花园：**
- **闭源**：不属于 open-source，只能算「private client / private app」，而这一类要被「selected」。
- **上架 App Store 的产品**：不算「personal projects」。
- **结论**：自助接入不适用，必须走 interest form。
- **商业 / 付费**：如果记忆花园收费（买断或订阅），收费本身不违规；但 SIWC 这条路必须对免费用户也开放，不能放进付费墙后面。
- **申请审核**：表单入口有。表单要填什么、审核标准、审核周期，**未查到**。

> 注意：UI/UX 指南里有一节「Make eligible app plans clear」，要求应用写清自己哪些付费档支持 SIWC；帮助中心也说参与的 app 可能只在某些档位提供。这和条款 §2「No charge」矛盾。合理推断：商业合作方签的是单独协议，「No charge」主要约束自助接入的开源 / 本地应用。**此为推断，未查到官方澄清。**

### 1.3 本地运行 / agent / coding 工具的要求

- **本地运行**：条款 §1 规定，Authentication Tokens 只能持久存在用户本地、由用户控制，不能放在远程或托管环境里。§2 规定请求必须来自用户本地运行时，或者只有该用户控制的远程运行时。
  - 记忆花园是本机 app、token 存 Keychain，这一条满足。
  - **iCloud 钥匙串同步算不算「remote or managed environment」，未查到**，有风险。
- **是不是必须是 agent / coding 工具**：条款和文档都**没有**限定只给 coding / agent 工具。
  - Cookbook 的示例就是一个改写文本的桌面小工具（Paste Perfect）。
  - 但文档措辞明显偏 coding harness，例如错误恢复页提到 coding harness 还需要别的付费路径。
  - 条款 §2「Connected application only」：订阅只能用于用户连接的那个应用，不能变成给其他工具用的通用 API 中转。
  - 记忆花园是聊天客户端，在这一点上没有问题。
  - **注意**：如果记忆花园把 SIWC 的 token 转给 cc-bridge、其他工具或 gateway 去调用，就踩了这条线。
- **禁止项（条款 §4）**：
  - 不能多账号轮换、绕过额度；
  - 不能池化、转卖、共享额度或 token；
  - 不能拿一个用户的订阅去处理另一个用户的请求；
  - 不能修改或逆向 SIWC 软件。
- **品牌（条款 §5）**：OpenAI 的名称、logo、按钮只能按授权方式使用，不能暗示 OpenAI 背书。按钮文案统一用「Continue with ChatGPT」（quickstart、sign-in 页）。
- **DevKit 许可证**：OpenAI 官方 SDK / 组件是 **NONCOMMERCIAL LICENSE**，明确不授予商业使用权。
  - 许可证同时写明：自己独立写的软件，只是调用这个接口，不构成 Modified Work。
  - 所以记忆花园用 Swift 自己实现不受这份许可证约束。
  - 但条款 §4 要求遵守「the applicable license」。这是否把非商业限制延伸到整个集成，**条款没说清，未查到解释**。

### 1.4 闭源、商业、移动端的限制（汇总）

| 维度 | 官方口径 | 出处 |
|---|---|---|
| 闭源 | 不是「open-source」。只有「selected private clients/apps」能用，需要被选中 | quickstart、cookbook |
| 商业 / 付费 | 付费或远程托管：先填 interest form 或 waitlist；SIWC 使用本身不能收费 | 总览、cookbook、条款 §2 |
| 移动端 | **文档里完全没有提到 iOS、Android 或移动端**（未查到） | 全部 SIWC 页面 grep 过 mobile / iOS / app store / custom scheme，零命中 |

---

## 2. 动态注册规则（sign-in 页、profiles-and-sessions 页）

- **`client_id=dynamic_agent_client`**
  - 只用于**首次注册**，是注册入口。不能把它当 client id 存下来，也不能拿去换 token。
  - 回调里带着 OpenAI 签发的 `client_id`（形如 `oaiapp_...`）。之后的换码、刷新、撤销、再授权都用这个签发的 id。
  - 新注册的回调如果没带 client_id，就当注册没完成处理。
  - 再授权时回调里的 client_id 如果和存下的不一样，要拒绝。
  - 签发的 client_id 绑定到「用户 + 注册时选的 workspace」。不需要 client secret，也不需要 partner API key。
- **`agent_name_hint`**
  - 填 app 的真实名字，所有安装统一用同一个。
  - 只在首次注册时带，再授权时不带。
  - 用户批准前可以改名。它只是显示用的元数据，不是身份。
- **`ext_agent_host_id`**
  - 必填，每台 host 一个，首次登录前生成并持久化，之后一直复用。
  - 必须是不透明值，不能用邮箱、user id 这类能识别用户的东西。
  - 接受三种格式：
    - `urn:ietf:params:oauth:jwk-thumbprint:…`（推荐，RFC 9278）
    - `urn:uuid:<UUIDv4>`
    - `did:key:<key>`
  - OpenAI 目前不校验私钥持有，它只是标识。
  - 一个 client 可以对应多个 host（同一用户、同一 workspace），共享用量设置和额度。
  - **magpie 的实现**：生成 v4 UUID。是否加了 `urn:uuid:` 前缀没细看；文档要求加前缀。
- **回调**
  - 官方原文：只允许 HTTP 回环 `127.0.0.1`，不准写成 `localhost`。
  - 示例是 `http://127.0.0.1:1455/auth/callback`。
  - 后续登录**只有端口可以变**，scheme、host、path 都不能变。
  - 浏览器打开前必须先起好 listener。
  - 同一次授权里，授权请求和换码请求的 redirect_uri 必须完全一致。
  - **没有任何关于自定义 scheme、universal link 或 HTTPS 回调的说明**（未查到）。
- **其他参数**
  - PKCE 只支持 S256。
  - scope：`openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`。
  - `resource=https://api.openai.com/v1`，授权和换码两边都要带。
  - 换码后**必须检查实际授予的 scope 里有没有 `chatgpt.tokens.use.direct`**；没有就不能走订阅推理。
- **Token 生命周期**（token-reference 页）
  - access token 1 小时。
  - refresh token 30 天，每次刷新都会换新的，没有总次数上限。
  - 刷新要串行，避免两个进程抢同一个 rotating token。
- **撤销**：从 `https://auth.openai.com/.well-known/openid-configuration` 取 `revocation_endpoint`，POST 时带上 refresh_token 和签发的 client_id。
- **断开通知**：用户在 ChatGPT 设置里断开某个 app 时，OpenAI **不会**主动通知；只能等请求或刷新失败时才发现。

### iOS 上怎么做

- **官方**：**无移动端指引**（未查到）。只允许 `127.0.0.1` 回环，没有 device code 流程。
- **社区做法**：
  - justrach/harness PR #130（https://github.com/justrach/harness/pull/130）认为，因为回调是回环、又没有 device code，手机端自己完成不了；它的做法是让手机遥控电脑去登录，token 留在电脑上。
  - OpenClawKit PR #20（https://github.com/MarcoDotIO/OpenClawKit/pull/20）是 Swift SDK，声称能在 iOS 上编译，提供两种 presenter：回环 listener 和 ASWebAuthenticationSession。**iOS 上到底用哪种、有没有真机跑通，页面没写清，未验证。**
- **技术推测（未验证，不是事实）**：
  - 思路：iOS app 在前台时，进程内起一个 `127.0.0.1:<port>` 的监听，再用 ASWebAuthenticationSession 或 SFSafariViewController 打开授权页。系统浏览器进程跳到设备自己的回环地址，理论上能打到 app 的 listener。
  - 难点：ASWebAuthenticationSession 的完成回调依赖 callbackURLScheme 或 HTTPS callback，http 回环不会触发它的自动结束，需要 app 自己收到回调后关掉 session。
  - 必须真机验证。验证之前，**不能假设 iOS 能用**。
- **替代思路**：
  - Mac 端登录完，把凭据传给 iPhone。self-hosted-vms 页允许把凭据经安全通道转移到用户自己控制的另一台 host，而且那台 host 要用自己的 host id。
  - 但官方注明：转移后的会话暂不支持按 host 统计用量，也不支持单独撤销。
  - 条款 §1 要求 token 持久化必须「本地且由用户控制」。iCloud 同步是否算违规，**未查到**。

---

## 3. 计费与额度

- **用的是不是用户自己的 ChatGPT 套餐额度**：是。
  - 帮助中心：开启后，合格请求计入套餐里的「ChatGPT Work and Codex usage」。可以给每个 app 设每周上限（占整体周额度的百分比）。app 上限只是封顶，不是单独的额度池。
  - 额度用完后，只有用户在 ChatGPT 设置里**显式**允许 app 用 credits、该 app 上限设为 100%、且账户有余额时，才会继续扣 credits。默认关闭。
  - Plus 用户有一个 5 小时窗口的额度，所有 app 共享（包括私有客户端和开源客户端）；Pro 没有这个 5 小时限制（profiles-and-sessions 页）。
  - 失败时 OpenAI **不会**静默切到别的计费路径（errors 页、帮助中心）。
- **哪些套餐能用（口径不一致）**：
  - 开发者文档：「Eligible ChatGPT Plus and Pro」。
  - 帮助中心：参与的**商业** app 需要 Go、Plus 或 Pro；「Supported open-source tools remain available to all ChatGPT users」。
  - 也就是说，商业 app 和开源工具的资格范围不同。哪个口径准，**未查到权威澄清**；以帮助中心为准的话，商业 app 要求 Go / Plus / Pro。
- **用量查询**：**没有用量 API**（文档里没有，magpie commit 也写了 token 没有 usage API）。
  - 官方要求在 app 的用量页放一个「Manage usage」链接，跳到 ChatGPT Settings → Usage（`https://chatgpt.com/settings/usage`）。
  - 发请求时，在输入框或模型选择器附近显示「Using ChatGPT plan」（UI/UX 指南）。
  - 首次登录后弹一次「You're using your ChatGPT plan」确认框。
- **`subscription_sharing_*` 错误码**（errors-and-recovery 页）：

| code | HTTP | 含义 / 处理 |
|---|---|---|
| `subscription_sharing_user_not_eligible` | 403 | 该用户、workspace 或策略不允许用订阅额度。说明原因，不要重试，也不要循环走 OAuth |
| `subscription_sharing_usage_limit_exceeded` | 429 | 达到额度上限（可能是整体套餐，也可能是这个 app 的上限）。暂停请求，引导到 Settings → Usage；不能据此推断重置时间 |
| `subscription_sharing_usage_unavailable` | 503 | 暂时查不到用量。保留凭据，有界退避后重试 |
| `subscription_sharing_unsupported_capability` | 400 | 看 `error.param`，删掉不支持的输入、工具、模型或 service tier；同样的请求体不要重试 |
| `subscription_sharing_route_not_supported` | 403 | 方法或端点不支持（只认 `POST /v1/responses`） |
| `subscription_sharing_invalid_user` | 401 | 订阅上下文验证失败。确认已被撤销，或刷新彻底失败后，再让用户重新登录 |
| `subscription_sharing_user_unavailable` | 503 | 用户或 workspace 信息暂时拿不到，退避重试 |
| `chatpass_v2_scope_not_authorized` / `chatpass_v2_invalid_authorization_context` | 403 | 签名权限上下文不允许这个操作，检查 client 和 grant 配置 |

  另外，流开始之前，准入层可能返回 `{"detail":"..."}`（401、403、503）。其中 403 的例子是**服务地区**限制。
- **请求限制**（preview-limitations 页）：
  - 必须 `store:false`、`stream:true`。
  - 不能发 system role 的消息，改用 instructions 或 developer 消息。
  - 必须去掉的字段：`temperature`、`top_p`、`max_output_tokens`、`metadata`、`user`、`previous_response_id`，等等。
  - 不支持的托管工具：image generation、file search、code interpreter、computer use、hosted MCP、tool_search。
  - 不支持音视频输入、Files 上传 API、转写 API。
  - 模型列表要用同一个 token 调 `GET /v1/models` 拿当前账户可用的模型。

---

## 4. 和 App Store 审核指南的冲突点

指南版本：https://developer.apple.com/app-store/review/guidelines/ （Last Updated: June 8, 2026）

| 条款 | 风险判断 |
|---|---|
| **5.2.2 Third-Party Sites/Services**：使用第三方服务时，必须确认该服务的使用条款明确允许，Apple 要求时须出示授权 | **最大的冲突点**。按 OpenAI 现行口径，闭源商业 app 要被「selected」才算获准。没被选中就上架，Apple 一问我们就拿不出授权；OpenAI 也可以按条款 §6 停用 |
| **5.2.1**：未经许可不得使用第三方商标 | ChatGPT 的名称、logo、按钮只能按 SIWC UI/UX 指南和条款 §5 使用，不能暗示背书 |
| **3.1.1 / 3.1.3**：IAP | 我们不卖 ChatGPT 订阅，SIWC 本身不涉及 app 内购买，看起来不触发 3.1.1，跟 BYOK 填 API key 的情况相近。但 UI/UX 指南建议「额度用完可以买 app 自己的 credits」，如果做了 app 内 credits，必须走 IAP。另外，在 app 里引导用户去 OpenAI 买 / 升级 ChatGPT 套餐，是否算 3.1.3 不允许的外部购买引导，**未查到先例**。官方只要求「Manage usage」链接，没要求引导升级，建议只放这个链接 |
| **4.8 Login Services** | 只把 SIWC 当「连接模型提供商」用、不作为 app 主账号登录的话，不适用。若作为主账号登录，必须同时提供符合要求的等价登录方式（如 Sign in with Apple） |
| **5.1.2(i)**：数据发给第三方 AI 要明示并取得同意 | 记忆花园本来就涉及。SIWC 路径同样要在 UI 和隐私说明里写清数据发给 OpenAI |

**已上架 App Store 的 app 用 SIWC 的先例**：**未查到**。
- 官方合作方名单（learn.chatgpt.com）：Amp Code、Conductor、Dactyl、Devin、Hermes Agent、Hyperagent、Kilo Code、Notion、Vercel、Vorflux、Warp；Lovable 即将上线；开源的有 OpenClaw、OpenCode、Pi、T3。
- 这些大多是桌面、Web 或 CLI。
- Notion 的 iOS app（Notion Agents）目前查到的是用 Notion 账号登录、走 Notion 自己的 AI 计费，**没有证据**显示它用了 SIWC 的订阅额度。

---

## 5. 本地参考：magpie（`/Users/susu/Desktop/susu-project/magpie`）

- commit `7a926dd`（2026-10-06，#933）：新增 `internal/provider/chatgpt_api.go`（723 行）。
- 它对 SIWC 的定位和官方口径一致：让开源 app 在用户机器上用 ChatGPT 套餐。
- **实现要点**（和官方文档逐条吻合）：
  - `dynamic_agent_client` + `agent_name_hint=magpie` + 持久化的 host id；
  - 回调先试 `127.0.0.1:1455`，被占用就随机端口；
  - PKCE、ID token 的 iss / aud / nonce / exp 校验；
  - 检查授予的 scope 里有没有 `chatgpt.tokens.use.direct`，没有就提示「账号可能不合格」；
  - 刷新串行、轮换 refresh token；
  - 登出时撤销；
  - 剥掉 API 拒收的字段，过滤托管工具；
  - 把 `subscription_sharing_*` 错误码翻译成用户能看懂的话。
- **commit message 自述**：没有用量表，因为 token 没有 usage API；也**还没有用真实 ChatGPT 账号登录过**（授权同意页要账号本人操作）。所以 magpie 只验证到假服务器，**没有真机跑通的证据**。
- 后续 commit `b0607ef`：模型列表合并了 Codex 列给该套餐的模型。

---

## 6. 风险与建议（供拍板）

1. **合规前提**：记忆花园要正式上架 SIWC，先填 interest form（https://openai.com/form/sign-in-with-chatgpt-interest/），拿到书面许可后再上。这份许可同时也是应付 Apple 5.2.2 的授权证明。没有许可就上架，OpenAI 可停用（§6），Apple 可拒审或下架。
2. **如果只想自用、Debug 试水**：以「本地个人项目」的身份接入，看起来落在 cookbook 说的「personal projects that run locally」范围内。可以只放进 Debug 构建、不进 Release，和现有「自用功能只进 Debug」的规矩一致。
3. **收费模式**：§2「No charge」要求 SIWC 路径不能被付费墙挡住。商业合作协议能不能放宽这一条，未查到。
4. **iOS 技术可行性未经证实**：只允许回环、没有自定义 scheme。要先在真机上验证「进程内 127.0.0.1 listener + 系统浏览器回跳」能不能跑通，再决定 iOS 做不做。从 Mac 转移凭据的方案受「本地且由用户控制」约束，而且转移后无法单独撤销。
5. **不能做 token 中转**：订阅额度只能用于记忆花园自己的请求，不能经 cc-bridge 等转给其他工具（§2「Connected application only」、§4 禁止共享）。
6. **体验约束**：没有用量 API，只能给 Manage usage 链接；额度错误必须如实暴露，不能静默回退到别的 provider（官方明确 OpenAI 不会替你切换；我们自己做自动回退，是否违反「user authorization」精神，未查到）。
