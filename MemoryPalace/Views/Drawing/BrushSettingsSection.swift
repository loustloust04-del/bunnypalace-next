import SwiftUI

/// 设置 · 贴纸 ·「画笔」（docs/design-page1-画板UI.html 第三台）：系统列表——每支笔一行开关、两组颜色可加可删、默认纸。
struct BrushSettingsSection: View {
    @Environment(\.settingsMetrics) private var m
    @State private var settings = BrushSettings.load()
    @State private var pendingWater = Color(red: 0.55, green: 0.42, blue: 0.62)
    @State private var pendingInk = Color(red: 0.2, green: 0.22, blue: 0.3)

    var body: some View {
        Section {
            ForEach(BoardTool.defaultTools) { tool in
                Toggle(isOn: Binding(get: { settings.tools.contains(tool) }, set: { set(tool, on: $0) })) {
                    HStack(spacing: 12) {
                        PenIllustration(tool: tool, tip: Color(brushHex: tool == .watercolor ? "#3a6fb0" : "#22314a"))
                            .frame(width: 13, height: 42)
                            .rotationEffect(.degrees(-38))
                            .frame(width: 28, height: 30)
                        Text(tool.title).font(m.secondary).foregroundColor(Theme.textPrimary)
                    }
                }
                .tint(Theme.branchIndicator)
                .disabled(settings.tools == [tool])   // 至少留一支
            }
        } header: {
            Text("画笔")
        } footer: {
            Text("关掉的笔不出现在画板里。")
        }

        palette("水彩颜色", colors: $settings.waterColors, pending: $pendingWater, defaults: BrushSettings.defaultWaterColors)
        palette("墨水颜色（钢笔 / 铅笔 / 马克笔…）", colors: $settings.inkColors, pending: $pendingInk, defaults: BrushSettings.defaultInkColors)

        noteDefaults

        Section {
            Picker("默认纸", selection: $settings.paper) {
                ForEach(PaperKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .font(m.secondary)
        }
        .onChange(of: settings) { _, new in new.save() }
    }

    /// 新便利贴默认长什么样（点了「便利贴」直接出这张纸）
    private var noteDefaults: some View {
        let spec = settings.noteDefault
        let bind = { (f: (inout NoteSpec) -> Void) in var s = spec; f(&s); settings.note = s.raw }
        return Section {
            HStack {
                Spacer()
                NoteView(spec: spec, text: "新便利贴长这样", width: 168).scaleEffect(0.8).frame(width: 140, height: 120)
                Spacer()
            }
            .padding(.vertical, 6)
            Picker("纸", selection: Binding(get: { spec.kind }, set: { k in bind { $0 = NoteSpec(kind: k, color: nil, font: $0.font) } })) {
                ForEach(NoteKind.allCases) { Text($0.title).tag($0) }
            }
            if !spec.kind.colors.isEmpty {
                HStack(spacing: 10) {
                    Text("颜色").font(m.secondary).foregroundColor(Theme.textPrimary)
                    Spacer()
                    ForEach(spec.kind.colors, id: \.self) { hex in
                        Circle().fill(Color(brushHex: hex))
                            .overlay(Circle().stroke(.black.opacity(0.1), lineWidth: 0.5))
                            .frame(width: 24, height: 24)
                            .padding(2)
                            .overlay(Circle().stroke(Theme.textPrimary, lineWidth: spec.color == hex ? 2 : 0))
                            .onTapGesture { bind { $0.color = hex } }
                            .accessibilityLabel("颜色 \(hex)")
                    }
                }
            }
            Picker("字体", selection: Binding(get: { spec.font }, set: { f in bind { $0.font = f } })) {
                ForEach(NoteFont.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("便利贴")
        }
        .font(m.secondary)
    }

    private func set(_ tool: BoardTool, on: Bool) {
        if on {
            settings.tools = BoardTool.defaultTools.filter { settings.tools.contains($0) || $0 == tool }
        } else if settings.tools.count > 1 {
            settings.tools.removeAll { $0 == tool }
        }
    }

    private func palette(_ title: String, colors: Binding<[String]>, pending: Binding<Color>, defaults: [String]) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(colors.wrappedValue, id: \.self) { hex in
                    Circle()
                        .fill(Color(brushHex: hex))
                        .overlay(Circle().stroke(.black.opacity(0.08), lineWidth: 0.5))
                        .frame(width: 30, height: 30)
                        .contextMenu {
                            Button(role: .destructive) { colors.wrappedValue.removeAll { $0 == hex } } label: {
                                Label("删掉这个颜色", systemImage: "trash")
                            }
                            .disabled(colors.wrappedValue.count <= 1)
                        }
                        .accessibilityLabel("颜色 \(hex)")
                }
            }
            .padding(.vertical, 4)
            HStack {
                ColorPicker("添加颜色", selection: pending, supportsOpacity: false)
                    .font(m.secondary)
                Button("加入") {
                    let hex = Self.hex(pending.wrappedValue)
                    if !colors.wrappedValue.contains(hex) { colors.wrappedValue.append(hex) }
                }
                .font(m.secondary.weight(.medium))
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if colors.wrappedValue != defaults {
                    Button("恢复默认") { colors.wrappedValue = defaults }
                        .font(m.caption).foregroundColor(Theme.branchIndicator).buttonStyle(.plain)
                        .textCase(nil)
                }
            }
        } footer: {
            Text("长按颜色可以删掉。")
        }
    }

    static func hex(_ c: Color) -> String {
        let r = c.resolve(in: EnvironmentValues())
        func h(_ v: Float) -> String { String(format: "%02x", Int((min(1, max(0, v)) * 255).rounded())) }
        return "#" + h(r.red) + h(r.green) + h(r.blue)
    }
}
