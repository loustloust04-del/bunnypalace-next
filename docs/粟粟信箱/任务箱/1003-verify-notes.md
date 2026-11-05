# 1003 粟粟验收批注 → #015–#020

来源：memorypalace-5f（开源规划 session）10-03 SendMessage，转来粟粟 10-03 验收时的原话（5f 不派，交给 Dex）。原话照录：

> 1. file-editor-sheet: "弹的很诡异。弹性太大了" (the Aa capsule↔circle glass morph in the file editor bounces far too much). Bug: tone down the spring. Ref docs/review-file-editor-sheet.md.
> 2. branch-map-v12: "一开始布局是：支A，主线b，支c。如果我点了支c，支c马上就突然到中间来了，变成支A支c主线b。突变！让人很迷惑". Bug: selecting a branch must not reorder the lanes abruptly. Keep lane order stable, or animate if it has to move. Ref docs/review-branch-map-v12.md.
> 3. thinking-branch: "那个思考icon不要黑色。棕灰". The thinking icon color should be brown-gray, not black. Ref docs/review-thinking-branch.md.
> 4. page0-list-polish: "还要加一个纯净模式（什么乱七八糟都不带，比如不带icon不带对话数字时间，只带对话标题）". New feature: a page0 list "pure mode" toggle that shows conversation titles only.
> 5. reading-marks-P4: "还是有点点不合理，但是这个延后吧。先放taskmd". Deferred: register it but don't dispatch.
> 6. search-s4-calibration: "暂缓". Paused: per your runbook, 暂缓 = archive.
>
> Still open on her side, no task needed: file-library-folder-open is waiting for the new mac build, and card-library-batch2 is waiting for her to update SillyTavern locally.
