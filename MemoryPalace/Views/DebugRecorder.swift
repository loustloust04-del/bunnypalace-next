#if DEBUG && os(iOS)
import SwiftUI
import UIKit
import QuartzCore

/// 帧捕获录屏器。CADisplayLink 跑 20fps，每 tick 抓 keyWindow 一帧到环形 buffer。
/// 上限 10s（200 帧）。停了 dump 成 Clip 存内存（不写盘），最多保 5 条。
///
/// 注：iOS 系统级 contextMenu preview 在私有窗口里渲染，app keyWindow snapshot 抓不到。
/// 但 bubble 自身的高亮/缩放/dim 这些前后帧能看到，结合时间轴 step 推菜单弹出方向。
@MainActor
final class DebugRecorder: ObservableObject {
    static let shared = DebugRecorder()

    struct Frame: Identifiable {
        let id = UUID()
        let image: UIImage
        let timestamp: TimeInterval
    }

    struct Clip: Identifiable {
        let id: UUID
        var name: String
        let frames: [Frame]
        let recordedAt: Date
        var duration: TimeInterval {
            guard let first = frames.first, let last = frames.last else { return 0 }
            return last.timestamp - first.timestamp
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var currentFrameCount = 0

    private var displayLink: CADisplayLink?
    private var ringBuffer: [Frame] = []
    private var startTime: CFTimeInterval = 0

    let targetFPS = 20
    let maxSeconds = 10
    private var maxFrames: Int { targetFPS * maxSeconds }
    private let maxClips = 5

    private init() {}

    func start() {
        guard !isRecording else { return }
        ringBuffer.removeAll(keepingCapacity: true)
        currentFrameCount = 0
        startTime = CACurrentMediaTime()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(targetFPS),
                maximum: Float(targetFPS),
                preferred: Float(targetFPS)
            )
        } else {
            link.preferredFramesPerSecond = targetFPS
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        displayLink?.invalidate()
        displayLink = nil
        isRecording = false

        if !ringBuffer.isEmpty {
            let clip = Clip(
                id: UUID(),
                name: Self.timeStamp(),
                frames: ringBuffer,
                recordedAt: Date()
            )
            clips.insert(clip, at: 0)
            if clips.count > maxClips {
                clips = Array(clips.prefix(maxClips))
            }
        }
        ringBuffer.removeAll(keepingCapacity: false)
        currentFrameCount = 0
    }

    func deleteClip(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
    }

    func clearAll() {
        clips.removeAll()
    }

    @objc private func tick() {
        guard isRecording, let window = Self.keyWindow() else { return }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // drawHierarchy(afterScreenUpdates:false) 是快路径，不强制 layout pass
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }

        let frame = Frame(image: image, timestamp: CACurrentMediaTime() - startTime)
        ringBuffer.append(frame)
        if ringBuffer.count > maxFrames {
            ringBuffer.removeFirst()
        }
        currentFrameCount = ringBuffer.count
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private static func timeStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
#endif
