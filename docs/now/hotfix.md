# hotfix：输入框紧急修复

- 基线：`4276ef98f`（含 T1 `9e8f5d550`）；未改 master/NOW。
- 结论：#00498 手写文本 Binding 捕获父 View 的 State 值快照，equatable 子树渲染仍读空文本，导致多行状态/发送箭头失步。不是队列/预热拦截，未观察到原生文字实际删换行。
- 改动：仅 InputBarStack 文本镜像改为稳定 Observable 引用；持久化、附件、发送门控、性能闸、外观均保留。新增真实整页 InputBarStack 输入/发送/PNG 回归。
- 正式对照：f74ed9bd0 双模式红；T1 双模式红；本次最小修复后双模式绿。初期按钮存在检查的假绿已在研究文档说明，不作为验收。
- 验证：xcodegen；MemoryPalaceIOS / MemoryPalaceIOSTests / MemoryPalaceTests test build 成功；mac 指定 29/29；iOS 新回归 2/2 + 整页对拍 1/1，最终测试文件再跑 2/2。
- 专用模拟器 `6CA4B302-A610-4254-8D66-85D5019C0518` 跑完已关闭；未装真机、未 push/提交合并队列。
- 媒体：`~/MemoryPalace-docs-media/docs/imessage-ref/ours/hotfix/`；结果包 `/tmp/hotfix-input-{f74ed9bd0-glyph,T1-glyph,fixed,fixed-repeat,mac-fixed}.xcresult`。
- [研究](../research-hotfix-input.md) / [计划](../plan-hotfix-input.md) / [复盘](../review-hotfix-input.md)。任务范围已结束，不在此工位启动下一件 WIP。
