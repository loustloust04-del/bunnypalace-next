# 第三方组件与许可

记忆花园 · Mneme Atrium 本身以 [AGPL-3.0](LICENSE) 发布（版权人：Mneme Atrium contributors）。下列第三方组件随 app 一起分发、在构建时链入，或有代码被改编进本仓库，各自保留原许可证。

- **核对日期 2026-10-10**。Swift Package 版本以入库的 `MemoryPalace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 及 `Packages/SwiftStreamingMarkdown/Package.resolved` 为准（另见 `project.yml` 的 `packages:` 段）。
- **许可全文副本**在 `MemoryPalace/Resources/Licenses/`（字体的在 `MemoryPalace/Resources/Fonts/`），随 mac、iOS 两个 app bundle 分发；iOS 版可在「设置 › 关于 › 开源致谢」查看。
- **平台**列：`mac` = macOS 版（含内嵌的 `mp-code` CLI），`iOS` = iOS 版，`both` = 两者都有。

## Swift Package（静态链入 app）

| 组件 | 版本 | 用途 | 平台 | 许可 |
|---|---|---|---|---|
| [swift-markdown](https://github.com/swiftlang/swift-markdown)（经 SwiftStreamingMarkdown 引入） | 0.7.3 | Markdown 语法树 | both | Apache-2.0（+ Runtime Library Exception），附 NOTICE |
| [swift-cmark](https://github.com/swiftlang/swift-cmark)（经 swift-markdown 引入） | 0.8.0 | CommonMark 解析 | both | BSD-2-Clause（含部分 MIT 文件，见其 COPYING） |
| SwiftStreamingMarkdown（仓库内 `Packages/SwiftStreamingMarkdown`，上游 [Microsoft](https://github.com/microsoft/SwiftStreamingMarkdown)） | — | 聊天正文 Markdown 渲染 | both | MIT |
| [HighlightSwift](https://github.com/appstefan/highlightswift)（经 SwiftStreamingMarkdown 引入） | @99c431b | 代码高亮 | both | MIT |
| └ [highlight.js](https://github.com/highlightjs/highlight.js)（HighlightSwift 内带） | 11.9.0 | 代码高亮引擎 | both | BSD-3-Clause |
| [iosMath](https://github.com/maitbayev/iosMath)（`maitbayev` fork，上游 [kostub/iosMath](https://github.com/kostub/iosMath)；经 SwiftStreamingMarkdown 引入） | @066ba2f | 数学公式渲染 | both | MIT |
| └ Latin Modern Math / TeX Gyre Termes Math（iosMath 内带字体） | 1.959 / 1.543 | 公式字体 | both | GUST Font License |
| └ XITS Math（iosMath 内带字体，STIX 派生） | 1.108 | 公式字体 | both | SIL OFL 1.1 |
| [equatable](https://github.com/ordo-one/equatable)（经 SwiftStreamingMarkdown 引入） | 1.0.10 | `@Equatable` 宏 | both | Apache-2.0 |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 1.13.8（固定） | 本机声纹 embedding / Swift C API | both | Apache-2.0；许可副本 `sherpa-onnx.txt` |
| └ [ONNX Runtime](https://github.com/microsoft/onnxruntime)（SPM `onnxruntime-libs`） | 1.28.2（固定） | 本机 ONNX 推理 | both | MIT；许可与官方 `ThirdPartyNotices.txt` 副本 `onnxruntime.txt` / `onnxruntime-notices.txt` |
| [Grape](https://github.com/swiftgraphs/Grape) | 1.1.0 | 记忆图可视化 | both | MIT |
| [VariableBlur](https://github.com/nikstar/VariableBlur) | 1.3.0 | 渐变模糊 | iOS | MIT |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | 备份/导入的 zip 读写 | both | MIT |
| SwiftTerm（仓库内 `Packages/SwiftTerm`，上游 [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) v1.13.0 @8e7a1e1 原样入库 + 宽字符补丁，见 `Packages/SwiftTerm/MP-PATCHES.md`） | 1.13.0 | 终端视图（含 xterm.js 派生代码） | both | MIT |
| [DeviceKit](https://github.com/devicekit/DeviceKit) | 5.9.0（固定） | 终端首页 3D 的本机型号名 | iOS | MIT；许可副本 `devicekit.txt` |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | 2.13.5 | HTML 解析 | both | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | 自动更新 | mac | MIT；内含 bsdiff（BSD-2-Clause）、sais-lite（MIT）、ed25519（Zlib）、SUSignatureVerifier（BSD-2-Clause），均在其 LICENSE 内 |
| [zstd](https://github.com/facebook/zstd)（libzstd） | 1.5.7 | 压缩 | mac | BSD-3-Clause OR GPL-2.0-only 双许可，**本项目选用 BSD-3-Clause** |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | 0.31.6 | 本地模型推理 | both | MIT |
| └ mlx-swift 内嵌：mlx、mlx-c、[{fmt}](https://github.com/fmtlib/fmt) 12.1.0、[nlohmann json](https://github.com/nlohmann/json) 3.11.3 | — | C++ 核心与依赖 | both | MIT |
| └ mlx-swift 内嵌：[metal-cpp](https://developer.apple.com/metal/cpp/) | — | Metal C++ 绑定 | both | Apache-2.0 |
| └ mlx 内嵌：PocketFFT（`pocketfft.h`） | — | FFT | both | BSD-3-Clause |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 3.31.3 | 本地 LLM | both | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.3.4 | 分词器 / Hub 下载 | both | Apache-2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja)（经 swift-transformers 引入） | 2.5.1 | chat 模板 | both | Apache-2.0 |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface)（经 swift-transformers 引入） | 0.11.0 | Hub 客户端 | both | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto)（经 swift-huggingface 引入） | 4.5.2 | 哈希 / 签名 | both | Apache-2.0，附 NOTICE |
| [swift-collections](https://github.com/apple/swift-collections)（经 swift-jinja 引入） | 1.7.1 | OrderedCollections | both | Apache-2.0（+ Runtime Library Exception） |
| [swift-numerics](https://github.com/apple/swift-numerics)（经 mlx-swift 引入） | 1.1.1 | 数值类型 | both | Apache-2.0（+ Runtime Library Exception） |
| [EventSource](https://github.com/mattt/EventSource)（经 swift-huggingface 引入） | 1.5.1 | SSE | both | MIT |
| [yyjson](https://github.com/ibireme/yyjson)（经 swift-transformers 引入） | 0.12.0 | JSON 解析 | both | MIT |

- 标「经 … 引入」的是传递依赖，都在被依赖包的 main target（非 testTarget），随 app 分发。
- **Apache-2.0 §4(d) NOTICE**：进产品二进制且自带 NOTICE 的只有 swift-markdown 与 swift-crypto，两份 NOTICE 原文见 `Resources/Licenses/swift-markdown-notice.txt`、`swift-crypto-notice.txt`。swift-transformers / swift-jinja / swift-huggingface / metal-cpp / equatable 没有 NOTICE 文件。
- swift-crypto 在 Apple 平台上只编 Swift 层，不链它 vendored 的 BoringSSL / XKCP（`Package.swift` 只给 Linux / Android / Windows / WASI / OpenBSD 链）。
- mlx 的 gguf 相关源码（`gguf.cpp`、`gguf_quants.cpp`）在 mlx-swift 的 `Package.swift` 里被排除，gguf-tools 不进二进制。
- `equatable` 的 LICENSE 为 Apache-2.0 标准模板，未填写版权持有人字段，仓库亦无 `NOTICE` 文件。
- `VariableBlur` 的 LICENSE 无 SPDX 标题、正文为 MIT，其版权行含 "Scott Chacon" 等姓名，疑为模板残留；此处按文件原样照录，不代为更正。
- 仅测试 / 构建期用到、不进产品二进制的：swift-argument-parser、swift-asn1（解析进锁，只被 swift-crypto 的 CryptoExtras 依赖，我们不链）、swift-custom-dump、swift-snapshot-testing、swift-syntax、xctest-dynamic-overlay，均为 Apache-2.0 / MIT。

## 打进 bundle 的脚本与资源

| 组件 | 用途 | 平台 | 许可 |
|---|---|---|---|
| [CodeMirror 6](https://codemirror.net)（`codemirror.bundle.js`：@codemirror/state·view·language·search·lang-markdown、@lezer/highlight，esbuild 打包） | 文件库 Markdown 编辑器 | both | MIT |
| [Mermaid](https://mermaid.js.org)（`mermaid.min.js` 12.0.0，npm 发布原样） | 聊天 / 文件库图表渲染 | both | MIT |
| [Readability.js](https://github.com/mozilla/readability) v0.5.0（`readability.min.js`，Arc90 / Mozilla） | 网页正文抽取 | both | Apache-2.0 |
| [Turndown](https://github.com/mixmark-io/turndown) 7.2.0（`turndown.min.js`，Copyright (c) 2017 Dom Christie） | HTML → Markdown | both | MIT |
| [霞鹜文楷 LXGW WenKai](https://github.com/lxgw/LxgwWenKai) | 界面/正文字体 | both | SIL OFL 1.1 |
| [思源宋体 Source Han Serif](https://github.com/adobe-fonts/source-han-serif) | 正文字体 | both | SIL OFL 1.1 |
| [Silkscreen](https://github.com/googlefonts/silkscreen) | 像素风顶栏字体（也进 iOS 小组件） | both | SIL OFL 1.1 |
| [IM FELL English / English SC / DW Pica](https://github.com/google/fonts/tree/main/ofl/imfellenglish)（Igino Marini，`IMFell-LICENSE.txt`） | 死亡天平版画字体 | both | SIL OFL 1.1 |
| [ECDICT](https://github.com/skywind3000/ECDICT)（`ecdict_subset.json` 子集，Copyright (c) 2025 Linwei） | 单词释义 | both | MIT |
| [jQuery](https://jquery.com) 3.5.1（`Resources/CardLib/cardlib-jquery-3.5.1.min.js`，官方 min 文件原样） | 卡里网页的内置库（`mp-card://lib/`） | both | MIT |
| [lodash](https://lodash.com) 4.17.23（`cardlib-lodash-4.17.23.min.js`，npm 发布原样） | 卡里网页的内置库 | both | MIT |
| [Font Awesome Free](https://fontawesome.com) 6.5.2（fontawesome / solid / brands 三份 CSS + solid / brands 两份 woff2；`all.min.css` 为三份 CSS 原样拼接） | 卡里网页的内置图标库 | both | 字体 SIL OFL 1.1、图标 CC BY 4.0、代码 MIT |

## 派生代码（改编进本仓库的源码）

下列文件的代码改编自第三方项目，文件头注明出处；改编部分仍受原许可约束，原版权声明与许可全文见 `Resources/Licenses/`。

### rootshell（MIT）

[kitknox/rootshell](https://github.com/kitknox/rootshell)，`Copyright (c) 2026 Rootshell LLC, Kit Knox`，全文 `Resources/Licenses/rootshell.txt`。平台 both。终端键盘工具条与设置搜索的结构、打分规则改编自 rootshell，共 14 个文件：

- `MemoryPalace/Views/Terminal/`（12 个）：`TerminalArrowJoystickButton.swift`、`TerminalByteComposer.swift`、`TerminalComposeOverlay.swift`、`TerminalCustomKeyEditor.swift`、`TerminalHardwareKeyboard.swift`、`TerminalKeyButton.swift`、`TerminalKeyModel.swift`、`TerminalModifierButton.swift`、`TerminalToolbarLayoutEditor.swift`、`TerminalToolbarSizes.swift`、`TerminalToolbarStore.swift`、`TerminalToolbarView.swift`
- `MemoryPalace/Views/Settings/SettingsSearch.swift`、`SettingsSearchPanel.swift`

只参考了交互做法、未抄代码、不计入派生的：`TerminalWindowSwitchSheet.swift`、`AppearanceSettingsTab.swift`、`CCTerminalPanelView.swift`、`PMBoardAppView.swift`、`SettingsView.swift`。

### Wake（MIT）

[iAmCorey/Wake](https://github.com/iAmCorey/Wake) v0.6.3，`Copyright (c) 2026 Corey Chiu`，全文 `Resources/Licenses/wake.txt`。平台 mac（同一批源码也编进 `mp-code`）。编程会话库的模型、解析规则与工具输出格式改编自 Wake：

- `MemoryPalace/Services/CodingSessions/CodingSessionModels.swift`（`crates/wake-core`）
- `MemoryPalace/Services/CodingSessions/CodingTools.swift`（`mcp/tools.rs`）
- `MemoryPalaceTests/CodingSessionAdapterTests.swift`（`tests/adapter_contracts.rs`，测试，不进产品）

### OpenMinis（GPL-3.0）

[OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis)，GPL-3.0。平台 iOS。这些文件保留 GPL-3.0（文件头 `SPDX-License-Identifier: GPL-3.0-only`），按 GPL-3.0 §13 与 AGPL-3.0 的本应用组合：

- `Sandbox/ish/`（7 个）：`CurrentRoot.h`、`CurrentRoot.m`（上游再往上来自 [iSH](https://github.com/ish-app/ish) `app/CurrentRoot.*`）、`ISHKernel.h`、`ISHKernel.m`、`ISHShellExecutor.h`、`ISHShellExecutor.m`、`RootfsManager.swift`
- `scripts/prepare-rootfs.sh`（改自 `deps/prepare_alpine_rootfs.sh`，构建脚本，不进包）
- 另：`Sandbox/ish/ISHShellBackend.swift` 是本项目自写文件，其中一段 shell 拼接写法抄自 OpenMinis `ISHExecutionCoordinator.swift`，已在该处注释标明。

### Pixelarticons（MIT）

[halfmage/pixelarticons](https://github.com/halfmage/pixelarticons)，`Copyright (c) 2019 Gerrit Halfmann`，全文 `Resources/Licenses/pixelarticons.txt`。平台 both。star、reload、wifi、battery-full 4 个图形光栅化成代码内点阵：`MemoryPalace/Views/Vocab/JournalKit.swift`。

### ThinkingOrbsKit（MIT，vendored）

[Jakubantalik/Libraries](https://github.com/Jakubantalik/Libraries) @`b47ff34`，`Copyright (c) 2026 Jakub Antalik`。平台 both。9 个 `.swift` 原样 vendored 在 `MemoryPalace/Vendor/ThinkingOrbsKit/`，来源与许可全文见同目录 `VENDORED.md`，副本 `Resources/Licenses/thinkingorbskit.txt`。

## 图标与商标

- **Remix Icon**（[Remix-Design/RemixIcon](https://github.com/Remix-Design/RemixIcon)，`Copyright (c) 2017–2026 Remix Design`）：`Assets.xcassets` 里 15 个 `ri-*` 图标（`ri-openai`、`ri-anthropic`、`ri-claude`、`ri-gemini`、`ri-deepseek`、`ri-grok-ai`、`ri-qwen-ai`、`ri-zhipu-ai`、`ri-robot-2`、`ri-emoji-sticker`、`ri-sword`、`ri-stack`、`ri-compass-3`、`ri-history`、`ri-git-branch`）取自 RemixIcon master，按 **Remix Icon License v1.0** 单独授权。该许可不是 OSI 开源许可，这些图标**不受本项目 AGPL-3.0 约束**，使用、再分发须遵守 Remix Icon License v1.0（全文 `Resources/Licenses/remix-icon.txt`）。平台 both。
- **simple-icons**（[simple-icons/simple-icons](https://github.com/simple-icons/simple-icons)）：`ri-openrouter`、`ri-moonshotai`、`ri-ollama` 三个虽带 `ri-` 前缀，实际取自 simple-icons，**CC0-1.0**（全文 `Resources/Licenses/cc0-1.0.txt`）。平台 both。
- **Tux 企鹅形象**（Larry Ewing <lewing@isc.tamu.edu>，用 The GIMP 绘制）：终端首页 3D 的小企鹅照这个形象重画（`MemoryPalace/Views/Terminal/TerminalSceneBuilder.swift`，代码内建模，不含原图文件）。原作者许可：使用、修改须致谢作者与 The GIMP。平台 iOS。
- **商标**：上述品牌 logo（OpenAI、Anthropic、Claude、Gemini、DeepSeek、Grok、Qwen、智谱、OpenRouter、Moonshot AI、Ollama）及 Font Awesome brands 中的品牌图形，商标归各自所有人，本应用仅用于标识对应服务，不表示任何背书或关联。

## 词表

- **NGSL 系列 9 个词表**（[newgeneralservicelist.org](http://www.newgeneralservicelist.org)），CC BY-SA 4.0：`vocab_gap_words.json` 的词头、分级与英文释义取自下列词表，取自这些词表的部分同样按 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) 提供（改动：合并为单一 JSON，加注中文释义与考试标签）。署名原文（全文 `Resources/Licenses/ngsl.txt`）：
  - New General Service List by Browne, C., Culligan, B., and Phillips, J. is licensed under a Creative Commons Attribution-ShareAlike 4.0 International License.
  - New General Service List-Spoken by Browne, C. and Culligan, B., is licensed under a Creative Commons Attribution-ShareAlike 4.0 International License.
  - New Academic Word List by Browne, C., Culligan, B., and Phillips, J. is licensed under a Creative Commons Attribution-ShareAlike 4.0 International License.
  - TOEIC Service List by Browne, C. and Culligan, B., is licensed under a Creative Commons Attribution-ShareAlike 4.0 International License.
  - Business Service List by Browne, C. and Culligan, B., is licensed under a Creative Commons Attribution-ShareAlike 4.0 International License.
  - Fitness English List by Browne, C. and Culligan, B., is licensed under a Creative Commons Attribution-ShareAlike 4.0 International License.
  - New Dolch List by Browne, C. and Culligan, B., is licensed under a Creative Commons Attribution-ShareAlike 4.0 International License.
  - Bible English List by Browne, C. and Culligan, B., is licensed under a Creative Commons Attribution-ShareAlike 4.0 International License.
  - Medical Oral English List by Chartrand, R. & Dilenschneider, R., is licensed under a Creative Commons Attribution-ShareAlike 4.0 International License.
- **IELTS / TOEFL / GRE**：`vocab_gap_words.json` 里的考试标签与部分中文释义整理自公开词表 [mahavivo/english-wordlists](https://github.com/mahavivo/english-wordlists)、[hefengxian/ielts-vocabulary](https://github.com/hefengxian/ielts-vocabulary)。
- `ielts_wordlist.txt`：项目整理。
- `vocab-corpus/`：单词讲解为本项目自生成。

## cc-bridge（随 macOS 版打包的 Mac 端桥接进程）

平台 mac。Bun 运行时与打包进二进制的 npm 依赖的版权、许可与源码指向见 [`cc-bridge/ATTRIBUTION.md`](cc-bridge/ATTRIBUTION.md)（随 app 一起放在 `Contents/Resources/cc-bridge/ATTRIBUTION.md`）；tmux 与 Claude Code CLI 不随 app 分发，按用户本机已装为准。

cc-bridge 的架构最初参考了 Shitsuten 的 cc-self-hosting-guide（https://github.com/Shitsuten/cc-self-hosting-guide），之后经大量改写与扩展。该仓库未附许可证文件，此处仅致谢。

## iOS 离线沙箱（静态链入 **iOS 版**二进制；macOS 版不含）

| 组件 | 用途 | 平台 | 许可 |
|---|---|---|---|
| [iSH](https://github.com/ish-app/ish) 的 ARM64 fork [OpenMinis/ish-arm64](https://github.com/OpenMinis/ish-arm64) | iOS 离线沙箱内核（用户态 Linux） | iOS | GPL-3.0（`0e3a4144` 之后的贡献额外 GPL-2.0），附 `LICENSE.IOS` App Store 分发豁免声明 |
| Alpine Linux minirootfs 3.21.0（aarch64） | 沙箱根文件系统 | iOS | 15 个软件包各自许可的聚合（见下） |

链接位置：`project.yml` 的 iOS target 链入 `libish.a` / `libish_emu.a`（构建产物由 `scripts/build-ish.sh` 生成）；本仓库只含 `Sandbox/ish/` 下的胶水代码（其中 7 个文件派生自 OpenMinis，见上「派生代码」），**未修改 iSH 本身**。iSH 及其修改版的源码由上游 fork [OpenMinis/ish-arm64](https://github.com/OpenMinis/ish-arm64)（公开仓库）提供。

iOS 版二进制因链入 iSH 而按 GPL-3.0 兼容方式分发（AGPL-3.0 与 GPL-3.0 互相兼容，见 GPL-3.0 §13）；这也是本项目 2026-08-26 去掉 Commons Clause 附加条款的原因——GPL 系许可证不允许对被授予的权利施加进一步限制。

### Alpine rootfs 与 GPL-2.0 源码提供

`deps/resources/alpine-rootfs.zip` 由 `scripts/prepare-rootfs.sh` 从官方 `alpine-minirootfs-3.21.0-aarch64.tar.gz` 生成，只改写配置文件，不额外安装软件包。包含的 15 个软件包（读自 rootfs 内 `/lib/apk/db/installed`）：

| 软件包 | 版本 | 许可 | aports 源码包 |
|---|---|---|---|
| alpine-baselayout、alpine-baselayout-data | 3.6.8-r0 | GPL-2.0-only | main/alpine-baselayout |
| alpine-keys | 2.5-r0 | MIT | main/alpine-keys |
| alpine-release | 3.21.0-r0 | MIT | main/alpine-base |
| apk-tools | 2.14.6-r2 | GPL-2.0-only | main/apk-tools |
| busybox、busybox-binsh、ssl_client | 1.37.0-r8 | GPL-2.0-only | main/busybox |
| scanelf | 1.3.8-r1 | GPL-2.0-only | main/pax-utils |
| musl | 1.2.5-r8 | MIT | main/musl |
| musl-utils | 1.2.5-r8 | MIT AND BSD-2-Clause AND GPL-2.0-or-later | main/musl |
| libcrypto3、libssl3 | 3.3.2-r4 | Apache-2.0 | main/openssl |
| ca-certificates-bundle | 20241010-r0 | MPL-2.0 AND MIT | main/ca-certificates |
| zlib | 1.3.1-r2 | Zlib | main/zlib |

- **对应源码**：APKBUILD 与补丁在 Alpine aports 仓库 [`v3.21.0` 标签](https://gitlab.alpinelinux.org/alpine/aports/-/tree/v3.21.0)；上游 tarball 在 [distfiles.alpinelinux.org](https://distfiles.alpinelinux.org/distfiles/v3.21/)。
- **随公开发布提供**：本项目公开发布时，把含 GPL 代码的源码包（alpine-baselayout、apk-tools、busybox、pax-utils、musl）的 APKBUILD、补丁与上游 tarball 作为公开仓库 Release 的附件提供。
- **书面承诺（GPL-2.0 §3(b)）**：自本应用首次分发之日起至少三年内，向任何第三方以不超过实际分发成本的费用提供上述 GPL 软件包完整的、机器可读的对应源码；请在公开仓库 [replica882/mneme-atrium](https://github.com/replica882/mneme-atrium) 的 Issues 中提出。承诺原文与包清单随 app 分发：`Resources/Licenses/alpine-rootfs.txt`；GPL-2.0 全文 `Resources/Licenses/gpl-2.0.txt`。

## 书摘底图（公有领域画作）

书房「书摘」卡片的可选底图，`Assets.xcassets/QuoteArt01–10`。均为公有领域或 CC0，逐张核对过 Wikimedia Commons 文件页的授权模板；来源明细见 `docs/quote-art-sources.json`。

| 资源 | 作品 | 授权 | 来源 |
|---|---|---|---|
| QuoteArt01 | Odilon Redon《Ophelia among the Flowers》c.1905–1908 | Public domain (PD-Art, PD-old-auto-expired) | https://commons.wikimedia.org/wiki/File:Odilon_Redon,_Ophelia_among_the_Flowers,_The_National_Gallery,_London.jpg |
| QuoteArt02 | William Morris《Strawberry Thief》1883 | Public domain (PD-retouched-user; work PD-old) | https://commons.wikimedia.org/wiki/File:Morris_Strawberry_Thief_1883.jpg |
| QuoteArt03 | William Morris《Willow Bough》1887 | CC0 (The Met Open Access) | https://commons.wikimedia.org/wiki/File:Willow_Bough_MET_DP306734.jpg |
| QuoteArt04 | Vincent van Gogh《Almond Blossom》1890 | Public domain (PD-Art, PD-old-auto-expired) | https://commons.wikimedia.org/wiki/File:Amandelbloesem_-_s0176V1962_-_Van_Gogh_Museum.jpg |
| QuoteArt05 | Claude Monet《Water Lilies》1916–1919 | CC0 (The Met Open Access) | https://commons.wikimedia.org/wiki/File:Water_Lilies_MET_DT1856.jpg |
| QuoteArt06 | Pierre-Joseph Redouté《Kamtschatka Rose (Rosa Kamtschatica), from Les Roses》1817–1824 | Public domain (PD-Art, PD-old-100) | https://commons.wikimedia.org/wiki/File:Chapuy,_after_Pierre-_Joseph_Redout%C3%A9_-_Kamtschatka_Rose_(Rosa_Kamtschatica),_from_Redout%C3%A9,_%22_Les_Roses%22,_Paris,_1817%E2%80%931824)_-_Google_Art_Project.jpg |
| QuoteArt07 | Maria Sibylla Merian《Banana Flower and Fruit, from Metamorphosis insectorum Surinamensium》1705 | Public domain (PD-old-70-expired) | https://commons.wikimedia.org/wiki/File:Maria_Sibylla_Merian_Banana_Flower_and_Fruit,_from_Metamorphosis_insectorum_Surinamensium_1705.jpg |
| QuoteArt08 | Henri Fantin-Latour《Still Life with Flowers and Fruit》1866 | CC0 (The Met Open Access) | https://commons.wikimedia.org/wiki/File:Henri_Fantin-Latour_-_Still_Life_with_Flowers_and_Fruit_MET_DT1980.jpg |
| QuoteArt09 | Gustav Klimt《Farm Garden with Sunflowers》c.1906–1907 | Public domain (PD-Art, PD-old-70; Yorck Project) | https://commons.wikimedia.org/wiki/File:Gustav_Klimt_035.jpg |
| QuoteArt10 | Katsushika Hokusai《Bellflower and Dragonfly, from the Large Flowers series》c.1830–1833 | CC0 (Rijksmuseum) | https://commons.wikimedia.org/wiki/File:Ballonklokje_en_libelle,_RP-P-1988-349.jpg |

2026-10-05 语音 P4 补充：Sherpa SDK 1.13.8 的 LICENSE 从实际 SPM checkout 复制；ONNX Runtime 1.28.2 的 LICENSE / ThirdPartyNotices.txt 从其固定版本官方仓库逐字复制。未随 app 分发声纹权重，模型由设备主人自行导入。
