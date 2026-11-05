# Review：小芽助手（MVP）

- 日期：2026-09-10（pi-lane）
- 对应 plan：`docs/plan-小芽助手.md`

## 1. 边界情况

- **提案后切楼层再点应用** → 已处理：预设/世界书提案 payload 带 `profileId` 锚，apply 时校验不一致即作废报「让小芽重新提一次」。角色卡是全局卡库（UserDefaults），无楼层概念，不受影响。
- **提案后用户手动改了同一目标再点应用** → 未处理：last-write-wins，提案里的新内容直接覆盖。payload 没有前置条件校验（如「旧值仍是 X 才应用」）。下轮可加 expected-old 校验。
- **appliedNotes 丢失**：应用/丢弃结果存在引擎内存，用户应用后若不继续发消息就关面板，模型永远不知道结果。可接受（结果本身已落库，下次查得到），但有体感断层。
- **模型裸写 JSON**：provider 不支持 tool calling 时没有文本协议降级，模型若把工具调用写成正文会原样显示给用户。见 §3。
- **多行输入框 onSubmit**：`TextField(axis: .vertical)` 下 Return 键行为依赖系统，可能换行而不是发送；发送按钮兜底。
- **提案并发**：一轮里模型可以连提多个提案，全部挂到最后一条消息；用户逐个应用，互不影响（apply 幂等性依赖目标仍存在，找不到就报错，安全失败）。

## 2. 与下一模块交互的风险

- **AssistantContext 是契约点**：`report(page:)` 目前四个模块上报。记忆时间线投影（research-对比 §1）和主动消息（§2）都会想读「用户在哪/在干嘛」，应复用这个单例而不是另建通道。
- **queryMemories 是单点**：记忆素材源换成 TimelineProjector 时只改 `AssistantTools.queryMemories` 一处。
- **resolveModel 是单点**：现在复用 `selectedChatModel`；上辅助 API 槽（小卷 §7.6）时只改 `AssistantEngine.resolveModel`。
- **Gemini 多轮工具调用**：小卷实测 reasoning 必须回传否则丢上下文。我们的 ChatService 若已处理则小芽自动继承；没处理的话小芽多轮工具链在 Gemini 上会退化。未验证。
- **数据面**：引擎复用面板环境的 ModelContext（主 actor），worldbook 写在主线程——条目量大时 apply 会卡 UI 一拍，目前条目规模下无感。

## 3. 技术债务

- **历史不落盘**：messages 是面板 @State，关面板即清空。要持久化得加存储层（建议等需求真出现再加）。
- **双协议只交付了原生一路**：plan §4.2 的文本协议降级（XML 解析）没做——MP 主聊天本身也只有原生 tool calling，保持一致，列为已知缺口而非退步。
- **persona 覆写是全局的**：`xiaoya.personaOverride` 不分楼层。小芽是元层助手，全局人设说得通；若未来要「每层楼不同性格的小芽」再拆。
- **页面上下文只有页面名**：`draftSummary` 字段留了但没接（各模块草稿上报是下一层级的活）。
- **图标双轨**：dock/设置里小芽是 SF `leaf.fill`，Page2 桌面是 ya3d 3D 图（Page2AppIcon 特例）。若以后 AppIconView 支持原色 asset，可收拢。
- **实测未跑**：双端 build 过，但「写一张卡→应用→进卡库验证」的端到端手测没做（需设备）。
