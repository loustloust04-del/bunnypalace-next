#if os(iOS)
import UIKit
import QuartzCore

/// 烘焙数据只含 frame / 标量关键帧；运行时不求曲线、不画玻璃、不逐帧回调。
@MainActor
final class LaunchSplashAnimationView: UIView {
    struct Track: Decodable {
        let keyPath: String
        let times: [Double]
        let values: [Double]

        func valid(duration: Double) -> Bool {
            let allowed: Set<String> = ["position.x", "position.y", "opacity", "transform.rotation.z", "transform.scale"]
            return allowed.contains(keyPath) && times.count >= 2 && times.count == values.count
                && times.first == 0 && abs((times.last ?? 0) - duration) < 0.00001
                && times.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= duration + 0.00001 }
                && values.allSatisfy(\.isFinite)
                && zip(times, times.dropFirst()).allSatisfy { $0.0 < $0.1 }
        }

        func animation(duration: TimeInterval) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values.map { NSNumber(value: $0) }
            animation.keyTimes = times.map { NSNumber(value: $0 / (times.last ?? 1)) }
            animation.duration = duration
            animation.calculationMode = .linear
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            return animation
        }
    }

    struct Layer: Decodable {
        let id: String
        let parent: String
        let frame: [Double]
        let anchorPoint: [Double]
        let opacity: Float
        let rotation: Double
        let scale: Double
        let asset: String?
        let clips: Bool?
        let cornerRadius: Double?
        let reducedTitle: Bool?
        let tracks: [Track]
    }

    struct Manifest: Decodable {
        let version: Int
        let canvas: [Double]
        let duration: Double
        let exitStart: Double
        let layers: [Layer]
        let exitTracks: [Track]

        var valid: Bool {
            guard version == 1, canvas == [393, 852], duration == 2.18, exitStart == 1.78,
                  !layers.isEmpty, layers.count < 80,
                  Set(exitTracks.map(\.keyPath)) == ["opacity", "transform.scale"],
                  exitTracks.allSatisfy({ $0.valid(duration: duration - exitStart) }) else { return false }
            var seen: Set<String> = ["canvas"]
            for l in layers {
                guard !seen.contains(l.id), seen.contains(l.parent), l.frame.count == 4,
                      l.frame.allSatisfy(\.isFinite), l.frame[2] > 0, l.frame[3] > 0,
                      l.anchorPoint.count == 2, l.anchorPoint.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                      l.opacity.isFinite, (0...1).contains(l.opacity), l.rotation.isFinite, l.scale.isFinite,
                      l.tracks.allSatisfy({ $0.valid(duration: exitStart) }),
                      l.asset == nil || l.asset?.hasPrefix("LaunchAnim") == true else { return false }
                seen.insert(l.id)
            }
            return layers.contains { $0.asset == "LaunchAnimPaper" }
        }
    }

    /// 只在专用串行后台队列调用；显式解码，不能把懒解码留到 CA 提交时。
    struct Artwork {
        let manifest: Manifest
        let images: [String: CGImage]

        nonisolated static func load() -> Artwork? {
            guard let data = NSDataAsset(name: "LaunchAnimTimeline")?.data,
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.valid else { return nil }
            var images: [String: CGImage] = [:]
            for name in Set(manifest.layers.compactMap(\.asset)).sorted() {
                guard let image = UIImage(named: name, in: .main, compatibleWith: UITraitCollection(displayScale: 3))?
                    .preparingForDisplay()?.cgImage else { return nil }
                images[name] = image
            }
            return Artwork(manifest: manifest, images: images)
        }
    }

    private let artwork: Artwork?
    private let canvas = CALayer()
    private var layers: [String: CALayer] = [:]
    private let reducedMotion: Bool
    var usesBakedArtwork: Bool { artwork != nil }
    var shortPresentation: Bool { reducedMotion || artwork == nil }
    var preExitDuration: TimeInterval { shortPresentation ? 0.36 : LaunchSplash.Timing.minimum }
    var exitDuration: TimeInterval { shortPresentation ? 0.20 : LaunchSplash.Timing.lift }

    init(frame: CGRect, artwork: Artwork?, reducedMotion: Bool) {
        self.artwork = artwork
        self.reducedMotion = reducedMotion
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = UIColor(named: "LaunchPaper") ?? UIColor(red: 0.929, green: 0.914, blue: 0.875, alpha: 1)
        clipsToBounds = true
        layer.addSublayer(canvas)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let artwork {
            canvas.bounds = CGRect(x: 0, y: 0, width: artwork.manifest.canvas[0], height: artwork.manifest.canvas[1])
            layers["canvas"] = canvas
            for spec in artwork.manifest.layers {
                let l = CALayer()
                l.bounds = CGRect(x: 0, y: 0, width: spec.frame[2], height: spec.frame[3])
                l.anchorPoint = CGPoint(x: spec.anchorPoint[0], y: spec.anchorPoint[1])
                l.position = CGPoint(x: spec.frame[0] + spec.frame[2] * spec.anchorPoint[0],
                                     y: spec.frame[1] + spec.frame[3] * spec.anchorPoint[1])
                l.opacity = spec.opacity
                l.transform = CATransform3DScale(CATransform3DMakeRotation(spec.rotation, 0, 0, 1), spec.scale, spec.scale, 1)
                l.masksToBounds = spec.clips ?? false
                l.cornerRadius = CGFloat(spec.cornerRadius ?? 0)
                l.contentsScale = 3
                l.contentsGravity = .resize
                if let name = spec.asset { l.contents = artwork.images[name] }
                // 初始模型层与脚本的 native t=0 合成一致；Reduce Motion 也从这帧接手。
                for track in spec.tracks { l.setValue(track.values[0], forKeyPath: track.keyPath) }
                layers[spec.parent]?.addSublayer(l)
                layers[spec.id] = l
            }
        } else {
            // 尚未烘焙 / 资源不完整：继续使用当前系统启动图，短淡出；不能半套新旧素材混播。
            let image = UIImage(named: "LaunchSplash")
            canvas.bounds = CGRect(origin: .zero, size: image?.size ?? CGSize(width: 393, height: 852))
            canvas.contents = image?.cgImage
            canvas.contentsScale = image?.scale ?? 3
            canvas.contentsGravity = .resize
        }
        canvas.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 与 UILaunchScreen 的原尺寸居中一致，不按 safe area / 宽高比重排素材。
        CATransaction.begin(); CATransaction.setDisableActions(true)
        canvas.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    /// 调用方在显示窗口的同一事务里提交整段（含 gate 后的退场），随后 flush。
    func start(at epoch: CFTimeInterval, exitAt: CFTimeInterval) {
        if let artwork {
            for spec in artwork.manifest.layers {
                guard let l = layers[spec.id] else { continue }
                if reducedMotion {
                    guard spec.reducedTitle == true else { continue }
                    let target = spec.tracks.first(where: { $0.keyPath == "opacity" })?.values.last ?? 1
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0; fade.toValue = target; fade.duration = 0.18
                    fade.beginTime = l.convertTime(epoch, from: nil)
                    fade.fillMode = .both; fade.isRemovedOnCompletion = false
                    l.opacity = Float(target); l.add(fade, forKey: "launchTitle")
                } else if !spec.tracks.isEmpty {
                    for tr in spec.tracks { l.setValue(tr.values.last, forKeyPath: tr.keyPath) }
                    let group = CAAnimationGroup()
                    group.animations = spec.tracks.map { $0.animation(duration: preExitDuration) }
                    group.beginTime = l.convertTime(epoch, from: nil)
                    group.duration = preExitDuration
                    group.fillMode = .both; group.isRemovedOnCompletion = false
                    l.add(group, forKey: "launchContent")
                }
            }
        }
        scheduleExit(at: exitAt)
    }

    /// 所有 keyframe 都加好后，把整棵 layer 的时钟平移到最终提交锚；
    /// 分配 NSNumber / CAAnimation 的耗时不能吃掉第 0 帧。之后 scheduleExit 仍接收全局媒体时间。
    func alignPreparedTimeline(from preparedEpoch: CFTimeInterval, to epoch: CFTimeInterval) {
        let parent = layer.superlayer
        let from = parent?.convertTime(preparedEpoch, from: nil) ?? preparedEpoch
        let to = parent?.convertTime(epoch, from: nil) ?? epoch
        layer.beginTime += to - from
    }

    /// covered 预排到 deadline；就绪可提前这个 beginTime，片子本身不重播、不跳帧。
    func scheduleExit(at time: CFTimeInterval) {
        let group = CAAnimationGroup()
        if !shortPresentation, let artwork {
            group.animations = artwork.manifest.exitTracks.map { $0.animation(duration: exitDuration) }
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = exitDuration
            group.animations = [fade]
        }
        group.beginTime = layer.convertTime(time, from: nil)
        group.duration = exitDuration
        group.fillMode = .both; group.isRemovedOnCompletion = false
        layer.opacity = 0
        if !shortPresentation { layer.transform = CATransform3DMakeScale(1.018, 1.018, 1) }
        layer.add(group, forKey: "launchExit")
    }
}

/// 只跨线程传递不可变 Artwork；锁只保护结果槽，不在锁内解码或等待主线程。
final class LaunchArtworkPreparation: @unchecked Sendable {
    struct Result {
        let artwork: LaunchSplashAnimationView.Artwork?
        let began: CFTimeInterval
        let ended: CFTimeInterval
    }
    private let queue = DispatchQueue(label: "mp.launch.artwork", qos: .userInitiated)
    private let lock = NSLock()
    private var result: Result?
    private var cancelled = false

    @MainActor func start() {
        queue.async { [self] in
            let began = CACurrentMediaTime()
            let artwork = autoreleasepool { LaunchSplashAnimationView.Artwork.load() }
            let value = Result(artwork: artwork, began: began, ended: CACurrentMediaTime())
            lock.lock()
            if !cancelled { result = value }
            lock.unlock()
            DispatchQueue.main.async { LaunchSplash.artworkDidPrepare() }
        }
    }

    func takeResult() -> Result? {
        lock.lock(); defer { lock.unlock() }
        let value = result
        result = nil
        return value
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        result = nil
    }
}
#endif
