#if PERSONAL_APPS
import SwiftUI

/// 底部卡片：砝码 / 一盘的清单 / 一段时辰 / 可读楼层。纸色底、双线框、法文小型大写
struct DeathScaleSheet: View {
    let store: DeathScaleStore
    let palette: DeathScalePalette
    let onAdded: (UUID) -> Void
    @State private var route: DeathScaleSheetRequest.Route
    @State private var height = 320.0
    @State private var detent = PresentationDetent.height(320)
    @Environment(\.dismiss) private var dismiss

    init(store: DeathScaleStore, initial: DeathScaleSheetRequest.Route, palette: DeathScalePalette, onAdded: @escaping (UUID) -> Void) {
        self.store = store
        self.palette = palette
        self.onAdded = onAdded
        _route = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            content
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(palette.ink, lineWidth: 1.5))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.ink, lineWidth: 0.5).padding(5))
                .padding(12)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { h in
                    height = h.rounded()
                    if detent != .large { detent = .height(height) }
                }
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(palette.ink)
        .tint(palette.ink)
        .presentationDetents([.height(height), .large], selection: $detent)
        .presentationBackground(palette.paper)
        .presentationCornerRadius(30)
        #if os(macOS)
        .frame(width: 440, height: min(max(height, 220), 720))
        .background(palette.paper)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .weight(let id):
            if let reason = store.reasons.first(where: { $0.id == id }) {
                DeathScaleWeightCard(store: store, reason: reason, palette: palette,
                                     onRemoved: { route = .list(reason.side) }, onClose: { dismiss() })
                    .id(id)
            } else {
                DeathScaleVoid(text: "Ce poids n’est plus là.", palette: palette)
            }
        case .list(let side):
            DeathScaleListCard(store: store, side: side, palette: palette, onOpen: { route = .weight($0) }, onAdded: onAdded)
        case .hour(let id):
            DeathScaleHourCard(store: store, hour: id.flatMap { id in store.hours.first { $0.id == id } }, palette: palette) { dismiss() }
        case .access:
            DeathScaleAccessCard(store: store, palette: palette)
        case .register:
            DeathScaleRegisterCard(store: store, palette: palette)
        }
    }
}

struct DeathScaleKicker: View {
    let lead: String?
    let main: String
    let palette: DeathScalePalette

    var body: some View {
        (Text(lead.map { "\($0) · " } ?? "").foregroundStyle(palette.ink2) + Text(main))
            .font(DeathScaleFont.smallCaps.font(12)).tracking(4)
            .frame(maxWidth: .infinity)
    }
}

struct DeathScaleActionButton: View {
    let title: String
    var dark = false
    let palette: DeathScalePalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DeathScaleFont.smallCaps.font(13)).tracking(3.9)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(dark ? palette.paper : palette.ink)
                .background(dark ? palette.ink : Color.clear)
                .overlay(Rectangle().strokeBorder(palette.ink, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 一枚砝码的小版画，给卡片和清单用
struct DeathScaleWeightIcon: View {
    let side: DeathScale.Side
    var size = 26.0
    var weight: Int?
    var seed = 0.0
    let palette: DeathScalePalette

    var body: some View {
        Canvas { ctx, frame in
            let box = CGRect(x: -size * 0.6, y: -size * 1.2, width: size * 1.2, height: size * 1.24)
            let k = min(frame.width / box.width, frame.height / box.height)
            var c = ctx
            c.translateBy(x: (frame.width - box.width * k) / 2, y: (frame.height - box.height * k) / 2)
            c.scaleBy(x: k, y: k)
            c.translateBy(x: -box.minX, y: -box.minY)
            var art = DeathScaleScene.weight(size, side: side, seed: seed)
            if let weight { art.append(DeathScaleScene.cartouche(size, weight: weight, seed: seed)) }
            art.draw(in: c, palette: palette)
        }
    }
}

// MARK: - 砝码

struct DeathScaleWeightCard: View {
    let store: DeathScaleStore
    let reason: DeathScale.Reason
    let palette: DeathScalePalette
    let onRemoved: () -> Void
    let onClose: () -> Void
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            DeathScaleKicker(lead: "POIDS", main: DeathScaleText.sideName[reason.side] ?? "", palette: palette)
            DeathScaleWeightIcon(side: reason.side, size: 104, weight: reason.weight, seed: DeathScaleScene.seed(reason.id), palette: palette)
                .frame(width: 150, height: 150)
                .padding(.top, 6)
                .padding(.bottom, 2)
            TextField("", text: $text, axis: .vertical)
                .font(DeathScaleFont.englishItalic.text(21))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($editing)
                .submitLabel(.done)
                .onSubmit(commit)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.ink2).frame(height: 0.5).opacity(editing ? 1 : 0)
                }
                .onChange(of: text) { _, v in
                    if v.contains("\n") { text = v.replacingOccurrences(of: "\n", with: " "); editing = false }
                }
                .onChange(of: editing) { _, on in if !on { commit() } }
            HStack(spacing: 22) {
                dialButton("−", -1)
                VStack(spacing: 4) {
                    Text(DeathScaleScene.roman(reason.weight)).font(DeathScaleFont.smallCaps.font(34)).tracking(2)
                    Text("\(reason.weight) / 9").font(DeathScaleFont.pica.font(12)).tracking(2.4).foregroundStyle(palette.ink2)
                }
                .frame(minWidth: 90)
                dialButton("+", 1)
            }
            .padding(.top, 12)
            .padding(.bottom, 6)
            Text("posé le \(DeathScaleTime.format(reason.createdAt))")
                .font(DeathScaleFont.pica.font(12)).tracking(0.7)
                .foregroundStyle(palette.ink2)
                .padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(store.ledger.filter { $0.reasonId == reason.id }.reversed()) { entry in
                    DeathScaleLedgerRow(entry: entry, palette: palette, size: 12, showSymbol: false)
                }
            }
            .padding(.top, 10)
            HStack(spacing: 10) {
                DeathScaleActionButton(title: "RETIRER", palette: palette) {
                    store.remove(reason.id)
                    onRemoved()
                }
                DeathScaleActionButton(title: "FERMER", dark: true, palette: palette) {
                    commit()
                    onClose()
                }
            }
            .padding(.top, 16)
        }
        .onAppear { text = reason.text }
        .onDisappear(perform: commit)
    }

    private func dialButton(_ label: String, _ delta: Int) -> some View {
        Button { store.setWeight(reason.id, reason.weight + delta) } label: {
            Text(label)
                .font(DeathScaleFont.english.font(22))
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(palette.ink, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!DeathScale.weightRange.contains(reason.weight + delta))
        .opacity(DeathScale.weightRange.contains(reason.weight + delta) ? 1 : 0.35)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.reasons.contains(where: { $0.id == reason.id }) else { return }
        if trimmed.isEmpty { text = reason.text } else { store.setText(reason.id, trimmed) }
    }
}

// MARK: - 一盘的清单

struct DeathScaleListCard: View {
    let store: DeathScaleStore
    let side: DeathScale.Side
    let palette: DeathScalePalette
    let onOpen: (UUID) -> Void
    let onAdded: (UUID) -> Void
    @State private var draft = ""
    @State private var weight = 1

    private var items: [DeathScale.Reason] {
        store.reasons.filter { $0.side == side }.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            DeathScaleKicker(lead: nil, main: "\(DeathScaleText.sideName[side] ?? "") · \(store.sum(side))", palette: palette)
            addBar.padding(.top, 12).padding(.bottom, 6)
            if items.isEmpty {
                DeathScaleVoid(text: "Le plateau est vide.", palette: palette)
            } else {
                ForEach(items) { r in
                    Button { onOpen(r.id) } label: {
                        HStack(spacing: 10) {
                            DeathScaleWeightIcon(side: side, seed: DeathScaleScene.seed(r.id), palette: palette).frame(width: 28, height: 28)
                            Text(r.text).font(DeathScaleFont.english.text(15)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(DeathScaleScene.roman(r.weight)).font(DeathScaleFont.smallCaps.font(15))
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(palette.ink.opacity(0.35)).frame(height: 0.5) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 0) {
            TextField("", text: $draft, prompt: Text("Une raison…").font(DeathScaleFont.englishItalic.font(16)).foregroundStyle(palette.faint))
                .font(DeathScaleFont.englishItalic.text(16))
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit(place)
                .padding(10)
            Rectangle().fill(palette.ink).frame(width: 1)
            HStack(spacing: 0) {
                miniButton("−", -1)
                Text(DeathScaleScene.roman(weight)).font(DeathScaleFont.smallCaps.font(15)).frame(minWidth: 30)
                miniButton("+", 1)
            }
            Button(action: place) {
                Text("POSER")
                    .font(DeathScaleFont.smallCaps.font(12)).tracking(2.4)
                    .foregroundStyle(palette.paper)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .background(palette.ink)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().strokeBorder(palette.ink, lineWidth: 1))
    }

    private func miniButton(_ label: String, _ delta: Int) -> some View {
        Button { weight = min(max(weight + delta, 1), 9) } label: {
            Text(label).font(DeathScaleFont.english.font(17)).frame(width: 24).frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func place() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let added = store.add(side: side, text: text, weight: weight) else { return }
        draft = ""
        weight = 1
        onAdded(added.id)
    }
}

// MARK: - 一段时辰

struct DeathScaleHourCard: View {
    let store: DeathScaleStore
    let hour: DeathScale.Hour?
    let palette: DeathScalePalette
    let onDone: () -> Void
    @State private var start = ""
    @State private var end = ""
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 14) {
            DeathScaleKicker(lead: nil, main: hour == nil ? "UNE HEURE OUBLIÉE" : "UNE HEURE", palette: palette)
            field("DÉBUT", $start, placeholder: "01.10.2026 · 21:00:00")
            field("FIN", $end, placeholder: hour?.end == nil && hour != nil ? "en cours" : "01.10.2026 · 22:00:00")
            if let hour, let e = hour.end {
                Text(DeathScaleText.duration(e.timeIntervalSince(hour.start)))
                    .font(DeathScaleFont.pica.font(13)).foregroundStyle(palette.ink2)
            }
            if let problem {
                Text(problem).font(DeathScaleFont.englishItalic.font(13)).foregroundStyle(palette.ink2)
            }
            HStack(spacing: 10) {
                if let hour {
                    DeathScaleActionButton(title: "EFFACER", palette: palette) {
                        store.deleteHour(hour.id)
                        onDone()
                    }
                }
                DeathScaleActionButton(title: "INSCRIRE", dark: true, palette: palette, action: save)
            }
            .padding(.top, 4)
        }
        .onAppear {
            if let hour {
                start = DeathScaleTime.format(hour.start)
                end = hour.end.map(DeathScaleTime.format) ?? ""
            } else {
                let now = Date()
                start = DeathScaleTime.format(now.addingTimeInterval(-3600))
                end = DeathScaleTime.format(now)
            }
        }
    }

    private func field(_ label: String, _ value: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(DeathScaleFont.smallCaps.font(11)).tracking(2.4).foregroundStyle(palette.ink2)
            TextField("", text: value, prompt: Text(placeholder).foregroundStyle(palette.faint))
                .font(DeathScaleFont.pica.font(18))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                #endif
                .padding(10)
                .overlay(Rectangle().strokeBorder(palette.ink, lineWidth: 1))
        }
    }

    private func save() {
        guard let s = DeathScaleText.parse(start) else { problem = "Le début est illisible : jj.mm.aaaa · hh:mm:ss"; return }
        let trimmedEnd = end.trimmingCharacters(in: .whitespacesAndNewlines)
        let e: Date?
        if trimmedEnd.isEmpty {
            e = nil
        } else if let parsed = DeathScaleText.parse(trimmedEnd) {
            e = parsed
        } else {
            problem = "La fin est illisible : jj.mm.aaaa · hh:mm:ss"
            return
        }
        if let e, e < s { problem = "La fin précède le début."; return }
        if let hour {
            if e == nil, store.hours.contains(where: { $0.id != hour.id && $0.end == nil }) { problem = "Une autre heure court déjà."; return }
            store.editHour(hour.id, start: s, end: e)
        } else {
            guard let e else { problem = "Il faut une fin."; return }
            guard store.addHour(start: s, end: e) != nil else { problem = "L’encre n’a pas pris."; return }
        }
        onDone()
    }
}

// MARK: - 谁能读

struct DeathScaleAccessCard: View {
    let store: DeathScaleStore
    let palette: DeathScalePalette
    @Environment(ProfileManager.self) private var profiles: ProfileManager?

    var body: some View {
        VStack(spacing: 0) {
            DeathScaleKicker(lead: nil, main: "QUI PEUT LIRE", palette: palette)
            Text("Les étages ouverts ici peuvent lire la balance, sans y toucher.")
                .font(DeathScaleFont.englishItalic.font(13))
                .foregroundStyle(palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 10)
            ForEach(profiles?.profiles ?? []) { p in
                Toggle(isOn: Binding(get: { store.canRead(profileId: p.id) },
                                     set: { on in if on { store.grantRead(p.id) } else { store.revokeRead(p.id) } })) {
                    Text("\(p.emoji) \(p.name)").font(DeathScaleFont.english.text(15))
                }
                .toggleStyle(.switch)
                .tint(palette.ink2)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(palette.ink.opacity(0.35)).frame(height: 0.5) }
            }
            if profiles == nil {
                DeathScaleVoid(text: "Aucun étage.", palette: palette)
            }
        }
    }
}

struct DeathScaleRegisterCard: View {
    let store: DeathScaleStore
    let palette: DeathScalePalette

    var body: some View {
        VStack(spacing: 0) {
            DeathScaleKicker(lead: nil, main: "LE REGISTRE", palette: palette).padding(.bottom, 10)
            if store.ledger.isEmpty {
                DeathScaleVoid(text: "Rien encore n’a été pesé.", palette: palette)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.ledger.reversed()) { entry in
                        DeathScaleLedgerRow(entry: entry, palette: palette)
                    }
                }
            }
        }
    }
}

// MARK: - 小本子

struct DeathScaleCarnet: View {
    let store: DeathScaleStore
    let palette: DeathScalePalette
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving: Task<Void, Never>?
    @State private var writtenAt: Date?
    @FocusState private var writing: Bool

    private static let lineHeight = 30.0

    var body: some View {
        VStack(spacing: 0) {
            // 顶上常驻返回：底部 FERMER 会被键盘 / 窗口高度挡住，全屏盖层又没有下滑关闭
            DeathScaleKicker(lead: nil, main: "LE CARNET", palette: palette)
                .padding(.top, 4)
                .overlay(alignment: .leading) {
                    Button(action: close) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("FERMER")
                }
            GeometryReader { geo in
                ScrollView {
                    TextField("", text: $text, prompt: Text("…").foregroundStyle(palette.faint), axis: .vertical)
                        .font(DeathScaleFont.englishItalic.text(17))
                        .modifier(DeathScaleLinePitch(pitch: Self.lineHeight))
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($writing)
                        .padding(.leading, 30)
                        .padding(.trailing, 6)
                        .padding(.top, 3)
                        .frame(maxWidth: .infinity, minHeight: max(420, geo.size.height), alignment: .topLeading)
                        .background(alignment: .topLeading) { paper }
                        .contentShape(Rectangle())
                        .onTapGesture { writing = true }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(.top, 12)
            Text(writtenAt.map { "écrit le " + DeathScaleTime.format($0) } ?? " ")
                .font(DeathScaleFont.pica.font(12)).tracking(0.7)
                .foregroundStyle(palette.ink2)
                .padding(.top, 8)
            DeathScaleActionButton(title: "FERMER", dark: true, palette: palette, action: close)
                .padding(.top, 14)
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(palette.ink, lineWidth: 1.5))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.ink, lineWidth: 0.5).padding(5))
        .padding(12)
        .foregroundStyle(palette.ink)
        .tint(palette.ink)
        .background(palette.paper.ignoresSafeArea())
        .onAppear {
            text = store.carnet
            writtenAt = (try? FileManager.default.attributesOfItem(atPath: DeathScaleStore.defaultRoot.appendingPathComponent("carnet.md").path))?[.modificationDate] as? Date
        }
        .onChange(of: text) { _, value in
            saving?.cancel()
            saving = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                if value != store.carnet {
                    store.setCarnet(value)
                    writtenAt = Date()
                }
            }
        }
        .onDisappear(perform: flush)
    }

    private func close() {
        writing = false
        flush()
        dismiss()
    }

    private func flush() {
        saving?.cancel()
        if text != store.carnet {
            store.setCarnet(text)
            writtenAt = Date()
        }
    }

    private var paper: some View {
        Canvas { ctx, size in
            let rule = palette.ink.opacity(0.28), margin = palette.ink.opacity(0.45)
            var y = Self.lineHeight - 6.5
            while y < size.height + 400 {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.8)), with: .color(rule))
                y += Self.lineHeight
            }
            ctx.fill(Path(CGRect(x: 22, y: 0, width: 1, height: size.height + 400)), with: .color(margin))
            ctx.fill(Path(CGRect(x: 25, y: 0, width: 0.5, height: size.height + 400)), with: .color(margin))
        }
    }
}

/// 横线纸：每行固定 30pt，字落在线上（iOS / macOS 26 有精确行高；老 mac 用行距近似）
private struct DeathScaleLinePitch: ViewModifier {
    let pitch: Double

    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.lineHeight(.exact(points: pitch))
        } else {
            content.lineSpacing(pitch - 21)
        }
    }
}
#endif
