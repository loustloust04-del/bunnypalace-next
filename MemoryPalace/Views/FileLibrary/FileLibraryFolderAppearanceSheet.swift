import SwiftUI

/// 长按文件夹 →「外观…」：颜色（8 + 自定义）/ 纹样 / 标记。改了立刻生效、立刻写盘，没有保存键。
struct FileLibraryFolderAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let name: String
    let detail: String
    let sheets: [FileLibraryFolderSheet]
    /// 这次没改成的原因（iCloud 还没同步完等），nil 不显示
    let notice: String?
    @Binding var look: FileLibraryFolderLook
    let onReset: () -> Void

    @State private var editingEmoji = false
    @State private var emojiDraft = ""
    @FocusState private var emojiFocused: Bool

    private static let symbols = [
        "pencil", "book", "graduationcap", "calendar", "heart", "leaf",
        "star", "camera", "music.note", "chart.line.uptrend.xyaxis", "paperclip"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FileLibraryFolderCard(name: name, detail: detail, look: look, sheets: sheets, pose: .open)
                        .frame(width: FileLibraryUI.size(200))
                        .padding(.top, FileLibraryUI.size(30))
                        .frame(maxWidth: .infinity)
                    if let notice {
                        Text(notice)
                            .font(FileLibraryUI.font(12))
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 10)
                    }
                    label("颜色")
                    swatches
                    label("纹样")
                    patternGrid
                    label("标记")
                    markGrid
                    if editingEmoji { emojiField }
                    Button("恢复默认") { onReset() }
                        .buttonStyle(.plain)
                        .font(FileLibraryUI.font(13))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
            }
        }
        .background(Theme.mainBg)
        #if os(macOS)
        .frame(width: 360, height: 600)
        #endif
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Text("「\(name)」的外观")
                .font(FileLibraryUI.font(16, .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button("完成") { dismiss() }
                .buttonStyle(.plain)
                .font(FileLibraryUI.font(15))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(FileLibraryUI.font(12))
            .tracking(0.5)
            .foregroundColor(Theme.textMuted)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    // MARK: - 颜色

    private var swatches: some View {
        let side = FileLibraryUI.size(29)
        return HStack(spacing: FileLibraryUI.size(8)) {
            ForEach(FileLibraryFolderPalette.allCases, id: \.self) { preset in
                Button { look.color = preset.rawValue } label: {
                    Circle()
                        .fill(Color(hex: preset.back))
                        .overlay(Circle().strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 0.5))
                        .frame(width: side, height: side)
                        .overlay(selectionRing(look.color == preset.rawValue))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.colorName(preset))
                .accessibilityAddTraits(look.color == preset.rawValue ? .isSelected : [])
            }
            ColorPicker("自定义颜色", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: side, height: side)
                .overlay(selectionRing(FileLibraryFolderPalette.hexValue(look.color) != nil).allowsHitTesting(false))
        }
    }

    private func selectionRing(_ on: Bool) -> some View {
        Circle()
            .stroke(Theme.textPrimary, lineWidth: 2)
            .padding(-4)
            .opacity(on ? 1 : 0)
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { look.paint.backColor },
            set: { color in
                if let hex = Self.hex(of: color) { look.color = FileLibraryFolderPalette.hexString(hex) }
            }
        )
    }

    private static func hex(of color: Color) -> UInt? {
        #if os(macOS)
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let rgb = [c.redComponent, c.greenComponent, c.blueComponent]
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        let rgb = [r, g, b]
        #endif
        return rgb.reduce(UInt(0)) { acc, v in (acc << 8) | UInt((min(max(v, 0), 1) * 255).rounded()) }
    }

    private static func colorName(_ p: FileLibraryFolderPalette) -> String {
        switch p {
        case .mint: "薄荷"
        case .rose: "玫瑰"
        case .lilac: "淡紫"
        case .sky: "蓝灰"
        case .sand: "沙"
        case .olive: "橄榄"
        case .cream: "奶白"
        case .ink: "棕黑"
        }
    }

    // MARK: - 纹样 / 标记

    private var patternGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 5), spacing: 9) {
            option(selected: look.pattern == nil, label: "无") { look.pattern = nil }
            ForEach(FileLibraryFolderLook.Pattern.allCases, id: \.self) { pattern in
                option(selected: look.pattern == pattern, label: pattern.title) { look.pattern = pattern }
            }
        }
    }

    private var markGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 6), spacing: 9) {
            option(selected: look.mark.kind == .none, label: "无") { look.mark = .none }
            option(selected: look.mark.kind == .mono, label: "首字") { look.mark = .mono }
            ForEach(Self.symbols, id: \.self) { symbol in
                option(selected: look.mark == .symbol(symbol), symbol: symbol) { look.mark = .symbol(symbol) }
            }
            if look.mark.kind == .emoji, let glyph = look.mark.value {
                option(selected: true, label: glyph, large: true) { startEmoji() }
            } else {
                option(selected: false, label: "＋ emoji") { startEmoji() }
            }
        }
    }

    private var emojiField: some View {
        TextField("输入一个 emoji", text: $emojiDraft)
            .textFieldStyle(.plain)
            .font(FileLibraryUI.font(15))
            .focused($emojiFocused)
            .padding(.horizontal, 12)
            .frame(height: FileLibraryUI.size(40))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FileLibraryUI.fieldFill))
            .padding(.top, 10)
            .onChange(of: emojiDraft) { _, text in
                guard let last = text.last else { return }
                let glyph = String(last)
                if text != glyph { emojiDraft = glyph }
                look.mark = .emoji(glyph)
            }
            .onSubmit { editingEmoji = false }
    }

    private func startEmoji() {
        emojiDraft = ""
        editingEmoji = true
        emojiFocused = true
    }

    private func option(selected: Bool, label: String? = nil, symbol: String? = nil, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: FileLibraryUI.size(17)))
                } else {
                    Text(label ?? "")
                        .font(large ? .system(size: FileLibraryUI.size(20)) : FileLibraryUI.font(11))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: FileLibraryUI.size(46))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.mainBg : Theme.textPrimary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.textPrimary, lineWidth: 1.5)
                    .opacity(selected ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? symbol ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
