# CC Bridge

本地把 Claude Code（CC）接进记忆宫殿（MP）的桥接服务。MP 把它当一个新的 Provider 用，跟 OpenAI / Anthropic 平级。

设计稿：[`docs/superpowers/specs/2026-05-18-cc-bridge-design.md`](../docs/superpowers/specs/2026-05-18-cc-bridge-design.md)
实施清单：[`docs/superpowers/plans/2026-05-18-cc-bridge.md`](../docs/superpowers/plans/2026-05-18-cc-bridge.md)

## 工作原理

```
MP（Mac app）  ──ws──>  hub.ts  ──tmux send-keys──>  CC（tmux session mp-cc）
        ▲                  ▲                                 │
        └────── ws ────────┴────── stdio ──── mcp-server.ts ◀┘
```

- **出站**（用户消息 → CC）：MP 通过 WebSocket 把消息发给 hub，hub 用 `tmux send-keys` 注入 CC 终端
- **入站**（CC 回复 → MP）：CC 调 MCP 工具 `reply`，mcp-server.ts 通过 WebSocket 转发给 hub，hub 广播给 MP

## 前置依赖

- **Bun**：`brew install oven-sh/bun/bun`
- **tmux**：`brew install tmux`
- **Claude Code（claude CLI）**：已装，路径在 `~/.local/bin/claude`
- 可选 **wscat**（仅 smoke test 用）：`npm install -g wscat`

## 启动（日常用法）

```bash
cd cc-bridge
bun install             # 首次或更新依赖后跑

# 终端 1：启动 hub
bash start_hub.sh

# 终端 2：启动 CC（在 tmux session mp-cc 里）
bash start_cc.sh
```

启动后：

1. 在 MP **设置页 → API Settings** 里选 **Claude Code (本地)** provider — 右边状态点应该是绿的
2. 在主对话页底部 **模型选择器** 里选 `Claude Code`
3. 发消息，等 CC 思考完回复（30s 内）

## 局域网用法（iPhone / iPad 同 WiFi 连 Mac）

让手机或平板在同一个家里 WiFi 下连到 Mac 上的 hub。

**Mac 上**：用 `start_hub_lan.sh` 代替 `start_hub.sh`：

```bash
cd cc-bridge && bash start_hub_lan.sh
```

启动后会打印：
```
===== cc-bridge hub (LAN 模式) =====
本机 LAN IP: 192.168.1.23
iOS MP 设置页填：
  Hub URL:   ws://192.168.1.23:7890/cc
  Hub Token: abc123...
====================================
```

抄下来。token 第一次生成后存在 `cc-bridge/hub-token.txt`，每次重启用同一个。

**iOS MP 上**：

1. 设置 → API → Claude Code (本地)
2. **Hub URL** 填上面打印的 `ws://192.168.1.23:7890/cc`，点保存
3. **Hub Token** 填上面打印的 token，点保存
4. 状态点应该变绿
5. 主对话页选 `Claude Code` 模型，发消息

**Mac MP 上**：不动。Mac 自己连 `127.0.0.1`，loopback 跳过 token 校验，跟之前一样。

**安全说明**：

- hub 只在家里 WiFi 内可达，对外是不可见的（除非路由器把 7890 端口映射出去——别那么干）
- 非 loopback 连接必须带正确 token；token 错或不带 → hub 直接 close 1008 + warn 日志
- token 16 字节 hex 暴力枚举不实际

**换 token / 重置**：删 `cc-bridge/hub-token.txt`，下次 `start_hub_lan.sh` 重新生成。iOS 端要同步更新。

**改 Mac 的 LAN IP 后**（路由器分配变了）：iOS 设置页改 Hub URL 即可，token 不用换。

**注意**：
- Mac 必须开着、不睡眠（系统设置 → 节能 → 接电源时不睡眠）
- 手机和 Mac 必须在同一个 WiFi
- 出门怎么办？v2 见 Tailscale 章节（暂未做）

## L2：多 CC 并行（一个对话一个 CC）

让 MP 每个对话框对应**独立的** tmux/CC 进程，多个对话同时跟不同 CC 聊互不串味。

**默认行为不变**：所有 ccBridge 对话默认绑到 `mp-cc` session（`start_cc.sh` 起的那个，带 `--continue` 接历史）。

**新增能力**：

1. MP 对话列表（sidebar）**右键 / 长按** ccBridge 对话 → contextMenu **"切换 CC Session..."**
2. picker 显示：
   - `mp-cc`（默认会话，接历史）
   - hub 端 alive 的其它 `mp-cc-*` sessions
   - **"+ 新建 session"** 输入框（自动建议 `mp-cc-2 / mp-cc-3 / ...`）
3. 点 "创建"，MP 发 `spawn_cc` 帧 → hub `tmux new-session -d -s <name> 'claude --mcp-config ...'`
4. 选中后，该对话的发送帧带 `session_name`，hub 按这个 routing 到对应 tmux session
5. 标题旁显示**荧光绿小标签**（如 `mp-cc-2`），表示这条对话被绑了

**重要约束**：

- spawn 出来的 CC **不带 `--continue`**（多 CC 同时 `--continue` 会抢 cwd 下 most-recent 的 jsonl）
  - → 这些 CC **没有跨 tmux 重启的历史 continuity**，死了就死了，需要重 spawn（新 jsonl）
- 所有 CC cwd 都是同一个 CC 工作目录（见下文「改 CC 的工作目录」），共享同一份 CLAUDE.md / project memory
- session 命名只允许 `[A-Za-z0-9_.-]{1,32}`，前缀 `mp-` 是约定（`list_sessions` 只列前缀 `mp-cc` 的）

**手动清理**：

```bash
tmux kill-session -t mp-cc-2   # 单独杀一个 spawn 出来的
tmux ls | grep mp-cc            # 看当前有哪些 sessions
```

绑到已死 session 的对话发消息 → hub `has-session` 探测立即返回 `session_not_found`（不等 grace timer）。

## L3：斜杠命令直发（CC 内建命令系统）

在 MP 输入框打 `/` 直发 CC 内建斜杠命令（`/clear` `/cost` `/model claude-opus-4-6[1M]` 等），不走 LLM 流式。

**触发**：当前选中的模型是 Claude Code (本地) 且输入框 text 以 `/` 开头：

- 输入框文字**整段变荧光绿**（IDE 代码色，明示"这是命令"）
- 输入框上方**浮一个 autocomplete 列表**，显示与 prefix 匹配的候选（带描述 + ⚠️ 标记 = 需 tmux）
- tap 候选 → 把"命令名 + 占位符 + 空格"插入输入框（**不立刻发**，让用户编辑参数）
- 也可以无视浮板，直接打完整自定义命令（如 `/model some-rare-variant[1M]`）回车发

**raw 直发**：hub 收到 `type=command` 帧后直接 `tmux send-keys -l <content> Enter`，**不包 `<channel>` tag** —— CC 看到裸 `/clear` 就触发自己的命令系统（包了 tag 会被当成文本聊天，命令不生效）。

**fire-and-forget**：CC 内建命令大多不调 MCP `reply` tool（响应在 tmux UI 渲染），MP 端**不创建 assistant 占位节点**，避免 grace timer 干等 10 分钟。

**已知限制（需 attach tmux）**：

候选列表里标 ⚠️ 橙三角的命令（`/mcp` `/resume` `/agents` `/memory` `/permissions`）— CC 收到后会弹**自己的 TUI 菜单**等用户选项。MP 远程发出去后，需要：

```bash
tmux attach -t mp-cc       # 或 mp-cc-2，看对话绑哪个
# 在 CC 的菜单里 ↑↓ + Enter 完成交互
```

或者直接用**带参形式**绕过菜单，比如：

- ✅ `/model claude-opus-4-6[1M]` — 直接切，不弹菜单
- ❌ `/model`（裸） — CC 弹菜单需 tmux 操作

`/quit` 标了 ⚠️ 是因为它**会杀 CC 进程**（mp-cc-N 那个），不是因为需要 tmux 交互。**谨慎**。

**session 路由**：命令跟 conversation 绑的 session 一致 — 比如某对话绑了 `mp-cc-2`，从该对话发 `/clear` 只清那个 CC，主 `mp-cc` 不动。

## L4：MP 内嵌完整终端（SwiftTerm）

L3 命令直发解决"发"，但 CC 的 TUI 响应（`/help` tab 切换、`/model` 菜单、`/mcp` server 列表等）只在 tmux 那头渲染，MP 看不到也按不了。L4 把整个 tmux pane 嵌进 MP 右页，**等价 `tmux attach`**：可看 ANSI 颜色 + 实时光标 + 双向按键交互。

**入口**：MP 对话页 → 右页工具栏切换到 **"CC 终端"** tab（默认开；从老 build 升级会自动加进右页工具列表末尾）。

**工作原理**：

```
MP 端 SwiftTerm view ──WS terminal_input──> hub ──tmux send-keys -H hex──> CC tmux pane
                     <──WS terminal_chunk── hub <──cat /tmp/fifo── tmux pipe-pane ←┘
                     <──WS terminal_init ── capture-pane -e (初始 ANSI snapshot)
```

- **attach**（切到 tab 时）：hub `mkfifo` + `tmux pipe-pane -o "cat > fifo"` 启动 stream + `capture-pane -e` 抓 200 行 ANSI snapshot → 双发给 MP
- **input**：键盘输入 / 工具栏按钮 → SwiftTerm delegate 给 raw bytes → hub `tmux send-keys -t <s> -H <hex>` 注入
- **resize**：SwiftTerm viewport 变化 → `tmux resize-window` 同步 → CC TUI 按新 cols/rows 重排
- **detach**（切走 tab / 关 app / 网络断）：最后一个 client 离开 → hub 关 pipe-pane + kill cat + 删 fifo

**session 路由**：终端自动 attach 当前 conversation 的 `ccBridgeSessionName`（nil → fallback 默认 `mp-cc`）。切对话或在 L2 picker 里换绑 session → 终端 view 用 `.id(sessionName)` 强制重建 + 重 attach。

**工具栏按钮**（iPhone 上特别有用，物理键盘没有的 ANSI 控制字符）：
`Esc` `Tab` `↑` `↓` `←` `→` `^C`（Ctrl+C）

**多 client**：Mac MP + iPhone MP 同时打开同一个 session 的终端 OK — hub 共享 stream，input 两端都能发（CC 会看到混合输入；v1 不阻拦）。

**已知限制**：

- 🔴 **fifo 阻塞风险**：如果 hub 端 broadcast 速度跟不上 CC tty 输出速度，tmux 写 fifo 会阻塞 → CC 主循环冻。规避：hub 端 `catProc.stdout.on('data')` 立即 broadcast 不积压。极端场景（CC 跑 `htop` / 大量颜色刷屏）可能仍触发；CC 本身命令不会有这种输出
- 🟡 **iOS 中文输入法（IME）**：SwiftTerm 的 `iOSTextInput.swift` 自己处理 IME，实测可能有边角 case；遇到反馈
- ⚠️ **跟 tmux 真实 attach 冲突**：如果你同时 `tmux attach -t mp-cc-2` + MP 终端，两边 resize-window 会互相覆盖（tmux pane 是共享的）
- ⚠️ **同一 session 多设备同时打开 CC 终端**：Mac MP 跟 iPhone MP 同时切到 "CC 终端" tool 看同一个 session（如 mp-cc）会触发：两端 SwiftTerm viewport size 不同 → 各自 sendResize → tmux pane 来回 resize → CC TUI 来回重排 → 乱码闪烁。**v1 限制：一台设备看就够，别同时开**。未来 v2 可考虑 hub 给每个 client 维护虚拟 viewport
- ⚠️ **极端长 idle 后切回**：30 分钟+ 物理网络断后重连，初始 terminal_init frame 可能跟 CC 当下状态不完全对齐；解决：切走 tool 再切回会重新 attach 修复

## v1 已知局限

- **不流式**：CC 整段回，UI 是"发→spinner→整段出现"，没有打字机效果
- **不支持 MP 分支**：CC 是单 session，切 MP 分支它不知道，UI 也不会提示
- **MP 的 preset / 角色卡 / 世界书 不生效**：ccBridge 路径绕过 PromptAssembler；CC 的人设和记忆走 CC 自己的 CLAUDE.md
- **CC 工具调用看不见**：CC 调 Read/Bash/Edit 时 MP 不显示中间过程，只显示最终 reply
- **hub 没自动起**：MP 启动 ≠ hub 启动，得手动跑 `start_hub.sh`
- **README 路径写死在 worktree 下**：设置页那个"查看启动说明"按钮的路径将来要 bundle 化

## 进阶

### CC 与开发环境隔离（默认行为）

`start_cc.sh` 给那个 CC **独立的 cwd**（`MP_CC_WORKDIR`；没设时 `~/Desktop/cc-rp` 存在就用它，否则 `~/Library/Application Support/MemoryPalace/cc-bridge/cc-rp`），放它自己的 `CLAUDE.md`（人设、记忆等）。首次启动会自动生成一个空模板，你去填。

- ✅ 项目 `CLAUDE.md` 分家（cwd 不同→读不同 CLAUDE.md）
- ✅ project-level memory 分家（auto-memory 按 cwd hash 存到 `~/.claude/projects/<hash>/`）
- ⚠️ user-level `~/.claude/` 共享（settings/plugins/skills/OAuth token）—— 但这些不会串味，只是工具配置

**为啥 user-level 不能硬隔离**：Mac Keychain 的 `Claude Code-credentials` entry name 是 CC 源码写死的，单 macOS 用户只能有一份 OAuth token。试过用 `HOME=...` env override，OAuth 走完之后 token 仍写到同一 Keychain slot，反而把主账号 token 覆盖坏。所以只走 cwd 隔离这一层。

### 改 CC 的工作目录

```bash
MP_CC_WORKDIR=~/Documents/我的RP角色 bash start_cc.sh
```

### 改 tmux session 名

```bash
MP_CC_TMUX_SESSION=cc-test bash start_cc.sh
MP_CC_TMUX_SESSION=cc-test bash start_hub.sh
```

两边要一致。

## Smoke Test（不开 MP，验证 hub+CC 链路）

```bash
# 终端 1
cd cc-bridge && bash start_hub.sh
# 看到 [hub] listening on ws://127.0.0.1:7890/cc

# 终端 2
cd cc-bridge && bash start_cc.sh
# tmux session 里跑着 CC，输 /mcp 应该列出 cc-bridge / reply

# 终端 3
wscat -c ws://127.0.0.1:7890/cc
# 连上后发：
> {"type":"send","chat_id":"test-1","message_id":"m1","content":"你好，调一下 reply 工具回我","user":"me"}
```

预期：
- wscat 立刻收到 `{"type":"ack","message_id":"m1"}`
- 切回终端 2（tmux），CC 看到 `<channel ...>` 开始思考
- CC 思考完调 reply，wscat 收到 `{"type":"reply","chat_id":"test-1","content":"..."}`

## 自动测试

不依赖 tmux / CC：

```bash
cd cc-bridge && bun test
```

应 5 pass 0 fail（hub WS 路由 + tmux send-keys + MCP broadcast 都有覆盖）。

## 排障

### "MP 设置页里 Claude Code (本地) 连接状态一直是灰的"

- hub 没跑：`bash start_hub.sh`
- hub 跑了但端口冲突：`lsof -i :7890` 看谁占的，kill 掉旧的
- MP 启动时机：MP 自动连一次，连不上不会一直重试到无穷大。可以点设置页 "重新连接" 按钮触发

### "MP 发消息没回应（spinner 一直转）"

- 终端 2（tmux）里 CC 是不是在干别的事？CC 一次只处理一条
- CC 加载 MCP 失败：在 CC 里 `/mcp` 看 `cc-bridge` 在不在。不在的话检查：
  - `cc-bridge/.mcp.json` 的路径是否指向真实存在的 `mcp-server.ts`
  - `start_cc.sh` 启动时是否成功 render 了 `.mcp.json`（看 `cat cc-bridge/.mcp.json`）

### "hub 日志说 MP connected 但 reply 没回到 MP"

- chat_id 不匹配：CC 调 reply 时传的 chat_id 必须和入站 `<channel chat_id="...">` 一致——CCBridgeProvider 用 conversation.id 当 chat_id 注册 handler，CC 回复时也应该用同一个
- mcp-server 没连 hub：hub 日志找 `[hub] MCP connected` — 没有说明 mcp-server.ts 启动后 WS 连接失败（看 mcp-server.ts 的 stderr，CC 会展示）

### "CC 第二次发消息卡住"

- CC 在前一条还没处理完（思考 / 调工具中），tmux 注入的新消息会和它输出混合
- 等 CC 输出完毕 / 在 CC 里按 ESC 中断当前思考

### "想杀干净重启"

```bash
tmux kill-session -t mp-cc 2>/dev/null
# ⚠️ 别用 `lsof -ti :7890 | xargs kill` —— 会把 mcp-server（端口 client）一起杀
# 只杀 LISTEN 端的 hub 进程：
pkill -f "bun run hub.ts"
# 或：lsof -ti :7890 -sTCP:LISTEN | xargs kill
# 然后重新走启动流程
```

## 文件作用

| 文件 | 干嘛 |
|---|---|
| `hub.ts` | WebSocket 服务器，端口 7890，桥接 MP ↔ tmux ↔ MCP |
| `mcp-server.ts` | MCP stdio server，提供 `reply` 工具给 CC |
| `mcp.template.json` | MCP 配置模板（启动时 render 成 `.mcp.json`） |
| `start_hub.sh` | 起 hub |
| `start_cc.sh` | 起 CC（在 tmux 里，加载 MCP 配置） |
| `hub.test.ts` / `mcp-server.test.ts` | bun:test 自动测试 |
