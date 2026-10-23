# 记忆花园 Mac CHANGELOG

## v1.1.0 (2026-06-20)

### 新增：Claude Code 桥接（cc-bridge）整合
- 设置 → Claude Code → **「启动 CC 桥接」开关** 一键起 hub 子进程（不再需要手动 `install-launchd.sh`）
- **依赖检查面板** 4 行勾选：Bun runtime（内置）/ tmux / Claude Code CLI / Node.js，缺哪个旁边一键复制安装命令
- **Hub 日志面板** 展开看实时 hub stdout/stderr，最近 500 条环形缓冲
- **健康检查 watchdog** 每 10s 探 hub /health，连续 3 次失败自动重启（60s 限频防 crash loop）
- **「连接说明文档」按钮** 弹出内置 markdown viewer，5 节手把手教配 MCP + 写 CLAUDE.md 人设
- App 退出时 hub 自动 SIGTERM + 3s 后 SIGKILL，不留尸进程
- hub token 走 Keychain（账号 `cc-bridge-hub-token`，本机限定不同步），端口 OS 动态分配
- bundle 进 .app/Contents/Resources/cc-bridge/：hub + mcp-server × arm64/x86_64 = 4 个 ~58MB 二进制

### 改造
- 推送通知区 **置灰**（v1.1 上架版未启用，hub 用的 APNs 证书属于开发者不能给所有用户）
- APNs cert 缺失时 hub 静默 skip 推送，不抛错（`apns.ts` stub 化）
- GUI app PATH 增强：spawn 子进程时 prepend `/usr/local/bin:/opt/homebrew/bin:~/.bun/bin:~/.local/bin`，
  解决 GUI 启动的 app 找不到 brew/npm 装的工具

### 体积
- DMG 147MB（v1.0 是 49MB），增量主要是 4 个 bun-compiled 二进制（共 ~240MB）+ DMG 压缩

### 用户体验提示
- 上架版 cc-bridge 走 Developer ID 分发（不上 Mac App Store），首次打开右键→打开
- 装 cc-bridge 前提：用户自行 `brew install tmux node` + `npm i -g @anthropic-ai/claude-code`，
  app 内依赖检查会提示
- 配套独立文档：`~/Downloads/记忆花园-CC桥接说明.md`（分发给朋友看用）

---

## v1.0.0 (2026-06-19)

首版 Mac DMG，含核心聊天 + 记忆 + 读书 + 联网搜索 + 反馈机制。
