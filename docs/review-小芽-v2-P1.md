# Review：小芽 v2 · P1 舞台窗口

- 日期：2026-09-26（🎩）
- plan：[plan-小芽-v2.md](plan-小芽-v2.md) §3 / §9 P1 · 提交 `ad018a9e`
- 验证：mac + iOS（iPhone 17 Pro 模拟器目的地）双端 build ✅；`XiaoyaMoodTests` 6 / `AppIconTests` 12 / `SettingsSearchTests` 全过；mac 离屏渲染截图（浅 / 深 / 空态 / 9 表情 + 收起态）目视 ✅。**iOS 真机 / 模拟器目视未做**（见 §1 末条）

## 1. 边界情况

- **表情资源**：九张脸原图里小人的「白」是不透明奶白，不是透明——直接 template 会染成实心剪影。已按亮度把奶白转成透明（入库时一次性处理），深色模式下就成了奶白线条的「负片」效果（像版画反印），是刻意接受的，不是 bug；她要是觉得深色下怪，可以改成深色模式给脸垫一块奶白小卡。
- **资源倍率**：只标 `@3x` 在 macOS 资源目录里直接加载不到（mac 只认 1x/2x），改成单一尺寸。以后再加 xiaoya 素材照这个做，`AppIconTests.testXiaoyaAssetsExistAndAreTemplate` 会兜住。
- **舞台收放**：用 `visibleRect` 算离底距离，80 收 / 24 放；短对话（不满一屏）距离恒为 0，舞台一直展开。流式输出时如果你往上翻（离底 > 80），不再把你拽回底部；发送新消息时强制回到底部并展开。未在 iOS 实机上测键盘弹起时的收放和跟底（键盘改变可视区高度，理论上 `visibleRect` 跟着变，结论要实测）。
- **短暂反馈与主状态**：盖章 → Love 2.5 s 后回到主状态；此时如果还有别的待盖章卡，回到 Cheer，不会误回 Smirk。停止 → Shock。连续触发时新反馈顶掉旧的，旧计时器失效（测试覆盖）。
- **Nope 的触发面很窄**：P1 只有「模型调了不存在的工具」才会触发；astra B10 砍掉了关键词判断。P2 权限包上线后，「调了关掉的包里的工具」也走这条。
- **iOS 目视没做**：粟粟的 iPhone 17 Pro 模拟器当时在跑别的 session 的 `--kb-probe-seed`，按「整机一台模拟器」规矩没装包、没开第二台。Page2 里的实际观感（顶部安全区、Page2 壳的左上角手势区是否压到舞台）待补。

## 2. 与下一模块（P2 盖章 + 账本）交互的风险

- **提案卡还是 P1 过渡版**：`AssistantPanelView.actionCard` 只换了皮（「不要 / ✓ 盖章」），数据仍是旧的 `detail` 纯文本、盖章后卡片仍被删除。P2 会整块换成 `AssistantProposalCard`，这个函数到时整个删。
- **awaitingStamp 的判定**：现在用「消息里还挂着 actions」判断（因为盖章 / 丢弃后 actions 会被 removeAll）。P2 改成卡片留存 + status 后，要改成「存在 status == pending 的卡」，否则历史里所有已处理的卡都会让她一直 Cheer。**这是 P2 必改点**，已在这里标出。
- **engine 的状态字段**：`readingLabel` / `lastRunFailed` / `feedback` 是 P1 加的，P2 引入 runId 后，这几个字段的写入也要核 runId（旧 run 的晚到回调不能改表情）。
- **XiaoyaSkin 目前是纯函数**（按深浅色选 cream / night）。P3 的「窗口皮肤」工具要把它变成可持久化的 store，`XiaoyaSkin.current(_:)` 是唯一取值点，改那里即可。

## 3. 技术债

- 设计稿里的「铃兰角标 / 五线谱分隔」没做（空态只有问候文案）。纹样素材已切在 `docs/assets/xiaoya-v2/`，要加就是再进两个 template 资源。
- 离屏快照测试没入库（它会临时改写 `AssistantChat/history.json`，虽然会还原，但入库后每次全量测试都去碰真实数据不合适）。脚本留在 session 草稿目录；以后要做正式视觉回归，得先给 `AssistantEngine` 加注入存储的入口（P2 改写盘时顺手做）。
- 共享工作区事故：我暂存的 `ya3d.imageset` 删除被另一个 session 的提交 `b3cbc523`（docs(search)）顺带提交了。内容无害，但提交归属乱了——多 session 同工作区时，暂存区是共享的，`git rm` 之后应该立刻提交。
- mac 右栏宽度下（~320pt）舞台表情 76pt，快照按 380 宽渲染，没专门截 320 宽。
