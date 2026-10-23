#if os(iOS)
import UIKit
import Observation
import os

/// 花园四季的时钟和出图缓存：所有壁纸实例共用。
/// - `frameBucket`：本地时间 10 分钟一档（低电量 30 分钟），只在跨档时写——壁纸视图在 UIKit 里观察它换帧
/// - `isDaylight`：只在日出 / 日落翻转时写——SwiftUI 侧的浅 / 深判断读它，一天最多触发两次重算
/// - 出图串行（一次只画一张），没人等的请求在开画前丢掉；主屏动画版要整套部件（#039），别的实例只要静帧
@MainActor
@Observable
final class GardenClock {
    static let shared = GardenClock()

    struct FrameKey: Hashable, Sendable {
        let bucket: Int, pixelWidth: Int, pixelHeight: Int, scale: CGFloat
        var parts = false
        var lowPower = false
    }
    enum Frame {
        case still(UIImage)
        case parts(GardenParts, base: UIImage)
        var base: UIImage { switch self { case .still(let image): image; case .parts(_, let base): base } }
    }
    struct Ticket { let key: FrameKey, token: Int }

    private(set) var isDaylight: Bool
    private(set) var frameBucket: Int

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var cache: [FrameKey: Frame] = [:]
    @ObservationIgnored private var cacheOrder: [FrameKey] = []
    @ObservationIgnored private var waiting: [FrameKey: [Int: (Frame?) -> Void]] = [:]
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored private let renderQueue = DispatchQueue(label: "garden.render", qos: .utility)
    nonisolated private static let abandoned = OSAllocatedUnfairLock(initialState: Set<FrameKey>())

    private init() {
        let now = Date()
        let c = GardenEnvironment.clock(now)
        isDaylight = GardenEnvironment(hour: c.hour, season: c.season).isDaylight
        frameBucket = Self.bucket(now)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.timer?.invalidate(); self?.timer = nil }
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cache.removeAll(); self?.cacheOrder.removeAll() }
        }
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.significantTimeChangeNotification,
                     Notification.Name.NSSystemTimeZoneDidChange, Notification.Name.NSProcessInfoPowerStateDidChange] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(); self?.startTimer() }
            }
        }
        startTimer()
    }

    /// 按本地时间切档：改时区立刻换档，旧图不会继续命中
    private static func bucket(_ date: Date) -> Int {
        let local = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
        return Int(local / (ProcessInfo.processInfo.isLowPowerModeEnabled ? 1800 : 600))
    }

    private func startTimer() {
        guard timer == nil, UIApplication.shared.applicationState != .background else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        let now = Date()
        let b = Self.bucket(now)
        if b != frameBucket { frameBucket = b }
        let c = GardenEnvironment.clock(now)
        let day = GardenEnvironment(hour: c.hour, season: c.season).isDaylight
        if day != isDaylight { isDaylight = day }
    }

    func key(size: CGSize, scale: CGFloat, parts: Bool = false) -> FrameKey {
        FrameKey(bucket: frameBucket, pixelWidth: Int((size.width * scale).rounded()), pixelHeight: Int((size.height * scale).rounded()), scale: scale,
                 parts: parts, lowPower: parts && ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// 要一帧：命中缓存同步回调；否则排进串行出图队列，画完在主线程回调（同一帧只画一次）。失败回调 nil，调用方可再要
    func frame(_ key: FrameKey, completion: @escaping (Frame?) -> Void) -> Ticket? {
        if let image = cache[key] { completion(image); return nil }
        nextToken += 1
        let token = nextToken
        let isNew = waiting[key] == nil
        waiting[key, default: [:]][token] = completion
        guard isNew else { return Ticket(key: key, token: token) }
        Self.abandoned.withLock { _ = $0.remove(key) }
        let c = GardenEnvironment.clock(Date())
        let w = Double(key.pixelWidth) / Double(key.scale), h = Double(key.pixelHeight) / Double(key.scale), sc = Double(key.scale)
        renderQueue.async {
            if Self.abandoned.withLock({ $0.contains(key) }) {
                Task { @MainActor in GardenClock.shared.finish(key, nil) }
                return
            }
            func prepared(_ image: CGImage) -> UIImage {
                let ui = UIImage(cgImage: image, scale: CGFloat(sc), orientation: .up)
                return ui.preparingForDisplay() ?? ui
            }
            let frame: Frame?
            if key.parts {
                let parts = GardenRenderer.renderParts(width: w, height: h, scale: sc, hour: c.hour, season: c.season)
                frame = parts.flatMap { p in p.base.map { .parts(p, base: prepared($0)) } }
            } else {
                frame = GardenRenderer.render(width: w, height: h, scale: sc, hour: c.hour, season: c.season).map { .still(prepared($0)) }
            }
            Task { @MainActor in GardenClock.shared.finish(key, frame) }
        }
        return Ticket(key: key, token: token)
    }

    /// 视图换了请求或离开窗口：撤掉自己的回调；这一帧没人等了就标记作废，还没开画的直接跳过
    func cancel(_ ticket: Ticket) {
        waiting[ticket.key]?.removeValue(forKey: ticket.token)
        if waiting[ticket.key]?.isEmpty == true {
            waiting[ticket.key] = nil
            Self.abandoned.withLock { _ = $0.insert(ticket.key) }
        }
    }

    private func finish(_ key: FrameKey, _ image: Frame?) {
        let callbacks = waiting.removeValue(forKey: key) ?? [:]
        Self.abandoned.withLock { _ = $0.remove(key) }
        if let image {
            cache[key] = image
            cacheOrder.append(key)
            // 静帧最多 4 张；整套部件（~7MB）单独只留最新 1 套，两种互不挤占
            let kind = cacheOrder.filter { $0.parts == key.parts }
            for old in kind.dropLast(key.parts ? 1 : 4) {
                cache.removeValue(forKey: old)
                cacheOrder.removeAll { $0 == old }
            }
        }
        callbacks.values.forEach { $0(image) }
    }
}

extension Page2Appearance {
    /// 浅色背景（雾白 / 手绘花园 / 白天的花园四季）；只有花园四季才去读昼夜，别的壁纸不订阅时钟
    @MainActor var isLightBackdrop: Bool {
        let wp = resolvedWallpaper
        return Self.isLightBackdrop(wp, daylight: wp == "garden" && GardenClock.shared.isDaylight)
    }
    /// 桌面文字 / 状态栏用深色：浅背景，或亮遮罩 ≥ 0.5 的照片
    @MainActor var wantsDarkForeground: Bool {
        isLightBackdrop || (resolvedWallpaper == "photo" && dimming >= 0.5)
    }
    /// 小组件玻璃走浅色：雾白，或白天的花园四季
    @MainActor var isPaleGlass: Bool {
        let wp = resolvedWallpaper
        return Self.isPaleGlass(wp, daylight: wp == "garden" && GardenClock.shared.isDaylight)
    }
}
#endif
