# Review：小芽 v2 · P4 本地大脑（分支 `xiaoya-p4`，未合 master）

- 日期：2026-09-26（🎩）
- plan：[plan-小芽-v2.md](plan-小芽-v2.md) §6 / §9 P4
- 验证：`AssistantLocalTurnTests` 4 / `AssistantModelStoreTests` 6（假网络：镜像回退、Range 续传、服务器不理 Range、sha256 不符、原子安装、删除）+ 既有小芽测试全过；mac 上**真模型端到端一轮**：读工具 → 回灌结果 → 回答，全链通；iOS 真机架构 / 模拟器编译（见提交）。**真机上下载 1 GB + 实聊没做**

## 0. 为什么还没合 master（要粟粟拍）

1. **构建插件要信任一次**：mlx-swift 带 `CudaBuild` 构建插件（Apple 平台上是空操作：只打一行「CUDA is disabled」就返回）。命令行 xcodebuild 不信任就直接失败——合进 master 后，**全机所有 session 的 MemoryPalace 编译都会挂**，除非：
   - (推荐) 你在 Xcode 里打开工程，点一次「Trust & Enable」（只信这一个插件，信任记在 `~/Library/org.swift.swiftpm/security/`，命令行也认）；
   - 或者给构建锁脚本 / fastlane 全局加 `-skipPackagePluginValidation`（等于所有包插件都免检，不推荐）。
2. **代价**：每次冷编译多编一遍 MLX 的 C++（约 1.5 分钟）；app 包体 +30 MB 量级（P0 实测）。
3. **版本**：钉 **3.31.3**（不是 P0 验过的 3.31.4）。3.31.4 要 swift-syntax 602..<604，跟渲染器的 `equatable` 1.0.10（600..<602）解不出来；升 equatable 要跨 4 个小版本、动聊天正文渲染，不值。3.31.3 上 Qwen3 工具调用实测照样全对（research §8 补记）。

## 1. 边界情况

- **模拟器**：一切 `import MLX*` 的代码在 `targetEnvironment(simulator)` 下编成空壳；设置里本地段整段隐藏；引擎在模拟器上永远走云端。
- **没装好 / 没开**：`activeInstalledDirectory` 要「开关开 + 选中的模型装好」两个都满足，否则走云端；云端也没配 → 提示去设置装本地大脑或选 API 模型。
- **下载**：钉 revision + 每文件字节数 + 权重 / 分词器 sha256；先下到 `<id>.partial/`，全部核对通过才整体换名；200（不理 Range）从头写、206 核 Content-Range 起点、416 视大小判完成或重下；HF 失败换 hf-mirror；剩余空间 < 所需 × 1.2 不开下；默认只走 Wi-Fi，蜂窝下显示「用流量下载」按钮；目录不进 iCloud 备份。**下到一半 app 被杀**：下次进设置显示「已下 X，继续」，续传。
- **残缺工具调用**：小模型写坏的 `<tool_call>` 不显示，换成「没弄懂」+ Sob。
- **卸载**：面板消失 / app 进后台 / mac 右栏切走 / iOS 内存警告 / 关开关 / 删模型 → 停推理并放掉模型和 GPU 缓存。
- **楼层切换 / 停止**：沿用引擎的 runId：本地推理的晚到 token 一律丢弃；停止时 backend.cancel() 取消推理 Task。

## 2. 与下一步交互的风险

- **小模型选工具不稳**：15 个工具（mac）时，「看世界书」它先调了 `list_world_books` 且塞了个多余参数，第二轮能正确总结。iOS 上是 18 个工具，准确率没测。如果实聊里乱调多了，下一步按意图裁工具（D4 当时说的「先全量实测、差再裁」）。
- **速度**：mac 上 3.31.3 实测首轮 11.7 s（含加载）、生成 17–30 tok/s；P0（3.31.4）时 110 tok/s。当时机器上有别的 session 在编译，不能确定是版本还是负载。真机 Air 上要实测。
- **内存**：1.7B 峰值 ~720 MB（P0 mac 实测）；4B 预计 ~2 GB。iOS 没加 `increased-memory-limit` entitlement，4B 在 Air 上会不会被 jetsam 要真机看。
- **3.31.3 的工具回合格式**：3.31.3 的消息不带工具调用 / id，按 Qwen 原生 `<tool_call>` / tool 角色写进正文——只对 Qwen 系模板成立，以后换别家模型要重写这段。

## 3. 技术债

- 下载只在前台跑（没用后台 URLSession），切走 app 会断，靠续传补。
- 下载进度的「已下」在服务器不理 Range 重头写时会多算一段（只影响显示）。
- 本地模式的 token 预算是粗估（12 条 × 600 字），没有真的数 token。
- 端到端真模型测试没入库（要 1 GB 权重）；只在 mac 上手跑过一次。
