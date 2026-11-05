# la0829 · post-M2 checkpoint：真机上让 hub 推一条 update，岛上数字变

> 这是 plan M3a 原验收「隔离 hub 手动发一条 → 真机岛上数字变」（被 M3a 任务书换成假 token 后欠下的）。
> 粟粟做的部分标 👩；🎩 做的部分标 🎩。**前置：M3b 合入并验收后**。

## 0. 为什么要先合 master

- 装机分流规矩：worktree → iPhone 14、master → Air。**iPhone 14 是刘海屏，没有灵动岛**，验岛只能在 Air → 先把 `worktree-live-activity` 合进 master。
- 生产 hub（launchd `com.susu.cc-bridge-hub`，跑主仓 `cc-bridge/hub.ts`）要认 `register_la_token` 才能收到真 token → 合 master 后要**重启一次生产 hub**（`launchctl kickstart -k`；只重启 hub 不动 tmux session，规矩见记忆「只 kill-session 禁 kill-server」——这里反过来，重启的是 hub 进程本身，CC session 在 tmux 里不受影响）。
- **推送验证不碰生产 hub**：从生产 `cc-bridge/secrets/la-tokens.json` 拷那条真 update 记录到隔离 hub 的 secrets，用 `MP_CC_LA_DEBUG=1 scripts/la-isolated-hub.sh` 推。生产 hub 不需要 `MP_CC_LA_DEBUG`。

## 1. 🎩 合 master + 重启生产 hub

```bash
cd "/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace"
git merge --no-ff worktree-live-activity      # 先确认没别的 session 在动 master 工作树
xcodegen generate
bash scripts/build-cc-bridge.sh               # 主仓的内嵌 hub 二进制（macOS app 用）
# 生产 hub 是 launchd 跑 bun run hub.ts，直接 kickstart：
launchctl kickstart -k gui/$(id -u)/com.susu.cc-bridge-hub
sleep 3 && curl --noproxy '*' -s 127.0.0.1:7890/health
```
验：hub log 出现 `[hub] la tokens loaded`（或同义行）。

## 2. 👩 装 Air（**Debug 配置**，不是 Release——`env` 按 `#if DEBUG` 报 sandbox，Release 会报 production 然后 BadDeviceToken）

- 主仓 cwd → Air（分流规矩）。第一次装：Xcode 会为 `com.susu.MemoryPalace.ios.Widget` 去 Portal 注册带 App Group 的 profile（Automatic Signing；命令行加 `-allowProvisioningUpdates`）。这是友邻【坑 6】，报错会说「profile doesn't include App Groups」，**不是权限问题，是没注册**。
- 装完先别开 app：无需 override（就是要连生产 7890）。

## 3. 👩 起岛 + 让 token 落到 hub

1. 开 app → 设置 → 编程工具 → 最底 DEBUG → 按 `working`。
2. 锁屏弹「Allow Live Activities from 记忆花园?」→ **Allow**（M1 收残局那次没替你点）。
3. 岛出现后，回到 app 前台一下（`recheck()` + WS `didOpen` 全量补报）。
4. 🎩 验：`cc-bridge/secrets/la-tokens.json` 里出现 `update` 记录（`session_name: "mp-cc"`、`env: "sandbox"`），hub log 有 `[hub] la token update ← activity=…`。**没出现** → 看 hub log 有没有 `la_token_nak`，或 app 端 `defaults read com.susu.MemoryPalace.ios ccLiveActivityRegistrations`（真机用 Xcode → Devices 拿容器）。

## 4. 🎩 从隔离 hub 推一条

```bash
cd "/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace"
SEC=$(mktemp -d) && cp cc-bridge/secrets/la-tokens.json "$SEC/"          # 只拷这一份
MP_CC_LA_DEBUG=1 MP_CC_SECRETS_DIR="$SEC" scripts/la-isolated-hub.sh 7899 &   # 脚本已改：显式给的 SECRETS_DIR 会被尊重，AGENT_DIR 仍临时
curl --noproxy '*' -s -XPOST '127.0.0.1:7899/la/push?token=la-test-token' \
  -H 'content-type: application/json' \
  -d '{"activity_id":"<从 la-tokens.json 抄>","state":{"phase":"working","model":"Opus 5","ctx":61,"five_hour":33,"seven_day":12,"since_unix":'"$(date +%s)"',"updated_unix":'"$(date +%s)"',"run_id":"r-manual-1"},"priority":10}'
```
期望：`{"ok":true,"status":200}`；**Air 锁屏/岛上 ctx 从 22% 变 61%**（数字是故意跟 DEBUG 假数据不同的）。
记两个时刻：curl 返回 200 的时刻、Air 上数字变的时刻（priority 10 应该秒级；换 `"priority":5` 再推一条看延迟——那是 M3b 用的档位）。

## 4b. 👩 锁屏小组件（M6 在模拟器上截不到，真机 5 分钟）

- 锁屏长按 → 自定义 → 加小组件：列表里应有「记忆花园 · CC 用量」，circular / rectangular / inline 三种**都能找到**（坑 36）。各放一个。
- 看：**确实是单色**（vibrant，坑 37——提前接受，不是 bug）；circular 是 Gauge 环（长度 = ctx%）、rectangular 三条细横条、inline 一行字。
- 观察项：rectangular 上「15 MIN, 21 SEC AGO」两个单位挤不挤？挤就告诉我，改成短格式。
- 桌面 `systemSmall` 也放一个：彩色、三档色对不对、中间那块空要不要填——你的审美你定。
- 截图各一张给我（锁屏 3 + 桌面 1）。

## 5. 👩 杀 app 再推一条（整刀的价值判据）

上滑杀掉 app → 🎩 再 curl 一条 `ctx: 77` → 岛上变 77% = **app 不在跑也能更新**，成立。

## 6. 记录

结果（两个时刻 + 截图）写回 `README.md` 在飞账本 checkpoint 行；不成立的话，按 hub log 的 status/reason 定位（400 BadDeviceToken = token/env 不匹配；403 = 证书/topic；200 但不变 = content-state 解不出来→对 golden 查字段）。
