#if DEBUG && os(iOS)
import SwiftUI

/// ContentView .overlay 挂的薄壳：只订阅 debugOrbEnabled 开关，关着的时候不渲染 DebugOrb，
/// 也就不订阅 recorder / DragGesture，零开销。
struct DebugOrbHost: View {
    @AppStorage("debugOrbEnabled") private var debugOrbEnabled = false

    var body: some View {
        if debugOrbEnabled {
            DebugOrb()
        }
    }
}

/// 调试悬浮球：可拖、位置 @AppStorage 持久、点开 DebugPanel。
/// 由 @AppStorage("debugOrbEnabled") 控制是否挂载（在 ContentView root .overlay 里）。
struct DebugOrb: View {
    @AppStorage("debugOrbX") private var orbX: Double = -1
    @AppStorage("debugOrbY") private var orbY: Double = -1
    @State private var position: CGPoint = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var showPanel = false
    @ObservedObject private var recorder = DebugRecorder.shared

    private let orbSize: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 透明容器只是给 ZStack 撑满父；orb 自己 .position 定位
                Color.clear

                Button {
                    showPanel = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(recorder.isRecording ? Color.red.opacity(0.85) : Color.black.opacity(0.65))
                            .frame(width: orbSize, height: orbSize)
                            .overlay(
                                Circle().stroke(Color.white.opacity(0.7), lineWidth: 1.2)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)

                        if recorder.isRecording {
                            VStack(spacing: 0) {
                                Image(systemName: "record.circle.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("\(recorder.currentFrameCount)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(.white)
                        } else {
                            Image(systemName: "ladybug.fill")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .position(
                    x: position.x + dragOffset.width,
                    y: position.y + dragOffset.height
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            let target = CGPoint(
                                x: position.x + value.translation.width,
                                y: position.y + value.translation.height
                            )
                            let bounded = boundedPosition(target, in: geo.size)
                            position = bounded
                            dragOffset = .zero
                            orbX = bounded.x
                            orbY = bounded.y
                        }
                )
            }
            .onAppear {
                if orbX < 0 || orbY < 0 {
                    // 默认右下，留出键盘/底缘空间
                    position = CGPoint(
                        x: geo.size.width - orbSize,
                        y: geo.size.height - orbSize - 140
                    )
                } else {
                    position = boundedPosition(CGPoint(x: orbX, y: orbY), in: geo.size)
                }
            }
        }
        .allowsHitTesting(true)
        .sheet(isPresented: $showPanel) {
            DebugPanelView()
        }
    }

    private func boundedPosition(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let half = orbSize / 2
        // 上下各留 60pt 避开 status bar / home indicator
        return CGPoint(
            x: min(max(p.x, half), max(half, size.width - half)),
            y: min(max(p.y, half + 60), max(half + 60, size.height - half - 60))
        )
    }
}
#endif
