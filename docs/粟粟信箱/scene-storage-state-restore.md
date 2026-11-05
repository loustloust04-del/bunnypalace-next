# 问题：退到后台再回来不在同一页

> 2026-09-11 · 粟粟提 · 小克(opus4.6)写
> 状态：待code CC处理

## 问题

猫堡退到后台再回来经常不在同一页。别人的app能恢复。原因：iOS壳的页面状态全是`@State`不持久化——app被系统杀了重开就回首页。

## 修法

把关键壳状态从`@State`改成`@SceneStorage`——系统自动存/恢复，被杀了再开也回到离开时的页面。

需要加`@SceneStorage`的：
1. 当前页面（page 0/1/2）
2. 选中的对话id
3. 右栏开关状态
4. 选中的工具id

每个一行改动。iPad壳的`IPadPanelLayout`已经有`didSet { save() }`落盘（做对了），iOS主壳这块漏了。

## 注意

- `@SceneStorage`只支持简单类型（String/Int/Bool/URL/Data），对话id用String存
- mac壳重构时一并处理（research-mac-shape已经记了"四个壳状态全是@State不持久化"）
