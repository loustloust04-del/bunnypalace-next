# Research: CC 调度台（dev 专用，不碰 release hub）

> 粟粟的原话：「做一个可以➕你们这些写代码cc的窗口，然后做为一个收发bot去派遣其他cc窗口？反正你现在可以通过tmux跟mpcc们讲话对吧？你先别动我们的hub，这个跟记忆宫殿（release）不一样，就是给我自己开发用的」
> 状态：理解确认稿，等粟粟批注。**不实现。**

## 我对需求的理解（先确认这个）

在记忆宫殿 app 里加一类**写码 CC 会话**：你从手机/Mac 给它发指令，它是个「调度 bot」——自己能用 tmux 驱动/创建别的写码 CC（就像我今天 spawn/kill/send-keys 驱动 mp-cc 们那样），把活派出去、盯进度、汇总回报给你。release 的 hub 和小克们的链路一根手指都不碰。

一句话：**把「你在终端跟我对话」搬进记忆宫殿，而且我可以替你使唤一群 CC。**

理解对不对？尤其这句：「派遣其他cc窗口」= 调度 CC 自己管理工作 CC（spawn 新的 / 驱动已存在的），**工作 CC 不直接连 app**，所有收发都经调度 CC 的嘴。对吗？还是你想要每个工作 CC 也各自是 app 里一个窗口？

## 已有地基（今天链路验证过的）

| 组件 | 现状 |
|---|---|
| hub.ts 全 env 参数化 | PORT / WORKDIR / SECRETS_DIR 都可覆盖 → **起第二个 dev 实例零代码改动**，「别动 hub」天然满足 |
| app 会话↔session 绑定 | `conversation.ccBridgeSessionName` + X-MP-CCSession 路由（ConversationViewModel:1473）已存在 |
| ➕ 新建 session UI | CCSessionPickerSheet 已有 spawn_cc 流程 |
| 调度 CC 驱动别的 CC | 今天实战验证：tmux spawn/kill/send-keys/capture-pane 全套可行（我就是这么管 mp-cc 们的） |
| 思考链 | dev hub 跑同一份 hub.ts → 调度 CC 的思考链自动也有 |

## 方案（推荐 O1）

### O1：第二个 hub 实例 + app 双连接（推荐）

```
记忆宫殿 app ──ws:7890──► release hub ──► cc-rp 的小克们（原样不动）
            └─ws:7891──► dev hub（同一份 hub.ts，env 区分）──► ~/Desktop/cc-dispatch 的调度 CC
                                                                  └─ tmux ─► 工作 CC们（任意项目目录）
```

- **dev hub**：`MP_CC_HUB_PORT=7891`、`MP_CC_WORKDIR=~/Desktop/cc-dispatch`、`MP_CC_SECRETS_DIR=<cc-bridge>/secrets-dev`、独立 token。一个 start 脚本手动起（开发工具，不上 launchd，也可以上，批注定）。
- **cc-dispatch 目录**：调度台的家。CLAUDE.md 写调度职责（收指令 → 派活 → 盯进度 → reply 汇报），没有 RP 人设。`.claude/settings.json` 同款 thinking hook（指 7891）。
- **app**：CCBridgeWebSocketClient 拆成可多实例（或加第二个单例 devShared），conversation 加一个标记（如 `bridgeKind: release|dev`）决定走哪条连接；➕ 写码 CC 入口放哪儿批注定（侧栏新分组？）。**iPhone 端要不要同步支持，批注定**（要的话扫码配对也得双份）。
- 隔离度：端口/secrets/workdir/token 全分开，dev 玩坏了 release 链路无感。

### O2：复用现有 hub 直接 ➕ session（不做，说明原因）

现有 hub spawn 一律 cwd=cc-rp → 调度 CC 会载入小克的 RP 人设 CLAUDE.md。改 spawn 支持 per-session cwd = 动 hub，你说了不动。PASS。

### O3：hub 加 per-session cwd 参数（最省力，但动 hub）

`spawn_cc` 帧加可选 `cwd` 字段，十几行。**这次不做**（尊重「别动hub」），但记一笔：将来 release 想要「项目会话」功能时这是正路，dev 侧验证好的调度模式可以平移。

## 调度 CC 的形态（批注点）

1. **能力边界**：调度 CC 有整台 Mac 的 shell（跟我一样）。它能 spawn 工作 CC 的项目目录要不要白名单（如只限 `~/Desktop/susu-project/*`）？还是全放开？
2. **工作 CC 的权限模式**：无人值守写码得用 auto mode 或 skip-permissions，胆子多大你定。
3. **一个常驻调度 CC，还是按项目开多个？** 我倾向一个常驻（mp-dev-dispatch），多了你自己也乱。
4. **汇报粒度**：派活后实时转播工作 CC 的输出，还是只报关键节点（开工/卡住/完成）？我倾向关键节点 + 你问才贴细节，不然手机上全是刷屏。
5. **iPhone 要不要**：Mac app 先行？还是两端一起？

## 风险

- 调度 CC = 能动你全部代码的 agent 挂在 app 后面，dev hub 的 token 认证必须留着（非 loopback 必带）。
- 多 CC 并行写同一个仓库会打架（你的 git 工作流记忆里有教训）——调度 CLAUDE.md 里要写死「同一仓库同时只派一个 CC，或者用 worktree 隔离」。
- app 双连接是这次最大的改动面（WS client 现在是单例），plan 阶段细拆。

—— 写代码 CC，2026-06-11 深夜
