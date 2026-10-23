#if PERSONAL_APPS
import SwiftUI

/// 死亡天平（plan-death-scale T7–T10b）：版画 + 时辰 + 账簿。界面文字只用法文
struct DeathScaleView: View {
    @State private var store = DeathScaleStore.shared
    @State private var sheet: DeathScaleSheetRequest?
    @State private var carnetOpen = false
    @State private var drop: DeathScaleDrop?
    @Environment(\.colorScheme) private var scheme
    #if os(iOS)
    @Environment(\.page2AppActive) private var appActive
    #else
    private let appActive = true
    #endif

    private var palette: DeathScalePalette { DeathScalePalette(scheme) }
    /// 版画外面的整页一律墨底（粟粟 10-02：外面的纸是黑色），版画和卡片仍跟系统深浅走
    private let page = DeathScalePalette(.dark)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DeathScalePlateView(store: store, palette: palette, active: appActive, drop: drop) { target in
                    switch target {
                    case .weight(let id): sheet = .init(route: .weight(id))
                    case .list(let side): sheet = .init(route: .list(side))
                    case .hourglass: toggleHour()
                    case .book: carnetOpen = true
                    case .register: sheet = .init(route: .register)
                    }
                }
                .padding(9)
                .background(palette.plate)
                .overlay(Rectangle().strokeBorder(palette.ink.opacity(0.12), lineWidth: 1))

                DeathScaleRule(title: "LES HEURES", palette: page).padding(.top, 30).padding(.bottom, 12)
                hoursHead
                ForEach(store.hours.reversed()) { hour in
                    Button { sheet = .init(route: .hour(hour.id)) } label: { DeathScaleHourRow(hour: hour, palette: page) }
                        .buttonStyle(.plain)
                }
                Button { sheet = .init(route: .hour(nil)) } label: {
                    Text("AJOUTER UNE HEURE")
                        .font(DeathScaleFont.smallCaps.font(11)).tracking(2.4)
                        .foregroundStyle(page.faint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if store.lastError != nil {
                    DeathScaleVoid(text: "L’encre n’a pas pris.", palette: page).padding(.top, 12)
                }
                colophon
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 48)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(page.paper.ignoresSafeArea())
        .foregroundStyle(page.ink)
        .tint(page.ink)
        .sheet(item: $sheet) { request in
            DeathScaleSheet(store: store, initial: request.route, palette: palette) { added in
                drop = DeathScaleDrop(id: added, start: Date().addingTimeInterval(0.35))
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $carnetOpen) { DeathScaleCarnet(store: store, palette: palette) }
        #else
        .sheet(isPresented: $carnetOpen) { DeathScaleCarnet(store: store, palette: palette).frame(minWidth: 460, minHeight: 620) }
        #endif
    }

    private func toggleHour() {
        if store.openHour == nil { store.startHour() } else { store.endHour() }
    }

    private var hoursHead: some View {
        HStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1, paused: !appActive)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    if let open = store.openHour {
                        Text(DeathScaleText.duration(context.date.timeIntervalSince(open.start)))
                            .font(DeathScaleFont.pica.font(30))
                        Text("DEPUIS \(DeathScaleText.hms(open.start)) · UTC + 8")
                            .font(DeathScaleFont.smallCaps.font(11)).tracking(2.4)
                            .foregroundStyle(page.ink2)
                    } else {
                        Text(DeathScaleText.hms(context.date)).font(DeathScaleFont.pica.font(30))
                        Text("UTC + 8").font(DeathScaleFont.smallCaps.font(11)).tracking(2.4).foregroundStyle(page.ink2)
                    }
                }
                .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: toggleHour) { DeathScaleSeal(on: store.openHour != nil, palette: page) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var colophon: some View {
        VStack(spacing: 6) {
            Text("Et nunc, quid pondus ?")
                .font(DeathScaleFont.englishItalic.font(12.5)).tracking(0.5)
                .foregroundStyle(page.ink2)
            Text("Toutes les heures · Asia/Shanghai")
                .font(DeathScaleFont.smallCaps.font(10)).tracking(3)
                .foregroundStyle(page.faint)
            Button { sheet = .init(route: .access) } label: {
                Text("QUI PEUT LIRE")
                    .font(DeathScaleFont.smallCaps.font(10)).tracking(3)
                    .foregroundStyle(page.faint)
                    .padding(.vertical, 8).padding(.horizontal, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .multilineTextAlignment(.center)
        .padding(.top, 30)
    }
}

// MARK: - 小件

struct DeathScaleRule: View {
    let title: String
    let palette: DeathScalePalette

    var body: some View {
        HStack(spacing: 10) {
            rule
            Text(title).font(DeathScaleFont.smallCaps.font(14)).tracking(4.5).fixedSize()
            rule
        }
        .padding(.horizontal, 2)
    }

    private var rule: some View {
        VStack(spacing: 1.4) {
            Rectangle().fill(palette.ink).frame(height: 0.6)
            Rectangle().fill(palette.ink).frame(height: 0.25)
        }
        .padding(.top, 2)
    }
}

struct DeathScaleVoid: View {
    let text: String
    let palette: DeathScalePalette

    var body: some View {
        Text(text)
            .font(DeathScaleFont.englishItalic.font(13))
            .foregroundStyle(palette.faint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}

struct DeathScaleSeal: View {
    let on: Bool
    let palette: DeathScalePalette

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2
                var ticks = Path()
                for i in 0..<60 {
                    let a = Double(i) / 60 * 2 * .pi
                    ticks.move(to: CGPoint(x: c.x + cos(a) * r * 0.76, y: c.y + sin(a) * r * 0.76))
                    ticks.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                }
                ctx.stroke(ticks, with: .color(palette.ink), lineWidth: 0.6)
                let inner = Path(ellipseIn: CGRect(x: c.x - r * 0.74, y: c.y - r * 0.74, width: r * 1.48, height: r * 1.48))
                ctx.fill(inner, with: .color(on ? palette.ink : palette.paper))
                ctx.stroke(Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)), with: .color(palette.ink), lineWidth: 1.5)
            }
            Text(on ? "L’HEURE\nPASSE" : "L’HEURE\nVIENT")
                .font(DeathScaleFont.smallCaps.font(10)).tracking(1.1)
                .multilineTextAlignment(.center)
                .lineSpacing(1)
                .foregroundStyle(on ? palette.paper : palette.ink)
        }
        .frame(width: 74, height: 74)
        .contentShape(Circle())
        .accessibilityLabel(on ? "L’HEURE PASSE" : "L’HEURE VIENT")
    }
}

struct DeathScaleRow<Middle: View>: View {
    let stamp: String
    let trailing: String
    let palette: DeathScalePalette
    var size: CGFloat = 13
    @ViewBuilder let middle: Middle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(stamp).font(DeathScaleFont.pica.font(size - 0.5)).foregroundStyle(palette.ink2).fixedSize()
            middle.frame(maxWidth: .infinity, alignment: .leading)
            Text(trailing).font(DeathScaleFont.pica.font(size)).foregroundStyle(palette.ink2).fixedSize()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.ink.opacity(0.35)).frame(height: 0.5) }
        .contentShape(Rectangle())
    }
}

struct DeathScaleHourRow: View {
    let hour: DeathScale.Hour
    let palette: DeathScalePalette

    var body: some View {
        DeathScaleRow(stamp: DeathScaleTime.format(hour.start),
                      trailing: hour.end.map { DeathScaleText.duration($0.timeIntervalSince(hour.start)) } ?? "…",
                      palette: palette) {
            Text("→ " + (hour.end.map(DeathScaleText.hms) ?? "…")).font(DeathScaleFont.english.font(13))
        }
    }
}

struct DeathScaleLedgerRow: View {
    let entry: DeathScale.LedgerEntry
    let palette: DeathScalePalette
    var size: CGFloat = 13
    var showSymbol = true

    var body: some View {
        DeathScaleRow(stamp: DeathScaleTime.format(entry.at), trailing: "\(entry.sumDie) : \(entry.sumLive)", palette: palette, size: size) {
            line
        }
    }

    private var line: Text {
        var t = showSymbol ? Text(DeathScaleText.symbol(entry) + " ").font(DeathScaleFont.english.text(size)) : Text("")
        for seg in DeathScaleText.ledger(entry) {
            t = t + Text(seg.text)
                .font((seg.italic ? DeathScaleFont.englishItalic : DeathScaleFont.english).text(size))
                .foregroundStyle(seg.italic ? palette.ink2 : palette.ink)
        }
        return t
    }
}

struct DeathScaleSheetRequest: Identifiable {
    enum Route: Equatable {
        case weight(UUID)
        case list(DeathScale.Side)
        case hour(UUID?)
        case access
        case register
    }

    let id = UUID()
    let route: Route
}
#endif
