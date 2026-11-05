# 全栈代码体检（2026-06-10）

对全项目（146 文件 / 51,673 行）的一次只读代码审查。八维度（架构/SwiftData/并发/性能/错误处理/卫生/macOS 适配/依赖构建），产出 4 P0 / 24 P1 / 60+ P2。

## 文件索引

| 文件 | 内容 |
|------|------|
| [CODE_REVIEW.md](CODE_REVIEW.md) | **总报告**——全部 issue 按 P0/P1/P2 分级 + 维度覆盖表 + 技术债热力图 + 修复顺序建议 |
| [集群报告-01-聊天UI.md](集群报告-01-聊天UI.md) | CardFlowView / MessageSegmentsView / ChatBubbleStyle / 附件与导出 sheet |
| [集群报告-02-导航侧栏.md](集群报告-02-导航侧栏.md) | ContentView / SidebarView / BranchMapSheet / ImportView / ImportHistoryView / Dashboard |
| [集群报告-03-设置页.md](集群报告-03-设置页.md) | 18 个设置 tab + SettingsView + 编辑器 + API key 安全专项 |
| [集群报告-04-数据管线.md](集群报告-04-数据管线.md) | 导入器 ×2 / 统一迁移 / SearchService / MemoryService / 数据安全专项 |
| [集群报告-05-集成层.md](集群报告-05-集成层.md) | CCBridgeWebSocketClient / MCP 五件套 / 文件库 / Prompt 组装 / Keychain / 安全专项 |
| [集群报告-06-贴纸主题.md](集群报告-06-贴纸主题.md) | 贴纸全家桶 / 小组件（宠物/花园/Todo/Dashboard）/ 主题体系 / Web / Paging / CC 面板 |

## 方法

- 核心路径逐行人工深读：全部 12 个 @Model、MemoryPalaceApp、ChatService、ConversationViewModel、APIProvider、MarkdownExporter、ContentCleaner 等
- 6 个并行审查代理覆盖其余集群，每份报告的 P0/关键 P1 均经原文行号二次抽查核实（12 次抽查无虚报）
- 全局 grep 扫描：try?（404 处）、力解包、print、TODO、死代码、@Query/FetchDescriptor 全景

## 后续

修复批次规划见项目根目录 `REFACTOR_PLAN.md`。
