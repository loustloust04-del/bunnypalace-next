# 复盘：后台保活（被系统回收后跳开屏 + 回到上次的页）

> 2026-10-15 · 🎩 · infra 工位 · [research](research-bg-keepalive.md) / [plan](plan-bg-keepalive.md)
> 根因（验收 1、3）：Air 开着开发者选项 Fast App Termination，粟粟已关、已确认。本单代码只管验收 2。
> 审查：sol（omp）+ Claude 只读审查各一轮（kimi 额度墙到 02:57，按惯例换 Claude 补席），裁决见 §0。

## 0. 审查裁决
| # | 问题 | 来源 | 裁决 |
|---|---|---|---|
| 1 | 没走恢复的启动（推送 / 闸口 / 切楼层）不对齐存值 → 下次回收后回到上一世的页 / 对话 | sol1 · C1 | 收：attempted 后先读快照再对齐当前；楼层重建对齐当前选中 |
| 2 | 恢复到 page0/2 时 `loadConversation` 把未读清零 | sol2 | 收：非聊天页目标时 load 后写回原未读 |
| 3 | 恢复没让路已认领的外部入口（推送 key 写入前的空窗） | sol3 · C6 | 收：加 `launchHasExternalTarget` + `LaunchSplash.pushLaunch` 闸 |
| 4 | 列表页挡板短路求值可能残留 | sol4 · C2 | 收：按对话 id 绑定、无条件消费 |
| 5 | Codex / 学习 / 读书草稿的字被填进普通草稿 | C3 | 收：只给普通草稿记字 |
| 6 | didEnterBackground 写入赶不赶得上系统存盘无文档保证 | sol5 · C4 | 不改码：早写也不保证；进 T8 实测第 8 条 |
| 7 | 回前台后标记不清 → 前台崩溃后误跳开屏 | C5 | 收：didBecomeActive 清（不用 willEnterForeground，冷启动可能早于 consume） |
| 8 | `--chat-sample` 没进 DEBUG 闸 | C7 | 收 |
| 9 | 单测只覆盖纯判定 | C 测试段 | 收：LastLocationResume 移出 iOS 块补静态单测 |
| 10 | 翻页 body 重算 / 跳开屏后闪一帧聊天页 | C8 · C9 | 进 T8 实测第 9 条 |

## 1. 边界情况
- **session 是否保留全靠实测**：iOS 27 上 Fast App Termination / `simctl terminate` 杀后 scene session 是否保留未查证（T1）。不保留 → 两样都读不到，行为与改前完全一样。
- **写入时机**：草稿字和回来标记只在 didEnterBackground 写；系统若先存盘，字滞后一轮、标记丢（照播开屏，安全退化）。
- **推送晚到**：推送 key 晚于 `.task` 写入时恢复先跑，0.6s 后推送落点覆盖——最终落点对，可能先闪一下。
- **iPad 横屏冷启动**：`.task` 时宽屏判定可能还没量出，先翻页再被转屏归位，可能闪。
- **草稿字填回时序**：要求输入条首次装载托底草稿发生在恢复之后；若之前已装过空草稿，字填不回（未查证）。
- **与 API 卡草稿恢复叠加**：先回原页再弹设置 sheet，预期内，要看观感。
- **普通草稿里换过模型 / 在文件夹 tab 新建**：会写 selectedModelId / folderId，被判成专用草稿，被回收后字不恢复（取舍：恢复出的托底草稿不带这些设置，强填字可能发到错的模型）。要恢复得连草稿设置一起存，另提。
- **回来标记清理**：didBecomeActive 清标记；冷启动走 rootGate 兜底路径时 consume 是否一定早于 didBecomeActive 未查证（正常走 willConnect，必然更早）。
- **写回未读**：写回后不显式 save，和原来清零一样靠后续 save 落盘；中间若有一次 save 过 0 再没 save，可能丢未读数（未查证）。

## 2. 与下一模块交互的风险
- `@SceneStorage` 键 `resume.page` / `resume.conversationId` / `resume.newChatText` 和 page2 的 `page2.*` 同生命周期；以后加「设置子页 / 滚动位置」恢复要沿用同一组闸（`canResumeAPIDraft` + 外部入口 + `LastLocationResume.attempted`）。
- `UISceneSession.userInfo["mp.resume.leftAt"]` 是新的跨进程契约；`LaunchSplash` 改入口时两处 `skipForResume` 都要保留。
- 改 `ConversationViewModel.loadConversation` 的副作用（未读清零、PushIdentity touch）会影响冷启动恢复。

## 3. 技术债务
- iSH init 死 → `halt_system()` `_exit(0)` 带走整个 app（`deps/ish/kernel/exit.c:403-456`），本单只记不修。
- iSH 后台 CPU 调速器 `beginBackgroundCPUGovernor` 全仓无调用方。
- 进后台的同步导出 + 时间机器备份不申请后台时间，`BackupStore.snapshotIfNeeded` 每次进后台全量 fetch + 编码。
- 恢复逻辑没有 UI 测试，只有判定 / 存取的静态单测，靠 T8 实测兜。

## 4. 说明书
不涉及（行为是「回到原处」，无新入口 / 设置）。
