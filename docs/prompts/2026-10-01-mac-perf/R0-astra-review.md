# astra 对抗审：mac 性能 R0（研究 + 简报 + 计划初稿）

你是对抗审稿人。审的是记忆花园（SwiftUI + SwiftData 的 iOS/macOS AI 聊天 app）macOS 性能冲刺的第一轮产出。目标：找出**事实错误、归因错误、漏掉的大头、测量方案里会让数据不可信或伤到粟粟真实数据的漏洞、计划里过度设计或顺序错误的地方**。不要客套，不要复述。

## 审什么（钉在提交 140a4790，用 `git show 140a4790:<path>` 读）

- `docs/research-mac-perf.md`
- `perf-mac/BRIEF.md`
- `docs/plan-mac-perf.md`
- 背景任务书：`docs/prompts/2026-10-01-mac-perf/R0-research.md`
- 参照 iOS 那轮：`perf/BRIEF.md`、`perf/报告.md`、`docs/plan-perf-flash.md`（§6 起历次裁决）、`MemoryPalace/Utils/PerfHarness.swift`

## 重点核查

1. **归因是否站得住**：每条「转菊花 / 2GB 写 / 全表计数 / 主线程迁移」结论，回到它引用的 `文件:行号` 和 `/Library/Logs/DiagnosticReports/记忆花园_*`、HangProbe 落盘采样去核（只读）。证据对不上、置信度标高了、或者有更可能的原因，都指出来。
2. **漏掉的大头**：mac 主线程上还有什么没进清单但量级可能更大的（SwiftData 主 context fetch、NSHostingView 层级、@AppStorage 风暴、图片解码、文件监听、Timer）。给 `文件:行号`。
3. **09-25 那次 39.8s hang**：研究里是否真的解释了（主线程卡在 NSHostingView.beginTransaction / Update.ensure）？没解释就说。
4. **测量方案**：bench 包换 bundle id + 独立数据目录是否真能隔离（App Group、钥匙串、iCloud/CloudKit 容器、UserDefaults 域、cc-bridge / 生产 hub 流量、文件监听 `~/.claude` 的目录）；双观察者口径；编译负载门；租约；冷缓存定义在 mac 上是否可行；样本量。
5. **计划**：顺序（先地基再下刀是否合理，哪些刀可以不等测量台就先做因为证据已足够）、每刀开关 / ABBA / UI 回归是否可执行、mac UI 回归的补法是否现实、todo 是否颗粒度够。
6. 拍板问题 Q1–Q8 有没有问错或漏问。

## 输出

写到报告文件（命令行 `-o` 指定）。格式：每条一个编号，标级别【阻断 / 重要 / 建议】，写清：问题、证据（`文件:行号` 或报告文件名）、建议改法。最后一段写「总评」三句话以内。

## 红线

只读 + 只写报告。不改任何文件、不 git 写、不 build、不启动/杀 app、不读粟粟真实数据库内容（`~/Library/Application Support/MemoryPalace`、`~/Library/Caches/MemoryPalace/*.sqlite` 的内容都不许读，只能看大小/修改时间）、不 sample/spindump、不联网。
