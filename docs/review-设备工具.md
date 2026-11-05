# Review：设备工具 P1（实现复盘）

> 2026-08-25 · worktree-device-tools（基于 worktree-permissions）· plan-设备工具 T0-T8 落地复盘。
> 状态：⏳ iOS build 绿 + 产物四键实证；macOS build/全套测试/模拟器实证进行中，本文随结果收口。

## 〇、首验事故：claude-proxy 丢 tools（2026-08-25 粟粟真机首验即中）

**现象**：问「我明天有什么安排」→ 模型吐 `<tool_call>{"name":"calendar_list_events",…}</tool_call>` 文本，名字是编的，无授权弹窗，轮次结束。
**根因（CONFIRMED）**：proxy.log 显示请求打的是 claude-proxy；`proxy.mjs` 全文不读 `tools`（只有 `--tools ''` 关 CC 自带工具），`claude -p` 也没有客户端自定义工具通道 → 28 个 schema 被丢，模型只看到 system 里「你可以用设备工具（calendar_*）」→ 对空气假调用。**不是设备工具的 bug，是 provider 能力缺口**——fs_*/recall/搜索走 proxy 一样废，设备工具的提示段只是把它照亮。
**修法（粟粟拍「都」）**：
- **A · proxy 文本模式 function calling 垫片**（`~/claude-proxy/proxy.mjs`，备份 `.bak-20260825-tools`，无 git）：请求带 `tools` → schema 塞进 system + 约定 `<tool_call>{json}</tool_call>`；历史 `tool_use/tool_result` 块渲染成同协议文本回灌（顺手修了 `extractText` 丢非 text 块导致多轮工具对话本就会断的老 bug）；输出扫描器把 `<tool_call>` 转成 Anthropic `tool_use` 块 / OpenAI `tool_calls`，`stop_reason: tool_use`。**只在带 tools 时启用，不带 tools 的路径一字不动**。`/health` 新增 `tools: "text-shim"`。实测三链全过（非流式/流式含 thinking 转发/tool_result 续轮）。launchd `com.susu.claude-proxy` 已 kickstart。
- **B · MP 卡级「工具调用」开关**：`APICredential.toolsSupported: Bool?`（Optional 保老存档，对比线洞 4 教训）+ 编辑器 Toggle（API Key 段下方）+ `toolInjection` 闸（关 = 不发 tools 也不提工具，同 ccBridge 待遇）。任何剥 tools 的中转都能用它止血；一键添加以后可从 `/health.tools` 自动设。
### 首验第二桩：⚠️「未收到回复」与成功结果并存（同日修，`aaabfa0c`）

**现象**：`calendar_create` 那轮，工具执行成功、正文「加好了…」也出来了，气泡里却挂着 ⚠️ 未收到回复。
**根因（CONFIRMED，读码定位，proxy 侧事件序列 curl 实测完整不背锅）**：工具循环跨轮复用同一个 `BaseChatProvider` 实例，每轮 `startRequest` 建新 URLSession。轮 N 的连接常在**轮 N+1 已开始后**才 `didCompleteWithError`（TCP 关闭延迟），此时读到的是新一轮状态——`receivedDone` 已被 `startStreaming` 重置、`isStreaming=true`、`streamingContent` 还空 → `wasStreaming && isEmpty` 成立 → 误报；**且顺手把新一轮的 `isStreaming` 置 false、`urlSession` 清 nil**（取消按钮失效，比误报更严重的隐藏副作用）。
**修法**：delegate 三个回调（didReceive data / response / didCompleteWithError）加代际身份守卫 `session !== self.urlSession → 丢弃`。教训进记忆 `feedback_stale_urlsession_callback`：长生命周期对象 + 每轮新建异步源，必须用**身份**判活，不能用标志位（标志位会被新一轮重置）。
**范围**：这是**所有 provider 所有工具轮**的既有缺陷，不是设备工具引入的——设备工具只是第一个把工具循环跑满两轮的场景。
**未验证**：真机复验待重装（单测覆盖不到 URLSession 竞态；补真机器人复现器代价高，接受靠日用观察）。

**债**：proxy 的 OpenAI 流式 tool_calls 路径只做了单调用一个 chunk 的最简形态，MP 的 OpenAI 兼容卡走 proxy 时多工具并发调用未实测。

### 首验战果（正面记账）

一次真机首验（两轮对话）产出：**工具链端到端通了**（calendar_query 空日历 → calendar_create 落系统日历），**外加三个真 bug**——proxy 丢 tools（A 修）、proxy 丢 tool_use/tool_result 块导致多轮工具对话本就会断（A 顺手修）、跨轮陈旧回调（守卫修）。后两个都不是设备工具引入的，是设备工具**第一次把工具循环跑满两轮**才照出来的存量缺陷。缓存命中 97-98%（垫片没破坏前缀稳定性）。

## 一、边界情况

1. **askOnce 对设备工具在调用时弹卡**（tool loop 闸沿用权限 P1）——但 `calendar_*` 三个工具各自触发一次同域弹卡？不会：grant 按域记，`calendar` 域答一次三工具共用 ✅。
2. **系统授权拒绝后不会再问**：EventKit 拒绝后 `authorizationStatus` 固定 denied，工具每次返回 `authorization_denied` + 指引；不重试系统弹窗（只能去系统设置）。
3. **重复事件删除的 ±1 天窗口**：occurrence_date 给错到隔天以外找不到 → not_found，文案引导重新 query。
4. **剪贴板图片落附件依赖 conversationId**——无对话语境（不会发生在 tool loop）返回 `_warning` 不保存。
5. **`notify_schedule` 只发一次性**；重复/action 回流 P2。通知 id 前缀 `ai-` 与 MedReminder 的 `med-` 隔离。
6. **SystemAuthQueue 超时 30s = 不写任何持久状态**：下次调用会再次请求系统授权（系统自己若已记录拒绝则直接 denied）。
7. **macOS**：`device_info battery` 返回 not_available；剪贴板走 NSPasteboard；EventKit/通知/Vision 全可用。

## 二、与下一模块交互的风险

1. **对比线 A1 `ToolCallPreflight` 落地时要吸收 `DeviceToolDispatcher.preflight`**（同一件事两处实现 = 漂移面）；A1 落地后删掉本地版。
2. **tool loop 又长了一个 else-if**：dispatcher 模式证明可行，fs_*/recall/search 等老分支值得反向收编（对比线 A3 并发只读工具的前置也是这个）。
3. **权限 P1 的 review 债「ConfigImporter 导入旧 key 不改 perm.*」**对新域无影响（新域无旧 key），但导入含 `perm.calendar` 的 config 会直接生效——用户行为，可接受。
4. `open_url` 的 `mp://` 等 C4；权限拒绝文案深链同挂。

## 二·五、合并记账（08-25）

**已合入 master `63af9ec2`**：权限 P1 + 设备工具 P1 + proxy 垫片配套（卡级工具开关）+ 陈旧回调守卫 + 对比线 A1/E1。合并时三处冲突全是「各加各的」：iOS plist（我的日历/提醒四键 × master 的 Bonjour + LocalNetwork 新文案，两边都留）、project.yml（同款）、NOW.md 戳。两个 Swift 文件（`APIProvider` / `APICredentialEditor`）自动合成功。

**合并后验证**：iOS build 绿 · macOS build 绿 · 650 测 1 红——`AgoraViewModelTests.testErrorBannerAutoDismisses`，**已判 flaky 非回归**：该用例 10ms banner + 30ms sleep，并行负载下定时器抖动；单独重跑 3/3 通过，且本批次未触碰 Agora 任何文件。**债**：这条用例该改成轮询等待而非固定 sleep（不归本批次，记给 Agora 线）。

**A1 落地后的清理**：`DeviceToolDispatcher.preflight` 已降级为兜底（主路径由 `ToolCallPreflight` 在 tool loop 统一拦），注释写明；两处实现不允许再分叉。

## 三、技术债

1. 模拟器实证（T9）：EventKit 在模拟器可用，可跑 create→query→delete 链；剪贴板/通知模拟器可验；OCR 需一张图——待跑。
2. 日历/提醒的 update、重复事件创建、地理围栏提醒 → P2。
3. `describe(EKEvent)` 没带 attendees/alarms；够 P1。
4. 工具描述文案是我写的中文，模型用得对不对要真机观察（尤其相对时间写法）。

## 四、粟粟真机清单

- [ ] 设置→权限：「AI 能做什么」多了日历/提醒事项/剪贴板三行（默认不允许）；「AI 自主行为」多了发通知；系统权限多了日历/提醒事项状态行
- [ ] 把「日历」调「自动允许」→ 问 AI「我明天有什么安排」→ 首次系统授权弹窗 → AI 读到日程
- [ ] 让 AI「明天下午三点帮我加个牙医预约」→ 系统日历 app 里出现
- [ ] 「提醒事项」调「每次询问」→ 让 AI 建个提醒 → 弹卡 → 允许 → 提醒事项 app 里出现
- [ ] 复制一段文字 → 「看看我剪贴板」→ 系统粘贴提示 → AI 复述
- [ ] 发张图 → 「把图里的字识别出来」（ocr_image）
- [ ] 「发通知」开 →「10 秒后提醒我喝水」→ 通知落地
- [ ] **复验陈旧回调修复**：再跑一次「查日历 → 让它建个事件」两轮工具链，气泡里不该再出现 ⚠️ 未收到回复；顺手确认生成中的停止按钮仍可用
