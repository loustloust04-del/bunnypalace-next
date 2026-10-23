# Page2 右边竖条切换小样

粟粟 10-11：「放在 page3，但是只拉出来一长条 app 图案供切换」（左上弧线留作设置里可切换的备选）。
先在小样上摸手感，定了再写 plan、找翻页1mac 对、进正式工程。

- 真 `UIScrollView` 三段：第一页（聊天占位）｜第二页（桌面 / 全屏应用）｜一条 92pt 竖条
- 第二页往左划露出竖条：应用跟着退、缩到 0.94、长屏幕圆角；竖条图标从右滑进、淡入，全开时轻震一下
- 竖条：最上面 ⌂ 桌面，下面开过的应用（最近的在上，最多 6 个），当前那个描白边；点了切过去、竖条收回
- 竖条开着时点应用那边收回；往右划同样收回
- 系统状态栏照常显示（这个方案不需要藏）
- 手感参数在 `Host/StripProtoApp.swift` 顶部 `Tune`

```bash
cd fixtures/page2-strip-prototype && xcodegen generate
xcodebuild build-for-testing -scheme StripProto -destination 'platform=iOS Simulator,id=<UDID>'
xcrun simctl install <UDID> ~/Library/Developer/Xcode/DerivedData/Page2StripPrototype-*/Build/Products/Debug-iphonesimulator/StripProto.app
xcrun simctl launch <UDID> com.susu.page2.stripproto                 # 桌面
xcrun simctl launch <UDID> com.susu.page2.stripproto -open 话题盒     # 直接在应用里（后台另有终端、日历）
xcrun simctl launch <UDID> com.susu.page2.stripproto -open 话题盒 -reveal   # 竖条开着
```
