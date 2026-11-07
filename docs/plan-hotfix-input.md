# 输入栏紧急修复执行计划

任务书已明确授权执行；范围限真实输入栏回归、证据支持的最小修复与指定验证。不 push、不提交合并队列、不装真机、不改输入栏外观。

## 步骤与影响

1. 对照 04feebbe0 核对 T1；记录共享工位和分支状态。
2. 新增 `MemoryPalaceIOSTests/BubbleInputRegressionTests.swift`，先直接挂真实 InputBarStack 校准宿主，再用生产 ContentView → PagingVC → InputBarStack → ChatInputBar → ChatInputRepresentable 完整路径交付。三次 insertText 连续执行；两种模式各一条完整输入发送回归。
3. 暂时还原 T1 五文件为 f74ed9bd0，同一测试先跑基线，再恢复 T1 跑当前版本。编译前检查 Data 卷 ≥15GiB；不设 derivedDataPath。
4. 依据真实红绿灯确定根因；若生产路径有失败，只改该根因，保留 #00498 的草稿恢复契约。
5. iOS / mac build-for-testing；mac 四个指定 suite；专用 iOS 模拟器跑新回归与 BubblePageSnapshotTests。保存媒体至 `~/MemoryPalace-docs-media/docs/imessage-ref/ours/hotfix/`，最后 shutdown 专用模拟器。
6. 记录研究运行证据、复盘、工位状态和 roadmap 索引；中文原子提交。交付 DONE commit 或确切 BLOCKED 原因，不合并。

## Checklist

- [x] 核对 T1 与改版前输入栏差异
- [x] 建立真实 InputBarStack 双模式输入发送测试
- [x] f74ed9bd0 基线运行并记录（完整整页 + 发送键 PNG：双模式红）
- [x] T1 HEAD 运行并记录（相同完整测试：双模式红）
- [x] 根因归因与最小修复：稳定 Observable 文本引用；保留持久化与性能闸，修复后双模式绿
- [x] iOS/mac test build 成功，均读到 TEST BUILD SUCCEEDED
- [x] mac 四个指定 suite 29/29 通过
- [x] iOS 新回归 2/2、BubblePageSnapshotTests 1/1，最终测试文件再跑 2/2；截图已保存，专用模拟器已关闭
- [x] 更新研究、复盘、工位状态与 roadmap 索引；同一根因和回归随本次原子提交归档，不 push/不合并
