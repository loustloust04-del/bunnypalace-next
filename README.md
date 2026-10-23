# 记忆花园 · Mneme Atrium

> **0.x 预览版。** 能用，但还在快速变化：数据格式可能迁移，界面会改，有些功能还在路上（见下方「还在路上」）。
> *0.x preview — usable, but moving fast. English below.*

记忆花园是一个 macOS / iOS 原生的 AI 聊天客户端，也是你过往 AI 对话的家。

- **把历史搬进来**：导入 Claude、ChatGPT 等官方导出包，分支、思考过程、工具调用、图片一起保留。
- **AI 记住你**：每轮对话后异步提取原子记忆，按重要度和时间衰减，在预算内注入下一轮；你能看、能改、能钉住、能删。
- **你决定它怎么说话**：楼层（彼此隔离的空间，各有自己的角色、人设和配置）+ 酒馆式 prompt 插槽、世界书、正则脚本。
- **口袋里的小电脑**：iOS 上内置离线 Linux 沙箱（iSH + Alpine），模型能用，你也能直接开终端；还能配对自己的电脑，接上 Claude Code / Codex 会话。

## 现在有什么

| | |
|---|---|
| **导入** | Claude（新旧三代导出包，含项目、记忆、Artifacts）、ChatGPT（设置页导出 / 隐私门户全包）、Kelivo、SillyTavern 角色卡 / 世界书；Gemini（Takeout / AI Studio）和 RikkaHub 为实验性。只在本机读文件，不联网。 |
| **模型** | 17 家预设（OpenAI、Anthropic、OpenRouter、DeepSeek、Gemini、Moonshot、Ollama 等），任意 OpenAI 兼容 / Anthropic 协议的自定义地址；ChatGPT 账号登录（非官方，见下）。key 存在系统钥匙串。 |
| **对话** | 完整分支树、流式 Markdown 渲染（含 Mermaid 图）、思考过程与工具调用时间线、全局预算闸。 |
| **记忆** | 原子记忆档案、衰减、注入预算、手动编辑与找回。 |
| **终端** | 三格：手机里的小电脑（离线沙箱）/ 我的电脑（配对的 hub）/ Agent（电脑上的 Claude Code、Codex 会话）。 |
| **子应用** | 书房、日历、文件库、学堂、单词等一组小应用。 |
| **Mac** | 多栏工作区，随包带 Claude Code 桥接（cc-bridge）和 `mp-code` 命令行。 |

系统要求：**macOS 15+ / iOS 26+**。

## 还在路上

这些是 roadmap，不是 bug：

- 记忆系统的后几个阶段（记忆工具、跨窗口时间轴、整理重写）正在做，0.x 期间记忆的数据结构还可能迁移。
- 挂载外部文件夹给沙箱；浏览器子应用的「AI 直接操作」。
- 更多导入来源；Gemini、RikkaHub 导入转正。
- 新版聊天页（UIKit 重写）不在这个版本里。

## 非官方声明

记忆花园是独立项目，与 OpenAI、Anthropic、Google 及其他模型提供商**没有任何关联**，也未获其认可。

**ChatGPT 账号登录是非官方的**：它复用了 OpenAI Codex CLI 公开的 OAuth 流程，不是 OpenAI 提供给第三方应用的接口，随时可能失效，使用前请自行判断是否符合你的账号条款。不想用就别点，用 API key 一样能聊。

## 从源码编译

见 [BUILDING.md](BUILDING.md)。简单说：Xcode 26+、`xcodegen`、复制一份签名配置；Mac 版还要 bun，iOS 版还要 iSH 的工具链（一条 `brew install`）。架构导览见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 参与

欢迎 issue 和 PR，流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。第一次提 PR 需要签一份贡献者许可协议（[CLA.md](CLA.md)），机器人会在 PR 里提示你。

**提 issue 时请别贴真实聊天记录、导出包或 API key**——需要样本就先脱敏，或者做一份合成的。

## 许可

代码以 [GNU AGPL-3.0](LICENSE) 发布。第三方组件（包括 GPLv3 的 iSH）及其许可见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。

---

## English

**Mneme Atrium (记忆花园, "Memory Garden")** is a native macOS / iOS AI chat client and a home for your past AI conversations. It is a **0.x preview**: usable, but data formats may still migrate, the UI will change, and some features are still on the way. The app UI is currently Chinese-first.

**What it does**

- **Bring your history**: import official exports from Claude and ChatGPT (branches, thinking, tool calls and images preserved), plus Kelivo backups and SillyTavern character cards / world books. Gemini (Takeout / AI Studio) and RikkaHub imports are experimental. Imports read local files only; nothing is uploaded.
- **It remembers you**: after each turn, atomic memories are extracted in the background, decayed by importance and age, and injected into later turns within a token budget. You can inspect, edit, pin and delete them.
- **You decide how it talks**: isolated spaces ("floors", each with its own character, persona and settings), SillyTavern-style prompt slots, world books and regex scripts.
- **A small computer in your pocket**: on iOS, an offline Linux sandbox (iSH + Alpine) usable by both the model and you through a terminal. You can also pair your own computer and attach Claude Code / Codex sessions.
- **Providers**: 17 presets (OpenAI, Anthropic, OpenRouter, DeepSeek, Gemini, Moonshot, Ollama, …) plus any OpenAI-compatible or Anthropic-protocol endpoint. API keys live in the system keychain.

Requires **macOS 15+ / iOS 26+**.

**Still on the way**: later memory stages (memory tools, cross-window timeline, consolidation), mounting external folders into the sandbox, "AI drives the browser", more import sources, and the rewritten (UIKit) chat page.

**Not affiliated** with OpenAI, Anthropic, Google or any model provider. **The ChatGPT account sign-in is unofficial**: it reuses the public OAuth flow of OpenAI's Codex CLI rather than an API offered to third-party apps, and it may stop working at any time. Check your account terms before using it; API keys work without it.

**Build from source**: see [BUILDING.md](BUILDING.md). **Architecture**: [ARCHITECTURE.md](ARCHITECTURE.md). **Contributing**: [CONTRIBUTING.md](CONTRIBUTING.md); first-time contributors sign the [CLA](CLA.md) through a bot on the PR. Please never paste real chat logs, export packages or API keys into issues.

**License**: [GNU AGPL-3.0](LICENSE). Third-party components, including GPLv3 iSH, are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
