import SwiftUI
import PhotosUI

// MARK: - 纪念日卡（plan-calendar §八 P5）
// 四种样子：镂空星卡（p2 + p3）· 夜·像素花（p5）· 彩色刺绣（p8）· 仙尘星轨（p6）。
// 按 250pt 的设计稿画，任意边长等比缩放（缩略版就是同一张卡）。

enum AnniversaryText {
    static func subtitle(_ a: Anniversary) -> String {
        switch a.kind {
        case .yearly:
            if let l = a.lunar { return "农历\(lunarLabel(l)) · 每年" }
            let parts = a.date.split(separator: "-")
            return parts.count == 3 ? "\(Int(parts[1]) ?? 0)月\(Int(parts[2]) ?? 0)日 · 每年" : a.date
        case .countdown: return a.date
        case .since: return "\(a.date) 起"
        }
    }

    static func lunarLabel(_ l: LunarMonthDay) -> String {
        let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
        let days = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
        let m = (1...12).contains(l.month) ? months[l.month - 1] : "\(l.month)"
        let d = (1...30).contains(l.day) ? days[l.day - 1] : "\(l.day)"
        return "\(l.leap ? "闰" : "")\(m)月\(d)"
    }

    /// (前缀, 数字)：「还有 / 已经 / 就是今天 / 已过」
    static func count(_ a: Anniversary, today: Date = Date()) -> (String, String) {
        guard let c = AnniversaryMath.countdown(for: a, today: today) else { return ("", "–") }
        switch a.kind {
        case .since: return ("已经", "\(c.days)")
        case .countdown: return c.days == 0 ? ("就是", "今天") : (c.isPast ? "已过" : "还有", "\(c.days)")
        case .yearly: return c.days == 0 ? ("就是", "今天") : ("还有", "\(c.days)")
        }
    }
}

struct AnniversaryCard: View {
    let anniversary: Anniversary
    /// 照片文件位置（调用方从楼层 store 算；没有就 nil）
    var photoURL: URL?
    /// 已经在手上的图（编辑器草稿 / 存成图前预先读好的）：有它就不去读盘
    var preloaded: CGImage?
    var today = Date()

    @State private var loaded: CGImage?
    @State private var missing = false

    private var photo: CGImage? { preloaded ?? loaded }

    var body: some View {
        GeometryReader { geo in
            // 字号按 170 宽定基准，等比缩放：墙（≈170）、编辑预览、500pt 导出同一个比例
            let k = geo.size.width / 170
            let s = geo.size.width / 250
            ZStack(alignment: .topLeading) {
                Self.background(anniversary.style)
                Canvas { ctx, size in
                    ctx.scaleBy(x: size.width / 250, y: size.width / 250)
                    Self.draw(anniversary.style, in: &ctx, seed: CalendarInk.seed(anniversary.id), photo: photo,
                              placeholder: placeholderText, today: today)
                }
                captions(k: k, s: s)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6 * k, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6 * k, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .task(id: loadKey) { await load() }
    }

    // MARK: 读图（裁定 #7：身份 = 文件路径 + 修改时间；读不到画占位，不清引用）

    private var loadKey: String {
        guard preloaded == nil, let url = photoURL else { return "" }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(mtime)"
    }

    private func load() async {
        guard !loadKey.isEmpty, let url = photoURL else { loaded = nil; missing = false; return }
        let key = loadKey
        if let hit = AnniversaryPhotoCache.image(for: key) { loaded = hit; missing = false; return }
        let image = await Task.detached(priority: .userInitiated) { AnniversaryPhoto.image(at: url, maxPixel: 900) }.value
        guard !Task.isCancelled, key == loadKey else { return }
        if let image { AnniversaryPhotoCache.set(image, for: key) }
        loaded = image
        missing = image == nil
    }

    /// 照片样式没图时的提示：没放过 →「放一张照片」；放过但读不到（坏了 / 还没从 iCloud 下来）→「照片没找到」；还在读 → 不画
    private var placeholderText: String? {
        guard anniversary.style.needsPhoto, photo == nil else { return nil }
        if anniversary.photo == nil || photoURL == nil { return "放一张照片" }
        return missing ? "照片没找到" : nil
    }

    // MARK: 字

    @ViewBuilder
    private func captions(k: CGFloat, s: CGFloat) -> some View {
        let (prefix, number) = AnniversaryText.count(anniversary, today: today)
        let ink = Self.ink(anniversary.style)
        switch anniversary.style {
        case .cut, .night, .stitch, .dust:
            VStack(alignment: .leading, spacing: 1 * k) {
                Text(anniversary.title).font(.system(size: 13 * k, weight: .semibold)).lineLimit(1)
                Text(AnniversaryText.subtitle(anniversary)).font(.system(size: 12 * k)).opacity(0.8).lineLimit(1)
                Spacer(minLength: 0)
                Text(prefix).font(.system(size: 13 * k)).opacity(0.85)
                bigNumber(number, big: 44 * k, unit: 13 * k)
            }
            .foregroundColor(ink)
            .padding(14 * k)
        case .full:
            // 左下斜 -2° 的小纸条（纸条本身在 Canvas 里画）
            VStack(alignment: .leading, spacing: 0) {
                Text(anniversary.title).font(.system(size: 12 * k, weight: .semibold)).lineLimit(1)
                numberWithDays(number, big: 26 * k, unit: 9 * k)
            }
            .foregroundColor(CalInk.ink)
            .frame(width: 112 * s, alignment: .leading)
            .rotationEffect(.degrees(-2))
            .position(x: 78 * s, y: 205 * s)
        default:
            // 拍立得 / 邮票 / 胶带 / 胶片 / 拱窗：底边一条字
            let bottom: CGFloat = anniversary.style == .film ? 32 : 12
            VStack {
                Spacer(minLength: 0)
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 1 * k) {
                        Text(anniversary.title).font(.system(size: 13 * k, weight: .semibold)).lineLimit(1)
                        if anniversary.style != .film {
                            Text(AnniversaryText.subtitle(anniversary)).font(.system(size: 11 * k)).opacity(0.75).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4 * k)
                    numberWithDays(number, big: 30 * k, unit: 9 * k)
                }
            }
            .foregroundColor(ink)
            .padding(.horizontal, 18 * s)
            .padding(.bottom, bottom * s)
        }
    }

    /// 大数字：手写体；「今天」走苹方（手写体没有中文字形）
    @ViewBuilder
    private func bigNumber(_ number: String, big: CGFloat, unit: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if number == "今天" {
                Text(number).font(.system(size: big * 0.77, weight: .medium))
            } else {
                Text(number).font(CalType.hand(number.count > 4 ? big * 0.73 : big))
                Text("天").font(.system(size: unit))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    @ViewBuilder
    private func numberWithDays(_ number: String, big: CGFloat, unit: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if number == "今天" {
                Text(number).font(.system(size: big * 0.7, weight: .medium))
            } else {
                Text(number).font(CalType.hand(big))
                Text("days").font(CalType.type(unit)).opacity(0.7)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    static func ink(_ s: Anniversary.Style) -> Color {
        switch s {
        case .cut, .dust: Color(red: 0.204, green: 0.251, blue: 0.227)
        case .night: Color(red: 0.949, green: 0.937, blue: 0.902)
        case .stitch: Color(red: 0.478, green: 0.227, blue: 0.133)
        case .film: Color(red: 0.937, green: 0.925, blue: 0.894)
        default: CalInk.ink
        }
    }

    @ViewBuilder
    static func background(_ s: Anniversary.Style) -> some View {
        switch s {
        case .cut: Color(red: 0.984, green: 0.973, blue: 0.945)
        case .night: Color(red: 0.122, green: 0.122, blue: 0.114)
        case .stitch: Color(red: 0.992, green: 0.988, blue: 0.973)
        case .dust: Color(red: 0.969, green: 0.961, blue: 0.937)
        case .polaroid: Color(red: 0.992, green: 0.992, blue: 0.98)
        case .stamp: Color.clear
        case .tape: Color(red: 0.953, green: 0.949, blue: 0.925)
        case .full: Color(red: 0.93, green: 0.93, blue: 0.92)
        case .film: Color.clear
        case .arch: Color(red: 0.969, green: 0.969, blue: 0.957)
        }
    }

    // MARK: 画（250 × 250 坐标）

    /// 照片铺满 rect（居中裁）；没照片：铅笔虚线框 + 一句提示
    static func drawPhoto(_ photo: CGImage?, in rect: CGRect, ctx: inout GraphicsContext, placeholder: String?) {
        if let photo {
            let img = ctx.resolve(Image(decorative: photo, scale: 1))
            let iw = CGFloat(photo.width), ih = CGFloat(photo.height)
            let scale = max(rect.width / iw, rect.height / ih)
            let dw = iw * scale, dh = ih * scale
            ctx.drawLayer { l in
                l.clip(to: Path(rect))
                l.draw(img, in: CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh))
            }
        } else if let placeholder {
            var rng = CalendarInk.Rand(seed: 4)
            ctx.stroke(CalendarInk.rubPath(in: rect.insetBy(dx: 2, dy: 2), amp: 1.2, rng: &rng),
                       with: .color(CalInk.ink3), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            ctx.draw(Text(placeholder).font(.system(size: 13)).foregroundColor(CalInk.ink3), at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    static func draw(_ s: Anniversary.Style, in ctx: inout GraphicsContext, seed: UInt64, photo: CGImage? = nil,
                     placeholder: String? = nil, today: Date = Date()) {
        var rng = CalendarInk.Rand(seed: seed)
        let full = CGRect(x: 0, y: 0, width: 250, height: 250)
        switch s {
        case .polaroid:
            drawPhoto(photo, in: CGRect(x: 16, y: 16, width: 218, height: 154), ctx: &ctx, placeholder: placeholder)
            ctx.stroke(Path(CGRect(x: 16, y: 16, width: 218, height: 154)), with: .color(.black.opacity(0.08)), lineWidth: 1)
        case .stamp:
            ctx.drawLayer { face in
                face.fill(Path(full), with: .color(Color(red: 0.984, green: 0.98, blue: 0.961)))
                drawPhoto(photo, in: CGRect(x: 22, y: 22, width: 206, height: 144), ctx: &face, placeholder: placeholder)
                // 邮戳：几道波浪 + 圆圈里今天的日期
                face.drawLayer { mark in
                    mark.opacity = 0.6
                    let ink = Color(red: 0.31, green: 0.306, blue: 0.294)
                    for k in 0..<4 {
                        var w = Path()
                        let y = 40 + CGFloat(k) * 8
                        w.move(to: CGPoint(x: 120, y: y))
                        for i in 0..<4 {
                            let x0 = 120 + CGFloat(i) * 24
                            w.addQuadCurve(to: CGPoint(x: x0 + 12, y: y), control: CGPoint(x: x0 + 6, y: y - 6))
                            w.addQuadCurve(to: CGPoint(x: x0 + 24, y: y), control: CGPoint(x: x0 + 18, y: y + 6))
                        }
                        mark.stroke(w, with: .color(ink), lineWidth: 1)
                    }
                    mark.stroke(Path(ellipseIn: CGRect(x: 90, y: 30, width: 44, height: 44)), with: .color(ink), lineWidth: 1.1)
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM · d"
                    mark.draw(Text(f.string(from: today).uppercased()).font(CalType.type(8)).foregroundColor(ink), at: CGPoint(x: 112, y: 48))
                    let y = Calendar.current.component(.year, from: today)
                    mark.draw(Text(String(y)).font(CalType.type(8)).foregroundColor(ink), at: CGPoint(x: 112, y: 59))
                }
                // 齿孔：沿四边挖半圆
                face.blendMode = .destinationOut
                var holes = Path()
                var t: CGFloat = 0
                while t <= 250 {
                    for c in [CGPoint(x: t, y: 0), CGPoint(x: t, y: 250), CGPoint(x: 0, y: t), CGPoint(x: 250, y: t)] {
                        holes.addEllipse(in: CGRect(x: c.x - 5.2, y: c.y - 5.2, width: 10.4, height: 10.4))
                    }
                    t += 14.7
                }
                face.fill(holes, with: .color(.black))
            }
        case .tape:
            var dots = Path()
            var y: CGFloat = 7
            while y < 250 { var x: CGFloat = 7; while x < 250 { dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)); x += 14 }; y += 14 }
            ctx.fill(dots, with: .color(Color(red: 0.804, green: 0.8, blue: 0.776)))
            ctx.drawLayer { card in
                card.translateBy(x: 125, y: 100); card.rotate(by: .degrees(-4)); card.translateBy(x: -125, y: -100)
                card.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 2))
                card.drawLayer { face in
                    face.fill(Path(CGRect(x: 36, y: 26, width: 178, height: 148)), with: .color(Color(red: 0.992, green: 0.992, blue: 0.98)))
                    drawPhoto(photo, in: CGRect(x: 44, y: 34, width: 162, height: 132), ctx: &face, placeholder: placeholder)
                }
            }
            for (c, a, color) in [(CGPoint(x: 48, y: 32), -38.0, Color(red: 0.902, green: 0.812, blue: 0.816)),
                                  (CGPoint(x: 206, y: 168), -32.0, Color(red: 0.812, green: 0.847, blue: 0.796))] {
                ctx.drawLayer { t in
                    t.translateBy(x: c.x, y: c.y); t.rotate(by: .degrees(a))
                    t.fill(Path(CGRect(x: -28, y: -9, width: 56, height: 18)), with: .color(color.opacity(0.78)))
                }
            }
        case .full:
            drawPhoto(photo, in: full, ctx: &ctx, placeholder: placeholder)
            ctx.drawLayer { slip in
                slip.translateBy(x: 78, y: 205); slip.rotate(by: .degrees(-2)); slip.translateBy(x: -78, y: -205)
                slip.addFilter(.shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 2))
                slip.fill(Path(CGRect(x: 14, y: 176, width: 128, height: 58)), with: .color(Color(red: 0.984, green: 0.984, blue: 0.973)))
            }
        case .film:
            ctx.drawLayer { strip in
                strip.fill(Path(full), with: .color(Color(red: 0.114, green: 0.114, blue: 0.11)))
                drawPhoto(photo, in: CGRect(x: 10, y: 36, width: 230, height: 128), ctx: &strip, placeholder: placeholder)
                strip.draw(Text("KODAK 400  ▸ 21A").font(CalType.type(10)).tracking(1).foregroundColor(Color(red: 0.851, green: 0.639, blue: 0.416)),
                           at: CGPoint(x: 12, y: 30), anchor: .leading)
                strip.blendMode = .destinationOut
                var holes = Path()
                var x: CGFloat = 8
                while x < 250 {
                    holes.addRoundedRect(in: CGRect(x: x, y: 10, width: 11, height: 15), cornerSize: CGSize(width: 2.5, height: 2.5))
                    holes.addRoundedRect(in: CGRect(x: x, y: 225, width: 11, height: 15), cornerSize: CGSize(width: 2.5, height: 2.5))
                    x += 20
                }
                strip.fill(holes, with: .color(.black))
            }
        case .arch:
            var window = Path()
            window.move(to: CGPoint(x: 34, y: 184)); window.addLine(to: CGPoint(x: 34, y: 118))
            window.addArc(center: CGPoint(x: 125, y: 118), radius: 91, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            window.addLine(to: CGPoint(x: 216, y: 184)); window.closeSubpath()
            ctx.drawLayer { l in
                l.clip(to: window)
                drawPhoto(photo, in: CGRect(x: 34, y: 27, width: 182, height: 157), ctx: &l, placeholder: placeholder)
            }
            var frame = Path()
            frame.move(to: CGPoint(x: 30, y: 186)); frame.addLine(to: CGPoint(x: 30, y: 118))
            frame.addArc(center: CGPoint(x: 125, y: 118), radius: 95, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            frame.addLine(to: CGPoint(x: 220, y: 186))
            ctx.stroke(frame, with: .color(CalInk.ink), lineWidth: 1.4)
            var spear = Path()
            spear.move(to: CGPoint(x: 125, y: 3))
            spear.addCurve(to: CGPoint(x: 125, y: 17), control1: CGPoint(x: 131, y: 9), control2: CGPoint(x: 130, y: 17))
            spear.addCurve(to: CGPoint(x: 125, y: 3), control1: CGPoint(x: 120, y: 17), control2: CGPoint(x: 119, y: 9))
            ctx.fill(spear, with: .color(CalInk.ink))
            var stem = Path(); stem.move(to: CGPoint(x: 125, y: 17)); stem.addLine(to: CGPoint(x: 125, y: 23))
            ctx.stroke(stem, with: .color(CalInk.ink), lineWidth: 1.4)
        case .cut:
            // 底下垫 p3 的刷色 + 奶油圆 + 红点阵；有照片就垫照片（从星孔里透出来）
            ctx.drawLayer { under in
                if let photo {
                    drawPhoto(photo, in: full, ctx: &under, placeholder: nil)
                    return
                }
                under.fill(Path(full), with: .color(Color(red: 0.357, green: 0.584, blue: 0.651)))
                for _ in 0..<60 {
                    var p = Path()
                    let y = rng.next() * 250, x = rng.next() * 250, l = 10 + rng.next() * 60
                    p.move(to: CGPoint(x: x, y: y))
                    p.addQuadCurve(to: CGPoint(x: x + l, y: y + rng.jitter(2)), control: CGPoint(x: x + l / 2, y: y + rng.jitter(2)))
                    under.stroke(p, with: .color(rng.next() < 0.5 ? Color(red: 0.498, green: 0.698, blue: 0.753).opacity(0.55)
                                                                  : Color(red: 0.294, green: 0.522, blue: 0.592).opacity(0.55)),
                                 lineWidth: 0.6 + rng.next())
                }
                let blob = CalendarInk.blob([CGPoint(x: 150, y: 40), CGPoint(x: 230, y: 60), CGPoint(x: 240, y: 150),
                                             CGPoint(x: 190, y: 210), CGPoint(x: 130, y: 170), CGPoint(x: 120, y: 90)], amp: 10, rng: &rng)
                under.fill(blob, with: .color(Color(red: 0.953, green: 0.914, blue: 0.824)))
                under.clip(to: blob)
                var y: CGFloat = 40
                while y < 220 {
                    var x: CGFloat = 110 + (Int(y / 12) % 2 == 0 ? 0 : 6)
                    while x < 245 {
                        under.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(Color(red: 0.659, green: 0.137, blue: 0.169)))
                        x += 12
                    }
                    y += 12
                }
            }
            let cells: [StarHoleCell] = [(4, 1), (5, 1), (5, 2), (6, 2), (4, 3), (5, 3), (6, 0), (3, 2), (6, 4), (5, 5), (6, 5)]
                .map { StarHoleCell(col: $0.0, row: $0.1, level: 4) }
                + [StarHoleCell(col: 3, row: 0, level: 1), StarHoleCell(col: 2, row: 3, level: 2), StarHoleCell(col: 4, row: 5, level: 1)]
            let holes = StarCardCover.holes(cells: cells, cols: 7, rows: 7, cell: 36, origin: CGPoint(x: -2, y: -4), seed: seed)
            ctx.drawLayer { card in
                card.addFilter(.shadow(color: .black.opacity(0.22), radius: 1.2, x: 1.2, y: 1.8))
                card.drawLayer { face in
                    face.fill(Path(full), with: .color(Color(red: 0.984, green: 0.973, blue: 0.945)))
                    face.blendMode = .destinationOut
                    face.drawLayer { h in
                        h.addFilter(.alphaThreshold(min: 0.5, color: .black))
                        h.addFilter(.blur(radius: 1))
                        h.fill(holes, with: .color(.black))
                    }
                }
            }
        case .night:
            if let p = CalendarInk.patterns["pix"] {
                let cream = Color(red: 0.949, green: 0.937, blue: 0.902)
                CalendarInk.draw(p, mode: .pixel, in: &ctx, origin: CGPoint(x: 150, y: 40), cell: 7.2,
                                 head: cream, stem: cream, core: Color(red: 0.122, green: 0.122, blue: 0.114), rng: &rng)
            }
        case .stitch:
            let S = CalendarInk.Stitch.self
            if let p = CalendarInk.patterns["sprig"] {
                CalendarInk.draw(p, mode: .stitch, in: &ctx, origin: CGPoint(x: 150, y: 70), cell: 7, head: S.orange, stem: S.leaf, core: S.rust, rng: &rng)
            }
            if let p = CalendarInk.patterns["tulip"] {
                CalendarInk.draw(p, mode: .stitch, in: &ctx, origin: CGPoint(x: 190, y: 150), cell: 5, head: S.lilac, stem: S.olive, rng: &rng)
            }
            if let p = CalendarInk.patterns["apple"] {
                CalendarInk.draw(p, mode: .stitch, in: &ctx, origin: CGPoint(x: 132, y: 170), cell: 5, head: S.rust, stem: S.leaf, rng: &rng)
            }
            for i in 0..<5 {
                ctx.fill(Path(ellipseIn: CGRect(x: 160 + CGFloat(i) * 16 - 2.2, y: 30 - 2.2, width: 4.4, height: 4.4)), with: .color(S.pink))
            }
        case .dust:
            let ink = Color(red: 0.204, green: 0.2, blue: 0.184)
            ctx.drawLayer { layer in
                func pt(_ t: CGFloat) -> CGPoint {
                    CGPoint(x: 40 + 190 * t, y: 215 - 170 * sin(t * .pi * 0.5) - 40 * t * (1 - t))
                }
                var t: CGFloat = 0
                while t <= 1 {
                    if rng.next() < 0.75 {
                        let p = pt(t), r = 0.6 + rng.next() * 1.1
                        layer.fill(Path(ellipseIn: CGRect(x: p.x + rng.jitter(10) - r, y: p.y + rng.jitter(10) - r, width: r * 2, height: r * 2)), with: .color(ink))
                    }
                    t += 0.018
                }
                for (tt, r) in [(0.25, 4.0), (0.45, 5.0), (0.62, 3.5), (0.78, 6.0)] as [(CGFloat, CGFloat)] {
                    layer.stroke(CalendarInk.sparkle(center: pt(tt), radius: r), with: .color(ink), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
                layer.stroke(CalendarInk.sparkle(center: CGPoint(x: 222, y: 48), radius: 15), with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                CalendarInk.applyGrain(&layer, in: full)
            }
        }
    }
}

/// 纪念日照片的解码缓存（裁定 #12：最多 24 张，按像素计 cost）
enum AnniversaryPhotoCache {
    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 24
        c.totalCostLimit = 24 * 900 * 900 * 4
        return c
    }()

    static func image(for key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }
    static func set(_ image: CGImage, for key: String) {
        cache.setObject(Box(image), forKey: key as NSString, cost: image.width * image.height * 4)
    }
}

// MARK: - 排序（月页的纪念日按钮 / 小组件快照共用）

enum AnniversaryOrdering {
    /// 月历上方 / 小组件：先是快到的（倒数没过的、每年的），按天数；再是正数的
    static func upcoming(_ all: [Anniversary], today: Date = Date()) -> [Anniversary] {
        let scored = all.compactMap { a -> (Anniversary, Int)? in
            guard let c = AnniversaryMath.countdown(for: a, today: today) else { return nil }
            switch a.kind {
            case .countdown: return c.isPast ? nil : (a, c.days)
            case .yearly: return (a, c.days)
            case .since: return (a, 100_000 + c.days)
            }
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

/// 月页上的纪念日：最近两个，铅笔方框按钮（点 → 纪念日页签）
struct AnniversaryStrip: View {
    let anniversaries: [Anniversary]
    var onTap: (Anniversary) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(AnniversaryOrdering.upcoming(anniversaries).prefix(2)) { a in
                let (prefix, number) = AnniversaryText.count(a)
                PencilBoxButton(seed: "ann-\(a.id)", action: { onTap(a) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if number == "今天" {
                                Text(number).font(.system(size: CalType.b, weight: .medium)).foregroundColor(CalInk.ink)
                            } else {
                                Text(number).font(CalType.hand(CalType.n)).foregroundColor(CalInk.ink)
                                Text("days").font(CalType.type(CalType.m)).foregroundColor(CalInk.ink3)
                            }
                        }
                        Text(a.title).font(.system(size: CalType.s)).foregroundColor(CalInk.ink2).lineLimit(1)
                    }
                    .frame(minWidth: 72, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(a.title)，\(prefix)\(number)\(number == "今天" ? "" : "天")")
                .accessibilityAddTraits(.isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 22)
        .padding(.trailing, 16)
    }
}

// MARK: - 卡片墙（分段「纪念日」）

struct AnniversaryWall: View {
    let profileId: String
    let anniversaries: [Anniversary]
    /// 容器宽：窄于 330 单列（mac 窄面板）
    var width: CGFloat = 390
    var onChange: () -> Void

    @State private var editing: Anniversary?
    @State private var sharing: Anniversary?

    private var store: AnniversaryStore { AnniversaryStore.forProfile(profileId) }

    private var columns: [GridItem] {
        width < 330 ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    }

    var body: some View {
        let ordered = AnniversaryOrdering.upcoming(anniversaries)
        let all = ordered + anniversaries.filter { a in !ordered.contains { $0.id == a.id } }
        VStack(alignment: .leading, spacing: 12) {
            if anniversaries.isEmpty {
                CalendarSectionLabel(text: "还没有纪念日。生日、在一起的日子、快到的旅行……都可以放进来。")
            } else {
                CalendarSectionLabel(text: "\(anniversaries.count) 个日子 · 按远近排")
            }
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(all) { a in
                    AnniversaryCard(anniversary: a, photoURL: store.photoURL(a))
                        .shadow(color: .black.opacity(0.08), radius: 5, x: 0, y: 3)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = a }
                        .accessibilityAddTraits(.isButton)
                        .contextMenu {
                            Button("编辑", systemImage: "pencil") { editing = a }
                            Button("存成图", systemImage: "square.and.arrow.up") { sharing = a }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                try? store.delete(id: a.id)
                                onChange()
                            }
                        }
                }
                PencilBoxButton(seed: "ann-add", action: {
                    editing = Anniversary(title: "", kind: .yearly, date: DailyActivity.dayKey(Date(), calendar: .current))
                }) {
                    ZStack(alignment: .bottom) {
                        IronHeart().padding(.bottom, 44)
                        VStack(spacing: 2) {
                            Text("＋ 加一个日子").font(.system(size: CalType.b)).foregroundColor(CalInk.ink)
                            Text("也可以在聊天里说").font(.system(size: CalType.s)).foregroundColor(CalInk.ink3)
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.leading, 22)
            .padding(.trailing, 16)
        }
        .padding(.top, 6)
        .sheet(item: $editing) { a in
            AnniversaryEditor(profileId: profileId, original: a) { onChange() }
        }
        .sheet(item: $sharing) { a in
            AnniversaryShareSheet(anniversary: a, photoURL: store.photoURL(a))
        }
    }
}

/// 「加一个日子」里的铁艺心形卷草（参考 1 粉色那块）：装饰灰，不响应点击
private struct IronHeart: View {
    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height + 44) / 170
            ctx.translateBy(x: size.width / 2 - 85 * k, y: 0)
            ctx.scaleBy(x: k, y: k)
            let hx: CGFloat = 85, hy: CGFloat = 14
            var p = Path()
            for s: CGFloat in [-1, 1] {
                p.move(to: CGPoint(x: hx, y: hy + 92))
                p.addCurve(to: CGPoint(x: hx + s * 34, y: hy + 22), control1: CGPoint(x: hx + s * 10, y: hy + 70), control2: CGPoint(x: hx + s * 36, y: hy + 50))
                p.addCurve(to: CGPoint(x: hx + s * 8, y: hy + 16), control1: CGPoint(x: hx + s * 32, y: hy + 4), control2: CGPoint(x: hx + s * 12, y: hy + 2))
                p.addCurve(to: CGPoint(x: hx + s * 19, y: hy + 22), control1: CGPoint(x: hx + s * 5, y: hy + 26), control2: CGPoint(x: hx + s * 16, y: hy + 30))
                p.addCurve(to: CGPoint(x: hx + s * 13, y: hy + 17), control1: CGPoint(x: hx + s * 21, y: hy + 16), control2: CGPoint(x: hx + s * 15, y: hy + 12))
            }
            p.move(to: CGPoint(x: hx, y: hy + 30)); p.addLine(to: CGPoint(x: hx, y: hy + 92))
            ctx.stroke(p, with: .color(CalInk.graphite), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            var bud = Path()
            bud.move(to: CGPoint(x: hx, y: hy + 30))
            bud.addCurve(to: CGPoint(x: hx, y: hy + 6), control1: CGPoint(x: hx - 3, y: hy + 22), control2: CGPoint(x: hx - 3, y: hy + 14))
            bud.addCurve(to: CGPoint(x: hx, y: hy + 30), control1: CGPoint(x: hx + 3, y: hy + 14), control2: CGPoint(x: hx + 3, y: hy + 22))
            ctx.fill(bud, with: .color(CalInk.graphite))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 存成图

struct AnniversaryShareSheet: View {
    let anniversary: Anniversary
    var photoURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var photo: CGImage?
    @State private var image: Image?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                AnniversaryCard(anniversary: anniversary, photoURL: photoURL, preloaded: photo).frame(maxWidth: 320)
                if let image {
                    ShareLink(item: image, preview: SharePreview(anniversary.title, image: image)) {
                        Label("存成图 / 分享", systemImage: "square.and.arrow.up")
                    }
                } else if failed {
                    Text("照片没找到，先存不了图").font(.system(size: CalType.s)).foregroundColor(CalInk.ink3)
                } else {
                    ProgressView()
                }
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
        // 先把原图读好，再在主线程渲染一次（裁定 #7：不分享纸色占位）
        .task {
            if let url = photoURL {
                photo = await Task.detached(priority: .userInitiated) { AnniversaryPhoto.image(at: url, maxPixel: 1200) }.value
                if photo == nil, anniversary.style.needsPhoto { failed = true; return }
            }
            image = render()
        }
    }

    @MainActor private func render() -> Image? {
        let r = ImageRenderer(content: AnniversaryCard(anniversary: anniversary, preloaded: photo).frame(width: 500, height: 500))
        r.scale = 2
        #if os(iOS)
        return r.uiImage.map { Image(uiImage: $0) }
        #else
        return r.nsImage.map { Image(nsImage: $0) }
        #endif
    }
}

// MARK: - 编辑

struct AnniversaryEditor: View {
    let profileId: String
    let original: Anniversary
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistantName") private var assistantName = "助手"
    @State private var draft: Anniversary
    @State private var pickedDate: Date
    @State private var useLunar: Bool
    @State private var lunar: LunarMonthDay
    @State private var remind: Bool
    // 照片：选了只是草稿，点保存才写盘（裁定 #1）
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingJPEG: Data?
    @State private var pendingImage: CGImage?
    @State private var removePhoto = false
    @State private var photoGeneration = 0
    @State private var loadingPhoto = false
    @State private var saveError: String?

    private var store: AnniversaryStore { AnniversaryStore.forProfile(profileId) }

    init(profileId: String, original: Anniversary, onSave: @escaping () -> Void) {
        self.profileId = profileId
        self.original = original
        self.onSave = onSave
        _draft = State(initialValue: original)
        let d = AnniversaryMath.date(fromKey: original.date, calendar: .current) ?? Date()
        _pickedDate = State(initialValue: d)
        _useLunar = State(initialValue: original.lunar != nil)
        _lunar = State(initialValue: original.lunar ?? AnniversaryMath.lunar(of: d, chinese: AnniversaryMath.chineseCalendar()))
        _remind = State(initialValue: original.remindDays != nil)
    }

    /// 编辑器里现在「有没有照片」：新选的草稿，或者原来的且没点去掉
    private var hasPhoto: Bool { pendingImage != nil || (original.photo != nil && !removePhoto) }
    private var existingPhotoURL: URL? { pendingImage == nil && !removePhoto ? store.photoURL(original) : nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字，比如 妈妈生日", text: $draft.title)
                    Picker("类型", selection: $draft.kind) {
                        Text("每年").tag(Anniversary.Kind.yearly)
                        Text("倒数").tag(Anniversary.Kind.countdown)
                        Text("正数").tag(Anniversary.Kind.since)
                    }
                    if draft.kind == .yearly { Toggle("是生日", isOn: $draft.isBirthday) }
                }
                Section {
                    DatePicker(draft.kind == .since ? "从哪天开始" : "日期", selection: $pickedDate, displayedComponents: .date)
                        .onChange(of: pickedDate) { _, d in
                            lunar = AnniversaryMath.lunar(of: d, chinese: AnniversaryMath.chineseCalendar())
                        }
                    if draft.kind == .yearly {
                        Toggle("按农历过", isOn: $useLunar)
                        if useLunar {
                            Text("农历\(AnniversaryText.lunarLabel(lunar))")
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                } footer: {
                    if draft.kind == .yearly && useLunar {
                        Text("按选中那天的农历算。闰月生日在没有这个闰月的年份过正常月；三十在只有二十九天的月份过二十九。")
                    }
                }
                Section("照片") {
                    HStack(spacing: 12) {
                        if hasPhoto {
                            AnniversaryPhotoThumb(url: existingPhotoURL, preloaded: pendingImage)
                        }
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Text(hasPhoto ? "换一张" : "从相册选…")
                        }
                        if loadingPhoto { ProgressView().controlSize(.small) }
                        Spacer()
                        if hasPhoto {
                            Button("去掉", role: .destructive) {
                                photoGeneration += 1
                                pendingJPEG = nil
                                pendingImage = nil
                                removePhoto = true
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Section("样子") {
                    Picker("样子", selection: $draft.style) {
                        ForEach(Anniversary.Style.allCases, id: \.self) { style in
                            HStack {
                                Text(style.label)
                                if style.acceptsPhoto { Text("用照片").font(.caption).foregroundColor(.secondary) }
                            }
                            .tag(style)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    AnniversaryCard(anniversary: preview, photoURL: existingPhotoURL, preloaded: pendingImage)
                        .frame(maxWidth: 200).frame(maxWidth: .infinity)
                }
                Section {
                    Toggle("让\(assistantName)知道", isOn: $remind)
                    if remind {
                        Stepper("提前 \(draft.remindDays ?? 3) 天", value: Binding(get: { draft.remindDays ?? 3 }, set: { draft.remindDays = $0 }), in: 0...30)
                    }
                } footer: {
                    Text("快到的时候，\(assistantName)会在聊天里知道这件事。")
                }
            }
            .formStyle(.grouped)
            .tint(Theme.branchIndicator)
            .navigationTitle(original.title.isEmpty ? "加一个日子" : "编辑")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || loadingPhoto)
                }
            }
            .onChange(of: photoItem) { _, item in loadPicked(item) }
            .alert("没存上", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 620)
        #endif
    }

    /// 选中的图：压成 JPEG 放内存；连续选两张时只认最后一张（generation）
    private func loadPicked(_ item: PhotosPickerItem?) {
        guard let item else { return }
        photoGeneration += 1
        let gen = photoGeneration
        loadingPhoto = true
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            let jpeg = await Task.detached(priority: .userInitiated) { data.flatMap { AnniversaryPhoto.jpeg(from: $0) } }.value
            guard gen == photoGeneration else { return }
            loadingPhoto = false
            photoItem = nil
            guard let jpeg, let image = AnniversaryPhoto.image(from: jpeg, maxPixel: 900) else {
                saveError = "这张图读不出来，换一张试试。"
                return
            }
            pendingJPEG = jpeg
            pendingImage = image
            removePhoto = false
        }
    }

    private var preview: Anniversary {
        var a = draft
        a.date = DailyActivity.dayKey(pickedDate, calendar: .current)
        a.lunar = (a.kind == .yearly && useLunar) ? lunar : nil
        if a.title.isEmpty { a.title = "名字" }
        if removePhoto && pendingImage == nil { a.photo = nil }
        return a
    }

    private func save() {
        var a = preview
        a.title = draft.title.trimmingCharacters(in: .whitespaces)
        if a.kind != .yearly { a.isBirthday = false }
        a.remindDays = remind ? (draft.remindDays ?? 3) : nil
        a.photo = original.photo
        let change: AnniversaryStore.PhotoChange = pendingJPEG.map { .replace($0) } ?? (removePhoto ? .remove : .keep)
        do {
            try store.save(a, photo: change)
        } catch {
            saveError = error.localizedDescription
            return
        }
        NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
        onSave()
        dismiss()
    }
}

/// 编辑页「照片」那一行的小方图：只有照片本身
private struct AnniversaryPhotoThumb: View {
    var url: URL?
    var preloaded: CGImage?
    @State private var loaded: CGImage?

    var body: some View {
        Group {
            if let image = preloaded ?? loaded {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.12)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url) {
            guard preloaded == nil, let url else { loaded = nil; return }
            loaded = await Task.detached(priority: .userInitiated) { AnniversaryPhoto.image(at: url, maxPixel: 200) }.value
        }
    }
}
