import SwiftUI

#if os(iOS)
/// iOS 设置页包装（独立 struct 防外观页 type-check 超时）
struct BubblePopTunerPage: View {
    var body: some View {
        ScrollView {
            BubblePopTunerView()
                .padding(16)
        }
        .background(Theme.sidebarBg.ignoresSafeArea())
        .navigationTitle("弹泡调音台")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

/// 弹泡调音台（plan-bubble-pop-tuner）：iMessage 式弹入动画的参数面板。
/// 预览区两个假泡无限重放 + 慢放滑条（0.1x 看清每一帧）+ 四参数滑条即调即看。
/// 滑条直写 BubblePopTuning 的 @AppStorage 键——聊天里的行级/块级弹泡读同一组真值，调完即全局生效。
struct BubblePopTunerView: View {
    @AppStorage(BubblePopTuning.bounceKey) private var bounce = BubblePopTuning.defaultBounce
    @AppStorage(BubblePopTuning.durationKey) private var duration = BubblePopTuning.defaultDuration
    @AppStorage(BubblePopTuning.scaleFromKey) private var scaleFrom = BubblePopTuning.defaultScaleFrom
    @AppStorage(BubblePopTuning.offsetYKey) private var offsetY = BubblePopTuning.defaultOffsetY
    @AppStorage(BubblePopTuning.velocityKey) private var velocity = BubblePopTuning.defaultVelocity
    @AppStorage(BubblePopTuning.jellyKey) private var jelly = BubblePopTuning.defaultJelly
    @AppStorage(BubblePopTuning.tiltKey) private var tilt = BubblePopTuning.defaultTilt
    @AppStorage(BubblePopTuning.offsetXKey) private var offsetX = BubblePopTuning.defaultOffsetX
    @AppStorage(BubblePopTuning.settleKey) private var settle = BubblePopTuning.defaultSettle

    /// 慢放倍速（仅预览用，不影响聊天里的实际动画）
    @State private var previewSpeed = 1.0
    @State private var showAssistant = false
    @State private var showUser = false
    @State private var replayTask: Task<Void, Never>? = nil
    /// 重放的隐藏阶段：动画门置 nil 让泡瞬时消失——否则慢放下淡出拖几秒没走完，
    /// 重新插入被 SwiftUI 当同一 view 的状态延续，只补 opacity → 弹跳成分全丢（粟粟报的"变淡入淡出"）
    @State private var hiding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // ── 预览区：假对话背景，重放无限看 ──
            VStack(alignment: .leading, spacing: 10) {
                previewBubble(text: "我先弹一个给你看看手感", isUser: false, visible: showAssistant)
                previewBubble(text: "然后我发的也要跳出来！", isUser: true, visible: showUser)
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg))
            .animation(hiding ? nil : previewAnimation, value: showAssistant)
            .animation(hiding ? nil : previewAnimation, value: showUser)

            HStack {
                Button("▶︎ 重放") { replay() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.branchIndicator)
                Spacer()
                Text(String(format: "慢放 %.1fx", previewSpeed))
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                Slider(value: $previewSpeed, in: 0.1...1.0)
                    .frame(width: 120)
            }

            Divider()

            // ── 参数滑条：即调即生效（聊天动画同源） ──
            sectionLabel("弹性")
            tunerRow("Q 弹程度", value: $bounce, range: 0...0.8, format: "%.2f",
                     hint: "过冲回弹的幅度：0 不弹 · 0.3 轻快 · 0.5 明显 · 0.7 夸张")
            tunerRow("起手冲劲", value: $velocity, range: 0...15, format: "%.1f",
                     hint: "初速度——「被抛出来」的爆发感，配合 Q 弹更跳")
            tunerRow("时长", value: $duration, range: 0.2...0.8, format: "%.2fs",
                     hint: "整个弹入动画的时间")

            sectionLabel("轨迹")
            tunerRow("起跳距离", value: $offsetY, range: 0...120, format: "%.0fpt",
                     hint: "从下方跳上来的距离")
            tunerRow("横向起跳", value: $offsetX, range: 0...60, format: "%.0fpt",
                     hint: "斜着从角落（输入框方向）抛入的横向分量")
            tunerRow("入场倾斜", value: $tilt, range: 0...15, format: "%.0f°",
                     hint: "带一点旋转落位，0 = 不转")

            sectionLabel("形变")
            tunerRow("起点大小", value: $scaleFrom, range: 0.3...1.0, format: "%.2f",
                     hint: "越小越有「从一点长出来」的感觉")
            tunerRow("果冻形变", value: $jelly, range: 0...1.0, format: "%.2f",
                     hint: "入场压扁、过冲时反向拉伸——真·果冻")
            tunerRow("回形利落", value: $settle, range: 1.0...3.0, format: "%.1fx",
                     hint: "形变比位移提前多少回正——1 同步（呆），越大落地越利落")

            Button("恢复默认") {
                BubblePopTuning.resetToDefaults()
                bounce = BubblePopTuning.defaultBounce
                duration = BubblePopTuning.defaultDuration
                scaleFrom = BubblePopTuning.defaultScaleFrom
                offsetY = BubblePopTuning.defaultOffsetY
                velocity = BubblePopTuning.defaultVelocity
                jelly = BubblePopTuning.defaultJelly
                tilt = BubblePopTuning.defaultTilt
                offsetX = BubblePopTuning.defaultOffsetX
                settle = BubblePopTuning.defaultSettle
                replay()
            }
            .font(.caption)
            .foregroundColor(Theme.textSecondary)
        }
        .onAppear { replay() }
        .onDisappear { replayTask?.cancel() }
    }

    private var previewAnimation: Animation {
        // 慢放 = 直接拉长 spring 感知时长（bounce 曲线原样保留，冲劲同步缩慢），不用 .speed() 包装
        .interpolatingSpring(
            duration: BubblePopTuning.duration / previewSpeed,
            bounce: BubblePopTuning.bounce,
            initialVelocity: BubblePopTuning.velocity * previewSpeed
        )
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(Theme.textMuted)
            .padding(.top, 2)
    }

    private func replay() {
        replayTask?.cancel()
        // 隐藏阶段关动画门：泡瞬时消失，插入才是每次全新的完整弹跳
        hiding = true
        showAssistant = false
        showUser = false
        replayTask = Task { @MainActor in
            // 等移除 commit 稳定后开门再弹，两泡错开一拍（间隔随慢放拉长）
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            hiding = false
            showAssistant = true
            try? await Task.sleep(nanoseconds: UInt64(500_000_000 / previewSpeed))
            guard !Task.isCancelled else { return }
            showUser = true
        }
    }

    @ViewBuilder
    private func previewBubble(text: String, isUser: Bool, visible: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Group {
                if visible {
                    Text(text)
                        .font(.system(size: 13.5))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            BubbleTailShape(isUser: isUser, radius: 14, hasTail: true)
                                .fill(isUser ? Theme.userBubble : Theme.assistantBubble)
                        )
                        .transition(BubblePopTuning.popTransition(isUser: isUser))
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private func tunerRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                          format: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.textPrimary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Theme.textSecondary)
            }
            Slider(value: value, in: range) { editing in
                if !editing { replay() }  // 松手自动重放一次看效果
            }
            Text(hint).font(.caption2).foregroundColor(Theme.textMuted)
        }
    }
}
