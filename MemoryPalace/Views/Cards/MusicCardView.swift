import SwiftUI
import SwiftStreamingMarkdown

/// 音乐卡（research-chat-cards §10.2 / §10.6，照 HTML 小样）：一个形状——
/// 点播放，同一张卡长出波形（波形就是进度条），封面变大、黑胶慢转，播放键原地变形成暂停；
/// 点喇叭，波形原地变形成音量条，停手 2 秒变回。拖过两头拉伸、松手弹回；只在水平拖动占优时接管（不抢聊天滚动）。
/// 不进输入框、不发消息；本地模式不联网；变成旧版本时停止。
struct MusicCardView: View {
    let card: MusicCard
    let nodeId: String?
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LocalMode.key) private var localMode = true
    /// 拖动中的原始比例（可超出 0...1）；松手 / 被系统取消时复位并弹回
    @State private var drag: Double?
    @State private var tipWidth: CGFloat = 40
    @State private var volumeMode = false
    @State private var volumeIdle: Task<Void, Never>?
    @State private var coverData: Data?

    private var player: MusicCardPlayer { .shared }
    private var key: String { "\(nodeId ?? "-")|\(card.id ?? card.title)|\(card.url ?? "")" }
    private var status: ChatCardStatus { viewModel?.cardStatus(.music(card), nodeId: nodeId) ?? .readOnly }
    private var phase: MusicCardPlayer.Phase { player.phase(for: key) }
    private var expanded: Bool { phase == .playing || phase == .paused || phase == .loading }
    private var playing: Bool { phase == .playing || phase == .loading }
    private var preparing: Bool { player.isPreparing(key: key) }
    private var canPlay: Bool { card.playableURL != nil || card.builtinTrack != nil }
    /// 网络音频在本地模式下不播；内置曲不联网，不受限
    private var networkBlocked: Bool { localMode && card.builtinTrack == nil && card.playableURL != nil }
    private var heights: [Double] { MusicWave.heights(seed: card.url ?? card.title) }
    private var ink: Color { Color.primary.opacity(0.88) }
    private static let mint = Color(red: 0.498, green: 0.722, blue: 0.620)

    private func animation(_ a: Animation) -> Animation { ChatCardMotion.animation(a, reduceMotion: reduceMotion) }
    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    var body: some View {
        ChatCardShell(kindLabel: "音乐", badge: status == .stale ? .stale : .none) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    cover
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.displayTitle).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        if let note = caption {
                            Text(note).font(.system(size: 13)).foregroundStyle(CodeBlockStyle.label).lineLimit(1)
                                .id(note)
                                .transition(ChatCardMotion.contentTransition(reduceMotion: reduceMotion))
                        }
                    }
                    .animation(animation(ChatCardMotion.morph), value: caption)
                    Spacer(minLength: 8)
                    if expanded, canPlay {
                        volumeButton.transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    trailingControl
                }
                if expanded {
                    scrubber
                        .padding(.top, 26)
                        .transition(ChatCardMotion.contentTransition(reduceMotion: reduceMotion))
                }
            }
            .animation(animation(ChatCardMotion.morph), value: expanded)
        }
        // 变旧版本即停（R5 U2）；initial：滚出屏幕时变旧、回来重建也要停（终审 I3）
        .onChange(of: status, initial: true) { _, new in if new == .stale { player.stop(key: key) } }
        .onChange(of: drag == nil) { _, ended in if ended, volumeMode { restartVolumeIdle() } else { volumeIdle?.cancel() } }
        .onChange(of: expanded) { _, now in if !now { volumeMode = false } }
        .task(id: "\(card.cover ?? "")|\(localMode)") {
            guard !localMode, let url = card.coverURL else { coverData = nil; return }
            coverData = MusicCoverLoader.shared.cached(url)
            if coverData == nil { coverData = await MusicCoverLoader.shared.load(url) }
        }
    }

    private var caption: String? {
        if networkBlocked { return "本地模式不联网" }
        if phase == .failed { return "播放失败" }
        if preparing { return "正在合成…" }                                   // 首次播放内置曲要等几秒（终审 I3）
        if phase == .loading, player.current > 0 { return "缓冲中…" }         // 放到一半在等数据（断网 / 弱网）
        return card.displaySubtitle
    }

    // MARK: 封面：有图用图（不转），没图画黑胶（播放时慢转）；收起 48 → 播放 64

    private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let size: CGFloat = expanded ? 64 : 48
        return Group {
            if let image = coverData.flatMap(Self.image) {
                image.resizable().scaledToFill().transition(.opacity)
            } else {
                VinylCover(spinning: playing && !reduceMotion)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(CodeBlockStyle.stroke, lineWidth: 1))
        .animation(animation(ChatCardMotion.morph), value: coverData)
    }

    private static func image(_ data: Data) -> Image? {
        #if os(iOS)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }

    // MARK: 按钮

    private var volumeButton: some View {
        Button {
            withAnimation(animation(ChatCardMotion.morph)) { volumeMode.toggle() }
            if volumeMode { restartVolumeIdle() } else { volumeIdle?.cancel() }
        } label: {
            Image(systemName: "speaker.wave.2.fill", variableValue: player.volume)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(volumeMode ? CodeBlockStyle.body : ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(volumeMode ? ink : .clear))
                .overlay(Circle().strokeBorder(ink.opacity(volumeMode ? 0 : 0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(volumeMode ? "收起音量" : "音量")
        .disabled(status == .stale)
    }

    @ViewBuilder private var trailingControl: some View {
        if canPlay {
            Button { togglePlay() } label: {
                PlayPauseShape(morph: playing ? 1 : 0)
                    .fill(CodeBlockStyle.body)
                    .frame(width: 22, height: 22)
                    .animation(animation(ChatCardMotion.snappy), value: playing)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "暂停" : "播放")
            .disabled(networkBlocked || status == .stale)
            .opacity(networkBlocked ? 0.3 : 1)
        } else if let link = card.linkURL {
            Button { openURL(link) } label: {
                Text("打开").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CodeBlockStyle.body)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Capsule().fill(ink))
            }
            .buttonStyle(.plain)
            .disabled(status == .stale)
        }
    }

    // MARK: 波形进度条 / 音量条（同一个形状）

    private var scrubber: some View {
        let live = player.duration > 0 ? player.current / player.duration : 0
        let progress = volumeMode ? live : Self.clamp(drag ?? live)
        let volume = volumeMode ? Self.clamp(drag ?? player.volume) : player.volume
        let overshoot = drag.map { ChatCardMotion.rubberBand($0, in: 0...1) - Self.clamp($0) } ?? 0
        let morph: Double = volumeMode ? 1 : 0
        return VStack(spacing: 6) {
            GeometryReader { g in
                let w = g.size.width
                // 播放中每帧刷新：播放头平滑走、附近的柱子跟着鼓点弹（音量表只有内置曲有，粟粟 09-26）
                TimelineView(.animation(paused: !(phase == .playing && drag == nil && !volumeMode))) { context in
                    let t = player.estimatedTime(at: context.date)
                    let p = drag == nil && !volumeMode && player.duration > 0 ? Self.clamp(t / player.duration) : progress
                    let level = reduceMotion || volumeMode ? 0 : player.level(at: context.date)
                    let shown = MusicWave.bounced(heights, progress: p, level: level)
                    ZStack(alignment: .leading) {
                        WaveBars(heights: shown, volumeMorph: morph).fill(ink.opacity(0.16))
                        WaveBars(heights: shown, volumeMorph: morph).fill(ink)
                            .mask(alignment: .leading) { Rectangle().frame(width: w * p) }
                            .opacity(1 - morph)
                        WaveBars(heights: shown, volumeMorph: morph).fill(Self.mint)
                            .mask(alignment: .leading) { Rectangle().frame(width: w * volume) }
                            .opacity(morph)
                        Rectangle().fill(Self.mint)
                            .frame(width: 2, height: g.size.height - 4)
                            .offset(x: min(max(w * p - 1, 0), w - 2))
                            .opacity(1 - morph)
                    }
                    .frame(width: w, height: g.size.height, alignment: .leading)
                }
                .scaleEffect(x: 1 + abs(overshoot), y: 1, anchor: overshoot < 0 ? .trailing : .leading)
                .overlay(alignment: .topLeading) {
                    if drag != nil, !volumeMode {
                        Text(MusicTime.text(progress * player.duration))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(CodeBlockStyle.body)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(ink))
                            .fixedSize()
                            .background(GeometryReader { t in Color.clear.onAppear { tipWidth = t.size.width } })
                            .alignmentGuide(.leading) { $0.width / 2 - MusicScrub.tipCenter(progress: progress, width: w, tipWidth: tipWidth) }
                            .offset(y: -24)
                            .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { commit($0.x / max(w, 1)) }
                .modifier(ScrubGesture(width: w, onChange: { drag = $0 }, onEnd: { fraction in
                    if let fraction { commit(fraction) }
                    withAnimation(animation(ChatCardMotion.snappy)) { drag = nil }
                }))
                .animation(animation(ChatCardMotion.morph), value: volumeMode)
                .animation(animation(ChatCardMotion.snappy), value: drag != nil)
            }
            .frame(height: 40)
            ZStack {
                HStack {
                    Text(MusicTime.text(progress * player.duration))
                    Spacer()
                    Text(MusicTime.text(player.duration))
                }
                .opacity(volumeMode ? 0 : 1)
                if volumeMode {
                    Text("音量 \(Int((volume * 100).rounded()))%")
                        .transition(ChatCardMotion.contentTransition(reduceMotion: reduceMotion))
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(CodeBlockStyle.label)
            .animation(animation(ChatCardMotion.morph), value: volumeMode)
        }
        .disabled(status == .stale)
    }

    private func togglePlay() {
        let origin = MusicOrigin(conversationId: viewModel?.selectedConversation?.id ?? "", nodeId: nodeId ?? "",
                                 title: card.displayTitle, card: card)
        if let url = card.playableURL {
            player.toggle(key: key, url: url, origin: origin)
        } else if let track = card.builtinTrack {
            player.toggleBuiltin(key: key, track: track, origin: origin)   // 合成状态归播放器管（终审 I2）
        }
    }

    private func commit(_ fraction: Double) {
        if volumeMode {
            player.setVolume(Self.clamp(fraction))
            restartVolumeIdle()
        } else {
            player.seek(fraction: Self.clamp(fraction))
        }
    }

    /// 音量条停手 2 秒变回波形
    private func restartVolumeIdle() {
        volumeIdle?.cancel()
        volumeIdle = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(animation(ChatCardMotion.morph)) { volumeMode = false }
        }
    }
}

/// 波形条的拖动（终审 I1）：iOS 用 UIKit 横向拖动识别器——起手是竖向就根本不开始，聊天列表照常滚；
/// 被系统取消也会回调。macOS 没有滚动冲突，用普通拖动。
private struct ScrubGesture: ViewModifier {
    let width: CGFloat
    let onChange: (Double) -> Void
    let onEnd: (Double?) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.gesture(HorizontalPan(onChange: { onChange($0 / max(width, 1)) },
                                      onEnd: { x in onEnd(x.map { $0 / max(width, 1) }) }))
        #else
        content.gesture(DragGesture(minimumDistance: 2)
            .onChanged { onChange($0.location.x / max(width, 1)) }
            .onEnded { onEnd($0.location.x / max(width, 1)) })
        #endif
    }
}

#if os(iOS)
import UIKit

private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let onChange: (CGFloat) -> Void
    /// nil = 被取消（不提交）
    let onEnd: (CGFloat?) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = context.converter.localLocation.x
        switch recognizer.state {
        case .began, .changed: onChange(x)
        case .ended: onEnd(x)
        case .cancelled, .failed: onEnd(nil)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return MusicScrub.accepts(CGSize(width: v.x, height: v.y))
        }
    }
}
#endif
