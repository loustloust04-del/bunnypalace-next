# hub 性能线实验日志

> 口径见 [plan-hub-perf](../docs/plan-hub-perf.md)。一刀一条：假设 → 改动 → 阻塞调用账计数 → bench 前后 p75 + loop lag → 留/退。

## K1-0 零行为异步化（`f238801f5` `1d0f93e29` `5ceedf4dd`，审查返工 `c055426f1` `9077544b7` `c83e94359`）

**假设**：K1 要把 tmux 调用换成控制连接（异步），先把接口改成 Promise、调用处全部 await，而实现保持 `execFileSync` 不变，可以把「改接口」和「换通道」两件事的风险拆开（[research](../docs/research-hub-tmux-control-mode.md) §5 R11、§6.2 第 0 步）。这一步不该改变任何计时和行为。

**改动**（只动 cc-bridge 的 TS）：
- `PasteIO` / `AskUserIO` 的 `sendLiteral` / `paste` / `sendKey` / `capturePane` 改成 `… | Promise<…>`，`realPasteIO` / `askUserIO` 改成 async；`pasteAwareSendAndEnter`、`driveAnswer` 逐步 await。
- `TmuxRunner` 的 `key` / `capture` / `spawn` / `kill` / `paste` 返回 Promise；`realTmuxRunner`、`dryRunRunner`、stream 分发器跟着改。
- 调用者改 async：`spawnSession`（SessionExistsError 接管分支保留）、`settleBoot` / `finishBoot`、`spawnTerminalWindow(Safely)`、`retireForTransport`、`endWindowAfterKill`、闲置回收；WS 处理里的 spawn_cc / open_window / restore_window / end_window / terminal_paste 加 await。`sendWithEffort` 普通路径保持同步，只有 codex 重启分支返回 Promise（见审查 R1-1）。
- WS 连上时的问问题卡验活循环包进 `void (async …)()`，`ws.on("message")` 仍同步挂上。

**为什么是零行为（审查后改正）**：async 函数体在第一个 await 之前同步执行，`execFileSync` 在调用那一刻就跑完，所以 tmux 副作用本身的发生时刻不变。但 await 之后的代码**不是**「只晚一个微任务、无害」：
- 微任务队列里已经排着的东西会插到前面。外层 await 一个已经往 `chainSessionSend` 排了 job 的调用，job（sendLiteral 这次 execFileSync）就先跑，状态更新和 ack 被推到同步 tmux 写入之后，机器卡时是秒级（R1-1）。
- await 前后不在同一个同步段里，「检查状态 → 改状态」之间能被同栈的另一个调用插进来（R1-2 的 spawning 标记、R1-3 的注册表快照）。
所以零行为的前提是：await 之前把该占的状态占好、await 之后不用旧快照；外层只在真要等的分支 await。这三处按此修正后才算零行为。

**阻塞调用账 / bench**：不适用（实现没变，`[block] tmux …` 的调用点和次数应与改前一致）。

**结果**：`bun test` 698 pass / 1 fail（失败的是 agora-store.test.ts「round_robin 回合制 > 三成员圈」，已知随机 flaky，与本刀无关）。hub.test.ts 的 duplicate session 接管、terminal_report、窗口 / 粘贴用例都过。`tsc --noEmit` 206 个错误，与改前相同（全是既有的 `.ts` 后缀导入等），无新增。

**审查 R1（astra）：三条已修**
1. P2 普通 send 顺序变成「sendLiteral → 状态更新 → ack」→ `sendWithEffort` 普通路径改回同步、返回 undefined，send 处理只在 codex 重启时 await。回归用例「普通 send：ack 早于 sendLiteral」。
2. `spawnSession` 的 spawning 标记在 await 之后 → 改成 spawn 前占位，抛错（含 SessionExistsError）先清占位，接管分支照旧恢复绑定 / 标就绪 / 按序补发。回归用例「spawn 进行中同栈并发两条」（在改前代码上跑红：spawn 2 次）。
3. end_window 旧快照整体赋回 → `endWindowAfterKill` 只回 kill/验活结果，hub 在最新表上 `endWindow`；open_window 抽号时排除已抽未入表的号并占位。回归用例「并发结束两个窗口」。
返工后 `bun test` 702 pass / 0 fail（这一轮 agora round_robin 没抖），tsc 206（与改前相同）。

**判定**：留。下一步按 research §6.2 第 1 步做 `tmux-control.ts`。时序风险清单写在本次交付报告里，第 1 步之后（真异步）要逐条兑现。

**第 1 步以后要兑现的时序风险**（第 0 步里窗口只有一个微任务；真异步后变成毫秒到几百毫秒）：
1. ~~`spawnSession`：spawning 标记 / `noteSpawned` 在 spawn 完成后才记，期间再来 send 会二次 spawn → 撞 duplicate → 接管，可能 flush 两次或 CC 未就绪就注入。→ spawn 前就标记，或把 spawn 排进 per-session 链。~~ R1-2 已修（spawn 前占 spawning）。
2. `sendWithEffort` codex respawn：kill 与 `clearSessionState` 之间来的 send 发给正在死的会话，可能 spawn 两次。
3. `retireForTransport`：kill 后的收尾排到调用方剩余代码之后（LA 推送先于 askUser 收账，目前互不依赖）。
4. ~~`end_window` / `open_window`：`terminalWindows` 快照 await 后整体赋回，可能覆盖并发改动；并发 open_window 可能抽到同一个 code。~~ R1-3 已修。
5. 连上时题卡验活后台跑：`ask_user_answer` 可能先到；验活 capture 与驱动键未串行。
6. WS 处理加 await：真异步后窗口 / 粘贴回包相对顺序会变（普通 send 的 ack 已在 R1-1 改回不 await）。
7. `terminal_paste` 与 `terminal_input`（`send-keys -H` 仍同步直调）没有共用串行链 → 写命令要按会话串行（research R8）。
8. `finishBoot` retry 失败从 uncaughtException 变成 unhandledRejection（两者都 FATAL exit，结果一样）。

## K1-1 tmux 控制连接模块（`9c239a3d4` `3731f2e88` `a39472fab`）

**假设**：一条常驻 `tmux -C` 连接能替掉每条命令一次 fork（research §0）。先把连接本身做稳、用单测钉死协议坑，再一步步接调用点。这一步不改任何调用点，生产行为只多一个 `_mp-hub-ctl` 会话和 `/health` 里一个字段。

**改动**：
- 新文件 `cc-bridge/tmux-control.ts`：
  - `TmuxControl`：`-u [-L $MP_CC_TMUX_SOCKET] -N -C new-session -A -s _mp-hub-ctl … cat`；先进先出配对，超时保位；最老一条超 3s 判卡死 → SIGKILL，退避 1s→30s 重连；env 删 TMUX/TMUX_PANE；只认 `%sessions-changed` / `%session-renamed`。
  - `tmuxRun(argv, {timeoutMs, write, session})`：K1 开且就绪走控制连接，否则 fork-async；读命令连接层失败换 fork 重试一次，写命令不重试；写命令按会话串行。`MP_HUB_PERF_K1=0` 不建连接，tmuxRun 不用它。
  - 回包补末尾 `\n`，与 fork 的 stdout 逐字节相同，调用点换通道时不用改解析。
- hub 启动（真 tmux 且 K1 开）建连接；`/health` 加 `tmuxCtl: {state, ctl, fork}`（干跑 = `off`）。
- 顺手修了 fork 回退本身会挂死的 bug（`runTmux` / `fetchTmuxPanes`，见下面第 4 条）。

**实测踩到的坑**（research 里没有的）：
1. **开头的 `~` 在双引号里也会展开成 HOME**（`set-buffer -- "~/foo"` 读回 `/Users/susu/foo`）。quoteArg 改成连 `~` 一起转义成 `\~`。
2. 参数里的 NUL 会把参数截断（C 字符串），fork 也传不过去 → 直接拒。参数里的换行经引号转义成 `\012` 是合法的（粘贴要用），只拒命令名不合规（换行 / 空 / 拼 `;`）。
3. **SIGSTOP 控制客户端进程卡不住连接**：控制模式的 I/O 是 server 直接读写客户端交过去的 stdin/stdout fd，客户端进程停了命令照样执行、照样回包。所以「控制客户端被换出」不是卡死风险。真会卡的是 server 本身停住，或这条连接的命令队列被队头堵住。例：`run-shell` 不带 `-b` 会先回 `%end`，再堵住后面所有命令，**控制连接上永远别发不带 -b 的 run-shell**。测试 11 因此拆成 11a（队头堵塞）和 11b（SIGSTOP server）。
4. **fork 回退会挂死**：server 停住时，fork 出的客户端卡在握手里，SIGTERM 杀不掉；SIGKILL 了也不行，因为它交给 server 的 stdout fd 还卡在 socket 队列里，管道不关，`await` 一直等到 server 恢复。`runTmux` / `fetchTmuxPanes` 原来就有这个问题（TmuxState 的 inflight 会跟着挂住）。改成超时 SIGKILL 并立刻 reject。
5. `kill-server` 是异步的：紧接着 `tmux ls` 可能回 `server exited unexpectedly`，而不是 `no server running`。
6. 控制连接挂着时，fork 的 `display-message -p`（不带 `-t`）会把它当成当前客户端（`#{client_control_mode}` = 1）。hub 的 display-message 都带 `-t`，不受影响；以后有不带 `-t` 的 `#{client_*}` 格式要注意。

**测试**：`tmux-control.test.ts` 用真 tmux 加独立 socket `mp-test-<pid>-<rand>`，fork 回退经 `MP_CC_TMUX_SOCKET` 也落在这里。覆盖 research §6.3 第 1–12 条外加 K1=0；连跑 3 遍稳定，跑完无残留 server。hub.test 加了 `/health` 干跑断言。

**阻塞调用账 / bench**：不适用（没有调用点改通道）。冒烟在 scratch 里做：`TMUX_TMPDIR` 把 tmux 整个隔离进临时目录，不碰默认 socket，不连 7890。结果：
- 真 tmux hub 起来后 `/health` 显示 `tmuxCtl.state=ready`；
- K1=0 显示 `off`；
- 没起 server 显示 `down`，fork 照常，日志只打一行。

**结果**：`bun test` 717 pass / 0 fail；tsc 206（与改前相同）。

**判定**：留。

## K1-2 TmuxState 读源换控制连接（`66b1940b6`）

**假设**（research §5.1、§6.2 第 2 步）：
- 会话表每 2s 一次的 `list-panes` fork 换成走控制连接（约 1ms，不 fork）；
- 会话增删、改名靠 `%sessions-changed` / `%session-renamed` 立刻刷新；
- listen 前先拿到首份快照，hub 刚起时 `hasSession` / `list` / `paneTitles` 就不用回退同步 `execFileSync`。

只读，风险最低。

**改动**：
- `fetchPanes()`：控制连接就绪 → `list-panes` 走它；失败或没就绪 → `fetchTmuxPanes`（没起 server 算空表，带 socket 前缀）。没直接套 `tmuxRun`：它的 fork 回退在没 server 时是抛错，这里要的是空表，而且会多 fork 一次。
- hub：
  - `tmuxState.fetch = fetchPanes`；
  - 收到 `sessions-changed` / `session-renamed`、或（重）连上时 → `refresh()`；
  - 2s 轮询、`noteSpawned` / `noteKilled` 叠加层不动；
  - 首份 `refresh()` 最多等 2s 再绑 loopback（日志 `[hub] 首份 tmux 会话表 Nms`）。
- 同步回退（hasSession / list / paneTitles 的 execFileSync）这一步没删，留给第 7 步。

**测试**：
- `fetchPanes` 与 fork 的 list-panes 原文相同；K1=0 走 fork；没 server 回 `""`。
- `TmuxState` 不开轮询，单靠通知在 2s 内感知外面建 / 改名 / 杀会话。

冒烟：首份会话表 4–5ms（控制连接还在 connecting，走的是 fork）；之后的轮询走控制连接（`/health` 里 `ctl` 计数涨、`fork` 不涨）。

**阻塞调用账**：预期 `[block] tmux has-session` / `tmux ls` / `tmux list-panes`（hub 刚起、快照过期时的同步回退）降到接近 0，要上生产后看现场账。

**结果**：`bun test` 719 pass / 0 fail；tsc 206。

**判定**：留。

**留下的边界**：
- `refresh()` 会复用进行中的那一轮。通知恰好落在一轮已经发出的 list-panes 之后时，这次变化要等下一次 2s 轮询（与改前相同；控制连接上一轮约 1ms，窗口很小）。
- 控制连接退避最长 30s。server 比 hub 晚起来时（她第一条消息才 spawn），最多 30s 后才切到控制连接，期间全走 fork。第 6 步可以在 spawn 成功后让连接立刻重连。
- `_mp-hub-ctl` 会出现在快照和 `tmux ls` 里（R10），hub 的前缀过滤碰不到它。

## K1-1 / K1-2 审查 R1（astra）：四条已修，返工另撞出一条 tmux 崩溃（`e0871f1c2` `2d4be67ef` `f27772052` `9df69df0d`）

1. **P1 hook 的块错配请求队列**（`e0871f1c2`）。tmux 全局 hook（command-error、after-new-session…）会产生 `%begin … 0` 块；旧代码对每个块都 `queue.shift()`，回包整体错位，fetchPanes 拿到错位内容 → TmuxState 缓存空表。
   - 修法：按 `%begin` 的 flags 分。只有 flags=1（stdin 发的命令）消费请求队列；argv 里 `new-session -A` 的回复是第一个 flags=0 块，单独消费一次；之后的 flags=0 块丢弃。
   - 实测：hook 的输出有的是 flags=0 块，有的（session-created）是块外的裸行，后者走通知分支被忽略。
   - 回归：四个 hook 下重新 attach、出错命令加并发请求、建会话的同时 fetchPanes / TmuxState 不变空。旧代码上跑红。
2. **P2 超时漏 fd**（`2d4be67ef`）。
   - 修法：`readText()` 手动拿 reader；超时时 SIGKILL 加取消两个 reader，立刻释放 fd。`TmuxControl.drop()` 走完整清理：关 stdin、取消 stdout / stderr 的读。
   - 回归：server SIGSTOP 期间 12 次超时，fd 增量 ≤3（旧代码 +20）。
3. **返工时撞出的崩溃：server 停住期间杀掉握手中的控制客户端，tmux 3.6a 恢复后 segfault**（同 `2d4be67ef`）。
   - 现象：旧实现 attach 超时就 drop + SIGKILL，退避后再起一个。server 恢复后，给这些「死在握手里」的客户端发 session-created / client-detached 通知时，`control_write` 空指针崩溃，整个 server 连同所有会话一起没。
   - 证据：DiagnosticReports 今天 11 份 tmux 崩溃栈全是测试 server（pid 对得上），生产 server（10-06 起的那个）没受影响。
   - 隔离复现：杀握手中的客户端 4/4 崩；杀已 attach 的 / 只关 stdin / 不杀，都是 0/4。
   - 风险：她机器 swap 打满、server 卡住超过 3s 时就会走到这条路。
   - 修法：attach 慢只记一行、接着等，不杀也不重连（期间 tmuxRun 走 fork）；`drop()` 只 SIGKILL 已经 attach 上的，握手中的只关 stdin。
   - 回归：同上一条，并且恢复后建会话，server 仍然活着。
4. **P2 fork 回退的 `;` 语义**（`f27772052`）。fork 的 argv tmux 也会解析末尾的 `;`。
   - 修法：forkRun 把以 `;` 结尾的参数末尾写成 `\;`。
   - 回归：9 个含 `;` 的参数在 K1 开 / 关两档的 round-trip 一致。
5. **P2 K1=0 仍等首份会话表**（`9df69df0d`）。
   - 修法：等待只在 K1 开时做；K1=0 和干跑时，loopback 同步绑定、refresh 后台跑，与 K1 之前一致。

**另一个发现（没修，不在本刀范围）**：server 停住时，hub 启动卡在同步 `execFileSync("tmux", ["ls"…], {timeout: 3s})` 上 8s 以上，K1 开关两档都一样。原因是 execFileSync 超时发的是 SIGTERM，停住的 server 面前客户端杀不掉（同 K1-1 坑 4）。这是现有同步回退的冻结来源之一，第 7 步删同步回退时一并消掉；在那之前如果要止血，需要 `killSignal: "SIGKILL"` 并且实测 spawnSync 会不会等管道 EOF。

**结果**：`bun test` 722 pass / 0 fail；tsc 206；`tmux-control.test.ts` 19 条连跑 4 遍稳定，没有新增崩溃报告。

**待办（不在本刀）**：第 6 步 spawn 成功后让控制连接立刻重连（现在退避最长 30s）。

## 基线 · 空闲档（`337b5f09f` `189d932c5` `5f59cece0`）

**测量台**：`cc-bridge/scripts/bench-hub.ts`（plan §3.3）。每组起一个新 hub（`MP_HUB_PERF_K1` 进程启动读一次），隔离 tmux server 里 27 个 `mp-cc-benchNN` 会话跑假 CC（`/bin/sh` 读一行、把这一行追加进日志、回一行 `ok`）。每组：等 `/health` 通（K1=1 再等 `tmuxCtl=ready`）→ 静置 3s → 热身一轮丢掉 → 12 轮。每轮依次：
- **A 连上**：`new WebSocket` → open，随即发 `client_info`。另记收到 `hello` 的时刻。
- **B 终端出字**：发 `terminal_attach`（46×40）→ 收到 `terminal_init`，然后发 `terminal_detach`。
- **C 发消息**：发 `send` 帧 → 假 CC 读到这一行，也就是文本进了输入框并且回车了。另记 `ack` 到达的时刻。

轮间隔 300ms，会话按轮号轮换。卡顿和阻塞账取自 `MP_HUB_BENCH=1` 时 `/health` 的 `bench` 字段，只算测量窗口内的。每组末尾用 `capture-pane -J` 抽验最后一条消息确实进了 pane。

```
cd cc-bridge && bun scripts/bench-hub.ts --rounds 12 --sessions 27 --k1 1,0,1,0 --profile idle --out <json>
```

**和 plan 写法的出入**：
- tmux 隔离用 `TMUX_TMPDIR=<临时目录>`，没用 `-L mp-bench`。hub 里的同步 `execFileSync("tmux", …)` 不认 `MP_CC_TMUX_SOCKET`，只有 TMUX_TMPDIR 能把所有 tmux 调用都关进去。
- 会话直接按手机尺寸建（`-x 46 -y 40`），所以 B 测的是**不 resize 的常态路径**。第一次 attach 会 resize 并多等 250ms，那一档没测。
- C 只测短单行（send-keys -l + Enter），多行 / 长文本的粘贴路径（load-buffer + paste-buffer + 0.5s settle）没测。

**隔离逐项**（读码 + 实跑核过）：

| 项 | 做法 | 核实 |
|---|---|---|
| 端口 | 随机空闲端口（≠7890），`MP_CC_HUB_HOST=127.0.0.1`，只绑 loopback；bench 只连这个端口 | hub 日志 `bound: 127.0.0.1` |
| 7890 | bench 不对 7890 发任何请求；前后各用 `lsof -t` 只读看监听进程 | 47211 → 47211 |
| 粟粟默认 tmux | 不碰；前后只读 `tmux ls` 计数 | 30 → 30（两次正式跑 + 两次冒烟都没变） |
| tmux 隔离 | hub 的 env 是白名单拼的（不继承本 shell 的 `TMUX` / 代理 / 口令 / `CLAUDE_*`），`TMUX_TMPDIR=<root>/tmux`；fork、`execFileSync`、控制连接都走这个 socket。结束只在 socket 位于 root 下时 `kill-server` | 跑完 `TMUX_TMPDIR=… tmux ls` 显示 no server |
| 数据 / secrets | `MP_CC_SECRETS_DIR` 每组一个新目录：session-map、reply-log、push-tokens、la-tokens、connect-ledger、agora.sqlite、hub-config 都写在这里 | 临时目录里只见 agora.sqlite*、la-phase.json |
| HOME | `HOME=<root>/home`：`homedir()`（Bun 认 HOME）下的 `~/.claude/projects`、`~/.vibe-island`、`~/.mp-warroom`、`~/.cc-bridge` 都落到假家 | 假家里只有 bun 缓存 |
| 工作目录 / spool | `MP_CC_WORKDIR`、`MP_CODEX_WORKDIR`、`MP_CC_THINKING_SPOOL`、`CC_MEMORY_SYNC_DIR`、`MP_CC_AGENT_DIR`、`MP_PM_Q`、`MP_AXISMUNDI_DIR` 全部指向临时目录；hub cwd 也是临时目录（不读 `cc-bridge/.mcp.json`） | — |
| 终端 fifo | `TMPDIR=<root>/tmp`（pipe-pane 的 `cc-bridge-*` 目录建在这里） | — |
| APNs | `MP_APNS_KEY_PATH` 指向不存在的文件（apns.ts 走 cert-missing，push disabled），`MP_APNS_HOST=https://127.0.0.1:9` 兜底；store 里没有 token | hub 日志 `[apns] cert not found … push disabled` |
| 不拉起真 claude / codex | ① 只往现成会话发：hub 从会话表看到会话在，就直接注入，不 spawn；② 假 `claude` / `codex` 放在 PATH 最前（tmux server 的 PATH 也是它；hub 前缀的 `/opt/homebrew/bin` 里没有 claude）；③ `MP_CC_DEFAULT_TRANSPORT=tmux`（不走 stream 直起 claude）；④ hub 日志出现 `spawned tmux:` / `stream spawn`，或假程序被调用过，都判 RED | 4 组全 GREEN |
| 其他后台 | `MP_CC_WARROOM=0`、`MP_CC_NUDGE_ENABLED=0`、`MP_CC_KEEPALIVE=0`、`MP_CC_RELAY_CONNECTOR=off`（也没有 relay.json）、`MP_CC_LA_INTERVAL_MS=3600000`、`MP_PM_URL=http://127.0.0.1:9`、`MP_CLAUDE_BIN=<假 claude>` | — |
| 清理 | hub SIGTERM → 5s 后 SIGKILL；退出时（含 SIGINT）kill 自己的 tmux server，删临时目录 | 跑完无 `mpbench-*` 残留 |

唯一的 hub 改动是 `MP_HUB_BENCH=1` 时 `/health` 多带 `bench: {lags, block}`。默认关，hub.test 断言不开时没有这个字段。

**环境**：10-10 12:47 和 12:48 各跑一次（ABAB × 12 轮）。负载 `1.56–2.27 / 1.77–1.91 / 1.89–1.94`，swap `used 7492M / 9216M（free 1723M）`，没有编译在跑。**这不是粟粟的现场条件**（现场是负载 40–200、swap 打满）：这份是「机器闲」的下限，K1 等刀的收益要看压力档。

**结果（第 1 次，ms；n=12 时 p95 就是第 12 个样本 = max）**

| 组 | K1 | A p50/p75/p95 | B p50/p75/p95 | C p50/p75/p95 | loop lag >200ms |
|---|---|---|---|---|---|
| g0 | 1 | 1 / 1 / 1 | 24 / 26 / 28 | 13 / 14 / 16 | 0 |
| g1 | 0 | 1 / 1 / 2 | 26 / 27 / 30 | 13 / 14 / 16 | 0 |
| g2 | 1 | 1 / 1 / 1 | 24 / 25 / 28 | 14 / 14 / 16 | 0 |
| g3 | 0 | 1 / 1 / 2 | 25 / 25 / 26 | 13 / 14 / 16 | 0 |
| **K1=1 合并 24** | | 1 / 1 / 1 | 24 / 25 / 28 | 14 / 14 / 16 | 0（max 0） |
| **K1=0 合并 24** | | 1 / 1 / 2 | 25 / 26 / 28 | 13 / 14 / 16 | 0（max 0） |

第 2 次合并：K1=1 B 25/26/27、C 14/14/16；K1=0 B 25/26/28、C 14/14/16；A 全是 1–2；loop lag 全 0。

**噪声带**（同档两组 p75 相对差）：
- B 0–8%、C 0%、ack 0–7%。
- A / hello 都在 1–2ms，整数毫秒下 1→2 就算 67%，相对差没有意义，看绝对值（≤1ms）。

**阻塞调用账**（每组 12 轮，各组几乎一样，以 g0 为例）：
- `tmux pipe-pane` ×24（attach 开、detach 关各一次），共 121ms，单次最长 7ms；
- `tmux send-keys` ×24（文本 + Enter），共 86ms，单次最长 5ms；
- `mkfifo` ×12，共 31ms；
- 其余（mkdtemp / unlink / readdir spool）≈0。

没有 ≥500ms 的 `[block]` 行。

**读法**：
1. **K1=1 和 K1=0 在空闲档分不开**：B、C 的差都在噪声带里。这是预期的，K1 现在只把会话表读源换成了控制连接（第 2 步）；B 的 display-message / capture（fork 异步）、pipe-pane，C 的 send-keys（同步 execFileSync）都还没切（第 3–6 步）。
2. **B ≈ 25ms 基本全在 hub 里**：`terminal_init` 带回的 hub_ms 比客户端测到的只少 0.7ms。分步大约 `size` 7–9ms（fork 一次 display-message）、`pipe` 9–12ms（mkfifo + pipe-pane 两次同步 fork）、`capture` 5–7ms（capture + display 并行两次 fork）。每一步都是 fork tmux，正好是 K1 要砍的东西。
3. **C ≈ 14ms 是两次同步 send-keys**，ack 只比「CC 收到」早 0.75ms。ack 在注入之前就 `ws.send` 了，但帧要等这一轮事件循环结束才真正写出去，而 send-keys 的 execFileSync 在同一轮的微任务里跑完。所以**手机看到「已送达」的时刻实际被同步 tmux 写拖住了**。机器卡时 send-keys 要几百毫秒，ack 会跟着晚到；K1 切到异步通道之后这一点应该自己消失，到时用 bench 验证。
4. A ≈ 1ms，hub 空闲时握手不是瓶颈；现场 A 慢都来自主循环被别的东西卡住（看压力档）。

**顺手发现（没修，不在本刀）**：`closeTerminalAttachment` 只删 fifo 文件不删目录，每开一次终端就在 TMPDIR 留一个空的 `cc-bridge-XXXXXX/`。粟粟机器的 TMPDIR 里现在约 417 个（另有 180 个 `cc-bridge-test-secrets-*` 是测试留的）。

**压力档：只实现，没跑**（要先问粟粟）：
```
cd cc-bridge && bun scripts/bench-hub.ts --rounds 12 --sessions 27 --k1 1,0,1,0 --profile stress --confirm-stress --out <json>
```
- 起 100 个 `perl` 忙等进程，10 核机器上负载会爬到 ~100。
- 再起一个 bun 吃内存进程：256MB 一块往上加，目标 4G（`--stress-mem-gb`）；每加一块前看 swap 余量，<1.5G 就停；之后每 10s 把每页摸一遍保持常驻。
- 等 5 分钟负载 >80（`--stress-load`），最多等 15 分钟，然后跑 4 组。
- 所有压力进程自带截止时间（ramp 上限 + 组数 × 估时 + 5 分钟），bench 崩了也会自己退；正常结束、Ctrl-C 都会立刻 SIGKILL。
- **对整机的影响**：预计 15–25 分钟里 CPU 被吃满（爬到 5 分钟负载 80 约 8–10 分钟，加 4 组测量）。她的 CC 会话、手机连生产 hub、终端出字、正在跑的编译都会明显变慢。内存那块受 swap 余量闸限制：现在 swap 只剩 ~1.7G，实际大概只加得上 0–1 块，主要压力来自 CPU。只在她不用机器的时段跑。

**判定**：测量台可用，空闲档基线已存。下一步：问粟粟挑时段跑压力档 → 审查 R1（口径）→ K1 第 3 步起每步用 bench 对比 B / C 的 p75。

## 基线 · 压力档（10-10 13:40–13:44，粟粟批准开跑）

命令：`bun scripts/bench-hub.ts --rounds 12 --sessions 27 --k1 1,0,1,0 --profile stress --confirm-stress`（粟粟手动起，自动模式拦了代跑）。原始 JSON：scratchpad `bench-stress-1.json`。

- 压力：100 个忙等进程，爬坡 230s 到负载 144–147（5 分钟 81–86）。吃内存那块被 swap 闸挡住（swap 7.1G/8.0G，余 1.0G <1.5G），**基本没加上内存压力**。
- 隔离核对：默认 tmux 31→31，生产 hub pid 26281→26281。

| | A 连上 p50/p75/p95 | B 终端出字 | C 发消息 | loop lag >200ms |
|---|---|---|---|---|
| K1=1（g0+g2，24 轮） | 0/1/4 | 28/30/34 | 18/20/26 | 0 |
| K1=0（g1+g3，24 轮） | 0/0/2 | 26/27/38 | 19/21/28 | 0 |

噪声带（同档两组 p75 差）：B 3–18%，C 0–5%。两档差都在噪声里。同时段生产 hub 也 0 次 loop lag。

**结论（重要）**：**纯 CPU 打满（负载 145）复现不了粟粟的几秒级卡顿**——B 只从空闲 25ms 涨到 ~28ms。现场卡顿（10:47–10:55 1–11s、06:38 73s、05:40 313s）都发生在 **swap 打满**时，病因主要是内存：hub 堆 / tmux 二进制页被换出，每次事件和每次 fork+exec 都要换页。bench hub 是新进程、页都在内存里，所以测不出。
- 推论：K1 的价值在「少 fork」（fork+exec 在换页时最贵），但必须在**内存压力**下才量得出；而在粟粟这台 swap 余 1G 的机器上人工造内存压力，等于故意让她的 CC 全部换页——不做。
- **改用现场尺**：阻塞调用账 13:3x 已上生产，之后每条 `loop lag` 都带「其中 X；其余（GC / 换页 / JS）」。攒几次现场卡顿再定：「其余」占大头 → 内存线（K4 优先级 + hub 常驻内存瘦身 / 少触碰冷数据）先于 K1 第 3 步；`tmux …` 占大头 → 继续 K1 第 3 步。
- 生产阻塞账第一份 top（重启后几分钟）：`fs.readFileSync bind-config.json` ×20 共 309ms 最长 149ms、`fs.statSync *.jsonl` ×784 共 152ms 最长 133ms、`fs.readdirSync receipts` ×19 最长 48ms——都是不该在热路径上反复做的同步盘读，属 K3 范围。

## K1-3 终端路径走控制连接（`8d8d7ba43` `e1d377dbe`）

**假设**：10-10 10:47 粟粟开 mp-cc-66 终端 7.8s，其中 hub 5.3s 全花在三次 fork tmux（size=644 pipe=986 capture=3657ms）。swap 打满时每次 fork+exec 都要换页。终端路径（操作 B，加上键入 / 粘贴 / resize）改走常驻控制连接，开终端就不再 fork tmux，主循环上也不再有同步 tmux（research §6.2 第 3 步）。

**改动**：
- 以下全部改 `tmuxRun`：
  - `terminal_attach` 的 size（display-message）、resize-window、pipe-pane 开、capture-pane、display-message；
  - `closeTerminalAttachment` 的 pipe-pane 关；
  - `terminal_resize`；
  - `terminal_input` 的 `send-keys -H`。

  写命令（send-keys、resize-window、pipe-pane 开关）带 `{write, session}` 走按会话写链，读命令走读。K1=0 时 tmuxRun 回退 fork-async，不恢复 execFileSync；send-keys -H / resize / pipe-pane 原来是同步的，改成异步属于本刀。
- `terminal_paste`：`pasteToTmux` 本身没动，仍是同步 fork 的 load-buffer + paste-buffer（set-buffer 留到第 5 步）。但它排进了同一条写链（`tmux-control.ts` 抽出 `chainTmuxWrite`），**K1-0 时序风险 7 兑现**。顺带用上 `MP_CC_TMUX_SOCKET`（生产没设，等于不变）。
- `mkfifo` 改用 `runProcess` 异步跑（就是原来的 `spawnTmux`：超时 SIGKILL + 取消 reader）。
- 关终端时删整个 `cc-bridge-*` 目录（原来只删 fifo，粟粟 TMPDIR 已积了 417 个空目录）；开失败也删。
- 解析不变（控制连接回包已补末尾 `\n`）；seq/stale 检查、`hub_ms` / `hub_steps`（size/resize/pipe/capture）都保留。

**开 pipe 变异步后补的时序**（原来同步一步做完，没有这些窗口）：
1. 同一会话并发两个 attach（两台设备 / 重连）→ 只开一套：`openTerminalAttachment` 复用正在进行的那次。不这样做的话，两个会各自 `pipe-pane -o`，第二个是空操作，它的 cat 永远等不到写端。
2. 开 pipe 期间 detach / 断开（那时这套还没进表，detach 摘不到）→ 回来发现 stale 且没人看，就关掉。
3. 等的这段时间这套被别人关了（同一套的另一个等待者 stale 后关的）→ 再开一次，不回 `terminal_error`（客户端会把它当 OFFLINE）。
4. cat 退出时只关自己那套：关 pipe 是异步的，这期间同一会话可能已经开了新的一套。
5. 关 pipe 排进写链：之后再开的 `pipe-pane -o` 一定排在它后面，不会被它关掉。先后顺序与原来一致：先关 pipe，再杀 cat，再删目录。

**测试**：新文件 `hub-terminal.test.ts`（真 tmux，独立 socket），3 条：
- 输入 / 粘贴交错 7 次（`aBcDeFg`），控制连接和 fork 回退两档都按调用顺序到达。**去掉写链时实测是红的**：到达顺序变成 `BDFaceg`，同步粘贴插到了排着队的键入前面。
- attach 一整套：pipe-pane 开走控制连接（ctl +1、fork +0）→ `send-keys -H` 键入 → pipe 流里出字 → capture 里有、末尾带光标复位 → 关掉后 `#{pane_pipe}`=0、cat 退出、fifo 目录删掉。全程 fork 计数不动。
- 并发两个 attach 拿到同一套，只建一个目录；会话不存在时开失败，目录也删掉。

`bun test` 725 pass / 0 fail（这轮 agora round_robin 没抖）；tsc 206（不变）。

**bench 空闲档**：10-10 13:57、13:58 各跑一次 ABAB × 12 轮。负载 3.9 / 8.5 / 17，swap 7.1G/8.0G。命令同基线，`--profile idle`。

| | B p50/p75/p95（第 1 次） | B（第 2 次） | C（第 1 次 · 第 2 次） | loop lag >200ms |
|---|---|---|---|---|
| 基线（K1-2 之后，两档合并） | 24–25 / 25–26 / 27–28 | | 13–14 / 14 / 16 | 0 |
| **K1=1** | **5 / 7 / 8** | **4 / 6 / 10** | 11/12/14 · 7/11/16 | 0 |
| K1=0 | 16 / 24 / 28 | 25 / 28 / 31 | 9/9/12 · 11/12/12 | 0 |

B 分步 p50（hub_steps，两次合看，ms）：

| | size | pipe | capture |
|---|---|---|---|
| 基线 | 7–9 | 9–12 | 5–7 |
| K1=1 | 0 | 2–5（只剩 mkfifo 一次异步 fork + 一个微任务） | 0–1 |
| K1=0 | 4–8 | 7–12 | 4–6 |

**阻塞调用账**（每组 12 轮）：

| 调用点 | 基线 | K1-3（两档相同） |
|---|---|---|
| `tmux pipe-pane` | ×24（开 + 关），共约 121ms | **0** |
| `mkfifo` | ×12，共约 31ms | **0** |
| `fs.unlinkSync` fifo | ×12 | 0（改成异步删目录） |
| `tmux send-keys` | ×24 | ×24，不变。这是 C 的发消息路径（`send-keys -l` + Enter），属第 4 步；bench 不发 terminal_input，键入那条由上面的单测钉住，不再 fork |
| `fs.mkdtempSync cc-bridge-` | ×12，约 1–2ms | ×12，约 1–2ms（留着，不 fork） |

**读法**：
1. **K1=1 的 B p75 从约 25ms 降到 6–7ms**，两次都是。空闲机器上 fork 一次 tmux 约 4–8ms，原来开一次终端要串着走 4–5 次 fork；现在控制连接往返 <1ms，剩下的是 mkfifo 那一次异步 fork。现场（swap 打满）每次 fork 是几百毫秒到秒级，省掉的正是那 3–4 次（10:47 那次的 5.3s）。
2. K1=0 档的 B 和基线持平（p75 24–28），区别只是这些 tmux 调用不再占主循环：阻塞账里 pipe-pane / mkfifo 两档都归零。
3. C 两档都在噪声里（第 1 次 K1=1 略高，第 2 次 K1=0 略高），这刀没碰 C。`tmux send-keys` 的 24 次同步调用就是 C 剩下的全部阻塞，是第 4 步的目标。
4. 噪声带：K1=1 档 B p75 的绝对值只有 5–7ms，整数毫秒下相对差 33–91% 没有意义，看绝对值（同档两组差 ≤4ms）；K1=0 档 B 4–40%（第 1 次 g1 / g3 差 8ms）。

**判定**：留。现场收益要等上生产后看终端出字账本（`terminal_report` 的 `hub_ms` / `hub_steps`）。

**留下的边界 / 给后面的步骤**：
- `pasteToTmux` 还是同步 fork：`load-buffer -` 走 stdin，在控制连接上无效（R4）。第 5 步换成 `set-buffer --` + `paste-buffer`；>64KB 走 fork-async（R5）。注意 fork 的 argv 上限约 1MB，1MB 的粘贴只能 load-buffer，或分块 `set-buffer -a`。
- 现在的写链是「tmux 写」链，和 `chainSessionSend`（发消息链）是两条：同一会话上她在终端里打字、同时手机发消息，两边的字可能交错。原来也是这样（键入同步直调，发消息走另一条链）。第 4 步可以考虑让 `realPasteIO` 的 tmux 写也进 `chainTmuxWrite`，但 job 粒度要是单条命令，别把整段 paste settle 的 sleep 包进去，否则键入会被堵上秒级。
- `chainTmuxWrite` 的 job 里不能再对同一会话 `tmuxRun` 写：会排在自己后面，死锁。已写进注释。

### K1-3 审查 R1（astra）：两条已修（`ee2332c61`）

1. **P1 pipe 开关失败后丢了生命周期状态**。
   - 触发：控制连接在 `pipe-pane` 开的回包前断了；或者关命令还没发出去连接就 down 了。
   - 后果：原代码照样删目录、摘 attachment、杀读端，server 上 `pane_pipe=1` 残留。下次 `pipe-pane -o` 遇到已有 pipe，只把旧的关掉就返回，不开新的（tmux 的 -o 是开关语义）。于是重开「成功」，但 `pane_pipe=0`，客户端只有快照、没有增量。开失败那条路还会留下卡在 FIFO open 上的 `cat > fifo`。
   - 修法：
     - **开 pipe 不带 -o**：不带 -o 的 `pipe-pane` 先关旧的再开新的，一条命令原子完成。上次没关掉的、hub 崩过留下的，都会被顶掉。比「先查 #{pane_pipe}、再关、再开」少两次往返，也没有中间窗口。
     - **读端 `cat fifo` 先起，再开 pipe**：阻塞在 open 上的读端也算读端，tmux 那头的写端一起来就能 open 成功，不会卡死。开失败（结果不明）时：先在链内 `closePanePipe` 关掉并确认，再立刻杀读端、删目录。写端这时要么读到 EOF 退出（pipe 已关），要么下次写时 SIGPIPE 退出。
     - **关 pipe 改走 `closePanePipe`**：失败不吞，先查 `#{pane_pipe}`（断了的连接，下一条会走 fork），还开着就再关一次。会话已经没了算关上。还是确认不了就记一行；下次开 pipe 不带 -o，会顶掉它。
   - 回归：开的回包前断、关的命令发出前断，两种都验 `pane_pipe` 正确、没有残留的 fifo 进程（`ps` 里查测试目录）、目录已删、再 attach 后 pipe 流里能出增量。另验 pane 上挂着别人的 pipe 时照样能开上。**这三条在旧代码上全红。**
2. **P2 读尺寸绕过了写链**。
   - 触发：手机 52 列的 resize 排在没跑完的写后面；手机随即 detach，恢复逻辑读到窗口是 80 列，跳过。之后旧的 52 列 resize 才执行，窗口停在 52x24。
   - 修法：改成 `syncWindowSize(session, target)`，读、比、改放在同一会话写链的一个 job 里。目标尺寸在 job 执行时按当时的设备重新算；链内的 resize-window 不带 session，不再入链（入链会排在自己后面，死锁）。attach、`terminal_resize`、detach / 退后台 / 断开后的恢复都走它。`terminal_resize` 原来是不比较直接 resize，现在先比，尺寸相同就不发。
   - 回归：先用一个写挡住链，排一条「手机还在」的 resize，然后手机离开、再排恢复，放行后两条都返回 false，窗口是 80x24。

**另记（不做，待办）**：写链没有上限，排队时间也不算进单条命令的 timeout，所以不保证总等待时长。tmux server 卡住时，同一会话后面的键入 / 粘贴 / resize 会一条条排着，每条各自超时。真要兜底，得给 `chainTmuxWrite` 加「排队超过 N 秒直接拒」或者队长上限，另开一刀。

**结果**：`bun test` 739 pass / 0 fail（含分支上新进的 session-reap 用例）；tsc 206；hub-terminal.test.ts 7 条连跑 3 遍稳定，跑完没有残留进程，测试 socket 文件也删了。

**bench 空闲档复测**（14:47，1 分钟负载 6–8，但 5 分钟负载还在 77：别的 session 的编译刚停）：

| | B p50/p75/p95 | B 分步 p50（size / pipe / capture） | ctl / fork 计数 |
|---|---|---|---|
| K1=1 | 3 / 4 / 26 | 0 / 2–3 / 0 | 68 / 1（与改前相同：正常路径没多发命令） |
| K1=0 | 21 / 26 / 38 | 3–7 / 5–13 / 3–8 | 0 / 69–70 |

B p75 没有回退（改前 6–7）。p95 被负载尾巴拖高：紧接着又跑了一次，负载爬回 18→39，K1=1 p75 15、K1=0 p75 60，只能当噪声看，没采用。阻塞账同改前：`tmux pipe-pane` / `mkfifo` 为 0，剩下的 `tmux send-keys` ×24 来自 C。

## K3 热路径同步盘读（`12ab48d30` `76d1fdacb` `942c2c868` `fe6390597`）+ 尺子补全（`5d39eb324` `db8e68636`）

**假设**：生产阻塞账（13:34 重启后约 35 分钟）前四名全是定时器上的同步盘读，合计约 15.8s。机器 swap 打满时单次 0.5–1s，每次都卡住整个主循环。这些读要么能异步，要么根本不用读。

**每个调用点**（改前数字是现场 35 分钟的累计）：

| 调用点 | 改前（现场） | 来源 | 改法 | 预期 |
|---|---|---|---|---|
| `fs.statSync *.jsonl` | ×3827，共 7047ms，最长 557ms | ① `toolActivityTick` 每 3s 对每个 working 会话同步 stat 两次（tick 一次 + `refreshToolActivity` 一次），卡了几天的旧 working 也照 stat ② `broadcastSessionPhase` 收尾时同步 refresh（stat + 读尾巴 256KB）③ `laWatchdogTick` 每 3 分钟对挂岛会话 stat | `tool-activity.ts` 新增 `ToolActivityTracker`：stat 走 fs/promises，读尾巴走 `readTailAsync`；同一会话的刷新串行；send 换轮后，在途的旧结果作废。tick 改成 async 并防重入，每会话每次 tick 只 stat 一次；半小时没动的 working 隔 60s 才 stat 一次，而且不读。非 working 的 phase 帧等读完再发；读的过程中 phase 又跳了，这帧就不发。看门狗改 async，只 stat 还在 working 的挂岛会话 | 同步次数降到约 0（只剩 spawn codex 时收割会话 id 的那一次）。异步 stat：活跃的每会话每 3s 一次（原来两次），卡住的每 60s 一次（原来每 3s 一次） |
| `fs.readdirSync receipts` | ×98，共 3635ms，最长 1091ms | `scanReceipts` 每 30s 同步列 `~/.mp-warroom/receipts`。**目录是空的**，耗时全是换页延迟 | `scanT1Receipts`：先从账本查在等收据的单（dispatched / working），只异步读这些单各自的 `<task_id>.json`；没单在等就完全不碰盘。读完再跑验收官，原来同一 tick 里先收据后开庭，顺序不变 | 平时 0 次盘操作 |
| `fs.readFileSync bind-config.json` | ×99，共 2754ms，最长 263ms | 30s 自愈重检每次同步读 | `hub-config.ts` 新增 `BindPrefsCache`：启动时同步读一次，set_bind 写盘时一起更新缓存。重检先异步 stat，mtime 变了（手改了文件）才异步重读；重读期间如果 set_bind 过，这次读数作废 | 同步 1 次（启动）。之后每 30s 一次异步 stat |
| `fs.readdirSync thinking-spool` | ×149，共 2346ms，最长 287ms | `drainThinkingSpool` 每 20s 同步列目录，平时是空的 | 全改 fs/promises。新增 `dir-watch.ts` 的 `DirtyDirScanner`：fs.watch 看到目录有动静才置脏，20s tick 只在脏的时候扫；扫完还留着的文件（刚写不到 15s / 补投失败）保持脏；watch 挂不上就每个 tick 都扫（等于原行为）；挂上了也每 5 分钟兜底扫一次 | 同步 0 次；平时 5 分钟一次异步 readdir |
| `tmux ls` | ×1，968ms | **启动时一次性**：`startHub` 里的 `agoraSafe("pump@boot")` → `listAvailableActors` → `listSessions` → `realTmuxRunner.list()`。这时首份 tmux 快照还没开始取（`firstTmuxSnapshot` 在 startHub 更后面），回退到同步 `tmux ls`。启动之后只有快照过期 >10s（主循环卡过）才会再回退 | **本刀不改**。留给 K1 第 7 步：agora 的启动 pump 挪到首份快照之后，或者 list 在没有快照时回 lastKnown | — |

`tmux send-keys`（×4，最长 847ms）属 K1 第 4 步，没动。

**语义放宽**（都列在这里，审查时逐条看）：
1. 进度卡工具数：transcript 半小时没动的 working 会话，60s 才看一次。卡住的会话如果又动起来，工具数最多晚约 63s 出现。原来是 3s。
2. 「做完了 / 等你」这类非 working 的 `session_phase` 帧，现在等异步读完尾巴再发，平时晚几毫秒；swap 时晚的就是读盘那段时间，但主循环不再被卡住。所以它可能排在同一时刻的 reply 帧后面，原来排在前面。读的过程中 phase 又变了，这帧就不发（新 phase 那一帧自己会发）。
3. 看门狗：判定用的 mtime 是异步拿的，晚几毫秒；LA scheduler tick 照旧排在看门狗之后。启动对账那行 `la phase restored … timed_out=` 日志晚一点打出来。（R1-2 后：逐会话串行 stat，判超时的会话多 stat 一次确认，一轮总时长 = 各会话 stat 之和。）
4. T1 收据：~~只看 dispatched / working 各最近 500 单……效果一样~~ **这句原来写错了**（审查 R1-3）：只看最新 500 单时，较新的 500 张一直不结案，旧单有收据也永远读不到，不是「效果一样」。现在按 task_id 游标轮转扫全部等待单，一轮最多 500 单；等待单超过 500 时，一张收据最多晚 ⌈N/500⌉ 轮（每轮 30s）才被收下。收据异步读完才跑验收官；上一轮没读完，下一 tick 整轮跳过（R1-6）。
5. bind-config：启动时读的时机比原来早（startHub 开头，原来是 loopback 绑完之后）；manualHost 模式也会读一次（原来不读）。手改文件靠 mtime 发现，下一个 30s 重检生效，和原来一样。mtime 被刻意改回原值的手改会漏掉。读 / 解析失败时保留上次有效的开关（R1-4；原来是失败当默认全开）。
6. thinking 待投：watch 正常时延迟和原来一样（下一个 20s tick + 15s 安全期）。watch 漏事件 / 目录被删了重建，最坏 5 分钟兜底。hub 启动时会先 mkdir 待投目录。

**尺子补全**（零行为改动）：
- `block-ledger.ts` 统一放 hub 进程共用的 `blockLedger` 单例和这些包装：`timedFs` / `timedSyncFs`（带模块前缀）、`timedExecFileSync`、`timeSqlite`、`timeHandler`。hub.ts 改用它们。
- 覆盖到的模块：
  - sqlite：warroom 库（indexer + ledger 共用）、agora 库。站点 `sqlite <库> <动作 表>`；语句的 run / get / all / values 都算，exec / run 也算（agora 的 BEGIN / COMMIT 单独成站点）。
  - warroom-indexer 的 fs 和 execFileSync（ps / tmux list-panes 普查）。
  - 同步 fs 加上模块前缀：connect-ledger、turn-extract（readTail）、terminal-usage、la-phase、la-tokens、push-tokens、askuser、terminal-windows、hub-config、cc-memory-sync、book-notes、voice-calls、agent-runner、budget、triggers、trading-research、apns、warroom-dispatch、pm-relay、cc-workdir、reader-daemon。
  - reply-log / thinking-log / session-map 本来就在 hub.ts 的账里。
  - 没碰：K1 的 tmux 路径（tmux-control / tmux-state / terminal-paste）、session-reap、relay-*、mcp-server（另一个进程）。
- WS 处理：`/cc` 每条消息按 type 记 `ws <type>`，例如 `ws client_info`、`ws set_cc_config`、`ws focus`、`ws register_push_token`、`ws register_la_token`。连上那一段（replay / 补投 / phase 快照）记 `ws connect /cc`。`/mcp` 记 `mcp <type>`。只量同步段（到第一个 await 为止），≥50ms 才记。
- 卡顿归因的「其余」改成按区间并集算：ws 处理和它里面的 fs 调用会重叠，不能重复扣。
- loop lag ≥1s 的那行末尾追加 `｜CPU xms/窗口ms、硬缺页 +n、堆 a→bMB（回收过）、rss`。读法：
  - CPU 远小于窗口、硬缺页多 → 在等换页；
  - CPU ≈ 窗口、堆掉了 → GC；
  - CPU ≈ 窗口、堆没掉 → JS。
  - 数据来自 `process.resourceUsage()` + `memoryUsage()`，每 500ms 采一次，单次约 1µs。Bun 拿不到 GC 次数，用「堆掉了」代替。

**测试**：新增 / 扩充 `tool-activity.test.ts`（tracker 5 条）、`hub-k3.test.ts`（收据）、`hub-config.test.ts`（bind 缓存 2 条）、`dir-watch.test.ts`（3 条）、`block-ledger.test.ts`（并集 / 包装 / sqlite / handler / 体征 5 条）。`bun test` 754 pass / 1 fail，fail 的是已知抖的 agora round_robin（单跑 8 次挂 2 次，`Cannot mention @alice`）；tsc 206，没增加。

**bench 空闲档**（15:36–15:41，1 分钟负载 14→9，5 分钟 36→30，swap 5.4G/7.0G）：

| | A p75 | B p50/p75/p95 | C p50/p75/p95 | loop lag >200ms |
|---|---|---|---|---|
| K1-3 复测（改前） | 0–1 | K1=1 3/4/26 · K1=0 21/26/38 | 7–11 / 11–14 / 14–16 | 0 |
| **K3 后 K1=1** | 1 | 4 / 6 / 12 | 9 / 10 / 17 | 0 |
| **K3 后 K1=0** | 1 | 12 / 17 / 21 | 7 / 9 / 10 | 0 |

A / B / C 都没回退。bench 的 hub 没有 working 会话、没挂岛、也不开 warroom，K3 砍掉的这几个调用点在 bench 里本来就几乎不出现，所以**收益只能看现场**。新尺子在 bench 账里已经出现模块前缀的站点：`la-phase fs.writeFileSync la-phase.json` ×12、`agent fs.mkdirSync agent` ×24、`terminal-usage fs.existsSync rl.json` ×23 等。

**顺手发现（没修）**：`agent fs.mkdirSync agent` 每发一条消息调两次，`la-phase.json` 每次 phase 变化都同步整写一次。这两处属于「写盘批量异步」，等尺子上了生产，按现场账再定。

**判定**：留。现场验证要等上生产（合并后重启 hub）：
1. 看 `[block] top` 里四个调用点是否归零或降一个数量级；
2. 看 `loop lag` 行的「其余」能不能拆出 `ws …` / `sqlite …`，以及体征段指向换页还是 GC。

### K3 审查 R1（astra）：六条已修

| # | 问题 | 修法 | commit |
|---|---|---|---|
| 1（最急） | `void p.finally(...)` 另生一个没人接的 Promise；transcript 里 `message.content` 是对象时 `toolActivitySince` 抛错 → unhandledRejection → hub 直接退出。非 working 帧的 `.then()` 也没有失败兜底 | tracker 的 job 整段 try/catch，链上的 Promise 永不 reject；清理改成成功 / 失败两个分支都做；数成功后才提交 mtime。`toolActivitySince` 跳过 content 不是数组的行。非 working 帧抽成 `session-phase.ts` 的 `sendPhaseAfter`：补数成功或失败都按当时的快照照发，send 抛了也不 reject。3s tick 加 catch | `976d34290` |
| 2 | 看门狗等 `Promise.all` 全部完成才取 now，A 的旧采样被 B 的慢 stat 拖到更晚的时刻判超时，会把还在干活的会话锁成 done | `live-activity-phase.ts` 新增 `runLaWatchdog`：逐会话 stat → 立刻取 now → 按当时快照判 → 立刻 apply；判成超时的会话再 stat 一次，用新采样重判；stat 抛错按 unknown 处理 | `6247f5559` |
| 3 | 只看最新 500 单，会永久饿死旧收据 | 一条 SQL 按 task_id 升序取等待单，游标跨轮保存；不满一页就从头补转凑满；一轮上限 500 | `419a8e0e4` |
| 4 | bind-config 的 stat 成功但读失败时，把「默认全开」连同 mtime 一起缓存了，恢复后再也不纠正 | stat 出非 ENOENT 错误、读失败、解析失败（坏 JSON / null / 非对象）时，都保留上次有效的开关、不提交 mtime，下一轮重试；只有文件确实不存在才按默认全开 | `6c40bfcde` |
| 5 | 原子写的临时文件名 `.tmp-<pid>-<hex>` 没归一，stats 无界增长（保存 100 次新增 302 个键） | `fsSite` 把 `.tmp-…`、ISO 时间戳、≥8 位独立 hex 段归成 `*`；stats 上限 512 个站点，超出的新站点并进「（其他）」 | `90077e8cd` |
| 6 | 扫描超过 30s 时，下一 tick 会抢先开庭 | 新增 `serialRound`：收据还在读时，下一 tick 整轮跳过（开庭也跳过）；收据读失败照样开庭，并记一行日志 | `216a97b0d` |

每条都配了回归测试（tool-activity +1、session-phase +1、live-activity-phase +2、hub-k3 +2、hub-config +1、block-ledger +1）。`bun test` 763 pass / 0 fail（这轮 round_robin 没抖）；tsc 206，没增加。

**比原来更宽的一处**：warroom 30s 轮里，收据读失败（比如 sqlite 抛错）现在只记一行日志，开庭照跑。K3 之前同步抛错会让 hub 退出，K3 第一版是变成 unhandledRejection 后退出。

## K3 现场验证（10-11 05:42 重启后 10 分钟）

**`[block] top` 前后对比**（各取一个 10 分钟窗口）：

| 调用点 | 重启前（旧进程） | 重启后 |
|---|---|---|
| fs.statSync *.jsonl（hub 本体） | ×69127 共 14677ms 最长 382ms | 不在榜 |
| fs.readFileSync bind-config.json | ×1720 共 12719ms 最长 332ms | 不在榜 |
| fs.readdirSync receipts | ×1719 共 9912ms 最长 418ms | 不在榜 |
| fs.readdirSync thinking-spool | ×2579 共 9312ms 最长 271ms | 不在榜 |

K3 砍的四个都出榜了，**留**。

**新榜单全是 warroom**：

- `sqlite warroom SELECT scan_state`：×15512，共 6744ms，最长 417ms
- `warroom fs.statSync *.jsonl`：×14411，共 4613ms，最长 574ms
- `sqlite warroom UPDATE sessions`：×52，共 1520ms，最长 1244ms
- `warroom fs.statSync rollout-*.jsonl`：×1100，共 1036ms
- `INSERT sessions` / `INSERT acc_cache`：单次最长 339 / 497ms

**新尺子看到的卡顿**（05:47–05:48 共 4 次，1.4–2.0s）：

- 一次能完整归因：`UPDATE sessions 1334ms`，CPU 59ms / 1904ms。
- 一次能部分归因：`INSERT acc_cache 497ms + INSERT sessions 169ms`，其余 1291ms。
- 两次全是「其余」，但 CPU 只有 8–18ms / 2.2–2.5s，硬缺页 0–5，堆没涨。也就是说，hub 在这段时间几乎没跑，没算 JS，也没被换页。

**结论**：

1. 卡顿的本质是**主线程停在同步 I/O 上等盘**，不是 CPU，也不是 GC。同一个 statSync 平均 0.3ms，尾巴能到 574ms；同一个 sqlite 写，平时几毫秒，尾巴能到 1.2s。机器 swap 吃满时盘队列很长，任何同步盘调用都可能吃到这条尾巴。
2. 剩下的同步盘调用基本全在 warroom（每 10 分钟约 3 万次）。→ **下一刀 K2：warroom 整体挪进 Worker**，主线程只收结果。
3. 「其余」里 CPU≈0 的那部分，要么是还没计时的同步 syscall，要么是进程没被调度。K4（ProcessType=Interactive，同时取消 I/O 节流）正对这一块，等粟粟点头。

顺带：重启后 4 次 SLOW connect（127.0.0.1，模拟器），大头都在 app 侧（主线程忙 0.7–2.1s，点开后 1.2–2.5s 才开始连），hub 侧没贡献。这个归 app 线，不归 hub。

## K2 第 1 步：warroom 普查扫描进 Worker 线程（`40b893d9e` `5fee32bca` `d42e71ab1` `58c0c0ece`）

**假设**：K3 现场之后，主线程上剩下的同步盘调用基本都来自 warroom 普查扫描，每 10 分钟约 3 万次：`SELECT scan_state` ×15512、`fs.statSync *.jsonl` ×14411、`rollout-*.jsonl` ×1100，`UPDATE sessions` 最长 1244ms，`INSERT acc_cache` 最长 497ms。卡顿时主线程是停在同步 I/O 上等盘。把整轮扫描挪进 Worker 线程后，这些站点会从主线程账里消失，主线程的卡顿里 CPU≈0 的「其余」部分应该少一截。

**改动**：

- `block-ledger.ts`：新增 `mergeStats`。别的线程送回来的累计只进累计表，不进近期环，所以 `explainLag` 不会把它们算成主线程卡顿。
- `warroom-indexer.ts`：
  - `scanOne` 拆成读盘半段 `readOne`（查进度、stat、读一片、解析，不写库）和写库半段 `writeOne`。`scanOne` 本身行为不变。
  - 新增 `scanAllBatched` 给 worker 用。轮次、分片、partial / stuck、单片 >50ms 按耗时 sleep 的过载减速，都和 `scanAllAsync` 一样。不同之处：读盘在事务外；每 8 个文件的写攒成一个 `BEGIN IMMEDIATE … COMMIT`；每轮结束前必须落盘，因为下一轮 partial 文件要读本轮写进去的进度；活进程刷新整个包进一个事务。
  - 库开 WAL，busy_timeout 设为 5s。
  - 代码在 Worker 线程里跑时，站点名前缀换成 `warroom-worker`。
  - `scanAllAsync` 的活进程来源改成可注入，测试不碰 tmux。
- `warroom-scan-worker.ts`（Worker 入口）：自己开一条连接（`synchronous=NORMAL`），跑 `scanAllBatched`，把结果和本轮阻塞账增量 `postMessage` 回主线程。
- `warroom-scan-client.ts`：
  - `WarroomScanWorker`：同一时间只跑一轮。worker 抛未捕获异常、自己退出、回包解不开、30 分钟不回，都按本轮失败处理：reject、terminate、扔掉 worker，下一轮 `scan()` 重建。它永远不抛同步异常，hub 退出时也会把 worker 终止掉。
  - `warroomScanRunner`：原来 hub.ts 里的 runScan 原样抽出来（防叠、负载 >40 跳增量最多 30 分钟、`[warroom] initial scan: …` 日志格式不变）。worker 为 null 时走主线程 `scanAllAsync`。
- `hub.ts`：
  - 默认走 worker。`MP_HUB_PERF_K2=0` 回主线程。
  - 编译版 hub 也自动回主线程。原因是 `bun --compile` 只认「字符串字面量 + 额外入口」形式的 worker，而 `build-cc-bridge.sh` 还没加这个入口。实测 `new URL(…, import.meta.url)` 在编译版里报 ModuleNotFound；字符串形式在源码模式下又是相对 cwd 解析，所以两边不能共用一种写法。
  - K2 开着时，主连接设 `wal_autocheckpoint=0`。
  - 启动时打一行 `[warroom] 普查扫描：Worker 线程（K2）`。

**主线程还剩的 warroom 调用**：读查询（`querySessions` / `warroomLookupTarget` / 看板快照）、奏折账本读写、30s 收据轮的 `SELECT tasks`、启动时建表和 PRAGMA。

**锁风险分析**：

1. **原状**：没设过 journal_mode，用的是 rollback journal（DELETE），busy_timeout 是 0（bun:sqlite 默认，实测 `PRAGMA busy_timeout` 返回 0）。单连接时没问题，两条连接就不行：DELETE 模式下写者提交时持 EXCLUSIVE 锁，读者也得等；busy_timeout=0 时撞锁立刻抛 SQLITE_BUSY，账本写会直接失败。所以 WAL 和 busy_timeout 是 K2 的前提。
2. **改成 WAL 后**：读不等写，写也不等读，只剩写写互斥。主线程的写只有奏折账本（派发、收据、开庭、朱批），事件驱动、频率低。主线程写撞上 worker 正在提交的那一批时，会在 sqlite 的 busy handler 里**同步睡**到锁放开。这一段仍然阻塞主循环，封顶 5s；超过 5s 抛 SQLITE_BUSY，走账本调用方原来的错误路径。
3. **压短 worker 的写锁占用**：
   - 读盘、stat、解析全在事务外。
   - 事务里只有 ≤24 条写（8 个文件 × 3 条）。
   - worker 连接用 `synchronous=NORMAL`，提交不等 fsync。WAL 下断电最多丢最后几批普查写，不会坏库；普查表随时能从 transcript 重建。主连接（账本）照旧是 FULL。
   - 活进程刷新（全表清零再置位）原来在主线程同步跑，天然原子。挪进 worker 后必须包事务，否则主线程会读到「全表 alive=0」的中间态，派发器会把活着的窗口当成死的。
4. **检查点**：K2 开着时主连接 `wal_autocheckpoint=0`，把 WAL 回写到库文件这一步只在 worker 的提交里做，主线程的账本提交不顺带干这件事。worker 停了的那段时间，WAL 只会多出账本那几条写。
5. **最坏情况**：swap 打满时，主线程上单条写见过 1.2s。那是 DELETE 模式加 FULL 同步时量的；WAL+NORMAL 下写只是追加到 WAL、不 fsync，应该短得多，但读 b-tree 页时缺页读盘仍然可能慢。一批 24 条最坏可能到几秒，主线程账本写正好撞上就会同步卡几秒，超过 5s 账本写失败。触发需要三件事同时发生：有账本写、正好落在 worker 的批事务里、swap 打满。比原来「每 10 分钟 3 万次同步调用都在主线程」小几个数量级，但不是 0。如果现场账里出现账本写的长尾（`sqlite warroom INSERT/UPDATE tasks`、`INSERT task_log`）或日志里有 `database is locked`，下一步把 `WRITE_BATCH` 改小，或者把账本写也挪走。
6. **小实验**（scratchpad 脚本，不入库）：
   - 造 1500 个假 transcript，每个约 70KB。扫描期间，主线程每 20ms 做一次账本式 INSERT 加一次 `SELECT sessions`，同时量 10ms tick 的迟到时间。
   - 条件：机器 1 分钟负载 29，没有 swap 压力，文件在页缓存里。所以主线程扫描本身在这里并不慢，这组数只看锁等待有多大，**不作收益证据**。
   - 三组下来，写全部成功（0 次 SQLITE_BUSY）；读的最长值和写在同一量级：

| | 首扫耗时 | loop lag 最长 | 主线程写最长 |
|---|---|---|---|
| A 主线程扫描（K2=0） | 519 / 639 / 556ms | 9.3 / 13.6 / 6.3ms | 0.9 / 3.2 / 1.3ms |
| B worker 扫描（K2） | 381 / 521 / 394ms | 2.8 / 11.1 / 3.5ms | 4.6 / 11.2 / 9.8ms |

   主线程写撞上 worker 批事务时会多等几 ms 到十几 ms。另有一次在负载 54 时、worker 还是 FULL 同步，测到最长 74ms；改成 NORMAL 后同样负载下最长 28ms。两次条件不完全一样，只能说明数量级。

**测试**：新增 `warroom-scan-worker.test.ts` 8 条，全部用临时目录（假 projects / codex 树 + 临时 db），liveness 一律注入空：

- worker 版和主线程 `scanAllAsync` 三张表逐行一致（不比 indexed_at）；跨批次、大文件跨多轮、半行尾巴都覆盖到；库是 WAL；阻塞账全部带 `warroom-worker` 前缀并回到主账；COMMIT 次数少于写文件数。
- 增量：没变化时 changed=0，只会重新打开那个半行尾巴文件（原有语义，判 stuck）；追加一行后只多打开这一个文件。
- 库开不了：本轮 reject，worker 不死。
- worker 抛未捕获异常、process.exit、不回包超时：本轮失败、扔掉 worker，下一轮重建后正常。
- 并发第二轮直接 reject；terminate 会让在跑的那一轮 reject。
- 开关：K2 开关和 runner 的主线程 / worker 分流。
- 过载跳过、失败只记一行。

以上全程没有未处理的 rejection。`block-ledger.test.ts` 加 1 条 mergeStats。`bun test` 772 pass / 0 fail（原 763 + 9）；tsc 206，没增加。

**语义变化**：

- warroom.db 从 rollback journal 改成 WAL。这是写进库文件的持久设置，`MP_HUB_PERF_K2=0` 回退后也还是 WAL。secrets 目录会多出 `warroom.db-wal` / `-shm`。
- 主连接 busy_timeout 从 0 变成 5s：原来撞锁立刻抛错，现在最多同步等 5s。
- 普查写按 8 个文件一批提交，`indexed_at` 是批内写入时刻。worker 崩溃时没提交的那一批会丢，因为 scan_state 也没写，下一轮会重读，结果不变。
- 活进程刷新变成原子的（主线程看不到中间态）。
- 编译版 hub 默认不走 K2，要等 `build-cc-bridge.sh` 加上 worker 入口。
- `[block] top` 会出现 `warroom-worker …` / `sqlite warroom-worker …` 站点，和主线程站点一起按总耗时排序。它们**不占主循环**，读榜时要分开看。

**判定**：代码留，待现场验证（合并后重启 hub，要问粟粟）：

1. `[block] top` 里主线程的 `sqlite warroom SELECT scan_state`、`warroom fs.statSync *.jsonl` / `rollout-*.jsonl`、`sqlite warroom UPDATE sessions` / `INSERT acc_cache` / `INSERT sessions` 应该消失（换成 `warroom-worker` 前缀的同名站点）。
2. `loop lag` >1s 的次数 / 小时，以及「其余」里 CPU≈0 的那部分，对比 K3 现场（05:47–05:48 共 4 次，1.4–2.0s）。
3. 账本写的长尾：`sqlite warroom INSERT tasks` / `UPDATE tasks` / `INSERT task_log` 的最长值，日志里有没有 `database is locked`。
4. 启动日志里有 `[warroom] 普查扫描：Worker 线程（K2）`，`initial scan:` 行照常出现，`warroom_board` / `/warroom/sessions` 数据正常。
5. 回退方法：`MP_HUB_PERF_K2=0` 后重启 hub。

### K2 审查 R1（astra）：五条已修

| # | 问题 | 修法 | commit |
|---|---|---|---|
| 1（P1） | 主连接 `busy_timeout=5000` 是同步等：账本写撞上 worker 的批事务，主循环最多卡 5.2s（astra 实测）。`warroom_request` 的 `createRequest()` 抛 BUSY 后，外层 async WS 回调没人接，变成 unhandledRejection，hub 退出 | 主连接 `busy_timeout` 降到 **20ms**（sqlite 的退避实际约 30ms，在 50ms 慢调用线以下；worker 一批常态提交几 ms，负载 50+ 时见过 30ms 左右，多数撞锁 20ms 内就放开）。新增 `retryBusy`：只对 SQLITE_BUSY 异步退避重试整个账本操作，合计约 7s，用完把原错误抛回原错误路径；等的时候主循环照转。接入的入口：WS `warroom_request`（最终失败回 WS 错误）、`/warroom/dispatch`、`/warroom/verdict`（改成异步回包）、T1 收据轮、验收 loop、派发器的 dispatched 迁移和 T2/T4 回执回调。开庭 / DAG 放行轮补了 catch，`onT2Settled` 回调里抛错也不会让链 reject。worker 连接 `busy_timeout` 10s（只卡 worker 线程）。**没接的两处**：启动时的孤儿清扫（那时 worker 还没起，失败只记一行，原样保留）；EPIC 终审叫醒的 `setRequestStatus`（同步抛错由 serialRound 接住记一行，下个 30s 轮重来） | `d22c9ddee` |
| 2（P1） | 账本操作不在事务里：`attachReceipt` 先提交 receipt/cost 再写日志，`transition` 先改状态再写日志，中间被 worker 抢锁就半成功；重试同一份收据 cost 翻倍（astra 复现 2→4） | 每个账本操作包成一个 `BEGIN IMMEDIATE` 事务（createTask / createRequest / transition / attachReceipt / attachEvidence / attachVerdict），状态和审计日志一起提交，失败整个回滚，所以 retryBusy 整件重试是安全的。新增 `acceptReceipt`：收据和 evidence_in / failed 迁移合成一个原子操作（T1 收据轮、T2/T4 回执都改用它）。同一份收据再挂一次不重复记 cost | `29042a071` |
| 3（P2） | 主连接关了自动检查点，扫描 changed=0 时没人做检查点，WAL 无界涨（astra 实测 5→10MB） | worker 每轮扫完都无条件做一次 `wal_checkpoint(PASSIVE)`，不管这轮有没有写。新增一种只做检查点的请求：普查轮因过载跳过扫描时发给 worker，检查点不在主线程做。worker 判不可用、退回主线程扫描时，恢复主连接的自动检查点（见 #4） | `e581bf6c3` |
| 4（P2） | worker 起不来（ModuleNotFound 等）时永远不降级，普查停止更新；worker 还没起就已经关了主连接检查点、宣布 K2 启用 | worker 模块加载完主动发 `ready`；在这之前出现的 error / close / 30s 不就绪都算启动失败。连试 3 次（退避 1s、2s）都失败就判不可用（`WorkerUnavailable`），普查轮在同一轮退回主线程扫描，并恢复主连接 `wal_autocheckpoint=1000`。单轮崩溃仍然是下一轮重建，不算不可用。「K2 就绪」日志和关主连接检查点都挪到第一次 ready 之后。空闲 worker 调 `unref()`，有请求在跑时 `ref()`。`terminate` 也能打断还在启动中的 worker | `e3dfbd878` |
| 5（P2） | 切 WAL 撞上旧连接的活动读事务：等 5s 后抛 BUSY，warroom 整个初始化永久跳过（K2=0 也走这条路） | 开库先查实际 journal_mode，已经是 WAL 就不再切；切不成或建表失败时，关掉这条新连接再抛。hub 改用 `openIndexerWithRetry` 开库：第一次同步试（成功就和原来一样同步初始化），失败按 2s / 5s / 15s / 60s / 5min 异步退避重开，拿到库才继续初始化账本、派发器和扫描 | `4bb9ee91a` |

**退出路径**（审查的附带一条）：hub 没装 SIGTERM 处理，launchd 停 hub 时进程直接被杀，worker 线程随进程一起结束，sqlite 未提交的批天然丢弃。`process.exit()`（FATAL 钩子）会走 exit 钩子里的 `scanWorker.terminate()`。空闲 worker 已经 unref，不会拖住进程自然退出（有回归测试：扫完不 terminate，子进程照样退出）。

**回归测试**：

- `warroom-ledger.test.ts` +3：撞锁和日志写失败都整个回滚、重试 cost 只记一次、重复收据不重复记账；retryBusy 只重试 BUSY；另一条连接占锁 400ms 期间，主线程单次同步 <100ms、定时器照转、锁放开后成功，一直拿不到锁则 reject 且不留半截。
- `warroom-indexer.test.ts` +1：旧 DELETE 库被读事务占着时构造 <500ms 失败，异步重开成功且是 WAL；已经是 WAL 时有读事务也照开。
- `warroom-scan-worker.test.ts` +5：入口不存在 / 不发 ready → 3 次后不可用；runner 同一轮回主线程且只 fallback 一次；onReady 只报一次；空闲 worker 不拖住进程退出；changed=0 时 WAL 不翻倍；过载跳过只发检查点。

`bun test` 800 pass / 0 fail（含同工位另一条线的新测试）；tsc 206，没增加。

## K1 第 4 步：发消息路径 + 其余同步 tmux 调用走 tmuxRun（`ed7311f4f` `4a4582c92`）

**假设**：10-11 06:11 现场（新尺子）：`send → tmux:mp-cc-66` 之后 `[block] tmux send-keys 651ms`、`873ms`，同一次 loop lag 1500ms 里 send-keys 占 1180ms；启动时 `[block] tmux ls 1008ms`、`首份 tmux 会话表 2690ms`。发消息路径（操作 C）、问问题卡、spawn / kill / boot 还是同步 `execFileSync`，swap 满时每次 fork 几百毫秒，全压在主循环上。改走控制连接（K1 关或没就绪走 fork-async），主循环上就不再有这些同步 tmux。research §6.2 第 4–6 步合成一刀，第 7 步（删同步回退）只做一半，见下。

**每个调用点**：

| 调用点 | 原来 | 现在（K1 开） | K1=0 |
|---|---|---|---|
| `realPasteIO.sendLiteral`（`send-keys -l`） | 同步，10s | `tmuxRun` 写，按会话进 `chainTmuxWrite`（和终端键入 / 粘贴 / resize / pipe 同一条链），10s | fork-async，同一条链 |
| `realPasteIO.paste`（`load-buffer -` stdin + `paste-buffer -p -d`） | 两次同步 | 两条合成一个 `chainTmuxWrite` job（中间插不进别的写，等于原来紧挨着的两次同步）。前一半 `tmuxLoadBuffer`：控制连接就绪、≤64KB、不含 NUL → `set-buffer -b <名> -- <文本>`；否则 fork `load-buffer -b <名> -`，文本走 stdin（与原来同一条命令）。`set-buffer` 只设缓冲区、同名重设幂等，控制连接层失败换 fork 再来一次；后一半 `paste-buffer` 是写，不重试 | 全走 fork：load-buffer stdin + paste-buffer |
| `realPasteIO.sendKey`（Enter） | 同步 | 同 sendLiteral | 同 |
| `realPasteIO.capturePane`（`-S -5`） | 同步 3s，失败 "" | `tmuxRun` 读 3s（连接层失败 fork 重试一次），失败 "" | fork-async |
| `askUserIO` 三个（`send-keys -l` / 键 / `capture -S -40`） | 同步 | 同上三个 | 同 |
| `realTmuxRunner.key` / `capture`（boot 期） | 同步 | 同上 | 同 |
| `realTmuxRunner.spawn`（`new-session -d -s … -e MP_CC_HUB_PORT=… -c cwd cmd`） | 同步 10s | `tmuxRun` 写 10s，进该会话写链；**K1 开时多一个 `-e PATH=<进程起来时的 PATH>`**（见下面「发现」）。`duplicate session` 判定照旧读 `.stderr`（TmuxCommandError） | fork-async，不加 `-e PATH` |
| `realTmuxRunner.kill`（`kill-session`） | 同步 3s，错误吞掉 | `tmuxRun` 写 3s，进写链，错误吞掉 | fork-async |
| `terminal_paste` 的 `pasteToTmux` | 同步 load-buffer + paste-buffer（失败 delete-buffer） | 改 async，同 `realPasteIO.paste` 的两半，失败 `delete-buffer`；仍包在 `chainTmuxWrite` 里，内部的写不带 session（带了死锁） | fork-async |
| `hasSession` | 快照 → 过期用 lastKnown → 从没拿到过快照才同步 `has-session` | **不变** | 不变 |
| `list` / `paneTitles` / `paneMeta` | 快照过期就同步 `tmux ls` / `list-panes` | 过期也用最后一份快照（叠加层照算，同 hasSession 的 lastKnown）；**只有一份快照都没拿到过才同步查** | 不变（过期就同步查） |
| agora 启动的 `recover@boot` / `pump@boot`（列会话 → `tmux.list()`） | startHub 里同步跑，这时还没有快照 → 同步 `tmux ls`（现场 1008ms 就是它） | 排到首份 `tmuxState.refresh()` 之后（refresh 从不 reject；拿不到快照照旧同步查） | 不变 |

为什么同步回退没删干净：`hasSession` / `list` / `paneTitles` / `paneMeta` 是同步签名，调用点 20 多处（发消息判活、终端状态广播、窗口列表、agora…）。改调用方为 async 牵动太大；改成「没快照就当查失败」会在 hub 刚起、首份快照 >2s 的窗口里改语义（`hasSession` 当 true → 死会话发消息直接丢；当 false → 重复 spawn）。所以只剩「从没拿到过快照」这一个窗口保留同步查。K1 开时 listen 前已等首份（≤2s），agora 启动也挪到首份之后，现场这个窗口里应该已经没有调用了。

**tmux-control 顺带改的一处：写命令在自己的超时内不判卡死**（`ed7311f4f`）。原规则：最老一条 3s 没回就断开连接、拒绝队里所有请求。对写命令这是新的歧义来源：断开时命令已经写进 stdin 管道，server 恢复后照样会读到并执行，调用方却收到失败。发消息路径收到失败会 `clearSessionState` → 重新判活 → 再发一遍 = **发两遍**；原来 `execFileSync` 要到 10s 超时才有同样的歧义。现在：队里有没到自己超时的写命令时先不断开，到期再判；读命令照旧各自 3s 超时后回退 fork，不受影响。测试：server SIGSTOP 1.2s（wedgeMs=300）期间发的 `send-keys` 照常成功、只到一次、连接没断；改回旧规则这条是红的（连接变 `connecting`）。

**发现（research R1 的对策要改）**：Bun 里 fork 出的子进程（`execFileSync`、`Bun.spawn`、`Bun.spawnSync`，不传 env 时）拿的是**进程起来时的环境**，看不到之后对 `process.env` 的改动（scratch 实测：改了 `PATH`、新增变量，三种子进程都看不到）。所以 hub.ts 开头那段「PATH 增强」从来没传到 fork 出来的 tmux 客户端，原来 fork 建的会话里 claude 的 PATH 一直是 launchd plist 给的那个。research 建议的 `-e PATH=${process.env.PATH}` 会换成增强过的 PATH，`/usr/local/bin`、`/opt/homebrew/bin` 排到前面，`claude` 可能解析到另一个二进制。现在用增强之前存下的 `FORK_CHILD_PATH`，子进程 PATH 与 fork 版逐字相同（hub-send 测试两档都断言等于 `printenv PATH` 的结果）。控制客户端自己是 `{...process.env}` 显式传的，拿的是增强版，这个不影响建会话（已 attach 的客户端建会话不看客户端 PATH）。

**测试**：
- 新文件 `hub-send.test.ts`（真 tmux，独立 socket，ctl / fork 两档各 4 条）：短消息（`"q" $HOME ~/x \; #{pane_id} end;` + 中文）pane 收到的字节 = 文本 + `\r`，ctl 档 fork 计数不动；多行消息走粘贴，bracketed 一整段 + settle 后 Enter，临时缓冲区不残留；spawn 子进程 PATH = fork 版的 PATH、不是 server 全局、带 `MP_CC_HUB_PORT`，重复 spawn 抛 `SessionExistsError`，kill 后没了、再 kill 不抛；`key` 到达，不存在的会话 `capture` 回 ""、`key` 抛 `can't find`。
- `terminal-paste.test.ts` 改成两档各跑一遍原有用例（ctl 档 set-buffer + paste-buffer 不 fork，fork 档两条都 fork），加 >64KB 与含 NUL 的粘贴走 fork load-buffer、paste-buffer 仍走控制连接。
- `tmux-control.test.ts` +1（上面的写命令不判卡死），`tmux-state.test.ts` +1（allowStale）。
- `bun test` 795 pass / 0 fail（中间一轮 agora round_robin 抖了一次，已知）；tsc 206，没增加。hub-terminal / tmux-control 两个文件连跑 3 遍 26/26（第一次跑撞过一次 5 fail，之后复现不出来，未查证原因，可能和同时在跑的 K2 返工有关）。

**bench 空闲档**（06:33，1 分钟负载 2.1，5 分钟 8.5；`--rounds 12 --sessions 27 --k1 1,0,1,0 --profile idle`，原始 JSON 在 scratchpad `bench-k14-1.json`）：

| | A p75 | B p50/p75/p95 | C p50/p75/p95 | loop lag >200ms | ctl / fork |
|---|---|---|---|---|---|
| K3 后（改前） K1=1 | 1 | 4 / 6 / 12 | 9 / 10 / 17 | 0 | — |
| K3 后（改前） K1=0 | 1 | 12 / 17 / 21 | 7 / 9 / 10 | 0 | — |
| **K1-4 K1=1** | 1 | 7 / 8 / 9 | **2 / 2 / 2** | 0 | 94 / 2 |
| **K1-4 K1=0** | 1 | 23 / 25 / 31 | 12 / 15 / 15 | 0 | 0 / 95 |

阻塞账：原来每组 `tmux send-keys` ×24（C 的文本 + Enter），两档现在都是 **0**，tmux 站点整个出榜。K1=1 档 C p75 从 10ms 降到 2ms（两次 fork 换成两次控制连接往返）；K1=0 档 C 和改前同一量级（fork-async，只是不占主循环）。B 没动（这刀不碰终端路径），数字在噪声里。K1=1 剩下的 2 次 fork 是控制连接就绪前的会话表刷新（首份 + 就绪前的一次轮询，未逐条核）。

**语义变化**（审查时逐条看）：
1. 发消息的 tmux 写从同步变异步，调用方 K1-0 起就 await 着，顺序不变：`sendWithEffort` 普通路径照旧先 ack 再进 `chainSessionSend`；注入 → （长文本）settle 0.5s → Enter → capture 判断 → 重试 Enter，每一步等上一步的 tmux 命令真执行完才走，settle 从粘贴完成算起，和原来一样。
2. 发消息的每条 tmux 写现在和终端键入 / 粘贴 / resize / pipe 排同一条会话写链。好处：同一会话上手机发消息和终端里打字不会再在 tmux 层乱序；代价：链上有慢命令（server 卡住）时，发消息的写也要排队，原来同步直调不排队。链粒度是单条命令，paste settle 的 sleep 不在链里，不会把键入堵上秒级。
3. 控制连接的卡死判定：有写在途时最晚到该写自己的超时（10s）才断，原来 3s。server 停住 3–10s 时，原来会断开再走 fork，现在等着；读命令各自 3s 超时后照旧回退 fork。K1-3 的终端键入写同样受这条影响。
4. fork 路径多了 `-u`（runTmux 一律带，K1-1 起就这样）。原来同步 `execFileSync` 不带。没有 LANG 时 `capture-pane -p` 的中文会不会被换成 `_`、因而 codex 指纹判定的结果会不会变：**未查证**（生产走控制连接，本来就带 -u）。
5. K1 开时 `list` / `paneTitles` / `paneMeta` 过期用最后一份快照，最多晚到下一次轮询落地（主循环恢复后 ≤2s）；原来过期时同步查（卡主循环、tmux 卡住时 3s 超时后返回空）。
6. K1 开时 agora 启动的 recover / pump 晚到首份会话表之后（通常几 ms）。首份 >2s 时排到 listen 之后；pump 自带防重入，事件触发的 pump 照常。
7. `-e PATH=…` 会把 PATH 写进新会话的 session 环境：之后在这个会话里手动开的新窗口拿的是这个 PATH，原来是 server 全局的。子进程 PATH 本身与 fork 版相同。
8. 大于 64KB、或含 NUL 的粘贴：load-buffer 走 fork，paste-buffer 仍走控制连接，两条在同一个 job 里，顺序不变。控制连接上 `set-buffer` 单行最长 64KB；research 实测 1MB 也能过（647ms），没有发现硬上限，这里的 64KB 是为了不堵队头（R5），不是协议限制。
9. 错误文案：失败日志 / `terminal_paste_result.reason` 里是 tmux 的 stderr 原文（`can't find pane: …`），原来是 execFileSync 的 `Command failed: tmux …` 加 stderr。只影响日志和失败原因文本。

**判定**：代码留，待现场验证（合并后重启 hub，要问粟粟）：
1. `[block] top` 和 `[block]` 单行里不再出现 `tmux send-keys` / `load-buffer` / `paste-buffer` / `capture-pane` / `new-session` / `kill-session`；启动时没有 `tmux ls`，`首份 tmux 会话表` 的耗时。
2. loop lag 行的归因里不再有 `tmux …`。
3. 发消息：短的、多行 / 长文本（含 >64KB 的粘贴）、中文、codex 的 Enter 重试；问问题卡的驱动键；新开 CC 会话 claude 能起来（PATH 对），hook 回传端口正常。
4. hub 启动时 tmux server 不在（第一条消息才拉起）：控制连接退避最长 30s，期间全走 fork，之后切回（第 6 步里「spawn 成功后立刻重连」这次没做，待办）。
5. 回退：`MP_HUB_PERF_K1=0` 重启 hub，tmux 调用全走 fork-async，同步回退恢复原样。

## cc_memory 清单 / 取文件改异步读盘（`4ef6523f7`）

**假设**：10-11 现场 `[block] ws cc_memory_manifest_req 2384ms`，同一次 loop lag 2422ms 里它占 2371ms，其中 `cc-memory fs.readFileSync xxx.md` 271 / 176 / 131ms…。app 连上就拉记忆清单，hub 同步逐个读 memory 目录下的 md，swap 满时每个文件都可能吃到几百毫秒的换页尾巴。改成异步读，主循环就不再等盘。

**改动**（只动 cc-memory-sync 模块和 hub 的两个 WS 分支）：
- `buildSnapshot` / `loadExtraExcludes` 改 fs/promises：readdir → 每个 `.md` 先 stat 再读，**同时读盘最多 8 个**，结果按 readdir 顺序装回，后面的排除 / MEMORY.md 去行逻辑一字没动。
- **按 mtime 缓存**（模块级，键是完整路径）：mtime、ctime、大小都没变就不重读。读失败（权限等）时有上次读到的就用它（K3 BindPrefsCache 同款），从没读到过就跳过（与原来一样）；文件不存在（列目录之后被删）跳过并出缓存，与原来一样。目录里没了的文件每次构建时清出缓存。sha256 还是每次现算（纯 CPU，没有盘）。
- 目录不存在 = 空快照；排除名单文件不存在 = 空名单；其他读错误照旧抛，清单回 `ok:false`（与原来一样）。
- hub：`cc_memory_manifest_req` 读完再回 `cc_memory_manifest`；`cc_memory_fetch` 读完再按帧回 `cc_memory_files`。
- 同模块里剩下的同步读只有 `watchMemoryDir` 启动时的一次 `existsSync`，不在 WS 路径上，没动。

**测试**：`cc-memory-sync.test.ts` 改成 await，新增 3 条：与原来的同步实现（照抄进测试）对拍 40 个文件（超过并行上限）的快照条目顺序、内容、清单 JSON、取文件帧，完全一致；缓存命中不重读、mtime 变了重读、读不了时用上次的、删掉的出缓存；从没读到过的读不了的文件跳过。`hub.test.ts` 的测试 hub 把 `CC_MEMORY_SYNC_DIR` 指到临时目录（原来指向 `~/.claude/projects/<临时工作目录编码>/memory`，不存在，只读），新增 1 条 WS 清单 + 取文件：排除的不进清单、取不到，MEMORY.md 已去行。`bun test` 795 pass / 0 fail；tsc 206。

**语义变化**：
1. 回包时机：清单 / 文件帧在读完之后才发，不在处理函数里同步发。同一连接上紧跟着的其他请求的回包可能排到它前面（app 是收到清单后才发 fetch，正常流程不受影响）。
2. 读失败（权限、I/O 错误）时用上次读到的内容，原来是这个文件从清单里消失。排除判定照旧按这份内容算。
3. **比原来更宽的一处**：`cc_memory_fetch` 读目录失败（比如权限）原来是 async 处理函数里同步抛 → unhandledRejection → hub FATAL 退出；现在只记一行 `[hub] cc_memory_fetch 读失败`，不回帧。
4. 内存：缓存常驻整份 memory 目录的正文（目前几百 KB 量级，未查证具体大小）。

**判定**：代码留，待现场验证：`[block]` 里不再有 `ws cc_memory_manifest_req` / `cc-memory fs.readFileSync …`；app 连上后记忆同步照常（花园文件库 memory/cc/ 内容不变）。

### K1 第 4 步 + cc_memory 审查 R1（astra）：五条已修

| # | 问题 | 修法 | commit |
|---|---|---|---|
| 1（P1） | 控制连接 `FileSink.write` / `flush` 背压时返回 Promise，断开清理里 `stdin.end()` 也是；server 停住被判卡死、管道断开时以 EPIPE 拒绝，没人接 → unhandledRejection → hub 退出。大文本 set-buffer 让这条路容易走到 | 三处都接住；write / flush 失败统一走 `drop` 清理（结束队列里所有请求）。回归：server 停住时 5 份 64KB 控制字符 set-buffer（转义后各约 256KB）塞满管道，判卡死断开后没有 unhandledRejection，恢复后重连照常。scratch 探针（生产默认 wedge 3s / 超时 10s）：HEAD 上 1 条 `EPIPE: broken pipe, write`，修后 0 条 | `f09340b06` |
| 2（P1） | ① 写命令 10s 超时后，发消息路径（`ensureSessionAndSendAsync`）清态并整条重发；astra 让 server 停 11.2s，恢复后 pane 收到 `ONCEXONCE\r`。② 在途写的最晚期限会被新来的写不断往后推，持续有写时连接永远不断 | ① 新增 `TmuxUncertainError`：写命令已经发出却没拿到回执（控制连接超时 / 断开、fork 客户端超时）一律按「结果不明」抛。发消息路径收到它不清态、不重发：记一行 `[hub] send 结果不明 …（不自动重发）`，并给所有 app 发一帧 `{type:"error", message_id, session_name, reason}`，由她看一眼终端再决定要不要重发。没选「先 capture 核对」：server 卡住时 capture 也拿不到，而管道里那条恢复后还会执行，核对的结论不可信。② 卡死截止点 = 最老那条没回的请求的发出时刻 + 队里最长的耐心（读 = wedgeMs 3s，写 = 自己的超时）。最老那条超过 wedgeMs 后，`run()` 不再接纳新请求（直接 fork，不往卡住的管道里塞），所以一次卡顿的截止点最多是「第一条卡住的 + 10s」，后来的写续不了期；到期断开，在途的写按结果不明拒绝。顺带把 fork 路径改成直接用 `runProcess`，退出码非 0 = 明确失败，超时 = 写命令结果不明（`runTmux` 没人用了，删掉）。回归：发消息时 server 停 11.2s，pane 里这条只有一遍（去掉判断后测试变红，两遍）；卡住后的新写走 fork，2.6s 内到期断开，两条写都是结果不明；tmux 明确答错仍是 `TmuxCommandError` | `ddbd52ccf` |
| 3（P2） | `cc_memory_fetch` 和清单各读各的。新的空清单先回、旧 fetch 后回，会把手机已删的文件写回去；旧构建读完还会把已删的路径写回缓存 | 新增 `MemoryReplies`：同一连接的清单 / 取文件回包按请求顺序发。配合第 4 条的 `MemorySnapshots`（同一目录的构建串行，结果只会越来越新），同一连接上后发的回包用的快照不会比先发的旧。缓存加 `epoch`：只有最新开始的那次构建能写缓存。回归：慢的旧 fetch 加快的新清单，仍按请求顺序发，一条失败不断链；用 FIFO 卡住旧构建，期间新构建开始并删掉文件，旧构建读完不写回（去掉核对后测试变红） | `05d14eac5` |
| 4（P2） | 「同时读盘 ≤8」是按请求算的，5 个并发请求就是 40 个读；app 收到清单后每 20 个名字发一个 fetch，每个都重扫整个目录 | 读盘信号量改成全进程共用一个（≤8）。`MemorySnapshots` 合并同一目录的构建：同一时刻最多一份在读、一份排队。清单（`fresh`）拿到的一定是请求之后才开始读的；取文件（`recent`）跟着在途 / 排队的那份，或复用 30s 内最近的一份。回归：5 个构建 × 30 个文件同时跑，并发峰值正好 8；读的时候再来 5 个清单只多排一份，取文件复用 | `4188786b3` |
| 5（P2） | 过滤前就缓存全文，没有容量上限；超大 / 被排除的文件也常驻；整个目录删除后缓存不清 | `MemoryFileCache` 改成类：正文总字节上限 8MB，按最近使用淘汰，单个超过上限的不进；只缓存要发出去的，frontmatter 排除的、超过单帧上限的不常驻（清单要它的哈希，每次现读）；按文件名就能排除的连读都不读，但仍进排除集，MEMORY.md 里指向它的行照删；目录 ENOENT 时清掉这个目录的缓存。回归：超大 / 排除文件不在缓存，读不了的 `private_` 照样删 MEMORY.md 里的行，LRU 淘汰，目录删除后缓存清空 | `31b46a815` |
| 继承 | 消息 paste 失败留下 `mp-<pid>-<n>` 缓冲区 | 链内失败也 `delete-buffer`。paste-buffer 结果不明时，同一条控制连接先进先出，delete 排在它后面。回归：多行消息粘贴到不存在的会话，不留缓冲区 | `ddbd52ccf` |

**这一节取代上面 K1 第 4 步里的两处说法**：
- 「写命令在自己的超时内不判卡死（队里有写就等）」改成上面第 2 条的截止点规则。
- 语义变化第 3 条（有写在途时最晚 10s 才断）仍成立，但截止点只从第一条卡住的算。

**真卡死时发一条消息最坏要等多久**（tmux server 停住；从这条消息的第一条 tmux 写真正开始算，**不含**在 `chainSessionSend` / `chainTmuxWrite` 里排队的时间，见下面遗留项）：

| 情况 | 走到哪一步 | 最坏耗时 | 结局 |
|---|---|---|---|
| 短消息（≤500 字、单行），`send-keys -l` 卡住 | 写超时 10s（控制连接；连接已判卡住时走 fork，同样 10s） | **10s** | 结果不明 → app 收到 error 帧，不重发 |
| 短消息，文本进去了、Enter 卡住 | Enter 写超时 10s，注入后的错误照旧吞掉 | 10s | 文本留在输入框等她手按（原来就是这样） |
| 长 / 多行消息，`set-buffer` 卡住 | 控制连接 3s 判卡死 → fork `load-buffer` 10s 超时（明确失败，没注入）→ `delete-buffer` fork 3s → 走原来的「清态重来」路径再试一遍：同样 ≤13s，再加 delete 3s | 约 **29s** | 第二遍失败只记日志，app 不会收到帧。这是原有路径，没注入过，不会两遍 |
| 长消息，`paste-buffer` 卡住 | set-buffer 正常，paste-buffer 写超时 10s → delete-buffer（同连接排在它后面或 fork 3s） | 约 13s | 结果不明 → error 帧，不重发 |
| 长消息粘进去了、之后卡住 | settle 0.5s → Enter 10s → 最多 3 轮（0.4s + capture 3s+3s fork + Enter 10s） | 约 60s（codex：0.4 + 10 + 6 ×（2 + 6 + 10）≈ 118s） | 注入后错误吞掉；这段时间占着该会话的发消息链，结构和原来同步版一样 |

**遗留（这次不修）**：
- 写链（`chainTmuxWrite`）的排队时间不算进单条命令的超时，也没有总上限。同一会话前面卡着 N 条写（键入 / 粘贴 / resize / 发消息），每条最多 10s，后面的消息要多等约 N×10s 才开始自己的 10s。要兜底得给写链加排队截止或队长上限，另开一刀。
- 长消息 load-buffer 两遍都失败时只记日志、不给 app 发帧（原有行为）。

**测试**：`bun test` 810 pass / 0 fail；tsc 206。新增 / 改动的回归：tmux-control +2（背压断连、截止点）、hub-send +2（不重发、粘贴失败删缓冲区）、cc-memory-sync +6。tmux 一律用独立 `-L` socket，跑完 kill 自己的 server。中途有一次在 HEAD 版本上验证背压用例，bun test 进程被 EPIPE 挂住，留下一个 SIGSTOP 状态的测试 server（`mp-test-35063-*`）；已 SIGCONT 并确认它退出，没碰默认 socket。

## K2 + K1 第 4 步 + 记忆清单 现场验证（10-11 08:5x 重启后 10 分钟）

**`[block] top`**：主线程的 warroom 站点全部出榜。榜上前几名都换成了 `warroom-worker …`：
- `fs.statSync *.jsonl` ×14411，共 6018ms
- `SELECT scan_state` ×15522，共 5779ms
- `statSync rollout` ×2222，共 4429ms
- 一次 `readdirSync` 2045ms

这些都在 Worker 线程里，不占主循环。有一轮增量扫描花了 33.6s（以前在主线程会卡 30s，现在 hub 无感）。`tmux send-keys` 和 `ws cc_memory_manifest_req` 也都没有出现。→ K2 / K1-4 / 记忆清单的去向判定为**留**。

**但 loop lag 还在**：10 分钟 9 次，1.0–3.3s，几乎全是「其余」。这些卡顿的特征：
- CPU 5–50ms / 1.5–4.1s；
- 硬缺页 0（偶尔 +5～+50）；
- 堆不变；
- rss 在 46–73MB 之间跳。

当时 1 分钟负载 **136**，swap 6.5G/8G。

**判断**：剩下的卡顿已经不是 hub 自己在同步干活，而是 hub 进程在那几秒里**没被调度**（负载 136，Standard 优先级），或者在等内存压缩器解压页面（压缩器缺页不计入 major fault；rss 下跌说明页被压过）。下一步：
1. 体征加上主动 / 被抢上下文切换和软缺页，用来区分是被抢占还是在阻塞等待（已派）；
2. **K4（ProcessType=Interactive）正对「没被调度」这一类**，证据比之前更足，再问粟粟。

顺带：模拟器又出现「点开后 13997ms app 才开始连」，归 app 线（见 docs/research-app-instant-connect.md）。

## K1 第 4b 步：结果不明的消息由 hub 自己核对送达（`9fb7203ca` `e6a5ab20c` `c0e635ea0`）

**假设**：K1-4 审查 R1 之后，tmux 卡住导致写入结果不明（`TmuxUncertainError`）时 hub 不重发，只发一帧 `error`。app 只把它记成「最近一次错误」，粟粟得自己开终端看（10-11 原话「本质上就是一直要打开终端擦屁股」）。R1 当时没做核对的理由是「server 卡着时 capture 也拿不到，管道里那条恢复后还会执行」——那就**先等它落定**再核对：落定以后结论可信，能补救就自动补救。

**改动**：
- `tmux-control.ts`：`TmuxUncertainError` 带 `settled`（这条写后来的下落）。控制连接写超时、连接还在 → 回执晚到时报 `replied`（ok / 答错）；控制连接断开、fork 客户端超时被 SIGKILL → 等客户端进程真退出后报 `abandoned`（`runProcess` 超时改抛 `ProcessTimeoutError`，带 `exited`）。新增 `waitTmuxWriteSettled(err, 截止)`：`replied` → executed / not-executed；`abandoned` → 新起 tmux 客户端 `display-message -p` 往返探针**连续成功 2 次**才算 settled；截止前没落定 → timeout。
- `send-verify.ts`（新）：`recoverSend` 核对流程 + `SendStatusBook` 状态账 + transcript / 屏幕匹配规则（下面）。
- `hub.ts`：`realTmuxRunner.send` 改走 `sendTracked`（仍在 `chainSessionSend` 里）。正常发送 = `pasteAwareSendAndEnter` 原样；捕获 `TmuxUncertainError` 才进核对。`pasteAwareSendAndEnter` 拆出 `submitAfterInject`（返回提交上没有），正常路径行为不变。WS `send` 帧带 `retry:true` 时先过 `acceptRetry`。

**流程**（每个 `send_status` 都广播给所有 app；`failed` 时另发旧版 `error` 帧）：

1. 结果不明 → 账上记 verifying，发 `uncertain`。
2. 等落定（每次最多 60s，超了 `failed`：「tmux 卡了 60s 还没恢复，确认不了」）。tmux 明确答错（not-executed）= 没执行，跳到 5。
3. 查绑定的 transcript：有这条 → `delivered`（「已经提交了」）。
4. `capture-pane -J -S -300`：看得到 → 停在输入框，走原有提交路径补回车（claude 长文本 settle + `[Pasted text` 重试，codex 指纹重试）。提交上 → `delivered`（「停在输入框里，补了回车」）；重试完还在 → `failed`。读不了屏 → `failed`。
5. 都没有 → 走 `pasteAwareSendAndEnter` 重发一次：成功 → `delivered`（「没进，自动重发了一次」）；明确失败 → `failed`；**又结果不明 → 再等落定、再做 3–4，但绝不重发第二次**（没进就 `failed`「重发了一次还是没进」）。比任务原文「再结果不明 → failed」多核对一轮：直接判 failed 的话，那条迟到落地后她再点重发就是两遍。

**落定判据与 tmux 3.6a 源码结论**（读 `server-client.c` / `control.c` / `proc.c` / `server.c`）：
- 每个客户端一个命令队列，`server_loop` 每轮把所有在 `clients` 链表上的客户端队列跑空（`cmdq_next`），之后才回事件循环、才写回包。同一客户端命令按序执行、按序回 → **回执晚到 = 执行过**，前面的也都执行过。
- fork 客户端：先 connect、发 identify 再发 `MSG_COMMAND`，都写进 socket 内核缓冲，server 停着也能写进去。客户端被 SIGKILL 后缓冲里的数据还在：`proc_event_cb` 一次 `imsgbuf_read` 先读到数据、逐条 dispatch（`MSG_COMMAND` → 入队），本轮末 `server_loop` 执行；EOF 要下一次读才见到，那时才 `server_client_lost`。所以**被杀前已交进 socket 的命令，server 恢复后照样执行**。测试实测：fork 写 1s 超时被杀，server 还停着，恢复后那条到达且只一遍（4/4）。
- 控制连接：控制模式下 server 直接读客户端的 stdin（`MSG_IDENTIFY_STDIN` 传过去的 fd，`control_start` 在 `c->fd` 上建 bufferevent，`control_read_callback` 逐行 `cmd_parse_and_append` 进这个客户端的队列）。hub 断开时杀掉控制客户端、关掉管道写端，但读端在 server 手里，数据还在。恢复后两件事谁先：先读管道 → 命令入队，同一轮里 socket 的 EOF 也到 → `server_client_lost` 把它从 `clients` 摘掉（`TAILQ_REMOVE`）、`control_stop` 释放 bufferevent，入队的命令永远不跑（`server_loop` 只遍历链表，队列随后在 `server_client_free` 里 `cmdq_free`）；先读到管道、本轮末执行，下一轮才见 EOF → 执行了。**执行与否不确定，但在 server 恢复后头一两轮事件里就定了**。测试实测：控制连接判卡死断开后，管道里那条 4/4 都执行了。
- 所以「落定」= 旧客户端进程已退出（不会再往 server 递东西）+ 之后**新起的客户端**往返成功：新客户端先 accept、下一轮才读得到它的命令，它的回包回来时，旧 fd 上已就绪的东西已经处理过。不需要「断开后等多久」的固定时长。探针要连续 2 次：libevent kqueue 一轮最多取 nevents 个就绪事件，余下的挪到下一轮，就绪 fd 很多时留一轮余量。
- 探针本身是只读的 `display-message -p ok`；server 停着时探针 3s 超时被杀，恢复后照样执行，无害。`no server running` 也算落定（server 没了，管道里的不会再执行）。

**匹配规则**：
- 记号：有 `message_id` 就用 `message_id="<id>"`（唯一；折行、粘贴展开、`\n`→空格都不影响）；没有（agora / warroom 注入）用去掉空白后的前 200 字，并且只认发送前 5s 之后的。比较时两边都去掉空白和框线字符（U+2500–257F），不用全文严格相等。
- transcript：claude = `sessionMap` 的 `claudeSessionId` → `claudeTranscriptPath`（已有规则），`type:"user"`、非 sidechain 的行；codex = 同一个 uuid 在 `~/.codex/sessions/YYYY/MM/DD/rollout-*-<uuid>.jsonl` 里找（日期目录从新往旧，找到就缓存），认 `response_item` 的 user message 和 `event_msg` 的 `user_message`。读尾部 4MB（`readTailAsync`）。没绑定 / 读不了 → 只看屏幕。**codex 选 rollout 而不是只看屏幕**：只看屏幕时，已提交的消息被长回答顶出可见区（核对窗口最长一分多钟）会被判成没进 → 重发 = 两遍。
- 屏幕：transcript 说没提交的前提下，屏幕上（含 300 行历史）看得到记号 = 在输入框里；claude 长文本被 TUI 收成 `[Pasted text #N …]` 看不到原文，认占位（和原有粘贴重试的判法一样）。
- app 重发（retry）：同一套，只是不等落定，先看现场——transcript 里已经有（比如她在终端里自己按过回车）就不注入，直接 `delivered`；停在输入框就补回车；没进才真发。

**会话里后面的消息怎么排**：核对在这个会话的发消息链（`chainSessionSend`）里跑完才放下一条。理由：后面那条要是先进去，会接在输入框里那半条后面、一个回车一起提交（粘成一条）；或者排到重发前面（乱序）。终端键入的写链（`chainTmuxWrite`）不占，核对只按条发 tmux 命令，她在终端里打字不受影响。代价：tmux 真卡死时，这个会话后面的消息要等核对结束（下表）。

**retry 帧**：`acceptRetry` 只接受账上 `failed` 的 message_id（转 `retrying`，不广播），然后走原有发送路径（ack 照发）；结果回 `send_status`。账上 `delivered` / 核对中 / 重发中 → 不发、不 ack，回 `send_status` 当前状态（核对中 / 重发中报 `uncertain`）。没记录（hub 重启过 / 超过 1 小时 / 本来就是正常发送的）→ 不发、不 ack，回 `failed` + 说明「要发请当新消息发」。账：只记走过核对的消息，按最后更新时间 1 小时过期，最多 1000 条，最老的先挤掉。

**测试**：`bun test` 839 pass / 0 fail（这一步净增 17 条；中间一轮 `dir-watch` 的 DirtyDirScanner 在 5 分钟负载 55 时 3s 超时一次，单跑和整套重跑都绿，没碰那个文件）；tsc 206，没增加。
- `send-verify.test.ts`（新，12 条，假 IO）：记号、两种 transcript 形状、折行 / 框线 / 占位、找 rollout、状态账（retry 对 failed / delivered / 核对中 / 没记录、过期、上限）、核对各分支（已提交、补回车成 / 不成、没进重发、答错直接重发、重发失败、重发结果不明不二次重发、落定超时、读屏失败、没 transcript、retry 两种）、`waitTmuxWriteSettled`（探针中途失败从头数、超时）。
- `tmux-control.test.ts` +2（真 tmux）：写超时但连接没断 → 恢复后 `replied ok`、只到一次；控制连接判卡死断开 + fork 客户端被杀 → server 还停着时都报 `abandoned`，恢复后探针落定，fork 那条照样执行一遍，落定后 1s 内两边都不再变。
- `hub-send.test.ts`：假 CC TUI（pane 里一个小程序：键入显示在输入框、粘贴显示占位、回车往临时 HOME 下的 transcript 写一行）。ctl / fork 两档 tmux 停 11.2s：卡住时发的那条**恰好提交一遍**，100ms 后发的下一条在它之后单独提交（不粘连），帧 = `uncertain → delivered`，之前那条正常发送没有帧、不进账；两档都走「停在输入框 → 补回车」（连跑 4 轮都是），用时约 11.3s（= 停顿 11.2s + 核对）。retry：transcript 里已有的不再注入、没进的照常发，送达后再 retry 不接受。旧的「最多一遍」用例由这两条取代（它用裸 `cat` pane，屏幕上看不到输入框，核对会判没进而重发，正好说明核对靠屏幕 / transcript）。
- `hub.test.ts` +1（WS）：没记录的 retry 回 `send_status failed`、不 ack；普通 send 只有 ack。
- 「没进 → 重发」在真 tmux 里造不出确定的场景（控制连接断开的那种实测 4/4 都执行了），由假 IO 单测覆盖；app 重发的「没进 → 发」分支走了真 tmux。
- SIGSTOP 只停测试自己起的 server（断言 `ps` 命令行含测试 socket 名），finally 必 SIGCONT 并断言 `ps stat` 不含 `T`；跑完查过没有遗留 `mp-hsend-*` / 本轮的 `mp-test-*` server。机器上另有一个 06:29 起的 `mp-test-66935-*`（不是本轮的，状态 Ss 没停住），没碰。

**最坏耗时**（从这条消息第一条 tmux 写开始算，不含排队；这段时间这个会话后面的消息都在等）：

| 情况 | 走到哪一步 | 最坏耗时 | 结局 |
|---|---|---|---|
| server 停住后很快恢复（典型） | 写超时 10s → 回执晚到 / 探针 2 次（毫秒级）→ transcript + capture → 补回车 | ≈ 停顿时长（测试 11.2s 停顿 → 11.3s） | delivered |
| server 一直不恢复 | 写超时 10s → 等落定 60s | **70s** | failed（确认不了） |
| 落定了、没进，重发顺利 | 10 + ≤60 + 核对（capture 读 3s，控制连接失败换 fork 再 3s）≤6 + 重发（同正常发送） | ≈ 76s + 一次正常发送 | delivered |
| 落定了、没进，重发又卡住 | 10 + 60 + 6 + 10 + 60 + 6 | ≈ 152s | failed / 落进输入框则补回车 |
| 停在输入框，补回车也卡 | 核对之后走原有提交路径：claude 短 10s；claude 长 0.5 + 10 + 3×(0.4 + 6 + 10) ≈ 60s；codex 0.4 + 10 + 6×(2 + 6 + 10) ≈ 118s | 上面再加这一段，codex 极端 ≈ 270s | 原有路径放弃时 failed |

**语义变化**：
1. 结果不明时不再立刻发 `error` 帧，改成 `uncertain`，核对完才 `delivered` / `failed`；`error` 帧只在 `failed` 时发（文案「这条消息没送进 X：<原因>」）。
2. 结果不明的消息会被**自动补回车或重发一次**（R1 时是绝不重发）。重发只在原写入确定落定、transcript 和屏幕上都没有这条之后发生。
3. 核对期间这个会话后面的消息排队等（最坏见上表）。原来结果不明后立刻放下一条。
4. 正常发送（没有结果不明）：字节、顺序、时机不变，不发 `send_status`，不进账；`sendRaw`（斜杠命令、`/effort`）不走核对，和原来一样。
5. retry 帧：只有 hub 记为 failed 的才发；其余不 ack（原来没有 retry 字段，同 id 会照发；不带 retry 的同 id 消息仍照原逻辑发）。
6. 账在内存里，hub 重启就没了：重启前 failed 的消息，重启后点重发会被拒（回 failed + 说明）。
7. `MP_HUB_PERF_K1=0`：fork 写超时同样走这套（测试 fork 档）。

**未查证 / 遗留**：
- 「回车发出去了但 CC 没提交」只能靠原有的占位 / 指纹重试判断；claude 短消息补回车后不再核对 transcript（CC 忙着时消息会排队，transcript 晚写，没法用它判）。
- 只核对「注入那一下」结果不明。文本进去了、**回车那一下**结果不明时，仍照原来吞掉（注入后的错误不外抛），不进核对——文本可能停在输入框。要补的话另开一刀。
- 没有 transcript 可查时（codex 收割 uuid 失败、claude 绑定丢了）只看 300 行屏幕：已提交又被顶出 300 行的会被判没进而重发。
- 核对里补回车 / 重发时，她恰好在终端里打了半句：回车会把她那半句一起提交。和原来一样没防。
- retry 被接受后，若原有发送路径走到「会话死了 → 重新拉起 → 排队」又没拉起来，账上停在 `retrying` 直到 1 小时过期，期间再 retry 回 `uncertain`。
- tmux 源码结论里「同一轮事件里管道先读还是 EOF 先到」是按 libevent / kqueue 行为推的，实测只见到「执行了」一种；两种情况核对都能处理。
- 落定探针每次 fork 一个 tmux 客户端（只在结果不明时才有）。

**待现场验证**（合并后重启 hub，要问粟粟）：
1. 正常发消息：日志里没有 `send 结果不明` / `send 核对`，app 不收 `send_status`。
2. 下次真卡住（日志出现 `send 结果不明 …`）：后面跟一行 `send 核对 … delivered|failed（原因；步骤）`，终端里这条只有一遍；app 显示「确认中」后变正常或「没送达」。
3. app 点「没送达」重发：日志 `retry 接受`，终端里只多一遍；对已送达的点重发：`retry 不接受`。

### K1 第 4b 步 · 审查 R1（astra）：十条 + app 协议，改了设计（`cf6edb736`）

**这一节取代上面「流程」「匹配规则」「会话里后面的消息怎么排」「最坏耗时」「语义变化 2/3」**。astra 用反例复现了重复注入（TUI 还没消费就判没进而重发，两份 tag 一次提交）、消息粘连（补回车失败后放行下一条）、错误的 delivered（重发后回车没提交仍报送达）。根子是把「这次查不到」当成「没进去」。

**新设计原则**：
1. **只有确定没执行的写才自动重发（一次）**：tmux 明确答错；或粘贴的临时缓冲区在落定后还在——`paste-buffer -d` 贴完即删，旧客户端已经没了（落定），缓冲区还在 = 它没贴过、也不会再贴。为此结果不明的 `paste-buffer` 不再立刻 `delete-buffer`，缓冲区名挂在 `TmuxUncertainError.buffer` 上，核对判完再删。短消息（`send-keys -l`）没有这种证据，证明不了丢弃 = 不确定。
2. **已执行**（回执晚到 / 缓冲区被用掉 / 输入框里认出了这次的记号）：字节已交给终端，TUI 早晚会消费。等它进输入框（认出记号；已执行的粘贴另认占位）→ 走原有提交路径补回车 → 确认（transcript 里有，或输入框里这条没了 = 终端收下了，提交或排队）。**不重注入**。认不出输入框时和正常路径同等把握：等 1s 当已消费，补回车，`submitAfterInject` 说提交上了就算。
3. **不确定**：20s 窗口每 0.5s 轮询 transcript 和当前输入框。transcript 里有 → delivered；输入框里认出这次的记号 → 按已执行走。窗口完了 → `failed`、`retryable:true`，原因「可能已经进去了，看一眼终端再决定要不要重发」。**不重发**。
4. **失败和「会话能不能继续注入」分开管**：失败后会话继续堵着（还在 chainSessionSend 里），直到旧写落定、且某次读屏确认输入框里没有这条（也没有粘贴占位）才放行。最多 2 分钟，到点放行、记一行日志，并给这条 failed 再推一帧补原因「…后面的消息已经放行，可能会接在它后面」。确定没执行 / 会话没了的失败不堵（输入框里不会有它）。
5. **身份只认唯一 ID**：app 消息 `message_id`；agora `claim_token`（每次认领唯一）；其余 channel 标签（warroom / 保暖 / 提醒）没有每次唯一的业务 ID → hub 生成 `inject_id` 写进开头标签的属性末尾（`source` 等前面的属性不动，thinking-hook / turn-extract 的正则照认）。既不是 channel 也没 claim 的裸文本（生产路径上没有）不改字节，记号永远认不出 = 只能「确定没执行才重发」，其余按不确定。
6. **transcript 从发送前的位置往后读**：发送前 stat 一次记长度（最多等 200ms，等不到之后一律 unknown），核对时增量读这之后的部分。超过 64MB、文件变短（被换掉）、读出错 → unknown，绝不当「没提交」。重新生成复用同一个 message_id 时，旧那次的行在游标之前，不会被认成这次。

**逐条**：

| # | 问题 | 修法 |
|---|---|---|
| 1（P1） | 落定后立刻查屏，TUI 还没消费 → 判没进 → 重发 = 两遍 | 原则 1–3：只有确定没执行才重发；已执行 / 不确定都在窗口里等消费、不重注入。回归：落定后输入框晚几拍才出现这条 → 只注入一次、补回车 → delivered；窗口里一直没看到 → failed retryable，注入仍一次 |
| 2（P1） | 核对失败就放行下一条，粘连 | 原则 4。回归：旧写超时没落定时输入框空着也不放行；落定后输入框里出现这条（迟到的写）不放行，清空才放；一直清不掉 2 分钟（测试缩到 0.4s）到点放行、补原因 |
| 3（P1） | `submitAfterInject` 的 false 被丢，报 delivered；提交检查 capture 失败当空屏 | `pasteAwareSendAndEnter` 返回 `{committed, paste}`；`realPasteIO.capturePane` 读失败抛（`submitAfterInject` 照旧接住、返回 false）。重发后没提交上 → 按已执行确认，不报 delivered；**正常发送回车后没确认提交也进核对**（原来记一行就放下一条） |
| 4（P1） | 无 ID 前 200 字匹配，agora 固定说明撞 | 原则 5 |
| 5（P1） | 任意占位 / 300 行历史冒充「在输入框」 | `locateEditArea` 只看可见屏的当前输入框：claude 按 2.1.291 二进制里 PromptInput 的画法（`borderStyle:"round", borderLeft:!1, borderRight:!1` → 上下两条整行 `─`，中间第一行是 `prefix`：`Z.pointer` 即 `❯`，bash 模式 `!`，老版本 `>`），取屏上最后两条整行横线、中间第一行是提示符才算；codex 取最后一个以 `›` 开头的行到下一个空行（**未查证**，codex 二进制里没搜到确定的提示符串）。认不出 = unlocated，身份确认不了就当不确定。占位只在「已执行的粘贴」里当证据，不确定时不认 |
| 6（P1） | 只查尾部 4MB，查不到判从没提交 | 原则 6（`TranscriptScanner`） |
| 7（P2） | 1000 条上限淘汰排队中的 retry | 账分两半：`active`（核对中 / 接受了的重发，不淘汰）和 `history`（终态，1 小时、1000 条）。进行中满 200 在接纳 retry 前限流（回 failed、retryable:true「电脑那边正忙，稍后再点重发」）。retry 身份跟着 `active` 里的 op 走，不靠历史账判断 |
| 8（P2） | 接受 retry 后前置失败没终态 | WS 处理里附件落盘 / 组帧抛错 → `abortRetry` 写 failed；进了原有路径（拉起 / 排队）的有 5 分钟看门狗，到点 failed「重发 5 分钟没发出去」。终态只有还登记着的那个 op 能写，看门狗和正常结束谁先谁算 |
| 9（P2） | 会话死了 retry 卡在核对里；reap 不算核对中 | 读屏结果分 `found / unlocated / unreadable / gone`（tmux 明确说 can't find / no server = gone）。核对中 gone → 只清就绪态（不碰启动互斥的 spawning / 排队），transcript 有就 delivered，否则 failed retryable（终端没了，没提交的字跟着没了，重发不会两遍）。retry 前看现场是 gone → 刷新会话表后交回原有路径重新拉起，身份留在 active 上（`started=false`），只交一次，再 gone 就 failed。核对按会话代次（`lastStartupGen`）：代次变了不补回车、不重发。reap 的 busy（计划前和 kill 前两处）加上 `sendTracker.busy`（核对中 / 有进行中的重发） |
| 10（P2） | send_status 不补发 | client_info 之后每个连接补一帧 `{"type":"send_status_snapshot","statuses":[…]}`（app 定的格式）：active 一个不漏报 `uncertain`，history 里的 failed 带 retryable，不带 delivered |
| 协议 | `retryable` | 每帧 send_status 都带 `retryable`（只有 failed 可能是 true）。retry 被拒：没记录 / hub 重启过 → failed + false「电脑那边没有这条的记录（可能已经送达…）」；已送达 → delivered + false；核对中 / 重发中 → uncertain + false；**跨 transport**（会话现在是 stream）一律拒，failed + false |
| 协议 | 重新生成后旧那次的迟到结果 | hub 收到 send 帧时按 channel 标签的 `ts` 登记「这个 message_id 的最新一次」。非 retry 的新一次开始：旧那次从 active 摘掉、历史清掉；之后旧那次的 `begin` / `finish` 都是空操作（不发 send_status，也不发旧版 error 帧）。retry 被接受后那次登记为最新 |
| 顺带 | cc-workdir.ts:12 同步 statSync 在路径上 | 发送前算 claude transcript 路径用 60s 缓存的目录（按 HOME + MP_CC_WORKDIR 失效）。codex rollout 查找单飞、没找到 30s 负缓存、发送前最多等 200ms（等不到这次 unknown，找完缓存给下次） |

**正常发送多了什么**（没有结果不明、回车确认提交）：发送前一次异步 stat（≤200ms 上限）、一次 channel 标签解析；非 app 消息的 channel 标签多一个 ` inject_id="inj-…"` 属性（字节变化，按审查 4 要求）。不发 send_status、不进账、tmux 命令序列不变。

**最坏耗时**（从这条第一条 tmux 写算，不含排队；期间这个会话后面的消息都在等。每次读屏 / 读 transcript 本身最多 3s + fork 重试 3s，窗口按挂钟算，所以每个窗口可能多出一次读的时长）：

| 情况 | 最坏 | 结局 |
|---|---|---|
| server 很快恢复、这条进了输入框（典型） | ≈ 停顿时长（测试 11.2s 停顿 → 11.2s） | 补回车，delivered |
| 一直没落定 | 写超时 10 + 等落定 60 + 堵 120 ≈ **190s** | failed retryable，到点放行 |
| 落定了、短消息、窗口里没认出 | 10 + 60 + 20 + 堵 120 ≈ 210s | failed retryable |
| 已执行、补回车也提交不上（codex 极端） | 10 + 60 + 20（等进框）+ 118（codex 提交重试）+ 20（确认）+ 120 ≈ 350s | failed retryable |
| 确定没执行 → 重发又结果不明 → 再走一遍 | 上面再加 10 + 60 | 不再重发 |
| 接受的 retry 一直发不出去 | 看门狗 5 分钟 | failed retryable |

**测试**：`bun test` 873 pass / 0 fail（含同工位「记住模型」那边的用例）；tsc 206，没增加。
- `send-track.test.ts`（新，18 条，假 IO、时间缩小）：正常发送零帧；R1-1 两条（晚几拍才进框只注入一次、一直没看到 failed 不重发）；确定没执行才重发；粘贴缓冲区三种（还在 → 删了重发、不在 → 认占位补回车、查不了 → 不确定、占位不认身份）；R1-5 占位 / 别的 message_id 不算；R1-6 发送前就有的同 id 不算；R1-2 没落定 / 迟到的写不放行、清空才放；到点放行补原因；R1-3 两条；代次变了不补回车；R1-9 gone + busy；retry 三种（其实进过 / 在框里 / 没进）；retry 时会话不在 → 交回原有路径、再不在 failed；R1-8 abort + 看门狗；retry 明确失败抛回原有路径、身份留着；重新生成后旧结果不发。
- `send-verify.test.ts`（重写，10 条）：标签 / 记号（agora 不同 claim 不撞、inject_id 位置、裸文本不改）、transcript 行形状、`TranscriptScanner`（游标前的不算、增量、超上限 / 变短 = unknown、原本没有 = not-seen）、`locateEditArea`、rollout、账（retry 接纳规则、限流、历史上限挤不掉进行中的、新一次顶掉旧结果、快照）、`waitTmuxWriteSettled`。
- `hub-send.test.ts`：假 CC TUI 改成照 claude 输入框画（上下横线 + `❯`）。ctl / fork 两档卡 11.2s：这条恰好提交一遍、后一条单独提交不粘连、帧 = uncertain → delivered，两档都是「停在输入框里，补了回车」（不重发）；retry 两种走真 tmux。
- `hub.test.ts`：没记录的 retry 回 failed + retryable:false、不 ack；client_info 两次只补一帧快照。
- 每轮跑完查过没有遗留本轮的 tmux server；SIGSTOP 只停测试 server，finally 必 SIGCONT 并断言不在 T 状态。

**未查证 / 遗留**：
- codex 输入框的画法（`›`）没在真 codex 上核过；认不出时 codex 的不确定都只能靠 rollout，失败后要堵满 2 分钟才放行。**现场第一件事：在 codex 会话上 capture-pane 看输入框长什么样**。
- claude 输入框认法基于 2.1.291 二进制里的组件参数推的，没在真 CC 上截过屏；对话框（权限确认等）出现时可能认错或认不出。
- 短消息被 CC 当粘贴收成占位（打字太快）时，不确定路径认不出身份 → failed retryable + 堵 2 分钟。
- 「回车那一下」结果不明仍照原来吞掉（`submitAfterInject` 里接住，返回 false → 现在会进核对，比原来好，但回车本身不做落定判断）。
- 只有 app 消息进账、有 send_status；agora / warroom / 保暖的核对只记日志，失败时发旧版 error 帧（不带 message_id）。
- 落定探针两次连续成功仍是推断加实测（astra 12 次、我们 4 轮都是旧命令先执行），没证明所有负载下都够；粘贴路径不靠它（缓冲区在不在是硬证据），短消息路径靠它的地方只决定「何时开始看现场」，不决定重发。
- 账在内存里：hub 重启后进行中的核对和 failed 记录都没了，app 快照里没有 → app 按「没送达、不可重发」显示。

## 记住模型 · 审查 R1（astra，审 b3de6e385）

背景：b3de6e385 让会话被重新拉起时用她 `/model` 选过的模型（`cc-model.ts`）。astra R1 提了 2 个 P1、11 个 P2 / P3，另有 2 个既存问题；车头裁定后在 backend-4 返工。

| # | 问题 | 修法 | commit |
|---|---|---|---|
| 1（P1） | 并发 `spawn_cc` 时第二次撞 duplicate 走接管：提前标就绪、提前补发，绕过第一次的 boot 等待。读转录让这个窗口变大了 | `sessionSpawning` 改成 会话 → 本次启动代次。所有拉起入口进 `spawnSession`，已有在启动的就并进去；启动链内重试带代次续上；每个 await / 定时器回来先核对代次，不是自己的就收手。「接管已有会话」只在本代次 `tmux.spawn` 撞 duplicate 时发生 | a37656c13 |
| 既存 | 回收在 `await kill` 之后无条件 `clearSessionState`，会清掉期间新起的启动和排队消息 | 记 kill 前的代次（`lastStartupGen`），变了就只清就绪 | a37656c13 |
| 2（P1） | stream 启动同步抛错，会话永远停在 spawning，消息只进不出 | 抛错时释放本代次、记一行错误并往上抛（spawn_cc 回 err），消息留在队列，下一条照常再拉起。`streamBootFailed` / `onStreamExit` / 就绪超时都按代次处理 | a37656c13 |
| 3（P2） | 读转录没有截止时间 | `readModelEventWithin` 设 1.5s 截止，超时或出错就按记录启动；迟到的结果没人接，不写记录、不碰启动状态 | 09865c044 |
| 4+5+6（P2） | 起不来就把她的记录永久写成 default 并靠时间戳竞争：未来时间会反复选回坏模型；无关原因的死亡也会改掉她的选择；stream 没有兜底 | 改成本次恢复专用的一次性覆盖（`cont.modelOverride`）：不写记录，每次启动只有 1 次预算。只有输出里有模型报错、且报的是这次用的模型，才降级。tmux 和 stream 共用 `planModelRecovery`。证据来源：stream 用 stderr 尾巴（stream-runner 保留最后 4096 字，onExit 时带出）；tmux 用 boot 期最后一次截屏 | 72d15ff35 |
| 7（P2） | await 之后还拿旧快照比，会覆盖期间的新选择；转录来源把发现时间当成事件时间 | await 之后重新取记录（`version()` 有变化就打一行）；读的期间绑定换了，转录就不作数。`setFromTranscript`：`updatedAt` 用转录里的命令时间，另外存 `seenAt` 和 `transcript`。比此刻晚 1 分钟以上的未来时间不可信 | 09865c044 |
| 8（P2，部分） | 空参数的选单事件后面还没有回复时，会遮住更早的选择 | 这种选单事件，以及参数不合格的命令，都跳过、继续往前找。「运行期间增量记录」没做，见遗留 | 4fe461e1d |
| 9（P2） | 普通正文或 channel 里出现命令标签，会被当成一次切换 | `standaloneModelArgs`：整条 user 内容只能是 command-message / command-name / command-args 三种标签（各至多一个）加空白，命令名正好是 `/model` | 4fe461e1d |
| 10（P2，裁定 b） | `/model default` 被换成另一种语义 | 文档没写明 `--model default` 合法，也没实测，所以车头定 b：显式 default 存成 `"default"`，和「从没选过」分开；拉起时由 `cliModelFor` 先映射成 hub 默认，注释和日志都写明未实测，以后要改只动一行 | 09865c044 |
| 11（P2） | 坏记录（NUL、超长、坏时间）也会被加载，还会永久压住正确的转录 | 统一用 `MODEL_NAME_RE`（字母、数字和 `. _ : / @ [ ] -`，1–200 字），parse / set / load / 转录回复里的 model 共用。load 时逐条校验 model、updatedAt、source、usedAt、seenAt、transcript，坏的丢掉并计数 | dfa4ae752 |
| 12（P3，最小化） | 退出前最后一次写可能丢 | `ModelPrefs.flush()`；两个 FATAL 钩子改成 `exitAfterFlush`，最多等 1s。不新加 SIGTERM 处理 | dfa4ae752 |
| 13（P3，部分） | 记录无界增长 | 上限 500 个会话，按最近使用（拉起时 touch）淘汰；加了 `delete`。启动时同步读一次，保留不改 | dfa4ae752 |
| 既存 | command 帧的 `sendRaw` 没有 await：异步失败会 unhandledRejection 让 hub 退出，而且是先记模型、先回 ack | 抽出 `sendSlashCommand`：await 之后才记模型、回 ack；普通失败和结果不明（TmuxUncertainError）都接住并回 error 帧 | 96c133fcc |

**测试**：在 96c133fcc 的干净导出上（工作区另有 K1 4b 未提交的 send-verify.ts 半成品，会让 relay-e2e 起 hub 失败，所以没在工作区数）跑 `bun test`：856 pass / 0 fail。新增和改动的回归在 `cc-model.test.ts`、`hub-model.test.ts`（假 tmux；stream 子进程一律打桩，不真起 claude）、`stream-runner.test.ts`。tsc 206，没有增加。

**遗留**：
- 运行期间不增量记录。终端里切的模型只在下次拉起时从转录尾部（1MB）采集；两次拉起之间转录涨过 1MB，或者 tmux 会话里 `/clear` 换了新转录，终端里那次切换就记不住了（app 发的有记录兜底）。
- tmux 起不来时几乎拿不到证据：会话死了就截不到屏，所以基本不会触发模型降级，按原来的死亡处理走（resume 失败就清绑定换 fresh）。如果坏模型真让 claude 启动即退出，仍会走到换 fresh。报错文案是按 Claude Code 的常见说法匹配的，没有实测。
- hub 现在没有「显式删除会话」的入口，`ModelPrefs.delete` 暂时没人调用，只靠 500 上限淘汰。
- 不为退出时落盘新加 SIGTERM 处理（会改变 launchd 停 hub 的行为）。launchd 正常停 hub 时，最后一次写仍可能丢（写是异步串行的，窗口在毫秒级）。
- `--model default` 是否合法要等实测；确认后改 `cliModelFor` 一行。

## session_model + 上下文窗口（`d3bf348b5` `ca002d561`；K4 模板 `dd6709fbc`）

背景：粟粟要底部模型胶囊显示「cc-模型名」。hub 知道每个会话实际在用的模型，但只在终端面板 attach 时随 `terminal_usage` 发，聊天页拿不到；ctx% 一律按 `CC_MODEL` 的窗口算，切到 5.5 之后按 200K 算（5.5 天生 1M），百分比偏大 5 倍。

**协议**：`{"type":"session_model","session_name","model":短名,"model_id":全名}`。app 报到（client_info 第一次）时补发已知的全部，没算过的会话挨个异步算（算出来走广播）；会话拉起、app `/model` 确认后、每轮做完（phase 离开 working）重算，**变了才广播**，只发报过到的连接。

**真实模型怎么定**（`session-model.ts resolveSessionModel`）：转录里最新一条主线回复的 `message.model`（codex：rollout 里最后一条 `turn_context.payload.model`）跟「选择」比时间，回复更新就用回复的，否则用选择。选择 = 本次拉起用的模型 / app `/model` 确认的参数（带确认时刻）。都没有：claude 用「下次拉起会用的」（记录或 hub 默认），codex 不发（app 不显示后缀）。回复里的 model 不带 `[1m]`：跟选择是同一个模型（同族别名也算）就把 `[1m]` 接回去——4.6 只有 `[1m]` 变体才 1M。

**短名**：`claude-opus-5-5` → `opus-5.5`，`claude-opus-4-6[1m]` → `opus-4.6-1m`，`claude-sonnet-4-5-20250929` → `sonnet-4.5`，`claude-opus-4-20250514` → `opus-4`，`opus[1m]` → `opus-1m`；`best` / `default` / `opusplan` / 云厂商 id（`us.anthropic.…-v1:0`）/ 老命名（`claude-3-5-sonnet-…`）/ `gpt-5.2-codex` 原样。

**上下文窗口**：`contextWindowFor` 除了 `[1m]` 后缀，再认天生 1M 的：Opus 4.7 及以后、Sonnet 5 及以后、Haiku 5.5、Fable 全系。来源 code.claude.com/docs/en/model-config（10-11 查）原文「Fable 5.1, Fable 5, Sonnet 5 and later, Haiku 5.5, and Opus 4.7 and later run with the 1M window by default」，以及「Opus 4.6 and Sonnet 4.6 reach 1M only through their `[1m]` variant」。`terminal_usage` 和 Live Activity 的 ctx% 改成按**那条回复**的模型（接上选择的 `[1m]`）算窗口。

**K4**：`install-launchd.sh` 渲染用的 `launchd/cc-bridge-hub.plist.template` 加 `ProcessType=Interactive`（只 hub，watchdog 不动）。没跑安装脚本，现有 plist 粟粟自己改。

**测试**：`bun test` 890 pass / 0 fail（新增 `session-model.test.ts`；`hub-model.test.ts` 5 条；`hub.test.ts` 1 条 WS：/model 确认后广播 + 新连接报到补发；`terminal-usage.test.ts` 1 条）。tsc 206，没增加。app：mac 定向 `CCSessionModelTests`。

**遗留 / 未查证**：
- 胶囊在屏幕上没看过（没装设备）；长名（「cc-opus-4.6-1m」）靠原有的中间截断。
- 不带版本的别名（`opus` / `sonnet` / `haiku`）的窗口不猜（随账号、配置解析成不同版本），按 200K；它只在还没有回复时出现，有回复就按回复里的全名算。`CLAUDE_CODE_DISABLE_1M_CONTEXT` 没算。云厂商 id 认不出，窗口按 200K。
- 终端里直接敲 `/model`：要等这一轮回复写进转录、phase 离开 working 才更新；一直没回复就一直显示旧的。
- codex 的 rollout 格式（`turn_context.payload.model`）照仓里的 fixture 和 `CodexAdapter.swift` 写的，没对真 rollout 验。新 codex 会话第一轮做完前没有后缀。
- 会话被删后 `sessionModelKnown` 不清（进程内，量小）；hub 重启后选择丢了，靠转录 / 记录兜。
- 每次 app 重连都对还没算出模型的会话（主要是没 rollout 的 codex）再读一次，找 rollout 的目录扫描有 30s 失败缓存。

### session_model · 审查 R1（astra，8 项 P2 + 1 项 P3；车头裁定 8 收 1 不收）

**这一节取代上面「真实模型怎么定」和遗留里的后三条**。新的定法：会话的「选择」有四个来源，按时间取最新的一次——拉起用的模型、app `/model` 经 CLI 确认的、转录里 CLI 接受了的 `/model`、落盘记录（cc-models.json 的 updatedAt）。转录里最新的回复如果比这次选择新，就用回复的模型，`[1m]` 只从这次选择接。都没有时，claude 按 hub 默认，codex 不发。

| # | 问题 | 修法 | commit |
|---|---|---|---|
| 5（P2） | codex 轮首的 turn_context 被超过 512KB 的输出挤出尾读范围：新会话没模型，老会话把旧模型当成没变 | `TranscriptScan` 按文件增量扫：size+mtime+inode 没变就不读；变长了从上次最后一个完整行之后接着读新增部分，事实按文件顺序更新；第一次、截短或换文件时，从尾部按 1MB 分块往回找，上限 8MB；半行等写完整再认 | fece8b707 |
| 8（P2） | 冷启动预热时每个 UUID 都把 codex 历史目录走一遍；普通刷新没有版本缓存和在途合并 | `CodexRolloutIndex` 一次扫描建 uuid → 路径表，60s 过期，同时只建一份；预热串行、一次最多读 32MB 转录。版本缓存和在途合并见上一条：同一会话的重算并进正在跑的那次，跑完再补一遍 | a2d98dc21（版本缓存 / 在途合并在 fece8b707） |
| 4（P2） | 终端里连着几轮都是 done → done，靠 phase 跳变会一直跳过刷新 | 改由真实的轮次结束驱动：claude 的 Stop hook（`/la/lifecycle` stop）、MCP reply（codex 靠它）。不看 phase 变没变，重复触发靠文件版本去重；app 报到时全部会话都重算（没算过的排前面，封顶 32MB） | 8b40f533b |
| 1（P2） | 旧的 `[1m]` 选择盖掉终端里后来去掉后缀的选择，180K 报成 18% | `FactsParser` 认 `/model` 命令和它后面的 `<local-command-stdout>`：输出是「Set model to …」就算接受，别的算没接受。接受的那次进候选、按时间比，`[1m]` 只从最新那次选择接。选单的模型从显示名推（「Opus 4.6 (1M context)」→ `claude-opus-4-6[1m]`），推不出就当「不知道」，不接后缀。输出样式（ANSI 粗体 / 反引号 / 带 effort）是从 obelisk 历史里查到的真实样子。第一次定位找到回复后，为找 `/model` 最多再往回读 2MB | 01520c5c7 |
| 2（P2） | hub 重启后，持久化选择的时间戳丢了，旧回复无条件赢 | 落盘记录按 updatedAt 进候选；转录里 CLI 在它之后（5s 宽限内也算）明确拒了同一个参数，这条记录就不算。「没选过」才用 hub 默认打底 | d7c223693 |
| 3（P2，部分收） | tmux 写入成功就被当成切换成功 | app 的 `/model` 先记成「请求中」：不发布，不当 `[1m]` 来源，hub 收到时就落盘的那条记录也不能借道。确认：转录里这次命令后面是「Set model to」，或下一条回复的模型对得上（同族同版本；别名同族即可）。撤销：CLI 回的是别的，或下一条回复对不上（同参数的落盘记录跟着失效）。10 分钟没下文就丢掉。写进终端后 1.5s 和 6s 各再看一次转录。`/model default` 按之前定的 (b) 映射成 hub 默认，不变（「默认 ≠ CC_MODEL」这半条不收） | 932b478d0 |
| 9（P3） | 新缓存没有边界，绑定换了还补发旧值 | hub：最多 300 个会话，7 天没碰的清掉（在算的不清；闲置回收不算删除，绑定还在）。记下事实属于哪个绑定，换绑定就清掉旧转录的事实；读的期间绑定换了，这次结果作废再算一遍。算不出模型了就发 `model:null`；app 报到补发只发绑定对得上、或本进程拉起过的会话。app：认 `model:null` 并清掉后缀；store 最多 256 项，7 天没碰的清掉 | f01753ddd |
| 6（P2） | 胶囊的订阅者是整个 ChatInputBar | 照 `CCSendStatusBadge` 拆出 `ModelCapsule`（新文件 `Views/ModelCapsule.swift`），自己读 entry；ChatInputBar 只经 `ModelCapsule.entry` 查索引、不读 model。iOS 和 mac 两段代码原样搬过去。单测用 withObservationTracking 证明：模型变了，父视图那一侧收不到通知，胶囊收得到 | 385eb5707 |
| 7（P2，不收） | 设了 `CLAUDE_CODE_DISABLE_1M_CONTEXT` 仍按 1M 算 | 粟粟不用这个开关，这次不做。见遗留 | — |

**测试**：`bun test` 913 pass / 0 fail（返工期间 `agora-store.test.ts` 的 round_robin 用例偶发失败，单跑 3 次挂 1 次，跟这次改动无关）；tsc 206。mac 定向：`Test Suite 'CCSessionModelTests' passed`，7 tests，0 failures；`CCSendStatusTests` 和 `CCSessionPhaseTests` 一起过，`** TEST SUCCEEDED **`。

**遗留 / 未查证**：
- `CLAUDE_CODE_DISABLE_1M_CONTEXT` 没处理（R1-7 不收）：要是开了，天生 1M 的模型会被少算成 1/5 的占用。
- 「Set model to」以外的 CLI 输出（模型不存在 / 不可用时说什么）没有真实样本，现在一律当「没接受」。CLI 要是什么都不输出，就靠下一条回复确认或撤销，10 分钟没下文才丢掉。
- 撤销只影响胶囊和 ctx%，不改落盘记录：下次拉起仍会用那个参数（拉起失败有 cc-model 的一次性降级兜底）。
- 第一次定位，找到回复后为找 `/model` 只再往回读 2MB，更早的切换看不到，只能靠落盘记录。整份往回找最多 8MB，codex 一轮输出超过 8MB 且刚好是第一次定位时，会找不到 turn_context。
- 转录被原地改写（不是只追加）且大小没变，增量扫描认不出来。CC 和 codex 都只追加，这只在测试里出现过。
- 新 codex 会话的 rollout 最多要等索引过期（60s）后的下一次刷新才找得到。
- 胶囊仍然没上屏看过；iOS 那段 `ModelCapsule` 没编过（mac 编过）。

## 军机处默认关闭（粟粟 10-11）+ 撤 K2b

粟粟：「把军机处可以删掉了其实（或者先注释掉。。）」——按「先注释掉」：代码全留，默认不起，一个开关能打开。

**改动**：
- `hub.ts` 军机处初始化段从「`MP_CC_WARROOM` 不是 `0` 就开」改成「**只有 `MP_CC_WARROOM=1` 才开**」。默认启动打一行 `[warroom] 军机处默认关闭（MP_CC_WARROOM=1 打开）`。
- K2b（账本读缓存，`565529ea3` + 文档 `10486f4a1`）整体 revert：账本 30s 轮不跑了，这刀没必要，没审过的代码不上线。`warroom-ledger.ts` / `hub.ts` 回到 K2b 之前（与 `59e3fe0b4` 逐字节一致）。

**重新打开**：hub 环境加 `MP_CC_WARROOM=1`，重启 hub。真 `secrets/warroom.db` 没动，打开后接着用；普查首扫走增量（scan_state 还在）。

**关着时随之消失的现场开销**：
- 普查扫描：约 7700 个 transcript / rollout 文件每 5 分钟一轮 stat + 读 + sqlite 写（K2 之后在 Worker 线程，K2 之前在主线程、最长一轮 154s），每轮的 `ps` / `tmux list-panes` 存活普查和 WAL 检查点。Worker 线程也不起。
- 账本 30s 轮：收据目录 readdir（`~/.mp-warroom/receipts`）→ 开庭（`SELECT tasks … evidence_in`）→ DAG 放行（`readyQueuedTasks`）→ 终审叫醒（`epicsReadyForFinalReview`）。K2b 要省的就是这一轮的 `SELECT tasks` / `SELECT requests`。
- 启动时：开库（切 WAL）及其退避重试、孤儿恢复 / reviewing 救援两条查询、`mkdir ~/.mp-warroom/receipts`。

**关着时各入口的表现**：

| 入口 | 表现 |
|---|---|
| HTTP `/warroom/sessions` `/tasks` `/dispatch` `/verdict` | 503（`indexer not ready` / `ledger not ready` / `warroom not ready`），loopback + token 校验照旧在前 |
| WS `warroom_board` | `{type:"warroom_board_result", ready:false, tasks:[], stats:{}}` |
| WS `warroom_request` | `{ok:false, error:"not ready"}`，不建库 |
| MCP `warroom_*` 四个工具 | 走上面的 HTTP：sessions / tasks 原样回 503 正文；dispatch / verdict 抛「failed (503)」 |
| 闲置回收 | 照旧排除军机处常驻会话（中枢名单 + `MP_WARROOM_DESK`），没改 |
| app 看板 / page2 小组件 | Swift 不读 `ready`；tasks 为空 → 看板「暂无奏折」、小组件「0 项待处理」，不报错。派单 sheet 收到 ok:false 只把「发送中」复位，不提示 |

**测试**：新增 `warroom-off.test.ts`（隔离 hub，临时 HOME / secrets，不碰 7890）：默认时打关闭日志、不建 `warroom.db`、不建 `~/.mp-warroom`、不起 worker、四个 HTTP 端点 503、看板 ready:false、`warroom_request` not ready；设 `=1` 时开库、建收据目录、验收 loop 起、`/warroom/tasks` 200、看板 ready:true。`bun test` 逐文件跑 72 个文件 906 pass / 0 fail，`relay/relay.test.ts` 24 pass；tsc 206 不增。整套一次跑时机器负载 622，`hub-terminal.test.ts` 三条超时 / EPIPE 后卡住（本来就 `MP_CC_WARROOM=0` 跑，跟这次无关），负载回落后单跑 7 pass。

**提交**：`f03c300c7`（撤 K2b）、`efe8f295a`（默认关 + 测试）、本条文档。生产 hub 没动，合并后重启 hub 才生效（问粟粟）。
