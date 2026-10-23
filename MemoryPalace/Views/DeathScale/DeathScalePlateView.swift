#if PERSONAL_APPS
import SwiftUI

/// 版画本身：静态部分缓存成一张图；横梁、秤盘、砝码堆、盘影在 TimelineView 里画，停稳就停
struct DeathScalePlateView: View {
    enum Target: Equatable {
        case weight(UUID)
        case list(DeathScale.Side)
        case hourglass
        case book
        case register
    }

    let store: DeathScaleStore
    let palette: DeathScalePalette
    let active: Bool
    let drop: DeathScaleDrop?
    let onTap: (Target) -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    @State private var backdrop: CGImage?
    @State private var backdropKey = ""
    @State private var pans: DeathScalePlateDrawing.Pans = [:]
    @State private var spring = DeathScaleSpring.resting(at: 0)
    @State private var animating = false

    private typealias S = DeathScaleScene
    private typealias D = DeathScalePlateDrawing

    var body: some View {
        Color.clear
            .aspectRatio(S.width / S.height, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let k = geo.size.width / S.width
                    ZStack(alignment: .topLeading) {
                        if let backdrop {
                            Image(decorative: backdrop, scale: displayScale).resizable()
                        }
                        hourglassLayer(k)
                        TimelineView(.animation(minimumInterval: nil, paused: !(animating && active))) { context in
                            Canvas { ctx, _ in
                                D.drawDynamic(ctx, k: k, angle: spring.angle(at: context.date), pans: pans, drop: drop,
                                              date: context.date, sums: sums, palette: palette)
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let p = CGPoint(x: value.location.x / k, y: value.location.y / k)
                        if let target = D.hit(p, angle: spring.angle(at: Date()), pans: pans) { onTap(target) }
                    })
                    .task(id: "\(Int(geo.size.width))|\(scheme == .dark)|\(displayScale)") {
                        await renderBackdrop(width: geo.size.width)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("LA BALANCE")
            .onChange(of: store.reasons, initial: true) { _, reasons in pans = D.pans(reasons, reusing: pans) }
            .onChange(of: sums) { _, s in
                spring = spring.retargeted(DeathScaleSpring.target(die: s[.die] ?? 0, live: s[.live] ?? 0), at: Date())
                animating = true
            }
            .onChange(of: drop) { _, d in if d != nil { animating = true } }
            .onAppear {
                spring = .resting(at: DeathScaleSpring.target(die: sums[.die] ?? 0, live: sums[.live] ?? 0))
            }
            .task(id: deadline) {
                let wait = deadline.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                animating = false
            }
    }

    private var sums: [DeathScale.Side: Int] { [.die: store.sum(.die), .live: store.sum(.live)] }

    private var deadline: Date {
        max(spring.settleDate, drop?.end ?? .distantPast)
    }

    private func renderBackdrop(width: CGFloat) async {
        let key = "\(Int(width))|\(scheme == .dark)|\(displayScale)"
        guard width > 0, key != backdropKey else { return }
        let art = await Task.detached(priority: .userInitiated) { S.staticArt }.value
        guard !Task.isCancelled else { return }
        if let image = D.backdrop(art, width: width, scale: displayScale, palette: palette) {
            backdrop = image
            backdropKey = key
        }
    }

    @ViewBuilder
    private func hourglassLayer(_ k: CGFloat) -> some View {
        if let open = store.openHour {
            TimelineView(.animation(minimumInterval: 0.1, paused: !active)) { context in
                Canvas { ctx, _ in D.drawHourglass(ctx, k: k, openSince: open.start, date: context.date, palette: palette) }
            }
        } else {
            Canvas { ctx, _ in D.drawHourglass(ctx, k: k, openSince: nil, date: .now, palette: palette) }
        }
    }
}

/// 版画的画法，跟 view 状态无关（单测 / 离屏出图也走这里）
enum DeathScalePlateDrawing {
    struct PanWeight {
        var placement: DeathScaleHeap.Placement
        var art: DeathScaleArt
    }

    typealias Pans = [DeathScale.Side: [PanWeight]]
    private typealias S = DeathScaleScene

    @MainActor
    static func backdrop(_ art: DeathScaleScene.Static, width: CGFloat, scale: CGFloat, palette: DeathScalePalette) -> CGImage? {
        let k = width / S.width
        let canvas = Canvas { ctx, _ in
            var c = ctx
            c.scaleBy(x: k, y: k)
            art.frame.draw(in: c, palette: palette)
            art.scene.draw(in: sceneContext(ctx, k: k), palette: palette)
        }
        .frame(width: width, height: width * S.height / S.width)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = scale
        return renderer.cgImage
    }

    static func sceneContext(_ ctx: GraphicsContext, k: CGFloat) -> GraphicsContext {
        var c = ctx
        c.scaleBy(x: k, y: k)
        c.clip(to: Path(S.pictureRect))
        c.concatenate(S.sceneTransform)
        return c
    }

    static func panOrigin(_ side: DeathScale.Side, angle: Double) -> CGPoint {
        let r = angle * .pi / 180, s = side == .die ? -1.0 : 1
        return CGPoint(x: S.pivot.x + s * S.arm * cos(r), y: S.pivot.y + s * S.arm * sin(r) + 8)
    }

    static func drawHourglass(_ ctx: GraphicsContext, k: CGFloat, openSince: Date?, date: Date, palette: DeathScalePalette) {
        let scene = sceneContext(ctx, k: k)
        guard let openSince else {
            S.hourglassArt[false]?.draw(in: scene, palette: palette)
            return
        }
        S.hourglassArt[true]?.draw(in: scene, palette: palette)
        let phase = -CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.35) / 0.35 * 6)
        scene.stroke(S.hourglassStream, with: .color(palette.ink), style: StrokeStyle(lineWidth: 0.8, dash: [1.5, 1.5], dashPhase: phase))
        DeathScaleArt.draw(.init(text: DeathScaleText.hms(openSince), face: .pica, size: 9,
                                 at: CGPoint(x: S.hourglassOrigin.x, y: 398), halo: true), in: scene, palette: palette)
    }

    static func drawDynamic(_ ctx: GraphicsContext, k: CGFloat, angle: Double, pans: Pans, drop: DeathScaleDrop?,
                            date: Date, sums: [DeathScale.Side: Int], palette: DeathScalePalette) {
        let scene = sceneContext(ctx, k: k)
        let sides: [DeathScale.Side] = [.die, .live]
        for side in sides {
            let o = panOrigin(side, angle: angle)
            let lift = (o.y + S.rim + S.depth) - 330
            var shadow = scene
            shadow.translateBy(x: o.x, y: 368)
            shadow.scaleBy(x: 1 + lift / 160, y: 1)
            shadow.opacity = DeathScaleEngraver.clamp(0.55 + lift / 70, 0.25, 1)
            S.shadowArt.draw(in: shadow, palette: palette)
        }
        for side in sides {
            let o = panOrigin(side, angle: angle)
            var pan = scene
            pan.translateBy(x: o.x, y: o.y)
            S.panBackArt.draw(in: pan, palette: palette)
            for w in pans[side] ?? [] {
                var c = pan
                c.translateBy(x: w.placement.x, y: w.placement.y)
                if let drop, drop.id == w.placement.id, let pose = drop.pose(at: date) {
                    c.translateBy(x: 0, y: pose.dy)
                    c.opacity = pose.opacity
                }
                w.art.draw(in: c, palette: palette)
            }
            S.panFrontArt[side]?.draw(in: pan, palette: palette)
        }
        var beam = scene
        beam.translateBy(x: S.pivot.x, y: S.pivot.y)
        beam.rotate(by: .degrees(angle))
        beam.translateBy(x: -S.pivot.x, y: -S.pivot.y)
        S.beamArt.draw(in: beam, palette: palette)
        S.forkArt.draw(in: scene, palette: palette)

        var plate = ctx
        plate.scaleBy(x: k, y: k)
        for side in sides {
            guard let c = S.sealCenters[side] else { continue }
            DeathScaleArt.draw(.init(text: String(sums[side] ?? 0), face: .pica, size: 14, at: CGPoint(x: c.x, y: S.barY + 14)), in: plate, palette: palette)
        }
    }

    /// 砝码堆刻好缓存；位置 / 大小没变的砝码沿用旧的刻线
    static func pans(_ reasons: [DeathScale.Reason], reusing old: Pans = [:]) -> Pans {
        var next: Pans = [:]
        for side in DeathScale.Side.allCases {
            let items = reasons.filter { $0.side == side }.map { DeathScaleHeap.Item(id: $0.id, weight: $0.weight, createdAt: $0.createdAt) }
            let cache = Dictionary((old[side] ?? []).map { ($0.placement.id, $0) }, uniquingKeysWith: { a, _ in a })
            next[side] = DeathScaleHeap.layout(items).placements.map { p in
                if let cached = cache[p.id], cached.placement.size == p.size, cached.placement.weight == p.weight {
                    return PanWeight(placement: p, art: cached.art)
                }
                let seed = S.seed(p.id)
                var art = S.weight(p.size, side: side, seed: seed)
                art.append(S.cartouche(p.size, weight: p.weight, seed: seed))
                return PanWeight(placement: p, art: art)
            }
        }
        return next
    }

    /// 版面坐标里点到了什么；砝码在最上层，先判
    static func hit(_ p: CGPoint, angle: Double, pans: Pans) -> DeathScalePlateView.Target? {
        for side in DeathScale.Side.allCases {
            if let c = S.sealCenters[side], hypot(p.x - c.x, p.y - c.y) < 18 { return .list(side) }
        }
        guard S.pictureRect.contains(p) else { return nil }
        let q = p.applying(S.sceneTransform.inverted())
        for side in DeathScale.Side.allCases {
            let o = panOrigin(side, angle: angle)
            let local = CGPoint(x: q.x - o.x, y: q.y - o.y)
            for w in (pans[side] ?? []).reversed() {
                let s = max(w.placement.size, 14)
                let rect = CGRect(x: w.placement.x - s / 2, y: w.placement.y - s * 1.15, width: s, height: s * 1.15)
                if rect.contains(local) { return .weight(w.placement.id) }
            }
            let panRect = CGRect(x: -S.panRadius - 4, y: S.rim - 90, width: S.panRadius * 2 + 8, height: S.depth + 96)
            if panRect.contains(local) { return .list(side) }
        }
        if S.hourglassHit.contains(q) { return .hourglass }
        if S.bookHit.insetBy(dx: -4, dy: -4).contains(q) { return .book }
        if S.registerHit.contains(q) { return .register }
        for side in DeathScale.Side.allCases {
            if let r = S.stoneRects[side], r.insetBy(dx: -2, dy: -6).contains(q) { return .list(side) }
        }
        return nil
    }
}
#endif
