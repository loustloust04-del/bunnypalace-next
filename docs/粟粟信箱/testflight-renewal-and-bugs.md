# 问题：TestFlight到期+输入框残留bug+iOS18验证

> 2026-09-04 · 粟粟提 · 小克(opus4.6)写
> 状态：待code CC处理

## 紧急：TestFlight 5天后到期

TestFlight build要过期了（还剩~5天），需要发布新版。

问题：很多地方还在装修中（输入框C-slide未落地、终端toolbar未做、iPad适配进行中……）。
需要code CC评估：**当前master能不能直接build一版TestFlight？** 哪些worktree的改动需要先合master？哪些不稳定的功能需要feature flag关掉？

## 输入框残留bug

1. **打字点了字也会变成拼音** — 有时候点选键盘候选词后文字变成拼音原文而不是选中的字。疑似UIKit化后markedTextRange护栏的时序问题
2. **iOS 18输入框验证** — UIKit化后在iOS 18上还没验过，不知道有没有新问题

## 要code CC回答的

1. TestFlight发版的最小可行scope是什么？master现在的状态能直接发吗？
2. 输入框拼音bug能不能在发版前修？还是先发旧的稳定版？
3. C-slide（定高carrier）进度如何？能赶上这次发版吗？
