#if os(iOS)
import SwiftUI
import SwiftData
import UIKit

/// 语音通话全屏页。入口：Page1 + 号条第三颗电话；原生来电接通后自动盖上。
/// 接线在 `CallController`（#042：锁屏接原生来电时页面可能根本没出来）；这里只展示和按钮。
struct CallScreen: View {
    let viewModel: ConversationViewModel
    let modelContext: ModelContext
    let profileManager: ProfileManager?
    let providerManager: ProviderManager
    let presetManager: PresetManager?
    let currentModel: ProviderModel
    var nativeCallID: String? = nil

    @Environment(\.dismiss) private var dismiss

    private var session: CallSession { CallSession.shared }
    private var controller: CallController { CallController.shared }

    private var profile: Profile? { profileManager?.currentProfile }
    private var assistantName: String { profile?.assistantName ?? "AI" }
    /// 头像取值链教训：assistantAvatarData ?? coverImageData（粟粟一般只设角色卡封面）
    private var avatarImage: UIImage? {
        if let data = profile?.assistantAvatarData ?? profile?.coverImageData {
            return UIImage(data: data)
        }
        return nil
    }

    var body: some View {
        ZStack {
            Theme.mainBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部：名字 + 计时
                VStack(spacing: 6) {
                    Text(assistantName)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsedText)
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.top, 60)

                Spacer()

                // 中部：头像 + 状态 + TA 正在说的话
                VStack(spacing: 24) {
                    avatarView
                    stateRow
                    if !session.currentUtterance.isEmpty {
                        Text(session.currentUtterance)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(6)
                            .padding(.horizontal, 36)
                            .transition(.opacity)
                    }
                    if let notice = controller.unavailableMessage ?? controller.fallbackNotice {
                        Text(notice)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 36)
                    }
                }

                Spacer()

                // 实时字幕条（她说话的 partial）
                Text(controller.partial.isEmpty ? " " : "你：\(controller.partial)")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                    .animation(.easeInOut(duration: 0.15), value: controller.partial)

                controlRow
                    .padding(.bottom, 48)
            }

            #if DEBUG
            // T6 注入口：模拟器无麦全链自证（说→发→回→读）
            VStack {
                HStack {
                    Spacer()
                    Button("模拟说话") {
                        session.userFinalTranscript("我在测试语音通话，你听到了吗？")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted.opacity(0.4))
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
            #endif
        }
        .onAppear { startCall() }
        .onDisappear { teardownIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .nativeCallEnded)) { _ in
            // 控制器已由协调器 finish 停掉，这里只收页面
            if nativeCallID != nil { dismiss() }
        }
        .onChange(of: viewModel.isCurrentConvResponding) { _, inFlight in
            session.turnInFlight = inFlight
        }
    }

    // MARK: - 子块

    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
                .frame(width: 120, height: 120)
            if let avatarImage {
                Image(uiImage: avatarImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
            } else {
                Text(profile?.emoji ?? "🌿")
                    .font(.system(size: 52))
            }
            // 说话时薄荷呼吸环
            if session.uiState == .speaking {
                Circle()
                    .stroke(Theme.branchIndicator.opacity(0.55), lineWidth: 3)
                    .frame(width: 136, height: 136)
                    .scaleEffect(pulse ? 1.06 : 0.98)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            }
        }
    }

    @State private var pulse = false

    private var stateRow: some View {
        HStack(spacing: 6) {
            switch session.uiState {
            case .listening:
                Image(systemName: session.muted ? "mic.slash.fill" : "waveform")
                    .font(.system(size: 13))
                Text(session.muted ? "已静音" : "听着呢")
            case .thinking:
                Image(systemName: "ellipsis.bubble")
                    .font(.system(size: 13))
                Text("想…")
            case .speaking:
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13))
                Text("正在说")
            case .idle:
                Image(systemName: "phone.down")
                    .font(.system(size: 13))
                Text("已结束")
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(Theme.textSecondary)
    }

    private var controlRow: some View {
        HStack(spacing: 64) {
            // 静音
            Button {
                session.muted.toggle()
                if nativeCallID != nil { NativeCallCoordinator.shared.setMuted(session.muted) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(session.muted ? .white : Theme.textPrimary)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(session.muted ? Theme.textMuted : Theme.accent))
            }
            .buttonStyle(.plain)

            // 挂断
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                endCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Theme.danger))
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if session.speaking || session.uiState == .thinking {
                Button { session.interruptReply() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止当前回应，保持通话")
            }
        }
    }

    private var elapsedText: String {
        guard let started = session.startedAt, session.active else { return "00:00" }
        let s = Int(Date().timeIntervalSince(started))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - 接线

    private func startCall() {
        if let nativeCallID {
            // 原生来电由控制器在后台接好，页面只接上显示；还没接上就再试一次，仍不是这通就收页
            controller.retryNative()
            guard controller.running, controller.nativeCallID == nativeCallID else { dismiss(); return }
        } else {
            let host = CallController.Host(viewModel: viewModel, modelContext: modelContext, profileManager: profileManager,
                                           providerManager: providerManager, presetManager: presetManager)
            guard controller.startInApp(host: host, model: currentModel) else { dismiss(); return }
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func endCall() {
        if nativeCallID != nil { NativeCallCoordinator.shared.appHangup() }
        controller.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        dismiss()
    }

    /// 手势划掉/系统关闭兜底。原生来电关页不挂（电话在系统通话界面继续，回到对话会再盖上）；+ 号拨打关页即挂
    private func teardownIfNeeded() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard nativeCallID == nil, controller.nativeCallID == nil else { return }
        controller.stop()
    }
}
#endif
