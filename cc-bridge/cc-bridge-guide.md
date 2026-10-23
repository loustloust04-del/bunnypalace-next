# 让手机连这台 Mac

用你订阅的 **Claude Pro / Max**（不是 API key）在记忆花园里跟 Claude Code 聊天、在手机上开这台 Mac 的终端。
三步，大约 15 分钟。

---

## 第 1 步：装 Homebrew 和 tmux

打开「终端」App，先装 Homebrew（已经装过就跳过）：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

装完按它最后提示的那两行把 brew 加进 PATH，然后装 tmux：

```bash
brew install tmux
```

> 装 Homebrew 时会顺带装上「命令行工具」，里面有 python3（思考过程、提问卡要用）。

---

## 第 2 步：装 Claude Code 并登录

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

装好后在终端里跑一次 `claude`，按提示用你的 Claude 账号登录，看到输入框就可以 `/exit` 退出了。

想在手机上也开 Codex 窗口的话（可选）：`brew install codex`，同样跑一次 `codex` 登录。

回到记忆花园 设置 →「让手机连这台 Mac」，看「依赖检查」：tmux、Claude Code CLI 都是绿勾就行。缺哪个点旁边的「复制命令」。

---

## 第 3 步：打开「让手机连这台 Mac」，扫码

1. 在「让手机连这台 Mac」页打开 **启动 CC 桥接**。状态变成「运行中」就好了；以后打开记忆花园会自动启动，退出时自动停。
2. 点 **配对手机**，弹出二维码。
3. 手机上打开记忆花园 设置 → **我的电脑** → **扫码配对**，对准二维码。

配好后手机上的「终端」就能开这台 Mac 的 shell、Claude Code 和 Codex 窗口。

> 这台 Mac 已经装过独立的 hub（比如用脚本装的常驻服务）时，开关不会再起一个，页面会写「这台 Mac 已有 hub 在跑，手机配它就行」，直接点「配对手机」即可。

---

## 可选：Agent 干活的目录

手机上 [+] 开的「新 Claude Code」「新 Codex」窗口默认开在 Agent 的家里。想让它们直接开在你的项目文件夹：在「让手机连这台 Mac」页的 **Agent 干活的目录** 里选一个文件夹（手机上「我的电脑」页也能改）。对话里的 Agent 不受影响，一直住在家里。

---

## 可选：给对话里的 Claude 写个人设

Agent 的家里有个 `CLAUDE.md`，Claude Code 每次启动都会读。留空也能聊（默认的 helpful assistant）；想让它按你的人设说话，就写进去：

```markdown
# 我希望你是

[你想它扮演什么角色 / 一段背景设定]

# 我希望你怎么回我

[长短、用词偏好、要不要 emoji、口语还是书面]

# 不要做的事

[你的禁区]
```

家的位置在「让手机连这台 Mac」页「Agent 干活的目录」下面那行小字里（「Claude 的家」）。写好后新开的对话生效。

---

## 排查

| 现象 | 原因 + 处理 |
|---|---|
| 依赖检查里有红叉 | 点旁边的「复制命令」，粘进终端跑 |
| 开关打开后状态变「崩溃」 | 展开下面的「Hub 日志」看最后几行 |
| 二维码出不来 | 开关没开，或 hub 还在启动；等状态变「运行中」再点 |
| 手机上扫了码还是连不上 | 手机和 Mac 不在同一个 Wi-Fi 时要两边都开 Tailscale；在咖啡店这类网络建议关掉 LAN 只留 Tailscale |
| 手机上 [+] 里「新 Claude Code」是灰的，写着「电脑上还没装」 | 回第 2 步装 Claude Code，装好后几分钟内会自动变可用 |

---

## 致谢

记忆花园 cc-bridge 模块用了这些开源软件：Bun（MIT，静态链入 LGPL 的 JavaScriptCore / WebKit 等）/
@modelcontextprotocol/sdk 等 npm 依赖（ws 由 Bun 内置实现替换，未打包）。完整版权 + 协议条文见同目录 `ATTRIBUTION.md`。
