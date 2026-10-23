import SwiftUI
import WidgetKit
import ImageIO

// MARK: - 纪念日小组件（plan-calendar §九 P6）
// 小号：最近一个日子（按那张卡的底色）；中号：最近三个。天数每天零点自己算，快照只给日期。

struct CalendarWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CalendarSnapshot?
}

struct CalendarWidgetProvider: TimelineProvider {
    private static let appGroupId = "group.com.susu.MemoryPalace"

    private func read() -> CalendarSnapshot? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId),
              let data = try? Data(contentsOf: base.appendingPathComponent(CalendarSnapshot.relativePath)) else { return nil }
        return try? JSONDecoder().decode(CalendarSnapshot.self, from: data)
    }

    func placeholder(in context: Context) -> CalendarWidgetEntry {
        CalendarWidgetEntry(date: Date(), snapshot: CalendarSnapshot(
            profileId: "", items: [.init(title: "生日", kind: "yearly", isBirthday: true, style: "night", baseDate: "2000-01-01", targets: [])],
            writtenAt: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarWidgetEntry) -> Void) {
        completion(CalendarWidgetEntry(date: Date(), snapshot: read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarWidgetEntry>) -> Void) {
        // 今天一条 + 之后七个零点各一条：天数跟着日子走，不用等 app 打开
        let cal = Calendar.current
        let snap = read()
        let start = cal.startOfDay(for: Date())
        var entries = [CalendarWidgetEntry(date: Date(), snapshot: snap)]
        for i in 1...7 {
            if let d = cal.date(byAdding: .day, value: i, to: start) { entries.append(CalendarWidgetEntry(date: d, snapshot: snap)) }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

private enum WidgetInk {
    static let paper = Color(red: 0.988, green: 0.984, blue: 0.965)
    static let night = Color(red: 0.122, green: 0.122, blue: 0.114)
    static let ink = Color(red: 0.204, green: 0.251, blue: 0.227)
    static let cream = Color(red: 0.949, green: 0.937, blue: 0.902)

    static func background(_ style: String) -> Color {
        switch style {
        case "night": night
        case "dust": Color(red: 0.969, green: 0.961, blue: 0.937)
        case "cut": Color(red: 0.984, green: 0.973, blue: 0.945)
        default: paper
        }
    }

    static func foreground(_ style: String) -> Color { style == "night" ? cream : ink }

    /// 米字闪星（p6）
    static func sparkle(center c: CGPoint, radius r: CGFloat) -> Path {
        let q = r * 0.45
        var p = Path()
        p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
        p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
        p.move(to: CGPoint(x: c.x - q, y: c.y - q)); p.addLine(to: CGPoint(x: c.x + q, y: c.y + q))
        p.move(to: CGPoint(x: c.x - q, y: c.y + q)); p.addLine(to: CGPoint(x: c.x + q, y: c.y - q))
        return p
    }
}

struct CalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CalendarWidgetEntry

    private var rows: [(CalendarSnapshot.Item, String, Int)] {
        (entry.snapshot?.items ?? []).compactMap { item in
            CalendarSnapshot.days(for: item, today: entry.date, calendar: .current).map { (item, $0.prefix, $0.days) }
        }
    }

    /// 手写体（和日历一致）；「今天」走苹方
    private static func hand(_ size: CGFloat) -> Font { .custom("BradleyHandITCTT-Bold", size: size) }

    /// 缩略图在快照准备好时就写进 App Group；这里读不到（被清了 / 还没写）就当没照片
    private static func photo(_ path: String?, maxPixel: Int) -> Image? {
        guard let path,
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.susu.MemoryPalace"),
              let src = CGImageSourceCreateWithURL(base.appendingPathComponent(path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { Image(decorative: $0, scale: 1) }
    }

    var body: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    @ViewBuilder
    private var small: some View {
        if let (item, prefix, days) = rows.first {
            if let photo = Self.photo(item.photo, maxPixel: 400) {
                // 有照片：照片铺满，左下一张小纸条（和「满幅」卡一个样子）
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            if days == 0 {
                                Text("今天").font(.system(size: 17, weight: .medium))
                            } else {
                                Text("\(days)").font(Self.hand(26)).minimumScaleFactor(0.5).lineLimit(1)
                                Text("days").font(.custom("AmericanTypewriter-Light", size: 9)).opacity(0.7)
                            }
                        }
                    }
                    .foregroundColor(WidgetInk.ink)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(red: 0.984, green: 0.984, blue: 0.973).shadow(.drop(color: .black.opacity(0.2), radius: 3, y: 2)))
                    .rotationEffect(.degrees(-2))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .containerBackground(for: .widget) { photo.resizable().scaledToFill() }
            } else {
                let fg = WidgetInk.foreground(item.style)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Spacer(minLength: 4)
                        Canvas { ctx, size in
                            ctx.stroke(WidgetInk.sparkle(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: size.width * 0.45),
                                       with: .color(fg.opacity(0.8)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                        }
                        .frame(width: 18, height: 18)
                    }
                    Spacer(minLength: 0)
                    Text(days == 0 ? "就是" : prefix).font(.system(size: 11)).opacity(0.65)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        if days == 0 {
                            Text("今天").font(.system(size: 32, weight: .medium))
                        } else {
                            Text("\(days)").font(Self.hand(44)).minimumScaleFactor(0.5).lineLimit(1)
                            Text("天").font(.system(size: 12))
                        }
                    }
                }
                .foregroundColor(fg)
                .containerBackground(WidgetInk.background(item.style), for: .widget)
            }
        } else {
            empty
        }
    }

    @ViewBuilder
    private var medium: some View {
        if rows.isEmpty {
            empty
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("纪念日").font(.system(size: 11.5)).foregroundColor(WidgetInk.ink.opacity(0.6)).tracking(1)
                ForEach(Array(rows.prefix(3).enumerated()), id: \.offset) { i, row in
                    HStack(alignment: .center, spacing: 8) {
                        if let photo = Self.photo(row.0.photo, maxPixel: 132) {
                            photo.resizable().scaledToFill().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        Text(row.0.title).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(row.2 == 0 ? "就是" : row.1).font(.system(size: 11)).opacity(0.6)
                        if row.2 == 0 {
                            Text("今天").font(.system(size: 15, weight: .medium))
                        } else {
                            Text("\(row.2)").font(Self.hand(20))
                            Text("天").font(.system(size: 11)).opacity(0.6)
                        }
                    }
                    if i < min(rows.count, 3) - 1 { Divider().opacity(0.4) }
                }
            }
            .foregroundColor(WidgetInk.ink)
            .containerBackground(WidgetInk.paper, for: .widget)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("还没有纪念日").font(.system(size: 12)).foregroundColor(WidgetInk.ink.opacity(0.6))
            Text("在日历里加一个").font(.system(size: 10.5)).foregroundColor(WidgetInk.ink.opacity(0.4))
        }
        .containerBackground(WidgetInk.paper, for: .widget)
    }
}

struct CalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CalendarSnapshot.widgetKind, provider: CalendarWidgetProvider()) { entry in
            CalendarWidgetView(entry: entry)
        }
        .configurationDisplayName("纪念日")
        .description("最近的纪念日还有几天。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
