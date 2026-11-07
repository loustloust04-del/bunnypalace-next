# 输入栏紧急修复复盘

## 1. 边界情况

- 已复现并修复：手写 Binding + equatable 宿主导致渲染读旧文本，原生已两行但 UI 仍为单行模式/语音波形。f74ed9bd0 与 T1 的气泡、文章模式均红；稳定可观察文本引用后两模式均绿。
- 连续三次原生 insertText、真实 frame 增高、完整草稿、实际发送键的 PNG/命中/公开 AX 激活、真实 HTTP/SSE、输入与草稿清空均已覆盖。
- 复现中原生文字及持久化的换行没有消失；没有声称复现了所有 Air 输入法状态。未装真机，候选组字/真机触摸时序不在这次证据范围。
- 未改预算拒发、busy 队列、wiki 预热或错误恢复。合成会话关闭记忆，本次发送场景证明请求真正到达 HTTP 服务，不代表已覆盖预热超时。

## 2. 与周边模块的交互

- 保留 InputBarDraftPersistence、同步 Binding setter、附件、引用、后台 flush、切对话 owner 守卫和 `.equatable()`；仅将文本镜像改为每个 host 的稳定 Observable 对象。
- 无 exported API、数据格式、schema、provider、发送门控或输入栏外观改动。T1 的旧输入栏布局保持；气泡/文章恢复相同的原有多行布局。
- mac 四组 29/29：InputBarHitRuleTests 5、VoiceRecordGestureTests 10、InputBarDraftPersistenceTests 6、MacComposerDraftTests 8。草稿恢复/旧空快照 flush 契约继续通过。
- iOS 新回归 2/2 + BubblePageSnapshotTests 1/1；最终按钮裁剪像素采样版本又单独复跑新回归 2/2。两模式字段均 40.667 → 57.667pt，发送键 44×44pt，各 1 次 HTTP 请求并完成回复。

## 3. 技术债务与证据限制

- 永久测试只在测试宿主加载私有 libAccessibility 的 automation 开关以建立系统 AX，退出恢复；生产二进制未引入该依赖。将来系统若移除此符号，应按宿主基础设施失败处理，不能删掉真实按钮激活或改成直接调回调。
- 最初“能激活右侧按钮并收到请求”的绿灯不充分：渲染事务外的 activation 会读 live binding，屏上的波形仍可能错。最终保留 PNG 白箭头/实心圆断言，不仅检查按钮存在。
- PNG 仅展开按钮区域为 RGBA，不做整屏像素缓冲；Profile/SwiftData/Keychain 均使用隔离宿主和合成数据。没有引入产品临时方案、stub 或 TODO。
- 本机 xcodebuild shim 的 test-without-building 租约提示存在 shell 语法警告，已报工具问题；命令仍真实执行，结果包与 passed 输出齐全，未绕过编译锁。

研究与正式红绿对照：[research-hotfix-input.md](research-hotfix-input.md)。媒体：`~/MemoryPalace-docs-media/docs/imessage-ref/ours/hotfix/`。本任务禁止 push、合并队列和装真机，均未执行。
