# 任务书：气泡模式输入框紧急修复（hotfix 工位）

工位 `/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace/.claude/worktrees/hotfix`，分支 `zone/hotfix`（共享工位：先 `git status`，不准动别人的未提交改动）。HEAD `9e8f5d550` = master `f74ed9bd0` + 车头摘过来的 T1（把气泡模式输入栏退回改版前、和文章模式一样的老版本）。中文写提交说明。

## 粟粟在 Air 上的原话（日用机，非常急）
- 「换行完全没了，发送键也被吞了」：当时那版 = 气泡模式第二轮 #00496 + backend-001 的 #00498。
- 退到 f74ed9bd（去掉 #00496、保留 #00498），说「还是有问题」。
- 退到 43147d53（两个都不含，气泡模式输入栏还是第一轮的 iMessage 式）：「495 气泡模式输入框还是不正常」。

## 嫌疑
1. 第一轮把气泡模式输入栏改成了 iMessage 式，她不要。T1 已经摘过来修了，**需要你验证**：现在的输入栏代码和 `04feebbe0`（改版前，她用着没问题）一致，除了 #00498 的改动。用 `git diff 04feebbe0 HEAD` 核对：输入栏相关文件（`ChatInputTextView`、`InputFieldContainer`、`ChatInputRepresentable`、`ChatInputBar`、`KeyboardInsetBridge`、`PagingViewController`、`VoiceRecordController`、`InputBarStack`）。
2. #00498（backend-001 的草稿持久化 / 发送排队）：
   - `MemoryPalace/Views/InputBarStack.swift:92–110`：把 `$draftText` / `$vmB.selectedAttachments` 换成了手写的 `Binding(get:set:)`，每次 body 都新建一个，set 时还做差分落盘。
   - `:134`：每打一个键调一次 `persistText`，可能拿旧快照回写，把带换行的文字盖掉。
   - `ConversationViewModel.sendMessage` 加了对话级门控：同一对话有 turn 在跑或树还在加载时，消息进 `pendingSends` 排队并返回 true，输入框照样清空；另外发送前可能等 wiki 预热，最多 5 秒。
   - 这套是为了修「切对话时旧的空快照 flush 盖掉刚恢复的草稿」加的。不管回退还是修改，`InputBarDraftPersistenceTests`、`MacComposerDraftTests` 都必须继续通过。

## 要做
1. **用真实路径复现**：在 iOS 测试宿主（`MemoryPalaceIOSTests`，参考 `BubblePageSnapshotTests` 起真实 `WindowGroup`）挂**真实的 `InputBarStack`**（不要用测试替身 Composer，要走 #00498 的 Binding 和持久化）。在 `zone/page1` 的 `MemoryPalaceIOSTests/BubbleInputRegressionTests.swift`（commit `91c3c0e6b`）里有现成的打字 / 截图 / 断言写法，可以借用。断言：
   - 原生 `insertText` 分三次输入「第一行」「\n」「第二行」，输入框文字一直保持完整（换行不丢），输入框长高；
   - 点**真实发送键**（不准直接调回调），消息真的发出去（进入发送路径，不是卡在排队或预热里）、输入框清空；
   - 发送键存在、可见、可点。

   气泡模式和文章模式都要测。
2. 先在 `f74ed9bd0`（不带 T1）上跑，看能不能复现。再在当前 HEAD（带 T1）上跑。把两次的红灯 / 绿灯都记下来。
3. 根因在 #00498 → 修到上面所有断言通过，同时 `InputBarDraftPersistenceTests` / `MacComposerDraftTests` 照样通过（最小改动，比如 Binding 改成稳定引用、回写时不能拿旧快照覆盖当前文字）。根因在别处 → 照实修，写明证据。
4. 一类问题一个 commit。

## 验证
- `xcodegen generate`；iOS（`-scheme MemoryPalaceIOS -destination 'platform=iOS Simulator,id=9451D1D2-7F24-46CB-B7FB-2AA3AD6304A9'`）和 mac（`-scheme MemoryPalaceTests -destination 'platform=macOS,arch=arm64'`）都要 `** TEST BUILD SUCCEEDED **`。
- mac 跑：`InputBarHitRuleTests`、`VoiceRecordGestureTests`、`InputBarDraftPersistenceTests`、`MacComposerDraftTests`，都要看到 passed。
- iOS 跑：新回归测试和 `BubblePageSnapshotTests`（专用模拟器 `6CA4B302-A610-4254-8D66-85D5019C0518`，跑完 `simctl shutdown`，不需要 device-lease）。
- 截图存到 `~/MemoryPalace-docs-media/docs/imessage-ref/ours/hotfix/`。
- 每次编译前看一眼 `df -h /System/Volumes/Data`，剩下不到 15G 就停下。

## 禁区
- 不准 push / merge-queue / 动 master 和别的工位；不准碰 `settings*.json` / CLAUDE.md / `tasks/`；不准装设备。
- 不准 `git stash` / `reset --hard` / `checkout -- .`；不准 `-derivedDataPath`。
- 不加功能、不改输入栏外观（目标就是改版前的老样子）。

## 交付
最后输出 `DONE <commit>`，然后写清：
- 根因（带 文件:行号 和证据），以及两次运行的红灯 / 绿灯；
- 改了什么；
- 测试结果；
- 截图路径。

卡住就写 `BLOCKED <原因>`。
